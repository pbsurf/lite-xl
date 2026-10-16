-- mod-version:3
-- A menu bar of commands, shown at the top of the window (the rest moves down)
-- when Alt is tapped (pressed and released on its own). Its menus come from
-- config.plugins.menubar.menus; the end of the last one lists, by plugin, the
-- commands no menu has, leaving out those that only exist to be bound to keys.
--
-- While shown: a menu's first letter (underlined) or Down/Return opens it,
-- Left/Right move between menus, Up/Down/Return choose in one, Escape closes.
-- Rows whose command doesn't apply now are dimmed; commands of plugins that
-- aren't installed are left out.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"

---A menu row: a command name; a table with `command` (a name, or a list of
---names: the first that applies now, else the first that exists) and optional
---`text` (else the command's name, prettified, without its prefix); a submenu,
---{ text = ..., rows = { ... } }; or "-" for a divider.
---@alias plugins.menubar.row string | { command: string|string[], text?: string } | { text: string, rows: plugins.menubar.row[] }

---@class plugins.menubar.menu
---@field title string
---@field rows plugins.menubar.row[]

config.plugins.menubar = common.merge({
  ---@type plugins.menubar.menu[]
  menus = {
    { title = "File", rows = {
      { command = "core:new-doc", text = "New File" },
      { command = "core:new-named-doc", text = "New Named File..." },
      { command = "core:open-file", text = "Open File..." },
      "-",
      { command = "core:open-project-folder", text = "Open Project Folder..." },
      { command = "core:change-project-folder", text = "Change Project Folder..." },
      { command = "core:add-directory", text = "Add Directory to Project..." },
      { command = "core:remove-directory", text = "Remove Directory from Project..." },
      "-",
      { command = "doc:save", text = "Save" },
      { command = "doc:save-as", text = "Save As..." },
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
      { command = "build:toggle-drawer", text = "Build Output" },
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
      { command = "build:rebuild", text = "Rebuild" },
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
}, config.plugins.menubar)


local menubar = {}

-- active: the bar is shown; open: the index of the menu dropped down, if any;
-- hovered: the title under the mouse (or chosen from the keyboard); keyboard:
-- shown from the keyboard (accelerators underlined)
local state = { active = false, open = nil, hovered = nil, keyboard = false }

---A dropdown menu: rows dimmed when their command doesn't apply, and
---submenus (rows with `rows`), opened to the right
---@class plugins.menubar.dropdown : core.contextmenu
local Dropdown = ContextMenu:extend()

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

local function on_bar(py)
  return py >= 0 and py < bar_height()
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

---Commands no menu has, of prefixes not hidden, and not bound to a mouse
---action; sorted.
local function unplaced_commands()
  local placed = {}
  local function mark(rows)
    for _, spec in ipairs(rows) do
      if type(spec) == "table" and spec.rows then mark(spec.rows)
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
  local res = {}
  for name in pairs(command.map) do
    local b = keymap.get_binding(name) or ""
    if not placed[name] and not hidden[name:match("^[^:]+")] and not hidden_command(name)
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
      local sub = build_rows(spec.rows)
      if sub then
        -- info reserves room for the arrow
        table.insert(rows, { text = spec.text, rows = sub, info = "  ", command = function() end })
      end
    else
      local name = row_command(spec)
      if name then
        table.insert(rows, {
          text = type(spec) == "table" and spec.text or label(name),
          info = binding(name),
          disabled = not command.is_valid(name),
          command = function() command.perform(name) end,
        })
      end
    end
  end
  if rows[#rows] == ContextMenu.DIVIDER then table.remove(rows) end
  return #rows > 0 and rows or nil
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
---window), as stack level `level`, closing any deeper ones.
local function push(level, rows, x, y)
  for j = #stack, level, -1 do stack[j]:hide(); stack[j] = nil end
  local d = Dropdown()
  d:register(nil, rows)
  if not d:show(x, y) then return end
  d.position.y = math.max(level == 1 and bar_height() or 0,
    math.min(y, core.root_view.size.y - d.items.height))
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
  state.active, state.open, state.hovered = false, nil, nil
  core.redraw = true
end

---Drops menu i down (closing any other).
function menubar.open(i)
  local menus = config.plugins.menubar.menus
  i = (i - 1) % #menus + 1
  state.hovered = i
  local rows = menu_rows(i)
  state.open = rows and push(1, rows, title_rects()[i].x, bar_height()) and i or nil
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
  if not item or item.disabled then return end
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
  local n = #(self.items or {})
  if n == 0 then return end
  local i = self.selected
  for _ = 1, n do
    i = i == -1 and (dir > 0 and 1 or n) or (i - 1 + dir) % n + 1
    local item = self.items[i]
    if item ~= ContextMenu.DIVIDER and not item.disabled then
      self.selected = i
      return
    end
  end
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
      common.draw_text(style.font, color, item.text, "left", x + style.padding.x, y, w, h)
      if item.rows then
        common.draw_text(style.icon_font, color, "+", "right", x, y, w - style.padding.x, h)
      elseif item.info then
        local info_color = i == self.selected and style.text or style.dim
        common.draw_text(style.font, info_color, item.info, "right", x, y, w - style.padding.x, h)
      end
    end
  end
end


local function draw_bar()
  local w, h = core.root_view.size.x, bar_height()
  renderer.set_clip_rect(0, 0, w, core.root_view.size.y)
  renderer.draw_rect(0, 0, w, h, style.background2)
  renderer.draw_rect(0, h - 1, w, 1, style.divider)
  local font = style.font
  for i, r in ipairs(title_rects()) do
    local title = config.plugins.menubar.menus[i].title
    local color = style.text
    if i == state.open or i == state.hovered then
      renderer.draw_rect(r.x, 0, r.w, h - 1, i == state.open and style.popup_background or style.line_highlight)
      if i == state.open then color = style.accent end
    end
    local tx = r.x + style.padding.x
    local ty = (h - font:get_height()) / 2
    renderer.draw_text(font, title, tx, ty, color)
    if state.keyboard then
      local uw = font:get_width(title:sub(1, 1))
      renderer.draw_rect(tx, ty + font:get_height() - math.max(1, SCALE), uw, math.max(1, SCALE), color)
    end
  end
  for _, d in ipairs(stack) do d:draw_context_menu() end
end


-- Events: while the bar is shown it gets the keyboard, and the mouse over it
-- or while a menu is down

-- the views are laid out below the bar: the root view's rect is the window
-- without it while its nodes are laid out, and the whole window otherwise
local root_update = RootView.update
function RootView:update(...)
  if not state.active then return root_update(self, ...) end
  local h = bar_height()
  self.position.y, self.size.y = self.position.y + h, self.size.y - h
  root_update(self, ...)
  self.position.y, self.size.y = self.position.y - h, self.size.y + h
end

local root_draw = RootView.draw
function RootView:draw(...)
  root_draw(self, ...)
  if state.active then draw_bar() end
end

local root_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  if state.active and (on_bar(y) or state.open) then
    local i = title_at(x, y)
    if i and state.open and i ~= state.open then menubar.open(i) end
    state.hovered = i or state.open
    local d, level = dropdown_at(x, y)
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

local root_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  alt_used = true
  if state.active then
    local i = title_at(x, y)
    if i then
      if state.open == i then close_menu() else menubar.open(i) end
      return true
    elseif on_bar(y) then
      return true
    elseif state.open then
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
  return root_on_mouse_pressed(self, button, x, y, clicks)
end

local root_on_mouse_wheel = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(...)
  alt_used = true
  if state.open then return true end
  return root_on_mouse_wheel(self, ...)
end


local function is_alt(k) return k == "left alt" or k == "right alt" end

---Keys while the bar is shown; true if handled.
local function bar_key(k)
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
    if not alt_used then
      if state.active then menubar.hide() else menubar.show(true) end
    end
  end
end

-- Alt+Tab: the window loses focus with Alt down
local root_on_focus_lost = RootView.on_focus_lost
function RootView:on_focus_lost(...)
  alt_used = true
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
