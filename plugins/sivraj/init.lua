-- mod-version:3

local core = require "core"

for _, loaded_view in ipairs(core.root_view.root_node:get_children()) do
  if loaded_view._sivraj_treeview then
    return loaded_view
  end
end

local TreeView = require "libraries.generic_treeview"
local default_treeview = require "plugins.treeview"
local view = TreeView()
local node = core.root_view.root_node:get_node_for_view(default_treeview)

view._sivraj_treeview = true
view.node = node:split("left", view, { x = true }, true)

return view
