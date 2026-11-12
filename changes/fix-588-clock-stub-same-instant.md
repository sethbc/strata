### Changed
- No change for players: the test harness's clock helpers `advance`, `run_for` and `advance_until` now run the scheduler as matron's 1 ms tick does, posting every resume due within a tick before delivering any and, with a latency, every tick due by a delivery before it, so a test driven by any of them catches a clock canceled while norns may have posted its resume (#588).
