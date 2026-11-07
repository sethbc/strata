// StrataMix.sc
// The mix area: a grain synth's own filter and where its output goes. For
// now neutral hooks: no filter, the output to out (mainBus) plus the
// mirror. See docs/notes/engine/grains.md.

+ Engine_Strata {
    // The mix area (order 120): no state, defs or commands yet
    strataAreaMix {
        ^(order: 120)
    }

    // A grain synth's stereo output through the voice's filter (filterType,
    // filterFreq, filterRes; filterMix 0 = bypass). Neutral: unchanged
    voiceFilter { arg sig, filterType, filterFreq, filterRes, filterMix;
        ^sig
    }

    // Write a grain synth's stereo output: to out (the engine sets mainBus)
    // and, times mirrorLevel, to mirrorOut (the voice bus, for its mod
    // synth). delaySend and reverbSend are the voice's sends. Neutral: the
    // output and the mirror, the sends ignored
    voiceOutput { arg sig, out, mirrorOut, mirrorLevel, delaySend, reverbSend;
        Out.ar(out, sig);
        Out.ar(mirrorOut, sig * mirrorLevel);
    }
}
