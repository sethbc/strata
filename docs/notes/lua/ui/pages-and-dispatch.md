## Must not break

- Change a page's draw function (`redraw_main`, `redraw_setup`, ...), never `redraw()`: its one dispatch besides the page's is the modal owner's (`S.lib.ui_modal.top()`, below), sanctioned in 3.4 (package 0a). While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector, never the page or an owner.
- While a modal owner is pushed (`lib/ui/modal.lua`), the screen's body and hints, E2, E3, K2, K3 and the arc are the owner's and E1 does nothing; K1 still sets ALT. A release reaches an owner only if its press did: a K2 or K3 that went down on the page before the push (or on an owner since popped) releases into nothing, neither the owner nor the page (the page forgets it: `S.key_press_page`, `S.key_press_at`, `S.key_press_alt`). A push forgets the covered owner's presses, or the page's (#866): the grid's step editor may cover any owner, and the covered one keeps no press whose release went elsewhere. An owner reads how long its key is held only through `S.lib.ui_modal.held_seconds(owner, n)`, never a mark of its own. Push and pop only through `S.lib.ui_modal`; no owner is on the stack twice, and every key down on an owner is on the top one, with its press time (the `modal owner` invariant).
- Each page file creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]` and sets every field but the four arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`), which only its `lib/arc/<page>.lua` sets. `strata.lua` includes every page file before every arc file and asserts every `UI_PAGES` name has its record with `draw`, `hints`, `enc` and `key`. A test checks who sets which field.
- A page's `draw()` draws its body only; `redraw()` draws the hint row from the "hints" flash while one shows, else from the record's `hints(alt_held)`. Never call `draw_hints` from a page.
- A page change goes through `S.lib.ui_keys.set_ui_page`, which runs the records' `leave`/`enter` and forgets every carried arc tick (`forget_arc_ticks()`). Never set `S.ui_page` directly.
- Code finds a page by its index (`UI_PAGES.index.<PAGE>`, `S.ui_page`), never by its title string.
- `redraw()`, `key` and `enc` do nothing until init's first start step sets `S.started` (`START_ORDER.started`, `lib/ui/frame.lua`): norns routes them to the script if its menu closes while the engine loads, before `init` has added the params (#426).
- A test (`test/unit/ui_detent_test.lua`, #427) scans `strata.lua` and every `lib/` file, comments and strings blanked: no `redraw()` or `arc_redraw()` call outside `lib/ui/frame.lua` (a call through another table, `fileselect.redraw()` or a record's `arc_redraw(port)`, is another function), no assignment to `ui_page` outside `lib/ui/frame.lua` and `lib/ui/keys.lua`, no `alt_key` call through a table outside `lib/ui/alt.lua`, no `draw_hints` call outside `strata.lua` and `lib/ui/header.lua`.

## Machines

### modal owner
- **State:** `stack` (the pushed owners, the top one last), `pressed[n]` and `pressed_at[n]` (the owner key `n` went down on and when), local to `lib/ui/modal.lua`; read through `S.lib.ui_modal.top()`, `top_name()` and `S.lib.ui_modal.held_seconds(owner, n)`. Per owner: off the stack, on top, or covered by another (only SEQ's step editor, which a grid pushes over any owner). Each owner keeps its own open flag beside its place on the stack, held by its own invariant (the owners' table, The modal owner below).
- **Invariant:** `modal owner`: no owner is on the stack twice, every key down on an owner is on the top one (a push forgets the covered owner's), and a key has a press time exactly while it is down on an owner.
- **Test:** `test/unit/ui_modal_test.lua`: "held_seconds is nil for an owner that is not on top" (and "a key pressed before the owner was pushed releases into nothing", "a release handler that raises leaves no key held (a modal owner's)").

No test runs this table: the modal owners are the design's (its section 5, a table and no test). A push of an owner already on the stack raises, so `on top` + `push` and `covered` + `push` are no rows.

| State | Event | Next | Effect |
|---|---|---|---|
| off | push | on top | the covered owner's presses and the page's forgotten (#866); a redraw |
| off | pop | off | nothing |
| on top | pop | off | its presses forgotten: a key still down releases into nothing; a redraw |
| on top | another owner pushed | covered | its presses forgotten |
| on top | K2 or K3 down | on top | `key(n, 1)`, the press and its time noted |
| on top | K2 or K3 up | on top | `key(n, 0)` only if it saw the press (`held_seconds` answers inside it), then the press forgotten, also when it raises |
| on top | `forget_held_keys` (the menu, the file selector, a name entry) | on top | its presses forgotten |
| covered | the owner over it popped | on top | nothing comes back: it saw no press since it was covered |
| covered | pop | off | nothing of its presses was left |
| covered | K2 or K3 | covered | the top owner's |

## Pages and dispatch

A page record may also have `animates()`: while it returns true for the shown page, `draw_frame` redraws the screen every frame (`docs/notes/lua/ui/redraws.md`).

The screen has `NUM_UI_PAGES` (10, `#UI_PAGES`) pages, named in `UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "MOD", "BUFFER", "SCENES", "SETUP", "IO"}` (3.4's MOD after LFO; 3.6's IO appended last, so no other page's index moved). `UI_PAGES.index[name]` is a page's index (`UI_PAGES.index.FX == 4`, `UI_PAGES.index.MAIN == 1`; the old `UI_PAGES.MAIN_PAGE` is gone, #393). `S.ui_page` is the index of the shown page.

Encoders and keys (`strata.lua`):
- `enc(1, d)` selects the page (`S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))`), stopping at MAIN and IO. E1 does nothing else. `set_ui_page` does nothing when the page does not change; on a change it calls the old record's `leave()`, forgets every carried arc tick (`forget_arc_ticks()`, so ticks turned on one page never step a param on another), sets `S.ui_page` and calls the new one's `enter()`, if the records have them.
- At init a start step in `strata.lua` (`START_ORDER.e1_settings`) turns E1's acceleration off and sets its sensitivity to `E1_TICKS_PER_PAGE` (4) with `norns.enc.accel(1, false)` / `norns.enc.sens(1, ...)`, so a fast turn steps pages instead of skipping to IO. norns resets these on every script load, so cleanup restores nothing.
- `enc(2|3, d)` calls `S.registry.pages[S.ui_page].enc(n, d)`, and `key(n, 1)` (K2, K3) calls `S.registry.pages[S.ui_page].key(n)`. With ALT held both go the ALT way instead (`docs/notes/lua/ui/alt-and-keys.md`).
- `key(1, z)` only sets ALT (`S.lib.ui_alt.set(z == 1)`; K1 held is ALT; norns delivers K1 to a script only once held). `forget_held_keys` clears it.
- Master density left E1. It is on the FX page's first row, MAIN's arc ring 1 and in params. The header no longer shows it.

Page records. Each page lives in its own file and creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]`:
- Required: `name`, `draw()` (the page body only), `hints(alt_held) -> string` (the hint row), `enc(n, d)` (E2, E3), `key(n)` (K2, K3 presses).
- Optional, every one dispatched today:
  - `alt_enc(n, d) -> handled`, `alt_key(n)`, `alt_key_release(n)`: the ALT layer (`docs/notes/lua/ui/alt-and-keys.md`);
  - `key_release(n)`: a plain key's release, on the page it went down on;
  - `enter()`, `leave()`: run by `set_ui_page` on a page change;
  - `arc_button()`: the arc's button on this page. `arc_key` (`lib/arc/core.lua`) calls the shown record's `arc_button` on a press, on every page that has one, and requests a redraw; a page without one ignores the button. MAIN's is `start_stop_selected_voice` (K3; VOICE's is `start_or_stop_selected_voice`, and `toggle_lock` locks);
  - `header_status() -> string|nil`: a text that replaces the header's indicators (`docs/notes/lua/ui/header-and-flashes.md`);
  - `layout_states`: an array of `{name, setup = function(context)}` the layout tests (`docs/notes/lua/ui/layout-and-renders.md`) and the page renders draw, each on a fresh script with the page shown.
- Optional, called by the shared ALT+K2 handler (`S.lib.ui_alt.k2_up` and `k2_hint`, from the page's own `alt_key_release` and `hints`), never by strata.lua: `randomize_section() -> spec or nil, reason` (set by MAIN, VOICE, SEQ, FX and LFO), `alt_hold()` (set by VOICE, SEQ and LFO) and `alt_hold_hint` (3.4: a string or a function returning one, the held hint's text in place of `reset`). See `docs/notes/lua/ui/alt-and-keys.md`, ALT+K2 on the randomizing pages.
- Arc fields, set only by `lib/arc/<page>.lua`: `arc_delta(n, d)`, `arc_redraw(arc_port)`, `arc_alt_delta(n, d)`, `arc_alt_redraw(arc_port)` (`docs/notes/lua/arc-core.md`).
- Ownership: the page file sets every field but the arc fields; the arc file sets only those, on `S.registry.pages[UI_PAGES.index.<PAGE>]`. So a page and its rings never edit the same file. `strata.lua` includes every page file before every arc file.
- To add a page: add its name to `UI_PAGES` (`NUM_UI_PAGES` follows), write its file and record, include it from `strata.lua` with the other pages, and, if it has rings, an arc file like `lib/arc/fx.lua` included after the pages (`docs/notes/lua/arc-pages.md`). Every page in `UI_PAGES` already has its page file, and every page but SETUP (which has no rings) and IO (whose rings, the tape's, come with its arc file later in 3.6) its arc file, so changing one adds no include.

`redraw()`:
- `screen.clear(); draw_header(); record.draw(); draw_hints(S.lib.ui_flash.text("hints") or record.hints(S.alt_held)); screen.update()`, with `record = S.registry.pages[S.ui_page]`, `record.draw` and the hint text computed in one function run through `S.lib.ui_frame.contained_call`. When it fails: `screen.clear(); draw_header(); draw_hints("draw error"); screen.update()` (`docs/notes/lua/ui/redraws.md`, Draw errors).
- Nothing before init's first start step (`S.started`).
- Except while the BUFFER page's file selector is open (`S.BUFFER_PAGE.file_selector_open`): then it calls `fileselect.redraw()` and returns, so neither norns' own `redraw()` calls nor Strata's frame clock draw the page over the file list (`docs/notes/lua/pages/buffer.md`).
- While a modal owner is pushed (after the file selector's check): the header, then `owner.draw()` and `draw_hints(owner.hints(S.alt_held))` (no hints function: an empty hint row), in the same contained function as the page's; no flash replaces the owner's hints.
- The hint row (`draw_hints(text)`: level 4, x=0, y=62) is drawn once, by `redraw()`: the "hints" flash while one shows (only on its owning page), else the record's hints.

## The modal owner

`lib/ui/modal.lua` (`S.lib.ui_modal`, 3.4, design §0.1): a stack of screen owners for a view that takes the screen and the controls from the page until it closes (3.4's step editor, §8.7; the scene name entry has none, since norns' `textentry` takes the keys itself).
- `push(owner)` puts an owner on top and requests a redraw; `pop(owner)` takes it off wherever it is (an owner not on the stack: nothing); `top()` is the owner the input goes to, or nil; `key(n, z)` is strata.lua's K2/K3 while one is pushed; `held_seconds(owner, n)` is how long key `n` has been down on `owner`, or nil unless `owner` is on top and saw the press (its own release still reads it: the press is forgotten after `key(n, 0)`, even when that raises, whose error is then raised again); `forget_presses()` forgets every owner's presses (a push, and `forget_held_keys` as the norns menu, the file selector or a name entry takes the keys); `top_name()` is the top owner's name, or nil (the header's title, #901); `close_all()` calls each owner's `close` from the top down, each contained (`S.lib.ui_frame.contained_call`, so a close that raises prints one line and skips no later cleanup step), and pops one its close left on the stack or whose close raised, with one console line, so the stack is empty after it (cleanup's step 141, `modal_owners`, #899). A push first forgets the covered owner's presses and the page's (`S.lib.ui_keys.forget_presses`). An owner already on the stack, or one without a `draw` function, a `name` of 1 to 5 characters or a `close` function, is an error.
- An owner is `{name = string, close = fn(), draw = fn(), hints = fn(alt_held) -> string, enc = fn(n, d), key = fn(n, z), arc_delta = fn(n, d), arc_key = fn(n, z), arc_redraw = fn(arc_port), animates = fn() -> boolean}`; `name`, `close` and `draw` are required, and a missing handler ignores its input (an owner without `arc_redraw` leaves the rings off). `name` (plain ASCII, at most 5 characters, so it ends before the page dots with the layout check's 4 px) is what the header's title shows while the owner is on top (3.9, #901); `close` closes the owner as its own K2 does, its open flag and its place on the stack together, so its invariant holds after it (#899). Both are the record's: nothing else stores them.
- An owner's `animates()` is read by the frame clock as a page's is (`docs/notes/lua/ui/redraws.md`, #592): while it is true the screen draws every frame whatever page is underneath; an owner without one leaves the frame to the page's own `animates()`. SEQ's step editor animates while its ALT+K2 is held and while the patterns play.
- While one is pushed: `enc` ignores E1 and sends E2 and E3 to `owner.enc(n, d)` (never the page's `alt_enc` or `enc`); `key` sets ALT from K1 as always, clears the key's page press marks and hands K2 and K3 to `S.lib.ui_modal.key(n, z)` (never `alt_action`, `key_release` or `alt_key_release`), which sends a press to the top owner's `key(n, 1)`, noting which owner it went to and when (`util.time()`), and a release to `key(n, 0)` only when that owner is still the top one and saw the press (a pop forgets its owner's presses); `redraw` draws the header, the owner's body and hints; `arc_delta`, `arc_key` (presses and releases) and `arc_redraw` (`lib/arc/core.lua`) go to the owner's handlers. No page change happens underneath (#875): in the running script `set_ui_page`'s callers are E1, which an owner ignores, and MOD's K3 (`S.lib.pages_lfo.show_lfo`), a page key the owner takes instead; nothing under `lib/grid/` calls it, and the grid's one effect on the screen is pushing SEQ's step editor.
- The `modal owner` invariant: no owner is on the stack twice, every key down on an owner is on the top one (a push forgets the covered owner's), and a key has a press time exactly while it is down on an owner.

The owners (3.9, #902): the name the header shows while each is on top (#901), who opens each, what closes it, which cleanup step closes it (#899), and which presses it reads (each through `S.lib.ui_modal.held_seconds(owner, n)`; the others act at the press). Each has an invariant that ties its open flag to the stack: its owner is the modal one while it is open (or beneath SEQ's step editor, which a grid can push over any owner) and never while it is closed.

| Owner | Name | Opened by | Closed by | At cleanup | Presses it reads | Invariant |
|---|---|---|---|---|---|---|
| SEQ's step editor (`lib/pages/seq.lua`) | `STEP` | a grid's held step key (`open_step_editor`, over any owner; a second open replaces the first) | K2; the key's release, the end of its gesture (a grid page change, a half switch, its voice's pattern replaced), a press with no release, the grid's removal (`close_step_editor`) | closed first (step 141; its record's `close` passes the port that opened it) | ALT+K2's hold (`K2:reset`) | `step editor` |
| the zones editor (`lib/ui/zones.lua`) | `ZONES` | K3 on SETUP's `mpe & zones` row | K2 | its learn ends (step 117), then closed (step 141) | none | `zones editor` |
| the voice picker (`lib/ui/voice_picker.lua`) | `PICK` | K3 on VOICE's `preset` row | K2 | closed (step 138) | ALT+K2's hold (clear), ALT+K3's release (the name entry) | `voice picker` |
| the scale editor (`lib/ui/scale_editor.lua`) | `SCALE` | K3 on SETUP's `scale & tuning` row | K2 | closed (step 139) | none | `scale editor` |
| the factory list (`lib/factory.lua`) | `SETS` | K3 on SETUP's `factory sets` row | K2 | closed (step 116) | none | `factory` |
| the slice editor (`lib/ui/slice_editor.lua`) | `SLICE` | K3 on BUFFER's `slices` field, a slot with audio (a second open replaces the first) | K2; its slot emptied | closed (step 141) | none | `slice editor` |
| IO's detail list (`lib/pages/io.lua`) | `IO+` (never `IO`, the page's title) | K3 on a detail row | K2 | closed (step 141) | none | `io detail` |

## Registering a page

- **Registering a page**: a new `lib/pages/<name>.lua` creates its record at `S.registry.pages[UI_PAGES.index.<NAME>]` and sets every field but the four arc fields. Add the name to `UI_PAGES` in `lib/constants.lua` (one line; `NUM_UI_PAGES` is `#UI_PAGES` and `UI_PAGES.index` follows) and its `include` to `strata.lua` among the page includes (one line). Its rings, if any, go in a `lib/arc/<name>.lua`, included after every page file, that sets only `arc_delta`, `arc_redraw`, `arc_alt_delta` and `arc_alt_redraw` on the record. So a page package and the arc package never edit the same file. Every page in `UI_PAGES` already has its page file, and every page but SETUP its arc file. A page's own files are its `lib/pages/<name>.lua`, `docs/user/pages/<name>.md`, `docs/notes/lua/pages/<name>.md` and `test/unit/pages_<name>_test.lua`; the arc's page rings are `lib/arc/<name>.lua`, `docs/notes/lua/arc-pages.md` and `test/unit/arc_pages_test.lua`; a grid layout's are `lib/grid/layout_<size>.lua`, `docs/user/grid/<size>.md`, `docs/notes/lua/grid/layout_<size>.md` and `test/unit/grid_layout_<size>_test.lua`. A page adds layout-test states only through its record's `layout_states`.
