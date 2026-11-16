#!/usr/bin/env python3
"""
arbox_card.py — render new Arbox signups as a Telegram-ready image card.

Same Hebrew approach as the proven Ashkelon wave card (surf_card.py):
python-bidi shapes the string, Pillow draws it with
ImageFont.Layout.BASIC — do NOT use raqm (it applies its own bidi pass
and re-orders the already-visual string).

Usage:
    echo '[{"day":"Sunday","date":"16-11-2026","class":"CrossFit","time":"08:00"}]' \\
        | python3 arbox_card.py --out card.png --run-date "16.11.2026 15:03"
    python3 arbox_card.py --json '[...]' --out card.png
    python3 arbox_card.py --demo --out card.png   # 3 sample signups

Input items: {"day": English weekday, "date": "DD-MM-YYYY",
"class": class name, "time": "HH:MM"}.
Runs on ubuntu-latest with DejaVu fonts + pip pillow/python-bidi only.
"""

import argparse
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

W = 1080
MARGIN = 56

_FONT_PATHS = {
    # DejaVu first: covers Hebrew + Latin + digits, ships on ubuntu-latest.
    "bold": [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansHebrew-Bold.ttf",
    ],
    "regular": [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansHebrew-Regular.ttf",
    ],
}

_font_cache = {}


def _font(size, bold=False):
    key = (size, bold)
    if key in _font_cache:
        return _font_cache[key]
    kind = "bold" if bold else "regular"
    for path in _FONT_PATHS[kind]:
        if os.path.exists(path):
            # BASIC layout is essential: Pillow's default (raqm) applies its
            # own bidi pass and re-orders the string that hb() already put
            # in visual order — undoing the RTL fix. BASIC draws the glyphs
            # exactly in the order given (Hebrew needs no joining).
            f = ImageFont.truetype(path, size, layout_engine=ImageFont.Layout.BASIC)
            _font_cache[key] = f
            return f
    f = ImageFont.load_default()
    _font_cache[key] = f
    return f


def hb(text):
    """Reorder a Hebrew (possibly mixed) string for display."""
    try:
        from bidi.algorithm import get_display
        return get_display(str(text), base_dir="R")
    except Exception:
        return str(text)


DOW_HE = {
    "Sunday": "ראשון",
    "Monday": "שני",
    "Tuesday": "שלישי",
    "Wednesday": "רביעי",
    "Thursday": "חמישי",
    "Friday": "שישי",
    "Saturday": "שבת",
}

GREEN = (34, 197, 94)
GREEN_DARK = (21, 128, 61)
SUB = (165, 195, 205)
WHITE = (255, 255, 255)
AMBER = (255, 217, 168)


def _gradient(size):
    """Vertical dark navy -> deep green gradient."""
    top = (13, 27, 46)
    bot = (8, 46, 36)
    img = Image.new("RGB", size)
    px = img.load()
    h = size[1]
    for y in range(h):
        t = y / h
        c = tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        for x in range(size[0]):
            px[x, y] = c
    return img


def _gradient_color(y, h):
    """Gradient color at height y (same interpolation as _gradient)."""
    top = (13, 27, 46)
    bot = (8, 46, 36)
    t = y / h
    return tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3))


def _row_fill(y, h):
    """Solid row fill: ~12% white pre-blended over the local gradient color.

    Must be SOLID: ImageDraw on an RGBA image does not alpha-blend shapes,
    it writes RGBA values raw and convert("RGB") drops the alpha — a
    translucent white fill comes out solid white and hides white text.
    """
    base = _gradient_color(y, h)
    return tuple(round(base[i] * 0.88 + 255 * 0.12) for i in range(3))


def _lines(img):
    """Subtle white diagonal motion lines."""
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    for row in range(10):
        y0 = 30 + row * 110
        pts = [(x, y0 + 8 * math.sin(x / 120.0 + row)) for x in range(0, W + 20, 20)]
        d.line(pts, fill=(255, 255, 255, 12), width=3)
    return Image.alpha_composite(img.convert("RGBA"), overlay)


def _text_right(d, x_right, y, s, font, fill):
    d.text((x_right, y), hb(s), font=font, fill=fill, anchor="ra")


def _text_center(d, x_center, y, s, font, fill):
    d.text((x_center, y), hb(s), font=font, fill=fill, anchor="ma")


def _fmt_date(date_str):
    """DD-MM-YYYY -> D.M.YYYY (drops a leading zero on the day)."""
    try:
        dd, mm, yyyy = date_str.split("-")
        return f"{int(dd)}.{mm}.{yyyy}"
    except Exception:
        return date_str


def build_card(signups, out_path="card.png", run_date=None):
    """Render the card. signups: list of {day, date, class, time} dicts."""
    n = len(signups)
    row_h = 118
    h = max(640, 400 + n * row_h + 90)
    img = _lines(_gradient((W, h)))
    d = ImageDraw.Draw(img, "RGBA")
    right = W - MARGIN
    left = MARGIN

    # ---- header: green check circle + title ----
    d.ellipse([right - 96, 56, right, 152], fill=GREEN)
    d.text(((right - 96 + right) / 2, 62), "✓", font=_font(64, bold=True),
           fill=WHITE, anchor="ma")
    _text_right(d, right - 122, 66, "נרשמת!", _font(64, bold=True), WHITE)
    _text_right(d, right, 152, "Arbox · שיעורי בוקר", _font(30, bold=True), SUB)

    # ---- count line ----
    count_text = "שיעור אחד חדש" if n == 1 else f"{n} שיעורים חדשים"
    _text_right(d, right, 222, count_text, _font(34, bold=True), AMBER)

    # ---- signup rows ----
    y = 300
    for s in signups:
        dow = DOW_HE.get(s.get("day", ""), s.get("day", ""))
        line = f"{dow} · {_fmt_date(s.get('date', ''))} · {s.get('class', '')} · {s.get('time', '')}"
        d.rounded_rectangle([left, y, right, y + row_h - 16], radius=18,
                            fill=_row_fill(y + (row_h - 16) // 2, h))
        _text_right(d, right - 28, y + 22, line, _font(34, bold=True), WHITE)
        y += row_h

    # ---- footer ----
    footer_y = h - 64
    _text_right(d, right, footer_y, "Arbox Auto-Signup", _font(24), SUB)
    if run_date:
        # Shape it like every other string: raw Hebrew renders reversed.
        d.text((left, footer_y), hb(run_date), font=_font(24), fill=SUB, anchor="la")

    img.convert("RGB").save(out_path, "PNG")
    return out_path


def _load_signups(args):
    if args.json:
        return json.loads(args.json)
    data = sys.stdin.read()
    if not data.strip():
        raise SystemExit("arbox_card.py: no signup JSON on stdin (use --json or pipe it in)")
    return json.loads(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Render an Arbox signup card.")
    parser.add_argument("--json", default=None, help="signup JSON array")
    parser.add_argument("--out", default="card.png")
    parser.add_argument("--run-date", default=None, help="footer stamp, e.g. 16.11.2026 15:03")
    parser.add_argument("--demo", action="store_true", help="render 3 sample signups")
    args = parser.parse_args()

    if args.demo:
        demo = [
            {"day": "Sunday", "date": "16-11-2026", "class": "CrossFit", "time": "08:00"},
            {"day": "Monday", "date": "17-11-2026", "class": "CrossFit", "time": "08:00"},
            {"day": "Friday", "date": "20-11-2026", "class": "Fuck You Friday", "time": "08:00"},
        ]
        build_card(demo, out_path=args.out, run_date=args.run_date or "דוגמה")
    else:
        build_card(_load_signups(args), out_path=args.out, run_date=args.run_date)
    print(f"wrote {args.out}")
