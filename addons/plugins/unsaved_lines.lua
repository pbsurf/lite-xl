-- mod-version:3
-- Marks the lines changed since the doc was last saved (or loaded) with a bar at
-- the right edge of the gutter, in style.unsaved_line. A line edited back to what
-- it was isn't marked, nor one deleted and restored (by undo, or typed again).
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"

config.plugins.unsaved_lines = common.merge({
  -- the bar's width, scaled by SCALE
  width = 2,
}, config.plugins.unsaved_lines)

local default_color = { common.color "#e0403a" }

-- doc -> { saved = the doc's lines as saved, origin = for each line, the index in
-- saved of the line it was, or false if new, present = the set of origins }; none
-- until an edit of a doc as saved or loaded. A line is unsaved if new or not as it
-- was.
local marks = setmetatable({}, { __mode = "k" })

-- The doc's marks, made before an edit: anew if the doc is as saved, which
-- drops those of edits since undone. Docs of no file (widgets' text boxes, the
-- command view, ...) have none.
local function get_marks(doc)
  if not doc.abs_filename then return end
  local m = marks[doc]
  if not m or not doc:is_dirty() then
    m = { saved = {}, origin = {}, present = {} }
    for i, line in ipairs(doc.lines) do
      m.saved[i], m.origin[i], m.present[i] = line, i, true
    end
    marks[doc] = m
  end
  return m
end

local function falses(n)
  local t = {}
  for i = 1, n do t[i] = false end
  return t
end

-- New lines first to last: each is the saved line after the one above's (the
-- first, if at the top) if that's gone from the doc and the text is the same, as
-- when undo restores lines removed.
local function find_origins(doc, m, first, last)
  for i = first, last do
    local above = i > 1 and m.origin[i - 1]
    local candidate = i == 1 and 1 or (above and above + 1)
    if candidate and not m.present[candidate] and m.saved[candidate] == doc.lines[i] then
      m.origin[i], m.present[candidate] = candidate, true
    end
  end
end

-- Lines first to last about to be removed: their origins are gone from the doc.
local function forget_origins(m, first, last)
  for i = first, last do
    if m.origin[i] then m.present[m.origin[i]] = nil end
  end
end

local raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, ...)
  local m = get_marks(self)
  raw_insert(self, line, col, text, ...)
  if not m then return end
  local _, n = text:gsub("\n", "")
  if n > 0 and col == 1 and text:sub(-1) == "\n" then
    -- whole lines above the line, which moves down
    common.splice(m.origin, line, 0, falses(n))
    find_origins(self, m, line, line + n - 1)
  elseif n > 0 then
    -- the line stays where it was (its text changed unless the insert starts
    -- with its newline), the new lines below it
    common.splice(m.origin, line + 1, 0, falses(n))
    find_origins(self, m, line + 1, line + n)
  end
end

local raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, ...)
  local m = get_marks(self)
  local whole_lines = line2 > line1 and col1 == 1 and col2 == 1
  raw_remove(self, line1, col1, line2, col2, ...)
  if not m then return end
  if whole_lines then
    -- lines line1 to line2 - 1 gone; line2 moves up
    forget_origins(m, line1, line2 - 1)
    common.splice(m.origin, line1, line2 - line1)
  elseif line2 > line1 then
    -- line1 is what's left, joined with the rest of line2
    forget_origins(m, line1 + 1, line2)
    common.splice(m.origin, line1 + 1, line2 - line1)
  end
end

local function is_unsaved(doc, line)
  local m = marks[doc]
  if not m or not doc:is_dirty() then return false end
  local origin = m.origin[line]
  return origin == false or (origin ~= nil and doc.lines[line] ~= m.saved[origin])
end

-- saved, loaded or reloaded: nothing changed since
local clean = Doc.clean
function Doc:clean(...)
  marks[self] = nil
  return clean(self, ...)
end

local draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local h = draw_line_gutter(self, line, x, y, width) or self:get_line_height()
  if is_unsaved(self.doc, line) then
    local w = math.max(1, math.floor(config.plugins.unsaved_lines.width * SCALE + 0.5))
    -- at the right edge of the gutter's fill, after the line numbers
    local gx = self.position.x + self:get_gutter_width() - self:get_gutter_gap() - w
    renderer.draw_rect(gx, y, w, h, style.unsaved_line or default_color)
  end
  return h
end
