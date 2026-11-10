### Changed
- SCENES' overwrite prompt names the keys that answer it: `K3 again: overwrite S<n>` while ALT is held, `ALT+K3: overwrite S<n>` once ALT is up (a plain K3 still recalls the slot).

### Fixed
- A grid's hold key goes dark (or lights) whenever a voice's scan hold changes, also when another grid that held it is unplugged or BUFFER's ALT ring 1 holds it and ALT comes up.
- A scene fade back to the scene already current, canceled or failing on a dark blink, redraws the steady mark on the screen and the grids.
- A pattern step that fails redraws the screen, so the header's play mark and SEQ show the pattern stopped.
- A fault in one part of the playhead clock's tick no longer skips the other parts, so an unplugged grid's scan hold is always released.
