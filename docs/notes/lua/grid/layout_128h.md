## Must not break

- The layout is its spec alone (`S.lib.grid_pane.arrange`): no key, LED or page of its own; pages are their own files (`docs/notes/lua/grid/pane.md`).
- Its strip is the 256's top strip: the same key in the same place.

## Owns

- `lib/grid/layout_128h.lua` (`S.lib.grid_layout_128h`): `M.layout`, the record at `S.registry.grid_layouts["128h"]`.
- Unit tests: `test/unit/grid_layout_128h_test.lua` (the pane and strip where the spec puts them, the redraw on a hot-plugged grid, two grids' own pages, the sounding step, the silenced voice's key, a step key's release toggle).

## The spec

`{panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}}}`: one pane on rows 1-7, row 8 its strip (PL 1, FL 2, P1-P7 3-9, O1-O7 10-16).
