// StrataGrainDefs.sc
// The grain SynthDefs and the grains area: the envelope buffers, the
// source -> grain SynthDef table and the envShape and history grain
// params. Both grain SynthDefs are GrainBuf pairs built by grainBody; pitch
// is the grain rate. See docs/notes/engine/grains.md.

+ Engine_Strata {
    // The longest grain any grain synth plays (s): Lua's largest grain size,
    // and the bound the rings' lookback (docs/notes/engine/rings.md) relies on
    grainMaxSeconds { ^0.5 }

    // The shortest time between two grain starts (s): a trigger sooner after
    // the last start starts no grain, so at most 125 grains of
    // grainMaxSeconds sound at once, under GrainBuf's maxGrains - 1 (past it
    // GrainBuf drops grains and prints "Too many grains"). Only a flood of
    // retriggers comes this close (more than 250 a second: a MIDI flood);
    // continuous grains come at most 200 a second (density 100 x master 2)
    grainTriggerSeconds { ^0.004 }

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
    // starts. The 3.2 controls past today's (history ...) have neutral
    // defaults: no variation, the whole slot as the loop, no freeze. The
    // voice filter, level, sends, mirror and tap are the voice's stage
    // (StrataMix.sc). 3.3's: scrubRate, scanHold and
    // t_scanReset default to no scrub, and recHeadBus (a named control, as
    // its default is this engine's idle head bus: the record area's) to the
    // idle head; the engine sends a buffer synth its slot's (slotLengthPairs).
    addGrainDefs {
        // Granular processor for a ring: the voice's own (synth source) or
        // the input's (input source), each written by a strataRingWrite
        // (StrataRings.sc) whose frame position is on phaseBus. Grains start
        // behind the write head (ringGrainReader).
        SynthDef(\strataGrainRing, {
            arg out, gate=1, bufL=0, bufR=0, phaseBus=0, bufScan=0,
            grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
            envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
            modBus1=0, modBus2=0, modBus3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            history=0, ringLevel=1, freeze=0, freezeMode=0,
            reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
            interval1=0, interval2=0, interval3=0, interval4=0,
            interval5=0, interval6=0, interval7=0, interval8=0,
            intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
            loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0;
            var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
            var controls = (
                out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
                posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
                t_trig: t_trig, bend: bend, kill: kill, pan: pan, rateLevel: rateLevel,
                modBuses: [modBus1, modBus2, modBus3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
                ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
                sizeJitter: sizeJitter,
                intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote
            );
            this.grainBody(controls, this.ringGrainReader(bufL, bufR, phaseBus, posSpread, history, bufScan, freeze));
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
            envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
            modBus1=0, modBus2=0, modBus3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            history=0, ringLevel=1, freeze=0, freezeMode=0,
            reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
            interval1=0, interval2=0, interval3=0, interval4=0,
            interval5=0, interval6=0, interval7=0, interval8=0,
            intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
            loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0;
            var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
            var controls = (
                out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
                posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
                t_trig: t_trig, bend: bend, kill: kill, pan: pan, rateLevel: rateLevel,
                modBuses: [modBus1, modBus2, modBus3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
                ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
                sizeJitter: sizeJitter,
                intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote
            );
            this.grainBody(controls, this.slotGrainReader(bufnumL, bufnumR, bufFrames, bufRateScale, bufPos, bufRate,
                bufScan, posSpread, freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus));
        }).add;
    }

    // The grain signal both grain SynthDefs share (grainSignal) and its one
    // Out (grainBody). controls: an Event of the def's controls (the three
    // crossmod slots as Arrays, the intervals as one). reader: a function of
    // (trigger, rate, duration, mode) returning an Event of what the grains
    // read: the left and right buffers (bufL, bufR), the rate, duration and
    // start (pos, 0-1 of the buffer) each GrainBuf latches per grain, and an
    // output level (level).
    //   1. The trigger: grainDensity grains per second (grainMode 0) or one
    //      per t_trig (1: retrigger, pattern steps, MIDI notes), never two
    //      within grainTriggerSeconds.
    //   2. Rate and duration: grainRate and grainDur (StrataVariation.sc);
    //      pitchShift is the rate (an exact transposition). bend and the
    //      frequency crossmod enter it scaled by rateLevel: 0 for the synth
    //      source, whose voice synth already applies them.
    //   3. Two stereo GrainBufs, the left buffer's grains panned to -1 and
    //      the right's to +1 (plus grainPan's offset), so the pair stays
    //      sample-aligned and keeps its image; then the slow pan wander
    //      (Balance2 by panSpread) and the voice's pan (panBalance; 0 for
    //      the synth source).
    //   4. The grain synth's own fade (fade): the ASR (openedGate, released
    //      by gate), the kill fade and ringLevel (a 50 ms fade the rings
    //      area uses before overwriting a ring). The filter, the voice-level
    //      gain, the sends, the mirror and the tap are the voice's mix stage
    //      (StrataMix.sc): one Out writes this synth's path.
    // Returns (sig: the stereo signal, fade: its fade).
    grainSignal { arg controls, reader;
        var c = controls, env, modSigs, rateMod, bendRate, grainMode, mode, trig;
        var vary, rate, dur, read, panOffset, left, right, sig;

        env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(c[\gate]), doneAction: 2) * this.killFade(c[\kill]);

        // Crossmod (rate only; the amplitude crossmod is the stage's):
        // clamped like the voices', kept positive, by rateLevel
        modSigs = c[\modBuses].collect({ arg bus; In.kr(bus, 1) });
        rateMod = (modSigs * c[\modFreqAmts]).sum.clip(-0.9, 2);
        bendRate = 1 + (c[\rateLevel] * ((c[\bend] * (1 + rateMod)) - 1));

        // (written on the control's own name: the Lua stub reads the
        // enumeration from "grainMode.round.clip(0, 1)")
        grainMode = c[\grainMode];
        mode = grainMode.round.clip(0, 1);
        // (Trig1 holds the trigger high for grainTriggerSeconds and ignores
        // any other meanwhile: every grain input reads its rising edge)
        trig = Trig1.ar(Select.ar(mode, [Impulse.ar(c[\grainDensity]), T2A.ar(c[\t_trig])]), this.grainTriggerSeconds);

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

        ^(sig: sig, fade: env * read[\level] * c[\ringLevel].lag(0.05))
    }

    // One grain synth's output: its signal times its own fade, on the path
    // of its source (StrataMix.sc)
    grainBody { arg controls, reader;
        var result = this.grainSignal(controls, reader);
        Out.ar(controls[\out], result[\sig] * result[\fade]);
    }

    // What a ring grain reads (strataGrainRing): the ring pair, at the rate
    // clipped to +/- ringMaxRate, starting a lookback D and one block behind
    // the write head (the frame position on phaseBus, which the writer
    // reports at the start of each block). See docs/notes/engine/rings.md:
    //   continuous: D = margin + history + spread + max(r - 1, 0) x dur
    //   triggered:  dur' = min(dur, dur / (r - 1)), D = margin + history + max(r - 1, 0) x dur'
    // spread is a per-grain draw of 0 to posSpread x ringSpreadSeconds
    // (backward only: forward of the head is the future), 0 in triggered
    // mode. history is clipped to historySeconds. ringScanOffset (the
    // freeze area's hook; neutral 0) moves the read point further back by
    // the voice's scan, for a frozen ring.
    // The head, the ring's frames and the history are each held for the
    // block (Latch on a block-rate tick, as slotHeadGuard holds its head),
    // and while the head advanced by one block since the last (the writer
    // runs; counted round the ring, so across its wrap too) the sample's
    // offset in the block is added: a grain starts at head - one block +
    // offset - D, the true head one block late, the same distance behind
    // it wherever in the block its trigger falls (grains at one rate stay
    // in phase; never the head held alone). A head that did not advance by
    // a block (a paused writer, a frozen copy's, or a reader just pointed
    // at another ring: rings, phase bus and history in one message) gets
    // no offset, so its grains start at one point, the new ring's, never
    // between the old read point and the new one. HPZ1.kr(head) x 2 is the
    // head's step since the last block (its one sample of state is the
    // last block's head).
    ringGrainReader { arg bufL, bufR, phaseBus, posSpread, history, bufScan, freeze;
        ^{ arg trig, rate, dur, mode;
            var block = context.server.options.blockSize, tick = Impulse.ar(ControlRate.ir);
            var ringRate = rate.clip2(this.ringMaxRate);
            var ahead = (ringRate - 1).max(0);
            var length = dur + (mode * ((dur / ahead.max(1)) - dur));
            var spread = TRand.ar(0, posSpread * this.ringSpreadSeconds, trig) * (1 - mode);
            var head = In.kr(phaseBus, 1), frames = BufFrames.kr(bufL);
            var lookback = this.ringReadMargin + Latch.ar(history.clip(0, historySeconds), tick) + spread + (ahead * length)
                + this.ringScanOffset(bufScan, freeze);
            var advanced = Latch.ar((HPZ1.kr(head) * 2).wrap(0, frames).absdif(block) < 0.5, tick);
            var offset = advanced * (Phasor.ar(0, 1, 0, block) - block);
            var heldFrames = Latch.ar(frames, tick);
            var start = ((Latch.ar(head, tick) + offset) - (lookback * SampleRate.ir)).wrap(0, heldFrames);
            // The start as a fraction of the ring: divided by the
            // control-rate frame count, as 3.2 did (a steady control-rate
            // divisor rounds in the last bit unlike an audio-rate one), but
            // in the block the count changes (a reader pointed at a ring of
            // another length) by the held frames: a changing control-rate
            // count ramps across the block
            var pos = Select.ar(HPZ1.kr(frames).abs > 0, [start / frames, start / heldFrames]);
            (bufL: bufL, bufR: bufR, rate: ringRate, dur: length, pos: pos, level: 1)
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
        freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus;
        ^{ arg trig, rate, dur, mode;
            var serverScale = BufRateScale.kr(bufnumL);
            var slotRate = rate * bufRate * (bufRateScale / serverScale);
            var validFrames = Gate.kr(bufFrames, bufFrames > 0);
            // the rate in slot frames per output frame, signed: what the
            // loop's direction test and the head guard need (slotRate is
            // GrainBuf's argument, divided by the server's BufRateScale,
            // which outlives a clear and a recording)
            var frameRate = slotRate * serverScale;
            var readRate = frameRate.abs.max(0.001);  // never 0: the duration divides by it
            var grainDur = dur.min((validFrames - grainEndMargin).max(0) / (readRate * SampleRate.ir));
            var grainFrames = grainDur * SampleRate.ir * readRate;
            var scanPhase = this.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_scanReset);
            var spreadDraw = TRand.ar(posSpread * -0.5, posSpread * 0.5, trig);
            var start = this.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, frameRate, grainFrames, validFrames,
                loopStart, loopLength, recHeadBus);
            (bufL: bufnumL, bufR: bufnumR, rate: slotRate, dur: grainDur,
                pos: start * (validFrames / BufFrames.kr(bufnumL)),
                // silent while the slot is empty or being recorded: every
                // grain would read position 0 and loop the take's first grain
                level: (bufFrames > 0).lag(0.05))
        }
    }
}
