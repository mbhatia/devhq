-- mod-version:3

-- Provider-driven engine mirroring review requests (GitHub PRs, GitLab MRs,
-- Gerrit changes) into local shallow clones with one detached worktree per change.

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local git = require "plugins.devhq.git"

local M = {}
local ctx

config.plugins.devhq = config.plugins.devhq or {}

local function join_path(path, name)
  if path:sub(-1) == PATHSEP then return path .. name end
  return path .. PATHSEP .. name
end

local function conf(section, key, fallback)
  local c = config.plugins.devhq[section] or {}
  local v = c[key]
  if v == nil or v == "" then return fallback end
  return v
end

-- Lazy require of comments avoids a circular dependency (comments needs us too).
local function decode(output)
  local ok, data = pcall(require("plugins.devhq.comments").decode, output or "")
  if ok then return data end
end

local function encode(value)
  return require("plugins.devhq.comments").encode(value)
end

local function git_cmd(cwd, args, yielding)
  local cmd = { "git", "-C", cwd }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  return git.run_command(cmd, cwd, yielding)
end

local function draft_body(thread)
  local parts = {}
  for _, m in ipairs(thread.messages or {}) do
    if m.state == "draft" and (m.body or "") ~= "" then parts[#parts + 1] = m.body end
  end
  return table.concat(parts, "\n\n")
end

local function previous_change(wt)
  if not wt then return end
  local extra = {}
  for _, key in ipairs({ "diff_refs", "patchset" }) do
    if wt[key] ~= nil then extra[key] = wt[key] end
  end
  return {
    number = wt.pr_number,
    branch = wt.branch,
    head = wt.head,
    base = wt.base,
    extra = next(extra) and extra or nil,
  }
end

-- GitHub provider -------------------------------------------------------------

local github = { kind = "github", ref_ns = "pr", wt_suffix = "-pr-" }

local function gh_bin() return conf("github", "gh", "gh") end

function github.enabled() return conf("github", "enabled", false) == true end

function github.scan(yielding, prev)
  local groups, seen, complete = {}, {}, true
  local limit = 100
  for _, flag in ipairs({ "--assignee=@me", "--review-requested=@me" }) do
    local out, code = git.run_command({ gh_bin(), "search", "prs", flag,
      "--state=open", "--limit", tostring(limit), "--json", "number,repository" }, nil, yielding)
    if code ~= 0 then return nil, out end
    local prs = decode(out)
    if type(prs) ~= "table" then return nil, "could not parse gh output" end
    if #prs >= limit then complete = false end
    for _, pr in ipairs(prs) do
      local nwo = type(pr.repository) == "table" and pr.repository.nameWithOwner
      if nwo and pr.number then
        local id = nwo .. "#" .. pr.number
        if not seen[id] then
          seen[id] = true
          local dout, dcode = git.run_command({ gh_bin(), "pr", "view", tostring(pr.number),
            "--repo", nwo, "--json", "number,headRefName,headRefOid,baseRefName" }, nil, yielding)
          local d = dcode == 0 and decode(dout)
          if type(d) == "table" and d.headRefOid then
            groups[nwo] = groups[nwo] or { changes = {} }
            table.insert(groups[nwo].changes, { number = d.number or pr.number,
              branch = d.headRefName, head = d.headRefOid, base = d.baseRefName })
          else
            complete = false
            local old = prev and previous_change(prev(github.kind, nwo, pr.number))
            if old then
              groups[nwo] = groups[nwo] or { changes = {} }
              table.insert(groups[nwo].changes, old)
            end
          end
        end
      else
        complete = false
      end
    end
  end
  return groups, complete
end

function github.make_repo(key) return { kind = "github", nwo = key } end
function github.cache_path(repo) return git.github_cache_path(repo.nwo) end

function github.clone(repo, yielding)
  return git.run_command({ gh_bin(), "repo", "clone", repo.nwo, repo.cache_path,
    "--", "--depth=1", "--no-checkout" }, common.dirname(repo.cache_path), yielding)
end

function github.source_ref(ch) return "refs/pull/" .. tostring(ch.number) .. "/head" end
function github.post_label(wt) return "github:pr#" .. tostring(wt.pr_number) end

-- Pure argument builder for a PR review comment (kept testable).
function M.api_comment_args(nwo, pr, thread, commit, body)
  local r = thread.range
  local args = { "api", "repos/" .. nwo .. "/pulls/" .. tostring(pr) .. "/comments",
    "-f", "body=" .. tostring(body),
    "-f", "path=" .. tostring(thread.file),
    "-f", "commit_id=" .. tostring(commit),
    "-F", "line=" .. tostring(r["end"].line),
    "-f", "side=RIGHT" }
  if r.start.line ~= r["end"].line then
    args[#args + 1] = "-F"; args[#args + 1] = "start_line=" .. tostring(r.start.line)
    args[#args + 1] = "-f"; args[#args + 1] = "start_side=RIGHT"
  end
  return args
end

function github.post_thread(repo, wt, thread, yielding)
  local cmd = { gh_bin() }
  for _, a in ipairs(M.api_comment_args(repo.nwo, wt.pr_number, thread,
    thread.commit, draft_body(thread))) do
    cmd[#cmd + 1] = a
  end
  local out, code = git.run_command(cmd, nil, yielding)
  return code == 0, out
end

-- GitLab provider -------------------------------------------------------------

local gitlab = { kind = "gitlab", ref_ns = "mr", wt_suffix = "-mr-" }
local gitlab_user

local function glab_cmd(args)
  local cmd = { conf("gitlab", "glab", "glab") }
  for _, a in ipairs(args) do cmd[#cmd + 1] = a end
  local host = conf("gitlab", "host", "")
  if host ~= "" then cmd[#cmd + 1] = "--hostname"; cmd[#cmd + 1] = host end
  return cmd
end

local function gitlab_api(path, yielding)
  local out, code = git.run_command(glab_cmd({ "api", path }), nil, yielding)
  if code ~= 0 then return nil, out end
  local data = decode(out)
  if type(data) ~= "table" then return nil, "could not parse glab output" end
  return data
end

function gitlab.enabled() return conf("gitlab", "enabled", false) == true end

function gitlab.scan(yielding, prev)
  if not gitlab_user then
    local user, err = gitlab_api("user", yielding)
    if not user or not user.id then return nil, err or "could not resolve gitlab user" end
    gitlab_user = user
  end
  local groups, seen, complete = {}, {}, true
  local limit = 100
  for _, query in ipairs({
    "merge_requests?scope=assigned_to_me&state=opened&per_page=100",
    "merge_requests?scope=all&reviewer_id=" .. tostring(gitlab_user.id) .. "&state=opened&per_page=100",
  }) do
    local mrs, err = gitlab_api(query, yielding)
    if not mrs then return nil, err end
    if #mrs >= limit then complete = false end
    for _, mr in ipairs(mrs) do
      local full = type(mr.references) == "table" and tostring(mr.references.full or "")
      local key = full and full:match("^(.-)!%d+$")
      if key and key ~= "" and mr.iid and mr.project_id then
        local id = key .. "!" .. mr.iid
        if not seen[id] then
          seen[id] = true
          local old = prev and prev(gitlab.kind, key, mr.iid)
          local diff_refs = old and old.head == mr.sha and old.diff_refs or nil
          local change
          if not diff_refs then
            local detail = gitlab_api("projects/" .. tostring(mr.project_id)
              .. "/merge_requests/" .. tostring(mr.iid), yielding)
            diff_refs = type(detail) == "table" and detail.diff_refs or nil
            if not diff_refs then
              complete = false
              if old then change = previous_change(old) end
            end
          end
          groups[key] = groups[key] or { changes = {}, project_id = mr.project_id }
          change = change or { number = mr.iid,
            branch = mr.source_branch, head = mr.sha, base = mr.target_branch,
            extra = { diff_refs = diff_refs } }
          table.insert(groups[key].changes, change)
        end
      else
        complete = false
      end
    end
  end
  return groups, complete
end

function gitlab.make_repo(key, group)
  return { kind = "gitlab", nwo = key, project_id = group and group.project_id }
end

function gitlab.cache_path(repo) return git.gitlab_cache_path(repo.nwo) end

-- glab repo clone does not accept the api command's --hostname flag. It uses
-- GITLAB_HOST to select a self-managed instance instead.
function M.gitlab_clone_spec(glab, host, nwo, cache_path)
  local cmd = { glab, "repo", "clone", nwo, cache_path }
  cmd[#cmd + 1] = "--"; cmd[#cmd + 1] = "--depth=1"; cmd[#cmd + 1] = "--no-checkout"
  local env = host ~= "" and { GITLAB_HOST = host } or nil
  return cmd, env
end

function gitlab.clone(repo, yielding)
  local cmd, env = M.gitlab_clone_spec(conf("gitlab", "glab", "glab"),
    conf("gitlab", "host", ""), repo.nwo, repo.cache_path)
  return git.run_command(cmd, common.dirname(repo.cache_path), yielding, env)
end

function gitlab.source_ref(ch) return "refs/merge-requests/" .. tostring(ch.number) .. "/head" end
function gitlab.post_label(wt) return "gitlab:mr!" .. tostring(wt.pr_number) end

-- Pure argument builder for a positioned MR discussion (kept testable).
-- NOTE: glab's flags invert gh's: -f is a raw string field, -F is a typed field.
function M.gitlab_discussion_args(project_id, iid, thread, diff_refs, body)
  return { "api", "--method", "POST",
    "projects/" .. tostring(project_id) .. "/merge_requests/" .. tostring(iid) .. "/discussions",
    "-f", "body=" .. tostring(body),
    "-f", "position[position_type]=text",
    "-f", "position[base_sha]=" .. tostring(diff_refs.base_sha),
    "-f", "position[start_sha]=" .. tostring(diff_refs.start_sha),
    "-f", "position[head_sha]=" .. tostring(diff_refs.head_sha),
    "-f", "position[new_path]=" .. tostring(thread.file),
    "-f", "position[old_path]=" .. tostring(thread.file),
    "-F", "position[new_line]=" .. tostring(thread.range["end"].line) }
end

function gitlab.post_thread(repo, wt, thread, yielding)
  if type(wt.diff_refs) ~= "table" or not wt.diff_refs.base_sha then
    return false, "no diff_refs stored for this MR; rescan (devhq:scan-review-requests) and retry"
  end
  local cmd = glab_cmd(M.gitlab_discussion_args(repo.project_id,
    wt.pr_number, thread, wt.diff_refs, draft_body(thread)))
  local out, code = git.run_command(cmd, nil, yielding)
  return code == 0, out
end

-- Gerrit provider -------------------------------------------------------------

local gerrit = { kind = "gerrit", ref_ns = "change", wt_suffix = "-change-",
  fetch_depth = 2, update_shallow = true, review_parent_ref = "HEAD^" }

local function gerrit_target(host, user)
  return ((user or "") ~= "" and user .. "@" or "") .. tostring(host)
end

function gerrit.enabled()
  return conf("gerrit", "host", "") ~= ""
end

function gerrit.scan(yielding)
  local host = conf("gerrit", "host", "")
  local port = tonumber(conf("gerrit", "port", 29418)) or 29418
  local user = conf("gerrit", "user", "")
  local out, code = git.run_command({ "ssh", "-p", tostring(port), gerrit_target(host, user),
    "gerrit", "query", "--format=JSON", "--current-patch-set",
    "status:open (owner:self OR reviewer:self)" }, nil, yielding)
  if code ~= 0 then return nil, out end
  local groups, complete, saw_stats = {}, true, false
  -- JSON-Lines output: one change per line plus a trailing stats line to skip.
  for line in tostring(out):gmatch("[^\r\n]+") do
    local ch = decode(line)
    if type(ch) ~= "table" then
      complete = false
    elseif ch.type == "stats" then
      saw_stats = tonumber(ch.rowCount) ~= nil or saw_stats
      if tonumber(ch.rowCount) == nil then complete = false end
      if ch.moreChanges then complete = false end
    elseif type(ch.currentPatchSet) == "table" then
      local number = tonumber(ch.number)
      local cp = ch.currentPatchSet
      if number and ch.project and ch.branch and cp.revision then
        groups[ch.project] = groups[ch.project] or { changes = {} }
        table.insert(groups[ch.project].changes, {
          number = number, branch = ch.branch, head = cp.revision,
          base = ch.branch, ref = cp.ref, extra = { patchset = tonumber(cp.number) or 1 } })
      else
        complete = false
      end
    else
      complete = false
    end
  end
  return groups, complete and saw_stats
end

function gerrit.make_repo(key)
  return { kind = "gerrit", nwo = key, host = conf("gerrit", "host", ""),
    port = tonumber(conf("gerrit", "port", 29418)) or 29418, user = conf("gerrit", "user", "") }
end

function gerrit.cache_path(repo) return git.gerrit_cache_path(repo.host, repo.nwo) end

function gerrit.clone(repo, yielding)
  local url = "ssh://" .. gerrit_target(repo.host, repo.user) .. ":"
    .. tostring(repo.port or 29418) .. "/" .. tostring(repo.nwo)
  return git.run_command({ "git", "clone", "--depth=1", "--no-checkout", url, repo.cache_path },
    common.dirname(repo.cache_path), yielding)
end

-- Pure fallback for currentPatchSet.ref: refs/changes/<last 2 digits>/<number>/<patchset>.
function M.gerrit_change_ref(number, patchset)
  local shard = string.format("%02d", (tonumber(number) or 0) % 100)
  return "refs/changes/" .. shard .. "/" .. tostring(number) .. "/" .. tostring(patchset)
end

function gerrit.source_ref(ch)
  return ch.ref or M.gerrit_change_ref(ch.number, (ch.extra and ch.extra.patchset) or 1)
end

function gerrit.post_label(wt) return "gerrit:#" .. tostring(wt.pr_number) end

-- Pure ReviewInput builder for `gerrit review --json` (kept testable).
function M.gerrit_review_input(thread, body)
  local r = thread.range
  local comment = { line = r["end"].line, message = tostring(body) }
  if r.start.line ~= r["end"].line then
    comment.range = {
      start_line = r.start.line,
      start_character = math.max(0, (r.start.col or 1) - 1),
      end_line = r["end"].line,
      end_character = math.max(0, (r["end"].col or 1) - 1),
    }
  end
  return { comments = { [tostring(thread.file)] = { comment } } }
end

function gerrit.post_thread(repo, wt, thread, yielding)
  local json = encode(M.gerrit_review_input(thread, draft_body(thread)))
  -- gerrit review reads the ReviewInput from stdin to EOF; run_command has no
  -- stdin support, so pipe the JSON in through a local shell.
  local script = "printf '%s' " .. git.shell_quote(json) .. " | exec ssh -p "
    .. tostring(repo.port or 29418) .. " " .. git.shell_quote(gerrit_target(repo.host, repo.user))
    .. " gerrit review --json " .. tostring(wt.pr_number) .. "," .. tostring(wt.patchset or 1)
  local out, code = git.run_command({ "/bin/sh", "-c", script }, nil, yielding)
  return code == 0, out
end

-- Generic engine --------------------------------------------------------------

local providers = { github, gitlab, gerrit }
local by_kind = {}
M.kinds = {}
for _, p in ipairs(providers) do
  by_kind[p.kind] = p
  M.kinds[p.kind] = true
end

function M.is_review_repo(repo)
  return repo and M.kinds[repo.kind] or false
end

function M.mutation_error(repo, action)
  if M.is_review_repo(repo) then
    return "Review-mirror repos do not support local worktree " .. tostring(action)
  end
end

local function find_prev(kind, key, number)
  if not ctx then return end
  for _, r in ipairs(ctx.repos) do
    if r.kind == kind and r.nwo == key then
      for _, wt in ipairs(r.worktrees or {}) do
        if wt.pr_number == number then return wt end
      end
    end
  end
end

local function ensure_repo(context, p, key, group)
  for _, r in ipairs(context.repos) do
    if r.kind == p.kind and r.nwo == key then return r end
  end
  local repo = p.make_repo(key, group)
  repo.cache_path = p.cache_path(repo)
  repo.path = repo.cache_path
  repo.worktrees = {}
  context.repos[#context.repos + 1] = repo
  return repo
end

local function ensure_clone(p, repo, yielding)
  if system.get_file_info(join_path(repo.cache_path, ".git")) then return true end
  common.mkdirp(common.dirname(repo.cache_path))
  local out, code = p.clone(repo, yielding)
  return code == 0, out
end

function M.materialize_review(p, repo, ch, prev, yielding)
  local n = tostring(ch.number)
  local base = tostring(ch.base)
  local fetch_depth = tonumber(p.fetch_depth) or 1
  local wt_path = repo.cache_path .. p.wt_suffix .. n
  local head_ref, base_ref = "origin/" .. p.ref_ns .. "/" .. n, "origin/" .. base
  local parent_ref = p.review_parent_ref or base_ref
  local exists = system.get_file_info(wt_path) ~= nil
  local previous_depth = tonumber(prev and prev.fetch_depth) or 1
  if exists and prev and prev.head == ch.head and previous_depth >= fetch_depth then
    git.store_parent_ref(wt_path, parent_ref, yielding, p.source_ref(ch))
    return wt_path, false
  end
  if exists then
    if prev and #(prev.agents or {}) > 0 then return nil, false end
    local dirty, derr = git.is_dirty(wt_path, yielding)
    if dirty == nil then return nil, false, derr end
    if dirty then return nil, false end
  end
  local fetch_args = { "fetch", "--force" }
  if p.update_shallow then fetch_args[#fetch_args + 1] = "--update-shallow" end
  fetch_args[#fetch_args + 1] = "--depth=" .. tostring(fetch_depth)
  fetch_args[#fetch_args + 1] = "origin"
  fetch_args[#fetch_args + 1] = "+" .. p.source_ref(ch)
    .. ":refs/remotes/origin/" .. p.ref_ns .. "/" .. n
  fetch_args[#fetch_args + 1] = "+refs/heads/" .. base .. ":refs/remotes/origin/" .. base
  local output, fcode = git_cmd(repo.cache_path, fetch_args, yielding)
  if fcode ~= 0 then return nil, false, output end
  if not exists then
    local out, code = git_cmd(repo.cache_path, git.remote_mirror_worktree_add_args(wt_path, head_ref), yielding)
    if code ~= 0 then return nil, false, out end
  else
    for _, cmd in ipairs(git.remote_mirror_checkout_commands(wt_path, head_ref)) do
      local out, code = git.run_command(cmd, wt_path, yielding)
      if code ~= 0 then return nil, false, out end
    end
  end
  git.store_parent_ref(wt_path, parent_ref, yielding, p.source_ref(ch))
  return wt_path, true
end

function M.reconcile(context, p, groups, yielding, complete)
  local changed, errors = false, {}
  for key, group in pairs(groups) do ensure_repo(context, p, key, group) end
  for i = #context.repos, 1, -1 do
    local repo = context.repos[i]
    if repo.kind == p.kind then
      local group = groups[repo.nwo]
      local changes = group and group.changes or {}
      if #changes > 0 then
        local cloned, cerr = ensure_clone(p, repo, yielding)
        if not cloned then
          errors[#errors + 1] = "clone failed for " .. repo.nwo .. ": " .. tostring(cerr)
          goto continue
        end
      end
      local existing = {}
      for _, wt in ipairs(repo.worktrees) do existing[wt.pr_number] = wt end
      local kept, seen = {}, {}
      for _, ch in ipairs(changes) do
        seen[ch.number] = true
        local prev = existing[ch.number]
        local wt_path, did, merr = M.materialize_review(p, repo, ch, prev, yielding)
        if wt_path then
          local wt = prev or { agents = {} }
          wt.path, wt.branch, wt.branch_name = wt_path, ch.branch, ch.branch
          wt.head, wt.base, wt.pr_number = ch.head, ch.base, ch.number
          if p.fetch_depth and did then wt.fetch_depth = p.fetch_depth end
          for k, v in pairs(ch.extra or {}) do wt[k] = v end
          wt.agents = wt.agents or {}
          kept[#kept + 1] = wt
          if did or not prev then changed = true end
        elseif prev then
          kept[#kept + 1] = prev
        end
        if merr then
          errors[#errors + 1] = "update failed for " .. repo.nwo .. "#"
            .. tostring(ch.number) .. ": " .. tostring(merr)
        end
      end
      for _, wt in ipairs(repo.worktrees) do
        if not seen[wt.pr_number] then
          if complete == false or #(wt.agents or {}) > 0 then
            kept[#kept + 1] = wt
          else
            local out, code = git_cmd(repo.cache_path,
              { "worktree", "remove", "--force", wt.path }, yielding)
            if code == 0 then
              changed = true
            else
              kept[#kept + 1] = wt
              errors[#errors + 1] = "prune failed for " .. repo.nwo .. "#"
                .. tostring(wt.pr_number) .. ": " .. tostring(out)
            end
          end
        end
      end
      repo.worktrees = kept
      if complete ~= false and #kept == 0 and not groups[repo.nwo] then
        table.remove(context.repos, i)
        changed = true
      end
    end
    ::continue::
  end
  return changed, #errors > 0 and table.concat(errors, "\n") or nil
end

local scanning = false
local last_error = {}

local function run_scan()
  if scanning or not ctx then return end
  scanning = true
  core.add_thread(function()
    local any_changed = false
    for _, p in ipairs(providers) do
      if p.enabled() then
        local ok, err = pcall(function()
          local groups, complete = M.scan_provider(p.kind, true, find_prev)
          if not groups then error(complete or (p.kind .. " scan failed"), 0) end
          local rchanged, rerr = M.reconcile(ctx, p, groups, true, complete)
          if rchanged then any_changed = true end
          if rerr then error(rerr, 0) end
          last_error[p.kind] = nil
        end)
        if not ok and tostring(err) ~= last_error[p.kind] then
          last_error[p.kind] = tostring(err)
          core.error("DevHQ %s: %s", p.kind, tostring(err))
        end
      end
    end
    if any_changed then ctx.save_state(); core.redraw = true end
    scanning = false
  end)
end

function M.cache_path(repo)
  local p = by_kind[repo.kind]
  return p and p.cache_path(repo)
end

function M.scan_provider(kind, yielding, prev)
  local p = by_kind[kind]
  if not p then return nil, "unknown repo kind: " .. tostring(kind) end
  return p.scan(yielding, prev)
end

function M.change_for_worktree(path)
  if not ctx then return end
  for _, r in ipairs(ctx.repos) do
    if M.kinds[r.kind] then
      for _, wt in ipairs(r.worktrees or {}) do
        if wt.path == path then return r, wt end
      end
    end
  end
end

function M.post_label(repo, wt)
  local p = by_kind[repo.kind]
  return p and p.post_label(wt)
end

function M.post_thread(repo, wt, thread, head, yielding)
  local p = by_kind[repo.kind]
  if not p then return false, "unknown repo kind: " .. tostring(repo.kind) end
  local draft_revision = thread and thread.commit
  local stored_revision = wt and wt.head
  if not head or not stored_revision or head ~= stored_revision then
    return false, string.format("review revision mismatch: stored %s; worktree HEAD is %s",
      tostring(stored_revision), tostring(head))
  end
  if not draft_revision or draft_revision == "uncommitted" or draft_revision ~= head then
    return false, string.format("stale draft revision %s; worktree HEAD is %s",
      tostring(draft_revision), tostring(head))
  end
  return p.post_thread(repo, wt, thread, yielding)
end

function M.setup(c)
  ctx = c
  command.add(nil, {
    ["devhq:scan-review-requests"] = run_scan,
  })
  core.add_thread(function()
    while true do
      run_scan()
      coroutine.yield(conf("forge", "poll_interval", 60))
    end
  end)
end

return M
