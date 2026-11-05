local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local tooltip = require "core.tooltip"
local shapes = require "libraries.shapes"

---The selected frame's arguments and locals, as a tree: structs, arrays and
---containers (through gdb's pretty printers) unfold into their members.
---Values that changed since they were last shown (at an earlier stop) are
---highlighted. Hovering a row shows its type. What's unfolded stays so from stop to stop (by the thread, the
---frame's function and the variable's path). While the program runs, the last
---stop's values stay, dimmed.
---
---Subclasses (the watches) give the tree's roots with fetch_roots().
---@class debug.variablesview : core.view
local VariablesView = View:extend()

-- its id in plugins.debug's views
VariablesView.view_id = "variables"

function VariablesView:new()
  VariablesView.super.new(self)
  self.scrollable = true
  -- scopes' nodes: { name, value, type, ref, key, depth, children, scope, changed }
  self.tree = {}
  self.rows = {}
  -- unfolded (true) or folded (false) nodes, by key; scopes are unfolded by default
  self.expanded = {}
  self.selected_key = nil
  self.hovered_row = nil
  -- values by key, for "changed": { value, generation (the stop it's of),
  -- previous (the value at the last stop before that it was seen at) }
  self.values = {}
  self.session = nil
  self.max_h_scroll = 0
end

local function debug() return require "plugins.debug" end

function VariablesView:get_name() return "Variables" end

function VariablesView:get_workspace_state() return {} end
function VariablesView:from_workspace_state() return debug().get_view(self.view_id) end

function VariablesView:get_line_height()
  return style.padding.y + math.max(style.font:get_height(), style.code_font:get_height())
end

function VariablesView:get_scrollable_size()
  return (math.max(#self.rows, 1)) * self:get_line_height() + style.padding.y
end

function VariablesView:get_h_scrollable_size() return self.max_h_scroll end

function VariablesView:is_expanded(node)
  local e = self.expanded[node.key]
  if e == nil then return node.scope == true end
  return e
end

function VariablesView:rebuild_rows()
  self.rows = {}
  local function add(node)
    table.insert(self.rows, node)
    if node.children and self:is_expanded(node) then
      for _, child in ipairs(node.children) do add(child) end
    end
  end
  for _, scope in ipairs(self.tree) do
    if not scope.children or #scope.children > 0 then add(scope) end
  end
  core.redraw = true
end

-- what identifies a frame from stop to stop: its thread, its function, and
-- its depth from the outermost (so a call deeper doesn't change it)
function VariablesView.frame_key(session)
  local frame = session:get_frame()
  return tostring(session:thread_id()) .. ":" .. (#session.frames - session.frame_index) .. ":" .. frame.name
end

---A node for a variable, marked changed if its value differs from the one
---last shown (at an earlier stop).
---@param v debug.variable
---@param key string
---@param depth integer
function VariablesView:make_node(session, v, key, depth)
  local node = { name = v.name, value = v.value, type = v.type, ref = v.ref, key = key, depth = depth }
  if v.value then
    local seen = self.values[key]
    if not seen then
      self.values[key] = { value = v.value, generation = session.generation }
    else
      if seen.generation ~= session.generation then
        seen.previous, seen.value, seen.generation = seen.value, v.value, session.generation
      end
      node.changed = seen.previous ~= nil and seen.previous ~= v.value
    end
  end
  return node
end

-- fetches a node's children, and theirs that are unfolded; in a thread
function VariablesView:fetch(session, node)
  local vars = session:variables(node.ref)
  if not vars then return false end
  node.children = {}
  for _, v in ipairs(vars) do
    local child = self:make_node(session, v, node.key .. "/" .. v.name, node.depth + 1)
    table.insert(node.children, child)
    if child.ref and self.expanded[child.key] then
      if self:fetch(session, child) == false then return false end
    end
  end
  return true
end

---The tree's roots, with what's unfolded fetched, in a thread: here the
---frame's scopes. nil if it failed, or `is_stale()` became true.
function VariablesView:fetch_roots(session, is_stale)
  local scopes = session:scopes()
  if not scopes or is_stale() then return nil end
  local fkey = VariablesView.frame_key(session)
  local tree = {}
  for _, s in ipairs(scopes) do
    local node = { name = s.name, ref = s.ref, scope = true, key = fkey .. ":" .. s.name, depth = 0 }
    table.insert(tree, node)
    if self:is_expanded(node) and self:fetch(session, node) == false then return nil end
    if is_stale() then return nil end
  end
  return tree
end

---Fetches the selected frame's variables (the session stopped, or another frame
---or thread was selected).
function VariablesView:refresh()
  local session = debug().session
  if session ~= self.session then
    self.session = session
    self.values = {}
  end
  if not session or session.state ~= "stopped" or not session:get_frame() then return end
  local token = {}
  self.fetching = token
  core.add_thread(function()
    -- stale (a newer fetch, or another stop) or failed: the tree stays
    local function give_up()
      if self.fetching == token then self.fetching = nil end
      core.redraw = true
    end
    local tree = self:fetch_roots(session, function() return self.fetching ~= token end)
    if not tree or self.fetching ~= token then return give_up() end
    self.fetching = nil
    self.tree = tree
    self.tree_generation = session.generation
    self:rebuild_rows()
  end)
end

-- fetched when shown (only a tab in front is updated) for a stop or frame it
-- hasn't been yet: values changed since they were last seen
function VariablesView:update()
  VariablesView.super.update(self)
  local session = debug().session
  local key = session and session.state == "stopped" and session.frames
    and self:fetch_key(session)
  if key and key ~= self.fetched_key then
    self.fetched_key = key
    self:refresh()
  end
end

-- what the tree was fetched for: when it changes, it's fetched again
function VariablesView:fetch_key(session)
  return session.generation .. ":" .. tostring(session:thread_id()) .. ":" .. tostring(session.frame_index)
end

-- what's shown without rows
function VariablesView:get_empty_text()
  local session = debug().session
  return session and session.state == "stopped" and (self.fetching and "…" or "No variables")
    or "Not stopped"
end

-- the tree is the current stop's
function VariablesView:is_current()
  local session = debug().session
  return session and session.state == "stopped" and self.tree_generation == session.generation and not self.fetching
end

function VariablesView:toggle(node, expand)
  if not node.ref then return end
  if expand == nil then expand = not self:is_expanded(node) end
  self.expanded[node.key] = expand
  if expand and not node.children and self:is_current() then
    local session = debug().session
    core.add_thread(function()
      self:fetch(session, node)
      self:rebuild_rows()
    end)
  else
    self:rebuild_rows()
  end
end

---Enter or a double click on a row: unfolds or folds it.
function VariablesView:activate(node)
  self:toggle(node)
end

function VariablesView:get_selected_row()
  for i, node in ipairs(self.rows) do
    if node.key == self.selected_key then return i, node end
  end
end

function VariablesView:select_row(i)
  if #self.rows == 0 then return end
  i = common.clamp(i, 1, #self.rows)
  self.selected_key = self.rows[i].key
  local h = self:get_line_height()
  self.scroll.to.y = math.min(self.scroll.to.y, h * (i - 1))
  self.scroll.to.y = math.max(self.scroll.to.y, h * i + style.padding.y - self.size.y)
end

function VariablesView:row_at(x, y)
  local _, oy = self:get_content_offset()
  local i = math.floor((y - oy) / self:get_line_height()) + 1
  return self.rows[i] and i or nil
end

-- the row's tooltip target: its key, if it has a type to show
local function tooltip_target(node)
  return node and node.type and node.type ~= "" and node.key or nil
end

function VariablesView:on_mouse_moved(x, y, ...)
  if VariablesView.super.on_mouse_moved(self, x, y, ...) then
    self.hovered_row = nil
    tooltip.hover(self, nil)
    return true
  end
  self.hovered_row = self:row_at(x, y)
  -- by key: a row rebuilt at a stop is the same target
  tooltip.hover(self, tooltip_target(self.rows[self.hovered_row]))
end

function VariablesView:on_mouse_left()
  VariablesView.super.on_mouse_left(self)
  self.hovered_row = nil
  tooltip.hover(self, nil)
end

-- the type, in a box under the row, from the name
function VariablesView:draw_tooltip(node, y, h)
  local font = style.code_font
  local text = node.type
  local w = font:get_width(text) + style.padding.x * 2
  local th = font:get_height() + style.padding.y
  local root = core.root_view.root_node
  local x = self:expander_x(node) + self:get_indent()
  x = math.max(0, math.min(x, root.size.x - w - 1))
  -- below the row, else above it
  local ty = y + h
  if ty + th > root.size.y then ty = y - th end
  common.draw_popup_box(x, ty, w, th)
  renderer.draw_text(font, text, x + style.padding.x, ty + style.padding.y / 2, style.text)
end

function VariablesView:expander_x(node)
  local ox = self:get_content_offset()
  return ox + style.padding.x + node.depth * self:get_indent()
end

function VariablesView:get_indent() return style.code_font:get_width("  ") end

function VariablesView:on_mouse_pressed(button, x, y, clicks)
  if VariablesView.super.on_mouse_pressed(self, button, x, y, clicks) then return true end
  local i = self:row_at(x, y)
  if button ~= "left" or not i then return end
  local node = self.rows[i]
  self.selected_key = node.key
  local ex = self:expander_x(node)
  if node.ref and x >= ex - style.padding.x / 2 and x < ex + self:get_indent() then
    self:toggle(node)
  elseif clicks > 1 or node.add then
    self:activate(node)
  end
  return true
end

local function value_color(value)
  if value:find('^"') or value:find("^0x%x+ \"") then return style.syntax.string or style.text end
  if value:find("^%-?[%d.]") then return style.syntax.number or style.text end
  if value == "true" or value == "false" then return style.syntax.literal or style.text end
  return style.text
end

function VariablesView:draw_node(node, x, y, h, dim)
  local font = style.code_font
  local indent = self:get_indent()
  x = x + node.depth * indent
  if node.ref then
    local size = math.floor(font:get_height() * 0.6)
    shapes.expander(x + (indent - size) / 2, y + (h - size) / 2, size, style.dim, self:is_expanded(node))
  end
  x = x + indent
  if node.scope or node.add then
    return common.draw_text(style.font, style.dim, node.name, "left", x, y, 0, h)
  end
  -- an array's elements by index
  local name = node.name:find("^%d+$") and ("[" .. node.name .. "]") or node.name
  x = common.draw_text(font, dim and style.dim or style.text, name, "left", x, y, 0, h)
  if node.value then
    x = common.draw_text(font, style.dim, " = ", "left", x, y, 0, h)
    local value = node.value:gsub("\n", " ")
    if #value > 500 then value = value:sub(1, 500) .. "…" end
    local color = dim and style.dim or (node.changed and style.debug.changed or value_color(value))
    if node.changed and not dim then
      local th = font:get_height()
      renderer.draw_rect(x, y + (h - th) / 2, font:get_width(value), th, style.debug.changed_background)
    end
    x = common.draw_text(font, color, value, "left", x, y, 0, h)
  elseif node.error then
    x = common.draw_text(font, style.dim, "  ", "left", x, y, 0, h)
    -- often just out of scope: not as loud as an error
    x = common.draw_text(style.font, style.dim, node.error, "left", x, y, 0, h)
  end
  if node.type and config.plugins.debug.show_types then
    x = common.draw_text(style.font, style.dim, "  " .. node.type, "left", x, y, 0, h)
  end
  return x
end

function VariablesView:draw()
  self:draw_background(style.background)
  local h = self:get_line_height()
  local ox, oy = self:get_content_offset()
  local _, _, w = self:get_content_bounds()
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  if #self.rows == 0 then
    common.draw_text(style.font, style.dim, self:get_empty_text(), "left", ox + style.padding.x, oy, 0, h)
  end
  local dim = not self:is_current()
  local first = math.max(1, math.floor(self.scroll.y / h))
  for i = first, math.min(#self.rows, first + math.ceil(self.size.y / h) + 1) do
    local node, y = self.rows[i], oy + (i - 1) * h
    if node.key == self.selected_key and core.active_view == self then
      renderer.draw_rect(ox, y, w, h, style.selection)
    elseif i == self.hovered_row then
      renderer.draw_rect(ox, y, w, h, style.line_highlight)
    end
    local x = self:draw_node(node, ox + style.padding.x, y, h, dim)
    self.max_h_scroll = math.max(self.max_h_scroll, x + style.padding.x - self.position.x + self.scroll.x)
    local target = i == self.hovered_row and tooltip_target(node)
    if target and tooltip.shown(self, target) then
      core.root_view:defer_draw(self.draw_tooltip, self, node, y, h)
    end
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end


command.add(VariablesView, {
  ["debug-variables:select-previous"] = function(view)
    local i = view:get_selected_row()
    view:select_row(i and i - 1 or #view.rows)
  end,
  ["debug-variables:select-next"] = function(view)
    local i = view:get_selected_row()
    view:select_row(i and i + 1 or 1)
  end,
  ["debug-variables:expand"] = function(view)
    local i, node = view:get_selected_row()
    if not node then return end
    if node.ref and not view:is_expanded(node) then view:toggle(node, true)
    elseif node.children and #node.children > 0 then view:select_row(i + 1) end
  end,
  ["debug-variables:collapse"] = function(view)
    local i, node = view:get_selected_row()
    if not node then return end
    if node.ref and view:is_expanded(node) then
      view:toggle(node, false)
    else
      -- to the parent
      for j = i - 1, 1, -1 do
        if view.rows[j].depth < node.depth then view:select_row(j) break end
      end
    end
  end,
  ["debug-variables:activate"] = function(view)
    local _, node = view:get_selected_row()
    if node then view:activate(node) end
  end,
})

keymap.add {
  ["up"] = "debug-variables:select-previous",
  ["down"] = "debug-variables:select-next",
  ["right"] = "debug-variables:expand",
  ["left"] = "debug-variables:collapse",
  ["return"] = "debug-variables:activate",
}

return VariablesView
