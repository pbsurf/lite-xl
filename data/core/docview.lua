local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local keymap = require "core.keymap"
local translate = require "core.doc.translate"
local ime = require "core.ime"
local View = require "core.view"

---@class core.docview : core.view
---@field super core.view
local DocView = View:extend()

function DocView:__tostring() return "DocView" end

DocView.context = "session"

local function move_to_line_offset(dv, line, col, offset)
  local xo = dv.last_x_offset
  if xo.line ~= line or xo.col ~= col then
    xo.offset = dv:get_col_x_offset(line, col)
  end
  xo.line = line + offset
  xo.col = dv:get_x_offset_col(line + offset, xo.offset)
  return xo.line, xo.col
end


DocView.translate = {
  ["previous_page"] = function(doc, line, col, dv)
    local min, max = dv:get_visible_line_range()
    return line - (max - min), 1
  end,

  ["next_page"] = function(doc, line, col, dv)
    if line == #doc.lines then
      return #doc.lines, #doc.lines[line]
    end
    local min, max = dv:get_visible_line_range()
    return line + (max - min), 1
  end,

  ["previous_line"] = function(doc, line, col, dv)
    if line == 1 then
      return 1, 1
    end
    return move_to_line_offset(dv, line, col, -1)
  end,

  ["next_line"] = function(doc, line, col, dv)
    if line == #doc.lines then
      return #doc.lines, math.huge
    end
    return move_to_line_offset(dv, line, col, 1)
  end,
}


function DocView:new(doc)
  DocView.super.new(self)
  self.cursor = "ibeam"
  self.scrollable = true
  self.doc = assert(doc)
  self.font = "code_font"
  self.last_x_offset = {}
  self.ime_selection = { from = 0, size = 0 }
  self.ime_status = false
  self.hovering_gutter = false
  self.v_scrollbar:set_forced_status(config.force_scrollbar_status)
  self.h_scrollbar:set_forced_status(config.force_scrollbar_status)
  -- widest line seen this session; nil when it needs a full measure
  self.max_line_width = nil
  doc:add_lines_listener(self)
end


function DocView:try_close(do_close)
  if #core.get_views_referencing_doc(self.doc) == 1 then
    core.confirm_close_docs({ self.doc }, do_close)
  else
    do_close()
  end
end


function DocView:get_name()
  local pre = self.doc:is_dirty() and "* " or ""
  local name = self.doc:get_name()
  return pre .. name:match("[^/%\\]*$")
end


function DocView:get_filename()
  if self.doc.abs_filename then
    local pre = self.doc:is_dirty() and "* " or ""
    return pre .. common.home_encode(self.doc.abs_filename)
  end
  return self:get_name()
end


function DocView:get_scrollable_size()
  if not config.scroll_past_end then
    local _, _, _, h_scroll = self.h_scrollbar:get_track_rect()
    return self:get_line_height() * (#self.doc.lines) + style.padding.y * 2 + h_scroll
  end
  return self:get_line_height() * (#self.doc.lines - 1) + self.size.y
end


-- Uses the default font only; tokens drawn with `style.syntax_fonts` are ignored.
local function measure_lines(font, lines, line1, line2, width)
  for i = line1, line2 do
    local text = lines[i]
    if text then
      width = math.max(width, font:get_width(text:sub(1, -2)))
    end
  end
  return width
end


function DocView:on_doc_lines_changed(doc, line1, line2)
  if not line1 then
    self.max_line_width = nil
    self.max_line_width_scan = nil
  elseif self.max_line_width then
    -- grow only, so the scroll width doesn't jump around while editing
    local font = self:get_font()
    font:set_tab_size(select(2, doc:get_indent_info()))
    self.max_line_width = measure_lines(font, doc.lines, line1, line2, self.max_line_width)
    if self.max_line_width_scan then
      self.max_line_width_scanned = measure_lines(font, doc.lines, line1, line2, self.max_line_width_scanned)
    end
  end
end


-- Measures every line in a background thread, as that can take a noticeable
-- time on large files. Until it's done, the width is `estimate` or the widest
-- line measured so far, whichever is larger.
function DocView:start_max_line_width_scan(estimate)
  local token = {}
  self.max_line_width_scan = token
  -- measure what's on screen now, so the scroll position isn't clamped meanwhile
  local font = self:get_font()
  font:set_tab_size(select(2, self.doc:get_indent_info()))
  local minline, maxline = self:get_visible_line_range()
  local width = measure_lines(font, self.doc.lines, minline, maxline, 0)
  for _, line1, _, line2 in self.doc:get_selections() do
    width = measure_lines(font, self.doc.lines, line1, line1, width)
    width = measure_lines(font, self.doc.lines, line2, line2, width)
  end
  self.max_line_width_scanned = width
  self.max_line_width = math.max(estimate, width)
  core.add_thread(function()
    local i, nlines = 1, #self.doc.lines
    while self.max_line_width_scan == token and i <= #self.doc.lines do
      -- restart if lines were added or removed, as that shifts unscanned lines
      if #self.doc.lines ~= nlines then i, nlines = 1, #self.doc.lines end
      local font = self:get_font()
      font:set_tab_size(select(2, self.doc:get_indent_info()))
      local last = math.min(i + 2000, nlines)
      self.max_line_width_scanned = measure_lines(font, self.doc.lines, i, last, self.max_line_width_scanned)
      self.max_line_width = math.max(self.max_line_width, self.max_line_width_scanned)
      i = last + 1
      coroutine.yield()
    end
    if self.max_line_width_scan == token then
      self.max_line_width_scan = nil
      self.max_line_width = self.max_line_width_scanned
    end
  end, token)
end


-- Rescans when the font, its size (zoom changes it in place) or the tab size
-- changes, or after the document is reloaded.
function DocView:get_max_line_width()
  local font = self:get_font()
  local font_size = font:get_size()
  local _, indent_size = self.doc:get_indent_info()
  if not self.max_line_width
    or font ~= self.max_line_width_font
    or font_size ~= self.max_line_width_font_size
    or indent_size ~= self.max_line_width_indent
  then
    local estimate = 0
    if self.max_line_width and font == self.max_line_width_font then
      estimate = self.max_line_width * font_size / self.max_line_width_font_size
    end
    self.max_line_width_font = font
    self.max_line_width_font_size = font_size
    self.max_line_width_indent = indent_size
    self:start_max_line_width_scan(estimate)
  end
  return self.max_line_width
end


function DocView:get_h_scrollable_size()
  -- matches the margins used by scroll_to_make_visible
  local _, _, scroll_w = self.v_scrollbar:get_track_rect()
  local xmargin = 3 * self:get_font():get_width(' ')
  return self:get_gutter_width() + self:get_max_line_width() + xmargin + scroll_w
end


function DocView:get_font()
  return style[self.font]
end


function DocView:get_line_height()
  return math.floor(self:get_font():get_height() * config.line_height)
end


---The gutter's width, which the text starts after, and how much of it isn't
---taken by the line numbers.
---@return number width, number padding
function DocView:get_gutter_width()
  -- padding left of the numbers and right of them within style.gutter's fill,
  -- then style.gutter_gap, unfilled, before the text
  local padding = style.padding.x * 1.5 + self:get_gutter_gap()
  return self:get_font():get_width(#self.doc.lines) + padding, padding
end

---The space between the gutter's fill (style.gutter) and the text:
---style.gutter_gap, by default half of style.padding.x.
---@return number
function DocView:get_gutter_gap()
  return style.gutter_gap or math.floor(style.padding.x / 2)
end


function DocView:get_line_screen_position(line, col)
  local x, y = self:get_content_offset()
  local lh = self:get_line_height()
  local gw = self:get_gutter_width()
  y = y + (line-1) * lh + style.padding.y
  if col then
    return x + gw + self:get_col_x_offset(line, col), y
  else
    return x + gw, y
  end
end

function DocView:get_line_text_y_offset()
  local lh = self:get_line_height()
  local th = self:get_font():get_height()
  return (lh - th) / 2
end


function DocView:get_visible_line_range()
  local x, y, x2, y2 = self:get_content_bounds()
  local lh = self:get_line_height()
  local minline = math.max(1, math.floor((y - style.padding.y) / lh) + 1)
  local maxline = math.min(#self.doc.lines, math.floor((y2 - style.padding.y) / lh) + 1)
  return minline, maxline
end


function DocView:get_col_x_offset(line, col)
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  local column = 1
  local xoffset = 0
  for _, type, text in self.doc.highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local length = #text
    if column + length <= col then
      xoffset = xoffset + font:get_width(text)
      column = column + length
      if column >= col then
        return xoffset
      end
    else
      for char in common.utf8_chars(text) do
        if column >= col then
          return xoffset
        end
        xoffset = xoffset + font:get_width(char)
        column = column + #char
      end
    end
  end

  return xoffset
end


function DocView:get_x_offset_col(line, x)
  local line_text = self.doc.lines[line]

  local xoffset, i = 0, 1
  local default_font = self:get_font()
  local _, indent_size = self.doc:get_indent_info()
  default_font:set_tab_size(indent_size)
  for _, type, text in self.doc.highlighter:each_token(line) do
    local font = style.syntax_fonts[type] or default_font
    if font ~= default_font then font:set_tab_size(indent_size) end
    local width = font:get_width(text)
    -- Don't take the shortcut if the width matches x,
    -- because we need last_i which should be calculated using utf-8.
    if xoffset + width < x then
      xoffset = xoffset + width
      i = i + #text
    else
      for char in common.utf8_chars(text) do
        local w = font:get_width(char)
        if xoffset + w >= x then
          return (x <= xoffset + (w / 2)) and i or i + #char
        end
        xoffset = xoffset + w
        i = i + #char
      end
    end
  end

  return #line_text
end


function DocView:resolve_screen_position(x, y)
  local ox, oy = self:get_line_screen_position(1)
  local line = math.floor((y - oy) / self:get_line_height()) + 1
  line = common.clamp(line, 1, #self.doc.lines)
  local col = self:get_x_offset_col(line, x - ox)
  return line, col
end


function DocView:scroll_to_line(line, ignore_if_visible, instant)
  local min, max = self:get_visible_line_range()
  if not (ignore_if_visible and line > min and line < max) then
    local x, y = self:get_line_screen_position(line)
    local ox, oy = self:get_content_offset()
    local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
    self.scroll.to.y = math.max(0, y - oy - (self.size.y - scroll_h) / 2)
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end


function DocView:scroll_to_make_visible(line, col)
  local _, oy = self:get_content_offset()
  local _, ly = self:get_line_screen_position(line, col)
  local lh = self:get_line_height()
  local _, _, _, scroll_h = self.h_scrollbar:get_track_rect()
  local overscroll = math.min(lh * 2, self.size.y) -- always show the previous / next line when possible
  self.scroll.to.y = common.clamp(self.scroll.to.y, ly - oy - self.size.y + scroll_h + overscroll, ly - oy - lh)
  local gw = self:get_gutter_width()
  local xoffset = self:get_col_x_offset(line, col)
  local xmargin = 3 * self:get_font():get_width(' ')
  local xsup = xoffset + gw + xmargin
  local xinf = xoffset - xmargin
  local _, _, scroll_w = self.v_scrollbar:get_track_rect()
  local size_x = math.max(0, self.size.x - scroll_w)
  if xsup > self.scroll.x + size_x then
    self.scroll.to.x = xsup - size_x
  elseif xinf < self.scroll.x then
    self.scroll.to.x = math.max(0, xinf)
  end
end

function DocView:on_mouse_moved(x, y, ...)
  DocView.super.on_mouse_moved(self, x, y, ...)

  self.mouse_position = { x = x, y = y }
  self.hovering_gutter = false
  local gw = self:get_gutter_width()

  if self:scrollbar_hovering() or self:scrollbar_dragging() then
    self.cursor = "arrow"
  elseif gw > 0 and x >= self.position.x and x <= (self.position.x + gw) then
    self.cursor = "arrow"
    self.hovering_gutter = true
  else
    self.cursor = "ibeam"
  end

  if self.gutter_selecting then
    self:select_whole_lines(self.gutter_selecting, (self:resolve_screen_position(x, y)))
  elseif self.mouse_selecting then
    local l1, c1 = self:resolve_screen_position(x, y)
    local l2, c2, snap_type = table.unpack(self.mouse_selecting)
    if snap_type == "block" then
      -- each line's columns are found from the x positions of the anchor and the
      -- mouse, so a short line (or tabs) under the mouse doesn't skew the block
      local ox = self:get_line_screen_position(1)
      local ax, mx = self:get_col_x_offset(l2, c2), x - ox
      if l1 > l2 then l1, l2 = l2, l1 end
      self.doc.selections = { }
      for i = l1, l2 do
        self.doc:set_selections(i - l1 + 1, i, self:get_x_offset_col(i, mx), i, self:get_x_offset_col(i, ax))
      end
    else
      if snap_type then
        l1, c1, l2, c2 = self:mouse_selection(self.doc, snap_type, l1, c1, l2, c2)
      end
      self.doc:set_selection(l1, c1, l2, c2)
    end
  end
end


function DocView:mouse_selection(doc, snap_type, line1, col1, line2, col2)
  local swap = line2 < line1 or line2 == line1 and col2 <= col1
  if swap then
    line1, col1, line2, col2 = line2, col2, line1, col1
  end
  if snap_type == "word" then
    line1, col1 = translate.start_of_word(doc, line1, col1)
    line2, col2 = translate.end_of_word(doc, line2, col2)
  elseif snap_type == "lines" then
    col1, col2 = 1, math.huge
  end
  if swap then
    return line2, col2, line1, col1
  end
  return line1, col1, line2, col2
end


---Selects lines `anchor` to `line` (in either order) including the last line's
---newline, with the caret at the end on `line`'s side.
function DocView:select_whole_lines(anchor, line)
  local first, last = math.min(anchor, line), math.max(anchor, line)
  local end_line, end_col = last + 1, 1
  if last == #self.doc.lines then end_line, end_col = last, #self.doc.lines[last] end
  if line < anchor then
    self.doc:set_selection(first, 1, end_line, end_col)
  else
    self.doc:set_selection(end_line, end_col, first, 1)
  end
end


function DocView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" or not self.hovering_gutter then
    return DocView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  local line = self:resolve_screen_position(x, y)
  if keymap.modkeys["shift"] then
    local sline, scol, sline2, scol2 = self.doc:get_selection(true)
    if line > sline then
      self.doc:set_selection(sline, 1, line,  #self.doc.lines[line])
    else
      self.doc:set_selection(line, 1, sline2, #self.doc.lines[sline2])
    end
  else
    -- select the line; dragging extends the selection by whole lines
    self:select_whole_lines(line, line)
    self.gutter_selecting = line
  end
  return true
end


function DocView:on_mouse_left()
  DocView.super.on_mouse_left(self)
  self.mouse_position = nil
end


---Where the mouse is over the text while ctrl is held: add-ons that give ctrl+click
---a target there show it with draw_ctrl_hover. nil otherwise.
---@return number? x
---@return number? y
function DocView:get_ctrl_hover()
  local m = self.mouse_position
  if not m or not keymap.modkeys["ctrl"] or self.mouse_selecting
    or self.hovering_gutter or self:scrollbar_hovering() then
    return
  end
  return m.x, m.y
end


---Underlines columns col1 to col2 - 1 of a line drawn at x, y, in the color of the
---text at col1.
---@param line integer
---@param x number
---@param y number
---@param col1 integer
---@param col2 integer
function DocView:draw_underline(line, x, y, col1, col2)
  local color, col = style.text, 1
  for _, type, text in self.doc.highlighter:each_token(line) do
    if col + #text > col1 then
      color = style.syntax[type] or style.text
      break
    end
    col = col + #text
  end
  local thickness = math.max(1, math.floor(SCALE + 0.5))
  local uy = y + self:get_line_text_y_offset() + self:get_font():get_height() - thickness
  local x1 = x + self:get_col_x_offset(line, col1)
  local x2 = x + self:get_col_x_offset(line, col2)
  renderer.draw_rect(x1, uy, x2 - x1, thickness, color)
end


---Shows columns col1 to col2 - 1 of a line drawn at x, y as what ctrl+click at
---get_ctrl_hover() would open: underlined, with a hand for the mouse cursor.
---@param line integer
---@param x number
---@param y number
---@param col1 integer
---@param col2 integer
function DocView:draw_ctrl_hover(line, x, y, col1, col2)
  self:draw_underline(line, x, y, col1, col2)
  self.ctrl_hover_shown = true
end


function DocView:on_mouse_released(...)
  DocView.super.on_mouse_released(self, ...)
  self.mouse_selecting = nil
  self.gutter_selecting = nil
end


function DocView:on_text_input(text)
  self.doc:text_input(text)
end

function DocView:on_ime_text_editing(text, start, length)
  self.doc:ime_text_editing(text, start, length)
  self.ime_status = #text > 0
  self.ime_selection.from = start
  self.ime_selection.size = length

  -- Set the composition bounding box that the system IME
  -- will consider when drawing its interface
  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local col = math.min(col1, col2)
  self:update_ime_location()
  self:scroll_to_make_visible(line1, col + start)
end

---Update the composition bounding box that the system IME
---will consider when drawing its interface
function DocView:update_ime_location()
  if not self.ime_status then return end

  local line1, col1, line2, col2 = self.doc:get_selection(true)
  local x, y = self:get_line_screen_position(line1)
  local h = self:get_line_height()
  local col = math.min(col1, col2)

  local x1, x2 = 0, 0

  if self.ime_selection.size > 0 then
    -- focus on a part of the text
    local from = col + self.ime_selection.from
    local to = from + self.ime_selection.size
    x1 = self:get_col_x_offset(line1, from)
    x2 = self:get_col_x_offset(line1, to)
  else
    -- focus the whole text
    x1 = self:get_col_x_offset(line1, col1)
    x2 = self:get_col_x_offset(line2, col2)
  end

  ime.set_location(x + x1, y, x2 - x1, h)
end

function DocView:update()
  -- scroll to make caret visible and reset blink timer if it moved
  local line1, col1, line2, col2 = self.doc:get_selection()
  if (line1 ~= self.last_line1 or col1 ~= self.last_col1 or
      line2 ~= self.last_line2 or col2 ~= self.last_col2) and self.size.x > 0 then
    if core.active_view == self and not ime.editing then
      self:scroll_to_make_visible(line1, col1)
    end
    core.blink_reset()
    self.last_line1, self.last_col1 = line1, col1
    self.last_line2, self.last_col2 = line2, col2
  end

  -- update blink timer
  if self == core.active_view and not self.mouse_selecting then
    local T, t0 = config.blink_period, core.blink_start
    local ta, tb = core.blink_timer, system.get_time()
    if ((tb - t0) % T < T / 2) ~= ((ta - t0) % T < T / 2) then
      core.redraw = true
    end
    core.blink_timer = tb
  end

  self:update_ime_location()

  DocView.super.update(self)
end


function DocView:draw_line_highlight(x, y)
  local lh = self:get_line_height()
  renderer.draw_rect(x, y, self.size.x, lh, style.line_highlight)
end


function DocView:draw_line_text(line, x, y)
  local default_font = self:get_font()
  local tx, ty = x, y + self:get_line_text_y_offset()
  local last_token = nil
  local tokens = self.doc.highlighter:get_line(line).tokens
  local tokens_count = #tokens
  if string.sub(tokens[tokens_count], -1) == "\n" then
    last_token = tokens_count - 1
  end
  for tidx, type, text in self.doc.highlighter:each_token(line) do
    local color = style.syntax[type]
    local font = style.syntax_fonts[type] or default_font
    -- do not render newline, fixes issue #1164
    if tidx == last_token then text = text:sub(1, -2) end
    tx = renderer.draw_text(font, text, tx, ty, color)
    if tx > self.position.x + self.size.x then break end
  end
  return self:get_line_height()
end

function DocView:draw_caret(x, y)
    local lh = self:get_line_height()
    renderer.draw_rect(x, y, style.caret_width, lh, style.caret)
end

function DocView:draw_line_body(line, x, y)
  -- draw highlight if any selection ends on this line
  local draw_highlight = false
  local hcl = config.highlight_current_line
  if hcl ~= false then
    for lidx, line1, col1, line2, col2 in self.doc:get_selections(false) do
      if line1 == line then
        if hcl == "no_selection" then
          if (line1 ~= line2) or (col1 ~= col2) then
            draw_highlight = false
            break
          end
        end
        draw_highlight = true
        break
      end
    end
  end
  if draw_highlight and core.active_view == self then
    self:draw_line_highlight(x + self.scroll.x, y)
  end

  self:draw_line_marks_and_selection(line, x, y)

  -- draw line's text
  return self:draw_line_text(line, x, y)
end


---Ranges of a line to mark with a background color (search matches,
---occurrences of the selection, ...), drawn under the selection and the text.
---Plugins wrap this and add theirs to the list the original returns.
---@param line integer
---@return { [1]: integer, [2]: integer, [3]: renderer.color }[] marks col1, col2 (exclusive), color
function DocView:get_line_marks(line)
  return {}
end


---Fills the background of columns col1 to col2 (exclusive) of a line.
---@param line integer
---@param col1 integer
---@param col2 integer
---@param x number the line's x, as passed to draw_line_body
---@param y number the line's y, as passed to draw_line_body
---@param color renderer.color
function DocView:draw_line_range(line, col1, col2, x, y, color)
  local x1 = x + self:get_col_x_offset(line, col1)
  local x2 = x + self:get_col_x_offset(line, col2)
  if x1 ~= x2 then
    renderer.draw_rect(x1, y, x2 - x1, self:get_line_height(), color)
  end
end


---Draws the line's marks (get_line_marks), then the selections overlapping it.
---@param line integer
---@param x number
---@param y number
function DocView:draw_line_marks_and_selection(line, x, y)
  for _, mark in ipairs(self:get_line_marks(line)) do
    self:draw_line_range(line, mark[1], mark[2], x, y, mark[3])
  end
  for lidx, line1, col1, line2, col2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      if line1 ~= line then col1 = 1 end
      if line2 ~= line then col2 = #self.doc.lines[line] + 1 end
      self:draw_line_range(line, col1, col2, x, y, style.selection)
    end
  end
end


function DocView:draw_line_gutter(line, x, y, width)
  local color = style.line_number
  for _, line1, _, line2 in self.doc:get_selections(true) do
    if line >= line1 and line <= line2 then
      color = style.line_number2
      break
    end
  end
  x = x + style.padding.x
  local lh = self:get_line_height()
  common.draw_text(self:get_font(), color, line, "right", x, y, width, lh)
  return lh
end


function DocView:draw_ime_decoration(line1, col1, line2, col2)
  local x, y = self:get_line_screen_position(line1)
  local line_size = math.max(1, SCALE)
  local lh = self:get_line_height()

  -- Draw IME underline
  local x1 = self:get_col_x_offset(line1, col1)
  local x2 = self:get_col_x_offset(line2, col2)
  renderer.draw_rect(x + math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.text)

  -- Draw IME selection
  local col = math.min(col1, col2)
  local from = col + self.ime_selection.from
  local to = from + self.ime_selection.size
  x1 = self:get_col_x_offset(line1, from)
  if from ~= to then
    x2 = self:get_col_x_offset(line1, to)
    line_size = style.caret_width
    renderer.draw_rect(x + math.min(x1, x2), y + lh - line_size, math.abs(x1 - x2), line_size, style.caret)
  end
  self:draw_caret(x + x1, y)
end


function DocView:draw_overlay()
  if core.active_view == self then
    local minline, maxline = self:get_visible_line_range()
    -- draw caret if it overlaps this line
    local T = config.blink_period
    for _, line1, col1, line2, col2 in self.doc:get_selections() do
      if line1 >= minline and line1 <= maxline
      and system.window_has_focus() then
        if ime.editing then
          self:draw_ime_decoration(line1, col1, line2, col2)
        else
          if config.disable_blink
          or (core.blink_timer - core.blink_start) % T < T / 2 then
            self:draw_caret(self:get_line_screen_position(line1, col1))
          end
        end
      end
    end
  end
end

function DocView:draw()
  self.ctrl_hover_shown = false
  self:draw_background(style.background)
  local _, indent_size = self.doc:get_indent_info()
  self:get_font():set_tab_size(indent_size)

  local minline, maxline = self:get_visible_line_range()
  local lh = self:get_line_height()

  local x, y = self:get_line_screen_position(minline)
  local gw, gpad = self:get_gutter_width()
  if style.gutter ~= style.background then
    renderer.draw_rect(self.position.x, self.position.y, gw - self:get_gutter_gap(),
      self.size.y, style.gutter)
  end
  for i = minline, maxline do
    y = y + (self:draw_line_gutter(i, self.position.x, y, gpad and gw - gpad or gw) or lh)
  end

  local pos = self.position
  x, y = self:get_line_screen_position(minline)
  -- the clip below ensure we don't write on the gutter region. On the
  -- right side it is redundant with the Node's clip.
  core.push_clip_rect(pos.x + gw, pos.y, self.size.x - gw, self.size.y)
  for i = minline, maxline do
    y = y + (self:draw_line_body(i, x, y) or lh)
  end
  self:draw_overlay()
  core.pop_clip_rect()

  self:draw_scrollbar()

  -- set here, as ctrl and replies from add-ons' servers change it without the
  -- mouse moving
  local cursor = self.ctrl_hover_shown and "hand" or "ibeam"
  if self.mouse_position and self.cursor ~= cursor
    and (self.cursor == "ibeam" or self.cursor == "hand") then
    self.cursor = cursor
    core.request_cursor(cursor)
  end
end

return DocView
