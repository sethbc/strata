## Must not break

- **One door**: a voice's external notes start, end and are expressed only through `S.lib.io_targets`. No target is called by any other module: a target registers with `S.register_note_target` and waits for the core's calls.
- **An off goes to exactly the targets its on went to**, whatever is routed by then: each sounding note keeps the names of the targets whose `note_on` ran without raising (`sounding[voice][id].targets`), and its off goes to those names alone. A target whose `note_on` raised is not on the note and never gets its off.
- **Every note on gets its off.** A note ends at its gate (a step's), at its hook's `ended` (a played note's), when its id plays again (ended first), and at every stop: the voice's stop (`voice_stop`), a route change (`route_changed(voice)`, from every route param's action, so a PSET load too), the voice becoming silenced by a mute or a solo (`silence_change`), the step output's `stop` (the patterns stopped: its step notes) and cleanup (step 142, every note). Cleanup sends every off at once: the LFO clock has stopped at 120, so nothing waits for a step.
- **One list of offs**, checked from one `S.lib.lfos.on_step` hook against `clock.get_beats()`; no coroutine or clock per note. A note on for an id that sounds ends it first, which drops its pending off, so an off never lands after the note that replaced it.
- **A beat that goes back ends the offs at once**: a followed transport start (which runs no output's `stop`), a transport reset or a new clock source can put the beat back near 0. Each pending off keeps its note's start beat (`event.beat`), and the hook ends every off whose start is after the beat it reads now by more than `TARGETS.jump_tolerance`, within one LFO step; a note started after the jump keeps its own gate. The tolerance (1/32 beat) is the sequencer's `SEQ.wake_tolerance` (`lib/sequencer.lua`; a test keeps them equal, since the sequencer is included after this module): on a MIDI or crow clock matron extrapolates the beat between ticks and a late tick pulls it back a few ms, which the sequencer absorbs the same way. Without it, such a pull-back read at the next step would cut a step note to about 20 ms.
- **A silenced voice starts no target note** (`S.lib.voice_mix.silenced`); `available(voice)` is false for it, and its sounding notes end as it becomes silenced.
- **Every call to a target is contained** (`S.lib.ui_frame.contained_call`): one that raises prints `strata: target <name> failed:` with its traceback once, and is skipped for starting and expressing notes (`routed`, `note_on`, `express`) until the step output's `stop` or a `route_changed` of any voice clears the failures. A failed target still gets the `note_off` of every note it started (contained: one that raises never stops the other targets' offs), and `stop_all` at cleanup is called on every target, failed or not: a hung note outranks the skip.
- **Hooks and targets never yield** and never call `S.lib.notes.play`: the core runs inside the note hooks, the step output's coroutine and the LFO step.
- **The ids**: `"s" .. k` for a step's k-th pitch (`event.pitches`, which already carry the step's pitch lock: played as given), `"m" .. key` for a played note of owner `midi`. A note of any other owner (the sequencer's `seq` notes) is ignored by the hook: the step output carries them, with their gates.
- **The `targets` step output plays after `voices`**: it is registered at the start step `io_targets` (161), after the sequencer's include registered `voices`.

## Owns

- `lib/io/targets.lua` (`S.lib.io_targets`): `TARGETS` (`order`, `zero_volt_note` 60, `notes_per_volt` 12, and the ids' prefixes and the played owner), `volts(pitch)`, `route_changed(voice)`, `end_target(name)`, `stop_all()`, `sounding(voice)`.
- The step output `targets`, the note hook `targets`, an LFO step hook, a voice-stop hook, a silence hook, IO's `voice` section, the start step `io_targets` (161), the cleanup step `io_targets` (142) and the invariant `targets`.
- Its unit tests: `test/unit/io_targets_test.lua`.

## A target

`S.register_note_target({name, routed, note_on, note_off, express, stop_all, rows, status})`, the first four required:
- `routed(voice)`: true when the voice plays the target now. The target's route params call `S.lib.io_targets.route_changed(voice)` from their actions.
- `note_on(voice, id, pitch, velocity, info)`: `pitch` a fractional MIDI note, `velocity` 0 to 1, `info` `{source = "step"}` or `{source = "midi", owner = "midi", key}`. `S.lib.io_targets.volts(pitch)` is `(pitch - 60) / 12`, the one conversion for every target that takes volts; each target clamps to its device's range.
- `note_off(voice, id)`; `express(voice, id)` (optional: a played note's expression changed; read it with `S.lib.expression.raw(voice, info.owner, info.key)`); `stop_all()` (optional: at cleanup, after every off).
- `rows(voice)` and `status(voice)` (optional): the rows the target adds to IO's `voice` section for the selected voice, and a mark for its title row.
- `layout_states` (optional): a list of `{name, setup = fn(context)}`, checked as an IO section's, for the looks of the target's rows. The IO page lists them as the `voice` section's, after its own (`docs/notes/lua/pages/io.md`); a target never edits another module's record.

## How it works

- `sounding[voice][id] = {pitch, targets = {name, ...}, off_beat}`; `offs` is the list of pending offs, each naming the record it ends. `sounding(voice)` returns a copy.
- **Steps**: `available(voice)` is true when the voice is not silenced and some target's `routed(voice)` is. `play(event)` starts, for each `k, pitch` of `event.pitches`, the note `"s" .. k` on every routed target with `event.velocity` and its off at `event.beat + event.gate_beats`. `stop` clears the failures and ends every voice's `s` notes.
- **Played notes**: the hook's `started` and `moved` start `"m" .. key` (a sounding one ended first, so a move is an off then an on at the new pitch); `ended` ends it; `expressed` calls `express(voice, id)` on the note's targets that have one.
- **`end_target(name)`**: that target's off for every sounding note that names it, its name dropped from them (a note left on no target is forgotten).
- **`stop_all()`**: every note ended (each voice, in id order), then each registered target's `stop_all`.
- **Order of targets**: `TARGETS.order` (`midi`, `crow`, `jf`, `wsyn`, `er301`, `txo`, `nb`), then any other name in registration order: the order of note ons and of IO's rows.

## IO's voice section

Titled `voice <n>` for the selected voice (ALT+E2 on IO selects it). Its rows are each target's `rows(voice)`, in the targets' order; its status the targets' non-nil `status(voice)` texts joined by a space, drawn at the right of the title. A target's `rows` or `status` that raises is contained (one console line per new message) and left out. With no target registered the section is its title alone. Its layout states, `a target's status` and `a target's rows`, both register (through one local function) a target named `layout probe`: once per script, never routed, with an action row labeled `layout probe` that does nothing, a status row and the mark `[!]`. `a target's status` leaves the section at its top, so the title shows the mark (a real look: nb's target gives one). The probe sorts after the real targets, so `a target's rows` reaches its row as a player does (`S.lib.pages_io.go_to_row`, by its id `probe`) and raises, naming the module and the row, when it is not there. Neither state takes another module's target out of the registry.
