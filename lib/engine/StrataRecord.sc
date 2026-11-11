// StrataRecord.sc
// The record area: the recording synth and commands, the tap group (every
// recording, and the persistent pre-master tap, run after the master), the
// record heads the grain synths read and steer around (slotHeadGuard), the
// voice tap buses and the recordState poll. Replace takes behave as 3.2's
// (the slot fades, empties and reads 0 s until the take ends); every other
// recording is playable (feedback, loop, armed by level or delay; the slot
// keeps playing while it records). See docs/notes/engine/record.md.

+ Engine_Strata {
    // The record area (order 130)
    strataAreaRecord {
        ^(
            order: 130,
            allocState: { this.allocRecordState },
            addDefs: { this.addRecordDefs; [] },
            addCommands: { this.addRecordCommands },
            start: { this.startRecordTaps },
            stop: { this.stopRecords },
            free: { this.freeRecordState },
            effectKeys: [\tapPreMaster]
        )
    }

    // A record synth's fade at each end of a recording (seconds)
    recordFadeSeconds { ^0.005 }
    // How far before a level crossing a take armed by level starts (seconds; a fixed DelayN)
    recordPrerollSeconds { ^0.01 }
    // Frames around the head a grain may not start in: the 5 ms fade plus
    // one block, for the block-rate head (slotHeadGuard)
    recordGuardFrames { ^(this.recordFadeSeconds * context.server.sampleRate).round.asInteger + context.server.options.blockSize }
    // How much before a synced take its slot is prepared (faded, emptied),
    // beside the fade itself: covers zeroing a 300 s slot on a Pi 4
    recordPrepMargin { ^0.15 }
    // How often a playable recording's peaks file is rewritten
    peakRefreshSeconds { ^0.5 }

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
        // What \strataRecord reads for the pre-master source
        state[\preMasterBus] = Bus.audio(server, 2);
        // Per slot: the recording in progress or waiting to start (an Event, or nil)
        state[\takes] = Array.newClear(numBuffers);
        state[\peakWrites] = (reports: 0, refreshes: 0);
    }

    addRecordDefs {
        var fade = this.recordFadeSeconds, preroll = this.recordPrerollSeconds;
        var points = this.waveformPoints;
        var sampleRate = context.server.sampleRate, fadeFrames = fade * sampleRate;
        // The master's own sum, for the pre-master record source: the filter,
        // delay and reverb returns, before drift, the limiter and the
        // saturator. A bypassed delay or reverb leaves its bus unwritten,
        // which In.ar reads as silence, exactly as the master does.
        SynthDef(\strataTapPreMaster, {
            arg out, in, delayIn, reverbIn, fxMix;
            Out.ar(out, this.masterSum(in, delayIn, reverbIn, fxMix));
        }).add;

        // One recording into a slot's buffer pair (design 3.3, section 1.4).
        // Armed at once, or once the source's level passes threshold (with a
        // 10 ms pre-roll, the source through a fixed DelayN, only then).
        // Writes old x keep + new x rec at the head, a Phasor over [0, frames)
        // from arming: rec is a 5 ms ASR on gate x armed (fades in and out,
        // no step at the seam), and a one-shot's tail fades over its last
        // 5 ms, so it ends on its length. loop wraps at frames until gated
        // off. Writes its head and D to headOut (-1 and 0 before arming, for
        // slotHeadGuard), its frames so far to framesOut (read by stopRecord),
        // and the slot's peak bins into peakBuf.
        SynthDef(\strataRecord, {
            arg in, bufnumL, bufnumR, level=1, feedback=0, threshold=0, loop=0, frames=1, peakFrames=1, peakBuf=0,
            framesOut=0, headOut=0, gate=1, replyID=0;
            var source = In.ar(in, 2) * level;
            var loudest = source[0].abs.max(source[1].abs);
            // (a threshold of 0 arms at once: the follower plus a tiny offset is always over it)
            var armed = SetResetFF.kr((Amplitude.kr(loudest, 0.001, 0.05) + 1e-6) > threshold, 0);
            var sig = Select.ar(threshold > 0, [source, DelayN.ar(source, preroll, preroll)]);
            // Runs only once armed, from 0 (so it reads 0 until then), over
            // [0, frames)
            var phase = Phasor.ar(0, armed, 0, frames);
            var head = A2K.kr(phase);
            // The record level: a 5 ms fade in at arming and out at gate 0;
            // a one-shot's release starts 5 ms before frames, per sample, so
            // it ends on its length (and frees: the last frames write
            // nothing, the head wrapping under an env of 0)
            var hold = (phase < (frames - fadeFrames)).max(loop);
            var rec = EnvGen.ar(Env.asr(fade, 1, fade, \lin), this.openedGate(gate) * armed * hold, doneAction: 2);
            var keep = 1 - (rec * (1 - feedback));
            var fresh = sig * rec;
            // One bin per waveformPoints of peakFrames; while the head is in
            // a bin, its peak is the old peak (latched as the head enters it,
            // in the first block for bin 0) x feedback, plus the largest
            // sample written since (both channels: the signal after the
            // pre-roll, times the record level). Nothing is written before
            // arming
            var bin = (head * points / peakFrames).floor;
            var entering = BinaryOpUGen('!=', bin, Delay1.kr(bin)) + Impulse.kr(0);
            var stored = BufRd.kr(1, peakBuf, bin, 1, 1);
            var oldPeak = Latch.kr(stored, entering);
            var peak = Peak.kr(fresh[0], entering).max(Peak.kr(fresh[1], entering));
            BufWr.kr(Select.kr(armed, [stored, ((oldPeak * feedback) + peak).min(1)]), peakBuf, bin, 1);
            [bufnumL, bufnumR].do({ arg bufnum, channel;
                var old = BufRd.ar(1, bufnum, phase, 1, 1);
                BufWr.ar((old * keep) + fresh[channel], bufnum, phase, 1);
            });
            // the frames written before this block, counted from arming
            // (sclang adds the block), which a one-shot's head, wrapping
            // under a stop's release, would not give
            Out.kr(framesOut, Sweep.kr(armed, sampleRate));
            Out.kr(headOut, Select.kr(armed, [[-1, 0], [head, frames]]));
            SendReply.kr(armed, '/strataRecord', 0, replyID);
        }).add;
    }

    addRecordCommands {
        var responder;
        // msg: slot index, seconds, level, feedback, source, threshold, loop,
        // delay; time: the message's OSC time (nil when called without one)
        var recordCommand = { arg msg, time;
            this.recordSlot(msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], msg[8], time);
        };
        this.addCommand(\recordBuffer, "ifffifif", recordCommand);
        // A synced take's delay runs from the command's arrival (#376), but
        // CroneEngine's command function gets the message only, and sclang
        // runs it when it gets to it (after a file's check, a chunk of a
        // write). The command's own OSCdef (the one CroneEngine frees at
        // deinit) calls the command function with the message's OSC time
        // instead; without that OSCdef the delay runs from when sclang
        // handles the command, as it did before, and says so.
        responder = this.commands.detect({ arg command; command.name == \recordBuffer }) !? { arg command; command.oscdef };
        if (responder.isKindOf(OSCdef)) {
            OSCdef(responder.key, recordCommand, responder.path);
        } {
            postln("strata: recordBuffer's OSCdef not found; a synced take's delay runs from when sclang handles the command");
        };

        // End a recording now, with its fade, keeping what was captured;
        // cancels one that has not started
        this.addCommand(\stopRecord, "i", { arg msg;
            this.stopRecordSlot(msg[1]);
        });

        // One message per change of a recording's state (recordStateValue).
        // Not periodic.
        areaState[\record][\statePoll] = this.addPoll(\recordState, { this.recordStatePoll.value ? 0.0 }, false);
    }

    recordStatePoll { ^areaState[\record][\statePoll] }

    // The tap group and its first node, and the reply that says a recording
    // has armed. Started after the effects area's master (order 130).
    startRecordTaps {
        var state = areaState[\record];
        state[\tapGroup] = Group.tail(context.xg);
        synths[\tapPreMaster] = Synth(\strataTapPreMaster, [\out, state[\preMasterBus], \in, filterBus, \delayIn, delayBus,
            \reverbIn, reverbBus, \fxMix, this.mixBus(\fxMix)], state[\tapGroup], \addToHead);
        state[\armReplies] = OSCFunc({ arg msg;
            var index = msg[2].asInteger, take = if (this.validBuffer(index)) { state[\takes][index] };
            // only this take's synth (another engine on the same server has its own)
            if (take.notNil and: { take[\synth].nodeID == msg[1] }) { this.takeArmed(index, take) };
        }, '/strataRecord', context.server.addr);
    }

    // The record area's nodes: the recordings first (none completes and
    // writes on free), then the tap (a persistent synth) and its group
    stopRecords {
        var state = areaState[\record];
        numBuffers.do({ arg index; this.stopRecording(index) });
        state[\armReplies] !? { state[\armReplies].free };
        synths[\tapPreMaster] !? { synths[\tapPreMaster].free; synths.removeAt(\tapPreMaster) };
        state[\tapGroup] !? { state[\tapGroup].free };
    }

    freeRecordState {
        var state = areaState[\record];
        recordFrameBuses.do({ arg bus; bus.free });
        state[\headBuses].do({ arg bus; bus.free });
        state[\idleHead].free;
        state[\voiceTaps].do({ arg bus; bus.free });
        state[\tapSink].free;
        state[\preMasterBus].free;
    }

    // A recording's state as one float (matron's /poll/value is typed "if"):
    // ((record number * 4) + state) * numBuffers + slot index; state 0 armed,
    // 1 recording, 2 ended and kept, 3 canceled
    recordStateValue { arg index, number, state;
        ^(((number * 4) + state) * numBuffers + index).asFloat
    }

    reportRecordState { arg index, number, state;
        this.recordStatePoll.update(this.recordStateValue(index, number, state));
    }

    // A slot's record head bus: the frame the recording writes and the
    // record length D, -1 and 0 while idle. Every strataGrainBuf reads its
    // slot's (slotLengthPairs)
    slotHeadBus { arg index;
        ^areaState[\record][\headBuses][index]
    }

    // The bus a record source reads: 0 input, 1 pre-master, 2 post-master
    // (norns' output bus), 3-9 voice 1-7; any other source records the input
    recordSourceBus { arg source;
        var state = areaState[\record];
        ^case
        { source == 1 } { state[\preMasterBus] }
        { source == 2 } { context.out_b }
        { source.isInteger and: { source.inclusivelyBetween(3, 2 + numVoices) } } { state[\voiceTaps][source - 3] }
        { inputBus }
    }

    // The frame a buffer grain starts at (slotGrainPos), moved behind the
    // record head when its life would carry it across the head (design 3.3,
    // section 1.5). The head moves one frame per output frame, a grain |r| frames
    // of the slot per output frame for L = durFrames / |r| output frames
    // (|r| floored at 0.001, as readRate is), so a start s is in danger when
    //   forward (r >= 0): [h - m - max(r - 1, 0) * L, h + m + max(1 - r, 0) * L]
    //   reverse (r < 0):  [h - m,                     h + m + (|r| + 1) * L]
    // (which is one formula: below = m + max(r - 1, 0) L, above = m + max(1 - r, 0) L
    // for any r). m is recordGuardFrames (the block-rate head). Distances
    // are modulo D (the head wraps there in loop mode); a start past D is
    // never in danger, and head -1 (no recording) passes frame through. A
    // start in the zone moves to its lower edge, the newest audio just behind
    // the head, clipped to slotGrainPos's own range so it never leaves the
    // valid region. The head is sampled once per block (Latch with a
    // block-rate tick), never interpolated: the bus reads a block-rate
    // staircase whose wrap would otherwise sweep the zone across the slot
    // during the block it wraps in.
    slotHeadGuard { arg frame, lowest, highest, rate, durFrames, recHead;
        var inputs = In.kr(recHead, 2);
        var tick = Impulse.ar(ControlRate.ir);
        var head = Latch.ar(inputs[0], tick), length = Latch.ar(inputs[1], tick).max(1);
        var margin = this.recordGuardFrames;
        var life = durFrames / rate.abs.max(0.001);
        var below = margin + ((rate - 1).max(0) * life);
        var width = (2 * margin) + ((rate - 1).abs * life);
        var edge = head - below;
        var distance = (frame - edge).wrap(0, length);
        var inZone = (head >= 0) * (frame < length) * (distance <= width);
        // the lower edge, inside slotGrainPos's range; if that range pushes
        // it back into the zone (a reverse grain too close to frame 0 to fit
        // behind the head) the zone's upper edge instead, when it fits
        var wrapped = edge.wrap(0, length);
        var lower = wrapped.clip(lowest, highest);
        var stillIn = ((lower - wrapped).abs > 0.5) * ((lower - edge).wrap(0, length) <= width);
        var moved = Select.ar(stillIn, [lower, (edge + width).clip(lowest, highest)]);
        ^Select.ar(inZone, [frame, moved])
    }

    // Free a recording now and forget it. A recording canceled by a load,
    // clear or a newer recording (including one still waiting to start, or
    // in its stop fade) reports "canceled"; a take whose frame count or
    // peaks are still awaited is dropped with it (slotChanges). It leaves
    // the slot as the take left it; each caller then reports the slot's
    // length (bufferChanged), so Lua learns which
    stopRecording { arg index;
        var synth = recordSynths[index], state = areaState[\record], take = state[\takes][index];
        recordSynths[index] = nil;
        if (take.notNil) {
            state[\takes][index] = nil;
            // a stop that was sent but never armed leaves no frame count to await
            if (stopReplies[index] == take[\change]) { stopReplies[index] = nil };
            this.reportRecordState(index, take[\number], 3);
        };
        // its take may have just completed (sendToSynth); free(false) marks
        // it freed. The head goes back to idle after the free (in order on
        // the server), so a retake waiting for its delay or its level never
        // leaves the grains steering around this one's head
        if (synth.notNil and: { synth.isPlaying }) {
            this.sendToSynth(synth.freeMsg);
            synth.free(false);
            this.slotHeadBus(index).setn([-1, 0]);
        };
    }

    // true while a recording runs or waits to start in the slot, or one
    // stopRecord ended still awaits its frame count (stopReplies)
    slotRecording { arg index;
        ^recordSynths[index].notNil or: { stopReplies[index].notNil }
    }

    // A load cancels the slot's recording: it never completes, and the slot
    // is left as the take left it: untouched before its preparation (a
    // synced replace take still waiting, a playable recording), empty after
    // it. "canceled" is followed by the slot's length (bufferChanged), which
    // tells Lua which. The change also drops the awaited frame count
    // (stopReplies) and supersedes the loads up to throughLoad (every load
    // sent so far unless given: a long file's load passes the load before
    // its own, so it can still take effect after its check)
    cancelSlotRecording { arg index, throughLoad;
        this.stopRecording(index);
        this.slotChanged(index, throughLoad);
        this.bufferChanged(index);
    }

    // Start a recording into a slot, replacing whatever was recording in it
    // (design 3.3, section 1.2). A replace take (feedback 0 and no loop, or a
    // slot holding audio at another sample rate: the slot would play the old
    // and the new audio at different pitches) empties its slot, the voices
    // reading it fade first (afterSlotFade), and reads 0 s until it ends.
    // Any other recording is playable: the slot keeps playing; an empty slot
    // is zeroed first, one that holds audio is left alone and at the
    // recording's start its valid length becomes the longer of its own and
    // the record length. A delay (seconds, Lua's clock sync) starts the
    // record synth by a timestamped bundle that long after the command
    // arrived (arrived: the command message's OSC time, #376; the logical
    // time when not given); a synced replace take prepares its slot only
    // just before it (bufferFadeWait + recordPrepMargin before), so the
    // slot keeps playing until then. threshold > 0 arms the take until the
    // source's level starts it.
    // Every delayed step (the preparation, the start) runs only if nothing
    // changed the slot meanwhile (slotChanges): a later load, clear or
    // recording always wins.
    recordSlot { arg index, seconds, level, feedback = 0, source = 0, threshold = 0, loop = 0, delay = 0, arrived;
        var state, server = context.server, frames, change, take, playable, prepareAt, now = thisThread.seconds, startAt;
        if (this.validBuffer(index).not) { ^this };
        state = areaState[\record];
        // counted first: matches Lua's records_sent, whatever happens to this command
        state[\recordCounts][index] = state[\recordCounts][index] + 1;
        frames = (seconds * server.sampleRate).round.asInteger.clip(0, buffersL[index].numFrames);
        if (frames < 1) { ^this };
        // long enough for its two 5 ms fades (\strataRecord's one-shot release)
        frames = frames.max((2 * this.recordFadeSeconds * server.sampleRate).ceil.asInteger).min(buffersL[index].numFrames);

        this.stopRecording(index);
        change = this.slotChanged(index);
        // (a slot's rate describes its audio, so only a slot holding audio is
        // judged by it, #374: every step that empties a slot sets the
        // server's rate, but a load's last step takes the file's rate while
        // the slot still reads 0 frames, until its peaks file is in place)
        playable = ((feedback > 0) or: { loop > 0 })
            and: { (bufferFrames[index] == 0) or: { bufferSampleRates[index] == server.sampleRate } };
        // delay after the command arrived, never after now
        startAt = (arrived ? now).min(now) + delay.max(0);
        take = (
            number: state[\recordCounts][index], kind: if (playable) { \playable } { \replace },
            frames: frames, level: level, feedback: if (playable) { feedback.clip(0, 1) } { 0 },
            source: source, threshold: threshold.max(0), loop: if (playable and: { loop > 0 }) { 1 } { 0 },
            delay: delay.max(0), startAt: startAt, change: change,
            synth: Synth.basicNew(\strataRecord, server), started: false, stopping: false
        );
        state[\takes][index] = take;
        recordSynths[index] = take[\synth];
        if ((take[\delay] > 0) or: { take[\threshold] > 0 }) { this.reportRecordState(index, take[\number], 0) };

        prepareAt = (startAt - (bufferFadeWait + this.recordPrepMargin)) - now;
        if (prepareAt > 0) {
            SystemClock.sched(prepareAt, {
                if (slotChanges[index] == take[\change]) { this.prepareTake(index, take) };
                nil
            });
        } { this.prepareTake(index, take) };
    }

    // Get a slot ready for a recording (at once, or just before a synced
    // take: recordSlot): a replace take empties it, a playable recording
    // into an empty slot zeroes it (an empty slot may still hold a canceled
    // take); both after the fade (afterSlotFade), then a sync, so the
    // zeroing never lands on the new take. Whatever needs no zeroing starts
    // at once.
    prepareTake { arg index, take;
        var replace = take[\kind] == \replace, empty = bufferFrames[index] == 0;
        if (replace) {
            bufferFrames[index] = 0;
            bufferSampleRates[index] = context.server.sampleRate;
            this.bufferChanged(index);
        };
        if (replace or: { empty }) {
            this.afterSlotFade(index, take[\change], {
                buffersL[index].zero;
                buffersR[index].zero;
                this.slotPeakBuffer(index).zero;
                fork({ context.server.sync; this.startTake(index, take) }, SystemClock);
            });
        } { this.startTake(index, take) };
    }

    // Send the record synth, if nothing changed the slot since the command.
    // With a delay still to run it is created now, paused, and started by
    // a timestamped /n_run: the server starts it on the block the timestamp
    // names, and a cancel can still free it first (a timestamped /s_new
    // could not be canceled before the node exists). Past its timestamp
    // (a preparation that outlasted the delay) it starts at once and says
    // so.
    startTake { arg index, take;
        var server = context.server, synth = take[\synth], wait = take[\startAt] - thisThread.seconds;
        var length = if (take[\kind] == \replace) { take[\frames] } { take[\frames].max(bufferFrames[index]) };
        var message;
        if ((recordSynths[index] !== synth) or: { slotChanges[index] != take[\change] }) { ^this };
        // Marked playing from the moment it is sent (not when /n_go arrives),
        // so stopRecording frees it from here on
        synth.register(true);
        synth.onFree({ this.recordSynthFreed(index, take) });
        recordFrameBuses[index].set(0);
        message = synth.newMsg(areaState[\record][\tapGroup], [
            \in, this.recordSourceBus(take[\source]).index,
            \bufnumL, buffersL[index].bufnum, \bufnumR, buffersR[index].bufnum,
            \level, take[\level], \feedback, take[\feedback], \threshold, take[\threshold], \loop, take[\loop],
            \frames, take[\frames], \peakFrames, length, \peakBuf, this.slotPeakBuffer(index).bufnum,
            \framesOut, recordFrameBuses[index].index, \headOut, this.slotHeadBus(index).index, \replyID, index
        ], \addToTail);
        // from then on the server may arm it before sclang hears so (it
        // computes ahead of the clock by its latency: stopRecordSlot)
        take[\sent] = true;
        if (wait > 0) {
            server.sendBundle(nil, message, synth.runMsg(false));
            server.sendBundle(wait, ['/error', -1], synth.runMsg(true));
        } {
            if ((take[\delay] > 0) and: { wait < 0 }) {
                this.postRecordLate(index, (wait.neg * 1000).round.asInteger);
            };
            server.listSendMsg(message);
        };
    }

    postRecordLate { arg index, milliseconds;
        var line = "strata: buffer " ++ (index + 1) ++ " recording started " ++ milliseconds ++ " ms late";
        areaState[\record][\lastLateLine] = line;
        postln(line);
    }

    // The record synth has armed: it reports "recording", a playable
    // recording takes the slot's length, and its peaks start refreshing
    takeArmed { arg index, take;
        var length;
        if (take[\started]) { ^this };
        take[\started] = true;
        this.reportRecordState(index, take[\number], 1);
        if ((take[\kind] == \playable) and: { slotChanges[index] == take[\change] }) {
            length = bufferFrames[index].max(take[\frames]);
            if (length != bufferFrames[index]) {
                bufferFrames[index] = length;
                bufferSampleRates[index] = context.server.sampleRate;
                this.bufferChanged(index);
            };
            this.refreshRecordPeaks(index, take);
        };
    }

    // A playable recording's peaks file, every peakRefreshSeconds while it
    // records: no length report (bufferChanged), so a loop recording's
    // waveform refreshes without a bufferState change
    refreshRecordPeaks { arg index, take;
        var state = areaState[\record];
        SystemClock.sched(this.peakRefreshSeconds, {
            if (state[\takes][index] === take) {
                this.readSlotPeaks(index, this.waveformPoints, {
                    if (state[\takes][index] === take) { this.writeRecordPeaks(index, bufferFrames[index], nil) };
                });
                this.peakRefreshSeconds
            }
        });
    }

    // writeSlotPeaks, counted (the check cannot see inside the waveform
    // area, and sclang cannot spy on one instance)
    writeRecordPeaks { arg index, frames, action;
        var counters = areaState[\record][\peakWrites];
        if (action.isNil) { counters[\refreshes] = counters[\refreshes] + 1 } { counters[\reports] = counters[\reports] + 1 };
        this.writeSlotPeaks(index, frames, action);
    }

    // The record synth ended (a one-shot at its length, a stopRecord's
    // fade, or canceled): the head goes back to idle, and a take not
    // canceled ends. Unless it was canceled, the take's synth is still in
    // recordSynths. A stopped replace take's frame count (framesOut, the
    // bus keeps its last value and /c_get answers after the /n_end) is read
    // here, so it includes the fade.
    recordSynthFreed { arg index, take;
        var change = take[\change];
        if (recordSynths[index] !== take[\synth]) {
            if (recordSynths[index].isNil) { this.slotHeadBus(index).setn([-1, 0]) };
            ^this
        };
        recordSynths[index] = nil;
        this.slotHeadBus(index).setn([-1, 0]);
        // (never armed: canceled, nothing kept; stopRecordSlot frees such
        // a synth, so this is only a safety net)
        if (take[\started].not) {
            if (stopReplies[index] == change) { stopReplies[index] = nil };
            if (areaState[\record][\takes][index] === take) {
                areaState[\record][\takes][index] = nil;
                this.reportRecordState(index, take[\number], 3);
                this.bufferChanged(index);  // after "canceled": what the slot holds
            };
            ^this
        };
        if (take[\stopping] and: { take[\kind] == \replace }) {
            recordFrameBuses[index].get({ arg recorded;
                if (stopReplies[index] == change) { stopReplies[index] = nil };
                if (slotChanges[index] == change) { this.endTake(index, take, (recorded.round.asInteger + context.server.options.blockSize).clip(0, take[\frames])) };
            });
        } {
            if (slotChanges[index] == change) { this.endTake(index, take, take[\frames]) };
        };
    }

    // A recording has ended and is kept: its peaks are read and written,
    // then a replace take's length is reported, then "ended", then the
    // scratch take is written. Each step runs only if the slot has not
    // changed since (a later load, clear or recording drops the rest). Lua
    // relies on the order: the peaks file names the length when it
    // arrives, and the length comes before "ended" (the check sees it from
    // outside, through the polls and the files, #378).
    endTake { arg index, take, frames;
        var state = areaState[\record], replace = take[\kind] == \replace, change = take[\change];
        var points = this.waveformPoints;
        var usedBins = if (replace) { (points * frames / take[\frames]).ceil.asInteger.clip(1, points) } { points };
        var valid = if (replace) { frames } { bufferFrames[index] };
        var kept = { (state[\takes][index] === take) and: { slotChanges[index] == change } };
        this.readSlotPeaks(index, usedBins, {
            if (kept.value) {
                this.writeRecordPeaks(index, valid, {
                    if (kept.value) {
                        if (replace) {
                            bufferFrames[index] = frames;
                            this.bufferChanged(index);
                        };
                        state[\takes][index] = nil;
                        this.reportRecordState(index, take[\number], 2);
                        this.writeSlot(index, this.scratchPath(index));
                    };
                });
            };
        });
    }

    // Stop a recording now and keep it: gate 0 fades it (5 ms); the synth
    // stays in recordSynths until it frees, and only then is the frame count
    // read (recordSynthFreed), so the count includes the fade. A recording
    // that has not started (still preparing or waiting for its delay or its
    // level) is canceled and keeps nothing, and leaves the slot as the take
    // left it: a synced replace take that had not yet prepared its slot
    // leaves it playing (#373), one that had leaves it empty. Every such
    // cancel is followed by the slot's length (bufferChanged), so Lua
    // learns which. An idle slot is left alone, a second stop during the
    // fade is a no-op. The kept reply applies only if no load, record or
    // clear changed the slot before it arrived (slotChanges).
    stopRecordSlot { arg index;
        var state = areaState[\record], take, change;
        if (this.validBuffer(index).not) { ^this };
        take = state[\takes][index];
        if (take.isNil or: { recordSynths[index].isNil }) { ^this };
        if (take[\stopping]) { ^this };
        // not started as far as sclang knows and not sent yet (waiting for
        // its preparation, or still preparing): canceled here, and the slot
        // change drops the waiting preparation. One sent (running, or paused
        // until its timestamp: the server computes ahead of the clock, so it
        // may have armed already, its reply still on its way) is gated off
        // like a started one, and after a sync (the server sends an arming
        // reply before it answers a /sync that follows the gate) one that
        // has still not armed is canceled: gated off unarmed it writes nothing
        if (take[\started].not and: { take[\sent] != true }) {
            this.stopRecording(index);
            this.slotChanged(index);
            // after "canceled", what the slot holds: its audio, untouched,
            // when the take had not prepared it; else 0 s
            this.bufferChanged(index);
            ^this
        };
        take[\stopping] = true;
        change = this.slotChanged(index);
        take[\change] = change;
        if (take[\kind] == \replace) { stopReplies[index] = change };
        this.sendToSynth(take[\synth].setMsg(\gate, 0));
        if (take[\started].not) {
            fork({
                context.server.sync;
                if (take[\started].not and: { state[\takes][index] === take }) {
                    this.stopRecording(index);
                    this.bufferChanged(index);  // after "canceled": what the slot holds
                };
            }, SystemClock);
        };
    }
}
