# Facts: the grid (panes, pages, strips, held keys, layouts)

## 1. How it works today

### Q1. A page's record
- The fields are `{name, index, press, redraw, sides?, faders?, signature?}`, and no others are allowed (`lib/state.lua:652-675`). `sides` must be nil, 1 or 2 (:672), and `name` must be `GRID_PAGES.names[index]`.
- `press(pane, x, y, z)` gets presses, and releases that were not consumed (`lib/grid/core.lua:893`).
- `redraw(pane, led)`: the `led` function drops any key the grid doesn't show (`lib/grid/pane.lua:400-404`).
- `faders(pane)` returns `{{line, first, keys, id}}`. The pane engine sets and draws those keys itself, so `press` never sees them (pane.lua:371-377).
- `signature(pane)` is compared by the 10 Hz drift tick (pane.lua:441-470).
- The pane object (pane.lua:124-163) has `port, index, page, side, width (16/8), offset (0/8), turned, shows, state()`. It also has wrappers in pane coordinates: `held, hold_pending, on_hold, consume, consumed, press_as, pressed_as, gesture_key, step_key`.
- A **second side** is the same page index with `pane.side == 2`, stored in `S.grid_panes[port][pane] = {page, side, half}` (core.lua:114-120).
  - `page_key` (pane.lua:277-285): a page key opens its page on side 1. The shown page's key pressed again toggles the side, if `sides == 2`.
  - LEDs: 15 on side 1, `side_two` 10 on side 2 (:350-351).
  - On the 64, chooser rows 3-4 pick side 2.
- Worked example: positions, the only two-sided page (`lib/grid/pages/positions.lua:91-112`), branches on `pane.side`. Side 1 is sixteen cells per voice; side 2 is the bookmarks (x 1-4), ST/HD/WH (x 6-8) and the slots' record and clear keys (x 9-16, lines 1-2). Each press is held in role `"positions"` (:43-47).

### Q2. Step keys
- Patterns calls `pane.step_key(x, y, z, y, x)` (`lib/grid/pages/patterns.lua:19`). That becomes `grid_core.step_key(port, px, py, z, v, step, x - offset, width)` (pane.lua:156-161; core.lua:420-438).
- Validation: the step must be ≤ `PATTERN_LENGTH`, and position ≤ positions ≤ `PATTERN_LENGTH` (:422-423).
- **Press, telling the second key from a toggle:** `held_step` (:386-396) searches `step_keys[port]` for this voice's held step, on any pane.
  - If one exists, this key is a **level key**. The held step gets `S.patterns[v][s] = max(1, round(pos·15/positions))` (`level_for_position`, :377-380), written directly, then `note_pattern_edit` runs. Both keys are consumed, the held step's hold stops, and the entry is marked `level_key = true` (:425-432). A level key never takes a level itself.
  - Otherwise this key becomes the held step and arms `on_hold(0.3 s)` (`GRID_HOLD.step_edit_seconds`, `lib/constants.lua:132`).
- **Consumed** means the release skips the layout and toggles nothing (:199-206).
- **Release** (`handle_key`, :886-896): stop the hold, pass the release to the layout unless consumed, then `release_step_key` (:370-374). That toggles 0↔15 (`lib/sequencer.lua:1464`) unless the key is consumed, a level key, or dropped. The key's state is always cleared afterward (`release_key` in its own xpcall, :913-917).
- **The 0.3 s hold** calls `S.lib.pages_seq.open_step_editor(v, step, port)`, the screen's modal. The key is consumed and remembered as `step_editor.key`; its release closes the editor (:403-407, :261-266). Level keys still work while the editor is open.
- `on_hold` (:234-243) runs on `S.lib.clocks.run`. It stops on a re-press, the release, `end_pane_keys` or `forget_port`, and cleanup cancels it.
- **Page, side or half change:** `end_pane_keys` (:317-332) drops the step entries, holds and roles of that pane's keys. The keys stay held and consumed marks stay. Strip keys and the other pane are untouched.
- **Unplug:** `forget_port` (:338-347) drops everything, including `port_state` and the panes.
- **`replace_pattern`** runs `end_step_gestures(v)` on every port (:451-461). Ruling 71 keeps the editor's own key open.
- grid-core.md "Machines: grid keys" is the full table.
- **256 behavior:** a voice has one held step per grid, whichever pane its keys are in (#450). Each level key's position is counted along its own pane.

### Q3. "One voice"
- `S.grid_voice_select` (core.lua:41) is global: one value for every grid and pane.
  - Only `select_grid_voice` sets it (:925-929, which also clamps `S.param_page`), from the faders page's V1-V7 on line 7 (`lib/grid/pages/faders.lua:87-100`).
  - `lib/voices.lua:230,357` read it.
  - It is "the grid's own pick, not the screen's" (user faders page).
- The "voice picker" (`docs/notes/lua/ui/voice-picker.md`) is the screen's preset modal, not a grid feature.
- `S.selected_voice` is changed only by `S.lib.ui_keys.select_voice_by` (`lib/ui/keys.lua:76-85`). A scan, `SELECTED_VOICE_SITES` (`test/unit/ui_detent_test.lua:314`), fails on any new assignment site. No grid page touches it.
- **No record of the last voice touched on a pane exists.** The nearest is positions' per-port `record.held = {voice, cell, cells, pane, still}` (`lib/positions.lua:606`).

### Q4. Strips (pane.lua:39-60, 305-352)
- Upper strip (row 8 on the 128h and 256, column 8 on the 128v): PL 1, FL 2, P1-P7 3-9, O1-O7 10-16.
- Lower strip (the 256's row 16): T- 1, T+ 2, P1-P7 3-9, M1-M7 10-16.
- Small strip (the 64): NV 1, O1-O7 2-8.
- **No free key on any strip.** A test requires 2 + `GRID_PAGES.count` + `NUM_VOICES` = 16 (`grid_pane_test.lua:68`).
- Gestures:
  - Tap: PL, P (again for side 2), O, M.
  - Hold: FL, with `press_as "fill"` and `hold_fill("grid:"..port, true, still)` until release. A page change does not end it; an unplug does.
  - Press plus held repeat: T±, repeating after 0.5 s then every 0.1 s (:262-273).
  - NV: a tap acts at release; a 0.5 s hold opens the chooser, where a pane key held under NV is the only hold-and-tap (:289-302).
- What is missing:
  - the 64 has no FL, tempo or mute keys;
  - the 128h and 128v have no tempo or mute keys;
  - solo exists only on the voices page.
- Chooser: page c is column c, and rows 1-4 pick side and half. Column 8 and rows 5-7 are dead (`grid_pane_test.lua:350`).

### Q5. Voices page (one side; `lib/grid/pages/voices.lua`)
- Keys: x1 MU, 2 SO, 3 LK, 4 FZ, 5 CL, 6 RN, 7 PC, 8 VC. x 9-16 are an 8-key fader line for `v<v>_amp` (:23-32, :139-150).
- Every key acts at press, except CL and RN, which act at a 0.5 s `on_hold` (:52-58).
- LEDs: MU/SO 15/4, LK 12/2, FZ 15/3, CL/RN 15 while pending else 2, PC/VC 15 the copied voice, 4 the others, 2 with no copy.
- **No free column, and no second side.**

### Q6. Where state lives
- `pane.state()` is `port_state(port).pages[<page name>]` (pane.lua:133-140). It is **per port and page, not per pane**: a 256 showing one page on both panes shares it.
- `port_state` itself holds `.positions` and `.chooser`.
- `S.grid_held[port][x][y]` holds press times. `hold_clocks`, `consumed_keys`, `step_keys` and `key_roles` are core locals (core.lua:165-173).
- **No page names a physical key** (pane.md, Must not break 1). Only `physical_of` maps pane keys to physical ones (pane.lua:76-90).

### Q7. LEDs and repaint
- `step_brightness` (`lib/sequencer.lua:1787-1794`):
  - the voice's sounding step: 15 if set, 4 if empty;
  - past the voice's length: 1 if set, 0 if empty;
  - otherwise: the step's level.
  - So a level-15 step looks the same playing or not.
- Shared levels (`GRID_LEVELS`, `lib/constants.lua:152`):
  - picked 15 / unpicked 4;
  - page shown 15, other 2, `side_two` 10;
  - voice 12 running / 6 silenced / 2 stopped;
  - lock 12/2;
  - play 15/4.
- "Waiting" today blinks only positions' marks. Package 5a (#876) adds a blink for play, freeze, scene and cell, with the 15 Hz playheads clock redrawing while anything waits. #949 (a pending hold lights nothing) is left as is (`docs/design/3.9-state-machines-design.md:207,347`).
- `grid_redraw` (core.lua:941-959) **repaints every grid in full**: `all(0)`, every pane, its fader lines, strips, then `refresh`. It runs:
  - once per key (#161);
  - once per beat that has steps (`finish_beat`, sequencer.lua:1107-1119, #527);
  - from param actions;
  - from the drift tick, when the signature changes;
  - from the playheads clock, for positions.
- In norns, `all` marks every quad dirty, so each refresh sends all quads: 4 on a 256, 2 on a 128, 1 on a 64 (`~/src/norns/matron/src/device/device_monome.cc:150-185`).
- Patterns makes 112 `led`/`step_brightness` calls per pane. **No measured cost exists in the repo.**

### Q8. 64 and 128v
- 64: the pane shows x offset+1..offset+8. The hidden half is unreachable (its wrappers return nil), and `set_half` ends the pane's keys, so **no two-key gesture can cross the half's edge**.
  - Levels run over eight positions: key 8 = 15, key 4 = 8.
  - A 16-key fader is squeezed into eight keys; an 8-key line on the other half is hidden (pane.lua:169-186).
- 128v: pane x is the physical row, pane y the column (pane.lua:86, 101-103). A line runs down its column, and faders run up with row 16 as the minimum (:177). Seven lines of sixteen fit exactly.

### Q9. Harness
- `h.grid_pane(context, arr)` (`test/helpers.lua:407-455`): `show(page, side, half)` raises if the view does not match. Also `press`, `tap`, `led`, `shows`, all in pane coordinates.
- `h.GRID_ARRANGEMENTS` = 128h, 256 top, 256 bottom, 128v, 64 left, 64 right.
- `h.probe_grid_page` and `h.no_grid_page` stand in for pages.
- `grid_pane_test.lua:739` presses every key of every side of every page on every arrangement, so a new side is exercised automatically. Page tests loop with `each_arrangement` (`grid_pages_patterns_test.lua:22-30`).
- Package 3b adds `test/unit/grid_walk_test.lua` (four layouts).

## 2. What the rework would touch
1. **A step you can hear:** this is mostly the sequencer's work. On the grid, the mode and target keys would sit on a new side, and `step_brightness` needs levels for pulse and move.
2. **Lanes:**
   - Patterns would get `sides = 2`, with `press` and `redraw` branching on `pane.side`.
   - `step_key`/`held_step` assume one held step per voice per port and write `S.patterns` directly (core.lua:426). Lane values need a generalized or a second key machine.
   - `level_for_position` can be reused for any 1-15 value.
   - A per-pane voice pick needs per-pane keys inside `pane.state()`.
   - Files to change: grid-core.md's table, the patterns notes and user page, `grid_pages_patterns_test.lua`, `grid_core_test.lua`.
   - Can stay: the pane engine, layouts, harness and strips.
3. **Keys and lights:**
   - "Hold a step to show its values" collides with the 0.3 s editor hold.
   - Changing the other pane's content changes no `view`, so neither `end_pane_keys` nor the press records see it.
   - `held_step` already spans a 256's panes.
4. **Performing:**
   - Two keys on one line are today the level gesture. Positions' two-key loop is a precedent: the first key jumps, the second sets the loop (`lib/positions.lua:599-605`).
   - A roll on a held key collides with the editor hold.
   - Variations, fill and solo have no free key on the strips or the voices page. FL is missing on the 64, and M1-M7 exist only on the 256.

## 3. Constraints
- pane.md, Must not break:
  - pane coordinates only;
  - fader keys belong to the engine;
  - a page change ends only its own pane's keys, never a strip key (ruling 54);
  - containment per pane;
  - state lives in `pane.state()`;
  - strips sum to 16 (a test).
- grid-core.md, Must not break:
  - the toggle happens only in the core's release path;
  - pattern keys go through `step_key`;
  - the editor never outlives its key (ruling 71 keeps its own replacements);
  - whole-pattern changes go through `replace_pattern` and `end_step_gestures` (#242);
  - delays go through `on_hold` (#870);
  - release-acting keys use `press_as`/`pressed_as`;
  - levels come from the core (#526);
  - one repaint per key (#161);
  - no redraw on every tick (#324);
  - `GRID_PAGES` names, never digits (a test);
  - bounds-check before indexing `S.patterns`.
- **No third side** (`lib/state.lua:672`; `grid_pane_test.lua:45`). **No eighth page key**, because `GRID_PAGES.count` is tied to the 16-key strips. Only the 64's chooser has a spare column (8).
- The "grid keys" invariant (core.lua:997-1038), `SELECTED_VOICE_SITES`, and the 200-local limit with 30 locals free (AGENTS.md).
- **AGENTS.md has 7,924 of its 8,000 words** (`docs_test.lua:855`). grid-core.md has 7,089 words, but no test limits it.
- Later waves will edit `lib/grid/core.lua`: 5a (waiting blinks; also the voices, scenes and positions pages) and 6a (overdub). 3b adds the grid walk test.

## 4. Open questions
1. How side 2 is reached: `sides = 2` on patterns through the lit P1, or a mode inside side 1. The code leans to `sides = 2`.
2. What a step hold does: the screen editor at 0.3 s, the side-2 step view, a roll, or a loop anchor. All four share one key machine.
3. Two keys on a line: a level set (today) or a loop. The second key would be told apart differently in each.
4. Which voice side 2 shows: the global `S.grid_voice_select`, a per-pane pick (needs new state), or the voice last touched (nothing records it).
5. Where variations, fill and solo go on sizes with no free keys (the 64, the 128s).
6. On a 256, how a hold on one pane redraws the other pane and ends its keys, since `view` does not change.
7. The LED vocabulary: playing and full steps both light 15, and 5a takes "waiting" as a blink.
8. The cost of repainting more lines: unmeasured; every repaint is full and sends all quads.
