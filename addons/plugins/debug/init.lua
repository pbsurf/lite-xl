-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local storage = require "core.storage"
local panel = require "core.panel"
local Node = require "core.node"
local DocView = require "core.docview"
local shapes = require "libraries.shapes"

local breakpoints = require "plugins.debug.breakpoints"
local Session = require "plugins.debug.session"
local Gdb = require "plugins.debug.gdb"
local hover = require "plugins.debug.hover"

---Debugger: runs the program under gdb, in a terminal tab of its own, with
---breakpoints in the gutter, the line it stopped at marked, and its call stack
---and variables in tabs. Those are ordinary tabs: in the bottom panel at
---first, and kept where they're dragged (the workspace restores those in the
---editor area); a closed one stays closed until shown with its command.
---
---Scripting (lxeval): `local debug = require "plugins.debug"`; `debug.start()`,
---then `debug.session` (plugins.debug.session) has the state and actions.
local debug = {}

config.plugins.debug = common.merge({
  -- the debugger's executable, and arguments before the program's
  gdb = "gdb",
  gdb_arguments = {},
  -- syntax names of the files that get a breakpoint column
  breakpoint_syntaxes = {
    "C", "C++", "Objective-C", "D", "Go", "Rust", "Fortran", "Zig", "Odin", "Nim", "Assembly",
  },
  -- stops select the innermost frame in the project, and frames outside it are
  -- folded in the call stack
  just_my_code = true,
  -- globs (gdb's `skip -gfi`) of files not stepped into; * doesn't match /
  skip_files = (function()
    local t = {}
    for depth = 1, 6 do table.insert(t, "/usr/include" .. string.rep("/*", depth)) end
    return t
  end)(),
  max_frames = 200,
  -- types after values in the variables
  show_types = false,
  -- while stopped, hovering a variable in the editor shows its value (and
  -- the language server's hover info doesn't show)
  hover_values = true,
  -- the keys: f5 start or continue (f8 too, as before), f10 step over, f11
  -- step into, f12 step out, shift+f5 or shift+f8 stop, f9 breakpoint, ctrl+f8
  -- run to the cursor. f10 and f11 step only while stopped: otherwise they're
  -- line wrapping's and fullscreen's
  keys = true,
  -- also the keys that work without a session: starting (f5, f8) and f9;
  -- the commands stay available, the gutter takes clicks, and ctrl+f8 (run to
  -- the cursor) starts too
  idle_keys = true,
}, config.plugins.debug)

style.debug = common.merge({
  breakpoint = { common.color "#e51400" },
  -- the line stopped at, and another frame's selected
  current = { common.color "#f2c744" },
  frame = { common.color "#4ec9b0" },
  current_line = { common.color "#f2c74430" },
  frame_line = { common.color "#4ec9b024" },
  -- a value that changed since last shown
  changed = style.text,
  changed_background = { common.color "#f2c74440" },
  -- the expression whose value is shown on hover
  hover = { common.color "#f2c74428" },
}, style.debug)

---The current session (or the last one, ended), nil before the first.
---@type debug.session?
debug.session = nil

---The views' ids, in the order they're first shown.
debug.view_ids = { "program", "stack", "variables", "watches", "threads", "breakpoints" }
local view_modules = {
  program = "plugins.debug.programview",
  stack = "plugins.debug.stackview",
  variables = "plugins.debug.variablesview",
  watches = "plugins.debug.watchesview",
  threads = "plugins.debug.threadsview",
  breakpoints = "plugins.debug.breakpointsview",
}
-- shown by a session unless closed; the others once shown with their command
-- (threads also once a program has several)
local default_views = { program = true, stack = true, variables = true, watches = true }

-- id -> the view (one each)
local views = {}
-- id -> "open" (shown by a session) or "closed" (not until shown with its
-- command); nil for the default
local view_state = storage.load("debug", "view_state") or {}

local function set_view_state(id, state)
  if view_state[id] == state then return end
  view_state[id] = state
  storage.save("debug", "view_state", view_state)
end

local function opens_with_session(id)
  return view_state[id] == "open" or (view_state[id] == nil and default_views[id])
end

local function view_is_open(view)
  return core.root_view.root_node:get_node_for_view(view) ~= nil or panel.contains(view)
end

---The view of an id, made if there's none: restored by the workspace, or
---for a session.
---@param id string
---@return core.view
function debug.get_view(id)
  local view = views[id]
  if view and view_is_open(view) then return view end
  if not view then
    view = require(view_modules[id])()
    views[id] = view
  end
  return view
end

---The view of an id if it's open.
function debug.find_view(id)
  local view = views[id]
  return view and view_is_open(view) and view or nil
end

---Shows a view: where it is, or in the panel.
function debug.show_view(id, focus)
  set_view_state(id, "open")
  panel.show(debug.get_view(id), { focus = focus })
end

-- a view closed by the user (not moved: removed and added in one go) is
-- remembered as closed
local node_remove_view = Node.remove_view
function Node:remove_view(root, view, ...)
  local res = node_remove_view(self, root, view, ...)
  for id, v in pairs(views) do
    if v == view then
      core.add_thread(function()
        if views[id] == view and not view_is_open(view) then
          views[id] = nil
          set_view_state(id, "closed")
          if view.close then pcall(view.close, view) end
        end
      end)
    end
  end
  return res
end

-- the session's views that aren't closed, in the panel unless elsewhere
local function show_views()
  local active = core.active_view
  for _, id in ipairs(debug.view_ids) do
    if opens_with_session(id) and not debug.find_view(id) then
      panel.show(debug.get_view(id), { focus = false })
    end
  end
  -- the program's in front, for its output and input
  if debug.find_view("program") then panel.show(views.program, { focus = false }) end
  if active then core.set_active_view(active) end
end

-- at a session's first stop, the stack in front of the program in the panel
local function front_stack_once(session)
  if session.stack_shown then return end
  session.stack_shown = true
  local program, stack = debug.find_view("program"), debug.find_view("stack")
  if not (program and stack) then return end
  local node = core.root_view.root_node:get_node_for_view(program)
  if node and node.active_view == program and node == core.root_view.root_node:get_node_for_view(stack) then
    local active = core.active_view
    node:set_active_view(stack)
    if active and active ~= program then core.set_active_view(active) end
  end
end


------------------------------ Editor: the line stopped at

-- the terminal's text color for the debugger's lines (the header...): dim
local function dim_sgr()
  local c = style.dim
  return string.format("\x1b[38;2;%d;%d;%dm", c[1], c[2], c[3])
end

---Where the selected frame is: file, line, and whether it's the innermost.
local function current_location()
  local session = debug.session
  local frame = session and session.state == "stopped" and session:get_frame()
  if frame and frame.file and frame.line then return frame.file, frame.line, session.frame_index == 1 end
end

-- the docview to show it in: preview tab in the editor used last, focused
-- unless the focus is in one of the debugger's views (stepping from there)
local function show_location(file, line)
  if not system.get_file_info(file) then return end
  local in_views = false
  for _, v in pairs(views) do if core.active_view == v then in_views = true end end
  if in_views then
    core.root_view:peek_file(file, line, 1)
    return
  end
  local dv = core.root_view:open_doc(core.open_doc(file), { preview = true })
  dv.doc:set_selection(line, 1)
  dv:scroll_to_line(line, true, true)
end

local function on_event(name, session)
  if session ~= debug.session then return end
  -- a value shown on hover may be another now
  if name ~= "output" and name ~= "breakpoints" and name ~= "threads" then hover.clear() end
  if name == "stopped" then
    local file, line = current_location()
    if file then show_location(file, line) end
    front_stack_once(session)
  elseif name == "frame" or name == "thread" then
    local file, line = current_location()
    if file then show_location(file, line) end
  elseif name == "threads" then
    -- a program with several: the threads, unless they were closed
    if session.threads and #session.threads > 1 and view_state.threads == nil and not debug.find_view("threads") then
      panel.show(debug.get_view("threads"), { focus = false })
    end
  elseif name == "ended" then
    local program = debug.find_view("program")
    if program and program.terminal then
      local text = session.exit and (session.exit.description or ("exited with code " .. session.exit.code))
        or (session.error and ("failed: " .. session.error) or "stopped")
      local x = program.terminal:cursor()
      program:write((x > 0 and "\r\n" or "") .. dim_sgr() .. "[" .. text .. "]\x1b[0m\r\n")
    end
  end
end

breakpoints.on_change = function(file)
  if debug.session and debug.session.state ~= "ended" then debug.session:sync_breakpoints(file) end
  core.redraw = true
end


------------------------------ Starting

---Whether a session is under way (not ended).
function debug.is_active()
  return debug.session ~= nil and debug.session.state ~= "ended"
end

local has_build, build = pcall(require, "plugins.build")

---What start() runs by default: the build target's binary, its arguments,
---working directory, environment and debugger commands (plugins.build).
---@return debug.launch_options?
function debug.get_target()
  if not config.target_binary then return nil end
  return {
    program = core.project_absolute_path(common.home_expand(config.target_binary)),
    arguments = config.target_binary_arguments,
    cwd = config.target_workdir and core.project_absolute_path(config.target_workdir) or core.project_dir,
    env = config.target_environment,
    commands = config.target_debugger_commands,
  }
end

local function command_line(options)
  local words = { options.program }
  for _, a in ipairs(options.arguments or {}) do table.insert(words, a) end
  if has_build then return build.command_line(words) end
  return table.concat(words, " ")
end

---Starts debugging: the target's program (or `options.program`), with
---options overriding the target's (debug.launch_options: stop_at_entry, run_to...).
---@param options? table
---@return debug.session?
function debug.start(options)
  if debug.is_active() then return nil end
  breakpoints.load()
  local target = debug.get_target() or {}
  options = common.merge(target, options or {})
  if not options.program then
    core.error("debug: no program to debug (set a build target)")
    return nil
  end
  if not system.get_file_info(options.program) then
    core.error("debug: %s doesn't exist (not built?)", options.program)
    return nil
  end
  options.debugger = options.debugger or config.plugins.debug.gdb
  options.debugger_arguments = options.debugger_arguments or config.plugins.debug.gdb_arguments
  options.skip_files = options.skip_files or config.plugins.debug.skip_files

  show_views()
  local program = debug.find_view("program")
  if program then
    options.tty = program:open_pty()
    program:write(dim_sgr() .. "$ " .. command_line(options) .. "\x1b[0m\r\n")
  end
  local session = Session(Gdb, options)
  debug.session = session
  session.on_event = on_event
  -- without a pty, the program's output comes from gdb
  if not options.tty and program then
    local on_backend_event = session.on_backend_event
    session.on_backend_event = function(self, name, data)
      if name == "output" and data.category == "target" then
        program:write((data.text:gsub("\r?\n", "\r\n")))
        return
      end
      return on_backend_event(self, name, data)
    end
  end
  session:start()
  return session
end

---Builds the target (saving the docs first) and starts debugging it, if the
---build succeeds.
function debug.build_and_start(options)
  if not has_build or not build.can_build(build.targets[build.state.target]) then
    return debug.start(options)
  end
  build.save_docs()
  build.build(function(status)
    if status == 0 then debug.start(options) end
  end)
end

local function can_build()
  return has_build and build.targets and build.can_build(build.targets[build.state.target]) and not build.is_running()
end


------------------------------ Editor: the gutter

local function supports_breakpoints(doc)
  if not (doc and doc.abs_filename and doc.syntax) then return false end
  for _, name in ipairs(config.plugins.debug.breakpoint_syntaxes) do
    if doc.syntax.name == name then return true end
  end
  return false
end

-- width added to the gutter for the breakpoint column, left of the line numbers
local function column_width(dv)
  return supports_breakpoints(dv.doc) and math.floor(dv:get_line_height() * 0.9) or 0
end

-- the column's clickable area, which includes the gutter's left padding
local function column_hit_width(dv)
  local w = column_width(dv)
  return w > 0 and w + style.padding.x / 2 or 0
end

local get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  local width, padding = get_gutter_width(self)
  return width + column_width(self), padding
end

local on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  if button == "left" and self.debug_hovered_line then
    breakpoints.load()
    breakpoints.toggle(self.doc.abs_filename, self.debug_hovered_line)
    return true
  end
  return on_mouse_pressed(self, button, x, y, clicks)
end

local on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  local was = self.debug_hovered_line
  self.debug_hovered_line = nil
  if on_mouse_moved(self, x, y, ...) then
    if was then core.redraw = true end
    return true
  end
  if x >= self.position.x and x < self.position.x + column_hit_width(self)
     and not self:scrollbar_overlaps_point(x, y) then
    self.debug_hovered_line = self:resolve_screen_position(x, y)
    self.cursor = "arrow"
  end
  if was ~= self.debug_hovered_line then core.redraw = true end
end

local on_mouse_left = DocView.on_mouse_left
function DocView:on_mouse_left()
  on_mouse_left(self)
  self.debug_hovered_line = nil
end

local function with_alpha(color, a)
  return { color[1], color[2], color[3], (color[4] or 255) * a }
end

local draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(vline, x, y, width)
  local bw = column_width(self)
  if bw > 0 then
    local line = self.get_dline and self:get_dline(vline) or vline
    local lh = self:get_line_height()
    local cx, cy = x + column_hit_width(self) / 2, y + lh / 2
    local r = math.floor(self:get_font():get_height() * 0.32)
    breakpoints.load()
    local has = breakpoints.has(self.doc.abs_filename, line)
    if has and breakpoints.enabled(self.doc.abs_filename, line) then
      -- faded if the debugger couldn't place it
      local status = debug.is_active() and debug.session:get_breakpoint_status(self.doc.abs_filename, line)
      shapes.circle(cx, cy, r, (status and not status.verified) and with_alpha(style.debug.breakpoint, 0.45)
        or style.debug.breakpoint)
    elseif has then
      -- disabled
      shapes.circle(cx, cy, r - SCALE / 2, style.debug.breakpoint, SCALE)
    elseif self.debug_hovered_line == line then
      -- where a click would set one
      shapes.circle(cx, cy, r, with_alpha(style.debug.breakpoint, 0.35))
    end
    local file, cur, innermost = current_location()
    if file == self.doc.abs_filename and line == cur then
      local color = innermost and style.debug.current or style.debug.frame
      if has then
        -- in the breakpoint's circle
        local a = r * 1.1
        shapes.arrow(cx - a * 0.4, cy - a / 2, a * 0.85, a, color, true)
      else
        local h = r * 2
        shapes.arrow(cx - r * 1.15, cy - h / 2, r * 2.3, h, color)
      end
    end
  end
  return draw_line_gutter(self, vline, x + bw, y, width - bw)
end

-- the line stopped at gets a background of its own, in place of the current
-- line's highlight
local draw_line_body = DocView.draw_line_body
function DocView:draw_line_body(line, x, y)
  local file, cur, innermost = current_location()
  if file == self.doc.abs_filename and line == cur then
    local x1 = self.position.x + self:get_gutter_width()
    renderer.draw_rect(x1, y, self.size.x - (x1 - self.position.x), self:get_line_height(),
      innermost and style.debug.current_line or style.debug.frame_line)
    self.debug_drawing_current = true
    local res = draw_line_body(self, line, x, y)
    self.debug_drawing_current = false
    return res
  end
  return draw_line_body(self, line, x, y)
end

local draw_line_highlight = DocView.draw_line_highlight
function DocView:draw_line_highlight(...)
  if self.debug_drawing_current then return end
  return draw_line_highlight(self, ...)
end


hover.setup(debug, supports_breakpoints)

-- while stopped, the language server's hover popups don't show: hovering is
-- for values
core.add_thread(function()
  local lsp = package.loaded["plugins.lsp"]
  if lsp and lsp.hover_suppressors then
    table.insert(lsp.hover_suppressors, function()
      return config.plugins.debug.hover_values and debug.session ~= nil and debug.session.state == "stopped"
    end)
  end
end)


------------------------------ Commands

local function session_in(...)
  local states = { ... }
  return function()
    local s = debug.session
    if not s then return false end
    for _, state in ipairs(states) do if s.state == state then return true, s end end
    return false
  end
end

local function idle() return not debug.is_active() and debug.get_target() ~= nil end

command.add(idle, {
  ["debug:start"] = function() debug.start() end,
  ["debug:start-at-entry"] = function() debug.start({ stop_at_entry = true }) end,
})

command.add(function() return idle() and can_build() end, {
  ["debug:build-and-start"] = function() debug.build_and_start() end,
})

-- f5: build and start when not debugging, continue when stopped
command.add(function()
  if debug.session and debug.session.state == "stopped" then return true end
  return idle()
end, {
  ["debug:start-or-continue"] = function()
    if debug.session and debug.session.state == "stopped" then
      debug.session:continue()
    elseif can_build() then
      debug.build_and_start()
    else
      debug.start()
    end
  end,
})

command.add(session_in("stopped"), {
  ["debug:continue"] = function(s) s:continue() end,
  ["debug:step-over"] = function(s) s:step_over() end,
  ["debug:step-into"] = function(s) s:step_into() end,
  ["debug:step-out"] = function(s) s:step_out() end,
})

command.add(session_in("running"), {
  ["debug:pause"] = function(s) s:pause() end,
})

command.add(session_in("starting", "running", "stopped"), {
  ["debug:stop"] = function(s) s:terminate() end,
})

local function cursor_line()
  local view = core.active_view
  if view:is(DocView) and view.doc.abs_filename then
    local line = view.doc:get_selection()
    return view.doc.abs_filename, line
  end
end

-- run to the cursor: continuing, or starting the program
command.add(function()
  local file = cursor_line()
  if not file then return false end
  if debug.session and debug.session.state == "stopped" then return true end
  return idle()
end, {
  ["debug:run-to-cursor"] = function()
    local file, line = cursor_line()
    if debug.session and debug.session.state == "stopped" then
      debug.session:run_to(file, line)
    else
      debug.start({ run_to = { file, line } })
    end
  end,
})

command.add(function()
  local view = core.active_view
  return view:is(DocView) and supports_breakpoints(view.doc), view
end, {
  ["debug:toggle-breakpoint"] = function(view)
    breakpoints.load()
    local line = view.doc:get_selection()
    breakpoints.toggle(view.doc.abs_filename, line)
  end,
})

command.add(nil, {
  ["debug:clear-breakpoints"] = function()
    breakpoints.load()
    breakpoints.clear_all()
  end,
})

for _, id in ipairs(debug.view_ids) do
  -- their commands are made as they load
  if id ~= "program" then require(view_modules[id]) end
  command.add(nil, {
    ["debug:show-" .. id:gsub("stack", "call-stack")] = function() debug.show_view(id, true) end,
  })
end

-- the stack's frames from anywhere: up (outward) and down
command.add(function()
  local s = debug.session
  return s and s.state == "stopped" and s.frames ~= nil, s
end, {
  ["debug:frame-up"] = function(s) s:select_frame((s.frame_index or 0) + 1) end,
  ["debug:frame-down"] = function(s) s:select_frame((s.frame_index or 2) - 1) end,
})

if config.plugins.debug.keys then
  local idle = config.plugins.debug.idle_keys
  keymap.add {
    ["f5"]         = idle and "debug:start-or-continue" or "debug:continue",
    ["f8"]         = { idle and "debug:start-or-continue" or "debug:continue", "debug:pause" },
    ["shift+f5"]   = "debug:stop",
    ["shift+f8"]   = "debug:stop",
    ["f10"]        = "debug:step-over",
    ["f11"]        = "debug:step-into",
    ["f12"]        = "debug:step-out",
    ["ctrl+f8"]    = "debug:run-to-cursor",
    ["ctrl+alt+up"]   = "debug:frame-up",
    ["ctrl+alt+down"] = "debug:frame-down",
  }
  -- these work without a session
  if idle then
    keymap.add { ["f9"] = "debug:toggle-breakpoint" }
  end
end


-- in the editor's context menu while debugging: running to the line clicked
-- (a right-click puts the caret there), while stopped, in a debugged file;
-- the selection or the word clicked as a watch
local menu_found, menu = pcall(require, "plugins.contextmenu")
if menu_found then
  menu:register(function()
    return debug.is_active() and core.active_view:is(DocView)
  end, function()
    local items = { menu.DIVIDER }
    if debug.session.state == "stopped" and supports_breakpoints(core.active_view.doc) then
      table.insert(items, { text = "Run to Here", command = "debug:run-to-cursor",
        info = keymap.get_binding("debug:run-to-cursor") })
    end
    table.insert(items, { text = "Add Watch", command = "debug:add-watch" })
    return items
  end)
end


------------------------------ Build integration

if has_build then
  -- in the target menu, after Build and Run
  for i, row in ipairs(build.menu_actions) do
    if row.command == "build:build-and-run" then
      table.insert(build.menu_actions, i + 1, { text = "Build and Debug", command = "debug:build-and-start" })
      table.insert(build.menu_actions, i + 2, { text = "Stop Debugging", command = "debug:stop" })
      break
    end
  end
end

debug.breakpoints = breakpoints
debug.Session = Session

return debug
