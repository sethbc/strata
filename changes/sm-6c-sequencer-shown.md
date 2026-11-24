### Added
- SEQ shows a status line under the pattern rows: the chain's scene and the bars to its next link (`[S3 4 bars]`, `chain [none]` with no scene to link), a division reset waiting for its bar (`[reset at bar]`) and a step output that failed until the next start (`[targets off]`). The pattern rows sit 5 px apart to make room.
- SETUP's `transport` row reads `follow [int]` on the internal clock, where nothing follows the transport, and a status line shows the patterns' count offset (`count offset: +3.50 beats`) while they play on their own count after a transport start they did not follow.

### Fixed
- The screen redraws when the patterns stop from anywhere (a transport stop, a scene, a grid key) and when their count is kept through a transport start they do not follow or another jump of the clock's beat (a new clock source).
