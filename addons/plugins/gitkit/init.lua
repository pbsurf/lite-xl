-- mod-version:3

-- Git tools. So far, history:
-- * "Git: Log" lists the repository's commits (of the active file's
--   repository, else the project's) in a bottom panel tab, uncommitted
--   changes above them; "Git: File History" the active file's (following
--   renames), also from the treeview's context menu. Stepping through them
--   with the arrow keys shows each in a commit view, as `git show` would:
--   message, stat, patch with colored lines and the old and new line numbers.
-- * In the commit view, Enter or ctrl+click on a patch line opens the file as
--   it was at that commit (removed lines: before it), at that line, read-only;
--   uncommitted changes open the working file. On a stat line it goes to the
--   file's patch. alt+pageup/alt+pagedown step to the previous/next commit.
-- * Commit lists refresh by themselves after commits, checkouts and other
--   changes to branches, tags or uncommitted files, keeping their selection.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local panel = require "core.panel"
local DocView = require "core.docview"

config.plugins.gitkit = common.merge({
  -- the git command: a name looked up in PATH, or a path
  git = "git",
  -- commits listed at most
  max_commits = 20000,
  -- a commit's patch is cut off after this many bytes
  max_diff_bytes = 4 * 1024 * 1024,
  -- seconds after a change in the repository (a commit, a checkout, a saved
  -- file) before the commit lists check for changes, so that a burst of
  -- them checks once
  refresh_delay = 0.3,
}, config.plugins.gitkit)

local git = require "plugins.gitkit.git"
local CommitList = require "plugins.gitkit.commitlist"
local CommitView = require "plugins.gitkit.commitview"

local gitkit = {
  CommitList = CommitList,
  CommitView = CommitView,
}

---Shows the commits of the repository `path` (a file or directory) is in, or
---only those of the file `path` with `file_history`, in the panel's commit
---list (reused).
---@param path string
---@param file_history? boolean
function gitkit.show_log(path, file_history)
  core.add_thread(function()
    local root, err = git.get_root(path)
    if not root then
      core.error("Not in a git repository: %s (%s)", common.home_encode(path), err or "")
      return
    end
    local rel = file_history and git.relative_path(root, path) or nil
    local view = panel.current(CommitList)
    if view then
      view:load(root, rel)
    else
      view = CommitList(root, rel)
      panel.set_current(view)
    end
    panel.show(view)
  end)
end

-- the file the active view shows: a doc's, or one at a revision's (in its
-- working tree)
local function active_file()
  local view = core.active_view
  if not (view and view:extends(DocView)) then return end
  local rev = view.doc.gitkit_revision
  if rev then return git.absolute_path(rev.root, rev.path) end
  return view.doc.abs_filename
end

command.add(nil, {
  ["gitkit:log"] = function()
    local view = core.active_view
    if view:is(CommitView) and view.meta.root then
      return gitkit.show_log(view.meta.root)
    end
    if view:is(CommitList) then return gitkit.show_log(view.root) end
    gitkit.show_log(active_file() or core.project_dir)
  end,
})

command.add(function()
  local file = active_file()
  return file ~= nil, file
end, {
  ["gitkit:file-history"] = function(file) gitkit.show_log(file, true) end,
})

command.add(function()
  local view = core.active_view
  if view:is(CommitView) then view = view.list end
  return view and view:is(CommitList), view
end, {
  ["gitkit:refresh"] = function(list) list:refresh() end,
})

command.add(function()
  local view = core.active_view
  return view:is(CommitView) and view.list and view.list:get_result_count() > 0, view
end, {
  ["gitkit:previous-commit"] = function(cv) cv.list:step(-1) end,
  ["gitkit:next-commit"] = function(cv) cv.list:step(1) end,
})

command.add(function()
  local view = core.active_view
  if not view:is(CommitView) then return false end
  local line, col = view.doc:get_selection()
  local target = view:get_target(line, col)
  return target ~= nil, view, target
end, {
  ["gitkit:open-at-caret"] = function(view, target) view:open_target(target) end,
})

command.add(function(x, y)
  local view = core.active_view
  if not (x and y and view:is(CommitView)) or view.hovering_gutter then return false end
  local line, col = view:resolve_screen_position(x, y)
  local target = view:get_target(line, col)
  return target ~= nil, view, target
end, {
  ["gitkit:open-at-mouse"] = function(view, target) view:open_target(target) end,
})
command.hidden["gitkit:open-at-mouse"] = true

keymap.add {
  ["return"] = "gitkit:open-at-caret",
  ["ctrl+1lclick"] = "gitkit:open-at-mouse",
  ["alt+pageup"] = "gitkit:previous-commit",
  ["alt+pagedown"] = "gitkit:next-commit",
}


-- the treeview's item menus: a file's history, a folder's repository's log
local tv_found, TreeView = pcall(require, "plugins.treeview")
if tv_found then
  local ContextMenu = require "core.contextmenu"
  local function item() return TreeView.hovered_item or TreeView.selected_item end
  command.add(function()
    local it = core.active_view == TreeView and item()
    return it and it.abs_filename ~= nil, it
  end, {
    ["gitkit:treeview-history"] = function(it)
      gitkit.show_log(it.abs_filename, it.type == "file")
    end,
  })
  command.hidden["gitkit:treeview-history"] = true
  TreeView.contextmenu:register(function()
    return core.active_view == TreeView and TreeView.hovered_item
  end, function()
    local it = TreeView.hovered_item
    return {
      ContextMenu.DIVIDER,
      { text = it.type == "file" and "Git History" or "Git Log",
        command = "gitkit:treeview-history" },
    }
  end)
end


return gitkit
