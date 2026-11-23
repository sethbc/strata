## Must not break

- **A clock is never canceled while its resume may be posted** (#626, #870): norns delivers every resume matron has posted, and one whose coroutine was canceled meanwhile makes `clock.resume` raise (maiden prints `bad argument #1 to 'resume'`). `S.lib.clocks.stop(handle)` cancels a clock only while its wait's end is farther off than the margin; otherwise it retires it, and the clock ends at its own wake, its wait returning false and its body returning. The margin is `CLOCKS.sleep_margin` (0.1 s, `lib/ui/zones.lua`'s `learn_wake_margin`) before a sleep's wake and `CLOCKS.sync_tolerance` (1/32 beat, `lib/quantize.lua`'s `wake_tolerance`) before a sync's landing; a sync whose beat is below the one it synced at (a reset or a new clock source moved it) is retired too.
- **Every wait in a helper clock's body goes through its handle** and returns when the wait says false: `if not handle.sleep(seconds) then return end`, or `handle.sync(beat, offset)`. A body that waits with a bare `clock.sleep` or `clock.sync` is not told it was stopped and runs on.
- **A sync's landing is worked out as matron's scheduler does** (`clock_scheduler_next_clock_beat`, `CLOCKS.sync_epsilon`): from the beat the sync was asked at, or, when the coroutine's last wait was a sync, from the beat that sync resumed with (matron counts from the last sync's beat, which a reset puts at 0). A landing not known (a sync given no positive beat) retires.
- **`cancel(handle)` is for cleanup steps only**: it cancels at once, whatever the wait, which is safe only when norns ends every clock anyway. The cleanup-order test sees a step through its `clock.cancel`.
- **The helper's cleanup step is the last of all** (`CLEANUP_ORDER.clocks`, 190): a step before it can still retire a clock (the grids' own step, 170, ends their hold clocks).
- **`handle.id` is not known inside the body before its first wait** (`clock.run` resumes the coroutine before it returns). A module keeps the handle; where its tests read `S.<name>_clock`, it sets that to `handle.id` once `run` has returned, and to nil at a stop.
- `clock.cancel` is called only in `lib/clocks.lua` and the files `test/unit/structure_test.lua` lists, as often as listed: `BARE_CANCEL_FILES` (the nineteen that move onto the helper, each in the package that owns it, which removes its line) and `EDGE_CANCEL_FILES` (the nine that cancel only as the script starts or ends, and `lib/sequencer.lua` and `lib/quantize.lua`, which keep their own rule). The first list only shrinks.

## Machines

### clocks
- **State:** a handle's `waiting` (`"sleep"`, `"sync"` or nil while its body runs), `stopped`, `ended`, the wait's `wake` (a sleep) or `sync_beat` and `landing` (a sync), and `M.retired[id]` (the stopped handles that still wait for their wake); `S.lib.clocks.alive(handle)` names a running one.
- **Invariant:** `clocks`: every retired handle is a stopped one under its own id, and its coroutine is pending until its wake (it is forgotten when it ends).
- **Test:** `test/unit/clocks_test.lua`: "the invariant fails for a retired handle whose coroutine is dead and still kept".

| State | Event | Next | Effect |
|---|---|---|---|
| running | its body waits (`handle.sleep`, `handle.sync`) | waiting | the wait's end noted |
| running | `stop` (from its own body) | stopped | its next wait returns false at once |
| running | its body returns | ended | forgotten if it was retired |
| stopped | its body waits | stopped | the wait returns false at once, without waiting |
| stopped | its body returns | ended | nothing kept |
| waiting | its wake | running | the wait returns true |
| waiting | `stop`, the end farther off than the margin | ended | `clock.cancel` at once |
| waiting | `stop`, the end within the margin, past, or the beat gone back | retired | kept in `M.retired` |
| waiting | `cancel` | ended | `clock.cancel` at once |
| retired | its wake | ended | the wait returns false, the body returns, the handle forgotten |
| retired | `cancel`, or cleanup step 190 | ended | `clock.cancel`, the handle forgotten |
| stopped, retired or ended | `stop` | unchanged | nothing |

## Owns

`lib/clocks.lua` (`S.lib.clocks`, 3.9, design section 3, package 0b), included first after the constants:
- `run(fn) -> handle`: starts a clock (`clock.run`) whose body is `fn(handle)`; `handle.id` is the clock's id once `run` returns. A body that is not a function is an error.
- `handle.sleep(seconds) -> boolean` and `handle.sync(beat, offset) -> boolean`: wait as `clock.sleep` and `clock.sync` do, noting when the wait ends; false once the handle was stopped (at once, or at the wake of a retired clock), and the body returns.
- `stop(handle)`: nil-safe, never raises; a stopped or ended handle is left as it is. Canceled at once while the wait's end is farther off than the margin, else retired. A clock stopped from its own body is neither: its next wait returns false.
- `cancel(handle)`: nil-safe; `clock.cancel` at once, whatever the wait, and the handle forgotten (for a cleanup step).
- `alive(handle) -> boolean`: started, never stopped, its body not ended and its coroutine not dead.
- `retired`: the retired handles by id (tests read it).
- The constants `S.constants.CLOCKS` (`sleep_margin`, `sync_tolerance`, `sync_epsilon`), the invariant `clocks` and the cleanup step `CLEANUP_ORDER.clocks` (190), which cancels every retired clock still waiting.
- Its tests: `test/unit/clocks_test.lua` (a stop as the wake is posted, driven with `context.clock.advance_until` and its `before_delivery`; a far stop; a reset's beat gone back; stops on nil, stopped, ended and running handles; cancel inside the margin; cleanup; the invariant) and, in `test/unit/structure_test.lua`, "clock.cancel is called only in lib/clocks.lua and the listed files, as often as listed".

## Moving a module onto it

The package that owns a module's file (#870; `lib/macros.lua`, `lib/morph.lua`, `lib/matrix.lua` and `lib/ui/zones.lua` in package 1q, which deletes their own retired lists) replaces the clock's `clock.run` and `clock.cancel` with `S.lib.clocks.run` and `stop`, makes every wait in its body `if not handle.sleep(...) then return end` (or `sync`), replaces a cancel in its cleanup step with `S.lib.clocks.cancel`, keeps `S.<name>_clock` as `handle.id` where a test reads it, adds the test "<the clock> stopped as its wake is posted: no clock error, and nothing more happens", and removes the file's line from `BARE_CANCEL_FILES`.

A retired sleep holds one of matron's hundred clock slots until it wakes, which is why a far wake is canceled: the cost of a retire is a slot for at most the margin (a sleep), or until the landing (a sync whose beat went back).
