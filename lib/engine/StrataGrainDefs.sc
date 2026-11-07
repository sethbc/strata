// StrataGrainDefs.sc
// The grain SynthDefs and the grains area: the envelope buffers, the
// source -> grain SynthDef table and the envShape grain param. See
// docs/notes/engine/grains.md.

+ Engine_Strata {
    // The grains area (order 30)
    strataAreaGrains {
        ^(
            order: 30,
            allocState: { this.allocEnvelopeBuffers },
            addDefs: { this.addGrainDefs; [\strataGrain, \strataGrainBuf] },
            // A buffer slot's voice reads it with strataGrainBuf; the synth
            // and input sources use strataGrain (the first match wins)
            grainDefs: [
                { arg source; source.inclusivelyBetween(1, numBuffers) } -> \strataGrainBuf,
                { true } -> \strataGrain
            ],
            grainParamHandlers: (
                // envShape is an index (0 = Hann, 1-4 = envBuffers) that the
                // engine turns into the grain synth's envBuf, kept so a
                // replacement grain synth (source switch) starts with it
                envShape: { arg voice, value;
                    var bufnum = this.envBufnumFor(value.round.asInteger);
                    if (bufnum.notNil) {
                        grainControls[voice][\envBuf] = bufnum;
                        this.setSynth(this.grainKey(voice), \envBuf, bufnum);
                    };
                    true
                }
            ),
            free: { this.freeEnvelopeBuffers }
        )
    }

    allocEnvelopeBuffers {
        // Grain envelope shapes selected by setGrainParam(voice, \envShape, n):
        // 0 = GrainIn's built-in Hann (envbufnum -1), 1-4 = these buffers
        envBuffers = [
            Env.sine,
            Env.perc(0.1, 0.9),
            Env.linen(0.1, 0.8, 0.1),
            Env([0, 1, 1, 0], [0.25, 0.5, 0.25])  // trapezoid
        ].collect({ arg env; Buffer.loadCollection(context.server, env.asSignal(1024)) });
    }

    freeEnvelopeBuffers {
        envBuffers.do({ arg buffer; buffer.free });
    }

    addGrainDefs {
        // Granular processor for a stereo bus: the voice's own bus (synth
        // source) or inputBus (input source). For the input source the engine
        // sets accentAmt 1 (there is no voice synth to carry the accent),
        // mirrorLevel 1 (copies the output to the voice bus for strataMod)
        // and modLevel 1 (amplitude crossmod; frequency crossmod has no
        // meaning for live input and is ignored), and the voice's pan; for
        // the synth source all four are 0 (their defaults), since the voice
        // synth already accents, crossmods and pans and this synth reads the
        // voice bus. bend is unused here.
        SynthDef(\strataGrain, {
            arg in, out, gate=1,
            grainSize=0.1, grainDensity=20, pitchShift=1,
            posSpread=0.5, panSpread=0.5, amp=1, envBuf = -1,
            grainMode=0, t_trig=0, velocity=1, accentAmt=0,
            mirrorOut=0, mirrorLevel=0, bend=1, kill=0, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0, modLevel=0;
            var sig, env, input, mode, grainTrigger, spreadLevel, accent, left, right, modSig;

            env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent for input-sourced voices; levelScale is sampled per
            // trigger, so velocity never rescales a running tail
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);
            // Amplitude crossmod for input-sourced voices, clamped like the voices'
            modSig = ((In.kr(modBus1, 1) * modAmpAmt1) + (In.kr(modBus2, 1) * modAmpAmt2)
                + (In.kr(modBus3, 1) * modAmpAmt3)).clip(-2, 2) * modLevel;
            input = In.ar(in, 2);

            // grainMode 0 = continuous (grainDensity grains per second),
            // 1 = triggered: one grain per t_trig (retrigger: pattern steps,
            // MIDI notes). Synth-sourced velocity reaches triggered grains
            // through the voice synth's accent; GrainIn has no per-grain
            // amplitude. Triggered mode mutes the position-spread path so
            // only the grains sound (faded over 50 ms, so a mode change
            // does not click; grainDensity and posSpread then do nothing).
            mode = grainMode.round.clip(0, 1);
            grainTrigger = Select.ar(mode, [Impulse.ar(grainDensity), T2A.ar(t_trig)]);
            spreadLevel = Select.kr(mode, [1, 0]).lag(0.05);

            // One mono GrainIn per input channel on a shared trigger, panned
            // as a pair like strataGrainBuf. (A stereo GrainIn on a stereo
            // input expands into two, each panning its own channel, which
            // Out then folds back to one channel apiece: pan spread did
            // nothing and the output path was doubled.) The voice's own pan
            // is applied after the PitchShift (panBalance).
            left = GrainIn.ar(1, grainTrigger, grainSize, input[0], 0, envBuf, maxGrains);
            right = GrainIn.ar(1, grainTrigger, grainSize, input[1], 0, envBuf, maxGrains);
            sig = Balance2.ar(left, right, LFNoise1.kr(2).range(panSpread.neg, panSpread));

            // Position spread: a little of the input, smeared by a wandering delay
            sig = sig + (DelayC.ar(
                input,
                0.2,
                LFNoise1.kr(1).range(0, posSpread * 0.2)
            ) * 0.3 * spreadLevel);

            // Transpose the whole grain-synth output (GrainIn has no rate
            // input). Shifting after the spread path is summed keeps every
            // part transposed and time-aligned. The window is the fixed
            // pitchShiftWindow, not the grain size: PitchShift allocates its
            // delay line from the real-time pool for the window it starts with.
            sig = PitchShift.ar(
                sig,
                windowSize: pitchShiftWindow,
                pitchRatio: pitchShift.lag(0.5),
                pitchDispersion: 0,
                timeDispersion: 0
            );
            sig = this.panBalance(sig, pan);

            sig = sig * env * (amp * (1 + modSig) * (1 + (accent * accentAmt))).clip(0, 2);
            Out.ar(out, sig);
            Out.ar(mirrorOut, sig * mirrorLevel);
        }).add;

        // Granular processor for a buffer slot: two mono GrainBufs (left and
        // right buffers) share one trigger, position, rate and duration, so
        // every grain is sample-aligned across the pair. bufPos (0-1) and the
        // scan are fractions of the valid region (bufFrames), so a short
        // sample uses the whole position range; bufScan moves the position
        // in valid-region lengths per second and wraps. Positions are scaled
        // to the part of the region a grain can start in and still end inside
        // it (and a grain is never longer than the region), so no grain reads
        // the zeroed rest of the buffer. Crossmod applies to amplitude and
        // rate as voice synths apply it to amp and freq; pan is the voice's.
        // bufRateScale is the content's sample rate over the server's (what
        // BufRateScale.kr would report), tracked by the engine: b_alloc keeps
        // a loaded file's rate, and norns' scsynth has no b_setSampleRate. The
        // output also goes to mirrorOut (the voice's bus) so the voice's
        // strataMod keeps following what is heard; the engine sets mirrorLevel
        // 1 (the default 0 keeps a synth without a mirrorOut off bus 0).
        SynthDef(\strataGrainBuf, {
            arg out, gate=1, bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0,
            grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
            envBuf = -1, grainMode=0, t_trig=0, amp=1, bend=1,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            velocity=1, mirrorOut=0, mirrorLevel=0, kill=0, pan=0;
            var sig, env, accent, mod1Sig, mod2Sig, mod3Sig, modSig, rateMod, modAmp;
            var mode, grainTrigger, scanPos, grainPos, rate, left, right, hasAudio;
            var validFrames, readRate, grainDur, grainFrames, startFrames;

            env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent fired by retrigger; levelScale is sampled per trigger
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            // Clamped like voice frequency modulation so the rate stays positive
            rateMod = ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2);
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            mode = grainMode.round.clip(0, 1);
            grainTrigger = Select.ar(mode, [Impulse.ar(grainDensity), T2A.ar(t_trig)]);

            scanPos = (bufPos + Phasor.ar(0, bufScan * SampleDur.ir, 0, 1)) % 1;
            // GrainBuf already scales by the buffer's own rate (BufRateScale), which
            // the server keeps from the last file read even after a recording:
            // divided out, so the engine's bufRateScale applies exactly once
            rate = bufRate * bend * (bufRateScale / BufRateScale.kr(bufnumL)) * (1 + rateMod);

            // Grain end: GrainBuf reads rate x its buffer's BufRateScale
            // frames per output sample (it applies the buffer's rate scale
            // itself; with the division above that is bufRate x bend x
            // bufRateScale x (1 + rateMod)), so a grain covers grainDur x
            // SampleRate x readRate frames. The duration is capped at the valid region (less
            // grainEndMargin), and the start positions (the scan, spread
            // included) are scaled to the frames before the region's end
            // minus that span, so every grain ends inside the region. While
            // the slot reads empty (bufFrames 0: cleared, reloading or
            // recording, faded out by hasAudio) the last valid length is
            // held, so the grains fading out keep their size and place.
            validFrames = Gate.kr(bufFrames, bufFrames > 0);
            readRate = (rate * BufRateScale.kr(bufnumL)).max(0.001);  // never 0: grainDur divides by it
            grainDur = grainSize.min((validFrames - grainEndMargin).max(0) / (readRate * SampleRate.ir));
            grainFrames = grainDur * SampleRate.ir * readRate;
            startFrames = (validFrames - grainEndMargin - grainFrames).clip(0, BufFrames.kr(bufnumL));
            grainPos = (scanPos + TRand.ar(posSpread * -0.5, posSpread * 0.5, grainTrigger)).wrap(0, 1)
                * (startFrames / BufFrames.kr(bufnumL));

            left = GrainBuf.ar(1, grainTrigger, grainDur, bufnumL, rate, grainPos, 2, 0, envBuf, maxGrains);
            right = GrainBuf.ar(1, grainTrigger, grainDur, bufnumR, rate, grainPos, 2, 0, envBuf, maxGrains);
            sig = Balance2.ar(left, right, LFNoise1.kr(2).range(panSpread.neg, panSpread));

            // Same transposition stage as strataGrain (fixed window), once for the pair
            sig = PitchShift.ar(
                sig,
                windowSize: pitchShiftWindow,
                pitchRatio: pitchShift.lag(0.5),
                pitchDispersion: 0,
                timeDispersion: 0
            );
            sig = this.panBalance(sig, pan);

            // Silent while the slot is empty or being recorded (bufFrames 0):
            // every grain would read position 0 and loop the take's first grain
            hasAudio = (bufFrames > 0).lag(0.05);

            sig = sig * env * modAmp * hasAudio;
            Out.ar(out, sig);
            Out.ar(mirrorOut, sig * mirrorLevel);
        }).add;
    }
}
