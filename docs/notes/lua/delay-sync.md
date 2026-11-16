## Must not break

- **The delay has one engine sender** (`lib/engine_sync.lua`, the `send_delay_to_engine` local; `S.engine_senders` of `delay_time`, `delay_feedback`, `delay_mix` and this module's three params): `engine.setDelay(S.lib.delay_sync.time(), engine_param_value("delay_feedback"), engine_param_value("delay_mix"), engine_param_value("delay_pingpong"))`, then `S.lib.delay_sync.sent(time)`. No other code calls `engine.setDelay`.
- **A synced delay plays its division and nothing else**: while `delay_sync` is on, `M.time()` is the division's beats at `S.lib.params_setup.beat_seconds_now()`, halved until at most `DELAY.max_seconds` (decision 9); `delay_time`, its hand edits, a scene's fade and its LFO and matrix offsets move the stored value and `engine_param_value("delay_time")`, which play again when sync is off. Never a base override for this: any hand edit of the param ends one.
- **`DELAY.max_seconds` equals the engine's limit** on `setDelay`'s time (`\strataDelay`'s `time.lag(0.1).clip(0.01, 2.7)`, read by the engine stub; a test compares them), and `delay_time`'s range ends there.
- **A recall never sends a mix of old and new delay settings**: while a scene applies (`S.scene_recall_in_progress`: an instant recall, a fade's end, morph's discrete entries) the sender only holds the send (`M.hold()`); the module's scene-applied hook (`S.register_scene_applied`, run once as `apply_entries` ends) sends one `setDelay` with every value the scene set, through `send_engine_value`. A recall's and a fade landing's go at once, never deferred (`docs/notes/lua/engine-sync.md`); morph's discrete entries apply inside morph's `deferrable`, so their send waits with the window full, as every morph write does (morph's rule, not a recall's). A fade's steps send `delay_pingpong` and `delay_time` as they move (outside the flag).
- **A tempo move is resent within a step, a small one never**: the step hook (`S.lib.lfos.on_step`) compares `M.time()` with the time last sent (`M.sent`; `delay_time`'s default before any send) and marks the send due when it moved by more than `DELAY.threshold` (0.5%) of itself. The send goes through the round robin and the send budget under the key `"delay sync"` (`S.lib.engine_sync.send_engine_value`), whose engine sender is the delay's.
- 3.6's sound by default: `delay_sync` off, `delay_pingpong` 0; the engine's `pingPong` default is 0 and every `setDelay` carries it.
- Scenes store the three: `delay_sync` and `delay_division` switch at a fade's end (`discrete`), `delay_pingpong` crossfades; a scene without them loads with their defaults (`fill_scene`).
- No 3.7 param joins a randomize (ruling 35): FX's delay draw is still time, feedback and mix.

## Owns

`lib/delay_sync.lua` (`S.lib.delay_sync`, 3.7 design §6, package 1d), included just before `lib/params_setup.lua`:
- `M.DELAY = {max_seconds = 2.7, default_division = 7, threshold = 0.005}`.
- `M.time()`: the seconds the delay plays (above). A tempo that gives no finite, positive length (an external clock reporting 0) plays `delay_time`.
- `M.playing()`: `{division = index into S.constants.DIVISIONS, halvings = n}` while synced, else nil. FX's time row, arc ring 3 and the 256's delay fader turn the division while it is not nil.
- `M.label()`: `1/8D`, or while halved the division and what plays: `1 bar>1/2` (the division whose beats equal the halved length) or `1/4D>2.25 s` (seconds when none does); nil while not synced.
- `M.hold()`, `M.resend()`, `M.sent(time)`: a scene's held send, the step hook's resend and the time last sent (above).
- The fx record `delay sync` (`S.register_fx_params`, three params after the group's own and the bypasses): `delay_sync` (binary toggle, 0), `delay_division` (option, `DIVISIONS.names`, default 7, `1/8D`), `delay_pingpong` (control 0-1, step 0.01, 0). Each action calls `send_param_to_engine`; sync's and the division's also redraw the grids while a 256 shows the FX faders and request a redraw (FX's time row, arc ring 3).
- The three scene fields and the step hook.

Elsewhere: the delay's sender and its hold are `lib/engine_sync.lua`'s; the rows are FX's (`docs/notes/lua/pages/fx.md`), ring 3 `lib/arc/fx.lua`'s (`docs/notes/lua/arc-pages.md`), the fader `S.lib.grid_faders.fx_fader_id` (`docs/notes/lua/grid/layout_256.md`); `\strataDelay` and its ping-pong are the effects area's (`docs/notes/engine/effects.md`).

## Tests

`test/unit/delay_sync_test.lua`: the four values with sync off; the division at 120 and 90 BPM; halving at 60, 30, 10 and 5 BPM and not at 88.9 (the labels); a tempo change sent at the next step and a move under 0.5% not at all; a synced delay ignoring `delay_time` and an offset on it; the scene fields (fade, defaults, ranges); a recall's one `setDelay` at once with the scene's values (an instant recall changing only the feedback or mix, a fade's landing, a morph crossing carrying only `delay_sync`); `DELAY.max_seconds` against the stub's limit. The FX rows in `pages_fx_test.lua`, ring 3 in `arc_pages_test.lua`, the fader in `grid_layout_256_test.lua`.
