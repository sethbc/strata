## Must not break

- MAIN is found by index (`S.ui_page == UI_PAGES.MAIN_PAGE`), never by its title string.
- No MAIN string between the header and the hint row crosses the divider at x=62: it ends by x=60 or starts at x=65 (the layout tests check it for every voice, source, lock and running state).
- Every voice-list entry is plain ASCII and at most `+ pulse [L]` wide (54 px by the harness estimate); a voice type's `MAIN_PARAMS[type].list_name` has at most 5 characters.
- The main parameter comes from `main_param_entry(voice_idx)` (`MAIN_PARAMS`, `BUFFER_MAIN_PARAM`, `INPUT_MAIN_PARAM`), never from an `if v.name ==` chain. E3, arc ring 2 and the details column all use it.
- K3 never stops a voice and never fires a triggered grain (`start_or_lock_selected_voice`). MAIN's `arc_button` is the same function.

## Owns

- `lib/pages/main.lua` (`S.lib.pages_main`): the MAIN record (`S.registry.pages[UI_PAGES.index.MAIN]`, with `arc_button`), `redraw_main`, `main_enc`, `main_key`, `main_hints`, `start_or_lock_selected_voice`; `S.voice_list`, `update_voice_list`, `main_param_id`, `main_param_entry`, `main_param_label` (global).
- Its unit tests: `test/unit/pages_main_test.lua`. Its rings: `lib/arc/main.lua` (`docs/notes/lua/arc-pages.md`).

## Keys

`redraw_main`, `main_enc`, `main_key`: the original screen.
- E2 selects the voice (`select_voice_by`), E3 adjusts its main parameter (`enc_param_delta`, so ALT+E3 is fine).
- K2 randomizes. K3 starts a stopped voice or locks/unlocks a running one (`start_or_lock_selected_voice`; it never stops a voice).
- Hint row: `K2:rand K3:lock` for a running voice, `K2:rand K3:start` for a stopped one. No ALT keys yet.

## Main parameter

- `main_param_id(voice_idx)` returns the param E3 and arc ring 2 adjust: `v<i>_freq` resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring.
- `main_param_label(voice_idx)` returns its screen label.
- Both read `main_param_entry(voice_idx)`:
  - the `MAIN_PARAMS` entry for the voice type (param id suffix, screen label, value format; arc ring 2 sweeps it with `arc_sweep_param`);
  - `BUFFER_MAIN_PARAM` (`buf_pos`, label `pos`, `%.2f`) for a buffer source (3.0 design §1);
  - `INPUT_MAIN_PARAM` (`grain_size`, label `size`, `%.2f s`) for the input source (its synth and buffer params do nothing).
- Use them instead of `if v.name ==` chains. Arc ring 2 is drawn to `param_fraction(main_param_id(...))` of a turn, following the warp like the FX and BUFFER rings.

## Voice list

- `update_voice_list()` recreates the `UI.ScrollingList` (`S.voice_list`) on every change.
- Each entry is plain ASCII, so its width does not depend on how the norns font draws other glyphs:
  - active status (`+` running, `-` stopped);
  - the voice type's short name, `MAIN_PARAMS[type].list_name` (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`; at most 5 characters). The details column shows the full name and ON/OFF;
  - lock status (` [L]` suffix).
- The widest entry, `+ pulse [L]`, is 54 px by the harness estimate, so it ends 8 px before the divider.
- The list puts the selected voice on row 2 (y=26, the ON/OFF row) except at the ends of the list (`num_above_selected` = 1), so entries must stay left of x=60 or they overlap the details.

## Layout

Two columns under the header (`draw_header()`, the same on every page: `docs/notes/lua/ui-core.md`):
- **Left column** (0-60 px): the scrolling voice list (4 visible at a time, rows y=15-48).
- **Right column** (65-128 px): the selected voice's details (name, status, main parameter at y=42/50). `[LOCK]` is right-aligned at x=127 on the status row (y=26), `[TRIG]` (triggered grain mode) right-aligned at x=127 on the main-parameter label row (y=42).
- **Divider** (x=62): a subtle vertical line between the columns.
- **Hint row** (y=62): `K2:rand K3:lock|start`.

Layout tests: `test/unit/pages_main_test.lua` draws the list for every voice, selection and running/locked state, and MAIN for buffer- and input-sourced voices; `test/unit/ui_layout_test.lua` draws MAIN with every voice, source, ALT state and flash.
