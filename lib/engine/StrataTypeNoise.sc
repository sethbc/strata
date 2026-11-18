// StrataTypeNoise.sc
// The noise voice type (3.8, design §3; package 1h): \strataNoise, pink
// noise and dust through a lowpass and a resonant bank at the voice's
// pitch. Its own area, typeNoise (order 23), only adds the def; the voices
// area lists it in voiceTypeDefs. See docs/notes/engine/types.md (Noise).

+ Engine_Strata {
    // The noise type's area (order 23): its def, whose name voiceTypeDefs
    // already returns, so addDefs returns none
    strataAreaTypeNoise {
        ^(
            order: 23,
            addDefs: { this.areaCall(\addNoiseDef); [] }
        )
    }

    // The bank: four resonances at freq x noiseSpread ** k (k 0 to 3), at
    // noiseBankLevels, each Resonz at the q (its rq)
    noiseSpread { ^1.5 }
    noiseBankLevels { ^#[1, 0.6, 0.4, 0.25] }
    // color 0 to 1 is the lowpass's cutoff over this range, exponentially (Hz)
    noiseColorRange { ^#[200, 16000] }
    // The level against the Pulse voice's at the defaults (RMS at 220 Hz,
    // the types area's check), and the limiter's level (before the
    // balance, which passes a channel whole when panned to it)
    noiseGain { ^14 }
    noiseCeiling { ^0.9 }

    addNoiseDef {
        // Every voice def's shared and note controls (voiceEnvelope,
        // voiceModulation); q is the expression control (noteMainValue)
        SynthDef(\strataNoise, {
            arg out, gate=1, freq=100, color=0.5, grit=0.3, dust=8, q=0.05, bank=0.7, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modFreq, modAmp, rq, source, resonances, sig;

            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            rq = this.noteMainValue(\strataNoise, q, noteMain);

            // pink noise and dust (grit, at dust bursts a second, a little
            // apart left and right), a channel each. Pink noise has energy
            // near 0 Hz: taken out here, before the voice bus (subsonicBlock)
            source = (PinkNoise.ar([1, 1]) * (1 - grit)) + (Dust2.ar([dust, dust * 1.1]) * grit * 4);
            source = LPF.ar(this.subsonicBlock(source), color.linexp(0, 1, this.noiseColorRange[0], this.noiseColorRange[1]));

            // The bank: a narrow Resonz rings quieter (noise power goes with
            // the bandwidth), so the sum is raised by rq's square root's
            // reciprocal; a slow swell between 0.6 and full. Each resonance
            // stays below Nyquist (filterCeiling)
            resonances = this.noiseBankLevels.collect({ arg level, k;
                Resonz.ar(source, (modFreq * (this.noiseSpread ** k)).min(SampleRate.ir * filterCeiling), rq, level)
            }).sum * rq.reciprocal.sqrt * LFNoise1.kr(0.1).range(0.6, 1);
            sig = (resonances * bank) + (source * (1 - bank) * 0.3);

            // The bank's gain at a narrow q and the dust's bursts make the
            // level swing widely: a limiter at noiseCeiling, after the
            // level (accents and crossmod included), as the Resonator's,
            // with its short lookahead (voiceLimiterLookahead)
            sig = Limiter.ar(sig * this.noiseGain * modAmp, this.noiseCeiling, voiceLimiterLookahead);
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env);
        }).add;
    }
}
