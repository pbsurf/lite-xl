-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"

config.plugins.lfautoinsert = common.merge({ map = {
  ["{%s*\n"] = "}",
  ["%(%s*\n"] = ")",
  ["%f[[]%[%s*\n"] = "]",
  ["=%s*\n"] = false,
  [":%s*\n"] = false,
  ["->%s*\n"] = false,
  ["^%s*<([^/!][^%s>]*)[^>]*>%s*\n"] = "</$TEXT>",
  ["^%s*{{#([^/][^%s}]*)[^}]*}}%s*\n"] = "{{/$TEXT}}",
  ["/%*%s*\n"] = "*/",
  ["c/c++"] = {
    file_patterns = {
      "%.c$", "%.h$", "%.inl$", "%.cpp$", "%.hpp$",
      "%.cc$", "%.C$", "%.cxx$", "%.c++$", "%.hh$",
      "%.H$", "%.hxx$", "%.h++$"
    },
    map = {
      ["^#if.*\n"] = "#endif",
      ["^#else.*\n"] = "#endif",
    }
  },
  ["lua"] = {
    file_patterns = { "%.lua$", "%.nelua$" },
    map = {
      ["%f[%w]do%s*\n"] = "end",
      ["%f[%w]then%s*\n"] = "end",
      ["%f[%w]else%s*\n"] = "end",
      ["%f[%w]repeat%s*\n"] = "until",
      ["%f[%w]function.*%)%s*\n"] = "end",
      ["%[%[%s*\n"] = "]]"
    }
  },
},
  -- how many lines below to look for an opening bracket's closing one
  closed_check_lines = 5000,
}, config.plugins.lfautoinsert)

local function get_autoinsert_map(filename)
  local map = {}
  if not filename then return map end
  for pattern, closing in pairs(config.plugins.lfautoinsert.map) do
    if type(closing) == "table" then
      if common.match_pattern(filename, closing.file_patterns) then
        for p, e in pairs(closing.map) do
          map[p] = e
        end
      end
    else
      map[pattern] = closing
    end
  end

  return map
end


local function indent_size(doc, line)
  local text = doc.lines[line] or ""
  local s, e = text:find("^[\t ]*")
  return e - s
end


local openers = { ["}"] = "{", [")"] = "(", ["]"] = "[" }

-- a line's indentation in columns, a tab as tab_width
local function indent_width(text, tab_width)
  local w = 0
  for c in text:match("^[\t ]*"):gmatch(".") do
    w = c == "\t" and (w // tab_width + 1) * tab_width or w + 1
  end
  return w
end

---Whether the opening bracket before the caret at line, col (`opener`, on
---that line) is closed already: counting brackets from the caret on (those
---in comments and strings aside), its `closer` comes before a line indented
---less than the opener's line (the enclosing block's end, closing nothing of
---ours). Preprocessor lines and labels, often at column 0 in a block, don't
---end it.
local function is_closed(doc, line, col, opener, closer)
  local tab_width = config.tab_width or config.indent_size
  local min_indent = indent_width(doc.lines[line], tab_width)
  local last = math.min(#doc.lines, line + config.plugins.lfautoinsert.closed_check_lines)
  local depth = 1
  for l = line, last do
    local text = doc.lines[l]
    if l > line and text:find("%S") and not text:find("^%s*#")
       and not text:find("^%s*[%a_][%w_]*%s*:%s*$")
       and indent_width(text, tab_width) < min_indent then
      return false
    end
    local pos = 1
    for _, type, token in doc.highlighter:each_token(l) do
      if type ~= "comment" and type ~= "string" then
        -- on the caret's line, only what's after it
        local from = l == line and math.max(1, col - pos + 1) or 1
        for i = from, #token do
          local c = token:sub(i, i)
          if c == opener then
            depth = depth + 1
          elseif c == closer then
            depth = depth - 1
            if depth == 0 then return true end
          end
        end
      end
      pos = pos + #token
    end
  end
  return false
end

command.add("core.docview!", {
  ["autoinsert:newline"] = function(dv)
    local not_applied =  { }
    local fallback = true
    local doc = dv.doc
    local indent_type, soft_size = doc:get_indent_info()
    local indent_string = indent_type == "hard" and "\t" or string.rep(" ", soft_size)

    for idx, line, col, _, _ in doc:get_selections(true, true) do
      -- We need to add `\n` to keep compatibility with the patterns
      -- that expected a newline to be placed where the caret is.
      local text = doc.lines[line]:sub(1, col - 1) .. '\n'
      local remainder = doc.lines[line]:sub(col, -1)
      local line_indent_size = indent_size(doc, line)
      -- Add more lines to remainder to detect `close`
      for i=line+1,#doc.lines do
        -- Stop adding when we find a line with a different indent level
        if #doc.lines[i] > 1 and indent_size(doc, i) ~= line_indent_size then break end
        remainder = remainder .. doc.lines[i]
        -- Continue adding until the first non-empty line
        if string.find(doc.lines[i], "%S") then
          break
        end
      end
      local current_indent = text:match("^[\t ]*")

      local pre, post
      for ptn, close in pairs(get_autoinsert_map(doc.filename)) do
        local s, _, str = text:find(ptn)
        if s then
          pre = string.format("\n%s%s", current_indent, indent_string)
          if not close then break end
          close = str and close:gsub("$TEXT", str) or close
          if (col == #doc.lines[line] and indent_size(doc, line + 1) <= line_indent_size) or
             (col < #doc.lines[line])
          then
            local clean_remainder = remainder:match("%s*(.*)")
            -- Avoid inserting `close` if it's already present; for a bracket,
            -- anywhere below that closes the block
            local already_closed = clean_remainder:find(close, 1, true) == 1
              or (openers[close] ~= nil and col == #doc.lines[line]
                  and is_closed(doc, line, col, openers[close], close))
            if not already_closed and col == #doc.lines[line] then
              -- Add the `close` only if we're at the end of the line
              post = string.format("\n%s%s", current_indent, close)
            elseif already_closed and col < #doc.lines[line] then
              -- Indent the already present `close`
              -- TODO: cleanup the spaces between the caret and the `close`
              post = string.format("\n%s", current_indent)
            end
          end
          break
        end
      end

      if pre or post then
        fallback = false
        doc:text_input(pre or "", idx)
        local l, c, l2, c2 = doc:get_selection_idx(idx)
        doc:text_input(post or "", idx)
        doc:set_selections(idx, l, c, l2, c2)
      else
        table.insert(not_applied, {idx, current_indent})
      end
    end

    -- Only call the fallback if no autoinsert was applied
    if fallback then
      command.perform("doc:newline")
    else
      for _,v in ipairs(not_applied) do
        local idx, indent = table.unpack(v)
        doc:text_input("\n"..indent, idx)
      end
    end
  end
})

keymap.add {
  ["return"] = { "autoinsert:newline" }
}

return {
  add = function(file_patterns, map)
    table.insert(
      config.plugins.lfautoinsert.map,
      { file_patterns = file_patterns, map=map }
    )
  end
}
