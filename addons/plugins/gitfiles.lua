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

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local storage = require "core.storage"
local dirwatch = require "core.dirwatch"
local ContextMenu = require "core.contextmenu"
local TreeView = require "plugins.treeview"

config.plugins.gitfiles = common.merge({
  -- seconds to wait after a change before asking git again, so that a burst
  -- of changes runs it once
  delay = 0.3,
}, config.plugins.gitfiles)

local DEFAULT_UNTRACKED = { common.color "#2e9e44" }

-- per project directory name: false if it isn't in a git repository, else
-- { git_dir, prefix (of the directory in the repository, with a trailing /),
--   ignored, untracked (sets of paths relative to the directory) }
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
           "-z", "--ignored", "--", "." }
end

-- `git status --porcelain -z` output: entries "XY path", NUL-terminated, paths
-- relative to the repository's top; a rename's or copy's source path follows
-- it as a field of its own. A directory whose files are all untracked or all
-- ignored is one entry, with a trailing /.
local function parse_status(out, prefix)
  local ignored, untracked = {}, {}
  local skip = false
  for field in out:gmatch("([^\0]*)\0") do
    if skip then
      skip = false
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
        end
      end
    end
  end
  return ignored, untracked
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

local function get_repo(dir_name)
  local repo = repos[dir_name]
  if repo ~= nil then return repo end
  repo = false
  local out = read_command({ "git", "-C", dir_name, "rev-parse", "--show-prefix", "--absolute-git-dir" })
  local prefix, git_dir = (out or ""):match("^([^\n]*)\n([^\n]+)\n")
  if git_dir then
    local status = read_command(status_args(dir_name))
    if status then
      repo = { git_dir = git_dir, prefix = prefix }
      repo.ignored, repo.untracked = parse_status(status, prefix)
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


local function same_set(a, b)
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
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
      local out = run_command(status_args(dir_name))
      if out then
        local ignored, untracked = parse_status(out, repo.prefix)
        rescan = rescan or not same_set(ignored, repo.ignored)
        repo.ignored, repo.untracked = ignored, untracked
        core.redraw = true
      end
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
