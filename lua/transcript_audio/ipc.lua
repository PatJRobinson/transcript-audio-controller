local M = {}

local uv = vim.uv or vim.loop
local REQUEST_ID = 1

local function describe_error(err)
  if err == nil then
    return "unknown error"
  end

  return tostring(err)
end

local function close_handle(handle, stop)
  if not handle or handle:is_closing() then
    return
  end

  if stop then
    pcall(stop, handle)
  end
  handle:close()
end

---Send one command over a fresh mpv JSON IPC connection.
---@param request { socket: string, timeout_ms: integer, command: table }
---@param callback fun(err: string|nil, data: any)
function M.request(request, callback)
  if type(callback) ~= "function" then
    error("transcript_audio.ipc.request requires a callback")
  end

  local done = false
  local pipe
  local timer

  local function finish(err, data)
    if done then
      return
    end
    done = true

    close_handle(timer, timer and timer.stop)
    close_handle(pipe, pipe and pipe.read_stop)

    vim.schedule(function()
      callback(err, data)
    end)
  end

  if type(request) ~= "table" then
    finish("IPC request must be a table")
    return
  end
  if type(request.socket) ~= "string" or request.socket == "" then
    finish("IPC socket path must be a non-empty string")
    return
  end
  if type(request.command) ~= "table" then
    finish("IPC command must be a table")
    return
  end
  if type(request.timeout_ms) ~= "number" or request.timeout_ms <= 0 then
    finish("IPC timeout must be a positive number")
    return
  end

  local encoded_ok, message = pcall(vim.json.encode, {
    command = request.command,
    request_id = REQUEST_ID,
  })
  if not encoded_ok then
    finish("Cannot encode IPC request: " .. describe_error(message))
    return
  end
  message = message .. "\n"

  local pipe_ok, new_pipe, pipe_err = pcall(uv.new_pipe, false)
  if not pipe_ok or not new_pipe then
    finish("Cannot create IPC pipe: " .. describe_error(pipe_ok and pipe_err or new_pipe))
    return
  end
  pipe = new_pipe

  local timer_ok, new_timer, timer_err = pcall(uv.new_timer)
  if not timer_ok or not new_timer then
    finish("Cannot create IPC timeout timer: " .. describe_error(timer_ok and timer_err or new_timer))
    return
  end
  timer = new_timer

  local start_ok, start_result, start_err = pcall(function()
    return timer:start(request.timeout_ms, 0, function()
      finish("Timed out waiting for mpv")
    end)
  end)
  if not start_ok or start_result == nil then
    finish("Cannot start IPC timeout timer: " .. describe_error(start_ok and start_err or start_result))
    return
  end

  local buffer = ""

  local connect_ok, connect_result, connect_err = pcall(function()
    return pipe:connect(request.socket, function(err)
      if done then
        return
      end
      if err then
        finish("Cannot connect to mpv: " .. describe_error(err))
        return
      end

      local read_ok, read_result, read_err = pcall(function()
        return pipe:read_start(function(stream_err, chunk)
          if done then
            return
          end
          if stream_err then
            finish("IPC read error: " .. describe_error(stream_err))
            return
          end
          if chunk == nil then
            finish("mpv closed the connection before replying")
            return
          end

          buffer = buffer .. chunk
          while not done do
            local newline = buffer:find("\n", 1, true)
            if not newline then
              break
            end

            local line = buffer:sub(1, newline - 1)
            buffer = buffer:sub(newline + 1)

            local decode_ok, reply = pcall(vim.json.decode, line)
            if not decode_ok or type(reply) ~= "table" then
              finish("Malformed JSON from mpv")
              return
            end

            if reply.request_id == REQUEST_ID then
              if type(reply.error) ~= "string" then
                finish("Malformed reply from mpv")
              elseif reply.error ~= "success" then
                finish("mpv error: " .. reply.error)
              else
                finish(nil, reply.data)
              end
              return
            end
          end
        end)
      end)

      if not read_ok or read_err ~= nil then
        finish("Cannot start IPC read: " .. describe_error(read_ok and read_err or read_result))
        return
      end

      local write_ok, write_result, write_err = pcall(function()
        return pipe:write(message, function(err_write)
          if err_write then
            finish("IPC write error: " .. describe_error(err_write))
          end
        end)
      end)
      if not write_ok or write_result == nil then
        finish("Cannot write IPC request: " .. describe_error(write_ok and write_err or write_result))
      end
    end)
  end)

  if not connect_ok or connect_result == nil then
    finish("Cannot start IPC connection: " .. describe_error(connect_ok and connect_err or connect_result))
  end
end

return M
