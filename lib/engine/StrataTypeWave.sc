// StrataTypeWave.sc
// The wave voice type (3.8, design §3): \strataWave, a wavetable voice that
// morphs across a bank of waveBankSize tables, from a sine to a bright
// stack. The type area allocates the bank (0b's wavetableBankFrames, which
// fixedBufferBytes already counts) and adds the def. See
// docs/notes/engine/types.md (Wave).

+ Engine_Strata {
    // The wave type's area (order 21, after the voices area): allocState
    // runs before every area's addDefs, so the def reads the bank's first
    // bufnum as a constant. Its def's name is in voiceTypeDefs, which the
    // voices area's addDefs returns
    strataAreaTypeWave {
        ^(
            order: 21,
            allocState: { this.areaCall(\allocWaveBank) },
            addDefs: { this.areaCall(\addWaveDef); [] },
            free: { this.areaCall(\freeWaveBank) }
        )
    }

    // The bank: waveBankSize tables, each waveTableFrames frames (a
    // wavetable of half as many samples, in VOsc's format); the whole bank
    // is 0b's wavetableBankFrames, so its size comes from that alone
    waveBankSize { ^8 }
    waveTableFrames { ^this.wavetableBankFrames div: this.waveBankSize }

    // Each table's harmonic amplitudes, before waveBankAmplitudes evens
    // their level, darkest first: a sine, two, four and eight harmonics falling as 1/k, sixteen
    // odd ones (a soft square), thirty-two falling as 1/k (a soft saw), a
    // peak of twelve around the sixth (a vowel-like formant) and sixty-four
    // falling as 1/sqrt(k), the brightest
    waveBankSpectra {
        ^[
            [1],
            [1, 0.5],
            [1, 0.5, 0.33, 0.25],
            (1..8).reciprocal,
            (1..16).collect({ arg k; if (k.odd) { 1 / k } { 0 } }),
            (1..32).reciprocal,
            (1..12).collect({ arg k; (k - 6).abs.neg.exp }),
            (1..64).collect({ arg k; k.sqrt.reciprocal })
        ]
    }

    // The tables at matched level (1f's review): each spectrum scaled so the
    // root of its squared amplitudes' sum is 1, so every table has a unit
    // sine's RMS (a sum of sines' mean square is half its squared
    // amplitudes' sum) and morph moves the timbre, not the loudness. sine1
    // then fills them with its normalize flag off. A table's peak may pass 1
    // (a stack's crest factor): the def's gain keeps the voice under it
    waveBankAmplitudes {
        ^this.waveBankSpectra.collect({ arg spectrum; spectrum * spectrum.squared.sum.sqrt.reciprocal })
    }

    // The bank's Buffers, consecutive bufnums (VOsc3 reads a table and the
    // next), allocated once; bufnums never change
    waveBank { ^areaState[\typeWave][\bank] }

    // Filled on the server by b_gen sine1 (not normalized: waveBankAmplitudes
    // sets the level; wavetable, clear) in each b_alloc's completion message:
    // no sclang loop over the samples
    allocWaveBank {
        var amplitudes = this.waveBankAmplitudes;
        areaState[\typeWave][\bank] = Buffer.allocConsecutive(this.waveBankSize, context.server, this.waveTableFrames, 1,
            { arg buffer, index; buffer.sine1Msg(amplitudes[index], false, true, true) });
    }

    freeWaveBank {
        (areaState[\typeWave][\bank] ? []).do({ arg buffer; if (buffer.bufnum.notNil) { buffer.free } });
    }

    // The wave voice: a stereo pair of VOsc3s over the bank, each three
    // oscillators at freq and detuned above it (left) or below it (right).
    // The bank position is the expression control morph (noteMainValue),
    // plus a slow random wander (morphDepth at morphRate) and the amplitude
    // crossmod, clipped to 0-1, across waveBankSize - 1.001 tables so the
    // next table VOsc3 reads stays in the bank. The bank's first bufnum is
    // built into the def (as scaleBuffer's is into the grain defs), so the
    // last engine built on a server owns it. A wavetable of sines has no
    // energy at 0 Hz, so there is no subsonic block. The three oscillators
    // sum to about three times one: the 0.3 brings it to one's level. Every
    // table has a unit sine's RMS (waveBankAmplitudes), so morph and its
    // wander keep the level
    addWaveDef {
        var base = this.waveBank[0].bufnum, span = this.waveBankSize - 1.001;
        SynthDef(\strataWave, {
            arg out, gate=1, freq=100, morph=0.3, morphRate=0.05, morphDepth=0.2, detune=0.003, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var env, modulation, modSig, modFreq, modAmp, position, sig;

            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            position = (this.noteMainValue(\strataWave, morph, noteMain) + (LFNoise1.kr(morphRate) * morphDepth)
                + (modSig * 0.2)).clip(0, 1);
            sig = [1, -1].collect({ arg side;
                VOsc3.ar(base + (position * span), modFreq, modFreq * (1 + (detune * side)), modFreq * (1 + (2 * detune * side)))
            });
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp * 0.3);
        }).add;
    }
}
