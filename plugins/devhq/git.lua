-- mod-version:3

local common = require "core.common"
local process = require "process"

local M = {}

local function join_path(path, name)
  if path:sub(-1) == PATHSEP then
    return path .. name
  end
  return path .. PATHSEP .. name
end

local function trim(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function git_path(path)
  if PATHSEP == "/" then return path end
  return (path:gsub("/", PATHSEP))
end

local function run_command(command, cwd, yielding, env)
  local proc = process.start(command, {
    cwd = cwd,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_STDOUT,
    env = env,
  })
  if not proc then
    return "", -1
  end

  local chunks = {}
  while true do
    local chunk = proc:read_stdout()
    if chunk == nil then break end
    if chunk ~= "" then chunks[#chunks + 1] = chunk end
    if yielding then coroutine.yield(0) end
  end
  return table.concat(chunks), proc:wait(process.WAIT_INFINITE)
end

local function run(path, args, yielding)
  local command = { "git", "-C", path }
  for _, arg in ipairs(args) do command[#command + 1] = arg end
  return run_command(command, path, yielding)
end

local function split_lines(text)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function matching_output_line(output, predicate)
  local lines = split_lines(output)
  for i = #lines, 1, -1 do
    local line = trim(lines[i])
    if predicate(line) then return line end
  end
end

function M.parse_remote_oid(output)
  return matching_output_line(output, function(line)
    return (line:len() == 40 or line:len() == 64) and line:match("^%x+$") ~= nil
  end)
end

function M.parse_remote_count(output)
  local line = matching_output_line(output, function(value)
    return value:match("^%d+$") ~= nil
  end)
  return line and tonumber(line) or nil
end

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function ssh_sh_command(server, script)
  return { "ssh", tostring(server), "/bin/sh -lc " .. shell_quote(script) }
end

local function safe_cache_part(part)
  if part == "." then return "_dot" end
  if part == ".." then return "_dotdot" end
  return (part:gsub(PATHSEP, "_"))
end

local function ensure_dir(path)
  if system.get_file_info(path) then return true end
  local ok, err, failed = common.mkdirp(path)
  if ok then return true end
  return false, string.format("Could not create %s: %s", failed or path, err or "unknown error")
end

local function ensure_file(result, rel)
  rel = git_path(rel)
  local file = result.files[rel]
  if not file then
    file = { path = rel, code = "M" }
    result.files[rel] = file
  end
  return file
end

local function mark_mode(result, mode, rel)
  result.modes[mode][git_path(rel)] = true
end

local function parse_numstat(result, output, mode)
  for _, line in ipairs(split_lines(output)) do
    local added, deleted, rel = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if rel then
      rel = rel:match(".+ %-> (.+)$") or rel
      local file = ensure_file(result, rel)
      if mode then
        file.stats = file.stats or {}
        file.stats[mode] = {
          added = added == "-" and nil or tonumber(added),
          deleted = deleted == "-" and nil or tonumber(deleted),
        }
        mark_mode(result, mode, rel)
      end
    end
  end
end

local function parse_status(result, output)
  for _, line in ipairs(split_lines(output)) do
    local xy, rel = line:sub(1, 2), line:sub(4)
    if rel ~= "" and xy ~= "!!" then
      rel = rel:match(".+ %-> (.+)$") or rel
      local x, y = xy:sub(1, 1), xy:sub(2, 2)
      local file = ensure_file(result, rel)
      file.staged = x ~= " " and x ~= "?"
      file.unstaged = y ~= " " or x == "?"
      file.code = x == "?" and "A" or (file.staged and x or y)
      if file.code == " " then file.code = "M" end
      file.codes = file.codes or {}
      file.codes.uncommitted = file.code
      if file.staged then file.codes.staged = x end
      mark_mode(result, "uncommitted", rel)
      if file.staged then mark_mode(result, "staged", rel) end
    end
  end
end

local function parse_name_status(result, output, mode)
  for _, line in ipairs(split_lines(output)) do
    local status, rel = line:match("^(%S+)%s+(.+)$")
    if rel then
      local file = ensure_file(result, rel)
      file.upstream = true
      file.codes = file.codes or {}
      file.codes[mode] = status:sub(1, 1)
      file.code = file.code or file.codes[mode]
      mark_mode(result, mode, rel)
    end
  end
end

local function first_parent(commit)
  return tostring(commit or "") .. "^"
end

local function normalize_diffstat_path(rel)
  local prefix, new_name, suffix = rel:match("^(.-)%{.- => (.-)%}(.*)$")
  if new_name then
    return prefix .. new_name .. suffix
  end
  return rel:match(".+ %-> (.+)$") or rel:match(".+ => (.+)$") or rel
end

local function parse_commit_numstat(files, output)
  for _, line in ipairs(split_lines(output)) do
    local added, deleted, rel = line:match("^(%S+)%s+(%S+)%s+(.+)$")
    if rel then
      rel = normalize_diffstat_path(rel)
      rel = git_path(rel)
      local file = files[rel]
      if file then
        file.added = added == "-" and nil or tonumber(added)
        file.deleted = deleted == "-" and nil or tonumber(deleted)
      end
    end
  end
end

local function parse_commit_status(output)
  local list, by_path = {}, {}
  for _, line in ipairs(split_lines(output)) do
    local status, rest = line:match("^(%S+)%s+(.+)$")
    if status and rest then
      local old_path, path = rest:match("^([^\t]+)\t(.+)$")
      if not path then path = rest end
      local item = {
        path = git_path(path),
        old_path = old_path and git_path(old_path) or nil,
        status = status:sub(1, 1),
        status_code = status,
      }
      list[#list + 1] = item
      by_path[item.path] = item
    end
  end
  return list, by_path
end

local function rev_exists(path, ref, yielding)
  local _, code = run(path, { "rev-parse", "--verify", ref .. "^{commit}" }, yielding)
  return code == 0
end

local function merge_base(path, ref, yielding)
  local output, code = run(path, { "merge-base", "HEAD", ref }, yielding)
  if code == 0 then
    output = trim(output)
    if output ~= "" then
      return output
    end
  end
end

local function merge_base_refs(path, left, right, yielding)
  local output, code = run(path, { "merge-base", left, right }, yielding)
  if code == 0 then
    output = trim(output)
    if output ~= "" then
      return output
    end
  end
end

local function configured_upstream_ref(path, yielding)
  local output, code = run(path, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, yielding)
  if code == 0 and trim(output) ~= "" then return trim(output) end
end

local function git_dir(path, yielding)
  local output, code = run(path, { "rev-parse", "--path-format=absolute", "--git-dir" }, yielding)
  if code ~= 0 or trim(output) == "" then return end
  return trim(output)
end

local function stored_review_refs(path, yielding)
  local dir = git_dir(path, yielding)
  if not dir then return end
  -- Detached remote mirrors have no branch upstream; sync stores it per worktree.
  local file = io.open(join_path(dir, "devhq-parent-ref"), "r")
  if not file then return end
  local parent = trim(file:read("*l") or "")
  local review = trim(file:read("*l") or "")
  file:close()
  return parent ~= "" and parent or nil, review ~= "" and review or nil
end

local function store_parent_ref(path, ref, yielding, review_ref)
  local dir = git_dir(path, yielding)
  if not dir then return end
  local file = io.open(join_path(dir, "devhq-parent-ref"), "w")
  if not file then return end
  file:write(trim(ref), "\n")
  if review_ref and trim(review_ref) ~= "" then file:write(trim(review_ref), "\n") end
  file:close()
end

function M.is_repo(path)
  local info = path and system.get_file_info(join_path(path, ".git"))
  return info and (info.type == "dir" or info.type == "file")
end

function M.scan_repos(path, found)
  if M.is_repo(path) then
    found[#found + 1] = path
    return
  end

  for _, name in ipairs(system.list_dir(path) or {}) do
    local child = join_path(path, name)
    local info = system.get_file_info(child)
    if info and info.type == "dir" then
      M.scan_repos(child, found)
    end
  end
end

function M.worktrees(path)
  local output, code = run(path, { "worktree", "list", "--porcelain" })
  if code ~= 0 then
    return {}
  end

  local list, current = {}, nil
  for line in output:gmatch("[^\r\n]+") do
    local worktree = line:match("^worktree (.+)$")
    if worktree then
      current = { path = worktree, branch = "HEAD" }
      list[#list + 1] = current
    elseif current then
      local branch = line:match("^branch refs/heads/(.+)$")
      if branch then
        current.branch = branch
      elseif line == "detached" then
        current.branch = "HEAD"
      end
    end
  end

  return list
end

function M.parse_worktree_porcelain(output)
  local list, current = {}, nil
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local worktree = line:match("^worktree (.+)$")
    if worktree then
      current = { path = worktree, branch = "HEAD" }
      list[#list + 1] = current
    elseif current then
      local head = line:match("^HEAD (.+)$")
      local branch = line:match("^branch refs/heads/(.+)$")
      if head then
        current.head = head
      elseif branch then
        current.branch = branch
        current.branch_name = branch
      elseif line == "detached" then
        current.branch = "HEAD"
        current.detached = true
      elseif line == "bare" then
        current.bare = true
      elseif line:match("^prunable") then
        current.prunable = true
      end
    end
  end
  return list
end

function M.parse_remote_spec(text)
  local server, remote_path = tostring(text or ""):match("^%s*([^:%s]+):(.+)%s*$")
  if not server or remote_path == "" then return end
  return server, remote_path
end

function M.remote_cache_root()
  return join_path(USERDIR, "devhq-remote-repos")
end

function M.remote_cache_path(server, remote_path)
  local path = join_path(M.remote_cache_root(), safe_cache_part(tostring(server or "repo")))
  local any = false
  for part in tostring(remote_path or ""):gmatch("[^/]+") do
    if part ~= "" then
      path = join_path(path, safe_cache_part(part))
      any = true
    end
  end
  if not any then path = join_path(path, "repo") end
  return path
end

local function remote_source(repo)
  return tostring(repo.server) .. ":" .. tostring(repo.remote_path)
end

local function remote_git(repo, args, yielding)
  local script = "git -C " .. shell_quote(repo.remote_path)
  for _, arg in ipairs(args) do script = script .. " " .. shell_quote(arg) end
  return run_command(ssh_sh_command(repo.server, script), nil, yielding)
end

local function parse_remote_list(output)
  local seen, names = {}, {}
  for _, line in ipairs(split_lines(output)) do
    local name, kind = line:match("^(%S+)%s+%S+%s+%((%w+)%)")
    if name and kind == "fetch" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

local function parse_upstreams(output)
  local upstreams = {}
  for _, line in ipairs(split_lines(output)) do
    local branch, upstream = line:match("^([^\t]+)\t(.+)$")
    if branch and branch ~= "" and upstream and upstream ~= "" then upstreams[branch] = upstream end
  end
  return upstreams
end

function M.remote_mirror_checkout_commands(path, ref)
  ref = ref or "HEAD"
  return {
    { "git", "-C", path, "clean", "-fd" },
    { "git", "-C", path, "checkout", "-f", "--detach", ref },
    { "git", "-C", path, "reset", "--hard", ref },
    { "git", "-C", path, "clean", "-fd" },
  }
end

function M.remote_mirror_worktree_add_args(path, ref)
  return { "worktree", "add", "--detach", path, ref or "HEAD" }
end

function M.remote_mirror_clone_args(source, path)
  return { "git", "clone", "--depth=1", "--no-tags", "--no-checkout", source, path }
end

local function remote_ref_parts(ref)
  local remote, branch = tostring(ref or ""):match("^([^/]+)/(.+)$")
  if remote and branch and remote ~= "" and branch ~= "" then
    return remote, branch
  end
end

local function remote_tracking_ref(remote, branch)
  return "refs/remotes/" .. tostring(remote) .. "/" .. tostring(branch)
end

function M.remote_mirror_fetch_args(server, branch, depth)
  return {
    "fetch", "--force", "--no-tags", "--depth=" .. tostring(math.max(1, depth or 1)),
    server, "+refs/heads/" .. branch .. ":" .. remote_tracking_ref(server, branch),
  }
end

local function fetch_ref_history(path, ref, source_ref, mode, yielding)
  local remote, branch = remote_ref_parts(ref)
  if not remote then return true end
  local args = { "fetch", mode, remote, source_ref or branch }
  local _, code = run(path, args, yielding)
  return code == 0
end

function M.ensure_review_merge_base(path, left, right, source_ref, yielding)
  if not left or left == "" or not right or right == "" then return true end
  if merge_base_refs(path, left, right, yielding) then return true end
  for _ = 1, 4 do
    fetch_ref_history(path, left, source_ref, "--deepen=50", yielding)
    fetch_ref_history(path, right, nil, "--deepen=50", yielding)
    if merge_base_refs(path, left, right, yielding) then return true end
  end
  fetch_ref_history(path, left, source_ref, "--unshallow", yielding)
  fetch_ref_history(path, right, nil, "--unshallow", yielding)
  return merge_base_refs(path, left, right, yielding) ~= nil
end

local parent_branches = { "main", "develop", "master" }

local function add_candidate(candidates, seen, ref)
  ref = trim(ref)
  if ref ~= "" and not seen[ref] then
    seen[ref] = true
    candidates[#candidates + 1] = ref
  end
end

local function add_remote_parent_candidates(candidates, seen, remote)
  if not remote or remote == "" then return end
  for _, branch in ipairs(parent_branches) do
    add_candidate(candidates, seen, remote .. "/" .. branch)
  end
end

local function remote_refs_pointing_at_head(path, yielding)
  local output, code = run(path, { "for-each-ref", "--format=%(refname:short)", "--points-at", "HEAD", "refs/remotes" }, yielding)
  if code ~= 0 then return {} end
  local refs = {}
  for _, ref in ipairs(split_lines(output)) do
    if ref ~= "" and not ref:match("/HEAD$") then refs[#refs + 1] = ref end
  end
  return refs
end

local function parent_ref_candidates(path, upstream, stored, head_refs, yielding)
  local candidates, seen = {}, {}
  add_candidate(candidates, seen, upstream)
  add_candidate(candidates, seen, stored)
  add_remote_parent_candidates(candidates, seen, "origin")
  for _, head_ref in ipairs(head_refs or remote_refs_pointing_at_head(path, yielding)) do
    local remote = remote_ref_parts(head_ref)
    add_remote_parent_candidates(candidates, seen, remote)
  end
  for _, branch in ipairs(parent_branches) do
    add_candidate(candidates, seen, branch)
  end
  return candidates
end

local function base_for_ref(path, ref, head_refs, review_ref, yielding)
  if not rev_exists(path, ref, yielding) then return end
  local base = merge_base(path, ref, yielding)
  if base then return base end
  for _, head_ref in ipairs(head_refs or {}) do
    if M.ensure_review_merge_base(path, head_ref, ref, review_ref, yielding) then
      base = merge_base(path, ref, yielding)
      if base then return base end
    end
  end
end

local function parent_base(path, yielding)
  local upstream = configured_upstream_ref(path, yielding)
  local stored, review_ref = stored_review_refs(path, yielding)
  local head_refs = remote_refs_pointing_at_head(path, yielding)
  for _, ref in ipairs(parent_ref_candidates(path, upstream, stored, head_refs, yielding)) do
    local base = base_for_ref(path, ref, head_refs, review_ref, yielding)
    if base then return base, ref end
  end
end

local function local_worktree_path(repo, remote_path)
  if tostring(remote_path) == tostring(repo.remote_path) then return repo.cache_path end
  return M.remote_cache_path(repo.server, remote_path)
end

function M.remote_mirror_parent_candidates(upstream, remote_names)
  local candidates, seen = {}, {}
  add_candidate(candidates, seen, tostring(upstream or ""))
  add_remote_parent_candidates(candidates, seen, "origin")
  for _, remote in ipairs(remote_names or {}) do
    add_remote_parent_candidates(candidates, seen, remote)
  end
  for _, branch in ipairs(parent_branches) do add_candidate(candidates, seen, branch) end
  return candidates
end

local function resolve_remote_histories(repo, worktrees, upstreams, remote_names, yielding)
  for _, wt in ipairs(worktrees) do
    local upstream = upstreams[wt.branch_name]
    wt.fetch_depth = 1
    for _, candidate in ipairs(M.remote_mirror_parent_candidates(upstream, remote_names)) do
      local output, code = remote_git(repo, { "merge-base", wt.head, candidate }, yielding)
      local merge_base = code == 0 and M.parse_remote_oid(output) or nil
      if merge_base then
        output, code = remote_git(repo,
          { "rev-list", "--count", merge_base .. ".." .. wt.head }, yielding)
        if code ~= 0 then return false, output end
        local distance = M.parse_remote_count(output)
        if not distance then
          return false, "Could not determine shallow history depth for " .. tostring(wt.remote_path)
        end
        wt.merge_base = merge_base
        wt.fetch_depth = distance + 1
        break
      end
    end
  end
  return true
end

local function configure_local_remote(path, name, url, yielding)
  local _, code = run(path, { "remote", "get-url", name }, yielding)
  local action = code == 0 and "set-url" or "add"
  local output
  output, code = run(path, { "remote", action, name, url }, yielding)
  return code == 0, output
end

local function remove_stale_worktrees(path, existing, wanted, yielding)
  for worktree_path in pairs(existing) do
    if worktree_path ~= path and not wanted[worktree_path] then
      local output, code = run(path, { "worktree", "remove", "--force", worktree_path }, yielding)
      if code ~= 0 then return false, output end
    end
  end
  local output, code = run(path, { "worktree", "prune" }, yielding)
  return code == 0, output
end

local function delete_refs(path, namespace, yielding)
  local output, code = run(path, { "for-each-ref", "--format=%(refname)", namespace }, yielding)
  if code ~= 0 then return false, output end
  for _, ref in ipairs(split_lines(output)) do
    output, code = run(path, { "update-ref", "-d", ref }, yielding)
    if code ~= 0 then return false, output end
  end
  return true
end

function M.sync_remote_repo(repo, yielding)
  repo.kind = "remote"
  repo.cache_path = repo.cache_path or M.remote_cache_path(repo.server, repo.remote_path)
  repo.path = repo.cache_path
  local ok, err = ensure_dir(common.dirname(repo.cache_path))
  if not ok then return false, err end

  if not system.get_file_info(join_path(repo.cache_path, ".git")) then
    local output, code = run_command(M.remote_mirror_clone_args(remote_source(repo), repo.cache_path),
      common.dirname(repo.cache_path), yielding)
    if code ~= 0 then return false, output end
  end

  local output, code = remote_git(repo, { "remote", "-v" }, yielding)
  if code ~= 0 then return false, output end
  local names = parse_remote_list(output)

  output, code = remote_git(repo, { "for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads" }, yielding)
  if code ~= 0 then return false, output end
  local upstreams = parse_upstreams(output)
  output, code = remote_git(repo, { "worktree", "list", "--porcelain" }, yielding)
  if code ~= 0 then return false, output end

  local mapped = {}
  for _, wt in ipairs(M.parse_worktree_porcelain(output)) do
    if wt.path and wt.branch_name and wt.branch_name ~= "" and not wt.bare and not wt.prunable then
      local remote_path = wt.path
      local cache_path = local_worktree_path(repo, remote_path)
      mapped[#mapped + 1] = {
        path = cache_path,
        cache_path = cache_path,
        remote_path = remote_path,
        branch = wt.branch,
        branch_name = wt.branch_name,
        head = wt.head,
      }
    end
  end

  ok, err = resolve_remote_histories(repo, mapped, upstreams, names, yielding)
  if not ok then return false, err end

  local server = tostring(repo.server)
  ok, err = configure_local_remote(repo.cache_path, server, remote_source(repo), yielding)
  if not ok then return false, err end

  -- Explicit fetch refspecs recreate only the active tracking refs.
  ok, err = delete_refs(repo.cache_path, "refs/remotes", yielding)
  if not ok then return false, err end

  local depths = {}
  for _, wt in ipairs(mapped) do
    depths[wt.branch_name] = math.max(depths[wt.branch_name] or 1, wt.fetch_depth)
  end
  for branch, depth in pairs(depths) do
    output, code = run(repo.cache_path,
      M.remote_mirror_fetch_args(repo.server, branch, depth), yielding)
    if code ~= 0 then return false, output end
  end

  local existing = {}
  for _, wt in ipairs(M.worktrees(repo.cache_path)) do existing[wt.path] = true end
  local wanted = {}
  for _, wt in ipairs(mapped) do wanted[wt.path] = true end
  ok, err = remove_stale_worktrees(repo.cache_path, existing, wanted, yielding)
  if not ok then return false, err end
  existing = {}
  for _, wt in ipairs(M.worktrees(repo.cache_path)) do existing[wt.path] = true end

  for _, wt in ipairs(mapped) do
    local ref = remote_tracking_ref(repo.server, wt.branch_name)
    local parent = wt.merge_base
    local local_head_output, local_head_code = run(repo.cache_path, { "rev-parse", "--verify", ref }, yielding)
    local local_head = local_head_code == 0 and trim(local_head_output) or ""
    if local_head ~= wt.head then
      return false, "Remote branch changed while syncing " .. tostring(wt.branch_name) .. "; retry sync"
    end
    if parent and merge_base_refs(repo.cache_path, ref, parent, yielding) ~= parent then
      return false, "Could not fetch shallow history through merge-base " .. tostring(parent) ..
        " for " .. tostring(ref)
    end
    if wt.path == repo.cache_path then
      for _, command in ipairs(M.remote_mirror_checkout_commands(wt.path, ref)) do
        output, code = run_command(command, wt.path, yielding)
        if code ~= 0 then return false, output end
      end
      store_parent_ref(wt.path, parent, yielding)
    elseif existing[wt.path] then
      for _, command in ipairs(M.remote_mirror_checkout_commands(wt.path, ref)) do
        output, code = run_command(command, wt.path, yielding)
        if code ~= 0 then return false, output end
      end
      store_parent_ref(wt.path, parent, yielding)
    else
      ok, err = ensure_dir(common.dirname(wt.path))
      if not ok then return false, err end
      output, code = run(repo.cache_path, M.remote_mirror_worktree_add_args(wt.path, ref), yielding)
      if code ~= 0 then return false, output end
      store_parent_ref(wt.path, parent, yielding)
    end
  end

  -- All mirror worktrees are detached. Drop clone-created branches and tags so
  -- only active shallow histories remain reachable.
  -- A bare remote repository has no main worktree to map onto the cache root;
  -- detach its local HEAD without materializing an extra checkout.
  if not wanted[repo.cache_path] and mapped[1] then
    output, code = run(repo.cache_path,
      { "update-ref", "--no-deref", "HEAD",
        remote_tracking_ref(repo.server, mapped[1].branch_name) }, yielding)
    if code ~= 0 then return false, output end
  end

  local namespaces = { "refs/tags", "refs/heads" }
  for _, namespace in ipairs(namespaces) do
    ok, err = delete_refs(repo.cache_path, namespace, yielding)
    if not ok then return false, err end
  end

  local agents_by_path = {}
  for _, wt in ipairs(repo.worktrees or {}) do agents_by_path[wt.path] = wt.agents end
  for _, wt in ipairs(mapped) do
    wt.fetch_depth = nil
    wt.merge_base = nil
    wt.agents = agents_by_path[wt.path] or {}
  end
  repo.worktrees = mapped
  repo.last_error = nil
  return true
end

function M.git_dir(path, yielding)
  return git_dir(path, yielding)
end

function M.github_cache_root()
  return join_path(USERDIR, "devhq-github-prs")
end

local function nested_cache_path(path, parts)
  for part in tostring(parts or ""):gmatch("[^/]+") do
    if part ~= "" then path = join_path(path, safe_cache_part(part)) end
  end
  return path
end

function M.github_cache_path(nwo)
  return nested_cache_path(M.github_cache_root(), nwo)
end

function M.gitlab_cache_path(nwo)
  return nested_cache_path(join_path(USERDIR, "devhq-gitlab-mrs"), nwo)
end

function M.gerrit_cache_path(host, project)
  local root = join_path(USERDIR, "devhq-gerrit-changes")
  host = tostring(host or "")
  return nested_cache_path(join_path(root, safe_cache_part(host ~= "" and host or "gerrit")), project)
end

M.shell_quote = shell_quote
M.run_command = run_command
M.store_parent_ref = store_parent_ref

function M.common_dir(path, yielding)
  local output, code = run(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, yielding)
  if code ~= 0 then return end
  output = trim(output)
  return output ~= "" and output or nil
end

function M.current_branch(path, yielding)
  local output, code = run(path, { "rev-parse", "--abbrev-ref", "HEAD" }, yielding)
  if code ~= 0 then return "HEAD" end
  output = trim(output)
  return output ~= "" and output or "HEAD"
end

function M.branch_exists(path, branch)
  local _, code = run(path, { "show-ref", "--verify", "--quiet", "refs/heads/" .. branch })
  return code == 0
end

function M.add_worktree(path, worktree_path, branch, base)
  local args = { "worktree", "add" }
  if base then
    table.move({ "-b", branch, worktree_path, base }, 1, 4, #args + 1, args)
  else
    table.move({ worktree_path, branch }, 1, 2, #args + 1, args)
  end
  local output, code = run(path, args)
  return code == 0, output
end

function M.remove_worktree(path, worktree_path)
  local output, code = run(path, { "worktree", "remove", worktree_path })
  return code == 0, output
end

function M.parent_commit(path, yielding)
  return parent_base(path, yielding)
end

function M.diff_against_parent(path, file, yielding, mode)
  local rel = common.relative_path(path, file)
  local args
  if mode == "staged" then
    args = { "diff", "--cached", "--no-color", "--no-ext-diff", "--unified=3", "-M", "-C", "--", rel }
  elseif mode == "uncommitted" then
    args = { "diff", "--no-color", "--no-ext-diff", "--unified=3", "-M", "-C", "HEAD", "--", rel }
  end
  if args then
    local output, code = run(path, args, yielding)
    return code == 0 and output or nil, code ~= 0 and output or nil
  end

  local parent, ref = M.parent_commit(path, yielding)
  if not parent then
    return nil, "No parent commit found"
  end

  args = { "diff", "--no-color", "--no-ext-diff", "--unified=3", "-M", "-C", parent }
  if mode == "head" then args[#args + 1] = "HEAD" end
  table.move({ "--", rel }, 1, 2, #args + 1, args)
  local output, code = run(path, args, yielding)
  if code ~= 0 then
    return nil, output
  end
  return output, nil, { parent = parent, ref = ref, path = rel }
end

function M.branch_history(path, yielding)
  local parent, ref = M.parent_commit(path, yielding)
  if not parent then
    return nil, "No upstream merge base found"
  end
  local output, code = run(path, {
    "log", "--date=short", "--format=%H%x1f%h%x1f%ad%x1f%an%x1f%s", parent .. "..HEAD"
  }, yielding)
  if code ~= 0 then return nil, output end
  local commits = {}
  for _, line in ipairs(split_lines(output)) do
    local hash, short_hash, date, author, subject = line:match("^([^\31]+)\31([^\31]+)\31([^\31]*)\31([^\31]*)\31(.*)$")
    if hash then
      commits[#commits + 1] = {
        hash = hash,
        short_hash = short_hash,
        date = date,
        author = author,
        subject = subject,
      }
    end
  end
  return commits, nil, { parent = parent, ref = ref }
end

function M.commit_files(path, commit, yielding)
  local output, code = run(path, {
    "diff", "--name-status", "-M", "-C", first_parent(commit), commit, "--"
  }, yielding)
  if code ~= 0 then return nil, output end
  local list, by_path = parse_commit_status(output)
  output, code = run(path, {
    "diff", "--numstat", "-M", "-C", first_parent(commit), commit, "--"
  }, yielding)
  if code == 0 then parse_commit_numstat(by_path, output) end
  return list
end

function M.commit_log(path, commit, yielding)
  local output, code = run(path, { "log", "-1", "--no-color", tostring(commit) }, yielding)
  if code ~= 0 then return nil, output end
  return output
end

function M.commit_file_content(path, commit, file, yielding)
  local rel = type(file) == "table" and file.path or file
  if not rel or rel == "" then return nil, "No file path" end
  local output, code = run(path, { "show", tostring(commit) .. ":" .. rel }, yielding)
  if code == 0 then return output end
  if type(file) == "table" and file.status == "D" then
    output, code = run(path, { "show", first_parent(commit) .. ":" .. (file.old_path or rel) }, yielding)
    if code == 0 then return output end
  end
  return nil, output
end

function M.diff_for_commit_file(path, commit, file, yielding)
  local rel = type(file) == "table" and file.path or file
  if not rel or rel == "" then return nil, "No file path" end
  local args = { "diff", "--no-color", "--no-ext-diff", "--unified=3", "-M", "-C",
    first_parent(commit), commit, "--" }
  if type(file) == "table" and file.old_path and file.old_path ~= rel then
    args[#args + 1] = file.old_path
  end
  args[#args + 1] = rel
  local output, code = run(path, args, yielding)
  if code ~= 0 then return nil, output end
  return output, nil, { parent = first_parent(commit), commit = commit, path = rel }
end

function M.head_commit(path, yielding)
  local output, code = run(path, { "rev-parse", "HEAD" }, yielding)
  if code ~= 0 or trim(output) == "" then return nil end
  return trim(output)
end

function M.file_at_commit(path, ref, rel, yielding)
  rel = git_path(rel)
  local output, code = run(path, { "show", tostring(ref) .. ":" .. rel }, yielding)
  if code ~= 0 then
    return nil, trim(output)
  end
  return output
end

function M.commit_for_file(path, file, yielding)
  local rel = common.relative_path(path, file)
  local output, code = run(path, { "status", "--porcelain", "--", rel }, yielding)
  if code == 0 and trim(output) ~= "" then
    return "uncommitted"
  end

  return M.head_commit(path, yielding) or "uncommitted"
end

function M.is_dirty(path, yielding)
  local output, code = run(path, { "status", "--porcelain=v1", "--untracked-files=all" }, yielding)
  if code ~= 0 then return nil, output end
  return trim(output) ~= ""
end

function M.tree_status(path, yielding)
  local result = {
    files = {},
    modes = {
      uncommitted = {},
      staged = {},
      head = {},
    },
  }

  local output, code = run(path, { "status", "--porcelain=v1", "--untracked-files=all" }, yielding)
  if code ~= 0 then
    return nil, output
  end
  parse_status(result, output)

  output, code = run(path, { "diff", "--numstat", "HEAD", "--" }, yielding)
  if code == 0 then parse_numstat(result, output, "uncommitted") end

  output, code = run(path, { "diff", "--cached", "--numstat", "--" }, yielding)
  if code == 0 then parse_numstat(result, output, "staged") end

  local parent, ref = parent_base(path, yielding)
  result.upstream_ref = ref
  if parent then
    output, code = run(path, { "diff", "--name-status", "--no-renames", parent, "HEAD", "--" }, yielding)
    if code == 0 then parse_name_status(result, output, "head") end
    output, code = run(path, { "diff", "--numstat", "--no-renames", parent, "HEAD", "--" }, yielding)
    if code == 0 then parse_numstat(result, output, "head") end
  end

  return result
end

return M
