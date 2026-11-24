### Changed
- Tests only, nothing a player hears or sees: CI's Lua jobs keep their two packages between runs and check each file against apt's lists, as the engine shards do, so a slow package mirror no longer stops them before their tests run (#993).
