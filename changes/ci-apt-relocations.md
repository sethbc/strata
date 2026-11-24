### Changed
- Tests only, nothing a player hears or sees: the docs tests now also refuse a CI workflow that points apt at configuration, keys or sources it does not hold (`Dir::Etc`, `Dir=`, `trusted`, `APT_CONFIG`, apt's `-c`, apt's nested syntax, or a write under `/etc/apt/` other than the pinned mirror reorder) (#1011).
