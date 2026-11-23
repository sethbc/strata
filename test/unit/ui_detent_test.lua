-- test/unit/ui_detent_test.lua
-- Center detents and fine adjustment (lib/ui/detent.lua): delta_with_detent
-- from encoders and arc rings, enc_param_delta's ALT+E3 fine mode, the
-- param helpers param_spans_zero and param_default (lib/ui/params.lua), the
-- stub's get_raw/set_raw, and the pages and rings routed through them
-- Run alone: lua test/run.lua ui_detent

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup = h.load_strata, h.local_value, h.finish_startup
local show_page, repo_root = h.show_page, h.repo_root

test("the detent and fine constants", function()
  load_strata()
  local constants = local_value("S").constants
  assert_equal(constants.DETENT.encoder_detents, 3, "DETENT.encoder_detents")
  assert_equal(constants.DETENT.arc_ticks, 24, "DETENT.arc_ticks")
  assert_equal(constants.FINE_DIVISOR, 10, "FINE_DIVISOR")
  assert_equal(constants.DETENT.hold_seconds, 1, "DETENT.hold_seconds")
end)

test("a delta landing on zero holds for three detents", function()
  load_strata()
  params:set("v1_pan", -0.02); delta_with_detent("v1_pan", 1); assert_equal(params:get("v1_pan"), 0, "lands on 0")
  for _ = 1, 3 do delta_with_detent("v1_pan", 1) end
  assert_equal(params:get("v1_pan"), 0, "held for three detents")
  delta_with_detent("v1_pan", 1); assert_near(params:get("v1_pan"), 0.02, 1e-9, "the fourth detent moves on")
end)

test("an accelerated delta across zero lands on zero", function()
  load_strata()
  params:set("v1_pan", -0.04); delta_with_detent("v1_pan", 5)
  assert_equal(params:get("v1_pan"), 0, "a fast turn from -0.04 by 5 detents stops at 0")
  -- the hold has started: three more detents stay at 0
  delta_with_detent("v1_pan", 2); delta_with_detent("v1_pan", 1)
  assert_equal(params:get("v1_pan"), 0, "the hold counts |d|")
  delta_with_detent("v1_pan", 1); assert_near(params:get("v1_pan"), 0.02, 1e-9, "past the hold")
  -- and downward across zero
  params:set("v1_pan", 0.06); delta_with_detent("v1_pan", -4)
  assert_equal(params:get("v1_pan"), 0, "a fast turn down from 0.06 stops at 0")
  -- an accelerated delta that uses up the hold moves on in that same turn
  delta_with_detent("v1_pan", -5); assert_near(params:get("v1_pan"), -0.1, 1e-9, "a delta past the hold applies")
end)

test("arc turns hold at zero for 24 ticks", function()
  load_strata()
  params:set("v1_pan", -0.02); arc_sweep_param("v1_pan", 10); assert_equal(params:get("v1_pan"), 0, "lands on 0")
  arc_sweep_param("v1_pan", 12); arc_sweep_param("v1_pan", 12); assert_equal(params:get("v1_pan"), 0, "24 ticks held")
  arc_sweep_param("v1_pan", 6); assert_true(params:get("v1_pan") > 0, "the 25th tick on moves")
end)

test("arc ticks move the raw value by ticks / ARC_TICKS_PER_SWEEP", function()
  load_strata()
  local sweep = local_value("UI_PAGES").ARC_TICKS_PER_SWEEP
  local r0 = params:get_raw("filter_res"); arc_sweep_param("filter_res", 64)
  assert_near(params:get_raw("filter_res") - r0, 64 / sweep, 1e-9, "64 ticks")
  -- an exp param sweeps its raw value evenly too
  r0 = params:get_raw("filter_freq"); arc_sweep_param("filter_freq", -32)
  assert_near(params:get_raw("filter_freq") - r0, -32 / sweep, 1e-9, "-32 ticks on an exp param")
end)

test("a hold ends when something else moves the value", function()
  load_strata()
  params:set("v1_pan", -0.02); delta_with_detent("v1_pan", 1); assert_equal(params:get("v1_pan"), 0, "lands on 0")
  params:set("v1_pan", 0.1)
  delta_with_detent("v1_pan", 1); assert_near(params:get("v1_pan"), 0.12, 1e-9, "no hold once moved away")
end)

test("a hold swallows detents only within DETENT.hold_seconds", function()
  local context = load_strata()
  context.set_time(100)
  params:set("v1_pan", -0.02); delta_with_detent("v1_pan", 1); assert_equal(params:get("v1_pan"), 0, "lands on 0")
  context.set_time(100.9)
  delta_with_detent("v1_pan", 1); assert_equal(params:get("v1_pan"), 0, "within the window the hold swallows a detent")
  context.set_time(101.1)
  delta_with_detent("v1_pan", 1); assert_near(params:get("v1_pan"), 0.02, 1e-9, "an expired hold swallows nothing")
end)

test("a stale hold never swallows a later detent", function()
  local context = load_strata()
  context.set_time(100)
  params:set("v1_pan", -0.02); delta_with_detent("v1_pan", 1); assert_equal(params:get("v1_pan"), 0, "lands on 0")
  -- something else (two scene recalls) moves it away and back to 0
  params:set("v1_pan", 0.5); params:set("v1_pan", 0)
  context.set_time(160)
  delta_with_detent("v1_pan", 1); assert_near(params:get("v1_pan"), 0.02, 1e-9, "a minute later the detent moves")
end)

test("holds are kept per param", function()
  load_strata()
  params:set("v1_pan", -0.02); delta_with_detent("v1_pan", 1)
  params:set("v2_pan", -0.02); delta_with_detent("v2_pan", 1)
  for _ = 1, 4 do delta_with_detent("v1_pan", 1) end
  assert_near(params:get("v1_pan"), 0.02, 1e-9, "v1's hold is used up")
  delta_with_detent("v2_pan", 1); assert_equal(params:get("v2_pan"), 0, "v2 is still held")
end)

test("a hold started on the arc and continued on an encoder lasts as long", function()
  load_strata()
  -- 24 arc ticks are worth 3 detents: 12 ticks used leave one and a half
  params:set("v1_pan", -0.02); arc_sweep_param("v1_pan", 10); arc_sweep_param("v1_pan", 12)
  delta_with_detent("v1_pan", 1); assert_equal(params:get("v1_pan"), 0, "half a hold left after one detent")
  delta_with_detent("v1_pan", 1); assert_near(params:get("v1_pan"), 0.02, 1e-9, "used up after two")
end)

test("ALT+E3 moves a control param a tenth of its raw step", function()
  load_strata()
  local r0 = params:get_raw("filter_freq"); enc_param_delta(3, "filter_freq", 1)
  assert_near(params:get_raw("filter_freq") - r0, 0.01, 1e-9, "E3 alone: a whole raw step")
  key(1, 1); local r1 = params:get_raw("filter_freq"); enc_param_delta(3, "filter_freq", 1)
  assert_near(params:get_raw("filter_freq") - r1, 0.001, 1e-9, "ALT+E3: a tenth")
  key(1, 0)
end)

test("ALT+E2 is never fine", function()
  load_strata()
  key(1, 1); local r0 = params:get_raw("mutation_rate"); enc_param_delta(2, "mutation_rate", 1)
  assert_near(params:get_raw("mutation_rate") - r0, 0.01, 1e-9, "ALT+E2: a whole raw step")
  key(1, 0)
end)

test("fine adjustment leaves number and option params in whole steps", function()
  load_strata()
  key(1, 1); params:set("v1_grain_mode", 1); enc_param_delta(3, "v1_grain_mode", 1)
  assert_equal(params:get("v1_grain_mode"), 2, "an option param steps whole options")
  params:set("midi_device", 1); enc_param_delta(3, "midi_device", 1)
  assert_equal(params:get("midi_device"), 2, "a number param steps whole numbers")
  key(1, 0)
end)

test("a fine turn across zero still lands on zero", function()
  load_strata()
  key(1, 1)
  -- pan: step 0.01, a raw step of 0.01 is 0.02 of pan, so a fine detent
  -- moves 0.002 (read back rounded to the step)
  params:set("v1_pan", -0.01)
  enc_param_delta(3, "v1_pan", 1); enc_param_delta(3, "v1_pan", 1)
  assert_near(params:get("v1_pan"), -0.01, 1e-9, "two fine detents still read -0.01 (rounded to the step)")
  enc_param_delta(3, "v1_pan", 1)
  assert_equal(params:get("v1_pan"), 0, "the third reaches 0")
  assert_equal(params:get_raw("v1_pan"), 0.5, "and sets exactly 0")
  for _ = 1, 3 do enc_param_delta(3, "v1_pan", 1) end
  assert_equal(params:get_raw("v1_pan"), 0.5, "held for three fine detents")
  enc_param_delta(3, "v1_pan", 1)
  assert_near(params:get_raw("v1_pan"), 0.501, 1e-9, "then moves on a tenth of a raw step")
  key(1, 0)
end)

test("params that do not span zero have no detent", function()
  load_strata()
  params:set("filter_res", 0.02); delta_with_detent("filter_res", -2); assert_equal(params:get("filter_res"), 0, "to 0")
  delta_with_detent("filter_res", 1); assert_near(params:get("filter_res"), 0.01, 1e-9, "on at once")
end)

test("a number param through zero holds too", function()
  load_strata()
  params:add_number("detent_test_number", "detent test", -5, 5, 0)
  params:set("detent_test_number", -2); delta_with_detent("detent_test_number", 3)
  assert_equal(params:get("detent_test_number"), 0, "a number param crossing 0 lands on it")
  for _ = 1, 3 do delta_with_detent("detent_test_number", 1) end
  assert_equal(params:get("detent_test_number"), 0, "held for three detents")
  delta_with_detent("detent_test_number", 1); assert_equal(params:get("detent_test_number"), 1, "then moves")
end)

test("param_spans_zero and param_default", function()
  load_strata()
  assert_true(param_spans_zero("v1_pan"), "pan spans 0")
  assert_true(param_spans_zero("v1_mod_amp_amt_1"), "a crossmod amount spans 0")
  assert_true(not param_spans_zero("filter_res"), "resonance starts at 0")
  assert_true(not param_spans_zero("v1_grain_mode"), "an option param never does")
  assert_true(not param_spans_zero("midi_device"), "the MIDI port (1-4) does not")
  assert_equal(param_default("filter_freq"), 5000, "a control param's controlspec default")
  assert_equal(param_default("midi_device"), 1, "a number param's default")
  assert_equal(param_default("v1_source"), local_value("S").voices[1].source, "an option param's default")
  params:set("filter_freq", 300)
  assert_equal(param_default("filter_freq"), 5000, "the default, not the value")
end)

test("the stub's set_raw keeps the raw value unrounded like norns", function()
  local context = load_strata()
  -- lua/core/params/control.lua: set_raw clamps to 0-1 and stores the raw
  -- value as given; get maps it and rounds to the controlspec step
  params:set_raw("filter_res", 0.123456)
  assert_equal(params:get_raw("filter_res"), 0.123456, "the raw value is kept unrounded")
  assert_near(params:get("filter_res"), 0.12, 1e-9, "get rounds to the step (0.01)")
  params:set_raw("filter_res", 1.5); assert_equal(params:get_raw("filter_res"), 1, "clamped to 1")
  params:set_raw("filter_res", -0.5); assert_equal(params:get_raw("filter_res"), 0, "clamped to 0")
  -- the action fires on a change only, and never when silent
  local fired = 0
  params:set_action("filter_res", function() fired = fired + 1 end)
  params:set_raw("filter_res", 0.5); assert_equal(fired, 1, "a change fires the action")
  params:set_raw("filter_res", 0.5); assert_equal(fired, 1, "no change, no action")
  params:set_raw("filter_res", 0.6, true); assert_equal(fired, 1, "silent")
  assert_equal(params:get_raw("filter_res"), 0.6, "a silent set_raw still stores the value")
  local ok = pcall(params.get_raw, params, "midi_device")
  assert_true(not ok, "get_raw is for control params only")
  ok = pcall(params.set_raw, params, "midi_device", 0.5)
  assert_true(not ok, "set_raw is for control params only")
  assert_true(context ~= nil, "loaded")
end)

test("arc rings go through the sweep", function()
  local context = load_strata(); finish_startup(context)
  context.arc.plug(1)
  show_page("FX")
  -- FX ring 2 is the filter resonance
  local r0 = params:get_raw("filter_res")
  context.arc.turn(1, 2, 32)
  assert_near(params:get_raw("filter_res") - r0, 32 / local_value("UI_PAGES").ARC_TICKS_PER_SWEEP, 1e-9, "a ring moves the raw value ticks / ARC_TICKS_PER_SWEEP")
end)

test("no page or ring calls params:delta", function()
  -- every encoder and ring change goes through enc_param_delta or
  -- delta_with_detent (lib/ui/detent.lua), the one place that calls it
  local offenders = {}
  for _, dir in ipairs({ "lib/pages", "lib/arc" }) do
    local pipe = assert(io.popen("ls '" .. repo_root .. "/" .. dir .. "'"))
    for name in pipe:lines() do
      if name:match("%.lua$") then
        local file = assert(io.open(repo_root .. "/" .. dir .. "/" .. name))
        local text = file:read("*a"); file:close()
        for line in text:gmatch("[^\n]*") do
          local code = line:gsub("%-%-.*$", "")
          if code:find("params:delta", 1, true) then table.insert(offenders, dir .. "/" .. name .. ": " .. line) end
        end
      end
    end
    pipe:close()
  end
  assert_equal(#offenders, 0, table.concat(offenders, "; "))
end)

-- The UI core's call rules (AGENTS.md, UI), over strata.lua and every lib/
-- file with comments and strings blanked: only the frame clock calls
-- redraw() and arc_redraw(), S.ui_page is set only where it starts
-- (lib/ui/frame.lua) and by set_ui_page (lib/ui/keys.lua), alt_key runs
-- only through alt_action (lib/ui/alt.lua), and only redraw() and the
-- header draw the hint row (#427)
test("only the UI core redraws, sets the page, runs alt_key and draws the hint row (#427)", function()
  -- `field`: a call through another table (fileselect.redraw(), a page
  -- record's arc_redraw(port)) is another function, not the rule's
  local RULES = {
    { name = "a redraw() call", pattern = "()%f[%w_]redraw%s*%(", field = true,
      allowed = { ["lib/ui/frame.lua"] = true } },
    { name = "an arc_redraw() call", pattern = "()%f[%w_]arc_redraw%s*%(", field = true,
      allowed = { ["lib/ui/frame.lua"] = true } },
    { name = "an assignment to ui_page", pattern = "()%f[%w_]ui_page%s*=[^=]",
      allowed = { ["lib/ui/frame.lua"] = true, ["lib/ui/keys.lua"] = true } },
    { name = "an alt_key call", pattern = "()[%.:]alt_key%s*%(", allowed = { ["lib/ui/alt.lua"] = true } },
    { name = "a draw_hints call", pattern = "()%f[%w_]draw_hints%s*%(",
      allowed = { ["strata.lua"] = true, ["lib/ui/header.lua"] = true } },
  }
  local offenders, scanned = {}, 0
  for _, source in ipairs(h.read_lua_sources()) do
    scanned = scanned + 1
    local sanitized = h.sync_check.sanitize_lua(source.text)
    for _, rule in ipairs(RULES) do
      if not rule.allowed[source.path] then
        for start in sanitized:gmatch(rule.pattern) do
          local before = sanitized:sub(math.max(1, start - 60), start - 1)
          -- a definition (function redraw(), function record.alt_key(n)) is no call
          local definition = before:match("function%s+[%w_.:]*$")
          local through_field = rule.field and before:match("[%.:]%s*$")
          if not definition and not through_field then
            local line = select(2, sanitized:sub(1, start - 1):gsub("\n", "")) + 1
            table.insert(offenders, source.path .. ":" .. line .. ": " .. rule.name)
          end
        end
      end
    end
  end
  assert_true(scanned > 50, "scanned strata.lua and every lib/ file (" .. scanned .. ")")
  assert_equal(#offenders, 0, table.concat(offenders, "; "))
end)

-- 3.4's touch hooks (S.register_param_touch): a user edit of a param, after
-- it sets the param, tells the hooks its id and where it came from
local function touch_log()
  local log = {}
  local_value("S").register_param_touch(function(param_id, source) log[#log + 1] = param_id .. ":" .. source end)
  return log
end

test("an encoder edit runs the touch hooks once; a detent the hold swallows runs none", function()
  local context = load_strata(); finish_startup(context)
  local log = touch_log()
  enc_param_delta(3, "reverb_mix", 1)
  assert_equal(table.concat(log, " "), "reverb_mix:enc", "one touch, from the encoder")
  delta_with_detent("reverb_mix", 1, {fine = true})
  assert_equal(table.concat(log, " "), "reverb_mix:enc reverb_mix:enc", "a fine turn is an encoder's too")
  for index in pairs(log) do log[index] = nil end
  params:set("v1_pan", 0.02)
  enc_param_delta(3, "v1_pan", -5)
  assert_equal(params:get("v1_pan"), 0, "the turn stops at 0")
  assert_equal(table.concat(log, " "), "v1_pan:enc", "the stop at 0 set the param: one touch")
  enc_param_delta(3, "v1_pan", -1)
  assert_equal(params:get("v1_pan"), 0, "the hold swallows the next detent")
  assert_equal(table.concat(log, " "), "v1_pan:enc", "and runs no hook")
  params:set("reverb_mix", 0.4)
  assert_equal(#log, 1, "a plain set is no touch")
end)

-- #875: in the running script S.selected_voice changes only in
-- select_voice_by (lib/ui/keys.lua). The other assignments are its
-- initialization (lib/voices.lua's constructor) and the setups of the
-- layout states of a page record or a voice-param record, which the layout
-- tests and the page renders run, never the device. Each site by file and
-- its enclosing functions, outside in: "constructor" is a module's
-- `return function(S)`, "function" one with no name; a named one is the last
-- part of its name, or the field it is assigned to (`setup = function`).
-- Each site holds exactly the number of assignments given, so a further
-- setup or a second assignment in a listed function fails until it is
-- listed. A source scan cannot follow an alias of S (`local state = S`)
local SELECTED_VOICE_SITES = {
  ["lib/ui/keys.lua"] = {["constructor > select_voice_by"] = 1},
  ["lib/voices.lua"] = {["constructor"] = 1},
  ["lib/arp.lua"] = {["constructor > setup"] = 1},
  ["lib/expression.lua"] = {["constructor > setup"] = 1},
  ["lib/freeze.lua"] = {["constructor > setup"] = 1},
  ["lib/grain.lua"] = {["constructor > setup"] = 1},
  ["lib/history.lua"] = {["constructor > setup"] = 2},
  ["lib/loops.lua"] = {["constructor > setup"] = 1},
  ["lib/notes.lua"] = {["constructor > add_layout_state > setup"] = 1},
  ["lib/positions.lua"] = {["constructor > setup"] = 1},
  ["lib/scan.lua"] = {["constructor > setup"] = 1},
  ["lib/slices.lua"] = {["constructor > setup"] = 1},
  ["lib/variation.lua"] = {["constructor > setup"] = 1},
  ["lib/voice_mix.lua"] = {["constructor > layout_state > setup"] = 1},
  ["lib/pages/main.lua"] = {["constructor > layout_state > setup"] = 1, ["constructor > setup"] = 1},
  ["lib/pages/voice.lua"] = {["constructor > layout_state > setup"] = 1, ["constructor > setup"] = 4,
    ["constructor > open_picker"] = 1, ["constructor > type_pending_state > setup"] = 1},
}

-- Every assignment of S.selected_voice in one source, as the names of the
-- functions it sits in (SELECTED_VOICE_SITES' form), in source order. The
-- code is read with comments and strings blanked (sync_check's
-- sanitize_lua), its blocks counted by keyword: function, do, if and repeat
-- open one, end and until close it
local function selected_voice_assignments(text)
  local code = h.sync_check.sanitize_lua(text)
  local events = {}
  for at, word in code:gmatch("()%f[%w_]([%a_][%w_]*)") do
    if word == "function" or word == "do" or word == "if" or word == "repeat" or word == "end" or word == "until" then
      table.insert(events, {at = at, word = word})
    end
  end
  -- `S.selected_voice = x`, `a, S.selected_voice = ...` and, with more
  -- targets after it on its line, `S.selected_voice, a = ...` (never `==`).
  -- A value after `{`, `(` or `=` is a read (`{S.selected_voice, key = 1}`,
  -- `local a = S.selected_voice, b`), never the first of a target list
  for index, pattern in ipairs({"()S%.selected_voice%s*=()", "()S%.selected_voice%s*,[%w_%.%[%] \t,]-=()"}) do
    for at, after in code:gmatch(pattern) do
      local before = code:sub(1, at - 1):match("(%S)%s*$")
      local read = index == 2 and (before == "{" or before == "(" or before == "=")
      if code:sub(after, after) ~= "=" and not read then table.insert(events, {at = at, assignment = true}) end
    end
  end
  table.sort(events, function(a, b) return a.at < b.at end)
  local blocks, found = {}, {}
  for _, event in ipairs(events) do
    if event.assignment then
      local names = {}
      for _, block in ipairs(blocks) do
        if block ~= true then table.insert(names, block) end
      end
      table.insert(found, #names > 0 and table.concat(names, " > ") or "main chunk")
    elseif event.word == "function" then
      local own = code:match("^function%s+([%w_%.:]+)%s*%(", event.at)
      local before = code:sub(math.max(1, event.at - 80), event.at - 1)
      local name = own and own:match("([%w_]+)$") or before:match("([%w_]+)%s*=%s*$")
        or (before:match("%f[%w_]return%s*$") and "constructor") or "function"
      table.insert(blocks, name)
    elseif event.word == "end" or event.word == "until" then
      table.remove(blocks)
    else
      table.insert(blocks, true)
    end
  end
  return found
end

test("S.selected_voice is assigned only by select_voice_by, at init and in layout states", function()
  local problems, scanned = {}, {}
  for _, source in ipairs(h.read_lua_sources()) do
    scanned[source.path] = true
    local allowed, counts = SELECTED_VOICE_SITES[source.path] or {}, {}
    for _, site in ipairs(selected_voice_assignments(source.text)) do
      if allowed[site] then counts[site] = (counts[site] or 0) + 1
      else table.insert(problems, source.path .. ": S.selected_voice assigned in " .. site) end
    end
    for site, count in pairs(allowed) do
      local found = counts[site] or 0
      if found == 0 then
        table.insert(problems, source.path .. ": no assignment left in " .. site .. " (remove it from the list)")
      elseif found ~= count then
        table.insert(problems, string.format("%s: %d assignments in %s, the list gives %d",
          source.path, found, site, count))
      end
    end
    if source.text:find("S%[%s*[\"']selected_voice[\"']%s*%]%s*=[^=]") or source.text:find("rawset%(%s*S%s*,%s*[\"']selected_voice") then
      table.insert(problems, source.path .. ": S.selected_voice assigned by its key")
    end
  end
  for path in pairs(SELECTED_VOICE_SITES) do
    if not scanned[path] then table.insert(problems, path .. " is listed but is no source (remove it from the list)") end
  end
  table.sort(problems)
  assert_true(#problems == 0, "S.selected_voice outside its allowed sites:\n" .. table.concat(problems, "\n"))
end)

test("the selected voice scan finds an assignment's functions and skips comments, strings and comparisons", function()
  local found = selected_voice_assignments(table.concat({
    "return function(S)",
    "  local M = {}",
    "  -- S.selected_voice = 2 (a comment)",
    "  local text = \"S.selected_voice = 3\"",
    "  if S.selected_voice == 1 then end",
    "  S.selected_voice = 1",
    "  S.selected_voice, other = 5, 6",
    "  other, S.selected_voice = 5, 6",
    "  f(S.selected_voice, x == 1)",
    "  local t = {S.selected_voice, key = 1}",
    "  g({ S.selected_voice, name = 1 })",
    "  local a, b = S.selected_voice, c  d = 1",
    "  for i = 1, 2 do",
    "    table.insert(states, {name = 'x', setup = function() S.selected_voice = i end})",
    "  end",
    "  local function pick(d)",
    "    if d then S.selected_voice = d end",
    "    clock.run(function() S.selected_voice = 4 end)",
    "  end",
    "  function M.select(d) repeat S.selected_voice = d until true end",
    "  return M",
    "end",
  }, "\n"))
  assert_equal(table.concat(found, "; "),
    "constructor; constructor; constructor; constructor > setup; constructor > pick; constructor > pick > function; constructor > select",
    "the sites")
end)

end
