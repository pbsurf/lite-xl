require "core.strict"
require "core.regex"
local common = require "core.common"
local config = require "core.config"
local style = require "colors.default"
local command
local keymap
local dirwatch
local ime
local RootView
local StatusView
local TitleView
local CommandView
local NagView
local DocView
local Doc

local core = {}

local function load_session()
  local ok, t = pcall(dofile, USERDIR .. PATHSEP .. "session.lua")
  return ok and t or {}
end


local function save_session()
  local fp = io.open(USERDIR .. PATHSEP .. "session.lua", "w")
  if fp then
    fp:write("return {recents=", common.serialize(core.recent_projects),
      ", recent_files=", common.serialize(core.recent_files),
      ", window=", common.serialize(table.pack(system.get_window_size())),
      ", window_mode=", common.serialize(system.get_window_mode()),
      ", previous_find=", common.serialize(core.previous_find),
      ", previous_replace=", common.serialize(core.previous_replace),
      "}\n")
    fp:close()
  end
end


-- Files made active, absolute paths, newest first, kept between sessions (unlike
-- core.visited_files, which is for the project's files and kept per session).
-- A transient view's file (a preview) isn't added; a plugin adds it when the view
-- stops being transient.
local MAX_RECENT_FILES = 50

function core.add_recent_file(abs_filename)
  local recents = core.recent_files
  for i = 1, #recents do
    if common.path_equal(recents[i], abs_filename) then
      table.remove(recents, i)
      break
    end
  end
  table.insert(recents, 1, abs_filename)
  recents[MAX_RECENT_FILES + 1] = nil
end


-- Closing a file's last tab moves it to the top of core.recent_files, so the
-- first entry that isn't open is the file closed last: core.reopen_file reopens
-- it where its tab was, at the cursor and scroll it had (this session only).

-- A tab's identity, which its view keeps and a reopened view takes over: a
-- reopened tab goes beside its neighbor's tab, also when that was reopened too.
-- Closed views aren't kept (a token is a small table), so their docs aren't.
local tab_views = setmetatable({}, { __mode = "v" })
local function tab_token(view)
  if not view then return end
  if not view.tab_token then
    view.tab_token = {}
    tab_views[view.tab_token] = view
  end
  return view.tab_token
end

-- Of each doc, where its last view removed from the tree was; a removal that
-- leaves the doc open (moving a tab) is overwritten by the next one
local removed_views = setmetatable({}, { __mode = "k" })
local removal_count = 0
-- Of each closed file (by absolute path), where its tab was
local closed_tabs = {}

---Called by a node before it removes the view at idx.
---@param node core.node
---@param view core.view
---@param idx integer
function core.on_view_removed(node, view, idx)
  if not (view.doc and view.doc.abs_filename) then return end
  removal_count = removal_count + 1
  removed_views[view.doc] = {
    seq = removal_count, transient = view:is_transient(), token = tab_token(view),
    left = tab_token(node.views[idx - 1]), right = tab_token(node.views[idx + 1]),
    -- weak: a reopen falls back when the node is gone
    node = setmetatable({ node }, { __mode = "v" }),
    scroll_x = view.scroll.to.x, scroll_y = view.scroll.to.y,
  }
end

---Called with the docs closed at once (by Close All, ...).
---@param docs core.doc[]
local function on_docs_closed(docs)
  local tabs = {}
  for _, doc in ipairs(docs) do
    local tab = removed_views[doc]
    -- a preview's file isn't recent (a plugin adds it when it becomes normal)
    if tab and not tab.transient and doc.abs_filename then
      tab.line, tab.col = doc:get_selection()
      tab.abs_filename = doc.abs_filename
      table.insert(tabs, tab)
    end
  end
  -- the tab removed last ends on top, as when closed one by one: reopening them
  -- one by one puts each beside a neighbor's new tab
  table.sort(tabs, function(a, b) return a.seq < b.seq end)
  for _, tab in ipairs(tabs) do
    closed_tabs[tab.abs_filename] = tab
    core.add_recent_file(tab.abs_filename)
  end
end

-- Closes the docs no view in the tree has (done once per frame, and on changing
-- the project).
local function close_unreferenced_docs()
  local closed = {}
  for i = #core.docs, 1, -1 do
    local doc = core.docs[i]
    if #core.get_views_referencing_doc(doc) == 0 then
      table.remove(core.docs, i)
      table.insert(closed, doc)
      doc:on_close()
    end
  end
  if #closed > 0 then on_docs_closed(closed) end
end

local function in_tree(node, root)
  return root == node or root.type ~= "leaf" and (in_tree(node, root.a) or in_tree(node, root.b))
end

---Opens a file in a new tab where its tab was when it was closed this session,
---at the cursor and scroll it had then: beside the tab that was next to it, or
---in the same split; otherwise as a new tab in the active split.
---@param abs_filename string
---@return core.docview
function core.reopen_file(abs_filename)
  local tab = closed_tabs[abs_filename]
  closed_tabs[abs_filename] = nil
  local root = core.root_view.root_node
  local node, idx
  if tab then
    local left, right = tab_views[tab.left], tab_views[tab.right]
    node = left and root:get_node_for_view(left)
    if node then
      idx = node:get_view_idx(left) + 1
    else
      node = right and root:get_node_for_view(right)
      if node then
        idx = node:get_view_idx(right)
      else
        node = tab.node[1]
        if node and not (node.type == "leaf" and in_tree(node, root)) then node = nil end
      end
    end
  end
  if not node or node.locked then node, idx = core.root_view:get_active_node_default(), nil end
  local view = DocView(core.open_doc(abs_filename))
  if tab then
    view.tab_token = tab.token
    tab_views[tab.token] = view
  end
  node:add_view(view, idx)
  if tab then
    view.doc:set_selection(tab.line, tab.col)
    view.scroll.x, view.scroll.to.x = tab.scroll_x, tab.scroll_x
    view.scroll.y, view.scroll.to.y = tab.scroll_y, tab.scroll_y
  end
  return view
end

---The files of core.recent_files that exist and aren't open, newest first.
---@return string[]
function core.get_closed_recent_files()
  local open = {}
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view.doc and view.doc.abs_filename then open[common.path_key(view.doc.abs_filename)] = true end
  end
  local files = {}
  for _, path in ipairs(core.recent_files) do
    if not open[common.path_key(path)] and system.get_file_info(path) then table.insert(files, path) end
  end
  return files
end


local function update_recents_project(action, dir_path_abs)
  local dirname = common.normalize_volume(dir_path_abs)
  if not dirname then return end
  local recents = core.recent_projects
  local n = #recents
  for i = 1, n do
    if common.path_equal(dirname, recents[i]) then
      table.remove(recents, i)
      break
    end
  end
  if action == "add" then
    table.insert(recents, 1, dirname)
  end
end


function core.set_project_dir(new_dir, change_project_fn)
  local chdir_ok = pcall(system.chdir, new_dir)
  local list_dir_ok = system.list_dir(new_dir)
  if chdir_ok and list_dir_ok then
    if change_project_fn then change_project_fn() end
    core.project_dir = common.normalize_volume(new_dir)
    core.project_directories = {}
  end
  return chdir_ok and list_dir_ok ~= nil
end


local function reload_customizations()
  local user_error = not core.load_user_directory()
  local project_error = not core.load_project_module()
  if user_error or project_error then
    -- Use core.add_thread to delay opening the LogView, as opening
    -- it directly here disturbs the normal save operations.
    core.add_thread(function()
      command.perform("core:open-log")
    end)
  end
end


function core.open_folder_project(dir_path_abs)
  if core.set_project_dir(dir_path_abs, core.on_quit_project) then
    core.root_view:close_all_docviews()
    -- now, not next frame: opening a file again (as the new project's workspace
    -- may) would get its old doc, with a filename relative to the old project
    close_unreferenced_docs()
    reload_customizations()
    update_recents_project("add", dir_path_abs)
    core.add_project_directory(dir_path_abs)
    core.on_enter_project(dir_path_abs)
  end
end


local function strip_leading_path(filename)
    return filename:sub(2)
end

local function strip_trailing_slash(filename)
  if filename:match("[^:]["..PATHSEP.."]$") then
    return filename:sub(1, -2)
  end
  return filename
end


function core.project_subdir_is_shown(dir, filename)
  return not dir.files_limit or dir.shown_subdir[filename]
end


-- bisects the sorted file list to get to things in ln(n)
local function file_bisect(files, is_superior, start_idx, end_idx)
  local inf, sup = start_idx or 1, end_idx or #files
  while sup - inf > 8 do
    local curr = math.floor((inf + sup) / 2)
    if is_superior(files[curr]) then
      sup = curr - 1
    else
      inf = curr
    end
  end
  while inf <= sup and not is_superior(files[inf]) do
    inf = inf + 1
  end
  return inf
end


local function file_search(files, info)
  local idx = file_bisect(files, function(file)
    return system.path_compare(info.filename, info.type, file.filename, file.type)
  end)
  if idx > 1 and files[idx-1].filename == info.filename then
    return idx - 1, true
  end
  return idx, false
end


local function files_info_equal(a, b)
  return (a == nil and b == nil) or (a and b and a.filename == b.filename and a.type == b.type)
end


local function project_subdir_bounds(dir, filename, start_index)
  local found = true
  if not start_index then
    start_index, found = file_search(dir.files, { type = "dir", filename = filename })
  end
  if found then
    local end_index = file_bisect(dir.files, function(file)
      return not common.path_belongs_to(file.filename, filename)
    end, start_index + 1)
    return start_index, end_index - start_index, dir.files[start_index]
  end
end


-- Should be called on any directory that registers a change, or on a directory we open if we're over the file limit.
-- Uses relative paths at the project root (i.e. target = "", target = "first-level-directory", target = "first-level-directory/second-level-directory")
local function refresh_directory(topdir, target)
  local directory_start_idx, directory_end_idx = 1, #topdir.files
  if target and target ~= "" then
    directory_start_idx, directory_end_idx = project_subdir_bounds(topdir, target)
    directory_end_idx = directory_start_idx + directory_end_idx - 1
    directory_start_idx = directory_start_idx + 1
  end

  local files = dirwatch.get_directory_files(topdir, topdir.name, (target or ""), 0, function() return false end)
  local change = false

  -- If this file doesn't exist, we should be calling this on our parent directory, assume we'll do that.
  -- Unwatch just in case.
  if files == nil then
    topdir.watch:unwatch(topdir.name .. PATHSEP .. (target or ""))
    return true
  end

  local new_idx, old_idx = 1, directory_start_idx
  local new_directories = {}
  -- Run through each sorted list and compare them. If we find a new entry, insert it and flag as new. If we're missing an entry
  -- remove it and delete the entry from the list.
  while old_idx <= directory_end_idx or new_idx <= #files do
    local old_info, new_info = topdir.files[old_idx], files[new_idx]
    if not files_info_equal(new_info, old_info) then
      change = true
      -- If we're a new file, and we exist *before* the other file in the list, then add to the list.
      if not old_info or (new_info and system.path_compare(new_info.filename, new_info.type, old_info.filename, old_info.type)) then
        table.insert(topdir.files, old_idx, new_info)
        old_idx, new_idx = old_idx + 1, new_idx + 1
        if new_info.type == "dir" then
          table.insert(new_directories, new_info)
        end
        directory_end_idx = directory_end_idx + 1
      else
      -- If it's not there, remove the entry from the list as being out of order.
        table.remove(topdir.files, old_idx)
        if old_info.type == "dir" then
          topdir.watch:unwatch(topdir.name .. PATHSEP .. old_info.filename)
        end
        directory_end_idx = directory_end_idx - 1
      end
    else
      -- If this file is a directory, determine in ln(n) the size of the directory, and skip every file in it.
      local size = old_info and old_info.type == "dir" and select(2, project_subdir_bounds(topdir, old_info.filename, old_idx)) or 1
      old_idx, new_idx = old_idx + size, new_idx + 1
    end
  end
  for i, v in ipairs(new_directories) do
    topdir.watch:watch(topdir.name .. PATHSEP .. v.filename)
    if not topdir.files_limit or core.project_subdir_is_shown(topdir, v.filename) then
      refresh_directory(topdir, v.filename)
    end
  end
  if change then
    core.redraw = true
    topdir.is_dirty = true
    -- for those that cache what they computed from topdir.files
    topdir.files_change_id = (topdir.files_change_id or 0) + 1
  end
  return change
end


local function no_recursion() return false end


-- Lists the top level of project directory `topdir` and the subdirectories
-- shown (expanded in the treeview): what topdir.files holds in files_limit mode.
local function list_shown_subdirs(topdir)
  topdir.files = dirwatch.get_directory_files(topdir, topdir.name, "", 0, no_recursion) or {}
  -- parents first, so that a subdirectory is listed when it's refreshed
  local subdirs = {}
  for subdir, shown in pairs(topdir.shown_subdir) do
    if shown then table.insert(subdirs, subdir) end
  end
  table.sort(subdirs, function(a, b) return system.path_compare(a, "dir", b, "dir") end)
  for _, subdir in ipairs(subdirs) do
    local _, found = file_search(topdir.files, { filename = subdir, type = "dir" })
    if found then refresh_directory(topdir, subdir) end
  end
  if topdir.name == core.project_dir then core.project_files = topdir.files end
  topdir.is_dirty = true
  topdir.files_change_id = (topdir.files_change_id or 0) + 1
  core.redraw = true
end


local function is_project_directory(topdir)
  for _, dir in ipairs(core.project_directories) do
    if dir == topdir then return true end
  end
  return false
end


---Indexes project directory `topdir` (an entry of core.project_directories)
---in a background thread: lists all its files, watching each directory, and
---sets topdir.files to the list once complete. Meanwhile, topdir.scan holds
---the progress (`files`, a growing prefix of the final list, and `n_files`),
---and topdir.files stays as it was (in files_limit mode, only the top level
---and the folders shown are listed, expanded on demand). The scan stops,
---leaving topdir in files_limit mode with topdir.over_limit set, after
---config.max_project_files entries, unless core:index-project lifted the limit
---for the directory. A scan already running is replaced.
---@param topdir table
function core.scan_project_directory(topdir)
  local index_all = require("core.storage").load("project_index", topdir.name)
  local limit = not index_all and config.max_project_files
  -- changed: absolute paths of the directories changed during the scan
  local scan = { files = {}, n_files = 0, changed = {} }
  topdir.scan = scan
  local t0, task
  -- false once the scan is stopped: "limit" or "cancelled" in scan.stopped
  local function scan_dir(path)
    topdir.watch:watch(path == "" and topdir.name or topdir.name .. PATHSEP .. path)
    local entries = dirwatch.get_directory_files(topdir, topdir.name, path, 0, no_recursion) or {}
    for _, info in ipairs(entries) do
      if limit and #scan.files >= limit then
        scan.stopped = "limit"
        return false
      end
      table.insert(scan.files, info)
      if info.type == "file" then scan.n_files = scan.n_files + 1 end
      if system.get_time() - t0 > 0.5 / config.fps then
        core.redraw = true
        task:update(common.format_count(scan.n_files) .. (scan.n_files == 1 and " file" or " files"))
        coroutine.yield(0)
        if topdir.scan ~= scan or not is_project_directory(topdir) then
          scan.stopped = "cancelled"
          return false
        end
        t0 = system.get_time()
      end
      if info.type == "dir" and not scan_dir(info.filename) then return false end
    end
    return true
  end

  local function run()
    t0 = system.get_time()
    scan_dir("")
    if scan.stopped == "cancelled" then return end
    topdir.scan = nil
    if scan.stopped == "limit" then
      if not topdir.files_limit then
        topdir.files_limit = true
        list_shown_subdirs(topdir)
      end
      -- in files_limit mode only the folders shown are watched
      for path in pairs(common.merge(topdir.watch.watched, topdir.watch.scanned)) do
        if path ~= topdir.name and not topdir.shown_subdir[path:sub(#topdir.name + 2)] then
          topdir.watch:unwatch(path)
        end
      end
      if not topdir.over_limit then
        core.warn("%s has over %d files: only opened folders are indexed. "
          .. "Run \"Core: Index Project\" to index it all.",
          common.home_encode(topdir.name), config.max_project_files)
      end
      topdir.over_limit = true
    else
      topdir.files = scan.files
      topdir.files_limit = false
      topdir.over_limit = nil
      if topdir.name == core.project_dir then core.project_files = topdir.files end
      -- what changed in the directories already listed
      local changed = {}
      for path in pairs(scan.changed) do table.insert(changed, path) end
      table.sort(changed, function(a, b) return system.path_compare(a, "dir", b, "dir") end)
      for _, path in ipairs(changed) do
        if path == topdir.name then
          refresh_directory(topdir)
        else
          local subdir = path:sub(#topdir.name + 2)
          local _, found = file_search(topdir.files, { filename = subdir, type = "dir" })
          if found then refresh_directory(topdir, subdir) end
        end
      end
    end
    topdir.is_dirty = true
    topdir.files_change_id = (topdir.files_change_id or 0) + 1
    core.redraw = true
  end

  core.add_thread(function()
    task = core.add_task("Indexing " .. common.basename(topdir.name))
    core.try(run)
    task:done()
  end)
end


---Called when the watch of project directory `topdir` (an entry of
---core.project_directories) reports a change in `path`, the absolute path of
---a directory being watched (topdir.name or one in it), before refreshing its
---file list: for plugins to override.
---@param topdir table
---@param path string
function core.on_project_directory_change(topdir, path) end


function core.add_project_directory(path)
  -- top directories has a file-like "item" but the item.filename
  -- will be simply the name of the directory, without its path.
  -- The field item.topdir will identify it as a top level directory.
  path = common.normalize_volume(path)
  local topdir = {
    name = path,
    item = {filename = common.basename(path), type = "dir", topdir = true},
    files_limit = false,
    is_dirty = true,
    shown_subdir = {},
    watch_thread = nil,
    watch = dirwatch.new()
  }
  table.insert(core.project_directories, topdir)

  local fstype = PLATFORM == "Linux" and system.get_fs_type(topdir.name) or "unknown"
  topdir.force_scans = (fstype == "nfs" or fstype == "fuse")
  -- the top level now, the rest once indexed in the background
  topdir.files_limit = true
  list_shown_subdirs(topdir)
  topdir.watch:watch(topdir.name)
  core.scan_project_directory(topdir)
  -- each top level directory gets a watch thread. if the project is small, or
  -- if the ablity to use directory watches hasn't been compromised in some way
  -- either through error, or amount of files, then this should be incredibly
  -- quick; essentially one syscall per check. Otherwise, this may take a bit of
  -- time; the watch will yield in this coroutine after 0.01 second, for 0.1 seconds.
  topdir.watch_thread = core.add_thread(function()
    while true do
      local changed = topdir.watch:check(function(target)
        core.on_project_directory_change(topdir, target)
        if topdir.scan then topdir.scan.changed[target] = true end
        if target == topdir.name then return refresh_directory(topdir) end
        local dirpath = target:sub(#topdir.name + 2)
        local abs_dirpath = topdir.name .. PATHSEP .. dirpath
        if dirpath then
          -- check if the directory is in the project files list, if not exit.
          local dir_index, dir_match = file_search(topdir.files, {filename = dirpath, type = "dir"})
          if not dir_match or not core.project_subdir_is_shown(topdir, topdir.files[dir_index].filename) then return end
        end
        return refresh_directory(topdir, dirpath)
      end, 0.01, 0.01)
      -- properly exit coroutine if project not open anymore to clear dir watch
      local project_dir_open = false
      for _, prj in ipairs(core.project_directories) do
        if topdir == prj then
          project_dir_open = true
          break
        end
      end
      if project_dir_open then
        if changed then coroutine.yield(0) else topdir.watch:wait(0.05) end
      else
        return
      end
    end
  end)

  if path == core.project_dir then
    core.project_files = topdir.files
  end
  core.redraw = true
  return topdir
end


-- The function below is needed to reload the project directories
-- when the project's module changes.
---Lists project directory `topdir` again (its top level and shown folders now,
---if in files_limit mode) and indexes it anew (core.scan_project_directory).
---@param topdir table
function core.rescan_project_directory(topdir)
  if topdir.files_limit then list_shown_subdirs(topdir) end
  core.scan_project_directory(topdir)
end


function core.rescan_project_directories()
  for _, dir in ipairs(core.project_directories) do
    core.rescan_project_directory(dir)
  end
end


function core.project_dir_by_name(name)
  for i = 1, #core.project_directories do
    if core.project_directories[i].name == name then
      return core.project_directories[i]
    end
  end
end


function core.update_project_subdir(dir, filename, expanded)
  assert(dir.files_limit, "function should be called only when directory is in files limit mode")
  dir.shown_subdir[filename] = expanded
  -- a scan watches every directory it lists
  if expanded or dir.scan then
    dir.watch:watch(dir.name .. PATHSEP .. filename)
  else
    dir.watch:unwatch(dir.name .. PATHSEP .. filename)
  end
  return refresh_directory(dir, filename)
end


-- Find files and directories recursively reading from the filesystem.
-- Filter files and yields file's directory and info table. This latter
-- is filled to be like required by project directories "files" list.
local function find_files_rec(dir, path, ignore_compiled)
  local root = dir.name
  ignore_compiled = ignore_compiled or dirwatch.compile_ignore_files()
  local all = system.list_dir(root .. path) or {}
  for _, file in ipairs(all) do
    local file = path .. PATHSEP .. file
    local info = system.get_file_info(root .. file)
    if info and info.type then
      info.filename = strip_leading_path(file)
      if dirwatch.project_file_filter(dir, info, ignore_compiled) then
        if info.type == "file" then
          coroutine.yield(root, info)
        else
          find_files_rec(dir, PATHSEP .. info.filename, ignore_compiled)
        end
      end
    end
  end
end


-- Iterator function to list all project files
local function project_files_iter(state)
  local dir = core.project_directories[state.dir_index]
  if state.co then
    -- We have a coroutine to fetch for files, use the coroutine.
    -- Used for directories that exceeds the files nuumber limit.
    local ok, name, file = coroutine.resume(state.co, dir, "")
    if ok and name then
      return name, file
    else
      -- The coroutine terminated, increment file/dir counter to scan
      -- next project directory.
      state.co = false
      state.file_index = 1
      state.dir_index = state.dir_index + 1
      dir = core.project_directories[state.dir_index]
    end
  else
    -- Increase file/dir counter
    state.file_index = state.file_index + 1
    while dir and state.file_index > #dir.files do
      state.dir_index = state.dir_index + 1
      state.file_index = 1
      dir = core.project_directories[state.dir_index]
    end
  end
  if not dir then return end
  if dir.files_limit then
    -- The current project directory is files limited: create a couroutine
    -- to read files from the filesystem.
    state.co = coroutine.create(find_files_rec)
    return project_files_iter(state)
  end
  return dir.name, dir.files[state.file_index]
end


function core.get_project_files()
  local state = { dir_index = 1, file_index = 0 }
  return project_files_iter, state
end


function core.project_files_number()
  local n = 0
  for i = 1, #core.project_directories do
    if core.project_directories[i].files_limit then return end
    n = n + #core.project_directories[i].files
  end
  return n
end


-- create a directory using mkdir but may need to create the parent
-- directories as well.
local function create_user_directory()
  local success, err = common.mkdirp(USERDIR)
  if not success then
    error("cannot create directory \"" .. USERDIR .. "\": " .. err)
  end
  for _, modname in ipairs {'plugins', 'colors', 'fonts'} do
    local subdirname = USERDIR .. PATHSEP .. modname
    if not system.mkdir(subdirname) then
      error("cannot create directory: \"" .. subdirname .. "\"")
    end
  end
end


local function write_user_init_file(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- put user settings here
-- this module will be loaded after everything else when the application starts
-- it will be automatically reloaded when saved

local core = require "core"
local keymap = require "core.keymap"
local config = require "core.config"
local style = require "core.style"

------------------------------ Themes ----------------------------------------

-- light theme:
-- core.reload_module("colors.summer")

--------------------------- Key bindings -------------------------------------

-- key binding:
-- keymap.add { ["ctrl+escape"] = "core:quit" }

-- pass 'true' for second parameter to overwrite an existing binding
-- keymap.add({ ["ctrl+pageup"] = "root:switch-to-previous-tab" }, true)
-- keymap.add({ ["ctrl+pagedown"] = "root:switch-to-next-tab" }, true)

------------------------------- Fonts ----------------------------------------

-- customize fonts:
-- style.font = renderer.font.load(DATADIR .. "/fonts/FiraSans-Regular.ttf", 14 * SCALE)
-- style.code_font = renderer.font.load(DATADIR .. "/fonts/JetBrainsMono-Regular.ttf", 14 * SCALE)
--
-- DATADIR is the location of the installed Lite XL Lua code, default color
-- schemes and fonts.
-- USERDIR is the location of the Lite XL configuration directory.
--
-- font names used by lite:
-- style.font          : user interface
-- style.big_font      : big text in welcome screen
-- style.icon_font     : icons
-- style.icon_big_font : toolbar icons
-- style.code_font     : code
--
-- the function to load the font accept a 3rd optional argument like:
--
-- {antialiasing="grayscale", hinting="full", bold=true, italic=true, underline=true, smoothing=true, strikethrough=true}
--
-- possible values are:
-- antialiasing: grayscale, subpixel
-- hinting: none, slight, full
-- bold: true, false
-- italic: true, false
-- underline: true, false
-- smoothing: true, false
-- strikethrough: true, false

------------------------------ Plugins ----------------------------------------

-- disable plugin loading setting config entries:

-- disable plugin detectindent, otherwise it is enabled by default:
-- config.plugins.detectindent = false

---------------------------- Miscellaneous -------------------------------------

-- modify list of files to ignore when indexing the project:
-- config.ignore_files = {
--   -- folders
--   "^%.svn/",        "^%.git/",   "^%.hg/",        "^CVS/", "^%.Trash/", "^%.Trash%-.*/",
--   "^node_modules/", "^%.cache/", "^__pycache__/",
--   -- files
--   "%.pyc$",         "%.pyo$",       "%.exe$",        "%.dll$",   "%.obj$", "%.o$",
--   "%.a$",           "%.lib$",       "%.so$",         "%.dylib$", "%.ncb$", "%.sdf$",
--   "%.suo$",         "%.pdb$",       "%.idb$",        "%.class$", "%.psd$", "%.db$",
--   "^desktop%.ini$", "^%.DS_Store$", "^%.directory$",
-- }

]])
  init_file:close()
end


function core.write_init_project_module(init_filename)
  local init_file = io.open(init_filename, "w")
  if not init_file then error("cannot create file: \"" .. init_filename .. "\"") end
  init_file:write([[
-- Put project's module settings here.
-- This module will be loaded when opening a project, after the user module
-- configuration.
-- It will be automatically reloaded when saved.

local config = require "core.config"

-- you can add some patterns to ignore files within the project
-- config.ignore_files = {"^%.", <some-patterns>}

-- Patterns are normally applied to the file's or directory's name, without
-- its path. See below about how to apply filters on a path.
--
-- Here some examples:
--
-- "^%." matches any file of directory whose basename begins with a dot.
--
-- When there is an '/' or a '/$' at the end, the pattern will only match
-- directories. When using such a pattern a final '/' will be added to the name
-- of any directory entry before checking if it matches.
--
-- "^%.git/" matches any directory named ".git" anywhere in the project.
--
-- If a "/" appears anywhere in the pattern (except when it appears at the end or
-- is immediately followed by a '$'), then the pattern will be applied to the full
-- path of the file or directory. An initial "/" will be prepended to the file's
-- or directory's path to indicate the project's root.
--
-- "^/node_modules/" will match a directory named "node_modules" at the project's root.
-- "^/build.*/" will match any top level directory whose name begins with "build".
-- "^/subprojects/.+/" will match any directory inside a top-level folder named "subprojects".

-- You may activate some plugins on a per-project basis to override the user's settings.
-- config.plugins.trimwitespace = true
]])
  init_file:close()
end


function core.load_user_directory()
  return core.try(function()
    local stat_dir = system.get_file_info(USERDIR)
    if not stat_dir then
      create_user_directory()
    end
    local init_filename = USERDIR .. PATHSEP .. "init.lua"
    local stat_file = system.get_file_info(init_filename)
    if not stat_file then
      write_user_init_file(init_filename)
    end
    dofile(init_filename)
  end)
end


function core.remove_project_directory(path)
  -- skip the fist directory because it is the project's directory
  for i = 2, #core.project_directories do
    local dir = core.project_directories[i]
    if dir.name == path then
      table.remove(core.project_directories, i)
      return true
    end
  end
  return false
end


function core.configure_borderless_window()
  system.set_window_bordered(not config.borderless)
  core.title_view:configure_hit_test(config.borderless)
  core.title_view.visible = config.borderless
end


local function add_config_files_hooks()
  -- auto-realod style when user's module is saved by overriding Doc:Save()
  local doc_save = Doc.save
  local user_filename = system.absolute_path(USERDIR .. PATHSEP .. "init.lua")
  function Doc:save(filename, abs_filename)
    local module_filename = system.absolute_path(".lite_project.lua")
    doc_save(self, filename, abs_filename)
    if common.path_equal(self.abs_filename, user_filename) or common.path_equal(self.abs_filename, module_filename) then
      reload_customizations()
      core.rescan_project_directories()
      core.configure_borderless_window()
    end
  end
end


-- The function below works like system.absolute_path except it
-- doesn't fail if the file does not exist. We consider that the
-- current dir is core.project_dir so relative filename are considered
-- to be in core.project_dir.
-- Please note that .. or . in the filename are not taken into account.
-- This function should get only filenames normalized using
-- common.normalize_path function.
function core.project_absolute_path(filename)
  if common.is_absolute_path(filename) then
    return common.normalize_path(filename)
  elseif not core.project_dir then
    local cwd = system.absolute_path(".")
    return cwd .. PATHSEP .. common.normalize_path(filename)
  else
    return core.project_dir .. PATHSEP .. filename
  end
end


function core.init()
  command = require "core.command"
  keymap = require "core.keymap"
  dirwatch = require "core.dirwatch"
  ime = require "core.ime"
  RootView = require "core.rootview"
  StatusView = require "core.statusview"
  TitleView = require "core.titleview"
  CommandView = require "core.commandview"
  NagView = require "core.nagview"
  DocView = require "core.docview"
  Doc = require "core.doc"

  if PATHSEP == '\\' then
    USERDIR = common.normalize_volume(USERDIR)
    DATADIR = common.normalize_volume(DATADIR)
    EXEDIR  = common.normalize_volume(EXEDIR)
  end

  do
    local session = load_session()
    if session.window_mode == "normal" then
      system.set_window_size(table.unpack(session.window))
    elseif session.window_mode == "maximized" then
      system.set_window_mode("maximized")
    end
    -- without paths that differ only in case (saved by versions that kept both)
    local function unique_paths(paths)
      local seen, res = {}, {}
      for _, path in ipairs(paths or {}) do
        if not seen[common.path_key(path)] then seen[common.path_key(path)] = true; table.insert(res, path) end
      end
      return res
    end
    core.recent_projects = unique_paths(session.recents)
    core.recent_files = unique_paths(session.recent_files)
    core.previous_find = session.previous_find or {}
    core.previous_replace = session.previous_replace or {}
  end

  local project_dir = core.recent_projects[1] or "."
  local project_dir_explicit = false
  local files = {}
  for i = 2, #ARGS do
    local arg_filename = strip_trailing_slash(ARGS[i])
    local info = system.get_file_info(arg_filename) or {}
    if info.type == "dir" then
      project_dir = arg_filename
      project_dir_explicit = true
    else
      -- on macOS we can get an argument like "-psn_0_52353" that we just ignore.
      if not ARGS[i]:match("^-psn") then
        local file_abs = core.project_absolute_path(arg_filename)
        if file_abs then
          table.insert(files, file_abs)
          project_dir = file_abs:match("^(.+)[/\\].+$")
        end
      end
    end
  end

  core.frame_start = 0
  core.clip_rect_stack = {{ 0,0,0,0 }}
  core.log_items = {}
  core.docs = {}
  core.cursor_clipboard = {}
  core.cursor_clipboard_whole_line = {}
  core.window_mode = "normal"
  core.threads = setmetatable({}, { __mode = "k" })
  core.blink_start = system.get_time()
  core.blink_timer = core.blink_start
  core.redraw = true
  core.visited_files = {}
  core.restart_request = false
  core.quit_request = false

  -- We load core views before plugins that may need them.
  ---@type core.rootview
  core.root_view = RootView()
  ---@type core.commandview
  core.command_view = CommandView()
  ---@type core.statusview
  core.status_view = StatusView()
  ---@type core.nagview
  core.nag_view = NagView()
  ---@type core.titleview
  core.title_view = TitleView()

  -- Some plugins (eg: console) require the nodes to be initialized to defaults
  local cur_node = core.root_view.root_node
  cur_node.is_primary_node = true
  cur_node:split("up", core.title_view, {y = true})
  cur_node = cur_node.b
  cur_node:split("up", core.nag_view, {y = true})
  cur_node = cur_node.b
  cur_node = cur_node:split("down", core.command_view, {y = true})
  cur_node = cur_node:split("down", core.status_view, {y = true})

  -- Load defaiult commands first so plugins can override them
  command.add_defaults()

  -- Load user module, plugins and project module
  local got_user_error, got_project_error = not core.load_user_directory()

  -- try to load a bunch of directories
  local try_project_dirs = {project_dir}
  if project_dir ~= "."     then table.insert(try_project_dirs, ".") end
  -- if cwd is not accessible for some reason (SIP on apple when launched from Finder), try home folder
  if PLATFORM == "Mac OS X" then table.insert(try_project_dirs, string.format("/Users/%s", os.getenv("USER"))) end
  if PLATFORM == "Windows"  then table.insert(try_project_dirs, string.format("%s\\%s", os.getenv("HOMEDRIVE"), os.getenv("HOMEPATH"))) end
  -- FIXME: better POSIX detection
  if os.getenv("USER")      then table.insert(try_project_dirs, string.format("/home/%s", os.getenv("USER"))) end
  -- discouraged since it can be blocked in sandboxed runtimes (SIP)
  table.insert(try_project_dirs, os.getenv("HOMEDRIVE") and (os.getenv("HOMEDRIVE").."\\") or "/")
  -- discouraged since it could be unreadable or embedded in the exe
  table.insert(try_project_dirs, DATADIR)

  local project_dir_abs
  local function load_project_module()
    got_project_error = not core.load_project_module()
  end
  for _, p in ipairs(try_project_dirs) do
    local abs_dir = system.absolute_path(p)
    if abs_dir and core.set_project_dir(abs_dir, load_project_module) then
      if p == project_dir and project_dir_explicit then
        update_recents_project("add", abs_dir)
      end
      project_dir_abs = abs_dir
      break
    else
      if p == project_dir and not project_dir_explicit then
        update_recents_project("remove", p)
      end
    end
  end
  if not project_dir_abs then
    system.show_fatal_error("Error", "Please restart Lite XL with a readable project directory.")
    os.exit(1)
  end

  -- Load core plugins after user ones to let the user override them
  local plugins_success, plugins_refuse_list = core.load_plugins()

  do
    local pdir, pname = project_dir_abs:match("(.*)[/\\\\](.*)")
    core.log("Opening project %q from directory %s", pname, pdir)
  end

  -- We add the project directory now because the project's module is loaded.
  core.add_project_directory(project_dir_abs)

  for _, filename in ipairs(files) do
    core.root_view:open_doc(core.open_doc(filename))
  end

  if not plugins_success or got_user_error or got_project_error then
    -- defer LogView to after everything is initialized,
    -- so that EmptyView won't be added after LogView.
    core.add_thread(function()
      command.perform("core:open-log")
    end)
  end

  core.configure_borderless_window()

  local any_refused = false
  for _, entry in pairs(plugins_refuse_list) do
    if #entry.plugins > 0 then any_refused = true end
  end
  if any_refused then
    local opt = {
      { text = "Exit", default_no = true },
      { text = "Continue", default_yes = true }
    }
    local msg = {}
    for _, entry in pairs(plugins_refuse_list) do
      if #entry.plugins > 0 then
        msg[#msg + 1] = string.format("Plugins from directory \"%s\":\n%s", common.home_encode(entry.dir), table.concat(entry.plugins, "\n"))
      end
    end
    core.nag_view:show(
      "Refused Plugins",
      string.format(
        "Some plugins are not loaded due to version mismatch.\n\n%s.\n\n" ..
        "Please download a recent version from https://github.com/lite-xl/lite-xl-plugins.",
        table.concat(msg, ".\n\n")),
      opt, function(item)
        if item.text == "Exit" then os.exit(1) end
      end)
  end

  add_config_files_hooks()
end


---Saves `doc`, under `filename` if given, then calls `on_saved`. If saving fails,
---offers to save it elsewhere, calling `on_saved` once that succeeds.
---@param doc core.doc
---@param filename? string
---@param on_saved? fun()
---@return boolean saved
function core.save_doc(doc, filename, on_saved)
  local abs_filename
  if filename then
    filename = core.normalize_to_project_dir(filename)
    abs_filename = core.project_absolute_path(filename)
  end
  local ok, err = pcall(doc.save, doc, filename, abs_filename)
  if ok then
    core.log("Saved \"%s\"", doc.filename)
    if on_saved then on_saved() end
    return true
  end
  core.error(err)
  core.nag_view:show("Saving Failed", string.format(
    "Couldn't save \"%s\". Save it to another location?", filename or doc:get_name()), {
    { text = "Save As...", default_yes = true },
    { text = "Cancel", default_no = true }
  }, function(item)
    if item.text == "Save As..." then
      -- in a thread: the nag view takes focus back from the command view on return
      core.add_thread(function() core.save_doc_as(doc, on_saved) end)
    end
  end)
  return false
end


---Asks for a filename and saves `doc` under it, then calls `on_saved`.
---@param doc core.doc
---@param on_saved? fun()
function core.save_doc_as(doc, on_saved)
  local text
  local last_doc = core.last_active_view and core.last_active_view.doc
  if doc.filename then
    text = doc.filename
  elseif last_doc and last_doc.abs_filename then
    text = core.normalize_to_project_dir(common.dirname(last_doc.abs_filename)) .. PATHSEP
  end
  core.command_view:enter("Save As", {
    text = text,
    submit = function(filename)
      core.save_doc(doc, common.home_expand(filename), on_saved)
    end,
    suggest = function(text)
      return common.home_encode_list(common.path_suggest(common.home_expand(text)))
    end
  })
end


---Saves docs one after another, asking for a filename for those without one, then
---calls `on_saved`. Stops at a save that fails or is cancelled.
local function save_docs(docs, on_saved)
  local i = 0
  local function save_next()
    i = i + 1
    local doc = docs[i]
    if not doc then return on_saved() end
    if doc.filename then return core.save_doc(doc, nil, save_next) end
    -- show the unnamed doc being named
    local view = core.get_views_referencing_doc(doc)[1]
    if view then
      core.root_view.root_node:get_node_for_view(view):set_active_view(view)
    end
    core.save_doc_as(doc, save_next)
  end
  save_next()
end


function core.confirm_close_docs(docs, close_fn, ...)
  local dirty = {}
  for _, doc in ipairs(docs or core.docs) do
    if doc:is_dirty() then table.insert(dirty, doc) end
  end
  if #dirty > 0 then
    local text
    if #dirty == 1 then
      local name = dirty[1].filename and string.format("\"%s\"", dirty[1].filename)
        or "the unnamed document"
      text = string.format("Save changes to %s before closing?", name)
    else
      text = string.format("Save changes to %d documents before closing?", #dirty)
    end
    local args = {...}
    local opt = {
      { text = "Save", default_yes = true },
      { text = "Discard" },
      { text = "Cancel", default_no = true }
    }
    core.nag_view:show("Unsaved Changes", text, opt, function(item)
      if item.text == "Save" then
        -- in a thread: the nag view takes focus back from the command view on return
        core.add_thread(function()
          save_docs(dirty, function() close_fn(table.unpack(args)) end)
        end)
      elseif item.text == "Discard" then
        close_fn(table.unpack(args))
      end
    end)
  else
    close_fn(...)
  end
end

---Asks to delete a file or directory (shown as `name`), then deletes it and
---closes the views of docs in it, without asking about their unsaved changes.
---@param abs_filename string
---@param name string
function core.confirm_delete(abs_filename, name)
  local info = system.get_file_info(abs_filename)
  if not info then return core.error("Cannot delete \"%s\": not found", name) end
  local is_dir = info.type == "dir"
  local docs, dirty = {}, false
  for _, doc in ipairs(core.docs) do
    local f = doc.abs_filename
    if f and (f == abs_filename or common.path_belongs_to(f, abs_filename)) then
      table.insert(docs, doc)
      dirty = dirty or doc:is_dirty()
    end
  end
  local text = is_dir
    and string.format("Delete the directory \"%s\" and everything in it?", name)
    or string.format("Delete the file \"%s\"?", name)
  if dirty then
    text = text .. (is_dir and " Unsaved changes to its open files are discarded."
      or " Its unsaved changes are discarded.")
  end
  core.nag_view:show(is_dir and "Delete Directory" or "Delete File", text, {
    { text = "Delete", default_yes = true },
    { text = "Cancel", default_no = true }
  }, function(item)
    if item.text ~= "Delete" then return end
    local ok, err, path = common.rm(abs_filename, is_dir)
    if not ok then return core.error("Cannot delete \"%s\": %s", path, err) end
    for _, doc in ipairs(docs) do
      for _, view in ipairs(core.get_views_referencing_doc(doc)) do
        core.root_view.root_node:get_node_for_view(view):remove_view(core.root_view.root_node, view)
      end
    end
    core.log("Deleted \"%s\"", name)
  end)
end

local temp_uid = math.floor(system.get_time() * 1000) % 0xffffffff
local temp_file_prefix = string.format(".lite_temp_%08x", tonumber(temp_uid))
local temp_file_counter = 0

function core.delete_temp_files(dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  for _, filename in ipairs(system.list_dir(dir) or {}) do
    if filename:find(temp_file_prefix, 1, true) == 1 then
      os.remove(dir .. PATHSEP .. filename)
    end
  end
end

function core.temp_filename(ext, dir)
  dir = type(dir) == "string" and common.normalize_path(dir) or USERDIR
  temp_file_counter = temp_file_counter + 1
  return dir .. PATHSEP .. temp_file_prefix
      .. string.format("%06x", temp_file_counter) .. (ext or "")
end

-- override to perform an operation before quitting or entering the
-- current project
do
  local do_nothing = function() end
  core.on_quit_project = do_nothing
  core.on_enter_project = do_nothing
end


local function quit_with_function(quit_fn, force)
  if force then
    core.delete_temp_files()
    core.on_quit_project()
    save_session()
    quit_fn()
  else
    core.confirm_close_docs(core.docs, quit_with_function, quit_fn, true)
  end
end

function core.quit(force)
  quit_with_function(function() core.quit_request = true end, force)
end


function core.restart()
  quit_with_function(function() core.restart_request = true end)
end


---Directories of add-ons besides the user and data directories, laid out as they
---are (plugins/, libraries/, colors/, native modules beside the Lua ones): searched
---after the user directory and before the data directory, in the order added.
---@type string[]
core.addon_dirs = {}

---Adds a directory of add-ons (see core.addon_dirs), e.g. a checkout's, so they're
---used from there rather than copied into the user directory. From the user module:
---its plugins load with the others, and it can require them once it's added.
---@param dir string
---@return boolean added false if it isn't a directory
function core.add_addon_dir(dir)
  local info = system.get_file_info(dir)
  if not info or info.type ~= "dir" then return false end
  dir = common.normalize_path(system.absolute_path(dir))
  for _, d in ipairs(core.addon_dirs) do
    if d == dir then return true end
  end
  table.insert(core.addon_dirs, dir)
  -- before the data directory's entries, so after those of the dirs added before
  local function insert(path, before, entries)
    local i = path:find(before, 1, true)
    return i and (path:sub(1, i - 1) .. entries .. path:sub(i)) or (path .. entries)
  end
  package.path = insert(package.path, DATADIR .. '/?/init.lua;',
    dir .. '/?/init.lua;' .. dir .. '/?.lua;')
  local suffix = PLATFORM == "Mac OS X" and 'lib' or (PLATFORM == "Windows" and 'dll' or 'so')
  package.cpath = insert(package.cpath, DATADIR .. '/?.' .. ARCH .. "." .. suffix .. ";",
    dir .. '/?.' .. ARCH .. "." .. suffix .. ";" ..
    dir .. '/?/init.' .. ARCH .. "." .. suffix .. ";" ..
    dir .. '/?.' .. suffix .. ";" ..
    dir .. '/?/init.' .. suffix .. ";")
  return true
end


local function get_plugin_details(filename)
  local info = system.get_file_info(filename)
  if info ~= nil and info.type == "dir" then
    filename = filename .. PATHSEP .. "init.lua"
    info = system.get_file_info(filename)
  end
  if not info or not filename:match("%.lua$") then return false end
  local f = io.open(filename, "r")
  if not f then return false end
  local priority = false
  local version_match = false
  for line in f:lines() do
    if not version_match then
      local mod_version = line:match('%-%-.*%f[%a]mod%-version%s*:%s*(%d+)')
      if mod_version then
        version_match = (mod_version == MOD_VERSION)
      end
    end
    if not priority then
      priority = line:match('%-%-.*%f[%a]priority%s*:%s*(%d+)')
      if priority then priority = tonumber(priority) end
    end
    if version_match then
      break
    end
  end
  f:close()
  return true, {
    version_match = version_match,
    priority = priority or 100
  }
end


function core.load_plugins()
  local no_errors = true
  local refused_list = {
    userdir = {dir = USERDIR, plugins = {}},
    datadir = {dir = DATADIR, plugins = {}},
  }
  -- the data directory's, then the added ones' (core.addon_dirs: the first added
  -- last), then the user's: each replaces a plugin of the same name before it
  local roots = { { dir = DATADIR, list = refused_list.datadir } }
  for i = #core.addon_dirs, 1, -1 do
    local entry = { dir = core.addon_dirs[i], plugins = {} }
    refused_list[core.addon_dirs[i]] = entry
    table.insert(roots, { dir = core.addon_dirs[i], list = entry })
  end
  table.insert(roots, { dir = USERDIR, list = refused_list.userdir })
  local files, ordered = {}, {}
  for _, root in ipairs(roots) do
    local plugin_dir = root.dir .. PATHSEP .. "plugins"
    for _, filename in ipairs(system.list_dir(plugin_dir) or {}) do
      -- not a plugin (a directory with only a native module, as a build's): it
      -- doesn't replace one
      local is_lua_file, details = get_plugin_details(plugin_dir .. PATHSEP .. filename)
      if is_lua_file or not files[filename] then
        if not files[filename] then
          table.insert(
            ordered, {file = filename}
          )
        end
        files[filename] = { dir = plugin_dir, root = root, valid = is_lua_file, details = details }
      end
    end
  end

  for _, plugin in ipairs(ordered) do
    local found = files[plugin.file]
    local name = plugin.file:match("(.-)%.lua$") or plugin.file
    local details = found.details

    plugin.valid = found.valid
    plugin.name = name
    plugin.dir = found.dir
    plugin.refused = found.root.list.plugins
    plugin.priority = details and details.priority or 100
    plugin.version_match = details and details.version_match or false
  end

  -- sort by priority or name for plugins that have same priority
  table.sort(ordered, function(a, b)
    if a.priority ~= b.priority then
      return a.priority < b.priority
    end
    return a.name < b.name
  end)

  local load_start = system.get_time()
  for _, plugin in ipairs(ordered) do
    if plugin.valid then
      if not config.skip_plugins_version and not plugin.version_match then
        core.log_quiet(
          "Version mismatch for plugin %q from %s",
          plugin.name,
          plugin.dir
        )
        table.insert(plugin.refused, plugin.file)
      elseif config.plugins[plugin.name] ~= false then
        local start = system.get_time()
        local ok = core.try(require, "plugins." .. plugin.name)
        if ok then
          core.log_quiet(
            "Loaded plugin %q from %s in %.1fms",
            plugin.name,
            plugin.dir,
            (system.get_time() - start) * 1000
          )
        end
        if not ok then
          no_errors = false
        end
      end
    end
  end
  core.log_quiet(
    "Loaded all plugins in %.1fms",
    (system.get_time() - load_start) * 1000
  )
  return no_errors, refused_list
end


function core.load_project_module()
  local filename = ".lite_project.lua"
  if system.get_file_info(filename) then
    return core.try(function()
      local fn, err = loadfile(filename)
      if not fn then error("Error when loading project module:\n\t" .. err) end
      fn()
      core.log_quiet("Loaded project module")
    end)
  end
  return true
end


function core.reload_module(name)
  local old = package.loaded[name]
  package.loaded[name] = nil
  local new = require(name)
  if type(old) == "table" then
    for k, v in pairs(new) do old[k] = v end
    package.loaded[name] = old
  end
end


function core.set_visited(filename)
  for i = 1, #core.visited_files do
    if core.visited_files[i] == filename then
      table.remove(core.visited_files, i)
      break
    end
  end
  table.insert(core.visited_files, 1, filename)
end


---When each view was last made active: views by increasing counter values, weak keys.
---Closing the active tab activates its node's most recently active other view.
core.view_visit_order = setmetatable({}, { __mode = "k" })
---While true, activated views don't count as visited (e.g. stepping through tabs).
core.keep_visit_order = false
local visit_counter = 0

function core.set_active_view(view)
  assert(view, "Tried to set active view to nil")
  -- Reset the IME even if the focus didn't change
  ime.stop()
  if view ~= core.active_view then
    if core.active_view and core.active_view.force_focus then
      core.next_active_view = view
      return
    end
    core.next_active_view = nil
    if view.doc and view.doc.filename then
      core.set_visited(view.doc.filename)
      -- a named doc that isn't a file (LSP's help) has no abs_filename
      if view.doc.abs_filename and not view:is_transient() then
        core.add_recent_file(view.doc.abs_filename)
      end
    end
    core.last_active_view = core.active_view
    core.active_view = view
  end
  if not core.keep_visit_order then
    visit_counter = visit_counter + 1
    core.view_visit_order[view] = visit_counter
  end
end


function core.show_title_bar(show)
  core.title_view.visible = show
end


local thread_counter = 0
function core.add_thread(f, weak_ref, ...)
  local key = weak_ref
  if not key then
    thread_counter = thread_counter + 1
    key = thread_counter
  end
  assert(core.threads[key] == nil, "Duplicate thread reference")
  local args = {...}
  local fn = function() return core.try(f, table.unpack(args)) end
  core.threads[key] = { cr = coroutine.create(fn), wake = 0 }
  return key
end


-- Threads waiting for core.wake(): key -> set of their coroutines
local thread_waits = {}
-- coroutine -> the key it was woken with
local woken_with = setmetatable({}, { __mode = "k" })
-- a thread was woken since the main loop last checked: run threads before waiting
local threads_woken = false

---Suspends the calling thread (the coroutine of core.add_thread, not one
---inside it) until core.wake() with one of `keys` (a key or a list of keys),
---or for at most `timeout` seconds (default: no limit). A wait with no limit
---is what lets an idle editor block until an event arrives.
---@param keys any
---@param timeout? number
---@return any key the key it was woken with, or nil after the timeout
function core.wait_for(keys, timeout)
  local co = coroutine.running()
  if type(keys) ~= "table" then keys = { keys } end
  for _, key in ipairs(keys) do
    thread_waits[key] = thread_waits[key] or setmetatable({}, { __mode = "k" })
    thread_waits[key][co] = true
  end
  coroutine.yield(timeout or math.huge)
  for _, key in ipairs(keys) do
    local waiting = thread_waits[key]
    if waiting then
      waiting[co] = nil
      if not next(waiting) then thread_waits[key] = nil end
    end
  end
  local key = woken_with[co]
  woken_with[co] = nil
  return key
end

---Wakes the threads waiting in core.wait_for() for `key`.
---@param key any
function core.wake(key)
  local waiting = thread_waits[key]
  if not waiting then return end
  for _, thread in pairs(core.threads) do
    if waiting[thread.cr] then
      waiting[thread.cr] = nil
      woken_with[thread.cr] = woken_with[thread.cr] or key
      thread.wake = 0
      threads_woken = true
    end
  end
end

---Arms a one-shot watch on `source` (as process:watch_source() returns) and
---returns the key core.wait_for() is woken with once it has data to read or
---ends. Re-arm after reading. If it can't be watched, the key is woken after
---a short while instead, so waiting for it polls.
---@param source integer
---@return string key
function core.watch_readable(source)
  local key = "readable:" .. source
  local ok, err = system.watch_readable(source)
  if not ok then
    core.log_quiet("Can't watch %s, polling instead: %s", key, err)
    core.add_thread(function()
      coroutine.yield(0.1)
      core.wake(key)
    end)
  end
  return key
end

---Drops the watch on `source` (before closing it) and wakes its waiters.
---@param source integer
function core.unwatch_readable(source)
  system.unwatch_readable(source)
  core.wake("readable:" .. source)
end


---@class core.task
---@field label string what's being done, e.g. "Indexing maps"
---@field progress? string how far it is, e.g. "1,200 files"
---@field start number system.get_time() when it was added
local Task = {}
Task.__index = Task

---Sets (or clears, with nil) how far the task is.
---@param progress? string
function Task:update(progress)
  if self.progress ~= progress then
    self.progress = progress
    core.redraw = true
  end
end

---Ends the task: it's no longer shown.
function Task:done()
  for i, task in ipairs(core.tasks) do
    if task == self then
      table.remove(core.tasks, i)
      core.redraw = true
      return
    end
  end
end

---Background work running, oldest first (see core.add_task): the status bar
---shows those running for core.task_delay seconds or more.
---@type core.task[]
core.tasks = {}

---How long a task runs before it's shown, so that quick ones don't flicker.
core.task_delay = 0.5

---Adds a task: background work to show on the status bar while it runs, so
---that what isn't finished (an index, a status) isn't taken for complete. End
---it with task:done(), however the work ends (an error included).
---@param label string
---@param progress? string
---@return core.task
function core.add_task(label, progress)
  local task = setmetatable({ label = label, progress = progress, start = system.get_time() }, Task)
  table.insert(core.tasks, task)
  -- a redraw when it's due to show
  core.add_thread(function()
    coroutine.yield(core.task_delay)
    for _, t in ipairs(core.tasks) do
      if t == task then core.redraw = true end
    end
  end)
  return task
end


function core.push_clip_rect(x, y, w, h)
  local x2, y2, w2, h2 = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  local r, b, r2, b2 = x+w, y+h, x2+w2, y2+h2
  x, y = math.max(x, x2), math.max(y, y2)
  b, r = math.min(b, b2), math.min(r, r2)
  w, h = r-x, b-y
  table.insert(core.clip_rect_stack, { x, y, w, h })
  renderer.set_clip_rect(x, y, w, h)
end


function core.pop_clip_rect()
  table.remove(core.clip_rect_stack)
  local x, y, w, h = table.unpack(core.clip_rect_stack[#core.clip_rect_stack])
  renderer.set_clip_rect(x, y, w, h)
end


function core.normalize_to_project_dir(filename)
  filename = common.normalize_path(filename)
  if common.path_belongs_to(filename, core.project_dir) then
    filename = common.relative_path(core.project_dir, filename)
  end
  return filename
end


function core.open_doc(filename)
  local new_file = not filename or not system.get_file_info(filename)
  local abs_filename
  if filename then
    -- normalize filename and set absolute filename then
    -- try to find existing doc for filename
    filename = core.normalize_to_project_dir(filename)
    abs_filename = core.project_absolute_path(filename)
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename and common.path_equal(abs_filename, doc.abs_filename) then
        return doc
      end
    end
  end
  -- no existing doc for filename; create new
  local doc = Doc(filename, abs_filename, new_file)
  table.insert(core.docs, doc)
  core.log_quiet(filename and "Opened doc \"%s\"" or "Opened new doc", filename)
  return doc
end


function core.get_views_referencing_doc(doc)
  local res = {}
  local views = core.root_view.root_node:get_children()
  for _, view in ipairs(views) do
    if view.doc == doc then table.insert(res, view) end
  end
  return res
end


function core.custom_log(level, show, backtrace, fmt, ...)
  local text = string.format(fmt, ...)
  if show then
    local s = style.log[level]
    if core.status_view then
      core.status_view:show_message(s.icon, s.color, text)
      if level == "ERROR" or (level == "WARN" and core.status_view.log_alert ~= "ERROR") then
        core.status_view.log_alert = level
      end
    end
  end

  local info = debug.getinfo(2, "Sl")
  local at = string.format("%s:%d", info.short_src, info.currentline)
  local item = {
    level = level,
    text = text,
    time = os.time(),
    at = at,
    info = backtrace and debug.traceback("", 2):gsub("\t", "")
  }
  table.insert(core.log_items, item)
  if #core.log_items > config.max_log_items then
    table.remove(core.log_items, 1)
  end
  return item
end


function core.log(...)
  return core.custom_log("INFO", true, false, ...)
end


function core.log_quiet(...)
  return core.custom_log("INFO", false, false, ...)
end

function core.warn(...)
  return core.custom_log("WARN", true, true, ...)
end

function core.error(...)
  return core.custom_log("ERROR", true, true, ...)
end


function core.get_log(i)
  if i == nil then
    local r = {}
    for _, item in ipairs(core.log_items) do
      table.insert(r, core.get_log(item))
    end
    return table.concat(r, "\n")
  end
  local item = type(i) == "number" and core.log_items[i] or i
  local text = string.format("%s [%s] %s at %s", os.date(nil, item.time), item.level, item.text, item.at)
  if item.info then
    text = string.format("%s\n%s\n", text, item.info)
  end
  return text
end


---Functions closing popups that take input before the views (menus), without
---calling into them; see core.close_popups.
core.popup_closers = {}

---Called when handling an event fails: closes the popups, since one left broken
---by the error would take every event after it and fail again, leaving the
---editor unusable.
function core.close_popups()
  local menu = core.context_menu
  if menu then
    core.context_menu = nil
    menu.show_context_menu, menu.items, menu.selected = false, nil, -1
  end
  for _, close in ipairs(core.popup_closers) do pcall(close) end
  core.redraw = true
end


function core.try(fn, ...)
  local err
  local ok, res = xpcall(fn, function(msg)
    local item = core.error("%s", msg)
    item.info = debug.traceback("", 2):gsub("\t", "")
    err = msg
  end, ...)
  if ok then
    return true, res
  end
  return false, err
end

-- the open file dialogs' callbacks, by id (see core.open_file_dialog)
local file_dialogs = {}

function core.on_event(type, ...)
  local did_keymap = false
  -- typing, clicking or scrolling hides a message (before the event, which may
  -- show another); modifiers alone don't, as for ctrl+hover
  if type == "textinput" or type == "mousepressed" or type == "mousewheel"
    or (type == "keypressed" and not keymap.is_modifier((...))) then
    if core.status_view then core.status_view:hide_message() end
  end
  if type == "textinput" then
    if not core.context_menu then core.root_view:on_text_input(...) end
  elseif type == "textediting" then
    ime.on_text_editing(...)
  elseif type == "keypressed" then
    -- In some cases during IME composition input is still sent to us
    -- so we just ignore it.
    if ime.editing then return false end
    -- an open context menu takes the keyboard (modifiers still go to the
    -- keymap, which tracks them)
    if core.context_menu and not keymap.is_modifier((...)) then
      core.context_menu:on_key_pressed(...)
      did_keymap = true
    else
      did_keymap = keymap.on_key_pressed(...)
    end
  elseif type == "keyreleased" then
    keymap.on_key_released(...)
  elseif type == "mousemoved" then
    -- where the pointer is, though a popup may keep the move from the root view
    local mouse = core.root_view.mouse
    mouse.x, mouse.y = ...
    core.root_view:on_mouse_moved(...)
  elseif type == "mousepressed" then
    if not core.root_view:on_mouse_pressed(...) then
      did_keymap = keymap.on_mouse_pressed(...)
    end
  elseif type == "hittest" then
    core.title_view:on_hit_test(...)
  elseif type == "mousereleased" then
    core.root_view:on_mouse_released(...)
  elseif type == "mouseleft" then
    core.root_view:on_mouse_left()
  elseif type == "mousewheel" then
    if not core.root_view:on_mouse_wheel(...) then
      did_keymap = keymap.on_mouse_wheel(...)
    end
  elseif type == "touchpressed" then
    core.root_view:on_touch_pressed(...)
  elseif type == "touchmoved" then
    core.root_view:on_touch_moved(...)
  elseif type == "touchreleased" then
    core.root_view:on_touch_released(...)
  elseif type == "resized" then
    core.window_mode = system.get_window_mode()
  elseif type == "minimized" or type == "maximized" or type == "restored" then
    core.window_mode = type == "restored" and "normal" or type
  elseif type == "filedropped" then
    core.root_view:on_file_dropped(...)
  elseif type == "dialogfinished" then
    local id, status, result = ...
    local callback = file_dialogs[id]
    file_dialogs[id] = nil
    if callback then callback(status, result) end
  elseif type == "focuslost" then
    core.root_view:on_focus_lost(...)
  elseif type == "quit" then
    core.quit()
  end
  return did_keymap
end


local function get_title_filename(view)
  local doc_filename = view.get_filename and view:get_filename() or view:get_name()
  if doc_filename ~= "---" then return doc_filename end
  return ""
end


function core.compose_window_title(title)
  return (title == "" or title == nil) and "Lite XL" or title .. " - Lite XL"
end


function core.step()
  -- handle events
  local did_keymap = false

  -- e: touchmoved's finger id, the only event with five values
  for type, a,b,c,d,e in system.poll_event do
    if type == "readable" or type == "dirchange" then
      -- a background source: wake the threads waiting for it, without a redraw
      core.wake(type == "readable" and "readable:" .. a or "dirchange")
    else
      if type == "textinput" and did_keymap then
        did_keymap = false
      elseif type == "mousemoved" then
        if not core.try(core.on_event, type, a, b, c, d) then core.close_popups() end
      else
        local ok, res = core.try(core.on_event, type, a, b, c, d, e)
        if not ok then core.close_popups() end
        did_keymap = res or did_keymap
      end
      core.redraw = true
    end
  end

  local width, height = renderer.get_size()

  -- update
  core.root_view.size.x, core.root_view.size.y = width, height
  core.root_view:update()
  if not core.redraw then return false end
  core.redraw = false

  close_unreferenced_docs()

  -- update window title
  local current_title = get_title_filename(core.active_view)
  if current_title ~= nil and current_title ~= core.window_title then
    system.set_window_title(core.compose_window_title(current_title))
    core.window_title = current_title
  end

  -- draw
  renderer.begin_frame()
  core.clip_rect_stack[1] = { 0, 0, width, height }
  renderer.set_clip_rect(table.unpack(core.clip_rect_stack[1]))
  core.root_view:draw()
  renderer.end_frame()
  return true
end


local run_threads = coroutine.wrap(function()
  while true do
    local max_time = 1 / config.fps - 0.004
    local minimal_time_to_wake = math.huge

    local threads = {}
    -- We modify core.threads while iterating, both by removing dead threads,
    -- and by potentially adding more threads while we yielded early,
    -- so we need to extract the threads list and iterate over that instead.
    for k, thread in pairs(core.threads) do
      threads[k] = thread
    end

    for k, thread in pairs(threads) do
      -- Run thread if it wasn't deleted externally and it's time to resume it
      if core.threads[k] and thread.wake < system.get_time() then
        local _, wait = assert(coroutine.resume(thread.cr))
        if coroutine.status(thread.cr) == "dead" then
          core.threads[k] = nil
        elseif wait then
          thread.wake = system.get_time() + wait
          minimal_time_to_wake = math.min(minimal_time_to_wake, wait)
        else
          minimal_time_to_wake = 0
        end
      else
        minimal_time_to_wake =  math.min(minimal_time_to_wake, thread.wake - system.get_time())
      end

      -- stop running threads if we're about to hit the end of frame
      if system.get_time() - core.frame_start > max_time then
        coroutine.yield(0, false)
      end
    end

    coroutine.yield(minimal_time_to_wake, true)
  end
end)


function core.run()
  local next_step
  local last_frame_time
  local run_threads_full = 0
  while true do
    core.frame_start = system.get_time()
    local time_to_wake, threads_done = run_threads()
    if threads_done then
      run_threads_full = run_threads_full + 1
    end
    local did_redraw = false
    local did_step = false
    local force_draw = core.redraw and last_frame_time and core.frame_start - last_frame_time > (1 / config.fps)
    if force_draw or not next_step or system.get_time() >= next_step then
      if core.step() then
        did_redraw = true
        last_frame_time = core.frame_start
      end
      next_step = nil
      did_step = true
    end
    if core.restart_request or core.quit_request then break end
    -- threads woken by this step's events (or by other threads) run before any wait
    if threads_woken then
      threads_woken = false
      time_to_wake = 0
    end

    if not did_redraw then
      if system.window_has_focus() or not did_step or run_threads_full < 2 then
        local now = system.get_time()
        if not next_step then -- compute the time until the next blink
          local t = now - core.blink_start
          local h = config.blink_period / 2
          local dt = math.ceil(t / h) * h - t
          local cursor_time_to_wake = dt + 1 / config.fps
          next_step = now + cursor_time_to_wake
        end
        if system.wait_event(math.min(next_step - now, time_to_wake)) then
          next_step = nil -- if we've recevied an event, perform a step
        end
      else
        -- Not in focus: no cursor blink, so only step on events (threads that
        -- set core.redraw are handled by force_draw), but still wake up for
        -- threads (LSP clients, file watchers, ...), which would otherwise only
        -- run when an event happens to arrive.
        local got_event
        if time_to_wake < math.huge then
          got_event = system.wait_event(time_to_wake)
        else
          got_event = system.wait_event()
        end
        -- perform a step when we're not in focus if we get an event
        if got_event then next_step = nil else next_step = math.huge end
      end
    else -- if we redrew, then make sure we only draw at most FPS/sec
      run_threads_full = 0
      local now = system.get_time()
      local elapsed = now - core.frame_start
      local next_frame = math.max(0, 1 / config.fps - elapsed)
      next_step = next_step or (now + next_frame)
      system.sleep(math.min(next_frame, time_to_wake))
    end
  end
end


function core.blink_reset()
  core.blink_start = system.get_time()
end


-- The system's file dialogs (from upstream f580d020). They return at once; the
-- callback gets status "accept" and a list of paths, "cancel", or "error" and a
-- message. Options (all optional): default_location, title, accept_label,
-- cancel_label; allow_many for the open dialogs; filters for the file dialogs,
-- a list of { name = "Lua", pattern = "lua;luac" } (* for all).
local last_dialog_id = 0
local function open_dialog(fn, callback, options)
  last_dialog_id = last_dialog_id + 1
  file_dialogs[last_dialog_id] = callback
  fn(last_dialog_id, options)
end

---@param callback fun(status: "accept"|"cancel"|"error", result: string[]|string|nil)
function core.open_file_dialog(callback, options)
  open_dialog(system.open_file_dialog, callback, options)
end

---@param callback fun(status: "accept"|"cancel"|"error", result: string[]|string|nil)
function core.open_directory_dialog(callback, options)
  open_dialog(system.open_directory_dialog, callback, options)
end

---@param callback fun(status: "accept"|"cancel"|"error", result: string[]|string|nil)
function core.save_file_dialog(callback, options)
  open_dialog(system.save_file_dialog, callback, options)
end


function core.request_cursor(value)
  core.cursor_change_req = value
end


function core.on_error(err)
  -- write error to file
  local fp = io.open(USERDIR .. PATHSEP .. "error.txt", "wb")
  fp:write("Error: " .. tostring(err) .. "\n")
  fp:write(debug.traceback("", 4) .. "\n")
  fp:close()
  -- save copy of all unsaved documents
  for _, doc in ipairs(core.docs) do
    if doc:is_dirty() and doc.filename then
      doc:save(doc.filename .. "~")
    end
  end
end


return core
