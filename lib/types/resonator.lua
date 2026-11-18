-- lib/types/resonator.lua
-- The resonator voice type (S.lib.types_resonator): a resonant filter
-- bank over noise, 3.7's voice 1. Its MAIN param is its pitch, so its
-- per-note expression moves rq. Registers its record (S.register_voice_type,
-- lib/state.lua) and returns an empty table. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "resonator",
    name = "resonator",
    list_name = "reso",
    def = "strataResonator",
    param_order = {"freq", "rq", "noise", "mod1", "mod2", "amp", "pan"},
    defaults = {freq = 100, rq = 0.1, noise = 0.5, mod1 = 0.1, mod2 = 0.15, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      rq = controlspec.new(0.01, 1, "lin", 0.01, 0.1),
      noise = controlspec.new(0, 1, "lin", 0.01, 0.5),
      mod1 = controlspec.new(0.01, 1, "lin", 0.01, 0.1, "Hz"),
      mod2 = controlspec.new(0.01, 1, "lin", 0.01, 0.15, "Hz"),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {},
    main = {key = "freq", label = "freq", format = "%.0f Hz"},
    note_main = "rq",
    envelope = {attack = 4, release = 8},
  })

  return M
end
