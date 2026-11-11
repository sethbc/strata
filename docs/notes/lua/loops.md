## Must not break

- **The start stops at 0.999 and the length at `1 - start`.** The start's param filter clamps it before it is stored or sent, and its action cuts a length that no longer fits, so an edit never sends the engine a start past 0.999 or a pair past the slot's end. Moving the start back never restores a cut length.
- **A recall or transition ends at the scene's loop.** Scenes set the registered fields in sorted key order (#531, `docs/notes/lua/scenes.md`), so `loop_length` comes before `loop_start`. The length's filter therefore stands down while `S.scene_recall_in_progress` or `S.scene_transition_active`: clamped to the old start's room, a recall from (0.5, 0.5) to (0, 1) would end at (0, 0.5). The start, set after the length, has the last word: when it changes, its action cuts a length it leaves no room for. If scenes ever set the extras in another order, revisit this (a test pins the order: the engine hears `loopLength`, then `loopStart`, then the cut).
- **Every scene's pair is valid** (#167). Captured pairs are; a loaded one goes through the record's `normalize_scene` in `migrate_scene` (the start at most 0.999, the length at most `1 - start`). Without it, a hand-edited invalid pair would end a crossfaded recall with the length too long (the last fade step already reached the target start, so the final start set changes nothing and its action never cuts the length), and an instant recall too when the start is already the scene's.
- The loop reaches the engine only through its grain keys (`setGrainParam(voice, "loopStart"/"loopLength", value)`, while the voice runs) and the voice sync; never `engine.*` from an action.
- They are continuous scene fields (defaults 0 and 1, 3.1's whole slot), and randomize, mutation and the 256 fader pages never touch them (`fader = false`).

## lib/loops.lua (`S.lib.loops`)

One registered voice-param record (`S.register_voice_params`, `docs/notes/lua/params.md`), `loops`, with two params per voice:

- `v<i>_loop_start`: a control, 0-1, linear, default 0, shown with three decimals. Stored in `S.voices[i].extras.loop_start`. Grain key `loopStart`.
- `v<i>_loop_length`: a control, 0.001-1, exponential (short loops get fine steps), default 1, three decimals, five below 0.01 (one detent there moves it about 7%, which fewer decimals would hide). Stored in `extras.loop_length`. Grain key `loopLength`.

Both are fractions of the slot's valid region (whatever its length: 16 s on standard, up to `S.performance.buffer_seconds` on high, or a short take). The engine starts a buffer voice's grains inside the loop; `bufPos`, the scan and the spread move through it (`docs/notes/engine/loops.md`). The params do nothing on synth and input voices, but the voice sync sends them for every voice, so a switch to a buffer plays the loop at once.

The clamps (`M.LOOP`: `max_start` 0.999, `min_length` 0.001):
- `S.register_param_filter("loop_start", ...)`: the start is at most 0.999.
- `S.register_param_filter("loop_length", ...)`: the length is at most `S.lib.loops.max_length(i)` (`1 - start`), except while a scene sets the fields (above).
- The start's own action (`clamp_length`): a length past `1 - start` (with `M.LOOP.tolerance` for the exponential warp's rounding) is set to `1 - start`, through `params:set`, so it is stored, sent and shown.

So a start of 1 (a PSET, PARAMS, an encoder or arc ring at the top) gives 0.999 and a length of 0.001, and turning the length up there does nothing.

Scenes: the record's `normalize_scene(extras)` applies the same two limits to a loaded scene's pair, from `migrate_scene` (`docs/notes/lua/scenes.md`). A start past 0.999 becomes 0.999 and a length past `1 - start` becomes `1 - start` (with `M.LOOP.tolerance`); a pair that is not two numbers is left for `validate_scene` to reject.

VOICE: the two rows end a buffer voice's `synth` section (after `buf_pos`, `buf_rate`, `buf_scan`), shown only while the voice reads a slot (`S.lib.loops.uses_buffer(i)`, `voice_uses_buffer`). `layout_states` put each voice on buffer 1 with a loop at the slot's end and the cursor on each row. The arc's VOICE rings reach them as any other row. Grid and arc gestures for loops are 3.3's.

Tests: `test/unit/loops_test.lua` (ranges, sends and the voice sync, both clamps, the rows and their layout, the scene fields both ways, instant and crossfaded, migration, a scene file's invalid pair cut on load, randomize, mutation and the faders).
