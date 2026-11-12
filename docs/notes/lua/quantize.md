## Must not break

- A user action that 3.4 quantizes (a scene recall from a key, a freeze toggle from a key, a bookmark recall or position jump from a key, the pattern start) goes through `S.lib.quantize.schedule(key, fn, label)`, never its own `clock.sync`. A step's bookmark lock and the functions themselves (`S.lib.positions.jump`, `set_loop`, `recall_bookmark`, `S.lib.bookmarks.recall`, `S.lib.freeze.toggle`) are never wrapped: a step never waits for a bar (design §8.9, plan item 12).
- One action waits per key: a new `schedule` of a key cancels the one that waits (its clock and its flash) before it runs its own or waits, also when `quantize_actions` is off by then.
- An action waits exactly while its clock runs (the `quantize` invariant): the entry `M.actions[key]` is dropped as its clock wakes, before `fn` runs, and by every cancel. A waiting `fn` that raises prints `strata: quantized <key> failed: <error>` (the harness counts it as a script error) and leaves nothing waiting.
- `PARAM_COUNT` is the number of params `add_params` adds (1): `lib/sequencer.lua`'s `strata_seq` group counts it in its size and calls `add_params` for its fifth param (plan item 11), so either package can land first. Until the sequencer has an `add_params`, `lib/params_setup.lua`'s `seq` record adds `strata_seq` with quantize's params alone.
- Cleanup step 97 cancels every waiting action, and nothing more (the flashes' own step, 140, ends the header's flash).

## Owns

`lib/quantize.lua` (`S.lib.quantize`, 3.4, packages 0a and 1f):
- The param `quantize_actions` (option `off`, `beat`, `bar`; default off), added by `add_params()`.
- `schedule(key, fn, label)`: run `fn` now while `quantize_actions` is off (or before the params exist), else at the next beat (`clock.sync(1)`) or bar (`clock.sync(4)`) on a clock of its own; a waiting action of the same key is replaced. With a `label` the header flashes `<label> at beat` or `<label> at bar` (`S.lib.ui_flash`, for one beat or bar at the tempo then) and the flash ends when `fn` runs or is replaced. Returns whether `fn` ran at once. A key that is not a non-empty string or an action that is not a function is an error.
- `waiting(key)`: whether an action of that key waits.
- `actions`: the waiting actions by key, `{clock, flash}` (tests read the clocks here).
- `QUANTIZE`, the module's one table of tunables (`param_count`, `param_id`, `modes`, `beats` per mode).
- The cleanup step `CLEANUP_ORDER.quantize` (97) and the `quantize` invariant.
- Its tests: `test/unit/quantize_test.lua` (the waits, the replacement, the flash, every wrap's flash fitting `HEADER.flash_width` for voice 7 under beat, a failing action, the cleanup, and `strata_seq` alone and as the sequencer's group of seven with a test double for its `add_params`).

## Callers

Design §8.9's keys:
- `freeze<v>`: `S.lib.freeze.toggle_quantized(v)` (label `v<v> frz`, which fits the header flash as `v7 frz at beat`), for the grids' freeze keys (2c points them at it; VOICE's freeze row and a mapped CC set the param and act at once).
- `position<v>`: a grid's position key (`S.lib.positions.grid_key`'s jump and its two-key loop, label `v<v> jump`; a loop replaces the jump its first key left waiting).
- `bookmark<v>`: a grid's bookmark strip key (`S.lib.positions.strip_key`'s recall, label `v<v> bm <n>`) and BUFFER's `bm` field (E3 and ALT+E3, `docs/notes/lua/pages/buffer.md`).
- `scene` (SCENES' keys, the grid's scene keys and the arc button, 1c) and `patterns` (the pattern start, 1d), in their own files.

Not quantized: the scene sequencer, steps (a step's bookmark lock calls `S.lib.bookmarks.recall`, which recalls at once), LFOs, morph, a grid's bookmark store and whole-loop keys, the arc's scrub.
