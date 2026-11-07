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

    // How much further back (s) a ring grain synth starts its grains for
    // the voice's scan and freeze controls: a frozen ring holds valid audio
    // all round and its reads wrap, so the scan can move the read point back
    // through it. Neutral: 0 (an unfrozen ring ignores bufScan)
    ringScanOffset { arg bufScan, freeze;
        ^0
    }

    // Freeze a voice's source (the freeze grain param). Neutral: nothing
    freezeVoice { arg voice; }

    // Undo freezeVoice. replaceGrainSynth calls it before every source
    // switch of a running voice. Neutral: nothing
    unfreezeVoice { arg voice; }
}
