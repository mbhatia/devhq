-- mod-version:3

local core = require "core"
local common = require "core.common"
local Doc = require "core.doc"
local DocView = require "core.docview"
local EmptyView = require "core.emptyview"
local Node = require "core.node"
local RootView = require "core.rootview"
local style = require "core.style"
local TreeView = require "libraries.generic_treeview"
local git = require "plugins.devhq.git"
local default_treeview = require "plugins.treeview"

local M = {}

local function cache_dir()
  return rawget(_G, "CACHEDIR")
    or os.getenv("LITE_CACHEDIR")
    or (os.getenv("XDG_CACHE_HOME") and os.getenv("XDG_CACHE_HOME") .. PATHSEP .. "lite-xl")
    or (HOME and HOME .. PATHSEP .. ".cache" .. PATHSEP .. "lite-xl")
    or USERDIR
end

local cache_root = cache_dir() .. PATHSEP .. "devhq-git-history"
local state = {
  view = nil,
  original_view = nil,
  original_node = nil,
  repo_path = nil,
  commits = nil,
  files = {},
  expanded = {},
  pending_history = nil,
  pending_files = {},
  commit_logs = {},
  pending_commit_logs = {},
}
local ephemeral_view
local attach_context

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

local function get_view_node(view)
  return view and core.root_view.root_node:get_node_for_view(view)
end

local function promote_ephemeral(view)
  if not (view and view._devhq_history_ephemeral) then return end
  view._devhq_history_ephemeral = nil
  view._devhq_ephemeral = nil
  if ephemeral_view == view then ephemeral_view = nil end
  core.redraw = true
end

local function close_ephemeral(except_doc)
  local view, node = ephemeral_view, get_view_node(ephemeral_view)
  if not (view and node) then
    ephemeral_view = nil
    return
  end
  if except_doc and view.doc == except_doc then return end
  if view.doc and view.doc:is_dirty() then
    promote_ephemeral(view)
    return
  end
  ephemeral_view = nil
  view._devhq_history_ephemeral = nil
  view._devhq_ephemeral = nil
  if #node.views > 1 then
    local idx = node:get_view_idx(view)
    if idx then
      table.remove(node.views, idx)
      if node.active_view == view then
        node:set_active_view(node.views[idx] or node.views[#node.views])
      end
    end
  else
    node.views = {}
    node:add_view(EmptyView())
  end
  core.root_view.root_node:update_layout()
  core.redraw = true
end

local function has_persistent_view(doc)
  for _, view in ipairs(core.get_views_referencing_doc(doc)) do
    if not view._devhq_history_ephemeral then return true end
  end
end

local function replace_ephemeral(doc, ephemeral, path, commit, file)
  local old_view, node = ephemeral_view, get_view_node(ephemeral_view)
  local idx = node and node:get_view_idx(old_view)
  if not idx then return end
  if old_view.doc and old_view.doc:is_dirty() then
    promote_ephemeral(old_view)
    return
  end

  local view = DocView(doc)
  node.views[idx] = view
  node:set_active_view(view)
  view:scroll_to_line(view.doc:get_selection(), true, true)
  attach_context(view, path, commit, file)
  if ephemeral then
    view._devhq_history_ephemeral = true
    view._devhq_ephemeral = true
    ephemeral_view = view
  else
    ephemeral_view = nil
  end
  old_view._devhq_history_ephemeral = nil
  old_view._devhq_ephemeral = nil
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end

local function activate_previous_editor()
  if core.last_active_view and core.active_view == state.view then
    core.set_active_view(core.last_active_view)
  end
end

local function reset_history(path)
  state.repo_path = path
  state.commits = nil
  state.files = {}
  state.expanded = {}
  state.pending_history = nil
  state.pending_files = {}
  state.commit_logs = {}
  state.pending_commit_logs = {}
end

local function load_history(force)
  local path = repo_path()
  if not path then
    if state.repo_path then reset_history(nil) end
    return
  end
  if state.repo_path ~= path then reset_history(path) end
  if state.pending_history or (state.commits and not force) then return end
  state.pending_history = path
  core.add_thread(function()
    local commits, err = git.branch_history(path, true)
    if state.repo_path ~= path or state.pending_history ~= path then return end
    state.pending_history = nil
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
  if state.repo_path ~= path then return end
  if not path or not commit or state.files[commit.hash] or state.pending_files[commit.hash] then return end
  state.pending_files[commit.hash] = true
  core.add_thread(function()
    local files = git.commit_files(path, commit.hash, true)
    if state.repo_path ~= path or not state.pending_files[commit.hash] then return end
    state.pending_files[commit.hash] = nil
    state.files[commit.hash] = files or {}
    core.redraw = true
  end)
end

local function commit_log_tooltip(commit)
  local path = repo_path()
  if not path or state.repo_path ~= path or not commit then
    return ""
  end
  local hash = commit.hash
  if not hash then return "" end
  if state.commit_logs[hash] then return state.commit_logs[hash] end
  if not state.pending_commit_logs[hash] then
    state.pending_commit_logs[hash] = true
    core.add_thread(function()
      local text, err = git.commit_log(path, hash, true)
      if state.repo_path ~= path or repo_path() ~= path or not state.pending_commit_logs[hash] then return end
      state.pending_commit_logs[hash] = nil
      state.commit_logs[hash] = text or string.format("%s\n%s", hash, err or commit.author or "")
      core.redraw = true
    end)
  end
  return string.format("%s\n%s", commit.hash or "", commit.author or "")
end

local function file_label(file)
  local stats = ""
  if file.added or file.deleted then
    stats = string.format(" (+%s,-%s)", file.added or "?", file.deleted or "?")
  end
  return string.format("%s %s%s", file.status or "M", file.path, stats)
end

local function commit_label(commit)
  return string.format("%s - %s - %s",
    commit.subject or "",
    commit.short_hash or commit.hash or "",
    commit.date or "")
end

local function short_hash(commit)
  local hash = commit.short_hash or tostring(commit.hash or ""):sub(1, 7)
  if hash == "" then hash = "unknown" end
  return safe_part(hash)
end

local function repo_file_path(file)
  local rel = tostring(file and file.path or ""):gsub("\\", "/")
  local parts = {}
  for part in rel:gmatch("[^/]+") do
    if part ~= "" and part ~= "." and part ~= ".." then
      parts[#parts + 1] = safe_part(part)
    end
  end
  if #parts == 0 then parts[1] = "_file" end
  return table.concat(parts, PATHSEP)
end

local function cache_path(path, commit, file)
  local dir = cache_root .. PATHSEP .. safe_part(path) .. PATHSEP .. short_hash(commit)
  return dir .. PATHSEP .. repo_file_path(file)
end

local function write_snapshot(path, commit, file)
  if not path or state.repo_path ~= path then
    return nil, "Project changed; reloading git history"
  end
  local text, err = git.commit_file_content(path, commit.hash, file, true)
  if not text then return nil, err end
  if state.repo_path ~= path or repo_path() ~= path then
    return nil, "Project changed; reloading git history"
  end
  local filename = cache_path(path, commit, file)
  local ok, mkdir_err = ensure_dir(common.dirname(filename))
  if not ok then return nil, mkdir_err end
  local fp = io.open(filename, "wb")
  if not fp then return nil, "Could not write " .. filename end
  fp:write(text)
  fp:close()
  return filename
end

attach_context = function(view, path, commit, file)
  if not view then return end
  view.devhq_commit_diff = {
    repo = path,
    commit = commit.hash,
    file = {
      path = file.path,
      old_path = file.old_path,
      status = file.status,
      status_code = file.status_code,
    },
  }
  view.devhq_diff_key = nil
end

local function open_file(commit, file, ephemeral)
  local path = repo_path()
  if not path or state.repo_path ~= path then
    return core.error("Could not open commit file: %s", "Project changed; reloading git history")
  end
  core.add_thread(function()
    local filename, err = write_snapshot(path, commit, file)
    if not filename then return core.error("Could not open commit file: %s", err or "unknown error") end
    if state.repo_path ~= path or repo_path() ~= path then return end
    activate_previous_editor()
    local doc = core.open_doc(filename)
    local persistent = has_persistent_view(doc)
    local node = get_view_node(ephemeral_view)
    if node and ephemeral_view.doc == doc and not persistent then
      if not ephemeral then promote_ephemeral(ephemeral_view) end
      node:set_active_view(ephemeral_view)
      return
    end
    if node and not persistent then
      local view = replace_ephemeral(doc, ephemeral, path, commit, file)
      if view then return end
    end
    if not persistent then
      close_ephemeral(doc)
    end
    local view = core.root_view:open_doc(doc)
    if view and view:extends(DocView) then
      attach_context(view, path, commit, file)
      if ephemeral and not persistent then
        view._devhq_history_ephemeral = true
        view._devhq_ephemeral = true
        ephemeral_view = view
      else
        promote_ephemeral(view)
      end
    end
    core.redraw = true
  end)
end

local function italic_font(font)
  if not style._devhq_ephemeral_font
      or style._devhq_ephemeral_font_base ~= font
      or style._devhq_ephemeral_font_size ~= font:get_size() then
    style._devhq_ephemeral_font = font:copy(font:get_size(), { italic = true })
    style._devhq_ephemeral_font_base = font
    style._devhq_ephemeral_font_size = font:get_size()
  end
  return style._devhq_ephemeral_font
end

local function install_ephemeral_hooks()
  if M._devhq_history_ephemeral_hooks then return end
  M._devhq_history_ephemeral_hooks = true

  local doc_on_text_change = Doc.on_text_change
  function Doc:on_text_change(...)
    promote_ephemeral((ephemeral_view and ephemeral_view.doc == self) and ephemeral_view)
    return doc_on_text_change(self, ...)
  end

  local node_draw_tab_title = Node.draw_tab_title
  function Node:draw_tab_title(view, font, ...)
    if view and view._devhq_history_ephemeral then
      font = italic_font(font)
    end
    return node_draw_tab_title(self, view, font, ...)
  end

  local root_on_mouse_pressed = RootView.on_mouse_pressed
  function RootView:on_mouse_pressed(button, x, y, clicks)
    local node = self.root_node:get_child_overlapping_point(x, y)
    local idx = node and node:get_tab_overlapping_point(x, y)
    if button == "left" and clicks > 1 and idx and node.hovered_close ~= idx then
      promote_ephemeral(node.views[idx])
    end
    return root_on_mouse_pressed(self, button, x, y, clicks)
  end

  local comments = core.devhq_comments
  if comments and not comments._devhq_history_ephemeral_hooks then
    comments._devhq_history_ephemeral_hooks = true
    local add_comment = comments.add_comment
    function comments.add_comment(...)
      promote_ephemeral(core.active_view)
      return add_comment(...)
    end
  end
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
        label = commit_label(commit),
        tooltip = function(node) return commit_log_tooltip(node.commit) end,
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
              open = function(child, clicks) open_file(child.commit, child.file, (clicks or 1) < 2) end,
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
  install_ephemeral_hooks()
  if state.view then
    if state.original_view and state.view then replace_view(state.view, state.original_view) end
    state.view = nil
    state.original_view = nil
    core.redraw = true
    return
  end
  reset_history(repo_path())
  local view = TreeView({ backend = backend, default_expanded = false })
  view.activate_on_single_click = true
  view._devhq_git_history = true
  state.view = view
  state.original_view = default_treeview
  if not replace_view(default_treeview, view) then
    local node = core.root_view.root_node:get_node_for_view(default_treeview)
    view.node = node:split("left", view, { x = true }, true)
  end
  load_history(true)
  core.redraw = true
end

install_ephemeral_hooks()

return M
