local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
local panel = require "core.panel"
local DocView = require "core.docview"
local ReadDoc = require "plugins.gitkit.readdoc"
local git = require "plugins.gitkit.git"
local diff = require "plugins.gitkit.diff"
local revision = require "plugins.gitkit.revision"

---A commit as `git show --stat --patch` shows it (or uncommitted changes as
---`git diff`), in a read-only doc: patch lines without their +/- prefix, on
---green or red, their numbers in the old and new file in the gutter, their
---code highlighted in the file's syntax. Enter or ctrl+click on a line opens
---its file as it was there (the new side; the old for a removed line), at
---that line; on a stat line, goes to the file's patch.
---@class gitkit.commitview : core.docview
---@field doc gitkit.readdoc
local CommitView = DocView:extend()

function CommitView:__tostring() return "CommitView" end

CommitView.context = "session"

---@class gitkit.commitview.meta
---@field root string The repository's top directory
---@field rev? string The revision its new side is (the commit's hash); nil
---for the working tree
---@field parent? string The revision its old side is ("HEAD" if uncommitted)
---@field title string The tab's title
---@field spec? gitkit.diffspec What it shows

---What a commit view shows: a commit, as `git show` does, or a comparison of
---two revisions, or of one with the working tree, as `git diff` does.
---@class gitkit.diffspec
---@field rev? string A commit, shown with its message
---@field from? string Else the old side of a comparison
---@field to? string and its new side; nil for the working tree
---@field paths? string[] Only these files (as git names them)
---@field title string The tab's title
---@field key? string The commit list's key of what's shown, if it's one of its rows

-- Searchable with search_ui (ctrl+f), as a terminal is: core's find takes only
-- plain DocViews ("core.docview!"), and search_ui other views through this
function CommitView:get_search_doc()
  return self.doc
end

-- every commit view made, to refresh those comparing with the working tree
local all_views = setmetatable({}, { __mode = "k" })

function CommitView:new()
  CommitView.super.new(self, ReadDoc("Commit"))
  self:set_result(diff.parse("", false), { title = "Commit" })
  all_views[self] = true
end

---The current commit view (core.panel's: the one commits and comparisons are
---shown in, until its tab is double-clicked to keep it), made if needed in the
---editor node used last, in front of its node, now showing `list`'s commits
---(nil for none). The focus stays where it is.
---@param list? gitkit.commitlist
---@return gitkit.commitview
function CommitView.place(list)
  local cv = panel.current(CommitView)
  local av = core.active_view
  if cv then
    local node = core.root_view.root_node:get_node_for_view(cv)
    if node then node:set_active_view(cv) end
  else
    cv = CommitView()
    core.root_view:get_last_used_node():add_view(cv)
    panel.set_current(cv)
  end
  cv.list = list
  core.set_active_view(av)
  return cv
end

---Shows again, as they are now, the open commit views that compare a revision
---of the repository at `root` with its working tree (or show uncommitted
---changes), keeping their place.
---@param root string
function CommitView.reload_working_tree(root)
  for cv in pairs(all_views) do
    if cv.meta.root == root and cv:shows_working_tree()
      and core.root_view.root_node:get_node_for_view(cv) then
      cv:reload()
    end
  end
end

---Shows a parsed commit, from the top; with `keep_place`, scrolled and with
---the caret where it was (uncommitted changes shown again as they are now).
---@param result gitkit.diff.result
---@param meta gitkit.commitview.meta
---@param keep_place? boolean
function CommitView:set_result(result, meta, keep_place)
  self.result, self.meta, self.infos = result, meta, result.infos
  -- tokens by line, and the tokenizer's states (new side, old) after them
  self.tokens, self.states = {}, {}
  local max = 1
  for _, info in ipairs(result.infos) do
    max = math.max(max, info.old or 0, info.new or 0)
  end
  self.number_digits = #tostring(max)
  self.doc.name = meta.title
  local line, col = self.doc:get_selection()
  self.doc:set_text(result.lines)
  if keep_place then
    line = math.min(line, #self.doc.lines)
    self.doc:set_selection(line, math.min(col, #self.doc.lines[line]))
  else
    self.scroll.x, self.scroll.to.x = 0, 0
    self.scroll.y, self.scroll.to.y = 0, 0
  end
  core.redraw = true
end

---Shows what `spec` says, of the repository at `root` (git asked in the
---background). `opts.keep_place`: shown again (refreshed), scrolled and with
---the caret where it was; `opts.scroll_to`: a file (as git names it) to scroll
---to the patch of.
---@param root string
---@param spec gitkit.diffspec
---@param opts? { keep_place?: boolean, scroll_to?: string }
function CommitView:show_diff(root, spec, opts)
  opts = opts or {}
  self.shown_key = spec.key
  self.generation = (self.generation or 0) + 1
  local generation = self.generation
  self.loading = true
  core.add_thread(function()
    local args
    if spec.rev then
      args = { "show", "--format=medium", "--diff-merges=first-parent" }
    else
      args = { "diff" }
    end
    for _, a in ipairs({ "--stat=120", "--patch", "--src-prefix=a/", "--dst-prefix=b/",
                         "--no-ext-diff" }) do
      table.insert(args, a)
    end
    table.insert(args, spec.rev or spec.from)
    if spec.to then table.insert(args, spec.to) end
    if spec.paths then
      table.insert(args, "--")
      for _, p in ipairs(spec.paths) do table.insert(args, p) end
    end
    local out, err, truncated = git.run(root, args, {
      max_bytes = config.plugins.gitkit.max_diff_bytes,
      cancelled = function() return self.generation ~= generation end,
    })
    if self.generation ~= generation then return end
    self.loading = false
    if not out then
      core.error("git %s: %s", args[1], err)
      return
    end
    -- a comparison of the same: said, rather than an empty view
    if out == "" and not spec.rev then out = "No differences.\n" end
    self:set_result(diff.parse(out, spec.rev ~= nil, truncated), {
      root = root, rev = spec.rev or spec.to,
      parent = spec.rev and spec.rev .. "^" or spec.from,
      title = spec.title, spec = spec,
    }, opts.keep_place)
    if opts.scroll_to and not opts.keep_place then self:scroll_to_file(opts.scroll_to) end
  end)
end

---Shows the same again, as it is now (a comparison with the working tree,
---after changes in it), keeping its place.
function CommitView:reload()
  local meta = self.meta
  if meta.root and meta.spec then self:show_diff(meta.root, meta.spec, { keep_place = true }) end
end

---Whether its new side is the working tree.
---@return boolean
function CommitView:shows_working_tree()
  local spec = self.meta.spec
  return spec ~= nil and not spec.rev and not spec.to
end

---The file whose patch, or stat line, is at `line`, if any.
---@param line integer
---@return gitkit.diff.file?
function CommitView:get_file_at(line)
  local info = self.infos[line]
  if not info then return end
  if info.kind == "stat" then return self.result.files[info.stat] end
  return info.file
end

function CommitView:get_name()
  return self.meta.title
end

function CommitView:get_filename()
  return self.meta.title
end

-- not restored with the workspace: the commit list that shows commits in it isn't
function CommitView:is_transient()
  return true
end


-- Colors: a theme can set style.gitkit_added, style.gitkit_removed (line
-- backgrounds), style.gitkit_file (a file's header's: its title line and the
-- empty one above) and style.gitkit_file_border (the line atop the header)
local function line_bg(kind)
  if kind == "add" then
    return style.gitkit_added or common.lerp(style.background, style.good, 0.2)
  elseif kind == "del" then
    return style.gitkit_removed or common.lerp(style.background, style.error, 0.2)
  elseif kind == "file" or kind == "pad" then
    return style.gitkit_file or common.lerp(style.background, style.text, 0.1)
  end
end

-- a status color (style.good, ...) as text: toward the text color, which
-- light themes' pale ones need on their background
local function text_color(color)
  return common.lerp(color, style.text, 0.35)
end

local function is_header(kind) return kind == "file" or kind == "pad" end

local bold_fonts = setmetatable({}, { __mode = "k" })

-- a bold copy of a font (synthesized, same advances), made once per font
local function bold_font(font)
  if not bold_fonts[font] then
    bold_fonts[font] = font:copy(font:get_size(), { bold = true })
  end
  return bold_fonts[font]
end


-- the gutter: the old line number, the new, and + or -
function CommitView:get_gutter_width()
  local font = self:get_font()
  local padding = style.padding.x * 1.5 + self:get_gutter_gap()
  local nw = font:get_width(string.rep("0", self.number_digits))
  local sw = font:get_width(" ")
  return nw * 2 + sw * 3 + font:get_width("+") + padding, padding
end

function CommitView:draw_line_gutter(line, x, y, width)
  local lh = self:get_line_height()
  local info = self.infos[line]
  if not info then return lh end
  local bg = line_bg(info.kind)
  if bg then
    -- headers across the gap too, joining the text area's band
    local w = self:get_gutter_width() - (is_header(info.kind) and 0 or self:get_gutter_gap())
    renderer.draw_rect(x, y, w, lh, bg)
    if info.kind == "pad" then self:draw_header_border(x, y, w) end
  end
  local color = style.line_number
  for _, line1, _, line2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      color = style.line_number2
      break
    end
  end
  local font = self:get_font()
  local nw = font:get_width(string.rep("0", self.number_digits))
  local sw = font:get_width(" ")
  x = x + style.padding.x
  if info.kind ~= "hunk" then
    if info.old then common.draw_text(font, color, info.old, "right", x, y, nw, lh) end
    if info.new then common.draw_text(font, color, info.new, "right", x + nw + sw, y, nw, lh) end
  end
  if info.kind == "file" then
    self:draw_file_icon(info.file, x + nw * 2 + sw * 3 + font:get_width("+"), y, lh)
  end
  local mark = info.kind == "add" and "+" or info.kind == "del" and "-"
  if mark then
    common.draw_text(font, info.kind == "add" and style.good or style.error, mark, "left",
      x + nw * 2 + sw * 3, y, 0, lh)
  end
  return lh
end


function CommitView:draw_line_highlight(x, y)
  -- the caret's line, unless on a colored band
  local line = self.doc:get_selection()
  if not line_bg((self.infos[line] or {}).kind) then
    CommitView.super.draw_line_highlight(self, x, y)
  end
end

-- A rule atop a file's header, from x across the view.
function CommitView:draw_header_border(x, y, w)
  local color = style.gitkit_file_border or common.lerp(style.background, style.text, 0.35)
  renderer.draw_rect(x, y, w, math.max(1, math.floor(SCALE + 0.5)), color)
end

-- The file's icon (the treeview's, or an icon plugin's), right-aligned at x.
function CommitView:draw_file_icon(file, x, y, h)
  local TreeView = package.loaded["plugins.treeview"]
  if not (TreeView and TreeView.get_item_icon) then return end
  local name = common.basename(file.new_path or file.old_path)
  local icon, font, color = TreeView:get_item_icon({ type = "file", name = name }, false, false)
  if icon and font then
    common.draw_text(font, color or style.text, icon, "right", x - font:get_width(icon), y,
      font:get_width(icon), h)
  end
end

-- After a file's title: how it changed, as a tag, and its added and removed
-- lines, at the view's right edge.
function CommitView:draw_file_extras(file, line, x, y)
  local lh = self:get_line_height()
  local font = self:get_font()
  local px = style.padding.x
  local tx = x + self:get_col_x_offset(line, #self.doc.lines[line]) + px
  local tags = {}
  local status = diff.file_status(file)
  if status then table.insert(tags, status) end
  if file.binary then table.insert(tags, "binary") end
  for _, tag in ipairs(tags) do
    local color = (tag == "new" and style.good) or (tag == "deleted" and style.error)
      or (tag == "binary" and style.text) or style.accent
    local tfont = style.font
    local tw, th = tfont:get_width(tag), tfont:get_height()
    local pad = math.floor(px / 2)
    local bh = math.min(lh, th + 2 * math.floor(SCALE))
    renderer.draw_rect(tx, y + (lh - bh) / 2, tw + pad * 2, bh, { color[1], color[2], color[3], 50 })
    common.draw_text(tfont, text_color(color), tag, "center", tx, y, tw + pad * 2, lh)
    tx = tx + tw + pad * 2 + pad
  end
  -- right to left: removed, then added (each only if any)
  local right = self.position.x + self.size.x - px - style.scrollbar_size
  for _, count in ipairs({ { file.removed, "−", style.error }, { file.added, "+", style.good } }) do
    if count[1] > 0 then
      local text = count[2] .. count[1]
      local w = font:get_width(text)
      common.draw_text(font, text_color(count[3]), text, "left", right - w, y, w, lh)
      right = right - w - px / 2
    end
  end
end

function CommitView:draw_line_body(line, x, y)
  local info = self.infos[line] or {}
  local bg = line_bg(info.kind)
  if bg then
    renderer.draw_rect(self.position.x, y, self.size.x, self:get_line_height(), bg)
    if info.kind == "pad" then self:draw_header_border(self.position.x, y, self.size.x) end
  end
  local lh = CommitView.super.draw_line_body(self, line, x, y)
  if info.kind == "file" then self:draw_file_extras(info.file, line, x, y) end
  return lh
end


-- A token's color: a name of style.syntax prefixed with "s:", else of style
local function token_color(name)
  if name:sub(1, 2) == "s:" then
    return style.syntax[name:sub(3)] or style.syntax.normal
  end
  return style[name] or style.text
end

local function syntax_tokens(syn, text, state)
  local t, resume
  t, state, resume = tokenizer.tokenize(syn, text, state)
  while resume do t, state, resume = tokenizer.tokenize(syn, text, state, resume) end
  local res = {}
  for _, type, s in tokenizer.each_token(t) do
    table.insert(res, "s:" .. type)
    table.insert(res, s)
  end
  return res, state
end

-- Tokenizes a hunk's lines up to `line` from the last one done: added and
-- context lines continue the new file's state, removed ones the old's
function CommitView:tokenize_patch(line)
  local info = self.infos[line]
  local hunk, file = info.hunk, info.file
  if file.syntax == nil then
    file.syntax = syntax.get(file.new_path or file.old_path)
  end
  local start = line
  while start > hunk.first and not self.states[start - 1] do start = start - 1 end
  local prev = self.states[start - 1] or {}
  local new_state, old_state = prev[1], prev[2]
  for i = start, line do
    local inf, text = self.infos[i], self.doc.lines[i]
    if inf.kind == "add" then
      self.tokens[i], new_state = syntax_tokens(file.syntax, text, new_state)
    elseif inf.kind == "del" then
      self.tokens[i], old_state = syntax_tokens(file.syntax, text, old_state)
    elseif inf.kind == "ctx" then
      self.tokens[i], new_state = syntax_tokens(file.syntax, text, new_state)
      old_state = new_state
    else
      self.tokens[i] = { "dim", text }
    end
    self.states[i] = { new_state, old_state }
  end
end

---The line's tokens: pairs of a color's name (token_color) and text.
---@param line integer
---@return string[]
function CommitView:get_line_tokens(line)
  local tokens = self.tokens[line]
  if tokens then return tokens end
  local info, text = self.infos[line], self.doc.lines[line]
  local kind = info and info.kind
  if kind == "add" or kind == "del" or kind == "ctx" then
    self:tokenize_patch(line)
    return self.tokens[line]
  elseif kind == "commit" then
    local word, hash, rest = text:match("^(%S+%s+)(%x+)(.*)$")
    tokens = word and { "s:keyword", word, "s:literal", hash, "accent", rest } or { "text", text }
  elseif kind == "header" then
    local label, rest = text:match("^(%a+:)(.*)$")
    tokens = label and { "dim", label, "text", rest } or { "dim", text }
  elseif kind == "stat" then
    local path, sep, rest = text:match("^(.-)( | )(.*)$")
    tokens = { "text", path, "dim", sep }
    local n, plus, minus, tail = rest:match("^(%s*%d+ )(%+*)(%-*)(.*)$")
    if n then
      for _, t in ipairs({ "text", n, "good", plus, "error", minus, "dim", tail }) do
        table.insert(tokens, t)
      end
    else
      table.insert(tokens, "dim")
      table.insert(tokens, rest)
    end
  elseif kind == "file" then
    -- directories dim, names bold; a rename's old name too, less so
    tokens = {}
    local function add_path(path, name_color)
      local dir, name = path:match("^(.*/)([^/]*)$")
      if dir then
        table.insert(tokens, "dim")
        table.insert(tokens, dir)
      end
      table.insert(tokens, name_color)
      table.insert(tokens, name or path)
    end
    local file = info.file
    local title = text:gsub("\n$", "")
    if title == diff.file_title(file) and title:find(diff.RENAME_ARROW, 1, true)
       and file.old_path and file.new_path then
      add_path(file.old_path, "text")
      table.insert(tokens, "dim")
      table.insert(tokens, diff.RENAME_ARROW)
      add_path(file.new_path, "bold")
    else
      add_path(title, "bold")
    end
  elseif kind == "hunk" then
    local range, rest = text:match("^(@@.-@@)(.*)$")
    tokens = range and { "dim", range, "s:function", rest } or { "dim", text }
  elseif kind == "message" then
    tokens = { "text", text }
  else
    tokens = { "dim", text }
  end
  self.tokens[line] = tokens
  return tokens
end

function CommitView:draw_line_text(line, x, y)
  local font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local tokens = self:get_line_tokens(line)
  local right = self.position.x + self.size.x
  for i = 1, #tokens, 2 do
    local text = tokens[i + 1]:gsub("\n$", "")
    local name = tokens[i]
    if name == "bold" then
      tx = renderer.draw_text(bold_font(font), text, tx, ty, style.text)
    else
      tx = renderer.draw_text(font, text, tx, ty, token_color(name))
    end
    if tx > right then break end
  end
  local hx, hy = self:get_ctrl_hover()
  if hx and self:resolve_screen_position(hx, hy) == line and self:get_target(line, 1) then
    local text = self.doc.lines[line]
    local first, last = text:find("%S"), #text:match("^(.-)%s*$")
    if first then self:draw_ctrl_hover(line, x, y, first, last + 1) end
  end
  return self:get_line_height()
end


---@class gitkit.commitview.target
---@field view_line? integer A line of this view to go to (a stat line's file)
---@field rev? string The revision to open the file at; nil: the working tree's
---@field path? string The file, as git names it
---@field line? integer
---@field col? integer

---What Enter or ctrl+click at line, col opens: nil if nothing.
---@param line integer
---@param col integer
---@return gitkit.commitview.target?
function CommitView:get_target(line, col)
  local info = self.infos[line]
  if not info then return end
  local kind, meta = info.kind, self.meta
  if kind == "stat" then
    local file = self.result.files[info.stat]
    return file and { view_line = file.line }
  end
  local file = info.file
  if not file or file.binary or kind == "nonl" then return end
  local new_side, n = file.new_path ~= nil, 1
  if kind == "del" then
    new_side, n = false, info.old
  elseif kind == "add" or kind == "ctx" then
    n = info.new
  elseif kind == "hunk" then
    n = new_side and info.new or info.old
    col = 1
  else
    col = 1
  end
  if new_side then
    return { rev = meta.rev, path = file.new_path, line = n, col = col }
  end
  return { rev = meta.parent, path = file.old_path, line = n, col = col }
end

---Opens a target (get_target).
---@param target gitkit.commitview.target
function CommitView:open_target(target)
  if target.view_line then
    self.doc:set_selection(target.view_line, 1)
    self:scroll_to_line(target.view_line, false, false)
    -- the file's title at the top
    local lh = self:get_line_height()
    self.scroll.to.y = math.max(0, (target.view_line - 1) * lh)
    return
  end
  revision.open(self.meta.root, target.rev, target.path, target.line, target.col)
end

---Scrolls to the patch of the file at `path` (either side), if it's in the commit.
---@param path string
function CommitView:scroll_to_file(path)
  for _, file in ipairs(self.result.files) do
    if file.new_path == path or file.old_path == path then
      self:open_target({ view_line = file.line })
      self.scroll.y = self.scroll.to.y
      return
    end
  end
end

return CommitView
