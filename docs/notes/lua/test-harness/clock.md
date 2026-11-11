## Must not break

- A clock error the stub records must be claimed (`context.clock.take_errors()`), or the test that left it fails: an error never passes silently. So must an error the script catches itself and prints (`context.take_script_errors()`, below, #473).

## Time and the clock

The clock follows `lua/core/clock.lua` over matron's scheduler (`clock_scheduler.cc` and `weaver.cc`).

Time:
- `util.time()` is the clock's time. It moves with `clock.advance()`/`clock.run_for()`, and `context.set_time(seconds)` moves it too.

Waits:
- `clock.run` resumes the coroutine at once, so an error in its first part reaches the caller.
- `clock.sleep(s)` wakes at `util.time() + s` (negative counts as 0, a non-number raises).
- `clock.sync(beats, offset)` wakes at the next multiple of `beats` plus `offset` on the beat timeline (`clock.get_beats()`, one beat per `clock.get_beat_sec()` = 60 / `clock.get_tempo()`), with matron's `FLT_EPSILON` (2^-23). It counts from the coroutine's previous sync beat when its last wait was a sync, so a coroutine resumed a whole period late never skips a beat. `beats <= 0` raises.
- `clock.cancel` needs an integer id.

Tempo:
- The `clock_tempo` action sets the clock's tempo (`clock.internal.set_tempo`) and calls `clock.tempo_change_handler`, as norns' does.
- A tempo change keeps the current beat (the beat timeline keeps its beat), and a waiting sync wakes at the new tempo.
- `clock.get_tempo()` returns the clock's tempo.

Transport:
- `clock.transport` is a table whose `start` and `stop` are nil until a script sets them, as norns' (`lua/core/clock.lua`). Nothing in the stub calls them: a test calls `clock.transport.start()` or `stop()` itself, as norns' `_norns.clock.start` and `stop` do when the clock source starts or stops.

What a resumed coroutine gets:
- the clock time (sleep) or beat (sync) as the return value, the one its tick posted it with;
- matron samples `clock_time` and `clock_beat` once per tick, so `clock.advance()` samples them at the step's start and every event of the step gets them (an overdue one too, and a tempo change by an earlier resume in the step cannot move them);
- `run_for` and `advance_until` fire each event at its own wake-up, so it gets the time or beat it waited for (or the one it was scheduled at, if later).

Events and slots:
- The scheduler's events are in `clock.events[id]`. They outlive the wake-up, as matron's do, and go when the coroutine is canceled or ends.
- Every yield is logged in `clock.sleep_log` (`id, mode, amount, offset`).
- Each coroutine holds one of matron's 100 event slots (`clock.slots`): the lowest free one when it first waits, kept until it is canceled or ends. All 100 in use is an error (matron would silently never wake it).
- Events due at the same time fire as matron's tick posts them: in slot order (not the order they were scheduled), and a sleep before a sync, since matron fires a sleep once the time reaches it (`>=`) and a sync once the beat is past it (`>`).

Driving it:
- `clock.advance()` is one scheduler step, a matron tick: `util.time()` moves to the earliest wake-up (never back), the events due then are fixed before any runs, and they fire in slot order. A sleep due at the step's time leaves a sync due at that time to the next step, at the same time. With the frame clock running, a step is usually a frame tick.
- `clock.advance_until(id)` runs the scheduler one event at a time until coroutine `id` wakes once, every clock due before it running first. It fails at once when `id` is not waiting ("nothing is pending" when no clock is) or another clock cancels it first.
- `clock.run_for(seconds, latency)` runs the scheduler for `seconds`, each coroutine `latency` (default 0) after its wake-up and never before `util.time()`, so a clock sleeping many short steps falls behind one long sleep, as on norns. `util.time()` ends at the start time plus `seconds`.
- Helpers in `test/helpers.lua` drive the script through it:
  - `finish_startup(context)` runs the clocks for init's start-up sleep (`STARTUP.voice_delay_seconds`, 0.5 s; voice 2 starts);
  - `next_frame(context)` runs them to the frame clock's next tick (one frame);
  - `wake(context, name)` to the next wake of the clock in script local `name` (`"pattern_clock"`, `"scene_transition_clock"`);
  - `wake_buffer_clock(context, slot)` to a slot's recording timer or fallback.
- clock.add_params' own three clocks (crow out, MIDI clock out, external tempo) are not run.

Errors in clocks:
- An error raised while the scheduler resumes a coroutine is not raised. norns prints it through `l_report` and keeps every other clock running; the coroutine stays dead in `clock.threads`, as norns never cancels it.
- The stub records it, and `context.clock.take_errors()` claims the recorded errors.
- The harness fails any test that leaves one unclaimed, so an error cannot pass silently (`run_test` in `test/helpers.lua`; a test that fails anyway gets them added to its own error).
- The script contains some errors itself and carries on: the frame clock's parts (`draw_frame_part`), the playhead tick and the menu watch print `strata: <what> failed: <error>`, the scene sequencer `scene sequencer: scene <n> failed: <error>`. A quiet install's `print` records each such line (`SCRIPT_ERROR_PATTERNS` in `test/norns_stubs.lua`) beside `context.printed`, and `run_test` treats them as it treats clock errors: a test that leaves one fails, or gets it added to its own error. A test that raises one on purpose claims it with `context.take_script_errors()`, which returns the lines, and checks what it claims: `h.claim_script_errors(context, count, prefix, last_text)` claims them and fails unless there are exactly `count`, each starting with `prefix` (`"strata: frame failed: "`), the last holding `last_text` (#473).
- A coroutine that cancels itself and then sleeps errors when it wakes (norns resumes the coroutine it no longer has).
