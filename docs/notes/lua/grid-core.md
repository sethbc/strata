## Must not break

- Grid handlers live on the vport only (`grid.connect(port)`, through `attach_grid`). Never store the raw device passed to `grid.add`, and never set `key` on it.
- `grid_layout()` matches the exact `cols`/`rows`. Never test `rows >= 16`, which also catches 8×16.
- Anything the grid shows calls `grid_redraw()` when it changes, wherever it changes. It is cheap without a grid.
- Bounds-check every voice, step and grid coordinate before indexing `S.patterns`.
- Faders follow each controlspec's warp (`set_param_from_column`), and a range that spans 0 has a zero column that sets exactly 0.
- Pages are per port (`S.lib.grid_core.page(port)`, `set_page`); a check for a page shown anywhere uses `any_page(n)`. There is no global grid page.
- Held keys are per port: `S.grid_held[port][x][y]` holds the press time while a key is down. `grid_key` clears a key on its release; `grid.remove` and `grid.add` forget the port's held, consumed and step keys and its page; cleanup forgets every port's.
- A delayed key action goes through `on_hold`, never a clock of its own: a new press or the release of the key, `grid.remove` of its port and cleanup cancel its hold clock, so a grid unplugged mid-hold never saves a scene and no clock errors.
- Pattern keys go through `step_key` and scene save keys through `scene_save_key` on every layout, so the step-level gesture and the save hold work the same everywhere.
- Each layout's rules are in its own notes file (`docs/notes/lua/grid/layout_256.md`, `layout_128h.md`, `layout_128v.md`, `layout_64.md`); the pattern sequencer's in `docs/notes/lua/sequencer.md`.

## Owns

- `lib/grid/core.lua` (`S.lib.grid_core`): the device lifecycle and what every layout shares.
  - State on `S`: `S.grids`, `S.MAX_GRID_PORTS`, the grid UI state (`S.grid_pages[port]`, read through `page(port)`; `S.param_page`, `S.grid_voice_select`), the held keys `S.grid_held[port][x][y]` (press time).
  - `GRID_LAYOUT`, exported as `S.lib.grid_core.GRID_LAYOUT`, which `lib/grid/faders.lua` and `lib/grid/layout_256.lua` alias.
  - Global functions: `grid_init`, `select_grid_voice` and the norns entry points `grid_key` and `grid_redraw`. `grid.add`/`grid.remove` are fields of norns' `grid` table. `grid_layout`, `attach_grid` and `forget_port` are locals of the constructor.
  - The shared key helpers on `S.lib.grid_core` (see "Pages, held keys and holds"): `page`, `set_page`, `any_page`, `held`, `on_hold`, `hold_pending`, `consume`, `consumed`, `port_state`, `level_for_position`, `step_key`, `scene_save_key`, `source_key`, `source_level`, `record_key`, `clear_key`, `record_level`, `CLEAR_LEVEL`; `GRID_HOLD` (`lib/constants.lua`).
  - Cleanup step 170: every pending hold canceled and every port's keys forgotten, then every connected grid left dark.
- `lib/grid/faders.lua` (`S.lib.grid_faders`): the fader maths and fader rows (the 256's parameter page and FX faders today): `fader_param_ids`, `fader_page_count`, `fader_zero_column`, `fader_column_fraction`, `set_param_from_column`, `set_fader_param`, `fader_position`, `voice_level_fader_keys`, `grid_redraw_fader_row`, `grid_redraw_faders`. `BUFFER_FADER_KEYS`, `GRAIN_FADER_KEYS` and `append_fader_ids` are local to it.
- Unit tests: `test/unit/grid_core_test.lua` (holds, gestures, pages per port, hot-plug); the faders are exercised through the 256's fader page in `test/unit/grid_layout_256_test.lua`.

Strata supports several grids at once and adapts its layout to each grid's size.

## Device lifecycle

- `grid_init()`: connects up to 4 grid ports at init (start step `START_ORDER.grids`).
- `grid.add(device)`: norns' callback when a grid connects (hot-plug).
- `grid.remove(device)`: norns' callback when a grid disconnects. It clears the vport's `key` handler and the `S.grids` slot, and forgets the port (`forget_port`): its pending holds are canceled, its held, consumed and step keys, its `port_state` and its page are dropped. `grid.add` forgets the port too, so a grid plugged in starts with no held keys, on page 1.
- `S.grids` stores the **vport** (`grid.connect(port)`) of each connected grid, indexed by port (1-4). Both `grid_init` and `grid.add` go through `attach_grid(port)`.
- Why never the raw device: devices have no `.device` field (so `grid_redraw` would skip them), and norns fires both `device.key` and `vports[port].key`, so handlers on both would run every press twice. The arc uses the same vport-only pattern (`attach_arc`).

## Layouts

`grid_layout(grid_port)` matches the exact `cols`/`rows` (16x16 is tested as `cols == 16 and rows == 16`) and names the layout. `grid_key` and `grid_redraw` call that name's record in `S.registry.grid_layouts`. A grid of any other size gets no keys and, between `all(0)` and `refresh()`, no LEDs.
- **16×16 (256 buttons)**: `grid_key_256()` and `grid_redraw_256()`, the full layout (`docs/notes/lua/grid/layout_256.md`).
- **16×8 (128 horizontal)**: `grid_key_128h()` and `grid_redraw_128h()` (`docs/notes/lua/grid/layout_128h.md`).
- **8×16 (128 vertical)**: `grid_key_128v()` and `grid_redraw_128v()` (`docs/notes/lua/grid/layout_128v.md`).
- **8×8 (64 buttons)**: `grid_key_64()` and `grid_redraw_64()`, the compact layout (`docs/notes/lua/grid/layout_64.md`).

To add a layout: a `lib/grid/layout_<name>.lua` that sets `S.registry.grid_layouts["<name>"] = {key = ..., redraw = ...}`, one `include` line in `strata.lua` and the size match in `grid_layout()`.

Several grids:
- Each grid shows and changes its own page; everything else (patterns, voice status, the fader page and voice) is shared.
- `grid_redraw()` iterates over `S.grids` and calls each grid's layout with its port: `redraw(port, grid_device)`.
- Held keys, holds and the step-level gesture are per port: a step held on one grid never sets levels from another.

## Pages, held keys and holds

- `grid_key(port, x, y, z)` ignores events outside the grid's size. A press sets `S.grid_held[port][x][y] = util.time()` (and forgets any earlier state of that key, for a press with no release before it), then calls the layout's `key(port, x, y, 1)`. A release cancels the key's pending hold, calls `key(port, x, y, 0)` unless the key was consumed, then clears the key (held, consumed, step key). Either way it redraws the grid and requests a screen redraw. Layouts return on `z == 0` unless they handle releases.
- `page(port)` is 1 until `set_page(port, page)` (port 1..`MAX_GRID_PORTS`, page 1-4; anything else is ignored). `any_page(page)` is true while a connected grid shows it: `drift_update` (page 2), `fx_fader_changed` and `buffer_state_changed` (page 4) redraw only then.
- `held(port, x, y)`: the press time of a held key, or nil.
- `on_hold(port, x, y, seconds, fn)`: for a held key, a `clock.run` that sleeps `seconds` and runs `fn` once if the hold is still the pending one. A new press or the release of the key, `grid.remove` of the port and cleanup cancel it. `hold_pending(port, x, y)` is true while it waits.
- `consume(port, x, y)` marks a held key so its release does nothing; `consumed` reads it. The mark goes with the release.
- `port_state(port)`: a table for a layout's per-port state, created on demand and dropped when the port's grid is removed.
- **Step level** (`step_key(port, x, y, z, voice, step, position, positions)`): on press, if another step key of the same voice is held on the same port (one pressed through `step_key`, not one that itself set a level), the most recently pressed of them gets `level_for_position(position, positions)` = `max(1, round(position * MAX_STEP_LEVEL / positions))`, and both keys are consumed; the pressed key does not toggle and stays out of the gesture while held. Otherwise the step toggles at press. A voice, step or position out of range (not a whole number in 1..`NUM_VOICES`, 1..`PATTERN_LENGTH`, 1..`positions`) does nothing. `position` runs along the voice's shown steps: the column on 256 and 128h (16 positions) and 64 (8, its column count), the row of the voice's column on 128v (16).
- **Scene save** (`scene_save_key(port, x, y, z, scene)`): a press arms `on_hold` for `GRID_HOLD.scene_save_seconds` (0.5 s); then `capture_scene(scene)`, `grid_redraw()` and `request_redraw()` (SETUP counts the saved scenes). Layouts light the key at 15 while `hold_pending` (4 otherwise). A shorter press saves nothing.
- **Source and slot keys**: `source_key(voice, option)` sets `v<voice>_source` for option 1..`#SOURCE_OPTIONS` (anything else, or a voice outside 1..`NUM_VOICES`, is ignored); `source_level(voice, option)` is 15 for the selected source, 2 for an empty buffer, 4 otherwise. `record_key(slot)`/`clear_key(slot)` call `record_buffer`/`clear_buffer` for slots 1..`NUM_BUFFERS`; `record_level(slot)` is 15 recording, 8 holding audio, 2 empty; `CLEAR_LEVEL` is 4. Out-of-range levels are 0.

## LEDs

- **Active steps**: at their level (15 for steps set by hand).
- **Current playback position** (the sounding step, `S.lib.sequencer.sounding_step()`, the one SEQ draws): 15 if the step is active, 4 if empty (`step_brightness()`).
- **Voice active**: 12. **Voice inactive**: 2-4.
- **Page indicators**: 15 selected, 2 unselected.
- Always call `grid_port:refresh()` after updating LEDs, and `grid_port:all(0)` to clear them before redrawing.
- Any state shown on the grid calls `grid_redraw()` when it changes, wherever it changes (`toggle_voice`, `toggle_lock`, `randomize_voice`, scene recall, ...). `grid_redraw()` returns at once when no grid is connected, so calling it is cheap.
- Parameter faders on grid page 2 are redrawn after `gentle_mutate`, after every scene-transition step, and from `drift_update` only when a grid shows page 2 (it runs 10 times a second).

## Keys

- Every layout acts on presses only today (`z == 0` returns at once); `grid_key` passes releases on so a layout can handle them, and it tracks held keys for holds and two-key gestures (above).
- Grid pages switch between pattern sequencing and parameter control.

## Faders (`lib/grid/faders.lua`)

Which faders:
- `fader_param_ids(voice)` starts with the voice's `param_order` (synthesis params, amp/pan last).
  - For a buffer source it starts instead with `BUFFER_FADER_KEYS` (buf_pos/buf_rate/buf_scan), then `voice_level_fader_keys(voice)`: `amp`, and `pan` for every voice but sub, which has none (the engine pans buffer and input grains).
  - For the input source there are no first keys: the grain params, then `voice_level_fader_keys`.
  - The source action clamps `S.param_page` to the new count.
- Then grain size/density/pitch/spread/envelope/mode, then source/amp mod/freq mod for crossmod slots 1-3.
- Voices have 4-6 fader pages (`fader_page_count`).

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
- Each fader row is drawn by `grid_redraw_fader_row(grid_device, y, param_id)`: a bar at 8 up to the value, the value's column at 15.
