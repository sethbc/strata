### Changed
- A PSET carries its sixteen scenes: saving a PSET writes them beside it (`<pset>.scenes.data`), loading one replaces the live scenes with the PSET's (no scene is recalled, a running scene fade stops, and the scene sequencer and the pattern chain go on over the new scenes), and deleting a PSET deletes its scenes file. Scenes saved or named since the last PSET save or load are kept as a backup (`scenes.data.bak`, ...) before a load replaces them; when no backup can be made, the PSET's scenes are not loaded and one console line says why. A PSET saved before this, or one whose scenes file cannot be read, leaves the live scenes as they are.

### Fixed
- An unusable `grids.data` or `notes.data` is now kept as a backup (`grids.data.bak`, `notes.data.bak`, ...) with one console line, as every other data file is, instead of being written over at the next grid rotation or note pool change.
