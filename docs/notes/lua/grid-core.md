## Must not break

- Grid handlers live on the vport only (`grid.connect(port)`, through `attach_grid`). Never store the raw device passed to `grid.add`, and never set `key` on it.
- `grid_layout()` matches the exact `cols`/`rows`. Never test `rows >= 16`, which also catches 8×16.
- Anything the grid shows calls `grid_redraw()` when it changes, wherever it changes. It is cheap without a grid.
- A grid key repaints each grid once (#161): while `grid_key` handles a key, `grid_redraw()` calls from its actions return at once, and `grid_key` paints when the handler returns. The handler runs in an `xpcall`, so a failing key still repaints, the hold on redraws always ends, and the error is raised after the repaint.
- A layout's redraw runs contained (#441): `grid_redraw` calls each grid's `layout.redraw` through `S.lib.ui_frame.contained_call` (keyed by the layout's name), so a failing layout prints its traceback once per distinct message, its grid is still refreshed, the grids after it are drawn, and whoever asked for the redraw (`toggle_voice`, a param action, the pattern clock, a poll, the drift tick, a key) is never raised into.
- The faders pages follow every param they show (#324): the drift tick (`drift_update`, 10 Hz) calls `S.lib.grid_faders.follow_faders()`, which redraws the grids while one shows page 2 only when `faders_signature()` (the grid voice, `S.param_page`, the page count and the four shown faders' columns) differs from its last look, so a param set on the screen, the arc, a MIDI map or in PARAMETERS reaches the faders within a tick and idle ticks repaint nothing. Never go back to a redraw on every tick.
- A port's rotation (#323) is applied at every attach (`attach_grid`: `grid_port:rotation(n)`, norns' `Grid:rotation`, which reads the grid's rows and cols again and updates the vport) and changes only through `set_rotation`, which writes `grids.data` first (a failed write sets nothing) and then turns the grid and forgets the port. A grid whose size changes under an attached port with no add or remove (a rotation made outside Strata) starts over too (`follow_size`, before a key and before each redraw). `grids.data` is read through `S.lib.data_files.read` (parsed, never run) and written through `write`.
- The key levels every layout shares come from the core (#526, #452): `voice_level`, `lock_level`, `play_level`, `M.LEVELS` (`S.constants.GRID_LEVELS`: the page and pick pairs), `scene_recall_level`, `scene_fade_level`, `scene_save_level` and `S.lib.grid_faders.fader_page_level`. A layout never works out one of these levels itself, so one state lights alike on every grid.
- A grid page outside `lib/grid/` is named (`S.constants.GRID_PAGES`: `patterns`, `faders`, `scenes`, `sources`, `positions`, `count`, and `position_cells`, the 16 cells of a position row on every layout), never a bare number (#451; `grid_core_test.lua` refuses `any_page(<digit>` outside `lib/grid/`).
- Bounds-check every voice, step and grid coordinate before indexing `S.patterns`.
- Faders follow each controlspec's warp (`set_param_from_column`), and a range that spans 0 has a zero column that sets exactly 0.
- Pages are per port (`S.lib.grid_core.page(port)`, `set_page`); a check for a page shown anywhere uses `any_page(n)`, and one for the FX faders `any_fx_faders()` (page 4 is FX only on the 256). There is no global grid page.
- Held keys are per port: `S.grid_held[port][x][y]` holds the press time while a key is down. `grid_key` clears a key on its release; `grid.remove` and `grid.add` forget the port's held, consumed and step keys and its page; cleanup forgets every port's.
- Cleanup leaves nothing of Strata's on the devices (#468): the grids' step clears every attached vport's `key` before darkening it and sets `grid.add` and `grid.remove` to no-ops (the arc's and MIDI's steps do the same for theirs), since norns' SLEEP runs only `cleanup()` before it shuts down, so a key pressed meanwhile would start a voice after the voices went off.
- A delayed key action goes through `on_hold`, never a clock of its own: a new press or the release of the key, `grid.remove` of its port and cleanup cancel its hold clock, so a grid unplugged mid-hold never saves a scene and no clock errors.
- A grid moved to another port in SYSTEM > DEVICES gets no `grid.add` or `grid.remove` (norns' menu calls `update_devices()` only, `lua/core/menu/devices.lua`), so `reconcile_ports()` runs as the norns menu closes (a `S.register_menu_close` hook) and brings `S.grids` back in line with the vports (#256).
- Pattern keys go through `step_key` and scene save keys through `scene_save_key` on every layout, so the step-level gesture and the save hold work the same everywhere.
- Every whole-pattern change ends the voice's step gestures (`end_step_gestures`, run by `S.lib.sequencer.replace_pattern`), and a 64's half switch ends its port's (`end_port_step_gestures`), so a held step never takes a level in a pattern or half it was not pressed in (#242).
- Each layout's rules are in its own notes file (`docs/notes/lua/grid/layout_256.md`, `layout_128h.md`, `layout_128v.md`, `layout_64.md`); the pattern sequencer's in `docs/notes/lua/sequencer.md`.

## Owns

- `lib/grid/core.lua` (`S.lib.grid_core`): the device lifecycle and what every layout shares.
  - State on `S`: `S.grids`, `S.MAX_GRID_PORTS`, the grid UI state (`S.grid_pages[port]`, read through `page(port)`; `S.param_page`, `S.grid_voice_select`), the held keys `S.grid_held[port][x][y]` (press time).
  - `GRID_LAYOUT`, exported as `S.lib.grid_core.GRID_LAYOUT`, which `lib/grid/faders.lua` and `lib/grid/layout_256.lua` alias.
  - Global functions: `grid_init`, `select_grid_voice` and the norns entry points `grid_key` and `grid_redraw`. `grid.add`/`grid.remove` are fields of norns' `grid` table. `grid_layout`, `attach_grid`, `attached_devices` and `forget_port` are locals of the constructor.
  - The shared key helpers on `S.lib.grid_core` (see "Pages, held keys and holds"): `page`, `set_page`, `any_page`, `held`, `on_hold`, `hold_pending`, `consume`, `consumed`, `port_state`, `existing_port_state`, `level_for_position`, `step_key`, `end_step_gestures`, `end_port_step_gestures`, `layout_of`, `any_fx_faders`, `reconcile_ports`, `scene_save_key`, `source_key`, `source_level`, `record_key`, `clear_key`, `record_level`, `CLEAR_LEVEL`; `GRID_HOLD` (`lib/constants.lua`).
  - The shared levels (see "LEDs"): `LEVELS` (`S.constants.GRID_LEVELS`), `voice_level`, `lock_level`, `play_level`, `scene_recall_level`, `scene_fade_level`, `scene_save_level`.
  - The rotation setting (see "Rotation"): `rotation`, `set_rotation`, `MAX_ROTATION`; the locals `GRID_ROTATION`, `read_rotations`, `apply_rotation`, `follow_size`.
  - Cleanup step 170: every pending hold canceled and every port's keys forgotten, every attached vport's key handler cleared and its grid left dark, `grid.add` and `grid.remove` set to no-ops.
- `lib/grid/faders.lua` (`S.lib.grid_faders`): the fader maths and fader rows, which the 256 (its parameter page and FX faders), the 16x8 and the 8x16 (their faders pages) draw and set alike: `fader_param_ids`, `fader_page_count`, `fader_zero_column`, `fader_column_fraction`, `set_param_from_column`, `set_fader_param`, `fader_position`, `voice_level_fader_keys`, `grid_redraw_fader_row`, `grid_redraw_faders`; on the module `fader_page_level`, `faders_signature` and `follow_faders`. `BUFFER_FADER_KEYS`, `GRAIN_FADER_KEYS`, `append_fader_ids` and `shown_faders` are local to it.
- Unit tests: `test/unit/grid_core_test.lua` (holds, gestures, pages per port, hot-plug, a grid moved in SYSTEM > DEVICES, the guards, the shared levels, the contained redraw, the faders' tick, the rotation, cleanup); the fader maths are exercised through the 256's fader page in `test/unit/grid_layout_256_test.lua`.

Strata supports several grids at once and adapts its layout to each grid's size.

## Device lifecycle

- `grid_init()`: reads `grids.data` (the rotations), then connects up to 4 grid ports at init (start step `START_ORDER.grids`).
- `grid.add(device)`: norns' callback when a grid connects (hot-plug).
- `grid_key(port, x, y, z)`: norns' key callback (on the vport). It ignores a port with no grid and a key outside the grid, runs the press or release through the layout (`handle_key`) with `grid_redraw()` held (`key_repaint.handling`), then repaints every grid once and requests a screen redraw.
- `grid.remove(device)`: norns' callback when a grid disconnects. It clears the vport's `key` handler and the `S.grids` slot, and forgets the port (`forget_port`): its pending holds are canceled, its held, consumed and step keys, its `port_state` and its page are dropped. `grid.add` forgets the port too, so a grid plugged in starts with no held keys, on page 1.
- `S.grids` stores the **vport** (`grid.connect(port)`) of each connected grid, indexed by port (1-4). `grid_init`, `grid.add` and `reconcile_ports` go through `attach_grid(port)`, which also records the device the vport holds then (`attached_devices[port]`) and turns the grid to the port's rotation (`apply_rotation`, which notes the size it then reports).
- `S.lib.grid_core.reconcile_ports()`: SYSTEM > DEVICES moves a grid between ports through norns' `update_devices()` alone, which rewrites the vports' `device`, `cols` and `rows` and the device's `port` but calls neither `grid.add` nor `grid.remove`. So, as the norns menu closes (registered with `S.register_menu_close`), for each port 1..`S.MAX_GRID_PORTS`: a vport holding a device that is not attached, or another device than `attached_devices[port]`, is forgotten and attached, as `grid.add` does; an attached port whose vport is empty loses its `key` handler and its `S.grids` slot and is forgotten, as `grid.remove` does. Then `grid_redraw()` and `request_redraw()` (SETUP counts the grids). A grid moved from port 1 to 2 thus starts on port 2 with no held keys, on page 1, and port 1 is no longer drawn.
- Why never the raw device: devices have no `.device` field (so `grid_redraw` would skip them), and norns fires both `device.key` and `vports[port].key`, so handlers on both would run every press twice. The arc uses the same vport-only pattern (`attach_arc`).

## Rotation

A monome 128 reports 16x8 (norns' matron reads its rows and cols once, at connect) until a script turns it: `Grid:rotation(n)` (`lua/core/grid.lua`) sets the rotation, reads rows and cols again and runs `update_devices()`, which copies them to the vport, so `grid_layout()` sees 8x16 with no change of its own. `grid.cleanup()` leaves a rotation in place, so a grid can arrive turned by an earlier script.

- `GRID_ROTATION` (local): `file` `grids.data` in `_path.data .. "strata/"`, `version` 1, `last` 3, `settings[port]` (nil reads as 0) and `sizes[port]`. The file holds `{version = 1, rotation = {r1, r2, r3, r4}}` in `tab.save`'s layout (`S.lib.data_files.encode`).
- `read_rotations()` (from `grid_init`, before any port is attached): a version-1 table's whole numbers 0-3 are the settings; any other entry, a missing file, one that does not parse or another version reads as 0 (an unusable file is named on the console and replaced at the next change).
- `rotation(port)`: 0-3. `set_rotation(port, n)`: false for a port outside 1..`S.MAX_GRID_PORTS` or `n` not a whole number 0-`MAX_ROTATION`; true at once when unchanged; else the four settings go to `S.lib.data_files.write` (the folder made first), false when it fails (nothing changes); then the setting is kept, a grid on the port is forgotten (`forget_port`) and turned (`apply_rotation`), and `grid_redraw()` and `request_redraw()` run. SETUP's rotation fields call it (`docs/notes/lua/pages/setup.md`).
- `follow_size(port, grid_port)`: when the grid's `cols`x`rows` is not `sizes[port]` (a rotation made outside Strata, or a grid moved in SYSTEM > DEVICES before the menu closes), the port is forgotten and the new size noted. `grid_key` runs it before the bounds check, `grid_redraw` before each grid's draw. `grid.remove` and `reconcile_ports`' detach clear `sizes[port]`.

## Layouts

`grid_layout(grid_port)` matches the exact `cols`/`rows` (16x16 is tested as `cols == 16 and rows == 16`) and names the layout. `grid_key` and `grid_redraw` call that name's record in `S.registry.grid_layouts`. A grid of any other size gets no keys and, between `all(0)` and `refresh()`, no LEDs.
- **16×16 (256 buttons)**: `grid_key_256()` and `grid_redraw_256()`, the full layout (`docs/notes/lua/grid/layout_256.md`).
- **16×8 (128 horizontal)**: `grid_key_128h()` and `grid_redraw_128h()` (`docs/notes/lua/grid/layout_128h.md`).
- **8×16 (128 vertical)**: `grid_key_128v()` and `grid_redraw_128v()` (`docs/notes/lua/grid/layout_128v.md`).
- **8×8 (64 buttons)**: `grid_key_64()` and `grid_redraw_64()`, the compact layout (`docs/notes/lua/grid/layout_64.md`).

To add a layout: a `lib/grid/layout_<name>.lua` that sets `S.registry.grid_layouts["<name>"] = {key = ..., redraw = ...}` (plus `fx_faders_page = <page>` if a page shows the FX faders; only the 256 has one, page 4; and `selects_grid_voice = true` if a position press selects the grid voice and the layout has one bookmark strip, for the grid voice: the 128h, 128v and 64, never the 256), one `include` line in `strata.lua` and the size match in `grid_layout()`.

Several grids:
- Each grid shows and changes its own page; everything else (patterns, voice status, the fader page and voice) is shared.
- `grid_redraw()` iterates over `S.grids` and calls each grid's layout with its port: `redraw(port, grid_device)`.
- Held keys, holds and the step-level gesture are per port: a step held on one grid never sets levels from another.

## Pages, held keys and holds

- `grid_key(port, x, y, z)` ignores events outside the grid's size. A press sets `S.grid_held[port][x][y] = util.time()` (and forgets any earlier state of that key, for a press with no release before it), then calls the layout's `key(port, x, y, 1)`. A release cancels the key's pending hold, calls `key(port, x, y, 0)` unless the key was consumed, then clears the key (held, consumed, step key). Either way it redraws the grid and requests a screen redraw. Layouts return on `z == 0` unless they handle releases.
- `page(port)` is 1 until `set_page(port, page)` (port 1..`MAX_GRID_PORTS`, page 1-5 (`MAX_GRID_PAGES`, `S.constants.GRID_PAGES.count`; every layout numbers its pages alike, `GRID_PAGES`: 1 patterns, 2 faders, 3 scenes, 4 sources and buffers, 5 positions; the 64 shows 1 and 5); anything else is ignored). `any_page(page)` is true while a connected grid shows it: `follow_faders` (page 2, the drift tick), `buffer_state_changed` (page 4) and the waveforms' peaks read (page 5) redraw only then. `layout_of(port)` is the layout record of the grid connected to the port (nil for no grid or a size with no layout); `S.lib.positions` reads its `selects_grid_voice`. `any_fx_faders()` is true while a connected grid shows its layout record's `fx_faders_page` (a 256 on page 4; the 16x8's and 8x16's page 4 show no FX): `fx_fader_changed` redraws only then.
- `held(port, x, y)`: the press time of a held key, or nil.
- `on_hold(port, x, y, seconds, fn)`: for a held key, a `clock.run` that sleeps `seconds` and runs `fn` once if the hold is still the pending one. A new press or the release of the key, `grid.remove` of the port and cleanup cancel it. `hold_pending(port, x, y)` is true while it waits.
- `consume(port, x, y)` marks a held key so its release does nothing; `consumed` reads it. The mark goes with the release.
- `port_state(port)`: a table for a layout's per-port state, created on demand and dropped when the port's grid is removed. `existing_port_state(port)` returns that table, or nil when the port has none, and never creates one: an invariant, or a check on a port whose grid may have left, reads through it.
- **Step level** (`step_key(port, x, y, z, voice, step, position, positions)`): on press, if the voice has a held step on the same port (a key pressed through `step_key` that toggled its step, not one that set a level), that step gets `level_for_position(position, positions)` = `max(1, round(position * MAX_STEP_LEVEL / positions))`, and both keys are consumed; the pressed key does not toggle and is a level key while held, never taking a level itself. Otherwise the step toggles at press and the key becomes the voice's held step. So a voice has at most one held step on a port (#450): every further key of the voice sets that step's level for as long as it stays down (`held_step` finds it). `end_step_gestures(voice)` ends the gesture on that voice's held step keys on every port (they stay held; the next step key of the voice toggles its own step): `S.lib.sequencer.replace_pattern` calls it, so a step held from before a clear, a randomize, a 256's paste or a scene recall never takes a level in the new pattern. `end_port_step_gestures(port)` forgets every step key of one port, whatever the voice (the keys stay held; their releases do nothing; a port that is not a whole number in 1..`S.MAX_GRID_PORTS` does nothing): the 64's half switch calls it, so a step held in the half it leaves never takes a level. A voice, step or position out of range (not a whole number in 1..`NUM_VOICES`, 1..`PATTERN_LENGTH`, 1..`positions`) does nothing. `position` runs along the voice's shown steps: the column on 256 and 128h (16 positions) and 64 (8, its column count), the row of the voice's column on 128v (16).
- **Scene save** (`scene_save_key(port, x, y, z, scene)`): a press arms `on_hold` for `GRID_HOLD.scene_save_seconds` (0.5 s); then `S.lib.scenes.save(scene)`, which captures the scene, redraws and flashes `saved S<n>` in the header. Layouts light the key at 15 while `hold_pending` (4 otherwise). A shorter press saves nothing.
- **Source and slot keys**: `source_key(voice, option)` sets `v<voice>_source` for option 1..`#SOURCE_OPTIONS` (anything else, or a voice outside 1..`NUM_VOICES`, is ignored); `source_level(voice, option)` is 15 for the selected source, 2 for a free buffer (`S.lib.buffers.is_free(slot)`: status `"empty"` or `"missing"`, the answer the fill and BUFFER share; a named load the engine has not reported yet is 4, #247), 4 otherwise. `record_key(slot)`/`clear_key(slot)` call `record_buffer`/`clear_buffer` for slots 1..`NUM_BUFFERS`; `record_level(slot)` reads the slot's `S.lib.buffers.status`, so both keys give one answer: 11 `"armed"`, 15 `"recording"`, `"dub"`, `"loop"` and `"finishing"` (an armed replace take stopped with K3 is 15 until its canceled report), 2 when `is_free`, else 8 (loading, loaded, or a named load the engine has not reported yet, #247); `CLEAR_LEVEL` is 4. Out-of-range levels are 0.

## States: the step-level gesture

The gesture's state is `step_keys[port][x][y]` (local to `lib/grid/core.lua`): `{voice, step, level_key}` for a key pressed through `step_key` and still held, alongside `S.grid_held[port][x][y]` (the press time). It registers no invariant.

| State of a key | Fields | Meaning |
|----------------|--------|---------|
| Not a step key | `step_keys[port][x][y]` nil | Not held, or held but outside the gesture (ended, or pressed through no `step_key`); a step key of its voice pressed now toggles its own step |
| Held step | entry with `level_key` nil, `S.grid_held[port][x][y]` set | At most one per voice on a port; it takes the level of every further step key of that voice on that port |
| Level key | entry with `level_key = true` (and consumed) | Set a held step's level; never takes a level itself |

An entry exists only while its key is held (every release and press clears it). One function per transition:

| Transition | Function |
|------------|----------|
| A step key pressed: the voice's held step, or a level key that sets the held step's level | `step_key` |
| A key released, or pressed again with no release seen | `release_key`, `press_key` |
| The voice's pattern replaced: its entries on every port forgotten | `end_step_gestures(voice)`, from `S.lib.sequencer.replace_pattern` |
| A 64's half switch: the port's entries forgotten | `end_port_step_gestures(port)` |
| The port's grid added or removed (also through `reconcile_ports` as the menu closes), cleanup | `forget_port` |

## States: the attached ports

A port's attachment is `S.grids[port]` (the vport, or nil) with `attached_devices[port]` (the device it held when attached), against what the vport holds now (`grid.connect(port).device`). The `attached_devices[port]` entry exists exactly while the port is attached: `attach_grid` sets it, `grid.remove` and `reconcile_ports`' detach clear it, and the `"grid keys"` invariant checks it. Nothing checks the vports against the attachment: they change under the script, inside norns' menu, so the two disagree while the menu is open.

| State of a port | Fields | Meaning |
|-----------------|--------|---------|
| Not attached | `S.grids[port]` nil, `attached_devices[port]` nil | No key handler from Strata; not drawn, not counted on SETUP |
| Attached | `S.grids[port]` the vport, `attached_devices[port]` its device | Keys reach `grid_key`; drawn and counted while the vport holds a device |
| Stale (menu open, or before the menu closes) | the vport's device is not `attached_devices[port]`, or it holds a device and `S.grids[port]` is nil | Set right by `reconcile_ports` as the menu closes |

| Transition | Function |
|------------|----------|
| Attach (init, hot-plug, the menu closing) | `attach_grid`, from `grid_init`, `grid.add`, `reconcile_ports` |
| Detach (unplug, the menu closing) | `grid.remove`, `reconcile_ports` |

## LEDs

- **Active steps**: at their level (15 for steps set by hand).
- **Current playback position** (the sounding step, `S.lib.sequencer.sounding_step()`, the one SEQ draws): 15 if the step is active, 4 if empty (`step_brightness()`).
- The levels every layout shares (#526), `S.constants.GRID_LEVELS` (`M.LEVELS`): a voice's on/off key 12 running, 2 stopped (`voice_level`); a page key 15 shown, 2 other; a pick key (the grid voice's, a fader page's: `S.lib.grid_faders.fader_page_level`) 15 picked, 4 not; a lock key 12 locked, 2 not (`lock_level`); the play keys 15 playing, 4 stopped (`play_level`). Keys of a kind of their own keep their own levels: the 8x16's page key (3-15 by page), the 16x8's sources key on page 5 (10), its voice cycle key (8), the 64's play key and position-view voice row.
- The scene keys (#452): a recall key 8 saved, 2 empty, 10 the slot the running sequencer recalls next (`S.lib.scenes.sequencer_next_slot()`, #303; empty slots skipped, #513), 15 the current scene, which wins (`S.lib.scenes.shows_current`: the scene a fade goes to blinks, #254) (`scene_recall_level(slot)`); a fade key 6 saved, 2 empty (`scene_fade_level`); a save key 15 while its hold is pending, 4 otherwise (`scene_save_level(port, x, y)`). A slot outside 1..`NUM_SCENES` is 0.
- Always call `grid_port:refresh()` after updating LEDs, and `grid_port:all(0)` to clear them before redrawing.
- Any state shown on the grid calls `grid_redraw()` when it changes, wherever it changes (`toggle_voice`, `toggle_lock`, `randomize_voice`, scene recall, ...). `grid_redraw()` returns at once when no grid is connected, so calling it is cheap.
- Parameter faders on grid page 2 are redrawn after `gentle_mutate`, after every scene-transition step, and from the drift tick (`drift_update`, 10 times a second) through `S.lib.grid_faders.follow_faders()`, only when what a faders page shows changed (#324).

## Keys

- Every layout handles releases on its position page (the hold, store and bookmark keys); elsewhere `z == 0` returns at once. `grid_key` passes releases on so a layout can handle them, and it tracks held keys for holds and two-key gestures (above).
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

## Registering a grid layout

- **Registering a grid layout**: a `lib/grid/layout_<name>.lua` sets `S.registry.grid_layouts["<name>"] = {key = ..., redraw = ...}`, plus one `include` line in `strata.lua` and the size match in `grid_layout()` (`lib/grid/core.lua`).
