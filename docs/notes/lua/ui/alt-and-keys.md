## Must not break

- A key release acts only on the page where the key went down (`S.key_press_page`). Keys held while the norns menu opens are forgotten, and so are keys held across a page change: `set_ui_page` clears `S.key_press_page` and `S.key_press_alt` (not `S.alt_held`, K1 is still down) and runs no ALT-release hook, so a K2 or K3 held out of a page and back does nothing when it comes up (#234).
- Every ALT+K2/ALT+K3 action goes through `alt_action(page, n)`, never a direct `alt_key` call; the one exception is BUFFER's ALT+K2 and ALT+K3, which act on release in `alt_key_release`, by how long they were held, while their `alt_key` only notes the press (`docs/notes/lua/pages/buffer.md`). A key pressed with ALT releases through `alt_key_release`, never `key_release`, even when K1 comes up first (on BUFFER, an ALT+K2 release must never open the file selector). `forget_held_keys` clears `S.alt_held` and `S.key_press_alt`. When ALT goes from held to not held (`S.lib.ui_alt.set(false)`, `forget_held_keys`), the `S.registry.alt_release` hooks run (`S.register_alt_release`).
- `unwatch_menu_opening()` puts `_menu.set_mode` back only if it is still Strata's wrapper; otherwise Strata's wrapper becomes a pass-through.
- The menu watch's wrapper never lets a failure stop the menu closing: the file selector release and each `S.registry.menu_close` hook run in their own `pcall`, and it calls only upvalues (no script-global lookup).

## States

The fields: `S.key_press_page[n]` (the page key `n` went down on, nil when up), `S.key_press_alt[n]` (true for an ALT press) and `S.alt_held` (K1 held). The "key presses" invariant checks that an ALT press has a press page.

| Per key (2, 3) | `key_press_page[n]` | `key_press_alt[n]` |
|----------------|---------------------|--------------------|
| up | nil | nil |
| down, plain | the page | nil |
| down, ALT | the page | true |

Legal: any of the three per key, with `S.alt_held` either way (K1 may come up before the key). A page change takes a key to up (its marks forgotten) while the physical key is still down, so its release then does nothing. Never an ALT press without a press page.

Transitions, one function each:
- `key(n, 1)` and `key(n, 0)` in `strata.lua`: up to down (plain or ALT by `S.alt_held`) and back to up.
- `S.lib.ui_keys.set_ui_page`: every key to up, `S.alt_held` untouched.
- `forget_held_keys`: every key to up and `S.alt_held` false, running the ALT-release hooks if ALT was held.

## ALT

`lib/ui/alt.lua` (`S.lib.ui_alt`). ALT is K1 held: norns delivers K1 to a script only after `KEY1_HOLD_TIME` (0.25 s, `lua/core/menu.lua`), and a shorter press opens the norns menu, so K1 is a hold-only key (3.1 design §2).
- `S.lib.ui_alt.set(held)` sets `S.alt_held` and requests a redraw (the hint row shows the page's ALT layer, `record.hints(true)`, and the arc switches to its ALT rings). `key(1, z)` calls it.
- `alt_action(page, n)` (global) runs `S.registry.pages[page].alt_key(n)` and returns true, or returns false and does nothing when `n` is not 2 or 3, `page` is not a page index, or the record has no `alt_key`. It takes the page as an argument, so a caller can name a page that is not showing.
- `key(n, 1)` with ALT held records the key's page (`S.key_press_page[n]`), marks it an ALT press (`S.key_press_alt[n] = true`) and calls `alt_action(S.ui_page, n)`; the record's `key` never runs. Without ALT it clears the mark and calls `key(n)`. A page without `alt_key` ignores ALT+K2/ALT+K3: they never fall through to `key`.
- `key(n, 0)` clears both marks and, if the key went down on the page still showing, calls `alt_key_release(n)` for an ALT press and `key_release(n)` otherwise (each only if the record has it). The press decides, not the state of K1 at release: K1 down, K2 down, K1 up, K2 up releases through `alt_key_release`, so BUFFER's K2 release never opens the file selector after an ALT+K2; K2 down, K1 down, K2 up releases through `key_release`.
- `enc(2|3, d)` with ALT held calls `alt_enc(n, d)` first; when the record has none or it returns false or nil (not handled), `enc(n, d)` runs. `enc(1, d)` steps the page with or without ALT and never reaches the record.
- `forget_held_keys` (as the norns menu or the file selector takes the keys) clears `S.alt_held` and every `S.key_press_alt` mark with `S.key_press_page`.

K1 held as ALT is confirmed on hardware, so the design's long-press fallback (§2: a 0.6 s hold of K2 or K3) was never wired, and 3.1's unused hook for it is gone.

## Key releases and the norns menu

Releases:
- `key(n, 1)` records `S.key_press_page[n] = S.ui_page`.
- `key(n, 0)` clears it and calls the page record's `key_release(n)` (or `alt_key_release(n)` for an ALT press, ALT above) only if the key went down on the page still shown, so a key held across a page change does nothing when released.
- Only BUFFER has a `key_release` today; on every other page releases do nothing.
- "K2 is held on this page" is `S.key_press_page[2] == S.ui_page`.

Keys held into the menu:
- The norns menu (K1, PARAMS, its file selector) takes every key while open (`_menu.key` is the menu's handler), so a key released there never reaches `key()`.
- `forget_keys_held_through_menu()`, called at the end of `drift_update` (the 10 Hz `S.drift_metro` tick), clears `S.key_press_page`, `S.key_press_alt` and `S.alt_held` whenever `norns.menu.status()` is true.
- Without it, a key released in the menu would stay held on the page it went down on.
- It also runs the moment the menu opens. Every way into the menu (K1, a script error, a keyboard's menu key) calls `_menu.set_mode(true)`, which `lua/core/menu.lua` and `keyboard.lua` look up on `_menu` at each call.
- So `watch_menu_opening()` (from its start step, `START_ORDER.menu_watch`) wraps it in `menu_watch.wrapper`: call norns' function, then `forget_keys_held_through_menu()` when `mode == true`.
- The wrapper holds norns' function, `forget_keys_held_through_menu`, `release_superseded_file_selector` and the `S.registry.menu_close` list as upvalues (no script-global lookup).
- As the menu closes (`mode == false`, while the watch is active), after norns' `set_mode(false)` returns, the wrapper runs each `S.registry.menu_close` hook (`S.register_menu_close(fn)`) in order, each in its own `pcall`: a hook that fails prints `strata: menu close hook failed: <error>`, and the next hook still runs and the menu still closes. The list is read when the wrapper is built (the `menu_watch` start step), so hooks register at include time (or in a test's `before_init`). The hooks today: `S.lib.grid_core.reconcile_ports` and `S.lib.arc_core.reconcile`, since SYSTEM > DEVICES moves a grid or arc to another port with no `add` or `remove` (`docs/notes/lua/grid-core.md`, `docs/notes/lua/arc-core.md`).
- `unwatch_menu_opening()`, cleanup's second step (after the tempo handler, before anything that can fail), puts `menu_watch.original_set_mode` back only if `_menu.set_mode` is still Strata's wrapper. Otherwise (something wrapped it later) it leaves that wrapper in place and turns Strata's into a pass-through (`menu_watch.active = false`).
- The 10 Hz tick stays as a fallback.
- norns has no key-state query.
- A file selector opened from play mode, as BUFFER K2 does, keeps `norns.menu.status()` false and takes the keys through the global `key`. It opens on K2's release, so only a K3 or K1 (ALT) held at that moment can be released there. `buffer_key_release` therefore calls `forget_held_keys()` just before `fileselect.enter`. `forget_held_keys` is a global: it clears `S.key_press_page`, `S.key_press_alt` and `S.alt_held`, and is also the body of `forget_keys_held_through_menu`.
