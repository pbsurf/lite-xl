local core = require "core"
local common = require "core.common"
local config = require "core.config"
local build = require "plugins.build"

-- Takes project configuration like so:
-- `name` is your target name
-- `binary` is the target full link
-- `type` is your type of build; valid values are `executable`, `static` or `shared`.
-- `ignored_files` will ignore any file that matches the pattern based on the normal ignore syntax.
-- `files` will take specific files and add them to the compile with override options based on any of these other options
-- `cflags` will specify compile time flags.
-- `ldflags` will specify link time flags
-- `cc` will specify your c compiler
-- `cxx` will specify your c++ compiler
-- `ar` specifies your archiver
-- `srcs` specifies the folders where your source is located.
-- { name = string, cc = "gcc", cxx = "g++", ar = "ar", binary = path, ignored_files = { "src/api.c" }, cflags = string, ldflags = string, files = {}, obj = path, srcs = { "." } }

if not config.plugins.build.internal then config.plugins.build.internal = {} end
local internal = common.merge({
  threads = build.threads,
  priority = 10
}, config.plugins.build.internal)

local function split(str, splitter)
  local t = {}
  local s = 1
  while true do
    local ns, e = str:find(splitter, s)
    if not ns then break end
    table.insert(t, str:sub(s, ns - 1))
    s = e + 1
  end
  table.insert(t, str:sub(s))
  return t
end
local function table_concat(t1, t2)
  local t = {}
  for i,v in ipairs(t1) do table.insert(t, v) end
  for i,v in ipairs(t2) do table.insert(t, v) end
  return t
end


local function get_field(target, path, field) if path and target and  target.files and target.files[path] then return target.files[path][field] or target[field] or internal[field] end return target[field] or internal[field] or build[field] end
local function get_cflags(target, path) return get_field(target, path, "cflags") end
local function get_cxxflags(target, path) return get_field(target, path, "cxxflags") end
local function get_type(target) return get_field(target, nil, "type") end
local function get_ldflags(target) return get_field(target, nil, "ldflags") end
local function get_binary(target) return get_field(target, nil, "binary") end
local function get_compiler(target, path)
  if not path then return get_field(target, path, "cc") end
  if path:find("%.c$") then return split(get_field(target, path, "cc"), "%s+") end
  if path:find("%.cc$") or path:find("%.cpp$") then return split(get_field(target, path, "cxx"), "%s+") end
  return nil
end
local function get_archiver(target) return get_field(target, nil, "ar") end
local function get_linker(target) return get_field(target, nil, "ld") end

local function get_source_files(target)
  local files = {}
  for project, file in core.get_project_files() do
    local file = file.filename
    for i, src in ipairs(target.srcs) do
      local path = core.normalize_to_project_dir(src)
      if file:find(path, 1, true) == 1 and get_compiler(target, file) then 
        table.insert(files, file)
        break
      end  
    end
  end
  return files
end


local function get_compile_flags(target, file)
  if file:find("%.cpp$") or file:find("%.cc") then return get_field(target, file, "cxxflags") end
  return get_field(target, file, "cflags")
end

function internal.infer()
  -- autodetect
  local srcs = nil
  if system.get_file_info(core.root_project():absolute_path("src")) then
    return {
      { name = "debug", binary = common.basename(core.root_project().path) .. "-debug" .. (PLATFORM == "Windows" and ".exe" or ""), cflags = {"-g", "-O0" }, cxxflags = { "-g", "-O0" }, srcs = { "src" } },
      { name = "release", binary = common.basename(core.root_project().path) .. "-release" .. (PLATFORM == "Windows" and ".exe" or ""), cflags = { "-O3" }, cxxflags = { "-O3" }, srcs = { "src" } },
    }
  end
end

-- a path as a makefile's target or prerequisite
local function make_path(path)
  return (path:gsub("%$", "$$"):gsub("([ #])", "\\%1"))
end

-- a command as a makefile's recipe line
local function make_recipe(cmd)
  return "\t" .. build.command_line(cmd):gsub("%$", "$$")
end

-- the obj directory, a source's object in it, and the makefile; relative to the
-- project if in it, as make runs in its directory
local function get_paths(target)
  local root = core.root_project().path
  local obj = core.root_project():absolute_path(target.obj or "obj")
  if common.path_belongs_to(obj, root) then obj = common.relative_path(root, obj) end
  local function object(file) return obj .. PATHSEP .. (target.name .. file):gsub("[/\\]+", "_") .. ".o" end
  return obj, object, obj .. PATHSEP .. target.name:gsub("[/\\]+", "_") .. ".mk"
end

-- Writes a makefile for the target, under its obj directory, and runs make
-- with it, which compiles in parallel what's out of date (with the headers
-- each source includes, from the compiler's -MMD) and links. Objects depend
-- on the makefile too, so changing flags rebuilds them.
function internal.build(target, callback)
  local files = get_source_files(target)
  if #files == 0 then error("can't find source files for project") end
  local has_cpp = false
  for i, v in ipairs(files) do if v:find("%.cpp$") or v:find("%.cc$") then has_cpp = true end end
  local obj, get_object, makefile = get_paths(target)
  local function absolute(path) return core.root_project():absolute_path(path) end
  common.mkdirp(absolute(obj))
  local binary = get_binary(target)
  local binary_folder = common.dirname(binary)
  if binary_folder then common.mkdirp(absolute(binary_folder)) end

  local objects, rules = {}, {}
  for i, file in ipairs(files) do
    local source = core.root_project():normalize_path(file)
    objects[i] = get_object(file)
    table.insert(rules, make_path(objects[i]) .. ": " .. make_path(source) .. " " .. make_path(makefile))
    table.insert(rules, make_recipe(table_concat(get_compiler(target, file), { "-fdiagnostics-color=always", "-MMD", "-MP", "-c", source, "-o", objects[i], table.unpack(get_compile_flags(target, file)) })))
    table.insert(rules, "-include " .. make_path(objects[i]:gsub("%.o$", ".d")))
  end
  local type = get_type(target)
  local linker = get_linker(target) or (has_cpp and split(get_field(target, nil, "cxx"), "%s+") or split(get_field(target, nil, "cc"), "%s+"))
  local link_job
  if type == "static" then
    link_job = { get_archiver(target), "-r", "-s", binary, table.unpack(objects) }
  else
    link_job = table_concat(linker, type == "shared" and { "-shared", "-o", binary } or { "-o", binary })
    for _, object in ipairs(objects) do table.insert(link_job, object) end
    for _, ldflag in ipairs(get_ldflags(target) or {}) do table.insert(link_job, ldflag) end
  end
  local prerequisites = {}
  for _, object in ipairs(objects) do table.insert(prerequisites, make_path(object)) end
  local text = table.concat({
    "# made by the build plugin's internal backend for target " .. target.name,
    make_path(binary) .. ": " .. table.concat(prerequisites, " ") .. " " .. make_path(makefile),
    make_recipe(link_job),
    table.concat(rules, "\n"),
    ""
  }, "\n")

  -- written only if it changed, as objects depend on it
  local f = io.open(absolute(makefile), "rb")
  local old = f and f:read("*a")
  if f then f:close() end
  if old ~= text then
    f = assert(io.open(absolute(makefile), "wb"))
    f:write(text)
    f:close()
  end
  build.run_command({ "make", "-f", makefile, "-j", tostring(build.threads) }, callback)
end


function internal.clean(target, callback)
  local _, get_object, makefile = get_paths(target)
  local function absolute(path) return core.root_project():absolute_path(path) end
  for i, v in ipairs(get_source_files(target)) do
    local object = absolute(get_object(v))
    os.remove((object:gsub("%.o$", ".d")))
    os.remove(object)
  end
  os.remove(absolute(makefile))
  os.remove(absolute(get_binary(target)))
  if callback then callback(0) end
end


return internal
