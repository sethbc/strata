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
  -- #24's SynthDef and envelope parsers: a commented-out SynthDef, argument or Env
  local patched, count = source:gsub("SynthDef%(\\strataGrainRing, {%s*arg ", "%0/* ghostControl=0, */ ")
  assert_equal(count, 1, "argument patch applies")
  patched, count = patched:gsub("envBuffers%s*=%s*%[", "%0\n            // Env.ghost,")
  assert_equal(count, 1, "envelope patch applies")
  local spec = stubs.engine_spec_from_source(patched .. "\n// SynthDef(\\ghostDef, { arg ghost; });")
  assert_true(spec.synthdef_controls.ghostDef == nil, "a commented-out SynthDef is skipped")
  assert_true(not spec.synthdef_controls.strataGrainRing.ghostControl, "a commented-out argument is skipped")
  assert_true(spec.synthdef_controls.strataGrainRing.grainSize, "the arguments around it are read")
  assert_equal(spec.enumerations.envShape[2], engine_spec.enumerations.envShape[2], "a commented-out Env is not counted")
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
  assert_equal(spec.mod_slots, local_value("NUM_MOD_SLOTS"), "modBus1..N on every voice SynthDef")
  assert_equal(#spec.voice_synthdefs, spec.num_voices, "one voice SynthDef per voice")
  assert_equal(spec.voice_synthdefs[1], "strataResonator", "voice 0 SynthDef")
  assert_equal(spec.voice_synthdefs[7], "strataRing", "voice 6 SynthDef")
  assert_true(spec.synthdef_controls.strataFM.ratio, "strataFM controls parsed")
  assert_true(spec.synthdef_controls.strataGrainBuf.bufPos, "strataGrainBuf controls parsed")
  assert_true(spec.grain_params.envShape, "setGrainParam's own envShape is accepted")
  assert_true(spec.grain_params.bufPos and spec.grain_params.grainSize, "grain SynthDef controls are accepted")
  -- each enumerated control is 0..options - 1 of its Lua option param
  assert_equal(spec.enumerations.grainMode[1], 0, "grainMode from 0")
  assert_equal(spec.enumerations.grainMode[2], #local_value("GRAIN_MODE_OPTIONS") - 1, "grainMode to triggered")
  assert_equal(spec.enumerations.envShape[1], 0, "envShape from Hann")
  assert_equal(spec.enumerations.envShape[2], #local_value("GRAIN_ENV_OPTIONS") - 1, "envShape to the last envelope buffer")
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
  -- (declared in exactly one of the script's files)
  local stride
  for _, source in ipairs(read_lua_sources()) do
    local found = tonumber(source.text:match("\nlocal BUFFER_STATE_STRIDE%s*=%s*(%d+)"))
    if found then
      assert_equal(stride, nil, "BUFFER_STATE_STRIDE is declared once")
      stride = found
    end
  end
  assert_equal(engine_spec.buffer_state_stride, stride, "bufferStateStride = BUFFER_STATE_STRIDE")
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
    local values, tokens, position = {numBuffers = engine_spec.num_buffers}, {}, 1
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
  load_buffer(5, "/tmp/a.wav"); context.polls.fire("bufferState", 4004)
  load_buffer(5, "/tmp/bad.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 2, false))
  assert_equal(buffers[5].name, "a.wav", "bufferLoadFailed: load 2 undone")
  load_buffer(5, "/tmp/gone.wav")
  context.polls.fire("bufferLoadFailed", load_failed_value(4, 3, true))
  assert_equal(buffers[5].name, "empty", "bufferLoadFailed: load 3 emptied the slot")
  -- bufferSaveResult: slot 6's first save written, its second failed
  load_buffer(6, "/tmp/c.wav"); context.polls.fire("bufferState", 5004)
  assert_true(save_buffer(6))
  context.polls.fire("bufferSaveResult", save_result_value(5, 1, false))
  assert_equal(S.lib.ui_flash.text("hints"), "saved buf 6", "bufferSaveResult: save 1 written")
  assert_true(save_buffer(6))
  context.polls.fire("bufferSaveResult", save_result_value(5, 2, true))
  assert_equal(S.lib.ui_flash.text("hints"), "buf 6 save failed", "bufferSaveResult: save 2 failed")
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
    {"recordBuffer", {0, 4, 1, 1.5, 0, 0, 0, 0}, "feedback past 1"},
    {"recordBuffer", {0, 4, 1, 0, 10, 0, 0, 0}, "source past 9"},
    {"recordBuffer", {0, 4, 1, 0, 0, -0.1, 0, 0}, "threshold below 0"},
    {"recordBuffer", {0, 4, 1, 0, 0, 0, 2, 0}, "loop past 1"},
    {"recordBuffer", {0, 4, 1, 0, 0, 0, 0, -1}, "delay below 0"},
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
  assert_true(pcall(engine.recordBuffer, 7, 16, 1, 1, 9, 0.5, 1, 2), "every recordBuffer argument at its limit")
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
  patched, count = patched:gsub(",%s*\\strataRing%]", "]")
  assert_equal(count, 1, "voiceSynthDefs patch applies")
  patched, count = patched:gsub("var <numBuffers = %d+;", "var <numBuffers = 4;")
  assert_equal(count, 1, "numBuffers patch applies")
  local spec = stubs.parse_engine_spec(patched)
  assert_equal(spec.num_voices, 6, "numVoices read from the patched copy")
  assert_equal(spec.num_buffers, 4, "numBuffers read from the patched copy")
  assert_equal(spec.input_source, 5, "inputSource follows numBuffers")
  -- the stub's range checks use them
  stubs.install { signatures = signatures, engine_polls = engine_polls, engine_spec = spec,
    data_dir = data_root .. "patched_engine/", quiet = true }
  engine.voiceOff(5); engine.clearBuffer(3); engine.setGrainSource(0, 5); engine.setModSource(0, 1, 5)
  assert_engine_rejects("voice", "voiceOff", 6)
  assert_engine_rejects("slot", "clearBuffer", 4)
  assert_engine_rejects("source", "setGrainSource", 0, 6)
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
  assert_equal(compared, 7, "filter freq, res and mix; delay time, feedback and mix; reverb mix compared")
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
  patched, count = patched:gsub("(this%.setSynth%(\\reverb, [^;]*;)", "%1 this.setSynth(\\master, \\drift, msg[3]);")
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
    "1:strataReverb.mix 2:strataReverb.size 3:strataMaster.drift 3:strataReverb.damp",
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
  assert_engine_rejects("slot", "recordBuffer", 8, 4, 1, 0, 0, 0, 0, 0)
  engine.clearBuffer(0); engine.clearBuffer(7)
  -- sources are 0 (synth), 1..numBuffers, numBuffers + 1 (input)
  assert_engine_rejects("source", "setGrainSource", 0, 10)
  assert_engine_rejects("source", "setGrainSource", 0, -1)
  engine.setGrainSource(0, 0); engine.setGrainSource(0, 9)
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
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", 5)
  assert_engine_rejects("envShape", "setGrainParam", 0, "envShape", -1)
  engine.setGrainParam(0, "grainMode", 1); engine.setGrainParam(0, "envShape", 4)
end)

-- A NaN fails every `<` and `>` of a range check, and an infinity passes
-- wherever the engine clips nothing: the type check refuses both (#477)
test("the engine stub rejects a NaN or infinite argument (#477)", function()
  load_strata()
  local nan, inf = 0 / 0, math.huge
  assert_engine_rejects("finite", "setFilter", nan, 0.5, 0, 1)
  assert_engine_rejects("finite", "setDelay", nan, nan, nan)
  assert_engine_rejects("finite", "recordBuffer", 0, nan, 1, 0, 0, 0, 0, 0)
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
  check_limits("setDelay", {0.375, 0.4, 0}, 1, "time", engine_limit("setDelay", 1, "time"))
  check_limits("setDelay", {0.375, 0.4, 0}, 2, "feedback", engine_limit("setDelay", 2, "feedback"))
  check_limits("setDelay", {0.375, 0.4, 0}, 3, "mix", engine_limit("setDelay", 3, "mix"))
  check_limits("retrigger", {0, 1}, 2, "velocity", engine_limit("retrigger", 2, "velocity"))
  -- the limits follow the engine source
  local source = engine_sources()
  local patched, count = source:gsub("feedback%.clip%(0, 0%.95%)", "feedback.clip(0, 0.5)")
  assert_equal(count, 1, "feedback patch applies")
  patched, count = patched:gsub("msg%[2%]%.clip%(0, 1%)", "msg[2].clip(0, 0.8)")
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
  assert_engine_rejects("nonsense", "setVoiceParam", 0, "nonsense", 1)
  for engine_voice = 0, spec.num_voices - 1 do engine.setVoiceParam(engine_voice, "bend", 1) end
  -- grain params: either grain SynthDef's controls (kept for a source switch) plus envShape
  assert_engine_rejects("ratio", "setGrainParam", 0, "ratio", 1)
  assert_engine_rejects("grainsize", "setGrainParam", 0, "grainsize", 0.1)
  engine.setGrainParam(0, "bufPos", 0.5); engine.setGrainParam(0, "grainSize", 0.1)
  engine.setGrainParam(0, "envShape", 0)
end)

test("AGENTS.md is the only agent instructions file", function()
  local agents = io.open(repo_root .. "/AGENTS.md", "r")
  assert_true(agents ~= nil, "AGENTS.md is at the repository root")
  if agents then agents:close() end
  local old = io.open(repo_root .. "/CLAUDE.md", "r")
  if old then old:close() end
  assert_true(old == nil, "CLAUDE.md is gone: the instructions live in AGENTS.md alone")
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
  -- docs/status.md or docs/notes is gone
  local doc_names = maintained_docs()
  for _, note in ipairs({"docs/status.md", "docs/notes/engine/structure.md", "docs/notes/lua/state-and-voices.md"}) do
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

test("every docs/notes/lua file opens with a Must not break section", function()
  local files = markdown_files("docs/notes/lua")
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
      local link = "(" .. folder .. "/" .. path:match("([^/]+)$") .. ")"
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
  "effects", "mix", "performance", "rings", "freeze", "variation", "loops", "record", "waveform", "positions", "soak" }

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
-- say how to run it (status.md's checks, and the engine notes)
test("every on-demand engine check area is documented and has a file (#131)", function()
  local on_demand, count = on_demand_areas(), 0
  local status = read_repo_file("docs/status.md")
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
    assert_true(status:find(run, 1, true) ~= nil, "docs/status.md says how to run " .. name .. " (" .. run .. ")")
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
  local block = workflow:match("\n%s*areas:%s*\n(.-)\n%s*env:")
  assert_true(block ~= nil, "the engine-shard matrix lists its areas")
  local seen, shards = {}, 0
  for shard in block:gmatch("%-%s*([%w,]+)") do
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
  local expected = { lua = 15, ["engine-shard"] = 15, engine = 5 }
  for _, name in ipairs(order) do
    assert_true(jobs[name].minutes ~= nil, "job " .. name .. " has a timeout-minutes at its own indent")
    assert_true(expected[name] ~= nil, "job " .. name .. " has no expected timeout in this test")
    assert_equal(jobs[name].minutes, expected[name], "timeout-minutes of job " .. name)
  end
  for name in pairs(expected) do assert_true(jobs[name] ~= nil, "job " .. name .. " exists") end
  -- the shard's timeout covers its engine check plus setup
  local seconds = tonumber(jobs["engine-shard"].text:match("name: Engine check\n%s+run:[^\n]-timeout (%d+) "))
  assert_true(seconds ~= nil, "the engine check step has a timeout in seconds")
  local setup_seconds = 180
  assert_true(seconds + setup_seconds <= jobs["engine-shard"].minutes * 60,
    "the shard's timeout covers its " .. seconds .. " s check plus " .. setup_seconds .. " s of setup")
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
  assert_true(step:find("timeout 600", 1, true) ~= nil, "CI keeps its 600 s limit around the shard")
  assert_true(read_repo_file("test/run_engine_check.sh"):find("ENGINE_CHECK_TIMEOUT:-1200", 1, true) ~= nil,
    "the runner's default timeout is 1200 s")
  assert_true(read_repo_file("test/engine_check.scd"):find("{ 1170 }", 1, true) ~= nil,
    "the check's fallback deadline is 1170 s")
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
  for name, value in paragraph:gmatch("`([%u_]+)` %((%d+)[,)]") do
    checked = checked + 1
    if constants[name] ~= tonumber(value) then
      table.insert(problems, name .. ": AGENTS.md says " .. value .. ", constants has " .. tostring(constants[name]))
    end
  end
  assert_true(checked >= 10, "the paragraph quotes at least ten values, saw " .. checked)
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


test("state-and-voices.md lists every registered invariant (#470)", function()
  local notes = read_repo_file("docs/notes/lua/state-and-voices.md")
  local missing, count = {}, 0
  for _, source in ipairs(read_lua_sources()) do
    for name in source.text:gmatch("S%.register_invariant%(\"([^\"]+)\"") do
      count = count + 1
      if not notes:find("| `" .. name .. "` |", 1, true) then table.insert(missing, name) end
    end
  end
  table.sort(missing)
  assert_true(count >= 12, "the code registers its invariants, saw " .. count)
  assert_true(#missing == 0, "no row in the invariants table for: " .. table.concat(missing, ", "))
end)

end
