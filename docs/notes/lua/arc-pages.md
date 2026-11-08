## Must not break

- Each `lib/arc/<page>.lua` sets only the arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`) on `S.registry.pages[UI_PAGES.index.<PAGE>]`, never another field of the record (the page file owns those, `arc_button` included; tests check both). Avoid page field names (`key`, `name`, `enter`, ...) as keys in a ring file's own tables: the ownership tests read every `<field> =` in the file. A second test watches the includes as the script loads: each page file sets no arc field, and each arc file sets only arc fields, only on its own page's record (which exists before it loads), and removes none (`test/unit/ui_pages_test.lua`).
- Every ring is drawn through `arc_ring_fill` or `arc_ring_fill_bipolar`. A ring showing a param draws from `param_fraction(id)` (`arc_ring_fill_param` picks the bipolar fill for a range through 0), so a changed param range moves the ring (a test swaps the controlspec to check). A ring showing a cursor or a step level draws exactly these fractions:
  - SEQ ring 1: `(S.cursors.seq_step - 1) / (PATTERN_LENGTH - 1)`;
  - SEQ ring 2: `S.patterns[S.selected_voice][step] / MAX_STEP_LEVEL`;
  - SEQ ring 4: `(S.selected_voice - 1) / (NUM_VOICES - 1)`;
  - SCENES ring 1: `(S.cursors.scene - 1) / (NUM_SCENES + #SCENES_FIELDS - 1)`.
- Every continuous ring sweeps its control param's whole range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512) ticks through `arc_sweep_param`. Never give a ring its own scale. The only exceptions step whole values through `arc_whole_steps(key, delta, ticks)` and then `delta_with_detent(id, steps)` (or move a cursor):
  - LFO: depth 10 ticks per percent, clocked rate 20 ticks per rate (`"lfo:<ring>"`);
  - VOICE: option and number rows 20 ticks per step (`"voice:<ring>"`); a binary row (a registered param, kind `"binary"`) steps the same way as a two-value option, set with `params:set` (a step up on, a step down off), and its ring is drawn with `arc_ring_fill` from its value (dark off, whole ring on);
  - SEQ: 10 ticks per step, 10 per level, 10 per BPM, 20 per voice (`"seq:<ring>"`);
  - SCENES: ring 1 10 ticks per stop (`"scenes:1"`).
- Carried ticks belong to what they were turned on: LFO ring 4's are forgotten when the selected LFO or its mode changes (`forget_arc_lfo_period_ticks()`), a VOICE ring's when the ring's row is another param, SEQ ring 2's when the cursor's voice or step changes. They never step another param, LFO or step.
- VOICE's rings read the cursor only from `S.lib.ui_cursors.sync("voice")` (the cursor module's re-anchoring, which returns `rows, cursor`), in `arc_delta` and `arc_redraw` alike, never `S.cursors.voice` raw (after a source switch the raw cursor can sit past the last row or on a section label) and never through the VOICE page module (a test checks). Tests place the cursor with `S.lib.pages_voice.place_cursor(index)`, the page's name for `S.lib.ui_cursors.place("voice", index)`.
- Rings past the VOICE group's last row, MAIN's ALT pan ring for Sub and SCENES rings 3-4 are dark (no segment, no LED) and ignore turns.
- SCENES ring 1 moves the cursor only through `S.lib.pages_scenes.move_cursor(slot)`, the page's own move (E2 uses it too), which disarms a pending overwrite confirmation and clears its prompt. The ring never touches `S.scenes_page` itself.

## Owns

- `lib/arc/main.lua`, `lib/arc/voice.lua`, `lib/arc/seq.lua`, `lib/arc/fx.lua`, `lib/arc/lfo.lua`, `lib/arc/buffer.lua`, `lib/arc/scenes.lua` (`S.lib.arc_main`, ...): each page's rings. `strata.lua` includes them after every page file. SETUP has no arc file (no ring fields on its record).
- `ARC_MAIN_ALT_KEYS` and `ARC_MAIN_LEVELS` (`lib/arc/main.lua`), `ARC_VOICE` (`lib/arc/voice.lua`), `ARC_SEQ` (`lib/arc/seq.lua`), `ARC_FX_RINGS` (`lib/arc/fx.lua`), `ARC_LFO` (`lib/arc/lfo.lua`), `ARC_BUFFER_RINGS` (`lib/arc/buffer.lua`), `ARC_SCENES` (`lib/arc/scenes.lua`).
- Unit tests: `test/unit/arc_pages_test.lua`. The dispatch, fills, carried ticks and button are `lib/arc/core.lua`'s (`docs/notes/lua/arc-core.md`).

## Rings per page

MAIN (`arc_main_delta`/`arc_main_redraw`, with ALT `arc_main_alt_delta`/`arc_main_alt_redraw`):
- Ring 1: master density.
- Ring 2: the selected voice's main parameter (`main_param_id`; `buf_pos` for a buffer-sourced voice, `grain_size` for an input-sourced one).
- Ring 3: the selected voice's grain size; grain pitch for an input-sourced voice (neither `voice_uses_synth` nor `voice_uses_buffer`), whose ring 2 already is grain size. This is MAIN's third field for that voice.
- Ring 4: the selected voice's grain density.
- ALT (`ARC_MAIN_ALT_KEYS`): grain pitch, grain spread, level (`amp`), pan. Sub has no pan (`S.voices[i].params.pan == nil`): its ring 4 is dark and ignores turns.
- Every ring, plain and ALT, sweeps through `arc_sweep_param` and draws through `arc_ring_fill_param` (pan bipolar).
- The button is MAIN's `arc_button` (`start_stop_selected_voice`, set by `lib/pages/main.lua`: K3, start or stop the selected voice).

VOICE (`arc_voice_delta`/`arc_voice_redraw`):
- `voice_page_group(voice_page_rows(S.selected_voice), S.cursors.voice)` gives up to four row indices; ring n edits the n-th. Control rows sweep (`arc_sweep_param`), option and number rows (grain envelope and mode, the mod sources, the source) step one whole value per `ARC_VOICE.ticks_per_step` (20) ticks, under `"voice:<n>"`. A local `carried_param[n]` remembers the param ring n's ticks were turned on and forgets them (`forget_arc_ticks`) when the row is another param (the cursor's group or the selected voice changed).
- Drawn through `arc_ring_fill_param`: the cursor row's ring at 15, the others at 12; rings past the group's rows dark. A binary row's ring is `arc_ring_fill(port, n, value, level)`: a binary param has no range for `param_fraction`.
- Registered rows (`S.registry.voice_params`, `docs/notes/lua/ui/field-list-and-cursors.md`) reach the rings through `voice_page_rows`, with nothing to add here.

SEQ (`arc_seq_delta`/`arc_seq_redraw`, `ARC_SEQ`):
- Ring 1: the step cursor, `S.lib.ui_cursors.move("seq_step", steps)` (clamped at 1 and `PATTERN_LENGTH`).
- Ring 2: the cursor step's level on the selected voice's pattern (`S.patterns[v][step]`, clamped to 0..`MAX_STEP_LEVEL`), written directly as the SEQ page's E3 does, then `grid_redraw()`. The carry is forgotten when the target `"<voice>:<step>"` changes.
- Ring 3: `tempo` (a number param), `delta_with_detent("tempo", steps)`.
- Ring 4: the voice row, `S.lib.ui_keys.select_voice_by(steps)` (as ALT+E2 on SEQ and E2 on MAIN: the voice list and an omni pitchbend follow).
- Rings 1-2 at 15, rings 3-4 at 12. Ring 1 at step 1, ring 2 at level 0 and ring 4 at voice 1 light nothing (fraction 0).

FX (`ARC_FX_RINGS`, `{param_id}` per ring):
- ring 1 `filter_freq`, ring 2 `filter_res`, ring 3 `delay_time`, ring 4 `delay_mix`;
- each drawn at level 12 to `param_fraction(param_id)` of a turn, so the exp params (filter freq, delay time) follow their controlspec warp.

LFO:
- Rings 1-3: `lfo_depth_1..3` in whole percents. `arc_whole_steps("lfo:<ring>", ...)` accumulates `ARC_LFO.ticks_per_percent` = 10 ticks per percent per ring, keeping the remainder, so the number param never holds a fraction.
- Ring 4 (`ARC_LFO.period_ring`): the period of `S.selected_lfo` (`lfo_period_param_id`):
  - free mode: `lfo_free_<n>` through `arc_sweep_param`;
  - clocked mode: `lfo_clocked_<n>`, one option per `ARC_LFO.ticks_per_rate` = 20 ticks.
- Ring 4's carried remainder (`S.arc_ticks["lfo:4"]`) belongs to one LFO's clocked rate.
  - `forget_arc_lfo_period_ticks()` (`forget_arc_ticks("lfo:4")`) clears it when `S.selected_lfo` changes and when the selected LFO's `lfo_mode_<n>` changes (a `wrap_param_action` after-hook added in `add_lfo_params`), so it never steps another LFO or mode.
  - The depth rings keep theirs (until the page changes, which forgets every carry).

BUFFER (`ARC_BUFFER_RINGS`, `{voice_key | param_id}` per ring):
- ring 1 `v<selected>_buf_pos`, ring 2 `v<selected>_buf_rate`, ring 3 `record_duration`, ring 4 `record_level`, each drawn to `param_fraction` of a turn;
- rings 1-2 adjust the voice's buffer params whatever its source (they apply once it switches to a buffer), drawn at 15 for a buffer-sourced voice, 4 otherwise;
- rings 3-4 at 12.

SCENES (`arc_scenes_delta`/`arc_scenes_redraw`, `ARC_SCENES`):
- Ring 1: the scene cursor over E2's stops (slots 1..`NUM_SCENES`, then `SCENES_FIELDS`), `S.lib.pages_scenes.move_cursor(S.cursors.scene + steps)`, `ARC_SCENES.ticks_per_stop` (10) ticks a stop under `"scenes:1"`. `move_cursor` disarms the overwrite confirmation and clears its prompt, as E2 does (`docs/notes/lua/pages/scenes.md`).
- Ring 2: `scene_transition_time` through `arc_sweep_param`.
- Rings 3-4 dark (3.4's morph will take ring 3). Both lit rings at 12.

SETUP: no rings.

## LED feedback

- MAIN brightness shows the voice state (`ARC_MAIN_LEVELS`):
  - ring 1 (density): 15 always;
  - ring 2 (the main param): 15 active, 4 stopped;
  - rings 3-4 and every ALT ring: 12 active, 3 stopped.
- VOICE: the cursor row's ring 15, the others 12. SEQ: rings 1-2 at 15, 3-4 at 12. SCENES at 12.
- FX rings at 12. BUFFER rings 1-2 at 15 (buffer source) or 4, rings 3-4 at 12. LFO depth rings at 15 (running) or 4, ring 4 at 12.
