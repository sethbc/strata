# Facts: voice presets, voice copy, and installing and loading factory presets

Read-only survey of `main` at 59a0a0c1 (the groundwork has not landed: only 0a's branch exists), of the groundwork's design, plan rulings and fact files (`plan-1a-values.md`, `plan-3a-4a-scenes.md`, `data-files-extras.md`), and of norns' source at ~/src/norns (227aa044, v3.0.2-autotest-7). Where the groundwork changes the code, this file describes it as the groundwork leaves it and says so ("after 1a", "after 4a"); line numbers are `main`'s. One figure is **measured** (one scratch Lua 5.3 run of the test harness's `load_strata()`, desktop, standard tier, nothing tracked changed); the repository sizes are **measured** with `git count-objects` and `du`; everything else is **quoted** with its source or marked **(est.)**. Nothing was checked on a device.

## 0. The facts most likely to change the design

1. **`capture_voice(i)` is a scene's voice, not a "sound"**: after 1a it returns `{active, source, values}`, with `values` holding all 73-77 scene keys of the voice (plan-1a-values.md:173, :183; plan:227). That includes the running state (`active`), the source index, the eight `seq_*` playing settings, `mute`, the four bookmarks, the loop, `slices`, `scan_mode`, `follow`, `freeze`, `history`, the envelope and expression keys, and every `mod_source_<n>` (an absolute voice number). It leaves out `note_cap` and `solo` (not scene keys, plan-1a-values.md:49). A preset that is "the sound" (ROADMAP.md:139) is a filtered `capture_voice`, and the filter is the design's to define.
2. **`apply_voice` refuses another type's data whole.** It fills missing keys from the *target's* defaults (`param_default("v<i>_<key>")`, plan-1a-values.md:167, :176) and then requires `values` to hold exactly `voice_scene_keys(i)`'s keys: an unknown key rejects the whole call with one console line (plan-1a-values.md:184). Voice 2's `ratio`, `index`, `modFreq` into voice 5 (Pulse) is refused. Copy and load across today's fixed types must drop the keys the target lacks before the call, and decide whether the target's own keys the source lacks take their defaults (the fill) or keep their current values. It also requires `active` (boolean) and `source` (1..10), so a caller that should not start, stop or re-source the target must put the target's own values there.
3. **The shared keys:** all 9 grain, 10 crossmod and 51 registered keys exist on every voice. Of the synth keys only `freq` and `amp` are on all seven; `pan` is on six (not Sub); `ratio` (FM, Ring) and `mod` (Folder, Ring) on two, with one spec each but different meanings (`lib/voices.lua:17-232`, `lib/params_setup.lua:1198-1219`). Every other synth key is on one type only.
4. **A running fade overwrites what `apply_voice` sets.** The fade's clock holds its targets in a closure (`lib/scenes.lua:713-760`) and sets them every step; its landing runs `recall_scene_instant` over the whole scene (`:766`), voice `active` and `source` included. No code can take one voice out of a running fade. The options are to cancel it first (`cancel_scene_transition()`, global, `:430-432`: the values stay mid-way, the previous scene is current again), to refuse during a fade, or to let the fade win; a new seam in `recall_scene` would be needed for anything finer.
5. **Every PSET read sets the player's rig.** norns writes every param with `save` (all of them by default, `paramset.lua:180`, `:513`), norns' own included: output, input and monitor levels, norns' reverb and compressor, the clock source and tempo (`lua/core/audio.lua:615-815`, `lua/core/script.lua:120-122`). Strata's read hook then sets every param of its own records that the file has no line for to its default (#628, `lib/params_setup.lua:226-238`), so a factory PSET stripped of `midi_device`, the MIDI and MPE settings, the 14 `v<i>_out_*`/`zone*` params and the IO groups would *reset* them, not leave the player's. A factory set as "one PSET" (groundwork design §6) cannot meet "never touches a player's data" (ROADMAP.md:182) without a filtered read or a file that is not a norns PSET.
6. **"A first run that finds no scenes file" is not a once-only test.** Every clean exit writes `scenes.data`, empty slots too (`lib/scenes.lua:1322-1333`, `:1042-1066`), so the file is missing only on a first start, after a start whose session never reached cleanup (a power cut), or after the player removes it. A 3.7 player's first start after the groundwork finds a file (set aside as older), not none. And every test's `load_strata()` gets a fresh data folder (`test/helpers.lua:129`), so every test start would be a first run once factory files exist.
7. **The repository ignores what a factory set is made of:** `.gitignore:2-4` ignores `*.pset`, `*.pmap` and `data/`. norns already copies a script's `data/*.pset` into its data folder when that folder does not exist (`lua/core/script.lua:194-200`), but only `*.pset` (no side files, no audio) and only on the very first load.
8. **A factory PSET outside the menu's glob is invisible to the PSET menu,** which lists `norns.state.data .. shortname .. "*.pset"` and numbers each by `(%d+).pset$`, a name without digits counting as 1 (`lua/core/menu/params.lua:69-101`). So `data/strata/strata-factory.pset` would take slot 1's place in the list; a file in a subfolder, or not starting with `strata`, is never listed; a high number (90-99) is listed and can be saved over from the menu.
9. **VOICE has no free key.** K2 and K3 jump sections at the press, ALT+K2 randomizes or undoes (quick) and resets the row (held), ALT+K3 locks at the press (`lib/pages/voice.lua:266-295`). What is free: holds of K2, K3 and ALT+K3 (each would move its action to the release), ALT+E2 (VOICE has no `alt_enc`, so ALT+E2 does E2's work, `docs/notes/lua/pages/voice.md`), or a new row or section with an action.
10. **A second norns file selector or text entry is not free.** `redraw()` in `strata.lua:309-310` knows only BUFFER's selector (`S.BUFFER_PAGE.file_selector_open`), and AGENTS.md forbids editing `redraw()`; SCENES' text entry needs its release-time opening, `forget_held_keys` and a `menu_close` hook (`docs/notes/lua/pages/scenes.md`, Must not break). A pick list drawn by Strata as a modal owner (`S.lib.ui_modal`, as the zones editor) needs neither.

## 1. What a voice's sound is, as data

**After 1a** (plan:220-227; plan-1a-values.md:134-188):

- `S.voices[i].values[key]`, a key being the param id without `v<i>_`. The voice keeps `name`, `active`, `source`, `param_order` as fields.
- `S.lib.scenes.capture_voice(i)`: a fresh `{active, source, values}`, `values` holding exactly the voice's scene keys; nil for a bad index.
- `voice_scene_keys(i)` (`lib/params_setup.lua`, new): `list, by_key`; `list` in recall order: the synth keys sorted, the 9 grain keys sorted, the 10 crossmod keys sorted, then the registered scene keys sorted; each `{key, default, range, limits}`. Ranges: `grain_env` {1, 5}, `grain_mode` {1, 2}, `mod_source_N` {0, `NUM_VOICES`}, and each record's `discrete`.
- `S.lib.scenes.voice_entries(i, data)`: entries `active`, the source, then the values in recall order (built-in keys sorted, then registered keys sorted: ruling 4, so `freq` comes before `freeze` and `loop_length` before `loop_start`).
- `S.lib.scenes.apply_voice(i, data, opts) -> boolean`: refuses a bad index or data still invalid after the fill (one console line, nothing applied); fills a deep copy (missing keys from the target's defaults, then each record's `normalize_scene`); runs `apply_entries(voice_entries(i, copy), opts)`. So `S.scene_recall_in_progress` is set throughout (the source-change hooks and `freq`'s scale filter stand down, `lib/scenes.lua:554-601`, `lib/variation.lua:203, 322`); a voice whose `active` entry stops it stops first; one it starts starts after its last value; a running voice whose source changed gets one `sync_voice_values_to_engine` and `S.lib.notes.recall_switched` (`:594-600`); every `scene_applied` hook runs once per call (`:582-585`). It leaves the pattern, the lock, the globals, the blocks, `S.current_scene` and a running transition alone. `opts.only` (`"discrete"` or `"continuous"`) is apply_entries' (`:555-558`); `apply_voice` has no fade of its own.

**Measured** (scratch run, today's nested shape flattened to format 9's): a voice holds 77 (Resonator), 76 (FM, Pulse, Karplus, Ring), 75 (Folder) and 73 (Sub) scene keys; one voice written as a data file `{version, preset = {name, type, voice = {active, source, values}}}` through `S.lib.data_files.encode` is 1901-1969 bytes at the defaults and 4 tables. Values far from the defaults print up to 14 significant digits: about 2.5 KB a voice (est.).

**During a running fade** (ruling 6 leaves it to 3.8): `recall_scene` snapshots `targets` once (`lib/scenes.lua:715`), each of the 20 steps sets every target (`:739-741`), and the landing applies the whole scene (`:766`). So a voice applied mid-fade has its continuous keys pulled back toward the scene within one step (`transition_time / 20` s) and its discrete keys, `active` and `source` replaced at the landing. Morph moves only when its params move and stops at rest; a later morph move writes any entry that differs among its corners or that it set before (`docs/notes/lua/morph.md`, Must not break), so it can overwrite an applied voice the same way. The scene sequencer's next pass recalls a whole scene. The chain links patterns only.

**What of a voice lies outside `capture_voice`, where it is kept, and whether it could travel:**

| Part | Where it is kept | In `capture_voice`? | Could it travel with a preset |
|---|---|---|---|
| Type (`S.voices[i].name`) | `lib/voices.lua:19, 52, ...`, fixed by index; no PSET or scene line | no | as a string field, only with a type change (`docs/design/3.8-facts/lua-types.md`) |
| Source (1 synth, 2-9 buffer slot, 10 input) | `S.voices[i].source`; `v<i>_source` (PSET); `scene.voices[i].source` | yes | yes, but a slot index plays whatever the slot holds (scenes name slots by index, never contents: `data-files-extras.md:39`) |
| The slot's file and start | `S.buffers[slot].path`, `.start`; `buffers.data` `paths`, `starts`, `settings` (`docs/notes/lua/buffers.md`, buffers.data); the PSET's `buf<n>_file` (path only, no start: `lib/params_setup.lua:668-669` loads with start 0) | no | as a path and start; loading it changes the slot for every voice that reads it |
| Slice mode (`slices`: off, one, overlap) | `values.slices` (`lib/slices.lua:488-507`) | yes | yes |
| Slice markers, mode, count, sensitivity, tempo, key, normalize | the file's record in `samples.data`, keyed by path and start together (`lib/samples.lua:128-133`, `:253-276`), or a take's `buffers.data` `settings[n]` | no | only with the file; `S.lib.samples.store_file(path, record)` (`:336-349`) stores a record for a path at start 0 |
| The 14 IO and zone params (`v<i>_out_*` ×11, `v<i>_zone`, `_zone_low`, `_zone_high`) | PSET only (`lib/io/targets.lua`, `lib/mpe.lua`); kept out of the value table (groundwork design §2, decided §8) | no | possible, but they are the rig's |
| LFO home routings aimed at the voice | matrix slots 17-22 after 2b; `matrix.data`, `.matrix.data`, the `matrix` scene block (groundwork design §4) | no | only by rewriting the destination's `v<from>_` to `v<to>_`; a home is the LFO's, not the voice's |
| R routings to `v<i>_` ids, and from `EN<i>` (the voice's envelope) | matrix slots 1-16, same files (`docs/notes/lua/matrix.md`; `lib/envelopes.lua:377`, `data-files-extras.md:118`) | no | by rewriting ids into free slots (16 are shared by the whole script) |
| Macro targets on `v<i>_` ids | `macros.data`, `.macros.data`, the `macros` block | no | same rewriting, into a macro's 8 targets (`MACRO_TARGETS`) |
| Bookmarks | `values.bookmark_1..4` (positions record, `lib/positions.lua:911`) | yes | yes, but they are places in the slot's audio |
| Mute | `values.mute` (voice_mix record) | yes | yes; scenes store mutes, never solos (AGENTS.md, Mute and solo) |
| Solo, note cap | `values.solo`, `values.note_cap` | no (not scene keys) | only by a preset format of its own |
| Lock | `S.locked[i]` after 0a; `scene.locked[i]` | no | not wanted by the roadmap (ROADMAP.md:141) |
| Pattern and step attributes | `S.patterns[i]`; `S.pattern_steps[i]` in the `steps` block | no | the pattern is the grid clipboard's (section 4) |
| The pattern's playing settings (`seq_length`, `_division`, `_direction`, `_misstep`, `_swing`, `_gate`, `_gate_length`, `_gate_release`) | `values` (seq record, `lib/sequencer.lua:1700`) | yes | yes, if the design counts them as sound |

**Relative or tier-bound values inside `capture_voice`:**
- Relative to the slot's audio: `buf_pos`, `buf_rate`, `buf_scan`, `loop_start`, `loop_length`, the bookmarks, `slices`, `scan_mode`, `follow`.
- Naming other voices: `mod_source_1..3` (0 none, 1-7 a voice; a voice may name itself, `lib/params_setup.lua:1129-1145`). Copied from voice 2 to voice 5, "voice 2" stays voice 2, so a voice that read itself now reads its source.
- Tier-bound: `history` (0 to 16 s standard, 60 s high, `docs/notes/lua/history.md`) and `freeze_mode` (spectral on high only, `docs/notes/lua/freeze.md`) clamp when loaded on standard.
- Per-index defaults: the notes record's `attack` and `release` defaults are per voice index (`NOTES.envelope`, `lib/notes.lua:43`), and the fill uses the target's.

## 2. Applying one voice's data to another voice

- **Today's synth keys** (`lib/voices.lua:22, 52, ...`; plan-1a-values.md:24-30): Resonator `freq rq noise mod1 mod2 amp pan`; FM `freq ratio index modFreq amp pan`; Folder `freq fold mod amp pan`; Sub `freq drift amp`; Pulse `freq width cutoff res amp pan`; Karplus `freq decay damping excite amp pan`; Ring `freq ratio mod brightness amp pan`.
- **Ranges:** one spec per name, shared by every type that has it (`lib/params_setup.lua:1198-1227`): a shared key's value is always in range on the target. `freq` is 20-2000 Hz on every type. Defaults differ per voice: `get_param_spec`'s copy takes the voice table's default.
- **What `apply_voice` does with a key the target lacks:** it refuses the whole call (§0 fact 2). Missing keys are filled with the target's defaults, not its current values.
- **For copy:** the caller builds `capture_voice(target)`, overlays the source's values for the keys both share, and passes the result. That keeps the target's own synth keys, `active` and `source`. A plain `apply_voice(target, capture_voice(source))` works only between voices of one type, and only if starting, stopping or re-sourcing the target is wanted.
- **For a preset across types:** the same overlay, or a type change first. If 3.8 lets a voice change type, copy and load need four things from it:
  1. The type in the data: `capture_voice` holds no `name` today, so presets and scenes both need it.
  2. The type set before validation: `apply_voice` validates against the target's `voice_scene_keys(i)`, which must already be the new type's.
  3. The type change inside the same apply, so the source switch, the voice's sync and the start order stay one apply (a type change made outside `apply_entries` would sync the old values first, as a source switch outside a recall does: `docs/notes/lua/params.md`, source change hooks).
  4. Per-type defaults for the fill: `NOTES.envelope` and `PULSE_RES` (`lib/constants.lua:20`) are tied to an index or a def today (`data-files-extras.md:126`).
- **The locked voice:** `apply_voice` neither reads nor sets the lock. Randomize refuses a locked voice (`lib/mutation.lua:144`). The rule is "randomize, drift, mutation and scatter leave a locked voice alone, and it can still be edited" (AGENTS.md, Lock), and a scene recall applies a locked voice's values (`lib/scenes.lua:504-535` has no lock check), so loading into a locked voice is the design's call.
- **Engine load:** a copy that switches a running voice's source sends the voice's sync, 58 messages, outside the send budget, as a recall's does (quoted, `docs/notes/lua/morph.md`, the uncounted burst). Its values (about 75) go through `send_param_to_engine`, counted against 150 a window of 0.1 s (`ENGINE_BUDGET`, AGENTS.md). One voice fits one window. A copy to six voices is about 450 counted messages, about 0.3 s of windows (est.).

## 3. Files

**Data files** (`lib/data_files.lua`; `docs/notes/lua/data-files.md`):
- `read` parses `tab.save`'s layout and never runs the file (a structure test, `structure_test.lua:81`).
- `write(path, value)` goes to `path .. ".part"`; open, write, flush, close and rename are each checked; it returns `"unchanged"` without opening when the bytes are equal.
- `set_aside(path, suffix)` takes the first free of `<file><suffix>`, then `.2` to `.9`, and refuses when all nine are taken (`DATA_FILES.backups` 9).
- Caps: `max_bytes` 4 MB, `max_tables` 32768, kept at four times `largest_scenes_tables` (7474 today; 6802, then 6898 after 1a and 2b, plan:102).
- The floor rule: a file from its floor to the build's version loads, filled; any other is set aside, never converted. The structure test (`structure_test.lua:128-140`, `:229-235`) refuses a comparison of a file's version with anything but a name ending `_FLOOR` or `_DATA_VERSION`, so a preset file needs constants named that way.
- The folder is `_path.data .. "strata/"`, hard-coded (`lib/scenes.lua:1014`, `lib/side_files.lua:24`, `lib/notes.lua:91`, `lib/grid/core.lua:587`, `lib/io/rig.lua:56`). norns writes PSETs to `norns.state.data`, which is `_path.data .. <the script folder's name> .. "/"` (`lua/core/script.lua:191`). The two are the same only while the script folder is named `strata`.

**Side files** (`lib/side_files.lua`):
- A spec's fields: `name`, `contents`, `version`, `key`, `live_file`, `side_suffix`, `backup_suffix`, `capture()`, `validate(data)`, `load(data, path, silent)`, and optionally `save_delay` with `clock_field` (`:26-43`). 2b adds an optional `floor`, read at `:75`.
- `pset_hook(before_read, after_read)` (`:140-151`): its `write` always writes, `read` sets an unusable file aside, and `delete` removes the file with `os.remove`. 4a adds `after_write(written, path_base)` and `after_delete(path_base)` (plan-3a-4a-scenes.md:227).
- After 4a, five side files sit beside each PSET: `.macros.data`, `.matrix.data`, `.gestures.data`, `.sequences.data` and `.scenes.data` (`lib/macros.lua:45`, `lib/matrix.lua:50`, `lib/gestures.lua:49`, `lib/random_sequences.lua:37`, plan-3a-4a-scenes.md:221). The hooks register at include time, because `pset_hooks` closes at init (`docs/notes/lua/params.md`, Must not break).

**What a new kind of file needs:**
- **One file of many presets** (a bank, as `scenes.data` is): one read at start, one `write` per save. A damaged file sets every preset aside at once. About 4 tables and 2-2.5 KB a preset (measured above), so the 4 MB cap holds about 1,600 presets (est.). Slots can be numbered, as scenes are, so no folder listing is needed.
- **One file per preset:** each is read on demand, damage stays in one file, and files can be copied by hand. Picking one needs a folder listing. `util.scandir` is forbidden in `lib/` (`structure_test.lua:3385`, #465); `lib/files.lua`'s `list_folder` (`:55-64`, `ls -pL --` with the folder single-quoted) is local to that module. A file name made from a player's text must drop `/`, newlines and shell characters. `util.make_dir` runs `mkdir -p` unquoted, and the stub refuses anything outside `[%w%._/%-+,:@=]` (`test/norns_stubs.lua:803-809`).
- **Either kind:** a module constructor, an include, a notes file and a unit test file, a row in AGENTS.md's module table, a start step if it loads at start, and a cleanup step if it writes at exit. AGENTS.md has 225 words left (`docs/status.md:40`).

**Naming and picking today:**
- Scenes: `S.lib.scenes.set_name(slot, text)` keeps bytes 32-126, cut to `SCENE_NAME_MAX` (12) (`lib/scenes.lua:1411-1420`; `lib/constants.lua:370`), and writes the file at once.
- SCENES' entry: `textentry.enter(callback, default, heading, check)` (`~/src/norns/lua/lib/textentry.lua:41`; `check(text)` returns a warning). It opens on ALT+K2's release after `forget_held_keys()`, and `reconcile_name_entry`, a `menu_close` hook, repairs a menu that took the entry over (`docs/notes/lua/pages/scenes.md`, Must not break).
- BUFFER: a quick K2 release calls `fileselect.enter(_path.audio, cb)` (`lib/pages/buffer.lua:858`). `strata.lua:309-310` draws the selector in place of the page.
  - norns' selector takes a filter: `fs.enter(folder, callback, filter_string)`, where the filter is `"all"`, `"audio"` or an extension matched against the last dot (`fileselect.lua:16`, `:27`, `:128-143`).
  - It lists with `util.scandir` (the folder in double quotes) and calls `audio.file_info` on every file (`:103-125`).
  - It offers `../` only below the folder it entered (`:111-113`), so a player cannot leave that folder.
- BUFFER's random and fill: `S.lib.files.random_into` and `fill_empty` list one folder through `list_folder` (`docs/notes/lua/files.md`).
- PSETs are named in the norns menu's text entry, kept as the file's first line `-- <name>` (`paramset.lua:510`).

## 4. The screen and the grids today

- **VOICE** (`docs/notes/lua/pages/voice.md`; `lib/pages/voice.lua`):
  - E2 moves the row; E3 edits it through `enc_param_delta`; ALT+E3 edits finely.
  - K2 goes to the previous section's first row, K3 to the next one's; both act at the press (`:266-278`).
  - ALT+K2 acts on its release through `S.lib.ui_alt.k2_up`: a quick press randomizes the cursor's section or undoes it; a press held 0.5 s (`ALT_HOLD_SECONDS`) resets the row (`:293-307`).
  - ALT+K3 toggles the lock at the press (`:282-289`). The arc button starts and stops the voice (`:316-318`).
  - No `alt_enc`, no `key_release`. The free gestures are listed in §0 fact 9.
  - Rows come from `voice_page_rows` and the records' `voice_rows` sections. A preset row would be a new row kind, since K3 on a row means "next section" today.
- **The modal owner** (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner):
  - `S.lib.ui_modal.push(owner)` and `pop(owner)`; an owner is `{draw, hints, enc, key, arc_delta, arc_key, arc_redraw, animates}`, and only `draw` is required.
  - While it is pushed it takes the body, the hints, E2, E3, K2, K3 and the arc; E1 does nothing; K1 still sets ALT.
  - The zones editor (`lib/ui/zones.lua`) is a row list in an owner: six rows from y 18, 7 px apart, the scroll marker at x 127.
  - `S.lib.ui_field_list` gives `move`, `clamp`, `first_visible`, `move_scroll` and `draw` over rows `{label, param_id?, selectable, section?}` (`docs/notes/lua/ui/field-list-and-cursors.md`, Field lists).
- **SETUP's action rows:** `{label, kind = "action", hint, run}` entries of `SETUP_FIELDS` (`lib/pages/setup.lua:59-79`): `mpe & zones`, `save scenes` and `load scenes`. K3 calls `run`, which flashes through `M.flash`. Adding one is one entry. `pages_setup_test.lua` pins field indices, so every field below a new one moves.
- **The grids' pattern copy and paste is the 256's alone** (`lib/grid/layout_256.lua:441-479`; `docs/notes/lua/grid/layout_256.md`, Row 16):
  - Row 16, columns 9-15 (voices 1-7), on every page: with nothing copied, a press copies the voice's levels (`S.patterns[v]` only, not `S.pattern_steps`); with something copied, a press pastes through `S.lib.sequencer.replace_pattern`. Pasting onto the copied voice does nothing. Column 16 clears the clipboard.
  - The clipboard is per port (`grid_core.port_state(port).clipboard`) and goes with the grid.
  - The 128h, 128v and 64 have none (grep finds `clipboard` only in `layout_256.lua` and `grid/core.lua:152`).
  - Tests: `grid_layout_256_test.lua:582, 620, 666`.
- **The undo** (`lib/mutation.lua`):
  - `S.undo = {page, section, voice, values = {[param_id] = old}, ids, pattern, until_time}`, held `UNDO_SECONDS` (5 s, `lib/constants.lua:233`), only from `M.randomize(spec)`, which refuses a locked voice (`:141-161`).
  - `undo_for(page, section, voice)` (`:166-170`) gates it; `M.undo()` puts the values back through `params:set`, in the held order (`:178-185`).
  - Every param a randomize can set calls `note_param_edit(id)`, which ends the undo when the edited id is held (`:233-236`). A preset load or copy through `apply_voice` sets those params, so it ends any undo holding them. A recall clears the undo outright (`clear_undo` in `recall_scene` and `recall_scene_instant`, `lib/scenes.lua:709`, `:790`); `apply_voice` does not.
  - Making a load or copy undoable needs a new entry in `lib/mutation.lua` (a spec holding given values, or a "hold" function). `randomize` with constant draws would refuse locked voices and could not put back `active`, which is no param.
  - The undo restores through `params:set` in the held order, not in recall order, with `S.scene_recall_in_progress` off: a source restored that way runs the source-change hooks (freeze cleared) and its own sync, and `freq`'s scale filter snaps.
  - "Undone only where it was made" means the spec's `page`, `section` and `voice` name the place: a copy made on the grid has no page unless the design names one.

## 5. A PSET as a factory set

- **norns** (`~/src/norns/lua/core/paramset.lua`):
  - `write(filename, name)` (`:498-522`): a number n becomes `norns.state.data .. shortname .. "-" .. %02d .. ".pset"`. It writes `-- <name>`, then one `"id": value` line per saved param (triggers and separators skipped), then calls `action_write(filename, name, number)`.
  - `read(filename, silent)` (`:527-578`): a nil filename means `norns.state.pset_last`. Each line goes through the param's own `set` in file order, then `action_read(filename, silent, number)`. A missing file prints `pset :: <file> not read.`
  - `delete(filename, name, number)` (`:584-595`) runs `norns.system_cmd("rm " .. filename)`, unquoted, then `action_delete`.
  - `number` is `"01"` style for a numbered call and nil for a path.
- **The PSET menu** (`lua/core/menu/params.lua`):
  - It lists `ls -1 <data><shortname>*.pset | sort`, numbers each by `(%d+).pset$` (no digits counts as 1), and offers one past the highest (`:69-101`).
  - Save and load write `pset-last.txt` (`:103-122`, `:270-281`); a script's `params:read` or `write` never does.
  - Delete passes the number (`:292`).
- **pset-last:** read at script load into `norns.state.pset_last` (`lua/core/script.lua:202-213`). Strata never reads a PSET at init (no `params:read` or `params:default` in `lib/` or `strata.lua`).
- **Strata's hooks:** `pset.install_actions` (`lib/params_setup.lua:269-275`) runs `migrate_read_pset` (`:226-238`: every record param with no line goes to its default; number params are rounded), then each `S.registry.pset_hooks` record in its own `pcall`, with `path_base`, the filename without `.pset` (`:251-261`).
- **The PSET hooks after 4a**, in registration order: `scenes` (4a; first, before `morph`), `macros`, `gestures`, `matrix`, `sequences` (side files); `morph`, `scatter`, `io_keyed` (which reads the PSET's own text), `io_tape`, `io_midi_out`, `io_nb` (`grep register_pset_hook lib/`).
- **What a 4a PSET load does with scenes:** it replaces the 16 live scenes and rewrites `scenes.data`, recalls nothing, and ends a running fade. When the live scenes are in no PSET (`S.scene_file.pset == nil`), it first sets the live file aside as `.bak`; with no backup name free it keeps the live scenes. A PSET with no scenes file leaves them (plan-3a-4a-scenes.md:235-258).
- **Buffers in a PSET:** `buf<n>_file` is a norns file param holding an absolute path (`File:get` returns `self.path`, `lua/core/params/file.lua:25-27`). An empty slot saves its folder, `_path.audio` (`lib/buffers.lua:228-262`), which loads nothing (`is_sound_file_path` refuses a trailing `/`, `:224-226`).
  - `File:set` runs the action only when the path changes and the read is not silent (`file.lua:29-41`). An unchanged slot does not reload (`buffers_test.lua:874`, #524).
  - The action is `load_buffer(slot, path)`, start 0 (`lib/params_setup.lua:669`). The start lives only in `buffers.data`.
  - A folder holding `$`, a backtick, `\` or `"` never enters the param (#559, `docs/notes/lua/buffers.md`).
- **`buffers.data`** holds `paths` (absolute, as loaded), `starts` and `settings` (`docs/notes/lua/buffers.md`, Saving).
- **`samples.data`** keys a file's record by path and start together (`lib/samples.lua:128-133`):
  - A record is made at a bind with defaults (`:253-276`).
  - Records at their defaults are pruned; past `max_files` (256) the least recently used unbound one goes (`:144-159`).
  - So samples installed at a fixed path keep their tempo, key and slices only if records for that path and start 0 are put in `samples.data` (`store_file`, `:336-349`) and stay among the 256 most recently used.
  - Slice markers also carry `frames` and `rate`, checked against the slot's length within 0.01 s (`lib/slices.lua:68-92`).
- **A file the PSET names that is missing:** `File:set` lists the missing folder (nothing), then `load_buffer` sends `loadBuffer`. The engine leaves the slot as it was and reports `bufferLoadFailed` (`docs/notes/engine/buffers.md`, Must not break). Lua puts the slot's previous state back, prints `buffer <n>: cannot load <path> (missing, unreadable, empty or damaged)` and flashes `buf <n> load failed` on BUFFER only (`lib/buffers.lua:851-883`). The param keeps the missing path until the slot changes.

## 6. Installing and loading

**What a first start leaves:**
- Before Strata runs, norns makes `norns.state.data` if missing and copies `<script>/data/*.pset` into it (`lua/core/script.lua:194-200`). The engine writes `performance_active.data` at every alloc (`lib/performance.lua:15-21`).
- At cleanup Strata writes `scenes.data` (30, guarded by `S.scenes_loaded`), `buffers.data` (40), the four live side files (`save_now`, `lib/side_files.lua:128-135`, empty data too), `io.data` (`lib/io/rig.lua:187-189`) and `samples.data` (`lib/samples.lua:503-509`, whatever it holds).
- `grids.data`, `notes.data` and `performance.data` are written only when the player changes them.
- So "no scenes file" at the `scenes_load` step (`START_ORDER` 100) is the only signal, and its limits are §0 fact 6. A once-only rule needs its own record: a marker file or a field in a data file, written when the factory set is installed or loaded. A 4a factory load also rewrites `scenes.data` at once (`M.autosave()`, plan-3a-4a-scenes.md:243), which closes the window by itself.

**Where it would run:** a start step after `buffers_load` (110) and `sequences_load` (111) and before `startup_clock` (120, which starts voices 1 and 2, `strata.lua:194-204`), so a PSET read there overrides the live files' loads. `START_ORDER` is `lib/constants.lua:191-230`, and `structure_test.lua:1057` pins the start's observed order.

**SETUP's action:** one `SETUP_FIELDS` entry (§4). A K3 that replaces the session (params, scenes) asks for a second press, as `load scenes` does while scenes are unsaved (`S.lib.scenes.request_load`, `SCENE_LOAD.confirm_seconds` 2 s).

**Copying files on norns:**
- `util.file_exists` (`io.open` for reading: true for a folder on Linux) and `util.make_dir` (`mkdir -p`, unquoted) are `lua/lib/util.lua:36-44` and `:68-70`.
- `util.os_capture(cmd)` runs a shell through `_norns.execute` and blocks (`:77-84`); `norns.system_cmd(cmd, cb)` runs asynchronously (`lua/core/norns.lua:226-228`); `os.execute` is plain Lua.
- Strata's only shell use today is `ls -pL -- '<folder>'` (`lib/files.lua:61`) and `mkdir`. The engine renames its own writes (`renameIntoPlace`).
- A copy in pure Lua (`io.open(src, "rb"):read("*a")`, written to a `.part` and renamed, as `data_files.write` does) needs no shell. Neither form exists in `lib/` today.
- A few MB of audio read and written in one Lua call blocks matron for tens of milliseconds on a CM3 (est.; not measured on a device); a clock that yields between files avoids one long block.

**Where things could live:**
- The script's folder is `norns.state.path` (`lua/core/script.lua:189`). Strata never reads it today, and the test stub's `norns.state` has only `data` and `shortname` (`test/norns_stubs.lua:3301-3303`).
- Reading the factory set in place from the code folder needs no copy, but:
  - the PSET's absolute sample paths would name the code folder;
  - an unusable side file there would be set aside by a rename inside the git checkout (`lib/side_files.lua:82-88`);
  - a player's own PSET saved after it would name code-folder samples that a later release could move.
- Copying samples to a fixed place (`_path.audio .. "strata/factory/"`, beside the saves in `_path.audio .. "strata/"`, `lib/buffers.lua:120`) gives stable absolute paths and stable `samples.data` keys whatever the script folder is named.

**Keeping out of the player's PSET numbers:** §0 fact 8. A numbered factory PSET (90-99) shows in the menu and can be saved over from it. A path the menu never lists is loaded only by Strata (`params:read(path)`, number nil), with its side files beside it by `path_base`.

**Adding to or replacing a set later without touching edited copies:**
- Install into a versioned name or folder and never overwrite an existing file (`util.file_exists` before the copy).
- Or keep a record of what was installed (names and sizes; a checksum in Lua of a few MB costs about a second on a device, est.) and replace only files that still match it.
- A player's edits live in their own numbered PSETs, written by the menu, so a factory set the menu cannot write is never edited in place. A numbered one can be.

**Size:**
- 16-bit stereo WAV at 48 kHz is 192,000 bytes a second (arithmetic), so eight 8 s stereo samples are about 12 MB (est.). FLAC would be smaller, but whether norns' libsndfile reads FLAC is unsure (`lib/files.lua` lists `.flac` and `.ogg` as sound files).
- The repository's pack is 15.69 MiB and its tracked files 12.05 MB (measured: `git count-objects -vH`; `du` of `git ls-files`). Every revision of a binary stays in the history of every clone.
- What reads every tracked file: the US-spelling test reads only `strata.lua`, `README.md`, `AGENTS.md`, `CHANGELOG.md`, `lib/**.sc|lua`, `test/**.lua|scd`, top-level `test/*.sh`, `test/*.sc.in`, `docs/**.md`, `changes/*.md` and the workflow files (`docs_test.lua:1317-1330`). The stray `.sc` test checks only `.sc` names (`structure_test.lua:1335-1356`). `sync_check.lua` and the structure tests read every `lib/**.lua` (`sync_check.lua:284`, `structure_test.lua:2373`). So factory data under a folder of its own (not `lib/`, not `.lua`, not `.md`) is read by no test. norns' SELECT lists every `*.lua` under `code/` outside `lib`, `data`, `crow`, `test` and `docs` folders (`lua/core/menu/select.lua:61-64`).
- CI checks out the repository with `actions/checkout`; no size check exists (`.github/workflows/test.yml:37`, `:134`).

## 7. Tests that pin this today, and the stubs

**Tests:**
- `scenes_test.lua`: capture, recall order against 3.3.2's copies, validation, set aside, names; after 1a also `capture_voice` and `apply_voice` (plan:260-265); after 4a the PSET's scenes (plan-3a-4a-scenes.md:283-294).
- `side_files_test.lua:60-255`: the helper.
- `data_files_test.lua:60-364`: reader, writer, cap, backups.
- `params_setup_test.lua`: `:624` no PSET format; `:656` and `:690` whole numbers; `:755` a missing line is the default (#628); `:797` the PSET hooks' order and arguments.
- `buffers_test.lua:874`: a PSET round trip reloads no unchanged slot.
- `io_rig_test.lua:182`: a PSET load and a scene recall change no rig setting.
- `grid_layout_256_test.lua:582, 620, 666`: copy and paste.
- `mutation_test.lua`: the undo.
- `pages_voice_test.lua` and `pages_setup_test.lua`: keys, hints, pinned field indices.
- `structure_test.lua`:
  - `:81` and `:114`: no `tab.load`, no `tab.save`;
  - `:128-317`: version comparisons;
  - `:831` and `:1057`: the cleanup and start orders;
  - `:2413`: recursive deletes only at guarded sites;
  - `:3385`: no `util.scandir`.
- `docs_test.lua:1317-1342`: US spelling.
- The system tests (`system_37_test.lua`): a default start against 3.7.0's. A factory set loaded at a first run would move them, since every test start is a first run (`test/helpers.lua:129`).

**Stubs** (`test/norns_stubs.lua`):
- `util` (`:763-830`): `time`, `clamp`, `dbamp`, `linlin`, `linexp`, `explin`, `round`, `file_exists`, `make_dir` (refuses shell characters), `scandir`, `os_capture` (real `io.popen`). There is no `util.file_size` or `trim_string_to_width`, and no `norns.system_cmd` or `norns.system_glob`.
- `os` and `io` are Lua's own, on a temporary folder per load.
- `_path` has only `data` and `audio` (`:3313`), and `norns.state` only `data` and `shortname` (`:3303`).
- `ParamSet:write`, `read` and `delete` follow norns' (`:1425-1500`).
- `fileselect` and `textentry` are stubbed (`context.fileselect`; `test/stub_textentry.lua`).
- An install step reading `norns.state.path` or `_path.code` needs the stub to set them, and a test of a first run needs a way to point them at a test folder of factory files. Otherwise the repository's own files would be installed into every test's data folder.

## Where the roadmap or the notes are wrong or silent

- `ROADMAP.md:139`, "its type, synth, grain, filter and send values": `capture_voice` holds much more (§1 table); the roadmap is silent on `active`, `mute`, the `seq_*` settings, envelopes, expression, freeze, history and the buffer-relative keys, all of which a scene's voice carries.
- `ROADMAP.md:141`, "what a preset holds and leaves out (the source and its buffer, the pattern, the lock)": silent on the crossmod sources, which name voices by number (`lib/params_setup.lua:1129-1145`).
- `ROADMAP.md:181`, "with 3.4's side files for macros, routings and recorders": after the groundwork a PSET has five side files (with 3.7's sequences and 4a's scenes).
- `ROADMAP.md:182`, "they load only when asked ..., or once on a first run that finds no scenes file, and a player's scenes, PSETs and buffers are never overwritten":
  - the scenes file is written at every clean exit (`lib/scenes.lua:1322-1333`);
  - a PSET read sets norns' system params and Strata's rig params (§0 fact 5);
  - a 4a PSET load replaces the live scenes (backed up only when they are in no PSET);
  - a PSET's `buf<n>_file` lines replace the player's slots.
- `docs/design/3.8-groundwork-design.md:167`, "A factory set is one PSET with its five side files and its samples": silent on `samples.data` (tempo, key and slices are keyed by path and start and are lost without an entry), on the start point (not in a PSET), on absolute paths, and on `.gitignore:2-4`, which ignores `*.pset` and `data/`.
- The groundwork's plan (removed; its rulings are in `docs/decisions/3.8.md`), ruling 6: it leaves a running fade to 3.8, but the fade's targets are private to `recall_scene`'s closure (`lib/scenes.lua:715-766`), so 3.8 can only cancel it, refuse, or edit `recall_scene`.
- `docs/notes/lua/data-files.md` (Must not break, the side files' rules) and `lib/side_files.lua:5` name three side-file modules; there are four on `main` (sequences, `lib/random_sequences.lua:284`), and five after 4a.
- No notes file says that Strata's data folder (`_path.data .. "strata/"`, `lib/scenes.lua:1014`) and norns' PSET folder (`norns.state.data`, `lua/core/script.lua:191`) differ when the script folder is not named `strata`. A factory set's live and side files would then land in two folders.
- `docs/notes/lua/pages/voice.md` (Keys and encoders) lists every key VOICE uses but not that none is left for a preset or copy action.

## Unsure

- Whether norns' libsndfile (engine and `audio.file_info`) reads FLAC and OGG on a device. `lib/files.lua` accepts them by extension; I found no test or device note.
- Lua copy and checksum times on a CM3, and an SD card's free space on a factory norns: not measured; figures marked est.
- How a player installs Strata (maiden's catalog: a git clone or an archive). It decides what samples in the repository cost each install. Not checked.
- Whether a factory PSET written on one norns reads the same on another: its absolute paths assume `/home/we`. `_path.home` comes from norns' config (`lua/core/config.lua:23`), but I did not check whether it ever differs from `/home/we` on a device.
- Whether 1a's `apply_voice` fill also fills `active` and `source` when absent. The plan says it fills "the missing keys" (plan-1a-values.md:176) and validates `active` as a boolean and `source` as 1..10 (:183); I read no code (1a is not written).
- How a type change adds params (`docs/design/3.8-facts/lua-types.md`) (all types' params at init, or rebuilt) decides whether a cross-type load can be one `apply_entries` call. Not read.
