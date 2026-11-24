### Changed
- An LFO in the engine (`~`) keeps running at depth 0: a depth swept through 0 by a macro, a fade or by hand carries on where its cycle was, where it used to stop and start again from a resync (#925).
- The LFO page's user notes say that a random shape in the engine draws its own values, while the page's dot and a routing from the LFO follow the script's draws (#929).

### Fixed
- An LFO turned on by a PSET read now starts at its phase setting, not where an earlier run had left it (#925).
