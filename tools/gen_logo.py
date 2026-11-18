#!/usr/bin/env python3
"""Genera la marca (blossom de OpenAI, la de Codex/ChatGPT) para la app.

Fuente: tools/openai-blossom.svg = "OpenAI logo 2025 (symbol).svg" de Wikimedia
Commons (dominio público; la flor geométrica de OpenAI, usada desde 2025). App
personal NO oficial: solo identifica de qué producto habla el widget.

El símbolo se traza a polígonos para dibujarlo vectorial en el reloj (nítido a
cualquier tamaño y sin bitmaps en la glance de 64 KB). No es un polígono único:
es un nudo de cintas cóncavo, y fillPolygon de Connect IQ falla con polígonos
cóncavos grandes (abanica desde pts[0]). Por eso:

  1. se rasteriza el SVG (cairosvg) con margen,
  2. se parte el símbolo en seis sectores de 60° y se traza UN sector: sus trozos
     (dos) son polígonos simples, sin agujeros,
  3. cada trozo se rellena en abanico: centro + tramos de STEP puntos, que es lo
     que hace Logo.draw en Theme.mc,
  4. se emiten los trozos de un sexto en source/LogoMark.mc; el reloj dibuja ese
     sexto seis veces, girado 60° (el símbolo tiene simetría de orden 6).

Salida:
  - source/LogoMark.mc                            polígonos del sexto
  - resources{,-416,-454}/drawables/launcher_icon.png  (40, 60 y 65 px)

Requiere Python 3 con Pillow, numpy y cairosvg (o rsvg-convert/magick).
Uso: python3 -I tools/gen_logo.py [--check]
"""
import argparse
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageOps

try:
    import numpy as np
except ImportError:  # pragma: no cover
    sys.exit("falta numpy (pip install numpy)")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SVG = os.path.join(HERE, "openai-blossom.svg")
GRID = 200.0          # rejilla de salida (centro 100,100)
RASTER = 800          # lado del raster de trabajo (px)
PAD = 0.06            # margen alrededor del viewBox del SVG
SECTOR = 60.0         # ancho del sector que se traza (simetría de la marca)
EPS = 0.40            # simplificación RDP en unidades de la rejilla 0..200
STEP = 6              # puntos por tramo del abanico (igual que Theme.mc)

# Marca y launcher icon (paleta ChatGPT).
TEAL = (0x10, 0xA3, 0x7F)     # #10A37F, teal de ChatGPT
TEAL_MIP = (0x00, 0xAA, 0x55)  # #10A37F cuantizado a la paleta MIP (00/55/AA/FF)
BG_AMOLED = (0x21, 0x21, 0x21)
BG_MIP = (0x00, 0x00, 0x00)


# --------------------------------------------------------------------------- #
# SVG -> máscara
# --------------------------------------------------------------------------- #

def svg_padded(path, pad):
    raw = open(path, encoding="utf-8").read()
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', raw).group(1).split()]
    nx = vb[0] - vb[2] * pad
    ny = vb[1] - vb[3] * pad
    nw = vb[2] * (1 + 2 * pad)
    nh = vb[3] * (1 + 2 * pad)
    return re.sub(r'viewBox="[^"]+"',
                  'viewBox="%s"' % " ".join("%.4f" % v for v in (nx, ny, nw, nh)),
                  raw)


def rasterize(svg_text, px):
    """devuelve una PIL.Image 'L': 0 = tinta, 255 = fondo"""
    tmp = tempfile.mkdtemp()
    try:
        src = os.path.join(tmp, "mark.svg")
        dst = os.path.join(tmp, "mark.png")
        open(src, "w", encoding="utf-8").write(svg_text)
        try:
            import cairosvg
            cairosvg.svg2png(url=src, write_to=dst, output_width=px,
                             background_color="white")
        except Exception:
            if shutil.which("rsvg-convert"):
                subprocess.check_call(["rsvg-convert", "-w", str(px), "-b", "white",
                                       "-o", dst, src])
            elif shutil.which("magick"):
                subprocess.check_call(["magick", "-background", "white", "-density",
                                       str(px * 16), src, "-resize", "%dx" % px, dst])
            else:
                sys.exit("no puedo rasterizar el SVG: instala cairosvg, rsvg-convert o magick")
        return Image.open(dst).convert("L").copy()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# Contornos (marching squares) y simplificación
# --------------------------------------------------------------------------- #

def contours(mask):
    """Contornos de una máscara booleana, como listas de puntos (x, y) en px.

    Marching squares con puntos medios; los extremos sueltos que deja una
    frontera en diagonal se sueldan (a menos de 1.25 px) antes de recorrer."""
    h, w = mask.shape
    pad = np.zeros((h + 2, w + 2), bool)
    pad[1:-1, 1:-1] = mask
    a = pad[:-1, :-1]
    b = pad[:-1, 1:]
    c = pad[1:, 1:]
    d = pad[1:, :-1]
    idx = (a.astype("uint8") | (b.astype("uint8") << 1)
           | (c.astype("uint8") << 2) | (d.astype("uint8") << 3))
    segs = {}

    def add(p, q):
        segs.setdefault(p, []).append(q)
        segs.setdefault(q, []).append(p)

    for (y, x) in np.argwhere((idx != 0) & (idx != 15)):
        y = int(y) - 1
        x = int(x) - 1
        i = int(idx[y + 1, x + 1])
        t = (x + 0.5, y)
        r = (x + 1, y + 0.5)
        bo = (x + 0.5, y + 1)
        le = (x, y + 0.5)
        if i == 1:
            add(le, t)
        elif i == 2:
            add(t, r)
        elif i == 3:
            add(le, r)
        elif i == 4:
            add(r, bo)
        elif i == 5 or i == 6:
            add(t, bo)
        elif i == 7:
            add(r, bo)
        elif i == 8:
            add(bo, le)
        elif i == 9:
            add(bo, t)
        elif i == 10 or i == 11:
            add(le, r)
        elif i == 12:
            add(r, le)
        elif i == 13:
            add(r, t)
        elif i == 14:
            add(t, le)

    def weld():
        odd = [k for k, v in segs.items() if len(v) == 1]
        done = False
        for i, k in enumerate(odd):
            if k not in segs or len(segs[k]) != 1:
                continue
            best = None
            for j in range(i + 1, len(odd)):
                q = odd[j]
                if q not in segs or len(segs[q]) != 1:
                    continue
                dist = math.hypot(q[0] - k[0], q[1] - k[1])
                if dist <= 1.25 and (best is None or dist < best[0]):
                    best = (dist, q)
            if best is None:
                continue
            q = best[1]
            for r2 in list(segs[q]):
                segs[r2].remove(q)
                segs[r2].append(k)
                segs[k].append(r2)
            del segs[q]
            done = True
        return done

    for _ in range(64):
        if not weld():
            break

    loops = []
    while segs:
        start = next(iter(segs))
        loop = [start]
        cur, prev = start, None
        closed = False
        while True:
            nxt = [p for p in segs.get(cur, []) if p != prev]
            if not nxt:
                break
            n = nxt[0]
            segs[cur].remove(n)
            if n in segs and cur in segs[n]:
                segs[n].remove(cur)
            if not segs.get(cur):
                segs.pop(cur, None)
            if n == start:
                closed = True
                break
            loop.append(n)
            prev, cur = cur, n
            if cur not in segs:
                break
        if closed and len(loop) > 2:
            loops.append(loop)
        else:
            for k in list(loop):
                segs.pop(k, None)
    return loops


def poly_area(poly):
    s = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        s += x1 * y2 - x2 * y1
    return s / 2


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    (x1, y1), (x2, y2) = pts[0], pts[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = math.hypot(dx, dy) or 1e-9
    dist, at = 0.0, 0
    for k in range(1, len(pts) - 1):
        dd = abs(dy * pts[k][0] - dx * pts[k][1] + x2 * y1 - y2 * x1) / norm
        if dd > dist:
            dist, at = dd, k
    if dist > eps:
        return rdp(pts[:at + 1], eps)[:-1] + rdp(pts[at:], eps)
    return [pts[0], pts[-1]]


def simplify(poly, eps):
    far = max(range(len(poly)),
              key=lambda k: math.hypot(poly[k][0] - poly[0][0], poly[k][1] - poly[0][1]))
    first = rdp(poly[:far + 1], eps)
    second = rdp(poly[far:] + [poly[0]], eps)
    return first[:-1] + second[:-1]


# --------------------------------------------------------------------------- #
# Sexto del símbolo: trozos, abanico y validación
# --------------------------------------------------------------------------- #

def sixth(mask, cx, cy, side):
    """Trozos (polígonos en la rejilla 0..200) del sector de 60° centrado en 0°."""
    yy, xx = np.mgrid[0:mask.shape[0], 0:mask.shape[1]]
    ang = np.degrees(np.arctan2((yy - cy).astype(float), (xx - cx).astype(float)))
    wedge = mask & (np.abs(ang) <= SECTOR / 2)
    scale = GRID / side
    out = []
    for loop in contours(wedge):
        if abs(poly_area(loop)) * scale * scale < 0.5:
            continue
        pts = [(100 + (x - cx) * scale, 100 + (y - cy) * scale) for x, y in loop]
        out.append(simplify(pts, EPS))
    out.sort(key=lambda p: -abs(poly_area(p)))
    return out


def poly_mask(poly, size=RASTER):
    img = Image.new("L", (size, size), 0)
    ImageDraw.Draw(img).polygon([(x * size / GRID, y * size / GRID) for x, y in poly], fill=255)
    return np.asarray(img) > 127


def fan(poly, center, size=RASTER, step=STEP):
    """Rellena el polígono como lo hace Logo.draw: centro + tramos de `step`."""
    img = Image.new("L", (size, size), 0)
    dr = ImageDraw.Draw(img)
    k = size / GRID
    pts = [(x * k, y * k) for x, y in poly]
    c = (center[0] * k, center[1] * k)
    n = len(pts)
    for j in range(0, n, step):
        dr.polygon([c] + [pts[(j + q) % n] for q in range(step + 1)], fill=255)
    return np.asarray(img) > 127


def best_fan(poly):
    """Centro del abanico que mejor reproduce el polígono (y su IoU)."""
    exact = poly_mask(poly)
    ys, xs = np.nonzero(exact)
    best = (0.0, 100.0, 100.0)
    for gy in np.linspace(ys.min() / float(RASTER) * GRID, ys.max() / float(RASTER) * GRID, 13):
        for gx in np.linspace(xs.min() / float(RASTER) * GRID, xs.max() / float(RASTER) * GRID, 13):
            if not exact[min(RASTER - 1, int(gy * RASTER / GRID)),
                        min(RASTER - 1, int(gx * RASTER / GRID))]:
                continue
            got = fan(poly, (gx, gy))
            iou = (got & exact).sum() / max(1, (got | exact).sum())
            if iou > best[0]:
                best = (iou, gx, gy)
    return best


def render_mark(pieces, centers, size, angle=0.0):
    """La marca entera (6 giros de cada trozo) en un lienzo `size` px."""
    img = Image.new("L", (size * 4, size * 4), 0)
    dr = ImageDraw.Draw(img)
    k = size * 4 / GRID
    for poly, c in zip(pieces, centers):
        for r in range(6):
            a = math.radians(angle + 60.0 * r)
            ca, sa = math.cos(a), math.sin(a)
            pts = []
            for x, y in poly:
                x -= 100.0
                y -= 100.0
                pts.append(((100 + x * ca - y * sa) * k, (100 + x * sa + y * ca) * k))
            cx = c[0] - 100.0
            cy = c[1] - 100.0
            cc = ((100 + cx * ca - cy * sa) * k, (100 + cx * sa + cy * ca) * k)
            n = len(pts)
            for j in range(0, n, STEP):
                dr.polygon([cc] + [pts[(j + q) % n] for q in range(STEP + 1)], fill=255)
    return img.resize((size, size), Image.LANCZOS)


def write_logo_mc(pieces, centers):
    lines = []
    for poly in pieces:
        chunks = []
        for k in range(0, len(poly), 6):
            chunks.append("        " + ", ".join("%d, %d" % (round(x), round(y))
                                                 for x, y in poly[k:k + 6]))
        lines.append(",\n".join(chunks))
    src = """using Toybox.Lang;

//! GENERADO por tools/gen_logo.py — no editar a mano.
//! Marca de OpenAI (blossom 2025) en una rejilla 0..200 con centro 100,100,
//! partida en los trozos de un sexto del símbolo: el reloj los dibuja seis
//! veces, girados 60°. SVG de Wikimedia Commons (dominio público); app
//! personal no oficial.
(:glance)
module LogoMark {
    const SIZE = 200;
    const STEP = %d;                     //!< puntos por tramo del abanico
    const NP = %d;                       //!< trozos por sexto
    const N = [%s];   //!< puntos de cada trozo
    const CX = [%s];  //!< centro del abanico (x)
    const CY = [%s];  //!< centro del abanico (y)
    const PTS = [
%s
    ];
}
""" % (STEP, len(pieces),
       ", ".join(str(len(p)) for p in pieces),
       ", ".join("%d" % round(c[0]) for c in centers),
       ", ".join("%d" % round(c[1]) for c in centers),
       ",\n".join(lines))
    path = os.path.join(ROOT, "source", "LogoMark.mc")
    open(path, "w", encoding="utf-8").write(src)
    print("LogoMark.mc: %d trozos, %d puntos" % (len(pieces), sum(len(p) for p in pieces)))


# --------------------------------------------------------------------------- #
# Launcher icons
# --------------------------------------------------------------------------- #

def launcher_icons(svg_text):
    """Marca en el color de la app sobre fondo oscuro, supersample x8."""
    for folder, px in (("resources", 40), ("resources-416", 60), ("resources-454", 65)):
        mip = px == 40   # relojes MIP de 64 colores: color exacto de paleta
        ss = 8
        side = px * ss
        mask = rasterize(svg_text, side)
        m = np.asarray(mask) < 128
        # recorta al bounding box de la tinta para centrar por la marca, no por el viewBox
        ys, xs = np.nonzero(m)
        box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
        art = mask.crop(box)
        bg = BG_MIP if mip else BG_AMOLED
        fg = TEAL_MIP if mip else TEAL
        im = Image.new("RGB", (side, side), bg)
        # la marca ocupa el 74 % del lado, centrada
        target = int(side * 0.74)
        k = min(target / art.width, target / art.height)
        art = art.resize((max(1, int(art.width * k)), max(1, int(art.height * k))), Image.LANCZOS)
        tile = Image.new("RGB", art.size, fg)
        # alfa de la tinta: 255 donde el SVG pintó
        im.paste(tile, ((side - art.width) // 2, (side - art.height) // 2),
                 ImageOps.invert(art).point(lambda v: 255 if v > 110 else 0))
        im = im.resize((px, px), Image.LANCZOS)
        if mip:
            # binariza a fondo/marca: el compilador no debe tramar la glance
            pix = im.load()
            thr = (fg[1] + bg[1]) // 2
            for y in range(px):
                for x in range(px):
                    pix[x, y] = fg if pix[x, y][1] > thr else bg
        out = os.path.join(ROOT, folder, "drawables")
        os.makedirs(out, exist_ok=True)
        im.save(os.path.join(out, "launcher_icon.png"))
        print("launcher %s %dpx" % (folder, px))


# --------------------------------------------------------------------------- #

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true",
                    help="solo valida la geometría (no escribe nada)")
    a = ap.parse_args()

    svg = svg_padded(SVG, PAD)
    ref = rasterize(svg, RASTER)
    mask = np.asarray(ref) < 128
    ys, xs = np.nonzero(mask)
    cx = float(xs.mean())
    cy = float(ys.mean())
    side = float(max(xs.max() - xs.min(), ys.max() - ys.min()) + 1)
    print("raster %d px, tinta %d px, lado %.0f" % (RASTER, mask.sum(), side))

    pieces = sixth(mask, cx, cy, side)
    if not pieces:
        sys.exit("no he podido trazar el SVG")
    centers = []
    ok = True
    ink = Image.fromarray((mask * 255).astype("uint8"))
    x0 = int(round(cx - side / 2.0))
    y0 = int(round(cy - side / 2.0))
    refat = ink.crop((x0, y0, x0 + int(round(side)), y0 + int(round(side))))
    for i, poly in enumerate(pieces):
        iou, fx, fy = best_fan(poly)
        centers.append((fx, fy))
        print("  trozo %d: %d puntos, abanico %.3f en (%.0f, %.0f)" % (i, len(poly), iou, fx, fy))
        if iou < 0.95:
            ok = False
    # validación global: seis giros del sexto contra el raster de referencia
    for size in (200, 50):
        got = np.asarray(render_mark(pieces, centers, size)) > 127
        want = np.asarray(refat.resize((size, size), Image.LANCZOS)) > 127
        iou = (got & want).sum() / max(1, (got | want).sum())
        print("  marca %d px: IoU %.3f" % (size, iou))
        if size == 200 and iou < 0.93:
            ok = False
    if not ok:
        sys.exit("geometría fuera de tolerancia")
    if a.check:
        return
    write_logo_mc(pieces, centers)
    launcher_icons(svg)


if __name__ == "__main__":
    main()
