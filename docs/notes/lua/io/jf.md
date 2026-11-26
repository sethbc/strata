## Must not break

- **Nothing is sent by default**: the routes are off, and `routed(voice)` is true only with the route on and `S.lib.io_ii.leads()` true. With no `S.lib.io_ii`, or before its `add_params` added this module's params, `routed` is false, `rows` is empty and no param is read (the IO page raises on a `param` row whose param does not exist).
- **One message per note**: `note_on` sends `("jf", "play_note", clamp(volts(pitch), -5, 5), velocity * jf_level)` through `S.lib.io_ii.send`; `note_off` and `stop_all` send nothing (Just Friends allocates six voices and steals the oldest). Command names and argument order are crow's descriptor's (`docs/design/3.6-facts/crow-ii.md` section 2).
- **Mode**: `ready` sends `mode 1` through `send`; `release` sends `mode 0` through `send_direct`.
- **Params are PSET-only**: `v<i>_out_jf` (binary toggles) and `jf_level`; none is a scene field, in any `param_order` or a fader page. The route action and PSET read hook compare the selected route with the last applied value for that voice. Each change calls `S.lib.io_targets.route_changed(voice)` once, including on a silent read. Reading an unchanged route preserves its held notes.

## Owns

- `lib/io/jf.lua` (`S.lib.io_jf`): `JF` (every tunable), `add_params()` (called by the ii module's group `strata_out_ii`; `param_count` 8), the ii device `jf` (`ports = false`: `play_note`'s first argument is a pitch, so the ii queue gives `play_note` one turn) and the note target `jf` (rows `jf` and `jf level` on IO's voice section; `jf` marked `JF.idle_mark`, `[idle]`, while the route is on and Strata does not lead the bus, #937; the layout state `an idle ii route`).
- Test: `test/unit/io_jf_test.lua`, with a double for `S.lib.io_ii`.
- User page: `docs/user/io/jf.md`.
