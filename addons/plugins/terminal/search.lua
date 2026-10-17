-- A terminal's text as a read-only doc for searching (the search_ui plugin):
-- rows a line wraps over are joined into one line, so matches can span them.
--
-- Rows are numbered as terminal:lines() takes them: 0 is the screen's top row,
-- negative rows are scrollback. Columns in rows are characters from 0, as in
-- TerminalView.selection; doc columns are bytes from 1, as in core.doc.

local core = require "core"

---@class plugins.terminal.searchdoc
---@field lines string[]
---@field search_backward boolean? searches go up (search_ui flips its directions)
local SearchDoc = {}
SearchDoc.__index = SearchDoc

local search = {}

---The text of rows first to last of a TerminalView.
---@return plugins.terminal.searchdoc
function search.snapshot(view, first, last)
  local self = setmetatable({ view = view, lines = {}, segments = {}, row_segment = {} }, SearchDoc)
  local parts, segments = {}, {}
  local bytes = 0
  local rows = last >= first and view.terminal:lines(first, last) or {}
  for i, line in ipairs(rows) do
    local texts = {}
    for j = 2, #line, 2 do texts[#texts + 1] = line[j] end
    local text = table.concat(texts)
    local wraps = text:sub(-1) ~= "\n"
    if not wraps then text = text:sub(1, -2) end
    local length = text:ulen()
    local segment = {
      row = first + i - 1, byte = bytes + 1, text = text,
      valid = length ~= nil, chars = length or #text
    }
    segments[#segments + 1] = segment
    parts[#parts + 1] = text
    bytes = bytes + #text
    if not wraps or i == #rows then
      table.insert(self.lines, table.concat(parts) .. "\n")
      table.insert(self.segments, segments)
      for _, s in ipairs(segments) do
        s.line = #self.lines
        self.row_segment[s.row] = s
      end
      parts, segments, bytes = {}, {}, 0
    end
  end
  if #self.lines == 0 then
    self.lines[1] = "\n"
    self.segments[1] = { { row = first, byte = 1, text = "", valid = true, chars = 0, line = 1 } }
    self.row_segment[first] = self.segments[1][1]
  end
  return self
end

---The row and column of a doc position. A position where a line wraps is the
---end of the upper row if `at_end` (the end of a match), else the start of
---the lower one.
---@return integer row
---@return integer col
function SearchDoc:to_row_col(line, col, at_end)
  local segments = self.segments[line]
  local segment = segments[1]
  for i = 2, #segments do
    local s = segments[i]
    if col > s.byte or (col == s.byte and not at_end) then segment = s end
  end
  local before = segment.text:sub(1, col - segment.byte)
  return segment.row, segment.valid and before:ulen() or #before
end

---The doc position of a row and column; nil for a row not in the doc.
---@return integer? line
---@return integer? col
function SearchDoc:from_row_col(row, col)
  local segment = self.row_segment[row]
  if not segment then return nil end
  col = math.min(col, segment.chars)
  local offset = segment.valid and utf8.offset(segment.text, col + 1) or col + 1
  return segment.line, segment.byte + offset - 1
end

---The first row of a line.
function SearchDoc:get_line_row(line)
  return self.segments[line][1].row
end

function SearchDoc:sanitize_position(line, col)
  line = math.max(1, math.min(line, #self.lines))
  return line, math.max(1, math.min(col, #self.lines[line]))
end

---The view's selection; without one, a cursor where a search starts: at the
---top of what's shown, or the end of its bottom row if searching backward.
function SearchDoc:get_selection()
  local selection = self.view.selection
  if selection then
    local line1, col1 = self:from_row_col(selection[2], selection[1])
    local line2, col2 = self:from_row_col(selection[4], selection[3])
    if line1 and line2 then return line1, col1, line2, col2 end
  end
  local top = -self.view.terminal:scrollback()
  local line, col
  if self.search_backward then
    line, col = self:from_row_col(top + self.view.lines - 1, math.huge)
  else
    line, col = self:from_row_col(top, 0)
  end
  if not line then line, col = 1, 1 end
  return line, col, line, col
end

function SearchDoc:set_selection(line1, col1, line2, col2)
  line2, col2 = line2 or line1, col2 or col1
  if line1 == line2 and col1 == col2 then
    self.view.selection = nil
  else
    local first = line1 < line2 or (line1 == line2 and col1 < col2)
    local row1, c1 = self:to_row_col(line1, col1, not first)
    local row2, c2 = self:to_row_col(line2, col2, first)
    self.view.selection = { c1, row1, c2, row2 }
  end
  core.redraw = true
end

function SearchDoc:get_text(line1, col1, line2, col2)
  if line1 > line2 or (line1 == line2 and col1 > col2) then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if line1 == line2 then return self.lines[line1]:sub(col1, col2 - 1) end
  local parts = { self.lines[line1]:sub(col1) }
  for i = line1 + 1, line2 - 1 do parts[#parts + 1] = self.lines[i] end
  parts[#parts + 1] = self.lines[line2]:sub(1, col2 - 1)
  return table.concat(parts)
end

return search
