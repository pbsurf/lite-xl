-- Targets from VS Code's .vscode/tasks.json and .vscode/launch.json: one per
-- launch configuration (request "launch"), building with its preLaunchTask
-- and running its program (debuggable with the debugger plugin for the native
-- types: cppdbg, gdb, lldb), then one per task, build only.
--
-- Supported: JSON with comments and trailing commas; the "linux"/"osx"/
-- "windows" overrides; tasks of type shell (a command line, run by $SHELL -c
-- or options.shell) and process/cppbuild (run directly), with options.cwd and
-- options.env (over tasks.json's top-level options), dependsOn (run in
-- sequence); launch configurations' program, args, cwd, environment (or env)
-- and setupCommands, or a command (node-terminal), run in a terminal. Errors
-- are found by build's gcc-style parser (as "$gcc"), with paths relative to
-- the task's cwd. Variables: ${workspaceFolder}, ${workspaceFolderBasename},
-- ${file}, ${relativeFile}, ${fileBasename}, ${fileBasenameNoExtension},
-- ${fileDirname}, ${fileExtname}, ${lineNumber}, ${selectedText}, ${cwd},
-- ${userHome}, ${pathSeparator}, ${env:NAME}.
--
-- Not supported: other problemMatchers, background tasks, presentation,
-- dependsOrder "parallel", compound and attach configurations, stopAtEntry.
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local build = require "plugins.build"
local json = require "libraries.json"

local vscode = { priority = -1 }

local PLATFORM_KEY = PLATFORM == "Windows" and "windows" or PLATFORM == "Mac OS X" and "osx" or "linux"
-- launch configuration types debugged with gdb
local DEBUGGABLE = { cppdbg = true, gdb = true, lldb = true }

---Removes comments and trailing commas (outside strings) from JSON with
---comments, as VS Code's settings files allow.
---@param text string
---@return string
function vscode.strip_jsonc(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == '"' then
      local j = i + 1
      while j <= n do
        local d = text:sub(j, j)
        if d == "\\" then j = j + 1 elseif d == '"' then break end
        j = j + 1
      end
      table.insert(out, text:sub(i, j))
      i = j + 1
    elseif text:sub(i, i + 1) == "//" then
      i = (text:find("\n", i, true) or n + 1)
    elseif text:sub(i, i + 1) == "/*" then
      local _, e = text:find("*/", i + 2, true)
      -- its line breaks kept, so that errors give the right line
      table.insert(out, (text:sub(i, e or n):gsub("[^\n]", "")))
      i = (e or n) + 1
    elseif c == "," then
      -- a comma before a closing bracket, past whitespace and comments
      local j = i + 1
      while j <= n do
        local s = text:match("^%s+", j)
        if s then j = j + #s
        elseif text:sub(j, j + 1) == "//" then j = (text:find("\n", j, true) or n + 1)
        elseif text:sub(j, j + 1) == "/*" then j = (select(2, text:find("*/", j + 2, true)) or n) + 1
        else break end
      end
      if not text:sub(j, j):match("[%]}]") then table.insert(out, c) end
      i = i + 1
    else
      local j = text:find('["/,]', i) or n + 1
      table.insert(out, text:sub(i, j - 1))
      i = j
    end
  end
  return table.concat(out)
end

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local ok, result = pcall(json.decode, vscode.strip_jsonc(text))
  if not ok then
    core.error("Can't read %s: %s", path, (tostring(result):gsub("^.-:%d+: ", "")))
    return nil
  end
  return result
end

-- the platform's overrides ("linux": {...}) applied; options merged a level deeper
local function for_platform(t)
  local over = type(t[PLATFORM_KEY]) == "table" and t[PLATFORM_KEY] or {}
  local r = common.merge(t, over)
  if t.options or over.options then
    r.options = common.merge(t.options, over.options)
    r.options.env = common.merge(t.options and t.options.env, over.options and over.options.env)
  end
  return r
end

-- the doc of the last docview active, for ${file} and the like
local function current_docview()
  local view = core.active_view
  if not (view and view.doc and view.doc.abs_filename) then view = core.last_active_view end
  return view and view.doc and view.doc.abs_filename and view
end

---Replaces VS Code's variables in a string (or the strings of a list).
---Raises an error for an unknown or unsupported one.
---@param value any
---@return any
function vscode.substitute(value)
  if type(value) == "table" then
    local t = {}
    for k, v in pairs(value) do t[k] = vscode.substitute(v) end
    return t
  end
  if type(value) ~= "string" then return value end
  local root = core.root_project().path
  return (value:gsub("%${([^}]*)}", function(name)
    local env = name:match("^env:(.*)")
    if env then return os.getenv(env) or "" end
    if name == "workspaceFolder" or name == "workspaceRoot" then return root end
    if name == "workspaceFolderBasename" then return common.basename(root) end
    if name == "cwd" then return root end
    if name == "userHome" then return os.getenv("HOME") or "" end
    if name == "pathSeparator" or name == "/" then return PATHSEP end
    local file_vars = {
      file = true, relativeFile = true, fileBasename = true, fileBasenameNoExtension = true,
      fileDirname = true, fileExtname = true, lineNumber = true, selectedText = true,
    }
    if file_vars[name] then
      local view = current_docview()
      if not view then error("${" .. name .. "}: no file is open", 0) end
      local file = view.doc.abs_filename
      local base = common.basename(file)
      if name == "file" then return file end
      if name == "relativeFile" then return common.relative_path(root, file) end
      if name == "fileBasename" then return base end
      if name == "fileBasenameNoExtension" then return (base:gsub("%.[^.]*$", "")) end
      if name == "fileDirname" then return common.dirname(file) end
      if name == "fileExtname" then return base:match("%.[^.]*$") or "" end
      local line1, col1, line2, col2 = view.doc:get_selection()
      if name == "lineNumber" then return tostring(line1) end
      return view.doc:get_text(line1, col1, line2, col2)
    end
    error("unsupported variable ${" .. name .. "}", 0)
  end))
end

local function shell_quote(s)
  if s:match("^[%w%-%._/=:,@+]+$") then return s end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function absolute(path)
  return common.normalize_path(common.is_absolute_path(path) and path or core.root_project().path .. PATHSEP .. path)
end

-- the tasks of tasks.json by label, in order, and its top-level options
local function load_tasks(root)
  local doc = read_json(root .. PATHSEP .. ".vscode" .. PATHSEP .. "tasks.json")
  local list = {}
  if not doc or type(doc.tasks) ~= "table" then return list, {} end
  doc = for_platform(doc)
  for _, task in ipairs(doc.tasks) do
    if type(task) == "table" then
      task = for_platform(task)
      task.label = task.label or task.taskName or (task.type and task.command and task.type .. ": " .. task.command)
      if task.label then table.insert(list, task) end
    end
  end
  return list, doc.options or {}
end

---The command to run a task, with `cwd` and `env` fields for build.run_tasks.
local function task_command(task, defaults)
  local options = common.merge(defaults, task.options)
  options.env = common.merge(defaults.env, task.options and task.options.env)
  local command = vscode.substitute(task.command)
  local args = vscode.substitute(task.args or {})
  if type(command) ~= "string" then error("task \"" .. task.label .. "\" has no command", 0) end
  local cmd
  if task.type == "shell" or task.type == nil then
    local line = { command }
    for _, arg in ipairs(args) do
      table.insert(line, type(arg) == "table" and shell_quote(tostring(arg.value)) or shell_quote(tostring(arg)))
    end
    local shell = options.shell or {}
    cmd = { shell.executable or os.getenv("SHELL") or "/bin/sh" }
    for _, arg in ipairs(shell.args or { "-c" }) do table.insert(cmd, arg) end
    table.insert(cmd, table.concat(line, " "))
  else
    cmd = { command }
    for _, arg in ipairs(args) do
      table.insert(cmd, type(arg) == "table" and tostring(arg.value) or tostring(arg))
    end
  end
  cmd.cwd = absolute(vscode.substitute(options.cwd or "${workspaceFolder}"))
  cmd.env = vscode.substitute(options.env)
  return cmd
end

-- the task and those it depends on, in the order to run them
local function task_sequence(tasks, label)
  local by_label = {}
  for _, task in ipairs(tasks) do by_label[task.label] = task end
  local sequence, visiting, done = {}, {}, {}
  local function visit(name)
    if done[name] then return end
    local task = by_label[name]
    if not task then error("no task \"" .. name .. "\" in tasks.json", 0) end
    if visiting[name] then error("task \"" .. name .. "\" depends on itself", 0) end
    visiting[name] = true
    local deps = task.dependsOn
    if type(deps) == "string" then deps = { deps } end
    for _, dep in ipairs(deps or {}) do
      visit(type(dep) == "table" and dep.label or dep)
    end
    done[name] = true
    if task.command then table.insert(sequence, task) end
  end
  visit(label)
  return sequence
end


function vscode.infer()
  local root = core.root_project().path
  local tasks = load_tasks(root)
  local targets = {}

  local launch = read_json(root .. PATHSEP .. ".vscode" .. PATHSEP .. "launch.json")
  for _, config in ipairs(launch and type(launch.configurations) == "table" and launch.configurations or {}) do
    config = type(config) == "table" and for_platform(config)
    if config and config.name and (config.request or "launch") == "launch" then
      local ok, err = pcall(function()
        local target = { name = config.name, info = "launch", task = config.preLaunchTask }
        target.wd = config.cwd and absolute(vscode.substitute(config.cwd))
        local env = {}
        for _, var in ipairs(config.environment or {}) do
          if var.name then env[var.name] = vscode.substitute(var.value or "") end
        end
        for name, value in pairs(config.env or {}) do env[name] = vscode.substitute(value) end
        target.env = next(env) and env or nil
        if DEBUGGABLE[config.type] and config.program then
          target.binary = absolute(vscode.substitute(config.program))
          target.binary_arguments = vscode.substitute(config.args or {})
          local commands = {}
          for _, c in ipairs(config.setupCommands or {}) do
            if c.text then table.insert(commands, c.text) end
          end
          target.debugger_commands = commands
        elseif config.program then
          target.command = shell_quote(absolute(vscode.substitute(config.program)))
          for _, arg in ipairs(vscode.substitute(config.args or {})) do
            target.command = target.command .. " " .. shell_quote(arg)
          end
        elseif config.command then
          target.command = vscode.substitute(config.command)
        end
        table.insert(targets, target)
      end)
      if not ok then core.error("launch.json, \"%s\": %s", config.name, err) end
    end
  end

  for _, task in ipairs(tasks) do
    table.insert(targets, { name = task.label, info = "task", task = task.label })
  end
  return targets
end


function vscode.can_build(target) return target.task ~= nil end

function vscode.build(target, callback)
  local root = core.root_project().path
  local tasks, defaults = load_tasks(root)
  local sequence = task_sequence(tasks, target.task)
  local commands = {}
  for _, task in ipairs(sequence) do table.insert(commands, task_command(task, defaults)) end
  local i = 0
  local function next_task(status)
    if status ~= 0 or i == #commands then
      local errors = 0
      for _, v in ipairs(build.message_view.messages) do
        if type(v) == "table" and v[1] == "error" then errors = errors + 1 end
      end
      if callback then callback(status == 0 and errors or math.max(errors, 1)) end
      return
    end
    i = i + 1
    local cwd = commands[i].cwd
    build.run_tasks({ commands[i] }, next_task, function(line)
      local message = build.parse_compile_line(line)
      -- a path relative to the task's directory: relative to the project's if in it
      if type(message) == "table" and not common.is_absolute_path(message[2]) then
        local file = common.normalize_path(cwd .. PATHSEP .. message[2])
        message[2] = common.path_belongs_to(file, root) and common.relative_path(root, file) or file
      end
      build.message_view:add_message(message)
    end)
  end
  next_task(0)
end


function vscode.can_run(target) return target.binary ~= nil or target.command ~= nil end

function vscode.run(target)
  if target.command then
    build.execute_command(build.get_shell_command(target, target.command, nil, true))
  else
    build.execute_command(build.get_shell_command(target, config.target_binary or target.binary))
  end
end


return vscode
