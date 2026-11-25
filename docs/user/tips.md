# Usage Tips

Workflows for evolving textures, cross-modulation, performance, the grid's sequencer and mutations. Back to the [README](../../README.md).

## Creating Evolving Textures

- Start with 2-3 voices active
- Use ALT+K2 (hold K1, press K2) to randomize individual voices until you find interesting combinations; ALT+K2 again within 5 seconds undoes a randomize you don't like
- Lock voices you like with ALT+K3
- Adjust master density (FX page, the first row, E3; or arc ring 1, or PARAMETERS) to create movement
- Add reverb or delay on the FX page for more space

## Exploring Cross-Modulation

- On VOICE, turn K3 to the voice's crossmod section (or open the PARAMETERS menu and find the voice's cross-modulation section)
- Each voice has 3 modulation slots that can be independently configured:
  - **Slot 1**: Set "mod source 1" to another active voice (e.g., voice 2)
  - Adjust "amp mod 1" (0.5 to 1.5 is a good starting range for amplitude modulation)
  - Try "freq mod 1" for pitch variation (start subtle: 0.1 to 0.3)
  - **Slot 2**: Add a second modulation source to create complex interactions
  - **Slot 3**: Add a third source for even more intricate modulation networks
- Experiment with different multi-source routing combinations
- Create modulation networks (voice 1 → 2, voice 2 → 3, voice 3 → 1) for complex evolution
- Mix multiple sources on a single voice (e.g., voice 1 modulated by voices 2, 4, and 7)
- Use positive and negative modulation amounts to create push-pull relationships

## Performance Workflow

1. Build up layers by activating voices one at a time
2. Randomize unlocked voices to create variation (ALT+K2 on MAIN)
3. Use master density (FX page) for dynamic swells and fades
4. Lock/unlock voices to create structural changes (ALT+K3 on MAIN), and stop or start them with K3
5. Set up cross-modulation for interdependent voice relationships

## Recording and Playing Buffers

Everything here works from the norns alone.

1. On BUFFER, pick a buffer with E2 and a source on the `rec` field (the input, the master, or one voice), then press K3 to record into it. Press K3 again to stop early.
2. Set the selected voice's `v1`...`v7` field to the buffer (`buf 1` ... `buf 8`): its grains now read the recording. K2 loads a sound file instead.
3. Turn `fb` above 0% to overdub: the buffer keeps playing while each pass layers on the old audio. `loop` records over and over the same stretch until you stop it.
4. Save a sound you like into a SCENES slot (ALT+K3 on SCENES); K3 recalls it, K2 fades to it over the transition time.

## Playing the Sequencer from the Grid

- Tap three steps on a voice's line of the patterns page and press PL: in `pulse`, the default, the voice is heard on its steps and quiet between them. Raise its gate floor (SEQ's `floor` row) to let some of it through between steps
- For a voice that keeps sounding and changes at each step, open the patterns page's side 2 (press its page key again), pick the voice (V1-V7) and press MV: every set step without a value A gets a random one, which moves the voice's position on a buffer voice and its pitch on any other. T1-T4 choose what value A moves; hold B and tap one to give value B a target too
- Give a lane a length of its own for patterns that shift against themselves: tap LN, then key 5 of the value A line, and value A repeats every five steps over the hits' sixteen
- On the voices page's perform side, tap B while the patterns play: the voice plays a copy of its pattern from the next bar, which you can change while A stays as it was. Hold OR, tap A A B A and let go: the voice walks those letters by itself, one a bar
- Hold a step on the patterns page's side 1 and press another key of its line to loop between them; let go and the voice is back in time with the others. LP on the perform side keeps the next loop after you let go, and R1 to R4 roll the voice for as long as you hold them
- A scene saved in 3.8 comes back with its voices in `accent`, where steps only swell the sound: press PU to hear them pulse, or MV to move them

## Playing Chords and MPE

- Hold keys together on a MIDI keyboard to play chords on a voice: each voice plays up to eight notes, and the voices share a note pool for the notes beyond each one's first (SETUP's `note pool`; raise it for bigger chords on several voices, lower it if a CM3 drops out)
- A buffer voice playing a recording makes a sampler: each note plays the sound at its own rate, and pressure swells each note on its own
- A synth voice's chord is grained as one sound: turn grain size and position spread up to smear it into a cloud
- Freeze a synth voice, then play keys: each note replays the frozen sound at its pitch, the key you froze at playing it as it was
- With an MPE controller, choose `mpe selected` on SETUP's `channels` row and set the controller's bend range to Strata's `mpe bend range` (48 by default). Pressure swells each note and slide moves the voice's main control by default; VOICE's `notes` section maps them elsewhere (try slide on `cutoff`, or pressure on `level` for notes that sound only while pressed)
- With a LinnStrument split in two, `mpe split` plays voice 1 from the left half and voice 2 from the right; SETUP's `mpe & zones` editor gives any voice a zone and a range (ALT+K3 on its row learns the range from the next two notes you play), and overlapping ranges layer voices
- `release` in `note off` ends each note with its key; `latch` keeps a chord sounding after the keys lift, until the next chord's first key replaces it: a held drone you can change chord by chord
- A sequencer step's notes play as a chord too (SEQ's `add note` row): sequence chords on one voice while you play another from MIDI

## Using Probability-Based Mutations

- Enable mutations on SETUP (the `mutations` field, E3; or PARAMETERS > mutations enabled)
- Start with conservative settings:
  - Mutation rate: 2-3 seconds (how often mutations occur)
  - Mutation probability: 0.10-0.15 (chance each parameter will change)
  - Mutation amount: 0.20-0.30 (size of changes relative to parameter range)
- Lock voices you want to keep stable while others evolve
- Combine with cross-modulation for complex, interdependent evolution
- Watch the `[M]` indicator on screen to confirm mutations are active
- For dramatic changes, increase probability to 0.25+ and amount to 0.40+
- For subtle drift, decrease both values and increase the mutation rate
