-- strata_grid.lua
-- A monome grid in iii mode as one of Strata's grids (Strata 3.6, design
-- §9). Upload it to the grid with diii and make it the first script
-- (first('strata_grid.lua')); then set IO > remote > grid port to the MIDI
-- port norns shows the grid on ("iii grid"). It runs on the grid, never
-- on norns.
--
-- The protocol, version 1, on the grid's USB MIDI port:
--   grid to Strata: CC 0, 1, 2 on channel 1 = columns, rows, version (the
--     hello, at start and when asked); a key as a note on, channel
--     index // 128 + 1, note index % 128, index = (y - 1) * 16 + (x - 1),
--     velocity 127 down and 0 up
--   Strata to grid: CC 2 = 0 on channel 1 asks for the hello; a note on
--     sets the LED at the same index to its velocity (0 to 15); CC 3 = 0
--     shows what was sent (the frame end); CC 4 = level sets every LED
-- Needs iii 1.1.0 or later (event_grid, event_midi and device_version are
-- new there): on an older iii it shows a dim checkerboard and sends nothing.

local VERSION = 1
local STRIDE = 16
local PER_CHANNEL = 128
local HELLO_CHANNEL = 1
local KEY_DOWN = 127

if type(device_version) ~= "function" then
  -- older than iii 1.1.0: a fixed pattern, nothing forwarded
  for x = 1, grid_size_x() do
    for y = 1, grid_size_y() do
      if (x + y) % 2 == 0 then grid_led(x, y, 4) end
    end
  end
  grid_refresh()
else
  local function hello()
    midi_cc(0, grid_size_x(), HELLO_CHANNEL)
    midi_cc(1, grid_size_y(), HELLO_CHANNEL)
    midi_cc(2, VERSION, HELLO_CHANNEL)
  end

  function event_grid(x, y, z)
    local index = (y - 1) * STRIDE + (x - 1)
    local channel = math.floor(index / PER_CHANNEL) + 1
    midi_note_on(index % PER_CHANNEL, z > 0 and KEY_DOWN or 0, channel)
  end

  function event_midi(status_byte, data1, data2)
    local status = status_byte - status_byte % 16
    local channel = status_byte % 16 + 1
    if status == 0x90 and (channel == 1 or channel == 2) then
      local index = (channel - 1) * PER_CHANNEL + data1
      grid_led(index % STRIDE + 1, math.floor(index / STRIDE) + 1, data2)
    elseif status == 0xb0 and channel == HELLO_CHANNEL then
      if data1 == 2 then
        hello()
      elseif data1 == 3 then
        grid_refresh()
      elseif data1 == 4 then
        grid_led_all(data2)
        grid_refresh()
      end
    end
  end

  hello()
end
