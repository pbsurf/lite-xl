-- mod-version:3
local core = require "core"
local command = require "core.command"
local RootView = require "core.rootview"
local DocView = require "core.docview"
local Doc = require "core.doc"
local TreeView = require "plugins.treeview"

local RootView_open_doc = RootView.open_doc
function RootView:open_doc(doc)
  -- Only a view open_doc creates is a preview; one already in the node keeps its
  -- state, also when it has no ephemeral flag (added otherwise, e.g. restored by
  -- the workspace)
  local node = self:get_active_node_default()
  local exists = false
  for _, v in ipairs(node.views) do
    if v.doc == doc then exists = true end
  end
  local docview = RootView_open_doc(self, doc)
  if not exists then
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

-- Double clicking in the TreeView makes the tab normal
local TreeView_on_mouse_pressed = TreeView.on_mouse_pressed
function TreeView:on_mouse_pressed(button, x, y, clicks)
  local result = TreeView_on_mouse_pressed(self, button, x, y, clicks)
  if (clicks > 1) and (core.active_view.doc ~= nil) then
    core.active_view.ephemeral = false
  end
  return result
end

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
