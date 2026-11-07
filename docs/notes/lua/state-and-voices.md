## Must not break

- `include("lib/state")()` builds a fresh `S` on every call, so a script reload keeps nothing from the last run. Never keep a table from an earlier `S`.
- State that more than one module uses is a field of `S` under its plain name. The tests find it by that name (`local_value`), so renaming it breaks them.
- `S.voices` is the only source of values. The engine holds no per-voice defaults.
- Source tests use `voice_uses_synth(i)` / `voice_uses_buffer(i)`. Never `not voice_uses_synth` (that includes input).
- `cleanup()` holds no steps of its own. Every metro, clock, poll and handler is stopped by a step its module registers with `S.register_cleanup` at a free order in `CLEANUP_ORDER`. Two steps never share an order.
- Bounds-check every index (voice, scene, step, slot, grid coordinate) before indexing, so tables never grow by accident.
- Cancel a running clock before starting its replacement.

## Owns

- `strata.lua`: the entry points only.
  - `S`, the includes, `init`, `redraw`, `enc`, `key`, `cleanup`.
  - init's start-up clock (`STARTUP`, `cancel_startup_clock`), kept beside `init`, which starts it.
  - The module rules (constructor shape, `S`, `S.lib` names, includes, registries) are in CLAUDE.md, "Lua modules and `S`". CLAUDE.md's module table lists the files in include order.
- `lib/state.lua`: `S` itself.
  - `S.registry` (`pages`, `params`, `grid_layouts`, `cleanup`), `S.register_cleanup`, `S.lib`.
  - The `__declared` key set the tests use: a key ever assigned into `S`, even to nil, is recorded there.
- `lib/constants.lua`: `S.constants`, a plain table. The constants and fixed tables (`NUM_VOICES`, `UI_PAGES`, `MAIN_PARAMS`, `GRAIN_PARAM_IDS`, `CLEANUP_ORDER`, ...).
- `lib/voices.lua`: `S.lib.voices`, which has no fields.
  - `S.voices`, `S.frozen`, `S.master_density`, `S.selected_voice`.
  - The global source tests `voice_uses_synth`, `voice_uses_buffer`, `voice_source_label`, `voice_buffer_slot`.

## Voice state

Each `S.voices[i]` holds:
- `name`: the voice type.
- `active`: whether it runs.
- `source`: the grain source, a `SOURCE_OPTIONS` index. 1 = synth, 2..`NUM_BUFFERS` + 1 = buffer 1-8, `NUM_BUFFERS` + 2 = input (`SOURCE_SYNTH`, `SOURCE_INPUT`).
- `param_order`: the `params` keys in order (PARAMS menu order and grid fader order; amp/pan last).
- `params`: the synthesis params (per voice type). Their values are also the param defaults.
- `grain`: size, density, pitch, spread, env (grain envelope option index), mode (grain mode option index), buf_pos, buf_rate, buf_scan.
- `crossmod`: `slot1`..`slot3` (`source`, `amp_amt`, `freq_amt`) and `speed`.

The engine mirrors this table:
- param actions forward changes while a voice is active (through `send_param_to_engine`, see `docs/notes/lua/engine-sync.md`);
- `sync_voice_to_engine` pushes everything when a voice starts.

## Start-up

`init` starts voice 1 at once and voice 2 `STARTUP.voice_delay_seconds` (0.5 s) later, from a clock (`clock.sleep` works only inside `clock.run`):

```lua
cancel_startup_clock()
STARTUP.clock = clock.run(function()
  toggle_voice(1)
  clock.sleep(STARTUP.voice_delay_seconds)
  STARTUP.clock = nil
  -- leave voice 2 alone if a MIDI note or grid press started it meanwhile
  if not S.voices[2].active then toggle_voice(2) end
end)
```

## Cleanup

`cleanup()` (`strata.lua`) runs the `S.registry.cleanup` records in ascending `order`.
- Each module registers its steps as it loads: `S.register_cleanup(S.constants.CLEANUP_ORDER.<step>, fn)` (`lib/state.lua`).
- Two steps at one order are refused, so the sort always gives one sequence.
- A step that fails stops the ones after it.

The sequence (`CLEANUP_ORDER` in `lib/constants.lua`):

| Order | Step | Module |
|-------|------|--------|
| 10 | give the clock back the tempo handler found at init, if the script's is still installed (`restore_tempo_change_handler`) | `lib/params_setup.lua` |
| 20 | give the norns menu its own `_menu.set_mode` back (`unwatch_menu_opening`), before anything that can fail | `lib/ui/menu_watch.lua` |
| 30 | save the scenes (skipped, with a message, if scenes.data failed to load and could not be moved aside) | `lib/scenes.lua` |
| 40 | save the buffer paths (skipped the same way for buffers.data) | `lib/buffers.lua` |
| 50 | cancel init's start-up clock (`cancel_startup_clock`, while it waits to start voice 2) | `strata.lua` |
| 60 | stop the frame clock | `lib/ui/frame.lua` |
| 70 | stop the drift metro | `lib/mutation.lua` |
| 80 | stop the mutation metro and set `mutation_enabled` to 0, so param and state agree | `lib/mutation.lua` |
| 90 | stop the pattern clock | `lib/sequencer.lua` |
| 100 | stop the scene sequencer through its param (`scene_sequencer_enabled` 0, then `scene_sequencer_stop`) | `lib/scenes.lua` |
| 110 | cancel a scene transition | `lib/scenes.lua` |
| 120 | stop the LFOs (through their state params, like the library's menu) and give their destinations back their stored values | `lib/lfos.lua` |
| 130 | stop the buffer polls and the recording timers (the engine finishes or frees any recording itself) | `lib/buffers.lua` |
| 140 | cancel the BUFFER page's flash clock | `lib/pages/buffer.lua` |
| 150 | detach the MIDI handler, before the voices go off | `lib/midi_in.lua` |
| 160 | `engine.voiceOff` for every running voice | `lib/engine_sync.lua` |
| 170 | leave every connected grid dark | `lib/grid/core.lua` |
| 180 | leave the arc dark | `lib/arc/core.lua` |

Adding a step:
- A new resource gets its stop in the module that starts it, at a free order at its place in this sequence (the orders are spaced by 10).
- The test "cleanup runs every registered step in today's order" logs each step's observable effect. It fails if a step moves, merges with another or is missing. Add the new step's effect to its `CLEANUP_STEPS` list.

Clocks: cancel the running one before starting its replacement.

```lua
if S.scene_transition_clock then
  clock.cancel(S.scene_transition_clock)
  S.scene_transition_clock = nil
end
S.scene_transition_clock = clock.run(function()
  -- clock body
end)
```

This prevents:
- orphaned clock coroutines;
- concurrent clocks making a parameter oscillate;
- leaks from metros never stopped;
- params that disagree with the state they control.

## Bounds checks

Check before indexing:
- every voice index (1 to `NUM_VOICES`);
- every scene index (1 to `NUM_SCENES`);
- every pattern step (1 to `PATTERN_LENGTH`);
- grid button coordinates;
- parameter ranges.

The scene and pattern examples are in `docs/notes/lua/scenes.md` and `docs/notes/lua/grid-and-sequencer.md`.
