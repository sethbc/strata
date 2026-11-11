### Changed
- A long file the engine is still checking 30 s after its load stays on its row at `...` until the engine answers, with `buf <n> still checking` on the hint row once; it no longer goes back to what the buffer held while the new file plays (#317).
- An overdub or loop recording into an empty buffer is named `take <n>` as soon as it has a length (#400).

### Fixed
- A long file whose check ends after 30 s is loaded under its own name, kept in `buffers.data` and counted as restored (#317).
- A failed second long load, after the first took effect, leaves the first file loaded instead of a row stuck at `...` that then showed the file before it (#399).
- A long file loaded from a start near its end no longer waits for a check the engine does not make (#317).
- A file above 48 kHz can be started anywhere up to its last part (a 60 s 96 kHz file up to 52 s on a 16 s buffer, a 12 s one up to 4 s), and a saved start past the old limit survives a restart (#326).
- A failed load during an overdub into an empty buffer no longer leaves a buffer that plays but is named `empty` (#400).
- A sound file named `empty` shows its name on BUFFER instead of `-` (#436).
- Filling the empty buffers flashes `filled 1 slot` for one (#512).
- A buffer number that is not a whole number is ignored everywhere instead of raising an error, and 3.0 is buffer 3 (#402).
- A clear or a recording no longer makes norns list the audio folder (#480).
- A file loaded from a folder whose name holds `$`, a backtick, `\` or `"` never enters the buffer's file param, so norns never runs that name as a command (when it lists the folder, when PARAMETERS opens the file selector there, or when a PSET is read); the file still loads and is restored at the next start, but PARAMETERS and PSETs do not show or save it (#480, #559).
