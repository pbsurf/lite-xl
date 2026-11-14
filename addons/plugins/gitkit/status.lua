local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local StatusView = require "core.statusview"
local ContextMenu = require "core.contextmenu"
local git = require "plugins.gitkit.git"
local revision = require "plugins.gitkit.revision"
local blame = require "plugins.gitkit.blame"
local CommitView = require "plugins.gitkit.commitview"
local CommitList = require "plugins.gitkit.commitlist"

---The status bar's git item: a branch icon and the branch's name, for the
---repository of the file in the editor (kept while the focus is elsewhere:
---the command view, a panel tab), or of the treeview's selection while it's
---focused. Its tooltip has the branch's upstream, ahead/behind, counts of
---changes, the file's state and the last commit that changed it; a click opens
---a menu of the file's and the repository's history and changes.
---config.plugins.gitkit.status_colors colors the icon by the repository's
---state.
---
---What git says comes from gitfiles (which keeps it up to date as files and
---the repository change) for files in a project directory; for others, from
---a `git status` of gitkit's own, asked again when the file is saved or
---focused.
local status = {}

local STATE_NAMES = { M = "modified", A = "added", D = "deleted", R = "renamed",
                      C = "copied", T = "type changed" }

-- A file's "XY" from git status, in words
local function describe(xy)
  if xy:find("U") or xy == "AA" or xy == "DD" then return "conflict" end
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  local staged, unstaged = STATE_NAMES[x] or x, STATE_NAMES[y] or y
  if x == " " then return unstaged end
  if y == " " then return staged .. " (staged)" end
  return staged .. " (staged), " .. (y == "M" and "modified again" or unstaged)
end


-- Without gitfiles ------------------------------------------------------------

-- by directory: the repository's top, false if it's in none
local roots = {}
-- by repository top: { summary, states (by path relative to the top: "XY",
-- "??" or "!!"), loading }
local fallback = {}

-- `git status --porcelain -z --branch --ignored` parsed: as gitfiles' summary,
-- and each entry's XY by path (directories ending with /)
local function parse_status(out)
  local summary = { ahead = 0, behind = 0, staged = 0, unstaged = 0, untracked = 0 }
  local states = {}
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
      states[path] = xy
      if xy == "??" then
        summary.untracked = summary.untracked + 1
      elseif xy ~= "!!" then
        if xy:sub(1, 1) ~= " " then summary.staged = summary.staged + 1 end
        if xy:sub(2, 2) ~= " " then summary.unstaged = summary.unstaged + 1 end
      end
    end
  end
  return summary, states
end

local function query(root)
  local entry = fallback[root]
  if not entry or entry.loading then return end
  entry.loading = true
  core.add_thread(function()
    local out = git.run(root, { "--no-optional-locks", "status", "--porcelain", "-z",
                                "--branch", "--ignored", "--", "." })
    entry.loading = false
    if out then
      entry.summary, entry.states = parse_status(out)
      core.redraw = true
    end
  end)
end

-- The repository of `dir`, asked of git the first time (nil until it answers)
local function root_of(dir)
  local root = roots[dir]
  if root == nil then
    roots[dir] = false
    core.add_thread(function()
      local r = git.get_root(dir)
      roots[dir] = r or false
      if r and not fallback[r] then
        fallback[r] = {}
        query(r)
      end
      core.redraw = true
    end)
    return
  end
  return root or nil
end

-- A path's state from a fallback entry: its own, or that of a directory it's
-- in (git lists a folder of untracked or ignored files as one entry)
local function fallback_state(entry, root, path)
  local rel = git.relative_path(root, path)
  local p = rel
  while p ~= "" do
    local xy = entry.states[p] or entry.states[p .. "/"]
    if xy == "??" then return "untracked" end
    if xy == "!!" then return "ignored" end
    if xy then return p == rel and describe(xy) or nil end
    p = p:match("^(.*)/[^/]*$") or ""
  end
end


-- What the item shows ------------------------------------------------------------

-- the file (or folder) the item is about
local current_path = nil

local function update_path()
  local view = core.active_view
  if view:is(CommitView) then
    current_path = view.meta.root or current_path
  elseif view:is(CommitList) then
    current_path = view.path and git.absolute_path(view.root, view.path) or view.root
  elseif view:extends(DocView) then
    local r = view.doc.gitkit_revision
    if r then
      current_path = git.absolute_path(r.root, r.path)
    elseif view.doc.abs_filename then
      current_path = view.doc.abs_filename
    end
  elseif view == package.loaded["plugins.treeview"] then
    local item = view.selected_item
    current_path = item and item.abs_filename or current_path
  end
  current_path = current_path or core.project_dir
end

---@class gitkit.status.info
---@field path string
---@field root string The repository's top
---@field dir? string The project directory the counts are of (gitfiles), nil for the repository
---@field summary table See gitfiles' parse_status
---@field state? string The path's state, nil if unchanged

---What the item shows, nil while it's not known, or outside a repository.
---@return gitkit.status.info?
function status.get_info()
  update_path()
  local path = current_path
  if not path then return end
  local gitfiles = package.loaded["plugins.gitfiles"]
  local st = gitfiles and gitfiles.get_status and gitfiles.get_status(path)
  if st then
    return { path = path, root = st.root, dir = st.dir ~= st.root and st.dir or nil,
             summary = st.summary, state = st.state }
  end
  local info = system.get_file_info(path)
  local dir = info and info.type == "dir" and path or common.dirname(path)
  local root = dir and root_of(dir)
  local entry = root and fallback[root]
  if not (entry and entry.summary) then return end
  return { path = path, root = root, summary = entry.summary,
           state = fallback_state(entry, root, path) }
end

-- the fallback asked again when a file in its repository is saved, or focused
local function refresh_fallback(path)
  local gitfiles = package.loaded["plugins.gitfiles"]
  if not path or (gitfiles and gitfiles.get_status and gitfiles.get_status(path)) then return end
  local root = roots[common.dirname(path)]
  if root then query(root) end
end

local clean = Doc.clean
function Doc:clean(...)
  local res = clean(self, ...)
  if self.abs_filename then refresh_fallback(self.abs_filename) end
  return res
end

local set_active_view = core.set_active_view
function core.set_active_view(view, ...)
  local res = set_active_view(view, ...)
  local doc = view and view:extends(DocView) and view.doc
  if doc and doc.abs_filename then refresh_fallback(doc.abs_filename) end
  return res
end


-- The last commit that changed the file, for the tooltip: asked when it first
-- shows, again once what git says changed (a new summary)
local last_commit = { path = nil, summary = nil, text = nil }

local function get_last_commit(info)
  local lc = last_commit
  if lc.path ~= info.path or lc.summary ~= info.summary then
    lc.path, lc.summary, lc.text = info.path, info.summary, nil
    if info.state == "untracked" or info.state == "ignored" then return end
    local path, summary = info.path, info.summary
    core.add_thread(function()
      local out = git.run(info.root, { "log", "-1", "--format=%h%x00%an%x00%at%x00%s",
                                       "--", git.relative_path(info.root, path) })
      if lc.path ~= path or lc.summary ~= summary then return end
      local hash, author, time, subject = (out or ""):match("^([^\0]*)\0([^\0]*)\0([^\0]*)\0([^\n]*)")
      lc.text = hash and string.format("%s · %s · %s\n%s", hash, author,
        common.format_age(tonumber(time)), subject) or false
      core.redraw = true
    end)
  end
  return lc.text
end


-- The item ------------------------------------------------------------------

local function branch_text(sum)
  if sum.detached then return "(detached)" end
  return sum.branch or "?"
end

local function icon_color(sum)
  if not config.plugins.gitkit.status_colors then return style.text end
  if sum.staged + sum.unstaged > 0 then return style.warn end
  if sum.ahead > 0 or sum.behind > 0 then return style.accent end
  return style.dim
end

local function tooltip(info)
  local sum = info.summary
  local lines = {}
  table.insert(lines, sum.detached and "Detached HEAD"
    or (sum.branch or "?") .. (sum.upstream and " → " .. sum.upstream or " (no upstream)"))
  if sum.upstream_gone then
    table.insert(lines, "Upstream is gone")
  elseif sum.upstream then
    table.insert(lines, string.format("%d ahead, %d behind (as of last fetch)", sum.ahead, sum.behind))
  end
  table.insert(lines, string.format("In %s: %d staged, %d changed, %d untracked",
    info.dir and common.basename(info.dir) or "the repository",
    sum.staged, sum.unstaged, sum.untracked))
  local file = system.get_file_info(info.path)
  if file and file.type == "file" then
    table.insert(lines, "")
    table.insert(lines, common.basename(info.path) .. ": " .. (info.state or "unchanged"))
    if info.state ~= "untracked" and info.state ~= "ignored" then
      local text = get_last_commit(info)
      if text == nil then
        table.insert(lines, "Last commit: …")
      elseif text then
        table.insert(lines, "Last commit: " .. text)
      end
    end
  end
  return table.concat(lines, "\n")
end

-- The commit view (current, focused) showing `spec`
local function show_in_commit_view(root, spec, scroll_to)
  local cv = CommitView.place(nil)
  cv:show_diff(root, spec, { scroll_to = scroll_to })
  core.set_active_view(cv)
end

local function menu(gitkit, info)
  local items = {}
  local file = system.get_file_info(info.path)
  local tracked = info.state ~= "untracked" and info.state ~= "ignored"
  if file and file.type == "file" then
    local view = core.active_view
    if view:extends(DocView) and blame.can_blame(view.doc) then
      table.insert(items, { text = blame.is_shown(view.doc) and "Hide Git Blame" or "Git Blame",
        command = function() blame.toggle(view.doc) end })
    end
    if tracked then
      table.insert(items, { text = "File History", command = function()
        gitkit.show_log(info.path, true)
      end })
    end
    if info.state and tracked then
      table.insert(items, { text = "File's Uncommitted Changes", command = function()
        local rel = git.relative_path(info.root, info.path)
        show_in_commit_view(info.root, gitkit.working_tree_spec("HEAD", { rel }), rel)
      end })
    end
    if #items > 0 then table.insert(items, ContextMenu.DIVIDER) end
  end
  table.insert(items, { text = "Git Log", command = function() gitkit.show_log(info.root) end })
  local sum = info.summary
  if sum.staged + sum.unstaged > 0 then
    table.insert(items, { text = "Uncommitted Changes", command = function()
      show_in_commit_view(info.root, { from = "HEAD", title = "uncommitted" })
    end })
  end
  table.insert(items, ContextMenu.DIVIDER)
  if sum.branch and not sum.detached then
    table.insert(items, { text = "Copy Branch Name", command = function()
      system.set_clipboard(sum.branch)
    end })
  end
  table.insert(items, { text = "Copy HEAD Hash", command = function()
    core.add_thread(function()
      local out, err = git.run(info.root, { "rev-parse", "--short", "HEAD" })
      if out then system.set_clipboard((out:gsub("%s+$", ""))) else core.error("git: %s", err) end
    end)
  end })
  return items
end

---Adds the item to the status bar.
---@param gitkit table The gitkit module (show_log, working_tree_spec)
function status.setup(gitkit)
  local shown -- the info the item last showed, for its tooltip and menu
  core.status_view:add_item({
    name = "gitkit:status",
    alignment = StatusView.Item.RIGHT,
    position = 1,
    predicate = function()
      shown = status.get_info()
      return shown ~= nil
    end,
    get_item = function()
      local sum = shown.summary
      local t = {}
      local nerdicons = package.loaded["plugins.nerdicons"]
      local icon, font
      if nerdicons and nerdicons.icon then icon, font = nerdicons.icon("dev-git_branch") end
      if icon then
        table.insert(t, font)
        table.insert(t, icon_color(sum))
        table.insert(t, icon)
        table.insert(t, style.font)
        table.insert(t, style.text)
        table.insert(t, " " .. branch_text(sum))
      else
        table.insert(t, style.font)
        table.insert(t, icon_color(sum))
        table.insert(t, "git: ")
        table.insert(t, style.text)
        table.insert(t, branch_text(sum))
      end
      return t
    end,
    tooltip = function() return shown and tooltip(shown) or "" end,
    menu = function() return shown and menu(gitkit, shown) or {} end,
  })
end

return status
