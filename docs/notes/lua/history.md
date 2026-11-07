## Must not break

- `v<i>_history`'s range is 0 to `S.performance.history_seconds`, read when the param is added at init (16 s standard, 60 s high), so a PSET or scene value saved on a longer tier clamps silently and the engine never receives more than the tier's history.
- History reaches the engine only through its registered grain key (`setGrainParam(voice, "history", seconds)`, while the voice runs) and the voice sync; never `engine.*` from the param's action.
- It is a continuous scene field (default 0), an LFO destination after every built-in one, and never touched by randomize, mutation or the 256 fader pages (`fader = false`).
- It is not `buf_pos`: an old scene whose voice is on input with a non-zero `buf_pos` must not jump into the past.

## lib/history.lua (`S.lib.history`)

One registered voice-param record (`S.register_voice_params`, `docs/notes/lua/params.md`), `history`, with one param per voice:

- `v<i>_history`: a control, 0 to `S.lib.history.max_seconds()` (`S.performance.history_seconds`) s, linear, default 0, unit `s`. Stored in `S.voices[i].extras.history`.
- Grain key `history`: the param's sender calls `setGrainParam(i - 1, "history", value)` while the voice runs, and `sync_voice_values_to_engine` sends it (after the built-in values). The engine keeps it for every voice and sends it only to an input voice's grain synth (`docs/notes/engine/grains.md`), so a synth voice never reads its 4 s ring from the past.
- Scene default 0, continuous: scenes capture it in `voices[i].extras`, migration fills 0, and a transition crossfades it.
- VOICE: a section `input` before `grain`, holding only the history row, shown only while the voice reads the input (`S.lib.history.uses_input(voice_idx)`, `voices[i].source == SOURCE_INPUT`).
- LFO destination `v<i> hist` (`S.register_lfo_destination("hist", "history")`), the first registered group after the built-ins (the LFO page's ALT+E3 jumps to it as one group). The LFO modulates around the stored value and is clamped to the range.

`M.HISTORY` names the key, engine name, LFO label and VOICE section. The engine side (the input ring and how far back a grain reads) is in `docs/notes/engine/rings.md`.

Tests: `test/unit/history_test.lua` (range, sends, scene field and crossfade, a high-tier value on standard, the VOICE row and layout, the LFO destination, randomize, mutation and the faders).
