# Facts: the state machines of outside devices (Lua)

Gathered on 2026-11-21 from `main` at a1c8e8b4 (3.8.0) by a read-only audit of this area, for `docs/design/3.9-state-machines-design.md`. Line numbers are that commit's. In the tables, a recommendation is one of: (a) leave the code and add a state table to the notes; (b) one named state value with one transition function; (c) a table-driven test of the transitions, code unchanged; (d) nothing. The design weighs them again and does not always follow them. A probe is a scratch unit test the audit ran against the harness: the seven probe files are in `probes.md`.

One scratch file exists outside the repo: three probes, run with `lua test/run.lua --dir`, at `probes.md`. The repo is untouched.

# Summary

| # | Machine | Owner | States | Transition bugs | Inv / table / model | Rec | Conf |
|---|---|---|---|---|---|---|---|
| 1 | MIDI out note record × port events | `lib/io/midi_out.lua` | live, held, departed × count 0/1/2+ | 10: #709, #747-#750, #767, #769, `f73946c8`, `83d454dd`, `0681a2d9` | counts ≥ 0 only / count table only / none | (c) model walk, then (a) | high |
| 2 | Port tellings: arrive, leave, claim, release, settle | `lib/io/ports.lua`, hooks in four modules | free/owned × absent/present/leaving × telling depth, settling | 5: #704, #772, #788, #753, `fa0fa23f` | listeners only / none / none | (a) sequence table + (c) | high |
| 3 | MIDI out zone per port | `lib/io/midi_out.lua` | none, up, setup due, takedown due × held | 3: #772, #788, #789 | none / none / none | (a) + two invariant lines | high |
| 4 | ii lead | `lib/io/ii.lua` | 6 | 3: `f37ee080`, `17b299e9`, #751 | none / yes / none | (c) as an invariant, plus show owed | med-high |
| 5 | ii queue lines and turns | `lib/io/ii.lua` | per line: unlearned, unknown, high, low × waiting | 10: `35dd565b`, `eaf2ecf7`, `5b0a859a`, `af4f94dd`, #710 (4 commits), #717, #719 | one assert / yes / flood test | (c) invariant; copy its table | high |
| 6 | TELEXo and ER-301 lines, TXo `active` | `lib/io/txo.lua`, `er301.lua` | per line: empty, n notes, env high; active set | 5 + one new: #752, `60eb5a56`, `8c3dfbc0`, `d56a3c96`, `dab6e9c5` | none / none / none | fix the new one, then (d) | high |
| 7 | Remote kind record, midigrid claims | `lib/io/remote.lua` | 6 | 5: `164916cf`, #704, #753, `41841d42`, `b1b427ee` | yes / none / none | (a) | medium |
| 8 | Targets ledger | `lib/io/targets.lua` | per id: silent, sounding (+ off pending); per target: failed | 3: `e64aad25`, `04cbcc2f`, `2bccca4f` | yes / none / system test | (d) | high |
| 9 | MIDI out route settle | `lib/io/midi_out.lua` | settled, noted | 3: `becdb3fc`, `d0eee45b`, `62974766` | yes / none / none | (d), pattern to copy | high |
| 10 | crow jacks, controllers, nb, OSC, tape, W/ tape, keyed, rig, PC guard, MIDI-in listening | their files | 2-4 each | 0-2 each | rig only | (d) | high |

The five things most worth knowing:

1. **These machines are synchronous and re-entrant on purpose.** Hooks read mid-transition answers: `device(port)` is nil while a device leaves, the owner is recorded before `holds` is true, the lead flag stays set through the leave. A run-to-completion FSM would change those answers, so (b) is wrong for the port and claim family.
2. **Nearly every bug was a wrong transition in the product of two machines owned by different modules** (note × port event, zone × claim). End-of-test invariants cannot see them, and no model walk covers `lib/io`. One walk with a per-device oracle (ons equal offs, nothing to a held port) is the highest-value item.
3. **Second records caused the bugs; compare-at-use is clean.** `held_owner`, `setup_due`, `takedown_due` and the TXo's `active` each shadow a fact owned elsewhere. `settle`, `settle_moved`, `follow_owners`, `refresh` and `status(kind)` compare at use and have little or no later history.
4. **Three player-facing gaps, each confirmed by a probe:**
   - Owed ii offs are invisible, and nothing lowers them while the bus is off.
   - A voice routed to a port a remote holds plays nothing, and IO's voice row shows no mark.
   - A TELEXo envelope setup refused by a full queue is recorded as done and never retried.
5. **`ii.md`'s state tables and `rig.lua` are the patterns to copy.** ii, crow, controllers, nb and OSC have no invariant. AGENTS.md has 77 words left, so every table goes in a notes file. Nothing here has run on hardware (#6).

# Full report

## Context

- **Age:** the whole area was built from 2026-11-14 to 11-18 by agents in review-fix rounds (`git log -- lib/io/`: `midi_out.lua` 25 commits, `ii.lua` 16, `ports.lua` 14).
- **Bug source:** every bug below was found by a review or the whole-system test, none on a device (`docs/status.md:191`).
- **Tests:** black-box and by example. State is a local `state` table per module, reached only through accessors (`queued`, `owed`, `holds`, `status`, `sounding`, `budget_state`, `clock_id`). `test/notes_model.lua` names no io module (grep). `test/unit/io_system_test.lua` (1696 lines) is one scripted minute, not a walk.
- **Notes:** rules are prose. The longest single bullets are 1002 words (`ii.md`), 882 (`midi_out.md`) and 463 (`ports.md`).

## 1. MIDI out: a note's record against port events

**Owner and state.** `lib/io/midi_out.lua:51-58`: `notes[voice][id]`, `counts`, `use`, `left_with`, `expressing`. Transitions: `start_note` :307, `end_note` :267, `set_aside` :237, `settle_moved` :256, `departed` :541, `pay_owed` :577, the claim hook :652, `reconcile_owed` :623.

**States.** A record is live, `held` (started while a remote held the port, :322-326) or `departed` (:238). Per port, channel and note the count is 0, 1 or 2+. Held and departed together is reachable: `set_aside` marks a held record departed and returns (:238-239). It is harmless because `end_note` returns on either (:275).

| Event | Live | Held | Departed |
|---|---|---|---|
| Its end | count table, off at the last id | nothing | nothing |
| Device leaves, or the port is settled with another device | set aside, owed to `record.device` | marked only | - |
| A remote claims the port | off now, set aside owed to none (:663-673) | - | - |
| Its device arrives, or the menu closes | - | - | the owed offs paid, by device name |

**Outside writers and readers.** Only through `S.lib.io_targets` (`note_on`, `note_off`), `S.lib.io_ports` hooks, `S.lib.io_remote.holds` (:81-84) and `held_by` (:638).

**Guards.** The invariant checks counts ≥ 0 and legal routes only (:1008-1024). `midi_out.md` has the count table but no record-state table. 98 example tests.

**History.** Ten transition bugs, all "an event met a record in a state the handler had not considered":
- #709: 21 ons and 1 off on a channel.
- `f73946c8`, `83d454dd`, `0681a2d9`: a device moved in SYSTEM > DEVICES.
- #747-#750: away and back in one visit, an empty port, expression to the newcomer, CC 123 cutting a new note.
- #767, #769: around a remote's claim.

No illegal state was ever the bug.

**Flags that hold more than one fact.**
- `departed` means "send nothing more of this": it is set for a device that left, for a note ended at a claim (:669) and for a held note.
- `record.device == nil` means "the port was empty at the on, owed to none" (:254-262).
- `left_with` is keyed by device name, so two devices of one name share debts (`midi_out.md`, "Two edges stay").

**Why this shape.** norns changes vports in the menu before anything is told, so the module compares `record.device` with `device(port)` at each send (`settle_moved`). That compare-at-use fix ended the menu bugs.

**Recommendation: (c), then (a).** A seeded walk over note start and end (step, played, MPE), unplug, plug, a menu move with its close, a remote's claim and release, a route change, a stop and cleanup. Its oracle is per device in the stub. The two documented edges become allowances. Add a small record-state table to `midi_out.md`. Not (b): a `state` field saves one boolean and risks the #769 ordering. Cost about a day; code unchanged. Bugs 10, blast radius high (a hung note on a synth), confidence high.

## 2. Port tellings

**Owner and state.** `lib/io/ports.lua:48-60`: `owners`, `seen`, `leaving`, `telling`, `unsettled`, `settling`, `hot_plug`. Transitions: `claim` :214, `release` :229, `added` :259, `removed` :268, `reconcile` :290, `told` :107, start :320, cleanup :336.

**States per port.** Owner free or named; device absent, present or leaving (`leaving[port]` only inside `removed`). Globally: telling depth 0..n and `settling`. Meant impossible: a settled hook running at depth above 0, or a port queued twice (:112-116).

**The protocol is spread over five modules' hooks**, which run in first-registration order:

| Hook set | Order | Where registered |
|---|---|---|
| change | `io_midi_out`, `remote`, then `midi_in`, `io_controllers` | `midi_out.lua:584`, `remote.lua:490` at include; `midi_in.lua:599`, `controllers.lua:530` at start |
| claim | the same order | `midi_out.lua:652`, `remote.lua:509`, `midi_in.lua:600`, `controllers.lua:531` |
| settled | `io_midi_out` | `midi_out.lua:607` |

Three order-of-calls conventions carry real weight:
- **Owner before `holds`.** `connect` calls `claim` before it sets `claimed_port` (`remote.lua:342-346`), so MIDI out's claim hook can still send the offs (#769).
- **`holds` false during a release.** `disconnect` releases while `claimed_port` is still set, so its own claim hook does not take the port back (`remote.lua:359-363`), and `holds` therefore also checks the owner (:219-225). `claimed_port` holds two facts: "the port I listen on" and "the port I hold".
- **`device()` nil during a removal** (#704, `ports.lua:170-171`).

**Guards.** The invariant covers listeners against dispatchers only (:357-367). No States table. 23 example tests, five on settle order.

**History.**
- `fa0fa23f`: the start step chained to itself.
- #704: a leaving device handed on. Its fix removed the remote's own `state.leaving`, a second record (`docs/decisions/3.6.md:46`).
- #772: a port settled before its arrival's claim; `reconcile` settled per move.
- #788: a release inside a claim's hook settled too early.
- #753: an arrival not rechecked for midigrid.

All were wrong orders between legal states.

**The naive refactor that breaks it.** An event queue would make hooks see post-transition answers and undo #704, #769 and #772. Only the settled telling is deferred, deliberately.

**Recommendation: (a) + (c).** One table in `ports.md`: per event, the hook order and what `device`, `owner` and `holds` answer at each hook. One table-driven test asserts exactly that with recording hooks. Cost half a day; code unchanged. Bugs 5, blast radius high (every MIDI module), confidence high.

## 3. MIDI out: a port's MPE zone

**Owner and state.** `state.config` (zones derived by `zones_of` :745), `setup_due`, `takedown_due`, `held_owner` (`midi_out.lua:46-54`). Writers: `apply` :758-794, the change hook :584-598, the claim hook :652-660, the settled hook :607-617, `stop` :992-999.

**States per port.** No zone; zone set up; setup due; takedown due; each also held or free.
- `setup_due` and `takedown_due` are exclusive by construction (`apply` clears one where it sets the other, :776-787). Nothing asserts it.
- `held_owner[port]` copies `ports.owner(port)` for holder names. Nothing asserts they agree.

**Triggers owned elsewhere.** Both due marks are flushed only by `S.lib.io_ports`' settled telling, and cleared by a departure (:589), a later `apply` or cleanup.

**History.** #772 (setup reached a held device, and none after a release), #788 (takedown dropped while held), #789 (zone left at script end). Three bugs in two days, each fixed by adding a second record.

**Belief not read back.** `setup()` to a port with no device sends nothing, and the arrival's mark covers it (:594). The bend ranges a setup sent are never put back (`midi_out.md`).

**Recommendation: (a) + two invariant lines** (not both due; `held_owner` agrees with the owner while not stopped). The four-state table belongs next to machine 1's, and the walk of machine 1 can carry zone messages in its oracle. Bugs 3, blast radius medium, confidence high.

## 4. The ii lead

**Owner and state.** `lib/io/ii.lua:72-74`: `started`, `stopped`, `leading`, `owing`, `leave_room`, `handlers_wait`, plus the rig's `ii_bus` and crow's presence. Transitions: `take_lead` :458, `give_up_lead` :477, `crow_gone` :512, `set_up` :532, the rig listener :547, `stop` :702.

**Real states.** Not started; idle (off, or strata without a crow); leading; leaving (`leave_room` set, flag still set); owing (crow left mid-lead); teletype answering; teletype with handlers waiting; stopped. Meant impossible: leading with owing, `leave_room` outside the leave, `handlers_wait` while leading.

**Readers.** `leads()` from `er301.lua:79`, `txo.lua:55-58`, jf, wsyn and `wtape.lua`. `nb.lua:223-226` reads the rig, not the flag, on purpose.

**Guards.** `ii.md` has a table of the flag's changes. There is no invariant. 52 example tests.

**History.**
- `f37ee080`: the lead taken twice at a second crow add.
- `17b299e9`: gates left high at a leave (build ruling 47).
- #751: 18 lines at once from strata to teletype.

All wrong transitions.

**Why the flag is not derived from the rig.** The rig tells listeners after its value changed, and `end_target`'s offs must still be accepted during the leave (`ii.md`, first bullet).

**UX, probe 2.** With an ER-301 gate high, the crow unplugged, the bus set to off and the crow back: 0 lines sent, 1 off owed, and the section's status is nil (:675-679 shows only `[--]` or `n dropped`). Also:
- `dropped` is a session count never reset (:99-102).
- At a script's end the owed offs are lost (`docs/status.md:200`).
- The jf, w/ syn and er-301 rows show a route as set while the bus is off, with no mark (`er301.lua:118-121`).

**Recommendation: (c) as an invariant, plus a status text.** An `ii` invariant: not leading with owing; `leave_room` nil; each learned line's `waiting` equals its sends in the queue (today one assert at the drain, :424); `state.asking` equals the turns asking. Show `n owed` in the title. Cost two hours. Bugs 3, blast radius medium, confidence medium-high.

## 5. The ii queue: lines and turns

**Owner.** `lines`, `pairs`, `queue`, `turns`, `pressed` (`ii.lua:115-298`).

**Already explicit.** `ii.md`, "The queue's states", is a full state × event table with "(cannot happen)" cells. It is the one notes file in the area that does this, and the pattern to copy.

**History.** Ten bugs, all wrong transitions, several caused by the controller's own rulings:
- `35dd565b`, `eaf2ecf7`: an off dropped or displaced.
- `5b0a859a`, `af4f94dd`: state kept or counted wrongly (build ruling 28: removing `learn_pair`'s count left a port high).
- #710, four commits: the lowest voices kept the bus.
- #717, #719.

**Belief not read back.** `line.high` is Lua's belief. It is forgotten at each lead (:461) and kept through a crow's absence (:519-520).

**Recommendation: (c).** Fold into machine 4's invariant. Leave the code.

## 6. TELEXo and ER-301 lines

**Owner.** `lines[output]` and `active` (`lib/io/txo.lua:34-36`), `lines[port]` (`lib/io/er301.lua:25`).

**History.** `60eb5a56` (one line across voices, build ruling 10), `8c3dfbc0` and `d56a3c96` (rollback after a raising send), `dab6e9c5` (routed only while leading), #752 (`active` survived a crow's absence).

**New finding, probe 1.** `set_up` sets `active[output] = true` whatever `send` returned (`txo.lua:102-107`).
- With the queue at 48, choosing envelope mode for an output dropped all three setup lines, and crow got none after the drain.
- A later `txo_attack` change sent `env_att(3, 25)` alone, so the module believes the envelope is set up.
- Nothing retries until that voice's output or mode changes or the lead is retaken.
- This is #752's pattern again: a second record of the device.

**Recommendation.** Fix it: mark `active` only when `env_act` was admitted, or resend on the next `sync`. Then (d). Bugs 5 + 1, blast radius low (overload only), confidence high.

## 7. The remote kinds

**Owner.** `records[kind]` (`lib/io/remote.lua:46-53`): `claimed_port`, `in_use`, `parts`, `problem`, `virtual`. Also `midigrid` (:58) and `draw.clock` (:60).

**States, named by `status(kind)` (:453-469).** Off; `[--]`; `in use`; `no hello`; a problem; attached (an arc may also be waiting behind a monome arc). `status` derives the state at each read and keeps no record of its own.

**Guards.** An invariant: attached exactly while a hello is held, and the clock exactly while attached (:613-636).

**History.** `164916cf` (review), #704, `b1b427ee` (a Launchpad also played voices), #753, `41841d42` (the waiting arc's text). Wrong transitions.

**What the player sees.** Good: a status row per kind, and a `rescan` action.

**Recommendation: (a).** A six-state table in `remote.md`; the texts are already the state names. Confidence medium.

## 8. The targets ledger

**Owner.** `sounding`, `offs`, `failed` (`lib/io/targets.lua:37`). Transitions: `start_note` :134, `end_note` :105, the LFO step :210, `route_changed` :223, `end_target` :228, `stop_all` :247, the stop and silence hooks :256-262.

**Guards.** An invariant: every note names a registered target, every off a sounding note, once (:354-371).

**History.** `e64aad25` (a beat jump and a failed target), `04cbcc2f` (jitter read as a jump), `2bccca4f` (a gate's low before the next high). Three wrong transitions in two days, none since.

**UX gap, read from the code.** A target that raised is skipped until the patterns stop or any route changes (:76-90, :172, :224). Only the console says so.

**Cross-area edge.** Offs, the ii queue, MIDI out's settle and expression, crow's followed outputs and `handlers_wait` all hang on `S.lib.lfos.on_step`.

**Recommendation: (d).**

## 9. MIDI out's routes

**Owner.** `noted`, `dirty`, `config` (:706-823).

**Shape.** Param actions only note a change. `settle` compares the params with the settled set and applies the difference once. It replaced per-param application after `becdb3fc` and `d0eee45b` (build rulings 19, 25) and `62974766`. The invariant holds the settled set legal.

**Recommendation: (d).** This is the reconciler to copy.

## 10. Smaller machines, all (d)

- **crow jacks** (`lib/io/crow.lua:50-55`).
  - Source kinds `off`, `mod`, `pitch`, `gate`, `clock` are explicit records (:551-563).
  - `set_up[kind][n]` is three-valued: nil never touched, true set, false off line sent (:285-288). Both nil and false read as "send no off line". It is reset by `crow.reset()` at each add (:393-394).
  - `follow_owners` compares norns' clock params with `owners` each step (:316-329).
  - History: `0e994f9b` (a gate left high when moved), `a29873ba`.
  - No invariant.
- **Controllers** (`lib/io/controllers.lua:38-46`).
  - `held[kind]` against the rig's port, compared at use (:365-379, :436-440).
  - Pickup per fader (:179-232); a one-shot echo guard (:278-290).
  - History: `c752206c`, `8239adae`. `port taken` is shown.
- **nb** (`lib/io/nb.lua:25`). Refcount and activation (:52-91). History: `c03a100a` (a count left at 0).
- **OSC** (`lib/io/osc.lua:26`). The clock runs exactly while feedback is on and a sender is known (:136-149). History: `fb20215a`, `840563ac`.
- **Tape** (`lib/io/tape.lua:37`). One flag, `engaged`. History: `428c8a6f`.
- **W/ tape** (`lib/io/wtape.lua:39`). `shown` and `level` are beliefs never reset, even by a new lead. Documented.
- **Keyed** (`lib/io/keyed.lua:14`). An option and a key param, reconciled from the file after each read (:88-104).
- **Rig** (`lib/io/rig.lua:94-142`). Already option (b): a spec per key, `set` writes first, listeners hear `(value, previous)`, a structure test holds every other module to reads, and an invariant at :192.
- **Program change guard** (`midi_out.lua:502-528`). `asked[port]` is consumed by the scenes' recalled hook. Documented cost: one swallowed program change if the recall never lands.
- **MIDI-in listening** (`lib/midi_in.lua:89-99`). `listening_port` is recomputed from `owner(port)` at each attach.
- **`lib/mpe.lua`** uses no port; its edge is `reset_ranges` called from `midi_in.lua:114`, `:122`, `:143` and `:155`.

## Cross-cutting patterns

**Clocks and the "retire, never cancel" rule (#626).**
- Only crow's flush clock follows it: it ends at its own wake and is canceled only at cleanup (`crow.lua:122-134`, :735).
- Plain `clock.cancel` from an event handler: crow's output clocks (:262), the controllers' (:312), the remote's draw clock (:207), OSC's (:130) and nb's `active_routine` (`nb.lua:65`).
- Each can be canceled by a rig change, a hot-plug or a param action while its resume is posted.
- Inferred from #626's text, not probed: the cost is a console `bad argument #1 to 'resume'` line.
- The others have no clock: targets, ii, MIDI out and crow's followed outputs run on the LFO step.

**Lifecycle flags.** Seven spellings of before-start, running and after-cleanup: `started`/`stopped` (ii, crow), `stopped` alone (MIDI out), `started` set false at cleanup (remote), `closing` (controllers), `hot_plug.installed` (ports), `added` (nb). The cleanup order 142 to 152 is itself a protocol: notes off, zones down, ii leave, crow off, releases, ports (`lib/constants.lua:274-283`).

**Owed values and who flushes them.**

| Owed value | Flushed by | Lost when |
|---|---|---|
| ii owed offs | the next lead: a rig change or a crow add | the script ends |
| `left_with[name]` | that name's arrival or a menu close | never expires |
| `setup_due`, `takedown_due` | the port's settled telling | the device leaves, or cleanup |
| `asked[port]` | a scene recall | never, if the recall is canceled |
| crow's pending lines | its flush clock | the crow leaves |

**Beliefs about a device that nothing reads back.**

| Belief | Reset by |
|---|---|
| crow's `set_up` | `crow.reset()` at an add |
| ii `line.high` | each lead |
| TXo `active` | `release`, and `ready`'s reconcile (#752) |
| W/ tape `level` | nothing |
| MIDI out's zone and counts | arrival marks; owed offs by device name |
| remote `shown` | each hello (`remote.lua:243-247`) |
| controllers' `echo.last` | an arrival or a setting change |
| OSC `last_sent` | `/strata/hello` |

**States the player cannot see.**
- **A claimed MIDI-in port.** SETUP's `midi` row shows `(owner)` (`lib/pages/setup.lua:247-252`). IO shows it only in the port fields' formatter inside a detail list (`midi_out.lua:833-838`). Nothing on IO says the keyboard is not being heard.
- **A voice routed to a remote-held port (probe 3).** The row reads `port 3  ch 1`, the titles show nothing, and the remote section reads `grid: no hello`.
- **Owed ii offs** (machine 4), **a failed target** (machine 8), **a dropped TXo setup** (machine 6).

**Constraints on any refactor.**
- Hooks must keep reading live mid-transition answers.
- Only `ports.lua` sets MIDI handlers (structure test).
- crow is text only, so every device state is a model, and the tunables (14, 15, 48) are unmeasured until #6.
- The accessor names the tests use must stay.
- The 200-local limit is not a constraint here: the largest module has 60 top-level locals (`crow.lua`).
