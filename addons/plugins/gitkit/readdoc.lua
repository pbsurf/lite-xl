local core = require "core"
local common = require "core.common"
local syntax = require "core.syntax"
local Doc = require "core.doc"

---A read-only doc of text that isn't a file: a commit, a file as it was at a
---revision. Not in core.docs, so add-ons that act on files (lsp, linters)
---don't see it; it has no filename, `syntax_path` choosing its syntax and
---`name` naming it.
---@class gitkit.readdoc : core.doc
---@field name string
---@field syntax_path? string
local ReadDoc = Doc:extend()

function ReadDoc:__tostring() return "ReadDoc" end

---@param name string
---@param syntax_path? string
function ReadDoc:new(name, syntax_path)
  self.name = name
  self.syntax_path = syntax_path
  ReadDoc.super.new(self)
end

---Sets the text, the selection going to the start.
---@param text string|string[] Lines ending with "\n", or text split into them
function ReadDoc:set_text(text)
  local lines = text
  if type(text) == "string" then
    lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if line:byte(-1) == 13 then line = line:sub(1, -2) end
      lines[#lines + 1] = line .. "\n"
    end
  end
  if #lines == 0 then lines = { "\n" } end
  -- the last line's newline isn't in the text, as Doc:load leaves it
  lines[#lines] = lines[#lines]:gsub("\n$", "") .. "\n"
  self.lines = lines
  self.highlighter:reset()
  for i = 1, #lines do self.highlighter.lines[i] = false end
  self.selections = { 1, 1, 1, 1 }
  self.last_selection = 1
  self:reset_syntax()
  self:notify_lines_changed()
end

function ReadDoc:reset_syntax()
  local header = self:get_text(1, 1, self:position_offset(1, 1, 128))
  local syn = syntax.get(self.syntax_path and common.normalize_path(self.syntax_path), header)
  if self.syntax ~= syn then
    self.syntax = syn
    self.highlighter:soft_reset()
  end
end

function ReadDoc:get_name() return self.name end
function ReadDoc:is_dirty() return false end
function ReadDoc:raw_insert(...) end
function ReadDoc:raw_remove(...) end
function ReadDoc:load(...) end
function ReadDoc:reload() end
function ReadDoc:save()
  core.warn("%s is read-only", self.name)
end

return ReadDoc
