-- mod-version:3
-- Buttons for the tab bar while its tabs scroll: scroll_left and scroll_right, and
-- menu, which shows how many tabs are hidden and opens a menu of all the tabs in
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
  active = function(node) return node.tab_offset > 1 end,
}

Node.tab_buttons.scroll_right = {
  icon = ">",
  on_click = function(node) node:scroll_tabs(2) end,
  active = function(node)
    return node.tab_offset + node:get_visible_tabs_number() - 1 < #node.views
  end,
}

---Shows the menu of the node's tabs, its top right corner at x, y.
local function show_menu(node, x, y)
  local items = {}
  for _, view in ipairs(node.views) do
    table.insert(items, {
      text = view:get_name(),
      active = view == node.active_view,
      command = function()
        if node:get_view_idx(view) then node:set_active_view(view) end
      end,
    })
  end
  menu.itemset = {}
  menu:register(nil, items)
  if menu:show(x, y) then
    menu.position.x = math.max(0, x - menu.items.width)
    menu.node = node
    for i, item in ipairs(items) do
      if item.active then menu.selected = i end
    end
  end
end

-- "N ▾", N the number of hidden tabs
local function chevron_width()
  return style.icon_font:get_width("-")
end

Node.tab_buttons.menu = {
  on_click = function(node, x, y, w, h) show_menu(node, x + w, y + h) end,
  -- room for the most digits the count can have, so it doesn't change with the count
  width = function(node)
    local digits = string.rep("0", #tostring(#node.views))
    return style.font:get_width(digits) + chevron_width() + style.padding.x * 2
  end,
  -- accent color while hovered or its menu is open
  draw = function(node, x, y, w, h, hovered)
    local color = (hovered or menu.node == node) and style.accent or style.text
    local cx = x + w - style.padding.x - chevron_width()
    local hidden = #node.views - node:get_visible_tabs_number()
    common.draw_text(style.font, color, tostring(hidden), "right", x, y, cx - x - style.padding.x / 4, h)
    common.draw_text(style.icon_font, color, "-", nil, cx, y, 0, h)
  end,
}

-- As core's draw_context_menu, with the active tab in the accent color
function menu:draw_context_menu()
  if not self.items then return end
  local bx, by, bw, bh = self.position.x, self.position.y, self.items.width, self.height
  renderer.draw_rect(bx - 1, by - 1, bw + 2, bh + 2, style.divider)
  renderer.draw_rect(bx, by, bw, bh, style.background3)
  for i, item, x, y, w, h in self:each_item() do
    if i == self.selected then
      renderer.draw_rect(x, y, w, h, style.selection)
    end
    local color = item.active and style.accent or style.text
    common.draw_text(style.font, color, item.text, "left", x + style.padding.x, y, w, h)
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
