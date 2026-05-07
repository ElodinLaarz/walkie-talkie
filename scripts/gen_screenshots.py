"""
Generate three Play-Store phone screenshots for the Frequency app.
Dimensions: 1080 x 1920 (9:16, standard phone portrait)
Run: python3 scripts/gen_screenshots.py
"""
import os
import sys

# Allow running from the repo root or from the scripts/ directory.
sys.path.insert(0, os.path.dirname(__file__))
from _fonts import FONT_BD, FONT_REG  # noqa: E402

from PIL import Image, ImageDraw, ImageFont

OUT = "fastlane/metadata/android/en-US/images/phoneScreenshots"
ICON_PATH = "assets/icon/icon.png"

W, H = 1080, 1920
BLUE      = (52,  152, 219)
DARK_BLUE = (26,  109, 174)
WHITE     = (255, 255, 255)
BG        = (250, 250, 250)
CARD_BG   = (255, 255, 255)
TEXT1     = (33,   33,  33)
TEXT2     = (117, 117, 117)
DIVIDER   = (224, 224, 224)
RED_PTT   = (231,  76,  60)
TEAL      = (26,  188, 156)
PURPLE    = (155,  89, 182)
GREEN     = (39,  174,  96)

os.makedirs(OUT, exist_ok=True)


def fnt(size, bold=False):
    """Return a Pillow ImageFont at the given point size (auto-detected system font)."""
    path = FONT_BD if bold else FONT_REG
    if path == "default":
        return ImageFont.load_default()
    return ImageFont.truetype(path, size)


def rounded_rect(draw, xy, r, fill=None, outline=None, width=1):
    """Draw a rounded rectangle; thin wrapper around draw.rounded_rectangle."""
    draw.rounded_rectangle(xy, radius=r, fill=fill, outline=outline, width=width)


def status_bar(draw, y=0, h=80):
    """Draw a blue Android-style status bar with time, signal bars, and battery icon."""
    draw.rectangle([0, y, W, y + h], fill=BLUE)
    draw.text((50, y + (h - 34) // 2 + 2), "9:41", font=fnt(34, True), fill=WHITE)
    bx, by = W - 130, y + h // 2 - 14
    draw.rounded_rectangle([bx, by, bx + 52, by + 28], radius=4, outline=WHITE, width=3)
    draw.rectangle([bx + 2, by + 2, bx + 42, by + 26], fill=WHITE)
    draw.rectangle([bx + 52, by + 9, bx + 58, by + 19], fill=WHITE)
    sx, sy = W - 220, y + h // 2 + 10
    for i, hb in enumerate([8, 14, 20, 26]):
        draw.rectangle([sx + i * 12, sy - hb, sx + i * 12 + 8, sy], fill=WHITE)


def nav_bar(draw):
    """Draw the Android three-button navigation bar at the bottom of the canvas."""
    draw.rectangle([0, H - 100, W, H], fill=(240, 240, 240))
    for i, ic in enumerate(["<", "O", "[]"]):
        nx = W // 4 * (i + 1)
        draw.text((nx - 16, H - 78), ic, font=fnt(36), fill=TEXT2)


def avatar(draw, cx, cy, r, color, initials):
    """Draw a circular avatar chip at (cx, cy) with radius r, background color, and two-letter initials."""
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)
    f = fnt(r, True)
    tw = draw.textlength(initials, font=f)
    draw.text((cx - tw // 2, cy - r // 2 + 2), initials, font=f, fill=WHITE)


# ──────────────────────────────────────────────────────────────
# Screenshot 1 — Discovery
# ──────────────────────────────────────────────────────────────
def make_discovery():
    """Render the Discovery screen mockup and save to phoneScreenshots/1.png."""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    status_bar(d)
    # App bar
    d.rectangle([0, 80, W, 192], fill=BLUE)
    d.text((54, 108), "Frequency", font=fnt(52, True), fill=WHITE)
    d.text((W - 280, 118), "● Scanning", font=fnt(30), fill=(180, 230, 255))
    y = 192

    # Hero section
    d.rectangle([0, y, W, y + 320], fill=BLUE)
    d.text((54, y + 32), "TUNING THE DIAL", font=fnt(30), fill=(180, 230, 255))
    d.text((54, y + 78), "Phones around you,", font=fnt(52, True), fill=WHITE)
    d.text((54, y + 140), "on the same wavelength.", font=fnt(52, True), fill=WHITE)
    rcx, rcy = W - 150, y + 160
    for r in [45, 80, 115]:
        d.ellipse([rcx - r, rcy - r, rcx + r, rcy + r], outline=(255, 255, 255), width=2)
    d.ellipse([rcx - 18, rcy - 18, rcx + 18, rcy + 18], fill=WHITE)
    y += 320

    # Nearby header
    y += 32
    d.text((54, y), "NEARBY", font=fnt(30, True), fill=TEXT2)
    y += 48

    sessions = [
        ("AC", "Alex Chen",   "98.7 MHz",  BLUE),
        ("TR", "Taylor Room", "104.3 MHz", PURPLE),
        ("MK", "Morgan K.",   "91.5 MHz",  GREEN),
    ]
    rh = 140
    for initials, name, freq, col in sessions:
        d.rectangle([32, y, W - 32, y + rh], fill=CARD_BG, outline=DIVIDER, width=1)
        avatar(d, 32 + 62, y + rh // 2, 38, col, initials)
        d.text((156, y + 26), name, font=fnt(38, True), fill=TEXT1)
        d.text((156, y + 72), "Frequency Session  ·  On " + freq, font=fnt(30), fill=TEXT2)
        bw, bh = 180, 62
        bx0 = W - 32 - 20 - bw
        by0 = y + (rh - bh) // 2
        rounded_rect(d, [bx0, by0, bx0 + bw, by0 + bh], r=31, fill=BLUE)
        btw = d.textlength("Tune in", font=fnt(30, True))
        d.text((bx0 + (bw - btw) // 2, by0 + 16), "Tune in", font=fnt(30, True), fill=WHITE)
        y += rh + 8

    # Start card
    sy2 = H - 240 - 100
    d.rectangle([32, sy2, W - 32, sy2 + 140], fill=CARD_BG, outline=DIVIDER, width=1)
    d.text((54, sy2 + 20), "+ Start a new Frequency", font=fnt(44, True), fill=BLUE)
    d.text((54, sy2 + 80), "A fresh channel will be broadcast at 107.2 MHz", font=fnt(30), fill=TEXT2)

    nav_bar(d)
    img.save(os.path.join(OUT, "1.png"), "PNG", optimize=True)
    print("  1.png (Discovery) saved")


# ──────────────────────────────────────────────────────────────
# Screenshot 2 — Room
# ──────────────────────────────────────────────────────────────
def make_room():
    """Render the Frequency Room screen mockup and save to phoneScreenshots/2.png."""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    status_bar(d)
    d.rectangle([0, 80, W, 192], fill=BLUE)
    d.text((54, 110), "Frequency  ·  98.7 MHz", font=fnt(46, True), fill=WHITE)
    d.text((W - 152, 122), "Leave", font=fnt(32, True), fill=(255, 200, 200))
    y = 192

    PAD = 32

    # Me-card: local user with avatar + name + PTT button
    y += 24
    card_h = 136
    rounded_rect(d, [PAD, y, W - PAD, y + card_h], r=16, fill=CARD_BG)
    ax = PAD + 20 + 44
    ay = y + card_h // 2
    d.ellipse([ax - 44, ay - 44, ax + 44, ay + 44], fill=BLUE)
    iw = d.textlength("AC", font=fnt(36, True))
    d.text((ax - iw // 2, ay - 22), "AC", font=fnt(36, True), fill=WHITE)
    tx = ax + 44 + 18
    d.text((tx, y + 26), "Alex Chen", font=fnt(38, True), fill=TEXT1)
    d.text((tx, y + 74), "Phone speaker", font=fnt(28), fill=TEXT2)
    bw, bh = 152, 64
    bx0 = W - PAD - 20 - bw
    by0 = y + (card_h - bh) // 2
    rounded_rect(d, [bx0, by0, bx0 + bw, by0 + bh], r=32, fill=BLUE)
    btw = d.textlength("PTT", font=fnt(32, True))
    d.text((bx0 + (bw - btw) // 2, by0 + 16), "PTT", font=fnt(32, True), fill=WHITE)
    y += card_h

    # Peers card — linear list matching the actual PeerRow-based UI
    peers = [
        ("TR", "Taylor Rivera", PURPLE, True,  False),
        ("MK", "Morgan Kim",    GREEN,  False, True),
    ]

    # Section header mirrors the in-app SectionLabel: "On this frequency · N"
    # where N = peers + local user.
    y += 28
    d.text((PAD + 6, y),
           f"On this frequency · {len(peers) + 1}", font=fnt(28, True), fill=TEXT2)
    y += 46

    row_h = 120
    card_total = len(peers) * row_h
    rounded_rect(d, [PAD, y, W - PAD, y + card_total], r=16, fill=CARD_BG)

    for i, (initials, name, col, talking, muted) in enumerate(peers):
        ry = y + i * row_h
        ax2 = PAD + 20 + 38
        ay2 = ry + row_h // 2
        if talking:
            d.ellipse([ax2 - 50, ay2 - 50, ax2 + 50, ay2 + 50], outline=col, width=4)
        d.ellipse([ax2 - 38, ay2 - 38, ax2 + 38, ay2 + 38], fill=col)
        niw = d.textlength(initials, font=fnt(30, True))
        d.text((ax2 - niw // 2, ay2 - 18), initials, font=fnt(30, True), fill=WHITE)
        tx2 = ax2 + 38 + 18
        d.text((tx2, ry + 22), name, font=fnt(36, True), fill=TEXT1)
        status = "Talking…" if talking else ("Muted" if muted else "Silent")
        status_col = col if talking else TEXT2
        d.text((tx2, ry + 68), status, font=fnt(28), fill=status_col)
        if i < len(peers) - 1:
            d.line([PAD + 16, ry + row_h, W - PAD - 16, ry + row_h], fill=DIVIDER)
    y += card_total

    # PTT mode hint
    y += 48
    hint = "Push-to-talk · hold the mic button to transmit"
    hw = d.textlength(hint, font=fnt(26))
    d.text((W // 2 - int(hw) // 2, y), hint, font=fnt(26), fill=TEXT2)

    nav_bar(d)
    img.save(os.path.join(OUT, "2.png"), "PNG", optimize=True)
    print("  2.png (Room) saved")


# ──────────────────────────────────────────────────────────────
# Screenshot 3 — Settings
# ──────────────────────────────────────────────────────────────
def make_settings():
    """Render the Settings screen mockup and save to phoneScreenshots/3.png."""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    status_bar(d)
    d.rectangle([0, 80, W, 192], fill=BLUE)
    d.text((54, 110), "Settings", font=fnt(52, True), fill=WHITE)
    y = 192

    def sec_hdr(y, title):
        """Draw a grey section-header band with an all-caps label; returns the new y position."""
        d.rectangle([0, y, W, y + 72], fill=(240, 244, 248))
        d.text((54, y + 22), title, font=fnt(30, True), fill=TEXT2)
        return y + 72

    def toggle_row(y, title, subtitle, on=True, rh=148):
        """Draw a settings row with a title, optional subtitle, and a Material-style toggle; returns the new y position."""
        d.rectangle([0, y, W, y + rh], fill=CARD_BG)
        d.line([54, y + rh - 1, W - 54, y + rh - 1], fill=DIVIDER)
        d.text((54, y + 26), title, font=fnt(38, True), fill=TEXT1)
        if subtitle:
            d.text((54, y + 74), subtitle, font=fnt(30), fill=TEXT2)
        tx, ty = W - 140, y + rh // 2 - 22
        col = TEAL if on else DIVIDER
        rounded_rect(d, [tx, ty, tx + 100, ty + 44], r=22, fill=col)
        kx = tx + 56 if on else tx + 4
        d.ellipse([kx, ty + 4, kx + 36, ty + 40], fill=WHITE)
        return y + rh

    def link_row(y, title, rh=110):
        """Draw a settings row that acts as a navigation link (with a trailing chevron); returns the new y position."""
        d.rectangle([0, y, W, y + rh], fill=CARD_BG)
        d.line([54, y + rh - 1, W - 54, y + rh - 1], fill=DIVIDER)
        d.text((54, y + (rh - 38) // 2), title, font=fnt(38), fill=TEXT1)
        d.text((W - 70, y + (rh - 40) // 2), ">", font=fnt(40), fill=TEXT2)
        return y + rh

    y += 24
    y = sec_hdr(y, "VOICE")
    y = toggle_row(y, "Push-to-talk mode",
                   "Hold the PTT button to transmit instead of always-on", on=False)
    y += 24
    y = sec_hdr(y, "DISPLAY")
    y = toggle_row(y, "Keep screen on",
                   "Prevent the display from sleeping while in a room", on=True)
    y += 24
    y = sec_hdr(y, "PRIVACY")
    y = toggle_row(y, "Crash reporting",
                   "Send anonymised crash reports to help fix bugs (opt-in)", on=False)
    y = link_row(y, "Privacy policy")
    y = link_row(y, "Privacy & Security FAQ")
    y += 24
    y = sec_hdr(y, "ABOUT")
    y = link_row(y, "Version 1.0.0")
    y = link_row(y, "Open source licenses")

    nav_bar(d)
    img.save(os.path.join(OUT, "3.png"), "PNG", optimize=True)
    print("  3.png (Settings) saved")


# ──────────────────────────────────────────────────────────────
# Screenshot 4 — Privacy / "No internet, no servers"
# ──────────────────────────────────────────────────────────────
def make_privacy():
    """Render the privacy hero screen mockup and save to phoneScreenshots/4.png.

    Mirrors the third explainer page ("No internet, no account") to surface
    the app's strongest differentiator in the Play Store carousel.
    """
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    status_bar(d)
    # App bar
    d.rectangle([0, 80, W, 192], fill=BLUE)
    d.text((54, 108), "Frequency", font=fnt(52, True), fill=WHITE)
    d.text((W - 220, 122), "Private", font=fnt(30), fill=(180, 230, 255))
    y = 192

    # Hero band with cloud-off-style icon (crossed cloud over Wi-Fi arcs).
    # Tall enough to fit two 72-px headline lines below the rings without
    # spilling onto the white background.
    band_h = 780
    d.rectangle([0, y, W, y + band_h], fill=BLUE)
    cx, cy = W // 2, y + 280
    # Concentric rings (Wi-Fi-style) behind the cloud, low-opacity look
    for r in [180, 230, 280]:
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(180, 230, 255), width=3)
    # Cloud silhouette
    cw, ch = 280, 150
    d.rounded_rectangle([cx - cw // 2, cy - ch // 2 + 20,
                         cx + cw // 2, cy + ch // 2 + 20], radius=70, fill=WHITE)
    d.ellipse([cx - cw // 2 - 20, cy - 30, cx - cw // 2 + 100, cy + 60], fill=WHITE)
    d.ellipse([cx + cw // 2 - 100, cy - 50, cx + cw // 2 + 20, cy + 60], fill=WHITE)
    # Diagonal "no" slash through the cloud
    d.line([cx - cw // 2 - 60, cy - ch // 2 - 30,
            cx + cw // 2 + 60, cy + ch // 2 + 70],
           fill=RED_PTT, width=14)

    # Headline beneath the icon. The outer ring radius is 280 px from cy
    # (= y + 280), so the rings extend down to y + 560. Place the first
    # baseline at y + 565 to clear them.
    f72b = fnt(72, True)
    headline1 = "No internet,"
    headline2 = "no account."
    h1w = d.textlength(headline1, font=f72b)
    h2w = d.textlength(headline2, font=f72b)
    d.text((cx - int(h1w) // 2, y + 565), headline1, font=f72b, fill=WHITE)
    d.text((cx - int(h2w) // 2, y + 647), headline2, font=f72b, fill=WHITE)
    y += band_h

    # Body copy. Cache the font outside the loop — fnt() loads from disk
    # on every call.
    y += 60
    f36 = fnt(36)
    body_lines = [
        "Voice never leaves the devices.",
        "No server. No login. No cloud.",
        "Just Bluetooth and your microphone.",
    ]
    for line in body_lines:
        lw = d.textlength(line, font=f36)
        d.text((W // 2 - int(lw) // 2, y), line, font=f36, fill=TEXT1)
        y += 56

    # Privacy bullets. Same font-caching reasoning as the body copy above.
    y += 60
    f30b = fnt(30, True)
    f28 = fnt(28)
    bullets = [
        ("Voice", "End-to-end on Bluetooth LE — never uploaded."),
        ("Identity", "Random peer ID, generated on-device."),
        ("Telemetry", "Crash reports off by default; no audio, ever."),
    ]
    for label, text in bullets:
        rounded_rect(d, [32, y, W - 32, y + 110], r=16, fill=CARD_BG, outline=DIVIDER, width=1)
        d.text((54, y + 18), label, font=f30b, fill=BLUE)
        d.text((54, y + 60), text, font=f28, fill=TEXT2)
        y += 124

    nav_bar(d)
    img.save(os.path.join(OUT, "4.png"), "PNG", optimize=True)
    print("  4.png (Privacy) saved")


if __name__ == "__main__":
    print("Generating screenshots...")
    make_discovery()
    make_room()
    make_settings()
    make_privacy()
    print("Done.")
