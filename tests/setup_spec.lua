local audio = require("transcript_audio")

local function assert_equal(actual, expected, message)
  assert(actual == expected, (message or "values differ") .. ": " .. vim.inspect(actual))
end

local old_socket = vim.env.TRANSCRIPT_MPV_SOCKET
local old_runtime_dir = vim.env.XDG_RUNTIME_DIR
local uid = (vim.uv or vim.loop).getuid()

vim.env.TRANSCRIPT_MPV_SOCKET = "/tmp/transcript-audio-env.sock"
local environment_config = audio.resolve_config({})
assert_equal(environment_config.socket, "/tmp/transcript-audio-env.sock", "environment socket")

local explicit_config = audio.resolve_config({
  socket = "/tmp/transcript-audio-explicit.sock",
  timeout_ms = 1500,
  mappings = false,
})
assert_equal(explicit_config.socket, "/tmp/transcript-audio-explicit.sock", "explicit socket")
assert_equal(explicit_config.timeout_ms, 1500, "explicit timeout")
assert_equal(explicit_config.mappings, false, "mapping switch")

vim.env.TRANSCRIPT_MPV_SOCKET = nil
vim.env.XDG_RUNTIME_DIR = "/tmp/runtime-dir"
assert_equal(
  audio.resolve_config({}).socket,
  "/tmp/runtime-dir/transcript-mpv.sock",
  "runtime directory socket"
)

vim.env.XDG_RUNTIME_DIR = nil
assert_equal(
  audio.resolve_config({}).socket,
  "/run/user/" .. uid .. "/transcript-mpv.sock",
  "fallback socket"
)

vim.env.TRANSCRIPT_MPV_SOCKET = old_socket
vim.env.XDG_RUNTIME_DIR = old_runtime_dir

audio.setup({ mappings = false })
assert_equal(audio.config.mappings, false, "setup mapping switch")
assert(vim.api.nvim_get_commands({ builtin = false }).Audio, "setup should create :Audio")

local function normal_mapping(lhs)
  for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
    if mapping.lhs == lhs then
      return mapping
    end
  end
end

local function any_mapping(mode, lhs)
  for _, mapping in ipairs(vim.api.nvim_get_keymap(mode)) do
    if mapping.lhs == lhs then
      return mapping
    end
  end
end

vim.g.mapleader = ","
audio.setup({ socket = "/tmp/transcript-audio-second.sock" })
for _, lhs in ipairs({
  ",aa", ",ap", ",as", ",ah", ",al", ",aj", ",ak",
  ",aH", ",aL", ",a0", ",a$", ",at",
}) do
  assert(normal_mapping(lhs), "default normal mapping missing: " .. lhs)
  assert(not any_mapping("i", lhs), "default mapping must not be installed in insert mode: " .. lhs)
end

assert_equal(audio.config.socket, "/tmp/transcript-audio-second.sock", "repeated setup socket")
assert(vim.api.nvim_get_commands({ builtin = false }).Audio, "repeated setup should keep :Audio")

audio.setup({ socket = "/tmp/transcript-audio-third.sock" })
assert(normal_mapping(",aa"), "repeated setup should keep default mappings")

audio.setup({ mappings = false })
assert(not normal_mapping(",aa"), "mappings=false should remove installed default mappings")

print("transcript_audio setup tests passed")
