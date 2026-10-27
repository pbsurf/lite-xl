---@meta

---
---Core functionality to render or draw elements into the screen.
---@class renderer
renderer = {}

---
---Array of bytes that represents a color used by the rendering functions.
---Note: indexes for rgba are numerical 1 = r, 2 = g, 3 = b, 4 = a but for
---documentation purposes the letters r, g, b, a were used.
---@class renderer.color
---@field public r number Red
---@field public g number Green
---@field public b number Blue
---@field public a number Alpha

---
---Represent options that affect a font's rendering.
---@class renderer.fontoptions
---@field public antialiasing "none" | "grayscale" | "subpixel"
---@field public hinting "slight" | "none" | "full"
---@field public bold boolean
---@field public italic boolean
---@field public underline boolean
---@field public smoothing boolean
---@field public strikethrough boolean

---
---@class renderer.font
renderer.font = {}

---
---Create a new font object.
---
---@param path string
---@param size number
---@param options? renderer.fontoptions
---
---@return renderer.font
function renderer.font.load(path, size, options) end

---
---Combines an array of fonts into a single one for broader charset support,
---the order of the list determines the fonts precedence when retrieving
---a symbol from it.
---
---@param fonts renderer.font[]
---
---@return renderer.font
function renderer.font.group(fonts) end

---
---Clones a font object into a new one.
---
---@param size? number Optional new size for cloned font.
---@param options? renderer.fontoptions
---
---@return renderer.font
function renderer.font:copy(size, options) end

---
---Set the amount of characters that represent a tab.
---
---@param chars integer Also known as tab width.
function renderer.font:set_tab_size(chars) end

---
---Set extra space after each character, as a fraction of the font size
---(like CSS `letter-spacing` in em; negative tightens), e.g. -0.125 for 3 px
---less per character at 24 px. It scales with `set_size` and is kept by `copy`.
---As text drawn this frame uses the font's current spacing, set it on a font
---of its own (a `copy`) rather than on one shared with other views.
---
---@param em number
function renderer.font:set_letter_spacing(em) end

---
---Get the letter spacing set with `set_letter_spacing`.
---
---@return number em
function renderer.font:get_letter_spacing() end

---
---Get the width in pixels of the given text when
---rendered with this font.
---
---@param text string
---
---@return number
function renderer.font:get_width(text) end

---
---Get the height in pixels that occupies a single character
---when rendered with this font.
---
---@return number
function renderer.font:get_height() end

---
---Get the current size of the font.
---
---@return number
function renderer.font:get_size() end

---
---Set a new size for the font.
---
---@param size number
function renderer.font:set_size(size) end

---
---Get the current path of the font as a string if a single font or as an
---array of strings if a group font.
---
---@return string | table<integer, string>
function renderer.font:get_path() end

---
---Toggles drawing debugging rectangles on the currently rendered sections
---of the window to help troubleshoot the renderer.
---
---@param enable boolean
function renderer.show_debug(enable) end

---
---Get the size of the screen area been rendered.
---
---@return number width
---@return number height
function renderer.get_size() end

---
---Save what the window shows as a PNG, for inspecting a running editor.
---
---@param path string
---@param x? integer Left of the area, in surface pixels (default 0).
---@param y? integer Top of the area (default 0).
---@param w? integer Width of the area (default: to the right edge).
---@param h? integer Height of the area (default: to the bottom edge).
---@param zoom? integer Integer scale-up with nearest neighbor, 1 to 16 (default 1).
---@return boolean? ok
---@return string? err
function renderer.save_screenshot(path, x, y, w, h, zoom) end

---
---Tell the rendering system that we want to build a new frame to render.
function renderer.begin_frame() end

---
---Tell the rendering system that we finished building the frame.
function renderer.end_frame() end

---
---Set the region of the screen where draw operations will take effect.
---
---@param x number
---@param y number
---@param width number
---@param height number
function renderer.set_clip_rect(x, y, width, height) end

---
---Draw a rectangle.
---
---@param x number
---@param y number
---@param width number
---@param height number
---@param color renderer.color
function renderer.draw_rect(x, y, width, height, color) end

---
---Draw an antialiased path, filled (nonzero winding) or stroked.
---
---The path is a flat list of commands, each followed by its coordinates:
---`"M", x, y` starts a subpath, `"L", x, y` a line, `"Q", cx, cy, x, y` a quadratic
---and `"C", c1x, c1y, c2x, c2y, x, y` a cubic Bézier, `"Z"` closes the subpath
---(and must be followed by `"M"`). Coordinates may be fractional.
---
---Strokes have round joins and butt caps; subpaths not closed with `"Z"` are open.
---Cost grows with the number of segments; for long wavy lines, prefer line
---segments with round joins over curves.
---
---@param path (string|number)[]
---@param color renderer.color
---@param stroke_width? number Stroke width; fills the path when nil or <= 0.
function renderer.draw_path(path, color, stroke_width) end

---
---Draw one glyph of a font as an antialiased shape fitted to a rectangle: its ink
---box is scaled to fit (keeping its aspect ratio) and centered in the rectangle.
---The font's size, hinting and synthesized bold/italic don't apply; the glyph is
---drawn from its outline, so any size and fractional position work. In a font
---group, the first font that has the glyph is used. Bitmap-only glyphs (e.g. color
---emoji) are not drawn.
---
---@param font renderer.font|renderer.font[]
---@param char string The glyph's character (the first one of the string).
---@param x number
---@param y number
---@param width number
---@param height number
---@param color renderer.color
function renderer.draw_glyph(font, char, x, y, width, height, color) end

---
---Draw the shadow of a box: the box blurred with a Gaussian, reaching `blur`
---beyond it (3 sigma), in the color (its alpha is the shadow's darkest). The
---box inset by `blur` is left out: draw the box (or one offset from it by less
---than `blur`) over it.
---
---@param x number
---@param y number
---@param width number
---@param height number
---@param blur number
---@param color renderer.color
function renderer.draw_shadow(x, y, width, height, blur, color) end

---
---Draw text and return the x coordinate where the text finished drawing.
---
---@param font renderer.font
---@param text string
---@param x number
---@param y number
---@param color renderer.color
---
---@return number x
function renderer.draw_text(font, text, x, y, color) end


return renderer
