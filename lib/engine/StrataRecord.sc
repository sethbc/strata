// StrataRecord.sc
// The record area: the recording synth and commands (moved out of
// StrataBuffers.sc, 3.2's behavior unchanged), the record heads the grain
// synths read, the voice tap buses and the recordState poll. The hooks and
// arguments that 3.3's record package (1a) fills are neutral here. See
// docs/notes/engine/record.md.

+ Engine_Strata {
    // The record area (order 130)
    strataAreaRecord {
        ^(
            order: 130,
            allocState: { this.allocRecordState },
            addDefs: { this.addRecordDefs; [] },
            addCommands: { this.addRecordCommands },
            stop: { numBuffers.do({ arg index; this.stopRecording(index) }) },
            free: { this.freeRecordState }
        )
    }

    allocRecordState {
        var state = areaState[\record], server = context.server;
        var headBus = { Bus.control(server, 2).setn([-1, 0]) };
        recordSynths = Array.newClear(numBuffers);
        recordFrameBuses = Array.fill(numBuffers, { Bus.control(server, 1) });
        stopReplies = Array.newClear(numBuffers);
        state[\recordCounts] = Array.fill(numBuffers, 0);
        // Per slot: the head frame and the record length D (slotHeadGuard
        // reads them through recHeadBus), -1 and 0 while idle; and one
        // head that always reads -1 and 0, the grain defs' default
        state[\headBuses] = Array.fill(numBuffers, headBus);
        state[\idleHead] = headBus.value;
        // Per voice: the voice's whole output before the sends, written by
        // the mix stage (0c), never a grain synth; the sink is the default
        // of its tapOut control, so no tap ever writes audio bus 0
        state[\voiceTaps] = Array.fill(numVoices, { Bus.audio(server, 2) });
        state[\tapSink] = Bus.audio(server, 2);
    }

    addRecordDefs {
        // Records the stereo input into a slot's buffer pair from frame 0
        // (replacing, never overdubbing) and frees itself after duration.
        // framesOut holds the frames recorded so far, read by stopRecord.
        SynthDef(\strataRecord, {
            arg in, bufnumL, bufnumR, level=1, duration=1, framesOut;
            var sig = In.ar(in, 2) * level;
            RecordBuf.ar(sig[0], bufnumL, loop: 0, doneAction: 2);
            RecordBuf.ar(sig[1], bufnumR, loop: 0);
            Out.kr(framesOut, Sweep.kr(0, SampleRate.ir));
            Line.kr(0, 0, duration, doneAction: 2);
        }).add;
    }

    addRecordCommands {
        // msg: slot index, seconds, level, then 3.3's feedback, source,
        // threshold, loop and delay (accepted, ignored until the record
        // package)
        this.addCommand(\recordBuffer, "ifffifif", { arg msg;
            this.recordSlot(msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8]);
        });

        // End a recording early, keeping what was captured
        this.addCommand(\stopRecord, "i", { arg msg;
            this.stopRecordSlot(msg[1]);
        });

        // One message per change of a recording's state (recordStateValue).
        // Not periodic; registered now, sent from the record package on.
        areaState[\record][\statePoll] = this.addPoll(\recordState, { this.recordStatePoll.value ? 0.0 }, false);
    }

    recordStatePoll { ^areaState[\record][\statePoll] }

    freeRecordState {
        var state = areaState[\record];
        recordFrameBuses.do({ arg bus; bus.free });
        state[\headBuses].do({ arg bus; bus.free });
        state[\idleHead].free;
        state[\voiceTaps].do({ arg bus; bus.free });
        state[\tapSink].free;
    }

    // A recording's state as one float (matron's /poll/value is typed "if"):
    // ((record number * 4) + state) * numBuffers + slot index; state 0 armed,
    // 1 recording, 2 ended and kept, 3 canceled
    recordStateValue { arg index, number, state;
        ^(((number * 4) + state) * numBuffers + index).asFloat
    }

    // A slot's record head bus: the frame the recording writes and the
    // record length D, -1 and 0 while idle. Every strataGrainBuf reads its
    // slot's (slotLengthPairs)
    slotHeadBus { arg index;
        ^areaState[\record][\headBuses][index]
    }

    // The frame a buffer grain starts at (slotGrainPos), moved behind the
    // record head when it would read across it. Neutral until the record
    // package: the frame as chosen
    slotHeadGuard { arg frame, lowest, highest, rate, durFrames, recHead;
        ^frame
    }

    // Cancel a recording in progress, or one still waiting for its zeroed
    // buffers (it then never starts); its onFree sees it was canceled
    stopRecording { arg index;
        var synth = recordSynths[index];
        recordSynths[index] = nil;
        // its take may have just completed (sendToSynth); free(false) marks it freed
        if (synth.notNil and: { synth.isPlaying }) { this.sendToSynth(synth.freeMsg); synth.free(false) };
    }

    // true while a recording runs or waits to start in the slot, or one
    // stopRecord ended still awaits its frame count (stopReplies)
    slotRecording { arg index;
        ^recordSynths[index].notNil or: { stopReplies[index].notNil }
    }

    // A load cancels the slot's recording: it never completes, and the slot
    // reads empty (0 frames). The change also drops the awaited frame count
    // (stopReplies) and supersedes the loads up to throughLoad (every load
    // sent so far unless given: a long file's load passes the load before
    // its own, so it can still take effect after its check)
    cancelSlotRecording { arg index, throughLoad;
        this.stopRecording(index);
        this.slotChanged(index, throughLoad);
        this.bufferChanged(index);
    }

    // Record the stereo input into a slot, replacing it: the slot reads as
    // empty at once (the voices reading it fade out, afterSlotFade), then
    // the pair is zeroed and the record synth starts after a sync, so
    // zeroing never lands on the new take, and only if nothing canceled it
    // meanwhile (a completion message could not be canceled before the
    // node exists). The slot reads as empty until the recording completes,
    // then the take is written to scratchDir so it survives a restart.
    // feedback, source, threshold, loop and delay are 3.3's arguments, not
    // used until the record package.
    recordSlot { arg index, seconds, level, feedback = 0, source = 0, threshold = 0, loop = 0, delay = 0;
        var frames, synth, change;
        if (this.validBuffer(index).not) { ^this };
        frames = (seconds * context.server.sampleRate).round.asInteger.clip(0, buffersL[index].numFrames);
        if (frames < 1) { ^this };

        this.stopRecording(index);
        change = this.slotChanged(index);
        bufferFrames[index] = 0;
        bufferSampleRates[index] = context.server.sampleRate;
        this.bufferChanged(index);

        synth = Synth.basicNew(\strataRecord, context.server);
        recordSynths[index] = synth;
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
            fork({
                context.server.sync;
                if (recordSynths[index] === synth) {
                    // Marked playing from the moment it is sent (not when /n_go
                    // arrives), so stopRecording frees it from here on
                    synth.register(true);
                    synth.onFree({
                        if (recordSynths[index] === synth) {
                            recordSynths[index] = nil;
                            bufferFrames[index] = frames;
                            this.bufferChanged(index);
                            this.writeSlot(index, this.scratchPath(index));
                        };
                    });
                    recordFrameBuses[index].set(0);
                    context.server.listSendMsg(synth.newMsg(inputSynth, [
                        \in, inputBus,
                        \bufnumL, buffersL[index].bufnum,
                        \bufnumR, buffersR[index].bufnum,
                        \level, level,
                        \duration, frames / context.server.sampleRate,
                        \framesOut, recordFrameBuses[index].index
                    ], \addAfter));
                };
            }, SystemClock);
        });
    }

    // Stop a recording now and keep it: the slot's valid length becomes the
    // frames the record synth reported (its frames bus keeps the last value
    // after the free, and /c_get is answered after the /n_free), then the
    // scratch take is written as for a completed recording. A recording
    // still waiting for its zeroed buffers captured nothing and is simply
    // canceled; an idle slot is left alone. The reply applies only if no
    // load, record or clear changed the slot before it arrived (slotChanges).
    stopRecordSlot { arg index;
        var synth, started, change;
        if (this.validBuffer(index).not) { ^this };
        synth = recordSynths[index];
        if (synth.isNil) { ^this };
        started = synth.isPlaying;  // read first: Node.free clears it
        this.stopRecording(index);
        change = this.slotChanged(index);
        if (started.not) { ^this };
        stopReplies[index] = change;
        recordFrameBuses[index].get({ arg recorded;
            if (stopReplies[index] == change) { stopReplies[index] = nil };
            if (slotChanges[index] == change) {
                bufferFrames[index] = recorded.round.asInteger.clip(0, buffersL[index].numFrames);
                this.bufferChanged(index);
                this.writeSlot(index, this.scratchPath(index));
            };
        });
    }
}
