local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"

---Behaviour shared by views listing results that are places in files, as
---project search's results and lsp's Symbols Search do. Selecting a result
---(arrow keys, page up/down, home/end, a click) shows it in the pane used
---last (RootView:peek_file), while the focus stays in the list; Enter or a
---double click moves the focus there. Where showing it would hide the list (a
---tab in that pane), a click or Enter opens it. Escape closes the view if it's
---a panel (it has a PanelHeader, `header`).
---
---A view class gets it with ResultsList.add_to(class, prefix), which adds the
---methods below (but not over the class's own) and the commands, named
---`prefix:select-next` and so on, for views extending the class. The class
---provides:
---* `get_result_count()`
---* `get_result_location(idx)`: filename, line1, col1[, line2, col2], the
---  range selected when shown
---* `get_selected_index()`: nil if none
---* `set_selected_index(idx)`: draws it selected and scrolls it into view
---* `get_page_size()`: results per page
---@class core.resultslist
local ResultsList = {}

---Selects a result (clamped to the list) and shows it, if that can be done
---without hiding the list.
---@param idx integer
function ResultsList:select(idx)
  local count = self:get_result_count()
  if count == 0 then return end
  idx = common.clamp(idx, 1, count)
  self:set_selected_index(idx)
  self.shown = nil
  if core.root_view:can_peek(self) then
    self.shown = core.root_view:peek_file(self:get_result_location(idx))
  end
end

---Selects the result `n` after the selected one (before if negative); from
---none, the first going down, the last going up.
---@param n integer
function ResultsList:step(n)
  local idx = self:get_selected_index()
  self:select(idx and idx + n or (n > 0 and 1 or self:get_result_count()))
end

---Shows the selected result, or the first, and focuses it.
---@return core.docview?
function ResultsList:open_selected()
  if not self:get_selected_index() then self:select(1) end
  local idx = self:get_selected_index()
  if not idx then return end
  local dv = self.shown or core.root_view:peek_file(self:get_result_location(idx))
  if dv then core.set_active_view(dv) end
  return dv
end

---A click on a result: selects it, and opens it on a double click or if it
---can't be shown without hiding the list.
---@param idx integer
---@param clicks integer
function ResultsList:click_result(idx, clicks)
  self:select(idx)
  if clicks > 1 or not core.root_view:can_peek(self) then self:open_selected() end
end

---Adds the methods to a view class, and its commands with their keys.
---@param cls core.view
---@param prefix string Of the commands' names
function ResultsList.add_to(cls, prefix)
  for name, fn in pairs(ResultsList) do
    if name ~= "add_to" and rawget(cls, name) == nil then cls[name] = fn end
  end

  local function active()
    return core.active_view:extends(cls), core.active_view
  end
  command.add(active, {
    [prefix .. ":select-previous"] = function(view) view:step(-1) end,
    [prefix .. ":select-next"] = function(view) view:step(1) end,
    [prefix .. ":select-previous-page"] = function(view) view:step(-view:get_page_size()) end,
    [prefix .. ":select-next-page"] = function(view) view:step(view:get_page_size()) end,
    [prefix .. ":select-first"] = function(view) view:select(1) end,
    [prefix .. ":select-last"] = function(view) view:select(view:get_result_count()) end,
    [prefix .. ":open-selected"] = function(view) view:open_selected() end,
  })
  -- Escape closes a panel; a tab is closed as any other
  command.add(function()
    local view = core.active_view
    return view:extends(cls) and view.header and view.header:is_panel(), view
  end, {
    [prefix .. ":close"] = function(view) view.header:close() end,
  })

  keymap.add {
    ["up"] = prefix .. ":select-previous",
    ["down"] = prefix .. ":select-next",
    ["pageup"] = prefix .. ":select-previous-page",
    ["pagedown"] = prefix .. ":select-next-page",
    ["home"] = prefix .. ":select-first",
    ["end"] = prefix .. ":select-last",
    ["ctrl+home"] = prefix .. ":select-first",
    ["ctrl+end"] = prefix .. ":select-last",
    ["return"] = prefix .. ":open-selected",
    ["escape"] = prefix .. ":close",
  }
end

return ResultsList
