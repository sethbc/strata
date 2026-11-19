-- test/unit/tuning_test.lua
-- The one tuning (lib/tuning.lua, 3.8 design §6): the default plays 3.7's
-- pitches exactly; keys, snaps and steps in other tunings; the mask in a
-- tuning of twelve tones to an octave; what reaches the engine; the
-- tuning_tones text; the built-ins; the Scala reader and the tunings folder.
-- Run alone: lua test/run.lua tuning

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function tuning() return local_value("lib").tuning end

local function option_index(param_id, name)
  for index, option in ipairs(params:lookup_param(param_id).options) do
    if option == name then return index end
  end
  error("no option " .. name .. " in " .. param_id)
end

-- A built-in by name
local function built_in(name)
  for _, entry in ipairs(tuning().built_ins()) do
    if entry.name == name then return entry end
  end
  error("no built-in tuning " .. name)
end

-- The cents of each built-in (design §6.4; the plan's facts, from norns'
-- intonation ratios, the fifths for Pythagorean and quarter-comma meantone)
local CENTS = {
  ["ji normal"] = {0, 111.7313, 203.9100, 315.6413, 386.3137, 498.0450, 590.2237, 701.9550, 813.6863, 884.3587,
    996.0900, 1088.2687},
  ["ptolemy"] = {0, 111.7313, 203.9100, 315.6413, 386.3137, 498.0450, 590.2237, 701.9550, 813.6863, 884.3587,
    1017.5963, 1088.2687},
  ["overtone"] = {0, 104.9554, 203.9100, 297.5130, 386.3137, 470.7809, 551.3179, 701.9550, 840.5277, 905.8650,
    968.8259, 1088.2687},
  ["undertone"] = {0, 111.7313, 231.1741, 294.1350, 359.4723, 498.0450, 648.6821, 729.2191, 813.6863, 902.4870,
    996.0900, 1095.0446},
  ["lamonte"] = {0, 176.6459, 203.9100, 239.6068, 443.5168, 470.7809, 674.6909, 701.9550, 737.6518, 941.5618,
    968.8259, 1172.7359},
  ["pythagorean"] = {0, 113.6850, 203.9100, 294.1350, 407.8200, 498.0450, 611.7300, 701.9550, 815.6400, 905.8650,
    996.0900, 1109.7750},
  ["meantone 1/4"] = {0, 76.0490, 193.1569, 310.2647, 386.3137, 503.4216, 579.4706, 696.5784, 772.6274, 889.7353,
    1006.8431, 1082.8921},
  ["partch 43"] = {0, 21.5063, 53.2729, 84.4672, 111.7313, 150.6371, 165.0042, 182.4037, 203.9100, 231.1741,
    266.8709, 294.1350, 315.6413, 347.4079, 386.3137, 417.5080, 435.0841, 470.7809, 498.0450, 519.5513, 551.3179,
    582.5122, 617.4878, 648.6821, 680.4487, 701.9550, 729.2191, 764.9159, 782.4920, 813.6863, 852.5921, 884.3587,
    905.8650, 933.1291, 968.8259, 996.0900, 1017.5963, 1034.9958, 1049.3629, 1088.2687, 1115.5328, 1146.7271,
    1178.4937},
}
local BUILT_IN_ORDER = {"12 equal", "ji normal", "ptolemy", "overtone", "undertone", "lamonte", "pythagorean",
  "meantone 1/4", "19 equal", "24 equal", "31 equal", "partch 43"}

-- Apply a built-in by name (as the editor does)
local function use(name) tuning().select(built_in(name)) end

local function sent_tuning(context)
  local calls = {}
  for _, call in ipairs(context.engine_calls) do
    if call.name == "setTuning" or call.name == "setTuningTone" then calls[#calls + 1] = call end
  end
  return calls
end

test("the default tuning is twelve equal steps and plays 3.7's pitches", function()
  load_strata()
  local t = tuning()
  assert_equal(t.count(), 12, "twelve tones")
  assert_equal(t.period(), 1200, "an octave")
  assert_equal(t.name(), "12 equal", "its name")
  assert_equal(params:get("tuning_tones"), t.TUNING.default_text, "tuning_tones holds the default text")
  for root = 1, 12 do
    params:set("root", root)
    for key = 0, 127 do
      assert_true(t.pitch_of_key(key) == key, "key " .. key .. " is its own pitch, root " .. root)
    end
  end
  params:set("root", 1)
  assert_equal(t.snap(60.4), 60, "60.4 snaps to 60")
  assert_equal(t.snap(60.5), 60, "a tie goes down")
  assert_equal(t.snap(60.6), 61, "60.6 snaps to 61")
  params:set("scale", option_index("scale", "Major"))
  assert_equal(t.snap(63.2), 64, "C major: 63.2 to E")
  assert_equal(t.snap(63.0), 62, "C major: 63 is a tie, down to D")
  assert_equal(local_value("lib").variation.snap_note(63.2), 64, "snap_note is the tuning's snap")
end)

test("step walks the allowed tones as the degrees did", function()
  load_strata()
  local t = tuning()
  params:set("scale", option_index("scale", "Major"))
  assert_equal(t.step(60, 2), 64, "two tones up from C is E")
  assert_equal(t.step(60, -1), 59, "one down is B")
  assert_equal(t.step(60.3, 1), 62, "from 60.3 the next is D")
  assert_equal(t.step(69, 1), 71, "from A the next is B")
  assert_equal(t.step(60, 0), 60, "zero steps is the pitch")
  assert_equal(t.step(60, 7), 72, "seven tones up is the octave")
  assert_equal(t.step(60, -8), 47, "eight down passes an octave")
  params:set("scale", 1)
  assert_equal(t.step(60.995, 1), 62, "within the tone tolerance of 61 counts as on it")
  assert_equal(t.step(61.005, -1), 60, "and the same below")
end)

test("equal_step is the tuning's step when every tone is allowed", function()
  load_strata()
  local t = tuning()
  assert_equal(t.equal_step(), 1, "twelve equal, the scale off: a semitone")
  params:set("scale", option_index("scale", "Major"))
  assert_equal(t.equal_step(), nil, "C major: no equal step")
  params:set("scale", option_index("scale", "Whole Tone"))
  assert_equal(t.equal_step(), nil, "Whole Tone: evenly spaced, but not every tone of the tuning")
  params:set("scale", option_index("scale", "Major"))
  use("19 equal")
  assert_near(t.equal_step(), 12 / 19, 1e-6, "19 equal: 12/19 semitone, the scale ignored")
  assert_near(t.mean_step(), 12 / 19, 1e-6, "and the mean step")
  use("ji normal")
  params:set("scale", 1)
  assert_equal(t.equal_step(), nil, "ji normal: unequal steps")
  assert_near(t.mean_step(), 1, 1e-9, "twelve tones to an octave: a mean step of a semitone")
end)

test("a key maps in order from the root", function()
  load_strata()
  local t = tuning()
  use("19 equal")
  assert_near(t.pitch_of_key(60), 60, 1e-9, "degree 0 on key 60 (root C)")
  assert_near(t.pitch_of_key(61), 60 + 12 / 19, 1e-4, "key 61 is one 19th of an octave up")
  assert_near(t.pitch_of_key(79), 72, 1e-9, "key 79 is the octave")
  assert_near(t.pitch_of_key(59), 60 - 12 / 19, 1e-4, "key 59 is one step down")
  params:set("root", option_index("root", "D"))
  assert_near(t.pitch_of_key(62), 62, 1e-9, "root D: degree 0 on key 62")
  params:set("root", 1)
  use("partch 43")
  assert_near(t.pitch_of_key(0), 43.29, 0.005, "Partch 43: key 0")
  assert_near(t.pitch_of_key(127), 78.80, 0.005, "Partch 43: key 127")
end)

test("the mask applies only to twelve tones of an octave", function()
  load_strata()
  local t = tuning()
  use("ji normal")
  params:set("scale", option_index("scale", "Major"))
  assert_true(t.scale_active(), "twelve tones to an octave: the scale applies")
  local allowed = t.allowed()
  local major = {1, 3, 5, 6, 8, 10, 12}
  assert_equal(#allowed, #major, "seven tones")
  for index, degree in ipairs(major) do
    assert_near(allowed[index], CENTS["ji normal"][degree], 1e-3, "C major's degree " .. index .. " in ji normal")
  end
  use("19 equal")
  assert_true(not t.scale_active(), "19 tones: no scale")
  assert_equal(#t.allowed(), 19, "every tone of 19 equal")
  local text = {"1300"}
  for step = 0, 11 do text[#text + 1] = tostring(step * 100) end
  params:set("tuning_tones", table.concat(text, " "))
  assert_equal(t.count(), 12, "twelve tones of 1300 cents")
  assert_true(not t.scale_active(), "no octave: no scale")
  assert_equal(#t.allowed(), 12, "every tone")
end)

test("the tuning reaches the engine as one setTuning and its tones, in order", function()
  local context = load_strata(); finish_startup(context)
  context.clear_engine_calls()
  use("ji normal")
  local calls = sent_tuning(context)
  assert_equal(#calls, 13, "one setTuning and twelve tones")
  assert_equal(calls[1].name, "setTuning", "setTuning first")
  assert_equal(calls[1].args[1], 12, "twelve tones")
  assert_equal(calls[1].args[2], 1200, "an octave")
  for index = 1, 12 do
    assert_equal(calls[index + 1].name, "setTuningTone", "tone " .. index)
    assert_equal(calls[index + 1].args[1], index - 1, "tone " .. index .. "'s index")
    assert_near(calls[index + 1].args[2], CENTS["ji normal"][index], 4e-4, "tone " .. index .. "'s cents")
  end
  assert_equal(params:get("tuning_name"), "ji normal", "the name shows the choice")
  context.clear_engine_calls()
  use("partch 43")
  assert_equal(#sent_tuning(context), 44, "Partch: one setTuning and 43 tones")
end)

test("tuning_tones' text round-trips", function()
  local context = load_strata(); finish_startup(context)
  local t = tuning()
  for _, entry in ipairs(t.built_ins()) do
    local text = t.text_of(entry.period, entry.tones)
    local period, tones = t.parse_text(text)
    assert_true(period ~= nil, entry.name .. "'s text parses")
    assert_equal(t.text_of(period, tones), text, entry.name .. "'s text round-trips")
  end
  use("ji normal")
  local kept = params:get("tuning_tones")
  local many = {"1200"}
  for step = 0, 128 do many[#many + 1] = tostring(step) end
  local bad = {"1200", table.concat(many, " "), "1200 0 100 50", "1200 5 100", "99 0 50", "abc", "1200 0 1200", "1200 0 0x10", "1200 0 1e3", "4801 0 100"}
  for _, text in ipairs(bad) do
    local from = #context.printed + 1
    context.clear_engine_calls()
    params:set("tuning_tones", text)
    local lines = #context.printed - from + 1
    assert_equal(lines, 1, "one line for " .. text:sub(1, 30))
    assert_true(context.printed[from]:match("^tuning: ") ~= nil, "the line starts tuning: (" .. tostring(context.printed[from]) .. ")")
    assert_equal(params:get("tuning_tones"), kept, "the param is set back: " .. text:sub(1, 30))
    assert_equal(#sent_tuning(context), 0, "nothing sent for " .. text:sub(1, 30))
    assert_equal(t.count(), 12, "the tuning stays ji normal")
  end
end)

test("the built-ins, in order, ascend from 0 below their period", function()
  load_strata()
  local t = tuning()
  local entries = t.built_ins()
  assert_equal(#entries, #BUILT_IN_ORDER, "the built-ins")
  for index, entry in ipairs(entries) do
    assert_equal(entry.name, BUILT_IN_ORDER[index], "built-in " .. index)
    assert_true(#entry.name <= t.TUNING.name_max, entry.name .. " fits name_max")
    assert_equal(entry.period, 1200, entry.name .. ": an octave")
    assert_equal(entry.tones[1], 0, entry.name .. " starts at 0")
    for tone = 2, #entry.tones do
      assert_true(entry.tones[tone] > entry.tones[tone - 1], entry.name .. " ascends at " .. tone)
    end
    assert_true(entry.tones[#entry.tones] < entry.period, entry.name .. " ends below its period")
    local cents = CENTS[entry.name]
    local equal = entry.name:match("^(%d+) equal$")
    if equal then
      assert_equal(#entry.tones, tonumber(equal), entry.name .. "'s count")
      for tone = 1, #entry.tones do
        assert_near(entry.tones[tone], (tone - 1) * 1200 / tonumber(equal), 1e-9, entry.name .. " tone " .. tone)
      end
    else
      assert_equal(#entry.tones, #cents, entry.name .. "'s count")
      for tone = 1, #cents do
        assert_near(entry.tones[tone], cents[tone], 1e-4, entry.name .. " tone " .. tone)
      end
    end
  end
end)

test("the Scala reader takes comments, ratios, cents and whole numbers", function()
  load_strata()
  local t = tuning()
  local period, tones = t.parse_scl(table.concat({"! a comment", "", "3", "! another", "9/8", "701.955 fifth", "2"}, "\n"))
  assert_true(period ~= nil, "an empty description, comments between the lines: " .. tostring(tones))
  assert_near(period, 1200, 1e-9, "2 is 2/1: the octave")
  assert_equal(#tones, 3, "three tones a period")
  assert_equal(tones[1], 0, "1/1 is implied")
  assert_near(tones[2], 203.910, 1e-3, "9/8")
  assert_near(tones[3], 701.955, 1e-9, "701.955 cents, its trailing text ignored")
  local bp = {"Bohlen-Pierce", "13"}
  for _, ratio in ipairs({"27/25", "25/21", "9/7", "7/5", "75/49", "5/3", "9/5", "49/25", "15/7", "7/3", "63/25",
    "25/9", "3/1"}) do bp[#bp + 1] = ratio end
  period, tones = t.parse_scl(table.concat(bp, "\n"))
  assert_near(period, 1901.955, 1e-3, "Bohlen-Pierce's period is 3/1")
  assert_equal(#tones, 13, "thirteen tones")
  local refusals = {
    {{"x", "0"}, "count"},
    {{"x", "129"}, "count"},
    {{"x", "2", "3/2"}, "only 1 pitches"},
    {{"x", "2", "-3/2", "2/1"}, "not a pitch"},
    {{"x", "2", "0/1", "2/1"}, "not a pitch"},
    {{"x", "2", "1e3", "2/1"}, "not a pitch"},
    {{"x", "2", "0x10", "2/1"}, "not a pitch"},
    {{"x", "2", "inf", "2/1"}, "not a pitch"},
    {{"x", "3", "5/4", "9/8", "2/1"}, "ascend"},
    {{"x", "2", "1/1", "2/1"}, "ascend"},
    {{"x", "1", "99.0"}, "period"},
    {{"x", "1", "4801.0"}, "period"},
    {{"x", "2", "1300.0", "1200.0"}, "above the period"},
  }
  for _, case in ipairs(refusals) do
    local refused, reason = t.parse_scl(table.concat(case[1], "\n"))
    assert_equal(refused, nil, table.concat(case[1], " | ") .. " is refused")
    assert_true(type(reason) == "string" and reason:find(case[2], 1, true) ~= nil,
      table.concat(case[1], " | ") .. ": " .. tostring(reason) .. " names " .. case[2])
  end
  local big = "x\n1\n2/1\n" .. string.rep("!", t.TUNING.max_file_bytes)
  assert_equal(t.parse_scl(big), nil, "a file over max_file_bytes is refused")
end)

test("a Scala file with CRLF and a BOM reads as its Unix copy", function()
  load_strata()
  local t = tuning()
  local unix = table.concat({"! fifths.scl", "Fifths", " 3", "!", " 9/8", " 701.955", " 2/1", ""}, "\n")
  local windows = "\239\187\191" .. unix:gsub("\n", "\r\n")
  local period, tones = t.parse_scl(unix)
  local wperiod, wtones = t.parse_scl(windows)
  assert_true(period ~= nil and wperiod ~= nil, "both read: " .. tostring(tones) .. ", " .. tostring(wtones))
  assert_equal(t.text_of(wperiod, wtones), t.text_of(period, tones), "the same tuning")
end)

test("a file is listed from the tunings folder and loads by name", function()
  local context = load_strata(); finish_startup(context)
  local t = tuning()
  assert_equal(#t.files(), 0, "no file yet")
  local folder = _path.data .. t.TUNING.folder
  assert_true(util.file_exists(folder), "the start makes the tunings folder")
  h.write_text(folder .. "b fifths.scl", "Fifths\n3\n9/8\n3/2\n2/1\n")
  h.write_text(folder .. "a bad.scl", "Bad\n0\n")
  h.write_text(folder .. "notes.txt", "not a tuning\n")
  local files = t.files()
  assert_equal(table.concat(files, ","), "a bad.scl,b fifths.scl", "the two .scl files, by name")
  local entry = t.load_file("b fifths.scl")
  assert_true(entry ~= nil, "a good file loads")
  assert_equal(entry.name, "b fifths", "named for its file")
  assert_equal(#entry.tones, 3, "its tones")
  local from = #context.printed + 1
  local refused, reason = t.load_file("a bad.scl")
  assert_equal(refused, nil, "a bad file is refused")
  assert_true(reason:find("count", 1, true) ~= nil, "with its reason: " .. tostring(reason))
  assert_equal(#context.printed - from + 1, 1, "one line")
  assert_true(context.printed[from]:find("tuning: a bad.scl: ", 1, true) == 1, "naming the file: " .. context.printed[from])
  t.select(entry)
  assert_equal(params:get("tuning_name"), "b fifths", "the name")
  assert_equal(t.count(), 3, "the file's tuning")
  h.remove_tree(folder)
  assert_equal(#t.files(), 0, "a missing folder lists none")
end)


-- Storage (design §6.4, ruling 42) ------------------------------------------

local function note_of(freq) return 69 + 12 * math.log(freq / 440) / math.log(2) end
local function freq_of(note) return 440 * 2 ^ ((note - 69) / 12) end

-- The index of the first engine call named name whose args match, or nil
local function first_call(context, name, match)
  for index, call in ipairs(context.engine_calls) do
    if call.name == name and (not match or match(call.args)) then return index end
  end
  return nil
end

test("a PSET carries the tuning and applies it before the voices", function()
  local context = load_strata({ data_subdir = "tuning_pset_round_trip" }); finish_startup(context)
  util.make_dir(context.data_dir)
  use("19 equal")
  params:set("v1_quantize", 1)
  params:set("v1_freq", freq_of(60 + 5 * 12 / 19))
  local saved = params:get("v1_freq")
  local path = context.data_dir .. "tuned.pset"
  params:write(path, "tuned")
  use("12 equal")
  assert_equal(tuning().count(), 12, "the session moved to twelve equal")
  context.clear_engine_calls()
  params:read(path)
  assert_equal(params:get("tuning_name"), "19 equal", "the name is back")
  assert_equal(tuning().count(), 19, "and the tuning")
  assert_equal(params:get("v1_freq"), saved, "voice 1's freq is the saved one, exactly (#125)")
  local tuned = first_call(context, "setTuning", function(args) return args[1] == 19 end)
  local freq = first_call(context, "setVoiceParam", function(args) return args[1] == 0 and args[2] == "freq" end)
  assert_true(tuned ~= nil, "setTuning(19, 1200) is sent")
  assert_true(freq == nil or tuned < freq, "before any v1_freq send")
end)

test("a PSET without the tuning lines comes back in twelve equal steps, its quantized voices snapped again", function()
  local context = load_strata({ data_subdir = "tuning_pset_without_lines" }); finish_startup(context)
  util.make_dir(context.data_dir)
  local path = context.data_dir .. "old.pset"
  params:set("v1_quantize", 1)
  params:set("v1_freq", 440)
  params:write(path, "old")
  local lines = {}
  for line in h.file_text(path):gmatch("[^\n]*\n") do
    if not line:match('^"tuning_') then lines[#lines + 1] = line end
  end
  h.write_text(path, table.concat(lines))
  use("24 equal")
  params:set("v1_freq", freq_of(69.5))
  assert_near(note_of(params:get("v1_freq")), 69.5, 1e-6, "a quarter tone")
  context.clear_engine_calls()
  params:read(path)
  assert_equal(params:get("tuning_name"), "12 equal", "tuning_name at its default")
  assert_equal(params:get("tuning_tones"), tuning().TUNING.default_text, "tuning_tones at its default")
  local tuned = first_call(context, "setTuning")
  assert_true(tuned ~= nil and context.engine_calls[tuned].args[1] == 12, "setTuning(12, 1200) is sent")
  local note = note_of(params:get("v1_freq"))
  assert_near(note, 69, 1e-6, "voice 1's freq is the saved whole note again (" .. note .. ")")
  -- a silent read sets both silently and sends nothing
  use("24 equal")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get("tuning_tones"), tuning().TUNING.default_text, "a silent read sets the default text")
  assert_equal(#sent_tuning(context), 0, "and sends nothing")
end)

-- Fix round 1 (#125 with the tuning): a PSET without the tuning lines,
-- read over a session in another tuning, loads every voice's saved freq
-- exactly once the default tuning is in force
local FIVE_EQUAL = "1200 0 240 480 720 960"

-- A PSET of this session (voice 3 quantized on C#4) without its tuning
-- lines, at path
local function pset_without_tuning(context, name)
  util.make_dir(context.data_dir)
  params:set("v3_quantize", 1)
  params:set("v3_freq", freq_of(61))
  local path = context.data_dir .. name .. ".pset"
  params:write(path, name)
  local lines = {}
  for line in h.file_text(path):gmatch("[^\n]*\n") do
    if not line:match('^"tuning_') then lines[#lines + 1] = line end
  end
  h.write_text(path, table.concat(lines))
  return path
end

-- How many times v3_freq's action runs while fn does
local function freq_actions(fn)
  local param = params:lookup_param("v3_freq")
  local real, count = param.action, 0
  param.action = function(...) count = count + 1; return real(...) end
  fn()
  param.action = real
  return count
end

test("a PSET without the tuning lines loads a quantized voice's saved pitch over a coarse tuning (#125)", function()
  local context = load_strata({ data_subdir = "tuning_pset_coarse" }); finish_startup(context)
  local path = pset_without_tuning(context, "csharp")
  params:set("tuning_name", "5 equal")
  params:set("tuning_tones", FIVE_EQUAL)
  assert_equal(tuning().count(), 5, "the session is in five equal steps")
  params:read(path)
  assert_equal(tuning().count(), 12, "twelve equal steps again")
  assert_near(note_of(params:get("v3_freq")), 61, 0.01, "voice 3 on C#4 to the cent")
end)

test("a PSET with its tuning lines, or read over twelve equal steps, sets no freq twice", function()
  local context = load_strata({ data_subdir = "tuning_pset_once" }); finish_startup(context)
  local path = pset_without_tuning(context, "plain")
  params:set("v3_freq", freq_of(64))
  assert_equal(freq_actions(function() params:read(path) end), 1, "over twelve equal steps: the voice's line alone")
  assert_near(note_of(params:get("v3_freq")), 61, 0.01, "C#4")
  use("19 equal")
  params:set("v3_freq", freq_of(60 + 12 * 7 / 19))
  local tuned = context.data_dir .. "tuned.pset"
  params:write(tuned, "tuned")
  local saved = params:get("v3_freq")
  use("12 equal")
  local count = freq_actions(function() params:read(tuned) end)
  -- the tuning line's change re-snaps the session's freq first (as a scale
  -- line does, #125), then the voice's own line sets the saved one: nothing
  -- sets it again after
  assert_equal(count, 2, "with its tuning lines: the re-snap and the voice's line, no third set")
  assert_equal(params:get("v3_freq"), saved, "the saved freq, exactly")
end)

-- #842: a silent read sets tuning_name and tuning_tones without their
-- actions; the read hook brings the module to the text the read left
-- (sending nothing, as the read is silent), so the name shown is the
-- tuning in force, and a later choice of that tuning reaches the engine,
-- whose tuning the silent read left as it was
test("a silent PSET read brings the tuning to the read's text, and choosing it then sends it (#842)", function()
  local context = load_strata({ data_subdir = "tuning_silent_read" }); finish_startup(context)
  util.make_dir(context.data_dir)
  use("19 equal")
  local path = context.data_dir .. "nineteen.pset"
  params:write(path, "nineteen")
  use("ji normal")
  assert_equal(tuning().count(), 12, "the session moved to ji normal")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get("tuning_name"), "19 equal", "the read's name")
  assert_equal(tuning().count(), 19, "and the module's tuning is the read's")
  assert_near(tuning().tones()[2], 1200 / 19, 1e-3, "its tones")
  assert_equal(#sent_tuning(context), 0, "a silent read sends nothing")
  use("19 equal")
  local sent = sent_tuning(context)
  assert_true(#sent == 20 and sent[1].name == "setTuning" and sent[1].args[1] == 19,
    "choosing 19 equal then sends it: setTuning(19, 1200) and its tones (" .. #sent .. " sends)")
  context.clear_engine_calls()
  use("19 equal")
  assert_equal(#sent_tuning(context), 0, "choosing it again, the engine's tuning, sends nothing")
  -- a read that is not silent applies the text through its action, once
  use("ji normal")
  context.clear_engine_calls()
  params:read(path)
  sent = sent_tuning(context)
  assert_true(#sent == 20 and sent[1].args[1] == 19, "a read sends the tuning once (" .. #sent .. " sends)")
  -- a silent read of 19 equal over ji normal, then a read of it that is
  -- not silent: the text is unchanged (norns runs no action), but the
  -- engine still has ji normal, so the read sends 19 equal (review fix)
  use("ji normal")
  params:read(path, true)
  context.clear_engine_calls()
  params:read(path)
  sent = sent_tuning(context)
  assert_true(#sent == 20 and sent[1].name == "setTuning" and sent[1].args[1] == 19,
    "a read after a silent one sends the tuning the engine lacks (" .. #sent .. " sends)")
  context.clear_engine_calls()
  params:read(path)
  assert_equal(#sent_tuning(context), 0, "and a read when the engine has it sends nothing")
end)

test("the start sends no tuning and makes the tunings folder", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(#sent_tuning(context), 0, "a default start sends no setTuning or setTuningTone (ruling 42)")
  assert_true(util.file_exists(_path.data .. tuning().TUNING.folder), "the folder exists")
end)
end
