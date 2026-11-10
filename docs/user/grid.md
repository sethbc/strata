# Monome Grid

The supported grid sizes, the key gestures every layout shares, the pattern sequencer and multi-grid support. Back to the [README](../../README.md).

Strata includes comprehensive grid integration for pattern sequencing and parameter manipulation. Supports multiple grids simultaneously and adapts layout based on grid size.

The grid has no LFO controls (no layout has room for them); the LFOs live on the screen's LFO page, the arc's LFO page and in PARAMETERS.

## Supported Grid Sizes

Each size has its own layout:

- [16×16 (256)](grid/256.md) - Full featured layout with patterns, parameters, scenes, buffers and FX
- [16×8 (128 horizontal)](grid/128h.md) - Four pages: patterns, faders, scenes and sources (record and clear buffers), and a fifth for buffer positions
- [8×16 (128 vertical)](grid/128v.md) - Five pages: patterns, faders, scenes, sources and positions, laid out vertically; the key at (8,8) steps to the next page
- [8×8 (64)](grid/64.md) - Pattern sequencing, 8 steps per voice, one half of the 16 at a time: tap row 8 column 1 for play/stop, hold it to switch halves; columns 2-8 toggle voices 1-7; a third view shows the selected voice's positions

A grid of any other size stays dark.

## Holds and Two-Key Gestures

Strata knows which keys of each grid are held, so a key can act on a hold, and a second key can change what a held key does:

- **Setting a step's level** - hold a step key and press another key of the same voice: the held step's level becomes that key's share of 15 along the voice's steps (column 16 = 15, column 8 = 8, column 1 = 1; on the 8×8, column 8 = 15 and column 4 = 8; on the 8×16, down the voice's column). The second key does not toggle its own step. Press more keys while still holding to try other levels; with two steps held, the one pressed last gets the level. Clearing, randomizing or pasting the voice's pattern, recalling a scene or switching the 8×8's half ends the level setting: the next key turns its own step on or off
- **Hold to save a scene** - a scene save key (row 3 of the scene page on the 16×16 and 16×8, column 3 on the 8×16) saves only once held for half a second. The key lights up while you hold it; letting go sooner saves nothing, so a stray press never overwrites a scene
- Unplugging a grid (or leaving the script) while a key is held cancels its hold: nothing is saved

## Pattern Sequencer Features

- **16-step patterns** per voice (a 64-button grid shows steps 1-8 or 9-16, as you choose)
- **Per-voice patterns** - each voice has independent pattern
- **Real-time recording** - toggle steps while playing
- **Visual feedback** - the step that just played is highlighted (bright if active, dim if empty): the same step the SEQ page shows, until the next one plays
- **Tempo control** - 1-300 BPM, the range of norns' clock tempo (adjustable via grid or PARAMS)
- **Pattern operations** - clear, randomize per voice
- **Automatic voice triggering** - a step starts a voice that is off, and gives a running voice a short accent (Karplus re-plucks its string) without restarting it; a voice in triggered grain mode also fires one grain
- **Step level is velocity** - a step's brightness (1-15) sets how strong its accent is (a triggered grain carries that accent): level 15 is full, level 6 is 6/15. Steps set by hand are 15; randomized patterns use levels 8-15. Set a step's level with the two-key gesture above

## Multi-Grid Support

- Connect up to 4 grids simultaneously
- Each grid has its own page: one grid can show the patterns while another shows the scenes. Patterns, voices and everything else are shared
- Hot-plug support - connect/disconnect grids while running. A grid plugged in starts on page 1; unplugging a grid while a scene save key is held saves nothing
