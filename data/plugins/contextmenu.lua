-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"
local DocView = require "core.docview"

local menu = ContextMenu()
local on_view_mouse_pressed = RootView.on_view_mouse_pressed
local on_mouse_moved = RootView.on_mouse_moved
local root_view_update = RootView.update
local root_view_draw = RootView.draw

function RootView:on_mouse_moved(...)
  if menu:on_mouse_moved(...) then return end
  on_mouse_moved(self, ...)
end

-- Whether line, col is within one of doc's (non-empty) selections.
local function in_selection(doc, line, col)
  for _, l1, c1, l2, c2 in doc:get_selections(true) do
    if (l1 ~= l2 or c1 ~= c2)
      and (line > l1 or line == l1 and col >= c1)
      and (line < l2 or line == l2 and col <= c2) then
      return true
    end
  end
  return false
end

-- A right-click on a doc's text moves the caret there first, so the menu's items
-- (and their predicates) act on what was clicked; a click within the selection
-- keeps it, for Cut, Copy and the like.
local function set_caret_at(x, y)
  local dv = core.active_view
  if not dv:extends(DocView) or dv:scrollbar_hovering()
    or x < dv.position.x + dv:get_gutter_click_width() then
    return
  end
  local line, col = dv:resolve_screen_position(x, y)
  if not in_selection(dv.doc, line, col) then
    dv.doc:set_selection(line, col)
  end
end

function RootView.on_view_mouse_pressed(button, x, y, clicks)
  if button == "right" and not menu.show_context_menu then set_caret_at(x, y) end
  -- We give the priority to the menu to process mouse pressed events.
  local handled = menu:on_mouse_pressed(button, x, y, clicks)
  return handled or on_view_mouse_pressed(button, x, y, clicks)
end

function RootView:update(...)
  root_view_update(self, ...)
  menu:update()
end

function RootView:draw(...)
  root_view_draw(self, ...)
  menu:draw()
end

command.add("core.docview!", {
  ["context:show"] = function(dv)
    menu:show(dv.position.x, dv.position.y)
  end
})

keymap.add {
  ["menu"] = "context:show"
}


local cmds = {
  { text = "Cut",     command = "doc:cut" },
  { text = "Copy",    command = "doc:copy" },
  { text = "Paste",   command = "doc:paste" },
  ContextMenu.DIVIDER,
  { text = "Find",    command = "find-replace:find"    },
  { text = "Replace", command = "find-replace:replace" }
}

menu:register("core.docview", cmds)


return menu
