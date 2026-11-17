# Facts: the grid layouts (the 256, then the 128h, the 128v and the 64)

Read on `main` at 59a0a0c1: `lib/grid/core.lua`, `lib/grid/faders.lua`, the four `lib/grid/layout_*.lua`, their notes and user pages, `lib/positions.lua`, `lib/playheads.lua`, the grid parts of `lib/sequencer.lua`, `iii/strata_grid.lua`, `lib/io/remote.lua`, `lib/io/controllers.lua`, `lib/arc/*.lua`, `docs/user/arc.md`, and the groundwork's design, plan and `plan-2a-records.md`. Where the groundwork changes the grids (the fader pages, `S.frozen` to `S.locked`), the maps show the code as the groundwork leaves it and say so; the only groundwork branch that touches `lib/grid/` so far (`feat/groundwork-0a-locked`) changes one line of `core.lua` (the lock's state name). Figures: line and test counts are **measured** (`wc -l`, `grep -c '^test('`, and `lua test/run.lua grid_` on Lua 5.3.6: 222 tests, 0 failures); key-coordinate counts in tests are **measured** with `grep` and are a lower bound (keys pressed through loop variables are not counted); fader page counts after the groundwork are **quoted** from the plan (ruling 12, `plan-2a-records.md:217-226`). Nothing was checked on a device; the midigrid quarter behavior is quoted from `docs/user/io/remote.md:50` and unverified.

## 0. The facts most likely to change the design

1. **On the 256, only rows 8 and 16 work on every page, and row 16 is full.** Row 8 has two dead keys (columns 10 and 11, `layout_256.lua:427-439`); row 16's sixteen keys are lock 1-7, the freeze modifier, copy/paste 1-7 and the clipboard clear (`:472-480`). So a new key that must work on every page (delay freeze, delay clear) has two places on the global rows unless a row's meaning changes.
2. **Voice on/off, the grid voice pick (row 14) and pattern clear/randomize (row 15) exist only on pages 1 and 2 of the 256** (`layout_256.lua:394-423`: they sit in the pattern/fader branch). On pages 3, 4 and 5 no key starts or stops a voice. Every smaller layout has the voice on/off keys on every page (128h row 8 columns 9-15, `layout_128h.lua:189-190`; 128v column 8 rows 1-7, `layout_128v.lua:134-135`; 64 row 8 columns 2-8, `layout_64.lua:128-131`). `docs/user/grid/256.md:40-42` gives row 14 no page qualifier.
3. **Free keys on the 256 are unevenly spread** (counted from the code, rows 8 and 16 included): page 1 has 7, page 2 14-15 after the groundwork (16-18 today), page 3 84 (a block of 55 at rows 11-15 x columns 1-11), page 4 53 (rows 9-15 x columns 13-16, column 11, and rows 1-2 x columns 9-16), page 5 65 (a block of 56 at rows 9-15 x columns 9-16). Pages 1 and 2 share rows 1-7 (the patterns), 8, 14, 15 and 16 and differ only in rows 9-13.
4. **Pages 4 and 5 already have one row per voice (rows 9-15) with free columns** (page 4: 11, 13-16; page 5: 5, 9-16). A per-voice key (voice type, preset load or copy) fits that pattern; no other 256 page has a free per-voice column. The 128h's page 4 has one row per voice too, with column 11 a light only and column 16 of row 6 and row 7 of columns 13-16 free.
5. **The layouts are if-chains over constants, and three of the numbers live outside the layout file.** `GRID_LAYOUT` in `lib/grid/core.lua:39-51` holds the 256's fader rows (9-12), the fader page row (13), the buffer rows (1-2), the FX rows (3-7) and the source rows (9-15); `lib/grid/faders.lua` reads `fader_rows`, `fader_width`, `fader_first_row` and `param_page_row` from it (`:68, 78, 188-190, 311-322`), and the 128h and 128v read `fader_rows` as their faders per page. `S.param_page` and `S.grid_voice_select` are global, shared by every grid (`core.lua:35-36`), so a 256 that showed other than four faders a page would change what a 128's page key means (`docs/notes/lua/grid/layout_128h.md:6`).
6. **The page numbers are shared by every layout and read outside `lib/grid/`.** `S.constants.GRID_PAGES` (`lib/constants.lua:170-171`: patterns 1, faders 2, scenes 3, sources 4, positions 5, count 5) is read by `lib/playheads.lua:18, 247` (positions and `strip_page`), `lib/waveforms.lua:25, 111, 130` (positions), `lib/buffers.lua:830` (sources), `core.lua:87` (`set_page` refuses a page above `count`), the 128v's page cycle (`layout_128v.lua:20, 137`: five levels, one per page) and the layout records' `fx_faders_page` (`layout_256.lua:657`). A sixth page, or pages renumbered on the 256 alone, touches those.
7. **A 256 rework re-bases most of its own tests.** The five grid test files hold 222 tests (core 73, 256 53, 128h 41, 128v 31, 64 24) and at least 904 calls with literal coordinates (core 227, 256 299, 128h 150, 128v 111, 64 117). Outside them, `params_setup_test.lua` (13), `stubs_test.lua` (13), `positions_test.lua` (9), `strata_test.lua` (9), `pages_seq_test.lua` (6), `arc_pages_test.lua` (6), `mutation_test.lua` (4) and five more files press or read grid keys.
8. **Nothing outside `lib/grid/` names a grid coordinate.** The iii grid script is a pass-through of keys and LEDs (`iii/strata_grid.lua:40-62`), `lib/io/remote.lua` only knows sizes (`:19`), `lib/io/controllers.lua` has no grid code, and the position page is reached by name (`GRID_PAGES.positions`). Coordinates appear in user docs only: `docs/user/grid.md`, `docs/user/grid/*.md`, `docs/user/scenes.md:27, 36, 51`, `docs/user/sequencer.md:47`, `docs/user/modulation.md:61`, README.md:20.
9. **Hidden or missing on every grid:** reverb (mix, size, damp), both bypasses, the master filter's type and mix, delay ping-pong and the sync switch (the division fader appears only once synced, `faders.lua:138-143`), master density, drift, scatter, morph scenes C and D (shown as the pad's corners, never picked), the LFOs, the matrix, the envelopes. Only the 256 has tempo, mute and solo, pattern clear, randomize, copy and paste; copy and paste exist nowhere on the screen.
10. **The arc has free ring sets beside the grid.** FX has no ALT layer and no ring for delay feedback or the reverb (`lib/arc/fx.lua:14-19`); SCENES, LFO and IO have no ALT layer; SETUP's rings are off. VOICE's rings follow its rows (`docs/user/arc.md:25`), so a new per-voice row gets a ring with no arc code.

## 1. The 256, every page, every key

### Legend (every page)

```
..  does nothing, dark          ##  see the page's own legend
PL  play/stop                   T- t- t+ T+  tempo -10 -1 +1 +10
FL  fill, held                  P1..P5  grid page 1..5
L1..L7  lock voice 1-7 (with FZ held: freeze voice 1-7)
FZ  hold: turns L1..L7 into freeze keys
K1..K7  copy voice's pattern / paste onto voice      KX  drop the clipboard
```

Rows 8 and 16 are the same on all five pages (`layout_256.lua:397-398, 421-422, 367-369, 389-392`; page 5 falls through to them, `:304, 394-423`):

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 8   PL PL PL PL T- t- t+ T+ FL .. .. P5 P1 P2 P3 P4
16   L1 L2 L3 L4 L5 L6 L7 FZ K1 K2 K3 K4 K5 K6 K7 KX
```

| Row | Cols | Press | Hold | With another key held | LEDs | Handler |
|---|---|---|---|---|---|---|
| 8 | 1-4 | `pattern_toggle()` (all four the same) | - | - | 15 playing, 4 stopped (`play_level`) | `grid_key_256_transport` `:427-430`; LED `:609-612` |
| 8 | 5-8 | `params:delta("tempo", -10/-1/+1/+10)` and a `tempo <bpm>` header flash | - | - | 15 while held, 4 otherwise | `:431-438`; LED `:615-618` |
| 8 | 9 | fill on as `"grid:<port>"` (press and release: off at release; a page change or unplug lets go) | held = on | - | 15 while fill is on by anyone, 4 off | `fill_key` `:286-294`, dispatched first `:298-302`; LED `:621-622` |
| 8 | 10-11 | nothing | | | dark | `:427-439` (no branch) |
| 8 | 12 | `set_page(port, 5)` | | | 15 on page 5, 2 elsewhere | `:328-331`; LED `:603-604` |
| 8 | 13-16 | `set_page(port, 1..4)` | | | 15 shown, 2 other | `:333-337`; LED `:600-602` |
| 16 | 1-7 | `toggle_lock(x)` (`S.frozen`, `S.locked` after the groundwork) | - | with col 8 held: `S.lib.freeze.toggle_quantized(x)` | 12 locked, 2 not; while col 8 held 15 frozen, 3 not | `grid_key_256_lock` `:472-474`; LED `:630-638` |
| 16 | 8 | nothing itself | held: rows 16's 1-7 become freeze | - | 15 held, 4 not | `freeze_held` `:461-463`; LED `:639-640` |
| 16 | 9-15 | no clipboard: copy voice x-8's pattern (a snapshot); clipboard of another voice: paste it (`replace_pattern`); the copied voice's own key: nothing | - | - | copied 15, the others 4 while a copy exists, 2 with none | `copy_paste_key` `:446-457`; LED `:641-648` |
| 16 | 16 | drop the clipboard (the only way to copy another voice) | | | 4 with a copy, 2 without | `:475-476`; LED `:649` |

Hold times: `GRID_HOLD = {scene_save_seconds = 0.5, half_toggle_seconds = 0.5, step_edit_seconds = 0.3}` (`lib/constants.lua:166`).

### Page 1: patterns, mutes, recorders, macros

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 1   st st st st st st st st st st st st st st st st    voice 1, step = column
 2   st st st st st st st st st st st st st st st st    voice 2
 3   st st st st st st st st st st st st st st st st
 4   st st st st st st st st st st st st st st st st
 5   st st st st st st st st st st st st st st st st
 6   st st st st st st st st st st st st st st st st
 7   st st st st st st st st st st st st st st st st    voice 7
 8   PL PL PL PL T- t- t+ T+ FL .. .. P5 P1 P2 P3 P4
 9   G1 G2 G3 G4 M1 M2 M3 M4 M5 M6 M7 .. B1 B2 B3 B4
10   mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf    shown bank's 1st macro
11   mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf    2nd
12   mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf    3rd
13   mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf mf    4th
14   V1 V2 V3 V4 V5 V6 V7 .. O1 O2 O3 O4 O5 O6 O7 ..
15   C1 C2 C3 C4 C5 C6 C7 .. R1 R2 R3 R4 R5 R6 R7 ..
16   L1 L2 L3 L4 L5 L6 L7 FZ K1 K2 K3 K4 K5 K6 K7 KX

st step   G gesture recorder   M mute (hold: solo)   B macro bank   mf macro fader
V pick the grid voice   O voice on/off   C clear pattern (hold)   R randomize pattern (hold)
```

| Row | Cols | Press | Hold | With another key held | LEDs | Handler |
|---|---|---|---|---|---|---|
| 1-7 | 1-16 | becomes the voice's held step; toggles at its release unless consumed | 0.3 s: opens the step editor (consumed; its release closes it) | another key of the same voice while a step is held: the held step's level = `max(1, round(col*15/16))`, both consumed | `step_brightness`: the level; the sounding step 15 set / 4 empty; past the voice's length 1 set / 0 | `grid_core.step_key(port,x,y,z,y,x,x,16)` `:394-396`; core `core.lua:330-348`, release `:280-284`, editor `:313-317`; LED `sequencer.lua:1790-1797`, `:540-545` |
| 9 | 1-4 | gesture recorder k: acts at release, `S.lib.gestures.press(k)` (empty, recording, playing, stopped, playing) | 0.5 s: clear (consumed) | - | empty 2, stopped 5, playing 10, recording 15 | `gesture_key` `core.lua:429-441` via `modulation_key` `:138-149`, dispatched before the presses-only return `:315-321`; LED `core.lua:444-447`, `:157` |
| 9 | 5-11 | mute key of voice x-4: toggles `v<i>_mute` at release (`set_binary_param`) | 0.5 s: toggles `v<i>_solo` (consumed) | only a key pressed in its role acts (`press_as`) | 2 muted, 15 soloed and heard, 8 otherwise | `mute_key` `:109-120`; LED `mute_level` `:123-127` |
| 9 | 12 | nothing | | | dark | `modulation_key_at` `:91-98` |
| 9 | 13-16 | `S.lib.macros.set_bank(1..4)` | - | - | 15 shown, 6 bank with targets, 2 empty | `:146-147`; LED `bank_level` `:130-134` |
| 10-13 | 1-16 | `set_param_from_column(macro_<m>, x)` (a grid touch, recorded) | - | - | bar 8 up to the value, the value's column 15 | `:151-152`; LED `grid_redraw_fader_row` `faders.lua:170-176` |
| 14 | 1-7 | `select_grid_voice(x)` (clamps `S.param_page`) | - | - | 15 picked, 4 other | `:410-414`, `core.lua:865-869`; LED `:559-561` |
| 14 | 8, 16 | nothing | | | dark | |
| 14 | 9-15 | `toggle_voice(x-8)` | - | - | 12 running, 6 running but silenced (mute/solo), 2 stopped (`voice_level`) | `:415-416`; LED `core.lua:412-416` |
| 15 | 1-7 | nothing at press | 0.5 s: `clear_pattern(x)`, redraw grids and screen | - | 2, 15 while the hold is pending | `pattern_key` `:258-274`; LED `:277-280, 565-569` |
| 15 | 9-15 | nothing at press | 0.5 s: `randomize_pattern(x-8)` | - | as above | same |
| 15 | 8, 16 | nothing | | | dark | |

### Page 2: parameter faders (as the groundwork leaves it)

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
1-7  st ... (as page 1)
 8   PL PL PL PL T- t- t+ T+ FL .. .. P5 P1 P2 P3 P4
 9   fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd    fader (page-1)*4 + 1
10   fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd    ... + 2
11   fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd    ... + 3
12   fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd fd    ... + 4
13   p1 p2 p3 p4 p5 p6 p7 p8 .. .. .. .. .. .. .. ..    p8 only where the voice has 8 pages
14   V1 V2 V3 V4 V5 V6 V7 .. O1 O2 O3 O4 O5 O6 O7 ..
15   C1 C2 C3 C4 C5 C6 C7 .. R1 R2 R3 R4 R5 R6 R7 ..
16   L1 L2 L3 L4 L5 L6 L7 FZ K1 K2 K3 K4 K5 K6 K7 KX

fd  a fader of the grid voice (S.grid_voice_select)   p  fader page key
```

| Row | Cols | Press | Hold | With another key held | LEDs | Handler |
|---|---|---|---|---|---|---|
| 1-7, 14, 15 | | as page 1 | | | | `:394-396, 410-420` |
| 9-12 | 1-16 | `set_fader_param(S.grid_voice_select, (S.param_page-1)*4 + row, x)`: the param's warp, a zero column (column 9 on symmetric ranges) setting exactly 0; option params as index faders | - | - | bar 8, value 15; a row past the voice's last fader dark and dead | `:399-404`; `faders.lua:146-150, 87-116`; LED `grid_redraw_faders` `faders.lua:311-322` |
| 13 | 1..N | `S.param_page = x` (N = `fader_page_count`) | - | - | 15 shown, 4 other (`fader_page_level`) | `:405-409`; `faders.lua:304-307` |
| 13 | N+1..16 | nothing | | | dark | `:407` |

N today: 4-6 (`docs/user/grid/256.md:38`). After the groundwork (plan ruling 12; `plan-2a-records.md:217-226`), with the new faders in rank order (voice filter cutoff, res, mix; delay and reverb sends; loop start and length on buffer voices only; pitch, size and pan jitter; attack, release): resonator 32 faders / 8 pages, fm, pulse, karplus, ring 31/8, folder 30/8, sub 28/7, buffer 32/8, sub on a buffer 31/8, input 27/7, sub on input 26/7. So row 13 uses columns 1-7 or 1-8, and page 7 or 8 of a voice whose count is not a multiple of four has dead fader rows. Crossmod `mod_speed` stays without a fader.

### Page 3: scenes and morph

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 1   ri ri ri ri ri ri ri ri ri ri ri ri ri ri ri ri    recall at once, scene = column
 2   rf rf rf rf rf rf rf rf rf rf rf rf rf rf rf rf    recall with the transition
 3   sv sv sv sv sv sv sv sv sv sv sv sv sv sv sv sv    save (hold 0.5 s)
 4   G1 G2 G3 G4 .. .. .. .. .. .. .. .. .. .. .. ..
 5   SQ .. l1 l2 l3 l4 l5 l6 l7 l8 .. .. .. .. .. ..    sequence length 1-8
 6   .. .. l9 lA lB lC lD lE lF lG .. .. .. .. .. ..    sequence length 9-16
 7   mo mo mo mo mo mo mo mo mo mo mo mo mo mo mo mo    morph fader
 8   PL PL PL PL T- t- t+ T+ FL .. .. P5 P1 P2 P3 P4
 9   mA mA mA mA mA mA mA mA mA mA mA mA mA mA mA mA    morph scene A = column
10   mB mB mB mB mB mB mB mB mB mB mB mB mB mB mB mB    morph scene B = column
11   .. .. .. .. .. .. .. .. .. .. .. xy xy xy xy xy    pad y = 1 (C at 12, D at 16)
12   .. .. .. .. .. .. .. .. .. .. .. xy xy xy xy xy
13   .. .. .. .. .. .. .. .. .. .. .. xy xy xy xy xy
14   .. .. .. .. .. .. .. .. .. .. .. xy xy xy xy xy
15   .. .. .. .. .. .. .. .. .. .. .. xy xy xy xy xy    pad y = 0 (A at 12, B at 16)
16   L1 L2 L3 L4 L5 L6 L7 FZ K1 K2 K3 K4 K5 K6 K7 KX

SQ scene sequencer on/off   l  a length key   mo morph   xy XY pad (x = morph, y = morph_y)
```

| Row | Cols | Press | Hold | With another key held | LEDs | Handler |
|---|---|---|---|---|---|---|
| 1 | 1-16 | `S.lib.quantize.schedule("scene", recall_scene(x, 0), "S"..x)` | - | - | 15 current (wins; blinks during a fade), 10 the sequencer's next, 8 saved, 2 empty | `:343-345`; `core.lua:467-472`, `:503` |
| 2 | 1-16 | the same with `scene_transition_time` | - | - | 6 saved, 2 empty | `:346-349`; `core.lua:474-477` |
| 3 | 1-16 | arms the save | 0.5 s: `S.lib.scenes.save(x)` | - | 15 pending, 4 idle | `scene_save_key` `:350-352`, `core.lua:388-393`; LED `:480-482` |
| 4 | 1-4 | gesture recorders, as page 1 row 9 (a doubled function) | 0.5 s clear | - | as page 1 | `:322-326`; LED `:234-236` |
| 4 | 5-16 | nothing (`gesture_key` refuses k > 4) | | | dark | `core.lua:430` |
| 5 | 1 | toggles `scene_sequencer_enabled` (`set_binary_param`) | - | - | 15 on, 4 off | `:353-356`; LED `:509` |
| 5 | 2, 11-16 | nothing | | | dark | |
| 5 | 3-10 | `scene_sequence_length` = 1-8 | - | - | 8 within the length, 2 beyond | `scene_length_at` `:245-250`, `:357-359`; LED `:512-518` |
| 6 | 3-10 | `scene_sequence_length` = 9-16 | - | - | as row 5 | same |
| 6 | 1-2, 11-16 | nothing | | | dark | |
| 7 | 1-16 | `set_param_from_column("morph", x)` | - | - | fader bar | `morph_key` `:177-180`; LED `:237` |
| 9 | 1-16 | `params:set("morph_a", x)` | - | - | 15 chosen, 6 populated, 2 empty | `:181-183`; LED `:187-191, 238-240` |
| 10 | 1-16 | `params:set("morph_b", x)` | - | - | as row 9 | same |
| 11-15 | 12-16 | `morph` = (x-12)/4 and `morph_y` = (15-y)/4 through `set_param_fraction` (recorded) | - | - | 15 the position's cell, a corner 8 populated / 2 empty, others 4 | `pad_key` `:205-210`; LED `redraw_pad` `:214-231` |
| 11-15 | 1-11 | nothing | | | dark | `:363-365` |

### Page 4: buffers, FX faders, sources, freeze

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 1   r1 r2 r3 r4 r5 r6 r7 r8 .. .. .. .. .. .. .. ..    record slot = column
 2   c1 c2 c3 c4 c5 c6 c7 c8 .. .. .. .. .. .. .. ..    clear slot = column
 3   ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff    filter_freq
 4   fr fr fr fr fr fr fr fr fr fr fr fr fr fr fr fr    filter_res
 5   dt dt dt dt dt dt dt dt dt dt dt dt dt dt dt dt    delay_time (delay_division while synced)
 6   db db db db db db db db db db db db db db db db    delay_feedback
 7   dm dm dm dm dm dm dm dm dm dm dm dm dm dm dm dm    delay_mix
 8   PL PL PL PL T- t- t+ T+ FL .. .. P5 P1 P2 P3 P4
 9   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..    voice 1's source and freeze
10   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..    voice 2
11   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..
12   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..
13   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..
14   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..
15   sy b1 b2 b3 b4 b5 b6 b7 b8 in .. fz .. .. .. ..    voice 7
16   L1 L2 L3 L4 L5 L6 L7 FZ K1 K2 K3 K4 K5 K6 K7 KX

sy synth  b buffer slot  in input  fz freeze (toggle_quantized)
```

| Row | Cols | Press | Hold | With another key held | LEDs | Handler |
|---|---|---|---|---|---|---|
| 1 | 1-8 | `record_buffer(x)` with the record settings; again while recording stops and keeps, while armed cancels | - | - | 11 armed, 15 recording/dub/loop/finishing, 8 holding audio, 2 free | `:376-378`, `core.lua:503-505`; LED `core.lua:515-521`, `:577-582` |
| 1, 2 | 9-16 | nothing | | | dark | `core.lua:504, 508` |
| 2 | 1-8 | `clear_buffer(x)` | - | - | 4 | `:379-380`; `core.lua:507-509, 523` |
| 3-7 | 1-16 | `set_param_from_column(fx_fader_id(id), x)` | - | - | fader bar; follows changes elsewhere through `fx_fader_changed` (`params_setup.lua:58`, `delay_sync.lua:121`) | `:381-382`; `faders.lua:138-143`; LED `:530-533` |
| 9-15 | 1-10 | `source_key(y-8, x)`: 1 synth, 2-9 buffers, 10 input | - | - | 15 selected, 2 free buffer, 4 other | `:383-387`, `core.lua:489-500`; LED `:586-594` |
| 9-15 | 12 | `S.lib.freeze.toggle_quantized(y-8)` (a doubled function: also row 16 with col 8 held) | - | - | 15 frozen, 3 not | `:384-385`; LED `:466-468` |
| 9-15 | 11, 13-16 | nothing | | | dark | |

### Page 5: positions and bookmark strips

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 1   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps    voice 1, 16 cells of its loop (or 16 slices)
 2   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps
 3   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps
 4   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps
 5   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps
 6   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps
 7   ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps ps    voice 7
 8   PL PL PL PL T- t- t+ T+ FL .. .. P5 P1 P2 P3 P4
 9   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..    voice 1's strip
10   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..
11   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..
12   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..
13   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..
14   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..
15   k1 k2 k3 k4 .. ST HD WH .. .. .. .. .. .. .. ..    voice 7's strip
16   L1 L2 L3 L4 L5 L6 L7 FZ K1 K2 K3 K4 K5 K6 K7 KX

ps position cell (a slice key on a slice row)  k bookmark (a slice bank on a slice row)
ST store (hold)  HD hold the scan (held)  WH whole loop
```

| Row | Cols | Press | Hold | With another key held | LEDs | Handler |
|---|---|---|---|---|---|---|
| 1-7 | 1-16 | jump voice y to the cell (quantized under `quantize_actions`); a slice row plays its slice, the release ends it; buffer voices only | - | another cell of the same row held: loop from the lower cell's start to the higher's end | playhead 15, record head 13, held 11, in loop 4-8 / outside 1-3 by peaks; slices 15 playing, 11 held, 9, 0 | `S.lib.positions.grid_key(port, y, x, 16, z)` `:308-309`; `positions.lua:560-589`; LED `:487-490` |
| 9-15 | 1-4 | recall bookmark (quantized); on a slice row pick the bank | - | with ST held: store the playhead | 6, 10 last recalled, 15 storing, blink 15/2 waiting; banks 15/4/0 | `strip_key` `:310-311`; `positions.lua:593-632` |
| 9-15 | 6 | store, held | held = store mode | - | 15 held, 4 | `positions.lua:633-652` |
| 9-15 | 7 | hold the scan while held (releases end it) | held | - | 15 while held by anyone, 4 | `positions.lua:653-670` |
| 9-15 | 8 | whole loop, no jump | - | - | 15 while whole, 4 | `positions.lua:671-672` |
| 9-15 | 5, 9-16 | nothing | | | dark | `LAYOUT_256.strip_key_columns` `:52` |

Pages 1-4 never call `S.lib.positions`; page 5 passes releases (`:304-314`). The 256's record is never `selects_grid_voice`: each strip is its own voice's (`positions.lua:530-536`).

## 2. What is doubled, split or hidden

### `revisit.md`'s five observations, against the code

| Observation (`revisit.md:142`, ROADMAP.md:162) | The code |
|---|---|
| page 5's key apart from pages 1 to 4 | True: column 12 (`layout_256.lua:45, 328-331`), pages 1-4 at 13-16 (`:333-337`), columns 10-11 dead between them and fill at 9. |
| the scene sequence's length on two rows | True: rows 5 and 6, columns 3-10, banks of eight (`:60-63, 245-250`). The 128h does it on one row of sixteen (`layout_128h.lua:169-171`); the 256's row 6 has 8 dead keys, row 5 7. |
| freeze behind a hold | Half true: row 16's 1-7 freeze only with column 8 held (`:459-480`), but page 4's column 12 freezes with a plain press (`:384-385`). Freeze is behind a hold on pages 1, 2, 3 and 5 only. |
| four keys that play and stop | True: row 8 columns 1-4 all call `pattern_toggle` (`:428-430`); the 128h keeps three (`layout_128h.lua:21`). |
| no reverb fader | True, and wider: `GRID_LAYOUT.fx_fader_ids` is filter freq, res, delay time, feedback, mix (`core.lua:48`). No reverb mix, size or damp, no filter type or mix, no ping-pong, no sync switch, no bypass, on any grid; the arc's FX rings also lack the reverb and delay feedback (`lib/arc/fx.lua:14-19`). |

### Further observations

- **Doubled:** the gesture recorders, page 1 row 9 and page 3 row 4, columns 1-4 (`:142-143, 322-326`); freeze on page 4 (column 12 and row 16 with column 8); the patterns on pages 1 and 2 (rows 1-7 identical; the pages differ only in rows 9-13); the morph on page 3 (row 7's fader and the pad's bottom row both set `morph`).
- **Split:** pattern operations over three rows with different scopes: clear and randomize on row 15 (pages 1-2, held), copy and paste on row 16 (every page), step edits on rows 1-7. The voice's states over three rows: on/off row 14 (pages 1-2), mute row 9 (page 1), lock row 16 (every page), freeze page 4 column 12. Grid voice pick (row 14, pages 1-2) is far from what it serves (page 2's faders); on page 1 it serves nothing on that page.
- **Missing per page on the 256:** voice on/off and grid voice pick on pages 3-5 (row 14 belongs to the pad, voice 6's source row and voice 6's strip there).
- **Behind a hold or a combination only (no other grid key):** solo (mute key held 0.5 s, `:113-116`); pattern clear and randomize (0.5 s, `:269`); scene save (0.5 s); recorder clear (0.5 s); the step editor (0.3 s); a step's level (two keys); a loop from cells (two keys); bookmark store (ST held plus a bookmark); freeze on pages 1, 2, 3, 5 (FZ plus L). Copy then paste is a mode: once a pattern is copied, a press on another voice pastes, and copying a different voice needs KX first (`:450-456`; `docs/user/grid/256.md:53`).
- **The screen can, no grid page can:** reverb mix/size/damp, delay and reverb bypass (`delay_bypass`, `reverb_bypass`), `filter_type`, `filter_mix`, `delay_pingpong`, `delay_sync` on/off, `master_density`, `drift_amount`, scatter (`scatter_depth`, `scatter_rate`, its destinations), `morph_c`, `morph_d`, `scene_transition_time`, scene chances, the pattern chain (`seq_chain*`), `quantize_actions`, per-voice length, division, swing and gate (SEQ), voice randomize and undo (MAIN ALT+K2), the LFOs (`docs/user/grid.md:7`), matrix, envelopes, notes and MPE, record settings, file load and save, slices editing, the tape loop and IO. Until the groundwork: the voice filter, sends, loop, jitters, attack and release (they gain faders, section 1).
- **A grid can, the screen cannot:** pattern copy and paste (256 only; no copy on SEQ, grep of `lib/pages/*.lua`); fill held momentarily (the screen only latches it; a MIDI map of `seq_fill` can hold); tempo by ±10 (the screen steps it too, but not by a held key).
- **The global functions:** reverb none; master filter 256 page 4 (freq, res) only; bypasses none; macro banks 256 page 1 row 9, 128h/128v one cycling key, 64 none; morph 256 full (fader, A, B, pad), 128h/128v fader only, 64 none; scene banks: no grid needs a bank key (all sixteen scenes show at once; `SCENE_BANK_SIZE` only shapes the 256's and 128v's length keys); fill 256 and 128h, not 128v or 64; mutes and solos 256 only; lock 256, 128h, 128v, not 64; freeze 256, 128h, 128v, not 64.

### Free keys per page (dead keys, rows 8 and 16 included)

| Layout | Page | Free | Where |
|---|---|---|---|
| 256 | 1 | 7 | row 8: 10, 11; row 9: 12; rows 14, 15: 8, 16 |
| 256 | 2 | 22 - N (today 16-18, after the groundwork 14-15) | row 8: 10, 11; row 13: N+1..16; rows 14, 15: 8, 16 |
| 256 | 3 | 84 | row 4: 5-16; row 5: 2, 11-16; row 6: 1-2, 11-16; rows 11-15: 1-11; row 8: 10, 11 |
| 256 | 4 | 53 | rows 1-2: 9-16; rows 9-15: 11, 13-16; row 8: 10, 11 |
| 256 | 5 | 65 | rows 9-15: 5, 9-16; row 8: 10, 11 |
| 128h | 1, 5 | 0 | |
| 128h | 2 | 33 - N (today 27-29, after 25-26) | row 5: N+1..15; rows 6, 7: 8-16 |
| 128h | 3 | 27 | row 5: 2-12; row 7: 1-16 |
| 128h | 4 | 12 | column 11 rows 1-7 (a light, no key); row 6 col 16; row 7 cols 13-16 |
| 128v | 1, 5 | 0 | |
| 128v | 2 | 40 - N (today 34-36, after 32-33) | column 5 rows N+1..15; column 6; column 7 rows 1-9 |
| 128v | 3 | 27 | column 4 rows 2-8; column 5 rows 1-8; column 7 rows 5-16 |
| 128v | 4 | 26 | rows 11, 15, 16 columns 1-8; column 8 rows 10, 14 |
| 64 | steps | 0 | |
| 64 | positions | 26 | row 3 col 5; rows 4-6; row 7 col 8 |

N is the grid voice's fader page count. On the last fader page, rows past the voice's last fader are dead too.

## 3. The three smaller layouts

### The 128h (16x8): row 8 on every page

```
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 8   PL PL PL FL P1 P2 P3 P4 O1 O2 O3 O4 O5 O6 O7 NV

P4: on page 4 goes to page 5, on page 5 back to page 4   NV next grid voice (7 -> 1)
```

```
Page 1 (patterns)                                   Page 2 (faders)
      1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16       1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16
 1   st x16 (voice 1)                                1   fd x16 (or the bank's 1st macro)
 ..                                                  2   fd x16
 7   st x16 (voice 7)                                3   fd x16
                                                     4   fd x16
                                                     5   p1 p2 p3 p4 p5 p6 p7 p8 .. .. .. .. .. .. .. MK
                                                     6   V1 V2 V3 V4 V5 V6 V7 .. .. .. .. .. .. .. .. ..
                                                     7   L1 L2 L3 L4 L5 L6 L7 .. .. .. .. .. .. .. .. ..

Page 3 (scenes)                                     Page 4 (sources, freeze, slots, the grid voice's strip)
 1   ri x16                                          1   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz R1 R2 R3 R4
 2   rf x16                                          2   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz R5 R6 R7 R8
 3   sv x16                                          3   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz C1 C2 C3 C4
 4   ln x16 (length = column)                        4   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz C5 C6 C7 C8
 5   SQ .. .. .. .. .. .. .. .. .. .. .. G1 G2 G3 G4  5   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz k1 k2 k3 k4
 6   mo x16                                          6   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz ST HD WH ..
 7   .. x16                                          7   sy b1 b2 b3 b4 b5 b6 b7 b8 in gv fz .. .. .. ..
                                                     (row = voice; gv lights the grid voice's row, no key)
Page 5 (positions)
 1-7 ps x16 (row = voice; a press also picks the grid voice)

MK macro page key: shown bank, then the next three, then back to the voice's faders
R record slot   C clear slot
```

| Page | Row | Cols | Press | Hold / combination | LEDs | Handler |
|---|---|---|---|---|---|---|
| all | 8 | 1-3 | `pattern_toggle` | | 15/4 | `control_row_key` `layout_128h.lua:183-184`; LED `:354-356` |
| all | 8 | 4 | fill held, as the 256's | held | 15/4 | `fill_key` `:202-210`, first `:214-218`; LED `:357-358` |
| all | 8 | 5-8 | `set_page(1..4)`; col 8 toggles 4 and 5 | | 15 shown, 2 other; col 8 10 on page 5 | `:185-188`; LED `:359-365` |
| all | 8 | 9-15 | `toggle_voice` | | 12/6/2 | `:189-190`; LED `:366-368` |
| all | 8 | 16 | next grid voice (on page 2 leaves the macros first) | | 8 | `:191-195`; LED `:369` |
| 1 | 1-7 | 1-16 | `step_key` as the 256's | 0.3 s editor; level gesture | `step_brightness` | `:255-257` |
| 2 | 1-4 | 1-16 | `set_param_from_column(shown_fader_ids(port)[y], x)` | | bar | `fader_page_key` `:93-96`; `faders.lua:287-292`; LED `:264-269` |
| 2 | 5 | 1..N | leave the macros, `S.param_page = x` | | 15/4 | `:99-103`; LED `:270-272` |
| 2 | 5 | 16 | `macro_page_key(port)` | | 4 voice faders, 6/9/12/15 banks 1-4 | `:97-98`; `faders.lua:256-268, 278-281` |
| 2 | 6 | 1-7 | leave the macros, `select_grid_voice` | | 15/4 | `:104-108` |
| 2 | 7 | 1-7 | `toggle_lock` | | 12/2 | `:109-110`; LED `:276` |
| 3 | 1-3 | 1-16 | as the 256's rows 1-3 | save 0.5 s | core scene levels | `scene_page_key` `:159-168`; LED `:283-288` |
| 3 | 4 | 1-16 | `scene_sequence_length = x` | | 8/2 | `:169-171`; LED `:291-294` |
| 3 | 5 | 1 | sequencer on/off | | 15/4 | `:172-175` |
| 3 | 5 | 13-16 | recorders 1-4 (release passed on, `:227-228`) | 0.5 s clear | 2/5/10/15 | `:140-154`; LED `:300-302` |
| 3 | 6 | 1-16 | morph fader | | bar | `:155-157`; LED `:303` |
| 4 | 1-7 | 1-10 | `source_key(y, x)` | | 15/4/2 | `source_page_key` `:134-135`; LED `:309-313` |
| 4 | 1-7 | 12 | `freeze.toggle_quantized(y)` | | 15/3 | `:132-133`; LED `:314-315` |
| 4 | 1-2 | 13-16 | record slots 1-4, 5-8 | | 11/15/8/2 | `slot_key` `:68-79`; LED `:317-321` |
| 4 | 3-4 | 13-16 | clear slots 1-4, 5-8 | | 4 | same |
| 4 | 5 | 13-16 | the grid voice's bookmarks (bank keys on a slice row) | with ST: store | strip levels | `strip_key_of` `:117-125`, `:249-251`; LED `redraw_strip` `:326-337` |
| 4 | 6 | 13-15 | store, hold, whole (releases passed on, `:229-233`) | held | strip levels | same |
| 5 | 1-7 | 1-16 | `positions.grid_key(port, y, x, 16, z)`; picks the grid voice | two cells: loop | position levels | `:242-243, 224-226`; LED `:340-346` |

Record: `{key, redraw, selects_grid_voice = true, strip_page = 4, shows_modulation}` (`:399-403`).

### The 128v (8x16): column 8 on every page

```
Column 8 (rows):  1-7 O1..O7 voice on/off | 8 PG next page (1>2>3>4>5>1) | 9 PL play/stop
                  10-16: V1..V7 grid voice pick on pages 1-3; the strip on page 5;
                         page 4: row 12 r8, row 13 c8 (slot 8), the rest dead

     Page 1             Page 2                 Page 3                  Page 4                 Page 5
     1 2 3 4 5 6 7 8    1 2 3 4 5 6 7 8        1 2 3 4 5 6 7 8         1 2 3 4 5 6 7 8        1 2 3 4 5 6 7 8
 1   s s s s s s s O    f f f f p . . O        i r v Q . m G O         y y y y y y y O        c c c c c c c O
 2   s s s s s s s O    f f f f p . . O        i r v . . m G O         b b b b b b b O        c c c c c c c O
 3   s s s s s s s O    f f f f p . . O        i r v . . m G O         b b b b b b b O        c c c c c c c O
 4   s s s s s s s O    f f f f p . . O        i r v . . m G O         b b b b b b b O        c c c c c c c O
 5   s s s s s s s O    f f f f p . . O        i r v . . m . O         b b b b b b b O        c c c c c c c O
 6   s s s s s s s O    f f f f p . . O        i r v . . m . O         b b b b b b b O        c c c c c c c O
 7   s s s s s s s O    f f f f p . . O        i r v . . m . O         b b b b b b b O        c c c c c c c O
 8   s s s s s s s N    f f f f p . . N        i r v . . m . N         b b b b b b b N        c c c c c c c N
 9   s s s s s s s P    f f f f . . . P        i r v l l m . P         b b b b b b b P        c c c c c c c P
10   s s s s s s s V    f f f f . . L V        i r v l l m . V         n n n n n n n .        c c c c c c c k
11   s s s s s s s V    f f f f . . L V        i r v l l m . V         . . . . . . . .        c c c c c c c k
12   s s s s s s s V    f f f f . . L V        i r v l l m . V         R R R R R R R R        c c c c c c c k
13   s s s s s s s V    f f f f . . L V        i r v l l m . V         C C C C C C C C        c c c c c c c k
14   s s s s s s s V    f f f f . . L V        i r v l l m . V         z z z z z z z .        c c c c c c c S
15   s s s s s s s V    f f f f . . L V        i r v l l m . V         . . . . . . . .        c c c c c c c H
16   s s s s s s s V    f f f f M . L V        i r v l l m . V         . . . . . . . .        c c c c c c c W

s step (column = voice, row = step)  f upright fader (row 16 min, row 1 max)  p fader page key (rows 1-8 after the groundwork)
M macro page key  L lock voice row-9  i recall now  r recall with transition  v save (hold)  Q sequencer on/off
l length (column 4 rows 9-16 = 1-8, column 5 = 9-16)  m morph fader  G recorders 1-4 (column 7 rows 1-4)
y synth  b buffers 1-8 (rows 2-9)  n input (row 10)  R record slot  C clear slot  z freeze voice = column
c position cell (column = voice; the grid voice's column one level up)  k bookmark 1-4  S store  H hold  W whole
O voice on/off, N next page, P play/stop: column 8 rows 1-9 on every page
```

| Page | Where | Press | Hold / combination | LEDs | Handler |
|---|---|---|---|---|---|
| all | col 8 rows 1-7 | `toggle_voice(y)` | | 12/6/2 | `grid_key_128v_controls` `layout_128v.lua:134-135`; LED `:280-282` |
| all | col 8 row 8 | `set_page(page % 5 + 1)` | | 3/6/9/12/15 by page | `:136-137`; LED `:283` |
| all | col 8 row 9 | `pattern_toggle` | | 15/4 | `:138-139`; LED `:284` |
| 1-3 | col 8 rows 10-16 | `select_grid_voice(y-9)` (page 2: leave the macros) | | 15/4 | `:143-146`; LED `:285-289` |
| 1 | cols 1-7 | `step_key(port,x,y,z,x,y,y,16)` | 0.3 s editor; level = row of the second key | `step_brightness` | `:178-180` |
| 2 | cols 1-4 | `set_param_from_column(shown_fader_ids(port)[x], 17-y)` | | bar from row 16 | `:75-78`; LED `:194-206` |
| 2 | col 5 rows 1..N | leave the macros, `S.param_page = y` | | 15/4 | `:81-83`; LED `:212-214` |
| 2 | col 5 row 16 | `macro_page_key` | | 4/6/9/12/15 | `:79-80`; LED `:207` |
| 2 | col 7 rows 10-16 | `toggle_lock(y-9)` | | 12/2 | `:84-85`; LED `:208-211` |
| 3 | cols 1-3 | recall now / with transition / save | save 0.5 s | core scene levels | `grid_key_128v_scenes` `:104-110`; LED `:219-225` |
| 3 | col 4 row 1 | sequencer on/off | | 15/4 | `:111-113` |
| 3 | cols 4-5 rows 9-16 | length 1-8, 9-16 | | 8/2 | `:89-96, 114-115`; LED `:228-234` |
| 3 | col 6 | morph fader (17-y) | | upright bar | `:102-103`; LED `:236` |
| 3 | col 7 rows 1-4 | recorders (releases passed on) | 0.5 s clear | 2/5/10/15 | `:164-167`; LED `:237-239` |
| 4 | cols 1-7 rows 1-10 | `source_key(x, y)` | | 15/4/2 | `grid_key_128v_sources` `:120-121`; LED `:243-247` |
| 4 | row 12 cols 1-8, row 13 cols 1-8 | record, clear slot x | | 11/15/8/2; 4 | `:122-125, 148`; LED `:248-251` |
| 4 | row 14 cols 1-7 | `freeze.toggle_quantized(x)` | | 15/3 | `:126-127`; LED `:252-255` |
| 5 | cols 1-7 | `positions.grid_key(port, x, y, 16, z)`, picks the grid voice | two cells: loop | position levels, grid voice +1 | `:155-163`; LED `:261-268` |
| 5 | col 8 rows 10-16 | the grid voice's strip: k1-k4, store, hold, whole | ST + k: store | strip levels | `:140-142, 158`; LED `:269-272` |

Record: `{key, redraw, selects_grid_voice = true, shows_modulation}` (`:312-315`); it has no `strip_page` (its strip is on the position page).

### The 64 (8x8)

```
Steps views (page 1, half 1 or 2)          Positions view (page 5)
     1  2  3  4  5  6  7  8                     1  2  3  4  5  6  7  8
 1   st st st st st st st st  voice 1      1   ps ps ps ps ps ps ps ps   grid voice cells 1-8
 2   st ...                                2   ps ps ps ps ps ps ps ps   cells 9-16
 3   st ...                                3   k1 k2 k3 k4 .. ST HD WH
 4   st ...                                4   .. .. .. .. .. .. .. ..
 5   st ...                                5   .. .. .. .. .. .. .. ..
 6   st ...                                6   .. .. .. .. .. .. .. ..
 7   st ...  voice 7                       7   V1 V2 V3 V4 V5 V6 V7 ..
 8   PH O1 O2 O3 O4 O5 O6 O7               8   PH O1 O2 O3 O4 O5 O6 O7

st step (half - 1) * 8 + column   PH tap: play/stop at release; hold 0.5 s: next view (1-8 > 9-16 > positions > 1-8)
```

| View | Where | Press | Hold / combination | LEDs | Handler |
|---|---|---|---|---|---|
| all | row 8 col 1 | play/stop at release | 0.5 s: `switch_half` (consumed) | steps views: stopped 4 (half 1) / 8 (half 2), 15 playing in the shown half, 12/3 by beat in the other; positions view 15/6 | `play_key` `layout_64.lua:83-94`, `switch_half` `:66-77`; LED `:138-147, 176-177` |
| all | row 8 cols 2-8 | `toggle_voice(x-1)` | | 12/6/2 | `:128-131`; LED `:197-199, 178-180` |
| steps | rows 1-7 | `step_key(port,x,y,z,y,(half-1)*8+x,x,8)` | 0.3 s editor; level = col*15/8 | `step_brightness` | `:124-127`; LED `:189-193` |
| positions | rows 1-2 | the grid voice's 16 cells | two cells: loop | position levels | `positions_key` `:101-103`; LED `:157-162` |
| positions | row 3 | k1-k4, store (6), hold (7), whole (8) | ST + k | strip levels | `:104-106`; LED `:163-166` |
| positions | row 7 cols 1-7 | `select_grid_voice(x)` | | 15 grid voice, 6 a buffer voice, 2 other | `:107-108`; LED `:170-175` |

Record: `{key, redraw, selects_grid_voice = true, rows_show_grid_voice = true}` (`:206-207`).

### Every function of the 256, on the smaller layouts

| 256 function (where) | 128h | 128v | 64 |
|---|---|---|---|
| steps, level, step editor (p1/p2 rows 1-7) | p1 rows 1-7 | p1 cols 1-7, step = row | rows 1-7, one half |
| play/stop (row 8, 1-4) | row 8, 1-3 | col 8 row 9 | row 8 col 1, tap |
| tempo ±1, ±10 (row 8, 5-8) | missing | missing | missing |
| fill held (row 8, 9) | row 8 col 4 | missing | missing |
| page keys (row 8, 12-16) | row 8, 5-8 (page 5 through col 8) | col 8 row 8, cycle | row 8 col 1 hold, cycle |
| mute, solo (p1 row 9) | missing | missing | missing |
| recorders (p1 row 9, p3 row 4) | p3 row 5, 13-16 | p3 col 7 rows 1-4 | missing |
| macro banks + faders (p1 rows 9-13) | p2 macro key (row 5 col 16), rows 1-4 | p2 macro key (col 5 row 16), cols 1-4 | missing |
| voice faders, fader pages (p2 rows 9-13) | p2 rows 1-5 | p2 cols 1-5 | missing |
| grid voice pick (p1/p2 row 14) | p2 row 6; row 8 col 16 (next); a position press | col 8 rows 10-16 (p1-3); a position press | positions view row 7; a position press |
| voice on/off (p1/p2 row 14) | row 8, 9-15, every page | col 8 rows 1-7, every page | row 8, 2-8, every page |
| pattern clear, randomize (row 15) | missing | missing | missing |
| lock (row 16) | p2 row 7 | p2 col 7 rows 10-16 | missing |
| freeze (p4 col 12; row 16 + col 8) | p4 col 12 | p4 row 14 | missing |
| pattern copy, paste (row 16) | missing | missing | missing |
| scene recall now, with transition, save (p3 rows 1-3) | p3 rows 1-3 | p3 cols 1-3 | missing |
| scene sequencer on/off (p3 row 5 col 1) | p3 row 5 col 1 | p3 col 4 row 1 | missing |
| sequence length (p3 rows 5-6) | p3 row 4, one row | p3 cols 4-5 rows 9-16 | missing |
| morph fader (p3 row 7) | p3 row 6 | p3 col 6 | missing |
| morph A, B (p3 rows 9-10) | missing | missing | missing |
| XY pad (p3 rows 11-15) | missing | missing | missing |
| record, clear slots (p4 rows 1-2) | p4 cols 13-16 rows 1-4 | p4 rows 12-13 | missing |
| FX faders (p4 rows 3-7) | missing | missing | missing |
| sources (p4 rows 9-15) | p4 rows 1-7 cols 1-10 | p4 cols 1-7 rows 1-10 | missing |
| positions (p5 rows 1-7) | p5 rows 1-7 | p5 cols 1-7 | positions view, grid voice only |
| bookmark strips, one per voice (p5 rows 9-15) | one, the grid voice's, on p4 | one, the grid voice's, on p5 col 8 | one, the grid voice's, row 3 |

Pages: the 256 1-5; the 128h 1-5 (5 only through page 4's key); the 128v 1-5; the 64 1 (two halves) and 5.

What a smaller layout does that the 256 does not: voice on/off on every page (all three); a "next voice" key (128h row 8 col 16); a position press picks the grid voice (`selects_grid_voice`, `positions.lua:575`); one strip that follows the grid voice, and store follows a voice picked while held (`positions.lua:637-651`); the sources and the strip on one page (128h page 4); the sequence length on one row of sixteen (128h); the grid voice's column one level brighter on positions (128v, `layout_128v.lua:263-266`); a page key whose brightness tells the page (128v); a play key that also tells the half and the beat (64).

## 4. The machinery a rework edits

**Registration and choice.** Each layout file sets `S.registry.grid_layouts["<name>"] = {key, redraw, ...}` at include (`layout_256.lua:656-662`, `layout_128h.lua:399-403`, `layout_128v.lua:312-315`, `layout_64.lua:206-207`); `strata.lua:162-167` includes core, faders and the four layouts. `grid_layout(grid_port)` matches the exact size (`core.lua:528-540`: 16x16 "256", 16x8 "128h", 8x16 "128v", 8x8 "64", else nil); `layout_of(port)` gives the record (`:546-549`). Optional record fields: `fx_faders_page` (256 only, read by `any_fx_faders`, `:554-560`), `shows_modulation(port)` (`any_modulation_shown`, `:567-573`, which the drift tick reads), `selects_grid_voice`, `rows_show_grid_voice` (read by `positions.lua:533-545, 949-952`), `strip_page` (read by `playheads.lua:241-251`).

**Dispatch.** `grid_key(port, x, y, z)` (`core.lua:846-863`): bounds check, `follow_size`, `handle_key` in an `xpcall` (`:826-836`: a press is recorded held then passed to `layout.key(port,x,y,1)`; a release cancels the key's hold, reaches the layout unless consumed, then `release_step_key` toggles a held step), `release_key` in its own `xpcall`, then one `grid_redraw()` and `request_redraw()`. `grid_redraw()` (`:881-899`) clears, calls `layout.redraw(port, grid_device)` contained per port, refreshes; it does nothing while a key is being handled (`key_repaint`, `:824`).

**Per-port state.** `page(port)` / `set_page(port, page)` (`:74-93`; a change ends the port's step gestures and holds and forgets key roles); `S.grid_pages[port]`; `S.grid_held[port][x][y]` = press time (`:109, 134-136`); local `hold_clocks`, `consumed_keys`, `step_keys`, `key_roles`, `port_states` (`:110-117`); `port_state(port)` (`:154-157`: the 256's clipboard, the 64's half, the 128s' `macro_faders` count) and `existing_port_state` (`:161-163`); `forget_port` (`:248-257`) on add, remove, reconcile, rotation, cleanup. Shared, not per port: `S.param_page`, `S.grid_voice_select` (`:35-36`).

**Key helpers.** `step_key` (`:330-348`), `end_step_gestures` (`:361-371`, from `sequencer.lua:1507`'s `replace_pattern`), `end_port_step_gestures` (`:378-384`), `scene_save_key` (`:388-393`), `on_hold(port,x,y,seconds,fn)` (`:174-185`), `hold_pending`, `consume`/`consumed`, `press_as`/`pressed_as` (`:234-243`), `gesture_key`/`gesture_level` (`:429-447`), `source_key`/`source_level`, `record_key`/`record_level`, `clear_key`/`CLEAR_LEVEL` (`:489-523`), the shared levels `LEVELS` (`constants.lua:182-183`), `voice_level`, `lock_level`, `play_level`, `scene_recall_level`, `scene_fade_level`, `scene_save_level` (`:412-482`). Globals the layouts call: `toggle_voice`, `toggle_lock` (`engine_sync.lua:649, 668`), `pattern_toggle`, `clear_pattern`, `randomize_pattern`, `step_brightness`, `toggle_pattern_step` (`sequencer.lua:1555, 1511, 1516, 1790, 1473`), `record_buffer` (`record.lua:149`), `clear_buffer` (`buffers.lua:508`), `set_binary_param` (`ui/params.lua:40`), `header_flash` (`ui/flash.lua:99`), `recall_scene` (`scenes.lua:688`).

**Which layout uses which helper.**

| Helper | 256 | 128h | 128v | 64 |
|---|---|---|---|---|
| `step_key`, `voice_level`, `set_page` | yes | yes | yes | yes |
| `scene_save_key`, scene levels, `gesture_key`/`level`, source/record/clear keys and levels, `lock_level`, `play_level`, `LEVELS` | yes | yes | yes | no |
| `on_hold` (own use) | mute, row 15 | no | no | play key |
| `press_as`/`pressed_as` (own use) | mute, fill | fill | no | no |
| `held`, `consume` (own use) | tempo LED, FZ; mute | no | no | play key |
| `hold_pending` | row 15 | no | no | no |
| `port_state` | clipboard | (via faders.lua) | (via faders.lua) | half |
| `end_port_step_gestures` | no | no | no | half switch |
| faders: `set_param_from_column`, `fader_page_count` | yes | yes | yes | no |
| faders: `grid_redraw_fader_row` | yes | yes | no (own upright draw from `fader_position`) | no |
| faders: `set_fader_param`, `grid_redraw_faders`, `shown_macro_ids`, `set_param_fraction`, `fx_fader_id` | yes | no | no | no |
| faders: `shown_fader_ids`, `macro_page_key`, `leave_macros`, `macro_page_level`, `shows_modulation` | no | yes | yes | no |
| faders: `fader_page_level` | (through `grid_redraw_faders`) | yes | yes | no |

**How redraws are driven.** Every key repaints once (`core.lua:860`). State that changes elsewhere calls `grid_redraw()` from its own module (60 calls in 23 files under `lib/`, measured by grep; scenes 10, sequencer 6 per step and stop, mutation 4, macros 3, params_setup 3). Gated redraws: the FX faders through `fx_fader_changed` while `any_fx_faders()` (`params_setup.lua:58`, `delay_sync.lua:121`); the sources page through `any_page(GRID_PAGES.sources)` (`buffers.lua:830`); the position page and `strip_page` from the playheads' 15 Hz clock when `display_signature` changes (`playheads.lua:241-263`) and from the peaks read (`waveforms.lua:111, 130`); the fader pages, macro faders and morph from the 10 Hz drift tick (`mutation.lua:295` calls `follow_faders`, `faders.lua:224-236`, comparing `faders_signature` and `modulation_signature`).

**Sizes (measured).**

| File | Lines | Test file | Lines | Tests | Literal-coordinate calls (lower bound) |
|---|---|---|---|---|---|
| `lib/grid/core.lua` | 957 | `grid_core_test.lua` | 1751 | 73 | 227 |
| `lib/grid/faders.lua` | 325 | (in the 256's file) | | | |
| `lib/grid/layout_256.lua` | 665 | `grid_layout_256_test.lua` | 1575 | 53 | 299 |
| `lib/grid/layout_128h.lua` | 406 | `grid_layout_128h_test.lua` | 1080 | 41 | 150 |
| `lib/grid/layout_128v.lua` | 318 | `grid_layout_128v_test.lua` | 884 | 31 | 111 |
| `lib/grid/layout_64.lua` | 210 | `grid_layout_64_test.lua` | 667 | 24 | 117 |

Notes: `grid-core.md` 180 lines, `layout_256.md` 99, `layout_128h.md` 30, `layout_128v.md` 33, `layout_64.md` 22. User pages: `grid.md` 92, `grid/256.md` 94, `grid/128h.md` 47, `grid/128v.md` 46, `grid/64.md` 26. `docs_test.lua:1947-1971` requires one `docs/user/grid/<key>.md` per registered layout and no other.

Tests outside the grid files that press or read keys on a plugged grid (count of `grid.press(`/`get_led(` lines): `params_setup_test` 13, `stubs_test` 13 (on a 16x8), `positions_test` 9, `strata_test` 1 line (9 literal calls), `pages_seq_test` 6 (16x8), `arc_pages_test` 6, `mutation_test` 4, `playheads_test` 2, `buffers_test`, `midi_in_test`, `ui_test`, `system_37_test` 1 each. `ui_layout_test`, `pages_setup_test`, `waveforms_test`, `io_remote_test` and others plug grids without pressing keys.

## 5. Who else depends on the coordinates

- **`lib/io/controllers.lua`**: no grid code (grep). **`lib/io/remote.lua`**: sizes only (`REMOTE.sizes`, `:19`), the iii protocol's `stride = 16` (`:30-31`), and the midigrid attach; it never names a page or a key.
- **The iii scripts**: `iii/strata_grid.lua` (65 lines) forwards each key as a note (`index = (y-1)*16 + (x-1)`) and sets each LED from a note (`:40-62`); it mirrors nothing of a layout. `iii/strata_arc.lua` (75 lines) is the arc's.
- **midigrid**: the mod's grid attaches by its size (default 16x8, the 128h); with one 8x8 Launchpad on a 128 or 256 layout, the mod's top-row buttons choose which 8x8 quarter shows (quoted, `docs/user/io/remote.md:46, 50`; unverified). A key group that crosses column 8/9 or row 8/9 is split between quarters there; the 256's row 8 is the last row of the top quarters.
- **Page numbers by name**: `playheads.lua:18` (`POSITION_PAGE = GRID_PAGES.positions`) and `:247` (`strip_page`); `waveforms.lua:25`; `buffers.lua:830` (`GRID_PAGES.sources`); `positions.lua:39` (`position_cells`). `grid_core_test.lua` refuses `any_page(<digit>` outside `lib/grid/` (`docs/notes/lua/grid-core.md:11`). `params_setup.lua:965-966` clamps `S.param_page` on a source change.
- **User docs with coordinates**: `docs/user/grid.md` (lines 16, 20, 29-35, 79-81), `docs/user/grid/*.md`, `docs/user/scenes.md:27, 36, 51`, `docs/user/sequencer.md:47` (the fill keys), `docs/user/modulation.md:61` (the pad), README.md:20 (the pad). `docs/user/controls.md` names no coordinate.

## 6. The arc beside it

The rings follow the screen page, never the grid page.

| Screen page | Rings 1-4 | With ALT | Free |
|---|---|---|---|
| MAIN | density, the voice's main param, grain size (pitch for input), grain density | grain pitch, spread, level, pan (`lib/arc/main.lua:12`) | none |
| VOICE | four rows of the voice's list around the cursor (`docs/user/arc.md:25`) | none | new per-voice rows get rings with no arc code |
| SEQ | step cursor, level, tempo, voice; the step editor's position, pitch, size, probability | editor: ratchets, note, bookmark, level | none |
| FX | filter freq, res, delay time (division when synced), delay mix (`lib/arc/fx.lua:14-19`) | none | the whole ALT layer; no ring for delay feedback, ping-pong or the reverb |
| LFO | depths of three LFOs, the selected LFO's rate | none | the ALT layer |
| MOD | the bank's four macros; routing depths; target and routing views | morph, scatter depth, scatter rate, morph B | none |
| BUFFER | buf pos, loop start, loop length, scan; slice editor rings | buf pos (scan held), buf rate, scrub friction, record feedback (`lib/arc/buffer.lua:16-27`) | none |
| SCENES | cursor, transition time, morph, morph B | none | the ALT layer |
| SETUP | off | | four rings |
| IO | tape level, speed, feedback, wear (`lib/arc/io.lua:10-15`) | none | the ALT layer |

For 3.8: shimmer, delay freeze and any reverb control would find the FX page's ALT layer empty; the voice type, presets and the pan wander depth would reach the arc through VOICE's rows; a scale editor's twelve pitch classes have no ring precedent (every ring is a param, a cursor or a step).

## Where the roadmap or the notes are wrong or silent

- `docs/design/3.7-facts/revisit.md:142` and ROADMAP.md:162: "freeze behind a hold" holds for pages 1, 2, 3 and 5 only; page 4's column 12 freezes with a press (`lib/grid/layout_256.lua:384-385`).
- ROADMAP.md:162 lists five observations and is silent on row 14: voice on/off and the grid voice pick are on pages 1-2 only (`layout_256.lua:394-417`), while every smaller layout has voice toggles on every page.
- `docs/user/grid/256.md:40-42` ("Row 14: Voice Selection & Status") gives no page qualifier, unlike row 15's "(pages 1 and 2)" (`:44`); on pages 3-5 row 14 is the pad (columns 12-16), voice 6's source row and voice 6's strip.
- `revisit.md:143` gives 636 and 1,453 lines; the files are 665 and 1,575 lines today (`wc -l`).
- After the groundwork's 2a, `docs/user/grid/256.md:38` ("Columns 1-4, 1-5 or 1-6 ... Folder and Sub have 5 pages, the other voices 6"), `docs/user/grid/128h.md:112` ("columns 1-4, 1-5 or 1-6 light") and `docs/notes/lua/grid-core.md:158` ("Voices have 4-6 fader pages") become false; the plan's 2a docs list names `256.md:33-34` and `grid-core.md:41, 153-155` only (`docs/superpowers/plans/2026-11-16-3.8-groundwork-plan.md:369`, `plan-2a-records.md:54-63`).
- `docs/notes/lua/grid-core.md:147` ("Every layout handles releases on its position page ...; elsewhere `z == 0` returns at once") is out of date: the 256's page 1 row 9 and page 3 row 4, both fill keys, the 128h's page 3 recorders and page 4 strip, the 128v's scenes recorders and the 64's play key handle releases (`layout_256.lua:298-326`, `layout_128h.lua:214-237`, `layout_128v.lua:164-167`, `layout_64.lua:115-117`).
- `docs/notes/lua/grid-core.md:84` says `set_page` takes ports `1..MAX_GRID_PORTS`; it also takes the virtual ports 5 and 6 (`core.lua:69-71, 86`), as `:27` of the same file says.
- `docs/user/grid.md:7` ("no layout has room for [LFO controls]") is a judgment the free-key counts above do not support for the 256 (55 dead keys in one block on page 3).
- The roadmap's 3.8 section (ROADMAP.md:137-140, 168-170) names "the keys on VOICE and the grids" for presets and "a key on FX and the grids" for the delay freeze and clear, and is silent on the 128s and the 64 having no FX on any page (`docs/notes/lua/grid/layout_256.md:99`) and the 64 having no per-voice keys beyond on/off.
- ROADMAP.md:124's scale editor is "a screen and a stored mask"; it is silent on the grids, where twelve pitch-class keys need a row of twelve (the 256 pages 3, 4, 5 have rows with twelve or more free keys; the 128s and the 64 have none without moving keys).

## Unsure

- What a midigrid Launchpad really shows of a 256 layout: quoted from `docs/user/io/remote.md:50`, which is built from midigrid's source, not checked on a device; the mod's source is not in the repository.
- The literal-coordinate counts are `grep` counts of calls with numeric arguments (`press(...)`, `get_led(...)`, `grid.press(port, x, y, z)`); keys pressed through loop variables or tables are not counted, so the true number of pinned coordinates is higher.
- The post-groundwork fader page counts are the plan's (ruling 12) and `plan-2a-records.md:217-226`, not code: 2a has not landed on any branch I could read (only `feat/groundwork-0a-locked` exists, and it touches one line of `lib/grid/core.lua`).
- How much the 256's faders, pad and row 15 are played is not knowable from the code.
- Whether `lib/arc/scenes.lua`, `lfo.lua` and `io.lua` could take an ALT layer without a core change: `lib/arc/main.lua`, `buffer.lua` and `mod.lua` read `S.alt_held` themselves, so it looks local to each page file, but I did not read `lib/arc/core.lua` for an ALT dispatch rule.
