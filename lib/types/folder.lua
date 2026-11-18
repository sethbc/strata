-- lib/types/folder.lua
-- The folder voice type (S.lib.types_folder): a wavefolder, 3.7's voice
-- 3. Registers its record (S.register_voice_type, lib/state.lua) and
-- returns an empty table. See docs/notes/lua/types.md

return function(S)
  local M = {}

  S.register_voice_type({
    key = "folder",
    name = "folder",
    list_name = "fold",
    def = "strataFolder",
    param_order = {"freq", "fold", "mod", "amp", "pan"},
    defaults = {freq = 60, fold = 1, mod = 0.2, amp = 0.3, pan = 0},
    specs = {
      freq = controlspec.new(20, 2000, "exp", 0, 60, "Hz"),  -- step 0: MIDI notes keep exact pitch
      fold = controlspec.new(0.1, 5, "lin", 0.1, 1),
      mod = controlspec.new(0.01, 2, "lin", 0.01, 0.2),
      amp = controlspec.new(0, 1, "lin", 0.01, 0.3),
      pan = controlspec.new(-1, 1, "lin", 0.01, 0),
    },
    formats = {},
    main = {key = "fold", label = "fold", format = "%.1f"},
    note_main = "fold",
    envelope = {attack = 3, release = 6},
  })

  return M
end
