## Must not break

- **The table below is the test's** (`test/unit/buffers_slot_test.lua`, 3.9, #903): "buffer slot: the notes' table equals these rows" compares its State, Event and Next cells with the test's rows, and "buffer slot: every cell is decided" fails on a pair of a state and an event that is neither a row nor one of the impossible pairs below. A row changes in both at once, and a new state or event comes with every one of its cells decided.
- **The states are the slot's status, split by fields that exist** (`S.lib.buffers.status(slot)`, `docs/notes/lua/buffers.md`, States): the table adds no field, and no code reads it. Six of status's cases have sub-states, each read from a field or the slot's clock: `empty` (`kept_state`, `settled_empty == "take"`), `loading` (`checking_from`, and whether it is 0, `awaiting_zero`, `restoring`, whether it tracks any load, `pending_loads`, and for a restore with none whether the engine reported a length, `seconds`), `armed` (the take's `kind`, a replace take's `unbound`: the engine has emptied the slot; a playable one's clock role `"fallback"`: K3 has stopped it), `dub` and `loop` (the clock role `"fallback"`) and `finishing` (the take's `phase`). Where one name would cover two behaviors, the name is split: a state's name decides its row.
- **An impossible pair is impossible in the code**, by any way in (a key, a param, a grid key, MIDI, a scene, a PSET read, a late engine report, a timer), never only in the history a state's entry happens to make.
- This file is the machine's table only: the slot's rules are `docs/notes/lua/buffers.md`'s and `docs/notes/lua/record.md`'s, and its Machines entry (`buffer slot`, the invariant `buffer slots`) is in `docs/notes/lua/buffers.md`.

## The table

### buffer slot

Slot 1 in every row. Most states start from the same history (`prelude`): a file loaded and reported (4 s), a replace take of it recorded (its "recording" report heard), stopped and settled from its 2 s length, then a load (number 2) that the clear right after forgets while it is in flight. The restoring states and `missing` start from a fresh script instead, as init's restore does. Each state is then entered by the script's own calls and the engine stub's reports, in the engine's order:
- `empty`: the prelude. `empty, kept state awaited`: `a.wav` loaded (4 s), a take synced to the beat (`record_sync` 2) stopped while armed, then its "canceled". `empty, adoptable`: a replace take whose timer ran out, then a 0 s report past `confirm_seconds`.
- `loading`: two loads sent into the empty slot. `loading, no load tracked`: `a.wav` into the empty slot, then four missing files, rejected in the order sent: the last one's undo gives `a.wav` back, its own load forgotten in flight. `loading, zero awaited`: two loads over `a.wav`. `loading, checking`: two long files (120 s) over `a.wav` on a high tier's slot (`S.performance.buffer_seconds` 300, set through `S`: the tier is read at load, before a state is entered), `checking_from` 4. `loading, checking, empty before`: the two long files into the empty slot, `checking_from` 0. Only long2's 0 s ends either check (#983). `loading, checking, given back` and `loading, checking, empty before, given back`: the same over `a.wav`, or over `z.wav` still loading, then long2's failure, which gives long1's check back; long2's number now names every load up to it, so any report of it ends the check (long1's own 0 s may have come before long2 reached the engine). Split because a report of audio ends them.
- `loading, restoring` and `loading, checking, restoring`: `buffers.data` naming a file (a long one on the high tier for the second), read with `load_buffers_from_disk()` on a fresh script, as init's start step runs it; the restore's own load is tracked. `loading, checking, restoring, given back`: the restore's check, then a bad load whose failure gives it back (any report then ends it). `loading, restoring, no load tracked`: the restore, then four bad loads, the fourth pushing the restore's own out of the list (`BUFFER_SETTLE.tracked_loads`), failing in the order sent: the last one's undo gives the restore back at 0 s, its own load forgotten in flight. `loading, restoring, no load tracked, audio known`: the restore, then (past `confirm_seconds`) a take synced to the beat during which the restore's audio is reported (6 s), then a bad load that cancels the take (engine row 9) and fails: the take had not prepared the slot, so the restore it replaced comes back with the length known, and the recording had emptied the tracked loads (a replace take's fallback after K3 while armed gives back the same, #974). The restores are split because their rows differ: a tracked restore's load can fail and undo it, with no recording seen; with no load tracked at 0 s the forgotten load can still fail (#980) and a load waits for no 0 s; with its audio known the load took effect, a load waits for its 0 s, and the canceled take's late reports can come.
- **Three restoring states cannot be reached, so they are not in the table** (`state_of` names them, and a row that entered one would fail): `loading, zero awaited, restoring` (`awaiting_zero` is set only by `load_buffer`, from the length shown, and `restoring` only by init's restore right after its `load_buffer`, when every slot shows 0 s, or by `apply_buffer_state`, which clears `awaiting_zero`), and a restore's check over audio, `loading, checking over audio, restoring` (`checking_from` is the length shown at the load, 0 at init, and `apply_buffer_state` gives back only a state a load replaced), and a restore's check with no load tracked, `loading, checking, restoring, no load tracked` (#980: a load being checked, the slot's `checking_load` or one a tracked load's state would give back, is never dropped from the tracked list while it is, and does not count in its bound; a clear or a recording, which empty the list, end the check, and what a canceled take gives back is never a check; so four bad loads after the restore's check give back `loading, checking, restoring`, its own load still tracked).
- `armed, unprepared`: a replace take synced to the beat over `a.wav`; `armed, prepared`: one armed by a threshold (`record_threshold` 2), which the engine empties at the send; `armed, playable`: a dub (`record_feedback` 50) armed by a threshold; `armed, playable, stopped`: the same after K3 (its fallback waits).
- `recording`: a replace take with no delay. `dub`: a dub over `a.wav` with a length (its timer runs). `dub, stopped`: the same after K3 (its fallback waits). `loop` and `loop, stopped`: a loop recording (`record_loop` 2) over `a.wav`, before and after K3.
- `finishing, recorded`: a replace take whose timer ran out (0 s known). `finishing, stopped armed`: a synced take over `a.wav` stopped with K3 while armed.
- `loaded`: `z.wav` then `a.wav` sent back to back, then a.wav's 4 s; both loads stay tracked. `unsettled`: the same two loads, then a 0 s report past `confirm_seconds`. `missing`: `buffers.data` naming a file that is not there, read on a fresh script, then a load over it whose failure puts it back.

The events, each the script's call or the engine's report of the slot as it is now:
- `load_buffer`, `clear_buffer`, `record_buffer`: the call (`/tmp/next.wav`, a file with no info, never checked; `record_buffer` with the record params at their defaults, a replace take with no delay, outside the recording states, and K3 in them).
- `take timer`, `the fallback`, `the notice`: the slot's clock wakes, in the role `"take"`, `"fallback"` or `"notice"` (`S.lib.record.clock_role`). The notice wakes once a check: after it the slot is still checking, with no clock left to wake.
- `recordState armed`, `recording`, `ended`, `canceled`: the report of the slot's newest recording (`records_sent`). In a state that holds no take it is the late report of a take a load, a clear (engine rows 12, 13), a settle or a fallback ended, and is ignored. Where a state's own way in sent no recording of that number (the prelude's take settled, so its "canceled" would not come; `loading, restoring, no load tracked, audio known`'s take was canceled, so its "ended" would not), the report is of the same number as one that other ways in leave late: the code drops both alike (`record_state_changed` finds no take).
- `bufferState audio`: 6 s, numbered with the newest load; `bufferState 0 s`: 0 s, inside `confirm_seconds` of the state's `confirm_since` (a row whose next state depends on a later 0 s moves the clock on in its check), but past it in `loading, restoring, no load tracked, audio known`, whose `confirm_since` is the restore's own and whose only 0 s comes after #974's fallback, 5 s after a stop; `another load's number`: 7 s, numbered with the load before the newest (ignored whatever its length, but its seconds where that load is a given-back check, #1016).
- `bufferLoadFailed newest`, `older`, `untracked`: the failure of the newest load the slot tracks (the last of `pending_loads`: its undo is applied), of the one tracked before it (spliced into the next one's `previous`), or of a load the slot does not track (nothing): the prelude's, forgotten in flight, or the restore's own in the no-load restore at 0 s, or `a.wav`'s in `loading, no load tracked`, emptied (the rejections changed nothing): `buffer_load_failed` finds no entry for any.
- `takeWriteFailed`: the failure of the newest recording's scratch write.

**The reported length is not in a state's name.** A row's next state can carry a length other than its entry's (a stale report of audio on an empty slot, a 0 s report on a loaded one, a failed load's undo over audio); only whether the next `load_buffer` waits for its 0 s depends on it.

The engine's rows of a recording (`docs/notes/engine/record.md`, The state table) are named in the Effect column beside the rows they pair with. An Effect cell of "ignored" or "nothing" is the event's own meaning in the list above: a late report of a take (engine rows 12, 13), a report of an older load (#578), a failure of a load the slot does not track, a write failure of no take the slot holds.

| State | Event | Next | Effect |
|---|---|---|---|
| `empty` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `empty` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `empty` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `empty` | `recordState armed` | `empty` | ignored: a late report |
| `empty` | `recordState recording` | `empty` | ignored: a late report |
| `empty` | `recordState ended` | `empty` | ignored: a late report |
| `empty` | `recordState canceled` | `empty` | ignored: a late report |
| `empty` | `bufferState audio` | `empty` | the length only (a report sent before the clear): nothing settles |
| `empty` | `bufferState 0 s` | `empty` | nothing |
| `empty` | `another load's number` | `empty` | ignored (#578) |
| `empty` | `bufferLoadFailed untracked` | `empty` | ignored: untracked |
| `empty` | `takeWriteFailed` | `empty` | nothing: no such take |
| `empty, kept state awaited` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `empty, kept state awaited` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `empty, kept state awaited` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `empty, kept state awaited` | `bufferState audio` | `loaded` | the take never prepared the slot: what it replaced comes back, bound (engine row 6) |
| `empty, kept state awaited` | `bufferState 0 s` | `empty` | the kept state is dropped; unbound (engine row 7) |
| `empty, kept state awaited` | `another load's number` | `empty, kept state awaited` | ignored (#578) |
| `empty, kept state awaited` | `bufferLoadFailed untracked` | `empty, kept state awaited` | ignored: untracked |
| `empty, adoptable` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `empty, adoptable` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `empty, adoptable` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `empty, adoptable` | `recordState recording` | `empty, adoptable` | ignored: the take has settled |
| `empty, adoptable` | `recordState ended` | `empty, adoptable` | ignored: the take has settled |
| `empty, adoptable` | `recordState canceled` | `empty, adoptable` | ignored: the take has settled (a K3 before its arming reply, settled by a 0 s report or its fallback before the cancel arrived) |
| `empty, adoptable` | `bufferState audio` | `loaded` | the late take is adopted: `take <n>`, bound |
| `empty, adoptable` | `bufferState 0 s` | `empty, adoptable` | nothing |
| `empty, adoptable` | `another load's number` | `empty, adoptable` | ignored (#578) |
| `empty, adoptable` | `bufferLoadFailed untracked` | `empty, adoptable` | ignored: untracked |
| `empty, adoptable` | `takeWriteFailed` | `empty, adoptable` | `take_unsaved`: a later adoption has no path |
| `loading` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `loading` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `loading` | `recordState armed` | `loading` | ignored: a late report |
| `loading` | `recordState recording` | `loading` | ignored: a late report |
| `loading` | `recordState ended` | `loading` | ignored: a late report |
| `loading` | `recordState canceled` | `loading` | ignored: a late report |
| `loading` | `bufferState audio` | `loaded` | settled: loaded, bound |
| `loading` | `bufferState 0 s` | `loading` | inside `confirm_seconds`: nothing (a later 0 s settles it `unsettled`) |
| `loading` | `another load's number` | `loading` | ignored (#578) |
| `loading` | `bufferLoadFailed newest` | `loading` | the load before it comes back (still loading) |
| `loading` | `bufferLoadFailed older` | `loading` | spliced into the newest load's `previous` |
| `loading` | `bufferLoadFailed untracked` | `loading` | ignored: untracked; emptied too, as `a.wav`, the next load, was sent after the clear (#1040) |
| `loading` | `takeWriteFailed` | `loading` | nothing: no such take |
| `loading, no load tracked` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `loading, no load tracked` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading, no load tracked` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `loading, no load tracked` | `recordState armed` | `loading, no load tracked` | ignored: a late report |
| `loading, no load tracked` | `recordState recording` | `loading, no load tracked` | ignored: a late report |
| `loading, no load tracked` | `recordState ended` | `loading, no load tracked` | ignored: a late report |
| `loading, no load tracked` | `recordState canceled` | `loading, no load tracked` | ignored: a late report |
| `loading, no load tracked` | `bufferState audio` | `loaded` | settled: loaded, bound |
| `loading, no load tracked` | `bufferState 0 s` | `loading, no load tracked` | nothing; a later 0 s settles it `unsettled`, which `a.wav`'s emptied failure still empties (#1040) |
| `loading, no load tracked` | `another load's number` | `loading, no load tracked` | ignored (#578) |
| `loading, no load tracked` | `bufferLoadFailed untracked` | `empty` | `a.wav`'s, emptied: no path, the file param at its folder, unbound (#1035) |
| `loading, no load tracked` | `takeWriteFailed` | `loading, no load tracked` | nothing: no such take |
| `loading, zero awaited` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loading, zero awaited` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading, zero awaited` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `loading, zero awaited` | `recordState armed` | `loading, zero awaited` | ignored: a late report |
| `loading, zero awaited` | `recordState recording` | `loading, zero awaited` | ignored: a late report |
| `loading, zero awaited` | `recordState ended` | `loading, zero awaited` | ignored: a late report |
| `loading, zero awaited` | `recordState canceled` | `loading, zero awaited` | ignored: a late report |
| `loading, zero awaited` | `bufferState audio` | `loading, zero awaited` | the old audio's report: nothing settles (#401) |
| `loading, zero awaited` | `bufferState 0 s` | `loading` | the load took effect: it waits for its audio |
| `loading, zero awaited` | `another load's number` | `loading, zero awaited` | ignored (#578) |
| `loading, zero awaited` | `bufferLoadFailed newest` | `loading` | the load before it comes back, no longer waiting for a 0 s |
| `loading, zero awaited` | `bufferLoadFailed older` | `loading, zero awaited` | spliced into the newest load's `previous` |
| `loading, zero awaited` | `bufferLoadFailed untracked` | `loading, zero awaited` | ignored: untracked |
| `loading, zero awaited` | `takeWriteFailed` | `loading, zero awaited` | nothing: no such take |
| `loading, checking` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the check and its notice end; over audio, it waits for its 0 s |
| `loading, checking` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking` | `recordState armed` | `loading, checking` | ignored: a late report |
| `loading, checking` | `recordState recording` | `loading, checking` | ignored: a late report |
| `loading, checking` | `recordState ended` | `loading, checking` | ignored: a late report |
| `loading, checking` | `recordState canceled` | `loading, checking` | ignored: a late report |
| `loading, checking` | `bufferState audio` | `loading, checking` | the old audio at the check's rejection: nothing; the notice still waits (#983) |
| `loading, checking` | `bufferState 0 s` | `loading` | the load took effect: the check and its notice end |
| `loading, checking` | `another load's number` | `loading, checking` | ignored (#578) |
| `loading, checking` | `bufferLoadFailed newest` | `loading, checking, given back` | the earlier check comes back, its notice started again |
| `loading, checking` | `bufferLoadFailed older` | `loading, checking` | spliced into the newest load's `previous` |
| `loading, checking` | `bufferLoadFailed untracked` | `loading, checking` | ignored: untracked |
| `loading, checking` | `takeWriteFailed` | `loading, checking` | nothing: no such take |
| `loading, checking` | `the notice` | `loading, checking` | one console line and `buf <n> still checking K2:ld/clr` on BUFFER; nothing else |
| `loading, checking, empty before` | `load_buffer` | `loading` | `loadBuffer`; the check and its notice end |
| `loading, checking, empty before` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking, empty before` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking, empty before` | `recordState armed` | `loading, checking, empty before` | ignored: a late report |
| `loading, checking, empty before` | `recordState recording` | `loading, checking, empty before` | ignored: a late report |
| `loading, checking, empty before` | `recordState ended` | `loading, checking, empty before` | ignored: a late report |
| `loading, checking, empty before` | `recordState canceled` | `loading, checking, empty before` | ignored: a late report |
| `loading, checking, empty before` | `bufferState audio` | `loading, checking, empty before` | a length at the check's rejection: nothing; the notice still waits (#983) |
| `loading, checking, empty before` | `bufferState 0 s` | `loading` | the load took effect: the check and its notice end; a later 0 s settles it `unsettled` |
| `loading, checking, empty before` | `another load's number` | `loading, checking, empty before` | ignored (#578) |
| `loading, checking, empty before` | `bufferLoadFailed newest` | `loading, checking, empty before, given back` | the earlier check comes back, its notice started again |
| `loading, checking, empty before` | `bufferLoadFailed older` | `loading, checking, empty before` | spliced into the newest load's `previous` |
| `loading, checking, empty before` | `bufferLoadFailed untracked` | `loading, checking, empty before` | ignored: untracked |
| `loading, checking, empty before` | `takeWriteFailed` | `loading, checking, empty before` | nothing: no such take |
| `loading, checking, empty before` | `the notice` | `loading, checking, empty before` | one console line and the flash |
| `loading, checking, given back` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the check and its notice end; over audio, it waits for its 0 s |
| `loading, checking, given back` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking, given back` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking, given back` | `recordState armed` | `loading, checking, given back` | ignored: a late report |
| `loading, checking, given back` | `recordState recording` | `loading, checking, given back` | ignored: a late report |
| `loading, checking, given back` | `recordState ended` | `loading, checking, given back` | ignored: a late report |
| `loading, checking, given back` | `recordState canceled` | `loading, checking, given back` | ignored: a late report |
| `loading, checking, given back` | `bufferState audio` | `loaded` | the check and its notice end, long1.wav settles, bound (#983) |
| `loading, checking, given back` | `bufferState 0 s` | `loading` | the check and its notice end |
| `loading, checking, given back` | `another load's number` | `loading, checking, given back` | the given-back check's own number: its seconds kept for the failure's undo, nothing else (#1016) |
| `loading, checking, given back` | `bufferLoadFailed newest` | `loaded` | long1.wav's failure: a.wav, which it replaced, comes back settled; the notice ends |
| `loading, checking, given back` | `bufferLoadFailed older` | `loading, checking, given back` | a.wav's failure: spliced into long1.wav's `previous` |
| `loading, checking, given back` | `bufferLoadFailed untracked` | `loading, checking, given back` | ignored: untracked |
| `loading, checking, given back` | `takeWriteFailed` | `loading, checking, given back` | nothing: no such take |
| `loading, checking, given back` | `the notice` | `loading, checking, given back` | one console line and the flash |
| `loading, checking, empty before, given back` | `load_buffer` | `loading` | `loadBuffer`; the check and its notice end |
| `loading, checking, empty before, given back` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking, empty before, given back` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking, empty before, given back` | `recordState armed` | `loading, checking, empty before, given back` | ignored: a late report |
| `loading, checking, empty before, given back` | `recordState recording` | `loading, checking, empty before, given back` | ignored: a late report |
| `loading, checking, empty before, given back` | `recordState ended` | `loading, checking, empty before, given back` | ignored: a late report |
| `loading, checking, empty before, given back` | `recordState canceled` | `loading, checking, empty before, given back` | ignored: a late report |
| `loading, checking, empty before, given back` | `bufferState audio` | `loaded` | the check and its notice end, long1.wav settles, bound (#983) |
| `loading, checking, empty before, given back` | `bufferState 0 s` | `loading` | the check and its notice end; a later 0 s settles it `unsettled` |
| `loading, checking, empty before, given back` | `another load's number` | `loading, checking, empty before, given back` | the given-back check's own number: its seconds kept for the failure's undo, nothing else (#1016) |
| `loading, checking, empty before, given back` | `bufferLoadFailed newest` | `loading` | long1.wav's failure: z.wav's load, which it replaced, comes back; the notice ends |
| `loading, checking, empty before, given back` | `bufferLoadFailed older` | `loading, checking, empty before, given back` | z.wav's failure: spliced into long1.wav's `previous` |
| `loading, checking, empty before, given back` | `bufferLoadFailed untracked` | `loading, checking, empty before, given back` | ignored: untracked |
| `loading, checking, empty before, given back` | `takeWriteFailed` | `loading, checking, empty before, given back` | nothing: no such take |
| `loading, checking, empty before, given back` | `the notice` | `loading, checking, empty before, given back` | one console line and the flash |
| `loading, restoring` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `loading, restoring` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading, restoring` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `loading, restoring` | `bufferState audio` | `loaded` | settled and counted in `buffers_restored`, bound |
| `loading, restoring` | `bufferState 0 s` | `loading, restoring` | inside `confirm_seconds`: nothing (a later 0 s settles it `unsettled`) |
| `loading, restoring` | `another load's number` | `loading, restoring` | ignored (#578) |
| `loading, restoring` | `bufferLoadFailed newest` | `empty` | the empty slot it replaced comes back |
| `loading, restoring, no load tracked` | `load_buffer` | `loading` | `loadBuffer` (0 s known: no wait for a 0 s) |
| `loading, restoring, no load tracked` | `clear_buffer` | `empty` | `clearBuffer`; unbound |
| `loading, restoring, no load tracked` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs |
| `loading, restoring, no load tracked` | `bufferState audio` | `loaded` | settled and counted in `buffers_restored`, bound |
| `loading, restoring, no load tracked` | `bufferState 0 s` | `loading, restoring, no load tracked` | inside `confirm_seconds`: nothing (a later 0 s settles it `unsettled`) |
| `loading, restoring, no load tracked` | `another load's number` | `loading, restoring, no load tracked` | ignored (#578) |
| `loading, restoring, no load tracked` | `bufferLoadFailed untracked` | `empty` | #980: the restore's own failure, the one outcome still to come, empties it as a tracked restore's does: no path, the file param at its folder, unbound, no clock |
| `loading, restoring, no load tracked, audio known` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; over the restore's reported audio it waits for its 0 s |
| `loading, restoring, no load tracked, audio known` | `clear_buffer` | `empty` | `clearBuffer`; unbound |
| `loading, restoring, no load tracked, audio known` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs |
| `loading, restoring, no load tracked, audio known` | `recordState armed` | `loading, restoring, no load tracked, audio known` | ignored: a late report of the take the failed load canceled (engine row 9), or of one its fallback ended |
| `loading, restoring, no load tracked, audio known` | `recordState recording` | `loading, restoring, no load tracked, audio known` | ignored: a late report of the take the failed load canceled (engine row 9), or of one its fallback ended |
| `loading, restoring, no load tracked, audio known` | `recordState ended` | `loading, restoring, no load tracked, audio known` | ignored: a late report of a take its fallback ended before the engine's reports came |
| `loading, restoring, no load tracked, audio known` | `recordState canceled` | `loading, restoring, no load tracked, audio known` | ignored: a late report of the take the failed load canceled (engine row 9) |
| `loading, restoring, no load tracked, audio known` | `bufferState audio` | `loaded` | settled and counted in `buffers_restored`, bound |
| `loading, restoring, no load tracked, audio known` | `bufferState 0 s` | `unsettled` | a 0 s comes only from a preparation reported after #974's fallback gave the restore back, past `confirm_seconds` of the restore's own `confirm_since`: settled empty, as a restore |
| `loading, restoring, no load tracked, audio known` | `another load's number` | `loading, restoring, no load tracked, audio known` | ignored (#578) |
| `loading, restoring, no load tracked, audio known` | `takeWriteFailed` | `loading, restoring, no load tracked, audio known` | ignored: the slot holds the restored file, not the take (its path is kept) |
| `loading, checking, restoring` | `load_buffer` | `loading` | `loadBuffer`; the check, its notice and the restore end |
| `loading, checking, restoring` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking, restoring` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking, restoring` | `bufferState audio` | `loading, checking, restoring` | a length at the check's rejection: nothing; the notice still waits (#983) |
| `loading, checking, restoring` | `bufferState 0 s` | `loading, restoring` | the load took effect: the check and its notice end; a later 0 s settles it `unsettled` |
| `loading, checking, restoring` | `another load's number` | `loading, checking, restoring` | ignored (#578) |
| `loading, checking, restoring` | `bufferLoadFailed newest` | `empty` | the empty slot it replaced comes back; the notice ends |
| `loading, checking, restoring` | `the notice` | `loading, checking, restoring` | one console line and the flash |
| `loading, checking, restoring, given back` | `load_buffer` | `loading` | `loadBuffer`; the check, its notice and the restore end |
| `loading, checking, restoring, given back` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking, restoring, given back` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking, restoring, given back` | `bufferState audio` | `loaded` | the check and its notice end, the restore settles and counts, bound (#983) |
| `loading, checking, restoring, given back` | `bufferState 0 s` | `loading, restoring` | the check and its notice end; a later 0 s settles it `unsettled` |
| `loading, checking, restoring, given back` | `another load's number` | `loading, checking, restoring, given back` | the given-back check's own number: its seconds kept, nothing else (#1016; the engine sends no such report here, the restore's check having canceled no recording, and its failure gives back the empty slot whatever the seconds) |
| `loading, checking, restoring, given back` | `bufferLoadFailed newest` | `empty` | the restore's own failure: the empty slot it replaced comes back; the notice ends |
| `loading, checking, restoring, given back` | `the notice` | `loading, checking, restoring, given back` | one console line and the flash |
| `armed, unprepared` | `load_buffer` | `loading, zero awaited` | the take is canceled (engine rows 9, 12); `previous` is `{after_cancel, kept}`; it waits for its 0 s |
| `armed, unprepared` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `armed, unprepared` | `record_buffer` | `finishing, stopped armed` | `stopRecord`: finishing until its `canceled` (engine row 6) |
| `armed, unprepared` | `recordState armed` | `armed, unprepared` | the phase stays armed |
| `armed, unprepared` | `recordState recording` | `recording` | the take starts: unbound, its timer runs |
| `armed, unprepared` | `bufferState audio` | `armed, unprepared` | the slot still plays its old audio: nothing |
| `armed, unprepared` | `bufferState 0 s` | `armed, prepared` | the engine prepared the slot: unbound |
| `armed, unprepared` | `another load's number` | `armed, unprepared` | ignored (#578) |
| `armed, unprepared` | `bufferLoadFailed untracked` | `armed, unprepared` | ignored: untracked |
| `armed, unprepared` | `takeWriteFailed` | `armed, unprepared` | `take_unsaved`: the take settles with no path |
| `armed, prepared` | `load_buffer` | `loading` | the take is canceled (engine rows 10, 12); the empty `previous` |
| `armed, prepared` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `armed, prepared` | `record_buffer` | `finishing, stopped armed` | `stopRecord`: finishing until its `canceled` (engine row 7) |
| `armed, prepared` | `recordState armed` | `armed, prepared` | the phase stays armed |
| `armed, prepared` | `recordState recording` | `recording` | the take starts; its timer runs |
| `armed, prepared` | `bufferState audio` | `armed, prepared` | the length shown; nothing settles |
| `armed, prepared` | `bufferState 0 s` | `armed, prepared` | nothing |
| `armed, prepared` | `another load's number` | `armed, prepared` | ignored (#578) |
| `armed, prepared` | `bufferLoadFailed untracked` | `armed, prepared` | ignored: untracked |
| `armed, prepared` | `takeWriteFailed` | `armed, prepared` | `take_unsaved`: the take settles with no path |
| `armed, playable` | `load_buffer` | `loading, zero awaited` | the dub is canceled (engine rows 11, 12); the file's state is `previous`; it waits for its 0 s |
| `armed, playable` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `armed, playable` | `record_buffer` | `armed, playable, stopped` | `stopRecord`; the fallback starts (#904) |
| `armed, playable` | `recordState armed` | `armed, playable` | the phase stays armed |
| `armed, playable` | `recordState recording` | `dub` | the dub starts; its length's timer runs |
| `armed, playable` | `bufferState audio` | `armed, playable` | the length shown; nothing settles |
| `armed, playable` | `bufferState 0 s` | `armed, playable` | nothing |
| `armed, playable` | `another load's number` | `armed, playable` | ignored (#578) |
| `armed, playable` | `bufferLoadFailed untracked` | `armed, playable` | ignored: untracked |
| `armed, playable` | `takeWriteFailed` | `armed, playable` | `take_unsaved`: it ends with no path |
| `armed, playable, stopped` | `load_buffer` | `loading, zero awaited` | the dub and its fallback end (engine rows 11, 12); it waits for its 0 s |
| `armed, playable, stopped` | `clear_buffer` | `empty` | `clearBuffer`: the dub and its fallback end (engine row 13); unbound |
| `armed, playable, stopped` | `record_buffer` | `armed, playable, stopped` | `stopRecord` again; the fallback waits on |
| `armed, playable, stopped` | `recordState armed` | `armed, playable, stopped` | the phase stays armed |
| `armed, playable, stopped` | `recordState recording` | `dub, stopped` | it had started: the fallback waits on |
| `armed, playable, stopped` | `recordState canceled` | `loaded` | canceled before it started: the file plays on, bound |
| `armed, playable, stopped` | `bufferState audio` | `armed, playable, stopped` | the length shown; nothing settles |
| `armed, playable, stopped` | `bufferState 0 s` | `armed, playable, stopped` | nothing |
| `armed, playable, stopped` | `another load's number` | `armed, playable, stopped` | ignored (#578) |
| `armed, playable, stopped` | `bufferLoadFailed untracked` | `armed, playable, stopped` | ignored: untracked |
| `armed, playable, stopped` | `takeWriteFailed` | `armed, playable, stopped` | `take_unsaved`: it ends with no path |
| `armed, playable, stopped` | `the fallback` | `loaded` | it ends as an unsaved take, on no path (#904) |
| `recording` | `load_buffer` | `loading` | the take ends (engine rows 10, 12); the empty `previous`; `loadBuffer` |
| `recording` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `recording` | `record_buffer` | `finishing, recorded` | `stopRecord` (engine row 8); the fallback runs |
| `recording` | `take timer` | `finishing, recorded` | the take ended: it waits for its length; the fallback runs |
| `recording` | `recordState recording` | `recording` | the start's report: its timer runs on |
| `recording` | `recordState ended` | `finishing, recorded` | finishing; with no length known yet, nothing settles (#457) |
| `recording` | `bufferState audio` | `recording` | the length shown; nothing settles |
| `recording` | `bufferState 0 s` | `recording` | nothing |
| `recording` | `another load's number` | `recording` | ignored (#578) |
| `recording` | `bufferLoadFailed untracked` | `recording` | ignored: untracked |
| `recording` | `takeWriteFailed` | `recording` | `take_unsaved`: the take settles with no path |
| `dub` | `load_buffer` | `loading, zero awaited` | the take ends (engine row 12); `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `dub` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `dub` | `record_buffer` | `dub, stopped` | `stopRecord` (engine row 8); the fallback starts (#904) |
| `dub` | `take timer` | `dub, stopped` | its length ran out: the fallback starts (#904) |
| `dub` | `recordState recording` | `dub` | the start's report: its length's timer runs on |
| `dub` | `recordState ended` | `loaded` | `take <n>` on the scratch path, bound to a copy of the file's record |
| `dub` | `bufferState audio` | `dub` | the length shown |
| `dub` | `bufferState 0 s` | `dub` | nothing |
| `dub` | `another load's number` | `dub` | ignored (#578) |
| `dub` | `bufferLoadFailed untracked` | `dub` | ignored: untracked |
| `dub` | `takeWriteFailed` | `dub` | `take_unsaved`: it ends with no path |
| `dub, stopped` | `load_buffer` | `loading, zero awaited` | the dub and its fallback end (engine row 12); it waits for its 0 s |
| `dub, stopped` | `clear_buffer` | `empty` | `clearBuffer`: the dub and its fallback end (engine row 13); unbound |
| `dub, stopped` | `record_buffer` | `dub, stopped` | `stopRecord` again; the fallback waits on |
| `dub, stopped` | `recordState recording` | `dub, stopped` | a late start report: the fallback waits on |
| `dub, stopped` | `recordState ended` | `loaded` | `take <n>` on the scratch path, bound to a copy of the file's record |
| `dub, stopped` | `recordState canceled` | `loaded` | the stop found it not yet started: the file plays on, bound |
| `dub, stopped` | `bufferState audio` | `dub, stopped` | the length shown |
| `dub, stopped` | `bufferState 0 s` | `dub, stopped` | nothing |
| `dub, stopped` | `another load's number` | `dub, stopped` | ignored (#578) |
| `dub, stopped` | `bufferLoadFailed untracked` | `dub, stopped` | ignored: untracked |
| `dub, stopped` | `takeWriteFailed` | `dub, stopped` | `take_unsaved`: it ends with no path |
| `dub, stopped` | `the fallback` | `loaded` | it ends from its last known length: `take <n>` on the scratch path, bound (#904) |
| `loop` | `load_buffer` | `loading, zero awaited` | the take ends (engine row 12); `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loop` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `loop` | `record_buffer` | `loop, stopped` | `stopRecord` (engine row 8); the fallback starts (#904) |
| `loop` | `recordState recording` | `loop` | the start's report: no timer (a loop has no length) |
| `loop` | `bufferState audio` | `loop` | the length shown |
| `loop` | `bufferState 0 s` | `loop` | nothing |
| `loop` | `another load's number` | `loop` | ignored (#578) |
| `loop` | `bufferLoadFailed untracked` | `loop` | ignored: untracked |
| `loop` | `takeWriteFailed` | `loop` | `take_unsaved`: it ends with no path |
| `loop, stopped` | `load_buffer` | `loading, zero awaited` | the loop and its fallback end (engine row 12); it waits for its 0 s |
| `loop, stopped` | `clear_buffer` | `empty` | `clearBuffer`: the loop and its fallback end (engine row 13); unbound |
| `loop, stopped` | `record_buffer` | `loop, stopped` | `stopRecord` again; the fallback waits on |
| `loop, stopped` | `recordState recording` | `loop, stopped` | a late start report: the fallback waits on |
| `loop, stopped` | `recordState ended` | `loaded` | `take <n>` on the scratch path, bound to a copy of the file's record |
| `loop, stopped` | `recordState canceled` | `loaded` | the stop found it not yet started: the file plays on, bound |
| `loop, stopped` | `bufferState audio` | `loop, stopped` | the length shown |
| `loop, stopped` | `bufferState 0 s` | `loop, stopped` | nothing |
| `loop, stopped` | `another load's number` | `loop, stopped` | ignored (#578) |
| `loop, stopped` | `bufferLoadFailed untracked` | `loop, stopped` | ignored: untracked |
| `loop, stopped` | `takeWriteFailed` | `loop, stopped` | `take_unsaved`: it ends with no path |
| `loop, stopped` | `the fallback` | `loaded` | it ends from its last known length: `take <n>` on the scratch path, bound (#904) |
| `finishing, recorded` | `load_buffer` | `loading` | the take and its fallback end; `loadBuffer` |
| `finishing, recorded` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `finishing, recorded` | `record_buffer` | `finishing, recorded` | ignored while it waits for the engine |
| `finishing, recorded` | `recordState recording` | `finishing, recorded` | a late start report: nothing more runs |
| `finishing, recorded` | `recordState ended` | `finishing, recorded` | with no length known yet, nothing settles |
| `finishing, recorded` | `recordState canceled` | `empty, kept state awaited` | the stop found it not yet started (engine rows 6, 7): empty, keeping what it replaced |
| `finishing, recorded` | `bufferState audio` | `loaded` | the take's length: settled, `take <n>` on the scratch path, bound |
| `finishing, recorded` | `bufferState 0 s` | `finishing, recorded` | inside `confirm_seconds`: nothing (a later 0 s settles it empty, adoptable) |
| `finishing, recorded` | `another load's number` | `finishing, recorded` | ignored (#578) |
| `finishing, recorded` | `bufferLoadFailed untracked` | `finishing, recorded` | ignored: untracked |
| `finishing, recorded` | `takeWriteFailed` | `finishing, recorded` | `take_unsaved`: it settles with no path |
| `finishing, recorded` | `the fallback` | `empty, adoptable` | settled from the last known length, 0 s: empty, adoptable |
| `finishing, stopped armed` | `load_buffer` | `loading, zero awaited` | the take and its fallback end; `previous` is `{after_cancel, kept}`; it waits for its 0 s |
| `finishing, stopped armed` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `finishing, stopped armed` | `record_buffer` | `finishing, stopped armed` | ignored while it waits for the engine |
| `finishing, stopped armed` | `recordState armed` | `finishing, stopped armed` | the phase stays armed |
| `finishing, stopped armed` | `recordState recording` | `finishing, recorded` | it had started at its beat: it finishes as recorded |
| `finishing, stopped armed` | `recordState canceled` | `empty, kept state awaited` | empty, keeping what it replaced for the next length (engine rows 6, 7) |
| `finishing, stopped armed` | `bufferState audio` | `finishing, stopped armed` | no length settles a take stopped while armed |
| `finishing, stopped armed` | `bufferState 0 s` | `finishing, stopped armed` | no length settles a take stopped while armed |
| `finishing, stopped armed` | `another load's number` | `finishing, stopped armed` | ignored (#578) |
| `finishing, stopped armed` | `bufferLoadFailed untracked` | `finishing, stopped armed` | ignored: untracked |
| `finishing, stopped armed` | `takeWriteFailed` | `finishing, stopped armed` | `take_unsaved`: it settles with no path |
| `finishing, stopped armed` | `the fallback` | `loaded` | settled as `take <n>` on the scratch path from the old audio's length (a fault, its issue to be filed) |
| `loaded` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loaded` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loaded` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `loaded` | `recordState armed` | `loaded` | ignored: a late report |
| `loaded` | `recordState recording` | `loaded` | ignored: a late report |
| `loaded` | `recordState ended` | `loaded` | ignored: a late report |
| `loaded` | `recordState canceled` | `loaded` | ignored: a late report |
| `loaded` | `bufferState audio` | `loaded` | the new length; its overview read again |
| `loaded` | `bufferState 0 s` | `loaded` | the length only (a report sent before the load took effect) |
| `loaded` | `another load's number` | `loaded` | ignored (#578) |
| `loaded` | `bufferLoadFailed newest` | `loading` | a.wav's failure: z.wav's load, which it replaced, comes back, still awaiting the engine |
| `loaded` | `bufferLoadFailed older` | `loaded` | z.wav's failure: spliced into a.wav's `previous`; nothing changes now |
| `loaded` | `bufferLoadFailed untracked` | `loaded` | ignored: untracked |
| `loaded` | `takeWriteFailed` | `loaded` | nothing: no such take |
| `unsettled` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `unsettled` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `unsettled` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `unsettled` | `recordState armed` | `unsettled` | ignored: a late report |
| `unsettled` | `recordState recording` | `unsettled` | ignored: a late report |
| `unsettled` | `recordState ended` | `unsettled` | ignored: a late report |
| `unsettled` | `recordState canceled` | `unsettled` | ignored: a late report |
| `unsettled` | `bufferState audio` | `loaded` | the late audio is adopted: loaded, bound |
| `unsettled` | `bufferState 0 s` | `unsettled` | nothing |
| `unsettled` | `another load's number` | `unsettled` | ignored (#578) |
| `unsettled` | `bufferLoadFailed newest` | `loading` | a.wav's failure: z.wav's load comes back, still awaiting the engine |
| `unsettled` | `bufferLoadFailed older` | `unsettled` | z.wav's failure: spliced into a.wav's `previous` |
| `unsettled` | `bufferLoadFailed untracked` | `unsettled` | ignored: untracked |
| `unsettled` | `takeWriteFailed` | `unsettled` | nothing: no such take |
| `missing` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `missing` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `missing` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs, the tracked loads forgotten |
| `missing` | `bufferState 0 s` | `missing` | nothing |
| `missing` | `another load's number` | `missing` | ignored (#578) |

The pairs that cannot happen (the test's `impossible` list, each with its reason; each reason is a fact of the code, true by every way into the state, never only of the history a state's entry makes):
- `take timer` in every state but `recording` and `dub`: the take timer runs only while a take with a length records (`start_take_timer`: at the send of a replace take or a dub with no delay or threshold, or at an armed one's "recording"); a loop has none, and K3, its own end, a load and a clear end it.
- `the fallback` in every state but the two finishing ones and the three stopped playable ones: it runs only after a take ends or stops (`finish_buffer_take`, `start_playable_fallback`), and the report, load, clear or recording that ends the take ends it.
- `the notice` in every state but the six checking ones: the `"buffer slots"` invariant holds a `"notice"` clock only while the slot checks a load (a load, a clear, a recording, the check's end and a failure whose undo gives back no check each end it).
- Any `recordState` and `takeWriteFailed` in `missing`, `loading, restoring`, `loading, restoring, no load tracked`, `loading, checking, restoring` and `loading, checking, restoring, given back`: no recording since the start. `missing_path` is set only by init's restore and every recording clears it; it comes back only as the state before a load sent while it was missing (a recording empties that list) or as what a canceled take kept, which needs audio a missing file's slot never reports. `loading, restoring` still tracks the restore's own load, and a recording empties the tracked loads for good (a restore loads only at init). A restore comes back after a recording only as what a canceled armed take replaced, and only with a length reported (`resolve_previous`, `settle_kept_state`): `loading, restoring, no load tracked, audio known`, which never drops to 0 s and stays restoring (its 0 s comes only from a preparation reported after #974's fallback, 5 s after the stop and so past `confirm_seconds` of the restore's `confirm_since`, and settles it `unsettled`); so at 0 s with no load tracked the restore came back through failed loads alone. A recording ends a check, and what a canceled take gives back is never a check (`state_before_take` passes over every load still checked).
- Any `recordState` in `empty, kept state awaited`: `kept_state` rests only after the take's "canceled" (its fallback settles it at once), the engine's last report of a take (`stopRecording`), its earlier ones sent before it on the same poll; `takeWriteFailed` there: the newest recording was canceled, and the engine writes only a take that ended (`endTake`).
- `recordState armed` in `empty, adoptable`: the slot settled empty for a take Lua saw record (phase "recording", set at a send the engine reports no "armed" for, or by its "recording") or for one a failed load canceled, and an armed take's "armed" is the engine's first report of it, sent at the `recordBuffer`, before any of those. In `recording`, `dub`, `loop`, `finishing, recorded`, `dub, stopped` and `loop, stopped`: phase "recording", set at a send with no delay or threshold (no "armed" is reported) or by its "recording", which follows its "armed" on the same poll.
- `recordState canceled` in the three armed states not stopped, `recording`, `dub` and `loop`: the engine cancels a take at a `stopRecord`, a load, a clear, a newer `recordBuffer` (`stopRecording`, engine rows 6-13) or its own free (after cleanup has stopped the poll), and, as a safety net, when a record synth frees before it armed (`recordSynthFreed`), which only a stop reaches (an unarmed synth's envelope is never opened, and `stopRecordSlot` frees one it gates off); Lua has sent none since the take: `load_buffer` and `clear_buffer` end the take, and `record_buffer` on a recording slot is K3, whose `stopRecord` leaves a finishing or stopped state.
- `recordState ended` in the four armed states and `finishing, stopped armed` (phase "armed": Lua has not had the take's "recording", which the engine sends before its "ended" on the same poll) and in `loop` (its record synth wraps until it is gated off, and Lua gates it off only by K3's `stopRecord`, which starts its fallback: the state is then `loop, stopped`; a load or a clear cancels it).
- `bufferLoadFailed newest` and `older` in the eleven states that hold a take: no load is tracked while a take runs (`record_buffer` empties the list, and a load ends the take). In the three empty states: no tracked load's failure can still come (a clear, a recording and a take's end empty the list; a failure that empties the slot comes after the failures of the loads before it, the server reading a slot's files in order; one that gives back an empty slot does so only once every later load has failed). In `missing` and the three no-load states: no load is tracked (none at the start; a failed load gives back the missing path only once every later load has failed).
- `bufferLoadFailed older` and `untracked` in `loading, restoring`, `loading, checking, restoring` and `loading, checking, restoring, given back`: a restoring slot tracks at most the restore's own load (a failed later load gives back the state from before it, with only the loads before it), and every load since it has failed or is tracked (four newer ones would push an unchecked restore's out first: the no-load state; a checked one's is never dropped while it is checked, #980; a clear or a recording ends the restore).
- `bufferLoadFailed untracked` in `loading, restoring, no load tracked, audio known`: the restore's own load took effect (the known length is its audio, reported while the take was armed), the recording emptied the list, and every load since has failed (the one whose undo gave the state back was the newest tracked; four newer ones would push it out, and the state could not come back).
- `bufferLoadFailed untracked` in `missing`: every load sent since the slot was missing has reported its failure (only that gives the missing path back), and none came before it. `bufferState audio` in `missing`: the slot has held no audio since the start (init's restore found no file, and every load since failed).

**A forgotten load's late failure** (`bufferLoadFailed untracked` in `loading, no load tracked` and `loading, restoring, no load tracked`): four newer loads can push an unchecked load out of the tracked list, and once they have all failed it comes back with no entry. Its own failure empties the slot: a restore's (load 1, #980), or a plain load's or a restore's reported emptied, awaiting its read or settled `unsettled` (#1035, #1040). One whose next load is still tracked has no state of its own (a loading state): `buffers_test.lua` runs it, and `loading`'s untracked row the refusal. The rules: `docs/notes/lua/buffers.md` (#980).
