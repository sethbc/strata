-- norns_stubs.lua
-- Minimal stand-ins for the norns Lua runtime, used by test/run.lua to load
-- strata.lua off-device. Behavior mirrors norns' own implementations
-- (lua/core/params/*.lua, controlspec.lua, grid.lua, arc.lua, clock.lua,
-- lib/util.lua, lib/tabutil.lua) wherever the script depends on it:
--   * control params quantize to controlspec.step and only fire their action
--     when the stored value changes
--   * number params clamp (but do not round) and fire on change
--   * option params store a floored, clamped index; file params a path
--     string, text params any value; triggers fire on every set, trigger
--     binaries only on a set above 0 (nil counts as 1); groups count the
--     params that follow them and cannot nest, and must be followed by
--     exactly n params (then a separator, a group or the end of the list,
--     context.check_param_groups)
--   * param.t holds norns' numeric type codes (params.tOPTION etc.); the
--     param list starts with norns' system params (LEVELS ... CLOCK, see
--     add_system_params), so a script id colliding with one fails
--   * params:write/read follow lua/core/paramset.lua for absolute paths:
--     read sets each param in file order, firing its action on a change;
--     params:set_save(id, false) keeps a param out of the file
--   * param strings follow core/params/*.lua: a control without a formatter
--     shows util.round(value, 0.01) .. " " .. units, a number or binary
--     returns its value (a number); a ControlSpec made without a default has
--     none (nil), and its control starts at raw 0
--   * lfo (stub_lfo.lua), midi (stub_midi.lua), poll, fileselect and musicutil
--     follow lib/lfo.lua, core/midi.lua, core/poll.lua, lib/fileselect.lua and
--     lib/musicutil.lua
--   * clock follows lua/core/clock.lua over matron's scheduler
--     (clock_scheduler.cc): clock.run resumes the coroutine at once (an
--     error there reaches the caller); sleep and sync yield to the
--     scheduler, which wakes a sleep at its time and a sync at the next
--     sync beat (counted from the coroutine's previous sync beat when it
--     synced last, with the offset argument and FLT_EPSILON) on a beat
--     timeline that runs at the clock tempo and keeps its beat when the
--     tempo changes. A resumed coroutine gets the clock time (sleep) or beat
--     (sync); one that cancels itself and then waits errors when it wakes,
--     as on norns. Each coroutine holds one of matron's 100 event slots
--     (the lowest free one when it first waits, until it is canceled or
--     ends; all 100 in use is an error, where matron would never wake the
--     coroutine): events due at the same time fire in slot order, a sleep
--     before a sync (matron fires a sleep when the time reaches it, a sync
--     once the beat is past it, so a stub step at a sleep's time leaves a
--     sync due then to the next step, at the same time). util.time() moves
--     with the clocks: clock.advance() is one scheduler step, a matron tick
--     (util.time() moves to the next wake-up, and the events due then are
--     fixed and resume in slot order, not wake order, as matron's tick
--     posts them); clock.advance_until(id) runs it event
--     by event until coroutine id wakes once, and fails at once if id is not
--     waiting or is canceled first; clock.run_for(seconds[, latency]) runs the
--     scheduler for `seconds`, each coroutine `latency` (default 0) after
--     its wake-up, so a clock that sleeps many short steps falls behind one
--     that sleeps once. An error raised in a scheduler resume is not raised:
--     as norns prints it and keeps the other clocks running, the stub keeps
--     it until the test claims it (clock.take_errors()), and the harness
--     fails any test that leaves one behind (stubs.take_clock_errors())
--   * util.time() is the clock's time; context.set_time(seconds) also moves it
--   * clock_tempo starts at 120 BPM, not norns' factory 90 (core/state.lua):
--     the tests assume 120, and on norns it is the user's saved tempo anyway
--   * the screen records texts, lines and rects (for layout checks)
--   * grid/arc device events fire both device.key and vports[port].key; the
--     arc device keeps matron's LED levels (led/all with rel, segment as
--     lua/core/arc.lua, through led)
--   * tab.save/tab.load are lib/tabutil.lua's, ported unchanged
--   * include(file) follows lua/core/startup.lua: dofile of the script
--     folder's <file>.lua, every call (stubs.install's module_sources
--     replaces a file's text)
-- The engine stub validates every engine.* call against the addCommand
-- signatures parsed from lib/Engine_Strata.sc, and range-checks indices,
-- enumerated values, setVoiceParam/setGrainParam names and continuous values
-- against the limits and SynthDef controls parsed from the same file
-- (stubs.parse_engine_spec), plus the ranges CLAUDE.md documents for
-- arguments the engine does not clip (DOCUMENTED_LIMITS).

local stubs = {}

local function shallow_copy(source)
  local copy = {}
  for key, value in pairs(source) do copy[key] = value end
  return copy
end

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

---------------------------------------------------------------------------
-- engine command signatures (parsed from the SC engine)
---------------------------------------------------------------------------

local function read_engine_source(sc_path)
  local file = assert(io.open(sc_path, "r"))
  local source = file:read("*a")
  file:close()
  return source
end

-- SuperCollider source with its // line comments and /* */ block comments
-- (which nest in SC) replaced by spaces, newlines kept, so a commented-out
-- command, SynthDef argument or Env is never parsed. Strings ("..."),
-- quoted symbols ('...') and character literals ($x) are copied unchanged.
-- An unterminated string, symbol or block comment is an error (it would
-- swallow the rest of the file, and sclang would not compile it either).
-- Every parser of the engine source goes through it: the ones below,
-- engine_spec_from_source, sync_check.lua (which uses
-- engine_signatures_from_source) and the CLAUDE.md table check (which uses
-- parse_engine_signatures).
function stubs.strip_sc_comments(source)
  local output = {}
  local index, length = 1, #source
  local function blank(text) return (text:gsub("[^\n]", " ")) end
  local function unterminated(what, start)
    local _, newlines = source:sub(1, start):gsub("\n", "")
    error(string.format("engine source: unterminated %s from line %d", what, newlines + 1), 0)
  end
  while index <= length do
    local char, two = source:sub(index, index), source:sub(index, index + 1)
    if two == "//" then
      local finish = (source:find("\n", index, true) or (length + 1)) - 1
      table.insert(output, blank(source:sub(index, finish)))
      index = finish + 1
    elseif two == "/*" then
      local depth, cursor = 1, index + 2
      while depth > 0 and cursor <= length do
        local pair = source:sub(cursor, cursor + 1)
        if pair == "/*" then depth, cursor = depth + 1, cursor + 2
        elseif pair == "*/" then depth, cursor = depth - 1, cursor + 2
        else cursor = cursor + 1 end
      end
      if depth > 0 then unterminated("block comment", index) end
      table.insert(output, blank(source:sub(index, cursor - 1)))
      index = cursor
    elseif char == '"' or char == "'" then
      local cursor = index + 1
      while cursor <= length and source:sub(cursor, cursor) ~= char do
        cursor = cursor + (source:sub(cursor, cursor) == "\\" and 2 or 1)
      end
      if cursor > length then unterminated(char == '"' and "string" or "symbol", index) end
      table.insert(output, source:sub(index, cursor))
      index = cursor + 1
    elseif char == "$" then
      local finish = index + (source:sub(index + 1, index + 1) == "\\" and 2 or 1)
      table.insert(output, source:sub(index, finish))
      index = finish + 1
    else
      table.insert(output, char)
      index = index + 1
    end
  end
  return table.concat(output)
end

function stubs.engine_signatures_from_source(source)
  local signatures = {}
  for name, signature in stubs.strip_sc_comments(source):gmatch('addCommand%(%s*\\(%w+)%s*,%s*"([^"]*)"') do
    signatures[name] = signature
  end
  return signatures
end

function stubs.parse_engine_signatures(sc_path)
  return stubs.engine_signatures_from_source(read_engine_source(sc_path))
end

-- engine polls (this.addPoll(\name, ...) in the SC engine)
function stubs.engine_polls_from_source(source)
  source = stubs.strip_sc_comments(source)
  local names = {}
  for name in source:gmatch('addPoll%(%s*\\(%w+)') do table.insert(names, name) end
  for name in source:gmatch('addPoll%(%s*"([^"]+)"') do table.insert(names, name) end
  return names
end

function stubs.parse_engine_polls(sc_path)
  return stubs.engine_polls_from_source(read_engine_source(sc_path))
end

-- The engine's limits and SynthDef controls, for the engine stub's range and
-- name checks. Everything is read from the SC source, so a limit or control
-- changed there needs no stub change:
--   num_voices, num_buffers,  var <numVoices = N; var <numBuffers = N;
--   buffer_seconds,           var <bufferSeconds = N;
--   buffer_state_stride       var <bufferStateStride = N;
--   num_mod_slots             var <numModSlots = N; (the slots the crossmod commands accept)
--   input_source              inputSource { ^numBuffers + N }
--   synthdef_controls[def]    the SynthDef's `arg a, b=1, ...;` (or |...|) names
--   synthdef_defaults[def]    its arguments' numeric defaults (b = 1)
--   control_limits[def][c]    {low, high}: a control the SynthDef body clips
--                             as it is (c.clip(low, high), or after a lag:
--                             c.lag(t).clip(low, high))
--   fx_commands[command]      a list of {argument, synthdef, control}: a
--                             command whose body sets an FX synth
--                             (synths[\key] = Synth(\def, ...)) with
--                             this.setSynth(\key, \control, msg[i], ...),
--                             every such setSynth call and pair read
--   argument_limits[command][i]  {low, high, name}: argument i's limits where
--                             the engine enforces them: the control_limits
--                             of the FX controls it sets, or the command's
--                             own msg[i].clip(low, high) (name: the var it is
--                             assigned to, else "argument i")
--   voice_synthdefs[i]        voiceSynthDefs = [...], i = engine voice + 1
--   mod_slots                 modBus1..N on every voice SynthDef
--   grain_params              setGrainParam names: every control of the
--                             grain SynthDefs (grainDefFor), whichever the
--                             voice uses now (the engine keeps the value for a
--                             source switch), plus the names the command
--                             handles itself (param == \name)
--   voice_params[i]           setVoiceParam names: the voice's SynthDef's
--                             controls (bend is one), plus any `param == \name`
--   enumerations[name]        {low, high}: whole-number controls the engine
--                             rounds (name.round.clip(low, high)), and envShape
--                             (0 = Hann, 1..envBuffers.size, envBufnumFor)
-- Comments are stripped first (strip_sc_comments).
local function engine_number(source, pattern, what)
  return tonumber((assert(source:match(pattern), "engine source: cannot find " .. what)))
end

-- The source of one addCommand's function, up to the next addCommand
local function engine_command_body(source, name)
  local start = assert(source:find("addCommand%(%s*\\" .. name .. "%f[^%w]"), "engine source: no addCommand \\" .. name)
  local finish = source:find("addCommand%(", start + 1) or #source
  return source:sub(start, finish)
end

local function engine_special_params(source, name, into)
  for param in engine_command_body(source, name):gmatch("param%s*==%s*\\([%w_]+)") do into[param] = true end
  return into
end

-- The text of the { ... } block whose "{" is at open_index (strings, quoted
-- symbols and $x characters skipped; comments are already stripped, and
-- strip_sc_comments has checked that every string ends)
local function engine_block(source, open_index)
  local depth, cursor = 0, open_index
  while cursor <= #source do
    local char = source:sub(cursor, cursor)
    if char == '"' or char == "'" then
      cursor = cursor + 1
      while cursor <= #source and source:sub(cursor, cursor) ~= char do
        cursor = cursor + (source:sub(cursor, cursor) == "\\" and 2 or 1)
      end
    elseif char == "$" then
      cursor = cursor + (source:sub(cursor + 1, cursor + 1) == "\\" and 2 or 1)
    elseif char == "{" then
      depth = depth + 1
    elseif char == "}" then
      depth = depth - 1
      if depth == 0 then return source:sub(open_index, cursor) end
    end
    cursor = cursor + 1
  end
  local _, newlines = source:sub(1, open_index):gsub("\n", "")
  error(string.format("engine source: unbalanced { from line %d", newlines + 1), 0)
end

-- `.clip(low, high)` with two literal numbers
local CLIP_LIMITS = "%.clip%(%s*(%-?%d+%.?%d*)%s*,%s*(%-?%d+%.?%d*)%s*%)"

-- Merge {low, high} into limits[key]: an argument limited twice keeps both limits
local function add_limit(limits, key, low, high, name)
  local known = limits[key]
  if known then
    known.low, known.high = math.max(known.low, low), math.min(known.high, high)
  else
    limits[key] = { low = low, high = high, name = name }
  end
end

-- control_limits[def]: the controls a SynthDef body clips as they are
local function synthdef_control_limits(body, controls)
  local limits = {}
  for _, pattern in ipairs({ "()([%a_][%w_]*)%.lag%d?%b()" .. CLIP_LIMITS, "()([%a_][%w_]*)" .. CLIP_LIMITS }) do
    for position, name, low, high in body:gmatch(pattern) do
      local before = body:sub(position - 1, position - 1)
      if controls[name] and not before:match("[%w_%.\\]") then
        local known = limits[name]
        low, high = tonumber(low), tonumber(high)
        assert(not known or (known.low == low and known.high == high), "engine source: " .. name .. " is clipped to two ranges")
        limits[name] = { low = low, high = high }
      end
    end
  end
  return limits
end

function stubs.engine_spec_from_source(source)
  source = stubs.strip_sc_comments(source)
  local spec = {
    num_voices = engine_number(source, "var%s+<?numVoices%s*=%s*(%d+)", "numVoices"),
    num_buffers = engine_number(source, "var%s+<?numBuffers%s*=%s*(%d+)", "numBuffers"),
    buffer_seconds = engine_number(source, "var%s+<?bufferSeconds%s*=%s*(%d+)", "bufferSeconds"),
    buffer_state_stride = engine_number(source, "var%s+<?bufferStateStride%s*=%s*(%d+)", "bufferStateStride"),
    num_mod_slots = engine_number(source, "var%s+<?numModSlots%s*=%s*(%d+)", "numModSlots"),
    synthdef_controls = {},
    synthdef_defaults = {},
    control_limits = {},
    fx_commands = {},
    argument_limits = {},
    voice_synthdefs = {},
    grain_params = {},
    voice_params = {},
    enumerations = {},
  }
  spec.input_source = spec.num_buffers
    + engine_number(source, "inputSource%s*{%s*%^%s*numBuffers%s*%+%s*(%d+)%s*}", "inputSource")

  for name, position in source:gmatch("SynthDef%(%s*\\([%w_]+)%s*,%s*{()") do
    local rest = source:sub(position)
    local arg_list = rest:match("^%s*arg%s+([^;]*);") or rest:match("^%s*|([^|]*)|")
    assert(arg_list, "engine source: SynthDef \\" .. name .. " has no argument list the stub can read")
    local controls, defaults = {}, {}
    for item in arg_list:gmatch("[^,]+") do
      local control = assert(item:match("^%s*([%a_][%w_]*)"), "SynthDef \\" .. name .. ": bad argument " .. item)
      controls[control] = true
      defaults[control] = tonumber(item:match("^%s*[%a_][%w_]*%s*=%s*(%-?[%d%.]+)%s*$"))
    end
    spec.synthdef_controls[name] = controls
    spec.synthdef_defaults[name] = defaults
    spec.control_limits[name] = synthdef_control_limits(engine_block(source, position - 1), controls)
  end

  local fx_synthdefs = {}
  for key, name in source:gmatch("synths%[%s*\\([%w_]+)%s*%]%s*=%s*Synth%(%s*\\([%w_]+)") do
    assert(spec.synthdef_controls[name], "engine source: synths[\\" .. key .. "] plays unknown SynthDef \\" .. name)
    fx_synthdefs[key] = name
  end
  for command in pairs(stubs.engine_signatures_from_source(source)) do
    local body = engine_command_body(source, command)
    local limits = {}
    for key, settings in body:gmatch("this%.setSynth%(%s*\\([%w_]+)%s*,([^;]*)%)%s*;") do
      local synthdef = fx_synthdefs[key]
      if synthdef then
        spec.fx_commands[command] = spec.fx_commands[command] or {}
        for control, index in settings:gmatch("\\([%w_]+)%s*,%s*msg%[(%d+)%]") do
          index = tonumber(index)
          table.insert(spec.fx_commands[command], { argument = index, synthdef = synthdef, control = control })
          local limit = spec.control_limits[synthdef][control]
          if limit then add_limit(limits, index, limit.low, limit.high, control) end
        end
      end
    end
    for assigned, index, low, high in body:gmatch("()msg%[(%d+)%]" .. CLIP_LIMITS) do
      index = tonumber(index)
      local name = body:sub(1, assigned - 1):match("([%a_][%w_]*)%s*=%s*$") or ("argument " .. index)
      add_limit(limits, index, tonumber(low), tonumber(high), name)
    end
    if next(limits) then spec.argument_limits[command] = limits end
  end

  local voice_list = assert(source:match("voiceSynthDefs%s*=%s*%[(.-)%]"), "engine source: no voiceSynthDefs")
  for name in voice_list:gmatch("\\([%w_]+)") do
    assert(spec.synthdef_controls[name], "engine source: voiceSynthDefs names unknown SynthDef \\" .. name)
    table.insert(spec.voice_synthdefs, name)
  end
  assert(#spec.voice_synthdefs == spec.num_voices, "engine source: voiceSynthDefs does not list numVoices SynthDefs")

  spec.mod_slots = 0
  while true do
    local control = "modBus" .. (spec.mod_slots + 1)
    for _, name in ipairs(spec.voice_synthdefs) do
      if not spec.synthdef_controls[name][control] then control = nil; break end
    end
    if not control then break end
    spec.mod_slots = spec.mod_slots + 1
  end

  local grain_def_body = assert(source:match("grainDefFor%s*{(.-)\n%s*}"), "engine source: no grainDefFor")
  for name in grain_def_body:gmatch("\\([%w_]+)") do
    for control in pairs(assert(spec.synthdef_controls[name], "grainDefFor names unknown SynthDef \\" .. name)) do
      spec.grain_params[control] = true
    end
  end
  engine_special_params(source, "setGrainParam", spec.grain_params)
  for index, name in ipairs(spec.voice_synthdefs) do
    spec.voice_params[index] = engine_special_params(source, "setVoiceParam", shallow_copy(spec.synthdef_controls[name]))
  end

  for name, low, high in source:gmatch("([%a_][%w_]*)%.round%.clip%(%s*(%-?%d+)%s*,%s*(%-?%d+)%s*%)") do
    local range = { tonumber(low), tonumber(high) }
    local known = spec.enumerations[name]
    assert(not known or (known[1] == range[1] and known[2] == range[2]), "engine source: " .. name .. " is clipped to two ranges")
    spec.enumerations[name] = range
  end
  local envelopes = assert(source:match("envBuffers%s*=%s*%[(.-)%]%.collect"), "engine source: no envBuffers")
  local _, envelope_count = envelopes:gsub("Env[%.%(]", "")
  spec.enumerations.envShape = { 0, envelope_count }
  return spec
end

function stubs.parse_engine_spec(sc_path)
  return stubs.engine_spec_from_source(read_engine_source(sc_path))
end

-- Limits CLAUDE.md's command table documents for arguments the engine does
-- not clip itself: the crossmod depths ("-2 to 2") and the mod speed
-- ("0.1-50"). The numbers are not copied here: each check reads, when the
-- command is called, the controlspec of the Lua param that sends the
-- argument (param_id(args) names it).
local DOCUMENTED_LIMITS = {
  setModAmpAmt = { argument = 3, name = "amount",
    param_id = function(args) return ("v%d_mod_amp_amt_%d"):format(args[1] + 1, args[2]) end },
  setModFreqAmt = { argument = 3, name = "amount",
    param_id = function(args) return ("v%d_mod_freq_amt_%d"):format(args[1] + 1, args[2]) end },
  setModSpeed = { argument = 2, name = "speed", param_id = function(args) return ("v%d_mod_speed"):format(args[1] + 1) end },
}

-- Per-command checks of argument values (after the type checks): each
-- returns an error message, or nil when the arguments are valid. Every
-- engine command needs an entry, so a new command gets its limits checked.
-- Each entry checks indices and enumerated values; every command's
-- continuous arguments are then checked against spec.argument_limits (the
-- limits the engine enforces) and DOCUMENTED_LIMITS (lookup_param(id) finds
-- the Lua param).
local function engine_argument_checks(spec, lookup_param)
  local last_voice = spec.num_voices - 1
  local function range(what, value, low, high)
    if value < low or value > high then
      return string.format("%s %s is outside %g..%g", what, tostring(value), low, high)
    end
  end
  -- continuous values may miss a limit by a rounding error: a 0.01 step
  -- quantizes 0.95 to 95 * 0.01 = 0.9500000000000001
  local function float_range(what, value, low, high)
    local slack = 1e-12 * math.max(1, math.abs(low), math.abs(high))
    return range(what, value, low - slack, high + slack) and range(what, value, low, high)
  end
  local function continuous(command, args)
    for index, limit in pairs(spec.argument_limits[command] or {}) do
      local problem = float_range(limit.name, args[index], limit.low, limit.high)
      if problem then return problem .. " (the engine clips it there)" end
    end
    local documented = DOCUMENTED_LIMITS[command]
    if documented then
      local param_id = documented.param_id(args)
      local param = lookup_param(param_id)
      if not (param and param.controlspec) then
        return "the stub reads this command's documented limit from param " .. param_id .. ", which is not a control"
      end
      local spec_range = param.controlspec
      local problem = float_range(documented.name, args[documented.argument], spec_range.minval, spec_range.maxval)
      if problem then return problem .. " (" .. param_id .. "'s range, which CLAUDE.md documents)" end
    end
  end
  local function enumerated(name, value)
    local limits = spec.enumerations[name]
    if not limits then return nil end
    if not is_integer(value) then return name .. " " .. tostring(value) .. " must be a whole number" end
    return range(name, value, limits[1], limits[2])
  end
  local function none() return nil end
  local function voice(args) return range("voice", args[1], 0, last_voice) end
  local function slot(args) return range("slot", args[1], 0, spec.num_buffers - 1) end
  local function voice_and_mod_slot(args) return voice(args) or range("mod slot", args[2], 1, spec.mod_slots) end
  local function named_param(args, accepted, what)
    if not accepted[args[2]] then return string.format("param \"%s\" is not a control of %s", args[2], what) end
    return enumerated(args[2], args[3])
  end
  local checks = {
    voiceOn = voice, voiceOff = voice, retrigger = voice, setModSpeed = voice,
    setVoiceParam = function(args)
      return voice(args)
        or named_param(args, spec.voice_params[args[1] + 1], "\\" .. spec.voice_synthdefs[args[1] + 1])
    end,
    setGrainParam = function(args)
      return voice(args) or named_param(args, spec.grain_params, "the grain SynthDefs")
    end,
    setGrainSource = function(args) return voice(args) or range("source", args[2], 0, spec.input_source) end,
    loadBuffer = slot, recordBuffer = slot, clearBuffer = slot, stopRecord = slot, saveBuffer = slot,
    setModSource = function(args) return voice_and_mod_slot(args) or range("mod source", args[3], -1, last_voice) end,
    setModAmpAmt = voice_and_mod_slot, setModFreqAmt = voice_and_mod_slot,
    setFilter = function(args) return enumerated("filterType", args[3]) end,
    setMasterDrift = none, setReverb = none, setDelay = none,
  }
  for command, check in pairs(checks) do
    checks[command] = function(args) return check(args) or continuous(command, args) end
  end
  return checks
end

---------------------------------------------------------------------------
-- util
---------------------------------------------------------------------------

local function make_util()
  local util = {}
  -- lib/util.lua: util.time() is the wall clock in seconds. In the stub it
  -- moves with the clocks (clock.advance, clock.run_for) and
  -- context.set_time(seconds)
  util.stub_now = 0
  function util.time() return util.stub_now end
  function util.clamp(n, min, max) return math.min(max, math.max(n, min)) end
  function util.linlin(slo, shi, dlo, dhi, f)
    if f <= slo then return dlo
    elseif f >= shi then return dhi
    else return (f - slo) / (shi - slo) * (dhi - dlo) + dlo end
  end
  function util.linexp(slo, shi, dlo, dhi, f)
    if f <= slo then return dlo
    elseif f >= shi then return dhi
    else return (dhi / dlo) ^ ((f - slo) / (shi - slo)) * dlo end
  end
  function util.explin(slo, shi, dlo, dhi, f)
    if f <= slo then return dlo
    elseif f >= shi then return dhi
    else return math.log(f / slo) / math.log(shi / slo) * (dhi - dlo) + dlo end
  end
  function util.round(number, quant)
    if quant == 0 then return number end
    return math.floor(number / (quant or 1) + 0.5) * (quant or 1)
  end
  function util.file_exists(name)
    local file = io.open(name, "r")
    if file ~= nil then io.close(file) return true end
    return false
  end
  function util.make_dir(path)
    os.execute("mkdir -p '" .. path .. "'")
  end
  -- norns runs `ls -pL --group-directories-first`; BSD ls lacks the last flag
  function util.scandir(directory)
    local listing = {}
    local pipe = io.popen('ls -pL "' .. directory .. '" 2>/dev/null')
    for filename in pipe:read("*a"):gmatch("[^\r\n]+") do table.insert(listing, filename) end
    pipe:close()
    return listing
  end
  function util.os_capture(cmd, raw)
    local pipe = io.popen(cmd)
    local output = pipe:read("*a")
    pipe:close()
    if raw then return output end
    output = string.gsub(output, "^%s+", "")
    output = string.gsub(output, "%s+$", "")
    output = string.gsub(output, "[\n\r]+", " ")
    return output
  end
  return util
end

---------------------------------------------------------------------------
-- controlspec
---------------------------------------------------------------------------

local function make_controlspec(util)
  local ControlSpec = {}
  ControlSpec.__index = ControlSpec

  -- core/controlspec.lua's DbFaderWarp (math.log10 and math.pow are Lua
  -- 5.3 compatibility functions, so the stub spells them out)
  local function ampdb(amp) return math.log(amp, 10) * 20.0 end
  local function dbamp(db) return 10.0 ^ (db * 0.05) end
  local function db_map(spec, value)
    local range = dbamp(spec.maxval) - dbamp(spec.minval)
    if range >= 0 then
      return ampdb(value * value * range + dbamp(spec.minval))
    else
      return ampdb((1 - (1 - value) * (1 - value)) * range + dbamp(spec.minval))
    end
  end
  local function db_unmap(spec, value)
    local minval, maxval = spec.minval, spec.maxval
    if maxval - minval >= 0 then
      return math.sqrt((dbamp(value) - dbamp(minval)) / (dbamp(maxval) - dbamp(minval)))
    else
      return 1 - math.sqrt(1 - ((dbamp(value) - dbamp(minval)) / (dbamp(maxval) - dbamp(minval))))
    end
  end

  -- core/controlspec.lua: `s.default = default or minval` reads the unset
  -- global minval, so a spec made without a default has none (nil), and a
  -- control param made from it starts at raw 0 (params/control.lua)
  function ControlSpec.new(min, max, warp, step, default, units, quantum, wrap)
    local spec = setmetatable({}, ControlSpec)
    spec.minval = min or 0
    spec.maxval = max or 1
    spec.warp_name = (warp == "exp" or warp == "db") and warp or "lin"
    spec.step = step or 0
    spec.default = default
    spec.units = units or ""
    spec.quantum = quantum or 0.01
    spec.wrap = wrap or false
    return spec
  end

  function ControlSpec:map(value)
    local clamped = util.clamp(value, 0, 1)
    local mapped
    if self.warp_name == "exp" then
      mapped = util.linexp(0, 1, self.minval, self.maxval, clamped)
    elseif self.warp_name == "db" then
      mapped = db_map(self, clamped)
    else
      mapped = util.linlin(0, 1, self.minval, self.maxval, clamped)
    end
    return util.round(mapped, self.step)
  end

  function ControlSpec:unmap(value)
    local clamped = util.clamp(util.round(value, self.step), math.min(self.minval, self.maxval),
      math.max(self.minval, self.maxval))
    if self.warp_name == "exp" then
      return util.explin(self.minval, self.maxval, 0, 1, clamped)
    elseif self.warp_name == "db" then
      return db_unmap(self, clamped)
    end
    return util.linlin(self.minval, self.maxval, 0, 1, clamped)
  end

  return { new = ControlSpec.new, UNIPOLAR = ControlSpec.new(0, 1, "lin", 0, 0, "") }
end

---------------------------------------------------------------------------
-- params
---------------------------------------------------------------------------

-- norns stores numeric type codes in param.t (lua/core/paramset.lua); params:add
-- still takes the type name as a string. This is the one table of codes: the
-- locals below and ParamSet's tSEPARATOR ... tBINARY are built from it.
local PARAM_TYPE_CODES = {
  separator = 0, number = 1, option = 2, control = 3, file = 4, taper = 5, trigger = 6, group = 7, text = 8,
  binary = 9,
}
stubs.PARAM_TYPE_CODES = PARAM_TYPE_CODES
local codes = PARAM_TYPE_CODES
local tSEPARATOR, tNUMBER, tOPTION, tCONTROL = codes.separator, codes.number, codes.option, codes.control
local tFILE, tTRIGGER, tGROUP, tTEXT, tBINARY = codes.file, codes.trigger, codes.group, codes.text, codes.binary

-- The params norns adds before every script (lua/core/script.lua calls
-- audio.add_params() and clock.add_params() after params:clear()), in
-- order, with their types, ranges, group sizes and factory defaults
-- (core/state.lua; clock_tempo 120 rather than 90, the tempo the tests
-- assume). They cover every id in core/paramset.lua's system_param_ids
-- except "clock_midi_out", which norns never adds (its params are
-- clock_midi_out_1..16), so a script param with one of these ids collides
-- as it would on norns. Their actions do nothing, except clock_tempo's,
-- which sets the internal clock's tempo and calls
-- clock.tempo_change_handler like norns'. clock.add_params' three clocks
-- (crow out, MIDI clock out, external tempo) are not started: they touch no
-- script state, and clock.advance() would mostly step them.
local function add_system_params(paramset, controlspec)
  local function db(id, name, max, default)
    paramset:add_control(id, name, controlspec.new(-math.huge, max, "db", 0, default, "dB"))
  end
  paramset:add_group("LEVELS", 9)
  db("output_level", "output", 6, 0); db("input_level", "input", 6, 0); db("monitor_level", "monitor", 6, 0)
  db("engine_level", "engine", 6, 0); db("softcut_level", "softcut", 6, 0); db("tape_level", "tape", 6, 0)
  paramset:add_separator("monitoring_separator", "monitoring")
  paramset:add_option("monitor_mode", "monitor mode", {"STEREO", "MONO"}, 1)
  paramset:add_number("headphone_gain", "headphone gain", 0, 63, 40)

  paramset:add_group("REVERB", 11)
  paramset:add_option("reverb", "reverb", {"OFF", "ON"}, 2)
  db("rev_eng_input", "input engine", 18, -9); db("rev_cut_input", "input softcut", 18, -9)
  db("rev_monitor_input", "input monitor", 18, -math.huge); db("rev_tape_input", "input tape", 18, -math.huge)
  db("rev_return_level", "return level", 18, 0)
  paramset:add_control("rev_pre_delay", "pre delay", controlspec.new(20, 100, "lin", 0, 60, "ms"))
  paramset:add_control("rev_lf_fc", "lf fc", controlspec.new(50, 1000, "exp", 0, 200, "hz"))
  paramset:add_control("rev_low_time", "low time", controlspec.new(0.1, 16, "lin", 0, 6, "s"))
  paramset:add_control("rev_mid_time", "mid time", controlspec.new(0.1, 16, "lin", 0, 6, "s"))
  paramset:add_control("rev_hf_damping", "hf damping", controlspec.new(1500, 20000, "exp", 0, 6000, "hz"))

  paramset:add_group("COMPRESSOR", 8)
  paramset:add_option("compressor", "compressor", {"OFF", "ON"}, 1)
  paramset:add_control("comp_mix", "mix", controlspec.new(0, 1, "lin", 0, 1, ""))
  paramset:add_control("comp_ratio", "ratio", controlspec.new(1, 20, "lin", 0, 4, ""))
  paramset:add_control("comp_threshold", "threshold", controlspec.new(-100, 10, "db", 0, -18, "dB"))
  paramset:add_control("comp_attack", "attack", controlspec.new(1, 1000, "exp", 0, 5, "ms"))
  paramset:add_control("comp_release", "release", controlspec.new(1, 1000, "exp", 0, 50, "ms"))
  paramset:add_control("comp_pre_gain", "pre gain", controlspec.new(-20, 60, "db", 0, 0, "dB"))
  paramset:add_control("comp_post_gain", "post gain", controlspec.new(-20, 60, "db", 0, 9, "dB"))

  paramset:add_group("SOFTCUT", 3)
  db("cut_input_adc", "input adc", 18, 0); db("cut_input_eng", "input engine", 18, 0)
  db("cut_input_tape", "input tape", 18, -math.huge)

  paramset:add_group("CLOCK", 29)
  paramset:add_option("clock_source", "source", {"internal", "midi", "link", "crow"}, 1)
  paramset:add_number("clock_tempo", "tempo", 1, 300, 120)
  -- lua/core/clock.lua's clock_tempo action (link and norns.state left out)
  paramset:set_action("clock_tempo", function(bpm)
    if paramset:string("clock_source") == "internal" then clock.internal.set_tempo(bpm) end
    if clock.tempo_change_handler ~= nil then clock.tempo_change_handler(bpm) end
  end)
  paramset:add_trigger("clock_reset", "reset")
  paramset:add_separator("link_separator", "link")
  paramset:add_number("link_quantum", "link quantum", 1, 32, 4)
  paramset:add_option("link_start_stop_sync", "link start/stop sync", {"disabled", "enabled"}, 1)
  paramset:add_separator("midi_clock_out_separator", "midi clock out")
  for port = 1, 16 do
    paramset:add_binary("clock_midi_out_" .. port, port .. ". none", "toggle", 0)
    paramset:hide("clock_midi_out_" .. port)  -- no MIDI device is connected yet
  end
  paramset:add_separator("midi_clock_in_separator", "midi clock in")
  local midi_clock_in_options = { "all", "none" }
  for port = 1, 16 do table.insert(midi_clock_in_options, tostring(port)) end
  paramset:add_option("clock_midi_in", "midi clock in", midi_clock_in_options, 1)
  paramset:add_separator("crow_clock_separator", "crow")
  paramset:add_option("clock_crow_out", "crow out", {"off", "output 1", "output 2", "output 3", "output 4"}, 1)
  paramset:add_number("clock_crow_out_div", "crow out div", 1, 32, 4)
  paramset:add_number("clock_crow_in_div", "crow in div", 1, 32, 4)
  -- the ones audio.lua and clock.lua keep out of PSET files (set_save false);
  -- the reverb, compressor and softcut levels are saved
  for _, id in ipairs({ "output_level", "input_level", "monitor_level", "engine_level", "softcut_level",
    "tape_level", "monitor_mode", "headphone_gain", "reverb", "compressor", "clock_source", "clock_tempo",
    "link_quantum", "link_start_stop_sync", "clock_midi_in", "clock_crow_out", "clock_crow_out_div",
    "clock_crow_in_div" }) do
    paramset:set_save(id, false)
  end
  for port = 1, 16 do paramset:set_save("clock_midi_out_" .. port, false) end
end

local function make_params(util, controlspec)
  -- ParamSet.tSEPARATOR etc., reachable as params.tOPTION like in norns
  local ParamSet = {}
  for type_name, code in pairs(PARAM_TYPE_CODES) do
    ParamSet["t" .. type_name:upper()] = code
  end
  ParamSet.__index = ParamSet

  -- open_group counts the params still to come in the current group, like
  -- norns' ParamSet.group (groups cannot nest); last_group is that group,
  -- kept after its last param until the next param shows where it ended
  local paramset = setmetatable({ params = {}, lookup = {}, action_log = {}, open_group = 0 }, ParamSet)

  local bang

  local function new_param(args)
    -- norns prints "unknown type" and adds nothing; the stub fails loudly
    if PARAM_TYPE_CODES[args.type] == nil then
      error("stub params: unknown param type " .. tostring(args.type))
    end
    local param = { id = args.id, name = args.name or args.id, t = PARAM_TYPE_CODES[args.type],
      action = args.action or function() end, hidden = false }
    if args.type == "control" then
      param.controlspec = args.controlspec or controlspec.UNIPOLAR
      -- params/control.lua: raw 0 when the spec has no default
      param.raw = param.controlspec.default and param.controlspec:unmap(param.controlspec.default) or 0
      param.formatter = args.formatter
    elseif args.type == "number" then
      param.min = args.min or -2147483648
      param.max = args.max or 2147483647
      param.default = args.default or 0
      param.value = param.default
      param.formatter = args.formatter
      param.wrap = args.wrap and param.min ~= param.max or false
    elseif args.type == "option" then
      param.options = {}
      local count = 0
      for key, value in pairs(args.options or {}) do
        param.options[key] = value
        count = count + 1
      end
      param.count = count
      param.default = args.default or 1
      param.selected = param.default
    elseif args.type == "binary" then
      -- norns reads o.behavior before setting it, so the default is always 0
      param.default = args.default or 0
      param.value = param.default
      param.behavior = args.behavior or "trigger"
    elseif args.type == "file" then
      param.path = args.path or "-"
    elseif args.type == "text" then
      param.text = args.text or ""
    elseif args.type == "group" then
      param.n = args.n or 1
    elseif args.type == "trigger" or args.type == "separator" then
      param.value = nil
    else
      error("stub params: unsupported param type " .. tostring(args.type))
    end
    -- param objects expose the norns param methods (get/set/bang/string/delta)
    param.get = function() return ParamSet.get(paramset, param.id) end
    param.set = function(_, value, silent) return ParamSet.set(paramset, param.id, value, silent) end
    param.bang = function() bang(param) end
    param.string = function() return ParamSet.string(paramset, param.id) end
    param.delta = function(_, delta) return ParamSet.delta(paramset, param.id, delta) end
    return param
  end

  -- Group sizes. norns cannot see where a group ends (it takes the next n
  -- params), so a wrong n silently moves params in or out of it. The stub
  -- requires a group to get all n params before the next group or the end
  -- of the list (check_groups), and the param after its last one to start a
  -- new section, a separator or a group: anything else means n is too small.
  local function check_group_size(param)
    local group = paramset.last_group
    if not group then return end
    local missing = paramset.open_group
    if param.t == tGROUP and missing >= 1 then
      error(string.format("stub params: group %s has only %d of its %d params before group %s (groups cannot nest)",
        group.id, group.n - missing, group.n, param.id), 0)
    elseif missing < 1 and param.t ~= tSEPARATOR and param.t ~= tGROUP then
      error(string.format("stub params: group %s ends after %d params, but %s follows with no separator or group "
        .. "(is the group's size too small?)", group.id, group.n, tostring(param.id)), 0)
    end
  end

  local function check_groups()
    local group = paramset.last_group
    if group and paramset.open_group >= 1 then
      error(string.format("stub params: group %s has only %d of its %d params at the end of the list",
        group.id, group.n - paramset.open_group, group.n), 0)
    end
  end

  -- separators and groups may reuse their own kind's id; any other collision is an error
  local function register(param)
    check_group_size(param)
    local existing = paramset.lookup[param.id]
    if existing then
      if param.t == tSEPARATOR or param.t == tGROUP then
        if existing.t ~= param.t then
          error((param.t == tGROUP and "group" or "separator") .. " collides with param: " .. param.id)
        end
      else
        error("parameter ID collision: " .. param.id)
      end
    end
    table.insert(paramset.params, param)
    paramset.lookup[param.id] = param
    if param.t == tGROUP then
      paramset.last_group, paramset.open_group = param, param.n
    elseif paramset.open_group >= 1 then
      paramset.open_group = paramset.open_group - 1
    else
      paramset.last_group = nil
    end
    return param
  end

  function ParamSet:add(args)
    assert(args.id, "params:add requires an id")
    if args.type == "group" then
      return self:add_group(args.id, args.name, args.n)
    end
    return register(new_param(args))
  end

  -- params/separator.lua: the name defaults to the id, the id to the name
  function ParamSet:add_separator(id, name)
    local separator_name = name or id or "separator"
    register(new_param({ id = id or separator_name, name = separator_name, type = "separator" }))
  end

  function ParamSet:add_group(id, name, n)
    id = id or "group"
    local count = type(name) == "number" and name or (n or 1)
    local group_name = type(name) ~= "number" and name or id
    register(new_param({ id = id, name = group_name, type = "group", n = count }))
  end

  function ParamSet:add_number(id, name, min, max, default, formatter, wrap)
    return self:add { type = "number", id = id, name = name, min = min, max = max, default = default,
      formatter = formatter, wrap = wrap }
  end

  function ParamSet:add_option(id, name, options, default)
    return self:add { type = "option", id = id, name = name, options = options, default = default }
  end

  function ParamSet:add_control(id, name, spec, formatter)
    return self:add { type = "control", id = id, name = name, controlspec = spec, formatter = formatter }
  end

  function ParamSet:add_file(id, name, path)
    return self:add { type = "file", id = id, name = name, path = path }
  end

  function ParamSet:add_text(id, name, text)
    return self:add { type = "text", id = id, name = name, text = text }
  end

  function ParamSet:add_trigger(id, name)
    return self:add { type = "trigger", id = id, name = name }
  end

  function ParamSet:add_binary(id, name, behavior, default)
    return self:add { type = "binary", id = id, name = name, behavior = behavior, default = default }
  end

  function ParamSet:lookup_param(id)
    local param = self.lookup[id] or (type(id) == "number" and self.params[id])
    if not param then error("invalid paramset index: " .. tostring(id)) end
    return param
  end

  function ParamSet:set_action(id, func)
    self:lookup_param(id).action = func
  end

  function ParamSet:hide(id) self:lookup_param(id).hidden = true end
  function ParamSet:show(id) self:lookup_param(id).hidden = false end
  function ParamSet:visible(id) return not self:lookup_param(id).hidden end

  bang = function(param)
    if param.t == tSEPARATOR or param.t == tGROUP then return end
    if param.t == tTRIGGER then param.action(); return end
    if param.t == tBINARY and param.behavior == "trigger" then
      param.action(1)
      param.value = 0
      return
    end
    param.action(ParamSet.get(paramset, param.id))
  end

  function ParamSet:get(id)
    local param = self:lookup_param(id)
    if param.t == tCONTROL then return param.controlspec:map(param.raw) end
    if param.t == tOPTION then return param.selected end
    if param.t == tFILE then return param.path end
    if param.t == tTEXT then return param.text end
    if param.t == tGROUP then return param.n end
    if param.t == tSEPARATOR then return "" end
    return param.value
  end

  local function require_number(id, value)
    if type(value) ~= "number" then
      error("params:set(" .. id .. ") with non-number value " .. tostring(value), 3)
    end
  end

  -- each type follows its lua/core/params/*.lua set(): actions fire only on a
  -- change, except triggers (and trigger-behavior binaries), which always fire
  function ParamSet:set(id, value, silent)
    local param = self:lookup_param(id)
    local changed = false
    if param.t == tCONTROL then
      require_number(id, value)
      local raw = util.clamp(param.controlspec:unmap(value), 0, 1)
      if param.raw ~= raw then param.raw = raw; changed = true end
    elseif param.t == tNUMBER then
      require_number(id, value)
      if param.wrap then
        local range = param.max - param.min + 1
        while value > param.max do value = value - range end
        while value < param.min do value = value + range end
      end
      local clamped = util.clamp(value, param.min, param.max)
      if param.value ~= clamped then param.value = clamped; changed = true end
    elseif param.t == tOPTION then
      require_number(id, value)
      local selected = util.clamp(math.floor(value), 1, param.count)
      if param.selected ~= selected then param.selected = selected; changed = true end
    elseif param.t == tBINARY then
      if value == nil then value = 1 end
      require_number(id, value)
      if param.behavior == "trigger" then
        changed = value > 0
      else
        local state = value > 0 and 1 or 0
        if param.value ~= state then param.value = state; changed = true end
      end
    elseif param.t == tTRIGGER then
      -- norns' Trigger:set has no silent argument
      bang(param)
      return
    elseif param.t == tFILE then
      if type(value) ~= "string" then
        error("params:set(" .. id .. ") file param needs a path string, got " .. tostring(value), 2)
      end
      if param.path ~= value then param.path = value; changed = true end
    elseif param.t == tTEXT then
      if param.text ~= value then param.text = value; changed = true end
    end
    if changed and not silent then bang(param) end
  end

  -- lua/core/params/control.lua (control params only; norns has no
  -- get_raw/set_raw on the other types, so the stub errors): get_raw is the
  -- 0-1 value as stored; set_raw wraps it (a wrapping spec) or clamps it to
  -- 0-1 and stores it unrounded (get rounds through controlspec:map), firing
  -- the action on a change unless silent
  local function control_param(self, id, method)
    local param = self:lookup_param(id)
    if param.t ~= tCONTROL then
      error("params:" .. method .. "(" .. tostring(id) .. ") on a param that is not a control", 3)
    end
    return param
  end

  function ParamSet:get_raw(id)
    return control_param(self, id, "get_raw").raw
  end

  function ParamSet:set_raw(id, value, silent)
    local param = control_param(self, id, "set_raw")
    require_number(id, value)
    if param.controlspec.wrap then
      while value > 1 do value = value - 1 end
      while value < 0 do value = value + 1 end
    end
    local raw = util.clamp(value, 0, 1)
    if param.raw ~= raw then
      param.raw = raw
      if not silent then bang(param) end
    end
  end

  function ParamSet:delta(id, delta)
    local param = self:lookup_param(id)
    if param.t == tCONTROL then
      local raw = util.clamp(param.raw + delta * param.controlspec.quantum, 0, 1)
      if param.raw ~= raw then param.raw = raw; bang(param) end
    elseif param.t == tNUMBER then
      self:set(id, param.value + delta)
    elseif param.t == tOPTION then
      local step = delta < 0 and math.floor(delta) or math.ceil(delta)
      self:set(id, param.selected + step)
    elseif param.t == tBINARY then
      if param.behavior == "momentary" then
        self:set(id, delta)
      elseif param.behavior == "toggle" then
        if delta ~= 0 then self:set(id, param.value == 0 and 1 or 0) end
      elseif delta ~= 0 then
        bang(param)
      end
    end
  end

  -- each type's string() in lua/core/params/*.lua: a control without a
  -- formatter shows its value rounded to 0.01 and its units ("0.5 s",
  -- "0.25 " when there are none); a number or binary returns its value
  -- itself, a number, not a string
  function ParamSet:string(id)
    local param = self:lookup_param(id)
    if param.formatter then return param.formatter(param) end
    if param.t == tCONTROL then return util.round(self:get(id), 0.01) .. " " .. param.controlspec.units end
    if param.t == tOPTION then return param.options[param.selected] end
    if param.t == tFILE then
      if param.path == "-" then return "-" end
      return param.path:match("[^/]*$")
    end
    if param.t == tTEXT then return param.text end
    if param.t == tTRIGGER then return "" end
    if param.t == tGROUP or param.t == tSEPARATOR then return param.name end
    return param.value
  end

  -- like norns: everything but triggers (and idle trigger binaries) bangs
  function ParamSet:bang()
    for _, param in ipairs(self.params) do
      if param.t ~= tTRIGGER and not (param.t == tBINARY and param.behavior == "trigger" and param.value == 0) then
        bang(param)
      end
    end
  end

  -- lua/core/paramset.lua write/read, for absolute paths only (the stub has
  -- no norns.state for numbered PSETs). write saves every param but
  -- separators and triggers as `"id": value`; read sets them in file order,
  -- each through its own set() (so actions fire on a change unless silent),
  -- skipping trigger binaries, then calls params.action_read
  local function quote(text) return '"' .. text:gsub('"', '\\"') .. '"' end
  local function unquote(text) return (text:gsub('^"', ''):gsub('"$', ''):gsub('\\"', '"')) end

  function ParamSet:write(filename, name)
    assert(type(filename) == "string", "stub params:write supports absolute paths only")
    local file = assert(io.open(filename, "w+"))
    if name then file:write("-- " .. name .. "\n") end
    for _, param in ipairs(self.params) do
      if param.id and param.save ~= false and param.t ~= tTRIGGER and param.t ~= tSEPARATOR then
        file:write(string.format("%s: %s\n", quote(param.id), tostring(self:get(param.id))))
      end
    end
    file:close()
    if self.action_write ~= nil then self.action_write(filename, name) end
  end

  function ParamSet:read(filename, silent)
    assert(type(filename) == "string", "stub params:read supports absolute paths only")
    local file = io.open(filename, "r")
    if not file then return end
    file:close()
    local already_set = {}
    for line in io.lines(filename) do
      if line:sub(1, 2) == "--" then
        self.name = line:sub(4, -1)
      else
        local id, value = line:match('(".-")%s*:%s*(.*)')
        if id and value then
          local param = self.lookup[unquote(id)]
          if param and not already_set[param] then
            if param.t ~= tTEXT and tonumber(value) ~= nil then
              if not (param.t == tBINARY and param.behavior == "trigger") then
                param:set(tonumber(value), silent)
              end
            elseif value == "-inf" then
              param:set(-math.huge, silent)
            elseif value == "inf" then
              param:set(math.huge, silent)
            else
              param:set(value, silent)
            end
            already_set[param] = true
          end
        end
      end
    end
    if self.action_read ~= nil then self.action_read(filename, silent) end
  end

  -- lua/core/paramset.lua: a param with save false is left out of params:write
  function ParamSet:set_save(id, state) self:lookup_param(id).save = state end

  add_system_params(paramset, controlspec)
  -- the script's params start a new list: the CLOCK group ends here
  paramset.last_group = nil

  return paramset, check_groups
end

---------------------------------------------------------------------------
-- clock (lua/core/clock.lua over matron's scheduler: clocks/clock_scheduler.cc,
-- the _clock_* functions and w_handle_clock_resume in weaver.cc)
---------------------------------------------------------------------------

-- matron's scheduler compares beats with C's FLT_EPSILON (2^-23)
local FLT_EPSILON = 2 ^ -23

-- lua/core/clock.lua's scheduler modes, as clock.sleep and clock.sync yield them
local SCHEDULE_SLEEP, SCHEDULE_SYNC = 0, 1

-- matron's scheduler has NUM_CLOCK_SCHEDULER_EVENTS (clock_scheduler.h) event slots
local SCHEDULER_SLOTS = 100

-- Errors raised while the scheduler resumed a coroutine. On norns
-- w_handle_clock_resume reports them on the console (l_report) and every
-- other clock keeps running, so the stub does not raise them either: it
-- keeps them here, shared by every installed clock, until a test claims them
-- (clock.take_errors()). The harness fails a test that leaves any behind
-- (stubs.take_clock_errors()), so an error can never pass unnoticed.
stubs.clock_errors = {}

function stubs.take_clock_errors()
  local errors = stubs.clock_errors
  stubs.clock_errors = {}
  return errors
end

-- luaL_checknumber's conversion and message
local function check_number(value, position, function_name)
  local number = (type(value) == "number" or type(value) == "string") and tonumber(value) or nil
  if number == nil then
    error(string.format("bad argument #%d to '%s' (number expected, got %s)", position, function_name, type(value)), 0)
  end
  return number
end

local function make_clock(util)
  -- events[coro_id] is the coroutine's scheduler event, as matron keeps it:
  -- type (SCHEDULE_SLEEP or SCHEDULE_SYNC), ready (waiting to fire),
  -- sleep_time (seconds) or sync_beat (on the beat timeline), scheduled_at
  -- and scheduled_beat (util.time() and the beat when it was scheduled),
  -- slot (its matron event slot) and order (a count of schedulings, so a
  -- step can tell a rescheduled event from the one it found). It outlives
  -- the wake-up, so a repeated sync counts on from its beat, and goes, with
  -- its slot, when the coroutine is canceled or ends.
  -- slots[n] is the coroutine holding event slot n: clock_scheduler_find_event
  -- gives a coroutine's first wait the lowest free slot, which it keeps until
  -- clock_scheduler_clear (clock.cancel). Each scheduler tick posts the due
  -- events in slot order, so slots order the events due at the same moment
  local clock = { threads = {}, sleep_log = {}, events = {}, slots = {}, tempo = 120 }
  local next_id, schedule_order = 1, 0
  -- the internal clock's beat timeline: beat_reference.beat at
  -- beat_reference.time, then one beat per 60 / clock.tempo seconds. A tempo
  -- change (clock.internal.set_tempo) keeps the beat, as matron's internal
  -- clock does (it takes the new tempo from its next tick, 1/24 beat later)
  local beat_reference = { beat = 0, time = 0 }

  local function beats_at(time) return beat_reference.beat + (time - beat_reference.time) * clock.tempo / 60 end
  local function time_of_beat(beat) return beat_reference.time + (beat - beat_reference.beat) * 60 / clock.tempo end

  -- clock_scheduler_next_clock_beat
  local function next_clock_beat(clock_beat, sync_beat, sync_beat_offset)
    local next_beat = math.ceil((clock_beat + FLT_EPSILON) / sync_beat) * sync_beat
    next_beat = next_beat + sync_beat_offset
    while next_beat < clock_beat + FLT_EPSILON do next_beat = next_beat + sync_beat end
    return math.max(next_beat, 0)
  end

  local function free_slot()
    for slot = 1, SCHEDULER_SLOTS do
      if clock.slots[slot] == nil then return slot end
    end
    -- matron returns false and the coroutine never wakes; the stub fails loudly
    error("clock: all " .. SCHEDULER_SLOTS .. " of matron's scheduler event slots are in use", 0)
  end

  local function ready_event(coro_id, event_type)
    local event = clock.events[coro_id]
    if not event then
      event = { slot = free_slot() }
      clock.slots[event.slot] = coro_id
    end
    schedule_order = schedule_order + 1
    event.type, event.ready, event.order = event_type, true, schedule_order
    event.scheduled_at, event.scheduled_beat = util.time(), beats_at(util.time())
    clock.events[coro_id] = event
    return event
  end

  -- _clock_schedule_sleep + clock_scheduler_schedule_sleep
  local function schedule_sleep(coro_id, seconds)
    seconds = check_number(seconds, 2, "clock_schedule_sleep")
    if seconds < 0 then seconds = 0 end
    ready_event(coro_id, SCHEDULE_SLEEP).sleep_time = util.time() + seconds
  end

  -- _clock_schedule_sync + clock_scheduler_schedule_sync: a sync by the
  -- coroutine whose last wait was a sync counts from that sync's beat
  -- (clock_scheduler.cc:171-173), so a late wake-up does not skip a beat
  local function schedule_sync(coro_id, sync_beat, offset)
    sync_beat = check_number(sync_beat, 2, "clock_schedule_sync")
    offset = offset == nil and 0 or check_number(offset, 3, "clock_schedule_sync")
    if sync_beat <= 0 then error(string.format("invalid sync beat: %f", sync_beat), 0) end
    local previous = clock.events[coro_id]
    local from = (previous and previous.type == SCHEDULE_SYNC) and previous.sync_beat or beats_at(util.time())
    ready_event(coro_id, SCHEDULE_SYNC).sync_beat = next_clock_beat(from, sync_beat, offset)
  end

  -- lua/core/clock.lua's clock.resume. A coroutine canceled from inside that
  -- then sleeps or syncs is scheduled all the same (the yield comes after
  -- the cancel), so its wake-up resumes a coroutine that is no longer in
  -- clock.threads: coroutine.resume(nil) raises, as on norns
  local function resume(coro_id, ...)
    local coro = clock.threads[coro_id]
    local result, mode, time, offset = coroutine.resume(coro, ...)
    if coroutine.status(coro) == "dead" then
      if result then clock.cancel(coro_id) else error(mode, 0) end
    elseif result and mode ~= nil then
      local mode_name = (mode == SCHEDULE_SLEEP and "sleep") or (mode == SCHEDULE_SYNC and "sync") or tostring(mode)
      table.insert(clock.sleep_log, { id = coro_id, mode = mode_name, amount = time, offset = offset })
      if mode == SCHEDULE_SLEEP then
        schedule_sleep(coro_id, time)
      elseif mode == SCHEDULE_SYNC then
        schedule_sync(coro_id, time, offset)
      else
        error("invalid clock scheduler mode", 0)
      end
    end
  end

  function clock.run(func, ...)
    local coro = coroutine.create(func)
    local coro_id = next_id
    next_id = next_id + 1
    clock.threads[coro_id] = coro
    resume(coro_id, ...)
    return coro_id
  end

  -- _clock_cancel (luaL_checkinteger, then clock_scheduler_clear)
  function clock.cancel(coro_id)
    if check_number(coro_id, 1, "clock_cancel") % 1 ~= 0 then
      error("bad argument #1 to 'clock_cancel' (number has no integer representation)", 0)
    end
    local event = clock.events[coro_id]
    if event then clock.slots[event.slot] = nil end
    clock.events[coro_id] = nil
    clock.threads[coro_id] = nil
  end

  function clock.sleep(...)
    return coroutine.yield(SCHEDULE_SLEEP, ...)
  end

  function clock.sync(...)
    return coroutine.yield(SCHEDULE_SYNC, ...)
  end

  -- lua/core/clock.lua: static callback run when clock_tempo is set
  clock.tempo_change_handler = nil

  -- the internal clock source (the clock_tempo param's action sets its tempo)
  clock.internal = {}
  function clock.internal.set_tempo(bpm)
    beat_reference.beat, beat_reference.time = beats_at(util.time()), util.time()
    clock.tempo = bpm
  end

  function clock.get_tempo() return clock.tempo end
  function clock.get_beat_sec() return 60.0 / clock.get_tempo() end
  function clock.get_beats() return beats_at(util.time()) end

  -- When the scheduler fires an event: a sleep at its wake time, a sync when
  -- the beat reaches its beat (at the current tempo), and never before it
  -- was scheduled (a sync counted from an old beat fires at once)
  local function fire_time(event)
    local due = event.type == SCHEDULE_SLEEP and event.sleep_time or time_of_beat(event.sync_beat)
    return math.max(due, event.scheduled_at)
  end

  -- At its fire time a sleep is due (clock_time >= sleep time), but a sync
  -- only once the beat is past its beat (clock_beat > sync beat), so at an
  -- equal time a sync comes after a sleep: rank 1. A sync whose beat had
  -- already passed when it was scheduled is due at once: rank 0
  local function fire_rank(event)
    return (event.type == SCHEDULE_SYNC and event.sync_beat >= event.scheduled_beat) and 1 or 0
  end

  -- the ready events in the order the scheduler fires them: by fire time,
  -- a sleep before a sync at the same time, then by event slot
  local function ready_events()
    local list = {}
    for coro_id, event in pairs(clock.events) do
      if event.ready then
        table.insert(list, { id = coro_id, event = event, order = event.order, time = fire_time(event),
          rank = fire_rank(event), slot = event.slot })
      end
    end
    table.sort(list, function(left, right)
      if left.time ~= right.time then return left.time < right.time end
      if left.rank ~= right.rank then return left.rank < right.rank end
      return left.slot < right.slot
    end)
    return list
  end

  -- Whether the event an entry found is still the one waiting (not
  -- canceled, fired or rescheduled since)
  local function still_waiting(entry)
    return clock.events[entry.id] == entry.event and entry.event.ready and entry.event.order == entry.order
  end

  -- The scheduler fires an event: w_handle_clock_resume calls clock.resume
  -- with the clock's time in seconds (a sleep) or in beats (a sync) that the
  -- tick posted it with: clock_time and clock_beat, sampled once per tick
  -- before any coroutine runs (clock_scheduler_tick_thread_run). advance()
  -- passes its step's `tick` ({time, beat}, sampled at the step's start, so
  -- a tempo change by an earlier resume in the step cannot move it).
  -- run_for and advance_until fire each event at its own wake-up, so their
  -- tick is the event's: the time or beat it waited for, or the one it was
  -- scheduled at if that was later (taken from the event, not from a fire
  -- time worked out earlier). An error is reported, not raised
  local function fire(entry, tick)
    local event = entry.event
    event.ready = false
    local value
    if event.type == SCHEDULE_SYNC then
      value = tick and tick.beat or math.max(event.sync_beat, event.scheduled_beat)
    else
      value = tick and tick.time or math.max(event.sleep_time, event.scheduled_at)
    end
    local ok, message = pcall(resume, entry.id, value)
    if not ok then table.insert(stubs.clock_errors, tostring(message)) end
  end

  -- Test helper: claim the errors the scheduler's resumes raised (from every
  -- installed clock), so the harness does not fail the test for them
  clock.take_errors = stubs.take_clock_errors

  -- Test helper: one scheduler step, a matron tick at the first pending
  -- event's fire time. util.time() moves there (never back); the events due
  -- then are fixed before any of them runs, as the tick posts them all at
  -- once with the time and beat it sampled (an overdue event resumes with
  -- the step's, not its own), and fire in slot order: every one whose fire
  -- time has passed, and those at the step's time of the first one's rank (a sleep at the step's
  -- time leaves a sync at that time to the next step, at the same time).
  -- Events scheduled during the step wait for the next one; one canceled or
  -- rescheduled by an earlier one in the step is skipped
  function clock.advance()
    local pending = ready_events()
    local first = pending[1]
    if not first then return end
    local step_time = math.max(util.time(), first.time)
    local rank_limit = first.time == step_time and first.rank or 0
    util.stub_now = step_time
    local due = {}
    for _, entry in ipairs(pending) do
      if entry.time < step_time or (entry.time == step_time and entry.rank <= rank_limit) then
        table.insert(due, entry)
      end
    end
    table.sort(due, function(left, right) return left.slot < right.slot end)
    local tick = { time = step_time, beat = beats_at(step_time) }
    for _, entry in ipairs(due) do
      if still_waiting(entry) then fire(entry, tick) end
    end
  end

  -- Test helper: run the scheduler, one event at a time in firing order,
  -- until the coroutine coro_id has been resumed once (every clock due
  -- before it runs first, as on norns). It must be waiting; it stops with
  -- an error as soon as another clock cancels it
  function clock.advance_until(coro_id)
    local function failure(why) error("clock.advance_until: coroutine " .. tostring(coro_id) .. " " .. why, 3) end
    local target = clock.events[coro_id]
    if not (target and target.ready) then
      failure(next(ready_events()) and "is not waiting" or "is not waiting: nothing is pending")
    end
    local waiting = { id = coro_id, event = target, order = target.order }
    for _ = 1, 1e6 do
      local entry = ready_events()[1]
      util.stub_now = math.max(util.time(), entry.time)
      fire(entry)
      if entry.id == coro_id and entry.order == waiting.order then return end
      if not still_waiting(waiting) then failure("was canceled (or rescheduled) before it woke") end
    end
    failure("never woke")
  end

  -- Test helper: run the scheduler for `seconds`. Each event fires in turn,
  -- and its coroutine runs `latency` seconds later (default 0; never before
  -- util.time(), as one coroutine runs at a time), with util.time() at that
  -- moment, so a clock that sleeps many short steps falls behind one that
  -- sleeps once, as on norns. Coroutines started or rescheduled meanwhile
  -- join in. util.time() ends at the start time plus `seconds`
  function clock.run_for(seconds, latency)
    latency = latency or 0
    local end_time = util.time() + seconds
    local resumes = 0
    while true do
      local entry = ready_events()[1]
      if not entry then break end
      local run_at = math.max(util.time(), entry.time + latency)
      if run_at > end_time then break end
      resumes = resumes + 1
      if resumes > 1e6 then error("clock.run_for: a coroutine never sleeps", 2) end
      util.stub_now = run_at
      fire(entry)
    end
    util.stub_now = end_time
  end

  function clock.pending_count()
    local count = 0
    for _ in pairs(clock.threads) do count = count + 1 end
    return count
  end

  return clock
end

---------------------------------------------------------------------------
-- metro
---------------------------------------------------------------------------

local function make_metro()
  local metro = { all = {} }
  function metro.init()
    local timer = { time = 1, running = false, event = nil }
    function timer:start() self.running = true end
    function timer:stop() self.running = false end
    table.insert(metro.all, timer)
    return timer
  end
  return metro
end

---------------------------------------------------------------------------
-- grid / arc (vports + devices, mirroring lua/core/grid.lua and arc.lua)
---------------------------------------------------------------------------

local function make_led_device(cols, rows)
  local device = { cols = cols, rows = rows, leds = {}, refresh_count = 0, port = nil }
  function device:all(level)
    for x = 1, self.cols do
      self.leds[x] = {}
      for y = 1, self.rows do self.leds[x][y] = level end
    end
  end
  function device:led(x, y, level)
    if x < 1 or x > self.cols or y < 1 or y > self.rows then
      error(string.format("grid led out of bounds: %d,%d on %dx%d", x, y, self.cols, self.rows))
    end
    if type(level) ~= "number" or level < 0 or level > 15 then
      error("grid led level out of range: " .. tostring(level))
    end
    self.leds[x] = self.leds[x] or {}
    self.leds[x][y] = level
  end
  function device:refresh() self.refresh_count = self.refresh_count + 1 end
  function device:get_led(x, y) return (self.leds[x] and self.leds[x][y]) or 0 end
  device:all(0)
  return device
end

local function wrap_method(method)
  return function(self, ...)
    if self.device then return self.device[method](self.device, ...) end
  end
end

local function make_grid()
  local grid = { vports = {}, devices = {} }
  for port = 1, 4 do
    grid.vports[port] = {
      name = "none", device = nil, key = nil, cols = 0, rows = 0,
      led = wrap_method("led"), all = wrap_method("all"), refresh = wrap_method("refresh"),
    }
  end
  function grid.connect(port) return grid.vports[port or 1] end
  function grid.add(device) end
  function grid.remove(device) end

  -- test helper: plug a device of the given size into a port
  function grid.plug(port, cols, rows)
    local device = make_led_device(cols, rows)
    device.port = port
    grid.devices[port] = device
    local vport = grid.vports[port]
    vport.device = device
    vport.cols = cols
    vport.rows = rows
    vport.name = "grid " .. port
    if grid.add then grid.add(device) end
    return device
  end

  function grid.unplug(port)
    local device = grid.devices[port]
    if not device then return end
    if grid.remove then grid.remove(device) end
    grid.devices[port] = nil
    local vport = grid.vports[port]
    vport.device = nil
    vport.cols = 0
    vport.rows = 0
  end

  -- test helper: deliver a key event the way _norns.grid.key does
  function grid.press(port, x, y, z)
    local device = grid.devices[port]
    assert(device, "no grid on port " .. port)
    if device.key then device.key(x, y, z) end
    if device.port and grid.vports[device.port].key then
      grid.vports[device.port].key(x, y, z)
    end
  end

  return grid
end

local function make_arc()
  local util = make_util()
  local arc = { vports = {}, devices = {} }
  for port = 1, 4 do
    arc.vports[port] = {
      name = "none", device = nil, delta = nil, key = nil,
      led = wrap_method("led"), all = wrap_method("all"), refresh = wrap_method("refresh"),
      segment = wrap_method("segment"),
    }
  end
  function arc.connect(port) return arc.vports[port or 1] end
  function arc.add(device) end
  function arc.remove(device) end

  function arc.plug(port)
    -- rings[ring][x] is matron's LED buffer (md->data), 4 rings of 64 LEDs;
    -- segments[ring] records the ring's last segment() call (from, to,
    -- level, rel and the 64 levels it computed) for the ring tests
    local device = { port = port, rings = {}, segments = {}, refresh_count = 0, cleared = 0 }
    for ring = 1, 4 do
      device.rings[ring] = {}
      for x = 1, 64 do device.rings[ring][x] = 0 end
    end
    local function check_integer(value, what)
      if not is_integer(value) then error("arc " .. what .. " must be an integer, got " .. tostring(value), 3) end
    end
    -- Arc:led -> _arc_set_led (luaL_checkinteger) -> dev_monome_arc_set_led:
    -- rel adds to the LED's level, clamped to 0..15; an absolute level is
    -- stored as it is. matron masks a ring or LED outside 1..4 / 1..64 into
    -- range; the stub fails instead, and like the grid stub rejects an
    -- absolute level outside 0..15
    function device:led(ring, x, level, rel)
      check_integer(ring, "ring"); check_integer(x, "LED"); check_integer(level, "level")
      if ring < 1 or ring > 4 or x < 1 or x > 64 then
        error(string.format("arc led out of bounds: ring %d, LED %d", ring, x), 2)
      end
      if rel then
        self.rings[ring][x] = math.min(15, math.max(0, self.rings[ring][x] + level))
      elseif level < 0 or level > 15 then
        error("arc led level out of range: " .. tostring(level), 2)
      else
        self.rings[ring][x] = level
      end
    end
    -- Arc:all -> dev_monome_all_led: rel adds to every level, clamped to
    -- 0..15; an absolute level outside 0..15 fails, as in led()
    function device:all(level, rel)
      check_integer(level, "level")
      if not rel and (level < 0 or level > 15) then error("arc all level out of range: " .. tostring(level), 2) end
      self.cleared = self.cleared + 1
      self.segments = {}
      for ring = 1, 4 do
        for x = 1, 64 do
          self.rings[ring][x] = rel and math.min(15, math.max(0, self.rings[ring][x] + level)) or level
        end
      end
    end
    function device:get_led(ring, x) return self.rings[ring][x] end
    -- lua/core/arc.lua's Arc:segment, line for line: angles reduce modulo
    -- 2*pi, each of the 64 LEDs gets round(overlap / LED width * level) and
    -- is set through led() with rel, so a full turn (0 -> 2*pi) lights nothing
    function device:segment(ring, from, to, level, rel)
      local tau = math.pi * 2

      local function overlap(a, b, c, d)
        if a > b then
          return overlap(a, tau, c, d) + overlap(0, b, c, d)
        elseif c > d then
          return overlap(a, b, c, tau) + overlap(a, b, 0, d)
        else
          return math.max(0, math.min(b, d) - math.max(a, c))
        end
      end

      local function overlap_segments(a, b, c, d)
        a = a % tau
        b = b % tau
        c = c % tau
        d = d % tau

        return overlap(a, b, c, d)
      end

      local m = {}
      local sl = tau / 64

      for i = 1, 64 do
        local sa = tau / 64 * (i - 1)
        local sb = tau / 64 * i

        local o = overlap_segments(from, to, sa, sb)
        m[i] = util.round(o / sl * level)
        self:led(ring, i, m[i], rel)
      end
      self.segments[ring] = { from = from, to = to, level = level, rel = rel, leds = m }
    end
    function device:refresh() self.refresh_count = self.refresh_count + 1 end
    arc.devices[port] = device
    arc.vports[port].device = device
    if arc.add then arc.add(device) end
    return device
  end

  function arc.unplug(port)
    local device = arc.devices[port]
    if not device then return end
    if arc.remove then arc.remove(device) end
    arc.devices[port] = nil
    arc.vports[port].device = nil
  end

  function arc.turn(port, ring, delta)
    local device = arc.devices[port]
    if device.delta then device.delta(ring, delta) end
    if device.port and arc.vports[device.port].delta then arc.vports[device.port].delta(ring, delta) end
  end

  function arc.push(port, button, state)
    local device = arc.devices[port]
    if device.key then device.key(button, state) end
    if device.port and arc.vports[device.port].key then arc.vports[device.port].key(button, state) end
  end

  return arc
end

---------------------------------------------------------------------------
-- encoders (norns.enc.accel/sens, mirroring lua/core/encoders.lua)
---------------------------------------------------------------------------

local function make_encoders()
  -- lua/core/script.lua resets every script to accel on, sensitivity 2
  local encoders = { accel = { true, true, true }, sens = { 2, 2, 2 }, tick = { 0, 0, 0 } }
  local api = {}
  function api.accel(n, enabled)
    for k = 1, 3 do
      if n == 0 or n == k then encoders.accel[k] = enabled; encoders.tick[k] = 0 end
    end
  end
  function api.sens(n, sensitivity)
    for k = 1, 3 do
      if n == 0 or n == k then
        encoders.sens[k] = math.min(16, math.max(1, sensitivity)); encoders.tick[k] = 0
      end
    end
  end
  encoders.api = api

  -- test helper: one hardware encoder event the way encoders.process_with_accel
  -- handles it; `interval` is the time since the previous event on that encoder
  function encoders.deliver(n, delta, interval)
    if encoders.accel[n] then
      if interval < 0.005 then delta = delta * 6
      elseif interval < 0.01 then delta = delta * 4
      elseif interval < 0.02 then delta = delta * 3
      elseif interval < 0.03 then delta = delta * 2
      end
    end
    encoders.tick[n] = encoders.tick[n] + delta
    if math.abs(encoders.tick[n]) >= encoders.sens[n] then
      local value = encoders.tick[n] / encoders.sens[n]
      value = (value > 0) and math.floor(value) or math.ceil(value)
      _G.enc(n, value)
      encoders.tick[n] = math.fmod(encoders.tick[n], encoders.sens[n])
    end
  end

  return encoders
end

---------------------------------------------------------------------------
-- screen / UI
---------------------------------------------------------------------------

-- Approximate advance of norns' default font (04B_03 at size 8): capitals
-- about 6 px, brackets/colon/period about 4 px, everything else 5 px. The
-- stub's screen.text_extents and the layout tests both use it. It counts
-- UTF-8 characters, not bytes, so a multi-byte glyph such as "●" is one.
function stubs.text_width(text)
  local width = 0
  for char in text:gmatch("[^\128-\191][\128-\191]*") do
    if char:match("%u") then
      width = width + 6
    elseif char:match("[%[%]%.:]") then
      width = width + 4
    else
      width = width + 5
    end
  end
  return width
end

local function make_screen()
  local screen = { texts = {}, lines = {}, rects = {}, cursor_x = 0, cursor_y = 0, current_level = 15 }
  function screen.clear() screen.texts = {}; screen.lines = {}; screen.rects = {} end
  function screen.level(level) screen.current_level = level end
  function screen.move(x, y) screen.cursor_x = x; screen.cursor_y = y end
  -- each drawn string is recorded with its position, alignment and level
  local function record_text(str, align)
    table.insert(screen.texts, { x = screen.cursor_x, y = screen.cursor_y, text = tostring(str),
      align = align, level = screen.current_level })
  end
  function screen.text(str) record_text(str, "left") end
  function screen.text_right(str) record_text(str, "right") end
  function screen.text_center(str) record_text(str, "center") end
  -- lua/core/screen.lua: text_extents(str) returns width, height
  function screen.text_extents(str) return stubs.text_width(tostring(str)), 8 end
  -- lines and rectangles are recorded too (from/to points, x/y/w/h), so
  -- tests can check that drawings stay in their area
  function screen.line(x, y)
    table.insert(screen.lines, { x1 = screen.cursor_x, y1 = screen.cursor_y, x2 = x, y2 = y,
      level = screen.current_level })
    screen.cursor_x = x; screen.cursor_y = y
  end
  function screen.rect(x, y, w, h)
    table.insert(screen.rects, { x = x, y = y, w = w, h = h, level = screen.current_level })
  end
  function screen.stroke() end
  function screen.fill() end
  function screen.update() end
  function screen.font_size() end
  function screen.font_face() end
  return screen
end

local function make_ui(util, screen)
  local UI = { ScrollingList = {} }
  UI.ScrollingList.__index = UI.ScrollingList
  function UI.ScrollingList.new(x, y, index, entries)
    assert(x and y and index and entries, "UI.ScrollingList.new requires all parameters")
    return setmetatable({ x = x, y = y, index = index, entries = entries,
      num_visible = 5, num_above_selected = 1, text_align = "left", active = true }, UI.ScrollingList)
  end
  -- lua/lib/ui.lua's ScrollingList:redraw, unchanged: row i at
  -- y + 5 + (i - 1) * 11, the selected entry at level 15 and the rest at 3,
  -- an empty string where the scroll offset runs past either end
  function UI.ScrollingList:redraw()
    local num_entries = #self.entries
    local scroll_offset = self.index - 1 - math.max(self.index - (num_entries - 2), 0)
    scroll_offset = scroll_offset - util.linlin(num_entries - self.num_above_selected, num_entries,
      self.num_above_selected, 0, self.index - 1) -- For end of list

    for i = 1, self.num_visible do
      if self.active and self.index == i + scroll_offset then screen.level(15)
      else screen.level(3) end
      screen.move(self.x, self.y + 5 + (i - 1) * 11)
      local entry = self.entries[i + scroll_offset] or ""
      if self.text_align == "center" then
        screen.text_center(entry)
      elseif self.text_align == "right" then
        screen.text_right(entry)
      else
        screen.text(entry)
      end
    end
    screen.fill()
  end
  return UI
end

---------------------------------------------------------------------------
-- tab: lib/tabutil.lua's tab.save and tab.load, ported unchanged (norns,
-- GPL-3.0), so scene and buffer files are written and read as on norns:
-- tabutil's "-- Table: {n}" layout, shared tables saved once, numbers
-- written with tostring (%.14g: they lose precision as on norns), functions
-- and userdata skipped, and the loaded file run unprotected
---------------------------------------------------------------------------

local function make_tab()
  local tab = {}

  function tab.save(tbl, filename)
    local charS, charE = "   ", "\n"
    local file, err = io.open(filename, "wb")
    if err then return err end

    -- initiate variables for save procedure
    local tables, lookup = { tbl }, { [tbl] = 1 }
    file:write("return {"..charE)

    for idx, t in ipairs(tables) do
      file:write("-- Table: {"..idx.."}"..charE)
      file:write("{"..charE)
      local thandled = {}

      for i, v in ipairs(t) do
        thandled[i] = true
        local stype = type(v)
        -- only handle value
        if stype == "table" then
          if not lookup[v] then
            table.insert(tables, v)
            lookup[v] = #tables
          end
          file:write(charS.."{"..lookup[v].."},"..charE)
        elseif stype == "string" then
          file:write(charS..string.format("%q", v)..","..charE)
        elseif stype == "number" then
          file:write(charS..tostring(v)..","..charE)
        elseif stype == "boolean" then
          file:write(charS..tostring(v)..","..charE)
        end
      end

      for i, v in pairs(t) do
        -- escape handled values
        if (not thandled[i]) then

          local str = ""
          local stype = type(i)
          -- handle index
          if stype == "table" then
            if not lookup[i] then
               table.insert(tables, i)
               lookup[i] = #tables
            end
            str = charS.."[{"..lookup[i].."}]="
          elseif stype == "string" then
            str = charS.."["..string.format("%q", i).."]="
          elseif stype == "number" then
            str = charS.."["..tostring(i).."]="
          elseif stype == "boolean" then
            str = charS.."["..tostring(i).."]="
          end

          if str ~= "" then
            stype = type(v)
            -- handle value
            if stype == "table" then
              if not lookup[v] then
                table.insert(tables, v)
                lookup[v] = #tables
              end
              file:write(str.."{"..lookup[v].."},"..charE)
            elseif stype == "string" then
              file:write(str..string.format("%q", v)..","..charE)
            elseif stype == "number" then
              file:write(str..tostring(v)..","..charE)
            elseif stype == "boolean" then
              file:write(str..tostring(v)..","..charE)
            end
          end
        end
      end
      file:write("},"..charE)
    end
    file:write("}")
    file:close()
  end

  -- `_` is an unset global here, as in tabutil: the first result is nil
  function tab.load(sfile)
    local ftables,err = loadfile(sfile)
    if err then return _, err end
    local tables = ftables()
    if tables ~= nil then
      for idx = 1, #tables do
        local tolinki = {}
        for i, v in pairs(tables[idx]) do
          if type(v) == "table" then
            tables[idx][i] = tables[v[1]]
          end
          if type(i) == "table" and tables[i[1]] then
            table.insert(tolinki, { i, tables[i[1]] })
          end
        end
        -- link indices
        for _, v in ipairs(tolinki) do
          tables[idx][v[2]], tables[idx][v[1]] =  tables[idx][v[1]], nil
        end
      end
      return tables[1]
    else
      return nil
    end
  end

  return tab
end

---------------------------------------------------------------------------
-- poll (lua/core/poll.lua)
---------------------------------------------------------------------------

-- polls CroneAudioContext registers before any engine loads
local SYSTEM_POLLS = { "cpu_peak", "cpu_avg", "amp_in_l", "amp_in_r", "amp_out_l", "amp_out_r",
  "pitch_in_l", "pitch_in_r" }

local function make_poll(engine_polls)
  local poll = { polls = {} }
  local function register(name)
    local entry = { name = name, callback = nil, time = 0.25, running = false }
    function entry:start() self.running = true end
    function entry:stop() self.running = false end
    poll.polls[name] = entry
  end
  for _, name in ipairs(SYSTEM_POLLS) do register(name) end
  for _, name in ipairs(engine_polls or {}) do register(name) end

  -- like norns: only registered polls exist; anything else returns nil
  function poll.set(name, callback)
    local entry = poll.polls[name]
    if entry then entry.callback = callback end
    return entry
  end

  -- test helper: deliver a value the way a running poll does
  function poll.fire(name, value)
    local entry = poll.polls[name]
    assert(entry, "no poll named " .. tostring(name))
    if entry.running and entry.callback then entry.callback(value) end
  end

  return poll
end

---------------------------------------------------------------------------
-- fileselect (lib/fileselect.lua): records the request instead of a menu.
-- A module, not a global: scripts get it from require "fileselect", as
-- norns' own files do. From play mode the real fs.enter calls
-- norns.menu.init(), whose _menu.set_mode(false) puts the script's redraw
-- back in the global `redraw` and calls it; fs.exit does the same before it
-- calls the callback with the chosen path or "cancel". The stub calls
-- norns.menu.init() there too (so a script's _menu.set_mode wrapper runs)
-- and makes those redraw() calls, but does not reroute key/enc (tests keep
-- pressing the script's keys while the selector is "open"). From the menu
-- (a PARAMS file param) neither calls init, as norns.menu.set is used
-- instead. fs.redraw draws the file
-- list; the stub counts the calls in `redraws` and draws nothing. Like
-- fs.enter, enter stores the callback in `callback`: norns has one selector,
-- so a second enter (from a PARAMS file param) replaces the first's.
---------------------------------------------------------------------------

local function make_fileselect()
  local fileselect = { last = nil, redraws = 0 }
  local entered = false  -- tests reset `last`; the real module keeps its list
  local function menu_init_redraw()
    if norns.menu.status() then return end
    norns.menu.init()
    if type(redraw) == "function" then redraw() end
  end
  function fileselect.redraw()
    -- the real one draws fs.list, which fs.enter sets up
    assert(entered, "fileselect.redraw before fileselect.enter")
    fileselect.redraws = fileselect.redraws + 1
  end
  function fileselect.enter(folder, callback, filter)
    entered = true
    fileselect.last = { folder = folder, callback = callback, filter = filter }
    fileselect.callback = callback
    menu_init_redraw()
    fileselect.redraw()
  end
  -- Test helper: close the selector the way fs.exit does, with `path`
  -- chosen, or canceled when path is nil
  function fileselect.close(path)
    local request = assert(fileselect.last, "the file selector is not open")
    menu_init_redraw()
    request.callback(path or "cancel")
  end
  return fileselect
end

-- The script's folder: the repo root, the folder above this file's
local script_folder = (debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or ".") .. "/.."

-- lua/core/startup.lua's include(file): runs <folder><file>.lua with dofile
-- for the first of the script's folder (norns.state.path), _path.code and
-- _path.extn that holds it, so every call runs the file again (a module
-- included twice is two copies), and raises "MISSING INCLUDE" when none
-- does. The stub looks in the script's folder only. module_sources[file],
-- when set, is run in place of the file's text, under the file's chunk name
local function make_include(module_sources)
  return function(file)
    local path = script_folder .. "/" .. file .. ".lua"
    local source = module_sources[file]
    if source then
      print("including " .. path)
      return assert(load(source, "@" .. path))()
    end
    local handle = io.open(path, "r")
    if handle then
      handle:close()
      print("including " .. path)
      return dofile(path)
    end
    print("### MISSING INCLUDE: " .. file)
    error("MISSING INCLUDE: " .. file, 2)
  end
end

---------------------------------------------------------------------------
-- install / reset
---------------------------------------------------------------------------

-- Installs fresh stubs as globals. Returns a context table with handles to
-- the recorders and helpers.
function stubs.install(options)
  local util = make_util()
  local controlspec = make_controlspec(util)
  local context = {
    signatures = options.signatures,
    engine_calls = {},
    printed = {},
  }

  local argument_checks = engine_argument_checks(assert(options.engine_spec, "stubs.install needs engine_spec"),
    function(param_id) return context.params.lookup[param_id] end)
  for command_name in pairs(context.signatures) do
    assert(argument_checks[command_name], "the engine stub has no argument check for engine." .. command_name)
  end

  local engine = { name = nil }
  setmetatable(engine, {
    __index = function(_, command_name)
      return function(...)
        local args = { ... }
        local count = select("#", ...)
        local signature = context.signatures[command_name]
        if not signature then
          error("engine." .. command_name .. " has no matching addCommand in Engine_Strata.sc", 2)
        end
        if count ~= #signature then
          error(string.format("engine.%s called with %d args, signature \"%s\" expects %d",
            command_name, count, signature, #signature), 2)
        end
        for index = 1, #signature do
          local type_code = signature:sub(index, index)
          local value = args[index]
          if type_code == "i" and not is_integer(value) then
            error(string.format("engine.%s arg %d must be an integer, got %s", command_name, index, tostring(value)), 2)
          elseif type_code == "f" and type(value) ~= "number" then
            error(string.format("engine.%s arg %d must be a number, got %s", command_name, index, tostring(value)), 2)
          elseif type_code == "s" and type(value) ~= "string" then
            error(string.format("engine.%s arg %d must be a string, got %s", command_name, index, tostring(value)), 2)
          end
        end
        local problem = argument_checks[command_name](args)
        if problem then error("engine." .. command_name .. ": " .. problem, 2) end
        table.insert(context.engine_calls, { name = command_name, args = args })
      end
    end,
  })

  context.util = util
  context.controlspec = controlspec
  -- context.check_param_groups(): every group has all of its params (the
  -- harness calls it after init())
  context.params, context.check_param_groups = make_params(util, controlspec)
  context.clock = make_clock(util)
  function context.set_time(seconds) util.stub_now = seconds end
  context.metro = make_metro()
  context.grid = make_grid()
  context.arc = make_arc()
  context.screen = make_screen()
  context.UI = make_ui(util, context.screen)
  context.tab = make_tab()
  context.engine = engine
  context.midi = require("stub_midi")()
  context.lfo = {}
  context.lfo.library = require("stub_lfo")(context.lfo)
  context.fileselect = make_fileselect()
  context.polls = make_poll(options.engine_polls)
  context.musicutil = {
    -- same formula as lib/musicutil.lua
    note_num_to_freq = function(note_num) return 13.75 * (2 ^ ((note_num - 9) / 12)) end,
  }
  -- _menu.mode is true while the norns menu (K1) owns the keys and screen;
  -- in play mode _menu.key and norns.encoders.callback route the hardware
  -- keys and encoders to the script (set_mode(false) copies them from the
  -- globals key and enc)
  context.menu = { rebuilds = 0, mode = false, key = nil }
  context.encoders = make_encoders()
  function context.menu.rebuild_params() context.menu.rebuilds = context.menu.rebuilds + 1 end
  -- lua/core/menu.lua: _menu.set_mode(true) opens the menu (K1, a script
  -- error), set_mode(false) returns to the script. The real one also swaps
  -- the key/enc/redraw handlers; the stub tracks the mode and, as play mode
  -- starts, records the routed handlers (_menu.key, norns.encoders.callback)
  function context.menu.set_mode(mode)
    context.menu.mode = mode
    if mode == false then
      context.menu.key = rawget(_G, "key")
      norns.encoders.callback = rawget(_G, "enc")
    end
  end

  _G.engine = engine
  -- options.module_sources: { ["lib/x"] = source } is run for include("lib/x")
  _G.include = make_include(options.module_sources or {})
  _G.util = util
  _G.controlspec = controlspec
  _G.params = context.params
  _G.clock = context.clock
  _G.metro = context.metro
  _G.grid = context.grid
  _G.arc = context.arc
  _G.screen = context.screen
  _G.tab = context.tab
  _G.midi = context.midi
  _G.fileselect = nil  -- lib/fileselect.lua is a module (package.preload below)
  _G.poll = context.polls
  _G._menu = context.menu
  _G.norns = { state = {}, enc = context.encoders.api, encoders = { callback = nil },
    -- lua/core/menu.lua: norns.menu.status() returns _menu.mode, and
    -- norns.menu.init() (used by fileselect) calls _menu.set_mode(_menu.mode)
    menu = { status = function() return context.menu.mode end,
      init = function() _menu.set_mode(_menu.mode) end } }
  _G._path = { data = options.data_dir, audio = options.data_dir .. "audio/" }
  util.make_dir(_G._path.audio)
  package.loaded["ui"] = context.UI
  package.preload["ui"] = function() return context.UI end
  package.loaded["musicutil"] = nil
  package.preload["musicutil"] = function() return context.musicutil end
  package.loaded["lfo"] = nil
  package.preload["lfo"] = function() return context.lfo.library end
  package.loaded["fileselect"] = nil
  package.preload["fileselect"] = function() return context.fileselect end

  if options.quiet then
    _G.print = function(...)
      local parts = {}
      for index = 1, select("#", ...) do parts[index] = tostring((select(index, ...))) end
      table.insert(context.printed, table.concat(parts, "\t"))
    end
  end

  function context.clear_engine_calls() context.engine_calls = {} end
  function context.calls_named(name)
    local matches = {}
    for _, call in ipairs(context.engine_calls) do
      if call.name == name then table.insert(matches, call) end
    end
    return matches
  end

  return context
end

stubs.shallow_copy = shallow_copy
stubs.make_tab = make_tab

return stubs
