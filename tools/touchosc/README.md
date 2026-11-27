# TouchOSC layouts

`lib/layout.lua` describes Strata's two TouchOSC layouts as one Lua table (the params they use, Strata's own OSC addresses, and a tablet and a phone layout of three pages: macros, voices, scenes and patterns). `generate.py` turns it into `extras/touchosc/strata-tablet.tosc` and `extras/touchosc/strata-phone.tosc`, which are committed.

## Run it

From the repository root:

    python3 tools/touchosc/generate.py

It needs Python 3 (standard library only, no packages) and `lua` or `luajit` on the PATH, which reads `lib/layout.lua`. The generator prints each file's size, decompressed size and node count. Run it again after changing `lib/layout.lua` and commit both files. The output is the same bytes every run: a node's ID is a uuid5 of its path in the layout (layout name, page, control), and the compression level is fixed.

To check that the committed files match `lib/layout.lua` without writing anything:

    python3 tools/touchosc/generate.py --check

It regenerates both files in memory and exits non-zero, naming the file, when one differs.

## What is verified

`test/unit/io_osc_test.lua` checks every param and address in `lib/layout.lua` against Strata's params and OSC addresses, and that both files exist. CI checks byte-for-byte regeneration and runs `python3 tools/touchosc/test_startup.py`. The latter verifies both committed panels against the generator before exercising their root callbacks. It checks the startup request on connection 1 and the display of incoming scene reports without a second recall.

The file format is unofficial. A `.tosc` file is zlib-compressed XML (`<lexml version="3">`, one root group holding a pager of page groups); the generator writes it as the tosclib library does (`docs/design/3.6-facts/checks.md`, section 5). Hexler publishes no schema, and **no file has been opened in TouchOSC** here: whether TouchOSC accepts them is unverified until the 4.0 hardware check. If one does not open, the connection settings and the addresses in `lib/layout.lua` are still correct and the controls can be built by hand in the editor.
