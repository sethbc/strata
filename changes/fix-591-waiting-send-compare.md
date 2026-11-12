### Fixed
- A Lua-run LFO no longer leaves the engine on a stale value when the send budget is full: it compares with the value waiting to be sent, not the last one delivered.
