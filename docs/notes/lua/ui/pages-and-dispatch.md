## Must not break

- Change a page's draw function (`redraw_main`, `redraw_setup`, ...), never `redraw()`: its one dispatch besides the page's is the modal owner's (`S.lib.ui_modal.top()`, below), sanctioned in 3.4 (package 0a). While `S.BUFFER_PAGE.file_selector_open` is set, `redraw()` draws the file selector, never the page or an owner.
- While a modal owner is pushed (`lib/ui/modal.lua`), the screen's body and hints, E2, E3, K2, K3 and the arc are the owner's and E1 does nothing; K1 still sets ALT. A release reaches an owner only if its press did: a K2 or K3 that went down on the page before the push (or on an owner since popped) releases into nothing, neither the owner nor the page (the page forgets it: `S.key_press_page`, `S.key_press_alt`). Push and pop only through `S.lib.ui_modal`; no owner is on the stack twice, and every key down on an owner is on one that is pushed (the `modal owner` invariant).
- Each page file creates one record at `S.registry.pages[UI_PAGES.index.<PAGE>]` and sets every field but the four arc fields (`arc_delta`, `arc_redraw`, `arc_alt_delta`, `arc_alt_redraw`), which only its `lib/arc/<page>.lua` sets. `strata.lua` includes every page file before every arc file and asserts every `UI_PAGES` name has its record with `draw`, `hints`, `enc` and `key`. A test checks who sets which field.
- A page's `draw()` draws its body only; `redraw()` draws the hint row from the "hints" flash while one shows, else from the record's `hints(alt_held)`. Never call `draw_hints` from a page.
- A page change goes through `S.lib.ui_keys.set_ui_page`, which runs the records' `leave`/`enter` and forgets every carried arc tick (`forget_arc_ticks()`). Never set `S.ui_page` directly.
- `redraw()`, `key` and `enc` do nothing until init's first start step sets `S.started` (`START_ORDER.started`, `lib/ui/frame.lua`): norns routes them to the script if its menu closes while the engine loads, before `init` has added the params (#426).
- A test (`test/unit/ui_detent_test.lua`, #427) scans `strata.lua` and every `lib/` file, comments and strings blanked: no `redraw()` or `arc_redraw()` call outside `lib/ui/frame.lua` (a call through another table, `fileselect.redraw()` or a record's `arc_redraw(port)`, is another function), no assignment to `ui_page` outside `lib/ui/frame.lua` and `lib/ui/keys.lua`, no `alt_key` call through a table outside `lib/ui/alt.lua`, no `draw_hints` call outside `strata.lua` and `lib/ui/header.lua`.

## Pages and dispatch

A page record may also have `animates()`: while it returns true for the shown page, `draw_frame` redraws the screen every frame (`docs/notes/lua/ui/redraws.md`).

The screen has `NUM_UI_PAGES` (8, `#UI_PAGES`) pages, named in `UI_PAGES = {"MAIN", "VOICE", "SEQ", "FX", "LFO", "BUFFER", "SCENES", "SETUP"}`. `UI_PAGES.index[name]` is a page's index (`UI_PAGES.index.FX == 4`, `UI_PAGES.index.MAIN == 1`; the old `UI_PAGES.MAIN_PAGE` is gone, #393). `S.ui_page` is the index of the shown page.

Encoders and keys (`strata.lua`):
- `enc(1, d)` selects the page (`S.lib.ui_keys.set_ui_page(util.clamp(S.ui_page + d, 1, NUM_UI_PAGES))`), stopping at MAIN and SETUP. E1 does nothing else. `set_ui_page` does nothing when the page does not change; on a change it calls the old record's `leave()`, forgets every carried arc tick (`forget_arc_ticks()`, so ticks turned on one page never step a param on another), sets `S.ui_page` and calls the new one's `enter()`, if the records have them.
- At init a start step in `strata.lua` (`START_ORDER.e1_settings`) turns E1's acceleration off and sets its sensitivity to `E1_TICKS_PER_PAGE` (4) with `norns.enc.accel(1, false)` / `norns.enc.sens(1, ...)`, so a fast turn steps pages instead of skipping to SETUP. norns resets these on every script load, so cleanup restores nothing.
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
  - `layout_states`: an array of `{name, setup = function(context)}` the layout tests (`test/unit/ui_layout_test.lua`) and the page renders draw, each on a fresh script with the page shown.
- Optional, called by the shared ALT+K2 handler (`S.lib.ui_alt.k2_up` and `k2_hint`, from the page's own `alt_key_release` and `hints`), never by strata.lua: `randomize_section() -> spec or nil, reason` (set by MAIN, VOICE, SEQ, FX and LFO), `alt_hold()` (set by VOICE and LFO) and `alt_hold_hint` (3.4: a string or a function returning one, the held hint's text in place of `reset`). See `docs/notes/lua/ui/alt-and-keys.md`, ALT+K2 on the randomizing pages.
- Arc fields, set only by `lib/arc/<page>.lua`: `arc_delta(n, d)`, `arc_redraw(arc_port)`, `arc_alt_delta(n, d)`, `arc_alt_redraw(arc_port)` (`docs/notes/lua/arc-core.md`).
- Ownership: the page file sets every field but the arc fields; the arc file sets only those, on `S.registry.pages[UI_PAGES.index.<PAGE>]`. So a page and its rings never edit the same file. `strata.lua` includes every page file before every arc file.
- To add a page: add its name to `UI_PAGES` (`NUM_UI_PAGES` follows), write its file and record, include it from `strata.lua` with the other pages, and, if it has rings, an arc file like `lib/arc/fx.lua` included after the pages (`docs/notes/lua/arc-pages.md`). Every page in `UI_PAGES` already has its page file, and every page but SETUP (which has no rings) its arc file, so changing one adds no include.

`redraw()`:
- `screen.clear(); draw_header(); record.draw(); draw_hints(S.lib.ui_flash.text("hints") or record.hints(S.alt_held)); screen.update()`, with `record = S.registry.pages[S.ui_page]`, `record.draw` and the hint text computed in one function run through `S.lib.ui_frame.contained_call`. When it fails: `screen.clear(); draw_header(); draw_hints("draw error"); screen.update()` (`docs/notes/lua/ui/redraws.md`, Draw errors).
- Nothing before init's first start step (`S.started`).
- Except while the BUFFER page's file selector is open (`S.BUFFER_PAGE.file_selector_open`): then it calls `fileselect.redraw()` and returns, so neither norns' own `redraw()` calls nor Strata's frame clock draw the page over the file list (`docs/notes/lua/pages/buffer.md`).
- While a modal owner is pushed (after the file selector's check): the header, then `owner.draw()` and `draw_hints(owner.hints(S.alt_held))` (no hints function: an empty hint row), in the same contained function as the page's; no flash replaces the owner's hints.
- The hint row (`draw_hints(text)`: level 4, x=0, y=62) is drawn once, by `redraw()`: the "hints" flash while one shows (only on its owning page), else the record's hints.

## The modal owner

`lib/ui/modal.lua` (`S.lib.ui_modal`, 3.4, design §0.1): a stack of screen owners for a view that takes the screen and the controls from the page until it closes (3.4's step editor, §8.7; the scene name entry has none, since norns' `textentry` takes the keys itself).
- `push(owner)` puts an owner on top and requests a redraw; `pop(owner)` takes it off wherever it is (an owner not on the stack: nothing); `top()` is the owner the input goes to, or nil; `key(n, z)` is strata.lua's K2/K3 while one is pushed. An owner already on the stack, or one without a `draw` function, is an error.
- An owner is `{draw = fn(), hints = fn(alt_held) -> string, enc = fn(n, d), key = fn(n, z), arc_delta = fn(n, d), arc_key = fn(n, z), arc_redraw = fn(arc_port)}`; only `draw` is required, and a missing handler ignores its input (an owner without `arc_redraw` leaves the rings off).
- While one is pushed: `enc` ignores E1 and sends E2 and E3 to `owner.enc(n, d)` (never the page's `alt_enc` or `enc`); `key` sets ALT from K1 as always, clears the key's page press marks and hands K2 and K3 to `S.lib.ui_modal.key(n, z)` (never `alt_action`, `key_release` or `alt_key_release`), which sends a press to the top owner's `key(n, 1)`, noting which owner it went to, and a release to `key(n, 0)` only when that owner is still the top one and saw the press (a pop forgets its owner's presses); `redraw` draws the header, the owner's body and hints; `arc_delta`, `arc_key` (presses and releases) and `arc_redraw` (`lib/arc/core.lua`) go to the owner's handlers. A page change made elsewhere (the grid) still changes the header's page underneath.
- The `modal owner` invariant: no owner is on the stack twice, and every key down on an owner is on one that is pushed.

## Registering a page

- **Registering a page**: a new `lib/pages/<name>.lua` creates its record at `S.registry.pages[UI_PAGES.index.<NAME>]` and sets every field but the four arc fields. Add the name to `UI_PAGES` in `lib/constants.lua` (one line; `NUM_UI_PAGES` is `#UI_PAGES` and `UI_PAGES.index` follows) and its `include` to `strata.lua` among the page includes (one line). Its rings, if any, go in a `lib/arc/<name>.lua`, included after every page file, that sets only `arc_delta`, `arc_redraw`, `arc_alt_delta` and `arc_alt_redraw` on the record. So a page package and the arc package never edit the same file. Every page in `UI_PAGES` already has its page file, and every page but SETUP its arc file. A page's own files are its `lib/pages/<name>.lua`, `docs/user/pages/<name>.md`, `docs/notes/lua/pages/<name>.md` and `test/unit/pages_<name>_test.lua`; the arc's page rings are `lib/arc/<name>.lua`, `docs/notes/lua/arc-pages.md` and `test/unit/arc_pages_test.lua`; a grid layout's are `lib/grid/layout_<size>.lua`, `docs/user/grid/<size>.md`, `docs/notes/lua/grid/layout_<size>.md` and `test/unit/grid_layout_<size>_test.lua`. A page adds layout-test states only through its record's `layout_states`.
