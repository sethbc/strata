## Must not break

- The layout is its spec alone (`S.lib.grid_pane.arrange`): no key, LED or page of its own; pages are their own files (`docs/notes/lua/grid/pane.md`).
- The pane is turned: pane x is the physical row, pane y the column, so a line of sixteen runs down a column and a fader line runs up (row 16 its minimum).

## Owns

- `lib/grid/layout_128v.lua` (`S.lib.grid_layout_128v`): `M.layout`, the record at `S.registry.grid_layouts["128v"]`.
- Unit tests: `test/unit/grid_layout_128v_test.lua` (the redraw on a hot-plugged grid, the strip down column 8 on every page, the steps down each voice's column, the sounding step, the silenced voice's key, a step key's release toggle).

## The spec

`{turned = true, panes = {{strip = {column = 8, keys = "upper"}}}}`: voices 1-7 on columns 1-7, a line's sixteen keys down rows 1-16; column 8 the 128h's strip top to bottom (PL row 1, FL 2, P1-P7 3-9, O1-O7 10-16). A monome 128 is an 8x16 grid once its port's rotation is 1 or 3 (`docs/notes/lua/grid-core.md`, Rotation).
