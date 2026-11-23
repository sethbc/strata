### Fixed
- A change of `seq direction` while the patterns play (by hand, a scene or the chain) no longer plays steps twice: the pass ends where the new direction wraps, and conditions such as `1:2` count the pass there (#874).
- A misstep while a shorter `seq length` waits for the pass's end wraps by the pass's own length, as the pass's other steps do (#920).
