local core = require "core"
local common = require "core.common"
local storage = require "core.storage"
local Doc = require "core.doc"

---Breakpoints: lines of files, enabled or not, with an optional condition
---(an expression: stops only where it's true) and hit count (stops from that
---hit on), kept per project (core.storage), following edits (lines inserted
---or removed above one move it). Changes are reported to breakpoints.on_change(file), which the session
---uses to update the debugger's (which has only the enabled ones), and counted
---in breakpoints.version, for views listing them.
local breakpoints = {}

---@class debug.breakpoint
---@field enabled boolean
---@field condition? string
---@field hit_count? integer stops from this hit on (the ones before are ignored)

-- absolute filename -> line -> debug.breakpoint
local files = {}
local project

---Called with a file whose breakpoints changed.
---@type fun(file: string)
breakpoints.on_change = function(file) end

---Counts changes (a view showing them is out of date when it differs).
breakpoints.version = 0

local function key() return "breakpoints-" .. project end

local function save()
  local t = {}
  for file, lines in pairs(files) do
    if next(lines) then t[file] = lines end
  end
  storage.save("debug", key(), t)
end

local function changed(file)
  breakpoints.version = breakpoints.version + 1
  save()
  breakpoints.on_change(file)
end

---Loads the project's breakpoints (the project changed).
function breakpoints.load()
  if project == core.project_dir then return end
  project = core.project_dir
  files = {}
  breakpoints.version = breakpoints.version + 1
  local t = storage.load("debug", key())
  for file, lines in pairs(type(t) == "table" and t or {}) do
    files[file] = {}
    for line, bp in pairs(lines) do
      -- once just whether it was enabled
      if type(bp) ~= "table" then bp = { enabled = bp == true } end
      files[file][line] = {
        enabled = bp.enabled == true,
        condition = type(bp.condition) == "string" and bp.condition ~= "" and bp.condition or nil,
        hit_count = math.type(bp.hit_count) == "integer" and bp.hit_count > 1 and bp.hit_count or nil,
      }
    end
  end
end

---Whether there's a breakpoint (enabled or not) on a line.
---@param file string
---@param line integer
function breakpoints.has(file, line)
  local lines = files[file]
  return lines ~= nil and lines[line] ~= nil
end

---Whether a line's breakpoint is enabled.
function breakpoints.enabled(file, line)
  local lines = files[file]
  return lines ~= nil and lines[line] ~= nil and lines[line].enabled
end

---A line's breakpoint (a copy), nil if there's none.
---@return debug.breakpoint?
function breakpoints.get(file, line)
  local bp = files[file] and files[file][line]
  return bp and { enabled = bp.enabled, condition = bp.condition, hit_count = bp.hit_count }
end

---Whether a breakpoint stops only sometimes: it has a condition or hit count.
function breakpoints.is_conditional(file, line)
  local bp = files[file] and files[file][line]
  return bp ~= nil and (bp.condition ~= nil or bp.hit_count ~= nil)
end

---A file's breakpoints' lines, in order; only the enabled ones if `enabled`.
---@param file string
---@param enabled? boolean
---@return integer[]
function breakpoints.lines(file, enabled)
  local list = {}
  for line, bp in pairs(files[file] or {}) do
    if bp.enabled or not enabled then table.insert(list, line) end
  end
  table.sort(list)
  return list
end

---A file's enabled breakpoints, by line, for the debugger.
---@return { line: integer, condition?: string, hit_count?: integer }[]
function breakpoints.specs(file)
  local list = {}
  for _, line in ipairs(breakpoints.lines(file, true)) do
    local bp = files[file][line]
    table.insert(list, { line = line, condition = bp.condition, hit_count = bp.hit_count })
  end
  return list
end

---The files with breakpoints.
---@return string[]
function breakpoints.files()
  local list = {}
  for file, lines in pairs(files) do
    if next(lines) then table.insert(list, file) end
  end
  table.sort(list)
  return list
end

---Sets (enabled) or clears a breakpoint.
---@param file string
---@param line integer
---@param on boolean
function breakpoints.set(file, line, on)
  breakpoints.load()
  files[file] = files[file] or {}
  if breakpoints.has(file, line) == on then return end
  if on then files[file][line] = { enabled = true } else files[file][line] = nil end
  changed(file)
end

-- a line's breakpoint, and whether it's new: one is set (enabled) if there's none
local function get_or_add(file, line)
  breakpoints.load()
  files[file] = files[file] or {}
  if files[file][line] then return files[file][line], false end
  files[file][line] = { enabled = true }
  return files[file][line], true
end

---Sets a breakpoint's condition (nil or "" for none), setting the breakpoint
---(enabled) if there's none.
---@param condition? string
function breakpoints.set_condition(file, line, condition)
  if condition and not condition:find("%S") then condition = nil end
  local bp, new = get_or_add(file, line)
  if bp.condition == condition and not new then return end
  bp.condition = condition
  changed(file)
end

---Sets the hit a breakpoint stops from (nil or 1 for every hit), setting the
---breakpoint (enabled) if there's none.
---@param count? integer
function breakpoints.set_hit_count(file, line, count)
  if count and count <= 1 then count = nil end
  local bp, new = get_or_add(file, line)
  if bp.hit_count == count and not new then return end
  bp.hit_count = count
  changed(file)
end

function breakpoints.toggle(file, line)
  breakpoints.set(file, line, not breakpoints.has(file, line))
end

---Enables or disables a breakpoint.
function breakpoints.set_enabled(file, line, enabled)
  if not breakpoints.has(file, line) or files[file][line].enabled == enabled then return end
  files[file][line].enabled = enabled
  changed(file)
end

---Moves a breakpoint (the debugger put it on another line).
function breakpoints.move(file, from, to)
  if from == to or not breakpoints.has(file, from) then return end
  files[file][to] = files[file][from]
  files[file][from] = nil
  breakpoints.version = breakpoints.version + 1
  save()
end

function breakpoints.clear_all()
  local list = breakpoints.files()
  files = {}
  for _, file in ipairs(list) do changed(file) end
  if #list == 0 then save() end
end

-- Following edits: lines after an insertion of n lines move down by n; a
-- removal moves those after it up, and those in it to its first line.
local function shift(doc, line1, line2, delta)
  local lines = doc.abs_filename and files[doc.abs_filename]
  if not lines or not next(lines) or delta == 0 then return end
  local moved = {}
  for line, bp in pairs(lines) do
    local to = line
    if line > line2 then
      to = line + delta
    elseif delta < 0 and line > line1 then
      to = line1
    end
    moved[to] = moved[to] or bp
  end
  files[doc.abs_filename] = moved
  breakpoints.version = breakpoints.version + 1
  doc.debug_breakpoints_moved = true
end

local raw_insert, raw_remove = Doc.raw_insert, Doc.raw_remove
function Doc:raw_insert(line, col, text, ...)
  local before = #self.lines
  raw_insert(self, line, col, text, ...)
  -- text inserted at a line's start pushes it down too
  shift(self, col == 1 and line - 1 or line, col == 1 and line - 1 or line, #self.lines - before)
end

function Doc:raw_remove(line1, col1, line2, col2, ...)
  raw_remove(self, line1, col1, line2, col2, ...)
  shift(self, line1, line2, -(line2 - line1))
end

-- saved with the doc: the debugger's lines are the file's as built
local doc_save = Doc.save
function Doc:save(...)
  local res = doc_save(self, ...)
  if self.debug_breakpoints_moved and self.abs_filename then
    self.debug_breakpoints_moved = nil
    changed(self.abs_filename)
  end
  return res
end

return breakpoints
