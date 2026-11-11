### Changed
- SETUP rows are 7 px apart (six visible) and the LFO page's destination label sits one pixel higher, so letters with tails (`p`, `y`, `g`) no longer touch the line below.
- SETUP's data file problem rows now come after `buffers:` at the end of the list.
- The hint row on FX, SETUP and SCENES names only keys that act: with K1 held FX shows `E3:fine` and SETUP no K3; an empty SCENES slot reads `empty  ALT+K3:save`; SETUP's save and load rows no longer offer `E3:value`.
- The tips page names the pages (FX, VOICE, SETUP) first, and has a buffer and recording workflow.

### Fixed
- SETUP: turning E2 past the last field scrolls over the status rows (`running:`, `grid:`, `arc:`, `buffers:`), so `buffers: ... missing` can always be read.
- VOICE: a locked voice keeps its whole `[L]` tag in the filter & sends section (the name is cut instead).
- Recalling an empty scene (a grid key, K2 or K3 on SCENES, or MIDI) flashes `S<n> empty` in the header; the scene sequencer still skips empty slots without a flash.
- The 256 grid's tempo keys flash the tempo the clock runs, which under an external clock source is not the tempo param.
- A tempo change from an external clock redraws SEQ's header and the arc.
- User docs: `[T]` is MAIN's triggered mark, the MAIN and VOICE examples match the screen, controls, SEQ and LFO pages describe the header and destinations as they are.
