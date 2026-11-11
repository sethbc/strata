### Fixed
- `scenes.data` and `buffers.data` are read by a parser of the layout norns writes them in, never run as Lua: a file holding code (one passed from another norns, say) can no longer touch the card or keep norns at its loading screen. Such a file, like any other damaged one, is reported in the console and kept as `.bak`; every file an earlier Strata saved loads as before (#464).
