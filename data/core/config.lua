local common = require "core.common"

local config = {}

config.fps = 60
config.max_log_items = 800
config.message_timeout = 5
-- seconds the mouse rests on something before its tooltip shows (core.tooltip)
config.tooltip_delay = 0.5
config.mouse_wheel_scroll = 50 * SCALE
config.animate_drag_scroll = false
config.scroll_past_end = true
---@type "expanded" | "contracted" | false @Force the scrollbar status of the DocView
config.force_scrollbar_status = false
config.file_size_limit = 10
config.ignore_files = {
  -- folders
  "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
  "^node_modules/", "^%.cache/", "^__pycache__/",
  -- files
  "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
  "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
  "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
  "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
}
config.symbol_pattern = "[%a_][%w_]*"
config.non_word_chars = " \t\n/\\()\"':,.;<>~!@#$%^&*|+=[]{}`?-"
config.undo_merge_timeout = 0.3
config.max_undos = 10000
-- Tabs scroll once a split has more than max_tabs, or they would get narrower than
-- min_tab_width (pixels at scale 1); 0 disables either limit
config.max_tabs = 0
config.min_tab_width = 120
-- Buttons at the right end of the tab bar while its tabs scroll, left to right;
-- names nothing registered in Node.tab_buttons are skipped (the tab_overflow
-- add-on registers "scroll_left", "scroll_right" and "menu")
config.tab_buttons = { "menu" }
config.always_show_tabs = true
-- Possible values: false, true, "no_selection"
config.highlight_current_line = true
config.line_height = 1.2
config.indent_size = 2
config.tab_type = "soft"
config.keep_newline_whitespace = false
config.line_limit = 80
config.max_project_files = 2000
config.transitions = true
config.disabled_transitions = {
  scroll = false,
  commandview = false,
  contextmenu = false,
  logview = false,
  nagbar = false,
  tabs = false,
  tab_drag = false,
  statusbar = false,
}
config.animation_rate = 1.0
config.blink_period = 0.8
config.disable_blink = false
config.draw_whitespace = false
config.borderless = false
config.tab_close_button = true
config.max_clicks = 3

-- key bindings of plugins, by plugin name: false for none of them, or a list
-- of the strokes and commands to keep (e.g. { "f6", "build:clean" }); plugins
-- not listed keep all their bindings. Set it in the user module, which loads
-- before plugins; their commands remain, for the command palette and menus.
---@type table<string, false|string[]>
config.plugin_keys = {}

-- set as true to be able to test non supported plugins
config.skip_plugins_version = false

-- holds the plugins real config table
local plugins_config = {}

-- virtual representation of plugins config table
config.plugins = {}

-- allows virtual access to the plugins config table
setmetatable(config.plugins, {
  __index = function(_, k)
    if not plugins_config[k] then
      plugins_config[k] = { enabled = true, config = {} }
    end
    if plugins_config[k].enabled ~= false then
      return plugins_config[k].config
    end
    return false
  end,
  __newindex = function(_, k, v)
    if not plugins_config[k] then
      plugins_config[k] = { enabled = nil, config = {} }
    end
    if v == false and package.loaded["plugins."..k] then
      local core = require "core"
      core.warn("[%s] is already enabled, restart the editor for the change to take effect", k)
      return
    elseif plugins_config[k].enabled == false and v ~= false then
      plugins_config[k].enabled = true
    end
    if v == false then
      plugins_config[k].enabled = false
    elseif type(v) == "table" then
      plugins_config[k].enabled = true
      plugins_config[k].config = common.merge(plugins_config[k].config, v)
    end
  end,
  __pairs = function()
    return coroutine.wrap(function()
      for name, status in pairs(plugins_config) do
        coroutine.yield(name, status.config)
      end
    end)
  end
})


return config
