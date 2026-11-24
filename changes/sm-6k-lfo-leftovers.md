### Fixed
- The LFO page names a destination saved by a later Strata that this one lacks (cut to fit), where it read `none`, as MOD already did; it still plays nothing and is kept until you turn it.

### Changed
- Two internal LFO readers that nothing used any more are gone; which LFO plays a destination is decided as before.
