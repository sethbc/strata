# 3.7 design facts: the Lua side

Read-only survey of `main` at 334429aa (2026-11-15). Paths are from the repository root; line numbers are as of that commit. "Code wins" marks a place where a doc and the code disagree (both quoted). "Not found" marks what could not be established. No design is proposed; each section ends with the constraints a design must meet.

---

## 1. Step attributes, the `steps` scene block, versions and the table cap

### The attribute table and its two functions

- `SEQ` tunables: `lib/sequencer.lua:31-72`. The keys that matter here: `max_step_notes = 8`, `max_ratchet = 4`, `max_prob = 100`, `max_degree = 14`, `gate_steps = {0.05, 16}`, `lock_params = {pos = "buf_pos", pitch = "grain_pitch", size = "grain_size"}` (`:55`), `lock_keys = {"pos", "pitch", "size", "bookmark"}` (`:56`).
- `ATTR_CHECKS`, `lib/sequencer.lua:187-196`. It holds one validator per key:
  ```lua
  prob = function(value) return whole_between(value, 0, SEQ.max_prob) end,
  ratchet = function(value) return whole_between(value, 1, SEQ.max_ratchet) end,
  notes = valid_notes,
  pos = function(value, voice_idx) return in_lock_range(voice_idx, "pos", value) end,
  pitch = ..., size = ...,
  bookmark = function(value) return whole_between(value, 1, NUM_BOOKMARKS) end,
  gate = function(value) return number_between(value, SEQ.gate_steps[1], SEQ.gate_steps[2]) end,
  ```
  - `in_lock_range` (`:181-184`) reads the live param's range: `param_range(voice_param(voice_idx, SEQ.lock_params[key]))`.
  - `valid_notes` (`:170-179`) accepts a list keyed 1..n with no hole, 1-8 whole degrees in -14..14.
- `M.step_attr(voice, step, key)`, `:212-218`. It returns a copy when the value is a table and nil when the place is invalid.
- `M.set_step_attr(voice, step, key, value)`, `:223-234`. It does nothing for an invalid place or for a key missing from `ATTR_CHECKS`. An empty notes list becomes nil. A value that fails its check does nothing. Otherwise it stores a copy of a notes list, and `steps[step] = next(attrs) ~= nil and attrs or nil`. It then calls `S.lib.mutation.note_pattern_edit(voice)` and `grid_redraw()`.
- `pos`, `pitch`, `size` and `bookmark` are "locks": `step_locks` (`:738-747`) copies the `SEQ.lock_keys` that are set. `bookmark` has no entry in `lock_params`, so it is not a base override. `apply_step` recalls it (`:586-589`) only when `S.lib.bookmarks.is_set` and `bookmark_in_loop` (`:408-413`) are both true.

### The `steps` scene block

- Registration: `lib/sequencer.lua:279-286`, with `key = "steps"` and `discrete = true`. Its parts:
  - `default`: `copy_steps({})`, which is `NUM_VOICES` empty tables.
  - `capture`: `copy_steps(S.pattern_steps)`.
  - `validate`: `M.valid_steps`.
  - `apply`: `set_all_steps`.
- `copy_steps` (`:256-269`) copies each key verbatim (a table value through `copy_list`) and drops empty steps.
- `M.valid_steps` (`:238-253`) checks every voice key with `valid_voice`, every step key as a whole number in 1..`PATTERN_LENGTH`, and every attribute through
  ```lua
  if ATTR_CHECKS[key] == nil or not ATTR_CHECKS[key](value, voice_idx) then return false end
  ```
  It also requires `steps[1..NUM_VOICES]` to be tables. **An unknown key rejects the whole scene.**
- A chain link applies the block with `set_all_steps(data.steps or {})` (`:1014`), with no validation of its own: `next_chain_scene` has already run `validate_scene` (`:1002`).

### Versions and migrations (`docs/notes/lua/scenes.md`, `lib/scenes.lua`)

- `SCENE_DATA_VERSION = 7` (`lib/constants.lua:11`).
- Loading: `lib/scenes.lua:1124-1131` checks `is_integer_between(loaded.version, 1, SCENE_DATA_VERSION)`. Any other version prints `error: scenes file has version ...` and calls `preserve_unloadable_scene_file()`, which renames the file to `.bak` and the next free names (scenes.md:22, :301). A version newer than the build is therefore refused whole: no scene loads.
- Then `migrate_scene` runs on every slot (`:1143-1147`), then `validate_scene_data` (`:1149`). If any slot fails, the file is set aside the same way (`:1150-1151`).
- The rules (scenes.md:4, :280):
  - "When to bump `SCENE_DATA_VERSION`: once per release that adds scene fields, never per field, and whenever a stored value changes meaning".
  - "Migration fills whatever is missing whatever the file's version".
  - A registered migration is `{name, before_version, migrate}` (scenes.md:287). It runs when `before_version > from_version`, and it must be idempotent.
- **Does an optional key in the sparse steps block need a version bump?**
  - In this build, no migration is needed: the block's `default` and sparse absence mean "plain step".
  - The scenes rule still says a release that adds scene fields bumps the version once.
  - Older builds (3.6 and earlier) reject an unknown step key in `valid_steps`, so a 3.7 file with a new attribute is refused whole and set aside by 3.6, whether or not the version rises. With a bump, 3.6 refuses it at the version check instead (`lib/scenes.lua:1127`), with a clearer console line.
  - Either way 3.6 never overwrites it: the file is set aside, or the autosave is blocked if the rename fails.
- A new step-attribute key that changes no stored value's meaning needs no `migrate_scene` conversion. A change of meaning does (scenes.md:4).
- A file older than the current format is kept as `scenes.data.v<n>` before the first save (scenes.md:26, `keep_copy`).

### The table cap

- `lib/data_files.lua:26-40`:
  - `max_tables = 32768`.
  - `largest_scenes_tables = 7394`, with the comment "Raise it with a release that adds scene tables, and max_tables with it".
  - `max_bytes` is 4 MB (data-files.md:34).
- Rule (data-files.md:6, ruling 90): `max_tables` stays at least 4 × the largest file. `test/unit/data_files_test.lua` checks it.
- `test/unit/matrix_test.lua:1353-1395` builds the largest file:
  - 16 macros × 8 targets, 16 routings, and on every voice and step `notes` (8 degrees) plus `prob, ratchet, pos, pitch, size, bookmark, gate`.
  - It asserts `tables == largest` **exactly** (`:1395`), so any new tables-per-step key, or a change to what the test sets, moves that number and the test.
- What a new per-step key adds, worst case 7 voices × 16 steps × 16 scenes = 1792 places:
  - A scalar key (a number) adds 0 tables, but bytes: about 1792 × the printed length. The file is about 1.0-1.1 MB today against the 4 MB `max_bytes`.
  - A table-valued key (say `{a, b}`) adds 1792 tables, giving 9186. 4 × 9186 = 36744 is over 32768, so `max_tables` would have to rise.
- docs/status.md:27 says the same: "a later block with tables per step or per voice re-measures it, since a file over the cap is refused whole".

### PSETs and patterns

- No PSET hook or side file holds `S.patterns` or `S.pattern_steps`.
  - Searched: `register_pset_hook` call sites are morph, scatter, macros, io_midi_out, gestures, matrix, lfos and io_keyed.
  - Patterns and step attributes live only in memory and in scenes. sequencer.md:61 says the `strata_seq` params are "PSETs store them; scenes don't".

### Constraints

- Every new attribute goes through `ATTR_CHECKS`. `set_step_attr` and the block share it, and an absent key must mean the 3.6 behavior.
- 3.6 cannot read a file holding a new step key. That is expected, and the file is never overwritten, but it is a one-way upgrade.
- Table-valued attributes cost about 1792 tables each in the worst file, and `largest_scenes_tables`, `max_tables` and the matrix test's exact figure all move.

---

## 2. How a voice advances; what assumes forward order

### The position and its wrap

- Per voice state (the comment at `lib/sequencer.lua:95-125`): `{anchor, tick, beat, due, position, pass_length}`.
  - `position` is "the next step it plays".
  - `end_clocks` (`:1235-1246`) makes it `{anchor = 0, tick = 0, beat = 0, position = 1, pass_length = PATTERN_LENGTH}`.
  - `voice_clock` (`:1167-1171`) sets `state.position, state.pass_length = 1, voice_length(voice_idx)`.
- `take_position` (`:1042-1057`), the whole advance:
  ```lua
  local length = voice_length(voice_idx)
  if length ~= state.pass_length and state.position <= length then state.pass_length = length end
  if state.position > state.pass_length then
    state.position, state.pass_length = 1, length
    if (overrides[voice_idx] or chords[voice_idx]) and not M.has_set_step(voice_idx) then
      end_overrides(voice_idx)
    end
  end
  local step = state.position
  state.position = step + 1
  return step
  ```
  - The wrap is "position past pass_length goes back to 1".
  - A length change applies at once while the position is inside the new length; otherwise it applies at the wrap.
  - At the wrap, the overrides and chord end when no set step is left inside the length.
- `begin_voice_step` (`:1062-1090`):
  1. `at_beat(state.beat)` runs first (a chain link).
  2. `step = take_position(voice)` and `S.pattern_sounding_steps[voice] = step`.
  3. The level and the attributes are read.
  4. The probability draw, exactly:
     ```lua
     local prob = attrs.prob or SEQ.max_prob
     if level > 0 and prob > 0 and (prob >= SEQ.max_prob or math.random() * SEQ.max_prob < prob) then
     ```
     It uses the global `math.random`. No draw happens for level 0, prob 0, or prob 100 or nil.
  5. Inside that branch: `step_beats = division + (state.tick % 2 == 0 and swing or -swing)`, then `hits = min(ratchet, max(1, floor(step_seconds / 0.02 + 1e-9)))`, then `step_inputs`, `step_pitches`, and `play_outputs(hit_event(...))` for hit 1.
  6. `finish_beat(state.beat)` runs whether or not the step played.
  7. It returns the plan `{step, level, hits, spacing, beat, semitones, pitches}`.
- `skip_due_ticks` (`:1145-1152`): while the next tick has come, it runs `take_position(voice)` and `take_tick(...)`. **Skipped steps advance the position and draw nothing** (sequencer.md:17, :68).
- `take_tick` (`:1131-1139`): at a division reset's bar it sets `state.anchor, k = reset, 0` and `state.position, state.pass_length = 1, voice_length(voice)`.
- `next_voice_tick` (`:945-956`) and `tick_beat` (`:939-941`):
  ```lua
  state.anchor + k * division + (k % 2 == 1 and swing or 0)
  ```
  Swing parity counts ticks since the anchor, not step numbers (sequencer.md:66). **It is independent of direction.**
- `voice_clock` (`:1167-1197`) runs: begin, then the ratchet hits 2..n (`due_hit`, `:1157-1162`), then `next_voice_tick`, `wait_for`, `take_tick`, `skip_due_ticks`, and begin again.
- `M.restart_voice(voice, beat)` (`:1201-1209`) ends the old clock and starts a new one at step 1. The division reset (`transport_step`, `:1098-1112`) and `start_patterns` (`:1347-1367`) call it.

### Counters

- **No per-voice pass counter exists.** The state has `tick`, the ticks since the anchor, reset to 0 at each anchor (a start, a restart, a division reset's bar). Nothing counts wraps. The transport counts 16ths (`S.pattern_position`, wrapping at 16, `:1108-1109`, `:1227`).
- The chain's bars are counted from the start beat through `chain.next_beat` (`:1031-1034`, `:1363`), not per pass.
- No state records "the previous conditioned step played or not". `last_played[voice]` (`:125`, set in `apply_step` at `:605`) is the last step that *played*, and it is used only for override bookkeeping.

### How the chain and the division reset touch the position

- A chain link (`load_chain_scene`, `:1009-1021`) does not reset any position. It does three things:
  - `end_all_overrides()` and `replace_pattern` for each voice;
  - `set_all_steps`;
  - `params:set` on each voice's `seq_length` and `seq_division` from the scene's extras (only those two keys, `:1017`).
  So the voices keep their positions and ticks through a link.
- The division reset puts every voice back to step 1 on the next bar (`take_tick`; `transport_step` restarts the voices still on their old anchor).
- A scene recall replaces patterns through `replace_pattern` (`:1278-1287`). That ends the overrides and the step gestures but does not touch the position.
- `seq_length`'s action (`:1424-1430`) ends the overrides when `last_played > length`.

### Everything that reads "the next step" or assumes forward order

- `take_position` and `skip_due_ticks`: `position + 1` and the wrap to 1. A random or ping-pong order would also change what `skip_due_ticks` moves through, and that runs several times at a late wake.
- The wrap's end of overrides (`:1050-1052`), which assumes "the wrap" is reaching past `pass_length`.
- `pass_length` (`:1045-1047`): "a length change applies at the wrap" is defined by forward motion.
- `M.has_set_step` (`:203-209`) scans 1..length, which is order-free, but it is called only at the wrap.
- `M.sounding_step(voice)` (`:1535-1544`) returns `S.pattern_sounding_steps[voice]`, the step played last. It is **order-free**, and every playhead reads it:
  - `step_brightness` (`:1549-1556`) lights the sounding step 15 (set) or 4 (empty), steps past the length at 1, and the rest at their level;
  - SEQ's rows and the edit view's strip;
  - the grids.
- The 64's play-key blink reads `sounding_step()`, the transport's 16th (layout_64.md:10), not a voice.
- Euclid (`:1313-1326`) fills `er.gen(hits, length, rotation)` from step 1, by step index. It is order-free.
- `hit_event.step` (`:751-764`) is the step index. The targets (`lib/io/targets.lua`) and any output get it as it is.
- The transport's `S.pattern_position` / `S.pattern_sounding_step` are 16ths, independent of any voice's direction.

### What a reverse, ping-pong or random order would have to touch (facts, not a design)

- `take_position` (the next index and the wrap rule) and its two callers, `begin_voice_step` and `skip_due_ticks`.
- The initial `position = 1` in `voice_clock`, `end_clocks` and `take_tick`'s reset.
- The wrap-time override end and `pass_length`'s "at the wrap".
- `seq_length`'s `last_played > length` check: a reverse voice past its new length.
- A random order's draws would consume `math.random`, as prob does. The seeded tests depend on the order of draws (sequencer.md:97 notes this for `randomize_pattern`).
- The playheads need nothing: they read the step played.

### Constraints

- No-bursts (rule 4): skipped ticks must advance whatever the order model is, without playing.
- A step that does not play (level 0, prob miss) leaves the previous played step's overrides in place. They end only at the next *played* step (`apply_step`, `:580-582`).
- "One reckoning per step": `stepping[voice]` is consumed by the first hit (`:519`, `:571-572`).

---

## 3. The SEQ page, the arc's SEQ rings, the grids' step keys and fill-key candidates

### SEQ's two views (`lib/pages/seq.lua`, `docs/notes/lua/pages/seq.md`, `docs/user/pages/seq.md`)

- **The pattern view** (seq.md:21-37):
  - Layout: 7 rows 6 px apart from y 13, so the last row's top is y 49 and its cells end at y 53. Sixteen 4×4 cells from x 10 to x 103. The `G` gate mark is right-aligned at x 121. `+`/`-` is at x 127 (`SEQ_PAGE`, `lib/pages/seq.lua:47-50`).
  - Free room: about x 104-116 between the cells and the `G`; no vertical room above the hint row (y 62).
  - Keys, all taken:
    - E2 the step and E3 the level; K2 play/stop and K3 the toggle.
    - ALT+E2 the voice and ALT+E3 the tempo.
    - ALT+K2: a quick press randomizes or undoes; held 0.5 s it opens the edit view.
    - ALT+K3 clears the pattern.
- **The edit view** (seq.md:39-55) is a field list (`S.lib.ui_field_list`): 5 rows in view, 7 px apart from y 24, scrolling, with `EDIT_ROWS` at `lib/pages/seq.lua:69-95`.
  - Section `voice`: `length`, `division`, `swing`, `gate`, `gate len`, `gate rel`, `euclid`, `clear`.
  - Section `step <n>`: `level`, `prob`, `ratchet`, `gate` (`step_gate`), `note` with `note 2`..`note 8` and `add note`, `pos`, `pitch`, `size`, `bookmark` (only while `has_bookmarks`).
  - Section `chain`: `chain`, `from`, `scenes`, `bars`, `quantize`.
  - Keys, all taken:
    - E2 the row and E3 the value; ALT+E2 the step; ALT+E3 fine (on euclid, the rotation).
    - K2 back and K3 the toggle (on `clear`, a clear).
    - ALT+K2: a quick press randomizes or undoes; held, `reset_row`. ALT+K3 clears.
  - Rows can be added (the list scrolls). `layout_states` must cover every row at its widest (seq.md:67), and `edit_windows` counts rows from `#EDIT_ROWS` (`lib/pages/seq.lua:969`).
- **The step editor** is the edit view pushed as a modal owner (`open_step_editor`, `close_step_editor`, `step_editor`, `step_editor_replacing`, seq.md:57-65) for any voice and step. The grids open it on a held step key.
- **How an attribute is edited** (seq.md:9, :55): only through `S.lib.pages_seq.turn_step(voice, step, key, d, opts)`, which calls `set_step_attr`.
  - Continuous locks step by the param's quantum (or `opts.raw` of the range from the arc). From `off` they start at the stored value; below the start they go `off`.
  - `prob` stores 100 as nil and `ratchet` stores 1 as nil.
  - `lock_raws` keeps the sub-step raw place for each voice, step and key.

### The arc's SEQ rings (`lib/arc/seq.lua`)

- Page rings (`:58-77`): 1 the step cursor, 2 the level, 3 the tempo, 4 the voice.
  - `arc_seq_delta` never reads `S.alt_held`, so **the page rings have no ALT layer (free)**.
  - The button plays and stops.
- Step editor rings (`ARC_SEQ`, `:26-34`, `editor_delta` `:117-135`):
  - plain: 1 `pos`, 2 `pitch`, 3 `size`, 4 `prob`;
  - ALT: 1 `ratchet`, 2 `notes` (the cursor's note), 3 `bookmark`, 4 `level`.
  - **All eight are taken**, and the editor has no button.

### The grids (`docs/notes/lua/grid-core.md:21-23, :89-90, :95-114`)

- **`step_key(port, x, y, z, voice, step, position, positions)`**:
  - A press makes the key the voice's held step and arms `on_hold(..., GRID_HOLD.step_edit_seconds, ...)`, 0.3 s.
  - A second key of the same voice sets the held step's level, `max(1, round(position × 15 / positions))`.
  - The release toggles the step unless the key was consumed.
  - Held 0.3 s, the key opens the screen's step editor.
  - **A grid edits only levels and on/off itself.** Every other attribute is edited on the screen or arc while a grid key holds the editor open.
- **The 256** (`lib/grid/layout_256.lua:296-415`, notes `docs/notes/lua/grid/layout_256.md:28-49`):
  - Page 1: rows 1-7 are the patterns.
  - Row 8, every page: columns 1-4 play/stop, 5-8 tempo, 12 the positions page, 13-16 pages 1-4. **Columns 9-11 have no handler and stay dark** (`grid_key_256_transport` `:403-415`, `grid_redraw_256_transport` `:583-596`).
  - Row 9: columns 1-4 recorders, 5-11 mute keys, 13-16 banks. **Column 12 does nothing** (layout_256.md:5).
  - Rows 10-13: macros. Row 14: columns 1-7 voice select, 9-15 voice on/off. **Columns 8 and 16 are free** (`:386-393`).
  - Row 15: hold-to-clear (1-7) and hold-to-randomize (9-15). **Columns 8 and 16 do nothing** (layout_256.md:49).
  - Row 16, every page: lock, the freeze hold (8), copy/paste (9-15), clear clipboard (16).
  - Releases: the layout returns on `z == 0` (`:303`) after page 1's rows 9-13 and page 3's recorders. A held key is still visible to code through `grid_core.held(port, x, y)`: row 16 column 8's freeze hold is read that way with no release handler (layout_256.md:41).
- **The 128h** (`lib/grid/layout_128h.lua:175-190`, notes `docs/notes/lua/grid/layout_128h.md:20-27`):
  - Page 1 is rows 1-7 patterns plus row 8, so no key is free.
  - Row 8: columns 1-4 all `pattern_toggle()` (`play_last_column`), 5-8 pages, 9-15 voice on/off, 16 cycles the grid voice.
  - **No unused key on the patterns page.** Columns 2-4 of row 8 duplicate play/stop.
  - Releases reach only positions and page 3's recorders.
- **The 128v** (`lib/grid/layout_128v.lua:132-150`, notes `:24-31`):
  - Patterns page: columns 1-7 × rows 1-16 are steps.
  - Column 8: rows 1-7 voice toggles, row 8 the page key, row 9 play, rows 10-16 voice select.
  - **No unused key.**
- **The 64** (notes `docs/notes/lua/grid/layout_64.md:3-22`):
  - Steps views: rows 1-7 × 8 columns are steps (one half).
  - Row 8: column 1 is a tap for play and a hold to cycle the views; 2-8 voice toggles.
  - **No unused key.**

### Constraints

- A fill key held from a grid exists only on the 256's spare keys:
  - row 8 columns 9-11, on every page;
  - row 9 column 12, row 14 columns 8 and 16, and row 15 columns 8 and 16, on page 1.
- No norns key or arc ring on SEQ is unused, except the page rings' ALT layer and a field-list row.

---

## 4. The scene sequencer and the pattern chain

### Params

| Id | Type | Range | Default | Where |
|---|---|---|---|---|
| `scene_sequencer_enabled` | binary toggle | 0/1 | 0 | `lib/params_setup.lua:417-430`; the action calls `scene_sequencer_start()`/`stop()` |
| `scene_transition_time` | control | 0-30 s, lin, step 0.5 | 2 s | `:432-440` |
| `scene_duration` | control | 4-120 s, lin, step 1 | 16 s | `:442-450` |
| `scene_sequence_length` | number | 1..`NUM_SCENES` (16) | 4 | `:452-463`; the action calls `grid_redraw()` |
| `seq_chain` | binary toggle | 0/1 | 0 | `lib/sequencer.lua:1399-1400`; the action is `chain_switched` |
| `seq_chain_from` | number | 1..16 | 1 | `:1401-1402` |
| `seq_chain_scenes` | number | 1..16 | 2 | `:1403-1404` |
| `seq_chain_bars` | number | 1..`SEQ.max_chain_bars` (16) | 4 | `:1405-1406` |

The `strata_seq` group (`M.add_params`, `:1397-1413`) is `SEQ.group_params` (6) plus `S.lib.quantize.PARAM_COUNT` params, in this order:

1. the four chain params;
2. the quantize params;
3. `seq_division_reset` (trigger);
4. `seq_follow_transport` (binary, 1).

PSETs hold these params and scenes do not. The scene sequencer's params are not scene fields either: `SCENE_GLOBAL_PARAMS` does not list them. **Not found**: a scene field that holds them.

### The scene sequencer's loop (`lib/scenes.lua:914-1015`)

- `scene_sequencer_start()` cancels any running clock and sets `position = 1` and `recall_due = true`. It then runs one `pass()` after another inside `clock.run`, with `clock.sleep(0)` first (because of the PSET read order).
- A `pass()` (`:926-980`):
  1. Guard: wrap the position to 1 past `scene_sequence_length`.
  2. `position = first_scene_from(position, length) or position`, which skips empty slots (`:906-912`, wrapping within 1..length).
  3. `recall_due = false`.
  4. If the slot is populated, `recall_scene(position, transition_time)` inside `xpcall`. Otherwise print a line and hold the slot.
  5. `clock.sleep(max(scene_duration, transition_time))`, then `wait_for_scene_transition()`.
  6. `position = position + 1`, wrapping to 1 past the current length.
  7. `recall_due = true`, `request_redraw()`, `grid_redraw()`.
- **The sequence is always slots 1..length.** There is no "from" param, and the timing is in **seconds**, not beats.

### Where "next" is computed

- Scene sequencer: `M.sequencer_next_slot()` (`lib/scenes.lua:1474-1481`):
  ```lua
  local next_slot = S.scene_sequencer_position
  if not S.scene_sequencer_recall_due then next_slot = next_slot + 1 end
  if next_slot > length then next_slot = 1 end
  return first_scene_from(next_slot, length) or next_slot
  ```
  - It is computed from the position each time it is asked, not stored.
  - Readers: `grid_core.scene_recall_level` (`lib/grid/core.lua:464-472`, `SCENE_LEVELS.next = 10`), used on every layout with a scenes page.
  - **The pass's own advance does not call it.** The display and the advance agree only because both run the same arithmetic.
- Chain: `chain_slots()` (`lib/sequencer.lua:985-991`, `seq_chain_scenes` slots from `seq_chain_from`, wrapping past 16) and `next_chain_scene(current)` (`:995-1005`: the slot after `current` among them, wrapping, the first populated and `validate_scene`-valid).
  - `chain.current` is local (`:127`).
  - **Nothing displays the chain's next or current scene.** A link is not a recall: it changes neither `S.current_scene` nor `takeovers()`, and runs no `scene_recalled` hooks.
  - `chain_link` (`:1023-1026`) runs from `at_beat` (`:1030-1035`), which the first participant to reach `chain.next_beat` calls. That participant advances `chain.next_beat += seq_chain_bars × 4`.
  - A start with the chain on links at once (`:1361-1364`).
  - `chain_switched` (`:1389-1392`) sets `chain.current = nil` and the next bar.

### What SCENES shows and which keys are free (`lib/pages/scenes.lua`, `docs/notes/lua/pages/scenes.md`)

- One bank of 8 slots in 2 columns of 4, at baselines y 16, 24, 32, 40. While the sequencer runs, a `>` mark (level 10) sits in front of the slot at its **position** (not the next).
- Four fields as a 2×2 block at y 48 and 55: `SCENES_FIELDS` (`lib/constants.lua:111`) are `scene_transition_time`, `scene_sequencer_enabled`, `scene_sequence_length` and `scene_duration`, at cursor stops 17-20.
- The page is full vertically: a hint row at 62 and fields at 48 and 55.
- Keys on a slot: E3 the transition time, K2 fade, K3 recall, ALT+K2 name, ALT+K3 save (armed), ALT+E2 jumps a bank, E2 the cursor.
- **On a field, K2, K3, ALT+K2 and ALT+K3 do nothing** (`scenes_key` `:245-253` returns when `slot > NUM_SCENES`; scenes.md:1 and :172-173). Only E3, ALT+E3 and E2 act there.
- A new field changes `SCENES_FIELDS`, the cursor stops (`lib/ui/cursors.lua`) and the 2×2 drawing (`:162-168`).

### Constraints

- A chance rule that picks the next scene must agree with what `sequencer_next_slot` shows at level 10. The draw would have to be made once and kept, or the light would show a value the pass does not take.
- The sequencer must keep these behaviors:
  - empty slots skipped at once (#513);
  - "never cuts a transition short";
  - the stop through its param on an error (#329);
  - the `scene sequencer` invariant.

---

## 5. MIDI notes in, pitch, slots, `noteExpression` position, latch

### Note modes (`docs/notes/lua/midi.md:53-54, :69-75`)

- `midi_channel_mode` (option, default 1):
  - `per voice`: channel 1..7 is voice 1..7;
  - `omni to selected`: every channel goes to `S.selected_voice`;
  - `mpe selected`;
  - `mpe split`: every voice whose zone and range hold the note.
- `midi_note_off` (option, default 1): `auto` (latch in the plain modes, release in the MPE modes), `release`, `latch`.

### A note to a pitch

- `midi_note_on` (`lib/midi_in.lua:433-455`):
  1. `expression.forget` and `first_touch`, then `S.lib.sequencer.note_gate(voice)`.
  2. It calls
     ```lua
     S.lib.notes.play(voice_idx, {owner = MIDI.owner, key = key,
       pitch = S.lib.variation.midi_note(voice_idx, note), velocity = velocity / MIDI.velocity_max, park = true,
       set_own = own_setters[voice_idx], expression = ...})
     ```
  3. When the note lands on slot 1, `S.lib.sequencer.own_note_taken(voice)`.
- `own_setters` (`:410-423`) set one param per source, clamped to its range:
  ```lua
  local id, value = prefix .. "grain_pitch", 2 ^ ((pitch - MIDI.rate_root_note) / 12)
  if voice_uses_synth(i) then id, value = prefix .. "freq", musicutil.note_num_to_freq(pitch)
  elseif voice_uses_buffer(i) then id = prefix .. "buf_rate" end
  ```
  So a synth voice sets `v<i>_freq`, a buffer voice `v<i>_buf_rate`, an input voice `v<i>_grain_pitch`. `MIDI.rate_root_note = 60` (`:26`): note 60 plays rate 1.
- `S.lib.variation.midi_note(voice, note)` (`lib/variation.lua:222-225`) snaps to the scale's nearest tone when `M.quantizes(voice)`.
- `S.lib.notes.note_values(voice, pitch)` (notes.md:53): `{note, freq, rate}`, with `rate = 2 ^ ((pitch - 60) / 12)` clamped to 0.25-4. On a frozen synth voice it uses `2 ^ ((pitch - reference)/12)`. notes.md:13: "`note_values` is the one place a pitch becomes what the engine plays".

### Slots (the allocator's branches, notes.md:25-35)

1. The same owner and key: re-pitched in place.
2. Slot 1 free (empty, parked or stopped): `set_own`, a start through `toggle_voice` if stopped, then `retrigger`. With `quiet` there is no start and no retrigger.
3. A free extra slot under the cap with room in the pool: `noteExpression` then `noteOn`.
4. The pool is full: steal the oldest stealable extra note (`noteOff(...,1)`), then as 3.
5. No free slot under the cap: replace the voice's oldest extra note in place.
6. Nothing can be stolen: slot 1, whoever held it.

`extra_only` takes only branches 1 or 3.

### `noteExpression`'s `position`

- Lua: `NOTES.expression_keys = {bend, amp, position, size, main}`, neutral `{1, 1, 0, 0, 0}`, position clipped to -1..1 (notes.md:19).
- Who sets it: `lib/expression.lua` only, from pressure or slide mapped to the target `position` (a buffer voice only) or `main` (on a buffer voice, the note's `position`). See expression.md:20, :26-31.
- What it does in the engine:
  ```
  fastModPosition { arg bufPos, m, notePos;
    ^(bufPos + (this.fastModHalfRanges[1] * (m[1] + notePos.lag(this.noteLag)))).clip(0, 1) }
  ```
  (`lib/engine/StrataModulation.sc:198-200`). It is an **offset** of ±0.5 of the region (the half range 0.5, `lib/lfos.lua:48` `fast_half_ranges[1] = 0.5`) from the voice's `bufPos`, lagged `noteLag`, never an absolute start.
- An extra note's scan "starts at the voice's position, as any grain start does" (docs/notes/engine/notes.md:48).

### Latch

- midi.md:6: a note off sends nothing, and the next chord replaces the last.
- Ruling 55 (`M.keeps_own`, `lib/midi_in.lua:465-...`): a latched own note gives way to a step's first note.

### Where "a note plays slice N" could branch, and what pitch would mean (facts)

- The pitch is decided in `midi_note_on` (`variation.midi_note`) and applied by `set_own` (slot 1: `buf_rate`) and `note_values` (extra slots: `rate`).
- Today a buffer voice's MIDI note is **only** a rate. No Lua path sets an absolute read position per note: the own note moves the voice's `buf_pos` only through params, and an extra note can only offset through `noteExpression`'s lagged ±0.5 `position`.
- The note number is the slot's 128-key identity (`key = channel * 128 + note`, `lib/midi_in.lua:436`, midi.md:39). A slice mode would reuse the note both as the key and as the slice index.

### Scale quantize for buffer voices

- `scaleNote` for a buffer or input voice is `root + 60` (variation.md:26).
- The engine adds the rate's semitones (`root + 60 + 12 log2(buf_rate)`), "so a MIDI note (rate 1 is note 60, not the root) ... transposes the voice without moving the scale".
- An extra buffer note gets its own `noteScaleNote` (engine notes.md:48).

### Constraints

- `S.lib.notes` alone calls `noteOn`, `noteOff`, `noteExpression` and `setNotePool`.
- A per-note absolute position does not exist in the 3.5 command set (`noteOn(voice, slot, note, freq, rate, velocity)`).
- Any slice-by-note path for extra notes needs either the relative, lagged `position` or a command change (`docs/design/3.7-facts/engine.md` §1).

---

## 6. Modulation sources, the matrix, the LFO clock; triggering a source; MOD and LFO pages

### Registering a source

- `S.register_mod_source(record)` (`lib/state.lua:475-...`). The fields (`MOD_SOURCE_FIELDS`, `:369-371`) are `key, name (1-4 chars), section, value, range, describe, visible, row{enc, fine_enc, press, alt_press, hints}`.
- The registry is read at each use (it is not in `INIT_READ`, `lib/state.lua:72-73`).
- Readers: `S.lib.mod_sources` (`lib/mod_sources.lua`): `get`, `list`, `registered`, `sections`, `fraction`, and `normalized`:
  - a bipolar source (`range[1] < 0`) gives `2f - 1`;
  - a unipolar one gives `f`;
  - a value that is not finite gives 0.
- Sources today:
  - `lfo1-6` (`lib/lfos.lua:1052`);
  - `macro1-16` (`lib/macros.lua:701`);
  - `gesture1-4` (`lib/gestures.lua:780`);
  - `input` (`lib/input_level.lua:105`);
  - the expression sources (`lib/expression.lua:417`);
  - `crow1-2` (`lib/io/crow.lua:442`).

### The 48 Hz step

- `LFO = {step_hz = 48, sends_per_step = 12, lua_max_hz = 10, engine_max_hz = 50, send_threshold = 1/1000, ...}` (`lib/lfos.lua:38-40`).
- `step_all` (`:671`), every 1/48 s, in this order (lfos.md:77-81):
  1. the six LFOs;
  2. the direct destinations;
  3. the `on_step` hooks (`M.on_step`, `:373`): the macros', then the matrix's (`lib/matrix.lua:399`), then the note flush;
  4. the drain: at most 12 due keys in a round robin (`M.mark_due(key, send)`, `:343`), each inside `deferrable`.
- `ENGINE_BUDGET = {messages_per_window = 150, window_seconds = 0.1}` (`lib/constants.lua:363`; `lib/engine_sync.lua:162-245`).
- The matrix step (matrix.md:43-50): for each playing routing, `m = depth/100 × normalized(source)`, summed by destination.
  - A Lua destination gets `set_extra_offset("matrix", id, sum)` and is marked due when it moved past `send_threshold` from `expected_value`.
  - A fast destination gets the sum plus the macros' fast extras, clamped to -2..2. It is marked due under `matrix fast <voice> <destination>`, whose sender (`lib/matrix.lua:218-219`) is
    ```lua
    engine.setFastOffset(voice - 1, MATRIX.note_slot, destination, value)
    ```
    and is sent through `send_engine_value`, which counts against the budget.
- The engine's `\strataFastOffsets` lags every offset 50 ms:
  ```
  Out.kr(out, Lag.kr(\offsets.kr(0 ! numChannels), lag))   // lag = 0.05
  ```
  (`lib/engine/StrataModulation.sc:271-273`).
- **So a Lua-run envelope through the matrix updates at most once per 1/48 s (about 21 ms) and is then smoothed by a 50 ms lag.** A 5 ms attack cannot be made that way. A Lua-run LFO is capped at 10 Hz (`lua_max_hz`). ROADMAP.md:145 already states: "An envelope on a fast destination must run in the engine, as an LFO there does, as a persistent node a step re-triggers: a step never creates one."
- Lua destinations (not fast) are sent at most once per step, shared with the 12-per-step cap and the threshold, and the engine's send path for most params also lags (engine area).

### The sample-and-hold shape: where the draw is

- Lua: `draw(n)` (`lib/lfos.lua:240-245`) is `math.random()`; for drunk it is the last value ± 0.2, reflected.
  - `new_cycle` (`:247-251`) runs at each wrap.
  - `lfo_u` (`:254-260`): s&h returns `state[n].to`, and smooth and drunk interpolate.
- Engine: `fastLfoShape` (`StrataModulation.sc:282-293`): s&h is `fastLfoDraws(phase, Dwhite(0, 1, inf))[\next]`, drunk is `Dbrown(0, 1, 0.2, inf)`. A draw is made at the start and at each wrap (`fastLfoDraws`, `:298-302`).
- **Lua and the engine draw independently.** An engine-run s&h LFO's Lua value (`M.value(n)`, which the matrix and the `lfo<n>` source read) is Lua's own draw, not the engine's (lfos.md "the dot is ... Lua's draws; an engine LFO draws its own, of the same kind", pages/lfo.md).
- Nothing keeps a sequence of draws: each cycle replaces `from`/`to`.

### Hooks for "voice v was hit by a step or a note"

- **Step outputs** (`S.register_step_output`, fields `{name, play, stop, available}`, `lib/state.lua:368, :443-448`). The registry is read at each hit (`lib/sequencer.lua:707-726`).
  - Every hit (ratchets included, with `event.first`) goes to every output, the `voices` output first.
  - 3.6's targets register theirs at a start step (`lib/io/targets.lua:345-350`), so a registration after the constructor works.
  - Each non-voices output runs in its own coroutine, must never yield, and fails alone.
- **Note hooks** (`S.register_note_hook`, fields `{name, started, ended, moved, expressed}`, `lib/state.lua:513, :522-527`; notes.md:14).
  - `started` fires once a record takes a slot, and `moved` fires for a held note re-pitched in place. Each is called as `(voice, slot, {owner, key, pitch, velocity})`, contained, and never yields.
  - Every MIDI note through `S.lib.notes.play` fires them, and so does every step **chord** note (owner `"seq"`).
- **A step with no notes never goes through `S.lib.notes`.** `voices_play` (`lib/sequencer.lua:631-648`) calls `engine.retrigger` directly, so note hooks miss plain step hits. A module that wants steps and MIDI notes alike needs a step output (for steps) and a note hook filtered on `owner == "midi"` (for MIDI), or it will hear chord steps twice.
- **`engine.retrigger` call sites:**
  - `lib/notes.lua:379` (the own note, unless `quiet`);
  - `lib/sequencer.lua:645` (the voices output);
  - `lib/io/actions.lua:85` (crow/OSC/remote actions, which reach no hook).

### The MOD page (`docs/notes/lua/pages/mod.md`, `lib/pages/mod.lua`)

- **The list:**
  - Five rows from y 18, 8 px apart, scrolling.
  - `MOD_PAGE.sections = {"macros", "morph", "scatter", "gestures", "lfos", "matrix"}` (`:41`). Any other section follows in the order its first source registered.
  - A row shows `name` (≤ 4 chars), `describe()` and its value.
  - Keys: E3 `row.enc`, ALT+E3 `row.fine_enc`, K3 `row.press`, ALT+K3 `row.alt_press(3)`, ALT+K2 held `alt_press(2)`, K2 the next section.
  - A source without `row` is read-only.
- Only the macros (target view) and the matrix (routing view) have views. MOD knows them by section, and a new view needs MOD code.
- The existing pattern for a source with many settings is the LFOs': the MOD row's K3 is `show_lfo(n)`, which shows the LFO page.
- The routing view offers every registered source, hidden ones too (`registered()`).
- **Room:** rows scroll, so a new section costs no screen room. Each row's text is cut to fit (`fit_text`).

### The LFO page (`docs/notes/lua/pages/lfo.md`)

- A window of 3 of the 6 LFOs (rows 13 px apart from y 11) and a strip under the selected LFO.
  - The strip is `LFO_FIELDS`, 12 fields that scroll horizontally (`strip_view`): `dest, shape, mode, rate, depth, offset, phase, rate mod, rate amt, depth mod, depth amt, on/off`.
  - Rows and strip are bounded to y 10-56.
- Keys: E2 the field, E3 the value, K2/K3 the LFO, ALT+K3 on/off, ALT+K2 randomize or reset.
- The page is LFO-specific (`S.lib.lfos` state, `LFO_FIELDS`), with no room for more rows. Fields can be added to the strip (it scrolls).
- Arc LFO rings: 1-3 the window's depths, 4 the selected rate or division (arc-pages.md:68-73).

### Constraints

- A source's `value`, `describe` and `visible` must be cheap, never send and never yield: MOD reads them up to 15 times a second.
- A source's value must stay in `range`.
- Any engine-run modulator must keep to "at most one node per engine LFO ... and one scatter node" (AGENTS fast modulation), unless a new rule is written.

---

## 7. The delay; the clocked LFOs and the tempo

### Params (`lib/params_setup.lua:491-630`, the group `strata_fx`, size `FX_GROUP_PARAMS` plus registered `fx_params` counts)

| Id | Spec | Default |
|---|---|---|
| `delay_time` | control 0.01-2 s, exp, step 0.001, unit `s` (`:546-556`) | 0.375 |
| `delay_feedback` | control 0-0.95, lin, step 0.01 (`:558-568`) | 0.4 |
| `delay_mix` | control 0-1, lin, step 0.01 (`:570-580`) | 0 |
| `delay_bypass` | binary (`S.lib.voice_mix.BYPASS`, fx.md:4) | — |

- Each action calls `note_param_edit`, then `send_param_to_engine`, then `fx_fader_changed()`.
- One sender for all three (`lib/engine_sync.lua:467-469, :493-495`):
  ```lua
  engine.setDelay(engine_param_value("delay_time"), engine_param_value("delay_feedback"),
    engine_param_value("delay_mix"))
  ```
- `delay_time` is also:
  - a continuous scene global (`lib/scenes.lua:98`, default 0.375);
  - the LFO and matrix destination `dly time`;
  - a fader on the 256's FX page (`lib/grid/core.lua:48`);
  - FX arc ring 3 (`lib/arc/fx.lua:10-15`);
  - in FX's randomize spec (0.05-1.0 s, even in octaves, fx.md:7).
- A new FX param goes in through `S.register_fx_params({name, count, add})` (`lib/state.lua:320-330`). Its params follow the built-in ones.

### The FX page (`docs/notes/lua/pages/fx.md`)

- A field list: 5 rows in view from y 18, 8 px apart, scrolling.
- Sections master, filter, delay (time, fdbk, mix) and reverb. Rows can be added.
- K3 on a delay row toggles `delay_bypass`. ALT+K3 does nothing on FX.
- Arc FX rings: 1 filter freq, 2 res, 3 delay time, 4 delay mix. **They have no ALT layer** (`arc_fx_delta` ignores ALT).

### How a clocked LFO turns a division into a rate

- `LFO.divisions` and `division_values` (`lib/lfos.lua:45-47`): 22 values, from 1/16 to 1024, default index 13 (`4`). The period is `value × 4` beats (`beats_per_division = 4`, `period_beats` `:275-277`).
- `base_rate(n) = 1 / (period_beats(n) * beat_seconds())` (`:281-284`), with `beat_seconds()` set to `S.lib.params_setup.beat_seconds_now()`.
- `beat_seconds_now()` (`lib/params_setup.lua:120-123`):
  ```lua
  if params:string("clock_source") == "internal" then return 60 / params:get("clock_tempo") end
  return 60 / clock.get_tempo()
  ```
- How it follows a tempo change: **by polling**. Every 48 Hz step re-reads `beat_seconds_now()`. A change of an engine LFO's base rate past 0.5 % (`engine_rate_threshold`) "goes out in the step that sees it, ahead of the round robin and not counted in `sends_per_step`" (lfos.md:14).
- A clocked LFO's phase is computed from `clock.get_beats()` (`:313-322`), and an engine LFO is resynced every bar (lfos.md:12).

### norns' tempo hook and Strata's use of it

- `~/src/norns/lua/core/clock.lua`:
  - `clock.tempo_change_handler = nil` (`:145`).
  - It is called by the `clock_tempo` param's action with `bpm` (`:229-238`, internal and link).
  - It is called once a second for external sources (MIDI, crow) when the rounded tempo changes (`:350-365`, `external_tempo = math.floor(clock.get_tempo() + 0.5)`).
  - Script cleanup sets it back to nil (`:94`).
- Strata installs `follow_clock_tempo` there (`lib/params_setup.lua:66-98`; installed at `:360`, restored at `CLEANUP_ORDER.tempo_handler`). It only sets Strata's `tempo` param silently and chains to the previous handler.
- **No Strata timing reads it.** The LFOs, the sequencer and recordings read `beat_seconds_now()` when they need it.
- `tempo` (`lib/params_setup.lua:348-358`) is a number param with `clock_tempo`'s range (1-300, norns `:228`). Its action is `params:set("clock_tempo", x)`, and it is a discrete scene global.

### Constraints

- `delay_time`'s range is 0.01-2 s. At 60 BPM a half note is 2 s and a bar is 4 s, so longer divisions exceed today's range. The delay line's real maximum is the engine's (`docs/design/3.7-facts/engine.md` §3).
- Whatever owns a synced delay must decide how the scene crossfade of `delay_time`, the LFO and matrix destination, the 256 fader, arc ring 3 and the FX randomize behave while it is synced.
- External clocks report a whole BPM through the handler, at most once a second. `clock.get_tempo()` read at each step is finer.

---

## 8. Buffer voices' per-voice params; voice-param records; the playhead estimate

### The built-in buffer params (`lib/params_setup.lua:985-1035`)

| Id | Spec | Default | Engine |
|---|---|---|---|
| `v<i>_buf_pos` | control 0-1, lin, step 0, no unit | 0 | `setGrainParam(v, "bufPos", x)` (`:1000-1002`); the action also sets `S.buf_pos_base[i]` unless `S.drift_writing` |
| `v<i>_buf_rate` | control 0.25-4, exp, step 0 (#679) | 1 | `"bufRate"` (`:1018-1020`) |
| `v<i>_buf_scan` | control -2..2, lin, step 0.01, **no unit** | 0 | `"bufScan"` (`:1033-1035`) |

- They are grain keys of `GRAIN_PARAM_IDS` (`lib/constants.lua:126-136`), stored in `S.voices[i].grain`, with defaults in `lib/voices.lua`.
- `BUFFER_MUTATION_KEYS = {"buf_pos", "buf_rate", "buf_scan"}` (`lib/constants.lua:123`): mutation moves all three.
- In scenes they are continuous grain keys. LFO destinations: `v<i> pos` (fast) and `v<i> rate` and `v<i> scan` (Lua).
- The voice sync sends all three (`lib/engine_sync.lua:617-619`).
- The user page (`docs/user/params.md:147`): "buffer scan | -2 to 2 | 0 | How fast the position moves through the loop, in loop lengths a second".

### How a registered voice-param record adds an option with a grain key (`docs/notes/lua/params.md:59-80, :118`)

- The record is `{name, count, add, add_first, grain_keys, sync, scene_defaults, discrete, scene_ranges, voice_rows, layout_states, normalize_scene, fader = false, randomize}`.
- `add` calls `S.lib.params_setup.add_voice_extra(voice, record, key, param)` exactly `count` times. The param id is `v<i>_<key>`, its value is in `S.voices[i].extras[key]`, and the action runs the param filter, stores the value, calls `note_param_edit` and `send_param_to_engine`, then the param's own action.
- `grain_keys`: `key = "engineName"` or `key = {name, value = fn}`. They get an `S.engine_senders` entry (`setGrainParam`, a running voice only) and are sent by every voice sync and before every `voiceOn`.
- Examples:
  - `seq` (`lib/sequencer.lua:1418-1459`): count 6; `grain_keys = {seq_gate = {name = "seqGate", value = function(option) return option - 1 end}, seq_gate_release = "gateRelease"}`; `discrete` and `scene_ranges`; no VOICE rows; `fader = false`.
  - `loops` (`lib/loops.lua:117-161`): count 2; `grain_keys = {[start_key] = start_engine, [length_key] = length_engine}`; `normalize_scene`; `voice_rows` shown only for buffer voices (`when`); `randomize`.
- A chain link carries only `seq_length` and `seq_division` (`lib/sequencer.lua:1017`). A new `seq` record key would not follow a link unless it is added there.

### The playhead estimate (`lib/playheads.lua`, `docs/notes/lua/playheads.md`)

- `scan_effective` (`:36-42`):
  ```lua
  local scan = engine_param_value(param_id(voice_idx, "buf_scan"))
  local frozen = S.lib.freeze.is_frozen(voice_idx) and 1 or 0
  local held = S.lib.positions.scan_held(voice_idx) and 1 or 0
  return scan * (1 - frozen) * (1 - held) + S.lib.positions.scrub_rate(voice_idx)
  ```
- `advance` (`:52-64`): `head.phase = (head.phase + scan_effective(v) * (now - head.at)) % 1`. **The wrap is hardcoded `% 1`.**
- `position` (`:68-75`): `start + ((buf_pos + heads[v].phase) % 1) * length`, where `start` and `length` are `loop_start` and `loop_length`.
- Resets (`M.reset`, `:45-48`, phase 0):
  - `S.register_grain_restart` (`:212-214`): every `voiceOn` and every running voice's source switch;
  - `S.lib.positions.jump` (playheads.md:3).
  - **A step's or a MIDI note's `retrigger` does not reset it.**
- The engine's matching formula: `slotScanPhase` is `Phasor.ar(t_scanReset, (scanRate(bufScan, freeze) × (1 − scanHold) + scrubRate) × SampleDur.ir, 0, 1)` (docs/notes/engine/positions.md:3, :14), in "fractions of the voice's loop per second".

### Constraints

- A scan mode (bounce, one shot) and a unit (seconds, beats) change `advance`'s `% 1`, `position`'s wrap and `scan_effective`'s units in step with the engine.
- One shot's "until the next step, note or jump restarts it" needs a reset on events that do not reset the estimate today (the retriggers).
- If `buf_scan`'s stored value is to mean another unit, scenes.md:4 requires a version and a conversion. A per-voice unit option whose default keeps today's meaning would not.

---

## 9. Limits

### Free locals (the probe of `test/unit/structure_test.lua:517-606`, run inline here on Lua 5.3.6; the test requires ≥ 30 in each main chunk and constructor)

| File | Constructor free |
|---|---|
| `lib/sequencer.lua` | 96 |
| `lib/scenes.lua` | 155 |
| `lib/midi_in.lua` | 169 |
| `lib/pages/seq.lua` | 117 |
| `lib/pages/buffer.lua` | 132 |
| `lib/pages/mod.lua` | 102 |
| `lib/pages/lfo.lua` | 163 |
| `lib/params_setup.lua` | 172 |
| `lib/lfos.lua` | 133 |
| `lib/matrix.lua` | 147 |
| `lib/notes.lua` | 149 |
| `lib/macros.lua` | 144 |
| `lib/engine_sync.lua` | 158 |
| `lib/playheads.lua` | 179 |
| `lib/pages/fx.lua` | 180 |
| `lib/pages/scenes.lua` | 168 |
| `lib/grid/core.lua` | 145 |
| `lib/grid/layout_256.lua` | 168 |
| `lib/arc/seq.lua` | 179 |

- Main chunks: every module's is 200 (the constructor is the only thing in it). `lib/constants.lua` is 153 and `strata.lua` 195.
- `lua test/run.lua structure`: 66 tests, 0 failures (the run prints no counts, only failures).
- Note: docs/status.md:24 says "the locals probe in `test/run.lua`". Code wins: the probe is in `test/unit/structure_test.lua:517-606`, which `test/run.lua` runs.

### AGENTS.md's budget

- `wc -w AGENTS.md` = **7917** words against the cap of 8000 (`test/unit/docs_test.lua:779-787`, counted as `%S+`), so **83 words are left**.
- The test also requires the stated figure ("a test fails above 8,000 words").
- docs/status.md:30: "a release that adds rows or rules makes room first, as #696 did for 3.6".
- Every new engine command needs a row in AGENTS.md's command table (a docs test checks one row per `addCommand`), and each row costs about 20-40 words.

### Registries

- `S.registry` (`lib/state.lua:27-62`) holds 31 registries: pages, io_sections, params, start, cleanup, grid_layouts, voice_params, scene_fields, source_change, param_filters, lfo_destinations, fx_params, grain_restart, alt_release, menu_close, invariants, scene_blocks, scene_migrations, pset_hooks, param_touch, lock_change, step_outputs, mod_sources, voice_stop, freeze_change, note_hooks, scene_recalled, silence_change, note_targets, ii_devices, macro_targets.
- `INIT_READ` (`:72-73`) closes 9 at `close_registries()`: voice_params, scene_fields, lfo_destinations, fx_params, start, menu_close, scene_blocks, scene_migrations, pset_hooks. All the others stay open.
- AGENTS.md lists the same 31 names and says "(the last thirteen are read at each use and stay open)". **Code wins**: 22 stay open (`closed` only holds `INIT_READ`), not only the last thirteen. The thirteen are read at each use; others such as `grain_restart` and `invariants` are open too but are read at fixed times.
- **Adding a registry** takes all of these:
  - a key in `M.registry` (`lib/state.lua:27-62`);
  - an `S.register_<name>` function that checks its fields (`require_named`, `require_known_fields`, refusing a duplicate);
  - adding it to `INIT_READ` if it is read once at init;
  - naming it in backticks in the `S.registry` bullet under Owns in `docs/notes/lua/state-and-voices.md`, which `test/unit/docs_test.lua:1405-1420` checks;
  - its place in AGENTS.md's registries list (words), which no test checks (**not found**: a test comparing AGENTS.md's list with `S.registry`);
  - tests in `test/unit/registries_test.lua`.

---

## Notes and code that disagree (code wins)

1. **The scan unit.**
   - ROADMAP.md:109 and docs/status.md:16 say `bufScan` "moves in lengths of the valid region per second" / "valid-region lengths per second".
   - The code and notes say loop fractions: `lib/playheads.lua:36` "loop fractions a second"; docs/notes/engine/positions.md:14 "fractions of the voice's loop per second"; docs/user/params.md:147 "loop lengths a second".
   - The two agree only while the loop is the whole slot.
2. **The registries.** AGENTS.md says "the last thirteen are read at each use and stay open"; `lib/state.lua:72-73` closes only 9, so 22 stay open.
3. **Where the locals probe is.** docs/status.md:24 says "the locals probe in `test/run.lua`"; it is in `test/unit/structure_test.lua:517-606`.
4. **When step overrides end.**
   - AGENTS.md: "they end at the voice's next step without them".
   - The code ends them only at the voice's next **played** step (`apply_step`, `lib/sequencer.lua:580-582`). A step at level 0 or a probability miss leaves them, as do the other endings (stop, replace, shorter length, wrap with no set step).
   - docs/notes/lua/sequencer.md:10 says "the voice's previous played step" correctly.

## Not found

- A per-voice pass counter, or any record of a conditioned step's outcome (section 2).
- A scene field or PSET side file holding `S.patterns` or `S.pattern_steps` (section 1).
- Any display of the pattern chain's current or next scene (section 4).
- A test comparing AGENTS.md's registries list with `S.registry` (section 9).
- A Lua path that gives a note an absolute buffer position (section 5).
- A hook that hears plain (noteless) step hits other than `S.register_step_output` (section 6).
