## Must not break

- Every engine command needs an entry in the stub's `engine_argument_checks` (an empty one when it takes no index or enumerated value), so a new command fails until its limits are decided.
- Every parser of the engine source runs `stubs.strip_sc_comments` first, so commented-out code is never counted.
- Call engine commands only as `engine.<name>(...)`. Any other use of the global `engine` fails the sync check, which cannot see what it calls.

## Engine stub

It rejects any `engine.*` call whose name, argument count or types do not match the SC `addCommand` signatures.

It range-checks the values, with limits parsed from the engine source by `stubs.parse_engine_spec` (`numVoices`, `numBuffers`, `inputSource`, `voiceSynthDefs`, the SynthDef `arg` lists):
- voice 0..numVoices-1, slot 0..numBuffers-1, source 0..numBuffers+1;
- mod slot 1..N (`modBus1..N` on every voice SynthDef), mod source -1..numVoices-1;
- the whole-number controls the engine rounds and clips (`name.round.clip(low, high)`: `filterType` 0-2, `grainMode` 0-1), plus `envShape` 0..the number of `envBuffers`.

Continuous arguments are checked where the engine enforces a limit (`argument_limits`):
- an FX control its SynthDef clips as it is (`feedback.clip(0, 0.95)`, `freq.lag(0.05).clip(20, 20000)`: the filter's freq, res and mix, the delay's time, feedback and mix);
- or an argument the command clips itself (`msg[2].clip(0, 1)`: `retrigger`'s velocity);
- a rounding error of 1e-12 of the limit passes (a 0.01 step makes 0.95 into 0.9500000000000001).
- The engine clips no crossmod depth or mod speed, but AGENTS.md's table documents their ranges. So `setModAmpAmt`, `setModFreqAmt` and `setModSpeed` are checked against the controlspec of the Lua param that sends them (`DOCUMENTED_LIMITS`, read at call time). A test checks that AGENTS.md's row states that range.

Param names:
- A `setVoiceParam` name must be a control of that voice's SynthDef (`bend` is one).
- A `setGrainParam` name must be a control of either grain SynthDef (`grainDefFor`; the engine keeps the value for a later source switch) or a name the command handles itself (`param == \envShape`).

Keeping it current:
- Every engine command needs an entry in the stub's `engine_argument_checks`.
- A control added to a SynthDef needs no stub change, and the voice, slot and source limits follow `numVoices` and `numBuffers` (a test parses a patched copy of the engine).

Comments:
- Every parser of the engine source (the stub's `engine_signatures_from_source`, `engine_polls_from_source` and `engine_spec_from_source`, `sync_check.lua`, which uses the stub's, and the AGENTS.md table check) first runs `stubs.strip_sc_comments`.
- It blanks `//` and (nested) `/* */` comments but not strings, quoted symbols or `$x` characters, so a commented-out command, poll, SynthDef, argument or `Env` is never counted.
- An unterminated string, symbol or block comment is an error naming its line (it would otherwise swallow the rest of the file).

The spec also holds:
- `bufferSeconds` (its initial value), `standardBufferSeconds`, `bufferStateStride`, `numModSlots`;
- each SynthDef's numeric argument defaults (`synthdef_defaults`);
- `fx_commands`: the commands whose body sets an FX synth (`synths[\key] = Synth(\def, ...)`) through `this.setSynth(\key, \control, msg[i], ...)`, as a list of `{argument, synthdef, control}` read from every such `setSynth` call in the body.

Tests built on it:
- One sends every `strata_fx` param's default through `send_param_to_engine` and checks that each FX command then carries its SynthDef's defaults (the script never bangs its params, so until a param changes the engine plays those).
- Another checks that `numVoices`, `numBuffers`, `bufferStateStride` and `numModSlots` equal `NUM_VOICES`, `NUM_BUFFERS`, `BUFFER_STATE_STRIDE` and `NUM_MOD_SLOTS` (and `numModSlots` the `modBus1..N` count), and a third that `standardBufferSeconds` equals `STANDARD_BUFFER_SECONDS` (the running length is a tier value, `S.performance.buffer_seconds`).
- The engine stub reads the tier from the test's `performance_active.data` (`stubs.active_buffer_seconds`, which validates it with the script's own `parse_active_text` from `lib/performance.lua`, so a file Lua rejects runs standard in the stub too): `recordBuffer` may not ask for more seconds than a slot holds on it. `h.write_performance_active(fields)` writes that file for the next `load_strata` (fields as the engine writes them, or a string as it is; none: no file, so Lua runs standard and prints its one line). `norns.platform` is 0 (unknown) unless a test sets it.

## Sync check

`lua test/sync_check.lua` is a static check over the script's Lua files (`strata.lua` and every `lib/**/*.lua`):
- every `engine.<name>(...)` call has a matching `addCommand` with the same number of arguments, and every command is used;
- any other use of the global `engine` fails it, because the check cannot see what it calls: `engine[name](...)`, a command referenced without a call (`local f = engine.voiceOn`), `engine:x()`, a call without parentheses (`engine.loadBuffer "x"`) or the table itself as a value (`local e = engine`);
- only `engine.name` may be read or set. A table key or function parameter named `engine` (`{ engine = 1 }`, `function(a, engine)`) and `#engine` name no command and pass.
- `sync_check.check_sources(lua_sources, sc_source)` runs it on any list of `{ path = ..., text = ... }` files and reports `<path>:<line>`. The test patches `strata.lua` with each form, and checks that a bad call in a module is reported.
- `sync_check.check(lua_source, sc_source)` runs it on one source, reported as `strata.lua`.
