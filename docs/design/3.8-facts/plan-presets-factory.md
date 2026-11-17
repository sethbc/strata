# Plan facts: 3b voice presets and copy, 4d the factory sets' code

Read-only survey of `main` at 2edbfa96 against `docs/design/3.8-design.md` (§8, §9, §11, §12's VOICE and SETUP lines, §14) and `docs/design/3.8-facts/lua-presets.md` (written at 59a0a0c1, before the groundwork; its line numbers are stale and are given again here). One scratch probe (`scratchpad/plan-presets/probe_keys.lua`: the harness's `load_strata()` + `finish_startup`, Lua 5.3, nothing tracked changed) listed every voice's scene keys by record, every param by menu group, `START_ORDER` and `CLEANUP_ORDER`. `lua test/run.lua side_files` (13 tests) and `mutation` (31 tests) pass on `main`. Everything that 0d, 1a, 1c, 1d, 1e and 2b add is named from the design, since none of it is on `main`; such names are marked **(from 0d)** etc. and the building package must check them against what those packages landed.

---

## Package 3b: voice presets and copy (design §8)

### 1. Files

Create:
- `lib/voice_presets.lua` (`S.lib.voice_presets`): the library, `VOICE_PRESETS`, `capture`, `load`, `copy`, `save`, `clear`, `loaded_name`, the start step. No cleanup step is needed: the file is written at each save (§8.2), never at exit.
- `lib/ui/voice_picker.lua` (`S.lib.ui_voice_picker`): the modal owner (`open(voice_idx)`, `close()`, `is_open()`), its rows, keys, hints and name entry.
- `test/unit/voice_presets_test.lua`, `test/unit/ui_voice_picker_test.lua` (AGENTS.md: one unit file per module).
- `docs/notes/lua/voice-presets.md` (opens with `## Must not break`; can cover both modules, as `docs/notes/lua/ui-core.md` covers the zones editor) or a second file `docs/notes/lua/ui/voice-picker.md`. The docs test `every docs/notes/lua and test-harness file opens with a Must not break section` (`test/unit/docs_test.lua:918`) holds either.
- A changelog fragment `changes/<branch>.md` (`### Added`).

Edit (main sites on `main`):
- `strata.lua`: two include lines. `S.lib.voice_presets` after `lib/slices` (`strata.lua:91`) or after `lib/delay_sync` (`:108`): it needs only `S.lib.scenes` (:59), `S.lib.mutation` (:58) and `S.lib.data_files` (:52) at call time. `S.lib.ui_voice_picker` after `lib/ui/slice_editor` (`:122`), since an owner that aliases `S.lib.ui_field_list` (`:116`) or `S.lib.ui_text` (`:115`) at construction must come after them.
- `lib/scenes.lua`: `release_voice` and the fade's changes (below): `scene_transition_targets` (`:570-597`), `recall_scene` (`:645-730`, the fade clock `:687-724`), `recall_scene_instant` (`:745-768`), `apply_entries` (`:511-562`), `end_scene_transition` (`:373-393`), the `scene transition` invariant (`:1501-1520`).
- `lib/mutation.lua`: `hold_voice`, `undo_voice`, the undo record, `undo_for` (`:164-168`), `undo` (`:176-187`), `hold_undo` (`:107-115`).
- `lib/ui/voice_rows.lua`: the `preset` row (`voice_page_rows`, `:107-124`), `voice_page_group` (`:144-158`) so the arc's group skips it, `param_kind` (`:92-98`) never called for it.
- `lib/pages/voice.lua`: `value_text` (`:97-106`), `voice_key` (`:266-278`, K3 on the row opens the picker), `voice_hints` (`:238-245`), `voice_enc` (`:247-261`, E3 does nothing on it), `voice_reset_row` (`:299-307`, does nothing on it), `row_draw` (`:197-206`, no draw), `layout_states` (`:327-395`: the row and the picker).
- `lib/ui/cursors.lua:30`: the VOICE anchor's `key` function (see Risks 1): one line.
- `lib/constants.lua`: `START_ORDER.voice_presets_load` (`:191-230` today; a free number between `sequences_load` 111 and `startup_clock` 120, e.g. 113).
- Name entry (Risks 5): either `lib/pages/scenes.lua` (`:283-339`, `NAME_ENTRY`, `open_name_entry`, `reconcile_name_entry`) moved into a shared helper, or a copy in the picker.
- `AGENTS.md`: the data files rule (line 240, 37 words; adding `` `voices.data` `` is +1 word, `factory.data` +1 more by 4d); two module rows (9 words each as `wc -w` counts them, after the `lib/slices.lua` row, line 106, and after the `lib/ui/slice_editor.lua` row, line 116); optionally the Randomize undo line (line 246, 40 words) gains "a preset load holds one too (`hold_voice`)" (+7). §14 names the data files rule as 3b's and 4d's.
- `docs/notes/lua/state-and-voices.md`: a row in the start table (docs test `the notes' start and cleanup tables list every step of START_ORDER and CLEANUP_ORDER`, `docs_test.lua:1369`), and a row in its invariants table for any `S.register_invariant` 3b adds (`docs_test.lua:1424`, `| \`<name>\` |`).
- `docs/notes/lua/scenes.md` (`release_voice`, the fade's released voices), `docs/notes/lua/mutation.md` (the hold, its Must not break bullets on the one undo and `undo_for`), `docs/notes/lua/pages/voice.md` (the row, K3), `docs/notes/lua/ui/field-list-and-cursors.md` (the anchor key), `docs/notes/lua/data-files.md` (the "two rules above cover every data file" bullet lists the files: add `voices.data`).
- User docs: `docs/user/pages/voice.md` (the `preset` row, the picker's keys) and a "Voice presets" section in `docs/user/voices-and-grains.md` (linked from README's index already). No new user page is needed; a new `docs/user/*.md` page would need a README index line (no test requires it).

Tests that change (measured):
- `test/unit/structure_test.lua:995-1058` `start_steps()`: one row for the new step, e.g. `{ "voice presets load", { "file read voices.data" } }` after `sequences load` (the test wraps `S.lib.data_files.read` and logs `file read <name>`, `:1124`).
- `test/unit/pages_voice_test.lua` and `test/unit/ui_cursors_test.lua` (`:144`, `:162`, `:287`, `:383` pin `S.cursors.voice == 2`; `pages_voice_test.lua:565` sets 2, `:614` pins `"K2:prev K3:next"`): 0d moves these first with its `type` row; 3b re-bases them again for the `preset` row.
- `test/unit/mutation_test.lua`: the one-undo tests stand; add the hold's.
- `test/unit/scenes_test.lua`: the recall-against-3.3.2 comparisons must pass unchanged (the release path adds nothing when no voice is released).

### 2. Names

**`lib/voice_presets.lua`** (proposed; module-local, fields of `M` where other code reads them):
- `VOICE_PRESET_DATA_VERSION = 1`, `VOICE_PRESET_FORMAT_FLOOR = 1`: locals named so the structure test on version comparisons passes. The rule (`structure_test.lua:229-235`): a file's version may be compared only with a name ending `_FLOOR` or `_DATA_VERSION` or another version chain. `VOICE_PRESETS.floor` or `.data_floor` would be caught; `VOICE_PRESETS.version` passes (a version chain) but a floor must end `_FLOOR`.
- `M.VOICE_PRESETS = {file = "voices.data", slots = 64, name_max = 12, backup_suffix = ".bak", keys = {...}}` (§1's `VOICE_PRESETS`). `name_max` equals `S.constants.SCENE_NAME_MAX` (12); alias it rather than repeat 12.
- `VOICE_PRESETS.keys`: `{[key] = true | false}` over every voice scene key that is no synth key (below). Every type's synth keys are in by rule, not listed.
- The file: `{version = 1, presets = {[slot] = {name, type, values}}}`, sparse by slot (`S.lib.data_files.encode` writes number keys past the array part, `lib/data_files.lua:85-102`). 64 presets of about 55 keys are about 120 KB and 129 tables (est. from the facts file's 1.9-2.5 KB a voice), far under `max_bytes` 4 MB and `max_tables` 32768.
- `M.capture(voice_idx) -> {type, values}`: `S.lib.scenes.capture_voice(voice_idx)` filtered: `type` its `type` field **(from 0d)**, `values` the keys with `keys[key] == true` and the current type's synth keys.
- `M.load(voice_idx, slot) -> boolean`, `M.copy(from_voice, to_voice) -> boolean` (a load of `M.capture(from_voice)`), `M.save(voice_idx, slot, name) -> boolean, why`, `M.clear(slot) -> boolean`, `M.preset(slot) -> {name, type} | nil` (the picker's row), `M.loaded_name(voice_idx) -> string | nil` (the `preset` row; not stored, §8.4).
- Start step `START_ORDER.voice_presets_load` (proposed 113): read `voices.data` through `S.lib.data_files.read`; missing: an empty library; unusable (unreadable, a version outside floor..version, a shape the check refuses): `S.lib.data_files.set_aside(path, ".bak")` with one console line, as `lib/samples.lua` and `lib/io/rig.lua` do; one that can be neither used nor set aside blocks every write this session (the #590 rule `lib/side_files.lua:111-121` states), and a save then refuses with a flash.
- The data `load` hands `apply_voice` (exact, against 0d's `valid_voice_data` with a `type` field and `voice_scene_keys(voice_idx, type_key)`):

```
current = S.lib.scenes.capture_voice(v)             -- {active, source, type, values}
record  = S.lib.types.record(preset.type)           -- nil: refuse (one line, a flash), nothing applied
list    = S.lib.params_setup.voice_scene_keys(v, preset.type)   -- the shared keys + that type's synth keys
for each entry of list (key = entry.key):
  a synth key of record (record.param_order):  preset.values[key] if present, else S.voices[v].values[key]
  VOICE_PRESETS.keys[key] == true:             preset.values[key] if present, else current.values[key]
  otherwise (an out key):                      current.values[key]
data = {active = current.active, source = current.source, type = preset.type, values = <the above>}
S.lib.scenes.release_voice(v); ok = S.lib.scenes.apply_voice(v, data)
if ok then S.lib.mutation.hold_voice(v, current); loaded[v] = preset.name end
```

  A preset key this build lacks is dropped (it is in no `list`), so `apply_voice` never sees it. `S.voices[v].values[key]` holds every type's keys only after 0d (§2.2: "every voice has every synth key"). A value out of a key's `range` or `limits` makes `apply_voice` refuse the whole call with one line (`lib/scenes.lua:1251-1256`), so a damaged preset loads nothing.
- `M.save` sanitizes the name as `set_name` does (`lib/scenes.lua:1568`: `text:gsub("[^\32-\126]", ""):sub(1, SCENE_NAME_MAX)`).

**`VOICE_PRESETS.keys`, every voice scene key on `main`** (probe; registration order of the records `synth, grain, crossmod, history, freeze, loops, variation, voice_mix, bookmarks, scan, envelopes, notes, expression, slices, seq`; a voice has 73 (Sub) to 77 (Resonator) keys):

| Record | Keys | In or out (§8.1 rule) |
|---|---|---|
| synth (synth keys) | Resonator `amp freq mod1 mod2 noise pan rq`; FM `amp freq index modFreq pan ratio`; Folder `amp fold freq mod pan`; Sub `amp drift freq`; Pulse `amp cutoff freq pan res width`; Karplus `amp damping decay excite freq pan`; Ring `amp brightness freq mod pan ratio` | in, by rule (not listed) |
| grain (built-in) | `buf_pos buf_rate buf_scan` | out (a place in audio, the rate, the scan) |
| grain (built-in) | `grain_density grain_mode grain_pitch grain_size grain_spread` | in |
| grain (built-in) | `grain_env` | gone in 1c (§4.1); not in the table at 3b |
| crossmod (built-in) | `mod_source_1..3 mod_amp_amt_1..3 mod_freq_amt_1..3` | out ("the three crossmod slots") |
| crossmod (built-in) | `mod_speed` | **unsure**: not a slot, but acts only through them; propose out (Risks 3) |
| history | `history` | out |
| freeze | `freeze freeze_mode` | out |
| loops | `loop_length loop_start` | out |
| variation | `custom_interval_1..5 intervals interval_prob pitch_jitter pan_jitter size_jitter reverse quantize` | in (`reverse` is a per-grain draw: in by the rule) |
| voice_mix | `filter_type filter_freq filter_res filter_mix delay_send reverb_send` | in |
| voice_mix | `mute` | out |
| bookmarks | `bookmark_1..4` | out |
| scan | `scan_mode follow` | out |
| envelopes | `env_attack env_decay env_sustain env_release env_curve env_loop` | **unsure**: §8.1's "the envelope's shape" most likely means these (the grain window is listed separately); but the envelope acts only through routings, which are out. Propose in (Risks 3) |
| notes | `attack release` | in |
| expression | `press_target press_depth slide_target slide_depth` | out |
| slices | `slices` | out |
| seq | `seq_length seq_division seq_direction seq_gate seq_gate_length seq_gate_release seq_swing seq_misstep` | out |
| (fields, not values) | `active`, `source`, `type` | `type` in (the preset's `type`); `active` and `source` out (the voice's own) |

`note_cap` and `solo` are no scene keys (`lib/params_setup.lua:1079-1080`), so no capture holds them.

**Keys later 3.8 packages add** (all land before 3b, which is wave 3): 1a `dry` (voice mix record, in); 1c `grain_shape`, `grain_skew`, `grain_prob`, `grain_cloud`, `grain_overlap`, `pan_wander` (lib/grain.lua's record, all in; `grain_env` removed); 1d `input_channel` (out); 2b `arp` (in); the five types' synth keys, in by rule: `wave` `morph morphRate morphDepth detune`, `additive` `tilt stretch oddEven wander`, `noise` `color grit dust q bank`, `saw` `width detune cutoff res`, `formant` `formant bw vowel` (§3, proposed; 1f-1j fix them). 1e adds no voice key (`scale_mask` is a global). 3a, 4a-4d add none. **How the test stays green**: 3b's table is written against `main` as wave 2 leaves it, so every key exists; the test (below) iterates `voice_scene_keys(v, t)` for every voice and every type, so any later key fails it until named.

**`lib/scenes.lua`** (new and changed):
- `M.release_voice(voice_idx) -> boolean`: while a fade runs, marks the voice released (true); otherwise nothing (false). A number that is no voice: false.
- `scene_transition_targets` (`:570-597`): each target gains `voice = entry.voice` (`add_target(entry.id, value, entry.voice)`); `scene_entries`' per-voice entries already carry `voice` (`:407-418`).
- The fade (`:668-724`): a local `released = {}` made at the fade's start and kept in `S.SCENE_TRANSITION.released` (so `release_voice` can reach it); each step skips a target whose `voice` is released (`:696-698`); the landing passes `released` to `recall_scene_instant`. Note `end_scene_transition("landing")` is evaluated as an argument before `recall_scene_instant` runs (`:723`) and clears the `SCENE_TRANSITION` fields (`:382-385`), so the landing must take the closure's `released`, never `S.SCENE_TRANSITION.released`.
- `recall_scene_instant(scene_num, scene_data, current_if_failed, landing, released)` (5th argument new) passes `{skip_voices = released}` to `apply_entries`.
- `apply_entries(entries, opts)`: `opts.skip_voices` (a set by voice) drops every entry whose `entry_voice(entry)` is in it, before `last_entry` is computed (`:516-524`). The scenes notes' Must not break says a change to what a recall sets goes in `scene_entries` or `apply_entries`, never beside them (`docs/notes/lua/scenes.md`, "A recall is one list").
- `end_scene_transition` clears `SCENE_TRANSITION.released` with the other fields; the `scene transition` invariant (`:1501`) gains "released is a table exactly while a fade runs".

**`lib/mutation.lua`** (new and changed):
- `M.hold_voice(voice_idx, capture)`: clears any undo, then `S.undo = {page = UI_PAGES.index.VOICE, section = nil, voice = voice_idx, capture = capture, values = {["v<i>_<key>"] = value, ...}, ids = {}, until_time = util.time() + UNDO_SECONDS}` and the expiry clock (`hold_undo`'s, `:107-115`). `values` names every param id of the capture so `note_param_edit` (`:235-238`) ends the undo on any later edit of the voice's values. It must be called after the apply (the apply's own param actions call `note_param_edit`).
- `M.undo()` (`:176-187`): with `undo.capture`, inside `write_as_undo`, `S.lib.scenes.apply_voice(undo.voice, {active = <now>, source = <now>, type = undo.capture.type, values = undo.capture.values})` (Risks 4: the voice's present `active` and `source`, not the capture's).
- `M.undo_for(page, section, voice)` (`:164-168`): also true when `undo.capture` and `page == undo.page and voice == undo.voice` within the window, whatever the section, so ALT+K2 on VOICE (`lib/ui/alt.lua:74-80`, which asks `undo_for(spec.page, spec.section, spec.voice)` with the cursor's section) undoes a load from any row.
- `M.undo_voice(voice_idx) -> boolean` (proposed, for 4c's grid page): undoes when the held undo is a hold of that voice.

**`lib/ui/voice_picker.lua`** (proposed):
- `M.open(voice_idx)`, `M.close()`, `M.is_open()`, `M.VOICE_PICKER = {visible, first_y, spacing, value_right, ...}` (the zones editor's 6 rows from y 18, 7 px apart, `lib/ui/zones.lua:29-33`).
- Rows: the six other voices `{voice = n}` drawn `from voice <n>  <list_name>` (0d: `S.lib.types.of(n).list_name`), then 64 slots `{slot = n}` drawn `<nn> <name>  <type list_name>` or `<nn> --`.
- Keys (the owner's `key(n, z)` gets presses and releases; ALT is `S.alt_held`): E2 moves (`S.lib.ui_field_list.move`); K3 press on a voice row copies, on a filled slot loads, on an empty slot nothing; ALT+K3 on a slot opens the name entry on K3's release, then saves; ALT+K2 held `ALT_HOLD_SECONDS` (0.5) then released clears the slot (`animates` while held, so the hint turns at the hold time, as `S.lib.ui_alt` does); K2 (no ALT) closes. Hints: `K2:back K3:load` (slot), `K2:back K3:copy` (voice row), with ALT `K2:clear K3:save` (slot).
- `S.lib.ui_modal.push(owner)` and `pop(owner)` (`lib/ui/modal.lua:39-63`); the owner takes the body, the hints, E2, E3, K2, K3 and the arc; `redraw()` draws the header and then the owner (`strata.lua:300-336`), so no `redraw()` edit.

**`lib/ui/voice_rows.lua`**: the row `{label = "preset", kind = "preset", key = "preset", section = <0d's section of the type row>, selectable = true}` right after 0d's `type` row; no `param_id`.

### 3. Order and seams

- Needs **0d**: `capture_voice` returning `type`, `apply_voice` taking it and setting it before the key check (§2.4), `valid_voice_data` with `type` in `VOICE_FIELDS` (`lib/scenes.lua:1240` today holds `{active, source, values}`), `S.lib.params_setup.voice_scene_keys(voice_idx, type_key)` (today one argument, `lib/params_setup.lua:1083`), `S.lib.types.record(key)`, `S.lib.types.of(v)` with `list_name` and `param_order`, every type's keys in `S.voices[v].values`, and the VOICE `type` row with its section name. The plan must name 0d's section for the `type` row, since `preset` joins it (Risks 2).
- Needs **1a** (`dry`), **1c** (the grain record's six keys, `grain_env` gone), **1d** (`input_channel`, sources to 17), **2b** (`arp`): only by name, for the table.
- Gives **4c** (grid voices page, wave 4): `S.lib.voice_presets.copy(from, to)`, `S.lib.mutation.undo_voice(v)`.
- Gives **4d** nothing, but both edit `lib/scenes.lua` (3b in wave 3, 4d in wave 4: no same-wave conflict) and both add to the AGENTS.md data files line.
- Same wave (wave 3: 3a, 3b): 3a owns the FDN and `lib/fx_hold.lua`; no shared file. 0d also edits `lib/scenes.lua`, `lib/ui/voice_rows.lua` and `lib/pages/voice.lua`, but in wave 0.
- `lib/ui/cursors.lua` and the name-entry helper are files §14 gives no package: add them to 3b's list.
- Rules touched: AGENTS.md "Randomize undo" (line 246: still true; "undone only where it was made" holds with a whole-voice clause for VOICE); "Cursors other modules move go through their owner" (the anchor key change is in the owner); `docs/notes/lua/mutation.md` Must not break "A quick ALT+K2 undoes only where the undo was made" (rewrite: a held voice undo counts on any VOICE section of that voice); `docs/notes/lua/scenes.md` Must not break (a released voice is the one exception to "the landing applies the whole scene").

### 4. Tests (proposed, all new unless noted)

`test/unit/voice_presets_test.lua`:
- `every voice scene key is in or out of VOICE_PRESETS.keys`: for each voice 1..7 and each type of `S.lib.types.list()`, each key of `voice_scene_keys(v, t.key)` is a synth key of `t` or a key of `VOICE_PRESETS.keys`; and every key the table names is some voice's scene key (no stale names).
- `a save writes voices.data and a start reads it back`: save voice 2 to slot 5 as "glass pad", `load_strata({data_subdir = same})`, `preset(5).name == "glass pad"`, `.type == "fm"`.
- `a name keeps printable ASCII, cut to twelve`: `"a\tbcdefghijklmnop"` saves as `"abcdefghijklm"`... (12 characters).
- `a load takes the sound and keeps the place`: voice 1 buffer-sourced, running, `buf_pos` 0.3, `seq_length` 5, `mute` 1, a preset of voice 2 (`fm`, `grain_size` 0.2, `delay_send` 0.4): after the load voice 1 is `fm`, `grain_size` 0.2, `delay_send` 0.4, and `source`, `active`, `buf_pos` 0.3, `seq_length` 5, `mute` 1 are kept.
- `a synth key the preset lacks keeps the voice's remembered value`: edit voice 1's `v1_ratio` while on `fm`, switch it to `resonator`, load an `fm` preset whose values lack `ratio`: `v1_ratio` is the edited value.
- `a key this build lacks is dropped`: a preset with `values.future_key = 1` loads, with no console error.
- `a preset of a type this build lacks loads nothing`: `type = "nope"`: false, one line, values unchanged.
- `copy is a load of the other voice's filtered capture`: copy 3 into 6: 6's type and in keys equal 3's; 6's out keys unchanged.
- `a locked voice can be loaded into` (`S.locked[v] = true`).
- `an unusable voices.data is set aside, never written over`: a file of `"garbage"`: the start sets it aside as `voices.data.bak`, the library is empty, a save writes a fresh file; a file that cannot be set aside (all nine backup names taken) blocks the save (false, why).
- `a load during a fade lets go of the voice`: recall scene 1, then a fade to scene 2 over 2 s; at step 5 load slot 1 into voice 3; run the fade to its end: voice 3 holds the preset's values, the other voices scene 2's, `S.current_scene == 2`.
- `a fade with no voice released sends what it sent`: the scenes_test comparisons pass unchanged (existing tests).

`test/unit/mutation_test.lua` (added):
- `a held voice undo puts the voice back through apply_voice`: load a preset into voice 4, ALT+K2 quick on VOICE with the cursor in any section: values are the pre-load ones; `S.undo == nil`.
- `an edit after a load ends its undo` (`note_param_edit` on `v4_grain_size`).
- `the undo restores the voice's present active and source` (voice started after the load stays running).
- `a held voice undo lapses after UNDO_SECONDS`; `undo_for` false on another voice and another page.

`test/unit/ui_voice_picker_test.lua`:
- `K3 on the preset row opens the picker; K2 closes it` (`S.lib.ui_modal.top()`), the hints for each row kind with and without ALT.
- `the list is the six other voices then 64 slots`; `E2 walks it and scrolls` (field_list).
- `ALT+K3 on a slot opens the name entry on release and saves the name` (`context.textentry` stub's `finish(text)`, `test/stub_textentry.lua`); `a canceled entry saves nothing`; `ALT stays not held after the entry` (`forget_held_keys`).
- `ALT+K2 held 0.5 s clears a slot; a quick one does nothing`.
- `the preset row shows the name last loaded, else --`.
- Layout states in VOICE's record (`lib/pages/voice.lua:327-395`; the layout tests walk every page's states): the row with a twelve-character name; the picker on the first voice row, on slot 1 with a twelve-character name and the widest type `list_name`, on slot 64 empty, with ALT held, with ALT+K2 held past the hold time.

`test/unit/structure_test.lua`: the start step row (above).

### 5. Risks and open points

1. **The VOICE cursor's anchor would land on a label row.** `lib/ui/cursors.lua:30` keys a row by `row.param_id:match(...)`; a row with no `param_id` keys as nil, and `sync` (`:62-78`) takes the first row whose key equals the anchor's, which is row 1, a section label (`selectable = false`). The `preset` row needs `key = "preset"` and the key function `row.key or (row.param_id and row.param_id:match("^v%d+_(.+)$"))`. `lib/ui/cursors.lua` must join 3b's files.
2. **The arc and VOICE's handlers assume a param.** `lib/arc/voice.lua:41-68` calls `arc_sweep_param(row.param_id)`, `arc_ring_fill_param`; `value_text` (`lib/pages/voice.lua:98-105`) calls `key:match` on `param_key(row)`; `voice_reset_row` (`:301-306`) calls `param_default(param_id)`. Make `voice_page_group` (`lib/ui/voice_rows.lua:144-158`) count only rows with a `param_id`, so neither the rings nor the ring marks see the row, and guard the three page handlers by `row.kind == "preset"`. Which section holds `type` and `preset` (a section label row of its own, or none) is 0d's; the design's sketch (§12) shows no label above them.
3. **Three keys the design leaves unclassified**: `mod_speed` (proposed out with the crossmod slots), the six `env_*` keys (proposed in as "the envelope's shape"), `reverse` (proposed in). The test forces a choice; the plan should state it.
4. **The undo's `active` and `source`.** `apply_voice` stops, starts and re-sources by its data (`lib/scenes.lua:467-476`, `:485-488`). An undo applied from the pre-load capture would stop a voice the player started after the load. Proposed: the undo applies the capture's `type` and `values` with the voice's present `active` and `source`.
5. **The name entry.** SCENES opens norns' `textentry` on ALT+K2's release with no modal owner (`lib/pages/scenes.lua:283-309`), after `forget_held_keys()`; `textentry.enter` swaps the globals `key`, `enc` and `redraw` itself (`~/src/norns/lua/lib/textentry.lua:41-68`), so `redraw()` needs no change, and the menu-close hook `reconcile_name_entry` (`:328-339`) repairs a menu that took it over. From the picker it works the same if opened on K3's release (the owner gets `key(3, 0)` because it saw the press, `lib/ui/modal.lua:72-84`; textentry cancels on a K2 release and ignores a K3 release with nothing pending). A shared helper (`lib/ui/name_entry.lua`, `S.lib.ui_name_entry.open(heading, default, callback)`, owning `NAME_ENTRY` and the menu-close hook) is possible but moves SCENES' state and its `scenes prompt` invariant (`:64-74`, which ties `S.scenes_page.naming` to `NAME_ENTRY.callback`); a copy in the picker is about 40 lines with a second `S.register_menu_close` hook. The design leaves it to the builder; norns has one textentry, so a helper is the safer of the two.
6. **What `copy` shows on the `preset` row** (`loaded_name`) is unspecified: proposed `v<n>` (MAIN's voice-source style). Whether a recall clears it: unspecified; proposed no (it is not stored).
7. **A load during a fade, the pattern and the lock.** "Out of its landing" (§8.3) is read here as every entry of the voice (active, source, values, lock, pattern). The preset holds neither the pattern nor the lock, so whether the landing should still set them is the plan's call; the proposal drops all of them.
8. **`release_voice` covers the fade only.** A morph move (`lib/morph.lua`) and the scene sequencer's next pass still write the voice; §8.3 asks only for the fade.
9. Engine load: one voice's apply is about 75 counted sends (facts file §2), inside one budget window (150 / 0.1 s).

---

## Package 4d: the factory sets' code (design §9)

### 1. Files

Create:
- `lib/factory.lua` (`S.lib.factory`): the index, the marker, the load clock, the parser, `FACTORY.rig`, the first-run start step, a cleanup step for the clock, and the SETUP list (a modal owner; the design names no UI file, so it lives here unless the plan splits it out).
- `test/unit/factory_test.lua`.
- `test/fixtures/factory/` (proposed layout, all text): `index.data`; `dusk/set.params`; `dusk/set.samples.data`; `dusk/set.scenes.data`, `dusk/set.macros.data`, `dusk/set.matrix.data`, `dusk/set.gestures.data`, `dusk/set.sequences.data` (one of them deliberately unusable for the skip test, or written so by the test); `dusk/audio/` (a WAV of a few frames, or written by the test with a 44-byte header: the stub's `audio.file_info` reads a real header, `test/norns_stubs.lua:3196-3232`). Tests copy the fixture into their own temporary script folder first, so a failing read can never rename a tracked file.
- `docs/notes/lua/factory.md` (`## Must not break` first).
- `changes/<branch>.md`: `### Added` "Factory sets: SETUP's `factory sets` row lists and loads the sets the script ships; 3.8 ships none. A set sets sound only and leaves the MIDI, MPE, zones, outputs, IO and tape settings alone; its audio installs under `audio/strata/factory/`." No norns restart note (no engine file changes).

Edit:
- `strata.lua`: one include, after `lib/scenes`, `lib/samples` and `lib/side_files` (e.g. after `lib/voice_presets`).
- `lib/side_files.lua`: the read-only load (below), `files.read` (`:83-109`).
- `lib/scenes.lua` (**not in §14's list for 4d**): export `back_up_live` (`:1394-1408`, local today) as `M.back_up_live()`; a factory branch in `load_pset_scenes` (`:1418-1439`); record the start's outcome in the `scenes_load` step (`:1462-1471`).
- `lib/pages/setup.lua`: one `SETUP_FIELDS` entry (`:60-80`), its layout states (`:398-475`).
- `lib/constants.lua`: `START_ORDER.factory_first_run` (a free number between 111 and 120, e.g. 117) and `CLEANUP_ORDER.factory` (a free number, e.g. 115 or 116, between `macros` 114 and `zones_learn` 117).
- `test/norns_stubs.lua:3303`: `norns.state.path`; `test/helpers.lua:126-146`: a `load_strata` option for it.
- `lib/samples.lua` (**not in §14's list**, Risks 6): `store_file` (`:336-349`) stores a record without checking it.
- `lib/params_setup.lua` (**not in §14's list**, or 1e exports): the param list and the load default (Risks 4).
- `AGENTS.md`: `factory.data` in the data files rule (line 240); one module row after the `lib/voice_presets.lua` row; optionally an invariant line "Factory sets never move the rig ... `docs/notes/lua/factory.md`" (about 25 words).
- `docs/notes/lua/state-and-voices.md` (start and cleanup rows: `docs_test.lua:1369`; an invariant row per `S.register_invariant`: `:1424`), `docs/notes/lua/data-files.md` (side files' read-only load; the data files bullet), `docs/notes/lua/scenes.md` (the factory branch, the start outcome), `docs/notes/lua/pages/setup.md`, `docs/notes/test-harness/stubs.md` (`norns.state.path`), `docs/user/pages/setup.md` (the row and its list).
- `.gitignore`: no change needed. `git check-ignore` over `factory/index.data`, `factory/dusk/set.params`, `factory/dusk/set.scenes.data`, `factory/dusk/audio/pad.wav` and the fixture paths ignores none; only a subfolder named `data/` would be (`.gitignore:4`), so a set never holds one.

Tests that change (measured):
- `test/unit/structure_test.lua:995-1058` `start_steps()`: a row for the first-run step; its effects depend on the order of its checks (Risks 2). With the scenes outcome tested first, the test's start (it has a saved scene) reads nothing: `{ "factory first run", {} }` or, if the marker is read first, `{ "factory first run", { "file read factory.data" } }`.
- `test/unit/structure_test.lua:819` `CLEANUP_STEPS` and its `clocks` list (`:895-913`): the cleanup test requires one observed effect per step (`:960-977`), so the test must start a load clock before cleanup (e.g. `S.factory_clock = clock.run(function() clock.sleep(100) end)`) and map it to a name.
- `test/unit/pages_setup_test.lua`: `:41` pins the cursor on `load scenes` at 11; `:150`, `:155`, `:202`, `:222` pin `performance` at 17. A row placed after `load scenes` moves only the four `17`s (to 18, or 19 after 1e's row). `lib/pages/setup.lua:417`'s layout state `enc(2, 10)` ("load prompt") moves if a row goes above `load scenes`. The `enc(2, 20)` states (`:400`, `:402`, ...) reach the end only while there are at most 21 fields: 12 today + 1e's + 4d's + 4 rotation + 2 performance = 20.
- `test/unit/system_37_test.lua` and `engine_sync_test.lua:1663` (the default start against 3.6.0's and 3.7.0's engine calls): unchanged, since the stub's script folder is empty and no first run happens.

### 2. Names

**`lib/factory.lua`** (proposed):
- Constants (locals named for the version test, `structure_test.lua:229-235`): `FACTORY_DATA_VERSION = 1`, `FACTORY_FORMAT_FLOOR = 1` (the marker), `FACTORY_INDEX_DATA_VERSION = 1` (index.data), `FACTORY_SET_DATA_VERSION = 1` (set.samples.data). A set's own `version` (a field of its index entry) may be compared with the marker's recorded version: both are version chains, which the test allows.
- `M.FACTORY = {folder = "factory/", index = "index.data", marker = "factory.data", params_file = "set.params", samples_file = "set.samples.data", side_base = "set", audio_folder = "audio/", install_folder = "strata/factory/", key_pattern = "^[%w_%-]+$", copy_chunk_bytes = 1048576, confirm_seconds = <S.lib.scenes.SCENE_LOAD.confirm_seconds>, pset_hooks = {"scenes", "macros", "morph", "gestures", "sequences", "matrix"}, rig = {groups = {...}, patterns = {...}}}`.
- `index.data`: `{version = 1, sets = {{key = "dusk", name = "dusk", version = 1}, ...}, first_run = "dusk"}`, read with `S.lib.data_files.read(norns.state.path .. "factory/index.data")`.
- `factory.data` (the marker, in `_path.data .. "strata/"`): `{version = 1, loaded = {[key] = <set version>}}`. Proposed: an unusable marker counts as found (no first run), is set aside (`.bak`) and written afresh, so a damaged marker never loads a set over a player.
- `set.samples.data`: `{version = 1, files = {["pad.wav"] = <a samples record: tempo, key, normalize, mode, count, sensitivity, edited, markers, frames, rate>}}`. Proposed as the list of the set's audio files too (one entry per file, defaults included), so the copy needs no folder listing (`util.scandir` is forbidden in `lib/`; `lib/files.lua`'s lister is local until 1e exports it).
- `set.params`: a PSET's line form, `"<id>": <value>` (norns' `ParamSet:write`, `~/src/norns/lua/core/paramset.lua:498-522`), `--` lines ignored; a slot line `"buf<n>_file": <name>` names a file of the set's `audio/` (a bare name: no `/`, no `..`), resolved to `_path.audio .. "strata/factory/<key>-<version>/<name>"`.
- Parser `M.parse_params(text) -> {[id] = raw string}` mirroring norns' read (`paramset.lua:527-578`): `string.match(line, "(\".-\")%s*:%s*(.*)")`, unquoted with `gsub('^"', ''):gsub('"$', ''):gsub('\\"', '"')` (Strata's `pset.named_ids` does the same, `lib/params_setup.lua:177-186`), first line for an id wins.
- Applying (`M.apply_params(lines, set)`), in the params' menu order (`params.params`), so `scale`, `root`, a voice's `quantize` (`add_first`, #125) and 1e's tuning come before every `freq` whatever the file's order: for each Strata record param (Risks 4) that is not rig, is saved (`param.save ~= false`) and is no trigger, separator or group: the line through the param's own `set` (`params:lookup_param(id):set(value)`, as norns' read does): a text param takes the string; a file param (`buf<n>_file`) the resolved path (its `File:set` runs `load_buffer(slot, path)` only when the path changes, `~/src/norns/lua/core/params/file.lua:29-41`, `lib/params_setup.lua:666`); a binary that is a trigger is skipped; a number param takes `util.round(tonumber(value))`; control, option, taper and binary take `tonumber(value)` (`-inf`/`inf` as norns reads them). With no line: the param's load default (control, number, option, taper, a non-trigger binary: `pset.default`, `lib/params_setup.lua:194-204`; a text param: 1e's extension; a file param: none, the slot keeps its audio). A line naming a rig param, a param norns owns (not in Strata's records: `clock_tempo`, `output_level`, `reverb`, ...) or no param: refused with one console line naming it.
- `M.load(key) -> boolean, why`: refuses when a load runs (one clock, `S.factory_clock`), when the key is not in the index, or when the key fails `key_pattern`. In `S.factory_clock = clock.run(...)`:
  1. `util.make_dir(<install folder>)` (`mkdir -p`; the stub refuses characters outside `[%w%._/%-+,:@=]`, `test/norns_stubs.lua:803-809`, so the key pattern matters); per file of `set.samples.data`: skipped if `util.file_exists(dest)`; else read the source (`io.open(src, "rb")`) in `copy_chunk_bytes` chunks, each written to `dest .. ".part"` with `clock.sleep(0)` between chunks, then flush, close and `os.rename` each checked; a failure removes the `.part`, prints one line and marks the file missing;
  2. `S.lib.samples.store_file(installed_path, record)` per installed file;
  3. `S.lib.scenes.back_up_live()`: false and why stops the load with one line and a flash;
  4. `M.apply_params` (a slot line whose file is missing is skipped with one line, Risks 7);
  5. inside `S.lib.side_files.read_only(fn)`: each `S.registry.pset_hooks` record whose `name` is in `FACTORY.pset_hooks`, in registry order, `record.read(path_base, nil, path_base .. ".params", false)` with `path_base = norns.state.path .. "factory/<key>/set"`, so the five side files are `set.scenes.data` ... `set.sequences.data` and each module's own before and after hooks run (gestures' `stop_all`, macros' `cancel_pending`, morph's `stop_clock`; `lib/gestures.lua:756`, `lib/macros.lua:746`, `lib/morph.lua:741`); the io hooks (`io_keyed`, `io_tape`, `io_midi_out`, `io_nb`) and scatter's (silent reads only) are not run;
  6. `header_flash(set.name)` (`lib/ui/flash.lua:99`), the marker's `loaded[key] = version` written, `request_redraw()`, `grid_redraw()`.
- `M.sets() -> list`, `M.open_list()`, `M.close_list()`, `M.loading() -> boolean`.
- Start step `START_ORDER.factory_first_run`: when `S.scene_file.start_outcome == "missing"` (below), no marker found, and the index names a `first_run` set: `M.load(first_run)` (not awaited: the script starts at its defaults and the set takes over when its clock ends). The marker is written "in every case" (§9; Risks 2).
- Cleanup step `CLEANUP_ORDER.factory`: cancels `S.factory_clock` and sets it nil.

**`FACTORY.rig`** (probe of `main`, by menu group; 185 params; `nosave` ones included since the walk covers every param of the groups):

| Group (id) | Count | Params |
|---|---|---|
| `strata_midi` (midi) | 6 | `midi_device`, `midi_channel_mode`, `midi_note_off`, `mpe_lower_members`, `mpe_upper_members`, `mpe_bend_range` |
| `strata_zones` (zones) | 21 | `v<i>_zone`, `v<i>_zone_low`, `v<i>_zone_high` |
| `strata_out_midi` (out midi) | 74 | `v<i>_out_port`, `_out_channel`, `_out_mode`, `_out_members` (28); `midi_out_bend_range`; `cc_out<n>_source` (nosave), `_source_key`, `_port`, `_channel`, `_number` for n 1..8 (40); `midi_pc_in`, `midi_pc_channel`, `midi_pc_out`, `midi_pc_out_port`, `midi_pc_out_channel` |
| `strata_crow` (crow) | 24 | `crow_in<n>_mode`, `_range`, `_action`, `_voice` (n 1..2); `crow_out<n>_source` (nosave), `_source_key`, `_range`, `_div` (n 1..4) |
| `strata_out_ii` (out ii) | 39 | `v<i>_out_jf`, `jf_level`, `v<i>_out_wsyn`, `wsyn_level`, `v<i>_out_er301`, `v<i>_out_txo`, `v<i>_out_txo_cv`, `txo_attack`, `txo_decay` |
| `strata_out_nb` (out nb) | 14 | `v<i>_out_nb` (nosave), `v<i>_out_nb_key` |
| `strata_tape` (tape) | 7 | `tapeloop`, `tapeloop_rec`, `tapeloop_length`, `tapeloop_rate`, `tapeloop_feedback`, `tapeloop_wear`, `tapeloop_level` |

Each voice's fourteen are `v<i>_out_port/channel/mode/members` (4), `v<i>_out_jf/wsyn/er301/txo/txo_cv` (5), `v<i>_out_nb`, `v<i>_out_nb_key` (2), `v<i>_zone`, `_zone_low`, `_zone_high` (3). Proposed patterns: `^midi_`, `^mpe_`, `^v%d+_out_`, `^v%d+_zone`, `^cc_out%d+_`, `^crow_`, `^jf_`, `^wsyn_`, `^txo_`, `^tapeloop`. The keyed params (`lib/io/keyed.lua`) are all here, so its PSET hook is rightly not run. norns' own groups (LEVELS, REVERB, COMPRESSOR, SOFTCUT, CLOCK, the clock separators: 50 params, `test/norns_stubs.lua:962-1000`) are outside Strata's records and refused by that rule, not by `FACTORY.rig`.

**The sound side the allow rule must cover** (Strata's other record params on `main`, saved ones): master (`master_density`, `tempo`), mutations (4), scenes (7 saved + `save_scenes`, `load_scenes` triggers), fx (16; 1a, 1b, 2a, 3a add theirs, the freezes nosave and `delay_clear` a trigger), the six LFO groups (72), macros (16), morph (6), scatter (8), matrix (32), input (`input_follow_gain`), gestures (4 saved quantize + 4 nosave play), rseq (12 + 4 triggers), seq (10 + `seq_fill` nosave), buffers (`record_duration`, `record_level`, `buf<n>_file` ×8, 24 triggers), record (6), positions (`scrub_friction`), scale (`scale`, `root`; 1e's `scale_mask`, `tuning_name`, `tuning_tones`), and each voice's params (74 to 78 a voice today, every type's after 0d). Unclassified by the design and worth a ruling (Risks 5): `tempo` (its action sets norns' `clock_tempo`, `lib/params_setup.lua:324-326`), `seq_follow_transport` (a SETUP setting), the record group (PSET-only settings: input source, threshold, sync), `input_follow_gain`, `scene_sequencer_enabled` and `mutation_enabled` (they start clocks), each voice's `v<i>_solo` (saved, not a scene key).

**`lib/side_files.lua`** (proposed): a module flag `reading_only`; `M.read_only(fn)` runs `fn` with the flag set (cleared on error, raised again), and `M.reading_only() -> boolean`. In `files.read` (`:83-109`), while the flag is set, an unusable file is never set aside: one line `error loading <name> file <path>: <why>; skipped (a factory file is never moved)`, `writable` stays true, and `spec.load(nil, path, silent)` runs as for a missing file (the macros' `load_block(nil)` clears every target, `lib/macros.lua:457-467`; the scenes' `load(nil)` leaves the live scenes). "Skipped" could also mean "the module keeps what it had" (no `load` call); the plan must pick (Risks 3).

**`lib/scenes.lua`** (4d's edits):
- `M.back_up_live = back_up_live` (`:1394`).
- `load_pset_scenes` (`:1418`): when `S.lib.side_files.reading_only()`: skip `back_up_live` (step 3 did it; calling it again would write and set aside the live file a second time, since the mark is then nil), `take_scenes(scene_table, path, silent)`, `S.scene_file.pset = nil` (the scenes are in no PSET: a mark naming `<script>/factory/<key>/set` would make `mark_holds_live` trust a file in the code folder), `M.autosave()`.
- The `scenes_load` start step (`:1467`) keeps its outcome: `S.scene_file.start_outcome = outcome` (`"loaded"`, `"missing"`, `"unreadable"`, `"older"`). This is how "no scenes file found at this start" is known at 4d's step: nothing records it today (`load_scenes_from_disk` returns it and the step drops it), and `util.file_exists` at 4d's step would read an unreadable file set aside at step 100 as missing.

**Stub** (`test/norns_stubs.lua:3303`): `norns.state.path = options.script_dir or (options.data_dir .. "script/")`, the default made empty (`util.make_dir`), with a trailing `/` as norns sets it (`~/src/norns/lua/core/script.lua:189`: `path .. '/'`); `test/helpers.lua` `load_strata(options)` passes `options.script_dir` to `stubs.install` (`:131-132`). `norns.state` today has only `data` and `shortname`.

**SETUP**: `{label = "factory sets", kind = "action", hint = "open", run = function() S.lib.factory.open_list() end}` (§12's `K3:open`; the existing action hint form is `"E2:field K3:" .. field.hint`, `lib/pages/setup.lua:276`). The list: rows `<name>  v<version>`, or one row `none`; E2 moves; K3 loads; while `S.scene_file.unsaved` the first K3 arms for `SCENE_LOAD.confirm_seconds` (2 s) and a second inside it loads, as `S.lib.scenes.request_load` does (`lib/scenes.lua:1225-1232`); K2 closes. Placement: §12's sketch shows `scale & tuning` (1e) and `factory sets` together; the plan must fix both positions (1e lands first).

### 3. Order and seams

- Needs every earlier package's params to exist (its allow side is "every Strata record param not rig"), 1e's text-param load default (Risks 4), 3b nothing.
- Files outside §14's list for 4d: `lib/scenes.lua` (3 sites), `lib/constants.lua` (2 lines), `test/helpers.lua`, possibly `lib/samples.lua` and `lib/params_setup.lua`. No other wave-4 package (4a `lib/pages/fx.lua`, `lib/arc/fx.lua`, `lib/ui/header.lua`; 4b, 4c grid pages) touches them; 3b (wave 3) edits `lib/scenes.lua` first.
- `lib/pages/setup.lua`: 1e (wave 1) adds `scale & tuning`; 4d's row lands later; no same-wave conflict.
- `AGENTS.md` line 240 is edited by both 3b and 4d (different waves).
- Rules: AGENTS.md data files (line 240) gains `voices.data` and `factory.data`; `docs/notes/lua/data-files.md`'s "side files' rules are written once" bullet gains the read-only load, and its "the two rules above cover every data file" bullet gains `factory.data` and `index.data`/`set.samples.data` (read only through `S.lib.data_files.read`); `docs/notes/lua/scenes.md` "Scenes travel with the PSET" gains the factory branch; nothing in AGENTS.md forbids calling the PSET hooks from another module, but `S.registry.pset_hooks`' comment (`lib/state.lua:47`, "run by the PSET actions") and `docs/notes/lua/params.md` should say so.

### 4. Tests (proposed, `test/unit/factory_test.lua` unless noted)

- `the script folder is empty by default, so no start is a first run`: a plain `load_strata()`: `S.factory_clock == nil`, no `audio/strata/factory/` folder, no engine call beyond 3.7.0's (the system tests already hold this).
- `a first run loads the first-run set once`: a fresh data folder, the fixture copied to a temporary script folder, `load_strata({script_dir = ...})`, `finish_startup`, `context.clock.run_for(1)`: the set's audio is at `<audio>strata/factory/dusk-1/pad.wav`, `params:get("v1_grain_size")` is the set's, `buf1_file` the installed path, `S.lib.samples` holds the file's tempo, the header flash is `dusk`, `factory.data` holds `loaded.dusk == 1`; a second `load_strata` on the same folders starts no load.
- `a player with scenes gets nothing`: a `scenes.data` saved before the start: no load, the marker written.
- `an unreadable scenes file is not a first run`: `scenes.data` of `"garbage"` (set aside at step 100): no load (`start_outcome == "unreadable"`).
- `a rig line is refused and printed`: `set.params` with `"midi_device": 3` and `"v2_out_port": 4`: both unchanged, one line each; `"clock_tempo": 90` and `"output_level": 0` (norns' own) unchanged.
- `a sound param the file lacks goes to its default, a text param too`: `v3_grain_pitch` set to 2 before; a set without the line: `param_default`; a text param (1e's `tuning_name`) to its load default.
- `the lines apply in menu order`: `set.params` listing `v1_freq` before `scale` and `v1_quantize`: the stored `freq` is snapped by the set's scale.
- `a number line is rounded` (`"v1_seq_length": 5.6` loads 6) and `a trigger line is skipped`.
- `a missing sample`: `set.samples.data` names `gone.wav` absent from `audio/`: one line, `buf2_file` (whose line names it) keeps its value, the rest of the set loads.
- `an unusable side file is skipped and not renamed`: `set.matrix.data` of `"garbage"`: one line, the file is still at its path with its bytes, no `.bak` beside it, the other four load (the macros' targets are the set's).
- `the live scenes are kept before a load replaces them`: populated live scenes in no PSET: after the load `scenes.data.bak` holds them and `S.scenes` holds the set's; `S.scene_file.pset == nil`; with every backup name taken (`.bak`, `.bak.2` ... `.bak.9`) the load stops with one line and nothing changes.
- `a load installs audio once; a new version installs beside the old`: a second load copies nothing (no `.part` opened, `watch_writes` in `test/helpers.lua:537`); the index at version 2 installs to `dusk-2/` and `dusk-1/` stays.
- `every rig group's params match FACTORY.rig, and no sound param does`: walk `params.params` from each group in `FACTORY.rig.groups` for its `n` params (a group param carries `n`, `test/norns_stubs.lua:1115`): each id matches a pattern; every other Strata record param matches none.
- `a second load while one runs is refused`; `cleanup cancels the load clock` (and the structure test's cleanup order).
- `pages_setup_test.lua`: `the factory sets row opens the list; none with no index`; `K3 loads; with unsaved scenes a second K3 within 2 s`; layout states (the list with a 12-character set name and version, the `none` list, the armed prompt).
- `side_files_test.lua`: `read_only never sets a file aside and loads it as missing`; `the flag is cleared after an error in fn`.
- `scenes_test.lua`: `the scenes start step records its outcome` (missing, loaded, unreadable, older).
- `structure_test.lua`: the start and cleanup rows above.

### 5. Risks and open points

1. **4d's file list is short of what the merged code needs**: `lib/scenes.lua` (export `back_up_live`, the factory branch of `load_pset_scenes`, the start outcome), `lib/constants.lua` (two order numbers), `test/helpers.lua` (the stub option), and probably `lib/samples.lua` and `lib/params_setup.lua`. None conflicts in wave 4.
2. **"In every case the marker is written"** means `factory.data` is written at every first start with no marker, including every test start (each `load_strata` gets a fresh data folder, `test/helpers.lua:129`) and every 3.8 start, which ships no index. That adds a file write to every test start (no current test counts writes from the load, as far as `grep` shows: `gestures_test.lua:712`, `macros_test.lua:896`, `side_files_test.lua:189` count later windows) and an effect to the structure test's start row if the marker is read or written there. Alternative: write the marker only when an index was read; it changes no outcome in 3.8 and keeps every test start's files as they are. The plan should pick.
3. **An unusable side file in a set**: treat it as missing (its module's `load(nil)`: the macros and matrix are emptied, the gestures cleared, the live scenes left) or leave the module as it was. The design says "skipped"; the first is the PSET rule for a missing file.
4. **The allow side needs two things `lib/params_setup.lua` keeps local**: `pset.record_params` (every param Strata's records add, `:138`, `:159-172`) and `pset.default` (`:194-204`), which 1e extends to the tuning's text params. Proposed exports: `S.lib.params_setup.record_param_ids()` and `S.lib.params_setup.load_default(param)`; 1e owns the read hook's text default, so 1e should add `load_default` and 4d `record_param_ids` (or 1e both).
5. **Unclassified params**: `tempo` (a set's line sets norns' clock tempo through `clock_tempo`, the very effect §9 avoided by not using a PSET), `seq_follow_transport`, the record group, `input_follow_gain`, `scene_sequencer_enabled`, `mutation_enabled`, `v<i>_solo`. The design's rig list does not name them, so as written they are sound and a set moves them.
6. **`S.lib.samples.store_file` checks nothing** (`lib/samples.lua:336-349` copies the fields; `record_from`, which checks them, is local, `:101-117`). A bad record from a set would be stored and written to `samples.data`, whose read may then set the whole file aside. Proposed: `store_file` refuses a record `record_from` refuses (returns false), a one-line change to `lib/samples.lua`; or the factory checks each record itself, which needs `record_from` exported.
7. **A missing sample's slot line**: skipped (the slot keeps the player's audio) is proposed; applying it would send `loadBuffer` for a missing file, which the engine refuses and Lua reports as `buf <n> load failed` (`lib/buffers.lua:851-883` on the facts file's reading).
8. **A slot holding an unsaved take**: a set's slot line replaces it (`load_buffer` sets `take_unsaved = false`, `lib/buffers.lua:461-490`). §9's confirm covers unsaved scenes only; the anti-goal "losing a player's data silently" suggests the confirm should also arm for a named slot holding an unsaved take.
9. **Morph during the params step**: setting `morph` and `morph_y` starts morph's clock, which would apply the corners over the set's params; morph's PSET hook (`lib/morph.lua:741-744`, `stop_clock(false)`, `forget_applied()`) must run right after the params, which step 5 does if `morph` is in `FACTORY.pset_hooks`.
10. **The copy's cost on a device** is unmeasured (facts file: tens of milliseconds a few MB, est.); the chunk size is the builder's (§ Left to the builder). The copy is pure Lua (`io.open` rb/wb, `os.rename`); `util.make_dir` runs `mkdir -p` unquoted on norns, so the key pattern is a safety rule, not a style one.
11. **Where the list's UI lives**: the design names only `lib/factory.lua`; the zones editor and the slice editor live under `lib/ui/`. Keeping the owner in `lib/factory.lua` is one module row; a `lib/ui/factory_list.lua` is a second module, unit file and row.

---

## For the planner

1. **4d edits `lib/scenes.lua` in three places §14 does not give it**: `back_up_live` is local (`lib/scenes.lua:1394`), `load_pset_scenes` would back up a second time and mark the scenes as held by a file in the code folder (`:1427`, `:1435`), and no field records "no scenes file found at this start" (`:1467` drops the outcome). Add the file to 4d's list (3b, wave 3, edits it first).
2. **The VOICE `preset` row needs `lib/ui/cursors.lua:30` changed**, or the anchor of a row with no `param_id` matches the first label row and the cursor lands on a label; and `voice_page_group` must skip the row or the arc's rings call `arc_sweep_param(nil)` (`lib/arc/voice.lua:41-68`). Add `lib/ui/cursors.lua` to 3b's files.
3. **A held voice undo needs `undo_for` to match any VOICE section of the voice** (`lib/ui/alt.lua:77` passes the cursor's section), and the undo should restore the capture's type and values with the voice's present `active` and `source` (`apply_voice` would otherwise stop a voice started after the load).
4. **`release_voice` must reach the landing through the closure, not `S.SCENE_TRANSITION`**: `end_scene_transition("landing")` runs as an argument before `recall_scene_instant` (`lib/scenes.lua:723`) and clears the fields. The filter belongs in `apply_entries` (`opts.skip_voices`), per the scenes notes' "one list" rule.
5. **`VOICE_PRESETS.keys` has three keys the design leaves open**: `mod_speed`, the six `env_*` and `reverse` (probe of `voice_scene_keys`). The plan should rule; proposal out, in, in.
6. **A factory set's side files can be loaded with no change to the five modules**: run the PSET hooks named `scenes, macros, morph, gestures, sequences, matrix` (registry order) with `path_base = <script>/factory/<key>/set` inside a `S.lib.side_files.read_only(fn)` flag that stops `files.read` from setting a file aside (`lib/side_files.lua:100-106`). Morph's hook must run, or its clock applies the corners over the set's params.
7. **The allow side needs `pset.record_params` and `pset.default`, both local to `lib/params_setup.lua`** (`:138`, `:194`); 1e extends the default to text params. Decide who exports them (proposal: 1e exports `load_default`, 4d `record_param_ids`).
8. **Seven params are neither rig nor obviously sound** (`tempo`, which sets norns' clock, `seq_follow_transport`, the record group, `input_follow_gain`, `scene_sequencer_enabled`, `mutation_enabled`, `v<i>_solo`); `FACTORY.rig` (185 params in seven groups on `main`) should rule on each.
9. **"The marker is written in every case" writes `factory.data` at every test start and every 3.8 start**, which has no index; writing it only once an index was read changes no 3.8 outcome and keeps test starts' files and the structure test's start row unchanged.
10. **Tests must copy the factory fixture to a temporary script folder**: a failing read-only path would otherwise rename a tracked file under `test/fixtures/`; and `S.lib.samples.store_file` stores an unchecked record (`lib/samples.lua:336`), so either it gains `record_from`'s check or the factory checks records itself.
