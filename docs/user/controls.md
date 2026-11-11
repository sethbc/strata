# Screen Controls

The screen pages, and what the encoders and keys do on every page. Back to the [README](../../README.md).

## Screen Pages

The screen has eight pages, in this order (each page's own controls are on its page):

1. [MAIN](pages/main.md) - the voice list and the selected voice's main parameter. ALT+K2 randomizes the voice when you let go of K2 (again within 5 s to undo), ALT+K3 locks it
2. [VOICE](pages/voice.md) - every parameter of the selected voice, in six sections (seven for a buffer voice). ALT+K2 resets the row to its default, ALT+K3 locks the voice
3. [SEQ](pages/seq.md) - the pattern sequencer: all seven patterns, transport and tempo. ALT+E2 picks the voice row, ALT+E3 sets the tempo, ALT+K2 clears the voice's pattern, ALT+K3 randomizes it
4. [FX](pages/fx.md) - master density, tape drift, filter, delay and reverb. No ALT actions of its own
5. [LFO](pages/lfo.md) - the three LFOs. ALT+E3 jumps a destination group (or refines the rate), ALT+K2 resets the setting, ALT+K3 turns the LFO on or off
6. [BUFFER](pages/buffer.md) - voice sources and the eight sample buffers. ALT+E2 moves the field cursor, ALT+K2 clears the buffer, ALT+K3 saves it
7. [SCENES](pages/scenes.md) - the eight scenes and the scene sequencer. ALT+K3 saves the current sound into the slot
8. [SETUP](pages/setup.md) - connected devices, MIDI input, saving scenes. No ALT actions of its own

E2, E3, K2 and K3 do something different on each page. The arc follows the page too (see [Monome Arc](arc.md)); its rings are off only on SETUP.

## E1

- **E1** - Select the page (turn left toward MAIN, right toward SETUP; one page per short turn, without acceleration, stopping at MAIN and SETUP)

Master density is no longer on E1: adjust it on the first row of the FX page, with arc ring 1 on the MAIN page, or in PARAMETERS.

## The Header and the Hint Row

Every page shows at the top the page name, eight small dots for the pages (the current one bright), `[M]` while mutations run, a small play triangle while the patterns play, `REC` while a buffer records (`ARM` while one only waits for a beat, a bar or a level to start), and the `S1`-`S8` scene indicator (brighter while the scene sequencer runs). The scene shows once one has been recalled, not when one is saved. SEQ shows the tempo (`120 bpm`) at all times in place of `[M]` and `REC`/`ARM`. The header no longer shows master density. A changed value can take the dots' and indicators' place in the header for 1.5 s.

The bottom row shows the page's key hints. A short message (a saved buffer, a failed load, ...) can take it for 1.5 s, on the page that raised it.

`draw error` on the hint row, under the page's name, means the page failed to draw: a bug in Strata. The keys and encoders still act on the page named in the header, and maiden's console shows the error with its traceback (please report it). The page draws normally again once it stops failing.

## ALT (K1 held)

Hold K1 to use ALT. norns hands K1 to a script only once it has been held for a quarter of a second (a shorter press opens the norns menu), so ALT is always a hold.

- While K1 is held the hint row shows the page's ALT keys, and only keys that act: FX shows `E3:fine`, SETUP names no K3, and SCENES offers `K3:save` on a slot and no K3 on a field
- **ALT+K2** and **ALT+K3** take the page's ALT actions instead of K2's and K3's. Where a page has no ALT action for a key (FX, SETUP, and ALT+K2 on SCENES) they do nothing: they never run the plain K2 or K3 action
- On a page whose ALT+K2 randomizes, it acts when you let go of K2: a quick press (under half a second) randomizes, or within 5 seconds of a randomize there undoes it; a longer press does the page's hold action, if it has one. On a page without one, hold ALT+K2 and let go to cancel: the hint says `K2:cancel` after half a second, and letting go then does nothing. There is one undo: a randomize anywhere replaces it, so a quick ALT+K2 on another page randomizes that page
- A key pressed with K1 held stays an ALT press until it is released, even if K1 comes up first (on BUFFER such a K2 never opens the file browser)
- On BUFFER, while K2, ALT+K2 or ALT+K3 is held, the hint row says what letting go will do, and changes after half a second
- **ALT+E2** and **ALT+E3** take a page's ALT turns where it has them; elsewhere they act as E2 and E3 (E3 in fine steps, below)

## Fine Adjustment

**ALT+E3** moves a continuous value a tenth as far per detent as E3 alone (the MAIN parameter, the FX rows). Values in whole steps (sources, envelopes, LFO depths, MIDI settings) still step whole values. ALT+E2 and the arc are never fine.

## Center Detents

A value whose range runs through 0 (pan, buffer scan, the cross-modulation amounts) stops at exactly 0 when a turn reaches or crosses it, even on a fast turn, and holds there for up to a second: the next 3 encoder detents or 24 arc ticks in that second stay at 0, and turning on past them, or after the second, leaves 0.
