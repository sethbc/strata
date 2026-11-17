# Plan facts: packages 1b to 1e (wave 1 fixes)

I read these from `main`. Line numbers are main's. Baseline: `lua test/run.lua io_midi_out` gives 59 tests, 0 failures, and `io_txo` gives 27, 0. None of the four packages reads `S.voices[i].params`, `.grain`, `.crossmod`, `.extras` or `S.frozen`. I grepped all five lib files and their test files. The only hits are `params.params`, the paramset (lib/io/ii.lua:585, 590), and `S.voices[3].active` (test/unit/io_ii_test.lua:120), a field that stays. The local `frozen` in test/unit/io_ii_test.lua:1097 holds the audio freeze (`v2_freeze`), so 0a should leave it. None of the four packages needs lib/voices.lua, lib/scenes.lua, lib/engine_sync.lua, lib/params_setup.lua, lib/state.lua or a shared test file. None makes a line of AGENTS.md false.

---

## 1b: MIDI out's moved device (#747-#750)

### 1. Files
- `lib/io/midi_out.lua`:
  - `MIDI_OUT` (18-25; `all_notes_off_cc` at 19)
  - the state comment (28-41)
  - `set_aside` (209-219)
  - `settle_moved` (225-234)
  - `express_step` (341-367)
  - `departed` (489-498)
  - `arrived_channels` (503-510)
  - the `on_change` hook (512-530; CC 123 at 518-520)
  - a new menu-close hook, next to the `on_change` hook
- `test/unit/io_midi_out_test.lua`: 8 assertions re-based (section 4) and 6 tests added.
- `docs/notes/lua/io/midi_out.md`:
  - line 3 ("... the MPE setup and takedown, CC 123")
  - line 14 ("(the CC 123 below, wherever the device arrives, stands for those offs)")
  - line 30: the whole bullet. Its tail documents the faults: "but for one case: a note sent mid-menu to an old port left empty names no device, so `settle_moved` leaves it ... The fix (#748, before 3.8) is ..." and "One more thing stays: in a swap of two devices ... the CC 123 ... can cut early a note sent to it there mid-menu".
  - line 37 (`all_notes_off_cc` 123 in the `MIDI_OUT` list)
- `docs/user/io/midi-out.md:33`: the whole paragraph. It opens "Strata sends it all notes off (CC 123) on each channel it had notes on". Its last two sentences document #748 ("It gets no note off for a note it never had, but in one case: ...") and #750 ("And when two devices swap ports ... can cut early ...").
- The package does not need to edit `lib/io/ports.lua`. The new hook is registered in midi_out.lua. Hooks run in registration order (lib/ui/menu_watch.lua:64-67), and ports' hook (lib/io/ports.lua:263) is included first (strata.lua:61, against midi_out at strata.lua:95), so `reconcile` always runs first.
- `changes/<branch>.md`.

### 2. Names, the code today and the fixes

**What survives a move.** `set_aside` (209-219) marks the record `departed`, removes it from the counts, the channel use and the expression list, and sets `left_with[key][channel] = true`. The record itself stays in `state.notes[voice][id]` until the voice ends the note. `end_note` (240) then sets it to nil and returns at 243, so at that point the note number is forgotten and only the channel remains in `left_with`. The code therefore cannot tell an owed note from a new one on the same channel. That is #750.

**#748**
- **Root cause:** `settle_moved` (229) skips a record with `record.device == nil`, which is a note sent to a port that was empty mid-menu. Its off then goes to whatever device took the port (end_note 257-259).
- **Fix:** in `settle_moved`, also set aside a record with `record.device == nil` once `now ~= nil`, by calling `set_aside(record, nil)`. In `set_aside`, record nothing in `left_with` when `key == nil`.
- **Also in `departed` (493-494):** a record that names no device is today owed to `departed_name`. That is wrong when the port now holds another device. If the note is still held when the menu closes, the moved device gets a spare off. Proposed: `set_aside(record, record.device or (now == nil and (departed_name or ("port " .. port))) or nil)`.
- **Edge left open:** the port is empty at the close, and a note was sent to it mid-menu and is still held. The note is then owed to `departed_name`, so the moved device gets one spare `note_off`. To close it, mark at the note on whether the vport had a device (`S.lib.io_ports.out(port).device`). Or drop the `departed_name` fallback for records altogether: of the three `on_change` hooks (lib/midi_in.lua:601, lib/io/midi_out.lua:512, lib/io/remote.lua:480), none starts a note, so a no-device record never reaches a leaving device. Planner's call.

**#749**
- **Root cause:** `express_step` (341-367) sends from `state.expressing` and never settles, so a moved port's played MPE note sends its bend to the new device.
- **Fix:** at the top of `express_step`, after the `count == 0` return, collect the ports of `state.expressing` and call `settle_moved(port)` for each, in port order (`for port = 1, S.lib.io_ports.PORTS.count`), then re-read `count = #state.expressing`. `set_aside` calls `remove_expressing` (195-203), which shifts the list and the cursor, so the collection has to come before any settling. `settle_moved` sends nothing, so the order affects only determinism. If the module avoids allocating at every step, reuse one table such as `state.express_ports`. This is cheap: at most 23 expressing records (notes line 20).

**#750**
- **Root cause:** an arrival sends CC 123 on every channel owed to the device's name (518-520). That cuts a note sent to the device at its new port mid-menu.
- **Rule proposed for the design's "where MIDI out still holds them": keep the note number for every owed note.**
  - `set_aside` writes `table_at(state.left_with, key, record.channel)[record.note] = true`.
  - Rename `arrived_channels(port, name)` to `arrived_notes(port, name)`. It returns `{[channel] = {[note] = true}}`, the union over `name` and `"port " .. port`, and clears both keys.
  - The arrival sends `note_off(note, 0, channel)` for each owed pair, channels 1 to 16 and the notes sorted, then the MPE setup as today.
- **Why this rule:** with the notes kept, MIDI out holds every owed note, including those whose off fell mid-menu. The design's "CC 123 only for the rest" then has no rest, so no CC 123 is sent and `MIDI_OUT.all_notes_off_cc` goes. That one line deviates from the design's wording, and the plan should state it.
- **The narrower alternative:** "held" means only the departed records still in `state.notes`. It leaves the probe failing whenever the old note ended mid-menu (the second #750 test below). Not recommended.
- **Collision:** the owed (channel, note) may equal a note now sounding at the arrival port (`counts[port][channel][note] > 0`). Send the off anyway: the device had two note ons, so #709's balance needs it, and the cost is a same-pitch cut. That is far narrower than today's cut of the whole channel.
- **Memory:** at most 16 × 128 entries a key.
- **Names:** a shared `pay_owed(port, name)` (local), used by the arrival and by #747's hook.

**#747**
- **Root cause:** `reconcile` (lib/io/ports.lua:248-261) compares device objects. Device a goes 2→3→2, so port 2's `current == seen[2]` and no arrival is reported. `left_with["synth a"]` stays until a next arrives somewhere.
- **Fix:** register `S.register_menu_close(function() ... end)` in midi_out.lua. Unless `state.stopped`, for each port 1 to `PORTS.count` whose `S.lib.io_ports.device(port)` names a device with an entry in `left_with`, it calls `pay_owed(port, name)`. That sends the own offs (not the issue's sketched `cc 123 0 6`) and clears the entry. It then calls `request_redraw()` only if anything was paid.
- **Known edge:** with #749, a played MPE note set aside while its device was away gets its off when the device returns to the same port. The voice still holds it, and its own later end sends nothing. That is the same cut an arrival gives today.

**Do they interact?** Yes. All four change one mechanism (`set_aside`, `settle_moved`, `left_with`, the arrival).
- **Order:** #748 (the `settle_moved` and `departed` rules, `set_aside` with nil), then #749 (it inherits #748's rule, so a no-device played note is also set aside once the port has a device), then #750 (the shape of `left_with`, own offs, `pay_owed`; this re-bases every CC 123 assertion), then #747 (the hook calls `pay_owed`; done before #750 it would be written with CC 123 and then rewritten).
- One worker, four commits, each test-first.

### 3. Order and seams
Needs 0a only. Gives nothing to later packages. It touches no file of 1a, 1c, 1d or 1e. Rules it keeps:
- Every send stays through `send`, so a port a remote holds stays absent (notes line 3).
- #709's balance (notes line 6) becomes unqualified. That bullet's claim "the CC 123 ... stands for those offs" becomes "the owed offs".

### 4. Tests
**Re-based** (test/unit/io_midi_out_test.lua):
- 101: `all_notes_off_cc` goes.
- 886: becomes `"note_off 60 2|note_off 64 5|" .. setup`.
- 911 and 915: `"note_off 60 6"`.
- 935 and 941: `"note_off 60 6"`; 936's message "no CC 123" becomes "no off".
- 979, 988 and 999: `"note_off 60 6"`.
- Test names at 875, 894, 918, 975, 992 say "all notes off". Rename them to "the offs of its notes".

**New**, using the file's helpers `a_moving`, `open_notes`, `clear`, `sent` and `_menu.set_mode` (lines 945-973):
- **#748, "a note sent to the empty old port mid-menu gives no off to the device moved in after it":** voice 1 is on port 2, channel 6. Open the menu, `reassign(2,3)`, play note 64, `reassign(4,2)`, then `note_off`. `sent(b) == ""`. After the close, `sent(a) == ""` and `sent(b) == ""`.
- **#748 variant, "... held until the menu closes":** the off comes after the close. a and b both get `""` at the close, and b gets `""` at the off (needs the `departed` change).
- **#749, "a played MPE note's expression never reaches the device that took its port":** MPE voice 1 on port 2 (a), played note 60 through port 1 as in test 594. Open the menu, `reassign(2,3)`, `reassign(4,2)`, `clear(b)`, send a new bend on port 1, take one step: `sent(b) == ""`. At the close, `sent(b) == SETUP_15_48` and `sent(a) == "note_off 60 2"`.
- **#750, "in a swap, a note sent to the moved device at its new port is not cut by its arrival":** b (port 4) holds voice 2's note 62 on channel 6. Open the menu, `reassign(4,2)`, voice 1 (port 2, channel 6) plays 60, close. `sent(b) == "note_on 60 127 6|note_off 62 6"`, then `note_off` for voice 1 gives `...|note_off 60 6`, and `open_notes(b)` is all 0 over the whole history (do not clear before the first on).
- **#750 variant:** voice 2's note 62 ends while the menu is open. Same assertions. This is the test that rules out the narrower alternative.
- **#747, "a synth moved away and back in one visit gets its owed off at the close":** a on 2, note 60 on channel 6, open the menu, `reassign(2,3)`, `note_off`, `reassign(3,2)`, close. `sent(a) == "note_off 60 6"`. Then unplug and plug a again: the new device's `sent == ""` (nothing owed is left).

### 5. Risks and open points
- That no CC 123 is ever sent is my reading of the design's rule, given the kept notes. The planner must confirm.
- The `departed_name` edge (in #748 above) needs a decision.
- The user page's "When the synth comes back" paragraph changes its first sentence too: "all notes off (CC 123)" becomes "a note off for each note it was still owed".

---

## 1c: the ii bus and the TELEXo (#751, #752)

### 1. Files
- `lib/io/ii.lua`:
  - `state` (70-72): a field `handlers_wait`
  - the step hook (393-416; its early return at 394)
  - `give_up_lead` (461-488): returns the lines it sent
  - `set_up` (510-515)
  - the rig listener (520-526)
  - `M.stop` (670-675)
- `lib/io/txo.lua`: `ready` (276-279) and nothing else.
- `test/unit/io_ii_test.lua`: 2 tests added; the existing handler tests (106, 1137) still pass, since they leave `off`, not `strata`.
- `test/unit/io_txo_test.lua`: 2 tests added.
- `docs/notes/lua/io/ii.md`:
  - line 14: "The three handlers go at each crow setup and at once when the rig turns to `teletype` with a crow there"
  - line 35: "From `strata` to `teletype` the sequence runs first."
  - one row of the leading-flag table (52-56) if the plan wants it
- `docs/notes/lua/io/txo.md:5`: "`release` ... forgets them, so a later `ready` sets everything up again" gains "and `ready` first turns off any output the module still has active that no voice wants".
- `docs/user/io/ii.md:13` (`teletype leads`): one sentence saying the handlers follow after a leave.
- `changes/<branch>.md`.

### 2. Names, the code today and the fixes

**#751**
- **The code today:** the rig listener (520-526) runs `give_up_lead()`. That sends up to 14 offs at once (472-474) and the release lines while the total is at most `II.leave_lines` (15; 480-482). Then `send_handlers()` (505-507) sends 3 lines at once, 18 in all.
- **How "drained" is known:** Strata cannot see crow's queue. The leave's lines go through `send_now` and not the module's queue, and `state.queue` is empty after the leave (468, 484). The one measure the module has is its own rate, `II.sends_per_step` (4) a 48 Hz step (notes line 5: "about 20 in each 0.1 s crow window").
- **Proposal:** the leave has drained when the steps the queue would need for those lines have passed, `math.ceil(sent / II.sends_per_step)`, which is 4 steps (about 83 ms) for 15 lines.
- **Edits:**
  - `give_up_lead()` returns `II.leave_lines - state.leave_room`, read before 482. It returns 0 when it does not lead.
  - New `state.handlers_wait`: nil, or the steps left.
  - New local `handlers_after(sent)`: `send_handlers()` at once when `sent <= 0`, else `state.handlers_wait = math.ceil(sent / II.sends_per_step)`.
  - The step hook gains a block before line 394: decrement `handlers_wait`; at 0 set it to nil, and `if active() and present() and bus() == "teletype" then send_handlers() end`.
  - The listener:
    ```
    local waiting = state.handlers_wait ~= nil
    state.handlers_wait = nil
    local sent = 0
    if previous == "strata" then sent = give_up_lead() end
    if previous == "teletype" and present() and not waiting then send reset_events end
    if value == "strata" and present() then take_lead()
    elseif value == "teletype" and present() then
      if previous == "strata" then handlers_after(sent) else send_handlers() end
    end
    ```
  - `set_up`'s teletype branch clears `handlers_wait` before it sends.
  - `M.stop` clears it.
- **If the leader changes again while the handlers wait:**
  - to `strata` or `off`: the wait is canceled and `ii.reset_events(ii.self)` is not sent, because crow never got the handlers.
  - to `strata`, in particular: `take_lead`'s `ready` lines go through the queue at 4 a step, as on any strata→off→strata.
  - strata→teletype again: a new wait replaces the old one.
  - crow unplugged: `present()` is false at the due step, so nothing is sent; a later crow setup sends the handlers once through `set_up`.
  - cleanup: `active()` is false.
- No new `II` constant is needed.

**#752**
- **Root cause:** not where the issue puts it. `crow_gone` (ii.lua:494-503) leaves the TELEXo alone (no `release`), so `active` (txo.lua:36) rightly still lists the outputs set up on the module. Then `ready` (277) does `active = {}` before `sync()`. `sync`'s turn-off loop (115-120) therefore iterates an empty set and never sends `env_act 0`.
- **Clearing at `crow_gone` would be wrong:** it throws away the one record of what the module holds. So would clearing at `take_lead`.
- **Fix:** `ready = function() sync() end`. `sync` then sends `env_act 0` for each active, unwanted output and the three setup lines for each wanted one, as `ready` sends today. On the first lead and after a `release`, `active` is already empty, so nothing changes there.
- **No `ii.lua` edit is needed for #752.**
- **Optional, same mechanism:** `release` (280-285) forgets every output even when `send_direct` returned false, which happens past the leave's 15 (build ruling 47). Keeping those in `active` would let the next `ready` turn them off. It would change `docs/user/io/er301-txo.md:27` ("it turns each envelope it set up off"). Planner's call.

### 3. Order and seams
Needs 0a only. Its two edits touch different files and functions, so they can be two commits. The rules it keeps:
- Everything still goes through `send_now` or the queue.
- "Under `off` and `teletype` no line starting `ii.` reaches crow but Teletype's three handlers and `ii.reset_events`" (ii.md line 3) still holds.
- The 15-line bound (line 7) is now true of the whole bus change.

### 4. Tests
- **io_ii_test.lua, "strata leads turned straight to teletype leads sends the handlers only once the leave's lines have gone (#751)":** the setup of test 975 (21 offs, a 7-line releaser). `set_bus(S, "teletype")` sends exactly 15 lines at once, none of them `HANDLERS`. The first 3 steps (`stepper`) send no handler line. The 4th step sends exactly the three `HANDLERS`, in order. No instant sends more than 15. Also: with nothing to leave (`port_devices`, an empty queue), strata→teletype sends the handlers at once.
- **io_ii_test.lua, "a leader change while the handlers wait cancels them":** strata→teletype, then →off before the 4th step: no `HANDLERS` line and no `RESET_EVENTS` over 10 steps. strata→teletype→strata: no `RESET_EVENTS`, and the device's `readies` is 2 (one for each lead). strata→teletype, then unplug crow: no handlers at the due step; plug it back: `crow.reset()`, then the handlers once, and not again at a later step.
- **io_txo_test.lua, "an envelope turned off while the bus is not led gets env_act 0 at the next ready (#752)":** the double; `v1_out_txo` 5, envelope; `ready()` (setup); `state.leading = false`; set the mode to pitch; `assert_calls {}`; `state.leading = true`; `ready()` gives `{{"send","txo","env_act",5,0}}` only.
- **io_txo_test.lua, "a crow that leaves and returns turns off an envelope no longer wanted":** `leading_real()` (515); output 4 envelope; step; `context.crow.unplug()`; set the mode to pitch; `crow.clear()`; `crow.plug()`; `run_for(0.2)`. `ii.txo.env_act(4, 0)` is in `crow.sent`, and `ii.txo.env_act(4, 1)` is not.

### 5. Risks and open points
- The ceil(sent/4) wait is my proposal; the design says only "drained". It shares the module's own rate assumption, not a measurement of crow.
- The design's wording "the TELEXo's active set is rebuilt when crow leaves" is wrong in mechanism. The fix is at `ready`, in txo.lua alone.

---

## 1d: the late midigrid claim (#753)

### 1. Files
- `lib/io/remote.lua`:
  - `claim_midigrid_ports` (382-389): split it
  - the `on_change` hook (480-495)
- `test/unit/io_remote_test.lua`: 2 tests added, next to 582.
- `docs/notes/lua/io/remote.md:7`, "The claims are released when the object is detached ... and a port's when its device leaves": add "and a port whose device arrives while the object is attached (a hot-plug or a move in SYSTEM > DEVICES) is checked again".
- `docs/user/io/remote.md:48`: "While the MIDI grid is attached, its device's MIDI port belongs to it" is not false today, but it can add "on whichever port SYSTEM > DEVICES moves it to".
- **No edit to `lib/io/ports.lua`.** The design's package table names it for 1d; it is not needed.

### 2. Names, the code today and the fix
- **Who hears of an added device today:** `lib/io/ports.lua`'s `added` (216-223, a hot-plug) and `reconcile` (248-261, a menu move) run every `on_change` hook. Those are `midi_in` (lib/midi_in.lua:601), `io_midi_out` (midi_out.lua:512) and `remote` (remote.lua:480).
- **The file that owns the midigrid claim:** `lib/io/remote.lua` (`MIDIGRID_OWNER` 56, `midigrid.ports` 57, `claim_midigrid_ports` 382, `release_midigrid_port` 391).
- **Root cause:** remote's hook already releases a departing port's claim (482). On an arrival it only connects the remote grid or arc (491-492) and never re-checks the midigrid claim. It claims only in `midigrid_connect` (423).
- **The realistic case:** a move of the Launchpad in SYSTEM > DEVICES. The device object, and the `event` midigrid set on it, move with it. The departure releases the old port; nothing claims the new one.
- **Fix:**
  - New local `claim_midigrid_port(port)`, which is today's loop body.
  - `claim_midigrid_ports` loops over it.
  - In the hook, after the KINDS loop (so a remote grid or arc the rig names on that port claims first, as at attach, where a port another owner holds is left alone): `if name ~= nil and midigrid.device ~= nil then claim_midigrid_port(port) end`.
- **Order:** midi_out's arrival hook runs before remote's (registration order, strata.lua:95 against 105). An owed off or an MPE setup can therefore reach the Launchpad's new port in the same reconcile before the claim. That is rare and pre-existing for any arrival; noted, not fixed.

### 3. Order and seams
Needs 0a. No conflict. MIDI out reads `S.lib.io_remote.holds` (midi_out.lua:71-74), which is unchanged.

### 4. Tests
- **"a Launchpad midigrid holds keeps its claim when SYSTEM > DEVICES moves it (#753)":** test 582's setup (Launchpad X on port 1, a `grid.connect` that sets `launchpad.event`, `midi_grid` on, `owner(1) == "midigrid"`). Then `_menu.set_mode(true)`; `context.midi.reassign(1, 4)`; `_menu.set_mode(false)`. `owner(4) == "midigrid"`, `holds(4)`, `owner(1) == nil`, `not holds(1)`. Turning `midi_grid` off gives `owner(4) == nil`.
- **"a device that arrives with a device-level handler is claimed only while midigrid is attached":** after start, wrap the global `midi.add` in the test so it sets `device.event` before calling through. That stands for a library that sets the handler at the add. With midigrid attached, `context.midi.plug(3, "Launchpad Mini")` gives `owner(3) == "midigrid"`. With `midi_grid` off, a plug on port 5 gives `owner(5) == nil`. Restore `midi.add`.

### 5. Risks
None found. Unsure whether midigrid itself ever sets `event` on a device added later (checks.md §7 says its `midi.add` wrapper only calls through), so the move is the case the tests should pin.

---

## 1e: the double scan reset (#742)

### 1. Files
- `lib/engine/StrataPositions.sc`:
  - the area comment (10-19)
  - the `regionLength` handler (30-34)
  - `allocPositionState` (42-44)
  - `positionsHit` (74-78)
  - a new method
- `test/engine_check/positions.scd`: a new check function beside `checkRegionRestart` (407-438), called in the list at 457-465 after `checkRegionRestart.value`. The area name `positions` is in `areaOrder` (test/engine_check.scd:25), and the file exists.
- `docs/notes/engine/positions.md`:
  - line 7: "a `retrigger` on a one-shot voice ... sends `t_scanReset` to the own grain synth alone" gains the exception.
  - line 15 (Owns): the new method and state.
  - line 43 (The check): the new check.
- `changes/<branch>.md`. No AGENTS.md line changes, and no file is renamed or deleted, so no restart note is needed.

### 2. How the resets arise, and the fix
- **The two resets:**
  - `notes.set_own_region` (lib/notes.lua:415-425) sends `setGrainParam regionStart`, then `regionLength`. The handler sends `regionLength` and `t_scanReset 1` to the own grain synth in one `/n_set` (StrataPositions.sc:32).
  - The retrigger that follows runs `voiceHit` (StrataVoices.sc:139). `positionsHit` (76) sends a second `/n_set t_scanReset 1` to the same synth.
  - Each goes out as its own bundle with no timestamp (`sendToSynth`, StrataUtil.sc:82-84).
- **The UGens:** `t_scanReset` is a TrigControl. It outputs the set value for one block, then zeroes it (~/src/supercollider/server/plugins/IOUGens.cpp:598-606). It feeds `Phasor.ar`'s trigger (with `t_scanSync`) and `Sweep.ar`'s (StrataPositions.sc:125-127). Both reset on a rising edge only (`previn <= 0 && in > 0`, TriggerUGens.cpp:1627).
- **Two sets in the same block, or in adjacent blocks, already give one reset** (the signal reads 1,1, a single edge). Two restarts need at least one block of 0 between them. So the issue's "within one control block one trigger, else about 1.3 ms apart" is not quite right: it is about 2.7 ms or more apart. That wording is in docs/status.md:19 and docs/decisions/3.7.md:190, which 5a should correct.
- **The engine cannot see the server's blocks.** The rule has to be a time window in sclang.
- **Fix (no UGen, no SynthDef change):**
  - `allocPositionState`: `areaState[\positions][\regionResets] = Array.newClear(numVoices);`.
  - The `regionLength` handler, after its `setSynth`: `areaState[\positions][\regionResets][voice] = [synths[this.grainKey(voice)], thisThread.seconds];`. This is inline, which is allowed: it calls no method that hands a function on (structure.md line 7; structure_test.lua:1773ff).
  - New method:
    ```
    // True when regionLength's restart reached the voice's live own grain
    // synth less than a control block ago (#742)
    regionResetJustSent { arg voice;
        var last = areaState[\positions][\regionResets][voice], server = context.server;
        ^last.notNil and: { last[0].notNil } and: { last[0] === synths[this.grainKey(voice)] }
            and: { (thisThread.seconds - last[1]) < (server.options.blockSize / server.sampleRate) }
    }
    ```
    `blockSize / sampleRate` is used already at StrataEffects.sc:34, and `thisThread.seconds` in a command at StrataRecord.sc:396.
  - `positionsHit`: `if ((kind == \retrigger) and: { this.oneShotVoice(voice) } and: { this.regionResetJustSent(voice).not }) { ... }`.
- **Why no needed reset is dropped:**
  - A hit with no region change: no recent entry, so the hit sends its reset.
  - A region change with no hit: the handler always sends its own reset, unchanged.
  - A region change and a hit more than a block apart: both are sent, as today.
  - A source switch between them: the synth differs (`===`), so the hit sends.
  - A stopped voice: the entry's synth is nil.
  - Only the hit's reset is ever skipped, and only when the same synth restarted less than one block earlier.
- **Real-time memory:** nothing is added on the server. No UGen, SynthDef, node or buffer, so the memory area's measures (3 MB or 3.5 MB free; each grain synth under 88 KB; docs/notes/engine/memory.md) are untouched. The cost is one 2-element Array per voice in sclang.

### 3. Order and seams
Needs 0a only. It is the only engine package (design §10). Rules it keeps:
- `t_scanReset` is still never stored (the time is kept in `areaState`, not `grainControls`).
- "The restarts 3.7 adds are one synth's each."
- Run with `STRATA_ENGINE_CHECK_AREAS=positions STRATA_SC_PORT=<own port> test/run_engine_check.sh` while working, and every area before landing.

### 4. Tests
- **New `checkRegionHitOneRestart`, in positions.scd, on the existing buffer voice:** set `scanMode 2` and `bufScan 1` with `setGrain`. Count `t_scanReset` with a helper over a `server.makeBundle(false, {...})` that counts the messages whose `msg[1]` is the own grain synth's `nodeID` and that hold `t_scanReset` (compare with `item.asString == "t_scanReset"`, since a `setMsg` may carry symbols). Send each captured bundle afterward (`server.sendBundle(nil, *bundle)`), as checkRegionRestart does at 426. Assert all five:
  - (a) `regionStart`, `regionLength` and `retrigger` in one bundle: exactly 1;
  - (b) `retrigger` alone: 1;
  - (c) `regionLength` alone: 1;
  - (d) `regionLength`, then `0.05.wait`, then `retrigger`: 1 and 1 (the hit's reset is not skipped once the window has passed);
  - (e) wrap (`scanMode 0`): a `retrigger` sends 0, as today.
  
  Optionally, end to end: after (a), `position.value` is within the region's start plus 0.08, as checkRegionRestart checks at 429. The message reads: `"positions: a one-shot hit that changes the region restarts the scan once (counts %)"`.
- No existing check pins the double reset. `checkRetriggerRestart` (286-302) and `checkRegionRestart` keep passing, since they use separate commands more than a block apart.

### 5. Risks
- Unsure: I did not run sclang to confirm that `thisThread.seconds` in an OSC command handler on norns is the receipt time. It is the record area's precedent. Inside the check's routine it is logical time, which makes (a) deterministic. `Main.elapsedTime` is the fallback, and it passes the check too.
- The window is one block (1.33 ms at 48 kHz). If sclang is busy and handles the two messages further apart than that, both resets go, as today. That is harmless.
