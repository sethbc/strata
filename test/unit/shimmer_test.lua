-- test/unit/shimmer_test.lua
-- Shimmer's params (lib/shimmer.lua, S.lib.shimmer, 3.8 design §7.4): an
-- interval of five pure ratios (an octave at first) and two amounts at 0
-- in the fx group, each sending setShimmer with the other two as the
-- engine has them; scene globals (the interval switches at a fade's end,
-- the amounts crossfade), LFO global destinations for the amounts, kept
-- through a bypass (which sends no setShimmer); and every node of the
-- three effect defs the engine and the engine check start passing its
-- shimmer rings (shiftL, shiftR: a ring left out is buffer 0)
-- Run alone: lua test/run.lua shimmer

return function(h)
local test, assert_true, assert_equal, assert_near = h.test, h.assert_true, h.assert_equal, h.assert_near
local load_strata, local_value, finish_startup, wake = h.load_strata, h.local_value, h.finish_startup, h.wake

local function loaded()
  local context = load_strata(); finish_startup(context)
  local S = local_value("S")
  return context, S, S.lib.shimmer
end

local IDS = {"shimmer_interval", "shimmer_delay", "shimmer_reverb"}

local function last_shimmer(context)
  local calls = context.calls_named("setShimmer")
  return calls[#calls] and calls[#calls].args
end

local function global_entry(S, id)
  for _, entry in ipairs(S.SCENE_GLOBAL_PARAMS) do if entry.id == id then return entry end end
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, entry in pairs(value) do copy[key] = deep_copy(entry) end
  return copy
end

test("shimmer's three params: an interval of five ratios, octave at first, and two amounts at 0", function()
  local context, S, shimmer = loaded()
  assert_equal(table.concat(shimmer.SHIMMER.ratios, " "), "0.5 1.5 2 3 4", "five pure ratios")
  assert_equal(table.concat(shimmer.SHIMMER.names, ","), "oct down,fifth,octave,oct+5th,2 oct", "their names")
  assert_equal(shimmer.SHIMMER.default_interval, 3)
  local interval = params:lookup_param("shimmer_interval")
  assert_true(interval ~= nil and interval.t == params.tOPTION, "shimmer_interval is an option")
  assert_equal(table.concat(interval.options, ","), table.concat(shimmer.SHIMMER.names, ","))
  assert_equal(params:get("shimmer_interval"), 3, "an octave at first")
  assert_equal(shimmer.ratio(), 2, "whose ratio is 2")
  for _, id in ipairs({"shimmer_delay", "shimmer_reverb"}) do
    local param = params:lookup_param(id)
    assert_true(param ~= nil and param.t == params.tCONTROL, id .. " is a control")
    local spec = param.controlspec
    assert_equal(spec.minval, 0); assert_equal(spec.maxval, 1); assert_equal(spec.warp_name, "lin")
    assert_near(spec.step, 0.01, 1e-9); assert_equal(params:get(id), 0, id .. " at 0")
    assert_equal(params:string(id), "0 %", id .. " shown in percent")
  end
  -- the last three of the fx group, in their order (the fx record "shimmer", three params)
  local group = params.lookup["strata_fx"]
  local last = group + params:get("strata_fx")
  for offset, id in ipairs(IDS) do
    assert_equal(params.params[last - 3 + offset].id, id, id .. " in its place at the fx group's end")
  end
  local record
  for _, each in ipairs(S.registry.fx_params) do if each.name == "shimmer" then record = each end end
  assert_true(record ~= nil and record.count == 3, "the fx record shimmer, three params")
  -- a default send: what the engine starts with (the defs' shimmer 0, ratio 2)
  context.clear_engine_calls()
  send_param_to_engine("shimmer_delay", params:get("shimmer_delay"))
  local args = last_shimmer(context)
  assert_true(args ~= nil and args[1] == 0 and args[2] == 0 and args[3] == 2, "setShimmer(0, 0, 2) from a default send")
  local defaults = h.engine_spec.synthdef_defaults
  assert_equal(defaults.strataDelay.shimmer, 0); assert_equal(defaults.strataDelay.shimmerRatio, 2)
  assert_equal(defaults.strataReverb.shimmer, 0); assert_equal(defaults.strataReverb.shimmerRatio, 2)
  assert_equal(defaults.strataReverbFDN.shimmer, 0); assert_equal(defaults.strataReverbFDN.shimmerRatio, 2)
end)

test("each param sends setShimmer with the other two as the engine has them", function()
  local context = loaded()
  context.clear_engine_calls()
  params:set("shimmer_interval", 1)
  local args = last_shimmer(context)
  assert_true(args ~= nil, "the interval sends setShimmer")
  assert_equal(args[3], 0.5, "interval 1 is an octave down")
  assert_equal(args[1], 0); assert_equal(args[2], 0)
  params:set("shimmer_reverb", 0.4)
  args = last_shimmer(context)
  assert_near(args[2], 0.4, 1e-9, "the reverb's amount second"); assert_equal(args[3], 0.5, "the interval kept")
  params:set("shimmer_delay", 0.7)
  args = last_shimmer(context)
  assert_near(args[1], 0.7, 1e-9, "the delay's amount first"); assert_near(args[2], 0.4, 1e-9)
  params:set("shimmer_interval", 5)
  args = last_shimmer(context)
  assert_equal(args[3], 4, "two octaves"); assert_near(args[1], 0.7, 1e-9); assert_near(args[2], 0.4, 1e-9)
  -- an LFO's offset on an amount reaches the engine with the others as they are
  local S = local_value("S")
  S.lib.engine_sync.set_extra_offset("probe", "shimmer_reverb", 0.1)
  send_param_to_engine("shimmer_reverb", params:get("shimmer_reverb"))
  args = last_shimmer(context)
  assert_near(args[2], 0.5, 1e-6, "the engine's value of the reverb's amount, its offset in it")
  assert_near(args[1], 0.7, 1e-9, "the delay's amount as the engine has it")
  S.lib.engine_sync.set_extra_offset("probe", "shimmer_reverb", 0)
end)

test("each param's action notes the edit before it sends (a randomize draws them)", function()
  local context, S = loaded()
  local mutation = S.lib.mutation
  local FX = S.constants.UI_PAGES.index.FX
  for _, id in ipairs(IDS) do
    local value = id == "shimmer_interval" and 2 or 0.3
    mutation.randomize({page = FX, section = "probe", draws = {{id = id, draw = function() return value end}}})
    assert_true(mutation.undo_for(FX, "probe", nil), id .. ": the randomize holds an undo")
    params:set(id, id == "shimmer_interval" and 4 or 0.6)
    assert_equal(S.undo, nil, "an edit of " .. id .. " ends the undo")
  end
  -- the order (#838): each action notes its edit before its setShimmer
  -- goes, so the edit is noted however the send fares
  local real_note = note_param_edit
  local noted = {}
  note_param_edit = function(param_id)
    noted[#noted + 1] = {id = param_id, sends = #context.calls_named("setShimmer")}
    return real_note(param_id)
  end
  local ok, failure = pcall(function()
    for _, id in ipairs(IDS) do
      for index in pairs(noted) do noted[index] = nil end
      context.clear_engine_calls()
      params:set(id, id == "shimmer_interval" and 1 or 0.9)
      assert_equal(#context.calls_named("setShimmer"), 1, id .. ": one setShimmer")
      assert_true(#noted == 1 and noted[1].id == id, id .. ": its edit is noted once, by its own id")
      assert_equal(noted[1].sends, 0, id .. ": the edit is noted before the setShimmer")
    end
  end)
  note_param_edit = real_note
  assert_true(ok, tostring(failure))
end)

test("shimmer's params are scene globals; the interval switches at a fade's end", function()
  local context, S = loaded()
  assert_true(global_entry(S, "shimmer_interval") ~= nil and not global_entry(S, "shimmer_interval").continuous
    and global_entry(S, "shimmer_interval").default == 3, "the interval: a discrete global, default 3")
  for _, id in ipairs({"shimmer_delay", "shimmer_reverb"}) do
    local entry = global_entry(S, id)
    assert_true(entry ~= nil and entry.continuous and entry.default == 0, id .. ": a continuous global, default 0")
  end
  params:set("shimmer_interval", 4); params:set("shimmer_delay", 0.8); params:set("shimmer_reverb", 0.6)
  capture_scene(1)
  local data = S.scenes[1].data
  assert_equal(data.shimmer_interval, 4); assert_near(data.shimmer_delay, 0.8, 1e-9); assert_near(data.shimmer_reverb, 0.6, 1e-9)
  params:set("shimmer_interval", 2); params:set("shimmer_delay", 0); params:set("shimmer_reverb", 0)
  recall_scene(1, 4); wake(context, "scene_transition_clock")
  context.clear_engine_calls()
  context.clock.run_for(2)
  local delay, reverb = params:get("shimmer_delay"), params:get("shimmer_reverb")
  assert_true(delay > 0 and delay < 0.8, "the delay's amount crossfades (got " .. delay .. ")")
  assert_true(reverb > 0 and reverb < 0.6, "the reverb's amount crossfades (got " .. reverb .. ")")
  assert_equal(params:get("shimmer_interval"), 2, "the interval holds until the fade's end")
  local args = last_shimmer(context)
  assert_true(args ~= nil and args[1] > 0 and args[1] < 0.8 and args[2] > 0 and args[2] < 0.6 and args[3] == 1.5,
    "the engine gets each step of both amounts at the old interval")
  context.clock.run_for(3)
  assert_equal(params:get("shimmer_interval"), 4, "the interval switches at the fade's end")
  assert_near(params:get("shimmer_delay"), 0.8, 1e-6); assert_near(params:get("shimmer_reverb"), 0.6, 1e-6)
  args = last_shimmer(context)
  assert_equal(args[3], 3, "and the engine gets it")
  -- a scene without them gets their defaults; one outside their ranges is invalid
  local filled = deep_copy(S.scenes[1])
  for _, id in ipairs(IDS) do filled.data[id] = nil end
  fill_scene(filled)
  assert_equal(filled.data.shimmer_interval, 3); assert_equal(filled.data.shimmer_delay, 0); assert_equal(filled.data.shimmer_reverb, 0)
  assert_true(validate_scene(filled), "a filled scene is valid")
  for _, bad in ipairs({{"shimmer_interval", 6}, {"shimmer_interval", 2.5}, {"shimmer_delay", 1.5}, {"shimmer_reverb", -0.1}}) do
    local scene = deep_copy(S.scenes[1])
    scene.data[bad[1]] = bad[2]
    assert_true(not validate_scene(scene), bad[1] .. " " .. bad[2] .. " is invalid")
  end
end)

test("the amounts are LFO global destinations; a bypass sends no setShimmer", function()
  local context, S = loaded()
  local found = {}
  for _, destination in ipairs(S.LFO_DESTINATIONS) do
    if destination.group == "global" then found[destination.label] = destination.resolve() end
  end
  assert_equal(found["shim dly"], "shimmer_delay"); assert_equal(found["shim rev"], "shimmer_reverb")
  params:set("shimmer_delay", 0.5); params:set("shimmer_reverb", 0.5)
  context.clear_engine_calls()
  params:set("delay_bypass", 1); params:set("reverb_bypass", 1)
  params:set("delay_bypass", 0); params:set("reverb_bypass", 0)
  assert_equal(#context.calls_named("setShimmer"), 0, "a bypass and its lift send no setShimmer (the engine keeps it)")
  assert_true(#context.calls_named("setBypass") > 0, "the bypasses were sent")
end)

-- Every node of \strataDelay, \strataReverb and \strataReverbFDN that the
-- engine or the engine check starts passes its shimmer rings, as every
-- delay passes its line (bufL, bufR): scsynth reads a bufnum left at its
-- default 0, or a negative or too large one, as buffer 0 (GET_BUF), a real
-- buffer of another area, which the shifter's BufWr would write. A site is
-- every form that starts a node: Synth( and Synth.new( (the def first),
-- Synth.head, tail, before, after and replace (the def second),
-- Synth.basicNew (with the next newMsg's arguments) and an s_new
-- written out (its message list). A site that names one of the three defs
-- passes \shiftL and \shiftR (and \bufL and \bufR for \strataDelay, #807)
-- in its arguments, or in the list variable it passes, assigned earlier in
-- its file; a site whose def is a variable and whose arguments name a
-- reverb's \delayIn or a delay's \bufL with its \feedback does too
local function engine_check_sources()
  local files = {}
  for _, pattern in ipairs({"lib/engine/*.sc", "test/engine_check/*.scd", "test/*.scd"}) do
    local pipe = io.popen("ls " .. h.repo_root .. "/" .. pattern .. " 2>/dev/null")
    for path in pipe:lines() do table.insert(files, path) end
    pipe:close()
  end
  return files
end

local NODE_DEFS = {strataDelay = {"\\shiftL", "\\shiftR", "\\bufL", "\\bufR"}, strataReverb = {"\\shiftL", "\\shiftR"},
  strataReverbFDN = {"\\shiftL", "\\shiftR"}}

-- The top-level arguments of an argument text (commas outside brackets and strings)
local function split_arguments(text)
  local parts, depth, start, quote = {}, 0, 1, nil
  for index = 1, #text do
    local char = text:sub(index, index)
    if quote then
      if char == quote then quote = nil end
    elseif char == '"' or char == "'" then quote = char
    elseif char:match("[%(%[{]") then depth = depth + 1
    elseif char:match("[%)%]}]") then depth = depth - 1
    elseif char == "," and depth == 0 then
      parts[#parts + 1] = text:sub(start, index - 1); start = index + 1
    end
  end
  parts[#parts + 1] = text:sub(start)
  return parts
end

-- Every node a text starts: {at, def (an argument's text), args (the text the controls must be in)}
local function node_sites(source)
  local text = "\n" .. source
  local sites = {}
  local function add(at, def, args) sites[#sites + 1] = {at = at, def = def, args = args} end
  local position = 1
  while true do
    local start, open, method = text:find("[^%w_%.]Synth%.?(%a*)%(", position)
    if not start then break end
    local body = text:match("%b()", open)
    if body then
      local parts = split_arguments(body:sub(2, -2))
      if method == "" or method == "new" then
        add(start, parts[1], body)
      elseif method == "head" or method == "tail" or method == "before" or method == "after" or method == "replace" then
        add(start, parts[2] or "", body)
      elseif method == "basicNew" then
        -- its controls are newMsg's, the next call of it after the node's making
        local message = text:find("newMsg%(", open)
        add(start, parts[1], message and text:match("%b()", message + 6) or "")
      end
    end
    position = open + 1
  end
  position = 1
  while true do
    local start, finish = text:find("['\"\\]/?s_new['\"]?", position)
    if not start then break end
    local open
    for at = start, 1, -1 do
      local char = text:sub(at, at)
      if char == "[" or char == "(" then open = at; break end
    end
    local list = open and text:match("%b" .. (text:sub(open, open) == "[" and "[]" or "()"), open)
    if list then
      local parts = split_arguments(list:sub(2, -2))
      for index, part in ipairs(parts) do
        if part:find("s_new", 1, true) then add(start, parts[index + 1] or "", list); break end
      end
    end
    position = finish + 1
  end
  return sites
end

-- The problems of one source text (path for the messages) and how many
-- sites of the three defs it holds, the literal and the variable ones
local function node_site_problems(text, path)
  local problems, literal, indirect = {}, 0, 0
  for _, site in ipairs(node_sites(text)) do
    local def = site.def:match("^%s*\\([%w_]+)%s*$")
    local needed = def and NODE_DEFS[def]
    local variable_def = not def and site.def:match("^%s*[%a_][%w_]*%s*$")
    if variable_def and (site.args:find("\\delayIn", 1, true)
        or (site.args:find("\\bufL", 1, true) and site.args:find("\\feedback", 1, true))) then
      needed = {"\\shiftL", "\\shiftR"}
    end
    if needed then
      local function holds(body)
        for _, control in ipairs(needed) do
          if not body:find(control, 1, true) then return false end
        end
        return true
      end
      local passes = holds(site.args)
      local list = not passes and site.args:match("^%(%s*[^,]+,%s*([%a_][%w_]*)%s*,")
      if list then
        local assigned
        for found in text:sub(1, site.at):gmatch("[^%w_]" .. list .. "%s*=%s*()%[") do assigned = found end
        local body = assigned and text:match("%b[]", assigned)
        passes = body ~= nil and holds(body)
      end
      if def then literal = literal + 1 else indirect = indirect + 1 end
      if not passes then
        problems[#problems + 1] = path .. ": " .. site.args:sub(1, 70) .. "... lacks " .. table.concat(needed, ", ")
      end
    end
  end
  return problems, literal + indirect, literal, indirect
end

-- Each form that starts a node, written without the controls, is found
-- and fails; with them it passes (Synth(, Synth.new(, Synth.head, tail,
-- before, after and replace, Synth.basicNew with newMsg, an /s_new written
-- out); and a \strataDelay needs its line (bufL, bufR) too (#807)
test("the node sites' test sees every form that starts a node, and a delay's line", function()
  local forms = {
    'Synth(\\strataReverb, [\\in, a%s], g)',
    'Synth.new(\\strataReverbFDN, [\\in, a%s], g)',
    'Synth.head(g, \\strataReverb, [\\in, a%s])',
    'Synth.tail(g, \\strataReverb, [\\in, a%s])',
    'Synth.before(n, \\strataReverbFDN, [\\in, a%s])',
    'Synth.after(n, \\strataReverb, [\\in, a%s])',
    'Synth.replace(n, \\strataReverbFDN, [\\in, a%s])',
    'x = Synth.basicNew(\\strataReverb, s); s.sendMsg(*x.newMsg(g, [\\in, a%s]));',
    "s.sendMsg('/s_new', \\strataReverb, -1, 0, 1, \\in, a%s);",
    's.sendBundle(nil, [\\s_new, \\strataReverbFDN, -1, 0, 1, \\in, a%s]);',
    'Synth(\\strataDelay, [\\in, a, \\bufL, l, \\bufR, r%s], g)',
  }
  for _, form in ipairs(forms) do
    local without = form:format("")
    local with = form:format(", \\shiftL, x, \\shiftR, y")
    local missing, sites = node_site_problems(without, "probe")
    assert_true(sites == 1 and #missing == 1, "found and failed without the rings: " .. without .. " (" .. sites .. " sites)")
    missing, sites = node_site_problems(with, "probe")
    assert_true(sites == 1 and #missing == 0, "passes with them: " .. with .. " (" .. table.concat(missing, "; ") .. ")")
  end
  local missing = node_site_problems('Synth(\\strataDelay, [\\in, a, \\shiftL, x, \\shiftR, y], g)', "probe")
  assert_equal(#missing, 1, "a delay without its line fails")
end)

test("every node of the delay and reverb defs passes its shimmer rings (shiftL, shiftR), a delay its line", function()
  local problems, literal, indirect = {}, 0, 0
  for _, path in ipairs(engine_check_sources()) do
    local file = assert(io.open(path, "r")); local text = h.stubs.strip_sc_comments(file:read("*a")); file:close()
    local found, _, named, variable = node_site_problems(text, path:match("[^/]+/[^/]+$"))
    for _, problem in ipairs(found) do problems[#problems + 1] = problem end
    literal, indirect = literal + named, indirect + variable
  end
  assert_equal(#problems, 0, "sites without their buffers: " .. table.concat(problems, "; "))
  assert_true(literal >= 6, "the sites that name a def were found (" .. literal .. ")")
  assert_true(indirect >= 4, "and those whose def is a variable (" .. indirect .. ")")
end)

end
