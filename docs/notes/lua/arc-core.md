## Must not break

- Handlers live on the vport only (`arc.connect(port)`), never on the raw device passed to `arc.add`.
- Strata follows one arc: on the vport of the device (`device.port`; at init the first vport holding a device). A device with no port (norns found no vport for it) is on no vport at all: `arc.add` and `arc.remove` return at once for it, so it is never followed and never taken for port 1's (#437). While one is connected, `arc.add` of another arc is ignored and `arc.remove` disconnects only the connected one.
- `S.arc_connected` is exactly whether the followed vport holds a device (the `"arc connection"` invariant). An arc moved in SYSTEM > DEVICES gets no `arc.add` or `arc.remove` (norns calls `update_devices()` only), so `S.lib.arc_core.reconcile()` runs as the norns menu closes (#256).
- Every ring is filled through `arc_ring_fill` from `param_fraction`, or through `arc_ring_fill_bipolar` (which reads `param_fraction` itself) for a range through 0, never from a hardcoded range and never with a bare `segment` (a full turn would light nothing). `arc_ring_fill_param` picks between them. A ring that shows a whole-step position (SEQ's step, level and voice rings, SCENES' cursor ring) is filled through `arc_ring_fill_position`, which lights LED 1 at the first position, so it never looks like a ring that is off (#510); a swept ring at its minimum still lights nothing.
- Every continuous ring sweeps its param's whole range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (1024) ticks through `arc_sweep_param`; a ring never has a scale of its own (the exceptions are listed in `docs/notes/lua/arc-pages.md`).
- Whole-step rings carry their spare ticks through `arc_whole_steps(key, delta, ticks_per_step)` under a key of their own (`S.arc_ticks[key]`), never in a table of their own, so a page change (`set_ui_page`, which calls `forget_arc_ticks()`) forgets them all.
- The button goes through the shown page record's `arc_button()` on every page that has one (`arc_key` finds the record by index, `S.registry.pages[S.ui_page]`, never by the title string). `arc_button` is a page field, set by `lib/pages/<page>.lua`.
- The ring handlers (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`) are set only by `lib/arc/<page>.lua`; a page without them ignores turns and leaves the rings off.
- Everything degrades gracefully without an arc: `arc_redraw()` returns unless `S.arc_device` has a connected device.
- Rings are drawn by the frame clock (`request_redraw()`), never by calling `arc_redraw()` from script code.

## Owns

- `lib/arc/core.lua` (`S.lib.arc_core`), what every page shares:
  - `S.arc_device`, `S.arc_connected`, and `reconcile()` on `S.lib.arc_core` (a menu-close hook);
  - `S.arc_ticks` (carried ticks per key);
  - `arc_sweep_param`, `arc_ring_fill`, `arc_ring_fill_position`, `arc_ring_fill_bipolar`, `arc_ring_fill_param`, `arc_whole_steps`, `forget_arc_ticks`, `attach_arc`, `first_arc_port`, `arc_init`, `arc.add`/`arc.remove`, `forget_arc_lfo_period_ticks`;
  - the norns entry points `arc_delta`, `arc_key` and `arc_redraw`;
  - all global but `attach_arc` and `page_ring_handler`, locals of the constructor (`arc.add`/`arc.remove` are fields of norns' `arc` table);
  - cleanup step 180: the followed vport's `delta` and `key` cleared, the arc left dark, and `arc.add`/`arc.remove` set to no-ops (norns' SLEEP runs only `cleanup()`, #468);
  - the invariant `"arc connection"`: `S.arc_connected == (S.arc_device ~= nil and S.arc_device.device ~= nil)`.
- Unit tests: `test/unit/arc_core_test.lua` (fills, carried ticks, ALT rings, the button, a portless device, the one followed arc, an arc moved in SYSTEM > DEVICES, drawing while the menu is open). Each page's rings are in `docs/notes/lua/arc-pages.md`.

## Device lifecycle

- `arc_init()` (start step `START_ORDER.arc`): attaches the first arc vport holding a device (`first_arc_port()`), else `UI_PAGES.ARC_PORT`, and sets up its callbacks through `attach_arc()`.
- `arc.add(device)`: norns' callback when an arc connects. It attaches the vport for `device.port`, only while no arc is connected; a device with no port is ignored.
- `arc.remove(device)`: norns' callback when an arc disconnects.
  - A device with no port is ignored.
  - It acts only when the removed device is on the connected vport (`S.arc_device == arc.connect(port)`), so another arc neither replaces nor disconnects it.
  - Removing the followed arc attaches `first_arc_port(port)`, the first other vport holding a device, if any. norns clears the removed vport only after `arc.remove` returns, so its port is skipped (issue #49).
  - It disconnects only when there is no other arc.
- `S.lib.arc_core.reconcile()`: SYSTEM > DEVICES moves an arc between ports through norns' `update_devices()` alone (`lua/core/menu/devices.lua`), with no `arc.add` or `arc.remove`, so the followed vport can go empty, or fill, under the script. As the norns menu closes (registered with `S.register_menu_close`): when the followed vport holds no device, follow `first_arc_port()` if there is one (through `attach_arc`), else `S.arc_connected = false`; when it holds one, `S.arc_connected = true`. Then `request_redraw()` (the rings, and SETUP's arc state).
- Handlers live on the vport only, as for grids and MIDI.

## States: the followed arc

| State | Fields | Meaning |
|-------|--------|---------|
| Before init | `S.arc_device` nil, `S.arc_connected` false | No arc followed yet |
| Followed, connected | `S.arc_device` a vport holding a device, `S.arc_connected` true | Turns and the button reach the pages; the rings are drawn; SETUP shows `arc: connected` |
| Followed, none | `S.arc_device` a vport holding no device, `S.arc_connected` false | Its handlers stay, for an arc that arrives on that port; SETUP shows `arc: none` |

The invariant `"arc connection"` holds outside the norns menu: `S.arc_connected` is true exactly when `S.arc_device` holds a device. One function per transition:

| Transition | Function |
|------------|----------|
| Follow the first arc at init (or port 1 with none) | `arc_init` |
| An arc plugged in while none is connected | `arc.add` |
| The followed arc unplugged: follow another, or none | `arc.remove` |
| The menu closes after SYSTEM > DEVICES moved the arc | `S.lib.arc_core.reconcile` |
| Attach a vport (any of the above) | `attach_arc` |

## Dispatch

The arc follows the screen page (`S.ui_page`):
- `arc_delta(n, delta)` calls the current page record's `arc_delta(ring, delta)` (`S.registry.pages[S.ui_page]`), then requests a redraw.
- `arc_redraw` runs `S.lib.ui_cursors.clamp_all()`, clears the rings, calls the record's `arc_redraw(S.arc_device)` and refreshes.
- While ALT is held (`S.alt_held`), both use the record's `arc_alt_delta`/`arc_alt_redraw` instead, when it has them; a page without ALT rings keeps its plain ones under ALT (`page_ring_handler`). K1 requests a redraw, so the rings switch at once. MAIN and BUFFER have ALT rings (`lib/arc/main.lua`, `lib/arc/buffer.lua`, `docs/notes/lua/arc-pages.md`); BUFFER's also hold the voice's scan from the first ring 1 turn and let go through an ALT-release hook (`S.register_alt_release`), so a page adding ALT rings that hold something follows BUFFER, not MAIN.
- A record without ring handlers ignores turns and leaves the rings off (and `arc_delta` still requests a redraw).
- A page change (`set_ui_page` in `lib/ui/keys.lua`) forgets every carried tick (`forget_arc_ticks()`), so ticks turned on one page never step a param on another.
- `enc` calls `request_redraw()`, which marks the arc dirty too, so changing page redraws the rings.

`arc_key(n, s)` handles the button (2025 arc models):
- A press calls the shown page record's `arc_button()` and requests a redraw, on whichever page is up; a release does nothing, and so does a press on a page whose record has no `arc_button`.
- The record is found by index (`S.registry.pages[S.ui_page]`), never by the title string.
- Each page file sets its own (`lib/pages/<page>.lua`, the page's main action: MAIN and VOICE start or stop the selected voice, SEQ plays or stops, SCENES recalls at once, ...); FX and SETUP have none.

## Input

- `arc_sweep_param(param_id, delta)` sweeps the control param's whole range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (1024) ticks: `delta_with_detent(id, nil, {arc_ticks = delta})` (`lib/ui/detent.lua`) moves the 0-1 raw value by `delta / ARC_TICKS_PER_SWEEP` (1024) through `params:set_raw`, and holds a range through 0 at 0 for `DETENT.arc_ticks` (24) ticks (center detents, `docs/notes/lua/ui-core.md`). The arc has no fine mode.
- Moving the raw value, the sweep follows the warp (256 ticks reach `spec:map(0.5)`, e.g. 200 Hz on the 20-2000 Hz exp freq). The step only quantizes the value read back; raw keeps the remainder.
- 1024 is a full revolution (512 was half a turn and too fast, #552): the arc reports 1024 ticks per revolution (monome arc docs: "high resolution knobs, 1024 ticks per revolution", every edition; matron passes libmonome's deltas through unscaled, `device_monome.cc`).
- `arc_whole_steps(key, delta, ticks_per_step)` adds `delta` to `S.arc_ticks[key]` and returns the whole steps in it, keeping the remainder; `forget_arc_ticks(key)` clears one key, `forget_arc_ticks()` all of them. Whole-step rings pass the steps to `delta_with_detent(id, steps)`.
- No ring calls `params:delta`: every ring change goes through `arc_sweep_param` or `delta_with_detent` (a test checks `lib/arc/` and `lib/pages/`).

## Drawing

- `arc_redraw()` updates every ring to show the current page's values.
- The frame clock draws it when `UI_PAGES.arc_dirty` is set (`request_redraw()`, see `docs/notes/lua/ui/redraws.md`): at most 15 times a second however fast the rings turn.
- The arc keeps drawing while the norns menu is open, by design (#169): norns' menu takes only the screen, the keys and the encoders (`_menu.set_mode` in `lua/core/menu.lua` swaps `redraw`, `refresh`, the key handler and the encoder callback), so arc turns still reach the script, as grid presses do. `draw_frame` calls `arc_redraw()` directly, whereas the screen goes through the global `redraw`, which norns swaps for `norns.none` in the menu. An arc turn, a param changed from PARAMS or a CC map while the menu is open moves the rings at once, the grid repaints as usual, and closing the menu changes nothing on the rings (tests pin all three).
- Rings are drawn with `S.arc_device:segment(ring, from, to, level)`, always through `arc_ring_fill(arc_port, ring, fraction, level)`, never a bare `segment`:
  - norns' `Arc:segment` reduces both angles modulo 2*pi, so a full turn (0 to 2*pi) lights nothing;
  - the helper clamps the fraction to 0-1 and ends the fill `UI_PAGES.ARC_FULL_TURN_MARGIN` below a full turn, so a ring at its maximum lights all 64 LEDs and one at its minimum none.
- Bipolar rings (`arc_ring_fill_bipolar(arc_port, ring, param_id, level)`, for a param whose range spans 0):
  - the fill runs from 12 o'clock through `(param_fraction(id) - param_value_fraction(id, 0))` of a turn: clockwise (`segment(ring, 0, angle)`) above 0, counter-clockwise (`segment(ring, 2*pi + angle, 2*pi)`) below;
  - the zero point is the param's own 0, not the ring's middle (on -3 to 1, 0 sits three quarters round);
  - like `arc_ring_fill`, a fill stops `ARC_FULL_TURN_MARGIN` short of a whole turn, so it never lights nothing;
  - at exactly 0 only LED 1 lights, at `ARC_BIPOLAR_ZERO_LEVEL` (3, a local of `lib/arc/core.lua`), so the ring never looks dead.
- `arc_ring_fill_param(arc_port, ring, param_id, level)` draws a param's ring: bipolar when `param_spans_zero(id)` (`lib/ui/params.lua`: a control or number param with min < 0 < max), else `arc_ring_fill` from `param_fraction`. MAIN, VOICE, SEQ (tempo), BUFFER and SCENES draw their param rings through it.
- The test stub ports the real `Arc:segment` line for line (each LED set through `led()`, with `rel` adding to the level already there) and stores the per-LED levels it computed in `device.segments[ring].leds`.
  - The device also keeps matron's LED buffer (`device:get_led(ring, x)`: `led` and `all` absolute or relative). A relative set is clamped to 0-15 as `dev_monome_arc_set_led` does; an absolute one is stored as is on matron, and the stub rejects an absolute level outside 0-15.
  - Tests assert LED counts, not angles.

## Rules of thumb

- Continuous rings sweep their param's range in `UI_PAGES.ARC_TICKS_PER_SWEEP` ticks through `arc_sweep_param`; never give a ring its own delta scale.
- Ring feedback uses the same ranges as the param specs.
- `request_redraw()` marks the screen and the arc dirty together.
- Every arc function is non-blocking and safe to call without an arc connected.
