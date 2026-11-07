// StrataGrainDefs.sc
// The grain SynthDefs and the grains area: the envelope buffers, the
// source -> grain SynthDef table and the envShape and history grain
// params. Both grain SynthDefs are GrainBuf pairs built by grainBody; pitch
// is the grain rate. See docs/notes/engine/grains.md.

+ Engine_Strata {
    // The longest grain any grain synth plays (s): Lua's largest grain size,
    // and the bound the rings' lookback (docs/notes/engine/rings.md) relies on
    grainMaxSeconds { ^0.5 }

    // The grains area (order 30)
    strataAreaGrains {
        ^(
            order: 30,
            allocState: { this.allocEnvelopeBuffers },
            addDefs: { this.addGrainDefs; [\strataGrainRing, \strataGrainBuf] },
            // A buffer slot's voice reads it with strataGrainBuf; the synth
            // and input sources read their ring with strataGrainRing (the
            // first match wins)
            grainDefs: [
                { arg source; source.inclusivelyBetween(1, numBuffers) } -> \strataGrainBuf,
                { true } -> \strataGrainRing
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
                },
                // history (s back from the input ring's head) is kept for
                // every voice but reaches only an input voice's grain synth:
                // the synth source reads its own 4 s ring at history 0
                // (grainControlPairs)
                history: { arg voice, value;
                    grainControls[voice][\history] = value;
                    if (grainSource[voice] == this.inputSource) { this.setSynth(this.grainKey(voice), \history, value) };
                    true
                }
            ),
            free: { this.freeEnvelopeBuffers }
        )
    }

    allocEnvelopeBuffers {
        // Grain envelope shapes selected by setGrainParam(voice, \envShape, n):
        // 0 = GrainBuf's built-in Hann (envbufnum -1), 1-4 = these buffers
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

    // The two grain SynthDefs. Both declare the same grain controls (their
    // arg lists are literal, so the Lua stub reads them) and share
    // grainBody; they differ only in what they read and where a grain
    // starts. The 3.2 controls past today's (history ... reverbSend) have
    // neutral defaults: no variation, the whole slot as the loop, no
    // freeze, no voice filter, sends at 1.
    addGrainDefs {
        // Granular processor for a ring: the voice's own (synth source) or
        // the input's (input source), each written by a strataRingWrite
        // (StrataRings.sc) whose frame position is on phaseBus. Grains start
        // behind the write head (ringGrainReader).
        SynthDef(\strataGrainRing, {
            arg out, gate=1, bufL=0, bufR=0, phaseBus=0,
            grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
            envBuf = -1, grainMode=0, t_trig=0, velocity=1, amp=1, bend=1, kill=0, pan=0,
            accentAmt=0, mirrorOut=0, mirrorLevel=0, modLevel=0, rateLevel=1,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            history=0, ringLevel=1, freeze=0, freezeMode=0,
            reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
            interval1=0, interval2=0, interval3=0, interval4=0,
            interval5=0, interval6=0, interval7=0, interval8=0,
            intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
            loopStart=0, loopLength=1,
            filterType=0, filterFreq=5000, filterRes=0.5, filterMix=0,
            delaySend=1, reverbSend=1;
            var controls = (
                out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
                posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
                t_trig: t_trig, velocity: velocity, amp: amp, bend: bend, kill: kill, pan: pan,
                accentAmt: accentAmt, mirrorOut: mirrorOut, mirrorLevel: mirrorLevel, modLevel: modLevel,
                rateLevel: rateLevel, modBuses: [modBus1, modBus2, modBus3],
                modAmpAmts: [modAmpAmt1, modAmpAmt2, modAmpAmt3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
                ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
                sizeJitter: sizeJitter,
                intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
                filterType: filterType, filterFreq: filterFreq, filterRes: filterRes, filterMix: filterMix,
                delaySend: delaySend, reverbSend: reverbSend
            );
            this.grainBody(controls, this.ringGrainReader(bufL, bufR, phaseBus, posSpread, history));
        }).add;

        // Granular processor for a buffer slot (bufnumL/R). bufPos (0-1) and
        // the scan are fractions of the valid region (bufFrames), so a short
        // sample uses the whole position range; bufScan moves the position
        // in valid-region lengths per second and wraps. No grain reads past
        // the valid region (slotGrainPos and the duration cap in
        // slotGrainReader). bufRateScale is the content's sample rate over
        // the server's (what BufRateScale.kr would report), tracked by the
        // engine: b_alloc keeps a loaded file's rate, and norns' scsynth has
        // no b_setSampleRate. While the slot is empty or being recorded
        // (bufFrames 0) the output fades out (hasAudio).
        SynthDef(\strataGrainBuf, {
            arg out, gate=1, bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0,
            grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
            envBuf = -1, grainMode=0, t_trig=0, velocity=1, amp=1, bend=1, kill=0, pan=0,
            accentAmt=0, mirrorOut=0, mirrorLevel=0, modLevel=0, rateLevel=1,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            history=0, ringLevel=1, freeze=0, freezeMode=0,
            reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
            interval1=0, interval2=0, interval3=0, interval4=0,
            interval5=0, interval6=0, interval7=0, interval8=0,
            intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
            loopStart=0, loopLength=1,
            filterType=0, filterFreq=5000, filterRes=0.5, filterMix=0,
            delaySend=1, reverbSend=1;
            var controls = (
                out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
                posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
                t_trig: t_trig, velocity: velocity, amp: amp, bend: bend, kill: kill, pan: pan,
                accentAmt: accentAmt, mirrorOut: mirrorOut, mirrorLevel: mirrorLevel, modLevel: modLevel,
                rateLevel: rateLevel, modBuses: [modBus1, modBus2, modBus3],
                modAmpAmts: [modAmpAmt1, modAmpAmt2, modAmpAmt3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
                ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
                sizeJitter: sizeJitter,
                intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
                filterType: filterType, filterFreq: filterFreq, filterRes: filterRes, filterMix: filterMix,
                delaySend: delaySend, reverbSend: reverbSend
            );
            this.grainBody(controls, this.slotGrainReader(bufnumL, bufnumR, bufFrames, bufRateScale, bufPos, bufRate,
                bufScan, posSpread, freeze, loopStart, loopLength));
        }).add;
    }

    // The chain both grain SynthDefs share. controls: an Event of the def's
    // controls (the three crossmod slots as Arrays, the intervals as one).
    // reader: a function of (trigger, rate, duration, mode) returning an
    // Event of what the grains read: the left and right buffers (bufL,
    // bufR), the rate, duration and start (pos, 0-1 of the buffer) each
    // GrainBuf latches per grain, and an output level (level).
    //   1. The trigger: grainDensity grains per second (grainMode 0) or one
    //      per t_trig (1: retrigger, pattern steps, MIDI notes).
    //   2. Rate and duration: grainRate and grainDur (StrataVariation.sc);
    //      pitchShift is the rate (an exact transposition). bend and the
    //      frequency crossmod enter it scaled by rateLevel: 0 for the synth
    //      source, whose voice synth already applies them.
    //   3. Two stereo GrainBufs, the left buffer's grains panned to -1 and
    //      the right's to +1 (plus grainPan's offset), so the pair stays
    //      sample-aligned and keeps its image; then the slow pan wander
    //      (Balance2 by panSpread), the voice's pan (panBalance; 0 for the
    //      synth source) and the voice filter (StrataMix.sc).
    //   4. The level: the ASR (openedGate, released by gate), the kill fade,
    //      ringLevel (a 50 ms fade the rings area uses before overwriting a
    //      ring), the amplitude crossmod (by modLevel) and the accent (by
    //      accentAmt; velocity is only the accent's levelScale, sampled per
    //      trigger, so it never rescales a running tail); then voiceOutput
    //      (StrataMix.sc) writes it and the mirror.
    grainBody { arg controls, reader;
        var c = controls, env, accent, modSigs, modSig, rateMod, bendRate, grainMode, mode, trig;
        var vary, rate, dur, read, panOffset, left, right, sig;

        env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(c[\gate]), doneAction: 2) * this.killFade(c[\kill]);
        accent = EnvGen.kr(Env.perc(0.005, 0.4), c[\t_trig], levelScale: c[\velocity]);

        // Crossmod, clamped like the voices': amplitude by modLevel, rate
        // (kept positive) by rateLevel
        modSigs = c[\modBuses].collect({ arg bus; In.kr(bus, 1) });
        modSig = (modSigs * c[\modAmpAmts]).sum.clip(-2, 2) * c[\modLevel];
        rateMod = (modSigs * c[\modFreqAmts]).sum.clip(-0.9, 2);
        bendRate = 1 + (c[\rateLevel] * ((c[\bend] * (1 + rateMod)) - 1));

        // (written on the control's own name: the Lua stub reads the
        // enumeration from "grainMode.round.clip(0, 1)")
        grainMode = c[\grainMode];
        mode = grainMode.round.clip(0, 1);
        trig = Select.ar(mode, [Impulse.ar(c[\grainDensity]), T2A.ar(c[\t_trig])]);

        vary = (
            reverseProb: c[\reverseProb], pitchJitter: c[\pitchJitter], intervals: c[\intervals],
            intervalCount: c[\intervalCount], intervalProb: c[\intervalProb], quantize: c[\quantize], scaleNote: c[\scaleNote]
        );
        rate = this.grainRate(trig, c[\pitchShift], bendRate, vary);
        dur = this.grainDur(trig, c[\grainSize], c[\sizeJitter]).min(this.grainMaxSeconds);
        read = reader.value(trig, rate, dur, mode);

        panOffset = this.grainPan(trig, c[\panJitter]);
        left = GrainBuf.ar(2, trig, read[\dur], read[\bufL], read[\rate], read[\pos], 2,
            (panOffset - 1).clip(-1, 1), c[\envBuf], maxGrains);
        right = GrainBuf.ar(2, trig, read[\dur], read[\bufR], read[\rate], read[\pos], 2,
            (panOffset + 1).clip(-1, 1), c[\envBuf], maxGrains);
        sig = left + right;
        sig = Balance2.ar(sig[0], sig[1], LFNoise1.kr(2).range(c[\panSpread].neg, c[\panSpread]));
        sig = this.panBalance(sig, c[\pan]);
        sig = this.voiceFilter(sig, c[\filterType], c[\filterFreq], c[\filterRes], c[\filterMix]);

        sig = sig * env * read[\level] * c[\ringLevel].lag(0.05)
            * (c[\amp] * (1 + modSig) * (1 + (accent * c[\accentAmt]))).clip(0, 2);
        this.voiceOutput(sig, c[\out], c[\mirrorOut], c[\mirrorLevel], c[\delaySend], c[\reverbSend]);
    }

    // What a ring grain reads (strataGrainRing): the ring pair, at the rate
    // clipped to +/- ringMaxRate, starting a lookback D behind the write head
    // (the frame position on phaseBus, which the writer reports at the start
    // of each block; a grain triggered later in the block only reads further
    // back). See docs/notes/engine/rings.md:
    //   continuous: D = margin + history + spread + max(r - 1, 0) x dur
    //   triggered:  dur' = min(dur, dur / (r - 1)), D = margin + history + max(r - 1, 0) x dur'
    // spread is a per-grain draw of 0 to posSpread x ringSpreadSeconds
    // (backward only: forward of the head is the future), 0 in triggered
    // mode. history is clipped to historySeconds.
    ringGrainReader { arg bufL, bufR, phaseBus, posSpread, history;
        ^{ arg trig, rate, dur, mode;
            var ringRate = rate.clip2(this.ringMaxRate);
            var ahead = (ringRate - 1).max(0);
            var length = dur + (mode * ((dur / ahead.max(1)) - dur));
            var spread = TRand.ar(0, posSpread * this.ringSpreadSeconds, trig) * (1 - mode);
            var lookback = this.ringReadMargin + history.clip(0, historySeconds) + spread + (ahead * length);
            var frames = BufFrames.kr(bufL);
            var start = (In.kr(phaseBus, 1) - (lookback * SampleRate.ir)).wrap(0, frames);
            (bufL: bufL, bufR: bufR, rate: ringRate, dur: length, pos: start / frames, level: 1)
        }
    }

    // What a buffer grain reads (strataGrainBuf): the slot pair. Rate: the
    // grain rate x bufRate x the content's rate scale. GrainBuf already
    // scales by the buffer's own rate (BufRateScale), which the server keeps
    // from the last file read even after a recording: divided out, so the
    // engine's bufRateScale applies exactly once. A grain reads
    // dur x SampleRate x |rate| x BufRateScale frames; its duration is
    // capped at the valid region (less grainEndMargin) and slotGrainPos
    // (StrataLoop.sc) starts it where it ends inside the region. While the
    // slot reads empty (bufFrames 0: cleared, reloading or recording, faded
    // out by the level) the last valid length is held, so the grains fading
    // out keep their size and place.
    slotGrainReader { arg bufnumL, bufnumR, bufFrames, bufRateScale, bufPos, bufRate, bufScan, posSpread,
        freeze, loopStart, loopLength;
        ^{ arg trig, rate, dur, mode;
            var serverScale = BufRateScale.kr(bufnumL);
            var slotRate = rate * bufRate * (bufRateScale / serverScale);
            var validFrames = Gate.kr(bufFrames, bufFrames > 0);
            var readRate = (slotRate * serverScale).abs.max(0.001);  // never 0: the duration divides by it
            var grainDur = dur.min((validFrames - grainEndMargin).max(0) / (readRate * SampleRate.ir));
            var grainFrames = grainDur * SampleRate.ir * readRate;
            var scanPhase = Phasor.ar(0, this.scanRate(bufScan, freeze) * SampleDur.ir, 0, 1);
            var spreadDraw = TRand.ar(posSpread * -0.5, posSpread * 0.5, trig);
            var start = this.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, slotRate, grainFrames, validFrames,
                loopStart, loopLength);
            (bufL: bufnumL, bufR: bufnumR, rate: slotRate, dur: grainDur,
                pos: start * (validFrames / BufFrames.kr(bufnumL)),
                // silent while the slot is empty or being recorded: every
                // grain would read position 0 and loop the take's first grain
                level: (bufFrames > 0).lag(0.05))
        }
    }
}
