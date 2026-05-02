"""
Generate three Play-Store phone screenshots for the Frequency app.
Dimensions: 1080 x 1920 (9:16, standard phone portrait)
Run: python3 scripts/gen_screenshots.py
"""
import math
import os
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

FONT_BD  = "C:/Windows/Fonts/segoeuib.ttf"
FONT_REG = "C:/Windows/Fonts/segoeui.ttf"

os.makedirs(OUT, exist_ok=True)


def fnt(size, bold=False):
    return ImageFont.truetype(FONT_BD if bold else FONT_REG, size)


def rounded_rect(draw, xy, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(xy, radius=r, fill=fill, outline=outline, width=width)


def status_bar(draw, y=0, h=80):
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
    draw.rectangle([0, H - 100, W, H], fill=(240, 240, 240))
    for i, ic in enumerate(["<", "O", "[]"]):
        nx = W // 4 * (i + 1)
        draw.text((nx - 16, H - 78), ic, font=fnt(36), fill=TEXT2)


def avatar(draw, cx, cy, r, color, initials):
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)
    f = fnt(r, True)
    tw = draw.textlength(initials, font=f)
    draw.text((cx - tw // 2, cy - r // 2 + 2), initials, font=f, fill=WHITE)


# ──────────────────────────────────────────────────────────────
# Screenshot 1 — Discovery
# ──────────────────────────────────────────────────────────────
def make_discovery():
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
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    status_bar(d)
    d.rectangle([0, 80, W, 192], fill=BLUE)
    d.text((54, 110), "Frequency  ·  98.7 MHz", font=fnt(46, True), fill=WHITE)
    d.text((W - 152, 122), "Leave", font=fnt(32, True), fill=(255, 200, 200))
    y = 192

    # Name chip
    y += 52
    nc = "Alex Chen  ·  You"
    ncw = d.textlength(nc, font=fnt(36))
    rounded_rect(d, [W // 2 - ncw // 2 - 30, y, W // 2 + ncw // 2 + 30, y + 64], r=32, fill=BLUE)
    d.text((W // 2 - ncw // 2, y + 14), nc, font=fnt(36), fill=WHITE)
    y += 90

    # Dial
    dial_cy = y + 380
    dial_r  = 260
    for r, alp in [(320, 25), (385, 15), (450, 8)]:
        ov  = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ovd = ImageDraw.Draw(ov)
        ovd.ellipse([W // 2 - r, dial_cy - r, W // 2 + r, dial_cy + r],
                    outline=(52, 152, 219, alp * 4), width=4)
        img = img.convert("RGBA")
        img = Image.alpha_composite(img, ov)
        img = img.convert("RGB")
    d = ImageDraw.Draw(img)
    d.ellipse([W // 2 - dial_r, dial_cy - dial_r, W // 2 + dial_r, dial_cy + dial_r],
              fill=WHITE, outline=DIVIDER, width=2)
    fw = d.textlength("98.7", font=fnt(80, True))
    d.text((W // 2 - fw // 2, dial_cy - 62), "98.7", font=fnt(80, True), fill=BLUE)
    mw = d.textlength("MHz", font=fnt(38))
    d.text((W // 2 - mw // 2, dial_cy + 36), "MHz", font=fnt(38), fill=TEXT2)

    # Peer chips
    orbit_r = 385
    for initials, pname, col, angle in [
        ("TR", "Taylor", PURPLE, -math.pi / 4),
        ("MK", "Morgan", GREEN,   math.pi + math.pi / 4),
    ]:
        px = int(W // 2 + orbit_r * math.cos(angle))
        py = int(dial_cy + orbit_r * math.sin(angle))
        d.ellipse([px - 56, py - 56, px + 56, py + 56], fill=col, outline=WHITE, width=4)
        avatar(d, px, py, 42, col, initials)
        pw = d.textlength(pname, font=fnt(30))
        d.text((px - pw // 2, py + 60), pname, font=fnt(30), fill=TEXT1)

    # PTT + mute
    ptt_cx, ptt_cy = W // 2, dial_cy + dial_r + 140
    d.ellipse([ptt_cx - 100, ptt_cy - 100, ptt_cx + 100, ptt_cy + 100], fill=RED_PTT)
    pw = d.textlength("PTT", font=fnt(36, True))
    d.text((ptt_cx - pw // 2, ptt_cy - 20), "PTT", font=fnt(36, True), fill=WHITE)

    mx, my = ptt_cx - 240, ptt_cy
    d.ellipse([mx - 60, my - 60, mx + 60, my + 60], fill=DARK_BLUE)
    mw2 = d.textlength("Mute", font=fnt(28))
    d.text((mx - mw2 // 2, my - 16), "Mute", font=fnt(28), fill=WHITE)

    nav_bar(d)
    img.save(os.path.join(OUT, "2.png"), "PNG", optimize=True)
    print("  2.png (Room) saved")


# ──────────────────────────────────────────────────────────────
# Screenshot 3 — Settings
# ──────────────────────────────────────────────────────────────
def make_settings():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    status_bar(d)
    d.rectangle([0, 80, W, 192], fill=BLUE)
    d.text((54, 110), "Settings", font=fnt(52, True), fill=WHITE)
    y = 192

    def sec_hdr(y, title):
        d.rectangle([0, y, W, y + 72], fill=(240, 244, 248))
        d.text((54, y + 22), title, font=fnt(30, True), fill=TEXT2)
        return y + 72

    def toggle_row(y, title, subtitle, on=True, rh=148):
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


if __name__ == "__main__":
    print("Generating screenshots...")
    make_discovery()
    make_room()
    make_settings()
    print("Done.")
