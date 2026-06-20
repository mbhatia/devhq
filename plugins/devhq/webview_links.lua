-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local EmptyView = require "core.emptyview"
local system = require "system"
local click_to_open = require "plugins.ghostty.click_to_open"

local M = {}

local rt = core.devhq_webview_links_runtime or {}
core.devhq_webview_links_runtime = rt
rt.projects = rt.projects or {}

local function option_enabled(name)
  return config.plugins.devhq and config.plugins.devhq[name] ~= false
end

local function public_url_action()
  local action = config.plugins.devhq and config.plugins.devhq.webview_public_url_action or "prompt"
  action = tostring(action or "prompt"):lower():gsub("%s+", "_"):gsub("-", "_")
  if action == "local" or action == "local_webview" or action == "web" then return "webview" end
  if action == "browser" or action == "system_browser" then return "system" end
  if action == "webview" or action == "system" or action == "prompt" then return action end
  return "prompt"
end

local function is_http_url(target)
  return type(target) == "string" and target:match("^https?://") ~= nil
end

local function url_host(target)
  return type(target) == "string" and target:match("^https?://([^/:?#]+)")
end

local function is_localhost_url(target)
  local host = url_host(target)
  return host == "localhost" or host == "127.0.0.1"
end

local function is_html_file(path)
  return type(path) == "string" and path:lower():match("%.html?$") ~= nil
end

local function detach_webview_native(view)
  if view and view.detach then
    view:detach()
  elseif view and view.browser and view.browser.detach then
    pcall(view.browser.detach, view.browser)
  elseif view and view.browser and not rt.missing_blur_reported then
    rt.missing_blur_reported = true
    core.error("DevHQ webview requires lite-xl-web 0.1.4 or newer; installed web_lxl has no detach()")
  end
end

local function project_key(path)
  return path or core.project_dir or ""
end

local function project_bucket(path)
  local key = project_key(path)
  local bucket = rt.projects[key]
  if not bucket then
    bucket = {}
    rt.projects[key] = bucket
  end
  return bucket
end

local function webview_target(view)
  return view and ((view.status and view.status.url) or view.url)
end

local function remember_webview(path, view, target)
  if not view then return end
  local bucket = project_bucket(path)
  bucket.view = view
  bucket.target = target or webview_target(view)
  rt.view = view
end

local function restore_focus(view)
  if not view then return end
  local node = core.root_view.root_node:get_node_for_view(view)
  if node then
    node:set_active_view(view)
  else
    core.set_active_view(view)
  end
end

local function remove_view_from_layout(view)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if not node then return false end
  detach_webview_native(view)
  if node == root and node.type == "leaf" and #node.views == 1 then
    node.views = {}
    node:add_view(EmptyView())
  else
    node:remove_view(root, view)
  end
  root:update_layout()
  core.redraw = true
  return true
end

local function stash_webview(path)
  local view = rt.view
  if not view then return end
  local root = core.root_view.root_node
  local bucket = project_bucket(path)
  if root:get_node_for_view(view) then
    bucket.target = webview_target(view)
    bucket.active = core.active_view == view
    bucket.view = nil
    remove_view_from_layout(view)
  else
    bucket.target = nil
    bucket.active = nil
    bucket.view = nil
  end
  rt.view = nil
end

local function create_webview(path, target, source_view)
  local ok, web = pcall(require, "plugins.web")
  if not ok or type(web) ~= "table" then
    core.error("DevHQ webview requires the web plugin")
    return nil
  end

  local view
  if web.WebView then
    view = web.WebView(target)
    local root = core.root_view.root_node
    local source_node = root:get_node_for_view(source_view) or core.root_view:get_active_node_default()
    source_node:split("right", view)
    root:update_layout()
  elseif web.open_tab then
    view = web.open_tab(target)
  end

  if not view then
    core.error("DevHQ webview requires plugins.web.open_tab")
    return nil
  end

  remember_webview(path, view, target)
  return view
end

local function restore_webview(path)
  local bucket = rt.projects[project_key(path)]
  if not (bucket and bucket.target) then return end

  local previous_active = core.active_view
  local view = create_webview(path, bucket.target, previous_active)
  if not view then return end

  if bucket.active then
    restore_focus(view)
  else
    restore_focus(previous_active)
    detach_webview_native(view)
  end
  core.redraw = true
end

local function install_focus_blur_handler()
  if rt.focus_blur_installed then return end
  local set_active_view = core.set_active_view
  function core.set_active_view(view)
    if rt.view and view ~= rt.view and core.root_view.root_node:get_node_for_view(rt.view) then
      detach_webview_native(rt.view)
    end
    return set_active_view(view)
  end
  rt.focus_blur_installed = true
end

local function install_project_switch_handler()
  if rt.project_switch_installed then return end
  local open_folder_project = core.open_folder_project
  function core.open_folder_project(path)
    local before = core.project_dir
    stash_webview(before)
    open_folder_project(path)
    restore_webview(core.project_dir ~= before and core.project_dir or path)
  end
  rt.project_switch_installed = true
end

local function file_target(detected, cwd)
  if not detected or (detected.kind ~= "path" and detected.kind ~= "file_url") then return nil end
  local root = require "plugins.ghostty.project".root()
  local filename = click_to_open.resolve_file(detected.target, cwd, root)
  if not is_html_file(filename) then return nil end
  local info = system.get_file_info(filename)
  if info and info.type == "file" then return filename end
end

local function open_web_target(target, source_view)
  local ok, web = pcall(require, "plugins.web")
  if not ok or type(web) ~= "table" then
    core.error("DevHQ webview requires the web plugin")
    return false
  end

  local root = core.root_view.root_node
  if rt.view and root:get_node_for_view(rt.view) then
    if rt.view.navigate then
      rt.view:navigate(target)
      remember_webview(core.project_dir, rt.view, target)
      detach_webview_native(rt.view)
      restore_focus(source_view)
      return true
    end
    rt.view = nil
  end

  local view
  if web.WebView then
    view = web.WebView(target)
    local source_node = root:get_node_for_view(source_view) or core.root_view:get_active_node_default()
    rt.node = source_node:split("right", view)
    remember_webview(core.project_dir, view, target)
    core.root_view.root_node:update_layout()
  elseif web.open_tab then
    view = web.open_tab(target)
    remember_webview(core.project_dir, view, target)
  end

  if not view then
    core.error("DevHQ webview requires plugins.web.open_tab")
    return false
  end

  detach_webview_native(view)
  restore_focus(source_view)
  return true
end

local function prompt_public_url(target, source_view, original_open, detected, cwd)
  core.command_view:enter("Open URL", {
    text = "local webview",
    suggest = function()
      return { "local webview", "system browser" }
    end,
    validate = function(text)
      return text == "local webview" or text == "system browser"
    end,
    submit = function(text, item)
      local choice = item and item.text or text
      if choice == "local webview" then
        open_web_target(target, source_view)
      else
        original_open(detected, cwd)
      end
    end,
  })
  return true
end

local function route(detected, cwd, original_open)
  if not detected then return false end

  local source_view = core.active_view
  local html_file = option_enabled("webview_open_html_files") and file_target(detected, cwd)
  if html_file then
    return open_web_target(html_file, source_view)
  end

  local target = detected.target
  if is_http_url(target) then
    if is_localhost_url(target) then
      if option_enabled("webview_open_localhost_urls") then
        return open_web_target(target, source_view)
      end
      return false
    end

    local action = public_url_action()
    if action == "webview" then
      return open_web_target(target, source_view)
    elseif action == "system" then
      return false
    end
    return prompt_public_url(target, source_view, original_open, detected, cwd)
  end

  return false
end

function M.setup()
  install_focus_blur_handler()
  install_project_switch_handler()
  if rt.installed then return end

  local original_open = click_to_open.open
  function click_to_open.open(detected, cwd)
    if route(detected, cwd, original_open) then return true end
    return original_open(detected, cwd)
  end

  command.add(nil, {
    ["devhq:open-webview"] = function(text)
      if text and text ~= "" then return open_web_target(text, core.active_view) end
      core.command_view:enter("Open URL or HTML File", {
        submit = function(input)
          if input and input ~= "" then open_web_target(common.home_expand(input), core.active_view) end
        end,
      })
    end,
  })

  rt.installed = true
end

return M
