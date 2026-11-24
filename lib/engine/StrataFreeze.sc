// StrataFreeze.sc
// The freeze area: holding what a voice's grains read. The freeze and
// freezeMode grain params (Lua's v<i>_freeze, v<i>_freeze_mode) hold:
// - a synth voice's ring: its writer paused (hold) or replaced by a
//   spectral writer that keeps writing one held spectrum (spectral, high
//   tier only);
// - an input voice's last 4 s: copied from the input ring into the voice's
//   copy ring (StrataRings.sc: copyRingFor), which its grain synth then
//   reads at history 0 (hold), or which a spectral writer of the input of
//   its own then continues (spectral). An input freeze never touches the
//   voice's own ring or its writer, so a synth-source grain synth (whose
//   path carries no voice level) never reads input audio (#494, #495);
// - a voice-source voice's (3.8) the same way: the 4 s behind its read
//   point of the read voice's output ring copied into its copy ring, and
//   on spectral a writer of the read voice's tap into it. The copy family
//   (frozenOnInput, readsInputCopy, copyInputToCopyRing, copyInputSpan,
//   returnToInputRing) keeps its names for both: a ring another writer
//   writes (freezesByCopy);
// - a buffer voice's scan: stopped (scanRate).
// Spectral asked for on the standard tier, or for a buffer voice, holds.
// See docs/notes/engine/freeze.md.

+ Engine_Strata {
    // The spectral writer's FFT size (frames)
    spectralFrames { ^2048 }

    // The spectral writer's analysis dither (amplitude, about -100 dBFS)
    spectralDither { ^0.00001 }

    // How long an input grain synth set back from the copy ring to the
    // input ring still counts as reading the copy ring (s): its longest
    // grain, started just before, plus the read margin
    freezeLeaveSeconds { ^this.grainMaxSeconds + this.ringReadMargin }

    // The freeze area (order 110). A freeze and a freezeMode act, then
    // return false, so setGrainParam also stores the control and sends it
    // to the grain synth (freeze stops a slot's scan and scans a frozen ring
    // there); an unfreeze stores and sends its freeze control itself, in
    // one bundle with what it sends (unfreezeWithControl). The spectral
    // copy writers are the engine's alone to start and free: effectKeys.
    strataAreaFreeze {
        ^(
            order: 110,
            allocState: { this.areaCall(\allocFreezeState) },
            addDefs: { this.areaCall(\addFreezeDefs); [] },
            addCommands: { this.areaCall(\addFreezePoll) },
            grainParamHandlers: (
                freeze: { arg voice, value;
                    if (value > 0.5) { this.areaCall(\freezeVoice, voice); false } { this.areaCall(\unfreezeWithControl, voice, value); true }
                },
                freezeMode: { arg voice, value; this.areaCall(\setFreezeMode, voice, value); false }
            ),
            stop: { this.areaCall(\stopCopyWriters); this.areaCall(\forgetWriterStarts) },
            free: { this.areaCall(\freeSpectralBuffers) },
            effectKeys: this.copyWriterKeys
        )
    }

    // areaState[\freeze], per voice: \frozen (Boolean), \mode (\hold or
    // \spectral while frozen, else nil), \source (the source it froze),
    // \copied (an input voice's copy is in its copy ring and its grain
    // synth reads it), \copies (the number of its latest input copy),
    // \faded (copy ring readers a pending copy set to ringLevel 0).
    // \inputReaders: the input grain synths that read their voice's copy
    // (pointed at it, started on it or re-gated onto it: noteInputReader)
    // -> (voice, until: nil while they do, the time they stop counting once
    // set back); pruned when a synth frees (forgetInputReader).
    // \spectralBuffers: on the high tier, each voice's [left, right] FFT
    // buffers for its spectral writer (see addFreezeDefs), else empty.
    // \writerStarts: per voice, while the /n_go of the ring writer
    // replaceRingWriter made last has not come, (watch: its responder, run:
    // whether it was made running), else nil (watchWriterStart, #1000).
    // \ended: per voice, the freezes the engine ended on its own
    // (abandonCopy), counted from 1 as the freezeEnded poll reports them.
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
        state[\ended] = Array.fill(numVoices, 0);
        state[\writerStarts] = Array.newClear(numVoices);
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
    // later. A voice's pair serves one running node at a time: its synth
    // freeze's writer (Synth.replace of its ring writer) or its input
    // freeze's copy writer (startCopyWriter), and an unfreeze frees the one
    // before the other can start. A burst of changes in one block can make
    // and replace several of a voice's writers before any is calculated;
    // the ones replaced never construct their units (scsynth runs a node's
    // constructors at its first block), so they never touch the pair.
    addFreezeDefs {
        var window = this.spectralFrames;
        if (tier != \high) { ^this };
        SynthDef(\strataRingWriteSpectral, {
            arg in, bufL, bufR, phaseOut, resume = 0, fftL, fftR;
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
            var phase = this.ringWritePhase(bufL, phaseOut, resume);
            BufWr.ar(sig[0], bufL, phase);
            BufWr.ar(sig[1], bufR, phase);
            Out.kr(phaseOut, A2K.kr(phase));
        }).add;
    }

    // The rate of a buffer grain synth's position scan (loop lengths per
    // second): stopped while frozen
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

    // Whether a source freezes by a copy into the voice's copy ring: the
    // input, and 3.8's voice sources (rings another writer writes)
    freezesByCopy { arg source;
        ^(source == this.inputSource) or: { this.voiceSource(source) }
    }

    // Whether the voice is frozen with a copy (of the input ring or, 3.8, of
    // a read voice's output ring; or a spectral writer of the input or of
    // the read voice's tap) as what its grains read: its history is then 0
    frozenOnInput { arg voice;
        var state = areaState[\freeze];
        ^this.validVoice(voice) and: { state[\frozen][voice] } and: { this.freezesByCopy(state[\source][voice]) }
    }

    // Whether the voice's ring is held by a spectral writer of its voice bus
    // (a synth voice's spectral freeze): PV_MagFreeze takes the held
    // spectrum's phases from the voice synth, so a type switch waits for the
    // unfreeze (setVoiceType, docs/notes/engine/types.md)
    spectralHoldsVoice { arg voice;
        var state = areaState[\freeze];
        ^(state[\mode][voice] == \spectral) and: { state[\source][voice] == 0 }
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
    // in the new one, in one bundle (#834), as unfreezeWithControl sends its
    // unfreeze: from spectral to hold the writer's replace, the type switch
    // that waited for the unfreeze and the new writer's pause land in one
    // block, so the new writer never writes a block into the held ring. The
    // unfreeze makes that writer paused (writerRun false: a hold on the
    // synth source follows), so the hold's pause finds it made so and sends
    // nothing, and no throwaway running writer is made first (#1000)
    setFreezeMode { arg voice, value;
        var state = areaState[\freeze], holdFollows;
        if (this.validVoice(voice).not) { ^this };
        grainControls[voice][\freezeMode] = value;
        if (state[\frozen][voice] and: { state[\mode][voice] != this.freezeModeFor(voice) }) {
            holdFollows = (grainSource[voice] == 0) and: { this.freezeModeFor(voice) == \hold };
            // (freezeVoice through areaCall: a copy source's forks its copy)
            context.server.makeBundle(nil, {
                this.unfreezeVoice(voice, holdFollows.not);
                this.areaCall(\freezeVoice, voice);
            });
        };
    }

    // Freeze a voice's source (the freeze grain param). A voice already
    // frozen on this source in this mode keeps its freeze; its live grain
    // synth is only pointed at the copy again (Lua resends freeze after
    // voiceOn; the grain synth voiceOn starts or re-gates already reads it:
    // grainReadPairs). Frozen on another source or mode (the source changed
    // while the voice was stopped), it is unfrozen first. Each freeze is a
    // ring change, so a copy still waiting for an earlier freeze never runs.
    // An input or voice-source voice's freeze is its copy alone: its own
    // ring and writer go on writing its voice bus.
    freezeVoice { arg voice;
        var state = areaState[\freeze], mode, source;
        if (this.validVoice(voice).not) { ^this };
        mode = this.freezeModeFor(voice);
        source = grainSource[voice];
        if (state[\frozen][voice] and: { (state[\mode][voice] != mode) or: { state[\source][voice] != source } }) {
            // (a hold on the synth source follows: the unfreeze makes its writer paused)
            this.unfreezeVoice(voice, ((source == 0) and: { mode == \hold }).not);
        };
        if (state[\frozen][voice]) {
            if (this.freezesByCopy(source) and: { state[\copied][voice] }) { this.pointAtCopyRing(voice) };
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
        { this.freezesByCopy(source) } { this.copyInputToCopyRing(voice) };
        // a slot: the grain synth's freeze control stops its scan (scanRate)
    }

    // Undo freezeVoice. replaceGrainSynth calls it before every source
    // switch of a running voice (grainSource is the new source by then).
    // A synth voice's writer resumes: a paused one from its own phase, a
    // spectral one replaced from its phase bus. An input or voice-source
    // voice's copy writer (spectral) is freed and the grain synths reading
    // its copy are set back to the ring it froze; its own writer
    // never stopped. The kept freeze control is 0, so a grain synth the
    // switch starts is unfrozen. A spectral one's end applies a type switch
    // that waited for it (applyWaitingVoiceType), after the writer's
    // replace: every path that ends a spectral freeze comes here (the
    // freeze param's unfreeze, inside its bundle; a mode change; a freeze
    // on another mode or source; a source switch, whose voice synth fades).
    // writerRun false: the plain writer a spectral one's end makes is made
    // paused, for a hold freeze that follows in the same bundle (a mode
    // change, a freeze on another mode); its pause then sends nothing
    unfreezeVoice { arg voice, writerRun = true;
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
                this.replaceRingWriter(voice, \strataRingWrite, granBuses[voice], writerRun);
                this.applyWaitingVoiceType(voice);
            } { this.resumeRingWriter(voice) };
        }
        { this.freezesByCopy(source) } {
            this.stopCopyWriter(voice);
            this.returnToInputRing(voice, source);
        };
    }

    // The freeze param's unfreeze: what unfreezeVoice sends (the readers set
    // back to the input ring, a copy writer freed, a synth voice's writer
    // resumed or replaced) and the grain synth's freeze control, kept and
    // sent, in one bundle, so they land in one block. ringGrainReader holds
    // the freeze flag for the block: a reader set back to the input ring a
    // block before its freeze 0 would start that block's grains a further
    // grainMaxSeconds back (rings.scd shows it). The control reaches the
    // voice's extra grain notes too (setGrainSynths). A synth voice's
    // unfreeze moves its notes in the same bundle (the notes area's
    // notesUnfrozen: the own grain synth's noteRate back to 1 and its park
    // open, the own note's expression on the voice synth again, which already
    // holds the park (ruling 44), its ring-stream notes restarted as voice
    // synths)
    unfreezeWithControl { arg voice, value;
        var synthVoice = this.frozenSynthVoice(voice);
        context.server.makeBundle(nil, {
            this.unfreezeVoice(voice);
            grainControls[voice][\freeze] = value;
            this.setGrainSynths(voice, \freeze, value);
            if (synthVoice) { this.areaCall(\notesUnfrozen, voice) };
        });
    }

    // The voice's ring writer (a persistent effectKeys synth: plain messages)
    ringWriterFor { arg voice;
        ^synths[this.ringWriterKeys[voice]]
    }

    // The pause, resume and replace of a voice's ring writer are a synth
    // voice's hold and spectral freeze only: an input freeze never touches
    // the voice's writer
    pauseRingWriter { arg voice;
        this.runRingWriter(voice, false);
    }

    resumeRingWriter { arg voice;
        this.runRingWriter(voice, true);
    }

    // A hold's pause or its run: /n_run only to a writer that has had its
    // first block (no /n_go awaited: watchWriterStart). scsynth runs a
    // node's unit constructors at its first block, and its Node_SetRun
    // breaks on a node still waiting for it (#1000, 3.13 and 3.14.1 alike):
    // a pause there leaves the node to construct itself paused, a run after
    // that pause is ignored (the writer stayed paused, the voice's ring held
    // though unfrozen), and a second pause skips the constructors, so the
    // run after it calculated units never constructed and crashed scsynth.
    // A writer still waiting and made in the state asked for gets nothing;
    // one made in the other is replaced, by one made paused or running: its
    // one /n_run before its first block, if any, is the pause in its own
    // /s_new's packet, which scsynth honors. Only a hold pauses or runs the
    // writer, so the voice's writer here is always a plain one of its voice
    // bus (a spectral freeze's writer is only ever replaced, never paused):
    // the replace makes \strataRingWrite of granBuses[voice]
    runRingWriter { arg voice, run;
        var writer = this.ringWriterFor(voice), waiting = areaState[\freeze][\writerStarts][voice];
        if (writer.isNil) { ^this };
        case
        { waiting.isNil } { writer.run(run) }
        { waiting[\run] != run } { this.replaceRingWriter(voice, \strataRingWrite, granBuses[voice], run) };
    }

    // Replace the voice's ring writer with one of defName reading the bus
    // in (Synth.replace frees the old one in the same server step); the new
    // one carries on from the old one's head (resume 1: ringWritePhase). A
    // synth voice's spectral freeze and its unfreeze, and a hold's pause or
    // run of a writer still waiting for its first block (runRingWriter).
    // run false makes it paused: its /n_run 0 in the replace's packet (a
    // caller's bundle, or one of its own). A replace is safe whatever the
    // old writer's state: one never calculated is freed without its
    // destructors, as scsynth frees a node that never constructed its units
    replaceRingWriter { arg voice, defName, in, run = true;
        var key = this.ringWriterKeys[voice], old = synths[key], ring = this.ringBuffersFor(voice, 0);
        var args = [\in, in, \bufL, ring[0], \bufR, ring[1], \phaseOut, ring[2], \resume, 1], fft, server = context.server, replace;
        if (old.isNil or: { this.pastStop }) { ^this };
        if (defName == \strataRingWriteSpectral) {
            fft = areaState[\freeze][\spectralBuffers][voice];
            if (fft.isNil) { ^this };
            args = args ++ [\fftL, fft[0], \fftR, fft[1]];
        };
        replace = {
            synths[key] = Synth.replace(old, defName, args);
            if (run.not) { synths[key].run(false) };
        };
        if (run or: { server.addr.hasBundle }) { replace.value } { server.makeBundle(nil, replace) };
        this.areaCall(\watchWriterStart, voice, synths[key], run);
    }

    // The voice's new ring writer has had its first block once its /n_go
    // has come: the server performs what it receives at the start of a
    // callback and calculates after, so whatever sclang sends once that
    // reply to the callback that made the node is in is performed in a
    // later callback, after the node's first block.
    // Until then areaState[\freeze][\writerStarts][voice] holds the
    // responder and the run state the writer was made in (watch, run), and
    // runRingWriter replaces the writer rather than send it a run (or, made
    // in the state asked for, leaves it). The responder goes with that /n_go, the voice's next replace
    // (forgetWriterStart) and the area's stop (forgetWriterStarts), never
    // with a timer: a writer whose /s_new found no room sends no /n_go, and
    // its voice's next pause or run is a replace
    watchWriterStart { arg voice, writer, run;
        var starts = areaState[\freeze][\writerStarts], entry = (run: run);
        this.forgetWriterStart(voice);
        entry[\watch] = OSCFunc({ if (starts[voice] === entry) { starts[voice] = nil } },
            '/n_go', context.server.addr, argTemplate: [writer.nodeID]).oneShot;
        starts[voice] = entry;
    }

    // The voice's writer's /n_go responder freed, if it has one
    forgetWriterStart { arg voice;
        var starts = areaState[\freeze][\writerStarts];
        starts[voice] !? { arg entry; entry[\watch].free };
        starts[voice] = nil;
    }

    forgetWriterStarts {
        numVoices.do({ arg voice; this.forgetWriterStart(voice) });
    }

    freeSpectralBuffers {
        areaState[\freeze][\spectralBuffers].do({ arg pair; pair.do(_.free) });
        areaState[\freeze][\spectralBuffers] = [];
    }

    // The grain synths that read the voice's copy ring, playing: the input
    // grain synths pointed at it, started on it or re-gated onto it
    // (inputReaders), and those set back from it until freezeLeaveSeconds
    // after (their grains already playing still read it). A synth-source
    // grain synth reads its voice's own ring and is never one of them.
    copyRingReaders { arg voice;
        var held = areaState[\freeze][\inputReaders], now = SystemClock.seconds;
        held.keys.copy.do({ arg synth;
            var entry = held[synth];
            if (synth.isPlaying.not or: { entry[\until].notNil and: { entry[\until] <= now } }) { held.removeAt(synth) };
        });
        ^held.keys.select({ arg synth; (held[synth][\voice] == voice) and: { synth.isPlaying } }).asArray
    }

    // The copy rings' writers (a spectral input freeze's, one key per
    // voice): effectKeys, the engine alone starts and frees them
    copyWriterKeys {
        ^numVoices.collect({ arg voice; ("copyWrite" ++ voice).asSymbol })
    }

    // A spectral input freeze: a writer of the input into the voice's copy
    // ring, from the copy's end (its phase bus, 0: a new node, resume 0),
    // at the tail of voiceGroup (after the input synth), beside the voice's
    // own writer. A voice source's (3.8): a writer of the read voice's tap,
    // at the tail of the record area's tap group (after every stage has
    // written its tap). Nothing on the standard tier (no FFT buffers), when
    // the voice has one already, or once the engine is past stop (pastStop)
    startCopyWriter { arg voice;
        var key = this.copyWriterKeys[voice], ring = this.copyRingFor(voice), source = areaState[\freeze][\source][voice];
        var fft = areaState[\freeze][\spectralBuffers][voice], in = inputBus, target = voiceGroup;
        if (fft.isNil or: { synths[key].notNil } or: { this.pastStop }) { ^this };
        if (this.voiceSource(source)) {
            in = areaState[\record][\voiceTaps][this.readVoiceOf(source)];
            target = areaState[\record][\tapGroup];
        };
        synths[key] = Synth(\strataRingWriteSpectral, [\in, in, \bufL, ring[0], \bufR, ring[1], \phaseOut, ring[2],
            \fftL, fft[0], \fftR, fft[1]], target, \addToTail);
    }

    // Free the voice's copy writer, if any (quietly: one whose /s_new found
    // no room never started)
    stopCopyWriter { arg voice;
        synths.removeAt(this.copyWriterKeys[voice]) !? { arg writer;
            this.sendToSynth(writer.freeMsg);
            writer.free(false);
        };
    }

    stopCopyWriters {
        numVoices.do({ arg voice; this.stopCopyWriter(voice) });
    }

    // An input voice's hold: the 4 s of the input ring ending at its read
    // point (the head minus ringReadMargin + history) copied into the
    // voice's copy ring (a voice source's, 3.8: of the read voice's output
    // ring, ending ringReadMargin behind its head), then the copy ring's
    // phase bus set to the copy's
    // end and its live grain synth set to read the copy. Fade before
    // overwriting: the copy ring's readers get ringLevel 0 and the copy
    // waits bufferFadeWait when any plays, and goes ahead at once
    // otherwise. Each step runs only while ringChanges[voice] is unchanged
    // and no later copy started (an unfreeze or switch wins). The faded
    // readers get ringLevel 1 back once the copy is in (or abandoned), by
    // the latest copy only.
    // A copy is in only if it ran inside its room (#809): the head is read
    // again once the server has done it, and a copy the writer outran
    // (copyOnTime), or one whose head the server never gave, is made again
    // from a fresh read point while the copy is current, up to copyAttempts
    // (the readers' fade is still down: nothing reads the copy ring until a
    // copy lands). One console line comes after the second late copy
    // (copyLateLineAttempt): an attempt whose head the server never gave is
    // counted apart, as no copy, never as a late one (#835); the hold is
    // abandoned (abandonCopy) only for a refused span or once the bound is
    // spent, its line naming both counts. Each attempt, its re-read and
    // the abandon run only while the copy is current, as every step does.
    copyInputToCopyRing { arg voice;
        var state = areaState[\freeze], change = this.ringChanges[voice], copy = state[\copies][voice] + 1;
        var readers = this.copyRingReaders(voice), server = context.server;
        var current = { (state[\copies][voice] == copy) and: { this.ringChanges[voice] == change }
            and: { this.pastStop.not } };
        state[\copies][voice] = copy;
        readers.do({ arg synth;
            state[\faded][voice].add(synth);
            this.sendToSynth(synth.setMsg(\ringLevel, 0));
        });
        fork({
            var ring, history, head, after, readAt, seconds, attempt = 0, late = 0, missing = 0, landed = false, refused = false;
            if (readers.notEmpty) { bufferFadeWait.wait };
            while { landed.not and: { refused.not } and: { attempt < this.copyAttempts } and: { current.value } } {
                attempt = attempt + 1;
                after = nil;
                seconds = nil;
                ring = this.ringBuffersFor(voice, state[\source][voice]);
                history = this.copyHistory(voice);
                head = this.areaCall(\ringHeadFrame, ring[2]);
                readAt = Main.elapsedTime;
                if (current.value and: { head.notNil }) { this.beforeCopyHook.value(voice, attempt) };
                if (current.value and: { head.notNil }) {
                    refused = this.copyInputSpan(voice, head, history).not;
                    if (refused.not) {
                        server.sync;  // answered once both channels' copies are done
                        seconds = Main.elapsedTime - readAt;
                        if (current.value) { after = this.areaCall(\ringHeadFrame, ring[2]) };
                    };
                };
                if (current.value and: { this.copyOnTime(head, after, seconds, ring[0].numFrames, history) }) {
                    this.holdCopyRing(voice);
                    landed = true;
                } {
                    // a head read the server never answered (ringHeadFrame's
                    // 1 s): no copy was made or none could be judged
                    if (current.value and: { refused.not }) {
                        if (head.isNil or: { after.isNil }) { missing = missing + 1 } {
                            late = late + 1;
                            if (late == this.copyLateLineAttempt) {
                                this.postFreezeLine("strata: voice % hold: its copy was late % times (room % s); made again until one is in time, at most % times".format(
                                    voice + 1, late, (this.copyRoomFrames(ring[0].numFrames, history) / server.sampleRate).round(0.001),
                                    this.copyAttempts));
                            };
                        };
                    };
                };
            };
            if (landed.not and: { current.value }) {
                this.areaCall(\abandonCopy, voice, if (refused) { nil } {
                    this.copyAbandonReason((this.copyRoomFrames(ring[0].numFrames, history) / server.sampleRate).round(0.001),
                        attempt, late, missing) });
            };
            if ((state[\copies][voice] == copy) and: { this.pastStop.not }) {
                this.restoreFadedReaders(voice);
            };
        }, SystemClock);
    }

    // How many times a hold's copy is made at most before it is abandoned
    // (8: a copy late each time, by a server queue held seconds at a time,
    // has gone on for seconds); the engine check sets a smaller bound
    // (areaState[\freeze][\copyAttempts]; nil: 8)
    copyAttempts { ^areaState[\freeze][\copyAttempts] ? 8 }
    copyAttempts_ { arg count; areaState[\freeze][\copyAttempts] = count }

    // The late copy after which the copy says so on the console, once (an
    // attempt with no head from the server is no late copy, #835)
    copyLateLineAttempt { ^2 }

    // An abandoned copy's reason (abandonCopy's line): its room (s), its
    // attempts, how many were late and how many got no head from the server
    copyAbandonReason { arg room, attempts, late, missing;
        if (late == 0) { ^"the server gave no head in % attempts".format(attempts) };
        if (missing == 0) { ^"its copy was not in within its room (% s) in % attempts".format(room, attempts) };
        ^"its copy was not in within its room (% s) in % attempts (% of them with no head from the server)".format(
            room, attempts, missing)
    }

    // How far behind a frozen copy's end its grains can read with no scan
    // (s): the frozen read point (ringScanOffset's grainMaxSeconds), the
    // read margin and the spread (the lookback; history is 0 inside the
    // copy), and a grain at ringMaxRate either way (forward it starts
    // (ringMaxRate - 1) x grainMaxSeconds further back and reads
    // grainMaxSeconds on; reversed it reads ringMaxRate x grainMaxSeconds
    // back from its start): 3.005 s
    frozenReachSeconds {
        ^this.grainMaxSeconds + this.ringReadMargin + this.ringSpreadSeconds + (this.ringMaxRate * this.grainMaxSeconds)
    }

    // The history a copy of the voice's source is taken at (s): the input's
    // kept history, clipped; 0 for a voice source
    copyHistory { arg voice;
        var source = areaState[\freeze][\source][voice];
        ^if (source == this.inputSource) { (grainControls[voice][\history] ? 0).clip(0, historySeconds) } { 0 }
    }

    // A copy's room (frames): how far the source ring's writer may go from
    // the head's read until the copy runs before audio it writes after the
    // read reaches what a frozen grain reads. That audio enters the copy at
    // copy frame ringReadMargin + history + a block (the head on the phase
    // bus is the start of the block its writer has written) less the source
    // ring's spare length (its frames less the copy's), and a frozen grain
    // reads the copy's last frozenReachSeconds and a block (its reader's
    // block lag). So: the source ring's frames less the frozen reach, the
    // read margin, the history and two blocks. 0.987 s of an output ring
    // at 48 kHz (no spare length); 1.99 s of the input ring at its longest
    // history (ringGuardSeconds + 1 s spare), more at less
    copyRoomFrames { arg sourceFrames, history = 0;
        var sampleRate = context.server.sampleRate;
        ^sourceFrames - ((this.frozenReachSeconds + this.ringReadMargin + history) * sampleRate)
            - (2 * context.server.options.blockSize)
    }

    // Whether a copy ran inside its room, at the history it was taken at:
    // the head read again after it (after; nil when the server did not
    // answer) moved less than copyRoomFrames from the read point's, counted
    // round the ring, and less than that time passed from the read's reply
    // to /synced (seconds). So the count never went a whole ring round: each
    // head read waits at most 1 s, and the ring's frames less its room are
    // at least frozenReachSeconds, more than the two reads' 2 s
    copyOnTime { arg head, after, seconds, ringFrames, history;
        var room = this.copyRoomFrames(ringFrames, history);
        ^head.notNil and: { after.notNil } and: { seconds.notNil } and: { (after - head).mod(ringFrames) < room }
            and: { (seconds * context.server.sampleRate) < room }
    }

    // Give up a hold whose copy never ran inside its room in copyAttempts,
    // or whose span copyInputSpan refused (why: the line's reason; nil when
    // copyInputSpan posted one): the voice is unfrozen as
    // the freeze param's unfreeze does it (unfreezeWithControl, one
    // bundle), so its grain synths read its live ring at freeze 0 and the
    // engine's freeze state reads 0. Then Lua is told on freezeEnded
    // (#858), so its v<i>_freeze goes to 0 with no unfreeze sent back
    abandonCopy { arg voice, why;
        var ended = areaState[\freeze][\ended];
        why !? { this.postFreezeLine("strata: voice % hold abandoned: %".format(voice + 1, why)) };
        this.unfreezeWithControl(voice, 0);
        ended[voice] = ended[voice] + 1;
        this.freezeEndedPoll !? { arg poll; poll.update(this.freezeEndedValue(voice, ended[voice])) };
    }

    // The freezeEnded poll (#858): one message per freeze the engine ended
    // on its own (abandonCopy), so Lua sets the voice's v<i>_freeze to 0
    // without sending the unfreeze back. Not periodic; a value request
    // resends the last report (Lua acts on a voice's newest count only)
    addFreezePoll {
        areaState[\freeze][\endedPoll] = this.addPoll(\freezeEnded, { this.freezeEndedPoll.value ? 0.0 }, false);
    }

    freezeEndedPoll { ^areaState[\freeze][\endedPoll] }

    // One float, as the slot polls' (matron's /poll/value is typed "if"):
    // the voice's ended count (from 1) times numVoices plus the voice index
    freezeEndedValue { arg voice, count;
        ^((count * numVoices) + voice).asFloat
    }

    // One console line of the freeze area (the engine check collects them
    // through areaState[\freeze][\postLine])
    postFreezeLine { arg line;
        var post = areaState[\freeze][\postLine];
        if (post.notNil) { post.value(line) } { line.postln };
    }

    // The engine check's step before each copy's message: a function of the
    // voice and the attempt (from 1 to copyAttempts), called inside the
    // copy's routine, where it may wait so that the copy goes out late while
    // the source ring's writer keeps writing (#809). nil: nothing
    beforeCopyHook { ^areaState[\freeze][\beforeCopy] }
    beforeCopyHook_ { arg hook; areaState[\freeze][\beforeCopy] = hook }

    // A ring writer's frame now (on its phase bus: the input writer's, or a
    // read voice's output ring writer's), inside a routine; nil if the
    // server does not answer within 1 s. The reply's responder is its own
    // (Bus.get's could not be freed), a one-shot of the bus's /c_set, and
    // is freed on both paths, the reply and the timeout (#1014), so a server
    // that never answers leaves none behind
    ringHeadFrame { arg bus;
        var condition = Condition(false), value, server = context.server, reply;
        reply = OSCFunc({ arg msg; value = msg[2]; condition.test = true; condition.signal },
            '/c_set', server.addr, argTemplate: [bus.index]).oneShot;
        server.listSendMsg([\c_get, bus.index]);
        SystemClock.sched(1, { condition.test = true; condition.signal; nil });
        condition.wait;
        reply.free;
        ^value
    }

    // Copy the 4 s of the frozen source's ring (the input ring, or a voice
    // source's output ring, 3.8) ending ringReadMargin + history (the
    // input's only) before head into the voice's copy ring, oldest first
    // from frame 0: one /b_gen copy per channel, two when the span wraps
    // the ring's end (an output ring, as long as the copy ring, always does).
    // A source ring shorter than the copy ring would leave the copy's start
    // unwritten (a negative span): refused, with one console line (#809).
    // Answers whether it copied. history: the attempt's (copyHistory), the
    // one its room is counted at
    copyInputSpan { arg voice, head, history;
        var rings = areaState[\rings], sampleRate = context.server.sampleRate, source = areaState[\freeze][\source][voice];
        var from = this.ringBuffersFor(voice, source), inputFrames = from[0].numFrames, voiceFrames = rings[\copyL][voice].numFrames;
        var end, start, spans;
        if (inputFrames < voiceFrames) {
            this.postFreezeLine("strata: voice % hold refused: its source ring (% frames) is shorter than its copy ring (% frames)".format(
                voice + 1, inputFrames, voiceFrames));
            ^false
        };
        end = (head - ((this.ringReadMargin + history) * sampleRate)).round.asInteger.mod(inputFrames);
        start = end - voiceFrames;
        // [source frame, copy ring frame, frames]
        spans = if (start >= 0) { [[start, 0, voiceFrames]] } {
            [[start + inputFrames, 0, start.neg], [0, start.neg, end]]
        };
        spans.do({ arg span;
            if (span[2] > 0) {
                from[0].copyData(rings[\copyL][voice], span[1], span[0], span[2]);
                from[1].copyData(rings[\copyR][voice], span[1], span[0], span[2]);
            };
        });
        ^true
    }

    // The copy is in: the copy ring's phase bus at its end (frame 0 = the
    // ring's length) and the live grain synth reading it; spectral starts
    // its writer of the input into the copy ring from there
    holdCopyRing { arg voice;
        var state = areaState[\freeze];
        this.copyRingFor(voice)[2].set(0);
        if (state[\mode][voice] == \spectral) { this.startCopyWriter(voice) };
        state[\copied][voice] = true;
        this.pointAtCopyRing(voice);
    }

    // Set the voice's live input grain synths, its own and its live extra
    // notes' (3.5: setGrainSynths), to read what grainReadPairs says (the
    // copy, once it is in: the copy ring at history 0; GrainBuf latches its
    // buffer per grain: seamless), and count them among the copy ring's
    // readers
    pointAtCopyRing { arg voice;
        var synth = synths[this.grainKey(voice)];
        if (synth.isNil or: { this.freezesByCopy(grainSource[voice]).not }) { ^this };
        this.setGrainSynths(voice, *this.grainReadPairs(voice));
        ([synth] ++ this.noteSynths(voice, \grain)).do({ arg each; this.noteInputReader(voice, each) });
    }

    // Whether the voice's grain synth reads its copy: the voice is on the
    // input or a voice source, frozen with a copy of that very source, and
    // the copy is in its copy ring
    readsInputCopy { arg voice;
        ^this.freezesByCopy(grainSource[voice]) and: { this.frozenOnInput(voice) }
            and: { areaState[\freeze][\source][voice] == grainSource[voice] }
            and: { areaState[\freeze][\copied][voice] }
    }

    // A ring's [left, right] buffers for the voice's input channel (3.8:
    // the kept inputChannel, 0 stereo, 1 the left twice, 2 the right
    // twice): the input source's only, its copy included; any other ring as
    // it is
    channelPair { arg voice, source, ring;
        if (source != this.inputSource) { ^[ring[0], ring[1]] };
        ^switch (grainControls[voice][\inputChannel] ? 0)
        { 1 } { [ring[0], ring[0]] }
        { 2 } { [ring[1], ring[1]] }
        { [ring[0], ring[1]] }
    }

    // What a voice's ring grain synth reads, as strataGrainRing controls:
    // the one answer the start, the re-gate (grainControlPairs) and a freeze
    // (pointAtCopyRing) all send. The synth source reads its voice's 4 s
    // ring at history 0 (history is for the input ring, so a voice that
    // leaves the input never reads a wrapped ring); the input source the
    // input ring at the voice's history, or its frozen copy (the copy
    // ring) at history 0; a voice source (3.8) the read voice's output
    // ring, or its frozen copy, at history 0; a buffer source nothing
    // (empty). The input's channel applies to its ring and its copy
    // (channelPair).
    grainReadPairs { arg voice;
        var source = grainSource[voice], ring, history = 0, pair;
        case
        { source == 0 } { ring = this.ringBuffersFor(voice, 0) }
        { this.freezesByCopy(source) } {
            if (this.readsInputCopy(voice)) { ring = this.copyRingFor(voice) } {
                ring = this.ringBuffersFor(voice, source);
                if (source == this.inputSource) { history = grainControls[voice][\history] ? 0 };
            };
        }
        { ^[] };
        pair = this.channelPair(voice, source, ring);
        ^[\bufL, pair[0].bufnum, \bufR, pair[1].bufnum, \phaseBus, ring[2].index, \history, history]
    }

    // Count a grain synth among the copy ring's readers (inputReaders)
    // while it reads the voice's input copy
    noteInputReader { arg voice, synth;
        if (this.readsInputCopy(voice)) { areaState[\freeze][\inputReaders][synth] = (voice: voice, until: nil) };
    }

    // A grain synth that frees reads nothing: inputReaders holds only
    // playing synths (watchVoiceSynth's onFree, as ringReaders)
    forgetInputReader { arg synth;
        areaState[\freeze][\inputReaders].removeAt(synth);
    }

    // Set the grain synths reading the copy ring back to the ring the voice
    // froze (source: the input ring at the voice's history, its channel
    // applied, or a voice source's output ring at history 0, 3.8); they
    // still count as the copy ring's readers for freezeLeaveSeconds (their
    // grains already playing). The source is the unfreeze's: a switch calls
    // it with grainSource already the new one
    returnToInputRing { arg voice, source;
        var held = areaState[\freeze][\inputReaders], ring = this.ringBuffersFor(voice, source);
        var until = SystemClock.seconds + this.freezeLeaveSeconds, pair = this.channelPair(voice, source, ring);
        var history = if (source == this.inputSource) { grainControls[voice][\history] ? 0 } { 0 };
        held.keysValuesDo({ arg synth, entry;
            if ((entry[\voice] == voice) and: { entry[\until].isNil }) {
                this.sendToSynth(synth.setMsg(\bufL, pair[0].bufnum, \bufR, pair[1].bufnum,
                    \phaseBus, ring[2].index, \history, history));
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
