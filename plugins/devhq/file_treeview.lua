-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local style = require "core.style"
local Doc = require "core.doc"
local DocView = require "core.docview"
local EmptyView = require "core.emptyview"
local Node = require "core.node"
local RootView = require "core.rootview"
local git = require "plugins.devhq.git"
local default_treeview = require "plugins.treeview"

local M = {}

local project_tree = {
  mode = "full",
  cache = {},
  pending = {},
  refreshed = {},
  interval = 2,
}
local ephemeral_view

local tree_modes = {
  { mode = "uncommitted", label = "Uncomm", tooltip = "Only show uncommitted changes" },
  { mode = "staged", label = "Staged", tooltip = "Only show staged changes" },
  { mode = "head", label = "HEAD", tooltip = "Only show changes from upstream to HEAD" },
  { mode = "full", label = "Full", tooltip = "Show the full tree" },
}

local function get_depth(filename)
  local n = 1
  for _ in filename:gmatch(PATHSEP) do n = n + 1 end
  return n
end

local function start_git_refresh(path, force)
  local now = system.get_time()
  if project_tree.pending[path] then return end
  if not force and project_tree.refreshed[path] and now - project_tree.refreshed[path] < project_tree.interval then
    return
  end

  project_tree.pending[path] = true
  project_tree.refreshed[path] = now
  core.add_thread(function()
    local status = git.tree_status(path, true)
    project_tree.pending[path] = nil
    if status then
      project_tree.cache[path] = status
    end
    core.redraw = true
  end)
end

local function refresh_project_tree_git(force)
  for _, dir in ipairs(core.project_directories or {}) do
    if git.is_repo(dir.name) then
      start_git_refresh(dir.name, force)
    end
  end
end

local function path_parent(path)
  return path:match("^(.*)" .. PATHSEP .. "[^" .. PATHSEP .. "]+$")
end

local function filtered_items_for_dir(dir, status)
  local wanted = status and status.modes and status.modes[project_tree.mode] or {}
  local by_name = {}
  for rel in pairs(wanted) do
    local info = system.get_file_info(dir.name .. PATHSEP .. rel)
    if info then
      local parent = path_parent(rel)
      while parent and parent ~= "" do
        by_name[parent] = { filename = parent, type = "dir" }
        parent = path_parent(parent)
      end
      by_name[rel] = { filename = rel, type = info.type }
    end
  end

  local items = {}
  for _, item in pairs(by_name) do items[#items + 1] = item end
  table.sort(items, function(a, b)
    return system.path_compare(a.filename, a.type, b.filename, b.type)
  end)
  return items
end

local function git_info_for_item(item)
  if not item or item.topdir or item.type ~= "file" then return end
  local status = project_tree.cache[item.dir_name]
  return status and status.files and status.files[item.filename]
end

local function git_suffix(item)
  local info = git_info_for_item(item)
  if not info then return "" end
  local stats = info.stats and (
    info.stats[project_tree.mode] or info.stats.uncommitted or info.stats.staged or info.stats.head
  )
  local code = info.codes and (
    info.codes[project_tree.mode] or info.codes.uncommitted or info.codes.staged or info.codes.head
  ) or info.code or "M"
  if stats then
    return string.format(" %s (+%s,-%s)", code, stats.added or "?", stats.deleted or "?")
  end
  return " " .. code
end

local function toolbar_height()
  return style.font:get_height() + style.padding.y * 2
end

local function each_toolbar_item(view)
  local ox, oy = view.position.x, view.position.y
  local h = style.font:get_height() + style.padding.y * 2
  local w = math.floor(view.size.x / #tree_modes)
  local i = 0
  return function()
    i = i + 1
    local mode = tree_modes[i]
    if mode then return mode, ox + (i - 1) * w, oy, i == #tree_modes and view.size.x - (i - 1) * w or w, h end
  end
end

local function toolbar_item_at(view, px, py)
  for item, x, y, w, h in each_toolbar_item(view) do
    if px > x and py > y and px <= x + w and py <= y + h then
      return item
    end
  end
end

local function draw_toolbar(view)
  renderer.draw_rect(view.position.x, view.position.y, view.size.x, toolbar_height(), style.background2)
  for item, x, y, w, h in each_toolbar_item(view) do
    local active = project_tree.mode == item.mode
    local hovered = view._devhq_filter_hovered_item == item
    if active then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
    elseif hovered then
      local color = { table.unpack(style.line_highlight) }
      color[4] = 120
      renderer.draw_rect(x, y, w, h, color)
    end
    common.draw_text(style.font, active and style.accent or style.text, item.label, "center", x, y, w, h)
  end
end

local function get_view_node(view)
  return view and core.root_view.root_node:get_node_for_view(view)
end

local function promote_ephemeral(view)
  if not (view and view._devhq_ephemeral) then return end
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
    if not view._devhq_ephemeral then return true end
  end
end

local function replace_ephemeral(doc, ephemeral)
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
  if ephemeral then
    view._devhq_ephemeral = true
    ephemeral_view = view
  else
    ephemeral_view = nil
  end
  old_view._devhq_ephemeral = nil
  core.root_view.root_node:update_layout()
  core.redraw = true
  return view
end

local function activate_previous_editor()
  if core.last_active_view and core.active_view == default_treeview then
    core.set_active_view(core.last_active_view)
  end
end

local function promote_ephemeral_item(item)
  local view, node = ephemeral_view, get_view_node(ephemeral_view)
  local doc_filename = core.normalize_to_project_dir(item.abs_filename)
  local abs_filename = core.project_absolute_path(doc_filename)
  if not (view and node and view.doc and view.doc.abs_filename == abs_filename) then
    return false
  end
  promote_ephemeral(view)
  node:set_active_view(view)
  return true
end

local function open_file_item(item, ephemeral)
  if not ephemeral and promote_ephemeral_item(item) then return core.active_view end
  activate_previous_editor()
  local doc_filename = core.normalize_to_project_dir(item.abs_filename)
  local doc = core.open_doc(doc_filename)
  local persistent = has_persistent_view(doc)
  local node = get_view_node(ephemeral_view)
  if node and ephemeral_view.doc == doc and not persistent then
    if ephemeral then
      node:set_active_view(ephemeral_view)
    else
      promote_ephemeral(ephemeral_view)
      node:set_active_view(ephemeral_view)
    end
    return ephemeral_view
  end
  if node and not persistent then
    local view = replace_ephemeral(doc, ephemeral)
    if view then return view end
  end
  if not persistent then
    close_ephemeral(doc)
  end
  local view = core.root_view:open_doc(doc)
  if ephemeral and not persistent then
    view._devhq_ephemeral = true
    ephemeral_view = view
  else
    promote_ephemeral(view)
  end
  return view
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

local function install_project_tree_filter()
  if default_treeview._devhq_filter_originals then return end

  local originals = {
    update = default_treeview.update,
    each_item = default_treeview.each_item,
    get_item_text = default_treeview.get_item_text,
    get_text_bounding_box = default_treeview.get_text_bounding_box,
    get_content_offset = default_treeview.get_content_offset,
    get_scrollable_size = default_treeview.get_scrollable_size,
    draw = default_treeview.draw,
    on_mouse_pressed = default_treeview.on_mouse_pressed,
    on_mouse_moved = default_treeview.on_mouse_moved,
    on_mouse_left = default_treeview.on_mouse_left,
    doc_on_text_change = Doc.on_text_change,
    node_draw_tab_title = Node.draw_tab_title,
    root_on_mouse_pressed = RootView.on_mouse_pressed,
  }
  default_treeview._devhq_filter_originals = originals

  function default_treeview:update(...)
    refresh_project_tree_git(false)
    return originals.update(self, ...)
  end

  function default_treeview:get_content_offset()
    local x, y = originals.get_content_offset(self)
    return x, y + toolbar_height()
  end

  function default_treeview:get_scrollable_size()
    return originals.get_scrollable_size(self) + toolbar_height()
  end

  function default_treeview:each_item()
    if project_tree.mode == "full" then
      return originals.each_item(self)
    end

    return coroutine.wrap(function()
      self:check_cache()
      local count_lines = 0
      local ox, oy = self:get_content_offset()
      local y = oy + style.padding.y
      local w = self.size.x
      local h = self:get_item_height()

      for _, dir in ipairs(core.project_directories) do
        local dir_cached = self:get_cached(dir, dir.item, dir.name)
        coroutine.yield(dir_cached, ox, y, w, h)
        count_lines, y = count_lines + 1, y + h

        local status = project_tree.cache[dir.name]
        local items = dir_cached.expanded and filtered_items_for_dir(dir, status) or {}
        local i = 1
        while i <= #items do
          local cached = self:get_cached(dir, items[i], dir.name)
          coroutine.yield(cached, ox, y, w, h)
          count_lines, y = count_lines + 1, y + h
          i = i + 1

          if cached.type == "dir" and not cached.expanded then
            local depth = cached.depth
            while i <= #items and get_depth(items[i].filename) > depth do
              i = i + 1
            end
          end
        end
      end
      self.count_lines = count_lines
    end)
  end

  function default_treeview:get_item_text(item, active, hovered)
    local text, font, color = originals.get_item_text(self, item, active, hovered)
    return text .. git_suffix(item), font, color
  end

  function default_treeview:draw(...)
    originals.draw(self, ...)
    draw_toolbar(self)
  end

  function default_treeview:on_mouse_pressed(button, x, y, clicks)
    local item = toolbar_item_at(self, x, y)
    if item then
      if button == "left" then
        project_tree.mode = item.mode
        self.selected_item = nil
        refresh_project_tree_git(true)
        core.redraw = true
      end
      return true
    end
    return originals.on_mouse_pressed(self, button, x, y, clicks)
  end

  function default_treeview:on_mouse_moved(px, py, ...)
    local item = toolbar_item_at(self, px, py)
    if item then
      self.hovered_item = nil
      self._devhq_filter_hovered_item = item
      self.tooltip.x, self.tooltip.y = nil, nil
      core.status_view:show_tooltip(item.tooltip)
      self._devhq_filter_tooltip = true
      return
    end
    if self._devhq_filter_tooltip then
      core.status_view:remove_tooltip()
      self._devhq_filter_tooltip = false
    end
    self._devhq_filter_hovered_item = nil
    return originals.on_mouse_moved(self, px, py, ...)
  end

  function default_treeview:on_mouse_left(...)
    if self._devhq_filter_tooltip then core.status_view:remove_tooltip() end
    self._devhq_filter_tooltip = false
    self._devhq_filter_hovered_item = nil
    return originals.on_mouse_left(self, ...)
  end

  function default_treeview:get_text_bounding_box(item, x, y, w, h)
    x, y, w, h = originals.get_text_bounding_box(self, item, x, y, w, h)
    local text, font = self:get_item_text(item, false, false)
    return x, y, font:get_width(text) + 2 * style.padding.x, h
  end

  function Doc:on_text_change(...)
    promote_ephemeral((ephemeral_view and ephemeral_view.doc == self) and ephemeral_view)
    return originals.doc_on_text_change(self, ...)
  end

  function Node:draw_tab_title(view, font, ...)
    if view and view._devhq_ephemeral then
      font = italic_font(font)
    end
    return originals.node_draw_tab_title(self, view, font, ...)
  end

  function RootView:on_mouse_pressed(button, x, y, clicks)
    local node = self.root_node:get_child_overlapping_point(x, y)
    local idx = node and node:get_tab_overlapping_point(x, y)
    if button == "left" and clicks > 1 and idx and node.hovered_close ~= idx then
      promote_ephemeral(node.views[idx])
    end
    return originals.root_on_mouse_pressed(self, button, x, y, clicks)
  end

  command.add(nil, {
    ["treeview-filter:full"] = function() project_tree.mode = "full"; refresh_project_tree_git(false); core.redraw = true end,
    ["treeview-filter:uncommitted"] = function() project_tree.mode = "uncommitted"; refresh_project_tree_git(true); core.redraw = true end,
    ["treeview-filter:staged"] = function() project_tree.mode = "staged"; refresh_project_tree_git(true); core.redraw = true end,
    ["treeview-filter:head"] = function() project_tree.mode = "head"; refresh_project_tree_git(true); core.redraw = true end,
  })

  command.add(function()
    return core.active_view == default_treeview
  end, {
    ["treeview:select-and-open"] = function(_, _, clicks)
      local view = default_treeview
      if not view.hovered_item then return end
      view:set_selection(view.hovered_item)
      if view.hovered_item.type == "dir" then
        command.perform "treeview:open"
      else
        core.try(function()
          open_file_item(view.hovered_item, (clicks or 1) < 2)
        end)
      end
    end,
  })
end

function M.setup()
  install_project_tree_filter()
  refresh_project_tree_git(true)
end

return M
