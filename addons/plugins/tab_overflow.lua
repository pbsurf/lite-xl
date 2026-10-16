-- mod-version:3
-- Buttons for the tab bar while its tabs scroll: scroll_left and scroll_right, and
-- menu, which shows how many tabs there are and opens a menu of all the tabs in
-- the split. config.tab_buttons chooses which show; tab-overflow:show opens the
-- menu from the keyboard.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local ContextMenu = require "core.contextmenu"
local Node = require "core.node"
local RootView = require "core.rootview"

local menu = ContextMenu()

Node.tab_buttons.scroll_left = {
  icon = "<",
  on_click = function(node) node:scroll_tabs(1) end,
  active = function(node) return node.tab_scroll > 0 end,
}

Node.tab_buttons.scroll_right = {
  icon = ">",
  on_click = function(node) node:scroll_tabs(2) end,
  active = function(node)
    return node.tab_scroll < node:get_max_tab_scroll()
  end,
}

---A doc's file icon, as the treeview (and an icon plugin like nerdicons) draws it.
---@return string? icon, renderer.font? font, renderer.color? color
local function get_icon(view)
  local TreeView = package.loaded["plugins.treeview"]
  if not (TreeView and view.doc) then return end
  return TreeView:get_item_icon({ type = "file", name = view.doc:get_name() }, false, false)
end

---Shows the menu of the node's tabs, its top right corner at x, y.
local function show_menu(node, x, y)
  local items = {}
  local icon_w = 0
  for _, view in ipairs(node.views) do
    local icon, icon_font, icon_color = get_icon(view)
    if icon then icon_w = math.max(icon_w, icon_font:get_width(icon)) end
    table.insert(items, {
      text = view:get_name(),
      icon = icon, icon_font = icon_font, icon_color = icon_color,
      active = view == node.active_view,
      command = function()
        if node:get_view_idx(view) then node:set_active_view(view) end
      end,
    })
  end
  menu.itemset = {}
  menu:register(nil, items)
  if menu:show(x, y) then
    -- ContextMenu sizes the menu from the text only: add the icon column
    menu.icon_w = icon_w > 0 and icon_w + style.padding.x / 2 or 0
    menu.items.width = menu.items.width + menu.icon_w
    menu.position.x = math.max(0, x - menu.items.width)
    menu.node = node
    for i, item in ipairs(items) do
      if item.active then menu.selected = i end
    end
  end
end

-- "N ▾", N the number of tabs
local function chevron_width()
  return style.icon_font:get_width("-")
end

Node.tab_buttons.menu = {
  on_click = function(node, x, y, w, h) show_menu(node, x + w, y + h) end,
  width = function(node)
    local digits = string.rep("0", #tostring(#node.views))
    return style.font:get_width(digits) + chevron_width() + style.padding.x * 2
  end,
  -- accent color while hovered or its menu is open
  draw = function(node, x, y, w, h, hovered)
    local color = (hovered or menu.node == node) and style.accent or style.text
    local cx = x + w - style.padding.x - chevron_width()
    common.draw_text(style.font, color, tostring(#node.views), "right", x, y, cx - x - style.padding.x / 4, h)
    common.draw_text(style.icon_font, color, "-", nil, cx, y, 0, h)
  end,
}

-- As core's draw_context_menu, with file icons and the active tab in the accent color
function menu:draw_context_menu()
  if not self.items then return end
  local bx, by, bw, bh = self.position.x, self.position.y, self.items.width, self.height
  common.draw_popup_box(bx, by, bw, bh)
  for i, item, x, y, w, h in self:each_item() do
    if i == self.selected then
      renderer.draw_rect(x, y, w, h, style.selection)
    end
    local tx = x + style.padding.x
    if item.icon then
      common.draw_text(item.icon_font, item.icon_color, item.icon, nil, tx, y, 0, h)
    end
    local color = item.active and style.accent or style.text
    common.draw_text(style.font, color, item.text, "left", tx + self.icon_w, y, w, h)
  end
end

-- The menu gets mouse events first while shown: a click anywhere closes it,
-- selecting the tab under the mouse, if any
local root_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if not menu.show_context_menu then
    return root_on_mouse_pressed(self, button, x, y, clicks)
  end
  local mx, my = menu.position.x, menu.position.y
  if x < mx or x >= mx + menu.items.width or y < my or y >= my + menu.items.height then
    menu.selected = -1
  end
  return menu:on_mouse_pressed(button, x, y, clicks)
end

local mouse_x, mouse_y = 0, 0
local root_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, ...)
  mouse_x, mouse_y = x, y
  if menu:on_mouse_moved(x, y, ...) then return end
  return root_on_mouse_moved(self, x, y, ...)
end

-- The moves the menu took left the root view's hover state (tab, button, cursor)
-- where the menu was opened: a click there without moving would open it again
local menu_hide = menu.hide
function menu:hide()
  menu_hide(self)
  if self.node then
    self.node = nil
    root_on_mouse_moved(core.root_view, mouse_x, mouse_y, 0, 0)
  end
end

local root_update = RootView.update
function RootView:update(...)
  root_update(self, ...)
  menu:update()
end

local root_draw = RootView.draw
function RootView:draw(...)
  root_draw(self, ...)
  menu:draw()
end

command.add(function() return menu.show_context_menu == true end, {
  ["tab-overflow:focus-previous"] = function() menu:focus_previous() end,
  ["tab-overflow:focus-next"] = function() menu:focus_next() end,
  ["tab-overflow:hide"] = function() menu:hide() end,
  ["tab-overflow:select"] = function() menu:call_selected_item() end,
})

command.add(function()
    local node = core.root_view:get_active_node()
    return #node.views > 1, node
  end, {
  ["tab-overflow:show"] = function(node)
    show_menu(node, node.position.x + node.size.x, node.position.y + node:get_tab_bar_height())
  end,
})

keymap.add {
  ["up"] = "tab-overflow:focus-previous",
  ["down"] = "tab-overflow:focus-next",
  ["escape"] = "tab-overflow:hide",
  ["return"] = "tab-overflow:select",
}

return menu
