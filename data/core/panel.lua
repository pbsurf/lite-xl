local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Node = require "core.node"
local EmptyView = require "core.emptyview"
local reusable = require "core.reusable"

---The bottom panel: a region below the editor area, split from it, holding
---tool views (search results, build output, terminals) as ordinary tabs, which
---show their status in their titles. It's ordinary nodes: it can be split, and
---tabs dragged within it and in and out of it. Each of its leaves has
---`is_panel` (a leaf split from one gets it too). It's made when a view is shown
---in it and goes away with its last tab, keeping its height for next time; hide()
---takes it out as it is, splits and all, and show() puts it back. Files don't
---open in it (RootView:get_active_node_default) and it never becomes the
---primary node. The workspace saves it as any split (its leaves the views that
---can be restored) and restores it hidden. The divider above it is thicker than
---an editor split's, in a muted accent color (style.panel_divider_size,
---style.panel_divider), telling the two apart.
---
---Each kind of view (its class) can have a current view (core.reusable), which
---the kind's next search or run reuses rather than opening another tab. Moving
---it out of the panel (a drag, "Move to Editor") keeps it, so the next one opens
---in the panel.
local panel = {}

---The panel's height (pixels) when it last went away; nil until then, for a
---third of the editor area
---@type number?
panel.height = nil

---The panel's region hide() took out, until the next show()
---@type core.node?
local hidden
-- its divider when hide() took it out before it was laid out (restored by the
-- workspace): its height then, panel.height not known
local hidden_divider

---Whether a node is (all) the panel's: its leaves are.
---@param node core.node
---@return boolean
function panel.is_region(node)
  if node.type == "leaf" then return node.is_panel == true end
  return panel.is_region(node.a) and panel.is_region(node.b)
end

local function find_region(node)
  if panel.is_region(node) then return node end
  if node.type ~= "leaf" then return find_region(node.a) or find_region(node.b) end
end

-- the region's leaf used last, else its first: where views are added
local function last_used_leaf(region)
  local node = core.root_view:get_last_visited_node(region, true)
  if node then return node end
  node = region
  while node.type ~= "leaf" do node = node.a end
  return node
end

---The panel's node (its root: a leaf, or a split of its leaves), nil while
---it's not shown.
---@return core.node?
function panel.get_region()
  return find_region(core.root_view.root_node)
end

---The panel's leaf that views are added to (the one used last), nil while the
---panel's not shown.
---@return core.node?
function panel.get_node()
  local region = panel.get_region()
  return region and last_used_leaf(region)
end

-- the panel's split's divider, as the color scheme is now
local function divider_size()
  return style.panel_divider_size or common.round(3 * SCALE)
end

local function divider_color()
  return style.panel_divider or common.lerp(style.background, style.accent, 0.5)
end

-- the region's last leaf going away (its parent the split from the editor area)
local function on_collapse(node)
  local parent = node:get_parent_node(core.root_view.root_node)
  -- not before it's been laid out (made and taken out at once)
  if parent and not panel.is_region(parent) and node.size.y > 0 then
    panel.height = node.size.y
  end
end

-- an empty panel leaf lists what opens in it, not the editor's shortcuts
-- (lines of commands without a key binding, from plugins not loaded, left out)
local empty_lines = {
  { fmt = "%s for a terminal", cmd = "terminal:swap-focus" },
  { fmt = "%s to build", cmd = "build:build" },
  { fmt = "%s to search the project", cmd = "project-search:find" },
  { fmt = "%s to debug", cmd = "debug:start-or-continue" },
  { fmt = "Tabs can be dragged here" },
}

---Makes a leaf the panel's (the workspace restoring it).
---@param node core.node
function panel.init_leaf(node)
  node.is_panel = true
  node.on_collapse = on_collapse
  node.fit_tab_width, node.max_tab_width = true, 640
  for _, view in ipairs(node.views) do
    if view:is(EmptyView) then view.lines = empty_lines end
  end
end

-- a panel leaf's split makes another
local node_split = Node.split
function Node:split(...)
  local is_panel = self.is_panel
  local node = node_split(self, ...)
  if is_panel then panel.init_leaf(node) end
  return node
end

-- A split of the editor area (the unlocked root): the editor area above, the
-- panel's region below. Returns the region's node in the tree: a copy of
-- `region` (Node:consume), which isn't used after.
local function attach(region)
  -- sizes as they are now: a node that just went away (the panel, hidden) may
  -- still have left its sibling the size it had
  core.root_view.root_node:update_layout()
  -- a new node focuses its EmptyView: the focus goes back, so it's what
  -- core.last_active_view is once the panel's first view is focused
  local active = core.active_view
  local root = core.root_view:get_unlocked_root()
  local area_h = root.size.y
  local node = root:split("down")
  node:consume(region)
  root.get_divider_size, root.get_divider_color = divider_size, divider_color
  if area_h > 0 and panel.height then
    root.divider = 1 - common.clamp(panel.height, area_h * 0.1, area_h * 0.9) / area_h
  else
    root.divider = hidden_divider or 2 / 3
  end
  core.set_active_view(active)
  return node
end

-- a new panel, empty; the focus stays (a new node focuses its EmptyView)
local function create()
  local active = core.active_view
  local region = Node()
  core.set_active_view(active)
  panel.init_leaf(region)
  return attach(region)
end

---Whether a view is in the panel (shown or hidden).
---@param view core.view
---@return boolean
function panel.contains(view)
  local node = core.root_view.root_node:get_node_for_view(view)
  if node then return node.is_panel == true end
  return hidden ~= nil and hidden:get_node_for_view(view) ~= nil
end

---Shows a view and makes it active: brought to the front where it is, if it's
---in a node (the panel's or one it was dragged to); else added to the panel
---(its leaf used last), which is made if needed. Shows the panel as hide() left
---it if it's hidden.
---@param view core.view
---@param opts? { focus?: boolean } focus: false leaves the focus where it is
function panel.show(view, opts)
  local active = core.active_view
  if hidden then
    attach(hidden)
    hidden = nil
  end
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if not node then
    node = last_used_leaf(panel.get_region() or create())
    node:add_view(view)
  end
  node:set_active_view(view)
  if opts and opts.focus == false and active then core.set_active_view(active) end
end

---Takes a view out of its node without closing it (a build or shell keeps
---running), e.g. to show it again later.
---@param view core.view
function panel.remove(view)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if node then
    node:remove_view(root, view)
  else
    node = hidden and hidden:get_node_for_view(view)
    if node == hidden and #node.views == 1 then
      hidden = nil
    elseif node then
      -- the hidden region has no focus to move
      local active, last_active = core.active_view, core.last_active_view
      node:remove_view(hidden, view)
      core.set_active_view(active)
      core.last_active_view = last_active
    end
  end
end

---Whether the panel is shown.
---@return boolean
function panel.is_shown()
  return panel.get_region() ~= nil
end

---Takes the panel out as it is, without closing its views, until the next
---show(); the focus goes to the editor area if it was in the panel.
function panel.hide()
  local region = panel.get_region()
  if not region then return end
  local root = core.root_view.root_node
  local had_focus = region:get_node_for_view(core.active_view) ~= nil
  local split = region:get_parent_node(root)
  if region.size.y > 0 then panel.height = region.size.y end
  hidden_divider = region.size.y <= 0 and split.divider or nil
  split:consume(split.a == region and split.b or split.a)
  -- kept if it has tabs
  local views = region:get_children()
  for _, view in ipairs(views) do view:on_mouse_left() end
  for _, view in ipairs(views) do
    if not view:is(EmptyView) then hidden = region break end
  end
  if had_focus then
    core.set_active_view(core.root_view:get_last_used_node().active_view)
  end
end

---Whether the panel is hidden: hide() took it out, and the next show() brings
---it back.
---@return boolean
function panel.has_hidden()
  return hidden ~= nil
end

---Hides the panel, or shows it again as hide() left it; with nothing to
---show, shows it empty (for tabs dragged to it), the focus staying.
---@param opts? { focus?: boolean } as for show()
function panel.toggle(opts)
  if panel.is_shown() then
    panel.hide()
  elseif hidden then
    panel.show(last_used_leaf(hidden).active_view, opts)
  else
    create()
  end
end

---Moves a view from wherever it is into the panel.
---@param view core.view
function panel.move_to_panel(view)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if node then node:remove_view(root, view) end
  panel.show(view)
end

---Moves a view from the panel into the editor node used last.
---@param view core.view
function panel.move_to_editor(view)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if node then node:remove_view(root, view) end
  reusable.keep(view)
  -- only now: removing the panel's last view replaces its sibling's node
  core.root_view:get_last_used_node():add_view(view)
end

return panel
