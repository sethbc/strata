### Fixed

- A burst of buffer saves now keeps each accepted filename reserved until the engine reports its result. BUFFER and PARAMETERS show `save queue full` when a slot is waiting on the oldest of four requests. Other slots can still save.
