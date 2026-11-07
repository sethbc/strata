### Fixed

- A start that failed before loading the saved scenes and buffer paths (the engine did not load, or an error earlier in `init`) no longer lets `cleanup()` overwrite `scenes.data` and `buffers.data` with empty state. Cleanup also no longer stops on the missing params and LFOs after such a start (#72).
