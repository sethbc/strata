## Must not break

- **Every MIDI note plays through the allocator** (`S.lib.notes.play`, owner `"midi"`, key `channel * 128 + note`), one play per voice the note on targets: `midi_note_on` never sends a note command, `toggle_voice` or `retrigger` itself. The allocator pitches the own note through the note's `set_own`, starts a stopped voice and accents slot 1 (`retrigger(i - 1, vel / 127)`); an extra note is its `noteExpression` then `noteOn`. A voice's `note cap` at 1, or a pool of 0, plays every key as 3.4 did, message for message. Velocity lands on the accent; voices keep their attacks.
- **Before each play**: `S.lib.expression.forget(voice, "midi", key)` (a re-pressed latched key takes pressure again, ruling 30), then `S.lib.sequencer.note_gate(voice)` (a gated voice's own gate length, never a step's, #639), then the play with `expression = S.lib.expression.note_values(voice, {bend, pressure, slide = 0})`, then, once the note is held, `S.lib.expression.update(voice, "midi", key, raw)` with the controller's absolute values (its slide becomes the note's reference).
- **A key is down on a voice exactly while some channel's note on lists it**: `held[voice][key]` is set exactly when `note_voice[channel][note]` holds the voice (the invariant `midi notes`). A note off goes to the voices its note on played, even if the omni selection or the MPE zones moved since; a note off no note on played changes nothing.
- **Latch** (`midi_note_off` `latch`, or `auto` in the plain modes): a note off sends nothing (`S.lib.expression.latch` keeps the note's highest pressure). A note on that finds no key down on a voice first releases that voice's MIDI notes (`release_owner`), so the next chord replaces the last. **Release** (`release`, or `auto` in the MPE modes): a note off calls `S.lib.notes.release` (the own note parks under other notes), and the voice's last key instead stops the voice (`toggle_voice`), whoever started it (plan ruling 8), with no release before it: the stop ends its notes, so the messages are `noteOff(v - 1, 0, 0)` when the own note's key lifts under others and `voiceOff(v - 1)` at the last key, never an unpark between.
- **A note off that never comes** (Review Focus 1): a port change, an unplug, a channel mode change, a note off change, a member count or zone change in the MPE modes and a panic release every MIDI note (the voice's stop, or `S.lib.notes.forget_owner` on every other voice) and call `S.lib.mpe.reset()` (which also puts each master channel's bend range back to 2), so the pool never fills with notes no key can end. The release reads the note off behavior in force after the change: in release mode the voices whose keys were down stop; a panic also stops every voice a MIDI note started.
- **A reset under latch leaves every voice sounding and parks nothing** (rulings 39 and 40): it never calls `release_owner`, which parks an own note under another owner's notes, but `S.lib.notes.forget_owner(voice, "midi")`: MIDI's extra notes end, MIDI's own note keeps sounding as nobody's, and another owner's notes (the sequencer's chords) play on, never cut and never stopped. An own note MIDI parked earlier (its key lifted in release mode under others) stays parked under them and returns, unaccented, when the voice's last note ends: the allocator never keeps a running, noteless voice parked (ruling 39).
- **Only a key down keeps a voice's own note from the sequencer** (ruling 55, refining ruling 35): `M.keeps_own(voice)` is true while MIDI's own note on the voice has its key in `S.midi_state.held[voice]`; a latched own note (its key up) gives way to a step: MIDI forgets it there (`S.lib.notes.forget`, nothing sent, and `S.lib.expression.forget` for its touch), so the step re-pitches and accents the voice's own note as in 3.4. MIDI's latched extra notes stay MIDI's. A MIDI note that lands on slot 1 calls `S.lib.sequencer.own_note_taken(voice)`, which ends a step's note override the note took slot 1 from.
- **A voice stopped under its keys forgets its notes** (the allocator's voice-stop hook); their later note offs send nothing, and the next key starts the voice again on slot 1 (Review Focus 2).
- The handler lives on the vport only (`S.midi_device = midi.connect(port)`), never on the raw device. Cleanup detaches it (step 150), before the voices go off.
- After init, `S.selected_voice` changes only in `select_voice_by`, which calls `midi_bend_follow_selection`, so an omni bend follows the selection (the pages' `layout_states`, test setups, set it directly). Callers reach it as `S.lib.ui_keys.select_voice_by` (`lib/ui/keys.lua`).
- The `freq` controlspec has step 0, so notes keep exact equal-tempered pitch.
- A quantized voice's every note, own or extra, snaps to the scale (`S.lib.variation.midi_note`) before it is played; an unquantized voice's never does.
- **The note tap is read once per note on**: `set_note_tap(fn)` may be called from inside `fn` (the zones editor's learn ends itself there), and a new tap or none takes effect from the next note. A consumed note never enters `note_voice`, so its note off does nothing. `reset_midi_input` and cleanup clear the tap; the layout hook never does (the learn changes the layout while its tap is set).
- The selected vport's device is reconciled when the norns menu closes (`M.reconcile`, a `register_menu_close` hook). Only a change of device resets the held notes, never an ordinary menu visit: SYSTEM > DEVICES moves a device with `update_devices()` and calls neither `midi.add` nor `midi.remove`.
- A panic (CC 123 or CC 120) stops every active voice that has a key down or is in `S.midi_state.started` (set when a note on finds the voice stopped and the play starts it, cleared when a MIDI note off or a panic stops it), in either note off mode, never one the norns, grid or a pattern started. A `grain_restart` hook registered in the start step clears the flag when a voice starts (it is not yet active when the hook runs; a running voice's source change leaves it); `midi_note_on` sets it after the play's start, so a voice stopped and restarted from the norns, grid or a pattern is never the panic's. The `midi notes` invariant checks `started`'s keys.
- Strata's code handles no CC but 123 and 120 (`release_held_notes(true)`) and, in the MPE modes, MPE's (74, 87, 6, 38, 100, 101, through `S.lib.mpe.control`); norns' PARAMS > MAP maps any other CC to any param. CC74 is not read in the plain modes.
- `midi.add` and `midi.remove` are assigned in the start step, never at include time: they read the `midi_device` param, which init adds (#469). The layout hook is registered there too (`S.lib.mpe` is included after this module).
- **No MIDI map is left on one of 3.3's own LFO ids, and no other map is touched** (#602): norns reads `strata.pmap` into `norns.pmap` (`data[param id]`, the reverse `rev[dev][ch][cc]`) in `Script.run`, before `init`, and its CC handler (`lua/core/menu/params.lua`'s `menu_midi_event`, which `_norns.midi.event` calls for every message) raises `invalid paramset index` for a map whose id is no param; the MAP menu lists params, so it cannot show such a map to remove it. The start step, after Strata's params exist, runs `M.repair_midi_map()`, which touches only the ids 3.3's Strata had and 3.4 has not (`M.MIDI.lfo_maps_3_3`): every param norns' LFO library added for 3.3's LFOs 1-3, `lfo_<n>` and `lfo_<field>_<n>` for `group`, `shape`, `depth`, `phase`, `offset`, `scaled`, `raw`, `min`, `max`, `baseline`, `mode`, `clocked`, `free`, `reset` and `reset_target`, and `strata_lfos` (49 ids, the exact difference between v3.3.2's params and 3.4's). One with a 3.4 param of the same meaning (`moves`: `lfo_depth_<n>`, `lfo_offset_<n>`, `lfo_phase_<n>` and `lfo_clocked_<n>`, to `strata_lfo<n>_depth`, `_offset`, `_phase` and `_division`, the import `lib/lfos.lua` keeps as they are) moves to it, its output range turned into the control's raw units (3.3's were number params), unless that param has a map of its own or the reverse slot is not the stale map's; every other one is removed (its reverse slot cleared only while it is its own). One console line each (`midi map: ...`); a removal says why: `3.4 has no param of its meaning`, `its 3.4 param <id> is already mapped (CC <n>, channel <n>, device <n>)` naming the map that keeps it, or `its CC <n> (channel <n>, device <n>) maps <id>`, then, only when something moved or went, `norns.pmap.write()` writes the whole map as norns' MAP menu does, so the next start reads it repaired. A map on any other id is left exactly as it is, with no console line, even when no param has that id at start: norns runs `hook.script_post_init` after `init` (`lua/core/script.lua`), so a mod may add its param then, and a later version may have it. With nothing of 3.3's to repair the file is never written.

## Owns

`lib/midi_in.lua` (`S.lib.midi_in`):
- `S.midi_device`, `S.midi_state`;
- notes, chords, velocity, pitchbend, pressure, MPE's routing and expression, hot-plug (`attach_midi`, `midi_init`, `midi.add`/`midi.remove`, `midi_event`, `midi_note_on`, `midi_note_off_for`, `midi_pitchbend`, `midi_set_bend`, `midi_bend_follow_selection`, `reset_midi_input`, `midi_target_voice`, `midi_device_name`), `M.note_off_mode()` and `M.set_note_tap(fn)`;
- the MIDI constants, `S.lib.midi_in.MIDI`, which the MIDI params in `lib/params_setup.lua` read;
- the MIDI map's repair at start (`M.repair_midi_map`, #602), with 3.3's own LFO ids, the only ones it touches, and those it moves (`M.MIDI.lfo_maps_3_3`);
- cleanup step 150: the MIDI handler detached, the note tap cleared, and `midi.add`/`midi.remove` set to no-ops (norns' SLEEP runs only `cleanup()`, #468).

MIDI notes, velocity, pitchbend and pressure play the voices (3.0 design §5, 3.5 design §5). It calls `S.lib.notes` (`docs/notes/lua/notes.md`), `S.lib.mpe` (`docs/notes/lua/mpe.md`) and `S.lib.expression` (`docs/notes/lua/expression.md`).

## State

Grouped in tables:
- `S.lib.midi_in.MIDI` holds the constants: `velocity_max` 127, `rate_root_note` 60 (a buffer or input voice's note at rate 1), `bend_center` 8192, `bend_semitones` 2, the option lists, `owner` (`"midi"`), `channels` 16, `notes_per_channel` 128 (a key is `channel * 128 + note`) and `pressure_max` 127.
- `S.midi_device` is the vport Strata listens to.
- `S.midi_state` holds:
  - `bend[voice]`: the plain modes' ratio, default 1 (transient: never a param, never in scenes);
  - `held[voice]`: the set of keys down on the voice;
  - `note_voice[channel][note]`: the list of voices the note's note on played (an empty channel has no table);
  - `started[voice]`: true while a MIDI note started the voice and nothing has stopped it through MIDI.
- Locals: the plain modes' pressures (`plain_pressure.channel[ch]`, the last channel pressure, nil before the first; `plain_pressure.key[key]`, the last poly aftertouch, until the key's note off), the note tap and `own_setters[voice]` (each voice's `set_own`).
- `local musicutil = require "musicutil"`.

## Params

Group `strata_midi`, 6 params (the last three are MPE's, `docs/notes/lua/mpe.md`):
- `midi_device`: number 1..`#midi.vports` (norns' 16 ports), default 1, stepping whole numbers under PARAMS' K3-held fine turn (#534, `docs/notes/lua/params.md`). Action `attach_midi(x)` then `reset_midi_input()`.
- `midi_channel_mode`: option {`per voice`, `omni to selected`, `mpe selected`, `mpe split`}, default 1; 3.4's two indices kept, the MPE modes appended. Action `reset_midi_input()`.
- `midi_note_off`: option {`auto`, `release`, `latch`}, default 1. Index 1 was 3.4's `ignore`, which `auto` plays in the plain modes (latch); index 2 was `voice off`, which `release` keeps; so no PSET changes meaning and `PSET_FORMAT` stays 2. `M.note_off_mode()` gives `"latch"` or `"release"`: `auto` is release while `S.lib.mpe.active()`, else latch. Action `reset_midi_input()`, as a channel mode change has: no chord carries from one behavior into the other (ruling 37).

## Device lifecycle

- `midi_init()` (from its start step, `START_ORDER.midi`, after the grids) calls `attach_midi(params:get("midi_device"))`.
- `attach_midi` rounds its port to a vport index (1..`#midi.vports`), so a fraction (a PSET written before the param stepped whole numbers, #534) still names a port, clears the old vport's `event` and sets `S.midi_device = midi.connect(port); S.midi_device.event = midi_event`. The unplug handler compares the device's port with the same rounded index.
- The handler lives on the vport only: norns fires both `device.event` and `vports[port].event`, as for grids and arc.
- `midi.add(device)` (assigned by the start step) re-attaches, requests a redraw (SETUP) and prints.
- `midi.remove(device)` resets the input if the device was on the selected port, requests a redraw and prints.
  - norns clears the vport as `midi.remove` returns (`Midi.update_devices`), before the next frame draws.
  - So `midi_device_name()` (the selected vport's name, or `none` without a device) then shows the port as empty.
- The module keeps `attached_device`, the device last seen on the selected vport (set in `attach_midi`, nil after `midi.remove` took the selected port's device).
- SYSTEM > DEVICES moves a device between ports through `update_devices()` only (no `midi.add`, no `midi.remove`). `M.reconcile()` runs as the menu closes: when `S.midi_device.device` is not `attached_device`, it calls `reset_midi_input()` if a device had been attached (its note offs and bend returns will not arrive), remembers the new device and requests a redraw. A menu visit that moves nothing does nothing. A device moved off the selected port and back inside one menu visit is the same device when the menu closes, so its held notes stay.
- `cleanup` clears `S.midi_device.event` and the note tap.

## Routing

- `midi_target_voice(channel)` (the plain modes; nil in the MPE modes):
  - per voice: channel 1..`NUM_VOICES` addresses that voice, other channels nothing;
  - omni: every channel addresses `S.selected_voice`.
- A note on's targets: `S.lib.mpe.targets(channel, note)` in the MPE modes (`mpe selected`: the selected voice for a channel in a zone; `mpe split`: every voice whose zone and range hold the note), else `midi_target_voice`'s voice.
- `midi_event(data)` parses with `midi.to_msg`; a channel outside 1-16 or a note outside 0-127 is ignored. In order: a note on (velocity above 0), a note off (or a note on at velocity 0), CC 123 and CC 120 (`M.PANIC_CCS`); then, in the MPE modes, every other message goes to `S.lib.mpe.control`, and each channel it returns has its notes updated with `S.lib.mpe.values(channel)`; in the plain modes, pitchbend, poly aftertouch (`key_pressure`) and channel pressure. Everything else is ignored.

## Notes

Note on (velocity above 0):
- the note tap first (below): a taken note plays nothing;
- a repeated note on (the channel's `note_voice` still lists voices for the note) first lifts the key, as a note off does, on each listed voice this note on does not target (the omni selection moved, a zone changed);
- `note_voice[channel][note]` becomes the target list; for each target, in order: a voice with no key down has its MIDI notes released first (`release_owner`: latch's chord replaced; a no-op in release mode, where such a voice holds none), the key goes down (`held`), then `midi_note_on(voice, note, vel, channel, raw)`;
- `raw` is `S.lib.mpe.values(channel)` in the MPE modes (bend, pressure, absolute slide), and in the plain modes `{bend = 1, pressure = the key's poly aftertouch or the channel's last pressure (nil before one arrived)}`;
- `midi_note_on`: `forget`, `note_gate`, then `S.lib.notes.play(voice, {owner = "midi", key, pitch = S.lib.variation.midi_note(voice, note), velocity = vel / 127, park = true, set_own, expression = note_values(voice, {bend, pressure, slide = 0})})`, `started[voice]` set when the voice was stopped and now runs, then `update` with `raw` when the play took a slot. Called directly (a test), the channel defaults to 1 and `raw` to `{bend = 1}`;
- `set_own(pitch)` (one per voice, `own_setters`) is `params:set` on `v<i>_freq` (`musicutil.note_num_to_freq(pitch)`) for a synth voice, `v<i>_buf_rate` for a buffer voice and `v<i>_grain_pitch` for an input voice (each `2 ^ ((pitch - 60) / 12)`), clamped to the param's range (design Question 9). The `freq` filter keeps a quantized note past the freq range on the scale's last tone inside it;
- the allocator then does the rest (`docs/notes/lua/notes.md`): slot 1 when the own note is free (the stopped voice started with `toggle_voice`, then `retrigger`), else an extra note under the voice's cap and the pool, else a steal, else slot 1 re-pitched. The `freq` step 0 matters: a 1 Hz step was 37 cents at 46 Hz.

Note off (or note on with velocity 0):
- the key's poly aftertouch is forgotten; a note no note on played (no `note_voice` entry: a stray note off, a tapped note, one released by a reset) changes nothing;
- otherwise the entry goes and, on each voice it lists, the key is up (`held`) and: in release mode, the voice's last key (an active voice with no key down left) stops it through `midi_note_off_for(voice)` (`toggle_voice`, `started` cleared) with no release first, and any other key's note goes through `S.lib.notes.release(voice, "midi", key)`; in latch mode `S.lib.expression.latch(voice, "midi", key)`, which sends nothing itself.
- A note during the release starts the voice again through `toggle_voice`/`voiceOn` (the allocator's), and the engine re-gates the releasing synths.

## Expression

- Plain modes (design §5.3): the pitch bend is the voice's `bend` (below), bending every note of the voice; a note's own `bend` is 1. Poly aftertouch is its note's pressure: `S.lib.expression.update(voice, "midi", key, {pressure = val / 127})` on each voice the key's note on played. Channel pressure is every held key of the channel's, and is kept as the channel's pressure for its next notes. CC74 is not read.
- MPE modes (design §5.4): each channel `S.lib.mpe.control(msg)` returns (a member's bend, pressure or CC74; a master's bend lists its whole zone; an RPN 0 its channels) has every key it holds updated with `S.lib.mpe.values(channel)`. Poly aftertouch is ignored, and the voices' `bend` stays at 1.
- Only held keys are updated: a latched note's later updates change nothing (`S.lib.expression`), and a key lifted in latch mode is no longer in `note_voice`.

## Releasing everything

`release_held_notes(stop_all)` (local), from `reset_midi_input()`, the panic (`stop_all`) and the layout hook:
- per voice, the voice stops (`toggle_voice`, whose voice-stop hook forgets its notes) when it is active and its keys were down in release mode (the mode read after the change), or, with `stop_all`, it had a key down or was `started`; every other voice gets `S.lib.notes.forget_owner(voice, "midi")` (ruling 40), which parks nothing: MIDI's held extra notes end (`noteOff`), and its held own note is dropped from the records with nothing sent, so the voice sounds on as 3.4's latch did, and another owner's notes play on. An own note MIDI parked earlier stays parked under the other owners' notes; when the last of them ends, the allocator brings it back as the voice's drone (`noteOn` on slot 0 at velocity 0, ruling 39), and if the reset itself ends the voice's last held note (MIDI's extra notes over its parked own note), it comes back at once;
- `held`, `note_voice` and the plain pressures are emptied and `S.lib.mpe.reset()` runs (every channel's values, pending CC87 and RPN state forgotten, and each master channel's bend range back to 2, on any reset, a note off change's included); a panic empties `started` too.
- With nothing held it sends nothing, so the layout hook, which may run several times in one PSET load and see a layout mid-change, is cheap and idempotent.

`reset_midi_input()` (a port or channel mode change, the selected port's device gone or moved) re-centers every bent voice (`bend` 1 sent only to active voices whose bend was not 1), clears the note tap, then releases everything. The `midi_note_off` param's action is `reset_midi_input()` too. The layout hook (`S.lib.mpe.on_layout_change`, registered in the start step: a member count or zone change, ruling 14) releases everything only while `S.lib.mpe.active()` (the plain modes route nothing through the zones), and keeps the tap and the bends.

## The note tap

`M.set_note_tap(fn | nil)` (the zones editor's learn, SETUP's `mpe & zones`, design §9.3): while a tap is set every note on, in any mode, goes to `fn(note)` first, read once into a local and called through `S.lib.ui_frame.contained_call` (one that raises is reported once and takes nothing); `true` consumes the note (nothing plays, no key goes down, so its note off does nothing). `fn` may clear or replace the tap while it runs; the change applies from the next note on. Anything but a function or nil raises.

## Pitchbend

- `midi_pitchbend(voice, value)` (the plain modes): `ratio = 2 ^ (((value - 8192) / 8192) * 2 / 12)`, stored in `S.midi_state.bend[voice]`.
- Sent with `setVoiceParam(i - 1, "bend", ratio)` if the voice is active. A stopped voice gets it when it starts.
- `midi_set_bend(voice, ratio)` stores a bend and (for an active voice) sends it.
- Omni bend follows the selection:
  - `select_voice_by` (E2 on MAIN and BUFFER, the only place `S.selected_voice` changes) calls `midi_bend_follow_selection(previous_voice)` when the selection moved;
  - in `omni to selected` mode with the previous voice bent (`bend ~= 1`, the wheel off center), it re-centers that voice (`bend` 1) and gives the new selection the wheel's ratio (a stopped voice gets it on start).
  - The other modes leave bends alone.
- Pitchbend asks for no redraw: nothing on the screen or the arc shows the bend.

## States

A key's voices are the list in `note_voice[channel][note]`; `held[voice][key]` mirrors those entries.

| Fields | Legal combinations | Transition |
|--------|--------------------|------------|
| `note_voice[ch][note]`, `held[voice][ch * 128 + note]` | a key is down on a voice exactly while its channel's list for the note holds the voice; each list non-empty, its voices valid and distinct | `midi_event` (note on, note off and a repeated note on); `release_held_notes` empties both (from `reset_midi_input`, also from `M.reconcile` when the selected vport's device changed, the panic and the layout hook) |
| `started[voice]` | true or absent | set by `midi_note_on` when its play started the voice; cleared by the grain-restart hook at any start, by `midi_note_off_for`'s stop and by the panic |

Tests: `test/unit/midi_in_test.lua` (pitch per source, velocity, the start order, clamping and channels; chords and the cap of 1; latch and release, auto; a note off's voices, repeated note ons in omni; input voices' grain pitch; quantize; pressure in the plain modes; mpe selected and mpe split, MPE's per-channel updates; the releases of every note, Review Focus 1 (a reset under latch with another owner's notes, a parked own note's return, a note off change, the layout hook only in the MPE modes and twice in a row, RPN 6 mid-handler), and a stopped voice's forgotten notes, Review Focus 2; the note tap; 3.4's PSET indices; pitchbend; hot-plug, the menu's reconcile and SETUP; the MIDI map's repair). `test/unit/sequencer_test.lua` plays real MIDI against the patterns for ruling 55: a latched note giving way at a note cap of 1 and a pool of 0, a key held down through steps, and a MIDI note taking a step's own note.
