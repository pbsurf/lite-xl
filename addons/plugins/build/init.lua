-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local common = require "core.common"
local style = require "core.style"
local DocView = require "core.docview"
local Doc = require "core.doc"
local StatusView = require "core.statusview"
local TreeView = config.plugins.treeview ~= false and require "plugins.treeview"
local ToolbarView = require "plugins.toolbarview"
local ContextMenu = require "core.contextmenu"
local TerminalView = require("plugins.terminal").class
local search = require "plugins.terminal.search"


local storage 
if rawget(_G, "MOD_VERSION_MAJOR") == 4 then
  storage = require "core.storage"
else
  storage = {}
  function storage.load(module, key)
    local f = io.open(USERDIR .. PATHSEP .. module .. "-" .. key .. ".state", "rb")
    return f and load("return " .. f:read("*all"))()
  end
  function storage.save(module, key, value)
    io.open(USERDIR .. PATHSEP .. module .. "-".. key .. ".state", "wb"):write(common.serialize(value)):close()
  end
  if not core.root_project then
    local root_project = {
      absolute_path = function(self, path)
        return core.project_absolute_path(path)
      end,
      normalize_path = function(self, path)
        return common.normalize_path(path)
      end,
      get_file_info = function(self, path)
        return system.get_file_info(path)
      end
    }
    function core.root_project()
      -- the project may have changed
      root_project.path = core.project_dir
      return root_project
    end
  end
end

local build = common.merge({
  targets = { },
  -- Config variables
  threads = 8,
  cc = os.getenv("CC") or "gcc",
  cxx = os.getenv("CXX") or "g++",
  ar = os.getenv("AR") or "ar",
  cflags = os.getenv("CFLAGS") or {},
  cxxflags = os.getenv("CXXFLAGS") or {},
  ldflags = os.getenv("LDFLAGS") or {},
  error_color = style.error,
  warning_color = style.warn,
  good_color = style.good,
  -- the height of the drawer with the build's terminal
  drawer_size = 250 * SCALE,
  max_previous_arguments = 100,
  -- after a successful build or clean: "keep" the drawer open, or "close" it
  on_success = "keep",
  -- show the build toolbar, under the file browser
  toolbar = true,
}, config.plugins.build)

function build.argument_string_to_table(str)
  if not str then return nil end
  local s = str:find("%S")
  if not s then return nil end
  local t = {}
  local quote_open = nil
  while true do
    if quote_open then
      local a = str:find(quote_open, s)
      if not a then error("can't find closing quote in " .. str .. " from " .. s) end
      table.insert(t, str:sub(s, a-1))
      s = a + 1
      quote_open = nil
    else
      local e = str:find("[\"' ]", s)
      if not e then break end
      local sample = str:sub(e, e)
      if sample == '"' or sample == "'" then
        if s < e then table.insert(t, str:sub(s, e - 1)) end
        s = e + 1
        quote_open = sample
      else
        local ne = select(2, str:find("^%s*", e))
        if e > s then table.insert(t, str:sub(s,e - 1)) end
        s = ne + 1
      end
    end
  end
  if s < #str then table.insert(t, str:sub(s)) end
  return t
end

local function get_plugin_directory()
  local paths = {
    USERDIR .. PATHSEP .. "plugins" .. PATHSEP .. "build",
    DATADIR .. PATHSEP .. "plugins" .. PATHSEP .. "build"
  }
  for i, v in ipairs(paths) do if system.get_file_info(v) then return v end end
  return nil
end

function build.get_backends(specific)
  local backends = {}
  for _, backend in ipairs(system.list_dir(get_plugin_directory() .. PATHSEP .. "backends")) do
    if backend:find("%.lua$") then
      local module = require("plugins.build.backends." .. backend:gsub("%.lua", ""))
      table.insert(backends, module)
      backends[#backends].id = backend:gsub("%.lua", "")
    end
  end
  if specific then
    for i,backend in ipairs(backends) do
      if backend.id == specific then return backend end
    end
    error("can't find backend " .. specific)
  end
  return backends
end

local function split(splitter, str)
  local o = 1
  local res = {}
  while true do
      local s, e = str:find(splitter, o)
      table.insert(res, str:sub(o, s and (s - 1) or #str))
      if not s then break end
      o = e + 1
  end
  return res
end


build.state = storage.load("build", "state") or { previous_arguments = {}, target = 1 }
local function save_state()
  storage.save("build", "state", build.state)
end


---Opens a file at a line (and column), as a preview.
local function jump_to_file(file, line, col)
  local view = core.root_view:open_doc(core.open_doc(file), { preview = true })
  if line then
    view.doc:set_selection(line, col or 1)
    view:scroll_to_line(line, true, true)
  end
  return view
end


---A compiler's message in a line of output, in gcc's and clang's format:
---`file:line:[column:] [type:] message`; nil if it isn't one. The type is
---"error" (a fatal error too), "warning" or "info" (a note, or a location with
---no type, as in "In file included from"). The file isn't checked here.
---@param line string
---@return { type: string, file: string, line: integer, col: integer, message: string }?
function build.parse_compile_line(line)
  local text = line:gsub("^In file included from ", "")
  local file, line_number, column, rest = text:match("^%s*([^:%s][^:]*):(%d+):(%d*):? ?(.*)")
  if not file then return nil end
  local kind, message = rest:match("^(%a[%a ]*):%s+(.*)")
  if kind == "error" or kind == "fatal error" then
    kind = "error"
  elseif kind ~= "warning" then
    kind, message = "info", rest
  end
  return {
    type = kind, file = file, line = tonumber(line_number),
    col = tonumber(column) or 1, message = message
  }
end


local function shell_quote(s)
  if s:match("^[%w%-%._/=:,@+]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---A command as it would be typed in a shell.
function build.command_line(cmd)
  local words = {}
  for _, arg in ipairs(cmd) do table.insert(words, shell_quote(tostring(arg))) end
  return table.concat(words, " ")
end


---A color as the escape sequence that sets it as the text's (24-bit).
local function sgr_color(color)
  return string.format("\x1b[38;2;%d;%d;%dm", color[1], color[2], color[3])
end


---Runs a command in the build terminal (build.view): a list, the program then
---its arguments, with optional `cwd` (default: the project's directory) and
---`env` (variables added). Calls `on_done` with its exit status (128 + the
---signal if one killed it, -1 if it couldn't start), from a thread. One at a
---time: a backend chains its commands from `on_done`.
---@param cmd table
---@param on_done? fun(status: integer)
function build.run_command(cmd, on_done)
  -- not after the build was terminated (its backend may be busy until then)
  if not build.current then error("the build has ended", 0) end
  build.view:run(cmd, function(status)
    -- terminated: the build ends with this command
    if build.current and build.current.cancelled then
      build.current.finish(status)
    elseif on_done then
      local ok, err = pcall(on_done, status)
      if not ok then build.fail(err) end
    end
  end)
end

---Ends the build (or clean or run) under way with an error: in red in the
---terminal, then its footer.
function build.fail(err)
  core.log_quiet("build: %s", err)
  if build.view.terminal then
    build.view:write(sgr_color(build.error_color) .. tostring(err):gsub("\n", "\r\n") .. "\x1b[0m\r\n")
  end
  if build.current then build.current.finish(-1) end
end

---The build, clean or run under way, from its start until its last command
---exits: { kind, target, started, finish(status) }.
build.current = nil
---The last build or clean that ended: { kind, target, status, errors, warnings, time }.
build.last = nil

function build.is_running() return build.current ~= nil end
function build.output(line) core.log_quiet(line) end

---Starts a build, clean or run (`kind`: "Build", "Clean", "Run") of a target:
---the drawer opens, and `start(finish)` is run in a thread; `finish(status)`
---(or build.fail) ends it, writing a footer, then calls `callback(status)`.
local function begin(kind, target, start, callback)
  local name = target.name or "target"
  local first_message = #build.view.messages + 1
  local current = { kind = kind, target = target, started = system.get_time() }
  build.current = current
  build.view.visible = true
  build.view.first_message = first_message
  build.view:begin()
  function current.finish(status)
    if build.current ~= current then return end
    build.current = nil
    local errors, warnings = 0, 0
    for i = first_message, #build.view.messages do
      local type = build.view.messages[i].type
      if type == "error" then errors = errors + 1 elseif type == "warning" then warnings = warnings + 1 end
    end
    local time = system.get_time() - current.started
    if kind ~= "Run" then
      build.last = { kind = kind, target = target, status = status, errors = errors, warnings = warnings, time = time }
    end
    local counts = {}
    if errors > 0 then table.insert(counts, errors .. (errors == 1 and " error" or " errors")) end
    if warnings > 0 then table.insert(counts, warnings .. (warnings == 1 and " warning" or " warnings")) end
    local result
    if current.cancelled then
      result = "terminated"
    elseif kind == "Run" then
      result = "exited with " .. status
    elseif status == 0 then
      result = "done"
    else
      result = status == -1 and "failed" or "failed with exit status " .. status
    end
    local summary = string.format("%s %s: %s%s, %.1f s", kind, name, result,
      #counts > 0 and ", " .. table.concat(counts, ", ") or "", time)
    build.view:write(sgr_color(status == 0 and style.dim or build.error_color) .. "── " .. summary .. "\x1b[0m\r\n")
    build.output(summary)
    if status == 0 and kind ~= "Run" and build.on_success == "close" then build.view.visible = false end
    if callback then callback(status) end
  end
  core.add_thread(function()
    local ok, err = pcall(start, current.finish)
    if not ok then build.fail(err) end
  end)
end

function build.set_target(target)
  if not build.targets or #build.targets == 0 then
    core.log_quiet("No build targets available")
    return
  end
  if not target then
    core.log_quiet("No target given")
    return
  end

  target = common.clamp(target, 1, #build.targets)
  local t = build.targets[target]
  config.target_binary = t.binary
  -- for the debugger: where and how to run the binary
  config.target_workdir = t.wd
  config.target_environment = t.env
  config.target_debugger_commands = t.debugger_commands
  -- the arguments last used with the target, else its own (binary_arguments)
  local arguments
  for i = #build.state.previous_arguments, 1, -1 do
    local v = build.state.previous_arguments[i]
    if v[1] == target then
      arguments = v[2] or ""
      break
    end
  end
  config.target_binary_arguments = arguments and build.argument_string_to_table(arguments) or t.binary_arguments
  build.state.target = target
  save_state()
end

function build.set_targets(targets, type)
  build.targets = targets
  for i,v in ipairs(targets) do
    if v.type or type then
      v.backend = build.get_backends(v.type or type)
    end
  end
  config.target_binary = build.targets and #build.targets > 0 and build.targets[1].binary
end

function build.can_build(target)
  return target ~= nil and target.build ~= false and (target.build or (target.backend.build and (not target.backend.can_build or target.backend.can_build(target))))
end

function build.build(callback)
  local target = build.targets[build.state.target]
  if build.is_running() or not build.can_build(target) then return false end
  begin("Build", target, function(finish)
    target.backend.build(target, finish)
  end, callback)
end

function build.escape_arguments(arguments)
  if type(arguments) == "table" then
    local new_arguments = {}
    for i,arg in ipairs(arguments) do
      if not arg:find("[ \"']") then
        table.insert(new_arguments, arg)
      elseif not arg:find("[']") then
        table.insert(new_arguments, "'" .. arg .. "'")
      elseif not arg:find("[\"]") then
        table.insert(new_arguments, "\"" .. arg .. "\"")
      else
        table.insert(new_arguments, "'" .. arg:gsub("'", "'\"'\"'"):gsub("\\", "\\\\") .. "'")
      end
    end
    return new_arguments
  end
  return arguments
end

---The command to run a program for the current target, in its `wd` with
---its `env`: `program` (relative to the project) with `arguments` (default
---config.target_binary_arguments; a string is a shell's command line). With
---`shell_line`, `program` is a command line for the shell instead.
function build.get_run_command(target, program, arguments, shell_line)
  target = target or build.targets[build.state.target]
  local cmd
  if shell_line then
    cmd = { os.getenv("SHELL") or "sh", "-c", program }
  else
    program = core.root_project():absolute_path(program)
    arguments = arguments or config.target_binary_arguments or {}
    if type(arguments) == "string" then
      cmd = { os.getenv("SHELL") or "sh", "-c", shell_quote(program) .. " " .. arguments }
    else
      cmd = { program, table.unpack(arguments) }
    end
  end
  cmd.cwd = target.wd and core.root_project():absolute_path(target.wd)
  cmd.env = target.env
  return cmd
end

---Whether the target can run: its `run`, its backend's, or else the binary.
function build.can_run(target)
  if target == nil or target.run == false then return false end
  if target.run then return true end
  if target.backend.run then return not target.backend.can_run or target.backend.can_run(target) end
  return config.target_binary ~= nil
end

---Runs the target's program in the build terminal, which takes the keyboard.
---A backend's `run(target, arguments)` returns the command, else it's the
---target's `run` (a function returning it, or a program), or its binary.
function build.run(arguments)
  local target = build.targets[build.state.target]
  if build.is_running() or not build.can_run(target) then return false end
  begin("Run", target, function(finish)
    local cmd
    if target.backend.run then
      cmd = target.backend.run(target, arguments)
    elseif type(target.run) == "function" then
      cmd = target.run(target, arguments)
    else
      cmd = build.get_run_command(target, target.run or config.target_binary, arguments)
    end
    core.set_active_view(build.view)
    build.run_command(cmd, finish)
  end)
end

function build.can_clean(target)
    return target ~= nil and target.clean ~= false and (target.clean or (target.backend.clean and (not target.backend.can_clean or target.backend.can_clean(target))))
end

function build.clean(callback)
  local target = build.targets[build.state.target]
  if build.is_running() or not build.can_clean(target) then return false end
  begin("Clean", target, function(finish)
    target.backend.clean(target, function(status) finish(status or 0) end)
  end, callback)
end

---Stops the build, clean or run under way: its command gets SIGTERM (or
---`signal`), and no other is started; it ends when the command exits.
function build.terminate(callback, signal)
  if not build.is_running() then return false end
  if build.view.job then
    build.current.cancelled = true
    build.view:kill(signal)
  else
    build.fail("Terminated.")
  end
  if callback then callback() end
end

---As build.terminate, with SIGKILL.
function build.kill(callback)
  return build.terminate(callback, 9)
end


------------------ UI Elements
---The binary's arguments as typed, "" if none.
local function get_arguments_text()
  local arguments = config.target_binary_arguments
  return arguments and table.concat(build.escape_arguments(arguments), " ") or ""
end

---Records the arguments last used with the current target, for the menu.
local function remember_arguments(text)
  local previous = build.state.previous_arguments
  for i = #previous, 1, -1 do
    if previous[i][1] == build.state.target and previous[i][2] == text then table.remove(previous, i) end
  end
  table.insert(previous, { build.state.target, text })
  if #previous > build.max_previous_arguments then table.remove(previous, 1) end
  save_state()
end

---The binary's path as shown: relative to the project if in it, else with ~.
local function get_binary_text()
  local path = core.root_project():absolute_path(config.target_binary)
  local root = core.root_project().path
  return common.path_belongs_to(path, root) and common.relative_path(root, path) or common.home_encode(path)
end

local function edit_binary()
  local arguments = get_arguments_text()
  core.command_view:enter("Set Target Binary", {
    text = get_binary_text() .. (arguments ~= "" and " " .. arguments or ""),
    submit = function(text)
      local i = text:find(" ")
      -- relative to the project, as shown
      config.target_binary = core.root_project():absolute_path(common.home_expand(i and text:sub(1, i-1) or text))
      if i then
        config.target_binary_arguments = build.argument_string_to_table(text:sub(i+1))
      else
        config.target_binary_arguments = nil
      end
      remember_arguments(i and text:sub(i+1))
    end
  })
end

---The actions at the end of the target menu; plugins may add to them. A row
---is shown if its command is valid and its `when`, if any, returns true.
build.menu_actions = {
  { text = "Build", command = "build:build" },
  { text = "Clean", command = "build:clean" },
  { text = "Run", command = "build:run-or-term-or-kill", when = function() return not build.is_running() end },
  { text = "Stop", command = "build:terminate" },
  { text = "Next Error", command = "build:next-error" },
  { text = "Previous Error", command = "build:previous-error" },
  { text = "Show Build Output", command = "build:toggle-drawer", when = function() return not build.view.visible end },
  { text = "Hide Build Output", command = "build:toggle-drawer", when = function() return build.view.visible end },
}

---The target menu's rows: targets, binary and recent arguments, actions.
local function get_menu()
  local rows = {}
  local function add_group(group)
    if #group == 0 then return end
    if #rows > 0 then table.insert(rows, ContextMenu.DIVIDER) end
    for _, row in ipairs(group) do table.insert(rows, row) end
  end

  local targets = {}
  for i, target in ipairs(build.targets) do
    table.insert(targets, {
      text = target.name or "default",
      info = target.info or target.backend and target.backend.id or "",
      active = i == build.state.target,
      command = function() build.set_target(i) end,
    })
  end
  add_group(targets)

  local binary = {}
  if config.target_binary then
    local arguments = get_arguments_text()
    table.insert(binary, { text = "Binary: " .. get_binary_text(), command = edit_binary })
    -- the arguments used recently with this target, newest first
    local seen = { [arguments] = true }
    local previous = build.state.previous_arguments
    for i = #previous, 1, -1 do
      local text = previous[i][2]
      if previous[i][1] == build.state.target and text and not seen[text] and #binary < 6 then
        seen[text] = true
        table.insert(binary, {
          text = "Arguments: " .. text,
          command = function()
            config.target_binary_arguments = build.argument_string_to_table(text)
            remember_arguments(text)
          end,
        })
      end
    end
    if arguments ~= "" then
      table.insert(binary, 2, { text = "Arguments: " .. arguments, info = "", active = true, command = edit_binary })
    end
  end
  add_group(binary)

  local actions = {}
  for _, row in ipairs(build.menu_actions) do
    if command.is_valid(row.command) and (not row.when or row.when()) then
      table.insert(actions, { text = row.text, command = row.command })
    end
  end
  add_group(actions)
  return rows
end

-- the toolbar's Next Target icon (a bullseye), at the size of the status bar's icons
local status_icon_font = renderer.font.load(get_plugin_directory() .. PATHSEP .. "build.ttf", style.icon_font:get_size())

core.status_view:add_item({
  predicate = function() return build.state.target and build.targets[build.state.target] and build.targets[build.state.target].backend end,
  name = "build:target",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local target = build.targets[build.state.target]
    if status_icon_font:get_size() ~= style.icon_font:get_size() then
      status_icon_font:set_size(style.icon_font:get_size())
    end
    local item = {
      style.text, status_icon_font, "&", style.font, " ",
      (target.name or "default") .. (get_arguments_text() ~= "" and "*" or "")
    }
    -- what's under way, or how the last build ended: its counts, else its status
    local function add(color, text) table.insert(item, color) table.insert(item, "  " .. text) end
    local last = build.last
    if build.current then
      add(style.dim, ({ Build = "building…", Clean = "cleaning…", Run = "running…" })[build.current.kind])
    elseif last and (last.errors > 0 or last.warnings > 0) then
      if last.errors > 0 then add(build.error_color, last.errors .. (last.errors == 1 and " error" or " errors")) end
      if last.warnings > 0 then add(build.warning_color, last.warnings .. (last.warnings == 1 and " warning" or " warnings")) end
    elseif last and last.status ~= 0 then
      add(build.error_color, last.kind:lower() .. " failed")
    end
    return item
  end,
  tooltip = function()
    local target = build.targets[build.state.target]
    local text = string.format("Target: %s (%s)", target.name or "default", target.info or target.backend.id)
    if config.target_binary then
      local arguments = get_arguments_text()
      text = text .. ", binary: " .. get_binary_text() .. (arguments ~= "" and " " .. arguments or "")
    end
    local last = build.last
    if last and not build.current then
      text = text .. string.format("; last %s: %s", last.kind:lower(),
        last.status == 0 and "done" or last.status == -1 and "failed" or "exit status " .. last.status)
    end
    return text
  end,
  menu = get_menu,
})

local type_colors = {
  error = function() return build.error_color end,
  warning = function() return build.warning_color end,
  info = function() return style.accent end,
}

-- the message gone to (next/previous error, or clicked) marks its line's gutter
local doc_view_draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(idx, x, y, width)
  local message = build.view and build.view.active_message
  if message and idx == message.line and self.doc.abs_filename == message.file then
    renderer.draw_rect(x, y, style.padding.x, self:get_line_height(), type_colors[message.type]())
  end
  return doc_view_draw_line_gutter(self, idx, x, y, width)
end


---The build's terminal, in a drawer: each command of a build runs in it, on
---a pty of its own, after the output of those before. Compilers' messages in
---it are found as lines complete (build.parse_compile_line, or the backend's),
---and can be clicked to go to their file.
local BuildView = TerminalView:extend()
BuildView.close_on_exit = false

function BuildView:new()
  BuildView.super.new(self, { shell = "DUMMY" })
  self.size.y = 0
  self.target_size = build.drawer_size
  self.visible = false
  -- messages found, in order: { type, file (absolute), line, col, message,
  -- first, last }, first and last naming its rows as row + terminal:scrolled()
  self.messages = {}
  -- the first message of the last build
  self.first_message = 1
  self.hovered_message = nil
  self.active_message = nil
  -- the command running: { cmd, cwd, dirs (make's directories), parsed (the
  -- first row not parsed yet, as an id), source (the pty's watch source) }
  self.job = nil
end

function BuildView:get_name() return "Build" end

function BuildView:update()
  -- no animation: a terminal resized a little at a time pushes its lines into
  -- the scrollback (and hidden, at 0, it keeps its size)
  self.size.y = self.visible and self.target_size or 0
  BuildView.super.update(self)
  if self.hovered_message and self.terminal and not self.terminal:mouse_tracking_mode() then self.cursor = "hand" end
end

function BuildView:set_target_size(axis, value)
  if axis == "y" then
    self.target_size = value
    return true
  end
end

function BuildView:accepts_input()
  return self.job ~= nil
end

function BuildView:input(text)
  if self.job then return BuildView.super.input(self, text) end
  return false
end

-- no cursor without a program to type to
function BuildView:get_cursor()
  local x, y, mode = self.terminal:cursor()
  return x, y, self.job and mode or "hidden"
end

function BuildView:clear()
  self.terminal:clear()
  self.messages, self.first_message = {}, 1
  self.hovered_message, self.active_message = nil, nil
end

---The terminal, made now if the drawer hasn't been shown yet.
function BuildView:get_terminal()
  if not self.terminal then
    self.size.y = self.target_size
    if self.size.x <= 0 then self.size.x = core.root_view.size.x end
    BuildView.super.update(self)
  end
  return self.terminal
end

---Writes text as if a program had (escape sequences included).
function BuildView:write(text)
  local shifts = self:get_terminal():output(text)
  self:on_output(shifts)
  core.redraw = true
end

---Starts a new build's output on a line of its own.
function BuildView:begin()
  local terminal = self:get_terminal()
  self.terminal:scrollback(0)
  local x = terminal:cursor()
  if x > 0 then self:write("\r\n") end
end

function BuildView:on_output(shifts)
  BuildView.super.on_output(self, shifts)
  if self.job then self:parse_output(false) end
end

---Runs a command (see build.run_command), then `on_done(status)`.
function BuildView:run(cmd, on_done)
  local terminal = self:get_terminal()
  local cwd = common.normalize_path(cmd.cwd or core.root_project().path)
  local env = {}
  for name, value in pairs(self.options.environment) do env[name] = value end
  for name, value in pairs(cmd.env or {}) do env[name] = value end
  -- where libterminal starts it
  env.PWD = cwd
  -- the program relative to the directory, if in it
  local shown = { table.unpack(cmd) }
  if common.is_absolute_path(shown[1]) and common.path_belongs_to(shown[1], cwd) then
    shown[1] = "." .. PATHSEP .. common.relative_path(cwd, shown[1])
  end
  local line = build.command_line(shown)
  local root = common.normalize_path(core.root_project().path)
  if cwd ~= root then
    line = "(in " .. (common.path_belongs_to(cwd, root) and common.relative_path(root, cwd) or common.home_encode(cwd)) .. ") " .. line
  end
  self:write(sgr_color(style.dim) .. "$ " .. line .. "\x1b[0m\r\n")
  local args = {}
  for i = 2, #cmd do args[i - 1] = tostring(cmd[i]) end
  local ok, err = pcall(terminal.spawn, terminal, self.options.term, cmd[1], args, env)
  if not ok then
    self:write(sgr_color(build.error_color) .. err .. "\x1b[0m\r\n")
    on_done(-1)
    return
  end
  local job = { cmd = cmd, cwd = cwd, dirs = {}, parsed = terminal:scrolled() + select(2, terminal:cursor()), source = terminal:watch_source() }
  self.job = job
  core.add_thread(function()
    while true do
      local read = self:shift_selection_update()
      if read then core.redraw = true end
      local source = terminal:watch_source()
      -- done once the output has ended, or the program exited and there's no more
      -- (a program it started in the background can keep the pty open)
      if not source or (not read and terminal:exited()) then break end
      if read then
        coroutine.yield(1 / config.fps)
      else
        -- woken by output; and now and then, to notice an exit without any
        core.wait_for(core.watch_readable(source), 1)
      end
    end
    while terminal:exited() == false do coroutine.yield(0.01) end
    if job.source then core.unwatch_readable(job.source) end
    self:parse_output(true)
    self.job = nil
    local code, signal = terminal:exited()
    core.redraw = true
    on_done(code == -1 and signal and signal > 0 and 128 + signal or code)
  end)
end

---Signals the command running (default SIGTERM).
function BuildView:kill(signal)
  if self.job then self.terminal:kill(signal) end
end

---Parses the lines the command has written since last time, but for the one
---the cursor is on (it may not be complete yet) unless `final`.
function BuildView:parse_output(final)
  local job, terminal = self.job, self.terminal
  if not job then return end
  local scrolled = terminal:scrolled()
  local _, total = terminal:scrollback()
  local _, cursor_y = terminal:cursor()
  local first = math.max(job.parsed - scrolled, -total)
  if cursor_y < first then return end
  local doc = search.snapshot(self, first, cursor_y)
  for i, text in ipairs(doc.lines) do
    local segments = doc.segments[i]
    if i == #doc.lines and not final then break end
    -- without the newline, and the blank cells at the end
    self:parse_line(text:gsub("%s+$", ""), segments[1].row + scrolled, segments[#segments].row + scrolled)
    job.parsed = segments[#segments].row + scrolled + 1
  end
end

function BuildView:parse_line(text, first, last)
  local job = self.job
  -- make's and ninja's directories, which the paths after are relative to
  local dir = text:match("Entering directory [`'\"](.*)['\"]%s*$")
  if dir then
    table.insert(job.dirs, common.normalize_path(common.is_absolute_path(dir) and dir or (job.dirs[#job.dirs] or job.cwd) .. PATHSEP .. dir))
    return
  end
  if text:find("Leaving directory [`'\"]") then
    table.remove(job.dirs)
    return
  end
  local backend = build.current and build.current.target.backend
  local message = (backend and backend.parse_compile_line or build.parse_compile_line)(text)
  if not message then return end
  local file = message.file
  if not common.is_absolute_path(file) then
    file = (job.dirs[#job.dirs] or job.cwd) .. PATHSEP .. file
  end
  file = common.normalize_path(file)
  local info = system.get_file_info(file)
  if not info or info.type ~= "file" then return end
  message.file, message.first, message.last = file, first, last
  table.insert(self.messages, message)
end

---The message on a row of the screen (0 is its top), if any.
function BuildView:get_message_at(row)
  if not self.terminal then return nil end
  local id = row - self.terminal:scrollback() + self.terminal:scrolled()
  -- messages are in order: a binary search for the last that starts at or above it
  local lo, hi = 1, #self.messages
  while lo <= hi do
    local mid = (lo + hi) // 2
    if self.messages[mid].first <= id then lo = mid + 1 else hi = mid - 1 end
  end
  local message = self.messages[hi]
  return message and id <= message.last and message or nil
end

---The y of a message's first row on screen, and its height.
function BuildView:get_message_rect(message)
  local _, padding_y = self:get_padding()
  local lh = self:get_line_height()
  local row = message.first - self.terminal:scrolled() + self.terminal:scrollback()
  return self.position.y + padding_y + row * lh, (message.last - message.first + 1) * lh
end

function BuildView:draw_background(color)
  BuildView.super.draw_background(self, color)
  if not self.terminal then return end
  for _, message in pairs({ hovered = self.hovered_message, active = self.active_message }) do
    local y, h = self:get_message_rect(message)
    if y + h > self.position.y and y < self.position.y + self.size.y then
      renderer.draw_rect(self.position.x, y, self.size.x, h, style.line_highlight)
      if message == self.active_message then
        renderer.draw_rect(self.position.x, y, math.ceil(2 * SCALE), h, type_colors[message.type]())
      end
    end
  end
end

function BuildView:on_mouse_moved(x, y, ...)
  local result = BuildView.super.on_mouse_moved(self, x, y, ...)
  local hovered = nil
  if not self.v_scrollbar.dragging and x >= self.position.x and x < self.position.x + self.size.x
    and y >= self.position.y and y < self.position.y + self.size.y then
    local _, row = self:convert_coordinates(x, y)
    hovered = self:get_message_at(row)
  end
  if hovered ~= self.hovered_message then
    self.hovered_message = hovered
    core.redraw = true
  end
  return result
end

function BuildView:on_mouse_left()
  BuildView.super.on_mouse_left(self)
  self.hovered_message = nil
end

function BuildView:on_mouse_pressed(button, x, y, clicks)
  self.pressed_message = button == "left" and clicks == 1 and self.hovered_message or nil
  return BuildView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function BuildView:on_mouse_released(button, x, y)
  BuildView.super.on_mouse_released(self, button, x, y)
  local s = self.selection
  -- a click, not a drag selecting text
  if button == "left" and self.pressed_message and self.pressed_message == self.hovered_message
    and (not s or (s[1] == s[3] and s[2] == s[4])) then
    self.selection = nil
    build.go_to_message(self.pressed_message)
  end
  self.pressed_message = nil
end

---Opens a message's file at its line, marking it in the terminal and the gutter.
function build.go_to_message(message)
  build.view.active_message = message
  -- scrolled into view if it isn't
  local view = build.view
  if view.terminal then
    local y, h = view:get_message_rect(message)
    if y < view.position.y or y + h > view.position.y + view.size.y then
      local scrollback, total = view.terminal:scrollback()
      local row = message.first - view.terminal:scrolled()
      view.terminal:scrollback(common.clamp(math.floor(view.lines / 3) - row, 0, total))
    end
  end
  jump_to_file(message.file, message.line, message.col)
  core.redraw = true
end

---The last build's errors and warnings, in order.
function build.get_errors()
  local errors = {}
  for i = build.view.first_message, #build.view.messages do
    local message = build.view.messages[i]
    if message.type ~= "info" then table.insert(errors, message) end
  end
  return errors
end

---Goes to the last build's next error or warning (previous if `step` is -1).
function build.next_error(step)
  step = step or 1
  local errors = build.get_errors()
  if #errors == 0 then return end
  local index = nil
  for i, message in ipairs(errors) do
    if message == build.view.active_message then index = i end
  end
  if not index then
    -- from the active message (an info one, or an earlier build's) onward
    local active = build.view.active_message
    index = step > 0 and 0 or #errors + 1
    if active then
      for i, message in ipairs(errors) do
        if step > 0 and message.first < active.first then index = i end
        if step < 0 and message.first > active.first and index > i then index = i end
      end
    end
  end
  index = index + step
  if index < 1 or index > #errors then
    core.log("No %s errors or warnings", step > 0 and "more" or "earlier")
    return
  end
  build.go_to_message(errors[index])
end


local BuildBarView = ToolbarView:extend()

function BuildBarView:new()
  BuildBarView.super.new(self)
  self.toolbar_font = renderer.font.load(get_plugin_directory() .. PATHSEP .. "build.ttf", style.icon_big_font:get_size())
  self.toolbar_commands = {
    {symbol = "!", command = "build:build"},
    {symbol = '"', command = "build:run-or-term-or-kill"},
    {symbol = "#", command = "build:clean-and-build"},
    {symbol = "$", command = "build:terminate"},
    {symbol = "&", command = "build:next-target"},
    {symbol = "%", command = "build:toggle-drawer"},
  }
end

build.build_bar_view = BuildBarView()
build.view = BuildView()
local node = core.root_view:get_active_node()
build.view_node = node:split("down", build.view, { y = true }, true)
-- above the file browser's toolbar, if it has one (toolbarview isn't disabled)
if TreeView and build.toolbar then
  build.build_bar_node = TreeView.node.b and TreeView.node.b:split("up", build.build_bar_view, {y = true})
    or TreeView.node:split("down", build.build_bar_view, {y = true})
end


command.add(function()
  return #build.get_errors() > 0
end, {
  ["build:next-error"] = function() build.next_error(1) end,
  ["build:previous-error"] = function() build.next_error(-1) end,
})

local tried_term = false

-- builds compile what's on disk, so save the files being edited first
local function save_docs()
  for i,v in ipairs(core.docs) do
    if v:is_dirty() and v.filename and v.abs_filename then
      v:save()
    end
  end
end

command.add(function(root_view, arguments)
  return not build.is_running() and build.can_build(build.targets[build.state.target]), arguments
end, {
  ["build:build"] = function()
    save_docs()
    if #build.targets > 0 then
      build.build()
    end
  end
})

command.add(function(root_view, arguments)
  return not build.is_running() and build.can_build(build.targets[build.state.target]) and build.can_run(build.targets[build.state.target]), arguments
end, {
  ["build:build-and-run"] = function(arguments)
    save_docs()
    if #build.targets > 0 then
      build.build(function(status)
        if status == 0 then
          build.run(arguments)
        end
      end)
    end
  end,
})

command.add(function(root_view, arguments)
  return not build.is_running() and build.can_build(build.targets[build.state.target]) and build.can_clean(build.targets[build.state.target]), arguments
end, {
  ["build:clean-and-build"] = function()
    save_docs()
    build.clean(function(status)
      if (status or 0) == 0 and #build.targets > 0 then
        build.build()
      end
    end)
  end
})


command.add(function(root_view, arguments)
  return not build.is_running() and build.can_clean(build.targets[build.state.target]), arguments
end, {
  ["build:clean"] = function()
    build.clean()
  end
})

command.add(function(root_view, arguments)
  return build.state.target
end, {
  ["build:next-target"] = function()
    if #build.targets > 0 then
      build.set_target((build.state.target % #build.targets) + 1)
    end
  end
})

command.add(function()
  return build.is_running()
end, {
  ["build:terminate"] = function()
    build.terminate()
  end
})

command.add(function(root_view, options)
  return (config.target_binary and system.get_file_info(core.root_project():absolute_path(config.target_binary))) or build.can_run(build.targets[build.state.target]), options
end, {
  ["build:run-or-term-or-kill"] = function(arguments)
    if build.is_running() then
      if tried_term then
        build.kill()
      else
        build.terminate()
        tried_term = true
      end
    else
      tried_term = false
      build.run(arguments)
    end
  end,
  ["build:run-or-term-or-kill-with-arguments"] = function(arguments)
    local relevant_previous_arguments
    for i,v in ipairs(build.state.previous_arguments) do if v[1] == build.state.target then relevant_previous_arguments = v[2] break end end
    core.command_view:enter(get_binary_text() .. " ", {
      submit = function(text)
        config.target_binary_arguments = build.argument_string_to_table(text)
        command.perform("build:run-or-term-or-kill", text)
        local has = false
        for i,v in ipairs(build.state.previous_arguments) do
          if v[1] == build.state.target and v[2] == text then
            has = i
          end
        end
        if has then table.remove(build.state.previous_arguments, has) end
        table.insert(build.state.previous_arguments, { build.state.target, text })
        if #build.state.previous_arguments > build.max_previous_arguments then table.remove(build.state.previous_arguments, 1) end
        save_state()
      end,
      suggest = function(text)
        return common.fuzzy_match(build.state.previous_arguments, text)
      end,
      text = relevant_previous_arguments or ""
    })
  end
})

---Shows or hides the drawer; hidden, it gives the keyboard back.
function build.set_drawer_visible(visible)
  build.view.visible = visible
  if not visible and core.active_view == build.view and core.last_active_view then
    core.set_active_view(core.last_active_view)
  end
end

local function select_target_commandview(submit, target, condition)
  if target then submit(target) end
  local target_names = {}
  for i,v in ipairs(build.targets) do if (not condition or condition(v)) then table.insert(target_names, v.name) end end
  if #target_names == 0 then
    core.log("No targets found")
    return
  end
  core.command_view:enter("Select Target", {
    submit = function(text)
      for i,v in ipairs(build.targets) do if v.name == text then submit(v, i) end end
    end,
    suggest = function(text)
      return common.fuzzy_match(target_names, text)
    end,
    validate = function(text)
      for i,v in ipairs(target_names) do if v == text then return true end end
      return false
    end
  })
end

command.add(nil, {
  ["build:toggle-drawer"] = function()
    build.set_drawer_visible(not build.view.visible)
  end,
  ["build:select-target"] = function(target)
    select_target_commandview(function(target, idx)
      build.set_target(idx)
    end, target)
  end,
  ["build:select-target-and-run"] = function(target)
    select_target_commandview(function(target, idx)
      build.set_target(idx)
      command.perform("build:run-or-term-or-kill")
    end, target, function(target)
      return target.binary
    end)
  end,
  ["build:select-target-and-build"] = function(target)
    select_target_commandview(function(target, idx)
      build.set_target(idx)
      command.perform("build:build")
    end, target)
  end
})

-- escape in the build terminal goes to its program while one runs
command.add(function()
  return core.active_view == build.view and build.view.visible and not build.view:accepts_input()
end, {
  ["build:contextual-close-drawer"] = function()
    build.set_drawer_visible(false)
  end
})

keymap.add {
  ["ctrl+b"]             = { "build:build", "build:terminate" },
  ["alt+b"]         = "build:build-and-run",
  ["ctrl+alt+b"]         = "build:clean-and-build",
  ["ctrl+e"]             = "build:run-or-term-or-kill",
  ["ctrl+shift+e"]       = "build:run-or-term-or-kill-with-arguments",
  ["ctrl+t"]             = "build:next-target",
  ["ctrl+shift+alt+t"]   = "build:select-target",
  ["ctrl+alt+e"]         = "build:select-target-and-run",
  ["ctrl+shift+alt+b"]   = "build:select-target-and-build",
  ["ctrl+shift+b"]       = "build:clean",
  ["f6"]                 = "build:toggle-drawer",
  ["f4"]                 = "build:next-error",
  ["shift+f4"]           = "build:previous-error",
  ["escape"]             = "build:contextual-close-drawer"
}

---Sets the targets: config.plugins.build.targets, or those the backends infer
---for the project. Keeps the current target if there's one of the same name.
function build.infer_targets()
  core.add_thread(function()
    local current = build.targets and build.targets[build.state.target]
    if config.plugins.build.targets then
      build.set_targets(config.plugins.build.targets, config.plugins.build.type or "internal")
    else
      local backends = build.get_backends()
      table.sort(backends, function(a,b) return (a.priority or 0) < (b.priority or 0) end)
      local targets = {}
      for _, backend in ipairs(backends) do
        if backend.id ~= "internal" then
          for _, target in ipairs(backend.infer and backend.infer() or {}) do
            target.backend = backend
            table.insert(targets, target)
          end
        end
      end
      if #targets == 0 then
        local internal = build.get_backends("internal")
        for _, target in ipairs(internal.infer() or {}) do
          target.backend = internal
          table.insert(targets, target)
        end
      end
      build.set_targets(targets)
    end
    if current then
      for i, target in ipairs(build.targets) do
        if target.name == current.name then build.state.target = i break end
      end
    end
    build.set_target(build.state.target)
  end)
end

build.infer_targets()

-- a new project has its own targets
local on_enter_project = core.on_enter_project
function core.on_enter_project(...)
  on_enter_project(...)
  build.infer_targets()
end

-- VS Code's task and launch files define targets (vscode backend)
local doc_save = Doc.save
function Doc:save(...)
  local res = doc_save(self, ...)
  local vscode_dir = core.root_project().path .. PATHSEP .. ".vscode" .. PATHSEP
  if self.abs_filename == vscode_dir .. "tasks.json" or self.abs_filename == vscode_dir .. "launch.json" then
    build.infer_targets()
  end
  return res
end

return build

