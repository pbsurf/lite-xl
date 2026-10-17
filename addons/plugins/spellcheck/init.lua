-- mod-version:3
-- Spell checking with hunspell, toggled per document (spell-check:toggle).
-- Identifiers are checked by their parts (camelCase, snake_case); words the
-- document's syntax lists as symbols (keywords, builtins), ALL CAPS words and
-- URLs/paths are skipped. Misspelled words get a squiggle; right click one for
-- suggestions or to add it to the personal word list.
local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local style = require "core.style"
local DocView = require "core.docview"
local ContextMenu = require "core.contextmenu"
local shapes = require "libraries.shapes"

config.plugins.spellcheck = common.merge({
  -- hunspell dictionary: path of its .aff and .dic files, without the extension
  dictionary = "/usr/share/hunspell/en_US",
  -- words accepted besides the dictionary's, one per line; "Add to Dictionary"
  -- appends to it
  user_dictionary = USERDIR .. PATHSEP .. "spellcheck_words.txt",
  -- words (or identifier parts) shorter than this aren't checked
  min_length = 0,
  max_suggestions = 8,
  config_spec = {
    name = "Spell Check",
    {
      label = "Dictionary",
      description = "Path of the hunspell .aff and .dic files, without the extension.",
      path = "dictionary",
      type = "string",
      default = "/usr/share/hunspell/en_US"
    },
    {
      label = "Minimum Length",
      description = "Words or identifier parts shorter than this aren't checked.",
      path = "min_length",
      type = "number",
      default = 0,
      min = 0
    },
  }
}, config.plugins.spellcheck)

style.spellcheck = style.spellcheck or { common.color "#d08770" }

local spellcheck = {}

local checker   -- hunspell instance, loaded when first needed
local load_error
-- per doc: misspellings by line text, { {col1, col2}, ... }, for the syntax they
-- were found with (its symbols are skipped)
local caches = setmetatable({}, { __mode = "k" })

local function get_checker()
  if checker or load_error then return checker end
  local ok, hunspell = pcall(require, "plugins.spellcheck.hunspell")
  if not ok then
    load_error = "native module missing (built by lite-xl's meson build): " .. hunspell
  else
    local dict = config.plugins.spellcheck.dictionary
    checker, load_error = hunspell.new(dict .. ".aff", dict .. ".dic")
  end
  if not checker then
    core.error("Spell check: %s", load_error)
    return
  end
  local fp = io.open(config.plugins.spellcheck.user_dictionary)
  if fp then
    for word in fp:lines() do
      if word ~= "" then checker:add(word) end
    end
    fp:close()
  end
  return checker
end

---Calls fn(col1, col2) for each word to check in text: runs of letters
---(non-ASCII bytes count as letters, apostrophes inside words too), split at
---camelCase boundaries, with each whitespace-separated chunk that looks like a
---URL, path or email skipped.
local function each_word(text, symbols, fn)
  local min_length = config.plugins.spellcheck.min_length
  local function part(run, offset, s, e)
    local word = run:sub(s, e)
    if #word >= min_length and not word:find("^%u%u+$") then
      fn(offset + s, offset + e)
    end
  end
  for chunk_start, chunk in text:gmatch("()(%S+)") do
    if not (chunk:find("://", 1, true) or chunk:find("@", 1, true)
      or (chunk:find("/", 1, true) and chunk:find("%.%w"))) then
      for run_start, run in chunk:gmatch("()([%a\128-\255']+)") do
        -- apostrophes only inside words
        local lead = #run:match("^'*")
        run = run:sub(lead + 1):gsub("'+$", "")
        if run ~= "" and not symbols[run] then
          local offset = chunk_start + run_start + lead - 2
          local s = 1
          for i = 2, #run do
            local a, b = run:sub(i - 1, i - 1), run:sub(i, i)
            -- fooBar -> foo|Bar, HTTPServer -> HTTP|Server
            if (a:find("%l") and b:find("%u"))
              or (a:find("%u") and b:find("%u") and run:sub(i + 1, i + 1):find("%l")) then
              part(run, offset, s, i - 1)
              s = i
            end
          end
          part(run, offset, s, #run)
        end
      end
    end
  end
end

---Misspelled words in a line of doc: { {col1, col2}, ... }.
local function misspellings(doc, line)
  local h = get_checker()
  if not h then return {} end
  local cache = caches[doc]
  if not cache or cache.syntax ~= doc.syntax or cache.count > 10000 then
    cache = { syntax = doc.syntax, lines = {}, count = 0 }
    caches[doc] = cache
  end
  local text = doc.lines[line]
  local found = cache.lines[text]
  if not found then
    found = {}
    each_word(text, doc.syntax.symbols or {}, function(col1, col2)
      if not h:spell(text:sub(col1, col2)) then
        table.insert(found, { col1, col2 })
      end
    end)
    cache.lines[text] = found
    cache.count = cache.count + 1
  end
  return found
end

---The misspelled word at line, col of doc: col1, col2 or nil.
function spellcheck.word_at(doc, line, col)
  for _, w in ipairs(misspellings(doc, line)) do
    if col >= w[1] and col <= w[2] + 1 then return w[1], w[2] end
  end
end

function spellcheck.add_word(word)
  local h = get_checker()
  if not h then return end
  h:add(word)
  local fp, err = io.open(config.plugins.spellcheck.user_dictionary, "a")
  if fp then
    fp:write(word, "\n")
    fp:close()
  else
    core.error("Spell check: cannot save \"%s\": %s", word, err)
  end
  caches = setmetatable({}, { __mode = "k" })
  core.redraw = true
  core.log("Added \"%s\" to the dictionary", word)
end

local function replace(doc, line, col1, col2, word, replacement)
  -- the doc may have changed since the word was found
  if doc.lines[line]:sub(col1, col2) ~= word then return end
  doc:remove(line, col1, line, col2 + 1)
  doc:insert(line, col1, replacement)
  doc:set_selection(line, col1 + #replacement)
end

local function suggestions(word)
  local list = get_checker():suggest(word)
  local max = config.plugins.spellcheck.max_suggestions
  for i = #list, max + 1, -1 do list[i] = nil end
  return list
end


local draw_line_text = DocView.draw_line_text
function DocView:draw_line_text(line, x, y)
  local lh = draw_line_text(self, line, x, y)
  if not self.doc.spellcheck then return lh end
  local words = misspellings(self.doc, line)
  if #words == 0 then return lh end
  -- a word being typed isn't marked yet: one with a caret at its end
  local typing = {}
  for _, l1, c1, l2, c2 in self.doc:get_selections() do
    if l1 == line and l2 == line and c1 == c2 then typing[c1] = true end
  end
  local line_height = self:get_line_height()
  local uy = y + line_height - (line_height - self:get_font():get_height()) / 2
  for _, w in ipairs(words) do
    if not typing[w[2] + 1] then
      local x1 = self:get_col_x_offset(line, w[1])
      local x2 = self:get_col_x_offset(line, w[2] + 1)
      shapes.squiggle(x + x1, uy, x2 - x1, style.spellcheck)
    end
  end
  return lh
end


command.add("core.docview", {
  ["spell-check:toggle"] = function(dv)
    if not dv.doc.spellcheck and not get_checker() then return end
    dv.doc.spellcheck = not dv.doc.spellcheck
    core.redraw = true
  end,
})

-- commands on the misspelled word at the cursor
command.add(function()
  local dv = core.active_view
  if not (dv:extends(DocView) and dv.doc.spellcheck) then return false end
  local line, col = dv.doc:get_selection()
  local col1, col2 = spellcheck.word_at(dv.doc, line, col)
  return col1 ~= nil, dv.doc, line, col1, col2
end, {
  ["spell-check:replace"] = function(doc, line, col1, col2)
    local word = doc.lines[line]:sub(col1, col2)
    local list = suggestions(word)
    core.command_view:enter("Replace \"" .. word .. "\" With", {
      submit = function(text, item)
        -- the highlighted suggestion, else what was typed
        text = item and item.text or text
        if text ~= "" then replace(doc, line, col1, col2, word, text) end
      end,
      suggest = function(text)
        return text == "" and list or common.fuzzy_match(list, text)
      end
    })
  end,
  ["spell-check:add-to-dictionary"] = function(doc, line, col1, col2)
    spellcheck.add_word(doc.lines[line]:sub(col1, col2))
  end,
})

-- Right click on a misspelled word: suggestions first, then the usual items
local menu_found, menu = pcall(require, "plugins.contextmenu")
if menu_found then
  menu:register(nil, function(x, y)
    local node = core.root_view.root_node:get_child_overlapping_point(x, y)
    local dv = node and node.active_view
    if not (dv and dv:extends(DocView) and dv.doc.spellcheck) then return end
    local doc = dv.doc
    local line, col = dv:resolve_screen_position(x, y)
    local col1, col2 = spellcheck.word_at(doc, line, col)
    if not col1 then return end
    local word = doc.lines[line]:sub(col1, col2)
    local items = {}
    for _, s in ipairs(suggestions(word)) do
      table.insert(items, { text = s, command = function()
        replace(doc, line, col1, col2, word, s)
      end })
    end
    if #items == 0 then
      table.insert(items, { text = "(no suggestions)", command = function() end })
    end
    table.insert(items, ContextMenu.DIVIDER)
    table.insert(items, { text = "Add to Dictionary", command = function()
      spellcheck.add_word(word)
    end })
    table.insert(items, ContextMenu.DIVIDER)
    return items
  end)
  table.insert(menu.itemset, 1, table.remove(menu.itemset))
end

return spellcheck
