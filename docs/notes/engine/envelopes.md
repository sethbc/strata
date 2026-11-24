## Must not break

- **Two commands, exactly**, with these signatures: `setFastEnv(route, source, voice, destination, depth, attack, decay, sustain, release, curve, loop)` `"iiiiffffffi"` and `stopFastEnv(route)` `"i"` (design 3.7 §7.3). Only `S.lib.envelopes` calls them (package 2f); until it lands both are in `test/sync_check.lua`'s `PENDING_COMMANDS`.
- **Each command checks before it acts**, through the modulation area's `fastModIndicesValid` and `fastModValuesFinite`: its indices first (route 0..`numEnvRoutes` - 1, source and voice 0..`numVoices` - 1, destination 0..`numFastDestinations` - 1, loop 0 or 1), then that every continuous argument is finite. A bad one is ignored with one console line (`postFastModIgnored`): nothing recorded, no node, no channel changed. Only then are the continuous arguments clipped (depth -2..2, attack, decay and release 0.001-10 s, sustain 0-1, curve -8..8), never ignored for being out of range.
- **At most one node per route at every moment, a releasing one included.** There is one def, so a route's node is never replaced: a set re-gates and sets it (a releasing one included) and moves it to another channel with `\out`; a node whose release ended on the server as `setFastEnv` re-gated it is started again when its end reaches sclang (`fastEnvEnded`), as an engine LFO is (`docs/notes/engine/modulation.md`). A hit never makes a node. That every route place's synth is a key of `nodeChannels` is held by the bookkeeping sweep (`sweepBookkeeping`, after every area of the engine check: `docs/notes/test-harness/engine-check-runner.md`).
- **Every channel comes from `fastModChannel(voice, 0, destination)`**, and the nodes write offsets only (the shape times depth), at the tail of `fastModGroup`, after the offset node (which writes every channel first in every block), so the envelope adds to it and a hit lands in the block it arrives in.
- **A channel is zeroed when its last envelope writer ends**: a route's channel goes to 0 when its node ends (a stop's release over) and a moved route's old channel in the bundle that moves it, each unless another envelope node writes that channel then (`envChannelUnwritten`). Like the LFOs', the zeroing matters only while no offset node writes the channel.
- **Every message to an envelope node goes through `sendToSynth`** (they end on their own); a node's creation is a plain `Synth`.
- **A hit sends one message per route whose source is the voice, and nothing else**: `envelopesHit` is reached from the area's `voiceHit` hook through `areaCall` (the pattern `voiceHit: { arg voice, kind; this.areaCall(\envelopesHit, voice, kind) }`), loops with an inlined `while` (no closure), and sends each running route of that source `\hold` and `\t_hit` in one `/n_set`. It never raises. The hold is ruling 26's: `(grainControls[voice][\seqGate] ? 0) * (grainControls[voice][\gateSeconds] ? 0.1)`, both nil until Lua sends them.
- **`numEnvRoutes { ^16 }` is a literal method**: the Lua engine stub reads it for its route check, and a docs test compares it with `S.constants.MATRIX_SLOTS` (a route is a matrix slot).
- **The def has no `LocalBuf`, no delay line and no table**: control rate; `LocalIn.kr` keeps one value in the graph's own memory. Its name must not begin with `strataFastLfo` (ruling 8: the memory check counts the LFO nodes by that prefix).
- **The area's `stop` forgets the places first**, so no node's end restarts a route or zeroes a channel, then frees its nodes; the modulation area's `stop`, after it (descending order), frees `fastModGroup`.

## The envelopes area (`StrataEnvelopes.sc`, order 190)

Design 3.7 §7: each voice has an envelope (attack, decay to a sustain level, a hold, a release), a unipolar modulation source. Lua models it for its own destinations; a matrix routing from an envelope to a fast destination runs in the engine, one node per routing (route = the matrix slot), fired by the source voice's hits with no message from Lua per hit. The area runs after the modulation area (160), whose `fastModBus`, `fastModGroup` (made in its `start`) and command checks it uses.

`areaState[\envelopes]`:

| Key | What |
|---|---|
| `\routes` | one place per route (`numEnvRoutes`, 16): nil, or an Event of its node (`\synth`), `\source` (the voice whose hits fire it), `\channel`, `\controls` (`out`, `depth`, `attack`, `decay`, `sustain`, `release`, `curve`, `loop`) and `\running` (false from a stop: the node is releasing, and its end forgets the place) |
| `\nodeChannels` | each envelope node → the channel it writes, until it ends |
| `\received` | per command, the arguments it last took (the continuous ones clipped), for the engine check |
| `\stopped` | true until `start` (the area not started yet). While it is, and once the engine is past stop (`pastStop`, from `free`'s stop phase: 3.9, #942, `StrataUtil.sc`; the area's `stop` no longer sets this flag), commands and hits do nothing, and no node's end restarts or zeroes anything |

The hooks: `allocState` (`allocEnvelopes`), `addDefs` (`addEnvelopeDefs`), `addCommands`, `start` (`startEnvelopes`: `\stopped` false), `stop` (`stopEnvelopes`) and `voiceHit`. No bus or buffer of its own, so no `free` hook.

### `\strataEnvelope`

`arg out, depth = 0, attack = 0.005, decay = 0.2, sustain = 0, release = 0.2, curve = -4, loop = 0, hold = 0, t_hit = 0, gate = 1` (the defaults are design §7.2's params').

- The shape is `EnvGen.kr(Env([0, 1, sustain, sustain, 0], [attack, decay, hold × held, release × held], curve), trigger)`, `held` = `sustain > 0`: 0 to 1 over attack, 1 to sustain over decay, sustain for the hold, sustain to 0 over release, each slope bent by `curve` (one number for every segment; the hold's is flat). With sustain 0 the hold and release take no time (a block each), so it is an attack and a decay whatever the hold, looping included.
- **A trigger starts the attack from the level the envelope is at**: `EnvGen` restarts its first segment from its current level when its gate rises (`check_gate` and `EnvGen_initSegment`, `server/plugins/LFUGens.cpp`). Segment times are read as each segment starts, so a hit's hold, sent in the hit's message, is the one its hold segment uses.
- `trigger` = `t_hit + (loop > 0) × ended`, where `ended` is `LocalIn.kr(1, 1)`: the last block's `Done.kr(shape)`, or 1 while the envelope has never run (`PulseCount.kr(trigger) < 1`). So with loop on the envelope starts again a block after it ends, as an LFO of its own shape whether or not its voice plays, and at once when it has never run (a route started or set to loop with no hit yet); with loop off only a hit starts it. A hit in the one block after a loop's restart reaches a gate still high and is lost; the envelope has just started again from about 0 anyway.
- `Out.kr(out, shape × depth.lag(0.02) × gateEnv)`, `gateEnv` a 20 ms `Env.asr` on `this.openedGate(gate)` with `doneAction: 2` (`fastLfoFadeSeconds`, as the LFOs').
- Before its first trigger an `EnvGen` holds its initial level (0) and reports no `Done`.

### The commands and the lifecycle

- `setFastEnv`: a route with no place gets one and a node (`startFastEnv`: `Synth(\strataEnvelope, controls, fastModGroup, \addToTail)`, watched through `areaCall(\watchFastEnv, ...)`, whose `onFree` calls `fastEnvEnded`). A route with a place keeps its node: its source, channel and controls are replaced and one `sendToSynth` carries `gate 1` and every control, with a `/c_fill` of the old channel when the route moved and no other envelope node writes it. A set never fires the envelope (only a hit or loop does), and a releasing node it re-gates keeps its level.
- `stopFastEnv`: a running route's node gets `gate 0` (20 ms) and its place is marked not running; no-op otherwise. Its end (`fastEnvEnded`) forgets the place and zeroes the channel unless another envelope node writes it.
- `fastEnvEnded`, a node's end: still its place's and running (its release ended as a set re-gated it) → a new node from the place's controls; its place's and not running (released) → the place is forgotten; then its channel is zeroed unless another envelope node writes it.

### Hits

`envelopesHit(voice, kind)` treats every kind the same (`\start`, `\retrigger`, `\note`; `docs/notes/engine/structure.md`, A hit on a voice). The engine's hits and Lua's differ in three places, and an engine envelope does this at each:
- **A start that its retrigger follows** (`toggle_voice` from a step on a gated voice, a MIDI note's start) is two hits in the engine, `\start` then `\retrigger` a few milliseconds apart: the second restarts the attack from the level the first has reached, so the envelope is one attack begun again a few milliseconds in (a few percent of the way up), with the second hit's hold. Lua's model counts one hit, from the start; the two differ by those milliseconds.
- **A step's chord notes** are `\note` hits in the engine only: each restarts the source voice's routes from their level, a few milliseconds after the step's `retrigger`, so the engine's envelope runs a few milliseconds behind Lua's model of the step's one hit.
- **A start Lua rolls back** (a hook or a send after `voiceOn` raised; `start_voice` sends `voiceOff` and raises again) is a `\start` in the engine and no hit in Lua: the envelope runs its shape once, on whatever channel its route writes (a destination of another, running voice included), while Lua's model shows nothing. An error path only.

### Memory

A node takes 6.7 KB of the pool (3.13 and 3.14.1 alike; the memory check's limit is 9 KB). Sixteen looping routes running through every worst case beside the six engine LFOs and scatter take 80-120 KB at each, and every floor holds (the tightest, high synth -> buffer -> synth, 3880 KB free against 3584): the figures before and after, case by case, are in `docs/notes/engine/memory.md`, 3.7: envelope nodes.

### The check (`test/engine_check/envelopes.scd`)

It runs in about 15 s, in the `modulation,freeze,envelopes,tuning` CI shard (`.github/workflows/test.yml`). Its checks:
- the area's order (190), sixteen empty routes and no node at its start;
- the two signatures; each valid call recorded with its clipped arguments (every bound met from both sides);
- every bad index (route 16 and -1, source and voice 7 and -1, destination 5 and -1, loop 2 and -1, a fractional route; `stopFastEnv` 16, -1 and 0.5) and every continuous argument NaN or infinite: one line each, nothing recorded, no node, every channel at 0;
- no command makes a node outside `fastModGroup`, and twenty hits (a running voice's and a stopped one's, both sources of routes) make no node at all;
- a hit fires every route of its source voice and no other voice's (peaks on three channels: two routes of voice 2, one of voice 3), for a retrigger of a stopped voice, a start and an extra note; a running voice's `voiceOn` fires nothing;
- the shape on a gated voice with `gateSeconds` 0.2 (attack, decay and release 0.05 s, sustain 0.5): 1 within 0.05 at 0.048 s (the attack's end: 37 control blocks), 0.5 at 0.12 and 0.28 s, 0 by 0.4 s, read by a check-only sampler that latches the channel at given times after a trigger sent in the hit's bundle;
- an ungated voice's hold is 0, with no `seqGate` yet (nil) and with `seqGate` 0 sent, `gateSeconds` 0.3 in both: in the release at 0.12 s, 0 at 0.2 s;
- sustain 0 is an attack and a decay with `gateSeconds` 0.3: 0 from the decay's end through what would be its hold;
- a hit in the middle of a linear release starts the attack from the level reached (0.25), never lower and never falling, up to 1 at its end;
- loop: about 11 cycles in 0.5 s with no hit and the voice stopped, none with loop off, and a route that never ran starts once it is set to loop;
- depth -2 reads -2 at the peak; two routes on one channel add (0.3 and 0.2 read 0.5);
- one node per route through starts, moves, shape sets, stops and stops re-set in the same tick, of the sixteen routes at 20 Hz for 2 s, with a hit every step (as the modulation check's LFO series, the same excuse and wait for a re-set split from its stop across two callbacks); none once stopped, no place, every channel 0;
- with the offset node paused, a stopped route's channel returns to 0 (keeping the other route's value while it still writes), and a moved route zeroes its old channel;
- the area leaves every channel at 0, no node or route, every voice stopped with the grain controls it found.
