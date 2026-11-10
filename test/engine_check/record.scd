// test/engine_check/record.scd
// The record area (lib/engine/StrataRecord.sc): its buses, the record sources
// and the tap group, the writing (feedback, loop, fades), arming by level and
// by delay, playable recordings, the head guard, the recordState reports and
// the end of a take. See docs/notes/engine/record.md.
//
// Audio comparisons run on the server (one number back to sclang, #131). A
// take and the same source captured by a check synth start from one
// timestamp, so they are compared sample for sample (the check's \in
// control tells the rest: a replace take's fades differ only in the first
// and last 5 ms).
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var state = engine.areaState[\record];
var sampleRate = server.sampleRate, blockSize = server.options.blockSize;
var fadeFrames = (0.005 * sampleRate).round.asInteger;
var seconds = 0.2, tone, frames;
var inputSynth = engine.inputSynth;
var settle = { arg time = 0.05; time.wait; server.sync };
var record = { arg slot, duration, level = 1.0, feedback = 0, source = 0, threshold = 0, loop = 0, delay = 0;
    h.command(\recordBuffer, slot, duration, level, feedback, source, threshold, loop, delay)
};
var isRecording = { arg slot; engine.recordSynths[slot].notNil };
var waitDone = { arg slot, limit = 5; h.waitFor({ isRecording.(slot).not }, limit) };
var reset = { arg slot; h.command(\clearBuffer, slot); server.sync };
// states of the slot's reports since `start` (an index into the poll's values)
var reportsFor = { arg slot, start = 0;
    h.pollValues(\recordState).drop(start).collect({ arg value;
        var whole = value.round.asInteger, stride = engine.numBuffers;
        var slotIndex = whole % stride, code = whole div: stride;
        [slotIndex, code div: 4, code % 4]
    }).select({ arg report; report[0] == slot })
};
var nowReports = { h.pollValues(\recordState).size };
var writeLevelFile = { arg name, duration, level;
    var path = h.tempDir +/+ name;
    h.writeTestFile(path, sampleRate, (duration * sampleRate).round.asInteger, [level, level]);
    path
};
// A check synth on one control bus: run it for `time` seconds and read the bus
var measured = { arg defName, args, time, target;
    var bus = Bus.control(server, 2), synth, values;
    target = target ?? { state[\tapGroup] ?? { engine.processGroup } };
    bus.setn([0, 0]);
    server.sync;
    synth = Synth(defName, args ++ [\out, bus.index], target, \addToTail);
    (time + 0.03).wait;
    server.sync;
    values = h.readBus(bus);
    synth.free; server.sync; bus.free;
    values
};
// [largest |a - b| over `count` frames from `first`, largest |a|]
var compareBuffers = { arg bufA, bufB, first, count, offsetB = 0;
    measured.(\strataCheckRecDiff, [\bufA, bufA.bufnum, \bufB, bufB.bufnum, \first, first, \count, count, \offsetB, offsetB],
        count / sampleRate)
};
// largest |buffer - value| over `count` frames from `first`
var deviationFrom = { arg buffer, first, count, value;
    measured.(\strataCheckRecValue, [\buf, buffer.bufnum, \first, first, \count, count, \value, value], count / sampleRate)[0]
};
var firstFrameAbove = { arg buffer, count, threshold;
    measured.(\strataCheckRecFirstAbove, [\buf, buffer.bufnum, \count, count, \threshold, threshold], count / sampleRate)[0]
};
var stepPeak = { arg buffer, count;
    measured.(\strataCheckRecSteps, [\buf, buffer.bufnum, \count, count], count / sampleRate)[0]
};
// A slot's take equals a capture of the bus, started from one timestamp
var sourceMatches = { arg slot, source, busNumber, label, duration = 0.25, prepare, during;
    var delay = 0.35, count = (duration * sampleRate).round.asInteger;
    var capture = Buffer.alloc(server, count + (blockSize * 2), 1), id = server.nextNodeID, comparison;
    server.sync;
    prepare.value;
    record.(slot, duration, 1.0, 0, source, 0, 0, delay);
    server.sendBundle(delay, ['/s_new', \strataCheckCapture, id, 1, (state[\tapGroup] ?? { context.xg }).nodeID,
        \in, busNumber.asControlInput, \buf, capture.bufnum]);
    during !? { (delay + (duration * 0.5)).wait; during.value };
    waitDone.(slot, delay + duration + 1);
    settle.(0.1);
    comparison = compareBuffers.(engine.buffersL[slot], capture, fadeFrames + 8, count - (2 * fadeFrames) - 16);
    capture.free; server.sync;
    reset.(slot);
    check.((comparison[0] < 1e-5) and: { comparison[1] > 0.001 } and: { engine.recordSynths[slot].isNil },
        "% (difference %, level %)".format(label, comparison[0], comparison[1]));
};
// voice playing slot (engine index) at 0.1 s grains, density 20
var startVoiceOn = { arg voice, slot, grainSize = 0.1, density = 20, pitch = 1;
    h.command(\setGrainSource, voice, slot + 1);
    server.sync;
    h.command(\voiceOn, voice, 110.0, 0.5, 0.0, grainSize, density, pitch);
    server.sync;
};
var voiceBufFrames = { arg voice; h.getControl(engine.synths[engine.grainKey(voice)], \bufFrames) };
var numBuffersReset = {
    h.stopAllVoices;
    engine.numBuffers.do({ arg slot; h.command(\clearBuffer, slot) });
    server.sync;
};
// One check of a test: an exception fails it, not the whole area
var test = { arg name, body;
    try { body.value } { arg error;
        check.(false, name ++ " (threw " ++ error.errorString ++ ")");
    };
    numBuffersReset.value;
};
// The head guard, called directly: frame and its bounds are fixed, the head
// bus set by the check. Returns the frame it left (0.1 s after the head is set)
var guardBus = Bus.control(server, 2);
var guardFrame = { arg frame, rate, durFrames, head, length, lowest = 0, highest = 1e7;
    guardBus.setn([head, length]);
    server.sync;
    measured.(\strataCheckGuard, [\frame, frame, \rate, rate, \durFrames, durFrames, \recHead, guardBus.index,
        \lowest, lowest, \highest, highest], 0.05, engine.processGroup)[0]
};
var margin = { engine.recordGuardFrames };
// voice 1 is engine.voice index 0
var lateLines = List.new;

SynthDef(\strataCheckRecDiff, { arg bufA, bufB, first, count, offsetB = 0, out;
    var phase = Sweep.ar(0, SampleRate.ir).min(count.max(1) - 1);
    var x = BufRd.ar(1, bufA, phase + first, 0, 1), y = BufRd.ar(1, bufB, phase + first + offsetB, 0, 1);
    Out.kr(out, [A2K.kr(Peak.ar((x - y).abs)), A2K.kr(Peak.ar(x.abs))]);
}).add;
SynthDef(\strataCheckRecValue, { arg buf, first, count, value, out;
    var phase = Sweep.ar(0, SampleRate.ir).min(count.max(1) - 1);
    Out.kr(out, A2K.kr(Peak.ar((BufRd.ar(1, buf, phase + first, 0, 1) - value).abs)));
}).add;
SynthDef(\strataCheckRecFirstAbove, { arg buf, count, threshold, out;
    var phase = Sweep.ar(0, SampleRate.ir).min(count.max(1) - 1);
    var hit = BufRd.ar(1, buf, phase, 0, 1).abs > threshold;
    Out.kr(out, A2K.kr(Latch.ar(phase, hit)));
}).add;
SynthDef(\strataCheckRecSteps, { arg buf, count, out;
    var phase = Sweep.ar(0, SampleRate.ir).min(count.max(1) - 1);
    var x = BufRd.ar(1, buf, phase, 0, 1);
    Out.kr(out, A2K.kr(Peak.ar((x - Delay1.ar(x)).abs)));
}).add;
SynthDef(\strataCheckLevelSource, { arg out, level = 0.5; Out.ar(out, K2A.ar(level) ! 2) }).add;
// value = seconds since the synth started: its first sample is 0
SynthDef(\strataCheckTimecode, { arg out; Out.ar(out, Sweep.ar(0, 1) ! 2) }).add;
SynthDef(\strataCheckMarked, { arg out;
    Out.ar(out, [Phasor.ar(0, 1, 0, 2 ** 24) / (2 ** 24), LFDNoise0.ar(8000) * 0.3]);
}).add;
SynthDef(\strataCheckCapture, { arg in, buf;
    RecordBuf.ar(In.ar(in, 2)[0], buf, loop: 0, doneAction: 2);
}).add;
SynthDef(\strataCheckGuard, { arg frame, lowest, highest, rate, durFrames, recHead, out;
    var moved = engine.slotHeadGuard(K2A.ar(frame), lowest, highest, rate, durFrames, recHead);
    Out.kr(out, A2K.kr(moved));
}).add;
SynthDef(\strataCheckMasterSum, { arg in, delayIn, reverbIn, fxMix, out;
    Out.ar(out, engine.masterSum(in, delayIn, reverbIn, fxMix));
}).add;
// One sign of the old audio and the other of the new one: any two samples
// of a grain 8 samples apart that disagree come from both sides of the head
SynthDef(\strataCheckRecSeam, { arg in, out;
    var x = In.ar(in, 2)[0];
    Out.kr(out, A2K.kr(Peak.ar((x * DelayN.ar(x, 0.01, 8 / SampleRate.ir)).neg.max(0))));
}).add;
SynthDef(\strataCheckAlternating, { arg out, period;
    Out.ar(out, (((Sweep.ar(0, 1 / period) % 2) < 1) * -1 + ((Sweep.ar(0, 1 / period) % 2) >= 1)) * 0.5 ! 2);
}).add;
server.sync;

check.((state[\headBuses].size == 8)
    and: { state[\headBuses].every({ arg bus; (bus.numChannels == 2) and: { bus.rate == \control } and: { h.readBus(bus) == [-1.0, 0.0] } }) }
    and: { h.readBus(state[\idleHead]) == [-1.0, 0.0] }
    and: { state[\voiceTaps].size == 7 }
    and: { state[\voiceTaps].every({ arg bus; (bus.numChannels == 2) and: { bus.rate == \audio } }) }
    and: { state[\tapSink].numChannels == 2 },
    "record: eight head buses read -1 and 0 and seven stereo voice taps exist");

engine.recordStatePoll.start;
check.(h.formatOf(\recordBuffer) == "ifffifif", "record: recordBuffer takes eight arguments (format ifffifif)");
tone = Synth(\strataCheckTone, [\out, engine.inputBus], inputSynth, \addBefore);
server.sync;
h.command(\loadBuffer, 0, h.stereoPath, 0);
h.waitFor({ engine.bufferFrames[0] > 0 });
record.(0, seconds);
frames = (seconds * server.sampleRate).round.asInteger;
check.((engine.bufferFrames[0] == 0) and: { engine.recordSynths[0].notNil },
    "record: recordBuffer takes eight arguments and records the input as a replace take (the slot reads empty)");
h.waitFor({ engine.bufferFrames[0] == frames }, (seconds + 1));
check.((engine.bufferFrames[0] == frames) and: { engine.recordSynths[0].isNil }
    and: { h.bufferSample(engine.buffersL[0], 500).abs > 0.001 },
    "record: recordBuffer takes eight arguments and records the input as a replace take (frames %, a sample %)".format(
        engine.bufferFrames[0], h.bufferSample(engine.buffersL[0], 500)));
tone.free; server.sync;
check.(CronePollRegistry.getPollFromName(\recordState).notNil, "record: the recordState poll exists");
h.command(\clearBuffer, 0); server.sync;

// ---- the record sources ------------------------------------------------
test.("record: input records the input bus", {
    var marked = Synth(\strataCheckMarked, [\out, engine.inputBus], inputSynth, \addBefore);
    server.sync;
    sourceMatches.(0, 0, engine.inputBus, "record: input records the input bus");
    marked.free; server.sync;
});
test.("record: a voice source records its grain output, through a source switch", {
    h.command(\loadBuffer, 5, h.stereoPath, 0);
    h.command(\loadBuffer, 6, h.stereoPath, 0);
    h.waitFor({ engine.bufferFrames[5] > 0 and: { engine.bufferFrames[6] > 0 } });
    startVoiceOn.(0, 5, 0.1, 40);
    settle.(0.2);
    sourceMatches.(3, 3, state[\voiceTaps][0], "record: a voice source records its grain output, through a source switch", 0.4,
        nil, { h.command(\setGrainSource, 0, 7) });
});
test.("record: pre-master equals masterSum, with the delay and reverb bypassed and not", {
    var sumBus = Bus.audio(server, 2), diffBus = Bus.control(server, 2), sum, probe, diff = Array.newClear(2);
    var label = "record: pre-master equals masterSum, with the delay and reverb bypassed and not";
    h.command(\setDelay, 0.05, 0.3, 0.5);
    h.command(\setReverb, 0.5, 0.5, 0.5);
    h.command(\voiceOn, 2, 220.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    settle.(0.2);
    sum = Synth(\strataCheckMasterSum, [\in, engine.filterBus, \delayIn, engine.delayBus, \reverbIn, engine.reverbBus,
        \fxMix, engine.mixBus(\fxMix), \out, sumBus], state[\tapGroup] ?? { context.xg }, \addToTail);
    probe = Synth(\strataCheckBusDiff, [\a, state[\preMasterBus] ?? { sumBus }, \b, sumBus, \out, diffBus], sum, \addAfter);
    server.sync;
    diff[0] = h.measure(probe, diffBus, 0.3);
    h.command(\setBypass, 0, 1); h.command(\setBypass, 1, 1);
    0.2.wait; server.sync;
    diff[1] = h.measure(probe, diffBus, 0.2);
    h.command(\setBypass, 0, 0); h.command(\setBypass, 1, 0);
    h.command(\voiceOff, 2);
    probe.free; sum.free; server.sync; sumBus.free; diffBus.free;
    check.(state[\preMasterBus].notNil and: { diff.every({ arg each; (each[0] < 1e-5) and: { each[1] > 0.001 } }) },
        "% (differences %)".format(label, diff.collect(_.round(1e-6))));
    h.command(\setDelay, 0.01, 0, 0);
    h.command(\setReverb, 0, 0.5, 0.5);
});
test.("record: post-master equals the master's output", {
    h.command(\voiceOn, 2, 220.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    settle.(0.2);
    sourceMatches.(1, 2, context.out_b, "record: post-master equals the master's output");
    h.command(\voiceOff, 2);
});
test.("record: a source outside 0-9 records the input", {
    var read;
    record.(1, 0.2, 1.0, 0, 12);
    settle.(0.05);
    read = engine.recordSynths[1] !? { arg synth; h.getControl(synth, \in) };
    waitDone.(1);
    check.(read == engine.inputBus.index, "record: a source outside 0-9 records the input (in = %, inputBus = %)".format(read, engine.inputBus.index));
});
test.("record: the tap group runs after the master with strataTapPreMaster first", {
    var names, master, group = state[\tapGroup], inside;
    record.(1, 0.2);
    settle.(0.05);
    names = h.synthNames(context.xg);
    inside = group !? { h.synthNames(group) } ? [];
    master = names.indexOf(\strataMaster);
    waitDone.(1);
    check.(group.notNil and: { inside.size >= 2 } and: { inside[0] == \strataTapPreMaster } and: { inside.includes(\strataRecord) }
        and: { names.indexOf(\strataTapPreMaster).notNil } and: { master < names.indexOf(\strataTapPreMaster) }
        and: { names.last == \strataRecord or: { names[names.size - 2] == \strataRecord } },
        "record: the tap group runs after the master with strataTapPreMaster first (tree: %, tap group: %)".format(names.keep(-4), inside));
});

// ---- writing --------------------------------------------------------------
test.("record: the peak buffer follows a loop recording, each bin min(1, old peak x keep + new peak)", {
    var loopSeconds = 4.0, path = writeLevelFile.("half-loop.wav", loopSeconds, 0.25), source, values, reached = false, target;
    h.command(\loadBuffer, 2, path, 0);
    h.waitFor({ engine.bufferFrames[2] > 0 });
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    engine.slotPeakBuffer(2).fill(0, engine.waveformPoints, 0.25);
    server.sync;
    record.(2, loopSeconds, 1.0, 0.5, 0, 0, 1);
    // into the last bin of the first pass (one bin is 62 ms of 4 s, and a bus read takes up to a period)
    target = 63.15 / 64 * loopSeconds * sampleRate;
    { var limit = thisThread.seconds + loopSeconds + 1;
        while { reached.not and: { thisThread.seconds < limit } } {
            reached = h.readBus(state[\headBuses][2])[0] >= target;
        };
    }.value;
    values = { var condition = Condition(false), result;
        engine.slotPeakBuffer(2).getn(0, engine.waveformPoints, { arg array; result = array; condition.test = true; condition.signal });
        h.awaitReply(condition); result }.value;
    h.command(\stopRecord, 2);
    source.free;
    waitDone.(2);
    check.(reached and: { values.size == 64 } and: { values.every({ arg each; (each - 0.625).abs < 1e-3 }) },
        "record: the peak buffer follows a loop recording, each bin min(1, old peak x keep + new peak) (head reached %, values % ... %)".format(
            reached, values.keep(2), values.keep(-2)));
});
test.("record: a second pass keeps old x feedback + new within 1e-4", {
    var loopSeconds = 1.0, path = writeLevelFile.("quarter.wav", loopSeconds, 0.25);
    var source, wraps = 0, last = -1, deviation, count = (loopSeconds * sampleRate).round.asInteger, scan;
    h.command(\loadBuffer, 2, path, 0);
    h.waitFor({ engine.bufferFrames[2] > 0 });
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    server.sync;
    record.(2, loopSeconds, 1.0, 0.5, 0, 0, 1);
    h.waitFor({ var head = h.readBus(state[\headBuses][2])[0];
        if (head >= 0 and: { head < last }) { wraps = wraps + 1 };
        if (head >= 0) { last = head };
        wraps >= 2 }, loopSeconds * 4);
    // frames from 0.5 D to 0.9 D have had exactly two passes (the head is early in its third)
    deviation = deviationFrom.(engine.buffersL[2], (count * 0.5).asInteger, (count * 0.4).asInteger, 0.8125);
    h.command(\stopRecord, 2);
    source.free;
    waitDone.(2);
    check.((wraps >= 2) and: { deviation < 1e-4 },
        "record: a second pass keeps old x feedback + new within 1e-4 (% wraps, deviation %)".format(wraps, deviation));
});
test.("record: loop mode wraps at D and keeps going until stopRecord", {
    var loopSeconds = 0.25, count = (loopSeconds * sampleRate).round.asInteger, wrapped = false, last = 0, heads = List.new;
    var running, beyond, path = writeLevelFile.("past-d.wav", 1.0, 0.7);
    h.command(\loadBuffer, 2, path, 0);
    h.waitFor({ engine.bufferFrames[2] > 0 });
    record.(2, loopSeconds, 1.0, 0, 0, 0, 1);
    20.do({ var head = h.readBus(state[\headBuses][2])[0];
        if (head >= 0) { heads.add(head); if (head < last) { wrapped = true }; last = head };
        0.05.wait });
    running = engine.recordSynths[2].notNil and: { h.readBus(state[\headBuses][2])[1] == count };
    h.command(\stopRecord, 2);
    waitDone.(2);
    beyond = h.bufferSample(engine.buffersL[2], count + 2000);
    check.(wrapped and: { running } and: { heads.every({ arg head; head < count }) } and: { engine.bufferFrames[2] == (1.0 * sampleRate).round.asInteger } and: { engine.recordSynths[2].isNil } and: { (beyond - 0.7).abs < 1e-3 },
        "record: loop mode wraps at D and keeps going until stopRecord (wrapped %, running %, head max %, frames %, past D %)".format(
            wrapped, running, heads.maxItem, engine.bufferFrames[2], beyond));
});
test.("record: the 5 ms fades leave no step over 0.01 on a constant signal", {
    var source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    var count = (0.2 * sampleRate).round.asInteger, peak;
    server.sync;
    record.(3, 0.2);
    waitDone.(3);
    source.free; server.sync;
    peak = stepPeak.(engine.buffersL[3], count);
    check.(peak < 0.01, "record: the 5 ms fades leave no step over 0.01 on a constant signal (largest step %)".format(peak));
});
test.("record: a replace take without threshold or delay equals 3.2's except its first and last 5 ms", {
    var duration = 0.5, count = (duration * sampleRate).round.asInteger;
    var framesBus = Bus.control(server, 1), input, starts, offset, later, earlier, comparison;
    input = Synth(\strataCheckMarked, [\out, engine.inputBus], inputSynth, \addBefore);
    server.sync;
    Synth(h.def32[\record], [\in, engine.inputBus, \bufnumL, engine.buffersL[1].bufnum, \bufnumR, engine.buffersR[1].bufnum,
        \level, 1.0, \duration, duration, \framesOut, framesBus.index], inputSynth, \addAfter);
    record.(0, duration);
    (duration + 0.3).wait;
    h.waitFor({ engine.bufferFrames[0] == count }, 2);
    input.free; server.sync;
    // the sample each take recorded just after its fade (frame 0 is faded)
    starts = [0, 1].collect({ arg slot; (h.bufferSample(engine.buffersL[slot], fadeFrames + 8) * (2 ** 24)).round.asInteger - (fadeFrames + 8) });
    offset = (starts[0] - starts[1]).abs;
    later = if (starts[0] >= starts[1]) { 0 } { 1 };
    earlier = 1 - later;
    comparison = compareBuffers.(engine.buffersL[later], engine.buffersL[earlier], fadeFrames + 8,
        count - offset - (2 * fadeFrames) - 16, offset);
    framesBus.free;
    check.(((offset % blockSize) == 0) and: { (comparison[0] < 1e-6) and: { comparison[1] > 0.001 } },
        "record: a replace take without threshold or delay equals 3.2's except its first and last 5 ms (offset %, difference %)".format(
            offset, comparison[0]));
});

// ---- arming -------------------------------------------------------------
test.("record: the threshold arms at the crossing and the take starts 10 ms before it", {
    var count = (0.2 * sampleRate).round.asInteger, source, armedBefore, marker;
    record.(0, 0.2, 1.0, 0, 0, 0.25);
    settle.(0.1);
    armedBefore = h.readBus(state[\headBuses][0])[0];
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    waitDone.(0, 2);
    source.free; server.sync;
    marker = firstFrameAbove.(engine.buffersL[0], count, 0.2);
    check.((armedBefore == -1) and: { engine.bufferFrames[0] == count } and: { marker.inclusivelyBetween(464, 640) },
        "record: the threshold arms at the crossing and the take starts 10 ms before it (head before % , the crossing at frame %)".format(armedBefore, marker));
});
test.("record: a source below the threshold never starts", {
    var source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.1], inputSynth, \addBefore);
    var start = nowReports.value, head, states;
    server.sync;
    record.(0, 0.2, 1.0, 0, 0, 0.25);
    0.4.wait; server.sync;
    head = h.readBus(state[\headBuses][0])[0];
    h.command(\stopRecord, 0);
    settle.(0.05);
    source.free; server.sync;
    states = reportsFor.(0, start).collect(_[2]);
    check.((head == -1) and: { states.includes(1).not } and: { engine.recordSynths[0].isNil },
        "record: a source below the threshold never starts (head %, states %)".format(head, states));
});
test.("record: delay starts the take within one block of its timestamp, also after a replace take's fade and zeroing", {
    var delay = 0.4, frame = 2000, value, error, id = server.nextNodeID;
    var path = writeLevelFile.("playing.wav", 1, 0.3);
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] > 0 });
    startVoiceOn.(1, 4);
    settle.(0.05);
    // a timestamped timecode: the take must hear its value 0 on its first frame
    record.(4, 0.3, 1.0, 0, 0, 0, 0, delay);
    server.sendBundle(delay, ['/s_new', \strataCheckTimecode, id, 2, inputSynth.nodeID, \out, engine.inputBus.index]);
    waitDone.(4, delay + 1);
    server.sendBundle(nil, ['/n_free', id]);
    server.sync;
    value = h.bufferSample(engine.buffersL[4], frame);
    error = (value - (frame / sampleRate)).abs * sampleRate;
    check.(error <= (blockSize + 1),
        "record: delay starts the take within one block of its timestamp, also after a replace take's fade and zeroing (off by % frames)".format(error.round(1)));
});
test.("record: a synced replace take keeps its slot playing until bufferFadeWait + recordPrepMargin before the take", {
    var delay = 1.0, before, after, duringPlay, path = writeLevelFile.("slot.wav", 1, 0.3);
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] > 0 });
    startVoiceOn.(1, 4);
    record.(4, 0.3, 1.0, 0, 0, 0, 0, delay);
    (delay - (engine.bufferFadeWait + engine.recordPrepMargin) - 0.1).wait; server.sync;
    before = engine.bufferFrames[4]; duringPlay = voiceBufFrames.(1);
    0.2.wait; server.sync;
    after = engine.bufferFrames[4];
    waitDone.(4, 2);
    check.((before > 0) and: { duringPlay == before } and: { after == 0 },
        "record: a synced replace take keeps its slot playing until bufferFadeWait + recordPrepMargin before the take (before %, voice %, after %)".format(before, duringPlay, after));
});
test.("record: a load sent during a synced take's wait drops its preparation", {
    var path = writeLevelFile.("slot.wav", 1, 0.3), nodes;
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] > 0 });
    record.(4, 0.3, 1.0, 0, 0, 0, 0, 0.6);
    0.1.wait;
    h.command(\loadBuffer, 4, h.monoPath, 0);
    0.8.wait; server.sync;
    nodes = h.synthNames(context.xg);
    check.((engine.bufferFrames[4] == 4410) and: { engine.recordSynths[4].isNil } and: { nodes.includes(\strataRecord).not },
        "record: a load sent during a synced take's wait drops its preparation (% frames, record synths: %)".format(engine.bufferFrames[4], nodes.includes(\strataRecord)));
});
test.("record: with a delay and a threshold, arming begins at the delay and the level starts the take", {
    var delay = 0.3, count = (0.15 * sampleRate).round.asInteger, source, head, marker, written;
    // above the threshold before the delay: nothing is written until the delay is over
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    server.sync;
    record.(0, 0.15, 1.0, 0, 0, 0.25, 0, delay);
    (delay * 0.5).wait; server.sync;
    head = h.readBus(state[\headBuses][0])[0];
    written = h.bufferSample(engine.buffersL[0], 100);
    source.free; server.sync;
    h.command(\stopRecord, 0); settle.(0.05);
    reset.(0);
    // silent past the delay: arming begins at the delay, the level starts the take
    record.(0, 0.15, 1.0, 0, 0, 0.25, 0, delay);
    (delay + 0.1).wait;
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    waitDone.(0, 2);
    source.free; server.sync;
    marker = firstFrameAbove.(engine.buffersL[0], count, 0.2);
    check.((head == -1) and: { written == 0 } and: { engine.bufferFrames[0] == count } and: { marker.inclusivelyBetween(464, 640) },
        "record: with a delay and a threshold, arming begins at the delay and the level starts the take (head during the wait %, sample %, crossing at frame %)".format(head, written, marker));
});
test.("record: a delay shorter than the preparation starts the take when it is done and posts how late", {
    var path = writeLevelFile.("playing.wav", 1, 0.3), start, states;
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] > 0 });
    startVoiceOn.(1, 4);
    settle.(0.05);
    start = nowReports.value;
    record.(4, 0.2, 1.0, 0, 0, 0, 0, 0.02);
    waitDone.(4, 2);
    states = reportsFor.(4, start).collect(_[2]);
    check.(state[\lastLateLine].notNil and: { state[\lastLateLine].contains("strata: buffer 5 recording started") }
        and: { state[\lastLateLine].contains("ms late") } and: { states.includes(1) } and: { engine.bufferFrames[4] > 0 },
        "record: a delay shorter than the preparation starts the take when it is done and posts how late (line %, states %)".format(state[\lastLateLine], states));
});

// ---- playable recordings ---------------------------------------------------
test.("record: a playable recording keeps the slot playing and sets its length to max(V, D) at its start", {
    var path = writeLevelFile.("value.wav", 0.5, 0.3), v = (0.5 * sampleRate).round.asInteger;
    var d = (1.0 * sampleRate).round.asInteger, atCommand, atStart, atGrain, source;
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] == v });
    startVoiceOn.(1, 4);
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    server.sync;
    record.(4, 1.0, 1.0, 0.5);
    atCommand = engine.bufferFrames[4];
    settle.(0.2);
    atStart = engine.bufferFrames[4];
    atGrain = voiceBufFrames.(1);
    h.command(\stopRecord, 4);
    waitDone.(4);
    source.free; server.sync;
    check.((atCommand == v) and: { atStart == d } and: { atGrain == d } and: { engine.bufferFrames[4] == d },
        "record: a playable recording keeps the slot playing and sets its length to max(V, D) at its start (at the command %, at the start %, voice %, at the end %)".format(
            atCommand, atStart, atGrain, engine.bufferFrames[4]));
});
test.("record: the length never shrinks", {
    var path = writeLevelFile.("eight.wav", 8, 0.3), v = (8 * sampleRate).round.asInteger, atStart;
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] == v }, 5);
    record.(4, 4.0, 1.0, 0.5);
    settle.(0.2);
    atStart = engine.bufferFrames[4];
    h.command(\stopRecord, 4);
    waitDone.(4);
    check.((atStart == v) and: { engine.bufferFrames[4] == v },
        "record: the length never shrinks (at the start %, at the end %)".format(atStart, engine.bufferFrames[4]));
});
test.("record: a canceled armed recording leaves the slot as it was", {
    var path = writeLevelFile.("value.wav", 0.5, 0.3), v = (0.5 * sampleRate).round.asInteger, before, after;
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] == v });
    before = h.bufferSample(engine.buffersL[4], 100);
    record.(4, 1.0, 1.0, 0.5, 0, 0.9);
    settle.(0.1);
    h.command(\stopRecord, 4);
    settle.(0.05);
    after = h.bufferSample(engine.buffersL[4], 100);
    check.((engine.bufferFrames[4] == v) and: { (before - after).abs < 1e-5 } and: { engine.recordSynths[4].isNil },
        "record: a canceled armed recording leaves the slot as it was (% frames, sample % -> %)".format(engine.bufferFrames[4], before, after));
});
test.("record: a playable recording into an empty slot zeroes it after the fade", {
    var stain = (1.5 * sampleRate).round.asInteger, inside, after, count = (0.3 * sampleRate).round.asInteger;
    h.command(\setGrainSource, 1, 5);
    h.command(\voiceOn, 1, 110.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    server.sync;
    engine.bufferFadeWait = 0.3;
    engine.buffersL[4].set(stain, 0.7);
    server.sync;
    record.(4, 0.3, 1.0, 0.5);
    0.15.wait; server.sync;
    inside = h.bufferSample(engine.buffersL[4], stain);
    0.3.wait; server.sync;
    after = h.bufferSample(engine.buffersL[4], stain);
    engine.bufferFadeWait = 0.06;
    waitDone.(4);
    check.(((inside - 0.7).abs < 1e-3) and: { after == 0 } and: { engine.bufferFrames[4] == count },
        "record: a playable recording into an empty slot zeroes it after the fade (during the fade %, after %, % frames)".format(inside, after, engine.bufferFrames[4]));
});
test.("record: a playable recording into a 44.1 kHz slot becomes a replace take and leaves the slot at the server rate", {
    var path = h.tempDir +/+ "cd-rate.wav", during, take = (0.2 * sampleRate).round.asInteger;
    h.writeTestFile(path, 44100, 22050, [0.25, 0.25]);
    h.command(\loadBuffer, 4, path, 0);
    h.waitFor({ engine.bufferFrames[4] > 0 });
    record.(4, 0.2, 1.0, 0.5, 0, 0, 1);
    during = engine.bufferFrames[4];
    settle.(0.1);
    waitDone.(4, 2);
    check.((during == 0) and: { engine.bufferSampleRates[4] == sampleRate } and: { engine.bufferFrames[4] == take },
        "record: a playable recording into a 44.1 kHz slot becomes a replace take and leaves the slot at the server rate (during %, rate %, frames %)".format(
            during, engine.bufferSampleRates[4], engine.bufferFrames[4]));
});

// ---- the head guard ----------------------------------------------------------
test.("record: no grain reads across the head at rates -4, -1, 0.5, 1 and 4 with 0.5 s grains", {
    // (6 s: with 2 s of reverse read at rate -4 a shorter loop leaves head positions with no safe start)
    var loopSeconds = 6.0, oldLevel = 0.5, voices = 4;
    var path = writeLevelFile.("guard.wav", loopSeconds, oldLevel), results = List.new;
    var rates = [[4, 0], [1, 0], [0.5, 0], [4, 1], [1, 1]];   // [|rate|, reverse probability]
    h.command(\loadBuffer, 2, path, 0);
    h.waitFor({ engine.bufferFrames[2] > 0 }, 3);
    rates.do({ arg pair;
        var rate = pair[0], reverse = pair[1], delay = 0.3, source, probes, buses, id = server.nextNodeID;
        var group = Group.tail(context.xg);
        buses = voices.collect({ Bus.control(server, 2) });
        probes = voices.collect({ arg voice;
            Synth(\strataCheckRecSeam, [\in, state[\voiceTaps][voice], \out, buses[voice]], group);
        });
        // pass n writes (-1)^(n + 1) x 0.5: the head always separates the two signs
        record.(2, loopSeconds, 1.0, 0, 0, 0, 1, delay);
        server.sendBundle(delay, ['/s_new', \strataCheckAlternating, id, 2, inputSynth.nodeID,
            \out, engine.inputBus.index, \period, loopSeconds]);
        // the voices start once the head runs (grains already playing when
        // a recording starts are not moved: design 3.3 section 1.5)
        (delay + 0.1).wait; server.sync;
        voices.do({ arg voice;
            h.command(\setGrainSource, voice, 3);
            h.command(\voiceOn, voice, 110.0, 0.5, 0.0, 0.5, 1.9, rate);
            h.command(\setGrainParam, voice, \reverseProb, reverse);
            h.command(\setGrainParam, voice, \panJitter, 0);
            h.command(\setGrainParam, voice, \sizeJitter, 0);
            h.command(\setGrainParam, voice, \bufPos, voice / voices);
            h.command(\setGrainParam, voice, \posSpread, 1);
        });
        server.sync;
        2.2.wait; server.sync;
        results.add([rate, reverse, buses.collect({ arg bus; h.readBus(bus)[0] })]);
        h.command(\stopRecord, 2);
        waitDone.(2);
        server.sendBundle(nil, ['/n_free', id]);
        voices.do({ arg voice; h.command(\voiceOff, voice) });
        group.free; server.sync; buses.do(_.free);
        h.stopAllVoices;
    });
    check.(results.every({ arg each; each[2].every({ arg value; value < 1e-3 }) }),
        "record: no grain reads across the head at rates -4, -1, 0.5, 1 and 4 with 0.5 s grains (% , largest sign-flip product per voice)".format(
            results.collect({ arg each; [each[0], each[1], each[2].maxItem.round(1e-5)] })));
});
test.("record: the guard's zone follows the grain's life in output frames, at rates 4 and 0.5", {
    var head = 5 * sampleRate, d = 12 * sampleRate, m = margin.value;
    // rate 4, a 2 s grain's frames: life 0.5 s, below = m + 3 x 0.5 s = m + 1.5 s
    var at4InZone = guardFrame.(head - m - sampleRate, 4, 2 * sampleRate, head, d);
    var at4Outside = guardFrame.(head - m - (2 * sampleRate), 4, 2 * sampleRate, head, d);
    // rate 0.5, 0.25 s of frames: life 0.5 s, above = m + 0.5 x 0.5 s = m + 0.25 s
    var atHalfInZone = guardFrame.(head + m + (0.2 * sampleRate), 0.5, 0.25 * sampleRate, head, d);
    var atHalfOutside = guardFrame.(head + m + (0.3 * sampleRate), 0.5, 0.25 * sampleRate, head, d);
    var expectLow4 = head - m - (1.5 * sampleRate);
    var expectLowHalf = head - m;
    check.(((at4InZone - expectLow4).abs < 2) and: { (at4Outside - (head - m - (2 * sampleRate))).abs < 2 }
        and: { (atHalfInZone - expectLowHalf).abs < 2 } and: { (atHalfOutside - (head + m + (0.3 * sampleRate))).abs < 2 },
        "record: the guard's zone follows the grain's life in output frames, at rates 4 and 0.5 (rate 4: % -> %, % -> %; rate 0.5: % -> %, % -> %)".format(
            head - m - sampleRate, at4InZone.round(1), head - m - (2 * sampleRate), at4Outside.round(1),
            head + m + (0.2 * sampleRate), atHalfInZone.round(1), head + m + (0.3 * sampleRate), atHalfOutside.round(1)));
});
test.("record: the head guard is a no-op with the head bus at -1", {
    var frame = 1000, value = guardFrame.(frame, 4, 2 * sampleRate, -1, 0);
    check.((value - frame).abs < 1e-3, "record: the head guard is a no-op with the head bus at -1 (frame % -> %)".format(frame, value));
});
test.("record: the head bus reads -1 after the record synth frees", {
    var during, after;
    record.(1, 0.2, 1.0, 0, 0, 0, 1);
    settle.(0.1);
    during = h.readBus(state[\headBuses][1]);
    h.command(\stopRecord, 1);
    waitDone.(1);
    settle.(0.05);
    after = h.readBus(state[\headBuses][1]);
    check.((during[0] >= 0) and: { during[1] > 0 } and: { after == [-1.0, 0.0] },
        "record: the head bus reads -1 after the record synth frees (during %, after %)".format(during, after));
});
test.("record: a loop shorter than the guard zone keeps its grains sounding inside the valid region", {
    var loopSeconds = 0.25, v = 4.0, path = writeLevelFile.("short.wav", v, 0.5), source, peakBus, badBus, peak, bad, group;
    var d = (loopSeconds * sampleRate).round.asInteger, validFrames = (v * sampleRate).round.asInteger;
    var durFrames = 0.5 * 4 * sampleRate, highest = (validFrames - engine.grainEndMargin - durFrames).max(0);
    var head = 0.1 * sampleRate, positions;
    h.command(\loadBuffer, 2, path, 0);
    h.waitFor({ engine.bufferFrames[2] > 0 });
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    server.sync;
    record.(2, loopSeconds, 1.0, 0.5, 0, 0, 1);
    h.command(\setGrainSource, 0, 3);
    h.command(\voiceOn, 0, 110.0, 0.5, 0.0, 0.5, 20.0, 4.0);
    h.command(\setGrainParam, 0, \loopStart, 0);
    h.command(\setGrainParam, 0, \loopLength, loopSeconds / v);
    h.command(\setGrainParam, 0, \posSpread, 1);
    peakBus = Bus.control(server, 2); badBus = Bus.control(server, 2);
    group = Group.tail(context.xg);
    Synth(\strataCheckPeak, [\in, state[\voiceTaps][0], \out, peakBus], group);
    Synth(\strataCheckBadValues, [\in, state[\voiceTaps][0], \out, badBus], group);
    server.sync;
    1.0.wait;
    peak = h.readBus(peakBus)[0];
    bad = h.readBus(badBus)[0];
    h.command(\stopRecord, 2);
    h.command(\voiceOff, 0);
    waitDone.(2);
    source.free; group.free; server.sync; peakBus.free; badBus.free;
    // every start is in the zone (it is 1.5 s wide, the loop 0.25 s), so
    // the guard moves each one: it must stay inside [lowest, highest]
    positions = [0, 0.05, 0.1, 0.2, 0.24].collect({ arg seconds;
        guardFrame.(seconds * sampleRate, 4, durFrames, head, d, 0, highest)
    });
    check.((peak > 0.0316) and: { bad < 0.5 } and: { positions.every({ arg position; position.inclusivelyBetween(0, highest) }) },
        "record: a loop shorter than the guard zone keeps its grains sounding inside the valid region (peak %, bad %, positions %, highest %)".format(
            peak, bad, positions.round(1), highest));
});

// ---- the recordState reports ----------------------------------------------
test.("record: recordState reports armed, recording, ended and canceled with the record number, in order", {
    var start = nowReports.value, reports, number, states, numbers, canceled;
    number = engine.areaState[\record][\recordCounts][2] + 1;
    record.(2, 0.15, 1.0, 0, 0, 0, 0, 0.2);
    waitDone.(2, 2);
    settle.(0.1);
    record.(2, 0.15, 1.0, 0, 0, 0.9);
    settle.(0.1);
    h.command(\clearBuffer, 2);
    settle.(0.1);
    reports = reportsFor.(2, start);
    states = reports.collect(_[2]);
    numbers = reports.collect(_[1]);
    check.((states == [0, 1, 2, 0, 3]) and: { numbers == [number, number, number, number + 1, number + 1] },
        "record: recordState reports armed, recording, ended and canceled with the record number, in order (states %, numbers %)".format(states, numbers));
});
test.("record: reports carry their record number", {
    var start = nowReports.value, reports, number = engine.areaState[\record][\recordCounts][1];
    record.(1, 0.1);
    waitDone.(1, 2);
    settle.(0.1);
    reports = reportsFor.(1, start);
    check.(reports.notEmpty and: { reports.every({ arg each; each[1] == (number + 1) }) },
        "record: reports carry their record number (reports %, record number %)".format(reports, number + 1));
});
test.("record: rapid record, load, clear and stop leave at most one record synth and drop every late step", {
    var running, slot = 3, path = writeLevelFile.("value.wav", 0.5, 0.3);
    h.command(\loadBuffer, slot, path, 0);
    h.waitFor({ engine.bufferFrames[slot] > 0 });
    startVoiceOn.(1, slot);
    settle.(0.05);
    record.(slot, 0.5);
    record.(slot, 0.4, 1.0, 0.5);
    h.command(\clearBuffer, slot);
    record.(slot, 0.3, 1.0, 0, 0, 0, 0, 0.1);
    h.command(\loadBuffer, slot, h.monoPath, 0);
    record.(slot, 0.2);
    h.command(\stopRecord, slot);
    record.(slot, 0.2);
    settle.(0.15);
    running = h.synthNames(context.xg).count({ arg name; name == \strataRecord });
    waitDone.(slot, 2);
    settle.(0.2);
    check.((running <= 1) and: { engine.recordSynths[slot].isNil } and: { engine.bufferFrames[slot] == (0.2 * sampleRate).round.asInteger }
        and: { h.synthNames(context.xg).includes(\strataRecord).not },
        "record: rapid record, load, clear and stop leave at most one record synth and drop every late step (running %, % frames)".format(running, engine.bufferFrames[slot]));
});
test.("record: a stopped recording's frame count is read in onFree and includes its fade", {
    var atStop, kept, slot = 1, source, inFade, past;
    source = Synth(\strataCheckLevelSource, [\out, engine.inputBus, \level, 0.5], inputSynth, \addBefore);
    server.sync;
    record.(slot, 0.8);
    settle.(0.25);
    atStop = h.readBusValue(engine.recordFrameBuses[slot]);
    h.command(\stopRecord, slot);
    waitDone.(slot, 2);
    settle.(0.1);
    kept = engine.bufferFrames[slot];
    source.free; server.sync;
    // within the frames kept the signal is still fading (the count includes
    // the 5 ms fade), just past them nothing was written
    inFade = h.bufferSample(engine.buffersL[slot], kept - (fadeFrames / 2).asInteger - blockSize);
    past = h.bufferSample(engine.buffersL[slot], kept + 2);
    check.(kept.inclusivelyBetween(atStop + fadeFrames - blockSize, atStop + fadeFrames + 2048 + (4 * blockSize))
        and: { inFade.abs > 0.05 } and: { past == 0 } and: { engine.stopReplies[slot].isNil },
        "record: a stopped recording's frame count is read in onFree and includes its fade (% frames at the stop, % kept, % in the fade, % past it)".format(
            atStop, kept, inFade, past));
});
test.("record: a load, clear or recording during the stop fade frees it at once and drops the take", {
    var slot = 1, results = List.new;
    [
        ["clear", { h.command(\clearBuffer, slot) }, 0],
        ["load", { h.command(\loadBuffer, slot, h.monoPath, 0) }, 4410],
        ["recording", { record.(slot, 0.1) }, (0.1 * sampleRate).round.asInteger]
    ].do({ arg case;
        var name = case[0], act = case[1], frames = case[2], running;
        record.(slot, 0.8);
        settle.(0.15);
        h.command(\stopRecord, slot);
        act.value;
        server.sync;
        running = h.synthNames(context.xg).count({ arg each; each == \strataRecord });
        0.5.wait; server.sync;
        results.add([name, running, engine.bufferFrames[slot], frames]);
        h.waitFor({ engine.recordSynths[slot].isNil }, 2);
        reset.(slot);
    });
    check.(results.every({ arg each; (each[1] <= 1) and: { each[2] == each[3] } }),
        "record: a load, clear or recording during the stop fade frees it at once and drops the take (%)".format(results));
});
test.("record: an armed recording stopped before it starts keeps nothing", {
    var before;
    reset.(1);
    record.(1, 0.3, 1.0, 0, 0, 0.9);
    settle.(0.1);
    before = engine.bufferFrames[1];
    h.command(\stopRecord, 1);
    settle.(0.1);
    check.((before == 0) and: { engine.bufferFrames[1] == 0 } and: { engine.recordSynths[1].isNil },
        "record: an armed recording stopped before it starts keeps nothing (before %, after %)".format(before, engine.bufferFrames[1]));
});
test.("record: a take with no delay or threshold reports recording and ended, never armed", {
    var start = nowReports.value, states;
    record.(1, 0.1);
    waitDone.(1, 2);
    settle.(0.1);
    states = reportsFor.(1, start).collect(_[2]);
    check.(states == [1, 2], "record: a take with no delay or threshold reports recording and ended, never armed (states %)".format(states));
});
test.("record: a clear cancels an armed recording and reports canceled", {
    var start = nowReports.value, states;
    record.(1, 0.3, 1.0, 0, 0, 0.9);
    settle.(0.1);
    h.command(\clearBuffer, 1);
    settle.(0.1);
    states = reportsFor.(1, start).collect(_[2]);
    check.(states.last == 3 and: { engine.recordSynths[1].isNil },
        "record: a clear cancels an armed recording and reports canceled (states %)".format(states));
});

// ---- the end of a take -----------------------------------------------------
test.("record: a take writes its peaks, then reports its length, then writes the scratch take", {
    var steps, slot = 1;
    record.(slot, 0.1);
    waitDone.(slot, 2);
    settle.(0.1);
    steps = state[\endSteps] !? { arg all; all[slot] !? _.asArray };
    check.((steps == [\peaksRead, \peaksWritten, \reported, \scratchWritten]),
        "record: a take writes its peaks, then reports its length, then writes the scratch take (steps %)".format(steps));
});
test.("record: a loop recording's peaks file refreshes every peakRefreshSeconds without a bufferState report", {
    var loopSeconds = 0.25, before, framesBefore, refreshes, reportsBefore, reportsAfter, slot = 2;
    var counters = { state[\peakWrites] ?? { (reports: 0, refreshes: 0) } };
    record.(slot, loopSeconds, 1.0, 0, 0, 0, 1);
    settle.(0.1);
    before = counters.value.copy;
    framesBefore = engine.bufferFrames[slot];
    1.6.wait; server.sync;
    refreshes = counters.value[\refreshes] - before[\refreshes];
    reportsAfter = counters.value[\reports] - before[\reports];
    h.command(\stopRecord, slot);
    waitDone.(slot, 2);
    check.((refreshes == 3) and: { reportsAfter == 0 } and: { engine.bufferFrames[slot] == framesBefore },
        "record: a loop recording's peaks file refreshes every peakRefreshSeconds without a bufferState report (% refreshes, % reports, frames %)".format(
            refreshes, reportsAfter, engine.bufferFrames[slot]));
});

guardBus.free;
engine.recordStatePoll.stop;
h.stopAllVoices;
engine.numBuffers.do({ arg slot; h.command(\clearBuffer, slot) });
server.sync;
}
