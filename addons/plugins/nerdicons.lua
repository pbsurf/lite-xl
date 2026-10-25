-- mod-version:3
-- Orginal Author: Jipok
-- Modified by: techie-guy
-- Doesn't work well with scaling mode == "ui"

-- This is an extension/modification of the nonicons plugin, https://github.com/lite-xl/lite-xl-plugins/blob/master/plugins/nonicons.lua

-- Any icon can be searched with nerdfonts.com/cheat-sheet

local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local TreeView = require "plugins.treeview"
local Node = require "core.node"
local View = require "core.view"

local nerdfonts_symbols = require "libraries.font_symbols_nerdfont_mono_regular"

-- Config
config.plugins.nerdicons = common.merge({
  use_default_dir_icons = false,
  use_default_chevrons = false,
  draw_treeview_icons = true,
  draw_tab_icons = true,
  -- The config specification used by the settings gui
  config_spec = {
    name = "Nerdicons",
    {
      label = "Use Default Directory Icons",
      description = "When enabled does not use nerdicon directory icons.",
      path = "use_default_dir_icons",
      type = "toggle",
      default = false
    },
    {
      label = "Use Default Chevrons",
      description = "When enabled does not use nerdicon expand/collapse arrow icons.",
      path = "use_default_chevrons",
      type = "toggle",
      default = false
    },
    {
      label = "Draw Treeview Icons",
      description = "Enables file related icons on the treeview.",
      path = "draw_treeview_icons",
      type = "toggle",
      default = true
    },
    {
      label = "Draw Tab Icons",
      description = "Adds file related icons to tabs.",
      path = "draw_tab_icons",
      type = "toggle",
      default = true
    },
  }
}, config.plugins.nerdicons)

local icon_font = renderer.font.load(nerdfonts_symbols.path, 18.5 * SCALE)
local map = nerdfonts_symbols.utf8
local chevron_width = icon_font:get_width(map["oct-chevron_down"])
local previous_scale = SCALE


local extension_icons = {
  [".hxml"]        = { "#d3d3d3", "seti-config"              }, -- Haxe
  [".hx"]          = { "#f68712", "seti-haxe"                },
  [".d"]           = { "#ff3333", "dev-dlang"                }, -- D
  [".di"]          = { "#ff6666", "dev-dlang"                },
  [".lua"]         = { "#405af0", "seti-lua"                 },
  [".md"]          = { "#519aba", "dev-markdown"             }, -- Markdown
  [".powershell"]  = { "#519aba", "cod-terminal_powershell"  },
  [".bat"]         = { "#cbcb41", "cod-terminal_cmd"         },
  [".txt"]         = { "#ffffff", "fa-file_text"             },
  [".cpp"]         = { "#519aba", "custom-cpp"               },
  [".c"]           = { "#599eff", "custom-c"                 },
  [".h"]           = { "#79029b", "fa-header"                },
  [".hpp"]         = { "#79029b", "fa-header"                },
  [".py"]          = { "#3572A5", "md-language_python"       }, -- Python
  [".pyc"]         = { "#519aba", "md-language_python"       },
  [".pyd"]         = { "#519aba", "md-language_python"       },
  [".php"]         = { "#a074c4", "md-language_php"          },
  [".cs"]          = { "#596706", "md-language_csharp"       },  -- C#
  [".conf"]        = { "#6d8086", "seti-config"              },
  [".cfg"]         = { "#6d8086", "seti-config"              },
  [".toml"]        = { "#6d8086", "seti-config"              },
  [".yaml"]        = { "#6d8086", "seti-yml"                 },
  [".yml"]         = { "#6d8086", "seti-yml"                 },
  [".json"]        = { "#854CC7", "seti-json"                },
  [".css"]         = { "#519abc", "dev-css3"                 },
  [".html"]        = { "#e34c26", "dev-html5"                },
  [".js"]          = { "#cbcb41", "dev-javascript_badge"     },
  [".cjs"]         = { "#cbcb41", "dev-javascript_badge"     },
  [".mjs"]         = { "#cbcb41", "dev-javascript_badge"     },  -- JavaScript
  [".ejs"]         = { "#ffea7f", "seti-ejs"                 },
  [".pug"]         = { "#a86454", "seti-pug"                 },
  [".go"]          = { "#519aba", "seti-go"                  },
  [".jpg"]         = { "#a074c4", "fa-image"                 },
  [".png"]         = { "#a074c4", "fa-image"                 },
  [".sh"]          = { "#4d5a5e", "cod-terminal_bash"        },
  [".bash"]        = { "#4d5a5e", "cod-terminal_bash"        },  -- Shell
  [".java"]        = { "#cc3e44", "dev-java"                 },
  [".scala"]       = { "#cc3e44", "dev-scala"                },
  [".kt"]          = { "#F88A02", "custom-kotlin"            },  -- Kotlin
  [".pl"]          = { "#519aba", "dev-perl"                 },  -- Perl
  [".pm"]          = { "#519aba", "dev-perl"                 },  -- Perl
  [".rb"]          = { "#701516", "dev-ruby_rough"           },  -- Ruby
  [".rs"]          = { "#c95625", "dev-rust"                 },  -- Rust
  [".rss"]         = { "#cc3e44", "fa-rss_square"            },
  [".sql"]         = { "#dad8d8", "dev-sqllite"              },
  [".swift"]       = { "#e37933", "dev-swift"                },
  [".ts"]          = { "#519aba", "md-language_typescript"   },  -- TypeScript
  [".diff"]        = { "#41535b", "oct-diff"                 },
  [".exe"]         = { "#cc3e55", "cod-file_binary"          },
  [".make"]        = { "#d0bf41", "dev-gnu"                  },
  [".svg"]         = { "#f7ca39", "md-svg"                   },
  [".ttf"]         = { "#dad8d4", "fa-font"                  },
  [".otf"]         = { "#dad8d4", "fa-font"                  },
  [".vim"]         = { "#8f00ff", "custom-vim"               },
  [".pdf"]         = { "#E53935", "fa-file_pdf_o"            },
  [".jl"]          = { "#4063d8", "seti-julia"               },
  [".mp4"]         = { "#e85e00", "oct-video"                },
  [".jld2"]        = { "#888888", "fa-database"              },
  [".ipynb"]       = { "#F37726", "seti-notebook"            },
}


local known_filenames_icons = {
  ["dockerfile"]      = { "#296478", "linux-docker"         },
  [".gitignore"]      = { "#cc3e55", "dev-git"              },
  [".gitmodules"]     = { "#cc3e56", "dev-git"              },
  ["PKGBUILD"]        = { "#6d8ccc", "md-package"           },
  ["license"]         = { "#d0bf41", "seti-license"         },
  ["copying"]         = { "#d0bf41", "seti-license"         },
  ["makefile"]        = { "#d0bf41", "dev-gnu"              },
  ["cmakelists.txt"]  = { "#cc3e55", "md-triangle_outline"  },
}

-- Preparing colors
for _, v in pairs(extension_icons) do
  v[1] = { common.color(v[1]) }
end
for _, v in pairs(known_filenames_icons) do
  v[1] = { common.color(v[1]) }
end

-- Icon colors are picked for dark themes. One with less than 3:1 contrast against
-- the backgrounds icons are drawn on (active tab: background; inactive tabs and
-- treeview: background2) is blended towards style.text until it has that.
local function luminance(c)
  local function linear(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linear(c[1]) + 0.7152 * linear(c[2]) + 0.0722 * linear(c[3])
end

local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

local readable_cache = setmetatable({}, { __mode = "k" })
local function readable(color)
  local cached = readable_cache[color]
  if cached and cached.background == style.background
     and cached.background2 == style.background2 and cached.text == style.text then
    return cached.color
  end
  local result = color
  for t = 0.1, 1.05, 0.1 do
    if math.min(contrast(result, style.background), contrast(result, style.background2)) >= 3 then
      break
    end
    result = {}
    for i = 1, 3 do result[i] = color[i] + (style.text[i] - color[i]) * math.min(t, 1) end
    result[4] = color[4]
  end
  readable_cache[color] = {
    background = style.background, background2 = style.background2, text = style.text,
    color = result
  }
  return result
end

-- Override function to change default icons for dirs, special extensions and names
local TreeView_get_item_icon = TreeView.get_item_icon
function TreeView:get_item_icon(item, active, hovered)
  local icon, font, color = TreeView_get_item_icon(self, item, active, hovered)
  if previous_scale ~= SCALE then
    icon_font:set_size(
      icon_font:get_size() * (SCALE / previous_scale)
    )
    chevron_width = icon_font:get_width(map["oct-chevron_down"])
    previous_scale = SCALE
  end
  if not config.plugins.nerdicons.use_default_dir_icons then
    icon = map["cod-file"] -- hex ea7b
    font = icon_font
    color = style.text
    if item.type == "dir" then
      icon = item.expanded and map["fa-folder_open"] or map["fa-folder"] -- hex f07c and f07b
    end
  end
  if config.plugins.nerdicons.draw_treeview_icons then
    local custom_icon = known_filenames_icons[item.name:lower()]
    if custom_icon == nil then
      custom_icon = extension_icons[item.name:match("^.+(%..+)$")]
    end
    if custom_icon ~= nil then
      color = readable(custom_icon[1])
      icon = map[custom_icon[2]]
      font = icon_font
    end
    if active or hovered then
      color = style.accent
    end
  end
  return icon, font, color
end

-- Override function to draw chevrons if setting is disabled
local TreeView_draw_item_chevron = TreeView.draw_item_chevron
function TreeView:draw_item_chevron(item, active, hovered, x, y, w, h)
  if not config.plugins.nerdicons.use_default_chevrons then
    if item.type == "dir" then
      local chevron_icon = item.expanded and "oct-chevron_down" or "oct-chevron_right"
      local chevron_color = hovered and style.accent or style.text
      common.draw_text(icon_font, chevron_color, map[chevron_icon], nil, x+8, y, 0, h) -- added 8 to x to draw the chevron closer to the icon
    end
    return self:get_item_chevron_width(item)
  end
  return TreeView_draw_item_chevron(self, item, active, hovered, x, y, w, h)
end

local TreeView_get_item_chevron_width = TreeView.get_item_chevron_width
function TreeView:get_item_chevron_width(item)
  if not config.plugins.nerdicons.use_default_chevrons then
    return chevron_width + style.padding.x
  end
  return TreeView_get_item_chevron_width(self, item)
end

-- Terminal views (terminal plugin, if loaded): a terminal icon
local View_get_icon = View.get_icon
function View:get_icon(hovered)
  if getmetatable(self) == package.loaded["plugins.terminal.view"] then
    return map["oct-terminal"], icon_font, hovered and style.accent or style.text
  end
  return View_get_icon(self, hovered)
end

-- Override function to draw icons in tabs titles if setting is enabled
local Node_draw_tab_title = Node.draw_tab_title
function Node:draw_tab_title(view, font, is_active, is_hovered, x, y, w, h)
  local icon, icon_font, color
  if config.plugins.nerdicons.draw_tab_icons and view then
    icon, icon_font, color = view:get_icon(is_hovered)
  end
  if icon then
    -- Icon and title as one group: centered while the title fits, otherwise the icon
    -- at the left and the title truncated in the space after it
    local icon_w = icon_font:get_width(icon) + style.padding.x / 2
    local group_w = icon_w + font:get_width(view:get_name())
    local ix = x + math.max(0, (w - group_w) / 2)
    common.draw_text(icon_font, color, icon, nil, ix, y, 0, h)
    local badge = view:get_icon_badge()
    if badge then
      common.draw_icon_badge(badge, is_active and style.background or style.background2,
        icon_font, icon, ix, y, h)
    end
    Node_draw_tab_title(self, view, font, is_active, is_hovered, ix + icon_w, y, x + w - ix - icon_w, h)
  else
    Node_draw_tab_title(self, view, font, is_active, is_hovered, x, y, w, h)
  end
end
