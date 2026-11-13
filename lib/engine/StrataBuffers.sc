// StrataBuffers.sc
// The buffers area: the eight slots, the live input, the slot commands and
// the bufferState and bufferLoadFailed polls (recording is the record area's:
// StrataRecord.sc). See docs/notes/engine/buffers.md.

+ Engine_Strata {
    // The buffers area (order 40)
    strataAreaBuffers {
        ^(
            order: 40,
            allocState: { this.areaCall(\allocBufferState) },
            addDefs: { this.areaCall(\addBufferDefs); [] },
            addCommands: { this.areaCall(\addBufferCommands) },
            start: { this.areaCall(\startInputSynth) },
            stop: { this.areaCall(\stopBuffers) },
            free: { this.areaCall(\freeBuffers) }
        )
    }

    // bufferState value = (load number * (numBuffers + 1) + slot index) *
    // stride + valid seconds (Lua's BUFFER_STATE_STRIDE; bufferStateReport)
    bufferStateStride { ^1000 }

    // The load numbers a bufferState report names: the slot's loadBuffer
    // count modulo this (Lua's BUFFER_STATE_LOADS, #578). 7 keeps the
    // largest value, (6 * 9 + 7) * 1000 + 300 = 61300, below 2^16, where a
    // 32-bit float holds it to 2^-8 s
    bufferStateLoads { ^7 }

    allocBufferState {
        // Buffer slots: a left/right pair of mono buffers each, bufferSeconds
        // at the server rate (the performance area sets it first: 16 s on
        // standard, 8 slots x 2 x 16 s x 48 kHz x 4 bytes = about 49 MB; up to
        // 300 s, about 922 MB, on high)
        buffersL = Array.fill(numBuffers, { Buffer.alloc(context.server, context.server.sampleRate * bufferSeconds, 1) });
        buffersR = Array.fill(numBuffers, { Buffer.alloc(context.server, context.server.sampleRate * bufferSeconds, 1) });
        bufferFrames = Array.fill(numBuffers, 0);
        bufferSampleRates = Array.fill(numBuffers, { context.server.sampleRate });
        slotChanges = Array.fill(numBuffers, 0);
        bufferLoads = Array.fill(numBuffers, 0);
        // Per slot: the newest load number that can no longer take effect (loadsSuperseded)
        areaState[\buffers][\loadsSuperseded] = Array.fill(numBuffers, 0);
        // Per slot: the seconds bufferChanged last sent, which the periodic
        // poll repeats with the slot's load number of that moment
        // (announcedBufferState)
        areaState[\buffers][\announced] = Array.fill(numBuffers, { arg index; this.bufferStateSeconds(index) });
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
    }

    startInputSynth {
        inputSynth = Synth(\strataInput, [\out, inputBus], voiceGroup, \addToHead);
    }

    addBufferCommands {
        // msg: slot index (0-7), sound file path, start seconds into the
        // file (at its own rate; clipped to the file; 0 = the beginning)
        this.addCommand(\loadBuffer, "isf", { arg msg;
            this.areaCall(\loadSlot, msg[1], msg[2].asString, msg[3]);
        });

        this.addCommand(\clearBuffer, "i", { arg msg;
            this.areaCall(\clearSlot, msg[1]);
        });

        // recordBuffer and stopRecord are the record area's;
        // saveBuffer and its bufferSaveResult poll are the files area's

        // Valid seconds per slot. matron only accepts single-float value
        // polls (/poll/value is typed "if"), so each message carries one
        // slot and the load it was sent after (bufferStateReport: (load
        // number * (numBuffers + 1) + slot index) * bufferStateStride +
        // seconds, #578). The periodic poll cycles through the slots and
        // then the slot length (bufferLengthValue: slot index numBuffers);
        // every change is also sent at once. A slot's periodic value is the
        // seconds bufferChanged last announced, never bufferFrames itself:
        // an arming takes its new length before its peaks file is written,
        // and announces it after (takeArmed)
        bufferStatePoll = this.addPoll(\bufferState, {
            var value = if (bufferStateCursor < numBuffers) {
                this.announcedBufferState(bufferStateCursor)
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

    // Waiting slot changes, then the input synth (the record area's stop
    // has canceled the recordings first, so none completes and writes on
    // free): a slot change drops a load or zeroing still waiting for its fade
    stopBuffers {
        numBuffers.do({ arg index; this.slotChanged(index) });
        inputSynth.free;
    }

    // The slots and buses (every area's nodes are gone by now)
    freeBuffers {
        buffersL.do({ arg buffer; buffer.free });
        buffersR.do({ arg buffer; buffer.free });
        inputBus.free;
    }

    // A slot's valid seconds as bufferState reports them, to 0.01 s: a slot
    // that holds frames reports at least 0.01 s (a single cycle of 128
    // frames would round to 0.00, which Lua takes as empty, #456); an empty
    // one 0
    bufferStateSeconds { arg index;
        var seconds = (bufferFrames[index] / bufferSampleRates[index]).round(0.01);
        if (bufferFrames[index] > 0) { seconds = seconds.max(0.01) };
        ^seconds
    }

    // One bufferState message (#578): (load number * (numBuffers + 1) +
    // index) * bufferStateStride + seconds, a Float (matron's /poll/value
    // is typed "if"). The load number is the slot's loadBuffer commands
    // received so far (bufferLoads, which Lua's load_buffer counts alike)
    // modulo bufferStateLoads, whatever change the report is of (a load, a
    // clear, a recording, a periodic repeat): Lua acts on a slot's report
    // only when it names Lua's own count, so a report sent before the
    // engine had a load never settles that load, while the reports of
    // anything after it (a clear, a recording, a rejected load) name it.
    // The slots' length (index numBuffers) names none (0). Largest value:
    // (6 * 9 + 7) * 1000 + 300 = 61300, below 2^16: a 32-bit float keeps
    // it to 2^-8 s, the hundredths exactly once rounded, and the slot and
    // load exactly
    bufferStateReport { arg index, seconds;
        var load = if (index < numBuffers) { bufferLoads[index] % this.bufferStateLoads } { 0 };
        ^((((load * (numBuffers + 1)) + index) * this.bufferStateStride) + seconds).asFloat
    }

    // The slot's bufferState value now: its valid seconds and load number
    bufferStateValue { arg index; ^this.bufferStateReport(index, this.bufferStateSeconds(index)) }

    // What the periodic poll reports for a slot: the seconds bufferChanged
    // last sent, so a length is never announced before the peaks file it
    // describes is in place (docs/notes/engine/waveform.md), with the
    // slot's load number now (a load rejected since, which Lua counted
    // too, is named, so the state Lua puts back is settled by it)
    announcedBufferState { arg index; ^this.bufferStateReport(index, areaState[\buffers][\announced][index]) }

    // The slots' length (bufferSeconds) as a bufferState message for the
    // slot index after the last slot: numBuffers * bufferStateStride +
    // seconds (load number 0). Lua caps its slot length to it (an old
    // active file the engine could not replace may name more than it
    // allocated, #153)
    bufferLengthValue { ^this.bufferStateReport(numBuffers, bufferSeconds) }

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
    // A voice's live grain synths, its own and its live extra notes' (3.5:
    // noteSynths), take the slot's length (and, when it holds
    // audio, its rate: slotLengthPairs). Any other strataGrainBuf still
    // reading it (releasing after voiceOff, fading or cutting after a source
    // switch) only ever takes bufFrames 0: it fades out (hasAudio) before
    // the slot is zeroed or overwritten, never replays the new take in its
    // tail, and keeps its rate. voiceOn re-gates a releasing one with the
    // slot as it is then (gateVoice). The seconds sent are the slot's
    // announced ones from now on, which the periodic poll repeats.
    bufferChanged { arg index;
        var live = numVoices.collect({ arg voice; [synths[this.grainKey(voice)]] ++ this.noteSynths(voice, \grain) }).flatten, seconds;
        this.slotGrainSynths(index).do({ arg synth;
            if (live.includes(synth)) {
                this.sendToSynth(synth.setMsg(*this.slotLengthPairs(index)));
            } {
                if (bufferFrames[index] == 0) { this.sendToSynth(synth.setMsg(\bufFrames, 0)) };
            };
        });
        seconds = this.bufferStateSeconds(index);
        areaState[\buffers][\announced][index] = seconds;
        bufferStatePoll.update(this.bufferStateReport(index, seconds));
    }

    // The strataGrainBuf synths reading a slot that have not freed: a
    // running voice's, and those still releasing, fading or cutting
    slotGrainSynths { arg index;
        var readers = List.new;
        grainSlots.keysValuesDo({ arg synth, slot; if ((slot == index) and: { synth.isPlaying }) { readers.add(synth) } });
        ^readers
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
    // (loadsSuperseded; the check stops at its next chunk and closes the
    // file, #375). bufferLoads counts at the command either way, so
    // bufferLoadFailed's numbering is the same.
    // start: seconds into the file at its own rate, clipped to the file. The
    // check and the read both begin at that frame, and at most bufferSeconds
    // from it fit. A start past the file's end loads its last frames, as
    // many as the slot holds (a stale start, the file having been replaced
    // by a shorter one, still loads something a player can hear). The check
    // also makes the load's peaks (one FloatArray), which become the slot's
    // only if the load takes effect (applyLoad).
    loadSlot { arg index, path, start = 0;
        var file, frames, rightChannel, sampleRate, load, decodes, damaged, canceled, startFrame, slotFrames, peaks;
        if (this.validBuffer(index).not) { ^this };
        bufferLoads[index] = bufferLoads[index] + 1;
        load = bufferLoads[index];
        file = SoundFile.openRead(path.standardizePath);
        if (file.isNil) { ^this.rejectLoad(index, load, "cannot read sound file " ++ path) };
        sampleRate = file.sampleRate;
        slotFrames = [(sampleRate * bufferSeconds).floor.asInteger, buffersL[index].numFrames].minItem;
        // compared as a Float, before converting: an int32 overflows about
        // 12.4 h into a 48 kHz file (asFloat: an Integer start, as a client
        // may send, would overflow in the multiplication itself)
        startFrame = start.asFloat.max(0) * sampleRate;
        startFrame = if (startFrame >= file.numFrames) { (file.numFrames - slotFrames).max(0) } { startFrame.floor.asInteger };
        frames = (file.numFrames - startFrame).min(slotFrames);
        rightChannel = if (file.numChannels > 1) { 1 } { 0 };
        damaged = "sound file " ++ path ++ " is damaged (it stops decoding early)";
        if (frames < 1) { file.close; ^this.rejectLoad(index, load, "sound file " ++ path ++ " is empty") };
        file.seek(startFrame, 0);
        peaks = FloatArray.newClear(this.waveformPoints);
        if (frames <= this.loadCheckAtOnceFrames) {
            decodes = this.fileDecodes(file, frames, false, peaks);
            file.close;
            if (decodes.not) { ^this.rejectLoad(index, load, damaged) };
            ^this.applyLoad(index, load, path, frames, rightChannel, sampleRate, startFrame, peaks)
        };
        // a long file: whatever the check finds, the recording is over (Lua's load_buffer ends it)
        canceled = this.slotRecording(index);
        if (canceled) { this.cancelSlotRecording(index, load - 1) };
        // (stops at the first chunk after something supersedes the load, #375)
        fork({
            decodes = this.fileDecodes(file, frames, true, peaks, { load > this.loadsSuperseded(index) });
            file.close;
            if (load > this.loadsSuperseded(index)) {
                if (decodes) { this.applyLoad(index, load, path, frames, rightChannel, sampleRate, startFrame, peaks) } {
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
    // A load that read its frames sets the slot's peaks and writes its peaks
    // file first, and reports its length once the file is in place, so every
    // bufferState report that announces audio finds it there.
    applyLoad { arg index, load, path, frames, rightChannel, sampleRate, startFrame, peaks;
        var change, readFailed, failWatcher, bufnums;
        this.stopRecording(index);
        change = this.slotChanged(index, load);
        bufferFrames[index] = 0;
        // an empty slot is at the server's rate: a recording sent before the
        // reads end is judged by what the slot holds, nothing (#374; with 0
        // frames slotLengthPairs sends no rate, so fading grains keep theirs)
        bufferSampleRates[index] = context.server.sampleRate;
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
            buffersL[index].readChannel(path.standardizePath, startFrame, frames, 0, false, [0]);
            buffersR[index].readChannel(path.standardizePath, startFrame, frames, 0, false, [rightChannel]);
            fork({
                context.server.sync;  // answered once both reads are done (after any /fail)
                failWatcher.free;
                if (readFailed) {
                    postln("strata: the server could not read sound file " ++ path ++ "; buffer " ++ (index + 1) ++ " emptied");
                    if (slotChanges[index] == change) {
                        bufferSampleRates[index] = context.server.sampleRate;
                        this.clearSlotPeaks(index);
                        this.bufferChanged(index);
                    };
                    bufferLoadFailedPoll.update(this.bufferLoadFailedValue(index, load, true));
                } {
                    if (slotChanges[index] == change) {
                        bufferSampleRates[index] = sampleRate;
                        this.storeSlotPeaks(index, peaks);
                        this.writeSlotPeaks(index, frames, {
                            bufferFrames[index] = frames;
                            this.bufferChanged(index);
                        });
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
    // The canceled take leaves the slot as it left it: untouched before its
    // preparation (a synced replace take still waiting keeps the slot's
    // audio, #311), empty after it; "canceled" is followed by the slot's
    // length (cancelSlotRecording), then the failure. Either way the
    // bufferLoadFailed poll reports the failure (load is the slot's load
    // number), so Lua puts back what the slot held (its bufferState reports
    // cannot tell a rejected load over audio from a good one).
    // canceled: a long file's command already canceled the slot's recording
    rejectLoad { arg index, load, reason, canceled = false;
        var recording = this.slotRecording(index);
        postln("strata: " ++ reason ++ "; buffer " ++ (index + 1)
            ++ (if (recording or: { canceled }) { " recording canceled" } { " unchanged" }));
        if (recording) { this.cancelSlotRecording(index) };
        bufferLoadFailedPoll.update(this.bufferLoadFailedValue(index, load, false));
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

    // Empty a slot: it reads 0 frames at once (the voices reading it fade
    // out) and is zeroed after the fade (afterSlotFade)
    clearSlot { arg index;
        var change;
        if (this.validBuffer(index).not) { ^this };
        this.stopRecording(index);
        change = this.slotChanged(index);
        bufferFrames[index] = 0;
        bufferSampleRates[index] = context.server.sampleRate;
        this.clearSlotPeaks(index);
        this.bufferChanged(index);
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
        });
    }
}
