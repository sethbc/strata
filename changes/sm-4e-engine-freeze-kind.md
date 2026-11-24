### Fixed
- A freeze read the engine could not answer in time no longer leaves a listener behind for each read that gave up (#1014).

### Changed
- The engine check now covers a type switch sent to a stopped voice whose freeze is spectral (#979).
