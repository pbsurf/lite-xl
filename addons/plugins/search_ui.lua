-- mod-version:3
--
-- Replacement for the find/replace and project search CommandView
---interface using Widgets with some extra features.
-- @copyright Jefferson Gonzalez <jgmdev@gmail.com>
-- @license MIT
--
local core = require "core"
local config = require "core.config"
local common = require "core.common"
local command = require "core.command"
local style = require "core.style"
local keymap = require "core.keymap"
local search = require "core.doc.search"
local projectsearch = require "plugins.projectsearch"
local CommandView = require "core.commandview"
local DocView = require "core.docview"
local Widget = require "libraries.widget"
local Button = require "libraries.widget.button"
local CheckBox = require "libraries.widget.checkbox"
local Line = require "libraries.widget.line"
local Label = require "libraries.widget.label"
local TextBox = require "libraries.widget.textbox"
local SelectBox = require "libraries.widget.selectbox"
local FilePicker = require "libraries.widget.filepicker"

---@class config.plugins.search_ui
---@field replace_core_find boolean
---@field position "right" | "bottom"
---@field highlight_all boolean
config.plugins.search_ui = common.merge({
  replace_core_find = true,
  position = "bottom",
  highlight_all = true,
  config_spec = {
    name = "Search User Interface",
    {
      label = "Replace Core Find",
      description = "Replaces the core find view when using the find shortcut.",
      path = "replace_core_find",
      type = "toggle",
      default = true
    },
    {
      label = "Position",
      description = "Location of search interface.",
      path = "position",
      type = "selection",
      default = "bottom",
      values = {
        { "Top", "top" },
        { "Right", "right" },
        { "Bottom", "bottom" }
      }
    },
    {
      label = "Highlight All",
      description = "Mark every match in the file while the search pane is shown.",
      path = "highlight_all",
      type = "toggle",
      default = true
    }
  }
}, config.plugins.search_ui)

-- The view searched: a DocView, or another view providing get_search_doc(),
-- returning a read-only doc-like object (lines, get_selection, set_selection,
-- get_text, sanitize_position, optionally search_backward: next and previous
-- swapped), and scroll_to_line(line) (a terminal)
---@type core.docview
local doc_view = nil

---@return core.doc?
local function target_doc(view)
  if view.get_search_doc then return view:get_search_doc() end
  return view.doc
end

---@type widget
local widget = Widget(nil, false)
widget.name = "Search and Replace"
widget:set_border_width(0)
widget.scrollable = true
widget:hide()
widget.init_size = true

---@type widget.label
local label = Label(widget, "Find and Replace")
label:set_position(10, 10)

---@type widget.line
local line = Line(widget)
line:set_position(0, label:get_bottom() + 10)

---@type widget.button
local togglereplace = Button(widget, "")
togglereplace:set_icon("+")
togglereplace:set_position(10, line:get_bottom() + 10)

---@type widget.textbox
local findtext = TextBox(widget, "", "search...  (↑↓ history)")
findtext:set_position(10, line:get_bottom() + 10)
findtext:set_tooltip("Text to search")

---@type widget.textbox
local replacetext = TextBox(widget, "", "replacement...  (↑↓ history)")
replacetext:set_position(10, findtext:get_bottom() + 10)
replacetext:set_tooltip("Text to replace")

---@type widget.button
local findprev = Button(widget, "")
findprev:set_icon("<")
findprev:set_position(10, replacetext:get_bottom() + 10)
findprev:set_tooltip("Find previous")

---@type widget.button
local findnext = Button(widget, "")
findnext:set_icon(">")
findnext:set_position(findprev:get_right() + 5, replacetext:get_bottom() + 10)
findnext:set_tooltip("Find next")

---@type widget.button
local findproject = Button(widget, "Find")
findproject:set_icon("L")
findproject:set_position(findprev:get_right() + 5, replacetext:get_bottom() + 10)
findproject:set_tooltip("Find in project")
findproject:hide()

---@type widget.button
local replace = Button(widget, "Replace")
replace:set_position(10, findnext:get_bottom() + 10)
replace:set_tooltip("Replace all matching results")

---@type widget.line
local line_options = Line(widget)
line_options:set_position(0, replace:get_bottom() + 10)

---@type widget.checkbox
local matchcase = CheckBox(widget, "Match Case")
matchcase:set_position(10, line_options:get_bottom() + 10)
matchcase:set_tooltip("Case sensitive search")

---@type widget.checkbox
local wholeword = CheckBox(widget, "Whole Word")
wholeword:set_position(10, matchcase:get_bottom() + 10)
wholeword:set_tooltip("Match whole words only")

---@type widget.checkbox
local patterncheck = CheckBox(widget, "Pattern")
patterncheck:set_position(10, wholeword:get_bottom() + 10)
patterncheck:set_tooltip("Treat search text as a lua pattern (always case sensitive)")

---@type widget.checkbox
local regexcheck = CheckBox(widget, "Regex")
regexcheck:set_position(10, patterncheck:get_bottom() + 10)
regexcheck:set_tooltip("Treat search text as a regular expression")

---@type widget.checkbox
local replaceinselection = CheckBox(widget, "Replace in Selection")
replaceinselection:set_position(10, regexcheck:get_bottom() + 10)
replaceinselection:set_tooltip("Perform replace only on selected text")

---@type widget.checkbox
local highlightall = CheckBox(widget, "Highlight All")
highlightall:set_position(10, replaceinselection:get_bottom() + 10)
highlightall:set_tooltip("Mark every match in the file")
highlightall:set_checked(config.plugins.search_ui.highlight_all)

---@type widget.selectbox
local scope = SelectBox(widget, "scope")
scope:set_position(10, regexcheck:get_bottom() + 10)
scope:add_option("current file")
scope:add_option("project files")
scope:set_selected(1)

---@type widget.filepicker
local filepicker = FilePicker(widget)
filepicker:set_mode(FilePicker.mode.DIRECTORY)
filepicker:set_position(10, scope:get_bottom() + 10)
filepicker:set_tooltip("Directory to perform the search")
filepicker:hide()

---@type widget.line
local statusline = Line(widget)
statusline:set_position(0, scope:get_bottom() + 10)

---@type widget.label
local status = Label(widget, "")
status:set_position(10, statusline:get_bottom() + 10)

-- at a match's start or end: unless the match's own character there isn't a
-- word character, the one beyond it mustn't be one
local word_boundary = "(?:(?<!\\w)|(?!\\w))"

-- plain text as a regex matching it
local function escape_regex(text)
  return (text:gsub("[^%w%s\128-\255]", "\\%0"))
end

---The text to search for and how, from the find box and checkboxes. Whole
---word searches are regex searches: the text (escaped, unless Regex) between
---word boundaries.
---@return string text
---@return boolean use_pattern
---@return boolean use_regex
local function search_query()
  local text = findtext:get_text()
  local use_pattern, use_regex = patterncheck:is_checked(), regexcheck:is_checked()
  if wholeword:is_checked() and text ~= "" then
    if not use_regex then text = escape_regex(text) end
    text = word_boundary .. "(?:" .. text .. ")" .. word_boundary
    use_pattern, use_regex = false, true
  end
  return text, use_pattern, use_regex
end

local get_matcher

--------------------------------------------------------------------------------
-- Helper class to keep track of amount of matches and display on status label
--------------------------------------------------------------------------------
---@class plugins.search_ui.result
---@field line integer
---@field col integer

---@class plugins.search_ui.results
---@field text string
---@field matches plugins.search_ui.result[]
---@field doc core.doc?
local Results = {
  text = "",
  matches = {},
  doc = nil,
  prev_search_id = 0
}

---@param text string
---@param doc core.doc
function Results:find(text, doc, force)
  if self.text == text and self.doc == doc and not force then
    self:set_status()
    return
  end

  -- disable previous search thread
  if self.prev_search_id > 0 and core.threads[self.prev_search_id] then
    core.threads[self.prev_search_id] = {
      cr = coroutine.create(function() end), wake = 0
    }
  end

  self.text = text
  self.doc = doc

  -- the matches Highlight All marks, so the count agrees with them
  local match = get_matcher()
  if not match then return end

  self.prev_search_id = core.add_thread(function()
    self.matches = {}
    local lines_count = #doc.lines
    for i=1, lines_count do
      for _, m in ipairs(match(doc.lines[i])) do
        table.insert(self.matches, {line = i, col = m[1]})
      end
      if i % 100 == 0 then
        coroutine.yield()
      end
    end
    self:set_status()
  end)
end

---@return integer
function Results:current()
  if not self.doc then return 0 end
  local line1, col1, line2, col2 = self.doc:get_selection()
  if line1 == line2 and col1 == col2 then return 0 end
  local line = math.min(line1, line2)
  local col = math.min(col1, col2)
  if self.matches and #self.matches > 0 then
    for i, result in ipairs(self.matches) do
      if result.line == line and result.col == col then
        return i
      end
    end
  end
  return 0
end

function Results:clear()
  self.text = ""
  self.matches = {}
  self.doc = nil
  status:set_label("")
end

function Results:set_status()
  local current = self:current()
  local total = self.matches and #self.matches or 0
  if total > 0 then
    status:set_label(
      "Result: " .. tostring(current .. " of " .. tostring(total))
    )
  else
    status:set_label("")
  end
end

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------
local function view_is_open(target_view)
  if not target_view then return false end
  local found = false
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view == target_view then
      found = true
      break
    end
  end
  return found
end

local function set_shown(w, shown)
  if shown then w:show() else w:hide() end
end

-- Whether the replace row (box, button, "Replace in Selection") is wanted;
-- find-replace:find hides it, find-replace:replace shows it, the chevron
-- button left of the search box toggles it. It and the chevron are only
-- shown for a view that can be changed: not one searched through
-- get_search_doc (a terminal).
local replace_shown = false
-- whether the row is shown now
local row_was_shown = false

local function can_replace()
  return not (doc_view and doc_view.get_search_doc)
end

local function row_shown()
  return replace_shown and can_replace()
end

local update_size

-- shows or hides the chevron and the replace row (in file scope)
local function show_replace_controls()
  if scope:get_selected() ~= 1 then return end
  local shown = row_shown()
  set_shown(togglereplace, can_replace())
  set_shown(replacetext, shown)
  set_shown(replace, shown)
  set_shown(replaceinselection, shown)
end

local function update_replace_controls()
  local shown = row_shown()
  local changed = shown ~= row_was_shown
  row_was_shown = shown
  togglereplace:set_icon(replace_shown and "-" or "+")
  local binding = keymap.get_binding("find-replace:replace")
  togglereplace:set_tooltip((replace_shown and "Hide Replace" or "Show Replace")
    .. (binding and " (" .. binding .. ")" or ""))
  show_replace_controls()
  if not shown and widget.child_active == replacetext then
    widget:swap_active_child(findtext)
  end
  -- fit the pane's height to what's shown: when hidden, the height it will
  -- show at (prev_size, see Widget:hide); else once no animation is running
  if changed and config.plugins.search_ui.position ~= "right"
    and scope:get_selected() == 1
  then
    if not widget.visible and widget.prev_size.y > 0 then
      local row = replacetext.size.y + 10
      widget.prev_size.y = widget.prev_size.y + (shown and row or -row)
    end
    widget.relayout = true
  end
  core.redraw = true
end

local function set_replace_shown(shown)
  replace_shown = shown
  update_replace_controls()
end

-- the view searched, with the replace controls it allows
local function set_target(view)
  doc_view = view
  update_replace_controls()
end

local function toggle_scope(idx, not_set)
  if not not_set then scope:set_selected(idx) end

  if idx == 1 then
    show_replace_controls()
    findnext:show()
    findprev:show()
    patterncheck:show()
    highlightall:show()
    findproject:hide()
    filepicker:hide()

    if view_is_open(doc_view) and findtext:get_text() ~= "" then
      Results:find(findtext:get_text(), target_doc(doc_view))
    else
      Results:clear()
    end
  else
    togglereplace:hide()
    replacetext:hide()
    findnext:hide()
    findprev:hide()
    replace:hide()
    patterncheck:hide()
    replaceinselection:hide()
    highlightall:hide()
    findproject:show()
    filepicker:show()

    Results:clear()
  end
end

--------------------------------------------------------------------------------
-- History: core's core.previous_find and core.previous_replace (newest first,
-- saved in the session, also offered by core's find), stepped through with
-- up/down in the boxes
--------------------------------------------------------------------------------
local max_history = 100

-- position while stepping through a box's history: 0 is the text being edited,
-- kept in draft
local history_pos = { [findtext] = { idx = 0 }, [replacetext] = { idx = 0 } }
local stepping = false

local function add_history(list, text)
  if text == "" then return end
  for i = #list, 1, -1 do
    if list[i] == text then table.remove(list, i) end
  end
  table.insert(list, 1, text)
  for i = #list, max_history + 1, -1 do list[i] = nil end
end

local function remember_find()
  add_history(core.previous_find, findtext:get_text())
  history_pos[findtext].idx = 0
end

local function remember_replace()
  add_history(core.previous_replace, replacetext:get_text())
  history_pos[replacetext].idx = 0
end

local function project_search()
  if findtext:get_text() == "" then return end
  remember_find()
  local query, _, use_regex = search_query()
  local rv
  if not use_regex then
    rv = projectsearch.search_plain(
      query, filepicker:get_path(), not matchcase:is_checked()
    )
  else
    rv = projectsearch.search_regex(
      query, filepicker:get_path(), not matchcase:is_checked()
    )
    -- the query is only shown (also after a refresh): show what was typed,
    -- not the whole word regex
    if rv then
      rv.query = findtext:get_text()
      rv.search_args[2] = rv.query
    end
  end
  command.perform "search-replace:hide"
  -- hiding focused the doc: back to the results, to step through them
  if rv then core.set_active_view(rv) end
end

local find_enabled = true
---@param reverse? boolean
---@param typing? boolean the search text changed: a backward search should
---still find the current match as it grows
local function find(reverse, typing)
  if
    not view_is_open(doc_view) or findtext:get_text() == "" or not find_enabled
  then
    Results:clear()
    return
  end

  local last = core.last_active_view
  if last and (last:is(DocView) or last.get_search_doc) then
    set_target(last)
  end

  local doc = target_doc(doc_view)
  if not doc then return end
  if doc.search_backward then reverse = not reverse end
  local cline1, ccol1, cline2, ccol2 = doc:get_selection()
  local line, col = cline1, ccol1
  if reverse and ccol2 < ccol1 then
    col = ccol2
  end
  -- going up, from where the current match would end with the new text, so
  -- it's found again if it still matches
  if typing and reverse and (cline1 ~= cline2 or ccol1 ~= ccol2) then
    if cline2 < cline1 or (cline2 == cline1 and ccol2 < ccol1) then
      cline1, ccol1 = cline2, ccol2
    end
    line, col = cline1, ccol1 + #findtext:get_text()
  end

  local query, use_pattern, use_regex = search_query()
  local opt = {
    wrap = true,
    -- Lua patterns can't fold case (core would lowercase the pattern itself)
    no_case = not matchcase:is_checked() and not use_pattern,
    pattern = use_pattern,
    regex = use_regex,
    reverse = reverse
  }

  if opt.regex and not regex.compile(query) then
    return
  end

  status:set_label("")

  core.try(function()
    local line1, col1, line2, col2 = search.find(
      doc, line, col, query, opt
    )

    local current_text = doc:get_text(
      table.unpack({ doc:get_selection() })
    )

    if opt.no_case and not opt.regex and not opt.pattern then
      current_text = current_text:ulower()
    end

    if line1 then
      local text = findtext:get_text()
      if opt.no_case and not opt.regex and not opt.pattern then
        text = text:ulower()
      end
      if reverse or (current_text == text or current_text == "") then
        doc:set_selection(line1, col2, line2, col1)
      else
        doc:set_selection(line1, col1, line2, col2)
      end
      doc_view:scroll_to_line(line1, true)
      Results:find(text, doc)
    else
      Results:clear()
    end
  end)
end

local function find_replace()
  if core.last_active_view:is(DocView) then
    set_target(core.last_active_view)
  end
  local doc = target_doc(doc_view)
  if not doc.replace then
    status:set_label("Read only")
    return
  end

  if not replaceinselection:is_checked() then
    local line1, col1, line2, col2 = doc:get_selection()
    if line1 ~= line2 or col1 ~= col2 then
      doc:set_selection(line1, col1)
    end
  end

  local old, use_pattern, use_regex = search_query()
  local new = replacetext:get_text()
  local no_case = not matchcase:is_checked()
  remember_find()
  remember_replace()
  -- gsub can't ignore case: a plain case insensitive search becomes a regex
  if no_case and not use_regex and not use_pattern then
    old, use_regex = escape_regex(old), true
  end
  -- a plain search that became a regex: keep its replacement literal
  if use_regex and not regexcheck:is_checked() then
    new = new:gsub("\\", "\\\\"):gsub("%$", "$$")
  end

  local results = doc:replace(function(text)
    if not use_regex then
      if not use_pattern then
        return text:gsub(old:gsub("%W", "%%%1"), new:gsub("%%", "%%%%"), nil)
      else
        return text:gsub(old, new)
      end
    end
    local result, matches = regex.gsub(regex.compile(old, no_case and "im" or "m"), text, new)
    if type(matches) == "table" then
      return result, #matches
    end
    return result, matches
  end)

  local n = 0
  for _,v in pairs(results) do
    n = n + v
  end

  status:set_label(string.format("Total Replaced: %d", n))
end

---Show an older (dir 1) or newer (dir -1) history entry in a box; newer than
---the newest is the text that was being edited.
---@param box widget.textbox
---@param dir integer
local function step_history(box, dir)
  local pos = history_pos[box]
  local list = box == findtext and core.previous_find or core.previous_replace
  local current = box:get_text()
  if pos.idx == 0 then pos.draft = current end
  local idx = pos.idx
  repeat idx = idx + dir until idx <= 0 or idx > #list or list[idx] ~= current
  if idx > #list then return end
  idx = math.max(idx, 0)
  if idx == pos.idx then return end
  pos.idx = idx
  stepping, find_enabled = true, false
  box:set_text(idx == 0 and pos.draft or list[idx])
  stepping, find_enabled = false, true
  box.textview.doc:set_selection(1, math.huge)
  if box == findtext and scope:get_selected() == 1 then find(false, true) end
end

local inside_node = false
local current_node = nil
local current_position = ""

local function add_to_node()
  if not inside_node or current_position ~= config.plugins.search_ui.position then
    if
      current_position ~= ""
      and
      current_position ~= config.plugins.search_ui.position
    then
      widget:hide()
      current_node:remove_view(core.root_view.root_node, widget)
      core.root_view.root_node:update_layout()
      widget:set_size(0, 0)
      widget.init_size = true
    end
    local node = core.root_view:get_primary_node()
    if config.plugins.search_ui.position == "right" then
      current_node = node:split("right", widget, {x=true}, true)
      current_position = "right"
    elseif config.plugins.search_ui.position == "top" then
      current_node = node:split("up", widget, {y=true}, false)
      current_position = "top"
    else
      current_node = node:split("down", widget, {y=true}, false)
      current_position = "bottom"
    end
    widget:show()
    inside_node = true
  end
end

---Show or hide the search pane.
---@param av? core.docview
---@param toggle? boolean
local function show_find(av, toggle)
  if
    not view_is_open(av)
    and
    scope:get_selected() == 1
  then
    widget:swap_active_child()
    if config.plugins.search_ui.position == "right" then
      widget:hide_animated(false, true)
    else
      widget:hide_animated(true, false)
    end
    return
  end

  if inside_node and current_position == config.plugins.search_ui.position then
    if toggle then
      widget:toggle_visible(true, false, true)
    else
      if not widget:is_visible() then
        if config.plugins.search_ui.position == "right" then
          widget:show_animated(false, true)
        else
          widget:show_animated(true, false)
        end
      end
    end
  else
    add_to_node()
  end

  if widget:is_visible() then
    status:set_label("")

    widget:swap_active_child(findtext)
    set_target(av)
    local doc = view_is_open(doc_view) and target_doc(doc_view)
    if doc then
      local doc_text = doc:get_text(table.unpack({ doc:get_selection() }))
      if not matchcase:is_checked() then doc_text = doc_text:ulower() end
      local current_text = findtext:get_text()
      if not matchcase:is_checked() then current_text = current_text:ulower() end
      if doc_text and doc_text ~= "" and current_text ~= doc_text then
        local original_text = doc:get_text(table.unpack({ doc:get_selection() }))
        find_enabled = false
        findtext:set_text(original_text)
        find_enabled = true
      elseif current_text ~= "" and doc_text == "" then
        if scope:get_selected() == 1 then
          find(false)
        end
      end
      if findtext:get_text() ~= "" then
        findtext.textview.doc:set_selection(1, math.huge, 1, 1)
        if scope:get_selected() == 1 then
          Results:find(findtext:get_text(), doc)
        else
          Results:clear()
        end
      else
        Results:clear()
      end
    end
  else
    if #Results.matches > 0 then remember_find() end
    widget:swap_active_child()
    if view_is_open(doc_view) then
      core.set_active_view(doc_view)
    end
  end
end

--------------------------------------------------------------------------------
-- Widgets event overrides
--------------------------------------------------------------------------------
function findtext:on_change(text)
  if not stepping then history_pos[findtext].idx = 0 end
  if scope:get_selected() == 1 then
    find(false, true)
  end
end

function replacetext:on_change(text)
  if not stepping then history_pos[replacetext].idx = 0 end
end

function matchcase:on_checked(checked)
  Results:clear()
end

-- whole word applies to plain and regex searches, not Lua patterns
function wholeword:on_checked(checked)
  if checked then
    patterncheck:set_checked(false)
  end
  Results:clear()
end

function patterncheck:on_checked(checked)
  if checked then
    regexcheck:set_checked(false)
    wholeword:set_checked(false)
  end
  Results:clear()
end

function regexcheck:on_checked(checked)
  if checked then
    patterncheck:set_checked(false)
  end
  Results:clear()
end

function scope:on_selected(idx)
  toggle_scope(idx, true)
  if not view_is_open(doc_view) and idx == 1 then
    command.perform "search-replace:hide"
  end
end

function findnext:on_click() remember_find() find(false) end
function findprev:on_click() remember_find() find(true) end
function findproject:on_click() project_search() end
function replace:on_click() find_replace() end
function togglereplace:on_click() set_replace_shown(not replace_shown) end

local function chevron_width()
  return math.max(style.icon_font:get_width("+"), style.icon_font:get_width("-"))
end

-- as wide for either chevron, so the search box doesn't move when toggled
function togglereplace:update()
  if not Button.update(self) then return false end
  self.size.x = self.padding.x * 2 - self.border.width * 2 + chevron_width()
  return true
end

-- the chevron centered: Button draws its icon at the left padding, and the
-- right chevron is narrower than the down one
function togglereplace:draw()
  local padding_x = self.padding.x
  self.padding.x = padding_x
    + (chevron_width() - style.icon_font:get_width(self.icon.code)) / 2
  local drawn = Button.draw(self)
  self.padding.x = padding_x
  return drawn
end
set_replace_shown(replace_shown)

function highlightall:on_checked(checked)
  config.plugins.search_ui.highlight_all = checked
  core.redraw = true
end

--------------------------------------------------------------------------------
-- Highlight all matches (DocView line marks)
--------------------------------------------------------------------------------
-- A function returning a line's matches as a list of { col1, col2 (exclusive) }
-- for the current search text and options; nil if there's nothing to find
local matcher_key, matcher = nil, nil
function get_matcher()
  local text, use_pattern, use_regex = search_query()
  local no_case = not matchcase:is_checked()
  local key = table.concat({ text, tostring(no_case), tostring(use_pattern),
    tostring(use_regex) }, "\0")
  if key == matcher_key then return matcher end
  matcher_key, matcher = key, nil
  if text == "" then return nil end

  if use_regex then
    local re = regex.compile(text, no_case and "im" or "m")
    if not re then return nil end
    matcher = function(line_text)
      local found, col = {}, 1
      while col <= #line_text do
        local s, e = re:cmatch(line_text, col)
        if not s then break end
        if e > s then table.insert(found, { s, e }) end
        col = math.max(e, s + 1)
      end
      return found
    end
  else
    local plain = not use_pattern
    -- lower-case without changing byte offsets (ulower may, for some text)
    local function lower(str)
      local lowered = str:ulower()
      return #lowered == #str and lowered or str:lower()
    end
    if no_case and plain then text = lower(text) end
    if use_pattern and not pcall(string.find, "", text) then return nil end
    matcher = function(line_text)
      if no_case and plain then line_text = lower(line_text) end
      local found, col = {}, 1
      while col <= #line_text do
        local s, e = line_text:find(text, col, plain)
        if not s then break end
        if e >= s then table.insert(found, { s, e + 1 }) end
        col = math.max(e + 1, s + 1)
      end
      return found
    end
  end
  return matcher
end

local function is_selected(doc, line, col1, col2)
  for _, l1, c1, l2, c2 in doc:get_selections(true) do
    if l1 == line and l2 == line and c1 == col1 and c2 == col2 then
      return true
    end
  end
  return false
end

---For Highlight All in a view that isn't a DocView (search_ui's module is the
---pane widget): a matcher as get_matcher's and the color to mark matches,
---while the view's matches are highlighted.
---@return function? match
---@return renderer.color? color
function widget.highlight_matcher(view)
  if
    not highlightall:is_checked() or not widget:is_visible()
    or scope:get_selected() ~= 1 or view ~= doc_view
  then
    return nil
  end
  local color = style.search_match
  if not color then
    local a = style.accent
    color = { a[1], a[2], a[3], 80 }
  end
  return get_matcher(), color
end

local get_line_marks = DocView.get_line_marks
function DocView:get_line_marks(line)
  local marks = get_line_marks(self, line)
  if self:is(CommandView) or not doc_view or self.doc ~= doc_view.doc then
    return marks
  end
  local match, color = widget.highlight_matcher(doc_view)
  if not match then return marks end
  for _, m in ipairs(match(self.doc.lines[line])) do
    if not is_selected(self.doc, line, m[1], m[2]) then
      table.insert(marks, { m[1], m[2], color })
    end
  end
  return marks
end

---@param self widget
function update_size(self)
  if config.plugins.search_ui.position == "right" then
    if scope:get_selected() == 1 then
      if self.size.x < replace:get_right() + replace:get_width() / 2 then
        self.size.x = replace:get_right() + replace:get_width() / 2
      end
    else
      if self.size.x < findproject:get_right() + findproject:get_width() * 2 then
        self.size.x = findproject:get_right() + findproject:get_width() * 2
      end
    end
  else
    self:set_size(nil, self:get_real_height() + 10)
  end
end

---@param self widget
local function update_right_positioning(self)
  scope:show()
  label:show()
  status:show()
  line_options:show()
  label:set_label("Find and Replace")

  label:set_position(10, 10)
  line:set_position(0, label:get_bottom() + 10)
  local text_x = 10
  if scope:get_selected() == 1 and can_replace() then
    togglereplace:set_position(10, line:get_bottom() + 10)
    text_x = togglereplace:get_right() + 5
  end
  findtext:set_position(text_x, line:get_bottom() + 10)
  findtext.size.x = self.size.x - 10 - text_x

  if scope:get_selected() == 1 then
    local below = findtext
    if row_shown() then
      replacetext:set_position(text_x, findtext:get_bottom() + 10)
      replacetext.size.x = findtext.size.x
      below = replacetext
    end
    findprev:set_position(10, below:get_bottom() + 10)
    findnext:set_position(findprev:get_right() + 5, below:get_bottom() + 10)
    replace:set_position(findnext:get_right() + 5, below:get_bottom() + 10)
    line_options:set_position(0, findnext:get_bottom() + 10)
  else
    findproject:set_position(10, findtext:get_bottom() + 10)
    replace:set_position(findproject:get_right() + 5, replacetext:get_bottom() + 10)
    line_options:set_position(0, findproject:get_bottom() + 10)
  end

  matchcase:set_position(10, line_options:get_bottom() + 10)
  wholeword:set_position(10, matchcase:get_bottom() + 10)
  if scope:get_selected() == 1 then
    patterncheck:set_position(10, wholeword:get_bottom() + 10)
    regexcheck:set_position(10, patterncheck:get_bottom() + 10)
    replaceinselection:set_position(10, regexcheck:get_bottom() + 10)
    highlightall:set_position(10,
      (row_shown() and replaceinselection or regexcheck):get_bottom() + 10)
    scope:set_position(10, highlightall:get_bottom() + 10)
  else
    regexcheck:set_position(10, wholeword:get_bottom() + 10)
    scope:set_position(10, regexcheck:get_bottom() + 10)
  end

  scope:set_size(self.size.x - 20)
  if scope:get_selected() == 1 then
    statusline:set_position(0, scope:get_bottom() + 30)
  else
    filepicker:set_position(10, scope:get_bottom() + 10)
    filepicker:set_size(self.size.x - 20, nil)
    statusline:set_position(0, filepicker:get_bottom() + 30)
  end

  status:set_position(10, statusline:get_bottom() + 10)
  if status.label == "" then
    statusline:hide()
  else
    statusline:show()
  end

  if self.init_size then
    update_size(self)
    self.init_size = false
    self:show_animated(false, true)
  end

  add_to_node()
end

---@param self widget
local function update_bottom_positioning(self)
  scope:hide()
  statusline:hide()

  if scope:get_selected() == 1 then
    label:hide()
    status:show()
    status:set_position(10, 10)
    replaceinselection:set_position(self.size.x - replaceinselection:get_width() - 10, 10)
    local right = row_shown() and replaceinselection:get_position().x or self.size.x
    regexcheck:set_position(right - 10 - regexcheck:get_width(), 10)
    patterncheck:set_position(regexcheck:get_position().x - 10  - patterncheck:get_width(), 10)
    wholeword:set_position(patterncheck:get_position().x - 10 - wholeword:get_width(), 10)
    matchcase:set_position(wholeword:get_position().x - 10 - matchcase:get_width(), 10)
    highlightall:set_position(matchcase:get_position().x - 10 - highlightall:get_width(), 10)
    line:set_position(0, status:get_bottom() + 10)
  else
    label:show()
    status:hide()
    label:set_label("Find in Directory")
    label:set_position(10, 10)
    regexcheck:set_position(self.size.x - regexcheck:get_width() - 10, 10)
    wholeword:set_position(regexcheck:get_position().x - 10 - wholeword:get_width(), 10)
    matchcase:set_position(wholeword:get_position().x - 10 - matchcase:get_width(), 10)
    line:set_position(0, label:get_bottom() + 10)
  end

  if scope:get_selected() == 1 then
    togglereplace:set_position(10, line:get_bottom() + 10)
    local text_x = can_replace() and togglereplace:get_right() + 10 or 10
    findtext:set_position(text_x, line:get_bottom() + 10)
    findtext.size.x = self.size.x - 30 - text_x - findprev:get_width() - findnext:get_width()
    findnext:set_position(self.size.x - 10 - findnext:get_width(), line:get_bottom() + 10)
    findprev:set_position(findnext:get_position().x - 10 - findprev:get_width(), line:get_bottom() + 10)
    replacetext:set_position(text_x, findtext:get_bottom() + 10)
    replacetext.size.x = findtext.size.x
    replace:set_position(self.size.x - 15 - replace:get_width(), findtext:get_bottom() + 10)
    replace.size.x = findprev:get_width() + findnext:get_width() + 10
    line_options:hide()
  else
    findtext:set_position(10, line:get_bottom() + 10)
    findtext.size.x = self.size.x - 30 - findproject:get_width()
    findproject:set_position(self.size.x - 10 - findproject:get_width(), line:get_bottom() + 10)
    replace:set_position(findproject:get_right() + 5, replacetext:get_bottom() + 10)
    line_options:show()
    line_options:set_position(0, findproject:get_bottom() + 10)
    filepicker:set_position(10, line_options:get_bottom() + 10)
    filepicker:set_size(self.size.x - 20, nil)
  end

  if self.init_size then
    update_size(self)
    self.init_size = false
    self:show_animated(true, false)
  end

  add_to_node()
end

-- reposition items on scale changes
function widget:update()
  if Widget.update(self) then
    if config.plugins.search_ui.position == "right" then
      update_right_positioning(self)
    else
      update_bottom_positioning(self)
    end
    if self.relayout and #self.animations == 0 then
      self.relayout = false
      if config.plugins.search_ui.position ~= "right" then
        self:set_size(nil, self:get_real_height() + 10)
        -- the node layout runs after views update, so would move the pane
        -- after its children were placed, and nothing would draw again
        -- until the next event: lay out now and place them again
        core.root_view.root_node:update_layout()
        self:update_position()
        core.redraw = true
      end
    end
  end
end

function widget:on_scale_change(...)
  Widget.on_scale_change(self, ...)
  update_size(self)
end

--------------------------------------------------------------------------------
-- Override set_active_view to keep track of currently active docview
--------------------------------------------------------------------------------
local core_set_active_view = core.set_active_view
function core.set_active_view(...)
  core_set_active_view(...)
  local view = core.next_active_view or core.active_view
  if
    view ~= doc_view
    and
    widget:is_visible()
    and
    (
      view:extends(DocView)
      and
      view ~= findtext.textview
      and
      view ~= replacetext.textview
      and
      view.doc.filename
      or
      view.get_search_doc
    )
  then
    set_target(view)
    Results:clear()
  end
end

--------------------------------------------------------------------------------
-- Register commands
--------------------------------------------------------------------------------
command.add(
  function()
    if core.active_view:is(DocView) or core.active_view.get_search_doc then
      return true, core.active_view
    elseif widget:is_visible() then
      return true, doc_view
    elseif scope:get_selected() == 2 then
      return true, nil
    end
    return false
  end,
  {
    ["search-replace:show"] = function(av)
      show_find(av, false)
    end,

    ["search-replace:toggle"] = function(av)
      show_find(av, true)
    end
  }
)

command.add(function() return widget:is_visible() and not core.active_view:is(CommandView) end, {
  ["search-replace:hide"] = function()
    -- typed and found, then closed: worth keeping, unlike a search that failed
    if #Results.matches > 0 then remember_find() end
    widget:swap_active_child()
    if config.plugins.search_ui.position == "right" then
      widget:hide_animated(false, true)
    else
      widget:hide_animated(true, false)
    end
    if view_is_open(doc_view) then
      core.set_active_view(doc_view)
    end
  end,

  ["search-replace:next"] = function()
    remember_find()
    find(false)
  end,

  ["search-replace:previous"] = function()
    remember_find()
    find(true)
  end,

  ["search-replace:toggle-sensitivity"] = function()
    matchcase:set_checked(not matchcase:is_checked())
    Results:clear()
  end,

  ["search-replace:toggle-regex"] = function()
    regexcheck:set_checked(not regexcheck:is_checked())
    Results:clear()
  end,

  ["search-replace:toggle-in-selection"] = function()
    replaceinselection:set_checked(not replaceinselection:is_checked())
  end
})

-- also from a view searched without being a DocView (a terminal binds it)
command.add(function()
  return widget:is_visible() and not core.active_view:is(CommandView)
    or core.active_view.get_search_doc ~= nil
end, {
  ["search-replace:file-search"] = function()
    set_replace_shown(false)
    toggle_scope(1)
    command.perform "search-replace:show"
  end
})

-- find-replace:replace (ctrl+r) only applies in a doc; in the pane's boxes,
-- show the replace row
command.add(function()
  return widget:is_visible() and scope:get_selected() == 1 and can_replace()
    and (core.active_view == findtext.textview or core.active_view == replacetext.textview)
end, {
  ["search-replace:show-replace"] = function()
    set_replace_shown(true)
  end
})

command.add(function()
  local av = core.active_view
  if widget:is_visible() and (av == findtext.textview or av == replacetext.textview) then
    return true, av.textbox
  end
  return false
end, {
  ["search-replace:previous-history"] = function(box) step_history(box, 1) end,
  ["search-replace:next-history"] = function(box) step_history(box, -1) end
})

-- only from the boxes: focus moved elsewhere by keyboard leaves one the
-- pane's active child
command.add(
  function()
    return widget:is_visible()
      and
      (
        core.active_view == findtext.textview
        or
        core.active_view == replacetext.textview
      )
  end,
  {
    ["search-replace:perform"] = function()
      if scope:get_selected() == 1 then
        if widget.child_active == findtext then
          ---@type core.doc
          local doc = target_doc(doc_view)
          local line1, col1, line2, col2 = doc:get_selection()
          -- correct cursor position to properly search next result
          if line1 ~= line2 or col1 ~= col2 then
            doc:set_selection(
              line1,
              math.max(col1, col2),
              line2,
              math.min(col1, col2)
            )
          end
          remember_find()
          find(false)
        else
          find_replace()
        end
      else
        project_search()
      end
    end
  }
)

--------------------------------------------------------------------------------
-- Override core find/replace commands
--------------------------------------------------------------------------------
local find_replace_find = command.map["find-replace:find"].perform
command.map["find-replace:find"].perform = function(...)
  if config.plugins.search_ui.replace_core_find then
    set_replace_shown(false)
    toggle_scope(1)
    command.perform "search-replace:show"
  else
    find_replace_find(...)
  end
end

local find_replace_replace = command.map["find-replace:replace"].perform
command.map["find-replace:replace"].perform = function(...)
  if config.plugins.search_ui.replace_core_find then
    set_replace_shown(true)
    toggle_scope(1)
    command.perform "search-replace:show"
  else
    find_replace_replace(...)
  end
end

local find_replace_repeat = command.map["find-replace:repeat-find"].perform
command.map["find-replace:repeat-find"].perform = function(...)
  if
    widget:is_visible()
    or
    (config.plugins.search_ui.replace_core_find and findtext:get_text() ~= "")
  then
    remember_find()
    find(false)
    return
  end
  find_replace_repeat(...)
end

local find_replace_previous = command.map["find-replace:previous-find"].perform
command.map["find-replace:previous-find"].perform = function(...)
  if
    widget:is_visible()
    or
    (config.plugins.search_ui.replace_core_find and findtext:get_text() ~= "")
  then
    remember_find()
    find(true)
    return
  end
  find_replace_previous(...)
end

local project_search_find = command.map["project-search:find"].perform
command.map["project-search:find"].perform = function(path)
  if config.plugins.search_ui.replace_core_find then
    toggle_scope(2)
    if path then
      filepicker:set_path(path)
    end
    local av = doc_view
    if
      core.active_view:extends(DocView)
      and
      core.active_view ~= findtext.textview
      and
      core.active_view ~= replacetext.textview
    then
      av = core.active_view
    end
    show_find(av, false)
    return
  end
  project_search_find(path)
end

--------------------------------------------------------------------------------
-- Register keymaps
--------------------------------------------------------------------------------
keymap.add {
  ["alt+h"] = "search-replace:toggle",
  ["escape"] = "search-replace:hide",
  ["f3"] = "search-replace:next",
  ["shift+f3"] = "search-replace:previous",
  ["return"] = "search-replace:perform",
  ["shift+return"] = "search-replace:previous",
  ["ctrl+i"] = "search-replace:toggle-sensitivity",
  ["ctrl+shift+i"] = "search-replace:toggle-regex",
  ["ctrl+alt+i"] = "search-replace:toggle-in-selection",
  ["ctrl+f"] = "search-replace:file-search",
  ["ctrl+r"] = "search-replace:show-replace",
  ["up"] = "search-replace:previous-history",
  ["down"] = "search-replace:next-history"
}


return widget
