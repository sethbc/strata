## Must not break

- **No grain reads past the valid region**, whatever the loop: a forward grain starts in `[0, validFrames - grainEndMargin - durFrames]`, a reverse one (rate < 0) in `[durFrames, validFrames - grainEndMargin]`, so a reverse grain never crosses frame 0 and wraps into the zeroed rest of the slot. The loop is cut to those starts; it never shortens a grain (`slotGrainReader` still caps the duration at the region less `grainEndMargin`).
- **The bounds are the grain's own**: the range depends on the grain's direction and frames, which the variation area draws per grain at audio rate, so the loop's first and last start are clipped with `max` and `min` at audio rate, taken at the trigger's sample (where `GrainBuf` latches the grain). Never `.clip` there: on the control-rate `first × validFrames` it builds a `Clip.kr`, which reads the bounds once per block, the grain before's (#304; the engine check fails on a control-rate `Clip` with an audio-rate input in either grain SynthDef). No control-rate UGen may read `lowest`, `highest`, the rate or the frames of a grain.
- **`rate` is the read rate in slot frames per output frame** (`slotRate × BufRateScale.kr`, signed), never `GrainBuf`'s rate argument: the head guard sizes its zone from it (`docs/notes/engine/record.md`).
- **`loopStart` 0 and `loopLength` 1 give 3.1's starts** (the scanned position scaled to the forward starts), so old scenes and PSETs sound as before.
- **A note's region takes the loop's place, never trusted either** (3.7, design §3.4): while `regionLength` > 0, `regionStart` and `regionLength`, each clipped 0-1 (the end at most 1), are the span (`slotSpan`), cut to the legal starts with the same audio-rate `max` and `min`, and the head guard keeps the last word; `regionLength` 0 gives the loop's starts exactly (`"loops: regionLength 0 gives the loop's starts"`, within 1e-6 of `slotGrainPos` without the state). No grain of a region reads outside the valid region, nor outside the region on the side it reads, in any scan mode (`"loops: no grain of a region reads outside it or the valid region, in each scan mode, forward and reverse"`).
- **The loop is plain grain params.** `loopStart` and `loopLength` pass through `setGrainParam` into `grainControls`, so a replacement grain synth (a source switch) starts with them; the loop area registers no handler, state, def or command. The engine clips them (start 0-1, end at most 1) and never trusts Lua's pairing: a recall can send a length before the start that makes it fit.

## The loop area

`lib/engine/StrataLoop.sc` (area `loop`, order 100) holds one method, `slotGrainPos`, which `slotGrainReader` (`lib/engine/StrataGrainDefs.sc`) calls for every `\strataGrainBuf` grain. Lua's side (the params, the clamps, the scene fields) is in `docs/notes/lua/loops.md`.

`slotGrainPos(trig, bufPos, scanPhase, spreadDraw, rate, durFrames, validFrames, loopStart, loopLength, recHead, state)` returns the grain's start as a fraction of the valid region (`slotGrainReader` turns it into a fraction of the buffer). `state` is 3.7's scan state (`slotScanState`, `docs/notes/engine/positions.md`; nil, as the check-only callers pass ten arguments, for 3.6's starts): its `first` and `last` are the span, the region or the loop (`slotSpan(loopStart, loopLength, regionStart, regionLength)`: the region while `regionLength` > 0, through `Select.kr`, so the loop's values pass exactly), and its mode picks the position (`slotScanPosition`: wrap as below; bounce folds `bufPos` + the scan over the span, one shot clips it, the spread then added and clipped). In wrap:

```
start = loopStart + ((min(bufPos, lastLoopPosition) + scan + spreadDraw) wrap 0..1) × loopLength
```

in frames, inside the starts that keep the grain in the region:

| Grain | Lowest start | Highest start |
|-------|--------------|---------------|
| forward (`rate >= 0`) | 0 | `validFrames - grainEndMargin - durFrames` |
| reverse (`rate < 0`) | `durFrames` | `validFrames - grainEndMargin` |

The loop's first and last start (`loopStart × validFrames`, `(loopStart + loopLength) × validFrames`) are clipped to that range, the last never below the first, and the wrapped position moves between them. So:
- `bufPos`, the scan and the spread are fractions of the loop (or the region) and wrap inside it; the scan is a speed (3.7: a scan of 1 crosses the span in its own length, `slotScanSpeed`). `bufPos` itself is held under 1 (`lastLoopPosition`, 0.999999) before the scan and the spread are added, so `bufPos` 1 (the encoder's end stop, a bookmark at 1.000, an LFO clamped at the top) is the loop's last start, not its first (#363); every position below that is unchanged.
- A grain starts inside the loop and may play past its end (a reverse one past its start): short loops keep full-length grains.
- A loop with no room left for a grain (at the region's end, or shorter than a grain near it) starts every grain at the nearest start that fits, which may be before the loop. A region shorter than a grain gets grains as long as the region, from its start (reverse: from its end).
- The forward range always holds a start: `durFrames` is at most `validFrames - grainEndMargin`.
- The record area's head guard has the last word: `slotGrainPos` hands the frame, its range and `recHead` (the slot's head bus) to `slotHeadGuard`, which passes the frame through while no recording runs (the head reads -1) and, during a playable recording, moves a start the head would meet in the grain's life just behind the head, inside the same range (`docs/notes/engine/record.md`).

`rate` is the grain's signed read rate in slot frames per output frame (`grainRate`'s rate, which the variation area makes negative for reverse grains, × `bufRate` × the content's rate scale: `slotGrainReader`'s `frameRate`); `durFrames` the frames the grain reads (`grainDur × SampleRate × |rate|`). The ring grains (`\strataGrainRing`) declare `loopStart` and `loopLength` too but never read them.

## The engine check

`test/engine_check/loops.scd`:
- A check-only def runs `slotGrainPos` alone (no buffer) and reports the lowest and highest start, the lowest and highest frame a grain reads, and the largest difference from 3.1's start, over the triggers since a reset. It checks the starts of a 0.25/0.25 loop, the wrap of `bufPos`, scan and spread inside the loop (`bufPos` 0.9 alone starts at 0.475; `bufPos` 1 alone at the loop's last start, both rates), grains past a loop's end but inside the region, loops of 0.001 at either end of a region and in a region shorter than a grain (both rates), and 3.1's starts at loop 0/1 (within 1e-5 of the region).
- A second check-only def gives `slotGrainPos` a rate and frames that alternate per trigger (a `ToggleFF`: rate 1 then -1 at 9600 frames; 2400 then 19200 frames; rate 0.5 at 4800 then 2 at 19200): every grain reads inside the region. And no grain SynthDef holds a control-rate `Clip` with an audio-rate input.
- A voice on a slot whose frames outside the region under test hold 1 (the rest 0) must be silent: grains with a 0.25/0.25 loop over a slot with 1 before 0.25 (the whole region is heard first, as the control), and loops at the region's end or shorter than a grain over a slot with 1 past its region (rates 1 and 2).
- Grains with per-grain draws (`reverseProb` 0.5, `sizeJitter` 1, `pitchJitter` 12, each alone) on a 1 s region with 1 past it are silent, and heard over a slot of 1s.
- Reverse grains come from a check-only def built with `slotGrainReader` at rate -1 (the variation area's `reverseProb` is the real path): silent over a slot with 1 past its region at loops 0/0.001, 0/1, 0.5/0.25 and 0.999/0.001, while the same grains started by 3.1's rule are heard (the control: they cross frame 0), and so are the reverse grains over a slot of 1s.
- The loop controls reach a UGen, default to the whole region, reach a running grain synth and the one a source switch starts.
- 3.7's region: a check-only def (`\strataCheckRegionStarts`) runs `slotGrainPos` with the scan state beside it without: the region 0.5/0.25 over loop 0/1 holds every start in each mode at both rates, and `regionLength` 0 gives the stateless starts within 1e-6. With the real def, each of four regions (0/0.001, 0.999/0.001, 0.5/0.25 of a 1 s slot, 0.25/0.5 of a 0.05 s slot) in each mode (one shot held still, so its grains keep sounding) at rates 1, 2 and reverse is silent over a slot with 1 outside the span under test (the middle region's side its grains read; the valid region for the others), and the middle region's grains are heard in each mode over a slot of 1s.
