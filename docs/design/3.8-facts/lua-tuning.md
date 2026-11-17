# 3.8 facts: microtuning and a scale editor (Lua and the engine's quantize)

Read against `main` at 59a0a0c1: the Lua notes and code this area touches, `lib/engine/StrataScale.sc`, `StrataVariation.sc`, `StrataNotes.sc`, `StrataGrainDefs.sc`, `StrataVoiceDefs.sc`, `StrataModulation.sc`, every note target under `lib/io/`, norns' `lua/lib/musicutil.lua`, `intonation.lua` and `fileselect.lua` (~/src/norns at v3.0.2-autotest-7-g227aa044), and SuperCollider's `Index` family at `Version-3.13.0`. I ran `lua test/run.lua variation_test` (26 tests, 0 failures) and `notes_test` (54, 0 failures); nothing else was run and nothing was checked on a device. Figures are **quoted** with their source or marked **(est.)**; the Scala format is **from memory** (no network). Line numbers are `main`'s; where the groundwork renames something, I say so (`S.voices[i].extras.x` and `.params.freq` become `S.voices[i].values.x`; `add_voice_extra` becomes `add_voice_param`).

## 0. The facts most likely to change the design

1. **Strata already carries pitch as a continuous log-frequency everywhere downstream of the entry points.** A "pitch" is a fractional MIDI note (12 units per octave, 69 = 440 Hz): `S.lib.notes.play`'s `pitch`, `note_values` (`lib/notes.lua:352-361`), the own setters (`lib/midi_in.lua:486-495`), the step chord (`lib/sequencer.lua:495-511`), the targets' `pitch` and `volts` (`lib/io/targets.lua:41-43`), `scaleNote` and `rootNote`, the engine's `ratiomidi`/`midiratio` math. None of these assumes twelve *steps*; they assume only that a pitch is `69 + 12 log2(f / 440)`. A tuning that turns a key or a degree into such a pitch leaves all of them unchanged.
2. **The twelve-step structure lives in exactly five places**: the MIDI key taken as the pitch (`lib/midi_in.lua:525`, identity but for the snap), the scale snap and mask (`lib/variation.lua:60-84, 170-220`), the step degrees (`lib/sequencer.lua:426-443`), the chord interval set (`lib/variation.lua:131-139`, `musicutil.generate_scale`), and the engine's quantize (`StrataScale.sc:100-106, 135-139`, a 12-frame table indexed by `round(n) % 12`). Plus two outputs that round to whole notes: MIDI out (`lib/io/midi_out.lua:283`) and nb (`lib/io/nb.lua:202`).
3. **`note_values` is not "the one place" a tuning would change** (notes.md:13 and `lib/notes.lua:351` say it is). The own note is pitched by `own_setters` in `lib/midi_in.lua:486-495` and by the step's override values in `lib/sequencer.lua:504`, and the synth voice's freq then passes the `freq` filter (`lib/variation.lua:202-221`), which re-snaps it to a 12-step scale tone when quantize is on. And `note_values` itself needs no change at all if the pitch it gets is already tuned.
4. **A 12-note, octave-period tuning needs no SynthDef change.** The engine's quantize is `q(n) = round(n) + scaleBuffer[round(n) mod 12]` (`StrataScale.sc:135-139`) and the buffer holds whole offsets (-6..6) today (`StrataScale.sc:100-106`). If the 12 frames held fractional offsets (the step to the nearest allowed class plus that tone's cents deviation from 12-ET), every grain would land on the tuned tone with the same UGens. The cost is a new or widened command (12 floats; `setScale` is `"ii"`) and the sclang `scaleOffsets` rewrite.
5. **Any tuning (any note count, any period) fits one table lookup of no more UGens than today.** A table over absolute pitch (frame = the nearest allowed tone as a fractional note, at a fixed resolution) makes the quantize `Index.ar(buf, (n * res + offset).round)`: three UGens against today's `round`, `%`, `Index`, `+` (est.). `Index` truncates and clips its index (`server/plugins/OscUGens.cpp:649-658` at 3.13.0), so the range needs a margin, not a wrap. The table lives in a `Buffer` (RAM, not the real-time pool), allocated once so its bufnum stays constant (`docs/notes/engine/variation.md:8`). The open cost is filling it: matron commands carry fixed scalar arguments, so the tones reach the engine as many messages, a string, or a file.
6. **The scale is stored by index into norns' list, in PSETs and in scenes.** `scale` is an option over `off` + `musicutil.SCALES` names (`lib/variation.lua:39-43, 379`), saved by index; it is a scene global (`lib/variation.lua:396`), and scene globals must be numbers (`lib/scenes.lua:1211`). A string (a tuning's name or path) can't be a scene global: it needs a scene block (`S.register_scene_block`, `lib/state.lua:405-412`) or a numeric index. A "custom" scale entry inserted anywhere but at the end shifts every saved index.
7. **The PSET order constraint (#125) binds a tuning too.** norns reads a PSET in param order and runs each action as it goes; the `freq` filter snaps by whatever scale is in force when the voice's freq arrives (`docs/notes/lua/variation.md:29`). So a tuning param must sit with `scale` and `root`, before every voice (`lib/params_setup.lua:732`), and its action must parse and apply the tuning synchronously.
8. **Turning a quantized freq skips tones in a dense tuning.** One encoder detent is 0.8 semitone of raw travel (quoted, `docs/notes/lua/variation.md:4`; `quantum` 0.01 of the 20-2000 Hz exp range, `lib/ui/detent.lua:90`). With steps under 0.8 st (24-EDO, 31-EDO, Partch's 43) the shadow-note rule lands on every other tone. The arc's 0.16 st tick and ALT+E3's fine turn still reach each tone.
9. **External targets.** crow, Just Friends, W/syn, ER-301 and TELEXo take volts from the fractional pitch (`lib/io/targets.lua:41-43`), so a microtuned pitch reaches them as it is. MIDI out sends `round(pitch)` (`lib/io/midi_out.lua:283`), so plain mode loses the cents; MPE mode could fold the remainder into the note's own bend (`lib/io/midi_out.lua:144-148`). nb rounds before `note_on` (`lib/io/nb.lua:202`).
10. **norns ships no tuning reader.** `intonation.lua` is eight functions that return ratio tables (five 12-tone, Zarlino's 16, Partch's 43, a 168-tone gamut; no period, no reference, no keyboard map). `musicutil.note_num_to_freq` is 12-ET at 440 (`musicutil.lua:639-641`). There is no `.scl` or `.kbm` parser in `~/src/norns/lua`. Strata would write its own, and it must never run the file's text.

## 1. Every place a note becomes a frequency or a rate, in Lua

"Pitch" below means a fractional MIDI note in 12-ET units. **Log** marks math that holds for any tuning once its input pitch is tuned; **12-step** marks math that assumes twelve steps to the octave.

| Site | In | Formula | Out, to whom | Kind |
|---|---|---|---|---|
| `lib/params_setup.lua:1199` `VOICE_PARAM_SPECS.freq` | | 20-2000 Hz, exp, step 0 ("MIDI notes keep exact pitch") | the `v<i>_freq` param (Hz) | none |
| `lib/variation.lua:86-87` `freq_to_note`, `note_to_freq` | Hz / pitch | `69 + 12 log2(f/440)`; `musicutil.note_num_to_freq` (`13.75 * 2^((n-9)/12)`, musicutil.lua:639-641) | local | log |
| `lib/variation.lua:60-67` `scale_mask` | the `scale` param (index) | bits `interval % 12` of `musicutil.SCALES[i].intervals` | 12-bit mask | 12-step |
| `lib/variation.lua:70-84` `is_tone`, `snap_note` | pitch | the nearest whole note whose `(note - root) % 12` bit is set, a tie going down | a whole note | 12-step |
| `lib/variation.lua:170-183` `tone_freq` | voice, pitch | `snap_note`, then whole-note steps to stay in range | Hz | 12-step |
| `lib/variation.lua:202-221` `freq_filter` (the shadow note) | every set of `v<i>_freq` on a quantized voice | shadow moves by `Δnote` on a turn, else restarts; result `tone_freq(shadow)` | the stored freq; sends `scaleNote` | 12-step |
| `lib/variation.lua:225-229, 366-371` `snap_freq`, `snap_quantized_freqs` | stored freq | `tone_freq` | `params:set(v<i>_freq)` | 12-step |
| `lib/variation.lua:232-235` `midi_note` | a MIDI key | `snap_note(key)` if quantized, else the key | the pitch `S.lib.notes.play` gets | 12-step (key = pitch) |
| `lib/variation.lua:102-109` `scale_note` | voice, freq | synth: `freq_to_note(freq)` or the freeze reference; buffer: the file's key (`lib/samples.lua:405`) or `root + 60` | `setGrainParam scaleNote` (`:114`, `:330`) | log; `root + 60` is a pitch class |
| `lib/variation.lua:120-123, 332` `send_root_note` | voice | `S.lib.samples.rate_root(voice)` (file key or 60, `lib/samples.lua:399-401`) | `setGrainParam rootNote` | log |
| `lib/variation.lua:126-147` `interval_set` | the voice's set | octaves `{-12,0,12}`, fifths `{-12,-5,0,7,12}`, chord degrees 1/3/5/7 of `musicutil.generate_scale(0, name, 2)` (`{0,4,7,11}` scale off), custom whole semitones -24..24 | `interval1..8` (semitones, floats in the engine) | 12-step |
| `lib/variation.lua:164-166` `send_scale` | scale, root | `setScale(root - 1, mask)` | the engine | 12-step |
| variation params `pitch_jitter` 0-12 st, `custom_interval_1..5` -24..24 st (number, whole) (`:288-303`) | | semitones | `pitchJitter`, `interval<n>` | 12-ET units, continuous |
| `lib/notes.lua:133-136` `freq_note` | the freq the engine plays | `69 + 12 log2(f/440)` | the freeze reference (`:330-343`) | log |
| `lib/notes.lua:352-361` `note_values` | voice, pitch | `note` = pitch clamped 0-127; `freq` = `note_num_to_freq(pitch)` clamped to the freq range; `rate` = `2^((pitch - root)/12)`, root the freeze reference or `rate_root`, clamped 0.25-4 | `noteOn(v, slot, note, freq, rate, vel)` (`:147-150`), the own note's slot-0 `noteOn` | log |
| `lib/notes.lua:367-372` `own_pitch` | a buffer or input voice's rate | `rate_root + 12 log2(rate)` | a slice note's pitch (`lib/slices.lua:423`), the drone's return | log |
| `lib/midi_in.lua:483-496` `own_setters` (the own note's `set_own`) | pitch | synth: `note_num_to_freq(pitch)` → `v<i>_freq`; buffer `v<i>_buf_rate` / input `v<i>_grain_pitch` = `2^((pitch - rate_root)/12)`; clamped | `params:set` (the freq passes the filter) | log, then the 12-step filter |
| `lib/midi_in.lua:506-536` `midi_note_on` | key 0-127, channel | `pitch = S.lib.variation.midi_note(voice, key)` (`:525`) | `S.lib.notes.play`; a slice voice ignores pitch (`:518-522`) | 12-step (identity map) |
| `lib/midi_in.lua:571-573` `midi_pitchbend` | 14-bit bend | `2^(((v - 8192)/8192) * 2 / 12)` | `setVoiceParam bend` (ratio) | log (a bend range in semitones) |
| `lib/mpe.lua:116-118, 120-135` `values` | a channel's bend | `2^(((raw - 8192)/8192) * range / 12)`, times the zone's master ratio | `noteExpression` bend (ratio) | log |
| `lib/sequencer.lua:413-416` `value_note` | a note param's value | synth `69 + 12 log2(f/440)`; buffer/input `rate_root + 12 log2(rate)` | a pitch | log |
| `lib/sequencer.lua:426-443` `degree_semitones` | voice, degree -14..14 | walk whole notes from the voice's pitch, counting set bits of the 12-bit mask; chromatic: k semitones | semitones (fractional) | 12-step |
| `lib/sequencer.lua:495-511` `step_chord` | the base value, semitones per note | `value = base * 2^(st/12)` (clamped), `pitch = base_note + st` | the own note's override (`set_override`, which resends `scaleNote`, `:322-330`), extra notes through `S.lib.notes.play` (pitch → `note_values`) | log |
| `lib/sequencer.lua:610-629` `step_pitches` | chord, pitch lock | pitches `+ 12 log2(lock / stored)` | `event.pitches` for the targets | log |
| `lib/samples.lua:391-405` `rate_root`, `scale_reference` | a slot file's key (whole 0-127, `:61`) | the key or 60; the key or nil | `rootNote`, `scaleNote`, rates | log (a key names a 12-ET note) |
| `lib/slices.lua:419-430` `play` | slice n | pitch = `S.lib.notes.own_pitch(voice)` (no key mapping) | `S.lib.notes.play` | none |
| `lib/io/targets.lua:41-43` `volts` | pitch | `(pitch - 60) / 12` | crow, JF, W/syn, ER-301, TELEXo | log |
| `lib/io/crow.lua:213-215` `pitch_volts` | pitch | `(pitch - 60) / 12` (its own copy, `:37`), clamped to the jack's range; written `%.4f` (`:72`) | `output[n].volts` | log; 0.0001 V = 0.12 cent |
| `lib/io/jf.lua:82` | pitch | `volts`, clamped -5..5 | `ii.jf.play_note(v, level)` | log |
| `lib/io/wsyn.lua:78` | pitch | `volts`, clamped ±5 | `ii.wsyn.play_note(v, vel)` | log |
| `lib/io/er301.lua:44-46` | pitch | `volts`, clamped ±10 | `ii.er301.cv(port, v)` | log |
| `lib/io/txo.lua:69-72` | pitch | `volts`, clamped ±10 (pitch mode) | `ii.txo.cv(n, v)` | log |
| `lib/io/midi_out.lua:283` `start_note` | pitch | `round(pitch)` clamped 0-127 | MIDI note number | loses the fraction |
| `lib/io/midi_out.lua:144-148` `encoded("bend")` | a played note's raw bend ratio | `8192 + 8192 * 12 log2(bend) / range` (`midi_out_bend_range`, default 48 st) | MPE per-note pitchbend; step notes get a centered bend (`:296-314`) | log; the only path a fraction could take |
| `lib/io/nb.lua:202` | pitch | `floor(pitch + 0.5)` | `player:note_on(note, vel)` | loses the fraction |

The engine's fast pitch destination is not a note: an offset of `m × 1.875` added to `pitchShift`, linear in the ratio (`StrataModulation.sc:36, 189`). Pressure, slide and the other expression targets carry no pitch (`docs/notes/lua/expression.md:24`).

**Can a microtuned pitch reach each target?**
- crow: yes, as volts, to 0.0001 V (`lib/io/crow.lua:72`; crow's DAC resolution is from memory and not checked).
- Just Friends, W/syn, ER-301, TELEXo: yes, as volts written to four decimals (`lib/io/ii.lua:93` through `S.lib.io_crow.number`). crow then encodes ii values as 16-bit (from memory: 16384 per 10 V, about 0.7 cent a step; not checked).
- MIDI out: plain mode, no; each voice has one channel and one bend. MPE mode, yes, if the remainder `pitch - round(pitch)` were added to the note's bend at its start and to every later bend. The bend encoding is already per note and in semitones (`:144-148`). The other way, sending the *key* rather than the pitch to an external synth that holds the same tuning, has no key for step notes (degrees).
- nb: not as Strata calls it (rounded). Whether a player would take a fractional note or a `pitch_bend` is the player's own; nb's source isn't on this machine (Unsure).

## 2. The engine's side

**Storage.** `areaState[\scale]` holds `\buffer` (12 mono frames), `\root`, `\mask`, `\offsets` and `\notes` (per voice the `scaleNote` Lua last sent) (`StrataScale.sc:83-91`). `setScale(root, mask)` (`"ii"`, `:124-128`) checks root 0-11 and mask 1-4095 (`:108-110`; anything else is ignored), works out `scaleOffsets` and rewrites the buffer with `setn` (`:114-122`). The bufnum is built into both grain SynthDefs as a constant, so it is allocated once in `allocState` before every `addDefs` (`:11-16`, `docs/notes/engine/variation.md:8`).

**The quantize** (`StrataScale.sc:135-139`, called from `grainRate`, `StrataVariation.sc:47-48`), in semitones (fractional MIDI notes):
- `base = scaleNote + ratiomidi(pitchShift)`;
- `rounded = round(base + offset)`, where offset is the pitch jitter plus the drawn interval;
- the result is `rounded + Index(scaleBuffer, rounded % 12) - base`;
- the grain's rate is then `pitchShift × midiratio(semitones) × bendRate × sign` (`StrataVariation.sc:50`).

So it quantizes the grain's absolute pitch to whole 12-ET notes, then moves the note to the nearest scale class through the table. Bend and crossmod multiply afterward ("quantize before bend", `docs/notes/engine/variation.md:6`).

**`scaleNote`** is the reference that makes the pitch absolute:
- a synth voice's freq as a note, or its freeze reference;
- for a buffer voice, the file's key or `root + 60`, plus the slot's `ratiomidi(bufRate)` added in the engine (`StrataScale.sc:43-49`); a buffer note's own is `noteScaleNote(voice, rate)` (`:54-56`, `StrataNotes.sc:168`).

**`rootNote`** is kept per voice and sent to no synth (`StrataNotes.sc:56-68`). `absoluteNoteRate(note, voice) = 2^((note - rootNote)/12)` (`StrataNotes.sc:37-39`) gives a ring-stream note leaving a freeze its rate (`:44-46`). It is log math: correct for any tuning as long as `noteOn`'s `note` (clipped 0-127, `:646`) is the tuned pitch, not the key.

**Where twelve is assumed:**
- `StrataScale.sc:89`: a buffer of 12 frames.
- `StrataScale.sc:101, 103, 104`: `% 12` and `12.collect`; `:102`: candidate offsets -6..6.
- `StrataScale.sc:108-110`: root 0-11, mask ≤ 4095 (`chromaticMask`, `:9`).
- `StrataScale.sc:138`: `rounded % 12` and the whole-note `round`.
- Elsewhere the 12 is the log unit only: `ratiomidi`/`midiratio` (`StrataScale.sc:46, 55, 136`; `StrataVariation.sc:50`) and `/ 12` (`StrataNotes.sc:38`), which hold for any tuning.

**Where pitch enters in Hz and where as a ratio:**
- Voice SynthDefs take `freq` in Hz, times `bend × noteBend × (1 + crossmod)` (`StrataVoiceDefs.sc:15-19`, each def's `freq=` default at `:136, 191, 225, 251, 279, 318, 374`). No assumption: a tuned frequency plays as sent.
- An extra synth-voice note is `\freq` in Hz too (`StrataNotes.sc:167`).
- Grain defs take `pitchShift` as a ratio (0.25-4), `noteRate` and `bufRate` as ratios, `scaleNote` as a fractional note, and the intervals and `pitchJitter` as semitones (`StrataGrainDefs.sc:109-117, 200-248`).

**What a tuning other than twelve equal steps would need there** (the options; see 0.4 and 0.5):
- **12 notes, octave period.** Keep the 12 frames and `Index` of `rounded % 12`. The frames become fractional: for each class c, `(target class - c) + deviation(target)/100`. That costs no UGen. It needs a command carrying 12 deviations (a new `"iiffffffffffff"`, or 12 messages of `"if"`), and `scaleOffsets` rewritten. The tie-break moves slightly, because `round(n)` still happens in 12-ET first, so a pitch within a few cents of a 12-ET midpoint may pick the other neighbor (est.).
- **Any N, any period, any reference: an absolute table.** Frames over the grains' whole pitch range, each holding the nearest allowed tone. The range is the synth freq range (MIDI 15.5-95.2) ± 24 st of `pitchShift`, ± 12 st of jitter, ± 24 st of interval: about -45 to 155 (est.). At 10-cent resolution that is 2000-2560 frames (est.), about 10 KB of RAM, none of it in the pool. The decision boundary moves by at most half the resolution, but the landed pitch is exact. The quantize becomes `tone = Index.ar(buf, ((n - low) * res).round)` and the result `tone - base`, the same UGen count as today or one fewer (est.). A period-relative table (one period in cents, `IndexInBetween` on a sorted table, a mod by the period) would add about 8-10 UGens (est.).
- **The grain synths' memory.** Each UGen is about a quarter of a KB in every grain synth (`docs/notes/engine/variation.md:4`). `\strataGrainBuf` is 82.6 KB of its 88 KB limit (quoted, `docs/status.md`).
- **Filling the table.** Matron commands take fixed scalar arguments (`i`, `f`, `s`). The tones reach the engine as one message per tone, as a string (`"s"`, parsed in sclang), or as a file the engine reads (as `loadBuffer` takes a path). sclang then builds the table. AGENTS.md bans a per-sample sclang loop in `StrataFiles.sc` and asks for C primitives; a 2560-frame build over N tones is the same kind of work and should use array primitives (est.).
- **The mask beside a tuning** can stay Lua's: Lua filters the tones by the mask before sending them, so the engine holds only "the allowed tones".
- **One tuning per voice in the engine.** The table bufnum is a constant, so per-voice tables need a control: a per-voice offset into one large buffer (one `+`, a control in `grainControls` and `controlNameSets`, sent to extra grain notes too), or a bufnum control.

## 3. Scales today in Lua

**Where the list comes from.**
- The scale list is norns' `musicutil.SCALES` (41 scales, `musicutil.lua:16-56`, the last "Chromatic"); Strata has no list of its own.
- `scale_options()` is `off` plus every name (`lib/variation.lua:39-43`): 42 options.
- `root` is `musicutil.NOTE_NAMES`, C-B (`:387`).
- The test stub copies the 41 scales (`test/norns_stubs.lua:2773-2820`).

**How it is stored.**
- `scale` and `root` are option params by **index**, added by `M.add_scale_params()` (`lib/variation.lua:377-393`) in the `scale` record, before every voice (`lib/params_setup.lua:732`).
- PSETs save the index.
- Both are discrete scene globals (`lib/variation.lua:396-397`), captured as `params:get` (`lib/scenes.lua:337-339`), so also the index.
- A norns update that inserted a scale would move every saved choice. Nothing guards this today, unlike the keyed options (`docs/notes/lua/io/keyed.md:3`).

**How the mask is built and sent.** The bits are `interval % 12` of the scale's intervals, summed as powers of 2 (arithmetic, for LuaJIT; `lib/variation.lua:60-67`). `send_scale` goes from both actions (`:164-166`), which also re-snap every quantized freq (`:366-371`, never during a recall or a fade) and resend chords or `scaleNote` (`:380-392`). Scale off sends 4095.

**Which pages show it.** None. `scale` and `root` are in PARAMETERS only (`docs/user/params.md:143-144`). VOICE shows each voice's `quantize` (the variation section, `lib/variation.lua:336-343`); SEQ shows step degrees as `+3` (`docs/user/pages/seq.md:27`). No grid layout or controller shows the scale (grep of `lib/grid`, `lib/arc`, `lib/io`).

**What a user scale (a stored 12-bit mask) needs:**
- **A value:** a number param `scale_mask` 1-4095, or twelve binaries. Numeric, so it can be a PSET param and a discrete scene global (`lib/scenes.lua:1211` takes numbers).
- **Picking it:** a `custom` entry in `scale`, appended after the musicutil names (index 43) so that no saved index moves, or the scale made keyed through `S.lib.io_keyed` (then a scene needs a block for the key).
- **Several named user scales:** a list beyond PSET values: a data file (an eleventh in `data/strata`; AGENTS.md lists ten) or a PSET side file through `S.lib.side_files`.
- **Every reader of the mask** already takes any mask: `scale_mask()` (`lib/variation.lua:60`), `degree_semitones` (`lib/sequencer.lua:428`), the engine (`StrataScale.sc:110`). Only `interval_set`'s chord (`lib/variation.lua:131-139`) reads `musicutil.generate_scale` by name, so it needs its own degrees from the mask (the set bits in order).
- **Where the editor could live:** SETUP opens modal editors from a row (`lib/pages/setup.lua:63`: the mpe & zones row opens `S.lib.ui_zones`, a `S.lib.ui_modal` owner, `lib/ui/zones.lua:1-14, 253-256`). Twelve toggles fit the 128 px row (about 10 px a class, est.). The zones editor's note tap (`S.lib.midi_in.set_note_tap`, `lib/midi_in.lua:181`) could learn a scale from played keys. On the 256, twelve keys of one row could toggle the classes; which row is free is `docs/design/3.8-facts/lua-grids.md`'s to say. An arc ring has no natural fit for twelve toggles. A MIDI controller's keys could toggle classes through the same note tap.
- **What a scene stores:** the mask (numeric global) and the scale index as today.

## 4. A tuning as data

**Scala `.scl` (from memory).**
- A text file; lines that begin with `!` are comments.
- The first other line is a description, which may be empty.
- The next is the number of pitches N, then N pitch lines. 1/1 (0 cents) is implied and not listed.
- A pitch that holds a `.` is cents (a float, which may be negative); one without is a ratio `a/b` or a whole number `a` (`a/1`). Anything after the value on a line is ignored, as is leading whitespace.
- The last pitch is the period ("formal octave"): `2/1` or `1200.0` usually, `3/1` for Bohlen-Pierce.
- Pitches need not be ascending, though nearly all files are.

**`.kbm` (from memory).** After the comments, in order:
1. the map size (0 = linear);
2. the first and last MIDI note to retune;
3. the middle note (the key where degree 0 sits);
4. the reference note and its frequency in Hz;
5. the scale degree that is the formal octave;
6. then map-size lines, each a degree or `x` for an unmapped key.

With no `.kbm`, Scala's default maps key 60 to degree 0 with key 69 at 440 Hz (from memory, Unsure). For a 12-note JI scale that puts C at 440 / (degree 9's ratio).

**What Strata needs to hold.**
- The tones of one period in cents from degree 0 (N values, sorted) and the period in cents.
- A reference (a key and its frequency, or the degree-0 key and the root's frequency).
- A keyboard mapping: the default linear one (key k is degree `k - middle`, wrapping by N per period), or a `.kbm` map.
- A name, for the screen and for PSETs and scenes.
- A precomputed `pitch_of_key[0..127]` (fractional notes) is cheap to keep (est.).

**What norns ships.**
- `lua/lib/intonation.lua`: `normal`, `ptolemy`, `overtone`, `undertone`, `lamonte` (12 ratios each, 1/1 first, no period), `zarlino` (16), `partch` (43) and `gamut` (168). Plain tables, so a built-in list could take them as they are (an octave period implied).
- `musicutil.note_num_to_freq`, `freq_to_note_num`, `interval_to_ratio`, `ratio_to_interval` are all 12-ET (`musicutil.lua:639-702`).
- Nothing in `lua/core` or `lua/lib` reads `.scl` (grep for "scl", "scala" and "tuning" found only a comment in `core/menu.lua:20`).
- The test stub has no `intonation`, so a `require "intonation"` needs a stub copy.

**Where a player's `.scl` files would live.** No norns convention exists in core. Strata's own data is under `_path.data .. "strata/"` (`lib/side_files.lua:24`, `lib/performance.lua:40`), its audio under `_path.audio .. "strata/"` (`lib/buffers.lua:120`). A `data/strata/tunings/` folder (est.) fits that pattern. The factory-preset installer (3.8's last package) could seed it. Some community norns mods keep tunings under `dust/data/` (from memory; Unsure).

**How a file select would pick one.**
- BUFFER opens `fileselect.enter(_path.audio, file_chosen)` under a guard against a failed enter (`lib/pages/buffer.lua:850-870, 893-899`).
- norns' `fileselect.enter(folder, callback, filter_string)` shows only files whose extension matches the filter, plus folders (`~/src/norns/lua/lib/fileselect.lua:16, 27, 129-141`), so `".scl"` lists only Scala files. It still calls `audio.file_info` on each file (`:124`).
- A norns file param (`params:add_file`, as `buf<n>_file`, `lib/params_setup.lua:668`) opens at `_path.dust` from PARAMETERS with no filter (`core/menu/params.lua:188`). A PSET keeps its path.
- Two pitfalls a file param brings: norns lists a file param's folder with a shell `ls` on every new path (#480), and a folder name holding `$`, a backtick, `\` or `"` runs as shell (#559). Both are guarded today for the buffer params (`docs/notes/lua/buffers.md:15-16`), and a tuning file param would need the same guards.

**How a tuning with N ≠ 12 meets a 12-bit scale mask.** The code allows these options:
- **(a) The mask only for 12-note octave tunings.** Degree i is class i, so a musicutil scale and the editor pick degrees of the tuning (JI major = the major classes of a JI table). With other tunings the "scale" is the whole tuning, and the mask is off or hidden.
- **(b) An N-bit degree mask.** It fits one engine `i` (int32) up to N = 31, or a Lua number exactly to 53 bits. An editor of N toggles doesn't fit twelve-wide screens for large N.
- **(c) Nearest-class filtering.** A tuning tone is allowed when its nearest 12-ET class is in the mask. musicutil scales then filter any tuning (several tones per class for N > 12); it is ambiguous near quarter tones.
- **(d) Mask and tuning as separate layers.** The tuning maps keys to pitches for MIDI and the targets; the quantize and the degrees use the tuning's tones filtered by the mask under (a) or (c).

Whichever is chosen, Lua's `snap_note`, `tone_freq`, `degree_semitones` and the chord set must use the same tone list the engine gets, or a quantized voice's freq and its grains disagree.

**Periods other than an octave.** The 12-bit mask, `root` as a pitch class (`lib/variation.lua:53-55`) and `scaleNote = root + 60` for buffer voices (`:108`) all assume the octave. An absolute-pitch tone list sidesteps the period in the engine; Lua's degree walk then steps through the list (`lib/sequencer.lua:432-440`, whose loop bound `12 × (|k| + 1)` assumes at most an octave between tones, `:434-435`).

## 5. One tuning or one per voice

**One tuning (the script's).** One module (est. `lib/tuning.lua`, `S.lib.tuning`) would give the functions every 12-step site calls:
- `pitch_of_key(key)` for `lib/midi_in.lua:525`, replacing the key as the pitch inside `variation.midi_note`;
- `snap(pitch)` and `step(pitch, k)` (the k-th allowed tone above or below) for `lib/variation.lua:70-84, 170-183, 202-221` and `lib/sequencer.lua:426-443`;
- `tones()` for the chord set (`lib/variation.lua:131-139`) and for what is sent to the engine (`:164-166`).

Everything in section 1 marked "log" stays as it is. `note_values`, `own_setters`, `step_chord`, the targets' `volts` and the engine's `scaleNote`, `rootNote` and `absoluteNoteRate` are correct once the pitch is tuned. The engine keeps one table, as today. The default (12-ET, no file) must give back today's pitches exactly, which `test/unit/system_37_test.lua` checks against 3.7.0 (the groundwork re-bases it).

**One per voice.** Which sites know their voice:
- **Know it:**
  - the `freq` filter (`freq_filter(voice_idx, …)`, `:202`);
  - `variation.midi_note(voice_idx, note)` (`:232`);
  - `midi_note_on(voice_idx, …)` (`lib/midi_in.lua:506`), which runs after the voice is chosen: by channel (per voice), the selection (omni) or `S.lib.mpe.targets(channel, note)` by key range (`lib/mpe.lua:96-115`), all on the key, not the pitch, so the voice is known before any tuning applies;
  - `note_values(voice, pitch)` (`lib/notes.lua:352`);
  - `degree_semitones(voice_idx, k)` (`lib/sequencer.lua:426`);
  - `interval_set(voice_idx)` (`:126`);
  - `scale_note(voice_idx)` (`:102`);
  - every target (it gets `voice` and an already-tuned pitch).
- **Don't know it:**
  - `scale_mask()` and `snap_note()` (`lib/variation.lua:60, 76`), which are global today but called only from per-voice sites, so a voice argument threads through;
  - `send_scale()` and the engine's single `scaleBuffer` (`StrataScale.sc:77, 89`), which needs per-voice tables or an offset control (section 2);
  - the MIDI allocator's pool (`S.lib.notes`), which is pitch-blind, so it is unaffected;
  - the scale and root params, which are globals.

**Where a tuning's name would be stored**, following today's file-valued settings:
- **A buffer's file** is a file param (`buf<n>_file`, PSET path) plus `buffers.data` (paths only, device level; `docs/notes/lua/buffers.md:3-5`), with its per-file settings in `samples.data`.
- **Options saved by key** go through `S.lib.io_keyed` (an option with `save` off plus a hidden text `<id>_key`; `docs/notes/lua/io/keyed.md:3-6`). That suits a built-in tuning list that may grow.
- **Scenes:** scene globals must be numbers (`lib/scenes.lua:1211`), so a tuning name or path in scenes needs a scene block (`register_scene_block`: `{key, default, capture, validate, apply, discrete = true}`, `lib/state.lua:400-412`).
- **Per voice:** in the groundwork's model a per-voice tuning is a voice value (`S.voices[i].values.tuning`, through a record). Values are params, so they are numeric: an index, or a keyed pair, which the records don't model (the groundwork keeps 14 keyed or rig params outside the value table, design §2).
- **The tuning's content:** a PSET side file (`<pset>.tuning.data` through `S.lib.side_files`, as scenes do after the groundwork) would carry the tones themselves, so a PSET still plays if the `.scl` moves or is deleted. A path alone doesn't.
- **Data file rules:** any Strata-written data file must go through `S.lib.data_files.write` and `read` (AGENTS.md). A `.scl` is a foreign file: read as text and parsed, never run.

## 6. Tests that pin today's note-to-frequency math

- `test/unit/notes_test.lua`: "note_values gives a note, its frequency and its rate" (:101: 69 → 440 Hz, rate `2^(9/12)`, 60.5 → `13.75·2^((60.5-9)/12)`, the clamps); "an extra note on a buffer voice plays its rate from the file's key" (:178); "a frozen synth voice plays rates from its freeze reference" (:705).
- `test/unit/variation_test.lua`: "chord follows the scale's degrees" (:147); "a quantized freq moves by scale tones on slow encoder and arc turns" (:163); "a MIDI note snaps to the scale for a quantized voice only" (:353); "scale and root are discrete scene globals that send setScale" (:378); "a buffer voice's scaleNote is its file's key, and every sync sends rootNote" (:416); "scaleNote follows a freq change, a root change, a quantize change and a source change" (:439); "a scale or root change re-snaps a quantized freq…" (:692); "a MIDI note two semitones from a voice left mid-turn plays that note (#412)" (:736); "a frozen synth voice's scaleNote is its freeze reference" (:786).
- `test/unit/midi_in_test.lua`: "MIDI notes set pitch per source…" (:64); "a buffer voice's MIDI note plays rate 1 at its file's key" (:82); "MIDI note details: start order, exact pitch, clamping…" (:99); "note off mode and pitchbend" (:152); "pitchbend: range, buffer voices…" (:328); "a buffer voice's own note and an extra note at one pitch play the same exact rate" (:657); "a quantized voice's MIDI notes snap to the scale, in its freq or buffer rate" (:686); "a quantized voice's every note is snapped" (:959).
- `test/unit/sequencer_test.lua`: "a noted step that starts a stopped quantized synth voice: voiceOn's freq and the first scaleNote are the note's" (:786); "a step's note on a buffer voice sends the exact rate" (:855); "a note transposes the voice by scale degrees" (:868); "a step's notes go through the scale once per step…" (:2306); "an input voice's chord measures every note from the step's pitch lock" (:2771); "a buffer voice's step pitches and degrees count from its file's key" (:3104).
- `test/unit/samples_test.lua`: :404, :434, :453 ("a key of 57 makes note 57 rate 1 and the quantize reference"), :506.
- `test/unit/mpe_test.lua`: "a member channel's bend uses the bend range…" (:92).
- `test/unit/io_targets_test.lua`: "volts puts note 60 at 0 V, a volt an octave" (:94, pins `zero_volt_note` 60 and `notes_per_volt` 12).
- `io_jf_test.lua:87` and `io_wsyn_test.lua:61` ("a note is one play_note in volts"); `io_txo_test.lua:131`; `io_crow_test.lua:266`.
- `io_midi_out_test.lua`: the bend and MPE note tests (:287, :594).
- `test/unit/docs_test.lua`: "the scale and bypass params' defaults equal the engine's start state (#460)" (:492: `setScale`'s default root and mask equal `allocScaleBuffer`'s); "the engine's note constants equal the script's" (:2141: `noteRateRootNote` = `NOTES.rate_root_note` = `MIDI.rate_root_note`).
- `test/unit/system_37_test.lua`: a default start against 3.7.0.
- Engine: `test/engine_check/variation.scd` (:105-123 the 12-frame buffer, chromatic start, C and D major offsets, a bad root or mask ignored; :154-165 quantize lands every grain on C major; :242 on, a buffer voice at `bufRate 2^(4/12)` gets 64 and stays in C major, and the bend lands half a semitone off it); `test/engine_check/notes.scd` (:251-280 `rootNote` 57 and `absoluteNoteRate`; :413-444 a buffer note's `scaleNote` `60 + 1.5.ratiomidi`, 72).

## Where the roadmap or the notes are wrong or silent

- `docs/notes/lua/notes.md:13` and `lib/notes.lua:351`: "`note_values` is the one place a pitch becomes what the engine plays… 3.8's tunings change it alone." The own note is pitched in `lib/midi_in.lua:486-495` (`own_setters`) and `lib/sequencer.lua:504` (the override), and passes the 12-step `freq` filter (`lib/variation.lua:202-221`). `note_values` is log math that needs no change; the tuning enters at the key, the degree, the snap, the chord and the engine's table (0.2).
- `docs/notes/lua/variation.md:4`: "One encoder detent (0.8 semitone of raw travel)… moves less than a scale step" holds only for steps above 0.8 st. Dense tunings break the "about one scale tone per semitone of travel" rule (`lib/variation.lua:190-201`).
- ROADMAP.md, "Microtuning and a scale editor": "`setScale` already takes any 12-bit set, so this is a screen and a stored mask" is true for the engine. But the `scale` param is an index into norns' list (`lib/variation.lua:379`), saved by index in PSETs and scenes (`:396`), so a `custom` entry must be appended or the param made keyed. The chord set reads `musicutil.generate_scale` by name (`:134`) and needs its own path for a user mask.
- ROADMAP.md is silent on the outputs: "wherever Strata turns a note into a frequency" names the quantize, steps, MIDI and MPE, but MIDI out (`lib/io/midi_out.lua:283`) and nb (`lib/io/nb.lua:202`) round pitches to whole notes. Only MIDI out's MPE bend could carry the cents.
- ROADMAP.md is silent on note counts other than twelve and on non-octave periods against the 12-bit mask, the 12-frame `scaleBuffer` (`StrataScale.sc:89`), `root` as a pitch class (`lib/variation.lua:53-55`) and the `root + 60` reference (`:108`).
- `lib/engine/StrataNotes.sc:641`: "a later release's tunings will need a note's number apart from its rate". Not needed if Lua sends the tuned pitch as `note`: `absoluteNoteRate` (`:37-39`) and `noteScaleNote` (`StrataScale.sc:54-56`) are log math. A key number is needed only if the engine must learn the key, which it never uses today.
- `lib/sequencer.lua:434-435`: "a scale holds its root, so at most an octave passes between two tones". The loop bound `SEQ.semitones * (|k| + 1)` assumes a 12-step octave and at most twelve semitones between tones.
- `docs/notes/lua/midi.md:15` ("notes keep exact equal-tempered pitch") and `docs/user/midi.md:16` ("exact equal temperament") become false under a tuning.
- `lib/variation.lua:39-43`: the scale list's indices follow norns' `musicutil.SCALES`. A norns change to the list would move saved PSET and scene choices; no note mentions it.
- A small existing quirk: musicutil's "In Sen Pou" lists its intervals unsorted (`{0, 1, 5, 2, 8, 12}`, `musicutil.lua:54`), and `generate_scale` keeps that order (`:259-273`). So the `chord` interval set's degrees 1/3/5/7 there are `{0, 5, 8, 13}`, not a stacked chord (`lib/variation.lua:134-138`). The mask and the degree walk are unaffected (they use sets).
- `lib/quantize.lua` is the time quantize of key actions (`docs/notes/lua/quantize.md:3`); it has nothing to do with pitch.

## Unsure

- **The Scala formats** are from memory, the no-`.kbm` default mapping (key 60 = degree 0, key 69 = 440 Hz) included. Check against the Scala documentation before the parser is specified.
- **Resolution of the ii path** (crow → JF, W/, ER-301, TELEXo as 16-bit values, about 0.7 cent) and of crow's own outputs: from memory, not checked.
- **nb players:** whether they take fractional notes or offer a pitch bend. nb's source isn't on this machine; `lib/io/nb.lua` calls only `note_on`, `note_off`, `stop_all`, `active`, `inactive`, `delayed_active` and `add_params`.
- **Engine string arguments:** whether matron limits an `"s"` engine argument's length (for a tone list sent as text). Not checked in `~/src/norns`.
- **Community tuning folders on norns:** whether a mod or a convention keeps `.scl` files somewhere; nothing in `~/src/norns` does.
- **Costs:** the UGen and KB figures for a reshaped `quantizedOffset` and the sclang cost of building a 2000-2560-frame table are estimates. The engine measurements (`docs/design/3.8-facts/engine-grain.md`) or a later run of `test/engine_check/memory.scd` would settle them.
