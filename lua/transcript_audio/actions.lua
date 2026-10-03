local M = {}

local commands = {
  play = { "set_property", "pause", false },
  pause = { "set_property", "pause", true },
  toggle = { "cycle", "pause" },
  beginning = { "seek", 0, "absolute" },
  ["end"] = { "seek", 100, "absolute-percent" },
  time = { "get_property", "time-pos" },
}

local seek_amounts = {
  [5] = true,
  [10] = true,
  [30] = true,
}

local function has_argument(argument)
  return argument ~= nil and tostring(argument):match("%S") ~= nil
end

local function speed_command(argument)
  if not has_argument(argument) then
    return nil, "Speed percentage is required (use 0 to 200)"
  end

  local percentage = tostring(argument)
  if percentage:sub(-1) == "%" then
    percentage = percentage:sub(1, -2)
  end

  if not percentage:match("^%d+%.?%d*$") then
    return nil, "Speed percentage must be numeric"
  end

  percentage = tonumber(percentage)
  if not percentage or percentage < 0 or percentage > 200 then
    return nil, "Speed percentage must be between 0 and 200"
  end

  return { "set_property", "speed", percentage / 100 }
end

local function parse_timestamp(argument)
  if not has_argument(argument) then
    return nil, "Timestamp is required (use MM:SS or HH:MM:SS)"
  end

  local timestamp = tostring(argument):match("^%s*(.-)%s*$")
  local parts = {}
  for part in timestamp:gmatch("[^:]+") do
    parts[#parts + 1] = part
  end

  if timestamp == "" or timestamp:match("^:") or timestamp:match(":$")
    or timestamp:find("::", 1, true)
  then
    return nil, "Timestamp must be MM:SS, HH:MM:SS, or seconds"
  end

  local seconds
  if #parts == 1 then
    if not parts[1]:match("^%d+%.?%d*$") then
      return nil, "Timestamp must be MM:SS, HH:MM:SS, or seconds"
    end
    seconds = tonumber(parts[1])
  elseif #parts == 2 then
    if not parts[1]:match("^%d+$") or not parts[2]:match("^%d+%.?%d*$") then
      return nil, "Timestamp must be MM:SS, HH:MM:SS, or seconds"
    end
    local minutes = tonumber(parts[1])
    local remaining = tonumber(parts[2])
    if remaining >= 60 then
      return nil, "Timestamp seconds must be less than 60"
    end
    seconds = minutes * 60 + remaining
  elseif #parts == 3 then
    if not parts[1]:match("^%d+$")
      or not parts[2]:match("^%d+$")
      or not parts[3]:match("^%d+%.?%d*$")
    then
      return nil, "Timestamp must be MM:SS, HH:MM:SS, or seconds"
    end
    local hours = tonumber(parts[1])
    local minutes = tonumber(parts[2])
    local remaining = tonumber(parts[3])
    if minutes >= 60 then
      return nil, "Timestamp minutes must be less than 60"
    end
    if remaining >= 60 then
      return nil, "Timestamp seconds must be less than 60"
    end
    seconds = hours * 3600 + minutes * 60 + remaining
  else
    return nil, "Timestamp must be MM:SS, HH:MM:SS, or seconds"
  end

  if not seconds or seconds < 0 or seconds == math.huge then
    return nil, "Timestamp must be non-negative"
  end
  return seconds
end

local function seek_command(argument)
  local seconds, error_message = parse_timestamp(argument)
  if not seconds then
    return nil, error_message
  end
  return { "seek", seconds, "absolute" }
end

M.parse_timestamp = parse_timestamp

---Convert a validated user-facing action into an mpv command array.
---@param action string|nil
---@param argument string|number|nil
---@return table|nil command
---@return string|nil error
function M.command(action, argument)
  if type(action) ~= "string" or action == "" then
    return nil, "Missing action"
  end

  if action == "load" then
    if not has_argument(argument) then
      return nil, "Usage: :Audio load /path/to/file.mp3"
    end
    return { "loadfile", tostring(argument), "replace" }
  end

  if action == "speed" then
    return speed_command(argument)
  end

  if action == "seek" then
    return seek_command(argument)
  end

  if action == "forward" or action == "back" then
    if not has_argument(argument) then
      return nil, "Seek amount is required (use 5, 10, or 30)"
    end

    local seconds = tonumber(argument)
    if not seconds then
      return nil, "Seek amount must be numeric"
    end
    if not seek_amounts[seconds] then
      return nil, "Seek amount must be 5, 10, or 30 seconds"
    end

    if action == "back" then
      seconds = -seconds
    end
    return { "seek", seconds, "relative" }
  end

  local command = commands[action]
  if not command then
    return nil, "Unknown action: " .. action
  end
  if has_argument(argument) then
    return nil, action .. " does not accept an argument"
  end

  local copy = {}
  for index, value in ipairs(command) do
    copy[index] = value
  end
  return copy
end

return M
