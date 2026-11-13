## Must not break

- MAIN is found by index (`S.ui_page == UI_PAGES.index.MAIN`), never by its title string.
- No MAIN string between the header and the hint row crosses the divider at x=62: it ends by x=60 or starts at x=65 (the layout tests check it for every voice, source, lock and running state, and the fields at their widest values).
- Every voice-list entry is plain ASCII and at most `5+ pulse [L]` wide (49 px as the harness measures with norns' own advances, 11 px inside the 60 px bound, so it ends by x=60); a voice type's `MAIN_PARAMS[type].list_name` has at most 5 characters.
- The voice list never scrolls past an end: `place_voice_list()` sets `num_above_selected` to 0 for the first voice, 2 for the last and 1 otherwise, on every `update_voice_list()` and every draw (the selection can move without `update_voice_list`).
- The main parameter comes from `main_param_entry(voice_idx)` (`MAIN_PARAMS`, `BUFFER_MAIN_PARAM`, `INPUT_MAIN_PARAM`), never from an `if v.name ==` chain. E3, arc ring 2 and the details column all use it. The three fields come from `main_fields(voice_idx)`; E3 edits `main_fields(S.selected_voice)[S.main_field]` through `enc_param_delta`.
- K3 and MAIN's `arc_button` are the same function (`start_stop_selected_voice`): start or stop, never lock, never fire a triggered grain.
- ALT+K3 goes through the record's `alt_key` (`alt_action`) and is `toggle_lock`, at the press. ALT+K2 acts on release through the shared handler (`S.lib.ui_alt.k2_down` from `alt_key`, `k2_up` from `alt_key_release`, `docs/notes/lua/ui/alt-and-keys.md`): a quick press undoes only while `undo_available(S.selected_voice)` (MAIN's undo of that voice), else randomizes it; a press held `ALT_HOLD_SECONDS` cancels (MAIN has no `alt_hold`). The hint and the release share one decision (`k2_hint`: `undo`, `locked` or `rand`, then `cancel` once held `ALT_HOLD_SECONDS`; `locked` and `cancel` do nothing), so it never offers an undo the key would not run, says `locked` instead of `rand` when the voice is locked (randomize would do nothing), and says `cancel` when the release would do nothing. MAIN animates while ALT+K2 is down (`main_animates`, `S.lib.ui_alt.k2_held`), so the frame clock draws `K2:cancel` at the hold time.
- ALT+K2 acts on the voice selected at its release, not at its press: an E2 turn while K2 is down (with ALT, E2 reaches `main_enc`, MAIN having no `alt_enc`) selects another voice, and the hint follows it, since `randomize_section` and `k2_hint` read `S.selected_voice` when they run.
- What MAIN's randomize changes is `randomize_voice`'s (`S.lib.mutation.voice_spec`, the same params, ranges and draw order as before #557): `randomize_section()` returns that spec, with `"locked"` for a locked voice, so an undo made before the lock still runs.
- A locked voice's fields are drawn at the same levels as an unlocked one's (the selected field 15, the others 4); `[L]` is drawn at 15.
- The status row (y 26) holds `OFF [L] [T] [F]` at its widest, ending by x 127 (fixed x: 65, 84, 99, 113). `[F]` comes from `S.lib.freeze.is_frozen` (3.2's audio freeze, `docs/notes/lua/freeze.md`), never from `S.frozen` (the lock); the voice list has no room for it.
- The name on y 18 is cut with `fit_text` to end `LAYOUT.name_gap` px before the right-aligned source, so the two never overlap. Under the harness estimate RESONATOR and KARPLUS are cut; with the norns font only RESONATOR is (`RESONAT`).
- 3.4's mark (`LAYOUT.modulated_mark`, `~`) follows the name on y 18, never the status row (y 26 is full: plan item 15), while `engine_modulated(voice)` holds: an LFO the LFO module plays in the engine (`S.lib.lfos.engine_playing(n)`, its own answer, never a copy: on, on a fast destination, at a depth above 0; design §2.6) whose destination is one of the voice's (`S.lib.lfos.destination(n).fast.voice`), `S.lib.scatter.affects(voice)` (on, depth above 0, a destination on, the voice unlocked) or `S.lib.matrix.affects(voice)` (a routing that plays on one of its params). The name is cut by the mark's width and `LAYOUT.mark_gap` (1 px) more, so the mark ends 2 px before the source and name, mark and source never overlap. Scatter and the matrix are always loaded and read directly. Every change the mark follows already asks for a redraw (the params' actions, `toggle_lock`, the matrix's routing changes).

## Owns

- `lib/pages/main.lua` (`S.lib.pages_main`): the MAIN record (`S.registry.pages[UI_PAGES.index.MAIN]`, with `alt_key`, `alt_key_release`, `randomize_section`, `animates`, `arc_button` and `layout_states`), `redraw_main`, `main_enc`, `main_key`, `main_alt_key`, `main_alt_key_release`, `main_randomize_section`, `main_animates`, `main_hints`, `start_stop_selected_voice` (also `S.lib.pages_main.start_stop_selected_voice`), `engine_modulated` (also `S.lib.pages_main.engine_modulated`), `S.lib.pages_main.LAYOUT`; the state `S.voice_list` and `S.main_field`; the globals `update_voice_list`, `main_param_id`, `main_param_entry`, `main_fields`.
- Its unit tests: `test/unit/pages_main_test.lua`. Its rings: `lib/arc/main.lua` (`docs/notes/lua/arc-pages.md`).

## Keys

`main_enc`, `main_key`, `main_alt_key`, `main_alt_key_release` (3.1 design §2; ALT+K2 on release, #557):
- E2 selects the voice (`S.lib.ui_keys.select_voice_by`), E3 adjusts the field under the cursor (`enc_param_delta`, so ALT+E3 is fine).
- K2 steps the cursor `S.main_field` 1 → 2 → 3 → 1. One cursor for every voice: each voice has three fields, so it never needs clamping.
- K3 starts or stops the selected voice (`toggle_voice`); the arc button does the same.
- ALT+K2, at its release (`S.lib.ui_alt.k2_up`): a press released within `ALT_HOLD_SECONDS` (0.5 s) undoes while `undo_available(S.selected_voice)` (the `UNDO_SECONDS` window after MAIN's randomize of this voice; `lib/mutation.lua`), else randomizes the voice (`randomize_voice`'s spec; a locked voice is left alone), the voice selected at the release (E2 while K2 is down moves it); a longer press cancels, and the hint says `K2:cancel` from the hold time. ALT+K3: `toggle_lock(S.selected_voice)`, at the press.
- Hint row: `K2:field K3:start|stop`; with ALT `K2:undo|locked|rand|cancel K3:lock|unlock` (cancel while ALT+K2 has been held `ALT_HOLD_SECONDS`, else undo while available, else locked for a locked voice, else rand; `S.lib.ui_alt.k2_hint`). `K2:cancel K3:unlock` is as wide as `K2:locked K3:unlock`. With K1 let go while ALT+K2 is down, `k2_hint(record)` alone, since the release still acts (`docs/notes/lua/ui/alt-and-keys.md`). The undo window's end redraws the hint without input (the undo clock calls `request_redraw()`). An undo made on another page or section is not offered on MAIN: a quick press there randomizes.

## Main parameter and fields

- `main_param_id(voice_idx)` returns the param of field 1 and arc ring 2: `v<i>_freq` resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring.
- It reads `main_param_entry(voice_idx)`, whose `label` is its screen label:
  - the `MAIN_PARAMS` entry for the voice type (param id suffix, screen label, value format; arc ring 2 sweeps it with `arc_sweep_param`);
  - `BUFFER_MAIN_PARAM` (`buf_pos`, label `pos`, `%.2f`) for a buffer source (3.0 design §1);
  - `INPUT_MAIN_PARAM` (`grain_size`, label `size`, `%.2f s`) for the input source (its synth and buffer params do nothing).
- `main_fields(voice_idx)` returns the three ids MAIN shows: `{main_param_id(i), "v<i>_grain_size", "v<i>_grain_density"}` for a synth or buffer voice, `{"v<i>_grain_size", "v<i>_grain_density", "v<i>_grain_pitch"}` for an input voice (its main param already is grain size).
- Field 1's label and format come from `main_param_entry`, the grain fields' from the module's `GRAIN_FIELDS`: `size` `%.2f s`, `dens` `%.0f /s`, `pitch` `%.2fx`.
- Arc ring 2 is drawn to `param_fraction(main_param_id(...))` of a turn, following the warp like the FX and BUFFER rings.

## Voice list

- `update_voice_list()` recreates the `UI.ScrollingList` (`S.voice_list`) on every change.
- Each entry is `<n><+|-|m|s> <name>[ [L]]` (`m`: a running voice that `S.lib.voice_mix.silenced` says is silenced; `s`: a running voice that is soloed and not muted; a stopped voice is always `-`; the mute and solo params' actions rebuild the list), plain ASCII, so its width does not depend on how the norns font draws other glyphs:
  - the voice number;
  - active status (`+` running, `-` stopped);
  - the voice type's short name, `MAIN_PARAMS[type].list_name` (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`; at most 5 characters). The details column shows the full name and ON/OFF;
  - lock status (` [L]` suffix).
- Four rows (y 15-48). The norns `ScrollingList` leaves a blank first row when the first entry is selected with one row above the selection, so `place_voice_list()` sets `num_above_selected` per selection (0 first, 2 last, 1 otherwise): voices 1-4 for voice 1, 4-7 for voice 7.

## Layout

Two columns under the header (`draw_header()`, the same on every page: `docs/notes/lua/ui/header-and-flashes.md`), positions in `S.lib.pages_main.LAYOUT`:
- **Left column** (0-60 px): the voice list.
- **Divider** (x=62, y 10-52): a subtle vertical line.
- **Right column** (65-127 px), the selected voice:
  - y=18: the full name (level 15, cut to fit), `~` right after it (level 15) while the engine's modulation moves the voice, and the source right-aligned at 127 (`voice_source_label`: `synth`, `buf 1`-`buf 8`, `input`; level 4);
  - y=26: `ON`/`OFF` (level 4) at x=65, `[L]` at x=84 (level 15) when locked, `[T]` at x=99 (level 8) in triggered grain mode, `[F]` at x=113 (level 15) while frozen (`S.lib.freeze.is_frozen`). Fixed x, so nothing shifts as they come and go;
  - y=34, 42, 50: the three fields: the cursor `>` at x=65 on the selected one, the label at x=71, the value with its unit right-aligned at 127. The selected field is at 15, the others at 4, locked or not.
- `mod:` (crossmod sources) is not on MAIN; the VOICE page shows them.
- **Hint row** (y=62): see Keys.

`layout_states` (drawn by `test/unit/ui_layout_test.lua` and the page renders): every voice running, locked, triggered and frozen with the cursor on field 3, with voice 1 selected; the same with voice 7 on buffer 8; voice 1 on the input; the voice list's m and s marks; `~` after RESONATOR on buffer 8 (scatter on); and voice 1 locked with ALT+K2 held `ALT_HOLD_SECONDS`, for the widest ALT hint, `K2:cancel K3:unlock`.

Layout tests: `test/unit/pages_main_test.lua` draws the list for every voice, selection and running/locked state, MAIN for buffer- and input-sourced voices, and the fields at their minimum and maximum values for every voice, source and cursor position; `test/unit/ui_layout_test.lua` draws MAIN with every voice, source, ALT state and flash, and the layout states.
