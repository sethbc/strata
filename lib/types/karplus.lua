-- lib/types/karplus.lua
-- The karplus voice type (S.lib.types_karplus): a plucked string
-- (Karplus-Strong), 3.7's voice 6. Registers its record
-- (S.register_voice_type, lib/state.lua) and returns an empty table. See
-- docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "karplus",
    name = "karplus",
    list_name = "karp",
    def = "strataKarplus",
    param_order = {"freq", "decay", "damping", "excite", "amp", "pan"},
    defaults = {freq = 200, decay = 4, damping = 0.5, excite = 0.3, amp = 0.35, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 200, "Hz"),  -- step 0: MIDI notes keep exact pitch
      decay = controlspec.new(0.5, 10, "lin", 0.1, 4, "s"),
      damping = controlspec.new(0.1, 0.9, "lin", 0.01, 0.5),
      excite = controlspec.new(0.1, 2, "lin", 0.01, 0.3, "Hz"),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.35),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {},
    main = {key = "decay", label = "decay", format = "%.1f s"},
    note_main = "decay",
    envelope = {attack = 0.01, release = 2},
  })

  return M
end
