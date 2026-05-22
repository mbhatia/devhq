-- mod-version:3

local core = require "core"
local TreeView = require "libraries.generic_treeview"
local default_treeview = require "plugins.treeview"

local view = TreeView()
local node = core.root_view.root_node:get_node_for_view(default_treeview)
view.node = node:split("left", view, { x = true }, true)

return view
