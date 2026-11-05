local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local ResultsList = require "core.resultslist"

---The stopped thread's frames, innermost first: the function with its
---arguments, and where it is. Frames outside the project (just my code) are
---dimmed, runs of them folded into one row, which a click unfolds. Selecting
---a frame (a click, arrow keys) selects it in the session, so the variables
---are its, and shows its line; Enter or a double click moves the focus there.
---@class debug.stackview : core.view
local StackView = View:extend()

function StackView:new()
  StackView.super.new(self)
  self.scrollable = true
  -- the rows: { frame = index } or { fold = { first, last } }
  self.rows = {}
  self.selected_row = nil
  self.hovered_row = nil
  -- folds opened: first frame's index -> true, for this stop
  self.unfolded = {}
  self.generation = nil
  self.max_h_scroll = 0
end

local function debug() return require "plugins.debug" end

function StackView:get_name() return "Call Stack" end

function StackView:get_workspace_state() return {} end
function StackView:from_workspace_state() return debug().get_view("stack", self) end

function StackView:get_line_height()
  return style.padding.y + math.max(style.font:get_height(), style.code_font:get_height())
end

-- rebuilt when the session's frames change
function StackView:update_rows()
  local session = debug().session
  local frames = session and session.frames
  if self.frames == frames and self.frame_index == (session and session.frame_index) then return end
  if not session or session.generation ~= self.generation then self.unfolded = {} end
  self.generation = session and session.generation
  self.frames = frames
  self.frame_index = session and session.frame_index
  self.rows = {}
  self.selected_row = nil
  local i = 1
  while frames and i <= #frames do
    local f = frames[i]
    -- a run of external frames, but not the selected one
    local last = i
    if f.external and i ~= self.frame_index then
      while frames[last + 1] and frames[last + 1].external and last + 1 ~= self.frame_index do last = last + 1 end
    end
    if last > i and not self.unfolded[i] then
      table.insert(self.rows, { fold = { i, last } })
      i = last + 1
    else
      for j = i, last do
        table.insert(self.rows, { frame = j })
        if j == self.frame_index then self.selected_row = #self.rows end
      end
      i = last + 1
    end
  end
end

-- the header row (why it stopped) comes first
function StackView:get_scrollable_size()
  self:update_rows()
  return (#self.rows + 1) * self:get_line_height()
end

function StackView:get_h_scrollable_size() return self.max_h_scroll end

-- ResultsList's interface: a result is a row
function StackView:get_result_count() self:update_rows() return #self.rows end
function StackView:get_selected_index() self:update_rows() return self.selected_row end
function StackView:get_page_size() return math.max(1, math.floor(self.size.y / self:get_line_height()) - 2) end

function StackView:get_result_location(idx)
  local row = self.rows[idx]
  local frame = row and row.frame and self.frames[row.frame]
  if frame and frame.file and frame.line and system.get_file_info(frame.file) then
    return frame.file, frame.line, 1
  end
end

function StackView:set_selected_index(idx)
  self.selected_row = idx
  local h = self:get_line_height()
  self.scroll.to.y = math.min(self.scroll.to.y, h * (idx - 1))
  self.scroll.to.y = math.max(self.scroll.to.y, h * (idx + 1) - self.size.y)
end

---Selects a row: a frame is selected in the session and its line shown; a
---fold is opened.
function StackView:select(idx)
  self:update_rows()
  if #self.rows == 0 then return end
  idx = common.clamp(idx, 1, #self.rows)
  local row = self.rows[idx]
  if not row then return end
  if row.fold then
    self.unfolded[row.fold[1]] = true
    self.frames = nil -- rebuild
    self:update_rows()
    -- the fold's first frame is at the fold's row now
    row = self.rows[idx]
  end
  self:set_selected_index(idx)
  if row.frame then debug().session:select_frame(row.frame) end
  self.frame_index = debug().session.frame_index
  self.shown = nil
  local file, line = self:get_result_location(idx)
  if file and core.root_view:can_peek(self) then
    self.shown = core.root_view:peek_file(file, line, 1)
  end
end

function StackView:open_selected()
  local idx = self:get_selected_index()
  if not idx then return end
  local file, line = self:get_result_location(idx)
  if not file then return end
  local dv = self.shown or core.root_view:peek_file(file, line, 1)
  if dv then core.set_active_view(dv) end
  return dv
end

function StackView:row_at(x, y)
  local _, oy = self:get_content_offset()
  local idx = math.floor((y - oy) / self:get_line_height())
  return idx >= 1 and idx <= #self.rows and idx or nil
end

function StackView:on_mouse_moved(x, y, ...)
  if StackView.super.on_mouse_moved(self, x, y, ...) then
    self.hovered_row = nil
    return true
  end
  self:update_rows()
  self.hovered_row = self:row_at(x, y)
end

function StackView:on_mouse_left()
  StackView.super.on_mouse_left(self)
  self.hovered_row = nil
end

function StackView:on_mouse_pressed(button, x, y, clicks)
  if StackView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local idx = self:row_at(x, y)
  if button == "left" and idx then
    self:select(idx)
    if clicks > 1 or not core.root_view:can_peek(self) then self:open_selected() end
    return true
  end
end

local function display_path(file)
  if common.path_belongs_to(file, core.project_dir) then
    return common.relative_path(core.project_dir, file)
  end
  return common.home_encode(file)
end

function StackView:draw_header(x, y, h)
  local session = debug().session
  local text, color = "Not debugging", style.dim
  if session then
    if session.state == "stopped" then
      text = session.stop and session.stop.description or "Stopped"
      color = session.stop and session.stop.signal and style.error or style.text
      if not session.frames then text = text .. " …" end
    elseif session.state == "running" then text = "Running"
    elseif session.state == "starting" then text = "Starting"
    elseif session.state == "ended" then
      text = session.exit and (session.exit.description or ("Exited with code " .. session.exit.code))
        or (session.error and ("Failed: " .. session.error) or "Stopped")
      color = session.error and style.error or style.dim
    end
  end
  return common.draw_text(style.font, color, text, "left", x, y, 0, h)
end

function StackView:draw_frame(frame, x, y, h, selected)
  local dim = frame.external and not selected
  local font = style.code_font
  local name_color = dim and style.dim or (style.syntax["function"] or style.text)
  x = common.draw_text(font, name_color, frame.name, "left", x, y, 0, h)
  local args = {}
  for _, a in ipairs(frame.args or {}) do
    table.insert(args, a.value and (a.name .. "=" .. a.value) or a.name)
  end
  local text = "(" .. table.concat(args, ", ") .. ")"
  if #text > 200 then text = text:sub(1, 197) .. "...)" end
  x = common.draw_text(font, dim and style.dim or style.text, text, "left", x, y, 0, h)
  local where
  if frame.file then
    where = display_path(frame.file) .. (frame.line and (":" .. frame.line) or "")
  else
    where = frame.from and common.home_encode(frame.from) or frame.addr or ""
  end
  return common.draw_text(style.font, selected and style.text or style.dim, "  " .. where, "left", x, y, 0, h)
end

function StackView:draw()
  self:draw_background(style.background)
  self:update_rows()
  local h = self:get_line_height()
  local ox, oy = self:get_content_offset()
  local _, _, w = self:get_content_bounds()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  self:draw_header(ox + style.padding.x, oy, h)
  local first = math.max(1, math.floor(self.scroll.y / h))
  for i = first, math.min(#self.rows, first + math.ceil(self.size.y / h) + 1) do
    local row, y = self.rows[i], oy + i * h
    local selected = i == self.selected_row
    if selected then
      renderer.draw_rect(ox, y, w, h, style.selection)
    elseif i == self.hovered_row then
      renderer.draw_rect(ox, y, w, h, style.line_highlight)
    end
    local x = ox + style.padding.x * 2
    if row.fold then
      -- named by the outermost: what the project's code called
      local n = row.fold[2] - row.fold[1] + 1
      local f = self.frames[row.fold[2]]
      local text = string.format("%d frames outside the project, from %s", n, f.name)
      if f.from then text = text .. " in " .. common.basename(f.from) end
      x = common.draw_text(style.font, style.dim, text, "left", x, y, 0, h)
    else
      x = self:draw_frame(self.frames[row.frame], x, y, h, selected)
    end
    self.max_h_scroll = math.max(self.max_h_scroll, x + style.padding.x - self.position.x + self.scroll.x)
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

ResultsList.add_to(StackView, "debug-stack")

return StackView
