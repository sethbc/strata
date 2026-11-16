# crow

monome crow on norns' USB: its two inputs move Strata's modulation or fire an action, and its four outputs carry Strata's modulation, a voice's pitch or gate, or the clock out to a modular. Back to [IO](../pages/io.md).

Everything starts off. Until you set an input or an output, Strata sends crow nothing, and with crow unplugged it sends nothing at all and keeps your settings. When crow is plugged in (again), Strata resets it, as norns does, then sets each jack up from the current settings.

Built from crow's firmware v4.0.5-4 and its reference (monome's crow documentation, https://monome.org/docs/crow/reference/), and from norns' `lua/core/crow.lua`. It is unverified on the device until the 4.0 hardware check.

## On the IO page

The `crow` section shows `[--]` on its title line while no crow is connected. It has one row per jack: `in 1`, `in 2`, `out 1` to `out 4`, each showing what the jack does. K3 on a row opens its settings (E2 picks one, E3 changes it, K2 closes the list). The same settings are in PARAMETERS > crow, and they are saved with a PSET, not with a scene.

## Inputs

Each input has a **mode**:
- **off** - nothing
- **cv** - the input is a modulation source, `CR1` or `CR2` in MOD's `crow` section, over its **range** (`-5..5`, `0..5` or `0..10` V): route it in the matrix like any other source. crow reads it 50 times a second
- **trigger** - each rise past 1 V runs the input's **action** on its **voice** (`sel` is the selected voice):
  - **retrigger** - accents the voice if it is running (it never starts a stopped one)
  - **next scene** - recalls the next saved scene, quantized as a scene key is
  - **freeze** - turns the voice's freeze on or off
  - **record** - starts or stops recording on BUFFER's slot, as BUFFER's K3 does
  - **patterns** - starts or stops the patterns
  - **fill** - turns fill on or off ([Fill](../sequencer.md#fill)); a trigger toggles it, it cannot hold it

## Outputs

Each output has a **source**, a **range** (`0..5`, `0..10` or `-5..5` V) and a **div**:
- **off** - 0 V
- **a modulation source** (`lfo1`, `macro3`, `pressure2`, `crow1`, ... the sources MOD lists) - the output follows it across its range, smoothed over 20 ms. An LFO that runs in the engine (its destination shows `~` on the LFO page) is followed as Strata's own model of it, so the output shows `~` too: in step with a clocked LFO, drifting slowly from a free one, and the random shapes draw their own values
- **v1 pitch** to **v7 pitch** - the voice's newest note, at 1 V an octave with MIDI note 60 (middle C) at 0 V, kept inside the range
- **v1 gate** to **v7 gate** - 5 V while the voice has a note sounding, 0 V when the last one ends. Choosing a gate source sets the jack at once: 5 V when that voice sounds, otherwise 0 V, so a gate moved off a sounding voice never stays high
- **clock** - a 10 ms pulse of 5 V every **div** beats (`1/16` to `4`, default `1`) of norns' clock

A PSET keeps each output's source by its name, so a later release that adds modulation sources still loads it on the same source; a source a PSET names that this Strata does not have leaves the output off until one that has it loads the PSET.

A voice's pitch and gate come from its steps and the notes you play on it, one note at a time: when the newest note ends and others still sound, the pitch goes back to the newest of them. A step's gate ends just before the next step, so consecutive steps retrigger; at very fast ratchets the low can fall in the same tick as the next high.

## norns' own crow clock

norns can take crow for its clock (PARAMETERS > CLOCK: source `crow` uses input 1, `crow out` uses an output). Strata leaves those jacks alone: their rows read `in 1  clock (norns)` or `out 2  clock (norns)`, and their settings wait until norns gives the jack back.

## Limits

Strata sends crow at most 32 lines each tenth of a second. Notes, gates, triggers and clock pulses always go at once; when an output's followed value has to wait, its newest value goes in the next tenth of a second.

## Sources

crow's firmware v4.0.5-4 and its reference, and norns' `lua/core/crow.lua`. Unverified on the device until the 4.0 hardware check.
