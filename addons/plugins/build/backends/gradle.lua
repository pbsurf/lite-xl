local core = require "core"
local build = require "plugins.build"

local gradle = { }

-- On Windows the wrapper is gradlew.bat, run by cmd: a command line running it
local function gradlew_bat(...)
  local line = { build.shell_quote(core.root_project():absolute_path("gradlew.bat")) }
  for _, arg in ipairs({ ... }) do table.insert(line, build.shell_quote(arg)) end
  return table.concat(line, " ")
end

-- the command running the gradle wrapper with arguments
local function gradlew(...)
  if PLATFORM == "Windows" then return build.shell_command(gradlew_bat(...)) end
  return { "./gradlew", ... }
end

function gradle.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "gradlew") and { 
    { name = "build" }
  }
end

function gradle.can_build(target) return target.task ~= "executable" end
function gradle.can_run(target) return target.task == "executable" end
function gradle.run(target)
  if PLATFORM == "Windows" then return build.get_run_command(target, gradlew_bat(target.name), nil, true) end
  return build.get_run_command(target, "./gradlew", { target.name })
end
function gradle.build(target, callback)
  build.run_command(gradlew(target.name), callback)
end


function gradle.clean(target, callback)
  build.run_command(gradlew("clean"), callback)
end


return gradle
