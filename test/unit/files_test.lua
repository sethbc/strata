-- test/unit/files_test.lua
-- The neutral lib/files.lua: its functions answer as pinned and send
-- nothing until its Wave 1 package fills them
-- Run alone: lua test/run.lua files

return function(h)
local test, assert_equal, load_strata, local_value = h.test, h.assert_equal, h.load_strata, h.local_value
local finish_startup = h.finish_startup

test("the neutral files answers as pinned and sends nothing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local files = S.lib.files
  context.clear_engine_calls()
  assert_equal(files.folder_for(1), _path.audio)
  assert_equal(files.random_into(1), false)
  assert_equal(files.fill_empty(), 0)
  files.note_chosen("/x.wav"); assert_equal(files.last_folder, nil)
  assert_equal(#context.engine_calls, 0, "no engine call")
end)

end
