# Facts: the pattern chain and the scene sequencer

**Read this first.** The "pattern chain" does not chain patterns. Strata has no pattern store: patterns live in `S.patterns` and, saved, only in scenes (`lib/scenes.lua:377-381`; no side file holds them). The chain (`seq_chain`, "Chaining" in `docs/user/sequencer.md:59`) steps through a range of **scene slots**, as the scene sequencer does, and loads only each scene's sequencing part: its patterns, its `steps` block and each voice's `seq_length`, `seq_division`, `seq_direction` and `seq_misstep` (`lib/sequencer.lua:1164-1178`, `SEQ.chain_keys` at :55). So these are two scene steppers over the same sixteen slots. One applies the whole scene on a time clock. The other applies a sequencing subset on the pattern clock.

## 1. The pattern chain

- **Added:** 3.4, design §8.8 and Question 19 (`docs/design/3.4-design.md:33`, :221-223, :737-739). "Scene ranges" was chosen over "an explicit chain list with its own editor" (:33). CHANGELOG 3.4 is at `CHANGELOG.md:364`. 3.7 added the chances (`CHANGELOG.md:47`, `docs/design/3.7-design.md:472`) and the direction and misstep keys (`CHANGELOG.md:46`).
- **State:** a local `chain = {current, next_beat}` (`lib/sequencer.lua:145`). It has no field of `S`. It never sets `S.current_scene` and has no accessor (grep for `chain.current` finds only :1168, :1182, :1582, :1612).
- **Clock:** none of its own. `at_beat` runs at the start of every voice step and every transport 16th (`lib/sequencer.lua:1188-1193`, :1279, :1321). Whichever participant reaches the bar first makes the link.
- **What advances it:** every `seq_chain_bars` × `SEQ.bar_beats` beats while the patterns play (:1190). It starts with `pattern_clock_start`, which links the range's first populated, valid scene with no draw (:1582-1586). Switching `seq_chain` on while the patterns play links at the next bar (:1611-1614). A followed transport start restarts the chain from `seq_chain_from` (:1710).
- **Next item:** `next_chain_scene` (:1146-1162) calls `S.lib.chance.pick` over the range's populated slots. Only the picked slot is validated. An invalid pick walks on to the next valid slot with `linkable_from` (:1128-1134), which is #738. A `"repeat"` move links nothing (:1181-1184).
- **Params:** 7, all in group `strata_seq`: `seq_chain`, `seq_chain_from`, `seq_chain_scenes`, `seq_chain_bars` (1-16, `SEQ.max_chain_bars`) and `seq_chain_next`/`_previous`/`_random` (:1621-1633). PSETs store them and scenes do not (`docs/user/params.md:81`).
- **Limits:** a range of 1-16 slots starting anywhere, wrapping past 16 (:1114-1120). Links come every 1-16 bars.
- **Screen:** the `chain` section of SEQ's edit view, opened by holding ALT+K2: 7 rows plus `quantize` (`lib/pages/seq.lua:102-109`, `docs/user/pages/seq.md:28`). E3 sets a value. There is no display of which scene the chain is on.
- **Grid:** no key on any layout (grep for `seq_chain` in `lib/grid/` finds nothing). **Arc:** no ring.
- **Docs:** `docs/user/sequencer.md:59-62` (243 words), `docs/user/params.md:83-84`, `docs/notes/lua/sequencer.md:92-95` (276 words) and seven other lines there.

## 2. The scene sequencer

- **Added:** before 2.0. The 2.0 changelog already lists fixes to it (`CHANGELOG.md:1102-1106`, :1215). Later additions: 3.0 waits for transitions (:858-859), 3.3 lights the next scene on the grids (#303, :604), 3.4 extended it to 16 slots (`docs/design/3.4-design.md:847`), and 3.7 added the chances (`docs/design/3.7-design.md:470`).
- **State on `S`:** `scene_sequencer_position`, `_enabled`, `_recall_due`, `_next` and `_clock` (`lib/scenes.lua:39-49`), plus a local `SEQUENCER_DRAW` (:843).
- **Clock:** its own `clock.run` loop (`lib/scenes.lua:975-997`). It holds each scene for `max(scene_duration, transition_time)` seconds with `clock.sleep` (:951-952), then waits for the transition to end (:819-828).
- **What advances it:** the end of a hold. The next slot is drawn once, right after the recall (`draw_next_scene`, :857-873), and kept. It is redrawn only if it can no longer play (`kept_next_scene`, :880-887).
- **Next item:** `S.lib.chance.pick` over the populated slots of 1..`scene_sequence_length`. `slot_plays` (:847-849) tests only `populated`, not validity. An empty slot is skipped at once (`first_scene_from`, :833-839).
- **What a step does:** a full `recall_scene` with the transition time (:933). That covers every voice param, sources, active and lock states, patterns, the steps block, extras, tempo, effects and LFOs (`docs/notes/lua/scenes.md:57-66`).
- **Params:** 7 in `strata_scenes` (`lib/params_setup.lua:389-450`): `scene_sequencer_enabled`, `scene_transition_time` (also used by manual recalls), `scene_duration` (4-120 s), `scene_sequence_length` (1-16, default 4) and `scene_chance_next`/`_previous`/`_random`. PSETs store them and scenes do not.
- **Limits:** the range always starts at slot 1. Time is in seconds, never synced to the tempo.
- **Screen:** SCENES' seven fields (`S.constants.SCENES_FIELDS`, `lib/constants.lua:114-115`). They are shared with `lib/arc/scenes.lua` and `lib/ui/cursors.lua` (23 stops). A `>` marks the position (`lib/pages/scenes.lua:152`), and the header's `S<n>` brightens while it runs (`lib/ui/header.lua:107`).
- **Grid:** the 256 has the on/off toggle at row 5 column 1 and the length on rows 5-6, columns 3-10 (`lib/grid/layout_256.lua:354-359`). The 128h has the length on row 4 and the toggle at row 5 column 1 (`lib/grid/layout_128h.lua:169-175`). The 128v has the toggle at column 4 row 1 and the length in columns 4-5, rows 9-16 (`lib/grid/layout_128v.lua:111-115`). The 64 has nothing. All three larger layouts light the next scene at 10 (`S.lib.scenes.sequencer_next_slot`, `lib/scenes.lua:1453-1464`).
- **Arc:** no ring of its own. SCENES' ring 2 is the transition time (`lib/arc/scenes.lua:43`).
- **Other:** it has an invariant (`lib/scenes.lua:1470-1486`) and cleanup step 100 (`lib/constants.lua:276`).
- **Docs:** `docs/user/scenes.md:40-53` (684 words), `docs/user/pages/scenes.md:5`, `docs/user/params.md:130-134`, the grid pages, and `docs/notes/lua/scenes.md:217-275` (1,164 words).

## 3. Overlap and difference

| | Pattern chain | Scene sequencer |
|---|---|---|
| Steps through | scene slots `from..from+n-1`, wrapping | scene slots `1..length` |
| Applies | patterns, steps block, 4 seq keys per voice | the whole scene, with a crossfade |
| Unit of time | bars (1-16) on the pattern clock | seconds (4-120), its own clock |
| Next item | `S.lib.chance.pick`, drawn at the link | `S.lib.chance.pick`, drawn ahead and kept |
| Validation | validates the pick, walks on (#738) | none in the draw; `recall_scene` refuses an invalid scene (`lib/scenes.lua:697-700`) |
| Transport | runs only while the patterns play; a followed start restarts it | ignores the transport and the patterns |
| Quantize | own bar count, never `S.lib.quantize` | never quantized (`docs/notes/lua/scenes.md:35`) |
| Error | a link's error reaches the clocks' `guarded` and stops the patterns (`lib/sequencer.lua:1339`, :1439) | a recall error is printed and it goes on; any other error stops it through its param (:932-937, :988-995) |
| Stop | the pattern stop drops `next_beat` (:1602); `current` resets at the next start | `scene_sequencer_stop` (:1000-1010); the position resets to 1 at start |
| Shown | nowhere while it runs | `>` on SCENES, header brightness, grid light |
| Storage | 7 PSET params | 7 PSET params |

A scene stores patterns (`data.patterns`), the `steps` block and the seq extras, so a recall replaces patterns through `replace_pattern` (`lib/scenes.lua:526-527`). No scene stores the chain's settings. The `sequences` block in scenes.data holds 3.7's random modulation sequences (`lib/random_sequences.lua:11-13`), not patterns.

## 4. How they interact

- Both can run at once. Nothing couples them: there is no `seq_chain` in `lib/scenes.lua` and no `scene_sequencer` in `lib/sequencer.lua`. Each writes `S.patterns` through `replace_pattern`, and the last writer wins. Morph is a third writer (`docs/notes/lua/morph.md:57`).
- A recall during a running chain leaves `chain.current` alone, and the next link replaces the recalled patterns. A recall also sets the tempo, and so the chain's bars (inferred).
- No test runs both together. `sequencer_test.lua` never touches `scene_sequencer`, and `scenes_test.lua` never touches `seq_chain`. `system_37_test.lua:101-104` only checks that both default to 100/0/0.
- Docs that list both side by side: `docs/user/grid.md:29` ("a scene recall, the scene sequencer's next scene, a chain link: while the chain plays, the editor stays open at most until the next link") and :30. `docs/user/sequencer.md:61` says: "Nothing else of the scene is applied: the sound, the sources and which voices run stay as they are." `docs/user/params.md:81` names it "the pattern chain". No user page explains the two against each other.
- A third walker exists: `S.lib.io_actions.next_scene` (`lib/io/actions.lua:55-62`) recalls the next saved slot after `S.current_scene`.

## 5. Shared code

- **Shared:** `S.lib.chance.pick` only (`lib/chance.lua`, 98 lines, 3 tests). Neither uses `lib/quantize.lua` or `lib/conditions.lua`; a link and a recall both keep the pass count (`docs/notes/lua/conditions.md:5`). They share no clock helper.
- **Duplicated** (code lines, comments left out):

| Job | Chain (`lib/sequencer.lua`) | Sequencer (`lib/scenes.lua`) |
|---|---|---|
| list of slots | `chain_slots` (7 lines) | inline in `draw_next_scene` |
| playable test | `populated` (1) + `validate_scene` | `slot_plays` (3) |
| skip to the next playable slot | `linkable_from` (7) | `first_scene_from` (7) |
| draw | `next_chain_scene` (17) | `draw_next_scene` (17), `kept_next_scene` (8), `forget_next_scene` (3) |

The regions are about 50 lines (`lib/sequencer.lua:1111-1162`) and 62 lines (`lib/scenes.lua:830-891`).

## 6. What each alternative changes

**(a) One mechanism with two front ends.** A shared stepper replaces the regions above (about 112 lines). The clocks stay different, bars against seconds, and so do validation (walk on, against refuse and hold) and draw-ahead against draw-at-link. No param, page, grid key or data file needs to change. Tests to adjust: `sequencer_test.lua` (11 of 131 mention the chain), `scenes_test.lua` (35 of 103 mention the sequencer or its params) and `chance_test.lua` (3). Docs: `docs/notes/lua/chance.md` (23 lines), with the notes sections above.

**(b) One chain whose links name a scene and/or a pattern set.**
- **Storage:** no store for links exists today, since links are implied by slot ranges. One is needed: a new data file, a PSET side file through `S.lib.side_files`, or a scenes.data field (`SCENE_DATA_VERSION` 8, `lib/constants.lua:11`). A "pattern set" separate from a scene does not exist.
- **Params:** 14 to replace or merge (7 + 7; `scene_transition_time` is also used by every manual recall).
- **Time:** seconds and bars must be reconciled.
- **Pages:** SEQ's chain section (7 rows) and SCENES' 7 fields with their 23 stops (`lib/pages/scenes.lua` 426 lines, `lib/arc/scenes.lua` 56, `lib/ui/cursors.lua` 117). 3.4 rejected an explicit list with an editor (`docs/design/3.4-design.md:33`).
- **Grid:** the toggle and length keys and the next light on the 256 (665 lines), 128h (406) and 128v (318). The 64 has none, and the chain has none anywhere.
- **Tests:** those in (a), plus `grid_layout_256_test` 5, `128h` 3, `128v` 4, `pages_scenes_test` 4, `pages_seq_test` 5, `system_37_test` 3 of 5, `params_setup_test` 1, `strata_test` 1, and `structure_test.lua:416, 824, 837, 894, 914` (the clock and cleanup lists).
- **Docs:** everything in 1 and 2, plus six Must-not-break items in `docs/notes/lua/scenes.md` (:16-35).

**(c) Names, pages and docs only.** The code stays. The surfaces differ today: "chain" on SEQ and in PARAMETERS > sequencer, "scene sequencer"/`seq` on SCENES and in PARAMETERS > scenes, three chances with the same meaning under two prefixes (`seq_chain_*`, `scene_chance_*`), and SEQ shows `random` where SCENES shows `rand`. The files are the user pages `sequencer.md`, `scenes.md`, `params.md`, `pages/seq.md`, `pages/scenes.md` and `grid.md`. Renaming a param id breaks PSETs and MIDI maps (inferred; the norns convention). Labels can change freely.

## 7. 3.8 and #738

- **3.8** (`ROADMAP.md:110-169`): voice types make a recall change a voice's type (:118), so the scene sequencer carries it and the chain does not. Voice presets leave the pattern out, by design question (:138-139). The 256 rework (:159-161, `revisit.md` 13) cites "the scene sequence's length on two rows" and will place the new keys; the chain has none. 3.8's factory-presets code (:163-165) has no stated link to either.
- **#738** (`docs/status.md:15`, `docs/decisions/3.7.md:129`) is on the **chain** side, not the scene side. On the scene side, from code reading: the draw does not leave out invalid saved slots, which goes against design §5.4's "empty and invalid slots are not in the list" (`docs/design/3.7-design.md:467`). A pick of an invalid scene is refused by `recall_scene`, which prints `error: scene n has invalid data`, and the sequencer holds it for its duration with nothing applied. The only related test is #48's (`scenes_test.lua:571`); none pins a chance draw landing on an invalid scene.

## Unsure

- Whether PSETs or any exit save keep the live patterns. I found no code that does (I checked `S.patterns` users and `S.lib.side_files` users).
- The tempo-to-chain effect is inferred, not tested.
- The test counts are tests whose body names the feature. They are rough.
