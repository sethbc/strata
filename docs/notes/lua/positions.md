## Must not break

- **A jump** (`jump(v, p)`): inside the voice's loop (`loop_start - 1e-6 <= p < loop_start + loop_length - 1e-6`, since the params return values a rounding away from a cell's fraction) `buf_pos` becomes `(p - loop_start) / loop_length`; outside, `loop_start` 0, `loop_length` 1 and `buf_pos` p. Everything but the reset goes through `params:set`, then `setGrainParam(v - 1, "t_scanReset", 1)` while the voice runs, the glide ends and the playhead resets. Only buffer voices respond; a stopped voice's position still changes and sends nothing.
- **A restart alone** (`restart_scan(v)`, 3.7: a scan mode change, `lib/scan.lua`): `setGrainParam(v - 1, "t_scanReset", 1)` to a running buffer voice, then the playhead's reset; nothing else moves (no param, no glide).
- **Every jump and bookmark recall enters through `jump` and `recall_bookmark`**, from the grid, the arc and BUFFER alike (the grid's keys and BUFFER's `bm` field through their quantized wraps, below), so each sends `t_scanReset` only while the voice runs.
- `set_loop(v, a, b)` sets `loop_start`, then `loop_length`, then jumps to a (the order the loop clamps need, `docs/notes/lua/loops.md`).
- **Only the grid's keys wait for the beat or bar** (3.4, `docs/notes/lua/quantize.md`): `grid_key`'s jump and two-key loop go through `S.lib.quantize.schedule("position<v>", ...)`, one-line wraps at the call sites, and `strip_key`'s recall through `recall_bookmark_quantized(v, n)`, which BUFFER's `bm` field calls too: it schedules `bookmark<v>` (a buffer voice and a bookmark 1..`NUM_BOOKMARKS` only) and passes the bookmark as the action's detail, so `waiting_bookmark(v)` (`S.lib.quantize.waiting_detail("bookmark<v>")`) names the bookmark that waits while an action waits (nil once it ran or another replaced it); the jump and the loop pass `{voice = v, cell = c}`, the cell pressed (#876); the held-key bookkeeping (`record.held`, the grid voice selection, store) still happens at the press. `jump`, `set_loop`, `recall_bookmark` and `S.lib.bookmarks.recall` themselves never wait: a step's bookmark lock reaches them and must never wait for a bar.
- **The scan hold, the glide's rate and the last recalled bookmark are transient**: never params, scenes or PSETs. The `bookmarks` record's `sync` empties the voice's holders and sends `scrubRate 0` and `scanHold 0` in every voice sync (after the source), so a started voice never inherits a glide or a hold, even one whose grid key is still down (its LED goes dim). Anything else that changes the hold or the rate calls `S.lib.playheads.advance(v)` first; the sync does not, since it relies on the grain-restart hooks, which reset the playhead (`S.lib.playheads.reset`) at every grain restart (a start runs them after its `voiceOn`, just after the sync it sends before `voiceOn`, and a running voice's source switch runs them in `send_grain_source` before its sync).
- **The scan hold has holders** (#238): a set per voice (`"grid:<port>"` for each grid port, `"arc"` for BUFFER's ALT ring 1, `"caller"` by default), and the voice is held exactly while its set is not empty (the `"scan holds"` invariant). `scanHold 1` goes out when the first holder joins, `scanHold 0` when the last one leaves, so one holder's release never ends another's hold. Only a buffer voice gains a holder; a release counts whatever the voice's source is now; a release by a holder not in the set changes nothing. Change the hold only through `hold_scan(v, on, holder)` (the cleanup step does too, once per holder); the `bookmarks` record's `sync` is the one other place, and it empties the set. Every change of the hold (`set_scan_hold`) calls `grid_redraw()` and `request_redraw()`, so each grid's hold key and BUFFER's ALT ring 1 (#934) show it whoever changed it: another grid's key, the arc, a grid that left (released by the playhead tick) or cleanup.
- **A grain restart ends the glide** (`S.register_grain_restart`), so does a jump or a new ring turn. A source switch forgets the last recalled bookmark (`S.register_source_change`).
- **One glide clock per run of turns** (#515): `scrub_turned` starts a clock only when the voice has none; a running one reads the voice's latest turn (`fling[v].turned_at`) and waits until the ring has been still for `SCRUB.release_seconds`, so a run of deltas starts one clock, never one per delta. A turn during the glide sets the rate to 0 at once and sends the same clock back to waiting. Anything that ends a glide for another reason (`end_glide`, a grain restart, a voice sync) stops the clock through `S.lib.clocks.stop` (3.9, #870: one whose wake may be posted retires and ends at that wake, its sleep returning false, so its body returns touching nothing a newer glide owns) and forgets `fling[v]`; the cleanup step cancels it (`S.lib.clocks.cancel`). Every sleep of the glide's body is its handle's (`handle.sleep`), never a bare `clock.sleep`, and the file calls no `clock.cancel` (`docs/notes/lua/clocks.md`).
- **The row context cache is keyed by what a cell's level reads, never by the time** (#398): the key holds the loop, the head and record cells, the slot's seconds and the held cells, and the cache also compares the peaks table's identity (`S.lib.waveforms.peaks(slot)`, replaced only when the peaks change). The device's clock moves between two calls, so a time comparison never hits there.
- **A voice that reads no buffer has a dark strip** (#445): `strip_level` returns 0 for every key, and a press on its strip (`strip_key` with `z` 1) records no store, hold or pressed bookmark; releases still end what they ended before.
- **The glide's clock never dies of an error** (#517): its two steps (`start_glide`, `decay_glide`) run through the frame's `S.lib.ui_frame.contained_call`, the sleeps outside it. An error prints `strata: scrub glide failed:` with its traceback, once per distinct message per voice (a good step forgets it), and the glide runs on while its rate is not 0, so a failed send never leaves the engine gliding with no clock to end it.
- **A held grid key lives in `S.lib.grid_core.port_state(port).positions`** (the held position key with its pane and `still`, the hold, store and pressed-bookmark keys per voice, and 3.7's slice keys and banks). It ends within a playhead tick (the port lets go of its hold, `"grid:<port>"`, and the held key is dropped) when the state is gone (the grid was removed) or the press's `still` says false; a key event checks it first too. Never keep a held key anywhere else (`records` here only finds the state again). The stale-port check reads the state with `S.lib.grid_core.existing_port_state(port)`, never `port_state` (which would create an empty state for a port whose grid left).
- **Each press record keeps its pane and its `still`** (3.8, then 3.9's #865): `grid_key` and `strip_key` take the pane the key is on (1 by default) and the press's `still` (their last argument, after the pane), a function that says whether the key is still held. The grid page builds it from the grid core's key roles (`pane.press_as(x, y, "positions")` at the press, `pane.pressed_as` in it), which the core clears at the key's release, a new press, its pane's page, side or half change, the 64's chooser opening (whose keys' releases reach no page) and the port's forget, so one test covers every way a release is lost. Every record they make (`held`, a slice key's entry, and the panes holding a voice's store and hold) keeps it, and `end_stale_port` ends an entry whose `still()` is false. A nil `still` (a direct call, as most tests make) is always true: such a record ends only at its release or when its port goes. No record keeps a view, and positions never reads `grid_core.view` (#851's opaque view is gone with it). `store[v]` and `hold[v]` are sets of panes (`{[pane] = still}`), since both panes of a 256 can show voice v's keys: a release or a stale `still` takes out its own pane, and the key ends (the store's pressed bookmark cleared, the port's hold released) only when the set is empty, so one pane's release or page change never ends the key the other pane still holds. So a key held on a 256's bottom pane lives through the top pane's page changes and ends with its own pane's page, side or half change (a 64's half and its chooser too), never reading `grid_core.page(port)`, which is pane 1's.
- **Every strip is one voice's** (3.8, ruling 56: every layout's lines are one voice each, so 0e removed the one-strip code, `selects_grid_voice`, `rows_show_grid_voice` and `store_down`): store, hold and each bookmark key are per voice (`store[voice]`, `hold[voice]`, `pressed[voice]`), and a release ends only its own voice's key. `hold` calls `hold_scan(v, false, "grid:<port>")` for its voice; a store release clears that voice's store and pressed bookmark.
- **Each grid's strip LEDs are its own**: every layout's redraw passes its port to `strip_level`, so `"store"` and a stored bookmark show only that port's keys (a 256 beside a 128h never lights the other's store); without a port (the playhead clock's `display_signature`) they read any port's.
- Bookmarks are one registered voice-param record (`bookmarks`, count 4, `fader = false`): continuous scene fields (`scene_ranges` 0-1 each, so a scene outside it is rejected), defaults 0, 0.25, 0.5, 0.75 (also what `fill_scene` gives a scene that lacks them), PSET-safe in any order (nothing reads them in a filter), never touched by MAIN's randomize or mutated, never on the fader pages. A quick ALT+K2 on VOICE's bookmarks section is the one exception (#557): the record's `randomize` (`randomize_draws`) gives four uniform 0-1 positions in ascending order. VOICE draws them in row order, each set before the next is drawn, so bookmark n reads bookmark n - 1's new value and draws the lowest of the `NUM_BOOKMARKS - n + 1` uniform positions left above it: `1 - (1 - previous) * u ^ (1 / left)` (bookmark n averages n / 5).
- `scrub_friction` is `controlspec.new(0, 100, "lin", 0, 100, "%", 0.01)` in the group `strata_positions` (step 0, quantum 0.01); it is not a scene field.
- **A slice row plays slices and never jumps** (3.7, design §10): while `slice_row(v)` (`S.lib.slices.takes_notes(v)`), a row's key plays slice `(bank - 1) x 16 + cell` only through `S.lib.slices.play(v, n, {owner = "grid", key = port x 100 + n, velocity = 1})`, inside `S.lib.quantize.schedule("position<v>", ...)`, and its release (or its grid's page change or removal, at the next tick) calls `S.lib.slices.note_off(v, "grid", port x 100 + n)` for the slice the press played, whatever bank shows by then. A play that still waits is taken back (`S.lib.quantize.cancel`), except in one shot with a moving scan (`S.lib.scan.pass_seconds` gives a number), where it plays at the beat and its note off follows the play. A voice with the option off, or no slices, keeps every position cell and strip key exactly.
- **The bank is the port's and transient**: `port_state(port).positions.bank[v]`, never a param, scene or PSET; `bank(port, v)` reads 1 when the slot's slices no longer reach the pick's first slice, and a bind of the voice's slot (`S.lib.samples.on_bind`, whose listener goes in at the first pick) forgets such a pick, as does a slice key's or a bank key's press that reads it (`read_bank`), so a pick never comes back when the slices reach it again (markers deleted and added back). The listener only changes state.
- **A slice key's release ends the slice it played for the voice it was pressed for** (2e's review): each release names its own voice (two lines can hold the same cell), and a position key's release ends that voice's held key of that cell (#733), so no stale anchor stays lit at 11 or makes the next press a loop.
- **`display_signature()` holds every slice row's levels and bank keys**, for no port and for each port with a record, so the playhead clock repaints a slice that starts or ends (S.lib.slices' notes end on their own) and each grid's own bank.

## Machines

### scan hold
- **State:** per voice, `holders[v]` (a set of holders: `"grid:<port>"`, `"arc"`, `"caller"`) and `scan_hold[v]` (locals of `lib/positions.lua`), read with `S.lib.positions.scan_held(v)` and `holds_scan(v, holder)`; the port records' `hold` only remember which voices a port holds.
- **Invariant:** `scan holds`: a voice's scan is held exactly while its set of holders is not empty (`scan_hold[v]` true with one or more holders, false with none; #238's one boolean behind several holders).
- **Test:** `test/unit/positions_test.lua`: "scan hold: every cell is decided" and its rows (voice 3, a stopped buffer voice, so a start is its voice sync; the holders a grid on port 1 and the arc).

Every cell is a row. `scanHold 1` goes out when the first holder joins and `scanHold 0` when the last one leaves, while the voice runs; the cleanup step `scrub_glide` lets every holder go through `hold_scan`.

| State | Event | Next | Effect |
|---|---|---|---|
| `free` | `grid holds` | `grid` | the first holder: held (`scanHold 1` while running) |
| `free` | `grid lets go` | `free` | a holder not in the set: nothing |
| `free` | `arc holds` | `arc` | the first holder: held |
| `free` | `arc lets go` | `free` | nothing |
| `free` | `voice start` | `free` | the sync sends `scanHold 0` |
| `grid` | `grid holds` | `grid` | already a holder: nothing |
| `grid` | `grid lets go` | `free` | the last holder: not held (`scanHold 0` while running) |
| `grid` | `arc holds` | `grid and arc` | another holder: nothing is sent |
| `grid` | `arc lets go` | `grid` | not a holder: nothing |
| `grid` | `voice start` | `free` | the sync empties the set and sends `scanHold 0` (the key's LED goes dim while it is down) |
| `arc` | `grid holds` | `grid and arc` | another holder: nothing is sent |
| `arc` | `grid lets go` | `arc` | not a holder: nothing |
| `arc` | `arc holds` | `arc` | already a holder: nothing |
| `arc` | `arc lets go` | `free` | the last holder: not held |
| `arc` | `voice start` | `free` | the sync empties the set |
| `grid and arc` | `grid holds` | `grid and arc` | nothing |
| `grid and arc` | `grid lets go` | `arc` | one holder's release never ends another's hold: nothing is sent |
| `grid and arc` | `arc holds` | `grid and arc` | nothing |
| `grid and arc` | `arc lets go` | `grid` | nothing is sent |
| `grid and arc` | `voice start` | `free` | the sync empties the set and sends `scanHold 0` |

### scrub glide
- **State:** per voice, `glide_clock[v]` (the clock helper's handle), `fling[v]` (`{turned_at, gliding}`, while the clock runs) and `glide_rate[v]` (as sent, `scrubRate`; read with `S.lib.positions.scrub_rate(v)`), locals of `lib/positions.lua`: idle (no clock), waiting for the ring to be still (a clock, rate 0) or gliding (a clock and a rate).
- **Invariant:** `scrub glide` (3.9, #907): a voice's glide rate is not 0 only while its clock runs; a rate with no clock would leave the engine gliding for good.
- **Test:** `test/unit/positions_test.lua`: "scrub glide: every cell is decided" and its rows (voice 1, running, at friction 0; its state read from the module's `glide_clock`), and "the scrub glide invariant: a glide's rate only with its clock (#907)".

Every cell is a row. A grain restart and a voice sync end a glide as a jump does (Must not break, above).

| State | Event | Next | Effect |
|---|---|---|---|
| `idle` | `a turn` | `waiting` | one clock starts for the run of turns |
| `idle` | `the ring still` | `idle` | nothing |
| `idle` | `a jump` | `idle` | nothing to end |
| `idle` | `a direct turn` | `idle` | friction 100%: the ring is direct |
| `waiting` | `a turn` | `waiting` | the same clock waits again from this turn (#515) |
| `waiting` | `the ring still` | `gliding` | still for `release_seconds`: the ring's speed is sent |
| `waiting` | `a jump` | `idle` | the clock stops (`S.lib.clocks.stop`) |
| `waiting` | `a direct turn` | `idle` | the clock stops; the turns are kept |
| `gliding` | `a turn` | `waiting` | `scrubRate 0` at once; the clock waits again |
| `gliding` | `the ring still` | `gliding` | the rate decays with the friction |
| `gliding` | `a jump` | `idle` | `scrubRate 0`; the clock stops |
| `gliding` | `a direct turn` | `idle` | `scrubRate 0`; the clock stops |

## Owns

`lib/positions.lua` (`S.lib.positions`): moving a voice's read position.

**Jumps and bookmarks.** `jump`, `set_loop`, `recall_bookmark` (a jump to the bookmark; `last_recalled(v)` becomes n, remembered with the voice's source, and reads nil once the voice's source differs, stopped or not, so a scene recall forgets it too), `store_bookmark(v, n)` (the playhead, or `buf_pos` mapped into the loop when the voice is not running), `bookmark(v, n)`, `hold_scan(v, on, holder)` (a holder joins or leaves the voice's set; `setGrainParam(v - 1, "scanHold", 1 or 0)` when the set stops or starts being empty, sent while running; see States), `holds_scan(v, holder)` (whether that holder is in the voice's set; false for a bad voice: the arc rejoins by it). `scan_held(v)` and `scrub_rate(v)` are what `S.lib.playheads` reads.

**The glide.** `scrub_turned(v)` is called by the arc's ring 1 after each turn of the voice's `buf_pos` (BUFFER's arc, 2b). It ends a running glide, records `buf_pos` with the time, and (unless `scrub_friction` is 100%, the ring is direct) starts a clock, or tells the voice's running one about the new turn (#515): after `SCRUB.release_seconds` (0.08 s) with no new turn, the speed over the last `SCRUB.window_seconds` (0.1 s), in loop fractions a second, is sent as `scrubRate` and decays every `1 / PLAYHEADS.update_hz` by `exp(-dt / tau)`, `tau = SCRUB.max_glide_seconds x (1 - friction / 100)` (4 s at 0%). Below `SCRUB.stop_rate` (0.001) it sends 0 and ends. The cleanup step `scrub_glide` (`CLEANUP_ORDER`, 124) stops every glide and releases every holder of every scan hold (one `scanHold 0` per held voice).

**Grid.** The grid's positions page (`lib/grid/pages/positions.lua`, `docs/notes/lua/grid/pages/positions.md`) calls these with the pane of each key: side 1 the cells, side 2 the marks. `grid_key(port, v, cell, cells, z, pane, still)`: a press jumps to `(cell - 1) / cells`; with another key of the same voice's row held, it sets the loop `[(lo - 1) / cells, hi / cells]` (the second key is not remembered as held, its release does nothing). Only buffer voices respond. A position press never selects the grid voice (3.8: every layout's lines are one voice each).
`grid_level(v, cell, cells, port)` (design 3.3 section 9; the port matters to a slice row only): 0 for a voice that is not a buffer voice or whose slot reports 0 s (`S.lib.playheads.has_audio`, the check BUFFER's heads read too, so the two never disagree, #433); the voice's playhead cell 15 (a stopped voice shows where it will start: `buf_pos` mapped into its loop), the record head's 13, a held key 11, then 4 + round(peak x 4) in the loop (the cell's middle inside `[loop_start, loop_start + loop_length)`) or 1 + round(peak x 2) outside, from `S.lib.waveforms.bins(slot, cells)` (no bins: peak 0).
`strip_key(port, v, key, z, pane, still)` and `strip_level(v, key, port)`: keys 1-4 recall (store held: store the playhead, level 15 while pressed), 6 otherwise and 10 for the last recalled; `"store"` 15 held, 4 otherwise (both from the port's own record when `port` is given, any port's otherwise); `"hold"` 15 while the voice's scan is held (`scan_held(v)`, whoever holds it: another grid or the arc lights it too, and a voice sync dims it while the key is down), 4 otherwise (the key is momentary: it holds as `"grid:<port>"` while down; `record.hold[v]` stays the port's record of the voices it holds, for the release sweep and the stale-port end); `"whole"` sets the loop back to the whole slot with no jump, level 15 when it is, 4 otherwise. A voice that reads no buffer gets 0 for every key and records no press (#445).
A bookmark key that waits (`waiting_bookmark(v)`) shows `LEVELS.waiting_high` / `waiting_low` (15 / 2), alternating every `LEVELS.waiting_ticks` (4) ticks of the playhead clock (`S.lib.grid_core.waiting_level()`, whose ticks the clock's `blink` part counts through `blink_tick()`; the clock is the only timer, #593; every waiting key blinks so since #876): no steady level is clear of 6, 10 and 15 on a varibright grid. A stored key still shows 15 first. The blink moves the signature only while a bookmark waits. A wait's repaints go to every connected grid while any grid shows the page (`grid_redraw()` repaints them all, as for every signature change). A position cell whose jump or loop waits (`waiting_cell(v)`, the cell of `waiting_detail("position<v>")`, nil for a slice's play) blinks the same way once its key is up (a held key shows `held` first); its repaints are the grid core's `blink_tick` (`docs/notes/lua/grid-core.md`), only while a pane shows the cells, since the display signature leaves the blink out. The blink's levels are the grid core's (`S.constants.GRID_LEVELS`); `LEVELS.waiting_*` here name the same values.

`display_signature()`: every LED level a positions page shows (both sides) plus the bookmark values, as one string; the playhead clock redraws when it changes (`docs/notes/lua/playheads.md`).

**Slice rows** (3.7, design §10, decision 13). `slice_row(v)` is `S.lib.slices.takes_notes(v)`: a buffer voice whose `slices` option is not off and whose slot has slices (false while `S.lib.slices` is absent). For such a voice, on a row of 16 cells (`SLICE_ROW.bank_size`, the position page's `GRID_PAGES.position_cells`):
- `grid_key(port, v, cell, 16, z)`: the cell's slice `n = (bank(port, v) - 1) x 16 + cell` plays, as above, or nothing when `n` is past `S.lib.slices.count(slot)`. The held key is `record.slices[v][cell] = {n, pane, still, token, released}`, so the release ends the slice it played. A second press of the voice replaces a play that still waits (one quantized action per voice, `position<v>`), and the replaced key's release sends its note off, which ends nothing.
- `grid_level(v, cell, 16, port)`: 15 (`LEVELS.slice_playing`) for a slice in `S.lib.slices.playing(v)`, 11 (`slice_held`) for a slice key the port holds (with no port: any port's), 9 (`slice`) for a slice that exists, 0 (`slice_none`) past the count. Every layout passes its port, since each grid shows its own bank.
- `strip_key(port, v, 1..4, 1)` picks the bank (`bank` in the port's record, 1 by default), store held or not; a bank whose first slice is past the count is not picked. Releases, `store`, `hold` and `whole` are as before. `strip_level(v, 1..4, port)`: 15 (`bank_shown`) for the port's bank, 4 (`bank_filled`) for a bank that holds slices, 0 (`bank_empty`) otherwise.
- Bookmarks are then recalled from BUFFER's `bm` field and from steps' bookmark locks, which never go through the strip.

**Params.** `add_params()` (the `positions` record in `lib/params_setup.lua`, after `buffers`): `scrub_friction`. The `bookmarks` record adds `v<i>_bookmark_1..4` (three decimals) and VOICE's `bookmarks` section for a buffer voice; its `layout_states` put each voice on buffer 1 with the cursor on bookmark 1.

## States

The scan hold and the glide are the Machines entries above. The last recalled bookmark, per voice (`recalled[v]`, a local of `lib/positions.lua`):

| `recalled[v]` | Meaning |
|---------------|---------|
| nil | no mark |
| `{bookmark, source}` | `recall_bookmark` ran with the voice on `source`; `last_recalled(v)` returns the bookmark only while `S.voices[v].source` is still `source` |

Transitions: `recall_bookmark(v, n)` sets it; the grain-restart and source-change hooks clear it; a source changed any other way (a scene recall of a stopped voice) hides it through `last_recalled` (and shows it again if a later recall brings the source back: the mark shows only while the voice has the source it was recalled on).

A strip's store, per port (the port's record in `S.lib.grid_core.port_state(port).positions`):

| `store[v]` | Meaning |
|------------|---------|
| nil | voice v's store up: a bookmark press recalls |
| a set of panes (each pane whose key is down, mapped to its press's `still`) | voice v's store down: a bookmark press stores for v |

Transitions:

| From | To | Function |
|------|----|----------|
| up | down | `strip_key(port, v, "store", 1, pane, still)`: the pane joins `store[v]` |
| down | down | another pane's press joins, or a release or a stale `still` leaves with a pane left |
| down | up | `strip_key(port, v, "store", 0, pane)` by the last pane, or `end_stale_port` (the grid is gone, or the last pane's `still` says false: its page, side or half changed, or the 64's chooser opened): `store[v]` and `pressed[v]` cleared |

Tests: `test/unit/positions_test.lua`.
