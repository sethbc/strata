## Must not break

- `v<i>_history`'s range is 0 to `S.performance.history_seconds`, read when the param is added at init (16 s standard, 60 s high), so a PSET or scene value saved on a longer tier clamps silently and the engine never receives more than the tier's history.
- History reaches the engine only through its registered grain key (`setGrainParam(voice, "history", seconds)`, while the voice runs) and the voice sync; never `engine.*` from the param's action.
- It is a continuous scene field (default 0), an LFO destination in its voice's group (after the voice's built-in ones), and never touched by MAIN's randomize, mutation or the 256 fader pages (`fader = false`). A quick ALT+K2 on VOICE's input section is the one exception (#557): the record's `randomize` draws it uniform from 0 to its param's top (the tier's history when the params were added), reading the voice's own param, so its draw takes the voice index.
- It is not `buf_pos`: an old scene whose voice is on input with a non-zero `buf_pos` must not jump into the past.
- `v<i>_input_channel` (3.8, package 1d) reaches the engine only as the handler-only grain param `inputChannel` (option - 1: 0 stereo, 1 left, 2 right; `carry = false`); it is a discrete scene key (1-3, default 1) and the VOICE row after history, on an input voice only (a voice source has neither row). The engine applies it as a choice of ring buffers, never a UGen (`docs/notes/engine/rings.md`).

## lib/history.lua (`S.lib.history`)

One registered voice-param record (`S.register_voice_params`, `docs/notes/lua/params.md`), `history`, with two params per voice:

- `v<i>_history`: a control, 0 to `S.lib.history.max_seconds()` (`S.performance.history_seconds`) s, linear, default 0, unit `s`. Stored in `S.voices[i].values.history`.
- Grain key `history`: the param's sender calls `setGrainParam(i - 1, "history", value)` while the voice runs, and `sync_voice_values_to_engine` sends it (after the built-in values). The engine keeps it for every voice and sends it only to an input voice's grain synth (`docs/notes/engine/grains.md`), so a synth voice never reads its 4 s ring from the past.
- Scene default 0, continuous: scenes capture it in `voices[i].values`, `fill_scene` fills the default (0) into a scene without it, and a transition crossfades it.
- `v<i>_input_channel` (3.8): an option, `stereo`, `left`, `right`, default 1, after `v<i>_history` in the voice's extras. Grain key `inputChannel` (sent as the option less 1, `carry = false`), scene default 1, discrete `{1, 3}`: a scene switches it at the end of a transition. `M.HISTORY.channel_key`, `channels` and `channel_engine_name` name it. A start sends it with the kept grain params, before `voiceOn`.
- VOICE: a section `input` before `grain`, holding the history row and the channel row, shown only while the voice reads the input (`S.lib.history.uses_input(voice_idx)`, `voice_uses_input`): never on a voice source, which has no history and no channel.
- LFO destination `v<i> hist` (`S.register_lfo_destination("hist", "history")`), the first registered destination in each voice's group, after its built-in ones (3.7: the list is by voice). The LFO modulates around the stored value and is clamped to the range.

`M.HISTORY` names the key, engine name, LFO label and VOICE section, and the channel's key, options and engine name. The layout states put each voice on the input with its cursor on the history row (at the range's top) and on the channel row. The engine side (the input ring and how far back a grain reads) is in `docs/notes/engine/rings.md`.

Tests: `test/unit/history_test.lua` (range, sends, scene field and crossfade, a high-tier value on standard, the VOICE row and layout, the LFO destination, randomize, mutation and the faders, the record's `randomize` draw on both tiers; the input channel's options, sends, scene key and row, and its place in a start).
