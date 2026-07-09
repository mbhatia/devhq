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
  local git = require "plugins.devhq.git"
  local commands = git.remote_mirror_checkout_commands("/cache/worktree", "dev226/develop")
  local checkout = commands[2]

  assert_equal(checkout[1], "git", "checkout command starts with git")
  assert_contains(checkout, "--detach", "remote mirror checkout must detach")
  assert_not_contains(checkout, "-B", "remote mirror checkout must not create or reset branch")
  assert_not_contains(checkout, "develop", "remote mirror checkout must not check out local branch name")
end

local function test_remote_mirror_worktree_add_uses_detached_checkout()
  local git = require "plugins.devhq.git"
  local args = git.remote_mirror_worktree_add_args("/cache/worktree", "dev226/develop")

  assert_equal(args[1], "worktree", "worktree add command starts with worktree")
  assert_equal(args[2], "add", "worktree add command uses add")
  assert_contains(args, "--detach", "remote mirror worktree add must detach")
  assert_not_contains(args, "-B", "remote mirror worktree add must not create branch")
  assert_not_contains(args, "develop", "remote mirror worktree add must not pass local branch name")
end

local function test_remote_mirror_clone_is_single_branch_and_shallow()
  local git = require "plugins.devhq.git"
  local args = git.remote_mirror_clone_args("dev226:/co/repo", "/cache/repo")

  assert_contains(args, "--depth=1", "remote mirror clone starts at depth one")
  assert_contains(args, "--no-tags", "remote mirror clone excludes tags")
  assert_contains(args, "--no-checkout", "remote mirror clone defers checkout")
  assert_not_contains(args, "--no-single-branch", "remote mirror clone must not fetch every branch")
end

local function test_remote_mirror_fetches_only_required_shallow_history()
  local git = require "plugins.devhq.git"
  local args = git.remote_mirror_fetch_args("dev226", "feature/x", 18)

  assert_contains(args, "--depth=18", "fetch is explicitly shallow")
  assert_contains(args, "--no-tags", "fetch excludes tag history")
  assert_contains(args, "dev226", "history is fetched only from the checkout server")
  assert_contains(args, "+refs/heads/feature/x:refs/remotes/dev226/feature/x",
    "fetch targets only the active branch")
  assert_not_contains(args, "--unshallow", "fetch must not unshallow the mirror")
end

local function test_remote_scalar_output_ignores_ssh_warnings()
  local git = require "plugins.devhq.git"
  local warning = "** WARNING: connection is not using a post-quantum key exchange algorithm.\n" ..
    "** This session may be vulnerable to store now, decrypt later attacks.\n"
  local oid = "44679e733eeac17b1a187cf4f33e7d0bdbeb98e5"

  assert_equal(git.parse_remote_oid(warning .. oid .. "\n"), oid,
    "remote OID parser ignores SSH diagnostics")
  assert_equal(git.parse_remote_count(warning .. "14\n"), 14,
    "remote count parser ignores SSH diagnostics")
  assert_equal(git.parse_remote_oid(warning), nil,
    "remote OID parser does not treat diagnostics as a result")
end

local function test_remote_mirror_parent_candidates_match_local_precedence()
  local git = require "plugins.devhq.git"
  local candidates = git.remote_mirror_parent_candidates("fork/topic", { "fork", "upstream" })

  assert_equal(candidates[1], "fork/topic", "tracking branch is preferred")
  assert_equal(candidates[2], "origin/main", "standard origin branches follow")
  assert_contains(candidates, "upstream/develop", "other remote defaults are considered")
  assert_contains(candidates, "master", "local default branches are considered last")
end

local function test_duplicate_local_remote_branch_grouping()
  local tree_model = require "plugins.devhq.tree_model"
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
      path = "/Users/manubhat/co/oss/devhq/devhq-remote-repos/dev226/co/nextunnel",
      worktrees = {
        {
          path = "/Users/manubhat/co/oss/devhq/devhq-remote-repos/dev226/co/nextunnel",
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
  test_remote_mirror_clone_is_single_branch_and_shallow,
  test_remote_mirror_fetches_only_required_shallow_history,
  test_remote_scalar_output_ignores_ssh_warnings,
  test_remote_mirror_parent_candidates_match_local_precedence,
  test_duplicate_local_remote_branch_grouping,
}

for _, test in ipairs(tests) do
  test()
end

print(string.format("ok %d tests", #tests))
