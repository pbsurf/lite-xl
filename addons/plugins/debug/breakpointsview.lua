local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local ResultsList = require "core.resultslist"
local shapes = require "libraries.shapes"
local breakpoints = require "plugins.debug.breakpoints"

---All breakpoints, by file and line, with the line's code: a checkbox enables
---or disables one (space too), Delete removes it, and selecting one shows its
---line. During a session, one the debugger couldn't place says so.
---@class debug.breakpointsview : core.view
local BreakpointsView = View:extend()

function BreakpointsView:new()
  BreakpointsView.super.new(self)
  self.scrollable = true
  -- { file, line }, in order
  self.items = {}
  self.version = nil
  self.selected_idx = nil
  self.hovered_row = nil
  -- file -> its lines, read for the code shown (docs open have theirs)
  self.file_lines = {}
  self.max_h_scroll = 0
end

local function debug() return require "plugins.debug" end

function BreakpointsView:get_name()
  self:update_items()
  return #self.items > 0 and ("Breakpoints: " .. #self.items) or "Breakpoints"
end

function BreakpointsView:get_workspace_state() return {} end
function BreakpointsView:from_workspace_state() return debug().get_view("breakpoints") end

function BreakpointsView:get_line_height()
  return style.padding.y + math.max(style.font:get_height(), style.code_font:get_height())
end

function BreakpointsView:update_items()
  breakpoints.load()
  if self.version == breakpoints.version then return end
  self.version = breakpoints.version
  local selected_idx = self.selected_idx
  local selected = self.items[selected_idx or 0]
  self.items = {}
  self.file_lines = {}
  self.selected_idx = nil
  for _, file in ipairs(breakpoints.files()) do
    for _, line in ipairs(breakpoints.lines(file)) do
      table.insert(self.items, { file = file, line = line })
      if selected and selected.file == file and selected.line == line then self.selected_idx = #self.items end
    end
  end
  -- removed: the one after it, or the last
  if selected and not self.selected_idx and #self.items > 0 then
    self.selected_idx = math.min(#self.items, selected_idx)
  end
  core.redraw = true
end

-- the code on a breakpoint's line: the open doc's, else the file's
function BreakpointsView:get_code(item)
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == item.file then return doc.lines[item.line] or "" end
  end
  local lines = self.file_lines[item.file]
  if not lines then
    lines = {}
    local f = io.open(item.file, "rb")
    if f then
      for l in f:lines() do table.insert(lines, l) end
      f:close()
    end
    self.file_lines[item.file] = lines
  end
  return lines[item.line] or ""
end

function BreakpointsView:get_scrollable_size()
  self:update_items()
  return math.max(#self.items, 1) * self:get_line_height() + style.padding.y
end

function BreakpointsView:get_h_scrollable_size() return self.max_h_scroll end

-- ResultsList's interface
function BreakpointsView:get_result_count() self:update_items() return #self.items end
function BreakpointsView:get_selected_index() return self.selected_idx end
function BreakpointsView:get_page_size() return math.max(1, math.floor(self.size.y / self:get_line_height()) - 1) end

function BreakpointsView:get_result_location(idx)
  local item = self.items[idx]
  if item then return item.file, item.line, 1 end
end

function BreakpointsView:set_selected_index(idx)
  self.selected_idx = idx
  local h = self:get_line_height()
  self.scroll.to.y = math.min(self.scroll.to.y, h * (idx - 1))
  self.scroll.to.y = math.max(self.scroll.to.y, h * idx + style.padding.y - self.size.y)
end

function BreakpointsView:row_at(x, y)
  -- a split's views all get the mouse's moves: only rows under it, in this one
  local p, s = self.position, self.size
  if x < p.x or x >= p.x + s.x or y < p.y or y >= p.y + s.y then return nil end
  local _, oy = self:get_content_offset()
  local idx = math.floor((y - oy) / self:get_line_height()) + 1
  return self.items[idx] and idx or nil
end

function BreakpointsView:checkbox_rect(x, y, h)
  local size = math.floor(style.font:get_height() * 0.75)
  return x, y + (h - size) / 2, size
end

function BreakpointsView:on_mouse_moved(x, y, ...)
  if BreakpointsView.super.on_mouse_moved(self, x, y, ...) then
    self.hovered_row = nil
    return true
  end
  self.hovered_row = self:row_at(x, y)
end

function BreakpointsView:on_mouse_left()
  BreakpointsView.super.on_mouse_left(self)
  self.hovered_row = nil
end

function BreakpointsView:toggle_enabled(idx)
  local item = self.items[idx]
  if item then breakpoints.set_enabled(item.file, item.line, not breakpoints.enabled(item.file, item.line)) end
end

function BreakpointsView:on_mouse_pressed(button, x, y, clicks)
  if BreakpointsView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local idx = self:row_at(x, y)
  if button ~= "left" or not idx then return end
  local ox = self:get_content_offset()
  local _, _, size = self:checkbox_rect(ox + style.padding.x, 0, 0)
  if x < ox + style.padding.x * 1.5 + size then
    self:toggle_enabled(idx)
  else
    self:click_result(idx, clicks)
  end
  return true
end

local function display_path(file)
  if common.path_belongs_to(file, core.project_dir) then
    return common.relative_path(core.project_dir, file)
  end
  return common.home_encode(file)
end

function BreakpointsView:draw_item(item, x, y, h, selected)
  local enabled = breakpoints.enabled(item.file, item.line)
  local cx, cy, size = self:checkbox_rect(x, y, h)
  renderer.draw_rect(cx, cy, size, size, style.dim)
  renderer.draw_rect(cx + SCALE, cy + SCALE, size - 2 * SCALE, size - 2 * SCALE, style.background)
  if enabled then shapes.checkmark(cx, cy, size, style.text) end
  x = cx + size + style.padding.x
  -- the gutter's marker
  local r = math.floor(style.code_font:get_height() * 0.28)
  if enabled then
    shapes.circle(x + r, y + h / 2, r, style.debug.breakpoint)
  else
    shapes.circle(x + r, y + h / 2, r - SCALE / 2, style.debug.breakpoint, SCALE)
  end
  x = x + 2 * r + style.padding.x
  x = common.draw_text(style.font, enabled and style.text or style.dim,
    display_path(item.file) .. ":" .. item.line, "left", x, y, 0, h)
  local code = self:get_code(item):gsub("^%s+", ""):gsub("%s+$", "")
  if #code > 200 then code = code:sub(1, 200) .. "…" end
  x = common.draw_text(style.code_font, selected and style.text or style.dim, "  " .. code, "left", x, y, 0, h)
  local session = debug().session
  local status = enabled and session and session.state ~= "ended" and session:get_breakpoint_status(item.file, item.line)
  if status and not status.verified then
    x = common.draw_text(style.font, style.warn, "  " .. (status.message or "not placed (no code there?)"), "left", x, y, 0, h)
  end
  return x
end

function BreakpointsView:draw()
  self:draw_background(style.background)
  self:update_items()
  local h = self:get_line_height()
  local ox, oy = self:get_content_offset()
  local _, _, w = self:get_content_bounds()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  if #self.items == 0 then
    common.draw_text(style.font, style.dim, "No breakpoints: a click in the gutter, or f9, sets one",
      "left", ox + style.padding.x, oy, 0, h)
  end
  for i, item in ipairs(self.items) do
    local y = oy + (i - 1) * h
    if y + h >= self.position.y and y < self.position.y + self.size.y then
      if i == self.selected_idx then
        renderer.draw_rect(ox, y, w, h, style.selection)
      elseif i == self.hovered_row then
        renderer.draw_rect(ox, y, w, h, style.line_highlight)
      end
      local x = self:draw_item(item, ox + style.padding.x, y, h, i == self.selected_idx)
      self.max_h_scroll = math.max(self.max_h_scroll, x + style.padding.x - self.position.x + self.scroll.x)
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

ResultsList.add_to(BreakpointsView, "debug-breakpoints")

command.add(function()
  local view = core.active_view
  return view:is(BreakpointsView) and view.selected_idx ~= nil and view.items[view.selected_idx] ~= nil, view
end, {
  ["debug-breakpoints:toggle-enabled"] = function(view) view:toggle_enabled(view.selected_idx) end,
  ["debug-breakpoints:remove"] = function(view)
    local item = view.items[view.selected_idx]
    breakpoints.set(item.file, item.line, false)
  end,
})

keymap.add {
  ["space"] = "debug-breakpoints:toggle-enabled",
  ["delete"] = "debug-breakpoints:remove",
}

return BreakpointsView
