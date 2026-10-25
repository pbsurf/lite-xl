-- mod-version:3
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local DocView = require "core.docview"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"
local CommandView = require "core.commandview"
local StatusView = require "core.statusview"
local storage = require "core.storage"
local tooltip = require "core.tooltip"

config.plugins.treeview = common.merge({
  -- Default treeview width
  size = 200 * SCALE,
  -- Dragging the treeview's divider narrower than this collapses the treeview
  collapse_size = 100 * SCALE,
}, config.plugins.treeview)


local function get_depth(filename)
  local n = 1
  for _ in filename:gmatch(PATHSEP) do
    n = n + 1
  end
  return n
end

-- entries directly in a folder of the tree, as shown (ignored files left
-- out), cached until the project's files change
local entry_counts = setmetatable({}, { __mode = "k" })
local function count_entries(item, dir)
  local c = entry_counts[item]
  if c and c.files == dir.files and c.change_id == dir.files_change_id then
    return c.n
  end
  local n, depth = 0, item.depth + 1
  local prefix = item.depth > 0 and item.filename .. PATHSEP or ""
  for _, info in ipairs(dir.files or {}) do
    if info.filename:sub(1, #prefix) == prefix and get_depth(info.filename) == depth then
      n = n + 1
    end
  end
  entry_counts[item] = { files = dir.files, change_id = dir.files_change_id, n = n }
  return n
end

local TreeView = View:extend()

function TreeView:__tostring() return "TreeView" end

function TreeView:new()
  TreeView.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.target_size = config.plugins.treeview.size
  self.cache = {}

  self.item_icon_width = 0
  self.item_text_spacing = 0
end


function TreeView:set_target_size(axis, value)
  if axis == "x" then
    if core.root_view.dragged_divider then
      -- dragged narrower than collapse_size, it collapses, keeping the width it
      -- had when the drag started to reopen with; dragged wider, it reopens
      self.drag_start_size = self.drag_start_size or self.target_size
      if value < config.plugins.treeview.collapse_size then
        self.visible = false
        self.target_size = self.drag_start_size
        return true
      end
      self.visible = true
    end
    self.target_size = value
    return true
  end
end


function TreeView:get_cached(dir, item, dirname)
  local dir_cache = self.cache[dirname]
  if not dir_cache then
    dir_cache = {}
    self.cache[dirname] = dir_cache
  end
  -- to discriminate top directories from regular files or subdirectories
  -- we add ':' at the end of the top directories' filename. it will be
  -- used only to identify the entry into the cache.
  local cache_name = item.filename .. (item.topdir and ":" or "")
  local t = dir_cache[cache_name]
  if not t or t.type ~= item.type then
    t = {}
    local basename = common.basename(item.filename)
    if item.topdir then
      t.filename = basename
      t.expanded = true
      t.depth = 0
      t.abs_filename = dirname
    else
      t.filename = item.filename
      t.depth = get_depth(item.filename)
      t.abs_filename = dirname .. PATHSEP .. item.filename
    end
    t.name = basename
    t.type = item.type
    t.dir_name = dir.name -- points to top level "dir" item
    dir_cache[cache_name] = t
  end
  return t
end


function TreeView:get_name()
  return nil
end


function TreeView:get_item_height()
  return style.font:get_height() + style.padding.y
end


function TreeView:invalidate_cache(dirname)
  for _, v in pairs(self.cache[dirname]) do
    v.skip = nil
  end
end


function TreeView:check_cache()
  for i = 1, #core.project_directories do
    local dir = core.project_directories[i]
    -- invalidate cache's skip values if directory is declared dirty
    if dir.is_dirty and self.cache[dir.name] then
      self:invalidate_cache(dir.name)
    end
    dir.is_dirty = false
  end
end


function TreeView:each_item()
  return coroutine.wrap(function()
    self:check_cache()
    local count_lines = 0
    local ox, oy = self:get_content_offset()
    local y = oy + style.padding.y
    local w = self.size.x
    local h = self:get_item_height()

    for k = 1, #core.project_directories do
      local dir = core.project_directories[k]
      local dir_cached = self:get_cached(dir, dir.item, dir.name)
      coroutine.yield(dir_cached, ox, y, w, h)
      count_lines = count_lines + 1
      y = y + h
      local i = 1
      if dir.files then -- if consumed max sys file descriptors this can be nil
        while i <= #dir.files and dir_cached.expanded do
          local item = dir.files[i]
          local cached = self:get_cached(dir, item, dir.name)

          coroutine.yield(cached, ox, y, w, h)
          count_lines = count_lines + 1
          y = y + h
          i = i + 1

          if not cached.expanded then
            if cached.skip then
              i = cached.skip
            else
              local depth = cached.depth
              while i <= #dir.files do
                if get_depth(dir.files[i].filename) <= depth then break end
                i = i + 1
              end
              cached.skip = i
            end
          end
        end -- while files
      end
    end -- for directories
    self.count_lines = count_lines
  end)
end


function TreeView:set_selection(selection, selection_y)
  self.selected_item = selection
  if selection and selection_y
      and (selection_y <= 0 or selection_y >= self.size.y) then

    local lh = self:get_item_height()
    if selection_y >= self.size.y - lh then
      selection_y = selection_y - self.size.y + lh
    end
    local _, y = self:get_content_offset()
    self.scroll.to.y = selection and (selection_y - y)
  end
end


---Where an entry's name is drawn in its row (x, y, w, h), as draw_item lays it out.
function TreeView:get_text_bounding_box(item, x, y, w, h)
  x = x + self:get_item_indent(item) + self:get_item_chevron_width(item)
    + self.item_icon_width + self.item_text_spacing
  local text, font = self:get_item_text(item)
  return x, y, font:get_width(text), h
end


function TreeView:on_mouse_moved(px, py, ...)
  if not self.visible then return end
  if TreeView.super.on_mouse_moved(self, px, py, ...) then
    -- mouse movement handled by the View (scrollbar)
    self.hovered_item = nil
    tooltip.hover(self, nil)
    return
  end

  self.hovered_item = self:item_at(px, py)
  tooltip.hover(self, self.hovered_item)
end


---The item at a point, if it's in the view.
function TreeView:item_at(px, py)
  local p, s = self.position, self.size
  if px < p.x or py < p.y or px >= p.x + s.x or py >= p.y + s.y then return end
  for item, x,y,w,h in self:each_item() do
    if px > x and py > y and px <= x + w and py <= y + h then return item end
  end
end


function TreeView:update()
  -- update width
  local dest = self.visible and self.target_size or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest, nil, "treeview")
  end

  if not self.visible then return end

  self.item_icon_width = style.icon_font:get_width("D")
  self.item_text_spacing = style.icon_font:get_width("f") / 2

  TreeView.super.update(self)
end


function TreeView:get_scrollable_size()
  return self.count_lines and self:get_item_height() * (self.count_lines + 1) or math.huge
end


---Facts about an entry, for its tooltip: a file's size
---and age, a folder's entry count. Plugins can add to them.
---@return string[]
function TreeView:get_item_info(item)
  if item.type == "dir" then
    local dir = core.project_dir_by_name(item.dir_name)
    if not dir then return {} end
    local n = count_entries(item, dir)
    return { common.format_count(n) .. (n == 1 and " item" or " items") }
  end
  local info = system.get_file_info(item.abs_filename)
  if not info then return {} end
  return { common.format_size(info.size), "modified " .. common.format_age(info.modified) }
end


---Draws an entry's tooltip at the tree view's right edge, beside its row (top ty,
---height th), so that it doesn't cover the entries around it.
function TreeView:draw_tooltip(item, ty, th)
  local text = common.home_encode(item.abs_filename)
  local info = table.concat(self:get_item_info(item), " · ")
  local font = style.font
  local lh = font:get_height()
  local w = math.max(font:get_width(text), font:get_width(info)) + style.padding.x * 2
  local h = lh * (info ~= "" and 2 or 1) + style.padding.y

  local root = core.root_view.root_node
  local x = self.position.x + self.size.x - style.padding.x / 2
  x = math.max(0, math.min(x, root.size.x - w - 1))
  local y = math.max(0, math.min(ty + (th - h) / 2, root.size.y - h - 1))

  common.draw_popup_box(x, y, w, h)
  local px, py = x + style.padding.x, y + style.padding.y / 2
  renderer.draw_text(font, text, px, py, style.text)
  if info ~= "" then
    renderer.draw_text(font, info, px, py + lh, style.dim)
  end
end


function TreeView:get_item_icon(item, active, hovered)
  local character = "f"
  if item.type == "dir" then
    character = item.expanded and "D" or "d"
  end
  local font = style.icon_font
  local color = style.text
  if active or hovered then
    color = style.accent
  end
  return character, font, color
end

function TreeView:get_item_text(item, active, hovered)
  local text = item.name
  local font = style.font
  local color = style.text
  if active or hovered then
    color = style.accent
  end
  return text, font, color
end


function TreeView:draw_item_text(item, active, hovered, x, y, w, h)
  local item_text, item_font, item_color = self:get_item_text(item, active, hovered)
  common.draw_text(item_font, item_color, item_text, nil, x, y, 0, h)
end


function TreeView:draw_item_icon(item, active, hovered, x, y, w, h)
  local icon_char, icon_font, icon_color = self:get_item_icon(item, active, hovered)
  common.draw_text(icon_font, icon_color, icon_char, nil, x, y, 0, h)
  return self.item_icon_width + self.item_text_spacing
end


function TreeView:draw_item_body(item, active, hovered, x, y, w, h)
    x = x + self:draw_item_icon(item, active, hovered, x, y, w, h)
    self:draw_item_text(item, active, hovered, x, y, w, h)
end


---Space before an entry's chevron column: its depth's indent, plus a margin.
function TreeView:get_item_indent(item)
  return item.depth * style.padding.x + style.padding.x / 2
end


---Width of the chevron column, which every entry has, chevron or not.
function TreeView:get_item_chevron_width(item)
  return style.padding.x
end


function TreeView:draw_item_chevron(item, active, hovered, x, y, w, h)
  if item.type == "dir" then
    local chevron_icon = item.expanded and "-" or "+"
    local chevron_color = hovered and style.accent or style.text
    common.draw_text(style.icon_font, chevron_color, chevron_icon, nil, x, y, 0, h)
  end
  return self:get_item_chevron_width(item)
end


function TreeView:draw_item_background(item, active, hovered, x, y, w, h)
  if hovered then
    local hover_color = { table.unpack(style.line_highlight) }
    hover_color[4] = 160
    renderer.draw_rect(x, y, w, h, hover_color)
  elseif active then
    renderer.draw_rect(x, y, w, h, style.line_highlight)
  end
end


function TreeView:draw_item(item, active, hovered, x, y, w, h)
  self:draw_item_background(item, active, hovered, x, y, w, h)

  x = x + self:get_item_indent(item)
  x = x + self:draw_item_chevron(item, active, hovered, x, y, w, h)

  self:draw_item_body(item, active, hovered, x, y, w, h)
end


function TreeView:draw()
  if not self.visible then return end
  self:draw_background(style.background2)
  local _y, _h = self.position.y, self.size.y

  local tooltip_item, tooltip_y, tooltip_h
  for item, x,y,w,h in self:each_item() do
    if y + h >= _y and y < _y + _h then
      self:draw_item(item,
        item == self.selected_item,
        item == self.hovered_item,
        x, y, w, h)
      if item == self.hovered_item and tooltip.shown(self, item) then
        tooltip_item, tooltip_y, tooltip_h = item, y, h
      end
    end
  end

  self:draw_scrollbar()
  if tooltip_item then
    core.root_view:defer_draw(self.draw_tooltip, self, tooltip_item, tooltip_y, tooltip_h)
  end
end


function TreeView:get_parent(item)
  local parent_path = common.dirname(item.abs_filename)
  if not parent_path then return end
  for it, _, y in self:each_item() do
    if it.abs_filename == parent_path then
      return it, y
    end
  end
end


function TreeView:get_item(item, where)
  local last_item, last_x, last_y, last_w, last_h
  local stop = false

  for it, x, y, w, h in self:each_item() do
    if not item and where >= 0 then
      return it, x, y, w, h
    end
    if item == it then
      if where < 0 and last_item then
        break
      elseif where == 0 or (where < 0 and not last_item) then
        return it, x, y, w, h
      end
      stop = true
    elseif stop then
      item = it
      return it, x, y, w, h
    end
    last_item, last_x, last_y, last_w, last_h = it, x, y, w, h
  end
  return last_item, last_x, last_y, last_w, last_h
end

function TreeView:get_next(item)
  return self:get_item(item, 1)
end

function TreeView:get_previous(item)
  return self:get_item(item, -1)
end


function TreeView:toggle_expand(toggle)
  local item = self.selected_item

  if not item then return end

  if item.type == "dir" then
    if type(toggle) == "boolean" then
      item.expanded = toggle
    else
      item.expanded = not item.expanded
    end
    local hovered_dir = core.project_dir_by_name(item.dir_name)
    if hovered_dir and hovered_dir.files_limit then
      core.update_project_subdir(hovered_dir, item.depth == 0 and "" or item.filename, item.expanded)
    end
  end
end


---Expands or collapses a folder and every folder in it. Where only opened folders
---are scanned (files_limit), expanding scans the folders as it goes, and stops
---once the subtree has more than config.max_project_files entries.
---@param item table a cached tree item of type "dir"
---@param expanded boolean
---@param descendants_only? boolean leave the folder itself as it is
function TreeView:set_expanded_all(item, expanded, descendants_only)
  local dir = core.project_dir_by_name(item.dir_name)
  if not dir or item.type ~= "dir" then return end
  local prefix = item.depth == 0 and "" or item.filename .. PATHSEP
  local function set(cached, filename)
    cached.expanded = expanded
    if dir.files_limit then core.update_project_subdir(dir, filename, expanded) end
  end
  -- folders in the subtree still to change, in tree order, and the subtree's size
  local function pending()
    local list, count = {}, 0
    for _, info in ipairs(dir.files) do
      if info.filename:sub(1, #prefix) == prefix then
        count = count + 1
        local cached = self:get_cached(dir, info, dir.name)
        if info.type == "dir" and cached.expanded ~= expanded then
          table.insert(list, { cached, info.filename })
        end
      end
    end
    return list, count
  end
  local own_name = item.depth == 0 and "" or item.filename
  if expanded then
    if not descendants_only then set(item, own_name) end
    while true do
      local list, count = pending()
      if #list == 0 or count > config.max_project_files then break end
      for _, d in ipairs(list) do set(d[1], d[2]) end
    end
  else
    -- innermost first: a collapsed folder's contents leave dir.files in files_limit mode
    local list = pending()
    for i = #list, 1, -1 do set(list[i][1], list[i][2]) end
    if not descendants_only then set(item, own_name) end
  end
end


---Collapses every folder except the project folders themselves.
function TreeView:collapse_all()
  for _, dir in ipairs(core.project_directories) do
    self:set_expanded_all(self:get_cached(dir, dir.item, dir.name), false, true)
  end
  -- a selection inside a collapsed folder moves to the folder shown
  local item = self.selected_item
  if item and item.depth > 1 then
    local dir = core.project_dir_by_name(item.dir_name)
    local top = item.filename:match("^[^%" .. PATHSEP .. "]+")
    self.selected_item = dir and self:get_cached(dir, { filename = top, type = "dir" }, dir.name)
  end
end


---Shows a file: expands the directories leading to it, selects it and scrolls it
---into view (the file browser too, if hidden). Returns false if it isn't listed.
---@param abs_filename string
---@return boolean
function TreeView:reveal(abs_filename)
  local dir
  for _, d in ipairs(core.project_directories) do
    if common.path_belongs_to(abs_filename, d.name) then dir = d break end
  end
  if not dir then return false end
  self.visible = true
  local rel = abs_filename:sub(#dir.name + 2)
  local prefix
  for part in rel:gmatch("([^%" .. PATHSEP .. "]+)%" .. PATHSEP) do
    prefix = (prefix or "") .. part
    local cached = self:get_cached(dir, { filename = prefix, type = "dir" }, dir.name)
    if not cached.expanded then
      cached.expanded = true
      if dir.files_limit then core.update_project_subdir(dir, prefix, true) end
    end
    prefix = prefix .. PATHSEP
  end
  self:get_cached(dir, dir.item, dir.name).expanded = true
  for item, _, y in self:each_item() do
    if item.abs_filename == abs_filename then
      self.selected_item = item
      local lh = self:get_item_height()
      y = y - self.position.y
      if y < 0 or y + lh > self.size.y then
        -- centered
        self.scroll.to.y = self.scroll.to.y + y - (self.size.y - lh) / 2
      end
      return true
    end
  end
  return false
end


-- init
local view = TreeView()

-- A doc's icon is its file's, as the tree shows it (plugins such as nerdicons
-- override get_item_icon on this instance, the module's value)
function DocView:get_icon(hovered)
  return view:get_item_icon({ type = "file", name = self.doc:get_name() }, false, hovered)
end

local node = core.root_view:get_active_node()
view.node = node:split("left", view, {x = true}, true)

-- The toolbarview plugin is special because it is plugged inside
-- a treeview pane which is itelf provided in a plugin.
-- We therefore break the usual plugin's logic that would require each
-- plugin to be independent of each other. In addition it is not the
-- plugin module that plug itself in the active node but it is plugged here
-- in the treeview node.
local toolbar_view = nil
-- (not loaded while disabled: once it's loaded, disabling it again, as the user
-- module does when it's run again on changing the project, warns)
local toolbar_plugin, ToolbarView = false, nil
if config.plugins.toolbarview ~= false then
  toolbar_plugin, ToolbarView = pcall(require, "plugins.toolbarview")
end
if toolbar_plugin then
  toolbar_view = ToolbarView()
  view.node:split("down", toolbar_view, {y = true})
  local min_toolbar_width = toolbar_view:get_min_width()
  view:set_target_size("x", math.max(config.plugins.treeview.size, min_toolbar_width))
  command.add(nil, {
    ["toolbar:toggle"] = function()
      toolbar_view:toggle_visible()
    end,
  })
end

-- The width (unscaled) and visibility it was left with, kept between sessions
local saved = storage.load("treeview", "state")
if type(saved) == "table" and type(saved.size) == "number" then
  view:set_target_size("x", saved.size * SCALE)
  view.visible = saved.visible ~= false
end
local on_quit_project = core.on_quit_project
function core.on_quit_project()
  core.try(storage.save, "treeview", "state", { size = view.target_size / SCALE, visible = view.visible })
  on_quit_project()
end

-- Add a context menu to the treeview
local menu = ContextMenu()

local on_view_mouse_pressed = RootView.on_view_mouse_pressed
local on_mouse_moved = RootView.on_mouse_moved
local on_mouse_released = RootView.on_mouse_released
local root_view_update = RootView.update
local root_view_draw = RootView.draw

function RootView:on_mouse_released(...)
  view.drag_start_size = nil -- a divider drag ended
  return on_mouse_released(self, ...)
end

function RootView:on_mouse_moved(...)
  if menu:on_mouse_moved(...) then return end
  on_mouse_moved(self, ...)
end

function RootView.on_view_mouse_pressed(button, x, y, clicks)
  -- a click acts on the item where it lands (its menu, and its commands, use
  -- the hovered item), whatever the last move left hovered
  if not menu.show_context_menu then view.hovered_item = view:item_at(x, y) end
  -- We give the priority to the menu to process mouse pressed events.
  local handled = menu:on_mouse_pressed(button, x, y, clicks)
  return handled or on_view_mouse_pressed(button, x, y, clicks)
end

function RootView:update(...)
  root_view_update(self, ...)
  menu:update()
end

function RootView:draw(...)
  root_view_draw(self, ...)
  menu:draw()
end

local on_quit_project = core.on_quit_project
function core.on_quit_project()
  view.cache = {}
  on_quit_project()
end

local function is_project_folder(path)
  for _,dir in pairs(core.project_directories) do
    if dir.name == path then
      return true
    end
  end
  return false
end

local function is_primary_project_folder(path)
  return core.project_dir == path
end


local function treeitem() return view.hovered_item or view.selected_item end


-- The item menus are for the item under the pointer; elsewhere in the
-- treeview, plugins may register a menu for the treeview itself
menu:register(function() return core.active_view:is(TreeView) and view.hovered_item end, {
  { text = "Open in System", command = "treeview:open-in-system" },
  ContextMenu.DIVIDER
})

menu:register(
  function()
    local item = view.hovered_item
    return core.active_view:is(TreeView) and item and not is_project_folder(item.abs_filename)
  end,
  {
    { text = "Rename", command = "treeview:rename" },
    { text = "Delete", command = "treeview:delete" },
  }
)

menu:register(
  function()
    local item = view.hovered_item
    return core.active_view:is(TreeView) and item and item.type == "dir"
  end,
  {
    { text = "New File", command = "treeview:new-file" },
    { text = "New Folder", command = "treeview:new-folder" },
  }
)

-- for the treeview itself, not over an item
menu:register(function() return core.active_view:is(TreeView) and not view.hovered_item end, {
  { text = "Collapse All", command = "treeview:collapse-all" },
})

menu:register(
  function()
    local item = view.hovered_item
    return core.active_view:is(TreeView) and item
      and not is_primary_project_folder(item.abs_filename)
      and is_project_folder(item.abs_filename)
  end,
  {
    { text = "Remove directory", command = "treeview:remove-project-directory" },
  }
)

local previous_view = nil

-- Register the TreeView commands and keymap
command.add(nil, {
  ["treeview:toggle"] = function()
    view.visible = not view.visible
  end,

  ["treeview:collapse-all"] = function()
    view:collapse_all()
  end,

  ["treeview:toggle-focus"] = function()
    if not core.active_view:is(TreeView) then
      if core.active_view:is(CommandView) then
        previous_view = core.last_active_view
      else
        previous_view = core.active_view
      end
      if not previous_view then
        previous_view = core.root_view:get_primary_node().active_view
      end
      core.set_active_view(view)
      if not view.selected_item then
        for it, _, y in view:each_item() do
          view:set_selection(it, y)
          break
        end
      end

    else
      core.set_active_view(
        previous_view or core.root_view:get_primary_node().active_view
      )
    end
  end
})

command.add(
  function()
    return not menu.show_context_menu and core.active_view:extends(TreeView), TreeView
  end, {
  ["treeview:next"] = function()
    local item, _, item_y = view:get_next(view.selected_item)
    view:set_selection(item, item_y)
  end,

  ["treeview:previous"] = function()
    local item, _, item_y = view:get_previous(view.selected_item)
    view:set_selection(item, item_y)
  end,

  ["treeview:open"] = function()
    local item = view.selected_item
    if not item then return end
    if item.type == "dir" then
      view:toggle_expand()
    else
      core.try(function()
        if core.last_active_view and core.active_view == view then
          core.set_active_view(core.last_active_view)
        end
        local doc_filename = core.normalize_to_project_dir(item.abs_filename)
        core.root_view:open_doc(core.open_doc(doc_filename), { preview = true })
      end)
    end
  end,

  ["treeview:deselect"] = function()
    view.selected_item = nil
  end,

  ["treeview:select"] = function()
    view:set_selection(view.hovered_item)
  end,

  ["treeview:select-and-open"] = function()
    if view.hovered_item then
      view:set_selection(view.hovered_item)
      command.perform "treeview:open"
    end
  end,

  ["treeview:toggle-expand-all"] = function()
    local item = view.hovered_item
    if item then
      view:set_selection(item)
      if item.type == "dir" then view:set_expanded_all(item, not item.expanded) end
    end
  end,

  ["treeview:collapse"] = function()
    if view.selected_item then
      if view.selected_item.type == "dir" and view.selected_item.expanded then
        view:toggle_expand(false)
      else
        local parent_item, y = view:get_parent(view.selected_item)
        if parent_item then
          view:set_selection(parent_item, y)
        end
      end
    end
  end,

  ["treeview:expand"] = function()
    local item = view.selected_item
    if not item or item.type ~= "dir" then return end

    if item.expanded then
      local next_item, _, next_y = view:get_next(item)
      if next_item.depth > item.depth then
        view:set_selection(next_item, next_y)
      end
    else
      view:toggle_expand(true)
    end
  end,
})


command.add(
  function()
    local item = treeitem()
    return item ~= nil and (core.active_view == view or menu.show_context_menu), item
  end, {
  ["treeview:delete"] = function(item)
    local filename = item.abs_filename
    local relfilename = item.filename
    if item.dir_name ~= core.project_dir then
      -- add secondary project dirs names to the file path to show
      relfilename = common.basename(item.dir_name) .. PATHSEP .. relfilename
    end
    core.confirm_delete(filename, relfilename)
  end,

  ["treeview:rename"] = function(item)
    local old_filename = item.filename
    local old_abs_filename = item.abs_filename
    core.command_view:enter("Rename", {
      text = old_filename,
      submit = function(filename)
        local abs_filename = filename
        if not common.is_absolute_path(filename) then
          abs_filename = item.dir_name .. PATHSEP .. filename
        end
        local res, err = os.rename(old_abs_filename, abs_filename)
        if res then -- successfully renamed
          for _, doc in ipairs(core.docs) do
            if doc.abs_filename and old_abs_filename == doc.abs_filename then
              doc:set_filename(filename, abs_filename) -- make doc point to the new filename
              doc:reset_syntax()
              break -- only first needed
            end
          end
          core.log("Renamed \"%s\" to \"%s\"", old_filename, filename)
        else
          core.error("Error while renaming \"%s\" to \"%s\": %s", old_abs_filename, abs_filename, err)
        end
      end,
      suggest = function(text)
        return common.path_suggest(text, item.dir_name)
      end
    })
  end,

  ["treeview:new-file"] = function(item)
    local text
    if not is_project_folder(item.abs_filename) then
      if item.type == "dir" then
        text = item.filename .. PATHSEP
      elseif item.type == "file" then
        local parent_dir = common.dirname(item.filename)
        text = parent_dir and parent_dir .. PATHSEP
      end
    end
    core.command_view:enter("Filename", {
      text = text,
      submit = function(filename)
        local doc_filename = item.dir_name .. PATHSEP .. filename
        core.log(doc_filename)
        local file = io.open(doc_filename, "a+")
        file:write("")
        file:close()
        core.root_view:open_doc(core.open_doc(doc_filename))
        core.log("Created %s", doc_filename)
      end,
      suggest = function(text)
        return common.path_suggest(text, item.dir_name)
      end
    })
  end,

  ["treeview:new-folder"] = function(item)
    local text
    if not is_project_folder(item.abs_filename) then
      if item.type == "dir" then
        text = item.filename .. PATHSEP
      elseif item.type == "file" then
        local parent_dir = common.dirname(item.filename)
        text = parent_dir and parent_dir .. PATHSEP
      end
    end
    core.command_view:enter("Folder Name", {
      text = text,
      submit = function(filename)
        local dir_path = item.dir_name .. PATHSEP .. filename
        common.mkdirp(dir_path)
        core.log("Created %s", dir_path)
      end,
      suggest = function(text)
        return common.path_suggest(text, item.dir_name)
      end
    })
  end,

  ["treeview:open-in-system"] = function(item)
    if PLATFORM == "Windows" then
      system.exec(string.format("start \"\" %q", item.abs_filename))
    elseif string.find(PLATFORM, "Mac") then
      system.exec(string.format("open %q", item.abs_filename))
    elseif PLATFORM == "Linux" or string.find(PLATFORM, "BSD") then
      system.exec(string.format("xdg-open %q", item.abs_filename))
    end
  end
})

local projectsearch = pcall(require, "plugins.projectsearch")
if projectsearch then
  menu:register(function()
    local item = treeitem()
    return item and item.type == "dir"
  end, { 
    { text = "Find in directory", command = "treeview:search-in-directory" } 
  })
  command.add(function()
    return view.hovered_item and view.hovered_item.type == "dir"
  end, {
    ["treeview:search-in-directory"] = function(item)
      command.perform("project-search:find", view.hovered_item.abs_filename)
    end
  })
end

command.add(function()
    local item = treeitem()
    return item
           and not is_primary_project_folder(item.abs_filename)
           and is_project_folder(item.abs_filename), item
  end, {
  ["treeview:remove-project-directory"] = function(item)
    core.remove_project_directory(item.dir_name)
  end,
})


-- Status bar items while the treeview is focused: the selected entry (click to
-- copy its path), and how many files the project has

local function is_treeview_focused()
  return core.active_view == view
end

core.status_view:add_item({
  predicate = function()
    return is_treeview_focused() and view.selected_item ~= nil
  end,
  name = "treeview:selection",
  alignment = StatusView.Item.LEFT,
  get_item = function()
    local item = view.selected_item
    local name = item.depth > 0 and item.filename or item.name
    if item.type == "dir" then name = name .. PATHSEP end
    return { style.text, name }
  end,
  command = function()
    system.set_clipboard(view.selected_item.abs_filename)
    core.log("Copied %s", common.home_encode(view.selected_item.abs_filename))
  end,
  tooltip = function()
    return common.home_encode(view.selected_item.abs_filename) .. " (click to copy the path)"
  end,
})

-- files (not folders) in each project directory, cached until they change
local file_counts = setmetatable({}, { __mode = "k" })
local function count_files(dir)
  local c = file_counts[dir]
  if c and c.files == dir.files and c.change_id == dir.files_change_id then
    return c.n
  end
  local n = 0
  for _, info in ipairs(dir.files or {}) do
    if info.type == "file" then n = n + 1 end
  end
  file_counts[dir] = { files = dir.files, change_id = dir.files_change_id, n = n }
  return n
end

local function any_files_limit()
  for _, dir in ipairs(core.project_directories) do
    if dir.files_limit then return true end
  end
  return false
end

core.status_view:add_item({
  predicate = is_treeview_focused,
  name = "treeview:files",
  alignment = StatusView.Item.RIGHT,
  get_item = function()
    local n = 0
    for _, dir in ipairs(core.project_directories) do n = n + count_files(dir) end
    if any_files_limit() then
      return { style.warn, style.icon_font, "!", style.font,
        " " .. common.format_count(n) .. "+ files (not all indexed)" }
    end
    return { style.text, common.format_count(n) .. (n == 1 and " file" or " files") }
  end,
  tooltip = function()
    local lines = {}
    for _, dir in ipairs(core.project_directories) do
      table.insert(lines, string.format("%s: %s files", common.basename(dir.name),
        common.format_count(count_files(dir))))
      if dir.files_limit then
        table.insert(lines, dir.slow_filesystem
          and "  Filesystem too slow: only opened folders are scanned"
          or string.format("  Over max_project_files (%d): only opened folders are scanned,",
            config.max_project_files))
        table.insert(lines, "  so Find File and project search miss files")
      end
    end
    return table.concat(lines, "\n")
  end,
})


keymap.add {
  ["ctrl+\\"]     = "treeview:toggle",
  ["up"]          = "treeview:previous",
  ["down"]        = "treeview:next",
  ["left"]        = "treeview:collapse",
  ["right"]       = "treeview:expand",
  ["return"]      = "treeview:open",
  ["escape"]      = "treeview:deselect",
  ["delete"]      = "treeview:delete",
  ["ctrl+return"] = "treeview:new-folder",
  ["lclick"]      = "treeview:select-and-open",
  ["mclick"]      = "treeview:select",
  ["ctrl+lclick"] = "treeview:toggle-expand-all"
}

-- The config specification used by gui generators
config.plugins.treeview.config_spec = {
  name = "Treeview",
  {
    label = "Size",
    description = "Default treeview width.",
    path = "size",
    type = "number",
    default = toolbar_view and math.ceil(toolbar_view:get_min_width() / SCALE)
      or 200 * SCALE,
    min = toolbar_view and toolbar_view:get_min_width() / SCALE
      or 200 * SCALE,
    get_value = function(value)
      return value / SCALE
    end,
    set_value = function(value)
      return value * SCALE
    end,
    on_apply = function(value)
      view:set_target_size("x", math.max(
        value, toolbar_view and toolbar_view:get_min_width() or 200 * SCALE
      ))
    end
  },
  {
    label = "Hide on Startup",
    description = "Show or hide the treeview on startup.",
    path = "visible",
    type = "toggle",
    default = false,
    on_apply = function(value)
      view.visible = not value
    end
  }
}

table.insert(RootView.tab_menu_items, {
  text = "Show in File Browser",
  show = function(_, v) return v.doc and v.doc.abs_filename end,
  command = function(_, v) view:reveal(v.doc.abs_filename) end,
})

-- Return the treeview with toolbar and contextmenu to allow
-- user or plugin modifications
view.toolbar = toolbar_view
view.contextmenu = menu

return view
