-- lib/types/saw.lua
-- The saw voice type (S.lib.types_saw, 3.8): three detuned variable saws a
-- side through a resonant lowpass. Every key is shared: width, cutoff and
-- res keep Pulse's specs and defaults (so a pulse voice switched to saw
-- keeps its filter), detune is wave's. Registers its record
-- (S.register_voice_type, lib/state.lua) and returns an empty table. See
-- docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "saw",
    name = "saw",
    list_name = "saw",
    def = "strataSaw",
    param_order = {"freq", "width", "detune", "cutoff", "res", "amp", "pan"},
    -- the first type's defaults for its keys: resonator's freq, amp and
    -- pan, pulse's width, cutoff and res, wave's detune
    defaults = {freq = 100, width = 0.5, detune = 0.003, cutoff = 2000, res = 0.8, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      width = controlspec.new(0.05, 0.95, "lin", 0.01, 0.5),   -- pulse's
      detune = controlspec.new(0, 0.02, "lin", 0.001, 0.003),  -- wave's
      cutoff = controlspec.new(100, 8000, "exp", 10, 2000, "Hz"),  -- pulse's
      -- pulse's: rises with resonance, played as rq = PULSE_RES.mirror - res
      res = controlspec.new(0.1, 1, "lin", 0.01, 0.8),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {detune = "%.3f"},  -- wave's format (#386)
    main = {key = "width", label = "width", format = "%.2f"},
    note_main = "width",
    envelope = {attack = 3, release = 6},
  })

  return M
end
