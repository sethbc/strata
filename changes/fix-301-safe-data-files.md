### Changed
- A saved scene is written to disk at once (ALT+K3 on SCENES, the grid's hold), and the remembered buffer files whenever a buffer's file or start point changes, so a power cut, a crash or maiden's `;restart` no longer loses them. Saving the same scene again, or leaving the script with nothing new, writes nothing (#327).
- SETUP's `load scenes` (and PARAMETERS > load scenes from disk) asks for a second press, `K3 again: drop unsaved`, only while a scene saved in this session is not on disk; otherwise it loads at once, the file already holding every saved scene (#328).
- An unreadable `scenes.data` or `buffers.data` is kept under the first free of `.bak`, `.bak.2` ... `.bak.9`, so a later unreadable file never replaces an earlier copy (#466).
- A data file from an older Strata is kept as `scenes.data.v<n>` (`buffers.data.v1`) before the first save in the new format replaces it, so it is still there for the older version (#467).

### Fixed
- `scenes.data` and `buffers.data` are written to a temporary file, each step checked, and put in place only when the whole write worked: a full card or a power cut during a save leaves the previous file whole, where it used to leave it empty or cut short and still print `saved`. A save that fails says so: the header reads `S<n> not on disk`, SETUP shows `scenes file not saved` (or `buffers file not saved`), and the next save tries again (#301).
- SETUP says what its save and load did on the hint row (`scenes saved`, `scenes not saved`, `scenes loaded`, `no scenes file`, `scenes unreadable`), lists a data file it could not read (and the copy it was kept as) or write, and the hint row names an unreadable data file for a few seconds at start (#463).
- Loading scenes from disk no longer leaves the current scene marked on a slot whose scene the file replaced with another (#518).
