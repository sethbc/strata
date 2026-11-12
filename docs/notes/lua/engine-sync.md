## Must not break

- Every control param that reaches the engine has an action of the form `function(x) <store x>; send_param_to_engine(id, x) end`, and its engine call lives in `S.engine_senders[id]`. Never call `engine.*` from a control param's action. `test/unit/lfos_test.lua` (every control param with a sender sends its LFO-offset value) puts an offset on each in turn and checks that setting the param sends the sender's call with the offset value, and that a control param without a sender makes no engine call (#316).
- One path from a value to the engine: `send_engine_value` records `S.engine_param_values[id]` and runs the sender. The LFOs send through it too.
- Voice senders run only while the voice is active (`add_voice_sender`, in `lib/params_setup.lua`, gates the call on `S.voices[voice_idx].active`). The `v<i>_source` action is the one exception: it also reaches stopped voices.
- A command that carries several params builds the others from `engine_param_value(id)` (what the engine has), so an LFO on one param never undoes an LFO on another.
- A start (`S.lib.engine_sync.start_voice`, which `toggle_voice` and a pattern step call) sends `setGrainSource` and every grain value first (the nine grain params, then the registered voice params' grain keys and syncs, all `setGrainParam`), then `engine.voiceOn` with the grain size, density and pitch just sent, then the voice-level values (every synth param, the crossmod slots, `setModSpeed`, `bend`). The engine keeps a stopped voice's grain values and builds or re-gates its grain synth with them inside `voiceOn`'s bundle, so the first grain plays this start's values; sent after `voiceOn` they arrived late and the first grain played the last run's position, loop, envelope or mode (#325). Nothing but `setGrainParam` goes between the source and `voiceOn`: `voiceOn` resets the voice-level controls, so a voice-level value sent before it is lost (a test fails on it).
- A start is all or nothing (#382): a send that raises before `voiceOn` has started nothing, and once `voiceOn` is sent a grain-restart hook or a send that raises sends `engine.voiceOff` and raises the error again, so the engine and `voice.active` always agree. `voice.active` is set only once the whole start has gone out.
- Voices are 0-indexed in the engine: always pass `voice_idx - 1`. Mod sources go through `engine_mod_source()` (Lua 0 = none / 1-7 → SC -1 / 0-6).
- Action sends always go out (no dedupe). Only a Lua-run LFO's step skips sends (`docs/notes/lua/lfos.md`).
- Every `engine.setGrainSource` goes through `S.lib.engine_sync.send_grain_source(voice_idx)` (a start's first send and the `v<i>_source` action), which remembers the source the engine has per voice. A running voice whose source changed runs the `S.registry.grain_restart` hooks; the same source again, or a stopped voice's change, runs none. A start runs them after `engine.voiceOn`, before the voice-level values and before it marks the voice running (`lib/midi_in.lua`'s hook relies on that).
- A start redraws nothing itself: `toggle_voice` updates the voice list and redraws the screen and the grid after it, and a pattern step does so once for every voice it starts (#527).
- **A base override is cleared only by a hand edit of its param** (3.4): the touch hook (`S.register_param_touch`, run by an encoder, arc or grid edit) clears it; the drift, morph, a macro, gesture playback, a mutation and a recall run the param's action, whose send stays under the override. Setting and clearing an override send at once.
- **Only a deferrable send waits** (3.4): a send waits for the budget only while `S.deferrable_write` is set (`S.lib.engine_sync.deferrable(fn)`, used by the Lua LFOs, the matrix, morph, gesture playback and every macro apply). Hand edits, steps, notes, locks, recalls and voice syncs are never deferred; a send that goes at once drops its id's waiting value, so an older value never follows a newer one.
- **A voice sync or start drops the voice's waiting values** (`forget_sent_voice_values`): they are older than what the sync sends.
- **A voice sync or start keeps the voice's overrides and extra offsets**: after its own sends (which carry the stored values) it sends every param of the voice that holds a base override or an extra offset again, through `with_lfo_offsets`, at once and never deferred; with none set it sends exactly what it sent before 3.4.
- **`deferrable(fn)`'s `fn` never yields** (no `clock.sleep` or `clock.sync` inside it): `S.deferrable_write` would stay set across the wait, and a hand edit made meanwhile would be deferred. A caller that waits sleeps outside `deferrable` and wraps each burst of writes.
- **A base override is a finite number**: `set_base_override` raises, naming the param, for anything else (nil, a string, NaN, ±inf); a caller clears with `clear_base_override`.
- **Values wait exactly while `S.engine_budget_clock` runs** (the `engine budget` invariant); cleanup step 127 cancels it.

## Owns

`lib/engine_sync.lua` (`S.lib.engine_sync`):
- `send_param_to_engine`, `send_engine_value`, `engine_param_value`, `with_lfo_offsets`;
- the effects and master density senders (`send_filter_to_engine`, `send_delay_to_engine`, `send_reverb_to_engine`, `send_master_density_to_engine`), `engine_mod_source`;
- the voice start and sync functions: `toggle_voice`, `toggle_lock`, `S.lib.engine_sync.start_voice(voice_idx)` (a stopped voice's start, without redraws; a voice outside 1..`NUM_VOICES` or one already running is left alone), `sync_voice_values_to_engine` (a running voice's sync, after its source), and the local `forget_sent_voice_values`, `send_registered_voice_values`, `send_grain_params`, `send_synth_params` and `send_crossmod_and_bend`;
- `S.lib.engine_sync.grain_key_message(grain_key, value)`: a registered record's grain key and a stored value as the `setGrainParam` name and value (also used by `add_voice_extra`'s senders);
- the shared state `S.engine_senders`, `S.engine_param_values`, and the LFO offsets `S.lfo_last_dest` and `S.lfo_scaled` (declared here, before `lib/lfos.lua` is included, because param actions read them);
- cleanup step 160: `engine.voiceOff` for every running voice. norns frees the engine before it calls `cleanup()` (`Script.clear`), so on the device none of these arrives: the voices have already stopped with the engine, at once, without a release (#461; `docs/notes/lua/state-and-voices.md`, Cleanup). The unit tests' engine is never freed, so they see the calls.
- 3.4's hooks (package 0a), fields of `S.lib.engine_sync`: `set_base_override(param_id, value)`, `clear_base_override(param_id)`, `engine_base_value(param_id)`, `set_extra_offset(source_key, param_id, offset)`, `deferrable(fn)` and `budget_state()`; the shared state `S.deferrable_write` and `S.engine_budget_clock`; the touch hook that clears an override; the `lock_change` hooks `toggle_lock` runs after the flip (`fn(voice_idx, S.frozen[voice_idx])`); cleanup step 127 and the `engine budget` invariant.

## Param → engine

Params that go this way: voice synthesis params, grain and buffer params, crossmod amounts and speed, master density, filter, delay, reverb, tape drift, and `filter_type`.

`send_param_to_engine(id, value)`:
- adds the offsets of every global LFO on that param: `with_lfo_offsets(id, value)` = value + Σ `S.lfo_scaled` × half the range, clamped; the value itself when no LFO is on it;
- passes the result to `send_engine_value(id, value)`, which records `S.engine_param_values[id] = value` and runs the sender.

So an edit, a mutation, a scene-fade step or the 10 Hz drift on a modulated param never sends the plain value under a running LFO. That mattered for `bufPos`, which has no lag in the engine: the stored position gave stray grains.

## 3.4's modulation hooks

Three additions, for step locks, LFOs on macros, the matrix and the deferrable writers (design §0.1). Nothing in 3.3's code uses them yet, so the engine gets what it got.

**The base override** (`S.lib.engine_sync.set_base_override(param_id, value)`, `clear_base_override(param_id)`, `engine_base_value(param_id)`):
- While an override is set, `with_lfo_offsets(param_id, value)` starts from it instead of `value`, so every send of the param (its action's, an LFO step's) carries the override plus the offsets. The stored value keeps changing underneath: a param action stores its value and its send is held under the override.
- Setting and clearing send at once, through `send_engine_value(id, with_lfo_offsets(id, params:get(id)))`; clearing a param with no override sends nothing. The value is a finite number (anything else raises, naming the param).
- A voice's sync (`sync_voice_values_to_engine`) and start (`S.lib.engine_sync.start_voice`, once the voice is marked running, so its gated senders send) end by sending, in id order, every param of the voice that holds an override or an extra offset, with `with_lfo_offsets(id, params:get(id))`, at once whatever `S.deferrable_write` says: their own sends carry the stored values (as they carry no LFO offset), so without it the engine would lose a step lock or an extra until the param was next sent.
- `engine_base_value(id)` is the override, else `params:get(id)`.
- This module registers a touch hook (`S.register_param_touch`) that clears the touched param's override: an encoder, arc or grid edit ends it. The drift's writes (`set_drifted_param`), morph, macros, gesture playback, mutations and recalls are no touch, so none of them ends a step lock.

**Extra offsets** (`S.lib.engine_sync.set_extra_offset(source_key, param_id, offset)`, nil clears): offsets in the param's own units, one per source key (a mod source's key), summed in `with_lfo_offsets` with the LFOs' offsets (scaled × half the range) and clamped once to the range with them. A param with an extra counts as modulated (its value is clamped even when the extras sum to 0). It sends nothing: the source sends the param when it moves. Lua destinations only: a fast destination's extras join the engine's `setFastOffset` sum.

**The send budget** (Question 23): `send_engine_value` counts every send in the current window, `math.floor(util.time() / ENGINE_BUDGET.window_seconds)` (0.1 s; the window index never goes back):
- A send made while `S.deferrable_write` is set, once the window has had `ENGINE_BUDGET.messages_per_window` (150) sends, is not sent: it is kept as its id's pending value (a newer one replaces it) and is not recorded in `S.engine_param_values` until it goes.
- The pending values go first in the next window, in the order their ids first waited, from the first send of that window or from the flush clock (`S.engine_budget_clock`), which sleeps to the next window's start and runs only while something waits. They count against that window; what the budget cannot take waits one more window.
- `S.lib.engine_sync.deferrable(fn)` runs `fn` with `S.deferrable_write` true and puts the flag back as it was, even if `fn` raises (the error is raised again, with its traceback). `fn` never yields: a writer that runs on a clock sleeps outside `deferrable` and wraps each step's writes.
- A send made outside `deferrable` always goes at once (and counts) and drops its id's pending value. `forget_sent_voice_values(voice_idx)` (a voice sync or start) drops the voice's pending values too, so a waiting value never lands after the sync's newer one.
- `budget_state()` returns `{sent = <this window's count>, pending = <ids waiting>}`, for tests.
- Cleanup step 127 cancels the clock and drops what waits.

Commands that carry several params:
- `engine_param_value(id)` is the last value sent, or `params:get(id)` before any.
- `send_filter_to_engine`, `send_delay_to_engine` and `send_reverb_to_engine` build `setFilter`/`setDelay`/`setReverb` from it.
- The grain density sender multiplies by `engine_param_value("master_density")`.
- The master density sender (`send_master_density_to_engine`) multiplies by each running voice's `engine_param_value("v<i>_grain_density")`.

Voice sync and start:
- The parts, as the engine takes them: `send_grain_params` (grainSize, grainDensity = the stored density × `engine_param_value("master_density")`, pitchShift, posSpread, envShape, grainMode, bufPos, bufRate, bufScan) and `send_registered_voice_values` are `setGrainParam` messages, which the engine keeps for a stopped voice too; `send_synth_params` (every `voices[i].params` entry) and `send_crossmod_and_bend` (the `NUM_MOD_SLOTS` slots, `setModSpeed`, `bend` = `S.midi_state.bend[i]`) are voice-level controls, which `voiceOn` resets.
- `sync_voice_values_to_engine` (a running voice: a source switch, a scene recall) sends the voice's stored values: `forget_sent_voice_values(voice_idx)` first, so an LFO re-applies its offset on its next step, then the synth params, the grain params, crossmod and bend, and the registered voice params. It sends no source: the `v<i>_source` action has sent it, both for a switch and for a recall (which syncs a running voice whose source it changed, `docs/notes/lua/scenes.md`).
- `S.lib.engine_sync.start_voice` (a stopped voice) sends the same messages with the same values in the start's order: `forget_sent_voice_values`, `send_grain_source` (no hook: the voice is not running yet), the grain params, the registered voice params, `voiceOn`, the grain-restart hooks, the synth params, crossmod and bend; then it marks the voice running. `voiceOn`'s density is the stored density times the master density the engine has, as the grainDensity just sent (an LFO on the voice's density re-applies its offset on its next step).
- The registered voice params (`send_registered_voice_values`): per `S.registry.voice_params` record, in registration order, each `grain_keys` entry (sorted by key) with the voice's `extras[key]`, then the record's `sync(voice_idx)` (`docs/notes/lua/params.md`). At a start they go before `voiceOn`, so a record's `sync` sends grain params only (`setGrainParam`).
- What a start leaves: for its first milliseconds a synth voice plays its SynthDef defaults for the synth params `voiceOn` does not carry, and a buffer or input voice's first grain has no crossmod and bend 1, until the voice-level values arrive. Those are neutral values, not another run's.

Adding a param that reaches the engine:
- give it a sender in `S.engine_senders` and call `send_param_to_engine` from its action;
- option and number params the LFOs cannot target (source, grain envelope/mode, mod sources) still call the engine from their action.
