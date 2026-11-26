## Must not break

- **Every MIDI note plays through the allocator** (`S.lib.notes.play`, owner `"midi"`, key `channel * 128 + note`), one play per voice the note on targets: `midi_note_on` never sends a note command, `toggle_voice` or `retrigger` itself. The allocator pitches the own note through the note's `set_own`, starts a stopped voice and accents slot 1 (`retrigger(i - 1, vel / 127)`); an extra note is its `noteExpression` then `noteOn`. A voice's `note cap` at 1, or a pool of 0, plays every key as 3.4 did, message for message. Velocity lands on the accent; voices keep their attacks.
- **Before each play**: `S.lib.expression.forget(voice, "midi", key)` (a re-pressed latched key takes pressure again, ruling 30), then `S.lib.expression.first_touch(voice, "midi", key, raw)` (3.6: the note's first values, which the targets the play's `started` hooks reach read through `S.lib.expression.raw`; it sends nothing, and a play that takes no slot is followed by `forget` again, so nothing is left pending), then `S.lib.sequencer.note_gate(voice)` (a gated voice's own gate length, never a step's, #639), then the play with `expression = S.lib.expression.note_values(voice, {bend, pressure, slide = 0})`, then, once the note is held, `S.lib.expression.update(voice, "midi", key, raw)` with the controller's absolute values (its slide becomes the note's reference).
- **A key is down on a voice exactly while some channel's note on lists it**: `held[voice][key]` is set exactly when `note_voice[channel][note]` holds the voice (the invariant `midi notes`). A note off goes to the voices its note on played, even if the omni selection or the MPE zones moved since; a note off no note on played changes nothing.
- **Latch** (`midi_note_off` `latch`, in every channel mode): a note off sends nothing (`S.lib.expression.latch` keeps the note's highest pressure). A note on that finds no key down on a voice first releases that voice's MIDI notes (`release_owner`; a one-shot slice still playing to its end is left to its time, so pad taps on an overlap voice ring over each other, the final review's I-1), so the next chord replaces the last. **Release** (`release`, in every channel mode): a note off calls `S.lib.notes.release` (the own note parks under other notes), and the voice's last key instead stops the voice (`toggle_voice`), whoever started it (plan ruling 8), with no release before it: the stop ends its notes, so the messages are `noteOff(v - 1, 0, 0)` when the own note's key lifts under others and `voiceOff(v - 1)` at the last key, never an unpark between.
- **A note off that never comes** (Review Focus 1): a port change, an unplug, a channel mode change, a note off change, a member count or zone change in the MPE modes and a panic release every MIDI note (the voice's stop, or `S.lib.notes.forget_owner` on every other voice) and call `S.lib.mpe.reset()` (which keeps each master channel's bend range: a controller sets it once, #688; a port change and a device change, but no other reset, also call `S.lib.mpe.reset_ranges()`), so the pool never fills with notes no key can end. The release reads the note off behavior in force after the change: in release mode the voices whose keys were down stop; a panic also stops every voice a MIDI note started.
- **A reset under latch leaves every voice sounding and parks nothing** (rulings 39 and 40): it never calls `release_owner`, which parks an own note under another owner's notes, but `S.lib.notes.forget_owner(voice, "midi")`: MIDI's extra notes end, MIDI's own note keeps sounding as nobody's, and another owner's notes (the sequencer's chords) play on, never cut and never stopped. An own note MIDI parked earlier (its key lifted in release mode under others) stays parked under them and returns, unaccented, when the voice's last note ends: the allocator never keeps a running, noteless voice parked (ruling 39).
- **Only a key down keeps a voice's own note from the sequencer** (ruling 55, refining ruling 35): `M.keeps_own(voice)` is true while MIDI's own note on the voice has its key in `S.midi_state.held[voice]`; a latched own note (its key up) gives way to a step: MIDI forgets it there (`S.lib.notes.forget`, nothing sent, and `S.lib.expression.forget` for its touch), so the step re-pitches and accents the voice's own note as in 3.4. MIDI's latched extra notes stay MIDI's. A MIDI note that lands on slot 1 calls `S.lib.sequencer.own_note_taken(voice)`, which ends a step's note override the note took slot 1 from.
- **A voice stopped under its keys forgets its notes** (the allocator's voice-stop hook); their later note offs send nothing, and the next key starts the voice again on slot 1 (Review Focus 2).
- The handler lives on the vport only (`S.midi_device = S.lib.io_ports.out(port)`), never on the raw device, and only `S.lib.io_ports` sets the vport's `event`: `midi_event` is its listener `"midi_in"` (`S.lib.io_ports.listen`). This module never sets `midi.add`, `midi.remove` or an `event` itself (a structure test checks; `docs/notes/lua/io/ports.md`). Cleanup detaches it (step 150, `unlisten`), before the voices go off.
- **The ports are read through `S.lib.io_ports` only** (#700): the port count is `S.lib.io_ports.PORTS.count` (norns' own 16) and a port's vport `S.lib.io_ports.out(port)`, never `#midi.vports`, `midi.vports[...]` or `midi.connect` through the global, which a mod may have replaced (nbout's facade has a seventeenth port of its own). The `midi_device` param's range, `vport_index` and the start step's port names follow it.
- After a silent PSET read, the `midi_input_port` hook compares the recalled port's vport with `S.midi_device`. A change runs the `midi_device` action once to move the listener, release the old controller's notes and reset its master bend ranges (#1104).
- **A claimed port is never played** (3.6): while another name owns the selected port (`S.lib.io_ports.claim`, a controller or a remote grid), the module does not listen to it; the claim releases every MIDI note and resets the master bend ranges, as a port change does (`reset_midi_input`, `S.lib.mpe.reset_ranges`), and the release listens again.
- In the running script `S.selected_voice` changes only in `select_voice_by`, which calls `midi_bend_follow_selection`, so an omni bend follows the selection. Callers reach it as `S.lib.ui_keys.select_voice_by` (`lib/ui/keys.lua`). The only other assignments in `lib/` are its initialization (`lib/voices.lua`) and the setups of the layout states of page records and voice-param records (`lib/freeze.lua`'s, `lib/notes.lua`'s, VOICE's, ...), which the layout tests and the page renders run, never the device; tests set it directly too. A scan holds the list of sites and how many assignments each holds, by file and function (`SELECTED_VOICE_SITES` in `test/unit/ui_detent_test.lua`, the count's one home, "S.selected_voice is assigned only by select_voice_by, at init and in layout states", #875): a new assignment outside them, or one more inside a listed function, fails it.
- The `freq` controlspec has step 0, so notes keep their exact pitch: a key's pitch in the tuning (`S.lib.variation.midi_note`: `S.lib.tuning.pitch_of_key`, then `snap` on a quantized voice; exact equal temperament in twelve equal steps, 3.8).
- A quantized voice's every note, own or extra, snaps to the scale (`S.lib.variation.midi_note`) before it is played; an unquantized voice's never does.
- **The note tap is read once per note on**: `set_note_tap(owner, fn)` and `clear_note_tap(owner)` may be called from inside `fn` (the zones editor's learn ends itself there), and a new tap or none takes effect from the next note. A consumed note never enters `note_voice`, so its note off does nothing. `reset_midi_input` and cleanup clear the tap; the layout hook never does (the learn changes the layout while its tap is set).
- **The note tap has one owner** (3.9, #900): `note_tap` and `note_tap_owner` are set together and cleared together. A set by another owner while one holds the tap is refused (`false`), and a clear by another owner does nothing, so the scale editor can neither take nor clear the zones learn's tap. `reset_midi_input` and cleanup clear it whoever holds it and then tell the owner, calling its `fn(nil)` once (contained, after the notes are released); the owner may set it again while told (the open scale editor does; a zones learn ends). An owner covered by another modal owner (SEQ's step editor) takes no note: each owner's `fn` reads `S.lib.ui_modal.top()`, so nothing is stored for it.
- The selected vport's device is reconciled when the norns menu closes (`M.reconcile`, a `register_menu_close` hook). Only a change of device resets the held notes, never an ordinary menu visit: SYSTEM > DEVICES moves a device with `update_devices()` and calls neither `midi.add` nor `midi.remove`.
- A panic (CC 123 or CC 120) stops every active voice that has a key down or is in `S.midi_state.started` (set when a note on finds the voice stopped and the play starts it, cleared when a MIDI note off or a panic stops it), in either note off mode, never one the norns, grid or a pattern started. A `grain_restart` hook registered in the start step clears the flag when a voice starts (its reason `"start"`; a running voice's source change, reason `"source"`, leaves it); `midi_note_on` sets it after the play's start, so a voice stopped and restarted from the norns, grid or a pattern is never the panic's. The `midi notes` invariant checks `started`'s keys.
- **Program change in** (3.6, MIDI out's `midi_pc_in`, off by default): with it on, a program change 0 to `NUM_SCENES` - 1 on `midi_pc_channel`'s channel (its first option, `any`, every channel) calls `S.lib.io_midi_out.program_change_in(listening port, value)`, which recalls scene value + 1 as a scene key does (`docs/notes/lua/io/midi_out.md`). Its branch of `midi_event` sits before the MPE branch, so it recalls in every channel mode; any other program change, or any with `midi_pc_in` off, falls through to the branches as before (ignored, or to `S.lib.mpe.control` in the MPE modes, which ignores it).
- Strata's code handles no CC but 123 and 120 (`release_held_notes(true)`) and, in the MPE modes, MPE's (74, 87, 6, 38, 100, 101, through `S.lib.mpe.control`); norns' PARAMS > MAP maps any other CC to any param. CC74 is not read in the plain modes.
- The hot-plug and claim handlers (`S.lib.io_ports.on_change("midi_in", ...)`, `on_claim("midi_in", ...)`) are registered in the start step, never at include time: they read the `midi_device` param, which init adds (#469). The layout hook is registered there too (`S.lib.mpe` is included after this module).
- **A held-back stop marks only a running voice with no key down** (`stop_pending`, 3.7; the `midi notes` invariant since 3.9, #913): only the last key's lift in release mode under a note playing to its end sets it, and every clearer (below, Machines) keeps it from outliving that.

## Machines

### midi notes
- **State:** per voice, the keys down on it (`S.midi_state.held[voice]`, each `channel * 128 + note`, mirrored by `S.midi_state.note_voice[channel][note]`, the list of voices the note's note on played), whether a MIDI note started it (`S.midi_state.started[voice]`) and whether its release-mode stop is held back (`stop_pending[voice]`, a local). The states below are a voice's: `no key` (nothing held, no mark), `keys down` and `stop held back` (no key down, the mark set, the voice running while a note of it plays to its end, `S.lib.notes.plays_to_end`). This entry's table is release mode's (`midi_note_off` `release`); latch's is the next entry's.
- **Invariant:** `midi notes`: a key is down on a voice exactly while some channel's note on lists the voice for it (each list non-empty, its voices valid and distinct); `started` holds only `true` for a valid voice; `stop_pending` marks only a running voice with no key down (3.9, #913).
- **Test:** `test/unit/midi_in_test.lua`: the `midi notes` transition table (`h.transition_table`, this table) and the `midi notes, latch` one (the next entry's); beside them "the midi notes invariant holds a held-back stop to a running voice with no key down (#913)", "a held-back stop is cleared by the voice's stop and by a key down (#913)", "a release-mode voice held back by another owner's one-shot slice stops when the last ends", "a release-mode voice restarted right after its last key stopped it keeps running", "release: each key's note ends with its key, the own note parks, the voice stops with the last", "latch: a panic CC stops a voice a released key started, never one started elsewhere (#529)"; the source switch's three rows (#1009): "the midi notes table: no key + a running voice's source switch keeps started", "the midi notes table: keys down + a running voice's source switch keeps the keys", "a held-back stop outlives a running voice's source switch".

The table is split by note off mode, each part run by an `h.transition_table` (3.9, #1028): a row's outcome depends on the mode (the last key's lift stops the voice in release mode and latches its notes in latch), and a change of mode is itself a reset (the `midi_note_off` action calls `reset_midi_input`), so each table's states set the mode first and then enter the state, as the note tap's states set the channel mode first. The rows the two modes share are in both tables. Here each state is voice 1's (the selected voice, which channel 1's notes play), in release mode: `no key` is the voice the start-up runs, which no MIDI note started; `keys down` two keys (36, then 37) that started the stopped voice; `stop held back` one key that started it, lifted while its slice plays to its end. The voice plays one-shot slices (each 0.5 s) so that a note can play to its end: a lift never cuts a slice short, so `last key up, nothing plays to its end` holds the keys past their slices' ends before they lift, and `the LFO step, a note still plays to its end` plays a grid key's slice first; a `last key up` lifts the other key first, then the last. On a synth voice a key's lift under others ends its note instead (the own note parks under the others), which the named test "release: each key's note ends with its key, the own note parks, the voice stops with the last" runs. `latch set, then the LFO step` is the mark's drop: the change is a reset (latch's: MIDI's notes forgotten, no voice stopped), then the step. Impossible: a key up in `no key` and in `stop held back` (no key is down: the mark is set only with none down). The invariant's test checks the mark's line, not a row.

A reset is `release_held_notes` (from `reset_midi_input`: a port or channel mode change, a note off change, the selected port's device gone, moved or claimed; and the MPE layout hook in the MPE modes); a panic is CC 123 or 120. `started` runs beside the table: set by `midi_note_on` when its play started a stopped voice, cleared by the grain-restart hook at every start, by `midi_note_off_for`'s stop and by the panic, which also stops every voice it holds. The mark's four clearers are a key down, the voice's stop (the voice-stop hook), its start (the grain-restart hook, reason `"start"`; a stopped voice holds no mark already, so this one only guards; a running voice's source switch, reason `"source"`, leaves the mark, test "a held-back stop outlives a running voice's source switch") and the LFO step, which stops the voice once no note of it plays to its end, or drops the mark once the voice no longer runs in release mode with no key down. A panic stops only a voice a MIDI note started (or one with a key down), so on a voice started elsewhere a held-back stop outlives it, for the LFO step. Impossible: `stop held back` with a start (the voice runs; a stop first clears the mark).

| State | Event | Next | Effect |
|---|---|---|---|
| `no key` | `key down` | `keys down` | the key is held and its slice plays; `started` stays unset (the voice already ran) |
| `no key` | `the voice's stop` | `no key` | the voice stops |
| `no key` | `a reset` | `no key` | nothing held: nothing sent, the voice runs on |
| `no key` | `a panic` | `no key` | the voice runs on: no MIDI note started it |
| `no key` | `a running voice's source switch` | `no key` | the voice runs on; `started` stays unset |
| `no key` | `the LFO step, nothing plays to its end` | `no key` | no mark: the voice runs on |
| `no key` | `the LFO step, a note still plays to its end` | `no key` | no mark: the voice runs on |
| `no key` | `latch set, then the LFO step` | `no key` | the voice runs on |
| `keys down` | `key down` | `keys down` | another key held, its slice plays |
| `keys down` | `key up, others down` | `keys down` | its one-shot slice plays on to its end: nothing sent, the voice runs on |
| `keys down` | `last key up, nothing plays to its end` | `no key` | the voice stops (`midi_note_off_for`), `started` cleared |
| `keys down` | `last key up, a note plays to its end` | `stop held back` | the mark set; the voice runs on and its slices play on |
| `keys down` | `the voice's stop` | `keys down` | its notes forgotten; the keys stay down, their offs send nothing |
| `keys down` | `a reset` | `no key` | every key released and the voice stopped, `started` cleared |
| `keys down` | `a panic` | `no key` | every key released and the voice stopped, `started` cleared |
| `keys down` | `a running voice's source switch` | `keys down` | the voice runs on; the keys, their note ons' lists and `started` kept |
| `keys down` | `the LFO step, nothing plays to its end` | `keys down` | the keys stay down, the voice runs on |
| `keys down` | `the LFO step, a note still plays to its end` | `keys down` | the keys stay down, the voice runs on |
| `keys down` | `latch set, then the LFO step` | `no key` | every key released and MIDI's notes forgotten; the voice runs on |
| `stop held back` | `key down` | `keys down` | the mark goes: the new key's lift decides again |
| `stop held back` | `the voice's stop` | `no key` | the mark goes with the stop |
| `stop held back` | `a reset` | `stop held back` | MIDI's notes forgotten (its slice playing to its end too), the voice runs on; the next LFO step stops it |
| `stop held back` | `a panic` | `no key` | the voice MIDI started stops, which clears the mark; `started` cleared |
| `stop held back` | `a running voice's source switch` | `stop held back` | the mark kept (the hook's reason `"source"`): the voice runs on, and stops once nothing plays to its end |
| `stop held back` | `the LFO step, nothing plays to its end` | `no key` | the voice stops (`midi_note_off_for`), `started` cleared |
| `stop held back` | `the LFO step, a note still plays to its end` | `stop held back` | it waits: the voice runs on |
| `stop held back` | `latch set, then the LFO step` | `no key` | the mark dropped; the voice runs on |

### midi notes, latch
- **State:** the `midi notes` entry's state, in latch mode (`midi_note_off` `latch`): `no key`, `keys down` and `stop held back`, which only a release-mode lift sets, so latch holds it only from a change to latch until the next LFO step drops the mark.
- **Invariant:** none: the `midi notes` entry above enters it.
- **Test:** `test/unit/midi_in_test.lua`: the `midi notes, latch` transition table (`h.transition_table`, this table); beside it "latch: lifting changes nothing, and the next chord's first key replaces the chord", "a reset under latch forgets MIDI's notes and leaves another owner's playing", "latch: a panic CC stops a voice a released key started, never one started elsewhere (#529)", "the midi notes table: no key + a running voice's source switch keeps started", "on an overlap one-shot voice sequential slice taps ring over each other in every note-off mode".

Each state is voice 1's and sets latch first, but `stop held back`: that is the release table's state, then latch set (the change is a reset, which forgets MIDI's notes and leaves the mark). In `no key` a released key's note (60) started the voice and sounds on, latched; in `keys down` two keys (60, then 64) started it; both on its synth source. In `stop held back` it plays one-shot slices, as in the release table. The release table's events that only release mode has are not here: every lift latches (`last key up` lifts the other key first, then the last), and the LFO step has only a mark to drop, so it is one event. On a voice of one-shot slices the next chord leaves the last chord's slices playing to their ends (the final review's I-1), which "on an overlap one-shot voice sequential slice taps ring over each other in every note-off mode" runs. Impossible: a key up in `no key` and in `stop held back` (no key is down: the mark is set only with none down).

| State | Event | Next | Effect |
|---|---|---|---|
| `no key` | `key down` | `keys down` | the last chord's note released first (the next chord replaces the last); the key held, its note plays |
| `no key` | `the voice's stop` | `no key` | the voice stops; its latched note forgotten |
| `no key` | `a reset` | `no key` | MIDI's latched note forgotten: nothing sent, the voice sounds on |
| `no key` | `a panic` | `no key` | the voice MIDI started stops, `started` cleared |
| `no key` | `a running voice's source switch` | `no key` | the voice runs on, `started` kept: a panic still stops it |
| `no key` | `the LFO step` | `no key` | the latched note sounds on, the voice runs on |
| `keys down` | `key down` | `keys down` | another key held, its note plays; the chord's notes play on |
| `keys down` | `key up, others down` | `keys down` | the note latches: it sounds on, nothing sent |
| `keys down` | `last key up` | `no key` | the notes latch and sound on; the voice runs on, `started` kept |
| `keys down` | `the voice's stop` | `keys down` | its notes forgotten; the keys stay down, their offs send nothing |
| `keys down` | `a reset` | `no key` | every key released and MIDI's notes forgotten; the voice runs on |
| `keys down` | `a panic` | `no key` | every key released and the voice stopped, `started` cleared |
| `keys down` | `a running voice's source switch` | `keys down` | the voice runs on; the keys, their note ons' lists and `started` kept |
| `keys down` | `the LFO step` | `keys down` | the keys stay down, the voice runs on |
| `stop held back` | `key down` | `keys down` | the mark goes |
| `stop held back` | `the voice's stop` | `no key` | the mark goes with the stop |
| `stop held back` | `a reset` | `stop held back` | the mark kept for the LFO step; the voice runs on |
| `stop held back` | `a panic` | `no key` | the voice MIDI started stops, which clears the mark; `started` cleared |
| `stop held back` | `a running voice's source switch` | `stop held back` | the mark kept; the voice runs on |
| `stop held back` | `the LFO step` | `no key` | the mark dropped; the voice runs on |

### note tap
- **State:** `note_tap` (a local: nil, or the function every note on goes to first) and `note_tap_owner` (its owner's name, nil exactly while `note_tap` is; 3.9, #900), set with `M.set_note_tap(owner, fn)` and cleared with `M.clear_note_tap(owner)` by its two owners, SETUP's zones editor's learn (`lib/ui/zones.lua`, `ZONES_EDITOR.tap_owner`) and the scale editor (`lib/ui/scale_editor.lua`, `SCALE_EDITOR.tap_owner`), and read through `M.note_tap_owner()`. States: `none` and `set` (an owner, the holder, holds it).
- **Invariant:** none registered: `set_note_tap` and every clear set and clear the two together (the table's test checks they agree in every state).
- **Test:** `test/unit/midi_in_test.lua`: the `note tap` transition table (`h.transition_table`, this table), "a note tap consumes the notes it takes, and their note offs", "the note tap is set and cleared by its owner only", "a MIDI reset tells the tap's owner"; `test/unit/ui_zones_test.lua`: "the zones learn's tap is not cleared by the scale editor", "a MIDI reset tells the zones learn, which ends"; `test/unit/ui_scale_editor_test.lua`: "a note while the step editor covers the scale editor toggles no scale class", "a MIDI reset tells the scale editor, which takes its tap back at once".

A set and a clear name an owner: in `set` the holder's set replaces its `fn`, another owner's set is refused and another owner's clear does nothing; in `none` any owner's set takes the tap and any clear does nothing. The two clears the owner did not make, a reset (`reset_midi_input`) and cleanup, tell the owner (its `fn(nil)`, after the tap is cleared): the open scale editor takes the tap back then, a zones learn ends. A covered owner (SEQ's step editor over it) keeps the tap and takes no note, its `fn` reading the modal stack: that is the owners', not a state of this table. The MPE layout hook keeps the tap. Impossible: `none` with `note on, taken` (with no tap `tapped` takes nothing).

| State | Event | Next | Effect |
|---|---|---|---|
| `none` | `set` | `set` | every note on goes to the tap first |
| `none` | `set by another owner` | `set` | taken: no owner held it |
| `none` | `cleared by the holder` | `none` | nothing |
| `none` | `cleared by another owner` | `none` | nothing |
| `none` | `note on, not taken` | `none` | the note plays |
| `none` | `a reset` | `none` | nothing to tell |
| `none` | `the MPE layout hook` | `none` | nothing |
| `none` | `cleanup` | `none` | nothing to tell |
| `set` | `set` | `set` | the holder's new tap from the next note (a tap may set it while it runs) |
| `set` | `set by another owner` | `set` | refused (`false`): the holder keeps it |
| `set` | `cleared by the holder` | `none` | from the next note |
| `set` | `cleared by another owner` | `set` | nothing (`false`) |
| `set` | `note on, taken` | `set` | the note plays nothing and enters no list, so its off does nothing |
| `set` | `note on, not taken` | `set` | the note plays |
| `set` | `a reset` | `none` | cleared, then the holder told (`fn(nil)`) |
| `set` | `the MPE layout hook` | `set` | kept: the zones editor's learn changes the layout while it is set |
| `set` | `cleanup` | `none` | cleared, then the holder told |

### listening port
- **State:** `listening_port` (a local: the port `midi_event` listens on through `S.lib.io_ports.listen`, nil while the selected port is claimed or after cleanup), `S.midi_device` (the selected port's vport) and `attached_device` (the device last seen on it); the selected port is the `midi_device` param. States: `listening` (the selected port is free), `claimed` (another name owns it: not listened to, its notes never played) and `ended` (cleanup has run).
- **Invariant:** none here: a port's listeners and its owner are the `midi ports` machine's (`lib/io/ports.lua`), which holds that its event and its listeners agree.
- **Test:** `test/unit/midi_in_test.lua`: "MIDI in leaves a claimed port alone", "the MIDI port moved onto a claimed port listens to nothing until the claim is released", "MIDI device param, hot-plug and the SETUP page", "a MIDI device moved off the selected port in SYSTEM > DEVICES gives up the notes it held".

A claim releases every MIDI note and resets the master bend ranges, as a port change does; its release listens again and resets nothing. SETUP's `midi` row names a claimed port's owner (`docs/notes/lua/pages/setup.md`); IO's `midi` section shows a `midi in <port> (<owner>)` status row while the port is claimed, so the keyboard not being heard is said there too (#913, `docs/notes/lua/io/midi_out.md`). Nothing happens in `ended`: every handler is gone (`lib/io/ports.lua`'s step after this one hands hot-plug back).

| State | Event | Next | Effect |
|---|---|---|---|
| `listening` | `claimed` | `claimed` | unlistened; every MIDI note released, the ranges reset |
| `listening` | `another port selected, free` | `listening` | listens there; every MIDI note released |
| `listening` | `another port selected, claimed` | `claimed` | unlistened; every MIDI note released |
| `listening` | `the device leaves` | `listening` | every MIDI note released, the ranges reset; still listening on the port |
| `listening` | `a device arrives` | `listening` | attached; on the selected port the ranges reset |
| `listening` | `the menu closes, the device moved` | `listening` | every MIDI note released, the ranges reset |
| `listening` | `cleanup` | `ended` | unlistened, the tap cleared |
| `claimed` | `released` | `listening` | listens again |
| `claimed` | `another port selected, free` | `listening` | listens there |
| `claimed` | `another port selected, claimed` | `claimed` | nothing heard |
| `claimed` | `the device leaves` | `claimed` | nothing heard (nothing held to release) |
| `claimed` | `a device arrives` | `claimed` | attached, still not heard |
| `claimed` | `cleanup` | `ended` | the tap cleared |

## Owns

`lib/midi_in.lua` (`S.lib.midi_in`):
- `S.midi_device`, `S.midi_state`;
- notes, chords, velocity, pitchbend, pressure, MPE's routing and expression, hot-plug through `S.lib.io_ports` (`attach_midi`, `midi_init`, the `on_change` and `on_claim` handlers, `midi_event`, `midi_note_on`, `midi_note_off_for`, `midi_pitchbend`, `midi_set_bend`, `midi_bend_follow_selection`, `reset_midi_input`, `midi_target_voice`, `midi_device_name`), `M.note_off_mode()`, `M.set_note_tap(owner, fn)`, `M.clear_note_tap(owner)` and `M.note_tap_owner()`;
- the MIDI constants, `S.lib.midi_in.MIDI`, which the MIDI params in `lib/params_setup.lua` read;
- cleanup step 150: the MIDI handler detached (`S.lib.io_ports.unlisten`) and the note tap cleared, its owner told; `lib/io/ports.lua`'s step 152 then puts back the `midi.add` and `midi.remove` it found (norns' SLEEP runs only `cleanup()`, #468).

MIDI notes, velocity, pitchbend and pressure play the voices (3.0 design §5, 3.5 design §5). It calls `S.lib.notes` (`docs/notes/lua/notes.md`), `S.lib.mpe` (`docs/notes/lua/mpe.md`) and `S.lib.expression` (`docs/notes/lua/expression.md`).

## State

Grouped in tables:
- `S.lib.midi_in.MIDI` holds the constants: `velocity_max` 127, `rate_root_note` 60 (a buffer or input voice's note at rate 1; 3.7: `own_setters` read `S.lib.samples.rate_root(voice)`, a buffer voice's file's key when set, and the constant stays equal to the engine's), `bend_center` 8192, `bend_semitones` 2, the option lists, `owner` (`"midi"`), `channels` 16, `notes_per_channel` 128 (a key is `channel * 128 + note`) and `pressure_max` 127.
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
- `midi_device`: number 1..`S.lib.io_ports.PORTS.count` (norns' 16 ports), default 1, stepping whole numbers under PARAMS' K3-held fine turn (#534, `docs/notes/lua/params.md`). Action `attach_midi(x)` then `reset_midi_input()`.
- `midi_channel_mode`: option {`per voice`, `omni to selected`, `mpe selected`, `mpe split`}, default 1; 3.4's two indices kept, the MPE modes appended. Action `reset_midi_input()`.
- `midi_note_off`: option {`latch`, `release`}, default 1 (3.8's groundwork, design section 8). `M.note_off_mode()` gives the option, whatever the channel mode. Nothing converts an old PSET: its index 1 (3.7's `auto`, 3.4's `ignore`) loads as `latch`, 2 (`release`, 3.4's `voice off`) stays `release`, and 3 (3.7's `latch`) is clamped to `release` by norns' `Option:set`. Action `reset_midi_input()`, as a channel mode change has: no chord carries from one behavior into the other (ruling 37).

## Device lifecycle

- `midi_init()` (from its start step, `START_ORDER.midi`, after the grids) calls `attach_midi(params:get("midi_device"))`.
- `attach_midi` rounds its port to a vport index (1..`S.lib.io_ports.PORTS.count`), so a fraction (a PSET written before the param stepped whole numbers, #534) still names a port, sets `S.midi_device = S.lib.io_ports.out(port)` and listens to it (`S.lib.io_ports.listen(port, "midi_in", midi_event)`, unlistening the old port) unless another name owns it. The listening changes only when the port or its claim does, so `"midi_in"` keeps its place among the port's listeners through a plug or a menu move on another port. The unplug handler compares the device's port with the same rounded index.
- The handler lives on the vport only: norns fires both `device.event` and `vports[port].event`, as for grids and arc.
- A device's arrival at a port (`on_change(port, name)`: norns' `midi.add`, or a move seen as the menu closes) re-attaches, resets the master bend ranges when it is the selected port (#688), requests a redraw (SETUP) and prints.
- A departure (`on_change(port, nil)`) resets the input and the ranges if it was the selected port, requests a redraw and prints the name last heard for the port.
  - norns clears the vport as `midi.remove` returns (`Midi.update_devices`), before the next frame draws.
  - So `midi_device_name()` (the selected vport's name, or `none` without a device) then shows the port as empty.
- The module keeps `attached_device`, the device last seen on the selected vport (set in `attach_midi`, nil after `midi.remove` took the selected port's device).
- SYSTEM > DEVICES moves a device between ports through `update_devices()` only (no `midi.add`, no `midi.remove`). `S.lib.io_ports`' menu-close hook, which runs first, tells of each move as a departure and an arrival (above), so the module's own record is current; `M.reconcile()` then runs as the menu closes (and on its own in tests): when `S.midi_device.device` is not `attached_device`, it calls `reset_midi_input()` if a device had been attached (its note offs and bend returns will not arrive), remembers the new device and requests a redraw. A menu visit that moves nothing does nothing. A device moved off the selected port and back inside one menu visit is the same device when the menu closes, so its held notes stay.
- `cleanup` unlistens and clears the note tap.

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

Slices (3.7, design §3.5, package 2b): on a voice that takes slice notes (`S.lib.slices.takes_notes`: a buffer voice whose `v<i>_slices` is not off and whose slot has slices), `midi_note_on` branches before the pitch: note `SLICES.first_note + n - 1` (36 for slice 1) calls `S.lib.slices.play(voice, n, {owner = "midi", key, velocity = vel / 127, park = true, expression})` at the voice's own pitch, with the same tail as any note (`started`, `own_note_taken`, the expression's update or forget). A note outside the slices is no note of that voice: `note_on` drops the voice from its targets (`ignored`), so it holds no key and releases nothing there. A key's lift releases through `S.lib.slices.note_off` (which leaves a one-shot slice playing to its end); in release mode the voice's last key stops it as for any note, unless a note of it plays to its end (`S.lib.notes.plays_to_end`). That note ends at its time (`docs/notes/lua/notes.md`). Only that lift marks the voice (`stop_pending`, set in `end_key` when `plays_to_end` held the stop back); a key down, the voice's stop and its start (the voice-stop and grain-restart hooks) clear the mark, so a voice restarted within a step of its last key's stop (a pattern step, K3, a grid key, a recall) is never stopped by it. At each LFO step a marked voice still running in release mode with no key down is stopped (`midi_note_off_for`) once no note of it plays to its end, whichever owner's note (MIDI's, a grid's, an overlap step's) ended last; anything else drops the mark. So a release-mode voice never runs on unheld.

**The `heard` note hook** (3.7, the controller's ruling on 2b's review): every MIDI note a voice receives (after the note tap, before the slice filter, so a note outside a voice's slices too) runs each note hook's `heard(voice, note, velocity)` (the note's number, velocity 0-1), contained (`strata: note hook <name> heard failed: `). It starts nothing and never reaches the targets: `started` stays for notes that play. The slice editor's key row listens through it (`docs/notes/lua/ui/slice-editor.md`).

## Expression

- Plain modes (design §5.3): the pitch bend is the voice's `bend` (below), bending every note of the voice; a note's own `bend` is 1. Poly aftertouch is its note's pressure: `S.lib.expression.update(voice, "midi", key, {pressure = val / 127})` on each voice the key's note on played. Channel pressure is every held key of the channel's, and is kept as the channel's pressure for its next notes. CC74 is not read.
- MPE modes (design §5.4): each channel `S.lib.mpe.control(msg)` returns (a member's bend, pressure or CC74; a master's bend lists its whole zone; an RPN 0 its channels) has every key it holds updated with `S.lib.mpe.values(channel)`. Poly aftertouch is ignored, and the voices' `bend` stays at 1.
- Only held keys are updated: a latched note's later updates change nothing (`S.lib.expression`), and a key lifted in latch mode is no longer in `note_voice`.

## Releasing everything

`release_held_notes(stop_all)` (local), from `reset_midi_input()`, the panic (`stop_all`) and the layout hook:
- per voice, the voice stops (`toggle_voice`, whose voice-stop hook forgets its notes) when it is active and its keys were down in release mode (the mode read after the change), or, with `stop_all`, it had a key down or was `started`; every other voice gets `S.lib.notes.forget_owner(voice, "midi")` (ruling 40), which parks nothing: MIDI's held extra notes end (`noteOff`), and its held own note is dropped from the records with nothing sent, so the voice sounds on as 3.4's latch did, and another owner's notes play on. An own note MIDI parked earlier stays parked under the other owners' notes; when the last of them ends, the allocator brings it back as the voice's drone (`noteOn` on slot 0 at velocity 0, ruling 39), and if the reset itself ends the voice's last held note (MIDI's extra notes over its parked own note), it comes back at once;
- `held`, `note_voice` and the plain pressures are emptied and `S.lib.mpe.reset()` runs (every channel's values, pending CC87 and RPN state forgotten, the master channels' bend ranges kept, #688); a panic empties `started` too.
- With nothing held it sends nothing, so the layout hook, which may run several times in one PSET load and see a layout mid-change, is cheap and idempotent.

`reset_midi_input()` (a port or channel mode change, the selected port's device gone or moved) re-centers every bent voice (`bend` 1 sent only to active voices whose bend was not 1), releases everything, then clears the note tap and tells its owner (3.9, #900). The `midi_note_off` param's action is `reset_midi_input()` too. The layout hook (`S.lib.mpe.on_layout_change`, registered in the start step: a member count or zone change, ruling 14) releases everything only while `S.lib.mpe.active()` (the plain modes route nothing through the zones), and keeps the tap and the bends.

## The note tap

`M.set_note_tap(owner, fn)` (the zones editor's learn, SETUP's `mpe & zones`, design §9.3, and the scale editor; an owner is a name, `ZONES_EDITOR.tap_owner` and `SCALE_EDITOR.tap_owner`, since 3.9's #900): while a tap is set every note on, in any mode, goes to `fn(note)` first, read once into a local and called through `S.lib.ui_frame.contained_call` (one that raises is reported once and takes nothing); `true` consumes the note (nothing plays, no key goes down, so its note off does nothing). It returns `true`, or `false` when another owner holds the tap (nothing changes); the owner's own set replaces its `fn`. `M.clear_note_tap(owner)` clears the owner's tap (`true`), and another owner's clear does nothing (`false`); `M.note_tap_owner()` names the owner, or nil. `fn` may clear or replace the tap while it runs; the change applies from the next note on. An owner that is not a non-empty string, or a `fn` that is not a function, raises. A clear the owner did not make (`reset_midi_input`, cleanup) calls the cleared `fn(nil)` once, through `contained_call` (key 2, `midi note tap's owner told`), after the tap is cleared, so the owner can take it back.

## Pitchbend

- `midi_pitchbend(voice, value)` (the plain modes): `ratio = 2 ^ (((value - 8192) / 8192) * 2 / 12)`, stored in `S.midi_state.bend[voice]`.
- Sent with `setVoiceParam(i - 1, "bend", ratio)` if the voice is active. A stopped voice gets it when it starts.
- `midi_set_bend(voice, ratio)` stores a bend and (for an active voice) sends it.
- Omni bend follows the selection:
  - `select_voice_by` (MAIN's E2, SEQ's and IO's voice picks and the arc's SEQ ring 4; the only place the running script changes `S.selected_voice`) calls `midi_bend_follow_selection(previous_voice)` when the selection moved;
  - in `omni to selected` mode with the previous voice bent (`bend ~= 1`, the wheel off center), it re-centers that voice (`bend` 1) and gives the new selection the wheel's ratio (a stopped voice gets it on start).
  - The other modes leave bends alone.
- Pitchbend asks for no redraw: nothing on the screen or the arc shows the bend.

## Tests

The key state, the held-back stop, the tap and the port are under Machines, above (3.9 moved 3.5's States table there, #913). Tests: `test/unit/midi_in_test.lua` (pitch per source, velocity, the start order, clamping and channels; chords and the cap of 1; latch and release, in every channel mode; a note off's voices, repeated note ons in omni; input voices' grain pitch; quantize; pressure in the plain modes; mpe selected and mpe split, MPE's per-channel updates; the releases of every note, Review Focus 1 (a reset under latch with another owner's notes, a parked own note's return, a note off change, the layout hook only in the MPE modes and twice in a row, RPN 6 mid-handler), and a stopped voice's forgotten notes, Review Focus 2; the note tap; an old PSET's note off indices; pitchbend; hot-plug, the menu's reconcile and SETUP). `test/unit/sequencer_test.lua` plays real MIDI against the patterns for ruling 55: a latched note giving way at a note cap of 1 and a pool of 0, a key held down through steps, and a MIDI note taking a step's own note.
