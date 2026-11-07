## Must not break

- `grid.add`/`grid.remove`/`arc.add`/`arc.remove`/`midi.add`/`midi.remove` call `request_redraw()`, so SETUP stays current (drawn on the next frame). A scene saved on a grid hold requests one too (SETUP counts the saved scenes).
- The MIDI device name is cut with `fit_text` to end by x 127, so a long norns device name never leaves the screen.
- E2 and E3 edit through `enc_param_delta`: ALT+E2 stays whole steps.
- SETUP has no arc fields: its rings stay dark and ignore turns.

## Owns

- `lib/pages/setup.lua` (`S.lib.pages_setup`): the SETUP record, `redraw_setup`, `setup_key`, `setup_hints`, `setup_enc` (global).
- Its unit tests: `test/unit/pages_setup_test.lua` (the long MIDI name case is in `test/unit/midi_in_test.lua`, the missing buffers in `test/unit/buffers_test.lua`).

## The page

`redraw_setup`, `setup_enc`, `setup_key`:
- Grid count and sizes (in port order), arc connected/none, `scenes: k/8 saved`.
- `buffers: k restored` (`S.buffers_restored`, engine-confirmed), or `buffers: k ok, m missing` when remembered files were missing.
- `midi <port>: <device>` (y 48; `midi_device_name()` cut with `fit_text` to end by x 127, so long norns device names fit) and `ch: <channel mode>` (y 54, level 4).
- Rows y 18-54, 6 px apart.
- E2 is `enc_param_delta(2, "midi_device", d)`, E3 `enc_param_delta(3, "midi_channel_mode", d)`, K3 calls `save_scenes_to_disk()`.
- Hints `E2:port E3:ch K3:save`. No ALT keys yet.
- `setup_enc` is a global function.
