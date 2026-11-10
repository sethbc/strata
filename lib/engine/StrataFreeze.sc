// StrataFreeze.sc
// The freeze area: holding what a voice's grains read. The freeze and
// freezeMode grain params (Lua's v<i>_freeze, v<i>_freeze_mode) hold:
// - a synth voice's ring: its writer paused (hold) or replaced by a
//   spectral writer that keeps writing one held spectrum (spectral, high
//   tier only);
// - an input voice's last 4 s: copied from the input ring into the voice's
//   own ring, which its grain synth then reads at history 0 (hold), or which
//   a spectral writer of the input then continues (spectral);
// - a buffer voice's scan: stopped (scanRate).
// Spectral asked for on the standard tier, or for a buffer voice, holds.
// See docs/notes/engine/freeze.md.

+ Engine_Strata {
    // The spectral writer's FFT size (frames)
    spectralFrames { ^2048 }

    // The spectral writer's analysis dither (amplitude, about -100 dBFS)
    spectralDither { ^0.00001 }

    // How long an input grain synth set back from the voice ring to the
    // input ring still counts as reading the voice ring (s): its longest
    // grain, started just before, plus the read margin
    freezeLeaveSeconds { ^this.grainMaxSeconds + this.ringReadMargin }

    // The freeze area (order 110). Its handlers act, then return false, so
    // setGrainParam also stores the control and sends it to the grain
    // synth (freeze stops a slot's scan and scans a frozen ring there).
    strataAreaFreeze {
        ^(
            order: 110,
            allocState: { this.allocFreezeState },
            addDefs: { this.addFreezeDefs; [] },
            grainParamHandlers: (
                freeze: { arg voice, value;
                    if (value > 0.5) { this.freezeVoice(voice) } { this.unfreezeVoice(voice) };
                    false
                },
                freezeMode: { arg voice, value; this.setFreezeMode(voice, value); false }
            ),
            stop: { areaState[\freeze][\stopped] = true },
            free: { this.freeSpectralBuffers }
        )
    }

    // areaState[\freeze], per voice: \frozen (Boolean), \mode (\hold or
    // \spectral while frozen, else nil), \source (the source it froze),
    // \copied (an input voice's copy is in its ring and its grain synth
    // reads it), \copies (the number of its latest input copy), \faded
    // (ring readers a pending copy set to ringLevel 0). \inputReaders: the
    // input grain synths that read their voice ring's copy (pointed at it,
    // started on it or re-gated onto it: noteInputReader) -> (voice, until:
    // nil while they do, the time they stop counting once set back);
    // pruned when a synth frees (forgetInputReader).
    // \spectralBuffers: on the high tier, each voice's [left, right] FFT
    // buffers for its spectral writer (see addFreezeDefs), else empty.
    allocFreezeState {
        var state = areaState[\freeze], historyHandler;
        state[\spectralBuffers] = if (tier == \high) {
            Array.fill(numVoices, { Array.fill(2, { Buffer.alloc(context.server, this.spectralFrames, 1) }) })
        } { [] };
        state[\frozen] = Array.fill(numVoices, false);
        state[\mode] = Array.newClear(numVoices);
        state[\source] = Array.newClear(numVoices);
        state[\copied] = Array.fill(numVoices, false);
        state[\copies] = Array.fill(numVoices, 0);
        state[\faded] = Array.fill(numVoices, { IdentitySet.new });
        state[\inputReaders] = IdentityDictionary.new;
        state[\stopped] = false;
        // Inside a frozen input copy history is 0: a history change is kept
        // (it applies again on unfreeze) but not sent while the voice is
        // frozen on the input. The grains area's handler does the rest.
        // This relies on alloc building grainParamHandlers from every area
        // before any allocState runs (so the grains area's handler is there
        // to wrap, whatever the orders), and on no other area wrapping or
        // replacing \history (two areas registering it is an error).
        historyHandler = grainParamHandlers[\history];
        grainParamHandlers[\history] = { arg voice, value;
            if (this.frozenOnInput(voice)) {
                grainControls[voice][\history] = value;
                true
            } { historyHandler.notNil and: { historyHandler.value(voice, value) == true } }
        };
    }

    // The spectral writer, high tier only: \strataRingWrite's controls and
    // phase, with each channel through FFT -> PV_MagFreeze -> IFFT. It
    // writes the input itself until the analysis has run two windows (the
    // IFFT's latency, and PV_MagFreeze then holds a real spectrum), then
    // crossfades over 10 ms to the held spectrum, so the ring never gets a
    // gap. Both the input and the output go through zeroBadValues.
    // The FFT buffers are the voice's \spectralBuffers (fftL, fftR), never
    // a LocalBuf: building a LocalBuf into this def corrupts sclang 3.13's
    // garbage collector (norns' version), which then aborts sclang a little
    // later. One writer per voice (Synth.replace), so a voice's pair is
    // never shared.
    addFreezeDefs {
        var window = this.spectralFrames;
        if (tier != \high) { ^this };
        SynthDef(\strataRingWriteSpectral, {
            arg in, bufL, bufR, phaseOut, fftL, fftR;
            var dry = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel) });
            var settle = 2 * window * SampleDur.ir;
            var held = Line.kr(0, 1, settle) >= 1;
            // the analysis gets a dither about 100 dB down: on exact digital
            // silence PV_MagFreeze would hold zero phases (a buzz at the hop
            // rate); under any real sound it is inaudible
            var wet = [dry, [fftL, fftR]].flop.collect({ arg pair;
                var chain = FFT(pair[1], pair[0] + WhiteNoise.ar(this.spectralDither), 0.5);
                this.zeroBadValues(IFFT(PV_MagFreeze(chain, held)))
            });
            var mix = EnvGen.kr(Env([0, 0, 1], [settle, 0.01]));
            var sig = [dry, wet].flop.collect({ arg pair; XFade2.ar(pair[0], pair[1], mix * 2 - 1) });
            var phase = Phasor.ar(Impulse.ar(0), 1, 0, BufFrames.kr(bufL), In.kr(phaseOut));
            BufWr.ar(sig[0], bufL, phase);
            BufWr.ar(sig[1], bufR, phase);
            Out.kr(phaseOut, A2K.kr(phase));
        }).add;
    }

    // The rate of a buffer grain synth's position scan (valid-region
    // lengths per second): stopped while frozen
    scanRate { arg bufScan, freeze;
        ^bufScan * (1 - freeze)
    }

    // How much further back (s) a ring grain synth starts its grains: 0
    // unless frozen. A frozen ring's head no longer moves, so a grain must
    // start at least its own length behind it, or it would read across the
    // seam into the ring's oldest audio: grainMaxSeconds (0.5 s) covers any
    // grain's forward reach, max(r - 1, 0) x dur being in the lookback
    // already. Then bufScan moves the read point back through the ring
    // (ring lengths per second; a negative scan moves it forward) from
    // where the freeze began, wrapping: the ring holds valid audio all
    // round. Moving back, the grains play about 3.5 s of continuous audio
    // before the read point crosses the seam (into the newest audio again),
    // once per ring length of travel.
    ringScanOffset { arg bufScan, freeze;
        var held = freeze > 0.5;
        var scan = Phasor.ar(K2A.ar(held), bufScan * SampleDur.ir, 0, 1);
        ^held * (this.grainMaxSeconds + (scan * this.ringSeconds))
    }

    // Whether the voice is frozen with an input ring copy (or spectral
    // writer of the input) as what its grains read: its history is then 0
    frozenOnInput { arg voice;
        var state = areaState[\freeze];
        ^this.validVoice(voice) and: { state[\frozen][voice] } and: { state[\source][voice] == this.inputSource }
    }

    // The mode a freeze of the voice uses: spectral only on the high tier,
    // when freezeMode asks for it and the voice reads a ring
    freezeModeFor { arg voice;
        var source = grainSource[voice];
        if ((tier == \high) and: { (grainControls[voice][\freezeMode] ? 0) >= 0.5 }
            and: { source.inclusivelyBetween(1, numBuffers).not }) { ^\spectral };
        ^\hold
    }

    // freezeMode: kept, and a frozen voice whose mode changes is frozen again
    // in the new one
    setFreezeMode { arg voice, value;
        var state = areaState[\freeze];
        if (this.validVoice(voice).not) { ^this };
        grainControls[voice][\freezeMode] = value;
        if (state[\frozen][voice] and: { state[\mode][voice] != this.freezeModeFor(voice) }) {
            this.unfreezeVoice(voice);
            this.freezeVoice(voice);
        };
    }

    // Freeze a voice's source (the freeze grain param). A voice already
    // frozen on this source in this mode keeps its freeze; its live grain
    // synth is only pointed at the copy again (Lua resends freeze after
    // voiceOn; the grain synth voiceOn starts or re-gates already reads it:
    // grainReadPairs). Frozen on another source or mode (the source changed
    // while the voice was stopped), it is unfrozen first. Each freeze is a
    // ring change, so a copy still waiting for an earlier freeze never runs.
    freezeVoice { arg voice;
        var state = areaState[\freeze], mode, source;
        if (this.validVoice(voice).not) { ^this };
        mode = this.freezeModeFor(voice);
        source = grainSource[voice];
        if (state[\frozen][voice] and: { (state[\mode][voice] != mode) or: { state[\source][voice] != source } }) {
            this.unfreezeVoice(voice);
        };
        if (state[\frozen][voice]) {
            if ((source == this.inputSource) and: { state[\copied][voice] }) { this.pointAtVoiceRing(voice) };
            ^this
        };
        state[\frozen][voice] = true;
        // kept, so a grain synth a start or re-gate builds is frozen too
        // (unfreezeVoice keeps 0; a mode change unfreezes, then freezes)
        grainControls[voice][\freeze] = 1;
        state[\mode][voice] = mode;
        state[\source][voice] = source;
        this.ringChanges[voice] = this.ringChanges[voice] + 1;
        case
        { source == 0 } {
            if (mode == \spectral) {
                this.replaceRingWriter(voice, \strataRingWriteSpectral, granBuses[voice])
            } { this.pauseRingWriter(voice) };
        }
        { source == this.inputSource } {
            this.pauseRingWriter(voice);
            this.copyInputToVoiceRing(voice);
        };
        // a slot: the grain synth's freeze control stops its scan (scanRate)
    }

    // Undo freezeVoice. replaceGrainSynth calls it before every source
    // switch of a running voice (grainSource is the new source by then).
    // The voice's writer resumes: a paused one from its own phase, a
    // replaced one (spectral, or an input copy's, whose phase bus points at
    // the copy's end) from its phase bus, so it writes over the copy's
    // oldest audio first. A grain synth reading an input copy is set back
    // to the input ring at the voice's history. The kept freeze control is
    // 0, so a grain synth the switch starts is unfrozen.
    unfreezeVoice { arg voice;
        var state = areaState[\freeze], source, mode;
        if (this.validVoice(voice).not or: { state[\frozen][voice].not }) { ^this };
        source = state[\source][voice];
        mode = state[\mode][voice];
        state[\frozen][voice] = false;
        state[\mode][voice] = nil;
        state[\source][voice] = nil;
        state[\copied][voice] = false;
        this.ringChanges[voice] = this.ringChanges[voice] + 1;
        grainControls[voice][\freeze] = 0;
        case
        { source == 0 } {
            if (mode == \spectral) {
                this.replaceRingWriter(voice, \strataRingWrite, granBuses[voice])
            } { this.resumeRingWriter(voice) };
        }
        { source == this.inputSource } {
            this.replaceRingWriter(voice, \strataRingWrite, granBuses[voice]);
            this.returnToInputRing(voice);
        };
    }

    // The voice's ring writer (a persistent effectKeys synth: plain messages)
    ringWriterFor { arg voice;
        ^synths[this.ringWriterKeys[voice]]
    }

    pauseRingWriter { arg voice;
        this.ringWriterFor(voice) !? { arg writer; writer.run(false) };
    }

    resumeRingWriter { arg voice;
        this.ringWriterFor(voice) !? { arg writer; writer.run(true) };
    }

    // Replace the voice's ring writer with one of defName reading the bus
    // in (Synth.replace frees the old one in the same server step); the new
    // one starts from the phase on its bus
    replaceRingWriter { arg voice, defName, in;
        var key = this.ringWriterKeys[voice], old = synths[key], ring = this.ringBuffersFor(voice, 0), writer;
        var args = [\in, in, \bufL, ring[0], \bufR, ring[1], \phaseOut, ring[2]], fft;
        if (old.isNil or: { areaState[\freeze][\stopped] ? false }) { ^this };
        if (defName == \strataRingWriteSpectral) {
            fft = areaState[\freeze][\spectralBuffers][voice];
            if (fft.isNil) { ^this };
            args = args ++ [\fftL, fft[0], \fftR, fft[1]];
        };
        writer = Synth.replace(old, defName, args);
        synths[key] = writer;
        areaState[\rings][\writers][voice] = writer;
    }

    freeSpectralBuffers {
        areaState[\freeze][\spectralBuffers].do({ arg pair; pair.do(_.free) });
        areaState[\freeze][\spectralBuffers] = [];
    }

    // The voice's ring readers that read its own ring, playing: its
    // \strataGrainRing synths (ringReaders) other than the live input grain
    // synth reading the input ring, plus the input grain synths set to read
    // the voice ring (inputReaders) until freezeLeaveSeconds after they were
    // set back. (ringReaders also keeps input grain synths that read the
    // input ring; an earlier one, fading, counts here too: at worst a copy
    // waits for nothing.)
    voiceRingReaders { arg voice;
        var held = areaState[\freeze][\inputReaders], now = SystemClock.seconds, live = synths[this.grainKey(voice)];
        held.keys.copy.do({ arg synth;
            var entry = held[synth];
            if (synth.isPlaying.not or: { entry[\until].notNil and: { entry[\until] <= now } }) { held.removeAt(synth) };
        });
        ^this.ringReaders.keys.select({ arg synth;
            (this.ringReaders[synth] == voice) and: { synth.isPlaying } and: {
                held[synth].notNil or: { (synth === live and: { grainSource[voice] == this.inputSource }).not }
            }
        }).asArray
    }

    // An input voice's hold: the 4 s of the input ring ending at its read
    // point (the head minus ringReadMargin + history) copied into the
    // voice's ring (paused by now), then the voice's phase bus set to the
    // copy's end and its live grain synth set to read the copy. Fade before
    // overwriting: the voice ring's readers get ringLevel 0 and the copy
    // waits bufferFadeWait when any plays, and goes ahead at once otherwise.
    // Each step runs only while ringChanges[voice] is unchanged and no later
    // copy started (an unfreeze or switch wins). The faded readers get
    // ringLevel 1 back once the copy is in (or abandoned), by the latest
    // copy only.
    copyInputToVoiceRing { arg voice;
        var state = areaState[\freeze], change = this.ringChanges[voice], copy = state[\copies][voice] + 1;
        var readers = this.voiceRingReaders(voice), server = context.server;
        var current = { (state[\copies][voice] == copy) and: { this.ringChanges[voice] == change }
            and: { (state[\stopped] ? false).not } };
        state[\copies][voice] = copy;
        readers.do({ arg synth;
            state[\faded][voice].add(synth);
            this.sendToSynth(synth.setMsg(\ringLevel, 0));
        });
        fork({
            var head;
            if (readers.notEmpty) { bufferFadeWait.wait };
            if (current.value) { head = this.inputHeadFrame };
            if (current.value and: { head.notNil }) {
                this.copyInputSpan(voice, head);
                server.sync;  // answered once both channels' copies are done
                if (current.value) { this.holdVoiceRing(voice) };
            };
            if ((state[\copies][voice] == copy) and: { (state[\stopped] ? false).not }) {
                this.restoreFadedReaders(voice);
            };
        }, SystemClock);
    }

    // The input writer's frame now (its phase bus), inside a routine; nil if
    // the server does not answer
    inputHeadFrame {
        var condition = Condition(false), value;
        areaState[\rings][\phaseBuses][numVoices].get({ arg frame; value = frame; condition.test = true; condition.signal });
        SystemClock.sched(1, { condition.test = true; condition.signal; nil });
        condition.wait;
        ^value
    }

    // Copy the 4 s of the input ring ending ringReadMargin + history before
    // head into the voice's ring, oldest first from frame 0: one /b_gen copy
    // per channel, two when the span wraps the input ring's end
    copyInputSpan { arg voice, head;
        var rings = areaState[\rings], sampleRate = context.server.sampleRate;
        var inputFrames = rings[\inputL].numFrames, voiceFrames = rings[\voiceL][voice].numFrames;
        var history = (grainControls[voice][\history] ? 0).clip(0, historySeconds);
        var end = (head - ((this.ringReadMargin + history) * sampleRate)).round.asInteger.mod(inputFrames);
        var start = end - voiceFrames;
        // [source frame, voice ring frame, frames]
        var spans = if (start >= 0) { [[start, 0, voiceFrames]] } {
            [[start + inputFrames, 0, start.neg], [0, start.neg, end]]
        };
        spans.do({ arg span;
            if (span[2] > 0) {
                rings[\inputL].copyData(rings[\voiceL][voice], span[1], span[0], span[2]);
                rings[\inputR].copyData(rings[\voiceR][voice], span[1], span[0], span[2]);
            };
        });
    }

    // The copy is in: the voice's phase bus at its end (frame 0 = the
    // ring's length) and the live grain synth reading it; spectral starts
    // its writer of the input from there
    holdVoiceRing { arg voice;
        var state = areaState[\freeze];
        areaState[\rings][\phaseBuses][voice].set(0);
        if (state[\mode][voice] == \spectral) { this.replaceRingWriter(voice, \strataRingWriteSpectral, inputBus) };
        state[\copied][voice] = true;
        this.pointAtVoiceRing(voice);
    }

    // Set the voice's live input grain synth to read what grainReadPairs
    // says (the copy, once it is in: the voice ring at history 0; GrainBuf
    // latches its buffer per grain: seamless), and count it among the voice
    // ring's readers
    pointAtVoiceRing { arg voice;
        var synth = synths[this.grainKey(voice)];
        if (synth.isNil or: { grainSource[voice] != this.inputSource }) { ^this };
        this.sendToSynth(synth.setMsg(*this.grainReadPairs(voice)));
        this.noteInputReader(voice, synth);
    }

    // Whether the voice's grain synth reads its input copy: the voice is on
    // the input, frozen on the input, and the copy is in its ring
    readsInputCopy { arg voice;
        ^(grainSource[voice] == this.inputSource) and: { this.frozenOnInput(voice) }
            and: { areaState[\freeze][\copied][voice] }
    }

    // What a voice's ring grain synth reads, as strataGrainRing controls:
    // the one answer the start, the re-gate (grainControlPairs) and a freeze
    // (pointAtVoiceRing) all send. The synth source reads its voice's 4 s
    // ring at history 0 (history is for the input ring, so a voice that
    // leaves the input never reads a wrapped ring); the input source the
    // input ring at the voice's history, or its frozen copy (the voice
    // ring) at history 0; a buffer source nothing (empty).
    grainReadPairs { arg voice;
        var source = grainSource[voice], ring, history = 0;
        case
        { source == 0 } { ring = this.ringBuffersFor(voice, 0) }
        { source == this.inputSource } {
            if (this.readsInputCopy(voice)) { ring = this.ringBuffersFor(voice, 0) } {
                ring = this.ringBuffersFor(voice, source);
                history = grainControls[voice][\history] ? 0;
            };
        }
        { ^[] };
        ^[\bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index, \history, history]
    }

    // Count a grain synth among the voice ring's readers (inputReaders)
    // while it reads the voice's input copy
    noteInputReader { arg voice, synth;
        if (this.readsInputCopy(voice)) { areaState[\freeze][\inputReaders][synth] = (voice: voice, until: nil) };
    }

    // A grain synth that frees reads nothing: inputReaders holds only
    // playing synths (watchVoiceSynth's onFree, as ringReaders)
    forgetInputReader { arg synth;
        areaState[\freeze][\inputReaders].removeAt(synth);
    }

    // Set the input grain synths reading the voice ring back to the input
    // ring at the voice's history; they still count as the voice ring's
    // readers for freezeLeaveSeconds (their grains already playing)
    returnToInputRing { arg voice;
        var held = areaState[\freeze][\inputReaders], ring = this.ringBuffersFor(voice, this.inputSource);
        var until = SystemClock.seconds + this.freezeLeaveSeconds;
        held.keysValuesDo({ arg synth, entry;
            if ((entry[\voice] == voice) and: { entry[\until].isNil }) {
                this.sendToSynth(synth.setMsg(\bufL, ring[0].bufnum, \bufR, ring[1].bufnum,
                    \phaseBus, ring[2].index, \history, grainControls[voice][\history] ? 0));
                entry[\until] = until;
            };
        });
    }

    // ringLevel 1 for the readers a copy faded (those still playing)
    restoreFadedReaders { arg voice;
        var faded = areaState[\freeze][\faded][voice];
        faded.do({ arg synth; if (synth.isPlaying) { this.sendToSynth(synth.setMsg(\ringLevel, 1)) } });
        faded.clear;
    }
}
