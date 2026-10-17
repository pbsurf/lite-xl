-- mod-version:3

-- Back and forward through the positions the cursor jumped from: a change of
-- document, or a move of more than `jump_threshold` lines that wasn't an edit.
-- History is global; the *-in-doc commands step through this document's entries
-- only. Going back from the newest entry first records where you are, so going
-- forward again returns there.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local Doc = require "core.doc"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local RootView = require "core.rootview"

config.plugins.navigate = common.merge({
  -- minimum change of line, within a document, that counts as a jump
  jump_threshold = 20,
  -- oldest entries are dropped beyond this
  max_entries = 100,
}, config.plugins.navigate)

local navigate = {
  -- entries {doc, filename, line, col}; doc is nil once closed, filename nil if unsaved
  list = {},
  -- the entry we're at; #list + 1 when not navigating
  index = 1,
}

-- active doc's position as of the last update: {doc, line, col, change_id}
local last

local function get_doc_view()
  local av = core.active_view
  if av and av:extends(DocView) and not av:extends(CommandView) then
    return av
  end
end

local function matches(entry, doc)
  return entry.doc == doc or (entry.filename ~= nil and entry.filename == doc.abs_filename)
end

local function same_place(entry, doc, line)
  return matches(entry, doc) and entry.line == line
end

local function push(doc, line, col)
  local list = navigate.list
  for i = #list, navigate.index, -1 do list[i] = nil end
  if not (#list > 0 and same_place(list[#list], doc, line)) then
    table.insert(list, { doc = doc, filename = doc.abs_filename, line = line, col = col })
    if #list > config.plugins.navigate.max_entries then table.remove(list, 1) end
  end
  navigate.index = #list + 1
end

local function update_last(doc)
  local line, col = doc:get_selection()
  last = { doc = doc, line = line, col = col, change_id = doc:get_change_id() }
end

local function go_to(entry)
  local doc = entry.doc
  if not doc then
    local ok, d = pcall(core.open_doc, entry.filename)
    if not ok then
      core.error("Can't open %s", entry.filename)
      return
    end
    doc = d
  end
  local dv = core.root_view:open_doc(doc)
  doc:set_selection(entry.line, entry.col)
  dv:scroll_to_line((doc:get_selection()), true)
  update_last(doc)
end

-- step = -1 (back) or 1 (forward); in_doc limits it to entries in the active doc
local function move(step, in_doc)
  local dv = get_doc_view()
  local list = navigate.list
  if step < 0 and navigate.index > #list and #list > 0 then
    local line, col = dv.doc:get_selection()
    push(dv.doc, line, col)
    navigate.index = #list
  end
  local i = navigate.index + step
  while list[i] and in_doc and not matches(list[i], dv.doc) do i = i + step end
  if list[i] then
    navigate.index = i
    go_to(list[i])
  end
end

function navigate.prev() move(-1) end
function navigate.next() move(1) end
function navigate.prev_in_doc() move(-1, true) end
function navigate.next_in_doc() move(1, true) end

-- Once per frame, compare the active doc's position with the last one.
local root_view_update = RootView.update
function RootView:update(...)
  root_view_update(self, ...)
  local dv = get_doc_view()
  if not dv then return end
  local doc = dv.doc
  if last and last.doc == doc then
    local line = doc:get_selection()
    if doc:get_change_id() == last.change_id
        and math.abs(line - last.line) > config.plugins.navigate.jump_threshold then
      push(doc, last.line, last.col)
    end
  elseif last then
    push(last.doc, last.line, last.col)
  end
  update_last(doc)
end

-- Keep entries on their lines as text is inserted and removed above them.
local function shift_lines(doc, line, delta)
  for _, entry in ipairs(navigate.list) do
    if matches(entry, doc) and entry.line > line then
      entry.line = math.max(line, entry.line + delta)
    end
  end
end

local raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, ...)
  raw_insert(self, line, col, text, ...)
  local _, newlines = text:gsub("\n", "")
  if newlines > 0 then shift_lines(self, line, newlines) end
end

local raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, ...)
  raw_remove(self, line1, col1, line2, col2, ...)
  if line2 > line1 then shift_lines(self, line1, line1 - line2) end
end

-- A closed doc's entries are kept by filename (reopened on navigation) and dropped
-- if it has none.
local doc_on_close = Doc.on_close
function Doc:on_close()
  local list = navigate.list
  for i = #list, 1, -1 do
    if list[i].doc == self then
      list[i].doc = nil
      if not list[i].filename then
        table.remove(list, i)
        if navigate.index > i then navigate.index = navigate.index - 1 end
      end
    end
  end
  if last and last.doc == self then last = nil end
  doc_on_close(self)
end

command.add(get_doc_view, {
  ["navigate:previous"] = navigate.prev,
  ["navigate:next"] = navigate.next,
  ["navigate:previous-in-doc"] = navigate.prev_in_doc,
  ["navigate:next-in-doc"] = navigate.next_in_doc,
})

keymap.add {
  ["alt+left"] = "navigate:previous",
  ["alt+right"] = "navigate:next",
  ["alt+shift+left"] = "navigate:previous-in-doc",
  ["alt+shift+right"] = "navigate:next-in-doc",
}

return navigate
