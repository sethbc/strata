### Fixed
- SETUP keeps saying that an unreadable `buffers.data` was kept as a backup after a failed write and a good one: the line came back as `buffers file not saved` and then vanished, though the backup was still on the card.
- Turning the sensitivity or the mode in the slice editor while Strata listens for a buffer's transients no longer starts another listen over the whole buffer with each detent; if a listen's answer is lost, a turn after 30 s listens again.
- An overdub or loop recording ends 5 s after K3 (an overdub also 5 s after its length has run out) even when the engine's report of its end never arrives, as a take already did; before, it stayed `DUB` and K3 only asked the engine to stop again.
- A long file's check that outlasts 30 s says how to stop waiting: the hint row reads `buf <n> still checking K2:ld/clr` (load another file or clear the buffer).

### Changed
- The buffers' recording timers, start reloads and transient reads run on the shared clock helper, so one stopped just as it wakes prints no clock error in maiden.
