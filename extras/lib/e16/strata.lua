-- extras/lib/e16/strata.lua
-- A script for an OXI E16 scene: draws Strata's macros on the E16's rings,
-- labels and page title from the SysEx frames Strata sends (lib/io/controllers.lua,
-- docs/user/io/controllers.md). Load it into the scene with OXI's app. It is
-- never loaded by norns.
--
-- Every frame is F0 7D 53 54 <command> ... F7 (bytes[1] is F0):
--   01  sixteen values of two 7-bit bytes, high first (0 to 16383): the rings
--   02  <index 0 to 15> <4 characters>: the label under encoder index + 1
--   03  1 to 15 characters: the page title
-- The E16's indexes count from 1 (E16 manual 1.0.1a, sections 6.8 to 6.11),
-- so the script adds 1 to a frame's index. A frame with another header, the
-- wrong length or another command does nothing. It uses only string.char
-- and the E16's own globals (no table.concat, type or pairs), so it asks
-- little of the E16's Lua.

local HEADER = {0xF0, 0x7D, 0x53, 0x54}
local END = 0xF7
local COMMAND_AT = 5
local ENCODERS = 16
local RING_COMMAND, LABEL_COMMAND, TITLE_COMMAND = 1, 2, 3
local RING_FRAME_LENGTH = COMMAND_AT + 2 * ENCODERS + 1
local LABEL_CHARS = 4
local LABEL_FRAME_LENGTH = COMMAND_AT + 1 + LABEL_CHARS + 1
local TITLE_MAX = 15
local RING_MAX = 16383
local COLOR = 0

-- Whether the frame starts with the header, ends with F7 and holds only 7-bit data between
local function well_formed(bytes)
  local count = #bytes
  if count <= COMMAND_AT or bytes[count] ~= END then return false end
  for index = 1, #HEADER do
    if bytes[index] ~= HEADER[index] then return false end
  end
  for index = COMMAND_AT, count - 1 do
    local byte = bytes[index]
    if byte == nil or byte < 0 or byte > 127 then return false end
  end
  return true
end

local function text_of(bytes, first, last)
  local text = ""
  for index = first, last do text = text .. string.char(bytes[index]) end
  return text
end

function controller.onSysex(bytes)
  if bytes == nil or not well_formed(bytes) then return end
  local command = bytes[COMMAND_AT]
  if command == RING_COMMAND then
    if #bytes ~= RING_FRAME_LENGTH then return end
    for encoder = 1, ENCODERS do
      local at = COMMAND_AT + 2 * (encoder - 1) + 1
      local value = bytes[at] * 128 + bytes[at + 1]
      if value > RING_MAX then value = RING_MAX end
      leds.update(encoder, value, COLOR)
    end
  elseif command == LABEL_COMMAND then
    if #bytes ~= LABEL_FRAME_LENGTH then return end
    local index = bytes[COMMAND_AT + 1]
    if index >= ENCODERS then return end
    slots.update(index + 1, text_of(bytes, COMMAND_AT + 2, COMMAND_AT + 1 + LABEL_CHARS))
  elseif command == TITLE_COMMAND then
    local length = #bytes - COMMAND_AT - 1
    if length < 1 or length > TITLE_MAX then return end
    page.setTitle(text_of(bytes, COMMAND_AT + 1, #bytes - 1))
  end
end
