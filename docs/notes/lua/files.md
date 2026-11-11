## Must not break

- Every random or fill load is `load_buffer(slot, path, 0)`: a new file starts at 0.
- Not recursive: only the files `list_folder(folder)` lists in the one folder, by extension (`.wav`, `.aif`, `.aiff`, `.flac`, `.ogg`, case-insensitive), never a folder (`ls -p` marks it with a trailing `/`) or a dot file.
- A folder reaches the shell only as one single-quoted word after `--` (`shell_quote`, each `'` written `'\''`), in `ls -pL`, never through `util.scandir`, which puts it between double quotes where `"`, `$`, a backtick and `\` still act (#465; a structure test forbids `util.scandir`). A folder that is not an absolute path or does not exist cannot be listed: `cannot open <folder>`, apart from `no files in <folder>` for one with no sound file.
- **The flashes name a folder as the player knows it, never by its absolute path** (#432): `/home/we/dust/audio/` alone fills the hint row, so the folder searched never showed. `flash_no_files` shows its path below `_path.audio` (`tape/`, `drums/kicks/`) when the flash fits the hint row whole (`S.lib.ui_header.hint_fits`), else the folder's own name, its last component (`another_one/`); `_path.audio` itself is `audio/` and a folder elsewhere its own name (`samples/`). So the folder's own name is always on screen.
- `random_into` never picks the slot's current file when the folder holds another; `fill_empty` gives each free slot a distinct file and stops when the files run out. A slot is free only by `S.lib.buffers.is_free(slot)` (status `"empty"` or `"missing"`, `docs/notes/lua/buffers.md`, States), never by a test of its own, so a slot that records, is armed, finishes, loads, holds audio or holds a named load the engine has not reported yet (`"unsettled"`, #247) is never overwritten.
- `random_into` checks its slot only through `S.lib.buffers.slot_index` (lib/buffers.lua's one slot check, #402): anything but a whole number from 1 to `NUM_BUFFERS` loads nothing and returns false.
- The module is a constructor ending with `  return M` and `end`; its table is `S.lib.files`.

## Owns

`lib/files.lua`: the audio folder and the sample files BUFFER fills slots from.
- `folder_for(slot)`: the folder of the slot's file, else `last_folder` (the folder `note_chosen` last saw, kept for the session), else `_path.audio`. A recorded take's scratch file counts as no file (its folder is not a library). Folders end in `/`.
- `note_chosen(path)`: BUFFER's file selector calls it with the file the user chose.
- `random_into(slot)`: a random file from `folder_for(slot)` through `load_buffer`; flashes `buf <n>: <name>` (the hint row draws a name with accented letters plainly, `S.lib.ui_text.printable`, #551; the file loads by its real name), or `no files in <folder>` / `cannot open <folder>` (the folder as above) and returns false.
- `fill_empty()`: fills the free slots (`S.lib.buffers.is_free`) from the folder of the BUFFER page's cursor slot (`S.buffer_page.slot`); flashes `filled <k> slots` (`filled 1 slot` for one, #512; `no files in <folder>` or `cannot open <folder>` when there are none) and returns k. A file another slot already holds is never given again; with fewer files left than empty slots, the rest stay empty.
- The flashes go through `buffer_page_flash`, so they show only while BUFFER is up.
- The start point of a long file and saving the loop region are `lib/buffers.lua`'s (`docs/notes/lua/buffers.md`).
