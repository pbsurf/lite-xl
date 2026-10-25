local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local LogView = require "core.logview"
local View = require "core.view"
local Object = require "core.object"
local ContextMenu = require "core.contextmenu"
local RootView = require "core.rootview"
local tooltip = require "core.tooltip"


---Text drawn with a vertical offset, in pixels (negative raises it): for a glyph
---that sits off the text's line, like a pilcrow.
---@class core.statusview.offsettext
---@field text string
---@field y number

---@alias core.statusview.styledtext table<integer, renderer.font|renderer.color|string|core.statusview.offsettext>
---@alias core.statusview.position '"left"' | '"right"'

---A status bar implementation for lite, check core.status_view.
---@class core.statusview : core.view
---@field super core.view
---@field items core.statusview.item[]
---@field active_items core.statusview.item[]
---@field hovered_item core.statusview.item
---@field message_timeout number
---@field message? { icon: string, color: renderer.color, text: string }
---@field log_alert? "WARN"|"ERROR" worst level logged since the log was last viewed
---@field tooltip_mode boolean
---@field tooltip core.statusview.styledtext
---@field left_width number
---@field right_width number
---@field pressed_item core.statusview.item | nil @The item the mouse was pressed on.
---@field menu core.statusview.menu
---@field hide_messages boolean
local StatusView = View:extend()

---The menu opened from an item, see `core.statusview.item.options.menu`.
---@class core.statusview.menu : core.contextmenu
---@field item core.statusview.item | nil @The item it was opened from.
local StatusMenu = ContextMenu:extend()

function StatusView:__tostring() return "StatusView" end

---Space separator
---@type string
StatusView.separator  = "      "

---Pipe separator
---@type string
StatusView.separator2 = "   |   "

---@alias core.statusview.item.separator
---|>`StatusView.separator`
---| `StatusView.separator2`

---@alias core.statusview.item.predicate fun():boolean
---@alias core.statusview.item.onclick fun(button: string, x: number, y: number)
---@alias core.statusview.item.get_item fun(self: core.statusview.item):core.statusview.styledtext?,core.statusview.styledtext?
---@alias core.statusview.item.ondraw fun(x, y, h, hovered: boolean, calc_only?: boolean):number
---@alias core.statusview.item.tooltip fun(self: core.statusview.item):string
---@alias core.statusview.item.menu fun(self: core.statusview.item):core.contextmenu.item[]

---@class core.statusview.item : core.object
---@field name string
---@field predicate core.statusview.item.predicate
---@field alignment core.statusview.item.alignment
---@field tooltip string | core.statusview.item.tooltip
---@field priority number
---@field command string | nil @Command to perform when the item is clicked.
---@field menu core.statusview.item.menu | nil @Rows of the menu a click opens.
---Function called when item is clicked and no command is set.
---@field on_click core.statusview.item.onclick | nil
---Custom drawing that when passed calc true should return the needed width for
---drawing and when false should draw.
---@field on_draw core.statusview.item.ondraw | nil
---@field background_color renderer.color | nil
---@field background_color_hover renderer.color | nil
---@field visible boolean
---@field separator core.statusview.item.separator
---@field active boolean
---@field x number
---@field w number
---@field cached_item core.statusview.styledtext
local StatusViewItem = Object:extend()

function StatusViewItem:__tostring() return "StatusViewItem" end

---Available StatusViewItem options.
---@class core.statusview.item.options : table
---A condition to evaluate if the item should be displayed. If a string
---is given it is treated as a require import that should return a valid object
---which is checked against the current active view, the sames applies if a
---table is given. A function that returns a boolean can be used instead to
---perform a custom evaluation, setting to nil means always evaluates to true.
---@field predicate string | table | core.statusview.item.predicate
---A unique name to identify the item on the status bar.
---@field name string @A unique name to identify the item on the status bar.
---@field alignment core.statusview.item.alignment
---A function that should return a core.statusview.styledtext element,
---returning an empty table is allowed.
---@field get_item core.statusview.item.get_item
---The name of a valid registered command or a callback function to execute
---when the item is clicked.
---@field command string | core.statusview.item.onclick | nil
---The position in which to insert the given item on the internal table,
---a value of -1 inserts the item at the end which is the default. A value
---of 1 will insert the item at the beggining.
---@field position? integer
---Text displayed when mouse hovers the item, or a function returning it.
---@field tooltip? string | core.statusview.item.tooltip
---When the items don't fit in the status bar, those with the lowest priority
---are left out (of equal ones, the furthest from their edge of the bar).
---Defaults to 0.
---@field priority? number
---A function returning the rows of a menu to open above the item when it's
---clicked (instead of `command`), as for `core.contextmenu`.
---@field menu? core.statusview.item.menu
---@field visible boolean @Flag to show or hide the item
---The type of separator rendered to the right of the item if another item
---follows it.
---@field separator? core.statusview.item.separator

---Flag to tell the item should me aligned on left side of status bar.
---@type integer
StatusViewItem.LEFT = 1

---Flag to tell the item should me aligned on right side of status bar.
---@type integer
StatusViewItem.RIGHT = 2

---@alias core.statusview.item.alignment
---|>`StatusView.Item.LEFT`
---| `StatusView.Item.RIGHT`

---Constructor
---@param options core.statusview.item.options
function StatusViewItem:new(options)
  self:set_predicate(options.predicate)
  self.name = options.name
  self.alignment = options.alignment or StatusView.Item.LEFT
  self.command = type(options.command) == "string" and options.command or nil
  self.tooltip = options.tooltip or ""
  self.priority = options.priority or 0
  self.menu = options.menu
  self.on_click = type(options.command) == "function" and options.command or nil
  self.on_draw = nil
  self.background_color = nil
  self.background_color_hover = nil
  self.visible = options.visible == nil and true or options.visible
  self.active = false
  self.x = 0
  self.w = 0
  self.separator = options.separator or StatusView.separator
  self.get_item = options.get_item
end

---Called by the status bar each time that the item needs to be rendered,
---if on_draw() is set this function is obviated.
---@return core.statusview.styledtext
function StatusViewItem:get_item() return {} end

---Do not show the item on the status bar.
function StatusViewItem:hide() self.visible = false end

---Show the item on the status bar.
function StatusViewItem:show() self.visible = true end

---A condition to evaluate if the item should be displayed. If a string
---is given it is treated as a require import that should return a valid object
---which is checked against the current active view, the sames applies if a
---table is given. A function that returns a boolean can be used instead to
---perform a custom evaluation, setting to nil means always evaluates to true.
---@param predicate string | table | core.statusview.item.predicate
function StatusViewItem:set_predicate(predicate)
  self.predicate = command.generate_predicate(predicate)
end

---@type core.statusview.item
StatusView.Item = StatusViewItem


---Predicated used on the default docview widgets.
---@return boolean
local function predicate_docview()
  return  core.active_view:is(DocView)
    and not core.active_view:is(CommandView)
end


---Constructor
function StatusView:new()
  StatusView.super.new(self)
  self.message_timeout = 0
  self.message = nil
  self.log_alert = nil
  self.tooltip_mode = false
  self.tooltip = {}
  self.items = {}
  self.active_items = {}
  self.hovered_item = {}
  self.pointer = {x = 0, y = 0}
  self.left_width = 0
  self.right_width = 0
  self.pressed_item = nil
  self.menu = StatusMenu()
  self.hide_messages = false
  self.visible = true

  self:register_log_item()
  self:register_docview_items()
  self:register_command_items()
end


---The log's item, first on the left: messages pop up above it (show_message),
---and it has the warning or error icon and color while there are ones not yet
---viewed.
function StatusView:register_log_item()
  self:add_item({
    name = "core:log",
    alignment = StatusView.Item.LEFT,
    priority = 20,
    get_item = function()
      if core.active_view:is(LogView) then self.log_alert = nil end
      local alert = self.log_alert and style.log[self.log_alert]
      return { alert and alert.color or style.text, style.icon_font,
        alert and alert.icon or "i", style.font }
    end,
    tooltip = function()
      local last = self.message and self.message.text
      return (last and last .. "\n" or "") .. "Click to open the log"
    end,
    command = "core:open-log",
  })
end

---The cursor's line and column, counting a tab as `indent_size` columns.
---@param dv core.docview
---@return integer line, integer col
local function get_position(dv)
  local line, col = dv.doc:get_selection()
  local _, indent_size = dv.doc:get_indent_info()
  -- Calculating tabs when the doc is using the "hard" indent type.
  local ntabs = 0
  local last_idx = 0
  while last_idx < col do
    local s, e = string.find(dv.doc.lines[line], "\t", last_idx, true)
    if s and s < col then
      ntabs = ntabs + 1
      last_idx = e + 1
    else
      break
    end
  end
  return line, col + ntabs * (indent_size - 1)
end


---The predefined status bar items displayed when a document view is active.
function StatusView:register_docview_items()
  if self:get_item("doc:position") then return end

  self:add_item({
    predicate = predicate_docview,
    name = "doc:position",
    alignment = StatusView.Item.LEFT,
    priority = 10,
    get_item = function()
      local line, col = get_position(core.active_view)
      return {
        style.text, line, ":",
        col > config.line_limit and style.accent or style.text, col,
      }
    end,
    command = "doc:go-to-line",
    tooltip = function()
      local dv = core.active_view
      local line, col = get_position(dv)
      return string.format("Line %d of %d (%.f%%), column %d",
        line, #dv.doc.lines, line / #dv.doc.lines * 100, col)
    end
  })

  -- Indentation and line endings: shown when they differ from the defaults,
  -- set from the menu
  self:add_item({
    predicate = predicate_docview,
    name = "doc:format",
    alignment = StatusView.Item.RIGHT,
    priority = -10,
    get_item = function()
      local doc = core.active_view.doc
      local indent_type, indent_size = doc:get_indent_info()
      -- a pilcrow, the usual symbol for formatting marks (the gear suggests settings);
      -- it hangs below the baseline, so it's raised to center it on the capitals
      local t = { style.text, style.font,
        { text = "¶", y = -math.floor(style.font:get_size() * 0.11 + 0.5) } }
      if indent_type ~= config.tab_type or indent_size ~= config.indent_size then
        table.insert(t, (indent_type == "hard" and "  tabs: " or "  spaces: ") .. indent_size)
      end
      if doc.crlf then table.insert(t, "  CRLF") end
      return t
    end,
    tooltip = function()
      local doc = core.active_view.doc
      local indent_type, indent_size, indent_confirmed = doc:get_indent_info()
      local indent = indent_type == "hard"
        and string.format("tabs, %d wide", indent_size)
        or string.format("%d spaces", indent_size)
      return string.format("Indent: %s%s, line endings: %s", indent,
        indent_confirmed and "" or " (default)", doc.crlf and "CRLF" or "LF")
    end,
    menu = function()
      local doc = core.active_view.doc
      local indent_type, indent_size = doc:get_indent_info()
      return {
        { text = "Indent size: " .. indent_size, command = "indent:set-file-indent-size" },
        { text = "Indent type: " .. (indent_type == "hard" and "tabs" or "spaces"),
          command = "indent:set-file-indent-type" },
        { text = "Line endings: " .. (doc.crlf and "CRLF" or "LF"),
          command = "doc:toggle-line-ending" },
      }
    end
  })
end


---The predefined status bar items displayed when a command view is active.
function StatusView:register_command_items()
  if self:get_item("command:files") then return end

  self:add_item({
    predicate = "core.commandview",
    name = "command:files",
    alignment = StatusView.Item.RIGHT,
    get_item = function()
      return {
        style.icon_font, "g",
        style.font, style.dim, self.separator2,
        style.text, #core.docs, style.text, " / ",
        #core.project_files, " files"
      }
    end,
    tooltip = function()
      local docs = string.format("%d open document%s", #core.docs,
        #core.docs == 1 and "" or "s")
      local n = core.project_files_number()
      if n then
        return string.format("%s, %d project files (what the file finder searches)",
          docs, n)
      end
      for _, dir in ipairs(core.project_directories) do
        if dir.files_limit and dir.scan then
          return docs .. "; indexing project files: the file finder searches those found so far"
        end
      end
      return docs .. "; project too large to index (see \"Core: Index Project\"): files are "
        .. "counted in expanded folders only, and the file finder falls back to Open File"
    end
  })
end


---Set a position to the best match according to total available items.
---@param self core.statusview
---@param position integer
---@param alignment core.statusview.item.alignment
---@return integer position
local function normalize_position(self, position, alignment)
  local offset = 0
  local items_count = 0
  local left = self:get_items_list(1)
  local right = self:get_items_list(2)
  if alignment == 2 then
    items_count = #right
    offset = #left
  else
    items_count = #left
  end
  if position == 0 then
    position = offset +  1
  elseif position < 0 then
    position = offset + items_count + (position + 2)
  else
    position = offset + position
  end
  if position < 1 then
    position = offset + 1
  elseif position > #left + #right then
    position = offset + items_count + 1
  end
  return position
end


---Adds an item to be rendered in the status bar.
---@param options core.statusview.item.options
---@return core.statusview.item
function StatusView:add_item(options)
  assert(self:get_item(options.name) == nil, "status item already exists: " .. options.name)
  ---@type core.statusview.item
  local item = StatusView.Item(options)
  table.insert(self.items, normalize_position(self, options.position or -1, options.alignment), item)
  return item
end


---Get an item object associated to a name or nil if not found.
---@param name string
---@return core.statusview.item | nil
function StatusView:get_item(name)
  for _, item in ipairs(self.items) do
    if item.name == name then return item end
  end
  return nil
end


---Get a list of items.
---@param alignment? core.statusview.item.alignment
---@return core.statusview.item[]
function StatusView:get_items_list(alignment)
  if alignment then
    local items = {}
    for _, item in ipairs(self.items) do
      if item.alignment == alignment then
        table.insert(items, item)
      end
    end
    return items
  end
  return self.items
end


---Move an item to a different position.
---@param name string
---@param position integer Can be negative value to position in reverse order
---@param alignment? core.statusview.item.alignment
---@return boolean moved
function StatusView:move_item(name, position, alignment)
  assert(name, "no name provided")
  assert(position, "no position provided")
  local item = nil
  for pos, it in ipairs(self.items) do
    if it.name == name then
      item = table.remove(self.items, pos)
      break
    end
  end
  if item then
    if alignment then
      item.alignment = alignment
    end
    position = normalize_position(self, position, item.alignment)
    table.insert(self.items, position, item)
    return true
  end
  return false
end


---Remove an item from the status view.
---@param name string
---@return core.statusview.item removed_item
function StatusView:remove_item(name)
  local item = nil
  for pos, it in ipairs(self.items) do
    if it.name == name then
      item = table.remove(self.items, pos)
      break
    end
  end
  return item
end


---Order the items by name
---@param names table<integer, string>
function StatusView:order_items(names)
  local removed_items = {}
  for _, name in ipairs(names) do
    local item = self:remove_item(name)
    if item then table.insert(removed_items, item) end
  end

  for i, item in ipairs(removed_items) do
    table.insert(self.items, i, item)
  end
end


---Hide the status bar
function StatusView:hide()
  self.visible = false
end


---Show the status bar
function StatusView:show()
  self.visible = true
end


---Toggle the visibility of the status bar
function StatusView:toggle()
  self.visible = not self.visible
end


---Hides the given items from the status view or all if no names given.
---@param names? table<integer, string> | string
function StatusView:hide_items(names)
  if type(names) == "string" then
    names = {names}
  end
  if not names then
    for _, item in ipairs(self.items) do
      item:hide()
    end
    return
  end
  for _, name in ipairs(names) do
    local item = self:get_item(name)
    if item then item:hide() end
  end
end


---Shows the given items from the status view or all if no names given.
---@param names? table<integer, string> | string
function StatusView:show_items(names)
  if type(names) == "string" then
    names = {names}
  end
  if not names then
    for _, item in ipairs(self.items) do
      item:show()
    end
    return
  end
  for _, name in ipairs(names) do
    local item = self:get_item(name)
    if item then item:show() end
  end
end


---Shows a message above the log's item for config.message_timeout.
---@param icon string
---@param icon_color renderer.color
---@param text string
function StatusView:show_message(icon, icon_color, text)
  if not self.visible or self.hide_messages then return end
  self.message = { icon = icon, color = icon_color, text = text }
  local timeout = system.get_time() + config.message_timeout
  self.message_timeout = timeout
  core.redraw = true
  core.add_thread(function()
    coroutine.yield(config.message_timeout)
    if self.message_timeout == timeout then core.redraw = true end
  end)
end


---Hides the message shown above the log's item, if any.
function StatusView:hide_message()
  if self.message_timeout > 0 then
    self.message_timeout = 0
    core.redraw = true
  end
end


---Draws the message shown above the log's item, on one line, shortened to fit.
function StatusView:draw_message()
  local item = self:get_item("core:log")
  if not item.active then return end
  local m = self.message
  core.root_view:defer_draw(function()
    local pad = style.padding
    local iw = style.icon_font:get_width(m.icon) + pad.x
    local max_w = self.size.x - iw - pad.x * 4
    local text = m.text:match("^[^\n]*")
    if style.font:get_width(text) > max_w then
      while #text > 0 and style.font:get_width(text .. "…") > max_w do
        text = text:sub(1, -2)
      end
      text = text .. "…"
    end
    local w = iw + style.font:get_width(text) + pad.x * 2
    local h = style.font:get_height() + pad.y * 2
    local x = math.min(item.x, self.position.x + self.size.x - w - pad.x)
    local y = self.position.y - h - pad.y
    common.draw_popup_box(x, y, w, h)
    local tx = x + pad.x
    tx = renderer.draw_text(style.icon_font, m.icon, tx, y + pad.y, m.color) + pad.x
    renderer.draw_text(style.font, text, tx, y + pad.y, style.text)
  end)
end


---Enable or disable system wide messages on the status bar.
---@param enable boolean
function StatusView:display_messages(enable)
  self.hide_messages = not enable
end


---Activates tooltip mode displaying only the given
---text until core.statusview:remove_tooltip() is called.
---@param text string | core.statusview.styledtext
function StatusView:show_tooltip(text)
  self.tooltip = type(text) == "table" and text or { text }
  self.tooltip_mode = true
end


---Deactivates tooltip mode.
function StatusView:remove_tooltip()
  self.tooltip_mode = false
end


---Helper function to draw the styled text.
---@param self core.statusview
---@param items core.statusview.styledtext
---@param x number
---@param y number
---@param draw_fn fun(font,color,text,align, x,y,w,h):number
local function draw_items(self, items, x, y, draw_fn)
  local font = style.font
  local color = style.text

  for _, item in ipairs(items) do
    if Object.is(item, renderer.font) then
      font = item
    elseif type(item) == "table" and item.text then
      x = draw_fn(font, color, item.text, nil, x, y + item.y, 0, self.size.y)
    elseif type(item) == "table" then
      color = item
    else
      x = draw_fn(font, color, item, nil, x, y, 0, self.size.y)
    end
  end

  return x
end


---Helper function to calculate the width of text by using it as part of
---the helper function draw_items().
---@param font renderer.font
---@param text string
---@param x number
local function text_width(font, _, text, _, x)
  return x + font:get_width(text)
end


---Draws a table of styled text on the status bar starting on the left or right.
---@param items core.statusview.styledtext
---@param right_align? boolean
---@param xoffset? number
---@param yoffset? number
function StatusView:draw_items(items, right_align, xoffset, yoffset)
  local x, y = self:get_content_offset()
  x = x + (xoffset or 0)
  y = y + (yoffset or 0)
  if right_align then
    local w = draw_items(self, items, 0, 0, text_width)
    x = x + self.size.x - w - style.padding.x
    draw_items(self, items, x, y, common.draw_text)
  else
    x = x + style.padding.x
    draw_items(self, items, x, y, common.draw_text)
  end
end


---Draw the tooltip of a given status bar item.
---@param item core.statusview.item
function StatusView:draw_item_tooltip(item)
  local text = item.tooltip
  if type(text) == "function" then text = text(item) end
  if not text or text == "" then return end
  core.root_view:defer_draw(function()
    -- one line per "\n"
    local lines, w = {}, 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
      table.insert(lines, line)
      w = math.max(w, style.font:get_width(line))
    end
    local lh = style.font:get_height()
    local h = lh * #lines
    local x = self.pointer.x - (w / 2) - (style.padding.x * 2)

    if (x + w + (style.padding.x * 3)) > self.size.x then
      x = self.size.x - w - (style.padding.x * 3)
    end
    if x < 0 then x = 0 end

    local y = self.position.y - h - (style.padding.y * 2)
    common.draw_popup_box(
      x + style.padding.x,
      y,
      w + (style.padding.x * 2),
      h + (style.padding.y * 2)
    )

    for i, line in ipairs(lines) do
      renderer.draw_text(
        style.font,
        line,
        x + (style.padding.x * 2),
        y + style.padding.y + (i - 1) * lh,
        style.text
      )
    end
  end)
end


---Older method of retrieving the status bar items and which is now
---deprecated in favour of core.status_view:add_item().
---@deprecated
---@param nowarn boolean
---@return table left
---@return table right
function StatusView:get_items(nowarn)
  if not nowarn and not self.get_items_warn then
    core.warn(
      "Overriding StatusView:get_items() is deprecated, "
      .. "use core.status_view:add_item() instead."
    )
    self.get_items_warn = true
  end
  return {"{:dummy:}"}, {"{:dummy:}"}
end


---Helper function to copy a styled text table into another.
---@param t1 core.statusview.styledtext
---@param t2 core.statusview.styledtext
local function table_add(t1, t2)
  for _, value in ipairs(t2) do
    table.insert(t1, value)
  end
end


---Helper function to merge deprecated items to a temp items table.
---@param destination table
---@param items core.statusview.styledtext
---@param alignment core.statusview.item.alignment
local function merge_deprecated_items(destination, items, alignment)
  local start = true
  local items_start, items_end = {}, {}
  for i, value in ipairs(items) do
    if value ~= "{:dummy:}" then
      if start then
        table.insert(items_start, i, value)
      else
        table.insert(items_end, value)
      end
    else
      start = false
    end
  end

  local position = alignment == StatusView.Item.LEFT and "left" or "right"

  local item_start = StatusView.Item({
    name = "deprecated:"..position.."-start",
    alignment = alignment,
    get_item = items_start
  })

  local item_end = StatusView.Item({
    name = "deprecated:"..position.."-end",
    alignment = alignment,
    get_item = items_end
  })

  table.insert(destination, 1, item_start)
  table.insert(destination, item_end)
end


---Append a space item into the given items list.
---@param self core.statusview
---@param destination core.statusview.item[]
---@param separator string
---@param alignment core.statusview.item.alignment
---@return core.statusview.item
local function add_spacing(self, destination, separator, alignment, x)
  ---@type core.statusview.item
  local space = StatusView.Item({name = "space", alignment = alignment})
  space.cached_item = separator == self.separator and {
    style.text, separator
  } or {
    style.dim, separator
  }
  space.x = x
  space.w = draw_items(self, space.cached_item, 0, 0, text_width)

  table.insert(destination, space)

  return space
end


---Remove starting and ending separators.
---@param self core.statusview
---@param styled_text core.statusview.styledtext
local function remove_spacing(self, styled_text)
  if
    not Object.is(styled_text[1], renderer.font)
    and
    type(styled_text[1]) == "table"
    and
    (
      styled_text[2] == self.separator
      or
      styled_text[2] == self.separator2
    )
  then
    table.remove(styled_text, 1)
    table.remove(styled_text, 1)
  end

  if
    not Object.is(styled_text[#styled_text-1], renderer.font)
    and
    type(styled_text[#styled_text-1]) == "table"
    and
    (
      styled_text[#styled_text] == self.separator
      or
      styled_text[#styled_text] == self.separator2
    )
  then
    table.remove(styled_text, #styled_text)
    table.remove(styled_text, #styled_text)
  end
end


---Positions the given items: left ones from the left edge of the status bar,
---right ones up to its right edge, with separators between the items of a side.
---@param self core.statusview
---@param items core.statusview.item[]
---@return core.statusview.item[] active_items The items and separators.
---@return number left_width
---@return number right_width
local function layout_items(self, items)
  local x = self:get_content_offset()
  local active_items = {}
  local width = { [StatusView.Item.LEFT] = 0, [StatusView.Item.RIGHT] = 0 }
  for _, item in ipairs(items) do
    local w = width[item.alignment]
    if w > 0 then
      local space = add_spacing(self, active_items, item.separator, item.alignment, w)
      w = w + space.w
    end
    item.x = w
    width[item.alignment] = w + item.w
    table.insert(active_items, item)
  end
  local lw, rw = width[StatusView.Item.LEFT], width[StatusView.Item.RIGHT]
  for _, item in ipairs(active_items) do
    if item.alignment == StatusView.Item.LEFT then
      item.x = x + item.x
    else
      item.x = x + self.size.x - rw - style.padding.x * 2 + item.x
    end
  end
  return active_items, lw, rw
end


---Set the active items that will be displayed on the left or right side
---of the status bar checking their predicates and performing positioning
---calculations for proper functioning of tooltips and clicks. Items that
---don't fit are left out, by priority.
function StatusView:update_active_items()
  ---@type core.statusview.item[]
  local combined_items = {}
  table_add(combined_items, self.items)

  -- load deprecated items for compatibility
  local dleft, dright = self:get_items(true)
  merge_deprecated_items(combined_items, dleft, StatusView.Item.LEFT)
  merge_deprecated_items(combined_items, dright, StatusView.Item.RIGHT)

  -- measure the items to show
  local items = {}
  for _, item in ipairs(combined_items) do
    item.active = false
    item.cached_item = {}
    if item.visible and item:predicate() then
      local styled_text = type(item.get_item) == "function"
        and item.get_item(item) or item.get_item

      if #styled_text > 0 then
        remove_spacing(self, styled_text)
      end

      if #styled_text > 0 or item.on_draw then
        local hovered = self.hovered_item == item
        item.w = item.on_draw and
          item.on_draw(0, self.position.y, self.size.y, hovered, true)
          or
          draw_items(self, styled_text, 0, 0, text_width)
        item.cached_item = styled_text
        table.insert(items, item)
      end
    end
  end

  -- leave out items until the rest fit: the lowest priority first and, of
  -- equal ones, the one furthest from its edge of the bar
  local active_items, lw, rw = layout_items(self, items)
  local function fits()
    -- padding at both edges, and between the sides if both have items
    local gap = (lw > 0 and rw > 0) and style.padding.x * 2 or 0
    return lw + rw + gap + style.padding.x * 2 <= self.size.x
  end
  while #items > 0 and not fits() do
    local drop, drop_distance
    for i, item in ipairs(items) do
      local distance = item.alignment == StatusView.Item.LEFT
        and item.x + item.w
        or self.size.x - item.x
      if not drop or item.priority < items[drop].priority
        or (item.priority == items[drop].priority and distance > drop_distance)
      then
        drop, drop_distance = i, distance
      end
    end
    table.remove(items, drop)
    active_items, lw, rw = layout_items(self, items)
  end

  for _, item in ipairs(items) do item.active = true end
  self.active_items = active_items
  self.left_width, self.right_width = lw, rw
end


---The area an active item takes on the screen.
---@param item core.statusview.item
---@return number x
---@return number w
function StatusView:get_item_visible_area(item)
  return item.x + style.padding.x, item.w
end


---Opens the item's menu above it.
---@param item core.statusview.item
function StatusView:show_menu(item)
  local menu = self.menu
  menu.itemset = {}
  menu:register(nil, item.menu(item))
  local x, w = self:get_item_visible_area(item)
  if menu:show(x, self.position.y) then
    local mw, mh = menu.items.width, menu.items.height
    if item.alignment == StatusView.Item.RIGHT then x = x + w - mw end
    menu.position.x = common.clamp(x, 0, self.size.x - mw)
    menu.position.y = math.max(0, self.position.y - mh)
    menu.height = mh
    menu.item = item
    for i, row in ipairs(menu.items) do
      if row.active then menu.selected = i end
    end
  end
end


function StatusView:on_mouse_pressed(button, x, y, clicks)
  if not self.visible then return end
  core.set_active_view(core.last_active_view)
  if y >= self.position.y and self.hovered_item.active then
    self.pressed_item = self.hovered_item
  end
  return true
end


function StatusView:on_mouse_moved(x, y, dx, dy)
  if not self.visible then return end
  StatusView.super.on_mouse_moved(self, x, y, dx, dy)

  if y < self.position.y then
    self.cursor = "arrow"
    self.hovered_item = {}
    tooltip.hover(self, nil)
    return
  end

  for _, item in ipairs(self.items) do
    if
      item.visible and item.active
      and
      (item.command or item.on_click or item.menu or item.tooltip ~= "")
    then
      local item_x, item_w = self:get_item_visible_area(item)

      if x > item_x and (item_x + item_w) > x then
        self.pointer.x = x
        self.pointer.y = y
        if self.hovered_item ~= item then
          self.hovered_item = item
        end
        -- status bar tooltips show at once
        tooltip.hover(self, item.tooltip ~= "" and item or nil, 0)
        if item.command or item.on_click or item.menu then
          self.cursor = "hand"
        end
        return
      end
    end
  end
  self.cursor = "arrow"
  self.hovered_item = {}
  tooltip.hover(self, nil)
end


function StatusView:on_mouse_released(button, x, y)
  if not self.visible then return end
  StatusView.super.on_mouse_released(self, button, x, y)

  -- only a click that started on the item: not the release of the click that
  -- closed its menu
  local item = self.pressed_item
  self.pressed_item = nil
  if y < self.position.y or item ~= self.hovered_item or not item.active then
    return
  end

  if item.menu then
    if button == "left" then self:show_menu(item) end
  elseif item.command then
    command.perform(item.command)
  elseif item.on_click then
    item.on_click(button, x, y)
  end
end


function StatusView:update()
  if not self.visible and self.size.y <= 0 then
    return
  elseif not self.visible and self.size.y > 0 then
    self:move_towards(self.size, "y", 0, nil, "statusbar")
    return
  end

  local height = style.font:get_height() + style.padding.y;

  if self.size.y + 1 < height then
    self:move_towards(self.size, "y", height, nil, "statusbar")
  else
    self.size.y = height
  end

  StatusView.super.update(self)

  self:update_active_items()
  self.menu:update()
end


---Retrieve the hover status and proper background color if any.
---@param self core.statusview
---@param item core.statusview.item
---@return boolean is_hovered
---@return renderer.color | nil color
local function get_item_bg_color(self, item)
  local hovered = self.hovered_item == item or self.menu.item == item

  local item_bg = hovered
    and item.background_color_hover or item.background_color

  return hovered, item_bg
end


function StatusView:draw()
  if not self.visible and self.size.y <= 0 then return end

  self:draw_background(style.background2)

  if self.tooltip_mode then
    self:draw_items(self.tooltip)
  end
  for _, item in ipairs(self.active_items) do
    local item_x = item.x + style.padding.x
    local hovered, item_bg = get_item_bg_color(self, item)
    if item.alignment == StatusView.Item.RIGHT or not self.tooltip_mode then
      if type(item_bg) == "table" then
        renderer.draw_rect(
          item_x, self.position.y,
          item.w, self.size.y, item_bg
        )
      end
      if item.on_draw then
        core.push_clip_rect(item_x, self.position.y, item.w, self.size.y)
        item.on_draw(item_x, self.position.y, self.size.y, hovered)
        core.pop_clip_rect()
      else
        self:draw_items(item.cached_item, false, item_x - style.padding.x)
      end
    end
  end

  -- draw tooltip; the log item's has the message, which it replaces
  local item_tooltip = self.hovered_item.active and not self.menu.show_context_menu
    and tooltip.shown(self, self.hovered_item)
  if item_tooltip then
    self:draw_item_tooltip(self.hovered_item)
  end
  if self.message and system.get_time() <= self.message_timeout
    and not (item_tooltip and self.hovered_item.name == "core:log") then
    self:draw_message()
  end
  self.menu:draw()
end


-- The menu opened from an item gets mouse events first while shown: a click
-- anywhere closes it, choosing the row under the mouse, if any
local root_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  local menu = core.status_view and core.status_view.menu
  if not (menu and menu.show_context_menu) then
    return root_on_mouse_pressed(self, button, x, y, clicks)
  end
  local mx, my = menu.position.x, menu.position.y
  if x < mx or x >= mx + menu.items.width or y < my or y >= my + menu.items.height then
    menu.selected = -1
  end
  return menu:on_mouse_pressed(button, x, y, clicks)
end

local root_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, ...)
  local menu = core.status_view and core.status_view.menu
  if menu and menu:on_mouse_moved(x, y, ...) then return end
  return root_on_mouse_moved(self, x, y, ...)
end

function StatusMenu:hide()
  StatusMenu.super.hide(self)
  self.item = nil
end


return StatusView
