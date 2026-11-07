## Must not break

- 3.1's chain by default: every `v<i>_delay_send` and `v<i>_reverb_send` defaults to 1 and every `v<i>_filter_mix` to 0, and the bypass params to off.
- The voice params reach the engine only through their registered grain keys (`setGrainParam`, while the voice runs) and the voice sync; never `engine.*` from an action. `filter_type` goes as its option minus 1 (`filterType` 0-2).
- `filter_type` is a discrete scene field (it switches at a transition's end); the other five crossfade. The cutoff and the two sends are LFO destinations (`v<i> vfilt`, `v<i> dsend`, `v<i> rsend`), registered after every built-in destination and after history, so saved destination indices keep their meaning.
- The bypass is explicit: only `delay_bypass` and `reverb_bypass` send `engine.setBypass`. A mix of 0 (E3, PARAMS, an LFO, a scene fade, a MIDI CC) never sets a bypass, and a bypass never changes a mix.
- PSETs store the bypass params (they are params); scenes never capture or recall them. Randomize, mutation and the 256 fader pages never touch any param of this module (`fader = false`).

## lib/voice_mix.lua (`S.lib.voice_mix`)

One registered voice-param record (`S.register_voice_params`, `docs/notes/lua/params.md`), `voice_mix` (count 6), per voice:

| Param | Kind | Range, default | Grain key |
|---|---|---|---|
| `v<i>_filter_type` | option | lowpass / highpass / bandpass, lowpass | `filterType` (option − 1) |
| `v<i>_filter_freq` | control | 20-20000 Hz exp, 5000 | `filterFreq` |
| `v<i>_filter_res` | control | 0-1, 0.5 | `filterRes` |
| `v<i>_filter_mix` | control | 0-1, 0 (the filter left out) | `filterMix` |
| `v<i>_delay_send` | control | 0-1, 1 | `delaySend` |
| `v<i>_reverb_send` | control | 0-1, 1 | `reverbSend` |

- Stored in `S.voices[i].extras`; scene defaults are the param defaults (3.1's chain), and `discrete = {filter_type = {1, 3}}`.
- VOICE: the section `filter & sends`, after mix, on every source (`M.VOICE_MIX.section`). Its `layout_states` put each voice on each source (synth, buf 1, input) with the cursor on the section's first and last row, at bandpass and 20000 Hz.
- LFO destinations (`S.register_lfo_destination`): `vfilt` (`filter_freq`), `dsend` (`delay_send`), `rsend` (`reverb_send`). `lib/history.lua` is included first, so `v<i> hist` comes before them.

The bypass params (`S.register_fx_params`, record `bypass`, count 2), at the end of the fx group: `delay_bypass` and `reverb_bypass`, binary toggles, default 0 (`M.BYPASS`, in `M.BYPASS_ORDER`). Their senders (`S.engine_senders`, set in the record's `add`) call `engine.setBypass(0, v)` and `engine.setBypass(1, v)`; their actions go through `send_param_to_engine`. `M.bypassed(effect)` ("delay", "reverb") is true while the param is on; the FX page reads it (`docs/notes/lua/pages/fx.md`).

The engine side (the voice filter inside every grain synth, the send gains, the bypass that frees and re-creates the node) is in `docs/notes/engine/effects.md`.

Tests: `test/unit/voice_mix_test.lua` (defaults and sends, the sync order, the LFO destinations, the scene round trip with the type switching at the end, the bypass params in PSETs and not in scenes, mixes and bypasses independent, the VOICE section and layout states, randomize, mutation and the faders); the FX page's K3 and `byp` in `test/unit/pages_fx_test.lua`.
