"""Builds web/fonts/accidentals.woff2: ♭ ♮ ♯ from Bravura Text, scaled and
moved to sit in text like letters (Bravura places them for a staff, so ♭
rises far above capitals and ♯ hangs below the baseline). Run with the
original font as argument:

  docker run --rm -v "$PWD":/w -w /w python:3.12-alpine sh -c \\
    "pip install -q fonttools brotli && python tools/accidentals.py BravuraText.otf"

Bravura is under the SIL Open Font License with the Reserved Font Name
"Bravura", so the modified font has its own name. See web/fonts/OFL.txt.
"""
import sys

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont

SCALE = 0.825  # ♭ about as tall as a capital with an ascender
SIDE = 30  # side bearing, units of 1000/em
MIDDLE = 350  # ♮ and ♯ centred on half the cap height
GLYPHS = {"flat": 0x266D, "natural": 0x266E, "sharp": 0x266F}

src = TTFont(sys.argv[1])
gs = src.getGlyphSet()
cmap = src.getBestCmap()

order = [".notdef", *GLYPHS]
glyphs = {".notdef": TTGlyphPen(None).glyph()}
widths = {".notdef": 500}
for name, code in GLYPHS.items():
    g = cmap[code]
    b = BoundsPen(gs)
    gs[g].draw(b)
    x0, y0, x1, y1 = b.bounds
    dy = -y0 * SCALE if name == "flat" else MIDDLE - (y0 + y1) / 2 * SCALE
    pen = TTGlyphPen(None)
    # CFF outlines are cubic and counter-clockwise; TrueType wants quadratic, clockwise.
    gs[g].draw(TransformPen(Cu2QuPen(pen, 1.0, reverse_direction=True), (SCALE, 0, 0, SCALE, SIDE - x0 * SCALE, dy)))
    glyphs[name] = pen.glyph()
    widths[name] = round((x1 - x0) * SCALE + 2 * SIDE)

fb = FontBuilder(1000, isTTF=True)
fb.setupGlyphOrder(order)
fb.setupCharacterMap({code: name for name, code in GLYPHS.items()})
fb.setupGlyf(glyphs)
glyf = fb.font["glyf"]
fb.setupHorizontalMetrics({n: (widths[n], getattr(glyf[n], "xMin", 0)) for n in order})
fb.setupHorizontalHeader(ascent=900, descent=-200)
fb.setupNameTable({
    "familyName": "Piano Tunah Accidentals",
    "styleName": "Regular",
    "copyright": 'Copyright © 2015, Steinberg Media Technologies GmbH, with Reserved Font Name "Bravura". '
    "Modified for Piano Tunah: three accidentals scaled and moved for text.",
    "licenseDescription": "SIL Open Font License, Version 1.1",
    "licenseInfoURL": "https://openfontlicense.org",
})
fb.setupOS2(sTypoAscender=900, sTypoDescender=-200, usWinAscent=900, usWinDescent=200)
fb.setupPost()
fb.font.flavor = "woff2"
fb.save("web/fonts/accidentals.woff2")
print({n: widths[n] for n in GLYPHS})
