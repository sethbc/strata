### Changed
- FX: while the delay is frozen, its `time` row shows `held` after the label, since a frozen loop keeps the length it froze at and the time shown is the one it plays once released (#911).

### Fixed
- A PSET loaded silently that bypasses a frozen delay now releases the freeze. Before, the delay was left bypassed and frozen, and ALT+K3 did nothing (#883).
- Clearing a frozen delay now releases the freeze first, so the delay refills with what comes in. Before, the loop emptied and stayed frozen on silence (#912).
