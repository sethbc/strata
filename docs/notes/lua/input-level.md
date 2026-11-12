## Must not break

- Only `lib/input_level.lua` names or sets norns' `amp_in_l` and `amp_in_r` polls (a norns poll has one callback, so a second owner would silence the first); a structure test checks `lib/`. Other modules read `S.lib.input_level.levels()`, `value()` or register `on_level`.
- The polls run from the start step (`START_ORDER.input_level`, 62) to the cleanup step (`CLEANUP_ORDER.input_meter`, 135) on every page, at `INPUT_LEVEL.poll_hz` (30); cleanup stops them and clears their callbacks. The invariant `"input level"` checks they run between the two.
- A listener (`on_level`) runs after each poll value, on every page, so it must be cheap and must ask for a redraw only when its page shows (BUFFER's meter checks `S.ui_page`). Each runs through `S.lib.ui_frame.contained_call`: one that raises prints once per distinct message and stops no other listener or the stored levels.
- The polls are looked up with `poll.set` again, never kept from load time (#438: norns replaces its poll objects when it re-registers the polls, an engine load, and a dead poll would silence the meter and the `IN` source): `refresh()` does it (it gives the module's callback and rate, starts them and stops a different object held before), the start step calls it and so does BUFFER's `enter`. No other module names the polls.
- The source's `value`, `describe` and `visible` never send and never yield (`docs/notes/lua/mod-sources.md`); a NaN or non-number poll value reads 0.

## Owns

`lib/input_level.lua` (`S.lib.input_level`, 3.4, package 1i, design §10.3), table `INPUT_LEVEL` (`poll_hz`, `polls`, `gain_param`, `hint`):
- `refresh()`: look both polls up again, set their callback and rate and start them.
- `levels()`: the last two polled amplitudes, left then right, 0 before the first.
- `value()`: the louder of the two times `input_follow_gain`, clamped to 0..1.
- `on_level(fn)`: `fn()` runs after each poll value.
- `add_params()`: the group `strata_input` ("input", called by the `input` menu record in `lib/params_setup.lua`) with `input_follow_gain` (control 1-30, exp, default 4).
- The mod source `input` (name `IN`, section `audio`, range 0..1): `describe` is the level in percent, `row.enc` turns the gain through `enc_param_delta` (E3), `row.fine_enc` through `delta_with_detent` with `fine`.

The polls are first looked up in the start step. A norns without them leaves the level at 0. BUFFER's input meter (`docs/notes/lua/pages/buffer.md`) draws from `levels()`. The matrix refreshes a destination at 24-48 Hz and the level arrives at 30 Hz: an envelope follower for swells and ducking, not transients.

Tests: `test/unit/input_level_test.lua`, and the meter's in `test/unit/pages_buffer_test.lua`.
