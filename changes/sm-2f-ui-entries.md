### Changed
- IO marks the row the cursor moved to with `>` when the row it was on goes away (a device unplugged, a route changed), so a turn of E3 or a press of K3 that only shows the move is not mistaken for one that acted.
- The screen's machines are written down and checked by the tests: the slice editor, IO's detail list and BUFFER's file selector each have the check the other screen lists already had (nothing a player notices).
