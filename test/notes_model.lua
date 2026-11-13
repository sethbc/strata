-- test/notes_model.lua
-- A model of the engine's note slots (ruling 57, #686), for the tests that
-- compare Lua's held notes with what the engine holds. It follows the notes
-- area's rules as docs/notes/engine/notes.md states them (and the freeze
-- area's, for a synth voice's streams), fed the engine calls the stub
-- records: noteOn, noteOff, setNotePool, voiceOn, voiceOff, setGrainSource
-- and the freeze grain param. Per engine voice: running, its source, its
-- freeze, the own note's park and, per extra slot, its state (empty, live,
-- releasing), kind (voice, buffer, input, stream), note, freq, rate and
-- start order. A releasing note never ends on its own here (its release
-- time is the engine's); that only makes more of them to cut. What the
-- engine would refuse or ignore that Lua should never send is an error
-- (model.errors). A test-side helper, not part of the shared stub: the stub
-- checks each call alone, the model the state a sequence of them leaves.
-- Used by test/unit/strata_test.lua.

local Model = {}
Model.__index = Model

-- constants: S.constants (NUM_VOICES, NOTE_SLOTS, NUM_BUFFERS); the
-- engine's input source is NUM_BUFFERS + 1, its rate root 60
function Model.new(constants)
  local model = setmetatable({pool = 0, order = 0, errors = {}, voices = {}, input = constants.NUM_BUFFERS + 1,
    slots = constants.NOTE_SLOTS, buffers = constants.NUM_BUFFERS, read = 0,
    -- how often each path ran, so a test can tell its sequence reached them
    counts = {starts = 0, restarts = 0, streams_left = 0, cuts = 0, parks = 0, unparks = 0, regrained = 0}}, Model)
  for voice = 0, constants.NUM_VOICES - 1 do
    local state = {running = false, source = 0, frozen = false, own = {parked = false}, extra = {}}
    for slot = 1, constants.NOTE_SLOTS - 1 do state.extra[slot] = {state = "empty"} end
    model.voices[voice] = state
  end
  return model
end

function Model:error(text) table.insert(self.errors, text) end

local function absolute_rate(note) return math.min(4, math.max(0.25, 2 ^ ((note - 60) / 12))) end

-- What the voice's next extra note is (noteKindFor)
function Model:kind_for(voice)
  local state = self.voices[voice]
  if state.source == self.input then return "input" end
  if state.source >= 1 and state.source <= self.buffers then return "buffer" end
  if state.frozen then return "stream" end
  return "voice"
end

function Model:held_count()
  local count = 0
  for voice = 0, #self.voices do
    for _, record in ipairs(self.voices[voice].extra) do
      if record.state ~= "empty" then count = count + 1 end
    end
  end
  return count
end

-- The oldest extra note in `state` across every voice (nil: none)
function Model:oldest(state)
  local found
  for voice = 0, #self.voices do
    for _, record in ipairs(self.voices[voice].extra) do
      if record.state == state and (found == nil or record.order < found.order) then found = record end
    end
  end
  return found
end

-- cutNote: the slot empties (its synth into the kill fade)
local function cut(record) record.state = "empty" end

-- startNote, after makeNoteRoom: false when the pool is full of live notes
function Model:start(voice, record, order)
  if self:held_count() >= self.pool then
    local releasing = self:oldest("releasing")
    if not releasing then return false end
    cut(releasing)
  end
  self.order = self.order + 1
  self.counts[order and "restarts" or "starts"] = self.counts[order and "restarts" or "starts"] + 1
  record.state, record.kind, record.order = "live", self:kind_for(voice), order or self.order
  return true
end

-- leaveStream (ruling 53): a ring-stream note's rate becomes its note's
local function leave_stream(record)
  if record.kind == "stream" then record.rate = absolute_rate(record.note) end
end

-- restartNotes (a running voice's switch) and notesUnfrozen (only the
-- streams): each note cut, each live one started again on the voice's
-- state now, keeping its order
function Model:restart(voice, streams_only)
  for _, record in ipairs(self.voices[voice].extra) do
    if record.state ~= "empty" and (not streams_only or record.kind == "stream") then
      local was_live = record.state == "live"
      cut(record)
      if record.kind == "stream" then self.counts.streams_left, record.streamed = self.counts.streams_left + 1, true end
      leave_stream(record)
      if was_live then self:start(voice, record, record.order) end
      -- a note once a stream, now on a buffer or the input: its rate is its note's
      if was_live and record.streamed and record.kind ~= "voice" and record.kind ~= "stream" then
        self.counts.regrained = self.counts.regrained + 1
      end
    end
  end
end

Model.commands = {}

Model.commands.voiceOn = function(self, voice)
  local state = self.voices[voice]
  state.running, state.own.parked = true, false
end

Model.commands.voiceOff = function(self, voice)
  local state = self.voices[voice]
  state.running = false
  for _, record in ipairs(state.extra) do
    if record.state == "live" then record.state = "releasing" end
  end
end

Model.commands.setGrainSource = function(self, voice, source)
  local state = self.voices[voice]
  if source == state.source then return end
  state.source = source
  if state.running then
    state.frozen = false  -- a switch unfreezes first (unfreezeVoice)
    self:restart(voice, false)
  end
end

-- the freeze param: freezeVoice (frozen on another source first unfrozen,
-- with no note moved), or unfreezeWithControl (a frozen synth voice's
-- streams restarted as voice synths)
Model.commands.setGrainParam = function(self, voice, name, value)
  if name ~= "freeze" then return end
  local state = self.voices[voice]
  if value > 0.5 then
    state.frozen, state.frozen_source = true, state.source
  elseif state.frozen then
    local synth_voice = state.source == 0
    state.frozen = false
    if synth_voice then self:restart(voice, true) end
  end
end

Model.commands.noteOn = function(self, voice, slot, note, freq, rate)
  local state = self.voices[voice]
  if slot == 0 then
    if not state.running then self:error("a slot-0 noteOn to stopped voice " .. voice) end
    if state.own.parked then self.counts.unparks = self.counts.unparks + 1 end
    state.own.parked = false
    return
  end
  if not state.running then return self:error("an extra noteOn to stopped voice " .. voice .. " (ignored)") end
  local record = state.extra[slot]
  record.note, record.freq, record.rate = note, freq, rate
  if record.state == "releasing" then cut(record) end
  if record.state == "empty" and not self:start(voice, record) then
    self:error("voice " .. voice .. " slot " .. slot .. ": refused, the pool of " .. self.pool .. " is full of live notes")
  end
end

Model.commands.noteOff = function(self, voice, slot, cut_it)
  local state = self.voices[voice]
  if slot == 0 then state.own.parked, self.counts.parks = true, self.counts.parks + 1; return end
  local record = state.extra[slot]
  if record.state == "empty" then return end
  if cut_it == 1 and record.state == "live" then self.counts.cuts = self.counts.cuts + 1 end
  if cut_it == 1 then cut(record) elseif record.state == "live" then record.state = "releasing" end
end

Model.commands.setNotePool = function(self, size)
  self.pool = size
  while self:held_count() > size do
    local victim = self:oldest("releasing")
    if not victim then
      victim = self:oldest("live")
      self:error("setNotePool " .. size .. " cut a live note")
    end
    cut(victim)
  end
end

-- Take the calls the stub recorded since the last feed (context.engine_calls,
-- never cleared while the model reads it)
local unpack_args = table.unpack or unpack  -- Lua 5.2+ or LuaJIT

function Model:feed(calls)
  for index = self.read + 1, #calls do
    local command = Model.commands[calls[index].name]
    if command then command(self, unpack_args(calls[index].args)) end
  end
  self.read = #calls
end

-- Lua's view against the model's: the problems found (empty: they agree).
-- S.lib.notes' held extra notes are the engine's live ones, each of the kind
-- the voice's state makes and at the pitch note_values gives it; a running
-- voice's own note is parked in both or neither; the pools agree, and live
-- and releasing notes stay within the engine's
function Model:compare(S)
  local problems, notes = {}, S.lib.notes
  local function problem(text) table.insert(problems, text) end
  if notes.pool() ~= self.pool then problem("pool: Lua " .. notes.pool() .. ", engine " .. self.pool) end
  if self:held_count() > self.pool then problem(self:held_count() .. " live and releasing notes past the pool") end
  for voice_idx = 1, S.constants.NUM_VOICES do
    local state, held, own = self.voices[voice_idx - 1], {}, nil
    if S.voices[voice_idx].active ~= state.running then problem("voice " .. voice_idx .. ": running differs") end
    for _, used in ipairs(notes.slots(voice_idx)) do
      if used.slot == 1 then own = used elseif used.held then held[used.slot - 1] = used end
    end
    local frozen_synth = voice_uses_synth(voice_idx) and S.lib.freeze.is_frozen(voice_idx)
    local kind = voice_uses_buffer(voice_idx) and "buffer" or not voice_uses_synth(voice_idx) and "input"
      or frozen_synth and "stream" or "voice"
    for slot, record in ipairs(state.extra) do
      local where = "voice " .. voice_idx .. " slot " .. slot + 1
      local used = held[slot]
      if (used ~= nil) ~= (record.state == "live") then
        problem(where .. ": Lua " .. (used and "holds a note" or "holds none") .. ", the engine's is " .. record.state)
      elseif used then
        local values = notes.note_values(voice_idx, used.pitch)
        if record.kind ~= kind then problem(where .. ": a " .. record.kind .. " note on a " .. kind .. " voice") end
        local engine_value, lua_value = record.rate, values.rate
        if record.kind == "voice" then engine_value, lua_value = record.freq, values.freq end
        if math.abs(engine_value - lua_value) > 1e-6 then
          problem(string.format("%s: plays %.6f, Lua's note_values %.6f", where, engine_value, lua_value))
        end
      end
    end
    if state.running and (own ~= nil and own.parked) ~= state.own.parked then
      problem("voice " .. voice_idx .. ": the own note is " .. (state.own.parked and "" or "not ") .. "parked in the engine")
    end
  end
  for _, text in ipairs(self.errors) do problem("engine: " .. text) end
  return problems
end

return Model
