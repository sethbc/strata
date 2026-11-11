### Added
- SETUP has a rotation field per grid port (`grid 1 rotation` ... `grid 4 rotation`: 0, 90, 180 or 270), kept in `grids.data` in Strata's data folder: a monome 128 stood upright at 90 or 270 uses the 8×16 layout, which it could not reach before (it reports itself as 16×8). A turned grid starts again on page 1 with no keys held, a grid plugged into the port is turned at once, and leaving Strata puts it back unturned for the next script (#323).
- The 16×8's sources page lights column 11 on the grid voice's row, and the 8×16's positions page lights the grid voice's column one step brighter, so the bookmark strip's voice shows on the page the strip is on (#444).

### Changed
- The same state lights alike on every grid layout (#526): a stopped voice's key is 2 on the 8×16 and 8×8 too (was 4), the 16×8's idle page keys and the 16×16's positions key are 2 (were 4), and the 8×16's unselected voice keys are 4 (were 2).
- A grid's faders page is redrawn when a fader it shows moves, from the screen, the arc, a MIDI map or PARAMETERS, within a tenth of a second, and no longer ten times a second while nothing changes (#324).

### Fixed
- One grid layout's drawing error no longer stops the other grids from being drawn, nor the voice toggle, pattern clock, source change or key that asked for the redraw; the error prints once (#441).
- After the script's cleanup (as norns' SLEEP runs it) a grid key, an arc turn or a hot-plugged grid, arc or MIDI device reaches nothing of Strata's, so a key pressed while norns shuts down can no longer light the grid or start a voice (#468).
- The grid docs: the step-level gesture (every further key sets the held step's level), the 16×8's hold key on its sources page, the 8×8's page names what to do on the screen, and the scenes guide leads with the SCENES page and names each layout's scene keys (#450, #360, #361, #334).
