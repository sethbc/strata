### Fixed
- A dub (a recording with feedback or loop) over a long file that is canceled while armed keeps the file's start, so the slot's start field still works and the next launch loads the same region; a dub that ends becomes `take <n>` read from its start (#244).
