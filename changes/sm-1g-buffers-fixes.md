### Fixed
- SETUP keeps saying that an unreadable `buffers.data` was kept as a backup after a failed write and a good one: the line came back as `buffers file not saved` and then vanished, though the backup was still on the card.
- Turning the sensitivity or the mode in the slice editor while Strata listens for a buffer's transients no longer starts another listen over the whole buffer with each detent.
- An overdub or loop recording stopped with K3 ends after 5 s even when the engine's report of its end never arrives, as a take already did; before, it stayed `DUB` and K3 only asked the engine to stop again.

### Changed
- The buffers' recording timers, start reloads and transient reads run on the shared clock helper, so one stopped just as it wakes prints no clock error in maiden.
