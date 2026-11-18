#!/usr/bin/env python3
"""Compone capturas "bonitas" del simulador sobre la carcasa real del dispositivo.

Uso:
  python3 -I tools/marketing_shots.py --device fenix7 --out img/tweet \\
      uso=/ruta/screen1.png semana=/ruta/screen2.png ...

- Carcasa e área de pantalla: ~/.Garmin/ConnectIQ/Devices/<id>/simulator.json + <imagen>.png
- La pantalla (260x260 MIP) se escala por vecino más cercano (píxel nítido, fiel al
  reloj) y la carcasa con Lanczos, ambas a la misma escala.
- Salidas: <out>/<nombre>.png (4:5, una por pantalla) y <out>/collage.png (16:9, 3 relojes).
"""
import argparse
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

BG_TOP = (0x21, 0x21, 0x21)      # ChatGPT modo oscuro
BG_BOT = (0x0E, 0x0E, 0x0E)
ACCENT = (0x10, 0xA3, 0x7F)      # teal de marca


def cutout(skin):
    """La imagen del SDK trae fondo blanco opaco: lo vuelve transparente
    (relleno desde las esquinas) y suaviza el borde para que no quede halo."""
    key = (255, 0, 255)
    rgb = skin.convert("RGB")
    for p in ((0, 0), (rgb.width - 1, 0), (0, rgb.height - 1), (rgb.width - 1, rgb.height - 1)):
        if rgb.getpixel(p) != key:
            ImageDraw.floodfill(rgb, p, key, thresh=60)
    alpha = Image.new("L", rgb.size, 255)
    ap, rp = alpha.load(), rgb.load()
    for yy in range(rgb.height):
        for xx in range(rgb.width):
            if rp[xx, yy] == key:
                ap[xx, yy] = 0
    alpha = alpha.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
    out = skin.copy()
    out.putalpha(Image.composite(alpha, Image.new("L", rgb.size, 0), skin.split()[3]))
    return out


def device(dev):
    base = os.path.expanduser(f"~/.Garmin/ConnectIQ/Devices/{dev}")
    sim = json.load(open(os.path.join(base, "simulator.json")))
    loc = sim["display"]["location"]
    skin = Image.open(os.path.join(base, sim["image"])).convert("RGBA")
    return cutout(skin), (loc["x"], loc["y"], loc["width"], loc["height"]), sim["display"].get("shape")


def watch(skin, loc, shape, screen_png, k):
    x, y, w, h = loc
    big = skin.resize((skin.width * k, skin.height * k), Image.LANCZOS)
    scr = Image.open(screen_png).convert("RGBA").resize((w * k, h * k), Image.NEAREST)
    mask = Image.new("L", (w * k * 4, h * k * 4), 0)
    d = ImageDraw.Draw(mask)
    if shape == "round":
        d.ellipse((0, 0, mask.width - 1, mask.height - 1), fill=255)
    else:
        d.rectangle((0, 0, mask.width, mask.height), fill=255)
    mask = mask.resize((w * k, h * k), Image.LANCZOS)
    big.paste(scr, (x * k, y * k), mask)
    return big


def background(W, H):
    bg = Image.new("RGB", (W, H), BG_TOP)
    px = bg.load()
    for yy in range(H):
        t = yy / max(1, H - 1)
        c = tuple(int(BG_TOP[i] * (1 - t) + BG_BOT[i] * t) for i in range(3))
        for xx in range(W):
            px[xx, yy] = c
    # halo teal muy suave detrás del reloj
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    r = int(min(W, H) * 0.36)
    gd.ellipse((W // 2 - r, H // 2 - r, W // 2 + r, H // 2 + r), fill=ACCENT)
    glow = glow.filter(ImageFilter.GaussianBlur(r * 0.55))
    return Image.blend(bg, Image.composite(glow, bg, Image.new("L", (W, H), 255)), 0.16)


def place(canvas, img, cx, cy, h):
    s = h / img.height
    im = img.resize((int(img.width * s), int(img.height * s)), Image.LANCZOS)
    sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    a = im.split()[3].point(lambda v: int(v * 0.55))
    blk = Image.new("RGBA", im.size, (0, 0, 0, 255))
    blk.putalpha(a)
    sh.paste(blk, (cx - im.width // 2 + 10, cy - im.height // 2 + 28), blk)
    sh = sh.filter(ImageFilter.GaussianBlur(28))
    canvas.alpha_composite(sh)
    canvas.alpha_composite(im, (cx - im.width // 2, cy - im.height // 2))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--device", default="fenix7")
    ap.add_argument("--out", required=True)
    ap.add_argument("--scale", type=int, default=4)
    ap.add_argument("--collage", default="", help="3 nombres separados por comas (orden izq,centro,der)")
    ap.add_argument("shots", nargs="+", help="nombre=ruta.png")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    skin, loc, shape = device(a.device)
    watches = {}
    for s in a.shots:
        name, _, path = s.partition("=")
        watches[name] = watch(skin, loc, shape, path, a.scale)
        W, H = 1600, 2000
        c = background(W, H).convert("RGBA")
        place(c, watches[name], W // 2, H // 2, int(H * 0.86))
        c.convert("RGB").save(os.path.join(a.out, f"{name}.png"), optimize=True)
        print("ok", name)
    names = [n for n in a.collage.split(",") if n] or list(watches)[:3]
    if len(names) == 3:
        W, H = 2400, 1350
        c = background(W, H).convert("RGBA")
        hh = int(H * 0.92)
        place(c, watches[names[0]], int(W * 0.21), H // 2 + 20, int(hh * 0.86))
        place(c, watches[names[2]], int(W * 0.79), H // 2 + 20, int(hh * 0.86))
        place(c, watches[names[1]], W // 2, H // 2, hh)
        c.convert("RGB").save(os.path.join(a.out, "collage.png"), optimize=True)
        print("ok collage", names)


if __name__ == "__main__":
    sys.exit(main())
