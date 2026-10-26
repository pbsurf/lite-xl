local core = require "core"
local build = require "plugins.build"

local backend = { }

function backend.build(target, callback)
  build.run_command(target.build, callback)
end


function backend.clean(target, callback)
  build.run_command(target.clean, callback)
end

return backend
