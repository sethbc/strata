## Must not break

- **Every message goes through `S.lib.io_ii`** (`send`, `send_off`, and `send_direct` in `release` alone). The module reads it at each call: where it is absent, or its params were never added, `routed` is false, `rows` is empty and nothing is sent. `routed` is also false while `S.lib.io_ii.leads()` is not, as Just Friends' and W/'s are, so a voice routed only here is not available under `off` or `teletype`, and the targets core records the device on no note that sent nothing.
- **An output is one line that plays one note at a time, whatever voices feed it** (ruling 10): `lines[output]` holds the sounding notes across voices, oldest first, each with its voice, id, pitch, velocity and the mode it started in. In pitch mode a note's cv is the pitch (`volts`, clamped to -10 to 10); in envelope mode it is `velocity * 5`, and its note on sends cv, `env` 1, `tr` 1. The newest note of the line sounds: when it ends and others remain, the cv goes to the newest left (as that note's own mode says) with no new trigger; the trigger goes low, and the envelope's gate (`env`, when any note on the line raised it), when the line's last note ends, whichever voice it belonged to. A note stays on its output and in its mode until it ends, even if its voice's output or mode changes.
- **An output's envelope is active while at least one voice routed to it is in envelope mode**: `env_act 1`, `env_att` and `env_dec` for each such output (once, however many voices share it) at `ready` and at each change of an output or a mode, only while the bus is led; a change of the attack or the decay sends only its own command (`env_att` or `env_dec`, `TXO.time_commands`), once per active output, so one detent of a turn is one line an output, not three; `env_act 0` goes once, when the last such voice leaves the output or changes mode. `release` sends `env_act 0` through `send_direct` for each active output, once, and forgets them, so a later `ready` sets everything up again.
- **A `note_on` whose send raises leaves the line and the device as they were** (best effort): the bookkeeping is rolled back; then, each send protected (a raise during the repair is swallowed), the newest note left on the line gets its cv sent again (as its own mode says), an envelope gate this note's `env` 1 raised (not high before; only when that send returned) is lowered with `env` 0 (no trigger repair exists: the trigger is sent last, and one whose own send raised was not sent); the send's own error is raised again. The targets core records a target for a note only when its `note_on` returned, so no `note_off` would come for it. An off for a note the line does not hold does nothing.

## Owns

- `lib/io/txo.lua` (`S.lib.io_txo`): `TXO` (every tunable), the note target `txo`, the ii device `txo` (16 params), the rows `txo` (a detail list of output and mode), `txo attack` and `txo decay`, and two layout states carried by its target record (`txo on an output`, `txo detail list open`; the IO page lists them with the `voice` section's, ruling 11). Each sets voice 1's output to 3 (the first also its mode to envelope), then reaches the `txo` row as a player does, through `S.lib.pages_io.go_to_row("txo", "voice", {id = "txo"})`, which raises naming the row (`txo layout: no row id txo in voice`) when the row is not there or the cursor did not land on it, since the other targets' rows come first and push it below the screen. The first leaves the cursor on the row, the second presses K3 to open its detail list. They do nothing where the params were never added.
- Tests: `test/unit/io_txo_test.lua`, against a double of `S.lib.io_ii`.
- User page: `docs/user/io/er301-txo.md`.

## Params

`v<i>_out_txo` (0 off, output 1 to 32), `v<i>_out_txo_cv` (`pitch`, `envelope`) for voices 1 to 7, then `txo_attack` (1 to 10000 ms, 10) and `txo_decay` (1 to 10000 ms, 500): 16, PSET-only.

## Messages

Per `docs/design/3.6-facts/crow-ii.md` section 2 (crow's `lua/ii/txo.lua`, the TELEX README): `cv`, `tr`, `env`, `env_act`, `env_att`, `env_dec`, each `(output, value)`. Outputs 1 to 32 reach across units, four to a TELEXo.

Unverified on the device until the 4.0 hardware check.
