-- mod-version:3

local core = require "core"
local common = require "core.common"
local DocView = require "core.docview"
local TreeView = require "libraries.generic_treeview"
local git = require "plugins.sivraj.git"
local default_treeview = require "plugins.treeview"

local M = {}

local cache_root = USERDIR .. PATHSEP .. "sivraj-git-history"
local state = {
  view = nil,
  original_view = nil,
  original_node = nil,
  commits = nil,
  files = {},
  expanded = {},
  pending_history = false,
  pending_files = {},
}

local function safe_part(text)
  text = tostring(text or ""):gsub("[/\\:]", "_")
  return text:gsub("[^%w%._%-]", "_")
end

local function ensure_dir(path)
  if system.get_file_info(path) then return true end
  local ok, err, failed = common.mkdirp(path)
  if ok then return true end
  return false, string.format("Could not create %s: %s", failed or path, err or "unknown error")
end

local function repo_path()
  return core.project_dir
end

local function load_history(force)
  local path = repo_path()
  if not path or state.pending_history or (state.commits and not force) then return end
  state.pending_history = true
  core.add_thread(function()
    local commits, err = git.branch_history(path, true)
    state.pending_history = false
    if commits then
      state.commits, state.files = commits, {}
    else
      state.commits = { { hash = "error", short_hash = "error", subject = err or "No git history" } }
    end
    core.redraw = true
  end)
end

local function load_files(commit)
  local path = repo_path()
  if not path or not commit or state.files[commit.hash] or state.pending_files[commit.hash] then return end
  state.pending_files[commit.hash] = true
  core.add_thread(function()
    local files = git.commit_files(path, commit.hash, true)
    state.pending_files[commit.hash] = nil
    state.files[commit.hash] = files or {}
    core.redraw = true
  end)
end

local function file_label(file)
  local stats = ""
  if file.added or file.deleted then
    stats = string.format(" (+%s,-%s)", file.added or "?", file.deleted or "?")
  end
  return string.format("%s %s%s", file.status or "M", file.path, stats)
end

local function cache_path(commit, file)
  local dir = cache_root .. PATHSEP .. safe_part(repo_path())
  return dir .. PATHSEP .. safe_part(commit.short_hash or commit.hash) .. "-" .. safe_part(file.path)
end

local function write_snapshot(commit, file)
  local path = repo_path()
  local text, err = git.commit_file_content(path, commit.hash, file, true)
  if not text then return nil, err end
  local filename = cache_path(commit, file)
  local ok, mkdir_err = ensure_dir(common.dirname(filename))
  if not ok then return nil, mkdir_err end
  local fp = io.open(filename, "wb")
  if not fp then return nil, "Could not write " .. filename end
  fp:write(text)
  fp:close()
  return filename
end

local function attach_context(view, commit, file)
  if not view then return end
  view.sivraj_commit_diff = {
    repo = repo_path(),
    commit = commit.hash,
    file = {
      path = file.path,
      old_path = file.old_path,
      status = file.status,
      status_code = file.status_code,
    },
  }
  view.sivraj_diff_key = nil
end

local function open_file(commit, file)
  core.add_thread(function()
    local filename, err = write_snapshot(commit, file)
    if not filename then return core.error("Could not open commit file: %s", err or "unknown error") end
    local doc = core.open_doc(filename)
    local view = core.root_view:open_doc(doc)
    if view and view:extends(DocView) then attach_context(view, commit, file) end
    core.redraw = true
  end)
end

local backend = {
  roots = function()
    load_history(false)
    local roots = {}
    for i, commit in ipairs(state.commits or {}) do
      roots[#roots + 1] = {
        id = commit.hash,
        order = i,
        kind = "commit",
        label = string.format("%s %s %s", commit.short_hash or "", commit.date or "", commit.subject or ""),
        tooltip = string.format("%s\n%s", commit.hash or "", commit.author or ""),
        commit = commit,
        can_expand = function(node) return node.commit and node.commit.hash ~= "error" end,
        is_expanded = function(node) return state.expanded[node.id] == true end,
        set_expanded = function(node, value)
          state.expanded[node.id] = not not value
          if value then load_files(node.commit) end
        end,
        children = function(node)
          load_files(node.commit)
          local children = {}
          for i, file in ipairs(state.files[node.id] or {}) do
            children[#children + 1] = {
              id = node.id .. ":" .. file.path,
              order = i,
              kind = "file",
              label = file_label(file),
              tooltip = file.old_path and (file.old_path .. " -> " .. file.path) or file.path,
              file = file,
              commit = node.commit,
              open = function(child) open_file(child.commit, child.file) end,
            }
          end
          return children
        end,
      }
    end
    return roots
  end,
}

local function replace_view(old, new)
  local node = core.root_view.root_node:get_node_for_view(old)
  local idx = node and node:get_view_idx(old)
  if not idx then return false end
  node.views[idx] = new
  node:set_active_view(new)
  new.node = node
  core.root_view.root_node:update_layout()
  return true
end

function M.toggle()
  if state.view then
    if state.original_view and state.view then replace_view(state.view, state.original_view) end
    state.view = nil
    state.original_view = nil
    core.redraw = true
    return
  end
  state.commits, state.files = nil, {}
  local view = TreeView({ backend = backend, default_expanded = false })
  view.activate_on_single_click = true
  view._sivraj_git_history = true
  state.view = view
  state.original_view = default_treeview
  if not replace_view(default_treeview, view) then
    local node = core.root_view.root_node:get_node_for_view(default_treeview)
    view.node = node:split("left", view, { x = true }, true)
  end
  load_history(true)
  core.redraw = true
end

return M
