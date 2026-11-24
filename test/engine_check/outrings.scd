// test/engine_check/outrings.scd
// The output rings (3.8, package 1d): the seven rings and their writers in
// the tap group, the writer's law (softclip, bad values to 0), voices
// reading voices (sources voiceSourceFirst to voiceSourceFirst + numVoices
// - 1), a voice at dry 0 still feeding its readers, the read lag, a
// self-read, a loop held at full scale, a stopped or muted read voice, an
// extra note on a voice source and the rings' bytes against
// fixedBufferBytes; then a reader's freeze (its copy, its fade, the
// unfreeze's bundle, a late copy's retry and abandon, spectral on a high engine), the read voice's freeze and
// the input channel.
//
// The read lag is read on a timecode: a check synth adds the time (wrapped
// at timecodeWrap s and scaled under softclip's linear half) on the left and
// timecodeFlag on the right to a voice's tap, after its stage has written
// it; a grain synth with a rectangular envelope then reads left over right
// as the time its audio was written, whatever its level.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var sampleRate = server.sampleRate, block = server.options.blockSize;
var first = engine.tryPerform(\voiceSourceFirst) ? (engine.numBuffers + 2);
var sourceOf = { arg readVoice; first + readVoice };
var timecodeWrap = 64, timecodeFlag = 0.5, silence = 1e-4;
var state, taps, tapGroup, probeGroup, quietBus, nowBus, readOut, rectEnv, tone, readings, ok, nodes, writers;
var outRing, grainOf, startReader, timeReads, peakOver, levelOver, ringPeaks, stepBus, stepProbe, steps, bufnums;
var tapSound, stages, badBus, badProbe, scratchL, scratchR, phaseBus, writer, units, record, expect, mixBuses, reader;
var fadeWaitBefore, copyRing, inOneBundle, heardBus, heardProbe, inputRing, root, other, otherCommand, spectralNodes, copiedAt;
var lateCopyChecks;

// A grain synth's reads of the timecode while seconds pass: [largest
// lookback, smallest lookback] (s), read only while the right channel is on
SynthDef(\strataCheckOutRead, { arg in, now, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset);
    var on = sig[1] > (0.05 * timecodeFlag);
    var written = sig[0] / sig[1].max(0.0001) * timecodeWrap;
    var lookback = (In.ar(now, 1) - written).wrap(-0.5 * timecodeWrap, 0.5 * timecodeWrap);
    Out.kr(out, A2K.kr([
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), lookback]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), lookback]), reset)
    ]));
}).add;
// The timecode, added to a bus (a voice's tap), and the time to now
SynthDef(\strataCheckOutTimecode, { arg out, now;
    var time = Sweep.ar(0, 1).wrap(0, timecodeWrap);
    Out.ar(out, [time * (timecodeFlag / timecodeWrap), DC.ar(timecodeFlag)]);
    Out.ar(now, time);
}).add;
// A constant pair added to a bus, and a pair of inf (left) and NaN (right)
// that never ends (the writer's law)
SynthDef(\strataCheckOutConstant, { arg out, left = 0, right = 0; Out.ar(out, [DC.ar(left), DC.ar(right)]) }).add;
SynthDef(\strataCheckOutBad, { arg out, big = 1e30;
    var infinite = DC.ar(big) * big;
    Out.ar(out, [infinite, infinite - infinite]);
}).add;
// A 440 Hz tone added to a bus (a voice's tap)
SynthDef(\strataCheckOutTone, { arg out, level = 0.3; Out.ar(out, SinOsc.ar(440, 0, level) ! 2) }).add;
// The largest sample of a mono buffer over a pass of it (bad values left
// out) and 1 once a NaN or inf was read: [peak, bad]
SynthDef(\strataCheckOutRingPeak, { arg buf, out, t_reset = 0;
    var frames = BufFrames.kr(buf), sig = BufRd.ar(1, buf, Phasor.ar(0, 1, 0, frames), 1, 1);
    var code = CheckBadValues.ar(sig, 0, 0), bad = (code > 0.5) * (code < 2.5), reset = T2A.ar(t_reset);
    Out.kr(out, A2K.kr([Peak.ar(Select.ar(code > 0.5, [sig, DC.ar(0)]).abs, reset), Peak.ar(bad, reset)]));
}).add;
// A stereo bus's mean square since t_reset: [the integral, the seconds]
SynthDef(\strataCheckOutLevel, { arg in, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset);
    Out.kr(out, A2K.kr([Integrator.ar(sig.squared.sum * 0.5 * SampleDur.ir, 1 - reset), Sweep.ar(reset, 1)]));
}).add;
// A phase bus's step from one block to the next (frames, wrapped at the
// ring's), since t_reset: [the smallest, the largest, how many runs of
// steps were neither 0 nor block] (freeze.scd's probe)
SynthDef(\strataCheckOutHeadStep, { arg in, out, frames = 1, block = 64, t_reset = 0;
    var head = In.kr(in), step = (head - Delay1.kr(head)).wrap(0, frames);
    var other = ((step - block).abs > 0.5) * (step > 0.5);
    Out.kr(out, [RunningMin.kr(step, t_reset), RunningMax.kr(step, t_reset), PulseCount.kr(other, t_reset)]);
}).add;
// Two mono buffers read sample for sample, the second offset frames on
// (wrapped): [the largest difference, the first's level] since t_reset
SynthDef(\strataCheckOutRotation, { arg bufA, bufB, offset = 0, out, t_reset = 0;
    var frames = BufFrames.kr(bufA), phase = Phasor.ar(0, 1, 0, frames), reset = T2A.ar(t_reset);
    var x = BufRd.ar(1, bufA, phase, 1, 1), y = BufRd.ar(1, bufB, (phase + offset).wrap(0, frames), 1, 1);
    Out.kr(out, A2K.kr([Peak.ar((x - y).abs, reset), Peak.ar(x.abs, reset)]));
}).add;
// The timecode a copy ring holds over frames frames from start, read only
// where its right channel is on: [the newest, the oldest] since t_reset
SynthDef(\strataCheckOutCopyTimes, { arg bufL, bufR, start = 0, frames = 1, out, t_reset = 0;
    var phase = Phasor.ar(0, 1, 0, frames) + start, reset = T2A.ar(t_reset);
    var left = BufRd.ar(1, bufL, phase, 1, 1), right = BufRd.ar(1, bufR, phase, 1, 1);
    var on = right > (0.05 * timecodeFlag), written = left / right.max(0.0001) * timecodeWrap;
    Out.kr(out, A2K.kr([
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), written]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), written]), reset)
    ]));
}).add;
// Seconds from t_reset until a stereo bus first passes 0.001
SynthDef(\strataCheckOutHeard, { arg in, out, t_reset = 0;
    var reset = T2A.ar(t_reset), heard = SetResetFF.ar(In.ar(in, 2).abs.sum > 0.001, reset);
    Out.kr(out, A2K.kr(Sweep.ar(reset, 1 - heard)));
}).add;
server.sync;

// Whether one packet (a bundle) sets node nodeID's bufL and its freeze to
// value (freeze.scd's)
inOneBundle = { arg packets, nodeID, value;
    var sets = { arg msg; ["15", "/n_set", "n_set"].includesEqual(msg[0].asString) and: { msg[1] == nodeID } };
    var nameAt = { arg msg, name;
        msg.detectIndex({ arg item, index; (index >= 2) and: { index.even } and: { item.asString == name.asString } }) };
    packets.any({ arg packet;
        packet.any({ arg msg; sets.(msg) and: { nameAt.(msg, \bufL).notNil } })
            and: { packet.any({ arg msg; var at; sets.(msg) and: { (at = nameAt.(msg, \freeze)).notNil } and: { msg[at + 1] == value } }) }
    })
};

state = engine.areaState[\outRings];
taps = engine.areaState[\record][\voiceTaps];
tapGroup = engine.areaState[\record][\tapGroup];
// after processGroup (every stage has written its tap), before the master
// filters and the tap group
probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);
nowBus = Bus.audio(server, 1);
readOut = Bus.audio(server, 2);
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
stepBus = Bus.control(server, 3);
server.sync;

outRing = { arg voice; engine.tryPerform(\outRingFor, voice) ? [] };
grainOf = { arg voice; engine.synths[engine.grainKey(voice)] };
// A voice on a source, running, its grains steady (no position spread or
// pan wander) and, for the timecode, through the rectangular envelope
startReader = { arg voice, source, size = 0.1, density = 20.0, amp = 0.2, rect = false;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 100.0, amp, 0.0, size, density, 1.0);
    server.sync;
    engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.set(\out, quietBus.index) };
    [\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, voice, control, 0.0) });
    if (rect) { grainOf.(voice).set(\envBuf, rectEnv.bufnum) };
    server.sync;
};
// A voice's grain synth to readOut, then its timecode reads while seconds pass
timeReads = { arg voice, seconds;
    var bus = Bus.control(server, 2), probe, values;
    grainOf.(voice).set(\out, readOut.index);
    probe = Synth(\strataCheckOutRead, [\in, readOut, \now, nowBus, \out, bus], probeGroup, \addToTail);
    server.sync; 0.05.wait;
    probe.set(\t_reset, 1); server.sync;
    seconds.wait;
    values = h.readBus(bus);
    probe.free; bus.free;
    grainOf.(voice).set(\out, engine.voicePathBus(voice, engine.grainSource[voice]).index);
    values
};
// The peak of a stereo bus (both channels' sum) over seconds
peakOver = { arg bus, seconds;
    var out = Bus.control(server, 1), probe, value;
    probe = Synth(\strataCheckPeak, [\in, bus, \out, out], probeGroup, \addToTail);
    server.sync; probe.set(\t_reset, 1);
    seconds.wait;
    value = h.readBusValue(out);
    probe.free; out.free;
    value
};
// The RMS of a stereo bus over seconds
levelOver = { arg bus, seconds;
    var out = Bus.control(server, 2), probe, values;
    probe = Synth(\strataCheckOutLevel, [\in, bus, \out, out], probeGroup, \addToTail);
    server.sync; probe.set(\t_reset, 1); server.sync;
    seconds.wait;
    values = h.readBus(out);
    probe.free; out.free;
    (values[0] / values[1].max(0.001)).sqrt
};
// [peak, bad] of each buffer, over a pass of the longest
ringPeaks = { arg buffers;
    var buses = buffers.collect({ Bus.control(server, 2) }), probes, values;
    probes = buffers.collect({ arg buffer, index;
        Synth(\strataCheckOutRingPeak, [\buf, buffer, \out, buses[index]], probeGroup, \addToTail) });
    server.sync; probes.do({ arg probe; probe.set(\t_reset, 1) });
    ((buffers.collect(_.numFrames).maxItem / sampleRate) + 0.2).wait;
    values = buses.collect({ arg bus; h.readBus(bus) });
    probes.do(_.free); buses.do(_.free);
    values
};
steps = { var values = h.readBus(stepBus); (min: values[0], max: values[1], other: values[2]) };
mixBuses = [engine.mainBus, engine.mixBus(\delaySend), engine.mixBus(\reverbSend)];

// ---- The area, its rings and their writers ----
check.(state.notNil and: { [\left, \right, \phaseBuses].every({ arg key; state[key].notNil }) }
    // #943: the writers have one record, synths under outRingWriterKeys
    and: { state.includesKey(\writers).not }
    and: { (state[\left] ++ state[\right]).every({ arg buffer;
        (buffer.numFrames == (engine.tryPerform(\outRingSeconds) * sampleRate)) and: { buffer.numChannels == 1 } }) }
    and: { [state[\left], state[\right], state[\phaseBuses]].every({ arg each; each.size == engine.numVoices }) }
    and: { (state[\left] ++ state[\right]).collect(_.bufnum).asSet.size == (2 * engine.numVoices) },
    "outrings: areaState[\\outRings] holds % mono rings of outRingSeconds (% s) a channel and % phase buses, and no second record of the writers (#943)".format(
        2 * engine.numVoices, engine.tryPerform(\outRingSeconds), engine.numVoices));
check.(state.notNil and: { outRing.(2) == [state[\left][2], state[\right][2], state[\phaseBuses][2]] }
    and: { engine.ringBuffersFor(0, sourceOf.(3)) == outRing.(3) } and: { engine.ringBuffersFor(5, sourceOf.(5)) == outRing.(5) },
    "outrings: outRingFor gives a voice's output ring, and ringBuffersFor a voice source's");
check.((first == (engine.numBuffers + 2)) and: { engine.tryPerform(\voiceSource, first) == true }
    and: { engine.tryPerform(\voiceSource, first + engine.numVoices - 1) == true }
    and: { engine.tryPerform(\voiceSource, first + engine.numVoices) == false }
    and: { engine.tryPerform(\voiceSource, engine.inputSource) == false }
    and: { engine.tryPerform(\readVoiceOf, first + 2) == 2 },
    "outrings: voiceSourceFirst is numBuffers + 2; voiceSource takes it to numVoices - 1 past it; readVoiceOf gives the read voice");
// the bytes: fixedBufferBytes' out-ring term
check.(state.notNil and: { ((state[\left] ++ state[\right]).collect(_.numFrames).sum * 4)
    == (engine.numVoices * 2 * engine.outRingSeconds * sampleRate * 4) },
    "outrings: the output rings' bytes are fixedBufferBytes' term (numVoices x 2 x outRingSeconds x the rate x 4)");
// seven writers at the tail of the tap group, after the pre-master tap
nodes = h.synthTree(tapGroup);
writers = nodes.copyRange((nodes.size - engine.numVoices).max(0), nodes.size - 1);
check.((nodes.first !? { arg node; node.def } == \strataTapPreMaster)
    and: { writers.size == engine.numVoices } and: { writers.every({ arg node; node.def == \strataOutRingWrite }) }
    and: { nodes.count({ arg node; node.def == \strataOutRingWrite }) == engine.numVoices },
    "outrings: seven strataOutRingWrite at the tail of the tap group, after strataTapPreMaster (got %)".format(nodes.collect(_.def)));
check.(writers.every({ arg node, voice;
        var ring = outRing.(voice);
        (node.controls[\in] == taps[voice].index) and: { node.controls[\bufL] == ring[0].bufnum }
            and: { node.controls[\bufR] == ring[1].bufnum } and: { node.controls[\phaseOut] == ring[2].index } })
    and: { (engine.tryPerform(\outRingWriterKeys) ? []).size == engine.numVoices }
    and: { engine.outRingWriterKeys.every({ arg key, voice; (engine.synths[key] !? _.nodeID) == writers[voice].id }) }
    and: { engine.outRingWriterKeys.every({ arg key; engine.effectKeys.includes(key) }) },
    "outrings: each writer records its voice's tap into its ring, and its key is an effect key");

// the writer's law, on a check-only writer: 0.25 passes, 2 becomes 0.875
// (softclip), inf and NaN become 0
scratchL = Buffer.alloc(server, sampleRate, 1);
scratchR = Buffer.alloc(server, sampleRate, 1);
phaseBus = Bus.control(server, 1);
badBus = Bus.audio(server, 2);
server.sync;
phaseBus.set(0);
tone = Synth(\strataCheckOutConstant, [\out, badBus, \left, 0.25, \right, 2.0], probeGroup);
writer = Synth(\strataOutRingWrite, [\in, badBus, \bufL, scratchL, \bufR, scratchR, \phaseOut, phaseBus], probeGroup, \addToTail);
server.sync; 1.1.wait;
readings = [h.bufferSample(scratchL, 100), h.bufferSample(scratchR, 100)];
tone.free; writer.free;
check.(readings.notNil and: { (readings[0] - 0.25).abs < 1e-6 } and: { (readings[1] - 0.875).abs < 1e-6 },
    "outrings: the writer passes 0.25 and writes 2 as 0.875 (softclip; got %)".format(readings));
scratchL.fill(0, sampleRate, 0.3); scratchR.fill(0, sampleRate, 0.3);
server.sync;
tone = Synth(\strataCheckOutBad, [\out, badBus], probeGroup);
writer = Synth(\strataOutRingWrite, [\in, badBus, \bufL, scratchL, \bufR, scratchR, \phaseOut, phaseBus], probeGroup, \addToTail);
server.sync; 1.1.wait;
tone.free; writer.free;
server.sync;
readings = ringPeaks.([scratchL, scratchR]);
check.(readings.every({ arg pair; (pair[0] == 0) and: { pair[1] == 0 } }),
    "outrings: the writer writes inf and NaN as 0 (every frame over the 0.3 it held: [peak, bad] %)".format(readings));
[scratchL, scratchR].do(_.free); phaseBus.free; badBus.free;

// bufnums and writers unchanged, and the writer's head one block a block,
// over a voice's start, a switch and a stop
bufnums = (state[\left] ++ state[\right]).collect(_.bufnum);
writers = engine.outRingWriterKeys.collect({ arg key; engine.synths[key] });
stepProbe = Synth(\strataCheckOutHeadStep, [\in, outRing.(0)[2], \out, stepBus, \frames, outRing.(0)[0].numFrames,
    \block, block], probeGroup);
server.sync; 0.05.wait; stepProbe.set(\t_reset, 1); server.sync;
command.(\voiceOn, 0, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
0.3.wait;
command.(\setGrainSource, 0, engine.inputSource);
0.3.wait;
command.(\setGrainSource, 0, sourceOf.(1));
0.3.wait;
command.(\voiceOff, 0);
0.3.wait;
readings = steps.value;
stepProbe.free;
check.(((state[\left] ++ state[\right]).collect(_.bufnum) == bufnums)
    and: { engine.outRingWriterKeys.collect({ arg key; engine.synths[key] }) == writers }
    and: { h.synthTree(tapGroup).collect(_.id).includesAll(writers.collect(_.nodeID)) },
    "outrings: a voice's start, switches and stop leave the rings' bufnums and the writers as they were");
check.((readings[\min] == block) and: { readings[\max] == block } and: { readings[\other] == 0 },
    "outrings: a writer's head steps exactly % frames a block over a voice's start, switches and stop (steps % to %, % runs of others)".format(
        block, readings[\min], readings[\max], readings[\other]));
h.stopAllVoices;

// setGrainSource takes the last voice source and ignores the next and -1
command.(\setGrainSource, 0, first + engine.numVoices - 1);
server.sync;
ok = engine.grainSource[0] == (first + engine.numVoices - 1);
command.(\setGrainSource, 0, first + engine.numVoices);
command.(\setGrainSource, 0, -1);
server.sync;
check.(ok and: { engine.grainSource[0] == (first + engine.numVoices - 1) },
    "outrings: setGrainSource takes % (voice %'s ring) and ignores % and -1 (source %)".format(
        first + engine.numVoices - 1, engine.numVoices, first + engine.numVoices, engine.grainSource[0]));
command.(\setGrainSource, 0, 0);

// ---- A voice at dry 0 still feeds its readers (ruling 30) ----
// voice 2 (engine voice 1) on the input, a 440 Hz tone, at dry 0 and both
// sends 0: its own share of the master's three buses is below -90 dBFS;
// voice 1 (engine voice 0) on source first + 1 then plays within 0.5 dB of
// what it plays with voice 2 at dry 1
tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
startReader.(1, engine.inputSource);
[\dry, \delaySend, \reverbSend].do({ arg control; command.(\setGrainParam, 1, control, 0.0) });
server.sync; 0.4.wait;
readings = mixBuses.collect({ arg bus; peakOver.(bus, 0.5) });
check.(readings.every({ arg peak; peak < (-90.dbamp) }),
    "outrings: a voice at dry 0 and sends 0 leaves the master's buses below -90 dBFS (dry, delay send, reverb send peaks %)".format(readings));
startReader.(0, sourceOf.(1));
1.0.wait;
readings = [levelOver.(taps[0], 2.0)];
[\dry, \delaySend, \reverbSend].do({ arg control; command.(\setGrainParam, 1, control, 1.0) });
0.5.wait;
readings = readings ++ [levelOver.(taps[0], 2.0)];
check.((readings[0] > 0.002) and: { (readings[0] / readings[1].max(1e-9)).ampdb.abs < 0.5 },
    "outrings: a reader of a voice at dry 0 plays within 0.5 dB of its level with the voice at dry 1 (rms %, % dB)".format(
        readings.round(0.0001), (readings[0] / readings[1].max(1e-9)).ampdb.round(0.01)));

// ---- A stopped or muted read voice gives its readers silence ----
// (voice 1 still reads voice 2, which reads the tone; nothing is sent to
// the reader)
reader = grainOf.(0);
readings = [peakOver.(engine.voicePathBus(0, sourceOf.(1)), 0.3)];
command.(\setGrainParam, 1, \voiceMute, 1.0);
ok = h.waitFor({ peakOver.(engine.voicePathBus(0, sourceOf.(1)), 0.2) < silence }, 2);
readings = readings ++ [ok];
command.(\setGrainParam, 1, \voiceMute, 0.0);
readings = readings ++ [h.waitFor({ peakOver.(engine.voicePathBus(0, sourceOf.(1)), 0.2) > 0.01 }, 2)];
units = h.wireUnits({ command.(\voiceOff, 1) });
ok = h.waitFor({ peakOver.(engine.voicePathBus(0, sourceOf.(1)), 0.2) < silence }, engine.grainRelease + 2);
check.((readings[0] > 0.01) and: { readings[1] } and: { readings[2] } and: { ok }
    and: { units.flatten(1).every({ arg msg; msg.includes(reader.nodeID).not }) } and: { grainOf.(0) === reader },
    "outrings: a muted or stopped read voice gives its reader silence, and nothing is sent to the reader (playing %, muted silent %, unmuted plays %, stopped silent %)".format(
        readings[0].round(0.0001), readings[1], readings[2], ok));
tone.free;
h.stopAllVoices;

// ---- The read lag: two blocks and the margin, sample by sample ----
// The read voice stopped, the timecode added to its tap; the reader on its
// ring, 4 ms grains at 187.3 a second. In either node order: voice 4
// (engine voice 3) reading voice 3 (engine voice 2), its mix group after
// the read voice's, and voice 1 (engine voice 0) reading voice 7 (the last),
// its mix group before it. Every reader runs in processGroup and every
// output ring writer in the tap group, after them all, so the lag is the
// same either way
expect = (2 * block / sampleRate) + engine.ringReadMargin;
[[2, 3, "after"], [engine.numVoices - 1, 0, "before"]].do({ arg pair;
    var read = pair[0], readerVoice = pair[1];
    tapSound = Synth(\strataCheckOutTimecode, [\out, taps[read], \now, nowBus], probeGroup);
    server.sync; 0.5.wait;
    startReader.(readerVoice, sourceOf.(read), 0.004, 187.3, 0.2, true);
    0.3.wait;
    readings = timeReads.(readerVoice, 2.0);
    check.((readings[1] >= (expect - 0.00005)) and: { readings[0] <= (expect + 0.00005) },
        "outrings: a reader starts every grain two blocks and ringReadMargin behind the read voice's tap, sample by sample (engine voice % reading %, its mix group % the read voice's: % ms; lookback % to % ms)".format(
            readerVoice, read, pair[2], (expect * 1000).round(0.001), (readings[1] * 1000).round(0.001), (readings[0] * 1000).round(0.001)));
    tapSound.free;
    h.stopAllVoices;
});

// ---- A self-read plays ----
startReader.(4, sourceOf.(4));
tapSound = Synth(\strataCheckOutTone, [\out, taps[4]], probeGroup);
server.sync; 0.3.wait;
readings = peakOver.(engine.voicePathBus(4, sourceOf.(4)), 0.5);
tapSound.free;
check.(readings > 0.01, "outrings: a voice reading its own ring plays (peak %)".format(readings.round(0.0001)));
h.stopAllVoices;

// ---- A loop holds at full scale ----
// voices 1 and 2 read each other at size 0.5, density 200, spread 0 and
// level 2, seeded with a tone in voice 1's tap: after 5 s every sample of
// their rings is at most 1 and finite, the master's output finite, and no
// stage was replaced for bad values
badBus = Bus.control(server, 1);
badProbe = Synth(\strataCheckBadValues, [\in, engine.context.out_b, \out, badBus], engine.context.xg, \addAfter);
stages = [0, 1].collect({ arg voice; engine.synths[engine.voiceMixKey(voice)] });
startReader.(0, sourceOf.(1), 0.5, 200.0, 2.0);
startReader.(1, sourceOf.(0), 0.5, 200.0, 2.0);
tapSound = Synth(\strataCheckOutTone, [\out, taps[0], \level, 0.5], probeGroup);
server.sync; badProbe.set(\t_reset, 1);
0.2.wait;
tapSound.free;
5.0.wait;
readings = ringPeaks.(outRing.(0).keep(2) ++ outRing.(1).keep(2));
ok = h.readBusValue(badBus);
check.(readings.every({ arg pair; (pair[0] <= 1) and: { pair[0] > 0.1 } and: { pair[1] == 0 } }) and: { ok == 0 }
    and: { [0, 1].collect({ arg voice; engine.synths[engine.voiceMixKey(voice)] }) == stages },
    "outrings: a loop of two voices at level 2 holds at full scale (each ring's [peak, bad] %, the master bad %, stages kept %)".format(
        readings.collect(_.round(0.0001)), ok, [0, 1].collect({ arg voice; engine.synths[engine.voiceMixKey(voice)] }) == stages));
badProbe.free; badBus.free;
h.stopAllVoices;

// ---- An extra note on a voice source is an input-kind note ----
startReader.(5, sourceOf.(1));
command.(\setNotePool, 4);
command.(\noteExpression, 5, 1, 1.0, 1.0, 0.0, 0.0, 0.0);
command.(\noteOn, 5, 1, 60.0, 261.63, 1.5, 1.0);
server.sync;
record = engine.areaState[\notes][\slots][5][1];
check.((record[\kind] == \input) and: { record[\synth].notNil } and: { getControl.(record[\synth], \pitchShift) == 1.5 }
    and: { engine.perNoteGrainControls(5).includes(\pitchShift) },
    "outrings: an extra note on a voice source is of kind \\input, with its own pitchShift (kind %)".format(record[\kind]));
command.(\noteOff, 5, 1, 1);
command.(\setNotePool, 0);
h.stopAllVoices;

// ---- A reader's freeze: its copy ring ----
// voice 3 (engine voice 2) stopped, a tone added to its tap for longer than
// its ring; voice 4 (engine voice 3) reads it. With the read voice's writer
// paused (so its ring stands still), a hold copies the 4 s of the ring
// ending ringReadMargin behind the head into the reader's copy ring, oldest
// first from frame 0, and the reader reads the copy at history 0
fadeWaitBefore = engine.bufferFadeWait;
copyRing = { arg voice; engine.copyRingFor(voice) };
tapSound = Synth(\strataCheckOutTone, [\out, taps[2], \level, 0.3], probeGroup);
startReader.(3, sourceOf.(2));
(engine.outRingSeconds + 0.3).wait;
reader = grainOf.(3);
writer = engine.synths[engine.outRingWriterKeys[2]];
writer.run(false); server.sync; 0.05.wait;
expect = h.readBusValue(outRing.(2)[2]);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ engine.areaState[\freeze][\copied][3] }, 1);
server.sync;
// copy frame k against ring frame (end + k), end the head less the margin
readings = [0, 1].collect({ arg channel;
    var bus = Bus.control(server, 2), frames = outRing.(2)[0].numFrames, probe, values;
    var end = (expect - (engine.ringReadMargin * sampleRate)).round.asInteger.mod(frames);
    probe = Synth(\strataCheckOutRotation, [\bufA, copyRing.(3)[channel], \bufB, outRing.(2)[channel], \offset, end, \out, bus],
        probeGroup, \addToTail);
    server.sync; probe.set(\t_reset, 1);
    ((frames / sampleRate) + 0.2).wait;
    values = h.readBus(bus);
    probe.free; bus.free;
    values
});
check.(ok and: { readings.every({ arg pair; (pair[0] == 0) and: { pair[1] > 0.1 } }) },
    "outrings: a hold on a reader copies the 4 s of the read voice's ring behind its read point into its copy ring (copied %; [difference, level] %)".format(
        ok, readings.collect(_.round(0.0001))));
check.((getControl.(reader, \bufL) == copyRing.(3)[0].bufnum) and: { getControl.(reader, \bufR) == copyRing.(3)[1].bufnum }
    and: { getControl.(reader, \phaseBus) == copyRing.(3)[2].index } and: { getControl.(reader, \history) == 0 }
    and: { engine.areaState[\freeze][\inputReaders][reader] !? { arg entry; entry[\voice] == 3 } ? false }
    and: { engine.spectralHoldsVoice(3).not },
    "outrings: a frozen reader reads its copy ring at history 0 and is counted among the copy's readers");
writer.run(true);
// the unfreeze points the reader back at the out ring and sends its freeze
// 0 in one bundle
units = h.wireUnits({ command.(\setGrainParam, 3, \freeze, 0.0) });
server.sync;
check.(inOneBundle.(units, reader.nodeID, 0) and: { getControl.(reader, \bufL) == outRing.(2)[0].bufnum }
    and: { getControl.(reader, \phaseBus) == outRing.(2)[2].index },
    "outrings: a reader's unfreeze points it back at the read voice's ring in one bundle with its freeze 0");
// the copy ring's readers fade first: a refreeze inside freezeLeaveSeconds
// finds the reader among them, which goes to ringLevel 0 while the copy
// waits; a switch inside the wait cancels the copy (the zeroed copy ring
// stays zero)
engine.bufferFadeWait = 1.0;
// (the unfreeze above set the reader back: once freezeLeaveSeconds has
// passed it no longer counts as a reader of the copy, and this freeze
// copies at once)
(engine.freezeLeaveSeconds + 0.1).wait;
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ engine.areaState[\freeze][\copied][3] }, 0.5);
command.(\setGrainParam, 3, \freeze, 0.0);
copyRing.(3).keep(2).do(_.zero);
server.sync;
command.(\setGrainParam, 3, \freeze, 1.0);
server.sync;
readings = [ok and: { engine.areaState[\freeze][\faded][3].includes(reader) }, getControl.(reader, \ringLevel),
    engine.areaState[\freeze][\copied][3]];
command.(\setGrainSource, 3, sourceOf.(4));
(engine.bufferFadeWait + 0.3).wait;
ok = ringPeaks.(copyRing.(3).keep(2));
check.(readings[0] and: { readings[1] == 0 } and: { readings[2].not } and: { engine.areaState[\freeze][\copied][3].not }
    and: { engine.areaState[\freeze][\frozen][3].not } and: { ok.every({ arg pair; pair[0] == 0 }) },
    "outrings: a refrozen reader fades first, and a switch inside the fade cancels the copy (faded %, ring level %, copy ring peaks %)".format(
        readings[0], readings[1], ok.collect(_.first)));
engine.bufferFadeWait = fadeWaitBefore;
tapSound.free;
h.stopAllVoices;
command.(\setGrainParam, 3, \freeze, 0.0);

// freezing the read voice leaves its readers' rings as they were: voice 3
// on its synth, frozen (hold), its writer to its ring paused, its output
// ring still written
startReader.(2, 0);
startReader.(3, sourceOf.(2));
reader = grainOf.(3);
readings = [\bufL, \bufR, \phaseBus].collect({ arg control; getControl.(reader, control) });
command.(\setGrainParam, 2, \freeze, 1.0);
server.sync; 0.1.wait;
ok = h.readBusValue(outRing.(2)[2]);
0.2.wait;
check.(([\bufL, \bufR, \phaseBus].collect({ arg control; getControl.(reader, control) }) == readings)
    and: { readings == [outRing.(2)[0].bufnum, outRing.(2)[1].bufnum, outRing.(2)[2].index] }
    and: { h.readBusValue(outRing.(2)[2]) != ok } and: { engine.areaState[\freeze][\frozen][2] },
    "outrings: freezing the read voice leaves its reader's bufL, bufR and phaseBus as they were, and its output ring written");
command.(\setGrainParam, 2, \freeze, 0.0);
h.stopAllVoices;

// A player will meet this: a reader frozen over a stopped voice holds
// silence; unfrozen 1 s after that voice's voiceOn, it reads the out ring
// again within 50 ms
tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
command.(\setGrainSource, 2, engine.inputSource);
startReader.(3, sourceOf.(2), 0.05, 100.0);
// (the frozen grains read from grainMaxSeconds back: past what the read
// voice played in the checks before)
1.2.wait;
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ engine.areaState[\freeze][\copied][3] }, 1);
command.(\voiceOn, 2, 100.0, 0.2, 0.0, 0.1, 20.0, 1.0);
server.sync;
[\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, 2, control, 0.0) });
readings = [peakOver.(engine.voicePathBus(3, sourceOf.(2)), 0.3)];
0.7.wait;
heardBus = Bus.control(server, 1);
heardProbe = Synth(\strataCheckOutHeard, [\in, engine.voicePathBus(3, sourceOf.(2)), \out, heardBus], probeGroup, \addToTail);
server.sync;
heardProbe.set(\t_reset, 1);
command.(\setGrainParam, 3, \freeze, 0.0);
0.3.wait;
readings = readings ++ [h.readBusValue(heardBus)];
heardProbe.free; heardBus.free; tone.free;
check.((readings[0] < silence) and: { readings[1] < 0.05 },
    "outrings: a reader frozen over a stopped voice holds silence and, unfrozen 1 s after that voice's voiceOn, reads it again within 50 ms (frozen peak %, heard after % s)".format(
        readings[0].round(0.00001), readings[1].round(0.001)));
h.stopAllVoices;

// ---- A reader's late copy (#809) ----
// voice 3 (engine voice 2) stopped, the timecode added to its tap; voice 4
// (engine voice 3) reads it. The engine check's step before each copy's
// message (beforeCopyHook, called with the attempt) waits, so the copy goes
// out late while the read voice's writer keeps writing: a real late copy.
// copyTimes reads the timecode over the copy's last frozenReachSeconds (what
// a frozen grain can read with no scan) and at its last frame (the read
// point's newest audio): with nothing written after the read point there,
// the newest is the last frame's.
lateCopyChecks = {
    var freeze = engine.areaState[\freeze], frames = outRing.(2)[0].numFrames;
    var reach = engine.tryPerform(\frozenReachSeconds) ? 3.0;
    var roomSeconds = (engine.tryPerform(\copyRoomFrames, frames) ? sampleRate) / sampleRate;
    var lines = List.new, attempts = List.new, copyTimes, values, frozenState, late;
    var holdBuffer, perPartial, holdQueue, endedCount, endedReport, endedBefore;
    copyTimes = { arg voice;
        var ring = copyRing.(voice), size = ring[0].numFrames, span = (reach * sampleRate).round.asInteger.min(size);
        var bus = Bus.control(server, 2), probe, times, last;
        probe = Synth(\strataCheckOutCopyTimes, [\bufL, ring[0], \bufR, ring[1], \start, size - span, \frames, span,
            \out, bus], probeGroup, \addToTail);
        server.sync; probe.set(\t_reset, 1);
        ((span / sampleRate) + 0.1).wait;
        times = h.readBus(bus);
        probe.free; bus.free;
        last = [h.bufferSample(ring[0], size - 1), h.bufferSample(ring[1], size - 1)];
        (newest: times[0], oldest: times[1], last: last[0] / last[1].max(0.0001) * timecodeWrap)
    };
    frozenState = { arg voice; [freeze[\frozen][voice], freeze[\copied][voice], engine.grainControls[voice][\freeze]] };
    // #858: the voice's freezes the engine ended itself so far, and whether
    // freezeEnded's last report is the voice's count-th (what Lua reads)
    endedCount = { arg voice; (freeze[\ended] ? [])[voice] ? 0 };
    endedReport = { arg voice, count;
        var poll = engine.tryPerform(\freezeEndedPoll), expected = engine.tryPerform(\freezeEndedValue, voice, count);
        poll.notNil and: { expected.notNil } and: { poll.value == expected }
    };
    freeze[\postLine] = { arg line; lines.add(line) };
    tapSound = Synth(\strataCheckOutTimecode, [\out, taps[2], \now, nowBus], probeGroup);
    startReader.(3, sourceOf.(2), 0.05, 50.0, 0.2, true);
    // a copy on time lands at its first attempt
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt) };
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ freeze[\copied][3] }, 1);
    command.(\setGrainParam, 3, \freeze, 0.0);
    check.(attempts.asArray == [1] and: { lines.isEmpty },
        "outrings: a reader's copy on time lands at its first attempt (attempts %, lines %)".format(attempts, lines));
    // a copy late but inside its room (about 0.64 s) lands at its first
    // attempt: the room is not too strict
    (engine.freezeLeaveSeconds + 0.1).wait;
    late = roomSeconds - 0.35;
    attempts.clear;
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt); if (attempt == 1) { late.wait } };
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ freeze[\copied][3] }, late + 1);
    engine.beforeCopyHook = nil;
    check.(freeze[\copied][3] and: { attempts.asArray == [1] } and: { lines.isEmpty },
        "outrings: a reader's copy % s late, inside its room (% s), lands at its first attempt with no line (attempts %, lines %)".format(
            late.round(0.001), roomSeconds.round(0.001), attempts, lines));
    command.(\setGrainParam, 3, \freeze, 0.0);
    // three copies late past the room, then one on time: the hold lands
    // on the fourth's read point, with nothing written after it where the
    // frozen grains read, and one console line (after the second)
    (engine.freezeLeaveSeconds + 0.1).wait;
    late = roomSeconds + 0.3;
    attempts.clear;
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt); if (attempt <= 3) { late.wait } };
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ freeze[\copied][3] }, (3 * late) + 2);
    engine.beforeCopyHook = nil;
    values = copyTimes.(3);
    check.(freeze[\copied][3] and: { attempts.asArray == [1, 2, 3, 4] }
        and: { values[\newest] <= (values[\last] + 0.001) } and: { values[\oldest] >= (values[\last] - reach - 0.1) }
        and: { getControl.(grainOf.(3), \bufL) == copyRing.(3)[0].bufnum }
        and: { lines.size == 1 } and: { lines.first.contains("abandoned").not },
        "outrings: a reader's hold whose copy is % s late three times lands at the fourth, keeping no audio written after its read point where frozen grains read, with one line (attempts %; the last % s of the copy hold % to % s, its last frame %; lines %)".format(
            late.round(0.001), attempts, reach.round(0.001), values[\oldest].round(0.001), values[\newest].round(0.001),
            values[\last].round(0.001), lines));
    command.(\setGrainParam, 3, \freeze, 0.0);
    // the bound spent (a bound of 2 through copyAttempts' override): the
    // hold is abandoned with its line, after the late one; the reader reads
    // the live ring unfrozen, its freeze 0
    (engine.freezeLeaveSeconds + 0.1).wait;
    lines.clear; attempts.clear;
    endedBefore = endedCount.(3);
    engine.tryPerform(\copyAttempts_, 2);
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt); late.wait };
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ freeze[\frozen][3].not }, (2 * late) + 2);
    engine.beforeCopyHook = nil;
    engine.tryPerform(\copyAttempts_, nil);
    server.sync;
    check.((attempts.asArray == [1, 2]) and: { frozenState.(3) == [false, false, 0] }
        and: { getControl.(grainOf.(3), \freeze) == 0 } and: { getControl.(grainOf.(3), \bufL) == outRing.(2)[0].bufnum }
        and: { getControl.(grainOf.(3), \phaseBus) == outRing.(2)[2].index }
        and: { lines.size == 2 } and: { lines.last.contains("abandoned") } and: { engine.copyAttempts == 8 }
        and: { endedCount.(3) == (endedBefore + 1) } and: { endedReport.(3, endedBefore + 1) },
        "outrings: a reader's hold whose bound of attempts is spent (2, each % s late) is abandoned with its line and reported on freezeEnded (#858): unfrozen on its live ring (attempts %, [frozen, copied, freeze] %, lines %, bound back to %, ended % then %, report %)".format(
            late.round(0.001), attempts, frozenState.(3), lines, engine.copyAttempts, endedBefore, endedCount.(3),
            engine.tryPerform(\freezeEndedPoll) !? { arg poll; poll.value }));
    // The missing head (#835): the server's command queue held 1.5 s (a
    // /b_gen sine1 runs in its non-real-time thread, and every reply after
    // it, a /c_get's among them, waits for it), so the copy's first head
    // read gets no answer within ringHeadFrame's 1 s and the attempt goes
    // on without a copy (no beforeCopyHook). A missing head is no late
    // copy: the late line counts late copies only. The second attempt's
    // read is answered by the first's late reply (Bus.get matches by
    // index), an older head, so its copy counts as late, and the third
    // lands: one late copy, no line
    holdBuffer = Buffer.alloc(server, 2 ** 20, 1);
    server.sync;
    perPartial = {
        var started = Main.elapsedTime;
        holdBuffer.sine1(Array.fill(20, 0.001), false, false, true);
        server.sync;
        (Main.elapsedTime - started) / 20
    }.value;
    holdQueue = { arg seconds; holdBuffer.sine1(Array.fill((seconds / perPartial).round.asInteger.clip(1, 4000), 0.001), false, false, true) };
    (engine.freezeLeaveSeconds + 0.1).wait;
    lines.clear; attempts.clear;
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt) };
    holdQueue.(1.5);
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ freeze[\copied][3] }, 5);
    engine.beforeCopyHook = nil;
    server.sync;
    check.(freeze[\copied][3] and: { attempts.notEmpty } and: { attempts.first >= 2 } and: { lines.isEmpty },
        "outrings: a copy whose head the server did not give within 1 s (its queue held 1.5 s) is made again, and the missing head is no late copy: no late line (attempts with a head %, lines %)".format(
            attempts, lines));
    command.(\setGrainParam, 3, \freeze, 0.0);
    // the bound spent on a missing head (a bound of 1): the hold is
    // abandoned with a line that says the server gave no head, not that a
    // copy was late
    (engine.freezeLeaveSeconds + 0.1).wait;
    lines.clear; attempts.clear;
    endedBefore = endedCount.(3);
    engine.tryPerform(\copyAttempts_, 1);
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt) };
    holdQueue.(1.5);
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ freeze[\frozen][3].not }, 3);
    engine.beforeCopyHook = nil;
    engine.tryPerform(\copyAttempts_, nil);
    server.sync;
    check.(attempts.isEmpty and: { frozenState.(3) == [false, false, 0] } and: { lines.size == 1 }
        and: { lines.first.contains("abandoned") } and: { lines.first.contains("no head") }
        and: { lines.first.contains("late").not } and: { endedReport.(3, endedBefore + 1) },
        "outrings: a hold whose one attempt got no head from the server is abandoned with a line that says so, and reported (attempts with a head %, [frozen, copied, freeze] %, lines %, ended % then %)".format(
            attempts, frozenState.(3), lines, endedBefore, endedCount.(3)));
    holdBuffer.free;
    // a switch during a late copy's third attempt cancels it: no copy, no
    // abandon (the one line is the late one), no freezeEnded report
    lines.clear; attempts.clear;
    endedBefore = endedCount.(3);
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt); late.wait };
    command.(\setGrainParam, 3, \freeze, 1.0);
    h.waitFor({ attempts.includes(3) }, (2 * late) + 2);
    copyRing.(3).keep(2).do(_.zero);
    server.sync;
    command.(\setGrainSource, 3, sourceOf.(4));
    (late + 0.3).wait;
    engine.beforeCopyHook = nil;
    values = ringPeaks.(copyRing.(3).keep(2));
    check.((attempts.asArray == [1, 2, 3]) and: { frozenState.(3) == [false, false, 0] } and: { lines.size == 1 }
        and: { lines.first.contains("abandoned").not } and: { values.every({ arg pair; pair[0] == 0 }) }
        and: { endedCount.(3) == endedBefore },
        "outrings: a switch during a late copy's third attempt cancels it (attempts %, [frozen, copied, freeze] %, lines %, copy ring peaks %)".format(
            attempts, frozenState.(3), lines, values.collect(_.first)));
    // a source ring shorter than the copy ring is refused, with one line,
    // and the hold abandoned (voice 7's out ring stood in for by a 1 s pair
    // for the freeze, then given back)
    lines.clear; attempts.clear;
    endedBefore = endedCount.(4);
    values = (outRings: engine.areaState[\outRings], left: engine.areaState[\outRings][\left][6],
        right: engine.areaState[\outRings][\right][6], shortL: Buffer.alloc(server, sampleRate, 1),
        shortR: Buffer.alloc(server, sampleRate, 1));
    server.sync;
    startReader.(4, sourceOf.(6));
    values[\outRings][\left][6] = values[\shortL];
    values[\outRings][\right][6] = values[\shortR];
    engine.beforeCopyHook = { arg voice, attempt; attempts.add(attempt) };
    command.(\setGrainParam, 4, \freeze, 1.0);
    h.waitFor({ freeze[\frozen][4].not }, 2);
    engine.beforeCopyHook = nil;
    values[\outRings][\left][6] = values[\left];
    values[\outRings][\right][6] = values[\right];
    server.sync;
    check.((attempts.asArray == [1]) and: { frozenState.(4) == [false, false, 0] } and: { lines.size == 1 }
        and: { lines.first.contains("refused") } and: { getControl.(grainOf.(4), \freeze) == 0 }
        and: { endedReport.(4, endedBefore + 1) },
        "outrings: a source ring shorter than the copy ring is refused with one line and the hold abandoned (attempts %, [frozen, copied, freeze] %, lines %)".format(
            attempts, frozenState.(4), lines));
    [values[\shortL], values[\shortR]].do(_.free);
    freeze[\postLine] = nil;
    tapSound.free;
    h.stopAllVoices;
    [3, 4].do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0) });
};
lateCopyChecks.value;

// ---- The input channel ----
// voice 5 (engine voice 4) on the input: left hands both reads the input's
// left ring, right its right ring, stereo both; on a frozen input voice the
// copy's left twice; kept across a switch away and back; a voice source
// ignores it; no grain def has the control
inputRing = engine.ringBuffersFor(4, engine.inputSource);
startReader.(4, engine.inputSource);
readings = [1, 2, 0].collect({ arg channel;
    command.(\setGrainParam, 4, \inputChannel, channel);
    server.sync;
    [getControl.(grainOf.(4), \bufL), getControl.(grainOf.(4), \bufR)]
});
check.(readings == [[inputRing[0].bufnum, inputRing[0].bufnum], [inputRing[1].bufnum, inputRing[1].bufnum],
        [inputRing[0].bufnum, inputRing[1].bufnum]],
    "outrings: inputChannel 1 gives bufL and bufR the input's left ring, 2 its right, 0 both (got %)".format(readings));
command.(\setGrainParam, 4, \inputChannel, 1);
command.(\setGrainParam, 4, \freeze, 1.0);
ok = h.waitFor({ engine.areaState[\freeze][\copied][4] }, 1);
server.sync;
readings = [getControl.(grainOf.(4), \bufL), getControl.(grainOf.(4), \bufR)];
command.(\setGrainParam, 4, \freeze, 0.0);
server.sync;
check.(ok and: { readings == [copyRing.(4)[0].bufnum, copyRing.(4)[0].bufnum] }
    and: { [getControl.(grainOf.(4), \bufL), getControl.(grainOf.(4), \bufR)] == [inputRing[0].bufnum, inputRing[0].bufnum] },
    "outrings: on a frozen input voice inputChannel 1 reads the copy's left twice, and the unfreeze the input's left twice (frozen %)".format(readings));
command.(\setGrainSource, 4, 0);
server.sync;
command.(\setGrainSource, 4, engine.inputSource);
server.sync;
check.((engine.grainControls[4][\inputChannel] == 1)
    and: { [getControl.(grainOf.(4), \bufL), getControl.(grainOf.(4), \bufR)] == [inputRing[0].bufnum, inputRing[0].bufnum] },
    "outrings: inputChannel is kept across a switch away and back");
command.(\setGrainParam, 4, \inputChannel, 5);
server.sync;
check.(engine.grainControls[4][\inputChannel] == 2, "outrings: inputChannel is rounded and clipped to 0-2 (5 kept as %)".format(
    engine.grainControls[4][\inputChannel]));
command.(\setGrainParam, 4, \inputChannel, 0);
startReader.(5, sourceOf.(1));
command.(\setGrainParam, 5, \inputChannel, 2);
server.sync;
check.(([getControl.(grainOf.(5), \bufL), getControl.(grainOf.(5), \bufR)] == [outRing.(1)[0].bufnum, outRing.(1)[1].bufnum])
    and: { h.grainDefs.every({ arg name; SynthDescLib.global.at(name).controlNames.collect(_.asSymbol).includes(\inputChannel).not }) },
    "outrings: a voice source ignores inputChannel, and no grain def has the control");
command.(\setGrainParam, 5, \inputChannel, 0);
h.stopAllVoices;

// ---- Spectral on a reader (a high engine) ----
// one copy writer of the read voice's tap, in the tap group, starting at
// the copy's end and stepping a block a block; freed at the unfreeze and at
// a switch; the reader's freeze never makes a type switch wait
root = h.tempDir +/+ "outrings-high/";
File.mkdir(root);
[["performance.data", "performance high\nbuffer_seconds 60\n"], ["model", "Raspberry Pi 4 Model B Rev 1.4"],
    ["meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n"]].do({ arg pair;
    File.use(root +/+ pair[0], "w", { arg file; file.write(pair[1]) });
});
other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
otherCommand = { arg name ... args; h.commandTo(other, name, *args) };
spectralNodes = { h.synthTree(other.context.xg).select({ arg node; node.def == \strataRingWriteSpectral }) };
otherCommand.(\setGrainSource, 3, sourceOf.(2));
otherCommand.(\voiceOn, 3, 100.0, 0.2, 0.0, 0.1, 20.0, 1.0);
otherCommand.(\setGrainParam, 3, \freezeMode, 1.0);
server.sync; 0.3.wait;
stepProbe = Synth(\strataCheckOutHeadStep, [\in, other.copyRingFor(3)[2], \out, stepBus,
    \frames, other.copyRingFor(3)[0].numFrames, \block, block], other.processGroup, \addToHead);
otherCommand.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ other.synths[other.copyWriterKeys[3]].notNil }, 1);
copiedAt = Main.elapsedTime;
readings = h.readBusValue(other.copyRingFor(3)[2]);
copiedAt = (Main.elapsedTime - copiedAt + 0.05) * sampleRate;
stepProbe.set(\t_reset, 1);
server.sync;
nodes = spectralNodes.value;
writer = other.synths[other.copyWriterKeys[3]];
check.(ok and: { other.tier == \high } and: { nodes.size == 1 } and: { nodes[0].id == writer.nodeID }
    and: { h.synthTree(other.areaState[\record][\tapGroup]).any({ arg node; node.id == writer.nodeID }) }
    and: { nodes[0].controls[\in] == other.areaState[\record][\voiceTaps][2].index }
    and: { nodes[0].controls[\bufL] == other.copyRingFor(3)[0].bufnum } and: { nodes[0].controls[\phaseOut] == other.copyRingFor(3)[2].index }
    and: { other.ringWriterFor(3).defName.asSymbol == \strataRingWrite },
    "outrings: spectral on a reader starts one copy writer of the read voice's tap in the tap group, into its copy ring (high %, writer %)".format(
        other.tier == \high, nodes.collect(_.def)));
check.(readings.notNil and: { readings.inclusivelyBetween(0, copiedAt + block + (0.06 * sampleRate)) },
    "outrings: a reader's copy writer starts at the copy's end (its head % frames after at most % frames)".format(readings, copiedAt.round));
0.4.wait;
readings = steps.value;
check.((readings[\min] == block) and: { readings[\max] == block } and: { readings[\other] == 0 },
    "outrings: a reader's copy writer's head steps exactly % frames a block (steps % to %, % runs of others)".format(
        block, readings[\min], readings[\max], readings[\other]));
// a type switch on a frozen reader is recorded, never waited for
otherCommand.(\setVoiceType, 3, 0);
check.(other.spectralHoldsVoice(3).not and: { other.voiceType(3) == 0 } and: { other.synths[other.voiceKey(3)].isNil },
    "outrings: a frozen reader's type switch is recorded at once, and no voice synth starts (type %)".format(other.voiceType(3)));
otherCommand.(\setVoiceType, 3, 3);
otherCommand.(\setGrainParam, 3, \freeze, 0.0);
server.sync;
stepProbe.set(\t_reset, 1);
0.3.wait;
readings = steps.value;
check.(other.synths[other.copyWriterKeys[3]].isNil and: { spectralNodes.value.isEmpty } and: { readings[\max] == 0 },
    "outrings: a reader's unfreeze frees its copy writer (its head then stands still: steps % to %)".format(readings[\min], readings[\max]));
otherCommand.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ other.synths[other.copyWriterKeys[3]].notNil }, 1);
otherCommand.(\setGrainSource, 3, sourceOf.(4));
server.sync;
check.(ok and: { other.synths[other.copyWriterKeys[3]].isNil } and: { spectralNodes.value.isEmpty },
    "outrings: a switch frees a frozen reader's copy writer");
stepProbe.free;
h.stopAllVoices(other);
h.freeEngine(other);
server.sync;

probeGroup.free;
[quietBus, nowBus, readOut, stepBus].do(_.free);
rectEnv.free;
server.sync;
}
