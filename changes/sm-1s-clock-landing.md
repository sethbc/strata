### Changed
- Developer groundwork only, nothing you hear or see changes: the clock helper now follows norns' own count of a clock's next beat after a new clock source moves the beat back or forward, so a clock stopped then never risks a `bad argument #1 to 'resume'` line in maiden, and its test check keeps naming a module clock that waits outside the helper.
