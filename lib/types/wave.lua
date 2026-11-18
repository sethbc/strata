-- lib/types/wave.lua
-- The wave voice type (S.lib.types_wave, 3.8): a wavetable voice that
-- morphs across the engine's bank of eight tables, from a sine to a bright
-- stack (\strataWave, lib/engine/StrataTypeWave.sc). Registers its record
-- (S.register_voice_type, lib/state.lua) and returns an empty table. See
-- docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "wave",
    name = "wave",
    list_name = "wave",
    def = "strataWave",
    param_order = {"freq", "morph", "morphRate", "morphDepth", "detune", "amp", "pan"},
    -- freq, amp and pan: the first type's defaults and specs
    defaults = {freq = 100, morph = 0.3, morphRate = 0.05, morphDepth = 0.2, detune = 0.003, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      morph = controlspec.new(0, 1, "lin", 0.01, 0.3),
      morphRate = controlspec.new(0.01, 1, "lin", 0.01, 0.05, "Hz"),
      morphDepth = controlspec.new(0, 1, "lin", 0.01, 0.2),
      detune = controlspec.new(0, 0.02, "lin", 0.001, 0.003),  -- saw's too
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {detune = "%.3f"},  -- three decimals for a step under 0.01 (#386)
    main = {key = "morph", label = "morph", format = "%.2f"},
    note_main = "morph",
    envelope = {attack = 3, release = 6},
  })

  return M
end
