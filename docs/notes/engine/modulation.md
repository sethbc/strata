## Must not break

- **Every channel of `fastModBus` comes from `fastModChannel(voice, noteSlot, destination)`**: `index + (voice × fastModNoteSlots + noteSlot) × numFastDestinations + destination`, through `fastModChannelFor` (which takes the slot count; the check runs it with six). `fastModBlock(voice, noteSlot)` is a block's first channel, and `fastModBlock(0, 0)` the bus's, which the whole-bus writers (the offset node, scatter) write from. No writer or reader computes a channel of its own, so 3.5's note slots change `fastModNoteSlots` and nothing else.
- **The buses hold offsets only, and Lua owns every base value**: the grain synths' and the stage's own controls hold what Lua sent; the engine adds the offsets inside the graphs (pitch, position and size in the grain synths, cutoff and amp in the stage) and never folds them into a control. With every channel at 0, `seqGate` 0 and `voiceMute` 0, each grain synth and the stage play 3.3's values within 1e-6 (the check compares them with check-only copies of 3.3's defs), and the mix area's equality checks against 3.2 pass unchanged.
- **The cutoff and the voice-level amp offsets belong to the stage** (`voiceMixMod`): the grain synths read all five channels in one `In.kr` but use only pitch, size and, in `\strataGrainBuf`, position; the cutoff and amp channels feed no grain UGen (the check reads both graphs). The amp offset follows the design's law: the other path's level is `(amp × (1 + modSig + m4) × (1 + accent)).clip(0, 2)`, the synth path's `(1 + m4).clip(0, 2)`, so −1 silences and +1 doubles a voice with no crossmod, and with crossmod running the offset adds to it inside the one clip.
- **One node per engine LFO, at most, at every moment, a releasing one included**: a command for a releasing LFO re-gates its node (the same shape) or frees it as its new node starts (a new shape); a running LFO's shape change is a `Synth.replace` (one server step). A released node is gone within its 20 ms release. When an LFO's node ends while its place still wants it running (its release ended just as `setFastLfo` re-gated it), it is started again, as `watchVoiceSynth` restarts a voice synth. Scatter is one node, re-gated the same way.
- **A channel is zeroed when its last writer ends**: a control bus keeps its last value, so an ended LFO's channel is set to 0 unless the LFO's newer node writes it, a moved LFO's old channel in the bundle that moves it, and every channel at scatter's end. The offset node writes every channel first in every block and the LFOs and scatter add (scsynth's first writer in a block overwrites a control bus, the others add), so the zeroing matters only for a channel no node writes.
- **Every message to an LFO or scatter node goes through `sendToSynth`** (they end on their own); the offset node, which never does, is an `effectKeys` node (`\fastOffsets`) and gets plain sets.
- **`fastModIn` is the engine's** (#458, one of `engineOwnedControls`): every grain synth starts with its voice's note slot 0 block (`grainControls`, set at alloc, so replacements and restarts read it too) and every stage with the same (`stageControls`); `setGrainParam` and `setVoiceParam` refuse the name. Its SynthDef default is `silentFastModBus` (5 channels, never written), never control bus 0 (norns' input follower) or `silentBus` (one channel).
- **`fastModGroup` is the first node of `context.xg`**, before `voiceGroup`, with the offset node at its head, so the offsets are written before every grain synth and stage that reads them in the same block. The structure check reads it.
- **The stage keeps its gate and mute values; Lua relies on it**: `seqGate`, `gateSeconds`, `gateRelease` and `voiceMute` are kept in `grainControls[voice]` (`setStageParam`), so a stage replaced in place (`replaceBadVoiceMix` starts it from `voiceMixArgs`) has them again, and a voice's stop, start or source switch never touches its stage. The sequencer sends `gateSeconds` only when it changes, caching the last value sent for the session, so a value the engine dropped would never come back; the check replaces a stage and restarts and switches its voice, then gates it with nothing resent.
- **The mirror stays outside the gate and the mute**: the stage's whole output (tap, dry, sends) is multiplied by `voiceGate`, the mirror (`other`) is not, so a gated or muted voice still modulates the others and a recording of it holds what is heard (design 3.4 §8.12, §8.14). `velocity` never reaches the gate's envelope (the velocity check, the stage included).
- **The five commands check their indices, then their values' finiteness**: an LFO outside 0..`numFastLfos` − 1, a voice outside 0..`numVoices` − 1, a destination outside 0..`numFastDestinations` − 1, a shape outside 0..`numFastLfoShapes` − 1, a note slot outside 0..`fastModNoteSlots` − 1, a mask past its bits, or a NaN or infinite continuous argument (a NaN passes `clip`) makes the command do nothing but post one `strata: ... ignored: ...` line. Only then are the continuous arguments clipped (rate 0.003-50, depth 0-1, offset −2..2, phase 0-1, scatter rate 0.01-1).
- **No def of the area has a `LocalBuf`, a delay line or a table**: all ten are control rate (`Delay1` and `HPZ1` keep one sample in the unit, no memory of their own).
- `numFastDestinations`, `fastModNoteSlots`, `numFastLfos` and `numFastLfoShapes` are literal `name { ^N }` methods: the Lua engine stub reads them for its range checks, and a docs test compares the first two with `S.constants.NUM_FAST_DESTINATIONS` (5) and `FAST_MOD_NOTE_SLOTS` (1). `fastModHalfRanges { ^[...] }` and `fastModCutoffFactor { ^N }` are literal too: a docs test compares them with the Lua specs (half of `grain_pitch`'s, `buf_pos`'s and `grain_size`'s ranges; the factor squared against `filter_freq`'s max over min, within 0.1 %).
- `grainParamHandlers` is written as a literal `grainParamHandlers: (...)` Event, so the Lua stub reads its keys (`seqGate`, `gateSeconds`, `gateRelease`, `voiceMute`), and `seqGate.round.clip(0, 1)` and `voiceMute.round.clip(0, 1)` are written on the controls' own names, so it reads them as enumerations 0-1.

## The modulation area (`StrataModulation.sc`, order 160)

3.4's fast modulation (`docs/design/3.4-design.md` §3): five destinations per voice take an engine-side offset, 0 pitch (the grain rate), 1 position (`bufPos`, buffer voices only), 2 size, 3 cutoff (the stage's voice filter) and 4 amp (the stage's level). The engine LFOs, scatter and the offset node (the matrix's, Lua-computed) write the offsets; the grain synths and the stage add them to what Lua sent. The stage's step gate and mute (§8.12, §8.14) are the area's too. Package 0c built the buses, the group, the addressing, the commands' checks and neutral hooks; package 1a the hooks' offsets, the ten SynthDefs, the nodes and the commands' behavior.

`areaState[\modulation]`:

| Key | What |
|---|---|
| `\fastModBus` | control bus of `numVoices × fastModNoteSlots × numFastDestinations` channels (35), zeroed at alloc |
| `\silentFastModBus` | control bus of `numFastDestinations` channels (5), zeroed at alloc and never written: `fastModIn`'s default |
| `\fastModGroup` | a group made in `start` with `Group.before(voiceGroup)`, at the head of `context.xg`: the offset node at its head, then the LFO and scatter nodes; freed in `stop` |
| `\lfos` | one place per engine LFO (`numFastLfos`, 6): nil, or an Event of its node (`\synth`), `\shape`, `\channel`, `\controls` (`out`, `rate`, `depth`, `offset`) and `\running` (false once released) |
| `\scatter` | scatter's place: nil, or an Event of its node, `\rate`, `\gains` and `\running` |
| `\nodeChannels` | each LFO node → the channel it writes, until it ends |
| `\offsetsIndex` | the control index of the offset node's `offsets` (`setFastOffset` sets one value by index) |
| `\stopped` | true until `start`, and from `stop`: commands do nothing, and no node's end restarts or zeroes anything |
| `\received` | per command, the arguments it last took (the continuous ones clipped), for the engine check |
| `\postIgnored` | nil: an ignored command posts its line; a function takes the line instead (the engine check counts them) |

`allocState` (after the mix area's, order 120) puts `\fastModIn` = `fastModBlock(v, 0)` into `grainControls[v]` and into `areaState[\mix][\stageControls][v]` for every voice. `start` makes `fastModGroup` and the offset node (`synths[\fastOffsets]`, an `effectKeys` node); `stop` forgets the places, removes the offset node's key and frees the group (every node in it); `free` frees both buses. Control buses take no real-time memory.

### The hooks

| Hook | Called from | Computes |
|---|---|---|
| `fastModRead(fastModIn)` | both grain defs, once, before their controls Event and reader (the result is the Event's `fastMod`), and `voiceMixMod` | `In.kr(fastModIn, numFastDestinations)`: the block's five offsets |
| `fastMod(controls)` | first line of `grainSignal`, before `grainRate`, `grainDur` and the readers see pitch and size | a copy of the Event with `pitchShift + 1.875 m0` clipped to 0.25-4 and `grainSize + 0.245 m2` clipped to 0.01-0.5 |
| `fastModPosition(bufPos, m)` | `\strataGrainBuf`, in place of `bufPos` given to `slotGrainReader` (so `slotScanPhase` and `slotHeadGuard` see it) | `(bufPos + 0.5 m1).clip(0, 1)` |
| `voiceMixMod(controls)` | the stage (`\strataVoiceMix`), before both filter banks and `voiceLevel` | declares `fastModIn`, `seqGate` (0), `gateSeconds` (0.1), `gateRelease` (0.1) and `voiceMute` (0); reads the block; sets `filterFreq × 31.62 ^ m3` clipped to 20-20000, `ampOffset` = m4 and `voiceGate` |

The half ranges are `fastModHalfRanges` (`[1.875, 0.5, 0.245]`, half of the Lua specs' ranges) and the cutoff's factor `fastModCutoffFactor` (31.62, so m = ±1 is half of 20-20000 Hz's ten octaves). The cutoff then passes `voiceFilter`'s 0.05 s lag, so a cutoff LFO's depth falls above about 20 Hz; the other four destinations are not smoothed by the graph. The ring reader still clips the rate to ±4 and `grainDur` still caps at 0.5 s, so the rings' lookback bound holds whatever the offset (`docs/notes/engine/rings.md`).

The stage's two level lines (`StrataMix.sc`, design 3.4 §0.3 and Question 40):

```
other = fo × voiceLevel(amp, modSig + ampOffset, accent)
sig   = (fs × voiceLevel(1, ampOffset, 0) + other) × voiceGate        (the mirror writes other)
```

### The gate and mute

`voiceGate = (1 − gate × (1 − env)) × (1 − mute.lag(0.02))`, with `gate = seqGate.round.clip(0, 1)` and `mute = voiceMute.round.clip(0, 1)`. `env` is `EnvGen.kr(Env([0, 1, 1, 0], [gateAttackSeconds, gateSeconds.clip(0.005, 120), gateRelease.clip(0.005, 4)]), t_trig)`: started by the stage's `t_trig` (the trigger `retrigger` already sends for the accent), held for `gateSeconds`, released over `gateRelease`, and restarted from its current level by a new trigger (EnvGen restarts a segment from where it is), so a retrigger in the release reopens the gate from its level. Its times are read as each segment starts (the hold at the end of the attack, the release at the end of the hold): Lua sends `gateSeconds` before the hit's `retrigger`.

**The attack is 5 ms in whole control blocks** (`gateAttackSeconds`: 4 blocks, 5.35 ms at 48 kHz). `EnvGen.kr` ends a segment on its whole blocks without reaching its level: a 5 ms attack is 3.75 blocks, ended at 0.8 after three, and the hold then climbed from 0.8 to 1 over `gateSeconds` (0.89 at 50 ms; measured with a tap on `voiceGate`). Rounded up to whole blocks plus a hundredth of one (so the float product never rounds a block down), the attack reaches 4/4.01 of the level and the hold the rest. The release, the last segment, ends at 0 (EnvGen's last level).

The four controls are the area's `grainParamHandlers`: `setStageParam` keeps each in `grainControls[voice]` (a replaced stage restarts with them) and sets it on the stage, never on a grain synth, as the mix area handles `filterFreq`. With `seqGate` 0 and `voiceMute` 0 the factor is exactly 1.

### The engine LFOs

Eight SynthDefs, built by one function, one per shape (`fastLfoShapeNames`: `\strataFastLfoSine`, `Tri`, `Square`, `Up`, `Down`, `Sah`, `Smooth`, `Drunk`; `fastLfoDefName(shape)`), all control rate. Controls: `out` (one channel), `rate` (Hz), `depth`, `offset` (half ranges), `t_sync`, `syncPhase`, `gate`. A `Phasor.kr` steps `rate × ControlDur` a block over 0-1 and `t_sync` resets it to `syncPhase`; `fastLfoShape` gives u (0-1) of the phase (design §2.2):

| Shape | u |
|---|---|
| sine | (sin 2πφ + 1) / 2 |
| tri | 1 − abs(2φ − 1) |
| square | φ < ½ |
| up / down | φ / 1 − φ |
| s&h | a `Dwhite(0, 1)` value drawn at the start and at each cycle start, held |
| smooth | from the last s&h value to the next, linear over the cycle |
| drunk | a `Dbrown(0, 1, 0.2)` walk (steps of ±0.2, reflected at 0 and 1), linear between, like smooth |

A cycle starts where the phase falls (`HPZ1.kr(phase) < 0`: a wrap, or a sync back) and at the node's start (`fastLfoDraws`; its first cycle runs from a value to itself). The output is `((2u − 1) × depth.lag(0.02) + offset) × env`, `env` an ASR of 20 ms attack and release through `openedGate(gate)` with `doneAction: 2`. smooth and drunk never jump by more than their per-block slope (at a wrap the step is at most the larger of the two cycles' slopes).

**Lifecycle** (`setFastLfo`, `stopFastLfo`, `syncFastLfo`): a place with no node gets one at the tail of `fastModGroup`; a running node is set (`out`, `rate`, `depth`, `offset`), or replaced with `Synth.replace` on a new shape (one server step); a releasing node is re-gated (`gate` 1 with the new values) or, on a new shape, freed quietly as its new node starts (a `Synth.replace` of a node that may have just ended would post FAILURE). A move (a new voice or destination) sets `out` and zeroes the old channel in the same bundle. `stopFastLfo` releases the node (20 ms) and leaves it in its place, not running; `syncFastLfo` sets `syncPhase` and `t_sync` on the place's node (a releasing one too). When a node ends (`fastLfoEnded`, its `onFree`): still its place's and running, it is started again; its place's and released, the place empties and its channel goes to 0; another's (replaced, or freed for a new node), its channel goes to 0 unless the LFO's node now writes it. A new node starts at phase 0: Lua resyncs after a start or a shape change.

### Scatter

`\strataScatter`: 35 `LFDNoise3.kr` at `rate × spread` (the spread, 0.8-1.2, drawn per channel when the def is built, so voices and destinations never move together), each times its entry of `gains` (35 values: depth on every channel whose voice and destination bits are set, `scatterGains`), through a 0.5 s ASR, in one `Out.kr` over the whole bus from `fastModBlock(0, 0)`. `setScatter` makes the node (its gains set in the same bundle) when depth rises above 0, sets `rate` and `gains` (re-gating a releasing node), and at depth 0 releases it, keeping its gains to fade from. Its end (`scatterEnded`) zeroes all 35 channels; an end while scatter should be running starts it again.

### The offset node

`\strataFastOffsets`, one node at the head of `fastModGroup` from `start` to `stop`: controls `offsets` (35 values, half ranges, default 0) and `lag` (0.05 s), `Out.kr(out, Lag.kr(offsets, lag))`. `setFastOffset(voice, noteSlot, destination, offset)` sets the value at `offsetsIndex + (fastModChannel(...) − fastModBlock(0, 0))` with `setSynth` (plain: an `effectKeys` node). Lua refreshes a destination at 24 Hz at the worst case, so the lag is at least 1/24 s.

### The commands

The rows of AGENTS.md's table:

| Command | Indices checked | Clipped | Does |
|---|---|---|---|
| `setFastLfo(lfo, voice, destination, shape, rate, depth, offset)` `"iiiifff"` | lfo 0-5, voice 0-6, destination 0-4, shape 0-7 | rate 0.003-50, depth 0-1, offset −2..2 | the LFO's node made, set, replaced or moved (above) |
| `stopFastLfo(lfo)` `"i"` | lfo 0-5 | | releases a running node |
| `syncFastLfo(lfo, phase)` `"if"` | lfo 0-5 | phase 0-1 | sets the phase of the place's node |
| `setScatter(depth, rate, destinations, voices)` `"ffii"` | destinations 0-31 (a bit per destination), voices 0-127 (a bit per voice) | depth 0-1, rate 0.01-1 | scatter's node made, set or released |
| `setFastOffset(voice, noteSlot, destination, offset)` `"iiif"` | voice 0-6, note slot 0..`fastModNoteSlots` − 1, destination 0-4 | offset −2..2 (after the finiteness check) | one value of the offset node |

An index that is not a whole number in its range, or a NaN or infinite continuous argument (each checked before any is clipped, `setFastOffset`'s offset included), makes the command do nothing but post one line (`strata: setFastLfo ignored: lfo 6 is not a whole number from 0 to 5`, `strata: setFastOffset ignored: offset nan is not a finite number`): nothing recorded, no node, no channel changed. Each command records what it took in `received`. The Lua engine stub refuses the same indices and the clipped ranges (Lua sends neither); for `setFastOffset` it checks only that the offset is finite, since Lua's matrix sends a sum the engine clamps (`docs/notes/lua/test-harness/engine-stub-and-sync.md`). `test/sync_check.lua`'s `PENDING_COMMANDS` holds each command until the Wave 1 package that calls it removes its name (1b the three LFO commands, 1e `setScatter`, 1h `setFastOffset`).

### Memory

Measured at package 1a (`docs/notes/engine/memory.md` has every figure): an LFO node 4.2-6.7 KB by shape (sine and tri 5.1, square, up and down 4.2, s&h 5.9, smooth and drunk 6.7), scatter 34.5 KB (the design estimated 18: its 35 noise generators, 35 rate products, 35 gain products and 35 envelope products are about 140 UGens), the offset node 11.0 KB; the stage 40.4 KB (41.3 in a full run in one sclang; 35.4 before; its check is 42 KB since 3.4), `\strataGrainRing` 59.0 KB and `\strataGrainBuf` 69.1 KB (58.1 and 67.4 before). With six engine LFOs and scatter on every voice and destination, the worst cases leave 150-170 KB less than before, against the design's estimate of 111 KB, and every floor holds (the tightest, high synth -> buffer -> synth, 536-556 KB above it).

### The check (`test/engine_check/modulation.scd`)

It runs in about 75 s, in a CI shard of its own (`.github/workflows/test.yml`): it builds an engine of its own (the area's `start` and `stop` on a second engine) and about thirty check-only SynthDefs. Its checks, in design §13's names:
- the area's order and state; `fastModChannel` against the formula for every voice, slot and destination (with one slot and, through `fastModChannelFor`, six: 210 distinct channels); the default `fastModIn` of the three defs;
- the offset node, one at the head of `fastModGroup`, the same node from the area's first check to its last, and on an engine of its own from its start to its free (which leaves no node, group or bus); `setFastOffset(2, 0, 0, 0.5)` reads 0.5 on its channel within 0.001 after 0.2 s, an offset of 7 reads 2, and an offset and an engine LFO on one channel add;
- the five signatures; each valid call recorded with its clipped arguments, no node made outside `fastModGroup`; every bad index and non-finite value ignored with one line, no channel changed; every channel at 0 and `fastModGroup` holding the offset node alone once LFOs and scatter end;
- one node per LFO through starts, shape changes, moves, sets and stops at 20 Hz for 2 s, starts and shape changes also sent in the tick of a stop (into the release). The bound is read twice a step. Right after the commands (the places' nodes taken then, the tree asked for in the same tick, with no sync between: a sync takes about 27 ms there, past the release), every LFO node on the server is its LFO's place's node, at most one per LFO, a releasing one included, and a releasing node must be seen at least once. 50 ms later, past the 20 ms release, each running LFO has exactly one node, of its shape and on its channel, and each stopped one none. None once all are stopped;
- two LFOs on one channel add; with the offset node paused (so only LFOs write), a stopped LFO's channel returns to 0 while another on it keeps writing, and a moved LFO zeroes its old channel;
- the shapes at fixed phases (rate 0.003 Hz), s&h's four draws in four wraps and nothing between, smooth's and drunk's largest step under their per-block slope, on the server (`\strataCheckKrTrack`); `syncFastLfo` sets the phase and makes no node without one;
- scatter's masks reach only their channels; its end zeroes its 35 channels (offset node paused);
- no `/fail` reply while LFO and scatter nodes release under messages; a re-gate in the release keeps the node; a node that ends on the server as it is re-gated starts again, and one given a new shape then has one new node;
- pitch on a synth voice (Folder at 330 Hz, its fold at 0.5 so its sine never folds, the median of 15 `Pitch` reads over about 1 s): an offset of +0.5 through the offset node and through an LFO multiplies it by 1.9375 within 0.03, the base within 1 % of the voice's pitch;
- taps on what the grain hooks compute (`\strataCheckFastTaps`) for four offsets, clips included; the real grain defs with position, size and pitch offsets play as copies at the moved controls (within 1 % of the level: a moved size differs in the last bit and can move a grain's end by a sample); with the cutoff and amp channels moved, both play exactly as with none, and in both graphs those two channels feed no UGen;
- taps on `voiceMixMod` (`\strataCheckStageTaps`): the cutoff moves by 31.62 ^ m and clips at 20 and 20000, the amp offset is m4; the real stage filters at the moved cutoff;
- the amp law: −1 silences and +1 doubles both paths with no crossmod or accent; with crossmod and an accent running, the synth path is silent or doubled and the other path equals 3.3's stage with its crossmod bus shifted by the offset over the amount, the clips at 0 and at 2 both met;
- with every bus at 0, each grain def and the stage equal check-only copies of 3.3.2's defs within 1e-6 (the stage with its filter, crossmod, accent and sends running);
- the gate on two check stages fed by one DC source (so the tap is the level times the gate): silent until a trigger, within 1 % of the ungated level 50 ms after one, half way down its release at 0.13 s, closed at 0.25 s, held past 0.25 s at `gateSeconds` 0.3; a trigger during the release reopens it from its level; the mirror not gated and the tap gated; a trigger at velocity 0.25 opens it fully; through the engine, a gated input voice's tap opens on `retrigger`, closes after the gate, and `voiceMute` silences it;
- the mute: `voiceMute` 1 silences the tap within 0.1 s ungated, gated open and gated closed (a trigger then opens nothing), 0 brings it back, and the mirror never differs from the unmuted stage's;
- the kept values: a stage replaced in place (a NaN on its `filterMix`), and its voice stopped and started and switched to its synth and back, each keep `gateSeconds` (0.3), `gateRelease` (0.05) and `voiceMute` (1) as last set with nothing resent; the mute keeps the replaced stage's tap silent, and the next `seqGate` 1 uses the kept `gateSeconds` (the tap open 0.22-0.28 s after a `retrigger`, where the 0.1 s default and its release close by 0.21 s, and closed by 0.4 s);
- every grain synth and stage reads its voice's block, through switches; `setGrainParam` and `setVoiceParam` refuse `fastModIn`; the four stage controls exist with their defaults, reach the stage and are kept, never a grain synth's;
- no def of the area has a `LocalBuf`, a delay line or a table, and the velocity check passes (no area def has a velocity control; in the stage, velocity feeds only an EnvGen's `levelScale`, never the gate's);
- what it leaves: every voice stopped on its synth source with the grain controls it found, every channel at 0, no LFO node.

The 3.3 copies (`\strataCheckGrainRing33`, `\strataCheckGrainBuf33`, `\strataCheckVoiceMix33`) are 3.3.2's text with `this.` written `engine.`; the helpers they call (the readers, `grainRate`, `voiceFilter`, `voiceOutput`, ...) are the engine's own, as the runner's 3.2 copies do. Timed comparisons run on the server: triggers, resets and latches go in timestamped bundles, and trackers latch a ratio or a step at set times after a reset, read with one `/c_getn` (#131).
