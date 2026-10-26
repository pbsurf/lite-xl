-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local style = require "core.style"
local View = require "core.view"
local panel = require "core.panel"
local ResultsList = require "core.resultslist"

---@class plugins.projectsearch.resultsview : core.view
local ResultsView = View:extend()

-- The results are a tab in the bottom panel (core.panel), reused by the next
-- search unless kept, to step through with the keyboard (core.resultslist),
-- the match selected in the file shown. The tab's title is the search's status,
-- its progress drawn behind it; its tooltip has the search's details.
function ResultsView:__tostring() return "ResultsView" end

ResultsView.context = "session"

---@param info? plugins.projectsearch.info
function ResultsView:new(path, text, fn, info)
  ResultsView.super.new(self)
  self.scrollable = true
  self.max_h_scroll = 0
  self.hovered_idx = 0
  self.generation = 0
  self:begin_search(path, text, fn, info)
end


function ResultsView:get_name()
  return string.format("Search \"%s\": %d", self.query, #self.results)
end


function ResultsView:get_progress()
  if not self.searching then return nil end
  local files_number = core.project_files_number()
  return files_number and self.last_file_idx / files_number or true
end


function ResultsView:get_tab_tooltip_info()
  local t = {}
  local info = self.search_args[4]
  if info then
    table.insert(t, info.mode .. (info.insensitive and ", ignoring case" or ""))
  end
  if self.search_args[1] then table.insert(t, "in " .. common.home_encode(self.search_args[1])) end
  table.insert(t, common.format_count(self.last_file_idx)
    .. (self.last_file_idx == 1 and " file" or " files"))
  local time = (self.finished or system.get_time()) - self.started
  table.insert(t, string.format("%.1f s", time))
  return t
end


local function find_all_matches_in_file(t, filename, fn)
  local fp = io.open(filename)
  if not fp then return t end
  local n = 1
  for line in fp:lines() do
    -- e: the column after the match, nil if unknown
    local s, e = fn(line)
    if s then
      -- Insert maximum 256 characters. If we insert more, for compiled files, which can have very long lines
      -- things tend to get sluggish. If our line is longer than 80 characters, begin to truncate the thing.
      local start_index = math.max(s - 80, 1)
      local text = (start_index > 1 and "..." or "") .. line:sub(start_index, 256 + start_index)
      if #line > 256 + start_index then text = text .. "..." end
      table.insert(t, { file = filename, text = text, line = n, col = s, col2 = e })
      core.redraw = true
    end
    if n % 100 == 0 then coroutine.yield() end
    n = n + 1
    core.redraw = true
  end
  fp:close()
end


---What a search is, for its tooltip.
---@class plugins.projectsearch.info
---@field mode string "literal", "regex", "fuzzy"
---@field insensitive? boolean

---@param path? string Searches files under it only
---@param text string
---@param fn fun(line: string): integer?, integer? A match's start and end
---@param info? plugins.projectsearch.info
function ResultsView:begin_search(path, text, fn, info)
  self.search_args = { path, text, fn, info }
  self.started, self.finished = system.get_time(), nil
  self.results = {}
  self.last_file_idx = 1
  self.query = text
  self.searching = true
  self.selected_idx = 0
  self.hovered_idx = 0
  -- a search still running when another starts in this view stops
  self.generation = self.generation + 1
  local generation, results = self.generation, self.results

  core.add_thread(function()
    local i = 1
    for dir_name, file in core.get_project_files() do
      if self.generation ~= generation then return end
      if file.type == "file" and (not path or (dir_name .. "/" .. file.filename):find(path, 1, true) == 1) then
        local truncated_path = (dir_name == core.project_dir and "" or (dir_name .. PATHSEP))
        find_all_matches_in_file(results, truncated_path .. file.filename, fn)
      end
      self.last_file_idx = i
      i = i + 1
    end
    if self.generation ~= generation then return end
    self.searching = false
    self.finished = system.get_time()
    core.redraw = true
  end, results)

  self.scroll.to.y = 0
end


function ResultsView:refresh()
  self:begin_search(table.unpack(self.search_args))
end


function ResultsView:on_mouse_moved(mx, my, ...)
  ResultsView.super.on_mouse_moved(self, mx, my, ...)
  self.hovered_idx = 0
  for i, item, x,y,w,h in self:each_visible_result() do
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


-- for core.resultslist: a result's range is the match (the line, for a fuzzy one)
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
  return style.padding.y + style.font:get_height()
end


function ResultsView:get_scrollable_size()
  return #self.results * self:get_line_height()
end


function ResultsView:get_h_scrollable_size()
  return self.max_h_scroll
end


function ResultsView:get_visible_results_range()
  local lh = self:get_line_height()
  local min = self.scroll.y-style.font:get_height()
  min = math.max(1, math.floor(min / lh))
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


function ResultsView:draw()
  self:draw_background(style.background)

  local ox, oy = self.position.x, self.position.y

  -- results
  local _, _, bw = self:get_content_bounds()
  core.push_clip_rect(ox, oy, bw, self.size.y)
  local y1, y2 = self.position.y, self.position.y + self.size.y
  for i, item, x,y,w,h in self:each_visible_result() do
    local color = style.text
    if i == self.selected_idx then
      color = style.accent
      renderer.draw_rect(x, y, w, h, style.selection)
    elseif i == self.hovered_idx then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    end
    x = x + style.padding.x
    local text = string.format("%s at line %d (col %d): ", item.file, item.line, item.col)
    -- dim is hard to read on the selection's color
    local info_color = i == self.selected_idx and style.text or style.dim
    x = common.draw_text(style.font, info_color, text, "left", x, y, w, h)
    x = common.draw_text(style.code_font, color, item.text, "left", x, y, w, h)
    self.max_h_scroll = math.max(self.max_h_scroll, x)
  end
  core.pop_clip_rect()

  self:draw_scrollbar()
end

---@param path string
---@param text string
---@param fn fun(line_text:string):...
---@return plugins.projectsearch.resultsview?
---@param info plugins.projectsearch.info
local function begin_search(path, text, fn, info)
  if text == "" then
    core.error("Expected non-empty string")
    return
  end
  local view = panel.current(ResultsView)
  if view then
    view:begin_search(path, text, fn, info)
  else
    view = ResultsView(path, text, fn, info)
    panel.set_current(view)
  end
  panel.show(view)
  return view
end


local function get_selected_text()
  local view = core.active_view
  local doc = (view and view.doc) and view.doc or nil
  if doc then
    return doc:get_text(table.unpack({ doc:get_selection() }))
  end
end


local function normalize_path(path)
  if not path then return nil end
  path = common.normalize_path(path)
  for i, project_dir in ipairs(core.project_directories) do
    if common.path_belongs_to(path, project_dir.name) then
      return project_dir.item.filename .. PATHSEP .. common.relative_path(project_dir.name, path)
    end
  end
  return path
end

---@class plugins.projectsearch
local projectsearch = {}

---@type plugins.projectsearch.resultsview
projectsearch.ResultsView = ResultsView

---@param text string
---@param path string
---@param insensitive? boolean
---@return plugins.projectsearch.resultsview?
function projectsearch.search_plain(text, path, insensitive)
  if insensitive then text = text:lower() end
  return begin_search(path, text, function(line_text)
    local s, e
    if insensitive then
      s, e = line_text:lower():find(text, nil, true)
    else
      s, e = line_text:find(text, nil, true)
    end
    -- the column after the match, as regex.cmatch gives
    return s, e and e + 1
  end, { mode = "literal", insensitive = insensitive })
end

---@param text string
---@param path string
---@param insensitive? boolean
---@return plugins.projectsearch.resultsview?
function projectsearch.search_regex(text, path, insensitive)
  local re, errmsg
  if insensitive then
    re, errmsg = regex.compile(text, "i")
  else
    re, errmsg = regex.compile(text)
  end
  if not re then core.log("%s", errmsg) return end
  return begin_search(path, text, function(line_text)
    return regex.cmatch(re, line_text)
  end, { mode = "regex", insensitive = insensitive })
end

---@param text string
---@param path string
---@param insensitive? boolean
---@return plugins.projectsearch.resultsview?
function projectsearch.search_fuzzy(text, path, insensitive)
  if insensitive then text = text:lower() end
  return begin_search(path, text, function(line_text)
    if insensitive then
      return common.fuzzy_match(line_text:lower(), text) and 1
    else
      return common.fuzzy_match(line_text, text) and 1
    end
  end, { mode = "fuzzy", insensitive = insensitive })
end


command.add(nil, {
  ["project-search:find"] = function(path)
    core.command_view:enter("Find Text In " .. (normalize_path(path) or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        projectsearch.search_plain(text, path, true)
      end
    })
  end,

  ["project-search:find-regex"] = function(path)
    core.command_view:enter("Find Regex In " .. (normalize_path(path) or "Project"), {
      submit = function(text)
        projectsearch.search_regex(text, path, true)
      end
    })
  end,

  ["project-search:fuzzy-find"] = function(path)
    core.command_view:enter("Fuzzy Find Text In " .. (normalize_path(path) or "Project"), {
      text = get_selected_text(),
      select_text = true,
      submit = function(text)
        projectsearch.search_fuzzy(text, path, true)
      end
    })
  end,
})


ResultsList.add_to(ResultsView, "project-search")

command.add(ResultsView, {
  ["project-search:refresh"] = function()
    core.active_view:refresh()
  end,
})

keymap.add {
  ["f5"]                 = "project-search:refresh",
  ["ctrl+shift+f"]       = "project-search:find",
}


return projectsearch
