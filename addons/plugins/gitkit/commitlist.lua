local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local ResultsList = require "core.resultslist"
local git = require "plugins.gitkit.git"
local diff = require "plugins.gitkit.diff"
local revision = require "plugins.gitkit.revision"
local CommitView = require "plugins.gitkit.commitview"

---A repository's commits (or a file's), newest first, a tab in the bottom
---panel (core.panel): hash, date, author, branches and tags, subject. Above
---them, uncommitted changes, if there are any. Stepping through them (as
---core.resultslist does results) shows the selected one in a commit view
---(gitkit.commitview) in the editor area, the focus staying in the list;
---Enter or a double click focuses it.
---@class gitkit.commitlist : core.view
local CommitList = View:extend()

function CommitList:__tostring() return "CommitList" end

CommitList.context = "session"

---@class gitkit.commit
---@field hash? string nil for uncommitted changes
---@field short? string
---@field author? string
---@field time? integer
---@field refs? string Branches and tags pointing at it, as git log's %D
---@field subject string

---@param root string The repository's top directory
---@param path? string A file (as git names it) whose history to list
function CommitList:new(root, path)
  CommitList.super.new(self)
  self.scrollable = true
  self.selected_idx, self.hovered_idx = 0, 0
  self.generation = 0
  self:load(root, path)
end

---Lists the commits of the repository at `root` (of `path` in it, if given),
---in the background, from the top.
---@param root string
---@param path? string
function CommitList:load(root, path)
  self.root, self.path = root, path
  self.commits = {}
  self.selected_idx, self.hovered_idx = 0, 0
  self.scroll.y, self.scroll.to.y = 0, 0
  self.error = nil
  self.loading = true
  self.generation = self.generation + 1
  local generation = self.generation
  local function current() return self.generation == generation end
  core.add_thread(function()
    local paths = path and { "--", path } or {}
    -- uncommitted changes (to tracked files)
    local changed = git.run(root, { "diff", "HEAD", "--name-only", table.unpack(paths) })
    if not current() then return end
    if changed and changed ~= "" then
      table.insert(self.commits, { subject = "Uncommitted changes" })
    end
    local args = { "log", "--format=%H%x1f%h%x1f%an%x1f%at%x1f%D%x1f%s%x1e",
                   "-n", tostring(config.plugins.gitkit.max_commits) }
    if path then table.insert(args, "--follow") end
    for _, a in ipairs(paths) do table.insert(args, a) end
    local buffer = ""
    local _, err = git.run(root, args, {
      cancelled = function() return not current() end,
      on_data = function(chunk)
        buffer = buffer .. chunk
        local pos = 1
        while true do
          local e = buffer:find("\30", pos, true)
          if not e then break end
          local rec = buffer:sub(pos, e - 1):gsub("^\n", "")
          local hash, short, author, time, refs, subject =
            rec:match("^(%x+)\31([^\31]*)\31([^\31]*)\31(%d*)\31([^\31]*)\31(.*)$")
          if hash then
            table.insert(self.commits, {
              hash = hash, short = short, author = author, time = tonumber(time),
              refs = refs ~= "" and refs or nil, subject = subject,
            })
          end
          pos = e + 1
        end
        buffer = buffer:sub(pos)
        core.redraw = true
      end,
    })
    if not current() then return end
    self.loading = false
    if err and #self.commits == 0 then self.error = err end
    core.redraw = true
  end)
end

---Lists them again, from the top.
function CommitList:refresh()
  self:load(self.root, self.path)
end


function CommitList:get_name()
  if self.path then return "History: " .. common.basename(self.path) end
  return "Git Log: " .. common.basename(self.root)
end

function CommitList:get_name_color()
  return self.error and style.error or nil
end

function CommitList:get_progress()
  return self.loading or nil
end

function CommitList:get_tab_tooltip_info()
  local info = { common.home_encode(self.root) }
  if self.path then table.insert(info, self.path) end
  table.insert(info, self.loading and "loading…" or (#self.commits .. " entries"))
  if self.error then table.insert(info, self.error) end
  return info
end

function CommitList:is_transient()
  return true
end


-- for core.resultslist
function CommitList:get_result_count() return #self.commits end

function CommitList:get_result_location(idx)
  return nil
end

function CommitList:get_selected_index()
  return self.selected_idx > 0 and self.selected_idx or nil
end

function CommitList:set_selected_index(idx)
  self.selected_idx = idx
  local h = self:get_line_height()
  self.scroll.to.y = math.min(self.scroll.to.y, h * (idx - 1))
  self.scroll.to.y = math.max(self.scroll.to.y, h * idx - self.size.y)
end

function CommitList:get_page_size()
  return math.max(1, math.floor(self.size.y / self:get_line_height()) - 1)
end

---The commit view showing this list's commits, if it's open.
---@return gitkit.commitview?
function CommitList:get_commit_view()
  local cv = self.commit_view
  if cv and core.root_view.root_node:get_node_for_view(cv) then return cv end
end

-- Shows the commit view, made if needed, in the editor node used last; the
-- focus stays where it is.
local function place_commit_view(self)
  local cv = self:get_commit_view()
  local av = core.active_view
  if cv then
    local node = core.root_view.root_node:get_node_for_view(cv)
    node:set_active_view(cv)
  else
    cv = CommitView()
    cv.list = self
    self.commit_view = cv
    core.root_view:get_last_used_node():add_view(cv)
  end
  core.set_active_view(av)
  return cv
end

---Shows commit `idx` in the commit view (git asked in the background).
---@param idx integer
function CommitList:show_commit(idx)
  local commit = self.commits[idx]
  if not commit then return end
  local cv = place_commit_view(self)
  cv.shown_idx = idx
  cv.generation = (cv.generation or 0) + 1
  local generation = cv.generation
  local root, path = self.root, self.path
  cv.loading = true
  core.add_thread(function()
    local args
    local opts = { "--stat=120", "--patch", "--src-prefix=a/", "--dst-prefix=b/", "--no-ext-diff" }
    if commit.hash then
      args = { "show", "--format=medium", "--diff-merges=first-parent" }
    else
      args = { "diff", "HEAD" }
    end
    for _, a in ipairs(opts) do table.insert(args, a) end
    if commit.hash then table.insert(args, commit.hash) end
    local out, err, truncated = git.run(root, args, {
      max_bytes = config.plugins.gitkit.max_diff_bytes,
      cancelled = function() return cv.generation ~= generation end,
    })
    if cv.generation ~= generation then return end
    cv.loading = false
    if not out then
      core.error("git %s: %s", args[1], err)
      return
    end
    local result = diff.parse(out, commit.hash ~= nil, truncated)
    local title = commit.hash and ("Commit " .. revision.short(commit.hash)) or "Uncommitted"
    cv:set_result(result, {
      root = root, rev = commit.hash, parent = commit.hash and commit.hash .. "^" or "HEAD",
      title = title,
    })
    if path then cv:scroll_to_file(path) end
  end)
end

-- core.resultslist's, with commits for files
function CommitList:select(idx)
  local count = self:get_result_count()
  if count == 0 then return end
  idx = common.clamp(idx, 1, count)
  self:set_selected_index(idx)
  if core.root_view:can_peek(self) then self:show_commit(idx) end
end

function CommitList:open_selected()
  if not self:get_selected_index() then self:select(1) end
  local idx = self:get_selected_index()
  if not idx then return end
  local cv = self:get_commit_view()
  if not cv or cv.shown_idx ~= idx then self:show_commit(idx) end
  cv = self:get_commit_view()
  if cv then core.set_active_view(cv) end
end


function CommitList:get_line_height()
  return style.padding.y + math.max(style.font:get_height(), style.code_font:get_height())
end

function CommitList:get_scrollable_size()
  return (#self.commits + 1) * self:get_line_height()
end

function CommitList:row_at(mx, my)
  local x, y = self:get_content_offset()
  local idx = math.floor((my - y) / self:get_line_height()) + 1
  if mx >= self.position.x and idx >= 1 and idx <= #self.commits then return idx end
end

function CommitList:on_mouse_moved(mx, my, ...)
  CommitList.super.on_mouse_moved(self, mx, my, ...)
  self.hovered_idx = (not self:scrollbar_hovering() and self:row_at(mx, my)) or 0
end

function CommitList:on_mouse_pressed(button, x, y, clicks)
  local caught = CommitList.super.on_mouse_pressed(self, button, x, y, clicks)
  if not caught and button == "left" and self.hovered_idx > 0 then
    self:click_result(self.hovered_idx, clicks)
    return true
  end
end

function CommitList:on_mouse_left()
  CommitList.super.on_mouse_left(self)
  self.hovered_idx = 0
end


local function draw_clipped(font, color, text, x, y, w, h)
  core.push_clip_rect(x, y, w, h)
  common.draw_text(font, color, text, "left", x, y, 0, h)
  core.pop_clip_rect()
end

function CommitList:draw()
  self:draw_background(style.background)
  local lh = self:get_line_height()
  local ox, oy = self:get_content_offset()
  local px = style.padding.x
  local x0 = ox + px
  if #self.commits == 0 then
    local msg = self.error or (self.loading and "Loading…" or "No commits")
    common.draw_text(style.font, self.error and style.error or style.dim, msg, "left",
      x0, oy, 0, lh)
    self:draw_scrollbar()
    return
  end
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  local hash_w = style.code_font:get_width("00000000")
  local date_w = style.font:get_width("0000-00-00 00:00")
  local author_w = math.floor(140 * SCALE)
  local first = math.max(1, math.floor((self.position.y - oy) / lh) + 1)
  local last = math.min(#self.commits, first + math.ceil(self.size.y / lh))
  for i = first, last do
    local c = self.commits[i]
    local y = oy + (i - 1) * lh
    local selected = i == self.selected_idx
    if selected then
      renderer.draw_rect(self.position.x, y, self.size.x, lh, style.selection)
    elseif i == self.hovered_idx then
      renderer.draw_rect(self.position.x, y, self.size.x, lh, style.line_highlight)
    end
    local dim = selected and style.text or style.dim
    local x = x0
    if c.hash then
      draw_clipped(style.code_font, dim, c.short, x, y, hash_w, lh)
      x = x + hash_w + px
      draw_clipped(style.font, dim, os.date("%Y-%m-%d %H:%M", c.time), x, y, date_w, lh)
      x = x + date_w + px
      draw_clipped(style.font, style.text, c.author, x, y, author_w, lh)
      x = x + author_w + px
      if c.refs then
        x = common.draw_text(style.font, style.accent, "(" .. c.refs .. ")", "left", x, y, 0, lh) + px / 2
      end
      common.draw_text(style.font, style.text, c.subject, "left", x, y, 0, lh)
    else
      x = x + hash_w + px
      common.draw_text(style.font, style.warn, c.subject, "left", x, y, 0, lh)
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end


ResultsList.add_to(CommitList, "gitkit-log")

return CommitList
