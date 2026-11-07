// StrataVariation.sc
// The variation area: the per-grain draws of rate, pan and size, which
// both grain SynthDefs call on their grain trigger (grainBody in
// StrataGrainDefs.sc). For now neutral hooks: no draws, so every grain
// plays at the voice's pitch, pan and size. See docs/notes/engine/grains.md.

+ Engine_Strata {
    // The variation area (order 90): no state, defs or commands yet
    strataAreaVariation {
        ^(order: 90)
    }

    // A grain's signed rate (negative plays it backward), latched by
    // GrainBuf on trig. pitchShift is the voice's pitch (0.25-4), bendRate
    // the pitchbend and frequency-crossmod factor (1 for the synth source),
    // vary an Event of the controls reverseProb, pitchJitter, intervals
    // (an Array of 8), intervalCount, intervalProb, quantize and scaleNote.
    // Neutral: the pitch times the bend.
    grainRate { arg trig, pitchShift, bendRate, vary;
        ^pitchShift * bendRate
    }

    // A grain's pan offset, added to both channel buffers' pans (-1 left,
    // +1 right, clipped at +/-1). Neutral: 0
    grainPan { arg trig, panJitter;
        ^0
    }

    // A grain's duration (s), from the voice's grain size; grainBody caps
    // it at grainMaxSeconds. Neutral: the size
    grainDur { arg trig, grainSize, sizeJitter;
        ^grainSize
    }
}
