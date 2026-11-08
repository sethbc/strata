### Fixed
- A scene file edited by hand with a loop that runs past the end of the buffer (a length longer than its start leaves room for) is shortened to fit when the scenes load, so recalling it, with or without a fade, ends on a loop the VOICE page can show. The VOICE page's documentation now lists the loop rows.
