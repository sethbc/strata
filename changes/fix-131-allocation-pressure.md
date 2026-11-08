### Fixed
- Saving a buffer is several times faster and puts far less load on SuperCollider's memory manager, which can crash under heavy load (most of all on norns' SuperCollider 3.13); saved files are unchanged.
