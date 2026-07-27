PATHSEP = PATHSEP or "/"
USERDIR = USERDIR or "."
SCALE = SCALE or 1

package.path = "./?.lua;" .. package.path

package.preload["core"] = function()
  return {}
end

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

package.preload["core.style"] = function()
  local font = {
    get_height = function() return 12 end,
    get_width = function(_, text) return #tostring(text or "") end,
  }
  return {
    font = font,
    icon_font = font,
    padding = { x = 1, y = 1 },
  }
end

package.preload["core.view"] = function()
  local View = {}

  function View:extend()
    local child = { super = self }
    child.__index = child
    return setmetatable(child, { __index = self })
  end

  return View
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

local function tree_view(roots, default_expanded)
  local TreeView = require "libraries.generic_treeview"
  return setmetatable({
    backend = { roots = function() return roots end },
    expanded = {},
    default_expanded = default_expanded,
    size = { x = 100, y = 100 },
    get_content_offset = function() return 0, 0 end,
  }, { __index = TreeView })
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

local function test_treeview_compacts_single_child_container_chains()
  local files = {
    { id = "one", label = "one.txt", kind = "file", order = 1 },
    { id = "two", label = "two.txt", kind = "file", order = 2 },
  }
  local folder2 = { id = "folder2", label = "folder2", kind = "bucket", children = files }
  local folder1 = { id = "folder1", label = "folder1", kind = "group", children = { folder2 } }
  local workspace = { id = "workspace", label = "workspace", kind = "workspace", children = { folder1 } }
  local view = tree_view({ workspace }, true)

  local rows = view:rows()
  assert_equal(#rows, 3, "compacted chain and its two leaves should produce three rows")
  assert_equal(view:get_item_label(rows[1]), "workspace/folder1/folder2", "compacted row label")
  assert_equal(rows[1].node, folder2, "compacted row acts on the innermost container")
  assert_equal(rows[2].depth, 1, "children remain one level below the compacted row")
  assert_equal(rows[3].depth, 1, "all compacted-row children have the same depth")
  assert_equal(view:item_has_id(rows[1], "workspace"), true, "compacted row retains the root id")
  assert_equal(view:item_has_id(rows[1], "folder1"), true, "compacted row retains intermediate ids")
  assert_equal(view:item_has_id(rows[1], "folder2"), true, "compacted row retains the innermost id")
end

local function test_treeview_does_not_compact_a_leaf_child()
  local leaf = { id = "leaf", label = "leaf", kind = "record" }
  local container = { id = "container", label = "container", kind = "section", children = { leaf } }
  local view = tree_view({ container }, true)

  local rows = view:rows()
  assert_equal(#rows, 2, "a container and its leaf remain separate rows")
  assert_equal(view:get_item_label(rows[1]), "container", "leaf child is not folded into its parent")
  assert_equal(view:get_item_label(rows[2]), "leaf", "leaf keeps its own row")
end

local function test_treeview_does_not_compact_branched_containers()
  local left = { id = "left", label = "left", kind = "section", children = {} }
  local right = { id = "right", label = "right", kind = "section", children = {} }
  local root = {
    id = "root",
    label = "root",
    kind = "section",
    children = { left, right },
  }
  local view = tree_view({ root }, true)

  local rows = view:rows()
  assert_equal(#rows, 3, "a branched parent and both children keep separate rows")
  assert_equal(view:get_item_label(rows[1]), "root", "branched parent is not compacted")
end

local function test_treeview_selection_follows_a_newly_compacted_row()
  local leaf = { id = "leaf", label = "leaf", kind = "record" }
  local child = { id = "child", label = "child", kind = "section", children = { leaf } }
  local root = { id = "root", label = "root", kind = "section", children = { child } }
  local view = tree_view({ root }, false)

  view.selected_item = view:rows()[1]
  view.selected_id = "root"
  view:toggle_expand(true)

  assert_equal(view:get_item_label(view.selected_item), "root/child",
    "selection follows the compacted row after expanding its parent")
  assert_equal(view.selected_item.node, child, "the next expansion acts on the visible child container")
end

local tests = {
  test_remote_mirror_uses_detached_checkout,
  test_remote_mirror_worktree_add_uses_detached_checkout,
  test_remote_mirror_clone_is_single_branch_and_shallow,
  test_remote_mirror_fetches_only_required_shallow_history,
  test_remote_scalar_output_ignores_ssh_warnings,
  test_remote_mirror_parent_candidates_match_local_precedence,
  test_duplicate_local_remote_branch_grouping,
  test_treeview_compacts_single_child_container_chains,
  test_treeview_does_not_compact_a_leaf_child,
  test_treeview_does_not_compact_branched_containers,
  test_treeview_selection_follows_a_newly_compacted_row,
}

for _, test in ipairs(tests) do
  test()
end

print(string.format("ok %d tests", #tests))
