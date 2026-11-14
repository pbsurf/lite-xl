-- mod-version:3

-- In a git repository, the project's files are the ones git doesn't ignore
-- (tracked, or untracked and not ignored), hidden files included, instead of
-- those config.ignore_files lets through. Untracked files are marked in the
-- treeview (style.git_untracked, green by default). "Show All Files" in the treeview's context menu shows everything
-- but .git (ignored files dimmed), in any project; it's kept per project.
--
-- git runs in the background, never blocking the editor: when a directory is
-- first listed (until it answers, the directory is listed by
-- config.ignore_files and not indexed yet; then listed again and indexed, its
-- submodules asked about right after), and again a moment after a change in
-- the project or its git directory (index, HEAD).
--
-- The treeview's and tabs' tooltips show an entry's or file's git state;
-- gitfiles.get_status gives it, with the repository's branch and counts of
-- changes, to other add-ons (gitkit's status bar item).
--
-- Folders at the top of a repository (submodules, other repositories nested in
-- the project, project directories) have a git badge on their icon
-- (style.git_badge, a muted git orange by default); a submodule's tooltip says
-- what it has checked out (branch, else commit) and its origin's URL.

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local storage = require "core.storage"
local dirwatch = require "core.dirwatch"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"
local TreeView = require "plugins.treeview"
local nerdfonts_symbols = require "libraries.font_symbols_nerdfont_mono_regular"

config.plugins.gitfiles = common.merge({
  -- the git command: a name looked up in PATH, or a path (on Windows e.g. "git.exe", or
  -- "C:\\Utils\\Tools\\wslgit.exe" to use git from WSL: paths in its arguments and output
  -- are translated)
  git = "git",
  -- seconds to wait after a change before asking git again, so that a burst
  -- of changes runs it once
  delay = 0.3,
}, config.plugins.gitfiles)

local gitfiles = {}

local DEFAULT_UNTRACKED = { common.color "#2e9e44" }
local DEFAULT_BADGE = { common.color "#b8735a" }

-- per project directory name: false if it isn't in a git repository, else
-- { git_dir, prefix (of the directory in the repository, with a trailing /),
--   ignored, untracked (sets of paths relative to the directory),
--   changes (status "XY" of other entries, by path), summary (see parse_status),
--   submodules (initialized ones in the directory, nested ones too, by path:
--   { branch (nil if detached), commit (short hash), url (origin's, if any) }) }
local repos = {}

-- by a folder's absolute path: whether it has a .git (a directory, or a
-- worktree's or submodule's file), so is a repository's top; cleared on any
-- change in the project
local has_git = {}

-- projects (core.project_dir) showing all files
local show_all = storage.load("gitfiles", "show_all")
if type(show_all) ~= "table" then show_all = {} end

local function showing_all()
  return show_all[core.project_dir] == true
end


local function status_args(dir_name)
  return { config.plugins.gitfiles.git, "-C", dir_name, "--no-optional-locks", "status", "--porcelain",
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

-- In a core thread: waits for the output without blocking the editor. Not
-- through a shell (io.popen), whose quoting and redirections differ between
-- systems.
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
-- NUL-terminated triples: path (relative to the directory); git directory,
-- branch ("HEAD" if detached) and short commit hash, on lines; origin's URL
-- (empty without one). The last command's status is printf's: a failing one
-- would stop foreach.
local function submodules_args(dir_name)
  return { config.plugins.gitfiles.git, "-C", dir_name, "submodule", "--quiet", "foreach", "--recursive",
           'printf "%s\\0%s\\0%s\\0" "$displaypath"'
           .. ' "$(git rev-parse --absolute-git-dir --abbrev-ref HEAD --short HEAD)"'
           .. ' "$(git config --get remote.origin.url)"' }
end

-- A path git printed, as this system's: on Windows with \ (git for Windows
-- prints C:/...), and /mnt/<drive>/... from a shell in WSL (wslgit only
-- translates git's own output) is <drive>:\...
local function native_path(path)
  if PLATFORM ~= "Windows" then return path end
  local drive, rest = path:match("^/mnt/(%a)/(.*)$")
  if drive then path = drive:upper() .. ":/" .. rest end
  return (path:gsub("/", "\\"))
end

-- Asks git about the directory (in a core thread): sets the repo's ignored,
-- untracked, summary and changes. git status doesn't look into submodules, so
-- each is asked too (unless `skip_submodules`: one run each, slow to wait for),
-- and what it says about its files is added to the sets (the summary stays the
-- directory's repository's). Returns whether the sets of ignored paths changed.
-- With `task` (core.add_task), its progress counts the submodules asked.
local function query(repo, dir_name, skip_submodules, task)
  local status = run_command(status_args(dir_name))
  if not status then return false end
  local ignored, untracked, summary, changes = parse_status(status, repo.prefix)
  local subs = not skip_submodules and run_command(submodules_args(dir_name)) or ""
  local submodules = {}
  local n_subs, done = select(2, subs:gsub("[^\0]*\0[^\0]*\0[^\0]*\0", "")), 0
  for path, head, url in subs:gmatch("([^\0]*)\0([^\0]*)\0([^\0]*)\0") do
    local git_dir, branch, commit = head:match("^([^\n]*)\n?([^\n]*)\n?([^\n]*)")
    git_dir = native_path(git_dir)
    if task then
      task:update(string.format("%d/%d submodules", done, n_subs))
      done = done + 1
    end
    if path:sub(1, 3) ~= "../" then
      local native = PATHSEP ~= "/" and path:gsub("/", PATHSEP) or path
      submodules[native] = { branch = branch ~= "" and branch ~= "HEAD" and branch or nil,
                             commit = commit ~= "" and commit or nil,
                             url = url ~= "" and url or nil }
      local sub_status = run_command(status_args(dir_name .. PATHSEP .. path))
      if sub_status then
        local base = native .. PATHSEP
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
  if not skip_submodules then repo.submodules = submodules end
  return changed
end

-- A change in a project directory of a repository, or in its git directory,
-- makes the status stale; the worker below waits for things to settle, then
-- updates, again if changes came meanwhile.
local stale = false

local function set_stale()
  stale = true
  core.wake("gitfiles")
end

-- project directory names git is being asked about (not in repos yet)
local pending = {}

-- Asks git whether the directory is in a repository, and about the repository
-- (not its submodules: those come with the next update), then lists and
-- indexes the directory again, now with what git ignores.
local function resolve(dir_name)
  local repo = false
  local task = core.add_task("Asking git about " .. common.basename(dir_name))
  core.try(function()
    local out = run_command({ config.plugins.gitfiles.git, "-C", dir_name, "rev-parse", "--show-prefix", "--absolute-git-dir" })
    local prefix, git_dir = (out or ""):match("^([^\n]*)\n([^\n]+)\n")
    if git_dir then
      local r = { git_dir = git_dir, prefix = prefix }
      query(r, dir_name, true)
      if r.ignored then
        repo = r
        -- the index and HEAD change with add, rm, commit, checkout...
        git_watch:watch(git_dir)
      end
    end
  end)
  task:done()
  repos[dir_name] = repo
  pending[dir_name] = nil
  local topdir = core.project_dir_by_name(dir_name)
  if topdir then core.rescan_project_directory(topdir) end
  if repo then set_stale() end
end

-- The directory's repository, false if it isn't in one, nil until git has
-- answered (asked in the background, the first time)
local function get_repo(dir_name)
  local repo = repos[dir_name]
  if repo == nil and not pending[dir_name] then
    pending[dir_name] = true
    core.add_thread(resolve, nil, dir_name)
  end
  return repo
end


-- A directory waiting for git isn't indexed (by config.ignore_files: most of a
-- build directory, say, then again without it): resolve() indexes it
local scan_project_directory = core.scan_project_directory
function core.scan_project_directory(topdir)
  if get_repo(topdir.name) == nil then return end
  return scan_project_directory(topdir)
end


-- Until git has answered: config.ignore_files, as outside a repository
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
      local task = core.add_task("Updating git status of " .. common.basename(dir_name))
      local ok, changed = core.try(query, repo, dir_name, false, task)
      task:done()
      rescan = (ok and changed) or rescan
      core.redraw = true
    end
  end
  if rescan then core.rescan_project_directories() end
end


local on_project_directory_change = core.on_project_directory_change
function core.on_project_directory_change(topdir, path)
  if repos[topdir.name] then set_stale() end
  -- a .git made or removed: badges drawn again
  has_git = {}
  core.redraw = true
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


-- the submodule an entry is, if it is one
local function submodule_of(item)
  local repo = item.type == "dir" and item.depth > 0 and repos[item.dir_name]
  return repo and repo.submodules and repo.submodules[item.filename]
end

-- whether an entry gets a git badge: a project directory at the top of its
-- repository, a submodule, or another folder at a repository's top (one
-- nested in the project's, or in a project that isn't in one)
local function has_badge(item)
  if item.depth == 0 then
    local repo = repos[item.dir_name]
    return repo and repo.prefix == ""
  end
  if item.type ~= "dir" then return false end
  if submodule_of(item) then return true end
  local path = item.abs_filename
  if has_git[path] == nil then
    has_git[path] = system.get_file_info(path .. PATHSEP .. ".git") ~= nil
  end
  return has_git[path]
end

-- The color of an entry's row, as TreeView:draw_item_background draws it
local function row_background(active, hovered)
  local hl = style.line_highlight
  if hovered then
    local bg, a = style.background2, 160 / 255 * (hl[4] or 255) / 255
    return { bg[1] + (hl[1] - bg[1]) * a, bg[2] + (hl[2] - bg[2]) * a,
             bg[3] + (hl[3] - bg[3]) * a, 255 }
  end
  return active and hl or style.background2
end

local BADGE_ICON = nerdfonts_symbols.utf8["dev-git"]
-- renderer.draw_glyph draws from the outline: the size doesn't matter
local badge_font = renderer.font.load(nerdfonts_symbols.path, 12)

-- A repository's folder icon (a submodule's, or the project's) gets a git badge
-- at its lower right corner, ringed with the row's color to set it apart from
-- the icon
local draw_item_icon = TreeView.draw_item_icon
function TreeView:draw_item_icon(item, active, hovered, x, y, w, h)
  local advance = draw_item_icon(self, item, active, hovered, x, y, w, h)
  if has_badge(item) then
    local icon, font = self:get_item_icon(item, active, hovered)
    local th = font:get_height()
    local d = th * 0.5
    local cx = x + font:get_width(icon) - d * 0.3
    local cy = common.round(y + (h - th) / 2) + th * 0.72
    local r = d / 2 + 1.5 * SCALE
    renderer.draw_path({ "M", cx, cy - r, "L", cx + r, cy, "L", cx, cy + r, "L", cx - r, cy, "Z" },
      row_background(active, hovered))
    renderer.draw_glyph(badge_font, BADGE_ICON, cx - d / 2, cy - d / 2, d, d,
      style.git_badge or DEFAULT_BADGE)
  end
  return advance
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
  local sub = submodule_of(item)
  if sub then
    local head = sub.branch and "on " .. sub.branch
      or sub.commit and "at " .. sub.commit .. " (detached)" or "with no commits"
    table.insert(info, "git submodule " .. head .. (state and ", " .. state or ""))
  elseif state then
    table.insert(info, "git: " .. state)
  end
  return info
end

-- a submodule's origin, on a line of its own (URLs are long)
local get_item_tooltip = TreeView.get_item_tooltip
function TreeView:get_item_tooltip(item)
  local lines = get_item_tooltip(self, item)
  local sub = submodule_of(item)
  if sub and sub.url then table.insert(lines, "origin: " .. common.home_encode(sub.url)) end
  return lines
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


---What git says about `path`, an absolute path in a project directory that's
---in a repository, once git has answered (nil otherwise; nil too for paths in
---no project directory): the project directory, the repository's top, the
---summary (see parse_status: branch, upstream, ahead, behind, and the counts
---of changed and untracked entries in the project directory), and the path's
---state ("modified", "untracked"..., see git_state; nil if unchanged).
---@param path string
---@return { dir: string, root: string, summary: table, state: string? }?
function gitfiles.get_status(path)
  local dir_name
  for _, dir in ipairs(core.project_directories) do
    if repos[dir.name] and (path == dir.name or common.path_belongs_to(path, dir.name))
      and (not dir_name or #dir.name > #dir_name) then
      dir_name = dir.name
    end
  end
  if not dir_name then return end
  local repo = repos[dir_name]
  local root = dir_name
  for _ in repo.prefix:gmatch("[^/]+") do root = common.dirname(root) end
  local rel = path == dir_name and "" or path:sub(#dir_name + 2)
  local info = system.get_file_info(path)
  return { dir = dir_name, root = root, summary = repo.summary,
           state = git_state(repo, rel, info and info.type == "dir") }
end


return gitfiles
