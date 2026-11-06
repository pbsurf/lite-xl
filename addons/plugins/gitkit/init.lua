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
--   uncommitted changes, or a file that's the same now, open the working
--   copy. On a stat line it goes to the file's patch; on a submodule's
--   "Subproject commit" line it shows that commit of the submodule. alt+pageup/alt+pagedown
--   step to the previous/next commit.
-- * Commits and comparisons all show in one commit view, the current one
--   (italic title, as reused tabs have; core.reusable). Double-clicking its
--   tab keeps it: the next opens in a tab of its own, and comparisons asked
--   for in a kept one show in that new tab.
-- * Commit lists refresh by themselves after commits, checkouts and other
--   changes to branches, tags or uncommitted files, keeping their selection.
-- * Comparisons: a commit with the working tree (the whole of it, or a file),
--   or two commits, in the commit view; from the commit list's context menu
--   (a right-clicked commit, with the selected one for two), or the commit
--   view's (its commit, the file at the caret), and the command palette.
--   Both menus also copy the commit's short hash; the commit view's opens
--   the file at the caret, or its history.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local panel = require "core.panel"
local reusable = require "core.reusable"
local DocView = require "core.docview"
local ContextMenu = require "core.contextmenu"

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
  -- a file opened from a commit is the working copy (editable, with lsp and
  -- the rest) when it's the same as it was then, rather than a read-only copy
  open_working_copy = true,
}, config.plugins.gitkit)

local git = require "plugins.gitkit.git"
local CommitList = require "plugins.gitkit.commitlist"
local CommitView = require "plugins.gitkit.commitview"
local revision = require "plugins.gitkit.revision"
local diff = require "plugins.gitkit.diff"

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
    local view = reusable.current(CommitList)
    if view then
      view:load(root, rel)
    else
      view = CommitList(root, rel)
      reusable.set_current(view)
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


-- Comparisons ----------------------------------------------------------------

-- A file's names in two revisions, once if the same (paths to limit a
-- comparison to)
local function file_paths(a, b)
  if a and b and a ~= b then return { a, b } end
  return { a or b }
end

---A comparison of the commit `hash` with the working tree; of the files
---`paths` only, if given (the last one named in the title).
---@param hash string
---@param paths? string[]
---@return gitkit.diffspec
function gitkit.working_tree_spec(hash, paths)
  local title = revision.short(hash) .. diff.RENAME_ARROW .. "Working Tree"
  if paths then title = common.basename(paths[#paths]) .. ": " .. title end
  return { from = hash, paths = paths, title = title }
end

---A comparison of two commits of a commit list (rows `i` and `j`): the older
---one (further down) with the newer.
---@param list gitkit.commitlist
---@param i integer
---@param j integer
---@return gitkit.diffspec
function gitkit.commits_spec(list, i, j)
  local old, new = list.commits[math.max(i, j)], list.commits[math.min(i, j)]
  return { from = old.hash, to = new.hash,
           title = revision.short(old.hash) .. diff.RENAME_ARROW .. revision.short(new.hash) }
end

-- The commit a command acts on: the commit view's, if it shows one, else
-- the commit list's selected one (not uncommitted changes)
local function current_commit()
  local view = core.active_view
  if view:is(CommitView) then
    local spec = view.meta.spec
    if spec and spec.rev then return { hash = spec.rev, root = view.meta.root, view = view } end
  elseif view:is(CommitList) then
    local commit = view.commits[view.selected_idx]
    if commit and commit.hash then
      return { hash = commit.hash, root = view.root, list = view, commit = commit }
    end
  end
end

-- The file at the commit view's caret: its patch, or stat line
local function caret_file()
  local view = core.active_view
  if not view:is(CommitView) then return end
  local file = view:get_file_at((view.doc:get_selection()))
  if file then return file, view end
end

-- A comparison asked for in a commit view: shown in it if it's the current
-- one, else (kept) in the current one, focused
local function show_from_view(view, root, spec)
  if not view.reusable then
    view = CommitView.place(view.list)
    core.set_active_view(view)
  end
  view:show_diff(root, spec)
end

command.add(function()
  local c = current_commit()
  return c ~= nil, c
end, {
  ["gitkit:compare-with-working-tree"] = function(c)
    local spec = gitkit.working_tree_spec(c.hash)
    if c.view then return show_from_view(c.view, c.root, spec) end
    c.list:show_comparison(spec)
  end,
  ["gitkit:copy-short-hash"] = function(c)
    system.set_clipboard(revision.short(c.hash))
  end,
})

-- the file at the commit view's caret, in its commit; in a file's history,
-- the file in the selected commit
command.add(function()
  local c = current_commit()
  if not c then return false end
  if c.view then
    local file = caret_file()
    -- a file deleted by the commit isn't in it
    return file ~= nil and file.new_path ~= nil, c, file and { file.new_path }
  end
  return c.list.path ~= nil, c, file_paths(c.commit.path, c.list.path)
end, {
  ["gitkit:compare-file-with-working-tree"] = function(c, paths)
    local spec = gitkit.working_tree_spec(c.hash, paths)
    if c.view then return show_from_view(c.view, c.root, spec) end
    c.list:show_comparison(spec)
  end,
})

command.add(function()
  local c = current_commit()
  return c ~= nil and c.list ~= nil and c.list.path ~= nil, c
end, {
  ["gitkit:open-file-at-commit"] = function(c)
    revision.open(c.root, c.hash, c.commit.path or c.list.path)
  end,
})

command.add(function()
  local file, view = caret_file()
  return file ~= nil and view.meta.root ~= nil, file, view
end, {
  ["gitkit:file-history-at-caret"] = function(file, view)
    gitkit.show_log(git.absolute_path(view.meta.root, file.new_path or file.old_path), true)
  end,
})


-- Context menus ----------------------------------------------------------------

-- Items whose command is valid (a function is), without dividers at the
-- start or end or two in a row
local function valid_items(items)
  local t = {}
  for _, item in ipairs(items) do
    if item == ContextMenu.DIVIDER then
      if #t > 0 and t[#t] ~= ContextMenu.DIVIDER then table.insert(t, item) end
    elseif type(item.command) ~= "string" or command.is_valid(item.command) then
      table.insert(t, item)
    end
  end
  if t[#t] == ContextMenu.DIVIDER then table.remove(t) end
  return t
end

if config.plugins.contextmenu ~= false then
  local menu = require "plugins.contextmenu"

  -- A commit in the list, right-clicked: the menu acts on it, not the
  -- selected one (which stays, to compare with)
  menu:register(function()
    local view = core.active_view
    return view:is(CommitList) and view.hovered_idx > 0
  end, function()
    local list = core.active_view
    local idx, sel = list.hovered_idx, list.selected_idx
    local commit, selected = list.commits[idx], list.commits[sel]
    if not commit.hash then return end
    local items = {
      { text = "Compare with Working Tree", command = function()
        list:show_comparison(gitkit.working_tree_spec(commit.hash))
      end },
    }
    if list.path then
      table.insert(items, { text = "Compare File with Working Tree", command = function()
        list:show_comparison(gitkit.working_tree_spec(commit.hash, file_paths(commit.path, list.path)))
      end })
    end
    if selected and selected.hash and sel ~= idx then
      table.insert(items, { text = "Compare with " .. revision.short(selected.hash), command = function()
        list:show_comparison(gitkit.commits_spec(list, idx, sel))
      end })
    end
    if list.path then
      table.insert(items, ContextMenu.DIVIDER)
      table.insert(items, { text = "Open File at This Commit", command = function()
        revision.open(list.root, commit.hash, commit.path or list.path)
      end })
    end
    table.insert(items, ContextMenu.DIVIDER)
    table.insert(items, { text = "Copy Short Hash", command = function()
      system.set_clipboard(revision.short(commit.hash))
    end })
    return items
  end)

  -- In the commit view, after the core menu's Copy and Find: the file at the
  -- caret (where the right-click put it), then its commit
  menu:register("plugins.gitkit.commitview", function()
    local view = core.active_view
    local target = view:get_target((view.doc:get_selection()))
    local items = valid_items({
      { text = target and target.view_line and "Go to Patch" or "Open File",
        command = "gitkit:open-at-caret" },
      { text = "File History", command = "gitkit:file-history-at-caret" },
      ContextMenu.DIVIDER,
      { text = "Compare with Working Tree", command = "gitkit:compare-with-working-tree" },
      { text = "Compare File with Working Tree", command = "gitkit:compare-file-with-working-tree" },
      ContextMenu.DIVIDER,
      { text = "Copy Short Hash", command = "gitkit:copy-short-hash" },
    })
    if #items > 0 then table.insert(items, 1, ContextMenu.DIVIDER) end
    return items
  end)
end

-- the commit view can be searched (core's find takes only plain DocViews)
local function wrap_predicate(name, fn)
  local cmd = command.map[name]
  if not cmd then return end
  local predicate = cmd.predicate
  cmd.predicate = function(...) return fn(predicate, ...) end
end

wrap_predicate("find-replace:find", function(predicate, ...)
  if core.active_view:is(CommitView) then return true, core.active_view, ... end
  return predicate(...)
end)

-- the treeview's item menus: a file's history, a folder's repository's log
local tv_found, TreeView = pcall(require, "plugins.treeview")
if tv_found then
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
