// test/engine_check/rings.scd
// The rings: the writers (place, controls, phase, NaN guard, free), and
// where ring grains read (pitch as rate, bend once, the lookback in
// continuous and triggered mode, the ring's end, input history), plus the
// GrainBuf wrap the rings rely on and no PitchShift or DelayC in a grain
// SynthDef.
//
// Most reads use a timecode: a check synth writes the seconds since it
// started (left) and 1 (right) into voice 1's bus and the input bus, and
// the same seconds to a private bus. A grain synth with a rectangular
// envelope then reads the left over the right as the time its audio was
// written, so the time now minus that is how far back it reads (its
// lookback), sample by sample, whatever its level.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var readBus = { arg bus; h.readBus(bus) };
var rings = engine.areaState[\rings], sampleRate = server.sampleRate, block = server.options.blockSize;
var probeGroup, quietBus, nowBus, readOut, rectEnv, timecode, sine, readings;
var timeReads, pitchOf, startTimecodeVoice, grainSynth, ringNames, writers, nodes, ringOk;
var rampBuffer, recordBuffer, wrapRead, other, otherRings, otherWriters, badBus, writer, phaseBus, scratchRing;

// A grain synth's reads while seconds pass: [largest lookback, smallest
// lookback, longest grain, largest step between samples, seconds with no
// grain, largest and smallest rate]. Reads only while the right channel (1
// in the ring) is above 0.05. The rate is how far a grain's timecode read
// has moved since 10 ms into the grain, over the time since then (once that
// is 50 ms): exact, where a per-sample slope would drown in float rounding.
// The reference point is taken well inside the grain (both the read and
// the time latched by the same trigger), never on its first sample, where
// a latch may hold the read from before the grain (0: SuperCollider 3.13).
SynthDef(\strataCheckRingRead, { arg in, now, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset);
    var on = sig[1] > 0.05, both = on * Delay1.ar(on);
    var read = sig[0] / sig[1].max(0.001);
    var lookback = In.ar(now, 1) - read;
    var elapsed = Sweep.ar(on, on);
    var mark = on * (elapsed > 0.01);
    var rate = (read - Latch.ar(read, mark)) / ((elapsed - Latch.ar(elapsed, mark)) + SampleDur.ir);
    var timed = on * (elapsed > 0.06);
    Out.kr(out, A2K.kr([
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), lookback]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), lookback]), reset),
        RunningMax.ar(elapsed, reset),
        RunningMax.ar((read - Delay1.ar(read)).abs * both, reset),
        Sweep.ar(reset, 1 - on),
        RunningMax.ar(Select.ar(timed, [DC.ar(-1000), rate]), reset),
        RunningMin.ar(Select.ar(timed, [DC.ar(1000), rate]), reset)
    ]));
}).add;
SynthDef(\strataCheckTimecode, { arg out, out2, now;
    var time = Sweep.ar(0, 1), sig = [time, DC.ar(1)];
    Out.ar(out, sig);
    Out.ar(out2, sig);
    Out.ar(now, time);
}).add;
SynthDef(\strataCheckPitch, { arg in, out;
    Out.kr(out, Pitch.kr(In.ar(in, 2)[0], minFreq: 100, maxFreq: 2000, ampThreshold: 0.001, median: 7));
}).add;
// One grain from pos at rate through a rectangular envelope, recorded
SynthDef(\strataCheckWrap, { arg bufnum, record, env, pos = 0.9, rate = 1, dur = 0.05;
    var sig = GrainBuf.ar(2, Impulse.ar(0), dur, bufnum, rate, pos, 2, -1, env, 16);
    RecordBuf.ar(sig, record, loop: 0, doneAction: 2);
}).add;
server.sync;

probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);    // where redirected voice synths play
nowBus = Bus.audio(server, 1);
readOut = Bus.audio(server, 2);     // where a measured grain synth plays
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
server.sync;

// A voice's grain synth to readOut, then its reads (timeReads) while
// action runs and seconds pass
timeReads = { arg voice, seconds, action;
    var bus = Bus.control(server, 7), probe, values;
    engine.synths[engine.grainKey(voice)].set(\out, readOut.index);
    probe = Synth(\strataCheckRingRead, [\in, readOut, \now, nowBus, \out, bus], probeGroup);
    server.sync; 0.05.wait;
    probe.set(\t_reset, 1); server.sync;
    action.value;
    seconds.wait;
    values = readBus.(bus);
    probe.free; bus.free;
    engine.synths[engine.grainKey(voice)].set(\out, engine.mainBus.index);
    values
};
// The median of a voice's grain pitch over 0.6 s (Hz)
pitchOf = { arg voice;
    var bus = Bus.control(server, 2), probe, freqs = List.new;
    engine.synths[engine.grainKey(voice)].set(\out, readOut.index);
    probe = Synth(\strataCheckPitch, [\in, readOut, \out, bus], probeGroup);
    server.sync; 0.3.wait;
    7.do({ 0.1.wait; readBus.(bus) !? { arg pair; if (pair[1] > 0.5) { freqs.add(pair[0]) } } });
    probe.free; bus.free;
    engine.synths[engine.grainKey(voice)].set(\out, engine.mainBus.index);
    if (freqs.isEmpty) { 0 } { freqs.sort[freqs.size div: 2] }
};
// Start a voice for the timecode reads: its voice synth (if any) played
// elsewhere, its grains through the rectangular envelope, no pan wander
// or position spread
startTimecodeVoice = { arg voice, source, size, density, pitch;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 100.0, 0.2, 0.0, size, density, pitch);
    server.sync;
    engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.set(\out, quietBus.index) };
    [\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, voice, control, 0.0) });
    engine.synths[engine.grainKey(voice)].set(\envBuf, rectEnv.bufnum);
    server.sync;
};

// ---- The SynthDefs ----
h.grainDefs.do({ arg name;
    var bad = SynthDescLib.global.at(name).def.children.select({ arg ugen;
        ugen.isKindOf(PitchShift) or: { ugen.class.name.asString.beginsWith("Delay") } or: { ugen.isKindOf(CombN) }
            or: { ugen.isKindOf(CombL) } or: { ugen.isKindOf(CombC) } or: { ugen.isKindOf(AllpassC) }
    });
    check.(bad.isEmpty, "rings: no PitchShift or DelayC in %, nor any delay line (got %)".format(name, bad.collect(_.class)));
});
check.(SynthDescLib.global.at(\strataGrainRing).def.children.count({ arg ugen; ugen.isKindOf(GrainBuf) }) == 2
    and: { SynthDescLib.global.at(\strataGrainRing).def.children.select({ arg ugen; ugen.isKindOf(GrainBuf) })
        .every({ arg ugen; ugen.channels.size == 2 }) },
    "rings: strataGrainRing runs two stereo GrainBufs (one per channel buffer)");

// ---- The writers ----
ringNames = [\voiceL, \voiceR, \inputL, \inputR, \phaseBuses, \writers, \readers, \changes];
check.(ringNames.every({ arg key; rings[key].notNil }), "rings: the rings area keeps %".format(ringNames));
check.((rings[\voiceL] ++ rings[\voiceR]).every({ arg buffer;
        (buffer.numFrames == (sampleRate * engine.ringSeconds)) and: { buffer.numChannels == 1 } })
    and: { [rings[\inputL], rings[\inputR]].every({ arg buffer;
        buffer.numFrames == (sampleRate * (engine.historySeconds + engine.ringGuardSeconds + 1)) }) }
    and: { rings[\phaseBuses].size == (engine.numVoices + 1) },
    "rings: % mono voice rings of % s, an input ring of % s and % phase buses".format(
        engine.numVoices * 2, engine.ringSeconds, engine.historySeconds + engine.ringGuardSeconds + 1, engine.numVoices + 1));
check.((engine.ringBuffersFor(2, 0) == [rings[\voiceL][2], rings[\voiceR][2], rings[\phaseBuses][2]])
    and: { engine.ringBuffersFor(2, engine.inputSource) == [rings[\inputL], rings[\inputR], rings[\phaseBuses].last] }
    and: { engine.ringBuffersFor(2, 3).isNil },
    "rings: ringBuffersFor gives the voice's ring, the input ring, or nil for a slot");
check.([engine.ringReadMargin, engine.ringSpreadSeconds, engine.ringMaxRate] == [0.005, 0.5, 4],
    "rings: ringReadMargin 0.005, ringSpreadSeconds 0.5, ringMaxRate 4");

// with a voice and a recording started, the writers still run last in voiceGroup
command.(\voiceOn, 2, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
command.(\recordBuffer, 7, 0.5, 1.0);
0.1.wait; server.sync;
nodes = h.synthTree(engine.voiceGroup);
writers = nodes.copyRange(nodes.size - (engine.numVoices + 1), nodes.size - 1);
check.(nodes.count({ arg node; node.def == \strataRingWrite }) == (engine.numVoices + 1)
    and: { writers.every({ arg node; node.def == \strataRingWrite }) }
    and: { nodes.any({ arg node; node.def == \strataRecord }) } and: { nodes.any({ arg node; node.def == engine.voiceSynthDefs[2] }) },
    "rings: one writer per voice plus the input writer, at the tail of voiceGroup (got %)".format(nodes.collect(_.def)));
ringOk = writers.every({ arg node, index;
    var isInput = index == engine.numVoices;
    var ring = engine.ringBuffersFor(index, if (isInput) { engine.inputSource } { 0 });
    (node.controls[\in] == if (isInput) { engine.inputBus.index } { engine.granBuses[index].index })
        and: { node.controls[\bufL] == ring[0].bufnum } and: { node.controls[\bufR] == ring[1].bufnum }
        and: { node.controls[\phaseOut] == ring[2].index }
});
check.(ringOk and: { engine.ringWriterKeys.every({ arg key, index; engine.synths[key].nodeID == writers[index].id }) }
    and: { engine.ringWriterKeys.every({ arg key; engine.effectKeys.includes(key) }) },
    "rings: each writer reads its voice bus (the input writer inputBus) into its ring, and its key is an effect key");
command.(\stopRecord, 7);
command.(\voiceOff, 2);

// a writer starts from the frame on its phase bus (a writer that replaces
// another carries on where it was)
scratchRing = Buffer.alloc(server, sampleRate, 1);
phaseBus = Bus.control(server, 1);
phaseBus.set(1000); server.sync;
writer = Synth(\strataRingWrite, [\in, quietBus, \bufL, scratchRing, \bufR, scratchRing, \phaseOut, phaseBus], probeGroup);
server.sync; 0.1.wait;
readings = h.readBusValue(phaseBus);
writer.free; server.sync;
check.(readings.notNil and: { readings > 1000 } and: { readings < (1000 + (0.5 * sampleRate)) },
    "rings: a writer starts from the frame on its phase bus (1000; read % 0.1 s later)".format(readings));

// a NaN input writes zeros into the ring: 50 ms of inf and NaN into a
// stopped voice's bus
badBus = engine.granBuses[5];
Synth(\strataCheckBadSource, [\out, badBus], engine.voiceGroup, \addToHead);
0.3.wait; server.sync;
ringOk = [rings[\voiceL][5], rings[\voiceR][5]].every({ arg buffer;
    var condition = Condition(false), values;
    buffer.loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition, 10);
    values.notNil and: { values.every({ arg value; (value == value) and: { value.abs < 1e30 } }) }
});
check.(ringOk, "rings: a NaN input writes zeros into the ring");

// ---- GrainBuf wraps (SuperCollider 3.13 recheck) ----
// One grain over a ramp of frame numbers: from 90% at rate 1 it crosses the
// end and continues from frame 0; from 10% at rate -1 it crosses frame 0
// and continues from the end
rampBuffer = Buffer.loadCollection(server, Array.series(4800, 0, 1).asFloat);
recordBuffer = Buffer.alloc(server, 3000, 2);
server.sync;
wrapRead = { arg pos, rate;
    var condition = Condition(false), values;
    recordBuffer.zero; server.sync;
    Synth(\strataCheckWrap, [\bufnum, rampBuffer, \record, recordBuffer, \env, rectEnv, \pos, pos, \rate, rate]);
    0.2.wait; server.sync;
    recordBuffer.loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition);
    (values ? []).clump(2).collect(_.first)
};
readings = [wrapRead.(0.9, 1), wrapRead.(0.1, -1)];
ringOk = (0.05 * sampleRate).asInteger - 10;  // samples well inside the 0.05 s grain
check.([readings, [1, -1]].flop.every({ arg pair;
    var values = pair[0].copyRange(0, ringOk - 1), rate = pair[1];
    var steps = values.differentiate.drop(1);
    var jumps = steps.select({ arg step; (step - rate).abs > 0.01 });
    (values.size == ringOk) and: { jumps.size == 1 } and: { (jumps[0] + (rate * 4799)).abs < 0.01 }
        and: { values.last > 0 }
}), "rings: GrainBuf wraps forward across a buffer end and backward across frame 0 (ends % and %)".format(
    readings[0].copyRange(ringOk - 3, ringOk - 1), readings[1].copyRange(ringOk - 3, ringOk - 1)));

// ---- Where ring grains read ----
timecode = Synth(\strataCheckTimecode, [\out, engine.granBuses[0], \out2, engine.inputBus, \now, nowBus],
    engine.voiceGroup, \addToHead);
sine = Synth(\strataCheckSine, [\out, engine.granBuses[4], \freq, 440], engine.voiceGroup, \addToHead);

// Pitch is the grain rate. Exactly: voice 1 on the timecode reads it at
// pitchShift x the time (0.2 s grains, two a second, one at a time). And as
// heard: voice 5 on a 440 Hz sine, through Pitch (a sanity check within
// 2.5%; a semitone is 5.9%)
startTimecodeVoice.(0, 0, 0.2, 2.0, 1.0);
0.6.wait;
readings = [0.5, 1, 2].collect({ arg pitch;
    var reads;
    command.(\setGrainParam, 0, \pitchShift, pitch);
    0.4.wait;                              // grains at the old pitch have ended
    reads = timeReads.(0, 1.2);
    [reads[5], reads[6]]
});
check.([readings, [0.5, 1, 2]].flop.every({ arg pair; pair[0].every({ arg rate; (rate / pair[1] - 1).abs < 0.002 }) }),
    "rings: pitchShift 0.5, 1 and 2 read at rates 0.5, 1 and 2 (got %)".format(readings.collect(_.round(0.0001))));
command.(\voiceOff, 0);
command.(\voiceOn, 4, 100.0, 0.2, 0.0, 0.2, 10.0, 1.0);
server.sync;
engine.synths[engine.voiceKey(4)].set(\out, quietBus.index);
readings = [0.5, 1, 2].collect({ arg pitch;
    command.(\setGrainParam, 4, \pitchShift, pitch);
    0.3.wait;
    pitchOf.(4)
});
check.([readings, [220, 440, 880]].flop.every({ arg pair; (pair[0] / pair[1] - 1).abs < 0.025 }),
    "rings: pitchShift 0.5, 1 and 2 play 220, 440 and 880 Hz (Pitch, within 2.5 percent; got %)".format(readings.round(0.1)));
command.(\voiceOff, 4);

// The synth source's grains never bend again (rateLevel 0): voice 2 (FM, a
// sine at index 0) at 440 Hz and bend 2 plays 880 Hz
command.(\voiceOn, 1, 440.0, 0.2, 0.0, 0.2, 10.0, 1.0);
command.(\setVoiceParam, 1, \index, 0.0);
command.(\setVoiceParam, 1, \bend, 2.0);
server.sync; 0.6.wait;
readings = pitchOf.(1);
check.((readings / 880 - 1).abs < 0.025, "rings: a synth voice's bend is applied once (880 Hz within 2.5 percent, not 1760; got % Hz)".format(readings.round(0.1)));
command.(\voiceOff, 1);

// The lookback (voice 1 on the timecode): rate 4 and 0.5 s grains.
// Continuous: 1.5 grains a second, so one plays at a time; each starts
// margin + 3 x 0.5 s back (and up to a block more: the head is reported at
// the block's start) and never reaches the head
startTimecodeVoice.(0, 0, 0.5, 1.5, 4.0);
2.0.wait;                                  // the ring holds 2 s of timecode
grainSynth = engine.synths[engine.grainKey(0)];
readings = timeReads.(0, 3.0);
check.((readings[1] >= (engine.ringReadMargin - 0.0005)) and: { readings[0] > 1.4 },
    "rings: no grain reads ahead of the write head at rate 4 and 0.5 s grains (lookback % to % s)".format(
        readings[1].round(0.0001), readings[0].round(0.0001)));
check.((readings[2] - 0.5).abs < 0.005 and: { readings[0] <= (1.505 + (block / sampleRate) + 0.0005) },
    "rings: a continuous grain at rate 4 keeps its 0.5 s length (longest % s, starting at most % s back)".format(
        readings[2].round(0.0001), readings[0].round(0.0001)));
// Triggered: three grains 0.4 s apart, each 0.5 / 3 s long, starting one
// grain length (plus the margin) back
command.(\setGrainParam, 0, \grainMode, 1);
0.6.wait;
readings = timeReads.(0, 0.4, { 3.do({ command.(\retrigger, 0, 1.0); 0.4.wait }) });
check.(((readings[2] - (0.5 / 3)).abs < 0.003) and: { readings[0] <= (0.505 + (block / sampleRate) + 0.0005) }
    and: { readings[0] > 0.49 } and: { readings[1] >= (engine.ringReadMargin - 0.0005) },
    "rings: a triggered grain at rate 4 and 0.5 s lasts 0.167 s and starts at most 0.505 s back (length % s, lookback % to % s)".format(
        readings[2].round(0.0001), readings[1].round(0.0001), readings[0].round(0.0001)));
command.(\setGrainParam, 0, \grainMode, 0);
// Rate 1, grains back to back for longer than the ring: grains that cross
// its end read on without a jump (at most a block between grains) or a gap
command.(\setGrainParam, 0, \pitchShift, 1.0);
command.(\setGrainParam, 0, \grainDensity, 2.0);
0.6.wait;
readings = timeReads.(0, engine.ringSeconds + 0.3);
check.((readings[3] < 0.01) and: { readings[4] < 0.01 },
    "rings: grains crossing the ring's end are continuous (largest step % s, % s without a grain)".format(
        readings[3].round(0.0001), readings[4].round(0.0001)));
// history is for the input ring: the synth source's grain synth stays at 0
command.(\setGrainParam, 0, \history, 3.0); server.sync;
check.(getControl.(grainSynth, \history) == 0, "rings: history never reaches a synth-sourced voice's grain synth");
command.(\setGrainParam, 0, \history, 0.0);
command.(\voiceOff, 0);

// Input history (voice 4 on the input ring): history 2 reads the timecode
// from 2 s back (margin and up to a block more)
startTimecodeVoice.(3, engine.inputSource, 0.1, 4.0, 1.0);
command.(\setGrainParam, 3, \history, 2.0);
0.3.wait;
readings = timeReads.(3, 1.0);
check.((readings[1] >= 2.004) and: { readings[0] <= (2.005 + (block / sampleRate) + 0.0005) },
    "rings: history 2 reads the tone from 2 s back (lookback % to % s)".format(readings[1].round(0.0001), readings[0].round(0.0001)));
// bufScan reaches a ring grain synth, but the freeze area's neutral
// ringScanOffset leaves an unfrozen ring's read point where it was
command.(\setGrainParam, 3, \bufScan, 2.0); server.sync;
ringOk = getControl.(engine.synths[engine.grainKey(3)], \bufScan);
0.3.wait;
readings = timeReads.(3, 1.0);
check.((ringOk == 2) and: { readings[1] >= 2.004 } and: { readings[0] <= (2.005 + (block / sampleRate) + 0.0005) },
    "rings: bufScan with the neutral hook changes nothing (bufScan %, lookback % to % s)".format(
        ringOk, readings[1].round(0.0001), readings[0].round(0.0001)));
command.(\setGrainParam, 3, \bufScan, 0.0);
command.(\setGrainParam, 3, \history, 0.0);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);

timecode.free; sine.free;
h.stopAllVoices;

// ---- free frees the writers and rings (a second engine) ----
other = h.startEngine;
otherRings = other.areaState[\rings];
otherWriters = otherRings[\writers].copy;
check.(otherWriters.size == (other.numVoices + 1)
    and: { h.synthNames(other.context.xg).count({ arg name; name == \strataRingWrite }) == (other.numVoices + 1) },
    "rings: a second engine starts its own writers");
h.freeEngine(other);
server.sync; 0.2.wait;
check.(h.synthNames(other.context.xg).includes(\strataRingWrite).not
    and: { other.ringWriterKeys.every({ arg key; other.synths[key].isNil }) }
    and: { (otherRings[\voiceL] ++ otherRings[\voiceR] ++ [otherRings[\inputL], otherRings[\inputR]]).every({ arg buffer; buffer.bufnum.isNil }) }
    and: { otherRings[\phaseBuses].every({ arg bus; bus.index.isNil }) },
    "rings: free frees the writers and rings");

probeGroup.free;
[quietBus, nowBus, readOut, phaseBus].do(_.free);
[rectEnv, rampBuffer, recordBuffer, scratchRing].do(_.free);
server.sync;
}
