-- lib/types/ring.lua
-- The ring voice type (S.lib.types_ring): a ring modulator, 3.7's voice
-- 7. Registers its record (S.register_voice_type, lib/state.lua) and
-- returns an empty table. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "ring",
    name = "ring",
    list_name = "ring",
    def = "strataRing",
    param_order = {"freq", "ratio", "mod", "brightness", "amp", "pan"},
    defaults = {freq = 300, ratio = 1.618, mod = 0.2, brightness = 0.5, amp = 0.25, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 300, "Hz"),  -- step 0: MIDI notes keep exact pitch
      ratio = controlspec.new(0.5, 8, "lin", 0.001, 1.618),   -- fm's spec, ring's own default
      mod = controlspec.new(0.01, 2, "lin", 0.01, 0.2),       -- folder's spec
      brightness = controlspec.new(0, 1, "lin", 0.01, 0.5),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.25),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {ratio = "%.3f"},  -- fm's format (#386)
    main = {key = "ratio", label = "ratio", format = "%.2f"},
    note_main = "ratio",
    envelope = {attack = 3, release = 5},
  })

  return M
end
