## Must not break

- A user action that 3.4 quantizes (a scene recall from a key, a freeze key's set, a bookmark recall or position jump from a key, the pattern start) goes through `S.lib.quantize.schedule(key, fn, label)`, never its own `clock.sync`. A step's bookmark lock and the functions themselves (`S.lib.positions.jump`, `set_loop`, `recall_bookmark`, `S.lib.bookmarks.recall`, `S.lib.freeze.toggle`) are never wrapped: a step never waits for a bar (design §8.9, plan item 12).
- One action waits per key: a new `schedule` of a key cancels the one that waits (its clock and its flash) before it runs its own or waits, also when `quantize_actions` is off by then. The scene, bookmark and position keys keep that rule (a second key replaces the first); the two keys a second press takes back, a freeze key (`S.lib.freeze.toggle_quantized`, a set of the value its press asked for) and the play key (`pattern_toggle`), call `cancel(key)` first and schedule nothing when it dropped one, so a second press takes the first back (#625).
- A waiting pattern start never outlives a start or stop of the patterns: `lib/sequencer.lua`'s `start_patterns` (the play key's own run, a followed transport start) and `pattern_clock_stop` (the play key, a followed transport stop, the error path, cleanup) call `cancel("patterns")` (#625).
- An action waits exactly while its clock runs (the `quantize` invariant): the entry `M.actions[key]` is dropped as its clock wakes, before `fn` runs, and by every cancel. A waiting `fn` that raises prints `strata: quantized <key> failed: <error>` (the harness counts it as a script error) and leaves nothing waiting.
- **A dropped action's clock is never canceled while its resume may be posted** (#626): norns delivers every resume matron posted, and one whose coroutine was canceled meanwhile makes `clock.resume` raise (maiden prints `bad argument #1 to 'resume'`). A cancel (a replacement, `cancel(key)`) whose action's sync is within `QUANTIZE.wake_tolerance` (1/32 beat) of its beat or past it, or whose beat is below the one it synced at (a reset or a new clock source moved the sync), retires the clock (`M.retired`): at that resume it finds its action gone and ends, running nothing. Any other is canceled at once. The sync's beat is worked out as matron's scheduler does (the clock's first wait counts from the beat it synced at). Cleanup cancels every retired clock still waiting; the invariant wants each to run until then.
- `PARAM_COUNT` is the number of params `add_params` adds (1): `lib/sequencer.lua`'s `strata_seq` group counts it in its size and calls `add_params` for its fifth param (plan item 11), so the group holds its seven params, `quantize_actions` fifth.
- Cleanup step 97 cancels every waiting action and every retired clock, and nothing more (the flashes' own step, 140, ends the header's flash).

## Machines

### quantize
- **State:** per key, its waiting action (`M.actions[key]`, read with `S.lib.quantize.waiting(key)`) and the clocks of dropped actions left to their resume (`M.retired`): `idle`, `waiting` or `retired`. What a waiting action does is its function's own: a freeze key's is a set of the value its press asked for (`docs/notes/lua/freeze.md`, freeze key), the play key's the patterns' start (`docs/notes/lua/sequencer.md`, pattern clock).
- **Invariant:** `quantize`: every waiting action's clock runs and is not retired; every retired clock runs until its resume.
- **Test:** `test/unit/quantize_test.lua`: "quantize: idle + schedule" (one test a row: `quantize_actions` on bar, a probe key, each state entered at beat 1.5; `retired` is a waiting action dropped 1/64 beat before its bar). Each row's check runs past the bar and counts the action's runs.

The clock is this file's own (not `S.lib.clocks`): `schedule` starts it on `clock.sync(beats)`; at its wake it runs the action only while that is still the key's (`M.actions[key]`), else ends, forgetting its retired mark. Every cell is a row.

| State | Event | Next | Effect |
|---|---|---|---|
| `idle` | `schedule` | `waiting` | the header flashes `<label> at bar`; it runs on the bar |
| `idle` | `schedule, off` | `idle` | it runs at once |
| `idle` | `cancel` | `idle` | nothing waits: false |
| `idle` | `cancel near the bar` | `idle` | nothing waits: false |
| `idle` | `the bar` | `idle` | nothing |
| `idle` | `cleanup` | `idle` | nothing |
| `waiting` | `schedule` | `waiting` | the old one canceled (far from its bar); the new one runs on the bar |
| `waiting` | `schedule, off` | `idle` | the old one canceled; the new one runs at once |
| `waiting` | `cancel` | `idle` | its clock canceled at once, its flash ended |
| `waiting` | `cancel near the bar` | `retired` | its resume may be posted: the clock is left to wake and end, running nothing (#626) |
| `waiting` | `the bar` | `idle` | it runs once |
| `waiting` | `cleanup` | `idle` | its clock canceled |
| `retired` | `schedule` | `waiting` | the new one runs on the bar; the retired clock ends there |
| `retired` | `schedule, off` | `retired` | it runs at once |
| `retired` | `cancel` | `retired` | nothing waits |
| `retired` | `cancel near the bar` | `retired` | nothing waits |
| `retired` | `the bar` | `idle` | the retired clock ends, running nothing |
| `retired` | `cleanup` | `idle` | the retired clock canceled |

## Owns

`lib/quantize.lua` (`S.lib.quantize`, 3.4, packages 0a and 1f):
- The param `quantize_actions` (option `off`, `beat`, `bar`; default off), added by `add_params()`.
- `schedule(key, fn, label)`: run `fn` now while `quantize_actions` is off (or before the params exist), else at the next beat (`clock.sync(1)`) or bar (`clock.sync(4)`) on a clock of its own; a waiting action of the same key is replaced. With a `label` the header flashes `<label> at beat` or `<label> at bar` (`S.lib.ui_flash`, started for `QUANTIZE.flash_seconds`, `math.huge`: no time ends it, so it shows for as long as the action waits, through a tempo change or a jump of the beat; #631) and the flash ends when `fn` runs or the action is replaced or dropped (another flash can take its place meanwhile, as any flash's). Returns whether `fn` ran at once and, when it waits, its token (a number no other action gets). A key that is not a non-empty string or an action that is not a function is an error.
- `waiting(key, token)`: whether an action of that key waits; with a token, whether the one that waits is still that action (a later schedule of the key, a run or a cancel ends it), so a caller that keeps what its own action will do knows when that is stale.
- `cancel(key)`: drops the action of that key that waits, its flash with it, and returns whether one waited (false for a key that is not a string).
- `actions`: the waiting actions by key, `{clock, flash, token, sync_beat, landing}` (tests read the clocks here); `retired`: the dropped actions' clocks left to end at their resume.
- `QUANTIZE`, the module's one table of tunables (`param_count`, `param_id`, `modes`, `beats` per mode, `wake_tolerance`, `flt_epsilon`, `flash_seconds`).
- The cleanup step `CLEANUP_ORDER.quantize` (97) and the `quantize` invariant.
- Its tests: `test/unit/quantize_test.lua` (the waits, the replacement, `cancel`, a drop with the resume posted (driven with `context.clock.advance`, which delivers every posted resume, #588), the flash through a tempo change, every wrap's flash fitting `HEADER.flash_width` for voice 7 under beat, a failing action, the cleanup, and `strata_seq` as the sequencer's group of seven).

## Callers

Design §8.9's keys:
- `freeze<v>`: `S.lib.freeze.toggle_quantized(v)`, a set of the value its press asked for (the opposite of the voice's freeze at the press, which a source switch, a hand set or a recall in between does not change, #864; label `v<v> frz`, which fits the header flash as `v7 frz at beat`), for the grids' freeze keys (2c points them at it; VOICE's freeze row and a mapped CC set the param and act at once); a press while the voice's set waits takes it back.
- `position<v>`: a grid's position key (`S.lib.positions.grid_key`'s jump and its two-key loop, label `v<v> jump`; a loop replaces the jump its first key left waiting).
- `bookmark<v>`: `S.lib.positions.recall_bookmark_quantized(v, n)` (label `v<v> bm <n>`), for a grid's bookmark strip key and BUFFER's `bm` field (E3 and ALT+E3, `docs/notes/lua/pages/buffer.md`); `S.lib.positions.waiting_bookmark(v)` is the bookmark that waits, whichever of the two scheduled it.
- `scene` (SCENES' keys, the grid's scene keys and the arc button, 1c) and `patterns` (the pattern start, 1d: a press while it waits takes it back, and any start or stop of the patterns drops it), in their own files.

Not quantized: the scene sequencer, steps (a step's bookmark lock calls `S.lib.bookmarks.recall`, which recalls at once), LFOs, morph, a grid's bookmark store and whole-loop keys, the arc's scrub.
