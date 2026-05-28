-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local agents = require "plugins.sivraj.agents"
local comments = require "plugins.sivraj.comments"
local file_treeview = require "plugins.sivraj.file_treeview"
local git = require "plugins.sivraj.git"
local git_doc_view = require "plugins.sivraj.git_doc_view"
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

local function load_state()
  local ok, state = pcall(dofile, state_filename)
  if not ok or type(state) ~= "table" or type(state.repos) ~= "table" then
    return {}, {}, nil
  end

  local loaded_repos = {}
  for _, repo in ipairs(state.repos) do
    if type(repo) == "table" and type(repo.path) == "string" then
      repo.worktrees = agents.sanitize_worktrees(type(repo.worktrees) == "table" and repo.worktrees or {})
      loaded_repos[#loaded_repos + 1] = repo
    end
  end
  return loaded_repos,
    type(state.expanded) == "table" and state.expanded or {},
    type(state.selected_worktree) == "string" and state.selected_worktree or nil
end

local repos, expanded, selected_worktree = load_state()

local function save_state()
  local fp = io.open(state_filename, "w")
  if fp then
    fp:write("return { repos = ", common.serialize(repos), ", expanded = ",
      common.serialize(expanded), ", selected_worktree = ", common.serialize(selected_worktree), " }\n")
    fp:close()
  end
end

local function refresh_worktrees(repo)
  repo.worktrees = agents.merge_worktrees(repo.worktrees, git.worktrees(repo.path))
end

for _, repo in ipairs(repos) do
  refresh_worktrees(repo)
end
if #repos > 0 then
  save_state()
end

local function open_project(path, opened)
  if core.project_dir == path then
    if opened then opened(path) end
    return
  end
  core.confirm_close_docs(core.docs, function(dirpath)
    core.open_folder_project(dirpath)
    if opened then opened(dirpath) end
  end, path)
end

local function select_worktree(path)
  open_project(path, function(opened_path)
    selected_worktree = opened_path
    save_state()
  end)
end

local function install_selection_handler(view)
  if view._sivraj_original_set_selection then
    view.set_selection = view._sivraj_original_set_selection
    view._sivraj_original_set_selection = nil
  end
  view.activate_on_single_click = true
end

local function worktree_id(repo, worktree)
  return repo.path .. ":" .. worktree.path
end

local function select_worktree_node(view, path)
  for _, repo in ipairs(repos) do
    for _, worktree in ipairs(repo.worktrees or {}) do
      if worktree.path == path then
        expanded[repo.path] = true
        view:set_selection_to_id(worktree_id(repo, worktree), false, true, true)
        core.redraw = true
        return
      end
    end
  end
end

local function worktree_children(repo)
  local children = {}
  for _, worktree in ipairs(repo.worktrees or {}) do
    children[#children + 1] = {
      id = worktree_id(repo, worktree),
      path = worktree.path,
      label = worktree.branch,
      kind = "worktree",
      tooltip = worktree.path,
      can_expand = function() return #(worktree.agents or {}) > 0 end,
      open_on_expand = true,
      is_expanded = function(node) return expanded[node.id] == true end,
      set_expanded = function(node, value)
        expanded[node.id] = not not value
        save_state()
      end,
      children = function() return agents.children(worktree) end,
      open = function(node) select_worktree(node.path) end,
    }
  end
  return children
end

local backend = {
  roots = function()
    local roots = {}
    for _, repo in ipairs(repos) do
      roots[#roots + 1] = {
        id = repo.path,
        path = repo.path,
        label = common.basename(repo.path),
        kind = "repo",
        tooltip = repo.path,
        is_expanded = function(node) return expanded[node.path] == true end,
        set_expanded = function(node, value)
          expanded[node.path] = not not value
          save_state()
        end,
        children = function() return worktree_children(repo) end,
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

local function has_repo(path)
  for _, repo in ipairs(repos) do
    if repo.path == path then
      return true
    end
  end
  return false
end

local function append_repo(path)
  if not has_repo(path) then
    local repo = { path = path, worktrees = {} }
    repos[#repos + 1] = repo
    expanded[path] = false
    return repo
  end
end

local function add_repo(path)
  local view = ensure_sidebar()
  local repo = append_repo(path)
  if repo then
    refresh_worktrees(repo)
    save_state()
  end
  view.visible = true
  core.redraw = true
end

local function add_scanned_repos(path)
  local found = {}
  local added = 0
  git.scan_repos(path, found)

  for _, repo_path in ipairs(found) do
    local repo = append_repo(repo_path)
    if repo then
      refresh_worktrees(repo)
      added = added + 1
    end
  end

  if added > 0 then
    save_state()
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
        if not git.is_repo(path) then
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

  ["sivraj:toggle-git-diff-overlay"] = function()
    git_doc_view.toggle()
  end,
})

git_doc_view.setup()
comments.setup()

agents.setup({
  repos = repos,
  open_project = open_project,
  save_state = save_state,
  set_selected_worktree = function(path)
    selected_worktree = path
    save_state()
  end,
  expand_worktree = function(worktree)
    for _, repo in ipairs(repos) do
      for _, repo_worktree in ipairs(repo.worktrees or {}) do
        if repo_worktree == worktree then expanded[worktree_id(repo, worktree)] = true end
      end
    end
  end,
})

local sidebar = ensure_sidebar()
local selected_info = selected_worktree and system.get_file_info(selected_worktree)
if selected_info and selected_info.type == "dir" then
  if core.project_dir ~= selected_worktree then
    core.open_folder_project(selected_worktree)
  end
  select_worktree_node(sidebar, selected_worktree)
end

file_treeview.setup()

return sidebar
