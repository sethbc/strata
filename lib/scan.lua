-- lib/scan.lua
-- A buffer voice's scan modes and tempo follow (3.7 design §2.3, §2.4,
-- decision 3; S.lib.scan): the voice-param record scan, with v<i>_scan_mode
-- (wrap, bounce, one shot: the engine's scanMode, the index less 1) and
-- v<i>_follow (off, stretch, repitch), two discrete scene fields and rows in
-- a buffer voice's synth section. A following voice reading a slot whose
-- file has a tempo (S.lib.samples.tempo) scales its scan by ratio = clock
-- tempo / file tempo (an engine factor on v<i>_buf_scan), and under repitch
-- its read rate too (followRate, clamped to FOLLOW.rate_min-rate_max): the
-- LFO clock's step hook sends a ratio that moved by more than
-- FOLLOW.ratio_threshold, and once a bar syncs the engine's scan to the
-- playhead (engine.syncScan: only this module calls it). pass_seconds tells
-- a one-shot note how long its region plays. The follow rate is worked out,
-- never a param, a scene field or a PSET value. See docs/notes/lua/scan.md.

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local FOLLOW = S.constants.FOLLOW
  M.FOLLOW = FOLLOW

  -- The record's names: its param keys, their options and VOICE section,
  -- the engine's grain params and the factor's key on v<i>_buf_scan
  M.SCAN = {
    mode_key = "scan_mode", follow_key = "follow", section = "synth",
    modes = {"wrap", "bounce", "one shot"}, follows = {"off", "stretch", "repitch"},
    mode_engine = "scanMode", rate_engine = "followRate", factor_key = "follow",
  }
  local SCAN = M.SCAN
  -- scan_mode's and follow's option indices
  M.MODE = {wrap = 1, bounce = 2, one_shot = 3}
  local MODE = M.MODE
  local FOLLOWS = {off = 1, stretch = 2, repitch = 3}

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx >= 1 and voice_idx <= NUM_VOICES and voice_idx % 1 == 0
  end

  local function param_id(voice_idx, key) return "v" .. voice_idx .. "_" .. key end

  -- The send keys of a voice's follow rate and bar sync: each holds a
  -- space, so no param id can be one, and starts "v<i>_", so a voice's
  -- sync and start drop a value of theirs still waiting for the budget
  -- (lib/engine_sync.lua's forget_sent_voice_values). Their engine senders
  -- are below
  local function rate_key(voice_idx) return "v" .. voice_idx .. "_follow rate" end
  local function sync_key(voice_idx) return "v" .. voice_idx .. "_scan sync" end

  local function finite_positive(value)
    return type(value) == "number" and value == value and value > 0 and value < math.huge
  end

  -- A voice's scan mode, an index of SCAN.modes (wrap for any other voice)
  function M.mode(voice_idx)
    if not valid_voice(voice_idx) then return MODE.wrap end
    return params:get(param_id(voice_idx, SCAN.mode_key))
  end

  local function follow_of(voice_idx) return params:get(param_id(voice_idx, SCAN.follow_key)) end

  -- The file tempo of the slot a voice reads (S.lib.samples.tempo), nil
  -- for none
  local function file_tempo(voice_idx)
    local tempo = S.lib.samples.tempo(voice_buffer_slot(voice_idx))
    if finite_positive(tempo) then return tempo end
    return nil
  end

  -- The clock's tempo for timing (60 / beat_seconds_now, as the clocked
  -- LFOs and the synced delay read it), nil for one that gives no length
  local function clock_tempo()
    local tempo = 60 / S.lib.params_setup.beat_seconds_now()
    if finite_positive(tempo) then return tempo end
    return nil
  end

  -- Whether a voice follows the tempo: a buffer voice whose follow is not
  -- off, reading a slot whose file has a tempo
  function M.following(voice_idx)
    return valid_voice(voice_idx) and voice_uses_buffer(voice_idx) and follow_of(voice_idx) ~= FOLLOWS.off
      and file_tempo(voice_idx) ~= nil and clock_tempo() ~= nil
  end

  -- clock tempo / file tempo for a following voice, else 1
  function M.ratio(voice_idx)
    if not M.following(voice_idx) then return 1 end
    return clock_tempo() / file_tempo(voice_idx)
  end

  -- The read rate's factor: the ratio clamped to rate_min-rate_max under
  -- repitch, else 1
  function M.rate(voice_idx)
    if not M.following(voice_idx) or follow_of(voice_idx) ~= FOLLOWS.repitch then return 1 end
    return util.clamp(M.ratio(voice_idx), FOLLOW.rate_min, FOLLOW.rate_max)
  end

  -- The seconds a one-shot voice takes to cross fraction of its slot's
  -- valid region: fraction x the slot's seconds / |scan|, the scan as the
  -- engine has it (engine_param_value: its follow factor included). nil
  -- unless the voice reads a buffer in one shot with a scan that is not 0
  function M.pass_seconds(voice_idx, fraction)
    if not valid_voice(voice_idx) or not voice_uses_buffer(voice_idx) or type(fraction) ~= "number" then return nil end
    if M.mode(voice_idx) ~= MODE.one_shot then return nil end
    local scan = engine_param_value(param_id(voice_idx, "buf_scan"))
    if type(scan) ~= "number" or scan == 0 then return nil end
    local slot = voice_buffer_slot(voice_idx)
    local seconds = S.buffers[slot] and S.buffers[slot].seconds or 0
    return fraction * seconds / math.abs(scan)
  end

  -- What each voice's engine was last given: its scan factor and its rate
  local applied = {}
  for voice_idx = 1, NUM_VOICES do applied[voice_idx] = {ratio = 1, rate = 1} end

  local function send_rate(voice_idx)
    S.lib.engine_sync.send_engine_value(rate_key(voice_idx), M.rate(voice_idx))
  end

  -- A value that moved by more than ratio_threshold of itself from the one
  -- last given, or that came back to 1 (at once, exactly)
  local function moved(value, last)
    return math.abs(value - last) > FOLLOW.ratio_threshold * value or (value == 1 and last ~= 1)
  end

  -- Give a voice's engine its ratio (the factor on buf_scan, which resends
  -- the scan) and its rate when they moved: the rate at once (a follow
  -- change) or through the round robin (the step hook)
  local function settle(voice_idx, at_once)
    local ratio, rate, last = M.ratio(voice_idx), M.rate(voice_idx), applied[voice_idx]
    if moved(ratio, last.ratio) then
      last.ratio = ratio
      S.lib.engine_sync.set_engine_factor(SCAN.factor_key, param_id(voice_idx, "buf_scan"), ratio)
    end
    if moved(rate, last.rate) then
      last.rate = rate
      if at_once then
        send_rate(voice_idx)
      else
        S.lib.lfos.mark_due(rate_key(voice_idx), function() send_rate(voice_idx) end)
      end
    end
  end

  -- The bar sync's voices: running, following, in wrap or bounce, with no
  -- scan hold, no glide and no freeze (design §2.4)
  local function syncable(voice_idx)
    return S.voices[voice_idx].active and M.following(voice_idx) and M.mode(voice_idx) ~= MODE.one_shot
      and not S.lib.positions.scan_held(voice_idx) and S.lib.positions.scrub_rate(voice_idx) == 0
      and not S.lib.freeze.is_frozen(voice_idx)
  end

  local function send_sync(voice_idx)
    local phase = S.lib.playheads.phase(voice_idx)
    if phase then S.lib.engine_sync.send_engine_value(sync_key(voice_idx), phase) end
  end

  -- The bar the beat was in at the last step (nil before the first)
  local last_bar
  local function bar_sync()
    local bar = math.floor(clock.get_beats() / FOLLOW.bar_beats)
    local crossed = last_bar ~= nil and bar ~= last_bar
    last_bar = bar
    if not crossed then return end
    for voice_idx = 1, NUM_VOICES do
      if syncable(voice_idx) then
        S.lib.lfos.mark_due(sync_key(voice_idx), function() send_sync(voice_idx) end)
      end
    end
  end

  -- Every LFO step: each voice's ratio and rate, inside deferrable (a
  -- moved ratio's scan, like the rate, waits for the budget when the
  -- window is full: design §2.4, "marked due"), then the bar sync
  S.lib.lfos.on_step(function()
    S.lib.engine_sync.deferrable(function()
      for voice_idx = 1, NUM_VOICES do settle(voice_idx, false) end
    end)
    bar_sync()
  end)

  -- A voice whose source changes (a user's switch, running or stopped; a
  -- running voice's grain restart, a scene's switch included) settles at
  -- once: one that leaves its buffer stops following before its sync sends
  -- the scan, and none starts with an old factor
  S.register_source_change(function(voice_idx) settle(voice_idx, true) end)
  S.register_grain_restart(function(voice_idx) settle(voice_idx, true) end)

  -- The senders, each sending only while its voice runs
  for voice_idx = 1, NUM_VOICES do
    S.lib.engine_sync.add_voice_sender(voice_idx, rate_key(voice_idx), function(rate)
      engine.setGrainParam(voice_idx - 1, SCAN.rate_engine, rate)
    end)
    S.lib.engine_sync.add_voice_sender(voice_idx, sync_key(voice_idx), function(phase)
      engine.syncScan(voice_idx - 1, phase)
    end)
  end

  local function buffer_voice(voice_idx) return valid_voice(voice_idx) and voice_uses_buffer(voice_idx) end

  -- VOICE's layout tests and page renders: each voice on buffer 1, the
  -- cursor on its follow row
  local layout_states = {}
  for voice_idx = 1, NUM_VOICES do
    table.insert(layout_states, {
      name = string.format("v%d buffer follow", voice_idx),
      setup = function()
        S.selected_voice = voice_idx
        params:set(param_id(voice_idx, "source"), S.constants.SOURCE_SYNTH + 1)
        S.lib.pages_voice.place_cursor(S.lib.pages_voice.row_of(param_id(voice_idx, SCAN.follow_key)))
      end,
    })
  end

  local record
  record = {
    name = "scan",
    count = 2,
    add = function(voice_idx)
      -- the engine's mode change never restarts its scan: the restart
      -- follows the mode (S.lib.positions, so the playhead restarts too)
      S.lib.params_setup.add_voice_extra(voice_idx, record, SCAN.mode_key, {
        type = "option",
        name = "scan mode",
        options = SCAN.modes,
        default = MODE.wrap,
        action = function() S.lib.positions.restart_scan(voice_idx) end,
      })
      -- a voice that stops following gets its factor and rate back at once
      S.lib.params_setup.add_voice_extra(voice_idx, record, SCAN.follow_key, {
        type = "option",
        name = "follow",
        options = SCAN.follows,
        default = FOLLOWS.off,
        action = function() settle(voice_idx, true) end,
      })
    end,
    grain_keys = {
      [SCAN.mode_key] = {name = SCAN.mode_engine, value = function(option) return option - 1 end},
    },
    -- every voice sync carries the follow rate
    sync = function(voice_idx)
      local rate = M.rate(voice_idx)
      applied[voice_idx].rate = rate
      engine.setGrainParam(voice_idx - 1, SCAN.rate_engine, rate)
    end,
    scene_defaults = {[SCAN.mode_key] = MODE.wrap, [SCAN.follow_key] = FOLLOWS.off},
    discrete = {[SCAN.mode_key] = {1, #SCAN.modes}, [SCAN.follow_key] = {1, #SCAN.follows}},
    voice_rows = {
      section = SCAN.section,
      rows = {SCAN.mode_key, SCAN.follow_key},
      when = function(voice_idx) return buffer_voice(voice_idx) end,
    },
    layout_states = layout_states,
    fader = false,
  }
  S.register_voice_params(record)

  return M
end
