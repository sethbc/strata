// StrataPositions.sc
// The positions area: a buffer grain synth's scan phase, with its transient
// performance state (t_scanReset, scrubRate, scanHold), which no scene, PSET
// or voices table holds. See docs/notes/engine/positions.md.

+ Engine_Strata {
    // The positions area (order 150). t_scanReset is handled here so nothing
    // stores it: a replacement grain synth never starts with a stale trigger.
    // scrubRate and scanHold are plain grain controls, stored and sent, so a
    // switch mid-glide keeps gliding.
    strataAreaPositions {
        ^(
            order: 150,
            grainParamHandlers: (
                t_scanReset: { arg voice, value;
                    this.setSynth(this.grainKey(voice), \t_scanReset, value);
                    true
                }
            )
        )
    }

    // A buffer grain's scan offset (0-1, wrapping), in fractions of the
    // voice's loop per second (of the whole valid region when the loop is
    // the whole slot): the voice's own scan (scanRate, stopped while frozen or by
    // scanHold) plus scrubRate, which neither stops. t_scanReset restarts it
    // at 0.
    slotScanPhase { arg bufScan, freeze, scrubRate, scanHold, t_scanReset;
        ^Phasor.ar(t_scanReset, (this.scanRate(bufScan, freeze) * (1 - scanHold) + scrubRate) * SampleDur.ir, 0, 1)
    }
}
