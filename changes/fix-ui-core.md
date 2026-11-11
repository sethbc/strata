### Fixed
- An error in a page's animation check (BUFFER, SCENES, LFO, SEQ) is printed once and no longer stops the screen and the arc drawing for the rest of the session (#320).
- A page whose drawing fails now shows its title and `draw error` on the hint row instead of leaving the previous page on screen while the keys act on the new one; the error is printed once (#424).
- Opening the norns menu no longer fails when an ALT-release step fails, and the grid, arc and MIDI ports are still checked as the menu closes when the screen's redraw fails (#425).
- Tapping K1 while the engine loads no longer raises errors, and keys and encoders used meanwhile do nothing (E2 no longer leaves another voice selected when the script comes up) (#426).
- A file or folder name the screen cannot shorten no longer hangs the interface (#514).
