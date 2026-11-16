// test/engine_check/envelopes.scd
// The envelopes area (lib/engine/StrataEnvelopes.sc, 3.7, design §7.3): its
// order, its two commands (their signatures, their checks and clips), the
// envelope nodes in fastModGroup (at most one per route at every moment, a
// releasing one included, and none made by a hit), the hits that fire a
// route (its source voice's retrigger, start and extra note, no other
// voice's), the shape on the channel a route writes (the hold a gated
// voice's gateSeconds, none for an ungated voice, sustain 0 an attack and
// decay, a hit from the level it is at, loop, depth, two routes adding),
// and the zeroing of a channel no route writes any more. See
// docs/notes/engine/envelopes.md.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var area = engine.strataAreas.detect({ arg each; each[\name] == \envelopes });
var state = engine.areaState[\envelopes], modulation = engine.areaState[\modulation];
// every voice's grain controls as the area found them (it puts them back)
var foundControls = engine.grainControls.collect(_.copy);
var ignoredLines = List.new;
var routes = 16;
var nodeCounts, groupNodes, envNodes, channel, channelBus, readChannel, readAll, placeSynth, setEnv;
var resetEnvelopes, withOffsetsPaused, tracker, sampleHit, gateVoice, restoreVoices;
var checkState, checkCommands, checkPlaces, checkHits, checkShape, checkUngated, checkSustainZero, checkFromLevel;
var checkLoop, checkDepth, checkSeries, checkZeroing, checkIgnored, checkLeft;

// [synths, groups] on the server, from one /status reply
nodeCounts = {
    var condition = Condition(false), reply;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/status.reply', server.addr).oneShot;
    server.sendMsg('/status');
    h.awaitReply(condition);
    reply !? { [reply[3], reply[4]] }
};
// fastModGroup's synths (id, def, controls); its envelope nodes
groupNodes = { modulation[\fastModGroup] !? { arg group; h.synthTree(group) } ? [] };
envNodes = { groupNodes.value.select({ arg node; node[\def] == \strataEnvelope }) };
// A fast-modulation channel's index, as a one-channel Bus (no allocation), and its value
channel = { arg voice, destination; engine.fastModChannel(voice, 0, destination) };
channelBus = { arg voice, destination; Bus.new(\control, channel.(voice, destination), 1, server) };
readChannel = { arg voice, destination; h.readBusValue(channelBus.(voice, destination)) };
readAll = { h.readBus(modulation[\fastModBus]) };
// The node a route's place holds (nil without one)
placeSynth = { arg route; state[\routes] !? { arg places; places[route] !? { arg place; place[\synth] } } };
// setFastEnv with the shape's defaults for what is not given
setEnv = { arg route, source, voice, destination, depth = 1.0, attack = 0.05, decay = 0.05, sustain = 0.5, release = 0.05,
    curve = -4.0, loop = 0;
    command.(\setFastEnv, route, source, voice, destination, depth, attack, decay, sustain, release, curve, loop);
};
// Every route stopped and its release over (each check starts from this)
resetEnvelopes = {
    routes.do({ arg route; command.(\stopFastEnv, route) });
    server.sync; 0.15.wait; server.sync;
};
// body run with the offset node paused (it writes every channel first in
// every block, so a channel no other node writes holds its last value only
// while it is paused); it runs again however body ends
withOffsetsPaused = { arg body;
    var node = engine.synths[\fastOffsets];
    if (node.notNil) { server.sendMsg('/n_run', node.nodeID, 0) };
    server.sync;
    body.protect({ if (node.notNil) { server.sendMsg('/n_run', node.nodeID, 1) } });
};
// A check-only tracker right after fastModGroup (so it reads what the
// group's nodes wrote in the same block), on a voice's channel: [the
// synth, the control bus it writes]
tracker = { arg def, voice, destination, size = 1, args;
    var bus = Bus.control(server, size);
    bus.setAll(0);
    [Synth(def, [\in, channel.(voice, destination), \out, bus] ++ (args ? []), modulation[\fastModGroup], \addAfter), bus]
};
// A hit on source (retrigger; voice unless given) 0.1 s from now, and the
// values of voice's destination channel at times (s) after it, read by a
// sampler started in the hit's bundle
sampleHit = { arg voice, destination, times, source;
    var sampler = tracker.(\strataCheckEnvSampler, voice, destination, 8, [\times, times ++ (0 ! (8 - times.size))]), values;
    server.sync;
    server.makeBundle(0.1, { command.(\retrigger, source ? voice, 1.0); sampler[0].set(\t_start, 1) });
    (0.15 + times.maxItem).wait; server.sync;
    values = h.readBus(sampler[1]).keep(times.size);
    sampler[0].free; sampler[1].free;
    values
};
// A voice's step gate as Lua sends it (setGrainParam: kept in grainControls)
gateVoice = { arg voice, seqGate, gateSeconds;
    command.(\setGrainParam, voice, \seqGate, seqGate);
    command.(\setGrainParam, voice, \gateSeconds, gateSeconds);
};
// Every voice's gate back at the stage's defaults and its grain controls as found
restoreVoices = {
    engine.numVoices.do({ arg voice;
        if (engine.grainControls[voice] != foundControls[voice]) {
            command.(\setGrainParam, voice, \seqGate, 0);
            command.(\setGrainParam, voice, \gateSeconds, 0.1);
            engine.grainControls[voice] = foundControls[voice].copy;
        };
    });
    server.sync;
};

// The check's own SynthDefs: a sampler that latches its input at up to
// eight times after t_start; a peak of the input's magnitude since
// t_reset; and a count of its rises past 0.5 in the window (s) from
// t_reset (timed on the server: sclang's waits stretch on a loaded machine)
SynthDef(\strataCheckEnvSampler, { arg in, out, t_start = 0;
    var elapsed = Sweep.kr(t_start, 1), value = In.kr(in, 1);
    Out.kr(out, \times.kr(0 ! 8).collect({ arg time; Latch.kr(value, elapsed >= time) }));
}).add;
SynthDef(\strataCheckEnvPeak, { arg in, out, t_reset = 0;
    Out.kr(out, RunningMax.kr(In.kr(in, 1).abs, t_reset));
}).add;
SynthDef(\strataCheckEnvCount, { arg in, out, t_reset = 0, window = 0.5;
    var open = Sweep.kr(t_reset, 1) < window;
    Out.kr(out, PulseCount.kr((In.kr(in, 1) > 0.5) * open, t_reset));
}).add;
server.sync;

// The area's order, its state at the start, and its numbers
checkState = {
    check.((area[\order] == 190) and: { engine.numEnvRoutes == routes } and: { state[\routes].size == routes }
        and: { state[\routes].every(_.isNil) } and: { state[\stopped] == false } and: { envNodes.value.isEmpty },
        "envelopes: the area runs at order 190 with sixteen empty routes and no node (order %, numEnvRoutes %, routes %, nodes %)".format(
            area[\order], engine.numEnvRoutes, state[\routes] !? { arg places; places.count(_.notNil) }, envNodes.value.size));
};

// The two commands' signatures, and what each records (the continuous
// arguments clipped: depth -2 to 2, the times 0.001 to 10, sustain 0 to 1,
// curve -8 to 8)
checkCommands = {
    var signatures = [[\setFastEnv, "iiiiffffffi"], [\stopFastEnv, "i"]];
    var calls = [
        [[\setFastEnv, 0, 0, 0, 0, 1.0, 0.005, 0.2, 0.0, 0.2, -4.0, 0], [0, 0, 0, 0, 1.0, 0.005, 0.2, 0.0, 0.2, -4.0, 0]],
        [[\setFastEnv, 15, 6, 6, 4, 2.0, 10.0, 10.0, 1.0, 10.0, 8.0, 1], [15, 6, 6, 4, 2.0, 10.0, 10.0, 1.0, 10.0, 8.0, 1]],
        [[\setFastEnv, 3, 2, 1, 2, -2.5, 0.0, 20.0, -0.5, 0.0001, -9.0, 0], [3, 2, 1, 2, -2.0, 0.001, 10.0, 0.0, 0.001, -8.0, 0]],
        [[\setFastEnv, 4, 5, 3, 1, 3.0, 11.0, -1.0, 1.5, 12.0, 9.5, 1], [4, 5, 3, 1, 2.0, 10.0, 0.001, 1.0, 10.0, 8.0, 1]],
        [[\stopFastEnv, 0], [0]],
        [[\stopFastEnv, 15], [15]]
    ];
    var recorded = calls.collect({ arg call;
        command.(*call[0]);
        state[\received][call[0][0]] == call[1]
    });
    check.(signatures.every({ arg pair; h.formatOf(pair[0]) == pair[1] }),
        "envelopes: the two commands exist with their signatures (got %)".format(signatures.collect({ arg pair; h.formatOf(pair[0]) })));
    check.(recorded.every(_ == true),
        "envelopes: each command records its arguments, the continuous ones clipped (wrong: %)".format(
            calls.select({ arg call, index; recorded[index].not }).collect({ arg call; [call[0], state[\received][call[0][0]]] })));
    resetEnvelopes.value;
};

// Every command's node is in fastModGroup, and a hit (retrigger, on a
// running voice and a stopped one, with routes on both) makes none at all
checkPlaces = {
    var outside = { var counts = nodeCounts.value; counts !? { [counts[0] - groupNodes.value.size, counts[1]] } };
    var before = outside.value, counts = List.new, all, after;
    [
        { setEnv.(0, 1, 0, 0) }, { setEnv.(1, 1, 2, 3, 0.5) }, { setEnv.(2, 3, 2, 3, -1.0, loop: 1) },
        { setEnv.(1, 1, 4, 4) }, { command.(\stopFastEnv, 0) }, { setEnv.(0, 1, 0, 1) }, { command.(\stopFastEnv, 2) }
    ].do({ arg step;
        step.value;
        server.sync;
        counts.add(outside.value);
    });
    command.(\setGrainSource, 1, 0);
    command.(\voiceOn, 1, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.1.wait; server.sync;
    all = nodeCounts.value;
    20.do({ arg index; command.(\retrigger, [1, 3][index % 2], 1.0) });
    server.sync;
    after = nodeCounts.value;
    check.(before.notNil and: { counts.every({ arg each; each == before }) } and: { all.notNil } and: { after == all },
        "envelopes: no command and no hit makes a node outside fastModGroup, and a hit makes none at all (synths and groups outside it before %, after each command %; every node before twenty hits %, after %)".format(
            before, counts.asSet.asArray, all, after));
    command.(\voiceOff, 1);
    h.stopAllVoices;
    resetEnvelopes.value;
};

// Each kind of hit fires every route of its source voice and no other
// voice's: routes 0 and 1 on voice 2's hits, route 2 on voice 3's, each on
// a channel of its own, read by a peak tracker reset before each hit. A
// running voice's voiceOn is no hit
checkHits = {
    var trackers = [[0, 0], [5, 3], [2, 2]].collect({ arg pair; tracker.(\strataCheckEnvPeak, *pair) });
    var expected = [[1, 1, 0], [1, 1, 0], [1, 1, 0], [0, 0, 0], [0, 0, 1]], results;
    var fire = { arg action;
        trackers.do({ arg each; each[0].set(\t_reset, 1) });
        server.sync;
        action.value;
        server.sync; 0.2.wait; server.sync;
        trackers.collect({ arg each; h.readBusValue(each[1]) })
    };
    setEnv.(0, 2, 0, 0, attack: 0.01, decay: 0.01);
    setEnv.(1, 2, 5, 3, attack: 0.01, decay: 0.01);
    setEnv.(2, 3, 2, 2, attack: 0.01, decay: 0.01);
    command.(\setGrainSource, 2, 0);
    command.(\setNotePool, 2);
    server.sync; 0.05.wait;
    results = [
        // retrigger of a stopped voice
        fire.({ command.(\retrigger, 2, 1.0) }),
        // a start
        fire.({ command.(\voiceOn, 2, 220.0, 0.2, 0.0, 0.1, 20.0, 1.0) }),
        // an extra note that sounds
        fire.({ command.(\noteExpression, 2, 1, 1.0, 1.0, 0.0, 0.0, 0.0); command.(\noteOn, 2, 1, 64.0, 330.0, 1.0, 1.0) }),
        // a running voice's voiceOn: no hit
        fire.({ command.(\voiceOn, 2, 220.0, 0.2, 0.0, 0.1, 20.0, 1.0) }),
        // another voice's retrigger
        fire.({ command.(\retrigger, 3, 1.0) })
    ];
    check.([results, expected].flop.every({ arg pair; [pair[0], pair[1]].flop.every({ arg each;
            if (each[1] == 1) { each[0] > 0.9 } { each[0] < 1e-6 } }) }),
        "envelopes: a hit fires every route of its source voice and no other voice's (peaks on routes 0 and 1, voice 2's, and route 2, voice 3's: retrigger %, a start %, an extra note %, a running voice's voiceOn %, voice 3's retrigger %)".format(
            *results.collect({ arg each; each.round(0.001) })));
    command.(\noteOff, 2, 1, 1);
    command.(\voiceOff, 2);
    command.(\setNotePool, 0);
    trackers.do({ arg each; each[0].free; each[1].free });
    h.stopAllVoices;
    resetEnvelopes.value;
};

// The shape (design §7.1) on a gated voice with gateSeconds 0.2: attack
// 0.05 s to 1, decay 0.05 s to the sustain 0.5, held for the hold
// (gateSeconds), released over 0.05 s. The peak is read at 0.048 s: the
// attack lasts 37 control blocks (0.0493 s), and one block into the
// decay (curve -4) it has already fallen to about 0.95. A curve -4 attack
// is near 1 well before its end, so a linear one (curve 0, 0.1 s) pins
// the timing: a quarter, half and three quarters of the way, within 0.03
// (3 ms)
checkShape = {
    var times = [0.048, 0.12, 0.28, 0.4], expected = [1, 0.5, 0.5, 0], values;
    var linearTimes = [0.025, 0.05, 0.075], linearExpected = [0.25, 0.5, 0.75], linear;
    gateVoice.(4, 1, 0.2);
    setEnv.(0, 4, 4, 1);
    server.sync; 0.05.wait;
    values = sampleHit.(4, 1, times);
    resetEnvelopes.value;
    setEnv.(0, 4, 4, 1, attack: 0.1, curve: 0.0);
    server.sync; 0.05.wait;
    linear = sampleHit.(4, 1, linearTimes);
    check.((values.size == 4) and: { [values, expected].flop.keep(3).every({ arg pair; (pair[0] - pair[1]).abs < 0.05 }) }
        and: { values[3].abs < 1e-3 }
        and: { (linear.size == 3) and: { [linear, linearExpected].flop.every({ arg pair; (pair[0] - pair[1]).abs < 0.03 }) } },
        "envelopes: the shape: attack 0.05, decay 0.05, sustain 0.5, release 0.05, depth 1, a gated voice with gateSeconds 0.2: the channel reads 1 (within 0.05) at % s (the attack's last block), 0.5 at % s and at % s, and 0 by % s (got %); a linear attack of 0.1 s reads % (within 0.03) at % s (got %)".format(
            times[0], times[1], times[2], times[3], values.round(0.001), linearExpected, linearTimes, linear.round(0.001)));
    restoreVoices.value;
    resetEnvelopes.value;
};

// A voice that is not gated holds nothing, whatever its gateSeconds: the
// release follows the decay at once. Voice 6 has never had a seqGate (nil
// until Lua sends one), and one with seqGate 0 sent is the same
checkUngated = {
    var never = engine.grainControls[6][\seqGate].isNil, times = [0.048, 0.12, 0.2], values, sent;
    command.(\setGrainParam, 6, \gateSeconds, 0.3);
    setEnv.(0, 6, 6, 2);
    server.sync; 0.05.wait;
    values = sampleHit.(6, 2, times);
    gateVoice.(6, 0, 0.3);
    server.sync;
    sent = sampleHit.(6, 2, times);
    check.(never and: { [values, sent].every({ arg each; (each.size == 3) and: { (each[0] - 1).abs < 0.05 } and: { each[1] < 0.3 }
        and: { each[2].abs < 1e-3 } }) },
        "envelopes: an ungated voice's hold is 0 (the release follows the decay at once; gateSeconds 0.3, no seqGate yet: %; at % s: % with no seqGate, % with seqGate 0)".format(
            never, times, values.round(0.001), sent.round(0.001)));
    restoreVoices.value;
    resetEnvelopes.value;
};

// Sustain 0 is an attack and a decay, whatever the hold: a gated voice with
// gateSeconds 0.3 reads 0 from the decay's end, through what would be its hold
checkSustainZero = {
    var times = [0.048, 0.12, 0.2, 0.35], values;
    gateVoice.(4, 1, 0.3);
    setEnv.(0, 4, 4, 3, sustain: 0.0);
    server.sync; 0.05.wait;
    values = sampleHit.(4, 3, times);
    check.((values.size == 4) and: { (values[0] - 1).abs < 0.05 } and: { values.drop(1).every({ arg value; value.abs < 1e-3 }) },
        "envelopes: sustain 0 is attack and decay whatever the hold (gateSeconds 0.3; at % s: %)".format(
            times, values.round(0.001)));
    restoreVoices.value;
    resetEnvelopes.value;
};

// A hit in the middle of the release (linear: curve 0) starts the attack
// from the level it has reached, 0.25 at 0.2 s, with no drop to 0 first:
// sampled from the second hit to the attack's end, every value is at least
// that level and none is below the one before, and the attack reaches 1
checkFromLevel = {
    var times = [0.19, 0.2, 0.2014, 0.2027, 0.205, 0.21, 0.23, 0.25], values, rising;
    var sampler = tracker.(\strataCheckEnvSampler, 6, 0, 8, [\times, times]);
    setEnv.(0, 6, 6, 0, attack: 0.05, decay: 0.05, sustain: 0.5, release: 0.2, curve: 0.0);
    server.sync; 0.05.wait;
    server.makeBundle(0.1, { command.(\retrigger, 6, 1.0); sampler[0].set(\t_start, 1) });
    server.makeBundle(0.3, { command.(\retrigger, 6, 1.0) });
    0.5.wait; server.sync;
    values = h.readBus(sampler[1]);
    rising = (2 .. (values.size - 1)).every({ arg index; values[index] >= (values[index - 1] - 1e-4) });
    check.((values.size == 8) and: { (values[0] - 0.275).abs < 0.03 } and: { values.drop(1).every({ arg value; value > 0.2 }) }
        and: { rising } and: { (values.last - 1).abs < 0.05 },
        "envelopes: a hit during the release starts the attack from the level it is at (no drop to 0 first: at %, s after the first hit, %; the second hit at 0.2 s)".format(
            times, values.round(0.001)));
    sampler[0].free; sampler[1].free;
    resetEnvelopes.value;
};

// Loop on: the envelope starts again each time it ends, with no hit and its
// voice stopped (0.04 s of attack and decay and three blocks a cycle:
// about 11 in 0.5 s, counted in a window the server times);
// with loop off it never starts without a hit, and a route that never ran
// starts once its loop is set
checkLoop = {
    var looped = tracker.(\strataCheckEnvCount, 5, 4), still = tracker.(\strataCheckEnvCount, 5, 3), counts, later;
    setEnv.(0, 5, 5, 4, attack: 0.02, decay: 0.02, sustain: 0.0, release: 0.02, loop: 1);
    setEnv.(1, 5, 5, 3, attack: 0.02, decay: 0.02, sustain: 0.0, release: 0.02, loop: 0);
    server.sync; 0.05.wait;
    [looped, still].do({ arg each; each[0].set(\t_reset, 1) });
    0.6.wait; server.sync;
    counts = [looped, still].collect({ arg each; h.readBusValue(each[1]) });
    server.makeBundle(nil, {
        setEnv.(1, 5, 5, 3, attack: 0.02, decay: 0.02, sustain: 0.0, release: 0.02, loop: 1);
        still[0].set(\t_reset, 1, \window, 0.3);
    });
    server.sync; 0.4.wait; server.sync;
    later = h.readBusValue(still[1]);
    check.((engine.voiceRunning(5).not) and: { counts[0] >= 9 } and: { counts[0] <= 13 } and: { counts[1] == 0 } and: { later >= 4 },
        "envelopes: loop starts again at the end with no hit (cycles in 0.5 s: % with loop on, of about 11, % with it off; % in 0.3 s once a route that never ran is set to loop)".format(
            counts[0], counts[1], later));
    [looped, still].do({ arg each; each[0].free; each[1].free });
    resetEnvelopes.value;
};

// Depth is the peak's: -2 reads -2; and two routes on one channel add
// (depths 0.3 and 0.2, sustain 1, a gated voice: 0.5 while both hold)
checkDepth = {
    var peak, both;
    setEnv.(0, 1, 3, 0, -2.0);
    server.sync; 0.05.wait;
    peak = sampleHit.(3, 0, [0.048], 1);
    resetEnvelopes.value;
    gateVoice.(1, 1, 0.5);
    setEnv.(1, 1, 3, 2, 0.3, 0.01, 0.01, 1.0);
    setEnv.(2, 1, 3, 2, 0.2, 0.01, 0.01, 1.0);
    server.sync; 0.05.wait;
    both = sampleHit.(3, 2, [0.1], 1);
    check.((peak.size == 1) and: { (peak[0] + 2).abs < 0.1 } and: { both.size == 1 } and: { (both[0] - 0.5).abs < 0.01 },
        "envelopes: depth -2 reads -2 at the peak, and two routes on one channel add (the peak %; 0.3 and 0.2 together %)".format(
            peak.round(0.001), both.round(0.001)));
    restoreVoices.value;
    resetEnvelopes.value;
};

// The series (design §7.3, as modulation's for the LFOs): starts, moves,
// shape sets, stops and stops re-set in the same tick, of the sixteen
// routes at 20 Hz for 2 s (seeded), with a hit on a random voice at every
// step. One tree read a step, asked for in the step's tick with no sync
// between: every envelope node on the server is its route's place's node,
// so at most one per route, a releasing one included; each running route
// has exactly one, writing its channel; each route stopped in the step
// before, 50 ms earlier, past its 20 ms release, has none and no place. A
// stop and the set after it in one tick can reach the server in two of its
// callbacks, the release ending before the re-gate (modulation's #677):
// the engine starts the route again when the node's end reaches sclang,
// and such a step waits for that (at most 0.5 s) and reads again
checkSeries = {
    var steps = 40, period = 0.05, wrong = List.new, maxNodes = 0, maxReleasing = 0, actions = Bag.new;
    var settings = Array.newClear(routes), stoppedBefore = [], t0, final, restarted = 0;
    var placeNodes = { (0 .. routes - 1).collect({ arg route; placeSynth.(route) !? _.nodeID }) };
    var breaks = { arg nodes, own, excused;
        var ids = nodes.collect(_[\id]);
        (ids.asSet.size != ids.size) or: { ids.any({ arg id; own.includes(id).not }) }
            or: { settings.any({ arg each, route;
                var node = nodes.detect({ arg node; node[\id] == own[route] });
                each.notNil and: { excused.includes(route).not }
                    and: { node.isNil or: { node[\controls][\out] != channel.(each[1], each[2]) } } }) }
    };
    var shape = { [exprand(0.001, 0.5), exprand(0.001, 0.5), 1.0.rand, exprand(0.001, 0.5), 8.0.rand2, 2.rand] };
    thisThread.randSeed = 3701;
    t0 = Main.elapsedTime;
    steps.do({ arg step;
        var stopped = List.new, regated = List.new, own, releasing, nodes, ids, ended;
        ((t0 + (period * step)) - Main.elapsedTime).max(0).wait;
        routes.do({ arg route;
            var action = [\start, \move, \set, \stop, \restart, \none].wchoose([0.25, 0.15, 0.15, 0.2, 0.15, 0.1].normalizeSum);
            var current = settings[route];
            if (current.isNil and: { [\move, \set, \restart].includes(action) }) { action = \start };
            actions.add(action);
            switch (action)
            { \start } { current = [7.rand, 7.rand, 5.rand, 4.0.rand2] ++ shape.value }
            { \move } { current = current.copy.put(1, 7.rand).put(2, 5.rand) }
            { \set } { current = current.keep(3) ++ [4.0.rand2] ++ shape.value }
            { \stop } { current = nil; command.(\stopFastEnv, route); stopped.add(route) }
            { \restart } { command.(\stopFastEnv, route); regated.add(route) };
            if (current.notNil and: { action != \none }) { command.(\setFastEnv, route, *current) };
            settings[route] = current;
        });
        command.(\retrigger, 7.rand, 1.0);
        own = placeNodes.value;
        releasing = (0 .. routes - 1).select({ arg route; state[\routes][route] !? { arg place; place[\running].not } ? false })
            .collect({ arg route; own[route] });
        nodes = envNodes.value;
        ids = nodes.collect(_[\id]);
        maxNodes = maxNodes.max(ids.size);
        maxReleasing = maxReleasing.max(ids.count({ arg id; releasing.includes(id) }));
        ended = regated.select({ arg route; ids.includes(own[route]).not });
        if (breaks.(nodes, own, ended)
            or: { stoppedBefore.any({ arg route; settings[route].isNil and: { own[route].notNil } }) }
            or: { ended.notEmpty and: {
                restarted = restarted + ended.size;
                h.waitFor({ ended.every({ arg route; placeSynth.(route) !? { arg synth; synth.nodeID != own[route] } ? false }) }, 0.5).not
                    or: { breaks.(envNodes.value, placeNodes.value, []) } } }) {
            wrong.add([step, ids.size]);
        };
        stoppedBefore = stopped;
    });
    routes.do({ arg route; command.(\stopFastEnv, route) });
    0.1.wait; server.sync;
    final = envNodes.value;
    check.(wrong.isEmpty and: { maxNodes <= routes } and: { maxReleasing > 0 } and: { final.isEmpty }
        and: { state[\routes].every(_.isNil) } and: { state[\nodeChannels].isEmpty } and: { readAll.value.every(_ == 0) },
        "envelopes: one node per route through starts, moves, shape sets and stops at 20 Hz for 2 s, and none once stopped (at each step's commands every envelope node is its route's, a releasing one included, each running route has one on its channel, and each stopped a step before has none: steps wrong %, at most % nodes and % releasing at once, % left, % re-sets that found their node ended and waited for its restart, actions %)".format(
            wrong.keep(4), maxNodes, maxReleasing, final.size, restarted, actions.contents));
    resetEnvelopes.value;
};

// With the offset node paused (so only the routes write the channels): a
// stopped route's channel returns to 0 once no route writes it, keeping
// the other route's value meanwhile, and a moved route zeroes its old
// channel. The routes loop at a value that holds near their depth (a
// 1 ms attack and decay to sustain 1, then a linear 10 s release)
checkZeroing = {
    var holding = { arg route, voice, destination, depth;
        setEnv.(route, 0, voice, destination, depth, 0.001, 0.001, 1.0, 10.0, 0.0, 1);
    };
    var one, none, moved;
    withOffsetsPaused.({
        holding.(0, 2, 3, 0.3);
        holding.(1, 2, 3, 0.2);
        server.sync; 0.1.wait;
        command.(\stopFastEnv, 0);
        server.sync; 0.1.wait;
        one = readChannel.(2, 3);
        command.(\stopFastEnv, 1);
        server.sync; 0.1.wait;
        none = readChannel.(2, 3);
        holding.(2, 2, 1, 0.4);
        server.sync; 0.1.wait;
        holding.(2, 2, 4, 0.4);
        server.sync; 0.1.wait;
        moved = [readChannel.(2, 1), readChannel.(2, 4)];
        command.(\stopFastEnv, 2);
        server.sync; 0.1.wait;
    });
    check.(((one - 0.2).abs < 0.02) and: { none == 0 } and: { moved[0] == 0 } and: { (moved[1] - 0.4).abs < 0.02 },
        "envelopes: a stopped route's channel returns to 0, and a moved route zeroes its old channel (one of two stopped: %, of 0.2; both: %; moved: old % and new %, of 0.4)".format(
            one.round(0.001), none, moved[0], moved[1].round(0.001)));
    resetEnvelopes.value;
};

// Out-of-range indices and every continuous argument's non-finite value
// (NaN passes clip): each posts one line, records nothing, makes no node
// and changes no channel
checkIgnored = {
    var nan = 0.0 / 0.0;
    var env = { arg route, source, voice, destination, loop = 0; [\setFastEnv, route, source, voice, destination, 1.0, 0.05, 0.05, 0.5, 0.05, -4.0, loop] };
    var bad = [
        env.(16, 0, 0, 0), env.(-1, 0, 0, 0), env.(0, 7, 0, 0), env.(0, -1, 0, 0), env.(0, 0, 7, 0), env.(0, 0, -1, 0),
        env.(0, 0, 0, 5), env.(0, 0, 0, -1), env.(0, 0, 0, 0, 2), env.(0, 0, 0, 0, -1), env.(0.5, 0, 0, 0),
        [\stopFastEnv, 16], [\stopFastEnv, -1], [\stopFastEnv, 0.5]
    ] ++ (5 .. 10).collect({ arg index; env.(0, 0, 0, 0).put(index, nan) })
      ++ (5 .. 10).collect({ arg index; env.(0, 0, 0, 0).put(index, [inf, inf.neg][index % 2]) });
    var kept = state[\received].deepCopy, before = nodeCounts.value, lines = List.new, unchanged = List.new;
    modulation[\postIgnored] = { arg line; ignoredLines.add(line) };
    bad.do({ arg call;
        var count = ignoredLines.size;
        command.(*call);
        lines.add(ignoredLines.size - count);
        unchanged.add((state[\received].size == kept.size) and: { kept.keys.every({ arg key; kept[key] == state[\received][key] }) });
    });
    server.sync;
    modulation[\postIgnored] = nil;
    check.(unchanged.every(_ == true) and: { lines.every(_ == 1) } and: { nodeCounts.value == before }
        and: { ignoredLines.every({ arg line; line.beginsWith("strata: ") }) } and: { readAll.value.every(_ == 0) }
        and: { state[\routes].every(_.isNil) },
        "envelopes: out-of-range indices and non-finite values are ignored, one line each, and change no channel (% calls; changed by %; lines %)".format(
            bad.size, bad.select({ arg call, index; unchanged[index].not }), lines.asSet.asArray));
};

// What the area leaves for the areas after it: no route, no node, every
// channel at 0, every voice stopped with the grain controls it found
checkLeft = {
    var running = (0 .. engine.numVoices - 1).select({ arg voice; engine.voiceRunning(voice) });
    var changed = (0 .. engine.numVoices - 1).reject({ arg voice; engine.grainControls[voice] == foundControls[voice] });
    check.(readAll.value.every(_ == 0) and: { envNodes.value.isEmpty } and: { state[\routes].every(_.isNil) }
        and: { running.isEmpty } and: { changed.isEmpty },
        "envelopes: the area leaves every channel at 0 (no route, % nodes; running voices %, grain controls changed on %)".format(
            envNodes.value.size, running, changed));
};

if (area.isNil or: { state.isNil }) {
    check.(false, "envelopes: the area runs at order 190 (no strataAreaEnvelopes)");
} {
    checkState.value;
    checkCommands.value;
    checkIgnored.value;
    checkPlaces.value;
    checkHits.value;
    checkShape.value;
    checkUngated.value;
    checkSustainZero.value;
    checkFromLevel.value;
    checkLoop.value;
    checkDepth.value;
    checkSeries.value;
    checkZeroing.value;
    restoreVoices.value;
    checkLeft.value;
};
}
