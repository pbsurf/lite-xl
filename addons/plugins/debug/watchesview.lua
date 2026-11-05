local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local VariablesView = require "plugins.debug.variablesview"
local watches = require "plugins.debug.watches"

---Watch expressions (kept per project), evaluated in the selected frame at
---each stop: as the variables, they unfold into their members and changed
---values are highlighted. The last row adds one; Enter or a double click on
---an expression edits it, Delete removes it.
---@class debug.watchesview : debug.variablesview
local WatchesView = VariablesView:extend()

WatchesView.view_id = "watches"

local function debug() return require "plugins.debug" end

function WatchesView:get_name() return "Watches" end

local function root_key(expression) return "watch:" .. expression end

function WatchesView:fetch_roots(session, is_stale)
  local tree = {}
  for i, expression in ipairs(watches.list()) do
    local var, err = session:watch(expression)
    if is_stale() then return nil end
    local node
    if var then
      node = self:make_node(session, { name = expression, value = var.value, type = var.type, ref = var.ref },
        root_key(expression), 0)
      if node.ref and self.expanded[node.key] and self:fetch(session, node) == false then return nil end
    else
      node = { name = expression, key = root_key(expression), depth = 0,
        error = err and err:gsub("%.$", "") or "unavailable" }
    end
    node.watch = i
    table.insert(tree, node)
  end
  return tree
end

-- the expressions alone, while there's nothing to evaluate them in
function WatchesView:show_expressions()
  self.tree = {}
  for i, expression in ipairs(watches.list()) do
    table.insert(self.tree, { name = expression, key = root_key(expression), depth = 0, watch = i })
  end
  self.tree_generation = nil
  self:rebuild_rows()
end

function WatchesView:fetch_key(session)
  return WatchesView.super.fetch_key(self, session) .. ":" .. watches.version
end

function WatchesView:update()
  WatchesView.super.update(self)
  local session = debug().session
  local stopped = session and session.state == "stopped"
  -- a change to the list while not stopped (while stopped, fetch_key has it)
  if not stopped and self.shown_version ~= watches.version then
    self.shown_version = watches.version
    -- the last stop's values stay while running
    if not (session and session.state == "running" and self.tree_generation) then
      self:show_expressions()
    end
  end
end

-- the roots as they are, and a row to add one
function WatchesView:rebuild_rows()
  self.rows = {}
  local function add(node)
    table.insert(self.rows, node)
    if node.children and self:is_expanded(node) then
      for _, child in ipairs(node.children) do add(child) end
    end
  end
  for _, node in ipairs(self.tree) do add(node) end
  table.insert(self.rows, { add = true, name = "Add expression…", key = "\0add", depth = 0 })
  core.redraw = true
end

---Asks for an expression to watch, or a new one for watch `index`.
function WatchesView.prompt(index, default)
  local list = watches.list()
  core.command_view:enter(index and "Edit Watch" or "Watch Expression", {
    text = index and list[index] or default or "",
    select_text = true,
    submit = function(text)
      text = text:match("^%s*(.-)%s*$")
      if text == "" then
        if index then watches.remove(index) end
      elseif index then
        watches.set(index, text)
      else
        watches.add(text)
      end
    end,
  })
end

function WatchesView:activate(node)
  if node.add then
    WatchesView.prompt()
  elseif node.watch and not node.ref then
    WatchesView.prompt(node.watch)
  else
    self:toggle(node)
  end
end

-- the watch (a root row) selected, if any
local function selected_watch(view)
  local _, node = view:get_selected_row()
  return node and node.watch, node
end

command.add(function()
  local view = core.active_view
  return view:is(WatchesView) and selected_watch(view) ~= nil, view
end, {
  ["debug-watches:remove"] = function(view)
    local i = view:get_selected_row()
    local watch = selected_watch(view)
    -- the selection goes to the next row
    local next_row = view.rows[i + 1]
    view.selected_key = next_row and next_row.key
    watches.remove(watch)
  end,
  ["debug-watches:edit"] = function(view) WatchesView.prompt(selected_watch(view)) end,
})

command.add(WatchesView, {
  ["debug-watches:add"] = function() WatchesView.prompt() end,
})

-- the selection, or the word at the cursor
local function expression_at_cursor()
  local view = core.active_view
  if not (view and view:is(DocView)) then return nil end
  local doc = view.doc
  local l1, c1, l2, c2 = doc:get_selection(true)
  if l1 ~= l2 or c1 ~= c2 then
    return l1 == l2 and doc:get_text(l1, c1, l2, c2) or nil
  end
  local text = doc.lines[l1]
  for ws, we in text:gmatch("()[%w_]+()") do
    if ws <= c1 and c1 <= we then return text:sub(ws, we - 1) end
  end
end

command.add(nil, {
  -- the selection or the word at the cursor, to start with
  ["debug:add-watch"] = function()
    local default = expression_at_cursor()
    debug().show_view("watches", false)
    WatchesView.prompt(nil, default)
  end,
})

keymap.add {
  ["delete"] = "debug-watches:remove",
  ["f2"] = "debug-watches:edit",
  ["insert"] = "debug-watches:add",
}

return WatchesView
