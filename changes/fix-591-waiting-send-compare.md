### Changed
- No change for players: a Lua-run LFO compares a new value with the one waiting to be sent, not the last one delivered, so a full send budget never leaves the engine on a stale value.
