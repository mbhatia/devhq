-- mod-version:3

local process = require "process"

local M = {}

local function join_path(path, name)
  if path:sub(-1) == PATHSEP then
    return path .. name
  end
  return path .. PATHSEP .. name
end

local function run(path, args)
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
  end

  return table.concat(chunks), proc:wait(process.WAIT_INFINITE)
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

return M
