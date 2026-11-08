### Fixed
- A buffer save that cannot be written (a full card, a folder that cannot be made) no longer says it saved: the BUFFER page shows `saving buf <n>`, then `saved buf <n>` only once the file is written, or `buf <n> save failed`, and the console says the same.
