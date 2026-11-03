local core = require "core"
local config = require "core.config"
local DocView = require "core.docview"
local git = require "plugins.gitkit.git"
local ReadDoc = require "plugins.gitkit.readdoc"

---Opens files as they were at a revision, in read-only docs.
local revision = {}

-- docs by repository, revision and path, while open
local docs = setmetatable({}, { __mode = "v" })

---A revision as shown: a hash shortened (with any ^ or ~ after it).
---@param rev string
---@return string
function revision.short(rev)
  return (rev:gsub("^(" .. string.rep("%x", 8) .. ")%x+", "%1"))
end

local function show(doc, line, col)
  local dv = core.root_view:open_doc(doc, { preview = true })
  line = math.max(1, math.min(line or 1, #dv.doc.lines))
  dv.doc:set_selection(line, col or 1)
  -- a tab just brought to the front has its size from when it last was
  core.root_view.root_node:get_node_for_view(dv):update_layout()
  dv:scroll_to_line(line, true, true)
  return dv
end

-- text with LF line endings, as docs hold it
local function lf(text)
  return (text:gsub("\r\n", "\n"))
end

-- The working copy's text: its open doc's (unsaved edits included), else the
-- file's; nil if there's neither.
local function working_text(abs)
  for _, doc in ipairs(core.docs) do
    if doc.abs_filename == abs then
      -- every line ends with "\n", the last one's not in the text
      return table.concat(doc.lines):sub(1, -2)
    end
  end
  local fp = io.open(abs, "rb")
  if not fp then return end
  local text = fp:read("a")
  fp:close()
  return lf(text)
end

---Opens `path` (as git names it, in the repository at `root`) at `rev` with
---the caret at line, col: the working copy if `rev` is nil or the file was
---the same then (config.plugins.gitkit.open_working_copy), else a read-only
---doc of it as it was (asked of git in the background).
---@param root string
---@param rev? string
---@param path string
---@param line? integer
---@param col? integer
function revision.open(root, rev, path, line, col)
  local abs = git.absolute_path(root, path)
  local function open_working_copy()
    local ok, doc = core.try(core.open_doc, abs)
    if ok and doc then show(doc, line, col) end
  end
  if not rev then return open_working_copy() end
  local key = root .. "\0" .. rev .. "\0" .. path
  core.add_thread(function()
    local doc = docs[key]
    local text = doc and doc.gitkit_text
    if not text then
      local out, err = git.run(root, { "show", rev .. ":" .. path })
      if not out then
        core.error("Can't show %s at %s: %s", path, revision.short(rev), err)
        return
      end
      text = lf(out)
    end
    if config.plugins.gitkit.open_working_copy and working_text(abs) == text then
      return open_working_copy()
    end
    doc = docs[key]
    if not doc then
      doc = ReadDoc(path .. " @ " .. revision.short(rev), path)
      doc.gitkit_revision = { root = root, rev = rev, path = path }
      doc.gitkit_text = text
      doc:set_text(text)
      docs[key] = doc
    end
    show(doc, line, col)
  end)
end

-- Views of read-only revisions aren't restored with the workspace (there's
-- no file to restore them from)
local DocView_is_transient = DocView.is_transient
function DocView:is_transient()
  return self.doc:is(ReadDoc) or DocView_is_transient(self)
end

return revision
