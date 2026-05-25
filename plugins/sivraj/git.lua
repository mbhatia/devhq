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

return M
