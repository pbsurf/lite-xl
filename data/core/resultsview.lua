local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"
local ResultsList = require "core.resultslist"

---A list of places in files, one per row, as project search's results and
---lsp's references: each drawn as `path:line:col`, then the line's code with
---the match (the searched text, the reference) highlighted. Stepped through
---with the keyboard and peeked as core.resultslist describes; subclasses fill
---`self.results` (with ResultsView.make_result) and name the view.
---@class core.resultsview : core.view
---@field results core.resultsview.result[]
local ResultsView = View:extend()

function ResultsView:__tostring() return "ResultsView" end

ResultsView.context = "session"

---@class core.resultsview.result
---@field file string As given to RootView:peek_file
---@field line integer
---@field col integer
---@field col2? integer The column after the match, nil if unknown
---@field text string The line's code drawn: an excerpt, without indentation
---@field match1? integer The match's start in `text`
---@field match2? integer The position after the match in `text`

function ResultsView:new()
  ResultsView.super.new(self)
  self.scrollable = true
  self:clear()
end


---Removes all results, scrolled back to the start.
function ResultsView:clear()
  self.results = {}
  self.selected_idx = 0
  self.hovered_idx = 0
  self.max_h_scroll = 0
  self.scroll.x, self.scroll.to.x = 0, 0
  self.scroll.y, self.scroll.to.y = 0, 0
end


-- the excerpt's characters around the match: before it, and in all
local excerpt_before, excerpt_len = 80, 256

---A result at `line`, `col` (up to `col2`) in `file`, whose text is
---`line_text`: drawn without indentation, and cut around the match if long.
---@param file string
---@param line_text string
---@param line integer
---@param col integer
---@param col2? integer The column after the match
---@return core.resultsview.result
function ResultsView.make_result(file, line_text, line, col, col2)
  line_text = line_text:gsub("[\r\n]+$", "")
  local first = line_text:find("%S") or #line_text + 1
  local last = #line_text:match("^(.-)%s*$")
  local start = math.max(first, math.min(col, last + 1) - excerpt_before)
  local stop = math.min(last, start + excerpt_len - 1)
  -- whole UTF-8 characters
  while start > first and common.is_utf8_cont(line_text, start) do start = start - 1 end
  while stop < last and common.is_utf8_cont(line_text, stop + 1) do stop = stop + 1 end
  local prefix = start > first and "..." or ""
  local text = prefix .. line_text:sub(start, stop) .. (stop < last and "..." or "")
  local match1, match2
  if col2 and col2 > col then
    local offset = #prefix - start + 1
    match1 = common.clamp(col, start, stop + 1) + offset
    match2 = common.clamp(col2, start, stop + 1) + offset
  end
  return {
    file = file, line = line, col = col, col2 = col2,
    text = text, match1 = match1, match2 = match2
  }
end


function ResultsView:on_mouse_moved(mx, my, ...)
  ResultsView.super.on_mouse_moved(self, mx, my, ...)
  self.hovered_idx = 0
  for i, _, x,y,w,h in self:each_visible_result() do
    if mx >= x and my >= y and mx < x + w and my < y + h then
      self.hovered_idx = i
      break
    end
  end
end


function ResultsView:on_mouse_pressed(button, x, y, clicks)
  local caught = ResultsView.super.on_mouse_pressed(self, button, x, y, clicks)
  if not caught and button == "left" and self.hovered_idx > 0 then
    self:click_result(self.hovered_idx, clicks)
    return true
  end
end


function ResultsView:on_mouse_left()
  ResultsView.super.on_mouse_left(self)
  self.hovered_idx = 0
end


-- for core.resultslist: a result's range is the match (the line, if unknown)
function ResultsView:get_result_count() return #self.results end

function ResultsView:get_result_location(idx)
  local res = self.results[idx]
  return res.file, res.line, res.col, res.line, res.col2 or math.huge
end

function ResultsView:get_selected_index()
  return self.selected_idx > 0 and self.selected_idx or nil
end

function ResultsView:set_selected_index(idx)
  self.selected_idx = idx
  self:scroll_to_make_selected_visible()
end

function ResultsView:get_page_size()
  return math.max(1, math.floor(self.size.y / self:get_line_height()) - 1)
end


function ResultsView:get_line_height()
  return style.padding.y + math.max(style.font:get_height(), style.code_font:get_height())
end


function ResultsView:get_scrollable_size()
  return #self.results * self:get_line_height()
end


function ResultsView:get_h_scrollable_size()
  return self.max_h_scroll
end


function ResultsView:get_visible_results_range()
  local lh = self:get_line_height()
  local min = math.max(1, math.floor(self.scroll.y / lh))
  return min, min + math.floor(self.size.y / lh) + 1
end


function ResultsView:each_visible_result()
  return coroutine.wrap(function()
    local lh = self:get_line_height()
    local x, y = self:get_content_offset()
    local min, max = self:get_visible_results_range()
    y = y + lh * (min - 1)
    for i = min, max do
      local item = self.results[i]
      if not item then break end
      local _, _, w = self:get_content_bounds()
      coroutine.yield(i, item, x, y, w, lh)
      y = y + lh
    end
  end)
end


function ResultsView:scroll_to_make_selected_visible()
  local h = self:get_line_height()
  local y = h * (self.selected_idx - 1)
  self.scroll.to.y = math.min(self.scroll.to.y, y)
  self.scroll.to.y = math.max(self.scroll.to.y, y + h - self.size.y)
end


---A result's file as shown: relative to the project if in it.
---@param file string
---@return string
local function display_path(file)
  if not common.is_absolute_path(file) then return file end
  if common.path_belongs_to(file, core.project_dir) then
    return common.relative_path(core.project_dir, file)
  end
  return common.home_encode(file)
end


---Draws a result's location and code from x, in a row at y of height h.
---@param item core.resultsview.result
---@param selected boolean
---@return number x The end of what was drawn
function ResultsView:draw_result(item, x, y, h, selected)
  -- dim is hard to read on the selection's color
  local dim = selected and style.text or style.dim
  local location = string.format("%s:%d:%d", display_path(item.file), item.line, item.col)
  x = common.draw_text(style.font, dim, location, "left", x, y, 0, h)
  x = x + style.padding.x
  local font, text = style.code_font, item.text
  if item.match1 then
    x = common.draw_text(font, style.text, text:sub(1, item.match1 - 1), "left", x, y, 0, h)
    x = common.draw_text(font, style.accent, text:sub(item.match1, item.match2 - 1), "left", x, y, 0, h)
    text = text:sub(item.match2)
  end
  return common.draw_text(font, style.text, text, "left", x, y, 0, h)
end


function ResultsView:draw()
  self:draw_background(style.background)
  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for i, item, x,y,w,h in self:each_visible_result() do
    local selected = i == self.selected_idx
    if selected then
      renderer.draw_rect(x, y, w, h, style.selection)
    elseif i == self.hovered_idx then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    x = self:draw_result(item, x + style.padding.x, y, h, selected)
    self.max_h_scroll = math.max(self.max_h_scroll,
      x + style.padding.x - self.position.x + self.scroll.x)
  end
  core.pop_clip_rect()
  self:draw_scrollbar()
end


ResultsList.add_to(ResultsView, "results")


return ResultsView
