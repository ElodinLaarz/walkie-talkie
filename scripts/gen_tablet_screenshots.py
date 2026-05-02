"""
Generate Play-Store 7-inch and 10-inch tablet screenshots for the Frequency app.

All pixel measurements are derived by multiplying the phone reference geometry
(1080 px wide) by a canvas-specific scale factor, so layouts look proportional
across densities without hard-coding per-device constants.

Output directories (created automatically):
  fastlane/metadata/android/en-US/images/sevenInchScreenshots/  1.png, 2.png
  fastlane/metadata/android/en-US/images/tenInchScreenshots/    1.png, 2.png

Dimensions:
  7-inch : 1200 x 1920 px  (portrait, 5:8, scale 1.11x)
  10-inch: 1600 x 2560 px  (portrait, 5:8, scale 1.48x)

Run: python3 scripts/gen_tablet_screenshots.py
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

FONT_BD  = "C:/Windows/Fonts/segoeuib.ttf"
FONT_REG = "C:/Windows/Fonts/segoeui.ttf"

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

BASE_W = 1080   # phone reference width (for scaling)

# ── Helpers (all size-aware via the scale parameter) ─────────────────────────

def fnt(size, bold=False, scale=1.0):
    """Return a Pillow ImageFont scaled to the canvas width."""
    return ImageFont.truetype(FONT_BD if bold else FONT_REG, max(10, int(size * scale)))


def s(value, scale):
    """Scale an integer pixel value to the target canvas size."""
    return int(value * scale)


def rounded_rect(draw, xy, r, fill=None, outline=None, width=1):
    """Draw a rounded rectangle; thin wrapper around draw.rounded_rectangle."""
    draw.rounded_rectangle(xy, radius=r, fill=fill, outline=outline, width=width)


def status_bar(draw, W, scale, y=0):
    """Draw a blue Android-style status bar with time, signal bars, and battery icon."""
    h = s(80, scale)
    draw.rectangle([0, y, W, y + h], fill=BLUE)
    draw.text((s(50, scale), y + (h - s(34, scale)) // 2 + 2),
              "9:41", font=fnt(34, True, scale), fill=WHITE)
    bx = W - s(130, scale)
    by = y + h // 2 - s(14, scale)
    bw, bh = s(52, scale), s(28, scale)
    draw.rounded_rectangle([bx, by, bx + bw, by + bh], radius=4, outline=WHITE, width=3)
    draw.rectangle([bx + 2, by + 2, bx + bw - 10, by + bh - 2], fill=WHITE)
    draw.rectangle([bx + bw, by + s(9, scale), bx + bw + s(6, scale), by + s(19, scale)], fill=WHITE)
    sx = W - s(220, scale)
    sy = y + h // 2 + s(10, scale)
    for i, hb in enumerate([8, 14, 20, 26]):
        bw2 = s(8, scale)
        bx2 = sx + i * s(12, scale)
        draw.rectangle([bx2, sy - s(hb, scale), bx2 + bw2, sy], fill=WHITE)
    return h   # returns bar height so callers can offset y


def nav_bar(draw, W, H, scale):
    """Draw the Android three-button navigation bar at the bottom of the canvas."""
    nh = s(100, scale)
    draw.rectangle([0, H - nh, W, H], fill=(240, 240, 240))
    for i, ic in enumerate(["<", "O", "[]"]):
        nx = W // 4 * (i + 1)
        draw.text((nx - s(16, scale), H - nh + s(14, scale)),
                  ic, font=fnt(36, False, scale), fill=TEXT2)


def avatar(draw, cx, cy, r, color, initials, scale):
    """Draw a circular avatar chip at (cx, cy) with radius r, background color, and initials."""
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)
    f = fnt(r, True, 1.0)   # r is already scaled at call site
    tw = draw.textlength(initials, font=f)
    draw.text((cx - int(tw // 2), cy - r // 2 + 2), initials, font=f, fill=WHITE)


# ── Screen generators ────────────────────────────────────────────────────────

def make_discovery(W, H, scale):
    """
    Render the Discovery screen mockup at canvas size W x H.

    Returns the resulting PIL Image.
    """
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    sb_h = status_bar(d, W, scale)
    y = sb_h

    # App bar
    ab_h = s(112, scale)
    d.rectangle([0, y, W, y + ab_h], fill=BLUE)
    d.text((s(54, scale), y + s(28, scale)), "Frequency",
           font=fnt(52, True, scale), fill=WHITE)
    scan_text = "● Scanning"
    st_w = d.textlength(scan_text, font=fnt(30, False, scale))
    d.text((W - int(st_w) - s(54, scale), y + s(36, scale)),
           scan_text, font=fnt(30, False, scale), fill=(180, 230, 255))
    y += ab_h

    # Hero section
    hero_h = s(320, scale)
    d.rectangle([0, y, W, y + hero_h], fill=BLUE)
    d.text((s(54, scale), y + s(32, scale)), "TUNING THE DIAL",
           font=fnt(30, False, scale), fill=(180, 230, 255))
    d.text((s(54, scale), y + s(76, scale)), "Phones around you,",
           font=fnt(52, True, scale), fill=WHITE)
    d.text((s(54, scale), y + s(140, scale)), "on the same wavelength.",
           font=fnt(52, True, scale), fill=WHITE)
    rcx = W - s(150, scale)
    rcy = y + hero_h // 2
    for r in [s(45, scale), s(80, scale), s(115, scale)]:
        d.ellipse([rcx - r, rcy - r, rcx + r, rcy + r], outline=WHITE, width=2)
    dot_r = s(18, scale)
    d.ellipse([rcx - dot_r, rcy - dot_r, rcx + dot_r, rcy + dot_r], fill=WHITE)
    y += hero_h

    # Nearby section
    y += s(32, scale)
    d.text((s(54, scale), y), "NEARBY", font=fnt(30, True, scale), fill=TEXT2)
    y += s(46, scale)

    sessions = [
        ("AC", "Alex Chen",   "98.7 MHz",  BLUE),
        ("TR", "Taylor Room", "104.3 MHz", PURPLE),
        ("MK", "Morgan K.",   "91.5 MHz",  GREEN),
    ]
    rh = s(140, scale)
    av_r = s(38, scale)
    pad = s(32, scale)
    for initials, name, freq, col in sessions:
        d.rectangle([pad, y, W - pad, y + rh], fill=CARD_BG, outline=DIVIDER, width=1)
        cx = pad + s(62, scale)
        avatar(d, cx, y + rh // 2, av_r, col, initials, scale)
        d.text((s(156, scale), y + s(26, scale)), name,
               font=fnt(38, True, scale), fill=TEXT1)
        d.text((s(156, scale), y + s(72, scale)),
               "Frequency Session  ·  On " + freq,
               font=fnt(30, False, scale), fill=TEXT2)
        bw, bh = s(180, scale), s(62, scale)
        bx0 = W - pad - s(20, scale) - bw
        by0 = y + (rh - bh) // 2
        rounded_rect(d, [bx0, by0, bx0 + bw, by0 + bh], r=s(31, scale), fill=BLUE)
        btw = d.textlength("Tune in", font=fnt(30, True, scale))
        d.text((bx0 + (bw - int(btw)) // 2, by0 + s(16, scale)),
               "Tune in", font=fnt(30, True, scale), fill=WHITE)
        y += rh + s(8, scale)

    # Start card
    sc_h = s(140, scale)
    sc_y = H - s(100, scale) - s(24, scale) - sc_h
    d.rectangle([pad, sc_y, W - pad, sc_y + sc_h],
                fill=CARD_BG, outline=DIVIDER, width=1)
    d.text((s(54, scale), sc_y + s(20, scale)),
           "+ Start a new Frequency", font=fnt(44, True, scale), fill=BLUE)
    d.text((s(54, scale), sc_y + s(80, scale)),
           "A fresh channel will be broadcast at 107.2 MHz",
           font=fnt(30, False, scale), fill=TEXT2)

    nav_bar(d, W, H, scale)
    return img


def make_room(W, H, scale):
    """
    Render the Frequency Room screen mockup at canvas size W x H.

    Returns the resulting PIL Image.
    """
    img = Image.new("RGB", (W, H), BG)

    # We need RGBA compositing for the pulse rings
    sb_h = status_bar(ImageDraw.Draw(img), W, scale)
    d = ImageDraw.Draw(img)
    y = sb_h

    # App bar
    ab_h = s(112, scale)
    d.rectangle([0, y, W, y + ab_h], fill=BLUE)
    d.text((s(54, scale), y + s(26, scale)),
           "Frequency  ·  98.7 MHz", font=fnt(46, True, scale), fill=WHITE)
    leave_w = d.textlength("Leave", font=fnt(32, True, scale))
    d.text((W - int(leave_w) - s(54, scale), y + s(36, scale)),
           "Leave", font=fnt(32, True, scale), fill=(255, 200, 200))
    y += ab_h

    # Name chip
    y += s(52, scale)
    nc = "Alex Chen  ·  You"
    ncw = d.textlength(nc, font=fnt(36, False, scale))
    chip_pad = s(30, scale)
    chip_h = s(64, scale)
    cx0 = W // 2 - int(ncw) // 2 - chip_pad
    cx1 = W // 2 + int(ncw) // 2 + chip_pad
    rounded_rect(d, [cx0, y, cx1, y + chip_h], r=s(32, scale), fill=BLUE)
    d.text((W // 2 - int(ncw) // 2, y + s(14, scale)),
           nc, font=fnt(36, False, scale), fill=WHITE)
    y += chip_h + s(30, scale)

    # Central dial
    dial_r  = s(260, scale)
    dial_cy = y + dial_r + s(80, scale)

    for r, alp in [(s(320, scale), 25), (s(385, scale), 15), (s(450, scale), 8)]:
        ov  = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ovd = ImageDraw.Draw(ov)
        ovd.ellipse([W // 2 - r, dial_cy - r, W // 2 + r, dial_cy + r],
                    outline=(52, 152, 219, alp * 4), width=4)
        img = img.convert("RGBA")
        img = Image.alpha_composite(img, ov)
        img = img.convert("RGB")
    d = ImageDraw.Draw(img)

    d.ellipse([W // 2 - dial_r, dial_cy - dial_r,
               W // 2 + dial_r, dial_cy + dial_r],
              fill=WHITE, outline=DIVIDER, width=2)
    freq_f = fnt(80, True, scale)
    fw = d.textlength("98.7", font=freq_f)
    d.text((W // 2 - int(fw) // 2, dial_cy - s(62, scale)), "98.7",
           font=freq_f, fill=BLUE)
    mhz_f = fnt(38, False, scale)
    mw = d.textlength("MHz", font=mhz_f)
    d.text((W // 2 - int(mw) // 2, dial_cy + s(36, scale)), "MHz",
           font=mhz_f, fill=TEXT2)

    # Peer chips
    orbit_r = s(385, scale)
    av_r    = s(42, scale)
    for initials, pname, col, angle in [
        ("TR", "Taylor", PURPLE, -math.pi / 4),
        ("MK", "Morgan", GREEN,   math.pi + math.pi / 4),
    ]:
        px = int(W // 2 + orbit_r * math.cos(angle))
        py = int(dial_cy + orbit_r * math.sin(angle))
        ring_r = av_r + s(14, scale)
        d.ellipse([px - ring_r, py - ring_r, px + ring_r, py + ring_r],
                  fill=col, outline=WHITE, width=4)
        avatar(d, px, py, av_r, col, initials, scale)
        pnf = fnt(30, False, scale)
        pw  = d.textlength(pname, font=pnf)
        d.text((px - int(pw) // 2, py + ring_r + s(6, scale)),
               pname, font=pnf, fill=TEXT1)

    # PTT + Mute
    ptt_cx = W // 2
    ptt_cy = dial_cy + dial_r + s(140, scale)
    ptt_r  = s(100, scale)
    d.ellipse([ptt_cx - ptt_r, ptt_cy - ptt_r,
               ptt_cx + ptt_r, ptt_cy + ptt_r], fill=RED_PTT)
    ptf = fnt(36, True, scale)
    ptw = d.textlength("PTT", font=ptf)
    d.text((ptt_cx - int(ptw) // 2, ptt_cy - s(20, scale)),
           "PTT", font=ptf, fill=WHITE)

    mute_r = s(60, scale)
    mx, my = ptt_cx - s(240, scale), ptt_cy
    d.ellipse([mx - mute_r, my - mute_r, mx + mute_r, my + mute_r], fill=DARK_BLUE)
    muf = fnt(28, False, scale)
    muw = d.textlength("Mute", font=muf)
    d.text((mx - int(muw) // 2, my - s(16, scale)), "Mute", font=muf, fill=WHITE)

    nav_bar(d, W, H, scale)
    return img


# ── Entry point ──────────────────────────────────────────────────────────────

SIZES = {
    "sevenInchScreenshots":  (1200, 1920),
    "tenInchScreenshots":    (1600, 2560),
}


def main():
    """Generate 7-inch and 10-inch tablet screenshots for the Play Store."""
    base_dir = "fastlane/metadata/android/en-US/images"

    for folder, (W, H) in SIZES.items():
        out_dir = os.path.join(base_dir, folder)
        os.makedirs(out_dir, exist_ok=True)
        scale = W / BASE_W

        # Screenshot 1 — Discovery
        img = make_discovery(W, H, scale)
        img.save(os.path.join(out_dir, "1.png"), "PNG", optimize=True)
        print(f"  {folder}/1.png  ({W}x{H}, scale={scale:.2f}x)  saved")

        # Screenshot 2 — Room
        img = make_room(W, H, scale)
        img.save(os.path.join(out_dir, "2.png"), "PNG", optimize=True)
        print(f"  {folder}/2.png  ({W}x{H}, scale={scale:.2f}x)  saved")

    print("Done.")


if __name__ == "__main__":
    main()
