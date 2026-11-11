### Fixed
- A scrub fling starts one glide clock for a run of ring turns, not one per turn.
- A grid's positions page and the 128h's page 4 strip are repainted within a tick of a change made elsewhere, including the first tick after the grid arrives; the position rows no longer rebuild their levels on every cell.
- A voice that reads no buffer shows a dark position strip on every grid and a store held with a bookmark stores nothing.
