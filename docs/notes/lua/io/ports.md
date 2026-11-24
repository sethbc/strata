## Must not break

- **One module owns the MIDI ports**: only `lib/io/ports.lua` sets `midi.add`, `midi.remove` or a MIDI vport's `event` (a structure test holds every other `lib/**.lua` and `strata.lua` to a strict rule: no assignment to a field named `event` but on the few holders it lists, each with why (today three metros); no assignment to `midi.add`, `midi.remove` or through `midi[...]`; and the global `midi` used only as `midi.<name>`, `midi:<name>` or a `midi[...]` read, never given another name). A module listens through `M.listen`, sends through `M.out`, hears of devices through `M.on_change` and takes a port through `M.claim`; it never sets a handler itself, or two modules would overwrite each other (3.6 design §0.2, `docs/design/3.6-facts/code.md`).
- **A vport's `event` is the dispatcher exactly while the port has a listener** (the invariant `midi ports`): the first `listen` on a port sets it, the last `unlisten` clears it. Only this module sets an `event`, so a port with no listener has none.
- **Listeners run in the order their names were first registered**, each through `S.lib.ui_frame.contained_call`: one that raises prints one line (`strata: midi port <n> listener <name> failed: ...`, once per distinct message) and the next still runs. The same name again replaces its function and keeps its place. The dispatcher walks a copy of the names, so a listener may unlisten or listen while it runs.
- **The hot-plug handlers found installed still run**, after the `on_change` listeners, as the transport handlers chain (`lib/sequencer.lua`): the start step keeps the `midi.add` and `midi.remove` it finds (a mod's wrapper, midigrid's) and installs its own; the cleanup step puts them back. A handler something installed over the module's own since (a wrapper that calls it) stays installed, and the module's own, still in that chain, then only calls the kept one, so the chain still reaches the found handler. The start step run again never chains the module to itself: its own handler installed already, or a wrapper a cleanup left over it (which still leads to it, holding the kept handler), stays as it is and nothing more is kept; and each of its two handlers returns at once when called again from inside itself, so no chain can loop.
- **A port names no device while its device's removal is told** (#704): norns' `_norns.midi.remove` calls `midi.remove` (`removed` here) and only then clears the vport, so the vport still names the leaving device while the hooks run, and an owner that releases the port in its change hook runs every claim hook with the port still "holding" it (a waiting owner would claim and greet a device that is gone). `removed` marks the port from its entry until it returns, on every way out (a hook, the kept handler or the module raising included), and `device(port)` answers nil while it is marked. Only `device` and `removed` hold the mark: `out(port)` and the vport are unchanged, and a device moved in SYSTEM > DEVICES reaches `reconcile` after norns updated the vports, so `device` already agrees there. Tests: `a port names no device while its device's removal is told (#704)`, `a removal hook that raises leaves the port naming its next device`, `a device moved in the menu is named at its new port while the hooks run`.
- **The hot-plug handlers go on norns' own MIDI module, whatever a mod put in the global `midi`** (#700): the nbout mod replaces the global with a facade (from each script's pre-init hook to its cleanup) whose metatable has no `__newindex`, so an assignment to `midi.add` would land on the facade, where norns' hot-plug never calls it. The start and cleanup steps install and put back `add` and `remove` on `norns_midi()`: `package.loaded["core/midi"]`, what norns' startup's `midi = require 'core/midi'` loaded, found without naming a mod's field; the global where it is not found (the test stubs). Every vport is read from that module too, once per call and never per port inside a loop (`listen`, `unlisten`, `out`, `device`, hot-plug, `reconcile`, the start and cleanup steps, the invariant): the facade's `vports` is a fresh copy at each read, with an entry of its own after norns' sixteen, which the module never listens to or reports. Never read `midi.vports` or `midi.connect` through the global here.
- **Only this module reads norns' MIDI ports** (#700): every other `lib/**.lua` and `strata.lua` gets the port count from `M.PORTS.count` (set at include from norns' own module's `vports`: 16, never a facade's count) and a port's vport from `M.out(port)`, and never names `midi.vports`, `midi.devices` or `midi.connect` (a structure test, beside the one on `add`, `remove` and `event`). The global's pure functions (`midi.to_msg`, `midi.to_data`) read no port and stay. So under nbout the `midi_device` param stops at 16, and a MAP echo (`set_binary_param`) goes to `M.out(map.dev)`, sending nothing for a port with no vport.
- **A claimed port has one owner**: `claim` is refused (false) while another name holds the port, its owner may claim it again (true, nothing told), and only the owner's `release` frees it. `on_claim` listeners hear each change of owner, and nothing else. `lib/midi_in.lua` does not listen to a port another name owns, and SETUP's `midi` row shows `(<owner>)` for it.
- **A port settles once its arrival or release has reached every hook** (#772): `on_settled` hooks hear `fn(port)`, contained and in the order their names were first registered (a raising one prints `strata: midi settled hook <name> failed: ...` and the next still runs). A port settles exactly then: after a hot-plug arrival's change hooks (`added`); after a release's claim hooks; and once per `reconcile`, after every departure and arrival of that menu close has been told (one telling wraps them all, so a departure's release, such as a remote letting go of the port a device was moved onto, never settles that port before its arrival is told and claimed). Every arrival, departure, claim and release is told through `told`, so any claim or release a hook makes meanwhile is told first: a telling inside another (a release inside a departure's, an arrival's or a claim's hooks, a claim taken straight back inside a release, a release or claim a settled hook makes) only queues its port, and the outermost settles the queue (#788). Ports settle in the order told: each joins the queue as its own telling ends, so a port released inside another telling queues before the port of the telling it is inside, and a port already queued keeps its first place; in a `reconcile` that is each port a departure's release queued (it settles even when nothing arrives there), then each arrived port in port order. So a port never settles while one of its hooks is still to run, a release taken straight back settles once with the new owner in place, and a release inside a claim's hooks settles after that claim's last hook. A settled hook reads the port as it then is: `device(port)` answers nil for a hot-plug removal (a release inside its departure settles before `removed` returns) and for a port a menu move left empty, and names the new device for a port that lost one device and gained another in the same `reconcile`. Never for a departure itself, a claim or a port outside 1..16. "Every hook" means the module's own hooks: a kept `midi.add` handler (a mod's wrapper, midigrid's) runs after `added` has settled the port, harmless today since none of them claims a port through this module. MIDI out sends a zone's setup from here (`docs/notes/lua/io/midi_out.md`). Tests: `on_settled hears a port once its arrival or release has reached every hook, a claim made by one included`, `a reconcile settles each moved port once, after every move it tells`, `a release inside a departure's hooks settles once, after every change hook`, `a settled hook that claims or releases a port settles each port once`, `a release made inside a claim's hook settles after every hook of that claim has run`.
- **Ports are 1 to 16** (`M.PORTS.count`, norns' vports): a port outside that, or a fraction, does nothing; `listen` returns nil, `claim` false, `out`, `device` and `owner` nil. A bad name or function is a caller's error and raises.
- `S.lib.io_ports` is included directly before `lib/midi_in.lua`, its first user.
- **The tellings' order is part of the protocol** (#936): the change, claim and settled hooks of `io_midi_out`, `remote`, `midi_in` and `io_controllers` run in the order their names were first registered (`io_midi_out` and `remote` at include, `midi_in` at start step 90, `io_controllers` at 94), and each reads `device`, `owner` and `S.lib.io_remote.holds` mid-telling. Three answers carry weight: the owner is recorded before `holds` is true (a claim's hooks run before `connect` sets `claimed_port`, so MIDI out can still send the offs, #769); `holds` is false during a release (#772); `device` is nil during a removal (#704). An event queue would make the hooks read the answers after the change and undo all three. The table below (The tellings) is what the hooks read; a test holds it.

## Machines

### midi ports
- **State:** `listeners[port]` and `dispatchers[port]` against each vport's `event`.
- **Invariant:** `midi ports`: a vport's event is the dispatcher exactly while the port has a listener.
- **Test:** `test/unit/io_ports_test.lua`: "the midi ports invariant names a port whose event and listeners disagree".

A two-state fact per port (listened to or not), so no table: `listen` and `unlisten` are its only changes.

### port tellings
- **State:** per port, `owners[port]` (free or named), the device on the vport and `seen[port]`, `leaving[port]` (set only inside `removed`); for the module, `telling` (how deep the tellings nest), `unsettled` and `settling`; named by `device(port)`, `owner(port)` and `S.lib.io_remote.holds(port)`.
- **Invariant:** none: the tellings are an order of calls, not a state that can be wrong at rest (no telling is open between two events); the listeners are `midi ports`'.
- **Test:** `test/unit/io_ports_test.lua`: "port tellings: each event's hooks run in their order, each reading device, owner and holds as the table gives" and "port tellings: the notes' table equals the test's rows".

Its table is no transition table: it gives, by event, each hook as it is entered and what it reads, under The tellings below.

## The tellings

The hooks as each event enters them, in order, and what `device(port)`, `owner(port)` and `holds(port)` (`S.lib.io_remote.holds`) answer at each one's entry. The remote grid's rig port is 3. `arrive`: `iii grid` plugged into port 3 (the remote's change hook claims it, so the claim's hooks run inside it); `leave`: that device unplugged while the remote holds the port (the remote's change hook releases it, inside the removal); `claim`: the rig set to 3 with the device there; `release`: the rig set to 0; `menu close with a move`: the device moved in SYSTEM > DEVICES from port 2 onto port 3, and the menu closed (every departure, then every arrival; only the arrived port settles). A row is one hook's entry; a nested telling's rows stand between the rows of the hook that made it.

| Event | Hook | Port | `device` | `owner` | `holds` |
|---|---|---|---|---|---|
| arrive | change `io_midi_out` | 3 | `iii grid` | nil | false |
| arrive | change `remote` | 3 | `iii grid` | nil | false |
| arrive | claim `io_midi_out` | 3 | `iii grid` | `remote grid` | false |
| arrive | claim `remote` | 3 | `iii grid` | `remote grid` | false |
| arrive | claim `midi_in` | 3 | `iii grid` | `remote grid` | false |
| arrive | claim `io_controllers` | 3 | `iii grid` | `remote grid` | false |
| arrive | change `midi_in` | 3 | `iii grid` | `remote grid` | true |
| arrive | change `io_controllers` | 3 | `iii grid` | `remote grid` | true |
| arrive | settled `io_midi_out` | 3 | `iii grid` | `remote grid` | true |
| leave | change `io_midi_out` | 3 | nil | `remote grid` | true |
| leave | change `remote` | 3 | nil | `remote grid` | true |
| leave | claim `io_midi_out` | 3 | nil | nil | false |
| leave | claim `remote` | 3 | nil | nil | false |
| leave | claim `midi_in` | 3 | nil | nil | false |
| leave | claim `io_controllers` | 3 | nil | nil | false |
| leave | change `midi_in` | 3 | nil | nil | false |
| leave | change `io_controllers` | 3 | nil | nil | false |
| leave | settled `io_midi_out` | 3 | nil | nil | false |
| claim | claim `io_midi_out` | 3 | `iii grid` | `remote grid` | false |
| claim | claim `remote` | 3 | `iii grid` | `remote grid` | false |
| claim | claim `midi_in` | 3 | `iii grid` | `remote grid` | false |
| claim | claim `io_controllers` | 3 | `iii grid` | `remote grid` | false |
| release | claim `io_midi_out` | 3 | `iii grid` | nil | false |
| release | claim `remote` | 3 | `iii grid` | nil | false |
| release | claim `midi_in` | 3 | `iii grid` | nil | false |
| release | claim `io_controllers` | 3 | `iii grid` | nil | false |
| release | settled `io_midi_out` | 3 | `iii grid` | nil | false |
| menu close with a move | change `io_midi_out` | 2 | nil | nil | false |
| menu close with a move | change `remote` | 2 | nil | nil | false |
| menu close with a move | change `midi_in` | 2 | nil | nil | false |
| menu close with a move | change `io_controllers` | 2 | nil | nil | false |
| menu close with a move | change `io_midi_out` | 3 | `iii grid` | nil | false |
| menu close with a move | change `remote` | 3 | `iii grid` | nil | false |
| menu close with a move | claim `io_midi_out` | 3 | `iii grid` | `remote grid` | false |
| menu close with a move | claim `remote` | 3 | `iii grid` | `remote grid` | false |
| menu close with a move | claim `midi_in` | 3 | `iii grid` | `remote grid` | false |
| menu close with a move | claim `io_controllers` | 3 | `iii grid` | `remote grid` | false |
| menu close with a move | change `midi_in` | 3 | `iii grid` | `remote grid` | true |
| menu close with a move | change `io_controllers` | 3 | `iii grid` | `remote grid` | true |
| menu close with a move | settled `io_midi_out` | 3 | `iii grid` | `remote grid` | true |

So: a claim's hooks read the new owner with `holds` still false (the claim of an arrival included, inside the remote's change hook), and the change hooks after the remote's read it held; a removal's hooks, and the release and the settle inside it, read no device; a release's hooks and its settle read the port free; a menu move's departures settle nothing, and its arrival settles after every move is told.

## Owns

`lib/io/ports.lua` (`S.lib.io_ports`, 3.6):
- `M.listen(port, name, fn)`, `M.unlisten(port, name)`: `fn(data)` gets every message of the port, the raw bytes norns delivers to `vports[port].event`;
- `M.out(port) -> vport | nil`: the port's vport (norns' own `vports[port]`), to send through (`:note_on`, `:cc`, ...);
- `M.device(port) -> name | nil`: the name of the device on the port (the vport's name while it holds a device);
- `M.device_handled(port) -> boolean`: whether the port's device has a device-level `event` handler set (norns' `midi.devices[id].event`, which norns calls before the vport's). Strata never sets one and norns' `midi.cleanup` clears them, so a set one is another library's: midigrid's, on each Launchpad it takes (`docs/design/3.6-facts/checks.md` §7). `lib/io/remote.lua` claims those ports as `midigrid` while its object is attached. False outside 1..16 and while the port's device is leaving;
- `M.on_change(name, fn)`: `fn(port, device_name | nil)` when a device arrives at or leaves a port: an arrival names the device now there, a departure passes nil, and a hook hears nothing else. A move in SYSTEM > DEVICES has already changed the vport when `M.reconcile` tells of it, so during a departure's hooks `device(port)` names the device that came. A departure does not name the device that left (MIDI out keeps the name of the device each note went to, `docs/notes/lua/io/midi_out.md`);
- `M.claim(port, name) -> boolean`, `M.release(port, name)`, `M.owner(port) -> name | nil`, `M.on_claim(name, fn)`: `fn(port, owner | nil)`;
- `M.on_settled(name, fn)`: `fn(port)` once a port's arrival or release has been told to every change and claim hook, once per `reconcile` after all its moves (Must not break);
- start step 88 (`START_ORDER.io_ports`, before `midi` 90) and cleanup step 152 (`CLEANUP_ORDER.io_ports`, after `midi_handler` 150);
- the invariant `midi ports`.

## How it works

- State is one local table: `listeners[port]` (an ordered set: `names` in first-registered order, `fns[name]`), `dispatchers[port]` (made once per port and kept, so the invariant can compare), `owners[port]`, `seen[port]` (the device object last seen on the port), the contained calls' `errors`, the `on_change`, `on_claim` and `on_settled` sets (`changes`, `claims`, `settles`), the telling count with the ports still to settle (`telling`, `unsettled`, `settling`; `told(port, settles, run)` wraps every telling), and `hot_plug` (the kept handlers and whether the module's own are installed).
- **Hot-plug.** norns puts a device on its vport (`Midi.update_devices`) before calling `midi.add`, and clears it only after `midi.remove` returns. The module's `midi.add` records the device as seen on `device.port`, tells `on_change(port, device.name)`, then calls the kept `midi.add`; its `midi.remove` forgets it, tells `on_change(port, nil)`, then calls the kept `midi.remove`. A device on no port (all sixteen named, or norns' virtual device) tells no listener; the kept handlers still run.
- **Moves in the menu.** SYSTEM > DEVICES moves a device with `update_devices()` only, calling neither handler. The module's menu-close hook (`M.reconcile`, registered with `S.register_menu_close` at include time, so it runs before `lib/midi_in.lua`'s) compares each port's device with the one last seen: every port that lost its device tells `on_change(port, nil)`, then every port that gained one tells `on_change(port, name)`, in port order (a swap is both). A visit that moves nothing tells nothing. Before the start step it does nothing.
- **Claims** call `request_redraw()` (SETUP's `midi` row, and IO's sections later).
- **Cleanup** (step 152, after `lib/midi_in.lua` has unlistened at 150): the kept handlers back (a wrapper over the module's own stays, and the kept handler is still called through it; from then on the module's hot-plug handlers tell no listener), every `event` that is still one of the dispatchers cleared, and the listeners forgotten, so the invariant holds after cleanup. Owners and the `on_change`, `on_claim` and `on_settled` sets stay: their modules release in their own cleanup steps, all before 150.

## Tests

`test/unit/io_ports_test.lua`: the listeners' order and containment, a message on another port, the invariant, `on_change` for an arrival, a departure and a menu move, the handlers found installed (put in through `load_strata({before_init = ...})`, which runs after the script is loaded and before `init()`), a wrapper installed after init that still reaches them after cleanup, the start step run again after that cleanup, the claims, the settled hook (an arrival, a release, a reconcile's moves, a release inside a departure or a claim's hook, a settled hook that claims or releases), `out`, and the table `port tellings` (each module's hook wrapped where it stands, by its own name registered again, so the script runs as it does). `test/unit/midi_in_test.lua` ("MIDI in leaves a claimed port alone", the port moved onto a claimed one, and MIDI keeping its place among its port's listeners), `test/unit/pages_setup_test.lua` (the `midi` row's owner) and `test/unit/structure_test.lua` (the steps, and only this module setting the handlers) cover the rest.

## The io modules' lifecycle flags

Seven flags under `lib/io/` say whether a module is before its start, running or after its cleanup (#938). Each flips at its own module's start or cleanup step (or, for nb, its params), not at one phase of the script's, so they are seven facts and no accessor joins them (plan ruling 14): between two steps one module is running while the next has not started or has already stopped, and each guard needs its own module's answer.

| Module | Flag | Set by | Cleared by | What it guards |
|---|---|---|---|---|
| `lib/io/ports.lua` | `hot_plug.installed` | start step `io_ports` (88): true | cleanup step `io_ports` (152): false | the hot-plug handlers tell the change hooks, and `reconcile` tells a menu move, only while it is true; the kept handlers run either way |
| `lib/io/crow.lua` | `started` | start step `io_crow` (92): true | never | a jack's lines are sent only once started (`active()`); the cleanup step does nothing before a start |
| `lib/io/crow.lua` | `stopped` | cleanup step `io_crow` (145): true | never | `send_now` and `send_value` send nothing, the hot-plug handlers and events do nothing, `on_event` installs nothing |
| `lib/io/ii.lua` | `started` | start step `io_ii` (93): true | never | with `stopped`, `active()`: a crow's setup takes the lead or sends Teletype's handlers, the `ii_bus` listener acts, Teletype's calls are answered, the handlers' wait sends |
| `lib/io/ii.lua` | `stopped` | cleanup step `io_ii` (144), `M.stop()`: true | never | `active()` false; no off is owed while stopped; `M.stop()` runs the leaving sequence once |
| `lib/io/controllers.lua` | `closing` | cleanup step `io_controllers` (146): true | start step `io_controllers` (94): false | a port released during cleanup is not claimed again by a controller that wants it (`port_released`) |
| `lib/io/remote.lua` | `started` | start step `io_remote` (95): true | closing step `io_remote_closing` (143): false, before the controllers' release (#1033) | `connect`, `rescan`, the rig listeners and the ports' change and claim hooks act only while it is true; MIDI out's settled hook sends no zone setup while it is false (`started()`, #1010) |
| `lib/io/midi_out.lua` | `stopped` | cleanup step `io_midi_out` (151), `M.stop()`: true | never | nothing is sent (`send`), no note starts, the step, ports and scene hooks, `settle` and program change in do nothing; the cleanup's takedowns go once |
| `lib/io/nb.lua` | `added` | `M.add_params()` (the params record `out nb`, in init before any start step): true | never | IO's voice rows show the player selector, and the PSET hook stops the chosen players, only once the params exist |

The cleanup order 142 to 152 is itself the io modules' protocol: every target note off (142), the remote's flag down (143, so no release hands it a port, #1033), the ii leave (144), crow's outputs off (145), the controllers' and the remotes' releases (146, 147; the remotes' pays what MIDI out owes a synth on a held port, #1010), OSC (148), the tape (149), MIDI in (150), the zones down (151), the ports (152).

