### Fixed
- SETUP keeps saying that an unreadable `buffers.data` was kept as a backup after a failed write and a good one: the line came back as `buffers file not saved` and then vanished, though the backup was still on the card.
- Turning the sensitivity or the mode in the slice editor while Strata listens for a buffer's transients no longer starts another listen over the whole buffer with each detent.
