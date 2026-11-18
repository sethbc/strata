-- lib/types.lua
-- The voice types (3.8, design §2; S.lib.types): the answers the script
-- reads about the types registered with S.register_voice_type (one record
-- a type, lib/types/<key>.lua, in type order). A voice's type is its
-- v<i>_type param (lib/voices.lua's synth record adds it); S.voices[i].name
-- is the current type's key and param_order its keys. Everything here reads
-- the registry at each call, after init. See docs/notes/lua/types.md

return function(S)
  local M = {}
  local NUM_VOICES = S.constants.NUM_VOICES

  local function valid_voice(voice_idx)
    return type(voice_idx) == "number" and voice_idx % 1 == 0 and voice_idx >= 1 and voice_idx <= NUM_VOICES
  end

  -- The records, in type order (a fresh list each call)
  function M.list()
    local list = {}
    for index, record in ipairs(S.registry.voice_types) do list[index] = record end
    return list
  end

  -- The record of key, or nil when this build has no such type
  function M.record(key)
    for _, record in ipairs(S.registry.voice_types) do
      if record.key == key then return record end
    end
    return nil
  end

  -- The voice's current type's record; nil for a number that is no voice
  -- (and before init, when no voice has a type yet)
  function M.of(voice_idx)
    if not valid_voice(voice_idx) then return nil end
    return M.record(S.voices[voice_idx].name)
  end

  -- The type voice voice_idx starts on: the voice_idx-th type (the 3.7 roster)
  function M.default_key(voice_idx)
    local record = valid_voice(voice_idx) and S.registry.voice_types[voice_idx]
    return record and record.key or nil
  end

  -- Every distinct synth key of the types, in type order (each type's
  -- param_order, a key at its first type)
  function M.keys()
    local keys, listed = {}, {}
    for _, record in ipairs(S.registry.voice_types) do
      for _, key in ipairs(record.param_order) do
        if not listed[key] then
          listed[key] = true
          keys[#keys + 1] = key
        end
      end
    end
    return keys
  end

  -- The first type's record that has key, or nil
  local function first_with(key)
    for _, record in ipairs(S.registry.voice_types) do
      if record.specs[key] then return record end
    end
    return nil
  end

  -- A copy of key's one spec (the registry makes every type's agree); a
  -- key no type has is an error, so a key never gets a 0-1 range unseen (#315)
  function M.spec(key)
    local record = first_with(key)
    if not record then error("S.lib.types.spec: no type has the key " .. tostring(key), 2) end
    return record.specs[key]:copy()
  end

  -- key's format string (one for every type that has it), or nil
  function M.format(key)
    local record = first_with(key)
    return record and record.formats[key] or nil
  end

  -- VOICE's type row (design §2.3, ruling 63): E3 and the arc's ring move
  -- a pending choice, one a voice, applied once the turns have rested
  -- settle_seconds (one settle clock a voice, S.type_settle_clocks[voice]),
  -- or at once by a voice pick, leaving VOICE or the voice's stop (flush)
  M.TYPES = {settle_seconds = 0.3}
  S.type_settle_clocks = {}

  -- Per voice, the type index VOICE's type row holds pending (nil: none)
  local pending = {}

  local function stop_settle(voice_idx)
    local id = S.type_settle_clocks[voice_idx]
    if id then
      S.type_settle_clocks[voice_idx] = nil
      clock.cancel(id)
    end
  end

  -- Forget the voice's pending choice and its settle. Every path that sets
  -- the voice's type does (the v<i>_type action calls it), so the later act stands
  function M.cancel(voice_idx)
    pending[voice_idx] = nil
    stop_settle(voice_idx)
  end

  -- The pending choice's type index for the voice, or nil
  function M.pending(voice_idx)
    return pending[voice_idx]
  end

  -- Apply the voice's pending choice at once, if it has one (a choice
  -- turned back to the current type only ends)
  function M.flush(voice_idx)
    local index = pending[voice_idx]
    if index == nil then return end
    M.cancel(voice_idx)
    local current = M.of(voice_idx)
    if current and current.index ~= index then params:set("v" .. voice_idx .. "_type", index) end
    request_redraw()
  end

  -- Move the voice's pending choice by d types (from its current type when
  -- none is pending), clamped to the list, and restart its settle
  function M.turn(voice_idx, d)
    local current = M.of(voice_idx)
    if not current or type(d) ~= "number" then return end
    pending[voice_idx] = util.clamp((pending[voice_idx] or current.index) + d, 1, #S.registry.voice_types)
    stop_settle(voice_idx)
    S.type_settle_clocks[voice_idx] = clock.run(function()
      clock.sleep(M.TYPES.settle_seconds)
      S.type_settle_clocks[voice_idx] = nil
      M.flush(voice_idx)
    end)
    request_redraw()
  end

  -- A voice's stop applies its pending choice (ruling 63)
  S.register_voice_stop(function(voice_idx) M.flush(voice_idx) end)

  -- cleanup: every settle clock canceled, nothing applied
  S.register_cleanup(S.constants.CLEANUP_ORDER.type_settle, function()
    for voice_idx = 1, NUM_VOICES do
      pending[voice_idx] = nil
      stop_settle(voice_idx)
    end
  end)

  -- Apply a type at once: v<i>_type set to the record's index (its action
  -- cancels the voice's pending choice). False for an unknown key or voice
  function M.set(voice_idx, key)
    local record = M.record(key)
    if not valid_voice(voice_idx) or not record then return false end
    M.cancel(voice_idx)
    params:set("v" .. voice_idx .. "_type", record.index)
    return true
  end

  return M
end
