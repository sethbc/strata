## Must not break

- MIDI notes never create nodes. A note on starts a stopped voice with `toggle_voice`, then accents it with `engine.retrigger(i - 1, vel / 127)`. Velocity lands on the accent; voices keep their slow attacks.
- The handler lives on the vport only (`S.midi_device = midi.connect(port)`), never on the raw device. Cleanup detaches it (step 150), before the voices go off.
- A note off goes to the voice its note on played (`S.midi_state.note_voice`), even if the omni selection moved since.
- A note has one owning voice: `held[voice][note]` is set exactly when some channel's `note_voice[ch][note]` is that voice (the invariant `midi notes` checks it). A note on whose voice changed releases the previous voice first; a note off clears `held` only through `release_note_hold` (a local of the module's constructor, not a script global), which keeps it while another channel still maps the note to the voice.
- After init, `S.selected_voice` changes only in `select_voice_by`, which calls `midi_bend_follow_selection`, so an omni bend follows the selection (the pages' `layout_states`, test setups, set it directly). Callers reach it as `S.lib.ui_keys.select_voice_by` (`lib/ui/keys.lua`).
- The `freq` controlspec has step 0, so notes keep exact equal-tempered pitch.
- A quantized voice's note snaps to the scale before it sets `freq` or `buf_rate`; an unquantized voice's never does.
- The selected vport's device is reconciled when the norns menu closes (`M.reconcile`, a `register_menu_close` hook). Only a change of device resets the held notes, never an ordinary menu visit: SYSTEM > DEVICES moves a device with `update_devices()` and calls neither `midi.add` nor `midi.remove`.
- A panic (CC 123 or CC 120) stops every active voice that holds a note or is in `S.midi_state.started` (set when `midi_note_on` starts a stopped voice, cleared when a MIDI note off or a panic stops it), in either note off mode, never one the norns, grid or a pattern started. A `grain_restart` hook registered in the start step clears the flag when a voice starts (it is not yet active when the hook runs; a running voice's source change leaves it); `midi_note_on` sets it after its own `toggle_voice`, so a voice stopped and restarted from the norns, grid or a pattern is never the panic's. The `midi notes` invariant checks `started`'s keys.
- Strata's code handles no CC but 123 and 120 (all notes off and all sound off: `release_held_notes(true)`); norns' PARAMS > MAP maps any other CC to any param.
- `midi.add` and `midi.remove` are assigned in the start step, never at include time: they read the `midi_device` param, which init adds (#469).
- **No MIDI map is left on one of 3.3's own LFO ids, and no other map is touched** (#602): norns reads `strata.pmap` into `norns.pmap` (`data[param id]`, the reverse `rev[dev][ch][cc]`) in `Script.run`, before `init`, and its CC handler (`lua/core/menu/params.lua`'s `menu_midi_event`, which `_norns.midi.event` calls for every message) raises `invalid paramset index` for a map whose id is no param; the MAP menu lists params, so it cannot show such a map to remove it. The start step, after Strata's params exist, runs `M.repair_midi_map()`, which touches only the ids 3.3's Strata had and 3.4 has not (`M.MIDI.lfo_maps_3_3`): every param norns' LFO library added for 3.3's LFOs 1-3, `lfo_<n>` and `lfo_<field>_<n>` for `group`, `shape`, `depth`, `phase`, `offset`, `scaled`, `raw`, `min`, `max`, `baseline`, `mode`, `clocked`, `free`, `reset` and `reset_target`, and `strata_lfos` (49 ids, the exact difference between v3.3.2's params and 3.4's). One with a 3.4 param of the same meaning (`moves`: `lfo_depth_<n>`, `lfo_offset_<n>`, `lfo_phase_<n>` and `lfo_clocked_<n>`, to `strata_lfo<n>_depth`, `_offset`, `_phase` and `_division`, the import `lib/lfos.lua` keeps as they are) moves to it, its output range turned into the control's raw units (3.3's were number params), unless that param has a map of its own or the reverse slot is not the stale map's; every other one is removed (its reverse slot cleared only while it is its own). One console line each (`midi map: ...`); a removal says why: `3.4 has no param of its meaning`, `its 3.4 param <id> is already mapped (CC <n>, channel <n>, device <n>)` naming the map that keeps it, or `its CC <n> (channel <n>, device <n>) maps <id>`, then, only when something moved or went, `norns.pmap.write()` writes the whole map as norns' MAP menu does, so the next start reads it repaired. A map on any other id is left exactly as it is, with no console line, even when no param has that id at start: norns runs `hook.script_post_init` after `init` (`lua/core/script.lua`), so a mod may add its param then, and a later version may have it. With nothing of 3.3's to repair the file is never written.
- A channel mode change keeps `note_voice` and `held` (`reset_midi_input(true)`), so a note off reaches the voice its note on played; a port change or unplug releases them, and in voice off mode stops the voices they held.

## Owns

`lib/midi_in.lua` (`S.lib.midi_in`):
- `S.midi_device`, `S.midi_state`;
- notes, velocity, pitchbend, hot-plug (`attach_midi`, `midi_init`, `midi.add`/`midi.remove`, `midi_event`, `midi_note_on`, `midi_note_off_for`, `midi_pitchbend`, `midi_set_bend`, `midi_bend_follow_selection`, `reset_midi_input`, `midi_target_voice`, `midi_device_name`);
- the MIDI constants, `S.lib.midi_in.MIDI`, which the MIDI params in `lib/params_setup.lua` read;
- the MIDI map's repair at start (`M.repair_midi_map`, #602), with 3.3's own LFO ids, the only ones it touches, and those it moves (`M.MIDI.lfo_maps_3_3`);
- cleanup step 150: the MIDI handler detached, and `midi.add`/`midi.remove` set to no-ops (norns' SLEEP runs only `cleanup()`, #468).

MIDI notes, velocity and pitchbend play the voices (3.0 design §5).

## State

Grouped in tables:
- `S.lib.midi_in.MIDI` holds the constants: `velocity_max` 127, `rate_root_note` 60, `bend_center` 8192, `bend_semitones` 2, and the option lists.
- `S.midi_device` is the vport Strata listens to.
- `S.midi_state` holds:
  - `bend[voice]`: the ratio, default 1 (transient: never a param, never in scenes);
  - `held[voice]`: the set of held notes;
  - `note_voice[channel][note]`: the voice a note's note on played;
  - `started[voice]`: true while a MIDI note started the voice and nothing has stopped it through MIDI.
- `local musicutil = require "musicutil"`.

## Params

Group `strata_midi`, 3 params:
- `midi_device`: number 1..`#midi.vports` (norns' 16 ports), default 1, stepping whole numbers under PARAMS' K3-held fine turn (#534, `docs/notes/lua/params.md`). Action `attach_midi(x)` then `reset_midi_input()`.
- `midi_channel_mode`: option {`per voice`, `omni to selected`}, default 1. Action `reset_midi_input(true)` (bends only).
- `midi_note_off`: option {`ignore`, `voice off`}, default 1.

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
- `cleanup` clears `S.midi_device.event`.

## Routing

- `midi_target_voice(channel)`:
  - per voice: channel 1..`NUM_VOICES` addresses that voice, other channels nothing;
  - omni: every channel addresses `S.selected_voice`.
- `midi_event(data)` parses with `midi.to_msg` and ignores everything but notes, pitchbend and CC 123 / CC 120 (`M.PANIC_CCS`: every held note is released and every voice holding one or started by MIDI stops, in either note off mode).

## Notes

Note on (velocity > 0):
- if the channel's `note_voice` held the note for another voice, releases that voice first (`release_note_hold`, `midi_note_off_for`), then records the note in `held` and `note_voice`, then calls `midi_note_on(voice, note, vel)`;
- a voice with `v<i>_quantize` on plays the scale tone nearest the note instead (`S.lib.variation.midi_note`, a tie going down; scale off quantizes to semitones, so nothing changes), before any of the below (`docs/notes/lua/variation.md`). The `freq` filter then keeps a note past the freq range on the scale's last tone inside it;
- a synth source sets `v<i>_freq` to `musicutil.note_num_to_freq(note)`, clamped to `param_range`;
- a buffer source sets `v<i>_buf_rate` to `2 ^ ((note - 60) / 12)`, clamped (0.25-4);
- an input source takes no pitch;
- all through `params:set`;
- then `toggle_voice(i)` if the voice is off, and `engine.retrigger(i - 1, vel / 127)`.
- The `freq` step 0 matters: a 1 Hz step was 37 cents at 46 Hz.

Note off (or note on with velocity 0):
- goes to the voice its note on played (`note_voice`; in omni mode the selection may have moved), or to `midi_target_voice` for a note never seen;
- is removed from `held` by `release_note_hold(voice, note)`, unless another channel's `note_voice` still maps the note to the voice;
- `midi_note_off_for(voice)`: in `voice off` mode, an active voice with no other held note is stopped with `toggle_voice`.
- A note during the release starts the voice again through `toggle_voice`/`voiceOn`, and the engine re-gates the releasing synths.

## Pitchbend

- `midi_pitchbend(voice, value)`: `ratio = 2 ^ (((value - 8192) / 8192) * 2 / 12)`, stored in `S.midi_state.bend[voice]`.
- Sent with `setVoiceParam(i - 1, "bend", ratio)` if the voice is active. A stopped voice gets it when it starts.
- `reset_midi_input(keep_notes)` (port or channel mode change, device removed) re-centers every bent voice, sending `bend` 1 only for active voices whose bend was not 1, and unless `keep_notes` (the channel mode change) releases the held notes: clears `held`/`note_voice`, and in voice off mode stops each active voice that held a note.
- `midi_set_bend(voice, ratio)` stores a bend and (for an active voice) sends it.
- Omni bend follows the selection:
  - `select_voice_by` (E2 on MAIN and BUFFER, the only place `S.selected_voice` changes) calls `midi_bend_follow_selection(previous_voice)` when the selection moved;
  - in `omni to selected` mode with the previous voice bent (`bend ~= 1`, the wheel off center), it re-centers that voice (`bend` 1) and gives the new selection the wheel's ratio (a stopped voice gets it on start).
  - Per voice mode leaves bends alone.
- Pitchbend asks for no redraw: nothing on the screen or the arc shows the bend.

## States

A note's owner is the voice in `note_voice[channel][note]`; `held[voice][note]` mirrors those entries.

| Fields | Legal combinations | Transition |
|--------|--------------------|------------|
| `note_voice[ch][note]`, `held[voice][note]` | held on a voice exactly while some channel maps the note to it | `midi_event` (note on and note off, through `release_note_hold`); `reset_midi_input` clears both (also from `M.reconcile` when the selected vport's device changed) |
