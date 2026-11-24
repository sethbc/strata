-- lib/random_sequences.lua
-- The random sequences (3.7, design §8, decision 7), S.lib.random_sequences:
-- RSEQ.count sequences of RSEQ.values numbers each (-1 to 1), of which the
-- first `length` play in order and repeat. Each steps on its own clock: a
-- division of the tempo, read from clock.get_beats() in the LFO clock's
-- step (S.lib.lfos.on_step, registered before the matrix's, so a routing
-- reads a step's new value in that same step), or a voice's hits (the
-- voice_hit hook). At a step the position moves on, then with the drift's
-- chance the value it left is drawn again. Params: the group strata_rseq
-- (rseq<n>_length, _drift, _clock, _new). Sources rseq1..rseq4 (section
-- sequences, RS1..RS4, -1..1) with their settings rows (fields). Storage:
-- the scene block `sequences`, the PSET side file <path base>.sequences.data
-- and the live data/strata/sequences.data, through S.lib.side_files. Start
-- step sequences_load, cleanup step sequences_save. Nothing here sends,
-- yields or redraws from a step: MOD animates while it shows them.
-- See docs/notes/lua/random-sequences.md.

return function(S)
  local M = {}
  local DIVISIONS = S.constants.DIVISIONS
  local NUM_VOICES = S.constants.NUM_VOICES

  -- The sequences' tunables: how many, the values each holds, the shortest
  -- length, the defaults (the length, the clock's option: 1/8), a value's
  -- edit steps on MOD (a detent, a fine one) and the files
  local RSEQ = {
    count = 4,
    values = 16,
    length_min = 2,
    default_length = 8,
    default_clock = 6,
    drift_max = 100,
    params_per_sequence = 4,            -- length, drift, clock, new
    value_step = 0.01,
    fine_step = 0.001,
    live_file = "sequences.data",       -- in data/strata/
    side_suffix = ".sequences.data",    -- after a PSET's path without .pset
    backup_suffix = ".bak",
    -- s from a hand edit, a new draw, a scene's or a PSET's values to the
    -- live file's write, one write per burst (drift's draws wait for the
    -- next one, or cleanup's)
    save_delay = 0.5,
    data_version = 1,
  }
  M.RSEQ = RSEQ

  local function valid(n) return type(n) == "number" and n % 1 == 0 and n >= 1 and n <= RSEQ.count end
  local function valid_index(index)
    return type(index) == "number" and index % 1 == 0 and index >= 1 and index <= RSEQ.values
  end
  local function finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
  end

  local function param_id(n, name) return "rseq" .. n .. "_" .. name end

  -- The clock option's names: the divisions, then voice 1..NUM_VOICES
  local CLOCK_NAMES = {}
  for index, name in ipairs(DIVISIONS.names) do CLOCK_NAMES[index] = name end
  for voice_idx = 1, NUM_VOICES do CLOCK_NAMES[#DIVISIONS.names + voice_idx] = "voice " .. voice_idx end

  -- Per sequence: values (RSEQ.values numbers), position (1..length) and
  -- count (the division's count of its last step, floor(beats / its
  -- beats); nil until the first reading on its clock)
  local sequences = {}
  for n = 1, RSEQ.count do
    local values = {}
    for index = 1, RSEQ.values do values[index] = 0 end
    sequences[n] = {values = values, position = 1, count = nil}
  end

  -- A param's value, or its default before the params exist
  local function length(n)
    local id = param_id(n, "length")
    return params.lookup[id] and params:get(id) or RSEQ.default_length
  end
  local function clock_option(n)
    local id = param_id(n, "clock")
    return params.lookup[id] and params:get(id) or RSEQ.default_clock
  end
  local function drift(n)
    local id = param_id(n, "drift")
    return params.lookup[id] and params:get(id) or 0
  end

  -- The voice a sequence follows, or nil on a division
  local function clock_voice(n)
    local option = clock_option(n)
    if option > #DIVISIONS.names then return option - #DIVISIONS.names end
    return nil
  end

  local function draw() return math.random() * 2 - 1 end

  -- The live file follows a change (set below, once the files exist)
  local save_live = function() end

  ---------------------------------------------------------------------------
  -- Reading and editing
  ---------------------------------------------------------------------------

  -- Sequence n's position, inside its length: a position past it (a length
  -- set silently, as a PSET read with silent sets it, skips the length's
  -- action) reads as 1, where that action would have put it
  local function position_of(n)
    local position = sequences[n].position
    if position > length(n) then return 1 end
    return position
  end

  function M.value(n)
    if not valid(n) then return 0 end
    return sequences[n].values[position_of(n)] or 0
  end

  function M.position(n)
    if not valid(n) then return nil end
    return position_of(n)
  end

  function M.values(n)
    if not valid(n) then return nil end
    local copy = {}
    for index, value in ipairs(sequences[n].values) do copy[index] = value end
    return copy
  end

  -- Value index of sequence n set by hand (clamped to -1..1). Returns
  -- whether it was set: an index, a sequence or a value that is not finite
  -- is refused
  function M.set_value(n, index, value)
    if not valid(n) or not valid_index(index) or not finite(value) then return false end
    sequences[n].values[index] = util.clamp(value, -1, 1)
    S.lib.mutation.note_sequence_edit(n)  -- a hand edit ends a held new (#922)
    save_live()
    return true
  end

  -- New values for all sixteen of sequence n, the old ones held by the
  -- undo on MOD at the sequence's own section, its source key (#922: undone
  -- on its row or in its settings; the row's press, the param's trigger)
  function M.new(n)
    if not valid(n) then return end
    S.lib.mutation.hold_sequence(n, {page = S.constants.UI_PAGES.index.MOD, section = "rseq" .. n})
    local values = sequences[n].values
    for index = 1, RSEQ.values do values[index] = draw() end
    save_live()
  end

  ---------------------------------------------------------------------------
  -- Stepping
  ---------------------------------------------------------------------------

  -- One step: the position moves to the next of 1..length (past it, 1);
  -- then, with drift % chance (one draw, made only above 0), the value at
  -- the position it left is drawn again
  local function step(n)
    local sequence = sequences[n]
    local left = position_of(n)
    sequence.position = left >= length(n) and 1 or left + 1
    local chance = drift(n)
    if chance > 0 and math.random() * RSEQ.drift_max < chance then sequence.values[left] = draw() end
  end

  -- The divisions, at each LFO step: a sequence steps once whenever its
  -- division's count has changed since its last step, whatever the gap (a
  -- transport start's fall too); its first reading on a clock only counts
  S.lib.lfos.on_step(function()
    local beats
    for n = 1, RSEQ.count do
      if not clock_voice(n) then
        beats = beats or clock.get_beats()
        local sequence = sequences[n]
        local count = math.floor(beats / DIVISIONS.beats[clock_option(n)])
        if sequence.count ~= nil and count ~= sequence.count then step(n) end
        sequence.count = count
      end
    end
  end)

  -- A voice's hits (lib/engine_sync.lua's voice_hit: a start, a retrigger,
  -- a played extra note's start; a step is one hit however many notes its
  -- chord has)
  S.register_voice_hit({name = "random sequences", hit = function(voice_idx)
    for n = 1, RSEQ.count do
      if clock_voice(n) == voice_idx then step(n) end
    end
  end})

  ---------------------------------------------------------------------------
  -- Params
  ---------------------------------------------------------------------------

  local function percent(param) return param:get() .. "%" end

  -- The group strata_rseq (design §8): per sequence its length, drift,
  -- clock and new
  function M.add_params()
    params:add_group("strata_rseq", "random sequences", RSEQ.params_per_sequence * RSEQ.count)
    for n = 1, RSEQ.count do
      local name = "RS" .. n .. " "
      params:add_number(param_id(n, "length"), name .. "length", RSEQ.length_min, RSEQ.values, RSEQ.default_length)
      params:set_action(param_id(n, "length"), function(value)
        if sequences[n].position > value then sequences[n].position = 1 end
      end)
      params:add_number(param_id(n, "drift"), name .. "drift", 0, RSEQ.drift_max, 0, percent)
      params:add_option(param_id(n, "clock"), name .. "clock", CLOCK_NAMES, RSEQ.default_clock)
      params:set_action(param_id(n, "clock"), function() sequences[n].count = nil end)
      params:add_trigger(param_id(n, "new"), name .. "new")
      params:set_action(param_id(n, "new"), function() M.new(n) end)
    end
  end

  ---------------------------------------------------------------------------
  -- Storage
  ---------------------------------------------------------------------------

  -- The four lists, each a copy
  local function capture()
    local lists = {}
    for n = 1, RSEQ.count do lists[n] = M.values(n) end
    return lists
  end

  -- Exactly n entries at the keys 1..n
  local function is_list(value, count)
    if type(value) ~= "table" then return false end
    local entries = 0
    for key in pairs(value) do
      if not (type(key) == "number" and key % 1 == 0 and key >= 1 and key <= count) then return false end
      entries = entries + 1
    end
    return entries == count
  end

  -- Why stored lists cannot be loaded, or nil: exactly RSEQ.count lists of
  -- RSEQ.values finite numbers in -1..1
  local function lists_problem(lists)
    if not is_list(lists, RSEQ.count) then return "not " .. RSEQ.count .. " sequences" end
    for n = 1, RSEQ.count do
      if not is_list(lists[n], RSEQ.values) then return "sequence " .. n .. " is not " .. RSEQ.values .. " values" end
      for index = 1, RSEQ.values do
        local value = lists[n][index]
        if not finite(value) or value < -1 or value > 1 then
          return "sequence " .. n .. " value " .. index .. " is not a number in -1..1"
        end
      end
    end
    return nil
  end

  -- Stored lists replace the values (a scene, a PSET's or the live file):
  -- each ends a held new of its sequence (#922)
  local function load_lists(lists)
    for n = 1, RSEQ.count do
      for index = 1, RSEQ.values do sequences[n].values[index] = lists[n][index] end
      S.lib.mutation.note_sequence_edit(n)
    end
  end

  local function zeros()
    local lists = {}
    for n = 1, RSEQ.count do
      lists[n] = {}
      for index = 1, RSEQ.values do lists[n][index] = 0 end
    end
    return lists
  end

  -- Scenes store the four lists (a discrete block: applied at a fade's end,
  -- as a copy); a scene without it loads sixteen zeros each
  S.register_scene_block({
    key = "sequences",
    default = zeros,
    capture = capture,
    validate = function(value) return lists_problem(value) == nil end,
    apply = function(value)
      load_lists(value)
      save_live()
    end,
    discrete = true,
  })

  -- The files (lib/side_files.lua): the live file data/strata/sequences.data
  -- and the one beside each PSET, {version, sequences = {four lists}}. The
  -- start step's read with no usable file draws every value (the first
  -- start); a PSET with none loads the scenes' default, sixteen zeros each
  local first_load, drew = true, false
  local files = S.lib.side_files.new({
    name = "sequences", contents = "random sequences", version = RSEQ.data_version, key = "sequences",
    live_file = RSEQ.live_file, side_suffix = RSEQ.side_suffix, backup_suffix = RSEQ.backup_suffix,
    save_delay = RSEQ.save_delay, clock_field = "sequences_save_clock",
    capture = capture,
    validate = lists_problem,
    load = function(lists)
      if lists then
        load_lists(lists)
      elseif first_load then
        for n = 1, RSEQ.count do
          for index = 1, RSEQ.values do sequences[n].values[index] = draw() end
        end
        drew = true
      else
        load_lists(zeros())
      end
      first_load = false
      request_redraw()
    end,
  })
  save_live = files.save_live

  -- The PSET's side file: written with every PSET save, read after every
  -- PSET load (the live file follows), deleted with the PSET
  S.register_pset_hook(files.pset_hook(nil, function() save_live() end))

  -- The live file: loaded at init, saved as the values change and at
  -- cleanup once it was read, missing or set aside. A first start's draw
  -- is saved one save_delay later (the live file may be written only once
  -- load_live returns), so a norns switched off at the power keeps it
  S.register_start(S.constants.START_ORDER.sequences_load, function()
    files.load_live()
    if drew then save_live() end
  end)
  S.register_cleanup(S.constants.CLEANUP_ORDER.sequences_save, files.save_now)

  ---------------------------------------------------------------------------
  -- The modulation sources and their settings rows
  ---------------------------------------------------------------------------

  -- Sequence n's rows: length, drift, clock, new, then a row per value;
  -- built once, and the list MOD reads kept per length
  local function param_row(n, label, name)
    local id = param_id(n, name)
    return {label = label, value = function() return tostring(params:string(id)) end,
      enc = function(d) enc_param_delta(3, id, d) end}
  end

  local function value_row(n, index)
    local function nudge(amount)
      local value = sequences[n].values[index] + amount
      M.set_value(n, index, util.round(value, RSEQ.fine_step))
    end
    return {
      label = "v" .. index,
      value = function() return string.format("%.3f", sequences[n].values[index]) end,
      enc = function(d) nudge(d * RSEQ.value_step) end,
      fine_enc = function(d) nudge(d * RSEQ.fine_step) end,
    }
  end

  local function rows_for(n)
    local all = {param_row(n, "length", "length"), param_row(n, "drift", "drift"), param_row(n, "clock", "clock"),
      {label = "new", value = function() return "" end, press = function() M.new(n) end}}
    local fixed = #all
    for index = 1, RSEQ.values do all[fixed + index] = value_row(n, index) end
    local by_length = {}
    return function()
      local count = length(n)
      local rows = by_length[count]
      if not rows then
        rows = {}
        for index = 1, fixed + count do rows[index] = all[index] end
        by_length[count] = rows
      end
      return rows
    end
  end

  for n = 1, RSEQ.count do
    S.register_mod_source({
      key = "rseq" .. n,
      name = "RS" .. n,
      section = "sequences",
      range = {-1, 1},
      value = function() return M.value(n) end,
      describe = function()
        return CLOCK_NAMES[clock_option(n)] .. " " .. position_of(n) .. "/" .. length(n)
      end,
      fields = rows_for(n),
    })
  end

  return M
end
