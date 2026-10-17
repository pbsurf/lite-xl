local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local command = require "core.command"
local Doc = require "core.doc"
local DocView = require "core.docview"
local View = require "core.view"


---@class core.commandview.input : core.doc
---@field super core.doc
local SingleLineDoc = Doc:extend()

function SingleLineDoc:__tostring() return "SingleLineDoc" end

function SingleLineDoc:insert(line, col, text)
  SingleLineDoc.super.insert(self, line, col, text:gsub("\n", ""))
end

---@class core.commandview : core.docview
---@field super core.docview
local CommandView = DocView:extend()

function CommandView:__tostring() return "CommandView" end

CommandView.context = "application"

local max_suggestions = 10

local noop = function() end

---@class core.commandview.state
---@field submit function
---@field suggest function
---@field cancel function
---@field validate function
---@field text string
---@field select_text boolean
---@field show_suggestions boolean
---@field typeahead boolean
---@field wrap boolean
---@field placeholder string? dim text shown while the input is empty
---@field modes core.commandview.mode[]? prefixes that switch to other commands
local default_state = {
  submit = noop,
  suggest = noop,
  cancel = noop,
  validate = function() return true end,
  text = "",
  select_text = false,
  show_suggestions = true,
  typeahead = true,
  wrap = true,
}

---A mode of a command view: when the text starts with `prefix`, `command` runs
---with the view it was entered from as the active view, and the state it enters
---replaces the view's own (`prefix` stays in the input but isn't part of the
---text the state sees). Removing the prefix returns to the view's own state.
---A command that enters asynchronously (e.g. after a server's reply) should
---check that `core.command_view.mode_request` is still what it was when it ran.
---@class core.commandview.mode
---@field prefix string
---@field command string
---@field text string what the mode does, for hints


function CommandView:new()
  CommandView.super.new(self, SingleLineDoc())
  self.suggestion_idx = 1
  self.suggestions_offset = 1
  self.suggestions = {}
  self.suggestions_height = 0
  self.last_change_id = 0
  self.last_text = ""
  self.gutter_width = 0
  self.gutter_text_brightness = 0
  self.selection_offset = 0
  self.state = default_state
  self.font = "font"
  self.size.y = 0
  self.label = ""
  ---@type core.commandview.mode?
  self.mode = nil
  ---A fresh table while a mode's command may still enter, nil otherwise.
  self.mode_request = nil
end


---@deprecated
function CommandView:set_hidden_suggestions()
  core.warn("Using deprecated function CommandView:set_hidden_suggestions")
  self.state.show_suggestions = false
end


function CommandView:get_name()
  return View.get_name(self)
end


function CommandView:get_line_screen_position(line, col)
  local x = CommandView.super.get_line_screen_position(self, 1, col)
  local _, y = self:get_content_offset()
  local lh = self:get_line_height()
  return x, y + (self.size.y - lh) / 2
end


function CommandView:get_scrollable_size()
  return 0
end

function CommandView:get_h_scrollable_size()
  return 0
end


function CommandView:scroll_to_make_visible()
  -- no-op function to disable this functionality
end


function CommandView:get_prefix()
  return self.mode and self.mode.prefix or ""
end


---The input's text, without the prefix of the current mode.
function CommandView:get_text()
  return self.doc:get_text(1, 1, 1, math.huge):sub(#self:get_prefix() + 1)
end


function CommandView:set_text(text, select)
  self.last_text = text
  local prefix = self:get_prefix()
  self.doc:remove(1, 1, math.huge, math.huge)
  self.doc:text_input(prefix .. text)
  if select then
    self.doc:set_selection(math.huge, math.huge, 1, #prefix + 1)
  end
end


local pending_state = common.merge(default_state, { pending = true })

function CommandView:enter_mode(mode)
  self.base_state, self.base_label = self.state, self.label
  self.mode, self.mode_request = mode, {}
  self.state = default_state
  -- the command sees the view the command view was entered from
  core.active_view = core.last_active_view
  command.perform(mode.command)
  if self.state == default_state then
    -- not entered (yet): wait, showing what the mode does
    core.active_view = self
    self.state = pending_state
    self.label = mode.text:gsub("^%l", string.upper) .. ": "
  end
end


function CommandView:leave_mode()
  self.state, self.label = self.base_state, self.base_label
  self.mode, self.mode_request, self.base_state = nil, nil, nil
end


function CommandView:move_suggestion_idx(dir)
  local function overflow_suggestion_idx(n, count)
    if count == 0 then return 0 end
    if self.state.wrap then
      return (n - 1) % count + 1
    else
      return common.clamp(n, 1, count)
    end
  end

  local function get_suggestions_offset()
    local max_visible = math.min(max_suggestions, #self.suggestions)
    if dir > 0 then
      if self.suggestions_offset + max_visible < self.suggestion_idx + 1 then
        return self.suggestion_idx - max_visible + 1
      elseif self.suggestions_offset > self.suggestion_idx then
        return self.suggestion_idx
      end
    else
      if self.suggestions_offset > self.suggestion_idx then
        return self.suggestion_idx
      elseif self.suggestions_offset + max_visible < self.suggestion_idx + 1 then
        return self.suggestion_idx - max_visible + 1
      end
    end
    return self.suggestions_offset
  end

  if self.state.show_suggestions then
    local n = self.suggestion_idx + dir
    self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
    self:complete()
    self.last_change_id = self.doc:get_change_id()
  else
    local current_suggestion = #self.suggestions > 0 and self.suggestions[self.suggestion_idx].text
    local text = self:get_text()
    if text == current_suggestion then
      local n = self.suggestion_idx + dir
      if n == 0 and self.save_suggestion then
        self:set_text(self.save_suggestion)
      else
        self.suggestion_idx = overflow_suggestion_idx(n, #self.suggestions)
        self:complete()
      end
    else
      self.save_suggestion = text
      self:complete()
    end
    self.last_change_id = self.doc:get_change_id()
    self.state.suggest(self:get_text())
  end

  self.suggestions_offset = get_suggestions_offset()
end


function CommandView:complete()
  if #self.suggestions > 0 then
    self:set_text(self.suggestions[self.suggestion_idx].text)
  end
end


function CommandView:submit()
  local suggestion = self.suggestions[self.suggestion_idx]
  local text = self:get_text()
  if self.state.validate(text, suggestion) then
    local submit = self.state.submit
    self:exit(true)
    submit(text, suggestion)
  end
end

---@param label string
---@varargs any
---@overload fun(label:string, options: core.commandview.state)
function CommandView:enter(label, ...)
  if self.state ~= default_state and self.state ~= pending_state then
    return
  end
  local options = select(1, ...)

  if type(options) ~= "table" then
    core.warn("Using CommandView:enter in a deprecated way")
    local submit, suggest, cancel, validate = ...
    options = {
      submit = submit,
      suggest = suggest,
      cancel = cancel,
      validate = validate,
    }
  end

  -- Support deprecated CommandView:set_hidden_suggestions
  -- Remove this when set_hidden_suggestions is not supported anymore
  if options.show_suggestions == nil then
    options.show_suggestions = self.state.show_suggestions
  end

  self.state = common.merge(default_state, options)

  -- We need to keep the text entered with CommandView:set_text to
  -- maintain compatibility with deprecated usage, but still allow
  -- overwriting with options.text
  local old_text = self:get_text()
  if old_text ~= "" and not self.mode then
    core.warn("Using deprecated function CommandView:set_text")
  end
  if options.text or options.select_text then
    local text = options.text or old_text
    self:set_text(text, self.state.select_text)
  end
  -- Replace with a simple
  -- self:set_text(self.state.text, self.state.select_text)
  -- once old usage is removed

  core.set_active_view(self)
  self:update_suggestions()
  self.gutter_text_brightness = 100
  self.label = label .. ": "
end


function CommandView:exit(submitted, inexplicit)
  if core.active_view == self then
    core.set_active_view(core.last_active_view)
  end
  local cancel = self.state.cancel
  local base_cancel = self.base_state and self.base_state.cancel or noop
  self.state = default_state
  self.mode, self.mode_request, self.base_state = nil, nil, nil
  self.doc:reset()
  self.suggestions = {}
  if not submitted then
    cancel(not inexplicit)
    base_cancel(not inexplicit)
  end
  self.save_suggestion = nil
  self.last_text = ""
end


function CommandView:get_line_height()
  return math.floor(self:get_font():get_height() * 1.2)
end


function CommandView:get_gutter_width()
  return self.gutter_width
end


function CommandView:get_suggestion_line_height()
  return self:get_font():get_height() + style.padding.y
end


function CommandView:update_suggestions()
  local t = self.state.suggest(self:get_text()) or {}
  local res = {}
  for i, item in ipairs(t) do
    if type(item) == "string" then
      item = { text = item }
    end
    res[i] = item
  end
  self.suggestions = res
  self.suggestion_idx = 1
  self.suggestions_offset = 1
end


function CommandView:update()
  CommandView.super.update(self)

  if core.active_view ~= self and self.state ~= default_state then
    self:exit(false, true)
  end

  -- update suggestions if text has changed
  if self.last_change_id ~= self.doc:get_change_id() then
    local raw = self.doc:get_text(1, 1, 1, math.huge)
    if self.mode and raw:sub(1, #self.mode.prefix) ~= self.mode.prefix then
      self:leave_mode()
    end
    for _, mode in ipairs(not self.mode and self.state.modes or {}) do
      if raw:sub(1, #mode.prefix) == mode.prefix then
        self:enter_mode(mode)
        break
      end
    end
    self:update_suggestions()
    if self.state.typeahead and self.suggestions[self.suggestion_idx] then
      local current_text = self:get_text()
      local suggested_text = self.suggestions[self.suggestion_idx].text or ""
      if #self.last_text < #current_text and
         string.find(suggested_text, current_text, 1, true) == 1 then
        self:set_text(suggested_text)
        self.doc:set_selection(1, #self:get_prefix() + #current_text + 1, 1, math.huge)
      end
      self.last_text = current_text
    end
    self.last_change_id = self.doc:get_change_id()
  end

  -- update gutter text color brightness
  self:move_towards("gutter_text_brightness", 0, 0.1, "commandview")

  -- update gutter width
  local dest = self:get_font():get_width(self.label) + style.padding.x
  if self.size.y <= 0 then
    self.gutter_width = dest
  else
    self:move_towards("gutter_width", dest, nil, "commandview")
  end

  -- update suggestions box height
  local lh = self:get_suggestion_line_height()
  local dest = self.state.show_suggestions and math.min(#self.suggestions, max_suggestions) * lh or 0
  self:move_towards("suggestions_height", dest, nil, "commandview")

  -- update suggestion cursor offset
  local dest = (self.suggestion_idx - self.suggestions_offset + 1) * self:get_suggestion_line_height()
  self:move_towards("selection_offset", dest, nil, "commandview")

  -- update size based on whether this is the active_view
  local dest = 0
  if self == core.active_view then
    dest = style.font:get_height() + style.padding.y * 2
  end
  self:move_towards(self.size, "y", dest, nil, "commandview")
end


function CommandView:draw_line_highlight()
  -- no-op function to disable this functionality
end


function CommandView:draw_line_text(line, x, y)
  local placeholder = self.state.placeholder
  if placeholder and self.doc:get_text(1, 1, 1, math.huge) == "" then
    local yoffset = self:get_line_text_y_offset()
    renderer.draw_text(self:get_font(), placeholder, x, y + yoffset, style.dim)
  end
  return CommandView.super.draw_line_text(self, line, x, y)
end


function CommandView:draw_line_gutter(idx, x, y)
  local yoffset = self:get_line_text_y_offset()
  local pos = self.position
  local color = common.lerp(style.text, style.accent, self.gutter_text_brightness / 100)
  core.push_clip_rect(pos.x, pos.y, self:get_gutter_width(), self.size.y)
  x = x + style.padding.x
  renderer.draw_text(self:get_font(), self.label, x, y + yoffset, color)
  core.pop_clip_rect()
  return self:get_line_height()
end


---Whether the suggestions box, drawn over the views above, overlaps the point.
---@param x number
---@param y number
---@return boolean
function CommandView:suggestions_overlap_point(x, y)
  if not self.state.show_suggestions or #self.suggestions == 0 then return false end
  local top = self.position.y - math.ceil(self.suggestions_height) - 2 * style.divider_size
  return x >= self.position.x and x < self.position.x + self.size.x
    and y >= top and y < self.position.y
end


---The index of the suggestion drawn at the point, if any.
---@param x number
---@param y number
---@return integer?
function CommandView:get_suggestion_at(x, y)
  if not self:suggestions_overlap_point(x, y) then return end
  local row = math.floor((self.position.y - style.divider_size - y)
    / self:get_suggestion_line_height()) + 1
  local visible = math.min(max_suggestions, #self.suggestions - self.suggestions_offset + 1)
  if row >= 1 and row <= visible then
    return self.suggestions_offset + row - 1
  end
end


---Handles a click on the suggestions box: a left click on a suggestion
---completes it and submits.
---@param button core.view.mousebutton
---@param x number
---@param y number
function CommandView:on_suggestions_mouse_pressed(button, x, y)
  local idx = self:get_suggestion_at(x, y)
  if idx and button == "left" then
    self.suggestion_idx = idx
    self:complete()
    self:submit()
  end
end


---Scrolls the suggestions by wheel amount dy (up shows later ones, which are
---drawn above), keeping the selected one in view.
---@param dy number
function CommandView:scroll_suggestions(dy)
  local max_offset = math.max(1, #self.suggestions - max_suggestions + 1)
  -- fractions of a row (smooth wheels) add up across events
  self.suggestions_scroll = (self.suggestions_scroll or 0)
    + dy * config.mouse_wheel_scroll / self:get_suggestion_line_height()
  local rows = self.suggestions_scroll < 0 and math.ceil(self.suggestions_scroll)
    or math.floor(self.suggestions_scroll)
  self.suggestions_scroll = self.suggestions_scroll - rows
  self.suggestions_offset = common.clamp(self.suggestions_offset + rows, 1, max_offset)
  local visible = math.min(max_suggestions, #self.suggestions)
  self.suggestion_idx = common.clamp(self.suggestion_idx,
    self.suggestions_offset, self.suggestions_offset + visible - 1)
end


local function draw_suggestions_box(self)
  local lh = self:get_suggestion_line_height()
  local dh = style.divider_size
  local x, _ = self:get_line_screen_position()
  local h = math.ceil(self.suggestions_height)
  local rx, ry, rw, rh = self.position.x, self.position.y - h - dh, self.size.x, h

  if #self.suggestions > 0 then
    -- docked on the command view: the shadow shows only above, on what's behind,
    -- without the usual downward offset (which would hide most of it)
    core.push_clip_rect(rx, 0, rw, ry + rh)
    common.draw_popup_shadow(rx, ry - 3 * SCALE, rw, rh)
    core.pop_clip_rect()
  end

  core.push_clip_rect(rx, ry, rw, rh)
  -- draw suggestions background
  if #self.suggestions > 0 then
    renderer.draw_rect(rx, ry, rw, rh, style.popup_background)
    renderer.draw_rect(rx, ry - dh, rw, dh, style.popup_border)
    local y = self.position.y - self.selection_offset - dh
    renderer.draw_rect(rx, y, rw, lh, style.line_highlight)
  end

  -- draw suggestion text
  local first = math.max(self.suggestions_offset, 1)
  local last = math.min(self.suggestions_offset + max_suggestions, #self.suggestions)
  for i=first, last do
    local item = self.suggestions[i]
    local color = (i == self.suggestion_idx) and style.accent or style.text
    local y = self.position.y - (i - first + 1) * lh - dh
    common.draw_text(item.font or self:get_font(), color, item.text, nil, x, y, 0, lh)

    if item.info then
      local w = self.size.x - x - style.padding.x
      common.draw_text(self:get_font(), style.dim, item.info, "right", x, y, w, lh)
    end
  end
  core.pop_clip_rect()
end


function CommandView:draw()
  CommandView.super.draw(self)
  if self.state.show_suggestions then
    core.root_view:defer_draw(draw_suggestions_box, self)
  end
end

return CommandView
