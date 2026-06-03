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

local function run(path, args, yielding)
  local command = { "git", "-C", path }
  for _, arg in ipairs(args) do
    command[#command + 1] = arg
  end

  local proc = process.start(command, {
    cwd = path,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_STDOUT,
  })
  if not proc then
    return "", -1
  end

  local chunks = {}
  while true do
    local chunk = proc:read_stdout()
    if chunk == nil then
      break
    end
    if chunk ~= "" then
      chunks[#chunks + 1] = chunk
    end
    if yielding then
      coroutine.yield(0)
    end
  end

  return table.concat(chunks), proc:wait(process.WAIT_INFINITE)
end

local function run_command(command, cwd, yielding)
  local proc = process.start(command, {
    cwd = cwd,
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_STDOUT,
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

local function split_lines(text)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
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

local function upstream_base(path, yielding)
  local output, code = run(path, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, yielding)
  if code ~= 0 or trim(output) == "" then return end
  local ref = trim(output)
  if rev_exists(path, ref, yielding) then
    local base = merge_base(path, ref, yielding)
    if base then return base, ref end
  end
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
  return join_path(USERDIR, "sivraj-remote-repos")
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
  local by_name, names = {}, {}
  for _, line in ipairs(split_lines(output)) do
    local name, url, kind = line:match("^(%S+)%s+(%S+)%s+%((%w+)%)")
    if name and url and kind == "fetch" and not by_name[name] then
      by_name[name] = url
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names, by_name
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

local function remote_ref_parts(ref)
  local remote, branch = tostring(ref or ""):match("^([^/]+)/(.+)$")
  if remote and branch and remote ~= "" and branch ~= "" then
    return remote, branch
  end
end

local function fetch_ref_history(path, ref, mode, yielding)
  local remote, branch = remote_ref_parts(ref)
  if not remote then return true end
  local args = { "fetch", mode, remote, branch }
  local _, code = run(path, args, yielding)
  return code == 0
end

local function ensure_merge_base(path, left, right, yielding)
  if not left or left == "" or not right or right == "" then return true end
  if merge_base_refs(path, left, right, yielding) then return true end
  for _ = 1, 4 do
    fetch_ref_history(path, left, "--deepen=50", yielding)
    fetch_ref_history(path, right, "--deepen=50", yielding)
    if merge_base_refs(path, left, right, yielding) then return true end
  end
  fetch_ref_history(path, left, "--unshallow", yielding)
  fetch_ref_history(path, right, "--unshallow", yielding)
  return merge_base_refs(path, left, right, yielding) ~= nil
end

local function worktree_ref(repo, wt)
  if wt.branch_name and wt.branch_name ~= "" then return tostring(repo.server) .. "/" .. wt.branch_name end
  return wt.head
end

local function local_worktree_path(repo, remote_path)
  if tostring(remote_path) == tostring(repo.remote_path) then return repo.cache_path end
  return M.remote_cache_path(repo.server, remote_path)
end

function M.sync_remote_repo(repo, yielding)
  repo.kind = "remote"
  repo.cache_path = repo.cache_path or M.remote_cache_path(repo.server, repo.remote_path)
  repo.path = repo.cache_path
  local ok, err = ensure_dir(common.dirname(repo.cache_path))
  if not ok then return false, err end

  if not system.get_file_info(join_path(repo.cache_path, ".git")) then
    local output, code = run_command({ "git", "clone", "--depth=1", "--no-single-branch", "--no-checkout",
      remote_source(repo), repo.cache_path }, common.dirname(repo.cache_path), yielding)
    if code ~= 0 then return false, output end
  end

  local output, code = remote_git(repo, { "remote", "-v" }, yielding)
  if code ~= 0 then return false, output end
  local names, urls = parse_remote_list(output)
  urls[tostring(repo.server)] = remote_source(repo)
  names[#names + 1] = tostring(repo.server)
  for _, name in ipairs(names) do
    local url = urls[name]
    if url then
      output, code = run(repo.cache_path, { "remote", "set-url", name, url }, yielding)
      if code ~= 0 then
        output, code = run(repo.cache_path, { "remote", "add", name, url }, yielding)
        if code ~= 0 then return false, output end
      end
      output, code = run(repo.cache_path, { "fetch", name }, yielding)
      if code ~= 0 then return false, output end
    end
  end

  output, code = remote_git(repo, { "for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads" }, yielding)
  if code ~= 0 then return false, output end
  local upstreams = parse_upstreams(output)
  output, code = remote_git(repo, { "worktree", "list", "--porcelain" }, yielding)
  if code ~= 0 then return false, output end

  local mapped = {}
  for _, wt in ipairs(M.parse_worktree_porcelain(output)) do
    if wt.path and not wt.bare and not wt.prunable then
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

  local existing = {}
  for _, wt in ipairs(M.worktrees(repo.cache_path)) do existing[wt.path] = true end
  for _, wt in ipairs(mapped) do
    local ref = worktree_ref(repo, wt)
    if not ensure_merge_base(repo.cache_path, ref, upstreams[wt.branch_name], yielding) then
      return false, "Could not fetch merge-base history for " .. tostring(ref) ..
        " and " .. tostring(upstreams[wt.branch_name])
    end
    if wt.path == repo.cache_path then
      for _, command in ipairs(M.remote_mirror_checkout_commands(wt.path, ref)) do
        output, code = run_command(command, wt.path, yielding)
        if code ~= 0 then return false, output end
      end
    elseif existing[wt.path] then
      for _, command in ipairs(M.remote_mirror_checkout_commands(wt.path, ref)) do
        output, code = run_command(command, wt.path, yielding)
        if code ~= 0 then return false, output end
      end
    else
      ok, err = ensure_dir(common.dirname(wt.path))
      if not ok then return false, err end
      output, code = run(repo.cache_path, M.remote_mirror_worktree_add_args(wt.path, ref), yielding)
      if code ~= 0 then return false, output end
    end
  end

  local agents_by_path = {}
  for _, wt in ipairs(repo.worktrees or {}) do agents_by_path[wt.path] = wt.agents end
  for _, wt in ipairs(mapped) do wt.agents = agents_by_path[wt.path] or {} end
  repo.worktrees = mapped
  repo.last_error = nil
  return true
end

function M.common_dir(path)
  local output, code = run(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if code ~= 0 then return end
  output = trim(output)
  return output ~= "" and output or nil
end

function M.current_branch(path)
  local output, code = run(path, { "rev-parse", "--abbrev-ref", "HEAD" })
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
  local output, code = run(path, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" }, yielding)
  local candidates = {}
  if code == 0 and trim(output) ~= "" then
    candidates[#candidates + 1] = trim(output)
  end
  for _, ref in ipairs({ "origin/main", "origin/develop", "origin/master", "main", "develop", "master" }) do
    candidates[#candidates + 1] = ref
  end

  for _, ref in ipairs(candidates) do
    if rev_exists(path, ref, yielding) then
      local base = merge_base(path, ref, yielding)
      if base then
        return base, ref
      end
    end
  end
end

function M.diff_against_parent(path, file, yielding)
  local parent, ref = M.parent_commit(path, yielding)
  if not parent then
    return nil, "No parent commit found"
  end

  local rel = common.relative_path(path, file)
  local output, code = run(path, {
    "diff", "--no-color", "--no-ext-diff", "--unified=3", "-M", "-C", parent, "--", rel
  }, yielding)
  if code ~= 0 then
    return nil, output
  end
  return output, nil, { parent = parent, ref = ref, path = rel }
end

function M.commit_for_file(path, file, yielding)
  local rel = common.relative_path(path, file)
  local output, code = run(path, { "status", "--porcelain", "--", rel }, yielding)
  if code == 0 and trim(output) ~= "" then
    return "uncommitted"
  end

  output, code = run(path, { "rev-parse", "HEAD" }, yielding)
  if code ~= 0 or trim(output) == "" then
    return "uncommitted"
  end
  return trim(output)
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

  local parent, ref = upstream_base(path, yielding)
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
