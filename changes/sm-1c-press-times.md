### Fixed
- A screen key held while a grid's held step opens the step editor over the voice picker (or any other screen view) is now forgotten: a later K3 tap no longer opens an old slot's name entry, and the picker's hint no longer stays on `K2:hold` or keeps redrawing with no key held (#866).
- A K2 held on a page when the step editor opened over it no longer acts at its release after the editor closed (on BUFFER it no longer clears the slot or opens the file selector).
