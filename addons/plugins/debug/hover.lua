local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local tooltip = require "core.tooltip"
local DocView = require "core.docview"

---Values on hover: while the program is stopped, resting the mouse on a
---variable in the editor shows its value and type (for a pointer, what it
---points to too) in a tooltip, evaluated in the selected frame.
---
---What's evaluated is read from the text, without a language server: the
---selection, if the mouse is in it; else the identifier under the mouse with
---the members and subscripts leading to it (`a.b->c[i].d`, up to the word
---hovered). Never a call: gdb would run it. Only in the selected frame's
---function (its lines, from the backend), so a name isn't looked up in a
---frame it doesn't belong to.
local hover = {}

-- tokens whose words aren't variables
local skip_tokens = {
  comment = true, string = true, keyword = true, keyword2 = true,
  preprocessor = true, ["function"] = true, number = true,
}

-- most lines of a value shown
local MAX_LINES = 15
-- widest a value is shown, in characters of the code font
local MAX_COLUMNS = 100

local function is_word_char(c) return c ~= "" and c:find("^[%w_]$") ~= nil end

-- a subscript's contents that can be evaluated without side effects: no
-- calls, assignments, increments
local function safe_subscript(s)
  if s:find("[%(%){},;]") or s:find("%+%+") or s:find("%-%-") then return false end
  s = s:gsub("[=!<>]=", "")
  return not s:find("=")
end

-- the start of the operand ending at text[e] (an identifier, or one followed
-- by subscripts), or nil
local function operand_start(text, e)
  local c = text:sub(e, e)
  if c == "]" then
    local depth, i = 0, e
    while i >= 1 do
      local ch = text:sub(i, i)
      if ch == "]" then depth = depth + 1
      elseif ch == "[" then
        depth = depth - 1
        if depth == 0 then break end
      end
      i = i - 1
    end
    if i < 1 or not safe_subscript(text:sub(i + 1, e - 1)) then return nil end
    return operand_start(text, i - 1)
  elseif is_word_char(c) then
    local s = e
    while s > 1 and is_word_char(text:sub(s - 1, s - 1)) do s = s - 1 end
    if text:sub(s, s):find("^%d") then return nil end
    return s
  end
end

-- extends an operand starting at s leftwards over `.`, `->` and `::` and what
-- they follow
local function extend_left(text, s)
  while true do
    local before = text:sub(1, s - 1)
    local op = before:match("%->$") or before:match("::$") or before:match("%.$")
    if not op then return s end
    local start = operand_start(text, s - #op - 1)
    if not start then return s end
    s = start
  end
end

local function token_type_at(doc, line, col)
  local column = 1
  for _, type, text in doc.highlighter:each_token(line) do
    local len = #text
    if col < column + len then return type end
    column = column + len
  end
end

---The expression to evaluate for the mouse at a character: the selection if
---the character is in it (on one line), else a variable's name (and how it's
---reached). nil if there's none there.
---@param doc core.doc
---@param line integer
---@param col integer the character under the mouse
---@return string? expression
---@return integer? col1 its first character
---@return integer? col2 after its last
function hover.expression_at(doc, line, col)
  local l1, c1, l2, c2 = doc:get_selection(true)
  if l1 == l2 and c1 ~= c2 and line == l1 and col >= c1 and col < c2 then
    local text = doc.lines[line]:sub(c1, c2 - 1)
    if text:find("%S") then return (text:gsub("^%s+", ""):gsub("%s+$", "")), c1, c2 end
  end
  local text = doc.lines[line]
  local c = text:sub(col, col)
  local s, e
  if c == "]" then
    s, e = operand_start(text, col), col
  elseif is_word_char(c) then
    e = col
    while is_word_char(text:sub(e + 1, e + 1)) do e = e + 1 end
    s = operand_start(text, e)
    if s and text:sub(s, e) ~= "this" and skip_tokens[token_type_at(doc, line, col) or ""] then
      return nil
    end
  end
  if not s then return nil end
  s = extend_left(text, s)
  return text:sub(s, e), s, e + 1
end


------------------------------ Hover state

-- the target hovered: { view, line, col1, col2, expression, change_id,
-- generation }; the one the tooltip shows when tooltip.shown(hover, target)
local current
-- what targets evaluated to, for one stop and frame: expression ->
-- { value, type, error } or false (nothing to show)
local cache = {}
local cache_key

local debug -- the plugin (set by hover.setup)

local function frame_key(session)
  local frame = session:get_frame()
  return frame and (session.generation .. ":" .. tostring(session:thread_id()) .. ":" .. frame.level)
end

local function get_cache(session)
  local key = frame_key(session)
  if key ~= cache_key then cache, cache_key = {}, key end
  return cache
end

---Forgets the hovered target (the session moved on, the mouse left).
function hover.clear()
  if current then
    current = nil
    tooltip.hover(hover, nil)
    core.redraw = true
  end
end

local function stopped_session()
  local s = debug and debug.session
  return s and s.state == "stopped" and s:get_frame() and s or nil
end

-- whether a line of a file is in the selected frame's function (in a core
-- thread); the lines above a function's opening brace on a line of its own
-- (its signature, from gdb's first line with code) count
local function in_frame(session, doc, line)
  local frame = session:get_frame()
  if not frame or frame.file ~= doc.abs_filename then return false end
  if not session.capabilities.function_lines then return true end
  local file, first, last = session:function_lines()
  if not file then return false end
  if file ~= doc.abs_filename then return false end
  if doc.lines[first] and doc.lines[first]:find("^%s*{") then
    local k = first - 1
    while k >= 1 and first - k <= 10 and doc.lines[k]:find("%S")
      and not doc.lines[k]:find("[;}]%s*$") and not doc.lines[k]:find("^%s*#") do
      first, k = k, k - 1
    end
  end
  return line >= first and line <= last
end

-- what to show for a target (in a core thread): { value, type, error } or false
local function resolve(session, target)
  local results = get_cache(session)
  local res = results[target.expression]
  if res ~= nil then return res end
  local doc = target.view.doc
  if not in_frame(session, doc, target.line) then
    res = false
  else
    local var, err = session:watch(target.expression)
    if err == "stale" then return false end
    if var then
      res = { value = var.value, type = var.type }
      -- a pointer: what it points to too (not a string's: gdb shows that)
      local t = var.type or ""
      if t:find("%*%s*$") and not t:find("char%s*%*%s*$") and not t:find("void%s*%*%s*$")
        and not t:find("%(") then
        local pointee, why = session:evaluate("*(" .. target.expression .. ")")
        res.pointee = pointee or (why and why:find("^Cannot access memory") and why) or nil
      end
    elseif err and err:find("^Cannot access memory") then
      -- a pointer that doesn't point anywhere: worth seeing
      res = { error = err }
    else
      res = false
    end
  end
  if session ~= stopped_session() or frame_key(session) ~= cache_key then return false end
  results[target.expression] = res
  return res
end

local function same_target(a, b)
  return a and b and a.view == b.view and a.line == b.line and a.col1 == b.col1
    and a.col2 == b.col2 and a.expression == b.expression and a.change_id == b.change_id
    and a.generation == b.generation
end

-- the target under the mouse in a docview, if any
local function target_at(view, x, y)
  local session = stopped_session()
  if not session or not view.doc.abs_filename then return nil end
  if not view:overlaps_point(x, y) or view.mouse_selecting then return nil end
  local gw = view:get_gutter_width()
  if x < view.position.x + gw or view:scrollbar_overlaps_point(x, y) then return nil end
  local line, col = view:resolve_screen_position(x, y)
  local lx, ly = view:get_line_screen_position(line, col)
  if y < ly or y >= ly + view:get_line_height() then return nil end
  -- the character under the mouse: resolve_screen_position rounds to the
  -- nearest boundary
  if x < lx then col = col - 1 end
  if col < 1 or col >= #view.doc.lines[line] then return nil end
  local expression, col1, col2 = hover.expression_at(view.doc, line, col)
  if not expression then return nil end
  return {
    view = view, line = line, col1 = col1, col2 = col2, expression = expression,
    change_id = view.doc:get_change_id(), generation = session.generation,
  }
end

local function update(view, x, y)
  local target = target_at(view, x, y)
  if same_target(target, current) then return end
  current = target
  if not target then
    tooltip.hover(hover, nil)
    return
  end
  local session = stopped_session()
  local res = get_cache(session)[target.expression]
  if res ~= nil then
    tooltip.hover(hover, res and target or nil)
    return
  end
  -- evaluated once the mouse has rested on it
  tooltip.hover(hover, nil)
  core.add_thread(function()
    coroutine.yield(config.tooltip_delay)
    if current ~= target or session ~= stopped_session() then return end
    res = resolve(session, target)
    if current == target and res then tooltip.hover(hover, target, 0) end
  end)
end

local function showing(view)
  if not (current and current.view == view and tooltip.shown(hover, current)) then return nil end
  local session = stopped_session()
  if not session or session.generation ~= current.generation
    or view.doc:get_change_id() ~= current.change_id then
    return nil
  end
  local res = get_cache(session)[current.expression]
  return res and current, res
end


------------------------------ Drawing

-- a value's text in lines at most max_w wide (breaking after commas and
-- spaces where it can), at most MAX_LINES of them
local function wrap(text, font, max_w)
  local lines = {}
  for para in (text .. "\n"):gmatch("(.-)\n") do
    while font:get_width(para) > max_w do
      local lo, hi = 1, #para
      while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if font:get_width(para:sub(1, mid)) <= max_w then lo = mid else hi = mid - 1 end
      end
      local n = lo
      -- not inside a UTF-8 sequence
      while n > 1 and (para:byte(n + 1) or 0) >= 0x80 and (para:byte(n + 1) or 0) < 0xc0 do n = n - 1 end
      local brk = para:sub(1, n):match(".*()[, ]")
      if brk and brk > n * 0.6 then n = brk end
      table.insert(lines, para:sub(1, n))
      para = para:sub(n + 1)
      if #lines >= MAX_LINES then break end
    end
    if #lines >= MAX_LINES then break end
    table.insert(lines, para)
  end
  if #lines > MAX_LINES or (#lines == MAX_LINES and #text > #table.concat(lines)) then
    while #lines >= MAX_LINES do table.remove(lines) end
    table.insert(lines, "…")
  end
  return lines
end

local function draw_tooltip(view, target, res)
  local font = style.code_font
  local fh = font:get_height()
  local root = core.root_view.root_node
  local max_w = math.min(root.size.x - style.padding.x * 4, font:get_width("m") * MAX_COLUMNS)
  local text = res.value or res.error or ""
  if res.pointee then text = text .. "\n→ " .. res.pointee end
  local lines = wrap(text, font, max_w)
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, font:get_width(l)) end
  local type_text = res.type and res.type ~= "" and res.type or nil
  if type_text then w = math.max(w, font:get_width(type_text)) end
  w = math.min(w, max_w) + style.padding.x * 2
  local h = fh * (#lines + (type_text and 1 or 0)) + style.padding.y
  local lh = view:get_line_height()
  local x, y = view:get_line_screen_position(target.line, target.col1)
  x = math.max(0, math.min(x - style.padding.x, root.size.x - w - 1))
  -- below the expression, else above it
  local ty = y + lh
  if ty + h > root.size.y then ty = y - h end
  common.draw_popup_box(x, ty, w, h)
  local cy = ty + style.padding.y / 2
  local color = res.error and style.error or style.text
  core.push_clip_rect(x, ty, w, h)
  for _, l in ipairs(lines) do
    renderer.draw_text(font, l, x + style.padding.x, cy, color)
    cy = cy + fh
  end
  if type_text then renderer.draw_text(font, type_text, x + style.padding.x, cy, style.dim) end
  core.pop_clip_rect()
end


---Sets the editor up: `debug_plugin` is plugins.debug, `supports(doc)` says
---whether a doc's language is debugged (where values are looked up).
function hover.setup(debug_plugin, supports)
  debug = debug_plugin

  local on_mouse_moved = DocView.on_mouse_moved
  function DocView:on_mouse_moved(x, y, ...)
    local res = on_mouse_moved(self, x, y, ...)
    if config.plugins.debug.hover_values and supports(self.doc) and not res
      and not self.debug_hovered_line then
      update(self, x, y)
    elseif current and current.view == self then
      hover.clear()
    end
    return res
  end

  local on_mouse_left = DocView.on_mouse_left
  function DocView:on_mouse_left()
    on_mouse_left(self)
    if current and current.view == self then hover.clear() end
  end

  local on_mouse_wheel = DocView.on_mouse_wheel
  function DocView:on_mouse_wheel(...)
    if current and current.view == self then hover.clear() end
    return on_mouse_wheel(self, ...)
  end

  -- the expression evaluated, marked
  local draw_line_body = DocView.draw_line_body
  function DocView:draw_line_body(line, x, y)
    local res = draw_line_body(self, line, x, y)
    local target = showing(self)
    if target and target.line == line then
      local x1 = self:get_line_screen_position(line, target.col1)
      local x2 = self:get_line_screen_position(line, target.col2)
      renderer.draw_rect(x1, y, x2 - x1, self:get_line_height(), style.debug.hover)
    end
    return res
  end

  local draw = DocView.draw
  function DocView:draw(...)
    draw(self, ...)
    local target, res = showing(self)
    if target then core.root_view:defer_draw(draw_tooltip, self, target, res) end
  end
end

return hover
