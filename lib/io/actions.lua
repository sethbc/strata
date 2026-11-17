-- lib/io/actions.lua
-- The shared actions (S.lib.io_actions): what crow's trigger inputs, OSC's
-- addresses and a Teletype's calls run. Each returns true when it acted; for
-- anything out of range it does nothing, returns false and prints one line,
-- "strata: <action> ignored: <why>". Voice 0 is the selected voice.
-- Notes: docs/notes/lua/io/actions.md

return function(S)
  local M = {}

  local NUM_VOICES, NUM_SCENES = S.constants.NUM_VOICES, S.constants.NUM_SCENES
  local NUM_MACROS = S.constants.NUM_MACROS

  local function ignored(action, why)
    print("strata: " .. action .. " ignored: " .. why)
    return false
  end

  local function whole(value)
    return type(value) == "number" and value == math.floor(value)
  end

  -- A voice number 1..NUM_VOICES, or the selected voice for 0; nil if out of range
  local function resolve_voice(voice)
    if voice == 0 then voice = S.selected_voice end
    if whole(voice) and voice >= 1 and voice <= NUM_VOICES then return voice end
    return nil
  end

  local function saved(n)
    return S.scenes[n] ~= nil and S.scenes[n].populated == true
  end

  -- What a mode 0 / 1 / 2 (off, on, toggle) asks of a thing that is `now`
  -- on: true or false, or nil for another mode
  local function wanted(mode, now)
    if mode == 0 then return false end
    if mode == 1 then return true end
    if mode == 2 then return not now end
    return nil
  end

  -- Scheduled as a scene key schedules it (the quantizer's "scene" action,
  -- with the scene transition time)
  function M.recall_scene(n)
    if not whole(n) or n < 1 or n > NUM_SCENES then
      return ignored("recall_scene", "scene " .. tostring(n) .. " is not 1 to " .. NUM_SCENES)
    end
    if not saved(n) then return ignored("recall_scene", "scene " .. n .. " is empty") end
    local transition_time = params:get("scene_transition_time")
    S.lib.quantize.schedule("scene", function() recall_scene(n, transition_time) end, "S" .. n)
    return true
  end

  -- The playable scene after the current one, through the stepper at 100,
  -- 0, 0 (no draw): an empty or invalid slot is passed over
  function M.next_scene()
    local scenes = S.lib.scenes
    local n = scenes.next_slot(S.current_scene, scenes.playable_slots(1, NUM_SCENES), {100, 0, 0})
    if n == nil then return ignored("next_scene", "no scene is saved") end
    return M.recall_scene(n)
  end

  function M.run_voice(voice, mode)
    local v = resolve_voice(voice)
    if not v then return ignored("run_voice", "voice " .. tostring(voice) .. " is not 0 to " .. NUM_VOICES) end
    local running = S.voices[v].active and true or false
    local want = wanted(mode, running)
    if want == nil then return ignored("run_voice", "mode " .. tostring(mode) .. " is not 0, 1 or 2") end
    if want ~= running then toggle_voice(v) end
    return true
  end

  -- An accent on a running voice: never a new node
  function M.retrigger(voice, velocity)
    local v = resolve_voice(voice)
    if not v then return ignored("retrigger", "voice " .. tostring(voice) .. " is not 0 to " .. NUM_VOICES) end
    if type(velocity) ~= "number" or velocity ~= velocity then
      return ignored("retrigger", "velocity is not a number")
    end
    if not S.voices[v].active then return false end
    -- a retrigger outside the patterns opens the voice's own gate length,
    -- not the last step's (#639), as lib/midi_in.lua does
    S.lib.sequencer.note_gate(v)
    S.lib.engine_sync.retrigger(v, math.max(0, math.min(1, velocity)), "action")
    return true
  end

  local function binary_action(action, key)
    return function(voice, mode)
      local v = resolve_voice(voice)
      if not v then return ignored(action, "voice " .. tostring(voice) .. " is not 0 to " .. NUM_VOICES) end
      local id = "v" .. v .. "_" .. key
      local want = wanted(mode, params:get(id) == 1)
      if want == nil then return ignored(action, "mode " .. tostring(mode) .. " is not 0, 1 or 2") end
      set_binary_param(id, want and 1 or 0)
      return true
    end
  end

  M.freeze = binary_action("freeze", "freeze")
  M.mute = binary_action("mute", "mute")

  function M.macro(m, value)
    if not whole(m) or m < 1 or m > NUM_MACROS then
      return ignored("macro", "macro " .. tostring(m) .. " is not 1 to " .. NUM_MACROS)
    end
    if type(value) ~= "number" or value ~= value then return ignored("macro", "value is not a number") end
    params:set("macro_" .. m, math.max(0, math.min(1, value)))
    return true
  end

  function M.patterns(mode)
    local want = wanted(mode, S.pattern_playing)
    if want == nil then return ignored("patterns", "mode " .. tostring(mode) .. " is not 0, 1 or 2") end
    if want and not S.pattern_playing then
      pattern_clock_start()
    elseif not want and S.pattern_playing then
      pattern_clock_stop()
    end
    return true
  end

  -- 3.7 (ruling 10): fill's latch, seq_fill (a key's hold is the grids';
  -- crow's triggers act on a rise only, so they toggle it)
  function M.fill(mode)
    local want = wanted(mode, params:get("seq_fill") == 1)
    if want == nil then return ignored("fill", "mode " .. tostring(mode) .. " is not 0, 1 or 2") end
    set_binary_param("seq_fill", want and 1 or 0)
    return true
  end

  -- What BUFFER's K3 does on the page's slot
  function M.record()
    record_buffer(S.buffer_page.slot)
    return true
  end

  return M
end
