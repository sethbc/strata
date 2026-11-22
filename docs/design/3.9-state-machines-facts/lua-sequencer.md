# Facts: the state machines of the sequencer (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

## Summary

Nothing in the repo was changed. The probes are scratch unit tests (`probes.md`), run with `lua test/run.lua --dir`.

| # | Machine | Owner | States | Transition bugs | Rec. | Confidence |
|---|---|---|---|---|---|---|
| 1 | What a step holds on its voice (locks, note, chord, region, slice) | `lib/sequencer.lua` | 6 parallel per-voice tables | about 10: 7e40f368, #632, rulings 32/35/55 (#684), ad98a781, #740, #744 | **c** (invariant + truth-table test), then fold into one record | medium-high |
| 2 | A voice's position and pass (direction, pass length) | `lib/sequencer.lua` | 4 fields per voice | #743 (twice), plus one unspecified transition found here | **c** | high |
| 3 | A clock's wait and end (count kept, retire) | `lib/sequencer.lua` | waiting × retired × stale × generation | 5: rulings 47, 54, 58, dc315d29, the #626 class | **a** | high: leave the code |
| 4 | Play state (stopped, start armed, playing) | `lib/sequencer.lua`, `lib/quantize.lua` | 3, of which 2 are tabled | #243, #530, #625, #631, #113 | **a** + a read accessor | high |
| 5 | Step editor (grid hold, modal, `replacing`) | `lib/pages/seq.lua`, `lib/grid/core.lua` | closed, open, open+replacing | #592, ruling 71, 2a411200, #596 | **c** (joint invariant) | medium |
| 6 | Voice hit (start or retrigger, gate, slice hit) | `lib/sequencer.lua`, `lib/engine_sync.lua` | 4 branches | #632, #639, #527 | **a** | high |
| 7 | Chain | `lib/sequencer.lua` | off, armed, linked | #738, 806a43db | **d** (UX only) | high |
| 8 | Fill (latch or holders) | `lib/conditions.lua` | 4 | 806a43db | **d**: copy it | high |
| 9 | Division reset, step outputs, transport handlers, conditions, SEQ views, random sequences, gate cache | various | small | ruling 38, 3463f4d3 | **d** | high |

Five things most worth knowing:

1. **The bug-prone machine is the step's holds, not the clock.** Six local per-voice tables (`lib/sequencer.lua:138,144`) must agree and end together. About ten fixes were wrong or missing transitions between legal states, and no invariant or States table covers them.
2. **An unspecified transition exists today.** Changing `seq_direction` mid-pass replays steps. My probe gave `8 7 6 →forward 7 8 1 2 3 1 2 3…`, because the pass ends by steps taken (`:1217-1219`), not by position. Every chain link carries the direction (`:55`, `:1146-1148`). No test changes direction mid-run.
3. **Leave the clock code alone.** Its "state" is beat arithmetic across a coroutine yield. Rulings 47, 54 and 58 are scenario-tested about 25 times, and a table FSM cannot express "test the beat `clock.sync` returned". Its retire rule is hand-written here and again in `lib/quantize.lua:54-76` and `lib/gestures.lua:309`. The grid's step-hold clock, which opens the step editor, still cancels plainly (`lib/grid/core.lua:221-226`).
4. **Armed states are invisible or mislabeled.** While a quantized start waits, SEQ's hint says `K2:play` although K2 would cancel it (`lib/pages/seq.lua:720`), the grid key shows stopped (`lib/grid/core.lua:524-526`), and another header flash erases the only cue (probed). An armed division reset, the chain's current scene and a failed step output show nothing.
5. **Flags read with another meaning.** `S.scene_recall_in_progress` at `:1513` is dead: it is true only inside the synchronous `apply_entries` (`lib/scenes.lua:566-584`), where no encoder turn can arrive. During a fade, which is what design §8.5 seems to mean, euclid still fills and the fade's end overwrites it. #113 was the same class (`S.pattern_position` read as the playhead).

---

## Full report

### Shared facts and constraints

- **House pattern.** The invariant registry dates from #232 (ec49a249) and the audit recorded at `docs/decisions/3.3.md:39`. My area has two: "pattern clock" (`lib/sequencer.lua:1808-1824`) and "step editor" (`lib/pages/seq.lua:946-952`). The table at `docs/notes/lua/state-and-voices.md:340` gives "pattern clock" only its first clause; the code also checks every voice's clock and the retired ones.
- **Tests.** `test/unit/sequencer_test.lua` has 139 tests, all by example. The clock tests assert properties over scenarios (`:1675-1702`: no step twice, none skipped). No transition is enumerated. They reach only `S` fields and `M` functions: `S.pattern_playing`, `S.pattern_clock`, `S.pattern_clocks` (`structure_test.lua:891,905`) and `S.pattern_position` (`pages_seq_test.lua:157`). Those names must stay; the locals are free to change.
- **Model coverage.** The notes model walk (`test/unit/strata_test.lua:422-461`) sets chord steps and toggles the patterns, so the slot side of step chords is modeled. Nothing models the sequencer's own state.
- **Locals.** `lib/sequencer.lua`'s constructor uses 115 (85 free, 55 above the test's floor); `lib/pages/seq.lua` uses 83 (measured with a probe).
- **Why a naive FSM refactor is wrong here.**
  - A wake tests the beat its `clock.sync` returned (`:1020-1023`).
  - No clock is canceled while its resume may be posted (`:1061-1068`).
  - No `play` yields (`:804-831`).
  - Tests compare every engine call ("a 3.6 pattern plays the same steps", `sequencer_test.lua:3904`; "3.4's messages", `:2571`).
  - Positions, passes, outcomes and holders are never params, scene fields or PSET values (`docs/notes/lua/conditions.md:7`).

### 1. What a step holds on its voice

**State.** `overrides`, `last_played`, `gate_sent`, `chords` (`:138`); `step_regions`, `step_slices`, `step_region_to_end` (`:144`); `stepping` (`:584`). The base overrides themselves live in `lib/engine_sync.lua:68`.

**Real states per voice.** Nothing held; locks only; note override as the own note (`chord.own`); first note in an extra slot (no override); chord with extras; own region set (may ring to its end); overlap slice in an extra slot (`rings` or not).

Representable but meant impossible: any of these while stopped; `step_region_to_end` without `step_regions`; `step_slices[v].step ~= last_played[v]`; `chord.own` with no note override.

**Transitions.**

| Event | Function | Effect |
|---|---|---|
| A step's first hit | `apply_step` `:633-702` | Clears the overrides it lacks, sets its locks, releases chord keys it lacks, decides region or slice, plays the first note |
| A ratchet's later hit | `voices_play` `:740-785`, `play_chord` `:709-718` | Accents only |
| Stop, `replace_pattern`, chain link | `end_overrides` `:385-394` via `:1580`, `:1483`, `:1141` | Ends all |
| Length cut below `last_played` | `seq_length` action `:1639` | Ends all |
| Pass end with no set step | `:1240` | Ends all |
| Hand edit of the param | Touch hook, `engine_sync.lua:399` | Clears the engine's override only; the sequencer's set keeps the id (harmless: `:387`) |
| MIDI takes slot 1 | `own_note_taken` `:568-578`, from `midi_in.lua:528` | Ends the note override |
| Slice refused a slot | `take_own_slice` `:724-731` | Own note takes the slice |

Outside readers: `slices.lua:460` (`playing_region`), `midi_in.lua:512` and `io/actions.lua:84` (`note_gate`).

**The slice decision as a truth table** (from `:669-685` and `:756-784`; I verified it by reading, not by test):

| Voice option | Other owner on slot 1 | Chord | Earlier slice rings | The slice plays as | The hit |
|---|---|---|---|---|---|
| one or off | no | no | – | own region | retrigger |
| one or off | no | yes | – | `chord.region` on every note | retrigger |
| one or off | yes | any | – | dropped | retrigger |
| overlap | no | no | no | own region | retrigger |
| overlap | no | no | yes | extra slot, `rings` | `extra_note_hit`; with no room, `take_own_slice` then retrigger |
| overlap | no | yes | any | `chord.region` | retrigger |
| overlap | yes | any | any | extra slot | retrigger; the slice only if there is room |

**Guards.** Example tests (`:712`, `:808`, `:1632`, `:2644`, `:4048-4372`). The slot side has the "notes" and "arp" invariants and the model walk. There is no invariant of its own and no States table. The notes rules at `docs/notes/lua/sequencer.md:3-11,34` are prose of 300 to 600 words each.

**History.** Introduced in 3.4 (51dc1fcb). Every fix but one was a wrong or missing transition:
- 7e40f368: locks never ended once the only set step was turned off.
- #632 (60e2b41d): overrides were set after the start, so the first grain missed them.
- Rulings 32 and 35 (c750adc3, dbd37b38): a step took slots from MIDI.
- #684, ruling 55 (0ea2bf01): a latched note blocked steps; two minors added `leave_extra_slot` and `own_note_taken`.
- ad98a781: the overlap own-note order, and a stop cut one-shot slices.
- #740: `playing_region` ended on a timer.
- #744: a refused slice retriggered the ringing one.

#382 is the one illegal-state bug, and it is `engine_sync`'s.

**UX.** A step lock in force shows nowhere. No UI reads `engine_base_value` (its readers are `variation.lua:347` and `notes.lua:136,376,1106`), so VOICE shows the stored value while the engine plays the lock. A first turn ends the lock silently. I inferred there is no mark; I did not render the pages.

**Recommendation: c.** Register a "step holds" invariant in `lib/sequencer.lua`: stopped means all six tables are nil and `stepping` is empty; `step_region_to_end[v]` implies `step_regions[v]`; `step_slices[v].step == last_played[v]`. Add a table-driven test of the truth table above, and put the table in the notes.

Optional second step: fold the six tables into one `held[v]` record ended by one function. That frees five locals and touches no outside reader.

Cost: about 30 lines for the invariant and 120 for the test. What could break: nothing for the invariant; for the fold, message order, which the exact-call tests catch.

Bugs about 10; blast radius one file, but audible; confidence medium-high. I checked the stopped-implies-none claim by reading every path (`:1573-1583`, `:1546-1566`), not by running it.

### 2. A voice's position and pass

**State.** `state.last`, `taken`, `heading`, `pass_length` (`:1171-1174`). The pass count is in `lib/conditions.lua:45`.

**Transitions.** `start_position` at three sites (`:1368`, `:1334`, `:1439`), `take_position` (`:1204-1246`), `ping_pong_step` (`:1184-1190`). Skipped ticks advance by the same function (`:1347`).

**Guards.** Example tests (`:3428`, `:3462`, `:3939`, `:3966`). No invariant, table or model.

**History.** 3.7 (1a6c43dc). #743 was fixed twice (f75ac2ed, 8569ba72). A reverse pass shortened mid-pass was ruled to stand (`docs/decisions/3.7.md:127`). All were wrong transitions.

**Found by probe.** A direction change mid-pass is unspecified in design §5.5 and untested:

| Change | Played | Repeat |
|---|---|---|
| reverse ×3 → forward | `8 7 6 7 8 1 2 3 1 2 3 4…` | `1 2 3` twice |
| forward ×3 → reverse | `1 2 3 2 1 8 7 6 8 7 6 5…` | `8 7 6` twice |
| ping-pong ×11 → forward | `…5 6 7 8 1 2 1 2 3…` | `1 2` twice |

Cause: the pass ends at `taken >= pass_length` and forces the direction's first step (`:1217-1219`, `:1226-1228`), wherever the position is. Chain links and scene recalls set the direction, so this is reachable in ordinary use.

Also probed: a misstep while a shorter length waits wraps by the new length at once (`:1224`): `1 2 3 4 5 6 | 1 4 1 2 1 4`.

**Recommendation: c.** A table test of direction × length change × direction change at each `taken`. Then a ruling on what a direction change should do. `take_position` is nearly pure and could be extracted for the table. Cost: about 100 test lines. Confidence high.

### 3. A clock's wait and end

**State.** Per participant: `waiting` (nil, `"sync"`, `"sleep"`), `retired` (the id, which also means "ended": one field, two facts), `stale`, `generation` against `play.generation`, `last_sync`, `sync_beat`, `due` (`:106-137`). Shared: `play.offset`, `play.retired`.

**Transitions.** `wait_for` (`:988-1037`), `keep_count` (`:918-927`), `end_clock` (`:1061-1068`), `finished` (`:948-952`).

**Retire, never cancel: which clocks have it.**
- Voice and transport clocks: yes, at every end (`end_clocks` `:1433-1445`, `restart_voice` `:1399-1407`). A followed start retires all (`:1721`).
- The erroring clock ends itself (`:1316-1325`).
- Cleanup cancels the retired ones (`:1782`), which is allowed as the script ends.
- The quantized start's clock: yes, in its own copy (`lib/quantize.lua:54-76`).
- `sequences_save_clock`: plain cancel, at cleanup only (`lib/side_files.lua:185-188`). That is fine.
- Output workers are plain coroutines (`:809-831`), so there is no hazard.
- The grid's step-key hold clock, which opens the step editor: plain `clock.cancel` on a sleeping clock (`lib/grid/core.lua:221-226`). By the sequencer's own rule a sleeping clock's resume may be posted (`:1047`). I inferred this hazard and did not reproduce it. It is grid core's to fix.

**Guards.** The invariant covers recorded and retired clocks. There are about 25 scenario tests (`:1703-2296`). No States table: the notes hold rules 13 to 19 as prose.

**History.** Ruling 47 (7e40f368), ruling 54 (944751b4), ruling 58 (fc94007c), dc315d29. All were wrong transitions. dc315d29 was an illegal action in a legal state, which end-of-test invariants cannot see.

**Recommendation: a.** A small state diagram in the notes (running → sync or sleep → on-time, off or stale; retired absorbs). A shared retire helper is a cross-area refactor for whoever owns clocks. Blast radius: every step's timing.

### 4. Play state

**State.** `S.pattern_playing`, `S.pattern_clock`, `S.pattern_clocks` (`:91-93`). The armed start is `S.lib.quantize.actions.patterns`. Effective following is two params (`:1698-1700`).

**Transitions.** `pattern_toggle` (`:1532-1538`), `start_patterns` (`:1546-1566`), `pattern_clock_stop` (`:1573-1583`), `transport.start` and `transport.stop` (`:1719-1735`), `guarded` (`:1316-1325`), `io_actions.patterns` (`lib/io/actions.lua:113-121`: direct, never quantized, never a take-back).

Readers of `S.pattern_playing`: `ui/header.lua:77,104`, `grid/core.lua:525`, `pages/seq.lua:720,881,1148`, `io/osc.lua:53`, `io/actions.lua:114-118`.

**Guards.** The invariant; a States table (`docs/notes/lua/sequencer.md:84-91`) with two states and no armed row; the "quantize" invariant. The model walk toggles it.

**History.**
- #243: an illegal state (lit with dead clocks). This is the one class the invariant catches.
- #530: a missing event.
- #625: a wrong transition (an armed start never dropped).
- #631: a flash outlived.
- #113: `S.pattern_position` means "the next 16th" but was read as the playhead.

**UX (probed).**
- Armed: the hint reads `K2:play`, the grid key is at the stopped level, and the header flash `play at bar` is lost to any later flash. A second press then silently cancels.
- SETUP's `transport: follow` shows the param even on the internal clock, where nothing follows (`lib/pages/setup.lua:81`).
- A count offset after an unfollowed reset (ruling 47) is invisible (`count_offset` has no reader outside tests).

**Recommendation: a.** Add the armed row to the table, and an accessor `S.lib.sequencer.play_state()` that the hint and the grid key read. It is a display-only change. A layout test would catch a hint-width break.

### 5. Step editor

**State.** `editor = {voice, step, port, alt_k2_at}` (`lib/pages/seq.lua:337`), `replacing` (`:343`), `views.editor.anchor` (`:437-440`). On the grid side: `step_editor.key` (`lib/grid/core.lua:248`), `step_keys`, `hold_clocks`.

**Open.**
1. A step key press records a held step and starts a 0.5 s hold (`grid/core.lua:424-427`).
2. The hold fires `open_step_editor` (`:393-397`): `pages_seq.open_step_editor` pops any open editor, sets `editor`, forgets arc ticks and pushes the owner (`seq.lua:913-920`).
3. The key is consumed, so its release toggles nothing.

**Close.**
- The key's release: `drop_step_key` → `close_step_editor_of` (`grid/core.lua:259-274`) → `close_step_editor(port)`, which closes only if that port opened it (`seq.lua:924-929`).
- K2 on the norns (`seq.lua:849`), which leaves `step_editor.key` stale until the release (harmless: `:262-263`).
- A pane change, the port's removal, or a press with no release (`:320`, `:330`, `:341`).
- Any `replace_pattern` (`end_step_gestures` `:441-451`), unless `step_editor_replacing()` is true.

**`replacing`.** A scoped flag set only inside `run_replacement` (`seq.lua:450-456`, xpcall-guarded), true exactly while the editor's own euclid, clear, ALT+K3 or randomize runs. It is a parameter passed through a module flag: its one reader (`grid/core.lua:446`) is two calls down from its writer.

**What depends on `alt_k2_at`.** The held hint (`:870-875`), `editor_animates` (`:880-882`), the hints' `k2_down` argument (`:898`), the release branch (`:850-853`), and the menu-close forget (`:889-892`). Nothing else.

**Guards.** The "step editor" invariant (the modal top equals open). No joint invariant with the grid's `step_editor.key`. Tests at `pages_seq_test.lua:1106-1298`.

**History.** #592 (no redraw over a still page), ruling 71 (its own replacement closed it), 2a411200 (a release taken by the menu left it animating), #596 (the hint). All were wrong transitions.

**Recommendation: c.** Extend "grid keys" so that `step_editor.key` implies the key is held and is a step key. I believe this holds on every path but did not run it. It crosses into grid core.

### 6. Voice hit

`voices_play` (`:740-785`): a stopped voice gets `start_voice` at the first hit with `retrigger_follows = gated`; a running one gets `retrigger`; `on_slice` hits go to `extra_note_hit`. The gate length is deduped in `gate_sent` (`:443-447`). The cache relies on the engine keeping `gateSeconds` (AGENTS.md says so), and it also tells "the last send was a step's own gate" (#639, `:467`).

**Already explicit and worth copying.** `engine_sync.retrigger` is the single door (`lib/engine_sync.lua:638-645`), enforced by a source-scan test.

**History.** #632, #639, #527: wrong transitions.

**Recommendation: a.** A four-row table (stopped or running × gated or not).

### 7. Chain

`chain.current`, `chain.next_beat` (`:146`); `chain_switched` (`:1588-1591`), `at_beat` (`:1160-1165`), `load_chain_scene` (`:1138-1150`). `current == nil` means both "no link yet" and "start from the range's first".

**History.** #738 (a walk on from an invalid scene). It was fixed by `S.lib.chance.pick` returning the move's name (ruling 36), which is a good example of making a transition's result explicit.

**UX.** The linked scene and the bars to the next link show nowhere. A start with the chain on replaces the live patterns with no undo (`:1560-1563`).

**Recommendation: d** for the code.

### 8. Fill

The latch param or holders (`lib/conditions.lua:83-134`). A holder carries its own `still` check and a 48 Hz sweep drops it (`:119-128`). This is the cleanest "held key" state in the area: copy it.

**History.** 806a43db added the sweep after a removed grid's hold never ended.

**UX.** A latched fill shows on SEQ and the grids only (ruling 9).

No invariant is needed. **Recommendation: d.**

### 9. The small ones (all d)

- **Division reset.** `play.reset_beat` (`:1612-1614`), consumed at `:1299-1305` and `:1332`. No bugs. Armed, it shows nothing (probed).
- **Step outputs.** `play.failed` and workers (`:798-831`). Ruling 38. A failure prints to maiden only, and the output stays off until the next start (probed).
- **Transport handlers.** `:1739-1746`, `:1784-1789`. Tested at `:476`. If another handler wraps Strata's after install, the closure stays chained after cleanup. I inferred this and did not test it.
- **Conditions.** `:45-78`. The order convention "every position start calls `start_position`" has three sites in one file. No bugs.
- **SEQ views.** `edit_open` (`seq.lua:703`) persists across page changes. Fine.
- **Arc carry targets.** `lib/arc/seq.lua:39,101`. Fine.
- **Random sequences.** `position`, `count` (nil means "first reading"), `first_load` and `drew` (`lib/random_sequences.lua:65-70,281`). 3463f4d3 was a missing transition. `new` overwrites sixteen hand-set values with no undo (`:139-144`).
- **`S.seq_euclid`.** It is never cleared, so the row shows the last fill after a clear or a recall (`seq.lua:507`).
- **`restart_voice`.** Public, unguarded, with no caller outside the module and its tests. Called while stopped it would break the invariant.

### Pattern checks asked for

1. **Retire.** See section 3. The gap is the grid's hold clock.
2. **Flag meaning.** `:1513` assumes the flag spans a time in which a user can turn the euclid row. Its writer holds it only across a synchronous loop. The three `euclid` callers (`seq.lua:578`, `seq.lua:980`, the module itself) are never inside that loop. `load_chain_scene` does not set the flag either.
3. **Fields holding two facts.** `state.retired`, `chain.current`, `gate_sent`, a `holders` value (`true` or a check function), and `event.first` (hit 1, and "apply the holds").
4. **Press-time mark.** See section 5.

### Edges into other areas

- **Quantize:** the armed start.
- **Grid core:** the hold clock and `step_editor.key`.
- **Notes and MIDI:** slot 1 ownership (`other_owns_slot_1` `:511-518`, `keeps_own`).
- **Mutation:** `note_pattern_edit` ends the pattern undo.
- **Scenes:** `next_slot`, `playable_slots`, and the recall flag.
- **Engine:** `gateSeconds` kept for a stopped voice.
