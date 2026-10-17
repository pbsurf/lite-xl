-- mod-version:3

-- In a git repository, the project's files are the ones git doesn't ignore
-- (tracked, or untracked and not ignored), hidden files included, instead of
-- those config.ignore_files lets through. Untracked files are marked in the
-- treeview (style.git_untracked, green by default). "Show All Files" in the treeview's context menu shows everything
-- but .git (ignored files dimmed), in any project; it's kept per project.
--
-- `git status` runs once when a directory is first scanned (blocking), then
-- again, in the background, a moment after a change in the project or its
-- git directory (index, HEAD).
--
-- While the treeview is focused, the status bar shows the selected entry's
-- repository: branch, commits ahead of/behind its upstream (as of the last
-- fetch), and how many files are changed or untracked in the project directory.
-- The treeview's and tabs' tooltips show an entry's or file's git state.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local storage = require "core.storage"
local dirwatch = require "core.dirwatch"
local ContextMenu = require "core.contextmenu"
local StatusView = require "core.statusview"
local RootView = require "core.rootview"
local TreeView = require "plugins.treeview"

config.plugins.gitfiles = common.merge({
  -- seconds to wait after a change before asking git again, so that a burst
  -- of changes runs it once
  delay = 0.3,
}, config.plugins.gitfiles)

local DEFAULT_UNTRACKED = { common.color "#2e9e44" }

-- per project directory name: false if it isn't in a git repository, else
-- { git_dir, prefix (of the directory in the repository, with a trailing /),
--   ignored, untracked (sets of paths relative to the directory),
--   changes (status "XY" of other entries, by path), summary (see parse_status) }
local repos = {}

-- projects (core.project_dir) showing all files
local show_all = storage.load("gitfiles", "show_all")
if type(show_all) ~= "table" then show_all = {} end

local function showing_all()
  return show_all[core.project_dir] == true
end


local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function status_args(dir_name)
  return { "git", "-C", dir_name, "--no-optional-locks", "status", "--porcelain",
           "-z", "--branch", "--ignored", "--", "." }
end

-- `git status --porcelain -z --branch` output: a "## branch...upstream [ahead
-- n, behind m]" header, then entries "XY path", NUL-terminated, paths relative
-- to the repository's top; a rename's or copy's source path follows it as a
-- field of its own. A directory whose files are all untracked or all ignored is
-- one entry, with a trailing /. Returns the sets of ignored and untracked
-- paths, a summary: { branch, upstream, ahead, behind, staged, unstaged,
-- untracked (counts of entries) }, and the other entries' "XY" by path.
local function parse_status(out, prefix)
  local ignored, untracked, changes = {}, {}, {}
  local summary = { ahead = 0, behind = 0, staged = 0, unstaged = 0, untracked = 0 }
  local skip = false
  for field in out:gmatch("([^\0]*)\0") do
    if skip then
      skip = false
    elseif field:sub(1, 3) == "## " then
      local head = field:sub(4)
      local branch = head:match("^No commits yet on (.+)$") or head:match("^Initial commit on (.+)$")
      if branch then
        summary.branch = branch
      elseif head:find("^HEAD %(no branch%)") then
        summary.detached = true
      else
        local tracking = head:match("%s%[(.*)%]$")
        head = head:gsub("%s%[.*%]$", "")
        summary.branch, summary.upstream = head:match("^(.-)%.%.%.(.+)$")
        summary.branch = summary.branch or head
        if tracking then
          summary.ahead = tonumber(tracking:match("ahead (%d+)")) or 0
          summary.behind = tonumber(tracking:match("behind (%d+)")) or 0
          summary.upstream_gone = tracking == "gone"
        end
      end
    else
      local xy, path = field:sub(1, 2), field:sub(4)
      skip = xy:find("[RC]") ~= nil
      path = path:gsub("/$", "")
      if path:sub(1, #prefix) == prefix and #path > #prefix then
        path = path:sub(#prefix + 1)
        if PATHSEP ~= "/" then path = path:gsub("/", PATHSEP) end
        if xy == "!!" then
          ignored[path] = true
        elseif xy == "??" then
          untracked[path] = true
          summary.untracked = summary.untracked + 1
        else
          changes[path] = xy
          if xy:sub(1, 1) ~= " " then summary.staged = summary.staged + 1 end
          if xy:sub(2, 2) ~= " " then summary.unstaged = summary.unstaged + 1 end
        end
      end
    end
  end
  return ignored, untracked, summary, changes
end

-- Blocking: the first scan of a directory needs the answer
local function read_command(args)
  local quoted = {}
  for i, arg in ipairs(args) do quoted[i] = shell_quote(arg) end
  local f = io.popen(table.concat(quoted, " ") .. " 2>/dev/null")
  if not f then return end
  local out = f:read("a")
  return f:close() and out or nil
end

-- In a core thread: waits for the output without blocking the editor
local function run_command(args)
  local ok, proc = pcall(process.start, args, { stderr = process.REDIRECT_DISCARD })
  if not ok then return end
  local out = {}
  while true do
    local s = proc:read_stdout(65536)
    if not s then break end
    if s == "" then
      local source = proc:watch_source(process.STREAM_STDOUT)
      if not source then break end
      core.wait_for(core.watch_readable(source))
    else
      table.insert(out, s)
    end
  end
  return proc:wait(1) == 0 and table.concat(out) or nil
end


local git_watch = dirwatch.new()

local function same_set(a, b)
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

-- The directory's submodules (initialized ones, nested ones too) in it, as
-- NUL-terminated pairs of path (relative to the directory) and git directory
local function submodules_args(dir_name)
  return { "git", "-C", dir_name, "submodule", "--quiet", "foreach", "--recursive",
           'printf "%s\\0%s\\0" "$displaypath" "$(git rev-parse --absolute-git-dir)"' }
end

-- Asks git about the directory with run (read_command or run_command): sets
-- the repo's ignored, untracked, summary and changes. git status doesn't look
-- into submodules, so each is asked too, and what it says about its files is
-- added to the sets (the summary stays the directory's repository's). Returns
-- whether the sets of ignored paths changed.
local function query(repo, dir_name, run)
  local status = run(status_args(dir_name))
  if not status then return false end
  local ignored, untracked, summary, changes = parse_status(status, repo.prefix)
  local subs = run(submodules_args(dir_name)) or ""
  for path, git_dir in subs:gmatch("([^\0]*)\0([^\0]*)\0") do
    if path:sub(1, 3) ~= "../" then
      local sub_status = run(status_args(dir_name .. PATHSEP .. path))
      if sub_status then
        local base = (PATHSEP ~= "/" and path:gsub("/", PATHSEP) or path) .. PATHSEP
        local sub_ignored, sub_untracked, _, sub_changes = parse_status(sub_status, "")
        for p in pairs(sub_ignored) do ignored[base .. p] = true end
        for p in pairs(sub_untracked) do untracked[base .. p] = true end
        for p, xy in pairs(sub_changes) do changes[base .. p] = xy end
      end
      git_watch:watch(git_dir)
    end
  end
  local changed = not repo.ignored or not same_set(ignored, repo.ignored)
  repo.ignored, repo.untracked, repo.summary, repo.changes = ignored, untracked, summary, changes
  return changed
end

local function get_repo(dir_name)
  local repo = repos[dir_name]
  if repo ~= nil then return repo end
  repo = false
  local out = read_command({ "git", "-C", dir_name, "rev-parse", "--show-prefix", "--absolute-git-dir" })
  local prefix, git_dir = (out or ""):match("^([^\n]*)\n([^\n]+)\n")
  if git_dir then
    local r = { git_dir = git_dir, prefix = prefix }
    query(r, dir_name, read_command)
    if r.ignored then
      repo = r
      -- the index and HEAD change with add, rm, commit, checkout...
      git_watch:watch(git_dir)
    end
  end
  repos[dir_name] = repo
  return repo
end


local project_file_filter = dirwatch.project_file_filter
function dirwatch.project_file_filter(dir, info, ignore_compiled)
  local repo = get_repo(dir.name)
  if not repo and not showing_all() then
    return project_file_filter(dir, info, ignore_compiled)
  end
  if common.basename(info.filename) == ".git" then return false end
  return showing_all() or not repo.ignored[info.filename]
end


local function is_project_dir(dir_name)
  for _, dir in ipairs(core.project_directories) do
    if dir.name == dir_name then return true end
  end
  return false
end

-- Asks git again about every repository; rescans the project if what's
-- ignored changed
local function update()
  local rescan = false
  for dir_name, repo in pairs(repos) do
    if repo and is_project_dir(dir_name) then
      rescan = query(repo, dir_name, run_command) or rescan
      core.redraw = true
    end
  end
  if rescan then core.rescan_project_directories() end
end


-- A change in a project directory of a repository, or in its git directory,
-- makes the status stale; the worker below waits for things to settle, then
-- updates, again if changes came meanwhile.
local stale = false

local function set_stale()
  stale = true
  core.wake("gitfiles")
end

local on_project_directory_change = core.on_project_directory_change
function core.on_project_directory_change(topdir, path)
  if repos[topdir.name] then set_stale() end
  return on_project_directory_change(topdir, path)
end

-- woken by any dirmonitor's changes; takes those of the git directories (or
-- their dirmonitor keeps posting them)
core.add_thread(function()
  while true do
    git_watch:check(set_stale)
    git_watch:wait(1)
  end
end)

core.add_thread(function()
  while true do
    if not stale then core.wait_for("gitfiles") end
    coroutine.yield(config.plugins.gitfiles.delay)
    stale = false
    core.try(update)
  end
end)


local function set_show_all(value)
  show_all[core.project_dir] = value or nil
  core.try(storage.save, "gitfiles", "show_all", show_all)
  core.rescan_project_directories()
end

command.add(nil, {
  ["gitfiles:toggle-show-all-files"] = function()
    set_show_all(not showing_all())
  end,
})


-- the path's own entry, or that of a directory it's in
local function in_set(set, path)
  while path and path ~= "" do
    if set[path] then return true end
    local parent = common.dirname(path)
    if parent == path then break end
    path = parent
  end
  return false
end

local get_item_text = TreeView.get_item_text
function TreeView:get_item_text(item, active, hovered)
  local text, font, color = get_item_text(self, item, active, hovered)
  local repo = repos[item.dir_name]
  if repo and item.depth > 0 and not (active or hovered) then
    if in_set(repo.untracked, item.filename) then
      color = style.git_untracked or DEFAULT_UNTRACKED
    elseif showing_all() and in_set(repo.ignored, item.filename) then
      color = style.dim
    end
  end
  return text, font, color
end


local STATE_NAMES = { M = "modified", A = "added", D = "deleted", R = "renamed",
                      C = "copied", T = "type changed" }

-- A path's git state, for tooltips: "modified", "added (staged)", "untracked",
-- "ignored", "conflict"...; for a folder ("" for the directory itself), how many
-- entries in it are changed or untracked. nil if there's nothing to say.
local function git_state(repo, path, is_dir)
  if in_set(repo.untracked, path) then return "untracked" end
  if in_set(repo.ignored, path) then return "ignored" end
  if is_dir then
    local prefix = path ~= "" and path .. PATHSEP or ""
    local function count(set)
      local n = 0
      for p in pairs(set) do
        if p:sub(1, #prefix) == prefix then n = n + 1 end
      end
      return n
    end
    local changed, untracked = count(repo.changes), count(repo.untracked)
    local t = {}
    if changed > 0 then table.insert(t, changed .. " changed") end
    if untracked > 0 then table.insert(t, untracked .. " untracked") end
    return #t > 0 and table.concat(t, ", ") or nil
  end
  local xy = repo.changes[path]
  if not xy then return end
  if xy:find("U") or xy == "AA" or xy == "DD" then return "conflict" end
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  local staged, unstaged = STATE_NAMES[x] or x, STATE_NAMES[y] or y
  if x == " " then return unstaged end
  if y == " " then return staged .. " (staged)" end
  -- staged, then changed again
  return staged .. " (staged), " .. (y == "M" and "modified again" or unstaged)
end

local get_item_info = TreeView.get_item_info
function TreeView:get_item_info(item)
  local info = get_item_info(self, item)
  local repo = repos[item.dir_name]
  local state = repo and git_state(repo, item.depth > 0 and item.filename or "", item.type == "dir")
  if state then table.insert(info, "git: " .. state) end
  return info
end

local get_tab_tooltip_info = RootView.get_tab_tooltip_info
function RootView:get_tab_tooltip_info(view)
  local info = get_tab_tooltip_info(self, view)
  local abs = view.doc and view.doc.abs_filename
  for _, dir in ipairs(abs and core.project_directories or {}) do
    local repo = repos[dir.name]
    if repo and common.path_belongs_to(abs, dir.name) then
      local state = git_state(repo, abs:sub(#dir.name + 2))
      if state then table.insert(info, "git: " .. state) end
      break
    end
  end
  return info
end


local function menu_items()
  return { { text = showing_all() and "Hide Ignored Files" or "Show All Files",
             command = "gitfiles:toggle-show-all-files" } }
end

-- for the treeview itself (not over an item), and at the end of item menus
TreeView.contextmenu:register(function()
  return core.active_view == TreeView and not TreeView.hovered_item
end, menu_items)

TreeView.contextmenu:register(function()
  return core.active_view == TreeView and TreeView.hovered_item
end, function()
  local items = menu_items()
  table.insert(items, 1, ContextMenu.DIVIDER)
  return items
end)


-- the repository of the treeview's selected entry, else of the first project
-- directory in one
local function treeview_repo()
  local item = TreeView.selected_item
  if item then return repos[item.dir_name] or nil end
  for _, dir in ipairs(core.project_directories) do
    if repos[dir.name] then return repos[dir.name] end
  end
end

core.status_view:add_item({
  predicate = function()
    return core.active_view == TreeView and treeview_repo() ~= nil
  end,
  name = "gitfiles:status",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local sum = treeview_repo().summary
    local t = { style.text, sum.detached and "(detached)" or sum.branch or "?" }
    if sum.ahead > 0 or sum.behind > 0 then
      local s = ""
      if sum.ahead > 0 then s = s .. " ↑" .. sum.ahead end
      if sum.behind > 0 then s = s .. " ↓" .. sum.behind end
      table.insert(t, style.accent)
      table.insert(t, s)
    end
    if sum.staged + sum.unstaged > 0 then
      table.insert(t, style.dim)
      table.insert(t, "  ·  ")
      table.insert(t, style.warn)
      table.insert(t, sum.staged > 0 and sum.unstaged > 0
        and string.format("%d staged, %d changed", sum.staged, sum.unstaged)
        or sum.staged > 0 and sum.staged .. " staged" or sum.unstaged .. " changed")
    end
    if sum.untracked > 0 then
      table.insert(t, style.dim)
      table.insert(t, "  ·  ")
      table.insert(t, style.git_untracked or DEFAULT_UNTRACKED)
      table.insert(t, sum.untracked .. " untracked")
    end
    return t
  end,
  tooltip = function()
    local sum = treeview_repo().summary
    local lines = { sum.detached and "Detached HEAD" or (sum.branch or "?")
      .. (sum.upstream and " → " .. sum.upstream or " (no upstream)") }
    if sum.upstream_gone then
      table.insert(lines, "Upstream is gone")
    elseif sum.upstream then
      table.insert(lines, string.format("%d ahead, %d behind (as of last fetch)",
        sum.ahead, sum.behind))
    end
    table.insert(lines, string.format("In this folder: %d staged, %d changed, %d untracked",
      sum.staged, sum.unstaged, sum.untracked))
    return table.concat(lines, "\n")
  end,
})
