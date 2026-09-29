local M = {}

local markers = {
  coughs = {
    text = "((coughs))",
    description = "Insert ((coughs))",
  },
  laughs = {
    text = "((laughs))",
    description = "Insert ((laughs))",
  },
  general_laughter = {
    text = "((General laughter))",
    line = true,
    description = "Insert ((General laughter)) on a separate line",
  },
  pause = {
    text = "((pause))",
    description = "Insert ((pause))",
  },
  short_pause = {
    text = "(.)",
    description = "Insert (.)",
  },
  long_pause = {
    text = "((long pause))",
    description = "Insert ((long pause))",
  },
  sighs = {
    text = "((sighs))",
    description = "Insert ((sighs))",
  },
  long_exhale = {
    text = "((long exhale))",
    description = "Insert ((long exhale))",
  },
  inaudible = {
    text = "((inaudible))",
    description = "Insert ((inaudible))",
  },
  overlap = {
    text = "((in overlap))",
    description = "Insert ((in overlap))",
  },
}

local placeholders = {
  uncertain = {
    text = "()",
    cursor = 1,
    description = "Insert an uncertain-hearing placeholder",
  },
  reported = {
    text = '""',
    cursor = 1,
    description = "Insert a reported-speech placeholder",
  },
  anonymise = {
    text = "[]",
    cursor = 1,
    description = "Insert an anonymisation placeholder",
  },
}

local punctuation_without_space = {
  [","] = true,
  ["."] = true,
  [";"] = true,
  [":"] = true,
  ["!"] = true,
  ["?"] = true,
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
  ["%"] = true,
}

local function split_lines(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  return lines
end

local function current_position()
  local position = vim.api.nvim_win_get_cursor(0)
  local row = position[1] - 1
  local column = position[2]
  local lines = vim.api.nvim_buf_get_lines(0, row, row + 1, false)
  return row, column, lines[1] or ""
end

local function set_cursor(row, column)
  vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

local function replace_at_cursor(text, row, column, cursor_offset)
  vim.api.nvim_buf_set_text(0, row, column, row, column, split_lines(text))

  local lines = split_lines(text)
  local last_line = lines[#lines]
  local end_row = row + #lines - 1
  local end_column

  if #lines == 1 then
    end_column = column + #last_line
  else
    end_column = #last_line
  end

  if cursor_offset then
    if #lines ~= 1 then
      error("cursor offsets are only supported for single-line insertions")
    end
    end_column = column + cursor_offset
  end

  set_cursor(end_row, end_column)
end

local function needs_leading_space(before)
  if before == "" or before:match("%s$") then
    return false
  end

  local final_character = before:sub(-1)
  return final_character ~= "(" and final_character ~= "["
    and final_character ~= "{" and final_character ~= '"'
end

local function needs_trailing_space(after)
  if after == "" or after:match("^%s") then
    return false
  end

  return not punctuation_without_space[after:sub(1, 1)]
end

local function insert_inline(text, cursor_offset)
  local row, column, line = current_position()
  local before = line:sub(1, column)
  local after = line:sub(column + 1)
  local prefix = needs_leading_space(before) and " " or ""
  local suffix = needs_trailing_space(after) and " " or ""

  replace_at_cursor(prefix .. text .. suffix, row, column, #prefix + cursor_offset)
end

local function insert_line(text)
  local row, column, line = current_position()

  if column == 0 then
    replace_at_cursor(text .. "\n", row, column)
    set_cursor(row + 1, 0)
    return
  end

  local before = line:sub(1, column):gsub("%s$", "")
  local after = line:sub(column + 1):gsub("^%s", "")
  vim.api.nvim_buf_set_text(0, row, 0, row, #line, { before, text, after })
  set_cursor(row + 2, 0)
end

local function ordered_selection()
  local start = vim.fn.getpos("'<")
  local finish = vim.fn.getpos("'>")

  if start[2] == 0 or finish[2] == 0 then
    return nil, "No visual selection"
  end

  local start_row = start[2] - 1
  local start_column = start[3] - 1
  local finish_row = finish[2] - 1
  local finish_column = finish[3]

  if start_row > finish_row
    or (start_row == finish_row and start_column > finish_column)
  then
    start_row, finish_row = finish_row, start_row
    start_column, finish_column = finish_column - 1, start_column + 1
  end

  return start_row, start_column, finish_row, finish_column
end

---Insert a fixed protocol marker or an empty placeholder at the cursor.
---@param name string
---@return boolean|nil ok
---@return string|nil error
function M.insert(name)
  local marker = markers[name] or placeholders[name]
  if not marker then
    return nil, "Unknown transcript notation: " .. tostring(name)
  end

  if marker.line then
    insert_line(marker.text)
  else
    insert_inline(marker.text, marker.cursor or #marker.text)
  end

  return true
end

---Wrap the current visual selection with a pair of delimiters.
---@param left string
---@param right string
---@return boolean|nil ok
---@return string|nil error
function M.wrap_selection(left, right)
  if type(left) ~= "string" or type(right) ~= "string" then
    return nil, "Transcript notation delimiters must be strings"
  end

  local start_row, start_column, finish_row, finish_column = ordered_selection()
  if not start_row then
    return nil, start_column
  end

  local selected = vim.api.nvim_buf_get_text(
    0,
    start_row,
    start_column,
    finish_row,
    finish_column,
    {}
  )
  if #selected == 0 then
    return nil, "Visual selection is empty"
  end

  selected[1] = left .. selected[1]
  selected[#selected] = selected[#selected] .. right
  vim.api.nvim_buf_set_text(
    0,
    start_row,
    start_column,
    finish_row,
    finish_column,
    selected
  )

  set_cursor(start_row + #selected - 1, #selected[#selected])
  return true
end

---Wrap a protocol concept using its standard delimiters.
---@param name string
---@return boolean|nil ok
---@return string|nil error
function M.wrap(name)
  local delimiters = {
    uncertain = { "(", ")" },
    reported = { '"', '"' },
    anonymise = { "[", "]" },
  }
  local pair = delimiters[name]
  if not pair then
    return nil, "Unknown transcript wrapper: " .. tostring(name)
  end
  return M.wrap_selection(pair[1], pair[2])
end

function M.names()
  local names = {}
  for name in pairs(markers) do
    names[#names + 1] = name
  end
  for name in pairs(placeholders) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

function M.description(name)
  local entry = markers[name] or placeholders[name]
  return entry and entry.description or nil
end

return M
