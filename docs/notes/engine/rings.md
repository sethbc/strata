## Must not break

- **Ring writers** (`\strataRingWrite`) are one per voice, reading `granBuses[i]`, and one reading `inputBus`.
- **Writers run last in `voiceGroup`** (after the voice, input and record synths), so a voice writer records only its voice synth: the stage writes the voice bus later, in `processGroup`. They are persistent (started in the rings area's `start`, never released) and their keys (`ringWrite0`..`ringWrite6`, `ringWriteInput`) are `effectKeys`, so they get plain messages.
- **A writer's input goes through `zeroBadValues`** before its `BufWr`s: a voice that blows up never writes NaN into a ring that frozen or later grains replay.
- **Rings only ever append.** Any other write into a voice ring (3.2's freeze copy) fades the voice's ring readers first (`ringLevel 0`, waiting `bufferFadeWait` when one plays) and runs only if `ringChanges[voice]` is unchanged, as `slotChanges` guards the slots.
- **`ringReaders`** holds every `\strataGrainRing` with its voice until it frees (set in `startGrainSynth`, cleared in `watchVoiceSynth`'s `onFree`).
- **The lookback bound.** Ring rates are clipped to ±`ringMaxRate` (4) and grains are at most `grainMaxSeconds` (0.5 s), so no grain reads further back than margin + history + spread + 2.5 s: inside a 4 s voice ring, and inside the input ring's `ringGuardSeconds` (4) + 1 s past `historySeconds`. A ring grain reads behind the write head by margin + history + spread + max(r − 1, 0) × dur, so it never overtakes the head and never reads past the ring.
- **The head is read sample by sample.** `ringGrainReader` starts every grain the lookback and one block behind the head, wherever in a block its trigger falls: grains at one rate must read one distance back, or overlapping grains comb each other (a head latched or `K2A`'d per block starts them up to a block apart: 3 to 6 dB lower, with a tremolo). In the block where the head wraps, the ramp of the head would sweep back through the ring; there the shifted head (counted from half a ring back) is read instead (#307).
- **Bufnums never change.** The rings are allocated once in `allocState` (not in the real-time pool) and freed in `free`.

## The rings

The rings area (`lib/engine/StrataRings.sc`, order 70) gives every synth- and input-sourced grain synth a buffer to read, so all three sources share one grain path (`\strataGrainRing`, `\strataGrainBuf`: `docs/notes/engine/grains.md`).

`areaState[\rings]`:

| Key | What |
|-----|------|
| `\voiceL`, `\voiceR` | Arrays of `numVoices` mono buffers, `ringSeconds` (4 s) at the server rate: each voice's ring |
| `\inputL`, `\inputR` | the input ring, `historySeconds + ringGuardSeconds + 1` s (16 + 4 + 1 = 21 s standard, 65 s high) |
| `\phaseBuses` | `numVoices + 1` control buses, each writer's frame position (the last is the input's) |
| `\writers` | the `numVoices + 1` `\strataRingWrite` synths, voices first |
| `\readers` | `ringReaders`: `\strataGrainRing` synth → voice |
| `\changes` | `ringChanges`: per voice, a count a source switch (here) and freeze/unfreeze (the freeze area) bump |

RAM (ordinary, not the real-time pool): 7 × 2 × 4 s × 192 KB/s = 10.8 MB of voice rings and 8.1 MB of input ring on standard (25 MB on high).

Methods: `ringSeconds` (4), `ringGuardSeconds` (4), `ringReadMargin` (0.005 s), `ringSpreadSeconds` (0.5 s), `ringMaxRate` (4), `ringWriterKeys`, `ringReaders`, `ringChanges`, `ringBuffersFor(voice, source)` → `[left buffer, right buffer, phase bus]` (the voice's ring for source 0, the input ring for `inputSource`, nil for a slot).

### Writers

`\strataRingWrite` (`in`, `bufL`, `bufR`, `phaseOut`): a `Phasor.ar` over the ring's frames drives two `BufWr`s and reports its position with `Out.kr(phaseOut, A2K.kr(phase))`. The `Phasor` starts from the frame on `phaseOut` (an `Impulse.ar(0)` reset to `In.kr(phaseOut)`), so a writer that replaces another (3.2's spectral freeze, `Synth.replace`) carries on where it was; the phase buses start at 0. One writer per voice reads `granBuses[i]`, and the input writer reads `inputBus`. They start at the tail of `voiceGroup` in the rings area's `start` (after the voices area's groups and the buffers area's input synth), stop in its `stop` (before the voices area frees the groups) and the rings and phase buses are freed in its `free`.

`In.ar` reads a bus not yet written in this cycle as silence, so a voice writer, running before `processGroup`, never records the mirror its stage writes: returning to the synth source never re-grains a fading buffer voice's mirror, with no gating.

### Where a ring grain starts

`ringGrainReader` (in `lib/engine/StrataGrainDefs.sc`) reads the write head from the phase bus (`In.kr`, the frame the writer reported at the start of the block) and starts each grain a lookback `D` behind it, at the rate `r` (clipped to ±4) and duration `dur` that `grainBody` passed:

```
continuous: D = margin + history + spread + max(r - 1, 0) * dur
triggered:  dur' = min(dur, dur / (r - 1)),  D = margin + history + max(r - 1, 0) * dur'
```

- `margin` is `ringReadMargin`. The head on the phase bus is the writer's frame at the start of the block; the audio-rate subtraction reads it as a ramp from the last block's value to this one's, which is the true head sample by sample, one block late. So every grain starts exactly `D` and one block (1.3 ms at 48 kHz) behind the head, wherever in the block its trigger falls, and grains at one rate stay in phase. In the block where the head wraps (it reads under a block) that ramp would run back through the whole ring and start a grain up to a ring back; there the reader takes the head counted from half a ring back (`shifted = head - frames × (head >= frames / 2)`, which steps where the head crosses the half and runs on across the wrap), selected for that block only, so its grains start where their neighbors do.
- `history` (seconds, clipped to `historySeconds`) is the input voices' history (`lib/history.lua`). The grains area's `history` handler stores it for every voice but sends it only to an input voice's grain synth, and `grainControlPairs` gives a synth-source grain synth `history 0`: its voice ring holds 4 s.
- `spread` is a per-grain draw of 0 to `posSpread × ringSpreadSeconds`, backward only (forward of the head is the future). It is 0 in triggered mode, as 3.1's position spread did nothing there for synth and input voices.
- Triggered grains above rate 2 are shortened, so their lookback is never more than one grain (plus margin and history): rate 4 and 0.5 s grains last 0.167 s and start 0.505 s back, where a continuous grain keeps its 0.5 s and starts 1.505 s back.
- Reverse grains (negative rates, from 3.2's variation area) need no lookback: they read older audio.
- `ringScanOffset(bufScan, freeze)` (the freeze area's hook, in `lib/engine/StrataFreeze.sc`) adds seconds to the lookback: neutral 0, so an unfrozen ring ignores `bufScan`. 3.2's synth hold uses it to move the read point back through the paused ring, which holds valid audio all round (its reads wrap).
- `GrainBuf` wraps: a grain crossing the ring's end continues from frame 0 (and a reverse one crossing frame 0 continues from the end), so the ring needs no special case.

## The engine check (`test/engine_check/rings.scd`)

Most of it reads a timecode: a check synth writes the seconds since it started (left) and 1 (right) into voice 1's bus and the input bus, and the same seconds to a private bus. A grain synth with a rectangular envelope (`envBuf`) and no pan wander or spread then plays left/right = the time its audio was written, so "now minus that" is how far back it reads, sample by sample, whatever its level. It checks:
- the area's state, sizes and constants; `ringBuffersFor`;
- one writer per voice plus the input writer at the tail of `voiceGroup` (with a voice and a recording running), each reading its bus into its ring, their keys among `effectKeys`;
- a writer starts from the frame on its phase bus;
- a NaN input writes zeros (the ring stays finite);
- `GrainBuf` wraps forward across a buffer end and backward across frame 0 (on CI's SuperCollider 3.13, the recheck §2.1 of the design asked for);
- no `PitchShift`, `DelayC` or other delay line in either grain SynthDef; `\strataGrainRing` runs two stereo `GrainBuf`s;
- pitch is the rate: on the timecode, `pitchShift` 0.5, 1 and 2 read at rates 0.5, 1 and 2 (how far each grain's read moves from 10 ms into the grain, over the time since, within 0.2%); on a 440 Hz sine they play 220, 440 and 880 Hz (`Pitch`, a sanity check within 2.5%: a semitone is 5.9%); a synth voice's bend (2, on an FM voice at index 0) is applied once (880 Hz within 2.5%, not 1760);
- at rate 4 and 0.5 s grains no grain reads ahead of the write head; a continuous grain keeps its 0.5 s length; a triggered one lasts 0.167 s and starts at most 0.505 s back (plus a block);
- grains crossing the ring's end read on without a jump or a gap (rate 1, grains back to back for longer than the ring);
- across the head's wrap: `ringGrainReader` alone (a check-only def, a trigger every 63 samples, so one in every block at each offset in turn) starts every grain the lookback and one block behind the head (within 0.05 ms) on voice 1's ring at rate 1 and at rate 4 with 0.5 s grains and on the input ring, over a lap of the input ring; the real def's 4 ms grains at 187.3 a second never read more than 10 ms back on either ring; and grains at rate 1 with no spread give a 750 Hz sine in the ring back at its level (left rms 0.25 within 2%, a 2 ms envelope never under 0.19), which a head held for the block would comb;
- history never reaches a synth-sourced voice's grain synth; history 2 on an input voice reads from 2 s back (plus the margin and a block); `bufScan` reaches the ring grain synth but, with the neutral `ringScanOffset`, moves nothing;
- `free` frees a second engine's writers, rings and phase buses.
