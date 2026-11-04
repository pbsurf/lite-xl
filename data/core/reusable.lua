local core = require "core"

---Reusable views: a view that the next one of its kind replaces, rather than
---opening a tab of its own. A search's results or a build's output reuse its
---kind's current view (core.panel); a file opened while browsing replaces the
---one opened so before in its node, as a preview tab (RootView:open_doc).
---
---A reusable view's title is italic (View:get_name_style), and it isn't restored
---with the workspace (View:is_transient). Double-clicking its tab keeps it, as
---does dragging it out of the panel or to another place in the editor, and so
---does what makes the view the user's (editing a preview's file, a double click
---on the file in the tree view); the next one then gets a tab of its own.
local reusable = {}

---The current view of each key: a view class, or for a preview, its node
---@type table<any, core.view>
local current = setmetatable({}, { __mode = "k" })

-- in a node, or taken out by panel.hide() (until the panel is shown again)
local function is_open(view)
  return core.root_view.root_node:get_node_for_view(view) ~= nil
    or require("core.panel").contains(view)
end

---The current view of `key`, if it's still open.
---@param key any A view class, or what the caller keys its views by
---@return core.view?
function reusable.current(key)
  local view = current[key]
  if view and view.reusable and is_open(view) then return view end
  current[key] = nil
end

---Makes a view the current one of `key` (by default the view's class), in
---place of the one before, which the caller has reused or closes: it stays
---reusable meanwhile (transient: a preview's file isn't made recent by closing
---it).
---@param view core.view
---@param key? any
function reusable.set_current(view, key)
  current[key or getmetatable(view)] = view
  view.reusable = true
end

---Keeps a view: its key's next view gets a tab of its own. A doc's file
---becomes recent (core.recent_files) only now, as the view stops being
---transient.
---@param view core.view
function reusable.keep(view)
  if not view.reusable then return end
  view.reusable = nil
  for key, v in pairs(current) do
    if v == view then current[key] = nil end
  end
  if view.doc and view.doc.abs_filename then core.add_recent_file(view.doc.abs_filename) end
end

return reusable
