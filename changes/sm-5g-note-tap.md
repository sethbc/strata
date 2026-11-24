### Fixed
- A MIDI note played while SEQ's step editor (opened from a grid) covers the scale & tuning editor no longer toggles a scale note you cannot see; it plays as usual, and the editor takes notes again once it shows. The same holds for a zones learn under the step editor.
- The scale & tuning editor can no longer take or clear a zones learn's MIDI note tap, and a MIDI reset (a port, channel mode or note off mode change, or an unplug) now ends a waiting zones learn instead of leaving it deaf.
