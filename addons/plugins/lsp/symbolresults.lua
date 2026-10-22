--
-- SymbolResults Widget/View.
-- @copyright Jefferson Gonzalez
-- @license MIT
--
-- A panel below the pane used last. Selecting a result (arrow keys, a click)
-- shows it in that pane, with the symbol's name selected, while the focus stays
-- here; Enter or a double click moves the focus there, Escape closes the panel.
--

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local Widget = require "libraries.widget"
local Label = require "libraries.widget.label"
local Line = require "libraries.widget.line"
local ListBox = require "libraries.widget.listbox"
local Server = require "plugins.lsp.server"
local util = require "plugins.lsp.util"

---@class lsp.symbolresults : widget
---@field public searching boolean
---@field public symbol string
---@field public generation integer Incremented by each search shown
---@field private title widget.label
---@field private line widget.line
---@field private list_container widget
---@field private list widget.listbox
local SymbolResults = Widget:extend()

---@type lsp.symbolresults?
local panel

function SymbolResults:new()
  SymbolResults.super.new(self)

  self.name = "Symbols Search"
  self.defer_draw = false

  self.title = Label(self, "")
  self.line = Line(self, 2, style.padding.x)

  self.list_container = Widget(self)
  self.list_container.border.width = 0
  self.list_container:set_size(200, 200)

  self.list = ListBox(self.list_container)
  self.list.border.width = 0

  self.list:enable_expand(true)
  self.list:add_column("Num.")
  self.list:add_column("Symbol")
  self.list:add_column("Kind")
  self.list:add_column("Location")

  self.list.on_row_click = function(_, idx, _, clicks)
    self:select(idx)
    if clicks > 1 then self:open_selected() end
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

---Shows the panel, cleared for a new search, and focuses it.
---@param symbol string
---@return lsp.symbolresults
function SymbolResults.open(symbol)
  if not panel then
    panel = SymbolResults()
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
  self.title:set_label("Searching symbols for: " .. symbol)
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

function SymbolResults:stop_searching()
  self.searching = false
end

---Opens a location in the pane used last, with the symbol's name selected (an
---unfocused view draws the selection, not the caret), leaving the focus as is.
---@return core.docview?
local function show_location(location)
  local av = core.active_view
  local dv
  core.try(function()
    core.set_active_view(core.root_view:get_last_used_node().active_view)
    local filename = common.home_expand(util.tofilename(location.uri))
    dv = core.root_view:open_doc(core.open_doc(filename), { preview = true })
    -- a WorkspaceSymbol (LSP 3.17) may give just the file
    if not location.range then return end
    local line1, col1, line2, col2 = util.toselection(location.range, dv.doc)
    -- just the start of a range over several lines
    if line2 ~= line1 then line2, col2 = line1, col1 end
    dv.doc:set_selection(line2, col2, line1, col1)
    dv:scroll_to_line(line1, true)
  end)
  core.set_active_view(av)
  return dv
end

---Selects a result (clamped to the list) and shows it.
---@param idx integer
function SymbolResults:select(idx)
  if #self.list.rows == 0 then return end
  idx = common.clamp(idx, 1, #self.list.rows)
  self.list:set_selected(idx)
  self.list:scroll_to_row(idx)
  self.shown = show_location(self.list:get_row_data(idx).location)
end

---Shows the selected result, or the first, and focuses it.
function SymbolResults:open_selected()
  if not self.list:get_selected() then self:select(1) end
  if self.shown then core.set_active_view(self.shown) end
end

function SymbolResults:close()
  local target = core.root_view:get_last_used_node()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then node:remove_view(core.root_view.root_node, self) end
  core.set_active_view(target.active_view)
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
  self.title:set_position(style.padding.x, style.padding.y)
  if not self.searching or #self.list.rows > 0 then
    local label = "Finished: "
    if self.searching then
      label = "Searching: "
    end
    self.title:set_label(
      label
        .. #self.list.rows
        .. " results found for "
        .. '"'
        .. self.symbol
        .. '"'
    )
  end
  self.line:set_position(0, self.title:get_bottom() + 10)
  self.list_container:set_position(style.padding.x, self.line:get_bottom() + 10)
  self.list_container:set_size(
    self.size.x - (style.padding.x * 2),
    self.size.y - self.line:get_bottom()
  )
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
  ["symbol-results:close"] = function(rs) rs:close() end,
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


return SymbolResults
