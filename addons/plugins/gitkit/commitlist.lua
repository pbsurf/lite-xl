local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"
local ResultsList = require "core.resultslist"
local git = require "plugins.gitkit.git"
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
---@field path? string In a file's history, the file's name in this commit

-- the key a commit is found by after a refresh
local function commit_key(commit)
  return commit and (commit.hash or "uncommitted")
end

---@param root string The repository's top directory
---@param path? string A file (as git names it) whose history to list
function CommitList:new(root, path)
  CommitList.super.new(self)
  self.scrollable = true
  self.selected_idx, self.hovered_idx = 0, 0
  self.generation = 0
  self.commits = {}
  self:load(root, path)
end


-- Refreshing: open lists watch their repository's git directories (HEAD,
-- the index, the reflog, refs), and a change in them or in a project
-- directory in the repository makes a list check its signature (refs, HEAD,
-- uncommitted files), cheap to ask for; it reloads only if that changed.
-- gitfiles' git status rewrites the index after each save, say, which
-- changes nothing listed.

-- open lists, by view
local lists = setmetatable({}, { __mode = "k" })
local watch = nil ---@type core.dirwatch?
local watched = {} -- directory -> true

local function is_open(list)
  return require("core.panel").contains(list)
    or core.root_view.root_node:get_node_for_view(list) ~= nil
end

-- Watches the git directories of open lists, and no others.
local function sync_watches()
  local wanted = {}
  for list in pairs(lists) do
    if is_open(list) then
      for _, dir in ipairs(list.git_dirs or {}) do wanted[dir] = true end
    else
      lists[list] = nil
    end
  end
  for dir in pairs(watched) do
    if not wanted[dir] then watch:unwatch(dir) watched[dir] = nil end
  end
  for dir in pairs(wanted) do
    if not watched[dir] then watch:watch(dir) watched[dir] = true end
  end
end

local function mark_stale(list)
  list.stale = true
  core.wake("gitkit:refresh")
end

local function start_watching()
  if watch then return end
  local dirwatch = require "core.dirwatch"
  watch = dirwatch.new()
  -- woken by any dirmonitor's changes; takes those of the git directories
  core.add_thread(function()
    while true do
      watch:check(function(dir)
        for list in pairs(lists) do
          for _, d in ipairs(list.git_dirs or {}) do
            if d == dir then mark_stale(list) end
          end
        end
      end)
      watch:wait(1)
    end
  end)
  -- checks stale lists a moment after the last change, so a burst of changes
  -- (a commit writes several files) checks once
  core.add_thread(function()
    while true do
      local any = false
      for list in pairs(lists) do any = any or list.stale end
      if not any then core.wait_for("gitkit:refresh") end
      coroutine.yield(config.plugins.gitkit.refresh_delay)
      sync_watches()
      for list in pairs(lists) do
        if list.stale and not list.loading then
          list.stale = false
          core.try(function()
            if list:get_signature() ~= list.signature then list:refresh() end
          end)
        end
      end
    end
  end)
  -- a changed working tree file may be a new uncommitted change
  local on_project_directory_change = core.on_project_directory_change
  function core.on_project_directory_change(topdir, path)
    for list in pairs(lists) do
      if common.path_belongs_to(topdir.name, list.root) or topdir.name == list.root
         or common.path_belongs_to(list.root, topdir.name) then
        mark_stale(list)
      end
    end
    return on_project_directory_change(topdir, path)
  end
end

---What a reload would change, in short: refs, HEAD, and the files with
---uncommitted changes (of the file whose history is listed). In a core thread.
---@return string signature, string changed The uncommitted files
function CommitList:get_signature()
  local paths = self.path and { "--", self.path } or {}
  local refs = git.run(self.root, { "for-each-ref", "--format=%(objectname) %(refname) %(HEAD)" }) or ""
  local head = git.run(self.root, { "rev-parse", "HEAD" }) or ""
  local changed = git.run(self.root, { "diff", "HEAD", "--name-only", table.unpack(paths) }) or ""
  return refs .. "\0" .. head .. "\0" .. changed, changed
end

---Lists the commits of the repository at `root` (of `path` in it, if given),
---in the background. From the top, shown as they come; with `keep`, the
---commits listed stay until the new ones are all there, the selection staying
---on the same commit (refresh).
---@param root string
---@param path? string
---@param keep? boolean
function CommitList:load(root, path, keep)
  local new_root = root ~= self.root
  self.root, self.path = root, path
  if not keep then
    self.commits = {}
    self.selected_idx, self.hovered_idx = 0, 0
    self.scroll.y, self.scroll.to.y = 0, 0
  end
  local commits = keep and {} or self.commits
  self.error = nil
  self.loading = true
  self.generation = self.generation + 1
  local generation = self.generation
  local function current() return self.generation == generation end
  core.add_thread(function()
    if new_root or not self.git_dirs then
      local out = git.run(root, { "rev-parse", "--path-format=absolute",
                                  "--absolute-git-dir", "--git-common-dir" }) or ""
      local git_dir, common_dir = out:match("^([^\n]+)\n([^\n]+)")
      self.git_dirs = {}
      if git_dir then
        -- HEAD, index, packed-refs, FETCH_HEAD; HEAD's reflog (every move of
        -- HEAD); branch and tag tips (one level of them)
        local dirs = { git_dir, git_dir .. "/logs", common_dir, common_dir .. "/refs/heads",
                       common_dir .. "/refs/tags", common_dir .. "/refs/remotes" }
        for _, info in ipairs(system.list_dir(common_dir .. "/refs/remotes") or {}) do
          table.insert(dirs, common_dir .. "/refs/remotes/" .. info)
        end
        for _, d in ipairs(dirs) do
          if PATHSEP ~= "/" then d = d:gsub("/", PATHSEP) end
          local info = system.get_file_info(d)
          if info and info.type == "dir" then table.insert(self.git_dirs, d) end
        end
      end
      lists[self] = true
      start_watching()
      sync_watches()
    end
    local signature, changed = self:get_signature()
    if not current() then return end
    if changed ~= "" then
      table.insert(commits, { subject = "Uncommitted changes" })
    end
    -- each commit starts with \30; in a file's history, the file's name in
    -- it follows its fields (--name-only), as --follow tracks renames
    local args = { "log", "--format=%x1e%H%x1f%h%x1f%an%x1f%at%x1f%D%x1f%s%x1f",
                   "-n", tostring(config.plugins.gitkit.max_commits) }
    if path then
      for _, a in ipairs({ "--follow", "--name-only", "--", path }) do table.insert(args, a) end
    end
    local function add(rec)
      local hash, short, author, time, refs, subject, name =
        rec:match("^(%x+)\31([^\31]*)\31([^\31]*)\31(%d*)\31([^\31]*)\31([^\31]*)\31%s*(.-)%s*$")
      if hash then
        table.insert(commits, {
          hash = hash, short = short, author = author, time = tonumber(time),
          refs = refs ~= "" and refs or nil, subject = subject,
          path = path and (name:match("^[^\n]+") or path) or nil,
        })
      end
    end
    local buffer = ""
    local _, err = git.run(root, args, {
      cancelled = function() return not current() end,
      on_data = function(chunk)
        buffer = buffer .. chunk
        -- the commits before the last \30 are complete
        local pos = 1
        while true do
          local s = buffer:find("\30", pos, true)
          local e = s and buffer:find("\30", s + 1, true)
          if not e then
            pos = s or #buffer + 1
            break
          end
          add(buffer:sub(s + 1, e - 1))
          pos = e
        end
        buffer = buffer:sub(pos)
        if not keep then core.redraw = true end
      end,
    })
    if current() and buffer:sub(1, 1) == "\30" then add(buffer:sub(2)) end
    if not current() then return end
    self.loading = false
    self.signature = signature
    if keep then self:replace_commits(commits) end
    if err and #self.commits == 0 then self.error = err end
    core.redraw = true
  end)
end

-- Shows a refresh's commits: the selection on the same commit (none if it's
-- gone), which stays where it was in view unless the list was at the top.
-- Uncommitted changes shown are shown again, as they are now.
function CommitList:replace_commits(commits)
  local old_idx = self.selected_idx
  local key = commit_key(self.commits[old_idx])
  self.commits = commits
  self.hovered_idx = 0
  self.selected_idx = 0
  for i, c in ipairs(key and commits or {}) do
    if commit_key(c) == key then
      self.selected_idx = i
      if self.scroll.to.y > 0 then
        local dy = (i - old_idx) * self:get_line_height()
        self.scroll.y, self.scroll.to.y = self.scroll.y + dy, self.scroll.to.y + dy
      end
      break
    end
  end
  -- uncommitted changes, or another comparison with the working tree, may
  -- have changed
  local cv = self:get_commit_view()
  if cv and cv:shows_working_tree() then cv:reload() end
end

---Lists them again, keeping the selection.
function CommitList:refresh()
  self:load(self.root, self.path, true)
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
---`opts.refresh`: it's shown already, to be updated, without showing the view
---or moving in it.
---@param idx integer
---@param opts? { refresh?: boolean }
function CommitList:show_commit(idx, opts)
  local commit = self.commits[idx]
  if not commit then return end
  local refresh = opts and opts.refresh
  local cv = refresh and self:get_commit_view() or place_commit_view(self)
  if not cv then return end
  local spec = commit.hash and { rev = commit.hash, title = "Commit " .. revision.short(commit.hash) }
    or { from = "HEAD", title = "Uncommitted" }
  spec.key = commit_key(commit)
  cv:show_diff(self.root, spec, { keep_place = refresh, scroll_to = commit.path or self.path })
end

---Shows a comparison (see gitkit.commitview.show_diff) in the commit view,
---made if needed; in a file's history, scrolled to the file's patch.
---@param spec gitkit.diffspec
---@param scroll_to? string
function CommitList:show_comparison(spec, scroll_to)
  place_commit_view(self):show_diff(self.root, spec, { scroll_to = scroll_to or self.path })
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
  if not cv or cv.shown_key ~= commit_key(self.commits[idx]) then self:show_commit(idx) end
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
