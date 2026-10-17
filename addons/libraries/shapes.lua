-- Antialiased shapes drawn with renderer.draw_path (added in pbsurf/lite-xl).
local shapes = {}

---@class shapes.squiggle_options
---@field period? number Length of one full wave (default 4 * SCALE)
---@field height? number Peak-to-peak height (default 1.5 * SCALE)
---@field thickness? number Stroke width (default 1 * SCALE)

---Draw a squiggly line (e.g. under an error) from x to x + width, centered
---vertically on y. Drawn as a zigzag with round joins: line segments are
---several times cheaper for the renderer than curves.
---@param x number
---@param y number
---@param width number
---@param color renderer.color
---@param opts? shapes.squiggle_options
function shapes.squiggle(x, y, width, color, opts)
  if width <= 0 then return end
  opts = opts or {}
  local half = (opts.period or 4 * SCALE) / 2
  local h = (opts.height or 1.5 * SCALE) / 2
  local path = { "M", x, y + h }
  local n = math.floor(width / half)
  for i = 1, n do
    path[#path + 1] = "L"
    path[#path + 1] = x + i * half
    path[#path + 1] = y + (i % 2 == 1 and -h or h)
  end
  local rest = width - n * half
  if rest > 0 then
    -- partial last segment, ending on the same slope
    local from = n % 2 == 0 and h or -h
    path[#path + 1] = "L"
    path[#path + 1] = x + width
    path[#path + 1] = y + from - 2 * from * rest / half
  end
  renderer.draw_path(path, color, opts.thickness or SCALE)
end

---Draw a checkmark (✓) fitted in the square x, y, size, size.
---@param x number
---@param y number
---@param size number
---@param color renderer.color
---@param thickness? number Stroke width (default size / 7, at least 1 * SCALE)
function shapes.checkmark(x, y, size, color, thickness)
  renderer.draw_path({
    "M", x + size * 0.1, y + size * 0.55,
    "L", x + size * 0.38, y + size * 0.82,
    "L", x + size * 0.9, y + size * 0.2,
  }, color, thickness or math.max(SCALE, size / 7))
end

return shapes
