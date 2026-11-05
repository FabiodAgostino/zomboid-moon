"""The poster (512x512) and the icon (128x128) of Jukebox (Moon), drawn with shapes only: nobody else's image.

    python -m tools.jukebox.art
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

MOD = Path(__file__).resolve().parents[2] / "mods" / "JukeboxMoon"


def jukebox(size: int) -> Image.Image:
    s = size / 512
    image = Image.new("RGB", (size, size), (14, 16, 32))
    glow = Image.new("RGB", (size, size), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    g.ellipse((60 * s, 40 * s, 452 * s, 470 * s), fill=(120, 60, 150))
    image = Image.blend(image, glow.filter(ImageFilter.GaussianBlur(60 * s)), 0.55)
    d = ImageDraw.Draw(image)
    # the cabinet: an arch on a box
    d.rounded_rectangle((136 * s, 150 * s, 376 * s, 470 * s), radius=int(20 * s), fill=(120, 52, 30), outline=(250, 200, 90),
                        width=max(1, int(8 * s)))
    d.pieslice((136 * s, 40 * s, 376 * s, 280 * s), 180, 360, fill=(140, 62, 36), outline=(250, 200, 90),
               width=max(1, int(8 * s)))
    d.rectangle((144 * s, 156 * s, 368 * s, 170 * s), fill=(140, 62, 36))
    # the window with a CD
    d.pieslice((176 * s, 80 * s, 336 * s, 240 * s), 180, 360, fill=(255, 230, 150))
    d.rectangle((176 * s, 160 * s, 336 * s, 250 * s), fill=(255, 230, 150))
    d.ellipse((206 * s, 120 * s, 306 * s, 220 * s), fill=(200, 205, 220), outline=(60, 60, 80), width=max(1, int(4 * s)))
    d.ellipse((244 * s, 158 * s, 268 * s, 182 * s), fill=(255, 230, 150))
    # the speaker grille
    for i in range(6):
        y = (290 + i * 26) * s
        d.line((170 * s, y, 342 * s, y), fill=(250, 200, 90), width=max(1, int(6 * s)))
    # the moon
    d.ellipse((400 * s, 40 * s, 470 * s, 110 * s), fill=(245, 240, 210))
    d.ellipse((418 * s, 30 * s, 488 * s, 100 * s), fill=(30, 26, 52))
    return image


def main() -> None:
    poster = jukebox(512)
    poster.save(MOD / "42" / "poster.png", optimize=True)
    icon = jukebox(512).resize((128, 128), Image.LANCZOS)
    icon.save(MOD / "42" / "icon.png", optimize=True)
    icon.save(MOD / "icon.png", optimize=True)


if __name__ == "__main__":
    main()
