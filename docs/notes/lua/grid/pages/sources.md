## Must not break

- **Every source is set through its param**: a key calls `S.lib.grid_core.source_key(v, option)` (`params:set("v<v>_source", option)`, checked against 1..`#SOURCE_OPTIONS`), and `in` on the input sets `v<v>_input_channel`; the params' actions do the engine's switch (`setGrainSource`, the channel's `inputChannel` grain param) and the page sends no engine command.
- **Every source number comes from the constants** (ruling D4): the own column toggles `SOURCE_SYNTH` and `SOURCE_VOICE_FIRST + v - 1`, another voice's column is `SOURCE_VOICE_FIRST + x - 1`, `in` is `SOURCE_INPUT`, slot `x - 8` is `SOURCE_SYNTH + x - 8`; the channel steps over the param's own options (`channel % count + 1`). Every level and the blink's half period are `SOURCES_PAGE`'s.
- **The blink costs nothing while no voice reads itself**: `signature(pane)` carries the blink's phase (`math.floor(util.time() / blink_seconds) % 2`) only while some voice's source is its own output, and `-` otherwise, so the drift tick's follow (`S.lib.grid_faders.follow_faders`, 10 Hz) repaints no grid for it then; while one does, each phase change repaints within a tick (0.1 s).
- **What redraws the page comes from elsewhere**, and the page adds no hook: the source param's action (`lib/voices.lua`, also during a scene recall, which redraws again at its end), `toggle_voice` and the sequencer's beat (`finish_beat`) for a read voice's running, `buffer_display_changed` (a load, a record param, a clear, a failure) and the `bufferState` poll's gate (`any_page(GRID_PAGES.sources)`) for the slots, and `grid_key` after a press. Only the input channel's param redraws no grid: the signature carries each voice's channel.
- **Index checks**: a press needs z 1, a whole x in 1-16 and a whole y in 1..`NUM_VOICES`; anything else does nothing. The page keeps no state (no `pane.state()`).

## Owns

- `lib/grid/pages/sources.lua` (`S.lib.grid_pages_sources`): its record (`M.record`, one side, a `signature`, no fader lines), registered at `GRID_PAGES.sources`, and `M.SOURCES_PAGE` (`input_column` 8, `slot_column` 8, `blink_seconds` 0.5, `levels`).
- Unit tests: `test/unit/grid_pages_sources_test.lua`, on every arrangement of the pane harness that shows the keys each test needs, with the five sources tests 0e handed on (the 256's, 128h's and 128v's sources parts) as "sources set and light".

## Keys and LEDs (design §10.6)

Line v is voice v (1-7); a press acts at its press, a release does nothing.

| x | Press | LED |
|---|---|---|
| v (own) | not the synth: the synth; the synth: its own output (`SOURCE_VOICE_FIRST + v - 1`) | 15 the synth; its own output blinks 15 / 6 (0.5 s each); else 4 |
| 1-7, not v | `SOURCE_VOICE_FIRST + x - 1` (reads voice x) | 15 selected; else 4 voice x running, 2 stopped |
| 8 `in` | not the input: `SOURCE_INPUT` (the channel kept); the input: the next channel (stereo, left, right) | selected: 15 stereo, 11 left, 7 right; else 4 |
| 9-16 | slot `x - 8` (`SOURCE_SYNTH + x - 8`) | 15 selected; else 2 free (`S.lib.buffers.is_free`), 4 holding audio (or loading or recording: not free) |

A slot cleared while a voice reads it keeps that voice's source (and key at 15); its key on the other lines goes to 2 at once.

`grid_core.source_level` (options 1-10, 3.7's) is not used: it gives an input or voice option a slot's free level.

Turned (the 128v), each voice's keys run down its column. On a 64 the left half (x 1-8) holds the voices and `in`, the right half (x 9-16) the slots. Both panes of a 256 can show the page; it has no per-port state, so they show the same.
