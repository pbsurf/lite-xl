local core = require "core"
local common = require "core.common"
local build = require "plugins.build"
local config = require "core.config"
local json = require "libraries.json"

-- ninja's messages have paths relative to the build directory, which build
-- finds from its "Entering directory"
local meson = {}

local function get_build_directory(target)
  return target.build_directory or core.root_project().path .. PATHSEP .. (target.build_directory or ("build-" .. target.name:lower():gsub("%W+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")))
end

function meson.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "meson.build") and {
    { name = "debug" },
    { name = "release", buildtype = "release" }
  }
end

-- a command's output, read to the end
local function read_command(args)
  local proc = process.start(args)
  local accumulator = ""
  while true do
    local chunk = proc:read_stdout(4096)
    if not chunk or (chunk == "" and not proc:running()) then break end
    accumulator = accumulator .. chunk
    coroutine.yield()
  end
  local status = proc:returncode()
  if status ~= 0 then error(proc:read_stderr(4096)) end
  return accumulator
end

function meson.build(target, callback)
  local bd = get_build_directory(target)

  -- the executable built by default is the target's binary
  local check_executables = function()
    local info = json.decode(read_command({ "meson", "introspect", bd, "-a" }))
    for i,v in ipairs(info.targets) do
      if v.build_by_default and v.type == "executable" and v.filename then
        target.binary = v.filename[1]
        config.target_binary = target.binary
        target.wd = common.dirname(target.binary)
      end
    end
    target.checked = true
  end

  local ninja_build = function(status)
    if status ~= 0 then return callback(status) end
    if not target.checked then check_executables() end
    build.run_command({ "ninja", "-C", bd }, callback)
  end

  if not system.get_file_info(bd .. PATHSEP .. "build.ninja") then
    build.run_command({ "meson", "setup", bd, "--buildtype", target.buildtype or "debug" }, ninja_build)
  else
    ninja_build(0)
  end
end


function meson.clean(target, callback)
  if system.get_file_info(get_build_directory(target)) then common.rm(get_build_directory(target), true) end
  callback(0)
end


return meson
