#!/usr/bin/env python3
"""
Generate FS25_FieldToDoList graphics from SVG sources.

Outputs:
  gui/menuIcon.svg      Source for menuIcon.dds (dev/build only, not shipped)
  gui/menuIcon.dds      In-game ESC menu tab texture
  gui/icons/*.svg       Optional button icon sources (not used in current UI)
  icon.dds              Mod list icon (512x512)

Requirements for conversion (at least one):
  - ImageMagick (convert or magick)
  - or: rsvg-convert + ImageMagick

Usage:
  python3 tools/generate_assets.py
  python3 tools/generate_assets.py --only svg
  python3 tools/generate_assets.py --only dds
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUI_DIR = ROOT / "gui"

# ESC tab: vanilla-style white outline on transparent (engine shows it on dark + green selected tabs).
# Do NOT use green fill here — selected tabs are green and would hide the paper.
MENU_ICON_SVG = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" fill="none"/>
  <!-- Clipboard frame + clip (white outline) -->
  <rect x="280" y="200" width="464" height="620" rx="48" fill="none" stroke="#F2F2F2" stroke-width="44"/>
  <rect x="392" y="140" width="240" height="88" rx="36" fill="none" stroke="#F2F2F2" stroke-width="40"/>
  <!-- Checklist (same light tone as vanilla glyphs) -->
  <path d="M360 380 L420 440 L540 320" fill="none" stroke="#F2F2F2" stroke-width="40" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="580" y1="380" x2="700" y2="380" stroke="#F2F2F2" stroke-width="32" stroke-linecap="round"/>
  <path d="M360 520 L420 580 L540 460" fill="none" stroke="#F2F2F2" stroke-width="40" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="580" y1="520" x2="720" y2="520" stroke="#F2F2F2" stroke-width="32" stroke-linecap="round"/>
  <circle cx="400" cy="660" r="28" fill="none" stroke="#F2F2F2" stroke-width="28"/>
  <line x1="580" y1="660" x2="700" y2="660" stroke="#F2F2F2" stroke-width="32" stroke-linecap="round"/>
</svg>
"""

# 128x128 button icons (white on transparent) — replace gui/icons/*.svg anytime
BUTTON_ICONS: dict[str, str] = {
    "add": """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" fill="none"/>
  <line x1="64" y1="28" x2="64" y2="100" stroke="#F2F2F2" stroke-width="14" stroke-linecap="round"/>
  <line x1="28" y1="64" x2="100" y2="64" stroke="#F2F2F2" stroke-width="14" stroke-linecap="round"/>
</svg>
""",
    "edit": """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" fill="none"/>
  <path d="M88 24 L104 40 L52 92 L28 100 L36 76 Z" fill="none" stroke="#F2F2F2" stroke-width="10" stroke-linejoin="round"/>
  <line x1="76" y1="36" x2="92" y2="52" stroke="#8BC34A" stroke-width="8" stroke-linecap="round"/>
</svg>
""",
    "done": """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" fill="none"/>
  <path d="M28 72 L52 96 L100 36" fill="none" stroke="#8BC34A" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M72 88 L100 88 L100 100 L28 100 L28 72 L40 72 L40 88 Z" fill="none" stroke="#F2F2F2" stroke-width="8" stroke-linejoin="round"/>
</svg>
""",
    "delete": """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <rect width="128" height="128" fill="none"/>
  <line x1="36" y1="36" x2="92" y2="92" stroke="#F2F2F2" stroke-width="14" stroke-linecap="round"/>
  <line x1="92" y1="36" x2="36" y2="92" stroke="#F2F2F2" stroke-width="14" stroke-linecap="round"/>
</svg>
""",
}

LOGO_SVG = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <!-- Transparent: black frame, green paper flush, gray checklist. -->
  <rect width="512" height="512" fill="none"/>
  <rect x="128" y="96" width="256" height="340" rx="28" fill="#8BC34A" stroke="#1A1A1A" stroke-width="22"/>
  <rect x="188" y="64" width="136" height="52" rx="18" fill="#1A1A1A"/>
  <rect x="208" y="78" width="96" height="24" rx="10" fill="#8BC34A"/>
  <!-- Checklist writing (gray) -->
  <path d="M168 188 L200 220 L256 152" fill="none" stroke="#EEEEEE" stroke-width="20" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="280" y1="188" x2="348" y2="188" stroke="#EEEEEE" stroke-width="16" stroke-linecap="round"/>
  <path d="M168 268 L200 300 L256 232" fill="none" stroke="#EEEEEE" stroke-width="20" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="280" y1="268" x2="360" y2="268" stroke="#EEEEEE" stroke-width="16" stroke-linecap="round"/>
  <circle cx="192" cy="360" r="18" fill="none" stroke="#EEEEEE" stroke-width="16"/>
  <line x1="280" y1="360" x2="340" y2="360" stroke="#EEEEEE" stroke-width="16" stroke-linecap="round"/>
</svg>
"""


def write_svgs() -> None:
    GUI_DIR.mkdir(parents=True, exist_ok=True)
    icons_dir = GUI_DIR / "icons"
    icons_dir.mkdir(parents=True, exist_ok=True)

    (GUI_DIR / "menuIcon.svg").write_text(MENU_ICON_SVG, encoding="utf-8")
    (GUI_DIR / "logo.svg").write_text(LOGO_SVG, encoding="utf-8")
    print(f"Wrote {GUI_DIR / 'menuIcon.svg'}")
    print(f"Wrote {GUI_DIR / 'logo.svg'}")

    for name, svg in BUTTON_ICONS.items():
        path = icons_dir / f"{name}.svg"
        path.write_text(svg, encoding="utf-8")
        print(f"Wrote {path}")


def find_convert() -> list[str] | None:
    if shutil.which("magick"):
        return ["magick"]
    if shutil.which("convert"):
        return ["convert"]
    return None


def svg_to_png(svg_path: Path, png_path: Path, size: int) -> bool:
    if shutil.which("rsvg-convert"):
        cmd = [
            "rsvg-convert",
            "-w",
            str(size),
            "-h",
            str(size),
            "-o",
            str(png_path),
            str(svg_path),
        ]
        subprocess.run(cmd, check=True)
        return True

    convert = find_convert()
    if convert is None:
        return False

    cmd = [
        *convert,
        "-background",
        "none",
        "-resize",
        f"{size}x{size}",
        str(svg_path),
        str(png_path),
    ]
    subprocess.run(cmd, check=True)
    return True


def png_to_dds(png_path: Path, dds_path: Path, use_alpha: bool) -> bool:
    convert = find_convert()
    if convert is None:
        return False

    compression = "dxt5" if use_alpha else "dxt1"
    cmd = [
        *convert,
        str(png_path),
        "-define",
        f"dds:compression={compression}",
        "-define",
        "dds:mipmaps=0",
        str(dds_path),
    ]
    subprocess.run(cmd, check=True)
    return True


def convert_all() -> int:
    menu_svg = GUI_DIR / "menuIcon.svg"
    logo_svg = GUI_DIR / "logo.svg"

    if not menu_svg.is_file() or not logo_svg.is_file():
        write_svgs()

    tmp_dir = ROOT / ".build" / "assets"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    menu_png = tmp_dir / "menuIcon.png"
    icon_png = tmp_dir / "icon.png"

    try:
        if not svg_to_png(menu_svg, menu_png, 1024):
            print("error: need rsvg-convert or ImageMagick to rasterize SVG", file=sys.stderr)
            return 1

        if not svg_to_png(logo_svg, icon_png, 512):
            print("error: failed to rasterize logo.svg", file=sys.stderr)
            return 1

        if not png_to_dds(menu_png, GUI_DIR / "menuIcon.dds", use_alpha=True):
            print("error: ImageMagick required for DDS export", file=sys.stderr)
            return 1

        if not png_to_dds(icon_png, ROOT / "icon.dds", use_alpha=True):
            print("error: failed to write icon.dds", file=sys.stderr)
            return 1

        icons_dir = GUI_DIR / "icons"
        icons_dir.mkdir(parents=True, exist_ok=True)
        for name in BUTTON_ICONS:
            svg_path = icons_dir / f"{name}.svg"
            if not svg_path.is_file():
                write_svgs()
            icon_png = tmp_dir / f"{name}.png"
            icon_dds = icons_dir / f"{name}.dds"
            if not svg_to_png(svg_path, icon_png, 128):
                print(f"error: failed to rasterize {svg_path}", file=sys.stderr)
                return 1
            if not png_to_dds(icon_png, icon_dds, use_alpha=True):
                print(f"error: failed to write {icon_dds}", file=sys.stderr)
                return 1
            print(f"Wrote {icon_dds}")

    except subprocess.CalledProcessError as exc:
        print(f"error: conversion command failed: {exc}", file=sys.stderr)
        return 1

    print(f"Wrote {GUI_DIR / 'menuIcon.dds'}")
    print(f"Wrote {ROOT / 'icon.dds'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate FS25_FieldToDoList SVG/DDS assets")
    parser.add_argument(
        "--only",
        choices=("svg", "dds", "all"),
        default="all",
        help="Generate only SVG sources, only DDS textures, or everything",
    )
    args = parser.parse_args()

    if args.only in ("svg", "all"):
        write_svgs()

    if args.only in ("dds", "all"):
        return convert_all()

    return 0


if __name__ == "__main__":
    sys.exit(main())
