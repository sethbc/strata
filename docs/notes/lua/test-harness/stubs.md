## Must not break

- The stubs mirror the real norns libraries (`~/src/norns/lua`) and matron. Check behavior there before changing a stub.
- `param.t` holds numeric type codes (`params.tOPTION`, ...). Never compare it with a string; a test enforces this, with either quote and either order.

## The stubs

The stubs mirror the real norns libraries (`~/src/norns/lua`), so check behavior there before changing them.

### Params

- Types: number, control, option, binary, trigger, file, text, separator, group.
- `set_action`, `hide`/`show`/`visible`.
- `params:write(path)`/`params:read(path, silent)` as in `lua/core/paramset.lua`, absolute paths only. Read sets each param in file order through its own `set`, so actions fire mid-read as on norns. `params:set_save(id, false)` keeps a param out of the file, as norns does for most system params.
- Strings as `core/params/*.lua`: a control without a formatter shows `util.round(value, 0.01) .. " " .. units`; a number or binary returns its value, a number.
- A ControlSpec made without a default has `default` nil, and its control starts at raw 0. `spec:copy()` is `core/controlspec.lua`'s: range, warp, step, default, units and quantum (not `wrap`, as on norns).
- `params:get_raw(id)`/`params:set_raw(id, v, silent)` as `core/params/control.lua`, for control params only (the stub errors on any other type): `set_raw` wraps a wrapping spec or clamps to 0-1, stores the raw value unrounded and fires the action on a change unless silent; `get` maps raw and rounds to the step.
- Warps: `exp`, `db` and `lin`.
- norns' system params come first (`audio.add_params` and `clock.add_params`: the LEVELS, REVERB, COMPRESSOR, SOFTCUT and CLOCK groups with their types, ranges and factory defaults, `clock_tempo` 120). Every id of `core/paramset.lua`'s `system_param_ids` is there but `clock_midi_out`, which norns never adds (its params are `clock_midi_out_1..16`). So a script param with a system id fails as a collision.

### Libraries

- `tab.save`/`tab.load`: lib/tabutil.lua's, ported unchanged. The `-- Table: {n}` layout; numbers go through `tostring`, so they keep 14 significant digits as on norns. A plain `return {...}` file loads as nil, so test fixtures are written with `tab.save`, or the `tabutil_text(value)` helper in `test/helpers.lua`.
- `require("lfo")`: `test/stub_lfo.lua`, compared line by line with `lua/lib/lfo.lua`.
  - The library's `lfo_*` params and actions; `reset_phase` and `set("period")` reset and rescale `phase_counter` as the library does.
  - Nothing runs on its own: `context.lfo.tick(instance, raw)` performs one library step, with `raw` 0..1 as the shape output.
- `midi`: `test/stub_midi.lua`. 16 vports, `to_msg`/`to_data`. Helpers `context.midi.plug(port, name)`, `unplug(port)`, `send(port, msg)`, and `reassign(from_port, to_port)`, which moves a device between vports as SYSTEM > DEVICES does (`update_devices()` only, no `midi.add` or `midi.remove`; the grid's and arc's `reassign` logic).
- `grid` and `arc`: 4 vports each, mirroring `lua/core/grid.lua` and `arc.lua`; devices are kept by id in `devices[id]`, each named after its id (`grid 1`, `arc 1`), and every event reaches both `device.key`/`delta` and the vport's handler, as norns fires them.
  - `context.grid.plug(port, cols, rows)` and `context.arc.plug(port)` put a new device on the port's vport (its name, `device`, the grid's `cols` and `rows`) and call `grid.add`/`arc.add`; `unplug(port)` calls `remove` with the device the port's vport holds and empties the vport.
  - `context.grid.press(port, x, y, z)`, `context.arc.turn(port, ring, delta)` and `context.arc.push(port, button, state)` deliver an event from the device the port's vport holds now.
  - `update_devices()` is norns': every device leaves its port, then each vport takes the device whose name it holds (a grid vport also its `cols` and `rows`).
  - `reassign(from_port, to_port)` is SYSTEM > DEVICES' K3 (`lua/core/menu/devices.lua`): `to_port` takes the name of the device on `from_port`, every other vport of that name becomes `"none"`, then `update_devices()`. It calls no `add` or `remove`, so the script hears of the move only as the norns menu closes (a test opens and closes it with `_menu.set_mode` around the call).
- `audio.file_info(path)`: `lua/core/audio.lua`'s (matron's `sound_file_inspect`): channels, frames and sample rate of a file a test lists in `context.audio.files[path] = {channels, frames, rate}`; `context.audio.register(path, {channels, frames, rate})` lists one too, and a path under a test's data folder is read from its WAV header (`fmt ` and `data` chunks); any other path returns 0, 0, 0, as for a file libsndfile cannot open.
- `poll.set`: the system polls plus the engine's `addPoll` names; unknown names return nil. `context.polls.fire(name, value)` reaches started polls.
- `require("fileselect")`: a module through `package.preload`, never a global, so a script that relies on a `fileselect` global fails.
  - `enter` records `context.fileselect.last`, and its callback in `fileselect.callback` (as `fs.enter` keeps it in `fs.callback`, so a second `enter` replaces the first's).
  - From play mode, `enter` calls `norns.menu.init()` (so a script's `_menu.set_mode` wrapper runs), makes the `redraw()` call norns' `fs.enter` makes, then its own `fileselect.redraw()`.
  - `fileselect.redraw` draws nothing and counts its calls in `context.fileselect.redraws`.
  - `context.fileselect.close(path)` closes it as `fs.exit` does: from play mode `norns.menu.init()` and `redraw()`, then the callback with `path`, or `"cancel"` when nil.
  - Keys and encoders are not rerouted.
- `require("musicutil").note_num_to_freq`, `_path.audio` (`context.audio_dir`), `util.scandir`/`util.os_capture`, `_menu.rebuild_params`.
- `_menu.set_mode(mode)` tracks `_menu.mode`. `set_mode(false)` records the play-mode routing from the globals, `_menu.key = key` and `norns.encoders.callback = enc`, as norns does. It swaps no handlers and draws nothing.
- `norns.menu.init()` is `_menu.set_mode(_menu.mode)`.
- `screen.line`/`screen.rect` are recorded in `context.screen.lines` (`x1, y1, x2, y2, level`) and `context.screen.rects` (`x, y, w, h, level`) beside the texts. `screen.fill()` and `screen.stroke()` close the current path as norns does (`lua/core/screen.lua`): they mark every line and rect drawn since the last fill or stroke (or `screen.clear()`) `filled = true` or `false`, so a test can tell a filled cell from an outline; `filled` is nil until then.
- `norns.enc.accel`/`sens`: state in `context.encoders.accel`/`sens`, starting at norns' script defaults (accel on, sens 2). `context.encoders.deliver(n, delta, interval)` delivers one hardware encoder event the way `encoders.process_with_accel` does, with `interval` seconds since the previous one.

### Param types

- Like norns, the param stub stores numeric type codes in `param.t` (`params.tOPTION` etc.), all from its one `PARAM_TYPE_CODES` table (exported as `stubs.PARAM_TYPE_CODES`).
- `params:add` with an unknown type raises an error (norns prints one and adds nothing).
- Never compare `param.t` with a string. A test enforces this for the script's sources, with either quote and either order: `p.t == "option"`, `'option' == p.t`.

### Group sizes

norns cannot see where a group ends (it takes the next `n` params), so the param stub requires each group to get exactly `n` params. It errors:
- when the next group arrives first (this is also the nesting error);
- when the param after the group's last one is neither a separator nor a group (`n` too small);
- in `context.check_param_groups()`, which `load_strata` calls after `init()`, when a group is still short at the end of the list.
