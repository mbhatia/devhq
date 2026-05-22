-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local TreeView = require "libraries.generic_treeview"
local default_treeview = require "plugins.treeview"

local state_filename = USERDIR .. PATHSEP .. "sivraj.lua"

local function find_sidebar()
  for _, loaded_view in ipairs(core.root_view.root_node:get_children()) do
    if loaded_view._sivraj_treeview then
      return loaded_view
    end
  end
end

local function join_path(path, name)
  if path:sub(-1) == PATHSEP then
    return path .. name
  end
  return path .. PATHSEP .. name
end

local function load_repos()
  local ok, state = pcall(dofile, state_filename)
  if not ok or type(state) ~= "table" or type(state.repos) ~= "table" then
    return {}
  end

  local loaded_repos = {}
  for _, repo_path in ipairs(state.repos) do
    if type(repo_path) == "string" then
      loaded_repos[#loaded_repos + 1] = repo_path
    end
  end
  return loaded_repos
end

local repos = load_repos()

local function save_repos()
  local fp = io.open(state_filename, "w")
  if fp then
    fp:write("return { repos = ", common.serialize(repos), " }\n")
    fp:close()
  end
end

local function select_repo(path)
  if core.project_dir == path then
    return
  end
  core.confirm_close_docs(core.docs, function(dirpath)
    core.open_folder_project(dirpath)
  end, path)
end

local function install_selection_handler(view)
  view.activate_on_single_click = false
  if view._sivraj_original_set_selection then
    return
  end
  view._sivraj_original_set_selection = view.set_selection
  function view:set_selection(selection, selection_y, center, instant)
    self:_sivraj_original_set_selection(selection, selection_y, center, instant)
    local node = selection and selection.node
    if node and node.path then
      select_repo(node.path)
    end
  end
end

local backend = {
  roots = function()
    local roots = {}
    for _, repo_path in ipairs(repos) do
      roots[#roots + 1] = {
        id = repo_path,
        path = repo_path,
        label = common.basename(repo_path),
        kind = "repo",
        tooltip = repo_path,
      }
    end
    return roots
  end,
}

local function ensure_sidebar()
  local view = find_sidebar()
  if view then
    view:set_backend(backend)
    install_selection_handler(view)
    return view
  end

  local node = core.root_view.root_node:get_node_for_view(default_treeview)
  view = TreeView({
    backend = backend,
  })
  view._sivraj_treeview = true
  install_selection_handler(view)
  view.node = node:split("left", view, { x = true }, true)
  return view
end

local function repo_path_from_text(text)
  local path = common.home_expand(text)
  path = system.absolute_path(path)
  return common.normalize_volume(path)
end

local function is_git_repo(path)
  local info = path and system.get_file_info(join_path(path, ".git"))
  return info and (info.type == "dir" or info.type == "file")
end

local function has_repo(path)
  for _, repo_path in ipairs(repos) do
    if repo_path == path then
      return true
    end
  end
  return false
end

local function append_repo(path)
  if not has_repo(path) then
    repos[#repos + 1] = path
    return true
  end
  return false
end

local function add_repo(path)
  local view = ensure_sidebar()
  if append_repo(path) then
    save_repos()
  end
  view.visible = true
  core.redraw = true
end

local function scan_git_repos(path, found)
  if is_git_repo(path) then
    found[#found + 1] = path
    return
  end

  for _, name in ipairs(system.list_dir(path) or {}) do
    local child = join_path(path, name)
    local info = system.get_file_info(child)
    if info and info.type == "dir" then
      scan_git_repos(child, found)
    end
  end
end

local function add_scanned_repos(path)
  local found = {}
  local added = 0
  scan_git_repos(path, found)

  for _, repo_path in ipairs(found) do
    if append_repo(repo_path) then
      added = added + 1
    end
  end

  if added > 0 then
    save_repos()
    ensure_sidebar().visible = true
    core.redraw = true
  end
end

local function suggest_repo_path(text)
  return common.home_encode_list(common.dir_path_suggest(common.home_expand(text)))
end

command.add(nil, {
  ["sivraj:toggle-sidebar"] = function()
    local view = find_sidebar()
    if view then
      view.visible = not view.visible
    else
      ensure_sidebar().visible = true
    end
    core.redraw = true
  end,

  ["sivraj:open-repo"] = function()
    core.command_view:enter("Open Repo", {
      text = "~" .. PATHSEP,
      submit = function(text)
        add_repo(repo_path_from_text(text))
      end,
      suggest = suggest_repo_path,
      validate = function(text)
        local path = repo_path_from_text(text)
        local info = path and system.get_file_info(path)
        if not info or info.type ~= "dir" then
          core.error("Not a directory: %s", text)
          return false
        end
        if not is_git_repo(path) then
          core.error("Not a git repo: %s", text)
          return false
        end
        return true
      end,
    })
  end,

  ["sivraj:scan-all-repos"] = function()
    core.command_view:enter("Scan Repos", {
      text = "~" .. PATHSEP,
      submit = function(text)
        add_scanned_repos(repo_path_from_text(text))
      end,
      suggest = suggest_repo_path,
      validate = function(text)
        local path = repo_path_from_text(text)
        local info = path and system.get_file_info(path)
        if not info or info.type ~= "dir" then
          core.error("Not a directory: %s", text)
          return false
        end
        return true
      end,
    })
  end,
})

return ensure_sidebar()
