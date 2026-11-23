### Fixed
- Undoing a voice preset's load or copy (a quick ALT+K2 on VOICE) puts the `preset` row's name back as well as the sound, so the row no longer names a preset the voice has left.
- A voice preset saved before the script has read its preset library no longer writes over the library on file.
- An edit that ends the randomize undo just as its 5-second window closes no longer prints a clock error in maiden.

### Changed
- The randomize undo's and the drift's "who is writing" flags put back the value they found, so a write nested in another can no longer clear the outer one's flag early (no change at the instrument today).
