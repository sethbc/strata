### Fixed
- Test harness: an error the script catches and prints (a frame draw, a playhead tick, a menu-close hook, a sequenced recall) now fails the test that leaves it, unless the test claims it (#473).
- Test harness: the screen stub records a path at the level it is stroked or filled with, checks the screen calls' arguments as matron does, and measures text with norns' font advances; the grid stub takes integer coordinates and levels, with `rel` (#474, #475, #476, #479).
- Test harness: the engine stub refuses a NaN or infinite argument, and reads each command's limits from its own function only (#477, #487).
- Test harness: the params stub keeps indices in `lookup`, returns nothing from `add`, and wraps a wrapping control on `set`; `util.make_dir`, `fileselect.enter` and `metro.init` refuse what norns refuses; `_menu.set_mode` swaps the handlers and redraws as norns does (#478, #481, #521).
- Test harness: `find_upvalue` raises for a name with different values; the runner fails a run or unit file with no test and removes its temporary folder on every way out (#482, #483, #484).
- Test harness: the recursive-delete scan catches every rm flag order, `find -delete`, `git clean` and `rsync --delete` (and reads the Dockerfile); the docs check reads links with an `#anchor` and backticked `changes/` and root files (#488, #489).
