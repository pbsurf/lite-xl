-- mod-version:3
local core = require "core"
local common = require "core.common"
local keymap = require "core.keymap"
local command = require "core.command"
local panel = require "core.panel"
local Results = require "core.resultsview"

---@class plugins.projectsearch.resultsview : core.resultsview
local ResultsView = Results:extend()

-- The results (core.resultsview) are a tab in the bottom panel (core.panel),
-- reused by the next search unless kept, the match selected in the file shown.
-- The tab's title is the search's status, its progress drawn behind it; its
-- tooltip has the search's details.
function ResultsView:__tostring() return "ResultsView" end

---@param info? plugins.projectsearch.info
function ResultsView:new(path, text, fn, info)
  ResultsView.super.new(self)
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
      table.insert(t, Results.make_result(filename, line, n, s, e))
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
  self:clear()
  self.last_file_idx = 1
  self.query = text
  self.searching = true
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
end


function ResultsView:refresh()
  self:begin_search(table.unpack(self.search_args))
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
