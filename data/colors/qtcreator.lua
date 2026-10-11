-- Qt Creator "Customized" scheme (~/.config/QtProject/qtcreator/styles/customized.xml).
-- Editor colors follow the scheme; UI chrome (tree view, tabs, status bar) is from summer.
local style = require "core.style"
local common = require "core.common"

-- UI chrome (summer)
style.background2 = { common.color "#f2f2f2" }
style.background3 = { common.color "#f2f2f2" }
style.text = { common.color "#404040" }
style.accent = { common.color "#fc1785" }
style.dim = { common.color "#b0b0b0" }
style.divider = { common.color "#e8e8e8" }
style.scrollbar = { common.color "#e0e0e0" }
style.scrollbar2 = { common.color "#c0c0c0" }

-- Editor
style.background = { common.color "#ffffff" }                 -- Text
style.caret = { common.color "#000000" }
-- Qt draws selected text white on #308cc6; lite-xl can't recolor selected text, so blend
-- the selection with the background to keep black text readable.
style.selection = { common.color "rgba(48, 140, 198, 0.5)" }  -- Selection
style.line_number = { common.color "#9f9d9a" }                -- LineNumber
style.line_number2 = { common.color "#808080" }               -- CurrentLineNumber
style.line_highlight = { common.color "#c1ddee" }             -- CurrentLine

-- bracketmatch plugin (Parentheses)
style.bracketmatch_color = { common.color "#ff0000" }
style.bracketmatch_char_color = { common.color "#ff0000" }
style.bracketmatch_block_color = { common.color "#b4eeb4" }
style.bracketmatch_frame_color = { common.color "#ff0000" }

-- lintplus (LSP diagnostics): Error / Warning underlines; info/hint have no Qt equivalent
style.lint = {
  error = { common.color "#ff0000" },
  warning = { common.color "#ffbe00" },
  info = { common.color "#808080" },
  hint = { common.color "#808080" },
}

style.syntax["normal"] = { common.color "#000000" }    -- Text
style.syntax["symbol"] = { common.color "#000000" }    -- Local
style.syntax["comment"] = { common.color "#008000" }   -- Comment
style.syntax["keyword"] = { common.color "#808000" }   -- Keyword
style.syntax["preprocessor"] = { common.color "#000080" }  -- Preprocessor
style.syntax["keyword2"] = { common.color "#808000" }  -- PrimitiveType (int, void; self in Lua)
style.syntax["number"] = { common.color "#000080" }    -- Number (also C UPPER_CASE macros)
style.syntax["literal"] = { common.color "#800080" }   -- Type (C type names; true/false/nil)
style.syntax["string"] = { common.color "#008080" }    -- String
style.syntax["operator"] = { common.color "#000000" }  -- Operator
style.syntax["function"] = { common.color "#000000" }  -- Function

return style
