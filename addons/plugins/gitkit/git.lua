local core = require "core"
local config = require "core.config"

---Runs git in the background, from core threads: output is read as it comes,
---the thread waiting on the pipe (core.watch_readable) in between, so the
---editor never blocks and an idle wait doesn't wake it.
local git = {}

---Options every command gets: output that's the same on every machine (paths
---unquoted, no colors, pager or external diff tools, default prefixes).
local COMMON = {
  "-c", "core.quotePath=false", "-c", "color.ui=false", "--no-pager",
}

---The argument list for git with `args`, run in `dir`.
---@param dir string
---@param args string[]
---@return string[]
function git.command(dir, args)
  local cmd = { config.plugins.gitkit.git, "-C", dir }
  for _, a in ipairs(COMMON) do table.insert(cmd, a) end
  for _, a in ipairs(args) do table.insert(cmd, a) end
  return cmd
end

---@class gitkit.run_options
---@field on_data? fun(chunk: string) Gets stdout as it comes (then not returned)
---@field cancelled? fun(): boolean Checked between reads: true kills git
---@field max_bytes? integer Stops reading stdout after this much (git is killed)

---Runs git with `args` in `dir`, in a core thread. Returns its output (all of
---stdout, unless options.on_data takes it), or nil and an error message: git's
---stderr, or why it couldn't run. `truncated` is true if max_bytes stopped it.
---@param dir string
---@param args string[]
---@param options? gitkit.run_options
---@return string? output, string? err, boolean? truncated
function git.run(dir, args, options)
  options = options or {}
  local ok, proc = pcall(process.start, git.command(dir, args))
  if not ok then return nil, tostring(proc) end
  local out, err, size = {}, {}, 0
  local truncated = false
  while true do
    if options.cancelled and options.cancelled() then
      proc:kill()
      return nil, "cancelled"
    end
    local s = proc:read_stdout(65536)
    -- drained as we go, so that git never blocks writing to it
    local e = proc:read_stderr(65536)
    if e and e ~= "" then table.insert(err, e) end
    if not s then break end
    if s == "" then
      local source = proc:watch_source(process.STREAM_STDOUT)
      if not source then break end
      core.wait_for(core.watch_readable(source))
    else
      size = size + #s
      if options.on_data then options.on_data(s) else table.insert(out, s) end
      if options.max_bytes and size >= options.max_bytes then
        truncated = true
        proc:kill()
        break
      end
    end
  end
  while true do
    local e = proc:read_stderr(65536)
    if not e or e == "" then break end
    table.insert(err, e)
  end
  local code = proc:wait(process.WAIT_INFINITE)
  if code ~= 0 and not truncated then
    local msg = table.concat(err):gsub("%s+$", "")
    return nil, msg ~= "" and msg or ("git exited with " .. tostring(code))
  end
  return table.concat(out), nil, truncated
end

---The top directory of the repository `path` (a file or directory) is in, or
---nil and why not. In a core thread.
---@param path string
---@return string? root, string? err
function git.get_root(path)
  local info = system.get_file_info(path)
  local dir = path
  if not info or info.type ~= "dir" then dir = path:match("^(.*)[/\\][^/\\]*$") or path end
  local out, err = git.run(dir, { "rev-parse", "--show-toplevel" })
  if not out then return nil, err end
  local root = out:match("^([^\n]+)")
  if PLATFORM == "Windows" and root then root = root:gsub("/", "\\") end
  return root
end

---`path`, an absolute path in `root`'s repository, relative to it with /
---separators, as git names it.
---@param root string
---@param path string
---@return string
function git.relative_path(root, path)
  local rel = path:sub(#root + 2)
  if PATHSEP ~= "/" then rel = rel:gsub("\\", "/") end
  return rel
end

---The absolute path of `rel`, a path in `root`'s repository as git names it.
---@param root string
---@param rel string
---@return string
function git.absolute_path(root, rel)
  if PATHSEP ~= "/" then rel = rel:gsub("/", PATHSEP) end
  return root .. PATHSEP .. rel
end

return git
