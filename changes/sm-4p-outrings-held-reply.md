### Changed
- Tests only, nothing a player hears or sees: the engine check's two missing-head checks of a reader's hold hold the server's reply to the copy's head read until the engine has given up on it, in place of a queue of server work sized by a timing, so a loaded machine no longer makes the head arrive in time and the checks fail (#998).
