### Fixed
- On the high performance setting, a buffer loading a file longer than 16 s shows `...` for its length while the engine checks the file, instead of the old length beside the new name, and the new length once the file is in. If the engine never reports the new length, the row goes back to what the buffer held after 30 s.
