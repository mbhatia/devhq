-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local ghostty = require "plugins.ghostty"

local M = {}
local rt = core.sivraj_agents_runtime or { views = {} }
core.sivraj_agents_runtime = rt

config.plugins.sivraj = config.plugins.sivraj or {}
config.plugins.sivraj.agents = config.plugins.sivraj.agents or {}
config.plugins.sivraj.agents.codex = config.plugins.sivraj.agents.codex
  or { start = "codex", resume = "codex resume" }

local function profiles() return config.plugins.sivraj.agents or {} end
local function key(w, a) return w.path .. "\0" .. a.profile .. "\0" .. a.name end
local function label(a) return (a.needs_input and "! " or "") .. a.profile .. ": " .. a.name end
local function node(v) return v and core.root_view.root_node:get_node_for_view(v) end
local function save() if rt.ctx then rt.ctx.save_state() end core.redraw = true end
local function set_title(v, a) if v then v.title = label(a) end end

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

local function launch(w, a, action)
  local k, v = key(w, a), rt.views[key(w, a)]
  if not (v and v.terminal) then
    local p = profiles()[a.profile]
    local cmd = p and (p[action] or p.start)
    if not cmd then return core.error("Unknown Sivraj agent profile: %s", a.profile) end
    v = ghostty.open_tab {
      kind = "agent", title = a.profile .. ": " .. a.name, cwd = w.path,
      command = cmd, shell = true, close_on_exit = "never",
    }
    v.sivraj_agent_key, rt.views[k] = k, v
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
      kind = "agent", tooltip = w.path, open = function() open_agent(w, a) end }
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
    ["sivraj:create-agent"] = function()
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
    local _, a = find_agent(e.view and e.view.sivraj_agent_key or "")
    if a then a.needs_input = true; set_title(e.view, a); save() end
  end
  ghostty.on("notification", mark)
  ghostty.on("bell", mark)
  ghostty.on("title-changed", function(e)
    local _, a = find_agent(e.view and e.view.sivraj_agent_key or "")
    if a then set_title(e.view, a); core.redraw = true end
  end)
  ghostty.on("terminal-closed", function(e)
    local k = e.view and e.view.sivraj_agent_key
    if k then remove_agent(k) end
  end)
  ghostty.on("terminal-exited", function(e)
    local k = e.view and e.view.sivraj_agent_key
    if k then
      local n = node(e.view)
      if n then n:close_view(core.root_view.root_node, e.view) else e.view:close() end
      remove_agent(k)
    end
  end)
  core.add_thread(function()
    while true do
      for _, v in pairs(rt.views) do if v.terminal and not node(v) then v:update() end end
      coroutine.yield(0.2)
    end
  end)
  rt.events_registered = true
end

return M
