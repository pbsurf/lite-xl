-- mod-version:3
local core = require "core"
local common = require "core.common"
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

-- Whether x, y is in the active doc view's gutter (the line numbers, and any
-- columns add-ons put there), the active view then.
local function in_gutter(x, y)
  local dv = core.active_view
  if not (x and y and dv:extends(DocView)) then return false end
  local x1, y1 = dv.position.x, dv.position.y
  return x >= x1 and x < x1 + dv:get_gutter_click_width()
    and y >= y1 and y < y1 + dv.size.y and not dv:scrollbar_overlaps_point(x, y), dv
end

-- Whether line is within one of doc's selections, as whole lines (one ending at
-- a line's start doesn't take that line).
local function in_selected_lines(doc, line)
  for _, l1, c1, l2, c2 in doc:get_selections(true) do
    if l2 > l1 and c2 == 1 then l2 = l2 - 1 end
    if (l1 ~= l2 or c1 ~= c2) and line >= l1 and line <= l2 then return true end
  end
  return false
end

-- A right-click on a doc's text moves the caret there first, so the menu's items
-- (and their predicates) act on what was clicked; a click within the selection
-- keeps it, for Cut, Copy and the like. In the gutter, to the line's start,
-- unless the line is selected (its items then act on the selected lines).
local function set_caret_at(x, y)
  local dv = core.active_view
  if not dv:extends(DocView) or dv:scrollbar_hovering() then return end
  local line, col = dv:resolve_screen_position(x, y)
  if in_gutter(x, y) then
    if not in_selected_lines(dv.doc, line) then dv.doc:set_selection(line, 1) end
  elseif not in_selection(dv.doc, line, col) then
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

-- Find and Replace with nothing selected search for the word at the caret (where
-- the right-click put it): it's selected first, as a double-click would, and
-- they take the selection as the text.
local seeds_search = { ["find-replace:find"] = true, ["find-replace:replace"] = true }

function menu:on_selected(item)
  local dv = core.active_view
  if seeds_search[item.command] and dv:extends(DocView) and not dv.doc:has_any_selection() then
    command.perform("doc:select-word")
  end
  ContextMenu.on_selected(self, item)
end

-- at the caret, below its line (in the text: the view's corner is the gutter's)
command.add("core.docview!", {
  ["context:show"] = function(dv)
    local line, col = dv.doc:get_selection()
    local x, y = dv:get_line_screen_position(line, col)
    x = common.clamp(x, dv.position.x + dv:get_gutter_width(), dv.position.x + dv.size.x)
    y = common.clamp(y + dv:get_line_height(), dv.position.y, dv.position.y + dv.size.y)
    menu:show(x, y)
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

---The gutter's menu, in place of the editor's, is the exclusive sets with this
---priority whose predicate is `menu.in_gutter` (and which may check more):
---add-ons add their own items for a line there. Columns of the gutter with
---menus of their own (priority 1, as `exclusive == true`) replace it.
menu.GUTTER = 0
menu.in_gutter = in_gutter

-- the line right-clicked (the caret's, set_caret_at), or the selected lines
menu:register(in_gutter, {
  { text = "Copy Reference", command = "doc:copy-reference" },
  { text = "Copy Absolute Reference", command = "doc:copy-absolute-reference" },
}, menu.GUTTER)


return menu
