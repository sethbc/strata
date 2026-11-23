-- lib/voice_presets.lua
-- Voice presets (3.8, design §8; S.lib.voice_presets): the library of
-- VOICE_PRESETS.slots named voice sounds in voices.data (the device's,
-- shared by every PSET: read at its start step, written at each save and
-- clear through S.lib.data_files, never at exit and never by a PSET or a
-- factory load), the filter that makes a voice's capture a sound
-- (VOICE_PRESETS.keys: every voice scene key that is no synth key, in or
-- out; every type's synth keys are in), and a load, a copy and a save. A
-- load or a copy takes a voice's sound (its type, its synth keys and the
-- in keys) and keeps its place (its active and source, and every out key),
-- lets go of the voice in a running fade (S.lib.scenes.release_voice) and
-- holds the voice's sound from before (its type, synth keys and in keys,
-- not its whole capture) for VOICE's undo (S.lib.mutation.hold_voice).
-- Fields of this module's table: VOICE_PRESETS, capture, load, copy, save,
-- clear, preset, loaded_name (cleared by a PSET read and a scene recall:
-- its PSET and recall hooks; put back by an undo: restore_name), forget.
-- See docs/notes/lua/voice-presets.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES
  local UI_PAGES = S.constants.UI_PAGES

  -- voices.data's version and the oldest this build reads (a version is
  -- compared only with these names)
  local VOICE_PRESET_DATA_VERSION = 1
  local VOICE_PRESET_FORMAT_FLOOR = 1

  -- The library's file, its slots, a name's length (a scene name's), the
  -- backup suffix of an unusable file, the texts it flashes and prints,
  -- what a copy shows as its name (copy_prefix and the voice's number), and
  -- the filter: every voice scene key that is no synth key, true (in: it
  -- shapes the sound whatever the voice reads) or false (out: a place in
  -- audio, another voice, a running state, the rig or the pattern). A test
  -- fails on a voice scene key the table does not name (design §8.1,
  -- ruling 48)
  local VOICE_PRESETS = {
    file = "voices.data",
    slots = 64,
    name_max = S.constants.SCENE_NAME_MAX,
    backup_suffix = ".bak",
    copy_prefix = "v",
    texts = {not_saved = "preset not saved", no_type = "no such type", nothing = "empty slot",
      not_loaded = "preset not loaded"},
    keys = {
      -- in (39)
      grain_size = true, grain_density = true, grain_pitch = true, grain_spread = true, grain_mode = true,
      grain_shape = true, grain_skew = true, grain_prob = true, grain_cloud = true, grain_overlap = true,
      pan_wander = true, intervals = true, interval_prob = true, custom_interval_1 = true,
      custom_interval_2 = true, custom_interval_3 = true, custom_interval_4 = true, custom_interval_5 = true,
      pitch_jitter = true, pan_jitter = true, size_jitter = true, reverse = true, quantize = true, arp = true,
      filter_type = true, filter_freq = true, filter_res = true, filter_mix = true, delay_send = true,
      reverb_send = true, dry = true, attack = true, release = true, env_attack = true, env_decay = true,
      env_sustain = true, env_release = true, env_curve = true, env_loop = true,
      -- out (39)
      buf_pos = false, buf_rate = false, buf_scan = false, mod_source_1 = false, mod_source_2 = false,
      mod_source_3 = false, mod_amp_amt_1 = false, mod_amp_amt_2 = false, mod_amp_amt_3 = false,
      mod_freq_amt_1 = false, mod_freq_amt_2 = false, mod_freq_amt_3 = false, mod_speed = false,
      history = false, freeze = false, freeze_mode = false, input_channel = false, loop_start = false,
      loop_length = false, bookmark_1 = false, bookmark_2 = false, bookmark_3 = false, bookmark_4 = false,
      scan_mode = false, follow = false, slices = false, mute = false, press_target = false,
      press_depth = false, slide_target = false, slide_depth = false, seq_length = false,
      seq_division = false, seq_direction = false, seq_gate = false, seq_gate_length = false,
      seq_gate_release = false, seq_swing = false, seq_misstep = false,
    },
  }
  M.VOICE_PRESETS = VOICE_PRESETS
  local KEYS = VOICE_PRESETS.keys

  -- The library: per slot nil or {name, type, values}; started once the
  -- start step ran (voices.data read: before it, no write is made, since
  -- one would put the empty library over the file unread); blocked when an
  -- unusable file could not be set aside (nothing is written over it this
  -- session); dropped while the file as read holds a damaged preset the
  -- start left out (the first write keeps the file as a backup first)
  local library = {}
  local store = {started = false, blocked = false, dropped = false}
  -- Per voice, the name shown on VOICE's preset row: the preset last
  -- loaded into it, or a copy's v<n> (not stored, design §8.4); a PSET read
  -- or a scene recall sets every voice anew and clears them all (#850); an
  -- undo of a load or a copy puts back the name from before it
  -- (restore_name, #869); a write that sets one voice anew without a
  -- recall forgets its own (forget, #869)
  local loaded = {}
  local function forget_names()
    loaded = {}
    request_redraw()
  end
  S.register_pset_hook({name = "voice_presets", read = forget_names})
  S.register_scene_recalled(forget_names)

  local function path() return S.lib.scenes.scene_data_dir .. VOICE_PRESETS.file end

  local function is_whole(value, low, high)
    return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
  end
  local function valid_voice(voice_idx) return is_whole(voice_idx, 1, NUM_VOICES) end
  local function valid_slot(slot) return is_whole(slot, 1, VOICE_PRESETS.slots) end
  local function finite(value) return type(value) == "number" and value > -math.huge and value < math.huge end

  local function flash(text)
    S.lib.ui_flash.start("hints", text, nil, UI_PAGES.index.VOICE)
  end

  -- A name as a preset keeps it: text's printable ASCII, cut to name_max
  local function clean_name(text)
    return (tostring(text):gsub("[^\32-\126]", ""):sub(1, VOICE_PRESETS.name_max))
  end

  -- A stored preset as this build can keep it, or nil: a name of at most
  -- name_max printable characters, a type key (^[%w_]+$; a type this build
  -- lacks is kept, and a load of it refused) and values holding finite
  -- numbers by string key
  local function preset_from(stored)
    if type(stored) ~= "table" then return nil end
    if type(stored.name) ~= "string" or #stored.name > VOICE_PRESETS.name_max or stored.name:find("[^\32-\126]") then
      return nil
    end
    if type(stored.type) ~= "string" or not stored.type:match("^[%w_]+$") then return nil end
    if type(stored.values) ~= "table" then return nil end
    local values = {}
    for key, value in pairs(stored.values) do
      if type(key) ~= "string" or not finite(value) then return nil end
      values[key] = value
    end
    return {name = stored.name, type = stored.type, values = values}
  end

  local function copy_values(values)
    local copy = {}
    for key, value in pairs(values) do copy[key] = value end
    return copy
  end

  -- What voices.data holds: the version and every filled slot
  local function stored_value()
    local presets = {}
    for slot = 1, VOICE_PRESETS.slots do
      local preset = library[slot]
      if preset then presets[slot] = {name = preset.name, type = preset.type, values = copy_values(preset.values)} end
    end
    return {version = VOICE_PRESET_DATA_VERSION, presets = presets}
  end

  -- Write voices.data: true, or false and why (the session's file blocked,
  -- or the write failed; the file is then as it was). While the file as
  -- read holds damaged presets, it is set aside first and kept only once
  -- the write lands: a failed write moves it back (#848)
  local function write()
    if not store.started then return false, VOICE_PRESETS.file .. " is not read yet" end
    if store.blocked then return false, VOICE_PRESETS.file .. " could not be set aside at the start" end
    local backup
    if store.dropped then
      -- the file as read, damaged presets and all, is kept before the
      -- first write drops them; no backup name free: nothing is written
      local failure
      backup, failure = S.lib.data_files.set_aside(path(), VOICE_PRESETS.backup_suffix)
      if not backup then
        print("strata: " .. VOICE_PRESETS.file .. " not saved: its damaged presets could not be kept ("
          .. tostring(failure) .. ")")
        return false, tostring(failure)
      end
    end
    util.make_dir(S.lib.scenes.scene_data_dir)
    local written, problem = S.lib.data_files.write(path(), stored_value())
    if not written then
      print("strata: " .. VOICE_PRESETS.file .. " not saved: " .. tostring(problem))
      if backup then
        local restored, why = os.rename(backup, path())
        if not restored then
          print("strata: " .. VOICE_PRESETS.file .. " as read is kept as " .. backup:match("[^/]*$")
            .. " (" .. tostring(why) .. ")")
        end
      end
      return false, tostring(problem)
    end
    if backup then
      store.dropped = false
      print("strata: " .. VOICE_PRESETS.file .. " as read kept as " .. backup:match("[^/]*$"))
    end
    return true
  end

  -- A capture (S.lib.scenes.capture_voice's) as a sound: its type and the
  -- values of its type's synth keys and the in keys
  local function sound_of(voice_idx, capture)
    local values = {}
    for _, entry in ipairs((S.lib.params_setup.voice_scene_keys(voice_idx, capture.type))) do
      if entry.synth or KEYS[entry.key] == true then values[entry.key] = capture.values[entry.key] end
    end
    return {type = capture.type, values = values}
  end

  -- A voice's sound: its capture (S.lib.scenes.capture_voice) filtered to
  -- its type and the values of its type's synth keys and the in keys; nil
  -- for a number that is no voice
  function M.capture(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return sound_of(voice_idx, S.lib.scenes.capture_voice(voice_idx))
  end

  -- A slot's preset as the picker shows it, {name, type}, or nil (empty,
  -- or a number that is no slot)
  function M.preset(slot)
    local preset = valid_slot(slot) and library[slot]
    if not preset then return nil end
    return {name = preset.name, type = preset.type}
  end

  -- The name VOICE's preset row shows for the voice, or nil
  function M.loaded_name(voice_idx)
    return loaded[voice_idx]
  end

  -- Empty the voice's name on its preset row, every other voice's kept
  -- (#869): for a write that sets the voice's sound anew without a recall
  -- (package 4b: a morph applying a voice's values). A number that is no
  -- voice forgets nothing
  function M.forget(voice_idx)
    if not valid_voice(voice_idx) then return end
    loaded[voice_idx] = nil
    request_redraw()
  end

  -- Put back the name the voice's row showed before a load or a copy (a
  -- string, or nil for none): S.lib.mutation.undo's, from the held
  -- capture's preset_name (#869). It is the undo's alone: no other writer
  -- calls it (a load, a copy or forget names a voice). A number that is no
  -- voice, or a name that is no string, changes nothing
  function M.restore_name(voice_idx, name)
    if not valid_voice(voice_idx) or (name ~= nil and type(name) ~= "string") then return end
    loaded[voice_idx] = name
    request_redraw()
  end

  -- Put a sound ({type, values}) on the voice, named shown_name on its
  -- preset row: the data apply_voice gets is, for each of the voice's
  -- scene keys of the sound's type (voice_scene_keys), a synth key from the
  -- sound else the voice's remembered value, an in key from the sound else
  -- the voice's capture, an out key from the capture, with the voice's own
  -- active and source and the sound's type. A key the sound has and this
  -- build lacks is in no list and dropped. A type this build lacks applies
  -- nothing (one console line, a flash). Once applied, the voice is let go
  -- of in a running fade (S.lib.scenes.release_voice: the fade's steps run
  -- on its clock, so none comes between), never after a refused apply,
  -- which leaves the voice in the fade. True once applied
  local function apply_sound(voice_idx, sound, shown_name)
    if not S.lib.types.record(sound.type) then
      print("strata: voice preset " .. shown_name .. " is of type " .. tostring(sound.type)
        .. ", which this build lacks; nothing loaded")
      flash(VOICE_PRESETS.texts.no_type)
      return false
    end
    local current = S.lib.scenes.capture_voice(voice_idx)
    local remembered = S.voices[voice_idx].values
    local values = {}
    for _, entry in ipairs((S.lib.params_setup.voice_scene_keys(voice_idx, sound.type))) do
      local key, value = entry.key, nil
      if entry.synth then
        value = sound.values[key]
        if value == nil then value = remembered[key] end
      elseif KEYS[key] == true then
        value = sound.values[key]
        if value == nil then value = current.values[key] end
      else
        value = current.values[key]
      end
      values[key] = value
    end
    local applied = S.lib.scenes.apply_voice(voice_idx,
      {active = current.active, source = current.source, type = sound.type, values = values})
    if not applied then
      flash(VOICE_PRESETS.texts.not_loaded)
      return false
    end
    S.lib.scenes.release_voice(voice_idx)
    -- after the apply, whose actions are edits; the row's name from before
    -- goes with the sound, for the undo to put back (#869)
    local before = sound_of(voice_idx, current)
    before.preset_name = loaded[voice_idx]
    S.lib.mutation.hold_voice(voice_idx, before)
    loaded[voice_idx] = shown_name
    request_redraw()
    grid_redraw()
    return true
  end

  -- Load slot's preset into the voice: its sound, the voice's place kept
  -- (apply_sound). False for no voice, no slot, an empty slot (a flash) or
  -- a preset that does not apply
  function M.load(voice_idx, slot)
    if not valid_voice(voice_idx) or not valid_slot(slot) then return false end
    local preset = library[slot]
    if not preset then
      flash(VOICE_PRESETS.texts.nothing)
      return false
    end
    return apply_sound(voice_idx, {type = preset.type, values = copy_values(preset.values)}, preset.name)
  end

  -- Copy another voice's sound (M.capture(from_voice)) into to_voice, as a
  -- load does; its row shows v<from>. False for no voice or the same one
  function M.copy(from_voice, to_voice)
    if not valid_voice(from_voice) or not valid_voice(to_voice) or from_voice == to_voice then return false end
    return apply_sound(to_voice, M.capture(from_voice), VOICE_PRESETS.copy_prefix .. from_voice)
  end

  -- Save the voice's sound (M.capture) in slot as name (printable ASCII,
  -- cut to name_max) and write voices.data: true, or false and why (no
  -- voice or slot, or the file not written: the slot is as it was, and a
  -- flash says so)
  function M.save(voice_idx, slot, name)
    if not valid_voice(voice_idx) then return false, "no voice " .. tostring(voice_idx) end
    if not valid_slot(slot) then return false, "no slot " .. tostring(slot) end
    if type(name) ~= "string" then return false, "a name is a string" end
    local before = library[slot]
    local sound = M.capture(voice_idx)
    library[slot] = {name = clean_name(name), type = sound.type, values = sound.values}
    local written, why = write()
    if not written then
      library[slot] = before
      flash(VOICE_PRESETS.texts.not_saved)
      return false, why
    end
    request_redraw()
    return true
  end

  -- Empty slot and write voices.data: true, or false (no slot, an empty
  -- one, or the file not written: the slot is as it was, with a flash)
  function M.clear(slot)
    if not valid_slot(slot) or library[slot] == nil then return false end
    local before = library[slot]
    library[slot] = nil
    if not write() then
      library[slot] = before
      flash(VOICE_PRESETS.texts.not_saved)
      return false
    end
    request_redraw()
    return true
  end

  -- The start step: read voices.data (parsed, never run). Missing: an
  -- empty library. Unreadable, of a version outside the floor and this
  -- build's, or not of the library's shape: set aside (voices.data.bak,
  -- ...) with one console line, the library empty; one that cannot be set
  -- aside blocks every write this session. A damaged preset is left out
  -- (the next write drops it), with one line naming how many
  S.register_start(S.constants.START_ORDER.voice_presets_load, function()
    library, loaded = {}, {}
    store.started, store.blocked, store.dropped = true, false, false
    local value, outcome, why = S.lib.data_files.read(path())
    if value == nil and outcome == "missing" then return end
    local problem = value == nil and (why or outcome) or nil
    if not problem then
      if type(value) ~= "table" then
        problem = "not a table"
      elseif type(value.version) ~= "number" or value.version < VOICE_PRESET_FORMAT_FLOOR
        or value.version > VOICE_PRESET_DATA_VERSION then
        problem = "version " .. tostring(value.version)
      elseif type(value.presets) ~= "table" then
        problem = "no presets"
      end
    end
    if problem then
      local backup, failure = S.lib.data_files.set_aside(path(), VOICE_PRESETS.backup_suffix)
      if not backup then store.blocked = true end
      print("strata: " .. VOICE_PRESETS.file .. " not used (" .. tostring(problem) .. "): the library is empty; "
        .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure))))
      return
    end
    local damaged = 0
    for slot, stored in pairs(value.presets) do
      local preset = valid_slot(slot) and preset_from(stored)
      if preset then library[slot] = preset else damaged = damaged + 1 end
    end
    if damaged > 0 then
      store.dropped = true
      print("strata: " .. VOICE_PRESETS.file .. ": " .. damaged .. " damaged "
        .. (damaged == 1 and "preset" or "presets") .. " left out (the file is kept as a backup at the next write)")
    end
  end)

  return M
end
