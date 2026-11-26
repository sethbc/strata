-- test/unit/mpe_test.lua
-- MPE (lib/mpe.lua, S.lib.mpe): the zones, the per-channel values, the
-- RPNs, the assignment and the MPE and zone params
-- Run alone: lua test/run.lua mpe

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup

local function setup(mode)
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  params:set("midi_channel_mode", mode or 3)
  S.lib.mpe.reset(); S.lib.mpe.reset_ranges()
  return context, S, S.lib.mpe
end

local function same(list, expected, label)
  assert_equal(#list, #expected, (label or "list") .. " length " .. #list)
  for index, value in ipairs(expected) do assert_equal(list[index], value, (label or "list") .. " " .. index) end
end

-- send a control change on a channel
local function cc(mpe, channel, number, value) return mpe.control({type = "cc", ch = channel, cc = number, val = value}) end
local function rpn(mpe, channel, number, value)
  cc(mpe, channel, 101, 0); cc(mpe, channel, 100, number); return cc(mpe, channel, 6, value)
end

test("the module's constants and the mode names", function()
  local _, S, mpe = setup(1)
  assert_equal(mpe.MPE.slide_cc, 74); assert_equal(mpe.MPE.fine_cc, 87); assert_equal(mpe.MPE.master_bend, 2)
  assert_equal(params:string("midi_channel_mode"), "per voice")
  params:set("midi_channel_mode", 3); assert_equal(params:string("midi_channel_mode"), "mpe selected")
  assert_true(mpe.active())
  params:set("midi_channel_mode", 4); assert_equal(params:string("midi_channel_mode"), "mpe split")
  assert_true(mpe.active())
  params:set("midi_channel_mode", 2); assert_true(not mpe.active())
  params:set("midi_channel_mode", 1); assert_true(not mpe.active())
  assert_equal(params:get("mpe_lower_members"), 15); assert_equal(params:get("mpe_upper_members"), 0)
  assert_equal(params:get("mpe_bend_range"), 48)
end)

test("the zones are their master and member channels", function()
  local _, _, mpe = setup()
  local zone, master = mpe.zone(1); assert_equal(zone, "lower"); assert_equal(master, true)
  zone, master = mpe.zone(2); assert_equal(zone, "lower"); assert_equal(master, false)
  zone, master = mpe.zone(16); assert_equal(zone, "lower"); assert_equal(master, false)
  params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
  assert_equal(mpe.zone(8), "lower"); assert_equal(mpe.zone(9), "upper")
  zone, master = mpe.zone(16); assert_equal(zone, "upper"); assert_equal(master, true)
  zone, master = mpe.zone(15); assert_equal(zone, "upper"); assert_equal(master, false)
  params:set("mpe_upper_members", 0); params:set("mpe_lower_members", 3)
  assert_equal(mpe.zone(5), nil); assert_equal(mpe.zone(4), "lower"); assert_equal(mpe.zone(0), nil)
  assert_equal(mpe.zone(17), nil)
  params:set("mpe_lower_members", 0)
  assert_equal(mpe.zone(1), nil, "a zone without members is off, its master too")
end)

test("the member counts never overlap", function()
  local _ = setup()
  params:set("mpe_lower_members", 15); params:set("mpe_upper_members", 4)
  assert_equal(params:get("mpe_lower_members"), 10); assert_equal(params:get("mpe_upper_members"), 4)
  params:set("mpe_upper_members", 0); params:set("mpe_lower_members", 15)
  assert_equal(params:get("mpe_lower_members"), 15)
  params:set("mpe_lower_members", 10); params:set("mpe_upper_members", 4)
  params:set("mpe_lower_members", 12)
  assert_equal(params:get("mpe_upper_members"), 2, "the other is lowered")
  params:set("mpe_lower_members", 15)
  assert_equal(params:get("mpe_upper_members"), 0, "15 members leave the other zone off")
end)

test("a note outside both zones has no target", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 3)
  same(mpe.targets(9, 60), {})
  same(mpe.targets(5, 60), {})
end)

test("mpe selected sends every zone note to the selected voice; mpe split to every voice whose zone and range hold it", function()
  local _, S, mpe = setup(3)
  S.selected_voice = 4
  same(mpe.targets(2, 60), {4}); same(mpe.targets(1, 60), {4}, "the master channel")
  params:set("midi_channel_mode", 4)
  same(mpe.targets(2, 60), {1})
  params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
  same(mpe.targets(15, 60), {2}); same(mpe.targets(16, 60), {2})
  params:set("v3_zone", 2); params:set("v3_zone_low", 48); params:set("v3_zone_high", 72)
  same(mpe.targets(2, 60), {1, 3}); same(mpe.targets(2, 80), {1}); same(mpe.targets(2, 47), {1})
  params:set("midi_channel_mode", 1); same(mpe.targets(2, 60), {}, "outside the MPE modes")
end)

test("a member channel's bend uses the bend range, times its zone's master bend", function()
  local _, _, mpe = setup()
  assert_equal(mpe.values(2).bend, 1)
  local changed = mpe.control({type = "pitchbend", ch = 2, val = 16383})
  same(changed, {2})
  assert_near(mpe.values(2).bend, 2 ^ ((8191 / 8192) * 48 / 12), 1e-9)
  local member = mpe.values(2).bend
  changed = mpe.control({type = "pitchbend", ch = 1, val = 16383})
  assert_equal(#changed, 16, "the master and its 15 members"); assert_equal(changed[1], 1); assert_equal(changed[16], 16)
  assert_near(mpe.values(2).bend, member * 2 ^ ((8191 / 8192) * 2 / 12), 1e-9)
  assert_near(mpe.values(5).bend, 2 ^ ((8191 / 8192) * 2 / 12), 1e-9, "another member: only the master's")
  assert_near(mpe.values(1).bend, 2 ^ ((8191 / 8192) * 2 / 12), 1e-9, "the master's own bend")
  params:set("mpe_bend_range", 12)
  assert_near(mpe.values(2).bend, 2 ^ ((8191 / 8192) * 12 / 12) * 2 ^ ((8191 / 8192) * 2 / 12), 1e-9)
  mpe.control({type = "pitchbend", ch = 2, val = 0})
  assert_near(mpe.values(2).bend, 2 ^ -1 * 2 ^ ((8191 / 8192) * 2 / 12), 1e-9)
end)

test("a master bend changes only its own zone's members", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
  local changed = mpe.control({type = "pitchbend", ch = 16, val = 16383})
  same(changed, {9, 10, 11, 12, 13, 14, 15, 16})
  assert_equal(mpe.values(2).bend, 1)
  assert_true(mpe.values(9).bend > 1)
end)

-- a full-up master bend on `channel`, then the ratio a member of that zone plays
-- (full up is raw 16383, one step short of +1)
local function full_up(range) return 2 ^ ((16383 - 8192) / 8192 * range / 12) end
local function master_ratio(mpe, master_channel, member)
  mpe.control({type = "pitchbend", ch = master_channel, val = 16383})
  local ratio = mpe.values(member).bend
  mpe.control({type = "pitchbend", ch = master_channel, val = 8192})
  return ratio
end

test("a reset keeps the master bend range the controller set (#688)", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 7)
  rpn(mpe, 1, 0, 12)
  mpe.reset()
  assert_near(master_ratio(mpe, 1, 2), full_up(12), 1e-9, "12 semitones, not 2")
end)

test("a reset still forgets every channel's values and selected RPN", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 7)
  mpe.control({type = "pitchbend", ch = 3, val = 16383})
  mpe.control({type = "channel_pressure", ch = 3, val = 64})
  cc(mpe, 3, 74, 127); cc(mpe, 3, 87, 5)
  cc(mpe, 3, 101, 0); cc(mpe, 3, 100, 0)
  mpe.reset()
  assert_equal(mpe.values(3).bend, 1)
  assert_equal(mpe.values(3).pressure, nil)
  assert_equal(mpe.values(3).slide, 0)
  local range = params:get("mpe_bend_range")
  cc(mpe, 3, 6, 12)
  assert_equal(params:get("mpe_bend_range"), range, "the selected RPN was forgotten")
  cc(mpe, 3, 74, 64)
  assert_near(mpe.values(3).slide, 64 / 127, 1e-12, "the pending CC87 was forgotten")
end)

test("an MPE configuration message resets its zone's master bend range and leaves the other zone's (#688)", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
  rpn(mpe, 1, 0, 12); rpn(mpe, 16, 0, 7)
  rpn(mpe, 1, 6, 7)
  assert_near(master_ratio(mpe, 1, 2), full_up(2), 1e-9, "the lower zone is back to 2")
  assert_near(master_ratio(mpe, 16, 9), full_up(7), 1e-9, "the upper zone keeps 7")
  rpn(mpe, 1, 0, 24)
  assert_near(master_ratio(mpe, 1, 2), full_up(24), 1e-9, "RPN 0 after it is stored")
  rpn(mpe, 1, 6, 0); params:set("mpe_lower_members", 7)
  assert_near(master_ratio(mpe, 1, 2), full_up(2), 1e-9, "a count of 0 resets it too")
end)

test("reset_ranges puts both master bend ranges back to 2", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
  rpn(mpe, 1, 0, 12); rpn(mpe, 16, 0, 7)
  mpe.reset_ranges()
  assert_near(master_ratio(mpe, 1, 2), full_up(2), 1e-9)
  assert_near(master_ratio(mpe, 16, 9), full_up(2), 1e-9)
end)

test("pressure is nil until first received; slide and pressure are 0-1", function()
  local _, _, mpe = setup()
  assert_equal(mpe.values(3).pressure, nil); assert_equal(mpe.values(3).slide, 0)
  same(mpe.control({type = "channel_pressure", ch = 3, val = 64}), {3})
  assert_near(mpe.values(3).pressure, 64 / 127, 1e-12)
  same(cc(mpe, 3, 74, 127), {3})
  assert_equal(mpe.values(3).slide, 1)
  mpe.control({type = "channel_pressure", ch = 3, val = 0}); assert_equal(mpe.values(3).pressure, 0)
  assert_equal(mpe.values(4).pressure, nil, "per channel")
end)

test("CC87 is the low seven bits of the channel's next pressure or CC74, once", function()
  local _, _, mpe = setup()
  same(cc(mpe, 4, 87, 100), {})
  mpe.control({type = "channel_pressure", ch = 4, val = 64})
  assert_near(mpe.values(4).pressure, (64 * 128 + 100) / 16383, 1e-12)
  mpe.control({type = "channel_pressure", ch = 4, val = 64})
  assert_near(mpe.values(4).pressure, 64 / 127, 1e-12)
  cc(mpe, 4, 87, 5); cc(mpe, 4, 74, 127)
  assert_near(mpe.values(4).slide, (127 * 128 + 5) / 16383, 1e-12)
  cc(mpe, 4, 74, 127); assert_equal(mpe.values(4).slide, 1, "once")
end)

test("a stale CC87 never reaches a later message on another channel", function()
  local _, _, mpe = setup()
  cc(mpe, 4, 87, 100); cc(mpe, 5, 74, 64)
  assert_near(mpe.values(5).slide, 64 / 127, 1e-12)
  mpe.control({type = "channel_pressure", ch = 4, val = 64})
  assert_near(mpe.values(4).pressure, (64 * 128 + 100) / 16383, 1e-12, "channel 4's still waits for it")
end)

test("RPN 6 sets a zone's member count and RPN 0 a bend range", function()
  local _, S, mpe = setup()
  local flash = S.lib.ui_flash
  rpn(mpe, 1, 6, 7)
  assert_equal(params:get("mpe_lower_members"), 7); assert_equal(flash.text("header"), "MPE lower 7")
  rpn(mpe, 16, 6, 5)
  assert_equal(params:get("mpe_upper_members"), 5); assert_equal(flash.text("header"), "MPE upper 5")
  assert_equal(params:get("mpe_lower_members"), 7)
  rpn(mpe, 2, 0, 24); assert_equal(params:get("mpe_bend_range"), 24)
  rpn(mpe, 1, 0, 12)
  assert_equal(params:get("mpe_bend_range"), 24, "the master's range is kept apart")
  mpe.control({type = "pitchbend", ch = 1, val = 16383})
  assert_near(mpe.values(2).bend, 2 ^ ((8191 / 8192) * 12 / 12), 1e-9,
    "the lower master's range is 12")
  local listed = rpn(mpe, 1, 0, 12)
  assert_equal(listed[1], 1, "a master's range change lists the master itself")
  assert_equal(#listed, 8, "and its 7 members")
  rpn(mpe, 16, 0, 1); assert_equal(params:get("mpe_bend_range"), 24)
  rpn(mpe, 1, 6, 99); assert_equal(params:get("mpe_lower_members"), 15, "a count over 15 clamps")
  assert_equal(params:get("mpe_upper_members"), 0, "and leaves the other zone off")
  rpn(mpe, 3, 6, 4); assert_equal(params:get("mpe_lower_members"), 15, "RPN 6 on a member channel is no configuration")
  rpn(mpe, 1, 6, 0); assert_equal(params:get("mpe_lower_members"), 0)
end)

test("a data entry changes a setting only under RPN 0 or 6", function()
  local _, _, mpe = setup()
  cc(mpe, 1, 6, 3); assert_equal(params:get("mpe_lower_members"), 15)
  cc(mpe, 1, 101, 0); cc(mpe, 1, 100, 5); cc(mpe, 1, 6, 3)
  assert_equal(params:get("mpe_lower_members"), 15, "another RPN")
  cc(mpe, 1, 101, 0); cc(mpe, 1, 100, 6); cc(mpe, 1, 101, 127); cc(mpe, 1, 100, 127); cc(mpe, 1, 6, 3)
  assert_equal(params:get("mpe_lower_members"), 15, "the null RPN")
  cc(mpe, 1, 101, 0); cc(mpe, 1, 100, 6); cc(mpe, 1, 38, 0)
  assert_equal(params:get("mpe_lower_members"), 15, "the LSB alone changes nothing")
  cc(mpe, 2, 6, 3); assert_equal(params:get("mpe_lower_members"), 15, "the selection is per channel")
  cc(mpe, 1, 6, 3); assert_equal(params:get("mpe_lower_members"), 3, "the selection stands")
  mpe.reset(); cc(mpe, 1, 6, 4); assert_equal(params:get("mpe_lower_members"), 3, "a reset forgets it")
end)

test("pressure and CC74 on a master channel are ignored; outside the MPE modes control returns nil", function()
  local _, _, mpe = setup()
  params:set("mpe_lower_members", 3)
  mpe.control({type = "channel_pressure", ch = 1, val = 64}); assert_equal(mpe.values(1).pressure, nil)
  cc(mpe, 1, 74, 64); assert_equal(mpe.values(1).slide, 0)
  mpe.control({type = "channel_pressure", ch = 9, val = 64}); assert_equal(mpe.values(9).pressure, nil)
  mpe.control({type = "pitchbend", ch = 9, val = 16383}); assert_equal(mpe.values(9).bend, 1, "outside both zones")
  assert_equal(mpe.control({type = "note_on", ch = 2, note = 60, vel = 1}), nil)
  assert_equal(mpe.control({type = "key_pressure", ch = 2, note = 60, val = 1}), nil)
  assert_equal(cc(mpe, 2, 7, 1), nil, "a CC that is not MPE's")
  params:set("midi_channel_mode", 2)
  assert_equal(mpe.control({type = "pitchbend", ch = 2, val = 16383}), nil)
  assert_equal(cc(mpe, 2, 74, 64), nil)
  assert_equal(mpe.values(2).slide, 0)
  params:set("midi_channel_mode", 3)
  assert_equal(mpe.values(2).bend, 1)
end)

test("a member count shrinking under a channel's values leaves it out of the zone", function()
  local _, _, mpe = setup()
  mpe.control({type = "pitchbend", ch = 9, val = 16383})
  rpn(mpe, 1, 6, 3)
  assert_equal(params:get("mpe_lower_members"), 3)
  same(mpe.control({type = "pitchbend", ch = 9, val = 9000}), {}, "channel 9 is in no zone now")
  same(mpe.targets(9, 60), {})
  assert_equal(mpe.values(9).bend, 1, "outside a zone its bend is 1 again")
end)

test("targets bounds-checks its channel and note", function()
  local _, _, mpe = setup()
  same(mpe.targets(2, 60), {1})
  same(mpe.targets(0, 60), {}); same(mpe.targets(17, 60), {}); same(mpe.targets(2.5, 60), {})
  same(mpe.targets(2, -1), {}); same(mpe.targets(2, 128), {}); same(mpe.targets(2, 60.5), {})
  same(mpe.targets(2, "60"), {}); same(mpe.targets(2, nil), {}); same(mpe.targets(2, 0 / 0), {})
  same(mpe.targets(2, 0), {1}); same(mpe.targets(2, 127), {1})
end)

test("layout-change hooks run once per changed layout param, each contained", function()
  local _, _, mpe = setup()
  local count = 0
  local ok, problem = pcall(mpe.on_layout_change, "x"); assert_true(not ok, "a non-function raises")
  local printed = {}
  local real_print = print
  print = function(...) printed[#printed + 1] = table.concat({...}, " ") end
  mpe.on_layout_change(function() error("hook failed") end)
  mpe.on_layout_change(function() count = count + 1 end)
  params:set("mpe_lower_members", 15)  -- already 15: no change, no hook
  assert_equal(count, 0)
  params:set("mpe_lower_members", 10)
  assert_equal(count, 1, "one set, one run, after the raising hook")
  params:set("mpe_upper_members", 8)
  assert_equal(count, 3, "the set and the count the clamp lowered")
  assert_equal(params:get("mpe_lower_members"), 6)
  params:set("v3_zone", 2); assert_equal(count, 4)
  params:set("v3_zone_low", 10); assert_equal(count, 5)
  params:set("v3_zone_high", 5); assert_equal(count, 7, "the high's clamp moves the low too")
  params:set("v1_zone_high", 127); assert_equal(count, 7, "no change, no run")
  print = real_print
  assert_equal(#printed, 1, "the raising hook is reported once for its message")
  assert_true(printed[1]:find("layout", 1, true) ~= nil)
end)

local function key(context, kind, channel, note)
  context.midi.send(1, {type = kind, ch = channel, note = note, vel = 100})
end

for _, silent in ipairs({false, true}) do
  test((silent and "silent" or "ordinary") .. " PSET moves a held MPE member to its new zone (#1107)", function()
    local context, S, mpe = setup(4)
    params:set("midi_note_off", 2)
    params:set("mpe_upper_members", 8)  -- lower ends at 7, upper begins at 8
    local path = context.data_dir .. "split.pset"
    params:write(path)
    params:set("mpe_lower_members", 7)  -- channel 8 now plays lower
    key(context, "note_on", 8, 60)
    assert_equal(S.lib.notes.held(1), 1)
    for _, cc_value in ipairs({{101, 0}, {100, 0}, {6, 12}}) do
      context.midi.send(1, {type = "cc", ch = 16, cc = cc_value[1], val = cc_value[2]})
    end
    S.lib.midi_in.set_note_tap("learn", function() end)
    context.clear_engine_calls()
    params:read(path, silent)
    assert_equal(S.lib.notes.held(1), 0, "former lower member released")
    assert_equal(next(S.midi_state.held[1]), nil, "former key cleared")
    assert_equal(#context.calls_named("voiceOff"), 1, "the held voice stops once")
    assert_equal(S.lib.midi_in.note_tap_owner(), "learn", "layout edits keep the learn tap")
    S.lib.midi_in.clear_note_tap("learn")
    key(context, "note_on", 8, 64)
    assert_equal(S.lib.notes.held(2), 1, "next note plays upper")
    key(context, "note_off", 8, 60)
    assert_equal(S.lib.notes.held(2), 1, "stale off leaves new key held")
    context.midi.send(1, {type = "pitchbend", ch = 16, val = 16383})
    assert_near(mpe.values(8).bend, full_up(12), 1e-9, "upper master kept its negotiated range")
    context.clear_engine_calls()
    params:read(path, true)
    assert_equal(#context.calls_named("voiceOff"), 0)
    assert_equal(S.lib.notes.held(2), 1, "duplicate read keeps the new key")
    assert_near(mpe.values(8).bend, full_up(12), 1e-9, "duplicate read keeps expression")
  end)
end

test("a silent read migrates a missing split range and releases its old owner (#1107)", function()
  local context, S = setup(4)
  params:set("midi_note_off", 2)
  params:set("v1_zone_low", 65)
  local path = context.data_dir .. "old-zones.pset"
  params:write(path)
  h.write_text(path, (h.file_text(path):gsub('"v1_zone_low": [^\n]+\n', "")))
  key(context, "note_on", 2, 70)
  params:read(path, true)
  assert_equal(params:get("v1_zone_low"), 0)
  assert_equal(S.lib.notes.held(1), 0, "range migration releases held key")
  key(context, "note_on", 2, 50)
  assert_equal(S.lib.notes.held(1), 1, "a key newly inside the range plays")
end)

test("silent reads resolve conflicting member counts and note ranges in the ordinary read order (#1107)", function()
  local context, S, mpe = setup(4)
  local path = context.data_dir .. "order.pset"
  local lower, upper = '"mpe_lower_members": 9\n', '"mpe_upper_members": 9\n'
  local low, high = '"v1_zone_low": 70\n', '"v1_zone_high": 50\n'
  for _, case in ipairs({
    {lower .. upper .. lower .. low .. high .. low, 5, 9, 50, "upper"},
    {upper .. lower .. high .. low, 9, 5, 70, "lower"},
    {upper .. high .. low, 15, 0, 70, "lower"},  -- missing lower defaults last
    {"", 15, 0, nil, "lower"},                   -- before MPE params
  }) do
    h.write_text(path, '"midi_channel_mode": 4\n' .. case[1])
    for _, silent in ipairs({false, true}) do
      params:set("mpe_lower_members", 7); params:set("mpe_upper_members", 7)
      params:set("v1_zone_low", 0); params:set("v1_zone_high", 127)
      params:read(path, silent)
      assert_equal(params:get("mpe_lower_members"), case[2], "lower members")
      assert_equal(params:get("mpe_upper_members"), case[3], "upper members")
      assert_equal(mpe.zone(9), case[5], "the routing of channel 9")
      assert_equal(params:get("v1_zone_low"), case[4] or 0, "low end")
      assert_equal(params:get("v1_zone_high"), case[4] or 127, "high end")
      local note = case[4] or 60
      key(context, "note_on", 2, note)
      assert_equal(S.lib.notes.held(1), 1, "the voice plays at its boundary")
      params:read(path, true)
      assert_equal(S.lib.notes.held(1), 1, "duplicate conflicting values resolve to the same layout")
      key(context, "note_off", 2, note)
      assert_equal(S.lib.params_setup.read_order("midi_channel_mode"), nil, "order is scoped to the read")
    end
  end
end)

test("a silent change to the zones keeps a plain-mode key (#1107)", function()
  local context, S = setup(1)
  params:set("midi_note_off", 2)
  local path = context.data_dir .. "plain-zones.pset"
  params:write(path)
  params:set("mpe_lower_members", 6)
  key(context, "note_on", 1, 60)
  params:read(path, true)
  assert_equal(S.lib.notes.held(1), 1)
  key(context, "note_off", 1, 60)
  assert_true(not S.voices[1].active)
end)

test("reset forgets every channel's values", function()
  local _, _, mpe = setup()
  mpe.control({type = "pitchbend", ch = 2, val = 16383}); mpe.control({type = "channel_pressure", ch = 2, val = 9})
  cc(mpe, 2, 74, 9); cc(mpe, 2, 87, 9)
  mpe.reset()
  local values = mpe.values(2)
  assert_equal(values.bend, 1); assert_equal(values.pressure, nil); assert_equal(values.slide, 0)
  mpe.control({type = "channel_pressure", ch = 2, val = 64})
  assert_near(mpe.values(2).pressure, 64 / 127, 1e-12, "the pending CC87 went too")
end)

test("the zone params: defaults, and a low never passes its high", function()
  local _ = setup()
  assert_equal(params:string("v1_zone"), "lower"); assert_equal(params:string("v2_zone"), "upper")
  for voice = 3, local_value("S").constants.NUM_VOICES do assert_equal(params:string("v" .. voice .. "_zone"), "off") end
  for voice = 1, local_value("S").constants.NUM_VOICES do
    assert_equal(params:get("v" .. voice .. "_zone_low"), 0); assert_equal(params:get("v" .. voice .. "_zone_high"), 127)
  end
  params:set("v1_zone_high", 40); params:set("v1_zone_low", 60)
  assert_equal(params:get("v1_zone_high"), 60, "the low pushes the high up")
  params:set("v1_zone_high", 30)
  assert_equal(params:get("v1_zone_low"), 30, "the high pulls the low down")
  assert_equal(params:get("v1_zone_high"), 30)
end)

test("the groups' sizes match their params", function()
  local _ = setup()
  local group_size = {}
  for _, param in ipairs(params.params) do
    if param.t == params.tGROUP then group_size[param.id] = param.n end
  end
  assert_equal(group_size.strata_midi, 6); assert_equal(group_size.strata_zones, 21)
end)

end
