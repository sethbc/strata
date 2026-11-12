## Must not break

- 3.1's chain by default: every `v<i>_delay_send` and `v<i>_reverb_send` defaults to 1 and every `v<i>_filter_mix` to 0, and the bypass params to off.
- The voice params reach the engine only through their registered grain keys (`setGrainParam`, while the voice runs) and the voice sync; never `engine.*` from an action. `filter_type` goes as its option minus 1 (`filterType` 0-2).
- `filter_type` is a discrete scene field (it switches at a transition's end); the other five crossfade. The cutoff and the two sends are LFO destinations (`v<i> vfilt`, `v<i> dsend`, `v<i> rsend`), registered after every built-in destination and after history, so saved destination indices keep their meaning.
- The bypass is explicit: only `delay_bypass` and `reverb_bypass` send `engine.setBypass`. A mix of 0 (E3, PARAMS, an LFO, a scene fade, a MIDI CC) never sets a bypass, and a bypass never changes a mix.
- PSETs store the bypass params (they are params); scenes never capture or recall them. MAIN's randomize, mutation and the 256 fader pages never touch any param of this module (`fader = false`). A quick ALT+K2 on VOICE's filter & sends section is the one exception (#557): the record's `randomize` draws `filter_type` (a uniform option), `filter_freq` (100-8000 Hz, even in octaves), `filter_res` (0-0.7, below self-oscillation) and `delay_send` and `reverb_send` (0-0.6 each); `filter_mix` is kept (0 would leave the filter out), and so are the bypass params.

- **Mute and solo (3.4)**: a mute silences in the mix stage (`voiceMute`) and never stops a voice; scenes store `mute` (discrete, migration default 0) and never `solo`. What the engine gets is `S.lib.voice_mix.silenced(voice)` (muted, or some voice is soloed and this one is not; false for any argument that is not a voice), sent by the record's `sync` (unconditionally, before `voiceOn`) and by the params' own senders, never through `grain_keys` (a grain key sends a stored value as it is). A change of any mute or solo sends only to running voices whose answer changed; stopped voices get theirs with their start. Neither is in the record's `randomize`.

## lib/voice_mix.lua (`S.lib.voice_mix`)

One registered voice-param record (`S.register_voice_params`, `docs/notes/lua/params.md`), `voice_mix` (count 8), per voice:

| Param | Kind | Range, default | Grain key |
|---|---|---|---|
| `v<i>_filter_type` | option | lowpass / highpass / bandpass, lowpass | `filterType` (option − 1) |
| `v<i>_filter_freq` | control | 20-20000 Hz exp, 5000 | `filterFreq` |
| `v<i>_filter_res` | control | 0-1, 0.5 | `filterRes` |
| `v<i>_filter_mix` | control | 0-1, 0 (the filter left out) | `filterMix` |
| `v<i>_delay_send` | control | 0-1, 1 (shown as a percent, `100 %`) | `delaySend` |
| `v<i>_reverb_send` | control | 0-1, 1 (shown as a percent, `100 %`) | `reverbSend` |
| `v<i>_mute` | binary | 0 | none: `voiceMute` is the effective mute (`silenced`), sent by the record's `sync` and a sender of its own |
| `v<i>_solo` | binary | 0, in no scene | none (as `mute`) |

- Stored in `S.voices[i].extras`; scene defaults are the param defaults (3.1's chain), and `discrete = {filter_type = {1, 3}, mute = {0, 1}}` (`scene_defaults.mute` = 0; `solo` is in neither). VOICE shows `mute` and `solo` as binary rows after the sends.
- VOICE: the section `filter & sends`, after mix, on every source (`M.VOICE_MIX.section`). Its `layout_states` put each voice on each source (synth, buf 1, input) with the cursor on the section's first and last row, at bandpass and 20000 Hz.
- LFO destinations (`S.register_lfo_destination`): `vfilt` (`filter_freq`), `dsend` (`delay_send`), `rsend` (`reverb_send`). `lib/history.lua` is included first, so `v<i> hist` comes before them.

The bypass params (`S.register_fx_params`, record `bypass`, count 2), at the end of the fx group: `delay_bypass` and `reverb_bypass`, binary toggles, default 0 (`M.BYPASS`, in `M.BYPASS_ORDER`). Their senders (`S.engine_senders`, set in the record's `add`) call `engine.setBypass(0, v)` and `engine.setBypass(1, v)`; their actions go through `send_param_to_engine`. `M.bypassed(effect)` ("delay", "reverb") is true while the param is on; the FX page reads it (`docs/notes/lua/pages/fx.md`).

The engine side (the voice filter inside every grain synth, the send gains, the bypass that frees and re-creates the node) is in `docs/notes/engine/effects.md`.

Tests: `test/unit/voice_mix_test.lua` (defaults and sends, the sync order, the LFO destinations, the scene round trip with the type switching at the end, the bypass params in PSETs and not in scenes, mixes and bypasses independent, the VOICE section and layout states, randomize, mutation and the faders, the record's `randomize` draws, and `test/unit/voice_mix_test.lua` also covers mute and solo: the sends, a start's sync, scenes, steps, randomize); the FX page's K3 and `byp` in `test/unit/pages_fx_test.lua`.
