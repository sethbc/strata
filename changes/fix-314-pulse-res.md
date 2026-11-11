### Changed
- The Pulse voice's res rises with resonance, as every other res does: turned up, its filter rings; at 0.1 it is flat (default 0.8, the sound of the old 0.3). Saved scenes and PSETs sound the same and show the turned-around number (0.3 shows as 0.8); a controller mapped to it in PARAMETERS > MAP and its grid fader now sharpen it as they go up, where they flattened it before.
- scenes.data is saved as format 5: the first save keeps the older file as `scenes.data.v4` (or `.v<n>`), and Strata 3.2 or an earlier 3.3 build cannot read a format 5 file.
- Every PSET saved now holds a hidden `strata_pset_format` line; a PSET saved before it has its Pulse res turned around each time it loads, until it is saved again.

### Fixed
- A PSET saved with a fraction in a whole-number setting (a mod source, the sequence length, ...) loads it as the nearest whole number, and a running voice never receives the fraction (a mod source of 0.05 briefly made a voice modulate itself).
