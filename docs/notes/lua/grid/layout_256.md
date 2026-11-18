## Must not break

- The layout is its spec alone (`S.lib.grid_pane.arrange`): no key, LED or page of its own; pages are their own files (`docs/notes/lua/grid/pane.md`).
- Two panes, each with its own page, side and keys: a page change on one ends only that pane's keys, never the other's or a strip's.
- It starts on patterns over voices (`start`); a start page with no record would start on patterns (the core's `start_page`).

## Owns

- `lib/grid/layout_256.lua` (`S.lib.grid_layout_256`): `M.layout`, the record at `S.registry.grid_layouts["256"]`.
- Unit tests: `test/unit/grid_layout_256_test.lua` (the panes and strips where the spec puts them, the redraw on a hot-plugged grid, the strips' keys and levels, fill across a page change, the tempo keys, the sounding step, a key held into another page).

## The spec

`{panes = {{x = 0, y = 0, strip = {row = 8, keys = "upper"}}, {x = 0, y = 8, strip = {row = 16, keys = "lower"}}}, start = {GRID_PAGES.patterns, GRID_PAGES.voices}}`: the top pane on rows 1-7, its strip on row 8 (PL, FL, P1-P7, O1-O7); the bottom pane on rows 9-15, its strip on row 16 (T-, T+, P1-P7, M1-M7). Row 8's page keys move the top pane, row 16's the bottom one.
