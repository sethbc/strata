## Must not break

- Every control param that reaches the engine has an action of the form `function(x) <store x>; send_param_to_engine(id, x) end`, and its engine call lives in `S.engine_senders[id]`. Never call `engine.*` from a control param's action.
- One path from a value to the engine: `send_engine_value` records `S.engine_param_values[id]` and runs the sender. The LFOs send through it too.
- Voice senders run only while the voice is active (`add_voice_sender`, in `lib/params_setup.lua`, gates the call on `S.voices[voice_idx].active`). The `v<i>_source` action is the one exception: it also reaches stopped voices.
- A command that carries several params builds the others from `engine_param_value(id)` (what the engine has), so an LFO on one param never undoes an LFO on another.
- `toggle_voice` calls `engine.voiceOn` and then `sync_voice_to_engine`, which sends `setGrainSource` first, then every synth, grain and crossmod value.
- Voices are 0-indexed in the engine: always pass `voice_idx - 1`. Mod sources go through `engine_mod_source()` (Lua 0 = none / 1-7 → SC -1 / 0-6).
- Action sends always go out (no dedupe). Only `apply_lfo` skips sends (`docs/notes/lua/lfos.md`).
- Every `engine.setGrainSource` goes through `S.lib.engine_sync.send_grain_source(voice_idx)` (the sync's first send and the `v<i>_source` action), which remembers the source the engine has per voice. A running voice whose source changed runs the `S.registry.grain_restart` hooks; the same source again, or a stopped voice's change, runs none. `toggle_voice` runs them after `engine.voiceOn`, before the sync.

## Owns

`lib/engine_sync.lua` (`S.lib.engine_sync`):
- `send_param_to_engine`, `send_engine_value`, `engine_param_value`, `with_lfo_offsets`;
- the effects and master density senders (`send_filter_to_engine`, `send_delay_to_engine`, `send_reverb_to_engine`, `send_master_density_to_engine`), `engine_mod_source`;
- the voice start and sync functions: `toggle_voice`, `toggle_lock`, `sync_voice_to_engine`, `sync_voice_values_to_engine`, `forget_sent_voice_values`, `send_registered_voice_values`;
- `S.lib.engine_sync.grain_key_message(grain_key, value)`: a registered record's grain key and a stored value as the `setGrainParam` name and value (also used by `add_voice_extra`'s senders);
- the shared state `S.engine_senders`, `S.engine_param_values`, and the LFO offsets `S.lfo_last_dest` and `S.lfo_scaled` (declared here, before `lib/lfos.lua` is included, because param actions read them);
- cleanup step 160: `engine.voiceOff` for every running voice.

## Param → engine

Params that go this way: voice synthesis params, grain and buffer params, crossmod amounts and speed, master density, filter, delay, reverb, tape drift, and `filter_type`.

`send_param_to_engine(id, value)`:
- adds the offsets of every global LFO on that param: `with_lfo_offsets(id, value)` = value + Σ `S.lfo_scaled` × half the range, clamped; the value itself when no LFO is on it;
- passes the result to `send_engine_value(id, value)`, which records `S.engine_param_values[id] = value` and runs the sender.

So an edit, a mutation, a scene-fade step or the 10 Hz drift on a modulated param never sends the plain value under a running LFO. That mattered for `bufPos`, which has no lag in the engine: the stored position gave stray grains.

Commands that carry several params:
- `engine_param_value(id)` is the last value sent, or `params:get(id)` before any.
- `send_filter_to_engine`, `send_delay_to_engine` and `send_reverb_to_engine` build `setFilter`/`setDelay`/`setReverb` from it.
- The grain density sender multiplies by `engine_param_value("master_density")`.
- The master density sender (`send_master_density_to_engine`) multiplies by each running voice's `engine_param_value("v<i>_grain_density")`.

Voice sync:
- `sync_voice_values_to_engine` sends the voice's stored values. It calls `forget_sent_voice_values(voice_idx)` first, so an LFO re-applies its offset on its next step.
- Its grain density uses the master density as sent.
- It ends with the registered voice params (`send_registered_voice_values`): per `S.registry.voice_params` record, in registration order, each `grain_keys` entry (sorted by key) with the voice's `extras[key]`, then the record's `sync(voice_idx)` (`docs/notes/lua/params.md`).

Adding a param that reaches the engine:
- give it a sender in `S.engine_senders` and call `send_param_to_engine` from its action;
- option and number params the LFOs cannot target (source, grain envelope/mode, mod sources) still call the engine from their action.
