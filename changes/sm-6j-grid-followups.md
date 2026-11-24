### Changed
- Grid sources page: a buffer whose file was not found at the start blinks slowly (a second on, a second off) until a file is loaded into it or it is cleared, so it is told from an empty buffer and from one holding audio.
- An overdub or loop recording into a buffer whose file is at another sample rate, which becomes a take that replaces the buffer, now says `buf <n> replaced` in the header on every page (it was the buffer page's hint row alone, so a grid overdub started from MAIN replaced the buffer without a word).

### Fixed
- A scene recall from crow, OSC or a Teletype that waits for the beat or bar now blinks that scene's keys on the grid until it lands, as a grid key's or the SCENES page's recall does.
