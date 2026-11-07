## Must not break

- Grid handlers live on the vport only (`grid.connect(port)`, through `attach_grid`). Never store the raw device passed to `grid.add`, and never set `key` on it.
- `grid_layout()` matches the exact `cols`/`rows`. Never test `rows >= 16`, which also catches 8×16.
- Pattern steps never create nodes: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)`, a stopped one `toggle_voice`. Never retrigger by toggling a voice off and on.
- Anything the grid shows calls `grid_redraw()` when it changes, wherever it changes. It is cheap without a grid.
- Bounds-check every voice, step and grid coordinate before indexing `S.patterns`.
- The 256's page 4 has an explicit branch in `grid_key_256`, so it never falls through to the pattern page.
- Faders follow each controlspec's warp (`set_param_from_column`), and a range that spans 0 has a zero column that sets exactly 0.
- The pattern clock only syncs (`clock.sync`), so external clock sources keep working. `pattern_clock_start` cancels a running clock before starting a new one.
- Pages are per port (`S.lib.grid_core.page(port)`, `set_page`); a check for a page shown anywhere uses `any_page(n)`. There is no global grid page.
- A delayed key action goes through `on_hold`, never a clock of its own: release, `grid.remove` and cleanup cancel it, so a grid unplugged mid-hold never saves a scene and no clock errors.
- Pattern keys go through `step_key` and scene save keys through `scene_save_key` on every layout, so the step-level gesture and the save hold work the same everywhere.

## Owns

- `lib/grid/core.lua` (`S.lib.grid_core`): the device lifecycle and what every layout shares.
  - State on `S`: `S.grids`, `S.MAX_GRID_PORTS`, the grid UI state (`S.grid_pages[port]`, read through `page(port)`; `S.param_page`, `S.grid_voice_select`), the held keys `S.grid_held[port][x][y]` (press time).
  - `GRID_LAYOUT`, exported as `S.lib.grid_core.GRID_LAYOUT`, which `lib/grid/faders.lua` and `lib/grid/layout_256.lua` alias.
  - Global functions: `grid_init`, `select_grid_voice` and the norns entry points `grid_key` and `grid_redraw`. `grid.add`/`grid.remove` are fields of norns' `grid` table. `grid_layout`, `attach_grid` and `forget_port` are locals of the constructor.
  - The shared key helpers on `S.lib.grid_core` (see "Pages, held keys and holds"): `page`, `set_page`, `any_page`, `held`, `on_hold`, `hold_pending`, `consume`, `consumed`, `port_state`, `level_for_position`, `step_key`, `scene_save_key`, `source_key`, `source_level`, `record_key`, `clear_key`, `record_level`, `CLEAR_LEVEL`.
  - Cleanup step 170: every pending hold canceled and every port's keys forgotten, then every connected grid left dark.
- `lib/grid/faders.lua` (`S.lib.grid_faders`): the 256's fader maths and fader rows: `fader_param_ids`, `fader_page_count`, `fader_zero_column`, `fader_column_fraction`, `set_param_from_column`, `set_fader_param`, `fader_position`, `voice_level_fader_keys`, `grid_redraw_fader_row`, `grid_redraw_faders`. `BUFFER_FADER_KEYS`, `GRAIN_FADER_KEYS` and `append_fader_ids` are local to it.
- `lib/grid/layout_256.lua` (the 256's four pages), `lib/grid/layout_128h.lua`, `lib/grid/layout_128v.lua`, `lib/grid/layout_64.lua` (`S.lib.grid_layout_256`, ...): one layout each. Each defines its global key and redraw functions and registers `S.registry.grid_layouts["256"|"128h"|"128v"|"64"] = {key = ..., redraw = ...}`.
- `lib/sequencer.lua` (`S.lib.sequencer`):
  - `S.patterns` (built fresh by its constructor), the pattern clock state (`S.pattern_position`, `S.pattern_playing`, `S.pattern_clock`);
  - `toggle_pattern_step`, `clear_pattern`, `randomize_pattern`, `pattern_toggle`, `pattern_clock_start`, `pattern_clock_stop`, `step_brightness`;
  - cleanup step 90: the pattern clock stopped.

Strata supports several grids at once and adapts its layout to each grid's size.

## Device lifecycle

- `grid_init()`: connects up to 4 grid ports at init (start step `START_ORDER.grids`).
- `grid.add(device)`: norns' callback when a grid connects (hot-plug).
- `grid.remove(device)`: norns' callback when a grid disconnects. It clears the vport's `key` handler and the `S.grids` slot, and forgets the port (`forget_port`): its pending holds are canceled, its held, consumed and step keys, its `port_state` and its page are dropped. `grid.add` forgets the port too, so a grid plugged in starts with no held keys, on page 1.
- `S.grids` stores the **vport** (`grid.connect(port)`) of each connected grid, indexed by port (1-4). Both `grid_init` and `grid.add` go through `attach_grid(port)`.
- Why never the raw device: devices have no `.device` field (so `grid_redraw` would skip them), and norns fires both `device.key` and `vports[port].key`, so handlers on both would run every press twice. The arc uses the same vport-only pattern (`attach_arc`).

## Layouts

`grid_layout(grid_port)` matches the exact `cols`/`rows` (16x16 is tested as `cols == 16 and rows == 16`) and names the layout. `grid_key` and `grid_redraw` call that name's record in `S.registry.grid_layouts`. A grid of any other size gets no keys and, between `all(0)` and `refresh()`, no LEDs.
- **16×16 (256 buttons)**: `grid_key_256()` and `grid_redraw_256()`, the full layout.
- **16×8 (128 horizontal)**: `grid_key_128h()` and `grid_redraw_128h()`.
- **8×16 (128 vertical)**: `grid_key_128v()` and `grid_redraw_128v()`.
- **8×8 (64 buttons)**: `grid_key_64()` and `grid_redraw_64()`, the compact layout.

Several grids:
- Each grid shows and changes its own page; everything else (patterns, voice status, the fader page and voice) is shared.
- `grid_redraw()` iterates over `S.grids` and calls each grid's layout with its port: `redraw(port, grid_device)`.
- Held keys, holds and the step-level gesture are per port: a step held on one grid never sets levels from another.

## Pages, held keys and holds

- `grid_key(port, x, y, z)` ignores events outside the grid's size. A press sets `S.grid_held[port][x][y] = util.time()` (and forgets any earlier state of that key, for a press with no release before it), then calls the layout's `key(port, x, y, 1)`. A release cancels the key's pending hold, calls `key(port, x, y, 0)` unless the key was consumed, then clears the key (held, consumed, step key). Either way it redraws the grid and requests a screen redraw. Layouts return on `z == 0` unless they handle releases.
- `page(port)` is 1 until `set_page(port, page)` (port 1..`MAX_GRID_PORTS`, page 1-4; anything else is ignored). `any_page(page)` is true while a connected grid shows it: `drift_update` (page 2), `fx_fader_changed` and `buffer_state_changed` (page 4) redraw only then.
- `on_hold(port, x, y, seconds, fn)`: for a held key, a `clock.run` that sleeps `seconds` and runs `fn` once if the hold is still the pending one. A new press or the release of the key, `grid.remove` of the port and cleanup cancel it. `hold_pending(port, x, y)` is true while it waits.
- `consume(port, x, y)` marks a held key so its release does nothing; `consumed` reads it. The mark goes with the release.
- `port_state(port)`: a table for a layout's per-port state, created on demand and dropped when the port's grid is removed.
- **Step level** (`step_key(port, x, y, z, voice, step, position, positions)`): on press, if another step key of the same voice is held on the same port (one pressed through `step_key`, not one that itself set a level), the most recently pressed of them gets `level_for_position(position, positions)` = `max(1, round(position * MAX_STEP_LEVEL / positions))`, and both keys are consumed; the pressed key does not toggle and stays out of the gesture while held. Otherwise the step toggles at press. `position` runs along the voice's shown steps: the column on 256 and 128h (16 positions) and 64 (8, its column count), the row of the voice's column on 128v (16).
- **Scene save** (`scene_save_key(port, x, y, z, scene)`): a press arms `on_hold` for `GRID_HOLD.scene_save_seconds` (0.5 s); then `capture_scene(scene)` and `grid_redraw()`. Layouts light the key at 15 while `hold_pending` (4 otherwise). A shorter press saves nothing.
- **Source and slot keys**: `source_key(voice, option)` sets `v<voice>_source` for option 1..`#SOURCE_OPTIONS` (anything else, or a voice outside 1..`NUM_VOICES`, is ignored); `source_level(voice, option)` is 15 for the selected source, 2 for an empty buffer, 4 otherwise. `record_key(slot)`/`clear_key(slot)` call `record_buffer`/`clear_buffer` for slots 1..`NUM_BUFFERS`; `record_level(slot)` is 15 recording, 8 holding audio, 2 empty; `CLEAR_LEVEL` is 4. Out-of-range levels are 0.

## Pattern sequencer

- **Storage**: `S.patterns[voice_idx][step]`, `NUM_VOICES` × `PATTERN_LENGTH` steps, values 0-15. The 64 grid shows and edits only steps 1-8, but patterns still play all 16.
- **Playback clock**: `S.pattern_clock` uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes against norns' global clock. The `tempo` param and the tempo handler are in `docs/notes/lua/params.md`. External clock sources still work because the sequencer only syncs.
- **Position**: `S.pattern_position` is the current step (1-16) and wraps around. Each tick triggers the step, redraws the grid (so the highlight shows the step that just played), then advances.
- **Triggering**: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)` (an accent in place at the step's level as velocity, one grain in triggered grain mode, no new nodes). A stopped voice is started with `toggle_voice`. Voices start automatically when a step triggers them.
- **Operations**:
  - `toggle_pattern_step(voice, step)`: toggle a step on or off;
  - `clear_pattern(voice)`: reset all steps to 0;
  - `randomize_pattern(voice)`: a random pattern at 50% density.
- Cleanup stops the pattern clock, so no clock coroutine is left behind.

Bounds check before indexing:

```lua
function toggle_pattern_step(voice_idx, step)
  -- bounds checks keep the table from growing
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  -- safe to access
  S.patterns[voice_idx][step] = ...
end
```

## LEDs

- **Active steps**: 15 (full).
- **Current playback position**: 15 if the step is active, 4 if empty (`step_brightness()`).
- **Voice active**: 12. **Voice inactive**: 2-4.
- **Page indicators**: 15 selected, 2 unselected.
- **256 parameter page faders (rows 9-12) and FX faders (page 4, rows 3-7)**: a bar at 8 up to the value, the value's column at 15. Row 13 (page 2): fader pages, selected 15, available 4.
- **256 page 4 buffers**: row 1 at 15 recording / 8 loaded / 2 empty, row 2 at 4. Source rows 9-15: selected 15, others 4, empty buffers 2.
- Always call `grid_port:refresh()` after updating LEDs, and `grid_port:all(0)` to clear them before redrawing.
- Any state shown on the grid calls `grid_redraw()` when it changes, wherever it changes (`toggle_voice`, `toggle_freeze`, `randomize_voice`, scene recall, ...). `grid_redraw()` returns at once when no grid is connected, so calling it is cheap.
- Parameter faders on grid page 2 are redrawn after `gentle_mutate`, after every scene-transition step, and from `drift_update` only when a grid shows page 2 (it runs 10 times a second).

## Keys

- Every layout acts on presses only today (`z == 0` returns at once); `grid_key` passes releases on so a layout can handle them, and it tracks held keys for holds and two-key gestures (above).
- Grid pages switch between pattern sequencing and parameter control.

## 256 parameter page (page 2)

Which faders:
- `fader_param_ids(voice)` starts with the voice's `param_order` (synthesis params, amp/pan last).
  - For a buffer source it starts instead with `BUFFER_FADER_KEYS` (buf_pos/buf_rate/buf_scan), then `voice_level_fader_keys(voice)`: `amp`, and `pan` for every voice but sub, which has none (the engine pans buffer and input grains).
  - For the input source there are no first keys: the grain params, then `voice_level_fader_keys`.
  - The source action clamps `S.param_page` to the new count.
- Then grain size/density/pitch/spread/envelope/mode, then source/amp mod/freq mod for crossmod slots 1-3.
- Voices have 4-6 fader pages.

Layout:
- Fader page N (row 13, column N) shows entries `(N-1)*4+1 .. N*4` on rows 9-12 (`GRID_LAYOUT.param_page_row`, `fader_rows`, `fader_first_row`; `fader_width` 16 columns).
- Each fader row is drawn by `grid_redraw_fader_row(grid_device, y, param_id)`.

Setting a value:
- Pressing column x calls `set_fader_param()`, which looks up the id and calls `set_param_from_column(param_id, x)`.
- Control params: `spec:map(fader_column_fraction(id, x))`, so faders follow each controlspec's warp (exp for freq, cutoff, mod speed).
- Number params (mod sources) and option params (grain envelope and mode; `param_range` gives `1, count`): `round(util.linlin(0, 1, min, max, fraction))`. It tests `param.options`, because norns' `param.t` is a number.
- Everything goes through `params:set`.

Columns:
- `fader_column_fraction` is `(x - 1) / 15`, except for a range that spans 0 (pan, `buf_scan`, the crossmod amounts; issue #49). 16 columns have no center, so the plain sweep gives ±0.07 for pan there and never 0.
- Such a fader has a zero column (`fader_zero_column(id)`: the column nearest `param_value_fraction(id, 0)`, clamped to 2-15; column 9 for the symmetric ranges), which sets exactly 0.
- Each side of the zero column sweeps its part of the range (in the warp's terms) evenly over its own columns, so column 1 is still the minimum and column 16 the maximum.
- `fader_position()` is the inverse: `param_fraction(id) * 15 + 1`, piecewise around a zero column, so 0 shows there. `param_fraction` is `param_value_fraction(id, params:get(id))`: `spec:unmap(value)`, or the linear fraction of a number or option param's range.

## 256 scene page (page 3)

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
- Active sequencer: 15, and the next scene position is shown.
- Sequence length: 8 for included scenes, 2 for excluded.

It follows changes made anywhere (issue #49):
- `recall_scene_instant` sets `S.current_scene` before its closing grid redraw, so an instant recall repaints the grid once with the scene lit;
- `recall_scene` redraws the grid after a smooth recall's start (the fade's first step redraws before `S.current_scene` is set);
- the `scene_sequence_length` action redraws it (PARAMS, CC maps, PSETs);
- `scene_sequencer_start` redraws it as it turns the sequencer on.

## 256 buffers / FX page (page 4)

`grid_key_256` has an explicit page 4 branch (`page(port) == 4`), so page 4 never falls through to the pattern page.
- Row 1 (`GRID_LAYOUT.buffer_record_row`), columns 1-`NUM_BUFFERS`: `record_key(x)` (`record_buffer`; a second press stops early).
- Row 2 (`GRID_LAYOUT.buffer_clear_row`): `clear_key(x)` (`clear_buffer`).
- `grid_redraw_256_buffers`: row 1 at `record_level` (15 recording, 8 loaded, 2 empty); row 2 at `CLEAR_LEVEL` (4).
- Rows 3-7 (from `GRID_LAYOUT.fx_first_row`): `GRID_LAYOUT.fx_fader_ids = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}` are faders (`set_param_from_column`/`grid_redraw_fader_row`).
  - The filter/delay param actions call `fx_fader_changed()` (`lib/params_setup.lua`), which redraws the grid while page 4 is shown, so the faders follow the screen, the arc and scene recalls.
  - During a smooth scene transition (`S.scene_transition_active`) it does not redraw: the transition loop redraws once per step.
- Rows 9-15 (`GRID_LAYOUT.source_first_row` + voice - 1): column x is `source_key(voice, x)` (1 synth, 2-9 buffer 1-8, 10 input). Columns 11-16 do nothing.
  - `grid_redraw_256_sources`: `source_level`: the selected source 15, other sources 4, empty buffers (not loaded, not recording) 2.
  - The source param action calls `grid_redraw()`; buffer changes call it through `buffer_display_changed()`.
- Rows 8 and 16 work and draw as on page 1 (`grid_key_256_transport`/`grid_redraw_256_transport`, `grid_key_256_freeze`/`grid_redraw_256_freeze`).
- Smaller grids have no buffers / FX page: buffers and sources are on the BUFFER screen page and in params.
