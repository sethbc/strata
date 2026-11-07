// StrataFreeze.sc
// The freeze area: holding what a voice's grains read. For now neutral
// hooks: nothing freezes. See docs/notes/engine/grains.md and
// docs/notes/engine/rings.md.

+ Engine_Strata {
    // The freeze area (order 110): no state, defs or commands yet
    strataAreaFreeze {
        ^(order: 110)
    }

    // The rate of a buffer grain synth's position scan (valid-region
    // lengths per second) for the voice's scan and freeze controls.
    // Neutral: the scan
    scanRate { arg bufScan, freeze;
        ^bufScan
    }

    // Freeze a voice's source (the freeze grain param). Neutral: nothing
    freezeVoice { arg voice; }

    // Undo freezeVoice. replaceGrainSynth calls it before every source
    // switch of a running voice. Neutral: nothing
    unfreezeVoice { arg voice; }
}
