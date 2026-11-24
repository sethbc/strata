### Fixed
- MAIN's `~` now shows for an LFO on one of the voice's parameters that runs in Lua (density, for example), as it already did for a matrix routing to the same parameter (#881).
- MOD dims an LFO's row while the LFO moves nothing (off, at depth 0 or with no destination), and a routing's row and arc ring at depth 0 as well as when it is off or incomplete: a bright row is one that moves a sound (#881, #926).
- MOD names an LFO destination from another release as it was saved, where it read `none` (#881).

### Changed
- MAIN's voice list marks a stopped voice that is muted, or silenced by another voice's solo, with `x` (`3x fold`), so you can see which stopped voices would start silent (#918). Edits to a stopped voice still reach the engine only once it runs again.
