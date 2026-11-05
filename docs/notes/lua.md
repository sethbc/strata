# Lua implementation notes

Detailed reference moved out of CLAUDE.md. Read the section you need; grep for the function name.

## Key Implementation Patterns

### Voice State Management

Each voice has a table structure containing:
- `name` - Voice type identifier
- `active` - Boolean state
- `source` - Grain source, a `SOURCE_OPTIONS` index: 1 = synth, 2..`NUM_BUFFERS` + 1 = buffer 1-8, `NUM_BUFFERS` + 2 = input (`SOURCE_SYNTH`, `SOURCE_INPUT`)
- `param_order` - Ordered list of the `params` keys (PARAMS menu order and grid fader order; amp/pan last)
- `params` - Synthesis parameters (voice-specific); their values are also the param defaults
- `grain` - Granular processing parameters (size, density, pitch, spread, env = grain envelope option index, mode = grain mode option index, buf_pos, buf_rate, buf_scan)
- `crossmod` - `slot1`..`slot3` (`source`, `amp_amt`, `freq_amt`) and `speed`

The `voices` table is the single source of truth. Engine state mirrors this: param actions forward changes (through `send_param_to_engine`, below) while a voice is active, and `sync_voice_to_engine` pushes everything when a voice starts.

### Param -> engine: `send_param_to_engine`

Every control param that reaches the engine (voice synthesis params, grain and buffer params, crossmod amounts and speed, master density, filter, delay, reverb, tape drift; also `filter_type`) has an action of the form `action = function(x) <store x>; send_param_to_engine(id, x) end`, and its engine call lives in `engine_senders[id] = function(value) ... end` (voice params through `add_voice_sender`, which gates the call on `voices[voice_idx].active`). `send_param_to_engine(id, value)` adds the offsets of every global LFO currently on that param (`with_lfo_offsets(id, value)`: value + Σ `lfo_scaled` × half the range, clamped; the value itself when no LFO is on it) and passes the result to `send_engine_value(id, value)`, which records `engine_param_values[id] = value` and runs the sender. So an edit, a mutation, a scene-fade step or the 10 Hz drift on a modulated param never sends the plain value under a running LFO (that mattered for `bufPos`, which has no lag in the engine: stray grains from the stored position). The LFOs drive the engine through `send_engine_value` too, so there is one path from a value to the engine. Action sends always go out (no dedupe).
- Commands that carry several params send the others as the engine has them: `engine_param_value(id)` is the last value sent (or `params:get(id)` before any). `send_filter_to_engine`, `send_delay_to_engine`, `send_reverb_to_engine` build `setFilter`/`setDelay`/`setReverb` from it, the grain density sender multiplies by `engine_param_value("master_density")`, and the master density sender (`send_master_density_to_engine`) by each running voice's `engine_param_value("v<i>_grain_density")`. So an LFO on filter res does not undo one on filter freq
- `sync_voice_values_to_engine` sends the voice's stored values and calls `forget_sent_voice_values(voice_idx)` first (an LFO re-applies its offset on its next step); its grain density uses the master density as sent
- When adding a param that reaches the engine, give it a sender and call `send_param_to_engine` from its action; never call `engine.*` from the action directly. Option and number params that the LFOs cannot target (source, grain envelope/mode, mod sources) still call the engine from their action

### Parameter System

Use norns params for all adjustable values:
1. Define in `init()` with `params:add{}`
2. Include `action` function to update engine
3. Reference params with `params:get("id")` or `params:set("id", value)`
4. Group related params with `params:add_separator()`, or `params:add_group(id, name, n)` for a collapsible section (`strata_fx`, `strata_lfos`, `strata_buffers`, `strata_midi`; the LFO library adds `lfo_group_<n>` itself). Menu order: `strata` (master density, tempo), `strata_mutations`, `strata_scenes`, the fx, lfo destinations, LFO 1-3, buffers and midi groups, then each voice's synthesis, granular and cross-modulation sections. `n` must equal the number of params that follow it exactly: norns groups cannot nest, and the test stub errors on a group opened inside another

### Global LFOs

Three LFOs (`NUM_LFOS`) built on norns' `lib/lfo.lua` (`local LFO = require "lfo"`), stored in `lfos[n]`. Not the per-voice drift (`drift_update`, below).

- **Construction** (`add_lfo_params()`, called from `init` after the FX group): `LFO:add{shape = "sine", min = -1, max = 1, depth = 0, mode = "free", period = LFO_DEFAULT_PERIOD (4), baseline = "center", action = function(scaled, raw) apply_lfo(n, scaled, raw) end}`, then `lfos[n]:add_params(tostring(n), nil, "LFO " .. n)`. The library owns the params `lfo_<n>` (state, option off/on), `lfo_shape_<n>`, `lfo_depth_<n>` (a **number 0-100, percent**), `lfo_phase_<n>`, `lfo_offset_<n>`, `lfo_mode_<n>` (clocked/free), `lfo_clocked_<n>` (rate option), `lfo_free_<n>` (0.1-300 s), `lfo_reset_<n>`, ... (`lfo_*` ids are reserved for it). The library starts an LFO from its state param's action (it is off by default, so `init` starts nothing) and hides the other params while it is off
- **PARAMS layout**: norns groups cannot nest and the library adds its own group per LFO (`lfo_group_<n>`, "LFO n", 15 params), so Strata's destinations get their own group first: `strata_lfos` ("lfo destinations", `NUM_LFOS` params `strata_lfo<n>_dest`). Never pass a separator to `add_params` or wrap the library's params in a Strata group: the library sizes its group itself
- **Destinations**: `LFO_DESTINATIONS` is the ordered `strata_lfo<n>_dest` option list of `{label, resolve}`: `none`, `density`, `drift`, `filt freq`, `filt res`, `filt mix`, `dly time`, `dly fdbk`, `dly mix`, `rev mix`, `rev size`, `rev damp`, then per voice `v<i> main` (`main_param_id(i)`, resolved on every step so it follows the voice's source), `v<i> size`, `dens`, `pitch`, `spread`, `pos`, `rate`, `scan` (`VOICE_LFO_DESTINATIONS`). 12 + 8 per voice = 68 entries; every resolved id is a control param. `lfo_destination_id(n)` returns the resolved id or nil. Labels must fit the LFO page's right column (49 px)
- **Modulate around the stored value, never write it**: with min -1, max 1 and a centre baseline the library hands the action `scaled` in -depth..depth (depth = percent / 100; the library's `lfo_offset_<n>` param adds to it). The user can change `lfo_min_<n>`, `lfo_max_<n>` and `lfo_baseline_<n>` in PARAMS: a `min` baseline gives `scaled` in -1..-1 + 2 × depth (below the stored value up to 50 % depth), `max` in 1 - depth..1 (the library's `scaled_min = max * (1 - depth)`: above it, half as wide), and other min/max scale the swing; the README tells users to keep the defaults. `apply_lfo(n, scaled, raw)` stores `lfo_last_raw[n] = raw`, resolves the destination, records `lfo_last_dest[n]`/`lfo_scaled[n] = scaled` and sends `with_lfo_offsets(id, params:get(id))` through `send_engine_value`: clamp(stored + (sum of `lfo_scaled` of every LFO whose `lfo_last_dest` is id) × 0.5 × (maxval - minval)) over `param_range(id)`. LFOs on one destination add up. `params:set` is never called for a destination. `lfo_last_dest`/`lfo_scaled` are declared with `send_param_to_engine` (above the LFO block) because param actions read them
- **Send dedupe**: `apply_lfo` skips the send when the new value differs from `engine_param_values[id]` (the last value sent to that destination by any path) by less than `LFO_SEND_THRESHOLD` (1/1000) of the destination's range, so a slow LFO sends only when it has moved. Restores and param-action sends are never skipped
- **Restore rules** (`restore_lfo_destination(n)`: clear `lfo_last_dest[n]`/`lfo_scaled[n]` and `send_param_to_engine(old id, params:get(old id))`, i.e. the stored value plus any other LFO's offset on it; always sent). The library stops calling the action when an LFO is off or its depth is 0, so Strata restores explicitly: from the `strata_lfo<n>_dest` action (destination changed), and from wrappers installed with `wrap_param_action(id, before, after)` around the library's `lfo_<n>` action (state off) and `lfo_depth_<n>` action (depth 0). When a `main` destination re-resolves to a different param (voice source changed), `apply_lfo` restores the old id once, then modulates the new one
- **Dot phase estimate**: the library's running phase is internal (`get("phase")` is the phase offset setting). `lfo_phase_estimate(n)` = (`lfo_phase_base[n]` + (`util.time()` - `lfo_phase_time[n]`) / period in seconds (clocked periods are beats × `clock.get_beat_sec()`) + phase offset) % 1. `note_lfo_reset(n)` sets the base to `LFO_RESET_PHASES[reset_target]` (floor 0.75, ceiling 0.25, mid: falling 0.5, mid: rising 0, as `LFO:reset_phase`) when the state turns on or `lfo_reset_<n>` fires; wrappers on `lfo_mode_<n>`, `lfo_clocked_<n>` and `lfo_free_<n>` call `rebase_lfo_phase(n)` before the library changes the period, which keeps the phase like the library's `change_period`. Tempo changes are not tracked (the estimate drifts until the next reset)
- **Rate ceiling and message rate**: the library's ceiling - free periods down to 0.1 s (10 Hz), clocked rates down to "1/16" (a period of 1/4 beat; clocked periods are the rate × 4 beats). The library calls the action on every step while depth > 0, so each LFO is set to `LFO_PPQN` (48) steps per beat with `lfos[n]:set("ppqn", LFO_PPQN)` right after `LFO:add` (the library's default is 96; `set("ppqn")` before `start` is what the sprocket is built from, and its phase counter advances 1/ppqn per step, so phase maths are unchanged): at most 96 sends/s per LFO at 120 BPM, 240 at 300 BPM (one engine message, one per running voice for master density), fewer with the dedupe
- **Scenes**: `SCENE_GLOBAL_PARAMS` holds per LFO `lfo_shape_<n>`, `lfo_mode_<n>`, `lfo_clocked_<n>` (default 13, the library's index for a period of 4), `lfo_free_<n>` and `lfo_depth_<n>` (continuous), `strata_lfo<n>_dest`, then `lfo_<n>` last so an LFO starts with its settings in place; scenes without them migrate to the defaults (LFOs off)
- **Cleanup**: `stop_lfo_page_clock()`, then per LFO `lfos[n]:stop()`, `params:set("lfo_<n>", 1)` and `restore_lfo_destination(n)`
- The grid has no LFO controls

### MIDI Input

MIDI notes, velocity and pitchbend play the voices (spec §5). CC is not handled in Strata's code: norns' PARAMS > MAP maps any CC to any param.

- **State** (grouped in tables: the main chunk is near the 200-local limit): `MIDI` holds the constants (`max_port` 4, `velocity_max` 127, `rate_root_note` 60, `bend_center` 8192, `bend_semitones` 2, the option lists), `midi_device` is the vport Strata listens to, and `midi_state` holds `bend[voice]` (ratio, default 1), `held[voice]` (set of held notes) and `note_voice[channel][note]` (the voice a note's note on played). `local musicutil = require "musicutil"`
- **Params** (group `strata_midi`, 3 params): `midi_device` number 1..`MIDI.max_port` default 1 (action `attach_midi(x)` then `reset_midi_input()`), `midi_channel_mode` option {`per voice`, `omni to selected`} default 1 (action `reset_midi_input()`), `midi_note_off` option {`ignore`, `voice off`} default 1
- **Device lifecycle**: `midi_init()` (from `init`, after `grid_init`) calls `attach_midi(params:get("midi_device"))`, which clears the old vport's `event` and sets `midi_device = midi.connect(port); midi_device.event = midi_event`. The handler lives on the vport only (norns fires both `device.event` and `vports[port].event`, as for grids and arc). `midi.add(device)` re-attaches, requests a redraw (SETUP) and prints; `midi.remove(device)` resets the input if the device was on the selected port, requests a redraw and prints. norns clears the vport as `midi.remove` returns (`Midi.update_devices`), before the next frame draws, so `midi_device_name()` (the selected vport's name, or `none` without a device) then shows the port as empty. `cleanup` clears `midi_device.event`
- **Routing**: `midi_target_voice(channel)`: per voice, channel 1..`NUM_VOICES` addresses that voice and other channels nothing; omni, every channel addresses `selected_voice`. `midi_event(data)` parses with `midi.to_msg` and ignores everything but notes and pitchbend
- **Note on** (velocity > 0): records the note in `held` and `note_voice`, then `midi_note_on(voice, note, vel)`: a synth source sets `v<i>_freq` to `musicutil.note_num_to_freq(note)` clamped to `param_range`, a buffer source `v<i>_buf_rate` to `2 ^ ((note - 60) / 12)` clamped (0.25-4), an input source takes no pitch (all through `params:set`); then `toggle_voice(i)` if the voice is off, and `engine.retrigger(i - 1, vel / 127)`. Voices keep their slow attacks; velocity lands on the accent. The `freq` controlspec has step 0 so notes keep exact equal-tempered pitch (a 1 Hz step was 37 cents at 46 Hz)
- **Note off** (or note on with velocity 0): the note goes to the voice its note on played (`note_voice`; in omni mode the selection may have moved), or to `midi_target_voice` for a note never seen, and is removed from `held`. `midi_note_off_for(voice)`: in `voice off` mode, an active voice with no other held note is stopped with `toggle_voice`. A note during the release starts it again through `toggle_voice`/`voiceOn`, and the engine re-gates the releasing synths
- **Pitchbend**: `midi_pitchbend(voice, value)`: `ratio = 2 ^ (((value - 8192) / 8192) * 2 / 12)`, stored in `midi_state.bend[voice]` and sent with `setVoiceParam(i - 1, "bend", ratio)` if the voice is active (a stopped voice gets it when it starts). `reset_midi_input()` (port or channel mode change, device removed) clears `held`/`note_voice` and re-centres every bent voice (sends `bend` 1 only for voices whose bend was not 1). `midi_set_bend(voice, ratio)` stores and (for an active voice) sends a bend. Omni bend follows the selection: `select_voice_by` (E2 on MAIN and BUFFER, the only place `selected_voice` changes) calls `midi_bend_follow_selection(previous_voice)` when the selection moved, which in `omni to selected` mode with the previous voice bent (`bend ~= 1`, the wheel off centre) re-centres it (`bend` 1) and gives the new selection the wheel's ratio (a stopped voice gets it on start). Per voice mode leaves bends alone

### Probability-Based Mutation System

Strata includes a mutation system that applies gentle, probabilistic changes to voice parameters over time, creating organic evolution:

#### Architecture
- **Mutation Metro**: `mutation_metro` - Timer that periodically calls `gentle_mutate()`
- **Mutation Function**: `gentle_mutate()` - Applies probability-based parameter changes
- **Global Parameters**: Controlled via PARAMS menu:
  - `mutation_enabled` (0/1) - Toggle mutation system on/off
  - `mutation_rate` (0.5-10s) - How often mutations are checked
  - `mutation_probability` (0-1) - Chance each parameter will mutate per check
  - `mutation_amount` (0-1) - Size of mutation delta relative to parameter range
- **Normalized space**: synth and buffer params mutate by a delta in the controlspec's normalized 0-1 range (`mutated_value(spec, current, delta)`: unmap, add, clamp, map), and `randomize_voice` draws synth params with `spec:map(math.random())`. Exponential params (freq, cutoff, buf_rate) therefore move evenly in octaves. Grain size, pitch and spread are linear, so their absolute deltas and ranges are unchanged. The Lua drifts (grain pitch, buffer position) act on linear params; the engine's tape drift is separate

#### Implementation Details

**Mutation Function** (`gentle_mutate()` in strata.lua):
```lua
function gentle_mutate()
  local probability = params:get("mutation_probability")
  local amount = params:get("mutation_amount")

  for i = 1, #voices do
    if voices[i].active and not frozen[i] then
      -- Check each synthesis parameter
      for key, current_val in pairs(v.params) do
        if key ~= "amp" and key ~= "pan" then
          if math.random() < probability then
            -- Gaussian-like delta as a fraction of the normalized 0-1 range
            local delta = ((math.random() + math.random()) / 2 - 0.5) * 2 * amount
            params:set("v" .. i .. "_" .. key, mutated_value(spec, current_val, delta))
          end
        end
      end

      -- Granular parameters mutate at lower probabilities
      -- grain_size: 0.5× probability
      -- grain_pitch: 0.3× probability
      -- grain_spread: 0.2× probability
    end
  end
end
```

**Key Design Decisions**:
- **Excluded Parameters**: `amp` and `pan` are never mutated to preserve voice balance and stereo placement; neither are the grain envelope shape and grain mode (`DISCRETE_GRAIN_KEYS`) nor the voice's `source`. Every grain key `gentle_mutate` changes (the buffer keys and its size/pitch/spread list) is guarded by `not DISCRETE_GRAIN_KEYS[key]` (checked before the `math.random()` draw, so the random sequence is unchanged); `DISCRETE_GRAIN_KEYS` is declared above `gentle_mutate` for that
- **Buffer and input sources**: a buffer-sourced voice mutates `BUFFER_MUTATION_KEYS` (`buf_pos`, `buf_rate`, `buf_scan`, each with `probability`, delta = gaussian × `amount` in the controlspec's normalized range, so the exp `buf_rate` moves evenly) instead of its synthesis params; an input-sourced voice mutates neither synthesis nor buffer params; grain size/pitch/spread mutate as for every voice
- **Frozen Voice Exemption**: Frozen voices are excluded from mutations
- **Gaussian Distribution**: Averaging two random values creates a bell curve distribution, favoring smaller changes
- **Relative Deltas**: Mutation amount is a fraction of the controlspec's normalized range, ensuring consistent behavior across different specs
- **Granular Hierarchy**: Grain parameters mutate less frequently than synthesis parameters

#### Usage Patterns

**Starting Mutations**:
```lua
params:set("mutation_enabled", 1)  -- Enable via params
params:set("mutation_probability", 0.15)  -- 15% chance per parameter
params:set("mutation_amount", 0.25)  -- 25% of parameter range
params:set("mutation_rate", 2)  -- Check every 2 seconds
```

**Recommended Settings**:
- **Subtle Evolution**: probability=0.1, amount=0.15, rate=3s
- **Moderate Change**: probability=0.15, amount=0.25, rate=2s (default)
- **Dramatic Shift**: probability=0.25, amount=0.4, rate=1s

**Integration with Existing Systems**:
- **Drift**: Mutations work alongside `drift_update()` (the per-voice drift; not the global LFOs), which gives each active, unfrozen voice a subtle mean-reverting grain pitch drift: `mean_reverting_step(current, base, DRIFT_PITCH_STEP, DRIFT_PITCH_REVERSION)` = `current + ((math.random() - 0.5) * step - (current - base) * reversion)` (step 0.004, reversion 0.01 per 100 ms tick; one `math.random()` per call). `base` (`grain_pitch_base[i]`) is the last grain pitch set by anything other than the drift (user, mutation, scene), tracked in the param action via the `drift_writing` flag, which the drift sets around each write in `set_drifted_param` (an `xpcall` with `with_traceback`, so an error in the param action clears the flag and is raised again with its traceback). The `grain_pitch` controlspec has step 0 so these small steps are not quantized away. Buffer-sourced voices also drift `buf_pos` with the same helper (`DRIFT_BUF_POS_STEP` 0.002, `DRIFT_BUF_POS_REVERSION` 0.01, centre `buf_pos_base[i]`, `buf_pos` step 0)
- **Freeze Feature**: Frozen voices are stable - neither the drift nor mutations affect them (buffer params included; `randomize_voice` also returns for a frozen voice)
- **Cross-Modulation**: Mutations never touch the crossmod sources or amounts; the routing a voice has (set by hand or by a scene) keeps modulating the mutated params
- **UI Feedback**: `[M]` indicator appears in the header (x=98) when enabled

#### Lifecycle Management
- **Initialization**: Metro created in `init()` but not started automatically
- **Control**: `mutation_enabled` param action starts/stops the metro
- **Cleanup**: `mutation_metro:stop()` called in `cleanup()` to prevent orphaned timers

### Scene System for Longer-Form Automation

Strata includes a comprehensive scene system for creating longer-form compositions and automations. Scenes capture complete snapshots of the instrument state and can be recalled manually or sequenced automatically.

#### Architecture
- **Scene Storage**: `scenes` table - 8 scene slots (numbered 1-8)
- **Scene Data**: Complete instrument state including:
  - All voice parameters (synthesis, granular including the buffer params, cross-modulation) and each voice's source (not buffer contents)
  - Voice active states and freeze states
  - Pattern data (all 7 voices × 16 steps)
  - Global parameters (master density, tempo, filter, delay, reverb, drift, mutations, and each LFO's shape, mode, rate, depth, destination and state)
- **Scene Sequencer**: Automatic scene progression with configurable timing
- **Transition Modes**: Instant recall or smooth crossfade between scenes

#### Core Functions

**Scene Capture** (`capture_scene()` in strata.lua):
```lua
function capture_scene(scene_num)
  -- Captures complete current state:
  -- - All voice parameters (params, grain, crossmod)
  -- - Voice active/frozen states
  -- - All pattern data
  -- - Global parameters (density, tempo, reverb, mutations, etc.)
  scenes[scene_num].data = scene_data
  scenes[scene_num].populated = true
end
```

**Scene Recall** (`recall_scene()` in strata.lua):
```lua
function recall_scene(scene_num, transition_time)
  -- Validates the slot (validate_scene) and cancels any running transition
  -- Instant recall (transition_time = 0) -> recall_scene_instant()
  -- OR smooth transition (transition_time > 0)
  --   - start values snapshotted once by scene_transition_targets()
  --   - SCENE_TRANSITION.steps (20) steps of util.linlin(0, 1, start, target, step / steps)
  --   - only continuous params fade; the rest switch at the end
end
```

**Scene Sequencer** (`scene_sequencer_start()` in strata.lua):
```lua
function scene_sequencer_start()
  scene_sequencer_clock = clock.run(function()
    clock.sleep(0)  -- start on the next scheduler tick (after a PSET read)
    while scene_sequencer_enabled do
      recall_scene(scene_sequencer_position, transition_time)
      local held = math.max(scene_duration, transition_time)
      clock.sleep(held)
      wait_for_scene_transition()
      -- wrap with the length as it is now
      scene_sequencer_position = scene_sequencer_position + 1
      if scene_sequencer_position > params:get("scene_sequence_length") then scene_sequencer_position = 1 end
    end
  end)
end
```

The sequencer never cancels a transition: everything that does not fade (voice on/off, sources, patterns, freeze, discrete grain params, mod sources, tempo, filter type, mutation and LFO settings) is applied only by the `recall_scene_instant` at the end of the fade, and the next recall cancels a running fade first. So a scene lasts `max(scene_duration, transition_time)`, and then the sequencer waits, checking every `SCENE_TRANSITION.settle_seconds` (0.01 s), until `scene_transition_active` clears: the fade's 20 sleeps add up scheduling delay, so with equal times the sequencer would otherwise wake first. It also waits for a transition started by a manual recall. A manual recall still cancels a running transition (the sequencer's or its own). An empty scene is skipped after `scene_duration` alone (no transition starts).

The wait (`wait_for_scene_transition`) is bounded, so a transition whose clock is gone cannot stop the sequencer: a transition whose next step (or end) is `SCENE_TRANSITION.overrun_seconds` (1 s) late is cancelled (`cancel_scene_transition`, with a console message) and the sequencer moves on. The bound follows the fade's progress, not its start: the transition clock records in `SCENE_TRANSITION.next_step_due` the `util.time()` at which its next step or its end is due (set when the transition starts and before each step's sleep, nil when no transition runs), so a healthy fade whose 21 wake-ups each run late under load (60 ms each puts a 16 s fade's end 1.3 s past its transition time) is never cut short, and one that stalls is caught `overrun_seconds` after its next step was due. It applies the same way to a transition the sequencer did not start (a manual recall's) or one left running because the sequencer's own recall failed validation. The transition clock clears `scene_transition_active` and `scene_transition_clock` on every exit: at its end (before `recall_scene_instant`, which it passes the scene data it read when the fade started: `capture_scene` stores a new table, so capturing into the slot during the fade does not change the fade's end), when cancelled, and when a param action raises an error during a fade step (each step runs in an `xpcall` with the global handler `with_traceback`, outside the `clock.sleep`, and the error is raised again with its traceback, so maiden shows where the param action failed; `with_traceback` adds a traceback only when the message has none yet).

An error in the sequencer's own recall (an instant recall, or the first fade step, which runs inside the sequencer's clock) is caught there with `xpcall`, printed with its traceback (`scene sequencer: scene <n> failed: ...`), and the sequencer keeps going: the recall has already cleared `scene_transition_active`, `scene_transition_clock` and `scene_recall_in_progress`, so continuing is safe, and the next scene may recall fine (stopping would end a long ambient run over one bad action). A failing scene still holds for its duration, so a repeating error prints at most once per scene. Errors in later fade steps are raised in the transition's clock, not the sequencer's.

The sequencer advances with the `scene_sequence_length` it reads after the wait, so a sequence shortened while a scene plays wraps to scene 1 (it never jumps to the new last scene). Its clock does nothing until the next scheduler tick (`clock.sleep(0)`): norns' `params:read` (a PSET load from the PARAMS menu) sets params one by one in file order, and `scene_sequencer_enabled` comes before the transition time, duration, length, FX, LFO and voice params. Started inside the read, the sequencer would recall scene 1 with the old transition time and the PSET's later lines would then overwrite it; on the next tick the read has finished. `scene_sequencer_start` and `pattern_clock_start` cancel their running clock before starting a new one (tests check that a restart leaves one clock).

#### Parameters

Controlled via PARAMS menu (strata_scenes section):
- `scene_sequencer_enabled` (binary) - Start/stop automatic scene progression
- `scene_transition_time` (0-30s, default 2s) - Crossfade duration for smooth transitions
- `scene_duration` (4-120s, default 16s) - How long each scene plays before advancing
- `scene_sequence_length` (1-8, default 4) - How many scenes to cycle through

#### Grid Integration

Scene controls on **Page 3** (16×16 grid):
- **Row 1**: Scene recall (instant) - Press to immediately load scene 1-8
- **Row 2**: Scene recall (with transition) - Press to crossfade into scene 1-8
- **Row 3**: Scene save - Press to capture current state to scene 1-8
- **Row 5, Column 1**: Toggle scene sequencer on/off
- **Row 5, Columns 3-10**: Set sequence length (1-8 scenes)

**LED Feedback**:
- Populated scenes: brightness 8 (row 1) or 6 (row 2)
- Current scene: brightness 15 (highlighted in row 1)
- Empty scenes: brightness 2
- Active sequencer: brightness 15, shows next scene position
- Sequence length indicators: brightness 8 for included scenes, 2 for excluded

#### UI Feedback

**Screen Display**:
- `S1` through `S8` indicator at top-right shows current scene number
- Brightness level 10 when sequencer is active, 6 when static
- Mutation indicator abbreviated to `[M]` to make room for scene indicator

#### Implementation Details

**State Capture**:
- Deep copy of all parameter values (not references)
- Preserves both the `voices` table state and norns param values
- Patterns are copied step-by-step to avoid reference issues

**Smooth Transitions**:
- `scene_transition_targets(scene_data)` snapshots `{id, start, target, step}` for every continuous param *once*, before the fade: voice params, grain params, crossmod amp/freq amounts, mod speed, and the continuous globals in `SCENE_GLOBAL_PARAMS` (master density, filter freq/res/mix, delay time/feedback/mix, reverb, drift)
- 20 interpolation steps regardless of transition time; step k sets `util.linlin(0, 1, start, target, k / 20)`, so the fade is linear over the whole transition time (never re-read the current value inside the loop: that makes the fade front-loaded). A number param (`step` 1: the LFO depths `lfo_depth_<n>`, which do not round themselves) is rounded to whole numbers during the fade, so arc and E3 depth steps land on whole percents again; the end applies the scene's exact value
- Mod sources, grain envelope shapes and grain modes (`DISCRETE_GRAIN_KEYS`), freeze and active states, tempo, filter type and mutation settings are not interpolated; they switch at the end via `recall_scene_instant()`, which also lands every param exactly on its target
- Any recall calls `cancel_scene_transition()` first, which cancels the clock and clears `scene_transition_active`
- A successful `load_scenes_from_disk()` cancels a running transition before it replaces the scenes: the fade's end would otherwise apply the file's data for that slot, or fail on a slot that is now empty. The fade stops where it is

**Voice Activation Handling**:
- Checks if voice state needs to change (on→off or off→on)
- Uses existing `toggle_voice()` function to properly start/stop voices
- Preserves freeze states across scene transitions

**Source changes and the full sync**: `recall_scene_instant` sets `scene_recall_in_progress` while it sets params (the body runs in an `xpcall` with `with_traceback`; the flag is always cleared, the end-of-recall syncs run, for whatever was applied before the error, and only then is an error raised again with `error(recall_error, 0)`, so the engine never lags the Lua state), so the `v<i>_source` action sends `setGrainSource` but not its `sync_voice_values_to_engine` (which would send the old values to the new grain synth before the recalled ones). After every param is set and the flag is cleared, each voice that is running and whose source changed gets one `sync_voice_values_to_engine`; a voice the recall starts is synced by `toggle_voice` instead. A voice the recall stops is stopped (`toggle_voice`) before its source and params are set, so its release tail keeps the outgoing scene's values (param actions reach the engine only while a voice is active), and a voice it starts is started after its params: the engine only records a stopped voice's source, so a recall never builds a grain synth for the new source only to release it at once (#46; scenes on/synth, off/input, on/buffer recalled in quick succession used to leave the engine more synths than its real-time memory bound, see Real-time memory in `docs/notes/engine.md`). So a recall sends at most one full sync per voice, after its params, and both an instant recall and a smooth transition (which ends in `recall_scene_instant`) leave the engine with the Lua state of every running voice

**Pattern Preservation**:
- Patterns are restored after all parameter changes
- Ensures `grid_redraw()` is called to update grid display
- Pattern sequencer continues playing if it was active

#### Usage Patterns

**Manual Scene Performance**:
```lua
-- From grid page 3:
-- 1. Build your sound
-- 2. Press row 3 button to save to scene slot
-- 3. Modify parameters
-- 4. Save to another slot
-- 5. Press row 1 buttons to instantly switch between scenes
-- 6. Press row 2 buttons to smoothly transition between scenes
```

**Automatic Scene Sequencing**:
```lua
-- Setup:
params:set("scene_transition_time", 3)  -- 3 second crossfades
params:set("scene_duration", 20)  -- 20 seconds per scene
params:set("scene_sequence_length", 4)  -- Cycle through scenes 1-4
params:set("scene_sequencer_enabled", 1)  -- Start sequencer

-- Result: Scenes 1→2→3→4→1... with 3s crossfades, 20s each
```

**Composition Workflow**:
1. Create 4-8 distinct scenes with different voice combinations and parameters
2. Set appropriate transition time (0s for rhythmic changes, 5-10s for ambient evolution)
3. Set scene duration based on desired pacing
4. Enable sequencer for hands-free long-form composition
5. Mutations can still evolve non-frozen voices during scenes

#### Integration with Other Systems

- **Freeze Feature**: Frozen voices are captured and restored per-scene
- **Mutations**: Mutation settings are per-scene; sequencer can alternate between static and evolving scenes
- **Pattern Sequencer**: Pattern data is saved per-scene; can switch between different rhythmic patterns
- **Cross-Modulation**: Modulation routing is per-scene; enables complex evolving relationships
- **Drift**: Continues to operate during scenes unless voices are frozen; the global LFOs keep running with the LFO settings the scene recalled

#### Lifecycle Management
- **Initialization**: Scenes array initialized in global scope, empty by default
- **Scene Sequencer Control**: Started/stopped via param action
- **Cleanup**: `scene_sequencer_stop()` called in `cleanup()` to prevent orphaned clocks
- **Transition State**: `scene_transition_clock` / `scene_transition_active` track the running transition; `cancel_scene_transition()` clears both

#### Disk Persistence
- **Storage Location**: `~/dust/data/strata/scenes.data`
- **File Format**: Lua table serialization using norns `tab` library: `{version = SCENE_DATA_VERSION, scenes = {...}}` (version 2). Version 1 files (`{version = 1, ...}`, or the bare scenes array written before 2.1) are migrated on load and print `migrated scenes file from version 1`; the next save writes version 2. Any other version is rejected
- **Migration**: `load_scenes_from_disk()` runs `migrate_scene(scene, from_version)` on every loaded slot before `validate_scene_data()`. It fills only what is missing, so it runs for every version: each global from its `SCENE_GLOBAL_PARAMS` entry's `default` (the param default), top-level blocks from `SCENE_BLOCK_DEFAULTS` (`{key, default}`), and per-voice fields from `VOICE_SCENE_DEFAULTS` (`{path = keys inside data.voices[i], default}`; filled only when the parent table exists). Malformed scenes are left for validation to reject. When a later feature adds a scene field, add its default to one of these tables (`VOICE_SCENE_DEFAULTS` holds the grain envelope and mode, `source` and the three buffer params; `SCENE_BLOCK_DEFAULTS` is empty: the LFO settings are globals in `SCENE_GLOBAL_PARAMS`)
- **Robust Loading**: `tab.load` runs the file as Lua unprotected, so `load_scenes_from_disk()` calls it through `pcall`. On any failure (error, unknown version, invalid data after migration) it prints a message, keeps the current scenes (empty at startup) and preserves the file: it is renamed to `scenes.data.bak` so the save in `cleanup()` cannot destroy it, and if the rename fails `scene_autosave_blocked` makes `cleanup()` skip the auto-save. Missing slots in a valid file are filled with empty scenes
- **Auto-save**: Scenes automatically saved to disk in `cleanup()` when script exits
- **Auto-load**: Scenes automatically loaded from disk in `init()` on script startup
- **Manual Controls**: PARAMS menu includes "save scenes to disk" and "load scenes from disk" trigger actions
- **What's Saved**: Complete scenes table including all 8 scene slots, populated state, and scene data
- **Persistence**: Scenes persist across norns reboots, allowing you to build a library of sonic palettes
- **Buffers** (`~/dust/data/strata/buffers.data`, `buffer_data_file`): `save_buffers_to_disk()` writes `{version = BUFFER_DATA_VERSION, paths = {[n] = buffers[n].path or buffers[n].missing_path or ""}}` (the loaded file or scratch take per slot, or a remembered file that was missing on start; paths only, never audio). `cleanup()` calls it after the scenes save; `init()` calls `load_buffers_from_disk()` after `load_scenes_from_disk()`. It resets `buffers_restored` and `buffer_autosave_blocked` first, then `load_buffer`s each non-empty path that `util.file_exists` and marks the slot `restoring`; `buffers_restored` counts only the slots the poll then confirms holding audio (see the buffers table). A path that exists but that the engine cannot load (unreadable, unsupported, empty or damaged) is reported by `bufferLoadFailed`, so the slot goes back to empty and the path is not saved again. A path that does not exist (deleted, or on an unmounted drive) is not loaded: the slot stays empty, the console names it, and it is kept in `missing_path`, so the next save writes it again and the sample comes back once the file is there (a clear, load or new recording in the slot forgets it). SETUP shows `buffers: k restored`, or `buffers: k ok, m missing` (m = slots with a `missing_path`; "restored" would not fit beside the missing count). Loading mirrors scenes: `tab.load` through `pcall`; on an error, a non-table, another version or no `paths` table the file is moved to `buffers.data.bak` (shared helper `move_aside_unloadable_file(data_file, label)`), and if that fails `buffer_autosave_blocked` makes `cleanup()` skip the save, so a bad file is never silently overwritten. Disk writes of audio happen only when a take completes (the engine's scratch file) or on an explicit `buf<n>_save`

#### Scene Data Validation (v2.0+)

**IMPORTANT**: Always validate scene data before using it to prevent crashes from corrupted files.

`validate_scene(scene)` checks one slot and `validate_scene_data(scene_table)` checks every present slot of a loaded table (missing slots are allowed and filled on load). A populated scene must contain everything `recall_scene_instant()` reads:
```lua
-- every SCENE_GLOBAL_PARAMS id is a number (master_density, tempo, mutation_*, filter_*, delay_*, reverb_*,
--   drift_amount, and per LFO lfo_shape/mode/clocked/free/depth_<n>, strata_lfo<n>_dest, lfo_<n>);
--   an option param's value is an integer from 1 to its option count
-- data.voices: NUM_VOICES tables, each with
--   active (boolean), source (integer 1..#SOURCE_OPTIONS), params (only known keys, numbers),
--   grain (only GRAIN_PARAM_IDS keys, numbers; env/mode integers 1..option count),
--   crossmod.slot1..3 {source = integer 0..NUM_VOICES, amp_amt, freq_amt numbers}, crossmod.speed number
-- data.frozen: NUM_VOICES booleans
-- data.patterns: NUM_VOICES x PATTERN_LENGTH integers 0..15
```
When adding a field to `capture_scene()`, add it to `validate_scene()` (and to `SCENE_GLOBAL_PARAMS`, with its `default`, for a global param), or recall will not restore it, and give it a migration default (`SCENE_GLOBAL_PARAMS.default`, `VOICE_SCENE_DEFAULTS` or `SCENE_BLOCK_DEFAULTS`) so older files still load.

**When to validate**:
- Always before loading scenes from disk (`load_scenes_from_disk`)
- Before recalling scenes (`recall_scene` calls `validate_scene`)
- After receiving scene data from external sources

**Error handling patterns**:
```lua
-- Graceful degradation with console messages
if not scene_data or not scene_data.voices then
  print("error: scene " .. scene_num .. " has invalid data")
  return
end

-- Nil-safe iteration
if scene_data.voices[i] and scene_data.voices[i].params then
  for key, target_val in pairs(scene_data.voices[i].params) do
    -- Safe to access
  end
end
```

### Bounds Checking and Safety (v2.0+)

**CRITICAL**: Always validate array indices before accessing to prevent expansion or crashes.

**Pattern bounds checking**:
```lua
function toggle_pattern_step(voice_idx, step)
  -- Bounds checking to prevent array expansion
  if voice_idx < 1 or voice_idx > NUM_VOICES then return end
  if step < 1 or step > PATTERN_LENGTH then return end

  -- Safe to access
  patterns[voice_idx][step] = ...
end
```

**Scene bounds checking**:
```lua
function recall_scene(scene_num, transition_time)
  if scene_num < 1 or scene_num > NUM_SCENES then return end
  if not scenes[scene_num].populated then
    print("scene " .. scene_num .. " is empty")
    return
  end
  -- Safe to proceed
end
```

**Apply bounds checking to**:
- All voice index access (1 to NUM_VOICES)
- All scene index access (1 to NUM_SCENES)
- All pattern step access (1 to PATTERN_LENGTH)
- Grid button coordinates
- Parameter ranges

### Resource Management and Cleanup (v2.0+)

**IMPORTANT**: Always clean up metros, clocks, and other resources to prevent leaks.

The `cleanup()` function demonstrates proper cleanup:
```lua
function cleanup()
  -- Give the clock back the tempo handler found at init, if the script's is still installed
  restore_tempo_change_handler()

  -- Give the norns menu its own _menu.set_mode back (watch_menu_opening wrapped it)
  unwatch_menu_opening()

  -- Save state before cleanup (each skipped if its file failed to load and could not be moved aside)
  save_scenes_to_disk()
  save_buffers_to_disk()

  -- Cancel init's start-up clock (STARTUP.clock, while it waits to start voice 2),
  -- stop the frame clock, then metros with nil checks
  cancel_startup_clock()
  stop_frame_clock()
  if drift_metro then drift_metro:stop() end

  -- Sync parameter state with actual state
  if mutation_metro then
    mutation_metro:stop()
    params:set("mutation_enabled", 0)  -- Keep param in sync
  end

  -- Stop pattern and scene clocks (scene sequencer via its param, like mutations)
  pattern_clock_stop()
  params:set("scene_sequencer_enabled", 0)
  scene_sequencer_stop()

  -- Cancel transition clocks to prevent orphaned coroutines
  cancel_scene_transition()

  -- Cancel the BUFFER page's flash clock; stop the LFOs and give their destinations back their stored values
  cancel_buffer_page_flash_clock()
  for n = 1, NUM_LFOS do
    lfos[n]:stop()
    params:set("lfo_" .. n, 1)
    restore_lfo_destination(n)
  end

  -- Stop the buffer polls and recording timers (the engine finishes or frees any recording)
  if buffer_polls.state then buffer_polls.state:stop() end
  if buffer_polls.load_failed then buffer_polls.load_failed:stop() end
  for slot = 1, NUM_BUFFERS do cancel_buffer_recording_timer(slot) end

  -- Stop listening to MIDI before the voices go off
  if midi_device then midi_device.event = nil end

  -- Turn off all voices
  for i = 1, NUM_VOICES do
    if voices[i].active then
      engine.voiceOff(i - 1)
    end
  end

  -- Leave connected grids and arc dark
  for _, grid_port in pairs(grids) do grid_port:all(0); grid_port:refresh() end
  if arc_device then arc_device:all(0); arc_device:refresh() end
end
```

**Clock management patterns**:
```lua
-- Before starting a clock, cancel existing one
if scene_transition_clock then
  clock.cancel(scene_transition_clock)
  scene_transition_clock = nil
end

-- Then start new clock
scene_transition_clock = clock.run(function()
  -- Clock body
end)
```

**Prevents**:
- Orphaned clock coroutines
- Concurrent clocks causing parameter oscillation
- Memory leaks from uncancelled metros
- State inconsistencies between params and actual state

### Async Initialization

Voice activation uses `clock.run()` for delayed starts:
```lua
clock.run(function()
  toggle_voice(1)
  clock.sleep(0.5)
  toggle_voice(2)
end)
```

### Grid Integration (Optional)

Strata supports monome grid controllers for pattern sequencing and parameter manipulation. The implementation handles multiple grid sizes and multiple simultaneous grids.

#### Device Lifecycle
- `grid_init()` - Connect to up to 4 grid ports at startup
- `grid.add(device)` - Global callback when grid connects (hot-plug support)
- `grid.remove(device)` - Global callback when grid disconnects; clears the vport's `key` handler and the `grids` slot
- `grids` table - Stores the **vport** (`grid.connect(port)`) of each connected grid, indexed by port (1-4). Both `grid_init` and `grid.add` go through `attach_grid(port)`
- Never store the raw device passed to `grid.add`, and never set `key` on it: devices have no `.device` field (so `grid_redraw` would skip them) and norns fires both `device.key` and `vports[port].key`, so handlers on both run every press twice. The arc uses the same vport-only pattern (`attach_arc`)

#### Grid Size Detection & Adaptive Layouts
`grid_layout(grid_port)` matches the exact `cols`/`rows` (16x16 is tested as `cols == 16 and rows == 16`; a `rows >= 16` test would also catch 8x16) and routes to the appropriate layout:
- **16×16 (256 buttons)**: `grid_key_256()` and `grid_redraw_256()` - Full-featured layout
- **16×8 (128 horizontal)**: `grid_key_128h()` and `grid_redraw_128h()` - Horizontal layout
- **8×16 (128 vertical)**: `grid_key_128v()` and `grid_redraw_128v()` - Vertical layout
- **8×8 (64 buttons)**: `grid_key_64()` and `grid_redraw_64()` - Compact layout

#### Pattern Sequencer Implementation
- **Pattern Storage**: `patterns[voice_idx][step]` - NUM_VOICES × PATTERN_LENGTH steps, values 0-15 (the 64 grid shows and edits only steps 1-8, but patterns still play all 16)
- **Playback Clock**: `pattern_clock` - Uses `clock.run()` and `clock.sync(1/4)` for tempo-synced 16th notes against norns' global clock. The script's `tempo` param (initialised from `clock_tempo`, with its range, read with `param_range("clock_tempo")`: 1-300, so a scene captured at any clock tempo recalls it exactly) sets `clock_tempo` in its action; grid tempo buttons adjust `tempo`. `install_tempo_change_handler()` (from `init`) installs the global `follow_clock_tempo` as `clock.tempo_change_handler`, keeping the previous handler in `previous_tempo_change_handler` and calling it after its own work; installing again is a no-op, so the handler never chains to itself. `restore_tempo_change_handler()` (from `cleanup()`) puts the previous handler back only while the script's is still installed, so a handler installed after it stays. A tempo set elsewhere (PARAMETERS > CLOCK, an external source) is thus mirrored into `tempo` silently (clamped to the param's range: an external source's tempo reaches the handler unclamped); scenes and grid buttons therefore always start from the playing tempo. The stub's `clock_tempo` action sets the internal clock's tempo and calls the handler, as norns' does; `clock.get_tempo()` returns the clock's tempo, and a sync waiting through a tempo change wakes at the new tempo (the beat timeline keeps its beat). External clock sources still work because the sequencer only syncs
- **Position Tracking**: `pattern_position` - Current step (1-16), wraps around. Each tick triggers the step, redraws the grid (so the highlight shows the step that just played), then advances
- **Triggering**: an active voice gets `engine.retrigger(voice - 1, level / MAX_STEP_LEVEL)` (accent in place at the step's level as velocity, one grain in triggered grain mode, no new nodes); a stopped voice is started with `toggle_voice`. Never retrigger by toggling a voice off and on
- **Pattern Operations**:
  - `toggle_pattern_step(voice, step)` - Toggle step on/off
  - `clear_pattern(voice)` - Reset all steps to 0
  - `randomize_pattern(voice)` - Generate random pattern with 50% density

#### Multi-Grid Synchronization
- All grids display the same interface simultaneously
- `grid_redraw()` iterates over `grids` table and updates each grid
- Shared state (patterns, voice status, pages) ensures consistency
- Each grid can trigger the same functions independently

#### LED Feedback Patterns
- **Active steps**: Brightness 15 (full)
- **Current playback position**: 15 if the step is active, 4 if empty (`step_brightness()`)
- **Voice active status**: Brightness 12
- **Voice inactive status**: Brightness 2-4
- **Page indicators**: 15 for selected, 2 for unselected
- **256 parameter page faders (rows 9-12) and FX faders (page 4, rows 3-7)**: bar at 8 up to the value, the value's column at 15; row 13 (page 2): fader pages, selected 15, available 4
- **256 page 4 buffers**: row 1 15 recording / 8 loaded / 2 empty, row 2 at 4; source rows 9-15 selected 15, others 4, empty buffers 2
- Always call `grid_port:refresh()` after updating LEDs
- Any state shown on the grid must call `grid_redraw()` when it changes, wherever it changes (`toggle_voice`, `toggle_freeze`, `randomize_voice`, scene recall, ...). `grid_redraw()` returns immediately when no grid is connected, so calling it is cheap

#### Key Implementation Details
- Grid key handler checks `z == 0` to ignore key releases (only respond to presses; only the norns keys have release handling, see Screen pages)
- Use `grid_port:all(0)` to clear all LEDs before redrawing
- Pattern clock uses `clock.sync()` for tempo-accurate timing
- Voices auto-activate when pattern step triggers them
- Stop pattern clock in `cleanup()` to prevent orphaned clock coroutines
- Grid pages allow switching between pattern sequencing and parameter control
- **Parameter page (256, page 2)**: `fader_param_ids(voice)` = the voice's `param_order` (synthesis params, amp/pan last; `BUFFER_FADER_KEYS` buf_pos/buf_rate/buf_scan then `voice_level_fader_keys(voice)` (`amp`, and `pan` for every voice but sub, which has none; the engine pans buffer and input grains) instead for a buffer source; for the input source no first keys, the grain params then `voice_level_fader_keys`; the source action clamps `param_page` to the new count), grain size/density/pitch/spread/envelope/mode, then source/amp mod/freq mod for crossmod slots 1-3. Fader page N (row 13, column N) shows entries `(N-1)*4+1 .. N*4` on rows 9-12 (`GRID_LAYOUT.param_page_row`, `fader_rows`, `fader_first_row`; `fader_width` 16 columns); pressing column x calls `set_fader_param()`, which looks up the id and calls `set_param_from_column(param_id, x)`: `spec:map(fader_column_fraction(id, x))` for control params, so faders follow each controlspec's warp (exp for freq, cutoff, mod speed), and `round(util.linlin(0, 1, min, max, fraction))` for number params (mod sources) and option params (grain envelope and mode, `param_range` gives `1, count`; it tests `param.options` because norns' `param.t` is a number). `fader_column_fraction` is `(x - 1) / 15`, except for a range that spans 0 (pan, `buf_scan`, the crossmod amounts; issue #49): 16 columns have no centre, so the plain sweep gives ±0.07 for pan there and never 0. Such a fader has a zero column (`fader_zero_column(id)`: the column nearest `param_value_fraction(id, 0)`, clamped to 2-15; column 9 for the symmetric ranges), which sets exactly 0, and each side of it sweeps its part of the range (in the warp's terms) evenly over its own columns, so column 1 is still the minimum and column 16 the maximum. `fader_position()` is the inverse (`param_fraction(id) * 15 + 1`, piecewise around a zero column, so 0 shows there; `param_fraction` is `param_value_fraction(id, params:get(id))`: `spec:unmap(value)` or the linear fraction of a number or option param's range). Each fader row is drawn by `grid_redraw_fader_row(grid_device, y, param_id)`. All through `params:set`. Voices have 4-6 fader pages
- **Buffers / FX page (256, page 4)**: `grid_key_256` has an explicit `grid_page == 4` branch so page 4 never falls through to the pattern page.
  - Row 1 (`GRID_LAYOUT.buffer_record_row`), columns 1-`NUM_BUFFERS`: `record_buffer(x)` (a second press stops early). Row 2 (`GRID_LAYOUT.buffer_clear_row`): `clear_buffer(x)`. `grid_redraw_256_buffers`: row 1 at 15 recording, 8 loaded, 2 empty; row 2 at 4
  - Rows 3-7 (from `GRID_LAYOUT.fx_first_row`): `GRID_LAYOUT.fx_fader_ids = {"filter_freq", "filter_res", "delay_time", "delay_feedback", "delay_mix"}` are faders (`set_param_from_column`/`grid_redraw_fader_row`). The filter/delay param actions call `fx_fader_changed()`, which redraws the grid while page 4 is shown, so the faders follow the screen, arc and scene recalls. During a smooth scene transition (`scene_transition_active`) it does not redraw: the transition loop redraws once per step
  - Rows 9-15 (`GRID_LAYOUT.source_first_row` + voice - 1): column x (1..`#SOURCE_OPTIONS`) is `params:set("v<voice>_source", x)` (1 synth, 2-9 buffer 1-8, 10 input); columns 11-16 do nothing. `grid_redraw_256_sources`: the selected source 15, other sources 4, empty buffers (not loaded, not recording) 2. The source param action calls `grid_redraw()`; buffer changes call it through `buffer_display_changed()`
  - Rows 8 and 16 work and draw as on page 1 (`grid_key_256_transport`/`grid_redraw_256_transport`, `grid_key_256_freeze`/`grid_redraw_256_freeze`)
  - Smaller grids have no buffers / FX page (buffers and sources are on the BUFFER screen page and in params)

### Arc Integration (Optional)

Strata supports the monome arc controller for tactile parameter control. The implementation follows these patterns:

#### Device Lifecycle
- `arc_init()` - Attach the first arc vport holding a device (`first_arc_port()`), else `UI_PAGES.ARC_PORT`, and set up callbacks via `attach_arc()`
- `arc.add(device)` - Global callback when arc connects; re-attaches the vport for `device.port` (handlers live on the vport only, as for grids)
- `arc.remove(device)` - Global callback when arc disconnects; removing the followed arc attaches `first_arc_port(port)`, the first other vport holding a device, if any
- Graceful degradation: `arc_redraw()` returns unless `arc_device` has a connected device

#### Arc Pages
Strata follows one arc: `arc_init` attaches the first vport that holds a device (else port 1); `arc.add` attaches the device's `port` (`UI_PAGES.ARC_PORT` if unassigned) only while no arc is connected; `arc.remove` acts only when the removed device is on the connected vport (`arc_device == arc.connect(port)`), so another arc neither replaces nor disconnects it. Removing the followed arc then follows the first other vport that holds a device (`first_arc_port(port)`: norns clears the removed vport only after `arc.remove` returns, so its port is skipped; issue #49), and disconnects only when there is none. Handlers live on that vport only. The arc follows the screen page (`ui_page`). `ARC_PAGE_DELTA` and `ARC_PAGE_REDRAW` are indexed like `UI_PAGES`: `arc_delta` calls `ARC_PAGE_DELTA[ui_page](ring, delta)`, and `arc_redraw` clears the rings, calls `ARC_PAGE_REDRAW[ui_page](arc_device)` and refreshes. MAIN uses `arc_main_delta`/`arc_main_redraw`, FX `arc_fx_delta`/`arc_fx_redraw`, LFO `arc_lfo_delta`/`arc_lfo_redraw`, BUFFER `arc_buffer_delta`/`arc_buffer_redraw`; SETUP has no rings (`arc_ignore_delta`/`arc_draw_nothing`). `enc(1, ...)` calls `arc_redraw()`, so changing page redraws the rings.

#### Input Handling
- **Ring speed rule**: every continuous ring (MAIN 1-4, FX 1-4, BUFFER 1-4, LFO ring 4 in free mode) goes through `arc_sweep_param(param_id, delta)`, which sweeps the control param's whole range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512) ticks: `params:delta(id, delta / (512 * controlspec.quantum))`. norns' `Control:delta` moves the 0-1 raw value by `d * quantum`, so the sweep follows the warp (256 ticks reach `spec:map(0.5)`, e.g. 200 Hz on the 20-2000 Hz exp freq) and the step only quantizes the value read back (raw keeps the remainder). 512 is half a revolution: the arc reports 1024 ticks per revolution (monome arc docs: "high resolution knobs, 1024 ticks per revolution", every edition; matron passes libmonome's deltas through unscaled, `device_monome.cc`). There are no per-ring scales; never add one beyond the two exceptions below. The LFO depth rings (`ticks_per_percent`) and the clocked rate (`ticks_per_rate`) step whole values instead
- `arc_delta(n, delta)` - Handle encoder rotation for rings 1-4 through the page's handler. MAIN:
  - Ring 1: Master density
  - Ring 2: Selected voice's main parameter (`main_param_id`; `buf_pos` for a buffer-sourced voice, `grain_size` for an input-sourced one)
  - Ring 3: Grain size for selected voice
  - Ring 4: Grain density for selected voice
- FX (`ARC_FX_RINGS`, `{param_id}` per ring): ring 1 `filter_freq`, ring 2 `filter_res`, ring 3 `delay_time`, ring 4 `delay_mix`. Each ring is drawn at level 12 to `param_fraction(param_id)` of a turn, so the exp params (filter freq, delay time) follow their controlspec warp
- BUFFER (`ARC_BUFFER_RINGS`, `{voice_key | param_id}` per ring): ring 1 `v<selected>_buf_pos`, ring 2 `v<selected>_buf_rate`, ring 3 `record_duration`, ring 4 `record_level`, each drawn to `param_fraction` of a turn. Rings 1-2 adjust the voice's buffer params whatever its source (they apply once it switches to a buffer) and are drawn at 15 for a buffer-sourced voice, 4 otherwise; rings 3-4 at 12
- LFO: rings 1-3 `lfo_depth_1..3` in whole percents (`arc_whole_steps` accumulates `ARC_LFO.ticks_per_percent` = 10 ticks per percent per ring, keeping the remainder, so the number param never holds a fraction), ring 4 (`ARC_LFO.period_ring`) the period of `selected_lfo`: `lfo_free_<n>` (`arc_sweep_param`) in free mode, `lfo_clocked_<n>` (one option per `ARC_LFO.ticks_per_rate` = 20 ticks) in clocked mode (`lfo_period_param_id`). Ring 4's carried remainder (`arc_lfo_ticks[4]`) belongs to one LFO's clocked rate: `forget_arc_lfo_period_ticks()` clears it when `selected_lfo` changes (`lfo_enc` E2) and when the selected LFO's `lfo_mode_<n>` changes (a `wrap_param_action` after-hook added in `add_lfo_params`), so it never steps another LFO or mode; the depth rings keep theirs. Depth rings are drawn to `param_fraction` at 15 while the LFO runs, 4 when off; ring 4 at 12
- `arc_key(n, s)` - Handle button press (2025 arc models)
  - On MAIN mirrors K3 (`start_or_freeze_selected_voice`); does nothing on other pages. MAIN is found by index, `ui_page == UI_PAGES.MAIN_PAGE` (1), never by the title string

#### LED Feedback
- `arc_redraw()` - Update all ring LEDs to reflect current parameter values (the current page's rings)
- Drawn by the frame clock when `UI_PAGES.arc_dirty` is set (`request_redraw()`, see Redraws under Screen pages): at most 15 times a second however fast the rings turn
- The arc keeps drawing while the norns menu is open: `draw_frame` calls `arc_redraw()` directly, whereas the screen goes through the global `redraw`, which norns swaps for `norns.none` in the menu. A param changed from PARAMS, a CC map or an LFO while the menu is open moves the rings at once (a test pins this)
- Every ring, MAIN 1-4 included, is drawn to `param_fraction(id)` of a turn (controlspec warp), so a changed param range moves the ring (a test swaps the controlspec to check)
- MAIN brightness levels indicate voice state:
  - 15 = active voice primary parameter
  - 12 = active voice secondary parameters
  - 4 = inactive voice primary parameter
  - 3 = inactive voice secondary parameters
- FX rings at 12; BUFFER rings 1-2 at 15 (buffer source) or 4, rings 3-4 at 12; LFO depth rings at 15 (running) or 4, ring 4 at 12
- Uses `arc_device:segment(ring, from, to, level)` for smooth arc visualizations
- Every ring is filled through `arc_ring_fill(arc_port, ring, fraction, level)`, never a bare `segment`: norns' `Arc:segment` reduces both angles modulo 2*pi, so a full turn (0 to 2*pi) lights nothing. The helper clamps the fraction to 0-1 and ends the fill `UI_PAGES.ARC_FULL_TURN_MARGIN` below a full turn, so a ring at its maximum lights all 64 LEDs and one at its minimum none. The test stub ports the real `Arc:segment` line for line (each LED set through `led()`, with `rel` adding to the level already there) and stores the per-LED levels it computed in `device.segments[ring].leds`; the device also keeps matron's LED buffer (`device:get_led(ring, x)`: `led` and `all` absolute or relative; a relative set is clamped to 0-15 as `dev_monome_arc_set_led` does, an absolute one is stored as is on matron, and the stub rejects an absolute level outside 0-15). Tests assert LED counts, not angles

#### Key Implementation Details
- Continuous rings sweep their param's range in `UI_PAGES.ARC_TICKS_PER_SWEEP` ticks through `arc_sweep_param` (see the ring speed rule above); never give a ring its own delta scale
- Parameters ranges must match between arc feedback and param specs
- `request_redraw()` marks the screen and the arc dirty together
- All arc functions are non-blocking and safe to call even without arc connected

### UI Updates

#### Screen pages

The screen has `NUM_UI_PAGES` (5) pages, named in `UI_PAGES = {"MAIN", "FX", "LFO", "BUFFER", "SETUP"}`; `ui_page` is the index of the shown page.
- `enc(1, d)` selects the page (`set_ui_page(util.clamp(ui_page + d, 1, NUM_UI_PAGES))`); E1 does nothing else. `init` turns E1's acceleration off and sets its sensitivity to `E1_TICKS_PER_PAGE` (4) with `norns.enc.accel(1, false)` / `norns.enc.sens(1, ...)`, so a fast turn steps pages instead of skipping to SETUP (norns resets these on every script load, so cleanup restores nothing). `enc(2|3, d)` calls `PAGE_ENC[ui_page](n, d)` and `key(n, 1)` calls `PAGE_KEY[ui_page](n)`
- **Key releases**: `key(n, 1)` records `key_press_page[n] = ui_page`; `key(n, 0)` clears it and calls `PAGE_KEY_RELEASE[ui_page](n)` only if the key went down on the page still shown, so a key held across a page change does nothing when released. Every page but BUFFER has `ignore_page_input` there, so presses keep their meaning and releases do nothing. "K2 is held on this page" is `key_press_page[2] == ui_page`. The norns menu (K1, PARAMS, its file selector) takes every key while open (`_menu.key` is the menu's handler), so a key released there never reaches `key()`; `forget_keys_held_through_menu()`, called at the end of `drift_update` (the 10 Hz `drift_metro` tick), clears `key_press_page` and `buffer_saved_during_k2` whenever `norns.menu.status()` is true. Without it a K2 released in the menu would stay held and every BUFFER K3 would save instead of record. It also runs the moment the menu opens: every way into the menu (K1, a script error, a keyboard's menu key) calls `_menu.set_mode(true)`, which `lua/core/menu.lua` and `keyboard.lua` look up on `_menu` at each call, so `watch_menu_opening()` (from `init`) wraps it in `menu_watch.wrapper` (call norns' function, then `forget_keys_held_through_menu()` when `mode == true`). The wrapper holds norns' function and `forget_keys_held_through_menu` as upvalues (no script-global lookup). `unwatch_menu_opening()`, the first thing `cleanup` does, puts `menu_watch.original_set_mode` back only if `_menu.set_mode` is still Strata's wrapper; otherwise (something wrapped it later) it leaves that wrapper in place and turns Strata's into a pass-through (`menu_watch.active = false`). The 10 Hz tick stays as a fallback. (norns has no key-state query. A file selector opened from play mode, as BUFFER K2 does, keeps `norns.menu.status()` false and takes the keys through the global `key`; it opens on K2's release, so only a K3 held at that moment can be released there. `buffer_key_release` therefore calls `forget_held_keys()` (a global: clears `key_press_page` and `buffer_saved_during_k2`, also the body of `forget_keys_held_through_menu`) just before `fileselect.enter`)
- `redraw()` is `screen.clear(); draw_header(); PAGE_DRAW[ui_page](); screen.update()`. Each page's draw function ends with `draw_hints(text)` (level 4, x=0, y=62)
- **Redraws** (issue #11): nothing in Strata calls `redraw()` or `arc_redraw()` directly any more. Anything that changes what the screen or the arc shows calls the global `request_redraw()`, which sets `UI_PAGES.screen_dirty` and `UI_PAGES.arc_dirty`. The frame clock (`UI_PAGES.frame_clock`, `start_frame_clock()` at the end of `init`, `stop_frame_clock()` first among `cleanup`'s clocks) sleeps `1 / UI_PAGES.FRAMES_PER_SECOND` (15) and runs `draw_frame()`: it clears each dirty flag and calls the global `redraw()` and/or `arc_redraw()`, so a burst of arc turns, encoder steps, MIDI or param changes costs one screen draw and one arc redraw per frame, and an idle frame draws nothing. Each draw runs through `draw_frame_part(part, draw)` (`part` is `"screen"` or `"arc"`; `xpcall` with `draw_error_report`, which returns a key and the error with its traceback: a string error is its own key; a table error, a new table each time, is keyed by its `message` field (also what is printed) or else its type): an error is printed to the console with its traceback and the clock keeps running; the flag was already cleared, so the failed draw is not retried, and the next `request_redraw()` draws again. `UI_PAGES.draw_errors[part]` holds the key last printed, so a draw that keeps failing with the same error (e.g. on the LFO page, which draws every frame) prints it once instead of 15 times a second; another message prints, and a good draw clears it, so the same error after a good frame prints again (issue #49). On the LFO page it marks the screen dirty every frame (the dots move). Both flags start set, so the first frame draws the screen and any arc connected at start. Because `draw_frame` calls the global `redraw`, norns' swaps apply: while the norns menu is open the global is `norns.none` (norns calls `redraw()` itself as the menu closes), and while the BUFFER file selector is open `redraw()` draws the selector, never the page. norns' own `redraw()` calls still draw the page at once.
  - **Who asks**: every param action, through `redraw_on_param_changes()` (run once in `init` after the last param is added; a param added, or an action set with `params:set_action`, after it runs does not request redraws), which wraps each param's action so it calls `request_redraw()` after it: PARAMS edits, PARAMS > MAP CCs, pset loads, scene fades and recalls, mutations, MIDI notes (they set freq or buf_rate) and the LFO page's E3/K2/K3 all arrive through param actions. Left out: text params (the LFO library writes each LFO's scaled and raw values into `lfo_scaled_<n>`/`lfo_raw_<n>` on every step, shown nowhere) and the drift's 10 Hz writes (`drift_writing`; grain pitch is shown nowhere, and `drift_update` requests a redraw itself when it moves the selected voice's buffer position, which MAIN and the BUFFER arc ring show; other voices' positions are shown nowhere, so they ask for none). Explicit calls cover state that is not a param: `enc`, `key`, `arc_delta`, `arc_key` (MAIN), `grid_key`, `toggle_voice`, `toggle_freeze`, `randomize_voice`, `gentle_mutate`, each smooth-transition step, `recall_scene` and the end of `recall_scene_instant` (freeze and running states), the scene sequencer, `buffer_display_changed`/`buffer_state_changed`, the BUFFER flash's end and the file selector's callback, and the grid/arc/MIDI hot-plug callbacks
- `PAGE_DRAW`, `PAGE_ENC`, `PAGE_KEY` and `PAGE_KEY_RELEASE` are indexed like `UI_PAGES`; `ignore_page_input` fills the slots a page does not use. To add a page, write its draw/enc/key functions and put them in the tables (and the arc tables below)
- The tables are script locals built after the functions they hold, so page functions must be defined above them
- **MAIN** (`redraw_main`, `main_enc`, `main_key`): the original screen - E2 voice select, E3 main parameter, K2 randomize, K3 starts a stopped voice or freezes/unfreezes a running one (`start_or_freeze_selected_voice`; it never stops a voice)
- **FX** (`redraw_fx`, `fx_enc`, `fx_key`): a scrolling list of `FX_PAGE.rows` (`{label, param_id, format}`; `format` is a `string.format` pattern, or nil for the param's own string): density, tape drift, filter type/freq/res/mix, delay time/fdbk/mix, reverb mix/size/damp. `FX_PAGE.visible_rows` (5) rows at y=18-50 (`first_row_y` 18, `row_spacing` 8), label at x=0 and value right-aligned at x=127, the selected row (`fx_row`) at level 15 and the others at 4; the view keeps one row above the selection. E2 selects the row, E3 is `params:delta` on its param. K3 toggles `filter_mix` between 0 and `fx_filter_last_mix`, which the `filter_mix` param action records whenever the mix is set above 0 (from E3, PARAMS, scenes or K3; initially 1). Hint: `K3:filter bypass` when the mix is above 0, else `K3:filter on`
- **BUFFER** (`redraw_buffer`, `buffer_enc`, `buffer_key`, `buffer_key_release`): left column (x 0-60) the selected voice's name (y 18), `src: <voice_source_label>` (y 26), `dur:` record duration (y 42) and `lvl:` record level (y 50); divider at x 62; right column eight rows (`BUFFER_PAGE.row_first_y` 14, `row_spacing` 6, so y 14-56): slot number at x 65 (`slot_x`), name at x 71 (`name_x`) (file name without extension, cut by `fit_text` with `screen.text_extents` to `BUFFER_PAGE.name_max_width` 31 px, whole UTF-8 characters at a time; `buffer_display_name` caches the cut name in `buffers[slot].display_name` until `name` changes, so a redraw measures nothing), seconds (`%.1fs`) or `REC` right-aligned at x 127. Row level: the selected voice's buffer (`voice_buffer_slot`) 15, loaded or recording 8, empty 2. E2 is `select_voice_by` (shared with MAIN), E3 `params:delta("v<i>_source", d)`. K3 press: `record_buffer(slot)` (toggles: stops early while recording), or `save_buffer(slot)` when K2 is held on this page (`buffer_saved_during_k2` then makes the K2 release do nothing), confirmed by `buffer_page_flash(text)`: `buf <n> busy` (and no `save_buffer` call) while the slot is `recording` or `finishing`, else `saved buf <n>` when the slot reports audio (`seconds > 0`, the rule `save_buffer` saves by), else `buf <n> empty`; `buffer_load_failed` flashes `buf <n> load failed` when the engine reports a failed load (see the buffers table in `engine.md`). The flash stores `BUFFER_PAGE.flash_text` and `flash_until = util.time() + BUFFER_PAGE.flash_seconds` (1.5); `redraw_buffer` draws it in the hint row instead of the key hints while `util.time() < flash_until`, and `BUFFER_PAGE.flash_clock` (a `clock.run` that sleeps 1.5 s, clears the text and asks for a redraw) makes it go away untouched. A new flash cancels the previous clock; `cleanup` cancels it (`cancel_buffer_page_flash_clock`). K2 release: `fileselect.enter(_path.audio, cb)` (`fileselect` is the main chunk's `local fileselect = require "fileselect"`, as in norns' own `core/menu.lua`: the library is a module, not a global), where `cb` calls `load_buffer(slot, path)` unless the path is `"cancel"`, then clears `BUFFER_PAGE.file_selector_open` and asks for a redraw (the next frame draws the page). `buffer_key_release` sets that flag just before `fileselect.enter`, and while it is set `redraw()` calls `fileselect.redraw()` (lib/fileselect.lua's `fs.redraw`, which draws the file list) instead of the page: from play mode `fs.enter` calls `norns.menu.init()`, whose `_menu.set_mode(false)` puts Strata's `redraw` back in the global, so without the flag the selector's own `redraw()` call and every frame-clock redraw (asked for by `key()`, buffer polls, sequencer steps, MIDI, grid/arc events) would draw over the file list. Drawing the selector rather than nothing also covers the norns menu opened and closed over it (K1 twice): `set_mode(false)` clears the screen and calls `redraw()`, which then shows the list again instead of leaving the screen blank. norns calls the callback on a choice and on a cancel alike (`fs.exit`, after its own `redraw()`), so the flag always clears; the callback calls `close_buffer_file_selector()`, which clears the flag, `BUFFER_PAGE.file_selector_callback` and the saved handlers and asks for a redraw. If `fileselect.enter` raises (it runs in an `xpcall` with `with_traceback`), no callback will come: Strata's `key`/`enc` go back in the globals, `close_buffer_file_selector()` runs, and, unless the menu is open, `pcall(norns.menu.init)` routes play mode again (every realistic failure point in `fs.enter` comes after its `norns.menu.init()` has routed `fs.key`/`fs.enc`, and keys reach the script through `_menu.key`/`norns.encoders.callback`, which only `set_mode(false)` copies from the globals, as `fs.exit` relies on); then the error is raised again. **A second selector** (issue #49): norns has a single selector (`lib/fileselect.lua`'s module state). From play mode `fs.enter` stores Strata's `key`/`enc`/`redraw` in `fs.key_restore`..., puts `fs.key`/`fs.enc` in the globals, and `norns.menu.init()` hands them to play mode (`_menu.key = key`, `norns.encoders.callback = enc`). If the menu is opened over it (K1) and a PARAMS file param (or TAPE) calls `fs.enter` from menu mode, that call overwrites `fs.callback` and the restore fields with the menu's; its `fs.exit` restores the menu's handlers only, Strata's callback never comes and the globals keep `fs.key`/`fs.enc`, which `set_mode(false)` would give play mode as the menu closes (a later exit from that stale selector would even install the PARAMS menu's handlers as the script's). So `buffer_key_release` records the callback (`BUFFER_PAGE.file_selector_callback`) and Strata's `key`/`enc` (`BUFFER_PAGE.script_key`/`script_enc`), and `menu_watch.wrapper` calls `release_superseded_file_selector()` (in a `pcall`, printing an error, so it can never stop the menu closing) before norns' `set_mode(false)`: on a real menu-to-play change (`norns.menu.status()` still true as `set_mode(false)` starts), while the flag is set and `fileselect.callback` is set but no longer Strata's, it puts Strata's `key` and `enc` back in the globals (norns' `set_mode(false)` then gives them to play mode) and calls `close_buffer_file_selector()`. The selector's own `set_mode(false)` calls (from `norns.menu.init` in `fs.enter`/`fs.exit`) run in play mode and change nothing. A norns whose fileselect keeps no `callback` field releases nothing (the flag may then stay set after a menu selector, as before #49), so an internals change can never break BUFFER K2 itself. With no buffer source (synth, input) K2 and K3 do nothing. Hints: `K2:load K3:rec K2+3:save` (`K3:stop` while the slot records, `K3:...` while it is `finishing`), or `K2:- K3:- E3:source`
- **LFO** (`redraw_lfo`, `lfo_enc`, `lfo_key`): one row per LFO, row top `LFO_PAGE.row_first_y` (16) + (n - 1) × `LFO_PAGE.row_spacing` (15), so rows fill y 16-57: `L<n>` at x 0 (baseline top + 7; level 15 for `selected_lfo`, 4 otherwise), one cycle of the shape as a 64-px polyline from x `LFO_PAGE.wave_x` (12) to 75, value 1 at the row top and 0 at top + `LFO_PAGE.wave_height` (10), level 6 running / 2 off, from `lfo_shape_value(shape, phase)` (a mirror of the library's shape math; random is drawn as two held steps). While the LFO runs and has sent a value, a 3×3 dot at x = 12 + `lfo_phase_estimate(n)` × 63, y from `lfo_last_raw[n]`. Right-aligned at x 127: the destination label (baseline top + 5) and `on|off <depth>%` (top + 11). Hints `E3:depth K2:dest K3:on|off`. E2 selects `selected_lfo`, E3 `params:delta("lfo_depth_<n>", d)` (percent), K2 steps `strata_lfo<n>_dest` (wrapping to none), K3 toggles `lfo_<n>` between 1 and 2. The page has no clock of its own: `draw_frame` marks the screen dirty on every frame while it is shown (15 fps, see Redraws), so the dots move
- **SETUP** (`redraw_setup`, `setup_enc`, `setup_key`): grid count and sizes (in port order), arc connected/none, `scenes: k/8 saved`, `buffers: k restored` (`buffers_restored`, engine-confirmed; `buffers: k ok, m missing` when remembered files were missing), `midi <port>: <device>` (y 48; `midi_device_name()` cut with `fit_text` to end by x 127, so long norns device names fit) and `ch: <channel mode>` (y 54, level 4); rows y 18-54, 6 px apart. E2 is `params:delta("midi_device", d)`, E3 `params:delta("midi_channel_mode", d)`, K3 calls `save_scenes_to_disk()`. Hints `E2:port E3:ch K3:save`. `setup_enc` is a global function (the main chunk is near the local limit). `grid.add`/`grid.remove`/`arc.add`/`arc.remove`/`midi.add`/`midi.remove` call `redraw()` so SETUP stays current
- Master density left E1. It is on the FX page's first row, MAIN's arc ring 1, in params, and in the header on every page

#### Main parameter

`main_param_id(voice_idx)` returns the param E3 and arc ring 2 adjust on MAIN (`v<i>_freq` resonator, `_index` fm, `_fold` folder, `_drift` sub, `_width` pulse, `_decay` karplus, `_ratio` ring) and `main_param_label(voice_idx)` its screen label. Both read `main_param_entry(voice_idx)`: the `MAIN_PARAMS` entry for the voice type (param id suffix, screen label, value format; arc ring 2 sweeps it with `arc_sweep_param`), `BUFFER_MAIN_PARAM` (`buf_pos`, label `pos`, `%.2f`) for a buffer source (spec §1), or `INPUT_MAIN_PARAM` (`grain_size`, label `size`, `%.2f s`) for the input source (its synth and buffer params do nothing). Use them instead of `if v.name ==` chains; arc ring 2 is drawn to `param_fraction(main_param_id(...))` of a turn (following the warp, like the FX and BUFFER rings)

#### MAIN layout

The `update_voice_list()` function recreates the `UI.ScrollingList` on every change. Each entry is plain ASCII, so its width does not depend on how the norns font draws other glyphs:
- Active status (`+` running, `-` stopped)
- The voice type's short name, `MAIN_PARAMS[type].list_name` (`reso`, `fm`, `fold`, `sub`, `pulse`, `karp`, `ring`; at most 5 characters). The details column shows the full name and ON/OFF
- Freeze status (` [F]` suffix)

The widest entry, `+ pulse [F]`, is 54 px by the harness estimate, so it ends 8 px before the divider. The list puts the selected voice on row 2 (y=26, the ON/OFF row) except at the ends of the list (`num_above_selected` = 1), so entries must stay left of x=60 or they overlap the details.

MAIN uses a two-column layout:
- **Header (y=8, `draw_header()`, identical on every page)**: page title at x=0 (04B_03 capitals advance ~6 px, so the longest title `BUFFER` ends near x=36), `dens:1.00` at x=40, `[M]` at x=98, scene indicator `S1`-`S8` right-aligned at x=127
- **Left column (0-60px)**: Scrolling voice list (4 visible at a time, rows y=15-48)
- **Right column (65-128px)**: Selected voice details (name, status, main parameter at y=42/50); `[FREEZE]` is right-aligned at x=127 on the status row (y=26), `[TRIG]` (triggered grain mode) right-aligned at x=127 on the main-parameter label row (y=42)
- **Divider (x=62)**: Subtle vertical line separating columns
- **Hint row (y=62)**: `K2:rand K3:freeze|start`
- `test/run.lua` checks, on every page and for every selected voice, that no two strings on a row overlap and that nothing leaves 128×64 (estimating 6 px per capital, 4 per bracket/colon/period, 5 otherwise), that `dens:` starts at least 4 px after the page title, that a hint row is drawn at y=62, and that the voice list's last row ends above the hint row. On MAIN every string between the header and the hint row must end by x=60 or start at x=65 or later (never across the divider); a separate test draws the list for every voice, selection and running/frozen state. Keep them passing when adding text. The width estimate is `stubs.text_width` in `test/norns_stubs.lua` (it counts UTF-8 characters, not bytes), which the screen stub also uses for `screen.text_extents` (returns width, 8); the stub records each string's `x`, `y`, `align` (`left`, `right`, `center`) and `level`. The stub's `UI.ScrollingList:redraw` is the real one from `lua/lib/ui.lua`, so the list's entries are recorded like any other text (an empty string where the list scrolls past an end)
- Parameter faders on grid page 2 are redrawn after `gentle_mutate`, after every scene-transition step, and from `drift_update` only when a grid shows page 2 (it runs 10x/s)
- MIDI pitchbend asks for no redraw: nothing on the screen or the arc shows the bend
- The grid's scene page follows changes made anywhere: `recall_scene_instant` sets `current_scene` before its closing grid redraw, so an instant recall repaints the grid once with the scene lit, and `recall_scene` redraws the grid after a smooth recall's start (the fade's first step redraws before `current_scene` is set), the `scene_sequence_length` action redraws it (PARAMS, CC maps, PSETs) and `scene_sequencer_start` redraws it as it turns the sequencer on (issue #49)

When adding UI elements, update the page's draw function (`redraw_main`, `redraw_setup`, ...), never `redraw()` itself.


## Future Extension Points

Potential expansion areas:
- ~~Cross-modulation between voices~~ ✓ Implemented (v1.0)
- ~~Additional voice types (Pulse, Karplus, Ring)~~ ✓ Implemented (v1.0)
- ~~Probability-based parameter mutations~~ ✓ Implemented (v1.0)
- ~~Monome grid integration~~ ✓ Implemented (v1.0)
- ~~Longer-form automation/sequencing~~ ✓ Implemented (v1.0 - scene system)
- ~~Multi-source modulation routing~~ ✓ Implemented (v1.0 - 3 slots per voice)
- ~~Scene disk persistence~~ ✓ Implemented (v1.0 - auto-save/load + manual triggers)
- ~~Scene data validation~~ ✓ Implemented (v2.0)
- ~~Bounds checking and safety~~ ✓ Implemented (v2.0)
- ~~Modulation signal clamping~~ ✓ Implemented (v2.0)
- More voice types (wavetable, additive, granular noise, etc.)
- Modulation matrix visualization on grid or arc
- Per-scene naming/tagging system
- ~~MIDI integration for external control~~ ✓ Implemented (v3.0 - notes, velocity, pitchbend; CC via norns PARAMS > MAP)
- ~~Sample buffers and live input~~ ✓ Implemented (v3.0 - per-voice sources)
- ~~Global LFOs~~ ✓ Implemented (v3.0 - three, on norns `lib/lfo.lua`)
- Engine-side LFOs (above the Lua library's 10 Hz ceiling)
- Buffer waveform display on the BUFFER page
- Tempo-synced delay times
- Undo/redo for parameter changes
- Parameter automation recording

## Version History

### Version 3.0.1 (2026-11-03)

Fixes the minor findings deferred from the 3.0 reviews; no command, param or file format changes. Highlights:
- Arc: every continuous ring sweeps its range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512 ticks, half a revolution) through `arc_sweep_param`, following the warp; MAIN ring 2 drawn along the warp; LFO ring 4's carry reset on LFO or mode change; `arc_key` finds MAIN by index
- BUFFER K2+K3 save flash (`buffer_page_flash`); held keys forgotten when the norns menu opens (`watch_menu_opening` wraps `_menu.set_mode`); omni pitchbend follows the selection
- Buffer takes and loads settle on the engine's `bufferState` report (`finishing`, `settle_buffer_slot`, `settled_empty` for late reports, `BUFFER_SETTLE` fallback); `buffers_restored` engine-confirmed; missing files kept in `missing_path`
- One full sync per scene recall, after the recalled params (`scene_recall_in_progress`); `voiceOn` density from `engine_param_value`
- Engine: filter type crossfade (20 ms), grain-mode fade (50 ms), `slotChanges` guards against stop/clear and load races, loads apply on completion, grain synths placed by `startPlacedGrainSynth`, mirror off by default, amplitude crossmod for input-sourced voices, failed writes cleaned up and stale `.part` files deleted at alloc
- Rulings: arc sweep 512 ticks; the write interleave keeps its per-frame loop (an array `lace` measured about twice as slow)
- Tests: 118 Lua tests; the engine check bounds every reply wait (`awaitReply`, 5 s) and the whole run (540 s)

See CHANGELOG.md.

### Version 3.0 (2026-11-03)

Absorbs the Confluence script's feature set (spec: `docs/superpowers/specs/2026-11-03-confluence-features-design.md`). Highlights:
- Paged screen UI (MAIN, FX, LFO, BUFFER, SETUP; E1 selects, no acceleration) with arc pages that follow it
- Master filter (`setFilter`) and stereo delay (`setDelay`) before the reverb; limiter moved before the saturator
- Grain envelope shapes (`envShape`) and triggered grain mode (`grainMode`); `retrigger` carries velocity (`"if"`)
- Eight stereo 16 s buffers and the live input as per-voice grain sources (`setGrainSource`, `loadBuffer`, `recordBuffer`, `stopRecord`, `clearBuffer`, `saveBuffer`, poll `bufferState`); BUFFER page, arc buffer rings, grid 256 page 4
- Buffer persistence: scratch takes, remembered paths in `buffers.data`, explicit timestamped save
- Three global LFOs on norns' `lib/lfo.lua`, modulating around stored values through `send_param_to_engine`; per-voice drift renamed `drift_update`
- MIDI notes, velocity and pitchbend (`bend`) with per-voice channels; CC through norns PARAMS > MAP
- Scene format version 2 with migration of version-1 files

Deviations from the spec (controller rulings): limiter before the saturator; K3 keeps start/freeze (no grain trigger); input-sourced voices' main param is grain size; LFO ceiling 10 Hz, LFO depth in percent, 48 ppqn plus send dedupe; one-slot-per-message `bufferState` encoding; `stopRecord` added; K2+K3 save gesture; scenes capture LFO mode and clocked rate as well as the free period; grain-side accent only for the input source (`accentAmt`); the input `\strataGrain` mirrors to the voice bus; `scratchDir` is an engine variable. See CHANGELOG.md.

### Version 2.1 (2026-11-03)

Whole-app review fix release. Highlights:
- `voiceOn` signature `"iffffff"` (freq was typed as a string and dropped); voices start with their full Lua state (`sync_voice_to_engine`)
- Pattern steps accent running voices with the new `retrigger` command instead of stacking synth chains
- Grain pitch is real pitch shifting; its LFO drift is subtle and mean-reverting
- Tempo param drives `clock_tempo`; 128v layout reachable; grid hot-plug fixed; 256 parameter page implemented as faders; grid LEDs stay current
- Silent bus for unrouted mod slots; frequency modulation clamped above zero; FM/Sub clamped
- Linear scene transitions; thorough scene validation; versioned, crash-safe scene file loading
- Engine nodes ordered inside `context.xg`; resonator and reverb no longer double their output; drift amounts mean depth
- Off-device test harness (`test/`)

See [CHANGELOG.md](CHANGELOG.md) for complete details.

### Version 2.0 (2025-01-24)

Major stability and code quality release focusing on bug fixes and defensive programming:

**Critical Bug Fixes**:
- Scene data validation prevents crashes from corrupted files
- Scene sequencer position bounds checking prevents out-of-bounds access
- Concurrent scene transition prevention via clock tracking and cancellation

**High Priority Bug Fixes**:
- Arc initialization race condition fixed
- Mutation metro state synchronization in cleanup
- 64-button grid pattern display corrected
- Pattern/scene bounds checking added throughout
- Scene transition nil access protection

**Code Quality Improvements**:
- Named constants (NUM_VOICES, NUM_SCENES, PATTERN_LENGTH) replace magic numbers
- Comprehensive error handling and validation patterns
- Resource management with proper cleanup
- Modulation signal clamping in SuperCollider engine

See [CHANGELOG.md](CHANGELOG.md) for complete details.

### Version 1.0

Initial release with:
- 7 synthesis voices with granular processing
- Cross-modulation (3 slots per voice)
- Probability-based mutations
- Scene system with disk persistence
- Grid and arc integration
- Pattern sequencer


## Test harness details

(Moved from CLAUDE.md.)

**Off-device tests** (run from the repo root before committing):
- `lua test/run.lua` and `luajit test/run.lua` - loads `strata.lua` into norns stubs (`test/norns_stubs.lua`) and runs the behaviour tests; exits non-zero on failure. The engine stub rejects any `engine.*` call whose name, argument count or types do not match the SC `addCommand` signatures, and the run includes the static sync check. It also range-checks the values, with limits parsed from the engine source by `stubs.parse_engine_spec` (`numVoices`, `numBuffers`, `inputSource`, `voiceSynthDefs`, the SynthDef `arg` lists): voice 0..numVoices-1, slot 0..numBuffers-1, source 0..numBuffers+1, mod slot 1..N (`modBus1..N` on every voice SynthDef), mod source -1..numVoices-1, and the whole-number controls the engine rounds and clips (`name.round.clip(low, high)`: `filterType` 0-2, `grainMode` 0-1) plus `envShape` 0..the number of `envBuffers`. Continuous arguments are checked where the engine enforces a limit (`argument_limits`): an FX control its SynthDef clips as it is (`feedback.clip(0, 0.95)`, `freq.lag(0.05).clip(20, 20000)`: the filter's freq, res and mix, the delay's time, feedback and mix) or an argument the command clips itself (`msg[2].clip(0, 1)`: `retrigger`'s velocity); a rounding error of 1e-12 of the limit passes (a 0.01 step makes 0.95 into 0.9500000000000001). The engine clips no crossmod depth or mod speed, but CLAUDE.md's table documents their ranges, so `setModAmpAmt`, `setModFreqAmt` and `setModSpeed` are checked against the controlspec of the Lua param that sends them (`DOCUMENTED_LIMITS`, read at call time; a test checks that CLAUDE.md's row states that range). A `setVoiceParam` name must be a control of that voice's SynthDef (`bend` is one); a `setGrainParam` name a control of either grain SynthDef (`grainDefFor`; the engine keeps the value for a later source switch) or a name the command handles itself (`param == \envShape`). Every engine command needs an entry in the stub's `engine_argument_checks` (an empty one when it takes no index or enumerated value), so a new command fails until its limits are decided. A control added to a SynthDef needs no stub change, and the voice, slot and source limits follow `numVoices` and `numBuffers` (a test parses a patched copy of the engine). Every parser of the engine source (the stub's `engine_signatures_from_source`, `engine_polls_from_source` and `engine_spec_from_source`, `sync_check.lua`, which uses the stub's, and the CLAUDE.md table check) first runs `stubs.strip_sc_comments`, which blanks `//` and (nested) `/* */` comments but not strings, quoted symbols or `$x` characters, so a commented-out command, poll, SynthDef, argument or `Env` is never counted; an unterminated string, symbol or block comment is an error naming its line (it would otherwise swallow the rest of the file). The spec also holds `bufferSeconds`, `bufferStateStride`, each SynthDef's numeric argument defaults (`synthdef_defaults`) and `fx_commands`: the commands whose body sets an FX synth (`synths[\key] = Synth(\def, ...)`) through `this.setSynth(\key, \control, msg[i], ...)`, as a list of `{argument, synthdef, control}` read from every such `setSynth` call in the body. One test sends every `strata_fx` param's default through `send_param_to_engine` and checks that each FX command then carries its SynthDef's defaults (the script never bangs its params, so until a param changes the engine plays those); another checks that `numVoices`, `numBuffers`, `bufferSeconds` and `bufferStateStride` equal `NUM_VOICES`, `NUM_BUFFERS`, `BUFFER_SECONDS` and `BUFFER_STATE_STRIDE`. Like norns, the param stub stores numeric type codes in `param.t` (`params.tOPTION` etc.), all taken from its one `PARAM_TYPE_CODES` table (exported as `stubs.PARAM_TYPE_CODES`; `params:add` with an unknown type raises an error, where norns prints one and adds nothing); never compare `param.t` with a string (a test enforces this for `strata.lua`, with either quote and either order: `p.t == "option"`, `'option' == p.t`).
- `lua test/sync_check.lua` - static check that every `engine.<name>(...)` call in `strata.lua` has a matching `addCommand` with the same number of arguments, and that every command is used. Any other use of the global `engine` fails it, because the check cannot see what it calls: `engine[name](...)`, a command referenced without a call (`local f = engine.voiceOn`), `engine:x()`, a call without parentheses (`engine.loadBuffer "x"`) or the table itself as a value (`local e = engine`). Only `engine.name` may be read or set; a table key or function parameter named `engine` (`{ engine = 1 }`, `function(a, engine)`) and `#engine` name no command and pass. `sync_check.check(lua_source, sc_source)` runs it on any source (the test patches `strata.lua` with each form).
- The run also checks CLAUDE.md: the command table under "Lua ↔ SuperCollider Communication" must have exactly one row per engine `addCommand`, with the same signature and argument count, and no `engine.<name>(` mentioned in CLAUDE.md, README.md or any `docs/notes/*.md` may name a command the engine no longer has. Update the table in the same commit as the engine.
- `test/run_engine_check.sh [path/to/norns]` - compiles `lib/Engine_Strata.sc` against the real norns `sc/core` classes (default `~/src/norns`, or `$NORNS_DIR`), boots a local scsynth with its output on a private bus (silent) and runs `test/engine_check.scd`, which drives every engine command. It adds SynthDefs of its own, `\strataCheckTone` (a 440 Hz tone written into `inputBus`) and `\strataCheckPeak` (a resettable peak meter on a stereo bus), to hear what a voice's bus carries, `\strataCheckSine`/`\strataCheckStep` (a sine of any frequency; the largest sample-to-sample step on a bus) for the filter crossfade, and (added by `addAudioCheckDefs`) `\strataCheckChannelPeaks` (per-channel peaks, for pan), `\strataCheckBadValues` (NaN/inf seen on a bus), `\strataCheckRms` (a bus's RMS over about 1.5 s) and `\strataCheckBadSource` (50 ms of inf and NaN; a float overflow, since `log(0)` is not -inf in scsynth). The check routine is at sclang's per-function selector limit: new checks go in top-level functions called from it. Every server reply it waits for goes through `awaitReply` (5 s, then a FAIL) and the whole check fails after 540 s, so a reply that never comes fails the check instead of hanging it (CI kills the job at 600 s). The script itself runs sclang under `timeout` (`ENGINE_CHECK_TIMEOUT`, default 570 s; a normal run takes about 2 minutes) with line-buffered output (`stdbuf`), and stops it as soon as the output shows a compile error (a syntax error in `engine_check.scd`, `Library has not been compiled successfully`): sclang never exits by itself then, and would hold the shared lock and CI's job until killed. `timeout` signals the whole process group, so the scsynth sclang booted goes too; without a `timeout` command the script's own watch loop enforces the limit. The script's own stop signals sclang and every descendant (`kill_tree`, children first), so no scsynth is left on port 57110, and exit 124 or 137 (timeout's `--kill-after` SIGKILL) reports as a timeout. Checks run at the same time on one machine share scsynth's port 57110 and break each other: run one at a time. Needs SuperCollider: sclang is `$SCLANG` if set, else `sclang` on `PATH`, else the macOS app path. On Linux scsynth also needs a running JACK server; CI and local runs use a dummy driver: `jackd --no-realtime -d dummy -r 48000 -p 1024 &` (check with `jack_lsp`), and `QT_QPA_PLATFORM=offscreen` keeps sclang headless.
- `test/StrataTestNoBoot.sc.in` is deliberately not a `.sc` file: norns compiles every `.sc` under `~/dust`, and that test class disables Crone's boot.
- Add a test to `test/run.lua` for every behaviour change; script locals are reached through `find_upvalue()`/`local_value()`. `load_strata { source = text }` loads a patched copy of the script instead of `strata.lua`. Each `load_strata` gets a data directory of its own, named by a counter (tests reseed `math.random`, so a random name could repeat); `load_strata { data_subdir = name }` shares one between loads (the persistence tests).
- Group sizes: norns cannot see where a group ends (it takes the next `n` params), so the param stub requires each group to get exactly `n` params. It errors when the next group arrives first (this is also the nesting error), when the param after the group's last one is neither a separator nor a group (`n` too small), or, in `context.check_param_groups()`, which `load_strata` calls after `init()`, when a group is still short at the end of the list.
- The stubs mirror the real norns libraries (`~/src/norns/lua`), so check behaviour there before changing them. Besides params (number, control, option, binary, trigger, file, text, separator, group; `set_action`, `hide`/`show`/`visible`; `params:write(path)`/`params:read(path, silent)` as in `lua/core/paramset.lua`, absolute paths only: read sets each param in file order through its own `set`, so actions fire mid-read as on norns, and `params:set_save(id, false)` keeps a param out of the file, as norns does for most system params; strings as `core/params/*.lua`: a control without a formatter shows `util.round(value, 0.01) .. " " .. units`, a number or binary returns its value, a number; a ControlSpec made without a default has `default` nil and its control starts at raw 0; the `exp`, `db` and `lin` warps), with norns' system params first (`audio.add_params` and `clock.add_params`: the LEVELS, REVERB, COMPRESSOR, SOFTCUT and CLOCK groups with their types, ranges and factory defaults, `clock_tempo` 120; every id of `core/paramset.lua`'s `system_param_ids` but `clock_midi_out`, which norns never adds: its params are `clock_midi_out_1..16`), so a script param with a system id fails as a collision, they provide: `tab.save`/`tab.load` (lib/tabutil.lua's, ported unchanged: the `-- Table: {n}` layout, numbers through `tostring`, so they keep 14 significant digits as on norns; a plain `return {...}` file loads as nil, so test fixtures are written with `tab.save`, or the `tabutil_text(value)` helper in `test/run.lua`), `require("lfo")` (`test/stub_lfo.lua`, compared line by line with `lib/lfo.lua`: the library's `lfo_*` params and actions, and `reset_phase` and `set("period")` reset and rescale `phase_counter` as the library does; nothing runs on its own, `context.lfo.tick(instance, raw)` performs one library step with `raw` 0..1 as the shape output), `midi` (`test/stub_midi.lua`: 16 vports, `to_msg`/`to_data`; helpers `context.midi.plug(port, name)`, `unplug(port)`, `send(port, msg)`), `poll.set` (system polls plus the engine's `addPoll` names, unknown names return nil; `context.polls.fire(name, value)` reaches started polls), `require("fileselect")` (a module through `package.preload`, never a global, so a script that relies on a `fileselect` global fails; `enter` records `context.fileselect.last` (and its callback in `fileselect.callback`, as `fs.enter` keeps it in `fs.callback`, so a second `enter` replaces the first's) and, from play mode, calls `norns.menu.init()` (so a script's `_menu.set_mode` wrapper runs) and makes the `redraw()` call norns' `fs.enter` makes, then its own `fileselect.redraw()`; `fileselect.redraw` draws nothing and counts its calls in `context.fileselect.redraws`; `context.fileselect.close(path)` closes it as `fs.exit` does, from play mode `norns.menu.init()` and `redraw()`, then the callback with `path`, or `"cancel"` when nil; keys and encoders are not rerouted), `require("musicutil").note_num_to_freq`, `_path.audio` (`context.audio_dir`), `util.scandir`/`util.os_capture`, `_menu.rebuild_params`, `_menu.set_mode(mode)` (tracks `_menu.mode`; `set_mode(false)` records the play-mode routing from the globals, `_menu.key = key` and `norns.encoders.callback = enc`, as norns does; it swaps no handlers and draws nothing), `norns.menu.init()` (`_menu.set_mode(_menu.mode)`), `util.time()` (the clock's time: it moves with `clock.advance()`/`clock.run_for()`, and `context.set_time(seconds)` moves it too), the clock (`lua/core/clock.lua` over matron's scheduler, `clock_scheduler.cc` and `weaver.cc`): `clock.run` resumes the coroutine at once, so an error in its first part reaches the caller; `clock.sleep(s)` wakes at `util.time() + s` (negative counts as 0, a non-number raises); `clock.sync(beats, offset)` wakes at the next multiple of `beats` plus `offset` on the beat timeline (`clock.get_beats()`, one beat per `clock.get_beat_sec()` = 60 / `clock.get_tempo()`), with matron's `FLT_EPSILON` (2^-23) and counted from the coroutine's previous sync beat when its last wait was a sync, so a coroutine resumed a whole period late never skips a beat; `beats <= 0` raises. The `clock_tempo` action sets the clock's tempo (`clock.internal.set_tempo`), which keeps the current beat, and a waiting sync follows the new tempo. A resumed coroutine gets the clock time (sleep) or beat (sync) as the return value. A resumed coroutine gets the time or beat its tick posted it with: matron samples `clock_time` and `clock_beat` once per tick, so `clock.advance()` samples them at the step's start and every event of the step gets them (an overdue one too, and a tempo change by an earlier resume in the step cannot move them); `run_for` and `advance_until` fire each event at its own wake-up, so it gets the time or beat it waited for (or the one it was scheduled at, if later). The scheduler's events are in `clock.events[id]` (they outlive the wake-up, as matron's do, and go when the coroutine is cancelled or ends); every yield is logged in `clock.sleep_log` (`id, mode, amount, offset`). Each coroutine holds one of matron's 100 event slots (`clock.slots`): the lowest free one when it first waits, kept until it is cancelled or ends (all 100 in use is an error; matron would silently never wake it). Events due at the same time fire as matron's tick posts them: in slot order (not the order they were scheduled), and a sleep before a sync, since matron fires a sleep once the time reaches it (`>=`) and a sync once the beat is past it (`>`). Two ways to drive it: `clock.advance()` is one scheduler step, a matron tick: `util.time()` moves to the earliest wake-up (never back), the events due then are fixed before any runs, and they fire in slot order (a sleep due at the step's time leaves a sync due at that time to the next step, at the same time; with the frame clock running a step is usually a frame tick); `clock.advance_until(id)` runs the scheduler one event at a time until coroutine `id` wakes once, every clock due before it running first, and fails at once when `id` is not waiting ("nothing is pending" when no clock is) or another clock cancels it first. `test/run.lua` drives the script through it: `finish_startup(context)` runs the clocks for init's start-up sleep (`STARTUP.voice_delay_seconds`, 0.5 s; voice 2 starts), `next_frame(context)` runs them to the frame clock's next tick (one frame), `wake(context, name)` to the next wake of the clock in script local `name` (`"pattern_clock"`, `"scene_transition_clock"`) and `wake_buffer_clock(context, slot)` to a slot's recording timer or fallback; `clock.run_for(seconds, latency)` runs the scheduler for `seconds`, each coroutine `latency` (default 0) after its wake-up and never before `util.time()`, so a clock sleeping many short steps falls behind one long sleep, as on norns; `util.time()` ends at the start time plus `seconds`. An error raised while the scheduler resumes a coroutine is not raised (norns prints it through `l_report` and keeps every other clock running; the coroutine stays dead in `clock.threads`, as norns never cancels it): the stub records it, `context.clock.take_errors()` claims the recorded errors, and the harness fails any test that leaves one unclaimed, so an error cannot pass silently (`run_test` in `test/run.lua`; a test that fails anyway gets them added to its own error). A coroutine that cancels itself and then sleeps errors when it wakes (norns resumes the coroutine it no longer has). `clock.cancel` needs an integer id. clock.add_params' own three clocks (crow out, MIDI clock out, external tempo) are not run, `screen.line`/`screen.rect` recorded in `context.screen.lines` (`x1, y1, x2, y2, level`) and `context.screen.rects` (`x, y, w, h, level`) beside the texts, and `norns.enc.accel`/`sens` (state in `context.encoders.accel`/`sens`, starting at norns' script defaults accel on / sens 2; `context.encoders.deliver(n, delta, interval)` delivers one hardware encoder event the way `encoders.process_with_accel` does, with `interval` seconds since the previous one).

**On hardware** - since this runs on norns hardware (or norns shield/fates):
- Use maiden (norns web IDE at `http://norns.local/maiden`) to edit files and view console output
- The maiden REPL is useful for testing Lua code
- SuperCollider changes require script restart
- Watch for errors in the maiden console (bottom panel)
