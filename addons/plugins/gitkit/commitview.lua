local core = require "core"
local common = require "core.common"
local style = require "core.style"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
local DocView = require "core.docview"
local ReadDoc = require "plugins.gitkit.readdoc"
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
---@field rev? string The commit's hash; nil for uncommitted changes
---@field parent? string The revision its old side is ("HEAD" if uncommitted)
---@field title string The tab's title

function CommitView:new()
  CommitView.super.new(self, ReadDoc("Commit"))
  self:set_result(diff.parse("", false), { title = "Commit" })
end

---Shows a parsed commit, from the top.
---@param result gitkit.diff.result
---@param meta gitkit.commitview.meta
function CommitView:set_result(result, meta)
  self.result, self.meta, self.infos = result, meta, result.infos
  -- tokens by line, and the tokenizer's states (new side, old) after them
  self.tokens, self.states = {}, {}
  local max = 1
  for _, info in ipairs(result.infos) do
    max = math.max(max, info.old or 0, info.new or 0)
  end
  self.number_digits = #tostring(max)
  self.doc.name = meta.title
  self.doc:set_text(result.lines)
  self.scroll.x, self.scroll.to.x = 0, 0
  self.scroll.y, self.scroll.to.y = 0, 0
  core.redraw = true
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
-- backgrounds) and style.gitkit_file (a file's title line's)
local function line_bg(kind)
  if kind == "add" then
    return style.gitkit_added or common.lerp(style.background, style.good, 0.2)
  elseif kind == "del" then
    return style.gitkit_removed or common.lerp(style.background, style.error, 0.2)
  elseif kind == "file" then
    return style.gitkit_file or common.lerp(style.background, style.text, 0.1)
  end
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
  if bg and info.kind ~= "file" then
    renderer.draw_rect(x, y, self:get_gutter_width() - self:get_gutter_gap(), lh, bg)
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

function CommitView:draw_line_body(line, x, y)
  local bg = line_bg((self.infos[line] or {}).kind)
  if bg then
    renderer.draw_rect(self.position.x, y, self.size.x, self:get_line_height(), bg)
  end
  return CommitView.super.draw_line_body(self, line, x, y)
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
    tokens = { "s:keyword", text }
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
    tx = renderer.draw_text(font, text, tx, ty, token_color(tokens[i]))
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
