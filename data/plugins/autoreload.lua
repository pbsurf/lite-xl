-- mod-version:3
local core = require "core"
local config = require "core.config"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local Node = require "core.node"
local common = require "core.common"
local dirwatch = require "core.dirwatch"

config.plugins.autoreload = common.merge({
  always_show_nagview = false,
  config_spec = {
    name = "Autoreload",
    {
      label = "Always Show Nagview",
      description = "Alerts you if an opened file changes externally even if you haven't modified it.",
      path = "always_show_nagview",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.autoreload)

local watch = dirwatch.new()
local times = setmetatable({}, { __mode = "k" })
local visible = setmetatable({}, { __mode = "k" })

-- Visible docs are watched through their directory, not the file itself: a file
-- replaced by renaming another over it (how many editors and tools save) leaves a
-- file watch on the old, deleted inode, reporting nothing then or later.
local dir_watchers = {} -- directory -> number of watched docs in it
local doc_dirs = setmetatable({}, { __mode = "k" }) -- doc -> its watched directory

local function watch_doc(doc, watched)
  local dir = doc_dirs[doc]
  if dir and (not watched or dir ~= common.dirname(doc.abs_filename)) then
    doc_dirs[doc] = nil
    dir_watchers[dir] = dir_watchers[dir] - 1
    if dir_watchers[dir] == 0 then
      dir_watchers[dir] = nil
      watch:watch(dir, false)
    end
  end
  if watched and not doc_dirs[doc] then
    dir = common.dirname(doc.abs_filename)
    doc_dirs[doc] = dir
    dir_watchers[dir] = (dir_watchers[dir] or 0) + 1
    if dir_watchers[dir] == 1 then watch:watch(dir, true) end
  end
end

local function update_time(doc)
  times[doc] = system.get_file_info(doc.filename).modified
end

-- asked: reloaded on the user's answer, rather than automatically
local function reload_doc(doc, asked)
  doc:reload()
  core.redraw = true
  if asked then
    core.log_quiet("Reloaded doc \"%s\"", doc.filename)
    return
  end
  core.log("Reloaded %s (changed on disk)", doc.filename)
  -- even when shown, the new text may go unnoticed: its tabs get a badge until
  -- the next input while it's the active doc
  doc.reloaded_unseen = true
end

function DocView:get_icon_badge()
  return self.doc.reloaded_unseen and style.accent or nil
end

local function seen(doc)
  if doc and doc.reloaded_unseen and system.window_has_focus() then
    doc.reloaded_unseen = nil
    core.redraw = true
  end
end

-- A reloaded doc is seen at the first input while it's the active doc
local on_event = core.on_event
function core.on_event(type, ...)
  if type == "keypressed" or type == "mousepressed" or type == "mousewheel" then
    seen(core.active_view.doc)
  end
  return on_event(type, ...)
end


local function check_prompt_reload(doc)
  if doc and doc.deferred_reload then
    core.nag_view:show("File Changed", doc.filename .. " has changed on disk. Reload it?"
      .. (doc:is_dirty() and " Undo brings back your unsaved changes." or ""), {
      { text = "Reload", default_yes = true },
      { text = "Keep Current", default_no = true }
    }, function(item)
      if item.text == "Reload" then reload_doc(doc, true) end
      doc.deferred_reload = false
    end)
  end
end

local timers = setmetatable({}, { __mode = "k" })

local function delayed_reload(doc, mtime)
  if timers[doc] then
    -- If mtime remains the same, there's no need to restart the timer
    -- as we're waiting a full second anyways.
    if not mtime or timers[doc].mtime ~= mtime then
      timers[doc] = { last_trigger = system.get_time(), mtime = mtime }
    end
    return
  end

  timers[doc] = { last_trigger = system.get_time(), mtime = mtime }
  core.add_thread(function()
    local diff = system.get_time() - timers[doc].last_trigger
    -- Wait a second before triggering a reload because we're using mtime
    -- to determine if a file has changed, and on many systems it has a
    -- resolution of 1 second.
    while diff < 1 do
      coroutine.yield(1 - diff)
      diff = system.get_time() - timers[doc].last_trigger
    end
    timers[doc] = nil
    if doc:is_dirty() then
      -- edited while we waited: ask, as for a change to an edited doc
      doc.deferred_reload = true
      if doc == core.active_view.doc then check_prompt_reload(doc) end
    else
      reload_doc(doc)
    end
  end)
end

-- If the doc's file changed since it was loaded or saved: reloads it, or marks
-- it for asking (deferred_reload, returning true). shown: it's being shown, so
-- a change from a while ago (no longer being written) is reloaded at once.
local function check_doc(doc, shown)
  local info = system.get_file_info(doc.filename or "")
  if info and info.type == "file" and times[doc] ~= info.modified then
    if not doc:is_dirty() and not config.plugins.autoreload.always_show_nagview then
      if shown and os.time() - info.modified >= 1 then
        reload_doc(doc)
      else
        delayed_reload(doc, info.modified)
      end
    else
      doc.deferred_reload = true
      return true
    end
  end
end

local function doc_changes_visiblity(doc, visibility)
  if doc and visible[doc] ~= visibility and doc.abs_filename then
    visible[doc] = visibility
    -- unwatched while hidden (unless another doc in its directory was visible):
    -- a change made then is found now
    if visibility then
      if not doc.deferred_reload then check_doc(doc, true) end
      check_prompt_reload(doc)
    end
    watch_doc(doc, visibility)
  end
end

local on_check = dirwatch.check
function dirwatch:check(change_callback, ...)
  on_check(self, function(dir)
    for _, doc in ipairs(core.docs) do
      if doc.abs_filename and (dir == common.dirname(doc.abs_filename) or dir == doc.abs_filename) then
        if check_doc(doc) and doc == core.active_view.doc then check_prompt_reload(doc) end
      end
    end
    change_callback(dir)
  end, ...)
end

local core_set_active_view = core.set_active_view
function core.set_active_view(view)
  core_set_active_view(view)
  doc_changes_visiblity(view.doc, true)
end

local node_set_active_view = Node.set_active_view
function Node:set_active_view(view)
  if self.active_view then doc_changes_visiblity(self.active_view.doc, false) end
  node_set_active_view(self, view)
  doc_changes_visiblity(self.active_view.doc, true)
end

core.add_thread(function()
  while true do
    -- because we already hook this function above; we only
    -- need to check the file.
    watch:check(function() end)
    watch:wait(0.05)
  end
end)

-- patch `Doc.save|load|reload` to store modified time
local load = Doc.load
local reload = Doc.reload
local save = Doc.save

Doc.load = function(self, ...)
  local res = load(self, ...)
  update_time(self)
  return res
end

Doc.reload = function(self, ...)
  local res = reload(self, ...)
  if self.filename then update_time(self) end
  return res
end

Doc.save = function(self, ...)
  local res = save(self, ...)
  -- if starting with an unsaved document with a filename, or saved to another directory
  if not times[self] or doc_dirs[self] then watch_doc(self, true) end
  update_time(self)
  return res
end
