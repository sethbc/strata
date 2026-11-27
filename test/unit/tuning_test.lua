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

test("a preset with no voice quantize switch restores its saved pitch (#1224)", function()
  local context = load_strata()
  finish_startup(context)
  local path = context.data_dir .. "before-quantize.pset"
  h.write_text(path, '"v1_freq": 450\n')
  for _, previous in ipairs({0, 1}) do
    params:set("v1_quantize", previous)
    params:set("v1_freq", 300)
    params:read(path)
    assert_equal(params:get("v1_quantize"), 0)
    assert_near(params:get("v1_freq"), 450, 1e-6)
    assert_near(local_value("voices")[1].values.freq, 450, 1e-6)
  end
end)

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

-- The engine hears each tone and the period as an OSC float, float32
-- (#884): exact float32 values, so the test needs no pack of its own
test("float32 rounds a number as an OSC float carries it, on Lua 5.3 and LuaJIT alike", function()
  load_strata()
  local float32 = tuning().float32
  assert_equal(float32(100), 100, "a whole number stays")
  assert_equal(float32(100.0000001), 100, "100.0000001 is 100")
  assert_equal(float32(100.0000002), 100, "100.0000002 is 100")
  assert_equal(float32(1199.99999), 1200, "1199.99999 is 1200")
  assert_equal(float32(4500.0002), 4500, "4500.0002 is 4500")
  assert_equal(float32(0.1), 0.100000001490116119384765625, "0.1 is float32's nearest")
  assert_equal(float32(16777217), 16777216, "a tie goes to the even")
  assert_equal(float32(-0.75), -0.75, "a negative number stays")
end)

test("a tuning whose tones are equal in float32 is refused by Lua (#884)", function()
  local context = load_strata(); finish_startup(context)
  local t = tuning()
  use("ji normal")
  local kept = params:get("tuning_tones")
  -- each ascends below its period in doubles; the engine hears two equal
  -- tones, or a last tone at the period, and keeps its tuning
  local bad = {"1200 0 100.0000001 100.0000002", "1200 0 1199.99999", "4800 0 4500.0001 4500.0002",
    "4800 0 4799.9999"}
  for _, text in ipairs(bad) do
    assert_equal(t.parse_text(text), nil, text .. " does not read")
    local from = #context.printed + 1
    context.clear_engine_calls()
    params:set("tuning_tones", text)
    assert_equal(#context.printed - from + 1, 1, "one line for " .. text)
    assert_true(context.printed[from]:match("^tuning: ") ~= nil, "the line starts tuning: (" .. tostring(context.printed[from]) .. ")")
    assert_equal(params:get("tuning_tones"), kept, "the param is set back: " .. text)
    assert_equal(#sent_tuning(context), 0, "nothing sent for " .. text)
    assert_equal(t.count(), 12, "the tuning stays ji normal")
  end
  assert_equal(t.parse_scl("x\n3\n100.0000001\n100.0000002\n1200.0"), nil, "a Scala file of the same is refused")
  assert_equal(t.parse_scl("x\n2\n1199.99999\n1200.0"), nil, "and one with a last tone at the period in float32")
  -- tones a double apart that float32 still tells apart (its step at 100
  -- cents is about 7.6e-6) read and are sent: nothing over-refused
  context.clear_engine_calls()
  params:set("tuning_tones", "1200 0 100.0001 100.0002")
  assert_equal(#sent_tuning(context), 4, "1200 0 100.0001 100.0002 is sent")
  assert_equal(t.count(), 3, "and is the tuning")
end)

-- The engine ignores a tone or a period that is not finite (setTuning,
-- setTuningTone), so a set holding one never completes there and its old
-- tuning stays: Lua refuses it as the engine does (#884)
test("a tuning with a tone or a period that is not a number, or infinite, is refused by Lua (#884)", function()
  local context = load_strata(); finish_startup(context)
  local t = tuning()
  local huge = string.rep("1", 400)
  -- a ratio of two 400-digit integers is inf / inf: NaN cents
  local files = {
    {"x\n2\n" .. huge .. "/" .. huge .. "\n1200.0", "a NaN tone"},
    {"x\n3\n" .. huge .. "/" .. huge .. "\n100.0\n1200.0", "a NaN tone before a finite one"},
    {"x\n1\n" .. huge .. "/" .. huge, "a NaN period"},
    {"x\n2\n" .. huge .. ".0\n1200.0", "an infinite tone"},
    {"x\n2\n1/" .. huge .. "\n1200.0", "a tone of minus infinity"},
    {"x\n1\n" .. huge .. ".0", "an infinite period"},
  }
  for _, case in ipairs(files) do
    assert_equal(t.parse_scl(case[1]), nil, "a Scala file with " .. case[2] .. " is refused")
  end
  assert_equal(t.parse_text("1200 0 " .. huge), nil, "a text with an infinite tone is refused")
  assert_equal(t.parse_text(huge .. " 0 100"), nil, "a text with an infinite period is refused")
  use("ji normal")
  local nan, inf = 0 / 0, math.huge
  local entries = {{period = 1200, tones = {0, nan}}, {period = 1200, tones = {0, inf}},
    {period = 1200, tones = {0, -inf}}, {period = nan, tones = {0, 100}}, {period = inf, tones = {0, 100}}}
  for index, entry in ipairs(entries) do
    context.clear_engine_calls()
    t.select({name = "bad " .. index, period = entry.period, tones = entry.tones})
    assert_equal(#sent_tuning(context), 0, "nothing sent for entry " .. index)
    assert_equal(t.count(), 12, "the tuning stays ji normal (entry " .. index .. ")")
    assert_equal(t.name(), "ji normal", "the refused entry keeps the tuning name")
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
    -- These are distinct OSC floats as written. At four decimal places
    -- 4500.0001 and 4500.0002 both reach the engine as exactly 4500.
    {{"x", "3", "4500.00014", "4500.000249", "4800.0"}, "ascend"},
    {{"x", "2", "4500.00014", "4500.000249"}, "above the period"},
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

test("a Scala choice applies its saved tones or leaves the old tuning in the editor (#1080)", function()
  local context = load_strata({data_subdir = "scala_choice_precision"}); finish_startup(context)
  local t = tuning()
  local folder = _path.data .. t.TUNING.folder
  h.write_text(folder .. "clear.scl", "Clear\n3\n100.001\n100.004\n2/1\n")
  h.write_text(folder .. "close.scl", "Close\n3\n100.00001\n100.00004\n2/1\n")
  h.show_page("SETUP")
  local_value("lib").ui_scale_editor.open()
  enc(2, 3)
  enc(3, #t.built_ins())  -- first file after the built-ins
  context.clear_engine_calls()
  h.tap(3)
  local text = "1200 0 100.001 100.004"
  assert_equal(t.name(), "clear", "the distinct pair applies under its file name")
  assert_equal(params:get("tuning_tones"), text, "the PSET text keeps both pitches")
  local function check_active()
    assert_equal(t.count(), 3, "the three-tone tuning is active")
    local calls = sent_tuning(context)
    assert_equal(#calls, 4, "the engine gets the whole tuning")
    assert_equal(calls[1].args[1], 3, "the count")
    assert_equal(calls[1].args[2], 1200, "the period")
    for index, cents in ipairs({0, 100.001, 100.004}) do
      assert_equal(calls[index + 1].args[1], index - 1, "the engine tone index")
      assert_equal(calls[index + 1].args[2], cents, "the engine tone in cents")
      assert_equal(t.tones()[index], cents, "the active tone in cents")
    end
  end
  check_active()
  context.clear_engine_calls()
  enc(3, 1)  -- next file, whose two pitches round to 100 cents
  h.tap(3)
  h.next_frame(context)
  assert_equal(t.name(), "clear", "a refused choice keeps the active name")
  assert_equal(params:get("tuning_tones"), text, "and its saved text")
  assert_equal(t.tones()[3], 100.004, "the active table stays")
  assert_equal(#sent_tuning(context), 0, "the engine keeps its table")
  assert_true(h.hint_text(context):find("ascend", 1, true) ~= nil, "the editor explains the refusal")

  local path = context.data_dir .. "scala.pset"
  params:write(path, "scala")
  use("12 equal")
  context.clear_engine_calls()
  params:read(path)
  assert_equal(t.name(), "clear", "the PSET restores the name")
  check_active()
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
  -- a silent read sets both silently, and its hook sends the default (#965)
  use("24 equal")
  context.clear_engine_calls()
  params:read(path, true)
  assert_equal(params:get("tuning_tones"), tuning().TUNING.default_text, "a silent read sets the default text")
  assert_equal(#sent_tuning(context), 13, "and sends it, as a read with actions does (#965)")
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
-- actions; the read hook brings the module to the text the read left, so
-- the name shown is the tuning in force, and (#965) sends it, so a later
-- choice of that tuning sends nothing
test("a silent PSET read brings the tuning to the read's text and sends it (#842, #965)", function()
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
  local sent = sent_tuning(context)
  assert_true(#sent == 20 and sent[1].name == "setTuning" and sent[1].args[1] == 19,
    "the silent read sends it: setTuning(19, 1200) and its tones (" .. #sent .. " sends, #965)")
  assert_true(tuning().engine_has_tuning(), "the engine has it")
  context.clear_engine_calls()
  use("19 equal")
  assert_equal(#sent_tuning(context), 0, "choosing it then, the engine's tuning, sends nothing")
  -- a read that is not silent applies the text through its action, once
  use("ji normal")
  context.clear_engine_calls()
  params:read(path)
  sent = sent_tuning(context)
  assert_true(#sent == 20 and sent[1].args[1] == 19, "a read sends the tuning once (" .. #sent .. " sends)")
  -- a silent read of 19 equal over ji normal, then a read of it that is
  -- not silent: the silent one sent it (#965), so the read, whose text is
  -- unchanged, sends nothing
  use("ji normal")
  params:read(path, true)
  context.clear_engine_calls()
  params:read(path)
  assert_equal(#sent_tuning(context), 0, "a read after a silent one sends nothing: the engine has the tuning")
end)

-- #965 (the review's probe: 50 calls after a read with actions, 7 after a
-- silent one): a silent read of a PSET in another tuning sends the engine
-- the tuning, and resends a running chord voice's intervals in it, as a
-- read with actions does
test("a silent read of a PSET with another tuning sends the tuning (#965)", function()
  local function read(silent)
    local context = load_strata({ data_subdir = "tuning_silent_sends_" .. tostring(silent) })
    finish_startup(context)
    local S = local_value("S")
    util.make_dir(context.data_dir)
    if not S.voices[1].active then toggle_voice(1) end
    params:set("v1_intervals", S.lib.variation.VARIATION.set_index.chord)
    local session, path = context.data_dir .. "session.pset", context.data_dir .. "nineteen.pset"
    params:write(session, "session")
    use("19 equal")
    params:write(path, "nineteen")
    params:read(session)
    context.clear_engine_calls()
    params:read(path, silent)
    local sent, intervals, lists = {}, {}, 0
    for _, call in ipairs(sent_tuning(context)) do sent[#sent + 1] = call.name .. " " .. table.concat(call.args, " ") end
    for _, call in ipairs(context.engine_calls) do
      if call.name == "setGrainParam" and tostring(call.args[2]):match("^interval") then
        intervals[call.args[2]] = call.args[3]
        if call.args[2] == "intervalCount" then lists = lists + 1 end
      end
    end
    return table.concat(sent, "\n"), intervals, lists
  end
  local actions_sent, actions_intervals = read(false)
  local silent_sent, silent_intervals, silent_lists = read(true)
  assert_equal(silent_lists, 1, "the chord's list goes once, never twice (fix round 1)")
  assert_true(tuning().engine_has_tuning(), "the engine has the read's tuning")
  assert_equal(tuning().count(), 19, "19 equal")
  assert_equal(silent_sent, actions_sent, "the tuning sent as a read with actions sends it")
  assert_true(next(actions_intervals) ~= nil, "a read with actions resends the chord's intervals")
  for name, value in pairs(actions_intervals) do
    assert_near(silent_intervals[name] or -1, value, 1e-9, "the chord's " .. name .. " in the read's tuning")
  end
end)

-- Fix round 1 of #965: the silent read's hook snaps the quantized freqs
-- inside the read, before the voice params' hook. A PSET whose quantized
-- voice's freq is no tone of its own tuning (a file written by hand: 450
-- Hz, or the session's own stored freq, a tone of the session's tuning,
-- which leaves the voice params' hook nothing to set) ends with
-- the freq a read with actions leaves, stored and sent
test("a silent read of a quantized freq off its PSET's tuning snaps it as a read with actions does (#965)", function()
  local function read(silent, freq_line)
    local context = load_strata({ data_subdir = "tuning_silent_snap_" .. tostring(silent) })
    finish_startup(context)
    local S = local_value("S")
    util.make_dir(context.data_dir)
    local path = context.data_dir .. "off.pset"
    use("19 equal")
    params:set("v2_quantize", 1)
    params:write(path, "off")
    use("ji normal")
    local lines = {}
    for line in h.file_text(path):gmatch("[^\n]*\n") do
      if line:match('^"v2_freq"') then line = '"v2_freq": ' .. freq_line(S) .. '\n' end
      lines[#lines + 1] = line
    end
    h.write_text(path, table.concat(lines))
    params:read(path, silent)
    local engine_freq
    for _, call in ipairs(context.engine_calls) do
      if call.name == "setVoiceParam" and call.args[1] == 1 and call.args[2] == "freq" then engine_freq = call.args[3] end
    end
    return params:get("v2_freq"), S.voices[2].values.freq, S, engine_freq
  end
  local lines = {
    ["450 Hz"] = function() return "450.0" end,
    ["the session's freq"] = function(S) return string.format("%.17g", S.voices[2].values.freq) end,
  }
  for what, freq_line in pairs(lines) do
    local actions_param, actions_stored, _, actions_engine = read(false, freq_line)
    local silent_param, silent_stored, S, silent_engine = read(true, freq_line)
    assert_near(silent_param, actions_param, 1e-9, what .. ": the silent read's freq is a read with actions'")
    assert_near(silent_stored, actions_stored, 1e-9, what .. ": and stored the same")
    assert_near(silent_stored, silent_param, 1e-9, what .. ": stored as the param holds it")
    assert_near(silent_engine, actions_engine, 1e-9, what .. ": and the engine holds the same freq")
    assert_near(silent_engine, silent_param, 1e-9, what .. ": the freq the param holds")
    assert_true(S.voices[2].active, "voice 2 runs")
    if what == "450 Hz" then
      assert_true(math.abs(actions_param - 450) > 1e-6, "a read with actions snaps 450 Hz to a tone of 19 equal")
    end
  end
end)

test("the start sends no tuning and makes the tunings folder", function()
  local context = load_strata(); finish_startup(context)
  assert_equal(#sent_tuning(context), 0, "a default start sends no setTuning or setTuningTone (ruling 42)")
  assert_true(util.file_exists(_path.data .. tuning().TUNING.folder), "the folder exists")
end)

-- 3.9 (#915): the invariant `tuning`, the param's text equal to the tuning
-- in force (engine_text lags only inside a read, until the hook sends, #965)
local function tuning_broken()
  for _, line in ipairs(h.check_invariants()) do
    if line:sub(1, #"tuning: ") == "tuning: " then return line end
  end
end

test("the tuning invariant holds through a refused text and names a param text the tuning never took", function()
  load_strata()
  assert_equal(tuning_broken(), nil, "at load")
  params:set("tuning_tones", "1200 0 240 480 720 960")
  assert_equal(tuning_broken(), nil, "a text that reads")
  for _, text in ipairs({"abc", "1200 0 100.0000001 100.0000002", "1200 0 nan", "inf 0 100"}) do
    params:set("tuning_tones", text)
    assert_equal(tuning_broken(), nil, "a refused text (" .. text .. "): the param is set back")
  end
  h.allow_broken_invariants("the test sets the param's text silently on purpose")
  params:set("tuning_tones", "1200 0 400 700", true)
  assert_true(tuning_broken() ~= nil, "a text set silently, never taken, is reported")
end)

---------------------------------------------------------------------------
-- The table `tuning` (3.9, #915; docs/notes/lua/tuning.md): whether the
-- engine has the tuning in force, by every way a text reaches tuning_tones.
-- The state is on ji normal (12 tones). Since #965 a silent read sends what
-- it takes, so no event leaves the engine lagging: `engine lags` is no
-- state of the table (the entry's prose says so). Each row's check counts
-- the setTuning and setTuningTone sends and the tones in force
---------------------------------------------------------------------------

local TUNING_TABLE = {five = "1200 0 240 480 720 960", refused = "abc", other = "24 equal", choice = "12 equal"}

local function tuning_enter(context)
  util.make_dir(context.data_dir)
  use(TUNING_TABLE.other)
  context.other_pset = context.data_dir .. "other.pset"
  params:write(context.other_pset, "other")
  use("ji normal")
  context.clear_engine_calls()
end

-- A PSET of the session as it is now (the text in force), read back
local function read_same(silent)
  return function(context)
    local path = context.data_dir .. "same.pset"
    params:write(path, "same")
    params:read(path, silent)
  end
end

-- A row's check: sends setTuning and setTuningTone messages, count tones in force
local function tuned(sends, count)
  return function(context)
    assert_equal(#sent_tuning(context), sends, "setTuning and setTuningTone sends")
    assert_equal(tuning().count(), count, "the tones in force")
    assert_equal(params:get("tuning_tones"), tuning().text_of(tuning().period(), tuning().tones()),
      "tuning_tones holds the tuning in force")
  end
end

h.transition_table({
  name = "tuning",
  notes = {"docs/notes/lua/tuning.md", "tuning"},
  states = {
    ["engine has it"] = tuning_enter,
  },
  events = {
    ["a text that reads"] = function() params:set("tuning_tones", TUNING_TABLE.five) end,
    ["a refused text"] = function() params:set("tuning_tones", TUNING_TABLE.refused) end,
    ["a silent read of another text"] = function(context) params:read(context.other_pset, true) end,
    ["a silent read of the same text"] = read_same(true),
    ["a read of another text"] = function(context) params:read(context.other_pset) end,
    ["a read of the same text"] = read_same(false),
    ["choosing the tuning in force"] = function() use(params:get("tuning_name")) end,
    ["choosing another tuning"] = function() use(TUNING_TABLE.choice) end,
  },
  state_of = function() return tuning().engine_has_tuning() and "engine has it" or "engine lags" end,
  rows = {
    {"engine has it", "a text that reads", "engine has it", check = tuned(6, 5)},
    {"engine has it", "a refused text", "engine has it", check = tuned(0, 12)},
    {"engine has it", "a silent read of another text", "engine has it", check = tuned(25, 24)},
    {"engine has it", "a silent read of the same text", "engine has it", check = tuned(0, 12)},
    {"engine has it", "a read of another text", "engine has it", check = tuned(25, 24)},
    {"engine has it", "a read of the same text", "engine has it", check = tuned(0, 12)},
    {"engine has it", "choosing the tuning in force", "engine has it", check = tuned(0, 12)},
    {"engine has it", "choosing another tuning", "engine has it", check = tuned(13, 12)},
  },
  impossible = {},
})
end
