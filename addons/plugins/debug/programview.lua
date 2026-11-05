local core = require "core"
local config = require "core.config"
local style = require "core.style"
local panel = require "core.panel"
local TerminalView = require("plugins.terminal").class

---The program's terminal: a pty of its own (terminal:open_pty), on which the
---debugger runs the program, so it reads the keyboard as in a shell. Its
---output stays there from session to session, each starting with a header.
---On Windows (no pty to give) the program's output comes from the debugger and
---is written to it.
---@class debug.programview : core.view
local ProgramView = TerminalView:extend()
ProgramView.close_on_exit = false

function ProgramView:new()
  ProgramView.super.new(self, { shell = "DUMMY" })
  -- the pty's slave, while there is one
  self.tty = nil
end

local function debug() return require "plugins.debug" end

function ProgramView:get_name()
  local session = debug().session
  if not session then return "Program" end
  local name = session.options.program:match("[^/\\]+$") or "Program"
  if session.state == "ended" then
    if session.exit then
      return name .. (session.exit.signal and (": " .. session.exit.signal) or (session.exit.code ~= 0 and (": exit " .. session.exit.code) or ": exited"))
    end
    return name .. (session.error and ": failed" or ": stopped")
  end
  return name .. ": " .. session.state
end

function ProgramView:get_name_color()
  local session = debug().session
  if session and session.state == "ended" and (session.error or (session.exit and (session.exit.signal or session.exit.code ~= 0))) then
    return style.error
  end
end

function ProgramView:get_progress()
  local session = debug().session
  return session and (session.state == "running" or session.state == "starting") or nil
end

function ProgramView:get_tab_tooltip_info()
  local session = debug().session
  if not session then return {} end
  return { session.options.program, session.stop and session.stop.description or nil }
end

-- restored with the workspace where it was (its output isn't)
function ProgramView:get_workspace_state() return {} end
function ProgramView:from_workspace_state()
  return debug().get_view("program", self)
end

---The terminal, made now if the view hasn't been shown yet: sized as the
---panel is likely to be, and resized when it shows.
function ProgramView:get_terminal()
  if not self.terminal then
    if self.size.y <= 0 then self.size.y = panel.height or core.root_view.size.y / 3 end
    if self.size.x <= 0 then self.size.x = core.root_view.size.x end
    ProgramView.super.update(self)
  end
  return self.terminal
end

function ProgramView:write(text)
  local shifts = self:get_terminal():output(text)
  self:on_output(shifts)
  core.redraw = true
end

---A new pty for a session's program: its slave's path, nil where there's
---none (Windows).
---@return string?
function ProgramView:open_pty()
  local terminal = self:get_terminal()
  if self.pty_source then core.unwatch_readable(self.pty_source) end
  local ok, tty = pcall(terminal.open_pty, terminal)
  if not ok or not tty then
    if not ok then core.log_quiet("debug: %s", tty) end
    return nil
  end
  self.tty = tty
  local reader = {}
  self.reader = reader
  core.add_thread(function()
    while self.reader == reader and self.terminal == terminal do
      local shifts = self:shift_selection_update()
      if shifts then core.redraw = true end
      local source = terminal:watch_source()
      if not source then break end
      self.pty_source = source
      if shifts then
        coroutine.yield(1 / config.fps)
      else
        core.wait_for(core.watch_readable(source))
      end
    end
  end)
  return tty
end

-- typing goes to the program while there's one
function ProgramView:accepts_input()
  local session = debug().session
  return self.tty ~= nil and session ~= nil and session.state ~= "ended"
end

function ProgramView:input(text)
  if self:accepts_input() then return ProgramView.super.input(self, text) end
  return false
end

function ProgramView:get_cursor()
  local x, y, mode = self.terminal:cursor()
  return x, y, self:accepts_input() and mode or "hidden"
end

function ProgramView:close()
  self.reader = nil
  if self.pty_source then core.unwatch_readable(self.pty_source) end
  return ProgramView.super.close(self)
end

return ProgramView
