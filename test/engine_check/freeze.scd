// test/engine_check/freeze.scd
// Freeze: each source holds (a synth voice's ring, an input voice's copy,
// a buffer's scan) and unfreeze resumes; the input copy's fade and its
// ring changes; the input grain synth as a ring reader; a source switch
// unfreezes; spectral writers on a high engine (one writer per voice) and
// spectral on standard holding.
//
// Most reads use a timecode, as the rings area does: a check synth writes
// the seconds since it started (left) and 1 (right) into voice 1's bus and
// the input bus (each switchable), and the same seconds to a private bus. A
// grain synth with a rectangular envelope then reads left/right as the time
// its audio was written.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var rings = engine.areaState[\rings], state = engine.areaState[\freeze];
var sampleRate = server.sampleRate, margin = engine.ringReadMargin;
// how much later than the clock was read a command may take effect: the
// server runs commands once per hardware period (1024 frames under the
// check's dummy JACK, 21 ms), and the read and the command each take a trip
var periodSlack = 0.06;
var probeGroup, quietBus, nowBus, clockBus, readOut, rectEnv, timecode, started;
var timeReads, startTimecodeVoice, now, phaseMoves, grainOf, fadingRingReader, voiceRing, inputRing;
var readings, frozenAt, live, fading, ok, savedFadeWait = engine.bufferFadeWait;
var rampPath, rampFile, other, otherCommand, writerNodes, root, write, high, toggles;

// A grain synth's reads while seconds pass: [largest lookback, smallest
// lookback, largest read, smallest read, seconds with a grain]. Reads only
// while the right channel (1 in the ring) is above 0.05.
SynthDef(\strataCheckFreezeRead, { arg in, now, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset);
    var on = sig[1] > 0.05;
    var read = sig[0] / sig[1].max(0.001);
    var lookback = In.ar(now, 1) - read;
    Out.kr(out, A2K.kr([
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), lookback]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), lookback]), reset),
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), read]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), read]), reset),
        Sweep.ar(reset, on)
    ]));
}).add;
// Where each grain starts reading: its read 1 ms in (a latch on the
// grain's first sample may still hold the read before it), held between
// grains
SynthDef(\strataCheckFreezeGrainStart, { arg in, out;
    var sig = In.ar(in, 2), on = sig[1] > 0.05;
    var read = sig[0] / sig[1].max(0.001);
    var onset = (on - Delay1.ar(on)) > 0;
    Out.kr(out, A2K.kr(Latch.ar(read, DelayN.ar(onset, 0.001, 0.001))));
}).add;
// The timecode: into out (voice 1's bus, while voiceOn > 0) and out2 (the
// input bus, while inputOn > 0); the time to now (audio) and nowKr
SynthDef(\strataCheckFreezeTimecode, { arg out, out2, now, nowKr, voiceOn = 1, inputOn = 1;
    var time = Sweep.ar(0, 1), sig = [time, DC.ar(1)];
    Out.ar(out, sig * voiceOn);
    Out.ar(out2, sig * inputOn);
    Out.ar(now, time);
    Out.kr(nowKr, A2K.kr(time));
}).add;
server.sync;

probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);    // where redirected voice synths play
nowBus = Bus.audio(server, 1);
clockBus = Bus.control(server, 1);
readOut = Bus.audio(server, 2);     // where a measured grain synth plays
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
server.sync;

voiceRing = { arg voice; engine.ringBuffersFor(voice, 0) };
inputRing = engine.ringBuffersFor(0, engine.inputSource);
grainOf = { arg voice; engine.synths[engine.grainKey(voice)] };
now = { h.readBusValue(clockBus) };
// whether a phase bus moves over 0.2 s
phaseMoves = { arg bus; var first = h.readBusValue(bus); 0.2.wait; h.readBusValue(bus) != first };

// A voice's grain synth to readOut, then its reads while action runs and
// seconds pass
timeReads = { arg voice, seconds, action;
    var bus = Bus.control(server, 5), probe, values, synth = grainOf.(voice);
    synth.set(\out, readOut.index);
    probe = Synth(\strataCheckFreezeRead, [\in, readOut, \now, nowBus, \out, bus], probeGroup);
    server.sync; 0.05.wait;
    probe.set(\t_reset, 1); server.sync;
    action.value;
    seconds.wait;
    values = h.readBus(bus);
    probe.free; bus.free;
    synth.set(\out, engine.mainBus.index);
    values
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
    grainOf.(voice).set(\envBuf, rectEnv.bufnum);
    server.sync;
};
// The voice's fading strataGrainRing (a switch's), or nil
fadingRingReader = { arg voice;
    engine.fadingSynths[voice].detect({ arg synth; synth.isPlaying and: { synth.defName.asSymbol == \strataGrainRing } })
};

timecode = Synth(\strataCheckFreezeTimecode, [\out, engine.granBuses[0], \out2, engine.inputBus,
    \now, nowBus, \nowKr, clockBus], engine.voiceGroup, \addToHead);
started = Main.elapsedTime;

// ---- The area ----
check.([\frozen, \mode].every({ arg key; state[key].size == engine.numVoices })
    and: { state[\frozen].every(_.not) },
    "freeze: areaState[\\freeze] keeps \\frozen and \\mode per voice, nothing frozen");
check.(h.grainDefs.every({ arg name; h.controlFeedsAUGen(name, \freeze) }),
    "freeze: the freeze controls feed a UGen (freeze in both grain SynthDefs: the scan, the frozen ring's read point)");
check.([engine.scanRate(0.5, 0), engine.scanRate(0.5, 1)] == [0.5, 0],
    "freeze: scanRate is bufScan x (1 - freeze)");

// ---- A synth voice: its ring held ----
// voice 1 on the timecode, its ring full of it (4 s and more)
startTimecodeVoice.(0, 0, 0.1, 10.0, 1.0);
(engine.ringSeconds + 0.3 - (Main.elapsedTime - started)).max(0).wait;
frozenAt = now.value;
command.(\setGrainParam, 0, \freeze, 1.0);
server.sync;
ok = phaseMoves.(rings[\phaseBuses][0]).not;
timecode.set(\voiceOn, 0);          // the voice's bus falls silent
0.3.wait;
readings = timeReads.(0, 1.0);
check.(ok and: { state[\frozen][0] } and: { state[\mode][0] == \hold } and: { readings[4] > 0.8 }
    and: { readings[2] <= (frozenAt + periodSlack) } and: { readings[3] >= (frozenAt - 1.0) }
    and: { (readings[2] - readings[3]) < 0.15 },
    "freeze: a frozen synth voice keeps sounding after its voice synth falls silent (writer paused %, % s of grains, reads % to % s, frozen at % s)".format(
        ok, readings[4].round(0.01), readings[3].round(0.001), readings[2].round(0.001), frozenAt.round(0.001)));
// the scan moves the read point back through the frozen ring, wrapping:
// at bufScan 1 (one ring length, 4 s, a second) each grain (0.1 s apart, 0.05 s long)
// starts about 0.4 s further back, and the start jumps up to the newest
// audio (the seam) once per 4 s of travel. Each grain's start, polled at
// 20 Hz for about 3 s
readings = { arg seconds;
    var bus = Bus.control(server, 1), synth = grainOf.(0), probe, starts = List.new, began, travel;
    synth.set(\out, readOut.index);
    probe = Synth(\strataCheckFreezeGrainStart, [\in, readOut, \out, bus], probeGroup);
    command.(\setGrainParam, 0, \grainSize, 0.05);  // a gap between grains, so each start shows
    server.sync; 0.2.wait;
    command.(\setGrainParam, 0, \bufScan, 1.0);
    server.sync;
    began = Main.elapsedTime;
    while { (Main.elapsedTime - began) < seconds } { starts.add(h.readBusValue(bus)); 0.05.wait };
    travel = (Main.elapsedTime - began) * engine.ringSeconds;
    command.(\setGrainParam, 0, \bufScan, 0.0);
    command.(\setGrainParam, 0, \grainSize, 0.1);
    probe.free; bus.free;
    synth.set(\out, engine.mainBus.index);
    [starts.asArray.differentiate.drop(1), travel]
}.value(3.0);
ok = readings[0].select({ arg step; step.abs > 0.01 });
check.((ok.select({ arg step; step > 2 }).size).inclusivelyBetween((readings[1] / engine.ringSeconds).floor,
        (readings[1] / engine.ringSeconds).ceil)
    and: { ok.reject({ arg step; step > 2 }).every({ arg step; step < 0 }) }
    and: { ok.size > 20 },
    "freeze: bufScan moves the read point back through a frozen ring and passes the seam once per 4 s of travel (% s of travel, % seam jumps, % steps back, % forward)".format(
        readings[1].round(0.1), ok.count({ arg step; step > 2 }), ok.count({ arg step; step < 0 }),
        ok.count({ arg step; (step > 0) and: { step <= 2 } })));
// unfreeze: the writer resumes and the grains read just behind the head again
timecode.set(\voiceOn, 1);
command.(\setGrainParam, 0, \freeze, 0.0);
server.sync; 0.3.wait;
ok = phaseMoves.(rings[\phaseBuses][0]);
readings = timeReads.(0, 0.5);
check.(ok and: { state[\frozen][0].not } and: { readings[4] > 0.3 } and: { readings[1] >= (margin - 0.0005) }
    and: { readings[0] < 0.02 },
    "freeze: unfreeze resumes the live ring (writer moving %, lookback % to % s)".format(
        ok, readings[1].round(0.0001), readings[0].round(0.0001)));

// ---- Spectral asked for on the standard tier holds ----
command.(\setGrainParam, 0, \freezeMode, 1.0);
command.(\setGrainParam, 0, \freeze, 1.0);
server.sync;
writerNodes = h.synthTree(engine.voiceGroup).select({ arg node;
    [\strataRingWrite, \strataRingWriteSpectral].includes(node.def) });
ok = phaseMoves.(rings[\phaseBuses][0]).not;
check.((engine.tier == \standard) and: { state[\mode][0] == \hold } and: { ok }
    and: { writerNodes.every({ arg node; node.def == \strataRingWrite }) }
    and: { writerNodes.size == (engine.numVoices + 1) },
    "freeze: spectral on standard acts as hold (mode %, writer paused %, writers %)".format(
        state[\mode][0], ok, writerNodes.collect(_.def)));
command.(\setGrainParam, 0, \freeze, 0.0);
command.(\setGrainParam, 0, \freezeMode, 0.0);

// ---- A source switch unfreezes ----
command.(\setGrainParam, 0, \freeze, 1.0);
command.(\setGrainSource, 0, 2);
server.sync;
check.(state[\frozen][0].not and: { engine.grainControls[0][\freeze] == 0 } and: { phaseMoves.(rings[\phaseBuses][0]) }
    and: { getControl.(grainOf.(0), \freeze) == 0 },
    "freeze: a source switch unfreezes (the writer runs, the new grain synth starts at freeze 0)");
command.(\voiceOff, 0);
command.(\setGrainSource, 0, 0);

// ---- An input voice: the 4 s at its read point, copied ----
// voice 4 on the input ring at history 2; no other reader of its ring, so
// the copy runs at once
startTimecodeVoice.(3, engine.inputSource, 0.1, 10.0, 1.0);
command.(\setGrainParam, 3, \history, 2.0);
0.5.wait;
live = grainOf.(3);
frozenAt = now.value;
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 0.3);
server.sync;
check.(ok and: { getControl.(live, \bufL) == voiceRing.(3)[0].bufnum } and: { getControl.(live, \history) == 0 }
    and: { getControl.(live, \phaseBus) == voiceRing.(3)[2].index },
    "freeze: with no reader of its ring an input voice's copy runs at once and its grain synth reads it at history 0");
timecode.set(\inputOn, 0);          // the input falls silent
0.3.wait;
readings = timeReads.(3, 1.0);
check.((readings[4] > 0.8) and: { readings[2] <= (frozenAt - 2.0 + 0.05) } and: { readings[3] >= (frozenAt - 2.0 - 0.75) }
    and: { (readings[2] - readings[3]) < 0.15 },
    "freeze: input hold keeps the audio at the read point (history 2 s holds the tone from 2 s back: reads % to % s, frozen at % s)".format(
        readings[3].round(0.001), readings[2].round(0.001), frozenAt.round(0.001)));
// history is 0 inside the copy: a change is kept for the unfreeze
command.(\setGrainParam, 3, \history, 3.0); server.sync;
check.((getControl.(live, \history) == 0) and: { engine.grainControls[3][\history] == 3 },
    "freeze: history stays 0 inside the frozen copy (and is kept)");
command.(\setGrainParam, 3, \history, 2.0);
// the live grain synth reads the voice ring while frozen, and for 0.5 s
// after it is set back to the input ring
timecode.set(\inputOn, 1);
ok = engine.voiceRingReaders(3).includes(live);
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
0.2.wait;
readings = [engine.voiceRingReaders(3).includes(live), getControl.(live, \bufL) == inputRing[0].bufnum,
    getControl.(live, \history)];
0.5.wait;
check.(ok and: { readings[0] } and: { readings[1] } and: { readings[2] == 2 }
    and: { engine.voiceRingReaders(3).includes(live).not } and: { engine.ringReaders[live] == 3 },
    "freeze: the live input grain synth is a ring reader while frozen and for 0.5 s after unfreeze (frozen %, 0.2 s after %, back on the input ring %, history %)".format(
        ok, readings[0], readings[1], readings[2]));

// ---- The fade before a copy ----
engine.bufferFadeWait = 0.4;
// a refreeze inside that window: the live synth fades, the copy waits
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 0.3);
0.2.wait;
command.(\setGrainParam, 3, \freeze, 0.0);
0.1.wait;
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.05.wait;
readings = [getControl.(live, \ringLevel), getControl.(live, \bufL) == inputRing[0].bufnum];
0.15.wait;
readings = readings ++ [getControl.(live, \bufL) == inputRing[0].bufnum];
0.5.wait;
check.((readings[0] == 0) and: { readings[1] } and: { readings[2] } and: { getControl.(live, \bufL) == voiceRing.(3)[0].bufnum }
    and: { getControl.(live, \ringLevel) == 1 },
    "freeze: a refreeze inside that window fades before copying (ringLevel %, input ring at 0.05 s % and 0.2 s %, then the copy at ringLevel 1)".format(
        readings[0], readings[1], readings[2]));
command.(\setGrainParam, 3, \freeze, 0.0);

// a fading reader of the ring (the synth-source grain synth a switch to the
// input replaced): faded, then the copy after bufferFadeWait
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
startTimecodeVoice.(3, 0, 0.1, 10.0, 1.0);
0.3.wait;
command.(\setGrainSource, 3, engine.inputSource); server.sync;
fading = fadingRingReader.(3);
live = grainOf.(3);
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.05.wait;
readings = [fading.notNil and: { getControl.(fading, \ringLevel) == 0 }];
0.15.wait;
readings = readings ++ [getControl.(live, \bufL) == inputRing[0].bufnum];
0.5.wait;
check.(readings[0] and: { readings[1] } and: { getControl.(live, \bufL) == voiceRing.(3)[0].bufnum }
    and: { fading.isPlaying.not or: { getControl.(fading, \ringLevel) == 1 } },
    "freeze: the input copy waits for a fading ring reader (faded %, input ring at 0.2 s %, then the copy)".format(
        readings[0], readings[1]));
command.(\setGrainParam, 3, \freeze, 0.0);

// an unfreeze inside the copy's wait wins: no copy, the reader back
command.(\setGrainSource, 3, 0); server.sync;
engine.synths[engine.voiceKey(3)] !? { arg synth; synth.set(\out, quietBus.index) };
0.3.wait;
command.(\setGrainSource, 3, engine.inputSource); server.sync;
fading = fadingRingReader.(3);
live = grainOf.(3);
rings[\voiceR][3].zero; server.sync;     // the writer keeps writing silence
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.1.wait;
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
0.6.wait;
readings = [0, 0.25, 0.5, 0.75, 0.999].collect({ arg fraction;
    h.bufferSample(rings[\voiceR][3], (fraction * (rings[\voiceR][3].numFrames - 1)).asInteger) });
check.((getControl.(live, \bufL) == inputRing[0].bufnum) and: { state[\copied][3].not }
    and: { readings.every({ arg value; value != 1 }) }
    and: { fading.notNil } and: { fading.isPlaying.not or: { getControl.(fading, \ringLevel) == 1 } },
    "freeze: an unfreeze inside the copy's wait wins (no copy: the voice ring reads %)".format(readings.round(0.001)));
engine.bufferFadeWait = savedFadeWait;
command.(\setGrainParam, 3, \history, 0.0);
// a frozen input voice switched to its synth: unfrozen, its writer reads the voice bus again
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 0.3);
command.(\setGrainSource, 3, 0); server.sync;
writerNodes = h.synthTree(engine.voiceGroup).select({ arg node; node.id == engine.synths[engine.ringWriterKeys[3]].nodeID });
check.(state[\frozen][3].not and: { writerNodes.size == 1 } and: { writerNodes[0].controls[\in] == engine.granBuses[3].index }
    and: { phaseMoves.(rings[\phaseBuses][3]) },
    "freeze: a source switch unfreezes an input voice (its writer reads its voice bus and runs)");
command.(\voiceOff, 3);

// ---- A buffer voice: the scan stops, spread still moves ----
// slot 6 holds a 1 s ramp (left 0 -> 1, right 1), so a grain's read is its
// position in the slot
rampPath = h.tempDir +/+ "freeze-ramp.wav";
rampFile = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(sampleRate.asInteger);
rampFile.openWrite(rampPath);
rampFile.writeData(FloatArray.fill(sampleRate.asInteger * 2, { arg i; if (i.odd) { 1.0 } { (i div: 2) / sampleRate } }));
rampFile.close;
command.(\loadBuffer, 5, rampPath);
h.waitFor({ engine.bufferFrames[5] > 0 }, 3);
startTimecodeVoice.(1, 6, 0.05, 20.0, 1.0);
command.(\setGrainParam, 1, \bufScan, 0.5);
0.3.wait;
readings = [timeReads.(1, 0.5)];
command.(\setGrainParam, 1, \freeze, 1.0);
0.2.wait;
readings = readings ++ [timeReads.(1, 0.5)];
command.(\setGrainParam, 1, \posSpread, 0.5);
0.2.wait;
readings = readings ++ [timeReads.(1, 0.5)];
readings = readings.collect({ arg reads; reads[2] - reads[3] });
check.((readings[0] > 0.2) and: { readings[1] < 0.08 } and: { readings[2] > 0.2 },
    "freeze: buffer hold stops the scan while spread still moves (read spans scanning, frozen, frozen with spread: %)".format(
        readings.round(0.001)));
command.(\setGrainParam, 1, \freeze, 0.0);
command.(\setGrainParam, 1, \bufScan, 0.0);
command.(\voiceOff, 1);
command.(\setGrainSource, 1, 0);

timecode.free;
h.stopAllVoices;
engine.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0); command.(\setGrainParam, voice, \freezeMode, 0.0) });
server.sync;

// ---- Spectral writers (a high engine) ----
root = h.tempDir +/+ "freeze-high/";
write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
File.mkdir(root);
write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
otherCommand = { arg name ... args; h.commandTo(other, name, *args) };
high = other.tier == \high;
// the spectral writer's def is added by a high engine only (so not in the
// runner's allDefs, which the structure area checks on the standard engine)
check.(high and: { SynthDescLib.global.at(\strataRingWriteSpectral).notNil }
    and: { SynthDescLib.global.at(\strataRingWriteSpectral).controlNames.collect(_.asSymbol) == [\in, \bufL, \bufR, \phaseOut, \fftL, \fftR] }
    and: { other.areaState[\freeze][\spectralBuffers].size == other.numVoices }
    and: { other.areaState[\freeze][\spectralBuffers].flat.every({ arg buffer; buffer.numFrames == other.spectralFrames }) },
    "freeze: a high engine adds strataRingWriteSpectral, with strataRingWrite's controls and a voice's FFT pair (fftL, fftR)");
check.(engine.areaState[\freeze][\spectralBuffers] == [],
    "freeze: a standard engine allocates no spectral FFT buffers");
writerNodes = {
    h.synthTree(other.voiceGroup).select({ arg node; [\strataRingWrite, \strataRingWriteSpectral].includes(node.def) })
};
otherCommand.(\voiceOn, 0, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
otherCommand.(\setGrainParam, 0, \freezeMode, 1.0);
server.sync;
toggles = 20.collect({ arg index;
    var frozen = index.even, nodes, spectral, key = other.ringWriterKeys[0];
    otherCommand.(\setGrainParam, 0, \freeze, if (frozen) { 1.0 } { 0.0 });
    server.sync; 0.05.wait;
    nodes = writerNodes.value;
    spectral = nodes.select({ arg node; node.def == \strataRingWriteSpectral });
    (nodes.size == (other.numVoices + 1)) and: { spectral.size == if (frozen) { 1 } { 0 } }
        and: { nodes.any({ arg node; node.id == other.synths[key].nodeID }) }
        and: { (other.areaState[\rings][\writers][0] === other.synths[key]) }
        and: { frozen.not or: { spectral[0].controls[\in] == other.granBuses[0].index } }
        and: { phaseMoves.(other.areaState[\rings][\phaseBuses][0]) }
});
check.(high and: { toggles.every(_.value) } and: { other.areaState[\freeze][\frozen][0].not },
    "freeze: spectral writer replacement leaves one writer per voice (high %, 20 toggles: %)".format(high, toggles));
// spectral on silence (a stopped voice: its bus is silent) writes only the
// dither, far below hearing: no buzz at the hop rate
otherCommand.(\setGrainParam, 4, \freezeMode, 1.0);
otherCommand.(\setGrainParam, 4, \freeze, 1.0);
server.sync; 0.6.wait;
readings = {
    var condition = Condition(false), values;
    other.ringBuffersFor(4, 0)[0].loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition, 10);
    (values ? [1]).abs.maxItem
}.value;
check.((writerNodes.value.count({ arg node; node.def == \strataRingWriteSpectral }) == 1) and: { readings < 0.001 },
    "freeze: a spectral writer frozen on silence writes nothing audible (ring peak %)".format(readings));
otherCommand.(\setGrainParam, 4, \freeze, 0.0);
server.sync;
// spectral on an input voice: the copy, then a spectral writer of the input
otherCommand.(\setGrainSource, 2, other.inputSource);
otherCommand.(\voiceOn, 2, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
otherCommand.(\setGrainParam, 2, \freezeMode, 1.0);
server.sync; 0.2.wait;
otherCommand.(\setGrainParam, 2, \freeze, 1.0);
h.waitFor({ other.areaState[\freeze][\copied][2] }, 0.5);
server.sync;
readings = writerNodes.value.detect({ arg node; node.id == other.synths[other.ringWriterKeys[2]].nodeID });
check.(readings.notNil and: { readings.def == \strataRingWriteSpectral } and: { readings.controls[\in] == other.inputBus.index }
    and: { getControl.(other.synths[other.grainKey(2)], \bufL) == other.ringBuffersFor(2, 0)[0].bufnum }
    and: { phaseMoves.(other.areaState[\rings][\phaseBuses][2]) },
    "freeze: spectral on an input voice writes the held input into its ring, which its grain synth reads");
// a mode change while frozen: spectral -> hold pauses the writer instead
otherCommand.(\setGrainParam, 0, \freeze, 1.0);
otherCommand.(\setGrainParam, 0, \freezeMode, 0.0);
server.sync; 0.05.wait;
check.((other.areaState[\freeze][\mode][0] == \hold) and: { writerNodes.value.count({ arg node; node.def == \strataRingWriteSpectral }) == 1 }
    and: { phaseMoves.(other.areaState[\rings][\phaseBuses][0]).not },
    "freeze: a mode change while frozen freezes again in the new mode");
other.numVoices.do({ arg voice; otherCommand.(\setGrainParam, voice, \freeze, 0.0) });
h.stopAllVoices(other);
h.freeEngine(other);
server.sync;

probeGroup.free;
[quietBus, nowBus, clockBus, readOut].do(_.free);
rectEnv.free;
server.sync;
}
