### Fixed
- A TELEXo output set to envelope mode while the ii bus was flooded is set up at the next TELEXo change instead of being taken as set up with none of its setup sent (#871).
- crow's clock outputs, the controllers' echo, the remote grid's and arc's drawing, OSC feedback and nb's player activation no longer print `bad argument #1 to 'resume'` when stopped just as their clock wakes (#870).
