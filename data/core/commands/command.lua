local core = require "core"
local command = require "core.command"
local CommandView = require "core.commandview"

command.add("core.commandview", {
  ["command:submit"] = function(active_view)
    active_view:submit()
  end,

  ["command:complete"] = function(active_view)
    active_view:complete()
  end,

  ["command:escape"] = function(active_view)
    active_view:exit()
  end,

  ["command:select-previous"] = function(active_view)
    active_view:move_suggestion_idx(1)
  end,

  ["command:select-next"] = function(active_view)
    active_view:move_suggestion_idx(-1)
  end,
})

-- only where marking suggestions is on, so tab completes elsewhere
command.add(function()
  local view = core.active_view
  return view:extends(CommandView) and view.state.multi_select
    and #view.suggestions > 0, view
end, {
  -- down, towards the input (the list runs bottom-up), as fzf's toggle+down;
  -- shift+tab up
  ["command:toggle-mark"] = function(view)
    view:toggle_mark(-1)
  end,

  ["command:toggle-mark-previous"] = function(view)
    view:toggle_mark(1)
  end,
})
