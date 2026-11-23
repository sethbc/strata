## Must not break

- **A clock is never canceled while its resume may be posted** (#626, #870): norns delivers every resume matron has posted, and one whose coroutine was canceled meanwhile makes `clock.resume` raise (maiden prints `bad argument #1 to 'resume'`). `S.lib.clocks.stop(handle)` cancels a clock only while its wait's end is farther off than the margin; otherwise it retires it, and the clock ends at its own wake, its wait returning false and its body returning. The margin is `CLOCKS.sleep_margin` (0.1 s, `lib/ui/zones.lua`'s `learn_wake_margin`) before a sleep's wake and `CLOCKS.sync_tolerance` (1/32 beat, `lib/quantize.lua`'s `wake_tolerance`) before a sync's landing; a sync whose beat is below the one it synced at (a reset or a new clock source moved it) is retired too.
- **Every wait in a helper clock's body goes through its handle** and returns when the wait says false: `if not handle.sleep(seconds) then return end`, or `handle.sync(beat, offset)`. A body that waits with a bare `clock.sleep` or `clock.sync` is not told it was stopped and runs on; a `stop` while it waits so (its `waiting` nil and its coroutine, `clock.threads[id]`, suspended) retires it, its wait's end not known, and records it in `M.bare[id]`, which only `cancel` and the cleanup step clear (#954), so the `clocks` invariant names it after the test even when the clock ran on and ended. A stop from the body's own run is no bare wait: its coroutine is "running", or "normal" while a coroutine the body resumed makes the stop; nor is a stop of a handle whose body raised (its coroutine "dead", left in `clock.threads` by `clock.resume`), which does nothing more.
- **A sync's landing is worked out as matron's scheduler does** (`clock_scheduler_next_clock_beat`, `CLOCKS.sync_epsilon`): from the beat the sync was asked at, or, when the coroutine's last wait was a sync, from the landing matron stored for it (`clock_scheduler_schedule_sync` counts from the event's stored landing, never from the beat its tick posted the resume with, which is up to a tick later and, with an offset just under a period, a whole period off). The helper works that stored landing out from the resume's beat `woke` (`counted_from`, #953): matron's tick posts a sync once the beat is past its landing, so the landing lies just below `woke`, and it is always on the sync's grid (`k * beats + offset`: the helper's landing, or the one a new clock source's reschedule found after its new beat), but for a reset's 0. So it counts from the grid point at most `CLOCKS.sync_tolerance` below `woke` when that is no later than the helper's landing (a resume a tick late; a beat moved back) or the landing was still ahead when the sync was asked (a reschedule forward past it); from 0 when the beat went back to within the tolerance of 0 (a reset); else from `math.min(landing, woke)` (a landing already past when asked fires at once). `lib/gestures.lua` still has `math.min(landing, woke)` until it moves onto the helper (package 1f). A landing not known (a sync given no positive beat) retires.
- **What the landing estimate costs**: it is matron's after a beat moved back (a new clock source) and after one moved forward past the landing, and never later than matron's but in one case, which the helper cannot tell from a reschedule forward: a tick of matron's that posts the resume at least a period less the tolerance after its landing (its tick thread stalled). The next landing is then counted a period late and a stop near the true one may cancel while its resume is posted. Where the estimate is earlier than matron's (a reschedule back to within the tolerance of 0, or a grid point the float division misses), a stop retires where it could cancel, which holds a clock slot for at most a period.
- **`cancel(handle)` is for cleanup steps only**: it cancels at once, whatever the wait, which is safe only when norns ends every clock anyway. The cleanup-order test sees a step through its `clock.cancel`.
- **The helper's cleanup step is the last of all** (`CLEANUP_ORDER.clocks`, 190): a step before it can still retire a clock (the grids' own step, 170, ends their hold clocks).
- **`handle.id` is not known inside the body before its first wait** (`clock.run` resumes the coroutine before it returns). A module keeps the handle; where its tests read `S.<name>_clock`, it sets that to `handle.id` once `run` has returned, and to nil at a stop.
- `clock.cancel` is called only in `lib/clocks.lua` and the files `test/unit/structure_test.lua` lists, as often as listed: `BARE_CANCEL_FILES` (the nineteen that move onto the helper, each in the package that owns it, which removes its line) and `EDGE_CANCEL_FILES` (the nine that cancel only as the script starts or ends, and `lib/sequencer.lua` and `lib/quantize.lua`, which keep their own rule). The first list only shrinks.

## Machines

### clocks
- **State:** a handle's `waiting` (`"sleep"`, `"sync"` or nil while its body runs), `stopped`, `ended` (its body returned; a canceled one's never does), the wait's `wake` (a sleep) or `sync_beat` and `landing` (a sync), `M.retired[id]` (the stopped handles that still wait for their wake) and `M.bare[id]` (the handles stopped while their body waited outside them, kept until `cancel` or cleanup); `S.lib.clocks.alive(handle)` names a running one.
- **Invariant:** `clocks`: no handle is in `M.bare`, and every retired handle is a stopped one under its own id whose coroutine is pending until its wake (it is forgotten when it ends).
- **Test:** `test/unit/clocks_test.lua`: "the invariant fails for a retired handle whose coroutine is dead and still kept".

| State | Event | Next | Effect |
|---|---|---|---|
| running | its body waits (`handle.sleep`, `handle.sync`) | waiting | the wait's end noted |
| running | `stop` (from its own body, or a coroutine the body resumed) | stopped | its next wait returns false at once |
| running | its body returns | ended | forgotten if it was retired |
| running | its body raises | raised | its coroutine dead, left in `clock.threads`; the error is reported |
| raised | `stop` | stopped | nothing more: no bare wait |
| running, waiting outside its handle | `stop` (from outside its body) | retired | kept in `M.retired` and `M.bare`: the invariant fails |
| retired, waiting outside its handle | its bare wait ends and the body runs on | stopped | forgotten from `M.retired`, still in `M.bare`: the invariant fails until `cancel` or cleanup |
| stopped | its body waits | stopped | the wait returns false at once, without waiting |
| stopped | its body returns | ended | nothing kept |
| waiting | its wake | running | the wait returns true |
| waiting | `stop`, the end farther off than the margin | canceled | `clock.cancel` at once; its body never resumes |
| waiting | `stop`, the end within the margin, past, or the beat gone back | retired | kept in `M.retired` |
| waiting | `cancel` | canceled | `clock.cancel` at once; its body never resumes |
| retired | its wake | ended | the wait returns false, the body returns, the handle forgotten |
| retired | `cancel`, or cleanup step 190 | canceled | `clock.cancel`, the handle forgotten (from `M.bare` too) |
| stopped, retired, canceled or ended | `stop` | unchanged | nothing |

## Owns

`lib/clocks.lua` (`S.lib.clocks`, 3.9, design section 3, package 0b), included first after the constants:
- `run(fn) -> handle`: starts a clock (`clock.run`) whose body is `fn(handle)`; `handle.id` is the clock's id once `run` returns. A body that is not a function is an error.
- `handle.sleep(seconds) -> boolean` and `handle.sync(beat, offset) -> boolean`: wait as `clock.sleep` and `clock.sync` do, noting when the wait ends; false once the handle was stopped (at once, or at the wake of a retired clock), and the body returns.
- `stop(handle)`: nil-safe, never raises; a stopped or ended handle is left as it is. Canceled at once while the wait's end is farther off than the margin, else retired. A clock stopped from its own body is neither: its next wait returns false. One stopped from outside while its body waits on a bare `clock.sleep` or `clock.sync` is retired and marked `bare` (a mistake the invariant names).
- `cancel(handle)`: nil-safe; `clock.cancel` at once, whatever the wait, and the handle forgotten (for a cleanup step).
- `alive(handle) -> boolean`: started, never stopped, its body not ended and its coroutine not dead.
- `retired`: the retired handles by id (tests read it); `bare`: the handles stopped while their body waited outside them, by id, until `cancel` or cleanup.
- The constants `S.constants.CLOCKS` (`sleep_margin`, `sync_tolerance`, `sync_epsilon`), the invariant `clocks` and the cleanup step `CLEANUP_ORDER.clocks` (190), which cancels every retired clock still waiting.
- Its tests: `test/unit/clocks_test.lua` (a stop as the wake is posted, driven with `context.clock.advance_until` and its `before_delivery`; a far stop; a reset's beat gone back; stops on nil, stopped, ended and running handles; cancel inside the margin; cleanup; the invariant; a repeated sync resumed a tick late, driven with `context.set_time` and `context.clock.advance`, which posts the beat at its step's time, after a beat moved back too; a sync rescheduled forward past its landing; a stop during a bare wait, still named once the clock ran on; stops from a coroutine the body resumed, from another clock's body and of a body that raised; forward jumps of the beat with `context.clock.set_beat`; the margins pinned to zones', the macros' and quantize's) and, in `test/unit/structure_test.lua`, "clock.cancel is called only in lib/clocks.lua and the listed files, as often as listed".

## Moving a module onto it

The package that owns a module's file (#870; `lib/macros.lua`, `lib/morph.lua`, `lib/matrix.lua` and `lib/ui/zones.lua` in package 1q, which deletes their own retired lists) replaces the clock's `clock.run` and `clock.cancel` with `S.lib.clocks.run` and `stop`, makes every wait in its body `if not handle.sleep(...) then return end` (or `sync`), replaces a cancel in its cleanup step with `S.lib.clocks.cancel`, keeps `S.<name>_clock` as `handle.id` where a test reads it, adds the test "<the clock> stopped as its wake is posted: no clock error, and nothing more happens", and removes the file's line from `BARE_CANCEL_FILES`.

A retired sleep holds one of matron's hundred clock slots until it wakes, which is why a far wake is canceled: the cost of a retire is a slot for at most the margin (a sleep), or until the landing (a sync whose beat went back).
