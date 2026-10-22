--
-- SymbolResults Widget/View.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
-- A panel below the pane used last. Selecting a result (arrow keys, a click)
-- shows it in that pane, with the symbol's name selected, while the focus stays
-- here; Enter or a double click moves the focus there, Escape closes the panel.
-- Its header's button moves it into a tab, keeping the results; the next search
-- opens a new panel. In a tab sharing a pane with the docs, showing a result
-- would hide the list, so there a click, double click or Enter opens it.
--
-- ReferenceResults, the same for the references to a symbol, is a subclass.
--

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local PanelHeader = require "core.panelheader"
local Widget = require "libraries.widget"
local ListBox = require "libraries.widget.listbox"
local Server = require "plugins.lsp.server"
local util = require "plugins.lsp.util"

---@class lsp.symbolresults : widget
---@field public searching boolean
---@field public symbol string
---@field public generation integer Incremented by each search shown
---@field private header core.panelheader
---@field private list_container widget
---@field private list widget.listbox
local SymbolResults = Widget:extend()

---The panel of each class (a subclass has its own), by class
---@type table<lsp.symbolresults, lsp.symbolresults>
local panels = {}

function SymbolResults:new()
  SymbolResults.super.new(self)

  self.name = "Symbols Search"
  self.defer_draw = false

  self.header = PanelHeader(self)
  -- moved into a tab: no longer the panel, which the next search opens anew
  self.header.on_move_to_tab = function()
    local class = getmetatable(self)
    if panels[class] == self then panels[class] = nil end
  end

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0

  self.list:enable_expand(true)
  self:add_columns()

  self.list.on_row_click = function(_, idx, _, clicks)
    self:select(idx)
    if clicks > 1 or not self:can_peek() then self:open_selected() end
  end

  -- valid before a first reset() too (e.g. made by an older workspace save)
  self.symbol = ""
  self.searching = false
  self.num = 1
  self.generation = 0
  self.border.width = 0
  self:set_size(200, 200)
  self:show()
end

function SymbolResults:add_columns()
  self.list:add_column("Num.")
  self.list:add_column("Symbol")
  self.list:add_column("Kind")
  self.list:add_column("Location")
end

---Shows the class's panel, cleared for a new search, and focuses it.
---Called on the class: `SymbolResults:open(symbol)`.
---@param symbol string
---@return lsp.symbolresults
function SymbolResults:open(symbol)
  local panel = panels[self]
  if not panel then
    panel = self()
    panels[self] = panel
    -- a third of the window at first; then as the user resizes it
    panel:set_size(nil, math.floor(core.root_view.size.y / 3))
  end
  if not core.root_view.root_node:get_node_for_view(panel) then
    core.root_view:get_last_used_node():split("down", panel, { y = true }, true)
  end
  panel:reset(symbol)
  core.set_active_view(panel)
  return panel
end

---@param symbol string
function SymbolResults:reset(symbol)
  self.symbol = symbol
  self.searching = true
  self.num = 1
  self.generation = self.generation + 1
  self.list:clear()
  self.list.scroll.x, self.list.scroll.to.x = 0, 0
  self.list.scroll.y, self.list.scroll.to.y = 0, 0
end

function SymbolResults:get_name()
  return "Symbols: " .. self.symbol
end

-- Not restored with the workspace: it would come back without its results
function SymbolResults:is_transient()
  return true
end

function SymbolResults:add_result(result)
  local preview, position = require("plugins.lsp").get_location_preview(result.location)
  local container_name = result.containerName and
    result.containerName .. "\n" or ""

  -- code (the symbol and the line it's on) in the code font
  local code_font = { container = style, name = "code_font" }
  local row = {
    tostring(self.num),
    ListBox.COLEND,
    code_font, style.syntax.keyword, container_name .. result.name,
    ListBox.COLEND,
    style.syntax.literal, Server.get_symbol_kind(result.kind),
    ListBox.COLEND,
    style.text, position, ListBox.NEWLINE,
    code_font, style.accent, preview
  }

  self.num = self.num + 1

  self.list:add_row(row, result)
end

---The header's text.
---@return string
function SymbolResults:get_status()
  if self.searching and #self.list.rows == 0 then
    return string.format("Searching symbols for %q...", self.symbol)
  end
  return string.format("%s %d results found for %q",
    self.searching and "Searching:" or "Finished:", #self.list.rows, self.symbol)
end

function SymbolResults:stop_searching()
  self.searching = false
end

---Shows a location in the pane used last (RootView:peek_file), with the
---symbol's name selected.
---@return core.docview?
local function show_location(location)
  local filename = common.home_expand(util.tofilename(location.uri))
  -- the doc converts the range's UTF-16 columns; peek_file logs a failed open
  local ok, doc = pcall(core.open_doc, filename)
  local line1, col1, line2, col2 = util.toselection(location.range, ok and doc or nil)
  -- just the start of a range over several lines
  if line2 ~= line1 then line2, col2 = line1, col1 end
  return core.root_view:peek_file(filename, line1, col1, line2, col2)
end

---Whether a result can be shown without hiding this list (in a tab sharing
---the docs' pane, it can't).
---@return boolean
function SymbolResults:can_peek()
  return core.root_view:can_peek(self)
end

---Selects a result (clamped to the list) and shows it, if that can be done
---without hiding the list.
---@param idx integer
function SymbolResults:select(idx)
  if #self.list.rows == 0 then return end
  idx = common.clamp(idx, 1, #self.list.rows)
  self.list:set_selected(idx)
  self.list:scroll_to_row(idx)
  self.shown = nil
  if self:can_peek() then
    self.shown = show_location(self.list:get_row_data(idx).location)
  end
end

---Shows the selected result, or the first, and focuses it.
function SymbolResults:open_selected()
  local idx = self.list:get_selected()
  if not idx then self:select(1) idx = self.list:get_selected() end
  if not idx then return end
  local dv = self.shown or show_location(self.list:get_row_data(idx).location)
  if dv then core.set_active_view(dv) end
end

---Results per page, by the first row's height (each is about as tall).
---@return integer
function SymbolResults:get_page_size()
  local row = self.list.rows[1]
  return row and math.max(1, math.floor(self.list.size.y / row.h) - 1) or 1
end

function SymbolResults:update()
  if not SymbolResults.super.update(self) then return end
  -- update the positions and sizes
  self.background_color = style.background
  self.header.text = self:get_status()
  local top = self.header:get_height()
  self.list_container:set_position(style.padding.x, top)
  self.list_container:set_size(
    self.size.x - (style.padding.x * 2),
    self.size.y - top
  )
end

function SymbolResults:draw()
  if not SymbolResults.super.draw(self) then return false end
  self.header:draw(self.position.x, self.position.y, self.size.x)
  return true
end

function SymbolResults:on_mouse_moved(x, y, ...)
  -- the widgets too, also when it's over the header: the list then learns the
  -- mouse left it
  local over_header = self.header:on_mouse_moved(x, y)
  return SymbolResults.super.on_mouse_moved(self, x, y, ...) or over_header
end

function SymbolResults:on_mouse_pressed(button, x, y, ...)
  if self.header:on_mouse_pressed(button, x, y) then return true end
  return SymbolResults.super.on_mouse_pressed(self, button, x, y, ...)
end

function SymbolResults:on_mouse_left()
  SymbolResults.super.on_mouse_left(self)
  self.header:on_mouse_left()
end

local function step(rs, n)
  local sel = rs.list:get_selected()
  rs:select(sel and sel + n or (n > 0 and 1 or #rs.list.rows))
end

command.add(SymbolResults, {
  ["symbol-results:select-previous"] = function(rs) step(rs, -1) end,
  ["symbol-results:select-next"] = function(rs) step(rs, 1) end,
  ["symbol-results:select-previous-page"] = function(rs) step(rs, -rs:get_page_size()) end,
  ["symbol-results:select-next-page"] = function(rs) step(rs, rs:get_page_size()) end,
  ["symbol-results:select-first"] = function(rs) rs:select(1) end,
  ["symbol-results:select-last"] = function(rs) rs:select(#rs.list.rows) end,
  ["symbol-results:open-selected"] = function(rs) rs:open_selected() end,
})

-- Escape closes the panel; a tab is closed as any other
command.add(function()
  return core.active_view:extends(SymbolResults) and core.active_view.header:is_panel(),
    core.active_view
end, {
  ["symbol-results:close"] = function(rs) rs.header:close() end,
})

keymap.add {
  ["up"] = "symbol-results:select-previous",
  ["down"] = "symbol-results:select-next",
  ["pageup"] = "symbol-results:select-previous-page",
  ["pagedown"] = "symbol-results:select-next-page",
  ["home"] = "symbol-results:select-first",
  ["end"] = "symbol-results:select-last",
  ["return"] = "symbol-results:open-selected",
  ["escape"] = "symbol-results:close",
}


---The references to a symbol: a row for each, its location and line of code.
---@class lsp.referenceresults : lsp.symbolresults
local ReferenceResults = SymbolResults:extend()

function ReferenceResults:new()
  ReferenceResults.super.new(self)
  self.name = "References"
end

function ReferenceResults:add_columns()
  self.list:add_column("Location")
  self.list:add_column("Code")
end

function ReferenceResults:get_name()
  return "References: " .. self.symbol
end

---@param location table An LSP Location
function ReferenceResults:add_result(location)
  local preview, position = require("plugins.lsp").get_location_preview(location)
  self.list:add_row({
    style.text, position,
    ListBox.COLEND,
    { container = style, name = "code_font" }, style.accent, preview
  }, { location = location })
end

function ReferenceResults:get_status()
  if self.searching and #self.list.rows == 0 then
    return string.format("Finding references to %q...", self.symbol)
  end
  return string.format("%s %d references to %q",
    self.searching and "Searching:" or "Finished:", #self.list.rows, self.symbol)
end

SymbolResults.ReferenceResults = ReferenceResults


return SymbolResults
