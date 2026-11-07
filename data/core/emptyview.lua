local style = require "core.style"
local keymap = require "core.keymap"
local View = require "core.view"

---@class core.emptyview : core.view
---@field super core.view
local EmptyView = View:extend()

function EmptyView:__tostring() return "EmptyView" end

function EmptyView:get_name()
  return "Get Started"
end

function EmptyView:get_filename()
  return ""
end

---The lines beside the title: `fmt` with a command's key binding (left out if
---the command has none), or as is without `cmd`. An instance can have its own.
---@type { fmt: string, cmd?: string }[]
EmptyView.lines = {
  { fmt = "%s to run a command", cmd = "core:find-command" },
  { fmt = "%s to open a file from the project", cmd = "core:find-file" },
  { fmt = "%s to change project folder", cmd = "core:change-project-folder" },
  { fmt = "%s to open a project folder", cmd = "core:open-project-folder" },
}

---Whether the title (and version) is drawn, left of the lines.
EmptyView.show_title = true

local function get_lines(self)
  local lines = {}
  for _, line in ipairs(self.lines) do
    local key = line.cmd and keymap.get_binding(line.cmd)
    if not line.cmd or key then table.insert(lines, string.format(line.fmt, key)) end
  end
  return lines
end

local function draw_text(self, x, y, color)
  local lines = get_lines(self)
  local lh = style.font:get_height() + style.padding.y
  local dh = #lines * lh - style.padding.y
  if self.show_title then
    local th = style.big_font:get_height()
    dh = 2 * th + style.padding.y * 2
    local x1, y1 = x, y + ((dh - th) / #lines)
    local xv = x1
    local title = "Lite XL"
    local version = "version " .. VERSION
    local title_width = style.big_font:get_width(title)
    local version_width = style.font:get_width(version)
    if version_width > title_width then
      version = VERSION
      version_width = style.font:get_width(version)
      xv = x1 - (version_width - title_width)
    end
    x = renderer.draw_text(style.big_font, title, x1, y1, color)
    renderer.draw_text(style.font, version, xv, y1 + th, color)
    x = x + style.padding.x
    renderer.draw_rect(x, y, math.ceil(1 * SCALE), dh, color)
    x = x + style.padding.x
  end
  y = y + (dh - lh * #lines) / 2
  local w = 0
  for _, text in ipairs(lines) do
    w = math.max(w, renderer.draw_text(style.font, text, x, y, color))
    y = y + lh
  end
  return w, dh
end

function EmptyView:draw()
  self:draw_background(style.background)
  local w, h = draw_text(self, 0, 0, { 0, 0, 0, 0 })
  local x = self.position.x + math.max(style.padding.x, (self.size.x - w) / 2)
  local y = self.position.y + (self.size.y - h) / 2
  draw_text(self, x, y, style.dim)
end

return EmptyView
