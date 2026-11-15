# TouchOSC layouts

`layout.lua` describes Strata's two TouchOSC layouts as one Lua table (the params they use, Strata's own OSC addresses, and a tablet and a phone layout of three pages: macros, voices, scenes and patterns). `generate.py` turns it into `extras/touchosc/strata-tablet.tosc` and `extras/touchosc/strata-phone.tosc`, which are committed.

## Run it

From the repository root:

    python3 tools/touchosc/generate.py

It needs Python 3 (standard library only, no packages) and `lua` or `luajit` on the PATH, which reads `layout.lua`. It is run on demand, never by the tests, and prints each file's size, decompressed size and node count. Run it again after changing `layout.lua` and commit both files. (A new run changes the files' bytes, because every control gets a fresh random ID.)

## What is verified

`test/unit/io_osc_test.lua` checks every param and address in `layout.lua` against Strata's params and OSC addresses, and that both files exist.

The file format is unofficial. A `.tosc` file is zlib-compressed XML (`<lexml version="3">`, one root group holding a pager of page groups); the generator writes it as the tosclib library does (`docs/design/3.6-facts/checks.md`, section 5). Hexler publishes no schema, and **no file has been opened in TouchOSC** here: whether TouchOSC accepts them is unverified until the 4.0 hardware check. If one does not open, the connection settings and the addresses in `layout.lua` are still correct and the controls can be built by hand in the editor.
