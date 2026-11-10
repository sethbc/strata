## Must not break

- Every random or fill load is `load_buffer(slot, path, 0)`: a new file starts at 0.
- Not recursive: only the files `util.scandir(folder)` lists in the one folder, by extension (`.wav`, `.aif`, `.aiff`, `.flac`, `.ogg`, case-insensitive), never a folder (`ls -p` marks it with a trailing `/`) or a dot file.
- `random_into` never picks the slot's current file when the folder holds another; `fill_empty` gives each free slot a distinct file and stops when the files run out. A slot is free only by `S.lib.buffers.is_free(slot)` (status `"empty"` or `"missing"`, `docs/notes/lua/buffers.md`, States), never by a test of its own, so a slot that records, is armed, finishes, loads, holds audio or holds a named load the engine has not reported yet (`"unsettled"`, #247) is never overwritten.
- The module is a constructor ending with `  return M` and `end`; its table is `S.lib.files`.

## Owns

`lib/files.lua`: the audio folder and the sample files BUFFER fills slots from.
- `folder_for(slot)`: the folder of the slot's file, else `last_folder` (the folder `note_chosen` last saw, kept for the session), else `_path.audio`. A recorded take's scratch file counts as no file (its folder is not a library). Folders end in `/`.
- `note_chosen(path)`: BUFFER's file selector calls it with the file the user chose.
- `random_into(slot)`: a random file from `folder_for(slot)` through `load_buffer`; flashes `buf <n>: <name>`, or `no files in <folder>` and returns false.
- `fill_empty()`: fills the free slots (`S.lib.buffers.is_free`) from the folder of the BUFFER page's cursor slot (`S.buffer_page.slot`); flashes `filled <k> slots` (`no files in <folder>` when there are none) and returns k. A file another slot already holds is never given again; with fewer files left than empty slots, the rest stay empty.
- The flashes go through `buffer_page_flash`, so they show only while BUFFER is up.
- The start point of a long file and saving the loop region are `lib/buffers.lua`'s (`docs/notes/lua/buffers.md`).
