-- mod-version:3
local core = require "core"
local translate = require "core.doc.translate"
local config = require "core.config"
local common = require "core.common"
local DocView = require "core.docview"
local command = require "core.command"
local keymap = require "core.keymap"


config.plugins.autoinsert = common.merge({ map = {
  ["["] = "]",
  ["{"] = "}",
  ["("] = ")",
  ['"'] = '"',
  ["'"] = "'",
  ["`"] = "`",
} }, config.plugins.autoinsert)


local function is_closer(chr)
  for _, v in pairs(config.plugins.autoinsert.map) do
    if v == chr then
      return true
    end
  end
end

---The syntax type of the token holding the character at line, col.
local function token_type_at(doc, line, col)
  local pos = 1
  for _, type, text in doc.highlighter:each_token(line) do
    pos = pos + #text
    if col < pos then return type end
  end
end

---Whether the cursor at line, col is inside a comment: the characters both
---before and after it are (a line comment's newline is part of it; after a
---block comment's end, or before its start, it isn't).
local function in_comment(doc, line, col)
  return col > 1 and token_type_at(doc, line, col - 1) == "comment"
    and token_type_at(doc, line, col) == "comment"
end

local function count_char(text, chr)
  local count = 0
  for _ in text:gmatch(chr) do
    count = count + 1
  end
  return count
end


local on_text_input = DocView.on_text_input

function DocView:on_text_input(text)

  -- Don't insert on multiselections
  if #self.doc.selections > 4 then return on_text_input(self, text) end

  local mapping = config.plugins.autoinsert.map[text]

  -- prevents plugin from operating on `CommandView`
  if getmetatable(self) ~= DocView then
    return on_text_input(self, text)
  end

  -- typing over a selection replaces it, as without the plugin: no wrapping
  -- in brackets or quotes
  if self.doc:has_selection() then
    return on_text_input(self, text)
  end

  -- skip inserting closing text
  local chr = self.doc:get_char(self.doc:get_selection())
  if text == chr and is_closer(chr) then
    self.doc:move_to(1)
    return
  end

  -- in a comment, text is prose: nothing is closed for it
  local line, col = self.doc:get_selection()
  if mapping and in_comment(self.doc, line, col) then
    return on_text_input(self, text)
  end

  -- don't insert closing quote if we have a non-even number on this line
  if text == mapping and count_char(self.doc.lines[line], text) % 2 == 1 then
    return on_text_input(self, text)
  end

  -- auto insert closing bracket
  if mapping and (chr:find("%s") or is_closer(chr) and chr ~= '"') then
    on_text_input(self, text)
    on_text_input(self, mapping)
    self.doc:move_to(-1)
    return
  end

  on_text_input(self, text)
end



local function predicate()
  return core.active_view:is(DocView)
    and #core.active_view.doc.selections <= 4 and not core.active_view.doc:has_selection(), core.active_view.doc
end

command.add(predicate, {
  ["autoinsert:backspace"] = function(doc)
    local l, c = doc:get_selection()
    if c > 1 then
      local chr = doc:get_char(l, c)
      local mapped = config.plugins.autoinsert.map[doc:get_char(l, c - 1)]
      if mapped and mapped == chr then
        doc:delete_to(1)
      end
    end
    command.perform "doc:backspace"
  end,

  ["autoinsert:delete-to-previous-word-start"] = function(doc)
    local le, ce = translate.previous_word_start(doc, doc:get_selection())
    while true do
      local l, c = doc:get_selection()
      if l == le and c == ce then
        break
      end
      command.perform "autoinsert:backspace"
    end
  end,
})

keymap.add {
  ["backspace"]            = "autoinsert:backspace",
  ["ctrl+backspace"]       = "autoinsert:delete-to-previous-word-start",
  ["ctrl+shift+backspace"] = "autoinsert:delete-to-previous-word-start",
}
