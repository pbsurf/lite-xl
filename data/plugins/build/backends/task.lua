local core = require "core"
local build = require "plugins.build"

local backend = { }

--local function grep(t, cond) local nt = {} for i,v in ipairs(t) do if cond(v, i) then table.insert(nt, v) end end return nt end

--function backend.infer()
--  return system.get_file_info("Makefile") and { name = "all" }
--end

function backend.build(target, callback)
  build.run_tasks({ target.build }, callback)  --function(status)
  --  local filtered_messages = grep(build.message_view.messages, function(v) return type(v) == 'table' and v[1] == "error" end)
  --  if callback then callback(status == 0 and #filtered_messages or 1) end
  --end)
end


function backend.clean(target, callback)
  build.run_tasks({ target.clean }, callback)
end

return backend
