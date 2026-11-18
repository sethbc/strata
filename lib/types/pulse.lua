-- lib/types/pulse.lua
-- The pulse voice type (S.lib.types_pulse): a filtered pulse, 3.7's voice
-- 5. Registers its record (S.register_voice_type, lib/state.lua) and
-- returns an empty table. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "pulse",
    name = "pulse",
    list_name = "pulse",
    def = "strataPulse",
    param_order = {"freq", "width", "cutoff", "res", "amp", "pan"},
    defaults = {freq = 120, width = 0.5, cutoff = 2000, res = 0.8, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 120, "Hz"),  -- step 0: MIDI notes keep exact pitch
      width = controlspec.new(0.05, 0.95, "lin", 0.01, 0.5),
      cutoff = controlspec.new(100, 8000, "exp", 10, 2000, "Hz"),
      -- rises with resonance: 0.8 is the filter's rq 0.3, 3.2's default (#314)
      res = controlspec.new(0.1, 1, "lin", 0.01, 0.8),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {},
    main = {key = "width", label = "width", format = "%.2f"},
    note_main = "width",
    envelope = {attack = 2, release = 4},
  })

  return M
end
