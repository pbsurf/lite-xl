--
-- SymbolResults Widget/View.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
-- A panel below the pane used last, to step through with the keyboard
-- (core.resultslist), the symbol's name selected in the file shown. Its
-- header's button moves it into a tab, keeping the results; the next search
-- opens a new panel. In a tab, the button moves it back, replacing the panel.
--
-- ReferenceResults, the same for the references to a symbol, is a subclass.
--

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local PanelHeader = require "core.panelheader"
local ResultsList = require "core.resultslist"
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

function SymbolResults:new()
  SymbolResults.super.new(self)

  self.name = "Symbols Search"
  self.defer_draw = false

  self.header = PanelHeader(self)

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0

  self.list:enable_expand(true)
  self:add_columns()

  self.list.on_row_click = function(_, idx, _, clicks)
    self:click_result(idx, clicks)
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

---Shows the class's panel (a subclass has its own), cleared for a new search,
---and focuses it. Called on the class: `SymbolResults:open(symbol)`.
---@param symbol string
---@return lsp.symbolresults
function SymbolResults:open(symbol)
  local panel = PanelHeader.get_panel(self) or self()
  panel.header:show_panel()
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

-- for core.resultslist: a result's range is the symbol's name (the start of a
-- range over several lines)
function SymbolResults:get_result_count() return #self.list.rows end

function SymbolResults:get_result_location(idx)
  local location = self.list:get_row_data(idx).location
  local filename = common.home_expand(util.tofilename(location.uri))
  -- the doc converts the range's UTF-16 columns; peek_file logs a failed open
  local ok, doc = pcall(core.open_doc, filename)
  local line1, col1, line2, col2 = util.toselection(location.range, ok and doc or nil)
  if line2 ~= line1 then line2, col2 = line1, col1 end
  return filename, line1, col1, line2, col2
end

function SymbolResults:get_selected_index() return self.list:get_selected() end

function SymbolResults:set_selected_index(idx)
  self.list:set_selected(idx)
  self.list:scroll_to_row(idx)
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

-- also for ReferenceResults, which extends it
ResultsList.add_to(SymbolResults, "symbol-results")


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
