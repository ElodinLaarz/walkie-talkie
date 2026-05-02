"""
Cross-platform Segoe UI font discovery for the screenshot generators.

Resolution order:
  1. Windows  — C:/Windows/Fonts/segoeui{b}.ttf
  2. macOS    — /Library/Fonts/segoeui.ttf or Microsoft fonts via brew
  3. Linux    — well-known DejaVu paths, then fc-match (fontconfig)
  4. Fallback — PIL default bitmap font (small sizes only; no TTF quality)

Import:
    from _fonts import FONT_BD, FONT_REG

Requires Python 3.8+.
"""
import os
import shutil
import subprocess
import sys
from typing import Optional


def _exists(path):
    # type: (str) -> Optional[str]
    """Return path if the file exists, else None."""
    return path if os.path.isfile(path) else None


def _fc_match(family):
    # type: (str) -> Optional[str]
    """Try fontconfig (fc-match) to locate a font by family name."""
    if shutil.which("fc-match") is None:
        return None
    try:
        out = subprocess.check_output(
            ["fc-match", "--format=%{file}", family],
            stderr=subprocess.DEVNULL,
            timeout=3,
        ).decode().strip()
        return out if out and os.path.isfile(out) else None
    except Exception:
        return None


def _find_font(bold):
    # type: (bool) -> str
    """
    Locate the best available proportional font for the current OS.

    Returns an absolute path to a TTF/OTF file, or the sentinel string
    'default' if no TTF could be found (PIL will use its built-in bitmap).
    """
    win_name = "segoeuib.ttf" if bold else "segoeui.ttf"
    dv_name  = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"

    # 1. Windows
    if found := _exists(os.path.join("C:/Windows/Fonts", win_name)):
        return found

    # 2. macOS — Segoe UI installed via Microsoft Office or brew fonts
    for mac_dir in [
        "/Library/Fonts",
        os.path.expanduser("~/Library/Fonts"),
        "/opt/homebrew/share/fonts",
        "/usr/local/share/fonts",
    ]:
        for name in [win_name, win_name.lower()]:
            if found := _exists(os.path.join(mac_dir, name)):
                return found

    # 3. Well-known DejaVu paths — check before the expensive os.walk and
    #    fontconfig call.  Ubuntu/Debian typically place DejaVu here.
    for share in ["/usr/share/fonts/truetype/dejavu",
                  "/usr/share/fonts/dejavu",
                  "/usr/local/share/fonts"]:
        if found := _exists(os.path.join(share, dv_name)):
            return found

    # 4. fontconfig (fc-match) — handles Segoe UI if installed, and any
    #    system sans-serif on both Linux and macOS.
    for query in (
        ("Segoe UI:bold" if bold else "Segoe UI"),
        ("DejaVu Sans:bold" if bold else "DejaVu Sans"),
        "sans-serif:bold" if bold else "sans-serif",
    ):
        if found := _fc_match(query):
            return found

    # 5. Last resort: recursive walk (limited depth to avoid excessive I/O).
    for share in ["/usr/share/fonts", "/usr/local/share/fonts"]:
        for root, _, files in os.walk(share):
            if dv_name in files:
                return os.path.join(root, dv_name)

    return "default"


FONT_BD = _find_font(bold=True)   # type: str
FONT_REG = _find_font(bold=False)  # type: str

if FONT_BD == "default" or FONT_REG == "default":
    print(
        "WARNING: could not locate a proportional TTF font. "
        "Text will use PIL's built-in bitmap and may look blocky. "
        "Install Segoe UI (Windows), DejaVu (Linux), or any sans-serif TTF "
        "and re-run. On Linux: sudo apt install fonts-dejavu-core",
        file=sys.stderr,
    )
