-- mod-version:3
-- Pasting several lines (ctrl+v) re-indents them as a block: the first line gets
-- the indentation of where it goes, the others keep theirs relative to it, in the
-- doc's tabs or spaces. ctrl+shift+v pastes the text as it is.
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"

-- a line ending in one opens a block: the next line goes one level deeper
local opener = "[%{%(%[:]%s*$"
-- a line starting with one closes a block
local closer = "^%s*[%}%)%]]"

local function indent_of(text)
  return text:match("^[ \t]*")
end

-- the width of indentation, tabs to the next multiple of size
local function width(ws, size)
  local w = 0
  for c in ws:gmatch(".") do
    w = c == "\t" and w + size - w % size or w + 1
  end
  return w
end

local function make_indent(w, indent_type, size)
  w = math.max(0, w)
  if indent_type == "hard" then
    return ("\t"):rep(w // size) .. (" "):rep(w % size)
  end
  return (" "):rep(w)
end

local function is_blank(text)
  return not text:find("%S")
end

-- The indentation width of a line put above line `line` (or on it, if it's
-- blank): that line's, unless it's blank or closes a block, then the line
-- before's, one level deeper if it opens a block.
local function target_width(doc, line, size)
  local current = doc.lines[line]
  if current and not is_blank(current) and not current:find(closer) then
    return width(indent_of(current), size)
  end
  for l = line - 1, 1, -1 do
    local text = doc.lines[l]
    if not is_blank(text) then
      return width(indent_of(text), size) + (text:find(opener) and size or 0)
    end
  end
  return 0
end

-- The width the first line had where it was copied. Copied from its text on
-- (no indentation in the clipboard), it's guessed from the others: a closing
-- line at the end is at its level, other lines after an opening first line one
-- level deeper, any others at it.
local function first_line_width(lines, size)
  local first = lines[1]
  if first:find("^[ \t]") or #lines == 1 then
    return width(indent_of(first), size)
  end
  local min, last
  for i = 2, #lines do
    if not is_blank(lines[i]) then
      local w = width(indent_of(lines[i]), size)
      min = math.min(min or w, w)
      last = i
    end
  end
  if not min then return 0 end
  if lines[last]:find(closer) then return width(indent_of(lines[last]), size) end
  if first:find(opener) then return math.max(0, min - size) end
  return min
end

-- The indentation unit of lines (widths relative to from): the largest of 2, 3,
-- 4, 8 dividing every one, if any is indented; nil if none or not all fit one
-- (lines aligned to columns).
local function indent_unit(lines, from, size)
  local rel = {}
  for i = 2, #lines do
    if not is_blank(lines[i]) then
      local w = width(indent_of(lines[i]), size) - from
      if w > 0 then table.insert(rel, w) end
    end
  end
  if #rel == 0 then return end
  for _, unit in ipairs({ 8, 4, 3, 2 }) do
    local fits = true
    for _, w in ipairs(rel) do
      if w % unit ~= 0 then fits = false break end
    end
    if fits then return unit end
  end
end

-- The lines re-indented: the first at first_w (unless keep_first), the others
-- relative to it, by as many levels of the doc's indentation as they had of
-- theirs; blank ones emptied.
local function reindent(lines, first_w, keep_first, doc)
  local indent_type, size = doc:get_indent_info()
  local from = first_line_width(lines, size)
  local unit = indent_unit(lines, from, size)
  local scale = unit and size / unit or 1
  local res = {}
  for i, text in ipairs(lines) do
    if i == 1 and keep_first then
      res[i] = text
    elseif is_blank(text) then
      res[i] = ""
    else
      -- the first line was at from, whatever its indentation in the clipboard
      local rel = i == 1 and 0 or width(indent_of(text), size) - from
      local w = first_w + math.floor(rel * scale + 0.5)
      res[i] = make_indent(w, indent_type, size) .. text:gsub("^[ \t]*", "")
    end
  end
  return res
end

local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do table.insert(lines, line) end
  return lines
end

local paste = command.map["doc:paste"].perform

local function paste_indented(dv)
  local doc = dv.doc
  local clipboard = system.get_clipboard()
  -- whole lines, as core pastes them: from a copy without a selection, put above
  -- the cursor's line
  local whole_line = core.cursor_clipboard["full"] == clipboard
    and core.cursor_clipboard_whole_line[1] and core.cursor_clipboard[1]
  local text = (whole_line and core.cursor_clipboard[1] .. "\n" or clipboard or ""):gsub("\r", "")
  if doc.read_only or #doc.selections > 4 or not text:find("\n") then
    return paste(dv)
  end
  local _, size = doc:get_indent_info()

  local line1, col1, line2, col2 = doc:get_selection(true)
  if line1 ~= line2 or col1 ~= col2 then
    doc:remove(line1, col1, line2, col2)
    doc:set_selection(line1, col1)
  end
  local line, col = line1, col1
  local before = doc.lines[line]:sub(1, col - 1)
  local ends_with_newline = text:sub(-1) == "\n"
  local lines = split_lines(ends_with_newline and text:sub(1, -2) or text)

  if whole_line or (ends_with_newline and is_blank(before) and not is_blank(doc.lines[line])) then
    -- lines above the line (core's whole line paste, wherever the cursor is on
    -- it), the cursor staying on it
    local new = table.concat(reindent(lines, target_width(doc, line, size), false, doc), "\n") .. "\n"
    doc:insert(line, 1, new)
    if col == 1 then doc:set_selection(line + #lines, 1) end
  elseif not is_blank(before) then
    -- mid-line: the first line goes on as copied, the others as if it were at
    -- the line's indentation
    local w = width(indent_of(doc.lines[line]), size)
    local new = table.concat(reindent(lines, w, true, doc), "\n")
    doc:text_input(new .. (ends_with_newline and "\n" or ""))
  else
    -- at the line's start (the indentation before the cursor replaced), or on a
    -- blank line
    local new = table.concat(reindent(lines, target_width(doc, line, size), false, doc), "\n")
    if col > 1 then doc:remove(line, 1, line, col) end
    doc:set_selection(line, 1)
    doc:text_input(new .. (ends_with_newline and "\n" or ""))
  end
end

command.add("core.docview!", {
  ["doc:paste-plain"] = function(dv) paste(dv) end,
})
command.map["doc:paste"].perform = paste_indented

keymap.add {
  ["ctrl+shift+v"] = "doc:paste-plain",
}
