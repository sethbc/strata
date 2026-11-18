-- lib/types/additive.lua
-- The additive voice type (S.lib.types_additive, 3.8): a bank of sine
-- partials, with a tilt, a stretch, an odd/even balance and one slow
-- wander for every partial. Registers its record (S.register_voice_type,
-- lib/state.lua) and returns an empty table. Its def, \strataAdditive, is
-- lib/engine/StrataTypeAdditive.sc's. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "additive",
    name = "additive",
    list_name = "add",
    def = "strataAdditive",
    param_order = {"freq", "tilt", "stretch", "oddEven", "wander", "amp", "pan"},
    -- freq, amp and pan: the first type's defaults (the resonator's)
    defaults = {freq = 100, tilt = 1, stretch = 0, oddEven = 0.5, wander = 0.2, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 100, "Hz"),  -- step 0: MIDI notes keep exact pitch
      -- partial k's level is k ^ -tilt: 0 all equal, 3 almost a sine
      tilt = controlspec.new(0, 3, "lin", 0.01, 1),
      -- partial k at k ^ (1 + 0.05 x stretch): 0 harmonic
      stretch = controlspec.new(-1, 1, "lin", 0.01, 0),
      -- 0 the odd partials only, 0.5 all, 1 the even only (the fundamental always)
      oddEven = controlspec.new(0, 1, "lin", 0.01, 0.5),
      wander = controlspec.new(0.01, 1, "lin", 0.01, 0.2, "Hz"),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {},
    main = {key = "tilt", label = "tilt", format = "%.2f"},
    note_main = "tilt",
    envelope = {attack = 4, release = 8},
  })

  return M
end
