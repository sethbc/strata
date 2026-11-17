### Changed
- Scenes files saved before this version (Strata 3.7 and earlier) are not converted: on the first start they are set aside whole as `scenes.data.bak` (the next free `.bak` name), and the hint row and SETUP show them as older (`scenes older (SETUP)`, `scenes older, kept`), not unreadable. The next scene save writes the new format. The lock ([L]) works as before.
