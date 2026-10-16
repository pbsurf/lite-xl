local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Object = require "core.object"
local EmptyView = require "core.emptyview"
local View = require "core.view"

---@class core.node : core.object
local Node = Object:extend()

---A button at the right end of the tab bar, shown while the node's tabs scroll.
---@class core.node.tab_button
---@field icon? string Glyph in style.icon_font, drawn centered
---@field draw? fun(node: core.node, x: number, y: number, w: number, h: number, hovered: boolean) Drawing instead of icon
---@field on_click fun(node: core.node, x: number, y: number, w: number, h: number)
---@field active? fun(node: core.node): boolean While false: dim, ignoring clicks
---@field width? fun(node: core.node): number Default: 3 icon widths. Called while
---working out how many tabs fit, so it can't depend on that (get_max_tabs,
---tabs_overflow, get_tab_area_width, target_tab_width, get_visible_tabs_number).

---Tab bar buttons by name; config.tab_buttons chooses which show, in which order.
---@type table<string, core.node.tab_button>
Node.tab_buttons = {}

function Node:__tostring() return "Node" end

function Node:new(type)
  self.type = type or "leaf"
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.views = {}
  self.divider = 0.5
  if self.type == "leaf" then
    self:add_view(EmptyView())
  end
  self.hovered = {x = -1, y = -1 }
  self.hovered_close = 0
  self.hovered_tab_button = 0
  -- tab_scroll: how far the tabs are scrolled, in tabs (fractional while scrolled
  -- freely); tab_shift (pixels) and tab_width animate towards it and target_tab_width()
  self.tab_scroll = 0
  self.tab_shift = 0
  self.tab_width = style.tab_width
  self.move_towards = View.move_towards
end


function Node:propagate(fn, ...)
  self.a[fn](self.a, ...)
  self.b[fn](self.b, ...)
end


function Node:on_mouse_moved(x, y, ...)
  if self.type == "leaf" then
    self.hovered.x, self.hovered.y = x, y
    -- now, not at the next update: a tap moves and clicks in the same frame
    self:tab_hovered_update(x, y)
    self.active_view:on_mouse_moved(x, y, ...)
  else
    self:propagate("on_mouse_moved", x, y, ...)
  end
end


function Node:on_mouse_released(...)
  if self.type == "leaf" then
    self.active_view:on_mouse_released(...)
  else
    self:propagate("on_mouse_released", ...)
  end
end


function Node:on_mouse_left()
  if self.type == "leaf" then
    self.hovered.x, self.hovered.y = -1, -1
    self:tab_hovered_update(-1, -1)
    self.active_view:on_mouse_left()
  else
    self:propagate("on_mouse_left")
  end
end


function Node:consume(node)
  for k, _ in pairs(self) do self[k] = nil end
  for k, v in pairs(node) do self[k] = v   end
end


local type_map = { up="vsplit", down="vsplit", left="hsplit", right="hsplit" }

-- The "locked" argument below should be in the form {x = <boolean>, y = <boolean>}
-- and it indicates if the node want to have a fixed size along the axis where the
-- boolean is true. If not it will be expanded to take all the available space.
-- The "resizable" flag indicates if, along the "locked" axis the node can be resized
-- by the user. If the node is marked as resizable their view should provide a
-- set_target_size method.
function Node:split(dir, view, locked, resizable)
  assert(self.type == "leaf", "Tried to split non-leaf node")
  local node_type = assert(type_map[dir], "Invalid direction")
  local last_active = core.active_view
  local child = Node()
  child:consume(self)
  self:consume(Node(node_type))
  self.a = child
  self.b = Node()
  if view then self.b:add_view(view) end
  if locked then
    assert(type(locked) == 'table')
    self.b.locked = locked
    self.b.resizable = resizable or false
    core.set_active_view(last_active)
  end
  if dir == "up" or dir == "left" then
    self.a, self.b = self.b, self.a
    return self.a
  end
  return self.b
end

function Node:remove_view(root, view)
  if #self.views > 1 then
    local idx = self:get_view_idx(view)
    if idx <= self.tab_scroll then
      -- a tab left of the view: keep the same tabs in view
      self.tab_scroll = math.max(0, self.tab_scroll - 1)
      self.tab_shift = math.max(0, self.tab_shift - self.tab_width)
    end
    table.remove(self.views, idx)
    if self.active_view == view then
      self:set_active_view(self.views[idx] or self.views[#self.views])
    end
  else
    local parent = self:get_parent_node(root)
    local is_a = (parent.a == self)
    local other = parent[is_a and "b" or "a"]
    local locked_size_x, locked_size_y = other:get_locked_size()
    local locked_size
    if parent.type == "hsplit" then
      locked_size = locked_size_x
    else
      locked_size = locked_size_y
    end
    local next_primary
    if self.is_primary_node then
      next_primary = core.root_view:select_next_primary_node()
    end
    if locked_size or (self.is_primary_node and not next_primary) then
      self.views = {}
      self:add_view(EmptyView())
    else
      if other == next_primary then
        next_primary = parent
      end
      parent:consume(other)
      local p = parent
      while p.type ~= "leaf" do
        p = p[is_a and "a" or "b"]
      end
      p:set_active_view(p.active_view)
      if self.is_primary_node then
        next_primary.is_primary_node = true
      end
    end
  end
  core.last_active_view = nil
end

function Node:close_view(root, view)
  local do_close = function()
    self:remove_view(root, view)
  end
  view:try_close(do_close)
end


function Node:close_active_view(root)
  self:close_view(root, self.active_view)
end


function Node:add_view(view, idx)
  assert(self.type == "leaf", "Tried to add view to non-leaf node")
  assert(not self.locked, "Tried to add view to locked node")
  if self.views[1] and self.views[1]:is(EmptyView) then
    table.remove(self.views)
  end
  table.insert(self.views, idx or (#self.views + 1), view)
  self:set_active_view(view)
end


function Node:set_active_view(view)
  assert(self.type == "leaf", "Tried to set active view on non-leaf node")
  local last_active_view = self.active_view
  self.active_view = view
  core.set_active_view(view)
  if last_active_view and last_active_view ~= view then
    last_active_view:on_mouse_left()
  end
end


function Node:get_view_idx(view)
  for i, v in ipairs(self.views) do
    if v == view then return i end
  end
end


function Node:get_node_for_view(view)
  for _, v in ipairs(self.views) do
    if v == view then return self end
  end
  if self.type ~= "leaf" then
    return self.a:get_node_for_view(view) or self.b:get_node_for_view(view)
  end
end


function Node:get_parent_node(root)
  if root.a == self or root.b == self then
    return root
  elseif root.type ~= "leaf" then
    return self:get_parent_node(root.a) or self:get_parent_node(root.b)
  end
end


function Node:get_children(t)
  t = t or {}
  for _, view in ipairs(self.views) do
    table.insert(t, view)
  end
  if self.a then self.a:get_children(t) end
  if self.b then self.b:get_children(t) end
  return t
end


local function get_tab_button_width(node, button)
  return button.width and button.width(node) or style.icon_font:get_width(">") * 3
end


function Node:get_divider_overlapping_point(px, py)
  if self.type ~= "leaf" then
    local axis = self.type == "hsplit" and "x" or "y"
    if self.a:is_resizable(axis) and self.b:is_resizable(axis) then
      local p = 6
      local x, y, w, h = self:get_divider_rect()
      x, y = x - p, y - p
      w, h = w + p * 2, h + p * 2
      if px > x and py > y and px < x + w and py < y + h then
        return self
      end
    end
    return self.a:get_divider_overlapping_point(px, py)
        or self.b:get_divider_overlapping_point(px, py)
  end
end


---The tab bar buttons config.tab_buttons names, as registered in Node.tab_buttons.
---@return core.node.tab_button[]
function Node:get_tab_buttons()
  local buttons = {}
  for _, name in ipairs(config.tab_buttons) do
    local button = Node.tab_buttons[name]
    if button then table.insert(buttons, button) end
  end
  return buttons
end


---How many tabs the node shows at once: all of them, unless that breaks
---config.max_tabs or config.min_tab_width; then as many as fit beside the buttons.
function Node:get_max_tabs()
  local n = #self.views
  local min_w = config.min_tab_width * SCALE
  local max = config.max_tabs > 0 and config.max_tabs or n
  if n <= max and n * min_w <= self.size.x then return n end
  if min_w > 0 then
    local w = self.size.x - self:get_tab_buttons_width()
    max = math.min(max, math.floor(w / min_w))
  end
  return math.max(1, max)
end


function Node:get_tab_buttons_width()
  local w = 0
  for _, button in ipairs(self:get_tab_buttons()) do
    w = w + get_tab_button_width(self, button)
  end
  return w
end


function Node:tabs_overflow()
  return #self.views > self:get_max_tabs()
end


---The width of the tab bar left for tabs, left of the buttons.
function Node:get_tab_area_width()
  if self:tabs_overflow() then
    return self.size.x - self:get_tab_buttons_width()
  end
  return self.size.x
end


function Node:target_tab_width()
  local n = math.min(#self.views, self:get_max_tabs())
  return math.min(style.tab_width, self:get_tab_area_width() / n)
end


---How many tabs fit in the tab area (can be fractional).
function Node:get_tab_area_tabs()
  return self:get_tab_area_width() / self:target_tab_width()
end


function Node:get_max_tab_scroll()
  return math.max(0, #self.views - self:get_tab_area_tabs())
end


---How many tabs are fully in view, once the tabs have finished scrolling.
function Node:get_visible_tabs_number()
  local first = math.ceil(self.tab_scroll - 1e-6)
  local after_last = math.floor(self.tab_scroll + self:get_tab_area_tabs() + 1e-6)
  return math.max(0, math.min(#self.views, after_last) - first)
end


---The first and last tab at least partly in view, where the tabs are drawn now.
function Node:get_drawn_tabs_range()
  local first = math.floor(self.tab_shift / self.tab_width) + 1
  local last = math.ceil((self.tab_shift + self:get_tab_area_width()) / self.tab_width)
  return math.max(1, first), math.min(#self.views, last)
end


function Node:get_tab_overlapping_point(px, py)
  if not self:should_show_tabs() then return nil end
  local x0, y0 = self.position.x, self.position.y
  if px < x0 or px >= x0 + self:get_tab_area_width()
     or py < y0 or py >= y0 + self:get_tab_bar_height() then
    return nil
  end
  local idx = math.floor((px - x0 + self.tab_shift) / self.tab_width) + 1
  if idx >= 1 and idx <= #self.views then return idx end
end


function Node:should_show_tabs()
  if self.locked then return false end
  local dn = core.root_view.dragged_node
  if #self.views > 1
     or (dn and dn.dragging) then -- show tabs while dragging
    return true
  elseif config.always_show_tabs then
    return not self.views[1]:is(EmptyView)
  end
  return false
end


local function close_button_location(x, w)
  local cw = style.icon_font:get_width("C")
  local pad = style.padding.x / 2
  return x + w - cw - pad, cw, pad
end


---Whether the point is on the node's tab bar (shown).
function Node:tab_bar_overlaps_point(px, py)
  return self:should_show_tabs()
    and px >= self.position.x and px < self.position.x + self.size.x
    and py >= self.position.y and py < self.position.y + self:get_tab_bar_height()
end


function Node:get_tab_button_index(px, py)
  if not self:should_show_tabs() or not self:tabs_overflow() then return end
  for i = 1, #self:get_tab_buttons() do
    local x, y, w, h = self:get_tab_button_rect(i)
    if px >= x and px < x + w and py >= y and py < y + h then
      return i
    end
  end
end


function Node:click_tab_button(i)
  local button = self:get_tab_buttons()[i]
  if button and (not button.active or button.active(self)) then
    button.on_click(self, self:get_tab_button_rect(i))
  end
end


function Node:tab_hovered_update(px, py)
  local tab_index = self:get_tab_overlapping_point(px, py)
  self.hovered_tab = tab_index
  self.hovered_close = 0
  self.hovered_tab_button = 0
  if tab_index then
    local x, y, w, h = self:get_tab_rect(tab_index)
    local cx, cw = close_button_location(x, w)
    if px >= cx and px < cx + cw and py >= y and py < y + h and config.tab_close_button then
      self.hovered_close = tab_index
    end
  else
    self.hovered_tab_button = self:get_tab_button_index(px, py) or 0
  end
end


function Node:get_child_overlapping_point(x, y)
  local child
  if self.type == "leaf" then
    return self
  elseif self.type == "hsplit" then
    child = (x < self.b.position.x) and self.a or self.b
  elseif self.type == "vsplit" then
    child = (y < self.b.position.y) and self.a or self.b
  end
  return child:get_child_overlapping_point(x, y)
end


function Node:get_tab_bar_height()
  return style.font:get_height() + style.padding.y * 2
end


---The i-th of the tab bar buttons, which are right-aligned in the tab bar.
function Node:get_tab_button_rect(i)
  local buttons = self:get_tab_buttons()
  local x = self.position.x + self.size.x
  for j = #buttons, i, -1 do
    x = x - get_tab_button_width(self, buttons[j])
  end
  return x, self.position.y, get_tab_button_width(self, buttons[i]), self:get_tab_bar_height()
end


---The tab's rect where it's drawn now; it can be partly or wholly outside the tab
---area (get_tab_area_width), which drawing clips to.
function Node:get_tab_rect(idx)
  local x = self.position.x + self.tab_width * (idx - 1) - self.tab_shift
  return x, self.position.y, self.tab_width, self:get_tab_bar_height()
end


function Node:get_divider_rect()
  local x, y = self.position.x, self.position.y
  if self.type == "hsplit" then
    return x + self.a.size.x, y, style.divider_size, self.size.y
  elseif self.type == "vsplit" then
    return x, y + self.a.size.y, self.size.x, style.divider_size
  end
end


-- Return two values for x and y axis and each of them is either falsy or a number.
-- A falsy value indicate no fixed size along the corresponding direction.
function Node:get_locked_size()
  if self.type == "leaf" then
    if self.locked then
      local size = self.active_view.size
      -- The values below should be either a falsy value or a number
      local sx = (self.locked and self.locked.x) and size.x
      local sy = (self.locked and self.locked.y) and size.y
      return sx, sy
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    -- The values below should be either a falsy value or a number
    local sx, sy
    if self.type == 'hsplit' then
      if x1 and x2 then
        local dsx = (x1 < 1 or x2 < 1) and 0 or style.divider_size
        sx = x1 + x2 + dsx
      end
      sy = y1 or y2
    else
      if y1 and y2 then
        local dsy = (y1 < 1 or y2 < 1) and 0 or style.divider_size
        sy = y1 + y2 + dsy
      end
      sx = x1 or x2
    end
    return sx, sy
  end
end


function Node.copy_position_and_size(dst, src)
  dst.position.x, dst.position.y = src.position.x, src.position.y
  dst.size.x, dst.size.y = src.size.x, src.size.y
end


-- calculating the sizes is the same for hsplits and vsplits, except the x/y
-- axis are swapped; this function lets us use the same code for both
local function calc_split_sizes(self, x, y, x1, x2, y1, y2)
  local ds = ((x1 and x1 < 1) or (x2 and x2 < 1)) and 0 or style.divider_size
  local n = x1 and x1 + ds or (x2 and self.size[x] - x2 or math.floor(self.size[x] * self.divider))
  self.a.position[x] = self.position[x]
  self.a.position[y] = self.position[y]
  self.a.size[x] = n - ds
  self.a.size[y] = self.size[y]
  self.b.position[x] = self.position[x] + n
  self.b.position[y] = self.position[y]
  self.b.size[x] = self.size[x] - n
  self.b.size[y] = self.size[y]
end


function Node:update_layout()
  if self.type == "leaf" then
    local av = self.active_view
    if self:should_show_tabs() then
      local _, _, _, th = self:get_tab_rect(1)
      av.position.x, av.position.y = self.position.x, self.position.y + th
      av.size.x, av.size.y = self.size.x, self.size.y - th
    else
      Node.copy_position_and_size(av, self)
    end
  else
    local x1, y1 = self.a:get_locked_size()
    local x2, y2 = self.b:get_locked_size()
    if self.type == "hsplit" then
      calc_split_sizes(self, "x", "y", x1, x2)
    elseif self.type == "vsplit" then
      calc_split_sizes(self, "y", "x", y1, y2)
    end
    self.a:update_layout()
    self.b:update_layout()
  end
end


---Scrolls the active tab into view, by as little as needed, unless the tabs were
---scrolled freely (scroll_tabs_freely) since it became active.
function Node:scroll_tabs_to_visible()
  if self.free_scroll_view ~= self.active_view then
    self.free_scroll_view = nil
    local index = self:get_view_idx(self.active_view)
    if index then
      self.tab_scroll = common.clamp(self.tab_scroll, index - self:get_tab_area_tabs(), index - 1)
    end
  end
  self.tab_scroll = common.clamp(self.tab_scroll, 0, self:get_max_tab_scroll())
end


---Scrolls the tabs by n tabs (negative: towards the first; can be fractional)
---without changing the active tab, which can scroll out of view; they follow it
---again once it changes.
function Node:scroll_tabs_freely(n)
  self.tab_scroll = common.clamp(self.tab_scroll + n, 0, self:get_max_tab_scroll())
  self.free_scroll_view = self.active_view
end


---Scrolls the tabs by one tab, to a whole tab at the edge (dir 1: towards the
---first, 2: towards the last), making the nearest tab in view active if the
---active one would go out of view.
function Node:scroll_tabs(dir)
  local first = self.tab_scroll
  first = dir == 1 and math.ceil(first - 1e-6) - 1 or math.floor(first + 1e-6) + 1
  self.tab_scroll = common.clamp(first, 0, self:get_max_tab_scroll())
  local index = self:get_view_idx(self.active_view)
  local first_index = math.ceil(self.tab_scroll - 1e-6) + 1
  local last_index = first_index + self:get_visible_tabs_number() - 1
  if index < first_index then
    self:set_active_view(self.views[first_index])
  elseif index > last_index then
    self:set_active_view(self.views[last_index])
  end
end


function Node:update()
  if self.type == "leaf" then
    self:scroll_tabs_to_visible()
    for _, view in ipairs(self.views) do
      view:update()
    end
    self:tab_hovered_update(self.hovered.x, self.hovered.y)
    local tab_width = self:target_tab_width()
    self:move_towards("tab_shift", self.tab_scroll * tab_width, nil, "tabs")
    self:move_towards("tab_width", tab_width, nil, "tabs")
  else
    self.a:update()
    self.b:update()
  end
end

function Node:draw_tab_title(view, font, is_active, is_hovered, x, y, w, h)
  local text = view and view:get_name() or ""
  local dots_width = font:get_width("…")
  local align = "center"
  if font:get_width(text) > w then
    align = "left"
    for i = 1, #text do
      local reduced_text = text:sub(1, #text - i)
      if font:get_width(reduced_text) + dots_width <= w then
        text = reduced_text .. "…"
        break
      end
    end
  end
  local color = style.dim
  if is_active then color = style.text end
  if is_hovered then color = style.text end
  common.draw_text(font, color, text, align, x, y, w, h)
end

function Node:draw_tab_borders(view, is_active, is_hovered, x, y, w, h, standalone)
  -- Tabs deviders
  local ds = style.divider_size
  local color = style.dim
  local padding_y = style.padding.y
  renderer.draw_rect(x + w, y + padding_y, ds, h - padding_y*2, style.dim)
  if standalone then
    renderer.draw_rect(x-1, y-1, w+2, h+2, style.background2)
  end
  -- Full border
  if is_active then
    color = style.text
    renderer.draw_rect(x, y, w, h, style.background)
    renderer.draw_rect(x + w, y, ds, h, style.divider)
    renderer.draw_rect(x - ds, y, ds, h, style.divider)
  end
  return x + ds, y, w - ds*2, h
end

function Node:draw_tab(view, is_active, is_hovered, is_close_hovered, x, y, w, h, standalone)
  x, y, w, h = self:draw_tab_borders(view, is_active, is_hovered, x, y, w, h, standalone)
  -- Close button
  local cx, cw, cpad = close_button_location(x, w)
  local show_close_button = ((is_active or is_hovered) and not standalone and config.tab_close_button)
  if show_close_button then
    local close_style = is_close_hovered and style.text or style.dim
    common.draw_text(style.icon_font, close_style, "C", nil, cx, y, cw, h)
  end
  -- Title
  x = x + cpad
  w = cx - x
  core.push_clip_rect(x, y, w, h)
  self:draw_tab_title(view, style.font, is_active, is_hovered, x, y, w, h)
  core.pop_clip_rect()
end

function Node:draw_tabs()
  local x, y = self.position.x, self.position.y
  local h = self:get_tab_bar_height()
  local ds = style.divider_size
  local dots_width = style.font:get_width("…")
  core.push_clip_rect(x, y, self.size.x, h)
  renderer.draw_rect(x, y, self.size.x, h, style.background2)
  renderer.draw_rect(x, y + h - ds, self.size.x, ds, style.divider)

  core.push_clip_rect(x, y, self:get_tab_area_width(), h)
  local first, last = self:get_drawn_tabs_range()
  for i = first, last do
    local view = self.views[i]
    local x, y, w, h = self:get_tab_rect(i)
    self:draw_tab(view, view == self.active_view,
                  i == self.hovered_tab, i == self.hovered_close,
                  x, y, w, h)
  end
  core.pop_clip_rect()

  if self:tabs_overflow() then
    for i, button in ipairs(self:get_tab_buttons()) do
      local bx, by, bw, bh = self:get_tab_button_rect(i)
      local hovered = self.hovered_tab_button == i
      if button.draw then
        button.draw(self, bx, by, bw, bh, hovered)
      else
        local active = not button.active or button.active(self)
        local color = not active and style.dim or hovered and style.accent or style.text
        common.draw_text(style.icon_font, color, button.icon, "center", bx, by, bw, bh)
      end
    end
  end

  core.pop_clip_rect()
end


function Node:draw()
  if self.type == "leaf" then
    if self:should_show_tabs() then
      self:draw_tabs()
    end
    local pos, size = self.active_view.position, self.active_view.size
    core.push_clip_rect(pos.x, pos.y, size.x, size.y)
    self.active_view:draw()
    core.pop_clip_rect()
  else
    local x, y, w, h = self:get_divider_rect()
    renderer.draw_rect(x, y, w, h, style.divider)
    self:propagate("draw")
  end
end


function Node:is_empty()
  if self.type == "leaf" then
    return #self.views == 0 or (#self.views == 1 and self.views[1]:is(EmptyView))
  else
    return self.a:is_empty() and self.b:is_empty()
  end
end


function Node:close_all_docviews(keep_active)
  local node_active_view = self.active_view
  local lost_active_view = false
  if self.type == "leaf" then
    local i = 1
    while i <= #self.views do
      local view = self.views[i]
      if view.context == "session" and (not keep_active or view ~= self.active_view) then
        table.remove(self.views, i)
        if view == node_active_view then
          lost_active_view = true
        end
      else
        i = i + 1
      end
    end
    self.tab_scroll = 0
    if #self.views == 0 and self.is_primary_node then
      -- if we are not the primary view and we had the active view it doesn't
      -- matter to reattribute the active view because, within the close_all_docviews
      -- top call, the primary node will take the active view anyway.
      -- Set the empty view and takes the active view.
      self:add_view(EmptyView())
    elseif #self.views > 0 and lost_active_view then
      -- In practice we never get there but if a view remain we need
      -- to reset the Node's active view.
      self:set_active_view(self.views[1])
    end
  else
    self.a:close_all_docviews(keep_active)
    self.b:close_all_docviews(keep_active)
    if self.a:is_empty() and not self.a.is_primary_node then
      self:consume(self.b)
    elseif self.b:is_empty() and not self.b.is_primary_node then
      self:consume(self.a)
    end
  end
end

-- Returns true for nodes that accept either "proportional" resizes (based on the
-- node.divider) or "locked" resizable nodes (along the resize axis).
function Node:is_resizable(axis)
  if self.type == 'leaf' then
    return not self.locked or not self.locked[axis] or self.resizable
  else
    local a_resizable = self.a:is_resizable(axis)
    local b_resizable = self.b:is_resizable(axis)
    return a_resizable and b_resizable
  end
end


-- Return true iff it is a locked pane along the rezise axis and is
-- declared "resizable".
function Node:is_locked_resizable(axis)
  return self.locked and self.locked[axis] and self.resizable
end


function Node:resize(axis, value)
  -- the application works fine with non-integer values but to have pixel-perfect
  -- placements of view elements, like the scrollbar, we round the value to be
  -- an integer.
  value = math.floor(value)
  if self.type == 'leaf' then
    -- If it is not locked we don't accept the
    -- resize operation here because for proportional panes the resize is
    -- done using the "divider" value of the parent node.
    if self:is_locked_resizable(axis) then
      return self.active_view:set_target_size(axis, value)
    end
  else
    if self.type == (axis == "x" and "hsplit" or "vsplit") then
      -- we are resizing a node that is splitted along the resize axis
      if self.a:is_locked_resizable(axis) and self.b:is_locked_resizable(axis) then
        local rem_value = value - self.a.size[axis]
        if rem_value >= 0 then
          return self.b.active_view:set_target_size(axis, rem_value)
        else
          self.b.active_view:set_target_size(axis, 0)
          return self.a.active_view:set_target_size(axis, value)
        end
      end
    else
      -- we are resizing a node that is splitted along the axis perpendicular
      -- to the resize axis
      local a_resizable = self.a:is_resizable(axis)
      local b_resizable = self.b:is_resizable(axis)
      if a_resizable and b_resizable then
        self.a:resize(axis, value)
        self.b:resize(axis, value)
      end
    end
  end
end


function Node:get_split_type(mouse_x, mouse_y)
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  local tab_h = self:get_tab_bar_height()
  y = y + tab_h
  h = h - tab_h

  local local_mouse_x = mouse_x - x
  local local_mouse_y = mouse_y - y

  if local_mouse_y < 0 then
    return "tab"
  else
    local left_pct = local_mouse_x * 100 / w
    local top_pct = local_mouse_y * 100 / h
    if left_pct <= 30 then
      return "left"
    elseif left_pct >= 70 then
      return "right"
    elseif top_pct <= 30 then
      return "up"
    elseif top_pct >= 70 then
      return "down"
    end
    return "middle"
  end
end


function Node:get_drag_overlay_tab_position(x, y, dragged_node, dragged_index)
  local tab_index = self:get_tab_overlapping_point(x, y)
  if not tab_index then
    -- mouse after the last tab, or over the buttons: the last tab in view
    local x0 = self.position.x
    local area_x = math.min(x, x0 + self:get_tab_area_width() - 1)
    tab_index = common.clamp(math.floor((area_x - x0 + self.tab_shift) / self.tab_width) + 1, 1, #self.views)
  end
  local tab_x, tab_y, tab_w, tab_h = self:get_tab_rect(tab_index)
  if x > tab_x + tab_w / 2 and tab_index <= #self.views then
    -- use next tab
    tab_x = tab_x + tab_w
    tab_index = tab_index + 1
  end
  if self == dragged_node and dragged_index and tab_index > dragged_index then
    -- the tab we are moving is counted in tab_index
    tab_index = tab_index - 1
    tab_x = tab_x - tab_w
  end
  return tab_index, tab_x, tab_y, tab_w, tab_h
end

return Node
