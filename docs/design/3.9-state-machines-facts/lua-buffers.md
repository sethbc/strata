# Facts: the state machines of buffers, recording, files and positions (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

## Summary

| # | Machine | Owner | States | Transition bugs | Invariant / States table | Pick | Confidence |
|---|---|---|---|---|---|---|---|
| 1 | Slot content and take (with the load-report protocol) | `lib/buffers.lua`, `lib/record.lua` | 10 statuses, about 16 real | #163 #171 #244 #246 #247 #311 #317 #399 #400 #401 #455 #457 #578, plus 4 unnumbered 3.2 fixes | yes / yes (statuses, not events) | (c), plus 4 invariant lines | high for (c), low for (b) |
| 2 | Grid held keys (positions) | `lib/positions.lua` | 5 sub-records per port | #221 #239 #445 #733 #851 | none of its own (grid core's "grid keys") / store only | (c) | medium |
| 3 | Slot clock: one handle, three roles | `lib/record.lua:17` | nil / take timer / fallback / check notice | #171 → #317, #457 | no / no | small (b) | medium |
| 4 | buffers.data persistence, and samples.data's twin | `lib/buffers.lua:896-974`, `lib/samples.lua:124-198` | 5 | #72 #301 #327 #466 #566 | no / prose | (b), cross-area | medium |
| 5 | Settings binding | `lib/samples.lua:117-289` | nil / OWN / entry | 2 review rounds, unnumbered | no / no | (a) plus an invariant | medium |
| 6 | Scrub glide | `lib/positions.lua:53, 111-335` | idle / waiting / gliding | #515 #517 | no / no | (a) plus an invariant | medium |
| 7 | Transients analysis protocol | `lib/slices.lua:57-62, 144-337` | idle / awaited / read due / held | none filed; one found here | no / no | one guard, then (a) | high |
| 8 | Waveform peaks | `lib/waveforms.lua:27-36` | none / awaiting / marked / shown | #401 (two fixes) | no / no | (a) | medium |
| 9 | Start reload | `lib/buffers.lua:451-459, 1239-1256` | 2 | #244 #245 | yes / prose | (d) | high |
| 10 | Slice editor modal | `lib/ui/slice_editor.lua:74` | closed / markers / rows | none | no (zones and scale editors have one) / prose | one invariant | high |
| 11 | Scan hold | `lib/positions.lua:142-155` | 2 | #238 | yes / yes | (d): the pattern to copy | high |
| 12 | Save, take-write, recalled bookmark, playhead mirror, follow, loop pair, file selector, input polls | various | small | #127 #246 #522, #312, #240 #431 #593, #739, #167, #435, #438 | mixed | (d) | high |

The five things most worth knowing:

1. **The slot machine is already half explicit, and that half did not stop the bugs.** It has a derived `status()` (`lib/buffers.lua:1180`), a States table and the "buffer slots" invariant. Of its bugs, only #163 and #400 were illegal states (and #300's `take 3.0` name, which is not a transition bug); the rest were wrong transitions between legal states. What is missing is a status × event table and a test driven by it, with the engine's 13-row table (`docs/notes/engine/record.md:60-74`) as the shared spine.
2. **Do not replace the fields with one state value.** About 160 test assertions read them raw, the failed-load undo copies them (`shown_state`, `apply_buffer_state`), and matron's one-float polls force Lua to infer the engine's state. Five layered guards on a load each exist for a separate race.
3. **The #626 "retire, never cancel" rule is absent from this area.** `cancel_timer` (`lib/record.lua:25`) is called from poll callbacks at the moment the take timer expires, which is the #457 race by construction. The start reload and the glide clock are also canceled from handlers. This is inferred from the code and not probed.
4. **Four UX gaps, confirmed by a probe test (`probes.md`):**
   - A "missing" slot draws exactly like an empty one, and fill loads over it.
   - Every buffer flash is BUFFER-only, so an overdub refused from the grid on another page does nothing visible.
   - A playable recording has no fallback without `recordState`.
   - Each sensitivity detent during an analysis sends another `analyzeBuffer` (6 calls for 5 detents).
5. **`S.buffer_file.problem` holds two facts**, as `S.scene_file`'s does. A failed write overwrites "unreadable", and the next good write clears it, so the "kept as .bak" row disappears. The debounced writer is hand-written twice here although `lib/side_files.lua` exists (#648).

## Full report

Method: the fourteen modules, their notes, both engine notes files, git history and issue titles and bodies. The probe was a scratch test file run with `lua test/run.lua --dir`; nothing in the repo changed. "P1" to "P5" below are its results.

### 1. Slot content and take

**Owner.**
- State: `S.buffers[slot]`, 24 fields (`lib/buffers.lua:73-80`), and `takes[slot]` (`lib/record.lua:19`, read through `M.state`, `:242`).
- Transitions in `lib/buffers.lua`: `load_buffer` (462), `clear_buffer` (509), `settle_buffer_slot` (198), `confirm_buffer_audio` (163), `apply_buffer_state` (337), `buffer_state_changed` (752), `buffer_load_failed` (852), `take_write_failed` (701), `recording_started` (1219), `restore_buffers_from_file` (986).
- Transitions in `lib/record.lua`: `record_buffer` (149), `finish_buffer_take` (46), `record_state_changed` (287), `slot_reported` (269), `take_started` (128).

**States.** `status()` gives ten: finishing, armed, recording, dub, loop, loading, loaded, unsettled, missing, empty (`:1180-1196`). The real set is larger:
- loading is three (plain; `awaiting_zero`; `checking_from`), each with or without `restoring`;
- armed is three (replace unprepared with old audio still playing; replace prepared; playable);
- finishing is two (recorded; stopped while armed);
- empty is three (plain; `kept_state` awaiting the next length; `settled_empty == "take"`, adoptable).

The check order in `status()` is itself a rule (finishing before armed, a 3.3 ruling, `docs/decisions/3.3.md`).

**Representable but meant impossible.**
- Enforced by the invariant (`:1136-1169`): finishing without recording; `kept_state` while recording; `checking_from` or `awaiting_zero` without `confirm_since`; `settled_empty` with `loaded`; `start ≠ sent_start` with no reload pending.
- Not enforced: `recording` with no take; finishing with a playable take; `missing_path` with `path`; `restoring` without `confirm_since`; `take_unsaved` on a slot holding a file.
- `takes[slot]` is not cleared when a replace take settles or a load supersedes it; only `M.state`'s `recording` gate hides the stale entry (`lib/record.lua:243`).

**Events and transitions.**

| Event | From | To |
|---|---|---|
| `load_buffer` (K2, file param, random, fill, restore, start reload) | any, finishing included | loading. Snapshots `previous`: the shown state; the empty "take" state during a replace take; `{after_cancel, kept}` during an armed one (`:281-292`) |
| `clear_buffer` | any | empty; `pending_loads` emptied |
| `record_buffer` | finishing | ignored |
| | recording, replace | `stopRecord`, finishing |
| | recording, playable | `stopRecord` only; waits for a report |
| | loading, playable params | refused, flash (#455) |
| | otherwise | armed or recording; `previous` kept for a replace take |
| take timer | recording, replace | finishing |
| `recordState` armed / recording | newest take only | phase; the timer starts for a replace take |
| `recordState` ended | playable | loaded as `take <n>` |
| | replace | finishing, then settled at once if a length is known (#457) |
| `recordState` canceled | replace | empty with `kept_state` |
| | playable | fields untouched |
| `bufferState`, other load number | any | ignored (#578) |
| `bufferState`, audio | `kept_state` | kept state applied |
| | loading plain | loaded |
| | `awaiting_zero` | nothing |
| | checking, same length | nothing |
| | checking, differs | check ends, then settles |
| | finishing, recorded | loaded |
| | finishing, stopped armed | nothing |
| | unsettled, or empty "take" | adopted |
| `bufferState`, 0 s | `kept_state` | dropped |
| | `awaiting_zero` | plain loading |
| | loading or finishing, 1 s after the change | unsettled, or empty "take" |
| `bufferLoadFailed(n)` | newest tracked load | its resolved `previous` applied |
| | older tracked load | spliced into the next load's `previous` |
| | untracked | ignored |
| `takeWriteFailed(n)` | newest recording | `take_unsaved`, or the path dropped |
| fallback, 5 s | finishing | settled from the last seconds |
| check notice, 30 s | checking | flash only |

**Outside writers.** Two layout states only: `lib/pages/scenes.lua:374` sets `recording = true` with no take, and `lib/pages/setup.lua:551` sets `missing_path`. On a slot left recording with no take, K3 sends `stopRecord` on every press and nothing ever ends it (inferred from `lib/record.lua:154-161`).

**Outside readers of raw fields.**
- `lib/ui/header.lua:57` (`recording`, phase).
- `lib/pages/buffer.lua:380, 418, 443, 455, 741`.
- `lib/pages/setup.lua:216`.
- `lib/slices.lua:366-367` (`records_sent`, `path`).
- `lib/samples.lua:258, 360`.
- `lib/files.lua:29, 121, 145`.
- `seconds` in playheads, scan, bookmarks, waveforms, positions and `lib/pages/seq.lua:971`.
- Through the accessors: `lib/grid/core.lua:562, 582`, `lib/grid/pages/sources.lua:118`, `lib/files.lua:153`.

**Guards.**
- Tokens: `loads_sent`, `records_sent`, `saves_sent`, each counted alike in the engine.
- The 1 s `confirm_seconds` rule compares wall-clock time; it is not a token.
- Tests: `test/unit/buffers_test.lua` (2,536 lines) and `record_test.lua` (863 lines), all scenario by example. One status walk exists (`buffers_test.lua:2078`). The engine's table rows 6, 7, 9, 10 and 11 are covered by name; no test enumerates status × event.
- Notes: 31 Must-not-break bullets in `docs/notes/lua/buffers.md` and 17 in `record.md`, about 7,200 words with the engine's 10,500 behind them.

**History.**
- 3.2 (`243d39a3`, 2026-11-03): a Lua timer only.
- `34f09418`: engine-confirmed takes (`finishing`, `confirm_since`, `restoring`).
- `9cde2e95`, `71c9d5d9`: late adoption (`settled_empty`) and the fallback.
- `3ff9a46b`: failed loads undone (`pending_loads`).
- #171: `checking_from`.
- 3.3 (`71401ad9`): takes with kind and phase.
- #311: `kept_state`. #312: `take_unsaved`. #401: `awaiting_zero`. #578: load numbers.

**The bugs.**
- Late or stale report acting on newer state: #401, #457, #578, #317 (Lua gave a check up at 30 s while the engine went on).
- Wrong snapshot for the undo: #399, #400, #311.
- Missing reset or wrong branch: #163, #244 (`state()` is nil until `recording` is set, so the wrong branch ran).
- Missing refusal: #246, #455.
- Three readers deriving "empty" differently: #247.
- Related, in machines listed under section 12 below: #245 (start reload snapshot), #312 (take write).

Only #163 and #400 were illegal states; the invariant catches neither class of the rest. (#300's `take 3.0` name was also an illegal state, from an unfloored poll value, not a transition.)

**Why this shape.** matron hands Lua one float per poll, and the project never asks upstream for changes. So Lua infers the engine's state from length reports. Each of the five load guards covers a separate race:
- the load number modulo 7;
- `awaiting_zero`;
- `checking_from`;
- the 1 s rule;
- adoption of a slot that settled empty.

The notes say why none can go (`docs/notes/lua/buffers.md:20`). A refactor that folds them into one "loading" state would regress one of them.

**What the user sees.**
- BUFFER row: `ARM`, `REC`, `DUB`, `LOOP`, `...`, or a length.
- Hint row: `K3:rec`, `stop`, or `...`.
- Header: REC or ARM.
- Grid record key: 2, 8, 11 or 15.

Gaps:
- **A missing slot is invisible per slot.** P2: status `missing`, row text `1 | -`. SETUP counts them and only the console names the path. Fill treats the slot as free and forgets the path (`lib/files.lua:153`).
- **Every buffer flash is BUFFER-only** (`lib/pages/buffer.lua:121`, `lib/ui/flash.lua:4`). P3: an overdub refused from the grid while MAIN shows sends nothing and shows nothing. `load failed`, `take not saved`, `still checking` and save results are silent off BUFFER.
- **A playable recording has no fallback.** P4: after two K3 presses and 30 s with no `recordState` report, the status is still `dub`. This is reachable only when the poll is missing.
- A stopped armed take reads `ARM` on screen and 15 on the grid (P5). This is an accepted ruling.
- A check the engine never ends stays at `...` until the player loads or clears.
- `unsettled` is a dim name with `0.0s` and no word.

**Pick: (c).** Write a status × event table in `docs/notes/lua/buffers.md`, and a test that walks it: for each reachable sub-state and each event, the next status and the invariant. A docs test should compare the notes' rows with the test's, as docs tests already do for the poll encodings. Add four invariant lines: finishing implies a replace take; `missing_path` implies no path and not loaded; `restoring` implies `confirm_since`; `recording` implies a take (the scenes layout state would then need a real recording).

- Cost: one test file and a notes section; no behavior change.
- What could break: nothing at run time. The table could be wrong, and the test would then fail on the first run.

(b) is not recommended: the raw-field assertions, the snapshots and the five guards make a rewrite a likely regression for no visible gain. Bug count 13 numbered and 4 unnumbered (17), not counting the three related ones; blast radius is every buffer voice, buffers.data and the settings binding.

### 2. Grid held keys in positions

**Owner.** `S.lib.grid_core.port_state(port).positions` (`lib/positions.lua:347-354`): `held`, `hold[v]` and `store[v]` (sets of views), `pressed[v]`, `bank[v]`, and `slices[v][cell]` entries `{n, pane, view, token, released}`. Transitions: `grid_key` (567), `strip_key` (599), `press_slice_key` (430), `end_slice_key` (449), `end_stale_port` (484, swept by the 15 Hz playhead tick).

**States.**
- Each key is up or down per view.
- A slice key adds: waiting for the beat; released while waiting (`released`, played later in one shot); playing.
- Illegal: a record kept for a port whose grid left. The sweep ends it within a tick.

**Guards.** Grid core's "grid keys" invariant (other area). A States table exists for store only. Tests by example (`positions_test.lua`, 1,433 lines).

**Bugs.** All wrong transitions (a release or a stale view ending the wrong owner's key): #221, #239, #733, #851, 2e's review, and `c624997c`. #445 was a missing refusal.

**Seen.** LEDs only: 11 held, 15 playing.

**Pick: (c).** A small table test of press and release per key kind, pane and stale view.
- Cost: low.
- Edges: grid core (`view`, `existing_port_state`), quantize tokens, `S.lib.slices`.

### 3. The slot clock

**Owner.** `S.buffer_record_clocks[slot]` (`lib/record.lua:17`) holds, by turn:
- the take timer (`:135`);
- the finishing fallback (`:50`);
- a long load's check notice (`lib/buffers.lua:379`).

Nothing records which role it has. `lib/record.lua:305` reads "no clock" as "no take timer yet", which holds only because `record_buffer` cancels first (`:177`).

**Guards.** No invariant, no table.

**Bugs.** #171 added a fallback that #317 had to remove. #457 was the timer racing the "ended" report.

**Pattern 1 applies.** `cancel_timer` is plain `clock.cancel` (`:27`), called from `record_state_changed` and `buffer_state_changed`, both poll callbacks, at about the moment the take timer's sleep ends. That is #626's shape: a resume may already be posted. Inferred, not probed; the effect would be a maiden line.

Since `recordState` exists, the Lua take timer is a second source of the end; it creates the "finishing" window in which K3 is ignored. It is still needed when the poll is missing.

**Pick: small (b).** Store `{id, role}` and retire the clock where its resume may be posted, as `lib/quantize.lua:59-76` does.
- What could break: tests that read the clock ids from `S.buffer_record_clocks`.
- What would detect it: `record_test.lua`'s timer tests.

### 4. buffers.data persistence, and its twin

**Owner.** `S.buffers_loaded`, `S.buffer_autosave_blocked`, `S.buffer_file {problem, backup, text, save_clock}` (`lib/buffers.lua:896-908`). Transitions: `remember` (960), `save_buffers_to_disk` (927), `restore_buffers_from_file` (986), cleanup (1107). No outside writer; SETUP reads it (`lib/pages/setup.lua:163`).

**States.** Not loaded (never saves, #72); clean; a write pending; blocked (unreadable and not moved); "not saved".

**Pattern 2 confirmed.** `problem` holds the load's outcome and the last write's. A failed write overwrites "unreadable" (`:936`), and the next good write clears "not saved" (`:943`). So SETUP's "unreadable, kept as …bak" row vanishes after a failed then good write, while `backup` stays set. The branch that clears an unreadable problem with no backup appears unreachable from the module, since both callers return while blocked (inferred).

`lib/samples.lua:124, 176-198` repeats the same debounce by hand (`store {started, blocked, text, save_clock}`) with no SETUP row. `lib/side_files.lua` (#648) holds the shared version; neither uses it.

**Guards.** No invariant; prose.

**Bugs.** #72, #301, #327, #466, #566. Mixed: missed transitions (#327, #566) and a destroyed backup (#466).

**Pick: (b).** Split `problem` into load and write facts and move both files onto the shared writer.
- Edge: the data-files auditor's area.
- What could break: SETUP's rows and the start flash.
- What would detect it: `buffers_test.lua:2200-2300`, `pages_setup_test.lua`.

### 5. Settings binding

**Owner.** `bound[slot]` is nil, `OWN` or a file entry; `own[slot]` beside it (`lib/samples.lua:117-124`). Transitions: `bind` (253), `unbind` (284), `drop_own`, `start_take`, `take_from_file`. `settings()` also needs `seconds > 0` (236), so "bound" and "has settings" differ, as the notes warn.

**Callers.** Eight sites drive it by hand:
- `lib/buffers.lua:188-189, 217-219, 361-365, 533-534, 780-783`;
- `lib/record.lua:131, 322-323`.

It is the slot machine's shadow.

**Guards.** No invariant, no table; one prose rule ("the binding names the audio that plays"). Tests by example (`samples_test.lua`, `record_test.lua:788-863`).

**Bugs.** Two review rounds (`f00f5cec`, `73d2d259`; `docs/decisions/3.7.md:144`), all wrong transitions: when a replace take unbinds.

**Seen.** Settings appear or vanish in the slice editor. The editor closes when its slot loses its settings (`lib/ui/slice_editor.lua:146`).

**Pick: (a).** One table of slot event → bind action, and one invariant: a settled slot with audio is bound; a free slot is not. It would join section 1's table test as an extra column.

### 6. Scrub glide

**Owner.** `glide_clock`, `fling {turned_at, gliding}`, `glide_rate`, `turns` (`lib/positions.lua:53`). Transitions: `scrub_turned` (316), `glide` (287), `end_glide` (121), the bookmarks record's `sync` (868), cleanup (897).

**States.** Idle; waiting (clock, rate 0); gliding (clock, rate not 0). Illegal: a rate with no clock, which would leave the engine gliding forever.

**Guards.** No invariant, no table. #517's contained calls protect the clock.

**Bugs.** #515 (a clock per delta), #517. Both lifecycle faults.

**Pattern 1.** `cancel_glide_clock` (113) is plain cancel, called from `jump` and the grain-restart hook while the clock wakes 15 times a second. Inferred exposure.

**Seen.** Only the moving playhead.

**Pick: (a), plus an invariant** (clock present iff `fling` present; a rate implies a clock) and retiring the clock.

### 7. Transients analysis

**Owner.** `analyses`, `awaited`, `generations`, `analysis_generations`, `candidates`, `due_reads`, `reader.clock`, `due_binds` (`lib/slices.lua:57-62`). Transitions: `analyze` (144), `onsets_reported` (325), `read_onsets` (284), the bind listener (362), the step hook (373).

**States.** Idle; awaited(n); read due; candidates held.

**Guards.** Two tokens, a count and a generation. No invariant or table. `slices_test.lua` by example.

**Found here.** While an analysis is awaited, `make` on a transients slot with no candidates calls `analyze` again (`:189-192`). So every mode or sensitivity detent in the editor sends a pass. P1: one call after `make`, six after five detents. The engine reports every pass exactly once (`docs/notes/engine/onsets.md`) and only the newest acts, so the result is right. The cost is repeated passes over a slot of up to 300 s (cost not measured).

A failed pass shows nothing (`:334`): the label only stops saying `analyzing`.

**Pick.** One guard (awaited at the same generation: do not resend), then (a).
- What could break: a pass that should rerun after the audio changes. The generation check covers that.
- What would detect it: `slices_test.lua:219-225, 248-258`.

### 8. Waveform peaks

**Owner.** `points`, `marked`, `awaiting`, `playable_due` (`lib/waveforms.lua:27-36`). Transitions: `forget` (139), `changed` (150), `stale` (117), `read` (91), the tick (215).

**States.** None; awaiting a load; marked; shown.

**Callers.** Six sites in `lib/buffers.lua` and `lib/record.lua`, again the slot machine's shadow.

**Guards.** No invariant, no table. Prose rules; one test checks that `io.open` waits for the clock.

**Bugs.** #401 twice (the old overview shown for new audio): wrong transitions.

**Pattern 1.** Its clock is canceled only at start and cleanup: no exposure.

**Pick: (a).** A three-row table. Low value otherwise.

### 9. Start reload

**Owner.** `start` against `sent_start`, and `start_reload_clocks[slot]` (`lib/buffers.lua:451-459, 1239-1256`).

**Guards.** In the invariant (`:1164`); prose in the notes.

**Bugs.** #244, #245: wrong transitions (a wrong snapshot, a wrong branch).

**Pattern 1.** `cancel_start_reload` runs at every E3 detent, 0.3 s after the last. Inferred small exposure.

**Pick: (d),** apart from retiring the clock.

### 10. Slice editor

**Owner.** `editor {open, slot, marker, view, row}`, `pending_key`, `binds_heard` (`lib/ui/slice_editor.lua:74-79`). Transitions: `open` (154), `close` (165), `enc` (541), `key` (563), the bind listener (146), the note hook and step (612-624).

**States.** Closed; markers; rows.

`editor.open` duplicates the modal stack (`S.lib.ui_modal`). Nothing else pops its owner today (grep of `ui_modal.pop`).

**Guards.** No invariant, though the zones and scale editors have one (`lib/ui/zones.lua:286`). Views in prose.

**Bugs.** None filed.

**Seen.** Fully.

**Pick.** Add the invariant: open iff its owner is on the stack; open implies the slot has settings; `pending_key` only while open.

### 11. Scan hold: the pattern to copy

`holders[v]`, a set, and `scan_hold[v]` (`lib/positions.lua:53`), changed only through `hold_scan` (142). It has a States table (`docs/notes/lua/positions.md:51-65`) and the "scan holds" invariant (`:907`).

One bug, #238 (several holders behind one boolean): an illegal-state design fault. Fixed by the set, and nothing since. The accepted exception (a voice sync drops a hold whose key is down) is written down.

What made it work: a single transition function, a named owner per holder, and an invariant that states the encoding.

**Pick: (d).**

### 12. Small machines: (d) for each

- **Save protocol** (`saves_sent`, `pending_saves`; `lib/buffers.lua:567-690`).
  - Bugs: #127 (said saved before the report), #246, #522.
  - Sound now. No invariant; prose.
  - Gap: no standing "saving" cue after the 1.5 s flash on a long save.
- **takeWriteFailed** (`take_unsaved`, `:701`).
  - Bug: #312.
  - Acts on the newest recording only.
- **Last recalled and waiting bookmark** (`recalled[v] {bookmark, source}`, `waiting_recalls[v] {n, token}`; `lib/positions.lua:204-230`).
  - Bugs: #240, #431, #593, wrong transitions.
  - Has a States table; the quantize token is the guard.
  - The wait shows as a header flash and a grid blink.
- **Playhead estimate** (`heads[v]`, `lib/playheads.lua:27`).
  - An order-of-calls convention: `advance` before the hold or rate changes; `reset` wherever the engine restarts its scan. Six call sites.
  - Bugs: "one restart a hit" (`98bce41c`), #322's first look.
  - No invariant is possible in Lua alone. Its clock has a small States table.
- **Follow and bar sync** (`applied[v]`, `last_bar`; `lib/scan.lua:112, 158`).
  - Bug: #739, a transition that ran no hook.
  - Derived each step; fine.
- **Loop pair.**
  - A scene sets the length before the start, so the length's filter stands down on two scenes flags (`lib/loops.lua:62-74`).
  - Bugs: #167, #531.
  - Edge: the scenes area.
- **File selector** (`file_selector_open`, callback, saved `key` and `enc`; `lib/pages/buffer.lua:103-106, 830-902`).
  - States: closed, open, superseded by the menu.
  - Readers: `strata.lua:341`, `lib/ui/menu_watch.lua:43`.
  - Bugs: `0e941357`, `042687cb`, #435.
  - No invariant; long prose.
  - An invariant (open iff callback and saved handlers set) would be cheap.
- **Input polls** (`state.started`, the poll objects; `lib/input_level.lua:21`).
  - Has the "input level" invariant.
  - Bug: #438 (stale poll objects).
  - Well kept.
- **BUFFER held keys (pattern 3)** (`pressed_at`, `lib/pages/buffer.lua:701`, with a States table in the page's notes).
  - In my area, K2 load or clear, ALT+K2 random or fill, ALT+K3 save or save loop, the hold hint and `buffer_animates` depend on it.

### Constraints on any refactor

- **Lua's local limit.** `lib/buffers.lua`'s constructor has 34 top-level locals, so room is not the issue.
- **Never params, scenes or PSETs.** The scan hold, the glide, the last recalled bookmark, the bank, the candidates and the follow rate. The record params are PSET-only.
- **Names the tests reach.** `S.finish_buffer_take`, `BUFFER_SETTLE` as its upvalue, `M.start_reload_clocks`, `M.read_clock`.
- **File formats.** buffers.data version 3 with floor 2; samples.data version 1.
- **Listeners.** They send nothing and never yield, so effects wait for the next LFO step.
- **The counts.** They must equal the engine's and never reset.

### Edges into other areas

- Engine record and buffers (the state table, `slotChanges`, the numbering).
- `S.lib.notes` (own region, `end_regions`).
- Quantize tokens.
- Grid core's port state and views.
- `ui_modal` and `ui_flash` (page-owned flashes).
- The scenes' recall flags and data folder.
- `data_files` and `side_files`.
- `engine_sync` (voice sync hooks, grain restart).
- The LFO step hook.
- Performance (slot index 8 of `bufferState`).

### Not verified

- The #626 exposure of the three clocks: read from the code, not probed.
- The cost of repeated analyses on a device.
- The unreachable branch at `lib/buffers.lua:943`.
- The stuck recording-without-take slot.

One `gh` call (the open-issue list) timed out, so open issues were not checked.

The probe file and its output are in `probes.md` (`probe_test.lua`, `out.txt`).
