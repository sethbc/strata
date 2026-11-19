## Must not break

- **One piece opens norns' textentry for Strata** (#849): SCENES' slot names (`lib/pages/scenes.lua`) and the voice picker's preset names (`lib/ui/voice_picker.lua`) each hold an entry from `S.lib.ui_name_entry.new(on_close)`; neither keeps a copy of the takeover or the reconcile. A fix to the entry is made here once. `lib/ui/name_entry.lua` is the one file besides `strata.lua` (and `lib/pages/buffer.lua`'s file selector, for `key` and `enc`) that writes the globals `key`, `enc` and `redraw` (`test/unit/structure_test.lua`'s allowance).
- **It opens on a key's release, after `forget_held_keys()`**: the entry takes every key while open and cancels on a K2 release, so a caller opens it on the release of the key that asks for it (SCENES' ALT+K2, the picker's ALT+K3), and `open` forgets the held keys and ALT first (K1's release goes to the entry, so ALT must not stay held after it).
- **A callback that is no longer the open entry's does nothing**: each `open` makes a fresh callback, and only the one the entry keeps closes it and hands the text on (`done(text)`; a cancel's nil hands nothing).
- **Each reconcile acts only on its own entry**: a caller runs its entry's `reconcile()` from its own `S.register_menu_close` hook. While the entry is open, a `textentry.callback` that is not its own means the menu's entry (a PSET name, a text param) took the one textentry over: Strata's key and enc (kept as it opened) go back in the globals, the entry closes (its `on_close` runs) and `norns.menu.init()` routes play mode to them, since norns' `set_mode(false)` copied the entry's handlers before the hook ran. Its own callback while the global `key` is the entry's means the menu came and went over it: `set_mode(false)` put Strata's redraw back and drew the page, so `reconcile` puts `norns.none` in `redraw` again (as `textentry.enter` does) and draws the entry. The entry's own enter, from play mode, runs that second branch on every open (harmless: it does early what enter does next); its exit runs neither.

## lib/ui/name_entry.lua (`S.lib.ui_name_entry`)

Included after `lib/ui/menu_watch.lua`, before the voice picker and SCENES. One field: `new(on_close)`, which returns an entry:

- `open(text, heading, done)`: `forget_held_keys()`, then the entry keeps its callback and Strata's key and enc, then `textentry.enter(callback, text, heading)` (no `check`: a caller cuts a long name where it keeps it). A typed text goes to `done(text)` once the entry has closed.
- `is_open()`: whether the entry holds a callback (from `open` until it calls back or `reconcile` forgets it).
- `reconcile()`: the menu-close step above; nothing while closed.
- `on_close` (optional) runs whenever the entry closes, before `done`: SCENES clears `S.scenes_page.naming` there.

The callers: SCENES (`docs/notes/lua/pages/scenes.md`, the slot's name, heading `scene <n> name`) and the voice picker (`docs/notes/lua/ui/voice-picker.md`, the slot's preset name, heading `preset <nn> name`), whose menu-close hook first forgets an ALT+K2 or ALT+K3 press the menu took.

Tests: `test/unit/ui_name_entry_test.lua` (the text, heading and done; a cancel; a menu takeover forgotten by its own reconcile and left alone by another entry's; the menu come and gone handing the entry the screen back), through `test/stub_textentry.lua` (`docs/notes/test-harness/stubs.md`); the callers' own in `test/unit/pages_scenes_test.lua` and `test/unit/ui_voice_picker_test.lua`.
