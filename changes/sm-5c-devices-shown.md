### Added
- IO marks a route that is set but plays nothing: `[held]` on a voice's MIDI row while a remote grid, a remote arc or `midi grid` holds its port, `[idle]` on a `jf`, `w/ syn`, `er-301` or `txo` route while Strata does not lead the ii bus, and `[error]` on the rows of an instrument whose part failed, until the patterns stop or a route changes.
- IO's `midi out` section says when the port you play Strata from is claimed by something else (`midi in 3 (remote grid)`): its notes are not heard then.
- The `ii` section's title shows the note ends owed to the next lead (`1 owed`).
- IO's `>` beside a row the cursor moved to by itself (its own row went) stays until you next turn E2 or E3, press K2 or K3, or leave the page, and sits before the row's name instead of against it.

### Changed
- The `ii` section's `n dropped` counts the drops since Strata last took the lead, not the whole session.
