local core = require "core"
local common = require "core.common"
local config = require "core.config"
local Object = require "core.object"
local breakpoints = require "plugins.debug.breakpoints"

---A debug session: a program run under a debugger backend, its state, and
---what can be done with it. Backend-neutral: the shapes follow the Debug
---Adapter Protocol's (threads, frames, scopes and variables by reference), so
---backends other than gdb's (a DAP client, Windows' debugger engine) fit.
---
---Usable from Lua (lxeval) as well as the UI: the current session is
---`require("plugins.debug").session`. Actions (continue, step_over...) can be
---called from anywhere; queries (variables, evaluate) wait for the backend, so
---they need a core thread (core.add_thread), or take a callback.
---
---States: "starting" (the debugger is setting up), "running", "stopped"
---(frames and variables can be looked at), "ended" (the program exited, or was
---stopped; final).
---
---Events (`session.on_event(name, session)`, set by whoever shows it):
---"state" (state changed), "stopped" (stopped, frames fetched), "frame" (another
---frame selected), "thread" (another thread selected, its frames fetched),
---"threads" (the threads listed), "breakpoints" (the debugger's breakpoints
---changed: `breakpoint_status`), "output" (debugger output: `session.output_log`),
---"ended".
---
---A backend (plugins.debug.gdb) is an object made with a function receiving
---its events, ("running"|"stopped"|"exited"|"output"|"ended", data), having
---`capabilities` and these methods, all called in a core thread:
---* start(launch_options) -> ok, err; run(stop_at_entry) -> ok, err;
---  run_to_start(file, line) (before run: where to stop first)
---* set_breakpoints(file, specs) -> debug.breakpoint_result[]; specs: { line,
---  condition?, hit_count? }[] (capability `conditions` for the last two)
---* continue(), pause(), step_over(thread), step_into(thread),
---  step_out(thread, level), run_to(file, line); terminate() -> whether
---  there was a debugger to end (its "ended" event follows)
---* threads() -> debug.thread[]; stack(thread, limit) -> debug.frame[]; new_stop()
---* scopes(thread, level) -> { name, ref }[]; variables(ref) -> debug.variable[]
---* evaluate(expression, thread, level) -> value, err
---* watch(expression, thread, level) -> debug.variable, err (one that unfolds)
---* function_lines(thread, level) -> file, first, last (capability
---  `function_lines`): the lines of the frame's function
---@class debug.session : core.object
local Session = Object:extend()

---@class debug.launch_options
---@field program string absolute
---@field arguments? string[]
---@field cwd? string
---@field env? table<string, string>
---@field tty? string the program's terminal (a pty's slave)
---@field commands? string[] debugger commands run before the program starts
---@field skip_files? string[] globs of files not stepped into
---@field debugger? string the debugger's executable
---@field debugger_arguments? string[]
---@field stop_at_entry? boolean
---@field run_to? { [1]: string, [2]: integer } file and line to run to

---@class debug.frame
---@field level integer 0 for the innermost
---@field name string the function's
---@field file? string absolute
---@field line? integer
---@field addr? string
---@field from? string the library, without debugging info
---@field args? { name: string, value?: string }[]
---@field external? boolean not in the project (set by the session)

---@class debug.thread
---@field id integer
---@field name? string the thread's name (pthread_setname_np), if it has one
---@field target_id? string the system's name for it, e.g. "Thread 0x7f... (LWP 123)"
---@field frame? debug.frame its innermost frame
---@field project_frame? debug.frame its innermost frame in the project (set by the session)

---@class debug.variable
---@field name string
---@field value? string
---@field type? string
---@field ref? integer its children's reference, if it has any

---@class debug.breakpoint_result
---@field line integer as asked for
---@field actual integer where the debugger put it
---@field verified boolean
---@field message? string

---Whether this runs in a core thread (core.add_thread), which can wait for the
---backend: not the main one, nor another coroutine (lxeval's).
function Session.in_core_thread()
  local co = coroutine.running()
  for _, thread in pairs(core.threads) do
    if thread.cr == co then return true end
  end
  return false
end

-- runs fn now if in a core thread, else in a new one
local function run(fn)
  if Session.in_core_thread() then fn() else core.add_thread(fn) end
end

---@param backend_class table
---@param options debug.launch_options
function Session:new(backend_class, options)
  self.options = options
  self.state = "starting"
  -- why it stopped: { reason, description, thread_id, signal }
  self.stop = nil
  -- the threads (once listed at a stop), the one selected (its id: at first
  -- the one that stopped), its frames and the one selected (index)
  self.threads = nil
  self.thread = nil
  self.frames = nil
  self.frame_index = nil
  -- counts stops: what's fetched for one is stale at the next
  self.generation = 0
  -- the program's exit: { code, signal, description }
  self.exit = nil
  self.error = nil
  -- the debugger's console and log output (not the program's: its terminal)
  self.output_log = {}
  self.on_event = function() end
  self.backend = backend_class(function(name, data) self:on_backend_event(name, data) end)
  self.capabilities = self.backend.capabilities or {}
  -- file -> line -> debug.breakpoint_result, for the enabled breakpoints
  self.breakpoint_status = {}
end

function Session:emit(name)
  core.redraw = true
  local ok, err = pcall(self.on_event, name, self)
  if not ok then core.error("debug: %s", err) end
end

function Session:set_state(state)
  if self.state == state or self.state == "ended" then return end
  self.state = state
  self:emit("state")
end

---Starts the debugger and runs the program.
function Session:start()
  run(function()
    local ok, err = self.backend:start(self.options)
    if not ok then return self:fail(err) end
    for _, file in ipairs(breakpoints.files()) do self:sync_breakpoints(file) end
    if self.options.run_to then
      local res, err = self.backend:run_to_start(self.options.run_to[1], self.options.run_to[2])
      if not res then return self:fail(err) end
    end
    ok, err = self.backend:run(self.options.stop_at_entry and not self.options.run_to)
    if not ok then return self:fail(err) end
  end)
end

function Session:fail(err)
  self.error = err
  self:log("Error: " .. tostring(err) .. "\n")
  core.error("debug: %s", err)
  self:terminate()
end

function Session:log(text)
  table.insert(self.output_log, text)
  if #self.output_log > 5000 then table.remove(self.output_log, 1) end
  self:emit("output")
end

---Whether a file is the project's (just my code): in one of its directories.
---@param file? string
function Session.is_project_file(file)
  if not file or not system.get_file_info(file) then return false end
  for _, dir in ipairs(core.project_directories) do
    if common.path_belongs_to(file, dir.name) then return true end
  end
  return false
end

function Session:on_backend_event(name, data)
  if name == "running" then
    self.stop, self.frames, self.frame_index, self.threads = nil, nil, nil, nil
    self:set_state("running")
  elseif name == "stopped" then
    self.generation = self.generation + 1
    local generation = self.generation
    if generation == 1 and self.options.stop_at_entry and data.reason == "breakpoint-hit" then
      data.description = "Entry"
    end
    self.stop = data
    self.frames, self.frame_index, self.threads = nil, nil, nil
    self.thread = data.thread_id
    self:set_state("stopped")
    core.add_thread(function()
      self.backend:new_stop()
      local frames, first = self:fetch_stack(data.thread_id, config.plugins.debug.max_frames)
      if self.generation ~= generation then return end
      self.frames = frames
      self.frame_index = (config.plugins.debug.just_my_code and first) or (#frames > 0 and 1 or nil)
      self:emit("stopped")
      self:fetch_threads(generation)
    end)
  elseif name == "exited" then
    self.exit = data
    self:log(string.format("Program %s.\n", data.description or ("exited with code " .. data.code)))
    self:terminate()
  elseif name == "output" then
    self:log(data.text)
  elseif name == "ended" then
    self.stop, self.frames, self.frame_index, self.threads = nil, nil, nil, nil
    self.breakpoint_status = {}
    self:set_state("ended")
    self:emit("ended")
  end
end

---A thread's frames, marked external (not the project's), and the index of
---the first that isn't, in a core thread.
---@return debug.frame[] frames
---@return integer? first
function Session:fetch_stack(thread_id, limit)
  local frames = self.backend:stack(thread_id, limit) or {}
  local first
  for i, frame in ipairs(frames) do
    frame.external = not Session.is_project_file(frame.file)
    if not frame.external and not first then first = i end
  end
  return frames, first
end

-- most threads whose stacks are looked at for their project frames
local MAX_THREAD_STACKS = 64
-- frames looked at in each
local THREAD_STACK_DEPTH = 32

---Lists the threads, each with its innermost project frame (in a core thread).
function Session:fetch_threads(generation)
  local threads = self.backend:threads() or {}
  for i, thread in ipairs(threads) do
    if self.generation ~= generation then return end
    if thread.id == self.thread and self.frames then
      local frames = self.frames
      for _, f in ipairs(frames) do
        if not f.external then thread.project_frame = f break end
      end
    elseif i <= MAX_THREAD_STACKS then
      local frames, first = self:fetch_stack(thread.id, THREAD_STACK_DEPTH)
      thread.project_frame = first and frames[first]
    end
  end
  if self.generation ~= generation then return end
  self.threads = threads
  self:emit("threads")
end

---Updates the debugger's breakpoints in a file to the store's enabled ones,
---moving those it put on other lines.
---@param file string
function Session:sync_breakpoints(file)
  if self.state == "ended" then return end
  run(function()
    -- set while running: gdb inserts them as it stops for it
    local results = self.backend:set_breakpoints(file, breakpoints.specs(file))
    local status = {}
    for _, r in ipairs(results) do
      if r.verified and r.actual ~= r.line and not breakpoints.has(file, r.actual) then
        breakpoints.move(file, r.line, r.actual)
        status[r.actual] = r
      else
        status[r.line] = r
      end
    end
    self.breakpoint_status[file] = status
    self:emit("breakpoints")
  end)
end

---What the debugger made of a breakpoint: debug.breakpoint_result, nil if it
---doesn't have it.
function Session:get_breakpoint_status(file, line)
  return self.breakpoint_status[file] and self.breakpoint_status[file][line]
end

---The selected frame.
---@return debug.frame?
function Session:get_frame()
  return self.frames and self.frame_index and self.frames[self.frame_index]
end

---The selected thread's id.
function Session:thread_id()
  return self.thread
end

---Selects a thread: the stack, variables and stepping are its.
---@param id integer
function Session:select_thread(id)
  if self.state ~= "stopped" or id == self.thread then return end
  local generation = self.generation
  self.thread = id
  self.frames, self.frame_index = nil, nil
  run(function()
    local frames, first = self:fetch_stack(id, config.plugins.debug.max_frames)
    if self.generation ~= generation or self.thread ~= id then return end
    self.frames = frames
    self.frame_index = (config.plugins.debug.just_my_code and first) or (#frames > 0 and 1 or nil)
    self:emit("thread")
  end)
end

---Selects a frame (index into frames): variables are of it.
function Session:select_frame(index)
  if not self.frames or not self.frames[index] or index == self.frame_index then return end
  self.frame_index = index
  self:emit("frame")
end

local function action(name)
  return function(self, ...)
    local args = { ... }
    if self.state ~= "stopped" then return false end
    run(function()
      local ok, err = self.backend[name](self.backend, table.unpack(args))
      if not ok and err then self:log(name .. ": " .. err .. "\n") end
    end)
    return true
  end
end

Session.continue = action("continue")

-- The level stepping applies to: the top frame's, unless frames above the
-- selected project frame are all outside the project (stopped in a library):
-- then stepping over or out returns to the selected one.
function Session:step_target()
  local index = self.frame_index or 1
  if index > 1 then
    for i = 1, index - 1 do
      if not self.frames[i].external then return nil end
    end
    return index
  end
end

function Session:step_over()
  local target = self:step_target()
  if target then return action("step_out")(self, self:thread_id(), self.frames[target - 1].level) end
  return action("step_over")(self, self:thread_id())
end

function Session:step_into()
  local target = self:step_target()
  if target then return action("step_out")(self, self:thread_id(), self.frames[target - 1].level) end
  return action("step_into")(self, self:thread_id())
end

function Session:step_out()
  local frame = self:get_frame()
  return action("step_out")(self, self:thread_id(), frame and frame.level or 0)
end

---Runs to a line (continuing if stopped).
function Session:run_to(file, line)
  return action("run_to")(self, file, line)
end

function Session:pause()
  if self.state ~= "running" then return false end
  run(function() self.backend:pause() end)
  return true
end

---Ends the debugger, and the program with it.
function Session:terminate()
  if self.state == "ended" or self.terminating then return end
  self.terminating = true
  run(function()
    -- nothing to end (it didn't start): the backend won't report it
    if not self.backend:terminate() then self:on_backend_event("ended", {}) end
  end)
end

---The selected frame's scopes, in a core thread (or given to `callback`):
---{ name, ref }[].
function Session:scopes(callback)
  local frame = self:get_frame()
  if not frame then return callback and callback(nil) end
  local generation = self.generation
  local function get()
    local scopes = self.backend:scopes(self:thread_id(), frame.level)
    if generation ~= self.generation then return nil end
    return scopes
  end
  if callback then core.add_thread(function() callback(get()) end) else return get() end
end

---A reference's variables, in a core thread (or given to `callback`).
---@return debug.variable[]?
function Session:variables(ref, callback)
  local generation = self.generation
  local function get()
    local vars, err = self.backend:variables(ref)
    if generation ~= self.generation then return nil, "stale" end
    return vars, err
  end
  if callback then core.add_thread(function() callback(get()) end) else return get() end
end

---An expression as a variable (unfolding into its members) in the selected
---frame, in a core thread (or given to `callback`).
---@return debug.variable?
---@return string? error
function Session:watch(expression, callback)
  local frame = self:get_frame()
  local generation = self.generation
  local function get()
    if self.state ~= "stopped" or not frame then return nil, "not stopped" end
    local var, err = self.backend:watch(expression, self:thread_id(), frame.level)
    if generation ~= self.generation then return nil, "stale" end
    return var, err
  end
  if callback then core.add_thread(function() callback(get()) end) else return get() end
end

---An expression's value in the selected frame, in a core thread (or given to
---`callback`).
---@return string? value
---@return string? error
function Session:evaluate(expression, callback)
  local frame = self:get_frame()
  local function get()
    if self.state ~= "stopped" then return nil, "not stopped" end
    return self.backend:evaluate(expression, self:thread_id(), frame and frame.level)
  end
  if callback then core.add_thread(function() callback(get()) end) else return get() end
end

---The lines of the selected frame's function: its file, first and last line
---with code, in a core thread (or given to `callback`); nil if the backend
---can't tell. Kept until the next stop.
---@return string? file
---@return integer? first
---@return integer? last
function Session:function_lines(callback)
  local frame = self:get_frame()
  local generation = self.generation
  local function get()
    if self.state ~= "stopped" or not frame or not self.capabilities.function_lines then return nil end
    if not self.function_lines_cache or self.function_lines_cache.generation ~= generation then
      self.function_lines_cache = { generation = generation }
    end
    local key = self:thread_id() .. ":" .. frame.level
    local cached = self.function_lines_cache[key]
    if not cached then
      cached = { self.backend:function_lines(self:thread_id(), frame.level) }
      if generation ~= self.generation then return nil end
      self.function_lines_cache[key] = cached
    end
    return table.unpack(cached, 1, 3)
  end
  if callback then core.add_thread(function() callback(get()) end) else return get() end
end

return Session
