local actions = require("transcript_audio.actions")
local audio = require("transcript_audio")
local ipc = require("transcript_audio.ipc")

local function assert_equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "values differ") .. ": " .. vim.inspect(actual))
end

local command_cases = {
  { "play", nil, { "set_property", "pause", false } },
  { "pause", nil, { "set_property", "pause", true } },
  { "toggle", nil, { "cycle", "pause" } },
  { "beginning", nil, { "seek", 0, "absolute" } },
  { "end", nil, { "seek", 100, "absolute-percent" } },
  { "forward", "5", { "seek", 5, "relative" } },
  { "forward", "10", { "seek", 10, "relative" } },
  { "forward", "30", { "seek", 30, "relative" } },
  { "back", "5", { "seek", -5, "relative" } },
  { "back", "10", { "seek", -10, "relative" } },
  { "back", "30", { "seek", -30, "relative" } },
  { "time", nil, { "get_property", "time-pos" } },
  { "load", "/tmp/interview with spaces.mp3", { "loadfile", "/tmp/interview with spaces.mp3", "replace" } },
}

for _, test_case in ipairs(command_cases) do
  local command, err = actions.command(test_case[1], test_case[2])
  assert(err == nil, test_case[1] .. " unexpectedly failed: " .. tostring(err))
  assert_equal(command, test_case[3], test_case[1] .. " command")
end

local invalid_cases = {
  { "load", nil, "missing load path" },
  { "forward", nil, "missing seek amount" },
  { "forward", "7", "unsupported seek amount" },
  { "back", "soon", "nonnumeric seek amount" },
  { "unknown", nil, "unknown action" },
}

for _, test_case in ipairs(invalid_cases) do
  local command, err = actions.command(test_case[1], test_case[2])
  assert(command == nil and type(err) == "string", test_case[3] .. " should fail cleanly")
end

assert_equal(audio.format_time(872.18), "14:32.18", "minute position")
assert_equal(audio.format_time(3672.18), "01:01:12.18", "hour position")
assert_equal(audio.format_time(59.999), "01:00.00", "rounded position")
for _, unusable in ipairs({ "12", false, -1, math.huge }) do
  local position, err = audio.format_time(unusable)
  assert(position == nil and type(err) == "string", "unusable time should fail cleanly")
end
do
  local position, err = audio.format_time(nil)
  assert(position == nil and type(err) == "string", "nil time should fail cleanly")
end

local original_request = ipc.request
local original_notify = vim.notify
local requests = {}
local notifications = {}
local next_error
local next_data

ipc.request = function(request, callback)
  requests[#requests + 1] = request
  callback(next_error, next_data)
end
vim.notify = function(message, level)
  notifications[#notifications + 1] = { message = message, level = level }
end

local function reset_test_state()
  requests = {}
  notifications = {}
  next_error = nil
  next_data = nil
end

audio.setup({ socket = "/tmp/actions-test.sock", timeout_ms = 123, mappings = false })

local test_dir = vim.fn.tempname()
assert(vim.fn.mkdir(test_dir, "p") == 1, "could not create test directory")
local spaced_path = test_dir .. "/interview with spaces.mp3"
assert(vim.fn.writefile({ "test media" }, spaced_path) == 0, "could not create test media")

vim.cmd("Audio load " .. spaced_path)
assert_equal(#requests, 1, "load request count")
assert_equal(requests[1].command, { "loadfile", spaced_path, "replace" }, "load path with spaces")
assert_equal(requests[1].socket, "/tmp/actions-test.sock", "configured socket")
assert_equal(requests[1].timeout_ms, 123, "configured timeout")

reset_test_state()
local old_cwd = vim.fn.getcwd()
vim.cmd("cd " .. vim.fn.fnameescape(test_dir))
vim.cmd("Audio load interview\\ with\\ spaces.mp3")
vim.cmd("cd " .. vim.fn.fnameescape(old_cwd))
assert_equal(#requests, 1, "relative load request count")
assert_equal(requests[1].command, { "loadfile", spaced_path, "replace" }, "absolute load path")

reset_test_state()
local old_home = vim.env.HOME
vim.env.HOME = test_dir
local home_path = test_dir .. "/home recording.mp3"
assert(vim.fn.writefile({ "test media" }, home_path) == 0, "could not create home test media")
vim.cmd("Audio load ~/home recording.mp3")
vim.env.HOME = old_home
assert_equal(#requests, 1, "tilde load request count")
assert_equal(requests[1].command, { "loadfile", home_path, "replace" }, "expanded tilde path")

reset_test_state()
vim.cmd("Audio load")
assert_equal(#requests, 0, "missing path request count")
assert(notifications[1].message:match("^Transcript audio:"), "missing path notification prefix")

reset_test_state()
vim.cmd("Audio load " .. test_dir .. "/missing.mp3")
assert_equal(#requests, 0, "invalid path request count")
assert(notifications[1].message:match("^Transcript audio:"), "invalid path notification prefix")

reset_test_state()
vim.cmd("Audio forward 7")
assert_equal(#requests, 0, "invalid seek request count")
assert(notifications[1].message:match("^Transcript audio:"), "invalid seek notification prefix")

reset_test_state()
next_error = "Cannot connect to mpv: connection refused"
local ok, run_error = pcall(audio.run, "play")
assert(ok, "transport error escaped as a stack trace: " .. tostring(run_error))
assert_equal(#notifications, 1, "transport error notification count")
assert(notifications[1].message:match("^Transcript audio:"), "transport error notification prefix")

reset_test_state()
next_data = 872.18
audio.run("time")
assert_equal(notifications[1].message, "Audio: 14:32.18", "time notification")

reset_test_state()
next_data = nil
audio.run("time")
assert_equal(#notifications, 1, "nil time notification count")
assert(notifications[1].message:match("^Transcript audio:"), "nil time notification prefix")

ipc.request = original_request
vim.notify = original_notify
vim.fn.delete(test_dir, "rf")

print("transcript_audio action tests passed")
