"""SilencerMoon: poster.png (512x512) and icon.png (128x128) of the mod, in the style of ZomBOT (Moon).

    python tools/silencermoon/poster.py mods/SilencerMoon <folder with Inter-SemiBold.woff and Inter-Regular.woff>

The Inter fonts (OFL) are in the zomboid-discord repository, src/zombot/fonts.
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

mod = Path(sys.argv[1])
fonts = Path(sys.argv[2])
tex = mod / "42" / "media" / "textures"
BG, FG, MUTED, COPPER = (18, 21, 29), (236, 238, 243), (150, 156, 170), (196, 122, 64)

def font(name, size):
    return ImageFont.truetype(str(fonts / name), size)

def moon(draw, cx, cy, r, color, bg):
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color)
    o = int(r * 0.55)
    draw.ellipse((cx - r + o, cy - r - int(r * 0.12), cx + r + o, cy + r - int(r * 0.12)), fill=bg)

def icon(name, size):
    return Image.open(tex / name).convert("RGBA").resize((size, size), Image.LANCZOS)

# poster 512x512
im = Image.new("RGB", (512, 512), BG)
d = ImageDraw.Draw(im)
moon(d, 256, 150, 110, (214, 218, 228), BG)
for i, name in enumerate(("Item_SilencerMoon_RifleCopper.png", "Item_SilencerMoon_RifleBallistic.png", "Item_SilencerMoon_OilFilter.png")):
    ic = icon(name, 150 if i < 2 else 120)
    x = (60, 190, 340)[i]
    y = 170 if i < 2 else 185
    im.paste(ic, (x, y), ic)
title = font("Inter-SemiBold.woff", 72)
w = d.textlength("SilencerMoon", font=title)
d.text(((512 - w) / 2, 330), "SilencerMoon", font=title, fill=FG)
d.rectangle((156, 430, 356, 434), fill=COPPER)
sub = font("Inter-Regular.woff", 30)
s = "Silenziatori artigianali"
d.text(((512 - d.textlength(s, font=sub)) / 2, 446), s, font=sub, fill=MUTED)
im.save(mod / "42" / "poster.png")

# icon 128x128
ic = Image.new("RGB", (128, 128), BG)
d = ImageDraw.Draw(ic)
moon(d, 64, 64, 50, (214, 218, 228), BG)
sup = icon("Item_SilencerMoon_RifleCopper.png", 96)
ic.paste(sup, (22, 26), sup)
ic.save(mod / "42" / "icon.png")
ic.save(mod / "icon.png")
print("ok")
