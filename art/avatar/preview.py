"""
A rough front-and-back picture of every garb on a blocky body, tinted the way
the game tints it, so the art can be judged without uploading anything.

    python art/avatar/preview.py   -- writes art/avatar/preview.png

It is flat: faces of the body pasted side by side, no lighting. Good enough
to see whether a belt lands on the waist and a colour reads.
"""

import os

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "textures")

SKIN = (205, 170, 142)

# garb -> (shirt, pants, overlay, shirt tint, pants tint, trim tint)
LOOKS = [
    ("ragged", "ragged", "ragged", (150, 142, 132), (120, 100, 80), (160, 120, 80)),
    ("tunic", "trousers", "tunic", (120, 84, 56), (60, 52, 50), (190, 150, 70)),
    ("leathers", "trousers", "leathers", (110, 78, 52), (70, 60, 52), (150, 90, 50)),
    ("plate", "greaves", "plate", (170, 172, 178), (150, 152, 158), (200, 160, 80)),
    ("robes", "robe", "robes", (40, 50, 90), (40, 50, 90), (190, 150, 70)),
    ("tabard", "trousers", "tabard", (130, 124, 116), (60, 52, 50), (140, 30, 36)),
    ("wrappings", "wraps", "wrappings", (190, 180, 160), (110, 90, 70), (160, 120, 80)),
    ("cloak", "trousers", "cloak", (60, 70, 50), (60, 52, 50), (200, 200, 205)),
]

FACES = [("face_steady", "eyes_natural", None), ("face_grim", "eyes_glow", (255, 140, 60)), ("face_hollow", "eyes_sockets", (120, 255, 200)), ("face_mask", "eyes_slits", None)]

S = 1  # template pixels per preview pixel


def load(name):
    return Image.open(os.path.join(TEX, f"{name}.png")).convert("RGBA")


def tint(img, rgb):
    a = np.asarray(img, np.float32).copy()
    for i in range(3):
        a[..., i] *= rgb[i] / 255
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def crop(img, x, y, w, h):
    return img.crop((x, y, x + w, y + h))


FRONT = {"torso": (231, 74), "rarm": (217, 355), "larm": (308, 355)}
BACK = {"torso": (427, 74), "rarm": (85, 355), "larm": (440, 355)}


def body(shirt, pants, overlay, face_imgs, skin, back=False):
    faces = BACK if back else FRONT
    W, H = 256, 420
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))

    def part(x, y, w, h):
        out.paste(Image.new("RGBA", (w, h), skin + (255,)), (x, y))

    tx, ty = 64, 90
    part(tx, ty, 128, 128)
    part(tx - 64, ty, 64, 128)
    part(tx + 128, ty, 64, 128)
    part(tx, ty + 128, 64, 128)
    part(tx + 64, ty + 128, 64, 128)
    # the character's right arm/leg is on the viewer's left from the front
    ra, la = ("rarm", "larm") if not back else ("larm", "rarm")
    for tex in (pants, shirt):
        out.alpha_composite(crop(tex, *faces["torso"], 128, 128), (tx, ty))
        out.alpha_composite(crop(tex, *faces[ra], 64, 128), (tx - 64, ty))
        out.alpha_composite(crop(tex, *faces[la], 64, 128), (tx + 128, ty))
    out.alpha_composite(crop(pants, *faces[ra], 64, 128), (tx, ty + 128))
    out.alpha_composite(crop(pants, *faces[la], 64, 128), (tx + 64, ty + 128))
    if not back and overlay is not None:
        o = overlay.resize((128, 102), Image.LANCZOS)
        out.alpha_composite(o, (tx, ty))
    # head
    hx, hy, hs = tx + 26, ty - 80, 76
    ImageDraw.Draw(out).rounded_rectangle([hx, hy, hx + hs, hy + hs], 14, fill=skin + (255,))
    if not back:
        for f in face_imgs:
            out.alpha_composite(f.resize((hs, hs), Image.LANCZOS), (hx, hy))
    return out


def main():
    cells = []
    for i, (shirt, pants, overlay, st, pt, tt) in enumerate(LOOKS):
        s = tint(load(f"shirt_{shirt}"), st)
        p = tint(load(f"pants_{pants}"), pt)
        o = tint(load(f"overlay_{overlay}"), tt)
        fb, eyes, eye_tint = FACES[i % len(FACES)]
        face_imgs = [load(fb) if fb != "face_mask" else tint(load(fb), tt), tint(load(eyes), eye_tint) if eye_tint else load(eyes)]
        cells.append(body(s, p, o, face_imgs, SKIN))
        cells.append(body(s, p, o, face_imgs, SKIN, back=True))
    cols = 8
    W, H = 256, 420
    rows = (len(cells) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * W, rows * H), (54, 50, 58, 255))
    for i, c in enumerate(cells):
        sheet.alpha_composite(c, ((i % cols) * W, (i // cols) * H))
    sheet.convert("RGB").save(os.path.join(HERE, "preview.png"))
    print("wrote preview.png")


if __name__ == "__main__":
    main()
