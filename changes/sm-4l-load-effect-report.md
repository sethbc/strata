### Fixed
- On the high tier, loading a long file right after another file no longer shows the long file as loaded, at the earlier file's length, while the engine is still checking it: the slot keeps showing `...` until the long file takes effect or fails (#983).
