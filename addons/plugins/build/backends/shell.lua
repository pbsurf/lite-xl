local core = require "core"
local build = require "plugins.build"

local shell = { }

--[[
target.runner_name = name of runner     (default = sh; cmd for a .bat or .cmd)
target.script_name = path to script     (default = build.sh; on Windows build.bat or build.cmd if there's one)
target.args_build  = list of build args (default = )
target.args_clean  = list of clean args (default = clean)
]]

-- the Windows batch files found, before build.sh
local batch_files = PLATFORM == "Windows" and { "build.bat", "build.cmd" } or {}

local function find_script()
  for _, name in ipairs(batch_files) do
    if system.get_file_info(core.root_project().path .. PATHSEP .. name) then return name end
  end
  return system.get_file_info(core.root_project().path .. PATHSEP .. "build.sh") and "build.sh"
end

local function get_script_name(target)
    return target.command or find_script() or "build.sh"
end
local function get_runner_name(target)
    return target.runner or "sh"
end
local function get_args_clean(target)
    return table.unpack(target.args_clean or {"clean"})
end
local function get_args_build(target)
    return table.unpack(target.arguments or target.args_build or {})
end

-- the command running the script with arguments: a batch file by cmd (it
-- can't run otherwise), anything else by the runner
local function script_command(target, ...)
  local script = get_script_name(target)
  local extension = script:lower():match("%.(%w+)$")
  if not target.runner and (extension == "bat" or extension == "cmd") then
    local line = { build.shell_quote(core.root_project():absolute_path(script)) }
    for _, arg in ipairs({ ... }) do table.insert(line, build.shell_quote(arg)) end
    return build.shell_command(table.concat(line, " "))
  end
  return { get_runner_name(target), script, ... }
end

function shell.infer()
  return find_script() and {
    { name = "debug", arguments = { "-g" } },
    { name = "release" }
  }
end

function shell.build(target, callback)
  build.run_command(script_command(target, get_args_build(target)), callback)
end


function shell.clean(target, callback)
  build.run_command(script_command(target, get_args_clean(target)), callback)
end


return shell
