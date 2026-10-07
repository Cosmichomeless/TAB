"""Rebuild the README cover from committed screenshots and the real app icon.

Requires Pillow: python3 -m pip install Pillow
Run from the repository root: python3 docs/screenshots/build-showcase.py
"""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[2]
SHOTS = ROOT / "docs/screenshots"
ICON = ROOT / "App/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
SCREENS = ("02-groups.png", "03-group-detail.png")
LEFT = bytes.fromhex("145A7C")
RIGHT = bytes.fromhex("0B9486")

cover = Image.new("RGB", (1200, 560))
brush = ImageDraw.Draw(cover)
for x in range(1200):
    position = x / 1199
    brush.line((x, 0, x, 560), fill=tuple(
        round(start * (1 - position) + end * position)
        for start, end in zip(LEFT, RIGHT)
    ))

icon = Image.open(ICON).convert("RGB").resize((170, 170), Image.Resampling.LANCZOS)
icon_mask = Image.new("L", (170, 170), 0)
ImageDraw.Draw(icon_mask).rounded_rectangle((0, 0, 169, 169), radius=38, fill=255)
cover.paste(icon, (65, 190), icon_mask)

for name, x in zip(SCREENS, (285, 735)):
    source = Image.open(SHOTS / name).convert("RGB")
    focus = source.crop((40, 95, source.width - 40, 750))
    focus = focus.resize((390, 490), Image.Resampling.LANCZOS)
    card = Image.new("RGB", (400, 500), "white")
    card.paste(focus, (5, 5))
    mask = Image.new("L", card.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 399, 499), radius=22, fill=255)
    cover.paste(card, (x, 30), mask)

cover.quantize(colors=192, dither=Image.Dither.NONE).save(
    SHOTS / "00-showcase.png", optimize=True
)
