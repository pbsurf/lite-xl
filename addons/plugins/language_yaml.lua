-- mod-version:3
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"

local yaml_bracket_list = {
  patterns = {
    -- comments
    { pattern = { "#", "\n"},                  type = "comment"  },
    -- strings
    { pattern = { '"', '"', '\\' },            type = "string"   },
    { pattern = { "'", "'", '\\' },            type = "string"   },
    -- keys
    {
      pattern = "%w%g*()%s*():()%s",
      type = { "keyword2", "normal", "operator", "normal" }
    },
     -- variables
    { pattern = "%$%a%w+",                     type = "keyword"  },
    { pattern = "%$%{%{.-%}%}",                type = "keyword"  },
    -- numeric place holders
    { pattern = "%-?%.inf",                    type = "number"   },
    { pattern = "%.NaN",                       type = "number"   },
    -- numbers
    { pattern = "[%+%-]?0%d+",                 type = "number"   },
    { pattern = "[%+%-]?0x%x+",                type = "number"   },
    { pattern = "[%+%-]?%d+[,%.eE:%+%d]*%d+",  type = "number"   },
    { pattern = "[%+%-]?%d+",                  type = "number"   },
    -- others
    { pattern = ",",                           type = "operator" },
    { pattern = "%w+",                         type = "string"   },
    {
      pattern = "[_%(%)%*@~`!%%%^&=%+%-\\;%.><%?/%s]+",
      type = "string"
    }
  },
  symbols = {}
}

local yaml = {
  name = "YAML",
  files = { "%.yml$", "%.yaml$" },
  comment = "#",
  space_handling = false,
  patterns = {
  --- rules that start with spaces first and those taking precedence
    -- parent and child keys
    {
      pattern = "^%w%g*%s*%f[:]",
      type = "literal"
    },
    {
      pattern = "^%s+%w%g*%s*%f[:]",
      type = "keyword2"
    },
    -- bracket lists after key declaration
    {
      pattern = { ":%s+%[", "%]" },
      syntax = yaml_bracket_list, type = "operator"
    },
    {
      pattern = { ":%s+{", "}" },
      syntax = yaml_bracket_list, type = "operator"
    },
    -- child key
    {
      pattern = "^%s+()%w%g*()%s*():()%s",
      type = { "normal", "keyword2", "normal", "operator", "normal" }
    },
    -- child list element
    {
      pattern = "^%s+()%-()%s+()%w%g*()%s*():()%s",
      type = { "normal", "operator", "normal", "keyword2", "normal", "operator", "normal" }
    },
    -- unkeyed bracket lists
    {
      pattern = { "^%s*%[", "%]" },
      syntax = yaml_bracket_list, type = "operator"
    },
    {
      pattern = { "^%s*{", "}" },
      syntax = yaml_bracket_list, type = "operator"
    },
    {
      pattern = { "^%s*%-%s*%[", "%]" },
      syntax = yaml_bracket_list, type = "operator"
    },
    {
      pattern = { "^%s*%-%s*{", "}" },
      syntax = yaml_bracket_list, type = "operator"
    },
    -- rule to optimize space handling
    { pattern = "%s+",                         type = "normal"   },
  --- all the other rules
    -- comments
    { pattern = { "#", "\n"},                  type = "comment"  },
    -- strings
    { pattern = { '"', '"', '\\' },            type = "string"   },
    { pattern = { "'", "'", '\\' },            type = "string"   },
    -- extra bracket lists rules on explicit type
    {
      pattern = { "!!%w+%s+%[", "%]"},
      syntax = yaml_bracket_list, type = "operator"
    },
    {
      pattern = { "!!%w+%s+{", "}"},
      syntax = yaml_bracket_list, type = "operator"
    },
    -- numeric place holders
    { pattern = "%-?%.inf",                    type = "number"   },
    { pattern = "%.NaN",                       type = "number"   },
    -- parent list element
    {
      pattern = "^%-()%s+()%w%g*()%s*():()%s",
      type = { "operator", "normal", "keyword2", "normal", "operator", "normal" }
    },
    -- key label
    {
      pattern = "%&()%g+",
      type = { "keyword", "literal" }
    },
    -- key elements expansion
    { pattern = "<<",                          type = "literal"  },
    {
      pattern = "%*()[%w%d_]+",
      type = { "keyword", "literal" }
    },
    -- explicit data types
    { pattern = "!!%g+",                       type = "keyword"  },
    -- parent key
    {
      pattern = "^%w%g*()%s*():()%s",
      type = { "literal", "normal", "operator", "normal" }
    },
    -- variables
    { pattern = "%$%a%w+",                     type = "keyword"  },
    { pattern = "%$%{%{.-%}%}",                type = "keyword"  },
    -- numbers
    { pattern = "[%+%-]?0%d+",                 type = "number"   },
    { pattern = "[%+%-]?0x%x+",                type = "number"   },
    { pattern = "[%+%-]?%d+[,%.eE:%+%d]*%d+",  type = "number"   },
    { pattern = "[%+%-]?%d+",                  type = "number"   },
    -- special operators
    { pattern = "[%*%|%!>%%]",                 type = "keyword"  },
    { pattern = "[%-%$:%?]+",                  type = "operator" },
    -- Everything else as a string
    { pattern = "[%d%a_][%g_]*",               type = "string"   },
    { pattern = "%p+",                         type = "string"   }
  },
  symbols = {
    -- YAML 1.2 core schema; 1.1's y/n/yes/no/on/off are plain strings now
    ["true"]  = "number", ["True"]  = "number", ["TRUE"]  = "number",
    ["false"] = "number", ["False"] = "number", ["FALSE"] = "number",
    ["null"]  = "number", ["Null"]  = "number", ["NULL"]  = "number",
    ["~"]     = "number"
  }
}

-- true, null, ... in flow collections too: "[true, null]"
yaml_bracket_list.symbols = yaml.symbols

syntax.add(yaml)

-- Block scalars ("key: |", "- >-", ...) run until the first non-blank line
-- indented no deeper than their key, which patterns can't express: the
-- tokenizer state only records which patterns are open.  So for YAML documents,
-- keep that indent in the state, as "\255" repeated indent + 1 times (which the
-- tokenizer reads as no open pattern), and color the content lines here.

-- If `text` starts a block scalar, return the indent its content must exceed.
local function block_scalar_indent(text)
  local line = text:gsub("%s+#.*", ""):gsub("%s+$", "")
  local head = line:match("^(.-)[|>][%-+%d]*$")
  if not head then return end
  -- drop anchors and tags before the indicator, as in "key: &a !!str |"
  repeat
    local n
    head, n = head:gsub("%s[&!]%S*%s+$", " ")
  until n == 0
  local indent = #head:match("^%s*")
  local rest, dash = head:sub(indent + 1)
  -- a sequence entry nests its content one level deeper: "- key: |"
  while rest:match("^%-%s+") do
    dash = rest:match("^%-%s+")
    indent, rest = indent + #dash, rest:sub(#dash + 1)
  end
  if rest == "" and dash then
    return indent - #dash -- "- |": the scalar is the entry itself
  elseif rest:match("^[^%s].-:%s+$") then
    return indent
  end
end

local tokenize = tokenizer.tokenize
function tokenizer.tokenize(syn, text, state, resume)
  if syn ~= yaml then return tokenize(syn, text, state, resume) end
  if not resume and state and state:byte(1) == 255 then
    if text:match("^%s*$") or #text:match("^ *") >= #state then
      return { "string", text }, state
    end
    state = nil
  end
  local res, new_state, new_resume = tokenize(syn, text, state, resume)
  if not new_resume and new_state == "\0" then
    local indent = block_scalar_indent(text)
    if indent then new_state = ("\255"):rep(indent + 1) end
  end
  return res, new_state, new_resume
end
