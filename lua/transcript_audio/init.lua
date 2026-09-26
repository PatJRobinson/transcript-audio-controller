local M = {}

local actions = require("transcript_audio.actions")
local ipc = require("transcript_audio.ipc")

local DEFAULT_TIMEOUT_MS = 3000
local SOCKET_NAME = "transcript-mpv.sock"

local default_mappings = {
  { "<leader>aa", "toggle", nil, "Toggle transcript audio" },
  { "<leader>ap", "play", nil, "Play transcript audio" },
  { "<leader>as", "pause", nil, "Pause transcript audio" },
  { "<leader>ah", "back", 5, "Seek transcript audio back 5 seconds" },
  { "<leader>al", "forward", 5, "Seek transcript audio forward 5 seconds" },
  { "<leader>aj", "back", 10, "Seek transcript audio back 10 seconds" },
  { "<leader>ak", "forward", 10, "Seek transcript audio forward 10 seconds" },
  { "<leader>aH", "back", 30, "Seek transcript audio back 30 seconds" },
  { "<leader>aL", "forward", 30, "Seek transcript audio forward 30 seconds" },
  { "<leader>a0", "beginning", nil, "Seek transcript audio to beginning" },
  { "<leader>a$", "end", nil, "Seek transcript audio to end" },
  { "<leader>at", "time", nil, "Show transcript audio position" },
}

local installed_mapping_lhs = {}

local function expand_leader(lhs)
  local leader = vim.g.mapleader
  if leader == nil then
    leader = "\\"
  end
  return (lhs:gsub("<leader>", leader))
end

local function user_id()
  local uv = vim.uv or vim.loop
  if uv and uv.getuid then
    return uv.getuid()
  end

  return vim.fn.getuid()
end

local function fallback_socket()
  return "/run/user/" .. user_id() .. "/" .. SOCKET_NAME
end

local function default_socket()
  local runtime_dir = vim.env.XDG_RUNTIME_DIR
  if runtime_dir and runtime_dir ~= "" then
    return runtime_dir .. "/" .. SOCKET_NAME
  end

  return fallback_socket()
end

local function resolve_socket(opts)
  if opts.socket ~= nil then
    return opts.socket
  end

  return vim.env.TRANSCRIPT_MPV_SOCKET or default_socket()
end

function M.resolve_config(opts)
  opts = opts or {}

  return {
    socket = resolve_socket(opts),
    timeout_ms = opts.timeout_ms ~= nil and opts.timeout_ms or DEFAULT_TIMEOUT_MS,
    mappings = opts.mappings == nil and true or opts.mappings,
  }
end

local function notify_error(message)
  vim.notify("Transcript audio: " .. message, vim.log.levels.WARN)
end

---Format an mpv time position for display.
---@param seconds any
---@return string|nil position
---@return string|nil error
function M.format_time(seconds)
  if type(seconds) ~= "number"
    or seconds < 0
    or seconds ~= seconds
    or seconds == math.huge
    or seconds == -math.huge
  then
    return nil, "mpv returned no usable playback position"
  end

  local centiseconds = math.floor((seconds * 100) + 0.5)
  local whole_seconds = math.floor(centiseconds / 100)
  local fraction = centiseconds % 100
  local display_seconds = whole_seconds % 60
  local total_minutes = math.floor(whole_seconds / 60)
  local display_minutes = total_minutes % 60
  local hours = math.floor(total_minutes / 60)

  if hours > 0 then
    return string.format(
      "%02d:%02d:%02d.%02d",
      hours,
      display_minutes,
      display_seconds,
      fraction
    )
  end

  return string.format("%02d:%02d.%02d", display_minutes, display_seconds, fraction)
end

local function resolve_media_path(path)
  local expanded = vim.fn.expand(path)
  local absolute = vim.fn.fnamemodify(expanded, ":p")
  if vim.fn.filereadable(absolute) ~= 1 then
    return nil, "File is not readable: " .. absolute
  end
  return absolute
end

local function send(command, on_success)
  ipc.request({
    socket = M.config.socket,
    timeout_ms = M.config.timeout_ms,
    command = command,
  }, function(err, data)
    if err then
      notify_error(err)
      return
    end
    if on_success then
      on_success(data)
    end
  end)
end

---Run a user-facing audio action.
---@param action string|nil
---@param argument string|number|nil
function M.run(action, argument)
  if action == "load" then
    if argument == nil or tostring(argument):match("%S") == nil then
      notify_error("Usage: :Audio load /path/to/file.mp3")
      return
    end

    local path, path_error = resolve_media_path(tostring(argument))
    if not path then
      notify_error(path_error)
      return
    end
    argument = path
  end

  local command, command_error = actions.command(action, argument)
  if not command then
    notify_error(command_error)
    return
  end

  if action == "time" then
    send(command, function(data)
      local position, format_error = M.format_time(data)
      if not position then
        notify_error(format_error)
        return
      end
      vim.notify("Audio: " .. position, vim.log.levels.INFO)
    end)
    return
  end

  send(command)
end

local function audio_command(command)
  local action, argument = command.args:match("^(%S+)%s*(.*)$")
  M.run(action, argument)
end

local function create_audio_command()
  vim.api.nvim_create_user_command("Audio", audio_command, {
    desc = "Control the transcript audio player",
    nargs = "+",
    force = true,
  })
end

local function create_default_mappings()
  for _, lhs in ipairs(installed_mapping_lhs) do
    pcall(vim.keymap.del, "n", lhs)
  end
  installed_mapping_lhs = {}

  for _, mapping in ipairs(default_mappings) do
    local lhs, action, argument, description = unpack(mapping)
    vim.keymap.set("n", lhs, function()
      M.run(action, argument)
    end, {
      desc = description,
      silent = true,
    })
    installed_mapping_lhs[#installed_mapping_lhs + 1] = expand_leader(lhs)
  end
end

function M.setup(opts)
  M.config = M.resolve_config(opts)
  create_audio_command()
  if M.config.mappings then
    create_default_mappings()
  else
    for _, lhs in ipairs(installed_mapping_lhs) do
      pcall(vim.keymap.del, "n", lhs)
    end
    installed_mapping_lhs = {}
  end
end

M.config = M.resolve_config()

return M
