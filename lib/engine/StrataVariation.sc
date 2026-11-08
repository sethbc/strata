// StrataVariation.sc
// The variation area: the per-grain draws of rate (pitch jitter, an
// interval from the voice's set, quantize to the scale, reverse), pan and
// size, which both grain SynthDefs call on their grain trigger (grainBody
// in StrataGrainDefs.sc). Every draw is a TRand or TIRand on that trigger
// feeding a GrainBuf input, so GrainBuf latches it with the grain: a draw
// never moves a sounding grain, and none costs memory. At the controls'
// defaults (no reverse, no jitter, no intervals, quantize off) a grain plays
// exactly as 3.1's did. See docs/notes/engine/variation.md.

+ Engine_Strata {
    // The variation area (order 90): no state, defs or commands of its own
    strataAreaVariation {
        ^(order: 90)
    }

    // A grain's signed rate (negative plays it backward), latched by
    // GrainBuf on trig. pitchShift is the voice's pitch (0.25-4), bendRate
    // the pitchbend and frequency-crossmod factor (1 for the synth source),
    // vary an Event of the controls reverseProb, pitchJitter, intervals
    // (an Array of 8), intervalCount, intervalProb, quantize and scaleNote.
    //   - pitch jitter: u x pitchJitter semitones, u uniform in -1..1;
    //   - an interval: with probability intervalProb, one of the first
    //     intervalCount intervals (semitones), each as likely; none while
    //     intervalCount is 0. Its draw (TIRand and TRand on trig) is read by
    //     a Select.kr at the start of each control block, so a grain takes
    //     the draw of the last trigger before its block: still one draw per
    //     grain, without the eight K2As a Select.ar would need (every UGen
    //     takes real-time memory in every grain synth);
    //   - quantize (quantize 1): the pitch, jitter and interval together
    //     moved to the nearest tone of the scale (quantizedOffset,
    //     StrataScale.sc), before bend and crossmod, so they still bend;
    //   - reverse: x -1 with probability reverseProb.
    // The rate is pitchShift x 2^(semitones / 12) x bendRate x the sign: at
    // the defaults exactly pitchShift x bendRate.
    grainRate { arg trig, pitchShift, bendRate, vary;
        // (written on the control's own name: the Lua stub reads the
        // enumeration from "intervalCount.round.clip(0, 8)"; 8 is the
        // number of interval controls, interval1..8)
        var intervalCount = vary[\intervalCount];
        var count = intervalCount.round.clip(0, 8);
        var chance = vary[\intervalProb] * (count > 0);
        // 0: no interval this grain; 1..count: that interval
        var pick = TIRand.ar(1, count.max(1), trig) * (TRand.ar(0, 1, trig) < chance);
        var interval = Select.kr(pick, [0] ++ vary[\intervals]);
        var offset = (TRand.ar(-1, 1, trig) * vary[\pitchJitter]) + interval;
        var semitones = Select.ar(vary[\quantize] > 0.5,
            [offset, this.quantizedOffset(pitchShift, offset, vary[\scaleNote])]);
        var reverse = TRand.ar(0, 1, trig) < vary[\reverseProb];
        ^pitchShift * semitones.midiratio * bendRate * (1 - (2 * reverse))
    }

    // A grain's pan offset, u x panJitter (u uniform in -1..1), added to
    // both channel buffers' pans (-1 left, +1 right, clipped at +/-1) on
    // top of the slow wander
    grainPan { arg trig, panJitter;
        ^TRand.ar(-1, 1, trig) * panJitter
    }

    // A grain's duration (s): grainSize x 2^(u x sizeJitter), u uniform in
    // -1..1; grainBody caps it at grainMaxSeconds
    grainDur { arg trig, grainSize, sizeJitter;
        ^grainSize * (2 ** (TRand.ar(-1, 1, trig) * sizeJitter))
    }
}
