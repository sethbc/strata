# Usage Tips

Workflows for evolving textures, cross-modulation, performance and mutations. Back to the [README](../../README.md).

## Creating Evolving Textures

- Start with 2-3 voices active
- Use K2 to randomize individual voices until you find interesting combinations
- Lock voices you like with K3
- Adjust master density (arc ring 1 or PARAMETERS) to create movement
- Add reverb or delay on the FX page for more space

## Exploring Cross-Modulation

- Open PARAMETERS menu and navigate to a voice's cross-modulation section
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
2. Randomize unfrozen voices to create variation
3. Use master density for dynamic swells and fades
4. Lock/unlock voices to create structural changes
5. Set up cross-modulation for interdependent voice relationships

## Using Probability-Based Mutations

- Enable mutations via PARAMETERS > mutations enabled
- Start with conservative settings:
  - Mutation rate: 2-3 seconds (how often mutations occur)
  - Mutation probability: 0.10-0.15 (chance each parameter will change)
  - Mutation amount: 0.20-0.30 (size of changes relative to parameter range)
- Lock voices you want to keep stable while others evolve
- Combine with cross-modulation for complex, interdependent evolution
- Watch the `[M]` indicator on screen to confirm mutations are active
- For dramatic changes, increase probability to 0.25+ and amount to 0.40+
- For subtle drift, decrease both values and increase the mutation rate
