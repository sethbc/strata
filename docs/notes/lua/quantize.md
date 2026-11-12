## Must not break

- A user action that 3.4 quantizes (a scene recall from a key, a freeze toggle from a key, a bookmark recall or position jump from a key, the pattern start) goes through `S.lib.quantize.schedule(key, fn, label)`, never its own `clock.sync`. A step's bookmark lock and the functions themselves (`S.lib.positions.jump`, `set_loop`, `recall_bookmark`, `S.lib.bookmarks.recall`, `S.lib.freeze.toggle`) are never wrapped: a step never waits for a bar (design §8.9, plan item 12).
- One action waits per key: a new `schedule` of a key cancels the one that waits (its clock and its flash) before it runs its own or waits, also when `quantize_actions` is off by then. The scene, bookmark and position keys keep that rule (a second key replaces the first); the two toggles, a freeze key (`S.lib.freeze.toggle_quantized`) and the play key (`pattern_toggle`), call `cancel(key)` first and schedule nothing when it dropped one, so a second press takes the first back (#625).
- A waiting pattern start never outlives a start or stop of the patterns: `lib/sequencer.lua`'s `start_patterns` (the play key's own run, a followed transport start) and `pattern_clock_stop` (the play key, a followed transport stop, the error path, cleanup) call `cancel("patterns")` (#625).
- An action waits exactly while its clock runs (the `quantize` invariant): the entry `M.actions[key]` is dropped as its clock wakes, before `fn` runs, and by every cancel. A waiting `fn` that raises prints `strata: quantized <key> failed: <error>` (the harness counts it as a script error) and leaves nothing waiting.
- **A dropped action's clock is never canceled while its resume may be posted** (#626): norns delivers every resume matron posted, and one whose coroutine was canceled meanwhile makes `clock.resume` raise (maiden prints `bad argument #1 to 'resume'`). A cancel (a replacement, `cancel(key)`) whose action's sync is within `QUANTIZE.wake_tolerance` (1/32 beat) of its beat or past it, or whose beat is below the one it synced at (a reset or a new clock source moved the sync), retires the clock (`M.retired`): at that resume it finds its action gone and ends, running nothing. Any other is canceled at once. The sync's beat is worked out as matron's scheduler does (the clock's first wait counts from the beat it synced at). Cleanup cancels every retired clock still waiting; the invariant wants each to run until then.
- `PARAM_COUNT` is the number of params `add_params` adds (1): `lib/sequencer.lua`'s `strata_seq` group counts it in its size and calls `add_params` for its fifth param (plan item 11), so either package could land first. With the sequencer's `add_params` (3.4's 1d) the group holds its seven params, `quantize_actions` fifth; `lib/params_setup.lua`'s `seq` record adds `strata_seq` with quantize's params alone only for a sequencer without one.
- Cleanup step 97 cancels every waiting action and every retired clock, and nothing more (the flashes' own step, 140, ends the header's flash).

## Owns

`lib/quantize.lua` (`S.lib.quantize`, 3.4, packages 0a and 1f):
- The param `quantize_actions` (option `off`, `beat`, `bar`; default off), added by `add_params()`.
- `schedule(key, fn, label)`: run `fn` now while `quantize_actions` is off (or before the params exist), else at the next beat (`clock.sync(1)`) or bar (`clock.sync(4)`) on a clock of its own; a waiting action of the same key is replaced. With a `label` the header flashes `<label> at beat` or `<label> at bar` (`S.lib.ui_flash`, for one beat or bar at the tempo then) and the flash ends when `fn` runs or is replaced. Returns whether `fn` ran at once and, when it waits, its token (a number no other action gets). A key that is not a non-empty string or an action that is not a function is an error.
- `waiting(key, token)`: whether an action of that key waits; with a token, whether the one that waits is still that action (a later schedule of the key, a run or a cancel ends it), so a caller that keeps what its own action will do knows when that is stale.
- `cancel(key)`: drops the action of that key that waits, its flash with it, and returns whether one waited (false for a key that is not a string).
- `actions`: the waiting actions by key, `{clock, flash, token, sync_beat, landing}` (tests read the clocks here); `retired`: the dropped actions' clocks left to end at their resume.
- `QUANTIZE`, the module's one table of tunables (`param_count`, `param_id`, `modes`, `beats` per mode, `wake_tolerance`, `flt_epsilon`).
- The cleanup step `CLEANUP_ORDER.quantize` (97) and the `quantize` invariant.
- Its tests: `test/unit/quantize_test.lua` (the waits, the replacement, the flash, every wrap's flash fitting `HEADER.flash_width` for voice 7 under beat, a failing action, the cleanup, and `strata_seq` as the sequencer's group of seven, its own and with a test double for its `add_params`).

## Callers

Design §8.9's keys:
- `freeze<v>`: `S.lib.freeze.toggle_quantized(v)` (label `v<v> frz`, which fits the header flash as `v7 frz at beat`), for the grids' freeze keys (2c points them at it; VOICE's freeze row and a mapped CC set the param and act at once); a press while the voice's toggle waits takes it back.
- `position<v>`: a grid's position key (`S.lib.positions.grid_key`'s jump and its two-key loop, label `v<v> jump`; a loop replaces the jump its first key left waiting).
- `bookmark<v>`: `S.lib.positions.recall_bookmark_quantized(v, n)` (label `v<v> bm <n>`), for a grid's bookmark strip key and BUFFER's `bm` field (E3 and ALT+E3, `docs/notes/lua/pages/buffer.md`); `S.lib.positions.waiting_bookmark(v)` is the bookmark that waits, whichever of the two scheduled it.
- `scene` (SCENES' keys, the grid's scene keys and the arc button, 1c) and `patterns` (the pattern start, 1d: a press while it waits takes it back, and any start or stop of the patterns drops it), in their own files.

Not quantized: the scene sequencer, steps (a step's bookmark lock calls `S.lib.bookmarks.recall`, which recalls at once), LFOs, morph, a grid's bookmark store and whole-loop keys, the arc's scrub.
