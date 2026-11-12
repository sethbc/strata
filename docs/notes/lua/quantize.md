## Must not break

- A user action that 3.4 quantizes (a scene recall from a key, a freeze toggle from a key, a bookmark recall or position jump from a key, the pattern start) goes through `S.lib.quantize.schedule(key, fn, label)`, never its own `clock.sync`. A step's bookmark lock and the functions themselves (`S.lib.positions.jump`, `recall_bookmark`) are never wrapped: a step never waits for a bar (design §8.9, plan item 12).
- Until package 1f adds the `quantize_actions` param, `schedule` runs `fn` at once and returns true, `waiting` is false, `add_params` adds nothing and `PARAM_COUNT` is 0, so every caller behaves as 3.3 did.
- `PARAM_COUNT` is the number of params `add_params` adds: `lib/sequencer.lua`'s `strata_seq` group counts it in its size and calls `add_params` for its fifth param (plan item 11), so either package can land first.

## Owns

`lib/quantize.lua` (`S.lib.quantize`, 3.4, package 0a; 1f fills it):
- `schedule(key, fn, label)`: run `fn` now or, from 1f, at the next beat or bar (`clock.sync(1)` or `clock.sync(4)`), a new action of the same key replacing a waiting one and the header flashing `label` (`S3 at bar`). Returns whether `fn` ran at once. A key that is not a non-empty string or an action that is not a function is an error.
- `waiting(key)`: whether an action of that key waits.
- `add_params()` and `PARAM_COUNT`: the scheduler's params (none in Wave 0).
- `QUANTIZE`, the module's one table of tunables (`param_count`; 1f adds the modes and their beats).
- Held for 1f: the cleanup step `CLEANUP_ORDER.quantize` (97), which cancels every waiting action.

## Callers

Design §8.9's keys: `scene` (SCENES' keys, the grid's scene keys and the arc button, 1c), `freeze<v>` (`S.lib.freeze.toggle_quantized`, the grids' freeze keys, 1f and 2c), `bookmark<v>` and `position<v>` (BUFFER's keys and the grids' position and strip keys, 1f), `patterns` (the pattern start, 1d). Not quantized: the scene sequencer, steps, LFOs and morph.
