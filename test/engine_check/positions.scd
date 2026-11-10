// test/engine_check/positions.scd
// The positions area (lib/engine/StrataPositions.sc): a buffer grain's scan
// phase and its three transient controls (t_scanReset, scrubRate, scanHold).
// Two kinds of check: the hook beside a Phasor of the expected rate, exactly,
// on the server; and the real \strataGrainBuf end to end, on a slot whose left
// channel is a staircase of its position and whose right channel is 1, so the
// left / right ratio of the grains is where they read.
// See docs/notes/engine/positions.md.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var readBus = { arg bus; h.readBus(bus) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var out = Bus.control(server, 2), posBus = Bus.control(server, 2);
var voice = 2, slot = 5, otherSlot = 6, grainKey = engine.grainKey(voice), steps = 64, seconds = 2;
var path = h.tempDir +/+ "positions.wav";
var saved = engine.grainControls[voice].copy;
var compare, position, reading, slope, setGrain, hookReset, values, probe, moved, restarted, before, after, stepFrames, frames, grain;

// The hook beside a Phasor of the rate it should run at, both reset by
// t_phaseReset; out: [the largest difference since the start, the hook's phase]
SynthDef(\strataCheckScanCompare, { arg peaks, bufScan = 0.5, freeze = 0, scrubRate = 0, scanHold = 0, rate = 0.5, t_phaseReset = 0;
    var a = engine.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_phaseReset);
    var b = Phasor.ar(t_phaseReset, rate * SampleDur.ir, 0, 1);
    Out.kr(peaks, [A2K.kr(Peak.ar((a - b).abs)), A2K.kr(a)]);
}).add;
// Where a voice's grains read (left / right, summed over 20 ms: the voice
// runs with no pan spread or pan jitter, which would move the ratio) and the
// server's own time, so a slope never depends on sclang's clock
SynthDef(\strataCheckScanPosition, { arg in, peaks;
    var signal = In.ar(in, 2);
    Out.kr(peaks, [A2K.kr(RunningSum.ar(signal[0].abs, 960) / RunningSum.ar(signal[1].abs, 960).max(0.001)), Sweep.kr(0, 1)]);
}).add;
server.sync;

// [difference, phase] of the hook after `wait` seconds at these settings
compare = { arg settings, wait = 0.4;
    var synth = Synth(\strataCheckScanCompare, [\peaks, out] ++ settings, engine.processGroup, \addToTail), result;
    wait.wait;
    result = readBus.(out);
    synth.free; server.sync;
    result
};

values = compare.([\bufScan, 0.5, \rate, 0.5], 1.0);
check.((values[0] < 1e-6) and: { values[1] > 0.3 },
    "positions: slotScanPhase is 3.2's scan (difference %, phase %)".format(values[0], values[1]));

// The real grain synth, on a slot of known contents
h.writeTestFile(path, server.sampleRate, (seconds * server.sampleRate).round.asInteger, [0, 0]);
command.(\loadBuffer, slot, path, 0);
h.waitFor({ engine.bufferFrames[slot] > 0 }, 3);
0.1.wait; server.sync;
frames = engine.bufferFrames[slot];
stepFrames = frames div: steps;
steps.do({ arg step; engine.buffersL[slot].fill(step * stepFrames, stepFrames, step / steps) });
engine.buffersR[slot].fill(0, frames, 1);
server.sync;

setGrain = { arg ... pairs;
    pairs.pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) });
    server.sync;
};
position = { readBus.(posBus)[0] };
// [where the grains read, the server's time]
reading = { readBus.(posBus) };
// How fast the grains moved between two readings, per server second
slope = { arg first, second; (second[0] - first[0]) / (second[1] - first[1]).max(0.001) };

setGrain.(\posSpread, 0, \panSpread, 0, \panJitter, 0, \bufPos, 0, \bufScan, 0, \loopStart, 0, \loopLength, 1, \scrubRate, 0, \scanHold, 0);
command.(\setGrainSource, voice, slot + 1);
command.(\voiceOn, voice, 200.0, 0.5, 0.0, 0.04, 200.0, 1.0);
server.sync;
probe = Synth.before(engine.synths[engine.voiceMixKey(voice)], \strataCheckScanPosition,
    [\in, engine.voicePathBus(voice, 1).index, \peaks, posBus.index]);
server.sync;
0.2.wait;

// t_scanReset: on the hook, and on the real synth, which it reaches without
// being stored
hookReset = {
    var synth = Synth(\strataCheckScanCompare, [\peaks, out, \bufScan, 0.5, \rate, 0.5], engine.processGroup, \addToTail), result;
    0.4.wait;
    synth.set(\t_phaseReset, 1);
    0.05.wait;
    result = readBus.(out);
    synth.free; server.sync;
    result
}.value;
setGrain.(\bufScan, 0.5);
1.2.wait;
moved = position.value;
command.(\setGrainParam, voice, \t_scanReset, 1);
0.1.wait;
restarted = position.value;
grain = engine.synths[grainKey];
// the switch to the synth source and back cuts this grain synth (the kill
// fade) and starts another, whose position alone is read after the fade
command.(\setGrainSource, voice, 0);
command.(\setGrainSource, voice, slot + 1);
server.sync;
0.15.wait;
after = position.value;
check.((hookReset[0] < 1e-6) and: { hookReset[1] < 0.1 }
    and: { moved > 0.4 } and: { restarted < 0.2 }
    and: { engine.grainControls[voice][\t_scanReset].isNil }
    and: { engine.grainControlPairs(voice).includes(\t_scanReset).not }
    and: { engine.synths[grainKey] !== grain }
    and: { after < 0.2 },
    "positions: t_scanReset restarts the phase and is not stored (hook %, %; the grains at % then %, after a switch %; stored %)"
        .format(hookReset[0], hookReset[1], moved, restarted, after, engine.grainControls[voice][\t_scanReset]));

// scrubRate adds to the scan: scan 0 and scrubRate 0.5, then a scan as well
values = [compare.([\bufScan, 0, \scrubRate, 0.5, \rate, 0.5]), compare.([\bufScan, 0.25, \scrubRate, 0.5, \rate, 0.75])];
setGrain.(\bufScan, 0);
command.(\setGrainParam, voice, \t_scanReset, 1);
0.1.wait;
setGrain.(\scrubRate, 0.5);
0.05.wait;
before = reading.value;
0.5.wait;
after = reading.value;
setGrain.(\scrubRate, 0);
check.(values.every({ arg each; each[0] < 1e-6 }) and: { (values[0][1] - 0.2).abs < 0.05 }
    and: { slope.(before, after).inclusivelyBetween(0.4, 0.6) },
    "positions: scrubRate adds to the scan (differences %, %; the grains moved % a second)".format(values[0][0], values[1][0], slope.(before, after)));

// scanHold stops the voice's scan and leaves the glide, frozen or not
values = [compare.([\bufScan, 0.5, \scanHold, 1, \rate, 0]), compare.([\bufScan, 0.5, \scanHold, 1, \scrubRate, 0.25, \rate, 0.25]),
    compare.([\bufScan, 0.5, \freeze, 1, \scrubRate, 0.25, \rate, 0.25])];
command.(\setGrainParam, voice, \t_scanReset, 1);
setGrain.(\bufScan, 0.5, \scanHold, 1);
0.1.wait;
before = position.value;
0.3.wait;
after = position.value;
moved = after - before;
setGrain.(\scrubRate, 0.25);
0.05.wait;
before = reading.value;
0.6.wait;
after = reading.value;
setGrain.(\scrubRate, 0, \scanHold, 0, \bufScan, 0);
check.(values.every({ arg each; each[0] < 1e-6 }) and: { values[0][1] < 1e-6 }
    and: { moved.abs < 0.03 } and: { slope.(before, after).inclusivelyBetween(0.18, 0.32) },
    "positions: scanHold stops the scan but not the glide (differences %; held moved %, the glide % a second)"
        .format(values.collect(_[0]), moved, slope.(before, after)));

// A switch mid-glide keeps gliding: both controls are stored and sent
setGrain.(\scrubRate, 0.125, \scanHold, 1);
grain = engine.synths[grainKey];
command.(\setGrainSource, voice, otherSlot + 1);
server.sync;
values = [getControl.(engine.synths[grainKey], \scrubRate), getControl.(engine.synths[grainKey], \scanHold)];
check.((engine.synths[grainKey] !== grain) and: { values[0].equalWithPrecision(0.125, 1e-6) } and: { values[1] == 1 },
    "positions: scrubRate and scanHold survive a source switch (%)".format(values));
setGrain.(\scrubRate, 0, \scanHold, 0);

check.([\scrubRate, \scanHold, \t_scanReset].every({ arg control; h.controlFeedsAUGen(\strataGrainBuf, control) }),
    "positions: the scan controls feed a UGen");

probe.free;
command.(\voiceOff, voice);
h.stopAllVoices;
command.(\setGrainSource, voice, 0);
command.(\clearBuffer, slot);
engine.grainControls[voice] = saved;
server.sync;
out.free; posBus.free;
File.delete(path);
}
