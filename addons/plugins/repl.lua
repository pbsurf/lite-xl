-- mod-version:3
--
-- repl: evaluate Lua sent from outside the editor (client: scripts/lxeval).
--
-- Requests are files req-<id>.lua in $XDG_RUNTIME_DIR/lite-xl-<pid>/, and each reply
-- is written to resp-<id>.  Requests are picked up every 10ms by a core thread.  While
-- the window is unfocused and idle, lite-xl blocks in system.wait_event() with no
-- timeout and threads don't run, so the directory is also watched with a dirmonitor,
-- whose inotify thread wakes the event loop when a request arrives.
--
-- If Lua is stuck in a loop, that thread never runs.  For that case every coroutine
-- has a count hook registered but not armed (an armed hook roughly halves the speed
-- of Lua code); `lxeval -g` arms it from gdb with lua_sethook(), which Lua allows at
-- any time.  The hook then services requests from inside the stuck code, where
-- `_where` is a traceback of the stuck code and `_locals` its locals, and abort()
-- raises an error in the stuck code once the request is done: a stuck core thread
-- dies (logged) and the editor recovers; in the main thread, it ends lite-xl like
-- any other uncaught error.  The hook disarms itself once the editor is unstuck.
-- config.plugins.repl.always_armed keeps it armed instead, at that cost.
--
-- Code is tried as an expression first, then as a chunk.  Return values are shown
-- with inspect(value, depth); print() output is captured.  Names resolve to globals,
-- then to loaded modules (`core`, `style`, `config.plugins`..., `lsp`, `treeview`: tried
-- as NAME, core.NAME and plugins.NAME).  Globals assigned by evaluated code persist in
-- the repl environment between requests.
local core = require "core"
local common = require "core.common"
local config = require "core.config"

config.plugins.repl = common.merge({
  -- seconds without the polling thread running before the hook takes over
  stall = 0.5,
  -- keep the hook armed (see above) rather than arming it from gdb when needed
  always_armed = false,
}, config.plugins.repl)

local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
local pid
do
  local f = io.open("/proc/self/stat")
  if f then pid = f:read("n"); f:close() end
end
if not runtime_dir or not pid then
  core.warn("repl: needs $XDG_RUNTIME_DIR and /proc; disabled")
  return
end

-- remove directories left by lite-xl processes that are gone
for _, name in ipairs(system.list_dir(runtime_dir) or {}) do
  local other = name:match("^lite%-xl%-(%d+)$")
  if other and not system.get_file_info("/proc/" .. other) then
    local d = runtime_dir .. "/" .. name
    for _, f in ipairs(system.list_dir(d) or {}) do os.remove(d .. "/" .. f) end
    os.remove(d)
  end
end

local dir = runtime_dir .. "/lite-xl-" .. pid
system.mkdir(dir)


local function format_scalar(v)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "function" then
    local info = debug.getinfo(v, "S")
    if info.what == "C" then return "function: builtin" end
    return string.format("function: %s:%d", info.short_src, info.linedefined)
  end
  return tostring(v)
end

local function key_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta < tb end
  if ta == "number" or ta == "string" then return a < b end
  return tostring(a) < tostring(b)
end

---Pretty-print a value: tables to `depth` levels (default 2), at most
---`max_items` entries each (default 50), with cycles marked.
local function format(value, depth, max_items)
  max_items = max_items or 50
  local on_path = {}
  local function rec(v, d, indent)
    if type(v) ~= "table" then return format_scalar(v) end
    if on_path[v] then return "<cycle " .. tostring(v) .. ">" end
    -- objects (core.object) name their class via __tostring
    local label = ""
    local mt = getmetatable(v)
    if mt and mt.__tostring then
      local ok, s = pcall(tostring, v)
      if ok then label = " -- " .. s end
    end
    if d <= 0 then return "{...}" .. label end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    if #keys == 0 then return "{}" .. label end
    table.sort(keys, key_less)
    on_path[v] = true
    local lines = {}
    for i, k in ipairs(keys) do
      if i > max_items then
        lines[#lines + 1] = indent .. "  ... " .. (#keys - max_items) .. " more"
        break
      end
      local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k
                 or "[" .. format_scalar(k) .. "]"
      lines[#lines + 1] = indent .. "  " .. ks .. " = " .. rec(rawget(v, k), d - 1, indent .. "  ")
    end
    on_path[v] = nil
    return "{" .. label .. "\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "}"
  end
  return rec(value, depth or 2, "")
end

-- inspect() for evaluated code: returns the formatted text, wrapped so that
-- returning it shows the text as-is rather than as a quoted string
local formatted_mt = { __tostring = function(self) return self.text end }
local function inspect(value, depth, max_items)
  return setmetatable({ text = format(value, depth, max_items) }, formatted_mt)
end

local abort_requested = false

local env = setmetatable({
  inspect = inspect,
  abort = function() abort_requested = true end,
}, {
  __index = function(_, name)
    -- rawget: core.strict raises on undefined globals
    local v = rawget(_G, name)
    if v ~= nil then return v end
    return package.loaded[name] or package.loaded["core." .. name]
           or package.loaded["plugins." .. name]
  end
})

-- traceback without the repl's own frames
local function traceback(err)
  local tb = debug.traceback(tostring(err), 2)
  return (tb:gsub("\n%s*%[C%]: in function 'xpcall'.*$", ""))
end

local function evaluate(code, context)
  local output = {}
  env.print = function(...)
    local t = table.pack(...)
    for i = 1, t.n do t[i] = tostring(t[i]) end
    output[#output + 1] = table.concat(t, "\t")
  end
  env._where, env._locals = context and context.where, context and context.locals

  local fn, err = load("return " .. code, "=lxeval", "t", env)
  if not fn then fn, err = load(code, "=lxeval", "t", env) end
  if not fn then return "syntax error: " .. err end

  local results = table.pack(xpcall(fn, traceback))
  if not results[1] then
    output[#output + 1] = "error: " .. tostring(results[2])
  else
    for i = 2, results.n do
      local r = results[i]
      if getmetatable(r) == formatted_mt then r = r.text
      -- multi-line strings (tracebacks, file contents) read better unquoted
      elseif not (type(r) == "string" and r:find("\n")) then r = format(r) end
      output[#output + 1] = r
    end
  end
  return table.concat(output, "\n")
end

local servicing = false
local last_service = system.get_time()

local function service(context)
  servicing = true
  for _, name in ipairs(system.list_dir(dir) or {}) do
    local id = name:match("^req%-(.+)%.lua$")
    local f = id and io.open(dir .. "/" .. name, "rb")
    if f then
      local code = f:read("a")
      f:close()
      os.remove(dir .. "/" .. name)
      local ok, reply = pcall(evaluate, code, context)
      if not ok then reply = "error: repl: " .. tostring(reply) end
      local tmp = dir .. "/.resp-" .. id
      local out = io.open(tmp, "wb")
      if out then
        out:write(reply, "\n")
        out:close()
        os.rename(tmp, dir .. "/resp-" .. id)
      end
    end
  end
  servicing = false
end

-- wakes the event loop on changes in dir; check() below consumes the change (until
-- then the monitor thread keeps posting wake-up events)
local monitor = dirmonitor.new()
monitor:watch(dir)

core.add_thread(function()
  while true do
    monitor:check(function() end)
    last_service = system.get_time()
    local ok, err = pcall(service)
    abort_requested = false -- only meaningful while stuck
    if not ok then servicing = false; core.error("repl: %s", err) end
    coroutine.yield(0.01)
  end
end)


-- count used when the hook is armed here; lxeval -g arms with its own count
local ARMED_COUNT = 1000000
local last_check = 0

local function hook()
  if servicing then return end
  local now = system.get_time()
  if now - last_service < config.plugins.repl.stall then
    -- armed by lxeval -g, and no longer stuck
    if not config.plugins.repl.always_armed then debug.sethook(hook, "", 0) end
    return
  end
  if now - last_check < 0.05 then return end
  last_check = now
  -- level 2 is the function that was running when the hook fired
  local context = {
    where = debug.traceback(string.format("stuck for %.1fs", now - last_service), 2),
    locals = {}
  }
  for i = 1, math.huge do
    local name, value = debug.getlocal(2, i)
    if not name then break end
    -- skip internal slots: "(temporary)", "(for state)", ...
    if not name:match("^%(") then context.locals[name] = value end
  end
  pcall(service, context)
  servicing = false
  if abort_requested then
    abort_requested = false
    error("aborted by repl", 2)
  end
end

-- Register the hook for a coroutine (nil: the running one); armed only if always_armed.
local function register(co)
  local count = config.plugins.repl.always_armed and ARMED_COUNT or 0
  if co then debug.sethook(co, hook, "", count) else debug.sethook(hook, "", count) end
end

-- the main thread
register()
-- threads that already exist
for _, thread in pairs(core.threads) do register(thread.cr) end
-- core.run's run_threads is a coroutine.wrap() created before plugins load; the
-- coroutine is the first upvalue of the function wrap() returns
for i = 1, math.huge do
  local name, value = debug.getupvalue(core.run, i)
  if not name then break end
  if name == "run_threads" then
    local _, co = debug.getupvalue(value, 1)
    if type(co) == "thread" then register(co) end
  end
end
-- coroutines created from now on
local coroutine_create, coroutine_wrap = coroutine.create, coroutine.wrap
function coroutine.create(f)
  local co = coroutine_create(f)
  register(co)
  return co
end
function coroutine.wrap(f)
  -- wrap() keeps its coroutine private, so register from inside it
  return coroutine_wrap(function(...)
    register()
    return f(...)
  end)
end
