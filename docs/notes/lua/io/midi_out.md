## Must not break

- **Nothing by default**: with every param at its default no message goes to any port. A voice is routed only while `v<i>_out_port` is above 0, a CC slot sends only while its source is not `off`, and program change in and out are off.
- **One door**: every message goes through the vport `S.lib.io_ports.out(port)` gives (`note_on`, `note_off`, `cc`, `pitchbend`, `channel_pressure`, `program_change`); `S.lib.io_ports.device(port)` says whether a device is there. The module never reads the `midi` global and never sets anything on a vport.
- **An off for every on**: each sounding id keeps the port, channel and note its on went to, and its off goes there whatever the params say by then. Ids on one port, channel and note are counted, and the note off goes when the last ends. A route param's change calls `S.lib.io_targets.route_changed(voice)` before the zone follows, so the old notes' offs go out first.
- **A played note is never sent back to the port it arrived on** (ruling 17): a note with `info.source == "midi"` is skipped when the voice's port is the `midi_device` param's.
- **One MPE voice a port, in its lower zone** (decision 20): a change of a voice's mode, port, channel or members that would put a second MPE voice on a port, or a plain voice's channel inside an MPE zone on its port (1 to members + 1), is put back silently to the value the module last applied, with the header flash `port has an mpe voice`. The invariant `midi out` holds it.
- **A played MPE note's first values go before its note on**, on its member channel and in this order: pitchbend, channel pressure (when it has one), CC 74 (when it has one), read from `S.lib.expression.raw(voice, owner, key)`. That read works at the note on because `lib/midi_in.lua` calls `S.lib.expression.first_touch` before `S.lib.notes.play` (ruling A, `docs/notes/lua/expression.md`). A step note gets a centered bend (8192) before its note on and no expression.
- **Later values are read, not waited for** (ruling B): the LFO step hook reads `raw` for each sounding played MPE note and sends each of bend, pressure and slide whose outgoing value differs from what that note last sent, at most `MIDI_OUT.express_per_step` (24) messages a step, round robin from the note the last step stopped at, always the value current at the send. The note hook `expressed` fires only when a voice's own mapped values change (`lib/expression.lua`'s `hand_over`), so a pressure or slide the voice maps to nothing would never reach the target through `express`; a played note's bend, pressure and slide go out whatever the voice's mapping, which decides only what Strata's engine does with them. So the target has no `express` field. A step reads `raw` once for each sounding played MPE note (at most 15) and keeps none of its tables across steps. A note that ended sends nothing more.
- **A device's return gets all notes off** (Review Focus 2): CC 123 on each channel the module had notes on as the device left or has now, then the MPE setup of a voice on that port; a channel that never had a note gets none.
- **Program change in is not echoed** (Review Focus 3): `program_change_in(port, value)` notes the port and scene before it asks `S.lib.io_actions.recall_scene(value + 1)`; the next scene-recalled hook drops the note and sends nothing when that scene's program change would go to that port.
- **Params are PSET-only**: none is a scene field, a macro target, an LFO destination, a fader-page param or drawn by a randomize or mutation. The CC slots' sources are kept by key (`S.lib.io_keyed`, ruling 24).
- **Hooks and targets never yield** and never call `S.lib.notes.play`.

## Owns

- `lib/io/midi_out.lua` (`S.lib.io_midi_out`): `MIDI_OUT` (`express_per_step` 24, `cc_per_step` 8, `slots` 8, `master_channel` 1, `master_bend_range` 2, `slide_cc` 74, `all_notes_off_cc` 123, and the RPN numbers, the bend's center and range, the texts), `add_params()`, `program_change_in(port, value)`, `stop()`.
- The note target `midi` (`routed`, `note_on`, `note_off`, `rows`), one LFO step hook (expression, then CC out), a scene-recalled hook (program change out), the `S.lib.io_ports.on_change` hook `io_midi_out`, IO's `midi` section, the cleanup step `io_midi_out` (143) and the invariant `midi out`.
- Its unit tests: `test/unit/io_midi_out_test.lua`; the program change branch of `lib/midi_in.lua` is tested in `test/unit/midi_in_test.lua`. User page: `docs/user/io/midi-out.md`.

## Params

The group `strata_out_midi`, 74 params, added by the menu record `out midi` of `lib/params_setup.lua`:
- per voice: `v<i>_out_port` (0 off, 1 to 16; 0), `v<i>_out_channel` (1 to 16; i), `v<i>_out_mode` (`plain`, `mpe`; `plain`), `v<i>_out_members` (1 to 15; 15);
- `midi_out_bend_range` (1 to 96; 48): the member channels' bend range;
- per slot k, 1 to 8: `cc_out<k>_source` and its hidden `cc_out<k>_source_key` (`S.lib.io_keyed.add`: the keys `off`, then each modulation source's key as `S.lib.mod_sources.registered()` lists them at init), `cc_out<k>_port` (1 to 16; 1), `cc_out<k>_channel` (1 to 16; 1), `cc_out<k>_number` (0 to 127; k);
- `midi_pc_in` and `midi_pc_out` (binary toggles, off; ruling 25), `midi_pc_channel` (`any`, 1 to 16; `any`), `midi_pc_out_port` (1 to 16; 1), `midi_pc_out_channel` (1 to 16; 1).

## How it works

- **The route** of each voice is kept as applied (`config`): the param actions check the proposed routes (`conflict`), then apply, end the voice's notes and move the zone. Setup, sent when the mode turns on, the port or the members change, the bend range changes or the port's device arrives: `cc(101, 0, 1)`, `cc(100, 6, 1)`, `cc(6, members, 1)`; `cc(101, 0, 2)`, `cc(100, 0, 2)`, `cc(6, bend_range, 2)`; `cc(101, 0, 1)`, `cc(100, 0, 1)`, `cc(6, 2, 1)`. Takedown, when the mode turns off or the port changes or goes to 0, on the old port: `cc(101, 0, 1)`, `cc(100, 6, 1)`, `cc(6, 0, 1)`.
- **Plain**: note `clamp(round(pitch), 0, 127)`, velocity `max(1, round(velocity * 127))`, on the voice's channel.
- **MPE allocation**: the free member channel released longest ago; with none free, the one with the fewest notes, and among those the one given a note longest ago. A bend is `clamp(round(8192 + 8192 * 12 * log2(bend) / bend_range), 0, 16383)`; pressure and slide `round(value * 127)`.
- **CC out**, from the step: each slot whose source is not `off` and whose port has a device sends `cc(number, round(fraction(key) * 127), channel)` when the value differs from its last, at most 8 a step. A slot's settings changing, or its port's device arriving, sends it again at the next step. A slot following an LFO the engine runs shows ` ~` on IO: it sends Lua's model of it (decision 20).
- **Program change out**: with `midi_pc_out` on, each recall sends `program_change(scene - 1, midi_pc_out_channel)` on `midi_pc_out_port` (a fade tells the hook at its first step).
- **Cleanup** (143, after the targets' 142 sent every off): `stop()` drops the express queue and the module sends nothing more.

## IO

- The target's `rows(voice)`: one `detail` row `midi` in the `voice` section (text `off`, `port 2  ch 3` or `port 2  mpe 15`; fields port, channel, mode, members).
- The section `midi` (title `midi out`): a `param` row `bend range`; eight `detail` rows `cc 1` to `cc 8` (text `off` or `lfo1  p2 ch3 #20`, fields source, port, channel, number); five `param` rows `pc in`, `pc channel`, `pc out`, `pc out port`, `pc out channel`. Status `[--]` when a port some setting sends on has no device. Layout states: `without its device`, `with its device` (each with an MPE voice, a plain voice, a slot and program change out set) and `a detail list open` (`cc 1`'s).
