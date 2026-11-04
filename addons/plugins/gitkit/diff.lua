---Parses what `git show --stat --patch` (or `git diff --stat --patch`) prints
---into the lines a commit view shows, each with what it is and where in the
---files it came from. Patch lines lose their +, - or space prefix (their kind
---says it, drawn in the gutter), so that their text is the file's: copied as
---code, and a column in it is one in the file.
local diff = {}

---@class gitkit.diff.file
---@field old_path? string As git names it, nil if the file was added
---@field new_path? string nil if the file was deleted
---@field line integer The view's line showing its name
---@field binary? boolean
---@field submodule? boolean A submodule: its patch lines are "Subproject commit <hash>"
---@field copied? boolean Copied from old_path (else renamed, if the paths differ)
---@field added integer Its patch's added lines
---@field removed integer Removed lines

---@class gitkit.diff.hunk
---@field first integer The view's line of its first patch line
---@field last integer Of its last

---@class gitkit.diff.info
---@field kind "commit"|"header"|"message"|"stat"|"summary"|"pad"|"file"|"meta"|"hunk"|"add"|"del"|"ctx"|"nonl"|"blank"|"note"
---@field file? gitkit.diff.file The file a "pad" (the empty line above its
---title), "file", "meta", "hunk" or patch line belongs to
---@field hunk? gitkit.diff.hunk A patch line's hunk
---@field old? integer A line's number in the old file ("del", "ctx"; a "hunk"'s first)
---@field new? integer In the new file ("add", "ctx"; a "hunk"'s first)
---@field stat? integer A "stat" line's file, by index in `files`

---@class gitkit.diff.result
---@field lines string[] The view's lines, each ending with "\n"
---@field infos gitkit.diff.info[] One for each line
---@field files gitkit.diff.file[] In the order git printed them

-- "a/P b/Q" from a "diff --git" line: P and Q are the same unless renamed,
-- copied (then rename/copy lines give them) and split at the middle if so
local function split_git_paths(s)
  local n = (#s - 5) / 2
  if n == math.floor(n) and n > 0 and s:sub(1, 2) == "a/" and s:sub(3 + n, 5 + n) == " b/"
     and s:sub(3, 2 + n) == s:sub(6 + n) then
    return s:sub(3, 2 + n), s:sub(6 + n)
  end
  local a, b = s:match("^a/(.-) b/(.*)$")
  return a or s, b or s
end

-- a path from a "---" or "+++" line: nil for /dev/null; git adds a tab after
-- names with spaces
local function patch_path(s, prefix)
  s = s:gsub("\t$", "")
  if s == "/dev/null" then return nil end
  if s:sub(1, 2) == prefix then return s:sub(3) end
  return s
end

-- between a renamed (or copied) file's old and new path in its title
diff.RENAME_ARROW = " → "

---The title line shown for a file: its path, both if renamed or copied.
---@param file gitkit.diff.file
---@return string
function diff.file_title(file)
  if file.old_path and file.new_path and file.old_path ~= file.new_path then
    return file.old_path .. diff.RENAME_ARROW .. file.new_path
  end
  return file.new_path or file.old_path
end

---How the file changed: "new", "deleted", "renamed", "copied", or nil if
---only its content (or mode) did.
---@param file gitkit.diff.file
---@return string?
function diff.file_status(file)
  if not file.old_path then return "new" end
  if not file.new_path then return "deleted" end
  if file.old_path ~= file.new_path then return file.copied and "copied" or "renamed" end
end

---Parses git's output. `has_header`: it starts with a commit's header and
---message (git show), else with the stat (git diff). `truncated`: it was cut
---off, its last line maybe in the middle.
---@param text string
---@param has_header boolean
---@param truncated? boolean
---@return gitkit.diff.result
function diff.parse(text, has_header, truncated)
  local lines, infos, files = {}, {}, {}
  local function add(s, info)
    lines[#lines + 1] = s .. "\n"
    infos[#infos + 1] = info
  end

  local phase = has_header and "header" or "stat"
  local file, hunk, in_hunk
  local old, new = 0, 0
  local nstat = 0

  -- the file's title line, once its paths are known (from the lines after
  -- "diff --git")
  local function finish_file()
    if file then lines[file.line] = diff.file_title(file) .. "\n" end
  end

  if truncated then text = text:match("^(.*\n)") or "" end
  if text:sub(-1) ~= "\n" and text ~= "" then text = text .. "\n" end

  for raw in text:gmatch("([^\n]*)\n") do
    if phase == "header" then
      if raw == "" then
        phase = "message"
        add("", { kind = "blank" })
      elseif raw:match("^commit ") then
        add(raw, { kind = "commit" })
      else
        add(raw, { kind = "header" })
      end
    elseif phase == "message" and (raw == "" or raw:sub(1, 4) == "    ") then
      add(raw, { kind = raw == "" and "blank" or "message" })
    else
      if phase ~= "diff" and raw:match("^diff %-%-git ") then phase = "diff" end
      if phase ~= "diff" then
        phase = "stat"
        if raw == "---" then
          -- git's separator before the stat
          add("", { kind = "blank" })
        elseif raw:match("^ .* | ") then
          nstat = nstat + 1
          add(raw, { kind = "stat", stat = nstat })
        elseif raw:match("^ %d+ files? changed") then
          add(raw, { kind = "summary" })
        else
          add(raw, { kind = raw == "" and "blank" or "header" })
        end
      elseif raw:match("^diff %-%-git ") then
        finish_file()
        local a, b = split_git_paths(raw:sub(12))
        file = { old_path = a, new_path = b, added = 0, removed = 0 }
        table.insert(files, file)
        in_hunk, hunk = false, nil
        -- the empty line above the title, drawn as part of it
        if #lines > 0 and infos[#infos].kind == "blank" then
          infos[#infos] = { kind = "pad", file = file }
        else
          add("", { kind = "pad", file = file })
        end
        file.line = #lines + 1
        add(diff.file_title(file), { kind = "file", file = file })
      elseif in_hunk and raw:match("^[ +%-\\]") or (in_hunk and raw == "") then
        local c = raw:sub(1, 1)
        local info = { file = file, hunk = hunk }
        if c == "+" then
          info.kind, info.new = "add", new
          file.added = file.added + 1
          new = new + 1
        elseif c == "-" then
          info.kind, info.old = "del", old
          file.removed = file.removed + 1
          old = old + 1
        elseif c == "\\" then
          info.kind = "nonl"
        else
          info.kind, info.old, info.new = "ctx", old, new
          old, new = old + 1, new + 1
        end
        -- "\ No newline at end of file" as git prints it
        add(c == "\\" and raw or raw:sub(2), info)
        hunk.last = #lines
      elseif raw:match("^@@ ") then
        local o, n = raw:match("^@@ %-(%d+)[,%d]* %+(%d+)")
        old, new = tonumber(o) or 1, tonumber(n) or 1
        if not in_hunk then finish_file() end
        in_hunk = true
        hunk = { first = #lines + 2, last = #lines + 1 }
        add(raw, { kind = "hunk", file = file, old = old, new = new })
      elseif file and not in_hunk then
        -- the file's header lines: paths are taken, the rest shown
        if raw:match("^%-%-%- ") then
          file.old_path = patch_path(raw:sub(5), "a/")
        elseif raw:match("^%+%+%+ ") then
          file.new_path = patch_path(raw:sub(5), "b/")
        elseif raw:match("^index ") then
          -- nothing in it the title doesn't say, but a submodule's mode
          if raw:match(" 160000$") then file.submodule = true end
        else
          local from = raw:match("^rename from (.*)$") or raw:match("^copy from (.*)$")
          local to = raw:match("^rename to (.*)$") or raw:match("^copy to (.*)$")
          if from then file.old_path = from end
          if to then file.new_path = to end
          if raw:match("^new file mode") then file.old_path = nil end
          if raw:match("^deleted file mode") then file.new_path = nil end
          if raw:match("^copy from ") then file.copied = true end
          if raw:match("^Binary files") then file.binary = true end
          -- an added or deleted submodule (no mode on its index line)
          if raw:match("^new file mode 160000$") or raw:match("^deleted file mode 160000$") then
            file.submodule = true
          end
          -- what the title and its tags say already isn't shown: renames,
          -- copies, their similarity, binary files, and a new or deleted
          -- file's usual mode
          local said = from or to or file.binary
            or raw:match("^similarity index") or raw:match("^dissimilarity index")
            or raw:match("^new file mode 100644$") or raw:match("^deleted file mode 100644$")
          if not said then add(raw, { kind = "meta", file = file }) end
        end
      else
        add(raw, { kind = "header" })
      end
    end
  end
  finish_file()
  if truncated then
    add("", { kind = "blank" })
    add("(cut off: the rest is too large to show)", { kind = "note" })
  end
  if #lines == 0 then add("", { kind = "blank" }) end
  return { lines = lines, infos = infos, files = files }
end

return diff
