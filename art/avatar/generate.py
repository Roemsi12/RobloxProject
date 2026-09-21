"""
Draws every texture a player avatar wears: classic shirt and pants templates,
the chest overlays that carry the trim colour, faces and markings.

    python art/avatar/generate.py            -- writes art/avatar/textures/*.png
    python art/avatar/generate.py --preview  -- also writes art/avatar/preview.png

Everything is drawn in greyscale on purpose. In game, each texture is tinted
by the colour the player picked (Shirt.Color3, Pants.Color3, ShirtGraphic.Color3,
Decal.Color3), and tinting multiplies. So a light grey reads as exactly the
chosen colour, and a darker grey reads as a shade of it: every garment works
in every colour without a texture per colour.

Needs Pillow and numpy. The PNGs are committed, so only someone changing the
art needs to run this. After changing it, re-upload (lune run upload-avatar --force <names>).
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "textures")

# --------------------------------------------------------------------------
# Canvas: a value channel and an alpha channel, both float 0..1.
# --------------------------------------------------------------------------


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.v = np.zeros((h, w), np.float32)
        self.a = np.zeros((h, w), np.float32)

    def paint(self, mask, value):
        """Lays `value` (a scalar or an array) over the canvas where `mask` is set."""
        m = np.clip(mask, 0, 1)
        self.v = self.v * (1 - m) + value * m
        self.a = np.maximum(self.a, m)

    def shade(self, mask, factor):
        """Multiplies value by `factor` where `mask` is set."""
        m = np.clip(mask, 0, 1)
        self.v = self.v * (1 - m + m * factor)

    def erase(self, mask):
        self.a = self.a * (1 - np.clip(mask, 0, 1))

    def image(self):
        g = (np.clip(self.v, 0, 1) * 255).astype(np.uint8)
        a = (np.clip(self.a, 0, 1) * 255).astype(np.uint8)
        return Image.merge("RGBA", [Image.fromarray(g)] * 3 + [Image.fromarray(a)])


def blank(w, h):
    return np.zeros((h, w), np.float32)


def mask_from(w, h, draw_fn, supersample=4):
    """A soft mask drawn with PIL at 4x, then scaled down so edges anti-alias."""
    img = Image.new("L", (w * supersample, h * supersample), 0)
    d = ImageDraw.Draw(img)
    draw_fn(d, supersample)
    img = img.resize((w, h), Image.LANCZOS)
    return np.asarray(img, np.float32) / 255


def rect(w, h, x0, y0, x1, y1):
    return mask_from(w, h, lambda d, s: d.rectangle([x0 * s, y0 * s, x1 * s - 1, y1 * s - 1], fill=255))


def poly(w, h, points):
    return mask_from(w, h, lambda d, s: d.polygon([(x * s, y * s) for x, y in points], fill=255))


def ellipse(w, h, cx, cy, rx, ry):
    return mask_from(w, h, lambda d, s: d.ellipse([(cx - rx) * s, (cy - ry) * s, (cx + rx) * s, (cy + ry) * s], fill=255))


def line(w, h, points, width):
    def draw(d, s):
        d.line([(x * s, y * s) for x, y in points], fill=255, width=max(1, int(width * s)), joint="curve")

    return mask_from(w, h, draw)


def blur(arr, radius):
    img = Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255


# --------------------------------------------------------------------------
# Noise and materials. Each returns a value field for the whole canvas; the
# caller paints it through a mask.
# --------------------------------------------------------------------------

_rng = np.random.default_rng(7)


def noise(w, h, cell, seed=None):
    """Smooth value noise, -1..1, with features about `cell` pixels across."""
    rng = np.random.default_rng(seed) if seed is not None else _rng
    gw, gh = max(2, int(w / cell) + 2), max(2, int(h / cell) + 2)
    grid = rng.random((gh, gw)).astype(np.float32)
    img = Image.fromarray((grid * 255).astype(np.uint8)).resize((w + int(cell) * 2, h + int(cell) * 2), Image.BICUBIC)
    arr = np.asarray(img, np.float32)[: h, : w] / 255
    return arr * 2 - 1


def grain(w, h, amount, seed=None):
    rng = np.random.default_rng(seed) if seed is not None else _rng
    return (rng.random((h, w)).astype(np.float32) * 2 - 1) * amount


def weave(w, h):
    """A fine cross-weave, the texture that says 'cloth' up close."""
    y, x = np.mgrid[0:h, 0:w]
    return (np.sin(x * 2.1) * np.sin(y * 2.1)) * 0.5


def cloth(w, h, base=0.9, folds=0.07, seed=None, fold_dir="vertical"):
    """Woven cloth: a weave, low soft folds and a little grain."""
    n = noise(w, h, 22, seed)
    if fold_dir == "vertical":
        y, x = np.mgrid[0:h, 0:w]
        n = 0.6 * n + 0.4 * np.sin(x / 7.0 + noise(w, h, 40, seed) * 2.5)
    return base + n * folds + weave(w, h) * 0.018 + grain(w, h, 0.02, seed)


def leather(w, h, base=0.45, seed=None):
    n1 = noise(w, h, 14, seed)
    n2 = noise(w, h, 4, None if seed is None else seed + 1)
    return base + n1 * 0.06 + n2 * 0.03 + grain(w, h, 0.025, seed)


def metal(w, h, base=0.82, seed=None):
    """Brushed metal: horizontal streaks and a broad soft sheen."""
    streak = noise(w, 1, 3, seed).repeat(h, 0) if False else None
    rng = np.random.default_rng(seed)
    rows = rng.random((h, 1)).astype(np.float32)
    streaks = np.asarray(
        Image.fromarray((rows * 255).astype(np.uint8)).resize((1, h), Image.BILINEAR), np.float32
    ) / 255
    streaks = np.repeat(streaks, w, axis=1)
    cols = rng.random((1, w * 3)).astype(np.float32)
    brushed = np.asarray(Image.fromarray((cols * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), np.float32) / 255
    return base + (brushed - 0.5) * 0.08 + (streaks - 0.5) * 0.04 + noise(w, h, 30, seed) * 0.05


def chain(w, h, base=0.62):
    """Mail: little interlocked rings in rows."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    row = np.floor(y / 3.0)
    xx = (x + (row % 2) * 1.5) % 3.0
    yy = y % 3.0
    ring = np.exp(-((xx - 1.5) ** 2 + (yy - 1.5) ** 2) / 1.1)
    return base + (ring - 0.5) * 0.35 + grain(w, h, 0.03)


# --------------------------------------------------------------------------
# The classic clothing template (585 x 559).
#
# A body part is drawn as one continuous strip wrapped around it, so a belt
# or a hem meets itself at the back, then cut into the template's faces.
# --------------------------------------------------------------------------

TEMPLATE = (585, 559)

# Torso strip, 384 x 128: right side, front, left side, back.
TORSO_FACES = [("R", 0, 64, (165, 74)), ("F", 64, 128, (231, 74)), ("L", 192, 64, (361, 74)), ("B", 256, 128, (427, 74))]
TORSO_UP = (231, 8)
TORSO_DOWN = (231, 204)

# Limb strips, 256 x 128, in the template's left-to-right order, which also
# runs continuously around the limb.
RIGHT_LIMB_FACES = [("L", 0, (19, 355)), ("B", 64, (85, 355)), ("R", 128, (151, 355)), ("F", 192, (217, 355))]
LEFT_LIMB_FACES = [("F", 0, (308, 355)), ("L", 64, (374, 355)), ("B", 128, (440, 355)), ("R", 192, (506, 355))]
RIGHT_LIMB_CAPS = ((217, 289), (217, 485))
LEFT_LIMB_CAPS = ((308, 289), (308, 485))

# Where the R15 parts fall on a 128-row strip. A classic template is drawn
# for the old six-part body; on R15 each strip is shared out between the
# parts in proportion to their height.
WAIST = 102  # torso: UpperTorso above, LowerTorso below
ELBOW = 59  # arm: upper arm above
WRIST = 112  # arm: hand below
KNEE = 58  # leg: upper leg above
ANKLE = 114  # leg: foot below


def face_x(faces, name):
    for f in faces:
        if f[0] == name:
            return f[1]
    raise KeyError(name)


def torso_front(x):
    """Distance of strip column x from the centre of the torso front, 0..1."""
    return abs(x - 128) / 64


def assemble(torso, right, left, torso_caps=None, right_caps=None, left_caps=None):
    """Cuts strips into the 585x559 template."""
    sheet = Image.new("RGBA", TEMPLATE, (0, 0, 0, 0))
    t = torso.image()
    for _, sx, width, (tx, ty) in TORSO_FACES:
        sheet.paste(t.crop((sx, 0, sx + width, 128)), (tx, ty))
    if torso_caps:
        up, down = torso_caps
        sheet.paste(up.image(), TORSO_UP)
        sheet.paste(down.image(), TORSO_DOWN)
    for strip, faces, caps, capdraw in ((right, RIGHT_LIMB_FACES, RIGHT_LIMB_CAPS, right_caps), (left, LEFT_LIMB_FACES, LEFT_LIMB_CAPS, left_caps)):
        img = strip.image()
        for _, sx, (tx, ty) in faces:
            sheet.paste(img.crop((sx, 0, sx + 64, 128)), (tx, ty))
        if capdraw:
            up, down = capdraw
            sheet.paste(up.image(), caps[0])
            if down is not None:
                sheet.paste(down.image(), caps[1])
    return sheet


def cap(w, h, value_fn, alpha=1.0):
    c = Canvas(w, h)
    c.paint(np.full((h, w), alpha, np.float32), value_fn(w, h))
    return c


def edge_darken(c, mask, radius=3, strength=0.25):
    """Shadows a material toward its own edges, so a panel reads as sitting on
    top of what's under it rather than being printed on."""
    inner = blur(mask, radius)
    c.shade(mask, 1 - strength * np.clip(1 - inner, 0, 1) * 2)


def seam(c, points, value=0.35, width=1.2, highlight=True):
    w, h = c.w, c.h
    m = line(w, h, points, width)
    c.v = c.v * (1 - m) + value * m * 1 + c.v * 0  # dark line
    if highlight:
        hp = [(x + 0.8, y + 0.8) for x, y in points]
        hm = line(w, h, hp, 0.8) * (1 - m)
        c.v = np.minimum(1, c.v + hm * 0.06)


def stitches(c, points, value=0.3, dash=3, gap=2, width=1):
    """A dashed line of stitching along a polyline."""
    w, h = c.w, c.h

    def draw(d, s):
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            length = math.hypot(x1 - x0, y1 - y0)
            steps = int(length // (dash + gap))
            for i in range(steps + 1):
                a = i * (dash + gap) / max(length, 1e-6)
                b = min(1, a + dash / max(length, 1e-6))
                d.line(
                    [((x0 + (x1 - x0) * a) * s, (y0 + (y1 - y0) * a) * s), ((x0 + (x1 - x0) * b) * s, (y0 + (y1 - y0) * b) * s)],
                    fill=255,
                    width=max(1, int(width * s)),
                )

    m = mask_from(w, h, draw)
    c.v = c.v * (1 - m) + value * m


def rivet(c, cx, cy, r=1.8, base=0.95):
    w, h = c.w, c.h
    shadow = ellipse(w, h, cx + 0.6, cy + 0.8, r + 0.6, r + 0.6)
    c.shade(shadow, 0.6)
    head = ellipse(w, h, cx, cy, r, r)
    c.paint(head, base)
    glint = ellipse(w, h, cx - r * 0.35, cy - r * 0.35, r * 0.4, r * 0.4)
    c.paint(glint, 1.0)


def top_light(c, strength=0.08):
    """A little more light from above, the way the dungeon's torches fall."""
    y = np.linspace(1 + strength, 1 - strength, c.h, dtype=np.float32)[:, None]
    c.v = c.v * y


# ----------------------------- belts and bits ------------------------------


def belt(c, y0, y1, buckle_x=None, value=0.34, buckle=True):
    w = c.w
    m = rect(w, c.h, 0, y0, w, y1)
    c.paint(m, leather(w, c.h, value, seed=11))
    edge_darken(c, m, 1.5, 0.35)
    stitches(c, [(0, y0 + 1.5), (w, y0 + 1.5)], value * 0.55, 2, 2)
    stitches(c, [(0, y1 - 2), (w, y1 - 2)], value * 0.55, 2, 2)
    if buckle and buckle_x is not None:
        bw, bh = 12, (y1 - y0) + 4
        outer = rect(w, c.h, buckle_x - bw / 2, y0 - 2, buckle_x + bw / 2, y0 - 2 + bh)
        inner = rect(w, c.h, buckle_x - bw / 2 + 2.5, y0 + 0.5, buckle_x + bw / 2 - 2.5, y0 - 2 + bh - 2.5)
        c.shade(blur(outer, 1.5), 0.7)
        c.paint(outer, metal(w, c.h, 0.9, seed=3))
        c.paint(inner, leather(w, c.h, value * 0.8, seed=12))
        c.paint(rect(w, c.h, buckle_x - 0.8, y0 + 1, buckle_x + 0.8, y0 - 2 + bh - 3), 0.95)


def pouch(c, x, y, pw=14, ph=13, value=0.4):
    w, h = c.w, c.h
    body = rect(w, h, x, y, x + pw, y + ph)
    c.shade(blur(body, 2), 0.7)
    c.paint(body, leather(w, h, value, seed=21))
    edge_darken(c, body, 1.5, 0.3)
    flap = poly(w, h, [(x - 0.5, y - 0.5), (x + pw + 0.5, y - 0.5), (x + pw + 0.5, y + ph * 0.45), (x + pw / 2, y + ph * 0.6), (x - 0.5, y + ph * 0.45)])
    c.paint(flap, leather(w, h, value * 1.12, seed=22))
    stitches(c, [(x + 1.5, y + ph * 0.38), (x + pw / 2, y + ph * 0.52), (x + pw - 1.5, y + ph * 0.38)], value * 0.5, 1.5, 1.5)
    rivet(c, x + pw / 2, y + ph * 0.5, 1.2, 0.85)


# --------------------------------------------------------------------------
# Shirts
# --------------------------------------------------------------------------


def torso_canvas():
    return Canvas(384, 128)


def limb_canvas():
    return Canvas(256, 128)


def cloth_torso(c, base=0.9, seed=1, y_end=128):
    m = rect(c.w, c.h, 0, 0, c.w, y_end)
    c.paint(m, cloth(c.w, c.h, base, seed=seed))
    return m


def neckline(c, depth=16, width=22, lace=False):
    """A V at the neck on the front. Skin shows through it."""
    fx = 128
    m = poly(c.w, c.h, [(fx - width / 2, -1), (fx + width / 2, -1), (fx, depth)])
    c.erase(m)
    rim = line(c.w, c.h, [(fx - width / 2 - 1, -1), (fx, depth + 1), (fx + width / 2 + 1, -1)], 3)
    c.shade(rim, 0.72)
    if lace:
        for i in range(3):
            y = 4 + i * 4
            half = (width / 2) * (1 - y / depth) + 2
            seam(c, [(fx - half, y), (fx + half, y + 2.5)], 0.3, 0.9, False)
            seam(c, [(fx + half, y), (fx - half, y + 2.5)], 0.3, 0.9, False)


def side_seams(c, value=0.55):
    for x in (64, 192):
        seam(c, [(x, 0), (x, 128)], value, 1)


def shoulder_yoke(c, y=18, value=0.8):
    m = rect(c.w, c.h, 0, 0, c.w, y)
    c.shade(m, value)
    stitches(c, [(0, y), (c.w, y)], 0.4, 2, 2)


def sleeve(c, length=WRIST - 4, base=0.9, seed=2, cuff=True, cuff_value=0.72, flare=False):
    """A sleeve down the whole strip to `length`, below which the skin shows."""
    m = rect(c.w, c.h, 0, 0, c.w, length)
    c.paint(m, cloth(c.w, c.h, base, seed=seed))
    # a crease inside the elbow
    for fx in (face_x(RIGHT_LIMB_FACES, "F"),):
        pass
    y, x = np.mgrid[0:c.h, 0:c.w].astype(np.float32)
    crease = np.exp(-((y - ELBOW) ** 2) / 18) * (0.5 + 0.5 * np.sin(x / 9))
    c.shade(m, 1 - crease * 0.12)
    if cuff:
        cm = rect(c.w, c.h, 0, length - 9, c.w, length)
        c.shade(cm, cuff_value)
        stitches(c, [(0, length - 9), (c.w, length - 9)], 0.38, 2, 2)
    edge = rect(c.w, c.h, 0, length - 1.5, c.w, length)
    c.shade(edge, 0.6)
    return m


def shirt_ragged():
    t = torso_canvas()
    # Linen torn off above the belly button, jagged all the way round.
    rng = np.random.default_rng(31)
    pts = [(0, -1), (384, -1)]
    x = 384
    hem = []
    while x >= 0:
        hem.append((x, 92 + rng.uniform(-7, 9)))
        x -= rng.uniform(5, 11)
    hem.append((0, 95))
    m = poly(t.w, t.h, pts + hem)
    t.paint(m, cloth(t.w, t.h, 0.86, folds=0.09, seed=33))
    # grime and stains
    stain = np.clip(noise(t.w, t.h, 40, 34), 0, 1) ** 2
    t.shade(m, 1 - stain * 0.14)
    t.shade(m * rect(t.w, t.h, 0, 70, t.w, 128), 0.9)
    # holes
    for (hx, hy, r) in [(100, 46, 5), (300, 60, 4), (170, 30, 3)]:
        hole = ellipse(t.w, t.h, hx, hy, r, r * 0.8)
        t.shade(blur(hole, 2.5), 0.7)
        t.erase(hole)
    # a patch sewn over the front
    patch = rect(t.w, t.h, 138, 50, 156, 66)
    t.paint(patch, cloth(t.w, t.h, 0.7, seed=35))
    stitches(t, [(138, 50), (156, 50), (156, 66), (138, 66), (138, 50)], 0.3, 2, 2)
    neckline(t, 20, 26)
    edge_darken(t, m, 2.5, 0.3)
    side_seams(t, 0.6)
    top_light(t)

    # sleeveless: a frayed cap over the shoulder only
    def arm():
        a = limb_canvas()
        pts2 = [(0, -1), (256, -1)]
        x = 256
        while x >= 0:
            pts2.append((x, 16 + rng.uniform(-4, 5)))
            x -= rng.uniform(5, 9)
        pts2.append((0, 16))
        am = poly(a.w, a.h, pts2)
        a.paint(am, cloth(a.w, a.h, 0.84, seed=36))
        edge_darken(a, am, 2, 0.3)
        return a

    up = cap(128, 64, lambda w, h: cloth(w, h, 0.86, seed=37))
    neck = ellipse(128, 64, 64, 32, 14, 10)
    up.erase(neck)
    down = cap(128, 64, lambda w, h: cloth(w, h, 0.8, seed=38), alpha=0)
    arm_up = cap(64, 64, lambda w, h: cloth(w, h, 0.84, seed=39))
    return assemble(t, arm(), arm(), (up, down), (arm_up, None), (arm_up, None))


def shirt_tunic():
    t = torso_canvas()
    m = cloth_torso(t, 0.9, seed=41)
    shoulder_yoke(t, 16, 0.88)
    neckline(t, 22, 22, lace=True)
    side_seams(t)
    # gathered folds falling from the belt
    y, x = np.mgrid[0:128, 0:384].astype(np.float32)
    gathers = np.clip((y - WAIST - 14) / 12, 0, 1) * (0.5 + 0.5 * np.sin(x / 3.2))
    t.shade(m, 1 - gathers * 0.14)
    belt(t, WAIST + 3, WAIST + 12, buckle_x=128)
    pouch(t, 88, WAIST + 9)
    top_light(t)

    def arm():
        a = limb_canvas()
        sleeve(a, WRIST - 3, 0.9, seed=42)
        top_light(a)
        return a

    return assemble(t, arm(), arm(), tunic_caps(0.9), (cap(64, 64, lambda w, h: cloth(w, h, 0.9, seed=43)), None), (cap(64, 64, lambda w, h: cloth(w, h, 0.9, seed=44)), None))


def tunic_caps(base):
    up = cap(128, 64, lambda w, h: cloth(w, h, base * 0.95, seed=45))
    up.erase(ellipse(128, 64, 64, 32, 15, 11))
    up.shade(line(128, 64, [(49, 32), (64, 43), (79, 32), (64, 21), (49, 32)], 3), 0.7)
    down = cap(128, 64, lambda w, h: cloth(w, h, base * 0.8, seed=46))
    return (up, down)


def shirt_leathers():
    t = torso_canvas()
    m = rect(t.w, t.h, 0, 0, t.w, 128)
    t.paint(m, leather(t.w, t.h, 0.78, seed=51))
    # panels, each stitched and each a touch different
    panels = [(0, 64), (64, 110), (110, 146), (146, 192), (192, 256), (256, 320), (320, 384)]
    for i, (x0, x1) in enumerate(panels):
        pm = rect(t.w, t.h, x0, 14, x1, WAIST + 2)
        t.shade(pm, 0.94 + 0.08 * ((i * 37) % 3) / 2)
        edge_darken(t, pm, 1.5, 0.22)
        stitches(t, [(x0 + 2, 14), (x0 + 2, WAIST + 2)], 0.42, 2, 2)
        stitches(t, [(x1 - 2, 14), (x1 - 2, WAIST + 2)], 0.42, 2, 2)
    # yoke across the shoulders
    yoke = rect(t.w, t.h, 0, 0, t.w, 16)
    t.paint(yoke, leather(t.w, t.h, 0.66, seed=52))
    edge_darken(t, yoke, 1.5, 0.3)
    stitches(t, [(0, 14), (384, 14)], 0.32, 2, 2)
    # laced opening
    for i in range(5):
        yy = 20 + i * 7
        rivet(t, 124, yy, 1.1, 0.85)
        rivet(t, 132, yy, 1.1, 0.85)
        seam(t, [(124, yy), (132, yy + 3.5)], 0.3, 0.8, False)
    neckline(t, 12, 16)
    belt(t, WAIST + 2, WAIST + 12, buckle_x=128, value=0.3)
    pouch(t, 80, WAIST + 8, 14, 12, 0.36)
    pouch(t, 162, WAIST + 8, 12, 11, 0.36)
    # under the belt: the jerkin skirt in strips
    for x0 in range(0, 384, 16):
        strip = rect(t.w, t.h, x0 + 0.5, WAIST + 12, x0 + 15.5, 128)
        t.shade(strip, 0.9 + (x0 % 32) / 32 * 0.1)
        edge_darken(t, strip, 1, 0.3)
    top_light(t)

    def arm():
        a = limb_canvas()
        sleeve(a, WRIST - 2, 0.86, seed=53, cuff=False)
        # bracer on the forearm
        br = rect(a.w, a.h, 0, ELBOW + 12, a.w, WRIST - 2)
        a.paint(br, leather(a.w, a.h, 0.5, seed=54))
        edge_darken(a, br, 1.5, 0.35)
        for fx in (0, 64, 128, 192):
            for yy in range(ELBOW + 18, WRIST - 4, 8):
                rivet(a, fx + 30, yy, 1.1, 0.8)
                seam(a, [(fx + 30, yy), (fx + 36, yy + 4)], 0.25, 0.8, False)
        stitches(a, [(0, ELBOW + 14), (256, ELBOW + 14)], 0.3, 2, 2)
        # pauldron-ish shoulder cap of stiff leather
        sh = rect(a.w, a.h, 0, 0, a.w, 20)
        a.paint(sh, leather(a.w, a.h, 0.62, seed=55))
        edge_darken(a, sh, 1.5, 0.3)
        stitches(a, [(0, 18), (256, 18)], 0.3, 2, 2)
        top_light(a)
        return a

    up = cap(128, 64, lambda w, h: leather(w, h, 0.66, seed=56))
    up.erase(ellipse(128, 64, 64, 32, 14, 10))
    down = cap(128, 64, lambda w, h: leather(w, h, 0.6, seed=57))
    arm_up = cap(64, 64, lambda w, h: leather(w, h, 0.62, seed=58))
    return assemble(t, arm(), arm(), (up, down), (arm_up, None), (arm_up, None))


def plate_band(c, x0, y0, x1, y1, base=0.86, seed=0, rivets=True, curve=0.0):
    m = rect(c.w, c.h, x0, y0, x1, y1)
    field = metal(c.w, c.h, base, seed=seed)
    # a highlight band across the plate's upper third, as if it curves
    y, x = np.mgrid[0:c.h, 0:c.w].astype(np.float32)
    t = (y - y0) / max(1, (y1 - y0))
    sheen = np.exp(-((t - 0.3) ** 2) / 0.02) * 0.12 - np.clip(t - 0.75, 0, 1) * 0.35
    c.paint(m, field + sheen)
    edge_darken(c, m, 1.2, 0.35)
    # bright rolled lip along the top edge
    lip = rect(c.w, c.h, x0, y0, x1, y0 + 1.6)
    c.paint(lip * m, 1.0)
    if rivets:
        step = 16
        xx = x0 + 6
        while xx < x1 - 3:
            rivet(c, xx, y0 + 4, 1.4)
            xx += step
    return m


def shirt_plate():
    t = torso_canvas()
    # mail everywhere underneath, showing at the seams and the waist
    t.paint(rect(t.w, t.h, 0, 0, t.w, 128), chain(t.w, t.h, 0.6))
    # breastplate and backplate: tall plates, then lames down to the waist
    for (x0, x1, seed) in ((58, 198, 61), (250, 384, 62)):
        m = rect(t.w, t.h, x0, 2, x1, 72)
        field = metal(t.w, t.h, 0.86, seed=seed)
        y, x = np.mgrid[0:128, 0:384].astype(np.float32)
        cx = (x0 + x1) / 2
        # the plate bulges: lit in the middle, falling off to the sides
        bulge = 1 - ((x - cx) / ((x1 - x0) / 2)) ** 2 * 0.25 - np.clip((y - 50) / 30, 0, 1) * 0.12
        t.paint(m, field * bulge)
        # central ridge
        ridge = line(t.w, t.h, [(cx, 4), (cx, 70)], 2.2)
        t.paint(ridge * m, 1.0)
        t.shade(line(t.w, t.h, [(cx + 2, 4), (cx + 2, 70)], 1.4) * m, 0.7)
        edge_darken(t, m, 1.5, 0.4)
        for yy in range(8, 70, 14):
            rivet(t, x0 + 5, yy, 1.5)
            rivet(t, x1 - 5, yy, 1.5)
    # side plates
    for x0 in (0, 192):
        m = rect(t.w, t.h, x0 + 2, 6, x0 + 62, 70)
        t.paint(m, metal(t.w, t.h, 0.74, seed=63 + x0))
        edge_darken(t, m, 1.5, 0.4)
    for i, y0 in enumerate(range(72, WAIST + 22, 9)):
        plate_band(t, 0, y0, 384, y0 + 10, 0.8 - i * 0.02, seed=70 + i, rivets=i % 2 == 0)
    # gorget line at the neck
    g = rect(t.w, t.h, 0, 0, t.w, 5)
    t.paint(g, metal(t.w, t.h, 0.95, seed=64))
    edge_darken(t, g, 1, 0.3)
    top_light(t, 0.05)

    def arm():
        a = limb_canvas()
        a.paint(rect(a.w, a.h, 0, 0, a.w, 128), chain(a.w, a.h, 0.58))
        # spaulder: three overlapping lames over the shoulder
        for i, y0 in enumerate((0, 10, 20)):
            plate_band(a, 0, y0, 256, y0 + 12, 0.9 - i * 0.05, seed=80 + i, rivets=True)
        # couter at the elbow
        cm = rect(a.w, a.h, 0, ELBOW - 7, a.w, ELBOW + 7)
        a.paint(cm, metal(a.w, a.h, 0.9, seed=84))
        edge_darken(a, cm, 1.5, 0.4)
        for fx in (0, 64, 128, 192):
            rivet(a, fx + 32, ELBOW, 2.4)
        # vambrace
        plate_band(a, 0, ELBOW + 9, 256, WRIST - 2, 0.84, seed=85, rivets=True)
        # gauntlet over the hand
        gm = rect(a.w, a.h, 0, WRIST - 2, a.w, 128)
        a.paint(gm, leather(a.w, a.h, 0.4, seed=86))
        plate_band(a, 0, WRIST - 2, 256, WRIST + 6, 0.8, seed=87, rivets=False)
        for fx in (0, 64, 128, 192):
            for k in range(4):
                seam(a, [(fx + 10 + k * 14, WRIST + 7), (fx + 10 + k * 14, 128)], 0.25, 0.8, False)
        return a

    up = cap(128, 64, lambda w, h: metal(w, h, 0.9, seed=88))
    up.erase(ellipse(128, 64, 64, 32, 14, 10))
    up.shade(line(128, 64, [(49, 32), (64, 43), (79, 32), (64, 21), (49, 32)], 2.5), 0.6)
    down = cap(128, 64, lambda w, h: chain(w, h, 0.55))
    arm_up = cap(64, 64, lambda w, h: metal(w, h, 0.9, seed=89))
    hand = cap(64, 64, lambda w, h: leather(w, h, 0.38, seed=90))
    return assemble(t, arm(), arm(), (up, down), (arm_up, hand), (arm_up, hand))


def shirt_robes():
    t = torso_canvas()
    m = cloth_torso(t, 0.92, seed=91)
    # crossed front: a wrap collar that runs from each shoulder to the waist
    fx = 128
    left_lapel = poly(t.w, t.h, [(fx - 30, -1), (fx - 18, -1), (fx + 8, 70), (fx - 2, 74)])
    right_lapel = poly(t.w, t.h, [(fx + 18, -1), (fx + 30, -1), (fx + 2, 74), (fx - 8, 70)])
    for lap in (right_lapel, left_lapel):
        t.shade(blur(lap, 2), 0.8)
        t.paint(lap, cloth(t.w, t.h, 0.74, seed=92))
        edge_darken(t, lap, 1, 0.35)
    stitches(t, [(fx - 24, 0), (fx + 2, 70)], 0.42, 2, 2)
    stitches(t, [(fx + 24, 0), (fx - 2, 70)], 0.42, 2, 2)
    neck = poly(t.w, t.h, [(fx - 18, -1), (fx + 18, -1), (fx, 18)])
    t.erase(neck)
    # hood gathered at the back of the neck
    hood = ellipse(t.w, t.h, 320, 2, 44, 20)
    t.shade(blur(hood, 3), 0.8)
    t.paint(hood, cloth(t.w, t.h, 0.8, seed=93))
    t.shade(line(t.w, t.h, [(290, 6), (320, 16), (350, 6)], 2), 0.6)
    # long fold lines
    for x0 in (20, 44, 96, 164, 212, 240, 270, 300, 340, 366):
        seam(t, [(x0, 20), (x0 + 3, 128)], 0.8, 2.5, False)
    # rope belt with a knot and hanging ends
    rope = rect(t.w, t.h, 0, WAIST + 4, t.w, WAIST + 10)
    t.paint(rope, leather(t.w, t.h, 0.62, seed=94))
    for xx in range(0, 384, 4):
        seam(t, [(xx, WAIST + 4), (xx + 3, WAIST + 10)], 0.35, 0.7, False)
    knot = ellipse(t.w, t.h, 146, WAIST + 7, 5, 5)
    t.paint(knot, leather(t.w, t.h, 0.6, seed=95))
    for dx in (0, 5):
        end = line(t.w, t.h, [(146 + dx, WAIST + 10), (144 + dx * 1.4, 128)], 2.4)
        t.paint(end, 0.58)
    top_light(t)

    def arm():
        a = limb_canvas()
        # the sleeve runs the full length and hangs past the wrist
        sm = rect(a.w, a.h, 0, 0, a.w, 128)
        a.paint(sm, cloth(a.w, a.h, 0.92, seed=96))
        y, x = np.mgrid[0:128, 0:256].astype(np.float32)
        drape = np.clip((y - ELBOW) / 60, 0, 1) * (0.5 + 0.5 * np.sin(x / 6))
        a.shade(sm, 1 - drape * 0.18)
        # embroidered band at the cuff
        band = rect(a.w, a.h, 0, 96, a.w, 108)
        a.paint(band, cloth(a.w, a.h, 0.7, seed=97))
        for xx in range(0, 256, 8):
            seam(a, [(xx, 102), (xx + 4, 98), (xx + 8, 102), (xx + 4, 106), (xx, 102)], 0.95, 0.8, False)
        edge_darken(a, band, 1, 0.3)
        # the open end: the shadowed inside of the sleeve over the hand
        inside = rect(a.w, a.h, 0, 110, a.w, 128)
        a.paint(inside, cloth(a.w, a.h, 0.28, seed=98))
        top_light(a)
        return a

    up, down = tunic_caps(0.92)
    arm_up = cap(64, 64, lambda w, h: cloth(w, h, 0.92, seed=99))
    hand = cap(64, 64, lambda w, h: cloth(w, h, 0.25, seed=100))
    return assemble(t, arm(), arm(), (up, down), (arm_up, hand), (arm_up, hand))


def quilt(c, mask, base=0.88, step=10, seed=0):
    """A padded gambeson: diamond quilting with puffed cells."""
    y, x = np.mgrid[0:c.h, 0:c.w].astype(np.float32)
    u = (x + y) / step
    v = (x - y) / step
    du = np.abs(u - np.round(u))
    dv = np.abs(v - np.round(v))
    d = np.minimum(du, dv)
    puff = np.clip(d * 2.2, 0, 1) ** 0.6
    c.paint(mask, cloth(c.w, c.h, base, folds=0.03, seed=seed) * (0.72 + 0.28 * puff))


def shirt_tabard():
    t = torso_canvas()
    m = rect(t.w, t.h, 0, 0, t.w, 128)
    quilt(t, m, 0.9, 10, seed=101)
    # the tabard itself: a panel front and back, hanging past the belt
    for x0, x1 in ((96, 160), (288, 352)):
        pm = rect(t.w, t.h, x0, 0, x1, 128)
        t.shade(blur(pm, 2.5), 0.72)
        t.paint(pm, cloth(t.w, t.h, 0.95, seed=102 + x0))
        edge_darken(t, pm, 1.5, 0.3)
        stitches(t, [(x0 + 3, 0), (x0 + 3, 128)], 0.5, 2, 2)
        stitches(t, [(x1 - 3, 0), (x1 - 3, 128)], 0.5, 2, 2)
    neckline(t, 10, 18)
    belt(t, WAIST + 3, WAIST + 11, buckle_x=128, value=0.32)
    top_light(t)

    def arm():
        a = limb_canvas()
        am = rect(a.w, a.h, 0, 0, a.w, WRIST - 3)
        quilt(a, am, 0.88, 9, seed=103)
        cuff = rect(a.w, a.h, 0, WRIST - 12, a.w, WRIST - 3)
        a.paint(cuff, leather(a.w, a.h, 0.42, seed=104))
        edge_darken(a, cuff, 1, 0.3)
        top_light(a)
        return a

    up = cap(128, 64, lambda w, h: cloth(w, h, 0.86, seed=105))
    up.erase(ellipse(128, 64, 64, 32, 14, 10))
    down = cap(128, 64, lambda w, h: cloth(w, h, 0.8, seed=106))
    arm_up = cap(64, 64, lambda w, h: cloth(w, h, 0.86, seed=107))
    return assemble(t, arm(), arm(), (up, down), (arm_up, None), (arm_up, None))


def wraps(c, y0, y1, seed, gap_every=0, base=0.9, slant=5):
    """Bandage strips wound round, each a little crooked."""
    rng = np.random.default_rng(seed)
    y = y0
    i = 0
    while y < y1:
        hgt = rng.uniform(7, 10)
        off = rng.uniform(-2, 2)
        pts = [(-2, y + off), (c.w + 2, y + off + slant), (c.w + 2, y + off + slant + hgt), (-2, y + off + hgt)]
        m = poly(c.w, c.h, pts)
        c.shade(blur(m, 1.5), 0.8)
        c.paint(m, cloth(c.w, c.h, base * rng.uniform(0.9, 1.0), folds=0.05, seed=seed + i, fold_dir="none"))
        edge_darken(c, m, 1, 0.35)
        y += hgt - rng.uniform(0.5, 2.5) + (rng.uniform(3, 6) if gap_every and i % gap_every == gap_every - 1 else 0)
        i += 1


def shirt_wrappings():
    t = torso_canvas()
    wraps(t, 6, WAIST + 20, 111, gap_every=3, base=0.9, slant=6)
    # a broad sash crossing the chest
    fx = 128
    sash = poly(t.w, t.h, [(fx - 60, -2), (fx - 36, -2), (fx + 64, 100), (fx + 40, 100)])
    t.shade(blur(sash, 2.5), 0.72)
    t.paint(sash, cloth(t.w, t.h, 0.78, seed=112))
    edge_darken(t, sash, 1.5, 0.3)
    stain = np.clip(noise(t.w, t.h, 20, 113), 0, 1) ** 2
    t.shade(t.a, 1 - stain * 0.25)
    top_light(t)

    def arm(seed):
        a = limb_canvas()
        wraps(a, ELBOW - 4, WRIST + 8, seed, gap_every=2, base=0.9, slant=3)
        top_light(a)
        return a

    up = cap(128, 64, lambda w, h: cloth(w, h, 0.8, seed=114), alpha=0)
    down = cap(128, 64, lambda w, h: cloth(w, h, 0.8, seed=115))
    return assemble(t, arm(116), arm(117), (up, down))


def shirt_cloak():
    t = torso_canvas()
    # a jerkin in front
    jm = rect(t.w, t.h, 0, 0, t.w, 128)
    t.paint(jm, leather(t.w, t.h, 0.74, seed=121))
    for x0 in (64, 192):
        seam(t, [(x0, 0), (x0, 128)], 0.4, 1)
    stitches(t, [(120, 12), (120, WAIST)], 0.35, 2, 2)
    stitches(t, [(136, 12), (136, WAIST)], 0.35, 2, 2)
    neckline(t, 12, 16)
    belt(t, WAIST + 2, WAIST + 11, buckle_x=128, value=0.3)
    # the cloak: all of the back, both sides, over the shoulders
    cm = poly(t.w, t.h, [(-1, -1), (60, -1), (58, 128), (-1, 128)])
    cm = np.maximum(cm, poly(t.w, t.h, [(196, -1), (385, -1), (385, 128), (196, 128)]))
    t.shade(blur(cm, 3), 0.7)
    y, x = np.mgrid[0:128, 0:384].astype(np.float32)
    folds = np.sin(x / 5.5 + noise(384, 128, 30, 122) * 2) * np.clip(y / 128 + 0.2, 0, 1)
    t.paint(cm, cloth(t.w, t.h, 0.9, folds=0.04, seed=123) * (0.86 + folds * 0.1))
    edge_darken(t, cm, 2, 0.35)
    # mantle over the shoulders, all the way round
    mantle = rect(t.w, t.h, 0, 0, t.w, 16)
    t.shade(blur(mantle, 2), 0.8)
    t.paint(mantle, cloth(t.w, t.h, 0.86, seed=124))
    edge_darken(t, mantle, 1.5, 0.3)
    stitches(t, [(0, 14), (384, 14)], 0.4, 2, 2)
    # clasp chain between the two collar clasps
    for cx in (106, 150):
        rivet(t, cx, 11, 3.2)
    for i in range(1, 11):
        rivet(t, 106 + i * 4, 11 + math.sin(i / 11 * math.pi) * 5, 1.1, 0.9)
    top_light(t)

    def arm():
        a = limb_canvas()
        sleeve(a, WRIST - 3, 0.82, seed=125)
        # the cloak's edge falls over the back of the shoulder
        back = face_x(RIGHT_LIMB_FACES, "B")
        cm2 = poly(a.w, a.h, [(back - 30, -1), (back + 94, -1), (back + 80, 36), (back - 16, 36)])
        a.shade(blur(cm2, 2), 0.75)
        a.paint(cm2, cloth(a.w, a.h, 0.86, seed=126))
        edge_darken(a, cm2, 1.5, 0.35)
        top_light(a)
        return a

    up = cap(128, 64, lambda w, h: cloth(w, h, 0.86, seed=127))
    up.erase(ellipse(128, 64, 64, 32, 14, 10))
    down = cap(128, 64, lambda w, h: leather(w, h, 0.6, seed=128))
    arm_up = cap(64, 64, lambda w, h: cloth(w, h, 0.86, seed=129))
    return assemble(t, arm(), arm(), (up, down), (arm_up, None), (arm_up, None))


# --------------------------------------------------------------------------
# Pants
# --------------------------------------------------------------------------


def boot(c, top=KNEE + 22, value=0.34, cuff=True):
    m = rect(c.w, c.h, 0, top, c.w, 128)
    c.shade(blur(m, 2), 0.7)
    c.paint(m, leather(c.w, c.h, value, seed=131))
    y, x = np.mgrid[0:128, 0:c.w].astype(np.float32)
    creases = np.clip((y - top) / 20, 0, 1) * np.clip((ANKLE - 4 - y) / 10, 0, 1) * (0.5 + 0.5 * np.sin(y / 2.2 + x / 30))
    c.shade(m, 1 - creases * 0.18)
    if cuff:
        cm = rect(c.w, c.h, 0, top, c.w, top + 7)
        c.paint(cm, leather(c.w, c.h, value * 1.18, seed=132))
        edge_darken(c, cm, 1, 0.35)
    sole = rect(c.w, c.h, 0, 124, c.w, 128)
    c.paint(sole, 0.16)
    stitches(c, [(0, ANKLE + 3), (c.w, ANKLE + 3)], value * 0.5, 2, 2)


def trouser_leg(seed, front_x, knee_pad=False, boots=True, base=0.9):
    c = limb_canvas()
    m = rect(c.w, c.h, 0, 0, c.w, 128)
    c.paint(m, cloth(c.w, c.h, base, seed=seed))
    for x0 in (0, 128):
        seam(c, [(x0 + 1, 0), (x0 + 1, 128)], 0.55, 1)
    y, x = np.mgrid[0:128, 0:256].astype(np.float32)
    crease = np.exp(-((y - KNEE) ** 2) / 30) * (0.5 + 0.5 * np.sin(x / 7))
    c.shade(m, 1 - crease * 0.14)
    if knee_pad:
        # on the front face, which is at the end of a right-leg strip and the
        # start of a left-leg one
        fx = front_x
        kp = rect(c.w, c.h, fx + 8, KNEE - 10, fx + 56, KNEE + 10)
        c.shade(blur(kp, 2), 0.75)
        c.paint(kp, leather(c.w, c.h, 0.52, seed=seed + 1))
        edge_darken(c, kp, 1.5, 0.3)
        stitches(c, [(fx + 10, KNEE - 8), (fx + 54, KNEE - 8), (fx + 54, KNEE + 8), (fx + 10, KNEE + 8), (fx + 10, KNEE - 8)], 0.3, 2, 2)
    if boots:
        boot(c)
    top_light(c)
    return c


def pants_torso(seed, base=0.9, rope=False):
    t = torso_canvas()
    m = rect(t.w, t.h, 0, WAIST - 6, t.w, 128)
    t.paint(m, cloth(t.w, t.h, base, seed=seed))
    if rope:
        r = rect(t.w, t.h, 0, WAIST - 2, t.w, WAIST + 4)
        t.paint(r, leather(t.w, t.h, 0.6, seed=seed + 1))
        for xx in range(0, 384, 4):
            seam(t, [(xx, WAIST - 2), (xx + 3, WAIST + 4)], 0.35, 0.7, False)
    else:
        wb = rect(t.w, t.h, 0, WAIST - 6, t.w, WAIST + 2)
        t.shade(wb, 0.82)
        stitches(t, [(0, WAIST + 2), (384, WAIST + 2)], 0.4, 2, 2)
    seam(t, [(128, WAIST + 2), (128, 128)], 0.5, 1)
    return t


def pants_caps(base, seed, foot_value=0.2):
    down = cap(128, 64, lambda w, h: cloth(w, h, base * 0.8, seed=seed))
    leg_up = cap(64, 64, lambda w, h: cloth(w, h, base, seed=seed + 1))
    foot = cap(64, 64, lambda w, h: leather(w, h, foot_value, seed=seed + 2))
    up = cap(128, 64, lambda w, h: cloth(w, h, base, seed=seed), alpha=0)
    return (up, down), (leg_up, foot)


def pants_trousers():
    t = pants_torso(141)
    caps, legcaps = pants_caps(0.9, 142)
    return assemble(t, trouser_leg(143, 192, knee_pad=True), trouser_leg(144, 0, knee_pad=True), caps, legcaps, legcaps)


def pants_ragged():
    t = pants_torso(151, 0.84, rope=True)
    rng = np.random.default_rng(152)

    def leg(seed):
        c = limb_canvas()
        pts = [(0, -1), (256, -1)]
        x = 256
        while x >= 0:
            pts.append((x, KNEE + 24 + rng.uniform(-6, 7)))
            x -= rng.uniform(5, 10)
        pts.append((0, KNEE + 24))
        m = poly(c.w, c.h, pts)
        c.paint(m, cloth(c.w, c.h, 0.84, folds=0.09, seed=seed))
        stain = np.clip(noise(c.w, c.h, 40, seed + 1), 0, 1) ** 2
        c.shade(m, 1 - stain * 0.14)
        edge_darken(c, m, 2, 0.3)
        # foot wraps round the ankle
        fw = rect(c.w, c.h, 0, ANKLE - 12, c.w, ANKLE + 2)
        c.paint(fw, cloth(c.w, c.h, 0.62, seed=seed + 2))
        for yy in range(ANKLE - 12, ANKLE + 2, 4):
            seam(c, [(0, yy), (256, yy + 2)], 0.4, 0.8, False)
        top_light(c)
        return c

    down = cap(128, 64, lambda w, h: cloth(w, h, 0.7, seed=153))
    up = cap(128, 64, lambda w, h: cloth(w, h, 0.7, seed=153), alpha=0)
    leg_up = cap(64, 64, lambda w, h: cloth(w, h, 0.84, seed=154))
    return assemble(t, leg(155), leg(156), (up, down), (leg_up, None), (leg_up, None))


def pants_greaves():
    t = torso_canvas()
    t.paint(rect(t.w, t.h, 0, WAIST - 6, t.w, 128), chain(t.w, t.h, 0.58))
    # tassets hanging from the waist
    for x0 in (64, 136, 256, 328):
        plate_band(t, x0, WAIST + 2, x0 + 56, WAIST + 14, 0.84, seed=160 + x0, rivets=True)
        plate_band(t, x0 + 2, WAIST + 13, x0 + 54, 128, 0.8, seed=161 + x0, rivets=False)

    def leg(seed):
        c = limb_canvas()
        c.paint(rect(c.w, c.h, 0, 0, c.w, 128), chain(c.w, c.h, 0.56))
        plate_band(c, 0, 4, 256, KNEE - 8, 0.84, seed=seed, rivets=True)
        # poleyn at the knee
        km = rect(c.w, c.h, 0, KNEE - 8, c.w, KNEE + 8)
        c.paint(km, metal(c.w, c.h, 0.94, seed=seed + 1))
        edge_darken(c, km, 1.5, 0.45)
        for fx in (0, 64, 128, 192):
            rivet(c, fx + 32, KNEE, 3)
        plate_band(c, 0, KNEE + 8, 256, ANKLE, 0.84, seed=seed + 2, rivets=True)
        # sabaton: overlapping lames over the foot
        for i, y0 in enumerate(range(ANKLE, 128, 5)):
            plate_band(c, 0, y0, 256, y0 + 6, 0.78 - i * 0.04, seed=seed + 3 + i, rivets=False)
        return c

    down = cap(128, 64, lambda w, h: chain(w, h, 0.55))
    up = cap(128, 64, lambda w, h: chain(w, h, 0.55), alpha=0)
    leg_up = cap(64, 64, lambda w, h: chain(w, h, 0.55))
    foot = cap(64, 64, lambda w, h: metal(w, h, 0.6, seed=170))
    return assemble(t, leg(171), leg(181), (up, down), (leg_up, foot), (leg_up, foot))


def pants_robe():
    t = pants_torso(191, 0.92, rope=False)

    def leg(seed):
        c = limb_canvas()
        m = rect(c.w, c.h, 0, 0, c.w, ANKLE - 2)
        y, x = np.mgrid[0:128, 0:256].astype(np.float32)
        folds = np.sin(x / 6 + noise(256, 128, 30, seed) * 2) * 0.5 + 0.5
        c.paint(m, cloth(c.w, c.h, 0.92, seed=seed) * (0.9 + folds * 0.1))
        hem = rect(c.w, c.h, 0, ANKLE - 14, c.w, ANKLE - 2)
        c.paint(hem, cloth(c.w, c.h, 0.7, seed=seed + 1))
        for xx in range(0, 256, 8):
            seam(c, [(xx, ANKLE - 8), (xx + 4, ANKLE - 12), (xx + 8, ANKLE - 8), (xx + 4, ANKLE - 4), (xx, ANKLE - 8)], 0.95, 0.8, False)
        edge_darken(c, hem, 1, 0.3)
        # soft shoes under the hem
        shoe = rect(c.w, c.h, 0, ANKLE - 2, c.w, 128)
        c.paint(shoe, leather(c.w, c.h, 0.3, seed=seed + 2))
        top_light(c)
        return c

    caps, legcaps = pants_caps(0.92, 192, 0.25)
    return assemble(t, leg(193), leg(194), caps, legcaps, legcaps)


def pants_wraps():
    t = pants_torso(201, 0.86)

    def leg(seed):
        c = limb_canvas()
        m = rect(c.w, c.h, 0, 0, c.w, 128)
        c.paint(m, cloth(c.w, c.h, 0.86, seed=seed))
        # puttees wound from knee to ankle
        wraps(c, KNEE - 2, ANKLE + 4, seed + 1, gap_every=0, base=0.72, slant=4)
        sole = rect(c.w, c.h, 0, ANKLE + 4, c.w, 128)
        c.paint(sole, leather(c.w, c.h, 0.3, seed=seed + 2))
        top_light(c)
        return c

    caps, legcaps = pants_caps(0.86, 202, 0.3)
    return assemble(t, leg(203), leg(204), caps, legcaps, legcaps)


# --------------------------------------------------------------------------
# Chest overlays (ShirtGraphic). Tinted with the trim colour, so these are
# where the second colour of a garb lives. 512 x 512, drawn over the front of
# the upper torso.
# --------------------------------------------------------------------------

GS = 512


def overlay_canvas():
    return Canvas(GS, GS)


def emblem(c, cx, cy, r):
    """A plain heater shield with a chevron: a house badge, no house in particular."""
    shield = poly(c.w, c.h, [(cx - r, cy - r), (cx + r, cy - r), (cx + r, cy + r * 0.2), (cx, cy + r * 1.3), (cx - r, cy + r * 0.2)])
    c.shade(blur(shield, 6), 0.7)
    c.paint(shield, metal(c.w, c.h, 0.9, seed=301))
    inner = poly(c.w, c.h, [(cx - r + 10, cy - r + 10), (cx + r - 10, cy - r + 10), (cx + r - 10, cy + r * 0.16), (cx, cy + r * 1.3 - 16), (cx - r + 10, cy + r * 0.16)])
    c.paint(inner, cloth(c.w, c.h, 0.62, seed=302))
    chev = poly(c.w, c.h, [(cx - r + 10, cy + 10), (cx, cy - 34), (cx + r - 10, cy + 10), (cx + r - 10, cy + 44), (cx, cy), (cx - r + 10, cy + 44)])
    c.paint(chev * inner, 0.95)
    edge_darken(c, shield, 3, 0.3)


def overlay_tabard():
    c = overlay_canvas()
    # the tabard panel sits exactly where the shirt drew it: the middle half
    m = rect(GS, GS, 128, 0, 384, GS)
    c.paint(m, cloth(GS, GS, 0.94, folds=0.05, seed=311))
    edge_darken(c, m, 4, 0.3)
    stitches(c, [(140, 0), (140, GS)], 0.5, 8, 6, 3)
    stitches(c, [(372, 0), (372, GS)], 0.5, 8, 6, 3)
    emblem(c, 256, 220, 82)
    return c.image()


def overlay_tunic():
    c = overlay_canvas()
    # an embroidered collar band round the V of the neck
    band = line(GS, GS, [(150, -4), (256, 100), (362, -4)], 26)
    c.paint(band, cloth(GS, GS, 0.94, seed=321))
    edge_darken(c, band, 3, 0.35)
    for i in range(9):
        t = i / 8
        for side in (-1, 1):
            x = 256 + side * (106 * (1 - t))
            y = -4 + 104 * t
            c.paint(ellipse(GS, GS, x, y, 5, 5), 0.6)
    return c.image()


def overlay_leathers():
    c = overlay_canvas()
    strap = poly(GS, GS, [(30, -10), (110, -10), (500, 520), (420, 520)])
    c.shade(blur(strap, 6), 0.7)
    c.paint(strap, leather(GS, GS, 0.9, seed=331))
    edge_darken(c, strap, 3, 0.35)
    stitches(c, [(48, -10), (436, 520)], 0.45, 8, 6, 3)
    stitches(c, [(92, -10), (482, 520)], 0.45, 8, 6, 3)
    for t in (0.3, 0.55, 0.8):
        x, y = 70 + (460 - 70) * t, -10 + 530 * t
        c.paint(ellipse(GS, GS, x, y, 16, 16), metal(GS, GS, 0.95, seed=332))
        c.shade(ellipse(GS, GS, x, y, 8, 8), 0.6)
    return c.image()


def overlay_plate():
    c = overlay_canvas()
    # a raised crest down the breastplate, and a gorget rim
    ridge = rect(GS, GS, 240, 0, 272, GS)
    c.paint(ridge, metal(GS, GS, 0.95, seed=341))
    edge_darken(c, ridge, 3, 0.4)
    gor = rect(GS, GS, 0, 0, GS, 26)
    c.paint(gor, metal(GS, GS, 0.95, seed=342))
    edge_darken(c, gor, 3, 0.4)
    for y in range(60, GS, 70):
        rivet(c, 256, y, 8)
    return c.image()


def overlay_robes():
    c = overlay_canvas()
    # a stole: two broad bands from the shoulders, with a sigil on each
    for x0 in (120, 316):
        m = rect(GS, GS, x0, 0, x0 + 76, GS)
        c.shade(blur(m, 5), 0.75)
        c.paint(m, cloth(GS, GS, 0.95, seed=351 + x0))
        edge_darken(c, m, 3, 0.3)
        stitches(c, [(x0 + 8, 0), (x0 + 8, GS)], 0.5, 8, 6, 3)
        stitches(c, [(x0 + 68, 0), (x0 + 68, GS)], 0.5, 8, 6, 3)
        cx = x0 + 38
        for cy in (140, 330):
            c.paint(line(GS, GS, [(cx, cy - 34), (cx + 26, cy), (cx, cy + 34), (cx - 26, cy), (cx, cy - 34)], 7), 0.5)
            c.paint(ellipse(GS, GS, cx, cy, 8, 8), 0.5)
    return c.image()


def overlay_wrappings():
    c = overlay_canvas()
    # a cord across the chest with a hanging charm
    cord = line(GS, GS, [(40, -10), (256, 250), (472, -10)], 12)
    c.paint(cord, leather(GS, GS, 0.85, seed=361))
    edge_darken(c, cord, 2, 0.35)
    charm = poly(GS, GS, [(256, 240), (292, 300), (256, 380), (220, 300)])
    c.shade(blur(charm, 6), 0.7)
    c.paint(charm, metal(GS, GS, 0.95, seed=362))
    edge_darken(c, charm, 3, 0.35)
    c.paint(ellipse(GS, GS, 256, 305, 14, 14), 0.55)
    return c.image()


def overlay_cloak():
    c = overlay_canvas()
    # the cloak's clasps and chain, big and bright on the collar
    for cx in (136, 376):
        disc = ellipse(GS, GS, cx, 80, 38, 38)
        c.shade(blur(disc, 6), 0.7)
        c.paint(disc, metal(GS, GS, 0.95, seed=371))
        edge_darken(c, disc, 3, 0.4)
        c.paint(line(GS, GS, [(cx - 18, 80), (cx, 60), (cx + 18, 80), (cx, 100), (cx - 18, 80)], 6), 0.6)
    for i in range(1, 16):
        t = i / 16
        x = 136 + 240 * t
        y = 90 + math.sin(t * math.pi) * 70
        c.paint(ellipse(GS, GS, x, y, 8, 6), metal(GS, GS, 0.92, seed=372))
    return c.image()


def overlay_ragged():
    c = overlay_canvas()
    # a rope belt knot high on the chest: a bandolier of rope
    rope = poly(GS, GS, [(20, -10), (70, -10), (492, 520), (442, 520)])
    c.paint(rope, leather(GS, GS, 0.85, seed=381))
    for k in range(0, 60):
        t = k / 60
        x, y = 45 + (467 - 45) * t, -10 + 530 * t
        c.paint(line(GS, GS, [(x - 22, y - 4), (x + 22, y + 12)], 3), 0.5)
    edge_darken(c, rope, 3, 0.4)
    return c.image()


# --------------------------------------------------------------------------
# Faces and markings. Decals on the head's front, 512 x 512. The eyes are a
# decal of their own, so an eye colour tints the eyes and nothing else.
#
# Positions match the old welded face: eyes a little above the middle, the
# mouth a quarter of the way up from the chin.
# --------------------------------------------------------------------------

FS = 512
EYE_Y = 214
EYE_SPREAD = 104
MOUTH_Y = 372


def face_canvas():
    return Canvas(FS, FS)


def almond(c, cx, cy, w, h, tilt=0.0):
    """An eye shape: pointed at the corners, fuller on top."""
    pts = []
    for i in range(41):
        t = i / 40 * math.pi
        x = cx - w / 2 + w * i / 40
        pts.append((x, cy - math.sin(t) * h * 0.62 + (x - cx) * tilt))
    for i in range(40, -1, -1):
        t = i / 40 * math.pi
        x = cx - w / 2 + w * i / 40
        pts.append((x, cy + math.sin(t) * h * 0.38 + (x - cx) * tilt))
    return poly(c.w, c.h, pts)


def eyes_natural(narrow=1.0):
    """Whites, a dark iris and a catch-light. Tinted only faintly."""
    c = face_canvas()
    for side in (-1, 1):
        cx = 256 + side * EYE_SPREAD
        white = almond(c, cx, EYE_Y, 84, 44 * narrow, tilt=-0.06 * side)
        c.paint(white, 0.93)
        c.shade(white * rect(FS, FS, 0, 0, FS, EYE_Y - 8 * narrow), 0.8)
        iris = ellipse(FS, FS, cx - side * 4, EYE_Y + 1, 17, 17)
        c.paint(iris * white, 0.28)
        pupil = ellipse(FS, FS, cx - side * 4, EYE_Y + 1, 8, 8)
        c.paint(pupil * white, 0.05)
        glint = ellipse(FS, FS, cx - side * 4 - 6, EYE_Y - 6, 4.5, 4.5)
        c.paint(glint * white, 1.0)
        lid = line(FS, FS, [(cx - 44, EYE_Y + 2 + side * 3), (cx - 20, EYE_Y - 22 * narrow), (cx + 20, EYE_Y - 24 * narrow), (cx + 44, EYE_Y - side * 3)], 6)
        c.paint(lid, 0.12)
    return c.image()


def eyes_glow(size=1.0):
    """Eyes that are all light: white here, whatever colour the tint makes them."""
    c = face_canvas()
    for side in (-1, 1):
        cx = 256 + side * EYE_SPREAD
        halo = almond(c, cx, EYE_Y, 110 * size, 64 * size, tilt=-0.08 * side)
        c.paint(blur(halo, 10) * 0.55, 0.9)
        core = almond(c, cx, EYE_Y, 84 * size, 40 * size, tilt=-0.08 * side)
        c.paint(core, 1.0)
        c.a = np.maximum(c.a, blur(halo, 12) * 0.5)
    return c.image()


def eyes_sockets():
    """Empty sockets with a pinpoint of light deep in each."""
    c = face_canvas()
    for side in (-1, 1):
        cx = 256 + side * EYE_SPREAD
        sock = ellipse(FS, FS, cx, EYE_Y + 4, 50, 40)
        c.paint(blur(sock, 8), 0.04)
        c.a = np.maximum(c.a, blur(sock, 8))
        pin = ellipse(FS, FS, cx, EYE_Y + 6, 9, 9)
        c.paint(blur(pin, 3), 1.0)
    return c.image()


def eyes_slits():
    c = face_canvas()
    for side in (-1, 1):
        cx = 256 + side * EYE_SPREAD
        slit = poly(FS, FS, [(cx - 50, EYE_Y - 8), (cx + 50, EYE_Y - 8 - side * 6), (cx + 46, EYE_Y + 8 - side * 6), (cx - 46, EYE_Y + 8)])
        c.paint(slit, 0.02)
        c.paint(blur(slit, 4) * 0.6, 0.02)
    return c.image()


def brows(c, tilt, y=EYE_Y - 64, thick=18):
    for side in (-1, 1):
        cx = 256 + side * EYE_SPREAD
        inner = (cx - side * 46, y + tilt)
        outer = (cx + side * 50, y - tilt * 0.4)
        mid = (cx, y - 8)
        c.paint(line(FS, FS, [inner, mid, outer], thick), 0.14)


def mouth(c, curve=0.0, width=120, thick=9):
    pts = [(256 - width / 2 + width * i / 20, MOUTH_Y - math.sin(i / 20 * math.pi) * curve) for i in range(21)]
    c.paint(line(FS, FS, pts, thick), 0.16)
    c.shade(line(FS, FS, [(256 - 24, MOUTH_Y + 18), (256 + 24, MOUTH_Y + 18)], 6), 0.0)
    c.paint(line(FS, FS, [(256 - 22, MOUTH_Y + 20), (256 + 22, MOUTH_Y + 20)], 6), 0.55)
    c.a = np.maximum(c.a, line(FS, FS, [(256 - 22, MOUTH_Y + 20), (256 + 22, MOUTH_Y + 20)], 6) * 0.25)


def nose(c):
    c.paint(line(FS, FS, [(262, EYE_Y + 40), (270, EYE_Y + 96), (252, EYE_Y + 104)], 6), 0.3)
    c.a = np.minimum(c.a, np.maximum(c.a * 0, c.a))


def face_base(tilt, curve=0.0, weary=False, width=120):
    c = face_canvas()
    brows(c, tilt)
    nose(c)
    mouth(c, curve, width)
    if weary:
        for side in (-1, 1):
            cx = 256 + side * EYE_SPREAD
            bag = line(FS, FS, [(cx - 36, EYE_Y + 30), (cx, EYE_Y + 40), (cx + 36, EYE_Y + 30)], 7)
            c.paint(blur(bag, 3), 0.3)
            c.a = np.maximum(c.a * 1, blur(bag, 3) * 0.6)
    return c.image()


def face_hollow():
    c = face_canvas()
    nose_hole = poly(FS, FS, [(256, EYE_Y + 60), (274, EYE_Y + 110), (238, EYE_Y + 110)])
    c.paint(blur(nose_hole, 3), 0.05)
    # a lipless grin of teeth
    m = rect(FS, FS, 170, MOUTH_Y - 18, 342, MOUTH_Y + 18)
    c.paint(blur(m, 3), 0.06)
    for i in range(9):
        x = 176 + i * 19
        tooth = rect(FS, FS, x, MOUTH_Y - 14, x + 15, MOUTH_Y + 14)
        c.paint(tooth, 0.8)
        c.shade(rect(FS, FS, x, MOUTH_Y - 1, x + 15, MOUTH_Y + 1), 0.3)
    return c.image()


def face_mask():
    """A visored half-mask, tinted with the trim colour."""
    c = face_canvas()
    m = poly(FS, FS, [(40, 110), (472, 110), (452, 330), (360, 420), (152, 420), (60, 330)])
    c.shade(blur(m, 8), 0.7)
    c.paint(m, metal(FS, FS, 0.9, seed=401))
    edge_darken(c, m, 4, 0.45)
    ridge = rect(FS, FS, 246, 110, 266, 420)
    c.paint(ridge, 1.0)
    c.shade(rect(FS, FS, 266, 110, 272, 420), 0.7)
    for x in (80, 432):
        for y in (150, 290):
            rivet(c, x, y, 9)
    for i in range(5):
        x = 200 + i * 28
        c.paint(rect(FS, FS, x, 360, x + 10, 400), 0.1)
    return c.image()


def marking_warpaint():
    c = face_canvas()
    band = poly(FS, FS, [(30, EYE_Y - 44), (482, EYE_Y - 44), (482, EYE_Y + 40), (30, EYE_Y + 40)])
    rough = np.clip(noise(FS, FS, 10, 501) * 0.5 + 0.8, 0, 1)
    c.paint(band * rough, 1.0)
    for side in (-1, 1):
        x = 256 + side * EYE_SPREAD
        drip = poly(FS, FS, [(x - 12, EYE_Y + 30), (x + 12, EYE_Y + 30), (x + 6, EYE_Y + 150), (x, EYE_Y + 160), (x - 6, EYE_Y + 150)])
        c.paint(drip * rough, 1.0)
    return c.image()


def marking_scar():
    c = face_canvas()
    pts = [(300, 90), (330, 180), (352, 280), (366, 350)]
    c.paint(line(FS, FS, pts, 16), 0.8)
    c.paint(line(FS, FS, [(p[0] - 3, p[1]) for p in pts], 5), 1.0)
    for t in (0.2, 0.45, 0.7):
        i = int(t * (len(pts) - 1))
        x = pts[i][0] + (pts[i + 1][0] - pts[i][0]) * (t * 3 - i)
        y = pts[i][1] + (pts[i + 1][1] - pts[i][1]) * (t * 3 - i)
        c.paint(line(FS, FS, [(x - 16, y - 4), (x + 16, y + 4)], 5), 0.7)
    return c.image()


def marking_brand():
    c = face_canvas()
    cx, cy = 150, 150
    ring = np.clip(ellipse(FS, FS, cx, cy, 46, 46) - ellipse(FS, FS, cx, cy, 32, 32), 0, 1)
    c.paint(blur(ring, 2), 1.0)
    c.paint(rect(FS, FS, cx - 36, cy - 6, cx + 36, cy + 6), 1.0)
    halo = blur(ellipse(FS, FS, cx, cy, 56, 56), 10)
    c.a = np.maximum(c.a, halo * 0.3)
    return c.image()


def marking_ash():
    c = face_canvas()
    smear = poly(FS, FS, [(60, EYE_Y + 60), (452, EYE_Y + 40), (440, 470), (80, 470)])
    streaks = np.clip(noise(FS, FS, 8, 511) * 0.4 + 0.6, 0, 1) * np.clip(noise(FS, FS, 60, 512) + 0.6, 0, 1)
    c.paint(blur(smear, 14), 1.0)
    c.a = blur(smear, 14) * streaks * 0.7
    return c.image()


def marking_tattoo():
    c = face_canvas()
    x = 150
    c.paint(line(FS, FS, [(x, 110), (x, 360)], 10), 1.0)
    for y, d in ((170, -1), (240, 1), (300, -1)):
        c.paint(line(FS, FS, [(x, y), (x + 50 * d, y - 40), (x + 70 * d, y - 30)], 8), 1.0)
    for y in (120, 360):
        c.paint(ellipse(FS, FS, x, y, 11, 11), 1.0)
    return c.image()


def marking_stitched():
    c = face_canvas()
    pts = [(320, 100), (330, 200), (322, 300), (330, 410)]
    c.paint(line(FS, FS, pts, 6), 0.15)
    for i in range(10):
        y = 110 + i * 32
        c.paint(line(FS, FS, [(302, y), (348, y + 10)], 6), 0.15)
    return c.image()


# --------------------------------------------------------------------------

SHIRTS = {
    "ragged": shirt_ragged,
    "tunic": shirt_tunic,
    "leathers": shirt_leathers,
    "plate": shirt_plate,
    "robes": shirt_robes,
    "tabard": shirt_tabard,
    "wrappings": shirt_wrappings,
    "cloak": shirt_cloak,
}

PANTS = {
    "trousers": pants_trousers,
    "ragged": pants_ragged,
    "greaves": pants_greaves,
    "robe": pants_robe,
    "wraps": pants_wraps,
}

OVERLAYS = {
    "ragged": overlay_ragged,
    "tunic": overlay_tunic,
    "leathers": overlay_leathers,
    "plate": overlay_plate,
    "robes": overlay_robes,
    "tabard": overlay_tabard,
    "wrappings": overlay_wrappings,
    "cloak": overlay_cloak,
}

FACES = {
    "face_steady": lambda: face_base(0),
    "face_grim": lambda: face_base(16, curve=-6),
    "face_weary": lambda: face_base(-12, curve=-2, weary=True),
    "face_fierce": lambda: face_base(20, curve=-10, width=100),
    "face_calm": lambda: face_base(-4, curve=4),
    "face_hollow": face_hollow,
    "face_mask": face_mask,
    "eyes_natural": eyes_natural,
    "eyes_narrow": lambda: eyes_natural(0.7),
    "eyes_glow": eyes_glow,
    "eyes_sockets": eyes_sockets,
    "eyes_slits": eyes_slits,
    "mark_warpaint": marking_warpaint,
    "mark_scar": marking_scar,
    "mark_brand": marking_brand,
    "mark_ash": marking_ash,
    "mark_tattoo": marking_tattoo,
    "mark_stitched": marking_stitched,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    jobs = []
    jobs += [(f"shirt_{k}", f) for k, f in SHIRTS.items()]
    jobs += [(f"pants_{k}", f) for k, f in PANTS.items()]
    jobs += [(f"overlay_{k}", f) for k, f in OVERLAYS.items()]
    jobs += list(FACES.items())
    for name, fn in jobs:
        if only and not any(o in name for o in only):
            continue
        fn().save(os.path.join(OUT, f"{name}.png"))
        print("wrote", name)


if __name__ == "__main__":
    main()
