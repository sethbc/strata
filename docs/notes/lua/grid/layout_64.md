## Must not break

- The layout is its spec alone (`S.lib.grid_pane.arrange`): no key, LED or page of its own; pages are their own files (`docs/notes/lua/grid/pane.md`).
- It shows a half of a pane: columns 1-8 or 9-16 of every page (`set_half`, the chooser's), so a two-key gesture (side 1's loop of the patterns page, a level or a lane's value on its side 2) runs over eight keys and a 16-key fader line is drawn across the half's eight.
- NV acts at its release when tapped (play or stop); held `GRID_HOLD.chooser_seconds` it shows the chooser instead and its release only closes it. The chooser's state is the port's (`port_state(port).chooser`), so each 64 has its own and it goes with the grid.

## Owns

- `lib/grid/layout_64.lua` (`S.lib.grid_layout_64`): `M.layout`, the record at `S.registry.grid_layouts["64"]`.
- Unit tests: `test/unit/grid_layout_64_test.lua` (the redraw on a hot-plugged grid, the voice keys, NV's tap and the chooser's half, halves and choosers per grid, a removed grid's hold, the sounding step in its half, a half switch ending a held step, the step editor on either half).

## The spec

`{half = true, panes = {{strip = {row = 8, keys = "small"}}}}`: rows 1-7 the shown half of the pane, row 8 the small strip (NV 1, O1-O7 2-8). The chooser, while NV is held: column c page c, row 1 its left half, row 2 its right, rows 3 and 4 side 2's (`docs/notes/lua/grid/pane.md`).
