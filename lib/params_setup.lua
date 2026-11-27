-- lib/params_setup.lua
-- init's params, in PARAMS menu order: S.registry.params holds one record
-- {name, add} per part of the menu (performance, master, mutations, scenes,
-- fx, lfos, buffers, record, positions, midi, scale, voices), and init runs
-- each record's add in order. Also
-- the voice params (add_voice_params, get_param_spec), the redraw-on-param
-- wrapper (redraw_on_param_changes, called by init after the records) and
-- the tempo-follow handlers; these stay global. S.fx_last_mix.filter is
-- read by the FX page's K3. Reads, at init, the voice-param records (the
-- built-in synth, grain and crossmod ones first, lib/voices.lua; each
-- param added through S.lib.params_setup.add_voice_param), fx params, param
-- filters and source change hooks (lib/state.lua), and sets S.performance
-- (the standard tier's values until the "performance" record fills it).

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local NUM_SCENES = S.constants.NUM_SCENES
  local NUM_BUFFERS = S.constants.NUM_BUFFERS
  local FX_GROUP_PARAMS = 11  -- the fx group's own params; registered fx params follow them

  -- The performance tier's values (tier, buffer_seconds, max_grains,
  -- history_seconds): the standard tier's, a copy so nothing changes the
  -- constant. The "performance" record (lib/performance.lua) fills it at
  -- init, before any param is added; every tier-dependent spec reads it as
  -- its params are added
  S.performance = {}
  for key, value in pairs(S.constants.STANDARD_PERFORMANCE) do S.performance[key] = value end

  -- The filter's restore mix: the mix K3 brings back from 0. filter_mix's
  -- action sets it when the mix rises, and toggle_filter_mix sets it to the
  -- mix at the press before turning the filter off: nothing else writes it
  -- (#235). The delay and reverb need none: K3 toggles their bypass params,
  -- which keep the mix
  S.fx_last_mix = {filter = 1}
  local filter_mix_before = 0  -- the filter mix before its last change (the param's default)

  -- The filter mix moved to x: a rise is the mix K3 brings back. filter_mix's
  -- action, and the engine params' PSET hook after a silent read (#965)
  local function filter_mix_moved(x)
    if x > filter_mix_before then S.fx_last_mix.filter = x end
    filter_mix_before = x
  end

  -- FX's K3 on a filter row: a mix above 0 becomes 0 (remembering it), a mix
  -- of 0 becomes the restore mix
  function M.toggle_filter_mix()
    local mix = params:get("filter_mix")
    if mix > 0 then
      S.fx_last_mix.filter = mix
      params:set("filter_mix", 0)
    else
      params:set("filter_mix", S.fx_last_mix.filter)
    end
  end

  -- The filter and delay params are faders on the grid's FX page: redraw
  -- only while a pane shows it (any_fx_faders). A scene that sets them (a
  -- fade step, a recall's apply: S.lib.scenes.setting()) redraws the grid
  -- once itself; a hand edit during a fade redraws at once (#867).
  local function fx_fader_changed()
    if S.lib.grid_core.any_fx_faders() and not S.lib.scenes.setting() then grid_redraw() end
  end

  -- Follow the clock when its tempo is set elsewhere (PARAMETERS > CLOCK, an
  -- external clock source): norns calls the handler with the new bpm (an
  -- external source's may be outside clock_tempo's range). Set the param
  -- silently, so its action does not write the clock back, then call the
  -- handler that was installed before the script's.
  local previous_tempo_change_handler

  function follow_clock_tempo(bpm)
    local min_tempo, max_tempo = param_range("tempo")
    local tempo = util.clamp(util.round(bpm), min_tempo, max_tempo)
    local changed = params:get("tempo") ~= tempo
    params:set("tempo", tempo, true)
    if changed then request_redraw() end  -- SEQ's header and arc ring 3 show it (#383)
    if previous_tempo_change_handler then previous_tempo_change_handler(bpm) end
  end

  -- Install follow_clock_tempo, keeping the handler it replaces for cleanup()
  -- (restore_tempo_change_handler). Installing it again (init run twice)
  -- changes nothing: the script's handler never chains to itself
  function install_tempo_change_handler()
    if clock.tempo_change_handler == follow_clock_tempo then return end
    previous_tempo_change_handler = clock.tempo_change_handler
    clock.tempo_change_handler = follow_clock_tempo
  end

  -- Give the clock back the handler found at install, unless a handler
  -- installed after the script's has replaced it: that one stays (and any
  -- chain through follow_clock_tempo still reaches the previous handler)
  function restore_tempo_change_handler()
    if clock.tempo_change_handler ~= follow_clock_tempo then return end
    clock.tempo_change_handler = previous_tempo_change_handler
    previous_tempo_change_handler = nil
  end

  -- cleanup()'s first step
  S.register_cleanup(S.constants.CLEANUP_ORDER.tempo_handler, function()
    restore_tempo_change_handler()
  end)

  -- The tempo (BPM) to show for the clock right after a change, for the
  -- 256's tempo flash (#383, #567): the clock_tempo param on the internal
  -- clock and Link, which a tempo key sets (the internal clock reports a
  -- new tempo through clock.get_tempo() only from its tick after next);
  -- clock.get_tempo() under MIDI or crow, which ignore the param. Never for
  -- timing: beat_seconds_now is the one a take's length and delay read
  function M.clock_tempo_now()
    local source = params:string("clock_source")
    if source == "internal" or source == "link" then return params:get("clock_tempo") end
    return clock.get_tempo()
  end

  -- A beat's length (s) the clock runs from now on, for timing: a synced
  -- take's length and delay, and so BUFFER's len field (#567). On the
  -- internal clock 60 / the clock_tempo param, which its action sets at
  -- once, while clock.get_tempo() reads the old tempo until the clock has
  -- ticked twice. On Link, MIDI and crow 60 / clock.get_tempo(): there the
  -- param is a whole BPM that norns refreshes from the clock once a second,
  -- so a fractional Link session or a peer's change would be off. A clocked
  -- LFO's rate (lib/lfos.lua) reads it too.
  function M.beat_seconds_now()
    if params:string("clock_source") == "internal" then return 60 / params:get("clock_tempo") end
    return 60 / clock.get_tempo()
  end

  -- norns' number param adds a delta unrounded, and its PARAMS menu turns
  -- a param by d / 20 while K3 is held (core/menu/params.lua's
  -- delta_value), so a number param could come to hold a fraction (#534).
  -- A number param gets a delta that steps whole numbers instead, as norns'
  -- option param does: d rounded away from 0
  local function step_whole(param)
    local own_delta = param.delta
    param.delta = function(self, d)
      own_delta(self, d < 0 and math.floor(d) or math.ceil(d))
    end
  end

  -- The PSET read hook's state (#314, #554, #628), filled at init, in menu
  -- order: record_params, the id of every param the records add (Strata's
  -- own, never norns' system params), and number_params, those of them that
  -- are number params
  -- text_defaults: a text param's text for a PSET with no line for it, by
  -- id (M.set_text_default; 3.8)
  -- read_changed: the ids the last read set to their default (no line for
  -- them) when that changed them (3.8, the tuning's PSET hook reads it)
  local pset = {number_params = {}, record_params = {}, text_defaults = {}, read_changed = {}}

  -- The text a PSET read gives text param id when the file has no line for
  -- it (3.8: tuning_name and tuning_tones, lib/tuning.lua); a text param
  -- without one keeps its text, as before
  function M.set_text_default(id, text)
    if type(id) ~= "string" or type(text) ~= "string" then
      error("params_setup.set_text_default: id and text are strings", 2)
    end
    pset.text_defaults[id] = text
  end

  -- A number param's value made whole in its action, before it is stored
  -- or reaches the engine (#554): norns' params:read sets each PSET line
  -- through the param's own set, actions included, before the read hook
  -- rounds, so a saved fraction reached setModSource once (matron casts an
  -- "i" argument). A fraction is written back silently, so the param shows
  -- what is stored and the hook has nothing left to round
  function pset.whole(param_id, x)
    local whole = util.round(x)
    if whole ~= x then params:set(param_id, whole, true) end
    return whole
  end

  -- Add one part of the PARAMS menu: init runs the records' add functions
  -- in the order they are registered here, which is the menu's order. Each
  -- param a record adds (Strata's own, never norns' system params) joins
  -- pset.record_params, which a PSET read gives a default when the file has
  -- no line for it (#628); each number param steps whole numbers
  -- (step_whole) and joins pset.number_params, which a PSET read rounds
  -- (#554)
  local function register_params(name, add)
    S.registry.params[#S.registry.params + 1] = {name = name, add = function()
      local before = #params.params
      add()
      for index = before + 1, #params.params do
        local param = params.params[index]
        pset.record_params[#pset.record_params + 1] = param.id
        if param.t == params.tNUMBER then
          step_whole(param)
          pset.number_params[#pset.number_params + 1] = param.id
        end
      end
    end}
  end

  -- One line of a PSET file's text as norns' params:read reads it
  -- (lua/core/paramset.lua): a line not starting "--" whose first quoted
  -- string is followed by a colon gives that string unquoted, the id, and
  -- the rest of the line, its raw value (a trailing \r dropped: norns keeps
  -- it, which a number's tonumber ignores but a text or a file name would
  -- not); any other line gives nil. The one
  -- reader of a line (the read hook's named ids, pset_value, 3.8's factory
  -- sets' parse_params)
  function M.pset_line(line)
    if type(line) ~= "string" or line:sub(1, 2) == "--" then return nil end
    line = line:gsub("\r$", "")  -- a file written with CRLF lines (3.8: a factory set made elsewhere)
    local quoted, value = line:match('(".-")%s*:%s*(.*)')
    if not quoted then return nil end
    return (quoted:gsub('^"', ''):gsub('"$', ''):gsub('\\"', '"')), value
  end

  -- The ids a PSET file's text has a line for
  function pset.named_ids(text, order)
    local named, index = {}, 0
    for line in text:gmatch("[^\n]+") do
      local id = M.pset_line(line)
      if id and not named[id] then
        named[id] = true
        if order then
          index = index + 1
          order[id] = index
        end
      end
    end
    return named
  end

  -- The order norns applied this id in the silent read whose hooks are
  -- running. Only its first line counts; a missing id defaults after them.
  function M.read_order(id)
    return pset.order and pset.order[id]
  end

  -- The text of id's line in a PSET file's text (the rest of the line after
  -- the quoted id and its colon), or nil for no line (3.8: the tuning's
  -- PSET hook reads a voice's freq)
  function M.pset_value(text, id)
    for line in text:gmatch("[^\n]+") do
      local line_id, value = M.pset_line(line)
      if line_id == id then return value end
    end
    return nil
  end

  -- Whether the last PSET read gave id its default (the file had no line
  -- for it) and that changed it (3.8)
  function M.read_defaulted(id)
    return pset.read_changed[id] == true
  end

  -- The value a param loads when a PSET has no line for it (#628): its
  -- default, as norns' set_default gives it, for the types that have one
  -- (control, number, option, taper, a binary that is not a trigger; a
  -- control made without a default, the value it starts at); nil for a
  -- param norns never saves (save off, a trigger, a separator or a group)
  -- and for a file or text param, which has none, but a text param given
  -- one with M.set_text_default (3.8: the tuning's two). The read hook's
  -- (migrate_read_pset) and 3.8's factory sets' load (S.lib.factory) alike
  function M.load_default(param)
    if param.save == false then return nil end
    if param.t == params.tTEXT then return pset.text_defaults[param.id] end
    if param.t == params.tCONTROL then
      local spec = param.controlspec
      if spec.default ~= nil then return spec.default end
      return spec:map(0)
    end
    if param.t == params.tNUMBER or param.t == params.tOPTION or param.t == params.tTAPER then return param.default end
    if param.t == params.tBINARY and param.behavior ~= "trigger" then return param.default end
    return nil
  end

  -- Every param Strata's records add (never norns' own), in menu order: the
  -- read hook's list, a copy (3.8: the factory sets' load walks it too)
  function M.record_param_ids()
    local ids = {}
    for index, id in ipairs(pset.record_params) do ids[index] = id end
    return ids
  end

  -- norns' params.action_read, run after every params:read (PARAMS > PSET,
  -- a script's read), with the file's path and the read's silent flag;
  -- every change goes through params:set, so the voices table, the engine
  -- and the screen follow, and honors silent.
  -- 0. Every param of Strata's records that norns saves and the file has no
  --    line for goes to its default (#628): a PSET saved before the param
  --    existed loads its default, never the session's value. norns writes
  --    a line for every saved param, so a PSET saved now is untouched.
  --    Before the PSET hooks.
  -- 1. Every number param pset.number_params lists is rounded to its step,
  --    a whole number (#554): one saved holding a fraction (norns' PARAMS
  --    menu turned a number param by d / 20 with K3 held) loads whole.
  -- Nothing is keyed on when a PSET was saved (3.7): a line for an id that
  -- is no param (3.3 to 3.6's strata_pset_format) is skipped by norns'
  -- read, and nothing is converted.
  function M.migrate_read_pset(filename, silent, order)
    -- 3.8 (ruling 63, P13 amended): a PSET read sets every voice's type, so
    -- every pending type choice is canceled, also where the type's line
    -- left the type as it was (its action runs only on a change)
    for voice_idx = 1, NUM_VOICES do S.lib.types.cancel(voice_idx) end
    local file = io.open(filename, "r")
    local text = file and file:read("*a")
    if file then file:close() end
    pset.read_changed = {}
    if text then
      local named, defaulted = pset.named_ids(text, order), 0
      for _, id in ipairs(M.record_param_ids()) do
        local default = not named[id] and M.load_default(params:lookup_param(id))
        if default then
          if params:get(id) ~= default then pset.read_changed[id] = true end
          params:set(id, default, silent)
          defaulted = defaulted + 1
        end
      end
      if defaulted > 0 then
        print("pset: " .. defaulted .. " params it has no line for (saved before they existed) set to their defaults")
      end
    end
    for _, id in ipairs(pset.number_params) do
      local value = params:get(id)
      if value ~= math.floor(value) then params:set(id, util.round(value), silent) end
    end
  end

  -- The PSET hooks (S.registry.pset_hooks, 3.4): run every hook's function
  -- for action (write, read or delete) that it has, in registration order,
  -- with the PSET's path without .pset (path_base) and then the action's own
  -- arguments; each in its own pcall, so a failing hook prints "pset hook
  -- <name>: <error>" and the next still runs
  local function run_pset_hooks(action, filename, ...)
    local path_base = tostring(filename):gsub("%.pset$", "")
    for _, hook in ipairs(S.registry.pset_hooks) do
      local fn = hook[action]
      if fn then
        local ran, failure = pcall(fn, path_base, ...)
        if not ran then print("pset hook " .. hook.name .. ": " .. tostring(failure)) end
      end
    end
  end

  -- norns' three PSET actions (lua/core/paramset.lua), installed by the
  -- master record: number is what norns passes, the PSET's two-digit
  -- number ("01") or nil for one read or written by path. A read migrates
  -- the PSET first (M.migrate_read_pset), then runs the hooks, passing on
  -- the read's silent flag (a hook that sets params honors it). norns clears
  -- the three with the script's params, so no cleanup step is needed
  function pset.install_actions()
    params.action_read = function(filename, silent, number)
      local order = silent and {} or nil
      M.migrate_read_pset(filename, silent, order)
      local previous = pset.order
      pset.order = order
      run_pset_hooks("read", filename, number, filename, silent)
      pset.order = previous
    end
    params.action_write = function(filename, name, number) run_pset_hooks("write", filename, number) end
    params.action_delete = function(filename, name, number) run_pset_hooks("delete", filename, number) end
  end

  -- Run a registered record's add(...) and check it added exactly
  -- record.count params (kind names the registry in the error)
  local function add_counted(kind, record, ...)
    local before = #params.params
    record.add(...)
    local added = #params.params - before
    if added ~= record.count then
      error(string.format("%s %s: add added %d params, but its count is %d", kind, record.name, added,
        record.count), 0)
    end
  end

  -- The performance tier the engine runs (lib/performance.lua): first, so
  -- S.performance is filled before any param is added. It adds no params
  register_params("performance", function()
    S.close_registries()  -- init reads the registries from here on (#384)
    S.lib.performance.read_active()
  end)

  register_params("master", function()
    params:add_separator("strata")

    -- A PSET read runs M.migrate_read_pset, then the PSET hooks
    -- (pset.install_actions)
    pset.install_actions()

    -- Master controls
    params:add{
      type = "control",
      id = "master_density",
      name = "master density",
      controlspec = controlspec.new(0.1, 2.0, "lin", 0.01, 1.0),
      action = function(x)
        note_param_edit("master_density")  -- a page randomize sets it: an edit ends its undo
        send_param_to_engine("master_density", x)
      end
    }

    -- Sequencer tempo: drives norns' global clock (clock_tempo), which the
    -- pattern clock follows via clock.sync so external clock sources still work.
    -- It has clock_tempo's range, so any clock tempo is captured and recalled
    local min_tempo, max_tempo = param_range("clock_tempo")
    params:add{
      type = "number",
      id = "tempo",
      name = "tempo",
      min = min_tempo,
      max = max_tempo,
      default = util.clamp(util.round(params:get("clock_tempo")), min_tempo, max_tempo),
      action = function(x)
        params:set("clock_tempo", x)
      end
    }

    install_tempo_change_handler()
  end)

  register_params("mutations", function()
    -- Probability-based mutations
    params:add_separator("strata_mutations", "mutations")

    params:add{
      type = "binary",
      id = "mutation_enabled",
      name = "mutations enabled",
      behavior = "toggle",
      default = 0,
      action = function(x)
        if x == 1 then
          S.mutation_metro:start()
        else
          S.mutation_metro:stop()
        end
      end
    }

    params:add{
      type = "control",
      id = "mutation_rate",
      name = "mutation rate",
      controlspec = controlspec.new(0.5, 10, "lin", 0.1, 2, "s"),
      action = function(x)
        S.mutation_metro.time = x
      end
    }

    params:add{
      type = "control",
      id = "mutation_probability",
      name = "mutation probability",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.15),
      action = function(x)
        -- Probability value used in gentle_mutate()
      end
    }

    params:add{
      type = "control",
      id = "mutation_amount",
      name = "mutation amount",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.25),
      action = function(x)
        -- Amount value used in gentle_mutate()
      end
    }
  end)

  register_params("scenes", function()
    -- Scene system
    params:add_separator("strata_scenes", "scenes")

    params:add{
      type = "binary",
      id = "scene_sequencer_enabled",
      name = "scene sequencer",
      behavior = "toggle",
      default = 0,
      action = function(x)
        if x == 1 then
          scene_sequencer_start()
        else
          scene_sequencer_stop()
        end
      end
    }

    params:add{
      type = "control",
      id = "scene_transition_time",
      name = "transition time",
      controlspec = controlspec.new(0, 30, "lin", 0.5, 2, "s"),
      action = function(x)
        -- Transition time used in scene recall
      end
    }

    params:add{
      type = "control",
      id = "scene_duration",
      name = "scene duration",
      controlspec = controlspec.new(4, 120, "lin", 1, 16, "s"),
      action = function(x)
        -- Time before advancing to next scene
      end
    }

    params:add{
      type = "number",
      id = "scene_sequence_length",
      name = "sequence length",
      min = 1,
      max = NUM_SCENES,
      default = 4,
      action = function(x)
        -- How many scenes to cycle through; the grid's scene page shows it
        grid_redraw()
      end
    }

    -- The sequencer's chances for its next scene (3.7, design §5.4): next,
    -- previous and random in percent, what is left a repeat. Read at each
    -- draw (lib/scenes.lua); PSET settings, never scene fields
    for _, chance in ipairs({{"next", 100}, {"previous", 0}, {"random", 0}}) do
      params:add{
        type = "number",
        id = "scene_chance_" .. chance[1],
        name = "chance " .. chance[1],
        min = 0,
        max = 100,
        default = chance[2],
        formatter = function(param) return param:get() .. "%" end,
      }
    end

    params:add_number("scene_confirm_seconds", "overwrite confirm (s)", 2, 20, 2)

    params:add{
      type = "trigger",
      id = "save_scenes",
      name = "save scenes to disk",
      action = function()
        save_scenes_to_disk()
      end
    }

    params:add{
      type = "trigger",
      id = "load_scenes",
      name = "load scenes from disk",
      action = function()
        -- with a scene of this session not on disk, the first trigger only
        -- arms (S.lib.scenes.request_load, #328)
        if S.lib.scenes.request_load() == "confirm" then
          print("scenes saved in this session are not on disk: trigger again within "
            .. S.lib.scenes.SCENE_LOAD.confirm_seconds .. " s to load the file over them")
        end
      end
    }
  end)

  register_params("fx", function()
    -- Effects chain: filter, delay, reverb and tape drift in one group, then
    -- the registered fx params (S.registry.fx_params). The group size must
    -- match the params below exactly.
    local fx_group_size = FX_GROUP_PARAMS
    for _, record in ipairs(S.registry.fx_params) do fx_group_size = fx_group_size + record.count end
    params:add_group("strata_fx", "fx", fx_group_size)

    params:add{
      type = "option",
      id = "filter_type",
      name = "filter type",
      options = {"lowpass", "highpass", "bandpass"},
      default = 1,
      action = function(x)
        note_param_edit("filter_type")
        send_param_to_engine("filter_type", x)
      end
    }

    params:add{
      type = "control",
      id = "filter_freq",
      name = "filter freq",
      controlspec = controlspec.new(20, 20000, "exp", 0, 5000, "Hz"),
      action = function(x)
        note_param_edit("filter_freq")
        send_param_to_engine("filter_freq", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "filter_res",
      name = "filter res",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
      action = function(x)
        note_param_edit("filter_res")
        send_param_to_engine("filter_res", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "filter_mix",
      name = "filter mix",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0),  -- 0 = bypass
      action = function(x)
        note_param_edit("filter_mix")
        -- a rise (E3, PARAMS, a scene, a PSET) is the mix K3 brings back
        filter_mix_moved(x)
        send_param_to_engine("filter_mix", x)
      end
    }

    params:add{
      type = "control",
      id = "delay_time",
      name = "delay time",
      controlspec = controlspec.new(0.01, 5.4, "exp", 0.001, 0.375, "s"),
      action = function(x)
        note_param_edit("delay_time")
        send_param_to_engine("delay_time", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "delay_feedback",
      name = "delay feedback",
      controlspec = controlspec.new(0, 0.95, "lin", 0.01, 0.4),
      action = function(x)
        note_param_edit("delay_feedback")
        send_param_to_engine("delay_feedback", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "delay_mix",
      name = "delay level",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0),
      action = function(x)
        note_param_edit("delay_mix")
        send_param_to_engine("delay_mix", x)
        fx_fader_changed()
      end
    }

    params:add{
      type = "control",
      id = "reverb_mix",
      name = "reverb level",
      -- 3.7's 0.3 / 0.7 (masterSum's gain), so a default start sounds as 3.7.0's
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.43),
      action = function(x)
        note_param_edit("reverb_mix")
        send_param_to_engine("reverb_mix", x)
      end
    }

    params:add{
      type = "control",
      id = "reverb_size",
      name = "reverb size",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.8),
      action = function(x)
        note_param_edit("reverb_size")
        send_param_to_engine("reverb_size", x)
      end
    }

    params:add{
      type = "control",
      id = "reverb_damp",
      name = "reverb damping",
      controlspec = controlspec.new(0, 1, "lin", 0.01, 0.5),
      action = function(x)
        note_param_edit("reverb_damp")
        send_param_to_engine("reverb_damp", x)
      end
    }

    params:add{
      type = "control",
      id = "drift_amount",
      name = "tape drift",
      controlspec = controlspec.new(0, 0.1, "lin", 0.001, 0.01),
      formatter = function(param) return string.format("%.3f", param:get()) end,
      action = function(x)
        note_param_edit("drift_amount")
        send_param_to_engine("drift_amount", x)
      end
    }

    for _, record in ipairs(S.registry.fx_params) do
      add_counted("fx params", record)
    end
  end)

  register_params("lfos", function()
    -- Global LFOs (their destinations, then the library's own groups)
    add_lfo_params()
  end)

  -- 3.4's groups, in menu order (design §0.1): each record calls its
  -- module's add_params, read at init, so a module included after this one
  -- has its table by then
  for _, group in ipairs({{"macros", "macros"}, {"morph", "morph"}, {"scatter", "scatter"}, {"matrix", "matrix"},
      {"input", "input_level"}, {"gestures", "gestures"}, {"rseq", "random_sequences"}}) do
    local module_name = group[2]
    register_params(group[1], function() S.lib[module_name].add_params() end)
  end

  -- 3.6's groups, in menu order (design §13): each record calls its
  -- module's add_params only when the module is loaded (each module's
  -- package adds its include), so a branch without it adds nothing
  for _, group in ipairs({{"out midi", "io_midi_out"}, {"crow", "io_crow"}, {"out ii", "io_ii"},
      {"out nb", "io_nb"}, {"tape", "io_tape"}}) do
    local module_name = group[2]
    register_params(group[1], function()
      if S.lib[module_name] then S.lib[module_name].add_params() end
    end)
  end

  -- strata_seq: the sequencer's add_params adds the group, its own params
  -- and, through S.lib.quantize.add_params, the quantizer's
  register_params("seq", function() S.lib.sequencer.add_params() end)

  register_params("buffers", function()
    -- Sample buffers: recording settings, then file/record/clear/save per
    -- slot. The group size must match the params below exactly.
    params:add_group("strata_buffers", "buffers", 2 + NUM_BUFFERS * 4)

    params:add{
      type = "control",
      id = "record_duration",
      name = "record duration",
      controlspec = controlspec.new(0.5, S.performance.buffer_seconds, "lin", 0.5, 8, "s")
    }

    params:add{
      type = "control",
      id = "record_level",
      name = "record level",
      controlspec = controlspec.new(0, 2, "lin", 0.01, 1)
    }

    for slot = 1, NUM_BUFFERS do
      S.lib.buffers.add_file_param(slot)
      params:add_trigger("buf" .. slot .. "_record", "buffer " .. slot .. " record")
      params:set_action("buf" .. slot .. "_record", function() record_buffer(slot) end)
      params:add_trigger("buf" .. slot .. "_clear", "buffer " .. slot .. " clear")
      params:set_action("buf" .. slot .. "_clear", function() clear_buffer(slot) end)
      params:add_trigger("buf" .. slot .. "_save", "buffer " .. slot .. " save")
      params:set_action("buf" .. slot .. "_save", function() save_buffer(slot) end)
    end
  end)

  register_params("record", S.lib.record.add_params)
  register_params("positions", function() S.lib.positions.add_params() end)

  register_params("midi", function()
    -- MIDI input (CC mapping is norns' own PARAMS > MAP). The group size must
    -- match the params below exactly.
    params:add_group("strata_midi", "midi", 6)

    params:add{
      type = "number",
      id = "midi_device",
      name = "midi device",
      min = 1,
      max = S.lib.io_ports.PORTS.count,  -- every norns port (#333), never a mod's facade's count (#700)
      default = 1,
      action = function(x)
        attach_midi(x)
        reset_midi_input()  -- the old port's note offs and bend returns will not arrive
        S.lib.mpe.reset_ranges()  -- another controller: its master bend range is its own (#688)
      end
    }

    params:add{
      type = "option",
      id = "midi_channel_mode",
      name = "midi channels",
      options = S.lib.midi_in.MIDI.channel_mode_options,
      default = 1,
      action = function()
        -- bends re-center and every MIDI note is released: the new mode routes the note offs elsewhere
        reset_midi_input()
      end
    }

    params:add{
      type = "option",
      id = "midi_note_off",
      name = "midi note off",
      options = S.lib.midi_in.MIDI.note_off_options,
      default = 1,
      -- every MIDI note is released, so no chord carries into the other behavior (ruling 37)
      action = function() reset_midi_input() end
    }

    -- 3.5's MPE settings (lib/mpe.lua): the member counts and the bend range
    S.lib.mpe.add_midi_params()
  end)

  -- 3.5's split zones: a zone and a note range per voice (lib/mpe.lua)
  register_params("zones", function() S.lib.mpe.add_params() end)

  -- The global scale and root grains and quantized voices snap to
  -- (lib/variation.lua), before the voices
  register_params("scale", function() S.lib.variation.add_scale_params() end)

  register_params("voices", function()
    -- Add params for each voice
    for i = 1, NUM_VOICES do
      add_voice_params(i)
    end
  end)

  -- Nearly every param is shown on a page or an arc ring, so every param
  -- action asks for a redraw: PARAMS edits, CC maps (PARAMS > MAP), pset
  -- loads, scene fades and mutations all arrive through them. Run once, after
  -- every param is added. Left out, as they are shown nowhere and change
  -- many times a second: text params (the LFO library writes each LFO's
  -- scaled and raw value into its own on every step) and the drift's 10 Hz
  -- writes (drift_update asks for the buffer positions it moves itself).
  function redraw_on_param_changes()
    for _, param in ipairs(params.params) do
      local action = param.action
      if param.t ~= params.tTEXT and type(action) == "function" then
        param.action = function(...)
          action(...)
          if not S.drift_writing then request_redraw() end
        end
      end
    end
  end

  -- A voice param's engine call runs only while the voice is running
  -- (a start sends everything: S.lib.engine_sync.start_voice); the send
  -- budget counts only the sends that reach the engine (#642)
  local function add_voice_sender(voice_idx, param_id, send, reaches)
    S.lib.engine_sync.add_voice_sender(voice_idx, param_id, send, reaches)
  end

  -- A voice param's value through its key's registered filter
  -- (S.registry.param_filters[key]), given the value stored before and
  -- whether this set is a turn of the param (S.turning_param, #318). A value
  -- the filter changes is written back to the param silently, so the param
  -- shows what is stored. The filter's result is what is stored, exactly,
  -- so a filter can recognize it as the next call's previous
  local function filtered_value(voice_idx, key, param_id, value, previous)
    local filter = S.registry.param_filters[key]
    if not filter then return value end
    local result = filter(voice_idx, value, previous, S.turning_param == param_id)
    if result ~= value then params:set(param_id, result, true) end
    return result
  end

  -- A filtered synthesis param's own delta is a turn: norns' PARAMS menu
  -- turns E3 with the param object's delta (core/menu/params.lua's
  -- delta_value), and params:delta calls it too, so neither passes
  -- delta_with_detent, which marks every other turn (#318)
  local function turn_on_own_delta(key, param_id)
    if not S.registry.param_filters[key] then return end
    local param = params:lookup_param(param_id)
    local own_delta = param.delta
    param.delta = function(self, d)
      S.lib.ui_detent.as_turn(param_id, function() own_delta(self, d) end)
    end
  end

  M.turn_on_own_delta = turn_on_own_delta

  -- Per voice, per record name: the keys its add and add_first added
  -- through add_voice_param ({key = true}), kept after init: the checks
  -- after each add, the fader check and a built-in record's scene keys
  -- (voice_scene_keys) read them
  local added_keys = {}
  for voice_idx = 1, NUM_VOICES do added_keys[voice_idx] = {} end

  -- The sender of a record's grain key or voice key (S.lib.state's
  -- shapes): setGrainParam with its engine name and value conversion,
  -- setVoiceParam likewise, or the entry's own send
  local function key_sender(voice_idx, grain_key, voice_key)
    if grain_key then
      return function(value)
        local name, sent = S.lib.engine_sync.grain_key_message(grain_key, value, voice_idx)
        engine.setGrainParam(voice_idx - 1, name, sent)
      end
    end
    if type(voice_key) == "table" and voice_key.send then
      return function(value) voice_key.send(voice_idx, value) end
    end
    return function(value)
      local name, sent = S.lib.engine_sync.grain_key_message(voice_key, value, voice_idx)
      engine.setVoiceParam(voice_idx - 1, name, sent)
    end
  end

  -- Add one param of a voice-param record (S.registry.voice_params, the
  -- built-in synth, grain and crossmod records among them) for voice
  -- voice_idx: param is a params:add table without an id; the id is
  -- v<i>_<key>. Its action runs the key's param filter, stores the value
  -- in S.voices[i].values[key], ends a randomize's undo, sends it through
  -- send_param_to_engine and then runs param.action, if any. A key in
  -- record.grain_keys or the voice's record.voice_keys gets the engine
  -- sender (key_sender), only while the voice runs. Called by the record's
  -- add, at init
  function M.add_voice_param(voice_idx, record, key, param)
    if type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES or voice_idx % 1 ~= 0 then
      error("add_voice_param: voice " .. tostring(voice_idx) .. " is not 1.." .. NUM_VOICES, 2)
    end
    if type(record) ~= "table" or type(record.name) ~= "string" then
      error("add_voice_param: a registered record is needed", 2)
    end
    if type(key) ~= "string" or not key:match("^[%w_]+$") then
      error("add_voice_param " .. record.name .. ": key " .. tostring(key) .. " is not a param id suffix", 2)
    end
    if type(param) ~= "table" or param.id ~= nil then
      error("add_voice_param " .. record.name .. ": a params:add table without an id", 2)
    end
    local param_id = "v" .. voice_idx .. "_" .. key
    local own_action = param.action
    local args = {}
    for field, value in pairs(param) do args[field] = value end
    args.id = param_id
    args.action = function(x)
      local values = S.voices[voice_idx].values
      if args.type == "number" then x = pset.whole(param_id, x) end  -- (the mod sources, the custom intervals, #554)
      x = filtered_value(voice_idx, key, param_id, x, values[key])
      values[key] = x
      note_param_edit(param_id)  -- an edit ends a randomize's undo
      send_param_to_engine(param_id, x)
      S.lib.sequencer.param_set(voice_idx, param_id)  -- #1047: a set ends a held step value on it
      if own_action then own_action(x) end
    end
    params:add(args)
    S.voices[voice_idx].values[key] = params:get(param_id)

    local grain_key = record.grain_keys and record.grain_keys[key]
    local voice_key = S.voice_keys_of(record, voice_idx)[key]
    -- 3.8: a record's reaches gates the sender (the synth record's: only
    -- while the voice's type has the key)
    local reaches = record.reaches and function() return record.reaches(voice_idx, key) end
    if grain_key or voice_key then
      add_voice_sender(voice_idx, param_id, key_sender(voice_idx, grain_key, voice_key), reaches)
    end
    local added = added_keys[voice_idx]
    added[record.name] = added[record.name] or {}
    added[record.name][key] = true
  end

  -- A per-voice param's stored value (#951): a registered voice param's
  -- S.voices[i].values[key], the type's index (S.lib.types.of) or the
  -- source; nil for any other param
  local function voice_stored_value(param_id)
    local voice_idx, key = tostring(param_id):match("^v(%d+)_(.+)$")
    local voice = S.voices[tonumber(voice_idx)]
    if not voice then return nil end
    if key == "type" then return S.lib.types.of(tonumber(voice_idx)).index end
    if key == "source" then return voice.source end
    for _, keys in pairs(added_keys[tonumber(voice_idx)]) do
      if keys[key] then return voice.values[key] end
    end
    return nil
  end

  -- The sequencer loads later. Register here so its read follows the scenes'
  -- side file and the engine and voice hooks still run last.
  S.register_pset_hook({name = "seq_chain", read = function(_, _, _, silent)
    if silent then S.lib.sequencer.reconcile_chain() end
  end})

  -- After a silent PSET read the engine follows every param too (#965,
  -- decided 2026-11-23): each engine sender whose params the read changed
  -- is sent once, through the param's own sender. SILENT_READ.same_send:
  -- the senders that only run another id's (lib/delay_sync.lua's three run
  -- delay_time's: one setDelay for all six)
  local SILENT_READ = {same_send = {delay_sync = "delay_time", delay_division = "delay_time",
    delay_pingpong = "delay_time"}}

  -- Whether the engine params' hook follows param: one with an engine
  -- sender that a PSET loads (M.load_default: never a trigger or a param
  -- saved off), but a per-voice param (the voice_params hook's), scatter's
  -- (its own hook sends setScatter after every silent read) and a macro's
  -- (its sender is an LFO's move of the targets' engine values, never a
  -- send of the macro: the targets' own lines load them)
  local function engine_follows(param)
    local id = param.id
    if type(id) ~= "string" or S.engine_senders[id] == nil or M.load_default(param) == nil then return false end
    if voice_stored_value(id) ~= nil or S.engine_senders[id] == S.engine_senders.scatter then return false end
    return not id:match("^macro_%d+$")
  end

  -- The value the engine has for param: what its sender last sent (or holds
  -- back: expected_value), else its start, the load default, as no start
  -- step sends a param that is not a voice's: as the param holds it (a
  -- control keeps its raw position, so its default reads back through the
  -- controlspec, 5000 Hz as 4999.9999999999973)
  local function engine_has(param)
    local sync = S.lib.engine_sync
    local value = sync.expected_value(param.id)
    if value ~= nil then return value end
    local default = M.load_default(param)
    if param.t == params.tCONTROL then default = param.controlspec:map(param.controlspec:unmap(default)) end
    return sync.with_lfo_offsets(param.id, default)
  end

  -- The hook (registered before voice_params, the last): every followed
  -- param whose value, as modulated, is not what the engine has joins its
  -- sender's group; each group's values are recorded as sent and the
  -- sender runs once (send_param_to_engine of its first id: a command of
  -- several params reads the others through engine_param_value;
  -- S.lib.engine_sync.record_as_sent, which drops a waiting value too), in param
  -- order, after fx_hold's release of a freeze the read left bypassed. The
  -- filter's restore mix follows as filter_mix's action has it. The scale
  -- keeps no record of what the engine has (the controller's ruling: one
  -- message is cheaper than a second record), so it is sent every time, as
  -- the scale's and the root's actions send it: setScale, the quantized
  -- voices' stored freqs snapped (#995, as the tuning's hook snaps them),
  -- each running
  -- voice's scaleNote and each running chord's intervals, once a read and
  -- only if they changed (the tuning's hook, which sends the tuning, leaves
  -- the chords here; a voice whose interval set the read changed gets its
  -- list from voice_params' action instead; S.lib.arp.send_if_changed
  -- compares with the list the engine was last sent, #994)
  S.register_pset_hook({name = "engine_params", read = function(path_base, number, pset_path, silent)
    if not silent then return end
    local sync, groups = S.lib.engine_sync, {}
    for _, param in ipairs(params.params) do
      if engine_follows(param) then
        local value = sync.with_lfo_offsets(param.id, params:get(param.id))
        if value ~= engine_has(param) then
          local sender = S.engine_senders[SILENT_READ.same_send[param.id] or param.id]
          local group = groups[sender]
          if not group then
            group = {}
            groups[sender] = group
            groups[#groups + 1] = group
          end
          group[#group + 1] = {id = param.id, value = value}
        end
      end
    end
    for _, group in ipairs(groups) do
      for _, changed in ipairs(group) do sync.record_as_sent(changed.id, changed.value) end
      send_param_to_engine(group[1].id, params:get(group[1].id))
    end
    if params:get("filter_mix") ~= filter_mix_before then filter_mix_moved(params:get("filter_mix")) end
    local variation = S.lib.variation
    variation.send_scale()
    -- the scale's and the root's actions snap every quantized voice's
    -- stored freq ahead of the voices' lines (#995): snapped here, then
    -- each freq the read left goes back, silently, for voice_params to set
    -- through its filter, as the tuning's hook does (lib/tuning.lua)
    local read_freqs = {}
    for voice_idx = 1, NUM_VOICES do read_freqs[voice_idx] = params:get("v" .. voice_idx .. "_freq") end
    variation.snap_quantized_freqs()
    for voice_idx, freq in ipairs(read_freqs) do
      local id = "v" .. voice_idx .. "_freq"
      if params:get(id) ~= freq then params:set(id, freq, true) end
    end
    for voice_idx = 1, NUM_VOICES do
      variation.send_scale_note(voice_idx)
      local intervals = S.voices[voice_idx].values.intervals
      if intervals == variation.VARIATION.set_index.chord and params:get("v" .. voice_idx .. "_intervals") == intervals then
        S.lib.arp.send_if_changed(voice_idx)
      end
    end
  end})

  -- After a silent PSET read (#951, the controller's rulings 1 and 2), the
  -- per-voice params end where a read with actions of the file leaves
  -- them: the read set them without their actions, so each whose stored
  -- value differs from what the read left goes back silently to its stored
  -- value, and then each per-voice param that does not hold the read's
  -- value (put back, or moved by an earlier one's action) is set to it,
  -- with its action, in param order (a type and a source ahead of their
  -- voice's other params; one left alone is never set again, since a
  -- control's set of its own value can land a step of rounding away and
  -- run its action): the read's own sets, so an action that reads
  -- another param's stored value (quantize's snap reads the freq, a loop
  -- start's cut the length) sees what it sees in a read with actions. The
  -- last hook (this module is included after every other that registers
  -- one); a read with actions has run every action already
  S.register_pset_hook({name = "voice_params", read = function(path_base, number, pset_path, silent)
    if not silent then return end
    local read = {}
    for _, param in ipairs(params.params) do
      local stored = voice_stored_value(param.id)
      if stored ~= nil then
        local value = params:get(param.id)
        read[#read + 1] = {id = param.id, value = value}
        if stored ~= value then params:set(param.id, stored, true) end
      end
    end
    for _, entry in ipairs(read) do
      if params:get(entry.id) ~= entry.value then params:set(entry.id, entry.value) end
    end
  end})

  -- Per record name: how many params its add_first added for the voice
  -- being added (counted with its add's)
  local first_added = {}

  -- Each record's add_first for voice voice_idx, ahead of the voice's
  -- synth params: norns reads a PSET line by line in param order, so a
  -- param a built-in param's filter reads (variation's quantize, read by the
  -- freq filter) must come first, or the filter would apply the current
  -- value, not the PSET's, to the built-in param (#125)
  local function add_first_voice_params(voice_idx)
    for _, record in ipairs(S.registry.voice_params) do
      added_keys[voice_idx][record.name] = {}
      first_added[record.name] = 0
      if record.add_first then
        local before = #params.params
        record.add_first(voice_idx)
        first_added[record.name] = #params.params - before
      end
    end
  end

  -- The keys a record's group (fader, main_randomize, mutate) gives for a voice
  function M.group_keys(group, voice_idx)
    if type(group.keys) == "function" then return group.keys(voice_idx) end
    return group.keys
  end

  -- After a record's add for voice voice_idx: it added exactly its count
  -- (with its add_first's), and every key it names (grain and voice keys,
  -- scene keys, discrete keys, rows) is one of its params; a discrete key
  -- of a record without scene defaults (a built-in one) has its param's
  -- default inside its range
  local function check_record(voice_idx, record, added)
    local count = S.voice_param_count(record, voice_idx)
    if added ~= count then
      error(string.format("voice params %s: add%s added %d params for voice %d, but its count is %d", record.name,
        record.add_first and " and add_first" or "", added, voice_idx, count), 0)
    end
    local own = added_keys[voice_idx][record.name]
    local named = {record.grain_keys or {}, S.voice_keys_of(record, voice_idx), S.voice_scene_defaults(record, voice_idx),
      record.discrete or {}}
    for _, keys in ipairs(named) do
      for key in pairs(keys) do
        if not own[key] then error("voice params " .. record.name .. ": " .. key .. " is not a param its add added", 0) end
      end
    end
    local rows = record.voice_rows and record.voice_rows.rows or {}
    if type(rows) == "function" then rows = rows(voice_idx) end  -- the voice's rows at init
    for _, key in ipairs(rows) do
      if not own[key] then error("voice params " .. record.name .. ": row " .. key .. " is not a param its add added", 0) end
    end
    local scene_keys = record.scene_keys
    if type(scene_keys) == "function" then scene_keys = scene_keys(voice_idx) end
    if type(scene_keys) == "table" then
      for _, key in ipairs(scene_keys) do
        if not own[key] then error("voice params " .. record.name .. ": scene key " .. key .. " is not a param its add added", 0) end
      end
    end
    if record.scene_defaults ~= nil then return end
    for key, range in pairs(record.discrete or {}) do
      local default = param_default("v" .. voice_idx .. "_" .. key)
      if default % 1 ~= 0 or default < range[1] or default > range[2] then
        error("voice params " .. record.name .. ": " .. key .. "'s default is outside its discrete range", 0)
      end
    end
  end

  -- Every key a record's fader groups give for voice voice_idx (whatever
  -- their when) is a param some record added for the voice
  local function check_faders(voice_idx)
    local added = {}
    for _, keys in pairs(added_keys[voice_idx]) do
      for key in pairs(keys) do added[key] = true end
    end
    for _, record in ipairs(S.registry.voice_params) do
      for _, group in ipairs(record.fader or {}) do
        for _, key in ipairs(M.group_keys(group, voice_idx)) do
          if not added[key] then
            error("voice params " .. record.name .. ": fader key " .. tostring(key) .. " is no param of voice "
              .. voice_idx, 0)
          end
        end
      end
    end
  end

  -- A voice's params: its heading, every record's add_first, then each
  -- record's add in registration order (the built-in synth, grain and
  -- crossmod first), each record under its separator: a separator
  -- "voice <i> <separator>" (nil: "extras") before a record whose separator
  -- differs from the record's before it, none for false (the synth params
  -- sit under the heading). Separators are outside a record's count
  function add_voice_params(voice_idx)
    -- 3.8 (ruling 19): a record whose count, voice_keys or scene_defaults
    -- is a function of the voice is checked now, at init
    for _, record in ipairs(S.registry.voice_params) do
      if type(record.count) == "function" or type(record.voice_keys) == "function"
        or type(record.scene_defaults) == "function" then
        S.check_voice_params(record, voice_idx, 0)
      end
    end
    -- the heading names the voice's own type (its id stays this text; the
    -- v<i>_type action renames it)
    params:add_separator("voice " .. voice_idx .. ": " .. tostring(S.lib.types.default_key(voice_idx)))
    add_first_voice_params(voice_idx)
    local previous = false
    for _, record in ipairs(S.registry.voice_params) do
      local separator = record.separator
      if separator == nil then separator = "extras" end
      if separator ~= previous and separator ~= false then
        params:add_separator("voice " .. voice_idx .. " " .. separator)
      end
      previous = separator
      local before = #params.params
      record.add(voice_idx)
      check_record(voice_idx, record, first_added[record.name] + #params.params - before)
    end
    check_faders(voice_idx)
  end

  -- A copy of a synthesis param's spec, its voice type records' one spec
  -- (S.lib.types.spec, 3.8: the records hold them); a name no type has is
  -- an error, so a param never gets a 0-1 range unseen (#315). Units and
  -- decimals are display only (#386, #387)
  function get_param_spec(param_name)
    local found, spec = pcall(S.lib.types.spec, param_name)
    if not found then error("get_param_spec: no spec for " .. tostring(param_name), 2) end
    return spec
  end

  -- A voice's engine parts (the groundwork before 3.8, rulings 5 and 11):
  -- what a start and a sync send, which lib/engine_sync.lua sends. A part
  -- is {name, kept = {entry, ...}, voice_level = {entry, ...}}: kept
  -- entries are setGrainParam messages and a record's sync, which the
  -- engine keeps for a stopped voice (a start sends them before voiceOn);
  -- voice_level entries are the controls voiceOn resets (a start sends
  -- them after it). An entry has key (the voice's value it sends; absent
  -- for a keyless send) and exactly one of grain = engine name
  -- (setGrainParam), voice = engine name (setVoiceParam) or send =
  -- fn(voice_idx, value); value = fn(x, voice_idx) converts the value, and carry =
  -- false sends the stored value at a start, never the param's override
  -- and offsets. One part per record (S.registry.voice_params), in
  -- registration order: its grain keys (kept) and voice keys
  -- (voice_level), each in its send_order (default sorted), its sync last
  -- in kept; the bend part follows the crossmod record's. The built-in
  -- records come first, so the parts begin synth (the synth keys, sorted),
  -- grain (the nine, in their fixed order), crossmod (per slot its source
  -- and amounts, then the speed), bend. Every call builds fresh tables, so
  -- a caller may change what it gets

  -- the MIDI pitchbend wheel's current position (voiceOn resets the engine's to 1)
  local function send_bend(voice_idx)
    engine.setVoiceParam(voice_idx - 1, "bend", S.midi_state.bend[voice_idx])
  end

  -- A record's keys of one kind ({key = entry}) in its send_order, or sorted
  local function in_send_order(record, keys)
    local ordered = {}
    if record.send_order then
      for _, key in ipairs(record.send_order) do
        if keys[key] ~= nil then ordered[#ordered + 1] = key end
      end
      return ordered
    end
    for key in pairs(keys) do ordered[#ordered + 1] = key end
    table.sort(ordered)
    return ordered
  end

  -- A part entry for a grain key (kind "grain") or a voice key ("voice")
  local function part_entry(kind, key, spec)
    if type(spec) == "string" then return {key = key, [kind] = spec} end
    if spec.send then return {key = key, send = spec.send, carry = spec.carry} end
    return {key = key, [kind] = spec.name, value = spec.value, carry = spec.carry}
  end

  function M.voice_engine_parts(voice_idx)
    if type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES or voice_idx % 1 ~= 0 then
      error("voice_engine_parts: voice " .. tostring(voice_idx) .. " is not 1.." .. NUM_VOICES, 2)
    end
    local parts = {}
    for _, record in ipairs(S.registry.voice_params) do
      local grain_keys, voice_keys = record.grain_keys or {}, S.voice_keys_of(record, voice_idx)
      -- 3.8: a key the record's reaches refuses now is left out (the synth
      -- part is the voice's current type's keys)
      local function reaches(key) return record.reaches == nil or record.reaches(voice_idx, key) end
      local kept, voice_level = {}, {}
      for _, key in ipairs(in_send_order(record, grain_keys)) do
        if reaches(key) then kept[#kept + 1] = part_entry("grain", key, grain_keys[key]) end
      end
      if record.sync then kept[#kept + 1] = {send = function(index) record.sync(index) end} end
      for _, key in ipairs(in_send_order(record, voice_keys)) do
        if reaches(key) then voice_level[#voice_level + 1] = part_entry("voice", key, voice_keys[key]) end
      end
      parts[#parts + 1] = {name = record.name, kept = kept, voice_level = voice_level}
      if record.name == "crossmod" then parts[#parts + 1] = {name = "bend", kept = {}, voice_level = {{send = send_bend}}} end
    end
    return parts
  end

  -- A voice's scene keys (the groundwork before 3.8, rulings 4 and 5; 3.8,
  -- package 0d: a type's): list, the entries {key, default, range, limits,
  -- synth} in recall order, and by_key, the same entries by key, for the
  -- type type_key (nil: the voice's current type). A record with
  -- scene_keys (the built-in synth, grain and crossmod) has those keys
  -- (true: every value its add added for the voice, the grain record's
  -- source being no value; a function: what it gives for the voice and the
  -- type key, the synth record's that type's keys, none for a type this
  -- build lacks), each default its param's (param_default, read at the
  -- call, after init), a synth_keys record's (the synth record's: the
  -- type's keys) marked synth = true (#840: the field, never the name); another
  -- record's are its scene_defaults' keys. The order: each scene_keys
  -- record's keys sorted, in registration order (synth, grain, crossmod),
  -- then every other record's scene keys sorted together, so a recall sets
  -- freq before freeze and loop_length before loop_start. range {min, max}
  -- marks a discrete key (the record's discrete: the grain mode and
  -- cloud, the mod sources, ...), limits a record's scene_ranges. solo and
  -- note_cap are no scene keys (their records give no scene_defaults)
  -- A scene_keys record's keys for the voice and type, sorted
  local function record_scene_keys(record, voice_idx, type_key)
    local keys, given = {}, record.scene_keys
    if given == true then
      for key in pairs(added_keys[voice_idx][record.name] or {}) do keys[#keys + 1] = key end
    else
      if type(given) == "function" then given = given(voice_idx, type_key) end
      for index, key in ipairs(given) do keys[index] = key end
    end
    table.sort(keys)
    return keys
  end

  function M.voice_scene_keys(voice_idx, type_key)
    if type(voice_idx) ~= "number" or voice_idx < 1 or voice_idx > NUM_VOICES or voice_idx % 1 ~= 0 then
      error("voice_scene_keys: voice " .. tostring(voice_idx) .. " is not 1.." .. NUM_VOICES, 2)
    end
    local prefix = "v" .. voice_idx .. "_"
    local list, by_key = {}, {}
    local function add(key, default, record)
      local entry = {key = key, default = default, range = record.discrete and record.discrete[key],
        limits = record.scene_ranges and record.scene_ranges[key], synth = record.synth_keys or nil}
      list[#list + 1] = entry
      by_key[key] = entry
    end
    local registered, records = {}, {}
    for _, record in ipairs(S.registry.voice_params) do
      if record.scene_keys ~= nil then
        for _, key in ipairs(record_scene_keys(record, voice_idx, type_key)) do
          add(key, param_default(prefix .. key), record)
        end
      else
        for key, default in pairs(S.voice_scene_defaults(record, voice_idx)) do
          registered[#registered + 1] = key
          records[key] = {record = record, default = default}
        end
      end
    end
    table.sort(registered)
    for _, key in ipairs(registered) do add(key, records[key].default, records[key].record) end
    return list, by_key
  end

  return M
end
