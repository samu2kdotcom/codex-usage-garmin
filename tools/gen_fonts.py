#!/usr/bin/env python3
"""Rasteriza TTF/OTF a BMFont (.fnt texto + .png) para Connect IQ.

Salida: resources-<ancho>/fonts/{fonts.xml, *.fnt, *_0.png} por resolución
(240, 260, 280, 416, 454). Los tamaños base están dados para 260 px y se
escalan por ancho/260.

Por defecto usa tipografías libres (OFL) de fonts-src/, el par que más se
acerca a la identidad de ChatGPT/Codex:
  mono   Geist Mono  ~ cifras del héroe (tabulares, aire de terminal de Codex)
  sans   Geist       ~ títulos y cuerpo (grotesca suiza, el relevo libre de Söhne)
Söhne, la tipografía real de la interfaz de ChatGPT, es propietaria: Geist es
la aproximación OFL más cercana (misma familia de grotescas neutras, mismas
proporciones cerradas). Para usar tus propias fuentes pásalas por parámetro, o
déjalas en fonts-src/local/ (ignorado por git):

  python3 -I tools/gen_fonts.py --mono fonts-src/local/Mono.otf --sans fonts-src/local/Sans.otf

Si la fuente es variable, se fija el peso (--mono-weight / --sans-weight) y el
tamaño óptico se ajusta solo. Requiere Python 3 + Pillow (con FreeType).
"""
import argparse, os, sys
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# ASCII imprimible + español + signos usados por la UI
EXTRA = "áéíóúÁÉÍÓÚñÑüÜ¿¡·%–…°"
FULL = "".join(chr(c) for c in range(32, 127)) + EXTRA
DIGITS = "0123456789% :.,-/"

# ancho de pantalla -> carpeta
WIDTHS = [240, 260, 280, 416, 454]

# id, familia, peso, tamaño base (a 260 px), charset, interlínea (em)
#
# La interlínea se fija a la del diseño original (la misma retícula que ya está
# medida en Pages.mc: filas a hSmall + 7 px, párrafos con hSmall) en vez de la
# que trae la TTF, que en Geist es más holgada (~1.37 em) y bajaba la última
# fila de la pantalla principal encima de los puntos de página.
FONTS = [
    ("Hero", "mono", 500, 56, DIGITS, 1.39),
    ("Title", "sans", 600, 25, FULL, 1.40),
    ("Body", "sans", 500, 19, FULL, 1.25),
    ("Small", "sans", 400, 15, FULL, 1.24),
]


def open_font(path, px, weight):
    f = ImageFont.truetype(path, px)
    try:
        axes = f.get_variation_axes()
    except Exception:
        return f
    vals = []
    for a in axes:
        n = a["name"]
        n = n.decode() if isinstance(n, bytes) else n
        n = n.lower()
        if "weight" in n:
            v = weight
        elif "optical" in n or n == "opsz":
            v = px * 0.75
        else:
            v = a["default"]
        vals.append(max(a["minimum"], min(a["maximum"], v)))
    f.set_variation_by_axes(vals)
    return f


def build(path, px, weight, charset, fid, outdir, aa=True, line_em=None):
    f = open_font(path, px, weight)
    asc, desc = f.getmetrics()
    base = asc
    line = asc + desc
    if line_em:
        line = max(asc + 1, int(round(px * line_em)))
    glyphs = []
    for ch in charset:
        l, t, r, b = f.getbbox(ch, anchor="ls")
        w, h = max(r - l, 0), max(b - t, 0)
        img = None
        if w and h:
            img = Image.new("L", (w, h), 0)
            ImageDraw.Draw(img).text((-l, -t), ch, font=f, fill=255, anchor="ls")
            if not aa:
                img = img.point(lambda v: 255 if v > 127 else 0)
        glyphs.append((ch, img, l, base + t, round(f.getlength(ch)), w, h))
    # empaquetado por estantes, atlas de ancho fijo
    aw = 256 if px < 40 else 512
    x = y = rowh = 0
    placed = []
    for g in sorted(glyphs, key=lambda g: -g[6]):
        _, img, _, _, _, w, h = g
        if x + w + 1 > aw:
            x, y, rowh = 0, y + rowh + 1, 0
        placed.append((g, x, y))
        x += w + 1
        rowh = max(rowh, h)
    ah = 1
    while ah < y + rowh + 1:
        ah *= 2
    atlas = Image.new("L", (aw, ah), 0)
    for (g, gx, gy) in placed:
        if g[1] is not None:
            atlas.paste(g[1], (gx, gy))
    atlas.save(os.path.join(outdir, fid + "_0.png"))
    lines = [
        'info face="%s" size=-%d bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0' % (fid, px),
        "common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0 alphaChnl=1 redChnl=0 greenChnl=0 blueChnl=0" % (line, base, aw, ah),
        'page id=0 file="%s_0.png"' % fid,
        "chars count=%d" % len(placed),
    ]
    for (g, gx, gy) in sorted(placed, key=lambda p: ord(p[0][0])):
        ch, _, xo, yo, adv, w, h = g
        lines.append("char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=0 chnl=15"
                     % (ord(ch), gx, gy, w, h, xo, yo, adv))
    open(os.path.join(outdir, fid + ".fnt"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    return line, len(placed), aw * ah


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mono", default=os.path.join(ROOT, "fonts-src", "GeistMono.ttf"))
    ap.add_argument("--sans", default=os.path.join(ROOT, "fonts-src", "Geist.ttf"))
    ap.add_argument("--mono-weight", type=int, default=None, help="peso de la mono variable (por defecto 500)")
    ap.add_argument("--sans-weight", type=int, default=None, help="peso base de la sans variable (por defecto 400/500/600)")
    ap.add_argument("--no-aa", action="store_true", help="sin antialias")
    a = ap.parse_args()
    paths = {"mono": a.mono, "sans": a.sans}
    for k, p in paths.items():
        if not os.path.isfile(p):
            sys.exit("no existe la fuente %s: %s" % (k, p))
    for w in WIDTHS:
        s = w / 260.0
        outdir = os.path.join(ROOT, "resources-%d" % w, "fonts")
        os.makedirs(outdir, exist_ok=True)
        xml = ["<resources>", "    <fonts>"]
        info = []
        for fid, fam, wt, base, cs, line_em in FONTS:
            if fam == "mono" and a.mono_weight:
                wt = a.mono_weight
            if fam == "sans" and a.sans_weight:
                wt = a.sans_weight + (wt - 400)
            px = max(8, round(base * s))
            line, n, area = build(paths[fam], px, wt, cs, fid, outdir,
                                  aa=not a.no_aa, line_em=line_em)
            xml.append('        <font id="%s" filename="%s.fnt" antialias="true"/>' % (fid, fid))
            info.append("%s %dpx(h%d,%d glifos)" % (fid, px, line, n))
        xml += ["    </fonts>", "</resources>"]
        open(os.path.join(outdir, "fonts.xml"), "w").write("\n".join(xml) + "\n")
        print("%d: " % w + "; ".join(info))


if __name__ == "__main__":
    main()
