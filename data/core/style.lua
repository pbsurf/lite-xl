local common = require "core.common"
local style = {}

style.padding = { x = common.round(14 * SCALE), y = common.round(7 * SCALE) }
style.divider_size = common.round(1 * SCALE)
style.scrollbar_size = common.round(4 * SCALE)
style.expanded_scrollbar_size = common.round(12 * SCALE)
style.caret_width = common.round(2 * SCALE)
style.tab_width = common.round(170 * SCALE)

-- The function renderer.font.load can accept an option table as a second optional argument.
-- It shoud be like the following:
--
-- {antialiasing= "grayscale", hinting = "full"}
--
-- The possible values for each option are:
-- - for antialiasing: grayscale, subpixel
-- - for hinting: none, slight, full
--
-- The defaults values are antialiasing subpixel and hinting slight for optimal visualization
-- on ordinary LCD monitor with RGB patterns.
--
-- On High DPI monitor or non RGB monitor you may consider using antialiasing grayscale instead.
-- The antialiasing grayscale with full hinting is interesting for crisp font rendering.
style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 15 * SCALE)
style.big_font = style.font:copy(46 * SCALE)
style.icon_font = renderer.font.load(DATADIR .. "/fonts/icons.ttf", 16 * SCALE, {antialiasing="grayscale", hinting="full"})
style.icon_big_font = style.icon_font:copy(23 * SCALE)
style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 15 * SCALE)

-- Token types that color schemes may leave undefined, and the type whose
-- color (and font) to use instead.
style.syntax_fallbacks = { preprocessor = "keyword" }
local syntax_fallback_mt = {
  __index = function(t, type)
    local fallback = style.syntax_fallbacks[type]
    if fallback then return t[fallback] end
  end
}

style.syntax = setmetatable({}, syntax_fallback_mt)

-- This can be used to override fonts per syntax group.
-- The syntax highlighter will take existing values from this table and
-- override style.code_font on a per-token basis, so you can choose to eg.
-- render comments in an italic font if you want to.
style.syntax_fonts = setmetatable({}, syntax_fallback_mt)
-- style.syntax_fonts["comment"] = renderer.font.load(path_to_font, size_of_font, rendering_options)

style.log = {}

-- Popups (menus, tooltips, completion and hover lists) float over both the
-- editor and the panels, so a color scheme may give them their own colors:
-- style.popup_background and style.popup_border (drawn style.divider_size
-- wide). Without them, background3 and divider are used. style.popup_shadow,
-- if set, is the color of their shadow at its darkest (common.draw_popup_box).
local popup_fallbacks = { popup_background = "background3", popup_border = "divider" }
setmetatable(style, {
  __index = function(t, k)
    local fallback = popup_fallbacks[k]
    if fallback then return rawget(t, fallback) end
  end
})

return style
