-- mod-version:3
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local Doc = require "core.doc"

---@class config.plugins.trimwhitespace
---@field enabled boolean
---@field trim_empty_end_lines boolean
---@field trim_caret_line boolean
config.plugins.trimwhitespace = common.merge({
  enabled = false,
  trim_empty_end_lines = false,
  trim_caret_line = false,
  config_spec = {
    name = "Trim Whitespace",
    {
      label = "Enabled",
      description = "Disable or enable the trimming of white spaces by default.",
      path = "enabled",
      type = "toggle",
      default = false
    },
    {
      label = "Trim Empty End Lines",
      description = "Remove any empty new lines at the end of documents.",
      path = "trim_empty_end_lines",
      type = "toggle",
      default = false
    },
    {
      label = "Trim Caret Line",
      description = "Also trim the line with the caret, moving the caret back if it was in the trimmed whitespace.",
      path = "trim_caret_line",
      type = "toggle",
      default = false
    }
  }
}, config.plugins.trimwhitespace)

---@class plugins.trimwhitespace
local trimwhitespace = {}

---Disable whitespace trimming for a specific document.
---@param doc core.doc
function trimwhitespace.disable(doc)
  doc.disable_trim_whitespace = true
end

---Re-enable whitespace trimming if previously disabled.
---@param doc core.doc
function trimwhitespace.enable(doc)
  doc.disable_trim_whitespace = nil
end

---Perform whitespace trimming in all lines of a document; on the line where
---the caret is, only right of the caret unless `trim_caret_line` is set.
---@param doc core.doc
function trimwhitespace.trim(doc)
  local cline, ccol = doc:get_selection()
  for i = 1, #doc.lines do
    local old_text = doc:get_text(i, 1, i, math.huge)
    local new_text = old_text:gsub("%s*$", "")

    -- don't remove whitespace which would cause the caret to reposition
    if cline == i and ccol > #new_text
      and not config.plugins.trimwhitespace.trim_caret_line then
      new_text = old_text:sub(1, ccol - 1)
    end

    if old_text ~= new_text then
      doc:insert(i, 1, new_text)
      doc:remove(i, #new_text + 1, i, math.huge)
    end
  end
end

---Removes all empty new lines at the end of the document, but the last: that
---one is after the file's final newline.
---@param doc core.doc
---@param raw_remove? boolean Perform the removal not registering to undo stack
function trimwhitespace.trim_empty_end_lines(doc, raw_remove)
  for _=#doc.lines, 1, -1 do
    local l = #doc.lines
    if l > 1 and doc.lines[l] == "\n" and doc.lines[l-1] == "\n" then
      local current_line = doc:get_selection()
      if current_line == l then
        doc:set_selection(l-1, math.huge, l-1, math.huge)
      end
      if not raw_remove then
        doc:remove(l-1, math.huge, l, math.huge)
      else
        table.remove(doc.lines, l)
      end
    else
      break
    end
  end
end


command.add("core.docview", {
  ["trim-whitespace:trim-trailing-whitespace"] = function(dv)
    trimwhitespace.trim(dv.doc)
  end,

  ["trim-whitespace:trim-empty-end-lines"] = function(dv)
    trimwhitespace.trim_empty_end_lines(dv.doc)
  end,
})


local doc_save = Doc.save
Doc.save = function(self, ...)
  if
    config.plugins.trimwhitespace.enabled
    and
    not self.disable_trim_whitespace
  then
    trimwhitespace.trim(self)
    if config.plugins.trimwhitespace.trim_empty_end_lines then
      trimwhitespace.trim_empty_end_lines(self)
    end
  end
  doc_save(self, ...)
end


return trimwhitespace
