PATHSEP = PATHSEP or "/"
USERDIR = USERDIR or "."

package.path = "./?.lua;" .. package.path

package.preload["process"] = function()
  return {}
end

package.preload["core.common"] = function()
  local M = {}

  function M.dirname(path)
    return tostring(path or ""):match("^(.*)[/\\][^/\\]+$") or "."
  end

  function M.mkdirp()
    return true
  end

  return M
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function assert_contains(list, value, message)
  for _, item in ipairs(list) do
    if item == value then return end
  end
  error((message or "missing value") .. ": " .. tostring(value), 2)
end

local function assert_not_contains(list, value, message)
  for _, item in ipairs(list) do
    if item == value then
      error((message or "unexpected value") .. ": " .. tostring(value), 2)
    end
  end
end

local function test_remote_mirror_uses_detached_checkout()
  local git = require "plugins.sivraj.git"
  local commands = git.remote_mirror_checkout_commands("/cache/worktree", "dev226/develop")
  local checkout = commands[2]

  assert_equal(checkout[1], "git", "checkout command starts with git")
  assert_contains(checkout, "--detach", "remote mirror checkout must detach")
  assert_not_contains(checkout, "-B", "remote mirror checkout must not create or reset branch")
  assert_not_contains(checkout, "develop", "remote mirror checkout must not check out local branch name")
end

local function test_remote_mirror_worktree_add_uses_detached_checkout()
  local git = require "plugins.sivraj.git"
  local args = git.remote_mirror_worktree_add_args("/cache/worktree", "dev226/develop")

  assert_equal(args[1], "worktree", "worktree add command starts with worktree")
  assert_equal(args[2], "add", "worktree add command uses add")
  assert_contains(args, "--detach", "remote mirror worktree add must detach")
  assert_not_contains(args, "-B", "remote mirror worktree add must not create branch")
  assert_not_contains(args, "develop", "remote mirror worktree add must not pass local branch name")
end

local function test_duplicate_local_remote_branch_grouping()
  local tree_model = require "plugins.sivraj.tree_model"
  local repos = {
    {
      path = "/Users/manubhat/co/nextunnel",
      worktrees = {
        { path = "/Users/manubhat/co/nextunnel", branch = "develop", agents = {} },
      },
    },
    {
      kind = "remote",
      server = "dev226",
      remote_path = "/co/nextunnel",
      path = "/Users/manubhat/co/oss/sivraj/sivraj-remote-repos/dev226/co/nextunnel",
      worktrees = {
        {
          path = "/Users/manubhat/co/oss/sivraj/sivraj-remote-repos/dev226/co/nextunnel",
          remote_path = "/co/nextunnel",
          branch = "develop",
          branch_name = "develop",
          agents = {},
        },
      },
    },
  }

  local roots = tree_model.roots(repos)
  assert_equal(#roots, 1, "duplicate local and remote repos should share one root")
  assert_equal(roots[1].label, "nextunnel", "shared repo root label")

  local children = roots[1].children()
  assert_equal(#children, 2, "shared repo root should contain both worktrees")
  assert_equal(children[1].label, "develop", "local worktree label")
  assert_equal(children[2].label, "[dev226] develop", "remote worktree label")
  if children[1].id == children[2].id then
    error("local and remote worktree ids must differ")
  end
end

local tests = {
  test_remote_mirror_uses_detached_checkout,
  test_remote_mirror_worktree_add_uses_detached_checkout,
  test_duplicate_local_remote_branch_grouping,
}

for _, test in ipairs(tests) do
  test()
end

print(string.format("ok %d tests", #tests))
