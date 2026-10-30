local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Node = require "core.node"
local EmptyView = require "core.emptyview"

---The bottom panel: a split below the editor area holding tool views (search
---results, build output, terminals) as ordinary tabs, which show their status
---in their titles. It's made when a view is shown in it and goes away with its
---last tab, keeping its height for next time. Files don't open in it
---(RootView:get_active_node_default), it never becomes the primary node, and
---the workspace doesn't save it. The divider above it is thicker than an
---editor split's, in a muted accent color (style.panel_divider_size,
---style.panel_divider), telling the two apart.
---
---Each kind of view (its class) can have a current view, which the kind's next
---search or run reuses rather than opening another tab. Its title is italic, as
---a preview tab's is; double-clicking its tab keeps it, and the next one then
---gets a tab of its own. Moving it out of the panel (a drag, "Move to Editor")
---keeps it too, so the next one opens in the panel.
local panel = {}

---The panel's height (pixels) when it last went away; nil until then, for a
---third of the editor area
---@type number?
panel.height = nil

---Each kind's current view
---@type table<core.object, core.view>
local current = {}

---The views hide() took out, in tab order; `active` the one in front
---@type core.view[]
local hidden = {}

---@param node core.node
---@return core.node?
local function find(node)
  if node.type == "leaf" then return node.is_panel and node or nil end
  return find(node.a) or find(node.b)
end

---The panel's node, nil while it's not shown.
---@return core.node?
function panel.get_node()
  return find(core.root_view.root_node)
end

-- the panel's split's divider, as the color scheme is now
local function divider_size()
  return style.panel_divider_size or common.round(3 * SCALE)
end

local function divider_color()
  return style.panel_divider or common.lerp(style.background, style.accent, 0.5)
end

local function on_collapse(node)
  -- not before it's been laid out (made and taken out at once)
  if node.size.y > 0 then panel.height = node.size.y end
end

-- A split of the editor area (the unlocked root): the editor area above, the
-- panel's node below
local function create()
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
  local node = Node()
  node.is_panel = true
  node.on_collapse = on_collapse
  node.fit_tab_width, node.max_tab_width = true, 640
  root.a, root.b = editor, node
  if area_h > 0 then
    local h = common.clamp(panel.height or area_h / 3, area_h * 0.1, area_h * 0.9)
    root.divider = 1 - h / area_h
  else
    root.divider = 2 / 3
  end
  core.set_active_view(active)
  return node
end

local function is_hidden(view)
  for _, v in ipairs(hidden) do
    if v == view then return true end
  end
  return false
end

---Whether a view is in the panel (shown or hidden).
---@param view core.view
---@return boolean
function panel.contains(view)
  local node = core.root_view.root_node:get_node_for_view(view)
  if node then return node.is_panel == true end
  return is_hidden(view)
end

---Shows a view and makes it active: brought to the front where it is, if it's
---in a node (the panel's or one it was dragged to); else added to the panel,
---which is made if needed, along with the views hide() took out.
---@param view core.view
---@param opts? { focus?: boolean } focus: false leaves the focus where it is
function panel.show(view, opts)
  local active = core.active_view
  local node = core.root_view.root_node:get_node_for_view(view)
  if not node then
    node = panel.get_node()
    if not node then
      node = create()
      for _, v in ipairs(hidden) do node:add_view(v) end
      hidden = {}
    end
    if not node:get_view_idx(view) then node:add_view(view) end
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
  if node then node:remove_view(root, view) end
  for i, v in ipairs(hidden) do
    if v == view then table.remove(hidden, i) break end
  end
end

---Whether the panel is shown.
---@return boolean
function panel.is_shown()
  return panel.get_node() ~= nil
end

---Takes all the panel's views out, without closing them, until the next
---show(); the focus goes to the editor area if it was in the panel.
function panel.hide()
  local node = panel.get_node()
  if not node then return end
  local root = core.root_view.root_node
  local had_focus = root:get_node_for_view(core.active_view) == node
  local views = {}
  for _, v in ipairs(node.views) do
    if not v:is(EmptyView) then table.insert(views, v) end
  end
  views.active = node.active_view
  for _, v in ipairs(views) do node:remove_view(root, v) end
  hidden = views
  if had_focus then
    core.set_active_view(core.root_view:get_last_used_node().active_view)
  end
end

---Whether hide() took views out that the next show() brings back.
---@return boolean
function panel.has_hidden()
  return #hidden > 0
end

---Hides the panel, or shows it again as hide() left it.
function panel.toggle()
  if panel.is_shown() then
    panel.hide()
  elseif #hidden > 0 then
    panel.show(hidden.active or hidden[1])
  end
end

---A kind's current view, if it's still open (in a node, or hidden).
---@param kind core.object A view class
---@return core.view?
function panel.current(kind)
  local view = current[kind]
  if view and (core.root_view.root_node:get_node_for_view(view) or is_hidden(view)) then
    return view
  end
  current[kind] = nil
end

---Makes a view its kind's current view, in place of the one before.
---@param view core.view
function panel.set_current(view)
  local kind = getmetatable(view)
  local old = current[kind]
  if old and old ~= view then old.reusable = nil end
  current[kind] = view
  view.reusable = true
end

---Keeps a current view: the kind's next one gets a tab of its own.
---@param view core.view
function panel.keep(view)
  view.reusable = nil
  for kind, v in pairs(current) do
    if v == view then current[kind] = nil end
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
  panel.keep(view)
  -- only now: removing the panel's last view replaces its sibling's node
  core.root_view:get_last_used_node():add_view(view)
end

return panel
