local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local ResultsList = require "core.resultslist"
local shapes = require "libraries.shapes"

---The program's threads, each with where it is in the project (its innermost
---frame in it, else its innermost): the one that stopped is marked with why.
---Selecting one (a click, arrow keys) makes the call stack, variables and
---stepping its, and shows where it is.
---@class debug.threadsview : core.view
local ThreadsView = View:extend()

function ThreadsView:new()
  ThreadsView.super.new(self)
  self.scrollable = true
  self.hovered_row = nil
  self.max_h_scroll = 0
end

local function debug() return require "plugins.debug" end

function ThreadsView:get_name()
  local session = debug().session
  local threads = session and session.threads
  return threads and #threads > 1 and ("Threads: " .. #threads) or "Threads"
end

function ThreadsView:get_workspace_state() return {} end
function ThreadsView:from_workspace_state() return debug().get_view("threads") end

function ThreadsView:get_line_height()
  return style.padding.y + math.max(style.font:get_height(), style.code_font:get_height())
end

function ThreadsView:get_threads()
  local session = debug().session
  return session and session.threads or {}
end

function ThreadsView:get_scrollable_size()
  return (#self:get_threads() + 1) * self:get_line_height()
end

function ThreadsView:get_h_scrollable_size() return self.max_h_scroll end

-- ResultsList's interface
function ThreadsView:get_result_count() return #self:get_threads() end
function ThreadsView:get_page_size() return math.max(1, math.floor(self.size.y / self:get_line_height()) - 2) end

function ThreadsView:get_selected_index()
  local session = debug().session
  for i, t in ipairs(self:get_threads()) do
    if t.id == session:thread_id() then return i end
  end
end

local function location(thread)
  return thread.project_frame or thread.frame
end

function ThreadsView:get_result_location(idx)
  local thread = self:get_threads()[idx]
  local frame = thread and location(thread)
  if frame and frame.file and frame.line and system.get_file_info(frame.file) then
    return frame.file, frame.line, 1
  end
end

function ThreadsView:set_selected_index(idx)
  local h = self:get_line_height()
  self.scroll.to.y = math.min(self.scroll.to.y, h * (idx - 1))
  self.scroll.to.y = math.max(self.scroll.to.y, h * (idx + 1) - self.size.y)
end

---Selects a thread in the session, showing where it is (the session's
---"thread" event shows its selected frame's line).
function ThreadsView:select(idx)
  local threads = self:get_threads()
  if #threads == 0 then return end
  idx = common.clamp(idx, 1, #threads)
  self:set_selected_index(idx)
  debug().session:select_thread(threads[idx].id)
end

function ThreadsView:open_selected()
  local idx = self:get_selected_index()
  local file, line = self:get_result_location(idx or 0)
  if not file then return end
  local dv = core.root_view:peek_file(file, line, 1)
  if dv then core.set_active_view(dv) end
  return dv
end

function ThreadsView:row_at(x, y)
  if not self:overlaps_point(x, y) then return nil end
  local _, oy = self:get_content_offset()
  local idx = math.floor((y - oy) / self:get_line_height())
  return idx >= 1 and idx <= #self:get_threads() and idx or nil
end

function ThreadsView:on_mouse_moved(x, y, ...)
  if ThreadsView.super.on_mouse_moved(self, x, y, ...) then
    self.hovered_row = nil
    return true
  end
  self.hovered_row = self:row_at(x, y)
end

function ThreadsView:on_mouse_left()
  ThreadsView.super.on_mouse_left(self)
  self.hovered_row = nil
end

function ThreadsView:on_mouse_pressed(button, x, y, clicks)
  if ThreadsView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local idx = self:row_at(x, y)
  if button == "left" and idx then
    self:select(idx)
    if clicks > 1 then self:open_selected() end
    return true
  end
end

local function display_path(file)
  if common.path_belongs_to(file, core.project_dir) then
    return common.relative_path(core.project_dir, file)
  end
  return common.home_encode(file)
end

function ThreadsView:draw_header(x, y, h)
  local session = debug().session
  local text = "Not stopped"
  if session and session.state == "stopped" then
    text = session.threads and (#session.threads .. (#session.threads == 1 and " thread" or " threads")) or "…"
  end
  return common.draw_text(style.font, style.dim, text, "left", x, y, 0, h)
end

function ThreadsView:draw_thread(thread, x, y, h, selected)
  local session = debug().session
  local stopped = session.stop and session.stop.thread_id == thread.id
  local fh = style.font:get_height()
  -- the thread that stopped: an arrow
  if stopped then
    local size = math.floor(fh * 0.55)
    shapes.arrow(x, y + (h - size) / 2, size * 1.2, size, style.debug.current)
  end
  x = x + math.floor(fh * 0.9)
  x = common.draw_text(style.code_font, style.text, "#" .. thread.id, "left", x, y, 0, h)
  local name = thread.name or thread.target_id
  if name then x = common.draw_text(style.font, style.dim, "  " .. name, "left", x, y, 0, h) end
  local frame = location(thread)
  if frame then
    x = common.draw_text(style.code_font, style.syntax["function"] or style.text, "  " .. frame.name, "left", x, y, 0, h)
    local where = frame.file and (display_path(frame.file) .. (frame.line and (":" .. frame.line) or ""))
      or (frame.from and common.home_encode(frame.from)) or ""
    x = common.draw_text(style.font, selected and style.text or style.dim, "  " .. where, "left", x, y, 0, h)
  end
  if stopped and session.stop.description then
    x = common.draw_text(style.font, session.stop.signal and style.error or style.dim,
      "  " .. session.stop.description, "left", x, y, 0, h)
  end
  return x
end

function ThreadsView:draw()
  self:draw_background(style.background)
  local h = self:get_line_height()
  local ox, oy = self:get_content_offset()
  local _, _, w = self:get_content_bounds()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  self:draw_header(ox + style.padding.x, oy, h)
  local threads = self:get_threads()
  local selected = self:get_selected_index()
  for i, thread in ipairs(threads) do
    local y = oy + i * h
    if y + h >= self.position.y and y < self.position.y + self.size.y then
      if i == selected then
        renderer.draw_rect(ox, y, w, h, style.selection)
      elseif i == self.hovered_row then
        renderer.draw_rect(ox, y, w, h, style.line_highlight)
      end
      local x = self:draw_thread(thread, ox + style.padding.x, y, h, i == selected)
      self.max_h_scroll = math.max(self.max_h_scroll, x + style.padding.x - self.position.x + self.scroll.x)
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end

ResultsList.add_to(ThreadsView, "debug-threads")

return ThreadsView
