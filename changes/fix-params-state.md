### Changed
- Grain size, decay, mod speed, excite and the wobble rates show their units (s, Hz) in the PARAMS menu and on VOICE, grain density shows /s and grain pitch x; the Sub and FM drift, the FM ratio and the tape drift show three decimals, so every encoder step changes the text.
- The voice delay and reverb sends show as a percent (100 %) on VOICE and in the PARAMS menu; their values are unchanged.
- The PARAMS menu headings above the mutations and scenes params read "mutations" and "scenes".

### Fixed
- A module that registers voice params, scene fields, LFO destinations, fx params, start steps or menu-close hooks after init now gets an error naming the registry, not a record that is silently never used; a record with a misspelled field is refused, naming the field.
