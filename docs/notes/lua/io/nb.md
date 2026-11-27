## Must not break

- **Strata loads no nb file and copies none of nb's code** (nb declares no license). It does an nb host's eight duties itself, from `docs/design/3.6-facts/checks.md` section 1 (issue #698); each is marked below as settled by nb's source or a choice.
- **A player's method is called only when `rawget(player, method)` is a function**: `note_on`, `note_off`, `stop_all`, `active`, `inactive`, `delayed_active`, `add_params`. Another host (nbout, nbin) may have put nb's player base on every entry as a metatable, so a plain index would find methods the mod never wrote. The module never sets or reads a player's metatable.
- **One count per change of player**: ordinary key changes and the PSET hook both use the same selection path, and `choose(voice, key)` does nothing when the voice already plays that key. A move from one player to another counts the old one down and the new one up; the voice's notes end first (`S.lib.io_targets.route_changed`), each on the player it started on.
- **`nb_player_refcounts` is created when nil and never replaced**; a missing entry is 0, and **an entry that reaches 0 is removed**, never left at 0: nb's own host activates a player only when its entry is nil and removes it at 0 (nb `400e0b38`, `count_up` and `count_down` in nb's own `player.lua`), so a `0` left behind would keep nbout's selector from ever activating a player Strata chose and left. The count used is the larger of the global entry and this module's own uses of the name, so a host that empties the table (nbin's `nb:init`, after Strata's `init`) neither makes Strata activate a player twice nor deactivate one a voice still plays, and a player Strata activated is still deactivated when its last voice leaves it.
- **`player.name` is set before the player is activated** (nb_drumcrow's `active` does nothing without it).
- **`note_players` is read in `add_params()`, at init, never at include**: the voice mods fill it in `script_pre_init`, after the script file has run.
- **Every player call is contained** (`S.lib.ui_frame.contained_call`, one printed line per new error): a mod's error never ends a param action, a PSET read or a note.
- **Apply the effective keys before stopping players on a PSET read.** The keyed module keeps the saved name in `v<i>_out_nb_key` and resolves it to an installed player or `none`. Its hook runs before `io_nb` in registration order. The nb hook passes each effective key to `choose`, including on a silent read that skipped the param actions, then calls each chosen player's `stop_all` once.
- **Strata's own sends**: the module sends nothing to crow, ii or MIDI itself. A player that does is another program's (design §7, decision 21); IO warns of it.
- **Nothing by default**: with no entry in `note_players` every voice's list is `none`, no player is called, and no separator or sentinel is added.

## Machines

### nb players
- **State:** `state.chosen[voice]` (the player each voice plays), `state.uses[key]` (the voices choosing it), the global `nb_player_refcounts` (shared with other hosts, taken as at least Strata's own uses) and `state.activations[key]` (nb's default activation clock).
- **Invariant:** `nb`: each player's count of the voices that use it is a whole number, never below 0.
- **Test:** `test/unit/io_nb_test.lua`: "the nb invariant names a count below 0", "the nb invariant names a count that is a fraction", "the nb invariant names a count that is not a number" and "the nb invariant holds as voices choose, change and leave players".

No table: a player is active while its count is above 0, one count up and one down per choice (`choose`), as Must not break gives.

## Owns

`lib/io/nb.lua` (`S.lib.io_nb`), included after `lib/io/crow.lua`:
- `NB`: `none = "none"`, `midi_prefix = "midi: "`, `delayed_seconds = 1`, `sentinel = "nb_sentinel_param"`, the selector's id form, the warning's text, the mark `[!]`, the group and separator ids.
- `add_params()` (the menu record `out nb` of `lib/params_setup.lua` calls it at init): the group `strata_out_nb`, 14 params, a voice's `S.lib.io_keyed.add("v<i>_out_nb", ...)` each (the option and its hidden text param `v<i>_out_nb_key`); then, unless `nb_sentinel_param` exists or `note_players` is empty, the separator `strata_nb_players` (`nb players`), every entry's own `add_params` in name order and the hidden binary `nb_sentinel_param`.
- The note target `nb` (`S.register_note_target`): `routed`, `note_on`, `note_off`, `stop_all`, `rows`, `status`.
- A voice-stop hook (`S.register_voice_stop`), the PSET hook `io_nb` and the invariant `nb`.
- No start or cleanup step: the targets core's cleanup step (`CLEANUP_ORDER.io_targets`) calls this target's `stop_all`.
- Tests: `test/unit/io_nb_test.lua`, against the nb stub (`context.nb.add_player`). User page: `docs/user/io/nb.md`.

## The eight duties

1. **Read `note_players` at init** (settled). Nil or empty: the list is `none`.
2. **Leave out every name that begins `midi: `** (a choice): nb's own MIDI players, made by whichever host last ran `nb:init`, possibly for a device that has gone; Strata has its own MIDI out. A name the keyed module refuses (`S.lib.io_keyed.refuses`, the one check its `add` makes, so `add` never raises at init: it reads as a number, holds a newline, starts or ends with a space; `docs/notes/lua/io/keyed.md`) and a player named `none` are left out too, each with one console line, `strata: nb player "<name>" left out: <why>` (`reads as a number`, `a newline`, `a surrounding space`, `the name Strata gives no player`).
3. **Find a mod's methods with `rawget`** (settled that `rawget` sees only the table's own fields; using it is a choice).
4. **Set `player.name = key` before activating** (settled).
5. **Count in the global `nb_player_refcounts[name]`** (a choice), as above: a missing entry is 0, and an entry is removed when it reaches 0, as nb's own `count_down` does (`checks.md` section 1 gives the first half only; its duty 5 needs the second for the docs pass). A player another host holds (its entry 1) is neither activated nor deactivated by Strata's choice and leave, and is left at 1.
6. **Activate as nb's base does** (a choice the source makes the right one): on a count from 0 to 1 the player's own `active`, else `is_active = true` and, in `player.active_routine`, a clock that after `NB.delayed_seconds` calls its own `delayed_active` if `is_active` is still true; on a count back to 0 its own `inactive`, else `is_active = false` and the clock stopped. The clock is `S.lib.clocks`' (#870, `docs/notes/lua/clocks.md`; its handle in `state.activations[key]`, its id in `player.active_routine` as nb's base keeps it): stopped with `S.lib.clocks.stop`, retired, never canceled, while its resume may be posted, so it ends at that wake calling nothing. On deactivation, Strata retires its fallback handle and clears its matching public ID before calling the player’s own inactive hook (#1242). A handle whose clock is no longer alive (another host's base canceled `active_routine`) is not stopped again, only forgotten. Before any count `add_params` sets `is_active = false` on every listed entry (a stale one comes only with a carried-over entry; a choice).
7. **Add the players' params once** (settled that nb does so): unless `params.lookup["nb_sentinel_param"]` exists, every entry's own `add_params` in name order, the `midi: ` entries included (a choice that keeps nbout's own selector working, since its `add_player_params` then skips them), then the hidden binary sentinel. Two choices of Strata's: the separator `nb players` goes first (it heads the players' params in the menu, so a plain one never reads as part of `strata_out_nb`; and the test stub, which norns does not, refuses a plain param right after a full group as a sign of a wrong group size), and with no entry nothing is added at all (there are no params to guard).
8. **Keep the chosen name in a hidden text param** (settled; the keyed module's work), and **call each chosen player's own `stop_all` at a PSET load** (a choice nb recommends and never makes). A name the list lacks shows `none` and is kept, and a later load whose list has it selects it; a voice's player is always `S.lib.io_keyed.key("v<i>_out_nb")`.

## How it works

- `state.players[key]` is each listed player's table, taken at init; `state.chosen[voice]` the key it plays (nil for none); `state.uses[key]` how many voices choose it; `state.notes[voice][id] = {player, key, note}` for each note sent on, so its off goes to the player that took its on.
- `note_on(voice, id, pitch, velocity)` sends `note_on(math.floor(pitch + 0.5), velocity)`; `note_off(voice, id)` sends `note_off(note)`; `stop_all` (the core's, at cleanup) forgets the notes and calls each chosen player's own `stop_all` once; the voice-stop hook calls the stopped voice's player's.
- `rows(voice)`: a `param` row `nb` for `v<voice>_out_nb`, and while any voice has a player a `status` row `nb mods send on their own` (id `nb warning`; design §7 words it `nb voices send on their own`, 122 px, 2 px wider than a status row's room, so it was shortened). `status()`: `[!]` while any voice has a player and the rig's `ii_bus` (`S.lib.io_rig.get`) is not `strata`, since such a player may lead the bus whatever the setting says. Strata cannot tell which players send to crow or ii, so neither depends on the player.
- Unverified until the 4.0 hardware check (#6): what a mod does when its `active` or `delayed_active` runs late or twice, and which carried-over entries besides `midi: ` players a real session holds.
