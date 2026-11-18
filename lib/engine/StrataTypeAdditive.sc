// StrataTypeAdditive.sc
// The additive voice type (3.8, design §3): \strataAdditive, a bank of
// additivePartials sine partials with a tilt, a stretch, an odd/even
// balance and one slow wander for every partial. Its own area adds the def;
// the voices area names it in voiceTypeDefs. See docs/notes/engine/types.md
// (The additive type).

+ Engine_Strata {
    // The additive type's area (order 22): its def only
    strataAreaTypeAdditive {
        ^(
            order: 22,
            addDefs: { this.areaCall(\addAdditiveDef); [] }
        )
    }

    // The partials a voice synth plays: the most that keep the def within
    // the memory area's one limit for every voice def (52 KB, design §1 and
    // §3: 16 if it fits, else 12, else 8; the sizes measured are in
    // docs/notes/engine/types.md)
    additivePartials { ^16 }

    // A partial at or above this fraction of the sample rate is muted (0.45:
    // 21.6 kHz at 48 kHz, under Nyquist with room for the stretch)
    additiveMuteRatio { ^0.45 }

    // How far the stretch bends the series: partial k sits at
    // k ** (1 + additiveStretchRatio x stretch), stretch -1..1
    additiveStretchRatio { ^0.05 }

    // How far the wander moves the tilt either way (the one LFNoise1, -1..1,
    // times this, added to the tilt the partials' levels fall by)
    additiveWanderDepth { ^0.3 }

    // The mute's lag (s): a bend or crossmod sweeping a partial across the
    // limit fades it (and the normalization with it) instead of stepping it
    additiveMuteLag { ^0.03 }

    // The additive voice. Partial k (1..additivePartials) sits at
    // freq x k ** (1 + 0.05 x stretch), at a level of k ** -tilt times its
    // odd or even level (oddEven 0: the odd partials only, 0.5 all, 1 the
    // even only; the fundamental always), the tilt moved either way by one
    // slow LFNoise1 at the wander rate, which serves every partial (no
    // oscillator a partial: design §3). Each is worked out in logarithms, so
    // a partial costs two MulAdds, two exps, its mute's comparison, lag
    // and product at control rate, and its SinOsc and one MulAdd at audio
    // rate (the running sum of its side). A partial at or above
    // additiveMuteRatio x the sample rate (the frequency after bend,
    // crossmod and the note's bend) is muted, over additiveMuteLag, and the
    // sum is normalized by the levels' sum, which bounds the peak whatever
    // the tilt (a flat tilt spreads it over many partials and is quieter).
    // The voice is centered at pan 0: the fundamental starts both sides'
    // sums, and the upper partials spread in pairs (2 left, 3 and 4 right,
    // 5 and 6 left, ...), so the sides' levels stay within about 1 dB at
    // every tilt and oddEven (the check holds them within 1.5); Balance2
    // pans the pair as the other types' do. A sum of sines has no energy
    // near 0 Hz, so no subsonicBlock. The tilt is the expression control
    // (noteMainValue)
    addAdditiveDef {
        var count = this.additivePartials;
        SynthDef(\strataAdditive, {
            arg out, gate=1, freq=100, tilt=1, stretch=0, oddEven=0.5, wander=0.2, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=4, releaseTime=8;
            var env, modulation, modFreq, modAmp, logFreq, logLimit, power, slope, oddLog, evenLog, wanderNoise;
            var amps, left, right, level;

            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            // log f_k = log freq + power x log k
            logFreq = modFreq.max(1).log;
            logLimit = (SampleRate.ir * this.additiveMuteRatio).log;
            power = (stretch.clip(-1, 1) * this.additiveStretchRatio) + 1;
            // log a_k = slope x log k + log of its odd or even level, where
            // slope is -tilt moved by the wander
            wanderNoise = LFNoise1.kr(wander.clip(0.01, 1));
            slope = (wanderNoise * this.additiveWanderDepth) - this.noteMainValue(\strataAdditive, tilt, noteMain);
            oddLog = (2 - (2 * oddEven.clip(0, 1))).clip(0.00001, 1).log;
            evenLog = (2 * oddEven.clip(0, 1)).clip(0.00001, 1).log;

            // the fundamental: level 1, muted only above the limit, on both
            // sides (one SinOsc that starts each side's sum)
            amps = [(logFreq < logLimit).lag(this.additiveMuteLag)];
            left = SinOsc.ar(modFreq, 0, amps[0]);
            right = left;
            (2 .. count).do({ arg k;
                var logK = k.log, logPartial = (power * logK) + logFreq;
                var a = ((slope * logK) + if (k.odd) { oddLog } { evenLog }).exp
                    * (logPartial < logLimit).lag(this.additiveMuteLag);
                amps = amps.add(a);
                // the upper partials spread in pairs: 2 left, 3-4 right, 5-6 left, ...
                if (((k - 1) div: 2).even) {
                    left = SinOsc.ar(logPartial.exp, 0, a, left)
                } {
                    right = SinOsc.ar(logPartial.exp, 0, a, right)
                };
            });

            level = amps.sum.max(0.001).reciprocal * env * modAmp;
            Out.ar(out, Balance2.ar(left, right, pan, level));
        }).add;
    }
}
