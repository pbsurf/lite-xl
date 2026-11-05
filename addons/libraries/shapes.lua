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

-- a quarter circle as a cubic Bézier: control points this far along the tangents
local KAPPA = 0.5522847498

---Draw a filled circle (or its outline, if `thickness` is given).
---@param cx number
---@param cy number
---@param r number
---@param color renderer.color
---@param thickness? number
function shapes.circle(cx, cy, r, color, thickness)
  local k = r * KAPPA
  renderer.draw_path({
    "M", cx + r, cy,
    "C", cx + r, cy + k, cx + k, cy + r, cx, cy + r,
    "C", cx - k, cy + r, cx - r, cy + k, cx - r, cy,
    "C", cx - r, cy - k, cx - k, cy - r, cx, cy - r,
    "C", cx + k, cy - r, cx + r, cy - k, cx + r, cy,
    "Z",
  }, color, thickness)
end

---Draw an arrow pointing right (a current line's marker), filled, fitted in the
---rect x, y, w, h: a shaft and a head, or with `head_only` just a triangle.
---@param x number
---@param y number
---@param w number
---@param h number
---@param color renderer.color
---@param head_only? boolean
function shapes.arrow(x, y, w, h, color, head_only)
  local cy = y + h / 2
  if head_only then
    renderer.draw_path({ "M", x, y, "L", x + w, cy, "L", x, y + h, "Z" }, color)
    return
  end
  local head = math.min(w, h * 0.9) -- the head's length
  local shaft = h * 0.4 / 2 -- half the shaft's thickness
  local hx = x + w - head
  renderer.draw_path({
    "M", x, cy - shaft, "L", hx, cy - shaft, "L", hx, y, "L", x + w, cy,
    "L", hx, y + h, "L", hx, cy + shaft, "L", x, cy + shaft, "Z",
  }, color)
end

---Draw a triangle pointing right, or down if `down` (a tree's expander), fitted
---in the square x, y, size, size.
---@param x number
---@param y number
---@param size number
---@param color renderer.color
---@param down? boolean
function shapes.expander(x, y, size, color, down)
  local a, b = size * 0.2, size * 0.8
  if down then
    renderer.draw_path({ "M", x + a, y + size * 0.32, "L", x + b, y + size * 0.32,
      "L", x + size / 2, y + size * 0.72, "Z" }, color)
  else
    renderer.draw_path({ "M", x + size * 0.32, y + a, "L", x + size * 0.72, y + size / 2,
      "L", x + size * 0.32, y + b, "Z" }, color)
  end
end

return shapes
