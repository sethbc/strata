# Facts: the state machines of grid and arc (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

## Summary

| # | Machine | Owner | States | Transition bugs | Rec. | Conf. |
|---|---|---|---|---|---|---|
| 1 | Positions page's held keys against the pane lifecycle | `lib/positions.lua:337-647`, `lib/grid/pane.lua:289-302,364-367` | 5 record kinds, each up/down | #221, #239, #733, #851, plus one live bug found here | (b), small | high |
| 2 | Per-key lifecycle (held, hold clock, consumed, role) | `lib/grid/core.lua:159-353` | up, plus held × 4 attributes | #114, #242, #620, roles (`cace710e`), moved-grid hold (`e7a8a9c7`) | (c) | high |
| 3 | Step gesture and step-editor key | `lib/grid/core.lua:243-463` | 5 per key | #242, #450, ruling 71, #630 | (c) | medium |
| 4 | Arc carried ticks and their context | `lib/arc/core.lua:97-118` and four page files | carry bound to a context | none filed | (b), small | medium |
| 5 | The 64's chooser | `lib/grid/pane.lua:218-302` | closed, armed, open | the live bug in 1 | (a) | high |
| 6 | Grid port attachment | `lib/grid/core.lua:621-871` | 4 | #256, #323, #468, #700 | (d) | high |
| 7 | Followed arc | `lib/arc/core.lua:123-265` | 3, × virtual waiting | #13, #49, #256, #437, #468 | (d) | high |
| 8 | BUFFER ALT scan hold on the arc | `lib/arc/buffer.lua:35-78` | none, holding, dropped | #238 review, `4b7ba518` | (a) | medium |
| 9 | Redraw gating by signature | `core.lua:876`, `faders.lua:180-194`, `playheads.lua:243-253` | latch plus last-seen | #161, #322, #324, #441 | (d) | high |
| 10 | Strip and page key modes (fill, tempo, NV, SV, CL/RN, PC/VC, macros) | `pane.lua`, `pages/*.lua` | 2-3 each | #618, #619 | (d) | high |

The five things most worth knowing:

1. **There is a live transition bug on the 64.** A positions key released while the chooser shows is swallowed (`lib/grid/pane.lua:364-367`, `235-236`). If the chooser closes on the same view, the positions record never ends. A probe showed a stale anchor turning the next tap into a loop, and a scan hold that stayed held with every key up. No issue exists for it.
2. **Its cause is two held-key mechanisms.** The core ends keys by push (`end_pane_keys`, `core.lua:308`). Positions keeps parallel records and polls for a stale view string (`lib/positions.lua:476-524`). The chooser opening is a core event that never changes the view. The fill holder's `still` predicate (`pane.lua:311`) already derives liveness from the core's role table; positions should use it too.
3. **Every bug in this area was a wrong transition between legal states.** #450 is the only case of an unreachable state, and it was dead code. The "grid keys" invariant (`core.lua:982`) catches illegal states only, and it omits `step_keys` and `step_editor.key`. Neither the grid nor the arc has model coverage, and the random probe that settled #450 was thrown away.
4. **The grid's hold clocks cancel while sleeping** (`core.lua:224`, `280`), the shape #626 retired in gestures, quantize and morph. The token is already there (`core.lua:236`), so retiring means dropping two `clock.cancel` calls. `lib/arc/` has no clock or metro.
5. **Waiting states are invisible on the grid, and a second press cancels them.** The play key reads only `S.pattern_playing` (`core.lua:524-526`) and FZ reads only `is_frozen` (`pages/voices.lua:129`). A waiting scene recall, jump or loop is unlit too. No file under `lib/grid/` calls `set_ui_page`.

---

## Full report

Coverage legend used below: Inv is a registered invariant, Tbl is a States table in the notes, Mdl is model or random-walk coverage.

### 1. Positions page's held keys against the pane lifecycle (edge to the positions audit)

**Owner.** The records are `port_state(port).positions = {held, hold, store, pressed, bank, slices}` (`lib/positions.lua:339-354`). Transitions are `grid_key` (567-594), `strip_key` (599-647), `end_stale_port` (484-519) and `end_stale_holds` (522), polled from the playhead clock at 15 Hz (`lib/playheads.lua:236,257`). The grid page only forwards keys (`lib/grid/pages/positions.lua:44-47,76-82`).

**States.** Each record is up or down. Each down record carries the pane and the `view` string it was pressed on (`core.lua:107-110`). A record is stale when the port's state is gone or the view differs (`positions.lua:476-478,485-486`).

**Events.**

| Event | What ends the record |
|---|---|
| Key release | `grid_key` or `strip_key` with z 0 |
| Page, side or half change | view differs, at the next tick or key |
| Unplug, rotation, reconcile | port state gone (`gone`) |
| **Chooser opens** | **nothing** |

**The bug (probed).** The chooser opening calls `end_pane_keys(port, 1)` (`pane.lua:292-296`), which ends the core's step keys, holds and roles. While it shows, every pane key goes to `chooser_key`, which returns on z 0 (`pane.lua:364-367,235-236`). The page never sees the release, and the view is unchanged if NV comes up with no pick or the same pick. Results from the probe at `probes.md` (run with `lua test/run.lua --jobs 1 --dir <that folder> probe_chooser`):

- **A.** Hold cell 3, open the chooser, release cell 3, release NV, tap cell 6. The loop becomes start 0.125, length 0.25 instead of a jump. This is #733's symptom.
- **B.** Hold HD, same sequence. `scan_held(1)` and `holds_scan(1, "grid:1")` both stay true with all keys up.
- **C.** SV, which uses the core's roles, behaves correctly.

A held slice key should follow the same path (`positions.lua:446-460`); I inferred that and did not probe it. The user recovers by pressing and releasing the same key again, by changing the view, or (for the hold) by restarting the voice. `docs/notes/lua/grid/pane.md:57` says "The chooser opening ends the pane's held keys, as a page change does", so the code breaks a written rule. `test/unit/grid_pages_positions_test.lua:540` covers only the case where the view changes.

**Guards.** Inv: "scan holds" (`positions.lua:907`), positions' own. Tbl: yes (`docs/notes/lua/positions.md:81-89`). Mdl: none. Tests are by example.

**History.** The records and the poll date from 3.3 (`c4052fde`, 2026-11-09). That is before the core's roles (`cace710e`, 3.4) and before `end_pane_keys` (`da566cee`, 3.8). 3.8 added the view tag (`011215c8`) rather than moving to the core's mechanism; the decision "1m's set of views per voice stands" is at `docs/decisions/3.8.md:287`. Bugs: #221 (release went to the grid voice at release time), #239 (store after a voice change), #733 (the same on the 64), #445, #851 (view parsed as text). All were wrong transitions.

**Can it use the fill holder's pattern?** Yes. Fill passes `still = function() return pressed_as(port, px, py, "fill") end` (`pane.lua:311`), and `lib/conditions.lua:107-123` drops a holder whose `still` is false. The core clears a role at release, a new press, `end_pane_keys` and `forget_port` (`core.lua:286-299,322,283,344,352`), so one predicate covers every way a key ends, the chooser included.

**Recommendation: (b), small.** The page marks each press with `pane.press_as(x, y, role)` and passes `still`. Positions keeps `still` in place of `view` and its tick tests it. This removes `view_of`, `stale_view` and the `gone` test.

- Cost: about 40 lines in `lib/positions.lua`, 6 in the page, and the tests that name views.
- What could break: a 256 with both panes on positions. Each pane's key is a different physical key, so a set of `still` predicates replaces the set of views.
- Detection: the existing 24 page tests, plus three new ones from the probe.
- Constraint: positions must not name a physical key. It does not; the page builds the closure.

Bug history 5 including the new one; blast radius one page on every layout; confidence high.

### 2. Per-key lifecycle in the grid core

**Owner.** `S.grid_held` (`core.lua:165`) and the locals `hold_clocks`, `consumed_keys`, `step_keys`, `port_states` (166-169) and `key_roles` (173). Transitions: `press_key` (339), `release_key` (348), `on_hold` and `cancel_hold` (221-241), `consume` (199), `press_as` (290), `end_pane_keys` (308), `end_port_holds` (278), `forget_port` (328), `handle_key` and `grid_key` (878-915).

**States.** A key is up, or held with any of: hold pending, consumed, role, step entry. Five sparse tables are keyed alike. A key with any attribute but not held is representable and meant to be impossible; the invariant checks this for three of the tables (`core.lua:995-1005`) and omits `step_keys` and `step_editor.key`. `held_step` re-checks `held` defensively (`core.lua:380`).

**Events.**

| Event | Effect |
|---|---|
| Press | every attribute reset, then held |
| Release | hold canceled; layout called unless consumed; step toggled; all cleared even if a handler raised (#620, `core.lua:905-909`) |
| Hold clock fires | token check, entry cleared, `fn` runs |
| Page, side or half change, or chooser open | step entries, holds and roles of that pane's keys end; held and consumed stay |
| Unplug, plug, reconcile, rotation, size change, cleanup | everything of the port goes |

**Outside access.** There are no outside writers. `S.grid_held` appears nowhere under `lib/` outside the core. Tests reach `grid_held` five times and write it once (`test/unit/grid_core_test.lua:405,847,901-902,1382`). The other tables are reached only through behavior.

**Guards.** Inv: "grid keys" (partial). Tbl: the step gesture only (`docs/notes/lua/grid-core.md:97-119`); the general key is prose (lines 81-91). Mdl: none. There are 73 scenario tests.

**History.** Held keys and holds arrived in 3.1 (`fd8cc581`). Bugs, all wrong transitions:

- #114: only the paste ended gestures.
- #242: clear, randomize, a scene recall and the half switch left a gesture alive.
- `e7a8a9c7`: a moved grid's pending hold was not canceled.
- `cace710e`: a key pressed on another page acted at release, which is why roles were added.
- #620: a raising release left the key held.

#450 removed `order` and `press_count`, which encoded an unreachable state. Since the 3.8 pane rewrite the only failure is the one in machine 1.

**Clocks and #626.** `cancel_hold` (`core.lua:224`) and `end_port_holds` (280) call `clock.cancel` on a sleeping coroutine. If the sleep's resume is already posted when a release or page change cancels it, #626's text says maiden prints `bad argument #1 to 'resume'`. I inferred that it is reachable here and did not probe it. The tempo repeat's 0.1 s clocks (`pane.lua:267-272`) make the window recur while a key is held. The token already exists (`core.lua:236`), so retiring means clearing the table entry without canceling. The cost is a coroutine that sleeps up to 0.5 s longer, and a retired list if cleanup or a test must see none live, as `lib/gestures.lua:131,765-770` does. `lib/arc/` has no clock or metro (grep).

**Recommendation: (c).** One record per key in place of the five tables would make the illegal state unrepresentable. The illegal state has never been the bug, though, and the blast radius is every grid press. Instead:

- Add `step_keys` and `step_editor.key` to the invariant.
- Keep a seeded random walk over press, release, clock advance, page change, chooser, replace-pattern and unplug on the four layouts, with a small model of "what a release does", in the style of `test/notes_model.lua`. The #450 probe ran 36,000 such events once.
- Retire the hold clocks.

Cost: one test file and about 10 lines. Risk: none to behavior. Bug history 5; blast radius all grids; confidence high.

### 3. Step gesture and step-editor key

**Owner.** `step_keys` entries and `step_editor.key` (`core.lua:248`). Transitions: `step_key` (410), `open_step_editor` (393), `release_step_key` (360), `drop_step_key` (269), `end_step_gestures` (441), `end_port_step_gestures` (457). SEQ's side is `editor = {voice, step, port}` (`lib/pages/seq.lua:914-929`).

**States.** Not a step key; held step waiting; held step leveled; held step editing; level key. The table at `docs/notes/lua/grid-core.md:101-119` is accurate against the code.

**Guards.** Inv: none joint. "step editor" (`lib/pages/seq.lua:946`) ties `editor` to the modal stack only. Tbl: yes. Mdl: none. Tests run against the real editor since #630.

**The joint state.** The grid is the only runtime opener (`core.lua:394`; the three other callers at `lib/pages/seq.lua:1097-1112` are layout states, inferred from their place in the file). Legal combinations:

- Key set, editor open on the key's port.
- Key set, editor closed (K2 closed it on the screen; the release then closes nothing, `core.lua:259-264`).
- Key nil, editor closed.

"Editor open with no key naming a held, consumed step key on `editor.port`" should be impossible and is unchecked. The core's side of that invariant is three lines.

**The push over another owner (item 2 of the handoff).** After 0.3 s the hold calls `S.lib.pages_seq.open_step_editor` unconditionally (`core.lua:393-397,425-427`). It never asks `S.lib.ui_modal.top()`. If the slice editor, voice picker, scale editor, zones editor or name entry is up with K2 or K3 down, the step editor is pushed on top. `ui_modal.key` then drops that key's release, because the press owner is no longer the top one (`lib/ui/modal.lua:75-87`). When the grid key comes up the step editor pops (`core.lua:263`) and the first owner is on top again, having seen a press and no release. What that owner does with it is the UI audit's question. From the grid side the transition has no guard and no test (grep of `grid_core_test.lua` for modal shows only the step editor's own owner). The choice is to refuse the open while another owner is up, or to document that the step editor may cover it. Refusing is one line and changes behavior only in that overlap.

**History.** The release toggle and editor came in 3.4 (`f6a81259`). Ruling 71 (`6cc55063`) made the editor survive its own replacements. All bugs were wrong transitions.

**Recommendation: (c).** The joint invariant, and one test of the open-over-a-modal path whichever way it is decided. Bug history 4; blast radius patterns page and SEQ; confidence medium, since the right behavior over a modal is a product call.

### 4. Arc carried ticks and their context

**Owner.** `S.arc_ticks[key]` with `arc_whole_steps` and `forget_arc_ticks` (`lib/arc/core.lua:97-118`).

**The implicit rule.** "Carried ticks belong to what they were turned on" (`docs/notes/lua/arc-pages.md:17`). It is implemented six ways:

- A blanket forget on a page change (`lib/ui/keys.lua:74`), on the step editor opening or closing (`lib/pages/seq.lua:917,927`) and on the slice editor opening (`lib/ui/slice_editor.lua:160`).
- A pushed forget from the LFO page and the mode action (`lib/pages/lfo.lua:184-186`, `lib/lfos.lua:924`).
- Four pulled context tags in page locals: `carried_param[n]` (`lib/arc/voice.lua:47-50`), `level_target` and `editor_targets` (`lib/arc/seq.lua:39,64-67,101-110`), `carried_in` (`lib/arc/mod.lua:42-48`).
- An explicit forget on a mode change (`lib/arc/fx.lua:50`).

**Guards.** Inv: none. Tbl: none. Mdl: none. Tests by example in `arc_pages_test.lua` (51 tests). No filed bug; the keyed carry came in 3.1 (`fbb4201c`) and the LFO forget predates it (`f5d319ae`).

**Risk.** A new whole-step ring must remember to invent a seventh variant. The failure, stale ticks stepping another param by one, is small and silent.

**Recommendation: (b), small.** Give `arc_whole_steps(key, delta, ticks_per_step, context)` an optional context kept beside the ticks, forgetting on a mismatch. The four locals collapse into that argument and the pushed forgets can stay. Cost: about 30 lines over five files. What could break: a carry forgotten too eagerly, which the existing carry tests detect. The page locals are not reached by `find_upvalue` in tests (grep of the grid tests only; the arc tests are unverified). Bug history 0; blast radius one step of one ring; confidence medium. Option (a), one rule in `arc-core.md`'s Must not break, is the fallback.

### 5. The 64's chooser

**Owner.** `port_state(port).chooser` (`pane.lua:219-222,293,298`), NV's role `"chooser"` and its hold (`pane.lua:289-302`).

| State | Encoding | LED | Leaves by |
|---|---|---|---|
| Closed | flag nil, no role | NV shows play level | NV press |
| Armed | role and hold pending | unchanged | release before 0.5 s (plays or stops), or the hold |
| Open | flag true | NV 15, chooser drawn | NV release, `forget_port` |

A pick while open sets page, side and half and stays open (`pane.lua:235-243`). A missed NV release leaves it open until the next NV tap, which is self-healing and visible.

**Guards.** Inv: none. Tbl: prose only (`docs/notes/lua/grid/pane.md:55-57`). Mdl: none. New in 3.8. Its one bug is the swallowed release in machine 1, a wrong transition.

**Recommendation: (a).** Put this table in `pane.md` with the row "open: releases of pane keys reach no page, so anything a page holds must end at opening". The code fix belongs to machine 1. Confidence high.

### 6. Grid port attachment

**Owner.** `S.grids[port]`, `attached_devices`, `GRID_ROTATION.sizes` (`core.lua:28,622,631`). Transitions: `attach_grid` (698), `grid_added` (767), `grid_removed` (777), `reconcile_ports` (802), `attach_virtual` and `detach_virtual` (845, 862), `follow_size` (713), `set_rotation` (725), cleanup (966).

**States.** Not attached; attached; stale while the norns menu is open; attached with no layout (a size other than the four, `core.lua:592-604`).

**Guards.** Inv: "grid keys" (`core.lua:990`) checks attachment against the recorded device. Tbl: yes (`docs/notes/lua/grid-core.md:121-135`). Mdl: none. Tests by example and thorough: hot-plug, the menu move, rotation, the facade, virtual ports.

**History.** I3 (handlers on device and vport fired twice), #256 (moved in SYSTEM > DEVICES), #323 (rotation), #468 (handlers left after cleanup), #700 (the midigrid facade). All wrong transitions. Each shaped the code: vport-only handlers, the menu-close reconcile, `norns_grid()`.

**Observations.** The detach sequence is written three times with small differences (`core.lua:780-787`, `812-818`, `864-870`). `forget_port` leaves `S.grid_held[port] = {}` (332) where `detach_virtual` sets nil (870), which a test pins (`grid_core_test.lua:1382`). A grid of an unknown size is dark and dead with no message; SETUP shows its size (`lib/pages/setup.lua:108-117`), a minor gap.

**Recommendation: (d).** This is already the explicit pattern: a table, an invariant, one function per transition. A shared `detach(port)` is optional tidying.

### 7. Followed arc

**Owner.** `S.arc_device`, `S.arc_connected`, `virtual.device` (`lib/arc/core.lua:19-20,142`). Transitions: `follow_device` (123), `arc_init` (177), `arc.add` (184), `arc.remove` (195), `reconcile` (219), `follow_virtual` and `unfollow_virtual` (244, 259).

**Guards.** Inv: "arc connection" (326). Tbl: yes (`docs/notes/lua/arc-core.md:39-56`). Mdl: none. 16 tests.

**History.** #13 and #49 (a second arc), #256, #437 (a portless device taken for port 1's), #468. All wrong transitions.

**Observations.** `S.arc_connected` is a cached copy of `S.arc_device.device ~= nil`. It has two outside readers (`lib/pages/setup.lua:213`, `lib/pages/voice.lua:132`), and the invariant exists only to keep the copy honest; an accessor would remove the state. In `reconcile`, a followed virtual arc sets `S.arc_connected = true` without reading its `device` field (225-226), so a remote arc that clears `device` without calling `unfollow_virtual` would break the invariant. That is inferred, and whether it happens is `lib/io/remote.lua`'s. The arc reads the global `arc`, where the grid needed #700's `norns_grid()`; no arc mod is known to replace it (inferred).

**Recommendation: (d).** Well kept; copy its pattern.

### 8. BUFFER ALT scan hold on the arc

**Owner.** `held_voice` (`lib/arc/buffer.lua:35`) with positions' holder `"arc"`.

| Event | Effect |
|---|---|
| First ALT ring 1 turn | hold joined for the selected voice (55-58) |
| Selected voice changes under ALT | hold moves at the next turn (55-57) |
| Voice sync drops the holders | the next turn rejoins (`holds_scan`, 55) |
| ALT released, or `forget_held_keys` | hook releases (74-78) |

**Guards.** Inv: positions' "scan holds". Tbl: none here; prose at `docs/notes/lua/arc-pages.md:82`. Bugs: `4b7ba518` (the hold did not follow the selected voice) and the #238 review (the arc did not rejoin). Both wrong transitions. The rings do not show the hold (`buffer.lua:63-69`); the grid's HD key and BUFFER do. It ends at ALT release whatever page shows.

**Recommendation: (a).** Add the table above to `arc-pages.md`.

### 9. Redraw gating

`key_repaint.handling` (`core.lua:876,904-910,935`) is a latch always released through `xpcall`. `shown_faders` (`faders.lua:180-194`) and `shown_signature` (`lib/playheads.lua:243-253`) are last-seen strings where nil means nothing is shown. `redraw_errors` remembers the last printed message per port. Bugs: #161, #322, #324, #441, #527. Each was a missing or excessive repaint, and each was fixed by this pattern.

**Recommendation: (d).** The compare-a-signature-on-a-tick pattern is the one to copy for anything a grid shows that changes off the grid.

### 10. Strip and page key modes

- **Fill** (`pane.lua:307-314`): a lease with a liveness predicate. This is the cleanest held key in the area.
- **Tempo repeat** (`pane.lua:262-273`): idle, delay, repeating. A hold that re-arms itself. LED 15 while held. Ends at release or `forget_port`.
- **Recorder key** (`core.lua:499-511`): tap at release, hold clears and consumes.
- **SV** (`pages/scenes.lua:54-57,98`): a role used as a modifier, LED on while held.
- **CL and RN** (`pages/voices.lua:46-52,131`): pending shown at 15.
- **PC and VC marks** (`pages/voices.lua:58-86`): none or marked, per port, shown at 15, 4 and 2. They persist off the page and go with the grid.
- **Macros mode** (`pages/faders.lua:33,70,75,98`): per port, beside the shared `S.param_page` and `S.grid_voice_select`, which `lib/voices.lua:230,357` clamps. Bugs #618 and #619, both wrong transitions.

Inv: "grid keys" for the roles and holds. Tbl: the strip table (`docs/notes/lua/grid/pane.md:45-53`). Mdl: none.

**Recommendation: (d).** The fill pattern suits a key whose effect lives in another module (fill, HD, store, slices). It is not needed for keys the core alone acts on: steps, recorder keys, CL and RN already end by push.

### Armed or waiting states the grid or arc cannot show

All apply with `quantize_actions` on. The screen's flash shows the wait; the grid and arc do not.

| State | Evidence | Trap |
|---|---|---|
| A waiting pattern start | `play_level` reads only `S.pattern_playing` (`core.lua:524-526`); PL and NV show stopped | a second press cancels it (`lib/sequencer.lua:1535`) |
| A waiting freeze toggle | FZ reads `is_frozen` (`pages/voices.lua:129`) | a second press takes it back (`lib/freeze.lua:66`) |
| A waiting scene recall or fade | `scene_recall_level` has no waiting term (`core.lua:536-541`); scheduled at `pages/scenes.lua:81,84` | none; another scene key replaces it |
| A waiting jump or two-key loop | scheduled at `lib/positions.lua:588,593`; only the held cell is lit | none |
| The 0.3 s step hold, the 0.5 s recorder-clear hold, NV's 0.5 s | no LED until they fire | none |
| On the arc: any of the above started from its button, and the ALT scan hold | no ring shows them | as above |

Shown already: a waiting bookmark blinks (#593, `lib/positions.lua:751-753`), an armed recording lights at 11, CL and RN pending, tempo held, a fade's target (#254). `toggle_voice` and the FX freeze keys do not go through the quantizer (grep), so they have no waiting state.

### Does the grid change the screen page?

No. Nothing under `lib/grid/` or `lib/arc/` calls `set_ui_page` or writes `S.ui_page` (grep). The callers are `strata.lua:276`, `lib/pages/lfo.lua:199` and `lib/io/wtape.lua:80`. The arc only reads `S.ui_page` (`lib/arc/core.lua:271,301`). The grid's one effect on the screen's ownership is the step editor's modal push (`core.lua:394`). A note saying the grid changes the page under a modal owner should say the grid pushes the step editor over it. I did not find the sentence quoted in the handoff in the UI notes.

### Constraints on any refactor here

- Handlers on the vport only (`core.lua:703`, `lib/arc/core.lua:131-132`).
- No page names a physical key or keeps state outside `pane.state()`.
- `grid_redraw()` stays direct.
- `S.grid_held` stays a field of `S`, since tests reach it.
- `lib/grid/core.lua`'s constructor is one function under the 200-local rule, so a new table of state should join an existing one.
