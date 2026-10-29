local core = require "core"
local common = require "core.common"
local build = require "plugins.build"
local config = require "core.config"

local cmake = {}

local function get_build_directory(target)
  return target.build_directory or core.root_project().path .. PATHSEP .. (target.build_directory or ("build-" .. target.name:lower():gsub("%W+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")))
end

-- the build type as CMake names it: Debug, Release
local function config_name(target)
  local buildtype = target.buildtype or "debug"
  return buildtype:sub(1, 1):upper() .. buildtype:sub(2)
end

function cmake.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "CMakeLists.txt") and {
    { name = "debug", buildtype = "debug" },
    { name = "release", buildtype = "release" }
  }
end

function cmake.build(target, callback)
  local bd = get_build_directory(target)

  local function run_build(status)
    if status ~= 0 then return callback(status) end
    -- --config for multi-config generators (Visual Studio's, the default on
    -- Windows), which ignore CMAKE_BUILD_TYPE; --parallel for any build tool
    local cmd = { "cmake", "--build", bd, "--config", config_name(target), "--parallel", tostring(build.threads) }
    -- a CMake target (the target's name is the build type's, not one)
    if target.target then
      table.insert(cmd, "--target")
      table.insert(cmd, target.target)
    end
    -- the paths in the messages of the build tool it runs are relative to it
    cmd.cwd = bd
    build.run_command(cmd, callback)
  end

  if not system.get_file_info(bd .. PATHSEP .. "CMakeCache.txt") then
    common.mkdirp(bd)
    build.run_command({ "cmake", "-B" .. bd, "-S" .. core.root_project().path, "-DCMAKE_BUILD_TYPE=" .. (target.buildtype or "debug") }, run_build)
  else
    run_build(0)
  end
end


function cmake.clean(target, callback)
  local bd = get_build_directory(target)
  build.run_command({ "cmake", "--build", bd, "--config", config_name(target), "--target", "clean" }, callback)
end


return cmake
