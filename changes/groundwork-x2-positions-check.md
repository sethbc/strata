### Fixed
- Development: the engine check's region-restart read no longer sits at the edge of the old grains: it reads 0.1 s after the region changes, once the grains from before the change have ended (#757).
