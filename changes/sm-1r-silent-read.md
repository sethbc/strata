### Fixed
- A PSET read without its actions (`params:read(n, true)`, from a script or a mod; the PARAMETERS menu reads with them) now leaves every voice where a normal read leaves it: its type, source and per-voice values take the file's, and a running voice is sent them. Before, each voice kept its old type, source and values, and played them, until each param next moved (#951).
