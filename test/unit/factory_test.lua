-- test/unit/factory_test.lua
-- The factory sets (3.8, design §9, package 4d): lib/factory.lua's index,
-- its rig list, the PSET-form parser, the load (copy, settings, backup,
-- params, side files, flash, marker), the first run and its marker
-- (factory.data), and the load clock's cleanup. Every test that loads a set
-- copies test/fixtures/factory/ into a script folder of its own first
-- (ruling 53), so no failing read can rename a tracked file
-- Run alone: lua test/run.lua factory

return function(h)
local test, assert_true, assert_equal = h.test, h.assert_true, h.assert_equal
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local write_text, file_text, data_root, shell_quote = h.write_text, h.file_text, h.data_root, h.shell_quote
local assert_near, scramble_state = h.assert_near, h.scramble_state
local show_page, next_frame, hint_text = h.show_page, h.next_frame, h.hint_text
local function note_freq(note) return 440 * 2 ^ ((note - 69) / 12) end

local FIXTURE = h.repo_root .. "/test/fixtures/factory/"

local function factory() return local_value("S").lib.factory end

local function lines_with(context, text)
  local found = {}
  for _, line in ipairs(context.printed) do
    if line:find(text, 1, true) then table.insert(found, line) end
  end
  return found
end

-- A copy of the fixture as a script folder of its own: <dir>factory/index.data,
-- <dir>factory/dusk/... (ruling 53)
local copies = 0
local function script_copy()
  copies = copies + 1
  local dir = data_root .. "factory-script-" .. copies .. "/"
  os.execute("mkdir -p " .. shell_quote(dir .. "factory"))
  os.execute("cp -R " .. shell_quote(FIXTURE) .. ". " .. shell_quote(dir .. "factory/"))
  return dir
end

-- The copy's index rewritten: sets ({key, name, version} each; dusk at 1
-- when nil) and first_run (none when nil)
local function write_index(dir, sets, first_run)
  write_text(dir .. "factory/index.data", h.tabutil_text({ version = 1,
    sets = sets or { { key = "dusk", name = "dusk", version = 1 } }, first_run = first_run }))
end

-- A file of the copy's set (dusk unless key), its text replaced
local function write_set_file(dir, name, text, key)
  write_text(dir .. "factory/" .. (key or "dusk") .. "/" .. name, text)
end

-- A started session over a copy of the fixture whose index names no first
-- run (opts.first_run keeps the fixture's), on opts.data_subdir when given;
-- opts.prepare(dir) runs on the copy first, opts.unstarted leaves the
-- start-up clock waiting
local function session(opts)
  opts = opts or {}
  local dir = opts.script_dir or script_copy()
  if not opts.first_run and not opts.script_dir then write_index(dir) end
  if opts.prepare then opts.prepare(dir) end
  local context = load_strata({ script_dir = dir, data_subdir = opts.data_subdir })
  if not opts.unstarted then finish_startup(context) end
  return context, local_value("S"), dir
end

-- Step the clocks until the load's clock has ended
local function run_load(context)
  for _ = 1, 1000 do
    if not factory().loading() then return end
    context.clock.advance()
  end
  error("the load never ended")
end

local function install_dir(context, version)
  return context.audio_dir .. "strata/factory/dusk-" .. (version or 1) .. "/"
end
local function marker(context) return local_value("S").lib.data_files.read(context.data_dir .. "strata/factory.data") end
-- The version factory.data marks dusk loaded at, or nil
local function marked(context)
  local held = marker(context)
  return held and held.loaded and held.loaded.dusk
end
local function live_scenes(context) return context.data_dir .. "strata/scenes.data" end
local function folder_of(context) return context.data_dir:match("([^/]+)/$") end

-- The set's lines: the fixture's audio lines, then extra (a list of lines)
local function set_params(extra)
  local lines = { "-- dusk", '"buf1_file": pad.wav', '"buf2_file": bell.wav', '"buf3_file": drone.wav' }
  for _, line in ipairs(extra or {}) do lines[#lines + 1] = line end
  return table.concat(lines, "\n") .. "\n"
end

-- The samples.data entry's settings of path, or nil
local function stored_settings(context, path)
  context.clock.run_for(0.11)  -- the store's write waits 0.1 s
  local saved = local_value("S").lib.data_files.read(context.data_dir .. "strata/samples.data")
  for _, entry in ipairs(saved and saved.files or {}) do
    if entry.path == path then return entry.settings end
  end
  return nil
end

-- The rig groups' params, walked from each group's param for its n params
local function group_params(group_id)
  local ids = {}
  for index, param in ipairs(params.params) do
    if param.t == params.tGROUP and param.id == group_id then
      for offset = 1, param.n do ids[#ids + 1] = params.params[index + offset].id end
    end
  end
  return ids
end

test("every rig group's params are rig, and no other Strata param is", function()
  local context = load_strata(); finish_startup(context)
  local rig = factory().FACTORY.rig
  local in_group = {}
  for _, group_id in ipairs(rig.groups) do
    local ids = group_params(group_id)
    assert_true(#ids > 0, "the group " .. group_id .. " is in the menu with its params")
    for _, id in ipairs(ids) do
      in_group[id] = true
      assert_true(factory().is_rig(id), group_id .. "'s " .. id .. " is rig")
    end
  end
  -- of Strata's own params outside those groups, only the two named in
  -- between are rig
  local between = { tempo = true, seq_follow_transport = true }
  for _, id in ipairs(local_value("S").lib.params_setup.record_param_ids()) do
    if not in_group[id] and between[id] then
      assert_true(factory().is_rig(id), id .. " is rig")
    elseif not in_group[id] then
      assert_true(not factory().is_rig(id), id .. " is a sound param outside the rig groups, but it matches a "
        .. "FACTORY.rig pattern: rename it or rule on it")
    end
  end
  for _, id in ipairs({ "scene_sequencer_enabled", "mutation_enabled", "v1_solo", "v7_solo", "record_duration",
    "record_level", "v1_freq", "delay_mix" }) do
    assert_true(params.lookup[id] ~= nil, id .. " is a param")
    assert_equal(factory().is_rig(id), false, id .. " is sound")
  end
  for _, id in ipairs({ "midi_device", "v2_out_port", "v7_zone_high", "record_source", "input_follow_gain", "tempo",
    "seq_follow_transport", "tapeloop_level", "crow_out1_source" }) do
    assert_equal(factory().is_rig(id), true, id .. " is rig")
  end
end)

-- A value of param other than its load default, or nil: a control's at a
-- quarter or three quarters of its range, a number's or an option's next
-- (or previous), a binary's other, a text param a probe text (a text with
-- no load default is kept by any load: moved, it shows nothing else
-- touches it); none for a file param, a trigger or a param saved nowhere
local function off_default(param)
  if param.t == params.tTEXT and param.save ~= false then return "factory probe" end
  local default = local_value("S").lib.params_setup.load_default(param)
  if default == nil then return nil end
  if param.t == params.tCONTROL then
    local quarter = param.controlspec:map(0.25)
    if math.abs(quarter - default) > 1e-6 then return quarter end
    return param.controlspec:map(0.75)
  end
  if param.t == params.tNUMBER then return default + 1 <= param.max and default + 1 or default - 1 end
  if param.t == params.tOPTION then return default < param.count and default + 1 or default - 1 end
  if param.t == params.tBINARY then return 1 - default end
  return nil
end

-- 4d fix round 1: one param of every rig group and every rig pattern, each
-- moved off its default, survives a load whose set.params names none of
-- them, and no action of theirs runs during the load (no engine, MIDI,
-- crow, ii or tape send)
test("a load never sets a rig param to its default", function()
  local context, S = session()
  local rig = factory().FACTORY.rig
  local chosen, order = {}, {}
  -- the first param of ids that can be moved off its default, moved
  local function pick(ids, where)
    for _, id in ipairs(ids) do
      if not chosen[id] then
        local param = params:lookup_param(id)
        local value = off_default(param)
        if value ~= nil then
          params:set(id, value)
          if params:get(id) ~= S.lib.params_setup.load_default(param) then
            chosen[id] = { value = params:get(id), where = where, actions = 0 }
            order[#order + 1] = id
            return
          end
        end
      end
    end
    error("no param of " .. where .. " can be moved off its default", 2)
  end
  for _, group_id in ipairs(rig.groups) do pick(group_params(group_id), "the group " .. group_id) end
  local record_ids = S.lib.params_setup.record_param_ids()
  for _, pattern in ipairs(rig.patterns) do
    local ids = {}
    for _, id in ipairs(record_ids) do
      if id:match(pattern) then ids[#ids + 1] = id end
    end
    assert_true(#ids > 0, "the pattern " .. pattern .. " matches a Strata param")
    local covered = false
    for _, id in ipairs(ids) do
      if chosen[id] then covered = true end
    end
    if not covered then pick(ids, "the pattern " .. pattern) end
  end
  for _, id in ipairs(order) do
    local param = params:lookup_param(id)
    local real = param.action
    param.action = function(...) chosen[id].actions = chosen[id].actions + 1; return real(...) end
  end
  assert_true(factory().load("dusk")); run_load(context)
  for _, id in ipairs(order) do
    assert_equal(params:get(id), chosen[id].value, id .. " (" .. chosen[id].where .. ") kept")
    assert_equal(chosen[id].actions, 0, id .. "'s action never runs during the load")
  end
  assert_true(#order >= #rig.groups, #order .. " rig params moved")
end)

test("parse_params reads norns' line form", function()
  load_strata()
  local lines = factory().parse_params(table.concat({
    "-- dusk",
    "\"v1_amp\": 0.5",
    "\"a \\\"quoted\\\" id\": 3",
    "-- \"v2_amp\": 0.9",
    "\"v1_amp\": 0.7",
    "\"x\":inf",
    "\"y\" :  -inf",
    "not a line",
    "\"tuning_name\": 19 equal",
  }, "\n"))
  assert_equal(lines.v1_amp, "0.5", "the first line of an id wins")
  assert_equal(lines['a "quoted" id'], "3", "a quoted id is unquoted as norns does")
  assert_equal(lines.v2_amp, nil, "a -- line is no line")
  assert_equal(lines.x, "inf"); assert_equal(lines.y, "-inf")
  assert_equal(lines.tuning_name, "19 equal", "a text value is the rest of the line")
  local count = 0
  for _ in pairs(lines) do count = count + 1 end
  assert_equal(count, 5, "five ids")
end)

test("a load installs, stores, keeps and applies", function()
  local context, S, dir = session()
  scramble_state(3); S.lib.scenes.save(1)  -- live scenes in no PSET
  local live_bytes = file_text(live_scenes(context))
  assert_equal(factory().load("dusk"), true, "the load starts")
  assert_true(factory().loading(), "in its clock")
  run_load(context)
  local install = install_dir(context)
  for _, name in ipairs({ "pad.wav", "bell.wav", "drone.wav" }) do
    assert_equal(file_text(install .. name), file_text(dir .. "factory/dusk/audio/" .. name), name .. " installed whole")
    assert_true(not util.file_exists(install .. name .. ".part"), "no .part left for " .. name)
  end
  assert_equal(file_text(live_scenes(context) .. ".bak"), live_bytes, "the live scenes kept as scenes.data.bak")
  assert_near(params:get("v1_grain_size"), 0.31, 1e-9, "the set's grain size")
  assert_near(params:get("v1_amp"), 0.42, 1e-9, "the set's amp")
  assert_equal(params:get("buf1_file"), install .. "pad.wav", "buf1_file the installed path")
  assert_equal(params:get("buf3_file"), install .. "drone.wav")
  assert_equal(S.lib.macros.targets(1)[1].id, "v1_amp", "the set's macros")
  assert_equal(S.lib.matrix.routing(1).dest, "v2_amp", "the set's matrix")
  assert_equal(S.scenes[1].name, "dusk", "the set's scenes")
  assert_true(not S.scenes[1].populated, "slot 1 empty, as the set holds it")
  assert_equal(S.scene_file.pset, nil, "no PSET marked")
  assert_equal(S.lib.ui_flash.text("header"), "dusk", "the header flashes the set's name")
  assert_equal(marked(context), 1, "factory.data: dusk loaded at version 1")
  assert_equal(marker(context).pending, nil, "nothing pending")
  assert_equal(stored_settings(context, install .. "pad.wav").tempo, 96, "pad.wav's tempo is stored for its path")
  assert_equal(stored_settings(context, install .. "bell.wav").count, 4, "bell.wav's slices too")
end)

test("a rig line and norns' own are refused", function()
  local context = session({ prepare = function(dir)
    write_set_file(dir, "set.params", set_params({ '"midi_device": 3', '"v2_out_port": 4', '"tempo": 90',
      '"clock_tempo": 90', '"output_level": 0', '"no_such_param": 1' }))
  end })
  local before = {}
  for _, id in ipairs({ "midi_device", "v2_out_port", "tempo", "clock_tempo", "output_level" }) do before[id] = params:get(id) end
  assert_true(factory().load("dusk")); run_load(context)
  for id, value in pairs(before) do
    assert_equal(params:get(id), value, id .. " unchanged")
    assert_equal(#lines_with(context, "the line for " .. id .. " is refused"), 1, "one line for " .. id)
  end
  assert_equal(#lines_with(context, "the line for no_such_param is refused (no param)"), 1, "a line naming no param too")
end)

test("a sound param the file lacks goes to its default, a text param too", function()
  local context, S = session()
  params:set("v3_grain_pitch", 2)
  params:set("delay_feedback", 0.8)
  for _, entry in ipairs(S.lib.tuning.built_ins()) do
    if entry.name == "19 equal" then S.lib.tuning.select(entry) end
  end
  assert_equal(params:get("tuning_name"), "19 equal", "the session's tuning")
  local slot_4 = params:get("buf4_file")
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(params:get("v3_grain_pitch"), params:lookup_param("v3_grain_pitch").controlspec.default, "a control")
  assert_equal(params:get("delay_feedback"), params:lookup_param("delay_feedback").controlspec.default, "a global")
  assert_equal(params:get("tuning_name"), "12 equal", "a text param to its load default")
  assert_equal(S.lib.tuning.count(), 12, "and the tuning with it")
  assert_equal(params:get("buf4_file"), slot_4, "a file param has none: slot 4 keeps its file")
end)

-- The cents between two frequencies
local function cents(from, to) return 1200 * math.log(to / from) / math.log(2) end

test("the lines apply in menu order", function()
  local context, S = session()
  local major
  for index, option in ipairs(params:lookup_param("scale").options) do
    if option:lower() == "major" then major = index end
  end
  assert_true(major ~= nil, "a major scale")
  write_set_file(context.script_dir, "set.params",
    set_params({ '"v1_freq": 285', '"v1_quantize": 1', '"scale": ' .. major }))
  params:set("v1_quantize", 1)
  assert_true(factory().load("dusk")); run_load(context)
  -- 285 Hz is MIDI 61.49: in C major its nearest tone is D (62), where the
  -- chromatic scale, the session's, would give C# (61) and the set's scale
  -- after it C
  assert_near(cents(note_freq(62), params:get("v1_freq")), 0, 0.5,
    "v1_freq, listed before the scale, is snapped by the set's scale")
  assert_equal(params:get("scale"), major)
  -- a set in 19 equal loads a quantized voice's tone to the cent over a
  -- session in twelve equal, and a set in twelve equal over 19 equal
  local nineteen
  for _, entry in ipairs(S.lib.tuning.built_ins()) do
    if entry.name == "19 equal" then nineteen = entry end
  end
  local tone = note_freq(60) * 2 ^ (3 / 19)
  write_set_file(context.script_dir, "set.params", set_params({ '"v1_freq": ' .. string.format("%.6f", tone),
    '"v1_quantize": 1', '"tuning_name": 19 equal',
    '"tuning_tones": ' .. S.lib.tuning.text_of(nineteen.period, nineteen.tones) }))
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(S.lib.tuning.count(), 19, "the set's tuning")
  assert_near(cents(tone, params:get("v1_freq")), 0, 1, "its tone, to the cent")
  write_set_file(context.script_dir, "set.params", set_params({ '"v1_freq": 293.664768', '"v1_quantize": 1' }))
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(S.lib.tuning.count(), 12, "twelve equal, the default")
  assert_near(cents(293.664768, params:get("v1_freq")), 0, 1, "D, to the cent, over a session in 19 equal")
end)

test("a number line is rounded; a trigger line is skipped", function()
  local saves = 0
  local context = session({ prepare = function(dir)
    write_set_file(dir, "set.params", set_params({ '"v1_seq_length": 5.6', '"save_scenes": 1', '"delay_clear": 1' }))
  end })
  local trigger = params:lookup_param("save_scenes")
  local real_action = trigger.action
  trigger.action = function(...) saves = saves + 1; return real_action(...) end
  local clears = #context.calls_named("clearDelay")
  assert_true(factory().load("dusk")); run_load(context)
  trigger.action = real_action
  assert_equal(params:get("v1_seq_length"), 6, "5.6 loads 6")
  assert_equal(#context.calls_named("clearDelay"), clears, "the delay_clear trigger is not fired")
  assert_equal(saves, 0, "nor the save_scenes trigger")
  assert_equal(#lines_with(context, "the line for delay_clear is refused"), 1, "one line for it")
  assert_equal(#lines_with(context, "the line for save_scenes is refused"), 1, "and for save_scenes")
end)

test("a missing sample", function()
  local context = session({ prepare = function(dir)
    local samples = h.tabutil_text({ version = 1, files = { ["pad.wav"] = { tempo = 96 }, ["gone.wav"] = { key = 60 } } })
    write_set_file(dir, "set.samples.data", samples)
    write_set_file(dir, "set.params", '"buf1_file": pad.wav\n"buf2_file": gone.wav\n"v1_grain_size": 0.31\n')
  end })
  local slot_2 = params:get("buf2_file")
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(#lines_with(context, "gone.wav"), 1, "one line names the missing sample")
  assert_equal(params:get("buf2_file"), slot_2, "its slot line is skipped")
  assert_true(not util.file_exists(install_dir(context) .. "gone.wav"), "nothing installed for it")
  assert_equal(params:get("buf1_file"), install_dir(context) .. "pad.wav", "the rest loads")
  assert_near(params:get("v1_grain_size"), 0.31, 1e-9)
  assert_equal(marked(context), 1, "and the load is whole")
end)

test("an unusable side file is skipped and not renamed", function()
  local context, S, dir = session({ prepare = function(dir)
    write_set_file(dir, "set.matrix.data", "garbage")
  end })
  local matrix_path = dir .. "factory/dusk/set.matrix.data"
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(file_text(matrix_path), "garbage", "the file keeps its place and bytes")
  assert_true(not util.file_exists(matrix_path .. ".bak"), "no .bak beside it")
  assert_equal(#lines_with(context, "error loading matrix file " .. matrix_path), 1, "one line")
  assert_equal(S.lib.matrix.routing(1).dest, "", "the matrix loads as missing: empty")
  assert_equal(S.lib.macros.targets(1)[1].id, "v1_amp", "the other files load: the macros")
  assert_equal(S.scenes[1].name, "dusk", "and the scenes")
end)

-- The samples.data entries, by path ({path = settings}), once its write has run
local function stored_entries(context)
  context.clock.run_for(0.11)
  local saved = local_value("S").lib.data_files.read(context.data_dir .. "strata/samples.data")
  local entries = {}
  for _, entry in ipairs(saved and saved.files or {}) do entries[entry.path] = entry.settings end
  return entries
end

-- The ruling: the settings are stored before the backup (the fact file's
-- order), so a refused backup leaves the installed files' records, and
-- nothing else of the player's changes
test("a backup that cannot be made stops the load", function()
  local context, S = session()
  scramble_state(5); S.lib.scenes.save(2)
  local mine = context.audio_dir .. "mine.wav"
  assert_true(S.lib.samples.store_file(mine, { tempo = 120 }), "a record of the player's")
  assert_true(S.lib.macros.set_target(2, 1, "v3_amp", 0.1, 0.9), "a macro target of the player's")
  assert_true(S.lib.matrix.set_routing(3, "lfo2", "v4_amp"), "a matrix routing of the player's")
  local entries_before = stored_entries(context)
  local path = live_scenes(context)
  for number = 1, S.lib.data_files.DATA_FILES.backups do
    write_text(path .. ".bak" .. (number > 1 and ("." .. number) or ""), "taken")
  end
  local live_bytes, scenes_text = file_text(path), S.lib.data_files.encode(S.scenes)
  local values = {}
  for _, id in ipairs(S.lib.params_setup.record_param_ids()) do values[id] = params:get(id) end
  local side_bytes = {}
  for _, name in ipairs({ "macros", "matrix", "gestures", "sequences" }) do
    side_bytes[name] = file_text(context.data_dir .. "strata/" .. name .. ".data")
  end
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(#lines_with(context, "dusk not loaded: the scenes in no PSET could not be kept"), 1, "one line")
  for id, value in pairs(values) do assert_equal(params:get(id), value, id .. " unchanged") end
  assert_equal(S.lib.data_files.encode(S.scenes), scenes_text, "the live scenes stay")
  assert_equal(file_text(path), live_bytes, "and their file")
  assert_equal(S.lib.macros.targets(2)[1].id, "v3_amp", "the macros stay")
  assert_equal(S.lib.matrix.routing(3).dest, "v4_amp", "the matrix stays")
  for name, bytes in pairs(side_bytes) do
    assert_equal(file_text(context.data_dir .. "strata/" .. name .. ".data"), bytes, name .. ".data unchanged")
  end
  local entries = stored_entries(context)
  for entry_path, settings in pairs(entries_before) do
    assert_equal(S.lib.data_files.encode(entries[entry_path]), S.lib.data_files.encode(settings),
      entry_path .. "'s record unchanged")
  end
  local added = {}
  for entry_path in pairs(entries) do
    if not entries_before[entry_path] then added[#added + 1] = entry_path:sub(#install_dir(context) + 1) end
  end
  table.sort(added)
  assert_equal(table.concat(added, " "), "bell.wav drone.wav pad.wav", "the only additions: the installed files' records")
  for entry_path in pairs(entries) do
    if not entries_before[entry_path] then
      assert_equal(entry_path:sub(1, #install_dir(context)), install_dir(context), entry_path .. " is installed")
    end
  end
  assert_equal(marked(context), nil, "nothing marked loaded")
end)

-- 4d fix round 1 (ruling): once the backup has moved the live file aside,
-- scenes.data is on disk again when the load's step ends, holding what is
-- in memory, on every path: the set's scenes taken, its scenes file missing
-- or unusable, a later step failing
local function scenes_kept_case(context, S, why)
  local path = live_scenes(context)
  assert_true(util.file_exists(path), why .. ": scenes.data is on disk after the load")
  assert_true(util.file_exists(path .. ".bak"), why .. ": and the backup beside it")
  local held = S.lib.data_files.read(path)
  assert_equal(S.lib.data_files.encode(held.scenes), S.lib.data_files.encode(S.scenes),
    why .. ": holding the scenes in memory")
end

test("a set without a scenes file leaves the live scenes on disk", function()
  for _, case in ipairs({ { why = "no set.scenes.data", text = nil }, { why = "an unusable one", text = "garbage" } }) do
    local context, S, dir = session({ prepare = function(dir)
      if case.text then write_set_file(dir, "set.scenes.data", case.text)
      else os.remove(dir .. "factory/dusk/set.scenes.data") end
    end })
    scramble_state(4); S.lib.scenes.save(3)
    local before = S.lib.data_files.encode(S.scenes)
    assert_true(factory().load("dusk")); run_load(context)
    assert_equal(S.lib.data_files.encode(S.scenes), before, case.why .. ": the live scenes stay")
    scenes_kept_case(context, S, case.why)
    -- a restart with no cleanup (a crash, the power cut): the start finds a
    -- scenes file, so nothing takes the player for a new one
    local again = load_strata({ script_dir = dir, data_subdir = folder_of(context) })
    assert_equal(local_value("S").scene_file.start_outcome, "loaded", case.why .. ": the next start finds them")
    assert_equal(S.lib.data_files.encode(local_value("S").scenes), before, case.why .. ": the same scenes")
    assert_true(again ~= nil)
  end
end)

test("a load that fails after the backup leaves the live scenes on disk", function()
  local context, S = session()
  scramble_state(4); S.lib.scenes.save(3)
  local before = S.lib.data_files.encode(S.scenes)
  local param = params:lookup_param("v1_amp")
  local real = param.action
  param.action = function() error("a probe's failing action") end
  assert_true(factory().load("dusk")); run_load(context)
  param.action = real
  local errors = context.clock.take_errors()
  assert_equal(#errors, 1, "the load's clock raised once")
  assert_true(errors[1]:find("a probe's failing action", 1, true) ~= nil, errors[1])
  -- #847: the load's clock is gone after the error, so the next load may start
  assert_true(not factory().loading(), "not loading after the error")
  assert_equal(S.factory_clock, nil, "S.factory_clock cleared")
  assert_equal(S.lib.data_files.encode(S.scenes), before, "the live scenes stay")
  scenes_kept_case(context, S, "a failed step")
  assert_equal(marked(context), nil, "nothing marked")
end)

-- #859: a load ends a running scene fade before it sets the set's sound
-- (step 4), so the fade's later steps and its landing never put the
-- scene's values back: a set without scenes, and a load whose step 4 fails
test("a load during a scene fade ends the fade first: the set's sound stays", function()
  for _, case in ipairs({ { why = "no set.scenes.data" }, { why = "a failing step", fails = true } }) do
    local context, S = session({ prepare = function(dir) os.remove(dir .. "factory/dusk/set.scenes.data") end })
    params:set("v1_grain_size", 0.1)
    capture_scene(1)
    params:set("v1_grain_size", 0.2)
    recall_scene(1, 60)
    context.clock.run_for(2)
    assert_true(S.scene_transition_active, case.why .. ": a fade runs")
    local param, real = params:lookup_param("v1_amp"), nil
    if case.fails then
      real = param.action
      param.action = function() error("a probe's failing action") end
    end
    assert_true(factory().load("dusk")); run_load(context)
    if case.fails then
      param.action = real
      assert_equal(#context.clock.take_errors(), 1, case.why .. ": the load raised")
    end
    assert_true(not S.scene_transition_active, case.why .. ": the load ended the fade")
    context.clock.run_for(70)
    if not case.fails then
      assert_near(params:get("v1_grain_size"), 0.31, 1e-9, case.why .. ": the set's grain size stays")
    else
      assert_true(math.abs(params:get("v1_grain_size") - 0.1) > 1e-6, case.why .. ": the fade never landed")
    end
  end
end)

test("audio installs once; a new version installs beside the old", function()
  local context, _, dir = session()
  assert_true(factory().load("dusk")); run_load(context)
  local restore, opened = h.watch_writes("never")
  assert_true(factory().load("dusk")); run_load(context)
  restore()
  for _, name in ipairs(opened) do
    assert_true(not name:find(".wav", 1, true), "no audio written again: " .. name)
  end
  write_index(dir, { { key = "dusk", name = "dusk", version = 2 } })
  assert_true(factory().load("dusk")); run_load(context)
  assert_true(util.file_exists(install_dir(context, 2) .. "pad.wav"), "version 2 installs to dusk-2/")
  assert_true(util.file_exists(install_dir(context, 1) .. "pad.wav"), "dusk-1/ stays")
  assert_equal(params:get("buf1_file"), install_dir(context, 2) .. "pad.wav", "the slot takes the new version's")
  assert_equal(marked(context), 2)
end)

test("the allow side covers 3.8's sound params and skips the holds", function()
  -- the sound ids on this base that 3.8 added (2a's shimmer and 1d's input
  -- channel add theirs when they land; 3a's reverb freeze was cut from 3.8
  -- and came with 3.9), each a value off its default
  local lines = { '"delay_freeze": 1', '"delay_to_reverb": 0.25', '"scale_mask": 2741', '"tuning_name": 19 equal',
    '"v2_type": 3', '"v1_dry": 0.4', '"v1_grain_shape": 0.2', '"v1_grain_skew": 0.5', '"v1_grain_prob": 40',
    '"v1_grain_cloud": 2', '"v1_pan_wander": 10' }
  local context = session({ prepare = function(dir) write_set_file(dir, "set.params", set_params(lines)) end })
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(params:get("delay_freeze"), 0, "the delay's freeze is saved nowhere: its line is skipped")
  assert_equal(#lines_with(context, "the line for delay_freeze is refused"), 1, "with one line")
  assert_near(params:get("delay_to_reverb"), 0.25, 1e-9)
  assert_equal(params:get("scale_mask"), 2741)
  assert_equal(params:get("tuning_name"), "19 equal")
  assert_equal(params:get("v2_type"), 3)
  assert_near(params:get("v1_dry"), 0.4, 1e-9)
  assert_near(params:get("v1_grain_shape"), 0.2, 1e-9)
  assert_near(params:get("v1_grain_skew"), 0.5, 1e-9)
  assert_equal(params:get("v1_grain_prob"), 40)
  assert_equal(params:get("v1_grain_cloud"), 2)
  assert_equal(params:get("v1_pan_wander"), 10)
end)

-- 4d fix round 1: the allow side, derived: every sound param of Strata's
-- records (not rig, saved, no trigger) that has a load default, each moved
-- off it first, goes back to it in a load whose set.params names none of
-- them, so a sound param a later package adds is covered without a line
-- here (a failure names it)
test("every sound param a set has no line for goes to its load default", function()
  local context, S = session({ prepare = function(dir) write_set_file(dir, "set.params", "-- dusk\n") end })
  local setup = S.lib.params_setup
  local moved = {}
  for _, id in ipairs(setup.record_param_ids()) do
    local param = params:lookup_param(id)
    local default = setup.load_default(param)
    local sound = default ~= nil and not factory().is_rig(id) and param.t ~= params.tTEXT
    local value = sound and off_default(param) or nil
    if value ~= nil then
      params:set(id, value)
      if params:get(id) ~= default then moved[#moved + 1] = id end
    end
  end
  assert_true(#moved > 0, "sound params moved off their defaults")
  assert_true(factory().load("dusk")); run_load(context)
  for _, id in ipairs(moved) do
    local param = params:lookup_param(id)
    local default = setup.load_default(param)
    local value = params:get(id)
    local same = value == default or (type(value) == "number" and math.abs(value - default) < 1e-6)
    assert_true(same, id .. " has no line, so it loads its default " .. tostring(default) .. ", not " .. tostring(value))
  end
end)

test("a held delay freeze stays through a load", function()
  local context = session()
  params:set("delay_freeze", 1)
  assert_equal(params:get("delay_freeze"), 1, "held")
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(params:get("delay_freeze"), 1, "a set neither sets nor releases the freeze (ruling 61)")
end)

-- Review Focus 5: a load cut short marks nothing, and the next one finishes it
test("an interrupted load is finished by the next, and marks nothing", function()
  local context, S, dir = session()
  scramble_state(7); S.lib.scenes.save(1)
  local live_bytes = file_text(live_scenes(context))
  local size = params:get("v1_grain_size")
  assert_true(factory().load("dusk"))
  context.clock.advance()  -- the first file (bell.wav) copied, the clock asleep after it
  local install = install_dir(context)
  assert_true(util.file_exists(install .. "bell.wav"), "the first sample installed")
  assert_true(not util.file_exists(install .. "drone.wav"), "the second not yet")
  write_text(install .. "drone.wav.part", "a part a cut copy left")
  assert_equal(params:get("v1_grain_size"), size, "no param set")
  cleanup()
  assert_equal(file_text(live_scenes(context)), live_bytes, "the live scenes file untouched")
  assert_equal(marked(context), nil, "the set is not in loaded")
  context = load_strata({ script_dir = dir, data_subdir = folder_of(context) }); finish_startup(context)
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(file_text(install .. "drone.wav"), file_text(dir .. "factory/dusk/audio/drone.wav"),
    "the .part is never taken for a sample")
  assert_true(not util.file_exists(install .. "drone.wav.part"), "and it is gone")
  assert_equal(file_text(install .. "pad.wav"), file_text(dir .. "factory/dusk/audio/pad.wav"), "pad.wav copied")
  assert_near(params:get("v1_grain_size"), 0.31, 1e-9, "then the params")
  assert_equal(marked(context), 1, "and loaded written")
end)

test("a refused write stops the load with one line and marks nothing", function()
  local context, S = session()
  scramble_state(7); S.lib.scenes.save(1)
  local live_bytes = file_text(live_scenes(context))
  local size = params:get("v1_grain_size")
  local restore = h.watch_writes("pad.wav.part", { at = "write", after = 0 })
  assert_true(factory().load("dusk")); run_load(context)
  restore()
  local install = install_dir(context)
  assert_equal(#lines_with(context, "dusk not loaded: pad.wav could not be installed"), 1, "one line")
  assert_true(not util.file_exists(install .. "pad.wav.part"), "the .part removed")
  assert_true(not util.file_exists(install .. "pad.wav"), "nothing in its place")
  assert_equal(params:get("v1_grain_size"), size, "no param set")
  assert_equal(file_text(live_scenes(context)), live_bytes, "the live scenes file untouched")
  assert_equal(marked(context), nil, "nothing marked loaded")
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(marked(context), 1, "the next load finishes it")
end)

-- Keep the real size probe, data file handles, output and rename. Only the
-- source read fails, immediately or after bytes have reached the part.
for _, prefix in ipairs({ 0, 16, 13 }) do
  test("a factory source read error after " .. prefix .. " bytes preserves the destination and can be retried", function()
    local context, _, dir = session()
    local source = dir .. "factory/dusk/audio/bell.wav"
    local destination = install_dir(context) .. "bell.wav"
    local original = file_text(source)
    factory().FACTORY.copy_chunk_bytes = 16
    util.make_dir(install_dir(context))
    if prefix > 0 then write_text(destination, "previous sample") end
    local open, measured, consumed = io.open, nil, 0
    io.open = function(path, mode)
      local file, why = open(path, mode)
      if not file or path ~= source or mode ~= "rb" then return file, why end
      return {
        seek = function(_, where)
          measured = file:seek(where)
          return measured
        end,
        read = function(_, bytes)
          if consumed == prefix then return nil, "injected source I/O error", 5 end
          local chunk = file:read(math.min(bytes, prefix - consumed))
          consumed = consumed + #chunk
          return chunk
        end,
        close = function() return file:close() end,
      }
    end
    local ok, why = pcall(function() assert_true(factory().load("dusk")); run_load(context) end)
    io.open = open
    assert_true(ok, tostring(why))
    assert_equal(measured, #original, "the installer measured the real source before copying")
    assert_equal(consumed, prefix)
    assert_equal(file_text(destination), prefix > 0 and "previous sample" or nil)
    assert_true(not util.file_exists(destination .. ".part"))
    assert_equal(marked(context), nil)
    assert_equal(#lines_with(context, "bell.wav could not be installed (injected source I/O error)"), 1)
    assert_true(factory().load("dusk")); run_load(context)
    assert_equal(file_text(destination), original)
    assert_equal(marked(context), 1)
  end)
end

test("a load refuses a key the index lists not, and one that is no key", function()
  session()
  assert_equal(select(2, factory().load("dawn")), "no set")
  assert_equal(select(2, factory().load("../dusk")), "no set")
  assert_true(not factory().loading(), "no clock")
end)

-- 4d fix round 1: a set written on another machine (CRLF lines), and the
-- values norns' read takes (a negative, an exponent)
test("a CRLF set.params loads as its Unix copy, a negative and an exponent too", function()
  local lines = { "-- dusk", '"buf1_file": pad.wav', '"v1_grain_size": 3.1e-1', '"v1_pan": -0.5',
    '"v1_seq_length": 1.2E1', '"tuning_name": 19 equal' }
  local loaded = {}
  for _, ending in ipairs({ "\n", "\r\n" }) do
    local context = session({ prepare = function(dir)
      write_set_file(dir, "set.params", table.concat(lines, ending) .. ending)
    end })
    assert_true(factory().load("dusk")); run_load(context)
    local name = ending == "\n" and "unix" or "crlf"
    loaded[name] = { buf1_file = params:get("buf1_file"):sub(#install_dir(context) + 1),
      v1_grain_size = params:get("v1_grain_size"), v1_pan = params:get("v1_pan"),
      v1_seq_length = params:get("v1_seq_length"), tuning_name = params:get("tuning_name") }
  end
  assert_equal(loaded.unix.buf1_file, "pad.wav", "the slot line")
  assert_near(loaded.unix.v1_grain_size, 0.31, 1e-9, "an exponent")
  assert_near(loaded.unix.v1_pan, -0.5, 1e-9, "a negative")
  assert_equal(loaded.unix.v1_seq_length, 12, "an exponent of a number param")
  assert_equal(loaded.unix.tuning_name, "19 equal", "a text")
  for key, value in pairs(loaded.unix) do
    assert_equal(loaded.crlf[key], value, key .. ": the CRLF copy loads as the Unix one")
  end
  load_strata()
  assert_equal(factory().parse_params('"a": 1\r\n"b": two words\r\n').b, "two words", "the parser drops a line's \\r")
end)

-- 4d fix round 1: a file installed short (a power cut before the card
-- wrote it whole: the copy writes no fsync) is copied again
test("an installed file of another size than the set's is copied again", function()
  local context, _, dir = session()
  local install = install_dir(context)
  util.make_dir(install)
  write_text(install .. "pad.wav", "RIFF")
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(file_text(install .. "pad.wav"), file_text(dir .. "factory/dusk/audio/pad.wav"), "copied whole")
  assert_true(not util.file_exists(install .. "pad.wav.part"), "through its .part, gone")
end)

-- 4d fix round 1: the departures the report named
test("a set whose files cannot be read is refused before any clock", function()
  for _, case in ipairs({ { file = "set.samples.data", text = "garbage" }, { file = "set.params" } }) do
    local context, _, dir = session({ prepare = function(dir)
      if case.text then write_set_file(dir, case.file, case.text) else os.remove(dir .. "factory/dusk/" .. case.file) end
    end })
    local loaded, why = factory().load("dusk")
    assert_equal(loaded, false, case.file .. ": refused")
    assert_equal(why, "unreadable", case.file)
    assert_true(not factory().loading(), case.file .. ": no clock")
    assert_equal(#lines_with(context, "dusk not loaded: " .. dir .. "factory/dusk/" .. case.file), 1,
      case.file .. ": one line naming it")
  end
end)

test("a sample record the checks refuse is left out with one line; the file installs", function()
  local context = session({ prepare = function(dir)
    write_set_file(dir, "set.samples.data", h.tabutil_text({ version = 1, files = {
      ["pad.wav"] = { tempo = 1000 }, ["bell.wav"] = { key = 64 }, ["drone.wav"] = {} } }))
  end })
  assert_true(factory().load("dusk")); run_load(context)
  local install = install_dir(context)
  assert_equal(#lines_with(context, "pad.wav's settings are refused"), 1, "one line")
  assert_true(util.file_exists(install .. "pad.wav"), "the file is installed")
  assert_equal(stored_settings(context, install .. "pad.wav"), nil, "with no record")
  assert_equal(stored_settings(context, install .. "bell.wav").key, 64, "the others keep theirs")
  assert_equal(marked(context), 1, "and the load is whole")
end)

test("a pending set the index no longer lists loads nothing and is left", function()
  local first = load_strata()
  cleanup()
  util.make_dir(first.data_dir .. "strata/")
  write_text(first.data_dir .. "strata/factory.data", h.tabutil_text({ version = 1, pending = "gone", loaded = {} }))
  local context = session({ first_run = true, unstarted = true, data_subdir = folder_of(first) })
  assert_true(not factory().loading(), "no load: the marker was found")
  assert_equal(marker(context).pending, "gone", "the marker as it was")
end)

test("a first run whose marker cannot be written starts no load", function()
  local restore = h.watch_writes("factory.data.part", { at = "write", after = 0 })
  local context = session({ first_run = true, unstarted = true })
  restore()
  assert_true(not factory().loading(), "no load: pending could not be written first")
  assert_equal(#lines_with(context, "error: factory file not saved"), 1, "one line")
  assert_equal(marker(context), nil, "no factory.data")
end)

-- The first run (ruling 51)
test("a start with no index writes nothing", function()
  local context = load_strata()
  assert_equal(local_value("S").factory_clock, nil, "no load")
  assert_true(not util.file_exists(context.data_dir .. "strata/factory.data"), "no factory.data")
  assert_true(not util.file_exists(context.audio_dir .. "strata/factory"), "no install folder")
  finish_startup(context)
  assert_true(not util.file_exists(context.data_dir .. "strata/factory.data"), "nor after the start")
end)

test("a first run writes pending before the copy", function()
  local context = session({ first_run = true, unstarted = true })
  local held = marker(context)
  assert_equal(held.pending, "dusk", "factory.data names the first-run set as pending")
  assert_equal(next(held.loaded), nil, "and nothing loaded")
  assert_true(factory().loading(), "its load runs, not awaited")
  assert_true(not util.file_exists(install_dir(context) .. "bell.wav"), "before the first file")
end)

test("a whole load writes loaded and clears pending", function()
  local context, _, dir = session({ first_run = true, unstarted = true })
  run_load(context)
  assert_equal(marked(context), 1, "dusk loaded")
  assert_equal(marker(context).pending, nil, "pending cleared")
  assert_near(params:get("v1_grain_size"), 0.31, 1e-9, "the set's sound")
  cleanup()
  context = load_strata({ script_dir = dir, data_subdir = folder_of(context) })
  assert_true(not factory().loading(), "a second start runs nothing")
end)

test("a start that finds pending runs that load again, though a scenes file now exists", function()
  local context, _, dir = session({ first_run = true, unstarted = true })
  context.clock.advance()  -- the first file (bell.wav) installed, the clock asleep after it
  local install = install_dir(context)
  assert_true(util.file_exists(install .. "bell.wav") and not util.file_exists(install .. "drone.wav"), "one file in")
  cleanup()
  assert_true(util.file_exists(live_scenes(context)), "the cleanup wrote a scenes file")
  assert_equal(marker(context).pending, "dusk", "pending names the set")
  local restore, opened = h.watch_writes("never")
  context = load_strata({ script_dir = dir, data_subdir = folder_of(context) })
  assert_equal(local_value("S").scene_file.start_outcome, "loaded", "this start found a scenes file")
  assert_true(factory().loading(), "the load runs again")
  run_load(context)
  restore()
  local wrote = {}
  for _, name in ipairs(opened) do wrote[name:match("[^/]*$")] = true end
  assert_true(not wrote["bell.wav.part"], "the first file left alone")
  assert_true(wrote["drone.wav.part"] and wrote["pad.wav.part"], "the other two copied")
  assert_equal(marker(context).pending, nil, "pending cleared at its end")
  assert_equal(marked(context), 1)
end)

test("a player whose scenes file was found gets loaded = {} and no load", function()
  local first = load_strata(); finish_startup(first)
  capture_scene(1)
  cleanup()
  local context = session({ first_run = true, unstarted = true, data_subdir = folder_of(first) })
  assert_true(not factory().loading(), "no load")
  local held = marker(context)
  assert_equal(held.version, 1)
  assert_equal(held.pending, nil)
  assert_equal(next(held.loaded), nil, "{version = 1, loaded = {}}")
end)

test("an unreadable scenes file is no first run", function()
  local first = load_strata()
  cleanup()
  util.make_dir(first.data_dir .. "strata/")
  write_text(first.data_dir .. "strata/scenes.data", "garbage")
  local context, S = session({ first_run = true, unstarted = true, data_subdir = folder_of(first) })
  assert_equal(S.scene_file.start_outcome, "unreadable")
  assert_true(not factory().loading(), "no load")
  assert_equal(next(marker(context).loaded), nil, "loaded = {}")
end)

test("an unusable marker is set aside and counts as found", function()
  local first = load_strata()
  cleanup()
  util.make_dir(first.data_dir .. "strata/")
  write_text(first.data_dir .. "strata/factory.data", "garbage")
  local context = session({ first_run = true, unstarted = true, data_subdir = folder_of(first) })
  assert_true(not factory().loading(), "no load")
  assert_equal(file_text(context.data_dir .. "strata/factory.data.bak"), "garbage", "kept as factory.data.bak")
  assert_equal(#lines_with(context, "error loading factory file"), 1, "one line")
  assert_equal(next(marker(context).loaded), nil, "written afresh: loaded = {}")
end)

test("cleanup cancels the load clock", function()
  local context = session({ first_run = true, unstarted = true })
  assert_true(factory().loading())
  cleanup()
  assert_equal(local_value("S").factory_clock, nil, "no clock after cleanup")
  context.clock.run_for(1)
  assert_true(not util.file_exists(install_dir(context) .. "bell.wav"), "nothing copied after it")
end)

-- #847: a first run (or a pending one) whose load is refused clears
-- pending, so its line prints at that start alone
test("a first run whose load is refused prints its line once and is not tried again", function()
  local context, _, dir = session({ first_run = true, unstarted = true, prepare = function(dir)
    write_set_file(dir, "set.samples.data", "garbage")
  end })
  assert_true(not factory().loading(), "refused: no load")
  assert_equal(#lines_with(context, "dusk not loaded"), 1, "one line")
  assert_equal(marker(context).pending, nil, "pending cleared")
  assert_equal(next(marker(context).loaded), nil, "nothing loaded")
  cleanup()
  context = load_strata({ script_dir = dir, data_subdir = folder_of(context) })
  assert_true(not factory().loading(), "the next start runs nothing")
  assert_equal(#lines_with(context, "dusk not loaded"), 0, "and prints nothing")
end)

-- #847: SETUP's list is closed by the cleanup step, its owner popped
test("cleanup closes SETUP's list", function()
  local _, S = session()
  show_page("SETUP")
  factory().open_list()
  local owner = S.lib.ui_modal.top()
  assert_true(factory().is_open() and owner ~= nil, "the list is the modal owner")
  cleanup()
  assert_true(not factory().is_open(), "closed")
  assert_true(S.lib.ui_modal.top() ~= owner, "its owner popped")
end)

-- SETUP's list
test("a second load while one runs is refused", function()
  local context, S = session()
  show_page("SETUP")
  factory().open_list()
  key(3, 1); key(3, 0)
  assert_true(factory().loading(), "K3 loads")
  local clock_id = S.factory_clock
  assert_equal(select(2, factory().load("dusk")), "loading", "load refuses a second")
  key(3, 1); key(3, 0)
  assert_equal(S.factory_clock, clock_id, "one clock")
  assert_equal(S.lib.ui_flash.text("hints"), "loading", "the list flashes loading")
  run_load(context)
  factory().close_list()
end)

-- #897: the armed prompt is the list's own hint row, as SCENES' overwrite
-- prompt is since #255, so a flash that comes meanwhile never hides that
-- the next K3 loads; it lapses by itself after the 2 s (the list animates)
test("the factory list draws its own prompt while armed, whatever flashes", function()
  local context, S = session()
  local path = context.data_dir .. "strata/scenes.data"
  S.lib.scenes.save(1)
  os.execute("mkdir -p '" .. path .. ".part/inside'")             -- the next write fails
  S.lib.scenes.save(2)
  assert_true(S.scene_file.unsaved, "a scene of this session is not on disk")
  show_page("SETUP")
  factory().open_list()
  next_frame(context)
  local idle_hints = hint_text(context)
  assert_equal(idle_hints, "K2:back E2:set K3:load", "the list's own keys")
  key(3, 1); key(3, 0)
  local armed_at = util.time()
  assert_true(not factory().loading(), "the first K3 only asks")
  next_frame(context)
  assert_equal(hint_text(context), "K3 again: drop unsaved", "the prompt")
  S.lib.ui_flash.start("hints", "B1 load failed", 5)              -- a flash for every page
  next_frame(context)
  assert_equal(hint_text(context), "K3 again: drop unsaved", "the prompt stays over the flash")
  key(1, 1)                                                       -- ALT: K3 does nothing (#897 review)
  next_frame(context)
  assert_true(not (hint_text(context) or ""):find("K3", 1, true), "under ALT the hint names no K3")
  key(3, 1); key(3, 0)
  assert_true(not factory().loading(), "ALT+K3 loads nothing")
  key(1, 0)
  next_frame(context)
  assert_equal(hint_text(context), "K3 again: drop unsaved", "ALT up: the prompt again")
  context.clock.run_for(armed_at + 1.8 - util.time())
  next_frame(context)
  assert_equal(hint_text(context), "K3 again: drop unsaved", "for the 2 s the second K3 has")
  context.clock.run_for(armed_at + 2.1 - util.time())
  next_frame(context)
  assert_equal(hint_text(context), "B1 load failed", "lapsed by itself: the flash shows")
  context.clock.run_for(3)
  next_frame(context)
  assert_equal(hint_text(context), idle_hints, "then the list's keys")
  key(3, 1); key(3, 0)
  S.lib.ui_flash.start("hints", "B1 load failed", 5)
  key(3, 1); key(3, 0)
  assert_true(factory().loading(), "the second K3 under the prompt loads, a flash or not")
  run_load(context)
  factory().close_list()
end)

-- #861: a set replaces every voice's sound, so VOICE's preset row names
-- no preset after it, as after a PSET read
test("a load clears the voices' preset names", function()
  local context, S = session()
  assert_true(S.lib.voice_presets.save(2, 1, "glass"), "a preset")
  assert_true(S.lib.voice_presets.load(1, 1), "loaded into voice 1")
  assert_true(S.lib.voice_presets.copy(4, 3), "voice 4 copied into voice 3")
  assert_true(factory().load("dusk")); run_load(context)
  assert_equal(S.lib.voice_presets.loaded_name(1), nil, "voice 1's name cleared")
  assert_equal(S.lib.voice_presets.loaded_name(3), nil, "voice 3's too")
  assert_equal(S.lib.voice_presets.preset(1).name, "glass", "the library is left alone")
end)

end
