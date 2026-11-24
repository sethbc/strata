### Changed
- Tests only, nothing a player hears or sees: the docs tests now also refuse a CI workflow that points apt at configuration, keys, lists or sources it does not hold (any `Dir::` setting but `Dir::State::status`, `Dir=`, `trusted`, `apt-key`, `APT_CONFIG`, apt's `-c`, apt's nested syntax, or a write under `/etc/apt/` other than the pinned mirror reorder, `sudo` included) (#1011).
