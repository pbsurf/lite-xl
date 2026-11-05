local core = require "core"
local common = require "core.common"
local Object = require "core.object"
local mi = require "plugins.debug.mi"

---The gdb backend: gdb run with its machine interface (MI3) on pipes, the
---program on a terminal's pty of its own (-inferior-tty-set). Each command
---carries a token its result comes back with, so commands can be in flight
---together; the reader thread sleeps until gdb writes (process:watch_source).
---
---Implements the backend interface described in plugins.debug.session.
---@class debug.gdb : core.object
local Gdb = Object:extend()

Gdb.name = "gdb"

---What the views and commands may rely on (see session.lua).
Gdb.capabilities = { pause = true, run_to = true, step_out = true, evaluate = true, threads = true, watch = true,
  function_lines = true, conditions = true }

-- most children of a variable listed (a big array's or container's)
local MAX_CHILDREN = 500

---@param on_event fun(name: string, data: table) called from the reader thread;
---must not block (start a thread for requests)
function Gdb:new(on_event)
  self.on_event = on_event
  self.next_token = 1
  -- token -> { done, class, results }
  self.pending = {}
  -- file -> line -> { number, actual }
  self.breakpoints = {}
  -- references to scopes and variables (session.lua): id -> what it names
  self.refs = {}
  self.next_ref = 1
  -- varobjs made for the stop they belong to, deleted at the next
  self.varobjs = {}
  self.exited = false
end

local function write_all(proc, data)
  while #data > 0 do
    local n = proc:write(data)
    if not n then return false end
    data = data:sub(n + 1)
    if #data > 0 then coroutine.yield(0.01) end
  end
  return true
end

---Sends an MI command; `callback(class, results)` gets its result ("done",
---"running", "error" with results.msg, ...).
---@param command string
---@param callback? fun(class: string, results: table)
function Gdb:send(command, callback)
  if not self.proc then
    if callback then callback("error", { msg = "gdb isn't running" }) end
    return
  end
  local token = self.next_token
  self.next_token = token + 1
  self.pending[token] = callback or false
  if self.log then self.log("> " .. token .. command) end
  self.proc:write(token .. command .. "\n")
end

---Sends a command and waits for its result, in a core thread.
---@return string class
---@return table results
function Gdb:request(command)
  assert(require("plugins.debug.session").in_core_thread(), "Gdb:request needs a core thread")
  local waiter = {}
  self:send(command, function(class, results)
    waiter.class, waiter.results = class, results
    core.wake(waiter)
  end)
  -- (a table key would be taken as a list of keys)
  while not waiter.class do core.wait_for({ waiter }) end
  return waiter.class, waiter.results
end

-- a request's results, or nil and the error's message
function Gdb:ask(command)
  local class, results = self:request(command)
  if class == "error" then return nil, results.msg or "error" end
  return results
end

-- runs a CLI command
function Gdb:cli(command)
  return self:ask("-interpreter-exec console " .. mi.quote(command))
end

local function frame_of(t)
  if not t then return nil end
  return {
    level = tonumber(t.level) or 0,
    name = t.func or "??",
    file = t.fullname or t.file,
    line = tonumber(t.line),
    addr = t.addr,
    from = t.from,
  }
end

local function stop_description(r)
  local reason = r.reason
  if reason == "breakpoint-hit" then
    return r.disp == "del" and "Reached line" or "Breakpoint"
  elseif reason == "end-stepping-range" then return "Step"
  elseif reason == "function-finished" then
    return r["return-value"] and ("Returned " .. r["return-value"]) or "Stepped out"
  elseif reason == "location-reached" then return "Reached location"
  elseif reason == "signal-received" then
    if r["signal-name"] == "SIGINT" then return "Paused" end
    return (r["signal-name"] or "Signal") .. (r["signal-meaning"] and (": " .. r["signal-meaning"]) or "")
  elseif reason == "watchpoint-trigger" then return "Watchpoint"
  elseif reason == nil then return "Paused"
  end
  return reason
end

function Gdb:on_record(rec)
  if rec.type == "result" then
    local callback = rec.token and self.pending[rec.token]
    if rec.token then self.pending[rec.token] = nil end
    if callback then callback(rec.class, rec.results) end
  elseif rec.type == "exec" then
    local r = rec.results
    if rec.class == "running" then
      self.on_event("running", { thread_id = r["thread-id"] })
    elseif rec.class == "stopped" then
      local reason = r.reason or ""
      if reason:find("^exited") then
        self.exited = true
        self.on_event("exited", {
          code = tonumber(r["exit-code"] or "0", 8) or 0,
          signal = r["signal-name"],
          description = reason == "exited-signalled" and ("Killed by " .. (r["signal-name"] or "a signal")) or nil,
        })
      else
        self.on_event("stopped", {
          reason = reason, description = stop_description(r),
          thread_id = tonumber(r["thread-id"]), frame = frame_of(r.frame),
          signal = reason == "signal-received" and r["signal-name"] ~= "SIGINT" and r["signal-name"] or nil,
          -- a function finished: what it returned, and the gdb variable holding it
          return_value = r["return-value"], return_var = r["gdb-result-var"],
        })
      end
    end
  elseif rec.type == "console" or rec.type == "target" or rec.type == "log" then
    self.on_event("output", { category = rec.type, text = rec.text })
  elseif rec.type == "other" and rec.text ~= "" then
    self.on_event("output", { category = "log", text = rec.text .. "\n" })
  end
end

---Starts gdb on the program, not running it yet.
---@param opts debug.launch_options
---@return boolean? ok
---@return string? error
function Gdb:start(opts)
  local args = { opts.debugger or "gdb", "--interpreter=mi3", "-q", "-nx" }
  for _, a in ipairs(opts.debugger_arguments or {}) do table.insert(args, a) end
  table.insert(args, "--args")
  table.insert(args, opts.program)
  for _, a in ipairs(opts.arguments or {}) do table.insert(args, a) end
  local ok, proc = pcall(process.start, args, {
    cwd = opts.cwd, env = opts.env, stderr = process.REDIRECT_STDOUT,
  })
  if not ok then return nil, "can't start " .. args[1] .. ": " .. tostring(proc) end
  self.proc = proc
  core.add_thread(function() self:read_loop() end)

  local setup = {
    "-gdb-set mi-async on",
    "-enable-pretty-printing",
    "-gdb-set debuginfod enabled off",
    "-gdb-set confirm off",
    "-gdb-set pagination off",
  }
  if opts.cwd then table.insert(setup, "-environment-cd " .. mi.quote(opts.cwd)) end
  if opts.tty then table.insert(setup, "-inferior-tty-set " .. mi.quote(opts.tty)) end
  for _, command in ipairs(setup) do self:ask(command) end
  for _, glob in ipairs(opts.skip_files or {}) do self:cli("skip -gfi " .. glob) end
  for _, command in ipairs(opts.commands or {}) do
    local ok, err = self:cli(command)
    if not ok then self.on_event("output", { category = "log", text = command .. ": " .. err .. "\n" }) end
  end
  -- was the program loaded?
  local res, err = self:ask("-file-list-exec-source-file")
  if not res and err and err:find("No symbol table") then
    self.on_event("output", { category = "log", text = "No debugging symbols in " .. opts.program .. "\n" })
  end
  return true
end

---Runs the program: until a breakpoint, or stopped at its entry (main).
---@param stop_at_entry? boolean
function Gdb:run(stop_at_entry)
  return self:ask(stop_at_entry and "-exec-run --start" or "-exec-run")
end

function Gdb:read_loop()
  local buffer = ""
  local proc = self.proc
  while true do
    local chunk = proc:read_stdout(65536)
    if not chunk then break end
    if chunk == "" then
      local source = proc:watch_source(process.STREAM_STDOUT)
      if not source then break end
      core.wait_for(core.watch_readable(source))
    else
      buffer = buffer .. chunk
      while true do
        local nl = buffer:find("\n", 1, true)
        if not nl then break end
        local line = buffer:sub(1, nl - 1):gsub("\r$", "")
        buffer = buffer:sub(nl + 1)
        if self.log then self.log("< " .. line) end
        local ok, err = pcall(self.on_record, self, mi.parse(line))
        if not ok then core.error("debug: %s", err) end
      end
    end
  end
  self.proc = nil
  -- commands waiting for results won't get any
  local pending = self.pending
  self.pending = {}
  for _, callback in pairs(pending) do
    if callback then callback("error", { msg = "gdb exited" }) end
  end
  self.on_event("ended", { code = proc:returncode() })
end

-- the bkpt of an insert's results: its line (the first location's, for one
-- with several)
local function bkpt_line(bkpt)
  if bkpt.line then return tonumber(bkpt.line) end
  for _, loc in ipairs(bkpt.locations or {}) do
    if loc.line then return tonumber(loc.line) end
  end
end

---Makes the file's breakpoints these: lines, each with an optional condition
---(-c) and the hit to stop from (-i, ignoring those before). One whose
---condition or hit count changed is inserted again.
---@param file string absolute
---@param specs { line: integer, condition?: string, hit_count?: integer }[]
---@return debug.breakpoint_result[]
function Gdb:set_breakpoints(file, specs)
  local current = self.breakpoints[file] or {}
  self.breakpoints[file] = current
  local wanted = {}
  for _, spec in ipairs(specs) do wanted[spec.line] = spec end
  for line, bp in pairs(current) do
    local spec = wanted[line]
    if not spec or spec.condition ~= bp.condition or spec.hit_count ~= bp.hit_count then
      if bp.number then self:ask("-break-delete " .. bp.number) end
      current[line] = nil
    end
  end
  local results = {}
  for _, spec in ipairs(specs) do
    local line = spec.line
    local bp = current[line]
    if not bp then
      local options = " -f"
      if spec.condition then options = options .. " -c " .. mi.quote(spec.condition) end
      if spec.hit_count then options = options .. " -i " .. (spec.hit_count - 1) end
      local res, err = self:ask("-break-insert" .. options .. " " .. mi.quote(file .. ":" .. line))
      if res and res.bkpt then
        bp = { number = res.bkpt.number, actual = bkpt_line(res.bkpt), pending = res.bkpt.pending ~= nil }
        -- pending: no code there, in the program or the libraries loaded so far
        if bp.pending then bp.error = "not in the program (pending)" end
      else
        -- kept, so it isn't tried again until it changes
        bp = { error = err }
      end
      bp.condition, bp.hit_count = spec.condition, spec.hit_count
      current[line] = bp
    end
    table.insert(results, { line = line, actual = bp.actual or line,
      verified = bp.number ~= nil and not bp.pending, message = bp.error })
  end
  return results
end

function Gdb:continue() return self:ask("-exec-continue") end
function Gdb:pause() return self:ask("-exec-interrupt") end

local function thread_frame(thread_id, level)
  return (thread_id and (" --thread " .. thread_id) or "") .. (level and (" --frame " .. level) or "")
end

function Gdb:step_over(thread_id) return self:ask("-exec-next" .. thread_frame(thread_id)) end
function Gdb:step_into(thread_id) return self:ask("-exec-step" .. thread_frame(thread_id)) end
---Runs until the frame at `level` returns.
function Gdb:step_out(thread_id, level) return self:ask("-exec-finish" .. thread_frame(thread_id, level)) end

---Before run: a temporary breakpoint to run to.
function Gdb:run_to_start(file, line)
  return self:ask("-break-insert -t " .. mi.quote(file .. ":" .. line))
end

function Gdb:run_to(file, line)
  local res, err = self:ask("-break-insert -t " .. mi.quote(file .. ":" .. line))
  if not res then return nil, err end
  return self:continue()
end

---Ends gdb and the program.
function Gdb:terminate()
  if not self.proc then return false end
  local proc = self.proc
  self:send("-gdb-exit")
  core.add_thread(function()
    local deadline = system.get_time() + 2
    while proc:running() and system.get_time() < deadline do coroutine.yield(0.05) end
    if proc:running() then proc:kill() end
  end)
  return true
end

---The thread's frames, innermost first, with their arguments.
---@param thread_id integer
---@param limit integer
---@return debug.frame[]?
---@return string? error
function Gdb:stack(thread_id, limit)
  local res, err = self:ask("-stack-list-frames" .. thread_frame(thread_id) .. " 0 " .. (limit - 1))
  if not res then return nil, err end
  local frames = {}
  for _, f in ipairs(res.stack or {}) do table.insert(frames, frame_of(f)) end
  local args = self:ask("-stack-list-arguments" .. thread_frame(thread_id) .. " --simple-values 0 " .. (limit - 1))
  for _, f in ipairs(args and args["stack-args"] or {}) do
    local frame = frames[(tonumber(f.level) or -1) + 1]
    if frame then
      frame.args = {}
      for _, a in ipairs(f.args or {}) do table.insert(frame.args, { name = a.name, value = a.value }) end
    end
  end
  return frames
end

function Gdb:make_ref(t)
  local id = self.next_ref
  self.next_ref = id + 1
  self.refs[id] = t
  return id
end

---Forgets the references of the stop before (the session calls it as it
---stops again), deleting their varobjs.
function Gdb:new_stop()
  self.refs = {}
  local varobjs = self.varobjs
  self.varobjs = {}
  for _, name in ipairs(varobjs) do self:send("-var-delete " .. name) end
end

---A frame's scopes: { name, ref }.
function Gdb:scopes(thread_id, level)
  return {
    { name = "Arguments", ref = self:make_ref({ kind = "scope", thread = thread_id, level = level, args = true }) },
    { name = "Locals", ref = self:make_ref({ kind = "scope", thread = thread_id, level = level, args = false }) },
  }
end

local function has_children(v)
  return (tonumber(v.numchild) or 0) > 0 or v.has_more == "1"
end

-- a variable from a varobj's fields
function Gdb:variable(name, v, ref_info)
  local var = { name = name, value = v.value, type = v.type }
  if has_children(v) then var.ref = self:make_ref(ref_info) end
  return var
end

---An expression as a variable with its own varobj, in a frame: a struct's or
---array's value is its contents, as gdb prints them, rather than "{...}".
---@return debug.variable?
---@return string? error
function Gdb:root_variable(expression, thread_id, level)
  local created, err = self:ask("-var-create" .. thread_frame(thread_id, level) .. " - * " .. mi.quote(expression))
  if not created then
    -- its message says only that it couldn't; evaluating says why
    local _, why = self:evaluate(expression, thread_id, level)
    return nil, why or err
  end
  table.insert(self.varobjs, created.name)
  local var = self:variable(expression, created, { kind = "var", varobj = created.name })
  if var.value and (var.value:find("^{%.%.%.}$") or var.value:find("^%[%d+%]$") or var.value == "") then
    local value, why = self:evaluate(expression, thread_id, level)
    if value then
      var.value = value
    elseif var.value == "" then
      -- unreadable (an uninitialized pointer's target): why
      return nil, why
    end
  end
  return var
end

---An expression to watch, as a variable that unfolds.
function Gdb:watch(expression, thread_id, level)
  return self:root_variable(expression, thread_id, level)
end

---The threads, each with its innermost frame.
---@return debug.thread[]?
function Gdb:threads()
  local res, err = self:ask("-thread-info")
  if not res then return nil, err end
  local threads = {}
  for _, t in ipairs(res.threads or {}) do
    table.insert(threads, { id = tonumber(t.id), name = t.name, target_id = t["target-id"], frame = frame_of(t.frame) })
  end
  return threads
end

---A scope's or a variable's variables: { name, value, type, ref (if it has
---children) }.
---@param ref integer
---@return debug.variable[]?
---@return string? error
function Gdb:variables(ref)
  local t = self.refs[ref]
  if not t then return nil, "stale reference" end
  local vars = {}
  if t.kind == "scope" then
    local res, err = self:ask("-stack-list-variables" .. thread_frame(t.thread, t.level) .. " --no-values")
    if not res then return nil, err end
    for _, v in ipairs(res.variables or {}) do
      if (v.arg == "1") == t.args then
        table.insert(vars, self:root_variable(v.name, t.thread, t.level) or { name = v.name, value = "<unavailable>" })
      end
    end
  else
    local function list(varobj)
      local res, err = self:ask("-var-list-children --all-values " .. mi.quote(varobj) .. " 0 " .. MAX_CHILDREN)
      if not res then return nil, err end
      for _, c in ipairs(res.children or {}) do
        -- C++'s access specifiers are pseudo-children: list what's in them
        if not c.type and (c.exp == "public" or c.exp == "private" or c.exp == "protected") then
          list(c.name)
        else
          table.insert(vars, self:variable(c.exp, c, { kind = "var", varobj = c.name }))
        end
      end
      if res.has_more == "1" then table.insert(vars, { name = "...", value = "more not shown" }) end
      return true
    end
    local ok, err = list(t.varobj)
    if not ok then return nil, err end
  end
  return vars
end

---The lines of the function a frame is in: its file, first and last line
---with code (from its disassembly, mixed with the source lines). Lines of
---functions inlined into it, in other files, aren't counted.
---@return string? file absolute
---@return integer? first
---@return integer? last
function Gdb:function_lines(thread_id, level)
  local res, err = self:ask("-data-disassemble" .. thread_frame(thread_id, level) .. " -a $pc -- 4")
  if not res then return nil, err end
  local frame = self:ask("-stack-info-frame" .. thread_frame(thread_id, level))
  local file = frame and frame.frame and frame.frame.fullname
  if not file then return nil, "no source" end
  local first, last
  for _, src in ipairs(res.asm_insns or {}) do
    local line = tonumber(src.line)
    if line and src.fullname == file then
      first, last = math.min(first or line, line), math.max(last or line, line)
    end
  end
  if not first then return nil, "no lines" end
  return file, first, last
end

---An expression's value in a frame.
function Gdb:evaluate(expression, thread_id, level)
  local res, err = self:ask("-data-evaluate-expression" .. thread_frame(thread_id, level) .. " " .. mi.quote(expression))
  if not res then return nil, err end
  return res.value
end

return Gdb
