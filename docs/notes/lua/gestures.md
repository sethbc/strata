## Must not break

- **Control params only, hand edits only.** A recorder takes its events from the `param_touch` registry (encoders, arc rings, grid faders) and keeps only `params.tCONTROL` params; options, binaries, sources, scene recalls and transitions, LFOs (their sends are no touch), the drift, mutations and morph's writes never reach it. While `S.gesture_playing` is set the touch hook takes nothing, so no recorder records a playback, its own or another's.
- **One recorder takes events at a time.** Starting a recording ends another's recording (which then plays) and every overdub; turning overdub on does the same.
- **Playback is deferrable.** Every param a recorder plays is set with `params:set` inside `S.lib.engine_sync.deferrable(fn)`, with `S.gesture_playing` set, both put back even when the set raises. `fn` never yields: the quantized loop's sleeps and syncs are outside it. A hand edit is never deferred.
- **A quantized loop follows the clock.** Its coroutine (`S.gestures[k].clock`) starts the first pass on the next beat or bar (`clock.sync` of the unit) and each later one `length_beats` after it (`clock.sync(length_beats, phase - length_beats)`, the offset matron counts from the next multiple of the length, so a pass never skips one), and sleeps to each event from the beat it reads then (`clock.get_beat_sec()` re-read at each event), so it follows tempo changes and stays locked to Link and MIDI clock. A free loop plays on pattern_time's own metro.
- **A beat count that moves ends the pass.** A MIDI Start or PARAMETERS > CLOCK > reset sets the count back (and matron wakes every waiting sync at once): before each event the coroutine checks the count, and one more than `GESTURES.beat_tolerance` (1/4 beat) below the pass's start or past its end, or a pass-start sync that wakes that far off its beat, ends the pass; the loop then starts again on the next multiple of its length on the new count (phase 0): at once when the beat is within `beat_tolerance` of one (a transport start wakes the pass-start sync on its beat 0, so the next pass starts there, #624), else at the next one (`clock.sync(length_beats)`), within one loop length, never after the old count's worth of beats. Each pass's start is read from `clock.get_beats()` after its sync, rounded to the beat it should be.
- **A stop never cancels a recorder's clock whose resume may be posted** (#626, #870): norns delivers every resume matron posted, and one whose coroutine was canceled meanwhile makes `clock.resume` raise (maiden prints `bad argument #1 to 'resume'`), as when a bar-quantized scene recall, delivered first on the bar's tick, stops a bar loop whose pass starts on that bar, or a press ends a recording as its 10-minute clock wakes. Both clocks, the quantized loop's and the 10-minute one, are the clock helper's (`S.lib.clocks.run`, `docs/notes/lua/clocks.md`): every wait of their bodies is the handle's `sync` or `sleep` (the loop's handle is `S.gestures[k].run`, the 10-minute clock's `limit_run`), and every stop is `S.lib.clocks.stop`, which cancels a clock at once while its wait's end is farther off than the helper's margin (`CLOCKS.sleep_margin`, 0.1 s, before a sleep's wake; `CLOCKS.sync_tolerance`, 1/32 beat, before a sync's landing) and otherwise retires it, to end at its wake playing nothing (its wait says false), so a stop within 0.1 s of an event's sleep retires the loop's clock (before 3.9 the module's own margin was 10 ms); a stop from the clock's own body (an event's set, the 10-minute wake ending the recording) does neither, and its next wait says false. The loop also ends after the event it is playing once its run is gone. The module keeps no retired list of its own: the clocks a stop retired are the helper's (`S.lib.clocks.retired`), which its own cleanup step cancels.
- **A live file that could be neither read nor set aside is never written over** (scenes.data's rule, as the matrix's): the start step `gestures_load` marks the live file loaded only when it was read, missing or set aside; otherwise the recorders are not saved in the session (no timed write, nothing at cleanup), with one console line (`... the gestures will not be saved this session`). A PSET's side file is always written.
- **The live file follows what it stores** (#651): `GESTURES.save_delay` (0.1 s) after a recording with an event ends, an overdub ends (toggled off, a stop, another recorder's recording, the 1024-event cap), a recorder that held something is cleared, a recorder's quantize changes or a PSET loads, one write per burst carrying the recorders as they are then (`S.gesture_save_clock`, the helper's timed write), so a crash, a power cut or maiden's `;restart` loses at most that last 0.1 s. Playback, a stop that ends no overdub, a scene recall's play states and an overdub's own events (written when it ends) change nothing stored and write nothing. The cleanup step `gestures_save` cancels the timed write and writes at once; the cleanup step `gestures` after it (a recording it ends, as if it stopped at the save) starts no timed write.
- **A failed playback stops its recorder.** A played set that raises (a param action's error) never reaches the caller: `apply_event` returns it, and the recorder stops (state `stopped`, its metro or clock ended, `gesture_<k>_play` 0) with one `strata: gesture G<k> failed: <error>` line; the other recorders play on. A free loop checks after pattern_time's `start` and after each `next_event` (the metro's `event` is pattern_time's `next_event` and then the check, since `next_event` restarts the metro after the set), a quantized loop's coroutine ends itself. The invariant requires a playing recorder's metro to run (norns' `is_running`, the harness timer's `running`) or its clock's coroutine to be alive.
- **The play param follows the state.** `gesture_<k>_play` is 1 exactly while recorder k plays; every state change sets it silently. Its action (a scene recall) plays a stopped recorder or stops a playing one; one that cannot follow (empty, recording) puts the param back. It is hidden and kept out of PSETs (`set_save` false): a PSET's recorders load stopped from its side file.
- **The side files go through the module's `S.lib.side_files.new` files** (#648; `docs/notes/lua/data-files.md`, Side files: `name` and `contents` `gestures`, `key` `recorders`, `validate` each recorder's `record_problem`, `load` every recorder stopped, then the redraws), which reach the card through `S.lib.data_files` (`write` and `read`, an unusable one `set_aside`), never `tab.save` or `tab.load`. The PSET hook's `write` always writes, empty recorders included, so a PSET saved over never keeps an older side file; its `read` stops every recorder before it reads; a missing file loads empty recorders (a PSET from before 3.4 held none); a file it cannot use (unparsable, another version, a malformed recorder: a bad event or time, a quantized length that is no whole number of its unit, a free loop whose times do not sum to more than 0, whose metro would fire without a pause) is set aside with a console line and the recorders load empty, and the PSET still loads. An event whose id this build has no control param for is kept, saved again, and skipped when it plays. A recorder entry past `NUM_GESTURES` is ignored, not refused (the macros and the matrix refuse an out-of-range key and set the whole file aside), so a file from a later release with more recorders loads its first four and loses the rest at the next save here: whoever raises `NUM_GESTURES` meets this.
- **Bounds:** at most `GESTURES.max_events` (1024) events per recorder, a recording or an overdub included (`G<k> full` flashes in the header), and a recording stops 10 minutes (`GESTURES.max_seconds`) after its first event. Every recorder index is checked (1..`NUM_GESTURES`).
- The `gesture recorders` invariant (its Machines entry, below; a recorder's run and clock in step, its `limit_run` held exactly while it records an event or more, each a live handle of the clock helper, `S.lib.clocks.alive`, so never a stopped or retired one; the retired clocks themselves are the helper's `clocks` invariant's) and the cleanup step `gestures` (95), which cancels every recorder's clocks (`S.lib.clocks.cancel`) and stops every metro; the helper's step (190) cancels the clocks a stop retired.

## Machines

### gesture recorder
- **State:** `S.gestures[k].state` (`empty`, `recording`, `playing`, `stopped`), the one stored state, with `overdubbing` (only while playing; `S.lib.gestures.overdubbing(k)` reads it, and the grid core reads it there, #879), `run` and `clock` (a quantized loop's), `limit_run` (the 10-minute clock) and the pattern's `rec`, `play` and metro; `S.lib.gestures.state(k)` names it, and every writer of it is one of `press`, `clear`, `set_playing` (the play param's action), `finish_recording`, `fail`, `load_record` and `stop_all`.
- **Invariant:** `gesture recorders`: at most one recorder records; a recorder's clock or metro runs exactly while it plays, its run with it; its 10-minute clock runs exactly while it records an event or more; it overdubs only while it plays; it is empty exactly when it holds no event and does not record; its play param is 1 exactly while it plays; its clocks are live handles of the clock helper.
- **Test:** `test/unit/gestures_test.lua`: "gesture recorder: recording + the limit".

The table (3.9, #948) is recorder 1's, with a free loop of one reverb edit (on its metro); `playing, overdubbing` is the state beside `playing` the overdub (`overdub(k)`, ALT+K3) makes. The limit is the cap the recorder meets: the 10-minute clock's wake where it runs (a recording with an event), else hand edits to `GESTURES.max_events` (1024) and one more, which only an overdub records. A load is a PSET read whose side file holds one stopped loop for the recorder (its hook stops every recorder first, then loads); stop all is the cleanup step `gestures` (its clocks canceled, then `stop_all`), the other caller of that stop. Every cell is a row.

| State | Event | Next | Effect |
|---|---|---|---|
| empty | press | recording | the pattern records; no 10-minute clock before the first event |
| empty | clear | empty | nothing |
| empty | play param 1 | empty | the param goes back to 0 |
| empty | play param 0 | empty | nothing |
| empty | the limit | empty | the edits are not recorded |
| empty | a load | stopped | the file's loop, stopped |
| empty | stop all | empty | nothing |
| recording | press | playing | the loop plays from its first event; the 10-minute clock stops |
| recording | clear | empty | the recording is dropped; the 10-minute clock stops |
| recording | play param 1 | recording | the param goes back to 0 |
| recording | play param 0 | recording | the recording goes on |
| recording | the limit | playing | the 10-minute clock ends it: a loop of 600 s plays |
| recording | a load | stopped | the stop keeps the recording, stopped; the file's loop replaces it |
| recording | stop all | stopped | the recording is kept, stopped |
| playing | press | stopped | its metro or clock stops |
| playing | clear | empty | stopped and emptied |
| playing | play param 1 | playing | nothing |
| playing | play param 0 | stopped | a scene recall's stop |
| playing | the limit | playing | the edits are not recorded |
| playing | a load | stopped | the file's loop, stopped |
| playing | stop all | stopped | its metro or clock stops |
| stopped | press | playing | a free loop at once, its first event first; a quantized one from its next beat or bar |
| stopped | clear | empty | emptied |
| stopped | play param 1 | playing | a scene recall's play |
| stopped | play param 0 | stopped | nothing |
| stopped | the limit | stopped | the edits are not recorded |
| stopped | a load | stopped | the file's loop replaces it |
| stopped | stop all | stopped | nothing |
| playing, overdubbing | press | stopped | the stop ends the overdub, and the live file follows |
| playing, overdubbing | clear | empty | the overdub and the loop end |
| playing, overdubbing | play param 1 | playing, overdubbing | nothing |
| playing, overdubbing | play param 0 | stopped | the stop ends the overdub |
| playing, overdubbing | the limit | playing | the 1024th event fills the loop; the next edit ends the overdub and flashes `G1 full` |
| playing, overdubbing | a load | stopped | the stop ends the overdub; the file's loop replaces it |
| playing, overdubbing | stop all | stopped | the overdub ends with the playback |

## Owns

`lib/gestures.lua` (`S.lib.gestures`, 3.4, package 1f, design §7), included after `lib/mod_sources.lua`:
- `S.gestures[k]` for k in 1..`NUM_GESTURES` (4): `pattern` (a pattern of norns' `pattern_time` library, `require "pattern_time"`, made at include time: its `event` list and `count` always, its `time` list for a free loop), `state` (`empty`, `recording`, `playing`, `stopped`), `quantize` (`free`, `beat`, `bar`), and for a quantized loop `offsets` (each event's beats from the loop's start) and `length_beats`; `run` (the quantized loop's clock-helper handle while it plays) and `clock` (its id), `loop_start` and `next_index` (its pass), `length_seconds` (a free loop's), `loop_started_at`, `first_event_at`, `limit_run` (the 10-minute stop's clock-helper handle while it records; its id is `limit_run.id`) and `overdubbing`.
- `S.gesture_playing`: true while a playback sets a param.
- `S.gesture_save_clock`: the live file's timed write while it waits (#651).
- `press(k)`, `clear(k)`, `overdub(k)`, `state(k)`, `overdubbing(k)` (the field, false for a recorder out of range), `describe(k)`, `phase(k)`, `add_params()`, `GESTURES` (the tunables).
- The group `strata_gestures` (8 params), the scene fields `gesture_<k>_play`, the PSET hook `gestures`, the start step `gestures_load` (107), the cleanup steps `gestures_save` (34) and `gestures` (95), the modulation sources `gesture1`..`gesture4`.
- Its tests: `test/unit/gestures_test.lua`. The harness's pattern_time is `test/stub_pattern_time.lua` (`docs/notes/test-harness/stubs.md`).

## The keys

`press(k)` (MOD's K3 and the grids): empty → recording (from its first event: a silent lead-in is not part of the loop) → playing (a free loop at once, its first event first; a quantized loop from its next beat or bar) → stopped → playing. A recording with no event goes back to empty. `clear(k)` stops and empties it. `overdub(k)` toggles overdub on a playing recorder: a free loop through pattern_time's `set_overdub` (its `overdub_event` splits the gap the hand edit falls in), a quantized one by inserting the event into the beat list at `(clock.get_beats() - loop_start) mod length_beats`, kept sorted, and moving `next_index` past it so this pass does not play it again (an edit before the first pass starts is not taken). A bad index does nothing.

`describe(k)`: `empty`, `rec 3.2 s` (seconds since the first event, `rec 0.0 s` before it), `play 2.5 s` or `stop 2.5 s` (a free loop's length), `play 3 bars`, `play 1 bar`, `play 4 beats` (a quantized loop's); a loop that overdubs ends ` dub` (`play 2.5 s dub`, `play 2 bars dub`, #879), so a player on another page sees that every hand edit goes into it, and each end of the overdub (ALT+K3 again, a stop, another recorder's recording, the 1024-event cap) takes it away with its redraw (`changed(k)`).

## Quantization

- `gesture_<k>_quantize` (option `free`, `beat`, `bar`; default free). While it records the mode waits for the stop; then a beat or bar loop's length in beats (its seconds over `clock.get_beat_sec()` at the stop) rounds to the nearest whole beat or bar (at least one) and every event's offset scales by the same factor: at 120 BPM a 1.9 s recording (3.8 beats) is 4 beats under beat and under bar, a 5.1 s one (10.2 beats) is 12 under bar, and an event at 2.55 s (5.1 beats) lands on beat 6.
- Changing the mode of a recorded loop converts it the same way (free to beat or bar, beat to bar from its beats), or back to seconds at the current tempo (free); a playing loop keeps playing in its new mode.
- A hand edit of a param a loop plays holds until the loop's next event for that param.

## Storage

- A recorder's record: `{quantize, events = {{id, value}, ...}}` with `times` (a free loop's pattern_time gaps, seconds, the last to the loop's end) or `beats` (a quantized loop's offsets) and `length_beats`; an empty one is `{quantize}`. A recording is stored as if it stopped then. The file: `{version = 1, recorders = {...}}`.
- Per PSET: `<PSET path without .pset>.gestures.data`, written with every PSET save, read after every PSET load (every recorder stopped first, a recording kept stopped and then replaced), deleted with the PSET. The quantize params are PSET params too; the side file's quantize sets each recorder's param again, silently.
- Live: data/strata/gestures.data, read by the start step (stopped) and, once the start step read the file, found it missing or set it aside (as the scenes' #72; a file that could be neither is never written over, above), written `GESTURES.save_delay` (0.1 s) after the recorders change (#651, above) and at once by the cleanup step `gestures_save`, which cancels that write first.
- Scenes store only `gesture_<k>_play` (discrete scene fields, default 0, registered at include time): a recall's 1 plays a stopped recorder and does nothing to an empty one, its 0 stops a playing one; a recording is left alone.

## Sources

`gesture1`..`gesture4` (`S.register_mod_source`, section `gestures`, name `G<k>`, range 0..1): the loop's phase (a free loop's from the time its pass began, `loop_started_at`; a quantized one's from its pass's start beat), 0 while it does not play or before its first pass; `describe` is `describe(k)`. The row (MOD's, 2a): E3 steps the quantize (`enc_param_delta`), K3 presses, `alt_press(2)` (ALT+K2 held) clears, `alt_press(3)` (ALT+K3) toggles overdub; hints `K3:rec E3:quant` (`K3:play`, `K3:stop` by state), and under ALT `K3:dub` while it plays, `K3:dub off` while it overdubs (#879).
