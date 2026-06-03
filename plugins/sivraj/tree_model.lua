-- mod-version:3

local M = {}

local function strip_trailing_separators(path)
  path = tostring(path or "")
  while #path > 1 and (path:sub(-1) == "/" or path:sub(-1) == "\\" or path:sub(-1) == PATHSEP) do
    path = path:sub(1, -2)
  end
  return path
end

local function basename(path)
  path = strip_trailing_separators(path)
  return path:match("([^/\\]+)$") or path
end

function M.repo_display_name(repo)
  local path = repo and repo.kind == "remote" and repo.remote_path or repo and repo.path
  local name = basename(path)
  return name ~= "" and name or "repo"
end

function M.repo_group_id(name)
  return "repo:" .. name
end

function M.repo_group_for_repo(repo)
  return M.repo_group_id(M.repo_display_name(repo))
end

function M.worktree_label(repo, worktree)
  if repo and repo.kind == "remote" then
    return "[" .. tostring(repo.server) .. "] " .. tostring(worktree.branch)
  end
  return worktree.branch
end

function M.worktree_id(repo, worktree)
  return repo.path .. ":" .. worktree.path
end

function M.build_repo_groups(repos)
  local groups, by_name = {}, {}
  for _, repo in ipairs(repos or {}) do
    local name = M.repo_display_name(repo)
    local group = by_name[name]
    if not group then
      group = { id = M.repo_group_id(name), name = name, repos = {}, order = #groups + 1 }
      by_name[name] = group
      groups[#groups + 1] = group
    end
    group.repos[#group.repos + 1] = repo
    if not group.local_repo and repo.kind ~= "remote" then
      group.local_repo = repo
    end
  end
  return groups
end

function M.worktree_children(repo, opts)
  opts = opts or {}
  local expanded = opts.expanded or {}
  local children = {}
  for _, worktree in ipairs(repo.worktrees or {}) do
    children[#children + 1] = {
      id = M.worktree_id(repo, worktree),
      path = worktree.path,
      label = M.worktree_label(repo, worktree),
      kind = "worktree",
      repo = repo,
      worktree = worktree,
      tooltip = repo.kind == "remote" and (worktree.remote_path .. " -> " .. worktree.path) or worktree.path,
      can_expand = function() return #(worktree.agents or {}) > 0 end,
      open_on_expand = true,
      is_expanded = function(node) return expanded[node.id] == true end,
      set_expanded = function(node, value)
        expanded[node.id] = not not value
        if opts.save_state then opts.save_state() end
      end,
      children = function()
        if opts.agent_children then return opts.agent_children(worktree) end
        return {}
      end,
      open = function(node)
        if opts.select_worktree then opts.select_worktree(node.path) end
      end,
    }
  end
  return children
end

function M.roots(repos, opts)
  opts = opts or {}
  local expanded = opts.expanded or {}
  local roots = {}
  for _, group in ipairs(M.build_repo_groups(repos)) do
    roots[#roots + 1] = {
      id = group.id,
      label = group.name,
      kind = "repo",
      repos = group.repos,
      repo = group.local_repo or group.repos[1],
      tooltip = group.name,
      order = group.order,
      is_expanded = function(node) return expanded[node.id] == true end,
      set_expanded = function(node, value)
        expanded[node.id] = not not value
        if opts.save_state then opts.save_state() end
      end,
      children = function()
        local children = {}
        for _, repo in ipairs(group.repos) do
          for _, child in ipairs(M.worktree_children(repo, opts)) do
            children[#children + 1] = child
          end
        end
        return children
      end,
    }
  end
  return roots
end

return M
