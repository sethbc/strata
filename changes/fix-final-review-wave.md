### Fixed
- The 16×16 grid's tempo keys flash the tempo they set (`tempo 121`), not the one before, on the internal clock and Link; under a MIDI or crow clock they show the tempo the clock runs.
- SETUP: with E2 turned past the last field, E3 no longer changes the field scrolled out of view (the performance setting, say). It scrolls back to the field, and the hint row reads `E2:field E3:back`.
- FX: with ALT held, the filter type's row no longer offers `E3:fine`, since the type steps one type at a time.
- LFO: each row's destination no longer touches the `on`/`off` line of the row above. The rows sit 1 px further apart.
