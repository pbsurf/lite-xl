local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local LogView = require "core.logview"


local fullscreen = false
local restore_title_view = false

local function suggest_directory(text)
  text = common.home_expand(text)
  local basedir = common.dirname(core.project_dir)
  return common.home_encode_list((basedir and text == basedir .. PATHSEP or text == "") and
    core.recent_projects or common.dir_path_suggest(text))
end

local function check_directory_path(path)
    local abs_path = system.absolute_path(path)
    local info = abs_path and system.get_file_info(abs_path)
    if not info or info.type ~= 'dir' then
      return nil
    end
    return abs_path
end

-- the system's file dialogs: callback gets the paths picked
local function dialog_result(callback)
  return function(status, result)
    if status == "accept" then
      callback(result)
    elseif status == "error" then
      core.error("Error while opening dialog: %s", result or "")
    end
  end
end

local function open_directory_dialog(title, allow_many, callback)
  core.open_directory_dialog(dialog_result(callback), {
    title = title, allow_many = allow_many,
    default_location = common.dirname(core.project_dir),
  })
end

command.add(nil, {
  ["core:quit"] = function()
    core.quit()
  end,

  ["core:restart"] = function()
    core.restart()
  end,

  ["core:force-quit"] = function()
    core.quit(true)
  end,

  ["core:toggle-fullscreen"] = function()
    fullscreen = not fullscreen
    if fullscreen then
      restore_title_view = core.title_view.visible
    end
    system.set_window_mode(fullscreen and "fullscreen" or "normal")
    core.show_title_bar(not fullscreen and restore_title_view)
    core.title_view:configure_hit_test(not fullscreen and config.borderless)
  end,

  ["core:reload-module"] = function()
    core.command_view:enter("Reload Module", {
      submit = function(text, item)
        local text = item and item.text or text
        core.reload_module(text)
        core.log("Reloaded module %q", text)
      end,
      suggest = function(text)
        local items = {}
        for name in pairs(package.loaded) do
          table.insert(items, name)
        end
        return common.fuzzy_match(items, text)
      end
    })
  end,

  ["core:find-command"] = function()
    local commands = {}
    for _, name in ipairs(command.get_all_valid()) do
      if not command.hidden[name] then table.insert(commands, name) end
    end
    core.command_view:enter("Do Command", {
      submit = function(text, item)
        if item then
          command.perform(item.command)
        end
      end,
      suggest = function(text)
        local res = {}
        for _, name in ipairs(commands) do
          local score = system.fuzzy_match(name, text)
          local keywords = command.keywords[name]
          if keywords then
            -- scored separately, as the matcher penalizes longer strings; keywords
            -- first, so e.g. "font inc" finds "scale:increase"
            local kscore = system.fuzzy_match(keywords .. " " .. name, text)
            if kscore and (not score or kscore > score) then score = kscore end
          end
          if score then table.insert(res, { name = name, score = score }) end
        end
        table.sort(res, function(a, b) return a.score > b.score end)
        for i, item in ipairs(res) do
          res[i] = {
            text = command.prettify_name(item.name),
            info = keymap.get_binding(item.name),
            command = item.name,
          }
        end
        return res
      end
    })
  end,

  ["core:find-file"] = function()
    -- the files of each project directory: those found so far while it's
    -- being indexed the first time
    local function dir_files(dir)
      return not dir.files_limit and dir.files or dir.scan and dir.scan.files
    end
    local function is_indexing()
      for _, dir in ipairs(core.project_directories) do
        if dir.files_limit and dir.scan then return true end
      end
      return false
    end
    local indexing = is_indexing()
    if not indexing and not core.project_files_number() then
       return command.perform "core:open-file"
    end
    local files, files_state
    local function get_files()
      local state = {}
      for _, dir in ipairs(core.project_directories) do
        local list = dir_files(dir)
        table.insert(state, list and #list or 0)
        table.insert(state, tostring(list))
        table.insert(state, dir.files_change_id or 0)
      end
      state = table.concat(state, " ")
      if state ~= files_state then
        files, files_state = {}, state
        for _, dir in ipairs(core.project_directories) do
          local path = (dir.name == core.project_dir and "" or dir.name .. PATHSEP)
          for _, item in ipairs(dir_files(dir) or {}) do
            if item.type == "file" then
              table.insert(files, common.home_encode(path .. item.filename))
            end
          end
        end
      end
      return files
    end
    local function suggest(text)
      return common.fuzzy_match_with_recents(get_files(), core.visited_files, text)
    end
    local hints = {}
    for _, mode in ipairs(command.find_file_modes) do
      table.insert(hints, mode.prefix .. " " .. mode.text)
    end
    core.command_view:enter("Open File From Project", {
      modes = command.find_file_modes,
      placeholder = "file name, or type " .. table.concat(hints, ", "),
      submit = function(text, item)
        text = item and item.text or text
        core.root_view:open_doc(core.open_doc(common.home_expand(text)))
      end,
      suggest = suggest
    })
    -- while indexing, the suggestions follow the files found
    core.add_thread(function()
      while indexing and core.command_view.state.suggest == suggest do
        coroutine.yield(0.25)
        indexing = is_indexing()
        if core.command_view.state.suggest == suggest then
          core.command_view:update_suggestions()
          core.redraw = true
        end
      end
    end)
  end,

  ["core:new-doc"] = function()
    core.root_view:open_doc(core.open_doc())
  end,

  ["core:reopen-closed-tab"] = function()
    local path = core.get_closed_recent_files()[1]
    if path then core.reopen_file(path) else core.log("No closed file to reopen") end
  end,

  ["core:new-named-doc"] = function()
    core.command_view:enter("File name", {
      submit = function(text)
        core.root_view:open_doc(core.open_doc(text))
      end
    })
  end,

  ["core:open-file"] = function()
    local view = core.active_view
    local text
    if view.doc and view.doc.abs_filename then
      local dirname, filename = view.doc.abs_filename:match("(.*)[/\\](.+)$")
      if dirname then
        dirname = core.normalize_to_project_dir(dirname)
        text = dirname == core.project_dir and "" or common.home_encode(dirname) .. PATHSEP
      end
    end
    core.command_view:enter("Open File", {
      text = text,
      submit = function(text)
        local filename = system.absolute_path(common.home_expand(text))
        core.root_view:open_doc(core.open_doc(filename))
      end,
      suggest = function (text)
          return common.home_encode_list(common.path_suggest(common.home_expand(text)))
        end,
      validate = function(text)
          local filename = common.home_expand(text)
          local path_stat, err = system.get_file_info(filename)
          if err then
            if err:find("No such file", 1, true) then
              -- check if the containing directory exists
              local dirname = common.dirname(filename)
              local dir_stat = dirname and system.get_file_info(dirname)
              if not dirname or (dir_stat and dir_stat.type == 'dir') then
                return true
              end
            end
            core.error("Cannot open file %s: %s", text, err)
          elseif path_stat.type == 'dir' then
            core.error("Cannot open %s, is a folder", text)
          else
            return true
          end
        end,
    })
  end,

  ["core:open-file-picker"] = function()
    local doc = core.active_view.doc
    core.open_file_dialog(dialog_result(function(filenames)
      for _, filename in ipairs(filenames) do
        core.root_view:open_doc(core.open_doc(filename))
      end
    end), {
      allow_many = true,
      default_location = doc and doc.abs_filename and common.dirname(doc.abs_filename)
        or core.project_dir,
    })
  end,

  ["core:change-project-folder-picker"] = function()
    open_directory_dialog("Change Project Folder", false, function(dirs)
      if dirs[1] == core.project_dir then return end
      core.confirm_close_docs(core.docs, function(dirpath)
        core.open_folder_project(dirpath)
      end, dirs[1])
    end)
  end,

  ["core:open-project-folder-picker"] = function()
    open_directory_dialog("Open Project", false, function(dirs)
      if dirs[1] == core.project_dir then
        core.error("Directory %q is currently opened", dirs[1])
        return
      end
      system.exec(string.format("%q %q", EXEFILE, dirs[1]))
    end)
  end,

  ["core:add-directory-picker"] = function()
    open_directory_dialog("Add Directory", true, function(dirs)
      for _, dir in ipairs(dirs) do
        core.add_project_directory(system.absolute_path(dir))
      end
    end)
  end,

  ["core:open-log"] = function()
    local node = core.root_view:get_active_node_default()
    node:add_view(LogView())
  end,

  ["core:open-user-module"] = function()
    local user_module_doc = core.open_doc(USERDIR .. "/init.lua")
    if not user_module_doc then return end
    core.root_view:open_doc(user_module_doc)
  end,

  ["core:open-project-module"] = function()
    if not system.get_file_info(".lite_project.lua") then
      core.try(core.write_init_project_module, ".lite_project.lua")
    end
    local doc = core.open_doc(".lite_project.lua")
    core.root_view:open_doc(doc)
    doc:save()
  end,

  ["core:change-project-folder"] = function()
    local dirname = common.dirname(core.project_dir)
    local text
    if dirname then
      text = common.home_encode(dirname) .. PATHSEP
    end
    core.command_view:enter("Change Project Folder", {
      text = text,
      submit = function(text)
        local path = common.home_expand(text)
        local abs_path = check_directory_path(path)
        if not abs_path then
          core.error("Cannot open directory %q", path)
          return
        end
        if abs_path == core.project_dir then return end
        core.confirm_close_docs(core.docs, function(dirpath)
          core.open_folder_project(dirpath)
        end, abs_path)
      end,
      suggest = suggest_directory
    })
  end,

  ["core:open-project-folder"] = function()
    local dirname = common.dirname(core.project_dir)
    local text
    if dirname then
      text = common.home_encode(dirname) .. PATHSEP
    end
    core.command_view:enter("Open Project", {
      text = text,
      submit = function(text)
        local path = common.home_expand(text)
        local abs_path = check_directory_path(path)
        if not abs_path then
          core.error("Cannot open directory %q", path)
          return
        end
        if abs_path == core.project_dir then
          core.error("Directory %q is currently opened", abs_path)
          return
        end
        system.exec(string.format("%q %q", EXEFILE, abs_path))
      end,
      suggest = suggest_directory
    })
  end,

  ["core:add-directory"] = function()
    core.command_view:enter("Add Directory", {
      submit = function(text)
        text = common.home_expand(text)
        local path_stat, err = system.get_file_info(text)
        if not path_stat then
          core.error("cannot open %q: %s", text, err)
          return
        elseif path_stat.type ~= 'dir' then
          core.error("%q is not a directory", text)
          return
        end
        core.add_project_directory(system.absolute_path(text))
      end,
      suggest = suggest_directory
    })
  end,

  ["core:remove-directory"] = function()
    local dir_list = {}
    local n = #core.project_directories
    for i = n, 2, -1 do
      dir_list[n - i + 1] = core.project_directories[i].name
    end
    core.command_view:enter("Remove Directory", {
      submit = function(text, item)
        text = common.home_expand(item and item.text or text)
        if not core.remove_project_directory(text) then
          core.error("No directory %q to be removed", text)
        end
      end,
      suggest = function(text)
        text = common.home_expand(text)
        return common.home_encode_list(common.dir_list_suggest(text, dir_list))
      end
    })
  end,
})

-- for project directories over config.max_project_files: index them all anyway,
-- now and when opened again
command.add(function()
  for _, dir in ipairs(core.project_directories) do
    if dir.over_limit then return true end
  end
  return false
end, {
  ["core:index-project"] = function()
    local storage = require "core.storage"
    for _, dir in ipairs(core.project_directories) do
      if dir.over_limit then
        storage.save("project_index", dir.name, true)
        core.scan_project_directory(dir)
      end
    end
  end,
})
