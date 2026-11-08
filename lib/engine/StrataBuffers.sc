// StrataBuffers.sc
// The buffers area: the eight slots, the live input, recording, the slot
// commands and the bufferState and bufferLoadFailed polls. See
// docs/notes/engine/buffers.md.

+ Engine_Strata {
    // The buffers area (order 40)
    strataAreaBuffers {
        ^(
            order: 40,
            allocState: { this.allocBufferState },
            addDefs: { this.addBufferDefs; [] },
            addCommands: { this.addBufferCommands },
            start: { this.startInputSynth },
            stop: { this.stopBuffers },
            free: { this.freeBuffers }
        )
    }

    // bufferState value = slot index * stride + valid seconds (Lua's BUFFER_STATE_STRIDE)
    bufferStateStride { ^1000 }

    allocBufferState {
        // Buffer slots: a left/right pair of mono buffers each, bufferSeconds
        // at the server rate (the performance area sets it first: 16 s on
        // standard, 8 slots x 2 x 16 s x 48 kHz x 4 bytes = about 49 MB; up to
        // 300 s, about 922 MB, on high)
        buffersL = Array.fill(numBuffers, { Buffer.alloc(context.server, context.server.sampleRate * bufferSeconds, 1) });
        buffersR = Array.fill(numBuffers, { Buffer.alloc(context.server, context.server.sampleRate * bufferSeconds, 1) });
        bufferFrames = Array.fill(numBuffers, 0);
        bufferSampleRates = Array.fill(numBuffers, { context.server.sampleRate });
        recordSynths = Array.newClear(numBuffers);
        recordFrameBuses = Array.fill(numBuffers, { Bus.control(context.server, 1) });
        slotChanges = Array.fill(numBuffers, 0);
        stopReplies = Array.newClear(numBuffers);
        bufferLoads = Array.fill(numBuffers, 0);
        // Per slot: the newest load number that can no longer take effect (loadsSuperseded)
        areaState[\buffers][\loadsSuperseded] = Array.fill(numBuffers, 0);
        inputBus = Bus.audio(context.server, 2);
        // Equals Lua's _path.audio .. "strata/scratch/" on norns
        scratchDir = Platform.userHomeDir +/+ "dust/audio/strata/scratch/";
    }

    addBufferDefs {
        // Live input copied to inputBus for input-sourced grain synths and recording
        SynthDef(\strataInput, {
            arg out;
            Out.ar(out, SoundIn.ar([0, 1]));
        }).add;

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

    startInputSynth {
        inputSynth = Synth(\strataInput, [\out, inputBus], voiceGroup, \addToHead);
    }

    addBufferCommands {
        // msg: slot index (0-7), sound file path
        this.addCommand(\loadBuffer, "is", { arg msg;
            this.loadSlot(msg[1], msg[2].asString);
        });

        // msg: slot index, seconds, input level
        this.addCommand(\recordBuffer, "iff", { arg msg;
            this.recordSlot(msg[1], msg[2], msg[3]);
        });

        this.addCommand(\clearBuffer, "i", { arg msg;
            this.clearSlot(msg[1]);
        });

        // End a recording early, keeping what was captured
        this.addCommand(\stopRecord, "i", { arg msg;
            this.stopRecordSlot(msg[1]);
        });

        // saveBuffer and its bufferSaveResult poll are the files area's

        // Valid seconds per slot. matron only accepts single-float value
        // polls (/poll/value is typed "if"), so each message carries one
        // slot: slot index * bufferStateStride + seconds. The periodic poll
        // cycles through the slots and then the slot length
        // (bufferLengthValue: slot index numBuffers); every change is also
        // sent at once.
        bufferStatePoll = this.addPoll(\bufferState, {
            var value = if (bufferStateCursor < numBuffers) {
                this.bufferStateValue(bufferStateCursor)
            } { this.bufferLengthValue };
            bufferStateCursor = (bufferStateCursor + 1) % (numBuffers + 1);
            value
        });

        // A load whose file cannot be used, whether or not the slot held
        // audio: one message per failed load, sent at once (rejectLoad) or,
        // when the server's read fails after the slot was zeroed, once the
        // reads are done (the slot is then emptied). It names the slot, that
        // slot's load number and whether the slot was emptied
        // (bufferLoadFailedValue), so Lua undoes exactly that load and never
        // a later one. Not periodic; a value request resends the last report
        // (Lua ignores a repeat).
        bufferLoadFailedPoll = this.addPoll(\bufferLoadFailed, { bufferLoadFailedPoll.value ? 0.0 }, false);
    }

    // Recordings and waiting slot changes, then the input synth
    stopBuffers {
        // canceled first, so no recording completes (and writes) on free;
        // a slot change also drops a load or zeroing still waiting for its fade
        numBuffers.do({ arg index; this.stopRecording(index); this.slotChanged(index) });
        inputSynth.free;
    }

    // The slots and buses (every area's nodes are gone by now)
    freeBuffers {
        buffersL.do({ arg buffer; buffer.free });
        buffersR.do({ arg buffer; buffer.free });
        inputBus.free;
        recordFrameBuses.do({ arg bus; bus.free });
    }

    bufferStateValue { arg index;
        ^(index * this.bufferStateStride) + (bufferFrames[index] / bufferSampleRates[index]).round(0.01)
    }

    // The slots' length (bufferSeconds) as a bufferState message for the
    // slot index after the last slot: numBuffers * bufferStateStride +
    // seconds. Lua caps its slot length to it (an old active file the
    // engine could not replace may name more than it allocated, #153). A
    // Float, as every bufferState value (matron's /poll/value is typed "if")
    bufferLengthValue { ^((numBuffers * this.bufferStateStride) + bufferSeconds).asFloat }

    // One float, as bufferState (matron's /poll/value is typed "if"):
    // (load * 2 + emptied) * numBuffers + slot index, where load is the
    // slot's load number (counted from 1) and emptied is 1 when the failed
    // load left the slot empty (the server's read failed after the zeroing),
    // 0 when it left the slot as it was. Exact for the first 2^20 loads of a
    // slot (a float32 holds integers exactly up to 2^24).
    bufferLoadFailedValue { arg index, load, emptied;
        ^((((load * 2) + emptied.binaryValue) * numBuffers) + index).asFloat
    }

    bufferRateScale { arg index;
        ^bufferSampleRates[index] / context.server.sampleRate
    }

    // A slot's valid length or rate changed: tell the grain synths reading it and Lua.
    // A voice's live grain synth takes the slot's length (and, when it holds
    // audio, its rate: slotLengthPairs). Any other strataGrainBuf still
    // reading it (releasing after voiceOff, fading or cutting after a source
    // switch) only ever takes bufFrames 0: it fades out (hasAudio) before
    // the slot is zeroed or overwritten, never replays the new take in its
    // tail, and keeps its rate. voiceOn re-gates a releasing one with the
    // slot as it is then (gateVoice).
    bufferChanged { arg index;
        var live = numVoices.collect({ arg voice; synths[this.grainKey(voice)] });
        this.slotGrainSynths(index).do({ arg synth;
            if (live.includes(synth)) {
                this.sendToSynth(synth.setMsg(*this.slotLengthPairs(index)));
            } {
                if (bufferFrames[index] == 0) { this.sendToSynth(synth.setMsg(\bufFrames, 0)) };
            };
        });
        bufferStatePoll.update(this.bufferStateValue(index));
    }

    // The strataGrainBuf synths reading a slot that have not freed: a
    // running voice's, and those still releasing, fading or cutting
    slotGrainSynths { arg index;
        var readers = List.new;
        grainSlots.keysValuesDo({ arg synth, slot; if ((slot == index) and: { synth.isPlaying }) { readers.add(synth) } });
        ^readers
    }

    // Cancel a recording in progress, or one still waiting for its zeroed
    // buffers (it then never starts); its onFree sees it was canceled
    stopRecording { arg index;
        var synth = recordSynths[index];
        recordSynths[index] = nil;
        // its take may have just completed (sendToSynth); free(false) marks it freed
        if (synth.notNil and: { synth.isPlaying }) { this.sendToSynth(synth.freeMsg); synth.free(false) };
    }

    // Read up to bufferSeconds of a sound file into a slot (channel 0 to the
    // left buffer, channel 1, or 0 again for a mono file, to the right).
    // At most bufferSeconds at the server rate fit (the buffers' size), so a
    // file at twice the server rate keeps half as many seconds. A missing,
    // unreadable, empty or damaged file (one that stops decoding before its
    // frames end: fileDecodes) leaves the slot unchanged (rejectLoad). A
    // file of up to standardBufferSeconds at the server rate is checked at
    // once; a longer one (high tier only) in a routine that yields between
    // chunks, so the commands go on meanwhile: the load cancels a recording
    // in the slot at once, but takes effect (applyLoad) only after the
    // check, and is dropped silently, reporting nothing, if a record, clear
    // or stop, or a later load that took effect, arrived meanwhile
    // (loadsSuperseded). bufferLoads counts at the command either way, so
    // bufferLoadFailed's numbering is the same.
    loadSlot { arg index, path;
        var file, frames, rightChannel, sampleRate, load, decodes, damaged, canceled;
        if (this.validBuffer(index).not) { ^this };
        bufferLoads[index] = bufferLoads[index] + 1;
        load = bufferLoads[index];
        file = SoundFile.openRead(path.standardizePath);
        if (file.isNil) { ^this.rejectLoad(index, load, "cannot read sound file " ++ path) };
        sampleRate = file.sampleRate;
        frames = [file.numFrames, (sampleRate * bufferSeconds).floor.asInteger, buffersL[index].numFrames].minItem;
        rightChannel = if (file.numChannels > 1) { 1 } { 0 };
        damaged = "sound file " ++ path ++ " is damaged (it stops decoding early)";
        if (frames < 1) { file.close; ^this.rejectLoad(index, load, "sound file " ++ path ++ " is empty") };
        if (frames <= this.loadCheckAtOnceFrames) {
            decodes = this.fileDecodes(file, frames);
            file.close;
            if (decodes.not) { ^this.rejectLoad(index, load, damaged) };
            ^this.applyLoad(index, load, path, frames, rightChannel, sampleRate)
        };
        // a long file: whatever the check finds, the recording is over (Lua's load_buffer ends it)
        canceled = this.slotRecording(index);
        if (canceled) { this.cancelSlotRecording(index, load - 1) };
        fork({
            decodes = this.fileDecodes(file, frames, true);
            file.close;
            if (load > this.loadsSuperseded(index)) {
                if (decodes) { this.applyLoad(index, load, path, frames, rightChannel, sampleRate) } {
                    this.rejectLoad(index, load, damaged, canceled)
                };
            };
        }, SystemClock);
    }

    // The most frames loadSlot checks at once (standardBufferSeconds at the
    // server rate: about 9 ms for a FLAC on a desktop); longer files are
    // checked in a routine (fileDecodes, yielding)
    loadCheckAtOnceFrames { ^(this.standardBufferSeconds * context.server.sampleRate).floor.asInteger }

    // Loads of the slot numbered up to this can no longer take effect: a
    // record, clear or stop supersedes every load sent before it, a load
    // that takes effect every earlier one (slotChanged)
    loadsSuperseded { arg index; ^areaState[\buffers][\loadsSuperseded][index] }

    // A load that passed its checks takes effect: it cancels a recording,
    // supersedes every earlier load and empties the slot at once. The file's
    // sample rate becomes the slot's bufRateScale, so it plays at pitch.
    // The voices reading the slot fade out first (afterSlotFade): the slot
    // reads 0 frames until the reads have completed (a sync after them),
    // then its length and rate reach the grain synths and the poll, only if
    // nothing else changed the slot meanwhile (slotChanges). A server read
    // that fails (/fail for /b_readChannel: the file vanished, or became
    // unreadable, after the checks) leaves the slot zeroed, so it stays
    // empty and the load is reported as failed with the slot emptied.
    applyLoad { arg index, load, path, frames, rightChannel, sampleRate;
        var change, readFailed, failWatcher, bufnums;
        this.stopRecording(index);
        change = this.slotChanged(index, load);
        bufferFrames[index] = 0;
        this.bufferChanged(index);
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
            // the server answers a read it cannot do with /fail, naming the
            // file ("File '<path>' could not be opened: ...") and the bufnum:
            // both must match, so an earlier load's failed read of another
            // file, still in flight in this slot, never fails this one
            readFailed = false;
            bufnums = [buffersL[index].bufnum, buffersR[index].bufnum];
            failWatcher = OSCFunc({ arg msg;
                if ((msg[1].asSymbol == '/b_readChannel') and: { bufnums.includes(msg[3]) }
                    and: { msg[2].asString.contains("'" ++ path.standardizePath ++ "'") }) { readFailed = true };
            }, '/fail', context.server.addr);
            buffersL[index].readChannel(path.standardizePath, 0, frames, 0, false, [0]);
            buffersR[index].readChannel(path.standardizePath, 0, frames, 0, false, [rightChannel]);
            fork({
                context.server.sync;  // answered once both reads are done (after any /fail)
                failWatcher.free;
                if (readFailed) {
                    postln("strata: the server could not read sound file " ++ path ++ "; buffer " ++ (index + 1) ++ " emptied");
                    if (slotChanges[index] == change) {
                        bufferSampleRates[index] = context.server.sampleRate;
                        this.bufferChanged(index);
                    };
                    bufferLoadFailedPoll.update(this.bufferLoadFailedValue(index, load, true));
                } {
                    if (slotChanges[index] == change) {
                        bufferFrames[index] = frames;
                        bufferSampleRates[index] = sampleRate;
                        this.bufferChanged(index);
                    };
                };
            }, SystemClock);
        });
    }

    // A load whose file cannot be used leaves the slot as it is, except that
    // it cancels a recording in progress or waiting to start, or one stopped
    // early whose frame count has not arrived yet (stopReplies; the slot
    // change drops that reply), as Lua's load_buffer expects: that take
    // never completes, so it is never adopted under the bad file's name.
    // The slot reads empty (0 frames), as for a recording a clear canceled.
    // Either way the bufferLoadFailed poll reports the failure (load is the
    // slot's load number), so Lua puts back what the slot held (its
    // bufferState reports cannot tell a rejected load over audio from a
    // good one).
    // canceled: a long file's command already canceled the slot's recording
    rejectLoad { arg index, load, reason, canceled = false;
        var recording = this.slotRecording(index);
        postln("strata: " ++ reason ++ "; buffer " ++ (index + 1)
            ++ (if (recording or: { canceled }) { " recording canceled" } { " unchanged" }));
        if (recording) { this.cancelSlotRecording(index) };
        bufferLoadFailedPoll.update(this.bufferLoadFailedValue(index, load, false));
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

    // true when a grain synth reads the slot: a running voice's, or one
    // still releasing, fading or cutting (slotGrainSynths)
    slotPlaying { arg index;
        ^this.slotGrainSynths(index).notEmpty
    }

    // Run action (zeroing or overwriting a slot) once the voices reading it
    // have faded out: the caller has set its bufFrames to 0 (bufferChanged),
    // which strataGrainBuf's hasAudio lag fades, so the sound never cuts
    // off. bufferFadeWait later when a running voice reads the slot, at once
    // otherwise. A delayed action runs only if nothing changed the slot
    // meanwhile (slotChanges), so a later load, record or clear always wins.
    afterSlotFade { arg index, change, action;
        if (this.slotPlaying(index).not) { ^action.value };
        SystemClock.sched(bufferFadeWait, {
            if (slotChanges[index] == change) { action.value };
            nil
        });
    }

    // Count a change to a slot (load, record, clear, stop) and return the
    // new count: a reply that arrives later applies only if it is unchanged.
    // A stopped take's frame count still awaited (stopReplies) is dropped
    // with it, so a bad load sent after this change sees no take to cancel
    // and never cancels this change instead (rejectLoad); stopRecordSlot
    // sets its own entry after its change. The loads up to throughLoad
    // (every load sent so far unless given) can no longer take effect
    // (loadsSuperseded): a long file still in its check is dropped.
    slotChanged { arg index, throughLoad;
        var superseded = areaState[\buffers][\loadsSuperseded];
        slotChanges[index] = slotChanges[index] + 1;
        stopReplies[index] = nil;
        superseded[index] = superseded[index].max(throughLoad ? bufferLoads[index]);
        ^slotChanges[index]
    }

    // Record the stereo input into a slot, replacing it: the slot reads as
    // empty at once (the voices reading it fade out, afterSlotFade), then
    // the pair is zeroed and the record synth starts after a sync, so
    // zeroing never lands on the new take, and only if nothing canceled it
    // meanwhile (a completion message could not be canceled before the
    // node exists). The slot reads as empty until the recording completes,
    // then the take is written to scratchDir so it survives a restart.
    recordSlot { arg index, seconds, level;
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

    // Empty a slot: it reads 0 frames at once (the voices reading it fade
    // out) and is zeroed after the fade (afterSlotFade)
    clearSlot { arg index;
        var change;
        if (this.validBuffer(index).not) { ^this };
        this.stopRecording(index);
        change = this.slotChanged(index);
        bufferFrames[index] = 0;
        bufferSampleRates[index] = context.server.sampleRate;
        this.bufferChanged(index);
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
        });
    }
}
