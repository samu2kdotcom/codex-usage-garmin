#!/usr/bin/env python3
"""Genera el isotipo (spark) de Claude para la app.

Lee tools/claude-symbol.svg (SVG público "Claude AI symbol", Wikimedia Commons;
uso personal no oficial), lo aplana a un polígono, lo simplifica y escribe:
  - source/Spark.mc          : puntos (rejilla 0..200) para fillPolygon
  - resources*/drawables/launcher_icon.png (40, 60 y 65 px)

Uso: python3 -I tools/gen_logo.py
"""
import math, os, re, sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GRID = 200.0 / 100.0   # el SVG es 100x100 -> rejilla 0..200


def parse_path(d):
    toks = re.findall(r"[a-zA-Z]|-?\d*\.?\d+(?:e-?\d+)?", d)
    i = 0
    pts = []
    x = y = sx = sy = 0.0
    cmd = None

    def num():
        nonlocal i
        v = float(toks[i]); i += 1
        return v

    while i < len(toks):
        if re.match(r"[a-zA-Z]", toks[i]):
            cmd = toks[i]; i += 1
            if cmd in "zZ":
                break
        if cmd == "m":
            x += num(); y += num(); sx, sy = x, y; pts.append((x, y)); cmd = "l"
        elif cmd == "l":
            x += num(); y += num(); pts.append((x, y))
        elif cmd == "L":
            x = num(); y = num(); pts.append((x, y))
        elif cmd == "H":
            x = num(); pts.append((x, y))
        elif cmd == "V":
            y = num(); pts.append((x, y))
        elif cmd == "h":
            x += num(); pts.append((x, y))
        elif cmd == "v":
            y += num(); pts.append((x, y))
        elif cmd == "c":
            c1 = (x + num(), y + num()); c2 = (x + num(), y + num()); e = (x + num(), y + num())
            p0 = (x, y)
            for k in range(1, 7):
                t = k / 6.0; u = 1 - t
                pts.append((u**3*p0[0] + 3*u*u*t*c1[0] + 3*u*t*t*c2[0] + t**3*e[0],
                            u**3*p0[1] + 3*u*u*t*c1[1] + 3*u*t*t*c2[1] + t**3*e[1]))
            x, y = e
        else:
            raise SystemExit("comando SVG no soportado: %r" % cmd)
    return pts


def dp(pts, eps):
    if len(pts) < 3:
        return pts
    (x1, y1), (x2, y2) = pts[0], pts[-1]
    dx, dy = x2 - x1, y2 - y1
    n = math.hypot(dx, dy) or 1e-9
    md, mi = 0, 0
    for k in range(1, len(pts) - 1):
        dd = abs(dy * pts[k][0] - dx * pts[k][1] + x2 * y1 - y2 * x1) / n
        if dd > md:
            md, mi = dd, k
    if md > eps:
        return dp(pts[:mi + 1], eps)[:-1] + dp(pts[mi:], eps)
    return [pts[0], pts[-1]]


def load():
    svg = open(os.path.join(HERE, "claude-symbol.svg"), encoding="utf-8").read()
    d = re.search(r'<path d="([^"]+)"', svg).group(1)
    pts = parse_path(d)
    # recentra en la caja 0..100 por su bounding box
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    side = max(max(xs) - min(xs), max(ys) - min(ys))
    return [((p[0] - cx) / side * 100 + 50, (p[1] - cy) / side * 100 + 50) for p in pts]


def main():
    pts = load()
    # polígono cerrado: se parte por el punto más lejano al primero
    far = max(range(len(pts)), key=lambda k: math.hypot(pts[k][0] - pts[0][0], pts[k][1] - pts[0][1]))
    a = dp(pts[:far + 1], 0.35)
    b = dp(pts[far:] + [pts[0]], 0.35)
    simp = a[:-1] + b[:-1]
    ints = [(round(x * GRID), round(y * GRID)) for x, y in simp]
    out = []
    for k in range(0, len(ints), 8):
        out.append("        " + ", ".join("%d, %d" % p for p in ints[k:k + 8]))
    src = """using Toybox.Lang;

//! GENERADO por tools/gen_logo.py - no editar a mano.
//! Isotipo (spark) de Claude como polígono en una rejilla 0..200 (centro 100,100).
//! Forma tomada del SVG público "Claude AI symbol" (Wikimedia Commons);
//! uso personal no oficial.
(:glance)
module Spark {
    const N = %d;
    const SIZE = 200;
    const PTS = [
%s
    ];
}
""" % (len(ints), ",\n".join(out))
    open(os.path.join(ROOT, "source", "Spark.mc"), "w", encoding="utf-8").write(src)
    print("Spark.mc: %d puntos" % len(ints))

    # Launcher icons: spark naranja sobre fondo oscuro, supersample x8
    for folder, px in (("resources", 40), ("resources-416", 60), ("resources-454", 65)):
        ss = 8
        S = px * ss
        # 40 px = relojes MIP de 64 colores (fr955, fr255, fēnix 7): colores
        # exactos de paleta y sin tramado (si no, el compilador lo tramaba y
        # en la glance salía un cuadrado ruidoso).
        mip = px == 40
        bg = (0, 0, 0) if mip else (0x26, 0x26, 0x24)
        fg = (0xFF, 0x55, 0x00) if mip else (0xD9, 0x77, 0x57)
        im = Image.new("RGB", (S, S), bg)
        dr = ImageDraw.Draw(im)
        k = 0.78 * S / 100.0
        off = (S - 100 * k) / 2
        dr.polygon([(off + x * k, off + y * k) for x, y in pts], fill=fg)
        im = im.resize((px, px), Image.LANCZOS)
        if mip:
            # Binariza a fondo/naranja (umbral 50 %): sin tonos intermedios.
            pix = im.load()
            for yy in range(px):
                for xx in range(px):
                    r = pix[xx, yy][0]
                    pix[xx, yy] = fg if r >= 0x80 else bg
        d = os.path.join(ROOT, folder, "drawables")
        os.makedirs(d, exist_ok=True)
        im.save(os.path.join(d, "launcher_icon.png"))
        print("launcher", folder, px)


if __name__ == "__main__":
    main()
