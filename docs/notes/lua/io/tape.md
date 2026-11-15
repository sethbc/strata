## Must not break

- **Nothing reaches softcut or the mixer with the tape off**: the module's params and senders call nothing until `tapeloop` is on, and the three `audio.level_*_cut` calls happen only when the tape goes on or off (and only off after it was on). Defaults send nothing (3.6's "nothing by default").
- **The write path's values are `checks.md` section 8's** (issue #701): an open cutoff of 12000 Hz (`TAPE.cutoff_open`, softcut clamps there), a filter rq of 1.414, the feedback param divided by the write gain 1.2 (`TAPE.write_gain`, so the param's top holds the loop), `pre_filter_fc_mod(v, 0)` before `pre_filter_fc`, `pre_filter_dry` 0 and `post_filter_dry` 1, and the mixer's ADC and tape levels into softcut at 0 with the engine's at 1 while the loop is on.
- **Order on**: the calls of `start` in the order of its code (buffer, pan, loop, loop start and end, fade, position, rate slew, rate, level, input, pre level, feedback, rec level, filter, rec, play, enable), then the mixer. A test pins it.
- **Two voices, 1 and 2**, and no other softcut voice is named. A voice's buffer is its own number.
- **Off and cleanup put the mixer back from norns' own params** (`cut_input_eng`, `cut_input_adc`, `cut_input_tape`, through `util.dbamp`), never from a remembered value.
- **The four macro targets send through `S.engine_senders`** (`send_param_to_engine`), so an LFO, a matrix routing or a macro on them reaches softcut with its offsets; those senders call softcut and no engine command, and the value they get is the offset one. `start` reads the same four from `engine_param_value` so a running modulation holds across an on.
- **Params are PSET-only**: none is a scene field, an LFO destination, a fader-page param or in `param_order`; only the four are macro targets. The ids are `tapeloop...`, never `tape_level` (norns owns that one).

## Owns

- `lib/io/tape.lua` (`S.lib.io_tape`): `TAPE` (every tunable), `add_params()` (group `strata_tape`, 7), `stop()`, `is_on()`; the four senders, the four macro targets, IO's `tape` section (seven param rows, no status; `layout_states` tape off, tape on); the start step (`START_ORDER.io_tape`, 97: starts the loop only if `tapeloop` is already on) and the cleanup step (`CLEANUP_ORDER.io_tape`, 149: `stop()`).
- `lib/arc/io.lua` (`S.lib.arc_io`): IO's four rings (`docs/notes/lua/arc-pages.md`).
- Tests: `test/unit/io_tape_test.lua` against `context.softcut` and `context.audio.levels`.
- User page: `docs/user/io/tape.md`.

## How it works

The `tapeloop` action calls `start` (sets two voices up as one stereo loop) or `stop`. The other params' actions send their own softcut calls to both voices while `engaged`. The cutoff is `12000 * (800 / 12000) ^ wear`. Softcut has no state to read back, so the module keeps one flag, `engaged`.
