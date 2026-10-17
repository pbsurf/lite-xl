-- mod-version:3
-- Ctrl+click opens the link under the mouse: a URL (with or without a protocol) or a
-- DOI in the browser, a [[wiki link]] or the path of an existing file (optionally
-- with :line[:col]) in the editor. Links can be underlined; paths are underlined
-- only under the mouse while ctrl is held. "Search Web" in the context menu
-- searches for the selection. Ported from a SciTE script (url.lua).
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"

config.plugins.openurl = common.merge({
  -- underline links in documents
  underline = true,
  -- DOIs open as doi_url .. doi
  doi_url = "https://sci-hub.box/",
  -- the selection is searched for at search_url .. query
  search_url = "https://www.google.com/search?q=",
  -- command that opens URLs, given the URL as its argument; empty for the
  -- system's default handler (system.open_url)
  launcher = "",
  config_spec = {
    name = "Open URL",
    {
      label = "Underline Links",
      description = "Underline URLs, DOIs and [[wiki links]] in documents.",
      path = "underline",
      type = "toggle",
      default = true,
    },
    {
      label = "DOI URL",
      description = "URL a DOI is appended to when opened.",
      path = "doi_url",
      type = "string",
      default = "https://sci-hub.box/",
    },
    {
      label = "Search URL",
      description = "URL the selection is appended to by Search Web.",
      path = "search_url",
      type = "string",
      default = "https://www.google.com/search?q=",
    },
    {
      label = "Launcher",
      description = "Command that opens URLs; empty for the system's default.",
      path = "launcher",
      type = "string",
      default = "",
    },
  }
}, config.plugins.openurl)


local URL_TAIL = "/[^%s'\"<>]+"

-- in priority order: a match overlapping an earlier one is dropped (e.g. the host of
-- a URL as a URL without protocol, or a DOI inside a doi.org URL)
local link_patterns = {
  { kind = "wiki", prefix = "%[%[([^%]]+)%]%]" },
  { kind = "url", prefix = "[a-z]+://[%w%-%.]+", suffix = URL_TAIL },
  { kind = "host", prefix = "[%w%-%.]+%.com%f[^%w]", suffix = URL_TAIL },
  { kind = "host", prefix = "[%w%-%.]+%.org%f[^%w]", suffix = URL_TAIL },
  { kind = "host", prefix = "[%w%-%.]+%.edu%f[^%w]", suffix = URL_TAIL },
  { kind = "host", prefix = "[%w%-%.]+%.net%f[^%w]", suffix = URL_TAIL },
  { kind = "host", prefix = "www%.[%w%-%.]+", suffix = URL_TAIL },
  -- registrants have 4+ digits; fewer would match divisions like 10.5/2 in code
  { kind = "doi", prefix = "%f[%w]10%.%d%d%d%d+/[%w%-%.%(%)/:_;]+" },
}

local function overlaps(links, s, e)
  for _, l in ipairs(links) do
    if s <= l.stop and e >= l.start then return true end
  end
  return false
end

-- all matches of prefix (+ optional suffix) in text, without trailing punctuation
-- and without a trailing ')' that has no '(' in the link (the link is in parentheses)
local function find_matches(text, p, links)
  local init = 1
  while true do
    local s, e, capture = text:find(p.prefix, init)
    if not s then break end
    if p.suffix then
      local _, se = text:find("^" .. p.suffix, e + 1)
      e = se or e
    end
    init = e + 1
    -- open parentheses in the link; can't use %b() since URLs can have unbalanced ones
    local _, opens = text:sub(s, e):gsub("%(", "")
    local _, closes = text:sub(s, e):gsub("%)", "")
    while e >= s do
      local last = text:sub(e, e)
      if last == "," or last == "." or last == ":" or last == ";" then
        e = e - 1
      elseif last == ")" and closes > opens then
        e, closes = e - 1, closes - 1
      else
        break
      end
    end
    if e >= s and not overlaps(links, s, e) then
      table.insert(links, { start = s, stop = e, kind = p.kind, target = capture or text:sub(s, e) })
    end
  end
end

-- links by line text; cleared when large, as lines change
local cache, cache_size = {}, 0

local function get_links(text)
  local links = cache[text]
  if links then return links end
  links = {}
  -- every pattern needs one of these
  if text:find("[%.:%[]") then
    for _, p in ipairs(link_patterns) do find_matches(text, p, links) end
  end
  if cache_size >= 2000 then cache, cache_size = {}, 0 end
  cache[text], cache_size = links, cache_size + 1
  return links
end

-- characters of file paths; a path is a run of them with a '/' or a '.' in it
local PATH_CHAR = "[%w_%-%.~+@/]"

-- the path of an existing file, relative to the doc's directory, a project
-- directory, or absolute (or ~/)
local function resolve_path(doc, name)
  name = common.home_expand(name)
  local candidates = {}
  if common.is_absolute_path(name) then
    candidates[1] = name
  else
    if doc.abs_filename then
      table.insert(candidates, common.dirname(doc.abs_filename) .. PATHSEP .. name)
    end
    for _, dir in ipairs(core.project_directories) do
      table.insert(candidates, dir.name .. PATHSEP .. name)
    end
  end
  for _, path in ipairs(candidates) do
    local info = system.get_file_info(path)
    if info and info.type == "file" then return common.normalize_path(path) end
  end
end

-- the last path looked up: paths are looked up under the mouse as it moves and
-- each frame while ctrl is held
local last_key, last_path

-- a link to the existing file whose path contains byte col of line, if any
local function path_at(doc, line, col)
  local text = doc.lines[line]
  if not text:sub(col, col):find(PATH_CHAR) then return end
  local s, e = col, col
  while s > 1 and text:sub(s - 1, s - 1):find(PATH_CHAR) do s = s - 1 end
  while text:sub(e + 1, e + 1):find(PATH_CHAR) do e = e + 1 end
  -- a sentence's period after it
  while e > s and text:sub(e, e) == "." do e = e - 1 end
  if col > e then return end
  local name = text:sub(s, e)
  if not name:find("[/.]") then return end
  local key = table.concat({ tostring(doc), s, e, text }, "\0")
  if key ~= last_key then
    last_key, last_path = key, nil
    local target = resolve_path(doc, name)
    if target then
      last_path = { start = s, stop = e, kind = "path", target = target }
      -- compilers' and debuggers' file:line:col
      local suffix, l, c = text:match("^(:(%d+):?(%d*))", e + 1)
      if suffix then
        last_path.stop = e + #suffix
        last_path.line, last_path.col = tonumber(l), tonumber(c)
      end
    end
  end
  return last_path
end

-- the link containing byte col of line, if any
local function link_at(doc, line, col)
  for _, l in ipairs(get_links(doc.lines[line])) do
    if l.start <= col and col <= l.stop then return l end
  end
  return path_at(doc, line, col)
end

-- the link under the screen position x, y of dv, if any, and its line
local function link_at_point(dv, x, y)
  if dv.hovering_gutter then return end
  local line, col = dv:resolve_screen_position(x, y)
  local lx, ly = dv:get_line_screen_position(line, col)
  if y < ly or y >= ly + dv:get_line_height() then return end
  -- col is the nearest character boundary: left of it is the previous character
  if x < lx then col = col - 1 end
  return link_at(dv.doc, line, col), line
end


local function launch(url)
  core.log("Opening %s", url)
  local launcher = config.plugins.openurl.launcher
  if launcher and launcher ~= "" then
    process.start({ launcher, url }, { detach = true })
  else
    local ok, err = system.open_url(url)
    if not ok then core.error("Can't open %s: %s", url, err) end
  end
end

local function escape_pattern(s)
  return s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
end

local function open_wiki(doc, target)
  local name, section = target:match("^([^#]*)#?(.*)$")
  local dir = doc.abs_filename and common.dirname(doc.abs_filename) or core.project_dir
  -- look in the doc's directory, then its parents
  while dir do
    for _, ext in ipairs({ "", ".md", ".mdwn", ".txt" }) do
      local path = dir .. PATHSEP .. name .. ext
      local info = system.get_file_info(path)
      if info and info.type == "file" then
        local dv = core.root_view:open_doc(core.open_doc(path), { preview = true })
        if section ~= "" then
          local heading = "^#+%s*" .. escape_pattern(section) .. "%s*#*%s*$"
          for i, text in ipairs(dv.doc.lines) do
            if text:match(heading) then
              dv.doc:set_selection(i, 1)
              dv:scroll_to_line(i, true, true)
              break
            end
          end
        end
        return
      end
    end
    dir = common.dirname(dir)
  end
  core.error("No file found for [[%s]]", target)
end

local function open_path(link)
  local dv = core.root_view:open_doc(core.open_doc(core.normalize_to_project_dir(link.target)),
    { preview = true })
  if link.line then
    dv.doc:set_selection(link.line, link.col or 1)
    dv:scroll_to_line(link.line, true, true)
  end
end

local function open_link(dv, link)
  if link.kind == "path" then
    open_path(link)
  elseif link.kind == "wiki" then
    open_wiki(dv.doc, link.target)
  elseif link.kind == "url" then
    launch(link.target)
  elseif link.kind == "host" then
    launch("http://" .. link.target)
  elseif link.kind == "doi" then
    launch(config.plugins.openurl.doi_url .. link.target)
  end
end


command.add(function(x, y)
  local dv = core.active_view
  if not (x and y and dv:extends(DocView)) then return false end
  local link = link_at_point(dv, x, y)
  return link ~= nil, dv, link
end, {
  ["open-url:open-at-mouse"] = open_link,
})
command.hidden["open-url:open-at-mouse"] = true

command.add(function()
  local dv = core.active_view
  if not dv:extends(DocView) then return false end
  local line, col = dv.doc:get_selection()
  -- the caret may be just after the link
  local link = link_at(dv.doc, line, col) or link_at(dv.doc, line, col - 1)
  return link ~= nil, dv, link
end, {
  ["open-url:open-at-caret"] = open_link,
})

-- query string encoding: whitespace runs as +, all but unreserved bytes as %XX
local function encode_query(text)
  text = text:match("^%s*(.-)%s*$"):gsub("%s+", " ")
  return (text:gsub("[^%w%-%._~ ]", function(c)
    return string.format("%%%02X", c:byte())
  end):gsub(" ", "+"))
end

local function has_selection()
  local dv = core.active_view
  return dv:extends(DocView) and dv.doc:has_selection(), dv
end

command.add(has_selection, {
  ["open-url:search-selection"] = function(dv)
    local text = dv.doc:get_text(dv.doc:get_selection())
    if text:find("%S") then
      launch(config.plugins.openurl.search_url .. encode_query(text))
    end
  end,
})

local menu_found, menu = pcall(require, "plugins.contextmenu")
if menu_found then
  -- with its divider, only while there's a selection
  menu:register(has_selection, {
    menu.DIVIDER,
    { text = "Search Web", command = "open-url:search-selection" },
  })
end

-- added after lsp (plugins load by name), so links win over its ctrl+click
keymap.add { ["ctrl+1lclick"] = "open-url:open-at-mouse" }


local DocView_draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  local lh = DocView_draw_line_text(self, line, x, y)
  local underline = config.plugins.openurl.underline
  if underline then
    for _, l in ipairs(get_links(self.doc.lines[line])) do
      self:draw_underline(line, x, y, l.start, l.stop + 1)
    end
  end
  -- the link ctrl+click would open (its underline drawn twice if underlined already)
  local hx, hy = self:get_ctrl_hover()
  if hx and self:resolve_screen_position(hx, hy) == line then
    local link = link_at_point(self, hx, hy)
    if link then
      self:draw_ctrl_hover(line, x, y, link.start, link.stop + 1)
    end
  end
  return lh
end
