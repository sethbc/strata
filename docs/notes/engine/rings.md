## Must not break

- **Ring writers** (`\strataRingWrite`) are one per voice, reading `granBuses[i]`, and one reading `inputBus`.
- **Writers run last in `voiceGroup`** (after the input synth at its head and the voice synths; the record synths run in the tap group, after the master), so a voice writer records only its voice synth: the stage writes the voice bus later, in `processGroup` (the synth-source grain synths at its head, then each voice's mix group, its buffer and input grain synths at the group's head and its stage at the tail, just before that voice's mod synth). They are persistent (started in the rings area's `start`, never released) and their keys (`ringWrite0`..`ringWrite6`, `ringWriteInput`) are `effectKeys`, so they get plain messages.
- **A writer's input goes through `zeroBadValues`** before its `BufWr`s: a voice that blows up never writes NaN into a ring that frozen or later grains replay.
- **Rings only ever append.** Any other write into a voice ring (3.2's freeze copy) fades the voice's ring readers first (`ringLevel 0`, waiting `bufferFadeWait` when one plays) and runs only if `ringChanges[voice]` is unchanged, as `slotChanges` guards the slots.
- **`ringReaders`** holds every `\strataGrainRing` with its voice until it frees (set in `startGrainSynth`, cleared in `watchVoiceSynth`'s `onFree`).
- **The lookback bound.** Ring rates are clipped to ±`ringMaxRate` (4) and grains are at most `grainMaxSeconds` (0.5 s), so no grain reads further back than margin + history + spread + 2.5 s: inside a 4 s voice ring, and inside the input ring's `ringGuardSeconds` (4) + 1 s past `historySeconds`. A ring grain reads behind the write head by margin + history + spread + max(r − 1, 0) × dur, so it never overtakes the head and never reads past the ring.
- **The head is read sample by sample.** `ringGrainReader` starts every grain the lookback and one block behind the head, wherever in a block its trigger falls: grains at one rate must read one distance back, or overlapping grains comb each other (a head latched or `K2A`'d per block without the sample's offset starts them up to a block apart: 3 to 6 dB lower, with a tremolo). It holds the head, the ring's frames and the history for the block and adds the sample's offset only while the head advanced by one block (counted round the ring, so across its wrap: #307), so a head that did not (a paused writer, a frozen copy's, a reader just pointed at another ring) starts that block's grains at one point, the new ring's, never between the old read point and the new one (#535).
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

- `margin` is `ringReadMargin`. The head on the phase bus is the writer's frame at the start of the block. The reader holds it for the block (`Latch.ar` on a block-rate tick, as the head guard does), with the ring's frames and the history, and while the head advanced by exactly one block since the last block (`HPZ1.kr(head) × 2`, its step, taken modulo the ring's frames) adds the sample's offset in the block less one block: the start is `head - block + offset - D`, the true head sample by sample one block late, the same value 3.2's audio-rate subtraction gave in every ordinary block (its ramp of the block-rate head). So every grain starts exactly `D` and one block (1.3 ms at 48 kHz) behind the head, wherever in the block its trigger falls, and grains at one rate stay in phase. In the block where the head wraps the step counted round the ring is still one block, so its grains start where their neighbors do (3.2's ramp ran back through the whole ring there and started a grain up to a ring back, #307). A head that did not advance by a block gets no offset: a paused writer's or a frozen copy's (constant, as in 3.2) and a reader pointed at another ring, whose rings, phase bus and history change in one message (a freeze or an unfreeze of an input voice): that block's grains start at the new ring's head less `D`, never at a point swept between the two rings by ramps of the head, the frames and the history (#535). The start becomes a fraction of the ring by a division by the control-rate frame count in an ordinary block (bit for bit 3.2's: a steady control-rate divisor rounds in the last bit unlike an audio-rate one, which the mix area's verbatim comparison would show) and by the held frames in a block whose head did not advance (a control-rate count that changes ramps across the block).
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
- ring rates are clipped to 4: `pitchShift` 4 with an interval of +24 on a synth voice (rate 16 asked) and, with a bend of 2, on an input voice (32) reads at rate 4, never ahead of the head and never more than margin + 1.5 s (plus a block) back (#496);
- at rate 4 and 0.5 s grains no grain reads ahead of the write head; a continuous grain keeps its 0.5 s length; a triggered one lasts 0.167 s and starts at most 0.505 s back (plus a block);
- grains crossing the ring's end read on without a jump or a gap (rate 1, grains back to back for longer than the ring);
- across the head's wrap: `ringGrainReader` alone (a check-only def, a trigger every 63 samples, so one in every block at each offset in turn) starts every grain the lookback and one block behind the head (within 0.05 ms) on voice 1's ring at rate 1 and at rate 4 with 0.5 s grains and on the input ring, over a lap of the input ring; the real def's 4 ms grains at 187.3 a second never read more than 10 ms back on either ring; and grains at rate 1 with no spread give a 750 Hz sine in the ring back at its level (left rms 0.25 within 2%, a 2 ms envelope never under 0.19), which a head held for the block would comb; and a reader pointed between the input ring at history 2 and voice 1's ring at history 0, 40 times with a trigger in every block, starts every grain within a block of the old read point or the new one;
- history never reaches a synth-sourced voice's grain synth; history 2 on an input voice reads from 2 s back (plus the margin and a block); `bufScan` reaches the ring grain synth but, with the neutral `ringScanOffset`, moves nothing;
- `free` frees a second engine's writers, rings and phase buses.
