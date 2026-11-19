### Fixed
- The scale and tuning editor's hint row shows only its own message (a refused tuning file's reason); a message from elsewhere, such as a scenes or buffers load's, no longer covers its keys (#843).
- The MPE and zones editor's hint row with K1 held names E3, which still turns the value (#844).
- VOICE draws `interval prob` dim while the voice's arpeggiator is on, since it is not used then (#845).
- A voice preset save that fails to write, while the presets file had damaged presets set aside for it, leaves `voices.data` as it was instead of leaving only its backup (#848).
- VOICE's preset row no longer names a preset after a PSET load or a scene recall has given the voice another sound, and the voice picker's hint row with K1 held on a voice row reads `E2:row` instead of nothing (#850).
- A factory set's load clears VOICE's preset row as a PSET load does, since the set gives every voice another sound (#861).
