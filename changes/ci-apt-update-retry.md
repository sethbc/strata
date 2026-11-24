### Changed
- Tests only, nothing a player hears or sees: in CI's Lua jobs and engine shards the package list's `apt-get update` gives up after 45 s on a slow mirror and runs once more with `https://archive.ubuntu.com` first, so a slow mirror no longer stops a job at that step's limit (#999).
