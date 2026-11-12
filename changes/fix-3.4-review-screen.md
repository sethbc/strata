### Changed
- SEQ's edit view and the step editor show a step's pitch lock as a ratio, as MAIN shows the pitch (`1.50x`).
- On SEQ's `euclid` and `clear` rows, which have nothing to reset, ALT+K2 held past half a second says `K2:cancel` (it said `K2:reset`); letting go does nothing there, as before.
- MOD's learn (ALT+K3 on a macro's target row or a routing's `dest`) now waits while you change pages, so the setting it learns can be turned on its own page with an encoder or an arc ring (nothing on MOD itself touches one, so before this only a grid fader could finish it). While it waits the header says so on every page (`learn M1 row 2`, `learn R3 dest`); K2 in the view, a new learn or 10 seconds without a touch still cancel it.
