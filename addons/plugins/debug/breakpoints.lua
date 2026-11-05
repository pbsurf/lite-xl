local core = require "core"
local common = require "core.common"
local storage = require "core.storage"
local Doc = require "core.doc"

---Breakpoints: lines of files, kept per project (core.storage), following
---edits (lines inserted or removed above one move it). Changes are reported
---to breakpoints.on_change(file), which the session uses to update the
---debugger's.
local breakpoints = {}

-- absolute filename -> set of lines
local files = {}
local project

---Called with a file whose breakpoints changed.
---@type fun(file: string)
breakpoints.on_change = function(file) end

local function key() return "breakpoints-" .. project end

local function save()
  local t = {}
  for file, lines in pairs(files) do
    local list = breakpoints.lines(file)
    if #list > 0 then t[file] = list end
  end
  storage.save("debug", key(), t)
end

---Loads the project's breakpoints (the project changed).
function breakpoints.load()
  if project == core.project_dir then return end
  project = core.project_dir
  files = {}
  local t = storage.load("debug", key())
  for file, lines in pairs(type(t) == "table" and t or {}) do
    files[file] = {}
    for _, line in ipairs(lines) do files[file][line] = true end
  end
end

---@param file string
---@param line integer
function breakpoints.has(file, line)
  local lines = files[file]
  return lines ~= nil and lines[line] == true
end

---A file's breakpoints' lines, in order.
---@param file string
---@return integer[]
function breakpoints.lines(file)
  local list = {}
  for line in pairs(files[file] or {}) do table.insert(list, line) end
  table.sort(list)
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

---Sets or clears a breakpoint.
---@param file string
---@param line integer
---@param on boolean
function breakpoints.set(file, line, on)
  breakpoints.load()
  files[file] = files[file] or {}
  if (files[file][line] == true) == on then return end
  files[file][line] = on or nil
  save()
  breakpoints.on_change(file)
end

function breakpoints.toggle(file, line)
  breakpoints.set(file, line, not breakpoints.has(file, line))
end

---Moves a breakpoint (the debugger put it on another line).
function breakpoints.move(file, from, to)
  if from == to or not breakpoints.has(file, from) then return end
  files[file][from] = nil
  files[file][to] = true
  save()
end

function breakpoints.clear_all()
  local changed = breakpoints.files()
  files = {}
  save()
  for _, file in ipairs(changed) do breakpoints.on_change(file) end
end

-- Following edits: lines after an insertion of n lines move down by n; a
-- removal moves those after it up, and those in it to its first line.
local function shift(doc, line1, line2, delta)
  local lines = doc.abs_filename and files[doc.abs_filename]
  if not lines or not next(lines) or delta == 0 then return end
  local moved = {}
  for line in pairs(lines) do
    if line > line2 then
      moved[line + delta] = true
    elseif delta < 0 and line > line1 then
      moved[line1] = true
    else
      moved[line] = true
    end
  end
  files[doc.abs_filename] = moved
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
    save()
    breakpoints.on_change(self.abs_filename)
  end
  return res
end

return breakpoints
