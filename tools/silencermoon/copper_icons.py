"""SilencerMoon: the copper icons, recoloured from the original suppressor icons (Pillow, no Blender).

Maps the luminance of each opaque pixel onto a copper ramp (shadow -> base -> highlight), keeping alpha. Writes
Item_SilencerMoon_Copper_9mm.png and Item_SilencerMoon_Copper_308.png, plus anteprima_icone.png, into OUT:

    python tools/silencermoon/copper_icons.py <folder with Item_SS_Suppressor_9mm.png and _308.png> OUT

The mod uses them as Item_SilencerMoon_PistolCopper.png and Item_SilencerMoon_RifleCopper.png.
"""
import sys
from pathlib import Path
from PIL import Image

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])

# copper gradient: shadow -> base -> highlight
STOPS = [(0.0, (46, 20, 8)), (0.45, (150, 78, 36)), (0.75, (196, 122, 64)), (1.0, (255, 214, 170))]

def ramp(t):
    t = max(0.0, min(1.0, t))
    for (a, ca), (b, cb) in zip(STOPS, STOPS[1:]):
        if t <= b:
            k = (t - a) / (b - a) if b > a else 0
            return tuple(round(ca[i] + (cb[i] - ca[i]) * k) for i in range(3))
    return STOPS[-1][1]

def copper(src, dst):
    im = Image.open(src).convert("RGBA")
    px = im.load()
    w, h = im.size
    lums = [0.299 * r + 0.587 * g + 0.114 * b for y in range(h) for x in range(w)
            for r, g, b, a in [px[x, y]] if a > 0]
    lo, hi = min(lums), max(lums)
    span = max(1.0, hi - lo)
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            t = (0.299 * r + 0.587 * g + 0.114 * b - lo) / span
            px[x, y] = ramp(t) + (a,)
    im.save(dst)
    return lo, hi

OUT.mkdir(parents=True, exist_ok=True)
for name in ("Item_SS_Suppressor_9mm.png", "Item_SS_Suppressor_308.png"):
    lo, hi = copper(SRC / name, OUT / name.replace("SS_Suppressor", "SilencerMoon_Copper"))
    print(name, "luminance", round(lo), round(hi))

# side by side preview: original vs copper
prev = Image.new("RGBA", (128 * 4 + 40, 128 + 20), (40, 40, 40, 255))
x = 10
for name, out in (("Item_SS_Suppressor_9mm.png", "Item_SilencerMoon_Copper_9mm.png"),
                  ("Item_SS_Suppressor_308.png", "Item_SilencerMoon_Copper_308.png")):
    for p in (SRC / name, OUT / out):
        prev.alpha_composite(Image.open(p).convert("RGBA"), (x, 10))
        x += 128
prev.save(OUT / "anteprima_icone.png")
