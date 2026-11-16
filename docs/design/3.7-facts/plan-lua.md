# 3.7 plan facts C: packages 2a-2f and 1d's Lua half

Read-only, from `main` at `78ba8510` (code identical to `334429aa`; only docs changed since). The design is now `docs/design/3.7-design.md` in the main checkout, with `docs/design/3.7-facts/{lua,buffers,engine}.md`. What those fact files already establish is cited, not repeated (lua.md §n, buffers.md §n). "not found" marks what could not be established.

## 0. Surprises a planner must meet first

1. **A start sends nothing but `setGrainParam` before `voiceOn`, and nothing grain-side after it. Two tests pin this.** `test/unit/engine_sync_test.lua:81-110` ("a start sends the source and every grain value before voiceOn, the voice-level values after") asserts calls 2..voiceOn-1 are all `setGrainParam` and that no `setGrainParam`/`setGrainSource` follows `voiceOn`. `test/unit/structure_test.lua:796-852` (`start_steps()`, used by "init runs every registered start step in today's order", :854) pins the start's command sequence `{"engine.setGrainSource", "engine.setGrainParam", "engine.voiceOn", "engine.setVoiceParam", setModSource/AmpAmt/FreqAmt x3, "engine.setModSpeed", "engine.setVoiceParam", ...}` and every start step's effects (`{ "notes load", { "file read notes.data", "engine.setNotePool" } }`, `{ "buffers load", ...}`). So §3.4's "every voice sync sends the own region" (`noteRegion`) and §2.4's `syncScan` cannot go in a record's `sync` at a start without changing both tests; `rootNote` and `followRate` (handler-only grain params via `setGrainParam`) can. A new start step (samples.data's read) must be added to `start_steps()`.
2. **`lib/files.lua` has no save function.** Design §13 gives 2d "`lib/files.lua` (a whole save's copy)". The saves are globals in `lib/buffers.lua`: `save_buffer(slot)` :580-589, `save_buffer_loop(slot)` :615-627, `send_save` :548-554, and the result `buffer_save_result(value)` :641-668. `lib/files.lua` only holds `folder_for`, `note_chosen`, `random_into`, `fill_empty`.
3. **`S.lib.notes.play` accepts only owners `midi` and `seq`.** `NOTES.owners = {midi = true, seq = true}` (`lib/notes.lua:30`), checked by `valid_note` (:397-405) and by the invariant's `record_problem` (:852). §10's grid slice keys ("the port as the note's owner") need a new owner. `valid_note` ignores unknown fields, so `region` passes it but is not copied into `played` (:419-421) or the record (`new_record` :148-152) unless added.
4. **`set_own` is not a module function.** It is a required field of `play`'s argument (`valid_note`: `type(note.set_own) == "function"`), called as `note.set_own(played.pitch)` in `play_own` (:360).
5. **`rate_root_note` has a fourth Lua use the design does not list**: `own_pitch` (`lib/notes.lua:315-320`), which `unpark_alone` (:338) uses for the own note's return noteOn. And `test/unit/docs_test.lua:2130-2148` asserts `noteRateRootNote` (StrataNotes.sc:27) = `NOTES.rate_root_note` = `MIDI.rate_root_note`.
6. **Peaks' `frames` and `rate` are parsed and dropped** (`lib/waveforms.lua:61-63`); `read` returns early when the values did not change (:94). A "peaks were read" call placed after :95 misses a re-read with the same values.
7. **BUFFER pins its field count and two field indices.** `test/unit/pages_buffer_test.lua:158-159` asserts "the field cursor stops at field 11"; `lib/pages/buffer.lua:948` (`LAYOUT.long_file_start`) sets `S.buffer_page.field = 10` (the `start` field) and :1021, :1042, :1049 set `field = 3`. Every `BUFFER_FIELDS` name needs a `FIELD_VALUES` entry (:952-964), or the layout-state loop (:1059-1064) calls nil.
8. **A modal owner gets K2/K3 and E2/E3 with ALT unsplit.** `strata.lua:256-266` sends K2/K3 to `S.lib.ui_modal.key(n, z)` whatever ALT is (no `alt_action`); `enc` (:229-243) sends E2/E3 to `owner.enc` (E1 ignored). The owner reads `S.alt_held` itself, as SEQ's step editor does.
9. **The 128h's page 5 has no strip**; its strip is on page 4 (`strip_page = PAGES.sources`, `lib/grid/layout_128h.lua:375`), rows 5-6 columns 13-16 for `S.grid_voice_select`.
10. **io.data has no SETUP problem line.** SETUP's data-file rows cover only `S.scene_file` and `S.buffer_file` (`lib/pages/setup.lua:152-163`); `lib/io/rig.lua` only prints.
11. **The FX arc has no ALT layer and no ring for an option.** `lib/arc/fx.lua` sets only `arc_delta` and `arc_redraw`; FX's `fx_key` (lib/pages/fx.lua:138-147) toggles the bypass for *any* row whose `effect` is `"delay"`, so a `sync` row with `effect = "delay"` would toggle the bypass.
12. **setDelay's three arguments are pinned in five test files** (§7 below), including stub-limit tests with a three-value base (`docs_test.lua:680, 723-725`) that a 4-argument stub check rejects.

---

## 1. Notes and MIDI (2b, 2d)

### lib/notes.lua

- `NOTES` (:28-40): `{file = "notes.data", version = 1, cut_seconds = 0.05, sends_per_step = 16, rate_root_note = 60, rate_range = {0.25, 4}, note_range = {0, 127}, a4 = {note = 69, freq = 440}, owners = {midi = true, seq = true}, expression_keys = {"bend", "amp", "position", "size", "main"}, neutral = {bend = 1, amp = 1, position = 0, size = 0, main = 0}, expression_ranges = {...}, cap = {...}, envelope = {...}, envelope_ranges, envelope_keys, envelope_engine}`; `M.NOTES = NOTES`.
- Module state (:44-52): `pool_setting`; `slots[v][s]` (the record, nil free), `ended[v][s]`, `sent[v][s]` (expression the engine keeps), `references[v]`, `lowered[v]`; `flush = {queue = {}, stopped = false, hooked = false}`.
- **`M.play(voice, note)`** (:413-485). `note` = `{owner, key, pitch, velocity, set_own, park, quiet, extra_only, expression}` (comment :407-412; `valid_note` :397-405: owner in `NOTES.owners`, key non-nil and `== key`, finite pitch and velocity, `set_own` a function, `park`/`quiet`/`extra_only` nil or boolean, `expression` nil or table). Returns the slot (1..NOTE_SLOTS) or nil. Builds
  ```lua
  local played = {owner = note.owner, key = note.key, pitch = note.pitch, park = note.park == true,
    quiet = note.quiet == true, velocity = util.clamp(note.velocity, 0, 1),
    expression = merged_expression(NOTES.neutral, note.expression)}
  ```
- **Slot record** (`new_record`, :148-152): `{voice, slot, owner, key, pitch, velocity, park, quiet, held = true, parked = false, started = now, expression = copy, due = false}`. `M.slots(voice)` (:255-266) returns copies `{slot, owner, key, pitch, held, parked}`.
- **The six branches** (lua.md §5 names them): 1 same owner+key: slot 1 → `play_own` (:424), extra slot re-pitched in place :425-438; `extra_only` path (branch 3 only) :444-451; 2 slot 1 free/parked/stopped → `play_own` :452; 3 free slot with room :455-474 (`start_extra`); 4 pool full → steal `oldest` :458-469; 5 cap full → re-pitch the voice's oldest in place :475-481; 6 → `play_own` :484.
- **Sends, quoted:**
  - `send_expression` (:123-127): `engine.noteExpression(voice - 1, slot - 1, expression.bend, expression.amp, expression.position, expression.size, expression.main)` then `sent[voice][slot] = copy_expression(expression)`.
  - `send_note_on` (:129-132): `local values = M.note_values(voice, record.pitch)` / `engine.noteOn(voice - 1, slot - 1, values.note, values.freq, values.rate, record.velocity)`.
  - unpark (:339): `engine.noteOn(voice - 1, 0, values.note, values.freq, values.rate, 0)` with `values = M.note_values(voice, own_pitch(voice))`.
  - `engine.noteOff` at :461 (steal, `cut 1`), :496 (`release_slot` extra, `0`), :502 (own note parks, slot 0, `0`), :792 (`cut_extras`, `1`).
  - `engine.retrigger(voice - 1, record.velocity)` at :379 in `play_own` unless `note.quiet` (0b moves this to `S.lib.engine_sync.retrigger`).
  - `start_extra` (:387-395): record → `run_note_hooks("started")` → `send_expression` → `send_note_on` → `count(2)`. **This is where an extra slot's `noteRegion` goes before `noteOn`.**
  - `play_own` (:354-383): `note.set_own(played.pitch)`; forget previous; `toggle_voice` if stopped and not quiet; new record; hooks; expression (or `mark_due` if quiet); `send_note_on` slot 1 only if `was_parked or frozen_synth` and active; `retrigger` unless quiet; `count(messages)`. **The own note's region goes before the retrigger here.**
- `count(n)` (:121): `S.lib.engine_sync.count_sends(n)`; every direct send is counted, never deferred.
- `release_slot` (local, :492-510), `M.release(voice, owner, key)` (:512-517, true if a note ended), `M.release_owner(voice, owner)` (:521-530, extras first then slot 1), `M.forget_owner(voice, owner)` (:538-549), `M.forget(voice, owner, key)` (:554-564; extra released, own dropped silently), `M.release_all(voice)` (:568-576, sends nothing), local `forget(record, now, moved)` (:173-180: clears slot, `ended`, runs `"ended"` unless moved), `M.find(voice, owner, key)` (:245-252), `M.held(voice)` (:225-232), `M.pool_used()` (:234-242), `M.pool()` (:269-272), `M.set_expression` (:582-589), `M.expression` (:595-600), `M.set_pool` (:635-657), `M.freeze_reference` (:279-285), `M.recall_switched` (:835-837).
- **`M.note_values`** (:300-309), whole:
  ```lua
  function M.note_values(voice, pitch)
    if not whole_in(voice, 1, NUM_VOICES) or not finite(pitch) then return nil end
    local min_freq, max_freq = param_range("v" .. voice .. "_freq")
    local root = M.freeze_reference(voice) or NOTES.rate_root_note
    return {
      note = util.clamp(pitch, NOTES.note_range[1], NOTES.note_range[2]),
      freq = util.clamp(musicutil.note_num_to_freq(pitch), min_freq, max_freq),
      rate = util.clamp(2 ^ ((pitch - root) / 12), NOTES.rate_range[1], NOTES.rate_range[2]),
    }
  end
  ```
  `own_pitch(voice)` (:315-320): synth `freq_note`; else `NOTES.rate_root_note + 12 * math.log(rate) / math.log(2)` from `engine_base_value("v<i>_buf_rate" | "_grain_pitch")`.
- **Hook lists** (:160-169):
  ```lua
  local function run_note_hooks(field, record)
    for _, hook in ipairs(S.registry.note_hooks) do
      if hook[field] then
        S.lib.ui_frame.contained_call(hook_errors, hook.name .. " " .. field, "note hook " .. hook.name .. " " .. field,
          hook[field], record.voice, record.slot,
          {owner = record.owner, key = record.key, pitch = record.pitch, velocity = record.velocity})
  ```
  `started` (play_own :365, start_extra :390), `moved` (:365, :436), `ended` (`forget` :179, park :505), `expressed` (`mark_due` :186). Registration: `S.register_note_hook({name, started, ended, moved, expressed})`, `lib/state.lua:513-527`; read at each use (stays open); "a hook never yields and never calls S.lib.notes.play". The only registered hook today is `lib/io/targets.lua:188`, which acts only for `owner == "midi"` (:183, :192, :195).
- **48 Hz flush hook**: `flush_step` (:605-621) is hooked at the start step `notes_load` (:756-771): `if not flush.hooked then flush.hooked = true; S.lib.lfos.on_step(flush_step) end` (:767-770). So it runs after include-time `on_step` hooks (macros, matrix). Cleanup `CLEANUP_ORDER.notes` → `M.stop_flush()` (:774).
- Other registrations: voice params record `notes` (:691-726, `S.register_voice_params(cap_record)`); `S.register_grain_restart(send_envelope)` (:730); scene migration "notes envelope" (:734-748); voice stop (:778-782: `M.release_all`, slot-1 expression reset to neutral, reference cleared); grain restart (:817-824); freeze change (:842-847); invariant "notes" (:871-903). Constructor has 149 locals free (lua.md §9).

### lib/midi_in.lua

- `M.MIDI` (:24-37): `velocity_max = 127, rate_root_note = 60, bend_center = 8192, bend_semitones = 2, channel_mode_options, note_off_options = {"auto", "release", "latch"}, owner = "midi", channels = 16, notes_per_channel = 128, pressure_max = 127`.
- `S.midi_state` (:40-49): `{bend = {}, held = {[v] = {[key] = true}}, note_voice = {[ch] = {[note] = {voices}}}, started = {}}`.
- `key_of(channel, note)` (:259): `channel * MIDI.notes_per_channel + note`.
- `note_on(channel, note, velocity)` (local, :310-327): `valid_note` + `tapped(note)` (the note tap, :293-299), ends the key on voices it no longer targets, records `note_voice`, then per target: `if next(S.midi_state.held[voice_idx]) == nil then S.lib.notes.release_owner(voice_idx, MIDI.owner) end` (latch: next chord replaces), `held[voice][key] = true`, `midi_note_on(voice_idx, note, velocity, channel, raw)`.
- `note_off(channel, note)` (local, :330-341): looks up `note_voice`, then `end_key(voice_idx, key)` per voice. **There is no function named `midi_note_off`** (not found); the off path is `note_off` → `end_key`, plus `midi_note_off_for`.
- **Latch logic**, `end_key` (:280-291):
  ```lua
  local function end_key(voice_idx, key)
    S.midi_state.held[voice_idx][key] = nil
    if M.note_off_mode() ~= "release" then
      S.lib.expression.latch(voice_idx, MIDI.owner, key)
    elseif next(S.midi_state.held[voice_idx]) == nil and S.voices[voice_idx].active then
      midi_note_off_for(voice_idx)
    else
      S.lib.notes.release(voice_idx, MIDI.owner, key)
    end
  end
  ```
  `M.note_off_mode()` (:171-176): auto → `"release"` while `S.lib.mpe.active()`, else `"latch"`. `midi_note_off_for(voice_idx)` (:478-484): in release mode with no key held, `toggle_voice` (stops the voice).
- **`own_setters`** (:410-423), whole:
  ```lua
  local own_setters = {}
  for i = 1, NUM_VOICES do
    local prefix = "v" .. i .. "_"
    own_setters[i] = function(pitch)
      local id, value = prefix .. "grain_pitch", 2 ^ ((pitch - MIDI.rate_root_note) / 12)
      if voice_uses_synth(i) then
        id, value = prefix .. "freq", musicutil.note_num_to_freq(pitch)
      elseif voice_uses_buffer(i) then
        id = prefix .. "buf_rate"
      end
      local low, high = param_range(id)
      params:set(id, util.clamp(value, low, high))
    end
  end
  ```
- **`midi_note_on(voice_idx, note, velocity, channel, raw)`** (global, :433-455), whole:
  ```lua
  function midi_note_on(voice_idx, note, velocity, channel, raw)
    if voice_idx < 1 or voice_idx > NUM_VOICES then return end
    raw = raw or {bend = 1}
    local key = key_of(channel or 1, note)
    S.lib.expression.forget(voice_idx, MIDI.owner, key)
    S.lib.expression.first_touch(voice_idx, MIDI.owner, key, raw)
    S.lib.sequencer.note_gate(voice_idx)
    local was_stopped = not S.voices[voice_idx].active
    local slot = S.lib.notes.play(voice_idx, {owner = MIDI.owner, key = key,
      pitch = S.lib.variation.midi_note(voice_idx, note), velocity = velocity / MIDI.velocity_max, park = true,
      set_own = own_setters[voice_idx],
      expression = S.lib.expression.note_values(voice_idx, {bend = raw.bend, pressure = raw.pressure, slide = 0})})
    if was_stopped and S.voices[voice_idx].active then S.midi_state.started[voice_idx] = true end
    if slot == 1 then S.lib.sequencer.own_note_taken(voice_idx) end
    if slot then
      S.lib.expression.update(voice_idx, MIDI.owner, key, {bend = raw.bend, pressure = raw.pressure, slide = raw.slide})
    else
      S.lib.expression.forget(voice_idx, MIDI.owner, key)
    end
  end
  ```
  (comment lines elided). §3.5's branch goes before the `pitch =` line's `S.lib.variation.midi_note`.
- **`M.keeps_own(voice_idx)`** (:465-474): true only when MIDI's held own note's key is down; a latched one is `S.lib.notes.forget`ten with its expression and false returned. Called by the sequencer's `other_owns_slot_1` (sequencer.lua:446-453).
- `release_held_notes(stop_all)` (:198-219), `reset_midi_input()` (:225-...). Constructor free locals 169 (lua.md §9).

### Every use of `rate_root_note`

| Where | Expression |
|---|---|
| `lib/notes.lua:29` | `rate_root_note = 60` (NOTES) |
| `lib/notes.lua:303` | `local root = M.freeze_reference(voice) or NOTES.rate_root_note` (note_values) |
| `lib/notes.lua:319` | `return NOTES.rate_root_note + 12 * math.log(rate) / math.log(2)` (own_pitch) |
| `lib/midi_in.lua:26` | `rate_root_note = 60` (MIDI) |
| `lib/midi_in.lua:414` | `local id, value = prefix .. "grain_pitch", 2 ^ ((pitch - MIDI.rate_root_note) / 12)` (own_setters) |
| `lib/sequencer.lua:345` | `return S.lib.midi_in.MIDI.rate_root_note + SEQ.semitones * log2(value)` (value_note) |
| `lib/engine/StrataNotes.sc:26-27` | `noteRateRootNote { ^60 }`; `absoluteNoteRate` :32-34 |
| `test/unit/docs_test.lua:2143-2145` | the three-way equality test (§0, item 5) |

`lib/variation.lua:32` `reference_octave = 60` is the scale's (below). No other hardcoded 60 for pitch was found in `lib/`.

### lib/variation.lua

- `M.quantizes(voice_idx)` (:90-93): `voice.extras.quantize == 1`.
- **The reference function** `M.scale_note(voice_idx, freq)` (:100-107):
  ```lua
  function M.scale_note(voice_idx, freq)
    if voice_uses_synth(voice_idx) then
      local reference = S.lib.notes and S.lib.notes.freeze_reference(voice_idx)
      if reference then return reference end
      return freq_to_note(freq or S.voices[voice_idx].params.freq)
    end
    return M.root() + V.reference_octave
  end
  ```
- `M.send_scale_note(voice_idx, freq)` (:110-113): running voices only, `engine.setGrainParam(voice_idx - 1, "scaleNote", M.scale_note(voice_idx, freq))`.
- `M.midi_note(voice_idx, note)` (:222-225): `if M.quantizes(voice_idx) then return M.snap_note(note) end return note`.
- scaleNote senders: the variation record's `sync` (:317-321, every voice sync, the voice maybe not yet running: `engine.setGrainParam(voice_idx - 1, "scaleNote", M.scale_note(voice_idx, S.lib.engine_sync.engine_base_value("v" .. voice_idx .. "_freq")))`); the freq filter (:208); quantize's action (:303); `S.register_source_change` (:349); `root`'s action, every voice (:379); notes' freeze hook (notes.lua:846); sequencer `set_override`/`clear_override` (sequencer.lua:296, :301, synth freq only).

### lib/sequencer.lua

- `set_override(voice_idx, param_id, value)` (:294-297) and `clear_override(voice_idx, param_id)` (:299-302): `S.lib.engine_sync.set_base_override` / `clear_base_override`, plus scaleNote on a synth `freq`.
- `end_chord` (:308-312), `end_overrides(voice_idx)` (:316-322; ends chord, clears every override, `overrides[v], last_played[v] = nil`), `end_all_overrides` (:324-326). Callers of `end_overrides`: `take_position` wrap with no set step (:1050-1052), `seq_length` action (:1428), plus stop/replace paths (lua.md §2).
- `note_param(voice_idx)` (:333-337), `value_note(voice_idx, value)` (:343-346), `voice_pitch_note` (:349).
- `M.degree_semitones(voice_idx, k)` (:356-373): reads `voice_pitch_note` (so `rate_root_note` for buffer voices) and `S.lib.variation.scale_mask()`, `root()`.
- `step_chord(voice_idx, semitones, wanted)` (:425-441) → `{note_id, count, pitches, values}`; `base_note = value_note(voice_idx, base)`.
- `chord_note(voice_idx, chord, k, velocity, own)` (:464-473): the note record for `S.lib.notes.play` (owner `SEQ.note_owner = "seq"`, key k, `quiet = own`, `extra_only = not own`, `set_own` sets the note override).
- `step_inputs(voice_idx, locks, semitones)` (:520-531) → `{locks, wanted, lock_ids, chord}`; `stepping[voice]` holds it from `begin_voice_step` to the first hit's `apply_step`.
- `step_pitches(voice_idx, inputs)` (:540-559): absolute pitches via `value_note`; these become `event.pitches` (`hit_event` :751-764).
- **`apply_step(voice_idx, event)`** (:568-606), whole:
  ```lua
  local function apply_step(voice_idx, event)
    local step = stepping[voice_idx] or step_inputs(voice_idx, event.locks, event.semitones)
    stepping[voice_idx] = nil
    local locks, wanted, lock_ids, chord = step.locks, step.wanted, step.lock_ids, step.chord
    local note_id = chord and chord.note_id
    local lock_value = note_id and wanted[note_id]  -- an input voice's pitch lock, the note's own param
    if note_id then wanted[note_id] = chord.values[1] end
    for k = (chord and chord.count or 0) + 1, SEQ.max_step_notes do
      S.lib.notes.release(voice_idx, SEQ.note_owner, k)
    end
    for _, param_id in ipairs(sorted_keys(overrides[voice_idx] or {})) do
      if wanted[param_id] == nil then clear_override(voice_idx, param_id) end
    end
    for _, param_id in ipairs(lock_ids) do
      if param_id ~= note_id then set_override(voice_idx, param_id, wanted[param_id]) end
    end
    local n = locks.bookmark
    if n and S.lib.bookmarks.is_set(voice_idx, n) and bookmark_in_loop(voice_idx, n) then
      S.lib.bookmarks.recall(voice_idx, n)
    end
    chords[voice_idx] = chord
    local own = note_id and not other_owns_slot_1(voice_idx)
    if own then leave_extra_slot(voice_idx) end
    if note_id then
      chord.lock_value = lock_value
      chord.own = S.lib.notes.play(voice_idx, chord_note(voice_idx, chord, 1, event.velocity, own)) == 1
      if not chord.own then
        wanted[note_id] = lock_value
        end_note_override(voice_idx, note_id, lock_value)
      end
    end
    local held = {}
    for param_id in pairs(wanted) do held[param_id] = true end
    overrides[voice_idx] = next(held) ~= nil and held or nil
    last_played[voice_idx] = event.step
  end
  ```
  A step with no notes never calls `S.lib.notes` (lua.md §6). `voices_play(event)` (:631-648) calls `apply_step` at `event.first`, then `S.lib.engine_sync.start_voice` for a stopped voice (:637-640), `engine.retrigger` (:645), `play_chord` (:613-622).
- `ATTR_CHECKS` (:187-196), `set_step_attr`, `valid_steps`, the `steps` block: lua.md §1 (an unknown key rejects a whole scene). A `slice` key needs an `ATTR_CHECKS` entry; `step_locks` copies only `SEQ.lock_keys` (:738-747), so a `slice` reaches `apply_step` only through `S.pattern_steps[voice][step]` or a new event field (`hit_event` :751-764 builds `event` from `attrs`).
- Seq record (`name = "seq"`, :1418-1459): its `discrete`/`scene_defaults` pattern for options is the closest model for scan's options (`seq_gate` grain key `{name = "seqGate", value = function(option) return option - 1 end}`).

---

## 2. Buffers, takes, files, waveforms (2d)

`S.buffers[slot]` fields and the per-change table: buffers.md §4.

### Where a slot's state settles or empties (lib/buffers.lua)

| Function | Lines | What it sets |
|---|---|---|
| `buffer_display_changed()` (local; `M.display_changed`) | :140-144 | `request_redraw(); grid_redraw(); remember()` |
| `confirm_buffer_audio(slot, is_take)` (global) | :161-183 | **audio settled**: `loaded = true, settled_empty = false, restoring = false`; a take: `name = "take n"`, `path = scratch` unless `take_unsaved`; a restore counts; `S.lib.waveforms.stale(slot)`. Called from `settle_buffer_slot` (:202) and the adoption in `buffer_state_changed` (:800) |
| `settle_buffer_slot(slot)` (global) | :191-212 | `confirm_since = nil, awaiting_zero = false`; a take ends recording/finishing; audio → `confirm_buffer_audio`; none → `loaded = false, settled_empty = "take"/"restore"/"load"`, a take empties `name`, `path` |
| `apply_buffer_state(slot, state)` (local) | :328-350 | **a failed load's undo / a canceled take's put-back**: every shown field, `start`, `sent_start`, `sample_rate`, `file_seconds`, the file param; `waveforms.forget` or `stale` |
| `load_buffer(slot, path, start)` (global) | :446-491 | shown at once: `name`, `loaded = true`, `confirm_since = util.time()`, `path`, `missing_path = nil`, `start/sent_start`, `sample_rate, file_seconds = file_length(path)`, check fields, `awaiting_zero`; `engine.loadBuffer`; `waveforms.forget`; `buffer_display_changed()` |
| `clear_buffer(slot)` (global) | :493-518 | everything emptied (`seconds = 0`, `path = nil`, start 0, rate nil, `pending_loads = {}`); `engine.clearBuffer`; `buffer_display_changed()`. **The unbind** |
| `take_write_failed(value)` (poll) | :679-702 | forgets the scratch path (`path = nil` or `take_unsaved = true`) |
| `buffer_state_changed(value)` (poll) | :730-808 | `seconds`; `kept_state` put back via `apply_buffer_state` (:752-759); `record.slot_reported`; waveforms `changed`/`stale`; check end; settle (:795-798) or adoption (:799-802); then `remember()` (:807) |
| `buffer_load_failed(value)` (global, poll) | :827-859 | `left = emptied and empty_buffer_state(false) or resolve_previous(...)`; newest load → `apply_buffer_state(slot, left)` (:851); `buffer_display_changed()` |
| `M.recording_started(slot, playable)` | :1184-1196 | replace take: `start, sent_start, sample_rate, file_seconds = 0, 0, nil, nil` |
| `restore_buffers_from_file()` (local) | :966-1019 | per remembered path: `load_buffer(slot, path, start)` then `restoring = true`; missing: `missing_path`, `start`, `sent_start` |
| `load_buffers_from_disk()` (global) | :1023-1026 | restore, then `S.buffers_loaded = true` |
| `remembered_buffers()` | :889-896 | `{version = BUFFER_DATA_VERSION, paths = paths, starts = starts}` |
| `save_buffers_to_disk()` (global) | :902-931 | `keep_copy(".v" .. version)` when an older file was read; `data_files.write`; `state.text = encode(value)` |
| `remember` | :940-954 | skips unless `S.buffers_loaded`; compares `encode(remembered_buffers())` with `S.buffer_file.text`; one write `BUFFER_DATA_SAVE.delay` (0.1 s) later from `S.buffer_file.save_clock` |

Also `empty_buffer_state(settled_empty)` (:252-256), `buffer_state_before_load` (:272-283), `M.shown_state` (:286-293), `resolve_previous` (:300-304), `M.state_before_take` (:311-323), `M.set_start` (:1204-1221, reload via `load_buffer` after `FILES.restart_seconds`). A playable recording's end is in lib/record.lua (below).

**Version check, lines 976-990** (quoted):
```lua
    if type(loaded) ~= "table" then
      print("error loading buffers file: " .. tostring(detail))
      preserve_unloadable_buffer_file()
      return
    end
    -- version 1 (3.2) has no starts: every start is 0
    if (loaded.version ~= BUFFER_DATA_VERSION and loaded.version ~= 1) or type(loaded.paths) ~= "table" then
      print("error: buffers file has version " .. tostring(loaded.version) ..
        " or no path list, expected version " .. BUFFER_DATA_VERSION)
      preserve_unloadable_buffer_file()
      return
    end

    -- the first save keeps a version 1 file as buffers.data.v1 first (#467)
    if loaded.version < BUFFER_DATA_VERSION then S.buffer_file.version = loaded.version end
```
`BUFFER_DATA_VERSION = 2` at `lib/constants.lua:24` (exported :313). `preserve_unloadable_buffer_file` (:956-960) uses `S.lib.scenes.move_aside_unloadable_file(path, "buffers")`.

**`M.status(slot)`** (:1147-1163): first match of `finishing`, `armed`, `loop`/`dub`/`recording`, `loading` (`confirm_since ~= nil`), `loaded`, `unsettled`, `missing`, `empty`; nil out of range. **`M.is_free(slot)`** (:1167-1170): `empty` or `missing`. Invariant "buffer slots" :1103-1136.

**Tests that pin the file's version and layout** (test/unit/buffers_test.lua):
- :637 "buffers.data format, restored scratch takes and the SETUP count" — `assert_equal(saved.version, 2, "format version")` (:657) and every `paths[slot]`.
- :925-978 "a buffers file that fails to load does not stop init and survives cleanup" — bad files incl. `{ version = 99, paths = {} }` and `{ version = 1, paths = "x" }`, kept as `.bak`.
- :980 "cleanup leaves buffers.data alone when init never loaded it (#72)" (a version 1 sentinel).
- :2037 "buffers.data saves version 2 with starts and loads version 1 with starts 0" — `assert_equal(saved.version, 2)` (:2048), v1 loads with start 0, damaged and non-finite starts.
- :2135-2225 the #301 write tests (:2159 `assert_equal(remembered.version, 2)`).
- :2227 "a version 1 buffers.data is kept as buffers.data.v1 when it is first replaced (#467)".
- `docs/notes/lua/buffers.md:21, :120` and AGENTS.md:290 state "version 2"/`BUFFER_DATA_VERSION (2)`.

### lib/record.lua

- Record params (`M.add_params`, :66-75, group `strata_record`, 6): `record_source`, `record_feedback` (0-100 %), `record_loop` ({"off", "on"}), `record_threshold`, `record_sync` (`SYNC_OPTIONS = {"off", "beat", "bar"}`, :63), `record_beats` (1-64, default 16). `record_duration` and `record_level` are in the buffers group (`lib/params_setup.lua:668, :675`). PSET only.
- `sync_delay()` (:80-89): 0 when `record_sync == 1`; else the delay to the next beat/bar from `clock.get_beats()` and `S.lib.params_setup.beat_seconds_now()`.
- `M.take_length()` (:99-116): `{seconds}` (sync off) or `{seconds, beats, capped}` at `beat_seconds_now()`.
- **A take starts** in `record_buffer(slot)` (global, :133-209). The send (:183-184):
  ```lua
  engine.recordBuffer(slot - 1, seconds, params:get("record_level"), feedback, params:get("record_source") - 1,
    threshold, loop and 1 or 0, delay, util.time() % 1000)
  ```
  with `delay = sync_delay()` (:165) and `seconds = M.take_length().seconds` (:168). Then `takes[slot] = {number, kind = playable and "playable" or "take", phase, started_at, seconds, loop, previous}` (:187-189), `S.lib.buffers.recording_started(slot, playable)` (:190). The synced state is `params:get("record_sync") > 1` (as `synced()` in lib/pages/buffer.lua:183). The tempo at the start is `60 / S.lib.params_setup.beat_seconds_now()`; nothing stores it today.
- **`record_state_changed(value)`** (local poll handler, :257-315), whole in substance:
  ```lua
  local STATE_ARMED, STATE_RECORDING, STATE_ENDED, STATE_CANCELED = 0, 1, 2, 3
  local function record_state_changed(value)
    if type(value) ~= "number" or value ~= value or value < 0 or value == math.huge
      or value ~= math.floor(value) then return end
    local slot = math.floor(value % NUM_BUFFERS) + 1
    local rest = math.floor(value / NUM_BUFFERS)
    local state_code = rest % 4
    local number = math.floor(rest / 4)
    local buffer = S.buffers[slot]
    local take = takes[slot]
    if not buffer or not take or not buffer.recording or number ~= buffer.records_sent or take.number ~= number then
      return
    end
    if state_code == STATE_ARMED then
      if take.phase ~= "recording" then take.phase = "armed" end
    elseif state_code == STATE_RECORDING then
      take.phase = "recording"
      take.started_at = util.time()
      if take.kind == "take" and not S.buffer_record_clocks[slot] and not buffer.finishing then
        start_take_timer(slot, take.seconds)
      end
    elseif state_code == STATE_ENDED then
      if take.kind == "playable" then
        M.cancel_timer(slot)
        takes[slot] = nil
        buffer.recording = false
        buffer.name = "take " .. slot
        buffer.path = scratch_take_path(slot)
        buffer.start, buffer.sent_start, buffer.sample_rate, buffer.file_seconds = 0, 0, nil, nil
        buffer.loaded = buffer.seconds > 0
        set_buffer_file_param(slot, _path.audio)
        S.lib.waveforms.stale(slot)
      else
        if not buffer.finishing then
          M.cancel_timer(slot)
          finish_buffer_take(slot)
        end
        if buffer.seconds > 0 then settle_buffer_slot(slot) end
      end
    elseif state_code == STATE_CANCELED then
      M.cancel_timer(slot)
      takes[slot] = nil
      buffer.recording = false
      buffer.finishing = false
      buffer.confirm_since = nil
      if take.kind == "take" then
        buffer.name, buffer.path, buffer.loaded, buffer.seconds = "empty", nil, false, 0
        buffer.settled_empty = false
        buffer.kept_state = take.previous
      end
    end
    S.lib.buffers.display_changed()
  end
  ```
  **The overdub/loop end** (where a file becomes a take, §4.1) is the `STATE_ENDED` + `"playable"` branch (:278-288); the previous `buffer.path` is still the file's until it is overwritten at :283. A replace take settles through `settle_buffer_slot` → `confirm_buffer_audio(slot, true)`.
- `M.state(slot)` (:214-217), `M.slot_reported` (:241-248), `finish_buffer_take` (:43-55, also `S.finish_buffer_take`), `M.cancel_timer` (:22-27). Start `START_ORDER.record_poll` (65), cleanup `CLEANUP_ORDER.record` (132).

### Saves (lib/buffers.lua; see §0 item 2)

- `save_buffer(slot)` (:580-589): `save_refusal` → `buffer_save_path(slot)` → `send_save(slot, path, 0, 1, false)`; returns `true` or `false, reason` (`"invalid"`, `"busy"`, `"empty"`).
- `save_buffer_loop(slot)` (:615-627): `loop_region(slot)` (:594-610, selected voice's loop if it reads the slot, else the lowest voice's, else whole) → `send_save(slot, path, start, length, true)`.
- `send_save` (:548-554): `pending_saves` entry `{number, path, loop = loop or nil}`, `engine.saveBuffer(slot - 1, path, start, length)`.
- **The result lands** in `buffer_save_result(value)` (:641-668): decodes `((save * 2) + failed) * NUM_BUFFERS + index`, finds the pending save, prints, flashes only for the newest. A whole save is `save.loop == nil`. Nothing records what the slot held when the save was sent (a load between send and report is possible).
- Paths: `buffer_audio_dir = _path.audio .. "strata/"` (:119); `buffer_save_path(slot, kind)` (:535-543).

### lib/waveforms.lua (whole file 215 lines)

- State: `points[slot]`, `marked[slot]`, `awaiting[slot]`, `playable_due[slot]` (:28-36).
- `peaks_path(slot)` (:45-47): `S.lib.scenes.scene_data_dir .. "buf" .. slot .. ".peaks"`.
- `parse(slot, text)` (:51-72): magic `"strata-peaks 1"`, `fields[key]`, `slot`, `frames`/`rate` checked against `S.buffers[slot].seconds` (±0.01) then dropped; 64 values in 0-1.
- **`read(slot)`** (local, :83-98):
  ```lua
  local function read(slot)
    if awaiting[slot] then return end
    local values = nil
    if S.buffers[slot].seconds > 0 then
      local file = io.open(peaks_path(slot), "r")
      if file then
        local text = file:read("*a")
        file:close()
        values = text and parse(slot, text) or nil
      end
    end
    if same_values(points[slot], values) then return end
    points[slot] = values
    request_redraw()
    if S.lib.grid_core.any_page(GRID_WAVEFORM_PAGE) then grid_redraw() end
  end
  ```
  A "peaks were read for slot n" call (§4.4) fits between :93 and :94 (every read, same values included) or after :95 (only on change); `parse` would have to return `frames` and `rate` too for §3.1.
- `M.stale(slot)` (:103-107), `M.forget(slot)` (:124-129), `M.changed(slot)` (:135-140), **`M.peaks(slot)`** (:143-146: nil unless `seconds > 0`), **`M.bins(slot, n)`** (:149-161), `mark_playable_recordings` (:167-181), `tick` (:184-193: one marked slot per frame), the clock loop (start step `START_ORDER.waveforms` = 140, :203-211; `M.read_clock`; each tick in `contained_call`); cleanup `CLEANUP_ORDER.waveforms` (126).

### lib/data_files.lua

- `M.read(path)` (:301-316) → value; or `nil, "missing"`; or `nil, "unreadable", why`.
- `M.write(path, value)` (:347-353) → `true, "written"` / `true, "unchanged"` / `false, problem` (via `replace_file` :322-340, a checked `.part` renamed).
- `M.set_aside(path, suffix)` (:374-380) → backup name, or `nil, why`.
- `M.keep_copy(path, suffix)` (:390-406) → name and `"copied"`/`"found"`; `true` (no file); `true, "full"`; or `nil, why`.
- `M.encode(value)` (:63), `M.decode(text)` (:127), `M.read_text` (:296).
- Caps `DATA_FILES` (:24-41): `max_bytes = 4 * 1024 * 1024`, `max_tables = 32768`, `largest_scenes_tables = 7394`, `backups = 9`.

### A whole data-file example: io.data (lib/io/rig.lua)

- Name and version: `RIG = {file = "io.data", version = 1, backup_suffix = ".bak", order, specs}` (:18-41). Path `_path.data .. "strata/" .. RIG.file` (:56).
- Write (:78-83):
  ```lua
  local function write(with_values)
    util.make_dir(_path.data .. "strata/")
    local written, problem = S.lib.data_files.write(rig_path(), {version = RIG.version, values = with_values})
    if not written then print("strata: " .. RIG.file .. " not saved: " .. tostring(problem)) end
    return written
  end
  ```
  `M.set` writes first and changes the value only when the write worked (:94-108).
- Validation `problem_with(value)` (:152-161).
- Load, the start step (:168-184):
  ```lua
  S.register_start(S.constants.START_ORDER.io_rig, function()
    values = defaults()
    started = true
    local path = rig_path()
    local value, outcome, why = S.lib.data_files.read(path)
    if value == nil and outcome == "missing" then return end
    local problem = value == nil and (why or outcome) or problem_with(value)
    if problem then
      local backup, failure = S.lib.data_files.set_aside(path, RIG.backup_suffix)
      print("strata: " .. RIG.file .. " not used (" .. problem .. "): the rig settings are the defaults; "
        .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure))))
      return
    end
    for _, key in ipairs(RIG.order) do
      if value.values[key] ~= nil then values[key] = value.values[key] end
    end
  end)
  ```
- Save at cleanup (:187-189): `S.register_cleanup(S.constants.CLEANUP_ORDER.io_rig_save, function() if started then write(values) end end)`. Invariant "rig" (:192-199).
- **SETUP problem line: none** (§0 item 10). SETUP's rows (`add_data_file_rows`, lib/pages/setup.lua:152-163) iterate `{{"scenes", S.scene_file}, {"buffers", S.buffer_file}}` with `SETUP_PAGE.file_texts` (:38-39); the state record shape is `S.buffer_file = {version, problem, backup, text, save_clock}` (lib/buffers.lua:884).
- Start/cleanup orders available (lib/constants.lua:187-224, 250-290): `matrix_load = 108`, `notes_load = 109`, `buffers_load = 110`, `startup_clock = 120`; `matrix_save = 36`, `io_rig_save = 38`, `buffer_paths_save = 40`. A samples.data load must precede `buffers_load` (110) if the restore binds settings.

---

## 3. Playheads, positions, grids (2a, 2e)

### lib/playheads.lua (219 lines)

- `heads[v] = {phase, at}` (:18); `clock_id`; `shown_signature`.
- `running_buffer_voice(v)` (:30-32): valid, active, `voice_uses_buffer`.
- **`scan_effective`** (:37-42): quoted in lua.md §8. Unit is "loop fractions a second".
- **`M.reset(v)`** (:45-48): `heads[v] = {phase = 0, at = util.time()}`.
- **`M.advance(v)`** (:52-64):
  ```lua
  function M.advance(voice_idx)
    if not valid_voice(voice_idx) then return end
    local head = heads[voice_idx]
    if not head then
      M.reset(voice_idx)
      return
    end
    local now = util.time()
    if running_buffer_voice(voice_idx) and now > head.at then
      head.phase = (head.phase + scan_effective(voice_idx) * (now - head.at)) % 1
    end
    head.at = math.max(now, head.at)
  end
  ```
- **`M.position(v)`** (:68-75): `return start + ((buf_pos + heads[voice_idx].phase) % 1) * length` with `start`, `length` = `params:get` of `loop_start`, `loop_length` and `buf_pos = engine_param_value(...)`. The `buf_pos` 1 disagreement: buffers.md §5, Code wins (engine holds under `lastLoopPosition`, `StrataLoop.sc:17, 59`).
- **`M.spread(v)`** (:79-82): `grain_spread * loop_length`.
- `M.cell_of(fraction, columns)` (:85-87), `M.column` (:90-94), `M.record_head(slot)` (:100-110), **`M.has_audio(slot)`** (:116-118: `valid_buffer_slot(slot) and (S.buffers[slot].seconds or 0) > 0`), `M.moving(slot)` (:123-131).
- The clock: `TICK_PARTS` (:175-180) `{scan = follow_scans, holds = end_stale_holds, blink = advance_blink, redraw = redraw_position_grids}`, each in `contained_call`; `start_clock` (:202-210) sleeps `1 / PLAYHEADS.update_hz` (15); `shows_positions()` (:151-161) is true on page 5 or a layout's `strip_page`; `redraw_position_grids` (:163-173) repaints when `S.lib.positions.display_signature()` changes.
- **Grain restart** (:212-214): `S.register_grain_restart(function(voice_idx) M.reset(voice_idx) end)`; start `START_ORDER.playheads` (150), cleanup `CLEANUP_ORDER.playheads` (122). The other reset: `S.lib.positions.jump` (positions.lua:162). A retrigger resets nothing (lua.md §8).

### lib/positions.lua (730 lines)

- **`M.LEVELS`** (:20-27):
  ```lua
  M.LEVELS = {
    outside = 1, outside_range = 2, inside = 4, inside_range = 4, held = 11, record_head = 13, playhead = 15,
    bookmark = 6, recalled = 10, stored = 15, key_down = 15, key_up = 4, whole = 15,
    waiting_high = 15, waiting_low = 2, waiting_ticks = 4, waiting_phases = 2,
  }
  ```
  `STRIP_KEYS = {"store", "hold", "whole"}` (:32); `DISPLAY_CELLS = GRID_PAGES.position_cells` (16, :34).
- **Port record** (`record_of(port)`, :327-332), in `S.lib.grid_core.port_state(port).positions`: `{hold = {[voice] = page}, store = {[voice] = page}, store_down = page|nil, pressed = {[voice] = key}, held = {voice, cell, cells, page}|nil}`; `records[port]` keeps it; `end_stale_port` (:337-359) clears a gone port or a page left.
- `selects_grid_voice(port)` (:379-382): `layout.selects_grid_voice == true` (128h, 128v, 64; never 256). `storing(record, v)` (:387-389).
- **`M.grid_key(port, voice_idx, cell, cells, z)`** (:395-416): z 0 ends `record.held`; z 1 on a buffer voice: `select_grid_voice(voice_idx)` where the layout selects; a second held key → `S.lib.quantize.schedule("position" .. voice_idx, function() M.set_loop(voice_idx, (low - 1) / cells, high / cells) end, "v" .. voice_idx .. " jump")`; else records `held` and schedules `M.jump(voice_idx, (cell - 1) / cells)`.
- **`M.strip_key(port, voice_idx, key, z)`** (:420-491): key 1-4 recall (`recall_bookmark_quantized`) or store with store held; `"store"`, `"hold"` (`M.hold_scan(v, on, "grid:" .. port)`), `"whole"` (`whole_loop`). Presses on a non-buffer voice do nothing.
- **`row_context(voice_idx, cells)`** (local, :501-534): nil unless a buffer voice with `has_audio`; head from `playheads.position` or `start + buf_pos * length`; cached by `voice:cells` and a key string plus the peaks table's identity.
- `cell_level(context, cell)` (:536-546); **`M.grid_level(voice_idx, cell, cells)`** (:550-555; 0 out of range or no context); **`M.strip_level(voice_idx, key, port)`** (:560-582).
- **`M.display_signature()`** (:587-602): per voice the 16 `cell_level`s, then each bookmark's `strip_level` and `string.format("%.6f", bookmark)`, then the three strip keys' levels. Anything a slice row shows must enter this string, or the 15 Hz clock never repaints it.
- `M.jump` (:149-163), `M.set_loop` (:167-174), `whole_loop` (:177-181), `M.recall_bookmark` (:183-187), `M.recall_bookmark_quantized` (:194-199), `M.store_bookmark` (:213-...).

### lib/grid/core.lua

- **`M.port_state(port)`** (:154-157): `port_states[port] = port_states[port] or {}`, emptied when the grid is removed; `M.existing_port_state(port)` (:161-163).
- **`M.layout_of(port)`** (:545-548): `S.registry.grid_layouts[grid_layout(grid_port)]` or nil.
- **`select_grid_voice(voice_idx)`** (global, :864-868): sets `S.grid_voice_select`, clamps `S.param_page`.
- **`M.on_hold(port, x, y, seconds, fn)`** (:174-185): runs fn once if still held after `seconds`; release, removal and cleanup cancel.
- `M.page(port)` (:74-76), `M.set_page(port, page)` (:84-93, ends the port's gestures and holds), `M.any_page(page)` (:96-101). `GRID_LAYOUT.fx_fader_ids` (:48).

### The four layouts' position pages

**256** (`lib/grid/layout_256.lua`): `LAYOUT_256.positions_key_column = 12`, `strip_first_row = 9`, `strip_key_columns = {[1] = 1, [2] = 2, [3] = 3, [4] = 4, [6] = "store", [7] = "hold", [8] = "whole"}` (:45-47). Key handler (`grid_key_256`, :278-290):
```lua
  function grid_key_256(port, x, y, z)
    local page = grid_core.page(port)
    if page == PAGES.positions and y ~= 8 and y ~= 16 then
      local strip_voice = y - LAYOUT_256.strip_first_row + 1
      if y <= NUM_VOICES then
        S.lib.positions.grid_key(port, y, x, PAGES.position_cells, z)
      elseif strip_voice >= 1 and strip_voice <= NUM_VOICES and LAYOUT_256.strip_key_columns[x] then
        S.lib.positions.strip_key(port, strip_voice, LAYOUT_256.strip_key_columns[x], z)
      end
      return
    end
```
Redraw (`grid_redraw_256`, :458-472):
```lua
    if page == PAGES.positions then
      for voice_idx = 1, NUM_VOICES do
        for cell = 1, PAGES.position_cells do
          grid_device:led(cell, voice_idx, S.lib.positions.grid_level(voice_idx, cell, PAGES.position_cells))
        end
        local y = LAYOUT_256.strip_first_row + voice_idx - 1
        for x, key in pairs(LAYOUT_256.strip_key_columns) do
          grid_device:led(x, y, S.lib.positions.strip_level(voice_idx, key, port))
        end
      end
      grid_redraw_256_transport(port, grid_device)
      grid_redraw_256_lock(port, grid_device)
```
Page key at (12, 8) (:304-305), lit :578-579.

**128h** (`lib/grid/layout_128h.lua`): strip on page 4: `strip_bookmark_row = 5`, `strip_key_row = 6`, `strip_first_column = 13`, `grid_voice_column = 11`, `position_page_level = 10` (:34-49). `strip_key_of(x, y)` (:111-120). Page 5 reached from page 4's sources key (`control_row_key`, :175-191: `page_offset == PAGES.sources and grid_core.page(port) == PAGES.sources` → `set_page(port, PAGES.positions)`). Key handler (`grid_key_128h`, :194-233):
```lua
    if z == 0 then
      if y ~= LAYOUT_128H.control_row and x >= 1 and x <= PAGES.position_cells then
        if page == PAGES.positions and y <= NUM_VOICES then
          S.lib.positions.grid_key(port, y, x, PAGES.position_cells, 0)
        elseif page == PAGES.scenes and recorder_at(x, y) then
          grid_core.gesture_key(port, x, y, 0, recorder_at(x, y))
        elseif page == PAGES.sources then
          local key = strip_key_of(x, y)
          if key then
            S.lib.positions.strip_key(port, S.grid_voice_select, key, 0)
          end
        end
      end
      return
    end
    ...
    if page == PAGES.positions then
      if y <= NUM_VOICES then S.lib.positions.grid_key(port, y, x, PAGES.position_cells, z) end
    ...
    elseif page == PAGES.sources then
      local key = strip_key_of(x, y)
      if key then
        S.lib.positions.strip_key(port, S.grid_voice_select, key, z)
      else
        source_page_key(x, y)
      end
```
Redraws: `redraw_strip(port, grid_device)` (:302-313, page 4, grid voice; marks column 11) and `redraw_position_page(grid_device)` (:316-322, rows 1-7). Registered `{key = grid_key_128h, redraw = grid_redraw_128h, selects_grid_voice = true, strip_page = PAGES.sources}` (:373-376).

**128v** (`lib/grid/layout_128v.lua`): `strip_first_row = 10`, `strip_keys = {1, 2, 3, 4, "store", "hold", "whole"}` (:52-53), control column 8. Keys (`grid_key_128v_controls` :133-150, `grid_key_128v` :153-163):
```lua
    if page == PAGES.positions then
      if x == LAYOUT_128V.control_column then
        if z == 1 or y >= LAYOUT_128V.strip_first_row then grid_key_128v_controls(port, y, page, z) end
      elseif x <= NUM_VOICES and y <= PAGES.position_cells then
        S.lib.positions.grid_key(port, x, y, PAGES.position_cells, z)
      end
      return
    end
```
(controls: `elseif page == PAGES.positions then local key = LAYOUT_128V.strip_keys[y - LAYOUT_128V.strip_first_row + 1]; if key then S.lib.positions.strip_key(port, S.grid_voice_select, key, z) end`). Redraw (`grid_redraw_128v_positions`, :261-273): each voice's column, the grid voice's `+1` (#444, `math.min(15, level + floor)`), then the strip down column 8.

**64** (`lib/grid/layout_64.lua`): `position_rows = {1, 2}`, `strip_row = 3`, `strip_keys = {[1] = 1, [2] = 2, [3] = 3, [4] = 4, [6] = "store", [7] = "hold", [8] = "whole"}`, voice row 7 (:25-31). `positions_key(port, x, y, z)` (:99-111):
```lua
  local function positions_key(port, x, y, z)
    local voice_idx = S.grid_voice_select
    if y == LAYOUT_64.position_rows[1] or y == LAYOUT_64.position_rows[2] then
      local cell = (y - LAYOUT_64.position_rows[1]) * position_width(S.grids[port].cols) + x
      S.lib.positions.grid_key(port, voice_idx, cell, PAGES.position_cells, z)
    elseif y == LAYOUT_64.strip_row then
      local key = LAYOUT_64.strip_keys[x]
      if key then S.lib.positions.strip_key(port, voice_idx, key, z) end
    elseif y == LAYOUT_64.voice_row and z == 1 and x >= 1 and x <= NUM_VOICES then
      select_grid_voice(x)
    end
  end
```
`positions_redraw(port, grid_device)` (:154-180): rows 1-2 the grid voice's 16 cells, row 3 the strip, rows 4-6 dark, row 7 voice picker, row 8 play/voices. Reached by a 0.5 s hold of (1, 8) (:63-75).

### Tests that pin page 5 (names, file:line)

- `test/unit/positions_test.lua`: :43, :55, :64, :73, :86 jumps and loops; :94 "a two-key press sets the loop..."; :118; :152; :191 "only buffer voices answer position keys..."; :210 "a position press selects the grid voice on the 128s and the 64, never on the 256"; :226; :321 "a row's LED levels are built once while nothing in it changes..."; **:589 "grid levels: empty 0, outside the loop 1-3, inside 4-8, held 11, record head 13, playhead 15"**; :625 "a stopped voice shows its start position at 15"; **:633 "strip keys recall, store with store held, hold the scan and restore the whole loop"**; :752-:874 strip release/store/hold per layout; :893, :905, :921, :932, :946, :961, :982 "a row's levels are rebuilt when the slot's peaks change (#398)"; :1001 "a voice that reads no buffer has a dark strip..."; :1051 "a position key and a bookmark key wait for the bar...".
- `test/unit/grid_layout_256_test.lua`: :907 "256: the key at x 12, y 8 shows page 5...", :918 "256: a position press jumps and a held pair sets the loop", **:930 "256: position LEDs follow grid_level for every voice"**, :948, :965, **:982 "256: voice v's strip on row 8 + v recalls, stores, holds and restores the whole loop"**, :1012.
- `test/unit/grid_layout_128h_test.lua`: :404, **:419 "128h: a position press jumps, selects the grid voice and a held pair sets the loop"**, **:434 "128h: the grid voice's strip on page 4 recalls..."**, :463, :475, :493, :525, :553, :569, :599, :682.
- `test/unit/grid_layout_128v_test.lua`: **:397 "128v: columns 1-7 are the voices' positions, row 1 the slot's start"**, :424, **:441 "128v: column 8 rows 10-16 are the grid voice's strip"**, :479, :510, :541, :597.
- `test/unit/grid_layout_64_test.lua`: :295, **:318 "64: rows 1-2 are the grid voice's 16 positions and a pair may span both"**, :334, **:349 "64: row 3 is the strip and row 7 picks the grid voice"**, :380, :427, :438, :456.

### Grid test helpers

- `context.grid.plug(port, cols, rows)` → a device (`test/norns_stubs.lua:2189-2219`); `context.grid.press(port, x, y, z)` (:2234-2241); `device:get_led(x, y)` (:2127); `context.grid.unplug(port)` (:2221).
- Local helpers: `grid_tap(context, x, y)` (grid_layout_256_test.lua:810-812) and `page5_grid()` (:897-905):
  ```lua
  local function page5_grid()
    local context = load_strata(); finish_startup(context)
    local S = local_value("S")
    S.buffers[1].seconds = 16
    local device = context.grid.plug(1, 16, 16)
    params:set("v1_source", S.constants.SOURCE_SYNTH + 1)
    params:set("v1_loop_length", 1); params:set("v1_loop_start", 0)
    return context, S, device
  end
  ```
- positions_test.lua: `buffer_voices()` (:12-20), `half_peaks(S)` (:581-587, stubs `S.lib.waveforms.bins`), `with_grid(S, cols, rows)` (:748-750: `S.grids[1] = {cols, rows}`).

---

## 4. Voice params and VOICE (2a, 2b, 2f)

- **`S.register_voice_params(record)`** (`lib/state.lua:182-226`). Allowed fields (`VOICE_PARAM_FIELDS`, :149-151): `name, count, add, add_first, grain_keys, sync, scene_defaults, discrete, scene_ranges, voice_rows, layout_states, normalize_scene, fader, randomize`. Checks: open (closes at init: `voice_params` is in `INIT_READ`); unique name; `count` whole ≥ 1; `add` function; `grain_keys` each `"name"` or `{name, value = fn}` (`is_grain_key` :155-158); `sync` function; **`scene_defaults` values must be numbers**; **`discrete` = `{min, max}` whole, holding its default**; `scene_ranges` continuous only, holding default; `voice_rows = {section, rows = {keys}, when = fn, before = <section>}`; `layout_states = {{name, setup = fn}}`; `normalize_scene` function; **`fader ~= true`**; `randomize = {key = fn}`. The comment (:160-181) and `docs/notes/lua/params.md:59-80, :118` document each.
- **`S.lib.params_setup.add_voice_extra(voice_idx, record, key, param)`** (`lib/params_setup.lua:819-858`): id `v<i>_<key>`; wrapped action: `pset.whole` for number params, the key's param filter, `extras[key] = x`, `note_param_edit(param_id)`, `send_param_to_engine(param_id, x)`, then the own action; `extras[key] = params:get(param_id)` at add; a grain key gets `add_voice_sender` (running voices only, `lib/engine_sync.lua:105-111`) sending `engine.setGrainParam(voice_idx - 1, name, sent)` via `grain_key_message`.
- The voice sync sends registered grain keys by sorted key name, then each record's `sync` (`send_registered_voice_values`, `lib/engine_sync.lua:584-603`); a start does this before `voiceOn` (§0 item 1).
- **The loops record** (`lib/loops.lua:117-161`), whole:
  ```lua
  local record
  record = {
    name = "loops",
    count = 2,
    add = function(voice_idx)
      S.lib.params_setup.add_voice_extra(voice_idx, record, LOOP.start_key, {
        type = "control",
        name = "loop start",
        controlspec = controlspec.new(0, 1, "lin", 0, 0),
        formatter = fraction_text,
        action = function() clamp_length(voice_idx) end,
      })
      -- exponential, so short loops get fine steps
      S.lib.params_setup.add_voice_extra(voice_idx, record, LOOP.length_key, {
        type = "control",
        name = "loop length",
        controlspec = controlspec.new(LOOP.min_length, 1, "exp", 0, 1),
        formatter = fraction_text,
      })
    end,
    grain_keys = {[LOOP.start_key] = LOOP.start_engine, [LOOP.length_key] = LOOP.length_engine},
    scene_defaults = {[LOOP.start_key] = 0, [LOOP.length_key] = 1},
    normalize_scene = normalize_scene,
    voice_rows = {
      section = LOOP.section,
      rows = {LOOP.start_key, LOOP.length_key},
      when = function(voice_idx) return M.uses_buffer(voice_idx) end,
    },
    layout_states = layout_states,
    fader = false,
    randomize = {
      [LOOP.start_key] = function() return math.random() * LOOP.random_max_start end,
      [LOOP.length_key] = function(voice_idx)
        local room = M.max_length(voice_idx)
        local shortest = math.min(LOOP.random_min_length, room)
        return shortest + math.random() * (room - shortest)
      end,
    },
  }
  S.register_voice_params(record)
  ```
  `LOOP.section = "synth"` (:23): a buffer voice's synth section is `BUFFER_SYNTH_KEYS = {"buf_pos", "buf_rate", "buf_scan"}` (`lib/ui/voice_rows.lua:17`), and registered rows go at the end of their section.
- **How `when` hides a row**: `sections_with_registered_rows(voice_idx)` (`lib/ui/voice_rows.lua:57-87`): `if not voice_rows.when or voice_rows.when(voice_idx, key) then table.insert(keys, key) end` (:64); a section not present is inserted before `before`, else at the end; read at each draw (`voice_page_rows`, :110-125).
- **An option row**: `param_kind` (:91-97) gives `"option"`; VOICE draws `value_text(row)` = `params:string(row.param_id)` trimmed (`lib/pages/voice.lua:94-102`, binary rows `"on"/"off"`); E3 is `enc_param_delta(n, row.param_id, d)` (`voice_enc`, :243-256; binary rows `set_binary_param`).
- **`buf_scan`'s row**: the param is `lib/params_setup.lua:1022-1035` (`controlspec.new(-2, 2, "lin", 0.01, v.grain.buf_scan)`, no unit, no formatter; sender `engine.setGrainParam(engine_voice, "bufScan", value)`). VOICE shows `params:string`, so a unit suffix comes either from a `formatter` on that param (`lib/params_setup.lua`, not in 2a's file list) or a special case in `value_text` (`lib/pages/voice.lua:94-102`, as `mod_source_%d+` already is). `get_param_spec` does not cover buf params: not found for `buf_scan` (they are grain params added directly).
- `buf_scan` is also an arc BUFFER ring 4 (`lib/arc/buffer.lua:20`), a grid fader key (`lib/grid/faders.lua:20`), the LFO destination `v<i> scan` (`lib/lfos.lua:107`), a scene grain path (`lib/scenes.lua:128`), mutation (`lib/mutation.lua:211`), VOICE randomize (`lib/pages/voice.lua:176`).
- **Tests a new record meets** (`test/unit/registries_test.lua`): :64 "a registered voice param is added, stored, sent and synced"; :167 "the register functions check their argument and refuse duplicates"; :467 "registered rows appear in their VOICE section, new sections in place, binary rows have kind binary"; :492 "VOICE lays out registered rows and sections on every voice and source"; :517 "a registered record's layout states are VOICE's too"; :570 "a version 2 scene migrates to 7 with every registered default" (0b moves it to 8); :615 "scenes validate registered fields"; **:646 "discrete extras switch at the end of a transition, after the source"**; **:685 "randomize, mutations and the fader pages never touch registered params"**; **:707 "every registered scene default equals its param's default"** (these three run over every record, so a new record is checked automatically); :801 scene_ranges. Scenes: `test/unit/scenes_test.lua:2138` "a registered discrete binary or number scene field holds a whole value in its range (#411)", :2235 "a recall and a fade set a voice's registered fields in sorted key order (#531)". Closest module tests: loops — `test/unit/loops_test.lua:42` "loop params default to the whole slot and reach the engine", :169 "loop rows show in a buffer voice's section only", :208 "loops are continuous scene fields that crossfade", :312 "randomize, mutation and the fader pages leave loops alone", :382; seq — `test/unit/sequencer_test.lua:1491` "scenes switch the gate at a transition's end and crossfade its length and release; old scenes load with it off". `test/unit/params_setup_test.lua:11` "every voice param has a menu param, ordered by param_order" and :397 cover only built-in params (not found for registered ones). VOICE layout states join through `START_ORDER.voice_layout_states` (15).
- **A test double module before init**: `test/unit/registries_test.lua:531-568` patches strata.lua's last include (`'S.lib.sequencer = include("lib/sequencer")(S)\n'`) and passes `load_strata({ source = patched, module_sources = { ["lib/probe_late"] = late_module } })`; `h.patched_script(pattern, replacement)` (`test/helpers.lua:458-467`) returns those options. `load_strata` options (`test/helpers.lua:126-145`): `data_subdir`, `source`, `module_sources`, `before_load(context)` (before the chunk runs), `before_init(context)` (after includes, before `init()`).

---

## 5. BUFFER and the modal (2c)

- **`BUFFER_FIELDS`** (`lib/pages/buffer.lua:264-295`), quoted in substance: `source` (label `v<sel>`, `param_id = voice_param("source")`, value `voice_source_label`), `rec`, `dur` (label `len` when `synced()`), `lvl`, `fb`, `loop`, `thr`, `sync`, `bm` (`enc = bookmark_enc`, `active = function() return voice_uses_buffer(S.selected_voice) end`), `start` (`enc = start_enc, value = start_text`), `fric`. A field is `{name, label = string|fn, param_id = fn, value = fn, enc = fn(d)?, active = fn?}`.
- Field draw `draw_field_row(field, y, selected)` (:306-325); `draw_fields()` (:328-338, 4 visible from y 16, marker at the divider x 56). Cursor `S.buffer_page = {slot = 1, field = 1}` (:111); `cursor_field()` (:297-300, `S.lib.ui_field_list.clamp`).
- E3: `buffer_enc(n, d)` (:716-728): `field.enc(d)` or `enc_param_delta(n, field.param_id(), d)`. ALT+E2: `buffer_alt_enc` (:731-735) moves the field; ALT+E3 falls through to `buffer_enc` (fields read `S.alt_held` themselves, e.g. `start_enc` :254-262).
- **K3 records at the press** (:739-749):
  ```lua
  local function record_cursor_slot()
    record_buffer(cursor_slot())
  end

  local function buffer_key(n)
    if n == 2 then
      pressed_at[2] = util.time()
    elseif n == 3 then
      record_cursor_slot()
    end
  end
  ```
  The arc button is the same function (`arc_button = record_cursor_slot`, :1088). Hints `buffer_hints(alt_held)` (:706-714, `"K2:ld/rnd K3:" .. record_hint`); hold texts `HOLD_HINTS` (:687-690).
- **The waveform draw** `draw_waveform(slot)` (:482-517):
  ```lua
  local function draw_waveform(slot)
    local peaks = S.lib.waveforms.bins(slot, PAGE.wave_columns)
    local center = PAGE.wave_center_y
    if not peaks then
      screen.level(LEVELS.wave_empty)
      screen.move(PAGE.wave_x, center)
      screen.line(PAGE.wave_x + PAGE.wave_columns - 1, center)
      screen.stroke()
      return
    end
    local reads = voice_buffer_slot(S.selected_voice) == slot
    local loop_start, loop_end = 0, 1
    if reads then
      loop_start = params:get(voice_param("loop_start"))
      loop_end = loop_start + params:get(voice_param("loop_length"))
    end
    local drawing = nil
    for column = 1, PAGE.wave_columns do
      local level = LEVELS.wave_unread
      if reads then
        local middle = (column - 0.5) / PAGE.wave_columns
        level = (middle >= loop_start and middle < loop_end) and LEVELS.wave_inside or LEVELS.wave_outside
      end
      if level ~= drawing then
        if drawing then screen.stroke() end
        screen.level(level)
        drawing = level
      end
      local half = math.floor(util.clamp(peaks[column], 0, 1) * PAGE.wave_half_height + 0.5)
      local x = PAGE.wave_x + column - 1
      screen.move(x, center - half)
      screen.line(x, center + half)
    end
    screen.stroke()
  end
  ```
  `wave_x_of(fraction)` (:473-475); heads `draw_head`/`draw_heads` (:520-583); `redraw_buffer()` (:658-673). Geometry `S.BUFFER_PAGE` (:45-107; buffers.md §6). `wave_top = 11`: "one pixel above" the waveform for a slice mark is y 10 (the divider's top is also y 10, at x 56).
- **`layout_states`** (:967-1064): the named states, then one `"field <name>"` per field calling `FIELD_VALUES[field.name]()` (:1059-1064; §0 item 7). Page record (:1085-1089): `{name = "BUFFER", draw, hints, enc, alt_enc, key, key_release, alt_key, alt_key_release, enter = start_input_meter, animates = buffer_animates, arc_button = record_cursor_slot, layout_states}`. Constructor free locals 132.
- **`S.lib.ui_modal`** (`lib/ui/modal.lua`, 102 lines): owner `{draw = fn() (required), hints = fn(alt_held) -> string, enc = fn(n, d), key = fn(n, z), arc_delta = fn(n, d), arc_key = fn(n, z), arc_redraw = fn(arc_port), animates = fn() -> boolean}` (`OWNER_HANDLERS` :21); no alt handlers (§0 item 8). `M.push(owner)` (:41-53, error if no draw, a non-function handler or already pushed; `request_redraw`); `M.pop(owner)` (:57-65; forgets its pressed keys); `M.top()` (:68-70); `M.key(n, z)` (:75-86; a release reaches the owner only if it saw the press). Invariant "modal owner" (:90-99). Dispatch: `strata.lua` `enc` :229-243, `key` :256-283, `redraw` :295-320 (owner's draw and hints under the header; the file selector wins first); arc `lib/arc/core.lua:280-316`: `arc_delta` → `owner.arc_delta`, `arc_key` → `owner.arc_key(n, s)` (press and release), `arc_redraw` → `owner.arc_redraw(S.arc_device)` (rings off when absent). Frame redraws while `animates(S.lib.ui_modal.top())` (`lib/ui/frame.lua:103`).
- **SEQ's step editor as the example** (`lib/pages/seq.lua:772-905`): owner table (:854-863):
  ```lua
  editor_owner = {
    draw = function() if editor then draw_edit_view(views.editor) end end,
    hints = function(alt_held)
      if editor == nil then return "" end
      return edit_hints(views.editor, alt_held, editor_k2_text(), editor.alt_k2_at ~= nil)
    end,
    enc = editor_enc,
    key = editor_key,
    animates = editor_animates,
  }
  M.step_editor_owner = editor_owner
  ```
  push (:868-875):
  ```lua
  function M.open_step_editor(voice_idx, step, port)
    if not valid_place(voice_idx, step) then return false end
    if editor then S.lib.ui_modal.pop(editor_owner) end
    editor = {voice = voice_idx, step = step, port = port}
    forget_arc_ticks()
    S.lib.ui_modal.push(editor_owner)
    return true
  end
  ```
  ALT handling inside the owner: `editor_enc` (:784-791: `n == 2 and S.alt_held`), `editor_key(n, z)` (:796-818: ALT+K2 through `S.lib.ui_alt.k2_down()`/`k2_up(editor_alt)` at release, ALT+K3 at the press). `S.register_menu_close` forgets a pending ALT+K2 (:844-848). Invariant "step editor" (:897-904). The arc rings are set from the arc file: `lib/arc/seq.lua:184-187` (`editor_owner.arc_delta = editor_delta; editor_owner.arc_redraw = editor_redraw`), so an owner's ring fields can be assigned by `lib/arc/buffer.lua` the same way. Its layout states are SEQ's page record's (`{name = "step editor v7 step 16", setup = function() ... M.open_step_editor(NUM_VOICES, PATTERN_LENGTH, 1) end}`, :1026-1029), drawn by the layout test and the renders.
- **lib/arc/buffer.lua** (90 lines, whole structure): `ARC_BUFFER_LEVELS = {buffer = 15, other = 4, fixed = 12}`; `ARC_BUFFER_RINGS = {{voice_key = "buf_pos", scrub = true}, {voice_key = "loop_start"}, {voice_key = "loop_length"}, {voice_key = "buf_scan"}}`; `ARC_BUFFER_ALT_RINGS = {{voice_key = "buf_pos", scrub = true}, {voice_key = "buf_rate"}, {param_id = "scrub_friction"}, {param_id = "record_feedback", always_level = 12}}` (:16-27); `ring_param` (:29-31); `turn_ring` → `arc_sweep_param` + `S.lib.positions.scrub_turned` (:37-41); `arc_buffer_alt_delta` holds the scan as `"arc"` (:52-61); `draw_rings` via `arc_ring_fill_param` (:63-69); `S.register_alt_release` drops the hold (:74-78); sets `arc_delta, arc_redraw, arc_alt_delta, arc_alt_redraw` on BUFFER's record (:82-87).
- Arc helpers (`lib/arc/core.lua`): `arc_sweep_param(param_id, delta)` (:41-43), `arc_ring_fill(arc_port, ring, fraction, level)` (:48-52), `arc_ring_fill_param` (:86-92), `arc_whole_steps(key, delta, ticks_per_step)` (:97-102; ticks in `S.arc_ticks[key]`).
- **Layout tests and renders a new view needs**: every page record's `layout_states` are drawn by `check_layout_states` (`test/unit/ui_layout_test.lua:33-57`, with ALT up and down, through `assert_screen_layout`) and by `test/render_pages.lua:144-168`. So the editor's states go in BUFFER's `layout_states`, each `setup` opening the editor (as SEQ's do). Page tests: `test/unit/pages_buffer_test.lua` (`to_field(n)` :86-88, `field_named`, `field_rows`; the 11-field pin at :158-159).

---

## 6. Matrix and sources (2f)

- **Routing record**: `S.matrix[k] = {source = key, dest = id}` (`""` for none; `empty_routing` :67); depth and on/off are params `matrix_<k>_depth` (-100..100 %) and `matrix_<k>` (binary, default 1) (`M.add_params`, :662-670). `M.routing(k)` (:186-192) → `{source, dest, depth, on}`. `playing(k)` (:158-166) → resolved id and depth, or nil. `resolve(dest)` (:134-145). `M.set_routing(k, source, dest)` (:529-534), `M.edit_routing` (:540-556), `M.clear(k)` (:558-...).
- **Source lookup by key**: `source_known(key)` = `S.lib.mod_sources.get(key) ~= nil` (:129); the value `S.lib.mod_sources.normalized(S.matrix[k].source)` (bipolar `2f - 1`, unipolar `f`, non-finite 0; lua.md §6).
- **The step** (:380-399, quoted):
  ```lua
  local function step()
    if idle() then return end
    local lua_sums, fast_sums = scratch.lua_sums, scratch.fast_sums
    empty(lua_sums); empty(fast_sums)
    local contained_call = S.lib.ui_frame.contained_call
    for k = 1, MATRIX_SLOTS do
      contained_call(step_errors.routings, k, step_errors.routing_labels[k], read_routing, k)
    end
    for id, extras in pairs(held.fast_extras) do
      for _, m in pairs(extras) do fast_sums[id] = (fast_sums[id] or 0) + m end
    end
    for _, id in ipairs(sorted_ids(lua_sums, held.lua)) do
      contained_call(step_errors.destinations, id, destination_label(id), update_lua, id)
    end
    for _, id in ipairs(sorted_ids(fast_sums, held.fast)) do
      contained_call(step_errors.destinations, id, destination_label(id), update_fast, id)
    end
  end

  S.lib.lfos.on_step(step)
  ```
  **Where a routing is split Lua/fast** (the hand-off point), `read_routing(k)` (:320-329):
  ```lua
  local function read_routing(k)
    local id, depth = playing(k)
    if not id then return end
    local m = depth / 100 * S.lib.mod_sources.normalized(S.matrix[k].source)
    if m ~= 0 and finite(m) then
      local into = S.lib.lfos.fast_destination(id) and scratch.fast_sums or scratch.lua_sums
      into[id] = (into[id] or 0) + m
    end
  end
  ```
  `update_lua(id)` (:332-346: `set_extra_offset("matrix", id, offset)`, `mark_lua(id)` when `lua_moved`); **`update_fast(id)`** (:352-363): `want = util.clamp(sum, -2, 2)`, `expected = S.lib.engine_sync.expected_value(entry.key) or 0`, `S.lib.lfos.mark_due(entry.key, entry.send)` when moved past `send_threshold` or back to 0. `held = {lua, fast, fast_want, fast_extras}` (:205). `idle()` (:366-374) is true with no routing having both parts.
- **The `matrix fast` sender** (:216-221):
  ```lua
  for voice = 1, NUM_VOICES do
    for destination = 0, S.constants.NUM_FAST_DESTINATIONS - 1 do
      S.engine_senders["matrix fast " .. voice .. " " .. destination] = function(value)
        engine.setFastOffset(voice - 1, MATRIX.note_slot, destination, value)
      end
    end
  end
  ```
  `channel(id)` (:224-236) builds `{key, send = function() S.lib.engine_sync.send_engine_value(key, held.fast_want[id] or 0) end}`.
- `M.offset(param_id)` (:404-406), `M.set_fast_extra(source_key, param_id, m)` (:412-429).
- **Scene block and PSET hook**: scene fields per routing `S.register_scene_field({id = depth_id(k), default = 0})` and `{id = on_id(k), default = 1, discrete = true}` (:674-677); block `S.register_scene_block({key = "matrix", default, capture = sparse, validate, apply, discrete = true, through_zero})` (:686-710); `S.register_pset_hook(files.pset_hook(nil, routings_changed))` (:715), `files = S.lib.side_files.new({...})` (:508-518); live file `matrix.data` at `START_ORDER.matrix_load` (:718-721), saved at `CLEANUP_ORDER.matrix_save`; cleanup `CLEANUP_ORDER.matrix` (:727-...).
- **Tests that pin the sum** (`test/unit/matrix_test.lua`): :215 "matrix: a routing on top of a Lua LFO sums before the clamp"; :235 "matrix: a routing to v3 pitch goes to the offset bus"; :393, :431, :460 fast sends under the budget; :552; :674 "matrix: an idle step sends nothing and leaves no offset"; :822 "matrix: a macro LFO on a fast target joins the setFastOffset sum, clipped once"; **:1250 "matrix: a fast destination's sum is clamped to -2..2 before it is sent"**; :1263. Helpers: `loaded`, `lfo_step(context, count)` (:23-25), `seeded(S, key, range, value)` (:28-33), `route(S, k, source, dest, depth)` (:36-39), `fast_calls`/`last_fast` (:42-53).
- **How lib/lfos.lua tells an engine-run LFO from a Lua one** (the pattern for handing a route to the engine): `M.is_engine_run(n)` (:183-185) = `destination_of(n).fast ~= nil`; `engine_playing(n)` (:509-512) = on, fast, depth > 0; `engine_want(n)` (:514-519); `send_fast_lfo(n, want)` (:521-525) sends `engine.setFastLfo(...)` and stores `state[n].engine = want`; deferrable keys `"lfo<n> engine"` and `"lfo<n> sync"` with `S.engine_senders` entries (:538-552); **`reconcile_engine(n)`** (:571-604): not playing → `engine.stopFastLfo(n - 1)` if `st.engine`, clear; changed voice/destination/shape, an edit or a tempo move → `send_fast_lfo` at once; rate/depth/offset drift → `M.mark_due(engine_key(n), engine_sends[n])`; then the sync. Called from `step_lfo` (:623-668): engine-run → `restore_lfo_destination` if Lua held one, then `reconcile_engine(n)` (:659-664); Lua-run → `if st.engine then reconcile_engine(n) end; step_lua(n)` (:665-667). `tempo_moved` (:556-559) uses `LFO.engine_rate_threshold = 0.005`.
- **`S.lib.lfos.mark_due(key, send)`** (:343-349): a key joins `queue.keys` once; `queue.due[key] = send` (a later mark replaces). `drain()` (:352-370): at most `LFO.sends_per_step` (12) keys that `reaches_engine`, each inside `S.lib.engine_sync.deferrable`. **`M.on_step(fn)`** (:373-376): hooks run after the LFOs and direct destinations, before `drain` (`step_all`, :671-693), each contained. **`send_engine_value(param_id, value)`** (`lib/engine_sync.lua:262-276`; `M.send_engine_value` :723): deferred under `S.deferrable_write` when the window is full, else `send_now`. **`reaches_engine(param_id)`** (:145-147; `M.reaches_engine` :725) = `engine_messages(param_id) > 0` (0 for an id with no sender, a stopped voice's gated param). `M.fast_destination(id)` (:69-75) with `M.FAST_DESTINATIONS = {grain_pitch = 0, buf_pos = 1, grain_size = 2, filter_freq = 3, amp = 4}` (:56).
- A source record (`lib/lfos.lua:1050-1060`, the LFOs' `register_mod_source`): `{key = "lfo" .. n, name = "L" .. n, section = "lfos", range = {-1, 1}, value, describe, row = {enc, fine_enc, press, hints}}`; allowed fields `MOD_SOURCE_FIELDS` (`lib/state.lua:369-370`: `key, name, section, value, range, describe, visible, row`; 0b adds `fields`), name ≤ 4 characters (:372).

---

## 7. The delay's Lua half (1d)

- **The sender** (`lib/engine_sync.lua:458-497`, the requested 460-500):
  ```lua
  local function send_filter_to_engine()
    engine.setFilter(engine_param_value("filter_freq"), engine_param_value("filter_res"),
      engine_param_value("filter_type") - 1, engine_param_value("filter_mix"))
  end

  local function send_delay_to_engine()
    engine.setDelay(engine_param_value("delay_time"), engine_param_value("delay_feedback"),
      engine_param_value("delay_mix"))
  end

  local function send_reverb_to_engine()
    engine.setReverb(engine_param_value("reverb_mix"), engine_param_value("reverb_size"),
      engine_param_value("reverb_damp"))
  end
  ...
  S.engine_senders.delay_time = send_delay_to_engine
  S.engine_senders.delay_feedback = send_delay_to_engine
  S.engine_senders.delay_mix = send_delay_to_engine
  ```
  (:467-470 and :493-495). `engine_param_value(id)` (:54-58) is the last value sent (LFO and extra offsets included) or `params:get`; `deliver` (:171-182) records `S.engine_param_values[param_id] = value` before calling the sender, so the sender reads the value just delivered. A base override would be cleared by any hand edit (`S.register_param_touch` → `clear_base_override`, :385).
- **The three params** (`lib/params_setup.lua:546-580`), one quoted:
  ```lua
    params:add{
      type = "control",
      id = "delay_time",
      name = "delay time",
      controlspec = controlspec.new(0.01, 2, "exp", 0.001, 0.375, "s"),
      action = function(x)
        note_param_edit("delay_time")
        send_param_to_engine("delay_time", x)
        fx_fader_changed()
      end
    }
  ```
  `delay_feedback` (:558-568, 0-0.95 lin 0.01, default 0.4), `delay_mix` (:570-580, 0-1, default 0). Group `strata_fx`, size `FX_GROUP_PARAMS` (11, `lib/params_setup.lua:23`) plus each fx record's `count` (:492-494); registered records are added after `drift_amount` by `add_counted("fx params", record)` (:631-633).
- **`S.register_fx_params({name, count, add})`** (`lib/state.lua:320-330`; fields `FX_PARAM_FIELDS = {name, count, add}`, :153; closes at init). The one example, `lib/voice_mix.lua:221-238`:
  ```lua
  S.register_fx_params({
    name = "bypass",
    count = #M.BYPASS_ORDER,
    add = function()
      for _, effect in ipairs(M.BYPASS_ORDER) do
        local bypass = M.BYPASS[effect]
        params:add{
          type = "binary",
          id = bypass.param_id,
          name = bypass.name,
          behavior = "toggle",
          default = 0,
          action = function(x) send_param_to_engine(bypass.param_id, x) end,
        }
        S.engine_senders[bypass.param_id] = function(value) engine.setBypass(bypass.engine_effect, value) end
      end
    end,
  })
  ```
  Registration order follows include order (voice_mix is included at `strata.lua:66`).
- **Scene globals**: `delay_time` is in `S.SCENE_GLOBAL_PARAMS` (`lib/scenes.lua:87-105`; :98 `{id = "delay_time", continuous = true, default = 0.375}`). A registered one is added with `S.register_scene_field({id, default, discrete, set})` (`lib/state.lua:235-...`, closes at init; examples `lib/scatter.lua:126-130`, `lib/matrix.lua:675-676`, `lib/variation.lua:384-385`); scenes read them after `SCENE_GLOBAL_PARAMS`.
- **FX page rows** (`lib/pages/fx.lua:24-50`), the delay part:
  ```lua
      {label = "delay", selectable = false, bypass = "delay"},
      {label = "time", param_id = "delay_time", format = "%.3f s", effect = "delay"},
      {label = "fdbk", param_id = "delay_feedback", format = percent, effect = "delay"},
      {label = "mix", param_id = "delay_mix", format = percent, effect = "delay"},
  ```
  A row's `format` is a pattern or `fn(raw)` (`draw_fx_row` :62-88, `raw = params:get(row.param_id)`); `nil` shows `params:string`. `row_of(param_id)` (:55-60) errors for a missing row. K3 (`fx_key`, :138-147):
  ```lua
  local function fx_key(n)
    local effect = cursor_row().effect
    if n ~= 3 or not effect then return end
    local bypass = S.lib.voice_mix.BYPASS[effect]
    if bypass then
      set_binary_param(bypass.param_id, 1 - params:get(bypass.param_id))  -- echoes to a MIDI map (#538)
    else
      S.lib.params_setup.toggle_filter_mix()
    end
  end
  ```
  Hints `fx_hints` (:113-124): `"K3:" .. effect .. " " .. (effect_on(effect) and "bypass" or "on")`; ALT shows `E3:fine` only for a control param. E3 `enc_param_delta(n, cursor_row().param_id, d)` (:126-132). Layout states (:198-218) find rows by `row_of`.
- **FX's randomize spec** (`lib/pages/fx.lua:160-176`): `FX_SECTION_DRAWS.delay = {{"delay_time", octaves(0.05, 1.0)}, {"delay_feedback", between(0, 0.7)}, {"delay_mix", between(0, 0.5)}}`, specs `{page = UI_PAGES.index.FX, section, draws = {{id, draw}}}`, chosen by the cursor row's `effect` (`fx_randomize_section`).
- **lib/arc/fx.lua** (42 lines, whole):
  ```lua
  local ARC_FX_RINGS = {
    {param_id = "filter_freq"},
    {param_id = "filter_res"},
    {param_id = "delay_time"},
    {param_id = "delay_mix"}
  }
  local ARC_FX_LEVEL = 12
  local function arc_fx_delta(n, delta)
    local ring = ARC_FX_RINGS[n]
    if ring then
      arc_sweep_param(ring.param_id, delta)
    end
  end
  local function arc_fx_redraw(arc_port)
    for n, ring in ipairs(ARC_FX_RINGS) do
      arc_ring_fill(arc_port, n, param_fraction(ring.param_id), ARC_FX_LEVEL)
    end
  end
  local record = S.registry.pages[S.constants.UI_PAGES.index.FX]
  assert(record, "lib/arc/fx.lua: no FX page record in S.registry.pages")
  record.arc_delta = arc_fx_delta
  record.arc_redraw = arc_fx_redraw
  ```
  Test: `test/unit/arc_pages_test.lua:174` "arc FX page: rings adjust filter freq/res, delay time/mix and show them"; :1086 ring levels.
- **The 256's FX fader**: `GRID_LAYOUT.fx_fader_ids = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}`, `fx_first_row = 3` (`lib/grid/core.lua:48-49`); used at `lib/grid/layout_256.lua:350` (key: `GRID_LAYOUT.fx_fader_ids[y - GRID_LAYOUT.fx_first_row + 1]`) and :506-507 (redraw `grid_redraw_fader_row`), on page 4 only (`M.any_fx_faders`, core.lua:553-...).
- Other `delay_time` users: the LFO/matrix destination `fixed_destination("dly time", "delay_time", "global")` (`lib/lfos.lua:96`).
- The tempo: `S.lib.params_setup.beat_seconds_now()` (`lib/params_setup.lua:120-123`, quoted in lua.md §7).
- **Tests that pin setDelay's three arguments**: `test/unit/params_setup_test.lua:255-266` "fx params drive setFilter/setDelay and live in scenes" (args 1-3); `test/unit/docs_test.lua:453-...` "the FX SynthDefs' defaults equal the Lua param defaults (#25)" (fx commands and their defaults), :571 "each FX param's controlspec lies within the engine's limit for its argument (#51)" (so `delay_time`'s 2.7 s range needs the engine's limit raised first), :676-697 "the engine stub rejects a NaN or infinite argument (#477)" (`assert_engine_rejects("finite", "setDelay", nan, nan, nan)`, :680), :699-750 "the engine stub range-checks continuous arguments at the engine's own limits (#51)" (`check_limits("setDelay", {0.375, 0.4, 0}, 1|2|3, ...)`, :723-725; the feedback limit read from `\strataDelay`, :729-734); `test/unit/lfos_test.lua:988-1022` (args[2], args[3]); `test/unit/gestures_test.lua:449`; `test/unit/voice_mix_test.lua:212`; `test/unit/pages_fx_test.lua` (24 tests, row lookups by param id at :266, :305). The stub's check `setDelay = none` (`test/norns_stubs.lua:691`).

---

## 8. Test harness

- **The engine call log**: `context.engine_calls`, entries `{ name = command_name, args = args }` (`test/norns_stubs.lua:3079`, :3122); `context.clear_engine_calls()` (:3315); `context.calls_named(name)` (:3316-...). The stub's per-command argument checks are the table `checks` at `test/norns_stubs.lua:660-...` (e.g. `noteOn = note_slot, noteExpression = note_slot`, `noteOff = function(args) return note_slot(args) or range("cut", args[3], 0, 1) end`); `setGrainParam` names must be grain SynthDef controls (`named_param`, :650-658). Sync check's `PENDING_COMMANDS`: `test/sync_check.lua:217`.
- **The 48 Hz clock**: `context.clock.advance_until(local_value("S").lfo_clock)` (the `lfo_step` helper in matrix_test.lua:23-25 and midi_in_test.lua). Wall time: `context.clock.run_for(seconds)` (`test/norns_stubs.lua:1985`); `context.set_time(seconds)` (:3133). Beats: `clock.get_beats()` follows util.time at `clock.tempo`; `context.clock.set_beat(beat)` (:2046-2056; e.g. io_targets_test.lua:385); tempo via `params:set("clock_tempo", bpm)` → `clock.internal.set_tempo` (:1727-1733, published a tick late, as matron). `h.wake(context, name)` (helpers :321-323), `h.next_frame(context)` (:308-310), `h.finish_startup(context)` (:315-317).
- **MIDI**: `context.midi.send(port, { type = "note_on", note = note, vel = velocity, ch = channel })` (`test/stub_midi.lua:137-142`), as midi_in_test.lua's helpers (:12-18):
  ```lua
  local function note_on(context, channel, note, velocity, port)
    context.midi.send(port or 1, { type = "note_on", note = note, vel = velocity or 100, ch = channel })
  end
  local function note_off(context, channel, note, port)
    context.midi.send(port or 1, { type = "note_off", note = note, vel = 0, ch = channel })
  end
  ```
- **Grid**: §3 (plug, press, `get_led`).
- **A page and the screen**: `h.show_page(page)` (title or index; `test/helpers.lua:651-662`), then `redraw()`; `context.screen.texts` entries `{x, y, text, ...}`; `h.screen_shows(context, text)` (:774-779), `h.texts_on_row(context, y)` (:665-672), `h.hint_text(context)` (:675-680), `h.assert_screen_layout(context, where)` (:695-...), `h.tap(n)` (:805), keys `key(n, z)`, encoders `enc(n, d)`.
- **A double module before init**: §4 (registries_test.lua:531-568, `h.patched_script`, `before_init`).
- **One short test of each kind**:
  - engine calls + a play — `test/unit/notes_test.lua:176-199` "the first note on a voice is its own note, with today's messages" (`play(context, 1, 1, 60)`; `call_text(context.engine_calls[#sent]) == "retrigger(0, 0.5)"`; `#context.calls_named("noteOn") + #context.calls_named("noteExpression") == 0`). The `note(context, key, pitch, fields)` helper (:129-134) logs `set_own` into `context.engine_calls`.
  - the 48 Hz clock — `test/unit/matrix_test.lua:235-245` "matrix: a routing to v3 pitch goes to the offset bus" (`context.clear_engine_calls(); lfo_step(context, 2); local fast = fast_calls(context, 2, 0); assert_equal(#fast, 1, ...)`).
  - a grid key and an LED — `test/unit/grid_layout_256_test.lua:918-928` and :930-946 (`grid_tap(context, 12, 8)`; `device:get_led(cell, voice_idx) == S.lib.positions.grid_level(voice_idx, cell, cells)`).
  - a page and the screen — `test/unit/buffers_test.lua:637-...` (`show_page("SETUP"); enc(2, 20); redraw(); assert_true(screen_has("buffers: 0 restored"))`).
  - a module double — `test/unit/registries_test.lua:531-568`.

## Not found

- A function named `midi_note_off` (the off path is `note_off` → `end_key` → `midi_note_off_for`).
- Any save function in `lib/files.lua`.
- A SETUP problem line for io.data (or for notes.data, macros.data, matrix.data, gestures.data).
- A stored record of a slot's exact frames or the file's peak in Lua.
- A Lua record of a synced take's tempo.
- `get_param_spec` entries for `buf_pos`, `buf_rate`, `buf_scan` (they are added directly in `lib/params_setup.lua:985-1035`).
- A test in `params_setup_test.lua` over registered voice params (they are in `registries_test.lua`).
