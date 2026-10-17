-- When hover tooltips show, shared by all of them (tabs, treeview entries,
-- status bar items), so they behave alike: a tooltip shows once the pointer
-- has rested on its target for config.tooltip_delay, and stays while the
-- pointer is on the target, however it moves there. While one is showing, or
-- for a moment after it hid, moving to another target shows that one at once.
-- A click hides it until the pointer moves to another target.
--
-- A source of tooltips reports the target under the pointer whenever that may
-- change, with tooltip.hover(owner, target), owner being the source (any value)
-- and target nil when it has none there, and draws its tooltip while
-- tooltip.shown(owner, target). Only targets that have a tooltip to show
-- should be reported.
local core = require "core"
local config = require "core.config"

local tooltip = {}

---Seconds after a tooltip hides during which another shows without delay.
tooltip.warm_time = 0.5

local owner, target
local show_at = 0
local dismissed = false
local last_shown = -math.huge -- when a showing tooltip was last hidden
local generation = 0

local function showing(now)
  return target ~= nil and not dismissed and now >= show_at
end

---Reports the target with a tooltip under the pointer, of a source of them.
---@param src any The source, e.g. the view drawing the tooltips.
---@param tgt any? Its target under the pointer, nil for none.
---@param delay number? Seconds before it shows, instead of config.tooltip_delay.
function tooltip.hover(src, tgt, delay)
  if tgt == nil and src ~= owner then return end -- not the source holding it
  if src == owner and tgt == target then return end
  local now = system.get_time()
  if showing(now) then last_shown = now end
  owner, target, dismissed = tgt ~= nil and src or nil, tgt, false
  generation = generation + 1
  delay = delay or config.tooltip_delay
  if tgt == nil then
    core.redraw = true
  elseif delay <= 0 or now - last_shown < tooltip.warm_time then
    show_at = now
    core.redraw = true
  else
    show_at = now + delay
    local gen = generation
    core.add_thread(function()
      coroutine.yield(delay)
      if gen == generation then core.redraw = true end
    end)
  end
end

---Whether a source's tooltip for a target should be drawn now.
---@param src any
---@param tgt any
---@return boolean
function tooltip.shown(src, tgt)
  return src == owner and tgt == target and showing(system.get_time())
end

---Hides the tooltip (on a click), until the pointer moves to another target.
function tooltip.dismiss()
  if target ~= nil and not dismissed then
    dismissed = true
    last_shown = -math.huge
    core.redraw = true
  end
end

---Forgets the target (the pointer left the window).
function tooltip.clear()
  if owner ~= nil then tooltip.hover(owner, nil) end
end

return tooltip
