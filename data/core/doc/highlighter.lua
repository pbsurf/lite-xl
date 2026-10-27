local core = require "core"
local common = require "core.common"
local config = require "core.config"
local tokenizer = require "core.tokenizer"
local Object = require "core.object"


local Highlighter = Object:extend()

function Highlighter:__tostring() return "Highlighter" end

function Highlighter:new(doc)
  self.doc = doc
  self.running = false
  self:reset()
end

-- Lines are tokenized in order, each from the state the line before ended in, by
-- a thread that works up to the lines wanted (drawn, or asked for by plugins).
-- Lines before first_invalid_line are tokenized from the top. Lines wanted more
-- than config.highlighter_sync_lines below them could take minutes to reach in a
-- large file, so they get a sync region instead: tokenized from SYNC_CONTEXT
-- lines above them (sync.line), guessing the default state there (wrong only
-- inside a long comment or string), up to sync.stop - 1. One per group of lines
-- wanted (the view, the cursor's line, another view of the doc), so the lines
-- between them aren't tokenized either; those are left as they are until a pass
-- gets there (any pass checks the lines it goes over, so a region can be dropped).
-- sync.min and sync.max are the lines wanted from it since the thread started.
local SYNC_CONTEXT = 500
local MAX_SYNCS = 8

-- Tokenizes the lines from..to that aren't up to date with the line before them,
-- line from with the default state if guess; returns the first line not done:
-- to + 1, or a long line left unfinished, to resume after a yield.
local function tokenize_lines(self, from, to, guess)
  local retokenized_from
  local next_line = to + 1
  for i = from, to do
    local prev = not (guess and i == from) and self.lines[i - 1]
    local state = prev and prev.state
    local line = self.lines[i]
    if line and line.resume and (line.init_state ~= state or line.text ~= self.doc.lines[i]) then
      -- Reset the progress if no longer valid
      line.resume = nil
    end
    if not (line and line.init_state == state and line.text == self.doc.lines[i] and not line.resume) then
      retokenized_from = retokenized_from or i
      self.lines[i] = self:tokenize_line(i, state, line and line.resume)
      if self.lines[i].resume then
        next_line = i
        break
      end
    elseif retokenized_from then
      self:update_notify(retokenized_from, i - retokenized_from - 1)
      retokenized_from = nil
    end
  end
  if retokenized_from then
    self:update_notify(retokenized_from, math.min(next_line, to) - retokenized_from)
  end
  return next_line
end

-- Returns the sync region for a line wanted far below first_invalid_line: the
-- one it's near, or a new one.
local function get_sync(self, idx)
  local dist = config.highlighter_sync_lines
  for _, sync in ipairs(self.syncs) do
    if idx >= (sync.line or sync.min) - dist and idx <= (sync.stop or sync.max) + dist then
      return sync
    end
  end
  if #self.syncs >= MAX_SYNCS then table.remove(self.syncs, 1) end
  local sync = {}
  table.insert(self.syncs, sync)
  return sync
end

-- Returns the lines to tokenize next and the sync region they're in, if any
-- (placing it as needed), or nil when the lines wanted are done.
local function next_work(self)
  if self.first_invalid_line <= self.max_wanted_line then
    return self.first_invalid_line, self.max_wanted_line
  end
  for i = #self.syncs, 1, -1 do
    local sync = self.syncs[i]
    if sync.min then
      local top = sync.min - SYNC_CONTEXT
      if top <= self.first_invalid_line then
        -- the exact pass got close enough (or the context is larger than the
        -- distance that makes lines far): it takes them over
        self.max_wanted_line = math.max(self.max_wanted_line, sync.max)
        table.remove(self.syncs, i)
        return next_work(self)
      end
      if not sync.line or top < sync.line or top > sync.stop then
        sync.line, sync.stop = top, top
      end
      local to = math.min(sync.max, #self.doc.lines)
      if sync.stop <= to then return sync.stop, to, sync end
    end
  end
end

-- Drops the sync regions starting in from..to - 1, which a pass from a line
-- above them has just tokenized; returns the furthest line wanted from them.
local function drop_syncs(self, from, to, keep)
  local max = 0
  for i = #self.syncs, 1, -1 do
    local sync = self.syncs[i]
    if sync ~= keep and sync.line and sync.line >= from and sync.line < to then
      max = math.max(max, sync.max or 0)
      table.remove(self.syncs, i)
    end
  end
  return max
end

-- init incremental syntax highlighting
function Highlighter:start()
  if self.running or self.stopped then return end
  self.running = true
  core.add_thread(function()
    while not self.stopped do
      local from, to, sync = next_work(self)
      if not from then break end
      local next_line = tokenize_lines(self, from, math.min(from + 40, to),
        sync and from == sync.line)
      if sync then
        sync.stop = next_line
        sync.max = math.max(sync.max, drop_syncs(self, sync.line, next_line, sync))
      else
        self.first_invalid_line = next_line
        drop_syncs(self, 1, next_line)
      end
      core.redraw = true
      coroutine.yield()
    end
    self.max_wanted_line = 0
    for _, sync in ipairs(self.syncs) do sync.min, sync.max = nil, nil end
    self.running = false
  end, self)
end

-- stop tokenizing for good: the doc was closed (else the thread would go on
-- tokenizing up to the line last viewed, in a large file for minutes)
function Highlighter:stop()
  self.stopped = true
end

local function set_max_wanted_lines(self, amount)
  self.max_wanted_line = amount
  if self.first_invalid_line <= self.max_wanted_line then
    self:start()
  end
end


function Highlighter:reset()
  self.lines = {}
  self:soft_reset()
end

function Highlighter:soft_reset()
  for i=1,#self.lines do
    self.lines[i] = false
  end
  self.first_invalid_line = 1
  self.max_wanted_line = 0
  self.syncs = {}
end

function Highlighter:invalidate(idx)
  self.first_invalid_line = math.min(self.first_invalid_line, idx)
  for _, sync in ipairs(self.syncs) do
    if sync.line and idx >= sync.line then sync.stop = math.min(sync.stop, idx) end
  end
  set_max_wanted_lines(self, math.min(self.max_wanted_line, #self.doc.lines))
end

function Highlighter:insert_notify(line, n)
  for _, sync in ipairs(self.syncs) do
    if sync.line and line < sync.line then
      sync.line, sync.stop = sync.line + n, sync.stop + n
    end
  end
  self:invalidate(line)
  local blanks = { }
  for i = 1, n do
    blanks[i] = false
  end
  common.splice(self.lines, line, 0, blanks)
end

function Highlighter:remove_notify(line, n)
  for _, sync in ipairs(self.syncs) do
    if sync.line and sync.line >= line + n then
      sync.line, sync.stop = sync.line - n, sync.stop - n
    elseif sync.line and sync.line >= line then
      -- the region's first line is removed: start it at the line after
      sync.line, sync.stop = line, line
    end
  end
  self:invalidate(line)
  common.splice(self.lines, line, n)
end

function Highlighter:update_notify(line, n)
  -- plugins can hook here to be notified that lines have been retokenized
end


function Highlighter:tokenize_line(idx, state, resume)
  local res = {}
  res.init_state = state
  res.text = self.doc.lines[idx]
  res.tokens, res.state, res.resume = tokenizer.tokenize(self.doc.syntax, res.text, state, resume)
  return res
end


function Highlighter:get_line(idx)
  local line = self.lines[idx]
  if not line or line.text ~= self.doc.lines[idx] then
    local prev = self.lines[idx - 1]
    line = self:tokenize_line(idx, prev and prev.state)
    self.lines[idx] = line
    self:update_notify(idx, 0)
  end
  local sync_lines = config.highlighter_sync_lines
  if sync_lines and idx > self.first_invalid_line + sync_lines then
    local sync = get_sync(self, idx)
    sync.min = math.min(sync.min or idx, idx)
    sync.max = math.max(sync.max or idx, idx)
    if next_work(self) then self:start() end
  else
    set_max_wanted_lines(self, math.max(self.max_wanted_line, idx))
  end
  return line
end


function Highlighter:each_token(idx)
  return tokenizer.each_token(self:get_line(idx).tokens)
end

return Highlighter
