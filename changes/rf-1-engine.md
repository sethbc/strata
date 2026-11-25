### Added
- The high tier's reverb can now hold its tail: the engine has a reverb freeze (`setReverbFreeze`), which the next change gives a param and keys. Frozen, the tail kept its level and its top within 1 dB over the minute measured, the reverb takes no new sound, its size waits for the release and `damp` still shades it (#819).

### Changed
- The engine changed: restart norns from SYSTEM > RESTART after updating. On the high tier the reverb's eight lines now live in ordinary memory (288 KB) instead of the real-time pool, so the high tier's reverb takes about 104 KB of the pool instead of 229 KB; it sounds exactly as before (#819).
