### Fixed
- A held extra note on a buffer or the input keeps its pitch when the voice's root moves (a source switch to a slot whose file has another key, or a change of that key), where it played off its pitch by the difference until it was struck again; no note is struck again (#958).
