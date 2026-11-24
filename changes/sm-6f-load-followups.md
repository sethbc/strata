### Fixed
- A remembered file that failed to load at start after four quick bad loads into its buffer no longer leaves the buffer waiting: it is empty, and the file is no longer remembered (a plain load forgotten the same way is #1035).
- On the high tier, a long file that failed its check right after another bad load, while a synced take waited, no longer counts as loaded for a moment: a grid's slice bank pick is kept.
