-- mod-version:3

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local View = require "core.view"

local TreeView = View:extend()

local tooltip_offset = style.font:get_height()
local tooltip_border = 1
local tooltip_delay = 0.5
local tooltip_alpha = 255
local tooltip_alpha_rate = 1

local function replace_alpha(color, alpha)
  local r, g, b = table.unpack(color)
  return { r, g, b, alpha }
end

local function call(value, ...)
  if type(value) == "function" then
    return value(...)
  end
  return value
end

local function split_lines(text)
  local lines = {}
  text = tostring(text or ""):gsub("\r\n", "\n")
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  for line in text:gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return #lines > 0 and lines or { "" }
end

local function sorted_children(children)
  local list = {}
  if type(children) ~= "table" then
    return list
  end
  local is_array = #children > 0
  if is_array then
    for _, child in ipairs(children) do
      list[#list + 1] = child
    end
  else
    for _, child in pairs(children) do
      list[#list + 1] = child
    end
  end
  table.sort(list, function(a, b)
    if a.order ~= nil or b.order ~= nil then
      return (a.order or 0) < (b.order or 0)
    end
    local ak = a.kind or a.type
    local bk = b.kind or b.type
    if ak ~= bk then
      return ak == "dir"
    end
    return tostring(a.label or a.name or a.id or "") < tostring(b.label or b.name or b.id or "")
  end)
  return list
end

function TreeView:__tostring()
  return "TreeView"
end

function TreeView:new(opts)
  TreeView.super.new(self)
  opts = opts or {}
  self.scrollable = true
  self.visible = opts.visible ~= false
  self.init_size = true
  self.target_size = opts.size or 200 * SCALE
  self.backend = opts.backend or {}
  self.cache = {}
  self.expanded = opts.expanded or {}
  self.default_expanded = opts.default_expanded
  self.selected_item = nil
  self.selected_id = nil
  self.hovered_item = nil
  self.tooltip = { x = 0, y = 0, begin = 0, alpha = 0 }
  self.last_scroll_y = 0
  self.item_icon_width = 0
  self.item_text_spacing = 0
  self.embedded = opts.embedded == true
  self.activate_on_single_click = opts.activate_on_single_click == true
  self.bounds = nil
end

function TreeView:set_backend(backend)
  self.backend = backend or {}
  self.selected_item = nil
  self.selected_id = nil
  self.hovered_item = nil
end

function TreeView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function TreeView:set_bounds(x, y, w, h)
  self.bounds = { x = x, y = y, w = w, h = h }
  self.position.x = x
  self.position.y = y
  self.size.x = w
  self.size.y = h
end

function TreeView:get_name()
  return nil
end

function TreeView:get_item_height()
  return style.font:get_height() + style.padding.y
end

function TreeView:get_node_id(node)
  return node and (node.id or node.path or node.label or node.name or tostring(node))
end

function TreeView:get_node_label(node)
  return tostring(node and (node.label or node.name or node.id) or "")
end

function TreeView:get_node_kind(node)
  return node and (node.kind or node.type) or "custom"
end

function TreeView:get_node_children(node)
  return sorted_children(call(node and node.children, node))
end

function TreeView:can_expand(node)
  if not node then
    return false
  end
  if node.can_expand ~= nil then
    return not not call(node.can_expand, node)
  end
  return self:get_node_kind(node) == "dir" or node.children ~= nil
end

function TreeView:is_expanded(node)
  if not self:can_expand(node) then
    return false
  end
  if node.is_expanded ~= nil then
    return not not call(node.is_expanded, node)
  end
  local id = self:get_node_id(node)
  if self.expanded[id] ~= nil then
    return self.expanded[id]
  end
  return self.default_expanded ~= false
end

function TreeView:set_expanded(node, expanded)
  if not self:can_expand(node) then
    return
  end
  if node.set_expanded then
    node.set_expanded(node, expanded)
    return
  end
  self.expanded[self:get_node_id(node)] = expanded
end

function TreeView:get_roots()
  return sorted_children(call(self.backend.roots, self.backend) or {})
end

function TreeView:rows()
  local rows = {}
  local function walk(node, depth, parent)
    local row = { node = node, depth = depth, parent = parent }
    rows[#rows + 1] = row
    if self:is_expanded(node) then
      for _, child in ipairs(self:get_node_children(node)) do
        walk(child, depth + 1, row)
      end
    end
  end
  for _, root in ipairs(self:get_roots()) do
    walk(root, 0, nil)
  end
  return rows
end

function TreeView:each_item()
  return coroutine.wrap(function()
    local ox, oy = self:get_content_offset()
    local h = self:get_item_height()
    local count_lines = 0
    for _, item in ipairs(self:rows()) do
      coroutine.yield(item, ox, oy + style.padding.y + h * count_lines, self.size.x, h)
      count_lines = count_lines + 1
    end
    self.count_lines = count_lines
  end)
end

function TreeView:set_selection(selection, selection_y, center, instant)
  self.selected_item = selection
  self.selected_id = selection and self:get_node_id(selection.node) or nil
  if selection and selection_y and (selection_y <= self.position.y or selection_y >= self.position.y + self.size.y) then
    local lh = self:get_item_height()
    local visible_y = selection_y - self.position.y
    if not center and visible_y >= self.size.y - lh then
      visible_y = visible_y - self.size.y + lh
    end
    if center then
      visible_y = visible_y - (self.size.y - lh) / 2
    end
    self.scroll.to.y = common.clamp(self.scroll.y + visible_y, 0, math.max(0, self:get_scrollable_size() - self.size.y))
    if instant then
      self.scroll.y = self.scroll.to.y
    end
  end
end

function TreeView:set_selection_to_id(id, expand, scroll_to, instant)
  local selected, selected_y
  for item, _, y in self:each_item() do
    if self:get_node_id(item.node) == id then
      selected, selected_y = item, y
      break
    end
  end
  if selected then
    self:set_selection(selected, scroll_to and selected_y, true, instant)
  end
  return selected
end

function TreeView:get_text_bounding_box(item, x, y, w, h)
  local icon_width = style.icon_font:get_width("D")
  local xoffset = item.depth * style.padding.x + style.padding.x + icon_width
  x = x + xoffset
  w = style.font:get_width(self:get_node_label(item.node)) + 2 * style.padding.x
  return x, y, w, h
end

function TreeView:on_mouse_moved(px, py, ...)
  if not self.visible then return end
  if not self.embedded and TreeView.super.on_mouse_moved(self, px, py, ...) then
    self.hovered_item = nil
    return true
  end

  local item_changed, tooltip_changed
  for item, x, y, w, h in self:each_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      item_changed = true
      self.hovered_item = item
      x, y, w, h = self:get_text_bounding_box(item, x, y, w, h)
      if px > x and py > y and px <= x + w and py <= y + h then
        tooltip_changed = true
        self.tooltip.x, self.tooltip.y = px, py
        self.tooltip.begin = system.get_time()
      end
      break
    end
  end
  if not item_changed then self.hovered_item = nil end
  if not tooltip_changed then self.tooltip.x, self.tooltip.y = nil, nil end
  return item_changed
end

function TreeView:on_mouse_left()
  TreeView.super.on_mouse_left(self)
  self.hovered_item = nil
end

function TreeView:on_mouse_pressed(button, x, y, clicks)
  if button ~= "left" then
    return TreeView.super.on_mouse_pressed(self, button, x, y, clicks)
  end
  for item, ix, iy, iw, ih in self:each_item() do
    if x > ix and y > iy and x <= ix + iw and y <= iy + ih then
      self:set_selection(item, iy)
      if self.activate_on_single_click or (clicks and clicks > 1) then
        self:open_selected(clicks)
      end
      return true
    end
  end
end

function TreeView:on_mouse_wheel(y, x)
  local amount = y * self:get_item_height() * 3
  local max_scroll = math.max(0, self:get_scrollable_size() - self.size.y)
  self.scroll.y = common.clamp((self.scroll.y or 0) - amount, 0, max_scroll)
  self.scroll.to.y = self.scroll.y
  core.redraw = true
  return true
end

function TreeView:update()
  local dest = self.visible and self.target_size or 0
  if not self.embedded then
    if self.init_size then
      self.size.x = dest
      self.init_size = false
    else
      self:move_towards(self.size, "x", dest, nil, "treeview")
    end
  end

  if self.size.x == 0 or self.size.y == 0 or not self.visible then return end

  local max_scroll = math.max(0, self:get_scrollable_size() - self.size.y)
  self.scroll.y = common.clamp(self.scroll.y or 0, 0, max_scroll)
  self.scroll.to.y = common.clamp(self.scroll.to.y or self.scroll.y, 0, max_scroll)

  local duration = system.get_time() - self.tooltip.begin
  if self.hovered_item and self.tooltip.x and duration > tooltip_delay then
    self:move_towards(self.tooltip, "alpha", tooltip_alpha, tooltip_alpha_rate, "treeview")
  else
    self.tooltip.alpha = 0
  end

  self.item_icon_width = style.icon_font:get_width("D")
  self.item_text_spacing = style.icon_font:get_width("f") / 2

  if not self.embedded then
    TreeView.super.update(self)
  end
end

function TreeView:get_scrollable_size()
  local count_lines = self.count_lines or #self:rows()
  return self:get_item_height() * (count_lines + 1)
end

function TreeView:draw_tooltip()
  local node = self.hovered_item and self.hovered_item.node
  local text = call(node and node.tooltip, node) or self:get_node_label(node)
  local lines = split_lines(text)
  local line_h = style.font:get_height()
  local w, h = 0, line_h * #lines
  for _, line in ipairs(lines) do
    w = math.max(w, style.font:get_width(line))
  end

  local x, y = self.tooltip.x + tooltip_offset, self.tooltip.y + tooltip_offset
  w, h = w + style.padding.x, h + style.padding.y

  if x + w > core.root_view.root_node.size.x then
    x = x - w
  end

  local bx, by = x - tooltip_border, y - tooltip_border
  local bw, bh = w + 2 * tooltip_border, h + 2 * tooltip_border
  renderer.draw_rect(bx, by, bw, bh, replace_alpha(style.text, self.tooltip.alpha))
  renderer.draw_rect(x, y, w, h, replace_alpha(style.background2, self.tooltip.alpha))
  local color = replace_alpha(style.text, self.tooltip.alpha)
  local text_x = x + style.padding.x / 2
  local text_y = y + style.padding.y / 2
  for i, line in ipairs(lines) do
    renderer.draw_text(style.font, line, text_x, text_y + (i - 1) * line_h, color)
  end
end

function TreeView:get_item_icon(item, active, hovered)
  local node = item.node
  if node and node.icon then
    local character, font, color = node.icon(self:is_expanded(node), active, hovered)
    if character then
      return character, font or style.icon_font, color or style.text
    end
  end
  local character = "f"
  if self:can_expand(node) then
    character = self:is_expanded(node) and "D" or "d"
  end
  local color = (active or hovered) and style.accent or style.text
  return character, style.icon_font, color
end

function TreeView:get_item_text(item, active, hovered)
  local node = item.node
  local text = self:get_node_label(node)
  local font = style.font
  local color = (active or hovered) and style.accent or style.text
  if node and node.color then
    color = call(node.color, node, active, hovered) or color
  end
  return text, font, color
end

function TreeView:draw_item_text(item, active, hovered, x, y, w, h)
  local item_text, item_font, item_color = self:get_item_text(item, active, hovered)
  common.draw_text(item_font, item_color, item_text, nil, x, y, 0, h)
end

function TreeView:draw_item_icon(item, active, hovered, x, y, w, h)
  local icon_char, icon_font, icon_color = self:get_item_icon(item, active, hovered)
  common.draw_text(icon_font, icon_color, icon_char, nil, x, y, 0, h)
  return self.item_icon_width + self.item_text_spacing
end

function TreeView:draw_item_body(item, active, hovered, x, y, w, h)
  x = x + self:draw_item_icon(item, active, hovered, x, y, w, h)
  self:draw_item_text(item, active, hovered, x, y, w, h)
end

function TreeView:draw_item_chevron(item, active, hovered, x, y, w, h)
  if self:can_expand(item.node) then
    local chevron_icon = self:is_expanded(item.node) and "-" or "+"
    local chevron_color = hovered and style.accent or style.text
    common.draw_text(style.icon_font, chevron_color, chevron_icon, nil, x, y, 0, h)
  end
  return style.padding.x
end

function TreeView:draw_item_background(item, active, hovered, x, y, w, h)
  if hovered then
    local hover_color = { table.unpack(style.line_highlight) }
    hover_color[4] = 160
    renderer.draw_rect(x, y, w, h, hover_color)
  elseif active then
    renderer.draw_rect(x, y, w, h, style.line_highlight)
  end
end

function TreeView:draw_item(item, active, hovered, x, y, w, h)
  self:draw_item_background(item, active, hovered, x, y, w, h)
  x = x + item.depth * style.padding.x + style.padding.x
  x = x + self:draw_item_chevron(item, active, hovered, x, y, w, h)
  self:draw_item_body(item, active, hovered, x, y, w, h)
end

function TreeView:draw()
  if not self.visible then return end
  if not self.embedded then
    self:draw_background(style.background2)
  end
  local _y, _h = self.position.y, self.size.y

  for item, x, y, w, h in self:each_item() do
    if y + h >= _y and y < _y + _h then
      self:draw_item(item, self:get_node_id(item.node) == self.selected_id, item == self.hovered_item, x, y, w, h)
    end
  end

  if not self.embedded then
    self:draw_scrollbar()
  end
  if self.hovered_item and self.tooltip.x and self.tooltip.alpha > 0 then
    core.root_view:defer_draw(self.draw_tooltip, self)
  end
end

function TreeView:get_item(item, where)
  local last_item, last_x, last_y, last_w, last_h
  local stop = false
  local item_id = item and self:get_node_id(item.node) or self.selected_id
  for it, x, y, w, h in self:each_item() do
    if not item and where >= 0 then
      return it, x, y, w, h
    end
    if item == it or (item_id and self:get_node_id(it.node) == item_id) then
      if where < 0 and last_item then
        break
      elseif where == 0 or (where < 0 and not last_item) then
        return it, x, y, w, h
      end
      stop = true
    elseif stop then
      return it, x, y, w, h
    end
    last_item, last_x, last_y, last_w, last_h = it, x, y, w, h
  end
  return last_item, last_x, last_y, last_w, last_h
end

function TreeView:get_next(item)
  return self:get_item(item, 1)
end

function TreeView:get_previous(item)
  return self:get_item(item, -1)
end

function TreeView:get_parent(item)
  local parent = item and item.parent
  if not parent then return end
  for it, _, y in self:each_item() do
    if it == parent or self:get_node_id(it.node) == self:get_node_id(parent.node) then
      return it, y
    end
  end
end

function TreeView:toggle_expand(toggle, item)
  item = item or self.selected_item
  if not item then return end
  local node = item.node
  if self:can_expand(node) then
    if type(toggle) == "boolean" then
      self:set_expanded(node, toggle)
    else
      self:set_expanded(node, not self:is_expanded(node))
    end
  end
end

function TreeView:open_selected(clicks)
  local item = self.selected_item
  if not item then return end
  local node = item.node
  if self:can_expand(node) then
    self:toggle_expand(nil, item)
    if node.open_on_expand and node.open then
      return node.open(node, clicks)
    end
  elseif node and node.open then
    return node.open(node, clicks)
  end
end

function TreeView:on_key_pressed(key)
  if key == "up" or key == "k" then
    local item, _, y = self:get_previous(self.selected_item)
    self:set_selection(item, y)
    return true
  elseif key == "down" or key == "j" then
    local item, _, y = self:get_next(self.selected_item)
    self:set_selection(item, y)
    return true
  elseif key == "left" then
    if self.selected_item then
      if self:can_expand(self.selected_item.node) and self:is_expanded(self.selected_item.node) then
        self:toggle_expand(false)
      else
        local parent, y = self:get_parent(self.selected_item)
        if parent then
          self:set_selection(parent, y)
        end
      end
    end
    return true
  elseif key == "right" then
    local item = self.selected_item
    if item and self:can_expand(item.node) then
      if self:is_expanded(item.node) then
        local next_item, _, next_y = self:get_next(item)
        if next_item and next_item.depth > item.depth then
          self:set_selection(next_item, next_y)
        end
      else
        self:toggle_expand(true)
      end
    end
    return true
  elseif key == "return" or key == "enter" then
    self:open_selected(2)
    return true
  elseif key == "escape" then
    self.selected_item = nil
    return true
  end
end

function TreeView:on_context_menu()
  if self.backend.context_menu then
    return self.backend.context_menu(self.hovered_item or self.selected_item, self)
  end
end

return TreeView
