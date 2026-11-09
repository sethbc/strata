// StrataPositions.sc
// The positions area: a buffer grain synth's scan phase. Neutral here (3.2's
// scan); 3.3's positions package (1c) adds scrubbing, holding and resetting
// it. See docs/notes/engine/positions.md.

+ Engine_Strata {
    // The positions area (order 150): no state, defs or commands yet
    strataAreaPositions {
        ^(order: 150)
    }

    // A buffer grain's scan offset (0-1, wrapping), in valid-region lengths
    // per second: scanRate stopped while frozen. scrubRate, scanHold and
    // t_scanReset are 3.3's grain controls, not used until the positions
    // package
    slotScanPhase { arg bufScan, freeze, scrubRate, scanHold, t_scanReset;
        ^Phasor.ar(0, this.scanRate(bufScan, freeze) * SampleDur.ir, 0, 1)
    }
}
