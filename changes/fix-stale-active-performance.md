### Fixed
- When the engine cannot replace an old `performance_active.data` (a read-only data folder), it now runs the tier that file names, the one the script reads at start, and says the file must be removed by hand. Before, the engine ran standard while the script could show the high tier (#153).
