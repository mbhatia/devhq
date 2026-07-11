PATHSEP = PATHSEP or "/"
USERDIR = USERDIR or "."

package.path = "./?.lua;" .. package.path

local process_handler
package.preload["process"] = function()
  local M = { REDIRECT_PIPE = 1, REDIRECT_STDOUT = 2, WAIT_INFINITE = -1 }
  function M.start(command, options)
    if not process_handler then return end
    local output, code = process_handler(command, options)
    local unread = true
    return {
      read_stdout = function()
        if not unread then return nil end
        unread = false; return output or ""
      end,
      wait = function() return code or 0 end,
    }
  end
  return M
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

package.preload["core"] = function() return { add_thread = function() end } end
package.preload["core.command"] = function() return { add = function() end } end
package.preload["core.config"] = function() return { plugins = { devhq = {} } } end

local decoded = {}
package.preload["plugins.devhq.comments"] = function()
  return {
    decode = function(text) return decoded[text] end,
    encode = function() return "{}" end,
  }
end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function assert_contains(list, value, message)
  for _, item in ipairs(list) do if item == value then return end end
  error((message or "missing value") .. ": " .. tostring(value), 2)
end

local function assert_not_contains(list, value, message)
  for _, item in ipairs(list) do if item == value then
    error((message or "unexpected value") .. ": " .. tostring(value), 2)
  end end
end

local function assert_contains_all(list, values, message)
  for _, value in ipairs(values) do assert_contains(list, value, message) end
end

local function test_remote_mirror_command_shapes()
  local git = require "plugins.devhq.git"
  local checkout = git.remote_mirror_checkout_commands("/cache/worktree", "dev226/develop")[2]
  assert_equal(checkout[1], "git"); assert_contains(checkout, "--detach")
  assert_not_contains(checkout, "-B"); assert_not_contains(checkout, "develop")

  local args = git.remote_mirror_worktree_add_args("/cache/worktree", "dev226/develop")
  assert_equal(args[1], "worktree"); assert_equal(args[2], "add"); assert_contains(args, "--detach")
  assert_not_contains(args, "-B"); assert_not_contains(args, "develop")

  args = git.remote_mirror_clone_args("dev226:/co/repo", "/cache/repo")
  assert_contains_all(args, { "--depth=1", "--no-tags", "--no-checkout" }, "shallow clone arg")
  assert_not_contains(args, "--no-single-branch", "remote mirror clone must not fetch every branch")

  args = git.remote_mirror_fetch_args("dev226", "feature/x", 18)
  assert_contains_all(args, { "--depth=18", "--no-tags", "dev226",
    "+refs/heads/feature/x:refs/remotes/dev226/feature/x" }, "shallow fetch arg")
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

  assert_equal(candidates[1], "fork/topic"); assert_equal(candidates[2], "origin/main")
  assert_contains(candidates, "upstream/develop"); assert_contains(candidates, "master")
end

local function test_review_merge_base_deepens_provider_ref()
  local git = require "plugins.devhq.git"
  for _, case in ipairs({
    { "GitHub", "origin/pr/16", "refs/pull/16/head" },
    { "GitLab", "origin/mr/42", "refs/merge-requests/42/head" },
    { "Gerrit", "origin/change/403216", "refs/changes/16/403216/19" },
  }) do
    local commands, merge_attempts = {}, 0
    process_handler = function(command)
      commands[#commands + 1] = command
      if command[4] == "merge-base" then
        merge_attempts = merge_attempts + 1
        if merge_attempts < 3 then return "", 1 end
        return "base-commit\n", 0
      end
      return "", 0
    end
    local found = git.ensure_review_merge_base("/cache/repo", case[2], "origin/main", case[3], false)
    process_handler = nil
    assert_equal(found, true, case[1]); assert_equal(merge_attempts, 3, case[1])
    assert_equal(#commands, 7, case[1])
    for _, index in ipairs({ 2, 5 }) do
      assert_equal(commands[index][4], "fetch"); assert_contains(commands[index], "--deepen=50")
      assert_equal(commands[index][6], "origin"); assert_equal(commands[index][7], case[3])
      assert_not_contains(commands[index], case[2]:match("^origin/(.+)$"),
        case[1] .. " does not fetch the synthetic local review branch")
    end
  end
end

local function test_duplicate_local_remote_branch_grouping()
  local tree_model = require "plugins.devhq.tree_model"
  local repos = {
    { path = "/co/nextunnel", worktrees = {
      { path = "/co/nextunnel", branch = "develop", agents = {} },
    } },
    { kind = "remote", server = "dev226", remote_path = "/co/nextunnel",
      path = "/cache/nextunnel", worktrees = {
        { path = "/cache/nextunnel", remote_path = "/co/nextunnel",
          branch = "develop", branch_name = "develop", agents = {} },
      } },
  }

  local roots = tree_model.roots(repos)
  assert_equal(#roots, 1); assert_equal(roots[1].label, "nextunnel")

  local children = roots[1].children()
  assert_equal(#children, 2); assert_equal(children[1].label, "develop")
  assert_equal(children[2].label, "[dev226] develop")
  if children[1].id == children[2].id then
    error("local and remote worktree ids must differ")
  end
end

local function test_forge_labels()
  local tree_model = require "plugins.devhq.tree_model"
  for _, case in ipairs({
    { "github", "owner/repo", 16, "chore/license", "[gh] owner/repo", "[gh#16] chore/license" },
    { "gitlab", "group/project", 42, "feature/x", "[gl] group/project", "[gl!42] feature/x" },
    { "gerrit", "tools/gerrit", 1234, "main", "[gerrit] tools/gerrit", "[gerrit#1234] main" },
  }) do
    local repo = { kind = case[1], nwo = case[2] }
    local worktree = { pr_number = case[3], branch = case[4] }
    assert_equal(tree_model.repo_display_name(repo), case[5], case[1])
    assert_equal(tree_model.worktree_label(repo, worktree), case[6], case[1])
  end
end

local function test_github_api_comment_args()
  local forge = require "plugins.devhq.forge"
  local thread = { file = "src/a.lua", range = { start = { line = 3, col = 1 }, ["end"] = { line = 5, col = 2 } } }
  local args = forge.api_comment_args("owner/repo", 16, thread, "abc123", "hello")
  assert_equal(args[1], "api"); assert_equal(args[2], "repos/owner/repo/pulls/16/comments")
  assert_contains_all(args, { "body=hello", "path=src/a.lua", "commit_id=abc123",
    "line=5", "start_line=3", "side=RIGHT" }, "GitHub comment arg")
end

local function test_failed_details_retain_previous_reviews()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_run_command = git.run_command
  local github_old = {
    pr_number = 16, branch = "old-branch", head = "old-head", base = "main",
  }
  local gitlab_old = {
    pr_number = 42, branch = "old-mr", head = "old-mr-head", base = "main",
    project_id = 99, diff_refs = { base_sha = "b", start_sha = "s", head_sha = "h" },
  }

  do
    decoded.github_search = {
      { number = 16, repository = { nameWithOwner = "owner/repo" } },
    }
    git.run_command = function(command)
      if command[2] == "search" then return "github_search", 0 end
      return "detail failed", 1
    end
    local github_groups, github_complete = forge.scan_provider("github", false, function()
      return github_old
    end)
    local github_change = github_groups["owner/repo"].changes[1]
    assert_equal(github_change.head, "old-head", "failed GitHub detail retains old head")
    assert_equal(github_change.branch, "old-branch", "failed GitHub detail retains old branch")
    assert_equal(github_complete, false, "failed GitHub detail makes scan incomplete")

    decoded.gitlab_user = { id = 7 }
    decoded.gitlab_search = {
      { iid = 42, project_id = 99, sha = "new-mr-head", source_branch = "new-mr",
        target_branch = "main", references = { full = "group/project!42" } },
    }
    git.run_command = function(command)
      local endpoint = command[3]
      if endpoint == "user" then return "gitlab_user", 0 end
      if endpoint and endpoint:match("^merge_requests%?") then return "gitlab_search", 0 end
      return "detail failed", 1
    end
    local gitlab_groups, gitlab_complete = forge.scan_provider("gitlab", false, function()
      return gitlab_old
    end)
    local gitlab_change = gitlab_groups["group/project"].changes[1]
    assert_equal(gitlab_change.head, "old-mr-head", "failed GitLab detail retains old head")
    assert_equal(gitlab_change.extra.diff_refs, gitlab_old.diff_refs,
      "failed GitLab detail retains old diff refs")
    assert_equal(gitlab_complete, false, "failed GitLab detail makes scan incomplete")
  end

  git.run_command = old_run_command
end

local function test_scan_completeness_ignores_valid_duplicates()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_run_command = git.run_command
  do
    local gh_record = { number = 16, repository = { nameWithOwner = "owner/repo" } }
    decoded.gh_duplicates = { gh_record, gh_record }
    decoded.gh_detail = { number = 16, headRefName = "topic", headRefOid = "head", baseRefName = "main" }
    git.run_command = function(command)
      return command[2] == "search" and "gh_duplicates" or "gh_detail", 0
    end
    local groups, complete = forge.scan_provider("github", false)
    assert_equal(complete, true, "valid duplicate GitHub records keep scan complete")
    assert_equal(#groups["owner/repo"].changes, 1, "duplicate GitHub review is deduplicated")

    local mr = { iid = 42, project_id = 99, sha = "head", source_branch = "topic",
      target_branch = "main", references = { full = "group/project!42" } }
    decoded.gl_duplicates = { mr, mr }
    decoded.gl_detail = { diff_refs = { base_sha = "b", start_sha = "s", head_sha = "h" } }
    git.run_command = function(command)
      local endpoint = command[3]
      if endpoint == "user" then decoded.gl_user = { id = 7 }; return "gl_user", 0 end
      if endpoint and endpoint:match("^merge_requests%?") then return "gl_duplicates", 0 end
      return "gl_detail", 0
    end
    groups, complete = forge.scan_provider("gitlab", false)
    assert_equal(complete, true, "valid duplicate GitLab records keep scan complete")
    assert_equal(#groups["group/project"].changes, 1, "duplicate GitLab review is deduplicated")
  end
  git.run_command = old_run_command
end

local function test_gerrit_requires_terminal_stats()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_run_command = git.run_command
  local change = { number = "5", project = "tools/repo", branch = "main",
    currentPatchSet = { number = "2", revision = "head", ref = "refs/changes/05/5/2" } }
  decoded.gerrit_change, decoded.gerrit_stats = change, { type = "stats", rowCount = 1 }
  do
    git.run_command = function() return "gerrit_change", 0 end
    local _, complete = forge.scan_provider("gerrit", false)
    assert_equal(complete, false, "missing Gerrit stats makes scan incomplete")
    git.run_command = function() return "gerrit_change\ngerrit_stats", 0 end
    _, complete = forge.scan_provider("gerrit", false)
    assert_equal(complete, true, "valid Gerrit stats completes scan")
  end
  git.run_command = old_run_command
end

local function test_failed_materialization_retains_previous_review()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_system = system
  local old_run_command = git.run_command
  local old_is_dirty = git.is_dirty
  local old_store_parent_ref = git.store_parent_ref
  local previous = {
    path = "/cache/repo-pr-16", pr_number = 16, branch = "old-branch",
    branch_name = "old-branch", head = "old-head", base = "main", agents = {},
  }
  local successful = {
    path = "/cache/repo-pr-17", pr_number = 17, branch = "old-success",
    branch_name = "old-success", head = "old-success-head", base = "main", agents = {},
  }
  local repo = {
    kind = "github", nwo = "owner/repo", cache_path = "/cache/repo",
    path = "/cache/repo", worktrees = { previous, successful },
  }
  local provider = {
    kind = "github", ref_ns = "pr", wt_suffix = "-pr-",
    source_ref = function(ch) return "refs/pull/" .. tostring(ch.number) .. "/head" end,
  }

  do
    system = { get_file_info = function() return {} end }
    git.run_command = function(command)
      for _, arg in ipairs(command) do
        if tostring(arg):match("refs/pull/16/head") then return "fetch failed", 1 end
      end
      return "", 0
    end
    git.is_dirty = function() return false end
    git.store_parent_ref = function() end
    local changed, reconcile_error = forge.reconcile({ repos = { repo } }, provider, {
      ["owner/repo"] = { changes = {
        { number = 16, branch = "new-branch", head = "new-head", base = "main" },
        { number = 17, branch = "new-success", head = "new-success-head", base = "main" },
      } },
    }, false)
    assert_equal(changed, true, "a failed review does not block successful review updates")
    assert_equal(repo.worktrees[1], previous, "failed update retains the previous worktree")
    assert_equal(previous.head, "old-head", "failed update does not advance the stored head")
    assert_equal(repo.worktrees[2].head, "new-success-head", "successful review metadata advances")
    if not tostring(reconcile_error):match("fetch failed") then
      error("failed update must be reported", 0)
    end
  end

  system = old_system
  git.run_command = old_run_command
  git.is_dirty = old_is_dirty
  git.store_parent_ref = old_store_parent_ref
end

local function test_incomplete_scan_and_prune_failure_retain_review()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_run_command = git.run_command
  local worktree = { path = "/cache/repo-pr-16", pr_number = 16, agents = {} }
  local repo = {
    kind = "github", nwo = "owner/repo", cache_path = "/cache/repo",
    path = "/cache/repo", worktrees = { worktree },
  }
  local context = { repos = { repo } }
  local provider = { kind = "github" }

  do
    git.run_command = function() error("incomplete scans must not prune") end
    local changed = forge.reconcile(context, provider, {}, false, false)
    assert_equal(changed, false, "incomplete scan retains unseen reviews")
    assert_equal(repo.worktrees[1], worktree, "incomplete scan retains review metadata")

    git.run_command = function() return "disk busy", 1 end
    local _, prune_error = forge.reconcile(context, provider, {}, false, true)
    assert_equal(repo.worktrees[1], worktree, "failed disk prune retains review metadata")
    if not tostring(prune_error):match("disk busy") then error("prune failure must be reported", 0) end
  end

  git.run_command = old_run_command
end

local function test_review_repos_are_managed()
  local forge = require "plugins.devhq.forge"
  for _, kind in ipairs({ "github", "gitlab", "gerrit" }) do
    assert_equal(forge.is_review_repo({ kind = kind }), true, kind .. " review repo is managed")
    assert_equal(forge.mutation_error({ kind = kind }, "deletion"),
      "Review-mirror repos do not support local worktree deletion",
      kind .. " review repo blocks deletion")
  end
  assert_equal(forge.is_review_repo({}), false, "local repo is not a managed review mirror")
  assert_equal(forge.is_review_repo({ kind = "remote" }), false, "remote repo uses its own policy")
end

local function test_state_save_failure_is_reported_and_retried()
  local file = assert(io.open("plugins/devhq/init.lua", "r"))
  local source = file:read("*a"); file:close()
  assert(source:find("save_state = save_state", 1, true), "forge must use reporting save path")
  assert(source:find("if err ~= state_save_error then", 1, true), "save errors must be deduplicated")
  assert(source:find("if state_save_pending then save_state() end", 1, true), "failed saves must retry")
  assert(not source:find("save_state(true)", 1, true), "save failures must not be quiet")
end

local function test_gitlab_clone_uses_host_environment()
  local forge = require "plugins.devhq.forge"
  local cmd, env = forge.gitlab_clone_spec("custom-glab", "gitlab.example.com",
    "group/project", "/cache/project")

  for i, value in ipairs({ "custom-glab", "repo", "clone", "group/project", "/cache/project" }) do
    assert_equal(cmd[i], value, "GitLab clone arg " .. i)
  end
  assert_not_contains(cmd, "--hostname", "repo clone does not support --hostname")
  assert_equal(cmd[6], "--", "git flags separator")
  assert_equal(cmd[7], "--depth=1", "shallow clone flag")
  assert_equal(cmd[8], "--no-checkout", "no checkout flag")
  assert_equal(env.GITLAB_HOST, "gitlab.example.com", "configured GitLab host environment")

  local _, default_env = forge.gitlab_clone_spec("glab", "", "group/project", "/cache/project")
  assert_equal(default_env, nil, "default host leaves the environment unchanged")
end

local function test_review_materialization_does_not_expand_history()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_system, old_run_command = system, git.run_command
  local old_is_dirty, old_store_parent_ref = git.is_dirty, git.store_parent_ref
  local commands, stored_parent = {}, nil

    system = { get_file_info = function() return nil end }
    git.run_command = function(command)
      commands[#commands + 1] = command
      return "", 0
    end
    git.is_dirty = function() return false end
    git.store_parent_ref = function(path, ref, _, review_ref)
      stored_parent = { path, ref, review_ref }
    end

    local provider = {
      ref_ns = "change",
      wt_suffix = "-change-",
      fetch_depth = 2,
      update_shallow = true,
      review_parent_ref = "HEAD^",
      source_ref = function() return "refs/changes/16/403216/19" end,
    }
    local repo = { cache_path = "/cache/manage" }
    local change = { number = 403216, base = "master" }
    local path, changed = forge.materialize_review(provider, repo, change, nil, false)

    assert_equal(path, "/cache/manage-change-403216", "review worktree path")
    assert_equal(#commands, 2, "materialization only fetches and creates the worktree")
    assert_contains(commands[1], "--depth=2", "Gerrit fetch includes the patch-set parent")
    assert_contains(commands[1], "--update-shallow", "existing Gerrit mirrors update shallow boundaries")
    assert_not_contains(commands[1], "--deepen=50", "review fetch does not deepen history")
    assert_not_contains(commands[1], "--unshallow", "review fetch does not unshallow history")
    assert_contains(commands[2], "add", "worktree is created after the shallow fetch")
    assert_equal(stored_parent[2], "HEAD^", "Gerrit diffs use the patch-set parent")
    assert_equal(stored_parent[3], "refs/changes/16/403216/19", "Gerrit review ref is retained")

    commands = {}
    system.get_file_info = function() return {} end
    change.head = "revision-19"
    local _, migrated = forge.materialize_review(provider, repo, change,
      { head = "revision-19" }, false)
    assert_equal(migrated, true, "depth-one Gerrit mirror is upgraded")
    assert_contains(commands[1], "--depth=2", "upgrade fetch includes the parent")

    commands = {}
    stored_parent = nil
    local _, unchanged = forge.materialize_review(provider, repo, change,
      { head = "revision-19", fetch_depth = 2 }, false)
    assert_equal(#commands, 0, "upgraded Gerrit mirrors skip materialization")
    assert_equal(stored_parent[3], "refs/changes/16/403216/19",
      "unchanged legacy mirror stores provider review ref")

    commands = {}
    system.get_file_info = function() return nil end
    provider.fetch_depth = nil
    provider.update_shallow = nil
    provider.review_parent_ref = nil
    provider.source_ref = function() return "refs/pull/42/head" end
    forge.materialize_review(provider, repo, { number = 42, base = "main" }, nil, false)
    assert_contains(commands[1], "--depth=1", "other forge review fetches remain depth one")
    assert_not_contains(commands[1], "--update-shallow", "other forges keep their fetch behavior")
    assert_equal(stored_parent[2], "origin/main", "other forges retain branch-based parent lookup")
    assert_equal(stored_parent[3], "refs/pull/42/head", "provider review ref is retained")
  system = old_system
  git.run_command = old_run_command
  git.is_dirty = old_is_dirty
  git.store_parent_ref = old_store_parent_ref
end

local function test_review_updates_wait_for_safe_worktree()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_system, old_run_command = system, git.run_command
  local old_is_dirty, old_store_parent_ref = git.is_dirty, git.store_parent_ref
  local commands = {}
  local provider = {
    ref_ns = "pr", wt_suffix = "-pr-",
    source_ref = function() return "refs/pull/16/head" end,
  }
  local repo = { cache_path = "/cache/repo" }
  local change = { number = 16, base = "main", head = "new-head" }

    system = { get_file_info = function() return {} end }
    git.run_command = function(command)
      commands[#commands + 1] = command
      return "", 0
    end
    git.store_parent_ref = function() end

    local dirty_checks = 0
    git.is_dirty = function()
      dirty_checks = dirty_checks + 1
      return false
    end
    local path, changed = forge.materialize_review(provider, repo, change,
      { head = "old-head", agents = { {} } }, false)
    assert_equal(path, nil, "attached agent freezes review update")
    assert_equal(dirty_checks, 0, "agent freeze does not inspect or mutate worktree")
    assert_equal(#commands, 0, "agent freeze runs no git commands")

    git.is_dirty = function() return true end
    path, changed = forge.materialize_review(provider, repo, change,
      { head = "old-head", agents = {} }, false)
    assert_equal(path, nil, "dirty worktree freezes review update")
    assert_equal(#commands, 0, "dirty freeze runs no fetch or checkout commands")

    system.get_file_info = function() return nil end
    git.is_dirty = function() error("new mirrors do not need a dirty check") end
    path, changed = forge.materialize_review(provider, repo, change,
      { head = "old-head", agents = { {} } }, false)
    assert_equal(path, "/cache/repo-pr-16", "missing review mirror is materialized")
    assert_equal(changed, true, "new review mirror reports a change")
    assert_equal(#commands, 2, "new review mirror fetches and creates a worktree")
  system = old_system
  git.run_command = old_run_command
  git.is_dirty = old_is_dirty
  git.store_parent_ref = old_store_parent_ref
end

local function test_stale_review_drafts_are_not_posted()
  local forge = require "plugins.devhq.forge"
  local git = require "plugins.devhq.git"
  local old_run_command = git.run_command
  local calls = 0
  git.run_command = function()
    calls = calls + 1
    return "", 0
  end

  do
    for _, kind in ipairs({ "github", "gitlab", "gerrit" }) do
      local posted, perr = forge.post_thread({ kind = kind, nwo = "owner/repo" },
        { head = "current-revision", pr_number = 16 },
        { commit = "draft-revision" }, "current-revision", false)
      assert_equal(posted, false, kind .. " rejects a stale draft")
      if not tostring(perr):match("draft%-revision")
        or not tostring(perr):match("current%-revision") then
        error(kind .. " stale draft error must identify both revisions", 0)
      end
    end
    local posted, perr = forge.post_thread({ kind = "github", nwo = "owner/repo" },
      { head = "stored-revision", pr_number = 16 },
      { commit = "disk-revision" }, "disk-revision", false)
    assert_equal(posted, false, "metadata and worktree mismatch rejects posting")
    if not tostring(perr):match("stored%-revision") or not tostring(perr):match("disk%-revision") then
      error("metadata mismatch error must identify stored and disk revisions", 0)
    end
    assert_equal(calls, 0, "stale drafts invoke no provider command")
  end

  git.run_command = old_run_command
end

local function test_gitlab_discussion_args()
  local forge = require "plugins.devhq.forge"
  local thread = { file = "src/a.lua", range = { start = { line = 3, col = 1 }, ["end"] = { line = 5, col = 2 } } }
  local diff_refs = { base_sha = "b1", start_sha = "s1", head_sha = "h1" }
  local args = forge.gitlab_discussion_args(99, 42, thread, diff_refs, "hello")
  assert_equal(args[1], "api", "glab api subcommand")
  assert_equal(args[2], "--method", "glab api method flag")
  assert_equal(args[3], "POST", "glab api POST")
  assert_equal(args[4], "projects/99/merge_requests/42/discussions", "glab api endpoint")
  assert_contains_all(args, { "body=hello", "position[position_type]=text",
    "position[base_sha]=b1", "position[start_sha]=s1", "position[head_sha]=h1",
    "position[new_path]=src/a.lua", "position[old_path]=src/a.lua",
    "position[new_line]=5" }, "GitLab discussion arg")
  for _, arg in ipairs(args) do
    if tostring(arg):find("position[line_range]", 1, true) then
      error("GitLab must fall back without required line codes", 0)
    end
  end
  -- new_line is the only typed (-F) field; everything else is a raw string (-f).
  for i, arg in ipairs(args) do
    if arg == "-F" then
      assert_equal(args[i + 1], "position[new_line]=5", "only new_line uses -F")
    end
  end
end

local function test_gerrit_change_ref()
  local forge = require "plugins.devhq.forge"
  assert_equal(forge.gerrit_change_ref(5, 3), "refs/changes/05/5/3", "single-digit shard is zero-padded")
  assert_equal(forge.gerrit_change_ref(100, 1), "refs/changes/00/100/1", "multiple-of-100 shard is 00")
  assert_equal(forge.gerrit_change_ref(884120, 3), "refs/changes/20/884120/3", "large change shard")
  assert_equal(forge.gerrit_change_ref(99, 2), "refs/changes/99/99/2", "two-digit shard")
end

local function test_gerrit_review_input()
  local forge = require "plugins.devhq.forge"
  local thread = { file = "src/a.lua", range = { start = { line = 3, col = 1 }, ["end"] = { line = 5, col = 2 } } }
  local input = forge.gerrit_review_input(thread, "hello\n\nworld")
  local file_comments = input.comments["src/a.lua"]
  assert_equal(type(file_comments), "table", "review input keyed by file path")
  assert_equal(#file_comments, 1, "one inline comment per thread")
  assert_equal(file_comments[1].line, 5, "comment line uses end line")
  assert_equal(file_comments[1].message, "hello\n\nworld", "comment message")
  assert_equal(file_comments[1].range.start_line, 3, "Gerrit range start line")
  assert_equal(file_comments[1].range.start_character, 0, "Gerrit range start character is zero-based")
  assert_equal(file_comments[1].range.end_line, 5, "Gerrit range end line")
  assert_equal(file_comments[1].range.end_character, 1, "Gerrit range end character is zero-based")

  local single = forge.gerrit_review_input({
    file = "src/a.lua", range = { start = { line = 5, col = 2 }, ["end"] = { line = 5, col = 4 } },
  }, "single").comments["src/a.lua"][1]
  assert_equal(single.range, nil, "single-line Gerrit comment uses end-line fallback")
end

local tests = {
  test_remote_mirror_command_shapes,
  test_remote_scalar_output_ignores_ssh_warnings,
  test_remote_mirror_parent_candidates_match_local_precedence,
  test_review_merge_base_deepens_provider_ref,
  test_duplicate_local_remote_branch_grouping,
  test_forge_labels,
  test_github_api_comment_args,
  test_failed_details_retain_previous_reviews,
  test_scan_completeness_ignores_valid_duplicates,
  test_gerrit_requires_terminal_stats,
  test_failed_materialization_retains_previous_review,
  test_incomplete_scan_and_prune_failure_retain_review,
  test_review_repos_are_managed,
  test_state_save_failure_is_reported_and_retried,
  test_gitlab_clone_uses_host_environment,
  test_review_materialization_does_not_expand_history,
  test_review_updates_wait_for_safe_worktree,
  test_stale_review_drafts_are_not_posted,
  test_gitlab_discussion_args,
  test_gerrit_change_ref,
  test_gerrit_review_input,
}

for _, test in ipairs(tests) do
  test()
end

print(string.format("ok %d tests", #tests))
