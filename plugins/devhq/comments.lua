-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local keymap = require "core.keymap"
local style = require "core.style"
local DocView = require "core.docview"
local renderer = require "renderer"
local git = require "plugins.devhq.git"
local agents = require "plugins.devhq.agents"

local M = {}
core.devhq_comments = M

local comments, loaded_worktree, state_file = {}, nil, nil
local normalize_thread

style.devhq_comments = common.merge({
  marker = style.warn or { common.color "#d79921" },
  resolved_marker = style.dim,
  marker_width = math.max(4, SCALE or 1),
  marker_gap = style.padding.x,
}, style.devhq_comments)

local function escape_json(value)
  return '"' .. tostring(value or ""):gsub('[%z\1-\31\\"]', function(ch)
    local map = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return map[ch] or string.format("\\u%04x", ch:byte())
  end) .. '"'
end

local function is_array(value)
  local count = 0
  for k in pairs(value) do
    if type(k) ~= "number" then return false end
    count = math.max(count, k)
  end
  return count == #value
end

local function encode(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then return escape_json(value) end
  if is_array(value) then
    local out = {}
    for i, item in ipairs(value) do out[i] = encode(item) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys, out = {}, {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = escape_json(k) .. ":" .. encode(value[k])
  end
  return "{" .. table.concat(out, ",") .. "}"
end

local function decoder(text)
  local i = 1
  local function skip() i = (text:find("%S", i) or (#text + 1)) end
  local function parse_value()
    skip()
    local ch = text:sub(i, i)
    if ch == '"' then
      i = i + 1
      local out = {}
      while i <= #text do
        ch = text:sub(i, i)
        if ch == '"' then i = i + 1; return table.concat(out) end
        if ch == "\\" then
          local esc = text:sub(i + 1, i + 1)
          local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
          if esc == "u" then
            out[#out + 1] = "?"
            i = i + 6
          else
            out[#out + 1] = map[esc] or esc
            i = i + 2
          end
        else
          out[#out + 1] = ch
          i = i + 1
        end
      end
    elseif ch == "{" then
      i = i + 1
      local obj = {}
      skip()
      if text:sub(i, i) == "}" then i = i + 1; return obj end
      while true do
        local key = parse_value()
        skip()
        if text:sub(i, i) ~= ":" then return nil end
        i = i + 1
        obj[key] = parse_value()
        skip()
        ch = text:sub(i, i)
        if ch == "}" then i = i + 1; return obj end
        if ch ~= "," then return nil end
        i = i + 1
      end
    elseif ch == "[" then
      i = i + 1
      local arr = {}
      skip()
      if text:sub(i, i) == "]" then i = i + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value()
        skip()
        ch = text:sub(i, i)
        if ch == "]" then i = i + 1; return arr end
        if ch ~= "," then return nil end
        i = i + 1
      end
    end
    local word = text:match("^[%w%+%-%.]+", i)
    i = i + #(word or "")
    if word == "true" then return true end
    if word == "false" then return false end
    if word == "null" then return nil end
    return tonumber(word)
  end
  return parse_value()
end

local function workspace_dir()
  local dir = USERDIR .. PATHSEP .. "ws"
  if not system.get_file_info(dir) then
    local ok, err = system.mkdir(dir)
    if not ok then error("cannot create workspace directory: \"" .. tostring(err) .. "\"") end
  end
  return dir
end

local function basename_pattern(path)
  return "^" .. common.basename(path):gsub("([^%w])", "%%%1") .. "%-devhq%-comments%-(%d+)%.jsonl$"
end

local function metadata_for(filename)
  local fp = io.open(filename, "r")
  if not fp then return end
  local line = fp:read("*l")
  fp:close()
  local ok, item = pcall(decoder, line or "")
  if ok and type(item) == "table" and item.type == "meta" then return item end
end

local function comments_file_for(path)
  local dir, pattern = workspace_dir(), basename_pattern(path)
  local used = {}
  for _, file in ipairs(system.list_dir(dir) or {}) do
    local id = tonumber(file:match(pattern))
    if id then
      used[id] = true
      local full = dir .. PATHSEP .. file
      local meta = metadata_for(full)
      if meta and meta.worktree == path then return full end
    end
  end

  local id = 1
  while used[id] do id = id + 1 end
  return dir .. PATHSEP .. common.basename(path) .. "-devhq-comments-" .. tostring(id) .. ".jsonl"
end

local function load(path)
  comments = {}
  loaded_worktree = path
  state_file = comments_file_for(path)
  local fp = io.open(state_file, "r")
  if not fp then return end
  for line in fp:lines() do
    local ok, item = pcall(decoder, line)
    if ok and type(item) == "table" and item.id then
      item.worktree = path
      comments[#comments + 1] = normalize_thread(item)
    end
  end
  fp:close()
end

local function save()
  if not loaded_worktree then return end
  state_file = state_file or comments_file_for(loaded_worktree)
  local fp = io.open(state_file, "w")
  if not fp then return end
  fp:write(encode({ type = "meta", worktree = loaded_worktree }), "\n")
  for _, item in ipairs(comments) do fp:write(encode(item), "\n") end
  fp:close()
  core.redraw = true
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function normalize_thread(item)
  item.messages = type(item.messages) == "table" and item.messages or nil
  if not item.messages then
    item.messages = {}
    if item.body and item.body ~= "" then
      item.messages[#item.messages + 1] = {
        author = "user",
        body = item.body,
        state = item.state == "draft" and "draft" or "open",
        created_at = item.created_at,
        updated_at = item.updated_at,
      }
    end
    for _, reply in ipairs(type(item.replies) == "table" and item.replies or {}) do
      item.messages[#item.messages + 1] = {
        author = reply.author or "user",
        body = reply.body or "",
        state = reply.state or "open",
        created_at = reply.created_at,
        updated_at = reply.updated_at,
      }
    end
  end
  if #item.messages == 0 then
    item.messages[1] = { author = "user", body = "", state = "draft", created_at = item.created_at, updated_at = item.updated_at }
  end
  for _, message in ipairs(item.messages) do
    message.author = message.author == "agent" and "agent" or "user"
    message.state = message.state or (item.state == "draft" and "draft" or "open")
    if item.state == "resolved" and message.state == "open" then message.state = "resolved" end
  end
  item.state = item.state or "draft"
  item.body, item.replies = nil, nil
  return item
end

local function first_message(item)
  return normalize_thread(item).messages[1]
end

local function has_draft_message(item)
  for _, message in ipairs(normalize_thread(item).messages) do
    if message.state == "draft" and (message.body or "") ~= "" then return true end
  end
  return false
end

local function mark_messages_open(item)
  local changed = false
  for _, message in ipairs(normalize_thread(item).messages) do
    if message.state == "draft" then
      message.state = "open"
      message.updated_at = now()
      changed = true
    end
  end
  if changed then item.state = "open" end
  item.updated_at = now()
end

local function resolve_thread(item)
  item.state = "resolved"
  item.updated_at = now()
  for _, message in ipairs(normalize_thread(item).messages) do
    if message.state == "open" then
      message.state = "resolved"
      message.updated_at = now()
    end
  end
end

local function author_label(author)
  return author == "agent" and "agent" or "you"
end

local function marker_color(item)
  return item.state == "resolved" and style.devhq_comments.resolved_marker or style.devhq_comments.marker
end

local function worktree()
  return core.project_dir
end

local function ensure_loaded()
  local path = worktree()
  if path and path ~= loaded_worktree then load(path) end
end

local function relative_file(view)
  local file = view.doc and view.doc.abs_filename
  local root = worktree()
  if not file or not root or not common.path_belongs_to(file, root) then return nil end
  return common.relative_path(root, file), file
end

local function comment_label(item)
  local text = first_message(item).body or ""
  text = text:gsub("%s+", " ")
  if #text > 60 then text = text:sub(1, 57) .. "..." end
  return string.format("%s:%d:%d %s", item.file, item.range.start.line, item.range.start.col, text)
end

local function active_comments_for_view(view)
  ensure_loaded()
  local rel = relative_file(view)
  if not rel then return {} end
  local out = {}
  for _, item in ipairs(comments) do
    if item.worktree == worktree() and item.file == rel then
      out[#out + 1] = item
    end
  end
  return out
end

local function find_comment(id)
  for i, item in ipairs(comments) do
    if item.id == id then return item, i end
  end
end

local function remove_comment(id)
  local _, index = find_comment(id)
  if index then table.remove(comments, index); save() end
end

local function marker_rect(view, line_y)
  local base_gw = DocView._devhq_comments_originals.get_gutter_width(view)
  local marker_w = style.devhq_comments.marker_width
  local hit_pad = math.floor(style.padding.x / 2)
  local x = view.position.x + base_gw + style.devhq_comments.marker_gap
  return { x = x, y = line_y, w = marker_w, h = view:get_line_height(), hit_x = x - hit_pad, hit_w = marker_w + hit_pad * 2 }
end

local function comment_at(view, x, y)
  local line = view:resolve_screen_position(x, y)
  local _, line_y = view:get_line_screen_position(line)
  local marker = marker_rect(view, line_y)
  if x < marker.hit_x or x > marker.hit_x + marker.hit_w then return nil end
  for _, item in ipairs(active_comments_for_view(view)) do
    if item.range.start.line == line then return item end
  end
end

local function overlay_lines(item)
  local lines = { string.format("%s  %s", item.state, comment_label(item)) }
  for _, message in ipairs(normalize_thread(item).messages) do
    local state = message.state ~= "open" and (" [" .. message.state .. "]") or ""
    lines[#lines + 1] = author_label(message.author) .. state .. ": " .. (message.body or "")
  end
  return lines
end

local function overlay_layout(view)
  local overlay = view.devhq_comment_overlay
  local item = overlay and find_comment(overlay.id)
  if not item then return nil end
  local font = style.font
  local pad, line_h = style.padding.x, math.floor(style.font:get_height() * 1.35)
  local lines = overlay_lines(item)
  local max_text_w = 0
  for _, line in ipairs(lines) do max_text_w = math.max(max_text_w, font:get_width(line)) end
  max_text_w = math.max(max_text_w, font:get_width(overlay.input or ""))
  local w = math.min(math.max(320, max_text_w + pad * 2), math.max(320, view.size.x - pad * 4))
  local h = (#lines + 2) * line_h + pad * 3
  local x, y = view:get_line_screen_position(overlay.line, overlay.col)
  x = math.max(view.position.x + pad, math.min(x, view.position.x + view.size.x - w - pad))
  y = math.max(view.position.y + pad, math.min(y + view:get_line_height(), view.position.y + view.size.y - h - pad))
  return { item = item, lines = lines, x = x, y = y, w = w, h = h, pad = pad, line_h = line_h, font = font }
end

local function close_overlay(view, cancel)
  local overlay = view.devhq_comment_overlay
  if cancel and overlay and overlay.created and (overlay.input or "") == "" then
    remove_comment(overlay.id)
  end
  view.devhq_comment_overlay = nil
  view.devhq_comment_hitboxes = nil
  core.redraw = true
end

local function commit_overlay(view)
  local overlay = view.devhq_comment_overlay
  local item = overlay and find_comment(overlay.id)
  if not item then return end
  local text = overlay.input or ""
  if item.state == "draft" then
    local message = first_message(item)
    message.body, message.updated_at = text, now()
  elseif text ~= "" then
    item.messages = normalize_thread(item).messages
    item.messages[#item.messages + 1] = { author = "user", body = text, state = "draft", created_at = now(), updated_at = now() }
    if item.state == "resolved" then item.state = "open" end
    item.updated_at = now()
  end
  save()
  close_overlay(view)
end

local function resolve_overlay(view)
  local item = view.devhq_comment_overlay and find_comment(view.devhq_comment_overlay.id)
  if item then
    resolve_thread(item)
    save()
  end
  close_overlay(view)
end

local function open_overlay(view, item, created)
  view.devhq_comment_overlay = {
    id = item.id,
    line = item.range["end"].line,
    col = item.range["end"].col,
    input = item.state == "draft" and (first_message(item).body or "") or "",
    created = created,
  }
  core.set_active_view(view)
  core.redraw = true
end

local function draw_button(view, boxes, action, label, x, y, h)
  local w = style.font:get_width(label) + style.padding.x
  renderer.draw_rect(x, y, w, h, style.line_highlight)
  common.draw_text(style.font, style.text, label, "center", x, y, w, h)
  boxes[#boxes + 1] = { action = action, x = x, y = y, w = w, h = h }
  return x + w + math.floor(style.padding.x / 2)
end

function M.draw_overlay(view)
  local layout = overlay_layout(view)
  if not layout then return end
  renderer.draw_rect(layout.x, layout.y, layout.w, layout.h, style.background2 or style.background)
  renderer.draw_rect(layout.x, layout.y, layout.w, math.max(1, SCALE or 1), marker_color(layout.item))
  local y = layout.y + layout.pad
  for _, line in ipairs(layout.lines) do
    renderer.draw_text(layout.font, line, layout.x + layout.pad, y, style.text)
    y = y + layout.line_h
  end

  local input_y = y + math.floor(layout.pad / 2)
  renderer.draw_rect(layout.x + layout.pad, input_y, layout.w - layout.pad * 2, layout.line_h, style.background3 or style.line_highlight)
  renderer.draw_text(layout.font, view.devhq_comment_overlay.input or "",
    layout.x + layout.pad * 1.5, input_y + math.floor((layout.line_h - layout.font:get_height()) / 2), style.text)
  local caret_x = layout.x + layout.pad * 1.5 + layout.font:get_width(view.devhq_comment_overlay.input or "")
  renderer.draw_rect(caret_x, input_y + 2, math.max(1, SCALE or 1), layout.line_h - 4, style.caret)

  local boxes, button_y = {}, input_y + layout.line_h + math.floor(layout.pad / 2)
  local x = layout.x + layout.pad
  x = draw_button(view, boxes, "save", layout.item.state == "draft" and "Save" or "Reply", x, button_y, layout.line_h)
  if layout.item.state == "open" then x = draw_button(view, boxes, "resolve", "Resolve", x, button_y, layout.line_h) end
  draw_button(view, boxes, "cancel", "Cancel", x, button_y, layout.line_h)
  view.devhq_comment_hitboxes = boxes
end

function M.add_comment()
  ensure_loaded()
  local view = core.active_view
  if not (view and view.doc and view:extends(DocView)) then return core.error("No active document") end
  local rel, file = relative_file(view)
  if not rel then return core.error("Document is not inside the current worktree") end
  local l1, c1, l2, c2 = view.doc:get_selection(true)
  if l1 == l2 and c1 == c2 then return core.error("Select text before adding a comment") end
  local item = {
    id = tostring(system.get_time()) .. ":" .. rel .. ":" .. l1 .. ":" .. c1,
    worktree = worktree(),
    file = rel,
    commit = git.commit_for_file(worktree(), file),
    state = "draft",
    range = { start = { line = l1, col = c1 }, ["end"] = { line = l2, col = c2 } },
    messages = { { author = "user", body = "", state = "draft", created_at = now(), updated_at = now() } },
    created_at = now(),
    updated_at = now(),
  }
  comments[#comments + 1] = item
  save()
  open_overlay(view, item, true)
end

local function postable_threads()
  ensure_loaded()
  local out = {}
  for _, item in ipairs(comments) do
    if item.worktree == worktree() and has_draft_message(item) then
      out[#out + 1] = item
    end
  end
  return out
end

local function blob_for(items)
  local out = { "Review comments for " .. tostring(worktree()), "" }
  for _, item in ipairs(items) do
    out[#out + 1] = string.format("%s:%d:%d-%d:%d [%s]", item.file,
      item.range.start.line, item.range.start.col, item.range["end"].line, item.range["end"].col, item.commit)
    for _, message in ipairs(normalize_thread(item).messages) do
      out[#out + 1] = "  " .. author_label(message.author) .. ": " .. (message.body or "")
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

local function open_blob(text)
  local doc = core.open_doc()
  doc:text_input(text)
  core.root_view:open_doc(doc)
end

function M.post_all_comments()
  local postable = postable_threads()
  if #postable == 0 then return core.error("No draft comments to post") end
  local targets, by_name = { "text" }, {}
  for _, item in ipairs(agents.active_for_worktree(worktree())) do
    local name = item.label
    targets[#targets + 1], by_name[name] = name, item
  end
  core.command_view:enter("Post Comments", {
    suggest = function(text) return common.fuzzy_match(targets, text) end,
    validate = function(text, item) return (item and item.text == "text") or by_name[item and item.text or text] ~= nil end,
    submit = function(text, item)
      local selected = item and item.text or text
      local blob = blob_for(postable)
      if selected == "text" then
        open_blob(blob)
      elseif not agents.send_to_agent(by_name[selected], blob .. "\n") then
        return core.error("Agent is no longer active: %s", selected)
      end
      for _, comment in ipairs(postable) do
        mark_messages_open(comment)
      end
      save()
    end,
  })
end

function M.resolve_comment()
  ensure_loaded()
  local items, by_label = {}, {}
  for _, item in ipairs(comments) do
    if item.worktree == worktree() and item.state == "open" then
      local label = comment_label(item)
      items[#items + 1], by_label[label] = label, item
    end
  end
  if #items == 0 then return core.error("No open comments") end
  core.command_view:enter("Resolve Comment", {
    suggest = function(text) return common.fuzzy_match(items, text) end,
    validate = function(text, item) return by_label[item and item.text or text] ~= nil end,
    submit = function(text, item)
      local comment = by_label[item and item.text or text]
      resolve_thread(comment)
      save()
    end,
  })
end

function M.setup()
  ensure_loaded()
  command.add(nil, {
    ["devhq:add-comment"] = M.add_comment,
    ["devhq:resolve-comment"] = M.resolve_comment,
    ["devhq:post-all-comments"] = M.post_all_comments,
  })
  command.add(function()
    local view = core.active_view
    return view and view.devhq_comment_overlay ~= nil, view
  end, {
    ["devhq:comment-save"] = commit_overlay,
    ["devhq:comment-cancel"] = function(view) close_overlay(view, true) end,
    ["devhq:comment-backspace"] = function(view)
      local overlay = view.devhq_comment_overlay
      if overlay then overlay.input = (overlay.input or ""):sub(1, -2); core.redraw = true end
    end,
    ["devhq:comment-resolve"] = resolve_overlay,
  })
  keymap.add {
    ["return"] = "devhq:comment-save",
    ["keypad enter"] = "devhq:comment-save",
    ["escape"] = "devhq:comment-cancel",
    ["backspace"] = "devhq:comment-backspace",
    ["ctrl+r"] = "devhq:comment-resolve",
  }

  if DocView._devhq_comments_originals then return end
  local originals = {
    get_gutter_width = DocView.get_gutter_width,
    draw_line_gutter = DocView.draw_line_gutter,
    on_mouse_pressed = DocView.on_mouse_pressed,
    on_text_input = DocView.on_text_input,
    draw_overlay = DocView.draw_overlay,
  }
  DocView._devhq_comments_originals = originals

  function DocView:get_gutter_width()
    local gw, gpad = originals.get_gutter_width(self)
    if #active_comments_for_view(self) > 0 then
      return gw + style.devhq_comments.marker_gap + style.devhq_comments.marker_width + style.padding.x, gpad
    end
    return gw, gpad
  end

  function DocView:draw_line_gutter(line, x, y, width)
    local base_gw, base_gpad = originals.get_gutter_width(self)
    local lh = originals.draw_line_gutter(self, line, x, y, base_gpad and base_gw - base_gpad or base_gw)
    for _, item in ipairs(active_comments_for_view(self)) do
      if item.range.start.line == line then
        local marker = marker_rect(self, y)
        renderer.draw_rect(marker.x, y + 1, marker.w, (lh or self:get_line_height()) - 2, marker_color(item))
        break
      end
    end
    return lh
  end

  function DocView:on_mouse_pressed(button, x, y, clicks)
    if button == "left" and self.devhq_comment_hitboxes then
      for _, box in ipairs(self.devhq_comment_hitboxes) do
        if x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h then
          if box.action == "save" then commit_overlay(self)
          elseif box.action == "resolve" then resolve_overlay(self)
          else close_overlay(self, true) end
          return true
        end
      end
    end
    if button == "left" then
      local item = comment_at(self, x, y)
      if item then open_overlay(self, item); return true end
    end
    return originals.on_mouse_pressed(self, button, x, y, clicks)
  end

  function DocView:on_text_input(text)
    local overlay = self.devhq_comment_overlay
    if overlay then
      overlay.input = (overlay.input or "") .. text:gsub("[\r\n]", " ")
      core.redraw = true
      return true
    end
    return originals.on_text_input(self, text)
  end

  function DocView:draw_overlay(...)
    originals.draw_overlay(self, ...)
    core.devhq_comments.draw_overlay(self)
  end
end

return M
