### Fixed
- A buffer voice's scan held by both a grid's hold key and the arc (ALT ring 1 on BUFFER), or by two grids, now stays held until the last of them lets go, and a hold key released on a grid that holds nothing no longer ends another's hold.
- The grid's hold key lights only while the voice's scan is actually held: it goes dim when a voice restart ends the hold, and stays dim for a voice that does not read a buffer.
- With ALT held on BUFFER, ring 1 holds the scan again after the voice restarts.
