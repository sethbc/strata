-- lib/types/noise.lua
-- The noise voice type (S.lib.types_noise, 3.8): pink noise and dust
-- through a lowpass (color) and a resonant bank of four at the voice's
-- pitch (q its width, the main; bank its mix against the plain noise).
-- The engine's \strataNoise (lib/engine/StrataTypeNoise.sc). Registers its
-- record (S.register_voice_type, lib/state.lua) and returns an empty table.
-- See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "noise",
    name = "noise",
    list_name = "noise",
    def = "strataNoise",
    param_order = {"freq", "color", "grit", "dust", "q", "bank", "amp", "pan"},
    -- freq, amp and pan: the first type's specs and defaults
    defaults = {freq = 100, color = 0.5, grit = 0.3, dust = 8, q = 0.05, bank = 0.7, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      color = controlspec.new(0, 1, "lin", 0.01, 0.5),       -- a lowpass at 200-16000 Hz, exponential in the def
      grit = controlspec.new(0, 1, "lin", 0.01, 0.3),        -- the dust against the noise
      dust = controlspec.new(0.5, 50, "exp", 0, 8, "/s"),    -- the dust's bursts a second
      q = controlspec.new(0.005, 1, "exp", 0, 0.05),         -- the bank's rq: lower is narrower
      bank = controlspec.new(0, 1, "lin", 0.01, 0.7),        -- the bank against the plain noise
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {q = "%.3f"},  -- three decimals for a step under 0.01 (#386)
    main = {key = "q", label = "q", format = "%.3f"},
    note_main = "q",
    envelope = {attack = 3, release = 6},
  })

  return M
end
