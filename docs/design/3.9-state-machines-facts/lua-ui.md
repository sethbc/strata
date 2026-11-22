# Facts: the state machines of the script's lifecycle and the screen UI (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

## Summary

Ranked by how much making the machine explicit would buy. All paths are from the repository's root.

| # | Machine | Owner | States | Transition bugs | Invariant / States table | Rec. | Conf. |
|---|---------|-------|--------|-----------------|--------------------------|------|-------|
| 1 | Held-key gestures (press time, release decides) | four copies: `lib/ui/alt.lua`, `lib/pages/buffer.lua`, `lib/pages/seq.lua`, `lib/ui/voice_picker.lua` | 3 per key | 9 (#234, #248, #250, #596, #823, 779a6610, 4628521d, 2a411200, 27b8000b) plus 2 new | partial / no | b | high |
| 2 | Key press marks and ALT | `lib/ui/keys.lua`, `strata.lua` `key()` | 3 per key × ALT | 3 (#234, #425, 779a6610) | yes / yes | c | high |
| 3 | Modal stack and its seven owners | `lib/ui/modal.lua` | stack + open flag each | 5 (0dc28ead, #592, ccb491c7, #843, #847) | 5 of 7 owners / no | a + two invariants | high |
| 4 | norns takeovers (menu watch, file selector, name entry) | `lib/ui/menu_watch.lua`, `lib/pages/buffer.lua`, `lib/ui/name_entry.lua` | 2–3 each | 8 (779a6610, 0e941357, ac4c9088, 042687cb, #425, #256, #435, #849) | name entry only / name entry only | a + one invariant | medium |
| 5 | IO view and row cursors | `lib/pages/io.lua`, `lib/ui/cursors.lua`, `lib/pages/setup.lua` | 4 (IO) | 5 (98748480, #319, b138a706, 5be51973, 9935d986) | no / no | a | medium |
| 6 | Flash slots and notices | `lib/ui/flash.lua` | 4 per slot | 5 (854fe77f, #255, 2c65c007, 7499125d, #843) | yes / no | a | medium |
| 7 | Armed confirmations | `lib/pages/scenes.lua`, `lib/factory.lua` | 3 | 3 (b23aed5b, a54d75ec, #255) | SCENES yes / yes | d | high |
| 8 | Script lifecycle and registries | `strata.lua`, `lib/state.lua` | 4 phases | 6 (#72, #384, #385, #426, #461, b2eae18e) | not needed / order tables | d | high |
| 9 | Redraw flags and frame clock | `lib/ui/frame.lua` | 2 flags + clock | 7 (#11, #320, #423, #424, #433–#435, #592) | no / no | d | high |
| 10 | Detent hold, `S.turning_param` | `lib/ui/detent.lua` | 2 per param | 2 (b23aed5b, #318) | turn only / no | d | high |
| 11 | Sub-views (MOD view, SEQ `edit_open`, slice editor view) | page files | 2–4 | 0 found | no / no | d | medium |
| 12 | Zones learn | `lib/ui/zones.lua` | 3 | 1 (#626) | yes, thorough / no | d | high |

The five things most worth knowing:

1. **The 3.3 audit's tools cannot see this area's bugs.** Almost every UI bug since has been a wrong transition: a release that never arrives, or a hint that names what the release will not do. The invariants run only after each test's end state.
2. **A new defect of that kind, reproduced in the harness.** With the voice picker open, hold ALT+K3 on a slot (or ALT+K2), and let a grid's held step push SEQ's step editor over it. The releases go nowhere, and the picker keeps `k3_slot` or `k2_at`:
   - A later plain K3 tap opens the save-name entry on its release.
   - The hint row stays on `K2:cancel` and the owner animates until K2 or the menu.
3. **"Forget a lost release" is written four ways.** The fix is one press time owned by the dispatcher, beside `S.key_press_page`, with an accessor; the four private marks then go, and a stale one becomes impossible.
4. **The cheapest wide net is a seeded random walk** of UI events with `h.check_invariants()` after each event and a quiescence check at the end. `test/notes_model.lua` (3.5's ruling 57) is the precedent, and it found #690.
5. **Leave alone, and copy:**
   - The lifecycle and registries, the modal stack, MOD's `change_view`, the zones learn's token-and-retire clock and the frame clock are already explicit and sound.
   - Three notes rules have drifted: a grid page change under a modal, IO's `leave` closing its detail, and "`S.selected_voice` changes only through `select_voice_by`".
   - Only the flash's clock in this area can be canceled with its resume posted.

---

## Full report

### What is already in place

- **Invariants.** Nine of the 35 registered invariants are this area's: `key presses` (`lib/ui/keys.lua:86`), `modal owner` (`lib/ui/modal.lua:90`), `flash slots` (`lib/ui/flash.lua:108`), `param turn` (`lib/ui/detent.lua:47`), `step editor` (`lib/pages/seq.lua:946`), `voice picker` (`lib/ui/voice_picker.lua:236`), `zones editor` (`lib/ui/zones.lua:286`), `scale editor` (`lib/ui/scale_editor.lua:294`) and `scenes prompt` (`lib/pages/scenes.lua:64`).
- **States tables.** In this area only `docs/notes/lua/ui/alt-and-keys.md:9` (keys), `docs/notes/lua/pages/scenes.md:28` (overwrite prompt, name entry) and `docs/notes/lua/pages/fx.md:15`.
- **Source scans.** `test/unit/ui_detent_test.lua` (#427) forbids direct `redraw()`, assignments to `ui_page`, table calls of `alt_key` and stray `draw_hints`.
- **Model test.** `test/unit/strata_test.lua:422` walks seeded random play against `test/notes_model.lua` and checks every invariant after each step (`docs/decisions/3.5.md:79`).

### 1. Held-key gestures: worth making explicit (b)

**Owner and state.** One machine, "note the press time, decide at the release by how long it was held, change the hint at the hold time", exists four times:

- `k2_press = {page, at}` in `lib/ui/alt.lua:55`, with `k2_down` :57, `k2_held` :64, `k2_up` :88 and `k2_hint` :113. MAIN, VOICE, SEQ, FX, LFO and MOD use it.
- `pressed_at[n]` in `lib/pages/buffer.lua:701`, with `held_long` :702 and `held_hint` :716. Its `hold_seconds` (:89) is a second constant with the same 0.5 s as `ALT_HOLD_SECONDS` (`lib/constants.lua:213`).
- `editor.alt_k2_at` in `lib/pages/seq.lua` (`editor_key` :842), which also calls `k2_down` and `k2_up`.
- `picker.k2_at` and `picker.k3_slot` in `lib/ui/voice_picker.lua:34`, set at :186 and :196.

**States.** Up, down and quick, down and past the hold time. Representable but meant to be impossible: a mark set while the physical key is up.

**Transitions.**

| Event | alt.lua | BUFFER | step editor | picker |
|-------|---------|--------|-------------|--------|
| press | `k2_down` | `pressed_at[n] = now` | `alt_k2_at = now` | `k2_at` / `k3_slot` |
| release | `k2_up` acts and clears | `held_long` reads and clears | acts and clears | acts and clears |
| page change | marks cleared by `set_ui_page` (`lib/ui/keys.lua:77`); `k2_press` stale but unread | same, the hint reads the marks | not applicable | not applicable |
| norns menu takes the release | marks cleared by `forget_held_keys` | same | menu-close hook (`lib/pages/seq.lua:889`) | menu-close hook (`lib/ui/voice_picker.lua:151`) |
| another owner pushed over | not applicable | not applicable | not applicable | **nothing** |

**Guards.** The picker's invariant checks only a closed picker (`lib/ui/voice_picker.lua:246`). `test/unit/ui_alt_test.lua` has 22 tests, all by example. `docs/notes/lua/ui/voice-picker.md` ("A press the menu took is forgotten") names exactly the two symptoms below, but only for the menu path.

**History.**

- 779a6610: keys held into the menu left BUFFER's K3 stuck on save.
- 4628521d: stale BUFFER key flags dropped.
- #234: a key held across a page change and back still fired.
- #248: no hint for what a held key will do.
- #250, #596, #823: the hint offered what the release would not do.
- 27b8000b: the release's hint after K1 comes up.
- 2a411200: a K2 release the menu took left the step editor redrawing.

Every one is a wrong transition. An end-of-test invariant saw none of them.

**New defect (confirmed).** `S.lib.ui_modal.key` delivers a release only when the press owner is still the top owner (`lib/ui/modal.lua:82-84`). A grid's held step pushes the step editor over any owner (`lib/grid/core.lua:393`, `lib/pages/seq.lua:913`), so the picker's release is lost and its marks stay. I ran this as a scratch unit file through `lua test/run.lua --dir` (nothing in the repo was written):

- After ALT+K3 down, editor pushed, keys up, editor closed: a plain K3 press leaves the text entry closed, and its release opens it (`lib/ui/voice_picker.lua:200-203`).
- After ALT+K2 down in the same sequence: the hint reads `K2:cancel` two seconds later with no key held (:107-109), and `animates` stays true (:119).

It needs a grid and an odd gesture, so it is rare. The probe is at `probes.md`.

**What the user sees.** Each copy shows what letting go will do, which is good. The gap is the stuck hint and the unexpected save prompt above.

**Recommendation: (b).**

- Record the press time where the press marks are already kept: `S.key_press_at[n]` beside `S.key_press_page[n]` in `key()` (`strata.lua:307`), and a time beside `pressed[n]` in `lib/ui/modal.lua:79`.
- Add accessors, for example `S.lib.ui_keys.held_seconds(n)` and `S.lib.ui_modal.held_seconds(owner, n)`, the second nil unless the owner is on top and saw the press.
- The four private marks then become reads. `k3_slot` stays as data but is gated by the accessor.
- Staleness goes by construction, because the dispatcher already clears its marks on every loss path (`strata.lua:303-304`, `lib/ui/keys.lua:33-38` and :77-78, `lib/ui/modal.lua:61-63`).

Constraints:

- `key()` is not on AGENTS.md's never-edited list, but `strata.lua` is shared, so this is a package of its own.
- Tests reach `S.key_press_page` by name, so it stays.
- `k2_up`'s page check (`lib/ui/alt.lua:91`) and BUFFER's rule that an ALT press never opens the file selector must survive.
- Whether tests reach `pressed_at` or `k2_press` through `find_upvalue` I did not check.

Cost: four modules, four notes files, about one day. Detection: the existing example tests plus the walk in section 2. Bug history 9 plus 2, blast radius every page's keys, confidence high.

### 2. Key press marks and ALT: sound; add a walk (c)

**Owner and state.** `S.key_press_page` (`lib/ui/keys.lua:16`), `S.alt_held` (:21) and `S.key_press_alt` (:27).

**Transitions.**

- `key()` (`strata.lua:297-327`).
- `S.lib.ui_alt.set` (`lib/ui/alt.lua:17`).
- `set_ui_page` (`lib/ui/keys.lua:69`).
- `forget_held_keys` (`lib/ui/keys.lua:32`), called by the menu wrapper, the 10 Hz fallback (`lib/ui/menu_watch.lua:24`), BUFFER's selector open (`lib/pages/buffer.lua:839`) and the name entry (`lib/ui/name_entry.lua:37`).

**Readers.** `k2_held`, BUFFER's `held_hint`, each page's `hints(alt_held)`, `enc_param_delta`'s fine test (`lib/ui/detent.lua:149`), and the modal owners, which read `S.alt_held` directly.

**Guards.** It has both an invariant and a States table. Its bugs (#234, #425, 779a6610) were all transitions.

**User.** I found no stuck ALT: every path that swallows K1's release forgets ALT first. The reverse is possible: ALT is forgotten while K1 is still down after a name entry or file selector closes. That is harmless and I did not probe it.

**Recommendation: (c).** A seeded walk over these events, with `h.check_invariants()` after each:

- K1, K2 and K3 down and up;
- E1;
- menu open and close;
- each owner's open and close;
- the grid's step editor push and pop;
- name entry finish and cancel;
- file selector cancel.

End it with every key up and every owner closed, and assert that no page or owner animates and that each hint equals a fresh script's. That end check would have caught section 1's defect and 2a411200. Cost: one test file and a small event model. The code is unchanged.

### 3. Modal stack and its owners: explicit already; close two gaps (a)

**Owner.** `stack` and `pressed` are locals in `lib/ui/modal.lua:25` and :30. `push` (:41), `pop` (:57) and `key` (:75) are the only writers. This is the pattern to copy.

**The redundancy.** Each owner keeps its own `open` flag beside "my owner is on the stack", with an invariant tying the two:

- step editor (`editor` nil or a table, `lib/pages/seq.lua:337`);
- zones editor (`lib/ui/zones.lua:49`);
- voice picker (`lib/ui/voice_picker.lua:34`);
- scale editor (`lib/ui/scale_editor.lua:44`);
- factory list (`lib/factory.lua:516`).

Two owners have no invariant: the slice editor (`lib/ui/slice_editor.lua:74`) and IO's detail list (`lib/pages/io.lua:51`).

**History.**

- 0dc28ead: a release reached an owner that had not seen the press.
- #592: an owner over a page that does not animate.
- ccb491c7: the editor closed by its own pattern replacements, hence `replacing` (`lib/pages/seq.lua:343`).
- #843: any flash replaced the scale editor's hints.
- #847: owners left pushed at cleanup.

**Findings.**

- Only the picker, the scale editor and the factory list close at cleanup (`lib/constants.lua:256`, :271, :272). The zones editor, slice editor, step editor and IO detail do not. I probed the zones editor: it is still open and on top after `cleanup()`. That is harmless, since nothing draws after cleanup, but inconsistent.
- The scale editor's note tap stays armed while the step editor covers it (`lib/ui/scale_editor.lua:82`, :199), so a MIDI note would toggle a scale class the player cannot see. This is read from the code, not probed.
- `docs/notes/lua/ui/pages-and-dispatch.md:52` says a page change "made elsewhere (the grid)" changes the page under an owner. No grid code calls `set_ui_page`; the only callers outside `enc` are `lib/pages/lfo.lua:199` and a layout state at `lib/io/wtape.lua:80`. So IO's `leave` closing its detail (`lib/pages/io.lua:562`) cannot run today.

**User.** Under an owner E1 is dead with no sign of it, and the header still names the page beneath. `K2:back` is the only cue.

**Recommendation: (a).** Add an owners table to the notes: who opens each, what closes it, whether it closes at cleanup, and which press marks it keeps. Add invariants for the slice editor and IO detail. Deriving `open` from the stack is not worth it, because each draw's `if not editor.open` guard is cheap and tested.

### 4. norns takeovers: document; one invariant (a)

Three machines swap norns' globals and must put them back.

- **Menu watch.** `menu_watch = {original_set_mode, wrapper, active}` at `lib/ui/menu_watch.lua:34`; `watch` :36, `unwatch` :75. States: unwatched, watching, pass-through (something wrapped it later). Hardened by #425.
- **File selector.** `file_selector_open`, `file_selector_callback`, `script_key`, `script_enc` at `lib/pages/buffer.lua:103-106`. Opened in `buffer_key_release` (:830-873), closed at :875, `release_superseded_file_selector` :896. States: closed, open, superseded by the menu's selector. It has no invariant and no States table. `redraw()` reads it (`strata.lua:341`) and so do the meter and `animates` (`lib/pages/buffer.lua:641`, :1185).
- **Name entry.** `state = {callback, script_key, script_enc}` at `lib/ui/name_entry.lua:20`; `open` :36, `reconcile` :65. It was extracted in #849 from two copies, and SCENES has its invariant and States table.

The file selector and the name entry have the same shape but must stay separate. The selector's release runs before norns' `set_mode(false)` (`lib/ui/menu_watch.lua:48-51`). The entry's reconcile runs after it and calls `norns.menu.init()` (`lib/ui/name_entry.lua:67-70`). Merging them would change that order.

The tempo handler (`lib/params_setup.lua:77-91`) and the PSET actions (:326) are the same "wrap and restore" kind, and are fine.

**Recommendation: (a).** A States table for the file selector in `docs/notes/lua/pages/buffer.md`, and one invariant: `file_selector_open` exactly while the callback and the saved `key` are set.

### 5. IO view and row cursors (a)

**IO.** `view = {tail, pinned, anchor, index, unseen}` at `lib/pages/io.lua:49`. Real states: in view, scrolled past (`tail > 0`), pinned section, unseen (the cursor's row vanished and no draw has shown the new one). E3 and K3 act only in the first; in the others they only bring the row back (`unseen` :206, `hidden` :225, `io_enc` :380, `io_key` :418). The hint says `E3:back` when hidden, but nothing marks the unseen state. It has no invariant and no table. History: 5be51973.

**VOICE.** Anchor in `lib/ui/cursors.lua:38`. `sync` (:64) is idempotent, and only `move` and `place` set the anchor (98748480). `clamp_all` runs in every `redraw()` (`strata.lua:346`).

**SETUP.** `setup_view.tail` at `lib/pages/setup.lua:105` (#319, b138a706).

That is three anchor schemes for one idea. Unifying them is not worth it, because each is small and tested by example.

**Recommendation: (a).** A four-row table for IO's view in `docs/notes/lua/pages/io.md`.

### 6. Flash slots (a)

**Owner.** `M.slots` at `lib/ui/flash.lua:18`; `start` :39, `text` :84, `cancel_all` :91, notices :65.

**States per slot.** Idle; showing; lapsed with the clock still pending (`text()` returns nil by time, :86); hidden because its page is not up.

**History.** 854fe77f (page scope), #255 (SCENES kept its prompt in the flash), 2c65c007 (standing notices), 7499125d, #843.

**Guards.** The invariant checks that a showing text has its clock.

**Clock.** `start` cancels the previous clock (:42) with no token. A flash replaced within a tick of its own end can cancel a clock whose resume is posted, giving #626's one maiden line. This is inferred, not probed. The quantize flash sleeps `math.huge` (`lib/quantize.lua:25`), so it is safe.

**Recommendation: (a).** Note the four states, and retire the clock with a token as `lib/ui/zones.lua:86-95` does if #626's rule is being made uniform.

### 7. Armed confirmations (d)

**SCENES.** `armed_slot` and `armed_until` at `lib/pages/scenes.lua:55`; `armed` :102, `disarm` :107. The lapse is handled inside `scenes_animates` (:215), a transition inside a query, and it is documented. It has an invariant and a States table and is well kept since #255. The prompt survives a page change and back within 2 s (probed); this is benign.

**Factory list.** `armed_until` at `lib/factory.lua:516`, shown only through the hints flash (:574-576). If another flash replaces the prompt, the list stays armed with nothing saying so. That is #255's shape in reverse, and minor.

**SETUP's load confirm** is `lib/scenes.lua`'s (:1282) and belongs to the scenes auditor.

### 8. Lifecycle and registries (d): the pattern to copy

**Phases.**

1. Include time: registries open.
2. `init` adds params; the first record closes nine registries (`lib/params_setup.lua:350`, `lib/state.lua:75-81`).
3. Start steps in order; `S.started` at step 5 (`lib/ui/frame.lua:18-21`).
4. Running.
5. `cleanup()` steps in order.

**Guards.**

- `require_open` raises on a late registration (`lib/state.lua:85`, #384).
- Unknown fields are refused (#385).
- Two steps never share an order (`lib/state.lua:98`).
- `test/unit/structure_test.lua:826` and :1063 pin both sequences.
- `docs/notes/lua/state-and-voices.md:45` and :119 hold the tables.

**History.** b2eae18e (a `clock.sleep` in `init`), #72 (cleanup overwrote files after a failed start), #426 (input before `init`), #461 (the engine is gone before cleanup).

**Gaps.** No phase says "cleaning up", and `S.started` is never cleared. I found no harm from either. The start-up clock is canceled at cleanup (`strata.lua:208`), which is safe because norns ends all clocks then.

### 9. Redraw flags and frame clock (d)

**Owner.** `screen_dirty`, `arc_dirty` and `frame_clock` at `lib/ui/frame.lua:30-32`; `draw_frame` :115; `contained_call` :73.

Each flag clears before its draw, so a failed draw is not retried. Its seven bugs were about who asks and what a failure does. All are fixed and tested, and the #427 scan guards the rule. The clock is canceled only at restart and cleanup.

### 10. Detent hold and `S.turning_param` (d)

**Owner.** `detent_holds` at `lib/ui/detent.lua:25`. The hold expires lazily, on the next turn (:118), so it has no clock. `as_turn` (:38) saves and restores the mark around an error, and has its invariant.

**History.** b23aed5b (hold expiry) and #318.

### 11. Sub-views (d)

**MOD.** `S.mod_page.view` at `lib/pages/mod.lua:63` is one named value with one writer, `change_view` (:396), and a change counter. This is recommendation (b) already done.

**SEQ and the slice editor.** SEQ's `edit_open` (`lib/pages/seq.lua:703`) and the slice editor's `view` (`lib/ui/slice_editor.lua:74`) are two-state and local.

Views persist across page changes by design. I found no transition bug.

### 12. Zones learn (d): the clock pattern to copy

**Owner.** `learning`, `learn_clock = {token, retired, wake}` and `tap_set` at `lib/ui/zones.lua:51-61`.

`cancel_learn` (:86) cancels only when the wake is more than `learn_wake_margin` away, and otherwise retires the clock. Its invariant (:286) checks the clock is alive, the tap matches, and the retired clocks are tidy. It is the most thorough invariant in the area.

### Edges into other areas

- **Pending voice type.** `lib/types.lua:90` is flushed by `set_ui_page` and `select_voice_by` (`lib/ui/keys.lua:49-71`). This is the types auditor's machine, with two of its triggers here.
- **`S.selected_voice`.** AGENTS.md says it changes only through `select_voice_by`, but about 25 layout-state setups assign it directly (for example `lib/freeze.lua:87`, `lib/notes.lua:898`, `lib/pages/voice.lua:395`), skipping the flush and the bend follow. I spot-checked four and inferred the rest from their shape. No scan enforces the rule.
- **Note tap.** `S.lib.midi_in.set_note_tap` is a single slot shared by the zones learn and the scale editor, with no owner check. The scale editor re-arms it on every draw (`lib/ui/scale_editor.lua:199`).
- **Grid.** The grid's `on_hold` is a fifth held-key timer, and the grid's step editor push is the only way one owner covers another.

### Suggested order

1. The seeded UI walk (section 2), with its end-state check. Code unchanged.
2. The dispatcher-owned press time (section 1), which fixes the picker defect at its root.
3. The notes tables and three small invariants (sections 3–6).
