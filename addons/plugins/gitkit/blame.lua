local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local tooltip = require "core.tooltip"
local Doc = require "core.doc"
local DocView = require "core.docview"
local git = require "plugins.gitkit.git"
local revision = require "plugins.gitkit.revision"
local diff = require "plugins.gitkit.diff"
local CommitView = require "plugins.gitkit.commitview"

---Blame: a column at the left of a doc's gutter, as GitHub's blame page has,
---showing which commit last changed each line. Lines from the same commit in
---a row form a group: its first line shows the commit's summary and age, the
---second its author and hash, and a bar beside it is brighter the newer the
---commit is (by rank among the file's commits). Shown per doc, in all its
---views: a working copy (unsaved edits too: git gets the editor's text), or a
---file at a revision.
---
---Edits move the lines along at once (edited ones count as not committed),
---and git is asked again a moment after the last edit, after a save or
---reload, and when the view is focused again after HEAD moved (a commit in
---the terminal, say).
local blame = {}

---@class gitkit.blame.commit
---@field hash string
---@field uncommitted boolean The working copy's own lines (git's zero hash)
---@field author? string
---@field time? integer author-time
---@field summary? string
---@field previous? { hash: string, path: string } Its parent, and the file's path there
---@field age number 1 for the file's newest commit, down to 0 for its oldest

---@class gitkit.blame.line
---@field commit gitkit.blame.commit
---@field orig integer The line's number in that commit
---@field path string The file's path in that commit

---@class gitkit.blame.state
---@field lines (gitkit.blame.line|false)[] By doc line; false: edited since
---@field starts integer[]? The first line of each line's group (nil: to compute)
---@field generation integer Of the latest request; older ones' results are dropped
---@field loading boolean
---@field root? string
---@field rel? string The file, as git names it
---@field rev? string The revision blamed, nil for the working copy
---@field head? string HEAD when the working copy was blamed
---@field due? number When a scheduled refresh runs
---@field waiting? boolean A refresh is scheduled

---@type table<core.doc, gitkit.blame.state>
local states = setmetatable({}, { __mode = "k" })

---Whether `doc` can be blamed: a file, or one at a revision.
---@param doc core.doc
---@return boolean
function blame.can_blame(doc)
  return doc.gitkit_revision ~= nil or doc.abs_filename ~= nil
end

---Whether `doc`'s blame is shown.
---@param doc core.doc
---@return boolean
function blame.is_shown(doc)
  return states[doc] ~= nil
end


-- Asking git ------------------------------------------------------------------

-- `git blame --porcelain` parsed: lines by number, and their commits
local function parse(out)
  local commits, lines = {}, {}
  local cur, commit
  for l in out:gmatch("([^\n]*)\n") do
    if l:byte(1) == 9 then
      -- the line's text, after its header
      if cur then
        lines[cur.final] = { commit = cur.commit, orig = cur.orig, path = cur.path or cur.commit.path }
      end
    else
      local hash, orig, final = l:match("^(%x+) (%d+) (%d+)")
      if hash and #hash >= 40 then
        commit = commits[hash]
        if not commit then
          commit = { hash = hash, uncommitted = hash:match("^0+$") ~= nil, age = 1 }
          commits[hash] = commit
        end
        cur = { commit = commit, orig = tonumber(orig), final = tonumber(final) }
      elseif commit then
        local key, value = l:match("^(%S+) ?(.*)$")
        if key == "author" then commit.author = value
        elseif key == "author-time" then commit.time = tonumber(value)
        elseif key == "summary" then commit.summary = value
        elseif key == "previous" then
          local h, p = value:match("^(%x+) (.*)$")
          if h then commit.previous = { hash = h, path = p } end
        elseif key == "filename" then
          cur.path = value
          commit.path = commit.path or value
        end
      end
    end
  end
  -- ages by rank, so that a file's history spread unevenly in time still
  -- gets its range of brightness
  local sorted = {}
  for _, c in pairs(commits) do
    if not c.uncommitted then table.insert(sorted, c) end
  end
  table.sort(sorted, function(a, b) return (a.time or 0) < (b.time or 0) end)
  for i, c in ipairs(sorted) do
    c.age = #sorted > 1 and (i - 1) / (#sorted - 1) or 1
  end
  -- a line git didn't give (it shouldn't happen) counts as edited
  local n = 0
  for i in pairs(lines) do n = math.max(n, i) end
  for i = 1, n do lines[i] = lines[i] or false end
  return lines
end

local run

-- Runs blame again `delay` seconds (default config.plugins.gitkit.blame_delay)
-- from now, unless it's put off again before then.
local function schedule(doc, st, delay)
  st.due = system.get_time() + (delay or config.plugins.gitkit.blame_delay)
  if st.waiting then return end
  st.waiting = true
  core.add_thread(function()
    while states[doc] == st do
      local wait = st.due - system.get_time()
      if wait <= 0 then break end
      coroutine.yield(wait)
    end
    st.waiting = false
    if states[doc] == st then run(doc, st) end
  end)
end

-- Asks git for the doc's blame, in the background.
function run(doc, st)
  st.generation = st.generation + 1
  local generation = st.generation
  st.loading = true
  core.redraw = true
  core.add_thread(function()
    local function cancelled() return states[doc] ~= st or st.generation ~= generation end
    local function fail(err)
      if cancelled() then return end
      states[doc] = nil
      core.redraw = true
      core.warn("Can't blame %s: %s", doc:get_name(), err or "")
    end
    local root, rel, rev, input
    local r = doc.gitkit_revision
    if r then
      root, rel, rev = r.root, r.path, r.rev
    else
      local err
      root, err = git.get_root(doc.abs_filename)
      if not root then return fail(err) end
      rel = git.relative_path(root, doc.abs_filename)
    end
    local args = { "blame", "--porcelain" }
    if rev then
      table.insert(args, rev)
    elseif doc:is_dirty() then
      -- unsaved edits: the editor's text is blamed, as the file's
      table.insert(args, "--contents")
      table.insert(args, "-")
      input = table.concat(doc.lines)
      if doc.crlf then input = input:gsub("\n", "\r\n") end
    end
    table.insert(args, "--")
    table.insert(args, rel)
    local change_id = doc:get_change_id()
    local head = not rev and git.run(root, { "rev-parse", "HEAD" }) or nil
    local out, err = git.run(root, args, { input = input, cancelled = cancelled })
    if cancelled() then return end
    if not out then return fail(err) end
    st.loading = false
    st.root, st.rel, st.rev, st.head = root, rel, rev, head
    if doc:get_change_id() ~= change_id then
      -- edited meanwhile: what git saw is gone (the edits moved the lines
      -- known before along)
      schedule(doc, st)
      return
    end
    st.lines, st.starts = parse(out), nil
    core.redraw = true
  end)
end

---Shows `doc`'s blame.
---@param doc core.doc
function blame.show(doc)
  if states[doc] or not blame.can_blame(doc) then return end
  local st = { lines = {}, generation = 0, loading = true }
  states[doc] = st
  run(doc, st)
end

---Hides `doc`'s blame.
---@param doc core.doc
function blame.hide(doc)
  states[doc] = nil
  core.redraw = true
end

---Shows or hides `doc`'s blame.
---@param doc core.doc
function blame.toggle(doc)
  if states[doc] then blame.hide(doc) else blame.show(doc) end
end


-- Following edits ---------------------------------------------------------------

-- Moves lines `from`.. by `n` (negative: up, dropping those it moves over)
local function shift(lines, from, n)
  local count = #lines
  if from > count + 1 or (n < 0 and from > count) then return end
  if n > 0 then
    table.move(lines, from, count, from + n)
    for i = from, from + n - 1 do lines[i] = false end
  elseif n < 0 then
    table.move(lines, from, count, from + n)
    for i = count + n + 1, count do lines[i] = nil end
  end
end

local raw_insert = Doc.raw_insert
function Doc:raw_insert(line, col, text, ...)
  local st = states[self]
  if st then
    local lines = st.lines
    local _, n = text:gsub("\n", "")
    if col == 1 and text:sub(-1) == "\n" then
      -- whole lines before `line`
      shift(lines, line, n)
    elseif col >= #self.lines[line] and text:sub(1, 1) == "\n" then
      -- lines after the end of `line`, which stays
      shift(lines, line + 1, n)
    else
      shift(lines, line + 1, n)
      if lines[line] ~= nil then lines[line] = false end
    end
    st.starts = nil
    schedule(self, st)
  end
  return raw_insert(self, line, col, text, ...)
end

local raw_remove = Doc.raw_remove
function Doc:raw_remove(line1, col1, line2, col2, ...)
  local st = states[self]
  if st then
    local lines = st.lines
    if col1 == 1 and col2 == 1 then
      -- whole lines
      shift(lines, line2, line1 - line2)
    else
      shift(lines, line2 + 1, line1 - line2)
      if lines[line1] ~= nil then lines[line1] = false end
    end
    st.starts = nil
    schedule(self, st)
  end
  return raw_remove(self, line1, col1, line2, col2, ...)
end

-- saved, loaded or reloaded
local clean = Doc.clean
function Doc:clean(...)
  local st = states[self]
  if st then schedule(self, st, 0) end
  return clean(self, ...)
end

-- HEAD may have moved while the view was in the background
local set_active_view = core.set_active_view
function core.set_active_view(view, ...)
  set_active_view(view, ...)
  local doc = view and view:extends(DocView) and view.doc
  local st = doc and states[doc]
  if st and not st.rev and st.head and not st.loading and not st.waiting then
    core.add_thread(function()
      local head = git.run(st.root, { "rev-parse", "HEAD" })
      if states[doc] == st and not st.loading and head ~= st.head then run(doc, st) end
    end)
  end
end


-- The column -------------------------------------------------------------------

local function group_key(entry)
  if not entry or entry.commit.uncommitted then return false end
  return entry.commit
end

-- The first line of each line's group
local function get_starts(st)
  if st.starts then return st.starts end
  local starts, lines = {}, st.lines
  local start, key
  for i = 1, #lines do
    local k = group_key(lines[i])
    if i == 1 or k ~= key then start, key = i, k end
    starts[i] = start
  end
  st.starts = starts
  return starts
end

-- The group of `line`: its first and last lines, and its first line's entry
local function group_at(st, line)
  local starts = get_starts(st)
  local first = starts[line]
  if not first then return end
  local last = line
  while starts[last + 1] == first do last = last + 1 end
  return { first = first, last = last, entry = st.lines[first] }
end

local function column_width(dv)
  return states[dv.doc] and math.floor(config.plugins.gitkit.blame_width * SCALE) or 0
end

local get_gutter_width = DocView.get_gutter_width
function DocView:get_gutter_width()
  local width, padding = get_gutter_width(self)
  return width + column_width(self), padding
end

local function with_alpha(color, a)
  return { color[1], color[2], color[3], (color[4] or 255) * a }
end

local function draw_column_line(dv, st, line, x, y, w)
  local lh = dv:get_line_height()
  local font = style.font
  local pad = style.padding.x / 2
  local hover = dv.gitkit_blame_hover
  if hover and line >= hover.first and line <= hover.last then
    renderer.draw_rect(x, y, w, lh, style.line_highlight)
  end
  -- the divider before the line numbers
  local dw = math.max(1, math.floor(SCALE))
  renderer.draw_rect(x + w - dw, y, dw, lh, style.divider)
  local minline = dv:get_visible_line_range()
  local starts = get_starts(st)
  local first = starts[line]
  if not first then
    if line == minline and st.loading then
      common.draw_text(font, style.dim, "Blaming…", "left", x + pad, y, 0, lh)
    end
    return
  end
  local entry = st.lines[line]
  local commit = entry and not entry.commit.uncommitted and entry.commit
  local bw = math.max(2, math.floor(3 * SCALE))
  local bar = commit and with_alpha(style.accent, 0.15 + 0.85 * commit.age) or style.good
  renderer.draw_rect(x, y, bw, lh, bar)
  if line == first and line > 1 then
    renderer.draw_rect(x, y, w - dw, dw, style.divider)
  end
  -- the group's label on its first two lines in view
  local nth = line - math.max(first, minline)
  local tx, tw = x + bw + pad, w - bw - pad * 2 - dw
  if nth == 0 then
    if commit then
      local age = commit.time and common.format_age(commit.time) or ""
      local aw = font:get_width(age)
      common.draw_text(font, style.dim, age, "right", tx, y, tw, lh)
      local summary = common.truncate_text(font, commit.summary or "", tw - aw - pad)
      common.draw_text(font, style.text, summary, "left", tx, y, 0, lh)
    else
      common.draw_text(font, style.dim, "Not committed yet", "left", tx, y, 0, lh)
    end
  elseif nth == 1 and commit then
    local hash = revision.short(commit.hash)
    local hw = font:get_width(hash)
    common.draw_text(font, style.dim, hash, "right", tx, y, tw, lh)
    local author = common.truncate_text(font, commit.author or "", tw - hw - pad)
    common.draw_text(font, style.dim, author, "left", tx, y, 0, lh)
  end
end

local draw_line_gutter = DocView.draw_line_gutter
function DocView:draw_line_gutter(line, x, y, width)
  local w = column_width(self)
  if w > 0 then
    local dline = self.get_dline and self:get_dline(line) or line
    draw_column_line(self, states[self.doc], dline, x, y, w)
  end
  return draw_line_gutter(self, line, x + w, y, width - w)
end

-- the commit's facts, below its summary
local function draw_tooltip(dv, hover)
  local commit = hover.entry.commit
  local font = style.font
  local lh = font:get_height()
  local lines = { commit.summary or "" }
  local facts = { revision.short(commit.hash) }
  if commit.author then table.insert(facts, commit.author) end
  if commit.time then
    table.insert(facts, os.date("%Y-%m-%d %H:%M", commit.time) .. " (" .. common.format_age(commit.time) .. ")")
  end
  table.insert(lines, table.concat(facts, " · "))
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, font:get_width(l)) end
  w = w + style.padding.x * 2
  local h = lh * #lines + style.padding.y
  local root = core.root_view.root_node
  local _, ly = dv:get_line_screen_position(hover.line)
  local x = common.clamp(dv.position.x + column_width(dv), 0, root.size.x - w - 1)
  local y = ly + dv:get_line_height()
  if y + h > root.size.y then y = ly - h end
  common.draw_popup_box(x, y, w, h)
  for i, l in ipairs(lines) do
    renderer.draw_text(font, l, x + style.padding.x, y + style.padding.y / 2 + (i - 1) * lh,
      i == 1 and style.text or style.dim)
  end
end

local draw = DocView.draw
function DocView:draw(...)
  draw(self, ...)
  local hover = self.gitkit_blame_hover
  if hover and hover.entry and tooltip.shown(self, hover.entry) then
    core.root_view:defer_draw(draw_tooltip, self, hover)
  end
end


-- The mouse ----------------------------------------------------------------------

local function set_hover(dv, hover)
  local old = dv.gitkit_blame_hover
  if (old and old.first) ~= (hover and hover.first) or (old and old.line) ~= (hover and hover.line) then
    core.redraw = true
  end
  dv.gitkit_blame_hover = hover
  -- uncommitted lines have nothing more to say
  tooltip.hover(dv, hover and hover.entry and not hover.entry.commit.uncommitted and hover.entry or nil)
end

local on_mouse_moved = DocView.on_mouse_moved
function DocView:on_mouse_moved(x, y, ...)
  local res = on_mouse_moved(self, x, y, ...)
  local st = states[self.doc]
  local hover
  if st and not self.mouse_selecting and not self.gutter_selecting
    and x >= self.position.x and x < self.position.x + column_width(self)
    and not self:scrollbar_overlaps_point(x, y) then
    local line = self:resolve_screen_position(x, y)
    hover = group_at(st, line)
    if hover then
      hover.line = line
      self.cursor = "hand"
    end
  end
  set_hover(self, hover)
  return res
end

local on_mouse_left = DocView.on_mouse_left
function DocView:on_mouse_left(...)
  set_hover(self, nil)
  return on_mouse_left(self, ...)
end

local on_mouse_pressed = DocView.on_mouse_pressed
function DocView:on_mouse_pressed(button, x, y, clicks)
  local hover = self.gitkit_blame_hover
  if hover and button == "left" then
    tooltip.dismiss()
    blame.show_commit(self, hover)
    return true
  end
  return on_mouse_pressed(self, button, x, y, clicks)
end


-- Actions on a group ------------------------------------------------------------

---@class gitkit.blame.group
---@field first integer
---@field last integer
---@field line integer The one under the pointer
---@field entry gitkit.blame.line|false

---The group under the pointer in `dv`'s blame column, if any.
---@param dv core.docview
---@return gitkit.blame.group?
function blame.hovered(dv)
  return dv.gitkit_blame_hover
end

---Shows a group's commit in the commit view (focused), at the file's patch;
---for uncommitted lines, the file's uncommitted changes.
---@param dv core.docview
---@param group gitkit.blame.group
function blame.show_commit(dv, group)
  local st = states[dv.doc]
  if not st or not st.root then return end
  local entry = group.entry
  local spec, path
  if entry and not entry.commit.uncommitted then
    spec = { rev = entry.commit.hash, title = revision.short(entry.commit.hash) }
    path = entry.path
  else
    spec = { from = "HEAD", paths = { st.rel },
             title = common.basename(st.rel) .. ": HEAD" .. diff.RENAME_ARROW .. "Working Tree" }
    path = st.rel
  end
  local cv = CommitView.place(nil)
  cv:show_diff(st.root, spec, { scroll_to = path })
  core.set_active_view(cv)
end

---Opens the file as it was before a group's commit, with its blame (GitHub's
---"blame prior to this change"), at about the group's line.
---@param dv core.docview
---@param group gitkit.blame.group
function blame.show_previous(dv, group)
  local st = states[dv.doc]
  local entry = group.entry
  local previous = entry and entry.commit.previous
  if not (st and st.root and previous) then return end
  revision.open(st.root, previous.hash, previous.path, entry.orig, nil, blame.show)
end

---The repository and commit of a group (nil if it's uncommitted).
---@param dv core.docview
---@param group gitkit.blame.group
---@return string? root, gitkit.blame.commit? commit
function blame.group_commit(dv, group)
  local st = states[dv.doc]
  local entry = group.entry
  if st and entry and not entry.commit.uncommitted then return st.root, entry.commit end
end

return blame
