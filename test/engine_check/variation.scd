// test/engine_check/variation.scd
// Per-grain variation and the scale: reverse grains, pitch jitter, the
// interval sets and their probability, quantize to the scale (setScale and
// scaleBuffer), size jitter's cap, pan jitter, and that every variation
// control feeds a UGen.
//
// Grain rates and lengths are read from a timecode, as in rings.scd: a
// check synth writes the seconds since it started (left) and 1 (right) into
// voice 1's bus, so a grain of voice 1 (through a rectangular envelope) reads
// back on its left over its right the time its audio was written. A log
// synth writes each grain's rate (how far its read moved since 10 ms into
// it, over the time since then) and length into two buffers when the grain
// ends, one frame per grain.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var probeGroup, quietBus, nowBus, readOut, rectEnv, timecode, logRates, logDurs, grainLog, startTimecodeVoice;
var grains, rates, semitones, majorMask = 2741, majorOffsets, before, after, state, bufferOffsets;
var rampPath, rampFile, rampFrames, scaleNote, leftPath, peakBus, peakProbe, levels, ratioDb, logFrames = 128, sentinel = -1000;
var varyControls = [\reverseProb, \pitchJitter, \panJitter, \sizeJitter, \intervalCount, \intervalProb, \quantize,
    \scaleNote] ++ (1..8).collect({ arg index; ("interval" ++ index).asSymbol });

SynthDef(\strataCheckVariationTimecode, { arg out, now;
    var time = Sweep.ar(0, 1);
    Out.ar(out, [time, DC.ar(1)]);
    Out.ar(now, time);
}).add;
// One frame per grain, at its end: its rate into rates, its length (s)
// into durs. Frame BufFrames - 1 takes every other sample's write
SynthDef(\strataCheckGrainLog, { arg in, rates, durs;
    var sig = In.ar(in, 2);
    var on = sig[1] > 0.05;
    var read = sig[0] / sig[1].max(0.001);
    var elapsed = Sweep.ar(on, on);
    var mark = on * (elapsed > 0.01);
    var rate = (read - Latch.ar(read, mark)) / ((elapsed - Latch.ar(elapsed, mark)) + SampleDur.ir);
    var ended = (Delay1.ar(on) - on) > 0.5;
    var index = Select.ar(ended, [DC.ar(BufFrames.kr(rates) - 1), PulseCount.ar(ended) - 1]);
    BufWr.ar(Delay1.ar(rate), rates, index, 0);
    BufWr.ar(Delay1.ar(elapsed), durs, index, 0);
}).add;
// The grain SynthDefs hold scaleBuffer's bufnum as a constant, and every
// engine built on this server re-adds them with its own: an earlier area's
// second engine (h.startEngine, freed since) has left them reading its freed
// buffer. On norns one engine runs at a time. Rebuild them for this engine
engine.addGrainDefs;
server.sync;

probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);
nowBus = Bus.audio(server, 1);
readOut = Bus.audio(server, 2);
peakBus = Bus.control(server, 2);
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
logRates = Buffer.alloc(server, logFrames, 1);
logDurs = Buffer.alloc(server, logFrames, 1);
server.sync;

// The grains a voice (engine voice 0 by default) plays while seconds pass: [rate, length] per grain,
// the first left out (it may have started before the log)
grainLog = { arg seconds, voice = 0;
    var log, values = [nil, nil];
    [logRates, logDurs].do({ arg buffer; buffer.fill(0, logFrames, sentinel) });
    server.sync;
    engine.synths[engine.grainKey(voice)].set(\out, readOut.index);
    log = Synth(\strataCheckGrainLog, [\in, readOut, \rates, logRates, \durs, logDurs], probeGroup);
    seconds.wait;
    log.free;
    engine.synths[engine.grainKey(voice)].set(\out, engine.voicePathBus(voice, engine.grainSource[voice]).index);
    h.check(h.getControl(engine.synths[engine.grainKey(voice)], \out) == engine.voicePathBus(voice, engine.grainSource[voice]).index,
        "variation: a grain synth's out is restored to its own path (voice %)".format(voice));
    server.sync;
    [logRates, logDurs].do({ arg buffer, index;
        var condition = Condition(false);
        buffer.loadToFloatArray(action: { arg array; values[index] = array; condition.test = true; condition.signal });
        h.awaitReply(condition);
    });
    [values[0].copyRange(0, logFrames - 2), values[1].copyRange(0, logFrames - 2)].flop
        .select({ arg pair; pair[0] != sentinel }).drop(1)
};
// Voice voice on source with its synth (if any) played elsewhere, its
// grains through the rectangular envelope, no pan wander or position spread
startTimecodeVoice = { arg voice, source, size, density, pitch;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 100.0, 0.2, 0.0, size, density, pitch);
    server.sync;
    engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.set(\out, quietBus.index) };
    [\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, voice, control, 0.0) });
    engine.synths[engine.grainKey(voice)].set(\envBuf, rectEnv.bufnum);
    server.sync;
};

// ---- The controls and the scale ----
h.grainDefs.do({ arg name;
    var unused = varyControls.reject({ arg control; h.controlFeedsAUGen(name, control) });
    check.(unused.isEmpty, "variation: the variation controls feed a UGen in % (unused: %)".format(name, unused));
});

state = engine.areaState[\scale];
bufferOffsets = {
    var condition = Condition(false), values;
    engine.scaleBuffer.loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition);
    values.asArray.collect(_.asInteger)
};
check.((engine.scaleBuffer.numFrames == 12) and: { engine.scaleRootAndMask == [0, 4095] }
    and: { bufferOffsets.value == Array.fill(12, 0) },
    "variation: the scale buffer has 12 frames and starts chromatic (root 0, mask 4095, every offset 0)");
// C major: C# D# F# G# A# go down to C D F G A (a tie goes down)
majorOffsets = [0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0];
command.(\setScale, 0, majorMask); server.sync;
check.(bufferOffsets.value == majorOffsets, "variation: setScale(0, C major) fills the offsets to the nearest tone (got %)"
    .format(bufferOffsets.value));
// D major (C# D E F# G A B): C is a tie between B and C#, so -1
command.(\setScale, 2, majorMask); server.sync;
check.(bufferOffsets.value == [-1, 0, 0, -1, 0, -1, 0, 0, -1, 0, -1, 0],
    "variation: the mask is from the root (D major; got %)".format(bufferOffsets.value));
before = [engine.scaleRootAndMask, bufferOffsets.value];
[[12, majorMask], [-1, majorMask], [0, 0], [0, 4096], [0, -5]].do({ arg pair; command.(\setScale, pair[0], pair[1]) });
server.sync;
after = [engine.scaleRootAndMask, bufferOffsets.value];
check.(after == before, "variation: setScale ignores a bad root or mask (kept %)".format(after[0]));
command.(\setScale, 0, 4095); server.sync;

// ---- Grain rates and lengths (voice 1 on the timecode) ----
timecode = Synth(\strataCheckVariationTimecode, [\out, engine.granBuses[0], \now, nowBus], engine.voiceGroup, \addToHead);
startTimecodeVoice.(0, 0, 0.1, 5.0, 1.0);
1.0.wait;  // the ring holds a second of timecode

// at the defaults every grain plays at the voice's pitch
grains = grainLog.(2.0);
check.((grains.size >= 5) and: { grains.every({ arg pair; (pair[0] - 1).abs < 0.002 }) },
    "variation: at the defaults every grain plays at rate 1 (% grains)".format(grains.size));

command.(\setGrainParam, 0, \reverseProb, 1.0);
0.3.wait;
grains = grainLog.(3.0);
check.((grains.size >= 8) and: { grains.every({ arg pair; (pair[0] + 1).abs < 0.002 }) },
    "variation: reverseProb 1 plays a ramp backward (rates %)".format(grains.collect({ arg pair; pair[0].round(0.001) })));
command.(\setGrainParam, 0, \reverseProb, 0.0);

command.(\setGrainParam, 0, \pitchJitter, 12.0);
0.3.wait;
grains = grainLog.(5.0);
rates = grains.collect(_.first);
semitones = rates.collect({ arg rate; rate.ratiomidi });
check.((grains.size >= 15) and: { rates.every({ arg rate; (rate >= 0.499) and: { rate <= 2.002 } }) }
    and: { (semitones.maxItem - semitones.minItem) > 12 }
    and: { semitones.count({ arg each; (each - each.round).abs > 0.05 }) > (semitones.size div: 2) },
    "variation: pitchJitter 12 keeps grains within an octave and spreads them (% grains, % to % semitones)".format(
        grains.size, semitones.minItem.round(0.01), semitones.maxItem.round(0.01)));

// quantize: C major from C4, with the same jitter
command.(\setScale, 0, majorMask);
command.(\setGrainParam, 0, \scaleNote, 60.0);
command.(\setGrainParam, 0, \quantize, 1.0);
0.3.wait;
grains = grainLog.(5.0);
semitones = grains.collect({ arg pair; pair[0].ratiomidi });
check.((grains.size >= 15) and: { semitones.every({ arg each;
        ((each - each.round).abs < 0.03) and: { majorOffsets[(60 + each.round.asInteger) % 12] == 0 }
            and: { each.round.abs <= 12 } }) }
    and: { semitones.collect(_.round).asSet.size >= 4 },
    "variation: quantize lands every grain on a scale tone (C major from C4; semitones %)".format(
        semitones.collect(_.round(0.01))));
command.(\setGrainParam, 0, \quantize, 0.0);
command.(\setGrainParam, 0, \pitchJitter, 0.0);
command.(\setScale, 0, 4095);

// the octaves set: one of -12, 0 and 12 per grain
[[1, -12.0], [2, 0.0], [3, 12.0]].do({ arg pair; command.(\setGrainParam, 0, ("interval" ++ pair[0]).asSymbol, pair[1]) });
command.(\setGrainParam, 0, \intervalCount, 3.0);
0.3.wait;
grains = grainLog.(5.0);
rates = grains.collect(_.first);
check.((grains.size >= 15) and: { rates.every({ arg rate; [0.5, 1, 2].any({ arg target; (rate / target - 1).abs < 0.002 }) }) }
    and: { [0.5, 1, 2].every({ arg target; rates.any({ arg rate; (rate / target - 1).abs < 0.002 }) }) },
    "variation: octaves picks only -12, 0 and 12 (rates %)".format(rates.collect(_.round(0.001))));
command.(\setGrainParam, 0, \intervalProb, 0.0);
0.3.wait;
grains = grainLog.(2.5);
check.((grains.size >= 8) and: { grains.every({ arg pair; (pair[0] - 1).abs < 0.002 }) },
    "variation: intervalProb 0 plays the base pitch only (rates %)".format(grains.collect({ arg pair; pair[0].round(0.001) })));
command.(\setGrainParam, 0, \intervalProb, 1.0);
command.(\setGrainParam, 0, \intervalCount, 0.0);

// size jitter: 0.5 s grains x 2^(-1..1), never past 0.5 s
command.(\setGrainParam, 0, \grainSize, 0.5);
command.(\setGrainParam, 0, \grainDensity, 1.9);
command.(\setGrainParam, 0, \sizeJitter, 1.0);
0.6.wait;
grains = grainLog.(7.0);
rates = grains.collect({ arg pair; pair[1] });
check.((grains.size >= 8) and: { rates.maxItem <= 0.505 } and: { rates.maxItem >= 0.495 } and: { rates.minItem < 0.49 },
    "variation: sizeJitter never makes a grain longer than 0.5 s (lengths %)".format(rates.collect(_.round(0.001))));
command.(\setGrainParam, 0, \sizeJitter, 0.0);
command.(\voiceOff, 0);
timecode.free;

// ---- Pan jitter (voice 2 on a buffer slot) ----
// stereo.wav holds 0.5 left and -0.25 right: at zero pan jitter the left
// buffer's grains play left only and the right's right only, as in 3.1, so
// the channels keep their 6 dB difference
command.(\loadBuffer, 0, h.stereoPath, 0); 0.3.wait; server.sync;
command.(\setGrainSource, 1, 1);
command.(\voiceOn, 1, 100.0, 0.5, 0.0, 0.1, 10.0, 1.0);
server.sync;
command.(\setGrainParam, 1, \panSpread, 0.0);
engine.synths[engine.grainKey(1)].set(\out, readOut.index);
peakProbe = Synth(\strataCheckChannelPeaks, [\in, readOut, \out, peakBus], probeGroup);
0.5.wait;
levels = h.measure(peakProbe, peakBus, 1.0);
ratioDb = (levels[0] / levels[1].max(1e-9)).ampdb;
check.((levels[1] > 0.01) and: { (ratioDb - 2.ampdb).abs < 0.5 },
    "variation: zero pan jitter matches 3.1's channel levels within 0.5 dB (left over right % dB, want %)".format(
        ratioDb.round(0.01), 2.ampdb.round(0.01)));
// a left-only file: with pan jitter 1 the left buffer's grains reach the
// right channel, but never past the center (their pans stay in -1..0)
leftPath = h.tempDir +/+ "variation-left.wav";
h.writeTestFile(leftPath, 22050, 11025, [0.5, 0.0]);
command.(\loadBuffer, 0, leftPath, 0); 0.3.wait; server.sync;
0.3.wait;
levels = h.measure(peakProbe, peakBus, 1.0);
check.((levels[0] > 0.01) and: { levels[1] < (levels[0] * 0.01) },
    "variation: zero pan jitter keeps a left-only buffer left (peaks %)".format(levels.round(0.0001)));
command.(\setGrainParam, 1, \panJitter, 1.0);
0.3.wait;
levels = h.measure(peakProbe, peakBus, 2.0);
check.((levels[1] > (levels[0] * 0.3)) and: { levels[1] <= (levels[0] * 1.001) },
    "variation: pan jitter spreads grain pans within -1..1 (peaks %)".format(levels.round(0.0001)));
command.(\setGrainParam, 1, \panJitter, 0.0);
command.(\setGrainParam, 1, \panSpread, 0.5);
peakProbe.free;
command.(\voiceOff, 1);
command.(\setGrainSource, 1, 0);

// ---- A buffer voice quantizes around the rate it plays (voice 2) ----
// A slot holding a ramp (left: the fraction of its 1 s, right: 1) is read
// like the timecode. bufRate 2^(4/12) (a MIDI E4) with Lua's scaleNote 60
// (root C): the grain synth quantizes around 64, so every grain, played at
// its rate, still lands on C major
rampPath = h.tempDir +/+ "variation-ramp.wav";
rampFrames = server.sampleRate.asInteger;
rampFile = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(server.sampleRate);
rampFile.openWrite(rampPath);
rampFile.writeData(h.stereoOf(h.rampSignal(rampFrames) / rampFrames, h.repeating(rampFrames, [1.0])));
rampFile.close;
command.(\loadBuffer, 0, rampPath, 0); 0.3.wait; server.sync;
startTimecodeVoice.(1, 1, 0.1, 5.0, 1.0);
[[\bufPos, 0.3], [\bufScan, 0.0], [\scaleNote, 60.0], [\bufRate, 2 ** (4 / 12)], [\pitchJitter, 12.0], [\quantize, 1.0]]
    .do({ arg pair; command.(\setGrainParam, 1, *pair) });
command.(\setScale, 0, majorMask);
server.sync;
scaleNote = h.getControl(engine.synths[engine.grainKey(1)], \scaleNote);
check.((scaleNote - 64).abs < 0.001,
    "variation: a buffer voice's bufRate moves the scaleNote its grain synth gets (60 + 4 semitones; got %)".format(scaleNote));
0.3.wait;
grains = grainLog.(5.0, 1);
semitones = grains.collect({ arg pair; pair[0].ratiomidi });
check.((grains.size >= 15) and: { semitones.every({ arg each;
        ((each - each.round).abs < 0.03) and: { majorOffsets[(60 + each.round.asInteger) % 12] == 0 } }) }
    and: { semitones.collect(_.round).asSet.size >= 4 },
    "variation: a buffer voice at bufRate 2^(4/12) (MIDI E4) keeps its grains in C major (semitones %)".format(
        semitones.collect(_.round(0.01))));
[[\pitchJitter, 0.0], [\quantize, 0.0], [\bufRate, 1.0], [\bufPos, 0.0], [\posSpread, 0.5], [\panSpread, 0.5]]
    .do({ arg pair; command.(\setGrainParam, 1, *pair) });
command.(\setScale, 0, 4095);
command.(\voiceOff, 1);
command.(\setGrainSource, 1, 0);

h.stopAllVoices;
[\reverseProb, \pitchJitter, \panJitter, \sizeJitter, \intervalCount, \quantize].do({ arg control;
    engine.numVoices.do({ arg voice; command.(\setGrainParam, voice, control, 0.0) });
});
command.(\setGrainParam, 0, \grainSize, 0.1);
command.(\setGrainParam, 0, \grainDensity, 20.0);
command.(\setGrainParam, 0, \scaleNote, 60.0);
probeGroup.free;
[quietBus, nowBus, readOut, peakBus].do(_.free);
[rectEnv, logRates, logDurs].do(_.free);
File.delete(leftPath);
File.delete(rampPath);
server.sync;
}
