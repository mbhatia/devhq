-- mod-version:3

local core = require "core"
local command = require "core.command"
local TreeView = require "libraries.generic_treeview"
local default_treeview = require "plugins.treeview"

local function find_sidebar()
  for _, loaded_view in ipairs(core.root_view.root_node:get_children()) do
    if loaded_view._sivraj_treeview then
      return loaded_view
    end
  end
end

local function ensure_sidebar()
  local view = find_sidebar()
  if view then
    return view
  end

  local node = core.root_view.root_node:get_node_for_view(default_treeview)
  view = TreeView()
  view._sivraj_treeview = true
  view.node = node:split("left", view, { x = true }, true)
  return view
end

command.add(nil, {
  ["sivraj:toggle-sidebar"] = function()
    local view = find_sidebar()
    if view then
      view.visible = not view.visible
    else
      ensure_sidebar().visible = true
    end
    core.redraw = true
  end,
})

return ensure_sidebar()
