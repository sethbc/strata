### Changed
- A refusal or a failure of a load, a save or a recording (`buf <n> load failed`, `take <n> unsaved`, `buf <n> save failed`, `buf <n> busy`, `buf <n> empty`, `buf <n> loading`) now shows in the header on every page, so an overdub refused from the grid or a load that failed while MAIN shows is no longer silent; progress and results stay in BUFFER's hint row.
- Fill (ALT+K2 held on BUFFER) skips a buffer whose file was missing at the start, which keeps waiting for that file.

### Added
- BUFFER's rows show `missing` with the file's name for a buffer whose file was not found at the start, `wait` for a loaded file whose audio has not been reported yet, and `saving` while a save is being written.
- The BUFFER user page says that a take armed by level empties its buffer as soon as K3 is pressed.
