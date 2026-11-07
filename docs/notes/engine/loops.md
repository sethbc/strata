## Must not break

- **No grain reads past the valid region**, whatever the loop: a forward grain starts in `[0, validFrames - grainEndMargin - durFrames]`, a reverse one (rate < 0) in `[durFrames, validFrames - grainEndMargin]`, so a reverse grain never crosses frame 0 and wraps into the zeroed rest of the slot. The loop is cut to those starts; it never shortens a grain (`slotGrainReader` still caps the duration at the region less `grainEndMargin`).
- **`loopStart` 0 and `loopLength` 1 give 3.1's starts** (the scanned position scaled to the forward starts), so old scenes and PSETs sound as before.
- **The loop is plain grain params.** `loopStart` and `loopLength` pass through `setGrainParam` into `grainControls`, so a replacement grain synth (a source switch) starts with them; the loop area registers no handler, state, def or command. The engine clips them (start 0-1, end at most 1) and never trusts Lua's pairing: a recall can send a length before the start that makes it fit.

## The loop area

`lib/engine/StrataLoop.sc` (area `loop`, order 100) holds one method, `slotGrainPos`, which `slotGrainReader` (`lib/engine/StrataGrainDefs.sc`) calls for every `\strataGrainBuf` grain. Lua's side (the params, the clamps, the scene fields) is in `docs/notes/lua/loops.md`.

`slotGrainPos(trig, bufPos, scanPhase, spreadDraw, rate, durFrames, validFrames, loopStart, loopLength)` returns the grain's start as a fraction of the valid region (`slotGrainReader` turns it into a fraction of the buffer):

```
start = loopStart + ((bufPos + scan + spreadDraw) wrap 0..1) × loopLength
```

in frames, inside the starts that keep the grain in the region:

| Grain | Lowest start | Highest start |
|-------|--------------|---------------|
| forward (`rate >= 0`) | 0 | `validFrames - grainEndMargin - durFrames` |
| reverse (`rate < 0`) | `durFrames` | `validFrames - grainEndMargin` |

The loop's first and last start (`loopStart × validFrames`, `(loopStart + loopLength) × validFrames`) are clipped to that range, the last never below the first, and the wrapped position moves between them. So:
- `bufPos`, the scan and the spread are fractions of the loop and wrap inside it (a scan of 1 crosses the loop once a second, whatever its length).
- A grain starts inside the loop and may play past its end (a reverse one past its start): short loops keep full-length grains.
- A loop with no room left for a grain (at the region's end, or shorter than a grain near it) starts every grain at the nearest start that fits, which may be before the loop. A region shorter than a grain gets grains as long as the region, from its start (reverse: from its end).
- The forward range always holds a start: `durFrames` is at most `validFrames - grainEndMargin`.

`rate` is the grain's signed rate (`grainRate`, which the variation area makes negative for reverse grains); `durFrames` the frames the grain reads (`grainDur × SampleRate × |rate| × BufRateScale`). The ring grains (`\strataGrainRing`) declare `loopStart` and `loopLength` too but never read them.

## The engine check

`test/engine_check/loops.scd`:
- A check-only def runs `slotGrainPos` alone (no buffer) and reports the lowest and highest start, the lowest and highest frame a grain reads, and the largest difference from 3.1's start, over the triggers since a reset. It checks the starts of a 0.25/0.25 loop, the wrap of `bufPos`, scan and spread inside the loop (`bufPos` 0.9 alone starts at 0.475), grains past a loop's end but inside the region, loops of 0.001 at either end of a region and in a region shorter than a grain (both rates), and 3.1's starts at loop 0/1 (within 1e-5 of the region).
- A voice on a slot whose frames outside the region under test hold 1 (the rest 0) must be silent: grains with a 0.25/0.25 loop over a slot with 1 before 0.25 (the whole region is heard first, as the control), and loops at the region's end or shorter than a grain over a slot with 1 past its region (rates 1 and 2).
- Reverse grains come from a check-only def built with `slotGrainReader` at rate -1 (the variation area's `reverseProb` is the real path): silent over a slot with 1 past its region at loops 0/0.001, 0/1, 0.5/0.25 and 0.999/0.001, while the same grains started by 3.1's rule are heard (the control: they cross frame 0), and so are the reverse grains over a slot of 1s.
- The loop controls reach a UGen, default to the whole region, reach a running grain synth and the one a source switch starts.
