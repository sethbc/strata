## Must not break

- `recordBuffer` and `stopRecord` and every recording's state (`recordSynths`, `recordFrameBuses`, `stopReplies`, `areaState[\record][\takes]`) belong to the record area (`lib/engine/StrataRecord.sc`, `strataAreaRecord`, order 130). The record area's `stop` cancels every recording before any slot change or the input synth stops, then frees `\strataTapPreMaster` and the tap group; its `free` frees the head buses, the pre-master bus and the voice taps.
- **One record synth per slot, and it lives only in the tap group** (`areaState[\record][\tapGroup]`, added at the tail of `context.xg` in the record area's `start`, after the master): a new recording, load or clear frees the old one first, at once (`stopRecording`), including one still in its stop fade. Replace, never stack.
- **A playable recording never shrinks its slot and never zeroes it except through `afterSlotFade`.** A replace take fades, empties (`bufferFrames` 0, the voices fade) and zeroes as 3.2's did; a playable recording leaves a slot that holds audio untouched, and sets its length to `max(V, D)` only at its start (the arming reply). A playable recording into an empty slot zeroes it (fade first), because an empty slot may hold a canceled take. A slot at another sample rate is always a replace take: playing the old audio and the new at different pitches is the one thing a playable recording cannot do.
- **Every delayed step runs only if `slotChanges` is unchanged**: the synced preparation, the zeroing, the start, the length update, the stop's frame count, the peaks and the report. A later load, clear or recording always wins; `"record: rapid record, load, clear and stop leave at most one record synth and drop every late step"`.
- **`slotHeadGuard` (the head guard)** is a no-op when the head bus reads -1 (no recording), moves a buffer grain's start out of the zone the head would reach during the grain's life, and never leaves `slotGrainPos`'s valid range. A start past D is never moved. Its zone follows the grain's life in output frames (`L = durFrames / |r|`, `|r|` floored at 0.001), not the frames it reads. The head is sampled once per block (`Latch.ar` on a block-rate tick), never `K2A`'d: a wrap would otherwise sweep the zone across the whole slot during the block it wraps in.
- A recording's voice source reads the stage's tap (`voiceTaps[v]`, `docs/notes/engine/mix.md`), a pre-master one the tap synth's `masterSum`, a post-master one norns' output bus, all after the master in the tap group; the record synths write no bus they read.
- `slotHeadBus(index)` reads -1 and 0 while idle: the engine sets it back when the record synth frees (`recordSynthFreed`), and a record synth writes -1 and 0 itself until it arms.
- `recordState` reports: armed only when a delay or threshold holds it, recording at the arming reply, ended and kept once the peaks are written and the length reported, canceled from `stopRecording`; each carries its record number (`recordCounts`, counted at every `recordBuffer`), and Lua acts only on its newest recording's reports.

## Owns

`lib/engine/StrataRecord.sc`:
- `\strataTapPreMaster` (`areaState[\record][\tapGroup]`'s first node, key `\tapPreMaster`, in `effectKeys`; `Out.ar(preMasterBus, this.masterSum(...))`) and `\strataRecord`;
- `recordSlot(index, seconds, level, feedback, source, threshold, loop, delay)`, `prepareTake`, `startTake`, `takeArmed`, `recordSynthFreed`, `endTake`, `stopRecordSlot`, `stopRecording`, `slotRecording`, `cancelSlotRecording`, the `recordBuffer` (`"ifffifif"`) and `stopRecord` (`"i"`) commands;
- `areaState[\record]`: `\headBuses`, `\idleHead`, `\voiceTaps`, `\tapSink` (0a's), `\recordCounts`, `\statePoll`, plus `\preMasterBus`, `\tapGroup`, `\armReplies`, `\takes` (per slot, the recording in progress or waiting: an Event, or nil), `\peakWrites` (counters of `writeSlotPeaks` calls with and without an action, for the check), `\endSteps` (per slot, the order of the last end's steps, for the check), `\lastLateLine`;
- the constants `recordFadeSeconds` (0.005), `recordPrerollSeconds` (0.01), `recordGuardFrames` (5 ms plus one block), `recordPrepMargin` (0.15 s), `peakRefreshSeconds` (0.5).

## The record synth

Controls: `in, bufnumL, bufnumR, level=1, feedback=0, threshold=0, loop=0, frames, peakFrames, peakBuf, framesOut, headOut, gate=1, replyID`.

- Armed in its first block (threshold 0), or at the first block where `Amplitude.kr` of either channel (1 ms attack, 50 ms release) passes `threshold`; `armed` latches through a `SetResetFF`. While unarmed it writes nothing (`rec` 0) and the head bus reads -1.
- With a threshold the written signal is the source through a fixed 10 ms `DelayN` (`recordPrerollSeconds`): the take starts 10 ms before the crossing (the crossing lands at frame 480 at 48 kHz, up to a block and Amplitude's attack later). A `Select` keeps a take with no threshold sample-exact.
- `phase`, a `Phasor.ar` of rate `armed` over `[0, frames)`: stays at 0 until armed, then runs; in loop mode it wraps at `frames`.
- Writes `old × keep + new × rec`, with `keep = 1 - rec × (1 - feedback)` and `rec` a 5 ms linear ASR on `openedGate(gate) × armed × hold`: `hold` is `phase < frames - fade` (a one-shot's release starts per sample 5 ms before its end, so the take's fade ends on its last frame; loop keeps `hold` at 1). The result's first and last 5 ms differ from 3.2's take; everything between equals it to float rounding (`"record: a replace take without threshold or delay equals 3.2's except its first and last 5 ms"`). A one-shot shorter than its two fades is lengthened to 10 ms.
- The envelope frees the synth (`doneAction: 2`) when its release ends, at a stop or a one-shot's length.
- `framesOut`: the frames written before each block, a `Sweep.kr` from arming (never the head, which wraps when a stop's release runs past a one-shot's length), read with `/c_get` after the synth frees; sclang adds the last block, so the count includes the fade. A replace take's length is that count; a playable recording's stays `max(V, D)`.
- Gated off before it armed, it writes nothing (`rec` needs `armed`); `stopRecordSlot` frees it.
- `SendReply.kr(armed, '/strataRecord', 0, replyID)` on arming, which `takeArmed` matches against the take's node ID (another engine on the same server has its own).
- Peaks: one bin per `waveformPoints` of `peakFrames` (`head × points / peakFrames`), written in `peakBuf` every block while the head is in the bin: `min(1, old peak × feedback + new peak)`, with `old peak` latched as the head enters the bin (or in the synth's first block, for bin 0) and `new peak` the largest `|sample|` written since (both channels: the signal after the pre-roll, times the record level, so a threshold take's bins line up with its audio and nothing before arming counts). The bin it is in, partly written, is what a stop or a mid-take read shows. Nothing is written before arming. sclang reads the 64 values with `/b_getn` (`readSlotPeaks`, 1b).

## The recording path

`recordSlot` counts the command, cancels what was recording and picks the kind: replace (feedback 0 and loop 0, or the slot at another sample rate; the take's `feedback` and `loop` are then 0) or playable. It reports armed (only with a delay or threshold) and either prepares at once or, for a synced take, at `delay - (bufferFadeWait + recordPrepMargin)` through `SystemClock.sched` guarded by `slotChanges`.

`prepareTake`: a replace take reads 0 frames, its voices fade (`afterSlotFade`, `bufferChanged`), its buffers and its peak buffer are zeroed after the fade, then a sync. A playable recording into an empty slot does the same zeroing (no fade needed for the frames, but the same path), and a playable recording into a slot that holds audio starts at once.

`startTake` sends the synth. With a delay still to run (its timestamp `delay` after the command, `take[\startAt]`, is still ahead) it creates the node paused and a second bundle, `/n_run 1` timestamped, starts it: the server starts the record synth on the block the timestamp names, and a cancel can still free the paused node first (a timestamped `/s_new` could not be canceled before the node exists). Past the timestamp (a preparation that outlasted the delay) it starts at once and posts `strata: buffer <n> recording started <ms> ms late` (also kept in `areaState[\record][\lastLateLine]`, which the check reads).

At the arming reply (`takeArmed`) the take reports recording; a playable one sets the slot's length to `max(V, D)` (`bufferChanged`) and starts its peak refresh (every `peakRefreshSeconds`: `readSlotPeaks` then `writeSlotPeaks` with no action, so no `bufferState` report).

`stopRecordSlot`: a recording not sent to the server yet (still preparing) is canceled and keeps nothing (a synced replace take that had not prepared its slot runs the fade and the zeroing itself, once, so the slot ends up as if it had prepared). Any other (running, or paused until its timestamp: the server computes ahead of the clock by its latency, so one may have armed before sclang hears so), started or not as far as sclang knows, is gated off through `sendToSynth`: armed, it fades out over 5 ms and is kept. One not started is then checked after a sync: the server sends an arming reply before it answers a `/sync` that follows the gate, so one that has still not reported arming never armed before the gate, writes nothing gated off, and is canceled (`stopRecording`). So a stop that crosses the arming reply never cuts a fade-in short. A second stop during the fade is a no-op. The synth stays in `recordSynths` until it frees, and its frame count is read in `recordSynthFreed`.

`stopRecording` (a load, clear or newer recording) frees the synth at once and sets the head bus back to -1 after the free, so a retake waiting for its delay or level never leaves the grains steering around the old head.

`endTake`, once the frame count is known (replace) or at once: `readSlotPeaks`, `writeSlotPeaks(index, frames, ...)`, then a replace take's `bufferChanged` (its length), the `ended` report, and the scratch take (`writeSlot(index, scratchPath(index))`). A take stopped at F frames uses `ceil(64 × F / D)` of its peak bins. Every step checks the take is still the slot's and the slot unchanged.

## The tap group

Every record synth and `\strataTapPreMaster` run in the tap group, the last group of `context.xg`, so every source is written before it is read: the input (`\strataInput`, head of `voiceGroup`), a voice's tap (its stage, in `processGroup`), the pre-master bus (`\strataTapPreMaster`, its first node) and norns' output bus (`\strataMaster`). A record source outside 0-9 records the input.

## recordState

`recordStateValue(index, number, state)` gives one float: `((number * 4) + state) * numBuffers + index` (state 0 armed, 1 recording, 2 ended and kept, 3 canceled). `record_number` counts the slot's `recordBuffer` commands from 1.

## Tests

`test/engine_check/record.scd`: sources against a capture of the same bus from one timestamp; writing (peaks, a second pass, a loop's wrap, the fades, 3.2's take); arming (threshold, delay, both); playable recordings; the guard (no crossing at rates -4, -1, 0.5, 1 and 4; the zone's width; a no-op with no recording; a loop shorter than the zone); `recordState`; the end's order. See `docs/design/3.3-design.md` §1.
