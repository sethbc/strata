-- lib/types/sub.lua
-- The sub voice type (S.lib.types_sub): a drifting sub oscillator, 3.7's
-- voice 4, the one type without pan. Registers its record
-- (S.register_voice_type, lib/state.lua) and returns an empty table. See
-- docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "sub",
    name = "sub",
    list_name = "sub",
    def = "strataSub",
    param_order = {"freq", "drift", "amp"},
    defaults = {freq = 40, drift = 0.02, amp = 0.4},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 40, "Hz"),  -- step 0: MIDI notes keep exact pitch
      drift = controlspec.new(0.001, 0.1, "lin", 0.001, 0.02),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.4),
    },
    formats = {drift = "%.3f"},  -- a step finer than 0.01 shows three decimals (#386)
    main = {key = "drift", label = "drift", format = "%.3f"},
    note_main = "drift",
    envelope = {attack = 8, release = 12},
  })

  return M
end
