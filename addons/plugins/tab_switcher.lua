-- mod-version:3
local core = require "core"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local common = require "core.common"
local DocView = require "core.docview"

config.plugins.tab_switcher = common.merge({
  -- false: the switch commands change tabs immediately instead of showing a list;
  -- while the modifier keys are held they keep stepping through the same list
  show_list = true,
  config_spec = {
    name = "Tab Switcher",
    {
      label = "Show List",
      description = "Show the list of tabs when switching, instead of switching immediately.",
      path = "show_list",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.tab_switcher)

local nodes_visit_order = setmetatable({}, {__mode = "k"})

---When true, releasing all the modifier keys will accept the selection
local hold_mode = false
---Whether or not the CommandView relative to this plugin is active
local in_switcher = false
---With show_list off, the tabs being stepped through while the modifiers are held:
---{ items = tab_switcher.tab_item[], idx = number }
local cycle = nil

---@param t table<any, boolean?>
---@return boolean
local function any_true(t)
  for _, v in pairs(t) do
    if v then return true end
  end
  return false
end

-- We need to override keymap.on_key_released to detect that all the modifier
-- keys were released while in "hold" mode, to accept the current selection.
local old_keymap_on_key_released = keymap.on_key_released
function keymap.on_key_released(k)
  -- Check if hold_mode has been triggered erroneously
  if hold_mode and not in_switcher then
    hold_mode = false
    core.warn("Something went wrong with the tab_switcher plugin. " ..
              "Please open an issue about it in the plugins repository on Github.")
  end

  local was_pressed = any_true(keymap.modkeys)
  old_keymap_on_key_released(k)
  local still_pressed = any_true(keymap.modkeys)

  if hold_mode and was_pressed and not still_pressed then
    hold_mode = false
    command.perform("command:submit")
  end

  -- the tabs stepped through don't count as visited, only the one we end on
  if cycle and not still_pressed then
    cycle = nil
    core.set_active_view(core.active_view)
  end
end


local order_counter = 0

local core_set_active_view = core.set_active_view
function core.set_active_view(view)
  if not cycle then
    nodes_visit_order[view] = order_counter
    order_counter = order_counter + 1
  end
  return core_set_active_view(view)
end

local tab_switcher = {}

---@class tab_switcher.tab_item
---@field text string The tab name
---@field view core.view

---Returns the list of DocView tabs under a specific node tree.
---@param base_node core.node Where to start the search from
---@return tab_switcher.tab_item[]
function tab_switcher.get_tab_list(base_node)
  local raw_list = base_node:get_children()
  local list = {}
  local mt = {
    -- fuzzy_match uses tostring to get the text to compare
    __tostring = function(i) return i.text end
  }
  for _,v in pairs(raw_list) do
    if v:is(DocView) then
      table.insert(list, setmetatable({
        text = v:get_name(),
        font = v:get_name_style(core.command_view:get_font()),
        view = v
      }, mt))
    end
  end
  table.sort(list, function(a, b)
    return (nodes_visit_order[a.view] or -1) > (nodes_visit_order[b.view] or -1)
  end)
  return list
end

local function set_active_view(view)
  local n = core.root_view.root_node:get_node_for_view(view)
  if n then n:set_active_view(view) end
end

---@param label string
---@param items tab_switcher.tab_item[]
local function ask_selection(label, items)
  in_switcher = true
  core.command_view:enter(label, {
    submit = function(_, item)
      in_switcher = false
      set_active_view(item.view)
    end,
    suggest = function(text)
      if #text > 1 then
        return common.fuzzy_match(items, text, true)
      else
        return items
      end
    end,
    validate = function(_, item)
      return item
    end,
    cancel = function()
      in_switcher = false
    end,
  })
end

---Steps through items without showing them; the first step from the active
---tab goes to items[2] (dir 1) or to the last item (dir -1).
---@param items tab_switcher.tab_item[]
---@param dir number
local function start_cycle(items, dir)
  cycle = { items = items, idx = items[1].view == core.active_view and 1 or 0 }
  if dir < 0 and cycle.idx == 0 then cycle.idx = 1 end
  command.perform(dir > 0 and "tab-switcher:previous-tab" or "tab-switcher:next-tab")
  -- not run from a key binding with modifiers: no release will end it
  if not any_true(keymap.modkeys) then
    cycle = nil
    core.set_active_view(core.active_view)
  end
end

command.add(function(items)
    items = items or tab_switcher.get_tab_list(core.root_view.root_node)
    return #items > 0, items
  end, {
  ["tab-switcher:tab-list"] = function(items)
    ask_selection("Switch to tab", items)
  end,
  ["tab-switcher:switch-to-last-tab"] = function(items)
    if not config.plugins.tab_switcher.show_list then
      return start_cycle(items, 1)
    end
    command.perform("tab-switcher:tab-list", items)
    command.perform("tab-switcher:previous-tab")
  end,
  ["tab-switcher:switch-to-oldest-tab"] = function(items)
    if not config.plugins.tab_switcher.show_list then
      return start_cycle(items, -1)
    end
    command.perform("tab-switcher:tab-list", items)
    command.perform("tab-switcher:next-tab")
  end,
})

command.add(function(items)
    items = items or tab_switcher.get_tab_list(core.root_view:get_active_node())
    return #items > 0, items
  end, {
  ["tab-switcher:tab-list-current-split"] = function(items)
    ask_selection("Switch to tab in current split", items)
  end,
  ["tab-switcher:switch-to-last-tab-in-current-split"] = function(items)
    if not config.plugins.tab_switcher.show_list then
      return start_cycle(items, 1)
    end
    command.perform("tab-switcher:tab-list-current-split", items)
    command.perform("tab-switcher:previous-tab")
  end,
})

---@param dir number 1 for less recently used, -1 for more
local function step_cycle(dir)
  cycle.idx = (cycle.idx + dir - 1) % #cycle.items + 1
  set_active_view(cycle.items[cycle.idx].view)
end

command.add(function() return in_switcher or cycle ~= nil end, {
  ["tab-switcher:next-tab"] = function()
    if cycle then return step_cycle(-1) end
    hold_mode = true
    command.perform("command:select-next")
  end,
  ["tab-switcher:previous-tab"] = function()
    if cycle then return step_cycle(1) end
    hold_mode = true
    command.perform("command:select-previous")
  end,
})

keymap.add({
  ["alt+p"]             = { "tab-switcher:previous-tab", "tab-switcher:tab-list" },
  ["ctrl+alt+p"]        = { "tab-switcher:previous-tab", "tab-switcher:switch-to-last-tab" },
  ["alt+shift+p"]       = { "tab-switcher:next-tab", "tab-switcher:tab-list-current-split" },
  ["ctrl+alt+shift+p"]  = { "tab-switcher:next-tab", "tab-switcher:switch-to-last-tab-in-current-split" },
})

return tab_switcher
