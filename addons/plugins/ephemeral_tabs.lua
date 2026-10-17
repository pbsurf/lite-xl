-- mod-version:3
local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local RootView = require "core.rootview"
local DocView = require "core.docview"
local Doc = require "core.doc"
local TreeView = require "plugins.treeview"

-- Only a doc opened with opts.preview (while browsing: tree view, go to
-- definition, ...) gets a preview tab; other opens (ctrl+p, ctrl+o, ...) make a
-- normal one
local RootView_open_doc = RootView.open_doc
function RootView:open_doc(doc, opts)
  -- Only a view open_doc creates is a preview; one already in the node keeps its
  -- state, also when it has no ephemeral flag (added otherwise, e.g. restored by
  -- the workspace)
  local node = self:get_active_node_default()
  local exists = false
  for _, v in ipairs(node.views) do
    if v.doc == doc then exists = true end
  end
  local docview = RootView_open_doc(self, doc, opts)
  if not (opts and opts.preview) then
    -- Opening a preview's doc otherwise makes it normal
    if docview.ephemeral then docview.ephemeral = false end
  elseif not exists then
    -- We assume that ephemeral tab is always the last one
    -- But user can drag and drop tabs so full check is needed
    for i, v in ipairs(node.views) do
      if v.ephemeral then
        node:close_view(self.root_node, v)
      end
    end
    docview.ephemeral = true
  end
  return docview
end

-- Ephemeral tabs show their title in italic (a synthesized slant, same advances)
local italic_fonts = setmetatable({}, { __mode = "k" })
local function italic(font)
  if not italic_fonts[font] then
    italic_fonts[font] = font:copy(font:get_size(), { italic = true })
  end
  return italic_fonts[font]
end

local DocView_get_name_style = DocView.get_name_style
function DocView:get_name_style(font)
  font = DocView_get_name_style(self, font)
  return self.ephemeral and italic(font) or font
end

-- A preview tab isn't restored with the workspace
function DocView:is_transient()
  return self.ephemeral == true
end

-- Any edit to the document makes the tab normal (a reload from disk isn't one,
-- and may be of a doc in another tab)
local Doc_on_text_change = Doc.on_text_change
function Doc:on_text_change(type)
  if type ~= "reload" then core.active_view.ephemeral = false end
  Doc_on_text_change(self, type)
end

-- Double clicking a file in the TreeView opens it as a normal tab (the keymap
-- tries "2lclick" before "lclick", treeview's binding for select-and-open)
command.add(
  function()
    return not TreeView.contextmenu.show_context_menu
      and core.active_view == TreeView
  end, {
  ["ephemeral-tabs:treeview-select-and-open-normal"] = function()
    command.perform "treeview:select-and-open"
    if core.active_view.doc then core.active_view.ephemeral = false end
  end
})

keymap.add { ["2lclick"] = "ephemeral-tabs:treeview-select-and-open-normal" }

-- Double clicking on a tab makes it normal
local RootView_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local result = RootView_on_mouse_pressed(self, button, x, y, clicks)
  if clicks > 1 then
    local node = self.root_node:get_child_overlapping_point(x, y)
    local idx = node:get_tab_overlapping_point(x, y)
    if idx then
      node.views[idx].ephemeral = false
    end
  end
  return result
end

-- Dragging a tab makes it normal
local RootView_on_mouse_released = RootView.on_mouse_released
function RootView:on_mouse_released(button, x, y, ...)
  if self.dragged_node then
    if button == "left" then
      if self.dragged_node.dragging then
        local view = self.dragged_node.node.views[self.dragged_node.idx]
        view.ephemeral = false
      end
    end
  end
  return RootView_on_mouse_released(self, button, x, y, ...)
end
