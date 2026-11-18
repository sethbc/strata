-- strata_arc.lua
-- A monome arc in iii mode (the 2025 edition) as the arc Strata follows
-- (Strata 3.6, design §9). Upload it to the arc with diii and make it the
-- first script (first('strata_arc.lua')); then set IO > remote > arc port
-- to the MIDI port norns shows the arc on ("iii arc"). It runs on the arc,
-- never on norns. A monome arc connected to norns takes over from it.
--
-- The protocol, version 1, on the arc's USB MIDI port:
--   arc to Strata: CC 0, 1, 2 on channel 1 = 0, 4 (rings), version (the
--     hello, at start and when asked); ring n turned by d as CC 15 + n on
--     channel 3 with value 64 + d, d from -63 to 63 (a larger turn is
--     split); the key as note 0 on channel 3, velocity 127 down and 0 up
--   Strata to arc: CC 2 = 0 on channel 1 asks for the hello; a note on,
--     channel 3 + index // 128, note index % 128, sets the LED at index =
--     (ring - 1) * 64 + (led - 1) to its velocity (0 to 15); CC 3 = 0 shows
--     what was sent (the frame end); CC 4 = level sets every LED
-- Needs iii 1.1.0 or later (event_arc, event_arc_key, event_midi and
-- device_version are new there): on an older iii it lights every eighth
-- LED and sends nothing.

local VERSION = 1
local RINGS = 4
local LEDS = 64
local PER_CHANNEL = 128
local HELLO_CHANNEL = 1
local ARC_CHANNEL = 3
local CENTER = 64
local MAX_STEP = 63
local KEY_DOWN = 127

if type(device_version) ~= "function" then
  -- older than iii 1.1.0: a fixed pattern, nothing forwarded
  for ring = 1, RINGS do
    for led = 1, LEDS, 8 do arc_led(ring, led, 4) end
  end
  arc_refresh()
else
  local function hello()
    midi_cc(0, 0, HELLO_CHANNEL)
    midi_cc(1, RINGS, HELLO_CHANNEL)
    midi_cc(2, VERSION, HELLO_CHANNEL)
  end

  function event_arc(n, d)
    while d ~= 0 do
      local step = math.max(-MAX_STEP, math.min(MAX_STEP, d))
      midi_cc(15 + n, CENTER + step, ARC_CHANNEL)
      d = d - step
    end
  end

  function event_arc_key(z)
    midi_note_on(0, z > 0 and KEY_DOWN or 0, ARC_CHANNEL)
  end

  function event_midi(status_byte, data1, data2)
    local status = status_byte - status_byte % 16
    local channel = status_byte % 16 + 1
    if status == 0x90 and (channel == ARC_CHANNEL or channel == ARC_CHANNEL + 1) then
      local index = (channel - ARC_CHANNEL) * PER_CHANNEL + data1
      arc_led(math.floor(index / LEDS) + 1, index % LEDS + 1, data2)
    elseif status == 0xb0 and channel == HELLO_CHANNEL then
      if data1 == 2 then
        hello()
      elseif data1 == 3 then
        arc_refresh()
      elseif data1 == 4 then
        arc_led_all(data2)
        arc_refresh()
      end
    end
  end

  hello()
end
