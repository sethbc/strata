## Must not break

- **Every message goes through `S.lib.io_ii`** (`send`, `send_off`, and `send_direct` in `release` alone). The module reads it at each call: where it is absent, or its params were never added, `routed` is false, `rows` is empty and nothing is sent.
- **One note at a time, the newest**, as the ER-301's (`docs/notes/lua/io/er301.md`): the cv returns to the newest left with no new trigger; the trigger (and in envelope mode the envelope's gate, after it) goes low when the last ends. In pitch mode the cv is the pitch (`volts`, clamped to -10 to 10); in envelope mode it is `velocity * 5`, and a note on sends cv, `env` 1, `tr` 1.
- **An off lowers the output and mode its on raised** (`state.high[voice]`), whatever the params say by then (a route change moves them before the off).
- **The envelope is set up only while the bus is led** (`leads()`): `env_act`, `env_att` and `env_dec` for each voice in envelope mode with an output, at `ready` and at each change of an output, a mode, the attack or the decay; an output a voice leaves gets `env_act 0`. `release` sends `env_act 0` for each set-up output through `send_direct` and forgets them, so a later `ready` sets everything up again.
- **Bookkeeping never goes negative or keeps an id that ended**, as the ER-301's.

## Owns

- `lib/io/txo.lua` (`S.lib.io_txo`): `TXO` (every tunable), the note target `txo`, the ii device `txo` (16 params), the rows `txo` (a detail list of output and mode), `txo attack` and `txo decay`, and two layout states added to the targets module's `voice` section (`txo on an output`, `txo detail list open`): a target has no layout hook of its own, so the module appends to the section record's `layout_states` at include time. The states do nothing where the params were never added.
- Tests: `test/unit/io_txo_test.lua`, against a double of `S.lib.io_ii`.
- User page: `docs/user/io/er301-txo.md`.

## Params

`v<i>_out_txo` (0 off, output 1 to 32), `v<i>_out_txo_cv` (`pitch`, `envelope`) for voices 1 to 7, then `txo_attack` (1 to 10000 ms, 10) and `txo_decay` (1 to 10000 ms, 500): 16, PSET-only.

## Messages

Per `docs/design/3.6-facts/crow-ii.md` section 2 (crow's `lua/ii/txo.lua`, the TELEX README): `cv`, `tr`, `env`, `env_act`, `env_att`, `env_dec`, each `(output, value)`. Outputs 1 to 32 reach across units, four to a TELEXo.

Unverified on the device until the 4.0 hardware check.
