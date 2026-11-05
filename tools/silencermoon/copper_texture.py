"""SilencerMoon: the 32x32 copper texture of the 3D model (the original gunmetal one is a single colour).

    python tools/silencermoon/copper_texture.py <folder with SimpleSuppressorGunmetal.png> OUT
"""
import sys
from pathlib import Path
from PIL import Image
src, out = Path(sys.argv[1]), Path(sys.argv[2])
im = Image.open(src / "SimpleSuppressorGunmetal.png").convert("RGB")
print("gunmetal pixels:", sorted(set(im.getdata()))[:5])
cu = Image.new("RGB", im.size, (150, 88, 50))
cu.save(out / "SilencerMoonCopper.png")
tex = Image.new("RGB", (128 * 2 + 30, 148), (40, 40, 40))
tex.paste(im.resize((128, 128), Image.NEAREST), (10, 10))
tex.paste(cu.resize((128, 128), Image.NEAREST), (148, 10))
tex.save(out / "anteprima_texture.png")
