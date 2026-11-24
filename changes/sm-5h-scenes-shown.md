### Changed
- SCENES' sequencer field reads `seq on [none]` while the scene sequencer is on with no scene it can play in its length (it holds a slot and recalls nothing), instead of a plain `seq on`.
- The factory sets list keeps its `K3 again: drop unsaved` prompt on the hint row for the whole 2 seconds the second K3 has, even when another message arrives meanwhile.
- The scenes page of the manual says that no key stops a crossfade where it is, and how to leave one.

### Fixed
- A scene crossfade that started from a sound the morph set, and was then stopped partway (by the scene sequencer or by loading scenes from disk), no longer leaves part of the crossfade's values behind when the morph moves again: the morph sets every value for its position.
