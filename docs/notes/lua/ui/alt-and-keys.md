## Must not break

- A key release acts only on the page where the key went down (`S.key_press_page`). Keys held while the norns menu opens are forgotten, and so are keys held across a page change: `set_ui_page` clears `S.key_press_page` and `S.key_press_alt` (not `S.alt_held`, K1 is still down) and runs no ALT-release hook, so a K2 or K3 held out of a page and back does nothing when it comes up (#234).
- Every ALT+K2/ALT+K3 action goes through `alt_action(page, n)`, never a direct `alt_key` call; the exceptions act on release in `alt_key_release`, by how long they were held (`key()` notes the press time), while the press does nothing (BUFFER's record has no `alt_key`, #959; a randomizing page's notes nothing): BUFFER's ALT+K2 and ALT+K3 (`docs/notes/lua/pages/buffer.md`) and the ALT+K2 of every page that randomizes, through the shared handler (ALT+K2, below). SCENES' ALT+K2 also acts on its release, however long it was held (it opens norns' text entry, which a K2 release would cancel, `docs/notes/lua/pages/scenes.md`); its `alt_key(2)` does nothing. A key pressed with ALT releases through `alt_key_release`, never `key_release`, even when K1 comes up first (on BUFFER, an ALT+K2 release must never open the file selector). `forget_held_keys` clears `S.alt_held` and `S.key_press_alt`. When ALT goes from held to not held (`S.lib.ui_alt.set(false)`, `forget_held_keys`), the `S.registry.alt_release` hooks run (`S.register_alt_release`).
- A randomizing page's ALT+K2 decides at the release only (`S.lib.ui_alt.k2_up`), and its hint and its release share one decision (`quick_action` for a quick press, no K2 hint where it draws nothing; past `ALT_HOLD_SECONDS`, `K2:reset` for a page's `alt_hold`, or its `alt_hold_hint`, else `K2:cancel`, since the release then does nothing), so the hint never offers what the release would not do (#823). A press carried across a page change holds nothing: `k2_held()` reads `S.key_press_page` and `S.key_press_alt`, which `set_ui_page` clears, and `k2_up` acts only on the page the press went down on.
- **One press time per key, the dispatcher's** (#866): `key()` sets `S.key_press_at[n]` (`util.time()`) with `S.key_press_page[n]` and clears it wherever that is cleared; a modal owner's press time is kept beside `pressed[n]` in `lib/ui/modal.lua`. A held gesture reads only `S.lib.ui_keys.held_seconds(n)` or `S.lib.ui_modal.held_seconds(owner, n)`, never a mark of its own (the shared ALT+K2, BUFFER, SEQ's step editor, the voice picker), so no loss path can leave a stale one. A release runs before its press is forgotten, so it reads how long the key was held; one that raises still has its press forgotten (it runs under `xpcall(..., with_traceback)` in `key()` and `S.lib.ui_modal.key`, and its error, with the traceback from where it raised, is raised again after), so no key stays held. `S.lib.ui_modal.push` forgets the covered owner's presses, or the page's, and `forget_held_keys` forgets the page's and every owner's.
- `unwatch_menu_opening()` puts `_menu.set_mode` back only if it is still Strata's wrapper; otherwise Strata's wrapper becomes a pass-through.
- The menu watch's wrapper never lets a failure stop the menu opening or closing: the file selector release, the forgetting of held keys (ALT-release hooks included) and each `S.registry.menu_close` hook run in their own `pcall`, and norns' own `set_mode` runs under a `pcall` too, so the close hooks run even when it raised (its `set_mode(false)` ends with the script's `redraw()`); its error is raised again after them. It calls only upvalues (no script-global lookup): `forget_held_keys` and `norns.menu.status` are held from include time (#425), so `lib/ui/keys.lua` stays included before `lib/ui/menu_watch.lua`, and a later replacement of either global never reaches the wrapper or the 10 Hz fallback.

## Machines

### key presses
- **State:** per key (2, 3) on the page: `S.key_press_page[n]`, `S.key_press_at[n]` and `S.key_press_alt[n]` (`lib/ui/keys.lua`, set by `key()` in `strata.lua`), read through `S.lib.ui_keys.held_seconds(n)` (and `S.lib.ui_alt.k2_held()` for ALT+K2); `S.alt_held` beside them. Up, down plain, down ALT; the States section below gives each state's fields. A key down on a modal owner is the `modal owner` machine's (`docs/notes/lua/ui/pages-and-dispatch.md`), never this one's: while an owner is pushed `key()` takes the page's key to up.
- **Invariant:** `key presses`: an ALT press has a press page, and a key has a press page exactly while it has a press time.
- **Test:** `test/unit/ui_test.lua`: "key presses: every cell is decided" and its rows (K2 on FX, whose `key`, `key_release`, `alt_key` and `alt_key_release` are probes that log whether `held_seconds` answered; the release after a loss is pressed on FX again); the invariant runs after every unit test.

Every cell is a row. `press` is K2 down as ALT stands (held in `down ALT`); `ALT press` is K1 down, then K2. A press of a key already down does not come from norns, which sends a key's press only after its release; the rows say what `key()` would do with one. `up` + `release` is a press forgotten while the physical key stayed down.

| State | Event | Next | Effect |
|---|---|---|---|
| up | press | down plain | the page and time noted; the record's `key(n)` (which reads `held_seconds`) |
| up | ALT press | down ALT | the page and time noted, the ALT mark; `alt_action(page, n)` (BUFFER has no `alt_key`: nothing at the press) |
| up | release | up | nothing (a press the page never saw, or forgot, releases into nothing) |
| up | page change | up | nothing |
| up | modal push | up | nothing |
| up | forget_held_keys | up | nothing |
| down plain | press | down plain | noted again; `key(n)` again |
| down plain | ALT press | down ALT | marked an ALT press; `alt_action(page, n)` |
| down plain | release | up | `key_release(n)` (reads `held_seconds`), then the marks cleared, also when it raises |
| down plain | page change | up | `set_ui_page` forgets it (#234): its release runs nothing |
| down plain | modal push | up | `S.lib.ui_modal.push` forgets it (#866): its release runs nothing |
| down plain | forget_held_keys | up | forgotten (the menu, the file selector, a name entry), ALT too |
| down ALT | press | down ALT | noted again (ALT is held); `alt_action(page, n)` again |
| down ALT | ALT press | down ALT | as `press` |
| down ALT | release | up | `alt_key_release(n)` (even with K1 up first), then the marks cleared, also when it raises |
| down ALT | page change | up | forgotten; ALT stays held and no ALT-release hook runs (K1 is still down) |
| down ALT | modal push | up | forgotten; ALT stays held |
| down ALT | forget_held_keys | up | forgotten, `S.alt_held` false and the ALT-release hooks run |

## States

The fields: `S.key_press_page[n]` (the page key `n` went down on, nil when up), `S.key_press_at[n]` (when it went down, nil when up), `S.key_press_alt[n]` (true for an ALT press) and `S.alt_held` (K1 held). The "key presses" invariant checks that an ALT press has a press page and that a key has a press page exactly while it has a press time.

| Per key (2, 3) | `key_press_page[n]` | `key_press_at[n]` | `key_press_alt[n]` |
|----------------|---------------------|-------------------|--------------------|
| up | nil | nil | nil |
| down, plain | the page | the press time | nil |
| down, ALT | the page | the press time | true |

Legal: any of the three per key, with `S.alt_held` either way (K1 may come up before the key). A page change, a modal push and `forget_held_keys` take a key to up (its marks forgotten) while the physical key is still down, so its release then does nothing. Never an ALT press without a press page, nor a press page without a press time. `S.lib.ui_keys.held_seconds(n)` is `util.time()` less the press time while the key is down on the page showing, else nil.

Transitions, one function each:
- `key(n, 1)` and `key(n, 0)` in `strata.lua`: up to down (plain or ALT by `S.alt_held`) and back to up, the release handler running first; while a modal owner is pushed (`docs/notes/lua/ui/pages-and-dispatch.md`, The modal owner), both take the key to up and go to `S.lib.ui_modal.key(n, z)`: a press to the owner's `key(n, 1)`, a release to its `key(n, 0)` only if it saw the press, so a key that went down on the page releases into nothing.
- `S.lib.ui_keys.set_ui_page`: every key to up, `S.alt_held` untouched.
- `S.lib.ui_modal.push`: every key to up (`S.lib.ui_keys.forget_presses`), `S.alt_held` untouched, and the covered owner's presses forgotten.
- `forget_held_keys`: every key to up, every owner's presses forgotten (`S.lib.ui_modal.forget_presses`) and `S.alt_held` false, running the ALT-release hooks if ALT was held.

## ALT

`lib/ui/alt.lua` (`S.lib.ui_alt`). ALT is K1 held: norns delivers K1 to a script only after `KEY1_HOLD_TIME` (0.25 s, `lua/core/menu.lua`), and a shorter press opens the norns menu, so K1 is a hold-only key (3.1 design §2).
- `S.lib.ui_alt.set(held)` sets `S.alt_held` and requests a redraw (the hint row shows the page's ALT layer, `record.hints(true)`, and the arc switches to its ALT rings). `key(1, z)` calls it.
- `alt_action(page, n)` (global) runs `S.registry.pages[page].alt_key(n)` and returns true, or returns false and does nothing when `n` is not 2 or 3, `page` is not a page index, or the record has no `alt_key`. It takes the page as an argument, so a caller can name a page that is not showing.
- `key(n, 1)` with ALT held records the key's page and time (`S.key_press_page[n]`, `S.key_press_at[n]`), marks it an ALT press (`S.key_press_alt[n] = true`) and calls `alt_action(S.ui_page, n)`; the record's `key` never runs. Without ALT it clears the mark and calls `key(n)`. A page without `alt_key` does nothing at an ALT+K2/ALT+K3 press: it never falls through to `key`. The press is still an ALT press, so its release goes to the record's `alt_key_release` if it has one (BUFFER, whose ALT keys act only there).
- `key(n, 0)`, if the key went down on the page still showing, calls `alt_key_release(n)` for an ALT press and `key_release(n)` otherwise (each only if the record has it), then clears the marks, so the release reads `held_seconds(n)`. The press decides, not the state of K1 at release: K1 down, K2 down, K1 up, K2 up releases through `alt_key_release`, so BUFFER's K2 release never opens the file selector after an ALT+K2; K2 down, K1 down, K2 up releases through `key_release`.
- `enc(2|3, d)` with ALT held calls `alt_enc(n, d)` first; when the record has none or it returns false or nil (not handled), `enc(n, d)` runs. `enc(1, d)` steps the page with or without ALT and never reaches the record.
- `forget_held_keys` (as the norns menu, the file selector or a name entry takes the keys) clears `S.alt_held` and every `S.key_press_alt` mark with `S.key_press_page` and `S.key_press_at`, and every modal owner's presses.

K1 held as ALT is confirmed on hardware, so the design's long-press fallback (§2: a 0.6 s hold of K2 or K3) was never wired, and 3.1's unused hook for it is gone.

## ALT+K2 on the randomizing pages

One handler in `lib/ui/alt.lua` for every page whose ALT+K2 randomizes (MAIN, VOICE, SEQ, FX and LFO; #557), acting on release, as BUFFER's ALT keys do:
- The page's ALT+K2 press calls nothing (`key()` notes the press time, #866; #959), and its `alt_key_release(2)` calls `S.lib.ui_alt.k2_up(record)`. strata.lua's `key` routes the release there even when K1 came up first.
- `k2_up(record, held)` acts only on a press still held: `held` is how long it was down, by default the page's ALT+K2 (`k2_held()` and `S.lib.ui_keys.held_seconds(2)`, read in the release `key()` runs); SEQ's step editor passes its own (`S.lib.ui_modal.held_seconds`). With none, nothing:
  - held `ALT_HOLD_SECONDS` (0.5 s, `lib/constants.lua`) or longer: the record's `alt_hold()`, if it has one (VOICE and LFO: reset to default; SEQ, 3.4: the edit view opens, or in it the row resets, `docs/notes/lua/pages/seq.md`); a page without one (MAIN and FX) does nothing: the long press cancels;
  - quicker: `quick_action(record)`: `S.lib.mutation.undo()` while `undo_for(spec.page, spec.section, spec.voice)`, else nothing where the press draws nothing (no spec, or a draws spec with none: VOICE's type and preset rows, a Sub voice's mix; #823), else nothing for a locked voice, else `S.lib.mutation.randomize(spec)`. Then it requests a redraw.
- The record's `randomize_section()` returns the spec of the section under its cursor (`docs/notes/lua/mutation.md`) and, for a locked voice, `"locked"` second: the spec still comes, so an undo held there runs (MAIN's undo wins over the lock, as before #557), but nothing is randomized. `nil` (no spec) randomizes nothing.
- `k2_hint(record)` is the hint's ALT+K2 part, what letting go will do: once the press has been held `ALT_HOLD_SECONDS`, `K2:reset` on a page with `alt_hold` and `K2:cancel` on a page without one (its release does nothing); before, the quick action's: `K2:undo`, `K2:locked` or `K2:rand`, or `nil` where a quick press draws nothing, and the page leaves K2 out of its hint (VOICE, as MOD's `k2_part`; `""` alone while K1 is up and K2 down; #823). So no page concatenates it: MAIN, VOICE, SEQ (its pattern view and its step editor), FX and LFO build their hint rows through `S.lib.ui_alt.join(...)`, which joins its parts with a space and leaves a nil or empty part out (`""` for none); a test draws every randomizing page's hints with `k2_hint` nil, ALT held and K2 held. A record with `alt_hold` may name what its hold does with `alt_hold_hint` (3.4), a string or a function returning one: the held hint is then `K2:` and that text (SEQ's `K2:edit`, MOD's `K2:clear`); without it, `K2:reset`. A record without `alt_hold` says `K2:cancel` whatever its `alt_hold_hint`. Every randomizing page animates while `S.lib.ui_alt.k2_held()` (its `animates`, as BUFFER's does; MAIN's `main_animates`), so the frame clock draws the change at the hold time.
- K1 let go before K2: the release still acts (randomize, undo, reset or cancel), so each randomizing page's `hints(alt_held)` shows `k2_hint(record)` alone while `not alt_held and S.lib.ui_alt.k2_held()`, as BUFFER shows its release text whether or not ALT is held; once K2 is up the plain hints return.
- `k2_held()` is true while ALT+K2 is down on the page showing: `S.lib.ui_keys.held_seconds(2)` answers and `S.key_press_alt[2]` is true. A page change, the norns menu, the file selector and a modal push clear those marks, and the module keeps no mark of its own, so nothing goes stale (#866; before, its own `k2_press` stayed stale until the next press).
- Two pages in a row: the undo names its page and section, so a quick press on another page randomizes there and replaces the undo, never undoing the first page's.

## Key releases and the norns menu

Releases:
- `key(n, 1)` records `S.key_press_page[n] = S.ui_page` and `S.key_press_at[n] = util.time()`.
- `key(n, 0)` calls the page record's `key_release(n)` (or `alt_key_release(n)` for an ALT press, ALT above) only if the key went down on the page still shown, so a key held across a page change does nothing when released, then clears both.
- Only BUFFER has a `key_release` today; on every other page releases do nothing.
- "K2 is held on this page" is `S.key_press_page[2] == S.ui_page`.

Keys held into the menu:
- The norns menu (K1, PARAMS, its file selector) takes every key while open (`_menu.key` is the menu's handler), so a key released there never reaches `key()`.
- `forget_keys_held_through_menu()`, called at the end of `drift_update` (the 10 Hz `S.drift_metro` tick), clears `S.key_press_page`, `S.key_press_at`, `S.key_press_alt`, every modal owner's presses and `S.alt_held` whenever `norns.menu.status()` is true. It calls `forget_held_keys` and `norns.menu.status` through upvalues the module took at include time (`lib/ui/keys.lua` is included first), so it works after norns swaps the script's globals away.
- Without it, a key released in the menu would stay held on the page it went down on.
- It also runs the moment the menu opens. Every way into the menu (K1, a script error, a keyboard's menu key) calls `_menu.set_mode(true)`, which `lua/core/menu.lua` and `keyboard.lua` look up on `_menu` at each call.
- So `watch_menu_opening()` (from its start step, `START_ORDER.menu_watch`) wraps it in `menu_watch.wrapper`: call norns' function (under `pcall`), then `forget_keys_held_through_menu()` when `mode == true`, in a `pcall` that prints `strata: forgetting held keys failed: <error>` (a failing ALT-release hook never stops the menu opening).
- The wrapper holds norns' function, `forget_keys_held_through_menu`, `release_superseded_file_selector` and the `S.registry.menu_close` list as upvalues (no script-global lookup).
- As the menu closes (`mode == false`, while the watch is active), after norns' `set_mode(false)` returns or raises, the wrapper runs each `S.registry.menu_close` hook (`S.register_menu_close(fn)`) in order, each in its own `pcall`: a hook that fails prints `strata: menu close hook failed: <error>`, and the next hook still runs and the menu still closes. Then, if norns' `set_mode` raised (a failing `redraw()`), the wrapper raises its error again, so norns still reports it. The list is read when the wrapper is built (the `menu_watch` start step), so hooks register at include time (or in a test's `before_init`). SYSTEM > DEVICES moves a grid, arc or MIDI device to another port with no `add` or `remove` (`docs/notes/lua/grid-core.md`, `docs/notes/lua/arc-core.md`, `docs/notes/lua/midi.md`). The hooks today, in the order they register: `S.lib.io_ports.reconcile` (3.6, `docs/notes/lua/io/ports.md`), `S.lib.midi_in.reconcile`, `S.lib.io_midi_out.reconcile_owed` (the offs a device is still owed, #747, `docs/notes/lua/io/midi_out.md`), `S.lib.ui_voice_picker.reconcile_name_entry` (the voice picker's name entry, 3.8, `docs/notes/lua/ui/voice-picker.md`), `S.lib.pages_scenes.reconcile_name_entry` (SCENES' name entry, `docs/notes/lua/pages/scenes.md`), `S.lib.arc_core.reconcile` and `S.lib.grid_core.reconcile_ports` (a test counts the names this line gives against `S.registry.menu_close`).
- `unwatch_menu_opening()`, cleanup's second step (after the tempo handler, before anything that can fail), puts `menu_watch.original_set_mode` back only if `_menu.set_mode` is still Strata's wrapper. Otherwise (something wrapped it later) it leaves that wrapper in place and turns Strata's into a pass-through (`menu_watch.active = false`).
- The 10 Hz tick stays as a fallback.
- norns has no key-state query.
- A file selector opened from play mode, as BUFFER K2 does, keeps `norns.menu.status()` false and takes the keys through the global `key`. It opens on K2's release, so only a K3 or K1 (ALT) held at that moment can be released there. `buffer_key_release` therefore calls `forget_held_keys()` just before `fileselect.enter`. `forget_held_keys` is a global: it clears `S.key_press_page`, `S.key_press_at`, `S.key_press_alt`, the modal owners' presses and `S.alt_held`, and is also the body of `forget_keys_held_through_menu`.

## Calls

- **A covered owner forgets its presses** (#866, the design's Calls): the grid's step editor may still be pushed over any owner (the voice picker, the zones editor, ...), and nothing is refused. `S.lib.ui_modal.push` forgets the covered owner's presses, and the page's when no owner was pushed, so their releases, which go to the new top owner, leave nothing behind: no hint naming a key that is up, no animation, no later tap acting on an old press.
- **ALT after a name entry** (#947) stays forgotten until K1 is pressed again. Every path that takes a key's release away forgets ALT first (`forget_held_keys`), so ALT never sticks; the reverse is kept: after a name entry (`lib/ui/name_entry.lua`) or BUFFER's file selector closes with K1 still down, `S.alt_held` is false until K1 comes up and goes down again, since norns has no key-state query. A test holds it.
