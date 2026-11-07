## Must not break

- The stubs mirror the real norns libraries (`~/src/norns/lua`) and matron. Check behavior there before changing a stub.
- `param.t` holds numeric type codes (`params.tOPTION`, ...). Never compare it with a string; a test enforces this, with either quote and either order.
- Every engine command needs an entry in the stub's `engine_argument_checks` (an empty one when it takes no index or enumerated value), so a new command fails until its limits are decided.
- Every parser of the engine source runs `stubs.strip_sc_comments` first, so commented-out code is never counted.
- A clock error the stub records must be claimed (`context.clock.take_errors()`), or the test that left it fails: an error never passes silently.
- Call engine commands only as `engine.<name>(...)`. Any other use of the global `engine` fails the sync check, which cannot see what it calls.
- Only one engine check runs per scsynth port: runs on the same port collide.
- `test/StrataTestNoBoot.sc.in` stays a `.sc.in` file: norns compiles every `.sc` under `~/dust`, and that test class disables Crone's boot.

## Owns

`test/run.lua` (the runner), `test/helpers.lua` (the shared harness), the unit files under test/unit/ (one per module; CLAUDE.md's module table names each), `test/norns_stubs.lua`, `test/stub_lfo.lua`, `test/stub_midi.lua`, `test/sync_check.lua`, `test/run_engine_check.sh`, `test/engine_check.scd`, `test/StrataTestNoBoot.sc.in`.

## The Lua test run

- `lua test/run.lua` and `luajit test/run.lua` load every `test/unit/*_test.lua` (listed and sorted by `load_unit_files` in `test/helpers.lua`, so a new unit file needs no runner edit) and run their tests. With an argument (`lua test/run.lua scenes`) they load only the unit files whose name contains it.
- Each unit file is `return function(h) ... end`: it registers its tests with `h.test(name, fn)` and takes the helpers from `h`.
- `test/helpers.lua` holds the harness: the stubs, the test registry and `run_test`, the assertions, `load_strata`, `find_upvalue`/`local_value`, the clock drivers and the helpers several unit files share.
- The tests load `strata.lua` into norns stubs (`test/norns_stubs.lua`). The run exits non-zero on failure and includes the static sync check.

### Engine stub

It rejects any `engine.*` call whose name, argument count or types do not match the SC `addCommand` signatures.

It range-checks the values, with limits parsed from the engine source by `stubs.parse_engine_spec` (`numVoices`, `numBuffers`, `inputSource`, `voiceSynthDefs`, the SynthDef `arg` lists):
- voice 0..numVoices-1, slot 0..numBuffers-1, source 0..numBuffers+1;
- mod slot 1..N (`modBus1..N` on every voice SynthDef), mod source -1..numVoices-1;
- the whole-number controls the engine rounds and clips (`name.round.clip(low, high)`: `filterType` 0-2, `grainMode` 0-1), plus `envShape` 0..the number of `envBuffers`.

Continuous arguments are checked where the engine enforces a limit (`argument_limits`):
- an FX control its SynthDef clips as it is (`feedback.clip(0, 0.95)`, `freq.lag(0.05).clip(20, 20000)`: the filter's freq, res and mix, the delay's time, feedback and mix);
- or an argument the command clips itself (`msg[2].clip(0, 1)`: `retrigger`'s velocity);
- a rounding error of 1e-12 of the limit passes (a 0.01 step makes 0.95 into 0.9500000000000001).
- The engine clips no crossmod depth or mod speed, but CLAUDE.md's table documents their ranges. So `setModAmpAmt`, `setModFreqAmt` and `setModSpeed` are checked against the controlspec of the Lua param that sends them (`DOCUMENTED_LIMITS`, read at call time). A test checks that CLAUDE.md's row states that range.

Param names:
- A `setVoiceParam` name must be a control of that voice's SynthDef (`bend` is one).
- A `setGrainParam` name must be a control of either grain SynthDef (`grainDefFor`; the engine keeps the value for a later source switch) or a name the command handles itself (`param == \envShape`).

Keeping it current:
- Every engine command needs an entry in the stub's `engine_argument_checks`.
- A control added to a SynthDef needs no stub change, and the voice, slot and source limits follow `numVoices` and `numBuffers` (a test parses a patched copy of the engine).

Comments:
- Every parser of the engine source (the stub's `engine_signatures_from_source`, `engine_polls_from_source` and `engine_spec_from_source`, `sync_check.lua`, which uses the stub's, and the CLAUDE.md table check) first runs `stubs.strip_sc_comments`.
- It blanks `//` and (nested) `/* */` comments but not strings, quoted symbols or `$x` characters, so a commented-out command, poll, SynthDef, argument or `Env` is never counted.
- An unterminated string, symbol or block comment is an error naming its line (it would otherwise swallow the rest of the file).

The spec also holds:
- `bufferSeconds`, `bufferStateStride`, `numModSlots`;
- each SynthDef's numeric argument defaults (`synthdef_defaults`);
- `fx_commands`: the commands whose body sets an FX synth (`synths[\key] = Synth(\def, ...)`) through `this.setSynth(\key, \control, msg[i], ...)`, as a list of `{argument, synthdef, control}` read from every such `setSynth` call in the body.

Tests built on it:
- One sends every `strata_fx` param's default through `send_param_to_engine` and checks that each FX command then carries its SynthDef's defaults (the script never bangs its params, so until a param changes the engine plays those).
- Another checks that `numVoices`, `numBuffers`, `bufferSeconds`, `bufferStateStride` and `numModSlots` equal `NUM_VOICES`, `NUM_BUFFERS`, `BUFFER_SECONDS`, `BUFFER_STATE_STRIDE` and `NUM_MOD_SLOTS` (and `numModSlots` the `modBus1..N` count).

### Param types

- Like norns, the param stub stores numeric type codes in `param.t` (`params.tOPTION` etc.), all from its one `PARAM_TYPE_CODES` table (exported as `stubs.PARAM_TYPE_CODES`).
- `params:add` with an unknown type raises an error (norns prints one and adds nothing).
- Never compare `param.t` with a string. A test enforces this for the script's sources, with either quote and either order: `p.t == "option"`, `'option' == p.t`.

### Sync check

`lua test/sync_check.lua` is a static check over the script's Lua files (`strata.lua` and every `lib/**/*.lua`):
- every `engine.<name>(...)` call has a matching `addCommand` with the same number of arguments, and every command is used;
- any other use of the global `engine` fails it, because the check cannot see what it calls: `engine[name](...)`, a command referenced without a call (`local f = engine.voiceOn`), `engine:x()`, a call without parentheses (`engine.loadBuffer "x"`) or the table itself as a value (`local e = engine`);
- only `engine.name` may be read or set. A table key or function parameter named `engine` (`{ engine = 1 }`, `function(a, engine)`) and `#engine` name no command and pass.
- `sync_check.check_sources(lua_sources, sc_source)` runs it on any list of `{ path = ..., text = ... }` files and reports `<path>:<line>`. The test patches `strata.lua` with each form, and checks that a bad call in a module is reported.
- `sync_check.check(lua_source, sc_source)` runs it on one source, reported as `strata.lua`.

### Docs checks

- CLAUDE.md's command table under "Lua ↔ SuperCollider Communication" must have exactly one row per engine `addCommand`, with the same signature and argument count. Update the table in the same commit as the engine.
- No `engine.<name>(` mentioned in the maintained docs may name a command the engine no longer has. The maintained docs are CLAUDE.md, README.md, `docs/status.md` and every `.md` under docs/notes/ (recursively) and docs/user/ (`maintained_docs` in `test/helpers.lua`).
- Every repo path the maintained docs name in backticks (under docs/, test/, .github/ and lib/) must exist, from the repo root. A relative Markdown link target must exist relative to the doc's own folder (`doc_paths_missing(text, doc_name)`); `docs/notes/lua.md` alone may still link root files from the repo root, a fallback to delete with that file. A norns library is named by its path in the norns repo (`lua/lib/lfo.lua`), which is not checked.
- Every file in docs/notes/lua/ must have `## Must not break` as its first heading (headings inside code fences do not count).
- Every changelog fragment in changes/ (`changes/README.md` aside) must hold an `### Added`, `### Changed` or `### Fixed` heading with a bullet under it.
- These checks are in `test/unit/docs_test.lua`.

### Reaching script state

- Add a test for every behavior change.
- Script values are reached through `find_upvalue()`/`local_value()`. They look in the shared table `S` (`lib/state.lua`, found as the upvalue `S` of `init`; a key ever assigned into `S`, even to nil, is recorded in `S.__declared` and found while nil), then in `S.constants`, then in the script locals (the upvalues of global functions). The setter writes where the name was found.
- The stub's `include(file)` follows norns' `lua/core/startup.lua`: it runs the script folder's `<file>.lua` with `dofile` on every call.
- Only `strata.lua` includes, each module once, by its `lib/` path. A test checks this, and that a reload builds an `S` sharing no table with the last one.
- `load_strata { source = text }` loads a patched copy of `strata.lua`, and `load_strata { module_sources = { ["lib/x"] = text } }` patched modules. `patched_script(pattern, replacement)` builds either from whichever file holds the pattern.
- `read_lua_sources()` returns the script's Lua files (`strata.lua`, then `lib/**/*.lua`) for the tests that read the source.
- `MODULE_HOMES` (`test/unit/structure_test.lua`) maps a module path to the global functions it must define.
- Each `load_strata` gets a data directory of its own, named by a counter (tests reseed `math.random`, so a random name could repeat). `load_strata { data_subdir = name }` shares one between loads (the persistence tests).

### Module safety nets

The Wave 0 golden master (a logged scripted session compared with a fixture) proved the module split changed no behavior and was retired once the split was done; git history keeps it.

- **Global-reference check** (Lua 5.3 only; it needs `luac` or `luac5.3` on PATH and fails without one; LuaJIT prints a skip note):
  - `luac -l -l -p` lists each file's `GETTABUP`/`SETTABUP` on `_ENV` (the name in the comment, or for a key past the first 256 constants the `LOADK` into its register);
  - every global read must be written by some script file or be a key of `_G` right after `stubs.install` (norns and the standard library);
  - `KNOWN_UNDEFINED_GLOBALS` lists reads allowed while their bug is open (none today).
- **Duplicate-global check** (same listing, Lua 5.3 only): no global, function or value, is written by more than one file, since a later include would silently replace the earlier definition. `GLOBALS_WRITTEN_IN_TWO_FILES` allows `key` and `enc`, which `lib/pages/buffer.lua` puts back when the file selector fails.
- **Locals probe**:
  - inserts `local p1, ..., pN` at the end of each file's main chunk (before a module's final top-level `return`) and of each constructor (before its final `  return M\nend`; every module but the plain constants table must end that way);
  - finds the largest N that loads;
  - requires at least 30 in each main chunk and each constructor, `strata.lua` included (195 free in its main chunk today).

### Group sizes

norns cannot see where a group ends (it takes the next `n` params), so the param stub requires each group to get exactly `n` params. It errors:
- when the next group arrives first (this is also the nesting error);
- when the param after the group's last one is neither a separator nor a group (`n` too small);
- in `context.check_param_groups()`, which `load_strata` calls after `init()`, when a group is still short at the end of the list.

## The stubs

The stubs mirror the real norns libraries (`~/src/norns/lua`), so check behavior there before changing them.

### Params

- Types: number, control, option, binary, trigger, file, text, separator, group.
- `set_action`, `hide`/`show`/`visible`.
- `params:write(path)`/`params:read(path, silent)` as in `lua/core/paramset.lua`, absolute paths only. Read sets each param in file order through its own `set`, so actions fire mid-read as on norns. `params:set_save(id, false)` keeps a param out of the file, as norns does for most system params.
- Strings as `core/params/*.lua`: a control without a formatter shows `util.round(value, 0.01) .. " " .. units`; a number or binary returns its value, a number.
- A ControlSpec made without a default has `default` nil, and its control starts at raw 0.
- Warps: `exp`, `db` and `lin`.
- norns' system params come first (`audio.add_params` and `clock.add_params`: the LEVELS, REVERB, COMPRESSOR, SOFTCUT and CLOCK groups with their types, ranges and factory defaults, `clock_tempo` 120). Every id of `core/paramset.lua`'s `system_param_ids` is there but `clock_midi_out`, which norns never adds (its params are `clock_midi_out_1..16`). So a script param with a system id fails as a collision.

### Libraries

- `tab.save`/`tab.load`: lib/tabutil.lua's, ported unchanged. The `-- Table: {n}` layout; numbers go through `tostring`, so they keep 14 significant digits as on norns. A plain `return {...}` file loads as nil, so test fixtures are written with `tab.save`, or the `tabutil_text(value)` helper in `test/helpers.lua`.
- `require("lfo")`: `test/stub_lfo.lua`, compared line by line with `lua/lib/lfo.lua`.
  - The library's `lfo_*` params and actions; `reset_phase` and `set("period")` reset and rescale `phase_counter` as the library does.
  - Nothing runs on its own: `context.lfo.tick(instance, raw)` performs one library step, with `raw` 0..1 as the shape output.
- `midi`: `test/stub_midi.lua`. 16 vports, `to_msg`/`to_data`. Helpers `context.midi.plug(port, name)`, `unplug(port)`, `send(port, msg)`.
- `poll.set`: the system polls plus the engine's `addPoll` names; unknown names return nil. `context.polls.fire(name, value)` reaches started polls.
- `require("fileselect")`: a module through `package.preload`, never a global, so a script that relies on a `fileselect` global fails.
  - `enter` records `context.fileselect.last`, and its callback in `fileselect.callback` (as `fs.enter` keeps it in `fs.callback`, so a second `enter` replaces the first's).
  - From play mode, `enter` calls `norns.menu.init()` (so a script's `_menu.set_mode` wrapper runs), makes the `redraw()` call norns' `fs.enter` makes, then its own `fileselect.redraw()`.
  - `fileselect.redraw` draws nothing and counts its calls in `context.fileselect.redraws`.
  - `context.fileselect.close(path)` closes it as `fs.exit` does: from play mode `norns.menu.init()` and `redraw()`, then the callback with `path`, or `"cancel"` when nil.
  - Keys and encoders are not rerouted.
- `require("musicutil").note_num_to_freq`, `_path.audio` (`context.audio_dir`), `util.scandir`/`util.os_capture`, `_menu.rebuild_params`.
- `_menu.set_mode(mode)` tracks `_menu.mode`. `set_mode(false)` records the play-mode routing from the globals, `_menu.key = key` and `norns.encoders.callback = enc`, as norns does. It swaps no handlers and draws nothing.
- `norns.menu.init()` is `_menu.set_mode(_menu.mode)`.
- `screen.line`/`screen.rect` are recorded in `context.screen.lines` (`x1, y1, x2, y2, level`) and `context.screen.rects` (`x, y, w, h, level`) beside the texts.
- `norns.enc.accel`/`sens`: state in `context.encoders.accel`/`sens`, starting at norns' script defaults (accel on, sens 2). `context.encoders.deliver(n, delta, interval)` delivers one hardware encoder event the way `encoders.process_with_accel` does, with `interval` seconds since the previous one.

### Time and the clock

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
- A coroutine that cancels itself and then sleeps errors when it wakes (norns resumes the coroutine it no longer has).

## The engine check

`test/run_engine_check.sh [path/to/norns]`:
- compiles `lib/Engine_Strata.sc` against the real norns `sc/core` classes (default `~/src/norns`, or `$NORNS_DIR`);
- boots a local scsynth with its output on a private bus (silent) and runs `test/engine_check.scd`, which drives every engine command.

Its own SynthDefs, to hear what a bus carries:
- `\strataCheckTone`: a 440 Hz tone written into `inputBus`;
- `\strataCheckPeak`: a resettable peak meter on a stereo bus;
- `\strataCheckSine`/`\strataCheckStep`: a sine of any frequency, and the largest sample-to-sample step on a bus, for the filter crossfade;
- added by `addAudioCheckDefs`: `\strataCheckChannelPeaks` (per-channel peaks, for pan), `\strataCheckBadValues` (NaN/inf seen on a bus), `\strataCheckRms` (a bus's RMS over about 1.5 s) and `\strataCheckBadSource` (50 ms of inf and NaN; a float overflow, since `log(0)` is not -inf in scsynth).

Structure:
- The check routine is at sclang's per-function selector limit: new checks go in top-level functions called from it.
- Every server reply it waits for goes through `awaitReply` (5 s, then a FAIL), and the whole check fails after 540 s, so a reply that never comes fails the check instead of hanging it (CI kills the job at 600 s).

What fails it, besides a failed check: any output line with `ERROR` at its start, `FAILURE` (the server's report of a failed command), `alloc failed`, `Too many grains` (a grain UGen past `maxGrains`) or `Strata invariant broken`.

Timeouts and processes:
- The script runs sclang under `timeout` (`ENGINE_CHECK_TIMEOUT`, default 570 s; a normal run takes about 2 minutes) with line-buffered output (`stdbuf`).
- It stops sclang as soon as the output shows a compile error (a syntax error in `engine_check.scd`, `Library has not been compiled successfully`): sclang never exits by itself then, and would hold the machine and CI's job until killed.
- `timeout` signals the whole process group, so the scsynth sclang booted goes too. Without a `timeout` command, the script's own watch loop enforces the limit.
- The script's own stop signals sclang and every descendant (`kill_tree`, children first), so no scsynth is left on its port. Exit 124 or 137 (timeout's `--kill-after` SIGKILL) reports as a timeout.

Ports:
- Each run boots scsynth on `$STRATA_SC_PORT` (default 57110). Runs on different ports (avoid 57120 and the few above it, used by sclang itself) can overlap; runs on the same port collide. `docs/status.md` (Running the checks) has the details.

Setup:
- Needs SuperCollider: sclang is `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app path.
- On Linux scsynth also needs a running JACK server. CI and local runs use a dummy driver: `jackd --no-realtime -d dummy -r 48000 -p 1024 &` (check with `jack_lsp`). `QT_QPA_PLATFORM=offscreen` keeps sclang headless.

## On hardware

On norns, norns shield or fates:
- Use maiden (the norns web IDE at `http://norns.local/maiden`) to edit files and watch the console.
- The maiden REPL is useful for trying Lua code.
- SuperCollider changes need a script restart.
- Watch for errors in the maiden console (bottom panel).
