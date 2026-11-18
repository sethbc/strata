// StrataVariation.sc
// The variation area: the per-grain draws of rate (pitch jitter, an
// interval from the voice's set, quantize to the scale, reverse), pan and
// size, which both grain SynthDefs call on their grain trigger (grainBody
// in StrataGrainDefs.sc). Every draw is a TRand or TIRand on that trigger
// feeding a GrainBuf input, so GrainBuf latches it with the grain: a draw
// never moves a sounding grain, and none costs memory. At the controls'
// defaults (no reverse, no jitter, no intervals, quantize off, 3.8's
// arpeggiator off) a grain plays exactly as 3.1's did. The arpeggiator's
// step (arpStep) is a counter on the same trigger. See
// docs/notes/engine/variation.md.

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
    // 3.8's arpeggiator step (design §4.3; vary's arpOn and arpFold): while
    // arpOn is 1 the interval is the next of the first intervalCount in
    // turn (arpStep), in place of the draw, and intervalProb does not apply.
    // With no arpOn in vary (the check-only copies of 3.2's and 3.3's defs)
    // today's graph (ruling 33)
    grainRate { arg trig, pitchShift, bendRate, vary;
        // (written on the controls' own names: the Lua stub reads the
        // enumerations from "intervalCount.round.clip(0, 8)", 8 the
        // number of interval controls, interval1..8, and from
        // "arpOn.round.clip(0, 1)" and "arpFold.round.clip(0, 1)")
        var intervalCount = vary[\intervalCount], arpOn = vary[\arpOn], arpFold = vary[\arpFold];
        var count = intervalCount.round.clip(0, 8);
        var chance = vary[\intervalProb] * (count > 0);
        // 0: no interval this grain; 1..count: that interval
        var drawn = TIRand.ar(1, count.max(1), trig) * (TRand.ar(0, 1, trig) < chance);
        var pick = if (arpOn.isNil) { drawn } {
            Select.ar(arpOn.round.clip(0, 1), [drawn, this.arpStep(trig, count, arpFold.round.clip(0, 1))])
        };
        var interval = Select.kr(pick, [0] ++ vary[\intervals]);
        var offset = (TRand.ar(-1, 1, trig) * vary[\pitchJitter]) + interval;
        var semitones = Select.ar(vary[\quantize] > 0.5,
            [offset, this.quantizedOffset(pitchShift, offset, vary[\scaleNote])]);
        var reverse = TRand.ar(0, 1, trig) < vary[\reverseProb];
        ^pitchShift * semitones.midiratio * bendRate * (1 - (2 * reverse))
    }

    // The arpeggiator's interval (1..count; 0 while count is 0) for each
    // grain the trigger starts: a Stepper counts the grains (a float
    // PulseCount would stop counting at 2^24, ruling 34), round span steps,
    // where span is count, or 2 x count - 2 there and back with the fold
    // (fold 1: 1, 2, 3, 2, 1, 2, ... for count 3), folded to
    // (count - 1) - |s - (count - 1)|. A grain the probability drops never
    // reaches the trigger, so it never advances the step. Every grain plays
    // the step from before its own trigger, wherever the trigger falls in a
    // block: grainRate's Select.kr reads the count at the block's first
    // sample (the one before a trigger inside the block), and the sum that
    // adds the interval to the jitter (an audio-rate plus a control-rate
    // input) ramps the control input from its last block's value, so a
    // trigger on the block's first sample (a retrigger's, T2A's) also
    // takes the old step; the ramp has ended before the next grain, which
    // the trigger's hold keeps at least two blocks later. So the order
    // holds, one grain late, at every density (fix round 1: the engine
    // check's arpeggio order checks)
    arpStep { arg trig, count, fold;
        var length = count.max(1), span = Select.kr(fold, [length, ((2 * length) - 2).max(1)]);
        var step = Stepper.ar(trig, 0, 0, span - 1);
        var index = Select.ar(fold, [step, (length - 1) - (step - (length - 1)).abs]);
        ^(index + 1) * (count > 0)
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
