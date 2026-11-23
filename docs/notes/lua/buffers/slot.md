## Must not break

- **The table below is the test's** (`test/unit/buffers_slot_test.lua`, 3.9, #903): "buffer slot: the notes' table equals these rows" compares its State, Event and Next cells with the test's rows, and "buffer slot: every cell is decided" fails on a pair of a state and an event that is neither a row nor one of the impossible pairs below. A row changes in both at once, and a new state or event comes with every one of its cells decided.
- **The states are the slot's status, split by fields that exist** (`S.lib.buffers.status(slot)`, `docs/notes/lua/buffers.md`, States): the table adds no field, and no code reads it. Four of status's cases have sub-states, each read from a field the code keeps: `empty` (`kept_state`, `settled_empty == "take"`), `loading` (`checking_from`, `awaiting_zero`, `restoring`), `armed` (the take's `kind`, and for a replace take its `unbound`: the engine has emptied the slot) and `finishing` (the take's `phase`).
- This file is the machine's table only: the slot's rules are `docs/notes/lua/buffers.md`'s and `docs/notes/lua/record.md`'s, and its Machines entry (`buffer slot`, the invariant `buffer slots`) is in `docs/notes/lua/buffers.md`.

## The table

### buffer slot

Slot 1 in every row. Every state starts from the same history (`prelude`): a file loaded and reported (4 s), a replace take of it recorded (its "recording" report heard), stopped and settled from its 2 s length, so take 1's "ended" report and a failed write of it may still come; then a load (number 2) that the clear right after forgets while it is in flight, so its failure may still come. Each state is then entered by the script's own calls and the engine stub's reports, in the engine's order:
- `empty`: the prelude. `empty, kept state awaited`: `a.wav` loaded (4 s), a take synced to the beat (`record_sync` 2) stopped while armed, then its "canceled". `empty, adoptable`: a replace take whose timer ran out, then a 0 s report past `confirm_seconds`.
- `loading`: two loads sent into the empty slot. `loading, zero awaited`: two loads over `a.wav`. `loading, checking`: two long files (120 s) over `a.wav` on a high tier's slot (`S.performance.buffer_seconds` 300, set through `S`: the tier is read from the engine's file at load, before a state is entered). The three restoring states: `buffers.data` naming a file, read again with `load_buffers_from_disk()` as init's start step runs it, into the empty slot, over `a.wav`, and over `a.wav` with a long file on the high tier.
- `armed, unprepared`: a replace take synced to the beat over `a.wav`; `armed, prepared`: one armed by a threshold (`record_threshold` 2), which the engine empties at the send; `armed, playable`: a dub (`record_feedback` 50) armed by a threshold.
- `recording`: a replace take with no delay. `dub`: a dub over `a.wav` with a length. `loop`: a loop recording (`record_loop` 2) over `a.wav`.
- `finishing, recorded`: a replace take whose timer ran out (0 s known). `finishing, stopped armed`: a synced take over `a.wav` stopped with K3 while armed.
- `loaded`: `a.wav` reported (4 s). `unsettled`: a load reported 0 s past `confirm_seconds`. `missing`: `buffers.data` naming a file that is not there, read again.

The events, each the script's call or the engine's report of the slot as it is now:
- `load_buffer`, `clear_buffer`, `record_buffer`: the call (`/tmp/next.wav`, a file with no info, never checked; `record_buffer` with the record params at their defaults, a replace take with no delay, outside the recording states, and K3 in them).
- `take timer`, `the fallback`, `the notice`: the slot's clock wakes, in the role `"take"`, `"fallback"` or `"notice"` (`S.lib.record.clock_role`).
- `recordState armed`, `recording`, `ended`, `canceled`: the report of the slot's newest recording (`records_sent`).
- `bufferState audio`: 6 s, numbered with the newest load; `bufferState 0 s`: 0 s, at once (inside `confirm_seconds`: a row whose next state depends on a later 0 s moves the clock on in its check); `another load's number`: 7 s, numbered with the load before the newest.
- `bufferLoadFailed newest`, `older`, `untracked`: the failure of the newest load, of the one before it, or of the prelude's forgotten load.
- `takeWriteFailed`: the failure of the newest recording's scratch write.

The engine's rows of a recording (`docs/notes/engine/record.md`, The state table) are named in the Effect column beside the rows they pair with.

| State | Event | Next | Effect |
|---|---|---|---|
| `empty` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `empty` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `empty` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `empty` | `recordState ended` | `empty` | ignored: the slot holds no take |
| `empty` | `bufferState audio` | `empty` | the length only (a report sent before the clear): nothing settles |
| `empty` | `bufferState 0 s` | `empty` | nothing |
| `empty` | `another load's number` | `empty` | ignored: sent before the slot's newest load (#578) |
| `empty` | `bufferLoadFailed untracked` | `empty` | ignored: the slot tracks no such load |
| `empty` | `takeWriteFailed` | `empty` | nothing: no take of that number holds the slot |
| `empty, kept state awaited` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `empty, kept state awaited` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `empty, kept state awaited` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `empty, kept state awaited` | `bufferState audio` | `loaded` | the take never prepared the slot: what it replaced comes back, bound (engine row 6) |
| `empty, kept state awaited` | `bufferState 0 s` | `empty` | the kept state is dropped; unbound (engine row 7) |
| `empty, kept state awaited` | `another load's number` | `empty, kept state awaited` | ignored: sent before the slot's newest load (#578) |
| `empty, kept state awaited` | `bufferLoadFailed untracked` | `empty, kept state awaited` | ignored: the slot tracks no such load |
| `empty, adoptable` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `empty, adoptable` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `empty, adoptable` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `empty, adoptable` | `recordState recording` | `empty, adoptable` | ignored: the take has settled |
| `empty, adoptable` | `recordState ended` | `empty, adoptable` | ignored: the take has settled |
| `empty, adoptable` | `bufferState audio` | `loaded` | the late take is adopted: `take <n>`, bound |
| `empty, adoptable` | `bufferState 0 s` | `empty, adoptable` | nothing |
| `empty, adoptable` | `another load's number` | `empty, adoptable` | ignored: sent before the slot's newest load (#578) |
| `empty, adoptable` | `bufferLoadFailed untracked` | `empty, adoptable` | ignored: the slot tracks no such load |
| `empty, adoptable` | `takeWriteFailed` | `empty, adoptable` | `take_unsaved`: a later adoption has no path |
| `loading` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `loading` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `loading` | `recordState ended` | `loading` | ignored: the slot holds no take |
| `loading` | `bufferState audio` | `loaded` | settled: loaded, bound |
| `loading` | `bufferState 0 s` | `loading` | inside `confirm_seconds`: nothing (a later 0 s settles it `unsettled`) |
| `loading` | `another load's number` | `loading` | ignored: sent before the slot's newest load (#578) |
| `loading` | `bufferLoadFailed newest` | `loading` | the load before it comes back (still loading) |
| `loading` | `bufferLoadFailed older` | `loading` | spliced into the newest load's `previous` |
| `loading` | `bufferLoadFailed untracked` | `loading` | ignored: the slot tracks no such load |
| `loading` | `takeWriteFailed` | `loading` | nothing: no take of that number holds the slot |
| `loading, zero awaited` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loading, zero awaited` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading, zero awaited` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `loading, zero awaited` | `recordState ended` | `loading, zero awaited` | ignored: the slot holds no take |
| `loading, zero awaited` | `bufferState audio` | `loading, zero awaited` | the old audio's report: nothing settles (#401) |
| `loading, zero awaited` | `bufferState 0 s` | `loading` | the load took effect: it waits for its audio |
| `loading, zero awaited` | `another load's number` | `loading, zero awaited` | ignored: sent before the slot's newest load (#578) |
| `loading, zero awaited` | `bufferLoadFailed newest` | `loading` | the load before it comes back, no longer waiting for a 0 s |
| `loading, zero awaited` | `bufferLoadFailed older` | `loading, zero awaited` | spliced into the newest load's `previous` |
| `loading, zero awaited` | `bufferLoadFailed untracked` | `loading, zero awaited` | ignored: the slot tracks no such load |
| `loading, zero awaited` | `takeWriteFailed` | `loading, zero awaited` | nothing: no take of that number holds the slot |
| `loading, checking` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the check and its notice end; over audio, it waits for its 0 s |
| `loading, checking` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking` | `recordState ended` | `loading, checking` | ignored: the slot holds no take |
| `loading, checking` | `bufferState audio` | `loaded` | a new length: the check and its notice end, the load settles, bound |
| `loading, checking` | `bufferState 0 s` | `loading` | the load took effect: the check and its notice end |
| `loading, checking` | `another load's number` | `loading, checking` | ignored: sent before the slot's newest load (#578) |
| `loading, checking` | `bufferLoadFailed newest` | `loading, checking` | the earlier check comes back, its notice started again |
| `loading, checking` | `bufferLoadFailed older` | `loading, checking` | spliced into the newest load's `previous` |
| `loading, checking` | `bufferLoadFailed untracked` | `loading, checking` | ignored: the slot tracks no such load |
| `loading, checking` | `takeWriteFailed` | `loading, checking` | nothing: no take of that number holds the slot |
| `loading, checking` | `the notice` | `loading, checking` | one console line and `buf <n> still checking K2:ld/clr` on BUFFER; nothing else |
| `loading, restoring` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `loading, restoring` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading, restoring` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `loading, restoring` | `recordState ended` | `loading, restoring` | ignored: the slot holds no take |
| `loading, restoring` | `bufferState audio` | `loaded` | settled and counted in `buffers_restored`, bound |
| `loading, restoring` | `bufferState 0 s` | `loading, restoring` | inside `confirm_seconds`: nothing (a later 0 s settles it `unsettled`) |
| `loading, restoring` | `another load's number` | `loading, restoring` | ignored: sent before the slot's newest load (#578) |
| `loading, restoring` | `bufferLoadFailed newest` | `empty` | the empty slot it replaced comes back |
| `loading, restoring` | `bufferLoadFailed untracked` | `loading, restoring` | ignored: the slot tracks no such load |
| `loading, restoring` | `takeWriteFailed` | `loading, restoring` | nothing: no take of that number holds the slot |
| `loading, zero awaited, restoring` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loading, zero awaited, restoring` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loading, zero awaited, restoring` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `loading, zero awaited, restoring` | `recordState ended` | `loading, zero awaited, restoring` | ignored: the slot holds no take |
| `loading, zero awaited, restoring` | `bufferState audio` | `loading, zero awaited, restoring` | the old audio's report: nothing settles (#401) |
| `loading, zero awaited, restoring` | `bufferState 0 s` | `loading, restoring` | the restore took effect: it waits for its audio |
| `loading, zero awaited, restoring` | `another load's number` | `loading, zero awaited, restoring` | ignored: sent before the slot's newest load (#578) |
| `loading, zero awaited, restoring` | `bufferLoadFailed newest` | `loaded` | the file it replaced comes back, bound |
| `loading, zero awaited, restoring` | `bufferLoadFailed untracked` | `loading, zero awaited, restoring` | ignored: the slot tracks no such load |
| `loading, zero awaited, restoring` | `takeWriteFailed` | `loading, zero awaited, restoring` | nothing: no take of that number holds the slot |
| `loading, checking, restoring` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the check, its notice and the restore end; it waits for its 0 s |
| `loading, checking, restoring` | `clear_buffer` | `empty` | `clearBuffer`; the check and its notice end; unbound |
| `loading, checking, restoring` | `record_buffer` | `recording` | a replace take: the check and its notice end (engine row 5) |
| `loading, checking, restoring` | `recordState ended` | `loading, checking, restoring` | ignored: the slot holds no take |
| `loading, checking, restoring` | `bufferState audio` | `loaded` | a new length: the check ends, the restore settles and counts, bound |
| `loading, checking, restoring` | `bufferState 0 s` | `loading, restoring` | the check and its notice end; the restore waits for its audio |
| `loading, checking, restoring` | `another load's number` | `loading, checking, restoring` | ignored: sent before the slot's newest load (#578) |
| `loading, checking, restoring` | `bufferLoadFailed newest` | `loaded` | the file it replaced comes back, bound |
| `loading, checking, restoring` | `bufferLoadFailed untracked` | `loading, checking, restoring` | ignored: the slot tracks no such load |
| `loading, checking, restoring` | `takeWriteFailed` | `loading, checking, restoring` | nothing: no take of that number holds the slot |
| `loading, checking, restoring` | `the notice` | `loading, checking, restoring` | one console line and the flash; nothing else |
| `armed, unprepared` | `load_buffer` | `loading, zero awaited` | the take is canceled (engine rows 9, 12); `previous` is `{after_cancel, kept}`; it waits for its 0 s |
| `armed, unprepared` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `armed, unprepared` | `record_buffer` | `finishing, stopped armed` | `stopRecord`: finishing until its `canceled` (engine row 6) |
| `armed, unprepared` | `recordState armed` | `armed, unprepared` | the phase stays armed |
| `armed, unprepared` | `recordState recording` | `recording` | the take starts: unbound, its timer runs |
| `armed, unprepared` | `bufferState audio` | `armed, unprepared` | the slot still plays its old audio: nothing |
| `armed, unprepared` | `bufferState 0 s` | `armed, prepared` | the engine prepared the slot: unbound |
| `armed, unprepared` | `another load's number` | `armed, unprepared` | ignored: sent before the slot's newest load (#578) |
| `armed, unprepared` | `bufferLoadFailed untracked` | `armed, unprepared` | ignored: the slot tracks no such load |
| `armed, unprepared` | `takeWriteFailed` | `armed, unprepared` | `take_unsaved`: the take settles with no path |
| `armed, prepared` | `load_buffer` | `loading` | the take is canceled (engine rows 10, 12); the empty `previous` |
| `armed, prepared` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `armed, prepared` | `record_buffer` | `finishing, stopped armed` | `stopRecord`: finishing until its `canceled` (engine row 7) |
| `armed, prepared` | `recordState armed` | `armed, prepared` | the phase stays armed |
| `armed, prepared` | `recordState recording` | `recording` | the take starts; its timer runs |
| `armed, prepared` | `bufferState audio` | `armed, prepared` | the length shown; nothing settles |
| `armed, prepared` | `bufferState 0 s` | `armed, prepared` | nothing |
| `armed, prepared` | `another load's number` | `armed, prepared` | ignored: sent before the slot's newest load (#578) |
| `armed, prepared` | `bufferLoadFailed untracked` | `armed, prepared` | ignored: the slot tracks no such load |
| `armed, prepared` | `takeWriteFailed` | `armed, prepared` | `take_unsaved`: the take settles with no path |
| `armed, playable` | `load_buffer` | `loading, zero awaited` | the dub is canceled (engine rows 11, 12); the file's state is `previous`; it waits for its 0 s |
| `armed, playable` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `armed, playable` | `record_buffer` | `armed, playable` | `stopRecord`; the fallback starts: it ends as an unsaved take, on no path (#904) |
| `armed, playable` | `recordState armed` | `armed, playable` | the phase stays armed |
| `armed, playable` | `recordState recording` | `dub` | the dub starts; its length's timer runs |
| `armed, playable` | `bufferState audio` | `armed, playable` | the length shown; nothing settles |
| `armed, playable` | `bufferState 0 s` | `armed, playable` | nothing |
| `armed, playable` | `another load's number` | `armed, playable` | ignored: sent before the slot's newest load (#578) |
| `armed, playable` | `bufferLoadFailed untracked` | `armed, playable` | ignored: the slot tracks no such load |
| `armed, playable` | `takeWriteFailed` | `armed, playable` | `take_unsaved`: it ends with no path |
| `recording` | `load_buffer` | `loading` | the take ends (engine rows 10, 12); the empty `previous`; `loadBuffer` |
| `recording` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `recording` | `record_buffer` | `finishing, recorded` | `stopRecord` (engine row 8); the fallback runs |
| `recording` | `take timer` | `finishing, recorded` | the take ended: it waits for its length; the fallback runs |
| `recording` | `recordState recording` | `recording` | the start's report: its timer runs on |
| `recording` | `recordState ended` | `finishing, recorded` | finishing; with no length known yet, nothing settles (#457) |
| `recording` | `bufferState audio` | `recording` | the length shown; nothing settles |
| `recording` | `bufferState 0 s` | `recording` | nothing |
| `recording` | `another load's number` | `recording` | ignored: sent before the slot's newest load (#578) |
| `recording` | `bufferLoadFailed untracked` | `recording` | ignored: the slot tracks no such load |
| `recording` | `takeWriteFailed` | `recording` | `take_unsaved`: the take settles with no path |
| `dub` | `load_buffer` | `loading, zero awaited` | the take ends (engine row 12); `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `dub` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `dub` | `record_buffer` | `dub` | `stopRecord` (engine row 8); the fallback starts (#904) |
| `dub` | `take timer` | `dub` | its length ran out: the fallback starts (#904) |
| `dub` | `recordState recording` | `dub` | the start's report: its length's timer runs on |
| `dub` | `recordState ended` | `loaded` | `take <n>` on the scratch path, bound to a copy of the file's record |
| `dub` | `bufferState audio` | `dub` | the length shown |
| `dub` | `bufferState 0 s` | `dub` | nothing |
| `dub` | `another load's number` | `dub` | ignored: sent before the slot's newest load (#578) |
| `dub` | `bufferLoadFailed untracked` | `dub` | ignored: the slot tracks no such load |
| `dub` | `takeWriteFailed` | `dub` | `take_unsaved`: it ends with no path |
| `loop` | `load_buffer` | `loading, zero awaited` | the take ends (engine row 12); `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loop` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `loop` | `record_buffer` | `loop` | `stopRecord` (engine row 8); the fallback starts (#904) |
| `loop` | `recordState recording` | `loop` | the start's report: no timer (a loop has no length) |
| `loop` | `bufferState audio` | `loop` | the length shown |
| `loop` | `bufferState 0 s` | `loop` | nothing |
| `loop` | `another load's number` | `loop` | ignored: sent before the slot's newest load (#578) |
| `loop` | `bufferLoadFailed untracked` | `loop` | ignored: the slot tracks no such load |
| `loop` | `takeWriteFailed` | `loop` | `take_unsaved`: it ends with no path |
| `finishing, recorded` | `load_buffer` | `loading` | the take and its fallback end; `loadBuffer` |
| `finishing, recorded` | `clear_buffer` | `empty` | `clearBuffer`: the take ends (engine row 13); unbound |
| `finishing, recorded` | `record_buffer` | `finishing, recorded` | ignored while it waits for the engine |
| `finishing, recorded` | `recordState recording` | `finishing, recorded` | a late start report: nothing more runs |
| `finishing, recorded` | `recordState ended` | `finishing, recorded` | with no length known yet, nothing settles |
| `finishing, recorded` | `bufferState audio` | `loaded` | the take's length: settled, `take <n>` on the scratch path, bound |
| `finishing, recorded` | `bufferState 0 s` | `finishing, recorded` | inside `confirm_seconds`: nothing (a later 0 s settles it empty, adoptable) |
| `finishing, recorded` | `another load's number` | `finishing, recorded` | ignored: sent before the slot's newest load (#578) |
| `finishing, recorded` | `bufferLoadFailed untracked` | `finishing, recorded` | ignored: the slot tracks no such load |
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
| `finishing, stopped armed` | `another load's number` | `finishing, stopped armed` | ignored: sent before the slot's newest load (#578) |
| `finishing, stopped armed` | `bufferLoadFailed untracked` | `finishing, stopped armed` | ignored: the slot tracks no such load |
| `finishing, stopped armed` | `takeWriteFailed` | `finishing, stopped armed` | `take_unsaved`: it settles with no path |
| `finishing, stopped armed` | `the fallback` | `loaded` | settled as `take <n>` on the scratch path from the old audio's length (a fault, its issue to be filed) |
| `loaded` | `load_buffer` | `loading, zero awaited` | `loadBuffer`; the overview forgotten; over audio, it waits for its 0 s (#401) |
| `loaded` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `loaded` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `loaded` | `recordState ended` | `loaded` | ignored: the slot holds no take |
| `loaded` | `bufferState audio` | `loaded` | the new length; its overview read again |
| `loaded` | `bufferState 0 s` | `loaded` | the length only (a report sent before the load took effect) |
| `loaded` | `another load's number` | `loaded` | ignored: sent before the slot's newest load (#578) |
| `loaded` | `bufferLoadFailed untracked` | `loaded` | ignored: the slot tracks no such load |
| `loaded` | `takeWriteFailed` | `loaded` | nothing: no take of that number holds the slot |
| `unsettled` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `unsettled` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `unsettled` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `unsettled` | `recordState ended` | `unsettled` | ignored: the slot holds no take |
| `unsettled` | `bufferState audio` | `loaded` | the late audio is adopted: loaded, bound |
| `unsettled` | `bufferState 0 s` | `unsettled` | nothing |
| `unsettled` | `another load's number` | `unsettled` | ignored: sent before the slot's newest load (#578) |
| `unsettled` | `bufferLoadFailed newest` | `empty` | the empty slot it replaced comes back |
| `unsettled` | `bufferLoadFailed untracked` | `unsettled` | ignored: the slot tracks no such load |
| `unsettled` | `takeWriteFailed` | `unsettled` | nothing: no take of that number holds the slot |
| `missing` | `load_buffer` | `loading` | `loadBuffer`; the overview forgotten |
| `missing` | `clear_buffer` | `empty` | `clearBuffer`; the tracked loads forgotten; unbound |
| `missing` | `record_buffer` | `recording` | a replace take, sent at once: unbound, its timer runs; the tracked loads forgotten |
| `missing` | `recordState ended` | `missing` | ignored: the slot holds no take |
| `missing` | `bufferState audio` | `missing` | the length only: nothing settles |
| `missing` | `bufferState 0 s` | `missing` | nothing |
| `missing` | `another load's number` | `missing` | ignored: sent before the slot's newest load (#578) |
| `missing` | `bufferLoadFailed untracked` | `missing` | ignored: the slot tracks no such load |
| `missing` | `takeWriteFailed` | `missing` | nothing: no take of that number holds the slot |

The pairs that cannot happen (the test's `impossible` list, each with its reason):
- `take timer` in every state but `recording` and `dub`: only a replace take recording, or a dub with a length, runs one.
- `the fallback` in every state but the two finishing ones: only a finishing take has one as the state is entered. A K3 or a dub's length starts a playable recording's, and those rows' checks run it (`armed, playable`, `dub` and `loop` + `record_buffer`, `dub` + `take timer`, `armed, playable` + `recordState recording`).
- `the notice` in every state but the two checking ones: no check runs.
- `recordState armed`, `recording` and `canceled` where the newest recording is the prelude's take 1 (`empty`, the six loading states, `loaded`, `unsettled`, `missing`): its "recording" came and its length settled it, so only its "ended" can still come.
- Any `recordState` in `empty, kept state awaited`: the take's "canceled" was its last report; and `takeWriteFailed` there: a canceled take writes no scratch file.
- `recordState armed` in `empty, adoptable`, `recording`, `dub`, `loop` and `finishing, recorded`: a take with no delay or threshold is never armed, and one that records has said so already.
- `recordState canceled` in the armed states, `empty, adoptable`, `recording`, `dub`, `loop` and `finishing, recorded`: the engine cancels a take only at a `stopRecord` of an armed take, a load or a clear, and none was sent.
- `recordState ended` in the armed states, `loop` and `finishing, stopped armed`: the engine sends a take's "recording" before its "ended" on the same poll, and a loop ends only at a stop.
- `bufferLoadFailed newest` where no load in flight is tracked (every state but the six loading ones and `unsettled`): a clear or a recording forgot them, or a loaded slot's load reported its audio.
- `bufferLoadFailed older` in every state but `loading`, `loading, zero awaited` and `loading, checking`: no older load is in flight (a restore's load is the slot's only one; an earlier tracked load reported its audio or was forgotten).
