local core = require "core"
local build = require "plugins.build"

local gradle = { }


function gradle.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "gradlew") and { 
    { name = "build" }
  }
end

function gradle.can_build(target) return target.task ~= "executable" end
function gradle.can_run(target) return target.task == "executable" end
function gradle.run(target)
  return build.get_run_command(target, "./gradlew", { target.name })
end
function gradle.build(target, callback)
  build.run_command({ "./gradlew", target.name }, callback)
end


function gradle.clean(target, callback)
  build.run_command({ "./gradlew", "clean" }, callback)
end


return gradle
