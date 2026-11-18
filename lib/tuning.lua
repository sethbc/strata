-- lib/tuning.lua
-- The one tuning (3.8, design §6), S.lib.tuning: a name, its tones in
-- cents above the first (ascending, the first 0) and its period in cents.
-- Every MIDI key, snap, degree and chord goes through it: pitch_of_key,
-- snap, step, allowed and chord. Two text params hold it (tuning_name,
-- shown, and tuning_tones, hidden: the period, then each tone), PSET lines
-- before every voice; tuning_tones' action applies it and alone sends
-- setTuning and setTuningTone. The built-ins and the player's Scala files
-- (data/strata/tunings/, read as text, never run). See
-- docs/notes/lua/tuning.md.

return function(S)
  local M = {}

  local LOG2 = math.log(2)
  -- A whole number as an integer (Lua 5.3 prints 4.0 otherwise), so twelve
  -- equal steps give 3.7's values exactly as 3.7 gave them
  local function tidy(value)
    if value == math.floor(value) then return math.floor(value) end
    return value
  end
  local function ratio_cents(numerator, denominator) return 1200 * math.log(numerator / denominator) / LOG2 end

  -- The tuning's constants. The first ten mirror the engine's
  -- (StrataScale.sc; a docs test compares them): 1-128 tones a period of
  -- 100-4800 cents; a period within octave_tolerance cents of an octave is
  -- an octave, where twelve tones take the scale's mask; degree 0 sits on
  -- key root_key + the root; the engine's table, table_frames frames from
  -- note table_low, table_resolution a semitone. Then: a pitch within
  -- tone_tolerance semitones of a tone is on it (step); cents a semitone;
  -- the default (twelve equal steps, the engine's start) and its text; the
  -- folder under _path.data and the extension of a player's files, the
  -- largest file read, a name's longest, the places a text keeps
  local TUNING = {
    max_tones = 128, min_period = 100, max_period = 4800, octave = 1200, twelve = 12, octave_tolerance = 0.001,
    root_key = 60, table_frames = 4096, table_low = -100, table_resolution = 10,
    tone_tolerance = 0.01, semitone = 100,
    default = {name = "12 equal", period = 1200, tones = {0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100}},
    default_text = "1200 0 100 200 300 400 500 600 700 800 900 1000 1100",
    folder = "strata/tunings/", extension = "scl", max_file_bytes = 65536, name_max = 24, cents_places = 4,
    bom = "\239\187\191",
  }
  M.TUNING = TUNING

  -- The built-ins (design §6.4), in the editor's order: an equal division
  -- (equal = n), ratios (norns' intonation tables, copied: the stub has no
  -- intonation and none is required), or a chain of fifths of `fifth`
  -- cents from `from` fifths below the first (Eb to G#)
  local JUST = {
    normal = {{1, 1}, {16, 15}, {9, 8}, {6, 5}, {5, 4}, {4, 3}, {45, 32}, {3, 2}, {8, 5}, {5, 3}, {16, 9}, {15, 8}},
    ptolemy = {{1, 1}, {16, 15}, {9, 8}, {6, 5}, {5, 4}, {4, 3}, {45, 32}, {3, 2}, {8, 5}, {5, 3}, {9, 5}, {15, 8}},
    overtone = {{1, 1}, {17, 16}, {9, 8}, {19, 16}, {5, 4}, {21, 16}, {11, 8}, {3, 2}, {13, 8}, {27, 16}, {7, 4}, {15, 8}},
    undertone = {{1, 1}, {16, 15}, {8, 7}, {32, 27}, {16, 13}, {4, 3}, {16, 11}, {32, 21}, {8, 5}, {32, 19}, {16, 9},
      {32, 17}},
    lamonte = {{1, 1}, {567, 512}, {9, 8}, {147, 128}, {1323, 1024}, {21, 16}, {189, 128}, {3, 2}, {49, 32},
      {441, 256}, {7, 4}, {63, 32}},
    partch = {{1, 1}, {81, 80}, {33, 32}, {21, 20}, {16, 15}, {12, 11}, {11, 10}, {10, 9}, {9, 8}, {8, 7}, {7, 6},
      {32, 27}, {6, 5}, {11, 9}, {5, 4}, {14, 11}, {9, 7}, {21, 16}, {4, 3}, {27, 20}, {11, 8}, {7, 5}, {10, 7},
      {16, 11}, {40, 27}, {3, 2}, {32, 21}, {14, 9}, {11, 7}, {8, 5}, {18, 11}, {5, 3}, {27, 16}, {12, 7}, {7, 4},
      {16, 9}, {9, 5}, {20, 11}, {11, 6}, {15, 8}, {40, 21}, {64, 33}, {160, 81}},
  }
  local BUILT_INS = {
    {name = "12 equal", equal = 12},
    {name = "ji normal", ratios = JUST.normal},
    {name = "ptolemy", ratios = JUST.ptolemy},
    {name = "overtone", ratios = JUST.overtone},
    {name = "undertone", ratios = JUST.undertone},
    {name = "lamonte", ratios = JUST.lamonte},
    {name = "pythagorean", fifth = ratio_cents(3, 2), from = -3},
    {name = "meantone 1/4", fifth = 300 * math.log(5) / LOG2, from = -3},
    {name = "19 equal", equal = 19},
    {name = "24 equal", equal = 24},
    {name = "31 equal", equal = 31},
    {name = "partch 43", ratios = JUST.partch},
  }

  -- A built-in's tones in cents, ascending from 0
  local function built_in_tones(record)
    local tones = {}
    if record.equal then
      for step = 0, record.equal - 1 do tones[#tones + 1] = step * TUNING.octave / record.equal end
    elseif record.ratios then
      for index, ratio in ipairs(record.ratios) do tones[index] = ratio_cents(ratio[1], ratio[2]) end
    else
      for fifths = record.from, record.from + TUNING.twelve - 1 do
        local cents = (fifths * record.fifth) % TUNING.octave
        tones[((fifths * 7) % TUNING.twelve) + 1] = cents  -- a fifth is seven semitones
      end
    end
    tones[1] = 0
    return tones
  end

  -- The tuning in force: what tuning_tones' text last applied
  local current = {period = TUNING.default.period, tones = {}}
  for index, cents in ipairs(TUNING.default.tones) do current.tones[index] = cents end

  ---------------------------------------------------------------------------
  -- The tuning in force
  ---------------------------------------------------------------------------

  function M.name() return params:get("tuning_name") end
  function M.count() return #current.tones end
  function M.period() return current.period end
  function M.tones()
    local copy = {}
    for index, cents in ipairs(current.tones) do copy[index] = cents end
    return copy
  end

  -- Whether the scale applies: twelve tones to an octave
  function M.scale_active()
    return #current.tones == TUNING.twelve and math.abs(current.period - TUNING.octave) < TUNING.octave_tolerance
  end

  -- The tones a pitch may land on, in cents above degree 0, ascending: the
  -- tones whose degree's bit of the scale's mask is set while the scale
  -- applies, every tone otherwise. Never empty (the mask is 1-4095)
  function M.allowed()
    if not M.scale_active() then return M.tones() end
    local mask, allowed = S.lib.variation.scale_mask(), {}
    for degree, cents in ipairs(current.tones) do
      if math.floor(mask / 2 ^ (degree - 1)) % 2 == 1 then allowed[#allowed + 1] = cents end
    end
    return allowed
  end

  -- Degree 0's key: root_key + the root
  local function root_note() return TUNING.root_key + S.lib.variation.root() end

  -- A MIDI key's pitch (a fractional note): key k is degree (k - degree 0's
  -- key) of the tuning, a period up or down for each wrap. In twelve equal
  -- steps it is k exactly, whatever the root
  function M.pitch_of_key(key)
    local reference, count = root_note(), #current.tones
    local distance = key - reference
    local periods = math.floor(distance / count)
    local degree = distance - periods * count
    return tidy(reference + (periods * current.period + current.tones[degree + 1]) / TUNING.semitone)
  end

  -- The allowed tone nearest a pitch, a tie going down
  function M.snap(pitch)
    local reference, period, allowed = root_note(), current.period, M.allowed()
    local cents = (pitch - reference) * TUNING.semitone
    local periods = math.floor(cents / period)
    local best, distance
    for whole = periods - 1, periods + 1 do
      for _, tone in ipairs(allowed) do
        local candidate = whole * period + tone
        local away = math.abs(candidate - cents)
        if distance == nil or away < distance or (away == distance and candidate < best) then
          best, distance = candidate, away
        end
      end
    end
    return tidy(reference + best / TUNING.semitone)
  end

  -- The k-th allowed tone beyond pitch: strictly above pitch +
  -- tone_tolerance for k > 0, strictly below pitch - tone_tolerance for
  -- k < 0; pitch itself for 0. Index arithmetic over the allowed tones and
  -- whole periods, no loop bound
  function M.step(pitch, k)
    if k == 0 then return pitch end
    local reference, period, allowed = root_note(), current.period, M.allowed()
    local count = #allowed
    local direction = k > 0 and 1 or -1
    local threshold = (pitch - reference + direction * TUNING.tone_tolerance) * TUNING.semitone
    local periods = math.floor(threshold / period)
    local index
    if direction > 0 then
      index = count + 1
      for position = count, 1, -1 do
        if periods * period + allowed[position] > threshold then index = position end
      end
    else
      index = 0
      for position = 1, count do
        if periods * period + allowed[position] < threshold then index = position end
      end
    end
    -- index 0 or count + 1 is the period's edge: the next one starts there
    index = index + direction * (math.abs(k) - 1) - 1
    periods = periods + math.floor(index / count)
    index = index % count + 1
    return tidy(reference + (periods * period + allowed[index]) / TUNING.semitone)
  end

  -- The step in semitones when the allowed tones are an equal division of
  -- the period (every gap within octave_tolerance cents), else nil
  function M.equal_step()
    local allowed, period = M.allowed(), current.period
    local gap = period / #allowed
    for index = 1, #allowed do
      local next_tone = allowed[index + 1] or (allowed[1] + period)
      if math.abs(next_tone - allowed[index] - gap) >= TUNING.octave_tolerance then return nil end
    end
    return tidy(gap / TUNING.semitone)
  end

  -- The allowed tones' mean step in semitones
  function M.mean_step() return current.period / #M.allowed() / TUNING.semitone end

  -- The chord interval set, in semitones from 0 (3.8 ruling 40): with a
  -- scale on in a tuning of twelve tones to an octave, its degrees 1, 3, 5
  -- and 7 (two periods of the allowed tones); otherwise the tuning's tones
  -- nearest 0, 4, 7 and 11 semitones, each once
  function M.chord()
    local V = S.lib.variation.VARIATION
    local chord, seen = {}, {}
    if M.scale_active() and S.lib.variation.scale_on() then
      local allowed, two = M.allowed(), {}
      for whole = 0, 1 do
        for _, tone in ipairs(allowed) do two[#two + 1] = whole * current.period + tone end
      end
      for _, degree in ipairs(V.chord_degrees) do
        if two[degree] then chord[#chord + 1] = tidy(two[degree] / TUNING.semitone) end
      end
      return chord
    end
    local reference = root_note()
    for _, semitones in ipairs(V.chromatic_chord) do
      local tone = tidy(M.snap(reference + semitones) - reference)
      if not seen[tone] then
        seen[tone] = true
        chord[#chord + 1] = tone
      end
    end
    return chord
  end

  ---------------------------------------------------------------------------
  -- The text and the engine
  ---------------------------------------------------------------------------

  -- A number at cents_places places, its trailing zeros (and point) dropped
  local function cents_text(cents)
    local text = string.format("%." .. TUNING.cents_places .. "f", cents)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    if text == "-0" then text = "0" end
    return text
  end

  -- tuning_tones' text: the period, then each tone
  function M.text_of(period, tones)
    local parts = {cents_text(period)}
    for _, cents in ipairs(tones) do parts[#parts + 1] = cents_text(cents) end
    return table.concat(parts, " ")
  end

  -- A tone list's problem, or nil: 1-128 tones, the first 0, each above the
  -- last, all below a period of 100-4800 cents
  local function tones_problem(period, tones)
    if #tones < 1 or #tones > TUNING.max_tones then return "count is not 1-" .. TUNING.max_tones end
    if period < TUNING.min_period or period > TUNING.max_period then
      return "period is not " .. TUNING.min_period .. "-" .. TUNING.max_period .. " cents"
    end
    if tones[1] ~= 0 then return "the first tone is not 0" end
    for index = 2, #tones do
      if tones[index] <= tones[index - 1] then return "tones do not ascend (tone " .. index .. ")" end
    end
    if tones[#tones] >= period then return "a tone at or above the period" end
    return nil
  end

  -- tuning_tones' text read: period, tones, or nil and the reason. Each
  -- token a plain decimal (never tonumber alone, which reads 0x10, 1e3 and
  -- inf)
  function M.parse_text(text)
    if type(text) ~= "string" then return nil, "not a text" end
    local numbers = {}
    for token in text:gmatch("%S+") do
      if not token:match("^%-?%d+%.?%d*$") then return nil, "not a number: " .. token:sub(1, 12) end
      numbers[#numbers + 1] = tonumber(token)
    end
    if #numbers < 2 then return nil, "count is not 1-" .. TUNING.max_tones end
    local period, tones = numbers[1], {}
    for index = 2, #numbers do tones[#tones + 1] = numbers[index] end
    local problem = tones_problem(period, tones)
    if problem then return nil, problem end
    return period, tones
  end

  -- The tuning to the engine: setTuning, then each tone (direct, up to 129
  -- messages; the engine rebuilds its table at the last)
  function M.send()
    engine.setTuning(#current.tones, current.period)
    for index, cents in ipairs(current.tones) do engine.setTuningTone(index - 1, cents) end
  end

  -- tuning_tones' action: a text that reads is the tuning from now on, sent,
  -- then every quantized voice snapped and every chord resent; one that
  -- does not prints one line and the param goes back, silently, to the
  -- tuning in force
  function M.apply_text(text)
    local period, tones = M.parse_text(text)
    if not period then
      print("tuning: " .. tostring(tones))
      params:set("tuning_tones", M.text_of(current.period, current.tones), true)
      return false
    end
    current.period, current.tones = period, tones
    M.send()
    S.lib.variation.tuning_changed()
    request_redraw()
    return true
  end

  -- Choose an entry (a built-in or a file's: name, period, tones): its name,
  -- then its text, whose action applies it
  function M.select(entry)
    params:set("tuning_name", entry.name)
    params:set("tuning_tones", M.text_of(entry.period, entry.tones))
  end

  function M.built_ins()
    local entries = {}
    for index, record in ipairs(BUILT_INS) do
      entries[index] = {name = record.name, period = TUNING.octave, tones = built_in_tones(record)}
    end
    return entries
  end

  ---------------------------------------------------------------------------
  -- Scala files
  ---------------------------------------------------------------------------

  -- A Scala pitch's cents, or nil: cents when it holds a point (a digit in
  -- it), else a ratio a/b or a whole number a, both terms positive
  local function pitch_cents(token)
    if token:match("^[+-]?%d*%.%d*$") and token:match("%d") then return tonumber(token) end
    local numerator, denominator = token:match("^(%d+)/(%d+)$")
    if not numerator then numerator, denominator = token:match("^(%d+)$"), "1" end
    numerator, denominator = tonumber(numerator), tonumber(denominator)
    if numerator and denominator and numerator > 0 and denominator > 0 then
      return ratio_cents(numerator, denominator)
    end
    return nil
  end

  -- A .scl file's text read: period, tones, or nil and the reason. A UTF-8
  -- BOM and CR line ends are taken as a Unix file's; a line starting "!" is
  -- a comment; the first other line the description, the next the count
  -- (1-128), then that many pitch lines (blank ones skipped), each read up
  -- to its first space; 1/1 is implied, the last pitch is the period
  function M.parse_scl(text)
    if type(text) ~= "string" then return nil, "not a text" end
    if #text > TUNING.max_file_bytes then return nil, "over " .. TUNING.max_file_bytes .. " bytes" end
    if text:sub(1, #TUNING.bom) == TUNING.bom then text = text:sub(#TUNING.bom + 1) end
    local description, count, pitches, number = nil, nil, {}, 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      number = number + 1
      line = line:gsub("\r$", "")
      if line:sub(1, 1) ~= "!" then
        local token = line:match("^%s*(%S+)")
        if description == nil then
          description = line
        elseif count == nil then
          count = token and token:match("^%d+$") and tonumber(token)
          if not count or count < 1 or count > TUNING.max_tones then return nil, "count is not 1-" .. TUNING.max_tones end
        elseif token and #pitches < count then
          local cents = pitch_cents(token)
          if not cents then return nil, "line " .. number .. ": not a pitch" end
          pitches[#pitches + 1] = cents
        end
      end
    end
    if count == nil then return nil, "count is not 1-" .. TUNING.max_tones end
    if #pitches < count then return nil, "only " .. #pitches .. " pitches" end
    local tones = {0}
    for index = 1, count - 1 do tones[#tones + 1] = pitches[index] end
    local period = pitches[count]
    local problem = tones_problem(period, tones)
    if problem then return nil, problem end
    return period, tones
  end

  local function folder() return _path.data .. TUNING.folder end

  -- The .scl files in the tunings folder, sorted by name (none when it is
  -- missing)
  function M.files()
    local names = S.lib.files.files_of(folder(), {[TUNING.extension] = true}) or {}
    table.sort(names)
    return names
  end

  -- A file of the folder as an entry (name, period, tones), or nil and the
  -- reason, printed as one line "tuning: <file>: <reason>". Read as text,
  -- at most max_file_bytes; the name is the file's without .scl, its
  -- control characters dropped (a PSET line stays one line), cut to name_max
  function M.load_file(name)
    local function refuse(reason)
      print("tuning: " .. tostring(name) .. ": " .. reason)
      return nil, reason
    end
    if type(name) ~= "string" or name:find("/", 1, true) then return refuse("not a file of the folder") end
    local file = io.open(folder() .. name, "rb")
    if not file then return refuse("cannot be read") end
    local text = file:read(TUNING.max_file_bytes + 1) or ""
    file:close()
    local period, tones = M.parse_scl(text)
    if not period then return refuse(tones) end
    local shown = name:gsub("%." .. TUNING.extension .. "$", ""):gsub("%c", ""):sub(1, TUNING.name_max)
    return {name = shown, period = period, tones = tones}
  end

  ---------------------------------------------------------------------------
  -- Params and the start
  ---------------------------------------------------------------------------

  -- tuning_name (shown; its action only renames) and tuning_tones (hidden;
  -- its action applies the tuning), each with its text default for a PSET
  -- read (S.lib.params_setup.set_text_default). Added from the scale
  -- record, after root and scale_mask, before every voice
  function M.add_params()
    params:add{type = "text", id = "tuning_name", name = "tuning", text = TUNING.default.name,
      action = function() request_redraw() end}
    params:add{type = "text", id = "tuning_tones", name = "tuning tones", text = TUNING.default_text,
      action = M.apply_text}
    params:hide("tuning_tones")
    S.lib.params_setup.set_text_default("tuning_name", TUNING.default.name)
    S.lib.params_setup.set_text_default("tuning_tones", TUNING.default_text)
  end

  -- The start makes the tunings folder; it sends nothing (the engine starts
  -- in the default tuning, 3.8 ruling 42)
  S.register_start(S.constants.START_ORDER.tuning, function() util.make_dir(folder()) end)

  return M
end
