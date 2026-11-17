### Fixed
- A scene recall that takes a stopped voice off its buffer drops the voice's tempo-follow factor at once, so its next start never plays the old one (#739).
- A synced delay under an LFO or a matrix routing on the delay time no longer resends the same delay settings 34 to 48 times a second, nor takes a modulation slot from other sends; turning sync off plays the modulated time at once (#741).
- Matrix routings that cancel to exactly 0 on a destination no longer resend the same value at every modulation step (#760).
