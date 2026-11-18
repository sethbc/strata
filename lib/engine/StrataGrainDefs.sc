// StrataGrainDefs.sc
// The grain SynthDefs and the grains area: the window bank (3.8), the
// source -> grain SynthDef table and the history grain param. Both grain
// SynthDefs are GrainBuf pairs built by grainBody; pitch is the grain rate.
// See docs/notes/engine/grains.md.

+ Engine_Strata {
    // The longest grain any grain synth plays (s): Lua's largest grain size,
    // and the bound the rings' lookback (docs/notes/engine/rings.md) relies on
    grainMaxSeconds { ^0.5 }

    // The shortest time between two grain starts (s): a trigger sooner after
    // the last start starts no grain, so at most 125 grains of
    // grainMaxSeconds sound at once, under GrainBuf's maxGrains - 1 (past it
    // GrainBuf drops grains and prints "Too many grains"). Two retriggers on
    // one voice within it (a MIDI flood, or a chord's notes arriving in
    // separate blocks) give one grain; pattern steps (at least 50 ms apart)
    // and continuous grains (at most 200 a second: density 100 x master 2;
    // 3.8's overlap cloud, at most 250) never lose one
    grainTriggerSeconds { ^0.004 }

    // The window bank (3.8, design §4.1): windowShapes x windowSkews fixed
    // tables of windowFrames, table shape x windowSkews + skew. A shape runs
    // from pointed (0) through the Hann (windowHannShape) to flat-topped
    // (windowShapes - 1); a skew moves the peak from early (0, percussive)
    // through the middle (windowSkewMiddle, even) to late (windowSkews - 1,
    // swelling). 480 KB of ordinary RAM, the window term of
    // fixedBufferBytes (windowBankFrames, StrataPerformance.sc)
    windowShapes { ^8 }
    windowSkews { ^15 }
    windowFrames { ^1024 }
    windowHannShape { ^4 }
    windowSkewMiddle { ^(this.windowSkews - 1) div: 2 }
    // The table GrainBuf's own Hann window (-1) plays in place of: shape 4
    // at skew 0, 4 x 15 + 7
    windowHannIndex { ^(this.windowHannShape * this.windowSkews) + this.windowSkewMiddle }
    // The bank's Buffers (consecutive bufnums), the grains area's state
    windowBank { ^areaState[\grains][\windowBank] }
    // How far the outermost skews move the peak from the middle (0.5 of the
    // table): to 0.1 at skew -1, 0.9 at +1
    windowSkewReach { ^0.4 }

    // The grains area (order 30)
    strataAreaGrains {
        ^(
            order: 30,
            allocState: { this.areaCall(\allocWindowBank) },
            addDefs: { this.areaCall(\addGrainDefs); [\strataGrainRing, \strataGrainBuf] },
            // A buffer slot's voice reads it with strataGrainBuf; the synth
            // and input sources read their ring with strataGrainRing (the
            // first match wins)
            grainDefs: [
                { arg source; source.inclusivelyBetween(1, numBuffers) } -> \strataGrainBuf,
                { true } -> \strataGrainRing
            ],
            grainParamHandlers: (
                // history (s back from the input ring's head) is kept for
                // every voice but reaches only an input voice's grain synth:
                // the synth source reads its own 4 s ring at history 0
                // (grainControlPairs). Both reach the voice's extra notes too
                // (setGrainSynths)
                history: { arg voice, value;
                    grainControls[voice][\history] = value;
                    if (grainSource[voice] == this.inputSource) { this.setGrainSynths(voice, \history, value) };
                    true
                }
            ),
            free: { this.areaCall(\freeWindowBank) }
        )
    }

    // The bank, allocated once from windowBankFrames (3.8, ruling 10) at
    // consecutive bufnums, each table's /b_setn riding as its /b_alloc's
    // completion message (a bare setn could reach the server before the
    // asynchronous allocation completes), and its first bufnum kept in
    // every voice's grainControls, so each grain synth the engine starts
    // reads this engine's bank (windowBank, engine-owned). The 3.7
    // envelope buffers are gone: Engine_Strata.sc's envBuffers stays nil
    allocWindowBank {
        var count = this.windowShapes * this.windowSkews, frames = this.windowBankFrames div: count;
        var tables = this.windowTables(frames), keys = (0 .. frames - 1), first;
        areaState[\grains][\windowBank] = Buffer.allocConsecutive(count, context.server, frames, 1,
            { arg buffer, index; buffer.setnMsg(0, tables[index].at(keys)) });
        first = this.windowBank.first.bufnum;
        numVoices.do({ arg voice; grainControls[voice][\windowBank] = first });
    }

    freeWindowBank {
        (this.windowBank ? []).do({ arg buffer; buffer.free });
    }

    // The bank's tables (Signals of `frames`), table shape x windowSkews +
    // skew, from Signal primitives only (no sclang function runs per
    // sample). x runs 0 to 1 across the table; a skew warps it piecewise
    // linearly so the middle of the window falls at its peak p (0.5 at
    // skew 0, 0.5 -/+ windowSkewReach at the outermost skews), where every
    // shape is flat, so the warp leaves no corner; h = sin^2(pi x) is the
    // Hann. A shape below windowHannShape is h ^ 2^((Hann - shape) / 2)
    // (pointed, to h^4), one above it 1 - (1 - h) ^ 2^(shape - Hann)
    // (flat-topped, to 1 - (1 - h)^8, about a linen with 20 % ramps).
    // Each table is scaled to a peak of exactly 1; both ends are 0
    windowTables { arg frames;
        var ramp = Signal.newClear(frames).fill(1.0).fade(0, frames - 1, 0, frames / (frames - 1));
        ^(0 .. (this.windowShapes * this.windowSkews) - 1).collect({ arg index;
            var shape = index div: this.windowSkews, skew = index % this.windowSkews;
            var peak = 0.5 + (this.windowSkewReach * ((skew - this.windowSkewMiddle) / this.windowSkewMiddle));
            var warped = (ramp * (0.5 / peak)).min(0.5) + ((ramp - peak) * (0.5 / (1 - peak))).max(0);
            var hann = (warped * pi).sin.squared, table;
            table = case
                { shape < this.windowHannShape } { this.windowPower(hann, 2 ** ((this.windowHannShape - shape) / 2)) }
                { shape > this.windowHannShape } { this.windowPower(hann.neg + 1, 2 ** (shape - this.windowHannShape)).neg + 1 }
                { hann };
            table * (1 / table.peak)
        })
    }

    // A Signal (0 to 1) to a power above 0, as exp(power x log): sclang 3.13
    // has no pow of a Signal (3.14 has); log 0 is -inf, whose exp is 0
    windowPower { arg signal, power;
        ^(signal.max(0).log * power).exp
    }

    // The envelope number both GrainBufs of a grain synth read (GrainBuf
    // latches it with each grain): the window bank's table for the shape
    // rounded to one of windowShapes and the skew to one of windowSkews,
    // GrainBuf's own Hann (-1) at windowHannIndex (the default graph is
    // 3.7's), and envBuf in its place while it is 0 or above (an
    // engine-owned override, which only the engine check sets: a
    // rectangular envelope for its timecode reads). With no windowShape in
    // the Event (a check-only copy of an older def) envBuf alone (ruling 33)
    windowPick { arg c;
        var windowShape = c[\windowShape], windowSkew = c[\windowSkew], index, window;
        if (windowShape.isNil) { ^c[\envBuf] };
        index = ((windowShape.clip(0, 1) * (this.windowShapes - 1)).round * this.windowSkews)
            + ((windowSkew.clip(-1, 1) + 1) * this.windowSkewMiddle).round;
        window = Select.kr(BinaryOpUGen('==', index, this.windowHannIndex), [c[\windowBank] + index, -1]);
        ^Select.kr(c[\envBuf] >= 0, [window, c[\envBuf]])
    }

    // The grains per second of continuous mode: grainDensity, or with the
    // overlap cloud (overlapOn 1, 3.8 design §4.4) grainOverlap over the
    // size the grain plays (after the fast offsets and the note's size; the
    // size jitter is a per-grain draw, which cannot set the rate), within
    // 0.1 to 250. Lua sends grainOverlap with master density applied. With
    // no overlapOn in the Event (a check-only control set) grainDensity
    // alone (ruling 33). (written on the control's own name: the Lua stub
    // reads the enumeration from "overlapOn.round.clip(0, 1)")
    grainCloudRate { arg c;
        var overlapOn = c[\overlapOn];
        if (overlapOn.isNil) { ^c[\grainDensity] };
        ^Select.kr(overlapOn.round.clip(0, 1), [c[\grainDensity], (c[\grainOverlap] / c[\grainSize]).clip(0.1, 250)])
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
    // 3.4's fastModIn (named, as its default is this engine's silent fast
    // bus) is read once by fastModRead into the Event's fastMod; every grain
    // synth starts with its voice's block (grainControls, the modulation
    // area's). A buffer grain's position offset applies to bufPos before the
    // reader (fastModPosition), since bufPos is not in the Event. 3.5's note
    // controls (design 3.5 §3.2), each neutral at its default and the
    // engine's own (engineOwnedControls): noteGate (the park), noteBend,
    // noteAmp, notePos and noteSize, the note's accent (t_accent at
    // velocity), and \strataGrainRing's noteRate (a frozen synth voice's
    // note's rate; 1 in \strataGrainBuf, whose note's pitch is its own
    // bufRate). The synth-source grain synth keeps every one at its default.
    // 3.7's scan controls (scanMode, regionStart, regionLength, followRate,
    // slotGain, t_scanSync, scanSyncPhase), each at its default 3.6's graph:
    // \strataGrainBuf's reader takes them (slotGrainReader); the ring def
    // declares and ignores them, as it does the loop's. 3.8's (design §4):
    // windowShape and windowSkew (the window's pick, windowPick; at the
    // Hann's shape and skew 0 GrainBuf's own window), grainProb (every
    // grain at 1), overlapOn and grainOverlap (the density cloud at 0:
    // grainCloudRate), arpOn and arpFold (the interval draw at 0:
    // grainRate), and windowBank, the bank's first bufnum (a named control,
    // engine-owned, sent with every voice's grain controls: a def built by
    // another engine on this server has that engine's bank as its default).
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
            loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0,
            noteGate=1, noteBend=1, noteAmp=1, notePos=0, noteSize=0, velocity=1, t_accent=0, noteRate=1,
            scanMode=0, regionStart=0, regionLength=0, followRate=1, slotGain=1, t_scanSync=0, scanSyncPhase=0,
            windowShape=0.57, windowSkew=0, grainProb=1, overlapOn=0, grainOverlap=2, arpOn=0, arpFold=0;
            var windowBank = \windowBank.kr(this.windowBank.first.bufnum);
            var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
            var fastModIn = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index);
            var m = this.fastModRead(fastModIn);
            var controls = (
                out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
                posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
                t_trig: t_trig, bend: bend, kill: kill, pan: pan, rateLevel: rateLevel,
                modBuses: [modBus1, modBus2, modBus3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
                ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
                sizeJitter: sizeJitter,
                intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
                fastMod: m, noteRate: noteRate, noteSize: noteSize, noteBend: noteBend,
                noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent,
                windowBank: windowBank, windowShape: windowShape, windowSkew: windowSkew, grainProb: grainProb,
                overlapOn: overlapOn, grainOverlap: grainOverlap, arpOn: arpOn, arpFold: arpFold
            );
            this.grainBody(controls, this.areaCall(\ringGrainReader, bufL, bufR, phaseBus, posSpread, history, bufScan, freeze));
        }).add;

        // Granular processor for a buffer slot (bufnumL/R). bufPos (0-1) and
        // the scan are fractions of the voice's loop (by default the valid
        // region, bufFrames, so a short sample uses the whole range) or, 3.7,
        // of the note's region; bufScan is a speed (1: the audio's own) and
        // wraps, bounces or holds by scanMode. No grain reads past
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
            loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0,
            noteGate=1, noteBend=1, noteAmp=1, notePos=0, noteSize=0, velocity=1, t_accent=0,
            scanMode=0, regionStart=0, regionLength=0, followRate=1, slotGain=1, t_scanSync=0, scanSyncPhase=0,
            windowShape=0.57, windowSkew=0, grainProb=1, overlapOn=0, grainOverlap=2, arpOn=0, arpFold=0;
            var windowBank = \windowBank.kr(this.windowBank.first.bufnum);
            var recHeadBus = \recHeadBus.kr(areaState[\record][\idleHead].index);
            var fastModIn = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index);
            var m = this.fastModRead(fastModIn);
            // 3.7's scan controls (written on their own names: the Lua stub
            // reads the clips as the limits)
            var scan = (scanMode: scanMode, regionStart: regionStart, regionLength: regionLength,
                followRate: followRate.clip(0.25, 4).lag(0.05), slotGain: slotGain.clip(0, 16).lag(0.05),
                t_scanSync: t_scanSync, scanSyncPhase: scanSyncPhase);
            var controls = (
                out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
                posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
                t_trig: t_trig, bend: bend, kill: kill, pan: pan, rateLevel: rateLevel,
                modBuses: [modBus1, modBus2, modBus3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
                ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
                sizeJitter: sizeJitter,
                intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
                intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote,
                fastMod: m, noteRate: 1, noteSize: noteSize, noteBend: noteBend,
                noteGate: noteGate, noteAmp: noteAmp, velocity: velocity, t_accent: t_accent,
                windowBank: windowBank, windowShape: windowShape, windowSkew: windowSkew, grainProb: grainProb,
                overlapOn: overlapOn, grainOverlap: grainOverlap, arpOn: arpOn, arpFold: arpFold
            );
            this.grainBody(controls, this.areaCall(\slotGrainReader, bufnumL, bufnumR, bufFrames, bufRateScale, this.fastModPosition(bufPos, m, notePos),
                bufRate, bufScan, posSpread, freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus, scan));
        }).add;
    }

    // The grain signal both grain SynthDefs share (grainSignal) and its one
    // Out (grainBody). controls: an Event of the def's controls (the three
    // crossmod slots as Arrays, the intervals as one). reader: a function of
    // (trigger, rate, duration, mode) returning an Event of what the grains
    // read: the left and right buffers (bufL, bufR), the rate, duration and
    // start (pos, 0-1 of the buffer) each GrainBuf latches per grain, and an
    // output level (level).
    //   1. The trigger: grainCloudRate's grains per second (grainMode 0:
    //      grainDensity, or 3.8's overlap cloud) or one per t_trig (1:
    //      retrigger, pattern steps, MIDI notes), never two within
    //      grainTriggerSeconds; in continuous mode each passes grainProb.
    //   2. Rate and duration: grainRate and grainDur (StrataVariation.sc);
    //      pitchShift is the rate (an exact transposition). bend and the
    //      frequency crossmod enter it scaled by rateLevel: 0 for the synth
    //      source, whose voice synth already applies them. 3.5's noteBend
    //      (lagged noteLag) multiplies it outside rateLevel's term, so it
    //      bends every grain synth's note, quantized or not, the synth
    //      source's (a frozen synth voice's streams) included.
    //   3. Two stereo GrainBufs on windowPick's envelope, the left buffer's
    //      grains panned to -1 and the right's to +1 (plus grainPan's
    //      offset), so the pair stays
    //      sample-aligned and keeps its image; then the slow pan wander
    //      (Balance2 by panSpread) and the voice's pan (panBalance; 0 for
    //      the synth source).
    //   4. The grain synth's own fade (fade): the ASR (openedGate, released
    //      by gate), the kill fade and ringLevel (a 50 ms fade the rings
    //      area uses before overwriting a ring), then 3.5's note: the park
    //      (notePark: noteGate, 0.1 s up and grainRelease down, as the ASR)
    //      and the note's gain, noteAmp (lagged noteLag) x (1 + its accent:
    //      voiceAccent of t_accent at velocity), clipped to 0-2. The filter,
    //      the voice-level gain, the sends, the mirror and the tap are the
    //      voice's mix stage (StrataMix.sc): one Out writes this synth's path.
    // 3.4's fast modulation offsets pitch and size first (fastMod, the
    // modulation area's hook, from the Event's fastMod: the block's
    // offsets, StrataModulation.sc), with 3.5's noteRate and noteSize.
    // Returns (sig: the stereo signal, fade: its fade).
    grainSignal { arg controls, reader;
        var c = this.fastMod(controls), env, modSigs, rateMod, bendRate, grainMode, mode, trig;
        var vary, rate, dur, read, panOffset, left, right, sig, grainProb, window;

        env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(c[\gate]), doneAction: 2) * this.killFade(c[\kill]);

        // Crossmod (rate only; the amplitude crossmod is the stage's):
        // clamped as the voices' frequency is (crossmodFreq), kept positive,
        // by rateLevel
        modSigs = c[\modBuses].collect({ arg bus; In.kr(bus, 1) });
        rateMod = this.crossmodFreq(modSigs, c[\modFreqAmts]);
        bendRate = (1 + (c[\rateLevel] * ((c[\bend] * (1 + rateMod)) - 1))) * c[\noteBend].lag(this.noteLag);

        // (written on the control's own name: the Lua stub reads the
        // enumeration from "grainMode.round.clip(0, 1)")
        grainMode = c[\grainMode];
        mode = grainMode.round.clip(0, 1);
        // (Trig1 holds the trigger high and ignores any other meanwhile:
        // every grain input reads its rising edge. It refuses a trigger
        // until its counter, round(duration x the rate) samples, has run out
        // a sample after the hold ends, so the hold is a sample shorter than
        // grainTriggerSeconds: two starts are at least grainTriggerSeconds
        // apart, and an Impulse of exactly 1 / grainTriggerSeconds, the
        // overlap cloud's 250 a second, loses no grain)
        trig = Trig1.ar(Select.ar(mode, [Impulse.ar(this.grainCloudRate(c)), T2A.ar(c[\t_trig])]),
            this.grainTriggerSeconds - SampleDur.ir);
        // 3.8's probability (design §4.2): in continuous mode each held
        // trigger passes a draw (a dropped one still held its window, and
        // draws nothing downstream: no rate, size or pan, no arpeggio
        // step); in triggered mode (mode 1) every one passes
        if (c[\grainProb].notNil) {
            grainProb = c[\grainProb];
            trig = trig * (TRand.ar(0, 1, trig) < grainProb.max(mode));
        };

        vary = (
            reverseProb: c[\reverseProb], pitchJitter: c[\pitchJitter], intervals: c[\intervals],
            intervalCount: c[\intervalCount], intervalProb: c[\intervalProb], quantize: c[\quantize], scaleNote: c[\scaleNote],
            arpOn: c[\arpOn], arpFold: c[\arpFold]
        );
        rate = this.grainRate(trig, c[\pitchShift], bendRate, vary);
        dur = this.grainDur(trig, c[\grainSize], c[\sizeJitter]).min(this.grainMaxSeconds);
        read = reader.value(trig, rate, dur, mode);

        panOffset = this.grainPan(trig, c[\panJitter]);
        window = this.windowPick(c);
        left = GrainBuf.ar(2, trig, read[\dur], read[\bufL], read[\rate], read[\pos], 2,
            (panOffset - 1).clip(-1, 1), window, maxGrains);
        right = GrainBuf.ar(2, trig, read[\dur], read[\bufR], read[\rate], read[\pos], 2,
            (panOffset + 1).clip(-1, 1), window, maxGrains);
        sig = left + right;
        sig = Balance2.ar(sig[0], sig[1], LFNoise1.kr(2).range(c[\panSpread].neg, c[\panSpread]));
        sig = this.panBalance(sig, c[\pan]);

        ^(sig: sig, fade: env * read[\level] * c[\ringLevel].lag(0.05) * this.notePark(c[\noteGate], 0.1, grainRelease)
            * (c[\noteAmp].lag(this.noteLag) * (1 + this.voiceAccent(c[\t_accent], c[\velocity]))).clip(0, 2))
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
    // The head, the ring's frames, the history and the freeze flag are each
    // held for the block (Latch on a block-rate tick, as slotHeadGuard holds
    // its head),
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
            // the freeze flag held for the block too: an unfreeze sends
            // freeze 0 in the block it points the reader back at the input
            // ring, and ringScanOffset's control-rate flag times its
            // audio-rate offset would ramp across that block
            var lookback = this.ringReadMargin + Latch.ar(history.clip(0, historySeconds), tick) + spread + (ahead * length)
                + this.ringScanOffset(bufScan, Latch.ar(freeze, tick));
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
    // 3.7 (design §2, §3.4, §4.4): scan, an Event of the def's scan
    // controls (nil for a check-only reader: wrap, the loop, no follow rate,
    // no gain, no sync), becomes the scan state (slotScanState): the scan's
    // mode, its span (a note's region in the loop's place while
    // regionLength > 0), the follow rate on the read rate (after the
    // quantize: rate arrives quantized and bent) and the slot's gain on the
    // level, beside the one-shot's (oneShotLevel). The scan is a speed for
    // every slot reader: its phase crosses the span in the span's own length
    // at a scan of 1 (slotScanSpeed).
    slotGrainReader { arg bufnumL, bufnumR, bufFrames, bufRateScale, bufPos, bufRate, bufScan, posSpread,
        freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus, scan;
        ^{ arg trig, rate, dur, mode;
            var state = scan !? { this.slotScanState(scan, loopStart, loopLength) };
            var span = if (state.isNil) { this.slotSpan(loopStart, loopLength) } { [state[\first], state[\last]] };
            var serverScale = BufRateScale.kr(bufnumL);
            var unfollowed = rate * bufRate * (bufRateScale / serverScale);
            var slotRate = if (state.isNil) { unfollowed } { unfollowed * state[\followRate] };
            var validFrames = Gate.kr(bufFrames, bufFrames > 0);
            // the rate in slot frames per output frame, signed: what the
            // loop's direction test and the head guard need (slotRate is
            // GrainBuf's argument, divided by the server's BufRateScale,
            // which outlives a clear and a recording)
            var frameRate = slotRate * serverScale;
            var readRate = frameRate.abs.max(0.001);  // never 0: the duration divides by it
            var grainDur = dur.min((validFrames - grainEndMargin).max(0) / (readRate * SampleRate.ir));
            var grainFrames = grainDur * SampleRate.ir * readRate;
            var scanPhase = this.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_scanReset,
                this.slotScanSpeed(bufRateScale, (span[1] - span[0]) * validFrames), state);
            var spreadDraw = TRand.ar(posSpread * -0.5, posSpread * 0.5, trig);
            var start, level;
            // (bufPos + the phase, which the position and the one-shot level share)
            if (state.notNil) { state[\sum] = bufPos + scanPhase };
            start = this.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, frameRate, grainFrames, validFrames,
                loopStart, loopLength, recHeadBus, state);
            // silent while the slot is empty or being recorded: every
            // grain would read position 0 and loop the take's first grain
            level = (bufFrames > 0).lag(0.05);
            if (state.notNil) { level = level * state[\slotGain] * this.oneShotLevel(state) };
            (bufL: bufnumL, bufR: bufnumR, rate: slotRate, dur: grainDur,
                pos: start * (validFrames / BufFrames.kr(bufnumL)),
                level: level)
        }
    }
}
