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
var levelBus, levelProbe, level, scanState, checkScanModes, checkOneShot, checkRetriggerRestart, checkSpeed, checkSyncScan;
var checkRegionRestart, checkScanControls, withIgnoredLines, nodeCount, checkSyncScanEdges;

// 3.7's scan state (StrataPositions.sc) for a check def: the mode, the loop
// 0/1 as the span, no region, no sync unless given
scanState = { arg scanMode;
    engine.slotScanState((scanMode: scanMode, regionStart: DC.kr(0), regionLength: DC.kr(0), followRate: 1, slotGain: 1,
        t_scanSync: DC.kr(0), scanSyncPhase: DC.kr(0)), DC.kr(0), DC.kr(1))
};

// The hook beside a Phasor of the rate it should run at, both reset by
// t_phaseReset; out: [the largest difference since the start, the hook's
// phase]. 3.7: the scan is a speed (ruling 29); over a span of 1 s at the
// server's rate a speed and 3.2's loops a second are the same number, so
// the hook runs at slotScanSpeed of one second's frames, in wrap (scanMode 0)
SynthDef(\strataCheckScanCompare, { arg peaks, bufScan = 0.5, freeze = 0, scrubRate = 0, scanHold = 0, rate = 0.5, t_phaseReset = 0,
    scanMode = 0;
    var a = engine.slotScanPhase(bufScan, freeze, scrubRate, scanHold, t_phaseReset,
        engine.slotScanSpeed(1, SampleRate.ir), scanState.(scanMode));
    var b = Phasor.ar(t_phaseReset, rate * SampleDur.ir, 0, 1);
    Out.kr(peaks, [A2K.kr(Peak.ar((a - b).abs)), A2K.kr(a)]);
}).add;
// The hook's phase and position over a span of 1 s at the server's rate
// (bufPos, no spread): [the position, the server time it last rose to the
// top (0.9999) and to the bottom (0.0001), its highest, its lowest, the
// phase, the one-shot level, its lowest since the synth started]
SynthDef(\strataCheckScanModes, { arg peaks, bufScan = 1, bufPos = 0, scanMode = 1, t_scanReset = 0;
    var state = scanState.(scanMode);
    var phase = engine.slotScanPhase(bufScan, 0, 0, 0, t_scanReset, engine.slotScanSpeed(1, SampleRate.ir), state);
    var place, time = Sweep.ar(0, 1), level, lowest, now;
    state[\sum] = bufPos + phase;
    place = engine.slotScanPosition(bufPos, phase, 0, state);
    level = engine.oneShotLevel(state);
    // (at either rate: the lowest of every sample the level had)
    lowest = if (level.rate == \audio) { A2K.kr(RunningMin.ar(level)) } { RunningMin.kr(level) };
    now = if (level.rate == \audio) { A2K.kr(level) } { level };
    Out.kr(peaks, A2K.kr([place, Latch.ar(time, place >= 0.9999), Latch.ar(time, place <= 0.0001),
        RunningMax.ar(place), RunningMin.ar(place), phase]) ++ [now, lowest]);
}).add;
// The voice's level: the mean |right channel| (1 in the slot) over 10 ms
SynthDef(\strataCheckScanLevel, { arg in, peaks;
    Out.kr(peaks, A2K.kr(RunningSum.ar(In.ar(in, 2)[1].abs, 480) / 480));
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
    "positions: slotScanPhase is 3.2's scan, a speed over a span of 1 s (difference %, phase %)".format(values[0], values[1]));

// [position, top time, bottom time, highest, lowest, phase, one-shot level] of the hook in a
// mode after `wait` seconds
checkScanModes = {
    var run = { arg settings, wait;
        var synth = Synth(\strataCheckScanModes, [\peaks, out] ++ settings, engine.processGroup, \addToTail), result;
        server.sync;
        wait.wait;
        result = h.readBus(out);
        synth.free; server.sync;
        result
    };
    var block = server.options.blockSize / server.sampleRate, bounce, held, back;
    var edge, past, inside, opening;
    out.free; out = Bus.control(server, 8);
    bounce = run.([\scanMode, 1, \bufScan, 1, \bufPos, 0], 2.5);
    check.(((bounce[1] - 1).abs <= block) and: { (bounce[2] - 2).abs <= block } and: { bounce[3] > 0.9999 }
        and: { bounce[4] < 1e-6 } and: { bounce[0].inclusivelyBetween(0.4, 0.6) },
        "positions: bounce turns round at both edges (top at % s, bottom at % s, within a block of 1 s and 2 s; highest %, lowest %, now %)"
            .format(bounce[1], bounce[2], bounce[3], bounce[4], bounce[0]));
    held = run.([\scanMode, 2, \bufScan, 1, \bufPos, 0], 1.5);
    back = run.([\scanMode, 2, \bufScan, -1, \bufPos, 1], 1.5);
    check.((held[0] == 1) and: { held[5] > 1.4 } and: { back[0] == 0 } and: { back[5] < -1.4 },
        "positions: one shot holds its position at the edge, forward and backward (forward: position %, phase %; backward: %, %)"
            .format(held[0], held[5], back[0], back[5]));
    // the level (design §2.1, §3.5): 1 at exactly 1 with the scan at 0
    // (bufPos 1 is the span's last start and sounds), 0 once bufPos + the
    // phase is past 1 forward or below 0 backward
    edge = run.([\scanMode, 2, \bufScan, 0, \bufPos, 1], 0.2);
    past = run.([\scanMode, 2, \bufScan, 1, \bufPos, 1], 0.2);
    inside = run.([\scanMode, 2, \bufScan, 0, \bufPos, 0.5], 0.2);
    check.((edge[6] > 0.999) and: { edge[7] > 0.999 } and: { past[6] < 1e-3 } and: { inside[6] > 0.999 }
        and: { held[6] < 1e-3 } and: { back[6] < 1e-3 },
        "positions: one shot sounds at exactly 1 with the scan at 0 and is silent past 1, or below 0 (levels at 1 % (lowest %), just past 1 %, at 0.5 %, at 1.5 %, at -0.5 %)"
            .format(edge[6], edge[7], past[6], inside[6], held[6], back[6]));
    // a backward one shot from bufPos 1 (a reverse slice) starts at the
    // edge: its first grains play at full level, never faded in
    opening = run.([\scanMode, 2, \bufScan, -1, \bufPos, 1], 0.1);
    check.((opening[7] > 0.999) and: { opening[6] > 0.999 },
        "positions: a backward one shot from bufPos 1 opens at full level, with no fade-in (lowest level since its start %, now %)"
            .format(opening[7], opening[6]));
    out.free; out = Bus.control(server, 2);
};
checkScanModes.value;

// The one-shot level is a 5 ms gate on the reader's level, built at control
// rate (one A2K of the sum), so the reader's level stays a control-rate
// product and costs no audio-rate wire buffers
{
    var levelRate;
    SynthDef(\strataCheckOneShotLevelRate, {
        var state = scanState.(\scanMode.kr(2));
        state[\sum] = DC.ar(0.5) + Sweep.ar(0, 0.1);
        levelRate = engine.oneShotLevel(state).rate;
        Out.kr(0, DC.kr(0));
    });
    check.(levelRate == \control, "positions: the one-shot level is built at control rate (got %)".format(levelRate));
}.value;

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
levelBus = Bus.control(server, 1);
levelProbe = Synth.before(engine.synths[engine.voiceMixKey(voice)], \strataCheckScanLevel,
    [\in, engine.voicePathBus(voice, 1).index, \peaks, levelBus.index]);
server.sync;
level = { readBus.(levelBus)[0] };
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
// (3.7: a speed of 1 crosses the 2 s slot in 2 s, as 3.6's 0.5 loops a second did)
setGrain.(\bufScan, 1);
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

// 3.7 (design §2.1, §2.2, §2.4, §3.4): the real grain synth on the 2 s slot.
// [synths, groups] of the server (one /status reply)
nodeCount = {
    var condition = Condition(false), reply;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/status.reply', server.addr).oneShot;
    server.sendMsg('/status');
    h.awaitReply(condition);
    reply !? { [reply[3], reply[4]] }
};
// the lines the engine posts for ignored commands, through the modulation
// area's postIgnored hook, given back however body ends
withIgnoredLines = { arg lines, body;
    var modulation = engine.areaState[\modulation], previous = modulation[\postIgnored];
    modulation[\postIgnored] = { arg line; lines.add(line) };
    body.protect({ modulation[\postIgnored] = previous });
};

// One shot over a loop of 1 s (0/0.5 of the slot) at a scan of 1: sound
// until the sum leaves the loop at 1 s, then silence; the same backward from 1
checkOneShot = {
    var results = [[0, 1], [1, -1]].collect({ arg start;
        var early, late;
        setGrain.(\loopStart, 0, \loopLength, 0.5, \scanMode, 2, \bufPos, start[0], \bufScan, start[1]);
        command.(\setGrainParam, voice, \t_scanReset, 1);
        0.6.wait;
        early = level.value;
        0.7.wait;
        late = level.value;
        [early, late]
    });
    setGrain.(\scanMode, 0, \bufScan, 0, \bufPos, 0, \loopLength, 1);
    0.1.wait;
    check.(results.every({ arg each; (each[0] > 0.01) and: { each[1] < 1e-4 } }) and: { level.value > 0.01 },
        "positions: one shot holds at the edge and is silent past it, forward and backward (levels at 0.6 s and 1.3 s: forward %, backward %; wrap again %)"
            .format(results[0], results[1], level.value));
};

// A retrigger restarts a one-shot voice's scan (positions' voiceHit hook) and
// leaves a wrapping one's: over a 1 s loop at a scan of 1, 0.6 s in
checkRetriggerRestart = {
    var results = [2, 0].collect({ arg mode;
        var moved, after;
        setGrain.(\loopStart, 0, \loopLength, 0.5, \scanMode, mode, \bufPos, 0, \bufScan, 1);
        command.(\setGrainParam, voice, \t_scanReset, 1);
        0.6.wait;
        moved = position.value;
        command.(\retrigger, voice, 1.0);
        0.06.wait;
        after = position.value;
        [moved, after]
    });
    setGrain.(\scanMode, 0, \bufScan, 0, \loopLength, 1);
    check.((results[0][0] > 0.2) and: { results[0][1] < 0.1 } and: { results[1][0] > 0.2 } and: { results[1][1] > 0.25 },
        "positions: a retrigger restarts a one-shot voice's scan and not a wrapping one's (one shot: % then %; wrap: % then %)"
            .format(results[0][0], results[0][1], results[1][0], results[1][1]));
};

// A scan of 1 is the audio's own speed: over the 2 s loop and over a region of
// 0.5 s (0.25/0.25) the grains move 0.5 of the slot a second, so each is
// crossed in its own length
checkSpeed = {
    var whole, region;
    setGrain.(\loopStart, 0, \loopLength, 1, \scanMode, 0, \bufPos, 0, \bufScan, 1);
    command.(\setGrainParam, voice, \t_scanReset, 1);
    0.1.wait;
    before = reading.value;
    0.8.wait;
    after = reading.value;
    whole = slope.(before, after);
    setGrain.(\regionStart, 0.25, \regionLength, 0.25);
    0.03.wait;
    before = reading.value;
    0.3.wait;
    after = reading.value;
    region = slope.(before, after);
    setGrain.(\regionStart, 0, \regionLength, 0, \bufScan, 0);
    check.(whole.inclusivelyBetween(0.4, 0.6) and: { region.inclusivelyBetween(0.4, 0.6) },
        "positions: a scan of 1 crosses a 2 s region in 2 s, and a 0.5 s region in 0.5 s (% s and % s: slopes % and % of the slot a second)"
            .format((1 / whole.max(0.001)).round(0.01), (0.25 / region.max(0.001)).round(0.01), whole, region));
};

// syncScan sets the own grain synth's phase: 0.5 is half the loop, 1.25
// wraps to 0.25 in wrap, 1.5 folds to 0.5 in bounce; no node is made, the
// sync is never stored, scanSyncPhase is the engine's own, and a bad
// command is ignored with one line
checkSyncScan = {
    var nodes = nodeCount.value, places = List.new, lines = List.new, received, refused, kept;
    setGrain.(\loopStart, 0, \loopLength, 1, \scanMode, 0, \bufPos, 0, \bufScan, 0);
    [[0, 0.5], [0, 1.25], [1, 1.5]].do({ arg sync;
        setGrain.(\scanMode, sync[0]);
        command.(\syncScan, voice, sync[1]);
        0.08.wait;
        places.add(position.value);
    });
    command.(\syncScan, voice, 3.0);
    received = engine.areaState[\positions][\received][\syncScan].copy;
    kept = received;
    withIgnoredLines.(lines, {
        [[\syncScan, 7, 0.5], [\syncScan, -1, 0.5], [\syncScan, voice, 0.0 / 0.0], [\syncScan, voice, inf]].do({ arg call;
            command.(*call)
        });
    });
    command.(\setGrainParam, voice, \scanSyncPhase, 0.75);
    refused = engine.grainControls[voice][\scanSyncPhase].isNil and: { engine.grainControls[voice][\t_scanSync].isNil };
    setGrain.(\scanMode, 0);
    check.(places[0].inclusivelyBetween(0.44, 0.53) and: { places[1].inclusivelyBetween(0.2, 0.3) }
        and: { places[2].inclusivelyBetween(0.44, 0.53) } and: { nodeCount.value == nodes } and: { refused }
        and: { received == [voice, 2.0] } and: { engine.areaState[\positions][\received][\syncScan] == kept }
        and: { lines.size == 4 } and: { lines.every({ arg line; line.beginsWith("strata: syncScan ignored: ") }) },
        "positions: syncScan sets the own note's phase, wraps it in wrap, and makes no node (at 0.5, 1.25 and bounce 1.5: %; nodes % then %; refused %; received %; lines %)"
            .format(places.asArray, nodes, nodeCount.value, refused, received, lines.asArray));
};

// syncScan's other cases: one shot ignores it (its phase is the Sweep,
// which only a restart moves); a voice whose own grain synth is a ring's
// (\strataGrainRing, the synth source) and a stopped voice get no message
// at all, though the command still records what it took
checkSyncScanEdges = {
    var held, ringVoice = 0, stoppedVoice = 6, ringBundle, stoppedBundle, ringDef, received = List.new;
    setGrain.(\loopStart, 0, \loopLength, 1, \scanMode, 2, \bufPos, 0.2, \bufScan, 0);
    command.(\setGrainParam, voice, \t_scanReset, 1);
    0.1.wait;
    command.(\syncScan, voice, 0.75);
    0.08.wait;
    held = position.value;
    setGrain.(\scanMode, 0, \bufPos, 0);
    command.(\setGrainSource, ringVoice, 0);
    command.(\voiceOn, ringVoice, 200.0, 0.5, 0.0, 0.04, 200.0, 1.0);
    server.sync;
    ringDef = engine.synths[engine.grainKey(ringVoice)] !? { arg synth; synth.defName.asSymbol };
    ringBundle = server.makeBundle(false, { command.(\syncScan, ringVoice, 0.5) });
    received.add(engine.areaState[\positions][\received][\syncScan].copy);
    stoppedBundle = server.makeBundle(false, { command.(\syncScan, stoppedVoice, 0.5) });
    received.add(engine.areaState[\positions][\received][\syncScan].copy);
    command.(\voiceOff, ringVoice);
    server.sync;
    check.(held.inclusivelyBetween(0.15, 0.28) and: { ringDef == \strataGrainRing } and: { ringBundle.isEmpty }
        and: { engine.voiceRunning(stoppedVoice).not } and: { stoppedBundle.isEmpty }
        and: { received.asArray == [[ringVoice, 0.5], [stoppedVoice, 0.5]] },
        "positions: syncScan leaves a one-shot scan where it is and sends nothing to a ring voice or a stopped one (one shot at 0.2 after a sync to 0.75: %; the ring voice's grain def %, sent %; the stopped voice's sent %; received %)"
            .format(held, ringDef, ringBundle, stoppedBundle, received.asArray));
};

// regionLength (with regionStart before it) restarts the own grain synth's
// scan in the region's place; an extra note's region is its own, so it gets
// neither the region nor the restart
checkRegionRestart = {
    var bundle, note, noteSent, own;
    setGrain.(\loopStart, 0, \loopLength, 1, \scanMode, 0, \bufPos, 0, \bufScan, 1);
    command.(\setGrainParam, voice, \t_scanReset, 1);
    0.9.wait;
    command.(\setGrainParam, voice, \regionStart, 0.5);
    command.(\setGrainParam, voice, \regionLength, 0.25);
    0.06.wait;
    own = position.value;
    setGrain.(\regionStart, 0, \regionLength, 0, \bufScan, 0);
    command.(\setNotePool, 2);
    command.(\noteExpression, voice, 1, 1.0, 1.0, 0.0, 0.0, 0.0);
    command.(\noteOn, voice, 1, 60.0, 220.0, 1.0, 1.0);
    server.sync;
    note = engine.noteRecord(voice, 1)[\synth];
    bundle = server.makeBundle(false, {
        command.(\setGrainParam, voice, \regionStart, 0.5);
        command.(\setGrainParam, voice, \regionLength, 0.25);
    });
    server.sendBundle(nil, *bundle);
    server.sync;
    noteSent = bundle.select({ arg msg; note.notNil and: { msg[1] == note.nodeID } });
    check.(own.inclusivelyBetween(0.5, 0.58) and: { note.notNil } and: { noteSent.isEmpty }
        and: { h.getControl(note, \regionLength) == 0 } and: { h.getControl(note, \regionStart) == 0 }
        and: { engine.grainControls[voice][\regionLength] == 0.25 },
        "positions: regionLength restarts the own note's scan and no extra note's (own at % after the region 0.5/0.25; sent to the note %; the note's region %)"
            .format(own, noteSent, [h.getControl(note, \regionStart), h.getControl(note, \regionLength)]));
    command.(\noteOff, voice, 1, 1);
    command.(\setNotePool, 0);
    setGrain.(\regionStart, 0, \regionLength, 0);
};

// Each 3.7 scan control reaches a UGen of the buffer grain synth, and both
// grain defs declare it at the default that plays 3.6's graph: wrap, no
// region, follow rate 1, gain 1, no sync
checkScanControls = {
    var defaults = [[\scanMode, 0], [\regionStart, 0], [\regionLength, 0], [\followRate, 1], [\slotGain, 1],
        [\t_scanSync, 0], [\scanSyncPhase, 0]];
    var defaultOf = { arg defName, name;
        SynthDescLib.global.at(defName).controls.detect({ arg each; each.name == name }) !? { arg control; control.defaultValue } };
    var feeds = defaults.reject({ arg pair; h.controlFeedsAUGen(\strataGrainBuf, pair[0]) }).collect(_[0]);
    var wrong = h.grainDefs.collect({ arg defName; defaults.reject({ arg pair; defaultOf.(defName, pair[0]) == pair[1] }).collect(_[0]) });
    check.(feeds.isEmpty and: { wrong.every(_.isEmpty) },
        "positions: the new scan controls feed a UGen and default to 3.6's graph (feeding none: %; not at the default: %)"
            .format(feeds, wrong));
};

// (the switch check above left the voice on the empty otherSlot: back to the
// slot of known contents, whose new grain synth the probes still hear)
command.(\setGrainSource, voice, slot + 1);
server.sync;
0.2.wait;
checkOneShot.value;
checkRetriggerRestart.value;
checkSpeed.value;
checkSyncScan.value;
checkSyncScanEdges.value;
checkRegionRestart.value;
checkScanControls.value;

probe.free; levelProbe.free; levelBus.free;
command.(\voiceOff, voice);
h.stopAllVoices;
command.(\setGrainSource, voice, 0);
command.(\clearBuffer, slot);
engine.grainControls[voice] = saved;
server.sync;
out.free; posBus.free;
File.delete(path);
}
