## Must not break

- **`S.lib.expression` sends no engine command itself** (design §6): a note's values reach the engine only through `S.lib.notes.set_expression` (the allocator's flush sends them); a voice-wide value only as an offset beside the matrix's, through `S.lib.matrix.set_fast_extra("expression", id, m)` (cutoff, a synth voice's size) or `S.lib.engine_sync.set_extra_offset("expression", "v<i>_grain_density", offset)` with a send in the LFOs' round robin (`S.lib.lfos.mark_due`). Never `setGrainParam`, `setFastOffset`, `noteExpression` or a `params:set` of a destination: a mapping moves the sound around the stored value and never changes it.
- **Nothing changes until a controller sends pressure or slide** (3.4's sound): a nil pressure leaves every target as stored (`level` too), a note's first slide is its reference, so its first `update` gives slide 0, and at the defaults (pressure on `amp` at 100 %, slide on `main` at 50 %) zero pressure and slide are the neutral values. A record starts with the neutral values as sent, and `set_expression` is called only when a note's values differ from those last handed over, so a plain note with no expression sends nothing beyond 3.4's messages.
- **The targets' option order is stored** in scenes and PSETs (`EXPRESSION.targets`: `off`, `amp`, `level`, `main`, `size`, `density`, `position`, `cutoff`): never reorder it; a later target is appended.
- **`update` and `latch` act only on a note the allocator holds** (`S.lib.notes.find`); a latched note's later updates change nothing; the step hook forgets a note the allocator no longer holds, so nothing has to say a note ended; `forget` starts a new touch of a note the allocator may still hold.
- **The step hook is registered at include time**: it runs after the LFOs and the matrix's step (`lib/matrix.lua` is included earlier) and before the allocator's flush (registered from its start step), so the flush sends in the same step what the hook marked, and a fast extra reaches the engine at the matrix's next step.
- A source's `value`, `describe` and `visible` never send or yield, and count only notes the allocator holds (`docs/notes/lua/mod-sources.md`).
- The four params are registered voice params (`docs/notes/lua/params.md`): scene keys (the targets discrete, the depths within -100..100), with a migration for scenes older than format 7 that only fills what is missing; PSET params; never MAIN's randomize, the mutations or the 256 fader pages; VOICE's ALT+K2 on the `notes` section draws the four.

## Owns

`lib/expression.lua` (`S.lib.expression`, 3.5 package 2c, design §6), included after `lib/input_level.lua` and `lib/mpe.lua`, with its table `EXPRESSION` (`M.EXPRESSION`): `targets` (the option list above), `mappings` (pressure's and slide's param keys, the controller value each reads, their names and defaults: `press_target` `amp`, `press_depth` 100, `slide_target` `main`, `slide_depth` 50), `depth_range` (-100..100), `gain_range` (0-2), `offset_range` (-1..1), `section` (`notes`, VOICE's, before `variation`), `extra_key` (`"expression"`), `wide_params` (`cutoff` `filter_freq`, `size` `grain_size`, `density` `grain_density`), `sources` (the section `notes` and the names) and `scene_format` (7).

### The params (design §6.1)

Per voice, the record `expression` (registered after the allocator's `notes`, so its rows follow `note cap` in VOICE's `notes` section): `v<i>_press_target` and `v<i>_slide_target` (option, the eight targets; `amp` and `main`; names `press target`, `slide target`) and `v<i>_press_depth` and `v<i>_slide_depth` (control -100..100 %, step 1, shown signed as the matrix's depths, `+100%`; 100 and 50). No grain keys: nothing is sent when they change; the step hook applies a new target or depth to the held notes at the next step. Scene keys with their defaults, the targets `discrete` (`{1, 8}`), the depths in `scene_ranges` (-100..100). `randomize`: a target among those the voice offers but `off`, and a whole depth across -100..100. A layout state per voice (`v<i> expression <source> <row>`), each voice on a source in turn (synth, buffer, input), its targets at their widest choices and its depths at -100 %, the cursor on `press target` and on `slide depth`.

`position` is a choice for a buffer voice only: a param filter on both target keys steps a turn of another voice's target over it, on in the turn's direction (`S.turning_param`: VOICE's E3 and every `delta_with_detent`). A set (a scene, a PSET, the PARAMS menu, whose own delta is no turn for a registered param) keeps it, and it acts as off there (below).

### A note's values (design §6.2, §6.3)

`note_values(voice, raw) -> {bend, amp, position, size, main}` (nil for a voice outside 1..`NUM_VOICES`), from `raw = {bend, pressure, slide}`: `bend` a ratio (anything not finite is 1; clipped to the allocator's 0.0625-16), `pressure` 0-1 (nil: none yet), `slide` already relative to the touch's start, -1..1 (nil is 0). For each mapping with a value, its target, by where it acts on the voice now:

| Target | Synth voice | Frozen synth voice | Buffer voice | Input voice |
|---|---|---|---|---|
| `amp`, `level` | the note's `amp` | the note's `amp` | the note's `amp` | the note's `amp` |
| `main` | the note's `main` | nothing | the note's `position` | the note's `size` |
| `size` | the voice's grain size | the note's `size` | the note's `size` | the note's `size` |
| `position` | nothing | nothing | the note's `position` | nothing |
| `density`, `cutoff` | the voice | the voice | the voice | the voice |

- `amp`: a gain of `1 + depth × value`. `level`: `1 - depth × (1 - value)` for a depth above 0, `1 + depth × value` below; with no pressure yet it is neutral (a nil pressure contributes nothing to any target). Each gain is clipped 0-2, the gains on a note multiply, and the product is clipped 0-2.
- Every other target: an offset of `depth × value` half ranges, clipped -1..1; offsets on one key add, and the sum is clipped -1..1.
- A frozen synth voice's notes are streams of its frozen ring, so `size` acts per note there and `main`, the voice synths' control the ring no longer hears, does nothing.
- The voice-wide targets leave the note's values neutral; `note_values` returns only the note's.

### Held notes

Per voice the module keeps a record per held note it was told about: `{owner, key, bend, pressure, peak, slide, reference, latched, values}`.
- `update(voice, owner, key, raw) -> boolean`: raw is the controller's: `bend` a ratio, `pressure` 0-1, `slide` absolute 0-1; each nil keeps the note's last. The first `update` of a note takes its slide as the reference (`reference`), so its first call gives slide 0: the MIDI package gives a note's first expression with `note_values(voice, {bend, pressure, slide = 0})` before `S.lib.notes.play`, then calls `update` once the note is held, and the two agree. `peak` is the highest pressure of the touch. The note's values (from `bend`, `pressure` and `slide - reference`) go to `S.lib.notes.set_expression(voice, slot, values)` when they differ from those last handed over (`values`, neutral at first). false, keeping nothing, for a note the allocator does not hold (`find` is nil), a latched note or a bad argument.
- `latch(voice, owner, key) -> boolean` (the MIDI package's note off in latch mode): the note's pressure becomes `peak` and its slide stays; later `update`s change nothing. false for a note the allocator does not hold.
- `forget(voice, owner, key)`: the record goes, so the next `update` starts a new touch (a new reference, peak and latch). The MIDI package calls it at each note on, before the note's `update`: the allocator keeps a re-pressed key's note in its slot (its branch 1), or releases and replays it within one handler (latch's `release_owner`), and neither leaves a step between for the hook below to see the note end.

### The step (design §6.3, §6.4, Question 3)

A hook of the LFO clock (`S.lib.lfos.on_step`, at include time). Per voice with records or a voice-wide value held: each record whose note the allocator no longer holds is dropped; each held note's values are worked out again and handed over when they changed (a mapping, the source or the freeze changed them); and each voice-wide target takes, among the voice's held notes, the value furthest from 0 (the strongest finger, whatever the depth's sign; the first of a tie), 0 or none clearing it:
- `cutoff` and a synth voice's `size`: `S.lib.matrix.set_fast_extra("expression", "v<i>_filter_freq" | "v<i>_grain_size", m)`, which the matrix's next step sums with its own routings and sends as `setFastOffset` (the cutoff by `cutoff_ratio` per half range, the size by its half range, `docs/notes/lua/lfos.md`); nil clears it.
- `density`: `S.lib.engine_sync.set_extra_offset("expression", "v<i>_grain_density", m × half its range)` (49.5 per unit), then the param sent with every offset in the LFOs' round robin (`mark_due` under the param's id, so one send carries the LFOs', the matrix's and this module's layers) when it was set or cleared, or moved by `LFO.send_threshold` of the range since the last mark.

### The sources (design §6.5, Question 11)

Sixteen read-only sources in the section `notes` (after `audio`, the input level's), range 0..1, `describe` a percent, no `row`: `pressure` (`PRES`) and `slide` (`SLID`), the largest pressure and absolute slide (as the controller sends it) among the held notes of every voice, then `pressure1`..`pressure7` (`PR1`..`PR7`) and `slide1`..`slide7` (`SL1`..`SL7`), each voice's; 0 with none. A latched note counts with its kept pressure. The per-voice ones are `visible` while their voice holds a note that has sent pressure or slide; MOD's routing view offers all sixteen.

### Registrations

The record `expression` (above), the param filters `press_target` and `slide_target`, the step hook, the sixteen sources and the scene migration `expression` (`before_version` 7: every voice of a populated scene gets the four defaults it lacks in its `extras`, made when missing; idempotent). `SCENE_DATA_VERSION` is 7 from this package (`docs/notes/lua/scenes.md`). No start or cleanup step: the hook runs with the LFO clock, and the extras it holds live in `S`, which every load builds fresh.

Tests: `test/unit/expression_test.lua` (each formula and clip; slide from the touch's first value, and a first update that sends nothing; `main` by source; two mappings on a target; the voice-wide largest, a negative depth's strongest finger and the clear; size voice-wide on a synth voice and per note on a buffer voice; density's extra offset and its sends; a frozen synth voice; latch and `forget`; a note the allocator no longer holds; a mapping's change reaching held notes; the sources and their visibility; the migration and a format 6 file; the rows after `note cap`, E3 over `position` and the randomize's draws). `test/unit/scenes_test.lua` checks the format 6 to 7 step.
