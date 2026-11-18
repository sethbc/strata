-- lib/types/fm.lua
-- The fm voice type (S.lib.types_fm): two-operator FM, 3.7's voice 2.
-- Registers its record (S.register_voice_type, lib/state.lua) and returns
-- an empty table. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "fm",
    name = "fm",
    list_name = "fm",
    def = "strataFM",
    param_order = {"freq", "ratio", "index", "modFreq", "amp", "pan"},
    defaults = {freq = 80, ratio = 1.5, index = 2, modFreq = 0.05, amp = 0.25, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 80, "Hz"),  -- step 0: MIDI notes keep exact pitch
      ratio = controlspec.new(0.5, 8, "lin", 0.001, 1.5),    -- a fine step: ring's default is 1.618
      index = controlspec.new(0, 10, "lin", 0.1, 2),
      modFreq = controlspec.new(0.01, 1, "lin", 0.01, 0.05, "Hz"),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.25),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {ratio = "%.3f"},  -- a step finer than 0.01 shows three decimals (#386)
    main = {key = "index", label = "index", format = "%.1f"},
    note_main = "index",
    envelope = {attack = 5, release = 10},
  })

  return M
end
