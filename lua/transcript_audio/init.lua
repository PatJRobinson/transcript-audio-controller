local M = {}

local DEFAULT_TIMEOUT_MS = 3000
local SOCKET_NAME = "transcript-mpv.sock"

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

local function audio_placeholder(command)
  vim.notify(
    "Transcript audio: playback actions are not implemented yet (received: "
      .. command.args
      .. ")",
    vim.log.levels.INFO
  )
end

local function create_audio_command()
  vim.api.nvim_create_user_command("Audio", audio_placeholder, {
    desc = "Control the transcript audio player",
    nargs = "+",
    force = true,
  })
end

function M.setup(opts)
  M.config = M.resolve_config(opts)
  create_audio_command()
end

M.config = M.resolve_config()

return M
