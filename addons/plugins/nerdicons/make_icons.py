# Writes icons.ttf, nerdicons' icons that the Nerd Font lacks, from the Nerd
# Font's own glyphs (MIT), so they match the others:
#   U+E000  h-hexagon: the C icon's hexagon (custom-c, U+E61E) with an H cut out
# Run with fontforge, from this directory, giving the Nerd Font (the
# font_symbols_nerdfont_mono_regular library, installed in the user dir):
#   fontforge -lang=py -script make_icons.py \
#     $USERDIR/libraries/font_symbols_nerdfont_mono_regular/SymbolsNerdFontMono-Regular.ttf
import fontforge, sys

src = fontforge.open(sys.argv[1])
out = fontforge.font()
out.em, out.ascent, out.descent = src.em, src.ascent, src.descent
out.fontname = out.familyname = out.fullname = "NerdiconsExtra"
out.copyright = "Derived from Nerd Fonts symbols (MIT)"

def letter_hole(quadratic, rect, stem, bar):
    """an H, centered in rect (x0, y0, x1, y1), as a hole (counter-clockwise)"""
    a, lo, b, hi = rect
    cy = (lo + hi) / 2
    m0, m1 = cy - bar / 2, cy + bar / 2
    hole = fontforge.contour()
    hole.is_quadratic = quadratic
    for x, y in [(a, lo), (a + stem, lo), (a + stem, m0), (b - stem, m0), (b - stem, lo),
                 (b, lo), (b, hi), (b - stem, hi), (b - stem, m1), (a + stem, m1),
                 (a + stem, hi), (a, hi)]:
        hole += fontforge.point(x, y)
    hole.closed = True
    if hole.isClockwise():
        hole.reverse()
    return hole

c = src[0xe61e]
# the outline, without the C cut out of it
hexagon = max(c.foreground, key=lambda k: k.boundingBox()[2] - k.boundingBox()[0])
x0, y0, x1, y1 = hexagon.boundingBox()
cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
# about the C's size and stroke (the C spans 401..1550 x -10..1227)
w, h = 1000, 1200
glyph = out.createChar(0xe000, "h_hexagon")
glyph.width = c.width
layer = fontforge.layer()
layer.is_quadratic = hexagon.is_quadratic
layer += hexagon.dup()
layer += letter_hole(hexagon.is_quadratic, (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), 280, 250)
glyph.foreground = layer

out.generate("icons.ttf")
