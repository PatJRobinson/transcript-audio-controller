local ipc = require("transcript_audio.ipc")

local socket = assert(vim.env.TRANSCRIPT_AUDIO_TEST_SOCKET, "test socket is not configured")
local callback_counts = {}
local case_index = 0

local cases = {
  { name = "success", data = "success" },
  { name = "fragmented", data = "fragmented" },
  { name = "multiple", data = "multiple" },
  { name = "event", data = "event" },
  { name = "unrelated", data = "unrelated" },
  { name = "mpv_error", error = "mpv error: property unavailable" },
  { name = "eof", error = "mpv closed the connection before replying" },
  { name = "malformed", error = "Malformed JSON from mpv" },
  { name = "malformed_reply", error = "Malformed reply from mpv" },
  { name = "timeout", error = "Timed out waiting for mpv", timeout_ms = 40 },
}

local watchdog = vim.defer_fn(function()
  error("IPC tests timed out")
end, 5000)

local function fail(message)
  vim.api.nvim_err_writeln(message)
  vim.cmd("cquit 1")
end

local function finish_tests()
  vim.defer_fn(function()
    local ok, err = pcall(function()
      for _, test_case in ipairs(cases) do
        assert(callback_counts[test_case.name] == 1, test_case.name .. " callback was not single-shot")
      end
    end)
    if not ok then
      fail(err)
      return
    end

    watchdog:close()
    print("transcript_audio IPC tests passed")
    vim.cmd("qa!")
  end, 200)
end

local function run_next()
  case_index = case_index + 1
  local test_case = cases[case_index]
  if not test_case then
    finish_tests()
    return
  end

  ipc.request({
    socket = socket,
    timeout_ms = test_case.timeout_ms or 1000,
    command = { "test", test_case.name },
  }, function(err, data)
    callback_counts[test_case.name] = (callback_counts[test_case.name] or 0) + 1

    local ok, assertion_error = pcall(function()
      assert(err == test_case.error, test_case.name .. " returned error: " .. vim.inspect(err))
      assert(data == test_case.data, test_case.name .. " returned data: " .. vim.inspect(data))
    end)
    if not ok then
      fail(assertion_error)
      return
    end

    run_next()
  end)
end

local missing_callback_count = 0
ipc.request({
  socket = socket .. ".missing",
  timeout_ms = 1000,
  command = { "test", "missing" },
}, function(err)
  missing_callback_count = missing_callback_count + 1
  if missing_callback_count ~= 1 or type(err) ~= "string" or not err:match("^Cannot connect to mpv:") then
    fail("missing socket returned an unexpected result: " .. vim.inspect(err))
    return
  end
  run_next()
end)
