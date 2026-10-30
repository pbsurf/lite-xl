-- mod-version:3
-- A menu bar of commands, shown under the title view (the header bar, with the
-- headerbar plugin; else at the top of the window), the rest moving down,
-- when Alt is tapped (pressed and released on its own). Its menus come from
-- config.plugins.menubar.menus; the end of the last one lists, by plugin, the
-- commands no menu has, leaving out those that only exist to be bound to keys.
--
-- While shown: a menu's first letter (underlined) or Down/Return opens it,
-- Left/Right move between menus, Up/Down/Return choose in one, Escape closes.
-- menubar.popup drops the same menus from a point instead (e.g. a button), as
-- one menu with a submenu each; Up/Down/Left/Right/Return and first letters
-- work there too.
--
-- Rows whose command doesn't apply now are dimmed; commands of plugins that
-- aren't installed are left out. Rows for settings that are on (see
-- config.plugins.menubar.checked) have a checkmark.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"
local View = require "core.view"
local shapes = require "libraries.shapes"

---A menu row: a command name; a table with `command` (a name, or a list of
---names: the first that applies now, else the first that exists) and optional
---`text` (else the command's name, prettified, without its prefix); a row
---running a function, { text = ..., action = function() ... end }; a submenu,
---{ text = ..., rows = { ... } }, where `rows` can be a function returning them
---(called each time the menu opens, e.g. for a list that changes); or "-" for
---a divider.
---@alias plugins.menubar.row string | { command: string|string[], text?: string } | { text: string, action: function } | { text: string, rows: plugins.menubar.row[] | fun(): plugins.menubar.row[] }

---@class plugins.menubar.menu
---@field title string
---@field rows plugins.menubar.row[]

local menubar = {}

config.plugins.menubar = common.merge({
  ---@type plugins.menubar.menu[]
  menus = {
    { title = "File", rows = {
      { command = "core:new-doc", text = "New File" },
      { command = "core:new-named-doc", text = "New Named File..." },
      { command = "core:open-file-picker", text = "Open File..." },
      { text = "Open Recent", rows = function() return menubar.recent_rows() end },
      { command = "core:reopen-closed-tab", text = "Reopen Closed Tab" },
      "-",
      { command = "core:open-project-folder-picker", text = "Open Project Folder..." },
      { command = "core:change-project-folder-picker", text = "Change Project Folder..." },
      { command = "core:add-directory-picker", text = "Add Directory to Project..." },
      { command = "core:remove-directory", text = "Remove Directory from Project..." },
      "-",
      { command = "doc:save", text = "Save" },
      { command = "doc:save-as-picker", text = "Save As..." },
      { command = "doc:reload", text = "Reload from Disk" },
      { command = "file:rename", text = "Rename File..." },
      { command = "file:delete", text = "Delete File" },
      "-",
      { command = "root:close", text = "Close Tab" },
      { command = "root:close-all-others", text = "Close Other Files" },
      { command = "root:close-all", text = "Close All Files" },
      "-",
      { command = "core:restart", text = "Restart" },
      { command = "core:quit", text = "Quit" },
    } },
    { title = "Edit", rows = {
      "doc:undo",
      "doc:redo",
      "-",
      "doc:cut",
      "doc:copy",
      "doc:paste",
      "-",
      { command = { "search-replace:file-search", "find-replace:find" }, text = "Find..." },
      { command = "find-replace:replace", text = "Replace..." },
      { command = { "search-replace:next", "find-replace:repeat-find" }, text = "Find Next" },
      { command = { "search-replace:previous", "find-replace:previous-find" }, text = "Find Previous" },
      { command = "find-replace:replace-symbol", text = "Replace Symbol..." },
      { command = "project-search:find", text = "Find in Project..." },
      { command = "project-search:find-regex", text = "Find Regex in Project..." },
      "-",
      "doc:toggle-line-comments",
      "doc:toggle-block-comments",
      "doc:indent",
      "doc:unindent",
      { text = "Lines", rows = {
        "doc:duplicate-lines",
        "doc:delete-lines",
        "doc:move-lines-up",
        "doc:move-lines-down",
        "doc:join-lines",
        "doc:newline-above",
        "doc:newline-below",
      } },
      { text = "Transform", rows = {
        { command = "doc:upper-case", text = "Upper Case" },
        { command = "doc:lower-case", text = "Lower Case" },
        { command = "reflow:reflow", text = "Reflow Paragraph" },
        { command = "tabularize:tabularize", text = "Tabularize..." },
        { command = "quote:quote", text = "Quote as String" },
      } },
    } },
    { title = "Selection", rows = {
      "doc:select-all",
      { command = "doc:select-lines", text = "Select Lines" },
      { command = "doc:select-word", text = "Select Word" },
      { command = "bracket-match:select-to-matching", text = "Select to Matching Bracket" },
      { command = "doc:select-none", text = "Select None" },
      "-",
      { command = "find-replace:select-add-next", text = "Add Next Occurrence" },
      { command = "find-replace:select-add-all", text = "Select All Occurrences" },
      { command = "doc:create-cursor-previous-line", text = "Add Cursor Above" },
      { command = "doc:create-cursor-next-line", text = "Add Cursor Below" },
    } },
    { title = "View", rows = {
      { command = "core:find-command", text = "Command Palette..." },
      "-",
      { command = "treeview:toggle", text = "File Browser" },
      { command = "treeview:toggle-focus", text = "Focus File Browser" },
      { command = "toolbar:toggle", text = "Toolbar" },
      { command = "status-bar:toggle", text = "Status Bar" },
      { command = "build:toggle-output", text = "Build Output" },
      { command = "debugger:toggle-drawer", text = "Debugger" },
      { command = "core:open-log", text = "Log" },
      "-",
      { command = "line-wrapping:toggle", text = "Line Wrapping" },
      { command = "draw-whitespace:toggle", text = "Whitespace" },
      { command = "lineguide:toggle", text = "Line Guide" },
      { command = "highlight-selection:toggle", text = "Highlight Selection Matches" },
      "-",
      { command = "scale:increase", text = "Zoom In" },
      { command = "scale:decrease", text = "Zoom Out" },
      { command = "scale:reset", text = "Reset Zoom" },
      { command = "core:toggle-fullscreen", text = "Full Screen" },
      "-",
      { command = "root:split-left", text = "Split Left" },
      { command = "root:split-right", text = "Split Right" },
      { command = "root:split-up", text = "Split Up" },
      { command = "root:split-down", text = "Split Down" },
      { command = "root:grow", text = "Grow Split" },
      { command = "root:shrink", text = "Shrink Split" },
    } },
    { title = "Go", rows = {
      { command = "core:find-file", text = "Go to File..." },
      { command = "doc:go-to-line", text = "Go to Line..." },
      { command = "tab-switcher:tab-list", text = "Go to Tab..." },
      { command = "lsp:view-document-symbols", text = "Go to Symbol in File..." },
      { command = "lsp:find-workspace-symbol", text = "Go to Symbol in Project..." },
      "-",
      { command = "lsp:goto-definition", text = "Go to Definition" },
      { command = "lsp:goto-implementation", text = "Go to Implementation" },
      { command = "lsp:find-references", text = "Find References" },
      { command = "lsp:view-call-hierarchy", text = "Call Hierarchy" },
      { command = "bracket-match:move-to-matching", text = "Go to Matching Bracket" },
      "-",
      { command = "lint+:goto-next-message", text = "Next Problem" },
      { command = "lint+:goto-previous-message", text = "Previous Problem" },
      "-",
      { command = "root:switch-to-next-tab", text = "Next Tab" },
      { command = "root:switch-to-previous-tab", text = "Previous Tab" },
      { command = "tab-switcher:switch-to-last-tab", text = "Last Used Tab" },
      { command = "root:move-tab-left", text = "Move Tab Left" },
      { command = "root:move-tab-right", text = "Move Tab Right" },
      "-",
      { command = "root:switch-to-left", text = "Split to the Left" },
      { command = "root:switch-to-right", text = "Split to the Right" },
      { command = "root:switch-to-up", text = "Split Above" },
      { command = "root:switch-to-down", text = "Split Below" },
    } },
    { title = "Code", rows = {
      { command = "lsp:complete", text = "Complete" },
      { command = "lsp:show-signature", text = "Show Signature" },
      { command = "lsp:show-symbol-info", text = "Show Symbol Info" },
      { command = "lsp:show-symbol-info-in-tab", text = "Show Symbol Info in Tab" },
      "-",
      { command = "lsp:rename-symbol", text = "Rename Symbol..." },
      { command = "lsp:format-document", text = "Format Document" },
      "-",
      { command = "lsp:view-document-diagnostics", text = "Problems in File" },
      { command = "lsp:view-all-diagnostics", text = "All Problems" },
      { command = "lsp:toggle-diagnostics", text = "Toggle Diagnostics" },
      { command = "lint+:check", text = "Lint File" },
      "-",
      { command = "lsp:start-servers", text = "Start Language Servers" },
      { command = "lsp:stop-servers", text = "Stop Language Servers" },
      { command = "lsp:restart-servers", text = "Restart Language Servers" },
    } },
    { title = "Build", rows = {
      { command = "build:build", text = "Build" },
      { command = "build:clean-and-build", text = "Clean and Build" },
      { command = "build:clean", text = "Clean" },
      { command = "build:terminate", text = "Stop Build" },
      "-",
      { command = "build:run-or-term-or-kill", text = "Run" },
      { command = "build:run-or-term-or-kill-with-arguments", text = "Run with Arguments..." },
      { command = "build:build-and-run", text = "Build and Run" },
      "-",
      { command = "build:select-target", text = "Select Target..." },
      { command = "build:next-target", text = "Next Target" },
      "-",
      { command = "debugger:start-or-continue", text = "Start or Continue Debugging" },
      { command = "debugger:halt", text = "Pause" },
      { command = "debugger:terminate", text = "Stop Debugging" },
      { command = "debugger:step-over", text = "Step Over" },
      { command = "debugger:step-into", text = "Step Into" },
      { command = "debugger:step-out", text = "Step Out" },
      { command = "debugger:toggle-line-breakpoint", text = "Toggle Breakpoint" },
    } },
    { title = "Tools", rows = {
      { command = "indent:set-file-indent-size", text = "Set Indent Size..." },
      { command = "indent:set-file-indent-type", text = "Set Indent Type..." },
      { command = "doc:toggle-line-ending", text = "Toggle Line Endings" },
      { command = "trim-whitespace:trim-trailing-whitespace", text = "Trim Trailing Whitespace" },
      { command = "trim-whitespace:trim-empty-end-lines", text = "Trim Empty Lines at End" },
      "-",
      { command = "macro:toggle-record", text = "Record Macro" },
      { command = "macro:play", text = "Play Macro" },
      "-",
      { command = "core:open-user-module", text = "Edit User Settings" },
      { command = "core:open-project-module", text = "Edit Project Settings" },
      { command = "core:reload-module", text = "Reload Module..." },
    } },
  },
  ---Command prefixes left out of the automatic list (commands placed in a menu
  ---still show): those whose commands only make sense bound to keys, or act on
  ---a view's own selection.
  hidden_prefixes = {
    "autocomplete", "command", "context", "dialog", "listbox", "doc", "root",
    "treeview", "search-replace", "project-search", "find-replace",
    "tab-overflow", "tab-switcher", "log", "menubar",
  },
  ---Patterns of other commands left out of the automatic list.
  hidden_commands = { "^status%-bar:menu%-" },
  ---Commands that toggle a setting, each with a function telling whether it's
  ---on now (its rows get a checkmark then).
  ---@type table<string, fun(): boolean?>
  checked = {
    ["treeview:toggle"] = function()
      local tv = package.loaded["plugins.treeview"]
      return tv and tv.visible
    end,
    ["toolbar:toggle"] = function()
      local tv = package.loaded["plugins.treeview"]
      return tv and tv.toolbar and tv.toolbar.visible
    end,
    ["status-bar:toggle"] = function() return core.status_view.visible end,
    ["build:toggle-output"] = function()
      local build = package.loaded["plugins.build"]
      return build and build.is_output_shown()
    end,
    ["debugger:toggle-drawer"] = function()
      local debugger = package.loaded["plugins.debugger"]
      return debugger and debugger:should_show_drawer()
    end,
    ["line-wrapping:toggle"] = function() return core.active_view.wrapped_settings ~= nil end,
    ["draw-whitespace:toggle"] = function() return config.plugins.drawwhitespace.enabled end,
    ["lineguide:toggle"] = function() return config.plugins.lineguide.enabled end,
    ["highlight-selection:toggle"] = function() return config.plugins.highlight_selection.enabled end,
    ["minimap:toggle-visibility"] = function() return config.plugins.minimap.enabled end,
    ["minimap:toggle-syntax-highlighting"] = function() return config.plugins.minimap.syntax_highlight end,
    ["core:toggle-fullscreen"] = function() return system.get_window_mode() == "fullscreen" end,
  },
}, config.plugins.menubar)


-- active: the bar or the popup is shown; open: the index of the menu dropped
-- down from the bar, if any; hovered: the title under the mouse (or chosen from
-- the keyboard); keyboard: shown from the keyboard (accelerators underlined);
-- popup: the y of the top of the popup (menubar.popup) when that's shown
-- instead of the bar
local state = { active = false, open = nil, hovered = nil, keyboard = false, popup = nil }

local function bar_shown()
  return state.active and not state.popup
end

---A dropdown menu: rows dimmed when their command doesn't apply, and
---submenus (rows with `rows`), opened to the right
---@class plugins.menubar.dropdown : core.contextmenu
local Dropdown = ContextMenu:extend()
-- the menubar handles the keys for its dropdowns
Dropdown.modal = false

---Size of the checkmark, and of the column for it left of the rows' text.
local function check_size()
  return math.floor(style.font:get_height() * 0.5)
end

function Dropdown:register(predicate, items)
  ContextMenu.register(self, predicate, items)
  items.width = items.width + check_size()
end

-- the open dropdowns: [1] dropped from the bar, then each one's open submenu
local stack = {}

local function bar_height()
  return style.font:get_height() + style.padding.y * 2
end

---Each menu's title and its x range on the bar.
local function title_rects()
  local rects, x = {}, style.padding.x / 2
  for i, menu in ipairs(config.plugins.menubar.menus) do
    local w = style.font:get_width(menu.title) + style.padding.x * 2
    rects[i] = { x = x, w = w }
    x = x + w
  end
  return rects
end

-- the bar is a view, in the layout under the title view: 0 high while hidden
local BarView = View:extend()

function BarView:__tostring() return "MenuBar" end

function BarView:update()
  self.size.y = bar_shown() and bar_height() or 0
  BarView.super.update(self)
end

local bar_view = BarView()
core.root_view.root_node:get_node_for_view(core.title_view):split("down", bar_view, { y = true })

local function bar_bottom()
  return bar_view.position.y + bar_view.size.y
end

local function on_bar(py)
  return bar_shown() and py >= bar_view.position.y and py < bar_bottom()
end

local function title_at(px, py)
  if not on_bar(py) then return end
  for i, r in ipairs(title_rects()) do
    if px >= r.x and px < r.x + r.w then return i end
  end
end


local function names_of(spec)
  local names = type(spec) == "string" and spec or spec.command
  return type(names) == "string" and { names } or names or {}
end

---A row's command: of its alternatives, the first that applies now, else the
---first that exists.
local function row_command(spec)
  local existing
  for _, name in ipairs(names_of(spec)) do
    if command.map[name] then
      if command.is_valid(name) then return name end
      existing = existing or name
    end
  end
  return existing
end

local function label(name)
  return (command.prettify_name(name):gsub("^[^:]*: ", ""))
end

---The shortest of a command's key bindings (ctrl+v rather than shift+insert).
local function binding(name)
  local best
  for _, b in ipairs(keymap.get_bindings(name) or {}) do
    if not best or #b < #best then best = b end
  end
  return best
end

---Commands no menu has, not hidden (by prefix, pattern or command.hidden), not
---bound to a mouse action, and not the enable/disable or show/hide of a toggle a
---menu has; sorted.
local function unplaced_commands()
  local placed = {}
  local function mark(rows)
    for _, spec in ipairs(rows) do
      if type(spec) == "table" and spec.rows then
        if type(spec.rows) == "table" then mark(spec.rows) end
      elseif type(spec) == "table" and spec.action then
      elseif spec ~= "-" then
        for _, name in ipairs(names_of(spec)) do placed[name] = true end
      end
    end
  end
  for _, menu in ipairs(config.plugins.menubar.menus) do mark(menu.rows) end
  local hidden = {}
  for _, prefix in ipairs(config.plugins.menubar.hidden_prefixes) do hidden[prefix] = true end
  local function hidden_command(name)
    for _, pattern in ipairs(config.plugins.menubar.hidden_commands) do
      if name:match(pattern) then return true end
    end
  end
  local toggle_parts = { enable = true, disable = true, show = true, hide = true }
  local function placed_toggle_part(name)
    local base, action = name:match("^(.*):(%a+)$")
    return base and toggle_parts[action] and placed[base .. ":toggle"]
  end
  local res = {}
  for name in pairs(command.map) do
    local b = keymap.get_binding(name) or ""
    if not placed[name] and not placed_toggle_part(name)
       and not hidden[name:match("^[^:]+")] and not hidden_command(name)
       and not command.hidden[name]
       and not b:match("click$") and not b:match("wheel") then
      table.insert(res, name)
    end
  end
  table.sort(res)
  return res
end

---Specs for the commands no menu has: a submenu per plugin.
local function unplaced_specs()
  local specs, sub, last_prefix = {}, nil, nil
  for _, name in ipairs(unplaced_commands()) do
    local prefix = name:match("^[^:]+")
    if prefix ~= last_prefix then
      sub = { text = command.prettify_name(prefix), rows = {} }
      table.insert(specs, sub)
      last_prefix = prefix
    end
    table.insert(sub.rows, name)
  end
  return specs
end

---Dropdown rows from specs; nil if none is left (commands not installed).
local function build_rows(specs)
  local rows = {}
  for _, spec in ipairs(specs) do
    if spec == "-" then
      if #rows > 0 and rows[#rows] ~= ContextMenu.DIVIDER then
        table.insert(rows, ContextMenu.DIVIDER)
      end
    elseif type(spec) == "table" and spec.rows then
      local sub = build_rows(type(spec.rows) == "function" and spec.rows() or spec.rows)
      if sub then
        -- info reserves room for the arrow
        table.insert(rows, { text = spec.text, rows = sub, info = "  ", command = function() end })
      end
    elseif type(spec) == "table" and spec.action then
      table.insert(rows, { text = spec.text, info = spec.info, command = spec.action })
    else
      local name = row_command(spec)
      if name then
        local checked = config.plugins.menubar.checked[name]
        table.insert(rows, {
          checked = checked and checked() or nil,
          text = type(spec) == "table" and spec.text or label(name),
          info = binding(name),
          disabled = not command.is_enabled(name),
          command = function() command.perform(name) end,
        })
      end
    end
  end
  if rows[#rows] == ContextMenu.DIVIDER then table.remove(rows) end
  return #rows > 0 and rows or nil
end

-- Of each list, the rows File > Open Recent shows at most
local MAX_RECENT_SHOWN = 15

---Rows for File > Open Recent: the recent files that exist and aren't open (the
---one closed last first), then the recent projects (names, with their directory
---on the right), and Clear Recent.
function menubar.recent_rows()
  local rows = {}
  local function add(paths, open, skip)
    local n = 0
    for _, path in ipairs(paths) do
      if n == MAX_RECENT_SHOWN then break end
      if path ~= skip and system.get_file_info(path) then
        table.insert(rows, {
          text = common.basename(path),
          info = common.home_encode(common.dirname(path)),
          action = function() open(path) end,
        })
        n = n + 1
      end
    end
  end
  add(core.get_closed_recent_files(), core.reopen_file)
  table.insert(rows, "-")
  add(core.recent_projects, function(path)
    core.confirm_close_docs(core.docs, core.open_folder_project, path)
  end, core.project_dir)
  table.insert(rows, "-")
  table.insert(rows, { text = "Clear Recent", action = function()
    for i = #core.recent_files, 1, -1 do table.remove(core.recent_files, i) end
    -- the current project stays: it's the one opened at start
    for i = #core.recent_projects, 1, -1 do
      if core.recent_projects[i] ~= core.project_dir then table.remove(core.recent_projects, i) end
    end
  end })
  return rows
end

local function menu_rows(i)
  local menus = config.plugins.menubar.menus
  local specs = menus[i].rows
  if i == #menus then
    specs = { table.unpack(specs) }
    table.insert(specs, "-")
    for _, spec in ipairs(unplaced_specs()) do table.insert(specs, spec) end
  end
  return build_rows(specs)
end


---Opens a dropdown of rows with its top left at x, y (moved to fit the
---window, but not over the bar, or above the popup), as stack level `level`,
---closing any deeper ones.
local function push(level, rows, x, y)
  for j = #stack, level, -1 do stack[j]:hide(); stack[j] = nil end
  local d = Dropdown()
  d:register(nil, rows)
  if not d:show(x, y) then return end
  local top = state.popup or (level == 1 and bar_bottom() or 0)
  d.position.y = math.max(top, math.min(y, core.root_view.size.y - d.items.height))
  d.height = d.items.height
  stack[level] = d
  return d
end

local function close_from(level)
  for j = #stack, level, -1 do stack[j]:hide(); stack[j] = nil end
end

---The y of row i of a dropdown.
local function row_y(d, i)
  for j, _, _, y in d:each_item() do
    if j == i then return y end
  end
  return d.position.y
end

---Opens the submenu of a dropdown's selected row, if it has one.
local function open_submenu(level)
  local d = stack[level]
  local item = d:get_item_selected()
  if not (item and item.rows) then return end
  if stack[level + 1] and stack[level + 1].parent_item == item then return stack[level + 1] end
  local sub = push(level + 1, item.rows, d.position.x + d.items.width, row_y(d, d.selected))
  if sub then sub.parent_item = item end
  return sub
end


---Shows the bar; from_keyboard underlines the menus' accelerators.
function menubar.show(from_keyboard)
  state.active, state.keyboard = true, from_keyboard
  state.hovered = from_keyboard and 1 or nil
  core.redraw = true
end

function menubar.hide()
  close_from(1)
  state.active, state.open, state.hovered, state.popup = false, nil, nil, nil
  core.redraw = true
end

-- after an error handling an event: closed without calling into the dropdowns
table.insert(core.popup_closers, function()
  for j = #stack, 1, -1 do stack[j] = nil end
  state.active, state.open, state.hovered, state.popup = false, nil, nil, nil
end)

---Drops the menus down from x, y (the top left), as one menu with a submenu
---each, rather than on the bar.
function menubar.popup(x, y)
  menubar.hide()
  local rows = {}
  for i, menu in ipairs(config.plugins.menubar.menus) do
    local sub = menu_rows(i)
    if sub then
      table.insert(rows, { text = menu.title, rows = sub, info = "  ", command = function() end })
    end
  end
  state.active, state.keyboard, state.popup = true, false, y
  if not push(1, rows, x, y) then menubar.hide() end
  core.redraw = true
end

---Whether the menus are shown, on the bar or as the popup.
function menubar.is_shown()
  return state.active
end

---Drops menu i down (closing any other).
function menubar.open(i)
  local menus = config.plugins.menubar.menus
  i = (i - 1) % #menus + 1
  state.hovered = i
  local rows = menu_rows(i)
  state.open = rows and push(1, rows, title_rects()[i].x, bar_bottom()) and i or nil
  core.redraw = true
end

local function close_menu()
  close_from(1)
  state.open = nil
end

---Performs the selected row of the deepest dropdown, or opens its submenu.
local function choose(level)
  local d = stack[level or #stack]
  local item = d and d:get_item_selected()
  -- a divider does nothing, as in core's context menu: the menu stays open
  if not item or item == ContextMenu.DIVIDER or item.disabled then return end
  if item.rows then
    local sub = open_submenu(level or #stack)
    if sub then sub:focus_step(1) end
    return
  end
  menubar.hide()
  item.command()
end

---The deepest open dropdown containing the point, and its level.
local function dropdown_at(x, y)
  for level = #stack, 1, -1 do
    local d = stack[level]
    local p = d.position
    if x >= p.x and x < p.x + d.items.width and y >= p.y and y < p.y + d.items.height then
      return d, level
    end
  end
end


function Dropdown:focus_step(dir)
  if dir > 0 then self:focus_next() else self:focus_previous() end
end

function Dropdown:draw_context_menu()
  if not self.items then return end
  local bx, by, bw, bh = self.position.x, self.position.y, self.items.width, self.height
  common.draw_popup_box(bx, by, bw, bh)
  for i, item, x, y, w, h in self:each_item() do
    if item == ContextMenu.DIVIDER then
      renderer.draw_rect(x, y + 5 * SCALE, w, 1, style.divider)
    else
      if i == self.selected and not item.disabled then
        renderer.draw_rect(x, y, w, h, style.selection)
      end
      local color = item.disabled and style.dim or style.text
      local cs = check_size()
      if item.checked then
        shapes.checkmark(x + style.padding.x / 2, y + (h - cs) / 2, cs, color)
      end
      common.draw_text(style.font, color, item.text, "left", x + style.padding.x + cs, y, w, h)
      if item.rows then
        common.draw_text(style.icon_font, color, "+", "right", x, y, w - style.padding.x, h)
      elseif item.info then
        local info_color = i == self.selected and style.text or style.dim
        common.draw_text(style.font, info_color, item.info, "right", x, y, w - style.padding.x, h)
      end
    end
  end
end


function BarView:draw()
  if not bar_shown() then return end
  local y, w, h = self.position.y, self.size.x, self.size.y
  renderer.draw_rect(0, y, w, h, style.background2)
  renderer.draw_rect(0, y + h - 1, w, 1, style.divider)
  local font = style.font
  for i, r in ipairs(title_rects()) do
    local title = config.plugins.menubar.menus[i].title
    local color = style.text
    if i == state.open or i == state.hovered then
      renderer.draw_rect(r.x, y, r.w, h - 1, i == state.open and style.popup_background or style.line_highlight)
      if i == state.open then color = style.accent end
    end
    local tx = r.x + style.padding.x
    local ty = y + (h - font:get_height()) / 2
    renderer.draw_text(font, title, tx, ty, color)
    if state.keyboard then
      local uw = font:get_width(title:sub(1, 1))
      renderer.draw_rect(tx, ty + font:get_height() - math.max(1, SCALE), uw, math.max(1, SCALE), color)
    end
  end
end


-- Events: while the bar is shown it gets the keyboard, and the mouse over it
-- or while a menu is down

local root_draw = RootView.draw
function RootView:draw(...)
  root_draw(self, ...)
  if not state.active then return end
  renderer.set_clip_rect(0, 0, self.size.x, self.size.y)
  for _, d in ipairs(stack) do d:draw_context_menu() end
end

local root_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  if state.active and (on_bar(y) or state.open or state.popup) then
    local i = title_at(x, y)
    if i and state.open and i ~= state.open then menubar.open(i) end
    state.hovered = i or state.open
    local d, level = dropdown_at(x, y)
    -- off the deepest dropdown, none of its rows is hovered (the shallower
    -- ones keep the row their open submenu belongs to)
    if stack[#stack] and stack[#stack] ~= d then stack[#stack].selected = -1 end
    if d then
      d:on_mouse_moved(x, y)
      local item = d:get_item_selected()
      if item and item.disabled then d.selected = -1 end
      -- hovering a row opens its submenu, or closes the one open
      if not open_submenu(level) and not (item == nil and stack[level + 1]) then
        close_from(level + 1)
      end
    end
    core.request_cursor("arrow")
    core.redraw = true
    return
  end
  if state.active then state.hovered = nil end
  return root_on_mouse_moved(self, x, y, dx, dy)
end

-- set by any key or click while Alt is down: its release then doesn't toggle
local alt_used = false

---A click while the menus are shown; true if it was theirs.
local function menu_click(x, y)
  local i = title_at(x, y)
  if i then
    if state.open == i then close_menu() else menubar.open(i) end
    return true
  elseif on_bar(y) then
    return true
  elseif state.open or state.popup then
    local d, level = dropdown_at(x, y)
    if d then
      d:on_mouse_moved(x, y)
      choose(level)
    else
      menubar.hide()
    end
    return true
  end
  menubar.hide()
end

-- set by a press the menus took: its release is theirs too, not the views'
-- (a widget's release takes focus from its input, as a chosen Find... gives it)
local press_taken = false

local root_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  alt_used = true
  press_taken = state.active and menu_click(x, y) or false
  if press_taken then return true end
  return root_on_mouse_pressed(self, button, x, y, clicks)
end

local root_on_mouse_released = RootView.on_mouse_released
function RootView:on_mouse_released(...)
  if press_taken then
    press_taken = false
    return true
  end
  return root_on_mouse_released(self, ...)
end

local root_on_mouse_wheel = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(...)
  alt_used = true
  if state.open or state.popup then return true end
  return root_on_mouse_wheel(self, ...)
end


local function is_alt(k) return k == "left alt" or k == "right alt" end

---Keys while the popup is shown; true if handled.
local function popup_key(k)
  local top = stack[#stack]
  local item = top and top:get_item_selected()
  if k == "escape" then
    if #stack > 1 then close_from(#stack) else menubar.hide() end
  elseif k == "left" then
    if #stack > 1 then close_from(#stack) end
  elseif k == "right" then
    if item and item.rows then choose() end
  elseif k == "return" or k == "keypad enter" then
    choose()
  elseif top and (k == "up" or k == "down") then
    top:focus_step(k == "up" and -1 or 1)
  elseif top and #k == 1 and k:match("%a") then
    -- the next row starting with the letter; a submenu opens
    local n = #top.items
    for step = 1, n do
      local i = (math.max(top.selected, 0) + step - 1) % n + 1
      local row = top.items[i]
      if row ~= ContextMenu.DIVIDER and not row.disabled and row.text:sub(1, 1):lower() == k then
        top.selected = i
        if row.rows then choose() end
        break
      end
    end
  else
    return false
  end
  core.redraw = true
  return true
end

---Keys while the bar is shown; true if handled.
local function bar_key(k)
  if state.popup then return popup_key(k) end
  local menus = config.plugins.menubar.menus
  local top = stack[#stack]
  if k == "escape" then
    if #stack > 1 then close_from(#stack)
    elseif state.open then close_menu()
    else menubar.hide() end
  elseif k == "left" and #stack > 1 then
    close_from(#stack)
  elseif k == "right" and top and top:get_item_selected() and top:get_item_selected().rows then
    choose()
  elseif k == "left" or k == "right" then
    local i = (state.open or state.hovered or 1) + (k == "left" and -1 or 1)
    if state.open then
      menubar.open(i)
      if stack[1] then stack[1]:focus_step(1) end
    else
      state.hovered = (i - 1) % #menus + 1
    end
  elseif top and (k == "up" or k == "down") then
    top:focus_step(k == "up" and -1 or 1)
  elseif top and (k == "return" or k == "keypad enter") then
    choose()
  elseif not top and (k == "down" or k == "return" or k == "keypad enter") then
    menubar.open(state.hovered or 1)
    if stack[1] then stack[1]:focus_step(1) end
  elseif #k == 1 and k:match("%a") then
    for i, menu in ipairs(menus) do
      if menu.title:sub(1, 1):lower() == k then
        menubar.open(i)
        if stack[1] then stack[1]:focus_step(1) end
        break
      end
    end
  else
    return false
  end
  core.redraw = true
  return true
end

local alt_down = false

local on_key_pressed = keymap.on_key_pressed
function keymap.on_key_pressed(k, ...)
  if is_alt(k) then
    -- a tap of Alt alone: not with another modifier held
    alt_down = true
    alt_used = keymap.modkeys["ctrl"] or keymap.modkeys["shift"] or keymap.modkeys["cmd"] or false
    return on_key_pressed(k, ...)
  end
  alt_used = true
  if state.active and not keymap.modkeys["ctrl"] and not keymap.modkeys["alt"] then
    if bar_key(k) then return true end
    -- any other key: keeps the bar if it's a modifier, else closes it and acts
    -- as usual
    if not ({ ["left shift"] = true, ["right shift"] = true, ["left ctrl"] = true,
              ["right ctrl"] = true })[k] then
      menubar.hide()
    end
  end
  return on_key_pressed(k, ...)
end

local on_key_released = keymap.on_key_released
function keymap.on_key_released(k, ...)
  on_key_released(k, ...)
  if is_alt(k) and alt_down then
    alt_down = false
    -- Alt+Tab: losing focus, SDL releases the keys held before telling us
    -- (focuslost, below), so this release comes first; but focus is gone
    if not alt_used and system.window_has_focus() then
      if state.active then menubar.hide() else menubar.show(true) end
    end
  end
end

-- Alt+Tab: the window loses focus with Alt down (where Alt's release comes
-- after). The bar and its menus close, as other menus do.
local root_on_focus_lost = RootView.on_focus_lost
function RootView:on_focus_lost(...)
  alt_used = true
  if state.active then menubar.hide() end
  return root_on_focus_lost(self, ...)
end

command.add(nil, {
  ["menubar:toggle"] = function()
    if state.active then menubar.hide() else menubar.show(true) end
  end,
})

menubar.stack = stack
menubar.state = state

return menubar
