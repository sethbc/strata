# Usage Tips

Workflows for evolving textures, cross-modulation, performance and mutations. Back to the [README](../../README.md).

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
