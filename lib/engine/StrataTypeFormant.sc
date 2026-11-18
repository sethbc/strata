// StrataTypeFormant.sc
// The formant voice type (3.8, design §3): \strataFormant, two Formant
// oscillators a channel at formant frequencies that move between vowels.
// Its area only adds the def; the voices area names it (voiceTypeDefs). See
// docs/notes/engine/types.md (Formant).

+ Engine_Strata {
    // The formant type's area (order 25)
    strataAreaTypeFormant {
        ^(
            order: 25,
            addDefs: { this.areaCall(\addFormantDef); [] }
        )
    }

    // The vowel's slow wander (Hz) and its depth (a fraction of the vowel's
    // 0-1), fixed in the def (the prototype's wander control at its default)
    formantWanderRate { ^0.1 }
    formantWanderDepth { ^0.2 }

    // The two formants' frequencies (Hz) at vowel 0 and vowel 1, before the
    // formant scale: the first rises from 300 to 800, the second falls from
    // 2300 to 1100 (an exponential move between them)
    formantFirstRange { ^#[300, 800] }
    formantSecondRange { ^#[2300, 1100] }

    // The second formant's level against the first's, the right channel's
    // detune and the sum's gain (two formants of up to 2 each)
    formantSecondLevel { ^0.5 }
    formantDetune { ^1.003 }
    formantGain { ^0.5 }

    addFormantDef {
        // vowel (0-1) moves both formants between vowels, wandering
        // formantWanderDepth either way at formantWanderRate; formant
        // (0.5-2, the expression control, noteMainValue) scales both
        // frequencies; bw (0.1-1) is each formant's bandwidth as a fraction
        // of its frequency. Formant takes the larger of the pitch and the
        // bandwidth itself, so a narrow bandwidth at a high pitch is clamped
        // there, never undefined. Its bursts (a raised cosine times a sine)
        // last max(pitch, bandwidth) a cycle, so where a formant falls near
        // or under the pitch a burst holds half a cycle or so of its sine and
        // carries DC, which moves with the vowel's wander: taken out here,
        // before the voice bus (subsonicBlock, #309; 0.42 to 0.46 of the
        // peak below 8 Hz without it at 300 Hz, formant 0.5, and 2000 Hz,
        // formant 2)
        SynthDef(\strataFormant, {
            arg out, gate=1, freq=100, formant=1, vowel=0.5, bw=0.5, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modFreq, modAmp, scale, place, first, second, sig;

            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            scale = this.noteMainValue(\strataFormant, formant, noteMain);
            place = (vowel + (LFNoise1.kr(this.formantWanderRate) * this.formantWanderDepth)).clip(0, 1);
            first = place.linexp(0, 1, this.formantFirstRange[0], this.formantFirstRange[1]) * scale;
            second = place.linexp(0, 1, this.formantSecondRange[0], this.formantSecondRange[1]) * scale;
            sig = [1, this.formantDetune].collect({ arg detune;
                this.subsonicBlock((Formant.ar(modFreq * detune, first, first * bw)
                    + (Formant.ar(modFreq * detune, second, second * bw) * this.formantSecondLevel)) * this.formantGain)
            });
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
    }
}
