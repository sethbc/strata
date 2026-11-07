## Must not break

- MIDI notes never create nodes. A note on starts a stopped voice with `toggle_voice`, then accents it with `engine.retrigger(i - 1, vel / 127)`. Velocity lands on the accent; voices keep their slow attacks.
- The handler lives on the vport only (`S.midi_device = midi.connect(port)`), never on the raw device. Cleanup detaches it (step 150), before the voices go off.
- A note off goes to the voice its note on played (`S.midi_state.note_voice`), even if the omni selection moved since.
- After init, `S.selected_voice` changes only in `select_voice_by`, which calls `midi_bend_follow_selection`, so an omni bend follows the selection (the pages' `layout_states`, test setups, set it directly).
- The `freq` controlspec has step 0, so notes keep exact equal-tempered pitch.
- A quantized voice's note snaps to the scale before it sets `freq` or `buf_rate`; an unquantized voice's never does.
- Strata's code handles no CC: norns' PARAMS > MAP maps any CC to any param.

## Owns

`lib/midi_in.lua` (`S.lib.midi_in`):
- `S.midi_device`, `S.midi_state`;
- notes, velocity, pitchbend, hot-plug (`attach_midi`, `midi_init`, `midi.add`/`midi.remove`, `midi_event`, `midi_note_on`, `midi_note_off_for`, `midi_pitchbend`, `midi_set_bend`, `midi_bend_follow_selection`, `reset_midi_input`, `midi_target_voice`, `midi_device_name`);
- the MIDI constants, `S.lib.midi_in.MIDI`, which the MIDI params in `lib/params_setup.lua` read;
- cleanup step 150: the MIDI handler detached.

MIDI notes, velocity and pitchbend play the voices (3.0 design §5).

## State

Grouped in tables:
- `S.lib.midi_in.MIDI` holds the constants: `max_port` 4, `velocity_max` 127, `rate_root_note` 60, `bend_center` 8192, `bend_semitones` 2, and the option lists.
- `S.midi_device` is the vport Strata listens to.
- `S.midi_state` holds:
  - `bend[voice]`: the ratio, default 1 (transient: never a param, never in scenes);
  - `held[voice]`: the set of held notes;
  - `note_voice[channel][note]`: the voice a note's note on played.
- `local musicutil = require "musicutil"`.

## Params

Group `strata_midi`, 3 params:
- `midi_device`: number 1..`MIDI.max_port`, default 1. Action `attach_midi(x)` then `reset_midi_input()`.
- `midi_channel_mode`: option {`per voice`, `omni to selected`}, default 1. Action `reset_midi_input()`.
- `midi_note_off`: option {`ignore`, `voice off`}, default 1.

## Device lifecycle

- `midi_init()` (from its start step, `START_ORDER.midi`, after the grids) calls `attach_midi(params:get("midi_device"))`.
- `attach_midi` clears the old vport's `event` and sets `S.midi_device = midi.connect(port); S.midi_device.event = midi_event`.
- The handler lives on the vport only: norns fires both `device.event` and `vports[port].event`, as for grids and arc.
- `midi.add(device)` re-attaches, requests a redraw (SETUP) and prints.
- `midi.remove(device)` resets the input if the device was on the selected port, requests a redraw and prints.
  - norns clears the vport as `midi.remove` returns (`Midi.update_devices`), before the next frame draws.
  - So `midi_device_name()` (the selected vport's name, or `none` without a device) then shows the port as empty.
- `cleanup` clears `S.midi_device.event`.

## Routing

- `midi_target_voice(channel)`:
  - per voice: channel 1..`NUM_VOICES` addresses that voice, other channels nothing;
  - omni: every channel addresses `S.selected_voice`.
- `midi_event(data)` parses with `midi.to_msg` and ignores everything but notes and pitchbend.

## Notes

Note on (velocity > 0):
- records the note in `held` and `note_voice`, then calls `midi_note_on(voice, note, vel)`;
- a voice with `v<i>_quantize` on plays the scale tone nearest the note instead (`S.lib.variation.midi_note`, a tie going down; scale off quantizes to semitones, so nothing changes), before any of the below (`docs/notes/lua/variation.md`). The `freq` filter then keeps a note past the freq range on the scale's last tone inside it;
- a synth source sets `v<i>_freq` to `musicutil.note_num_to_freq(note)`, clamped to `param_range`;
- a buffer source sets `v<i>_buf_rate` to `2 ^ ((note - 60) / 12)`, clamped (0.25-4);
- an input source takes no pitch;
- all through `params:set`;
- then `toggle_voice(i)` if the voice is off, and `engine.retrigger(i - 1, vel / 127)`.
- The `freq` step 0 matters: a 1 Hz step was 37 cents at 46 Hz.

Note off (or note on with velocity 0):
- goes to the voice its note on played (`note_voice`; in omni mode the selection may have moved), or to `midi_target_voice` for a note never seen;
- is removed from `held`;
- `midi_note_off_for(voice)`: in `voice off` mode, an active voice with no other held note is stopped with `toggle_voice`.
- A note during the release starts the voice again through `toggle_voice`/`voiceOn`, and the engine re-gates the releasing synths.

## Pitchbend

- `midi_pitchbend(voice, value)`: `ratio = 2 ^ (((value - 8192) / 8192) * 2 / 12)`, stored in `S.midi_state.bend[voice]`.
- Sent with `setVoiceParam(i - 1, "bend", ratio)` if the voice is active. A stopped voice gets it when it starts.
- `reset_midi_input()` (port or channel mode change, device removed) clears `held`/`note_voice` and re-centers every bent voice. It sends `bend` 1 only for voices whose bend was not 1.
- `midi_set_bend(voice, ratio)` stores a bend and (for an active voice) sends it.
- Omni bend follows the selection:
  - `select_voice_by` (E2 on MAIN and BUFFER, the only place `S.selected_voice` changes) calls `midi_bend_follow_selection(previous_voice)` when the selection moved;
  - in `omni to selected` mode with the previous voice bent (`bend ~= 1`, the wheel off center), it re-centers that voice (`bend` 1) and gives the new selection the wheel's ratio (a stopped voice gets it on start).
  - Per voice mode leaves bends alone.
- Pitchbend asks for no redraw: nothing on the screen or the arc shows the bend.
