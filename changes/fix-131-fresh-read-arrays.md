### Fixed
- Loading and saving long buffers no longer risks crashing SuperCollider on norns: each chunk of a file is read into a new array, as SuperCollider 3.13 needs.
