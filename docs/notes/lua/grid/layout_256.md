## Must not break

- The 256's page 4 has an explicit branch in `grid_key_256`, so it never falls through to the pattern page.
- Pattern keys (rows 1-7) go through `step_key` (16 positions, the column) and scene save keys (page 3, row 3) through `scene_save_key`.
- The FX faders follow changes made anywhere through `fx_fader_changed()`, except during a smooth scene transition, which redraws the grid once per step. The layout record's `fx_faders_page = 4` is what `any_fx_faders()` reads, so FX changes redraw the grids only while a 256 shows page 4.
- Rows 8 and 16 work and draw the same on pages 1, 2 and 4 (page 3, scenes, has only the page keys on row 8 and no row 16).
- The clipboard lives in `grid_core.port_state(port).clipboard` (`{voice = i, steps = {...}}` or nil), never in a module local or on `S`: each grid has its own, and unplugging the grid forgets it. `steps` is a copy of the levels at copy time; a paste copies them into `S.patterns[target]` level by level and never shares the table.
- A paste onto the copied voice changes nothing (the pattern stays as edited since the copy, the clipboard stays). Column 16 is the only way to drop the clipboard.
- A paste calls `grid_core.end_step_gestures(target)`: a step of the target voice held (on any grid) from before the paste never takes a level in the pasted pattern; the next key on that voice toggles its own step.
- The tempo keys light from `grid_core.held(port, x, 8)` (15 held, 4 otherwise); `grid_key` redraws after every press and release, so the layout keeps no lit state of its own. Each tempo press calls `header_flash("tempo <bpm>")` with the tempo it lands on.
- Scene page row 1: the sequencer position (`S.scene_sequencer_position`, the next scene it recalls) at 10 only while `S.scene_sequencer_enabled`; the current scene at 15 wins over it.
- The layout's keys and levels are in the `LAYOUT_256` table at the top of the constructor (no new locals per value).

## Owns

- `lib/grid/layout_256.lua` (`S.lib.grid_layout_256`): `grid_key_256`, `grid_key_256_transport`, `grid_key_256_lock(port, x)`, `grid_redraw_256`, `grid_redraw_256_buffers`, `grid_redraw_256_sources`, `grid_redraw_256_page_row`, `grid_redraw_256_transport`, `grid_redraw_256_lock(port, grid_device)` (global); it registers `S.registry.grid_layouts["256"]`.
- Its unit tests: `test/unit/grid_layout_256_test.lua` (with the fader maths of `lib/grid/faders.lua`, `docs/notes/lua/grid-core.md`).

## Pages

Row 8 columns 13-16 select pages 1-4 (`set_page(port, ...)`): 1 patterns, 2 parameters, 3 scenes, 4 buffers / FX. Rows 1-7 are the patterns on pages 1 and 2; row 8 columns 1-4 play/stop, 5-8 tempo -10, -1, +1, +10; rows 14-15 voice select/toggle and pattern clear/randomize; row 16 lock and copy/paste.

## Row 8: tempo keys

`LAYOUT_256.tempo_steps` maps columns 5-8 to -10, -1, +1, +10. A press calls `params:delta("tempo", step)` (the `tempo` param drives `clock_tempo`) and `header_flash(string.format("tempo %d", ...))` with the new tempo, so the screen's header shows it for 1.5 s on any page. `grid_redraw_256_transport` lights a held tempo key at 15 (`grid_core.held`), the others at 4.

## Row 16: lock, freeze and copy/paste

`grid_key_256_lock(port, x)`:
- Columns 1-7: `toggle_lock(x)` (stored as `S.frozen`); LEDs 12 locked, 2 unlocked. While column 8 of row 16 is held on the port (`grid_core.held`), they are `S.lib.freeze.toggle(x)` instead, and their LEDs show the freeze (15 frozen, 3 not). Column 8 itself does nothing but hold; its LED is 15 while held, 4 otherwise. The grid redraws on every press and release, so the row flips back at once.
- Columns 9-15 (voices 1-7), through the local `copy_paste_key(port, voice)`: with no clipboard, copy the voice's pattern (`clipboard = {voice = v, steps = <copy of S.patterns[v]>}`); with one, paste `clipboard.steps` onto the voice, unless it is the copied voice. The clipboard stays for more pastes.
- Column 16: clear the clipboard.

`grid_redraw_256_lock(port, grid_device)`: the copied voice's key 15, the other voice keys and column 16 at 4 while a pattern is copied; columns 9-16 at 2 with none. It works on pages 1, 2 and 4 (page 3 has no row 16).

## Parameter page (page 2)

- Fader page N (row 13, column N) shows entries `(N-1)*4+1 .. N*4` of `fader_param_ids(S.grid_voice_select)` on rows 9-12 (`GRID_LAYOUT.param_page_row`, `fader_rows`, `fader_first_row`; `fader_width` 16 columns). Row 13: fader pages, selected 15, available 4.
- Each fader row is drawn by `grid_redraw_fader_row(grid_device, y, param_id)`; a press calls `set_fader_param()`.
- Row 14 columns 1-7 select the voice (`select_grid_voice`).

## Scene page (page 3)

Keys:
- **Row 1**: scene recall (instant): press to load scene 1-8 at once.
- **Row 2**: scene recall with transition: press to crossfade into scene 1-8.
- **Row 3**: scene save: hold 0.5 s to capture the current state to scene 1-8 (`scene_save_key`; lit at 15 while held). The 128h's row 3 on its page 3 works the same way.
- **Row 5, column 1**: scene sequencer on/off.
- **Row 5, columns 3-10**: sequence length (1-8 scenes).

LEDs:
- Populated scenes: 8 (row 1) or 6 (row 2).
- Current scene: 15 (in row 1).
- Empty scenes: 2.
- Active sequencer: row 5 column 1 at 15 (4 when stopped); row 1 lights the sequencer position (the next scene it recalls) at 10 while it runs. The current scene's 15 wins when they are the same key.
- Sequence length: 8 for included scenes, 2 for excluded.

It follows changes made anywhere (issue #49):
- `recall_scene_instant` sets `S.current_scene` before its closing grid redraw, so an instant recall repaints the grid once with the scene lit;
- `recall_scene` redraws the grid after a smooth recall's start (the fade's first step redraws before `S.current_scene` is set);
- the `scene_sequence_length` action redraws it (PARAMS, CC maps, PSETs);
- `scene_sequencer_start` redraws it as it turns the sequencer on.

## Buffers / FX page (page 4)

`grid_key_256` has an explicit page 4 branch (`page(port) == 4`), so page 4 never falls through to the pattern page.
- Row 1 (`GRID_LAYOUT.buffer_record_row`), columns 1-`NUM_BUFFERS`: `record_key(x)` (`record_buffer`; a second press stops early).
- Row 2 (`GRID_LAYOUT.buffer_clear_row`): `clear_key(x)` (`clear_buffer`).
- `grid_redraw_256_buffers`: row 1 at `record_level` (15 recording, 8 loaded, 2 empty); row 2 at `CLEAR_LEVEL` (4).
- Rows 3-7 (from `GRID_LAYOUT.fx_first_row`): `GRID_LAYOUT.fx_fader_ids = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}` are faders (`set_param_from_column`/`grid_redraw_fader_row`; a bar at 8 up to the value, the value's column at 15).
  - The filter/delay param actions call `fx_fader_changed()` (`lib/params_setup.lua`), which redraws the grids while a 256 shows page 4 (`grid_core.any_fx_faders()`), so the faders follow the screen, the arc and scene recalls.
  - During a smooth scene transition (`S.scene_transition_active`) it does not redraw: the transition loop redraws once per step.
- Rows 9-15 (`GRID_LAYOUT.source_first_row` + voice - 1): column x is `source_key(voice, x)` (1 synth, 2-9 buffer 1-8, 10 input); column 12 (`LAYOUT_256.freeze_column`) is the voice's freeze key, `S.lib.freeze.toggle(voice)` (LED 15 frozen, 3 not). Columns 11 and 13-16 do nothing.
  - The freeze param's action calls `grid_redraw()`, so a freeze from VOICE, MIDI or a scene shows at once.
  - `grid_redraw_256_sources`: `source_level`: the selected source 15, other sources 4, empty buffers (not loaded, not recording) 2.
  - The source param action calls `grid_redraw()`; buffer changes call it through `buffer_display_changed()`.
- Rows 8 and 16 work and draw as on page 1 (`grid_key_256_transport`/`grid_redraw_256_transport`, `grid_key_256_lock`/`grid_redraw_256_lock`).
- Smaller grids have no buffers / FX page: buffers and sources are on the BUFFER screen page and in params.
