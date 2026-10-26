local core = require "core"
local build = require "plugins.build"

local make = { }


function make.infer()
  return system.get_file_info(core.root_project().path .. PATHSEP .. "Makefile") and { { name = "all" } }
end

function make.build(target, callback)
  build.run_command({ "make", target.name, "-j", tostring(build.threads) }, callback)
end


function make.clean(target, callback)
  build.run_command({ "make", "clean" }, callback)
end


return make
