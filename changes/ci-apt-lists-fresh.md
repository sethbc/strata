### Changed
- Tests only, nothing a player hears or sees: in CI's Lua jobs and engine shards the package list's `apt-get update` reads Ubuntu's sources alone and fails on any list of theirs that did not download, where it went on with the old list before, and the step then checks that it read Ubuntu's main and universe lists; the runner's other sources fail nothing (#1005).
