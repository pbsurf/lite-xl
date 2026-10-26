local core = require "core"
local common = require "core.common"
local build = require "plugins.build"
local config = require "core.config"

local cmake = {}

local function get_build_directory(target)
  return target.build_directory or core.root_project().path .. PATHSEP .. (target.build_directory or ("build-" .. target.name:lower():gsub("%W+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")))
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
    local cmd = { "cmake", "--build", bd}
    if target.name then
        table.insert(cmd, "--target")
        table.insert(cmd, target.name)
    end
    table.insert(cmd, "--")
    table.insert(cmd, "-j")
    table.insert(cmd, build.threads)
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
  build.run_command({ "cmake", "--build", bd, "--target", "clean" }, callback)
end


return cmake
