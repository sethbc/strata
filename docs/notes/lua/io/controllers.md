## Must not break

- **Ports and listeners only through `S.lib.io_ports`**: `claim`, `release`, `listen`, `unlisten`, `out`, `device` and `on_change`; nothing is set on a vport. Frames go out as raw bytes through `out(port):send(bytes)` and CCs through its `:cc(cc, value, channel)`, and only while a device is on the port.
- **Rig settings are read, never written**: `S.lib.io_rig.get` at each use (channel, first CC, encoding and hires are live) and `on_change` for the eight controller keys; the module never calls `set` or `step` (a structure test), so a layout state shows a stand-in (`preview`) for the ports, devices, marks and clash, never the rig's own values.
- **A macro's value is its param's value**: a fader sets `macro_<m>` with `params:set`, an E16 turn is `delta_with_detent("macro_<m>", d, {source = "midi"})` (a touch from midi, so macro learn and the gesture recorders see it). An LFO or a matrix routing on a macro moves engine values and never the param, so it neither moves a ring or an echo nor drops a pickup.
- **The echo never reads as a turn**: a CC arriving on the E16's channel with the number and value Strata sent less than `CONTROLLERS.echo_guard_seconds` ago is ignored.
- **One clock, only while a controller port is set**: `clock_id()` is nil with both ports off; the clock is canceled before its replacement (a rig port change) and at cleanup 146. Each tick is contained (`contained_call`).
- **The frames' bytes** (`CONTROLLERS.header` = F0 7D 53 54): ring `01` then sixteen two-byte values (`round(value * 16383)`, high 7 bits first) then F7 (38 bytes); label `02 <m - 1> <4 characters> F7` (the first target's `target_label`, cut or padded to four, or `M<m>`); title `03 STRATA F7`. The index byte is 0-based; the E16's own indexes count from 1, which is why `extras/e16/strata.lua` adds 1 (`docs/design/3.6-facts/checks.md` section 2).
- **Relative encodings** (`docs/design/3.6-facts/controllers.md` section 1, `checks.md` section 3): `rel1` 1 to 63 up by that many and 65 to 127 down by `128 - value`; `rel2` 63 up and 65 down (below 64: `64 - value` up, above: `value - 64` down); 0 and 64 nothing.
- **Pickup**: a fader picks its macro up when its value comes within `pickup_window` (2/127) of the param or crosses it between two messages; a param value that is not what the fader last set ends it (`M.pickup` checks live). With hires on, a CC `faders_cc + m - 1 + 32` is the low 7 bits; once one has come the value is `(high * 128 + low) / 16383`, until then `high / 127`; a low byte before any high byte moves nothing.
- **The start step 94 sends nothing** with both ports off (a structure test's start log): refreshes at start ask for no redraw.

## Owns

`lib/io/controllers.lua` (`S.lib.io_controllers`, 3.6):
- `M.CONTROLLERS`, `M.pickup(m)`, `M.map_clash()`, `M.clock_id()`;
- the E16 handler (listener name `e16`) and the faders' (`faders`), the echo clock (15 Hz, at most 16 CCs a tick, newest values, one ring frame when any changed, a label frame for each macro whose first target changed), labels and the title at a device's arrival;
- IO's `controllers` section: the eight settings as `rig` rows, a `status` row of sixteen marks (`|` picked up, `.` waiting), the section status `map clash` or `[--]` when a set port has no device; `layout_states` `no port set`, `port without device`, `both present` and `map clash`;
- start step 94 (`START_ORDER.io_controllers`) and cleanup step 146 (`CLEANUP_ORDER.io_controllers`).

`extras/e16/strata.lua`: the E16 scene script (never loaded by norns): `controller.onSysex` checks the header, F7, 7-bit data and the frame's length, then draws the rings (`leds.update`), labels (`slots.update`) and the title (`page.setTitle`). `test/stub_e16.lua` runs it with the E16's globals.

## Not done

- A port that another owner holds is not taken, and not taken again when the owner releases it; set the rig port again.
- At a device's arrival only labels and the title are sent; rings and CCs follow the first change of each macro.
- Unverified on a device until the 4.0 hardware check (#6): the order of an E16's CC14 bytes (unused), whether a fast turn sends more than one detent, and whether a script's rings stay visible on the page a relative control is on.

Tests: `test/unit/io_controllers_test.lua`; the E16 script's through `test/stub_e16.lua`.
