#!/usr/bin/env python3
"""Generate the section cover tiles for the Pitchfork Reviews plugin.

One committed source of truth (like the sibling ListenBrainz plugin's
make_covers.py): edit + re-run `python3 tools/make_covers.py` from the repo root,
then rebuild the zip. Don't hand-edit the PNGs — they're regenerated here.

Design: Pitchfork's own palette — a clean near-white card, the round Pitchfork
mark up top, a bold black title, and a red (#ef4035) accent bar along the bottom.
The mark source is the shipped app icon (PitchforkReviewsIcon.png), so the tiles
stay in sync with the logo. Tiles render as fixed cover art (not theme-recoloured),
so a light card stands out in Material's dark UI, matching Pitchfork's white site.
"""

import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG = os.path.join(ROOT, "PitchforkReviews", "HTML", "EN", "plugins",
                   "PitchforkReviews", "html", "images")

SIZE = 500
BG = (247, 247, 245, 255)      # near-white card
INK = (24, 24, 24, 255)        # near-black title
RED = (239, 64, 53, 255)       # Pitchfork mark red (#ef4035)
FONT = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

TILES = {
    "menu-best-new-music.png": "Best New Music",
    "menu-high-scoring-albums.png": "High Scoring Albums",
    "menu-latest-reviews.png": "Latest Reviews",
}


def font(size):
    try:
        return ImageFont.truetype(FONT, size)
    except OSError:
        return ImageFont.load_default()


def wrap(draw, text, fnt, maxw):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=fnt) <= maxw:
            cur = t
        else:
            if cur:
                lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def make(title, mark):
    im = Image.new("RGBA", (SIZE, SIZE), BG)
    d = ImageDraw.Draw(im)

    # mark, centred, upper third
    ms = 210
    m = mark.resize((ms, ms), Image.LANCZOS)
    im.alpha_composite(m, ((SIZE - ms) // 2, 60))

    # title, bold, centred below the mark, wrapped to <= 2 lines
    tf = font(58)
    lines = wrap(d, title, tf, SIZE - 60)
    asc, desc = tf.getmetrics()
    lh = asc + desc
    ty = 300
    for ln in lines:
        w = d.textlength(ln, font=tf)
        d.text(((SIZE - w) / 2, ty), ln, font=tf, fill=INK)
        ty += lh

    # red accent bar along the bottom
    d.rectangle([0, SIZE - 26, SIZE, SIZE], fill=RED)
    return im


def main():
    mark = Image.open(os.path.join(IMG, "PitchforkReviewsIcon.png")).convert("RGBA")
    for fname, title in TILES.items():
        make(title, mark).save(os.path.join(IMG, fname))
        print("wrote", fname)


if __name__ == "__main__":
    main()
