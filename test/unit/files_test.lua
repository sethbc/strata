-- test/unit/files_test.lua
-- lib/files.lua: the folder a slot's files come from, a random file into a
-- slot, and filling the empty slots
-- Run alone: lua test/run.lua files

return function(h)
local test, assert_equal, assert_true = h.test, h.assert_equal, h.assert_true
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

-- A folder of empty files under the context's audio folder; its path ends in "/"
local function make_folder(context, name, files)
  local folder = context.audio_dir .. name .. "/"
  util.make_dir(folder)
  for _, file in ipairs(files) do
    if file:sub(-1) == "/" then util.make_dir(folder .. file) else io.open(folder .. file, "w"):close() end
  end
  return folder
end

-- The text of the BUFFER page's current hint-row flash
local function flash_text()
  h.show_page("BUFFER")   -- the hints flash shows only while BUFFER is up
  return local_value("S").lib.ui_flash.text("hints")
end

test("folder_for uses the slot's file, then the last chosen folder, then _path.audio", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  load_buffer(1, "/a/x.wav")
  assert_equal(files.folder_for(1), "/a/", "the slot's own file")
  assert_equal(files.folder_for(2), _path.audio, "a fresh load: nothing chosen yet")
  files.note_chosen("/b/y.wav")
  assert_equal(files.last_folder, "/b/", "note_chosen remembers the folder")
  assert_equal(files.folder_for(2), "/b/", "an empty slot follows the last chosen folder")
  assert_equal(files.folder_for(1), "/a/", "a slot with a file keeps its own")
  clear_buffer(1)
  assert_equal(files.folder_for(1), "/b/", "a cleared slot has no file")
end)

-- #465: util.scandir puts the folder between double quotes, where the shell
-- still reads ", $, ` and \: such a folder listed nothing, and $(...) ran
test("a folder named with a quote, a dollar sign, a backtick or a command lists its files and runs nothing", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local marker = context.audio_dir .. "f465_marker"
  local names = { 'pack "one"', "kit $HOME", "it's", "tick `id`", "back\\slash", "-rf", "semi; touch " .. marker,
    "$(touch " .. marker .. ")", "`touch " .. marker .. "`", "a b  c", "glob *?[x]{y}" }
  os.execute("mkdir -p '" .. context.audio_dir .. "'")
  for index, name in ipairs(names) do
    local folder = context.audio_dir .. name .. "/"
    -- made without a shell reading the name: mkdir gets it as one single-quoted word
    os.execute("mkdir -p -- '" .. folder:gsub("'", "'\\''") .. "'")
    for _, file in ipairs({ "a.wav", "b.wav" }) do io.open(folder .. file, "w"):close() end
    local slot = (index - 1) % local_value("NUM_BUFFERS") + 1
    clear_buffer(slot)
    files.note_chosen(folder .. "x.wav")
    context.clear_engine_calls()
    assert_true(files.random_into(slot), "a file loads from " .. name)
    local path = context.calls_named("loadBuffer")[1].args[2]
    assert_true(path == folder .. "a.wav" or path == folder .. "b.wav", "from that folder: " .. path)
  end
  assert_true(not util.file_exists(marker), "no folder name ran as a command")
  -- fill_empty lists the same way
  for slot = 1, local_value("NUM_BUFFERS") do clear_buffer(slot) end
  files.note_chosen(context.audio_dir .. 'pack "one"/x.wav')
  local_value("S").buffer_page.slot = 1
  assert_equal(files.fill_empty(), 2, "both files of the quoted folder fill slots")
end)

test("a folder that cannot be listed says so and loads nothing", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  files.note_chosen(context.audio_dir .. "gone/x.wav")
  context.clear_engine_calls()
  assert_equal(files.random_into(1), false)
  assert_equal(flash_text(), "cannot open gone/")   -- the folder below _path.audio (#432)
  assert_equal(files.fill_empty(), 0)
  assert_equal(#context.calls_named("loadBuffer"), 0)
  -- an empty folder is a different message
  local folder = make_folder(context, "nothing", { "notes.txt" })
  files.note_chosen(folder .. "x.wav")
  assert_equal(files.random_into(1), false)
  assert_equal(flash_text(), "no files in nothing/")
end)

test("random_into keeps sound files only and never repeats the current one", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local folder = make_folder(context, "random", { "a.wav", "B.FLAC", "c.txt", ".d.wav", "sub/" })
  math.randomseed(7)
  files.note_chosen(folder .. "x.wav")
  for _ = 1, 12 do
    clear_buffer(1)
    context.clear_engine_calls()
    assert_true(files.random_into(1), "loaded")
    local call = context.calls_named("loadBuffer")[1]
    local name = call.args[2]:match("[^/]*$")
    assert_true(name == "a.wav" or name == "B.FLAC", "only sound files: " .. name)
    assert_equal(call.args[3], 0, "from the start")
  end
  load_buffer(1, folder .. "a.wav")
  for _ = 1, 6 do
    context.clear_engine_calls()
    assert_true(files.random_into(1))
    assert_equal(context.calls_named("loadBuffer")[1].args[2], folder .. "B.FLAC", "never the current file")
    assert_true(files.random_into(1))
    assert_equal(context.calls_named("loadBuffer")[2].args[2], folder .. "a.wav", "and back")
  end
  assert_equal(flash_text(), "buf 1: a.wav", "the flash names the file")
end)

test("random_into loads the only file again when the folder holds one", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local folder = make_folder(context, "one", { "only.wav" })
  load_buffer(1, folder .. "only.wav")
  context.clear_engine_calls()
  assert_true(files.random_into(1))
  assert_equal(context.calls_named("loadBuffer")[1].args[2], folder .. "only.wav")
end)

test("an empty folder flashes no files in it", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local folder = make_folder(context, "empty", { "notes.txt", "sub/" })
  files.note_chosen(folder .. "gone.wav")
  context.clear_engine_calls()
  assert_equal(files.random_into(1), false)
  assert_equal(flash_text(), "no files in empty/")
  assert_equal(#context.calls_named("loadBuffer"), 0, "nothing loaded")
  assert_equal(files.random_into(0), false, "an invalid slot loads nothing")
  assert_equal(files.random_into(9), false)
end)

test("fill_empty gives distinct files to the empty slots until they run out", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local folder = make_folder(context, "fill", { "one.wav", "two.aif", "three.ogg" })
  files.note_chosen(folder .. "x.wav")
  load_buffer(2, "/elsewhere/a.wav"); load_buffer(5, "/elsewhere/b.wav")
  record_buffer(3)
  context.clear_engine_calls()
  assert_equal(files.fill_empty(), 3, "three files, five empty slots")
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 3)
  local seen, slots = {}, {}
  for _, call in ipairs(loads) do
    assert_true(not seen[call.args[2]], "distinct files")
    seen[call.args[2]] = true
    table.insert(slots, call.args[1])
    assert_equal(call.args[3], 0)
  end
  assert_equal(table.concat(slots, ","), "0,3,5", "slots 1, 4 and 6, in order")
  assert_equal(flash_text(), "filled 3 slots")
  local buffers = local_value("buffers")
  assert_true(buffers[7].path == nil and buffers[8].path == nil, "7 and 8 stay empty")
  assert_true(buffers[3].recording, "the recording slot was left alone")
  assert_equal(buffers[2].path, "/elsewhere/a.wav", "loaded slots too")
  -- the folder's files are all in use now: the two empty slots stay empty
  context.clear_engine_calls()
  assert_equal(files.fill_empty(), 0)
  assert_equal(#context.calls_named("loadBuffer"), 0)
  assert_equal(flash_text(), "filled 0 slots")
end)

test("fill_empty never gives a file another slot already holds", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local folder = make_folder(context, "fill-used", { "one.wav", "two.wav", "three.wav" })
  files.note_chosen(folder .. "x.wav")
  load_buffer(4, folder .. "one.wav")
  context.clear_engine_calls()
  assert_equal(files.fill_empty(), 2, "two files left for seven empty slots")
  local seen = {}
  for _, call in ipairs(context.calls_named("loadBuffer")) do
    assert_true(call.args[2] ~= folder .. "one.wav", "the file slot 4 holds is not repeated")
    assert_true(not seen[call.args[2]], "distinct")
    seen[call.args[2]] = true
  end
  assert_equal(local_value("buffers")[4].path, folder .. "one.wav")
  assert_true(local_value("buffers")[3].path == nil, "the rest stay empty")
end)

test("fill_empty leaves a named load the engine has not reported yet", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local folder = make_folder(context, "fill-unsettled", { "a.wav", "b.wav", "c.wav", "d.wav", "e.wav", "f.wav",
    "g.wav", "h.wav", "i.wav" })
  files.note_chosen(folder .. "x.wav")
  load_buffer(2, "/elsewhere/slow.wav")
  context.set_time(util.time() + 1.1); context.polls.fire("bufferState", context.polls.buffer_state_value(2, 1, 0))
  assert_equal(local_value("S").lib.buffers.status(2), "unsettled", "named, no length reported")
  context.clear_engine_calls()
  assert_equal(files.fill_empty(), 7, "the seven other slots")
  local slots = {}
  for _, call in ipairs(context.calls_named("loadBuffer")) do table.insert(slots, call.args[1]) end
  assert_equal(table.concat(slots, ","), "0,2,3,4,5,6,7", "no load into slot 2 (index 1)")
  assert_equal(local_value("buffers")[2].path, "/elsewhere/slow.wav", "the unsettled load keeps its file")
end)

-- #512: one filled slot is one slot
test("the fill's flash counts one slot and two slots", function()
  local context = load_strata(); finish_startup(context)
  local files = local_value("S").lib.files
  local one = make_folder(context, "fill-one", { "a.wav" })
  files.note_chosen(one .. "x.wav")
  assert_equal(files.fill_empty(), 1)
  assert_equal(flash_text(), "filled 1 slot")
  local two = make_folder(context, "fill-two", { "b.wav", "c.wav" })
  files.note_chosen(two .. "x.wav")
  local_value("S").buffer_page.slot = 2   -- an empty slot: the last chosen folder
  assert_equal(files.fill_empty(), 2)
  assert_equal(flash_text(), "filled 2 slots")
end)

-- #404 (6): a recorded take's scratch folder is nobody's library: a slot
-- holding a take takes its files from the last chosen folder
test("folder_for a take n slot is the last chosen folder", function()
  local context = load_strata(); finish_startup(context)
  local files, buffers = local_value("S").lib.files, local_value("buffers")
  files.note_chosen("/b/y.wav")
  params:set("record_duration", 2)
  record_buffer(2); h.wake_buffer_clock(context, 2); context.polls.fire("bufferState", context.polls.buffer_state_value(2, 0, 2))
  assert_equal(buffers[2].name, "take 2"); assert_equal(buffers[2].path, scratch_take_path(2))
  assert_equal(files.folder_for(2), "/b/", "not the scratch folder")
end)

-- #404 (7): a remembered file missing on start leaves its slot free, so the
-- fill gives it a file
test("fill_empty fills a slot whose remembered file is missing", function()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  local folder = make_folder(context, "fill-missing", { "a.wav" })
  S.lib.files.note_chosen(folder .. "x.wav")
  for slot = 1, local_value("NUM_BUFFERS") do
    if slot ~= 3 then load_buffer(slot, "/elsewhere/" .. slot .. ".wav") end
  end
  S.buffers[3].missing_path = "/gone/pad.wav"
  assert_equal(S.lib.buffers.status(3), "missing")
  context.clear_engine_calls()
  S.buffer_page.slot = 3
  assert_equal(S.lib.files.fill_empty(), 1)
  local loads = context.calls_named("loadBuffer")
  assert_equal(#loads, 1); assert_equal(loads[1].args[1], 2, "into slot 3")
  assert_equal(loads[1].args[2], folder .. "a.wav")
end)

test("filling eight free slots writes buffers.data once (#566)", function()
  local context = load_strata(); finish_startup(context)
  local S, files = local_value("S"), local_value("S").lib.files
  context.clock.run_for(1)
  local names = {}
  for n = 1, 8 do names[n] = "f" .. n .. ".wav" end
  local folder = make_folder(context, "fillonce", names)
  files.note_chosen(folder .. "x.wav")
  local count, real_write = 0, S.lib.data_files.write
  S.lib.data_files.write = function(path, value)
    if path:match("buffers%.data$") then count = count + 1 end
    return real_write(path, value)
  end
  assert_equal(files.fill_empty(), 8)
  for slot = 1, 8 do context.polls.fire("bufferState", context.polls.buffer_state_value(slot, 1, 1)) end
  context.clock.run_for(0.5)
  S.lib.data_files.write = real_write
  assert_equal(count, 1, "one write for eight loads")
end)

end
