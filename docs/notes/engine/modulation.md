## Must not break

- **Every channel of `fastModBus` comes from `fastModChannel(voice, noteSlot, destination)`**: `index + (voice × fastModNoteSlots + noteSlot) × numFastDestinations + destination`, through `fastModChannelFor` (which takes the slot count; the check runs it with six). `fastModBlock(voice, noteSlot)` is a block's first channel. No writer or reader computes a channel of its own, so 3.5's note slots change `fastModNoteSlots` and nothing else.
- **The buses hold offsets only**: Lua owns every base value (the grain synths' and the stage's own controls, sent as ever). With every channel at 0 the engine plays exactly 3.3: the mix area's equality checks against 3.2 are the proof that the stage's two level lines are neutral, and they pass unchanged.
- **`fastModIn` is the engine's** (#458, one of `engineOwnedControls`): every grain synth starts with its voice's note slot 0 block (`grainControls`, set at alloc, so replacements and restarts read it too) and every stage with the same (`stageControls`); `setGrainParam` and `setVoiceParam` refuse the name. Its SynthDef default is `silentFastModBus` (5 channels, never written), never control bus 0 (norns' input follower) or `silentBus` (one channel).
- **`fastModGroup` is the first node of `context.xg`**, before `voiceGroup`, so whatever writes the offsets runs before every grain synth and stage that reads them in the same block. The structure check reads `xg`'s children in that order.
- **The five commands check their indices**: an LFO outside 0..`numFastLfos` − 1, a voice outside 0..`numVoices` − 1, a destination outside 0..`numFastDestinations` − 1, a shape outside 0..`numFastLfoShapes` − 1, a note slot outside 0..`fastModNoteSlots` − 1, a mask past its bits, or a non-finite `setFastOffset` offset is ignored with one `strata: ... ignored: ...` line. Their continuous arguments are clipped (rate 0.003-50, depth 0-1, offset −2..2, phase 0-1, scatter rate 0.01-1).
- **Until package 1a no command creates a node**: each records what it took (`received`) and nothing else; the four hooks stay neutral (`fastModRead` five zeros and no UGen, `fastMod` and `fastModPosition` their input, `voiceMixMod` the stage's controls with `ampOffset` 0 and `voiceGate` 1).
- **The mirror stays outside the gate factor**: the stage's whole output (tap, dry, sends) is multiplied by `voiceGate`, the mirror (`other`) is not, so a gated or muted buffer voice still modulates the others (design 3.4 §8.12, §8.14).
- `numFastDestinations`, `fastModNoteSlots`, `numFastLfos` and `numFastLfoShapes` are literal `name { ^N }` methods: the Lua engine stub reads them for its range checks, and a docs test compares the first two with `S.constants.NUM_FAST_DESTINATIONS` (5) and `FAST_MOD_NOTE_SLOTS` (1).
- `grainParamHandlers` is written as a literal `grainParamHandlers: (...)` Event, so the Lua stub reads its keys (`seqGate`, `gateSeconds`, `gateRelease`, `voiceMute`).
- **The check builds no engine and no SynthDef and loads no slot**: it runs last in a full run, where each raised sclang 3.13's crash rate (#131, #211; "The check" below).

## The modulation area (`StrataModulation.sc`, order 160)

3.4's fast modulation (`docs/design/3.4-design.md` §3): five destinations per voice take an engine-side offset, 0 pitch (the grain rate), 1 position (`bufPos`, buffer voices only), 2 size, 3 cutoff (the stage's voice filter) and 4 amp (the stage's level). Engine LFOs, scatter and the matrix's offset node write the offsets; the grain synths (pitch, position, size) and the stage (cutoff, amp) add them to what Lua sent. This file describes the area as 3.4's Wave 0 (package 0c) leaves it: the buses, the group, the addressing, the five commands as checked stubs and the neutral hooks, so the later packages build on fixed interfaces. Package 1a gives the commands their nodes and fills the hooks.

`areaState[\modulation]`:

| Key | What |
|---|---|
| `\fastModBus` | control bus of `numVoices × fastModNoteSlots × numFastDestinations` channels (35), zeroed at alloc |
| `\silentFastModBus` | control bus of `numFastDestinations` channels (5), zeroed at alloc and never written: `fastModIn`'s default |
| `\fastModGroup` | a group made in `start` with `Group.before(voiceGroup)`, at the head of `context.xg`; freed in `stop` |
| `\lfos` | one place per engine LFO (`numFastLfos`, 6) for its node; all nil in Wave 0 |
| `\scatter` | scatter's node; nil in Wave 0 |
| `\received` | per command, the arguments it last took (the continuous ones clipped), for the engine check |
| `\postIgnored` | nil: an ignored command posts its line; a function takes the line instead (the engine check counts them) |

`allocState` (after the mix area's, order 120) puts `\fastModIn` = `fastModBlock(v, 0)` into `grainControls[v]` and into `areaState[\mix][\stageControls][v]` for every voice. `free` frees both buses. Control buses take no real-time memory.

### The commands

The rows of AGENTS.md's table, as Wave 0 runs them:

| Command | Indices checked | Clipped | Wave 0 |
|---|---|---|---|
| `setFastLfo(lfo, voice, destination, shape, rate, depth, offset)` `"iiiifff"` | lfo 0-5, voice 0-6, destination 0-4, shape 0-7 | rate 0.003-50, depth 0-1, offset −2..2 | recorded |
| `stopFastLfo(lfo)` `"i"` | lfo 0-5 | | recorded |
| `syncFastLfo(lfo, phase)` `"if"` | lfo 0-5 | phase 0-1 | recorded |
| `setScatter(depth, rate, destinations, voices)` `"ffii"` | destinations 0-31 (a bit per destination), voices 0-127 (a bit per voice) | depth 0-1, rate 0.01-1 | recorded |
| `setFastOffset(voice, noteSlot, destination, offset)` `"iiif"` | voice 0-6, note slot 0..`fastModNoteSlots` − 1, destination 0-4; offset finite | offset −2..2 (after the finite check) | recorded |

An index that is not a whole number in its range, or a NaN or infinite offset, is ignored: one line (`strata: setFastLfo ignored: lfo 6 is not a whole number from 0 to 5`), nothing recorded, no node. The Lua engine stub refuses the same indices and the clipped ranges (Lua sends neither); for `setFastOffset` it checks only that the offset is finite, since Lua's matrix sends a sum the engine clamps (`docs/notes/lua/test-harness/engine-stub-and-sync.md`). `test/sync_check.lua`'s `PENDING_COMMANDS` holds the five until the Wave 1 package that calls each removes its name (1b the three LFO commands, 1e `setScatter`, 1h `setFastOffset`).

### The hooks

| Hook | Called from | Wave 0 |
|---|---|---|
| `fastModRead(fastModIn)` | both grain defs, once, before their controls Event and reader; the result is the Event's `fastMod` | `0 ! numFastDestinations`: no UGen |
| `fastMod(controls)` | first line of `grainSignal`, before `grainRate`, `grainDur` and the readers see pitch and size | `controls` |
| `fastModPosition(bufPos, m)` | `\strataGrainBuf`, in place of `bufPos` given to `slotGrainReader` (so `slotScanPhase` and `slotHeadGuard` see it) | `bufPos` |
| `voiceMixMod(controls)` | the stage (`\strataVoiceMix`), before both filter banks and `voiceLevel` | declares `fastModIn`, `seqGate` (0), `gateSeconds` (0.1), `gateRelease` (0.1) and `voiceMute` (0) as named controls and puts them in the Event, with `ampOffset` 0 and `voiceGate` 1 |

The stage's two level lines (`StrataMix.sc`, design 3.4 §0.3 and Question 40):

```
other = fo × voiceLevel(amp, modSig + ampOffset, accent)
sig   = (fs × voiceLevel(1, ampOffset, 0) + other) × voiceGate        (the mirror writes other)
```

With `ampOffset` 0 and `voiceGate` 1 (numbers, not UGens) both fold to 3.3's `other = fo × voiceLevel(amp, modSig, accent)` and `sig = fs + other`: sclang drops a `+ 0` and a `× 1` as it builds the graph, so the stage's UGens are 3.3's and only its five named controls are new (one Control UGen each): 35.4 KB a stage in full runs on 3.13.0 and 3.14.1, against 3.3.0's 34.5. The grain defs gain one each (`fastModIn`), under the probes' resolution: `\strataGrainRing` 57.3 KB and `\strataGrainBuf` 66.6 KB in the same runs (3.3.0's full runs: 58.1 and 67.4; the per-def probes resolve about 0.85 KB). The worst cases leave 0-20 KB less than at 3.3.0 (the high synth -> buffer -> synth case 4170 KB free, 586 KB above its floor).

### The gate and mute controls

`seqGate`, `gateSeconds`, `gateRelease` and `voiceMute` (design 3.4 §8.12 and §8.14) are the area's `grainParamHandlers`: `setStageParam` keeps each in `grainControls[voice]` (a replaced stage restarts with it) and sets it on the stage, never on a grain synth, as the mix area handles `filterFreq`. In Wave 0 no UGen reads them. The Lua stub takes every `grainParamHandlers` key as a `setGrainParam` name and checks no range for these continuous ones; package 1a makes `seqGate` and `voiceMute` enumerated 0-1 (their `.round.clip(0, 1)`).

### The check (`test/engine_check/modulation.scd`)

It checks the area's order and state, `fastModChannel` against the formula for every voice, slot and destination (with one slot and, through `fastModChannelFor`, six: 210 distinct channels), the five signatures, that no valid call changes the server's synth and group counts and that each records its clipped arguments, that every bad index and non-finite offset of Step 1's list (and the negatives) is ignored with one line, that all 35 channels and the silent bus's 5 read 0, that `fastModGroup` is `xg`'s first node and empty, that grain synths of every source kind (and their replacements after a switch) and all seven stages read their voice's block, that `setGrainParam` and `setVoiceParam` refuse `fastModIn`, that the four stage controls exist with their defaults, reach the stage and change nothing (a synth voice's tap equals its synth path and an input voice's tap its mirror within 1e-6, at each setting), and that the area's `stop` frees its group and its `free` both buses. It then waits 5.5 s, so every `awaitReply` timer it started has run out before the runner quits sclang (below), and runs in about 11 s.

The area runs last in a full run (about 940 s in), where building anything big ended sclang on SuperCollider 3.13: a second engine for the `free` check, in two of four runs (once the collector's count error, #211, once a segmentation fault, #131), h.engine's three defs built again for the default check, in two of four more (segmentation faults; on 3.14.1 the def write raised), and, with neither, in two of eight more (once in the gate check, which then loaded a slot, once as sclang quit), against none in eight runs of `main` beside them and none in eight of this branch with every area but this one. Without any of the three, two of eight runs still segfaulted as sclang quit, after every check had passed; with the 5.5 s wait at the end, the four runs of eight that reached the area all passed (the other four failed in the waveform and positions areas, before it), too few to call the pending timers the cause. CI runs the area in the `memory,modulation` shard, which passed eight of eight. So the area builds no engine and no SynthDef and loads no slot: the buffer voice of the fastModIn check reads an empty slot (its grain synth starts all the same) and the gate check's other-path voice is an input voice on the check's tone. `stop` and `free` run on a group and two buses swapped in for the check, h.engine's own put back afterward. The SynthDefs' default `fastModIn` is read from the global `SynthDescLib`, which holds the defs of the engine built last (another area's in a full run): the three defaults must be one bus and never control bus 0, and h.engine's silent bus when the descs are h.engine's, which their `tapOut` and `recHeadBus` defaults show (the area alone, or after the memory area, which builds the default engine last).
