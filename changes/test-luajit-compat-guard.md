### Fixed
- Added a test that fails on Lua 5.2+ names the CI LuaJIT lacks (`table.unpack` and others) unless they have a fallback, so a local LuaJIT can no longer pass code CI rejects (#119).
