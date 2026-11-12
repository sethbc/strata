### Changed
- No change for players: the test harness's clock helpers `run_for` and `advance_until` now post every resume due at one instant before delivering any, as norns does (and as `advance` already did), so a test driven by any of them catches a clock canceled while its resume is posted (#588).
