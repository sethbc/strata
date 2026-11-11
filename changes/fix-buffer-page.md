### Changed
- A synced recording whose beats do not fit a buffer is the whole beats that fit, as BUFFER's `len` field shows (`26b max` at 100 BPM is 26 beats, 15.6 s), so a loop recorded that way wraps on the beat; a whole buffer only when not one beat fits (`<1b max`). Deviation from the 3.3 design, which capped a synced length at the buffer length (#321).
- BUFFER's `bm` field shows `-` until the selected voice recalls a bookmark, so the first E3 detent either way recalls bookmark 1; ALT+E3 recalls the bookmark shown again (#431).
- The `no files in` and `cannot open` flashes name the folder by its path inside `~/dust/audio` (`tape/`), or by its own name when that does not fit the screen or the folder is elsewhere, never by its absolute path (#432).

### Fixed
- BUFFER draws no playhead, spread or bookmark tick over an empty buffer or one recording a take, and stops redrawing every frame then, as the grid's position rows stay dark (#433).
- BUFFER's input meter no longer repaints a connected arc's rings at every level change (#434).
- An open BUFFER file selector is no longer redrawn 15 times a second while a voice plays the buffer under the cursor or the input meter moves (#435).
- A file name with accented letters shows them plainly (`café` as `cafe`, `?` for a character the norns screen cannot show) instead of gaps, on BUFFER's rows and in its flashes; the file keeps its own name (#551).
- The user pages say that BUFFER's `bm` field recalls bookmarks without a grid, and that a VOICE row or a grid's store key sets one (#336).
