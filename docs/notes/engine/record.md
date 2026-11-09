## Must not break

- `recordBuffer` and `stopRecord` and every recording's state (`recordSynths`, `recordFrameBuses`, `stopReplies`) belong to the record area (`lib/engine/StrataRecord.sc`, `strataAreaRecord`, order 130). The record area's `stop` cancels every recording before any slot change or the input synth stops (`alloc` and `free` run the areas in order: `stopBuffers` only drops what still waits for a fade).
- The `strataRecord` synth is 3.2's, unchanged: `"buffers: a take through the record area equals 3.2's sample for sample"` records the same input into two slots, one through the engine and one through the check's copy of 3.2's def (`h.def32[\record]`), and compares them on the server.
- `recHeadBus` of every `\strataGrainBuf` is its slot's head bus (`slotLengthPairs` carries it, `"structure: every buffer grain synth gets its slot's recHeadBus"`), never the default idle head. The ring def declares the control and ignores it.
- `slotHeadGuard` is called on the frame `slotGrainPos` chose, before dividing by `validFrames`. Neutral (the frame) until 1a. With the head bus at -1 it must stay a no-op.
- `areaState[\record][\voiceTaps]` is written only by the voice mix stage (0c, its `tapOut`), never a grain synth; `areaState[\record][\tapSink]` is that control's default (read when the stage's def is built, as `scaleBuffer`'s bufnum), so no tap ever writes audio bus 0.
- `recordState` is registered with `addPoll(\recordState, ..., false)` and never sent until the record package: `"record: the recordState poll exists and sends nothing"`.

## Owns

`lib/engine/StrataRecord.sc`:
- the `\strataRecord` def, `recordSlot(index, seconds, level, feedback, source, threshold, loop, delay)` (the last five ignored until 1a), `stopRecordSlot`, `stopRecording`, `slotRecording`, `cancelSlotRecording` and the `recordBuffer` (`"ifffifif"`) and `stopRecord` (`"i"`) commands, moved verbatim from `StrataBuffers.sc`;
- their state: `recordSynths`, `recordFrameBuses`, `stopReplies` (allocation only; the variables stay in `lib/Engine_Strata.sc`);
- `areaState[\record]`: `\headBuses` (one per slot, two control channels: the head frame and the record length D, -1 and 0 while idle), `\idleHead` (a head bus that always reads -1 and 0: the grain defs' `recHeadBus` default), `\voiceTaps` (`numVoices` stereo audio buses, filled by 0c's stage), `\tapSink` (a stereo bus the stage's `tapOut` defaults to), `\recordCounts` (per slot, 0: 1a counts the commands), `\statePoll`;
- the hooks 1a fills: `slotHeadGuard(frame, lowest, highest, rate, durFrames, recHead)` (neutral: `frame`), `recordStateValue(index, number, state)`, `slotHeadBus(index)`.

## recordState

`recordStateValue(index, number, state)` gives one float: `((number * 4) + state) * numBuffers + index` (state 0 armed, 1 recording, 2 ended and kept, 3 canceled). `record_number` counts the slot's `recordBuffer` commands from 1. Registered but never sent in 0a; 1a sends it.
