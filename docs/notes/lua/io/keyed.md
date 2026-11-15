## Must not break

- **A PSET keeps the key, never the index.** `M.add` adds an option param (`save` off, so norns never writes its index) and directly after it a hidden text param `<id>_key` holding the chosen key, which is what a PSET keeps. A list that gains an entry (a modulation source a later release registers ahead of the saved one) never moves a saved choice onto another.
- **The key wins whatever order a read sets the two in.** The option's action stores its key in the text param silently, then calls the action; the text param's action selects the key's option silently, then calls the action. After every PSET read the module's PSET hook (`io_keyed`) puts each keyed param on the key the file holds, or on the first key when the file holds none (a PSET saved before the param), and leaves alone one already there, so a plain read acts once.
- **A key the list lacks is kept.** It shows the first option, the text keeps the key (so a PSET written now keeps it, and a later release whose list has it selects it), and the action gets the first key. `M.key(id)` is the key in effect: the text's when the list has it, else the first.
- **Two params per call**: a group's count allows for both.
- `add` run again for an id (init run again on the same `S`, which only a test does) replaces its record; a second id in one paramset is norns' own error.

## Owns

`lib/io/keyed.lua` (`S.lib.io_keyed`, 3.6), included directly before `lib/io/crow.lua`, its first user:
- `M.add(id, name, keys, labels, action)`: the option `id` (one label per key, in order; the first key the default) and the hidden text param `id .. "_key"`; `action(key)` after each choice and each key set.
- `M.key(id) -> key`.
- The PSET hook `io_keyed` (`S.register_pset_hook`, its `read`).

Users: crow's `crow_out<n>_source` (`docs/notes/lua/io/crow.md`). MIDI out's CC slots and the nb selector are meant to use it too (design §7's remedy for nb's selector). Tests: `test/unit/io_keyed_test.lua`.
