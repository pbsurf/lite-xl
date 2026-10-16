local core = require "core"
local common = require "core.common"
local style = require "core.style"
local Node = require "core.node"
local View = require "core.view"
local DocView = require "core.docview"
local ContextMenu = require "core.contextmenu"
local command = require "core.command"
local keymap = require "core.keymap"

---@class core.rootview : core.view
---@field super core.view
---@field root_node core.node
---@field mouse core.view.position
---@field tab_menu core.rootview.tabmenu
local RootView = View:extend()

---The context menu of a tab.
---@class core.rootview.tabmenu : core.contextmenu
---@field node core.node? The node of the tab it was opened on
---@field view core.view? The tab's view
local TabMenu = ContextMenu:extend()

---Seconds the mouse rests on a tab before its tooltip shows.
local TAB_TOOLTIP_DELAY = 0.5

function RootView:__tostring() return "RootView" end

function RootView:new()
  RootView.super.new(self)
  self.root_node = Node()
  self.deferred_draws = {}
  self.mouse = { x = 0, y = 0 }
  self.drag_overlay = { x = 0, y = 0, w = 0, h = 0, visible = false, opacity = 0,
                        base_color = style.drag_overlay,
                        color = { table.unpack(style.drag_overlay) } }
  self.drag_overlay.to = { x = 0, y = 0, w = 0, h = 0 }
  self.drag_overlay_tab = { x = 0, y = 0, w = 0, h = 0, visible = false, opacity = 0,
                            base_color = style.drag_overlay_tab,
                            color = { table.unpack(style.drag_overlay_tab) } }
  self.drag_overlay_tab.to = { x = 0, y = 0, w = 0, h = 0 }
  self.first_dnd_processed = false
  self.tab_menu = TabMenu()
  -- the tab under the mouse and since when; dismissed by a click until it changes
  self.tab_tooltip = { view = nil, node = nil, time = 0, dismissed = false }
end


function RootView:defer_draw(fn, ...)
  table.insert(self.deferred_draws, 1, { fn = fn, ... })
end


---@return core.node
function RootView:get_active_node()
  local node = self.root_node:get_node_for_view(core.active_view)
  if not node then node = self:get_primary_node() end
  return node
end


---@return core.node
local function get_primary_node(node)
  if node.is_primary_node then
    return node
  end
  if node.type ~= "leaf" then
    return get_primary_node(node.a) or get_primary_node(node.b)
  end
end


---@return core.node
function RootView:get_active_node_default()
  local node = self.root_node:get_node_for_view(core.active_view)
  if not node then node = self:get_primary_node() end
  if node.locked then
    local default_view = self:get_primary_node().views[1]
    assert(default_view, "internal error: cannot find original document node.")
    core.set_active_view(default_view)
    node = self:get_active_node()
  end
  return node
end


---@return core.node
function RootView:get_primary_node()
  return get_primary_node(self.root_node)
end


---@param node core.node
---@return core.node
local function select_next_primary_node(node)
  if node.is_primary_node then return end
  if node.type ~= "leaf" then
    return select_next_primary_node(node.a) or select_next_primary_node(node.b)
  else
    local lx, ly = node:get_locked_size()
    if not lx and not ly then
      return node
    end
  end
end


---@return core.node
function RootView:select_next_primary_node()
  return select_next_primary_node(self.root_node)
end


---@param doc core.doc
---@return core.docview
function RootView:open_doc(doc)
  local node = self:get_active_node_default()
  for i, view in ipairs(node.views) do
    if view.doc == doc then
      node:set_active_view(node.views[i])
      return view
    end
  end
  local view = DocView(doc)
  node:add_view(view)
  self.root_node:update_layout()
  view:scroll_to_line(view.doc:get_selection(), true, true)
  return view
end


---@param keep_active boolean
function RootView:close_all_docviews(keep_active)
  self.root_node:close_all_docviews(keep_active)
end


---Function to intercept mouse pressed events on the active view.
---Do nothing by default.
---@param button core.view.mousebutton
---@param x number
---@param y number
---@param clicks integer
function RootView.on_view_mouse_pressed(button, x, y, clicks)
end


---@param button core.view.mousebutton
---@param x number
---@param y number
---@param clicks integer
---@return boolean
function RootView:on_mouse_pressed(button, x, y, clicks)
  self.tab_tooltip.dismissed = true
  -- the tab menu gets clicks first while shown: a click anywhere closes it,
  -- choosing the row under the mouse, if any
  local menu = self.tab_menu
  if menu.show_context_menu then
    local mx, my = menu.position.x, menu.position.y
    if x < mx or x >= mx + menu.items.width or y < my or y >= my + menu.items.height then
      menu.selected = -1
    end
    return menu:on_mouse_pressed(button, x, y, clicks)
  end
  local div = self.root_node:get_divider_overlapping_point(x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  if div and (node and not node.active_view:scrollbar_overlaps_point(x, y)) then
    self.dragged_divider = div
    return true
  end
  if node.hovered_tab_button > 0 then
    node:click_tab_button(node.hovered_tab_button)
    return true
  end
  local idx = node:get_tab_overlapping_point(x, y)
  if idx then
    if button == "middle" or node.hovered_close == idx then
      node:close_view(self.root_node, node.views[idx])
      return true
    elseif button == "right" then
      self:show_tab_menu(node, node.views[idx], x, y)
      return true
    else
      if button == "left" then
        self.dragged_node = { node = node, idx = idx, dragging = false, drag_start_x = x, drag_start_y = y}
      end
      node:set_active_view(node.views[idx])
      return true
    end
  elseif not self.dragged_node then -- avoid sending on_mouse_pressed events when dragging tabs
    core.set_active_view(node.active_view)
    return self.on_view_mouse_pressed(button, x, y, clicks) or node.active_view:on_mouse_pressed(button, x, y, clicks)
  end
end


function RootView:get_overlay_base_color(overlay)
  if overlay == self.drag_overlay then
    return style.drag_overlay
  else
    return style.drag_overlay_tab
  end
end


function RootView:set_show_overlay(overlay, status)
  overlay.visible = status
  if status then -- reset colors
    -- reload base_color
    overlay.base_color = self:get_overlay_base_color(overlay)
    overlay.color[1] = overlay.base_color[1]
    overlay.color[2] = overlay.base_color[2]
    overlay.color[3] = overlay.base_color[3]
    overlay.color[4] = overlay.base_color[4]
    overlay.opacity = 0
  end
end


---@param button core.view.mousebutton
---@param x number
---@param y number
function RootView:on_mouse_released(button, x, y, ...)
  if self.dragged_divider then
    self.dragged_divider = nil
  end
  if self.dragged_node then
    if button == "left" then
      if self.dragged_node.dragging then
        local node = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
        local dragged_node = self.dragged_node.node

        if node and not node.locked
           -- don't do anything if dragging onto own node, with only one view
           and (node ~= dragged_node or #node.views > 1) then
          local split_type = node:get_split_type(self.mouse.x, self.mouse.y)
          local view = dragged_node.views[self.dragged_node.idx]

          if split_type ~= "middle" and split_type ~= "tab" then -- needs splitting
            local new_node = node:split(split_type)
            self.root_node:get_node_for_view(view):remove_view(self.root_node, view)
            new_node:add_view(view)
          elseif split_type == "middle" and node ~= dragged_node then -- move to other node
            dragged_node:remove_view(self.root_node, view)
            node:add_view(view)
            self.root_node:get_node_for_view(view):set_active_view(view)
          elseif split_type == "tab" then -- move besides other tabs
            local tab_index = node:get_drag_overlay_tab_position(self.mouse.x, self.mouse.y, dragged_node, self.dragged_node.idx)
            dragged_node:remove_view(self.root_node, view)
            node:add_view(view, tab_index)
            self.root_node:get_node_for_view(view):set_active_view(view)
          end
          self.root_node:update_layout()
          core.redraw = true
        end
      end
      self:set_show_overlay(self.drag_overlay, false)
      self:set_show_overlay(self.drag_overlay_tab, false)
      if self.dragged_node and self.dragged_node.dragging then
        core.request_cursor("arrow")
      end
      self.dragged_node = nil
    end
  else -- avoid sending on_mouse_released events when dragging tabs
    self.root_node:on_mouse_released(button, x, y, ...)
  end
end


local function resize_child_node(node, axis, value, delta)
  local accept_resize = node.a:resize(axis, value)
  if not accept_resize then
    accept_resize = node.b:resize(axis, node.size[axis] - value)
  end
  if not accept_resize then
    node.divider = node.divider + delta / node.size[axis]
  end
end


---@param x number
---@param y number
---@param dx number
---@param dy number
function RootView:on_mouse_moved(x, y, dx, dy)
  -- the system can move the pointer along with a finger (VMware does)
  if self.touch then return end
  if core.active_view == core.nag_view then
    core.request_cursor("arrow")
    core.active_view:on_mouse_moved(x, y, dx, dy)
    return
  end

  if self.dragged_divider then
    local node = self.dragged_divider
    if node.type == "hsplit" then
      x = common.clamp(x - node.position.x, 0, self.root_node.size.x * 0.95)
      resize_child_node(node, "x", x, dx)
    elseif node.type == "vsplit" then
      y = common.clamp(y - node.position.y, 0, self.root_node.size.y * 0.95)
      resize_child_node(node, "y", y, dy)
    end
    node.divider = common.clamp(node.divider, 0.01, 0.99)
    return
  end

  self.mouse.x, self.mouse.y = x, y
  if self.tab_menu:on_mouse_moved(x, y) then return end

  local dn = self.dragged_node
  if dn and not dn.dragging then
    -- start dragging only after enough movement
    dn.dragging = common.distance(x, y, dn.drag_start_x, dn.drag_start_y) > style.tab_width * .05
    if dn.dragging then
      core.request_cursor("hand")
    end
  end

  -- avoid sending on_mouse_moved events when dragging tabs
  if dn then return end

  self.root_node:on_mouse_moved(x, y, dx, dy)

  local last_overlapping_node = self.overlapping_node
  self.overlapping_node = self.root_node:get_child_overlapping_point(x, y)

  if last_overlapping_node and last_overlapping_node ~= self.overlapping_node then
    last_overlapping_node:on_mouse_left()
  end

  local div = self.root_node:get_divider_overlapping_point(x, y)
  local tab_index = self.overlapping_node and self.overlapping_node:get_tab_overlapping_point(x, y)
  if self.overlapping_node and self.overlapping_node:get_tab_button_index(x, y) then
    core.request_cursor("arrow")
  elseif div and (self.overlapping_node and not self.overlapping_node.active_view:scrollbar_overlaps_point(x, y)) then
    core.request_cursor(div.type == "hsplit" and "sizeh" or "sizev")
  elseif tab_index then
    core.request_cursor("arrow")
  elseif self.overlapping_node then
    core.request_cursor(self.overlapping_node.active_view.cursor)
  end
end


function RootView:on_mouse_left()
  if self.overlapping_node then
    self.overlapping_node:on_mouse_left()
  end
end


---@param filename string
---@param x number
---@param y number
---@return boolean
function RootView:on_file_dropped(filename, x, y)
  local node = self.root_node:get_child_overlapping_point(x, y)
  local result = node and node.active_view:on_file_dropped(filename, x, y)
  if result then return result end
  local info = system.get_file_info(filename)
  if info and info.type == "dir" then
    if self.first_dnd_processed then
      -- first update done, open in new window
      system.exec(string.format("%q %q", EXEFILE, filename))
    else
      -- DND event before first update, this is sent by macOS when folder is dropped into the dock
      core.confirm_close_docs(core.docs, function(dirpath)
        core.open_folder_project(dirpath)
      end, system.absolute_path(filename))
      self.first_dnd_processed = true
    end
  else
    local ok, doc = core.try(core.open_doc, filename)
    if ok then
      local node = core.root_view.root_node:get_child_overlapping_point(x, y)
      node:set_active_view(node.active_view)
      core.root_view:open_doc(doc)
    end
  end
  return true
end


-- Touch, one finger at a time (others are ignored): a tap clicks, as the left
-- mouse button (quick taps in one place count as double and triple clicks); a
-- drag scrolls what's under the finger, a tab bar's tabs or the view, locked to
-- one axis when it starts mostly along it.
local TOUCH_DRAG_DISTANCE = 8   -- moving less than this (scaled) is still a tap
local TAP_INTERVAL = 0.4        -- seconds between taps of a double tap

function RootView:on_touch_pressed(x, y, id)
  if self.touch then return end
  self.touch = { id = id, x = x, y = y }
  -- no hover effects from touch (a tap's click moves the mouse there itself)
  self.root_node:on_mouse_left()
end


local function start_touch_scroll(self, t, x, y)
  t.scrolling = true
  t.node = self.root_node:get_child_overlapping_point(t.x, t.y)
  t.on_tabs = t.node:tab_bar_overlaps_point(t.x, t.y)
  local dx, dy = math.abs(x - t.x), math.abs(y - t.y)
  t.lock_x = t.on_tabs or dx > dy * 2   -- horizontal only
  t.lock_y = not t.on_tabs and dy > dx * 2
end


function RootView:on_touch_moved(x, y, dx, dy, id)
  local t = self.touch
  if not t or t.id ~= id then return end
  if not t.scrolling then
    if common.distance(x, y, t.x, t.y) < TOUCH_DRAG_DISTANCE * SCALE then return end
    start_touch_scroll(self, t, x, y)
    dx, dy = x - t.x, y - t.y   -- include the movement before it counted as a drag
  end
  if t.lock_y then dx = 0 end
  if t.lock_x then dy = 0 end
  local node = t.node
  if t.on_tabs then
    node:scroll_tabs_freely(-dx / node.tab_width)
    node.tab_shift = node.tab_scroll * node.tab_width   -- follow the finger, no animation
  else
    local view = node.active_view
    view.scroll.to.x = view.scroll.to.x - dx
    view.scroll.to.y = view.scroll.to.y - dy
    view:clamp_scroll_position()
    view.scroll.x, view.scroll.y = view.scroll.to.x, view.scroll.to.y
  end
  core.redraw = true
end


function RootView:on_touch_released(x, y, id)
  local t = self.touch
  if not t or t.id ~= id then return end
  self.touch = nil
  if t.scrolling then return end
  local now, last = system.get_time(), self.last_tap
  local clicks = 1
  if last and now - last.time < TAP_INTERVAL
     and common.distance(x, y, last.x, last.y) < TOUCH_DRAG_DISTANCE * SCALE then
    clicks = last.clicks % 3 + 1
  end
  self.last_tap = { time = now, x = x, y = y, clicks = clicks }
  -- through core.on_event, so it goes where a real click would (keymap included)
  core.on_event("mousemoved", x, y, 0, 0)
  core.on_event("mousepressed", "left", x, y, clicks)
  core.on_event("mousereleased", "left", x, y)
end


function RootView:on_mouse_wheel(dy, dx)
  local x, y = self.mouse.x, self.mouse.y
  local node = self.root_node:get_child_overlapping_point(x, y)
  -- over a tab bar: one notch scrolls one tab if its tabs scroll, else nothing
  if node:tab_bar_overlaps_point(x, y) then
    if node:tabs_overflow() then node:scroll_tabs_freely(-(dy + (dx or 0))) end
    return true
  end
  return node.active_view:on_mouse_wheel(dy, dx)
end


function RootView:on_text_input(...)
  core.active_view:on_text_input(...)
end

function RootView:on_ime_text_editing(...)
  core.active_view:on_ime_text_editing(...)
end

function RootView:on_focus_lost(...)
  -- We force a redraw so documents can redraw without the cursor.
  core.redraw = true
end


function RootView:interpolate_drag_overlay(overlay)
  self:move_towards(overlay, "x", overlay.to.x, nil, "tab_drag")
  self:move_towards(overlay, "y", overlay.to.y, nil, "tab_drag")
  self:move_towards(overlay, "w", overlay.to.w, nil, "tab_drag")
  self:move_towards(overlay, "h", overlay.to.h, nil, "tab_drag")

  self:move_towards(overlay, "opacity", overlay.visible and 100 or 0, nil, "tab_drag")
  overlay.color[4] = overlay.base_color[4] * overlay.opacity / 100
end


function RootView:update()
  Node.copy_position_and_size(self.root_node, self)
  self.root_node:update()
  self.root_node:update_layout()

  self:update_drag_overlay()
  self:interpolate_drag_overlay(self.drag_overlay)
  self:interpolate_drag_overlay(self.drag_overlay_tab)
  -- set this to true because at this point there are no dnd requests
  -- that are caused by the initial dnd into dock user action
  self.first_dnd_processed = true
  self:update_tab_tooltip()
  self.tab_menu:update()
end


function RootView:set_drag_overlay(overlay, x, y, w, h, immediate)
  overlay.to.x = x
  overlay.to.y = y
  overlay.to.w = w
  overlay.to.h = h
  if immediate then
    overlay.x = x
    overlay.y = y
    overlay.w = w
    overlay.h = h
  end
  if not overlay.visible then
    self:set_show_overlay(overlay, true)
  end
end


local function get_split_sizes(split_type, x, y, w, h)
  if split_type == "left" then
    w = w * .5
  elseif split_type == "right" then
    x = x + w * .5
    w = w * .5
  elseif split_type == "up" then
    h = h * .5
  elseif split_type == "down" then
    y = y + h * .5
    h = h * .5
  end
  return x, y, w, h
end


function RootView:update_drag_overlay()
  if not (self.dragged_node and self.dragged_node.dragging) then return end
  local over = self.root_node:get_child_overlapping_point(self.mouse.x, self.mouse.y)
  if over and not over.locked then
    local tab_h = over:get_tab_bar_height()
    local x, y = over.position.x, over.position.y
    local w, h = over.size.x, over.size.y
    local split_type = over:get_split_type(self.mouse.x, self.mouse.y)

    if split_type == "tab" and (over ~= self.dragged_node.node or #over.views > 1) then
      local tab_index, tab_x, tab_y, tab_w, tab_h = over:get_drag_overlay_tab_position(self.mouse.x, self.mouse.y)
      self:set_drag_overlay(self.drag_overlay_tab,
        tab_x + (tab_index and 0 or tab_w), tab_y,
        style.caret_width, tab_h,
        -- avoid showing tab overlay moving between nodes
        over ~= self.drag_overlay_tab.last_over)
      self:set_show_overlay(self.drag_overlay, false)
      self.drag_overlay_tab.last_over = over
    else
      if (over ~= self.dragged_node.node or #over.views > 1) then
        y = y + tab_h
        h = h - tab_h
        x, y, w, h = get_split_sizes(split_type, x, y, w, h)
      end
      self:set_drag_overlay(self.drag_overlay, x, y, w, h)
      self:set_show_overlay(self.drag_overlay_tab, false)
    end
  else
    self:set_show_overlay(self.drag_overlay, false)
    self:set_show_overlay(self.drag_overlay_tab, false)
  end
end


function RootView:draw_grabbed_tab()
  local dn = self.dragged_node
  local _,_, w, h = dn.node:get_tab_rect(dn.idx)
  local x = self.mouse.x - w / 2
  local y = self.mouse.y - h / 2
  local view = dn.node.views[dn.idx]
  self.root_node:draw_tab(view, true, true, false, x, y, w, h, true)
end


function RootView:draw_drag_overlay(ov)
  if ov.opacity > 0 then
    renderer.draw_rect(ov.x, ov.y, ov.w, ov.h, ov.color)
  end
end


function RootView:draw()
  self.root_node:draw()
  self:draw_tab_tooltip()
  self.tab_menu:draw()
  while #self.deferred_draws > 0 do
    local t = table.remove(self.deferred_draws)
    t.fn(table.unpack(t))
  end

  self:draw_drag_overlay(self.drag_overlay)
  self:draw_drag_overlay(self.drag_overlay_tab)
  if self.dragged_node and self.dragged_node.dragging then
    self:draw_grabbed_tab()
  end
  if core.cursor_change_req then
    system.set_cursor(core.cursor_change_req)
    core.cursor_change_req = nil
  end
end


-- Tab tooltips: a view's get_filename() (a doc's full path), when it says more
-- than the tab's title, shown once the mouse rests on its tab for a moment

function RootView:update_tab_tooltip()
  local node = self.overlapping_node
  local view = node and node.hovered_tab and node.views[node.hovered_tab]
  if self.dragged_node or self.tab_menu.show_context_menu then view = nil end
  local tt = self.tab_tooltip
  if view ~= tt.view then
    tt.view, tt.node, tt.dismissed = view, node, false
    tt.time = system.get_time()
    if view then
      core.add_thread(function()
        coroutine.yield(TAB_TOOLTIP_DELAY)
        core.redraw = true
      end)
    end
  end
end


---The tooltip's text and, for a file in a project directory, that directory's
---part of it (drawn dimmed, so files outside the project stand out).
---@param view core.view
---@return string? text, string? project_part
local function get_tab_tooltip(view)
  local text = view.get_filename and view:get_filename()
  if not text or text == "" or text == view:get_name() then return end
  local abs = view.doc and view.doc.abs_filename
  for _, dir in ipairs(core.project_directories) do
    if abs and common.path_belongs_to(abs, dir.name) then
      local part = common.home_encode(dir.name) .. PATHSEP
      if text:sub(1, #part) == part then return text, part end
    end
  end
  return text
end


function RootView:draw_tab_tooltip()
  local tt = self.tab_tooltip
  if not tt.view or tt.dismissed or system.get_time() - tt.time < TAB_TOOLTIP_DELAY then
    return
  end
  local idx = tt.node:get_view_idx(tt.view)
  local text, project_part = get_tab_tooltip(tt.view)
  if not (idx and text) then return end
  local tx, ty, _, th = tt.node:get_tab_rect(idx)
  self:defer_draw(function()
    local font = style.font
    local w = font:get_width(text) + style.padding.x * 2
    local h = font:get_height() + style.padding.y
    local x = common.clamp(math.max(tx, tt.node.position.x), 0, self.size.x - w - 1)
    local y = ty + th + 1
    local bw = style.divider_size
    renderer.draw_rect(x - bw, y - bw, w + bw * 2, h + bw * 2, style.popup_border)
    renderer.draw_rect(x, y, w, h, style.popup_background)
    local tx = x + style.padding.x
    local ty = y + (h - font:get_height()) / 2
    if project_part then
      tx = renderer.draw_text(font, project_part, tx, ty, common.lerp(style.text, style.dim, 0.5))
      text = text:sub(#project_part + 1)
    end
    renderer.draw_text(font, text, tx, ty, style.text)
  end)
end


-- Tab context menu

---Closes a node's views, after one confirmation for those with unsaved changes.
---@param node core.node
---@param views core.view[]
local function close_views(node, views)
  local closing = {}
  for _, view in ipairs(views) do closing[view] = true end
  local docs, seen = {}, {}
  for _, view in ipairs(views) do
    local doc = view.doc
    if doc and not seen[doc] then
      seen[doc] = true
      -- no need to ask about a doc that stays open in another view
      local kept = false
      for _, other in ipairs(core.get_views_referencing_doc(doc)) do
        if not closing[other] then kept = true end
      end
      if not kept then table.insert(docs, doc) end
    end
  end
  core.confirm_close_docs(docs, function()
    for _, view in ipairs(views) do
      if node:get_view_idx(view) then node:remove_view(core.root_view.root_node, view) end
    end
  end)
end

local function has_file(_, view)
  return view.doc and view.doc.abs_filename
end

---Rows of the tab context menu: `core.contextmenu` items (or `ContextMenu.DIVIDER`)
---whose `command` is called with the tab's node and view, listed if their
---optional `show(node, view)` returns true. Plugins may add rows.
RootView.tab_menu_items = {
  { text = "Close", command = function(node, view)
      node:close_view(core.root_view.root_node, view)
    end },
  { text = "Close Others",
    show = function(node) return #node.views > 1 end,
    command = function(node, view)
      local views = {}
      for _, v in ipairs(node.views) do
        if v ~= view then table.insert(views, v) end
      end
      close_views(node, views)
    end },
  { text = "Close to the Right",
    show = function(node, view) return node:get_view_idx(view) < #node.views end,
    command = function(node, view)
      close_views(node, { table.unpack(node.views, node:get_view_idx(view) + 1) })
    end },
  { text = "Close All",
    show = function(node) return #node.views > 1 end,
    command = function(node)
      close_views(node, { table.unpack(node.views) })
    end },
  ContextMenu.DIVIDER,
  { text = "Copy Path", show = has_file,
    command = function(_, view) system.set_clipboard(view.doc.abs_filename) end },
  { text = "Copy Relative Path",
    show = function(_, view)
      return has_file(nil, view) and not common.is_absolute_path(view.doc.filename)
    end,
    command = function(_, view) system.set_clipboard(view.doc.filename) end },
}


---Shows the context menu of a tab at x, y.
---@param node core.node
---@param view core.view
---@param x number
---@param y number
function RootView:show_tab_menu(node, view, x, y)
  local rows = {}
  for _, item in ipairs(RootView.tab_menu_items) do
    if item == ContextMenu.DIVIDER then
      -- no leading or doubled dividers
      if #rows > 0 and rows[#rows] ~= ContextMenu.DIVIDER then table.insert(rows, item) end
    elseif not item.show or item.show(node, view) then
      table.insert(rows, setmetatable({
        command = function() item.command(node, view) end
      }, { __index = item }))
    end
  end
  if rows[#rows] == ContextMenu.DIVIDER then table.remove(rows) end
  local menu = self.tab_menu
  menu.itemset = {}
  menu:register(nil, rows)
  if menu:show(x, y) then
    menu.node, menu.view = node, view
  end
end


function TabMenu:hide()
  TabMenu.super.hide(self)
  if self.view then
    self.node, self.view = nil, nil
    -- the moves the menu took left the hover state where it was opened
    local root = core.root_view
    root:on_mouse_moved(root.mouse.x, root.mouse.y, 0, 0)
  end
end


command.add(function()
    return core.root_view and core.root_view.tab_menu.show_context_menu == true,
      core.root_view and core.root_view.tab_menu
  end, {
  ["root:tab-menu-previous"] = function(menu) menu:focus_previous() end,
  ["root:tab-menu-next"] = function(menu) menu:focus_next() end,
  ["root:tab-menu-hide"] = function(menu) menu:hide() end,
  ["root:tab-menu-select"] = function(menu) menu:call_selected_item() end,
})

keymap.add {
  ["up"] = "root:tab-menu-previous",
  ["down"] = "root:tab-menu-next",
  ["escape"] = "root:tab-menu-hide",
  ["return"] = "root:tab-menu-select",
}

return RootView
