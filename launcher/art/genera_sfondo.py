"""Draws the launcher's background and icon from nothing but code and a fixed random seed.

Nothing is taken from the game or from the internet: every pixel comes from the noise and the shapes below,
so the images belong to Moon like the rest of the repo. Run it again after a change:

    python launcher/art/genera_sfondo.py

It writes into launcher/Assets: the night sky with the moon (cielo.jpg), the clouds that pass in front of it
(nuvole.png), the hills and the trees (colline.png), the field with the road and the zombies (terra.png), the fog
(nebbia.png), the moon of the logo and of the icon (luna.png, moon.ico) and the splash (splash.png). The launcher moves the layers one over
the other: the clouds and the fog are seamless left to right, so they can scroll forever.
"""

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "Assets"
W, H = 1920, 1140                   # 1.5 times the 1280x760 window
SS = 3                              # silhouettes are drawn 3 times bigger, then scaled down: smooth edges
HORIZON = int(H * 0.70)
MOON_X, MOON_Y, MOON_R = int(W * 0.600), int(H * 0.235), int(H * 0.128)
ROAD_VP = (int(W * 0.565), HORIZON + 14)   # where the road disappears


# ---------------------------------------------------------------------------------------------------------------------
# noise and colour helpers

def noise2(h, w, beta, seed, sx=1.0, sy=1.0):
    """Fractal noise from filtered white noise: it tiles seamlessly in both directions."""
    rng = np.random.default_rng(seed)
    spectrum = np.fft.fft2(rng.standard_normal((h, w)))
    fy = np.fft.fftfreq(h)[:, None] * sy
    fx = np.fft.fftfreq(w)[None, :] * sx
    f = np.sqrt(fx * fx + fy * fy)
    f[0, 0] = 1.0
    spectrum /= f ** beta
    spectrum[0, 0] = 0
    n = np.real(np.fft.ifft2(spectrum))
    return (n - n.mean()) / n.std()


def noise1(n, beta, seed):
    rng = np.random.default_rng(seed)
    spectrum = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n)
    f[0] = 1.0
    spectrum /= f ** beta
    spectrum[0] = 0
    x = np.fft.irfft(spectrum, n)
    return (x - x.mean()) / x.std()


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def gradient(stops, t):
    """Colours along t (0..1): stops is a list of (position, (r, g, b))."""
    pos = np.array([s[0] for s in stops])
    cols = np.array([s[1] for s in stops], dtype=np.float64)
    out = np.empty(t.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(t, pos, cols[:, c])
    return out


def blur(a, sigma):
    """Gaussian blur of a 2D float array, as two passes of shifted copies."""
    r = int(math.ceil(sigma * 3))
    k = np.exp(-(np.arange(-r, r + 1) ** 2) / (2 * sigma * sigma))
    k /= k.sum()
    for axis in (0, 1):
        padded = np.pad(a, [(r, r) if ax == axis else (0, 0) for ax in (0, 1)], mode="edge")
        n = a.shape[axis]
        a = sum(w * np.take(padded, np.arange(i, i + n), axis=axis) for i, w in enumerate(k))
    return a


def save_rgb(rgb, name, quality=92):
    Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB").save(OUT / name, quality=quality, optimize=True)


def save_rgba(rgb, alpha, name):
    a = np.clip(alpha, 0, 1)
    data = np.dstack([np.clip(rgb, 0, 255), a * 255]).astype(np.uint8)
    Image.fromarray(data, "RGBA").save(OUT / name, optimize=True)


# ---------------------------------------------------------------------------------------------------------------------
# the moon

def moon_disc(r, seed, light=(-0.55, -0.45)):
    """The moon as RGB and alpha arrays of (2r+8) pixels, lit a little from the upper left."""
    size = 2 * r + 8
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float64)
    xx -= size / 2 - 0.5
    yy -= size / 2 - 0.5
    d = np.sqrt(xx * xx + yy * yy) / r
    alpha = np.clip((1 - d) * r + 0.5, 0, 1)

    maria = blur(smoothstep(0.35, 1.7, noise2(size, size, 3.2, seed)), r * 0.02 + 0.5)
    albedo = 1.0 - 0.22 * maria + noise2(size, size, 1.4, seed + 1) * 0.018

    rng = np.random.default_rng(seed + 2)
    lx, ly = light
    for _ in range(int(r * 0.30)):
        cr = r * (rng.random() ** 2.4 * 0.15 + 0.015)
        a = rng.random() * math.tau
        rad = math.sqrt(rng.random()) * r * 0.93
        cx, cy = math.cos(a) * rad, math.sin(a) * rad
        dx, dy = (xx - cx) / cr, (yy - cy) / cr
        dd = np.sqrt(dx * dx + dy * dy)
        facing = np.clip(-(dx * lx + dy * ly) / np.maximum(dd, 1e-6), -1, 1)
        albedo -= smoothstep(1.05, 0.85, dd) * (0.035 + 0.03 * facing * (dd > 0.55))
        albedo += np.exp(-((dd - 1.0) / 0.16) ** 2) * (0.02 + 0.035 * facing)

    # one young bright crater with rays, like Tycho
    tx, ty = -0.32 * r, 0.52 * r
    ang = np.arctan2(yy - ty, xx - tx)
    tdist = np.sqrt((xx - tx) ** 2 + (yy - ty) ** 2)
    rays = (np.cos(ang * 9) ** 8 + np.cos(ang * 14 + 1.3) ** 10) * np.exp(-tdist / (r * 0.6))
    albedo += rays * 0.03 + np.exp(-(tdist / (r * 0.04)) ** 2) * 0.12

    z = np.sqrt(np.clip(1 - d * d, 0, 1))
    shade = 0.66 + 0.34 * z ** 0.5
    lum = np.clip(albedo, 0, 1.1) * shade
    base = np.array([238, 233, 218], dtype=np.float64)
    rgb = lum[..., None] * base[None, None, :]
    rgb[..., 2] += (1 - z) * 18          # the edge goes a little blue
    return rgb, alpha


# ---------------------------------------------------------------------------------------------------------------------
# the sky

def sky():
    y = np.linspace(0, 1, H)[:, None] * np.ones((1, W))
    x = np.ones((H, 1)) * np.linspace(0, 1, W)[None, :]
    hz = HORIZON / H
    rgb = gradient([(0.00, (3, 5, 11)), (0.30, (7, 12, 25)), (0.55, (14, 24, 42)),
                    (hz - 0.04, (30, 44, 60)), (hz, (46, 60, 72)), (1.0, (20, 26, 34))], y)

    # far away a town is burning: an orange glow on the horizon, on the right and, weaker, on the left
    rgb += np.exp(-(((x - 0.94) / 0.20) ** 2 + ((y - hz) / 0.075) ** 2))[..., None] * np.array([86, 34, 10])
    rgb += np.exp(-(((x - 0.05) / 0.16) ** 2 + ((y - hz) / 0.05) ** 2))[..., None] * np.array([44, 20, 8])

    # a thin, high veil that catches the moonlight
    veil = smoothstep(0.2, 1.8, noise2(H, W, 1.8, 7, sx=0.35, sy=1.6))
    px = np.arange(W)[None, :]
    py = np.arange(H)[:, None]
    dist = np.sqrt((px - MOON_X) ** 2 + (py - MOON_Y) ** 2)
    out = np.maximum(dist - MOON_R, 0)
    glow = (np.exp(-out / (MOON_R * 0.45)) * 0.60 + np.exp(-out / (MOON_R * 2.2)) * 0.32
            + np.exp(-dist / (MOON_R * 8.0)) * 0.20)
    rgb += glow[..., None] * np.array([118, 142, 182])
    rgb += (veil * (0.25 + glow * 1.4))[..., None] * np.array([22, 28, 38])

    # stars: fewer near the horizon and next to the moon
    rng = np.random.default_rng(11)
    stars = np.zeros((H, W))
    n = 1700
    sx = rng.integers(0, W, n)
    sy = (rng.random(n) ** 1.25 * HORIZON).astype(int)
    stars[sy, sx] = 0.15 + rng.random(n) ** 7 * 1.6
    fade = smoothstep(hz, hz - 0.30, y) * (1 - np.clip(glow * 1.6, 0, 1))
    small = blur(stars, 0.6) * 5.0
    big = blur(np.where(stars > 0.9, stars, 0), 2.2) * 9.0
    twinkle = (small + big) * fade
    rgb += twinkle[..., None] * np.array([210, 220, 255])

    # the moon
    mrgb, malpha = moon_disc(MOON_R, 3)
    s = mrgb.shape[0]
    x0, y0 = MOON_X - s // 2, MOON_Y - s // 2
    region = rgb[y0:y0 + s, x0:x0 + s]
    a = malpha[..., None]
    region[:] = region * (1 - a) + mrgb * a

    # a very light grain, so the gradients do not band
    rgb += noise2(H, W, 0.0, 5)[..., None] * 1.6
    return rgb


# ---------------------------------------------------------------------------------------------------------------------
# clouds and fog: seamless left to right

def clouds():
    """Long thin streaks of cloud, eaten away by noise, with a silver top where the moon lights them."""
    h = int(H * 0.62)
    rng = np.random.default_rng(21)
    xx = np.arange(W)[None, :].astype(np.float64)
    yy = np.arange(h)[:, None].astype(np.float64)
    dens = np.zeros((h, W))
    for _ in range(26):
        cx = rng.uniform(0, W)
        cy = rng.uniform(0.10, 0.70) * h
        length = rng.uniform(220, 760)
        thick = rng.uniform(10, 34)
        slope = rng.uniform(-0.03, 0.03)
        dx = (xx - cx + W / 2) % W - W / 2            # wraps around: the layer stays seamless
        dens += (np.exp(-2.2 * (dx / length) ** 2) * np.exp(-((yy - cy - dx * slope) / thick) ** 2)
                 * rng.uniform(0.55, 1.0))
    erosion = noise2(h, W, 1.9, 23, sx=0.35, sy=1.0)
    dens *= smoothstep(-1.4, 0.9, erosion)
    dens = np.clip(dens, 0, 1.3)
    dens *= smoothstep(1.0, 0.80, yy / h)
    lit = np.clip(blur(dens - np.roll(dens, 6, axis=0), 1.5), 0, 1) * 0.9
    alpha = np.clip(smoothstep(0.04, 1.1, dens) * 0.78 + lit * 0.12, 0, 0.85)
    rgb = np.empty((h, W, 3))
    rgb[:] = np.array([30, 38, 55])
    rgb += lit[..., None] * np.array([120, 134, 164])
    return rgb, alpha


def fog():
    h = int(H * 0.40)
    n = noise2(h, W, 2.1, 31, sx=0.22, sy=1.0)
    yy = np.linspace(0, 1, h)[:, None]
    band = np.exp(-((yy - 0.45) / 0.26) ** 2)
    dens = smoothstep(-0.6, 1.6, n) * band
    rgb = np.empty((h, W, 3))
    rgb[:] = np.array([128, 146, 170])
    return rgb, dens * 0.55


# ---------------------------------------------------------------------------------------------------------------------
# silhouettes, drawn on a big mask

class Mask:
    def __init__(self):
        self.img = Image.new("L", (W * SS, H * SS), 0)
        self.d = ImageDraw.Draw(self.img)

    def poly(self, pts, fill=255):
        self.d.polygon([(px * SS, py * SS) for px, py in pts], fill=fill)

    def ellipse(self, cx, cy, rx, ry, fill=255):
        self.d.ellipse([(cx - rx) * SS, (cy - ry) * SS, (cx + rx) * SS, (cy + ry) * SS], fill=fill)

    def line(self, pts, width, fill=255):
        p = [(px * SS, py * SS) for px, py in pts]
        w = max(1, int(round(width * SS)))
        self.d.line(p, fill=fill, width=w, joint="curve")
        r = width * SS / 2
        for qx, qy in p:
            self.d.ellipse([qx - r, qy - r, qx + r, qy + r], fill=fill)

    def array(self):
        small = self.img.resize((W, H), Image.LANCZOS)
        return np.asarray(small, dtype=np.float64) / 255.0


def ridge(x0, x1, base, amp, beta, seed, step=1):
    xs = np.arange(x0, x1 + 1, step)
    n = noise1(len(xs), beta, seed)
    return [(float(px), float(base - amp * v)) for px, v in zip(xs, n)]


def tree_blob(m, rng, x, ground, height):
    """A deciduous tree: a trunk and a crown of overlapping lumps."""
    m.line([(x, ground), (x + rng.uniform(-2, 2), ground - height * 0.45)], max(1.5, height * 0.06))
    cy = ground - height * 0.62
    for _ in range(9):
        rx = height * rng.uniform(0.16, 0.30)
        m.ellipse(x + rng.uniform(-0.28, 0.28) * height, cy + rng.uniform(-0.30, 0.22) * height, rx, rx * 0.9)


def tree_pine(m, rng, x, ground, height):
    m.line([(x, ground), (x, ground - height)], max(1.2, height * 0.04))
    layers = 6
    for i in range(layers):
        t = i / layers
        w = height * (0.30 - 0.22 * t) * rng.uniform(0.85, 1.15)
        y = ground - height * (0.18 + 0.80 * t)
        m.poly([(x - w, y + height * 0.12), (x + w, y + height * 0.12), (x, y - height * 0.10)])


def water_tower(m, x, ground, height):
    tank_w, tank_h = height * 0.36, height * 0.30
    top = ground - height
    legs_top = top + tank_h * 0.95
    for k in (-1, -0.35, 0.35, 1):
        m.line([(x + k * tank_w * 0.42, legs_top), (x + k * tank_w * 0.62, ground)], height * 0.022)
    for f in (0.35, 0.65):
        yb = legs_top + (ground - legs_top) * f
        wb = tank_w * (0.42 + 0.20 * f)
        m.line([(x - wb, yb), (x + wb, yb)], height * 0.012)
        m.line([(x - wb, yb), (x + wb * 0.55, yb + (ground - legs_top) * 0.30)], height * 0.009)
    m.line([(x, legs_top), (x, ground)], height * 0.03)
    m.poly([(x - tank_w / 2, top + tank_h * 0.25), (x + tank_w / 2, top + tank_h * 0.25),
            (x + tank_w / 2, legs_top), (x - tank_w / 2, legs_top)])
    m.ellipse(x, legs_top, tank_w / 2, tank_h * 0.12)
    m.poly([(x - tank_w * 0.56, top + tank_h * 0.27), (x + tank_w * 0.56, top + tank_h * 0.27), (x, top - tank_h * 0.10)])
    m.line([(x, top - tank_h * 0.10), (x, top - tank_h * 0.32)], height * 0.008)
    m.line([(x - tank_w * 0.62, top + tank_h * 0.62), (x + tank_w * 0.62, top + tank_h * 0.62)], height * 0.012)


def farmhouse(m, x, ground, w):
    """A two storey farmhouse with a porch; returns the lit window's centre."""
    h = w * 0.52
    m.poly([(x, ground), (x + w, ground), (x + w, ground - h), (x, ground - h)])
    m.poly([(x - w * 0.05, ground - h), (x + w * 0.5, ground - h - w * 0.34), (x + w * 1.05, ground - h)])
    m.poly([(x + w * 0.70, ground - h - w * 0.12), (x + w * 0.78, ground - h - w * 0.12),
            (x + w * 0.78, ground - h - w * 0.30), (x + w * 0.70, ground - h - w * 0.30)])
    # porch roof and posts
    m.poly([(x - w * 0.18, ground - h * 0.45), (x + w * 0.02, ground - h * 0.58), (x + w * 0.02, ground - h * 0.50),
            (x - w * 0.18, ground - h * 0.40)])
    for px in (-0.16, -0.07):
        m.line([(x + w * px, ground), (x + w * px, ground - h * 0.42)], w * 0.012)
    # a barn behind on the right
    bx = x + w * 1.25
    bw = w * 0.85
    m.poly([(bx, ground), (bx + bw, ground), (bx + bw, ground - bw * 0.40), (bx + bw * 0.86, ground - bw * 0.62),
            (bx + bw * 0.5, ground - bw * 0.76), (bx + bw * 0.14, ground - bw * 0.62), (bx, ground - bw * 0.40)])
    m.poly([(bx + bw * 0.38, ground - bw * 0.62), (bx + bw * 0.62, ground - bw * 0.62), (bx + bw * 0.5, ground - bw * 0.70)])
    sx, sw, sh = bx + bw * 1.08, bw * 0.20, bw * 0.95
    m.poly([(sx, ground), (sx + sw, ground), (sx + sw, ground - sh), (sx, ground - sh)])
    m.ellipse(sx + sw / 2, ground - sh, sw / 2, sw * 0.42)
    return (x + w * 0.26, ground - h * 0.66), (w * 0.085, h * 0.17)


def car(m, x, ground, w, tilt):
    h = w * 0.30

    def r(px, py):
        c, s = math.cos(tilt), math.sin(tilt)
        return x + px * c - py * s, ground + px * s + py * c

    body = [(0, -h * 0.18), (w, -h * 0.18), (w * 0.98, -h * 0.55), (w * 0.74, -h * 0.62), (w * 0.60, -h),
            (w * 0.26, -h), (w * 0.16, -h * 0.62), (0.02 * w, -h * 0.55)]
    m.poly([r(px, py) for px, py in body])
    for wx in (0.2, 0.8):
        cx, cy = r(w * wx, -h * 0.16)
        m.ellipse(cx, cy, w * 0.085, w * 0.085)
    # the driver's door, open
    m.poly([r(w * 0.30, -h * 0.20), r(w * 0.20, -h * 0.05), r(w * 0.18, -h * 0.62), r(w * 0.28, -h * 0.66)])


def zombie(m, x, foot, height, facing=1, lean=0.10, arm=0.0, seed=0):
    """A shambling zombie in profile: head down, one arm reaching, a dragged leg."""
    rng = np.random.default_rng(seed)
    f = facing
    u = height

    def p(px, py):
        return x + f * px * u, foot + py * u

    lean_x = lean
    hip = (0.0, -0.48)
    shoulder = (0.02 + lean_x * 0.55, -0.80)
    m.poly([p(hip[0] - 0.085, hip[1]), p(hip[0] + 0.09, hip[1]), p(shoulder[0] + 0.12, shoulder[1] + 0.02),
            p(shoulder[0] + 0.03, shoulder[1] - 0.04), p(shoulder[0] - 0.11, shoulder[1] + 0.03)])
    # ragged shirt
    hem = [p(hip[0] - 0.09, hip[1] - 0.02)]
    for k in range(6):
        t = k / 5
        hem.append(p(hip[0] - 0.09 + 0.19 * t, hip[1] + (0.05 if k % 2 else 0.01) + rng.uniform(0, 0.03)))
    hem.append(p(hip[0] + 0.10, hip[1] - 0.04))
    m.poly(hem)
    # head, dropped forward
    hx, hy = shoulder[0] + 0.07 + lean_x * 0.3, shoulder[1] - 0.10
    m.line([p(shoulder[0] + 0.02, shoulder[1]), p(hx, hy + 0.03)], u * 0.06)
    m.ellipse(*p(hx, hy), u * 0.064, u * 0.074)
    # legs: one straight, one dragged behind
    m.line([p(0.03, -0.47), p(0.07, -0.25), p(0.04 + rng.uniform(-0.02, 0.03), -0.01)], u * 0.085)
    m.line([p(0.04, -0.01), p(0.12, 0.0)], u * 0.045)
    m.line([p(-0.03, -0.47), p(-0.07, -0.25), p(-0.17, -0.05)], u * 0.078)
    m.line([p(-0.17, -0.05), p(-0.22, -0.02)], u * 0.04)
    # arms: one reaching forward, one hanging
    reach = -0.68 + arm
    m.line([p(shoulder[0] + 0.03, shoulder[1] + 0.03), p(shoulder[0] + 0.17, reach - 0.02),
            p(shoulder[0] + 0.32, reach + 0.01)], u * 0.058)
    m.line([p(shoulder[0] + 0.32, reach + 0.01), p(shoulder[0] + 0.38, reach + 0.03)], u * 0.034)
    m.line([p(shoulder[0] - 0.05, shoulder[1] + 0.03), p(shoulder[0] - 0.07, -0.60), p(shoulder[0] - 0.02, -0.45)],
           u * 0.055)


def power_line(m, near, far, count, heights):
    """Wooden poles along the road, from near to far, with sagging wires between them."""
    poles = []
    for i in range(count):
        t = (i / (count - 1)) ** 2.3
        x = near[0] + (far[0] - near[0]) * t
        g = near[1] + (far[1] - near[1]) * t
        hgt = heights[0] + (heights[1] - heights[0]) * t
        poles.append((x, g, hgt))
        m.line([(x, g), (x, g - hgt)], max(1.0, hgt * 0.022))
        m.line([(x - hgt * 0.16, g - hgt * 0.90), (x + hgt * 0.16, g - hgt * 0.90)], max(0.8, hgt * 0.013))
    for (x0, g0, h0), (x1, g1, h1) in zip(poles, poles[1:]):
        for k in (-0.13, 0.0, 0.13):
            a = (x0 + k * h0, g0 - h0 * 0.90)
            b = (x1 + k * h1, g1 - h1 * 0.90)
            sag = abs(b[0] - a[0]) * 0.06 + 2
            pts = []
            for s in range(25):
                t = s / 24
                pts.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t + sag * 4 * t * (1 - t)))
            m.line(pts, 0.7)
    return poles


def fence(m, near, far, count, heights, broken=(3, 7)):
    posts = []
    for i in range(count):
        t = (i / (count - 1)) ** 1.6
        x = near[0] + (far[0] - near[0]) * t
        g = near[1] + (far[1] - near[1]) * t
        h = heights[0] + (heights[1] - heights[0]) * t
        posts.append((x, g, h))
        m.line([(x, g), (x + h * 0.04, g - h)], max(1.0, h * 0.09))
    for i, ((x0, g0, h0), (x1, g1, h1)) in enumerate(zip(posts, posts[1:])):
        for f in (0.35, 0.75):
            if i in broken and f == 0.75:
                m.line([(x0, g0 - h0 * f), (x0 + (x1 - x0) * 0.45, g0 - h0 * 0.1)], max(0.8, h0 * 0.06))
                continue
            m.line([(x0, g0 - h0 * f), (x1, g1 - h1 * f)], max(0.8, (h0 + h1) * 0.035))


# ---------------------------------------------------------------------------------------------------------------------
# the layers in front of the sky

def hills():
    m_far = Mask()
    far = ridge(-10, W + 10, HORIZON - 34, 26, 2.4, 41, step=4)
    m_far.poly(far + [(W + 10, H), (-10, H)])
    far_a = m_far.array()

    m = Mask()
    rng = np.random.default_rng(52)
    base = ridge(-10, W + 10, HORIZON - 4, 6, 2.0, 43, step=6)
    m.poly(base + [(W + 10, H), (-10, H)])
    x = -20.0
    while x < W + 20:
        gx = min(max(int(x), 0), W - 1)
        ground = base[min(len(base) - 1, max(0, int((gx + 10) / 6)))][1] + 2
        gap = abs(x - ROAD_VP[0]) < 22
        if not gap:
            height = rng.uniform(26, 58) * (1.25 if rng.random() < 0.12 else 1.0)
            if rng.random() < 0.30:
                tree_pine(m, rng, x, ground, height * 1.2)
            else:
                tree_blob(m, rng, x, ground, height)
        x += rng.uniform(9, 22)
    water_tower(m, W * 0.455, HORIZON - 2, 205)
    mid_a = m.array()

    hz = np.arange(H)[:, None] * np.ones((1, W))
    far_rgb = gradient([(0, (30, 42, 58)), (HORIZON - 60, (30, 42, 58)), (HORIZON, (18, 26, 38)), (H, (10, 14, 20))],
                       hz)
    mid_rgb = gradient([(0, (9, 13, 21)), (HORIZON, (9, 13, 21)), (H, (6, 8, 12))], hz)
    # moonlight on the top edge of the trees, stronger on the side of the moon
    edge = np.clip(mid_a - np.roll(mid_a, 2, axis=0), 0, 1)
    side = np.exp(-((np.arange(W)[None, :] - MOON_X) / (W * 0.35)) ** 2)
    mid_rgb += (edge * (0.35 + 0.65 * side))[..., None] * np.array([70, 84, 104])

    a = mid_a + far_a * (1 - mid_a)
    rgb = (mid_rgb * mid_a[..., None] + far_rgb * (far_a * (1 - mid_a))[..., None]) / np.maximum(a, 1e-6)[..., None]
    # the haze between the trees and the far hills
    haze = smoothstep(HORIZON - 70, HORIZON + 6, hz) * smoothstep(HORIZON + 60, HORIZON + 4, hz)
    rgb += (haze * 0.35)[..., None] * np.array([40, 48, 60]) * (1 - mid_a[..., None])
    return rgb, a


def ground():
    m = Mask()
    vx, vy = ROAD_VP
    m.poly([(-10, HORIZON + 6), (W + 10, HORIZON + 6), (W + 10, H), (-10, H)])
    field_a = m.array()

    # the road: from the bottom of the window to the vanishing point
    road = Mask()
    road.poly([(vx - 3, vy), (vx + 3, vy), (W * 0.80, H + 2), (W * 0.44, H + 2)])
    road_a = road.array()

    lines = Mask()
    for i in range(14):
        t0 = (i / 14) ** 2.2
        t1 = ((i + 0.45) / 14) ** 2.2
        cx0 = vx + (W * 0.62 - vx) * t0
        cy0 = vy + (H - vy) * t0
        cx1 = vx + (W * 0.62 - vx) * t1
        cy1 = vy + (H - vy) * t1
        lines.line([(cx0, cy0), (cx1, cy1)], 0.6 + 5 * t1)
    lines_a = lines.array() * road_a

    things = Mask()
    poles = power_line(things, (W * 1.01, H + 60), (vx + 26, vy - 1), 7, (420, 10))
    fence(things, (W * 0.30, H + 20), (vx - 30, vy + 1), 11, (95, 4))
    window, window_size = farmhouse(things, W * 0.115, HORIZON + 22, 190)
    car(things, W * 0.405, HORIZON + 66, 92, -0.08)
    # the zombies: far on the road, closer on the field and on the shoulder
    zombie(things, vx + 18, HORIZON + 34, 34, facing=-1, lean=0.12, seed=1)
    zombie(things, vx - 42, HORIZON + 46, 44, facing=1, lean=0.18, arm=0.06, seed=2)
    zombie(things, W * 0.66, HORIZON + 92, 92, facing=-1, lean=0.10, arm=-0.04, seed=3)
    zombie(things, W * 0.735, HORIZON + 168, 168, facing=-1, lean=0.16, arm=0.03, seed=4)
    zombie(things, W * 0.36, HORIZON + 120, 104, facing=1, lean=0.14, arm=0.08, seed=5)
    zombie(things, W * 0.24, HORIZON + 74, 60, facing=1, lean=0.08, seed=6)
    # tall grass along the bottom edge
    rng = np.random.default_rng(77)
    for _ in range(900):
        gx = rng.uniform(-10, W + 10)
        if W * 0.45 < gx < W * 0.79 and rng.random() < 0.9:
            continue
        hgt = rng.uniform(12, 46) * (1.6 if rng.random() < 0.1 else 1)
        bend = rng.uniform(-0.4, 0.4) * hgt
        things.line([(gx, H + 2), (gx + bend * 0.4, H - hgt * 0.6), (gx + bend, H - hgt)], rng.uniform(0.8, 2.0))
    things_a = things.array()

    yy = np.arange(H)[:, None] * np.ones((1, W))
    xx = np.ones((H, 1)) * np.arange(W)[None, :]
    t = smoothstep(HORIZON, H, yy)
    field = gradient([(0, (34, 44, 56)), (HORIZON + 6, (34, 44, 56)), (HORIZON + 40, (24, 31, 41)),
                      (HORIZON + 150, (14, 18, 25)), (H, (7, 9, 12))], yy)
    # crop rows converging to the vanishing point, on the left of the road
    ang = np.arctan2(yy - vy, xx - vx)
    rows = (np.sin(ang * 260) * 0.5 + 0.5) ** 3 * smoothstep(HORIZON + 10, HORIZON + 140, yy) * (xx < vx - 20)
    field += rows[..., None] * np.array([7, 9, 10]) * (1 - t * 0.5)[..., None]
    field += noise2(H, W, 1.2, 61)[..., None] * 2.0

    road_rgb = gradient([(0, (40, 46, 56)), (HORIZON + 6, (40, 46, 56)), (HORIZON + 120, (26, 30, 38)), (H, (17, 19, 24))],
                        yy)
    # the moon shines on the asphalt
    below = np.maximum(yy - vy, 0)
    sheen = np.exp(-((xx - (vx + (MOON_X - vx) * 0.15 + below * 0.18)) / (40 + below * 0.25)) ** 2)
    road_rgb += (sheen * (1 - t * 0.7) * 0.5)[..., None] * np.array([46, 52, 62])
    road_rgb += lines_a[..., None] * np.array([48, 44, 26])

    rgb = field * (1 - road_a[..., None]) + road_rgb * road_a[..., None]

    obj_rgb = gradient([(0, (5, 7, 11)), (HORIZON, (6, 8, 12)), (H, (2, 3, 4))], yy)
    # things far away melt a little into the fog
    far_fog = smoothstep(HORIZON + 50, HORIZON - 30, yy)
    obj_rgb = obj_rgb * (1 - far_fog[..., None] * 0.30) + np.array([30, 38, 50]) * (far_fog[..., None] * 0.30)
    edge = np.clip(things_a - np.roll(things_a, 1, axis=0), 0, 1)
    obj_rgb += edge[..., None] * np.array([34, 40, 52])
    rgb = rgb * (1 - things_a[..., None]) + obj_rgb * things_a[..., None]

    # the lit window of the farmhouse
    wx, wy = window
    ww, wh = window_size
    lamp = Mask()
    lamp.poly([(wx - ww / 2, wy - wh / 2), (wx + ww / 2, wy - wh / 2), (wx + ww / 2, wy + wh / 2), (wx - ww / 2, wy + wh / 2)])
    lamp_a = lamp.array()
    rgb = rgb * (1 - lamp_a[..., None]) + np.array([255, 178, 92]) * lamp_a[..., None]
    rgb[..., :] = rgb  # keep numpy happy about views

    alpha = np.clip(field_a + things_a, 0, 1)
    return rgb, alpha, (wx / W, wy / H)


# ---------------------------------------------------------------------------------------------------------------------
# the moon of the logo and of the icon

def logo_and_icon():
    big = 512
    r = int(big * 0.42)
    mrgb, malpha = moon_disc(r, 9)
    canvas = np.zeros((big, big, 4))
    s = mrgb.shape[0]
    o = (big - s) // 2
    canvas[o:o + s, o:o + s, :3] = mrgb
    canvas[o:o + s, o:o + s, 3] = malpha
    yy, xx = np.mgrid[0:big, 0:big]
    d = np.sqrt((xx - big / 2) ** 2 + (yy - big / 2) ** 2)
    halo = np.exp(-np.maximum(d - r, 0) / (big * 0.035)) * (d > r - 1) * 0.65
    out_a = canvas[..., 3] + halo * (1 - canvas[..., 3])
    out_rgb = (canvas[..., :3] * canvas[..., 3:4] + np.array([150, 176, 214]) * (halo * (1 - canvas[..., 3]))[..., None])
    out_rgb /= np.maximum(out_a, 1e-6)[..., None]
    img = Image.fromarray(np.dstack([np.clip(out_rgb, 0, 255), out_a * 255]).astype(np.uint8), "RGBA")
    img.resize((128, 128), Image.LANCZOS).save(OUT / "luna.png", optimize=True)

    # the icon: the moon with a hand rising in front of it, only where there is room for the hand
    hand = Mask.__new__(Mask)
    hand.img = Image.new("L", (big * SS, big * SS), 0)
    hand.d = ImageDraw.Draw(hand.img)
    cx = big * 0.52
    base = big * 1.02
    hand.poly([(cx - 52, base), (cx + 40, base), (cx + 46, big * 0.70), (cx - 50, big * 0.70)])
    hand.ellipse(cx - 2, big * 0.68, 52, 40)
    for i, (dx, top, wdt) in enumerate([(-44, 0.50, 17), (-17, 0.40, 19), (10, 0.39, 19), (35, 0.46, 17)]):
        hand.line([(cx + dx, big * 0.66), (cx + dx + (i - 1.5) * 3, big * top)], wdt)
    hand.line([(cx + 44, big * 0.73), (cx + 74, big * 0.62), (cx + 86, big * 0.55)], 20)
    hand_a = np.asarray(hand.img.resize((big, big), Image.LANCZOS), dtype=np.float64) / 255
    rgb_i = out_rgb * (1 - hand_a[..., None]) + np.array([10, 12, 18]) * hand_a[..., None]
    a_i = np.clip(out_a + hand_a * (yy < big * 0.98), 0, 1) * (d < big * 0.5)
    with_hand = Image.fromarray(np.dstack([np.clip(rgb_i, 0, 255), a_i * 255]).astype(np.uint8), "RGBA")
    plain = img
    sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    frames = [(with_hand if sz >= 40 else plain).resize((sz, sz), Image.LANCZOS) for sz in sizes]
    frames[-1].save(OUT / "moon.ico", format="ICO", sizes=[(sz, sz) for sz in sizes], append_images=frames[:-1])

    # the splash that Windows shows while the launcher starts: the moon with a wide, soft glow
    size = 360
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    yy, xx = np.mgrid[0:size, 0:size]
    d = np.sqrt((xx - size / 2) ** 2 + (yy - size / 2) ** 2)
    glow = np.clip(np.exp(-np.maximum(d - 96, 0) / 30.0) * 0.75, 0, 1) * (d > 90)
    halo = np.zeros((size, size, 4))
    halo[..., :3] = np.array([150, 180, 225])
    halo[..., 3] = glow * 255
    canvas.alpha_composite(Image.fromarray(halo.astype(np.uint8), "RGBA"))
    moon = img.resize((220, 220), Image.LANCZOS)
    canvas.alpha_composite(moon, ((size - 220) // 2, (size - 220) // 2))
    canvas.save(OUT / "splash.png", optimize=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    save_rgb(sky(), "cielo.jpg")
    rgb, a = clouds()
    save_rgba(rgb, a, "nuvole.png")
    rgb, a = fog()
    save_rgba(rgb, a, "nebbia.png")
    rgb, a = hills()
    save_rgba(rgb, a, "colline.png")
    rgb, a, window = ground()
    save_rgba(rgb, a, "terra.png")
    logo_and_icon()
    print("finestra accesa (frazione della larghezza e dell'altezza): %.4f, %.4f" % window)
    print("nuvole: y da 0 a %.3f dell'altezza; nebbia: centrata a %.3f" % (0.62, HORIZON / H))


if __name__ == "__main__":
    main()
