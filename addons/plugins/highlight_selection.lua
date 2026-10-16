-- mod-version:3
-- Marks the other occurrences of the selected text in the document's views
-- (DocView line marks, under the selection and the text). Only a selection on
-- one line, not just whitespace, is looked for, case-sensitively; a selection
-- that is a whole word only matches whole words.
--
-- Color: style.selection_match, else the selection color at half its alpha.
local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local style = require "core.style"
local DocView = require "core.docview"
local CommandView = require "core.commandview"

config.plugins.highlight_selection = common.merge({
  enabled = true,
  -- a selection that is a whole word only matches whole words
  whole_word = true,
  -- shorter selections aren't looked for
  min_length = 1,
  config_spec = {
    name = "Highlight Selection",
    {
      label = "Enabled",
      description = "Mark the other occurrences of the selected text.",
      path = "enabled",
      type = "toggle",
      default = true
    },
    {
      label = "Whole Word",
      description = "When the selection is a whole word, only mark whole words.",
      path = "whole_word",
      type = "toggle",
      default = true
    },
    {
      label = "Minimum Length",
      description = "Shorter selections aren't looked for.",
      path = "min_length",
      type = "number",
      default = 1,
      min = 1
    }
  }
}, config.plugins.highlight_selection)


local function is_word_char(char)
  return char ~= "" and not config.non_word_chars:find(char, 1, true)
end

-- Whether line's text from col1 to col2 (exclusive) is a whole word there
local function is_whole_word(text, col1, col2)
  for i = col1, col2 - 1 do
    if not is_word_char(text:sub(i, i)) then return false end
  end
  return not is_word_char(text:sub(col1 - 1, col1 - 1))
    and not is_word_char(text:sub(col2, col2))
end


-- What to look for in a doc: the text of its last selection, and whether
-- matches must be whole words; cached until the doc or its selections change
local cache = setmetatable({}, { __mode = "k" })

local function get_needle(doc)
  local conf = config.plugins.highlight_selection
  local line1, col1, line2, col2 = doc:get_selection(true)
  local key = table.concat({ doc:get_change_id(), line1, col1, line2, col2,
    tostring(conf.whole_word), conf.min_length, #doc.selections }, ",")
  local cached = cache[doc]
  if cached and cached.key == key then return cached.needle end

  local needle
  if line1 == line2 and col2 - col1 >= conf.min_length then
    local line_text = doc.lines[line1]
    local text = line_text:sub(col1, col2 - 1)
    if text:find("%S") then
      needle = {
        text = text,
        whole_word = conf.whole_word and is_whole_word(line_text, col1, col2)
      }
    end
  end
  cache[doc] = { key = key, needle = needle }
  return needle
end


local function is_selected(doc, line, col1, col2)
  for _, l1, c1, l2, c2 in doc:get_selections(true) do
    if l1 == line and l2 == line and c1 == col1 and c2 == col2 then
      return true
    end
  end
  return false
end


local get_line_marks = DocView.get_line_marks
function DocView:get_line_marks(line)
  local marks = get_line_marks(self, line)
  if not config.plugins.highlight_selection.enabled or self:is(CommandView) then
    return marks
  end
  local needle = get_needle(self.doc)
  if not needle then return marks end

  local color = style.selection_match
  if not color then
    local s = style.selection
    color = { s[1], s[2], s[3], (s[4] or 255) / 2 }
  end
  local text = self.doc.lines[line]
  -- first in the list, drawn under other plugins' marks (e.g. search matches,
  -- which usually include these)
  local col, n = 1, 1
  while true do
    local s, e = text:find(needle.text, col, true)
    if not s then break end
    if (not needle.whole_word or is_whole_word(text, s, e + 1))
      and not is_selected(self.doc, line, s, e + 1) then
      table.insert(marks, n, { s, e + 1, color })
      n = n + 1
    end
    col = e + 1
  end
  return marks
end


command.add(nil, {
  ["highlight-selection:toggle"] = function()
    local conf = config.plugins.highlight_selection
    conf.enabled = not conf.enabled
    core.redraw = true
  end
})
