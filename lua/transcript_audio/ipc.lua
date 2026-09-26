--- mpv JSON IPC transport will live here.
local M = {}

function M.request(_request, callback)
  if type(callback) ~= "function" then
    error("transcript_audio.ipc.request requires a callback")
  end

  callback("mpv IPC transport is not implemented yet")
end

return M
