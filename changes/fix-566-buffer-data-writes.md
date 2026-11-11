### Fixed
- The saved buffer paths are written once, 0.1 s after the last change, instead of inside each engine report, so filling several slots at once no longer stalls the script on file writes.
