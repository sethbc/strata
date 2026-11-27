### Fixed

- Starting the pattern chain keeps live pattern edits undoable when the saved order begins on another letter.
- A local recall sends its MIDI program change even when an incoming program change is waiting to recall the same scene.
- Loading a scene bank or preset cancels a pending quantized scene recall.
- An instant recall refreshes each attached grid once, including when only part of the scene could be applied.
