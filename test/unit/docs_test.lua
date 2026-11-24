-- test/unit/docs_test.lua
-- The Lua <-> engine interface and the docs: sync_check, the engine source
-- parsers and the engine stub's limits, the shared constants and FX
-- defaults, the AGENTS.md command table, doc paths and CI
-- Run alone: lua test/run.lua docs

return function(h)
local test, repo_root, stubs, sync_check, engine_sources = h.test, h.repo_root, h.stubs, h.sync_check, h.engine_sources
local signatures, engine_polls, engine_spec = h.signatures, h.engine_polls, h.engine_spec
local data_root, fail, assert_true, assert_equal = h.data_root, h.fail, h.assert_true, h.assert_equal
local assert_near, load_strata, local_value = h.assert_near, h.load_strata, h.local_value
local maintained_docs, read_lua_sources = h.maintained_docs, h.read_lua_sources
local patched_script, doc_paths_missing = h.patched_script, h.doc_paths_missing

test("Lua engine calls and SC addCommand signatures are in sync (sync_check)", function()
  local ok, problems, summary = sync_check.run(repo_root)
  assert_true(ok, summary .. "\n" .. table.concat(problems, "\n"))
  -- the scanner itself: nested calls, strings and comments
  local calls = sync_check.lua_calls('engine.foo(a, f(b, c), "x,y)", {1, 2}) -- engine.bar(1)\nengine.baz()')
  assert_equal(#calls, 2, "comment ignored")
  assert_equal(calls[1].arg_count, 4, "nested commas ignored")
  assert_equal(calls[2].arg_count, 0, "empty call")
end)

test("sync_check fails on engine uses it cannot check: engine[...], references, the table as a value (#27)", function()
  local sample = table.concat({
    'local f = engine.voiceOn',          -- 1: a command passed by value
    'engine["voiceOff"](0)',             -- 2: a computed name
    'local e = engine',                  -- 3: the table itself
    'engine:voiceOff(0)',                -- 4: a method call
    'engine.loadBuffer "x.wav"',         -- 5: a call without parentheses
    'engine.name = "Strata"',            -- allowed: the engine to load
    'x = context.engine; s = "a" .. engine.name',  -- a field of another table; engine.name read
    'engine . retrigger (0, 1)',         -- a call, spaces and all
    'local engine_senders = {} -- engine.bad', 'y = "engine.bad"',
  }, "\n")
  local problems = sync_check.lua_reference_problems(sample)
  local lines = {}
  for _, entry in ipairs(problems) do table.insert(lines, entry.line) end
  assert_equal(table.concat(lines, " "), "1 2 3 4 5", "each unchecked use is reported, nothing else")
  assert_true(problems[1].text:find("engine.voiceOn", 1, true), "the report names the command")
  local calls = sync_check.lua_calls(sample)
  assert_equal(#calls, 1, "only engine.<name>(...) is a call")
  assert_equal(calls[1].name, "retrigger"); assert_equal(calls[1].arg_count, 2, "a spaced call is counted")
  -- the whole check fails when one of the script's files holds one
  local lua_sources = read_lua_sources()
  local sc_source = engine_sources()
  assert_true((sync_check.check_sources(lua_sources, sc_source)), "the script's files pass as they are")
  for _, patch in ipairs({ "local f = engine.voiceOn", 'engine["voiceOff"](0)', "local e = engine" }) do
    local patched = {}
    for index, source in ipairs(lua_sources) do
      patched[index] = { path = source.path, text = source.text .. (index == 1 and "\n" .. patch .. "\n" or "") }
    end
    local ok, found = sync_check.check_sources(patched, sc_source)
    assert_true(not ok, "the check fails on: " .. patch)
    assert_true(found[#found]:find("strata.lua:%d+ "), "with the line: " .. tostring(found[#found]))
  end
end)

test("sync_check accepts a table key or parameter named engine and #engine (#51)", function()
  local allowed = table.concat({
    'local t = { engine = 1 }',
    'local u = { a = 1, engine = { 2 }; [3] = 4 }',
    'local v = {',
    '  engine = "Strata",',
    '}',
    'local function f(engine) return 1 end',
    'local g = function(x, engine, ...) end',
    'function obj:method(a,engine) end',
    'local n = #engine',
  }, "\n")
  local problems = sync_check.lua_reference_problems(allowed)
  local reported = {}
  for _, entry in ipairs(problems) do table.insert(reported, entry.line .. ": " .. entry.text) end
  assert_equal(#problems, 0, "nothing to report, got:\n" .. table.concat(reported, "\n"))
  -- the global engine still fails in the same places
  local flagged = table.concat({
    'local t = { engine }',              -- 1: the table as a list item
    'f(engine)',                         -- 2: as an argument
    'local w = { k = engine }',          -- 3: as a key's value
    'if { engine == 1 } then end',       -- 4: compared, not a key
    'local e = (engine)',                -- 5: in parentheses
    'g(function() end, engine)',         -- 6: an argument after a function
    'functions.apply(engine)',           -- 7: calls whose names start with "function"
    'function_call(a, engine)',          -- 8
    'local x = functional(engine)',      -- 9
  }, "\n")
  local lines = {}
  for _, entry in ipairs(sync_check.lua_reference_problems(flagged)) do table.insert(lines, entry.line) end
  assert_equal(table.concat(lines, " "), "1 2 3 4 5 6 7 8 9", "each use of the table as a value is reported")
end)

test("sync check reports a bad engine call in a module file", function()
  local sc_source = engine_sources()
  local function problems_of(sources)
    local ok, problems = sync_check.check_sources(sources, sc_source)
    return ok, table.concat(problems, "\n")
  end
  local ok, report = problems_of({ { path = "strata.lua", text = "" }, { path = "lib/x.lua", text = "engine.nope(1)" } })
  assert_true(not ok, "an unknown command in a module fails the check")
  assert_true(report:find("lib/x.lua:1 engine.nope", 1, true), "the report names the module and line:\n" .. report)
  ok, report = problems_of({ { path = "strata.lua", text = "" }, { path = "lib/x.lua", text = "\n\nengine.voiceOff(1, 2)\nlocal e = engine" } })
  assert_true(report:find("lib/x.lua:3 engine.voiceOff passes 2 args", 1, true), "a wrong argument count:\n" .. report)
  assert_true(report:find("lib/x.lua:4 the engine table", 1, true), "an unchecked use:\n" .. report)
  -- every command is called somewhere: a call in any file counts
  local sources = read_lua_sources()
  assert_equal(sources[1].path, "strata.lua", "strata.lua comes first")
  local moved = { { path = "strata.lua", text = "" } }
  for _, source in ipairs(sources) do table.insert(moved, { path = "lib/moved_" .. #moved .. ".lua", text = source.text }) end
  ok, report = problems_of(moved)
  assert_true(ok, "the calls moved into modules still cover every command:\n" .. report)
  ok, report = problems_of({ { path = "strata.lua", text = "" } })
  assert_true(not ok and report:find("is never called", 1, true), "a command no file calls is reported")
  -- the single-source entry point reports its source as strata.lua
  local _, single = sync_check.check("\nengine.nope(1)", sc_source)
  assert_equal(single[1], "strata.lua:2 engine.nope has no addCommand in the engine", "check() reads one source")
end)

test("the engine source parsers skip // and /* */ comments (#25)", function()
  local stripped = stubs.strip_sc_comments('a = "x // y /* z"; b = \'s//\'; c = $"; // gone\nd /* e /* f */ g */ h')
  assert_equal(stripped, 'a = "x // y /* z"; b = \'s//\'; c = $"; ' .. string.rep(" ", #"// gone")
    .. "\nd " .. string.rep(" ", #"/* e /* f */ g */") .. " h",
    "comments become spaces (newlines kept); strings, symbols and characters are not comments")
  local source = engine_sources()
  -- the 3.0.1 review's mutation: \stopRecord wrapped in a block comment
  local start = assert(source:find("this.addCommand(\\stopRecord", 1, true), "stopRecord found")
  local finish = assert(source:find("this.addCommand(", start + 1, true), "next command found")
  local commented = source:sub(1, start - 1) .. "/* " .. source:sub(start, finish - 1) .. "*/ " .. source:sub(finish)
    .. '\n// this.addCommand(\\ghostLine, "i", { arg msg; });'
    .. '\n/* outer /* nested */ this.addCommand(\\ghostNested, "i", { arg msg; }); */'
    .. '\n// this.addPoll(\\ghostPoll, { 0 });'
  -- the engine stub's (which the AGENTS.md table check uses) and sync_check's
  for parser_name, parse in pairs({ stub = stubs.engine_signatures_from_source, sync_check = sync_check.sc_commands }) do
    local commands = parse(commented)
    for _, name in ipairs({"stopRecord", "ghostLine", "ghostNested"}) do
      assert_true(commands[name] == nil, parser_name .. " skips the commented-out \\" .. name)
    end
    assert_equal(commands.clearBuffer, signatures.clearBuffer, parser_name .. " reads the command before it")
    assert_equal(commands.saveBuffer, signatures.saveBuffer, parser_name .. " reads the command after it")
  end
  assert_true(signatures.stopRecord ~= nil, "the real engine has \\stopRecord")
  for _, name in ipairs(stubs.engine_polls_from_source(commented)) do
    assert_true(name ~= "ghostPoll", "a commented-out poll is skipped")
  end
  -- #24's SynthDef and enumeration parsers: a commented-out SynthDef,
  -- argument or clip (3.8: the grain envelopes' Env list is gone)
  local patched, count = source:gsub("SynthDef%(\\strataGrainRing, {%s*arg ", "%0/* ghostControl=0, */ ")
  assert_equal(count, 1, "argument patch applies")
  local spec = stubs.engine_spec_from_source(patched .. "\n// SynthDef(\\ghostDef, { arg ghost; });\n// overlapOn.round.clip(0, 5)")
  assert_true(spec.synthdef_controls.ghostDef == nil, "a commented-out SynthDef is skipped")
  assert_true(not spec.synthdef_controls.strataGrainRing.ghostControl, "a commented-out argument is skipped")
  assert_true(spec.synthdef_controls.strataGrainRing.grainSize, "the arguments around it are read")
  assert_equal(spec.enumerations.overlapOn[2], engine_spec.enumerations.overlapOn[2], "a commented-out clip is not read")
end)

test("strip_sc_comments fails on an unterminated string, symbol or block comment (#51)", function()
  local function assert_strip_fails(source, expected_text, line)
    local ok, message = pcall(stubs.strip_sc_comments, source)
    assert_true(not ok, "unterminated " .. expected_text .. " is an error, not the rest of the file")
    assert_true(tostring(message):find("unterminated " .. expected_text, 1, true)
      and tostring(message):find("line " .. line, 1, true), "the error says what and where: " .. tostring(message))
  end
  assert_strip_fails('a = 1;\nb = "open;\nc = 2;', "string", 2)
  assert_strip_fails("a = 1;\n\nb = 'open;", "symbol", 3)
  assert_strip_fails('a = 1; /* open /* nested */ still open', "block comment", 1)
  assert_strip_fails('a = "ends in an escape\\"', "string", 1)
  -- a SynthDef whose { never closes: the error names its line too
  local source = engine_sources()
  local _, lines = source:gsub("\n", "")
  local ok, message = pcall(stubs.engine_spec_from_source, source .. "\nSynthDef(\\open, { arg x; x = 1;\n")
  assert_true(not ok and tostring(message):find("unbalanced { from line " .. (lines + 2), 1, true),
    "unbalanced: " .. tostring(message))
  -- closed ones, with escapes, still pass
  assert_equal(stubs.strip_sc_comments('a = "x\\"y"; b = \'q\\\'r\';'), 'a = "x\\"y"; b = \'q\\\'r\';', "escaped quotes")
end)

-- Expects engine.<name>(...) to be rejected by the engine stub with an error
-- containing `expected_text`
local function assert_engine_rejects(expected_text, name, ...)
  local ok, message = pcall(engine[name], ...)
  assert_true(not ok, "engine." .. name .. " should be rejected (" .. expected_text .. ")")
  assert_true(tostring(message):find(expected_text, 1, true) ~= nil,
    "engine." .. name .. " error mentions " .. expected_text .. ": " .. tostring(message))
end

test("the engine stub reads its limits and controls from the engine source (#24)", function()
  load_strata()
  local spec = stubs.parse_engine_spec(engine_sources())
  assert_equal(spec.num_voices, local_value("NUM_VOICES"), "numVoices")
  assert_equal(spec.num_buffers, local_value("NUM_BUFFERS"), "numBuffers")
  assert_equal(spec.input_source, local_value("NUM_BUFFERS") + 1, "inputSource")
  assert_equal(spec.voice_source_first, local_value("SOURCE_VOICE_FIRST") - 1, "voiceSourceFirst (3.8)")
  assert_equal(spec.mod_slots, local_value("NUM_MOD_SLOTS"), "modBus1..N on every voice SynthDef")
  assert_true(#spec.voice_type_defs >= spec.num_voices, "the default roster gives voice i type i")
  assert_equal(spec.voice_type_defs[1], "strataResonator", "type 0's SynthDef")
  assert_equal(spec.voice_type_defs[spec.num_voices], "strataRing", "the last voice's own type's SynthDef")
  assert_true(spec.synthdef_controls.strataFM.ratio, "strataFM controls parsed")
  assert_true(spec.synthdef_controls.strataGrainBuf.bufPos, "strataGrainBuf controls parsed")
  assert_true(spec.grain_params.history, "a grainParamHandlers key (history) is accepted")
  assert_true(spec.grain_params.envShape == nil, "3.8: envShape is gone")
  assert_true(spec.grain_params.bufPos and spec.grain_params.grainSize, "grain SynthDef controls are accepted")
  -- each enumerated control is 0..options - 1 of its Lua option param
  assert_equal(spec.enumerations.grainMode[1], 0, "grainMode from 0")
  assert_equal(spec.enumerations.grainMode[2], #local_value("GRAIN_MODE_OPTIONS") - 1, "grainMode to triggered")
  -- 3.8: the overlap cloud and the arpeggiator's switches, 0..1
  for _, name in ipairs({"overlapOn", "arpOn", "arpFold"}) do
    assert_equal(table.concat(spec.enumerations[name] or {}, ","), "0,1", name .. " is 0..1")
  end
  assert_equal(spec.enumerations.overlapOn[2], #local_value("S").lib.grain.GRAIN.clouds - 1, "overlapOn to the last cloud")
  assert_equal(spec.enumerations.filterType[1], 0, "filterType from lowpass")
  assert_equal(spec.enumerations.filterType[2], 2, "filterType to bandpass")
  -- a control added to a grain SynthDef is picked up without stub changes
  local source = engine_sources()
  local extended, count = source:gsub("SynthDef%(\\strataGrainRing, {%s*arg ", "%0newGrainControl=0, ")
  assert_equal(count, 1, "test patch applies")
  assert_true(stubs.engine_spec_from_source(extended).grain_params.newGrainControl, "new grain control accepted")
end)

test("the engine's shared constants equal strata.lua's (#25)", function()
  load_strata()
  assert_equal(engine_spec.num_voices, local_value("NUM_VOICES"), "numVoices = NUM_VOICES")
  assert_equal(engine_spec.num_buffers, local_value("NUM_BUFFERS"), "numBuffers = NUM_BUFFERS")
  -- the crossmod commands accept slots 1..numModSlots, the modBus1..N of every voice SynthDef (#47)
  assert_equal(engine_spec.num_mod_slots, local_value("NUM_MOD_SLOTS"), "numModSlots = NUM_MOD_SLOTS")
  assert_equal(engine_spec.num_mod_slots, engine_spec.mod_slots, "numModSlots = the modBus1..N controls")
  -- only buffer_state_changed, a local function, reads BUFFER_STATE_STRIDE
  -- and BUFFER_STATE_LOADS (#578; each declared in exactly one of the
  -- script's files)
  local declared = {}
  for _, source in ipairs(read_lua_sources()) do
    for _, name in ipairs({ "BUFFER_STATE_STRIDE", "BUFFER_STATE_LOADS" }) do
      local found = tonumber(source.text:match("\nlocal " .. name .. "%s*=%s*(%d+)"))
      if found then
        assert_equal(declared[name], nil, name .. " is declared once")
        declared[name] = found
      end
    end
  end
  assert_equal(engine_spec.buffer_state_stride, declared.BUFFER_STATE_STRIDE, "bufferStateStride = BUFFER_STATE_STRIDE")
  assert_equal(engine_spec.buffer_state_loads, declared.BUFFER_STATE_LOADS, "bufferStateLoads = BUFFER_STATE_LOADS")
end)

-- #459: the engine packs bufferLoadFailed, bufferSaveResult and recordState
-- in three Value methods and Lua decodes them in three handlers. Each
-- method's expression is read from the engine source and evaluated as
-- sclang does (binary operators left to right, messages first), and the
-- values it gives reach the handlers, which must act on the load, save or
-- recording they name.
local function engine_value_method(name)
  local source = stubs.strip_sc_comments(engine_sources())
  local args, body = source:match("\n%s*" .. name .. "%s*{%s*arg%s+([%w_,%s]-);%s*%^([^\n]-)%s*\n%s*}")
  assert_true(args ~= nil, "the engine has " .. name .. " { arg ...; ^... }")
  local names = {}
  for arg in args:gmatch("[%w_]+") do table.insert(names, arg) end
  return function(...)
    local values, tokens, position = {numBuffers = engine_spec.num_buffers, numVoices = engine_spec.num_voices}, {}, 1
    for index, arg in ipairs(names) do values[arg] = select(index, ...) end
    -- tokens: numbers, names, ( ) + - * / and .message
    local text = body:gsub("%s+", "")
    local index = 1
    while index <= #text do
      local number = text:match("^%d+%.?%d*", index)
      local word = text:match("^[%a_][%w_]*", index)
      if number then table.insert(tokens, {kind = "number", value = tonumber(number)}); index = index + #number
      elseif word then table.insert(tokens, {kind = "name", value = word}); index = index + #word
      else table.insert(tokens, {kind = text:sub(index, index)}); index = index + 1 end
    end
    local operand, expression
    local function message(value, selector)
      if selector == "asFloat" or selector == "asInteger" then
        assert_true(type(value) == "number", name .. ": ." .. selector .. " of a number")
        return selector == "asInteger" and (value >= 0 and math.floor(value) or -math.floor(-value)) or value
      elseif selector == "binaryValue" then
        assert_true(type(value) == "boolean", name .. ": .binaryValue of a Boolean")
        return value and 1 or 0
      end
      fail(name .. ": a message this test does not know: ." .. selector)
    end
    function operand()
      local token, value = tokens[position], nil
      position = position + 1
      if token.kind == "number" then value = token.value
      elseif token.kind == "name" then
        value = values[token.value]
        assert_true(value ~= nil, name .. ": a name this test does not know: " .. token.value)
      elseif token.kind == "(" then
        value = expression()
        assert_equal(tokens[position].kind, ")", name .. ": a closing parenthesis")
        position = position + 1
      else fail(name .. ": unexpected " .. tostring(token.kind)) end
      while tokens[position] and tokens[position].kind == "." do
        value = message(value, tokens[position + 1].value)
        position = position + 2
      end
      return value
    end
    function expression()
      local value = operand()
      while tokens[position] and ("+-*/"):find(tokens[position].kind, 1, true) do
        local operator = tokens[position].kind
        position = position + 1
        local right = operand()
        assert_true(type(value) == "number" and type(right) == "number", name .. ": arithmetic on numbers")
        if operator == "+" then value = value + right elseif operator == "-" then value = value - right
        elseif operator == "*" then value = value * right else value = value / right end
      end
      return value
    end
    local result = expression()
    assert_equal(position, #tokens + 1, name .. ": the whole expression is read")
    return result
  end
end

test("the engine's event polls decode in Lua's handlers (#459)", function()
  local context = load_strata(); h.finish_startup(context)
  local S = local_value("S")
  local buffers = local_value("buffers")
  local record_state_value = engine_value_method("recordStateValue")
  local load_failed_value = engine_value_method("bufferLoadFailedValue")
  local save_result_value = engine_value_method("bufferSaveResultValue")
  S.lib.ui_keys.set_ui_page(local_value("UI_PAGES").index.BUFFER)
  -- recordState: slot 3's sixth recording (engine index 2) reports recording, then canceled
  buffers[3].records_sent = 5
  params:set("record_sync", 3)
  record_buffer(3)
  assert_equal(S.lib.record.state(3).phase, "armed")
  context.polls.fire("recordState", record_state_value(2, 6, 1))
  assert_equal(S.lib.record.state(3) and S.lib.record.state(3).phase, "recording", "recordState: recording")
  context.polls.fire("recordState", record_state_value(2, 6, 3))
  assert_equal(buffers[3].recording, false, "recordState: canceled")
  -- bufferLoadFailed: slot 5's second load failed, its third emptied the slot
  load_buffer(5, "/tmp/a.wav"); context.polls.fire("bufferState", context.polls.buffer_state_value(5, 1, 4))
  load_buffer(5, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 2, false))
  assert_equal(buffers[5].name, "a.wav", "bufferLoadFailed: load 2 undone")
  load_buffer(5, "/tmp/gone.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 3, true))
  assert_equal(buffers[5].name, "empty", "bufferLoadFailed: load 3 emptied the slot")
  -- bufferSaveResult: slot 6's first save written, its second failed
  load_buffer(6, "/tmp/c.wav"); context.polls.fire("bufferState", context.polls.buffer_state_value(6, 1, 4))
  assert_true(save_buffer(6))
  context.polls.fire("bufferSaveResult", save_result_value(5, 1, false))
  assert_equal(S.lib.ui_flash.text("hints"), "saved buf 6", "bufferSaveResult: save 1 written")
  assert_true(save_buffer(6))
  context.polls.fire("bufferSaveResult", save_result_value(5, 2, true))
  assert_equal(S.lib.ui_flash.text("header"), "buf 6 save failed", "bufferSaveResult: save 2 failed (the header's, #878)")
end)

-- #858: the freeze area's report of a hold it abandoned, as the engine
-- encodes it, unfreezes Lua's voice
test("the engine's freezeEnded poll decodes in Lua's handler (#858)", function()
  local context = load_strata(); h.finish_startup(context)
  local S = local_value("S")
  local freeze_ended_value = engine_value_method("freezeEndedValue")
  params:set("v2_source", S.constants.SOURCE_INPUT)
  params:set("v2_freeze", 1)
  context.polls.fire("freezeEnded", freeze_ended_value(1, 1))
  assert_equal(params:get("v2_freeze"), 0, "voice 2's (engine voice 1) first ended hold")
end)

test("the engine's waveformPoints equals WAVEFORM_POINTS", function()
  load_strata()
  local points = tonumber(engine_sources():match("waveformPoints%s*{%s*%^(%d+)%s*}"))
  assert_equal(points, 64, "the engine's waveformPoints")
  assert_equal(local_value("WAVEFORM_POINTS"), 64, "lib/constants.lua's WAVEFORM_POINTS")
  assert_equal(points, local_value("WAVEFORM_POINTS"), "waveformPoints = WAVEFORM_POINTS")
end)

test("the engine stub checks the 3.3 arguments", function()
  load_strata()
  local rejected = {
    {"recordBuffer", {0, 4, 1, 1.5, 0, 0, 0, 0, 0}, "feedback past 1"},
    {"recordBuffer", {0, 4, 1, 0, 10, 0, 0, 0, 0}, "source past 9"},
    {"recordBuffer", {0, 4, 1, 0, 0, -0.1, 0, 0, 0}, "threshold below 0"},
    {"recordBuffer", {0, 4, 1, 0, 0, 0, 2, 0, 0}, "loop past 1"},
    {"recordBuffer", {0, 4, 1, 0, 0, 0, 0, -1, 0}, "delay below 0"},
    {"recordBuffer", {0, 4, 1, 0, 0, 0, 0, 0, 1794412302.5}, "sent past 1000 (util.time() not wrapped)"},
    {"recordBuffer", {0, 4, 1, 0, 0, 0, 0, 0, -1}, "sent below 0"},
    {"loadBuffer", {0, "/x.wav", -1}, "a start below 0"},
    {"saveBuffer", {0, "/x.wav", 0, 1.5}, "a length past 1"},
    {"saveBuffer", {0, "/x.wav", -0.1, 1}, "a start below 0"},
    {"recordBuffer", {0, 4, 1}, "3.2's three arguments"},
    {"loadBuffer", {0, "/x.wav"}, "3.2's two arguments"},
    {"saveBuffer", {0, "/x.wav"}, "3.2's two arguments"},
  }
  for _, case in ipairs(rejected) do
    assert_true(not pcall(engine[case[1]], (table.unpack or unpack)(case[2])), "engine." .. case[1] .. " rejects " .. case[3])
  end
  assert_true(pcall(engine.recordBuffer, 7, 16, 1, 1, 9, 0.5, 1, 2, 1000), "every recordBuffer argument at its limit")
  assert_true(pcall(engine.loadBuffer, 7, "/x.wav", 12.5), "a start inside the file")
  assert_true(pcall(engine.saveBuffer, 7, "/x.wav", 0.25, 0.5), "a region of the slot")
end)

-- The slot length is a tier value (lib/performance.lua): only the standard
-- tier's is a constant on both sides
test("the engine's standard buffer length equals STANDARD_BUFFER_SECONDS", function()
  load_strata()
  assert_equal(engine_spec.standard_buffer_seconds, local_value("STANDARD_BUFFER_SECONDS"),
    "standardBufferSeconds = STANDARD_BUFFER_SECONDS")
  assert_equal(local_value("STANDARD_PERFORMANCE").buffer_seconds, engine_spec.standard_buffer_seconds,
    "STANDARD_PERFORMANCE's length")
  assert_equal(local_value("S").constants.BUFFER_SECONDS, nil, "BUFFER_SECONDS is no longer a constant")
end)

-- A "Must match <NAME> in <file>" comment in the engine names a constant
-- that file still declares, so a moved or removed constant (BUFFER_SECONDS,
-- now a tier value) never leaves a stale pointer behind
test("every engine \"must match <NAME> in <file>\" comment names a constant that file declares", function()
  local files = {"lib/Engine_Strata.sc"}
  local listing = io.popen('ls "' .. repo_root .. '/lib/engine"')
  for name in listing:lines() do
    if name:match("%.sc$") then table.insert(files, "lib/engine/" .. name) end
  end
  listing:close()
  local function read(path)
    local file = io.open(repo_root .. "/" .. path, "r")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
  end
  local stale, seen = {}, 0
  for _, path in ipairs(files) do
    for line in read(path):gmatch("[^\n]+") do
      local comment = line:match("//(.*)$")
      if comment then
        for name, target in comment:gmatch("[Mm]ust match ([%u_][%u%d_]*) in ([%w_/%.%-]+%.lua)") do
          seen = seen + 1
          local text = read(target)
          if not (text and text:match("\nlocal " .. name .. "%s*=")) then
            table.insert(stale, path .. ": " .. name .. " in " .. target)
          end
        end
      end
    end
  end
  assert_true(seen >= 3, "the engine's constant comments are found (" .. seen .. ")")
  assert_true(#stale == 0, "comments naming a constant the file does not declare:\n" .. table.concat(stale, "\n"))
end)

test("the engine stub's voice and slot limits follow numVoices and numBuffers in the engine source (#51)", function()
  local source = engine_sources()
  local patched, count = source:gsub("var <numVoices = %d+;", "var <numVoices = 6;")
  assert_equal(count, 1, "numVoices patch applies")
  patched, count = patched:gsub("var <numBuffers = %d+;", "var <numBuffers = 4;")
  assert_equal(count, 1, "numBuffers patch applies")
  local spec = stubs.parse_engine_spec(patched)
  assert_equal(spec.num_voices, 6, "numVoices read from the patched copy")
  assert_equal(spec.num_buffers, 4, "numBuffers read from the patched copy")
  assert_equal(spec.input_source, 5, "inputSource follows numBuffers")
  assert_equal(spec.voice_source_first, 6, "voiceSourceFirst follows numBuffers")
  assert_equal(#spec.voice_type_defs, #engine_spec.voice_type_defs, "the type list does not follow numVoices")
  -- the stub's range checks use them
  stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = spec,
    data_dir = data_root .. "patched_engine/", quiet = true }
  engine.voiceOff(5); engine.clearBuffer(3); engine.setGrainSource(0, 5); engine.setModSource(0, 1, 5)
  assert_engine_rejects("voice", "voiceOff", 6)
  assert_engine_rejects("slot", "clearBuffer", 4)
  engine.setGrainSource(0, 11)  -- (3.8: voice 6 of six's ring, voiceSourceFirst 6)
  assert_engine_rejects("source", "setGrainSource", 0, 12)
  assert_engine_rejects("mod source", "setModSource", 0, 1, 6)
end)

-- The script never bangs its params, so until a param changes the engine
-- plays the FX SynthDef's own default: it must be the Lua param's default.
-- Each FX command sets FX synth controls from its arguments (parsed from
-- every setSynth in the command bodies); sending every fx param's default
-- must send exactly those SynthDef defaults.
test("the FX SynthDefs' defaults equal the Lua param defaults (#25)", function()
  local context = load_strata()
  local fx_commands = engine_spec.fx_commands
  for _, name in ipairs({"setFilter", "setDelay", "setReverb", "setMasterDrift"}) do
    assert_true(fx_commands[name] ~= nil, "engine." .. name .. " sets an FX synth")
  end
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  assert_true(group_index ~= nil, "the fx group exists")
  context.clear_engine_calls()
  for index = group_index + 1, group_index + params:get("strata_fx") do
    local param_id = params.params[index].id
    send_param_to_engine(param_id, params:get(param_id))
  end
  for name, settings in pairs(fx_commands) do
    local calls = context.calls_named(name)
    assert_true(#calls > 0, "an fx param sends engine." .. name)
    local set_arguments = {}
    for _, setting in ipairs(settings) do
      set_arguments[setting.argument] = true
      local defaults = engine_spec.synthdef_defaults[setting.synthdef]
      local label = "\\" .. setting.synthdef .. " " .. setting.control
      assert_true(defaults[setting.control] ~= nil, label .. " has a numeric default")
      assert_near(calls[#calls].args[setting.argument], defaults[setting.control], 1e-6,
        "engine." .. name .. " argument " .. setting.argument .. " (Lua default) vs " .. label)
    end
    for index = 1, #signatures[name] do
      assert_true(set_arguments[index], "engine." .. name .. " argument " .. index .. " sets a control")
    end
  end
end)

-- The same rule for the scale and the two bypasses (#460): setScale and
-- setBypass go out only when their params change, so the engine's start
-- state (allocScaleBuffer's root and mask, the effects area's bypassed
-- table, both read from the engine source) must be what the params'
-- defaults send.
test("the scale and bypass params' defaults equal the engine's start state (#460)", function()
  local context = load_strata()
  local source = stubs.strip_sc_comments(engine_sources())
  local function method_body(name)
    local start = assert(source:find("\n%s*" .. name .. "%s*{"), "engine source: no method " .. name)
    return source:sub(start, (source:find("\n    }", start, true)))
  end
  -- the engine's start: root, mask (a number or this.chromaticMask), bypassed per effect
  local alloc = method_body("allocScaleBuffer")
  local start_root = tonumber(alloc:match("state%[\\root%]%s*=%s*(%d+)%s*;"))
  local mask_text = alloc:match("state%[\\mask%]%s*=%s*([^;]-)%s*;")
  local start_mask = tonumber(mask_text)
  if mask_text == "this.chromaticMask" then start_mask = tonumber(source:match("chromaticMask%s*{%s*%^%s*(%d+)%s*}")) end
  assert_true(start_root ~= nil and start_mask ~= nil, "allocScaleBuffer sets a root and a mask the test can read")
  local bypass_keys = {}
  for key in (source:match("bypassKeys%s*{%s*%^%s*%[(.-)%]%s*}") or ""):gmatch("\\([%w_]+)") do table.insert(bypass_keys, key) end
  local bypassed = source:match("state%[\\bypassed%]%s*=%s*IdentityDictionary%[(.-)%]%s*;") or ""
  assert_equal(#bypass_keys, 2, "the engine's bypassKeys name two effects")
  -- the Lua defaults: the scale and root actions send setScale; each bypass param's sender, setBypass
  context.clear_engine_calls()
  params:lookup_param("scale"):bang()
  params:lookup_param("root"):bang()
  local scale_calls = context.calls_named("setScale")
  assert_true(#scale_calls > 0, "the scale and root params send engine.setScale")
  assert_equal(scale_calls[#scale_calls].args[1], start_root, "setScale's root (Lua default) vs allocScaleBuffer's")
  assert_equal(scale_calls[#scale_calls].args[2], start_mask, "setScale's mask (Lua default) vs allocScaleBuffer's")
  local voice_mix = local_value("lib").voice_mix
  for _, effect in ipairs(voice_mix.BYPASS_ORDER) do
    local bypass = voice_mix.BYPASS[effect]
    context.clear_engine_calls()
    send_param_to_engine(bypass.param_id, params:get(bypass.param_id))
    local calls = context.calls_named("setBypass")
    assert_equal(#calls, 1, bypass.param_id .. " sends engine.setBypass")
    local key = bypass_keys[calls[1].args[1] + 1]
    assert_true(key ~= nil, bypass.param_id .. "'s effect number is one of the engine's bypassKeys")
    local engine_start = bypassed:match("\\" .. key .. "%s*%->%s*(%a+)")
    assert_true(engine_start == "true" or engine_start == "false", "the engine's bypassed table starts \\" .. key)
    assert_equal(calls[1].args[2], engine_start == "true" and 1 or 0,
      bypass.param_id .. "'s default vs the engine's bypassed \\" .. key)
  end
end)

-- 3.8's tuning (design §6.2): lib/tuning.lua's TUNING mirrors the engine's
-- tuning constants, and its default is the tuning the engine starts in
-- (allocScaleBuffer's tones and period), so a start need send none (ruling
-- 42); #460's rule, extended: what the tuning param's default sends is
-- that start
test("the tuning constants equal the engine's", function()
  local context = load_strata()
  local source = stubs.strip_sc_comments(engine_sources())
  local function engine_value(name)
    local value = tonumber(source:match("%f[%w_]" .. name .. "%s*{%s*%^%s*(%-?[%d%.]+)%s*}") or "")
    assert_true(value ~= nil, "the engine defines " .. name .. " { ^N }")
    return value
  end
  local TUNING = local_value("lib").tuning.TUNING
  local mirrors = {max_tones = "tuningMaxTones", min_period = "tuningMinPeriod", max_period = "tuningMaxPeriod",
    octave = "octaveCents", twelve = "tuningTwelve", octave_tolerance = "tuningOctaveTolerance",
    root_key = "tuningRootKey", table_frames = "tuningTableFrames", table_low = "tuningTableLow",
    table_resolution = "tuningTableResolution"}
  for field, method in pairs(mirrors) do
    assert_equal(TUNING[field], engine_value(method), "TUNING." .. field .. " vs the engine's " .. method)
  end
  local start = source:find("\n%s*allocScaleBuffer%s*{")
  local alloc = source:sub(start, (source:find("\n    }", start, true)))
  local count, period, divisor = alloc:match(
    "state%[\\tones%]%s*=%s*%(0 %.%. %(this%.(%w+) %- 1%)%)%s*%*%s*%(this%.(%w+) div: this%.(%w+)%)%s*;")
  assert_true(count ~= nil and period ~= nil and count == divisor,
    "allocScaleBuffer starts the tones as equal steps the test can read")
  assert_equal(alloc:match("state%[\\period%]%s*=%s*this%.(%w+)%s*;"), period, "allocScaleBuffer's period is the tones' period")
  local tones = {}
  for step = 0, engine_value(count) - 1 do tones[#tones + 1] = step * math.floor(engine_value(period) / engine_value(count)) end
  assert_equal(TUNING.default.period, engine_value(period), "TUNING.default's period vs the engine's start")
  assert_equal(table.concat(TUNING.default.tones, " "), table.concat(tones, " "), "TUNING.default's tones vs the engine's start")
  -- #460's rule, extended to the tuning: what the tuning param's default
  -- sends is the engine's start
  context.clear_engine_calls()
  params:lookup_param("tuning_tones"):bang()
  local started = context.calls_named("setTuning")
  local sent = context.calls_named("setTuningTone")
  assert_equal(#started, 1, "tuning_tones' action sends setTuning")
  assert_equal(started[1].args[1], #tones, "setTuning's count (Lua default) vs allocScaleBuffer's")
  assert_equal(started[1].args[2], engine_value(period), "setTuning's period (Lua default) vs allocScaleBuffer's")
  local sent_tones = {}
  for index, call in ipairs(sent) do
    assert_equal(call.args[1], index - 1, "setTuningTone " .. index .. "'s index")
    sent_tones[index] = call.args[2]
  end
  assert_equal(table.concat(sent_tones, " "), table.concat(tones, " "), "the tones (Lua default) vs allocScaleBuffer's")
end)

-- A Lua FX param whose range is wider than the limit the engine clips its
-- control to fails here (the range check only sees the values sent)
-- The FX params whose controlspec range leaves the limit the engine clips
-- their argument to (each param's argument: the one that changes with it),
-- and how many param/limit pairs were compared
local function fx_specs_outside_engine_limits(context)
  local group_index
  for index, param in ipairs(params.params) do
    if param.id == "strata_fx" then group_index = index end
  end
  local problems, compared = {}, 0
  for index = group_index + 1, group_index + params:get("strata_fx") do
    local param = params.params[index]
    local spec = param.controlspec
    if spec then
      local function sent(fraction)
        context.clear_engine_calls(); send_param_to_engine(param.id, spec:map(fraction))
        return context.engine_calls[#context.engine_calls]
      end
      local low, high = sent(0.25), sent(0.75)
      for argument = 1, #high.args do
        local limit = (engine_spec.argument_limits[high.name] or {})[argument]
        if low.args[argument] ~= high.args[argument] and limit then
          compared = compared + 1
          if spec.minval < limit.low or spec.maxval > limit.high then
            table.insert(problems, string.format("%s %g..%g leaves engine.%s's %s limit %g..%g", param.id,
              spec.minval, spec.maxval, high.name, limit.name, limit.low, limit.high))
          end
        end
      end
    end
  end
  return problems, compared
end

-- A Lua FX range wider than the engine's limit fails here directly (the
-- range check only sees the values a test happens to send)
test("each FX param's controlspec lies within the engine's limit for its argument (#51)", function()
  local problems, compared = fx_specs_outside_engine_limits(load_strata())
  assert_equal(#problems, 0, table.concat(problems, "; "))
  assert_equal(compared, 11,
    "filter freq, res and mix; delay time, feedback, mix and ping-pong; reverb mix; delay to reverb; shimmer's two amounts compared")
  local widened, count = patched_script('controlspec%.new%(0, 0%.95, "lin", 0%.01, 0%.4%)', 'controlspec.new(0, 0.99, "lin", 0.01, 0.4)')
  assert_equal(count, 1, "delay feedback patch applies")
  problems = fx_specs_outside_engine_limits(load_strata(widened))
  assert_true(#problems == 1 and problems[1]:find("delay_feedback", 1, true), "a widened range fails: " .. table.concat(problems, "; "))
end)

test("fx_commands reads every setSynth in a command body (#51)", function()
  local source = engine_sources()
  -- \setFilter split into two setSynth calls, and \setReverb also setting the master's drift
  local patched, count = source:gsub(
    "this%.setSynth%(\\filter, \\freq, msg%[1%], \\res, msg%[2%], \\filterType, msg%[3%], \\mix, msg%[4%]%);",
    "this.setSynth(\\filter, \\freq, msg[1], \\res, msg[2]);\n            "
      .. "this.setSynth(\\filter, \\filterType, msg[3], \\mix, msg[4]);")
  assert_equal(count, 1, "setFilter patch applies")
  patched, count = patched:gsub("(this%.setSynth%(\\reverb, \\mix[^;]*;)", "%1 this.setSynth(\\master, \\drift, msg[3]);")
  assert_equal(count, 1, "setReverb patch applies")
  local function settings_of(spec, command)
    local found = {}
    for _, setting in ipairs(spec.fx_commands[command]) do
      table.insert(found, setting.argument .. ":" .. setting.synthdef .. "." .. setting.control)
    end
    table.sort(found)
    return table.concat(found, " ")
  end
  local spec = stubs.engine_spec_from_source(patched)
  assert_equal(settings_of(spec, "setFilter"), settings_of(engine_spec, "setFilter"), "both setSynth calls read")
  assert_equal(settings_of(spec, "setFilter"),
    "1:strataFilter.freq 2:strataFilter.res 3:strataFilter.filterType 4:strataFilter.mix", "every argument")
  assert_equal(settings_of(spec, "setReverb"),
    "1:strataReverb.mix 2:strataReverb.size 3:strataMaster.drift 3:strataReverb.damp 4:strataReverb.delayToReverb",
    "a second FX synth set by the same command")
end)

-- A command's limits and names come from its own function, the addCommand
-- call's ( ... ), never from the methods after the last command of a file (#487)
test("the stub reads a command's limits from its own function only (#487)", function()
  local source = engine_sources()
  local bypass = assert(source:find("addCommand%(\\setBypass"), "setBypass is in the engine")
  local file_end = source:find("\n// file: ", bypass, true) or #source + 1
  local close = source:sub(1, file_end - 1):match(".*()}")
  local patched = source:sub(1, close - 1) .. "\n    strataProbeDepth { arg msg; var depth = msg[2].clip(0, 0.5); ^depth }\n"
    .. source:sub(close)
  assert_equal(engine_spec.argument_limits.setBypass, nil, "setBypass clips nothing itself")
  assert_equal(stubs.engine_spec_from_source(patched).argument_limits.setBypass, nil,
    "a method after the file's last command limits nothing")
  local fragment = 'this.addCommand(\\setGrainParam, "isf", { arg msg; var param = msg[2].asSymbol;'
    .. ' if (param == \\inside) { }; });\n'
    .. 'strataProbeHelper { arg param; if (param == \\outside) { }; }\n'
  local spec = stubs.engine_spec_from_source(fragment)
  assert_true(spec.grain_params.inside, "a name the command handles is a grain param")
  assert_equal(spec.grain_params.outside, nil, "a name in a later method is not")
end)

test("the engine stub rejects out-of-range engine arguments (#24)", function()
  load_strata()
  -- voices are 0..numVoices-1
  assert_engine_rejects("voice", "voiceOff", 7)
  assert_engine_rejects("voice", "voiceOff", -1)
  assert_engine_rejects("voice", "voiceOn", 7, 100, 0.3, 0, 0.1, 20, 1)
  assert_engine_rejects("voice", "retrigger", 7, 1)
  assert_engine_rejects("voice", "setVoiceParam", 7, "amp", 0.3)
  assert_engine_rejects("voice", "setGrainParam", 7, "grainSize", 0.1)
  assert_engine_rejects("voice", "setModSpeed", 7, 1)
  engine.voiceOff(0); engine.voiceOff(6)
  -- slots are 0..numBuffers-1
  for _, command in ipairs({"clearBuffer", "stopRecord"}) do
    assert_engine_rejects("slot", command, 8)
    assert_engine_rejects("slot", command, -1)
  end
  assert_engine_rejects("slot", "loadBuffer", 8, "/tmp/x.wav", 0)
  assert_engine_rejects("slot", "saveBuffer", 8, "/tmp/x.wav", 0, 1)
  assert_engine_rejects("slot", "recordBuffer", 8, 4, 1, 0, 0, 0, 0, 0, 0)
  engine.clearBuffer(0); engine.clearBuffer(7)
  -- sources are 0 (synth), 1..numBuffers, numBuffers + 1 (input), then (3.8) a voice source a voice
  assert_engine_rejects("source", "setGrainSource", 0, engine_spec.voice_source_first + engine_spec.num_voices)
  assert_engine_rejects("source", "setGrainSource", 0, -1)
  engine.setGrainSource(0, 0); engine.setGrainSource(0, 9); engine.setGrainSource(0, engine_spec.voice_source_first + engine_spec.num_voices - 1)
  -- mod slots are 1..3, mod sources -1 (none) or a voice
  for _, command in ipairs({"setModAmpAmt", "setModFreqAmt"}) do
    assert_engine_rejects("mod slot", command, 0, 0, 0.5)
    assert_engine_rejects("mod slot", command, 0, 4, 0.5)
    assert_engine_rejects("voice", command, 7, 1, 0.5)
  end
  assert_engine_rejects("mod slot", "setModSource", 0, 4, 1)
  assert_engine_rejects("mod source", "setModSource", 0, 1, 7)
  assert_engine_rejects("mod source", "setModSource", 0, 1, -2)
  engine.setModSource(0, 1, -1); engine.setModSource(0, 3, 6)
  -- filter type 0..2
  assert_engine_rejects("filterType", "setFilter", 5000, 0.5, 3, 0)
  assert_engine_rejects("filterType", "setFilter", 5000, 0.5, -1, 0)
  engine.setFilter(5000, 0.5, 2, 0)
  -- enumerated grain params: whole numbers in range
  assert_engine_rejects("grainMode", "setGrainParam", 0, "grainMode", 2)
  assert_engine_rejects("grainMode", "setGrainParam", 0, "grainMode", 0.5)
  assert_engine_rejects("overlapOn", "setGrainParam", 0, "overlapOn", 2)
  assert_engine_rejects("overlapOn", "setGrainParam", 0, "overlapOn", 0.5)
  assert_engine_rejects("arpOn", "setGrainParam", 0, "arpOn", 2)
  assert_engine_rejects("arpFold", "setGrainParam", 0, "arpFold", 0.5)
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", 0)  -- 3.8: gone
  assert_engine_rejects("windowBank", "setGrainParam", 0, "windowBank", 3)  -- engine-owned
  engine.setGrainParam(0, "grainMode", 1); engine.setGrainParam(0, "overlapOn", 1)
  engine.setGrainParam(0, "arpOn", 1); engine.setGrainParam(0, "arpFold", 0)
end)

-- A NaN fails every `<` and `>` of a range check, and an infinity passes
-- wherever the engine clips nothing: the type check refuses both (#477)
test("the engine stub rejects a NaN or infinite argument (#477)", function()
  load_strata()
  local nan, inf = 0 / 0, math.huge
  assert_engine_rejects("finite", "setFilter", nan, 0.5, 0, 1)
  assert_engine_rejects("finite", "setDelay", nan, nan, nan, nan)
  assert_engine_rejects("finite", "recordBuffer", 0, nan, 1, 0, 0, 0, 0, 0, 0)
  assert_engine_rejects("finite", "voiceOn", 0, nan, 0.3, 0, 0.1, 20, 1)
  assert_engine_rejects("finite", "setVoiceParam", 0, "freq", inf)
  assert_engine_rejects("finite", "setGrainParam", 0, "bufPos", nan)
  assert_engine_rejects("finite", "retrigger", 0, nan)
  assert_engine_rejects("finite", "setMasterDrift", -inf)
  assert_engine_rejects("finite", "loadBuffer", 0, "/tmp/x.wav", inf)
  assert_engine_rejects("integer", "voiceOff", inf)
  assert_engine_rejects("integer", "setScale", 0, nan)
  engine.setFilter(5000, 0.5, 0, 1); engine.setMasterDrift(0.2)
end)

-- Continuous limits come from where the engine enforces them: a control its
-- FX SynthDef clips (feedback.clip(0, 0.95), freq.lag(0.05).clip(20, 20000))
-- or an argument the command clips (msg[2].clip(0, 1)). The engine clips no
-- crossmod depth or mod speed itself; AGENTS.md's command table documents
-- their ranges, and the stub reads them from the spec of the Lua param that
-- sends the value.
test("the engine stub range-checks continuous arguments at the engine's own limits (#51)", function()
  load_strata()
  local limits = engine_spec.argument_limits
  local unpack_args = table.unpack or unpack
  -- base_args with argument `index` set to `value`
  local function args_with(base_args, index, value)
    local args = { unpack_args(base_args) }
    args[index] = value
    return unpack_args(args)
  end
  local function check_limits(command, base_args, index, name, low, high)
    assert_engine_rejects(name, command, args_with(base_args, index, high + 1e-6))
    assert_engine_rejects(name, command, args_with(base_args, index, low - 1e-6))
    engine[command](args_with(base_args, index, low)); engine[command](args_with(base_args, index, high))
  end
  local function engine_limit(command, index, name)
    local limit = limits[command] and limits[command][index]
    assert_true(limit ~= nil, "engine." .. command .. " argument " .. index .. " (" .. name .. ") has a limit")
    assert_true(limit.name == name, "engine." .. command .. " argument " .. index .. " is " .. name)
    return limit.low, limit.high
  end
  check_limits("setFilter", {5000, 0.5, 0, 0}, 1, "freq", engine_limit("setFilter", 1, "freq"))
  check_limits("setFilter", {5000, 0.5, 0, 0}, 2, "res", engine_limit("setFilter", 2, "res"))
  check_limits("setFilter", {5000, 0.5, 0, 0}, 4, "mix", engine_limit("setFilter", 4, "mix"))
  check_limits("setDelay", {0.375, 0.4, 0, 0}, 1, "time", engine_limit("setDelay", 1, "time"))
  check_limits("setDelay", {0.375, 0.4, 0, 0}, 2, "feedback", engine_limit("setDelay", 2, "feedback"))
  check_limits("setDelay", {0.375, 0.4, 0, 0}, 3, "mix", engine_limit("setDelay", 3, "mix"))
  check_limits("setDelay", {0.375, 0.4, 0, 0}, 4, "pingPong", engine_limit("setDelay", 4, "pingPong"))
  check_limits("retrigger", {0, 1}, 2, "velocity", engine_limit("retrigger", 2, "velocity"))
  -- the limits follow the engine source
  local source = engine_sources()
  local patched, count = source:gsub("feedback%.clip%(0, 0%.95%)", "feedback.clip(0, 0.5)")
  assert_equal(count, 1, "feedback patch applies")
  patched, count = patched:gsub("velocity = msg%[2%]%.clip%(0, 1%)", "velocity = msg[2].clip(0, 0.8)")
  assert_equal(count, 1, "velocity patch applies")
  local patched_limits = stubs.engine_spec_from_source(patched).argument_limits
  assert_equal(patched_limits.setDelay[2].high, 0.5, "the delay feedback limit is read from \\strataDelay")
  assert_equal(patched_limits.retrigger[2].high, 0.8, "the velocity limit is read from \\retrigger")
  -- documented, not clipped: the Lua param's controlspec, which AGENTS.md's row states
  local file = assert(io.open(repo_root .. "/AGENTS.md", "r")); local doc = file:read("*a"); file:close()
  local documented = {
    { command = "setModAmpAmt", args = {6, 3, 0}, index = 3, param = "v7_mod_amp_amt_3", range = "%g to %g" },
    { command = "setModFreqAmt", args = {0, 1, 0}, index = 3, param = "v1_mod_freq_amt_1", range = "%g to %g" },
    { command = "setModSpeed", args = {2, 10}, index = 2, param = "v3_mod_speed", range = "%g-%g" },
  }
  for _, entry in ipairs(documented) do
    local spec = params:lookup_param(entry.param).controlspec
    check_limits(entry.command, entry.args, entry.index, entry.param, spec.minval, spec.maxval)
    local row = doc:match("\n| `engine%." .. entry.command .. "%(.-\n")
    assert_true(row and row:find(string.format(entry.range, spec.minval, spec.maxval), 1, true),
      "AGENTS.md documents engine." .. entry.command .. "'s range as " .. entry.param .. "'s spec")
  end
end)

test("the engine stub rejects param names the SynthDefs do not have (#24)", function()
  load_strata()
  local spec = stubs.parse_engine_spec(engine_sources())
  -- ratio is a strataFM control (voice 1), not one of strataResonator (voice 0)
  assert_engine_rejects("ratio", "setVoiceParam", 0, "ratio", 1.5)
  engine.setVoiceParam(1, "ratio", 1.5)
  -- (3.8) on FM's type, voice 0 takes it
  engine.setVoiceType(0, 1)
  engine.setVoiceParam(0, "ratio", 1.5)
  assert_engine_rejects("nonsense", "setVoiceParam", 0, "nonsense", 1)
  for engine_voice = 0, spec.num_voices - 1 do engine.setVoiceParam(engine_voice, "bend", 1) end
  -- grain params: either grain SynthDef's controls (kept for a source switch) plus the handlers' (history)
  assert_engine_rejects("ratio", "setGrainParam", 0, "ratio", 1)
  assert_engine_rejects("grainsize", "setGrainParam", 0, "grainsize", 0.1)
  engine.setGrainParam(0, "bufPos", 0.5); engine.setGrainParam(0, "grainSize", 0.1)
  engine.setGrainParam(0, "history", 0); engine.setGrainParam(0, "windowShape", 0.57)
end)

test("AGENTS.md is the only agent instructions file", function()
  local agents = io.open(repo_root .. "/AGENTS.md", "r")
  assert_true(agents ~= nil, "AGENTS.md is at the repository root")
  if agents then agents:close() end
  local old = io.open(repo_root .. "/CLAUDE.md", "r")
  if old then old:close() end
  assert_true(old == nil, "CLAUDE.md is gone: the instructions live in AGENTS.md alone")
end)

-- Every agent loads all of AGENTS.md, so it stays an index: a rule there is
-- a line or two naming the notes file that holds the detail. The limit is
-- in words as `wc -w` counts them (the file says the same number)
local AGENTS_WORD_LIMIT = 8000
test("AGENTS.md stays within its word budget", function()
  local file = assert(io.open(repo_root .. "/AGENTS.md", "r")); local doc = file:read("*a"); file:close()
  local words = 0
  for _ in doc:gmatch("%S+") do words = words + 1 end
  assert_true(words <= AGENTS_WORD_LIMIT, "AGENTS.md has " .. words .. " words, over its budget of " .. AGENTS_WORD_LIMIT
    .. ": move detail to the module's notes file and keep the rule's line")
  local stated = doc:match("a test fails above ([%d,]+) words")
  assert_equal(stated and tonumber((stated:gsub(",", ""))), AGENTS_WORD_LIMIT, "the budget AGENTS.md states")
end)

test("AGENTS.md command table lists exactly the engine's commands", function()
  local file = assert(io.open(repo_root .. "/AGENTS.md", "r")); local doc = file:read("*a"); file:close()
  -- table rows: | `engine.<name>(<args>)` | `"<signature>"` | purpose |
  local rows = {}
  for line in doc:gmatch("[^\n]+") do
    local name, args, signature = line:match('^| `engine%.(%w+)%((.-)%)` | `"(%a*)"` |')
    if name then
      assert_true(rows[name] == nil, "AGENTS.md documents engine." .. name .. " twice")
      local arg_count = 0
      if args:match("%S") then arg_count = select(2, args:gsub(",", ",")) + 1 end
      rows[name] = { signature = signature, arg_count = arg_count }
    end
  end
  for name, signature in pairs(signatures) do
    local row = rows[name]
    assert_true(row ~= nil, "AGENTS.md command table documents engine." .. name)
    assert_equal(row.signature, signature, "AGENTS.md signature of engine." .. name)
    assert_equal(row.arg_count, #signature, "AGENTS.md argument count of engine." .. name)
  end
  for name in pairs(rows) do
    assert_true(signatures[name] ~= nil, "AGENTS.md command table lists engine." .. name .. ", which the engine does not have")
  end
  -- no engine command mentioned anywhere in AGENTS.md, README.md,
  -- ROADMAP.md, docs/status.md, the other docs/*.md, docs/decisions or
  -- docs/notes is gone
  local doc_names = maintained_docs()
  for _, note in ipairs({"ROADMAP.md", "docs/status.md", "docs/checks.md", "docs/workflow.md", "docs/history.md",
      "docs/decisions/README.md", "docs/decisions/3.4.md", "docs/notes/test-harness.md",
      "docs/notes/test-harness/run-and-helpers.md", "docs/notes/engine/structure.md",
      "docs/notes/lua/state-and-voices.md"}) do
    local listed = false
    for _, doc_name in ipairs(doc_names) do listed = listed or doc_name == note end
    assert_true(listed, "the check reads " .. note)
  end
  for _, doc_name in ipairs(doc_names) do
    file = assert(io.open(repo_root .. "/" .. doc_name, "r")); local text = file:read("*a"); file:close()
    for name in text:gmatch("engine%.(%w+)%(") do
      assert_true(signatures[name] ~= nil, doc_name .. " mentions engine." .. name .. ", which the engine does not have")
    end
  end
end)

-- #808: AGENTS.md's guarded-commands sentence names exactly the commands
-- whose handler refuses a bad value with one line through a guard helper:
-- a call in the addCommand's function, or in an engine method that
-- function calls (this.<method> or areaCall(\<method>), one level down, as
-- setTuning's handler reaches postTuningIgnored)
local GUARDED_COMMANDS = {
  helpers = { "fastModIndicesValid", "fastModValuesFinite", "postTuningIgnored" },
}
function GUARDED_COMMANDS.block_at(text, open)
  local depth = 0
  for index = open, #text do
    local char = text:sub(index, index)
    if char == "{" then depth = depth + 1
    elseif char == "}" then depth = depth - 1; if depth == 0 then return text:sub(open, index) end end
  end
  return ""
end
function GUARDED_COMMANDS.scan(source)
  local function method_body(name)
    local at = source:find("\n%s+" .. name .. "%s*{")
    return at and GUARDED_COMMANDS.block_at(source, source:find("{", at, true)) or ""
  end
  local found = {}
  for start, name in source:gmatch("()this%.addCommand%(\\(%w+)") do
    local block = GUARDED_COMMANDS.block_at(source, source:find("{", start, true))
    local text = block
    for called in block:gmatch("this%.([%a_][%w_]*)") do text = text .. method_body(called) end
    for called in block:gmatch("areaCall%(\\([%a_][%w_]*)") do text = text .. method_body(called) end
    for _, helper in ipairs(GUARDED_COMMANDS.helpers) do
      if text:find("this%." .. helper .. "%(") then found[name] = true end
    end
  end
  return found
end

test("AGENTS.md's guarded commands are the commands whose handlers call a guard helper (#808)", function()
  local planted = GUARDED_COMMANDS.scan(table.concat({
    "    this.addCommand(\\direct, \"i\", { arg msg; if (this.fastModIndicesValid(\\direct, [])) { } });",
    "    this.addCommand(\\viaMethod, \"i\", { arg msg; this.checkIt(msg[1]) });",
    "    this.addCommand(\\viaAreaCall, \"i\", { arg msg; this.areaCall(\\checkThat, msg[1]) });",
    "    this.addCommand(\\plain, \"i\", { arg msg; this.other(msg[1]) });",
    "    checkIt { arg value; ^this.postTuningIgnored(\\viaMethod, \"why\") }",
    "    checkThat { arg value; this.fastModValuesFinite(\\viaAreaCall, []) }",
    "    other { arg value; ^value }",
  }, "\n"))
  local planted_names = {}
  for name in pairs(planted) do planted_names[#planted_names + 1] = name end
  table.sort(planted_names)
  assert_equal(table.concat(planted_names, " "), "direct viaAreaCall viaMethod", "the scan finds a guard in the handler and one method down")
  local guarded = GUARDED_COMMANDS.scan(stubs.strip_sc_comments(engine_sources()))
  local file = assert(io.open(repo_root .. "/AGENTS.md", "r")); local doc = file:read("*a"); file:close()
  local sentence = doc:match("\n%*%*Guarded commands%*%*[^\n]*")
  assert_true(sentence ~= nil, "AGENTS.md has the guarded-commands sentence")
  local listed, problems = {}, {}
  for name in (sentence or ""):match("%):(.*)$"):gmatch("`(%w+)`") do listed[name] = true end
  for name in pairs(guarded) do
    if not listed[name] then problems[#problems + 1] = name .. " is guarded but not in the sentence" end
  end
  for name in pairs(listed) do
    if not guarded[name] then problems[#problems + 1] = name .. " is in the sentence but its handler calls no guard helper" end
  end
  table.sort(problems)
  assert_equal(table.concat(problems, "; "), "", "the guarded-commands sentence against the engine's handlers")
end)

test("every repo path the maintained docs name exists (#52)", function()
  local checked = 0
  for _, doc_name in ipairs(maintained_docs()) do
    local file = assert(io.open(repo_root .. "/" .. doc_name, "r")); local text = file:read("*a"); file:close()
    local missing, count = doc_paths_missing(text, doc_name)
    checked = checked + count
    if #missing > 0 then fail(doc_name .. " names " .. missing[1] .. ", which does not exist") end
  end
  assert_true(checked > 0, "the check finds the paths the docs name")
end)

test("the docs path check resolves links from the doc's folder", function()
  local missing = doc_paths_missing("[top](README.md) and [ok](../../README.md)", "docs/user/arc.md")
  assert_equal(table.concat(missing, " "), "README.md", "a root-relative link in docs/user is reported")
  missing = doc_paths_missing("[top](README.md)", "docs/notes/engine/structure.md")
  assert_equal(#missing, 1, "a notes file may not link the root that way")
  -- a link with an #anchor: its file is checked, and the anchor against the
  -- file's headings (GitHub's anchors) (#489)
  local checked
  missing, checked = doc_paths_missing("[gone](no-such-page.md#section)", "docs/user/arc.md")
  assert_equal(table.concat(missing, " "), "no-such-page.md#section", "an anchored link to a missing file")
  assert_equal(checked, 1, "is checked")
  missing = doc_paths_missing("[ok](effects.md#bypass), [ok](effects.md#each-voices-filter-and-sends) and "
    .. "[bad](effects.md#no-such-heading)", "docs/user/params.md")
  assert_equal(table.concat(missing, " "), "effects.md#no-such-heading", "an anchor the file has no heading for")
  -- backticked changes/ paths and the repo's root files
  missing, checked = doc_paths_missing("`changes/README.md`, `changes/no-such-fragment.md`, `README.md`, "
    .. "`CLAUDE.md`, `strata.lua` and `voice.md`", "docs/notes/lua/x.md")
  assert_equal(table.concat(missing, " "), "changes/no-such-fragment.md CLAUDE.md", "the missing ones are reported")
  assert_equal(checked, 5, "a page's bare name (voice.md) is no root file")
end)

test("the docs path check covers lib/ paths", function()
  local missing, checked = doc_paths_missing("see `lib/missing.lua`, `lib/Engine_Strata.sc` and `lib/x`, not lib/bare.lua")
  assert_equal(table.concat(missing, " "), "lib/missing.lua lib/x", "the missing lib/ paths are reported")
  assert_equal(checked, 3, "every backticked lib/ path is checked")
end)

-- Each fragment in changes/ (README.md aside) must hold a ### Added,
-- ### Changed or ### Fixed heading with a bullet under it. Returns the
-- problem, or nil when the text is a valid fragment
local function fragment_problem(text)
  local under_heading, found = false, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^### ") then
      under_heading = line:match("^### Added%s*$") or line:match("^### Changed%s*$") or line:match("^### Fixed%s*$")
    elseif under_heading and line:match("^%s*[-*] %S") then
      found = true
    end
  end
  if not found then return "no bullet under ### Added, ### Changed or ### Fixed" end
end

test("every changelog fragment has a heading and a bullet under it", function()
  local listing = io.popen('ls -1 "' .. repo_root .. '/changes" 2>/dev/null')
  for name in listing:read("*a"):gmatch("[^\n]+") do
    if name ~= "README.md" then
      local file = assert(io.open(repo_root .. "/changes/" .. name, "r")); local text = file:read("*a"); file:close()
      local problem = fragment_problem(text)
      if problem then fail("changes/" .. name .. ": " .. problem) end
    end
  end
  listing:close()
  assert_true(fragment_problem("### Added\n- one\n") == nil, "a valid fragment passes")
  assert_true(fragment_problem("Added some things\n- one\n") ~= nil, "no heading fails")
  assert_true(fragment_problem("### Added\nno bullet\n") ~= nil, "no bullet fails")
  assert_true(fragment_problem("### Other\n- one\n") ~= nil, "another heading fails")
end)

-- The .md files under `dir` (repo-relative), recursively, sorted, as
-- repo-relative paths
local function markdown_files(dir)
  local listing = io.popen('cd "' .. repo_root .. '" && find "' .. dir .. '" -name "*.md" 2>/dev/null')
  local found = {}
  for path in listing:read("*a"):gmatch("[^\n]+") do table.insert(found, (path:gsub("^%./", ""))) end
  listing:close()
  table.sort(found)
  return found
end

local function read_repo_file(path)
  local file = assert(io.open(repo_root .. "/" .. path, "r")); local text = file:read("*a"); file:close()
  return text
end

test("every docs/notes/lua and test-harness file opens with a Must not break section", function()
  local files = markdown_files("docs/notes/lua")
  local harness = markdown_files("docs/notes/test-harness")
  assert_true(#harness >= 5, "the check reads the test harness's notes (" .. #harness .. " found)")
  for _, path in ipairs(harness) do table.insert(files, path) end
  table.insert(files, "docs/notes/test-harness.md")
  local nested = 0
  for _, path in ipairs(files) do
    if path:match("^docs/notes/lua/.+/") then nested = nested + 1 end
    local heading, in_fence = nil, false
    for line in (read_repo_file(path) .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%s*```") then in_fence = not in_fence
      elseif not in_fence and line:match("^#+ ") then heading = line; break end
    end
    assert_equal(heading, "## Must not break", path .. " first heading")
  end
  -- the per-page and per-layout notes (docs/notes/lua/pages/, grid/) count
  assert_true(nested >= 12, "the check reads the notes in subfolders (" .. nested .. " found)")
end)

test("every user page and grid layout doc is linked from its index", function()
  local indexes = { pages = "docs/user/controls.md", grid = "docs/user/grid.md" }
  local expected = { pages = 8, grid = 4 }
  for folder, index in pairs(indexes) do
    local index_text = read_repo_file(index)
    local files = markdown_files("docs/user/" .. folder)
    assert_true(#files >= expected[folder], #files .. " docs in docs/user/" .. folder .. "/")
    for _, path in ipairs(files) do
      -- linked by its path below docs/user/ (3.8: grid/pages/<name>.md)
      local link = "(" .. path:sub(#"docs/user/" + 1) .. ")"
      assert_true(index_text:find(link, 1, true), index .. " links " .. path)
    end
  end
end)

-- The user-facing sentences that say "freeze" (or frozen, unfrozen, ...)
-- for the lock: every sentence (split at . ! ? followed by a space, and at
-- line ends) holding such a word and also "lock", "[L]", "params" or
-- "values", unless it contrasts the two ("unlike"). Freeze is 3.2's audio
-- freeze; the lock keeps a voice's values
local function freeze_lock_sentences(text)
  local found = {}
  local lowered = text:lower():gsub("[%.!?]%s+", "\n")
  for sentence in (lowered .. "\n"):gmatch("([^\n]*)\n") do
    local says_freeze = sentence:find("%a*freez%a*") or sentence:find("%a*froz%a*")
    local says_lock = sentence:find("lock", 1, true) or sentence:find("[l]", 1, true)
      or sentence:find("params", 1, true) or sentence:find("values", 1, true)
    if says_freeze and says_lock and not sentence:find("unlike", 1, true) then
      table.insert(found, sentence)
    end
  end
  return found
end

test("the user docs never say freeze for lock", function()
  local planted = freeze_lock_sentences("Freeze a voice to keep its values safe from randomize. "
    .. "Unlike lock, freeze holds the audio itself. Frozen grains keep playing.\nLocked voices keep their params.")
  assert_equal(#planted, 1, "one bad sentence found")
  assert_true(planted[1]:find("keep its values", 1, true), "the bad one: " .. tostring(planted[1]))
  local files = markdown_files("docs/user")
  table.insert(files, "README.md")
  for _, path in ipairs(files) do
    local sentences = freeze_lock_sentences(read_repo_file(path))
    assert_true(#sentences == 0, path .. " says freeze for lock: '" .. tostring(sentences[1]) .. "'")
  end
  -- MAIN's page names both marks
  local main = read_repo_file("docs/user/pages/main.md"):lower():gsub("[%.!?]%s+", "\n")
  local lock_mark, freeze_mark
  for sentence in (main .. "\n"):gmatch("([^\n]*)\n") do
    if sentence:find("`[l]`", 1, true) and sentence:find("lock", 1, true) then lock_mark = true end
    if sentence:find("`[f]`", 1, true) and sentence:find("froz", 1, true) then freeze_mark = true end
  end
  assert_true(lock_mark, "docs/user/pages/main.md describes [L] as lock")
  assert_true(freeze_mark, "docs/user/pages/main.md describes [F] as freeze")
end)

-- The names (without extension) of the files in a repo folder that end in
-- `extension`, sorted
local function names_in(dir, extension)
  local names = {}
  local listing = io.popen('ls -1 "' .. repo_root .. "/" .. dir .. '" 2>/dev/null')
  for name in listing:read("*a"):gmatch("[^\n]+") do
    local base = name:match("^(.+)%." .. extension .. "$")
    if base then table.insert(names, base) end
  end
  listing:close()
  table.sort(names)
  return names
end

-- The engine check's runner and its area files (3.2 Wave 0b)
local ENGINE_CHECK_AREA_ORDER = { "structure", "voices", "grains", "lifecycle", "memory", "buffers", "files",
  "effects", "delay", "shimmer", "mix", "performance", "rings", "freeze", "variation", "tuning", "loops", "record", "waveform", "positions", "modulation",
  "envelopes", "notes", "onsets", "types", "outrings", "soak" }

-- The areas the runner runs only when STRATA_ENGINE_CHECK_AREAS names them
-- (its onDemandAreas: the soak, #131), as a set
local function on_demand_areas()
  local runner = stubs.strip_sc_comments(read_repo_file("test/engine_check.scd"))
  local list = runner:match("var%s+onDemandAreas%s*=%s*(%b[])")
  assert_true(list ~= nil, "test/engine_check.scd declares onDemandAreas")
  local names = {}
  for name in list:gmatch("\\(%w+)") do names[name] = true end
  return names
end

test("every engine notes file opens with Must not break", function()
  local files = markdown_files("docs/notes/engine")
  for _, path in ipairs(files) do
    local heading, in_fence = nil, false
    for line in (read_repo_file(path) .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%s*```") then in_fence = not in_fence
      elseif not in_fence and line:match("^#+ ") then heading = line; break end
    end
    assert_equal(heading, "## Must not break", path .. " first heading")
  end
  assert_true(#files >= 9, "docs/notes/engine holds the area notes (found " .. #files .. ")")
end)

test("AGENTS.md names the engine notes files", function()
  local instructions = read_repo_file("AGENTS.md")
  for _, name in ipairs(names_in("docs/notes/engine", "md")) do
    assert_true(instructions:find("`docs/notes/engine/" .. name .. ".md`", 1, true) ~= nil,
      "AGENTS.md names docs/notes/engine/" .. name .. ".md")
  end
  assert_true(instructions:find("STRATA_ENGINE_CHECK_AREAS", 1, true) ~= nil, "AGENTS.md names STRATA_ENGINE_CHECK_AREAS")
end)

-- Both ways (#155): every area has its notes file, and every notes file
-- belongs to an area. An on-demand area (the soak) tests other areas'
-- code: it has no notes file and is documented where it is run (next test)
test("the engine check areas and the engine notes files match one to one", function()
  local notes, areas, on_demand = {}, {}, on_demand_areas()
  local note_names, area_names = names_in("docs/notes/engine", "md"), names_in("test/engine_check", "scd")
  for _, name in ipairs(note_names) do notes[name] = true end
  for _, name in ipairs(area_names) do areas[name] = true end
  assert_true(#area_names >= 9, "test/engine_check holds the area files (found " .. #area_names .. ")")
  for _, name in ipairs(area_names) do
    if not on_demand[name] then
      assert_true(notes[name], "test/engine_check/" .. name .. ".scd has docs/notes/engine/" .. name .. ".md")
    end
  end
  for _, name in ipairs(note_names) do
    assert_true(areas[name], "docs/notes/engine/" .. name .. ".md has test/engine_check/" .. name .. ".scd")
  end
end)

-- An on-demand area has a file, runs last in the fixed order, and the docs
-- say how to run it (docs/checks.md, and the engine notes)
test("every on-demand engine check area is documented and has a file (#131)", function()
  local on_demand, count = on_demand_areas(), 0
  local checks = read_repo_file("docs/checks.md")
  local files_notes = read_repo_file("docs/notes/engine/files.md")
  local seen_on_demand = false
  for _, name in ipairs(ENGINE_CHECK_AREA_ORDER) do
    if on_demand[name] then seen_on_demand = true
    else assert_true(not seen_on_demand, name .. " runs after an on-demand area") end
  end
  for name in pairs(on_demand) do
    count = count + 1
    local file = io.open(repo_root .. "/test/engine_check/" .. name .. ".scd", "r")
    assert_true(file ~= nil, "on-demand area " .. name .. " has test/engine_check/" .. name .. ".scd")
    if file then file:close() end
    local run = "STRATA_ENGINE_CHECK_AREAS=" .. name
    assert_true(checks:find(run, 1, true) ~= nil, "docs/checks.md says how to run " .. name .. " (" .. run .. ")")
    assert_true(files_notes:find(run, 1, true) ~= nil, "docs/notes/engine/files.md says how to run " .. name)
  end
  assert_true(count >= 1, "the runner names its on-demand areas (the soak)")
end)

test("the runner's area order names every area file", function()
  local runner = stubs.strip_sc_comments(read_repo_file("test/engine_check.scd"))
  local list = runner:match("var%s+areaOrder%s*=%s*(%b[])")
  assert_true(list ~= nil, "test/engine_check.scd declares areaOrder")
  local order, position = {}, {}
  for name in list:gmatch("\\(%w+)") do
    table.insert(order, name)
    position[name] = #order
  end
  assert_equal(table.concat(order, " "), table.concat(ENGINE_CHECK_AREA_ORDER, " "), "the fixed area order")
  for _, name in ipairs(names_in("test/engine_check", "scd")) do
    assert_true(position[name] ~= nil, "areaOrder names test/engine_check/" .. name .. ".scd")
  end
end)

-- CI runs the engine check in parallel shards (.github/workflows/test.yml):
-- every area in exactly one, so none is skipped or run twice
test("CI's engine shards run every engine check area exactly once", function()
  local file = assert(io.open(repo_root .. "/.github/workflows/test.yml", "r")); local workflow = file:read("*a"); file:close()
  local listed = h.workflow_shards()
  assert_true(listed ~= nil, "the engine-shard matrix lists its areas")
  local seen, shards = {}, 0
  for _, shard in ipairs(listed) do
    shards = shards + 1
    for name in shard:gmatch("[^,]+") do
      assert_true(seen[name] == nil, name .. " is in two shards")
      seen[name] = shards
    end
  end
  assert_true(shards >= 2, "the check is sharded (" .. shards .. " shards)")
  -- the areas with a file (areaOrder may name one not written yet; the
  -- runner refuses a name with no file, so a shard may not list it). An
  -- on-demand area (the soak) is never in a shard: CI never runs it.
  local files, on_demand = {}, on_demand_areas()
  for _, name in ipairs(names_in("test/engine_check", "scd")) do
    files[name] = true
    if on_demand[name] then
      assert_true(not seen[name], name .. " runs on demand only, never in a CI shard")
    else
      assert_true(seen[name], name .. " (test/engine_check/" .. name .. ".scd) is in a shard")
    end
  end
  for name in pairs(seen) do assert_true(files[name], "shard area " .. name .. " has an area file") end
  -- the required check is still one job named engine, which needs every shard
  assert_true(workflow:find("\n  engine:\n    name: engine\n    needs: engine%-shard\n    if: always%(%)") ~= nil,
    "an engine job gathers the shards")
end)

test("every CI job has a timeout", function()
  local file = assert(io.open(repo_root .. "/.github/workflows/test.yml", "r")); local workflow = file:read("*a"); file:close()
  local jobs_text = workflow:match("\njobs:\n(.*)$")
  assert_true(jobs_text ~= nil, "the workflow has jobs")
  -- split the jobs at their two-space indent keys
  local jobs, order, current = {}, {}, nil
  for line in (jobs_text .. "\n"):gmatch("([^\n]*)\n") do
    local name = line:match("^  ([%w_%-]+):%s*$")
    if name then
      current = name; jobs[name] = {}; order[#order + 1] = name
    elseif current then
      local minutes = line:match("^    timeout%-minutes:%s*(%d+)%s*$")
      if minutes then jobs[current].minutes = tonumber(minutes) end
      jobs[current].text = (jobs[current].text or "") .. line .. "\n"
    end
  end
  -- lua-suite runs one shard of a Lua suite a runner, in parallel on its
  -- cores (3.8's package x5); lua gathers them, as engine gathers the shards
  local expected = { ["lua-suite"] = 12, lua = 5, ["engine-shard"] = 37, engine = 5 }
  for _, name in ipairs(order) do
    assert_true(jobs[name].minutes ~= nil, "job " .. name .. " has a timeout-minutes at its own indent")
    assert_true(expected[name] ~= nil, "job " .. name .. " has no expected timeout in this test")
    assert_equal(jobs[name].minutes, expected[name], "timeout-minutes of job " .. name)
  end
  for name in pairs(expected) do assert_true(jobs[name] ~= nil, "job " .. name .. " exists") end
  -- the required check is still one job named lua, which needs both suites
  -- and passes only when both passed
  assert_true(workflow:find("\n  lua:\n    name: lua\n    needs: lua%-suite\n    if: always%(%)") ~= nil,
    "a lua job gathers the suites")
  assert_true(jobs.lua.text:find('test "${{ needs.lua-suite.result }}" = success', 1, true) ~= nil,
    "the lua job fails unless every suite passed")
  assert_true(jobs["lua-suite"].text:find("lua: [lua5.3, luajit]", 1, true) ~= nil, "lua-suite runs Lua 5.3 and LuaJIT")
  assert_true(jobs["lua-suite"].text:find("${{ matrix.lua }} test/run.lua", 1, true) ~= nil, "each runs the suite")
  assert_true(jobs["lua-suite"].text:find("lua5.3 test/sync_check.lua", 1, true) ~= nil, "lua-suite runs the sync check")
  -- the shard's timeout covers its engine check plus setup (#790: the
  -- check's timeout has a kill-after)
  local seconds = tonumber(jobs["engine-shard"].text:match("name: Engine check\n%s+run:[^\n]-timeout %-%-kill%-after=%d+ (%d+) "))
  assert_true(seconds ~= nil, "the engine check step has a timeout in seconds")
  local setup_seconds = 180
  assert_true(seconds + setup_seconds <= jobs["engine-shard"].minutes * 60,
    "the shard's timeout covers its " .. seconds .. " s check plus " .. setup_seconds .. " s of setup")
end)

-- The workflow's jobs and their steps, as far as the tests below read them:
-- each job's name, timeout-minutes and steps; each step's text, name, id,
-- uses, timeout-minutes and whether it may fail (continue-on-error)
local CI_WORKFLOW = {}
function CI_WORKFLOW.jobs(workflow)
  local jobs, job, step = {}, nil, nil
  for line in ((workflow:match("\njobs:\n(.*)$") or "") .. "\n"):gmatch("([^\n]*)\n") do
    local job_name = line:match("^  ([%w_%-]+):%s*$")
    if job_name then
      job = { name = job_name, steps = {}, text = "" }; step = nil
      jobs[#jobs + 1] = job; jobs[job_name] = job
    elseif job then
      job.text = job.text .. line .. "\n"
      job.minutes = job.minutes or tonumber(line:match("^    timeout%-minutes:%s*(%d+)%s*$") or "")
      local first = line:match("^      %- (.*)$")
      if first then
        step = { text = "" }; job.steps[#job.steps + 1] = step
        line = "        " .. first
      end
      if step and not line:match("^%s*#") then
        step.text = step.text .. line .. "\n"
        local key, value = line:match("^        ([%w_%-]+):%s*(.-)%s*$")
        if key == "name" or key == "id" or key == "uses" then step[key] = value
        elseif key == "timeout-minutes" then step.minutes = tonumber(value)
        elseif key == "continue-on-error" then step.may_fail = value == "true" end
      end
    end
  end
  return jobs
end
-- the uses: lines that are not an action pinned by a full commit with its
-- version in a comment (#533)
function CI_WORKFLOW.unpinned_actions(text)
  local problems = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local reference = line:match("^%s*%-?%s*uses:%s*(.-)%s*$")
    if reference then
      local commit = reference:match("^[%w_.%-]+/[%w_.%-/]+@(%x+) # v%d+[%.%d]*$")
      if not commit or #commit ~= 40 then problems[#problems + 1] = reference end
    end
  end
  return problems
end

test("every action the workflow uses is pinned by a full commit, its version in a comment (#533)", function()
  local sample = table.concat({
    "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1",
    "        uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0",
    "      - uses: actions/cache@v6",
    "      - uses: actions/cache@55cc834 # v6.1.0",
    "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
  }, "\n")
  assert_equal(table.concat(CI_WORKFLOW.unpinned_actions(sample), " | "),
    "actions/cache@v6 | actions/cache@55cc834 # v6.1.0 | actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
    "a tag, a short commit and a commit with no version are found, and only those")
  local workflow = read_repo_file(".github/workflows/test.yml")
  assert_equal(table.concat(CI_WORKFLOW.unpinned_actions(workflow), " | "), "", "the workflow's unpinned actions")
end)

-- What is wrong with .github/dependabot.yml's text: it moves the action pins
-- above (#533) and nothing else, every action in one pull request (so the
-- cache steps stay one release of actions/cache), and never the Docker
-- image, whose Ubuntu must stay the runner's (the image's pins test)
function CI_WORKFLOW.dependabot_problems(text)
  local problems, ecosystems = {}, {}
  for ecosystem in text:gmatch("package%-ecosystem:%s*\"?([%w_%-]+)\"?") do ecosystems[#ecosystems + 1] = ecosystem end
  if not text:match("^version:%s*2%s*\n") then problems[#problems + 1] = "not version 2" end
  if table.concat(ecosystems, " ") ~= "github-actions" then
    problems[#problems + 1] = "ecosystems: " .. table.concat(ecosystems, " ")
  end
  if not text:match("\n%s+directory:%s*\"/\"%s*\n") then problems[#problems + 1] = "no directory \"/\"" end
  if not text:match("\n%s+interval:%s*\"?monthly\"?%s*\n") then problems[#problems + 1] = "not monthly" end
  if not text:match("\n%s+groups:%s*\n%s+[%w_%-]+:%s*\n%s+patterns:%s*\n%s+%-%s*\"%*\"%s*\n") then
    problems[#problems + 1] = "the actions are not one group"
  end
  if not text:match("\n%s+prefix:%s*\"ci\"%s*\n") then problems[#problems + 1] = "the commits are not ci:" end
  return problems
end

test("Dependabot moves only the action pins, every action in one pull request (#533)", function()
  local good = table.concat({
    "version: 2", "updates:", "  - package-ecosystem: \"github-actions\"", "    directory: \"/\"",
    "    schedule:", "      interval: \"monthly\"", "    groups:", "      actions:", "        patterns:",
    "          - \"*\"", "    commit-message:", "      prefix: \"ci\"", "",
  }, "\n")
  assert_equal(table.concat(CI_WORKFLOW.dependabot_problems(good), " | "), "", "a good file passes")
  local docker = good .. "  - package-ecosystem: \"docker\"\n    directory: \"/test/docker/sc313\"\n"
  assert_equal(table.concat(CI_WORKFLOW.dependabot_problems(docker), " | "), "ecosystems: github-actions docker",
    "the Docker image is refused")
  local ungrouped = good:gsub("    groups:\n      actions:\n        patterns:\n          %- \"%*\"\n", "")
  assert_equal(table.concat(CI_WORKFLOW.dependabot_problems(ungrouped), " | "), "the actions are not one group",
    "actions in separate pull requests are refused")
  local weekly = good:gsub("monthly", "weekly")
  assert_equal(table.concat(CI_WORKFLOW.dependabot_problems(weekly), " | "), "not monthly", "another interval is refused")
  local file = io.open(repo_root .. "/.github/dependabot.yml", "r")
  assert_true(file ~= nil, ".github/dependabot.yml exists")
  local text = file:read("*a"); file:close()
  assert_equal(table.concat(CI_WORKFLOW.dependabot_problems(text), " | "), "", ".github/dependabot.yml's problems")
end)

-- What is wrong with a shard list's text (the items between the brackets
-- of lua-suite's `shard: [...]` line): an item that is not "K/N", counts
-- that differ, a shard missing or repeated. Empty when it is 1/N .. N/N
function CI_WORKFLOW.shard_problems(list)
  local problems, seen, count, items = {}, {}, nil, 0
  for item in (list .. ","):gmatch("%s*([^,]-)%s*,") do
    items = items + 1
    local shard, of = item:match('^"(%d+)/(%d+)"$')
    shard, of = tonumber(shard), tonumber(of)
    if not shard then
      problems[#problems + 1] = "not a quoted K/N: " .. item
    else
      count = count or of
      if of ~= count then problems[#problems + 1] = "a shard of another count: " .. item end
      if seen[shard] then problems[#problems + 1] = "repeated: " .. item end
      seen[shard] = true
    end
  end
  if items == 0 or not count then return #problems > 0 and problems or { "no shard" } end
  for shard = 1, count do
    if not seen[shard] then problems[#problems + 1] = "missing: " .. shard .. "/" .. count end
  end
  for shard in pairs(seen) do
    if shard < 1 or shard > count then problems[#problems + 1] = "out of range: " .. shard .. "/" .. count end
  end
  return problems
end

-- 3.8's package x5: the Lua suite runs a job per interpreter and shard of
-- the unit files (test/run.lua --shard), each in parallel on its runner's
-- cores, gathered by the lua job; the sync check runs once a run
test("CI's Lua suite jobs run each shard of the unit files under each interpreter, the sync check once", function()
  for _, case in ipairs({ { '"1/1"', "" }, { '"1/2", "2/2"', "" }, { '"2/3", "1/3", "3/3"', "" },
      { '"1/2"', "missing: 2/2" }, { '"1/2", "1/2", "2/2"', "repeated: \"1/2\"" }, { '"1/2", "2/3"', "a shard of another count: \"2/3\"" },
      { '1/1', "not a quoted K/N: 1/1" }, { '"0/1", "1/1"', "out of range: 0/1" }, { "", "not a quoted K/N: " } }) do
    assert_equal(table.concat(CI_WORKFLOW.shard_problems(case[1]), " | "), case[2], "the shard list " .. case[1])
  end
  local workflow = read_repo_file(".github/workflows/test.yml")
  local jobs = CI_WORKFLOW.jobs(workflow)
  local suite = jobs["lua-suite"]
  local list = suite.text:match("\n        shard:%s*%[([^%]\n]*)%]%s*\n")
  assert_true(list ~= nil, "lua-suite's matrix names its shards on one line (shard: [...])")
  assert_equal(table.concat(CI_WORKFLOW.shard_problems(list or ""), " | "), "", "the shards are 1/N .. N/N, each once")
  assert_true(suite.text:find("\n      fail%-fast: false\n") ~= nil, "a failing job never cancels the others")
  local runs, sync_steps, cores = 0, {}, false
  for _, job in ipairs(jobs) do
    for _, step in ipairs(job.steps) do
      if step.text:find("test/sync_check.lua", 1, true) then sync_steps[#sync_steps + 1] = { job = job.name, step = step } end
      if job.name == "lua-suite" and step.text:find("\n%s+run: nproc\n") then cores = true end
      if step.text:find("test/run.lua", 1, true) then
        runs = runs + 1
        assert_equal(job.name, "lua-suite", "only lua-suite runs the Lua suite")
        assert_true(step.text:find("run: ${{ matrix.lua }} test/run.lua --shard ${{ matrix.shard }}\n", 1, true) ~= nil,
          "each job runs its shard, on the runner's cores (no --jobs): " .. step.text)
      end
    end
  end
  assert_equal(runs, 1, "one step runs the suite")
  assert_true(cores, "lua-suite prints the runner's cores (nproc) before the suite")
  -- the sync check: one step, run by the Lua 5.3 job of the first shard only
  assert_equal(#sync_steps, 1, "one step runs the sync check")
  assert_equal(sync_steps[1] and sync_steps[1].job, "lua-suite", "lua-suite runs the sync check")
  assert_true(sync_steps[1] and sync_steps[1].step.text:find("\n%s+if: matrix%.lua == 'lua5%.3' && startsWith%(matrix%.shard, '1/'%)\n"),
    "the sync check runs in the Lua 5.3 job of shard 1 only")
  assert_true(suite.text:find("\n        lua: [lua5.3, luajit]\n", 1, true) ~= nil, "one Lua 5.3 and one LuaJIT job a shard")
  -- the required lua job needs every job that runs the suite and passes only when each passed
  local lua = jobs.lua
  local needs = lua.text:match("\n    needs:%s*([^\n]+)\n") or ""
  local needed = {}
  for name in needs:gsub("[%[%]]", ""):gmatch("[%w_%-]+") do needed[name] = true end
  for _, job in ipairs(jobs) do
    if job.text:find("test/run.lua", 1, true) then
      assert_true(needed[job.name], "the lua job needs " .. job.name)
      assert_true(lua.text:find('test "${{ needs.' .. job.name .. '.result }}" = success', 1, true) ~= nil,
        "the lua job fails unless every " .. job.name .. " job passed")
    end
  end
  assert_true(lua.text:find("\n    if: always%(%)\n") ~= nil, "the lua job runs whatever the suites did")
end)

-- #785: a slow package mirror canceled three engine shards at the job's
-- limit while apt was still downloading. Every apt-get gives up on a dead
-- connection (APT_NETWORK_OPTIONS, apt's command line winning over the
-- runner's apt.conf.d), and every step that runs one has a limit of its own,
-- so a slow install fails by the step's name and the check keeps its 600 s
test("every apt-get in CI has retries and a stall limit, in a step with its own time limit (#785)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  local options = workflow:match("\nenv:\n.-\n  APT_NETWORK_OPTIONS:%s*([^\n]-)%s*\n")
  assert_true(options ~= nil, "the workflow's env sets APT_NETWORK_OPTIONS for every job")
  options = options or ""
  local retries = tonumber(options:match("%-o Acquire::Retries=(%d+)") or "")
  assert_true(retries ~= nil and retries >= 1 and retries <= 5, "a failed file is tried again, a few times: " .. options)
  for _, scheme in ipairs({ "http", "https" }) do
    local seconds = tonumber(options:match("%-o Acquire::" .. scheme .. "::Timeout=(%d+)") or "")
    assert_true(seconds ~= nil and seconds >= 5 and seconds <= 60, scheme .. " drops a stalled connection within a minute: " .. options)
  end
  local jobs, installing = CI_WORKFLOW.jobs(workflow), {}
  for _, job in ipairs(jobs) do
    local apt_seconds = 0
    for _, step in ipairs(job.steps) do
      local calls = 0
      for line in step.text:gmatch("[^\n]+") do
        if line:find("apt%-get ") then
          calls = calls + 1
          assert_true(line:find("apt-get $APT_NETWORK_OPTIONS ", 1, true) ~= nil,
            job.name .. "'s step " .. tostring(step.name) .. " runs apt-get without APT_NETWORK_OPTIONS: " .. line)
        end
      end
      if calls > 0 then
        assert_true(step.minutes ~= nil, job.name .. "'s step " .. tostring(step.name) .. " runs apt-get and has a timeout-minutes")
        assert_true((step.minutes or 0) < job.minutes, job.name .. "'s step " .. tostring(step.name) .. "'s limit is under the job's")
        apt_seconds = apt_seconds + (step.minutes or 0) * 60
        installing[job.name] = true
      end
    end
    if job.name == "engine-shard" then
      -- the installs' limits leave the check its own 600 s within the job's
      local kill, check = job.text:match("name: Engine check\n%s+run:[^\n]-timeout %-%-kill%-after=(%d+) (%d+) ")
      kill, check = tonumber(kill or ""), tonumber(check or "")
      assert_true(check ~= nil, "the engine check step has a timeout in seconds, with a --kill-after")
      assert_true(apt_seconds + (check or 0) <= job.minutes * 60,
        "the shard's installs (" .. apt_seconds .. " s) and its check (" .. tostring(check) .. " s) fit its " .. job.minutes .. " minutes")
      -- #786, #790: every step has a limit of its own (the checkouts, the
      -- cache's restore and save, JACK's start, the check and the refusal
      -- checks after it too), and the job's limit is their sum and the
      -- allowance for the runner's own steps, so a hung step fails by its
      -- own name, never by the job's limit
      local total, unlimited, check_step = CI_WORKFLOW.SECONDS.runner_steps, {}, nil
      for _, step in ipairs(job.steps) do
        if step.name == "Engine check" then check_step = step end
        if step.minutes then total = total + step.minutes * 60 else unlimited[#unlimited + 1] = tostring(step.name or step.uses) end
      end
      assert_equal(table.concat(unlimited, ", "), "", "the shard's steps with no timeout-minutes of their own")
      assert_equal(total, job.minutes * 60, "the shard's limit, in seconds, against its steps' limits and "
        .. CI_WORKFLOW.SECONDS.runner_steps .. " s for the runner's own steps")
      -- the check's timeout, and its kill of a process that ignores the
      -- signal, both land inside the check step's own limit
      assert_true(kill ~= nil and kill >= 1, "the check's timeout kills a process that ignores its signal (--kill-after)")
      assert_true(check_step and check_step.minutes and (check or 0) + (kill or 0) < check_step.minutes * 60,
        "the check's timeout (" .. tostring(check) .. " s) and its kill-after (" .. tostring(kill)
        .. " s) end inside the check step's " .. tostring(check_step and check_step.minutes) .. " minutes")
    end
    if job.name == "lua-suite" then
      -- #993: every step before the suite has a limit of its own, and those
      -- limits and the runner's own steps fit the job's, so a hung step of
      -- the setup fails by its own name before the job's limit. The suite
      -- has none: the job's limit is its own
      local total, unlimited, suite = CI_WORKFLOW.SECONDS.runner_steps, {}, false
      for _, step in ipairs(job.steps) do
        if step.name == "Behavior tests" then suite = true; break end
        if step.minutes then total = total + step.minutes * 60 else unlimited[#unlimited + 1] = tostring(step.name or step.uses) end
      end
      assert_true(suite, "the Lua job runs its Behavior tests step")
      assert_equal(table.concat(unlimited, ", "), "", "the Lua job's steps before the suite with no timeout-minutes of their own")
      assert_true(total <= job.minutes * 60, "the Lua job's setup limits and " .. CI_WORKFLOW.SECONDS.runner_steps
        .. " s for the runner's own steps (" .. total .. " s) fit its " .. job.minutes .. " minutes")
      -- A hit and a miss on a slow mirror, each with the slowest suite
      -- measured, fit the job's limit: the measured times of
      -- CI_WORKFLOW.SECONDS.lua, and from the workflow the list's two
      -- updates (#999: in both paths the first to its timeout and its kill,
      -- the second to its timeout, then the list's apt-cache work), the
      -- install's two tries (on a miss, the first to its timeout and its
      -- kill, the second to its timeout, then the refill and the unpacking)
      -- and the restore's limit (a hit whose restore hangs to it still
      -- fits). Not covered, each a fault on top of the slowest mirror and
      -- suite seen: on a miss, a cache service that hangs both the restore
      -- and the save to their limits (they only warn), or a list whose
      -- apt-cache work hangs to the step's own limit.
      -- The 471 s is shard 1's before #1001, when its time was
      -- ui_layout_test.lua's alone; #1001 split that file across both
      -- shards, and the job's limit stays until runs on the split rule on it
      local lua, limit, install, restore, list = CI_WORKFLOW.SECONDS.lua, job.minutes * 60, nil, nil, nil
      for _, step in ipairs(job.steps) do
        if step.name == "Install Lua 5.3 and LuaJIT" then install = step end
        if step.uses and step.uses:match("^actions/cache/restore@") then restore = step end
        if step.id == "packages" then list = step end
      end
      local tries = {}
      for kill, seconds in (install and install.text or ""):gmatch("sudo timeout %-%-kill%-after=(%d+) (%d+) apt%-get ") do
        tries[#tries + 1] = { kill = tonumber(kill), seconds = tonumber(seconds) }
      end
      assert_equal(#tries, 2, "the Lua install's download runs under a limit, and once more")
      assert_true(restore and restore.minutes, "the Lua job's restore has a limit")
      local updates = CI_WORKFLOW.update_tries(list)
      assert_equal(#updates, 2, "the Lua list's apt-get update runs under a limit, and once more (#999)")
      local slow_list = (updates[1] and updates[1].seconds + updates[1].kill + updates[2].seconds or 0) + CI_WORKFLOW.SECONDS.list_work
      local before = lua.checkout + slow_list
      local after = lua.after_downloads
      local hit = before + lua.restore + after + lua.suite + lua.runner_steps
      local hung_hit = before + restore.minutes * 60 + after + lua.suite + lua.runner_steps
      local miss = before + lua.restore + tries[1].seconds + tries[1].kill + tries[2].seconds + after + lua.save
        + lua.suite + lua.runner_steps
      for _, path in ipairs({ { "a hit", hit }, { "a hit whose restore hangs to its limit", hung_hit }, { "a miss", miss } }) do
        assert_true(path[2] <= limit, path[1] .. " on a slow mirror with the slowest suite measured (" .. lua.suite .. " s) takes "
          .. path[2] .. " s, over the Lua job's " .. job.minutes .. " minutes")
      end
    end
  end
  assert_true(installing["lua-suite"] and installing["engine-shard"], "both the Lua suites and the engine shards install with apt-get")
end)

-- #786: the engine shard's measured times (runs 44221169221, uncached with
-- the second mirror on three shards, and 44224340612, cached; seven shards
-- each) and the allowances the limits are sized with. After its downloads
-- the install refills the kept folder and unpacks: 23 s at most after the
-- second mirror's download, 28 s at most for a whole cached install; the
-- allowance is about twice that. #790: every step of the shard has a limit
-- of its own; the runner's own steps (set up job, the checkout's post step,
-- complete job), which no limit can name, took 6 s at most together in
-- five runs of seven shards (44367155756 to 44385889124); the allowance is
-- a minute.
-- #993: the Lua job's times, measured in 32 jobs of runs 45317374513,
-- 45318591229, 45318610201, 45318613190 and 45320574628 (every attempt,
-- before its packages were kept) where a figure says so, the others
-- allowances: the checkout 7 s at most; on a slow mirror the install's
-- `apt-get update` took 131 s from the step's start (run 45318610201,
-- 13.4 MB at 114 kB/s); #999: the list's updates now run under limits the
-- workflow sets, and its apt-cache work after the update took 2.1 to
-- 2.6 s (run 45327275355's Lua jobs; 3.2 to 4.2 s in the engine shards'
-- lists), allowed 5; the restore and the save of an entry under a
-- megabyte are allowed 10 s each (the shard's 111 MB restore took 10 s
-- at most); the refill and the unpacking 15 s (a fast mirror's whole
-- install, its update and download included, took 9 to 11 s); the
-- runner's own steps 3 s at most, allowed 6 as the shard's measure; the
-- slowest suite 471 s (run 45320574628 on main, lua (luajit, 1/2) on 4
-- cores: "60 unit files in 4 processes, 470 s"; shard 1 took 264 to 331 s
-- in every other job, shard 2 121 to 222 s)
CI_WORKFLOW.SECONDS = { after_downloads = 60, runner_steps = 60, list_work = 5,
  lua = { checkout = 7, restore = 10, save = 10, after_downloads = 15, runner_steps = 6, suite = 471 } }

-- #999: a list step's `apt-get update` runs, each with its limit and its
-- kill-after in seconds, in the order of the step's text (empty without a
-- step). #1005: with any options between the network options and update
-- (the pinned piece says which)
function CI_WORKFLOW.update_tries(step)
  local tries = {}
  for kill, seconds in (step and step.text or ""):gmatch("sudo timeout %-%-kill%-after=(%d+) (%d+) apt%-get %$APT_NETWORK_OPTIONS [^\n]-update") do
    tries[#tries + 1] = { kill = tonumber(kill), seconds = tonumber(seconds) }
  end
  return tries
end
-- #993: where a job's text is in the workflow's: from the newline before its
-- key line (`  <job>:`) to the newline before the next job's, or the end
function CI_WORKFLOW.job_span(text, job)
  local from = text:find("\n  " .. job .. ":\n", 1, true)
  if not from then return nil end
  local to = text:find("\n  [%w_%-]+:%s*\n", from + 1)
  return from, to or #text
end
-- #786: the workflow's text with `old` (found exactly once, so a mutation
-- never passes by missing its place) replaced by `new`. #993: with `job`,
-- `old` is found once in that job's text (two jobs keep their packages by
-- the same lines)
function CI_WORKFLOW.mutated(text, old, new, job)
  local from, to = 1, #text
  if job then
    from, to = CI_WORKFLOW.job_span(text, job)
    assert_true(from ~= nil, "the workflow has the job " .. job)
  end
  local region = text:sub(from, to)
  local at = region:find(old, 1, true)
  assert_true(at ~= nil and region:find(old, at + 1, true) == nil,
    "the mutation's text is in " .. (job and ("the job " .. job) or "the workflow") .. " once: " .. old)
  at = from + at - 1
  return text:sub(1, at - 1) .. new .. text:sub(at + #old)
end
-- a step's run script, one entry a command line: the lines under `run: |`
-- (or the one after `run:`), dedented, a line ending in a backslash joined
-- to the next unless `raw` (CI_WORKFLOW.jobs has already left out the
-- comment lines)
function CI_WORKFLOW.script(step, raw)
  local lines, indent, inside = {}, nil, false
  for line in step.text:gmatch("([^\n]*)\n") do
    local lead = line:match("^( *)%S")
    if inside then
      if lead and #lead <= 8 then break end
      if lead then
        indent = indent or #lead
        local text = (line:sub(indent + 1):gsub("%s+$", ""))
        local last = lines[#lines]
        if not raw and last and last:match("\\$") then lines[#lines] = (last:gsub("%s*\\$", " ")) .. (text:gsub("^%s+", ""))
        else lines[#lines + 1] = text end
      end
    else
      local run = line:match("^        run:%s*(.-)%s*$")
      if run == "|" then inside = true elseif run and run ~= "" then return { run } end
    end
  end
  return lines
end
-- a script line's commands (split at ;, &&, || and |), each without the
-- words before its command (if, then, do, sudo, ...)
function CI_WORKFLOW.commands(line)
  local commands = {}
  for command in (line:gsub("&&", "\1"):gsub("||", "\1"):gsub("[;|]", "\1") .. "\1"):gmatch("([^\1]*)\1") do
    command = command:match("^%s*(.-)%s*$")
    local stripped = true
    while stripped do
      stripped = false
      for _, word in ipairs({ "if", "then", "do", "else", "elif", "while", "until", "!", "sudo" }) do
        if command:sub(1, #word + 1) == word .. " " then command = command:sub(#word + 2):match("^%s*(.-)$"); stripped = true end
      end
    end
    if command ~= "" then commands[#commands + 1] = command end
  end
  return commands
end
-- whether a text names apt's archive folder (as the install's variable, by
-- its path or a part of it, so a path built through another variable counts
-- too, or as the setting that moves it, Dir::Cache, apt.conf(5))
function CI_WORKFLOW.names_archives(text)
  return text:find("$archives", 1, true) ~= nil or text:find("${archives}", 1, true) ~= nil
    or text:find("/archives", 1, true) ~= nil or text:find("cache/apt", 1, true) ~= nil
    or text:lower():find("dir::cache", 1, true) ~= nil
end
-- whether a command that names apt's archive folder puts nothing in it: the
-- folder's assignment, a test, or a cp into the kept folder (the refill)
function CI_WORKFLOW.leaves_archives(command)
  if command == "archives=/var/cache/apt/archives" or command:match("^%[ ") or command:match("^test ") then return true end
  local words = {}
  for word in command:gmatch("%S+") do words[#words + 1] = (word:gsub('"', "")) end
  if words[1] ~= "cp" then return false end
  for _, word in ipairs(words) do
    if word:match("^%-t") or word:match("^%-%-target") then return false end
  end
  return words[#words]:sub(1, #"$debs") == "$debs"
end
-- #786, #792: the pieces of the shard's scripts the cache's safety rests on,
-- pinned verbatim (dedented, trailing spaces dropped): any edit of them fails
-- the tests by its first changed line, and whoever changes one changes its
-- text here in the same commit, on purpose.
-- The making of the SHA512 list (the list step, from the empty dpkg status
-- to the list's write: every command name and sum come from): the sums are
-- the SHA512 fields of apt's own lists, whose signatures apt has checked, so
-- a kept file can only match what the archive published.
-- The verify-and-copy loop (the install step, from the kept folder's
-- assignment to the loop's done: every line the loop reads that this step
-- sets): a kept file is copied into apt's archive folder only inside the if
-- whose condition is its own check, so a damaged or altered file never
-- reaches apt, which takes any file of the right size there as downloaded.
-- The install step's start (#792, from the script's first line, which it
-- must be, to the kept folder's assignment, where the loop's piece starts):
-- nothing before the loop can shadow a command it runs (a function, an
-- alias or a PATH of its own for sha512sum)
-- #993: the Lua jobs keep their two packages by the same pieces, with their
-- own package names, kept folder and list (CI_WORKFLOW.CACHES).
-- #999: the list step's start, the same in both jobs (from the script's
-- first line, which it must be, to the update's last check): the update
-- runs under a limit, and when it is killed or fails it runs once more
-- with https://archive.ubuntu.com first in the runner's mirror list, by
-- the download retry's own sed; when neither try updates the lists, the
-- step fails by its ::error:: line before any list is read. So the SHA512
-- list is always made from lists this job's update fetched.
-- #1005: apt-get update exits 0 when a list fails with only a warning
-- (`W: Failed to fetch`), and leaves the old list in place. So both tries
-- read Ubuntu's sources file alone (the runner's third-party sources, which
-- these jobs install nothing from, fail nothing) with --error-on=any, so a
-- list of Ubuntu's that did not download exits 100, gets the retry through
-- the reorder and then fails by the ::error:: line; --no-list-cleanup
-- leaves the other sources' lists as they were. A sources file that is
-- missing or names nothing makes an update that reads nothing and exits 0,
-- so the step then checks that what the update read holds Ubuntu's main
-- and universe lists for the runner's release, and fails by its own
-- ::error:: line if not. (Whether a list is newer than the step's start
-- cannot tell: a list that was already current is a Hit, and apt leaves
-- its file's time as it was.)
CI_WORKFLOW.LIST_UPDATE = [==[
set -o pipefail
mirrors=/etc/apt/apt-mirrors.txt
ubuntu_only=(-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=-)
status=0
sudo timeout --kill-after=5 45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any --no-list-cleanup update || status=$?
if [ "$status" -ne 0 ] && grep -q '^https://archive\.ubuntu\.com/ubuntu/[[:space:]]' "$mirrors"; then
  echo "::warning::apt's update failed or was unfinished after 45 s (exit $status): trying https://archive.ubuntu.com first"
  sudo sed -i -E '/^https:\/\/archive\.ubuntu\.com\/ubuntu\//! s/priority:[0-9]+/priority:9/' "$mirrors"
  cat "$mirrors"
  status=0
  sudo timeout --kill-after=5 60 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any --no-list-cleanup update || status=$?
fi
if [ "$status" -ne 0 ]; then
  echo "::error::apt's lists did not update (exit $status; 124 or 137: too slow; 100: a list of Ubuntu's did not download, apt's E: lines above name it). Nothing was installed or checked: rerun this job"
  exit 1
fi
release=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release) || release=
targets=$(apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" indextargets --format '$(RELEASE) $(COMPONENT) $(CREATED_BY)') || targets=
for component in main universe; do
  if ! grep -qx "$release $component Packages" <<< "$targets"; then
    echo "::error::Ubuntu's $release $component list is not among the lists the update read: the SHA512 list would come from a stale one. Nothing was installed or checked"
    exit 1
  fi
done
]==]
CI_WORKFLOW.PINNED = {}
CI_WORKFLOW.PINNED["engine-shard"] = {
  { name = "list step's update", step = "list", first = "set -o pipefail", from_start = true, text = CI_WORKFLOW.LIST_UPDATE },
  { name = "install step's start", step = "install", first = 'echo "jackd2 ', from_start = true, text = [==[
echo "jackd2 jackd/tweak_rt_limits boolean false" | sudo debconf-set-selections
packages=(jackd2 "supercollider-language=$SC_APT_VERSION" "supercollider-server=$SC_APT_VERSION")
debs="$RUNNER_TEMP/sc-debs"
]==] },
  { name = "making of the SHA512 list", step = "list", first = ": > ", text = [==[
: > "$RUNNER_TEMP/empty-status"
nothing_installed=(-o Dir::State::status="$RUNNER_TEMP/empty-status")
apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" "${nothing_installed[@]}" install -s jackd2 \
    "supercollider-language=$SC_APT_VERSION" "supercollider-server=$SC_APT_VERSION" \
  | awk '/^Inst / { for (i = 3; i <= NF; i++) if (substr($i, 1, 1) == "(") { print $2 "=" substr($i, 2); break } }' \
  > "$RUNNER_TEMP/sc-install.txt"
xargs apt-cache "${ubuntu_only[@]}" "${nothing_installed[@]}" show < "$RUNNER_TEMP/sc-install.txt" \
  | awk -v native="$(dpkg --print-architecture)" \
      '/^Package: / { p = $2 } /^Version: / { v = $2 } /^Architecture: / { a = $2 } /^SHA512: / { s = $2 }
       /^$/ { if (s != "" && (a == native || a == "all")) { gsub(/:/, "%3a", v); print s "  " p "_" v "_" a ".deb" }; p = v = a = s = "" }' \
  | sort -u > "$RUNNER_TEMP/sc-packages.sha512"
]==] },
  { name = "verify-and-copy loop", step = "install", first = "debs=", text = [==[
debs="$RUNNER_TEMP/sc-debs"
archives=/var/cache/apt/archives
mirrors=/etc/apt/apt-mirrors.txt
mkdir -p "$debs"
kept=0
while read -r sum name; do
  if [ -f "$debs/$name" ] && echo "$sum  $debs/$name" | sha512sum --check --status; then
    sudo cp "$debs/$name" "$archives/"
    kept=$((kept + 1))
  fi
done < "$RUNNER_TEMP/sc-packages.sha512"
]==] },
}
CI_WORKFLOW.PINNED["lua-suite"] = {
  { name = "list step's update", step = "list", first = "set -o pipefail", from_start = true, text = CI_WORKFLOW.LIST_UPDATE },
  { name = "install step's start", step = "install", first = "packages=", from_start = true, text = [==[
packages=(lua5.3 luajit)
debs="$RUNNER_TEMP/lua-debs"
]==] },
  { name = "making of the SHA512 list", step = "list", first = ": > ", text = [==[
: > "$RUNNER_TEMP/empty-status"
nothing_installed=(-o Dir::State::status="$RUNNER_TEMP/empty-status")
apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" "${nothing_installed[@]}" install -s lua5.3 luajit \
  | awk '/^Inst / { for (i = 3; i <= NF; i++) if (substr($i, 1, 1) == "(") { print $2 "=" substr($i, 2); break } }' \
  > "$RUNNER_TEMP/lua-install.txt"
xargs apt-cache "${ubuntu_only[@]}" "${nothing_installed[@]}" show < "$RUNNER_TEMP/lua-install.txt" \
  | awk -v native="$(dpkg --print-architecture)" \
      '/^Package: / { p = $2 } /^Version: / { v = $2 } /^Architecture: / { a = $2 } /^SHA512: / { s = $2 }
       /^$/ { if (s != "" && (a == native || a == "all")) { gsub(/:/, "%3a", v); print s "  " p "_" v "_" a ".deb" }; p = v = a = s = "" }' \
  | sort -u > "$RUNNER_TEMP/lua-packages.sha512"
]==] },
  { name = "verify-and-copy loop", step = "install", first = "debs=", text = [==[
debs="$RUNNER_TEMP/lua-debs"
archives=/var/cache/apt/archives
mirrors=/etc/apt/apt-mirrors.txt
mkdir -p "$debs"
kept=0
while read -r sum name; do
  if [ -f "$debs/$name" ] && echo "$sum  $debs/$name" | sha512sum --check --status; then
    sudo cp "$debs/$name" "$archives/"
    kept=$((kept + 1))
  fi
done < "$RUNNER_TEMP/lua-packages.sha512"
]==] },
}
-- #993: the jobs that keep their packages between runs, each read by the
-- same checks: its install step's name, the step that runs what the job is
-- for (the save comes before it), its kept folder (under the runner's temp
-- folder), its SHA512 list (under the same) and the start of its cache
-- key, which neither job's key shares with the other's, so no restore-keys
-- of one ever restores the other's entry
CI_WORKFLOW.CACHES = {
  { job = "engine-shard", where = "the engine shard", install = "Install SuperCollider and JACK", suite = "Engine check",
    kept = "sc-debs", list = "sc-packages.sha512", prefix = "sc-debs-" },
  { job = "lua-suite", where = "the Lua job", install = "Install Lua 5.3 and LuaJIT", suite = "Behavior tests",
    kept = "lua-debs", list = "lua-packages.sha512", prefix = "lua-debs-" },
}
-- a cache's steps in its job (list, restore, install, save, suite: their
-- indexes), and the job
function CI_WORKFLOW.cache_steps(workflow, cache)
  local job = CI_WORKFLOW.jobs(workflow)[cache.job]
  if not job then return nil, {} end
  local at = {}
  for index, step in ipairs(job.steps) do
    if step.id == "packages" then at.list = index end
    if step.uses and step.uses:match("^actions/cache/restore@") then at.restore = index end
    if step.name == cache.install then at.install = index end
    if step.uses and step.uses:match("^actions/cache/save@") then at.save = index end
    if step.name == cache.suite then at.check = index end
  end
  return job, at
end
-- what breaks the cache's safety in a workflow's text, one line each: the
-- pinned pieces differ from their text (the first differing line); outside
-- them, a line of any step of the shard names apt's archive folder (by a
-- path, a part of one or Dir::Cache) other than to read it or to copy from
-- it into the kept folder, or writes the SHA512 list; the kept folder is not
-- the one the restore fills; the save is not the step right after the
-- install or runs on an exact hit; a pinned piece that must start the
-- script does not (#792); anything that can shadow a command the pinned
-- lines run (#792): a shell function or an alias in any step of the shard,
-- BASH_ENV anywhere in the workflow (bash runs its file before every step's
-- script), a write to GITHUB_PATH or a PATH written to GITHUB_ENV in any step
-- (both reach every later step), and a PATH key in the env of the workflow,
-- the shard job or any of its steps (#817). #993: so in each job of
-- CI_WORKFLOW.CACHES, each of its problems led by the job's name, and the
-- jobs' keys start apart
function CI_WORKFLOW.cache_problems(workflow)
  local problems, starts = {}, {}
  for _, cache in ipairs(CI_WORKFLOW.CACHES) do
    local found, start = CI_WORKFLOW.job_cache_problems(workflow, cache)
    for _, text in ipairs(found) do problems[#problems + 1] = cache.job .. ": " .. text end
    starts[#starts + 1] = { job = cache.job, start = start }
  end
  for first = 1, #starts do
    for second = first + 1, #starts do
      local a, b = starts[first].start, starts[second].start
      if a and b and (a:sub(1, #b) == b or b:sub(1, #a) == a) then
        problems[#problems + 1] = "the cache keys of " .. starts[first].job .. " and " .. starts[second].job
          .. " start alike (" .. a .. ", " .. b .. "): one's restore-keys would restore the other's entry"
      end
    end
  end
  -- the workflow's env, the job's, a step's or a line written to
  -- $GITHUB_ENV: any of them reaches every step of the job after it
  for line in (workflow .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^%s*#") and line:find("BASH_ENV", 1, true) then
      problems[#problems + 1] = "BASH_ENV is set (bash runs its file before every step's script): " .. line:match("^%s*(.-)%s*$")
    end
  end
  for _, text in ipairs(CI_WORKFLOW.env_path_problems(workflow:match("^(.-\n)jobs:\n") or "")) do
    problems[#problems + 1] = text
  end
  return problems
end
-- one job's cache problems, and the literal start of its key's prefix (to
-- its first variable)
function CI_WORKFLOW.job_cache_problems(workflow, cache)
  local problems = {}
  local function problem(text) problems[#problems + 1] = text end
  local shard, at = CI_WORKFLOW.cache_steps(workflow, cache)
  if not shard then return { "the workflow has no " .. cache.job .. " job" } end
  local steps = shard.steps
  for _, part in ipairs({ "list", "restore", "install", "save", "check" }) do
    if not at[part] then problem(cache.where .. " has no " .. part .. " step") end
  end
  if #problems > 0 then return problems end
  if not (at.list < at.restore and at.restore < at.install) then problem(cache.where .. " does not list, restore, then install") end
  if at.save ~= at.install + 1 or at.save > at.check then problem("the save is not the step right after the install") end
  local miss = "steps." .. tostring(steps[at.restore].id) .. ".outputs.cache-hit != 'true'"
  if steps[at.save].text:match("\n%s+if:%s*([^\n]-)%s*\n") ~= miss then problem("the save runs on an exact hit: its if is not " .. miss) end
  -- #993: the key is the job's own (CI_WORKFLOW.CACHES' prefix)
  local prefix = steps[at.list].text:match('\n%s+prefix="([^"\n]*)"') or ""
  if prefix:sub(1, #cache.prefix) ~= cache.prefix then
    problem("the cache key's prefix (" .. prefix .. ") does not start with " .. cache.prefix)
  end
  -- the pinned pieces, verbatim; a piece that matches is exempt from the
  -- route checks below (its lines are the ones that may name the folder)
  local exempt = {}
  for _, piece in ipairs(CI_WORKFLOW.PINNED[cache.job]) do
    local script, expected = CI_WORKFLOW.script(steps[at[piece.step]], true), {}
    for line in piece.text:gmatch("([^\n]*)\n") do expected[#expected + 1] = line end
    local starts = {}
    for index, line in ipairs(script) do
      if line:sub(1, #piece.first) == piece.first then starts[#starts + 1] = index end
    end
    if #starts ~= 1 then
      problem("the " .. piece.name .. " is not found once (" .. #starts .. " lines start with `" .. piece.first .. "`)")
    elseif piece.from_start and starts[1] ~= 1 then
      problem("the " .. piece.name .. " is not the script's first line: line 1 is `" .. tostring(script[1]) .. "`")
    else
      local differs
      for offset, line in ipairs(expected) do
        local found = script[starts[1] + offset - 1]
        if found ~= line then
          problem("the " .. piece.name .. " differs from its pinned text at line " .. offset .. ": expected `" .. line
            .. "`, found `" .. tostring(found) .. "`")
          differs = true
          break
        end
      end
      if not differs then
        local ranges = exempt[at[piece.step]] or {}
        ranges[#ranges + 1] = { from = starts[1], to = starts[1] + #expected - 1 }
        exempt[at[piece.step]] = ranges
      end
    end
  end
  -- the kept folder is the one the restore fills (and the save keeps)
  local kept = steps[at.restore].text:match("\n%s+path:%s*([^\n]-)%s*\n") or ""
  if kept ~= "${{ runner.temp }}/" .. cache.kept then
    problem("the kept folder the restore fills (" .. kept .. ") is not the install's debs, \"$RUNNER_TEMP/" .. cache.kept .. "\"")
  end
  local list_stem = cache.list:gsub("%.sha512$", "")
  -- outside the pinned pieces nothing puts a file in apt's archive folder,
  -- and nothing writes the SHA512 list (a read of it is `< "<the list>"`)
  for index, step in ipairs(steps) do
    local script = CI_WORKFLOW.script(step, true)
    -- what a step leaves to the steps after it (#792's review): GITHUB_PATH
    -- at all, and a PATH in a step that writes GITHUB_ENV (as NAME=value or
    -- as a NAME<<delimiter block, so on any line of that step)
    local writes_env = false
    for _, line in ipairs(script) do
      if line:find("%f[%w_]GITHUB_ENV%f[^%w_]") then writes_env = true end
    end
    for _, line in ipairs(script) do
      if line:find("%f[%w_]GITHUB_PATH%f[^%w_]") then
        problem("GITHUB_PATH is written (its directories come first in PATH for every later step): " .. line:match("^%s*(.-)$"))
      end
      if writes_env and (line:find("%f[%w_]PATH%s*=") or line:find("%f[%w_]PATH%s*<<")) then
        problem("PATH is written to GITHUB_ENV (it reaches every later step): " .. line:match("^%s*(.-)$"))
      end
    end
    if #script == 0 and CI_WORKFLOW.names_archives(step.text) then
      problem("step " .. tostring(step.name or step.uses) .. " names apt's archive folder")
    end
    for line_index, line in ipairs(script) do
      local pinned = false
      for _, range in ipairs(exempt[index] or {}) do
        if line_index >= range.from and line_index <= range.to then pinned = true end
      end
      for _, command in ipairs(CI_WORKFLOW.commands(line)) do
        if command:match("^function%s") or command:match("^[^%s=()'\"$]+%s*%(%s*%)") then
          problem("a shell function is defined in " .. cache.where .. " (it could shadow a command the pinned lines run): " .. line)
        end
      end
      if line:find("%f[%w_]alias%f[^%w_]") then
        problem("an alias in " .. cache.where .. " (it could shadow a command the pinned lines run): " .. line)
      end
      for _, command in ipairs(pinned and {} or CI_WORKFLOW.commands(line)) do
        if CI_WORKFLOW.names_archives(command) and not CI_WORKFLOW.leaves_archives(command) then
          problem("a file can reach apt's archive folder past the hash check: " .. line)
        end
        if command:find(list_stem, 1, true)
            and not (command:find('< "$RUNNER_TEMP/' .. cache.list .. '"', 1, true) and not command:find(">", 1, true)) then
          problem("the SHA512 list is written past its pinned making: " .. line)
        end
      end
    end
  end
  for _, text in ipairs(CI_WORKFLOW.env_path_problems(shard.text)) do problem(text) end
  return problems, prefix:match("^[^$]*")
end
-- the PATH keys in the env blocks of a text (the workflow's head, or a job's
-- text: its own env and its steps'), one problem each.
-- A PATH key in an env block (#817): the workflow's, a caching job's or a
-- step's sets the PATH every command under it runs with, so a directory
-- put first there shadows a command the pinned lines run.
-- What it reads, by lines, comments and blank lines dropped: the env of
-- the workflow (before `jobs:`), of each job that keeps its packages and of each of its
-- steps. An `env:` line (a step's first key, `- env:`, too) with nothing
-- after it opens a block: the lines after it indented deeper than the
-- `env:`, and, when the first of them starts with `{`, the lines from that
-- `{` to its closing `}` too. One that opens a flow mapping (`env: {`)
-- opens the lines to that `}`, whatever their indent (braces counted, so
-- `${{ ... }}` balances), and the lines indented deeper than the `env:`.
-- A block ends at the later of the two: its brace's close and its
-- indent's end. On those lines and on the `env:`
-- line itself (`env: { A: 1, PATH: x }`), a PATH key is matched as a
-- plain or quoted key (`PATH`, `"PATH"`, `'PATH'`, any spacing before its
-- colon) after the line's indent, a `{` or a `,`; a key that only ends in
-- PATH (`MYPATH`) passes.
-- What it does not: it parses no quotes, so a quoted value holding
-- `, PATH:` or `{ PATH:` (`A: "x, PATH: y"`) is refused too, a known
-- over-refusal (`A: "PATH: y"` passes), and a brace inside a quoted value
-- is counted as a brace, so a quoted `}` closes a `{`-opened block early;
-- the indent still holds the block's deeper lines, so only a flow
-- mapping whose lines sit at the `env:`'s own indent, after a quoted `}`,
-- is left unread; it does not read an explicit key written
-- with `?` (`? PATH` then `: x`), a tagged key (`!!str PATH: x`), an env
-- given by an expression (`env: ${{ ... }}`, such as `fromJSON`) or one
-- through an anchor or merge key (`<<: *name`). The workflow uses none of
-- these
function CI_WORKFLOW.env_path_problems(text)
  local problems = {}
  local function problem(found) problems[#problems + 1] = found end
  local function names_path(text) return ("," .. text):find("[{,]%s*[\"']?PATH[\"']?%s*:") ~= nil end
  local function braces(text) return select(2, text:gsub("{", "")) - select(2, text:gsub("}", "")) end
  local function blamed(line) problem("PATH is set in an env block (every command under it runs with that PATH): " .. line:match("^%s*(.-)%s*$")) end
  for _, scope in ipairs({ text }) do
    -- block: the env:'s indent while its block lasts; depth: the braces
    -- open while a `{`-opened block's brace is open (the block then lasts
    -- whatever the indent); first: the next line is the first after an
    -- `env:` with nothing after it
    local block, depth, first
    for line in (scope .. "\n"):gmatch("([^\n]*)\n") do
      if not (line:match("^%s*$") or line:match("^%s*#")) then
        local content = line:match("^%s*(.-)%s*$"):gsub("%s+#.*$", "")
        if first and content:match("^{") then depth = 0 end
        first = false
        if depth then
          if names_path(content) then blamed(line) end
          depth = depth + braces(content)
          -- the brace has closed: the block's deeper lines are still its own
          if depth <= 0 then depth = nil end
        else
          if block and #line:match("^%s*") <= block then block = nil end
          local lead, rest = line:match("^(%s*%-?%s*)env:%s*(.-)%s*$")
          if lead then rest = rest:gsub("^#.*$", ""):gsub("%s+#.*$", "") end
          if (lead and names_path(rest)) or (block and names_path(content)) then blamed(line) end
          if lead and rest == "" then block, first = #lead, true
          elseif lead and rest:match("^{") then
            block = #lead
            if braces(rest) > 0 then depth = braces(rest) end
          end
        end
      end
    end
  end
  return problems
end
-- what in a workflow's text weakens apt's checks, one line each: a setting
-- or option that turns a check off (apt-get(8), apt.conf(5),
-- apt-transport-https(1), apt's configure-index; matched without case,
-- hyphens or underscores, so an option and its setting are one word), a
-- change of the sources, and an install that names a file, which takes the
-- file as it is, not as apt's lists give it
-- #1005: the one line that may name Ubuntu's sources file, or set apt's
-- sources (Dir::Etc::sourcelist, Dir::Etc::sourceparts, any case), is the
-- list step's ubuntu_only, exactly as pinned (CI_WORKFLOW.LIST_UPDATE): it
-- only points apt at the file, read as it is, and names no variable a
-- later line could write through
-- #1011: and what points apt at other configuration, keyrings, lists or
-- sources: every Dir:: setting but Dir::State::status, which the SHA512
-- list's making sets (apt.conf(5): Dir::Etc moves the configuration, its
-- keys and sources included, Dir::State its lists, Dir::Bin its methods,
-- gpgv's among them), Dir= (with an attached -o too), the word trusted
-- (Dir::Etc::trusted, trustedparts, a deb822 Trusted: yes), apt-key (it
-- writes /etc/apt/trusted.gpg), APT_CONFIG and apt's own -c or
-- --config-file (in a command of apt's alone: python3 -c and git -C are
-- not), apt's nested syntax (Dir {, Etc {), any write under /etc/apt/ or
-- of a file named apt.conf* (a redirection, tee, cp, mv, install, ln,
-- sed -i, dd of= or a download's -o, past sudo and its options, also
-- through a variable assigned such a path), a cd or pushd into /etc/apt/,
-- and an assignment of such a path but the pinned ubuntu_only and mirrors=
-- lines; but the mirror reorder (#999), the one write the workflow makes
-- there, exactly as pinned: a line, not a step, is let through, so a write
-- added beside the reorder is still refused
-- #1024: and what changes apt's trust outside its configuration, named as
-- such (names_apt_trust): a write, in the same forms, under
-- /usr/share/keyrings/ or /var/lib/apt/lists/ (gpg's --keyring among them,
-- there or under /etc/apt/, in a command that does not only read), a cd or
-- pushd into either (past its options, as into /etc/apt/), an assignment
-- of such a path, and APT::Key:: and Acquire::gpgv (how gpgv checks a
-- list's signature). #1024's review: gpg's home folder (--homedir,
-- GNUPGHOME) is written as its keyring is, a read that imports
-- (--auto-key-retrieve, --auto-key-import) writes, a long option is read
-- by any start of it, Acquire::Min-ValidTime is refused, and a relative
-- path is resolved from the folder cd, pushd and popd leave
CI_WORKFLOW.UBUNTU_ONLY = CI_WORKFLOW.LIST_UPDATE:match("\n(ubuntu_only=[^\n]*)\n")
CI_WORKFLOW.MIRRORS = CI_WORKFLOW.LIST_UPDATE:match("\n(mirrors=[^\n]*)\n")
CI_WORKFLOW.REORDER = CI_WORKFLOW.LIST_UPDATE:match("\n%s*(sudo sed %-i [^\n]*)\n")
-- sudo's options that take a value (sudo(8)), skipped with it (#1024: -h
-- and --host take a host)
CI_WORKFLOW.SUDO_VALUES = { ["-u"] = true, ["-g"] = true, ["-p"] = true, ["-C"] = true, ["-D"] = true, ["-r"] = true,
  ["-t"] = true, ["-T"] = true, ["-U"] = true, ["-R"] = true, ["-h"] = true, ["--user"] = true, ["--group"] = true,
  ["--prompt"] = true, ["--close-from"] = true, ["--chdir"] = true, ["--role"] = true, ["--type"] = true,
  ["--command-timeout"] = true, ["--other-user"] = true, ["--chroot"] = true, ["--host"] = true }
-- #1011: whether a word names a file of apt's configuration: a path under
-- /etc/apt/ (with doubled slashes or ./ folded), a file named apt.conf*, or
-- a variable assigned one (`assigned`)
function CI_WORKFLOW.names_apt_config(word, assigned)
  local path = word:gsub("['\"]", ""):gsub("/%./", "/"):gsub("//+", "/")
  if path:find("/etc/apt", 1, true) or path:lower():find("apt.conf", 1, true) then return true end
  for name in path:gmatch("%${?([%a_][%w_]*)") do
    if assigned[name] then return true end
  end
  return false
end
-- #1024: whether a word names a file apt trusts outside its configuration:
-- a path under /usr/share/keyrings/ (the keyrings its sources' Signed-By
-- name) or /var/lib/apt/lists/ (the lists it takes as checked), folded as
-- names_apt_config folds, or a variable assigned one (`assigned`)
function CI_WORKFLOW.names_apt_trust(word, assigned)
  local path = word:gsub("['\"]", ""):gsub("/%./", "/"):gsub("//+", "/")
  if path:find("/usr/share/keyrings", 1, true) or path:find("/var/lib/apt/lists", 1, true) then return true end
  for name in path:gmatch("%${?([%a_][%w_]*)") do
    if assigned[name] then return true end
  end
  return false
end
-- #1024: gpg's commands that only read a keyring (gpg(1)); any other
-- command naming a keyring may write it
CI_WORKFLOW.GPG_READS = { ["--verify"] = true, ["--list-keys"] = true, ["-k"] = true, ["--list-public-keys"] = true,
  ["--list-sigs"] = true, ["--check-sigs"] = true, ["--fingerprint"] = true, ["--list-packets"] = true, ["--export"] = true,
  ["--show-keys"] = true }
-- #1024's review: whether a word is the long option `option` or a start of
-- it (gpg and getopt_long take an unambiguous start; an ambiguous one is an
-- error of the tool's, so counting it too refuses nothing that runs), with
-- or without an attached =value
function CI_WORKFLOW.long_option(word, option)
  local name = word:match("^(%-%-[^=]+)")
  return name ~= nil and #name >= 3 and option:sub(1, #name) == name
end
-- #1024's review: a written word as a path from the folder `here` (false:
-- not known), its option (--name=, of=, an attached -t) dropped, with . and
-- .. folded; nil for a path it cannot place (one through a variable or ~,
-- or a relative one from a folder not known)
function CI_WORKFLOW.resolved(word, here)
  local path = word:gsub("['\"]", ""):gsub("^%-%-[^=]*=", ""):gsub("^of=", ""):gsub("^%-%a", "")
  if path == "" or path:match("^[$~]") then return nil end
  if not path:match("^/") then
    if not here then return nil end
    path = here .. "/" .. path
  end
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then parts[#parts] = nil
    elseif part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/")
end
-- #1024's review: the folder a step's script is in, followed through cd,
-- pushd and popd in the script's order: `place` holds here (false when not
-- known: the step starts in the workspace), pushd's stack below it and the
-- folder cd - returns to. For a cd or pushd it returns the folder word and
-- that folder resolved from where the command ran
function CI_WORKFLOW.follow_folder(words, place)
  local tool = words[1]
  if tool ~= "cd" and tool ~= "pushd" and tool ~= "popd" then return nil end
  -- options (-P, -L, -e, -@, -n; -- ends them), a +N or -N stack entry
  -- (pushd and popd), then the folder
  local stay, entry, operand, index = false, nil, nil, 2
  while words[index] do
    local word = words[index]
    if word == "--" then operand = words[index + 1]; break
    elseif tool ~= "cd" and word:match("^[+-]%d+$") then entry = word
    elseif word:match("^%-.") then stay = stay or word:find("n", 2, true) ~= nil
    else operand = word; break end
    index = index + 1
  end
  local before, list = place.here, { place.here }
  for _, folder in ipairs(place.stack) do list[#list + 1] = folder end
  -- the place of a +N (from the top) or -N (from the bottom) entry in list
  local at = entry and (entry:sub(1, 1) == "+" and tonumber(entry:sub(2)) + 1 or #list - tonumber(entry:sub(2)))
  local folder = false
  if operand == "-" and tool == "cd" then folder = place.previous
  elseif operand then folder = CI_WORKFLOW.resolved(operand, place.here) or false end
  local function set(new)
    place.here, place.stack = new[1], {}
    for i = 2, #new do place.stack[#place.stack + 1] = new[i] end
  end
  if tool == "cd" then
    place.here = folder
  elseif tool == "pushd" and operand then
    if stay then table.insert(place.stack, 1, folder)
    else table.insert(place.stack, 1, place.here); place.here = folder end
  elseif tool == "pushd" and at then
    if list[at] ~= nil and not stay then
      local rotated = {}
      for i = 0, #list - 1 do rotated[#rotated + 1] = list[(at - 1 + i) % #list + 1] end
      set(rotated)
    end
  elseif tool == "pushd" then
    if #list > 1 and not stay then list[1], list[2] = list[2], list[1]; set(list) end
  else
    at = at or (stay and 2 or 1)
    if list[at] ~= nil and #list > 1 then table.remove(list, at); set(list) end
  end
  if place.here ~= before then place.previous = before end
  if tool ~= "popd" and operand then return operand, folder end
  return nil
end
-- #1011: the words a command writes to: its redirections' files, and a
-- writing command's targets (its name found past env assignments and the
-- wrappers that run another command)
function CI_WORKFLOW.written_words(command)
  local targets = {}
  for target in command:gmatch(">>?%s*([^%s>&][^%s]*)") do targets[#targets + 1] = target end
  local words = {}
  for word in command:gmatch("%S+") do words[#words + 1] = (word:gsub("^['\"]+", "")) end
  -- sudo's options (and their values) from `at` on
  local function past_sudo_options(at)
    while words[at] and words[at]:match("^%-") do
      local option = words[at]
      at = at + 1
      if option == "--" then break end
      if CI_WORKFLOW.SUDO_VALUES[option] then at = at + 1 end
    end
    return at
  end
  -- CI_WORKFLOW.commands strips a leading sudo but not its options, and no
  -- command starts with a -
  local at = past_sudo_options(1)
  -- #1024's review: gpg's home folders set past sudo or env (GNUPGHOME=)
  local homes = {}
  while words[at] do
    local word = words[at]
    if word:match("^[%a_][%w_]*=") then
      if word:match("^GNUPGHOME=") then homes[#homes + 1] = word end
      at = at + 1
    elseif word == "env" or word == "command" or word == "exec" or word == "nohup" or word == "nice"
        or word == "xargs" or word == "stdbuf" or word == "timeout" then
      at = at + 1
      while words[at] and words[at]:match("^%-") do at = at + 1 end
      if word == "timeout" and words[at] and words[at]:match("^%d") then at = at + 1 end
    elseif word == "sudo" then at = past_sudo_options(at + 1)
    else break end
  end
  local name, rest, operands = words[at] or "", {}, {}
  -- #1024's review: the path given to one of `options` (any start of it,
  -- CI_WORKFLOW.long_option), attached (=) or as the next word
  local function paths_of(options)
    for index, word in ipairs(rest) do
      for _, option in ipairs(options) do
        if CI_WORKFLOW.long_option(word, option) then
          targets[#targets + 1] = word:find("=", 1, true) and word or (rest[index + 1] or "")
          break
        end
      end
    end
  end
  for index = at + 1, #words do
    rest[#rest + 1] = words[index]
    if not words[index]:match("^%-") then operands[#operands + 1] = words[index] end
  end
  if name == "tee" then
    for _, word in ipairs(operands) do targets[#targets + 1] = word end
  elseif name == "cp" or name == "mv" or name == "install" or name == "ln" then
    for index, word in ipairs(rest) do
      if word == "-t" then targets[#targets + 1] = rest[index + 1] or ""
      elseif word:match("^%-t.") then targets[#targets + 1] = word end
    end
    paths_of({ "--target-directory" })
    targets[#targets + 1] = operands[#operands]
  elseif name == "sed" then
    for _, word in ipairs(rest) do
      if word:match("^%-%a*i") or CI_WORKFLOW.long_option(word, "--in-place") then
        for _, operand in ipairs(operands) do targets[#targets + 1] = operand end
        break
      end
    end
  elseif name == "dd" then
    for _, word in ipairs(rest) do
      if word:match("^of=") then targets[#targets + 1] = word end
    end
  elseif name == "curl" or name == "wget" or name == "gpg" then
    for index, word in ipairs(rest) do
      if word == "-o" or word == "-O" then targets[#targets + 1] = rest[index + 1] or ""
      elseif word:match("^%-[oO].") then targets[#targets + 1] = word end
    end
    paths_of({ "--output", "--output-document", "--output-dir", "--output-file" })
  end
  -- #1024: gpg's keyring (--keyring, --primary-keyring) is written by any
  -- command of gpg's but those that only read (gpg takes one command); so
  -- is its home folder (--homedir, GNUPGHOME), which holds a keyring named
  -- without a slash (gpg(1)). #1024's review: a read that imports the key
  -- it fetches or finds (--auto-key-retrieve, --auto-key-import, the
  -- keyserver option auto-key-retrieve) writes too
  if name == "gpg" then
    local reads = false
    for _, word in ipairs(rest) do
      if CI_WORKFLOW.GPG_READS[word] then reads = true end
    end
    for _, word in ipairs(rest) do
      if CI_WORKFLOW.long_option(word, "--auto-key-retrieve") or CI_WORKFLOW.long_option(word, "--auto-key-import")
          or word:find("auto-key-retrieve", 1, true) then reads = false end
    end
    if not reads then
      for _, home in ipairs(homes) do targets[#targets + 1] = home end
      paths_of({ "--keyring", "--primary-keyring", "--homedir" })
    end
  end
  return targets
end
function CI_WORKFLOW.apt_weakenings(workflow)
  local found = {}
  -- #1011: the names assigned a file of apt's configuration anywhere in the
  -- workflow (a script's assignment, an export or an env: key)
  local assigned = {}
  -- #1024: and those assigned a path of apt's keyrings or lists
  local assigned_trust = {}
  for line in (workflow .. "\n"):gmatch("([^\n]*)\n") do
    local plain = line:lower():gsub("[-_]", "")
    local trimmed = line:match("^%s*(.-)%s*$")
    local reads_ubuntu = trimmed == CI_WORKFLOW.UBUNTU_ONLY
    for _, word in ipairs({ "allowunauthenticated", "allowinsecurerepositories", "allowdowngradetoinsecurerepositories",
        "allowweakrepositories", "checkvaliduntil", "checkdate", "forceyes", "verifypeer", "verifyhost", "trusted=yes",
        "sources.list", "dir::etc::source", "trusted", "aptkey", "apt::key::", "acquire::gpgv", "minvalidtime" }) do
      if plain:find(word, 1, true) and not (reads_ubuntu and (word == "sources.list" or word == "dir::etc::source")) then
        found[#found + 1] = word .. ": " .. trimmed
      end
    end
    for at in plain:gmatch("()dir::") do
      if not reads_ubuntu and plain:sub(at, at + #"dir::state::status" - 1) ~= "dir::state::status" then
        found[#found + 1] = "a Dir:: setting (but Dir::State::status): " .. trimmed
        break
      end
    end
    -- Dir= as a word of its own (a NORNS_DIR= is not apt's), or after an
    -- attached -o
    if plain:find("%f[%w]dir=") or line:lower():find("%-o['\"]?dir=") then found[#found + 1] = "dir=: " .. trimmed end
    if line:find("APT_CONFIG", 1, true) then found[#found + 1] = "APT_CONFIG: " .. trimmed end
    for _, block in ipairs({ "Dir {", "Etc {" }) do
      if plain:find("%f[%w]" .. block:lower():gsub(" ", "%%s*")) then
        found[#found + 1] = "apt's nested configuration (" .. block .. "): " .. trimmed
      end
    end
    for _, words in ipairs({ "dpkg -i", "dpkg --install", "dpkg --unpack" }) do
      if line:find(words, 1, true) then found[#found + 1] = words .. ": " .. trimmed end
    end
    local name, value = trimmed:match("^export%s+([%a_][%w_]*)=(.*)$")
    if not name then name, value = trimmed:match("^([%a_][%w_]*)[=:]%s*(.*)$") end
    if name and CI_WORKFLOW.names_apt_config(value, {}) then
      assigned[name] = true
      if not reads_ubuntu and trimmed ~= CI_WORKFLOW.MIRRORS then
        found[#found + 1] = "an assignment of a path of apt's configuration: " .. trimmed
      end
    end
    if name and CI_WORKFLOW.names_apt_trust(value, {}) then
      assigned_trust[name] = true
      found[#found + 1] = "an assignment of a path of apt's keyrings or lists: " .. trimmed
    end
  end
  for _, job in ipairs(CI_WORKFLOW.jobs(workflow)) do
    for _, step in ipairs(job.steps) do
      -- #1024's review: the folder the step's script is in
      local place = { here = false, stack = {}, previous = false }
      for _, line in ipairs(CI_WORKFLOW.script(step)) do
        local paths = {}
        local packages = line:match("^%s*packages=%((.*)%)%s*$")
        if packages then
          for word in packages:gmatch("%S+") do paths[#paths + 1] = word end
        end
        local trimmed = line:match("^%s*(.-)%s*$")
        local reorder = trimmed == CI_WORKFLOW.REORDER
        for _, command in ipairs(CI_WORKFLOW.commands(line)) do
          local words, apt, install = {}, nil, nil
          for word in command:gmatch("%S+") do words[#words + 1] = word end
          for index, word in ipairs(words) do
            if not apt and (word == "apt" or word == "apt-get") then apt = index end
            if apt and not install and word == "install" then install = index end
          end
          local index = (install or #words) + 1
          while install and index <= #words do
            if words[index] == "-o" then index = index + 1
            elseif not words[index]:match("^%-") then paths[#paths + 1] = words[index] end
            index = index + 1
          end
          -- #1011: apt's own configuration file, in a command of apt's
          local tool = false
          for _, word in ipairs(words) do
            word = word:gsub("^['\"]+", "")
            if word == "apt" or word:match("^apt%-%a+$") then tool = true
            elseif tool and (word:match("^%-c") or word:match("^%-%-config%-file")) then
              found[#found + 1] = "a configuration file for apt (-c, --config-file): " .. trimmed
              break
            end
          end
          -- #1024: the folder a cd or pushd names, past its options;
          -- #1024's review: and resolved from the folder it ran in
          local folder, resolved = CI_WORKFLOW.follow_folder(words, place)
          resolved = resolved or ""
          if folder and (CI_WORKFLOW.names_apt_config(folder, assigned) or CI_WORKFLOW.names_apt_config(resolved, {})) then
            found[#found + 1] = "a change into apt's configuration folder: " .. trimmed
          end
          if folder and (CI_WORKFLOW.names_apt_trust(folder, assigned_trust) or CI_WORKFLOW.names_apt_trust(resolved, {})) then
            found[#found + 1] = "a change into apt's keyrings or lists: " .. trimmed
          end
          -- a write's target as written, and resolved from the step's folder
          local written = reorder and {} or CI_WORKFLOW.written_words(command)
          for index = 1, #written do written[#written + 1] = CI_WORKFLOW.resolved(written[index], place.here) end
          for _, target in ipairs(written) do
            if CI_WORKFLOW.names_apt_config(target, assigned) then
              found[#found + 1] = "a write into apt's configuration: " .. trimmed
              break
            end
          end
          for _, target in ipairs(written) do
            if CI_WORKFLOW.names_apt_trust(target, assigned_trust) then
              found[#found + 1] = "a write into apt's keyrings or lists: " .. trimmed
              break
            end
          end
        end
        for _, word in ipairs(paths) do
          if word:find("/", 1, true) or (word:gsub('"', "")):match("%.deb$") then
            found[#found + 1] = "an install of a file path, past apt's lists: " .. line
            break
          end
        end
      end
    end
  end
  return found
end
-- each case: a name, the edits (old, new, ...) and a text the problems name
-- (or a list of texts, each named); every case that is not refused is
-- reported, not only the first. #993: the edits are made in the job `job`
-- names (the case's own `job` first; "workflow" for the whole text)
function CI_WORKFLOW.failing_cases(workflow, find_problems, cases, job)
  local missed = {}
  for _, case in ipairs(cases) do
    local text, scope = workflow, case.job or job
    if scope == "workflow" then scope = nil end
    for i = 1, #case.edits, 2 do text = CI_WORKFLOW.mutated(text, case.edits[i], case.edits[i + 1], scope) end
    local found = table.concat(find_problems(text), "\n  ")
    for _, expect in ipairs(type(case.expect) == "table" and case.expect or { case.expect }) do
      if not found:find(expect, 1, true) then
        missed[#missed + 1] = case.name .. ": the problems should name " .. expect .. "; they are: " .. (found == "" and "(none)" or found)
      end
    end
  end
  assert_true(#missed == 0, "mutations of the workflow not refused:\n" .. table.concat(missed, "\n"))
end
-- #1011: the ways of pointing apt at other configuration, other keyrings or
-- other sources, each a mutation of a job's text that apt_weakenings
-- refuses, in both jobs that keep their packages (each edit's text is in
-- each job once)
function CI_WORKFLOW.relocation_cases()
  local install = '          sudo apt-get $APT_NETWORK_OPTIONS install -y "${packages[@]}"\n'
  local function on_install(extra) return { install, '          sudo apt-get $APT_NETWORK_OPTIONS install -y ' .. extra .. ' "${packages[@]}"\n' } end
  local function instead(line) return { install, "          " .. line .. "\n" } end
  local function before_install(...)
    local lines = {}
    for _, line in ipairs({ ... }) do lines[#lines + 1] = "          " .. line .. "\n" end
    return { install, table.concat(lines) .. install }
  end
  local parts = "-o Dir::Etc::sourceparts=-)"
  local list_retry = "priority:9/' \"$mirrors\"\n            cat \"$mirrors\"\n            status=0\n            sudo timeout --kill-after=5 60 "
  local write = "a write into apt's configuration: "
  local trust = "a write into apt's keyrings or lists: "
  local dir = "a Dir:: setting (but Dir::State::status): "
  local kept_line = "          echo \"$kept package files from the cache, each matching apt's lists\"\n"
  return {
    -- the whole configuration moved (apt.conf(5): Dir, Dir::Etc)
    { name = "-o Dir=", expect = "dir=: sudo apt-get", edits = on_install("-o Dir=/tmp/apt") },
    { name = "-o Dir::Etc=", expect = dir .. "sudo apt-get", edits = on_install("-o Dir::Etc=/tmp/etc") },
    { name = "Dir::Etc::parts, quoted, any case", expect = dir .. "sudo apt-get", edits = on_install('-o "dir::etc::parts=/tmp/conf.d"') },
    { name = "the list's ubuntu_only moving Dir::Etc", expect = dir .. "ubuntu_only=(", edits = { parts, "-o Dir::Etc::sourceparts=- -o Dir::Etc=/tmp/etc)" } },
    { name = "the list's ubuntu_only moving Dir", expect = "dir=: ubuntu_only=(", edits = { parts, "-o Dir::Etc::sourceparts=- -o Dir=/tmp/apt)" } },
    -- other keyrings, and a deb822 source trusted unsigned
    { name = "Dir::Etc::trusted", expect = "trusted: sudo apt-get", edits = on_install("-o Dir::Etc::trusted=/tmp/k.gpg") },
    { name = "Dir::Etc::TrustedParts", expect = "trusted: sudo apt-get", edits = on_install("-o Dir::Etc::TrustedParts=/tmp/keys") },
    { name = "a deb822 Trusted: yes", expect = "trusted: echo", edits = instead("echo 'Trusted: yes' >> \"$RUNNER_TEMP/x.sources\"") },
    -- a configuration file the workflow does not hold
    { name = "APT_CONFIG before an install", expect = "APT_CONFIG: APT_CONFIG=",
      edits = instead('APT_CONFIG="$RUNNER_TEMP/x.conf" sudo -E apt-get $APT_NETWORK_OPTIONS install -y "${packages[@]}"') },
    { name = "APT_CONFIG exported", expect = "APT_CONFIG: export", edits = before_install("export APT_CONFIG=/tmp/x.conf") },
    { name = "APT_CONFIG left to the later steps", expect = "APT_CONFIG: echo", edits = before_install('echo "APT_CONFIG=/tmp/x.conf" >> "$GITHUB_ENV"') },
    { name = "apt-get -c", expect = "a configuration file for apt (-c, --config-file): sudo apt-get", edits = on_install("-c /tmp/x.conf") },
    { name = "apt-get --config-file=", expect = "a configuration file for apt (-c, --config-file): sudo apt-get", edits = on_install("--config-file=/tmp/x.conf") },
    { name = "the list's apt-cache -c", expect = "a configuration file for apt (-c, --config-file): xargs apt-cache",
      edits = { 'xargs apt-cache "${ubuntu_only[@]}"', 'xargs apt-cache -c "$RUNNER_TEMP/x.conf" "${ubuntu_only[@]}"' } },
    -- a write under /etc/apt/ or of a file named apt.conf*
    { name = "a tee into apt.conf.d", expect = write .. "echo 'APT::Get::Assume-Yes",
      edits = instead("echo 'APT::Get::Assume-Yes \"true\";' | sudo tee /etc/apt/apt.conf.d/99yes") },
    { name = "a printf into a file named apt.conf", expect = write .. "printf",
      edits = instead("printf 'APT::Get::Assume-Yes \"true\";\\n' > \"$RUNNER_TEMP/apt.conf\"") },
    { name = "an echo appended under /etc/apt/", expect = write .. "sudo sh -c",
      edits = instead("sudo sh -c 'echo \"Pin-Priority: 1001\" >> /etc/apt/preferences.d/x'") },
    { name = "a cp into apt.conf.d", expect = write .. "sudo cp", edits = instead('sudo cp "$RUNNER_TEMP/x.conf" /etc/apt/apt.conf.d/') },
    { name = "a link into apt.conf.d", expect = write .. "sudo ln", edits = instead('sudo ln -s "$RUNNER_TEMP/x.conf" /etc/apt/apt.conf.d/99x') },
    { name = "a download into apt.conf.d", expect = write .. "curl", edits = instead("curl -fsSL -o /etc/apt/apt.conf.d/99x https://example.com/x") },
    { name = "a heredoc through a variable", expect = write .. 'sudo tee "$conf"',
      edits = before_install("conf=/etc/apt/apt.conf.d/99x", "sudo tee \"$conf\" > /dev/null <<'EOF'", 'APT::Get::Assume-Yes "true";', "EOF") },
    { name = "a sed -i of another file under /etc/apt/", expect = write .. "sudo sed", edits = instead("sudo sed -i 's/^/#/' /etc/apt/apt.conf.d/70debconf") },
    -- the reorder is let through only exactly as pinned
    { name = "a second sed of the mirror list", expect = write .. "sudo sed", edits = instead("sudo sed -i 's/^/x/' \"$mirrors\"") },
    { name = "the list's reorder writing a second file", expect = write .. "sudo sed -i -E",
      edits = { list_retry, "priority:9/' \"$mirrors\" /etc/apt/apt.conf.d/70debconf\n            cat \"$mirrors\"\n            status=0\n            sudo timeout --kill-after=5 60 " } },
    { name = "a tee in the list step beside the reorder", expect = write .. "echo 'Acquire::Retries",
      edits = { list_retry, "priority:9/' \"$mirrors\"\n            echo 'Acquire::Retries \"0\";' | sudo tee /etc/apt/apt.conf.d/99x\n            cat \"$mirrors\"\n            status=0\n            sudo timeout --kill-after=5 60 " } },
    -- #1011's review: a write through sudo with its options, or under a
    -- wrapper before sudo
    { name = "a tee under sudo -E", expect = write .. "echo x | sudo -E tee", edits = instead("echo x | sudo -E tee /etc/apt/apt.conf.d/x") },
    { name = "a cp under sudo -u root", expect = write .. "sudo -u root cp", edits = instead('sudo -u root cp "$RUNNER_TEMP/x" /etc/apt/apt.conf.d/') },
    { name = "a tee under timeout and sudo", expect = write .. "echo x | timeout 45 sudo tee", edits = instead("echo x | timeout 45 sudo tee /etc/apt/x") },
    -- an attached -o, and every Dir:: but Dir::State::status
    { name = "an attached -oDir=", expect = "dir=: sudo apt-get", edits = on_install("-oDir=/tmp/apt") },
    { name = "Dir::State::lists", expect = dir .. "sudo apt-get", edits = on_install("-o Dir::State::lists=/tmp/lists") },
    { name = "Dir::State=", expect = dir .. "sudo apt-get", edits = on_install("-o Dir::State=/tmp/state") },
    { name = "Dir::Bin::Methods", expect = dir .. "sudo apt-get", edits = on_install("-o Dir::Bin::Methods=/tmp/methods") },
    { name = "an attached -oDir::State::lists", expect = dir .. "sudo apt-get", edits = on_install("-oDir::State::lists=/tmp/lists") },
    -- the mirror list's name moved before the install's reorder
    { name = "the mirror list's variable reassigned", expect = "an assignment of a path of apt's configuration: mirrors=/etc/apt/apt.conf.d/70debconf",
      edits = { kept_line, kept_line .. "          mirrors=/etc/apt/apt.conf.d/70debconf\n" } },
    -- apt-key writes /etc/apt/trusted.gpg; a cd into /etc/apt/ makes a write relative
    { name = "apt-key", expect = "aptkey: curl", edits = instead("curl -fsSL https://example.com/k.asc | sudo apt-key add -") },
    { name = "a cd into /etc/apt/", expect = "a change into apt's configuration folder: cd /etc/apt", edits = before_install("cd /etc/apt/apt.conf.d", "echo x > 99x", "cd -") },
    { name = "a pushd into /etc/apt/", expect = "a change into apt's configuration folder: pushd /etc/apt", edits = before_install("pushd /etc/apt", "popd") },
    -- apt's nested syntax, in a file written anywhere
    { name = "a heredoc of nested settings on one line", expect = "apt's nested configuration (Dir {): Dir {",
      edits = before_install("cat > \"$RUNNER_TEMP/x\" <<'EOF'", 'Dir { Etc { SourceList "/tmp/x"; }; };', "EOF") },
    { name = "a heredoc of nested settings over lines", expect = { "apt's nested configuration (Dir {): Dir {", "apt's nested configuration (Etc {): Etc {" },
      edits = before_install("cat > \"$RUNNER_TEMP/x\" <<'EOF'", "Dir {", "Etc {", 'Main "/tmp/x.conf";', "};", "};", "EOF") },
    -- #1024: a write into the keyrings apt reads or the lists it trusts as
    -- checked, gpg's keyring there, and how gpgv checks a list's signature
    { name = "a download into /usr/share/keyrings/", expect = trust .. "curl",
      edits = instead("curl -fsSL -o /usr/share/keyrings/x.gpg https://example.com/k.gpg") },
    { name = "a tee into /usr/share/keyrings/", expect = trust .. "echo x | sudo tee", edits = instead("echo x | sudo tee /usr/share/keyrings/x.asc") },
    { name = "a tee into /usr/share/keyrings/, slashes doubled", expect = trust .. "echo x | sudo tee",
      edits = instead("echo x | sudo tee //usr/share/./keyrings//x.asc") },
    { name = "gpg --import into a keyring under /usr/share/keyrings/", expect = trust .. "gpg --no-default-keyring",
      edits = instead("gpg --no-default-keyring --keyring /usr/share/keyrings/x.gpg --import k.asc") },
    { name = "gpg --keyring= under /etc/apt/ receiving keys", expect = write .. "sudo gpg --keyring=",
      edits = instead("sudo gpg --keyring=/etc/apt/keyrings/x.gpg --recv-keys 0123456789ABCDEF") },
    { name = "a cp into /var/lib/apt/lists/", expect = trust .. "sudo cp",
      edits = instead('sudo cp "$RUNNER_TEMP/x_Packages" /var/lib/apt/lists/') },
    { name = "a cd into /var/lib/apt/lists/", expect = "a change into apt's keyrings or lists: cd /var/lib/apt/lists",
      edits = before_install("cd /var/lib/apt/lists", "echo x > x_Packages", "cd -") },
    { name = "a keyring path assigned, then written through", expect = { "an assignment of a path of apt's keyrings or lists: keys=/usr/share/keyrings/x.gpg",
        trust .. 'echo x | sudo tee "$keys"' }, edits = before_install("keys=/usr/share/keyrings/x.gpg", 'echo x | sudo tee "$keys"') },
    { name = "APT::Key::gpgvcommand", expect = "apt::key::: sudo apt-get", edits = on_install("-o APT::Key::gpgvcommand=/tmp/gpgv") },
    { name = "Acquire::gpgv::Options", expect = "acquire::gpgv: sudo apt-get", edits = on_install("-o Acquire::gpgv::Options::=--ignore-time-conflict") },
    -- #1024's comment: sudo's -h takes a host, and cd and pushd options
    { name = "a tee under sudo -h", expect = write .. "echo x | sudo -h localhost tee", edits = instead("echo x | sudo -h localhost tee /etc/apt/apt.conf.d/x") },
    { name = "a tee under sudo --host", expect = write .. "echo x | sudo --host localhost tee", edits = instead("echo x | sudo --host localhost tee /etc/apt/apt.conf.d/x") },
    { name = "a cd -P into /etc/apt/", expect = "a change into apt's configuration folder: cd -P /etc/apt", edits = before_install("cd -P /etc/apt", "echo x > preferences.d/x", "cd -") },
    { name = "a pushd -n into /etc/apt/", expect = "a change into apt's configuration folder: pushd -n /etc/apt", edits = before_install("pushd -n /etc/apt", "popd") },
    { name = "a cd -P -e -- into /usr/share/keyrings/", expect = "a change into apt's keyrings or lists: cd -P -e -- /usr/share/keyrings",
      edits = before_install("cd -P -e -- /usr/share/keyrings", "echo x > x.gpg", "cd -") },
    -- #1024's review: gpg's home folder holds a --keyring named without a
    -- slash, so --homedir and GNUPGHOME are written too
    { name = "gpg --homedir with a keyring named in it", expect = trust .. "sudo gpg --homedir /usr/share/keyrings",
      edits = instead("sudo gpg --homedir /usr/share/keyrings --no-default-keyring --keyring ubuntu-archive-keyring.gpg --import k.asc") },
    { name = "gpg --homedir=", expect = trust .. "gpg --homedir=",
      edits = instead("gpg --homedir=/usr/share/keyrings --no-default-keyring --keyring ubuntu-archive-keyring.gpg --import k.asc") },
    { name = "GNUPGHOME past sudo", expect = trust .. "sudo GNUPGHOME=",
      edits = instead("sudo GNUPGHOME=/usr/share/keyrings gpg --no-default-keyring --keyring ubuntu-archive-keyring.gpg --import k.asc") },
    { name = "GNUPGHOME past env", expect = trust .. "env GNUPGHOME=",
      edits = instead("env GNUPGHOME=/usr/share/keyrings gpg --no-default-keyring --keyring ubuntu-archive-keyring.gpg --import k.asc") },
    -- a read that imports what it fetches or finds
    { name = "gpg --verify with --auto-key-retrieve", expect = trust .. "gpg --no-default-keyring",
      edits = instead("gpg --no-default-keyring --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg --auto-key-retrieve --verify x.sig x") },
    { name = "gpg --verify with --keyserver-options auto-key-retrieve", expect = trust .. "gpg --keyserver-options",
      edits = instead("gpg --keyserver-options auto-key-retrieve --no-default-keyring --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg --verify x.sig x") },
    { name = "gpg --list-keys with --auto-key-import", expect = trust .. "gpg --auto-key-import",
      edits = instead("gpg --auto-key-import --no-default-keyring --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg --list-keys") },
    -- long options abbreviated (gpg and getopt_long take any unambiguous start)
    { name = "gpg --keyr", expect = trust .. "gpg --no-default-keyring --keyr",
      edits = instead("gpg --no-default-keyring --keyr /usr/share/keyrings/x.gpg --import k.asc") },
    { name = "gpg --homed=", expect = trust .. "gpg --homed=", edits = instead("gpg --homed=/usr/share/keyrings --keyring x.gpg --import k.asc") },
    { name = "gpg --dearmor --out", expect = trust .. "gpg --dearmor --out", edits = instead("gpg --dearmor --out /usr/share/keyrings/x.gpg k.asc") },
    { name = "cp --target=", expect = write .. "sudo cp --target=", edits = instead('sudo cp --target=/etc/apt/apt.conf.d "$RUNNER_TEMP/x.conf"') },
    { name = "sed --in-pl", expect = write .. "sudo sed --in-pl", edits = instead("sudo sed --in-pl 's/^/#/' /etc/apt/apt.conf.d/70debconf") },
    -- --primary-keyring, both forms
    { name = "gpg --primary-keyring", expect = trust .. "gpg --primary-keyring /usr",
      edits = instead("gpg --primary-keyring /usr/share/keyrings/x.gpg --import k.asc") },
    { name = "gpg --primary-keyring=", expect = trust .. "gpg --primary-keyring=",
      edits = instead("gpg --primary-keyring=/usr/share/keyrings/x.gpg --recv-keys 0123456789ABCDEF") },
    -- Acquire::Min-ValidTime keeps a Release file valid past its Valid-Until
    { name = "Acquire::Min-ValidTime", expect = "minvalidtime: sudo apt-get", edits = on_install("-o Acquire::Min-ValidTime=86400") },
    -- a relative write, resolved against the folder cd, pushd and popd leave
    { name = "a cd into /var/lib/apt/, then lists/", expect = trust .. "echo x > lists/x_Packages",
      edits = before_install("cd /var/lib/apt", "echo x > lists/x_Packages", "cd -") },
    { name = "a cd into /usr/share/, then keyrings/", expect = trust .. "echo x | sudo tee keyrings/x.gpg",
      edits = before_install("cd /usr/share", "echo x | sudo tee keyrings/x.gpg", "cd -") },
    { name = "a cd into /etc/, then apt/", expect = write .. "echo x > apt/preferences.d/x",
      edits = before_install("cd /etc", "echo x > apt/preferences.d/x", "cd -") },
    { name = "a write through ..", expect = trust .. "echo x > ../keyrings/x.gpg",
      edits = before_install("cd /usr/share/doc", "echo x > ../keyrings/x.gpg", "cd -") },
    { name = "a relative cd", expect = "a change into apt's keyrings or lists: cd /usr/share && cd keyrings", edits = before_install("cd /usr/share && cd keyrings", "cd -") },
    { name = "cd - back to /usr/share/", expect = trust .. "echo x > keyrings/x.gpg",
      edits = before_install("cd /usr/share", "cd /tmp", "cd -", "echo x > keyrings/x.gpg") },
    { name = "popd back to /usr/share/", expect = trust .. "echo x > keyrings/x.gpg",
      edits = before_install("pushd /usr/share", "pushd /tmp", "popd", "echo x > keyrings/x.gpg", "popd") },
    { name = "pushd +1 to a folder pushed with -n", expect = trust .. "echo x > keyrings/x.gpg",
      edits = before_install("pushd -n /usr/share", "pushd +1", "echo x > keyrings/x.gpg", "popd") },
  }
end

-- #786: the making of the SHA512 list and the verify-and-copy loop are
-- pinned verbatim (CI_WORKFLOW.PINNED), and outside them nothing puts a file
-- in apt's archive folder: apt takes any file of the right size there as
-- downloaded. #792: so is the install step's start, and nothing in the
-- shard can shadow a command the pinned lines run
test("a kept package reaches apt's archive folder only through the hash check, by its place in the script (#786)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  assert_equal(table.concat(CI_WORKFLOW.cache_problems(workflow), " | "), "", "the workflow's cache problems")
  local check = '            if [ -f "$debs/$name" ] && echo "$sum  $debs/$name" | sha512sum --check --status; then\n'
  local copy = '              sudo cp "$debs/$name" "$archives/"\n'
  local after_loop = '          echo "$kept package files from the cache, each matching apt\'s lists"\n'
  local function added(line) return { after_loop, "          " .. line .. "\n" .. after_loop } end
  -- an edit of a pinned region fails by the region's first differing line
  local function differs(region, line, found)
    return { "the " .. region .. " differs from its pinned text at line " .. line .. ":", "found `" .. found .. "`" }
  end
  local loop, start = "verify-and-copy loop", "install step's start"
  local function also(expect, extra) expect[#expect + 1] = extra; return expect end
  local debs, prefix = '          debs="$RUNNER_TEMP/sc-debs"\n', '          prefix="sc-debs-'
  local cases = {
    -- inside the pinned loop: every edit fails by its first changed line.
    -- The case nobody wrote down: the whole kept folder copied "to save a loop"
    { name = "the kept folder copied before the check", expect = differs(loop, 5, 'sudo cp "$debs"/*.deb "$archives/"'),
      edits = { "          kept=0\n", '          sudo cp "$debs"/*.deb "$archives/"\n          kept=0\n' } },
    { name = "the copy moved before the check", expect = differs(loop, 7, '  sudo cp "$debs/$name" "$archives/"'),
      edits = { check .. copy, copy:sub(3) .. check } },
    { name = "the copy moved out of the check's if", expect = differs(loop, 8, "    kept=$((kept + 1))"),
      edits = { copy .. "              kept=$((kept + 1))\n            fi\n", "              kept=$((kept + 1))\n            fi\n" .. copy:sub(3) } },
    { name = "the check made optional", expect = differs(loop, 7, '  if [ -f "$debs/$name" ] || echo "$sum  $debs/$name" | sha512sum --check --status; then'),
      edits = { '[ -f "$debs/$name" ] && echo', '[ -f "$debs/$name" ] || echo' } },
    { name = "the check reading another list", expect = differs(loop, 11, 'done < "$debs/sums.sha512"'),
      edits = { '            fi\n          done < "$RUNNER_TEMP/sc-packages.sha512"\n          echo "$kept',
        '            fi\n          done < "$debs/sums.sha512"\n          echo "$kept' } },
    -- a check whose status the if never sees (the steps run as bash -e
    -- without pipefail: a pipeline's status is its last command's)
    { name = "the check's status ignored",
      expect = differs(loop, 7, '  if [ -f "$debs/$name" ] && echo "$sum  $debs/$name" | sha512sum --check --status; true; then'),
      edits = { "sha512sum --check --status; then", "sha512sum --check --status; true; then" } },
    { name = "the check piped into a log",
      expect = differs(loop, 7, '  if [ -f "$debs/$name" ] && echo "$sum  $debs/$name" | sha512sum --check | tee -a "$RUNNER_TEMP/check.log"; then'),
      edits = { "sha512sum --check --status; then", 'sha512sum --check | tee -a "$RUNNER_TEMP/check.log"; then' } },
    { name = "the check's output tested instead of its status",
      expect = differs(loop, 7, '  if [ -f "$debs/$name" ] && [ -n "$(echo "$sum  $debs/$name" | sha512sum --check 2>&1)" ]; then'),
      edits = { '&& echo "$sum  $debs/$name" | sha512sum --check --status; then',
        '&& [ -n "$(echo "$sum  $debs/$name" | sha512sum --check 2>&1)" ]; then' } },
    -- the re-review's three: the copy on the check's failure, the if closed
    -- before the copy, and a sum made from the kept file itself
    { name = "the copy in an else one indent deeper", expect = differs(loop, 8, "    true"),
      edits = { copy, "              true\n              else\n" .. copy } },
    { name = "the check's if closed before the copy", expect = differs(loop, 8, "    true"),
      edits = { copy, "              true\n              fi\n              if true; then\n" .. copy } },
    { name = "the sum made from the kept file", expect = differs(loop, 7, '  sum=$(sha512sum "$debs/$name" | cut -d" " -f1)'),
      edits = { check, '            sum=$(sha512sum "$debs/$name" | cut -d" " -f1)\n' .. check } },
    -- inside the pinned making of the SHA512 list: a sum that is not apt's
    { name = "the list's sums not apt's", expect = { "the making of the SHA512 list differs from its pinned text at line 9:", "/^SHA256: /" },
      edits = { "/^SHA512: / { s = $2 }", "/^SHA256: / { s = $2 }" } },
    -- outside the pinned text: any other route into apt's archive folder
    { name = "an unchecked mv", expect = 'sudo mv "$debs"/*.deb "$archives/"', edits = added('sudo mv "$debs"/*.deb "$archives/"') },
    { name = "an unchecked install", expect = 'sudo install -m 644 "$debs"/*.deb /var/cache/apt/archives/',
      edits = added('sudo install -m 644 "$debs"/*.deb /var/cache/apt/archives/') },
    { name = "an unchecked ln", expect = 'sudo ln -s "$debs"/*.deb "$archives"', edits = added('sudo ln -s "$debs"/*.deb "$archives"') },
    { name = "a cp to a target directory", expect = 'sudo cp -t "$archives" "$debs"/*.deb', edits = added('sudo cp -t "$archives" "$debs"/*.deb') },
    { name = "the archive folder through a variable", expect = 'sudo cp "$debs"/*.deb "$apt/archives/"',
      edits = { after_loop, '          apt=/var/cache/apt\n          sudo cp "$debs"/*.deb "$apt/archives/"\n' .. after_loop } },
    { name = "a copy in another step", expect = 'a file can reach apt\'s archive folder past the hash check: sudo cp "$RUNNER_TEMP"/sc-debs/*.deb /var/cache/apt/archives/',
      edits = { "          jackd --no-realtime -d dummy", '          sudo cp "$RUNNER_TEMP"/sc-debs/*.deb /var/cache/apt/archives/\n          jackd --no-realtime -d dummy' } },
    { name = "apt pointed at the kept folder", expect = 'Dir::Cache::archives="$debs"',
      edits = { 'install -y --download-only "${packages[@]}" || status=$?\n          if',
        '-o Dir::Cache::archives="$debs" install -y --download-only "${packages[@]}" || status=$?\n          if' } },
    { name = "the restore filling apt's archive folder", expect = "/var/cache/apt/archives",
      edits = { "          path: ${{ runner.temp }}/sc-debs\n          key: ${{ steps.packages.outputs.key }}\n          restore-keys",
        "          path: /var/cache/apt/archives\n          key: ${{ steps.packages.outputs.key }}\n          restore-keys" } },
    { name = "the SHA512 list written again after its pinned making",
      expect = 'sha512sum "$RUNNER_TEMP"/sc-debs/*.deb > "$RUNNER_TEMP/sc-packages.sha512"',
      edits = { "          fi\n          prefix=", '          fi\n          sha512sum "$RUNNER_TEMP"/sc-debs/*.deb > "$RUNNER_TEMP/sc-packages.sha512"\n          prefix=' } },
    -- #792: what shadows sha512sum before the loop runs it. The issue's
    -- probe, a function above debs=, fails by the pinned start and by name
    { name = "sha512sum shadowed by a function above debs=", expect = also(differs(start, 3, "sha512sum() { :; }"),
        "a shell function is defined in the engine shard (it could shadow a command the pinned lines run): sha512sum() { :; }"),
      edits = { debs, "          sha512sum() { :; }\n" .. debs } },
    { name = "a function by the keyword, in another step",
      expect = "a shell function is defined in the engine shard (it could shadow a command the pinned lines run): function sha512sum { :; }",
      edits = { "          jackd --no-realtime -d dummy", "          function sha512sum { :; }\n          jackd --no-realtime -d dummy" } },
    { name = "sha512sum shadowed by an alias above debs=", expect = also(differs(start, 3, "shopt -s expand_aliases; alias sha512sum=true"),
        "an alias in the engine shard (it could shadow a command the pinned lines run): shopt -s expand_aliases; alias sha512sum=true"),
      edits = { debs, "          shopt -s expand_aliases; alias sha512sum=true\n" .. debs } },
    { name = "BASH_ENV in the install step's env", expect = "BASH_ENV is set (bash runs its file before every step's script): BASH_ENV: /tmp/shadow.sh",
      edits = { "        timeout-minutes: 4\n        run: |\n          echo \"jackd2 ",
        "        timeout-minutes: 4\n        env:\n          BASH_ENV: /tmp/shadow.sh\n        run: |\n          echo \"jackd2 " } },
    -- #817: a PATH key in an env block, the step's, the job's or the
    -- workflow's (each reaches the install's commands), and in a flow mapping
    { name = "PATH in the install step's env", expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/shadow:/usr/bin:/bin",
      edits = { "        timeout-minutes: 4\n        run: |\n          echo \"jackd2 ",
        "        timeout-minutes: 4\n        env:\n          PATH: /tmp/shadow:/usr/bin:/bin\n        run: |\n          echo \"jackd2 " } },
    { name = "PATH in the shard job's env", expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/shadow:/usr/bin:/bin",
      edits = { "      STRATA_ENGINE_CHECK_AREAS: ${{ matrix.areas }}\n",
        "      STRATA_ENGINE_CHECK_AREAS: ${{ matrix.areas }}\n      PATH: /tmp/shadow:/usr/bin:/bin\n" } },
    { name = "PATH in the workflow's env", job = "workflow", expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/shadow:/usr/bin:/bin",
      edits = { "\nenv:\n", "\nenv:\n  PATH: /tmp/shadow:/usr/bin:/bin\n" } },
    { name = "PATH in a flow mapping on a step's env", expect = "PATH is set in an env block (every command under it runs with that PATH): env: { PATH: /tmp/shadow }",
      edits = { "        timeout-minutes: 4\n        run: |\n          echo \"jackd2 ",
        "        timeout-minutes: 4\n        env: { PATH: /tmp/shadow }\n        run: |\n          echo \"jackd2 " } },
    -- X13's review: an env: line with a comment, and a flow mapping over
    -- lines, both on the restore step's env
    { name = "PATH under an env: line with a comment", expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/shadow:/usr/bin:/bin",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env:  # the download's limit\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n          PATH: /tmp/shadow:/usr/bin:/bin\n" } },
    { name = "PATH in a flow mapping over lines", expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/shadow",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env: {\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1,\n          PATH: /tmp/shadow\n        }\n" } },
    -- X13's re-review: a key after a comma in mid-line, over lines (bare,
    -- and quoted with a space before its colon) and on one line
    { name = "PATH after a comma in mid-line, in a flow mapping over lines",
      expect = "PATH is set in an env block (every command under it runs with that PATH): SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env: {\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s\n        }\n" } },
    { name = "a quoted PATH after a comma in mid-line, spaced before its colon",
      expect = "PATH is set in an env block (every command under it runs with that PATH): SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1,  'PATH' : /tmp/s",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env: {\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1,  'PATH' : /tmp/s\n        }\n" } },
    { name = "PATH after a comma in a flow mapping on one line",
      expect = "PATH is set in an env block (every command under it runs with that PATH): env: { SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s }",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n", "        env: { SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s }\n" } },
    -- X13's third review: a flow mapping's lines at the env:'s own indent
    -- (PyYAML takes both), opened on the env: line and on the line after it
    { name = "PATH in a flow mapping whose lines sit at the env:'s indent",
      expect = "PATH is set in an env block (every command under it runs with that PATH): SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env: {\n        SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s\n        }\n" } },
    { name = "PATH in a flow mapping opened on the line after env:",
      expect = "PATH is set in an env block (every command under it runs with that PATH): SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env:\n          {\n        SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1, PATH: /tmp/s\n        }\n" } },
    -- #825: a quoted } closes the brace early, but the block lasts to its
    -- indent's end, the later of the two
    { name = "PATH after a quoted } in a flow mapping over lines",
      expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/s",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env: {\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: \"}\",\n          PATH: /tmp/s\n        }\n" } },
    { name = "PATH after a quoted } on the env: line",
      expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/s }",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env: { SEGMENT_DOWNLOAD_TIMEOUT_MINS: \"}\",\n          PATH: /tmp/s }\n" } },
    { name = "PATH after a quoted } in a flow mapping opened on the line after env:",
      expect = "PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/s",
      edits = { "        env:\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: 1\n",
        "        env:\n          {\n          SEGMENT_DOWNLOAD_TIMEOUT_MINS: \"}\",\n          PATH: /tmp/s\n          }\n" } },
    -- the pinned start: a PATH of its own before the loop, and a line above the script's first
    { name = "a PATH of its own above debs=", expect = differs(start, 3, 'export PATH="$RUNNER_TEMP/bin:$PATH"'),
      edits = { debs, '          export PATH="$RUNNER_TEMP/bin:$PATH"\n' .. debs } },
    { name = "a line above the install's first", expect = "the install step's start is not the script's first line: line 1 is `set +o errexit`",
      edits = { '          echo "jackd2 jackd/tweak_rt_limits', '          set +o errexit\n          echo "jackd2 jackd/tweak_rt_limits' } },
    -- what an earlier step leaves to the later ones (each step is a new
    -- bash, so a function or an alias stays in its own): GITHUB_PATH, and a
    -- PATH written to GITHUB_ENV, either way GitHub reads it
    { name = "a directory added to GITHUB_PATH in the list step",
      expect = 'GITHUB_PATH is written (its directories come first in PATH for every later step): echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"',
      edits = { prefix, '          echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"\n' .. prefix } },
    { name = "a PATH written to GITHUB_ENV in the list step",
      expect = 'PATH is written to GITHUB_ENV (it reaches every later step): echo "PATH=$RUNNER_TEMP/bin:$PATH" >> "$GITHUB_ENV"',
      edits = { prefix, '          echo "PATH=$RUNNER_TEMP/bin:$PATH" >> "$GITHUB_ENV"\n' .. prefix } },
    { name = "a PATH written to GITHUB_ENV as a block",
      expect = "PATH is written to GITHUB_ENV (it reaches every later step): echo 'PATH<<END'",
      edits = { prefix, "          {\n            echo 'PATH<<END'\n            echo \"$RUNNER_TEMP/bin\"\n            echo END\n          } >> \"$GITHUB_ENV\"\n" .. prefix } },
  }
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.cache_problems, cases, "engine-shard")
  -- and none of them refuses a step that reads PATH or writes another
  -- variable to GITHUB_ENV (the workflow writes to GITHUB_ENV nowhere today)
  for _, line in ipairs({ 'echo "PATH is $PATH"', 'echo "SC_STARTED=1" >> "$GITHUB_ENV"', 'export MYPATH="$RUNNER_TEMP/bin"' }) do
    assert_equal(table.concat(CI_WORKFLOW.cache_problems(CI_WORKFLOW.mutated(workflow, prefix, "          " .. line .. "\n" .. prefix)), " | "), "",
      "the cache problems of a list step with " .. line)
  end
  -- #817: nor an env block with other keys (the restore step's has one)
  local install_start = "        timeout-minutes: 4\n        run: |\n          echo \"jackd2 "
  for _, env in ipairs({ "        env:\n          SC_STARTED: 1\n          MYPATH: /tmp/bin\n", "        env: { PATH_NOTE: none }\n",
      "        env:\n          STRATA_PATH: /tmp/bin\n", "        env:  # PATH is the runner's own\n          SC_STARTED: 1\n",
      "        env: {\n          SC_STARTED: 1,\n          MYPATH: /tmp/bin\n        }\n", "        with:\n          path: /tmp/bin\n",
      "        env: {\n          SC_STARTED: 1, MYPATH: /tmp/bin\n        }\n", "        env: { SC_STARTED: 1, MYPATH: /tmp/bin }\n",
      "        env: { SC_STARTED: \"}\",\n          MYPATH: /tmp/bin }\n        with:\n          path: /tmp/bin\n",
      "        env: {\n        SC_STARTED: 1\n        }\n        with:\n          path: /tmp/bin\n",
      "        env:\n          {\n        SC_STARTED: \"${{ github.sha }}\"\n        }\n        with:\n          path: /tmp/bin\n" }) do
    assert_equal(table.concat(CI_WORKFLOW.cache_problems(CI_WORKFLOW.mutated(workflow, install_start,
      "        timeout-minutes: 4\n" .. env .. "        run: |\n          echo \"jackd2 ")), " | "), "",
      "the cache problems of an install step with " .. env)
  end
end)

-- #786: what would weaken apt's own checks, each refused (apt-get(8),
-- apt-transport-https(1), apt.conf(5) and apt's configure-index).
-- --allow-downgrades is not among them: apt-get(8) says only that apt
-- continues without asking when it downgrades; authentication is
-- --allow-unauthenticated's, refused, as --force-yes is, which apt-get(8)
-- says stands for --allow-unauthenticated and three others
test("the workflow refuses every weakening of apt's checks and every install of a file path (#786)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  assert_equal(table.concat(CI_WORKFLOW.apt_weakenings(workflow), " | "), "", "the workflow's weakenings")
  local install = '          sudo apt-get $APT_NETWORK_OPTIONS install -y "${packages[@]}"\n'
  local function on_install(extra) return { install, '          sudo apt-get $APT_NETWORK_OPTIONS install -y ' .. extra .. ' "${packages[@]}"\n' } end
  local function instead(line) return { install, "          " .. line .. "\n" } end
  local cases = {
    { name = "--force-yes", expect = "--force-yes", edits = on_install("--force-yes") },
    { name = "Verify-Peer=false", expect = "Verify-Peer", edits = on_install("-o Acquire::https::Verify-Peer=false") },
    { name = "Verify-Host=false", expect = "Verify-Host", edits = on_install("-o Acquire::https::Verify-Host=false") },
    { name = "--allow-insecure-repositories", expect = "--allow-insecure-repositories",
      edits = { '45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}"', '45 apt-get $APT_NETWORK_OPTIONS --allow-insecure-repositories "${ubuntu_only[@]}"' } },
    { name = "AllowWeakRepositories", expect = "AllowWeakRepositories", edits = on_install("-o Acquire::AllowWeakRepositories=true") },
    { name = "Check-Date", expect = "Check-Date", edits = on_install("-o Acquire::Check-Date=false") },
    { name = "apt-get install of ./x.deb", expect = "./x.deb", edits = instead("sudo apt-get $APT_NETWORK_OPTIONS install -y ./x.deb") },
    { name = "apt install of a path", expect = "/path/x.deb", edits = instead("sudo apt install -y /path/x.deb") },
    { name = "apt-get install of a kept file", expect = '"$debs/$name"', edits = instead('sudo apt-get $APT_NETWORK_OPTIONS install -y "$debs/$name"') },
    { name = "a path among the packages", expect = '"$debs/jackd2.deb"',
      edits = { 'packages=(jackd2 "supercollider-language', 'packages=("$debs/jackd2.deb" "supercollider-language' } },
    -- X2's list, as before
    { name = "--allow-unauthenticated", expect = "--allow-unauthenticated", edits = on_install("--allow-unauthenticated") },
    { name = "trusted=yes", expect = "trusted=yes", edits = instead('echo "deb [trusted=yes] file:/x ./" | sudo tee /etc/apt/sources.list.d/x.list') },
    { name = "Check-Valid-Until", expect = "Check-Valid-Until", edits = on_install("-o Acquire::Check-Valid-Until=false") },
    { name = "dpkg --install", expect = "dpkg --install", edits = instead('sudo dpkg --install "$debs"/*.deb') },
    { name = "dpkg -i", expect = "dpkg -i", edits = instead('sudo dpkg -i "$debs"/*.deb') },
    { name = "dpkg --unpack", expect = "dpkg --unpack", edits = instead('sudo dpkg --unpack "$debs"/*.deb') },
    -- #1005: the list step's ubuntu_only names Ubuntu's sources file, and
    -- only that line, exactly as pinned, may: a write to the file, or the
    -- line with anything added, is still refused
    { name = "a write to Ubuntu's sources file", expect = "sources.list: echo",
      edits = instead('echo "Types: deb" | sudo tee -a /etc/apt/sources.list.d/ubuntu.sources') },
    { name = "the list's ubuntu_only reading a second file", expect = "sources.list: ubuntu_only=(",
      edits = { "-o Dir::Etc::sourceparts=-)", "-o Dir::Etc::sourceparts=- -o Dir::Etc::sourcelist=/etc/apt/sources.list)" } },
    { name = "the list's ubuntu_only reading parts from another folder", expect = "dir::etc::source: ubuntu_only=(",
      edits = { "-o Dir::Etc::sourceparts=-)", "-o Dir::Etc::sourceparts=/tmp/parts)" } },
    { name = "the install reading another sources file", expect = "dir::etc::source: sudo apt-get",
      edits = on_install("-o Dir::Etc::SourceList=/tmp/x.list") },
    { name = "the install reading another parts folder", expect = "dir::etc::source: sudo apt-get",
      edits = on_install("-o dir::etc::sourceparts=/tmp/parts") },
  }
  -- #1011: apt's configuration, keyrings and sources moved or written
  for _, case in ipairs(CI_WORKFLOW.relocation_cases()) do cases[#cases + 1] = case end
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.apt_weakenings, cases, "engine-shard")
  -- #1011: a -c or -C of a command that is not apt's, a read of a file
  -- under /etc/apt/ and the Dir::State of the SHA512 list's making pass;
  -- #1024: so do Acquire::Retries, a read from /usr/share/keyrings/ and a
  -- gpg --verify against a keyring there
  local install = '          sudo apt-get $APT_NETWORK_OPTIONS install -y "${packages[@]}"\n'
  local passes = "          python3 -c 'import sys'\n          git -C \"$RUNNER_TEMP\" status\n"
    .. "          cp /etc/apt/apt-mirrors.txt \"$RUNNER_TEMP/\"\n          sudo apt-get -o Dir::State::status=/tmp/s check\n"
    .. "          sudo apt-get -o Acquire::Retries=1 check\n          cp /usr/share/keyrings/ubuntu-archive-keyring.gpg \"$RUNNER_TEMP/\"\n"
    .. "          gpg --no-default-keyring --keyring /usr/share/keyrings/ubuntu-archive-keyring.gpg --verify x.sig x\n"
    .. "          cd /usr/share/doc\n          cd /tmp\n          echo x > ../keyrings/x.gpg\n          cd \"$RUNNER_TEMP\"\n          echo x > keyrings/x.gpg\n"
  for _, cache in ipairs(CI_WORKFLOW.CACHES) do
    assert_equal(table.concat(CI_WORKFLOW.apt_weakenings(CI_WORKFLOW.mutated(workflow, install, passes .. install, cache.job)), " | "), "",
      "the weakenings of " .. cache.where .. " with python3 -c, git -C, a read under /etc/apt/, Dir::State, Acquire::Retries and reads under /usr/share/keyrings/")
  end
  -- the pinned ubuntu_only line itself, as the workflow indents it, passes
  assert_equal(table.concat(CI_WORKFLOW.apt_weakenings("          " .. CI_WORKFLOW.UBUNTU_ONLY .. "\n"), " | "), "",
    "the weakenings of the pinned ubuntu_only line")
end)

-- #786: the save is the step right after the install, and runs only when the
-- restore missed: a rerun of a shard that was too slow finds what a faster
-- one saved, whatever the check did
test("the cache is saved by the step right after the install, only on the restore's miss (#786)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  local condition = "        if: steps.restore.outputs.cache-hit != 'true'\n"
  local save_start = workflow:find("      # Saved right after the install", 1, true)
  local save_end = workflow:find("      # scsynth talks to JACK", 1, true)
  assert_true(save_start ~= nil and save_end ~= nil, "the save step and the JACK step after it are found")
  local save = workflow:sub(save_start, save_end - 1)
  local check_run = workflow:match("(      %- name: Engine check\n        run: [^\n]*\n)")
  assert_true(check_run ~= nil, "the engine check step is found")
  local cases = {
    { name = "the save moved after the engine check", expect = "the save is not the step right after the install",
      edits = { save, "", check_run, check_run .. "\n" .. save } },
    { name = "the save made unconditional", expect = "the save runs on an exact hit", edits = { condition, "" } },
    { name = "the save run always", expect = "the save runs on an exact hit",
      edits = { condition, "        if: always()\n" } },
  }
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.cache_problems, cases, "engine-shard")
end)

-- #993: the Lua jobs keep their packages by the engine shard's pieces, so
-- the same checks refuse the same edits there: each pinned piece fails by
-- its first changed line, every other route into apt's archive folder or
-- write of the list is named, the save stays right after the install and
-- only on a miss, nothing shadows a command the pinned lines run, and the
-- Lua job's key never starts as the shard's does
test("a kept package reaches apt only through the hash check in the Lua jobs too, under a key of their own (#993)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  assert_equal(table.concat(CI_WORKFLOW.cache_problems(workflow), " | "), "", "the workflow's cache problems")
  local function differs(region, line, found)
    return { "lua-suite: the " .. region .. " differs from its pinned text at line " .. line .. ":", "found `" .. found .. "`" }
  end
  local loop, start, list = "verify-and-copy loop", "install step's start", "making of the SHA512 list"
  local after_loop = '          echo "$kept package files from the cache, each matching apt\'s lists"\n'
  local function added(line) return { after_loop, "          " .. line .. "\n" .. after_loop } end
  local debs, first = '          debs="$RUNNER_TEMP/lua-debs"\n', "          packages=(lua5.3 luajit)\n"
  local reach = "lua-suite: a file can reach apt's archive folder past the hash check: "
  local cases = {
    { name = "the kept folder copied before the check", expect = differs(loop, 5, 'sudo cp "$debs"/*.deb "$archives/"'),
      edits = { "          kept=0\n", '          sudo cp "$debs"/*.deb "$archives/"\n          kept=0\n' } },
    { name = "the check made optional", expect = differs(loop, 7, '  if [ -f "$debs/$name" ] || echo "$sum  $debs/$name" | sha512sum --check --status; then'),
      edits = { '[ -f "$debs/$name" ] && echo', '[ -f "$debs/$name" ] || echo' } },
    { name = "the check reading another list", expect = differs(loop, 11, 'done < "$debs/sums.sha512"'),
      edits = { '            fi\n          done < "$RUNNER_TEMP/lua-packages.sha512"\n          echo "$kept',
        '            fi\n          done < "$debs/sums.sha512"\n          echo "$kept' } },
    { name = "the list's sums not apt's", expect = { "lua-suite: the " .. list .. " differs from its pinned text at line 8:", "/^SHA256: /" },
      edits = { "/^SHA512: / { s = $2 }", "/^SHA256: / { s = $2 }" } },
    { name = "the list made against the image's own dpkg status", expect = differs(list, 3, "apt-get $APT_NETWORK_OPTIONS \"${ubuntu_only[@]}\" install -s lua5.3 luajit \\"),
      edits = { '"${nothing_installed[@]}" install -s lua5.3', "install -s lua5.3" } },
    { name = "an unchecked mv", expect = reach .. 'sudo mv "$debs"/*.deb "$archives/"', edits = added('sudo mv "$debs"/*.deb "$archives/"') },
    { name = "a copy in the suite's step", expect = reach .. 'sudo cp "$RUNNER_TEMP"/lua-debs/*.deb /var/cache/apt/archives/',
      edits = { "        run: ${{ matrix.lua }} test/run.lua", '        run: sudo cp "$RUNNER_TEMP"/lua-debs/*.deb /var/cache/apt/archives/ && ${{ matrix.lua }} test/run.lua' } },
    { name = "apt pointed at the kept folder", expect = reach,
      edits = { 'install -y --download-only "${packages[@]}" || status=$?\n          if',
        '-o Dir::Cache::archives="$debs" install -y --download-only "${packages[@]}" || status=$?\n          if' } },
    { name = "the restore filling apt's archive folder", expect = "lua-suite: the kept folder the restore fills (/var/cache/apt/archives)",
      edits = { "          path: ${{ runner.temp }}/lua-debs\n          key: ${{ steps.packages.outputs.key }}\n          restore-keys",
        "          path: /var/cache/apt/archives\n          key: ${{ steps.packages.outputs.key }}\n          restore-keys" } },
    { name = "the SHA512 list written again after its pinned making",
      expect = 'lua-suite: the SHA512 list is written past its pinned making: sha512sum "$RUNNER_TEMP"/lua-debs/*.deb > "$RUNNER_TEMP/lua-packages.sha512"',
      edits = { "          fi\n          prefix=", '          fi\n          sha512sum "$RUNNER_TEMP"/lua-debs/*.deb > "$RUNNER_TEMP/lua-packages.sha512"\n          prefix=' } },
    { name = "sha512sum shadowed by a function above debs=", expect = { differs(start, 2, "sha512sum() { :; }")[1],
        "lua-suite: a shell function is defined in the Lua job (it could shadow a command the pinned lines run): sha512sum() { :; }" },
      edits = { debs, "          sha512sum() { :; }\n" .. debs } },
    { name = "an alias in the suite's step", expect = "lua-suite: an alias in the Lua job",
      edits = { "        run: nproc\n", "        run: shopt -s expand_aliases; alias sha512sum=true; nproc\n" } },
    { name = "a line above the install's first", expect = "lua-suite: the install step's start is not the script's first line: line 1 is `set +o errexit`",
      edits = { first, "          set +o errexit\n" .. first } },
    { name = "PATH in the Lua job's env", expect = "lua-suite: PATH is set in an env block (every command under it runs with that PATH): PATH: /tmp/shadow:/usr/bin:/bin",
      edits = { "    timeout-minutes: 12\n    runs-on: ubuntu-24.04\n", "    timeout-minutes: 12\n    runs-on: ubuntu-24.04\n    env:\n      PATH: /tmp/shadow:/usr/bin:/bin\n" } },
    { name = "a directory added to GITHUB_PATH in the list step",
      expect = 'lua-suite: GITHUB_PATH is written (its directories come first in PATH for every later step): echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"',
      edits = { '          prefix="lua-debs-', '          echo "$RUNNER_TEMP/bin" >> "$GITHUB_PATH"\n          prefix="lua-debs-' } },
    { name = "the save made unconditional", expect = "lua-suite: the save runs on an exact hit",
      edits = { "        if: steps.restore.outputs.cache-hit != 'true'\n", "" } },
    { name = "a step between the install and the save", expect = "lua-suite: the save is not the step right after the install",
      edits = { "      - name: Keep Lua 5.3 and LuaJIT's packages\n", "      - name: A step between\n        run: true\n      - name: Keep Lua 5.3 and LuaJIT's packages\n" } },
    { name = "the Lua job's key the shard's", expect = { "lua-suite: the cache key's prefix (sc-debs-$ImageOS-$RUNNER_ARCH-) does not start with lua-debs-",
        "the cache keys of engine-shard and lua-suite start alike (sc-debs-, sc-debs-)" },
      edits = { 'prefix="lua-debs-$ImageOS-$RUNNER_ARCH-"', 'prefix="sc-debs-$ImageOS-$RUNNER_ARCH-"' } },
    { name = "the Lua job's key a longer start of the shard's", expect = "the cache keys of engine-shard and lua-suite start alike (sc-debs-, sc-debs-lua-)",
      edits = { 'prefix="lua-debs-$ImageOS-$RUNNER_ARCH-"', 'prefix="sc-debs-lua-$ImageOS-$RUNNER_ARCH-"' } },
  }
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.cache_problems, cases, "lua-suite")
  -- and what an apt weakening is in the shard is one in the Lua job
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.apt_weakenings, {
    { name = "dpkg -i of the kept files", expect = "dpkg -i", edits = { '          sudo apt-get $APT_NETWORK_OPTIONS install -y "${packages[@]}"\n',
      '          sudo dpkg -i "$debs"/*.deb\n' } },
    { name = "an install of a kept file", expect = '"$debs/$name"', edits = { '          sudo apt-get $APT_NETWORK_OPTIONS install -y "${packages[@]}"\n',
      '          sudo apt-get $APT_NETWORK_OPTIONS install -y "$debs/$name"\n' } },
  }, "lua-suite")
  -- #1011: and so is a move or write of apt's configuration
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.apt_weakenings, CI_WORKFLOW.relocation_cases(), "lua-suite")
end)

-- #785: the engine shards keep the package files they download (actions/cache,
-- restored before the install, saved after it) and trust none unchecked: apt
-- takes any file of the right size in its archive folder as downloaded, so a
-- kept file reaches apt only when its SHA512 is the one apt's lists give.
-- #993: the Lua jobs keep theirs the same way, under a key of their own
test("the engine shards and the Lua jobs keep their packages between runs and check each one against apt's lists (#785, #993)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  local commits = {}
  for _, cache in ipairs(CI_WORKFLOW.CACHES) do
    local job, at = CI_WORKFLOW.cache_steps(workflow, cache)
    assert_true(job ~= nil, "the workflow has the job " .. cache.job)
    for _, part in ipairs({ "list", "restore", "install", "save", "check" }) do
      assert_true(at[part] ~= nil, cache.where .. " has its " .. part .. " step")
    end
    assert_true(at.list < at.restore and at.restore < at.install and at.install < at.save and at.save < at.check,
      cache.where .. " lists its packages, restores them, installs, keeps them, then runs " .. cache.suite)
    -- saved as soon as the install has succeeded, whatever the check does, so
    -- a rerun of a job that was too slow finds what a faster one saved
    assert_equal(at.save, at.install + 1, cache.where .. "'s save is the step right after the install")
    local list, restore, install, save = job.steps[at.list], job.steps[at.restore], job.steps[at.install], job.steps[at.save]
    -- the key names the packages (each file's name and SHA512) and the image's
    -- release, never its build or a mirror's address
    local key = list.text:match('echo "key=([^\n]*)"')
    assert_true(key ~= nil and key:find("sha256sum", 1, true) ~= nil, "the key ends in a hash of the package list: " .. tostring(key))
    local prefix = list.text:match('prefix="([^"\n]*)"') or ""
    assert_equal(prefix:sub(1, #cache.prefix), cache.prefix, cache.where .. "'s key is its own")
    local parts = cache.job == "engine-shard" and { "$ImageOS", "$RUNNER_ARCH", "$SC_APT_VERSION" } or { "$ImageOS", "$RUNNER_ARCH" }
    for _, part in ipairs(parts) do
      assert_true(prefix:find(part, 1, true) ~= nil, "the key's prefix names " .. part .. ": " .. prefix)
    end
    assert_true(not list.text:find("ImageVersion", 1, true) and not list.text:find("print-uris", 1, true),
      "the key names no image build and no mirror (the run of #785 had two of each)")
    assert_true(list.text:find("SHA512", 1, true) ~= nil, "the list holds each file's SHA512 from apt's lists")
    -- one key for every job of a kind: the list is what the packages need
    -- with nothing installed, so what an image has installed does not change it
    assert_true(list.text:find('Dir::State::status="$RUNNER_TEMP/empty-status"', 1, true) ~= nil
      and list.text:find(': > "$RUNNER_TEMP/empty-status"', 1, true) ~= nil, "the list is made against an empty dpkg status")
    -- restore and save: the same pinned action, folder and key; neither can fail the job
    assert_equal(save.uses:match("@(%x+)"), restore.uses:match("@(%x+)"), "restore and save are one release of actions/cache")
    commits[#commits + 1] = restore.uses:match("@(%x+)")
    local path = restore.text:match("\n%s+path:%s*([^\n]-)%s*\n")
    assert_equal(path, "${{ runner.temp }}/" .. cache.kept, "the kept folder is in the runner's temp folder")
    assert_equal(save.text:match("\n%s+path:%s*([^\n]-)%s*\n"), path, "save keeps the folder restore fills")
    for _, step in ipairs({ restore, save }) do
      assert_equal(step.text:match("\n%s+key:%s*([^\n]-)%s*\n"), "${{ steps.packages.outputs.key }}", tostring(step.uses) .. "'s key")
      assert_true(step.may_fail and step.minutes ~= nil, tostring(step.uses) .. " has a limit and never fails " .. cache.where)
    end
    assert_equal(restore.text:match("\n%s+restore%-keys:%s*([^\n]-)%s*\n"), "${{ steps.packages.outputs.prefix }}", "a near miss restores most files")
    assert_equal(save.text:match("\n%s+if:%s*([^\n]-)%s*\n"), "steps." .. tostring(restore.id) .. ".outputs.cache-hit != 'true'",
      "an exact hit saves nothing")
    -- the install hands apt only checked files; apt still installs
    assert_true(install.text:find("sha512sum --check", 1, true) ~= nil, "each kept file is checked against its SHA512")
    assert_true(not install.text:find("dpkg -i", 1, true) and not install.text:find("dpkg --install", 1, true), "nothing is installed past apt")
    assert_true(install.text:find('install -y --download-only "${packages[@]}"', 1, true) ~= nil,
      "apt downloads what the cache lacked before the kept folder is refilled")
  end
  -- every cache step is the one pinned release of actions/cache (#533)
  for _, commit in ipairs(commits) do assert_equal(commit, commits[1], "every cache step is one release of actions/cache") end
  assert_true(CI_WORKFLOW.jobs(workflow)["engine-shard"].text:find(
    'echo "jackd2 jackd/tweak_rt_limits boolean false" | sudo debconf-set-selections', 1, true) ~= nil, "the JACK debconf line is kept")
end)

-- #785: a slow mirror sends data, so no file fails and neither apt's timeout
-- nor its mirror failover ends it. The download has a limit of its own, then
-- runs again with the runner's second mirror (https://archive.ubuntu.com,
-- already in its mirror list) first, within the step's limit; apt's lists,
-- their signatures and the files' hashes are checked as before. #993: so in
-- the Lua jobs
test("a slow mirror ends a job's download early and tries archive.ubuntu.com, apt's checks unchanged (#785, #993)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  for _, cache in ipairs(CI_WORKFLOW.CACHES) do
    local job, at = CI_WORKFLOW.cache_steps(workflow, cache)
    local install = job and at.install and job.steps[at.install]
    assert_true(install, cache.where .. " has its install step")
    local limits = {}
    for seconds in install.text:gmatch("sudo timeout %-%-kill%-after=%d+ (%d+) apt%-get %$APT_NETWORK_OPTIONS install %-y %-%-download%-only ") do
      limits[#limits + 1] = tonumber(seconds)
    end
    assert_equal(#limits, 2, cache.where .. ": the download runs under a limit, and once more after the mirrors are reordered")
    assert_true(limits[1] <= 60, "the first try gives up within a minute (a normal one takes seconds): " .. tostring(limits[1]))
    local first, second = install.text:find("sudo timeout", 1, true), select(2, install.text:find("sudo timeout.-sudo timeout"))
    local reorder = install.text:find("sudo sed -i -E '/^https:\\/\\/archive\\.ubuntu\\.com\\/ubuntu\\//! s/priority:[0-9]+/priority:9/' \"$mirrors\"", 1, true)
    assert_true(reorder ~= nil and first < reorder and reorder < second, cache.where .. ": only the mirror list's priorities change, between the two tries")
    assert_true(install.text:find("mirrors=/etc/apt/apt-mirrors.txt", 1, true) ~= nil, "the list changed is the runner's own")
    -- both tries and the unpacking (about 25 s) fit in the step's limit
    assert_true(limits[1] + limits[2] + 30 <= install.minutes * 60, cache.where .. ": both tries fit the step's " .. install.minutes .. " minutes")
    -- #786: the worst run that still succeeds (each try to its limit and its
    -- kill, the second one finishing, then the refill and the unpacking) ends
    -- inside the step's limit, so a failure is the step's own ::error:: line
    local worst = CI_WORKFLOW.SECONDS.after_downloads
    for kill, seconds in install.text:gmatch("sudo timeout %-%-kill%-after=(%d+) (%d+) apt%-get ") do
      worst = worst + tonumber(kill) + tonumber(seconds)
    end
    assert_true(worst <= install.minutes * 60,
      cache.where .. ": the worst successful install (" .. worst .. " s) fits the step's " .. install.minutes .. " minutes")
    assert_true(install.text:find("::error::", 1, true) ~= nil, cache.where .. ": a download that never finishes fails the step with its own line")
  end
  -- X2's list (allow-unauthenticated, AllowInsecureRepositories, trusted=yes,
  -- Check-Valid-Until, AllowDowngradeToInsecureRepositories, dpkg -i, dpkg
  -- --install, sources.list) is in CI_WORKFLOW.apt_weakenings, with #786's
  assert_equal(table.concat(CI_WORKFLOW.apt_weakenings(workflow), " | "), "",
    "the workflow never weakens apt's checks or changes its sources")
end)

-- #999: a slow mirror stalls the list step's `apt-get update` too (73 to
-- 155 s seen, and twice no end before the step's own limit: #986's run on
-- f003baff, #1004's first attempt), and the cache cannot spare it: the
-- SHA512 list must come from lists this job fetched. So in both jobs the
-- update runs under `timeout` with a kill-after, and when it is killed or
-- fails it runs once more after the download retry's own sed has put
-- https://archive.ubuntu.com first; when neither try updates the lists the
-- step fails by its ::error:: line, inside its own limit, before the list
-- is made. The piece is pinned verbatim in both jobs (CI_WORKFLOW.LIST_UPDATE)
test("a list step's apt-get update runs under a limit, then once more with archive.ubuntu.com first, in both jobs (#999)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  assert_equal(table.concat(CI_WORKFLOW.cache_problems(workflow), " | "), "", "the workflow's cache problems")
  local sed = "sudo sed -i -E '/^https:\\/\\/archive\\.ubuntu\\.com\\/ubuntu\\//! s/priority:[0-9]+/priority:9/' \"$mirrors\""
  for _, cache in ipairs(CI_WORKFLOW.CACHES) do
    local job, at = CI_WORKFLOW.cache_steps(workflow, cache)
    local list, install = job and at.list and job.steps[at.list], job and at.install and job.steps[at.install]
    assert_true(list and install, cache.where .. " has its list and install steps")
    local updates, calls = CI_WORKFLOW.update_tries(list), 0
    for _, line in ipairs(CI_WORKFLOW.script(list)) do
      if line:find("apt%-get [^\n]-update") then calls = calls + 1 end
    end
    assert_equal(#updates, 2, cache.where .. ": the list's update runs under a limit, and once more after the mirrors are reordered")
    assert_equal(calls, #updates, cache.where .. ": every apt-get update of the list is one of its two tries under timeout")
    -- the tries the budget sums read: the first cut at 45 s (a fast
    -- mirror's update took 1 to 34 s), the retry at 60, each killed 5 s
    -- after its signal
    for index, expected in ipairs({ { seconds = 45, kill = 5 }, { seconds = 60, kill = 5 } }) do
      local try = updates[index] or {}
      assert_equal(try.seconds, expected.seconds, cache.where .. ": the list's update try " .. index .. "'s limit, in seconds")
      assert_equal(try.kill, expected.kill, cache.where .. ": the list's update try " .. index .. "'s kill-after, in seconds")
    end
    -- the reorder is the download retry's own line, between the two tries
    local first, second = list.text:find("sudo timeout", 1, true), select(2, list.text:find("sudo timeout.-sudo timeout"))
    local reorder = list.text:find(sed, 1, true)
    assert_true(reorder ~= nil and first < reorder and reorder < second, cache.where .. ": the list's retry reorders the mirrors between its tries")
    assert_true(install.text:find(sed, 1, true) ~= nil, cache.where .. ": the reorder is the install's own sed")
    -- both tries to their limits and kills and the apt-cache work fit the
    -- step's limit, so a list that never updates fails by its own line
    local worst = updates[1].seconds + updates[1].kill + updates[2].seconds + updates[2].kill + CI_WORKFLOW.SECONDS.list_work
    assert_true(worst < list.minutes * 60, cache.where .. ": both updates to their kills (" .. worst .. " s) fit the list's "
      .. list.minutes .. " minutes")
    local failed, made = list.text:find("::error::apt's lists did not update", 1, true), list.text:find(': > "$RUNNER_TEMP/empty-status"', 1, true)
    assert_true(failed and made and failed < made, cache.where .. ": a list that did not update fails before the SHA512 list is made")
  end
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.cache_problems, {
    { name = "the Lua list's update with no limit", job = "lua-suite",
      expect = "lua-suite: the list step's update differs from its pinned text at line 5:",
      edits = { 'sudo timeout --kill-after=5 45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}"', 'sudo apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}"' } },
    { name = "the shard's retry only on a kill", job = "engine-shard",
      expect = "engine-shard: the list step's update differs from its pinned text at line 6:",
      edits = { 'if [ "$status" -ne 0 ] && grep', 'if { [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; } && grep' } },
    { name = "the Lua list going on after neither update", job = "lua-suite",
      expect = "lua-suite: the list step's update differs from its pinned text at line 15:",
      edits = { "            exit 1\n          fi\n          release=", "            true\n          fi\n          release=" } },
    { name = "the shard's list with a line inside its update", job = "engine-shard",
      expect = "engine-shard: the list step's update differs from its pinned text at line 2:",
      edits = { "          set -o pipefail\n          mirrors=", "          set -o pipefail\n          true\n          mirrors=" } },
    { name = "the Lua list's lists restored before the update", job = "lua-suite",
      expect = "lua-suite: the list step's update is not the script's first line: line 1 is `sudo cp -r \"$RUNNER_TEMP/lists\" /var/lib/apt/`",
      edits = { "          set -o pipefail\n          mirrors=", "          sudo cp -r \"$RUNNER_TEMP/lists\" /var/lib/apt/\n          set -o pipefail\n          mirrors=" } },
  })
end)

-- #1005: apt-get update exits 0 when a list fails with only a warning
-- (`W: Failed to fetch ...`, `W: Some index files failed to download`),
-- and the old list stays: the SHA512 list would come from it. So in both
-- jobs both tries read Ubuntu's sources file alone with --error-on=any (a
-- list of Ubuntu's that did not download exits 100, so it gets the retry
-- through the reorder, then the ::error:: line) and --no-list-cleanup (the
-- runner's third-party sources are neither read nor emptied, so they fail
-- nothing); then the step checks that what the update read holds Ubuntu's
-- main and universe lists for the runner's release, so a sources file that
-- is missing or names nothing, which apt reads as nothing to update and
-- exit 0, fails by its own ::error:: line before the SHA512 list is made
test("a list step's update reads Ubuntu's sources alone, fails on any of their errors, and checks it read main and universe, in both jobs (#1005)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  assert_equal(table.concat(CI_WORKFLOW.cache_problems(workflow), " | "), "", "the workflow's cache problems")
  assert_equal(CI_WORKFLOW.UBUNTU_ONLY,
    "ubuntu_only=(-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=-)",
    "the update reads Ubuntu's sources file and no sources.list.d part")
  for _, cache in ipairs(CI_WORKFLOW.CACHES) do
    local job, at = CI_WORKFLOW.cache_steps(workflow, cache)
    local list = job and at.list and job.steps[at.list]
    assert_true(list ~= nil, cache.where .. " has its list step")
    local strict, tries = 0, 0
    for _, line in ipairs(CI_WORKFLOW.script(list)) do
      if line:find("apt%-get [^\n]-update") then
        tries = tries + 1
        if line:find('apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any --no-list-cleanup update', 1, true) then
          strict = strict + 1
        end
      end
    end
    assert_equal(tries, 2, cache.where .. ": the list's update tries")
    assert_equal(strict, tries, cache.where .. ": every update of the list reads Ubuntu's sources alone, fails on any of their errors and empties no other list")
    local read = list.text:find("for component in main universe; do", 1, true)
    local stale = list.text:find("::error::Ubuntu's $release $component list is not among the lists the update read", 1, true)
    local updated = list.text:find("::error::apt's lists did not update", 1, true)
    local made = list.text:find(': > "$RUNNER_TEMP/empty-status"', 1, true)
    assert_true(updated and read and stale and made and updated < read and read < stale and stale < made,
      cache.where .. ": after the update, a list of main or universe the update did not read fails the step before the SHA512 list is made")
  end
  -- the check, lines 17 to the piece's end, as the workflow indents it
  local check, number = {}, 0
  for line in CI_WORKFLOW.LIST_UPDATE:gmatch("([^\n]*)\n") do
    number = number + 1
    if number >= 17 then check[#check + 1] = "          " .. line .. "\n" end
  end
  check = table.concat(check)
  CI_WORKFLOW.failing_cases(workflow, CI_WORKFLOW.cache_problems, {
    { name = "the Lua list's update reading every source", job = "lua-suite",
      expect = "lua-suite: the list step's update differs from its pinned text at line 3:",
      edits = { " -o Dir::Etc::sourceparts=-)", ")" } },
    { name = "the shard's update trusting a warning", job = "engine-shard",
      expect = "engine-shard: the list step's update differs from its pinned text at line 5:",
      edits = { '45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any ', '45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" ' } },
    { name = "the Lua list's retry trusting a warning", job = "lua-suite",
      expect = "lua-suite: the list step's update differs from its pinned text at line 11:",
      edits = { '60 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any ', '60 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" ' } },
    { name = "the shard's update emptying the third-party lists", job = "engine-shard",
      expect = "engine-shard: the list step's update differs from its pinned text at line 5:",
      edits = { '45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any --no-list-cleanup update', '45 apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" --error-on=any update' } },
    { name = "the shard's list with no check of what the update read", job = "engine-shard",
      expect = { "engine-shard: the list step's update differs from its pinned text at line 17:", 'found `: > "$RUNNER_TEMP/empty-status"`' },
      edits = { check, "" } },
    { name = "the Lua list with no check of what the update read", job = "lua-suite",
      expect = { "lua-suite: the list step's update differs from its pinned text at line 17:", 'found `: > "$RUNNER_TEMP/empty-status"`' },
      edits = { check, "" } },
    { name = "the Lua list checking main alone", job = "lua-suite",
      expect = "lua-suite: the list step's update differs from its pinned text at line 19:",
      edits = { "for component in main universe; do", "for component in main; do" } },
    { name = "the Lua list's packages read from every source's lists", job = "lua-suite",
      expect = { "lua-suite: the making of the SHA512 list differs from its pinned text at line 3:", "found `apt-get $APT_NETWORK_OPTIONS \"${nothing_installed[@]}\" install -s" },
      edits = { 'apt-get $APT_NETWORK_OPTIONS "${ubuntu_only[@]}" "${nothing_installed[@]}" install -s', 'apt-get $APT_NETWORK_OPTIONS "${nothing_installed[@]}" install -s' } },
    { name = "the shard's sums read from every source's lists", job = "engine-shard",
      expect = { "engine-shard: the making of the SHA512 list differs from its pinned text at line 7:", "found `xargs apt-cache \"${nothing_installed[@]}\" show" },
      edits = { 'xargs apt-cache "${ubuntu_only[@]}" "${nothing_installed[@]}" show', 'xargs apt-cache "${nothing_installed[@]}" show' } },
    { name = "the shard's list going on after a stale list", job = "engine-shard",
      expect = "engine-shard: the list step's update differs from its pinned text at line 22:",
      edits = { "              exit 1\n            fi\n          done\n", "              true\n            fi\n          done\n" } },
  })
end)

-- The SuperCollider 3.13 image (test/run_engine_check_313.sh) runs what CI
-- runs: the same Ubuntu release and SuperCollider package
test("the 3.13 Docker image pins CI's SuperCollider and Ubuntu", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  local dockerfile = read_repo_file("test/docker/sc313/Dockerfile")
  local ci_version = workflow:match("\n%s*SC_APT_VERSION:%s*(%S+)")
  local image_version = dockerfile:match("\nARG SC_APT_VERSION=(%S+)")
  assert_true(ci_version ~= nil, "the workflow pins SC_APT_VERSION")
  assert_equal(image_version, ci_version, "test/docker/sc313/Dockerfile's SC_APT_VERSION")
  local ci_ubuntu = workflow:match("engine%-shard:.-runs%-on:%s*ubuntu%-(%S+)")
  assert_equal(dockerfile:match("\nFROM ubuntu:(%S+)"), ci_ubuntu, "the image's Ubuntu release")
  local runner = read_repo_file("test/run_engine_check_313.sh")
  assert_true(runner:find("docker/sc313", 1, true) ~= nil, "the runner builds test/docker/sc313")
end)

-- #581: a full run on 3.13 is CI's shards, each in a fresh sclang, read from
-- the workflow at each start; -l prints them and starts nothing
test("the 3.13 runner's shard list is the workflow's", function()
  local expected = h.workflow_shards()
  assert_true(expected ~= nil, "the engine-shard matrix lists its areas")
  assert_true(#expected >= 2, "the workflow has shards")
  local pipe = io.popen("cd " .. h.shell_quote(repo_root) .. " && /bin/sh test/run_engine_check_313.sh -l 2>&1; echo exit=$?")
  local output = pipe:read("*a")
  pipe:close()
  assert_equal(output, table.concat(expected, "\n") .. "\nexit=0\n", "-l prints the workflow's shards, one a line, in order, and nothing else")
end)

test("the 3.13 runner's synopsis is the same in its usage, AGENTS.md, docs/checks.md and the runner notes", function()
  local script = read_repo_file("test/run_engine_check_313.sh")
  local usage = script:match('echo "usage: %$0 (%[[^"]-)" >&2')
  assert_true(usage ~= nil, "the script prints a usage line")
  for _, flag in ipairs({ "[-1]", "[-l]", "[-c]" }) do assert_true(usage:find(flag, 1, true) ~= nil, "the usage names " .. flag) end
  assert_equal(script:match("\n# usage: [^\n]-test/run_engine_check_313%.sh (%[[^\n]*)"), usage, "the header comment's usage")
  for _, path in ipairs({ "AGENTS.md", "docs/checks.md", "docs/notes/test-harness/engine-check-runner.md" }) do
    local count = 0
    for synopsis in read_repo_file(path):gmatch("`test/run_engine_check_313%.sh (%[[^`]*)`") do
      count = count + 1
      assert_equal(synopsis, usage, path .. "'s synopsis")
    end
    assert_true(count >= 1, path .. " gives the synopsis")
  end
end)

-- #582: a doc that says how many shards CI runs says the workflow's number
local SHARD_COUNT_WORDS = { two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10, eleven = 11, twelve = 12 }
local function shard_counts(text)
  local counts = {}
  for _, pattern in ipairs({ "(%w+)%s+parallel%s+shards", "(%w+)%s+shards" }) do
    for word in text:gmatch(pattern) do
      local count = tonumber(word) or SHARD_COUNT_WORDS[word:lower()]
      if count then counts[#counts + 1] = { word = word, count = count } end
    end
  end
  return counts
end

test("every doc that counts CI's engine shards counts the workflow's (#582)", function()
  local sample = shard_counts("runs in seven parallel shards, then in four shards, in 3 shards, in its shards and in different shards")
  local found = {}
  for _, entry in ipairs(sample) do found[#found + 1] = entry.count end
  assert_equal(table.concat(found, " "), "7 4 3", "the counts a doc can quote are found, and only those")
  local shards = #h.workflow_shards()
  for _, path in ipairs(maintained_docs()) do
    for _, entry in ipairs(shard_counts(read_repo_file(path))) do
      assert_equal(entry.count, shards, path .. " says \"" .. entry.word .. " shards\"; the workflow has " .. shards)
    end
  end
end)

test("the 3.13 runner documents its sharded default", function()
  local bullet = read_repo_file("AGENTS.md"):match("\n%- `test/run_engine_check_313%.sh[^\n]*")
  local section = read_repo_file("docs/notes/test-harness/engine-check-runner.md"):match("\n### The engine check on SuperCollider 3%.13.*$")
  for name, text in pairs({ ["AGENTS.md's bullet on the 3.13 runner"] = bullet or "", ["the runner notes' 3.13 section"] = section or "" }) do
    assert_true(text:find("`-1`", 1, true) ~= nil, name .. " names -1, the run in one sclang")
    assert_true(text:find("`-l`", 1, true) ~= nil, name .. " names -l, the shard list")
    assert_true(text:find("shard", 1, true) ~= nil and text:find(".github/workflows/test.yml", 1, true) ~= nil,
      name .. " says a full run is the workflow's shards")
  end
end)

test("CI cancels superseded runs of pull requests only, never of main (#51)", function()
  local file = assert(io.open(repo_root .. "/.github/workflows/test.yml", "r")); local workflow = file:read("*a"); file:close()
  local setting = workflow:match("\n%s*cancel%-in%-progress:%s*([^\n]-)%s*\n")
  assert_equal(setting, "${{ github.event_name == 'pull_request' }}", "cancel-in-progress")
  -- a pending run in a shared group is replaced by the next one even without
  -- cancel-in-progress, so a run on main gets a group of its own
  local group = workflow:match("\n%s*group:%s*([^\n]-)%s*\n")
  assert_equal(group, "tests-${{ github.event_name == 'pull_request' && github.ref || github.run_id }}", "group")
end)


test("the engine check's default timeout fits a full local run and CI keeps 570 s (#208)", function()
  local workflow = read_repo_file(".github/workflows/test.yml")
  local step = workflow:match("%- name: Engine check\n(.-)\n\n") or workflow:match("%- name: Engine check\n(.*)$")
  assert_true(step ~= nil, "the workflow has an Engine check step")
  assert_true(step:find("ENGINE_CHECK_TIMEOUT=570", 1, true) ~= nil, "CI passes ENGINE_CHECK_TIMEOUT=570")
  assert_true(step:find("timeout %-%-kill%-after=%d+ 600 ") ~= nil, "CI keeps its 600 s limit around the shard, with a kill after it (#790)")
  local default = tonumber(read_repo_file("test/run_engine_check.sh"):match("ENGINE_CHECK_TIMEOUT:%-(%d+)}") or "")
  assert_true(default ~= nil, "the runner has a default timeout (ENGINE_CHECK_TIMEOUT:-<seconds>)")
  assert_true(read_repo_file("test/engine_check.scd"):find("{ " .. (default - 30) .. " }", 1, true) ~= nil,
    "the check's fallback deadline is the default timeout less 30 s, " .. (default - 30) .. " s")
end)

-- #816: a full run in one sclang (every area, no shards) has room under the
-- runner's default timeout: at least ENGINE_TIMEOUT_ROOM times the sum of the
-- workflow's area times (read through h.workflow_area_times, the #491 and
-- #731 tests' reader), so a new area cannot close the gap unnoticed; and the
-- docs say the default and the deadline, 30 s under it, as they are
local ENGINE_TIMEOUT_ROOM = 1.5
local function engine_timeout_problems(workflow, runner)
  local problems = {}
  local stated = h.workflow_area_times(workflow)
  if stated == 0 then stated = nil end
  local default = tonumber(runner:match("ENGINE_CHECK_TIMEOUT:%-(%d+)}") or "")
  if not stated then problems[#problems + 1] = "the workflow has no area times" end
  if not default then problems[#problems + 1] = "the runner has no default timeout (ENGINE_CHECK_TIMEOUT:-<seconds>)" end
  if stated and default and default < ENGINE_TIMEOUT_ROOM * stated then
    problems[#problems + 1] = "the default timeout, " .. default .. " s, is under " .. ENGINE_TIMEOUT_ROOM
      .. " times the area times' " .. stated .. " s (" .. ENGINE_TIMEOUT_ROOM * stated .. " s)"
  end
  return problems
end

test("the engine check's default timeout is half as much again as a full run's area times (#816)", function()
  local workflow, runner = read_repo_file(".github/workflows/test.yml"), read_repo_file("test/run_engine_check.sh")
  assert_equal(table.concat(engine_timeout_problems(workflow, runner), " | "), "", "the default timeout's room")
  -- #816's figures: 1733 s of areas (CI run 44395161831) against 1800 s
  local planted = "  # Area times on SuperCollider 3.13 at 3.8 (s):\n  # lifecycle 1000,\n  # record 733: 1733 s in all.\n"
  assert_equal(table.concat(engine_timeout_problems(planted, "sclang_timeout=${ENGINE_CHECK_TIMEOUT:-1800}\n"), " | "),
    "the default timeout, 1800 s, is under 1.5 times the area times' 1733 s (2599.5 s)", "#816's 1800 s is refused")
  assert_equal(table.concat(engine_timeout_problems(planted, "sclang_timeout=${ENGINE_CHECK_TIMEOUT:-2700}\n"), " | "),
    "", "2700 s has room for 1733 s")
  assert_equal(#engine_timeout_problems("", ""), 2, "no table and no default are both refused")
  local default = tonumber(runner:match("ENGINE_CHECK_TIMEOUT:%-(%d+)}"))
  for _, path in ipairs({ "docs/checks.md", "docs/notes/test-harness/engine-check-runner.md", "docs/notes/engine/structure.md",
      "test/run_engine_check.sh", "test/engine_check.scd" }) do
    local text = read_repo_file(path)
    for _, seconds in ipairs({ default, default - 30 }) do
      assert_true(text:find("%f[%d]" .. seconds .. "%f[%D]") ~= nil, path .. " gives the default timeout and its deadline: " .. seconds .. " s")
    end
  end
end)

-- British spellings that must not creep back in (whole words, case-insensitive).
-- Extend this table; the list lives here, so this file is the one file not scanned.
-- ("analyses" is left out: it is also the US plural noun.)
local BRITISH_SPELLINGS = {
  "behaviour", "behaviours", "centre", "centres", "centred", "centring",
  "colour", "colours", "coloured", "colouring", "favour", "favours", "favourite",
  "honour", "honours", "honoured", "neighbour", "neighbours", "flavour", "labour", "humour",
  "cancelled", "cancelling", "labelled", "labelling", "modelled", "modelling",
  "travelled", "signalled", "initialise", "initialised", "initialises",
  "organise", "organised", "organises", "realise", "realised", "realises",
  "recognise", "recognised", "recognises", "normalise", "normalised", "normalises",
  "synchronise", "synchronised", "synchronises", "optimise", "optimised", "optimises",
  "summarise", "summarised", "summarises", "prioritise", "prioritised", "prioritises",
  "analyse", "analysed", "catalogue", "dialogue", "licence", "defence",
  "grey", "metre", "fibre", "towards", "afterwards", "whilst", "amongst", "learnt",
  "judgement", "programme",
}
-- Exact "path:word" pairs allowed to stay (e.g. a quoted third-party name). Greyhole
-- needs none: whole-word matching never sees "grey" inside the UGen name.
local BRITISH_ALLOWED = {}
local SPELLING_SKIP = { ["test/unit/docs_test.lua"] = true }

local function british_hits(text, path)
  local hits, wanted = {}, {}
  for _, word in ipairs(BRITISH_SPELLINGS) do wanted[word] = true end
  local line_number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    for word in line:lower():gmatch("%a+") do
      if wanted[word] and not BRITISH_ALLOWED[path .. ":" .. word] then
        table.insert(hits, ("%s:%d:%s"):format(path, line_number, word))
      end
    end
  end
  return hits
end

local function spelling_files()
  local listing = assert(io.popen("cd '" .. repo_root .. "' && git ls-files")):read("*a")
  local files = {}
  for path in listing:gmatch("[^\n]+") do
    local scanned = path == "strata.lua" or path == "README.md" or path == "AGENTS.md"
      or path == "CHANGELOG.md" or path:match("^lib/.*%.sc$")
      or path:match("^lib/.*%.lua$") or path:match("^test/.*%.lua$")
      or path:match("^test/.*%.scd$") or path:match("^test/[^/]*%.sh$")
      or path:match("^test/[^/]*%.sc%.in$") or path:match("^docs/.*%.md$")
      or path:match("^changes/[^/]*%.md$") or path:match("^%.github/workflows/[^/]*%.yml$")
    if scanned and not SPELLING_SKIP[path] then table.insert(files, path) end
  end
  return files
end

test("text uses US spelling", function()
  local planted = british_hits("fine\nThe Behaviour is grey; Greyhole stays", "x")
  assert_equal(table.concat(planted, " "), "x:2:behaviour x:2:grey", "the scan finds whole words only")
  local found, files = {}, spelling_files()
  assert_true(#files > 10, "the scan sees the repo's files")
  for _, path in ipairs(files) do
    local file = assert(io.open(repo_root .. "/" .. path, "r"))
    local text = file:read("*a"); file:close()
    for _, hit in ipairs(british_hits(text, path)) do table.insert(found, hit) end
  end
  assert_true(#found == 0, "use US spelling:\n" .. table.concat(found, "\n"))
end)

local function read_repo_file(path)
  local file = assert(io.open(repo_root .. "/" .. path, "r"))
  local text = file:read("*a"); file:close()
  return text
end

-- The orders in the first cell of a notes table: the rows under the line that
-- starts with `heading`, up to the next heading or "The sequence (" line, so
-- prose between rows does not hide the rows below it
local function table_orders(text, heading)
  local orders, inside = {}, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if not inside then
      inside = line:sub(1, #heading) == heading
    elseif line:sub(1, 1) == "|" then
      local order = line:match("^|%s*(%d+)%s*|")
      if order then orders[tonumber(order)] = true end
    elseif line:sub(1, 1) == "#" or line:sub(1, 14) == "The sequence (" then
      break
    end
  end
  return orders
end

test("the notes' start and cleanup tables list every step of START_ORDER and CLEANUP_ORDER", function()
  load_strata()
  local constants = local_value("S").constants
  local notes = read_repo_file("docs/notes/lua/state-and-voices.md")
  local problems = {}
  for _, kind in ipairs({{"START_ORDER", "start"}, {"CLEANUP_ORDER", "cleanup"}}) do
    local rows = table_orders(notes, "The sequence (`" .. kind[1] .. "`")
    assert_true(next(rows) ~= nil, "found the " .. kind[2] .. " table")
    local expected = {}
    for name, order in pairs(constants[kind[1]]) do
      expected[order] = true
      if not rows[order] then table.insert(problems, kind[2] .. " step " .. order .. " (" .. name .. ") has no row") end
    end
    for order in pairs(rows) do
      if not expected[order] then table.insert(problems, kind[2] .. " row " .. order .. " is in no " .. kind[1]) end
    end
  end
  table.sort(problems)
  assert_true(#problems == 0, table.concat(problems, "\n"))
end)

test("every constant AGENTS.md quotes with a value has that value", function()
  load_strata()
  local constants = local_value("S").constants
  local paragraph = read_repo_file("AGENTS.md"):match("%*%*Named constants, never magic numbers%.%*%*[^\n]*")
  assert_true(paragraph ~= nil, "found the Named constants paragraph")
  local problems, checked = {}, 0
  for name, paren in paragraph:gmatch("`([%u_][%u%d_]*)` (%b())") do
    local value = paren:match("^%((%-?%d[%d%.]*)[,)]")
    if value then
      checked = checked + 1
      if constants[name] ~= tonumber(value) then
        table.insert(problems, name .. ": AGENTS.md says " .. value .. ", constants has " .. tostring(constants[name]))
      end
    elseif paren:match("^%(%-?%d") then
      -- a value the pattern cannot read (`NAME` (16 per voice)) is no quote it may skip
      table.insert(problems, name .. " " .. paren .. ": a quoted value the test cannot read (write `NAME` (value) or (value, ...))")
    end
  end
  assert_true(checked >= 10, "the paragraph quotes at least ten values, saw " .. checked)
  assert_true(#problems == 0, table.concat(problems, "\n"))
end)

-- The rest of AGENTS.md's Named constants live in state-and-voices.md's
-- constants bullet: `NAME` (number), `TABLE.field` (number), `NAME`
-- (`field` number, ...) and names quoted without a value (#783)
test("every constant state-and-voices.md quotes beside AGENTS.md's has that value (#783)", function()
  load_strata()
  local constants = local_value("S").constants
  local notes = read_repo_file("docs/notes/lua/state-and-voices.md")
  local bullet = notes:match("\n  %- Beside the %a+ `AGENTS%.md` quotes %(Named constants%):([^\n]*)")
  assert_true(bullet ~= nil, "found the bullet beside AGENTS.md's Named constants")
  local problems, plain, fields = {}, 0, 0
  local function compare(label, actual, quoted)
    if actual ~= tonumber(quoted) then
      table.insert(problems, label .. ": the notes say " .. quoted .. ", constants has " .. tostring(actual))
    end
  end
  for name, suffix, after in bullet:gmatch("`([%u_][%u%d_]*)([%.%w_]*)`()") do
    local value = constants[name]
    local label = name .. suffix
    local field = suffix:match("^%.([%a_][%w_]*)$")
    if suffix ~= "" and not field then
      table.insert(problems, label .. ": not a NAME or NAME.field quote")
    elseif field and type(value) == "table" then value = value[field] end
    if value == nil or (field and type(constants[name]) ~= "table") then
      table.insert(problems, label .. ": quoted in the notes, but constants has no such value")
    else
      local paren = bullet:match("^ (%b())", after)
      local number = paren and paren:match("^%((%-?%d[%d%.]*)[,)]")
      if number then
        if field then fields = fields + 1 else plain = plain + 1 end
        compare(label, value, number)
      elseif paren and paren:match("^%(%-?%d") then
        -- a value the pattern cannot read (`NAME` (16 per voice)) is no quote it may skip
        table.insert(problems, label .. " " .. paren .. ": a quoted value the test cannot read (write `NAME` (value) or (value, ...))")
      elseif paren then
        for key, quoted in paren:gmatch("`([%l_][%w_]*)` (%-?%d[%d%.]*)") do
          fields = fields + 1
          compare(label .. "." .. key, type(value) == "table" and value[key] or nil, quoted)
        end
      end
    end
  end
  -- a stale name is listed above; these catch a bullet the patterns no longer read
  if plain < 13 then table.insert(problems, "the bullet quotes at least thirteen plain values, saw " .. plain) end
  if fields < 4 then table.insert(problems, "the bullet quotes at least four field values, saw " .. fields) end
  assert_true(#problems == 0, table.concat(problems, "\n"))
end)

test("state-and-voices.md names every registry", function()
  load_strata()
  local notes = read_repo_file("docs/notes/lua/state-and-voices.md")
  -- the "Owns" bullet for lib/state.lua is where the registries are listed
  local owned = notes:match("\n  %- `S%.registry`[^\n]*")
  assert_true(owned ~= nil, "found the S.registry bullet under Owns")
  notes = owned
  local missing, count = {}, 0
  for name in pairs(local_value("S").registry) do
    count = count + 1
    if not notes:find("`" .. name .. "`", 1, true) then table.insert(missing, name) end
  end
  table.sort(missing)
  assert_true(count >= 14, "the registry has its keys, saw " .. count)
  assert_true(#missing == 0, "not named in backticks: " .. table.concat(missing, ", "))
end)


-- The registered invariants that have no Machines entry yet (design
-- section 1, docs/notes/lua/state-and-voices.md, Registering an
-- invariant), one line a module. A package that enters a machine removes
-- its names here; a name is never added: an invariant registered from now
-- on gets its entry in the commit that registers it. The list only shrinks
local UNTABLED_INVARIANTS = {
}

-- The Machines entries of notes files ({{path, text}}) checked against the
-- registered invariants (a list of names) and the untabled list: the
-- problems, sorted. An entry is a `### <machine>` heading inside the
-- file's `## Machines` section, which is the section right after "Must not
-- break"; it has a `- **State:**`, a `- **Invariant:**` and a `- **Test:**`
-- line (a `- **Two facts:**` line is optional), and its first table, if it
-- has one, has the columns State, Event, Next and Effect (h.notes_table
-- reads the first three). The Invariant line names its invariants in
-- backticks at its start (`a`, or `a`, `b`, or `a` and `b`, then any text),
-- or says "none" and why. Every registered invariant is named by one entry
-- (never two) or listed as untabled, never both; a listed or entered name
-- is a registered one
local MACHINE_TABLE_HEADER = "| State | Event | Next | Effect |"
local function machines_problems(files, registered, untabled)
  local problems, entered, known, listed = {}, {}, {}, {}
  for _, name in ipairs(registered) do known[name] = true end
  local function problem(text) table.insert(problems, text) end
  for _, file in ipairs(files) do
    local sections, section, entry, in_fence = 0, nil, nil, false
    local function close_entry()
      if not entry then return end
      for _, label in ipairs({"State", "Invariant", "Test"}) do
        if not entry.lines[label] then problem(file.path .. ": " .. entry.name .. " has no `- **" .. label .. ":**` line") end
      end
      entry = nil
    end
    local function invariant_line(rest)
      if rest:match("^none") then return end
      local names, cursor = {}, rest
      while true do
        local name, after = cursor:match("^`([^`]+)`(.*)$")
        if not name then break end
        table.insert(names, name)
        cursor = after:match("^, (`.*)$") or after:match("^ and (`.*)$") or ""
      end
      if #names == 0 then problem(file.path .. ": " .. entry.name .. "'s Invariant line names no invariant and is not none: " .. rest) end
      for _, name in ipairs(names) do
        if entered[name] then
          problem(file.path .. ": " .. entry.name .. ": `" .. name .. "` is entered twice (also in " .. entered[name] .. ")")
        end
        entered[name] = entered[name] or file.path
        if not known[name] then problem(file.path .. ": " .. entry.name .. " enters `" .. name .. "`, which no module registers") end
      end
    end
    for line in (file.text .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%s*```") then in_fence = not in_fence end
      local level = not in_fence and line:match("^(#+) ")
      if level and #level <= 2 then
        close_entry()
        sections = sections + 1
        section = line
        if line == "## Machines" and sections ~= 2 then
          problem(file.path .. ": its ## Machines section is not the one right after Must not break")
        end
      elseif level and #level == 3 and section == "## Machines" then
        close_entry()
        entry = {name = line:sub(5), lines = {}, tabled = false}
      elseif not in_fence then
        local label, rest = line:match("^%- %*%*([%a ]+):%*%* ?(.*)$")
        if label == "Invariant" and not entry then
          problem(file.path .. ": an Invariant line outside a Machines entry: " .. line)
        elseif entry and label then
          entry.lines[label] = true
          if label == "Invariant" then invariant_line(rest) end
        elseif entry and not entry.tabled and line:match("^|") then
          entry.tabled = true
          if line ~= MACHINE_TABLE_HEADER then
            problem(file.path .. ": " .. entry.name .. "'s table opens " .. line .. ", not " .. MACHINE_TABLE_HEADER)
          end
        end
      end
    end
    close_entry()
  end
  for _, name in ipairs(untabled) do
    listed[name] = true
    if not known[name] then problem("UNTABLED_INVARIANTS lists `" .. name .. "`, which no module registers") end
    if entered[name] then problem("`" .. name .. "` has its entry in " .. entered[name] .. ": remove it from UNTABLED_INVARIANTS") end
  end
  for _, name in ipairs(registered) do
    if not entered[name] and not listed[name] then
      problem("`" .. name .. "` has no Machines entry (an `- **Invariant:**` line under docs/notes/lua/)")
    end
  end
  table.sort(problems)
  return problems
end

test("every registered invariant has a Machines entry, and no name listed as untabled has one", function()
  load_strata()
  local registered = {}
  -- the registry, not the source: lib/arp.lua passes its name as ARP.name
  for _, record in ipairs(local_value("S").registry.invariants) do table.insert(registered, record.name) end
  assert_true(#registered >= 34, "the script registers its invariants, saw " .. #registered)
  local files = {}
  for _, path in ipairs(markdown_files("docs/notes/lua")) do
    table.insert(files, {path = path, text = read_repo_file(path)})
  end
  local problems = machines_problems(files, registered, UNTABLED_INVARIANTS)
  assert_true(#problems == 0, table.concat(problems, "\n"))
  -- the convention is written where a worker entering a machine reads it
  local notes = read_repo_file("docs/notes/lua/state-and-voices.md")
  local paragraph = notes:match("\n%- %*%*Registering an invariant%*%*.-\n%- %*%*Registering a cleanup step%*%*") or ""
  for _, part in ipairs({"## Machines", "### <name>", "- **State:**", "- **Invariant:** `<name>`",
    "- **Two facts:**", "- **Test:**", MACHINE_TABLE_HEADER, "UNTABLED_INVARIANTS"}) do
    assert_true(paragraph:find(part, 1, true), "Registering an invariant gives the entry's " .. part)
  end
end)

test("the Machines check fails an invariant with no entry, a listed name with one and a malformed entry", function()
  local function entry(name, invariant, table_header)
    return table.concat({"### " .. name, "- **State:** `S.x`.", "- **Invariant:** " .. invariant,
      "- **Test:** `test/unit/x_test.lua`: \"x\".", "", table_header or MACHINE_TABLE_HEADER, "|---|---|---|---|"}, "\n")
  end
  local function notes(...)
    return {path = "docs/notes/lua/x.md", text = table.concat({"## Must not break", "- a rule", "## Machines", ...}, "\n\n")}
  end
  local function check(files, registered, untabled)
    return table.concat(machines_problems(files, registered, untabled), "\n")
  end
  -- 0b's case: an entry, and the name not listed
  assert_equal(check({notes(entry("clocks", "`clocks`"))}, {"clocks"}, {}), "", "an entered invariant passes")
  assert_equal(check({notes(entry("a and b", "`a` and `b` (3.9)"), entry("c", "none: a two-state flag"))}, {"a", "b"}, {}), "",
    "two names on one line, and none")
  assert_equal(check({notes()}, {"clocks"}, {"clocks"}), "", "a listed invariant passes")
  assert_true(check({notes()}, {"clocks"}, {}):find("`clocks` has no Machines entry", 1, true), "neither an entry nor listed")
  assert_true(check({notes(entry("clocks", "`clocks`"))}, {"clocks"}, {"clocks"}):find("remove it from UNTABLED_INVARIANTS", 1, true),
    "listed and entered")
  assert_true(check({notes()}, {}, {"gone"}):find("lists `gone`", 1, true), "a listed name no module registers")
  assert_true(check({notes(entry("x", "`typo`"))}, {}, {}):find("enters `typo`", 1, true), "an entered name no module registers")
  assert_true(check({notes(entry("x", "the clock"))}, {}, {}):find("names no invariant", 1, true), "an Invariant line without a name")
  assert_true(check({notes(entry("x", "`x`", "| From | Event | To |"))}, {"x"}, {}):find("x's table opens", 1, true), "the table's columns")
  local stray = {path = "docs/notes/lua/y.md", text = "## Must not break\n\n## Owns\n\n- **Invariant:** `x`\n"}
  assert_true(check({stray}, {"x"}, {}):find("outside a Machines entry", 1, true), "an Invariant line outside the section")
  local late = {path = "docs/notes/lua/z.md", text = "## Must not break\n\n## Owns\n\n## Machines\n\n" .. entry("x", "`x`")}
  assert_true(check({late}, {"x"}, {}):find("not the one right after Must not break", 1, true), "Machines after another section")
  local short = {path = "docs/notes/lua/w.md", text = "## Must not break\n\n## Machines\n\n### x\n- **Invariant:** `x`\n"}
  local found = check({short}, {"x"}, {})
  assert_true(found:find("no `- **State:**` line", 1, true) and found:find("no `- **Test:**` line", 1, true), "an entry's lines")
  -- each invariant is entered once: a second entry, in the same file or another, fails
  assert_true(check({notes(entry("x", "`x`"), entry("y", "`x`"))}, {"x"}, {}):find("`x` is entered twice", 1, true),
    "a name entered twice in one file")
  local other = {path = "docs/notes/lua/v.md", text = "## Must not break\n\n## Machines\n\n" .. entry("z", "`a` and `x`")}
  assert_true(check({notes(entry("x", "`x`")), other}, {"a", "x"}, {}):find("`x` is entered twice", 1, true),
    "a name entered twice in two files")
end)

-- The longest a notes file under docs/notes/lua may be, in words as `wc -w`
-- counts them (#898: scenes.md, at 11,139, was longer than one read of a
-- file; the longest after it had 8,499)
local NOTES_WORD_LIMIT = 9000

test("no file under docs/notes/lua is longer than 9,000 words", function()
  local long, count = {}, 0
  for _, path in ipairs(markdown_files("docs/notes/lua")) do
    count = count + 1
    local words = select(2, read_repo_file(path):gsub("%S+", ""))
    if words > NOTES_WORD_LIMIT then table.insert(long, path .. " has " .. words .. " words") end
  end
  assert_true(count >= 100, "the check reads the notes, saw " .. count)
  assert_true(#long == 0, "over " .. NOTES_WORD_LIMIT .. " words: " .. table.concat(long, ", "))
end)

-- The text of a Markdown section: from the line `heading` to the next
-- heading of the same or a higher level (nil when the heading is missing)
local function doc_section(text, heading)
  local level = #heading:match("^(#+)")
  local lines, inside = {}, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local hashes = line:match("^(#+) ")
    if inside and hashes and #hashes <= level then break end
    if line == heading then inside = true end
    if inside then table.insert(lines, line) end
  end
  return inside and table.concat(lines, "\n") or nil
end

-- The superpowers skills the process runs on (docs/workflow.md, Skills):
-- `process` are required steps, `unused` is named only as not used, and
-- `worker` are the ones a worker's dispatch carries (Dispatch)
local SKILLS = {
  process = { "brainstorming", "writing-plans", "using-git-worktrees", "subagent-driven-development",
    "dispatching-parallel-agents", "test-driven-development", "systematic-debugging",
    "requesting-code-review", "receiving-code-review", "verification-before-completion",
    "finishing-a-development-branch" },
  unused = { "executing-plans" },
  worker = { "test-driven-development", "systematic-debugging", "receiving-code-review",
    "verification-before-completion" },
}

-- Every `superpowers:<name>` in `text`, as a set of the bare names (a name
-- ends at the first character that is not a letter or a hyphen)
local function skills_named(text)
  local found = {}
  for name in text:gmatch("superpowers:([%a-]+)") do found[name] = true end
  return found
end

-- The differences between a set of found names and the expected lists: each
-- expected name the set lacks, and each found name in no expected list
local function skill_set_problems(found_set, expected_lists, where)
  local problems, expected = {}, {}
  for _, list in ipairs(expected_lists) do
    for _, name in ipairs(list) do expected[name] = true end
  end
  local names = {}
  for name in pairs(expected) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do
    if not found_set[name] then table.insert(problems, where .. " does not name superpowers:" .. name) end
  end
  names = {}
  for name in pairs(found_set) do
    if not expected[name] then table.insert(names, name) end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(problems, where .. " names superpowers:" .. name .. ", which is not expected there")
  end
  return problems
end

-- `text` without its code fences (``` or ~~~): a fence closes only on a line
-- of its own mark at least as long as its opening, so a ```` fence may quote
-- a ``` one
local function without_code_fences(text)
  local kept, fence_mark, fence_length = {}, nil, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local marks = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if fence_mark then
      if marks and marks:sub(1, 1) == fence_mark and #marks >= fence_length
          and line:match("^%s*" .. marks .. "%s*$") then
        fence_mark = nil
      end
    elseif marks then
      fence_mark, fence_length = marks:sub(1, 1), #marks
    else
      table.insert(kept, line)
    end
  end
  -- the second value is true when the text ends inside a fence
  return table.concat(kept, "\n"), fence_mark ~= nil
end

-- A plan's skill problems, outside its code fences: an unclosed fence, no
-- execution skill, or a `### Task` section with no `**Skills:**` line naming
-- a process skill
local function plan_skill_problems(text)
  local unclosed
  text, unclosed = without_code_fences(text)
  local problems = {}
  if unclosed then table.insert(problems, "the plan has an unclosed code fence") end
  if not skills_named(text)["subagent-driven-development"] then
    table.insert(problems, "the plan does not name superpowers:subagent-driven-development")
  end
  for heading in (text .. "\n"):gmatch("([^\n]*)\n") do
    if heading:sub(1, 9) == "### Task " then
      local named = false
      for line in ((doc_section(text, heading) or "") .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(1, 11) == "**Skills:**" then
          local skills = skills_named(line)
          for _, name in ipairs(SKILLS.process) do named = named or skills[name] == true end
        end
      end
      if not named then table.insert(problems, heading .. " has no **Skills:** line naming a process skill") end
    end
  end
  return problems
end

test("AGENTS.md's process section and the workflow's Skills name the same superpowers skills", function()
  local agents = doc_section(read_repo_file("AGENTS.md"), "## How work is done: the superpowers skills")
  assert_true(agents ~= nil, "AGENTS.md has the section \"How work is done: the superpowers skills\"")
  local workflow = doc_section(read_repo_file("docs/workflow.md"), "## Skills")
  assert_true(workflow ~= nil, "docs/workflow.md has the section \"Skills\"")
  local problems = skill_set_problems(skills_named(agents or ""), { SKILLS.process }, "AGENTS.md's process section")
  for _, problem in ipairs(skill_set_problems(skills_named(workflow or ""), { SKILLS.process, SKILLS.unused },
      "docs/workflow.md's Skills")) do
    table.insert(problems, problem)
  end
  assert_equal(table.concat(problems, "; "), "", "the two skill lists")
  -- the section comes before Architecture: every agent meets it first
  local doc = read_repo_file("AGENTS.md")
  assert_true((doc:find("\n## How work is done: the superpowers skills\n", 1, true) or math.huge)
    < doc:find("\n## Architecture\n", 1, true), "the process section is above Architecture")
end)

test("the workflow's dispatch text gives a worker every worker skill, and reports and reviews carry the Skills line", function()
  -- the check reports each expected skill a text does not name
  local missing = skill_set_problems({}, { SKILLS.worker }, "sample")
  assert_equal(#missing, 4, "an empty set misses the four worker skills")
  for _, problem in ipairs(missing) do
    assert_true(problem:find("does not name", 1, true) ~= nil, "a missing skill is reported as not named: " .. problem)
  end
  local workflow = read_repo_file("docs/workflow.md")
  local dispatch = doc_section(workflow, "## Dispatch")
  assert_true(dispatch ~= nil, "docs/workflow.md has the section \"Dispatch\"")
  local block = (dispatch or ""):match("```\n(.-)\n```")
  assert_true(block ~= nil, "the Dispatch section holds the worker's lines in a code fence")
  assert_equal(table.concat(skill_set_problems(skills_named(block or ""), { SKILLS.worker }, "the dispatch text"), "; "),
    "", "the dispatch text's skills")
  for _, heading in ipairs({ "## Dispatch", "## Reports", "## Review" }) do
    assert_true((doc_section(workflow, heading) or ""):find('"Skills" line', 1, true) ~= nil,
      "docs/workflow.md's " .. heading:sub(4) .. " names the report's \"Skills\" line")
  end
  assert_true((doc_section(workflow, "## Briefs") or ""):find("the skills its worker invokes", 1, true) ~= nil,
    "a brief names the skills its worker invokes")
end)

test("every superpowers skill a maintained doc or a plan names is one the process knows", function()
  local known = { SKILLS.process, SKILLS.unused }
  local function unknown(text, where)
    local problems = {}
    for _, problem in ipairs(skill_set_problems(skills_named(text), known, where)) do
      if problem:find("which is not expected there", 1, true) then table.insert(problems, problem) end
    end
    return problems
  end
  -- the check sees a misspelled name, and reads a name before punctuation
  assert_equal(#unknown("invoke superpowers:test-driven-developement first", "sample"), 1, "a misspelled skill is reported")
  assert_equal(#unknown("`superpowers:subagent-driven-development`'s templates; superpowers:brainstorming.", "sample"), 0,
    "a name before a backtick, a possessive or a period is read bare")
  -- a plan is read outside its code fences (it may quote a test's samples);
  -- a maintained doc is read whole (the workflow's dispatch text is fenced)
  local function plan_unknown(text, where) return unknown(without_code_fences(text), where) end
  local quoted = "# Plan\n\n````lua\n```\ninvoke superpowers:test-driven-developement first\n```\n````\n"
  assert_equal(#plan_unknown(quoted, "sample"), 0, "a plan's fenced unknown name is not reported")
  assert_equal(#plan_unknown((quoted:gsub("````lua\n```\n", "")), "sample"), 1,
    "a plan's unknown name outside a fence is reported")
  local problems = {}
  for _, doc_name in ipairs(maintained_docs()) do
    for _, problem in ipairs(unknown(read_repo_file(doc_name), doc_name)) do table.insert(problems, problem) end
  end
  for _, plan in ipairs(markdown_files("docs/superpowers/plans")) do
    for _, problem in ipairs(plan_unknown(read_repo_file(plan), plan)) do table.insert(problems, problem) end
  end
  assert_equal(table.concat(problems, "; "), "", "unknown skill names")
end)

test("every plan under docs/superpowers/plans names the execution skill and a skill for each task", function()
  local good = "# Plan\n\n> REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development\n\n"
    .. "### Task 1: one\n\n**Skills:** `superpowers:test-driven-development`\n\n- [ ] step\n\n"
    .. "### Task 2: docs\n\n**Skills:** `superpowers:verification-before-completion` (docs only)\n"
  assert_equal(#plan_skill_problems(good), 0, "a plan naming its skills has no problem")
  assert_equal(#plan_skill_problems((good:gsub("superpowers:subagent%-driven%-development", "the usual skill"))), 1,
    "a plan without the execution skill is reported")
  local bare = good:gsub("%*%*Skills:%*%* `superpowers:test%-driven%-development`", "**Files:** none")
  local problems = plan_skill_problems(bare)
  assert_equal(#problems, 1, "a task without a Skills line is reported")
  assert_true((problems[1] or ""):find("### Task 1: one", 1, true) ~= nil, "the problem names the task's heading")
  assert_equal(#plan_skill_problems((good:gsub("`superpowers:verification%-before%-completion`", "none"))), 1,
    "a Skills line naming no process skill is reported")
  assert_equal(#plan_skill_problems(good .. "\n```markdown\n### Task 9: an example\n\n- [ ] step\n```\n"), 0,
    "a task heading inside a code fence is not a task")
  assert_equal(#plan_skill_problems(good .. "\n~~~\n### Task 9: an example\n\n- [ ] step\n~~~\n"), 0,
    "a task heading inside a tilde fence is not a task")
  local unclosed = plan_skill_problems(good .. "\n```markdown\n### Task 9: an example\n")
  assert_equal(#unclosed, 1, "a plan with an unclosed fence has one problem")
  assert_true((unclosed[1] or ""):find("unclosed code fence", 1, true) ~= nil, "the problem names the unclosed code fence")
  for _, plan in ipairs(markdown_files("docs/superpowers/plans")) do
    assert_equal(table.concat(plan_skill_problems(read_repo_file(plan)), "; "), "", plan)
  end
end)

-- A menu name without its trailing number: "LFO 1" and "LFO 1-3" are
-- "LFO", "custom 5" is "custom"
local function menu_family(name)
  return (name:gsub(" %d+%-%d+$", ""):gsub(" %d+$", ""))
end

-- maiden installs a script with `;install <url>` in its REPL (whose matron
-- tab takes Lua, never shell commands); its project manager has no catalog
-- tab or URL field, and lists only the catalogs (decisions, #302)
test("README's install routes are maiden's ;install and git clone into ~/dust/code, then SYSTEM > RESTART (#302)", function()
  local install = doc_section(read_repo_file("README.md"), "## Installation")
  assert_true(install ~= nil, "README.md has an Installation section")
  local url = install:match("`;install (https://github%.com/[%w%-_]+/[%w%-_]+)`")
  assert_true(url ~= nil, "the section names `;install <the repository's URL>`")
  assert_true(install:find("git clone " .. url .. ".git", 1, true), "and a git clone of the same repository")
  assert_true(install:find("~/dust/code", 1, true), "into ~/dust/code")
  assert_true(install:find("SYSTEM > RESTART", 1, true), "then SYSTEM > RESTART, which recompiles the engine")
  local lowered = install:lower()
  for _, gone in ipairs({'"catalog"', "circular icon", "command line (bottom panel)", "`;restart`"}) do
    assert_true(not lowered:find(gone, 1, true), "the section no longer names " .. gone)
  end
end)

-- norns shows the script's header when the script is selected. The
-- fragments in changes/ become CHANGELOG.md's next entry at the release, so
-- until then the header and README already carry the release in progress;
-- once CHANGELOG.md's newest entry reaches it, the newest entry is the one
-- they name (#391, #350)
local RELEASE_IN_PROGRESS = "3.3.0"
test("strata.lua's header and README name the release, AGENTS.md CHANGELOG.md's newest (#391, #350)", function()
  local function parts(version)
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)$")
    return {tonumber(major), tonumber(minor), tonumber(patch)}
  end
  local function newer(a, b)
    local x, y = parts(a), parts(b)
    for i = 1, 3 do
      if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
  end
  local released = read_repo_file("CHANGELOG.md"):match("\n## Version (%d+%.%d+%.%d+)")
  assert_true(released ~= nil, "CHANGELOG.md has a '## Version x.y.z' entry")
  local expected = newer(RELEASE_IN_PROGRESS, released) and RELEASE_IN_PROGRESS or released
  local header = read_repo_file("strata.lua"):match("^%-%- strata%.lua\n%-%- [^\n]*\n%-%- v(%d+%.%d+%.%d+)\n")
  assert_equal(header, expected, "strata.lua's third header line, the version norns shows")
  assert_equal(read_repo_file("README.md"):match("This is version (%d+%.%d+%.%d+)%."), expected, "README's version")
  assert_equal(read_repo_file("AGENTS.md"):match("The current release is (%d+%.%d+%.%d+)"), released,
    "AGENTS.md's current release is CHANGELOG.md's newest entry")
end)

-- The reference names every group Strata adds, in the menu's order, and
-- every param of a voice's granular, cross-modulation and extras parts by
-- its menu name (a numbered name once: "custom 1-5"). The voice's own
-- synthesis params are voices-and-grains.md's (#343)
test("params.md names every Strata group in menu order and every param of a voice's last three parts (#343)", function()
  local context = load_strata()
  h.finish_startup(context)
  local text = read_repo_file("docs/user/params.md")
  local order_line = text:match("\n([^\n]*[Tt]he menu shows[^\n]*)")
  assert_true(order_line ~= nil, "params.md has the menu-order sentence")
  local bold = {}
  for name in order_line:gmatch("%*%*(.-)%*%*") do table.insert(bold, menu_family(name)) end
  local groups, seen, first = {}, {}, nil
  for index, param in ipairs(params.params) do
    if param.id == "strata" then first = index end
    if first and param.t == params.tGROUP and not seen[menu_family(param.name)] then
      seen[menu_family(param.name)] = true
      table.insert(groups, menu_family(param.name))
    end
  end
  assert_true(#groups >= 6, "Strata adds its groups, saw " .. #groups)
  local at = 0
  for _, group in ipairs(groups) do
    local found
    for index = at + 1, #bold do
      if bold[index] == group then found = index; break end
    end
    assert_true(found ~= nil, "the menu-order sentence names **" .. group .. "** after the groups before it")
    at = found
  end

  local section = doc_section(text, "## Per-Voice Sections")
  assert_true(section ~= nil, "params.md has its Per-Voice Sections")
  -- the table: | name | range | default | notes |, by menu family
  local rows = {}
  for line in (section .. "\n"):gmatch("([^\n]*)\n") do
    local name, range, default = line:match("^| ([^|]-) | ([^|]-) | ([^|]-) |")
    if name and name ~= "parameter" and not name:find("^%-+$") then
      rows[menu_family(name)] = {range = range, default = default, used = false}
    end
  end
  -- a range "a-b unit" or "a to b unit" (a unit stops at a space or "(")
  local function numeric_range(cell)
    local low, high, unit = cell:match("^(%-?[%d%.]+) to (%-?[%d%.]+) ?([^%s(]*)")
    if not low then low, high, unit = cell:match("^(%-?[%d%.]+)%-([%d%.]+) ?([^%s(]*)") end
    return tonumber(low), tonumber(high), unit
  end
  local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 1e-9 end
  local S = local_value("S")
  local problems, checked = {}, 0
  for voice_idx, voice in ipairs(S.voices) do
    local synth_ids, members, order, inside = {}, {}, {}, false
    -- (3.8: every voice type's synth keys, which voices-and-grains.md describes)
    for _, key in ipairs(S.lib.types.keys()) do synth_ids["v" .. voice_idx .. "_" .. key] = true end
    -- the voice's params from its heading to the next voice's, but its
    -- synthesis params, grouped by family in menu order
    for _, param in ipairs(params.params) do
      if param.t == params.tSEPARATOR and param.name:find("^voice %d+: ") then
        if inside then break end
        inside = param.name:find("^voice " .. voice_idx .. ": ") ~= nil
      elseif inside and param.t ~= params.tSEPARATOR and not synth_ids[param.id] then
        local family = menu_family(param.name)
        if not members[family] then members[family] = {}; table.insert(order, family) end
        table.insert(members[family], param)
      end
    end
    for _, family in ipairs(order) do
      local row = rows[family]
      local where = "voice " .. voice_idx .. " " .. family
      if not row then
        table.insert(problems, where .. ": no row")
      else
        row.used = true
        local listed = row.default:gsub("^by voice: ", "")
        local defaults = {}
        for value in (listed .. ","):gmatch("%s*([^,]-)%s*,") do table.insert(defaults, value) end
        if row.default:find("^by voice: ") then defaults = {defaults[voice_idx]} end
        for k, param in ipairs(members[family]) do
          checked = checked + 1
          local stated = (#defaults == #members[family] and defaults[k]) or (#defaults == 1 and defaults[1]) or nil
          local name = where .. (#members[family] > 1 and (" " .. k) or "")
          if param.t == params.tCONTROL then
            local spec, scale = param.controlspec, 1
            local low, high, unit = numeric_range(row.range)
            -- a 0-1 control its formatter shows in percent (the sends, #338)
            -- is given in percent, as the screen shows it
            if param.formatter and params:string(param.id):find("%%%s*$") and unit ~= "%" then
              table.insert(problems, name .. ": shown as " .. params:string(param.id) .. ", given as '" .. row.range .. "'")
            end
            if unit == "%" and (spec.units or "") ~= "%" and param.formatter then scale, unit = 100, spec.units or "" end
            if not (near(low, spec.minval * scale) and near(high, spec.maxval * scale)) then
              table.insert(problems, name .. ": range '" .. row.range .. "', the param's " .. spec.minval .. "-" .. spec.maxval)
            elseif unit ~= (spec.units or "") then
              table.insert(problems, name .. ": unit '" .. tostring(unit) .. "', the param's '" .. tostring(spec.units) .. "'")
            end
            if not near(tonumber(stated), spec.default * scale) then
              table.insert(problems, name .. ": default '" .. tostring(stated) .. "', the param's " .. spec.default)
            end
          elseif param.t == params.tNUMBER then
            local low, high = numeric_range(row.range)
            if low then
              if not (near(low, param.min) and near(high, param.max)) then
                table.insert(problems, name .. ": range '" .. row.range .. "', the param's " .. param.min .. "-" .. param.max)
              end
            else
              -- a range given in the param's own words (none ... voice 7)
              for _, value in ipairs({param.min, param.max}) do
                params:set(param.id, value)
                if not row.range:find(params:string(param.id), 1, true) then
                  table.insert(problems, name .. ": range '" .. row.range .. "' lacks " .. params:string(param.id))
                end
              end
              params:set(param.id, param.default)
            end
            if not (near(tonumber(stated), param.default) or stated == params:string(param.id)) then
              table.insert(problems, name .. ": default '" .. tostring(stated) .. "', the param's " .. param.default)
            end
          elseif param.t == params.tOPTION then
            for _, option in ipairs(param.options) do
              if not row.range:find(menu_family(option), 1, true) then
                table.insert(problems, name .. ": range '" .. row.range .. "' lacks " .. option)
              end
            end
            if stated ~= param.options[param.default] then
              table.insert(problems, name .. ": default '" .. tostring(stated) .. "', the param's " .. param.options[param.default])
            end
          elseif param.t == params.tBINARY then
            if row.range ~= "off/on" or stated ~= (param.default == 1 and "on" or "off") then
              table.insert(problems, name .. ": '" .. row.range .. "', '" .. tostring(stated) .. "' for a binary param")
            end
          end
        end
      end
    end
  end
  for family, row in pairs(rows) do
    if not row.used then table.insert(problems, family .. ": a row for no param") end
  end
  table.sort(problems)
  assert_true(#problems == 0, "params.md's Per-Voice Sections:\n" .. table.concat(problems, "\n"))
  assert_true(checked >= 7 * 40, "every voice's params were checked, " .. checked)
end)

-- Each voice type's synthesis params, as the VOICE page, MAIN and
-- PARAMETERS show them: a table per type (3.8: S.lib.types.list()) under
-- its bold name, a row per key of its param_order (amp and pan are
-- described once, above the tables), with the key's range, unit and the
-- type's own default, and its main key marked (main) (#395)
test("voices-and-grains.md has a row for every synthesis param, with its range, unit and default (#395)", function()
  local context = load_strata()
  h.finish_startup(context)
  local S = local_value("S")
  local section = doc_section(read_repo_file("docs/user/voices-and-grains.md"), "## Synthesis Parameters")
  assert_true(section ~= nil, "voices-and-grains.md has a Synthesis Parameters section")
  local problems, rows_checked = {}, 0
  for _, record in ipairs(S.lib.types.list()) do
    local rows, inside = {}, false
    for line in (section .. "\n"):gmatch("([^\n]*)\n") do
      local bold_name = line:match("^%*%*(.-)%*%*$")
      if bold_name then
        inside = bold_name:lower() == record.name
      elseif inside and line:sub(1, 1) == "|" then
        local key, rest, range, default = line:match("^| `([%w_]+)`([^|]*)| ([^|]+) | ([^|]+) |")
        if key then rows[key] = {main = rest:find("(main)", 1, true) ~= nil, range = range, default = default} end
      end
    end
    local expected_keys = {}
    for _, key in ipairs(record.param_order) do
      if key ~= "amp" and key ~= "pan" then
        expected_keys[key] = true
        local row = rows[key]
        local where = record.name .. " " .. key
        if not row then
          table.insert(problems, where .. ": no row")
        else
          rows_checked = rows_checked + 1
          local spec = record.specs[key]
          local low, high, unit = row.range:match("^(%-?[%d%.]+)%-(%-?[%d%.]+) ?(%S*)%s*$")
          if not (low and math.abs(tonumber(low) - spec.minval) < 1e-9 and math.abs(tonumber(high) - spec.maxval) < 1e-9) then
            table.insert(problems, where .. ": range '" .. row.range .. "' is not " .. spec.minval .. "-" .. spec.maxval)
          elseif unit ~= (spec.units or "") then
            table.insert(problems, where .. ": unit '" .. unit .. "' is not '" .. tostring(spec.units) .. "'")
          end
          local default = tonumber(row.default:match("^%s*(.-)%s*$"))
          if not default or math.abs(default - record.defaults[key]) > 1e-9 then
            table.insert(problems, where .. ": default '" .. row.default .. "' is not " .. record.defaults[key])
          end
          if row.main ~= (record.main.key == key) then
            table.insert(problems, where .. ": (main) belongs on MAIN's param, " .. record.main.key)
          end
        end
      end
    end
    for key in pairs(rows) do
      if not expected_keys[key] then table.insert(problems, record.name .. " " .. key .. ": a row for no param") end
    end
  end
  assert_true(rows_checked >= 20, "the tables were read, " .. rows_checked .. " rows")
  table.sort(problems)
  assert_true(#problems == 0, table.concat(problems, "\n"))
end)

-- How long a glide lasts in the code: voice 1 on a 16 s buffer, the ring
-- turned for 0.3 s at `speed` loop lengths a second, then let go; the
-- seconds from the last turn until the glide's rate is 0, in playhead steps
local function measured_glide(friction, speed)
  local context = load_strata()
  h.finish_startup(context)
  local S = local_value("S")
  S.buffers[1].seconds = 16
  params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
  params:set("scrub_friction", friction)
  local position = 0.2
  params:set("v1_buf_pos", position)
  for _ = 1, 30 do
    context.clock.run_for(0.01)
    position = position + speed * 0.01
    params:set("v1_buf_pos", position)
    S.lib.positions.scrub_turned(1)
  end
  local step, elapsed, started = 1 / S.constants.PLAYHEADS.update_hz, 0, false
  while elapsed < 120 do
    context.clock.run_for(step)
    elapsed = elapsed + step
    local rate = S.lib.positions.scrub_rate(1)
    if rate ~= 0 then started = true end
    if started and rate == 0 then return elapsed end
  end
  fail("the glide at " .. friction .. "% and " .. speed .. " never ended")
end

-- params.md's glide lengths are the code's, measured: a fling of a
-- twentieth, one and two loop lengths a second at 0%, the same range at 50%
-- and 75%, and at 90% to a tenth of a second; and the decay's time constant
-- (SCRUB.max_glide_seconds) is the "every 4 s" it states (#342)
test("params.md's scrub friction gives the glide lengths the code measures (#342)", function()
  local function whole(seconds) return math.floor(seconds + 0.5) end
  local function tenth(seconds) return string.format("%.1f", math.floor(seconds * 10 + 0.5) / 10) end
  local slow, one, two = measured_glide(0, 0.05), measured_glide(0, 1), measured_glide(0, 2)
  local expected = {
    string.format("stops after %d to %d s (%d s for a flick of a twentieth of the loop a second, "
      .. "%d s for one loop a second, %d s for two)", whole(slow), whole(two), whole(slow), whole(one), whole(two)),
    string.format("halves those times (%d to %d s)", whole(measured_glide(50, 0.05)), whole(measured_glide(50, 2))),
    string.format("quarters them (%d to %d s)", whole(measured_glide(75, 0.05)), whole(measured_glide(75, 2))),
    string.format("at 90%% a glide stops after %s to %s s", tenth(measured_glide(90, 0.05)), tenth(measured_glide(90, 2))),
  }
  load_strata()
  local SCRUB = local_value("S").constants.SCRUB
  table.insert(expected, "loses about two thirds of its speed every " .. SCRUB.max_glide_seconds .. " s")
  local friction = read_repo_file("docs/user/params.md"):match("\n%- Scrub friction[^\n]*")
  assert_true(friction ~= nil, "params.md describes the scrub friction")
  for _, text in ipairs(expected) do
    assert_true(friction:find(text, 1, true), "params.md's scrub friction says: " .. text)
  end
end)

-- The record keys and triggers record with the record settings (3.3's
-- record_buffer), never "the input for the record duration"; the
-- positions page's user page (3.8: docs/user/grid/pages/positions.md, which
-- took grid.md's Positions) describes a press, the LEDs and the marks,
-- gives the two-key loop's edges in either order, and says its record keys
-- record with the record settings (#337, #353, #356, #358, #362)
test("the record keys use the record settings; the positions page gives the loop's edges (#337, #353, #356, #358, #362)", function()
  load_strata()
  local trigger = read_repo_file("docs/user/params.md"):match("\n  %- Record:[^\n]*")
  assert_true(trigger ~= nil, "params.md describes a buffer's Record trigger")
  assert_true(trigger:find("record settings", 1, true) and not trigger:find("live input", 1, true),
    "the Record trigger records with the record settings")
  local path = "docs/user/grid/pages/positions.md"
  local positions = read_repo_file(path)
  assert_true(positions:find("from the start of the earlier", 1, true) and positions:find("in either order", 1, true),
    path .. " gives the loop's edges in either order")
  local slots = doc_section(positions, "## Side 2: the marks and the slots")
  assert_true(slots ~= nil, path .. " has its side 2")
  assert_true(slots:find("with the record settings", 1, true), path .. "'s record keys use the record settings")
  assert_true(read_repo_file("docs/user/grid.md"):find("](grid/pages/positions.md)", 1, true), "grid.md links the positions page")
  for _, file in ipairs(markdown_files("docs/user/grid")) do
    assert_true(not read_repo_file(file):lower():find("record the input", 1, true),
      file .. " never says the record keys record the input")
  end
end)

-- 3.8 (design §10.1): the layouts are the top-level files of
-- docs/user/grid/, one per registered layout; the pages are
-- docs/user/grid/pages/<name>.md, one per registered page record (each
-- linked from grid.md, as the index test checks)
test("docs/user/grid/ has a page for each registered layout, and docs/user/grid/pages/ one for each registered grid page", function()
  load_strata()
  local S = local_value("S")
  local function documented(dir, prefix)
    local found = {}
    for _, path in ipairs(markdown_files(dir)) do
      local name = path:match("^" .. prefix:gsub("%p", "%%%0") .. "([^/]+)%.md$")
      if name then found[name] = true end
    end
    return found
  end
  local layout_docs = documented("docs/user/grid", "docs/user/grid/")
  local layouts = 0
  for key in pairs(S.registry.grid_layouts) do
    layouts = layouts + 1
    assert_true(layout_docs[key], "docs/user/grid/" .. key .. ".md documents the registered layout " .. key)
    layout_docs[key] = nil
  end
  assert_true(layouts >= 4, "the layouts are registered, saw " .. layouts)
  assert_true(next(layout_docs) == nil, "every top-level page in docs/user/grid/ is a registered layout's: "
    .. tostring(next(layout_docs)))
  local page_docs = documented("docs/user/grid/pages", "docs/user/grid/pages/")
  local pages = 0
  for index, record in pairs(S.registry.grid_pages) do
    pages = pages + 1
    assert_equal(record.name, S.constants.GRID_PAGES.names[index], "page " .. index .. "'s record")
    assert_true(page_docs[record.name], "docs/user/grid/pages/" .. record.name .. ".md documents the page")
    page_docs[record.name] = nil
  end
  assert_true(pages >= 1, "the patterns page at least is registered, saw " .. pages)
  assert_true(next(page_docs) == nil, "every page in docs/user/grid/pages/ is a registered page's: "
    .. tostring(next(page_docs)))
end)

-- Three claims pages state from the code: effects.md's sends as the params
-- show them (in percent, #338); technical.md's signal flow and architecture
-- with each voice's stage and the master filter on its three buses (#347);
-- the BUFFER page's PARAMETERS home of each field's param, found by turning
-- the field with E3, and the loop save's fallback, as sources-and-buffers.md
-- gives it (#348)
test("effects.md's sends, technical.md's voice stage and BUFFER's field homes match the code (#338, #347, #348)", function()
  local context = load_strata()
  h.finish_startup(context)
  local S = local_value("S")

  local sends = read_repo_file("docs/user/effects.md"):match("\n%- %*%*delay send, reverb send%*%*[^\n]*")
  assert_true(sends ~= nil, "effects.md describes the voice sends")
  local default_text = params:string("v1_delay_send"):gsub(" ", "")
  params:set("v1_delay_send", 0)
  local low_text = params:string("v1_delay_send"):gsub(" ", ""):gsub("%%", "")
  params:set("v1_delay_send", 1)
  local high_text = params:string("v1_delay_send"):gsub(" ", "")
  local stated = low_text .. "-" .. high_text .. ", default " .. default_text
  assert_true(sends:find(stated, 1, true), "effects.md gives the sends as they show: " .. stated)

  local technical = read_repo_file("docs/user/technical.md")
  local flow = doc_section(technical, "## Audio Signal Flow")
  assert_true(flow ~= nil, "technical.md has its signal flow")
  local _, filters = flow:gsub("Filter", "")
  assert_true(flow:find("Voice Stage", 1, true) and flow:find("delay send", 1, true) and flow:find("reverb send", 1, true)
    and filters >= 3, "the flow runs each voice's stage, its two sends and three filters")
  local architecture = doc_section(technical, "## Architecture") or ""
  assert_true(architecture:find("mix stage per voice", 1, true) and architecture:find("Voice Stage", 1, true),
    "the architecture lists the voice's mix stage, named as the flow names it")

  -- each param's home: its group, or the separator its section starts with
  local home, group, remaining, section = {}, nil, 0, nil
  for _, param in ipairs(params.params) do
    if param.t == params.tGROUP then
      group, remaining = param.name, param.n
    elseif remaining > 0 then
      home[param.id], remaining = group, remaining - 1
    elseif param.t == params.tSEPARATOR then
      section = param.name
    elseif param.id then
      home[param.id] = section
    end
  end
  local sentence = read_repo_file("docs/user/pages/buffer.md"):match("\nThe fields are also in PARAMETERS:[^\n]*")
  assert_true(sentence ~= nil, "buffer.md says where the fields are in PARAMETERS")
  -- the doc's homes: each field named in backticks belongs to the next
  -- **group** the sentence names
  local doc_home, pending = {}, {}
  for token in sentence:gmatch("[`*]+[^`*]+[`*]+") do
    local field, bold = token:match("^`([^`]+)`$"), token:match("^%*%*([^*]+)%*%*$")
    if field then table.insert(pending, field) end
    if bold then
      for _, name in ipairs(pending) do doc_home[name] = bold end
      pending = {}
    end
  end
  local page = S.registry.pages[S.constants.UI_PAGES.index.BUFFER]
  local checked = {}
  local function turn_field(state, field)
    state.setup()
    for _, d in ipairs({1, -1}) do
      local before = {}
      for _, param in ipairs(params.params) do
        if param.id and param.t ~= params.tSEPARATOR and param.t ~= params.tGROUP then before[param.id] = params:get(param.id) end
      end
      page.enc(3, d)
      local changed = {}
      for id, value in pairs(before) do
        if params:get(id) ~= value then table.insert(changed, id) end
      end
      if #changed == 1 then
        local where = home[changed[1]] or "?"
        if where:find("^voice %d+ granular$") then
          assert_true(sentence:find("granular section", 1, true), "buffer.md puts the voice's " .. changed[1]
            .. " in its granular section")
        else
          assert_equal(doc_home[field], where, "buffer.md's group for `" .. field .. "` (" .. changed[1] .. ")")
        end
        table.insert(checked, field)
        return
      end
    end
  end
  for _, state in ipairs(page.layout_states) do
    local field = state.name:match("^field (%S+)$")
    if field then
      params:set("record_sync", 1)
      turn_field(state, field)
      if field == "dur" then
        params:set("record_sync", 2)  -- with sync on the field is len, the record beats
        turn_field({setup = state.setup}, "len")
      end
    end
  end
  assert_true(#checked >= 9, "the fields that edit one param were turned: " .. table.concat(checked, " "))
  for _, path in ipairs({"docs/user/pages/buffer.md", "docs/user/sources-and-buffers.md"}) do
    assert_true(read_repo_file(path):find("lowest-numbered", 1, true), path .. " gives the loop save's fallback voice")
  end
end)

-- 3.4's fast modulation (design §3.2): the engine's fastModBus holds
-- numVoices x fastModNoteSlots x numFastDestinations channels, which Lua
-- addresses with the same two numbers (setFastOffset's note slot, the
-- scatter mask's destination bits)
test("the engine's fast-modulation constants equal the script's", function()
  load_strata()
  assert_equal(engine_spec.num_fast_destinations, 5, "numFastDestinations (StrataModulation.sc)")
  assert_equal(engine_spec.fast_mod_note_slots, 1, "fastModNoteSlots (StrataModulation.sc)")
  assert_equal(engine_spec.num_fast_destinations, local_value("NUM_FAST_DESTINATIONS"),
    "numFastDestinations = NUM_FAST_DESTINATIONS")
  assert_equal(engine_spec.fast_mod_note_slots, local_value("FAST_MOD_NOTE_SLOTS"), "fastModNoteSlots = FAST_MOD_NOTE_SLOTS")
end)

-- 3.4's LFOs (design §2): Lua's NUM_LFOS LFOs are the engine's numFastLfos
-- engine LFOs, one node each (setFastLfo's lfo 0..NUM_LFOS - 1)
test("the engine's numFastLfos equals NUM_LFOS", function()
  load_strata()
  assert_equal(engine_spec.num_fast_lfos, 6, "numFastLfos (StrataModulation.sc)")
  assert_equal(engine_spec.num_fast_lfos, local_value("NUM_LFOS"), "numFastLfos = NUM_LFOS")
end)

-- 3.7's envelopes (design §7.3): one engine route per matrix slot
-- (setFastEnv's route 0..MATRIX_SLOTS - 1)
test("the engine's numEnvRoutes equals MATRIX_SLOTS", function()
  load_strata()
  assert_equal(engine_spec.num_env_routes, 16, "numEnvRoutes (StrataEnvelopes.sc)")
  assert_equal(engine_spec.num_env_routes, local_value("MATRIX_SLOTS"), "numEnvRoutes = MATRIX_SLOTS")
end)

-- 3.4's fast modulation (design §3.3): an offset m moves pitch, position
-- and size by m half ranges, the half of each Lua param's range, and the
-- cutoff by fastModCutoffFactor ^ m, ± half of filter_freq's ten octaves
-- at m = ±1: the factor squared is its max over its min
test("the engine's fast-modulation half ranges equal the Lua specs", function()
  load_strata()
  local source = stubs.strip_sc_comments(engine_sources())
  local list = source:match("fastModHalfRanges%s*{%s*%^%s*%[([^%]]*)%]%s*}")
  assert_true(list ~= nil, "fastModHalfRanges { ^[pitch, position, size] } (StrataModulation.sc)")
  local halves = {}
  for number in list:gmatch("%-?[%d%.]+") do halves[#halves + 1] = tonumber(number) end
  assert_equal(#halves, 3, "three half ranges: pitch, position, size")
  for index, id in ipairs({"v1_grain_pitch", "v1_buf_pos", "v1_grain_size"}) do
    local spec = params:lookup_param(id).controlspec
    assert_near(halves[index], (spec.maxval - spec.minval) / 2, 1e-9, id .. "'s half range")
  end
  local factor = tonumber(source:match("fastModCutoffFactor%s*{%s*%^%s*([%d%.]+)%s*}"))
  assert_true(factor ~= nil, "fastModCutoffFactor { ^N } (StrataModulation.sc)")
  local cutoff = params:lookup_param("v1_filter_freq").controlspec
  assert_near(factor * factor / (cutoff.maxval / cutoff.minval), 1, 0.001,
    "fastModCutoffFactor squared against v1_filter_freq's max over min")
end)

-- 3.5's notes (design §1): a voice's eight note slots and the pool of extra
-- notes all voices share, the same numbers on both sides (StrataNotes.sc's
-- noteSlots and notePoolMax, lib/constants.lua's NOTE_SLOTS and NOTE_POOL.max)
test("the engine's note constants equal the script's", function()
  load_strata()
  assert_equal(engine_spec.note_slots, 8, "noteSlots (StrataNotes.sc)")
  assert_equal(engine_spec.note_pool_max, 16, "notePoolMax (StrataNotes.sc)")
  assert_equal(engine_spec.note_slots, local_value("NOTE_SLOTS"), "noteSlots = NOTE_SLOTS")
  local pool = local_value("NOTE_POOL")
  assert_equal(engine_spec.note_pool_max, pool and pool.max, "notePoolMax = NOTE_POOL.max")
  -- ruling 53: the engine derives a ring-stream note's rate on a buffer or
  -- the input from its note as Lua's note_values does, from the same root
  local source = stubs.strip_sc_comments(engine_sources())
  local root = tonumber(source:match("noteRateRootNote%s*{%s*%^%s*(%d+)%s*}"))
  local S = local_value("S")
  assert_equal(root, S.lib.notes.NOTES.rate_root_note, "noteRateRootNote = NOTES.rate_root_note")
  assert_equal(root, S.lib.midi_in.MIDI.rate_root_note, "noteRateRootNote = MIDI.rate_root_note")
  local low, high = source:match("absoluteNoteRate%s*{.-%.clip%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*%)")
  assert_equal(tonumber(low), S.lib.notes.NOTES.rate_range[1], "absoluteNoteRate's low clip = NOTES.rate_range")
  assert_equal(tonumber(high), S.lib.notes.NOTES.rate_range[2], "absoluteNoteRate's high clip = NOTES.rate_range")
end)

-- 3.8 (package 0d, ruling 21): a type is only appended, and Lua's
-- registration order (S.register_voice_type, strata.lua's includes) is the
-- engine's voiceTypeDefs order, so a saved type index means one def
test("the engine's voiceTypeDefs equal Lua's types in order", function()
  load_strata()
  local S = local_value("S")
  local source = stubs.strip_sc_comments(engine_sources())
  local block = source:match("voiceTypeDefs%s*{%s*%^%s*#%[(.-)%]%s*}")
  assert_true(block ~= nil, "voiceTypeDefs { ^#[...] } (StrataVoices.sc)")
  local defs = {}
  for name in block:gmatch("\\([%a_][%w_]*)") do defs[#defs + 1] = name end
  local list = S.lib.types.list()
  assert_equal(#list, #defs, "one Lua type per engine def")
  for index, record in ipairs(list) do
    assert_equal(record.def, defs[index], "type " .. index .. " (" .. record.key .. ")'s def")
    assert_equal(record.index, index, record.key .. "'s index is its place")
  end
  assert_equal(table.concat(defs, " "), table.concat(engine_spec.voice_type_defs, " "), "the stub reads the same list")
end)

-- 3.5's per-note main expression (design §3.2): noteMain offsets one control
-- of each voice SynthDef by its half range, clipped to the range, from
-- noteMainRanges' literals (StrataVoiceDefs.sc), which are Lua's param specs.
-- 3.8 (package 0d): each type's control is its record's note_main, its
-- range the record's spec of it
test("the engine's expression controls and ranges equal the Lua specs", function()
  load_strata()
  local S = local_value("S")
  local source = stubs.strip_sc_comments(engine_sources())
  local block = source:match("noteMainRanges%s*{%s*%^%s*(%b())%s*}")
  assert_true(block ~= nil, "noteMainRanges { ^(def: [\\control, lo, hi], ...) } (StrataVoiceDefs.sc)")
  local ranges = {}
  for def, control, low, high in block:gmatch("([%a_][%w_]*)%s*:%s*%[%s*\\([%a_][%w_]*)%s*,%s*(%-?[%d%.]+)%s*,%s*(%-?[%d%.]+)%s*%]") do
    ranges[def] = { control = control, low = tonumber(low), high = tonumber(high) }
  end
  for _, record in ipairs(S.lib.types.list()) do
    local def = record.def
    local range = ranges[def]
    assert_true(range ~= nil, "noteMainRanges has an entry for \\" .. def)
    assert_equal(range.control, record.note_main, "\\" .. def .. "'s expression control is " .. record.key .. "'s note_main")
    assert_true(engine_spec.synthdef_controls[def][range.control], "\\" .. range.control .. " is a control of \\" .. def)
    assert_true(engine_spec.synthdef_controls[def].noteMain, "\\" .. def .. " has a noteMain control")
    local spec = record.specs[record.note_main]
    assert_near(range.low, spec.minval, 1e-9, def .. "'s " .. range.control .. " low = its spec's min")
    assert_near(range.high, spec.maxval, 1e-9, def .. "'s " .. range.control .. " high = its spec's max")
  end
  local count = 0
  for _ in pairs(ranges) do count = count + 1 end
  assert_equal(count, #engine_spec.voice_type_defs, "one noteMainRanges entry per voice type")
end)

-- 3.5's per-note controls are the engine's own (design §3.2): setVoiceParam
-- and setGrainParam refuse them, as the stub does; the envelope times are
-- ordinary voice params (design §3.5)
test("the stub refuses the per-note controls and accepts the envelope times", function()
  load_strata()
  -- (refused as the engine's, not merely as a name no SynthDef has)
  local owned = "a control the engine sets itself"
  assert_engine_rejects(owned, "setVoiceParam", 0, "noteGate", 0)
  assert_engine_rejects(owned, "setVoiceParam", 0, "noteAmp", 1)
  assert_engine_rejects(owned, "setGrainParam", 0, "notePos", 0)
  assert_engine_rejects(owned, "setGrainParam", 0, "noteRate", 2)
  for _, name in ipairs({"noteGate", "noteBend", "noteAmp", "noteMain", "notePos", "noteSize", "noteRate", "t_accent"}) do
    assert_true(engine_spec.engine_controls[name], name .. " is one of engineOwnedControls")
  end
  -- the stage's t_gate (ruling 54), refused as the engine's
  assert_engine_rejects(owned, "setGrainParam", 0, "t_gate", 1)
  assert_engine_rejects(owned, "setVoiceParam", 0, "t_gate", 1)
  engine.setVoiceParam(0, "attackTime", 0.01)
  engine.setVoiceParam(0, "releaseTime", 30)
  for index, def in ipairs(engine_spec.voice_type_defs) do
    for _, name in ipairs({"attackTime", "releaseTime"}) do
      assert_true(engine_spec.voice_params[index][name], name .. " is a setVoiceParam name of \\" .. def)
    end
  end
end)

-- 3.9 (#873): the notes model's kind rule (test/notes_model.lua's
-- Model:kind_for) is the engine's (StrataNotes.sc's noteKindFor): the same
-- branches in the same order, each returning the same kind and testing the
-- same cases. A changed condition on either side fails, so a new case
-- reaches the model
test("the model's kind rule names the engine's cases", function()
  -- Each branch's condition as its tokens (names, numbers, comparison
  -- operators and the minus sign, in order) on each side, the lines before
  -- the branches first, against one expected list a side (the two languages
  -- spell their operators apart): so any other name (this.<name> or a bare
  -- instance variable), number, sign or comparison operator in either
  -- fails, and each side's numbers are the other's
  local EXPECTED = {
    { kind = "", engine = { "var", "source", "=", "grainSource", "voice" },
      model = { "local", "source", "=", "self", "voices", "voice", "source" } },
    { kind = "input", engine = { "source", "==", "this", "inputSource", "or", "this", "voiceSource", "source" },
      model = { "source", "==", "self", "input", "or", "self", "voice_source", "source" } },
    { kind = "buffer", engine = { "source", "inclusivelyBetween", "1", "numBuffers" },
      model = { "source", ">=", "1", "and", "source", "<=", "self", "buffers" } },
    { kind = "stream", engine = { "this", "frozenSynthVoice", "voice" }, model = { "self", "frozen_synth_voice", "voice" } },
    { kind = "voice", engine = {}, model = {} },
  }
  -- names, numbers and operators (runs of = < > ! ~ and the minus sign), in order
  local function tokens(text)
    local list, position = {}, 1
    while true do
      local start, finish = text:find("[%w_]+", position)
      local operator_start, operator_finish = text:find("[=<>!~%-]+", position)
      if operator_start and (not start or operator_start < start) then start, finish = operator_start, operator_finish end
      if not start then return list end
      list[#list + 1] = text:sub(start, finish)
      position = finish + 1
    end
  end
  local function numbers(list)
    local found = {}
    for _, token in ipairs(list) do if token:match("^%d") then found[#found + 1] = token end end
    return table.concat(found, " ")
  end
  -- the problems of one engine source and model text (empty: they agree)
  local function kind_rule_problems(engine_text, model_text)
    local problems = {}
    local function check(ok, text) if not ok then problems[#problems + 1] = text end end
    local engine_body = stubs.strip_sc_comments(engine_text):match("noteKindFor%s*{%s*arg%s+voice;(.-)\n    }")
    local model_body = model_text:match("\nfunction Model:kind_for%(voice%)(.-)\nend\n")
    check(engine_body ~= nil, "noteKindFor { arg voice; ... } (StrataNotes.sc)")
    check(model_body ~= nil, "function Model:kind_for(voice) ... end (test/notes_model.lua)")
    if not engine_body or not model_body then return problems end
    -- entry 1 the lines before the branches (kind ""), then one a branch
    local engine_branches, model_branches = { { condition = "", kind = "" } }, { { condition = "", kind = "" } }
    for line in engine_body:gmatch("[^\n]+") do
      local condition, kind = line:match("^%s*if%s*(%b())%s*{%s*%^\\(%w+)%s*}%s*;?%s*$")
      if not kind then kind = line:match("^%s*%^\\(%w+)%s*;?%s*$") end
      if kind then engine_branches[#engine_branches + 1] = { condition = condition or "", kind = kind }
      elseif #engine_branches == 1 then engine_branches[1].condition = engine_branches[1].condition .. " " .. line
      else check(false, "noteKindFor: a line that is no branch after its first branch: " .. line) end
    end
    for line in model_body:gmatch("[^\n]+") do
      local condition, kind = line:match("^%s*if%s+(.-)%s+then%s+return%s+\"(%w+)\"%s+end%s*$")
      if not kind then kind = line:match("^%s*return%s+\"(%w+)\"%s*$") end
      if kind then model_branches[#model_branches + 1] = { condition = condition or "", kind = kind }
      elseif #model_branches == 1 then model_branches[1].condition = model_branches[1].condition .. " " .. line
      else check(false, "Model:kind_for: a line that is no branch after its first branch: " .. line) end
    end
    check(#engine_branches == #EXPECTED, "noteKindFor's four branches: " .. #engine_branches - 1)
    check(#model_branches == #EXPECTED, "Model:kind_for's four branches: " .. #model_branches - 1)
    for index, expected in ipairs(EXPECTED) do
      local engine_branch = engine_branches[index] or { condition = "", kind = "(none)" }
      local model_branch = model_branches[index] or { condition = "", kind = "(none)" }
      local where = index == 1 and "before the branches" or "branch " .. index - 1 .. " (\\" .. expected.kind .. ")"
      check(engine_branch.kind == expected.kind, where .. ": the engine's kind is " .. engine_branch.kind)
      check(model_branch.kind == expected.kind, where .. ": the model's kind is " .. model_branch.kind)
      local engine_tokens, model_tokens = tokens(engine_branch.condition), tokens(model_branch.condition)
      check(table.concat(engine_tokens, " ") == table.concat(expected.engine, " "),
        where .. ": the engine's tokens are " .. table.concat(engine_tokens, " "))
      check(table.concat(model_tokens, " ") == table.concat(expected.model, " "),
        where .. ": the model's tokens are " .. table.concat(model_tokens, " "))
      check(numbers(engine_tokens) == numbers(model_tokens), where .. ": the engine's numbers "
        .. numbers(engine_tokens) .. ", the model's " .. numbers(model_tokens))
    end
    return problems
  end
  local file = assert(io.open(repo_root .. "/test/notes_model.lua", "r")); local model_text = file:read("*a"); file:close()
  local engine_text = engine_sources()
  local found = kind_rule_problems(engine_text, model_text)
  assert_equal(#found, 0, "the model's kind rule against the engine's: " .. table.concat(found, "; "))
  -- the check's own controls: a bare instance variable in a condition,
  -- another lower bound of the buffer branch, and a changed comparison on
  -- either side, each fail it
  local function patched(text, old, new)
    local start, finish = text:find(old, 1, true)
    assert_true(start ~= nil, "the source holds " .. old)
    return text:sub(1, start - 1) .. new .. text:sub(finish + 1)
  end
  local controls = {
    { "a bare instance variable", patched(engine_text, "if (this.frozenSynthVoice(voice)) { ^\\stream };",
      "if (this.frozenSynthVoice(voice) and: { grainSource[voice] == 0 }) { ^\\stream };"), model_text },
    { "the buffer branch from 0", patched(engine_text, "if (source.inclusivelyBetween(1, numBuffers)) { ^\\buffer };",
      "if (source.inclusivelyBetween(0, numBuffers)) { ^\\buffer };"), model_text },
    { "the engine's input test as !=", patched(engine_text, "if ((source == this.inputSource) or:",
      "if ((source != this.inputSource) or:"), model_text },
    { "the model's buffer bound as >", engine_text, patched(model_text, "if source >= 1 and source <= self.buffers then",
      "if source > 1 and source <= self.buffers then") },
    { "the engine's buffer bound negated", patched(engine_text, "if (source.inclusivelyBetween(1, numBuffers)) { ^\\buffer };",
      "if (source.inclusivelyBetween(-1, numBuffers)) { ^\\buffer };"), model_text },
    { "the model's buffer bound negated", engine_text, patched(model_text, "if source >= 1 and source <= self.buffers then",
      "if source >= -1 and source <= self.buffers then") },
  }
  local uncaught = {}
  for _, control in ipairs(controls) do
    if #kind_rule_problems(control[2], control[3]) == 0 then uncaught[#uncaught + 1] = control[1] end
  end
  assert_equal(#uncaught, 0, "controls the check does not fail: " .. table.concat(uncaught, "; "))
end)

end
