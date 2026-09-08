#!/usr/bin/env python3
"""Merge verified numbered artboard images into a PDF and render sample pages."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path, help="UTF-8 result JSON from export-artboards-as-pages.ps1")
    parser.add_argument("--output", required=True, type=Path, help="Final multi-page PDF")
    parser.add_argument("--render-dir", required=True, type=Path, help="Directory for first/middle/last rendered verification PNGs")
    parser.add_argument("--result", required=True, type=Path, help="UTF-8 merge and verification result JSON")
    parser.add_argument("--overwrite", action="store_true", help="Allow replacing an existing final PDF")
    parser.add_argument("--keep-page-pdfs", action="store_true", help="Keep generated single-page PDFs after all checks pass")
    parser.add_argument("--cleanup-images", action="store_true", help="Delete exported page images only after the final PDF and sample renders pass")
    parser.add_argument("--render-max-pixels", type=int, default=1800, help="Maximum rendered sample width or height")
    return parser.parse_args()


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def load_dependencies():
    try:
        from PIL import Image
        from pypdf import PdfReader, PdfWriter
    except ImportError as exc:  # pragma: no cover - environment-specific
        raise RuntimeError(
            "PDF merge requires Pillow and pypdf. Install the missing package before retrying."
        ) from exc
    try:
        import fitz
    except ImportError:  # Poppler is the preferred bundled fallback.
        fitz = None
    return Image, PdfReader, PdfWriter, fitz


def validated_pages(manifest_path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not manifest_path.is_file():
        raise RuntimeError(f"Page manifest is missing: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    if manifest.get("ok") is not True:
        raise RuntimeError("Page export manifest does not report ok=true")
    pages = list(manifest.get("pages") or [])
    if not pages:
        raise RuntimeError("Page export manifest contains no pages")
    pages.sort(key=lambda item: int(item["number"]))
    numbers = [int(item["number"]) for item in pages]
    if len(set(numbers)) != len(numbers):
        raise RuntimeError("Page manifest contains duplicate page numbers")
    for previous, current in zip(numbers, numbers[1:]):
        if current != previous + 1:
            raise RuntimeError("Page manifest numbering is not contiguous")
    for item in pages:
        page_path = Path(str(item["file"])).resolve()
        if not page_path.is_file() or page_path.stat().st_size <= 0:
            raise RuntimeError(f"Exported page is missing or empty: {page_path}")
        item["file"] = str(page_path)
    declared_count = int(manifest.get("pageCount", len(pages)))
    if declared_count != len(pages):
        raise RuntimeError(f"Manifest pageCount is {declared_count}, but {len(pages)} page records were found")
    return manifest, pages


def image_to_single_page_pdf(Image, image_path: Path, pdf_path: Path) -> None:
    with Image.open(image_path) as opened:
        if opened.mode in ("RGBA", "LA") or (opened.mode == "P" and "transparency" in opened.info):
            rgba = opened.convert("RGBA")
            rgb = Image.new("RGB", rgba.size, "white")
            rgb.paste(rgba, mask=rgba.getchannel("A"))
        else:
            rgb = opened.convert("RGB")
        dpi_value = opened.info.get("dpi", (72, 72))
        dpi = float(dpi_value[0] if isinstance(dpi_value, tuple) else dpi_value)
        if dpi <= 0:
            dpi = 72.0
        rgb.save(pdf_path, "PDF", resolution=dpi)
        rgb.close()


def render_samples_fitz(fitz, pdf_path: Path, render_dir: Path, page_count: int, max_pixels: int) -> list[dict[str, Any]]:
    if max_pixels < 100:
        raise RuntimeError("render-max-pixels must be at least 100")
    render_dir.mkdir(parents=True, exist_ok=True)
    indexes = sorted({0, page_count // 2, page_count - 1})
    outputs: list[dict[str, Any]] = []
    with fitz.open(pdf_path) as document:
        if document.page_count != page_count:
            raise RuntimeError("Renderer page count differs from pypdf verification")
        for index in indexes:
            page = document.load_page(index)
            rect = page.rect
            longest = max(float(rect.width), float(rect.height), 1.0)
            scale = min(1.0, max_pixels / longest)
            pixmap = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
            out_path = render_dir / f"verify-page-{index + 1:04d}.png"
            pixmap.save(out_path)
            if not out_path.is_file() or out_path.stat().st_size <= 0:
                raise RuntimeError(f"Rendered verification image is missing or empty: {out_path}")
            outputs.append({"page": index + 1, "file": str(out_path.resolve()), "width": pixmap.width, "height": pixmap.height})
    return outputs


def run_poppler(command: list[str]) -> None:
    executable = Path(command[0])
    if executable.suffix.lower() in {".cmd", ".bat"}:
        comspec = os.environ.get("COMSPEC", "cmd.exe")
        completed = subprocess.run(
            [comspec, "/d", "/s", "/c", subprocess.list2cmdline(command)],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    else:
        completed = subprocess.run(command, check=False, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "unknown Poppler error").strip()
        raise RuntimeError(f"pdftoppm failed with exit code {completed.returncode}: {detail}")


def resolve_pdftoppm() -> str | None:
    found = shutil.which("pdftoppm")
    if not found:
        return None
    wrapper = Path(found).resolve()
    if wrapper.suffix.lower() not in {".cmd", ".bat"}:
        return str(wrapper)
    candidates = [
        wrapper.parent.parent.parent / "native" / "poppler" / "Library" / "bin" / "pdftoppm.exe",
        wrapper.parent.parent / "Library" / "bin" / "pdftoppm.exe",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate.resolve())
    return str(wrapper)


def render_samples_poppler(Image, pdf_path: Path, render_dir: Path, page_count: int, max_pixels: int) -> list[dict[str, Any]]:
    executable = resolve_pdftoppm()
    if not executable:
        raise RuntimeError("Sample rendering requires PyMuPDF or Poppler pdftoppm; neither is available")
    render_dir.mkdir(parents=True, exist_ok=True)
    indexes = sorted({0, page_count // 2, page_count - 1})
    outputs: list[dict[str, Any]] = []
    for index in indexes:
        prefix = render_dir / f"verify-page-{index + 1:04d}"
        out_path = prefix.with_suffix(".png")
        command = [
            executable,
            "-png",
            "-f",
            str(index + 1),
            "-l",
            str(index + 1),
            "-singlefile",
            "-scale-to",
            str(max_pixels),
            str(pdf_path),
            str(prefix),
        ]
        run_poppler(command)
        if not out_path.is_file() or out_path.stat().st_size <= 0:
            raise RuntimeError(f"Rendered verification image is missing or empty: {out_path}")
        with Image.open(out_path) as rendered:
            width, height = rendered.size
        outputs.append({"page": index + 1, "file": str(out_path.resolve()), "width": width, "height": height})
    return outputs


def main() -> int:
    args = parse_args()
    result: dict[str, Any] = {
        "ok": False,
        "stage": "merge",
        "manifest": str(args.manifest.resolve()),
        "output": str(args.output.resolve()),
        "pageCount": 0,
        "singlePagePdfDirectory": None,
        "sampleRenders": [],
        "renderer": None,
        "imagesDeleted": False,
        "error": None,
    }
    work_dir: Path | None = None
    partial_path: Path | None = None
    try:
        Image, PdfReader, PdfWriter, fitz = load_dependencies()
        _, pages = validated_pages(args.manifest.resolve())
        output_path = args.output.resolve()
        if output_path.exists() and not args.overwrite:
            raise RuntimeError(f"Final PDF already exists: {output_path}")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        args.render_dir.resolve().mkdir(parents=True, exist_ok=True)

        token = uuid.uuid4().hex
        work_dir = output_path.parent / f".{output_path.stem}.page-pdfs-{token}"
        work_dir.mkdir(parents=False, exist_ok=False)
        result["singlePagePdfDirectory"] = str(work_dir.resolve())
        single_page_pdfs: list[Path] = []
        for page in pages:
            number = int(page["number"])
            page_pdf = work_dir / f"page-{number:04d}.pdf"
            image_to_single_page_pdf(Image, Path(page["file"]), page_pdf)
            reader = PdfReader(str(page_pdf))
            if len(reader.pages) != 1:
                raise RuntimeError(f"Single-page PDF verification failed: {page_pdf}")
            single_page_pdfs.append(page_pdf)

        writer = PdfWriter()
        for page_pdf in single_page_pdfs:
            reader = PdfReader(str(page_pdf))
            writer.add_page(reader.pages[0])
        partial_path = output_path.parent / f".{output_path.name}.{token}.partial"
        with partial_path.open("wb") as output_stream:
            writer.write(output_stream)

        merged = PdfReader(str(partial_path))
        if len(merged.pages) != len(pages):
            raise RuntimeError(f"Final PDF has {len(merged.pages)} pages; expected {len(pages)}")
        for index, page in enumerate(merged.pages):
            box = page.mediabox
            if float(box.width) <= 0 or float(box.height) <= 0:
                raise RuntimeError(f"Final PDF page {index + 1} has invalid dimensions")

        if fitz is not None:
            samples = render_samples_fitz(fitz, partial_path, args.render_dir.resolve(), len(pages), args.render_max_pixels)
            renderer = "PyMuPDF"
        else:
            samples = render_samples_poppler(Image, partial_path, args.render_dir.resolve(), len(pages), args.render_max_pixels)
            renderer = "Poppler pdftoppm"
        os.replace(partial_path, output_path)
        partial_path = None
        if not output_path.is_file() or output_path.stat().st_size <= 0:
            raise RuntimeError("Final PDF is missing or empty after atomic replacement")
        final_reader = PdfReader(str(output_path))
        if len(final_reader.pages) != len(pages):
            raise RuntimeError("Final PDF page count changed after atomic replacement")

        result.update({"ok": True, "stage": "verified", "pageCount": len(pages), "sampleRenders": samples, "renderer": renderer})
        if args.cleanup_images:
            for page in pages:
                Path(page["file"]).unlink()
            result["imagesDeleted"] = True
        if not args.keep_page_pdfs:
            shutil.rmtree(work_dir)
            result["singlePagePdfDirectory"] = None
            work_dir = None
    except Exception as exc:
        result["ok"] = False
        result["stage"] = "failed"
        result["error"] = str(exc)
    finally:
        if partial_path is not None and not result["ok"]:
            result["partialPdf"] = str(partial_path.resolve())
        write_json(args.result.resolve(), result)

    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
