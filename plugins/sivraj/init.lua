-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local context_menu = require "plugins.contextmenu"
local MessageBox = require "libraries.widget.messagebox"
local agents = require "plugins.sivraj.agents"
local comments = require "plugins.sivraj.comments"
local file_treeview = require "plugins.sivraj.file_treeview"
local git = require "plugins.sivraj.git"
local git_doc_view = require "plugins.sivraj.git_doc_view"
local TreeView = require "libraries.generic_treeview"
local default_treeview = require "plugins.treeview"

local state_filename = USERDIR .. PATHSEP .. "sivraj.lua"

config.plugins.sivraj = common.merge({
  worktree_root = ".worktrees",
}, config.plugins.sivraj)

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
    if type(repo) == "table" and repo.kind == "remote" and type(repo.server) == "string"
      and type(repo.remote_path) == "string" then
      repo.cache_path = repo.cache_path or git.remote_cache_path(repo.server, repo.remote_path)
      repo.path = repo.cache_path
      repo.worktrees = agents.sanitize_worktrees(type(repo.worktrees) == "table" and repo.worktrees or {})
      loaded_repos[#loaded_repos + 1] = repo
    elseif type(repo) == "table" and type(repo.path) == "string" then
      repo.worktrees = agents.sanitize_worktrees(type(repo.worktrees) == "table" and repo.worktrees or {})
      loaded_repos[#loaded_repos + 1] = repo
    end
  end
  return loaded_repos,
    type(state.expanded) == "table" and state.expanded or {},
    type(state.selected_worktree) == "string" and state.selected_worktree or nil
end

local repos, expanded, selected_worktree = load_state()
local worktree_watch = {}

local function save_state()
  local fp = io.open(state_filename, "w")
  if fp then
    fp:write("return { repos = ", common.serialize(repos), ", expanded = ",
      common.serialize(expanded), ", selected_worktree = ", common.serialize(selected_worktree), " }\n")
    fp:close()
  end
end

local function refresh_worktrees(repo)
  if repo.kind == "remote" then
    return false
  end
  local old = common.serialize(repo.worktrees or {})
  repo.worktrees = agents.merge_worktrees(repo.worktrees, git.worktrees(repo.path))
  return old ~= common.serialize(repo.worktrees)
end

local function add_watch_path(snapshot, path)
  local info = system.get_file_info(path)
  if info then
    snapshot[path] = info.modified or 0
  end
end

local function repo_worktree_snapshot(common_dir)
  local snapshot = {}
  add_watch_path(snapshot, common_dir)
  add_watch_path(snapshot, common_dir .. PATHSEP .. "HEAD")

  local worktrees_dir = common_dir .. PATHSEP .. "worktrees"
  add_watch_path(snapshot, worktrees_dir)

  for _, name in ipairs(system.list_dir(worktrees_dir) or {}) do
    local path = worktrees_dir .. PATHSEP .. name
    local info = system.get_file_info(path)
    if info and info.type == "dir" then
      add_watch_path(snapshot, path)
      add_watch_path(snapshot, path .. PATHSEP .. "HEAD")
      add_watch_path(snapshot, path .. PATHSEP .. "gitdir")
    end
  end

  return snapshot
end

local function snapshots_equal(a, b)
  for path, value in pairs(a or {}) do
    if not b or b[path] ~= value then return false end
  end
  for path in pairs(b or {}) do
    if not a or a[path] == nil then return false end
  end
  return true
end

local function watch_repo_worktrees(repo)
  if repo.kind == "remote" and not system.get_file_info(repo.path) then return end
  local state = worktree_watch[repo.path]
  if not state then
    local common_dir = git.common_dir(repo.path)
    if not common_dir then return end
    state = { common_dir = common_dir }
    worktree_watch[repo.path] = state
  end
  state.snapshot = repo_worktree_snapshot(state.common_dir)
end

local function repo_worktrees_changed(repo)
  local state = worktree_watch[repo.path]
  if not state then
    watch_repo_worktrees(repo)
    return false
  end

  local snapshot = repo_worktree_snapshot(state.common_dir)
  local changed = not snapshots_equal(state.snapshot, snapshot)
  state.snapshot = snapshot
  return changed
end

local function watch_all_repo_worktrees()
  for _, repo in ipairs(repos) do
    watch_repo_worktrees(repo)
  end
end

local function refresh_all_worktrees()
  local changed = false
  for _, repo in ipairs(repos) do
    if repo_worktrees_changed(repo) then
      changed = refresh_worktrees(repo) or changed
      watch_repo_worktrees(repo)
    end
  end
  if changed then
    save_state()
    core.redraw = true
  end
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

local function join_path(path, name)
  if path:sub(-1) == PATHSEP then return path .. name end
  return path .. PATHSEP .. name
end

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function default_worktree_path(repo, branch)
  local root = config.plugins.sivraj.worktree_root
  if type(root) ~= "string" or root == "" then root = ".worktrees" end
  root = common.home_expand(root)
  if not common.is_absolute_path(root) then
    root = join_path(repo.path, root)
  end
  return join_path(root, branch)
end

local function finish_worktree_change(repo)
  refresh_worktrees(repo)
  save_state()
  watch_repo_worktrees(repo)
  core.redraw = true
end

local function sync_remote_repo(repo)
  if not repo or repo.kind ~= "remote" then return end
  core.add_thread(function()
    local ok, err = git.sync_remote_repo(repo, true)
    if not ok then
      repo.last_error = trim(err) ~= "" and trim(err) or "remote sync failed"
      core.error("Could not sync remote repo %s:%s: %s", repo.server, repo.remote_path, repo.last_error)
    end
    save_state()
    watch_repo_worktrees(repo)
    core.redraw = true
  end)
end

local function sync_all_remote_repos()
  for _, repo in ipairs(repos) do
    if repo.kind == "remote" then sync_remote_repo(repo) end
  end
end

local function create_worktree(repo, branch)
  if repo and repo.kind == "remote" then return core.error("Remote repos do not support local worktree creation") end
  branch = trim(branch)
  if branch == "" then return core.error("Branch name is required") end

  local path = default_worktree_path(repo, branch)
  local parent = common.dirname(path)
  if parent and not system.get_file_info(parent) then
    local ok, err, failed = common.mkdirp(parent)
    if not ok then return core.error("Could not create %s: %s", failed, err) end
  end

  local base = not git.branch_exists(repo.path, branch) and git.current_branch(repo.path) or nil
  local ok, output = git.add_worktree(repo.path, path, branch, base)
  if not ok then return core.error("Could not create worktree: %s", trim(output) ~= "" and trim(output) or "git failed") end
  expanded[repo.path] = true
  finish_worktree_change(repo)
end

local function prompt_create_worktree(repo)
  if not repo then return core.error("Select a repo in the Sivraj sidebar") end
  if repo.kind == "remote" then return core.error("Remote repos do not support local worktree creation") end
  core.command_view:enter("Branch Name", {
    submit = function(branch) create_worktree(repo, branch) end,
  })
end

local function remove_worktree(repo, worktree)
  if repo and repo.kind == "remote" then return core.error("Remote repos do not support local worktree deletion") end
  local ok, output = git.remove_worktree(repo.path, worktree.path)
  if not ok then
    local message = trim(output)
    MessageBox.error("Remove Worktree Failed", message ~= "" and message or "git worktree remove failed")
    return
  end
  if selected_worktree == worktree.path then selected_worktree = nil end
  finish_worktree_change(repo)
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
      repo = repo,
      worktree = worktree,
      tooltip = repo.kind == "remote" and (worktree.remote_path .. " -> " .. worktree.path) or worktree.path,
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
        label = repo.kind == "remote" and (repo.server .. ":" .. repo.remote_path) or common.basename(repo.path),
        kind = "repo",
        repo = repo,
        tooltip = repo.kind == "remote" and repo.path .. " (local mirror)" or repo.path,
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

local context_item

local function item_at(view, x, y)
  for item, ix, iy, iw, ih in view:each_item() do
    if x > ix and y > iy and x <= ix + iw and y <= iy + ih then
      return item, iy
    end
  end
end

local function selected_repo()
  local view = find_sidebar()
  local item = view and view.selected_item
  local node = item and item.node
  if node and node.kind == "repo" then return node.repo end
  if node and node.kind == "worktree" then return node.repo end
  if #repos == 1 then return repos[1] end
end

local function context_node(kind)
  return function(x, y)
    local view = core.active_view
    if not (view and view._sivraj_treeview) then return false end
    local item, item_y = item_at(view, x, y)
    local node = item and item.node
    if not (node and node.kind == kind) then return false end
    context_item = item
    view:set_selection(item, item_y)
    return true
  end
end

context_menu:register(context_node("repo"), {
  { text = "Create Worktree", command = "sivraj:create-worktree" },
})

context_menu:register(context_node("worktree"), {
  { text = "Delete Worktree", command = "sivraj:delete-worktree" },
})

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

local function has_remote_repo(server, remote_path)
  for _, repo in ipairs(repos) do
    if repo.kind == "remote" and repo.server == server and repo.remote_path == remote_path then
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

local function append_remote_repo(server, remote_path)
  if not has_remote_repo(server, remote_path) then
    local cache_path = git.remote_cache_path(server, remote_path)
    local repo = {
      kind = "remote",
      server = server,
      remote_path = remote_path,
      cache_path = cache_path,
      path = cache_path,
      worktrees = {},
    }
    repos[#repos + 1] = repo
    expanded[cache_path] = false
    return repo
  end
end

local function add_repo(path)
  local view = ensure_sidebar()
  local repo = append_repo(path)
  if repo then
    refresh_worktrees(repo)
    save_state()
    watch_repo_worktrees(repo)
  end
  view.visible = true
  core.redraw = true
end

local function add_remote_repo(spec)
  local server, remote_path = git.parse_remote_spec(spec)
  if not server then return core.error("Remote repo must be formatted as server:/path/to/repo") end
  local view = ensure_sidebar()
  local repo = append_remote_repo(server, remote_path)
  if repo then
    save_state()
    sync_remote_repo(repo)
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
      watch_repo_worktrees(repo)
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

  ["sivraj:open-remote-repo"] = function()
    core.command_view:enter("Open Remote Repo", {
      submit = add_remote_repo,
      validate = function(text)
        local server, remote_path = git.parse_remote_spec(text)
        if not server then
          core.error("Remote repo must be formatted as server:/path/to/repo")
          return false
        end
        return remote_path ~= ""
      end,
    })
  end,

  ["sivraj:sync-remote-repos"] = function()
    sync_all_remote_repos()
  end,

  ["sivraj:create-worktree"] = function()
    prompt_create_worktree(selected_repo())
  end,

  ["sivraj:delete-worktree"] = function()
    local view = find_sidebar()
    local item = context_menu.show_context_menu and context_item or (view and view.selected_item)
    local node = item and item.node
    if not (node and node.kind == "worktree") then
      return core.error("Select a worktree in the Sivraj sidebar")
    end
    if node.repo and node.repo.kind == "remote" then
      return core.error("Remote repos do not support local worktree deletion")
    end
    remove_worktree(node.repo, node.worktree)
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
watch_all_repo_worktrees()
core.add_thread(function()
  while true do
    refresh_all_worktrees()
    coroutine.yield(1)
  end
end)

local selected_info = selected_worktree and system.get_file_info(selected_worktree)
if selected_info and selected_info.type == "dir" then
  if core.project_dir ~= selected_worktree then
    core.open_folder_project(selected_worktree)
  end
  select_worktree_node(sidebar, selected_worktree)
end

file_treeview.setup()

return sidebar
