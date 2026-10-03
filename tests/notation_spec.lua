local audio = require("transcript_audio")
local notation = require("transcript_audio.notation")

local function assert_equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), (message or "values differ") .. ": " .. vim.inspect(actual))
end

local function set_buffer(lines, row, column)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd("startinsert")
  vim.api.nvim_win_set_cursor(0, { row, column })
end

local function buffer_lines()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

audio.setup({
  mappings = false,
  notation_mappings = false,
})

set_buffer({ "hello" }, 1, 5)
vim.cmd("TranscriptNote coughs")
assert_equal(buffer_lines(), { "hello ((coughs))" }, "TranscriptNote command")

set_buffer({ "hello" }, 1, 5)
assert(notation.insert("coughs"))
assert_equal(buffer_lines(), { "hello ((coughs))" }, "marker at end")
assert_equal(vim.api.nvim_win_get_cursor(0), { 1, 16 }, "cursor after marker")

set_buffer({ "hello world" }, 1, 5)
assert(notation.insert("laughs"))
assert_equal(buffer_lines(), { "hello ((laughs)) world" }, "marker between words")

set_buffer({ "hello," }, 1, 5)
assert(notation.insert("pause"))
assert_equal(buffer_lines(), { "hello ((pause))," }, "marker before punctuation")

set_buffer({ "hello world" }, 1, 0)
assert(notation.insert("short_pause"))
assert_equal(buffer_lines(), { "(.) hello world" }, "marker at line start")

set_buffer({ "hello world" }, 1, 5)
assert(notation.insert("general_laughter"))
assert_equal(
  buffer_lines(),
  { "hello", "((General laughter))", "world" },
  "shared laughter on separate line"
)
assert_equal(vim.api.nvim_win_get_cursor(0), { 3, 0 }, "cursor after shared laughter")

set_buffer({ "hello world" }, 1, 5)
assert(notation.insert("uncertain"))
assert_equal(buffer_lines(), { "hello () world" }, "uncertain placeholder")
assert_equal(vim.api.nvim_win_get_cursor(0), { 1, 7 }, "cursor inside uncertain placeholder")

set_buffer({ "hello world" }, 1, 5)
assert(notation.insert("anonymise"))
assert_equal(buffer_lines(), { "hello [] world" }, "anonymisation placeholder")
assert_equal(vim.api.nvim_win_get_cursor(0), { 1, 7 }, "cursor inside anonymisation placeholder")

set_buffer({ "hello world" }, 1, 1)
vim.fn.setpos("'<", { 0, 1, 1, 0 })
vim.fn.setpos("'>", { 0, 1, 5, 0 })
assert(notation.wrap("uncertain"))
assert_equal(buffer_lines(), { "(hello) world" }, "visual uncertain wrapper")

set_buffer({ "hello world" }, 1, 1)
vim.fn.setpos("'<", { 0, 1, 7, 0 })
vim.fn.setpos("'>", { 0, 1, 11, 0 })
assert(notation.wrap("anonymise"))
assert_equal(buffer_lines(), { "hello [world]" }, "visual anonymisation wrapper")

local ok, error_message = notation.insert("does-not-exist")
assert(ok == nil and type(error_message) == "string", "unknown notation should fail cleanly")

audio.setup({
  mappings = true,
  notation_prefix = "<C-g>",
})
assert(vim.fn.maparg("<C-g>c", "i") ~= "", "cough mapping missing")
assert(vim.fn.maparg("<C-g>g", "i") ~= "", "general laughter mapping missing")
assert(vim.fn.maparg("<C-g>u", "x") ~= "", "visual uncertainty mapping missing")
assert(vim.fn.maparg("<C-g>c", "n") == "", "notation mapping must not be normal-mode mapping")

audio.setup({
  mappings = false,
})
assert(vim.fn.maparg("<C-g>c", "i") ~= "", "notation mappings should be independent of playback mappings")
assert(vim.fn.maparg("\\aa", "n") == "", "playback mappings should be disabled")

audio.setup({
  mappings = true,
  notation_mappings = false,
})
assert(vim.fn.maparg("<C-g>c", "i") == "", "notation_mappings=false should remove mappings")

print("transcript_audio notation tests passed")
