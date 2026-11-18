## Must not break

- **One output ring per voice, written only by its writer**: `\strataOutRingWrite` (`outRingWrite0`..`outRingWrite6`, the area's `effectKeys`), persistent, at the tail of the record area's tap group, reading the voice's tap (`areaState[\record][\voiceTaps][v]`). Nothing else writes an output ring; a reader's freeze copies from it into the reader's own copy ring.
- **The tap comes before the dry level** (ruling 30, package 1a's stage): a voice at dry 0 and sends 0 still feeds its readers. The ring holds everything the voice sounds dry, after its grains, filter, level, gate and mute.
- **The writer zeroes bad values, then clips softly** (`this.zeroBadValues(channel).softclip` on each channel): linear to half scale, never at full scale, so a loop of voices reading each other (or a voice reading itself) holds at full scale. `softclip` of NaN is NaN, which is why `zeroBadValues` comes first.
- **The writer's phase is `ringWritePhase`** (#801): no `Phasor` reset by a trigger on its first sample, which SuperCollider 3.13 never sees. The writers start once, at the area's start (`resume` 0, from their phase buses' 0), and nothing replaces or restarts them; the check reads one block a block over a voice's start, its switches and its stop.
- **Rings only append, and no reader is told anything.** A stopped, gated or muted read voice writes silence, which its readers grain; a source switch, start or stop of either voice sends nothing to the other. `ringReaders` records the reading voice, not the ring it reads: nothing needs a ring's readers.
- **Bufnums never change**: the rings are allocated once (`allocState`, ordinary RAM: `outRingSeconds` at the server rate, 10.8 MB at 48 kHz for the seven pairs, `fixedBufferBytes`' term, [performance.md](performance.md)) and freed in the area's `free`.
- **Order 135**: the area starts after the record area (130), whose start makes the tap group, and stops before it (stops run in descending order), so its writers are freed before the record area frees the group.

## The out rings area

`lib/engine/StrataOutRings.sc` (3.8, package 1d, design §5). `areaState[\outRings]`:

| Key | What |
|-----|------|
| `\left`, `\right` | Arrays of `numVoices` mono buffers of `outRingSeconds` (4 s, the performance area's method) at the server rate: each voice's output ring |
| `\phaseBuses` | `numVoices` control buses, each writer's frame (zeroed at alloc) |
| `\writers` | the `numVoices` `\strataOutRingWrite` synths |

Methods: `outRingWriterKeys`, `outRingFor(voice)` → `[left buffer, right buffer, phase bus]`, `allocOutRings`, `addOutRingDefs` (adds the def, returns no names), `startOutRingWriters`, `stopOutRingWriters`, `freeOutRings`; each hook calls its method through `areaCall`.

`\strataOutRingWrite` (`in`, `bufL`, `bufR`, `phaseOut`, `resume` 0): `\strataRingWrite`'s graph (two `BufWr`s at `ringWritePhase`, the frame reported with `Out.kr(phaseOut, A2K.kr(phase))`), each channel through `zeroBadValues` and `softclip`. `resume` is there for a writer that would replace another (none does): the phase stays the rings area's one law.

## Voice sources

Sources `voiceSourceFirst` (`numBuffers + 2`, 10) to `voiceSourceFirst + numVoices - 1` (16) read voice `readVoiceOf(source)` (`source - voiceSourceFirst`)'s ring (`voiceSource(source)`, `validSource`'s upper bound; `StrataUtil.sc`). Lua's options 11-17 send 10-16. Such a voice is an input voice in all but its ring:
- `grainDefs` gives it `\strataGrainRing` (not a slot), `voicePathBus` the other path, `startGrainSynth` `rateLevel 1` and no slot pairs, `startPlacedGrainSynth` the head of its mix group: no voice synth.
- `ringBuffersFor(voice, source)` gives `outRingFor(readVoiceOf(source))` (`StrataRings.sc`), and `grainReadPairs` reads it at history 0, or the reader's copy ring while it is frozen with the copy in.
- **The read lag**: the writer runs in the tap group, after every reader in `processGroup`, so in each block a reader's `In.kr` of the phase bus holds the frame the writer wrote at the start of the block before: a grain starts `ringGrainReader`'s lookback, one block (its own) and one more block behind the tap, 2 × 64 frames + `ringReadMargin` (7.67 ms at 48 kHz), sample by sample, the head advancing one block a block.
- Its extra notes are `\input` notes (`noteKindFor`), pitched by their own `pitchShift` (`perNoteGrainControls`).
- The history grain param never reaches it (the grains area sends it to an input voice only), and the input channel (`inputChannel`, the rings area's handler) is ignored for it.

## A reader's freeze

The freeze area's copy family serves a voice source as it serves the input (`freezesByCopy(source)`; [freeze.md](freeze.md)): a hold copies the 4 s of the read voice's ring ending `ringReadMargin` behind its head (`ringHeadFrame` of the ring's phase bus) into the reader's copy ring, oldest first from frame 0, fading the copy ring's readers first; spectral (high tier) then starts a copy writer of the read voice's tap (`\strataRingWriteSpectral`, a new node, `resume` 0, at the tail of the tap group) into the copy ring from its end. An output ring is as long as the copy ring, so the copy always wraps the ring's end, and the copy's oldest few tens of milliseconds are audio written after the head was read (the time the copy took to reach the server): a seam 4 s back from the frozen read point, which the frozen grains, `grainMaxSeconds` back, only meet once a scan has carried them round. Freezing the read voice changes nothing for its readers (its frozen sound is what its tap carries). A type switch on a frozen reader is recorded at once: it has no voice synth, and `spectralHoldsVoice` is true only for a synth-source voice.

## Memory

The writer takes about 5 KB of the pool (seven: about 35 KB in every case), measured by the memory area beside the grain defs. The memory area's voice-source cases (3.8, package 1d, from the design's prototype): V2, every voice switched between three other voices' rings 0.2 s apart (21 `\strataGrainRing`, and on high seven spectral copy writers), and V4, V2 with the pool full, sixteen ring notes live and cutting; the figures are in [memory.md](memory.md).

## The engine check (`test/engine_check/outrings.scd`)

The area's state and sizes, `outRingFor`, `ringBuffersFor` and the voice source methods; the rings' bytes against `fixedBufferBytes`' term; seven writers at the tail of the tap group after `\strataTapPreMaster`, each reading its voice's tap, their keys effect keys; the writer's law on a check-only writer (0.25 passes, 2 writes 0.875, inf and NaN write 0 over every frame); the bufnums and writers unchanged and the writer's head stepping exactly one block a block (`\strataCheckOutHeadStep`, the freeze area's probe) over a voice's start, two switches and its stop; `setGrainSource` taking 16 and ignoring 17 and -1; a voice on the input (a tone) at dry 0 and sends 0 leaving the master's three buses below -90 dBFS while its reader plays within 0.5 dB of its level at dry 1; a muted and a stopped read voice silencing its reader with nothing sent to the reader; the read lag on a timecode added to a stopped voice's tap (two blocks and `ringReadMargin`, every grain within 0.05 ms); a self-read playing; a loop of two voices at level 2, size 0.5 and density 200 holding every ring sample at most 1 and finite after 5 s (0.9965 measured), the master's output finite and no stage replaced; an extra note on a voice source of kind `\input` with its own `pitchShift`. Then a reader's hold (with the read voice's writer paused, the copy ring equals the ring rotated to end the margin behind the head, sample for sample), the reader on its copy at history 0 and counted among its readers, the unfreeze's re-point and `freeze` 0 in one bundle, a refreeze fading the reader first and a switch inside the fade canceling the copy, the read voice's freeze leaving its reader's buffers as they were, a reader frozen over a stopped voice holding silence and, unfrozen 1 s after that voice's `voiceOn`, playing it again within 50 ms (3 ms measured); the input channel (1 the left ring twice, 2 the right, 0 both; on a frozen input voice the copy's left twice; kept across a switch away and back; rounded and clipped; ignored by a voice source; no grain def's control); and on a high engine, a reader's spectral copy writer in the tap group reading the read voice's tap, starting at the copy's end and stepping one block a block, freed at the unfreeze (its head then still) and at a switch, and a type switch on the frozen reader recorded at once with no voice synth.
