-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local ghostty = require "plugins.ghostty"

local M = {}
local rt = core.devhq_agents_runtime or { views = {} }
core.devhq_agents_runtime = rt

local function shell_quote_double(value) return '"' .. tostring(value or ""):gsub('"', '\\"') .. '"' end
local function shell_quote_single(value) return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'" end

config.plugins.devhq = config.plugins.devhq or {}
config.plugins.devhq.agents = config.plugins.devhq.agents or {}
local codex_start_cmd = [[${SHELL:-sh} -lc 'exec codex --add-dir "$REPO"']]
local codex_resume_cmd = [[${SHELL:-sh} -lc 'exec codex --add-dir "$REPO" resume']]
local codex_resume_thread_cmd = [[${SHELL:-sh} -lc 'exec codex --add-dir "$REPO" resume "$THREAD_ID"']]
local function codex_cmd(cmd)
  local quoted = shell_quote_double(cmd)
  return [[session="$REPO_ID:${AGENT_ID##*:}"; ]]
    .. [[ _shpool_with_config() { command -v shpool >/dev/null 2>&1 && [ -f "$HOME/.config/shpool/config.toml" ] && exec shpool -c "$HOME/.config/shpool/config.toml" attach -f -d "$PWD" -c ]] .. quoted .. [[ "$session"; }; ]]
    .. [[ _shpool() { command -v shpool >/dev/null 2>&1 && exec shpool attach -f -d "$PWD" -c ]] .. quoted .. [[ "$session"; }; ]]
    .. [[ _atch() { command -v atch >/dev/null 2>&1 && exec atch "$session" ]] .. cmd .. [[; }; ]]
    .. [[ _cmd() { exec ]] .. cmd .. [[; }; ]]
    .. [[ _shpool_with_config || _shpool || _atch || _cmd ]]
end
local function fontawesome_icon_font()
  local font_path = USERDIR .. PATHSEP .. "fonts" .. PATHSEP
    .. "fontawesome_free_desktop" .. PATHSEP
    .. "fontawesome-free-7.3.0-desktop" .. PATHSEP
    .. "otfs" .. PATHSEP
    .. "Font Awesome 7 Brands-Regular-400.otf"
  if not system.get_file_info(font_path) then
    return style.icon_font or style.font
  end

  local base = style.icon_font or style.font
  local size = base and base.get_size and base:get_size() or (14 * SCALE)
  local ok, font = pcall(renderer.font.load, font_path, size)
  return ok and font or base
end
config.plugins.devhq.agents.codex = common.merge({
  start = codex_cmd(codex_start_cmd),
  resume = codex_cmd(codex_resume_cmd),
  resume_thread = codex_cmd(codex_resume_thread_cmd),
  thread = {
    input = "/status\n",
    pattern = "[Ss]ession%s*:%s*(%x+-%x+-%x+-%x+-%x+)",
  },
  icon = "\u{e7cf}",
  icon_font = fontawesome_icon_font(),
}, config.plugins.devhq.agents.codex)

local function profiles() return config.plugins.devhq.agents or {} end
local function key(w, a) return w.path .. "\0" .. a.profile .. "\0" .. a.name end
local function label(a) return (a.needs_input and "! " or "") .. a.name .. " [" .. a.profile .. "]" end
local function agent_id(a) return (a.profile .. ":" .. a.name):gsub("%s+", "-") end
local function icon(a)
  return function(_, active, hovered)
    local p = profiles()[a.profile] or {}
    local color = p.icon_color or (a.needs_input and style.warn) or ((active or hovered) and style.accent) or style.dim
    return p.icon or "@", p.icon_font or style.font, color
  end
end
local function node(v) return v and core.root_view.root_node:get_node_for_view(v) end
local function save() if rt.ctx then rt.ctx.save_state() end core.redraw = true end
local function set_title(v, a) if v then v.title = label(a) end end
local function strip_trailing_separators(path)
  path = tostring(path or "")
  while #path > 1 and (path:sub(-1) == "/" or path:sub(-1) == "\\" or path:sub(-1) == PATHSEP) do
    path = path:sub(1, -2)
  end
  return path
end

local function parent_repo(w)
  if not rt.ctx then return end
  for _, r in ipairs(rt.ctx.repos) do
    for _, rw in ipairs(r.worktrees or {}) do
      if rw == w or rw.path == w.path then
        return r
      end
    end
  end
end

local function parent_repo_path(w)
  local r = parent_repo(w)
  if r then
    return r.path
  end
  return w.path
end

local function parent_repo_id(w)
  local r = parent_repo(w)
  local path = r and r.kind == "remote" and r.remote_path or r and r.path or w.path
  return common.basename(strip_trailing_separators(path))
end

local function agent_options(w, a, cmd)
  local r = parent_repo(w)
  if r and r.kind == "remote" then
    local remote_path = w.remote_path or r.remote_path
    local script = "cd " .. shell_quote_single(remote_path)
      .. " && REPO=" .. shell_quote_single(remote_path)
      .. " && REPO_ID=" .. shell_quote_single(parent_repo_id(w))
      .. " && AGENT_ID=" .. shell_quote_single(agent_id(a))
      .. " && THREAD_ID=" .. shell_quote_single(a.thread_id or "")
      .. " && export REPO REPO_ID AGENT_ID THREAD_ID"
      .. " && " .. cmd
    return {
      kind = "agent", title = a.profile .. ": " .. a.name, cwd = w.path,
      command = { "ssh", "-At", r.server, "/bin/sh -lc " .. shell_quote_single(script) },
      agent_close_on_exit = "never",
    }
  end
  return {
    kind = "agent", title = a.profile .. ": " .. a.name, cwd = w.path,
    command = cmd, shell = true, agent_close_on_exit = "never",
    env = { REPO = parent_repo_path(w), REPO_ID = parent_repo_id(w), AGENT_ID = agent_id(a),
      THREAD_ID = a.thread_id or "" },
  }
end

local function find_agent(k)
  if not rt.ctx then return end
  for _, r in ipairs(rt.ctx.repos) do
    for _, w in ipairs(r.worktrees or {}) do
      for i, a in ipairs(w.agents or {}) do
        if key(w, a) == k then return w, a, i end
      end
    end
  end
end

local function clear_attention(v)
  local _, a = find_agent(v and v.devhq_agent_key or "")
  if a and a.needs_input then
    a.needs_input = false
    set_title(v, a)
    save()
  end
end

local function install_attention_clearer(v)
  if not v or v.devhq_attention_clearer then return end
  v.devhq_attention_clearer = true

  local on_text_input = v.on_text_input
  function v:on_text_input(text)
    clear_attention(self)
    if on_text_input then return on_text_input(self, text) end
  end

  local on_key_pressed = v.on_key_pressed
  function v:on_key_pressed(...)
    clear_attention(self)
    if on_key_pressed then return on_key_pressed(self, ...) end
    return false
  end
end

local function current_worktree()
  for _, r in ipairs(rt.ctx.repos) do
    for _, w in ipairs(r.worktrees or {}) do
      if w.path == core.project_dir then return w end
    end
  end
end

local function focus(v)
  local n = node(v)
  if n then n:set_active_view(v) else core.root_view:get_active_node_default():add_view(v) end
end

local function profile_input(text, a)
  return tostring(text or "")
    :gsub("%$AGENT_ID", function() return agent_id(a) end)
    :gsub("%$AGENT_NAME", function() return tostring(a.name or "") end)
    :gsub("%$THREAD_ID", function() return tostring(a.thread_id or "") end)
end

local function terminal_text(v)
  local lines = {}
  local rows = v and v.snapshot and v.snapshot.rows_data or {}
  for _, row in ipairs(rows) do
    local parts = {}
    for _, span in ipairs(row.spans or {}) do parts[#parts + 1] = span.text or "" end
    lines[#lines + 1] = table.concat(parts)
  end
  return table.concat(lines, "\n")
end

local function send_terminal_input(v, text, delay)
  if not (v and v.terminal) then return end
  for part, nl in tostring(text or ""):gsub("\r\n", "\n"):gmatch("([^\n]*)(\n?)") do
    if part ~= "" then v.terminal:input_text(part) end
    if nl ~= "" and v.on_key_pressed then
      coroutine.yield(delay or 0.1)
      v:on_key_pressed("return", nil, false, {})
    end
    if nl == "" then break end
  end
end

local function capture_thread(v, a, p)
  local cfg = p and p.thread
  if type(cfg) ~= "table" or not cfg.pattern or a.thread_id then return end
  core.add_thread(function()
    coroutine.yield(cfg.delay or 1)
    if cfg.input then send_terminal_input(v, profile_input(cfg.input, a), cfg.submit_delay) end
    for _ = 1, cfg.attempts or 50 do
      if not v.terminal then return end
      if v.update then v:update() end
      local id = terminal_text(v):match(cfg.pattern)
      if id and id ~= "" then
        a.thread_id = id
        save()
        return
      end
      coroutine.yield(cfg.interval or 0.2)
    end
  end)
end

local function launch(w, a, action)
  local k, v = key(w, a), rt.views[key(w, a)]
  if not (v and v.terminal) then
    local p = profiles()[a.profile]
    local cmd = p and (action == "resume" and a.thread_id and p.resume_thread or p[action] or p.start)
    if not cmd then return core.error("Unknown DevHQ agent profile: %s", a.profile) end
    v = ghostty.open_tab(agent_options(w, a, cmd))
    install_attention_clearer(v)
    v.devhq_agent_key, rt.views[k] = k, v
    capture_thread(v, a, p)
  end
  a.needs_input = false
  set_title(v, a)
  focus(v)
  save()
end

local function open_agent(w, a)
  rt.ctx.open_project(w.path, function(path)
    rt.ctx.set_selected_worktree(path)
    local v = rt.views[key(w, a)]
    launch(w, a, v and v.terminal and "start" or "resume")
  end)
end

local function remove_agent(k)
  local w, _, i = find_agent(k)
  local changed = w ~= nil or rt.views[k] ~= nil
  if w and i then table.remove(w.agents, i) end
  rt.views[k] = nil
  if changed then save() end
end

local function profile_names()
  local names = {}
  for name in pairs(profiles()) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function create_agent(profile)
  core.command_view:enter("Agent Name", {
    validate = function(text) return text ~= "" end,
    submit = function(name)
      local w = current_worktree()
      if not w then return core.error("Current project is not a loaded worktree") end
      w.agents = w.agents or {}
      for _, a in ipairs(w.agents) do
        if a.profile == profile and a.name == name then
          return core.error("Agent already exists: %s: %s", profile, name)
        end
      end
      local a = { profile = profile, name = name, needs_input = false }
      w.agents[#w.agents + 1] = a
      if rt.ctx.expand_worktree then rt.ctx.expand_worktree(w) end
      save()
      launch(w, a, "start")
    end,
  })
end

function M.sanitize_worktrees(worktrees)
  for _, w in ipairs(worktrees or {}) do w.agents = type(w.agents) == "table" and w.agents or {} end
  return worktrees or {}
end

function M.merge_worktrees(old, new)
  local by_path = {}
  for _, w in ipairs(old or {}) do by_path[w.path] = w.agents end
  for _, w in ipairs(new or {}) do w.agents = by_path[w.path] or {} end
  return M.sanitize_worktrees(new)
end

function M.children(w)
  local nodes = {}
  for _, a in ipairs(w.agents or {}) do
    nodes[#nodes + 1] = { id = "agent:" .. key(w, a), label = label(a),
      kind = "agent", tooltip = w.path, icon = icon(a),
      open = function() open_agent(w, a) end }
  end
  return nodes
end

function M.active_for_worktree(path)
  local items = {}
  if not rt.ctx then return items end
  for _, r in ipairs(rt.ctx.repos) do
    for _, w in ipairs(r.worktrees or {}) do
      if w.path == path then
        for _, a in ipairs(w.agents or {}) do
          local k, v = key(w, a), rt.views[key(w, a)]
          if v and v.terminal then
            items[#items + 1] = { key = k, label = label(a), profile = a.profile, name = a.name }
          end
        end
      end
    end
  end
  return items
end

function M.send_to_agent(item, text)
  local v = item and rt.views[item.key]
  if v and v.terminal then
    v.terminal:input_text(text)
    focus(v)
    return true
  end
  return false
end

function M.setup(ctx)
  rt.ctx = ctx
  command.add(nil, {
    ["devhq:create-agent"] = function()
      core.command_view:enter("Agent Profile", {
        suggest = function(text) return common.fuzzy_match(profile_names(), text) end,
        validate = function(text) return profiles()[text] ~= nil end,
        submit = function(text, item) create_agent(item and item.text or text) end,
      })
    end,
  })
end

if not rt.events_registered then
  local function mark(e)
    local _, a = find_agent(e.view and e.view.devhq_agent_key or "")
    if a then a.needs_input = true; set_title(e.view, a); save() end
  end
  ghostty.on("notification", mark)
  ghostty.on("bell", mark)
  ghostty.on("title-changed", function(e)
    local _, a = find_agent(e.view and e.view.devhq_agent_key or "")
    if a then set_title(e.view, a); core.redraw = true end
  end)
  ghostty.on("terminal-exited", function(e)
    local k = e.view and e.view.devhq_agent_key
    if k then
      -- local n = node(e.view)
      -- if n then n:close_view(core.root_view.root_node, e.view) else e.view:close() end
      remove_agent(k)
    end
  end)
  core.add_thread(function()
    while true do
      local active = core.active_view
      if active ~= rt.last_active_view then
        rt.last_active_view = active
        clear_attention(active)
      end
      for _, v in pairs(rt.views) do
        if v.terminal then
          install_attention_clearer(v)
          if not node(v) then v:update() end
        end
      end
      coroutine.yield(0.2)
    end
  end)
  rt.events_registered = true
end

return M
