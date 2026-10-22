local core = require "core"
local common = require "core.common"
local style = require "core.style"
local tooltip = require "core.tooltip"
local Object = require "core.object"

---The status line at the top of a results view (project search's, LSP's
---Symbols Search, ...): a text, then a divider that can show progress. When the
---view is a locked panel, it has buttons on the right to move the view into a
---tab and to close it, which also tell a panel from a tab.
---
---The view sets the fields below, calls draw() and passes on mouse events.
---@class core.panelheader : core.object
---@field view core.view
---@field text string
---@field color renderer.color? Of the text; style.text if nil
---@field divider_color renderer.color? style.dim if nil
---@field progress number? 0 to 1: drawn over the divider while set
---@field on_move_to_tab fun(view: core.view)? Called after the view moved
---@field on_close fun(view: core.view)? Called after the panel closed
local PanelHeader = Object:extend()

local buttons = {
  { icon = "w", action = "move_to_tab", tooltip = "Open in Tab" },
  { icon = "C", action = "close", tooltip = "Close" },
}

---@param view core.view
function PanelHeader:new(view)
  self.view = view
  self.text = ""
  self.rects = {} -- each shown button's {button, x, y, w, h}, as last drawn
  self.hovered = nil
end

---@return number
function PanelHeader:get_height()
  return style.font:get_height() + style.padding.y * 3
end

---Whether the view is in a locked panel rather than a tab.
---@return boolean
function PanelHeader:is_panel()
  local node = core.root_view.root_node:get_node_for_view(self.view)
  return node and node.locked and true or false
end

---@param x number
---@param y number
---@param w number
function PanelHeader:draw(x, y, w)
  local h = self:get_height()
  local pad = style.padding

  -- buttons, from the right
  self.rects = {}
  local right = x + w - pad.x
  if self:is_panel() then
    for i = #buttons, 1, -1 do
      local b = buttons[i]
      local bw = style.icon_font:get_width(b.icon)
      right = right - bw
      local color = self.hovered == b and style.text or style.dim
      common.draw_text(style.icon_font, color, b.icon, nil, right, y + pad.y, 0,
        style.font:get_height())
      table.insert(self.rects, { b, right - pad.x / 2, y, bw + pad.x, h - pad.y })
      right = right - pad.x
    end
  end

  -- text, cut short before the buttons
  local text = common.truncate_text(style.font, self.text, right - x - pad.x * 2)
  renderer.draw_text(style.font, text, x + pad.x, y + pad.y, self.color or style.text)

  -- divider, and progress over it
  local dw = w - pad.x * 2
  local dy = y + h - pad.y
  renderer.draw_rect(x + pad.x, dy, dw, style.divider_size, self.divider_color or style.dim)
  if self.progress then
    renderer.draw_rect(x + pad.x, dy, dw * self.progress, style.divider_size, style.text)
  end

  if self.hovered and tooltip.shown(self, self.hovered) then
    for _, r in ipairs(self.rects) do
      if r[1] == self.hovered then self:draw_tooltip(r) end
    end
  end
end

function PanelHeader:draw_tooltip(rect)
  local b, bx, by, bw, bh = table.unpack(rect)
  core.root_view:defer_draw(function()
    local font = style.font
    local w = font:get_width(b.tooltip) + style.padding.x * 2
    local h = font:get_height() + style.padding.y
    local x = common.clamp(bx + bw - w, 0, core.root_view.size.x - w - 1)
    local y = by + bh + 1
    common.draw_popup_box(x, y, w, h)
    renderer.draw_text(font, b.tooltip, x + style.padding.x, y + style.padding.y / 2, style.text)
  end)
end

local function button_at(self, x, y)
  for _, r in ipairs(self.rects) do
    local b, bx, by, bw, bh = table.unpack(r)
    if x >= bx and x < bx + bw and y >= by and y < by + bh then return b end
  end
end

---@return boolean over_button
function PanelHeader:on_mouse_moved(x, y)
  local b = button_at(self, x, y)
  if b ~= self.hovered then
    self.hovered = b
    core.redraw = true
  end
  tooltip.hover(self, b)
  if b then core.request_cursor("hand") end
  return b ~= nil
end

---@return boolean handled
function PanelHeader:on_mouse_pressed(button, x, y)
  local b = button_at(self, x, y)
  if not b then return false end
  tooltip.dismiss()
  if button == "left" then self[b.action](self) end
  return true
end

function PanelHeader:on_mouse_left()
  self.hovered = nil
  tooltip.hover(self, nil)
end

---Removes the view from its panel, focusing the pane used last.
function PanelHeader:close()
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self.view)
  if node then node:remove_view(root, self.view) end
  core.set_active_view(core.root_view:get_last_used_node().active_view)
  self:on_mouse_left()
  if self.on_close then self.on_close(self.view) end
end

---Moves the view from its panel into a tab of the pane used last.
function PanelHeader:move_to_tab()
  local root = core.root_view.root_node
  local node = root:get_node_for_view(self.view)
  if node then node:remove_view(root, self.view) end
  -- only now: removing the panel's node replaces its sibling's node
  core.root_view:get_last_used_node():add_view(self.view)
  core.set_active_view(self.view)
  self:on_mouse_left()
  if self.on_move_to_tab then self.on_move_to_tab(self.view) end
end


return PanelHeader
