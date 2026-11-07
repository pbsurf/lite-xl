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
---primary node. The workspace saves it, with the views that can be restored, and
---restores it hidden. The divider above it is thicker than an editor split's, in
---a muted accent color (style.panel_divider_size, style.panel_divider), telling
---the two apart.
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

local function get_leaves(node, t)
  t = t or {}
  if node.type == "leaf" then
    table.insert(t, node)
  else
    get_leaves(node.a, t)
    get_leaves(node.b, t)
  end
  return t
end

-- the region's leaf whose active view was visited last: where views are added
local function last_used_leaf(region)
  local best, best_visit
  for _, node in ipairs(get_leaves(region)) do
    local visit = node.active_view and core.view_visit_order[node.active_view]
    if not best or (visit and (not best_visit or visit > best_visit)) then
      best, best_visit = node, visit
    end
  end
  return best
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

---The region hide() took out, nil if none.
---@return core.node?
function panel.get_hidden()
  return hidden
end

---The panel's height: as it is, or as it was last shown.
---@return number?
function panel.get_height()
  local region = panel.get_region()
  if region and region.size.y > 0 then return region.size.y end
  return panel.height
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

local function init_leaf(node)
  node.is_panel = true
  node.on_collapse = on_collapse
  node.fit_tab_width, node.max_tab_width = true, 640
end

-- a panel leaf's split makes another
local node_split = Node.split
function Node:split(...)
  local is_panel = self.is_panel
  local node = node_split(self, ...)
  if is_panel then init_leaf(node) end
  return node
end

---A new, empty panel leaf, not shown: the workspace restores the panel into it
---(splitting it), and gives it to restore().
---@return core.node
function panel.new_region()
  local node = Node()
  init_leaf(node)
  return node
end

-- A split of the editor area (the unlocked root): the editor area above, the
-- panel's region below
local function attach(region)
  -- sizes as they are now: a node that just went away (the panel, hidden) may
  -- still have left its sibling the size it had
  core.root_view.root_node:update_layout()
  -- a new node focuses its EmptyView: the focus goes back, so it's what
  -- core.last_active_view is once the panel's first view is focused
  local active = core.active_view
  local root = core.root_view:get_unlocked_root()
  local area_h = root.size.y
  local editor = Node()
  editor:consume(root)
  root:consume(Node("vsplit"))
  root.get_divider_size, root.get_divider_color = divider_size, divider_color
  root.a, root.b = editor, region
  if area_h > 0 then
    local h = common.clamp(panel.height or area_h / 3, area_h * 0.1, area_h * 0.9)
    root.divider = 1 - h / area_h
  else
    root.divider = 2 / 3
  end
  core.set_active_view(active)
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
    local region = panel.get_region()
    if not region then
      region = panel.new_region()
      attach(region)
    end
    node = last_used_leaf(region)
    node:add_view(view)
  end
  node:set_active_view(view)
  if opts and opts.focus == false and active then core.set_active_view(active) end
end

-- takes a view out of the hidden region, which has no focus to move
local function take_out_hidden(node, view)
  local idx = node:get_view_idx(view)
  table.remove(node.views, idx)
  node.tab_widths[view] = nil
  if #node.views > 0 then
    if node.active_view == view then
      node.active_view = node:get_most_recent_view() or node.views[math.min(idx, #node.views)]
    end
  elseif node == hidden then
    hidden = nil
  else
    local parent = node:get_parent_node(hidden)
    parent:consume(parent.a == node and parent.b or parent.a)
  end
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
    if node then take_out_hidden(node, view) end
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
  if region.size.y > 0 then panel.height = region.size.y end
  local split = region:get_parent_node(root)
  split:consume(split.a == region and split.b or split.a)
  hidden = region
  for _, node in ipairs(get_leaves(region)) do
    if node.active_view then node.active_view:on_mouse_left() end
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

---Hides the panel, or shows it again as hide() left it.
function panel.toggle()
  if panel.is_shown() then
    panel.hide()
  elseif hidden then
    panel.show(last_used_leaf(hidden).active_view)
  end
end

---Makes a region (from new_region(), restored by the workspace) the panel,
---hidden, unless there's a panel already (shown or hidden).
---@param region core.node
---@param height? number
function panel.restore(region, height)
  if hidden or panel.is_shown() then return end
  -- without the leaves left empty (views that couldn't be restored)
  local function prune(node)
    if node.type == "leaf" then
      init_leaf(node)
      return #node.views > 0 and not node.views[1]:is(EmptyView) and node or nil
    end
    local a, b = prune(node.a), prune(node.b)
    if a and b then
      node.a, node.b = a, b
      return node
    end
    return a or b
  end
  hidden = prune(region)
  panel.height = height or panel.height
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
