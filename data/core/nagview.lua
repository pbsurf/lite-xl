local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local View = require "core.view"
local style = require "core.style"

local BORDER_WIDTH = common.round(1 * SCALE)
local UNDERLINE_WIDTH = common.round(2 * SCALE)
local UNDERLINE_MARGIN = common.round(1 * SCALE)

local noop = function() end

local function get_button_width(opt)
  return style.font:get_width(opt.text) + 2 * BORDER_WIDTH + style.padding.x
end

---Splits a line into lines no wider than width: at spaces (dropped at the
---breaks), after "/" (paths), and between characters for longer words.
local function wrap_line(font, line, width)
  local lines, cur = {}, ""
  local function fits(s) return font:get_width((s:gsub(" +$", ""))) <= width end
  for piece in line:gmatch("[^ /]*[ /]*") do
    if piece ~= "" then
      if not fits(cur .. piece) and cur ~= "" then
        table.insert(lines, (cur:gsub(" +$", "")))
        cur = ""
      end
      if fits(cur .. piece) then
        cur = cur .. piece
      else
        for ch in piece:gmatch(utf8.charpattern) do
          if cur ~= "" and not fits(cur .. ch) then
            table.insert(lines, cur)
            cur = ""
          end
          cur = cur .. ch
        end
      end
    end
  end
  table.insert(lines, (cur:gsub(" +$", "")))
  return lines
end

---@class core.nagview : core.view
---@field super core.view
local NagView = View:extend()

function NagView:__tostring() return "NagView" end

function NagView:new()
  NagView.super.new(self)
  self.size.y = 0
  self.show_height = 0
  self.force_focus = false
  self.queue = {}
  self.scrollable = true
  self.target_height = 0
  self.on_mouse_pressed_root = nil
end

function NagView:get_title()
  return self.title
end

-- The two methods below are duplicated from DocView
function NagView:get_line_height()
  return math.floor(style.font:get_height() * config.line_height)
end

function NagView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = style.font:get_height()
  return (lh - th) / 2
end

-- Buttons height without padding
function NagView:get_buttons_height()
  local lh = style.font:get_height()
  local bt_padding = lh / 2
  return lh + 2 * BORDER_WIDTH + 2 * bt_padding
end

---Lays the message out for the view's width: beside the buttons if its lines
---fit there, else above them, wrapped to the whole width; buttons that don't
---fit in a row wrap to more. Sets self.lines, self.stacked, self.button_rows
---and self.target_height (the height without top and bottom padding).
function NagView:update_layout()
  if not self.message then return end
  local width = self.size.x > 0 and self.size.x or system.get_window_size()
  local key = table.concat({ width, style.font:get_size(), #self.queue, self.message }, "\0")
  if key == self.layout_key then return end
  self.layout_key = key

  local x = style.padding.x
  if #self.queue > 0 then
    x = x + style.font:get_width(string.format("[%d]", #self.queue)) + style.padding.x
  end
  -- rows of buttons: { first, last } option indices
  self.button_rows = {}
  local row_width
  for i, opt in ipairs(self.options) do
    local w = get_button_width(opt) + style.padding.x
    if row_width and row_width + w <= width - style.padding.x then
      self.button_rows[#self.button_rows][2] = i
      row_width = row_width + w
    else
      table.insert(self.button_rows, { i, i })
      row_width = w
    end
  end
  local full_width = width - x - style.padding.x
  local beside_width = #self.button_rows > 1 and 0 or full_width - (row_width or 0)

  local paragraphs = {}
  for line in self.message:gmatch("(.-)\n") do table.insert(paragraphs, line) end
  self.stacked = false
  for _, line in ipairs(paragraphs) do
    if style.font:get_width(line) > beside_width then self.stacked = true end
  end
  self.lines = {}
  for _, line in ipairs(paragraphs) do
    for _, l in ipairs(wrap_line(style.font, line, self.stacked and full_width or beside_width)) do
      table.insert(self.lines, l)
    end
  end

  local message_height = self:get_message_height()
  local buttons_height = self:get_button_rows_height()
  self.target_height = self.stacked and message_height + style.padding.y + buttons_height
    or math.max(message_height, buttons_height)
end

function NagView:get_target_height()
  return self.target_height + 2 * style.padding.y
end

function NagView:get_scrollable_size()
  local w, h = system.get_window_size()
  if self.visible and self:get_target_height() > h then
    self.size.y = h
    return self:get_target_height()
  else
    self.size.y = 0
  end
  return 0
end

function NagView:dim_window_content()
  local ox, oy = self:get_content_offset()
  oy = oy + self.show_height
  local w, h = core.root_view.size.x, core.root_view.size.y - oy
  core.root_view:defer_draw(function()
    renderer.draw_rect(ox, oy, w, h, style.nagbar_dim)
  end)
end

function NagView:change_hovered(i)
  if i ~= self.hovered_item then
    self.hovered_item = i
    self.underline_progress = 0
    core.redraw = true
  end
end

---Height of the buttons' rows together, without padding above and below.
function NagView:get_button_rows_height()
  local rows = #(self.button_rows or { 1 })
  return rows * self:get_buttons_height() + (rows - 1) * style.padding.y
end

function NagView:each_option()
  return coroutine.wrap(function()
    if not self.options then return end
    local bh = self:get_buttons_height()
    local ox, oy = self:get_content_offset()
    local rows = self.button_rows or { { 1, #self.options } }
    -- the rows end at the bottom, each aligned right
    local y = oy + self.show_height - style.padding.y - self:get_button_rows_height()
    for _, row in ipairs(rows) do
      local x = ox + self.size.x
      for i = row[2], row[1], -1 do
        local bw = get_button_width(self.options[i])
        x = x - bw - style.padding.x
        coroutine.yield(i, self.options[i], x, y, bw, bh)
      end
      y = y + bh + style.padding.y
    end
  end)
end

function NagView:on_mouse_moved(mx, my, ...)
  if not self.visible then return end
  core.set_active_view(self)
  NagView.super.on_mouse_moved(self, mx, my, ...)
  for i, _, x,y,w,h in self:each_option() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self:change_hovered(i)
      break
    end
  end
end

local function register_mouse_pressed(self)
  if self.on_mouse_pressed_root then return end
  -- RootView is loaded locally to avoid NagView and RootView being
  -- mutually recursive
  local RootView = require "core.rootview"
  self.on_mouse_pressed_root = RootView.on_mouse_pressed
  local this = self
  function RootView:on_mouse_pressed(button, x, y, clicks)
    if
      not this:on_mouse_pressed(button, x, y, clicks)
    then
      return this.on_mouse_pressed_root(self, button, x, y, clicks)
    else
      return true
    end
  end
  self.new_on_mouse_pressed_root = RootView.on_mouse_pressed
end

local function unregister_mouse_pressed(self)
  local RootView = require "core.rootview"
  if
    self.on_mouse_pressed_root
    and
    -- just in case prevent overwriting what something else may
    -- have overwrote after us, but after testing with various
    -- plugins this doesn't seems to happen, but just in case
    self.new_on_mouse_pressed_root == RootView.on_mouse_pressed
  then
    RootView.on_mouse_pressed = self.on_mouse_pressed_root
    self.on_mouse_pressed_root = nil
    self.new_on_mouse_pressed_root = nil
  end
end

function NagView:on_mouse_pressed(button, mx, my, clicks)
  if not self.visible then return false end
  if NagView.super.on_mouse_pressed(self, button, mx, my, clicks) then return true end
  for i, _, x,y,w,h in self:each_option() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self:change_hovered(i)
      command.perform "dialog:select"
    end
  end
  return true
end

function NagView:on_text_input(text)
  if not self.visible then return end
  -- an option's first letter selects it
  for i, opt in ipairs(self.options) do
    if opt.text:sub(1, 1):lower() == text:lower() then
      self:change_hovered(i)
      command.perform "dialog:select"
      return
    end
  end
  if text:lower() == "y" then
    command.perform "dialog:select-yes"
  elseif text:lower() == "n" then
    command.perform "dialog:select-no"
  end
end

function NagView:update()
  if not self.visible and self.show_height <= 0 then return end
  NagView.super.update(self)
  self:update_layout()

  if self.visible and core.active_view == self and self.title then
    self:move_towards(self, "show_height", self:get_target_height(), nil, "nagbar")
    self:move_towards(self, "underline_progress", 1, nil, "nagbar")
  else
    self:move_towards(self, "show_height", 0, nil, "nagbar")
    if self.show_height <= 0 then
      self.title = nil
      self.message = nil
      self.options = nil
      self.on_selected = nil
    end
  end
end

local function draw_nagview_message(self)
  self:dim_window_content()

  -- draw message's background
  local ox, oy = self:get_content_offset()
  renderer.draw_rect(ox, oy, self.size.x, self.show_height, style.nagbar)

  ox = ox + style.padding.x

  core.push_clip_rect(ox, oy, self.size.x, self.show_height)

  -- if there are other items, show it
  if #self.queue > 0 then
    local str = string.format("[%d]", #self.queue)
    ox = common.draw_text(style.font, style.nagbar_text, str, "left", ox, oy, self.size.x, self.show_height)
    ox = ox + style.padding.x
  end

  -- draw message: centered beside the buttons, or at the top above them
  local lh = style.font:get_height() * config.line_height
  local message_height = self:get_message_height()
  local area_height = self.stacked and message_height or self.target_height
  oy = oy + style.padding.y + (area_height - message_height) / 2
  for _, msg_line in ipairs(self.lines) do
    local ty = oy + self:get_line_text_y_offset()
    renderer.draw_text(style.font, msg_line, ox, ty, style.nagbar_text)
    oy = oy + lh
  end

  -- draw buttons
  for i, opt, bx,by,bw,bh in self:each_option() do
    local fw,fh = bw - 2 * BORDER_WIDTH, bh - 2 * BORDER_WIDTH
    local fx,fy = bx + BORDER_WIDTH, by + BORDER_WIDTH

    -- draw the button
    renderer.draw_rect(bx,by,bw,bh, style.nagbar_text)
    renderer.draw_rect(fx,fy,fw,fh, style.nagbar)

    if i == self.hovered_item then -- draw underline
      local uw = fw - 2 * UNDERLINE_MARGIN
      local halfuw = uw / 2
      local lx = fx + UNDERLINE_MARGIN + halfuw - (halfuw * self.underline_progress)
      local ly = fy + fh - UNDERLINE_MARGIN - UNDERLINE_WIDTH
      uw = uw * self.underline_progress
      renderer.draw_rect(lx,ly,uw,UNDERLINE_WIDTH, style.nagbar_text)
    end

    common.draw_text(style.font, style.nagbar_text, opt.text, "center", fx,fy,fw,fh)
  end

  self:draw_scrollbar()

  core.pop_clip_rect()
end

function NagView:draw()
  if (not self.visible and self.show_height <= 0) or not self.title then
    return
  end
  core.root_view:defer_draw(draw_nagview_message, self)
end

function NagView:on_scale_change(new_scale, old_scale)
  BORDER_WIDTH = common.round(1 * new_scale)
  UNDERLINE_WIDTH = common.round(2 * new_scale)
  UNDERLINE_MARGIN = common.round(1 * new_scale)
  self.layout_key = nil
  self:update_layout()
end

function NagView:get_message_height()
  return #(self.lines or {}) * style.font:get_height() * config.line_height
end

function NagView:next()
  local opts = table.remove(self.queue, 1) or {}
  if opts.title and opts.message and opts.options then
    self.visible = true
    self.title = opts.title
    self.message = opts.message and opts.message .. "\n"
    self.options = opts.options
    self.on_selected = opts.on_selected

    self.layout_key = nil
    self:update_layout()
    self:change_hovered(common.find_index(self.options, "default_yes"))

    self.force_focus = true
    core.set_active_view(self)
    -- We add a hook to manage all the mouse_pressed events.
    register_mouse_pressed(self)
  else
    self.force_focus = false
    -- an option may have closed the last active view (Node:remove_view clears it)
    core.set_active_view(core.next_active_view or core.last_active_view
      or core.root_view:get_primary_node().active_view)
    self.visible = false
    unregister_mouse_pressed(self)
  end
end

function NagView:show(title, message, options, on_select)
  local opts = {}
  opts.title = assert(title, "No title")
  opts.message = assert(message, "No message")
  opts.options = assert(options, "No options")
  opts.on_selected = on_select or noop
  table.insert(self.queue, opts)
  self:next()
end

return NagView
