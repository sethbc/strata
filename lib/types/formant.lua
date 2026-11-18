-- lib/types/formant.lua
-- The formant voice type (S.lib.types_formant, 3.8): two formant
-- oscillators a channel whose formants move between vowels. Its MAIN param
-- and per-note expression is formant, a scale on both formant frequencies.
-- Registers its record (S.register_voice_type, lib/state.lua) and returns
-- an empty table. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "formant",
    name = "formant",
    list_name = "vox",
    def = "strataFormant",
    param_order = {"freq", "formant", "vowel", "bw", "amp", "pan"},
    -- freq, amp and pan: the first type's defaults and specs (resonator's)
    defaults = {freq = 100, formant = 1, vowel = 0.5, bw = 0.5, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      formant = controlspec.new(0.5, 2, "lin", 0.01, 1),      -- a scale on both formant frequencies
      vowel = controlspec.new(0, 1, "lin", 0.01, 0.5),        -- f1 300-800 Hz, f2 2300-1100 Hz
      bw = controlspec.new(0.1, 1, "lin", 0.01, 0.5),         -- a formant's bandwidth / its frequency
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {},
    main = {key = "formant", label = "form", format = "%.2f"},
    note_main = "formant",
    envelope = {attack = 3, release = 6},
  })

  return M
end
