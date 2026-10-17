-- mod-version:3
-- A header bar: one strip at the top of the window, in place of core's title
-- view, with a menu button (the menubar plugin's menus as a dropdown), a file
-- browser toggle, back/forward (navigate plugin; dimmed when there's nowhere to
-- go) and, with config.borderless, the title and the window controls. Then it
-- is the window's title bar: dragging the strip moves the window,
-- double-clicking it maximizes or restores, and the window's edges resize.
-- Without borderless it sits under the OS title bar.
--
-- In a narrow window the title goes first, then back/forward, the file browser
-- toggle and the menu button.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local tooltip = require "core.tooltip"
local TitleView = require "core.titleview"

---A button: `icon` (a character of style.icon_font) or `draw(x, y, w, h,
---color)`; `action()`, or `command` (a name), performed on a click; optional
---`tooltip` (shown with the command's key binding), `enabled()` (else
---whether the command applies), `active()` (drawn pressed), `available()` (else
---shown when it has an action or its command exists).
---@class plugins.headerbar.button
---@field tooltip? string
---@field icon? string
---@field draw? fun(x: number, y: number, w: number, h: number, color: renderer.color)
---@field action? fun(self: plugins.headerbar.button, view: plugins.headerbar)
---@field command? string
---@field enabled? fun(): boolean
---@field active? fun(): boolean
---@field available? fun(): boolean

local function menubar() return package.loaded["plugins.menubar"] end
local function navigate() return package.loaded["plugins.navigate"] end
local function treeview() return package.loaded["plugins.treeview"] end

---A panel at the left of a window: the file browser.
local function draw_file_browser_icon(x, y, w, h, color)
  local s = math.floor(style.icon_font:get_height() * 0.8)
  local t = math.max(1, math.floor(SCALE))
  local bx, by = math.floor(x + (w - s) / 2), math.floor(y + (h - s) / 2)
  local bw, bh = s, math.floor(s * 0.85)
  by = by + math.floor((s - bh) / 2)
  local panel = math.floor(bw * 0.38)
  local tv = treeview()
  if tv and tv.visible then
    renderer.draw_rect(bx, by, panel, bh, color)
  end
  local o = t / 2
  renderer.draw_path({
    "M", bx + o, by + o, "L", bx + bw - o, by + o, "L", bx + bw - o, by + bh - o,
    "L", bx + o, by + bh - o, "Z",
    "M", bx + panel - o, by, "L", bx + panel - o, by + bh,
  }, color, t)
end

---Button groups at the left, most important first (the last goes first when
---the window is narrow).
---@type plugins.headerbar.button[][]
local groups = {
  {
    { icon = "M", tooltip = "Menu", available = menubar, active = function()
        return menubar().state.popup ~= nil
      end,
      action = function(self, view)
        if menubar().state.popup then
          menubar().hide()
        else
          menubar().popup(self.x, view.position.y + view.size.y)
        end
      end },
  },
  {
    { draw = draw_file_browser_icon, command = "treeview:toggle", tooltip = "File Browser" },
  },
  {
    { icon = "<", command = "navigate:previous", tooltip = "Back",
      enabled = function() return navigate().can_move(-1) end },
    { icon = ">", command = "navigate:next", tooltip = "Forward",
      enabled = function() return navigate().can_move(1) end },
  },
}

---Draws a window control's symbol, thin lines in a square centered in the
---rect: `f(x, y, s)` gives the path in the square at x, y of size s.
local function control_symbol(f)
  return function(x, y, w, h, color)
    local t = math.max(1, math.floor(SCALE))
    local s = math.floor(style.icon_font:get_height() * 0.55)
    -- on pixel centers, for crisp lines
    local o = t % 2 / 2
    renderer.draw_path(f(math.floor(x + (w - s) / 2) + o, math.floor(y + (h - s) / 2) + o, s), color, t)
  end
end

local window_controls = {
  { draw = control_symbol(function(x, y, s)
      return { "M", x, y + s / 2, "L", x + s, y + s / 2 }
    end),
    action = function() system.set_window_mode("minimized") end },
  { draw = control_symbol(function(x, y, s)
      if core.window_mode == "maximized" then
        -- restore: a square, and the edges of one behind it
        local d = math.floor(s / 4)
        return {
          "M", x, y + d, "L", x + s - d, y + d, "L", x + s - d, y + s, "L", x, y + s, "Z",
          "M", x + d, y + d, "L", x + d, y, "L", x + s, y, "L", x + s, y + s - d, "L", x + s - d, y + s - d,
        }
      end
      return { "M", x, y, "L", x + s, y, "L", x + s, y + s, "L", x, y + s, "Z" }
    end),
    action = function() TitleView.toggle_maximized() end },
  { draw = control_symbol(function(x, y, s)
      return { "M", x, y, "L", x + s, y + s, "M", x + s, y, "L", x, y + s }
    end),
    close = true, action = function() core.quit() end },
}

local close_hover = { common.color "#e81123" }
local close_hover_text = { common.color "#ffffff" }


---@class plugins.headerbar : core.titleview
local HeaderBar = TitleView:extend()

function HeaderBar:__tostring() return "HeaderBar" end

function HeaderBar:new()
  HeaderBar.super.new(self)
  self.borderless = false
  -- laid out each update: the buttons shown, each with x, y, w, h
  self.buttons = {}
  self.title_x = nil
  self.hovered = nil
end

local function height()
  return style.font:get_height() + style.padding.y * 2
end

local function available(b)
  if b.available then return b.available() end
  return b.action ~= nil or command.map[b.command] ~= nil
end

local function enabled(b)
  if b.enabled and not b.enabled() then return false end
  return b.action ~= nil or command.is_valid(b.command)
end

---The title: the file, and the project (dim).
function HeaderBar:get_title()
  local project = common.basename(core.project_dir)
  local file = core.window_title
  if file == nil or file == "" then return project, "" end
  return file, "  —  " .. project
end

function HeaderBar:layout()
  local x0, y0, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  local bw = h
  local gap = style.padding.x / 2
  self.buttons = {}

  local right = x0 + w
  if self.borderless then
    local cw = math.floor(h * 1.4)
    right = right - cw * #window_controls
    for i, b in ipairs(window_controls) do
      b.x, b.y, b.w, b.h = right + (i - 1) * cw, y0, cw, h
      table.insert(self.buttons, b)
    end
  end

  -- groups, in order, while they fit (with room for the controls)
  local x = x0 + gap
  for _, group in ipairs(groups) do
    local list = {}
    for _, b in ipairs(group) do
      if available(b) then table.insert(list, b) end
    end
    local gw = #list * bw
    if x + gw > right then break end
    for i, b in ipairs(list) do
      b.x, b.y, b.w, b.h = x + (i - 1) * bw, y0, bw, h
      table.insert(self.buttons, b)
    end
    if #list > 0 then x = x + gw + gap end
  end

  -- the title: centered in the window if it can be, else in the space left
  self.title_x = nil
  if self.borderless then
    local file, project = self:get_title()
    local font = style.font
    local tw = font:get_width(file) + font:get_width(project)
    local left, avail = x + gap, right - x - gap * 2
    if tw > avail then
      -- without the project, then without leading directories
      project, tw = "", font:get_width(file)
      local path = file
      while tw > avail and path:find("[/\\]") do
        path = path:gsub("^[^/\\]*[/\\]", "")
        file = "…" .. PATHSEP .. path
        tw = font:get_width(file)
      end
    end
    if tw <= avail then
      self.title_x = common.clamp(x0 + (w - tw) / 2, left, right - gap - tw)
      self.title = { file, project }
    end
  end
end

function HeaderBar:update()
  self.size.y = self.visible and height() or 0
  -- (TitleView's update would replace the controls' layout)
  HeaderBar.super.super.update(self)
  self:layout()
  if self.borderless then self:update_hit_test() end
end

---Tells the window which parts of the strip take clicks; the rest drags the
---window. With the menubar's bar shown above the header bar, none of it drags.
function HeaderBar:update_hit_test()
  local rects = {}
  local mb = menubar()
  if mb and mb.state.active and not mb.state.popup then
    table.insert(rects, { 0, 0, core.root_view.size.x, self.position.y })
  end
  for _, b in ipairs(self.buttons) do
    table.insert(rects, { b.x, b.y, b.w, b.h })
  end
  local title_height = self.position.y + self.size.y
  local parts = { title_height, TitleView.resize_border() }
  for _, r in ipairs(rects) do table.insert(parts, table.concat(r, ",")) end
  local key = table.concat(parts, ";")
  if key ~= self.hit_test_key then
    self.hit_test_key = key
    system.set_window_hit_test(title_height, 0, TitleView.resize_border(), rects)
  end
end

function HeaderBar:configure_hit_test(borderless)
  self.borderless = borderless
  self.hit_test_key = nil
  if not borderless then system.set_window_hit_test() end
  core.redraw = true
end

function HeaderBar:on_scale_change()
  self.hit_test_key = nil
end


function HeaderBar:button_at(px, py)
  for _, b in ipairs(self.buttons) do
    if px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h then return b end
  end
end

function HeaderBar:on_mouse_moved(px, py, ...)
  if self.size.y == 0 then return end
  self.hovered = self:button_at(px, py)
  tooltip.hover(self, self.hovered and self.hovered.tooltip and self.hovered)
  -- (TitleView's tracks the controls' layout)
  HeaderBar.super.super.on_mouse_moved(self, px, py, ...)
end

function HeaderBar:on_mouse_left()
  HeaderBar.super.on_mouse_left(self)
  self.hovered = nil
  tooltip.hover(self, nil)
end

function HeaderBar:on_mouse_pressed(button, x, y, clicks)
  core.set_active_view(core.last_active_view)
  local b = self:button_at(x, y)
  if b then
    if button == "left" and enabled(b) then
      if b.action then b.action(b, self) else command.perform(b.command) end
    end
  elseif self.borderless and button == "left" and clicks % 2 == 0 then
    TitleView.toggle_maximized()
  end
  return true
end


function HeaderBar:draw_button(b)
  local on = enabled(b)
  local color = on and style.text or style.dim
  local hover = { style.text[1], style.text[2], style.text[3], 0x20 }
  if b.close and b == self.hovered then
    renderer.draw_rect(b.x, b.y, b.w, b.h, close_hover)
    color = close_hover_text
  elseif (b == self.hovered and on) or (b.active and b.active()) then
    renderer.draw_rect(b.x, b.y, b.w, b.h, hover)
  end
  if b.draw then
    b.draw(b.x, b.y, b.w, b.h, color)
  else
    common.draw_text(style.icon_font, color, b.icon, "center", b.x, b.y, b.w, b.h)
  end
end

---Draws a button's tooltip below it, over the views.
function HeaderBar:draw_tooltip(b)
  local text = b.tooltip
  local binding = b.command and keymap.get_binding(b.command)
  core.root_view:defer_draw(function()
    local font = style.font
    local sep = "   "
    local w = font:get_width(text) + (binding and font:get_width(sep .. binding) or 0)
      + style.padding.x * 2
    local h = font:get_height() + style.padding.y
    local x = common.clamp(b.x + (b.w - w) / 2, 0, core.root_view.size.x - w - 1)
    local y = b.y + b.h + 1
    common.draw_popup_box(x, y, w, h)
    local tx = renderer.draw_text(font, text, x + style.padding.x, y + style.padding.y / 2, style.text)
    if binding then renderer.draw_text(font, sep .. binding, tx, y + style.padding.y / 2, style.dim) end
  end)
end

function HeaderBar:draw()
  self:draw_background(style.background2)
  for _, b in ipairs(self.buttons) do self:draw_button(b) end
  if self.hovered and self.hovered.tooltip and tooltip.shown(self, self.hovered) then self:draw_tooltip(self.hovered) end
  if self.title_x then
    local y, h = self.position.y, self.size.y
    local x = common.draw_text(style.font, style.text, self.title[1], "left", self.title_x, y, 0, h)
    common.draw_text(style.font, style.dim, self.title[2], "left", x, y, 0, h)
  end
end


-- replace core's title view, in its node
local header_bar = HeaderBar()
local node = core.root_view.root_node:get_node_for_view(core.title_view)
node.views[1] = header_bar
node.active_view = header_bar
core.title_view = header_bar

-- shown with or without borderless (core shows its title view only with)
local configure_borderless_window = core.configure_borderless_window
function core.configure_borderless_window(...)
  configure_borderless_window(...)
  header_bar.visible = true
end

return HeaderBar
