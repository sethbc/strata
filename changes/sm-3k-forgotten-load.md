### Fixed
- A long file's load that is still being checked on the high tier is no longer forgotten when four or more loads follow it: if its check then fails, the slot gives back what it held before instead of showing the check running on (#980).
