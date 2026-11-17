# Plan facts: 3a (the stepper, #738 #754 #740 #743 #744), 3c's #739, 4a (scenes with the PSET, the one rule)

Read from `main` (the same code as the design worktree). Line numbers are today's. 1a renames `.extras` to `.values` and 0a renames `frozen`; the plan should rebase every line below on them.

## Package 3a

### 1. Files

- `lib/scenes.lua`: the sequencer's draw, 830-891 (`first_scene_from` 833-839, `SEQUENCER_DRAW` 843, `slot_plays` 847-849, `draw_next_scene` 857-873, `kept_next_scene` 880-887, `forget_next_scene` 889-891), the pass 909-918 and 958-967, `sequencer_next_slot` 1453-1464, `capture_scene` 385-387, `read_scenes_file` 1134-1151 (the validity cache is set there).
- `lib/sequencer.lua`: the chain 1111-1162 (`chain_slots`, `populated`, `linkable_from`, `next_chain_scene`); `chain_link` 1181-1184 and `load_chain_scene` 1166-1178 stay. #740 at 142-143, 344-363, 677, 686-687. #743 at 1204-1213 and 1252-1254. #744 at 761-775.
- `lib/io/actions.lua`: `saved` 30-32, `next_scene` 55-62.
- `lib/chance.lua`: header comment 2-5 only. `pick` is unchanged.
- `lib/pages/scenes.lua:85` (`rand` becomes `random`). The design's table leaves this file out. No wave-3 package owns it.
- Tests: `test/unit/scenes_test.lua`, `test/unit/sequencer_test.lua`, `test/unit/io_actions_test.lua:49-56` (passes unchanged), `test/unit/pages_scenes_test.lua:147,149`. `test/unit/chance_test.lua` needs no change.
- Notes: `docs/notes/lua/chance.md:3,6`; `docs/notes/lua/scenes.md:22` (the drawn-once rule), the #513 Must-not-break line ("skips an empty slot"), the sequencer section 217-275 (the code sketch at 227-236 names `first_scene_from`, `draw_next_scene` and `kept_next_scene`), and `:24` of `docs/notes/lua/pages/scenes.md` (`rand 0%`); `docs/notes/lua/sequencer.md:34`, 74 (ping-pong), 92-95 (the chain: "only the picked slot is validated ... `linkable_from`").
- User pages: `docs/user/sequencer.md:17` ("ping-pong takes a new length at once"), `docs/user/pages/seq.md:16` ("while ping-pong turns at the new length at once"), `docs/user/scenes.md:45` and `docs/user/pages/scenes.md:5` (`rand`), `docs/user/sequencer.md:61` (the chain).
- AGENTS.md: no line becomes false. Line 266 ("a one-voice step sets the own region through `S.lib.notes.set_own_region`") holds after #744.

### 2. Names

**Added to `S.lib.scenes`:**

- `M.playable(slot)`: true when `slot` is whole in 1..`NUM_SCENES`, `S.scenes[slot].populated == true`, and the slot's data is valid by the cache.
- `M.playable_slots(first, count)`: the playable slots of `first, first+1, ...`, `min(count, NUM_SCENES)` of them, wrapping past 16 (`(first - 1 + offset) % NUM_SCENES + 1`), in that order. It returns `{}` when `first` is not whole in 1..16 or `count` is not a whole number of at least 1. The sequencer calls `playable_slots(1, length)`. The chain calls `playable_slots(params:get("seq_chain_from"), params:get("seq_chain_scenes"))`, which is `chain_slots`' range today (sequencer.lua:1114-1120).
- `M.next_slot(position, slots, chances, random)`: returns `slot, move`.
  - `#slots == 0`: `nil, nil`.
  - `position` in `slots`: `S.lib.chance.pick(position, slots, chances, random)`. It must be looked up at call time: sequencer_test.lua:3553 replaces `chance.pick`.
  - `position` nil or not in `slots` (empty, invalid, or outside the range): no draw. The first slot of `slots` after `position` in cyclic 1..16 order (smallest `(s - position - 1) % NUM_SCENES`), `"next"`. A nil position gives `slots[1]`.

  Cyclic order over 16 matches both front ends, because each range is an arc of the 16. For 1..length it is the sequencer's rule today: "past the length, from 1" (scenes.lua:859-864). For a chain range from 13 it gives 13 first. "No other playable slot" means `slots = {position}`. `pick` then returns that slot: `"next"` at 100, 0, 0 (so it is applied again, by ruling 36), `"repeat"` with random or all zero. So the playing scene is kept without a special case.
- A local `following(position, slots)` (the cyclic first, with `position` itself last). `next_slot` uses it, and so do the pass's skip-at-once (917-918) and `sequencer_next_slot` (1460-1463).

**What happens to each duplicated function:**

| Function | Callers | Fate |
|---|---|---|
| `chain_slots` (seq:1114) | `next_chain_scene` | goes, replaced by `playable_slots` |
| `populated` (seq:1122) | 1131, 1150, 1154 | goes |
| `linkable_from` (seq:1128) | 1148, 1161 | goes (#738's walk) |
| `next_chain_scene` (seq:1146) | `chain_link` 1182 | becomes one line, `S.lib.scenes.next_slot(current, S.lib.scenes.playable_slots(from, n), {next, previous, random})`; inline it into `chain_link` or keep the name |
| `first_scene_from` (sc:833) | 862, 917, 1463 | goes, replaced by `following` over `playable_slots(1, length)` |
| `slot_plays` (sc:847) | 859, 868, 883 | stays, as `plays(slot, length)` = in 1..length and `M.playable(slot)` (#754) |
| `draw_next_scene` (sc:857) | 885, 944, 961 | stays as the sequencer's front end: `S.scene_sequencer_next, SEQUENCER_DRAW.move = M.next_slot(S.scene_sequencer_position, M.playable_slots(1, length), chances)`. Its own position-cannot-play branch moves into `next_slot` |
| `kept_next_scene` (sc:880) | 959, 1457 | stays (draw-ahead is the sequencer's) |
| `forget_next_scene` (sc:889) | 901, 991, 1003 | stays |
| `io_actions.next_scene` (act:55) | crow, OSC, Teletype | `local slot = S.lib.scenes.next_slot(S.current_scene, S.lib.scenes.playable_slots(1, NUM_SCENES), {100, 0, 0})`; recall it, or `ignored("next_scene", "no scene is saved")` for nil. At 100, 0, 0 there is no draw, and the result equals today's walk except that it skips invalid scenes |

No test reaches any of these names (grep of test/ for each). `validate_scene` stays global. The sequencer stops calling it.

**Validity cache.** A local in lib/scenes.lua, `local checked = {}`, keyed by slot: `checked[slot] = {data = <the data table checked>, valid = <bool>}`. Nothing is written to the file: `save_scenes_to_disk` writes `S.scenes` itself (scenes.lua:1048), so a field on a scene would be saved.

- Set at `capture_scene` (after 385-386): `validate_scene(S.scenes[n])` once.
- Set at `read_scenes_file` (after 1150): `true` for every populated slot, since `validate_scene_data` passed (1129).
- Set at 4a's PSET load the same way.
- A rename (`set_name`, 1415) needs nothing, since the cache is keyed by data and the name is sanitized.
- There is no scene clear anywhere in lib/ (grep `populated = false`: only `empty_scene`).
- `M.playable` reads `checked[slot]`. When its `data` is not the slot's current `data` table, it validates once and stores the result. That lazy branch runs only for a data table written outside lib/scenes.lua, which only tests do: no lib code writes `S.scenes` but lib/scenes.lua.

**Cost.** In memory an invalid scene can exist only through tests: a disk load sets aside the whole file when one scene is invalid (`validate_scene_data`, 1294-1304). `validate_scene` (1201-1290) costs, for each populated scene, a check and a `params:lookup_param` on each of the 154 `SCENE_GLOBAL_PARAMS`, every block's validate (steps 7×16, macros, matrix, sequences), then 7 voices × (synth 3-7, grain 9, crossmod 3 slots, extras 53, pattern 16). That is roughly 1,000 checks a scene and 16,000 a link over a full range: the reason for 3.7's "validate only the pick". `recall_scene` (697) and morph (`morph.lua:105`) keep their own calls. Morph is outside 3a.

**Labels.** SEQ: `random` (`lib/pages/seq.lua:109`, row label, 30 px). SCENES: `rand` (`lib/pages/scenes.lua:85`, drawn as `"rand 5%"`). Stub widths (`test/norns_stubs.lua` `text_width`): `random 100%` is 53 px and `rand 100%` 42 px. SCENES' fields are two columns at x 0 and 64 (`SCENES_PAGE.column_x`), and `scene_chance_random` is field 7, column 1. 53 px fits before x 64, so **`random`** fits both pages: SCENES changes and SEQ keeps its label.

**#740.** `M.playing_region` (seq:355-363) returns nil once `util.time() >= step_region_ends[voice]`. That time is set once at the step (687: `util.time() + pass_seconds`). The fix:
- Rename `step_region_ends` to `step_region_to_end` (143, 346, 677, 687), a boolean `S.lib.notes.pass_seconds(voice, region[2]) ~= nil`.
- In `playing_region`: `if step_region_to_end[voice_idx] and S.lib.playheads.finished(voice_idx) then return nil end`.

`S.lib.playheads.finished` (playheads.lua:159) is the one-shot end over the span, which is the own region. It restarts wherever the engine's scan does: a grain restart, a one-shot hit, a jump, `restart_scan`. Line 677's `rings` then reads the same end. The issue's examples are wrong: a K3 stop clears the own region (notes.lua:975), and so does a running source switch (1016). The restarts that keep the region are a ratchet's later hit, `S.lib.positions.restart_scan`, a jump and a scan mode change.

**#743.** `ping_pong_step` (seq:1208-1213) clamps to the live `length`. Proposed:
```lua
local function ping_pong_step(state, last, length)
  if length <= 1 then return 1, true end
  -- a longer length, or one the leg can still turn at, applies at once; else the leg ends at its own top
  if length > state.pass_length or (state.heading > 0 and last < length) then state.pass_length = length end
  local turned = (state.heading > 0 and last >= state.pass_length) or (state.heading < 0 and last <= 1)
  if turned then state.heading, state.pass_length = -state.heading, length end
  return util.clamp(last + state.heading, 1, state.pass_length), turned
end
```
Line 1254 already resets `pass_length` at a turn. This mirrors reverse's rule ("applies at once while fewer steps than it have been taken", 1240). A shorter length applies at once while the leg can still turn at it, and otherwise at the leg's turn.

**#744.** In `voices_play` (770-774), `elseif on_slice then S.lib.engine_sync.retrigger(...)` restarts the earlier slice: `step_regions` and the own region are still its. Replace it with a call to a new local `take_own_slice(voice_idx, slice.slice)`, then the retrigger. `take_own_slice`:
- sets `step_slices[voice_idx] = nil`, so the ratchet's later hits go through line 758, as on a voice set to one;
- takes `region = S.lib.slices.voice_region(voice_idx, n)`, returning when there is none;
- calls `S.lib.notes.set_own_region(voice_idx, region, true)`;
- sets `step_regions[voice_idx] = region`;
- sets `step_region_to_end[voice_idx] = S.lib.notes.pass_seconds(voice_idx, region[2]) ~= nil`.

It covers pool 0, a full pool (`steals` takes only step slices, so another owner's extra note refuses it) and a ratchet whose slice note was stolen.

### 3. Order and seams

- 3a needs 1a (`.values` in `load_chain_scene` 1173, and in the scene shape `validate_scene` checks) and 2b (the `matrix` block's 22 slots inside `validate_scene`).
- It gives 4a `checked` and `M.playable`.
- 3c (`lib/scan.lua`, `lib/delay_sync.lua`) and 3b (`lib/midi_in.lua`, `lib/params_setup.lua`) share no file with 3a. `lib/pages/scenes.lua` is unowned in wave 3.
- Must-not-break items reworded, none broken:
  - scenes.md "skips an empty slot" becomes "an empty or invalid slot".
  - scenes.md "the next scene is drawn once" now names `S.lib.scenes.next_slot`.
  - chance.md:6 "the caller hands it only the slots that can play" is now `next_slot`'s job.
  - sequencer.md:34 (ruling 36) holds.
- lib/sequencer.lua has 111 `local` lines in its constructor. 3a removes four locals and adds one, so the 200-local limit is not at risk.

### 4. Tests

**Re-base:**
- sequencer_test.lua:3628 "the chain goes on from a cleared scene's place": a cleared current is no longer kept in the list.
  - Previous at 100 becomes `"3 4 2 1 4"`: on to 4 with no draw, then backward.
  - Random at 100 becomes `"3 4"` with no draw.
  - The defaults case `"3 4 1"` stands.

  Rename it "a cleared playing scene goes on to the next saved one with no draw". This changes chain behavior, a point for the plan (section 5).
- sequencer_test.lua:3699 "a link validates only the scene it links": a draw now validates nothing.
  - Assert 0 validations at the start and at a link.
  - Make scene 2 invalid on a fresh table (`S.scenes[2] = deep_copy(S.scenes[2]); S.scenes[2].data.steps[1][1] = {cond = "9:9"}`). An in-place edit of a captured scene keeps the cached `true`.
  - The link lands on 3 (mark 4) with exactly 1 validation, the lazy one for the fresh table.
- sequencer_test.lua:3730 "previous past an invalid scene ...": the same fresh-table edit. Expect `"3 1"` with 1 validation.
- sequencer_test.lua:3821: `"1 2 3 2 1 2 1 2"` becomes `"1 2 3 4 2 1 2 1"` (4 to 2 after three steps up: 3 ≥ 2, so the leg ends at 4). 3822 stands.
- sequencer_test.lua:4097 "playing names a one-voice step's slice while it sounds": replace the `scan.pass_seconds` double (4109) with `params:set("v1_scan_mode", 3); params:set("v1_buf_scan", 1)`. The slot is 2 s (`sliced_setup`, 3859) and the slice 0.25, so the pass is 0.5 s.
- sequencer_test.lua:3923 (double at 3926): the step-5 "played out" check needs one shot and `v1_buf_scan` 1.25 (0.4 s). The ratchet and pool sub-cases (3956, 3974) ring by the doubles and need one shot with `v1_buf_scan` 0.25 (2 s) instead.
- sequencer_test.lua:4017: its ends are the notes module's (`ends_at`), so it is likely unaffected. Run it.
- The `pass_seconds` doubles in midi_in_test.lua (1691-1797) and slices_test.lua:56 feed the notes module, not `playing_region`. They are likely unaffected (unsure; run them).
- pages_scenes_test.lua:147,149: `rand 5%` becomes `random 5%`.

**New, in scenes_test.lua:**
- "playable_slots lists a range's populated valid slots, wrapping past 16": capture 1, 2, 15, 16; make 2 invalid on a fresh table. `playable_slots(15, 4)` = `{15, 16, 1}`, `playable_slots(1, 16)` = `{1, 15, 16}`, `playable_slots(0, 4)` = `{}`, and a count of 20 counts 16.
- "next_slot: no playable slot is nil; a lone slot keeps the playing scene; a position not in the list goes on with no draw": `next_slot(1, {}, ...)` = nil. `next_slot(3, {3}, {100,0,0})` = 3, "next". `next_slot(3, {3}, {0,0,100})` = 3, "repeat". `next_slot(2, {1, 4}, {0,100,0}, raising_random)` = 4, "next". `next_slot(nil, {13,14,1})` = 13.
- "#754: the scene sequencer never draws or recalls an invalid scene": scenes 1-4 with 3 invalid on a fresh table, chances 0, 0, 100, `math.randomseed(1)`, 40 passes. `sequencer_next_slot()` is never 3, no recall names 3, and no "has invalid data" line is printed.
- "a sequence whose one playable slot is the playing scene keeps it": scenes 1 and 2 with 2 invalid, length 2, 100/0/0. It recalls `"1 1 1"` (ruling 36's `next` to itself).

**New, in sequencer_test.lua:**
- "#738: a chain move never lands on an invalid scene and never walks on from one": scenes 1-4, 3 invalid (fresh table), random 100, playing 2. With `math.random` at 0.5 (the middle of {1, 4}) it links 4. With 0.0 it links 1. Over 50 seeded links 3 never appears, and the share of 4 is not about twice that of 1 (measure the counts at the seed used).
- "a ping-pong pass finishes its leg before a shorter length (#743): 8 to 4 after three steps in each direction", with `run` as at 3804:
  - `run("ping-pong", 8, 3, 4, 6)` = `"1 2 3 4 3 2 1 2 3"` (fits: turns at 4, same as today).
  - `run("ping-pong", 8, 11, 4, 6)` = `"1 2 3 4 5 6 7 8 7 6 5 4 3 2 1 2 3"` (fits, same as today).
  - The two that fail today: `run("ping-pong", 8, 5, 4, 6)` = `"1 2 3 4 5 6 7 8 4 3 2"` (today `"... 5 4 3 2 1 2 3"`), and `run("ping-pong", 8, 9, 4, 6)` = `"... 8 7 6 5 4 3 2 1"` (today `"... 8 7 4 3 2 1 2 3"`).
- "#740: a one-shot step slice is named again after its scan restarts": `sliced_setup(2)`, scan mode 3, `v1_buf_scan` 1, `seq_length` 16, step 1's slice 3.
  - Playing is `"3"`. After `run_for(0.5 + 2/48)` it is `""`.
  - `S.lib.positions.restart_scan(1)` makes it `"3"` again (`""` today). After 0.5 s more it is `""`.
- "#744: an overlap step slice refused a slot takes the own note with its own slice, at pool 0 and at a full pool": `sliced_setup(3)`, one shot, `v1_buf_scan` 0.25 (each slice 2 s), steps 1 (slice 1) and 3 (slice 2).
  - Pool 0: `notes.set_pool(0)`. At step 3 `region_texts(context, 0)` = `"setGrainParam(0, regionStart, 0.25) setGrainParam(0, regionLength, 0.25)"` before one `retrigger(0, ...)`, `notes.own_region(1)[1]` = 0.25, and `S.lib.slices.playing(1)` = `{2}`. Today: no region, own region 0, slice 1 restarted.
  - Full pool: `set_pool(1)` with voice 2 running and holding two MIDI notes (`midi_note(S, 2, 60); midi_note(S, 2, 64)`, `pool_used() == 1`). Same assertions.
  - A ratchet 2 on step 3 at pool 0: the second hit retriggers the own note with slice 2's region and sends no region again.

### 5. Risks and open points

- **#743's reading:** the issue's own test ("three steps in each direction") gives today's output under my fits rule. Only "past the new end" positions differ. Under the stricter reading (a leg always finishes at its old top), `run("ping-pong", 8, 3, 4, 6)` would be `"1 2 3 4 5 6 7 8 4"`. The plan must choose one. I recommend the fits rule: no jump, and it is reverse's rule.
- **A cleared playing scene on the chain:** today it is kept in the list, and the chances apply from its place (3.6's behavior, pinned by 3628). Under one `next_slot` it goes on with no draw, as the sequencer has done since 1f's review. It can arise only from a load (SETUP's `load scenes`, or a 4a PSET load), since no scene clear exists. This needs a ruling.
- **Tests that make a scene invalid by editing it in place** (sequencer_test 3720, 3736) must use a fresh table. Other in-place edits (scenes_test 2485, 3126; morph_test 897; matrix_test 539, 609; scatter_test 164) go through `recall_scene` or morph, which keep calling `validate_scene`. They are unaffected (unsure for matrix_test 539/609: they recall, by reading, not draw).
- **The design's "keeps the playing scene":** read with ruling 36, it is a re-application at 100, 0, 0, not a hold. Say so in the plan.
- `S.lib.slices.playing` runs per grid cell (slices.lua:442 comment). `playheads.finished` adds an advance per call (a few param reads). I did not measure it at 256 cells (unsure).

## Package 3c's #739

### 1. Files
`lib/scan.lua` (around 72-77, the hooks), `test/unit/scan_test.lua`, `docs/notes/lua/scan.md:7`.

### 2. Names
The hook exists as `S.register_scene_applied({name, fn = fn()})` (state.lua:643). `apply_entries` runs it once, after clearing `S.scene_recall_in_progress` (scenes.lua:588-592), for every voice, stopped ones included. That covers an instant recall, a fade's landing and morph's discrete entries. Its `fn` takes no arguments. `S.register_scene_recalled` (state.lua:574) is the other hook; it fires per recall with `scene_num` and not for morph. The source-change hook skips recalls (state.lua:268-269).

The fix, in lib/scan.lua alone:
```lua
-- #739: a recall's source switch runs no source-change hook; a voice it leaves stopped settles at once
S.register_scene_applied({name = "scan", fn = function()
  for voice_idx = 1, NUM_VOICES do
    if not S.voices[voice_idx].active then settle(voice_idx, true) end
  end
end})
```
It covers stopped voices only. A running voice whose source changed settles through its sync's grain restart (scenes.lua:598-600, scan.lua:77), and one the recall starts settles through its voiceOn. Settling running voices too would move a tempo recall's rate send out of the round robin. A stopped voice's `settle` sends nothing: the senders are gated on running, and `set_engine_factor` only stores, then sends through the gated sender. It fixes the factor a later start sends.

### 4. Tests
New in scan_test.lua: "a recall that takes a stopped voice off its buffer settles its follow at once (#739)".
- Setup: `loaded()`, `tempos[1] = 120`, `clock_tempo` 90, repitch, `lfo_step`, factor 0.75.
- Capture the scene: `toggle_voice(1)` (stopped), `params:set("v1_source", SOURCE_SYNTH)`, `capture_scene(1)`.
- Back on the buffer: `params:set("v1_source", SOURCE_SYNTH + 1)`; the factor is 0.75 (the source hook).
- `recall_scene(1, 0)`. With no `lfo_step`, `engine_factor("v1_buf_scan")` is 1 and the voice is still stopped.

### 5. Risks
None found. The hook is named `scene_applied`, as the design says.

## Package 4a

### 1. Files

- `lib/scenes.lua`:
  - `S.scene_file` 1030 gains `pset`.
  - `save_scenes_to_disk` 1048 writes `pset`.
  - `read_scenes_file` 1095-1159: split it, and take `pset`.
  - `capture_scene` 385 and `set_name` 1415 clear `pset`.
  - New: the side-file spec and PSET hook (after 1304), `take_scenes`, `back_up_live`.
- `lib/side_files.lua`: `pset_hook` 140-151 gains `after_write` and `after_delete` (header 17). 2b adds `floor` to `files.read` (75).
- `lib/grid/core.lua`: `GRID_ROTATION` 585, `read_rotations` 601-614.
- `lib/notes.lua`: `NOTES` 32 (`backup_suffix`), the `notes_load` start step 946-954.
- `lib/pages/setup.lua`: no edit needed. Its status rows read `S.scene_file.problem/backup` (154-164), which keep their meaning.
- Tests: `scenes_test.lua`, `side_files_test.lua:227`, `grid_core_test.lua:1443`, `notes_test.lua:85`.
- Notes:
  - `docs/notes/lua/data-files.md:9, 14` (side files' users: "the macros, the gestures, the matrix", becoming five, with scenes' live file its own), `:35` (grids "replaced at the next change, with no backup"; notes the same), `:49, :57`;
  - `docs/notes/lua/scenes.md`: the Must-not-break lines "scenes.data is written only by `save_scenes_to_disk`", the `load_scenes_from_disk` line, and the Owns header (scenes.lua:7-11);
  - `docs/notes/lua/grid-core.md:61`;
  - `docs/notes/lua/notes.md:11, 77`.
- User pages: `docs/user/scenes.md:18-21` (a PSET bullet), `docs/user/params.md` (the PSET list), `docs/user/pages/setup.md:23` (unchanged).
- AGENTS.md:240 (the data-files rule) stays true. Nothing becomes false. The design's "4a rewrites the data files rule" is optional.

### 2. Names

**The live scenes file** keeps its writer, status rows, load prompt and blocks. Only the PSET's file goes through the helper (the design's "Left to the builder"). Today's disk code:
- `save_scenes_to_disk` (1042) writes at once and sets `S.scene_file`.
- `move_aside_unloadable_file` (1073) is also buffers' (buffers.lua:976).
- `read_scenes_file` (1095) handles version, fill, validate, and replacement with the #518 current-scene rule.
- `load_scenes_from_disk` (1164), `M.autosave` (1174, respecting `S.scenes_loaded` and `S.scene_autosave_blocked`), `M.request_load` (1190, the confirm).
- The start step (1308) and the cleanup step `scenes_save` (1322).

Scenes are written at each `M.save` (1377), each `set_name` (1417), SETUP's `save scenes`, and cleanup. `side_files`' live functions (`load_live`, `save_live` with a delay, `save_now`) do not fit: there are immediate writes and SETUP's state. So scenes never call them, though the spec must still name `live_file` (REQUIRED, side_files.lua:28).

**What moves:**
- `read_scenes_file` 1134-1158 becomes `local function take_scenes(scene_table, from)`. It fills gaps with `empty_scene()` and runs `cancel_scene_transition()`. It keeps the #518 current-scene rule (1145-1149), sets `S.scenes`, raises every revision, sets `checked` for the populated slots, prints `"scenes loaded from " .. from` and calls `grid_redraw()`. `read_scenes_file` and the PSET load both call it.
- 1124-1132 becomes `local function scenes_problem(scene_table)`: fill each slot, then `validate_scene_data`. It returns nil or `"corrupted or incompatible"`. The spec's `validate` is this function.

**The spec**, made at include time (side_files is included at 54, scenes at 59):
```lua
{name = "scenes", contents = "scenes", version = SCENE_DATA_VERSION, floor = SCENE_FORMAT_FLOOR,
 key = "scenes", live_file = "scenes.data", side_suffix = ".scenes.data", backup_suffix = ".bak",
 capture = function() return S.scenes end, validate = scenes_problem, load = load_pset_scenes}
```
With version 9 and floor 9, the side file accepts exactly 9. That fits 2b's optional `floor` (side_files.lua:75 becomes `is_integer_between(loaded.version, spec.floor or spec.version, spec.version)`). `side_files.read` checks the version before `validate` and calls `load(nil)` for a missing or unusable file. So a PSET with no scenes file, and an unusable one (set aside with the helper's line `error loading scenes file <path>: <why>; kept as <backup>`), leave the live scenes alone.

**`pset_hook(before_read, after_read, after_write, after_delete)`**: `write` becomes `local written = files.write(...); if after_write then after_write(written, path_base) end`, and `delete` calls `after_delete(path_base)` after the remove. Scenes registers `S.register_pset_hook(files.pset_hook(nil, nil, pset_saved, pset_deleted))` at include. The hooks run in registration order (params_setup.lua:251-260), so scenes' hook comes first, before morph's (morph.lua:741, include 82), which forgets its plan after the slots change. No scene block's `validate` reads live macro, matrix or sequence state (macros.lua:727, matrix.lua:699, random_sequences.lua:269: shape only), and a PSET load applies no block. So nothing requires scenes after macros, matrix or sequences.

**The live file's field `pset`**: the PSET path without `.pset` (`path_base`) that holds exactly the live scenes, absent otherwise. The file becomes `{version = 9, scenes = S.scenes, pset = S.scene_file.pset}`. `validate_scene_data` reads only `.scenes`, so the field is no scene and breaks nothing. A non-string reads as nil. A string records more than a boolean: deleting that PSET clears it. Sites:
- **Cleared** (nil, before the write): `capture_scene` (385) and `set_name` (1415).
- **From the file:** `read_scenes_file` (SETUP's load and the start).
- **Set to `path_base`:** `pset_saved(written, base)` when `written`, then `M.autosave()`, which rewrites the live file at every PSET save. The PSET load also sets it.
- **Cleared on delete:** `pset_deleted(base)`, when `S.scene_file.pset == base`, then `M.autosave()`.

**`load_pset_scenes(scene_table, path, silent)`**:
1. nil: return (live scenes stay).
2. `back_up_live()`. It applies when `S.scene_file.pset == nil` and some slot is populated or named; otherwise there is nothing to back up.
   - `M.autosave()` first, so the live file holds memory (it makes the file if missing). A falsy result refuses.
   - Then `S.lib.data_files.set_aside(scene_data_file, ".bak")` (data_files.lua:373). With all nine names taken (`DATA_FILES.backups` 9, :40) it returns nil, "every backup name is taken"; a rename failure returns its why.
   - On success: `print("scenes in no PSET kept as " .. backup)`.
   - On refusal: `print("scenes from " .. path .. " not loaded: the scenes in no PSET could not be kept (" .. why .. "); the live scenes stay")` and return.
3. `take_scenes(scene_table, path)`.
4. `S.scene_file.pset = path_base` (the path less `.scenes.data`), `SCENE_LOAD.armed_until = 0`, `M.autosave()`, `request_redraw()`.

**Scene state at a PSET load:**

| State | What happens |
|---|---|
| `S.scenes` | replaced |
| `checked` | set |
| revisions | raised (morph rebuilds) |
| `S.current_scene` | kept only if its slot encodes the same, else 0 (#518, as a disk load); the header follows |
| transition | `cancel_scene_transition()` (previous scene back; no landing applies) |
| scene sequencer | position and `S.scene_sequencer_next` untouched; a kept slot that can no longer play is redrawn by `kept_next_scene` |
| chain | `chain.current` untouched |
| morph A-D | slot numbers are params, unchanged; morph's own hook stops its clock |
| undo | not cleared (a disk load does not clear it either) |
| `S.scene_file.problem/backup/unsaved` | `M.autosave`'s outcome |

**grids.data and notes.data.** Today an unusable file reads as 0 or the default and is overwritten at the next `set_rotation` or `set_pool`, with no backup. Add `backup_suffix = ".bak"` to `GRID_ROTATION` and `NOTES`, and follow `lib/io/rig.lua:173-180`:
- **grids** (`read_rotations`, the `elseif` at 609): `local backup, failure = S.lib.data_files.set_aside(rotation_path(), GRID_ROTATION.backup_suffix)`. The line becomes `"strata: grids.data not used (<why>): every grid rotation is 0; " .. (backup and ("kept as " .. backup:match("[^/]*$")) or ("not moved: " .. tostring(failure)))`.
- **notes** (948-953): the same, with `"...: the pool is the tier's default, <n>; kept as notes.data.bak"`.

"Unusable" stays what the code already treats as the whole file failing: unreadable, not a table, the wrong version, or (grids) `rotation` not a table / (notes) the pool bad. A version 1 grids file with bad entries keeps its good ones and is not set aside (grid_core_test 1463-1466).

### 3. Order and seams

- 4a needs 3a (`checked`, `take_scenes` sets it), 2b (`floor` in side_files), 1a (format 9).
- 4a is wave 4 alone, so no conflict. It edits `lib/side_files.lua` after 2b.
- Rules to reword:
  - data-files.md:14 ("never read, set aside or write them themselves"): scenes' live file stays its own.
  - scenes.md "scenes.data is written only by `save_scenes_to_disk`": the live file; its PSET file goes through the helper.
  - The `pset` field is new in format 9, so 1a's format 9 fixture should carry it or the plan should say it is optional.

### 4. Tests

**Re-base:**
- side_files_test.lua:227: add `after_write(written, base)` and `after_delete(base)` to the order list.
- grid_core_test.lua:1443: cases 1, 2, 3 and 5 also assert `strata/grids.data.bak` holds the case's bytes and one line ends `kept as grids.data.bak`; case 4 is not set aside.
- notes_test.lua:85: each case's line ends `kept as notes.data.bak`, and the `.bak` holds the bytes.
- Run every test file that calls `params:write`/`params:read` (20 files, among them scenes_test, morph_test, matrix_test, macros_test, io_*): a read now replaces the live scenes with the PSET's. A test that captures between a write and a read loses the capture (scenes_test 1029 captures before its write and is safe). I did not check each one (unsure).

**New, in scenes_test.lua** (a PSET through `params:write(context.data_dir .. "strata-0N.pset")`):
- "a PSET save writes its sixteen scenes beside it, an empty set too": `strata-01.scenes.data` exists, version 9, 16 slots. With nothing saved, every slot is unpopulated. The live file's `pset` names `strata-01`.
- "a PSET load replaces the live scenes, rewrites the live file and recalls nothing": live from P1; save P2 after another capture; read P1. No recall: `takeovers()` is unchanged and no scene-recalled hook runs. The slots are P1's, `S.current_scene` is 0 unless the slot is unchanged, and the live file holds P1's scenes with `pset` = P1's base.
- "a PSET load ends a running transition": a 4 s fade, then read; `S.scene_transition_active` is false.
- "a PSET delete removes its scenes file and the live file's mark": `params:delete`, or the hook's `delete`.
- "a PSET with no scenes file leaves the live scenes": remove the side file and read. The scenes are unchanged, no `.bak`, no line.
- "an unusable scenes file beside a PSET is set aside with one line and the live scenes stay": `"return {"` and a version 8 file. The side `.bak` holds the bytes and the live scenes are unchanged.
- "a load over unsaved scenes makes one backup first; over none, none": capture after a PSET save, then read. `scenes.data.bak` holds the earlier live bytes and one line names it. A second read with no edit makes no `.bak.2`.
- "with no backup name free the live scenes stay": make `scenes.data.bak` and `.bak.2-.9` directories (as pages_setup_test 593-594 does). The scenes are unchanged, one line, and the live file is unchanged.
- "an edit from an earlier session still counts": capture, new `load_strata` on the same `data_subdir`, read, one backup. Conversely, a PSET save then a new session: no backup.
- "the live file's pset field is no scene": a file with `pset = "x"` and one with `pset = 5` both load all 16.
- "the scenes' PSET hook runs before morph's" (registry order).

**New, elsewhere:**
- grid_core_test "an unusable grids.data is set aside before a rotation writes a new one": `set_rotation(1, 1)`, then the new file reads 1 and the `.bak` holds the old bytes. With nine backup names taken, the line says `not moved`.
- notes_test: the same with `set_pool(3)`.

### 5. Risks and open points

- If the live write fails during the backup (card full), the load refuses and the live scenes stay. That falls under the design's "the card refuses".
- **The scene sequencer and "recalls nothing":** a PSET that turns `scene_sequencer_enabled` on still recalls position 1 on the next tick (scenes_test 1029, scenes.lua:976-979). It does so over the new scenes, since the hook runs synchronously inside `params:read` (norns paramset.lua:572). The design's "nothing is recalled" holds for the load itself.
- The `.bak` suffix is shared by the backups of unusable files and of PSET loads (nine in all). Another suffix (`.unsaved.bak`) would give each its own nine. The design says "the nine backup names", so I kept `.bak`.
- **What to do when grids/notes cannot set a file aside** (unsure which the maintainer wants): rig (io.data) writes over the file afterward. samples (`store.blocked`) and side files never do. I followed rig, since `set_rotation`/`set_pool` must still work. The alternative is a blocked flag that makes them return false.
- The design's 4a file table lists `lib/pages/setup.lua`. I found nothing there that must change.
