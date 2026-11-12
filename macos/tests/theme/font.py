# Writes a one-glyph TrueType font: font.py <out.ttf> <family>.
import sys
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

out, family = sys.argv[1], sys.argv[2]
fb = FontBuilder(1000, isTTF=True)
fb.setupGlyphOrder([".notdef", "a"])
fb.setupCharacterMap({ord("a"): "a"})
pen = TTGlyphPen(None)
pen.moveTo((0, 0)); pen.lineTo((500, 0)); pen.lineTo((500, 500)); pen.closePath()
glyph = pen.glyph()
fb.setupGlyf({".notdef": glyph, "a": glyph})
fb.setupHorizontalMetrics({".notdef": (600, 0), "a": (600, 0)})
fb.setupHorizontalHeader(ascent=800, descent=-200)
fb.setupNameTable({"familyName": family, "styleName": "Regular"})
fb.setupOS2()
fb.setupPost()
fb.save(out)
