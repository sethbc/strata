### Added
- **Four patterns a voice, A to D** ([Variations](docs/user/sequencer.md#variations)): each voice holds four whole patterns (the steps, their settings and the lanes' lengths). The first switch to an unused letter copies the pattern playing, so the voice plays on unchanged; a used letter keeps what was left in it, empty or not. Scenes keep every voice's letters (a scene saved before them plays its pattern on A alone), the chain carries them and the undo of a chain start puts them back. Switching letters from the grid and SEQ comes in a later step of this work.

### Changed
- The grid's pattern copy (PC on the voices page) copies the whole pattern, every step's settings and the lane lengths with the steps, and a paste replaces the voice's playing pattern whole.
- A scenes file may now be up to 12 MB and hold up to 98304 tables (both three times 3.8's), so sixteen full scenes with every letter of every voice full (about 3.3 MB) still load.
