local core = require "core"
local storage = require "core.storage"

---Watch expressions, in order, kept per project (core.storage).
local watches = {}

local list = {}
local project

---Counts changes (a view showing them is out of date when it differs).
watches.version = 0

local function key() return "watches-" .. project end

local function changed()
  watches.version = watches.version + 1
  storage.save("debug", key(), list)
end

---Loads the project's watches (the project changed).
function watches.load()
  if project == core.project_dir then return end
  project = core.project_dir
  local t = storage.load("debug", key())
  list = {}
  for _, e in ipairs(type(t) == "table" and t or {}) do
    if type(e) == "string" then table.insert(list, e) end
  end
  watches.version = watches.version + 1
end

---The expressions.
---@return string[]
function watches.list()
  watches.load()
  return list
end

function watches.add(expression)
  watches.load()
  table.insert(list, expression)
  changed()
end

function watches.set(index, expression)
  watches.load()
  if not list[index] then return end
  list[index] = expression
  changed()
end

function watches.remove(index)
  watches.load()
  if not list[index] then return end
  table.remove(list, index)
  changed()
end

return watches
