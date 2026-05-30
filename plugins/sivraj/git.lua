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

local function split_lines(text)
  local lines = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
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
