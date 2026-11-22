# Facts: the state machines of voices, notes, freeze and effects (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

## Summary

| # | Machine | Owner | States | Transition bugs | Inv / States table / model | Rec | Conf |
|---|---|---|---|---|---|---|---|
| 1 | Voice kind (source × freeze), by hand or in a recall | `lib/voices.lua`, `lib/freeze.lua`, `lib/notes.lua` | 5 kinds, 2 paths | 6 (#682, #690 twice, three 3.5 fixes) | none / none / partial | a + c | high |
| 2 | Voice run state and the start transaction | `lib/engine_sync.lua` | 3 real, 2 encoded | 7 (#325, #382, #632, #529 three times, `231d06c4`) | none / none / partial | b-lite | high |
| 3 | Voice freeze: param, waiting toggle, `freezeEnded` | `lib/freeze.lua` | 4 | 2 (#625, #858), plus 1 found here | "quantize" only / none / none | b-lite | high |
| 4 | Synced delay | `lib/delay_sync.lua` | 3 modes × held | 5 (#741, #762, #768, #770, `74cf8c49`) | none / none / none | c + a | high |
| 5 | Note slots | `lib/notes.lua` | 4 per slot | about 12 | yes / none / yes | a | high |
| 6 | MIDI keys, `started`, `stop_pending`, tap, port | `lib/midi_in.lua` | 5 small machines | 7 (#249, #295, #407, #529, #684, `e2cf35d2`, `231d06c4`) | yes / partial / none | a | medium |
| 7 | Send budget | `lib/engine_sync.lua` | 3 | 4 (#591, #637, #654, `725379ca`) | yes / prose contract / none | d | high |
| 8 | Pending voice type | `lib/types.lua` | 2 + clock | 1 (P13), plus pattern 1 | none / none / none | b-lite | medium |
| 9 | Delay freeze × bypass, clear | `lib/fx_hold.lua`, `lib/voice_mix.lua` | 3 legal, 1 illegal | 1 (`4f2cbec0`) | none / none / none | c-lite | medium |
| 10 | Tuning's three texts | `lib/tuning.lua` | 3 copies | 2 (#842 twice) | none / none / none | c-lite | medium |
| 11 | Quantize scheduler | `lib/quantize.lua` | 3 | 3 (#625, #626, #631) | yes / none / none | d (copy it) | high |
| 12 | Mute and solo, arp list, expression records, MPE channels, lock, freq shadow, base override | various | small | 0-3 each | arp only | d | medium |

"b-lite" means a named value or argument at one door, not a state-machine module.

Five things most worth knowing:

1. **A waiting freeze toggle carries no target.** I confirmed it with a probe: a frozen voice whose FZ key waits for the bar, then loses its freeze to a source switch, is frozen again at the bar. #625 fixed the same hole for the pattern start but not for freeze. The fix is one cancel in the freeze action.
2. **"Starting" is a real state with no name.** The grain-restart hooks run after `voiceOn` while `voice.active` is still false, and four hooks read that false as "this is a start, not a source switch". Seven bugs came from this distinction. Passing the reason to the hook removes the trick.
3. **`S.scene_recall_in_progress` carries four different promises in this area**: skip the source hooks, defer the sync, do not snap, hold the delay send. Recall-path bugs (#690, `74cf8c49`) came from one promise being kept differently from the by-hand path. The two paths need one transition table.
4. **Nearly every bug here was a wrong transition between legal states.** The three illegal-state bugs (#382, ruling 39's parked silent voice, #654) each became a guard or an invariant. Only the note slots have a model that walks transitions. The synced delay has five bugs in 206 lines and no invariant, States table or model.
5. **The type settle clock is canceled with no "retire" guard** (`lib/types.lua:92-98`), the #626 pattern. I inferred this from the code and did not probe it. The 200-local limit is no constraint here: every module in the area has at least 137 locals free.

---

## Full report

### Method

I read the fifteen notes files and the code, and measured free locals with a copy of the structure test's probe. I ran four probes through `lua test/run.lua --jobs 1 --dir <scratch>`, where the probe file is `probes.md`. Nothing in the repo changed.

### 1. Voice kind: source × freeze, by hand or in a recall

**Owner.** The source action is `lib/voices.lua:342-361`. The freeze param and its source hook are `lib/freeze.lua:110-115, 147-149`. The consequences for notes are `lib/notes.lua:129-131, 1017-1032, 1071-1084, 1095-1107`.

**States.** A voice is one of synth, frozen synth, buffer, input or voice-source. No field holds this. It is derived in at least four places, each differently: `frozen_synth` (`lib/notes.lua:129`), `own_pitch` (`lib/notes.lua:373-378`), `own_setters` (`lib/midi_in.lua:483-492`) and `placement` (`lib/expression.lua:90`). A voice-source voice falls into the "else" branch as an input voice in three of them. `docs/notes/lua/expression.md`'s table has no column for it.

**Transitions.**

| Event | By hand | In a recall |
|---|---|---|
| Source set | store, `setGrainSource`, grain-restart hooks if running, source-change hooks (freeze goes to 0), sync | store, `setGrainSource`, grain-restart hooks; no source-change hooks, no sync (`lib/voices.lua:349, 353`) |
| Freeze set | action, sender, freeze-change hooks (reference taken, extras cut) | the same, as a later discrete entry |
| End | nothing | one sync per changed voice, then `recall_switched` (`lib/notes.lua:1095`) |

By hand, the grain-restart hook sees a brief "frozen synth" state: the new source with the old freeze still 1. It takes a reference that the freeze hook drops a moment later.

**Guards.** Tests are by example in `notes_test.lua`, including "all four cases of the freeze before and the scene's". The note model sees `setGrainSource` and the freeze param (`test/notes_model.lua:5-7`). There is no invariant and no States table.

**History.** All were wrong transitions between legal states:
- #682: a chord on a frozen synth voice went out of tune at a source change.
- #690, `8e381816`: a recall into a frozen synth left extras silent and counted in the pool. The model found it.
- `c1b89391`, ruling 59: the first fix cut at the switch, not at the recall's end.
- `a1d8c4d5`, `bb16838c`, `baf1ebca`: the freeze reference and the slot-0 `noteOn` around starts and switches.

**Why it has this shape.** A recall sets every value itself and must send one sync, not seven (`docs/notes/lua/engine-sync.md`, the exception). So hooks cannot simply run in a recall.

**UX.** MAIN shows the source label and `[F]` (`lib/pages/main.lua:154, 185-189`). Nothing shows that extra notes were cut at a freeze, except the held count dropping.

**Recommendation: (a) plus (c).** Put the two-column table above in `docs/notes/lua/freeze.md`. Add one table-driven test over {kind before} × {event} × {by hand, recall} that asserts the end state (freeze param, reference, extras, `scaleNote`). The code stays unchanged. A named `kind(voice)` accessor (b) is tempting but risky: the four derivations differ on purpose (expression treats a frozen synth apart; MIDI does not). Cost is about a day. A wrong table would show in the existing example tests. Bug count 6, blast radius high (stuck or silent notes), confidence high.

### 2. Voice run state and the start transaction

**Owner.** `voice.active` is written only at `lib/engine_sync.lua:665` and `:799`. The functions are `toggle_voice` (`:659-674`), `start_voice` (`:769-804`) and cleanup (`:810-817`). About 95 reads sit in 27 files.

**States.** The real states are stopped, starting (`voiceOn` sent, hooks and voice-level sends running, `active` still false) and running. The engine also has "releasing", which Lua does not model. A voice sounding but marked stopped is meant to be impossible; #382 was exactly that.

**Transitions.**

| Event | From → to | Guard |
|---|---|---|
| `start_voice` | stopped → starting → running | `xpcall` rolls back with `voiceOff` (`:788-798`) |
| `toggle_voice`, a release-mode last key, a recall, a panic | running → stopped | voice-stop hooks, contained (`:607-611`) |
| Source switch on a running voice | running → running | grain-restart hooks, not contained (`:577-579, 589`) |

**The implicit part.** Four grain-restart hooks read `not S.voices[v].active` to mean "this is a start" (`lib/notes.lua:1075, 1080`; `lib/midi_in.lua:345, 596`). So one field holds two facts during that window. There is no voice-start hook. A start is also seen as `voice_hit` with source `"start"`, which is not emitted when `retrigger_follows` (`:803`).

**Inconsistent containment.** Voice-stop, voice-hit, freeze-change and silence hooks are contained. Grain-restart hooks at a source switch, source-change hooks (`lib/voices.lua:350`) and lock-change hooks (`:681`) are not. I infer that a raising hook would leave the engine on the new source with the old values and no sync; I did not observe it.

**Guards.** `engine_sync_test.lua` (2,072 lines) pins the order by example. There is no invariant and no States table.

**History.**
- #325: the order of sends in a start.
- #382: an illegal state, fixed by the rollback.
- #632: a start without its step locks.
- #529 (`7680cf10`, `1125790f`, `ab38c81a`): `started` across a restart and a source change.
- `231d06c4`: `stop_pending` hitting a restarted voice.

The last four are all the start-versus-switch distinction.

**UX.** MAIN shows `+`/`-` and ON/OFF (`lib/pages/main.lua:73, 174`). Edits to a stopped voice in its release tail reach no engine, except the mute. Probe D confirmed that only `voiceMute` was sent. The grain tail is about 2 s, so this is minor.

**Recommendation: (b-lite).** Call the grain-restart hooks with a reason: `hook(voice, "start" | "source")`. Replace the four `not active` reads. A structure test can then forbid `.active` inside a grain-restart hook. Contain the hooks at a source switch as the others are. Cost: one signature and seven registrations (`lib/scan.lua:186`, `lib/playheads.lua:294`, `lib/positions.lua:890` and the four above). Risk: Lua ignores extra arguments, so old hooks keep working. `midi_in_test.lua` and `notes_test.lua` cover every changed read. Do not turn `active` into an enum: 95 readers and the tests' `local_value` reach it. Confidence high.

### 3. Voice freeze: param, waiting toggle, engine-ended hold

**Owner.** `lib/freeze.lua`: `is_frozen` (`:47`), `toggle` (`:55`), `toggle_quantized` (`:63-68`), the `ended` table (`:76`), `reaches` (`:139`), `freeze_ended` (`:158-169`).

**States.** Off, on, on with a toggle waiting, off with a toggle waiting. The engine also has "hold pending its copy" and "abandoned". The param holds two facts: what the player asked for and what the engine holds. #858 was the two diverging.

**Transitions.**

| Event | Effect | Writer |
|---|---|---|
| VOICE row, a mapped CC, a recall | set at once | the param action |
| Grid FZ key | toggle at the bar; a second press takes it back | `toggle_quantized` |
| Source switch by hand | goes to 0 | the hook (`:147`) |
| `freezeEnded` with a newer count | goes to 0, nothing sent | the poll (`:158`) |

**Found here (probe A, confirmed).** The waiting action is `M.toggle`, not "unfreeze". A source switch between the press and the bar leaves the voice unfrozen with the toggle still waiting, and the bar then freezes the new source. Nothing but a second FZ press cancels `freeze<v>` (`grep quantize.cancel`: `lib/freeze.lua:66` only). The sequencer cancels its waiting start on every other transition (`lib/sequencer.lua:1547, 1574`). No invariant fails, because both states are legal.

**Guards.** `freeze_test.lua` has 16 tests, by example. The "quantize" invariant covers the clock, not the intent. The #858 race (a refreeze within milliseconds) is documented in `docs/notes/lua/freeze.md`.

**UX.** `[F]` on MAIN, the grid key at 15 or 3, and the header flash `v3 frz at bar`, which another flash may replace. The grid key never shows a waiting toggle (`lib/grid/pages/voices.lua:129`).

**Recommendation: (b-lite).** In the `v<i>_freeze` action, cancel `freeze<v>` when the change did not come from the scheduled toggle. Or schedule a target value instead of a toggle. Add a three-row States table to the notes. Cost is a few lines and one test. Risk: the action runs inside the scheduled function too, so the cancel must not retire its own clock. `quantize.schedule` already clears `M.actions[key]` before `fn` runs (`lib/quantize.lua:116`), so a plain `cancel` is safe. Confidence high.

### 4. Synced delay

**Owner.** `lib/delay_sync.lua`, with the one sender at `lib/engine_sync.lua:521-530`.

**States.** Mode is free, division, or synced with no length. It is computed three times as `synced() and synced_time()` (`:59-62, 112, 154`). Beside it are `last_sent` and `last_others` (`:95-101`) and `held` (`:132`).

**Transitions.** A tempo move sends under the key `"delay sync"`, or under `delay_time` when there is no length (`:150-159`). Modulation of `delay_time` is skipped while `time_unheard()` holds (`:111`), which `lib/matrix.lua` and `lib/macros.lua` read. Sync off sends the modulated time (`:180`). A recall holds and the scene-applied hook flushes (`:134-138`).

**History.** Five wrong transitions in two days: #741 and #762 (too many sends), #768 (stale value on entering no-length), #770 (two sends a step), `74cf8c49` (a recall sending a mix of old and new). Each got an example test.

**Pattern 3.** `held` is set by `lib/engine_sync.lua:523` and flushed by scenes' hook. The flag is cleared at `lib/scenes.lua:584`, before the hooks. I did not read past that line to see whether a failed apply still flushes.

**Pattern 2.** `lib/delay_sync.lua:164` reads `S.scene_transition_active` to skip a grid redraw. The discrete `delay_sync` and `delay_division` only switch at a fade's end, so during a fade those actions come from the hand. I infer that a hand change mid-fade skips the 256's fader redraw until the next fade step.

**UX.** The time row shows the division label, and `1 bar>1/2` when halved. While frozen, the time row still edits and shows a time the loop is not playing (`docs/notes/lua/fx-hold.md`). This is a small gap.

**Recommendation: (c) plus (a).** Write one table-driven test over {mode} × {tempo move, modulation, feedback edit, sync toggle, recall, tempo to 0 and back} that asserts the number of `setDelay` and the time each carries. Add a States table to the notes. A local `mode()` would tidy the three copies but is optional. Cost is half a day. Bug count 5, blast radius medium (audible time jumps, message floods), confidence high.

### 5. Note slots

**Owner.** `lib/notes.lua`: `slots` (`:57`), `play` (`:553-659`), `play_own` (`:466`), `release_slot` (`:666`), `unpark_alone` (`:442`), the timers (`:813`), the invariant (`:1131`).

**States per slot.** Free, held, parked (slot 1 only), and held-quiet on a stopped voice awaiting its caller's start. The invariant forbids every other combination, including a parked own note on a running voice with nothing held (ruling 39).

**Coverage.** It has an invariant and the seeded model (`test/unit/strata_test.lua:422`). It has no States table: `docs/notes/lua/notes.md` describes branches, not states.

**History.** About 12, almost all wrong transitions:
- `baf1ebca`, `66201bdf`, `bb16838c`, `a1d8c4d5`: parks and the freeze reference.
- `4179feb4`, `e2cf35d2`: a parked, silent, noteless voice. This was an illegal state that became the invariant.
- `5e7abbfd`, #684, #683, `6a604c9b`, `ad98a781`, `98bce41c`.

The model found #690, which no Lua invariant could see because Lua and the engine disagreed.

**Fields holding two facts.** `play` returns `NOTES.arp_slot`, 0, as "truthy, never 1" (`:38`). `quiet and held` on a stopped voice means "awaiting a start".

**Recommendation: (a).** Add a States table for slot 1 and for an extra slot, with events as rows. This is the best-kept machine in the area, and the model is the pattern to copy. Do not refactor: `play`'s branch order is the specification ("3.4's, message for message").

### 6. MIDI keys and their satellites

**Owner.** `lib/midi_in.lua`: `S.midi_state` (`:40-45`), `stop_pending` (`:284`), `note_tap` (`:55`), `listening_port` and `attached_device` (`:74-75`).

**Coverage.** The invariant "midi notes" (`:626`) and the States table in `docs/notes/lua/midi.md` cover `held`, `note_voice` and `started`. They do not cover `stop_pending`, the tap or the port.

**`stop_pending`.** This is a deferred stop: set at `:295`, flushed by the LFO step (`:331-342`), cleared by a key down (`:392`), a stop (`:343`) and a start (`:345`). It has four clearers in three places, described in prose only. `231d06c4` was a missing clearer.

**The tap.** It is one slot with two clients, the zones editor and the scale editor. `reset_midi_input` clears it without telling its owner (`:229`), so the scale editor re-arms it at every draw (`lib/ui/scale_editor.lua:199`). That is an edge for the UI audit.

**A claimed port.** `listening_port == nil` means notes are silently not played (`:91-95`). I did not check whether SETUP shows the claim.

**UX.** Nothing shows `started` (the panic's set) or a held-back stop. In release mode the last key stops a voice whoever started it (plan ruling 8, by design).

**History.** Seven, all wrong transitions: #249, #295, #407, #529, #684, `e2cf35d2`, `231d06c4`.

**Recommendation: (a).** Add `stop_pending`, the tap and the port to the States table, each with its clearers.

### 7. Send budget

**Owner.** `lib/engine_sync.lua:176-359`. States: nothing waiting; waiting with the clock running; clock running on with nothing waiting until its next wake.

**Coverage.** The invariant (`:338`) and a full contract in `docs/notes/lua/engine-sync.md`.

**History.** The wrong transitions were #591, #637, `725379ca` and #654. Six more were accounting: #642, #644, #645, #646, #649, #703.

**Pattern 1.** This clock is never canceled while the script runs (`:254-264`), the cleanest answer to #654.

**Recommendation: (d).** The contract is already explicit. Copy its "never cancel, end at your own wake" where a clock can afford it.

### 8. Pending voice type

**Owner.** `lib/types.lua`: `pending` (`:90`), `stop_settle` (`:92-98`), `cancel` (`:102`), `flush` (`:114`), `turn` (`:125`), `set` (`:153`).

**Pattern 3, confirmed.** The value is flushed from `lib/ui/keys.lua:50` (a voice pick, leaving VOICE), from its own voice-stop hook (`:139`) and from the settle clock. It is canceled from `lib/voices.lua:219`, `lib/scenes.lua:516`, `lib/params_setup.lua:279` and `lib/factory.lua:357`. That is eight sites in six files for one rule, because norns' `Option:set` runs no action for an unchanged value (P13 amended, `docs/decisions/3.8.md:264`).

**Pattern 1.** `stop_settle` calls `clock.cancel` on a sleeping clock with no check that its resume may be posted. It runs on every turn, every cancel, and from a voice-stop hook that a pattern step's clock can trigger in the same tick. By #626's finding this prints `bad argument #1 to 'resume'` in maiden; behavior stays right. The clock does avoid canceling itself (`:132`). I inferred this and did not probe it, since `run_for` cannot see it.

**UX.** The pending name is drawn at level 4 on VOICE only (`lib/pages/voice.lua:186`). Leaving VOICE applies it, so it is never stranded.

**Recommendation: (b-lite).** Give the settle the quantize module's retire rule, ideally as one shared helper, since the rule is hand-written in seven modules. Add a "type settle" invariant: a pending value exists exactly while its clock runs. Risk is low and `pages_voice_test.lua` covers the paths.

### 9. Delay freeze × bypass, and the clear

**Owner.** `lib/fx_hold.lua:27-68, 81-93` and the bypass action at `lib/voice_mix.lua:250-253`.

**States.** Running, running and frozen, bypassed. Bypassed and frozen is meant to be impossible, kept so by two guards: the bypass releases first, and the freeze is refused while bypassed.

**Probe B.** A silent set (`params:set("delay_bypass", 1, true)`, as norns' silent read does) reaches bypassed and frozen. `freezable` is then false, so ALT+K3 does nothing. E3 down on the freeze row still gets out. It is reachable only through a silent read, so severity is low.

**The clear.** Lua has no state for it. Probe C showed one `clearDelay` and no flash. On a frozen delay the loop empties and stays frozen on silence with the input closed (`docs/notes/engine/delay.md:22`), and `K3:clear` is offered there. The screen says `frz`, so it is recoverable but surprising.

**UX otherwise good.** `frz` and `byp` on the section rows (`lib/pages/fx.lua:145-149`), FX's page dot as a bar on every page (`lib/ui/header.lua:23-36`), and the grid keys.

**Recommendation: (c-lite).** Register an invariant `not (bypassed and frozen)`. Cost is five lines. One decision to make: either it allows the silent set, or the read hook settles it.

### 10. Tuning's three texts

**Owner.** `lib/tuning.lua`: the param text, `current.text` (`:104`) and `engine_text` (`:106`). `send` (`:304-308`) is up to 129 direct messages and is atomic in Lua.

**History.** #842, twice, was the three copies diverging after a silent read. The read hook (`:478-484`) and `select` (`:338`) now reconcile them.

**Recommendation: (c-lite).** An invariant that the param text equals `current.text`. `engine_text` may lag by design.

### 11. Quantize scheduler

`lib/quantize.lua` is explicit already: actions by key with tokens (`:33, 105`), a retired set (`:36`), `resume_may_be_posted` (`:54`) and an invariant (`:140`). #625, #626 and #631 were all fixed here. It is the pattern for machine 8. Its one gap is machine 3: a toggle has no target.

### 12. Small machines, leave alone

- **Mute and solo** (`lib/voice_mix.lua:55-118`). `silenced` is derived, with two caches, `sent_mute` and `told_silenced`, deliberately apart (plan ruling 16). One bug, #640. A stopped muted voice shows only `-` on MAIN (`lib/pages/main.lua:73-80`). (d).
- **Arp list** (`lib/arp.lua:48-51, 121`). It has an invariant. Two bugs: `f0905792` and #846. `bases[v] == nil` doubles as "check every step" (`:330`). (d).
- **Expression records** (`lib/expression.lua:169-176`). Pending, live, latched, inert, with lazy removal at the step. Two bugs. (d).
- **MPE** (`lib/mpe.lua:29`). RPN selection and the CC87 prefix are tiny protocol machines. `master_range` is shown on no screen and survives every reset but a port or device change (#688). (d).
- **Lock.** Two writers, `toggle_lock` (`lib/engine_sync.lua:678`) and `lib/scenes.lua:502`, each running the hooks itself. One setter would do; this is an edge for the scenes audit.
- **Freq shadow** (`lib/variation.lua:201-233`). #318 and #125 were wrong values, not transitions. (d).
- **Base override** (`lib/engine_sync.lua:68, 378-399`). The lifecycle is the sequencer's. MAIN and VOICE show the stored value, not the override. That is an edge for the sequencer audit.
- **Not machines:** the grain cloud mode, the shimmer params, the page cursors.

### The three patterns

1. **Clock canceled with its resume posted.** In this area the budget never cancels and quantize retires. `lib/types.lua:96` is unguarded. No other clock in the area is canceled.
2. **Flags read with another meaning.** `S.scene_recall_in_progress` is bracketed at `lib/scenes.lua:566-584`. In this area it is read as:
   - "a sync follows, skip mine" (`lib/voices.lua:227, 353`);
   - "the scene sets what the hooks would" (`lib/voices.lua:349`);
   - "values are exact, do not snap" (`lib/variation.lua:217, 328, 383`);
   - "more delay values are coming, hold" (`lib/engine_sync.lua:522`).

   `S.scene_transition_active` is read as "do not re-snap" (`lib/variation.lua:383`) and "skip the grid redraw" (`lib/delay_sync.lua:164`). Fields holding two facts are `voice.active` during a start, the `v<i>_freeze` param, and `play`'s 0.
3. **Pending values flushed elsewhere.** The pending type, the delay's `held`, `stop_pending`, the arp's `pending`, and the waiting freeze toggle. Only the last has a missing trigger.

### One cross-cutting gap for agents

Lua keeps at least eight mirrors of engine state, each with its own reset rule tied to `voiceOn`, `voiceOff` or alloc:
- `S.engine_param_values`
- `sent_sources` (`lib/engine_sync.lua:575`)
- `sent` and `regions_sent` (`lib/notes.lua:57, 61`)
- `sent_mute` (`lib/voice_mix.lua:82`)
- `remembered` (`lib/arp.lua:121`)
- `last_sent` (`lib/delay_sync.lua:95`)
- `engine_text` (`lib/tuning.lua:106`)

One table in `docs/notes/lua/engine-sync.md` listing each mirror and what resets it would save an agent from reading eight modules.
