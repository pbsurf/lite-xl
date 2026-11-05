---gdb/MI output, parsed: one line of it into a record.
---
---Records (GDB manual, "GDB/MI Output Syntax"):
---* `[token]^class[,results]`: the result of the command sent with that token
---* `[token]*class,...` (exec), `+class,...` (status), `=class,...` (notify):
---  asynchronous
---* `~"text"` (console), `@"text"` (target), `&"text"` (log): streams
---* `(gdb)`: the prompt, ending a batch of output
---
---Results are `name=value` pairs, a value being a C string, a tuple `{...}`
---of results or a list `[...]` of values or of results. Tuples become tables
---keyed by name; lists become arrays (of results: of their values, the names,
---all the same, as in `stack=[frame={...},frame={...}]`, dropped).
local mi = {}

local escapes = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\",
  a = "\a", b = "\b", f = "\f", v = "\v", e = "\27" }

-- A C string starting at s[i] (the opening quote): its text, and the index
-- after the closing quote.
local function parse_string(s, i)
  local out, n = {}, #s
  i = i + 1
  local start = i
  while i <= n do
    local c = s:byte(i)
    if c == 34 then -- "
      out[#out + 1] = s:sub(start, i - 1)
      return table.concat(out), i + 1
    elseif c == 92 then -- \
      out[#out + 1] = s:sub(start, i - 1)
      local e = s:sub(i + 1, i + 1)
      local octal = s:match("^[0-7][0-7]?[0-7]?", i + 1)
      if octal then
        out[#out + 1] = string.char(tonumber(octal, 8) % 256)
        i = i + 1 + #octal
      else
        out[#out + 1] = escapes[e] or e
        i = i + 2
      end
      start = i
    else
      i = i + 1
    end
  end
  -- unterminated: what there is
  out[#out + 1] = s:sub(start)
  return table.concat(out), n + 1
end

local parse_value

-- name=value pairs from s[i] up to `close` (a byte, or nil for the end of the
-- line): a table keyed by name, and the index after `close`. As arrays too, in
-- order, for lists of results.
local function parse_results(s, i, close, as_list)
  local t = {}
  while i <= #s do
    local c = s:byte(i)
    if c == close then return t, i + 1 end
    if c == 44 then i = i + 1 end -- ,
    local name, after = s:match("^([%w_%-]+)=()", i)
    if not name then
      -- a list's values without names
      if as_list then
        local value
        value, i = parse_value(s, i)
        t[#t + 1] = value
      else
        return t, #s + 1
      end
    else
      local value
      value, i = parse_value(s, after)
      if as_list then t[#t + 1] = value else t[name] = value end
    end
  end
  return t, i
end

function parse_value(s, i)
  local c = s:byte(i)
  if c == 34 then return parse_string(s, i) end
  if c == 123 then return parse_results(s, i + 1, 125) end -- { }
  if c == 91 then return parse_results(s, i + 1, 93, true) end -- [ ]
  -- not a value: skip to the next separator
  local j = s:find("[,}%]]", i) or #s + 1
  return s:sub(i, j - 1), j
end

---@class debug.mi.record
---@field type string "result", "exec", "status", "notify", "console", "target", "log", "prompt" or "other"
---@field token? integer a result's (or exec record's) token, if the command had one
---@field class? string e.g. "done", "error", "stopped", "running"
---@field results? table its results, by name
---@field text? string a stream's text, or an unparsed line's

local types = { ["^"] = "result", ["*"] = "exec", ["+"] = "status", ["="] = "notify",
  ["~"] = "console", ["@"] = "target", ["&"] = "log" }

---Parses a line of MI output (without its line ending).
---@param line string
---@return debug.mi.record
function mi.parse(line)
  if line:find("^%(gdb%) *$") then return { type = "prompt" } end
  local token, prefix, rest = line:match("^(%d*)([%^%*%+=~@&])(.*)$")
  local type = prefix and types[prefix]
  if not type then return { type = "other", text = line } end
  if type == "console" or type == "target" or type == "log" then
    return { type = type, text = rest:sub(1, 1) == '"' and parse_string(rest, 1) or rest }
  end
  local class, after = rest:match("^([%w_%-]+)()")
  if not class then return { type = "other", text = line } end
  local results = {}
  if rest:sub(after, after) == "," then results = parse_results(rest, after + 1) end
  return { type = type, token = tonumber(token), class = class, results = results }
end

---A string as an MI command's argument: as is if it needs no quotes, else
---as a C string.
---@param s string
---@return string
function mi.quote(s)
  s = tostring(s)
  if s ~= "" and not s:find('[%s"\\]') then return s end
  return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

return mi
