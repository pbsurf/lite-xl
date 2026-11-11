-- mod-version:3
-- Breadcrumbs: a bar at the top of each editor (between its node's tabs and
-- the text) with the file's path, from its project directory (or ~, or the
-- root), then, with the lsp plugin, the symbols around the cursor: e.g.
-- project > src > widget.cpp > Widget > draw. Markdown files without a
-- language server get their sections from the headings
-- (breadcrumbs.symbol_providers, by syntax name, can add other formats).
--
-- Clicking a part drops down its siblings: the files and directories beside
-- it, or the symbols beside it in their parent. A file opens; a directory, or
-- a symbol with members, opens a submenu to the right (on hover, or Right); a
-- symbol is jumped to. Typing filters the deepest dropdown (Backspace and
-- Escape undo it); Up/Down/PageUp/PageDown/Home/End select, Return chooses,
-- Left/Right at the first level move to the neighbouring part, Escape closes.
-- When the cursor is outside every symbol, a "…" part lists the top-level ones.
--
-- breadcrumbs:focus (ctrl+shift+.) drops down the last part from the keyboard.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local Object = require "core.object"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local Node = require "core.node"
local RootView = require "core.rootview"
local dirwatch = require "core.dirwatch"

config.plugins.breadcrumbs = common.merge({
  -- show the bar
  enabled = true,
  -- the symbols around the cursor, from the lsp plugin's servers
  symbols = true,
  -- seconds without edits before asking the server for the symbols again
  symbol_delay = 0.4,
  -- rows a dropdown shows before it scrolls
  max_rows = 20,
  -- icons for files, folders and symbol kinds (nerdicons')
  icons = true,
  -- between the bar and the text: "shadow" (cast on the text), "line" or "none"
  divider = "shadow",
  config_spec = {
    name = "Breadcrumbs",
    {
      label = "Enabled",
      description = "Show the path and symbol bar at the top of editors.",
      path = "enabled",
      type = "toggle",
      default = true,
    },
    {
      label = "Symbols",
      description = "Show the symbols around the cursor (needs a language server).",
      path = "symbols",
      type = "toggle",
      default = true,
    },
    {
      label = "Divider",
      description = "What separates the bar from the text.",
      path = "divider",
      type = "selection",
      default = "shadow",
      values = { { "Shadow", "shadow" }, { "Line", "line" }, { "None", "none" } },
    },
    {
      label = "Icons",
      description = "Show icons for files, folders and symbol kinds (with nerdicons).",
      path = "icons",
      type = "toggle",
      default = true,
    },
  },
}, config.plugins.breadcrumbs)

local breadcrumbs = {}

local function lsp() return package.loaded["plugins.lsp"] end
local function lsp_util() return package.loaded["plugins.lsp.util"] end

local function join(dir, name)
  return dir:sub(-1) == PATHSEP and dir .. name or dir .. PATHSEP .. name
end

local function bar_height()
  return math.floor(style.font:get_height() + style.padding.y)
end

local function row_height()
  return math.floor(style.font:get_height() + style.padding.y)
end


------------------------------------------------------------------------------
-- Rows of the dropdowns: { text, detail?, icon?, key, action?, children? }
-- (children: a function returning rows, for a submenu; icon: { glyph, font,
-- color? })

local function nerdicons()
  local n = package.loaded["plugins.nerdicons"]
  return type(n) == "table" and n or nil
end

---A file's or directory's icon: nerdicons' (by file type), else the icon font's.
local function file_icon(name, file_type)
  if not config.plugins.breadcrumbs.icons then return end
  local n = nerdicons()
  if n and n.file_icon then return { n.file_icon(name, file_type) } end
  return { file_type == "dir" and "d" or "f", style.icon_font }
end

---A symbol kind's icon, with nerdicons.
local function symbol_icon(kind)
  if not config.plugins.breadcrumbs.icons then return end
  local n = nerdicons()
  if n and n.symbol_icon and kind then return { n.symbol_icon(kind) } end
end

---An icon's width, and the gap after it.
local function icon_width(icon)
  return icon and icon[2]:get_width(icon[1]) + math.floor(style.padding.x / 3) or 0
end

---Draws an icon at x, centered in y..y+h; returns where text after it starts.
local function draw_icon(icon, x, y, h, color)
  if not icon then return x end
  common.draw_text(icon[2], color or icon[3] or style.dim, icon[1], "left", x, y, 0, h)
  return x + icon_width(icon)
end

---Whether config.ignore_files leaves out a file or directory: `name` is its
---basename, `rel` its path from its project directory, if it's in one.
local function ignored(compiled, name, rel, type)
  local full = "/" .. (rel or name):gsub("\\", "/")
  for _, c in ipairs(compiled) do
    local test = c.use_path and full or name
    if c.match_dir then
      if type == "dir" and string.match(test .. "/", c.pattern) then return true end
    elseif string.match(test, c.pattern) then
      return true
    end
  end
  return false
end

local function project_dir_of(path)
  for _, dir in ipairs(core.project_directories) do
    if path == dir.name or common.path_belongs_to(path, dir.name) then return dir.name end
  end
end

local function open_file(view, path)
  if view then core.set_active_view(view) end
  core.try(function()
    core.root_view:open_doc(core.open_doc(path))
  end)
end

local dir_rows

---The directories and files in `dir`, directories first.
function dir_rows(dir, view)
  local compiled = dirwatch.compile_ignore_files()
  local root = project_dir_of(dir)
  local entries = {}
  for _, name in ipairs(system.list_dir(dir) or {}) do
    local path = join(dir, name)
    local info = system.get_file_info(path)
    if info and (info.type == "dir" or info.type == "file") then
      local rel = root and path ~= root and path:sub(#root + 2) or nil
      if not ignored(compiled, name, rel, info.type) then
        table.insert(entries, { name = name, path = path, type = info.type })
      end
    end
  end
  table.sort(entries, function(a, b)
    return system.path_compare(a.name, a.type, b.name, b.type)
  end)
  local rows = {}
  for _, e in ipairs(entries) do
    if e.type == "dir" then
      table.insert(rows, {
        text = e.name, icon = file_icon(e.name, "dir"), key = e.path,
        children = function() return dir_rows(e.path, view) end,
      })
    else
      table.insert(rows, {
        text = e.name, icon = file_icon(e.name, "file"), key = e.path,
        action = function() open_file(view, e.path) end,
      })
    end
  end
  return rows
end


------------------------------------------------------------------------------
-- Symbol providers, for files without a language server: by syntax name, a
-- function(doc) returning a list as lsp.get_document_symbols's (name, kind,
-- depth, name_range, range; ranges 0-based, as LSP's, end inclusive).

breadcrumbs.symbol_providers = {}

local HEADING_KIND = 15 -- LSP SymbolKind String, as marksman and VS Code give headings

local function thematic_break(text)
  if text:match("^    ") then return false end
  local t = text:gsub("%s", "")
  return t:match("^%*%*%*+$") or t:match("^%-%-%-+$") or t:match("^___+$")
end

---Markdown's sections: ATX (# Title) and setext (Title, then === or ---)
---headings, outside fenced code blocks and front matter, nested by level.
function breadcrumbs.symbol_providers.Markdown(doc)
  local lines = doc.lines
  local list, stack = {}, {}
  local function close(level, last)
    while #stack > 0 and stack[#stack].level >= level do
      local s = table.remove(stack)
      s.range["end"] = { line = last - 1, character = #lines[last] }
    end
  end
  local function add(level, name, line)
    close(level, line - 1)
    local s = {
      name = name, kind = HEADING_KIND, depth = #stack, level = level, line = line,
      name_range = { start = { line = line - 1, character = 0 },
                     ["end"] = { line = line - 1, character = #lines[line] } },
      range = { start = { line = line - 1, character = 0 } },
    }
    table.insert(list, s)
    table.insert(stack, s)
  end
  local fence -- the open code fence's char and length
  local paragraph -- the line where the current paragraph starts
  local i = 1
  -- front matter
  if lines[1] and lines[1]:match("^%-%-%-%s*$") then
    for j = 2, #lines do
      if lines[j]:match("^%-%-%-%s*$") or lines[j]:match("^%.%.%.%s*$") then i = j + 1 break end
    end
  end
  while i <= #lines do
    local text = lines[i]:gsub("\n$", "")
    local indent, run = text:match("^( *)(```+)")
    if not run then indent, run = text:match("^( *)(~~~+)") end
    if fence then
      if run and #indent <= 3 and run:sub(1, 1) == fence.char and #run >= fence.len
        and text:match("^ *[`~]+%s*$") then
        fence = nil
      end
    elseif run and #indent <= 3
      and not (run:sub(1, 1) == "`" and text:sub(#indent + #run + 1):find("`", 1, true)) then
      fence = { char = run:sub(1, 1), len = #run }
      paragraph = nil
    else
      local hashes, rest = text:match("^ ? ? ?(#+)(.*)$")
      if hashes and #hashes <= 6 and (rest == "" or rest:match("^[ \t]")) then
        rest = rest:gsub("^%s+", ""):gsub("%s+#+%s*$", ""):gsub("^#+%s*$", ""):gsub("%s+$", "")
        if rest ~= "" then add(#hashes, rest, i) end
        paragraph = nil
      elseif paragraph and (text:match("^ ? ? ?=+%s*$") or text:match("^ ? ? ?%-+%s*$")) then
        local name = lines[paragraph]:gsub("^%s+", ""):gsub("%s+$", "")
        add(text:match("=") and 1 or 2, name, paragraph)
        paragraph = nil
      elseif text:match("^%s*$") then
        paragraph = nil
      elseif text:match("^ ? ? ?[>|<]") or text:match("^ ? ? ?[%-%*%+]%s")
        or text:match("^ ? ? ?%d+[.)]%s") or thematic_break(text) then
        -- a quote, table, HTML, list item or thematic break: no setext heading
        paragraph = nil
      elseif not paragraph and not text:match("^    ") then
        paragraph = i
      end
    end
    i = i + 1
  end
  close(1, #lines)
  for _, s in ipairs(list) do s.level = nil end
  return list
end


------------------------------------------------------------------------------
-- Document symbols, from the lsp plugin or, for a file no configured server
-- handles, a provider of breadcrumbs.symbol_providers, per doc: { list, top
-- (the top-level ones, each with `children`), change_id (of the doc when last
-- asked), pending (asking) }

local symbol_state = setmetatable({}, { __mode = "k" })

---Nests the symbols of lsp.get_document_symbols's list by depth.
local function symbol_tree(list)
  local top, stack = {}, {}
  for _, s in ipairs(list) do
    if not s.uri then
      s.children = nil
      while #stack > 0 and stack[#stack].depth >= s.depth do table.remove(stack) end
      local parent = stack[#stack]
      if parent and parent.depth == s.depth - 1 then
        parent.children = parent.children or {}
        table.insert(parent.children, s)
      else
        table.insert(top, s)
      end
      table.insert(stack, s)
    end
  end
  return top
end

---Whether a configured server handles the doc's file (it may still be starting).
local function has_server(doc)
  local l = lsp()
  if not l then return false end
  for _, server in pairs(l.servers or {}) do
    if server.file_patterns and common.match_pattern(doc.filename, server.file_patterns) then
      return true
    end
  end
  return false
end

local function doc_is_open(doc)
  for _, d in ipairs(core.docs) do if d == doc then return true end end
  return false
end

---The doc's symbol provider, for a file no configured server handles.
local function symbol_provider(doc)
  local provider = doc.syntax and breadcrumbs.symbol_providers[doc.syntax.name]
  if provider and not has_server(doc) then return provider end
end

---Asks for the doc's symbols if it changed since they were last asked for:
---once edits pause (config.plugins.breadcrumbs.symbol_delay), and while its
---server starts, every second for a while.
local function refresh_symbols(doc)
  if not (config.plugins.breadcrumbs.symbols and doc.filename) then return end
  local l = lsp()
  local provider = symbol_provider(doc)
  if not provider and not (l and l.get_document_symbols) then return end
  local st = symbol_state[doc]
  if not st then st = {}; symbol_state[doc] = st end
  if st.pending or st.change_id == doc:get_change_id() then return end
  st.pending = true
  local function got(id, list)
    st.pending = false
    st.change_id = id
    if list then st.list, st.top = list, symbol_tree(list) end
    st.chain_key = nil
    core.redraw = true
  end
  core.add_thread(function()
    if st.list then
      repeat
        local id = doc:get_change_id()
        coroutine.yield(config.plugins.breadcrumbs.symbol_delay)
      until id == doc:get_change_id()
    end
    if provider then
      if not doc_is_open(doc) then st.pending = false return end
      local id = doc:get_change_id()
      local ok, list = pcall(provider, doc)
      if not ok then core.error("breadcrumbs: symbols of %s: %s", doc.filename, list) end
      got(id, ok and list or {})
      return
    end
    for _ = 1, 30 do
      if not doc_is_open(doc) then st.pending = false return end
      local id = doc:get_change_id()
      local asked = l.get_document_symbols(doc, function(list) got(id, list) end)
      if asked then return end
      if not has_server(doc) then break end
      coroutine.yield(1)
    end
    st.pending = false
    st.change_id = doc:get_change_id()
  end)
end

---Whether position (0-based line, utf-16 character) is within the range.
local function in_range(range, line, char)
  local s, e = range.start, range["end"]
  return (line > s.line or line == s.line and char >= s.character)
    and (line < e.line or line == e.line and char <= e.character)
end

---The symbols around the cursor, outermost first, and the top-level ones.
local function symbol_chain(doc)
  local st = symbol_state[doc]
  if not (st and st.top) then return {}, nil end
  local line, col = doc:get_selection()
  local key = table.concat({ tostring(st.list), line, col, doc:get_change_id() }, ":")
  if st.chain_key ~= key then
    local util = lsp_util()
    local char = (util and util.doc_utf8_to_utf16(doc, line, col) or col) - 1
    local chain, level = {}, st.top
    while level do
      local found
      for _, s in ipairs(level) do
        if in_range(s.range, line - 1, char) then found = s end
      end
      if not found then break end
      table.insert(chain, found)
      level = found.children
    end
    st.chain, st.chain_key = chain, key
  end
  return st.chain, st.top
end

local function jump_to_symbol(view, s)
  local doc = view.doc
  local util = lsp_util()
  local line, col
  if util then
    line, col = util.toselection(s.name_range, doc)
  else
    line, col = s.name_range.start.line + 1, s.name_range.start.character + 1
  end
  line = common.clamp(line, 1, #doc.lines)
  core.set_active_view(view)
  doc:set_selection(line, col, line, col)
  view:scroll_to_line(line, true)
end

local function symbol_rows(view, symbols)
  local rows = {}
  for _, s in ipairs(symbols) do
    local children = s.children
    table.insert(rows, {
      text = s.name, detail = s.detail, key = s, icon = symbol_icon(s.kind),
      action = function() jump_to_symbol(view, s) end,
      children = children and function() return symbol_rows(view, children) end,
    })
  end
  return rows
end


------------------------------------------------------------------------------
-- The bar's parts: { text, color?, rows() (the dropdown's), key (preselected
-- in it) }

---The path's parts: its project directory's name, else ~ or the root, then
---each directory and the file.
local function path_parts(view, path)
  local parts = {}
  local base, rel = project_dir_of(path), nil
  if base then
    parts[1] = { text = common.basename(base), path = base }
  elseif HOME and common.path_belongs_to(path, HOME) then
    base = HOME
    parts[1] = { text = "~", path = HOME }
  else
    base = path:match("^[^" .. PATHSEP .. "]*" .. PATHSEP)
    parts[1] = { text = base == "/" and "/" or base:sub(1, -2), path = base, root = true }
  end
  rel = path:sub(#base + (base:sub(-1) == PATHSEP and 1 or 2))
  local dir = base
  for name in rel:gmatch("[^" .. PATHSEP .. "]+") do
    dir = join(dir, name)
    table.insert(parts, { text = name, path = dir })
  end
  for _, p in ipairs(parts) do
    local p_path = p.path
    -- the parts beside it (the root's: what's in it)
    local parent = not p.root and common.dirname(p_path) or p_path
    p.rows = function() return dir_rows(parent, view) end
    p.key = p_path
    p.color = style.dim
  end
  parts[#parts].color = style.text
  parts[#parts].file = true
  parts[#parts].icon = file_icon(parts[#parts].text, "file")
  return parts
end

local function view_parts(view)
  local doc = view.doc
  local parts = path_parts(view, doc.abs_filename)
  if not config.plugins.breadcrumbs.symbols then return parts end
  refresh_symbols(doc)
  local chain, top = symbol_chain(doc)
  if not top or #top == 0 then return parts end
  local siblings = top
  for _, s in ipairs(chain) do
    local level = siblings
    table.insert(parts, {
      text = s.name, color = style.text, key = s, symbol = true, icon = symbol_icon(s.kind),
      rows = function() return symbol_rows(view, level) end,
    })
    siblings = s.children
  end
  if #chain == 0 then
    table.insert(parts, {
      text = "…", color = style.dim, symbol = true,
      rows = function() return symbol_rows(view, top) end,
    })
  end
  return parts
end


------------------------------------------------------------------------------
-- The bar, at the top of a node's active DocView: node.breadcrumbs =
-- { x, y, w, h, view, parts (laid out when drawn: each with x and w) }

local function shows_bar(node, view)
  return config.plugins.breadcrumbs.enabled and not node.locked
    and view:extends(DocView) and not view:extends(CommandView)
    and view.breadcrumbs ~= false and view.doc and view.doc.abs_filename ~= nil
end

local node_update_layout = Node.update_layout
function Node:update_layout()
  node_update_layout(self)
  if self.type ~= "leaf" then return end
  local av = self.active_view
  if shows_bar(self, av) then
    local h = math.min(bar_height(), av.size.y)
    local bar = self.breadcrumbs
    if not bar or bar.view ~= av then bar = { view = av } end
    bar.x, bar.y, bar.w, bar.h = av.position.x, av.position.y, av.size.x, h
    self.breadcrumbs = bar
    av.position.y = av.position.y + h
    av.size.y = av.size.y - h
  else
    self.breadcrumbs = nil
  end
end

-- hovered: { node, index } of the part under the mouse; open: the dropdowns
-- shown, { node, index (the part they're from), stack (deepest last),
-- keyboard }
local hovered
local open

local function separator_width()
  return math.floor(style.font:get_height() * 0.6)
end

local function part_padding()
  return math.floor(style.padding.x / 3)
end

---Each run of hidden parts as one "…" part, which drops down the last of them.
local function with_ellipses(parts, hidden)
  local shown = {}
  for i, p in ipairs(parts) do
    if not hidden[i] then
      table.insert(shown, p)
    elseif not hidden[i + 1] then
      table.insert(shown, { text = "…", color = style.dim, rows = p.rows, key = p.key })
    end
  end
  return shown
end

---Lays the parts out from the bar's left. Those that don't fit give way to
---"…": the directories between the first part and the file, nearest the first
---first, then the outer symbols, the first part, the file; never the last part.
local function layout(bar)
  local parts = view_parts(bar.view)
  local font, pad, sep = style.font, part_padding(), separator_width()
  local function total_width(list)
    local w = style.padding.x / 2 - pad
    for i, p in ipairs(list) do
      w = w + icon_width(p.icon) + font:get_width(p.text) + pad * 2 + (i > 1 and sep or 0)
    end
    return w
  end
  local max = bar.w - style.padding.x / 2
  if total_width(parts) > max then
    local file_index = 1
    for i, p in ipairs(parts) do if p.file then file_index = i end end
    local order = {}
    for i = 2, file_index - 1 do table.insert(order, i) end
    for i = file_index + 1, #parts - 1 do table.insert(order, i) end
    table.insert(order, 1)
    table.insert(order, file_index)
    local hidden = {}
    for _, i in ipairs(order) do
      if i >= #parts then break end
      hidden[i] = true
      if total_width(with_ellipses(parts, hidden)) <= max then break end
    end
    parts = with_ellipses(parts, hidden)
  end
  local x = bar.x + style.padding.x / 2 - pad
  for i, p in ipairs(parts) do
    if i > 1 then x = x + sep end
    p.x, p.w = x, icon_width(p.icon) + font:get_width(p.text) + pad * 2
    x = x + p.w
  end
  bar.parts = parts
end

local function draw_separator(x, y, w, h, color)
  local s = math.floor(h * 0.22)
  local cx, cy = math.floor(x + w / 2), math.floor(y + h / 2)
  local t = math.max(1, math.floor(SCALE))
  renderer.draw_path({
    "M", cx - s / 2, cy - s, "L", cx + s / 2, cy, "L", cx - s / 2, cy + s,
  }, color, t)
end

local function draw_bar(node)
  local bar = node.breadcrumbs
  layout(bar)
  core.push_clip_rect(bar.x, bar.y, bar.w, bar.h)
  renderer.draw_rect(bar.x, bar.y, bar.w, bar.h, style.background)
  local font, sep = style.font, separator_width()
  for i, p in ipairs(bar.parts) do
    if i > 1 then draw_separator(p.x - sep, bar.y, sep, bar.h, style.dim) end
    local is_open = open and open.node == node and open.index == i
    local is_hovered = hovered and hovered.node == node and hovered.index == i
    if (is_open or is_hovered) and p.rows then
      local m = math.floor(2 * SCALE)
      renderer.draw_rect(p.x, bar.y + m, p.w, bar.h - m * 2, style.line_highlight)
    end
    local color = is_open and style.accent or is_hovered and p.rows and style.text or p.color
    local tx = draw_icon(p.icon, p.x + part_padding(), bar.y, bar.h)
    common.draw_text(font, color, p.text, "left", tx, bar.y, p.w, bar.h)
  end
  core.pop_clip_rect()
end

---The divider under the bar, over the top of the view's text.
local function draw_divider(bar)
  local kind = config.plugins.breadcrumbs.divider
  local y = bar.y + bar.h
  if kind == "line" then
    -- the dim text's color, faint: style.divider is often too faint on the
    -- editor's background
    local c = style.dim
    renderer.draw_rect(bar.x, y, bar.w, math.max(1, math.floor(SCALE)),
      { c[1], c[2], c[3], (c[4] or 255) * 0.35 })
  elseif kind == "shadow" and style.popup_shadow then
    local blur = math.floor(5 * SCALE)
    core.push_clip_rect(bar.x, y, bar.w, blur * 2)
    -- the bar's shadow, light from above (moved down, as popups'); wider than
    -- the bar, so its ends don't fade
    renderer.draw_shadow(bar.x - blur * 2, bar.y + math.floor(2 * SCALE),
      bar.w + blur * 4, bar.h, blur, style.popup_shadow)
    core.pop_clip_rect()
  end
end

local node_draw = Node.draw
function Node:draw()
  node_draw(self)
  if self.type == "leaf" and self.breadcrumbs then
    draw_bar(self)
    draw_divider(self.breadcrumbs)
  end
end

---The node whose bar is under the point, and the index of the part there.
local function bar_at(x, y)
  local node = core.root_view.root_node:get_child_overlapping_point(x, y)
  local bar = node and node.breadcrumbs
  if not bar or x < bar.x or x >= bar.x + bar.w or y < bar.y or y >= bar.y + bar.h then
    return nil
  end
  for i, p in ipairs(bar.parts or {}) do
    if x >= p.x and x < p.x + p.w then return node, p.rows and i or nil end
  end
  return node, nil
end


------------------------------------------------------------------------------
-- Dropdowns: scrolling lists of rows, filtered by typing

local Dropdown = Object:extend()

---`current`: the keys of the rows on the bar's path (shown in the accent
---color, the first one selected).
function Dropdown:new(rows, current)
  self.all_rows = rows
  self.filter = ""
  self.rows = rows
  self.selected = nil
  self.scroll = 0
  self.current = current
  for i, r in ipairs(rows) do
    if r.key ~= nil and current[r.key] then self.selected = i break end
  end
  local font = style.font
  local w = 0
  -- one column for the icons, as wide as the widest
  self.icon_w = 0
  for _, r in ipairs(rows) do self.icon_w = math.max(self.icon_w, icon_width(r.icon)) end
  for _, r in ipairs(rows) do
    local rw = self.icon_w + font:get_width(r.text)
    if r.detail then rw = rw + style.padding.x + font:get_width(r.detail) end
    w = math.max(w, rw)
  end
  local arrow = style.icon_font:get_width("+") + style.padding.x / 2
  self.w = math.floor(math.min(w + style.padding.x * 2 + arrow,
    core.root_view.size.x * 0.6))
  self.w = math.max(self.w, math.floor(160 * SCALE))
end

function Dropdown:visible_rows()
  local max = self.max_rows or config.plugins.breadcrumbs.max_rows
  return math.min(math.max(#self.rows, 1), max)
end

function Dropdown:filter_height()
  return self.filter ~= "" and row_height() or 0
end

function Dropdown:height()
  return self:filter_height() + self:visible_rows() * row_height()
end

---Places it at x, y, moved to fit the window; with `below`, showing no more
---rows than fit below y (a row kept free for the filter).
function Dropdown:place(x, y, below)
  local rw, rh = core.root_view.size.x, core.root_view.size.y
  if below ~= nil then
    local space = below and rh - y - style.padding.y or rh
    self.max_rows = math.max(3, math.min(config.plugins.breadcrumbs.max_rows,
      math.floor(space / row_height()) - 1))
  end
  self.x = common.clamp(x, 0, math.max(0, rw - self.w))
  self.y = common.clamp(y, 0, math.max(0, rh - self:height()))
end

function Dropdown:scroll_to_selected()
  local n = self:visible_rows()
  if self.selected <= self.scroll then
    self.scroll = self.selected - 1
  elseif self.selected > self.scroll + n then
    self.scroll = self.selected - n
  end
  self.scroll = common.clamp(self.scroll, 0, math.max(0, #self.rows - n))
end

function Dropdown:set_filter(text)
  self.filter = text
  if text == "" then
    self.rows = self.all_rows
  else
    local scored = {}
    for i, r in ipairs(self.all_rows) do
      local score = system.fuzzy_match(r.text, text, false)
      if score then table.insert(scored, { r = r, score = score, i = i }) end
    end
    table.sort(scored, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.i < b.i
    end)
    self.rows = {}
    for i, m in ipairs(scored) do self.rows[i] = m.r end
  end
  self.selected, self.scroll = 1, 0
  self:place(self.x, self.y)
end

function Dropdown:contains(x, y)
  return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self:height()
end

function Dropdown:row_at(x, y)
  if not self:contains(x, y) then return end
  local top = self.y + self:filter_height()
  if y < top then return end
  local i = self.scroll + math.floor((y - top) / row_height()) + 1
  if self.rows[i] then return i end
end

function Dropdown:row_y(i)
  return self.y + self:filter_height() + (i - self.scroll - 1) * row_height()
end

function Dropdown:draw()
  local x, y, w, h = self.x, self.y, self.w, self:height()
  common.draw_popup_box(x, y, w, h)
  core.push_clip_rect(x, y, w, h)
  local font, rh = style.font, row_height()
  local pad = style.padding.x
  if self.filter ~= "" then
    renderer.draw_rect(x, y, w, rh, style.line_highlight)
    common.draw_text(font, style.accent, self.filter, "left", x + pad, y, w - pad * 2, rh)
  end
  if #self.rows == 0 then
    common.draw_text(font, style.dim, "No matches", "left", x + pad, self:row_y(1), w, rh)
  end
  local n = self:visible_rows()
  for i = self.scroll + 1, math.min(#self.rows, self.scroll + n) do
    local r = self.rows[i]
    local ry = self:row_y(i)
    if i == self.selected then renderer.draw_rect(x, ry, w, rh, style.selection) end
    local color = r.key ~= nil and self.current[r.key] and style.accent or style.text
    local tx = x + pad
    draw_icon(r.icon, tx, ry, rh)
    tx = tx + self.icon_w
    local right = x + w - pad
    if r.children then
      right = right - style.icon_font:get_width("+")
      common.draw_text(style.icon_font, style.dim, "+", "left", right, ry, w, rh)
      right = right - pad / 2
    end
    local text_end = common.draw_text(font, color, r.text, "left", tx, ry, w, rh)
    if r.detail and right - text_end > pad * 2 then
      core.push_clip_rect(text_end + pad, ry, right - text_end - pad, rh)
      common.draw_text(font, style.dim, r.detail, "left", text_end + pad, ry, w, rh)
      core.pop_clip_rect()
    end
  end
  -- where the visible rows are in the list
  if #self.rows > n then
    local track = n * rh
    local th = math.max(math.floor(track * n / #self.rows), math.floor(8 * SCALE))
    local ty = self:row_y(self.scroll + 1)
      + math.floor((track - th) * self.scroll / (#self.rows - n))
    local tw = math.max(2, math.floor(3 * SCALE))
    renderer.draw_rect(x + w - tw - 1, ty, tw, th, style.scrollbar or style.dim)
  end
  core.pop_clip_rect()
end


------------------------------------------------------------------------------
-- The open dropdowns, as core.context_menu: they take the keyboard

local menu = { show_context_menu = false }

local function close_all()
  if not open then return end
  open = nil
  if core.context_menu == menu then core.context_menu = nil end
  menu.show_context_menu = false
  core.redraw = true
  core.root_view:recheck_pointer()
end

function menu:hide() close_all() end

table.insert(core.popup_closers, function()
  open = nil
  menu.show_context_menu = false
end)

local function deepest() return open and open.stack[#open.stack] end

---Opens the dropdown of part `index` of the node's bar.
local function open_part(node, index, keyboard)
  local bar = node.breadcrumbs
  local p = bar and bar.parts and bar.parts[index]
  if not (p and p.rows) then return false end
  local rows = p.rows()
  if not rows or #rows == 0 then return false end
  -- the parts' keys, from this one
  local current = {}
  for j = index, #bar.parts do
    if bar.parts[j].key ~= nil then current[bar.parts[j].key] = true end
  end
  local d = Dropdown(rows, current)
  d.selected = d.selected or 1
  d:place(p.x, bar.y + bar.h, true)
  d:scroll_to_selected()
  if open then
    open.node, open.index, open.stack = node, index, { d }
  else
    open = { node = node, index = index, stack = { d } }
  end
  open.keyboard = keyboard
  if core.context_menu and core.context_menu ~= menu then core.context_menu:hide() end
  core.context_menu = menu
  menu.show_context_menu = true
  hovered = nil
  core.request_cursor("arrow")
  core.redraw = true
  return true
end

---Opens the submenu of the selected row of level `level`, if it has one.
local function open_submenu(level)
  local d = open.stack[level]
  local r = d.rows[d.selected]
  for j = #open.stack, level + 1, -1 do
    if j == level + 1 and open.stack[j].parent_row == r then return open.stack[j] end
    open.stack[j] = nil
  end
  if not (r and r.children) then return end
  local rows = r.children()
  if not rows or #rows == 0 then return end
  local sub = Dropdown(rows, d.current)
  -- nothing selected until it's entered, unless on the bar's path
  sub.selected = sub.selected or 0
  sub.parent_row = r
  local x = d.x + d.w
  if x + sub.w > core.root_view.size.x then x = math.max(0, d.x - sub.w) end
  -- below the bar, as the first dropdown
  local top = open.stack[1].y
  sub.max_rows = math.max(3, math.min(config.plugins.breadcrumbs.max_rows,
    math.floor((core.root_view.size.y - top) / row_height()) - 1))
  sub:place(x, d:row_y(d.selected))
  sub:scroll_to_selected()
  open.stack[level + 1] = sub
  core.redraw = true
  return sub
end

local function select_row(d, i)
  if #d.rows == 0 then return end
  d.selected = common.clamp(i, 1, #d.rows)
  d:scroll_to_selected()
  core.redraw = true
end

---Chooses the selected row of level `level` (the deepest by default): its
---action, else its submenu.
local function choose(level)
  level = level or #open.stack
  local d = open.stack[level]
  local r = d and d.rows[d.selected]
  if not r then return end
  if r.action then
    close_all()
    r.action()
  elseif r.children then
    local sub = open_submenu(level)
    if sub then select_row(sub, math.max(1, sub.selected)) end
  end
end

---Moves to the part dir (1 or -1) from the open one, from the keyboard.
local function step_part(dir)
  local bar = open.node.breadcrumbs
  local i = open.index
  for _ = 1, #bar.parts do
    i = (i - 1 + dir) % #bar.parts + 1
    if bar.parts[i].rows and open_part(open.node, i, true) then return end
  end
end

function menu:on_key_pressed(key)
  local d = deepest()
  if not d then close_all() return end
  local level = #open.stack
  local page = math.max(1, d:visible_rows() - 1)
  if key == "up" then
    select_row(d, d.selected <= 1 and #d.rows or d.selected - 1)
  elseif key == "down" then
    select_row(d, d.selected >= #d.rows and 1 or d.selected + 1)
  elseif key == "pageup" then
    select_row(d, d.selected - page)
  elseif key == "pagedown" then
    select_row(d, d.selected + page)
  elseif key == "home" then
    select_row(d, 1)
  elseif key == "end" then
    select_row(d, #d.rows)
  elseif key == "right" then
    local r = d.rows[d.selected]
    if r and r.children then
      local sub = open_submenu(level)
      if sub then select_row(sub, math.max(1, sub.selected)) end
    elseif level == 1 then
      step_part(1)
    end
  elseif key == "left" then
    if level > 1 then
      open.stack[level] = nil
      core.redraw = true
    else
      step_part(-1)
    end
  elseif key == "return" or key == "keypad enter" then
    choose()
  elseif key == "backspace" then
    if d.filter ~= "" then d:set_filter(d.filter:sub(1, utf8.offset(d.filter, -1) - 1)) end
    core.redraw = true
  elseif key == "escape" then
    if d.filter ~= "" then
      d:set_filter("")
      select_row(d, 1)
    elseif level > 1 then
      open.stack[level] = nil
    else
      close_all()
    end
    core.redraw = true
  end
end

function menu:on_text_input(text)
  local d = deepest()
  if not d then return end
  d:set_filter(d.filter .. text)
  core.redraw = true
end

---The deepest dropdown containing the point, and its level.
local function dropdown_at(x, y)
  if not open then return end
  for level = #open.stack, 1, -1 do
    if open.stack[level]:contains(x, y) then return open.stack[level], level end
  end
end


------------------------------------------------------------------------------
-- Mouse and drawing

local mouse_down = false

local root_view_on_mouse_pressed = RootView.on_mouse_pressed
function RootView:on_mouse_pressed(button, x, y, clicks)
  if open then
    local d, level = dropdown_at(x, y)
    if d then
      local i = d:row_at(x, y)
      if i and button == "left" then
        d.selected = i
        choose(level)
      end
      return true
    end
    local node, index = bar_at(x, y)
    local same = node == open.node and index == open.index
    close_all()
    if node and index and not same and button == "left" then open_part(node, index) end
    return true
  end
  local node, index = bar_at(x, y)
  if node then
    if index and button == "left" then
      core.set_active_view(node.breadcrumbs.view)
      open_part(node, index)
    end
    return true
  end
  mouse_down = true
  return root_view_on_mouse_pressed(self, button, x, y, clicks)
end

local root_view_on_mouse_released = RootView.on_mouse_released
function RootView:on_mouse_released(...)
  mouse_down = false
  return root_view_on_mouse_released(self, ...)
end

local function set_hovered(node, index)
  local h = node and index and { node = node, index = index } or nil
  if (h and h.node) ~= (hovered and hovered.node) or (h and h.index) ~= (hovered and hovered.index) then
    hovered = h
    core.redraw = true
  end
end

local root_view_on_mouse_moved = RootView.on_mouse_moved
function RootView:on_mouse_moved(x, y, dx, dy)
  if open and not self.touch then
    self.mouse.x, self.mouse.y = x, y
    core.request_cursor("arrow")
    local d, level = dropdown_at(x, y)
    if d then
      local i = d:row_at(x, y)
      if i and i ~= d.selected then
        d.selected = i
        core.redraw = true
      end
      if i then open_submenu(level) end
      return
    end
    -- over another part of the bar: its dropdown instead
    local node, index = bar_at(x, y)
    if node == open.node and index and index ~= open.index then
      open_part(node, index, open.keyboard)
    end
    return
  end
  local node, index = bar_at(x, y)
  if node and not mouse_down and not self.dragged_node and not self.dragged_divider then
    self.mouse.x, self.mouse.y = x, y
    if self.overlapping_node then
      self.overlapping_node:on_mouse_left()
      self.overlapping_node = nil
    end
    set_hovered(node, index)
    core.request_cursor("arrow")
    return
  end
  set_hovered(nil)
  return root_view_on_mouse_moved(self, x, y, dx, dy)
end

local root_view_on_mouse_left = RootView.on_mouse_left
function RootView:on_mouse_left(...)
  set_hovered(nil)
  return root_view_on_mouse_left(self, ...)
end

local root_view_on_mouse_wheel = RootView.on_mouse_wheel
function RootView:on_mouse_wheel(dy, dx)
  local x, y = self.mouse.x, self.mouse.y
  if open then
    local d = dropdown_at(x, y)
    if d and dy ~= 0 then
      local n = d:visible_rows()
      d.scroll = common.clamp(d.scroll - (dy > 0 and 3 or -3), 0, math.max(0, #d.rows - n))
      d.selected = d:row_at(x, y) or d.selected
      core.redraw = true
    end
    return true
  end
  if bar_at(x, y) then return true end
  return root_view_on_mouse_wheel(self, dy, dx)
end

local function draw_dropdowns()
  if not open then return end
  for _, d in ipairs(open.stack) do d:draw() end
end

local root_view_draw = RootView.draw
function RootView:draw(...)
  -- deferred before the views draw: drawn after (over) what they defer
  if open then self:defer_draw(draw_dropdowns) end
  return root_view_draw(self, ...)
end

local root_view_update = RootView.update
function RootView:update(...)
  root_view_update(self, ...)
  -- the view the dropdowns are for went away
  if open and not (open.node.breadcrumbs and open.node.breadcrumbs.parts) then close_all() end
end


------------------------------------------------------------------------------
-- Commands

local function active_bar_node()
  local view = core.active_view
  local node = core.root_view.root_node:get_node_for_view(view)
  return node and node.breadcrumbs and node.breadcrumbs.view == view and node or nil
end

command.add(function() return active_bar_node() ~= nil end, {
  ["breadcrumbs:focus"] = function()
    local node = active_bar_node()
    local parts = node.breadcrumbs.parts
    if not parts then return end
    for i = #parts, 1, -1 do
      if parts[i].rows and open_part(node, i, true) then return end
    end
  end,
})

command.add(nil, {
  ["breadcrumbs:toggle"] = function()
    config.plugins.breadcrumbs.enabled = not config.plugins.breadcrumbs.enabled
    core.redraw = true
  end,
})

keymap.add { ["ctrl+shift+."] = "breadcrumbs:focus" }

breadcrumbs.Dropdown = Dropdown
breadcrumbs.close = close_all

return breadcrumbs
