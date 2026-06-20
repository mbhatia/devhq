-- mod-version:3

local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local system = require "system"
local click_to_open = require "plugins.ghostty.click_to_open"

local M = {}

local rt = core.devhq_webview_links_runtime or {}
core.devhq_webview_links_runtime = rt

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

local function blur_webview(view)
  if view and view.blur then
    view:blur()
  elseif view and view.browser and view.browser.blur then
    pcall(view.browser.blur, view.browser)
  elseif view and view.browser and not rt.missing_blur_reported then
    rt.missing_blur_reported = true
    core.error("DevHQ webview requires lite-xl-web 0.1.2 or newer; installed web_lxl has no blur()")
  end
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

local function install_focus_blur_handler()
  if rt.focus_blur_installed then return end
  local set_active_view = core.set_active_view
  function core.set_active_view(view)
    if rt.view and view ~= rt.view and core.root_view.root_node:get_node_for_view(rt.view) then
      blur_webview(rt.view)
    end
    return set_active_view(view)
  end
  rt.focus_blur_installed = true
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
      blur_webview(rt.view)
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
    rt.view = view
    core.root_view.root_node:update_layout()
  elseif web.open_tab then
    view = web.open_tab(target)
    rt.view = view
  end

  if not view then
    core.error("DevHQ webview requires plugins.web.open_tab")
    return false
  end

  blur_webview(view)
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
