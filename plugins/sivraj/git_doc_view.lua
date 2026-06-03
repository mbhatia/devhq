-- mod-version:3

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local DocView = require "core.docview"
local style = require "core.style"
local renderer = require "renderer"
local git = require "plugins.sivraj.git"

local M = {}
core.sivraj_git_doc_view = M

config.plugins.sivraj = config.plugins.sivraj or {}
config.plugins.sivraj.git_diff_overlay = config.plugins.sivraj.git_diff_overlay ~= false

style.sivraj_diff_addition = style.sivraj_diff_addition or { common.color "#587c0c" }
style.sivraj_diff_modification = style.sivraj_diff_modification or { common.color "#0c7d9d" }
style.sivraj_diff_deletion = style.sivraj_diff_deletion or { common.color "#94151b" }
style.sivraj_diff_marker_width = style.sivraj_diff_marker_width or math.max(3, SCALE or 1)
style.sivraj_diff_marker_gap = style.sivraj_diff_marker_gap or style.padding.x

local function split_lines(text)
  local lines = {}
  text = (text or ""):gsub("\r\n", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function parse_hunk_header(line)
  local old_start, old_count, new_start, new_count, scope =
    line:match("^@@%s+%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s+@@%s*(.*)$")
  if old_start then
    return {
      old_start = tonumber(old_start) or 1,
      old_count = old_count ~= "" and tonumber(old_count) or 1,
      new_start = tonumber(new_start) or 1,
      new_count = new_count ~= "" and tonumber(new_count) or 1,
      scope = scope or "",
    }
  end
end

local function color_for_kind(kind)
  if kind == "addition" then return style.sivraj_diff_addition end
  if kind == "modification" then return style.sivraj_diff_modification end
  return style.sivraj_diff_deletion
end

local function add_annotation(annotations, line, kind, hunk, line_count)
  line = common.clamp(line or 1, 1, math.max(1, line_count or 1))
  local existing = annotations[line]
  if existing then
    if existing.kind == "deletion" and kind ~= "deletion" then
      existing.kind = kind
    end
    existing.hunks[hunk] = true
    return
  end
  annotations[line] = { kind = kind, hunk = hunk, hunks = { [hunk] = true } }
end

local function build_annotations(raw, line_count)
  local annotations, hunks = {}, {}
  local hunk, old_line, new_line = nil, 0, 0
  local pending_deleted, pending_anchor, replacing_deleted = 0, nil, false

  local function flush_deleted_anchor()
    if pending_deleted > 0 and hunk then
      add_annotation(annotations, pending_anchor or new_line, "deletion", hunk, line_count)
    end
    pending_deleted, pending_anchor, replacing_deleted = 0, nil, false
  end

  for _, line in ipairs(split_lines(raw)) do
    local parsed = parse_hunk_header(line)
    if parsed then
      flush_deleted_anchor()
      hunk = {
        old_start = parsed.old_start,
        old_count = parsed.old_count,
        new_start = parsed.new_start,
        new_count = parsed.new_count,
        scope = parsed.scope,
        lines = { line },
      }
      hunks[#hunks + 1] = hunk
      old_line, new_line = parsed.old_start, parsed.new_start
    elseif hunk then
      hunk.lines[#hunk.lines + 1] = line
      if line:sub(1, 1) == "-" and not line:match("^%-{3}") then
        pending_deleted = pending_deleted + 1
        pending_anchor = new_line
        replacing_deleted = false
        old_line = old_line + 1
      elseif line:sub(1, 1) == "+" and not line:match("^%+%+%+") then
        local kind = (pending_deleted > 0 or replacing_deleted) and "modification" or "addition"
        add_annotation(annotations, new_line, kind, hunk, line_count)
        replacing_deleted = pending_deleted > 0 or replacing_deleted
        pending_deleted, pending_anchor = 0, nil
        new_line = new_line + 1
      elseif line:sub(1, 1) == " " then
        flush_deleted_anchor()
        old_line, new_line = old_line + 1, new_line + 1
      else
        flush_deleted_anchor()
      end
    end
  end
  flush_deleted_anchor()

  for _, item in ipairs(hunks) do
    item.text = table.concat(item.lines, "\n")
  end
  return annotations, hunks
end

local function enabled()
  return config.plugins.sivraj.git_diff_overlay ~= false
end

local function current_key(view)
  local context = view.sivraj_commit_diff
  if context then
    local file = view.doc and view.doc.abs_filename
    local info = file and (system.get_file_info(file) or {}) or {}
    local stamp = tostring(info.modified or "") .. ":" .. tostring(info.size or "")
    return table.concat({ "commit", context.repo or "", context.commit or "",
      context.file and context.file.path or "", file or "", stamp }, "\0"),
      context.repo, context.file, context
  end
  local file = view.doc and view.doc.abs_filename
  local root = core.project_dir
  if not file or not root or not common.path_belongs_to(file, root) then
    return nil
  end
  local info = system.get_file_info(file) or {}
  local stamp = tostring(info.modified or "") .. ":" .. tostring(info.size or "")
  return root .. "\0" .. file .. "\0" .. stamp, root, file
end

local function clear(view)
  view.sivraj_diff_annotations = nil
  view.sivraj_diff_hunks = nil
  view.sivraj_diff_overlay = nil
  view.sivraj_diff_key = nil
  view.sivraj_diff_pending = false
  view.sivraj_diff_token = nil
end

function M.refresh(view)
  if not enabled() then
    clear(view)
    return
  end
  local key, root, file, context = current_key(view)
  if not key then
    clear(view)
    return
  end
  if view.sivraj_diff_pending or view.sivraj_diff_key == key then
    return
  end

  view.sivraj_diff_pending = true
  view.sivraj_diff_key = key
  local token = {}
  view.sivraj_diff_token = token

  core.add_thread(function()
    local raw
    if context then
      raw = git.diff_for_commit_file(root, context.commit, file, true)
    else
      raw = git.diff_against_parent(root, file, true)
    end
    if view.sivraj_diff_token ~= token then
      return
    end
    if current_key(view) ~= key then
      view.sivraj_diff_pending = false
      return
    end
    view.sivraj_diff_pending = false
    if raw then
      view.sivraj_diff_annotations, view.sivraj_diff_hunks = build_annotations(raw, view.doc and #view.doc.lines or 1)
      if view.sivraj_diff_overlay and not view.sivraj_diff_annotations[view.sivraj_diff_overlay.line] then
        view.sivraj_diff_overlay = nil
      end
    else
      view.sivraj_diff_annotations, view.sivraj_diff_hunks, view.sivraj_diff_overlay = nil, nil, nil
    end
    core.redraw = true
  end)
end

function M.marker_rect(view, line_y)
  local base_gw = DocView._sivraj_diff_originals.get_gutter_width(view)
  local marker_w = style.sivraj_diff_marker_width
  local hit_pad = math.floor(style.padding.x / 2)
  local x = view.position.x + base_gw + style.sivraj_diff_marker_gap
  return { x = x, y = line_y, w = marker_w, h = view:get_line_height(), hit_x = x - hit_pad, hit_w = marker_w + hit_pad * 2 }
end

function M.marker_at(view, x, y)
  if not enabled() or not view.sivraj_diff_annotations or not next(view.sivraj_diff_annotations) then
    return nil
  end
  local line = view:resolve_screen_position(x, y)
  local _, line_y = view:get_line_screen_position(line)
  local marker = M.marker_rect(view, line_y)
  if x < marker.hit_x or x > marker.hit_x + marker.hit_w then
    return nil
  end
  return line, view.sivraj_diff_annotations[line]
end

function M.overlay_layout(view)
  local overlay = view.sivraj_diff_overlay
  if not overlay or not overlay.hunk then return nil end

  local font = style.code_font or style.font
  local line_h = math.floor(font:get_height() * 1.25)
  local pad = style.padding.x
  local lines = split_lines(overlay.hunk.text or "")
  local max_text_w = 0
  for _, line in ipairs(lines) do
    max_text_w = math.max(max_text_w, font:get_width(line))
  end

  local gw = view:get_gutter_width()
  local max_w = math.max(180, view.size.x - gw - pad * 3)
  local w = math.min(max_w, math.max(260, max_text_w + pad * 2))
  local header_h = line_h + pad
  local body_h = math.min(math.max(line_h * 3, math.floor(view.size.y * 0.55)), math.max(line_h * 3, view.size.y - pad * 4 - header_h))
  local visible_lines = math.max(1, math.floor((body_h - pad) / line_h))
  local h = header_h + visible_lines * line_h + pad
  local lx, ly = view:get_line_screen_position(overlay.line)
  local x = math.max(view.position.x + gw + pad, math.min(lx + pad, view.position.x + view.size.x - w - pad))
  local y = math.max(view.position.y + pad, math.min(ly + view:get_line_height(), view.position.y + view.size.y - h - pad))
  local max_scroll = math.max(0, #lines - visible_lines)
  overlay.scroll = common.clamp(overlay.scroll or 0, 0, max_scroll)

  return { font = font, line_h = line_h, pad = pad, lines = lines, x = x, y = y, w = w, h = h,
    header_h = header_h, body_y = y + header_h, body_h = visible_lines * line_h,
    visible_lines = visible_lines, max_scroll = max_scroll }
end

function M.point_in_overlay(view, x, y)
  local layout = M.overlay_layout(view)
  if layout and x >= layout.x and x <= layout.x + layout.w and y >= layout.y and y <= layout.y + layout.h then
    return layout
  end
end

function M.draw_overlay(view)
  local overlay = view.sivraj_diff_overlay
  if not overlay then return end
  local layout = M.overlay_layout(view)
  if not layout then return end

  renderer.draw_rect(layout.x, layout.y, layout.w, layout.h, style.background2 or style.background)
  renderer.draw_rect(layout.x, layout.y, layout.w, math.max(2, SCALE or 1), color_for_kind(overlay.kind))
  renderer.draw_rect(layout.x, layout.y + layout.header_h, layout.w, math.max(1, SCALE or 1), style.divider or style.background3 or style.selection)
  renderer.draw_text(style.font, "git diff hunk", layout.x + layout.pad, layout.y + math.floor(layout.pad / 2), style.text)

  core.push_clip_rect(layout.x + layout.pad, layout.body_y, layout.w - layout.pad * 2, layout.body_h)
  for i = 1, layout.visible_lines do
    local line = layout.lines[(overlay.scroll or 0) + i]
    if not line then break end
    local color = style.text
    if line:sub(1, 1) == "+" and not line:match("^%+%+%+") then
      color = style.sivraj_diff_addition
    elseif line:sub(1, 1) == "-" and not line:match("^%-{3}") then
      color = style.sivraj_diff_deletion
    elseif line:match("^@@") then
      color = style.accent
    elseif line:match("^diff ") or line:match("^index ") or line:match("^%-%-%- ") or line:match("^%+%+%+ ") then
      color = style.dim
    end
    renderer.draw_text(layout.font, line, layout.x + layout.pad, layout.body_y + (i - 1) * layout.line_h, color)
  end
  core.pop_clip_rect()

  if layout.max_scroll > 0 then
    local sw = math.max(3, SCALE or 1)
    local thumb_h = math.max(layout.line_h, layout.body_h * (layout.visible_lines / #layout.lines))
    local thumb_y = layout.body_y + (layout.body_h - thumb_h) * ((overlay.scroll or 0) / layout.max_scroll)
    renderer.draw_rect(layout.x + layout.w - sw - 2, layout.body_y, sw, layout.body_h, style.background3 or style.selection)
    renderer.draw_rect(layout.x + layout.w - sw - 2, thumb_y, sw, thumb_h, style.dim)
  end
end

function M.toggle()
  config.plugins.sivraj.git_diff_overlay = not enabled()
  for _, view in ipairs(core.root_view.root_node:get_children()) do
    if view.doc then
      local context = view.sivraj_commit_diff
      clear(view)
      view.sivraj_commit_diff = context
    end
  end
  core.redraw = true
end

function M.setup()
  if DocView._sivraj_diff_originals then return end
  local originals = {
    update = DocView.update,
    get_gutter_width = DocView.get_gutter_width,
    draw_line_gutter = DocView.draw_line_gutter,
    on_mouse_pressed = DocView.on_mouse_pressed,
    on_mouse_moved = DocView.on_mouse_moved,
    on_mouse_wheel = DocView.on_mouse_wheel,
    draw_overlay = DocView.draw_overlay,
  }
  DocView._sivraj_diff_originals = originals

  function DocView:update(...)
    core.sivraj_git_doc_view.refresh(self)
    return originals.update(self, ...)
  end

  function DocView:get_gutter_width()
    local gw, gpad = originals.get_gutter_width(self)
    if enabled() and self.sivraj_diff_annotations and next(self.sivraj_diff_annotations) then
      return gw + style.sivraj_diff_marker_gap + style.sivraj_diff_marker_width + style.padding.x, gpad
    end
    return gw, gpad
  end

  function DocView:draw_line_gutter(line, x, y, width)
    local base_gw, base_gpad = originals.get_gutter_width(self)
    local lh = originals.draw_line_gutter(self, line, x, y, base_gpad and base_gw - base_gpad or base_gw)
    local annotation = enabled() and self.sivraj_diff_annotations and self.sivraj_diff_annotations[line]
    if annotation then
      local marker = core.sivraj_git_doc_view.marker_rect(self, y)
      if annotation.kind == "deletion" then
        renderer.draw_rect(marker.x - marker.w, y + math.floor((lh or self:get_line_height()) / 2), marker.w * 2, math.max(2, SCALE or 1), color_for_kind(annotation.kind))
      else
        renderer.draw_rect(marker.x, y, marker.w, lh or self:get_line_height(), color_for_kind(annotation.kind))
      end
    end
    return lh
  end

  function DocView:on_mouse_pressed(button, x, y, clicks)
    if button == "left" then
      local line, annotation = core.sivraj_git_doc_view.marker_at(self, x, y)
      if annotation then
        self.sivraj_diff_overlay = { line = line, hunk = annotation.hunk, kind = annotation.kind, scroll = 0 }
        core.redraw = true
        return true
      elseif self.sivraj_diff_overlay then
        self.sivraj_diff_overlay = nil
        core.redraw = true
      end
    end
    return originals.on_mouse_pressed(self, button, x, y, clicks)
  end

  function DocView:on_mouse_moved(x, y, ...)
    originals.on_mouse_moved(self, x, y, ...)
    if select(2, core.sivraj_git_doc_view.marker_at(self, x, y)) then
      self.cursor = "hand"
    end
  end

  function DocView:on_mouse_wheel(y, x)
    local mouse = core.root_view and core.root_view.mouse
    local layout = mouse and core.sivraj_git_doc_view.point_in_overlay(self, mouse.x, mouse.y)
    if layout and layout.max_scroll > 0 then
      self.sivraj_diff_overlay.scroll = common.clamp(math.floor((self.sivraj_diff_overlay.scroll or 0) - y + 0.5), 0, layout.max_scroll)
      core.redraw = true
      return true
    end
    return originals.on_mouse_wheel(self, y, x)
  end

  function DocView:draw_overlay(...)
    originals.draw_overlay(self, ...)
    core.sivraj_git_doc_view.draw_overlay(self)
  end
end

return M
