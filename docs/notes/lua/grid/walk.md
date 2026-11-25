## Must not break

- **The walk's model reads the rules, never the code under test.** `test/unit/grid_walk_test.lua` predicts what each key does from `docs/notes/lua/grid-core.md` (Machines, `grid keys`, and the step keys), the two pages' notes (`docs/notes/lua/grid/pages/patterns.md`, `docs/notes/lua/grid/pages/voices.md`), the step view (`docs/notes/lua/grid/keys.md`) and `docs/notes/lua/loop-roll.md`. Its values are 3b's rules worked out by hand in literal tables (`VALUES`). A check that took its expected value from the module it checks would pass any fault in that module.
- **Every key event of an op goes through `Walk.press` and `Walk.release`**, which model the key before the core sees it, then run the checks the model queued (`Walk.expect`). An op that presses a key through anything else is unchecked.
- **The model observes only whole-pattern replacements** (its wrapper of `replace_pattern`, and of `replace_whole` to mark a letter's switch) and reads, as given, what no key of the walk decides: whether a cell holds a value before a key acts on it, a lane's length before LN's key, the voice's length and mode (each mode key's press is checked to set it; a scene recall may set it too), whether the patterns play and a voice runs, and whether a voice's loop lives at a replacement (a length cut's end of it is not predicted).
- **A seed walks the same ops every run.** A change to an op's draws moves every seed, and its `reached` counters must be summed again.

## The grid walk

`test/unit/grid_walk_test.lua`: an `h.walk` a layout (the 256, the 128h, the 128v and the 64), four seeds of 500 steps each, on port 1. 3.9's package 3b made it; the grid sequencer's 6b extended it to the rework's two sides. It drives the `grid keys` machine (`docs/notes/lua/grid-core.md`), patterns' lane side and step view, and the voices page's perform side.

**Its ops:**
- a key down: any key the grid shows, on whatever page and side its pane shows, strip keys among them; now and then a key already down is pressed again (a release that never came);
- a held key up;
- the clock advanced 0.05 to 0.6 s;
- a pane's page, side or (on the 64) half changed (both sides of every page);
- the 64's chooser opened (NV held past its hold) and closed;
- a voice's pattern replaced (`S.lib.sequencer.replace_pattern`);
- the grid unplugged, and plugged back at the next key down;
- a rotation (`set_rotation`; a 128 turns between its two layouts);
- K2 with the step editor open;
- the rework's keys on purpose:
  - a key of patterns' lane side or of the voices page's perform side (the step view's bars while it shows), with a tap, a second key or `B` with a target after it;
  - a second key of a held step's or cell's line;
  - the play key;
  - a sparse voice's step tapped;
  - LN tapped, then a lane key (at a lane's length one time in two), a side change or a 64's half change;
  - a loop: one time in four after a letter of its voice is tapped, then held across a bar when its voice will switch; latched from an armed latch and its key let go; or on a 256 latched by `LP` from the other pane;
  - an HD key tapped;
  - an order built with `OR`;
  - two roll keys of one voice;
  - a step view: a hits key held past its hold, a bar key, then the key's release, K2 or nothing.

A page change and a rotation run while the grid is unplugged too: `set_page` takes a port with no grid (pane 1), which the plug then starts over on its start pages, and a rotation is written and turns the grid at the plug.

**The model** keeps, per key the core holds, what its release does:
- toggle its step (a held step whose gesture stands);
- tap its cell (a lane's);
- nothing (a second key, a consumed key, a dropped one);
- or end a hold: NV closes the chooser, FL lets fill go, an HD key lets its voice's scan go, and a loop's or a roll's key ends it.

It also keeps whether each key's press still stands (`gone`), the open step editor's key, the picked voice, LN's arming (`{pane}`), the port's last value a lane was set to, and per voice the key holding its loop and its roll.

**Its rules:**
- **Second keys.** A press of a voice with a held step is its second key, before the hold fires:
  - only a held step of its own side counts (the final review's M1): a side-1 key and a side-2 hits key of one voice never pair;
  - on side 1 a loop between the two keys, cut to the voice's length (one wholly past it makes none, and the voice's loop stays);
  - on side 2's hits, the level from its place, or value A in move.
- **Lane values.**
  - A lane cell's second key sets the held cell from its own place, kept as the port's last value for the lane.
  - A tap clears a cell that holds a value, and gives an empty one the port's last value for the lane, or the lane's first (15, 15, 53, 2, the voice's gate length).
  - A lane value written on an off step of a following A or B turns it on at 15.
- **LN.** Armed, LN takes the next lane key: line 1 sets the voice's length to x; a lane is set to x, or to following when x is its length already. Any page or side change disarms it, and a half change does not.
- **Mode keys** set the voice's mode to the key's.
- **LP.** A latched loop ends with its latch; a held loop is latched, the same loop; with no loop the latch is armed, or disarmed if it was.
- **Holds.** A held step's hold opens the editor 0.3 s on, and the step view where a pane shows side 2. NV's hold opens the chooser 0.5 s on and ends pane 1's keys.
- **The step view.** Its start and end end its pane's keys but the editor's. At a pane's own change the view is the one before the change, as the core reads it in `set_pane`. A bar sets the level, or a lane's value from its place; the value's own key clears the cell, and a free lane's bar sets nothing.
- **Ends of keys.** A pane's view changing ends its keys, a replacement ends its voice's step gestures but the held step whose press the voice's live loop carries (`carriers`; the final review's I1: a further key still moves the loop's end; whether the loop lives is read as given), and an unplug, a plug or a rotation forgets the port, and with it the picked voice, LN and the last values.

**Its values** are the literal tables of `VALUES`, worked out by hand from 3b's formulas, not by the page's arithmetic:
- the level a place gives, on 16 keys and on 8;
- repeats a place gives;
- chance by level;
- the tap's first values.

Gate is known only at its two ends: level 1 is the spec's minimum and level 15 its maximum. Between them the walk checks a value lies strictly inside the spec, and a gate value's own bar key is not known. So on the step view a gate cell that holds a value may be cleared or set.

**After every op** it compares the model with:
- `S.patterns`, `S.grid_held[1]` and the open step editor;
- the step view (`step_view(1)`), the picked voice and LN on each pane;
- each key's press: the core's `still` for it, taken at its press, false exactly where the model's `gone` says;
- each voice's roll, and a loop whose key's press ended (none unless latched);
- a running voice's last `seqGate` in the call log against the gate rule;
- the 64's chooser.

At each key event it also checks:
- the cell value a second key, a tap or a bar key leaves (as 3b's rules give);
- a free lane's bar leaving its cell;
- the loop a second key leaves (its two keys' bounds);
- the length LN's key leaves, and the mode a mode key leaves;
- what `LP` leaves;
- that every latched loop is the same after any key's release;
- that a key whose pane's view changed waits for no hold;
- that a released key's hold, fill, scan hold and unlatched loop ended.

Every invariant runs after every op.

**At the end** every key goes up. Then, before any wait:
- no hold the core armed still lives (the walk keeps each handle `on_hold` puts in `hold_clocks`: a hold never stopped would fire and clear itself during a wait);
- fill is not held;
- no step view shows, no voice rolls and no unlatched loop lives.

And, a second on:
- no roll lives, and every running voice's last `seqGate` is the rule's;
- LN armed is disarmed by a page change;
- with the patterns stopped no letter waits;
- no hold clock is pending or retired (`hold_clocks`, `S.lib.clocks.retired`);
- no positions record holds a key, and no voice's scan is held;
- no step editor and no chooser is open.

**What the walk does not check.**
- A letter's switch, an order (`OR`) and its bars are observed, not predicted. The `pattern letters` invariant checks them: a letter waits only while the patterns play and no order is on.
- The targets (`B` and x 5-8) are pressed but not checked.
- MU and SO are pressed but not checked.
- A loop's bounds after a length cut are not predicted.
- Values other than a cell's are not predicted: a move voice's random value A, and a letter's or a replacement's steps.

**Each walk must have reached:**
- the core's keys: a hold that fired, a hold a page change ended, an unplug with a key held (a row of `S.grid_held[1]` with a press time: a column keeps its table after its keys' releases), a step toggled, a second key, an HD key let go, a page change and a rotation while unplugged, a press ended while its key stayed down;
- the lane side: a key of each new side, a hits second key, a cell tapped and set, LN armed, spent and disarmed by a page change, a target with `B` held (not on the 64, which never shows them together);
- the step view: opened, the editor opened with none (no side 2 shown), a bar key, K2's close;
- loops: a loop made, a latched loop's key let go, `LP` pressed, and one let go after a letter's switch (a loop's end moved after a replacement, `loop_end_after_replacement`, is reached by the by-hand test alone: no seed presses a further key there);
- rolls: a roll pressed, one replaced and one released from under a later key, one a page change ended;
- an order's bar, and a pulse voice's gate opened by its last step's tap;
- on the 256: a step view opened with a key held on its other pane, and `LP` latching a held loop;
- the 64's a release under the chooser, the others' a fill key let go.

**Ties.** Two timed events of one clock op closer than 3 ms (the stub's tick is 1 ms) are left to the code's order, within what they can do:
- a tie opens the editor for one of the keys whose holds were due, never a key whose gesture ended;
- the editor from before stays only where every due hold's gesture may have ended before it fired;
- none open is allowed only where an event of the tie (a replacement, NV's hold) ends the gesture of a key the editor may be open for.

The model then follows the one the code opened, and ends the step view's keys as its open did.

**Faults it catches.** Each is a fault put back, one line (the fill key's two):
- `set_pane` with no `end_pane_keys`;
- the chooser's opening or closing;
- a fill key that never lets go (its `still` always true, its release gone);
- positions' `held_still`, an HD key's release;
- `stop_hold`;
- `forget_port`'s held keys;
- `release_step_key`'s consumed test;
- `replace_pattern`'s `end_step_gestures`.

The 6b faults it catches:
- a step editor its key's release leaves open;
- a `step_view` on a side-1 pane;
- K2's close leaving the view's keys;
- a roll or a loop that ignores its key's `still`;
- a second key that makes no loop;
- `LP` never latching;
- a `latched` that is always true;
- a stop keeping the waiting letters;
- an uncounted page change;
- a `set_level` that never sends the rule;
- a following lane's value that never turns its step on;
- a second key's or a bar's level from the wrong place;
- a tap on a consumed cell;
- a tap's first chance changed;
- repeats spread over three;
- a second key that keeps no last value;
- LN's key at a lane's length that does not set it back to following;
- the mode keys mixed up.

A fill key whose `still` is always true (its release kept) fails only the end's fill check. `stop_hold` also fails the file's end test ("the grid walk's end: ...") through the read before the wait, which a read after it misses; the seeds fail on it sooner, at the editor. The end's new lines have a test of their own ("the grid walk's end names a loop, a roll, ..."). `test/unit/ui_walk_test.lua` is the screen's walk (`docs/notes/lua/ui-core.md`, The UI walk).
