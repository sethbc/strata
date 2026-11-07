## Must not break

- Each `lib/arc/<page>.lua` sets only the arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`) on `S.registry.pages[UI_PAGES.index.<PAGE>]`, never another field of the record (the page file owns those, `arc_button` included; a test checks both).
- Every continuous ring sweeps its param's whole range in `UI_PAGES.ARC_TICKS_PER_SWEEP` (512) ticks through `arc_sweep_param`. Never give a ring its own scale. The only exceptions are the LFO page's whole-value rings (depth at 10 ticks per percent, clocked rate at 20 ticks per rate), which carry their spare ticks through `arc_whole_steps("lfo:<ring>", ...)`.
- Every ring is drawn through `arc_ring_fill` from `param_fraction(id)`, or `arc_ring_fill_bipolar` for a range through 0 (`arc_ring_fill_param` picks), so a changed param range moves the ring (a test swaps the controlspec to check).
- LFO ring 4's carried ticks are forgotten when the selected LFO or its mode changes (`forget_arc_lfo_period_ticks()`), so they never step another LFO or mode.

## Owns

- `lib/arc/main.lua`, `lib/arc/voice.lua`, `lib/arc/seq.lua`, `lib/arc/fx.lua`, `lib/arc/lfo.lua`, `lib/arc/buffer.lua`, `lib/arc/scenes.lua` (`S.lib.arc_main`, ...): each page's rings. `strata.lua` includes them after every page file. VOICE, SEQ and SCENES are stubs for now: their rings stay dark and ignore turns. SETUP has no arc file (no ring fields on its record).
- `ARC_FX_RINGS` (`lib/arc/fx.lua`), `ARC_BUFFER_RINGS` (`lib/arc/buffer.lua`), `ARC_LFO` (`lib/arc/lfo.lua`).
- Unit tests: `test/unit/arc_pages_test.lua`. The dispatch, fills and button are `lib/arc/core.lua`'s (`docs/notes/lua/arc-core.md`).

## Rings per page

MAIN uses `arc_main_delta`/`arc_main_redraw`, FX `arc_fx_delta`/`arc_fx_redraw`, LFO `arc_lfo_delta`/`arc_lfo_redraw`, BUFFER `arc_buffer_delta`/`arc_buffer_redraw`. VOICE, SEQ and SCENES have stub rings that draw nothing and ignore turns. No page has ALT rings yet.

Every continuous ring (MAIN 1-4, FX 1-4, BUFFER 1-4, LFO ring 4 in free mode) goes through `arc_sweep_param(param_id, delta)`.

MAIN:
- Ring 1: master density.
- Ring 2: the selected voice's main parameter (`main_param_id`; `buf_pos` for a buffer-sourced voice, `grain_size` for an input-sourced one).
- Ring 3: the selected voice's grain size.
- Ring 4: the selected voice's grain density.
- The button is MAIN's `arc_button` (`start_or_lock_selected_voice`, set by `lib/pages/main.lua`).

FX (`ARC_FX_RINGS`, `{param_id}` per ring):
- ring 1 `filter_freq`, ring 2 `filter_res`, ring 3 `delay_time`, ring 4 `delay_mix`;
- each drawn at level 12 to `param_fraction(param_id)` of a turn, so the exp params (filter freq, delay time) follow their controlspec warp.

BUFFER (`ARC_BUFFER_RINGS`, `{voice_key | param_id}` per ring):
- ring 1 `v<selected>_buf_pos`, ring 2 `v<selected>_buf_rate`, ring 3 `record_duration`, ring 4 `record_level`, each drawn to `param_fraction` of a turn;
- rings 1-2 adjust the voice's buffer params whatever its source (they apply once it switches to a buffer), drawn at 15 for a buffer-sourced voice, 4 otherwise;
- rings 3-4 at 12.

LFO:
- Rings 1-3: `lfo_depth_1..3` in whole percents. `arc_whole_steps("lfo:<ring>", ...)` accumulates `ARC_LFO.ticks_per_percent` = 10 ticks per percent per ring, keeping the remainder, so the number param never holds a fraction.
- Ring 4 (`ARC_LFO.period_ring`): the period of `S.selected_lfo` (`lfo_period_param_id`):
  - free mode: `lfo_free_<n>` through `arc_sweep_param`;
  - clocked mode: `lfo_clocked_<n>`, one option per `ARC_LFO.ticks_per_rate` = 20 ticks.
- Ring 4's carried remainder (`S.arc_ticks["lfo:4"]`) belongs to one LFO's clocked rate.
  - `forget_arc_lfo_period_ticks()` (`forget_arc_ticks("lfo:4")`) clears it when `S.selected_lfo` changes (`lfo_enc` E2) and when the selected LFO's `lfo_mode_<n>` changes (a `wrap_param_action` after-hook added in `add_lfo_params`), so it never steps another LFO or mode.
  - The depth rings keep theirs (until the page changes, which forgets every carry).

## LED feedback

- Every ring, MAIN 1-4 included, is drawn to `param_fraction(id)` of a turn (controlspec warp).
- MAIN brightness shows the voice state:
  - 15: active voice, primary parameter;
  - 12: active voice, secondary parameters;
  - 4: inactive voice, primary parameter;
  - 3: inactive voice, secondary parameters.
- FX rings at 12. BUFFER rings 1-2 at 15 (buffer source) or 4, rings 3-4 at 12. LFO depth rings at 15 (running) or 4, ring 4 at 12.
