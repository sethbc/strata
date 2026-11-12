// test/engine_check/modulation.scd
// The modulation area (lib/engine/StrataModulation.sc), as 3.4's Wave 0
// leaves it: its order, the fast-modulation buses and their addressing
// (fastModChannel, fastModBlock), the five commands as checked stubs that
// create no node and leave every channel at 0, fastModGroup's place before
// voiceGroup, the fastModIn every grain synth and stage starts with, and the
// stage's gate and mute controls, neutral until package 1a fills them.
// See docs/notes/engine/modulation.md.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var area = engine.strataAreas.detect({ arg each; each[\name] == \modulation });
var state = engine.areaState[\modulation];
// the lines the engine posts for the commands it ignores
var ignoredLines = List.new;
// every voice's grain controls as the area found them (it puts them back)
var foundControls = engine.grainControls.collect(_.copy);
var nodeCounts, childrenOf, sameReceived, checkState, checkChannels, checkCommands, checkIgnored, checkBuses;
var checkFastModIn, checkGateControls, checkDefaults, checkFree, checkVoicesLeft;

// [synths, groups] on the server, from one /status reply
nodeCounts = {
    var condition = Condition(false), reply;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/status.reply', server.addr).oneShot;
    server.sendMsg('/status');
    h.awaitReply(condition);
    reply !? { [reply[3], reply[4]] }
};

// A group's own children's node IDs, in order, from one /g_queryTree
childrenOf = { arg group;
    var condition = Condition(false), reply, children = List.new, index = 2, parse;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/g_queryTree.reply', server.addr).oneShot;
    server.sendMsg('/g_queryTree', group.nodeID, 0);
    if (h.awaitReply(condition).not) { reply = [nil, 0, group.nodeID, 0] };
    parse = { arg depth;
        var nodeID = reply[index], numChildren = reply[index + 1];
        index = index + 2;
        if (numChildren == -1) { index = index + 1 } { numChildren.do({ parse.(depth + 1) }) };
        if (depth == 1) { children.add(nodeID) };
    };
    parse.(0);
    children.asArray
};

// Two records of what the commands received, key for key
sameReceived = { arg a, b;
    (a.size == b.size) and: { a.keys.every({ arg key; a[key] == b[key] }) }
};

// The area, its order and its state as alloc leaves it
checkState = {
    check.(area.notNil and: { area[\order] == 160 }, "modulation: the area runs at order 160 (got %)".format(area !? { area[\order] }));
    check.((engine.numFastDestinations == 5) and: { engine.fastModNoteSlots == 1 } and: { engine.numFastLfos == 6 }
        and: { state[\fastModBus].numChannels == 35 } and: { state[\fastModBus].rate == \control }
        and: { state[\silentFastModBus].numChannels == 5 } and: { state[\silentFastModBus].rate == \control }
        and: { state[\silentFastModBus].index != state[\fastModBus].index }
        and: { state[\lfos] == [nil, nil, nil, nil, nil, nil] } and: { state[\scatter].isNil },
        "modulation: the area holds a 35-channel fastModBus, a 5-channel silentFastModBus, six empty LFO places and no scatter (%, %, %)".format(
            state[\fastModBus] !? _.numChannels, state[\silentFastModBus] !? _.numChannels, state[\lfos]));
};

// fastModChannel(v, n, d) = index + (v x slots + n) x 5 + d, through
// fastModChannelFor with this engine's one slot and with six
checkChannels = {
    var index = state[\fastModBus].index;
    var voices = (0 .. engine.numVoices - 1), destinations = (0 .. 4);
    var got = voices.collect({ arg v; destinations.collect({ arg d; engine.fastModChannel(v, 0, d) }) }).flatten;
    var expected = voices.collect({ arg v; destinations.collect({ arg d; index + (5 * v) + d }) }).flatten;
    var blocks = voices.collect({ arg v; engine.fastModBlock(v, 0) });
    var six = voices.collect({ arg v; (0 .. 5).collect({ arg n; destinations.collect({ arg d;
        engine.fastModChannelFor(v, n, d, 6) - index }) }) }).flatten(2);
    var sixExpected = voices.collect({ arg v; (0 .. 5).collect({ arg n; destinations.collect({ arg d;
        (((v * 6) + n) * 5) + d }) }) }).flatten(2);
    check.((got == expected) and: { blocks == voices.collect({ arg v; index + (5 * v) }) }
        and: { (six == sixExpected) and: { six.asSet.size == 210 } and: { six.minItem == 0 } and: { six.maxItem == 209 } },
        "modulation: fastModChannel is index + (v × slots + n) × 5 + d for every voice, slot and destination (one slot: %; six: % distinct, % to %)".format(
            got - index, six.asSet.size, six.minItem, six.maxItem));
};

// The commands' signatures, and the valid calls: none creates a node,
// each is recorded with its continuous arguments clipped
checkCommands = {
    var signatures = [[\setFastLfo, "iiiifff"], [\stopFastLfo, "i"], [\syncFastLfo, "if"], [\setScatter, "ffii"], [\setFastOffset, "iiif"]];
    // [the call, what the command records]
    var calls = [
        [[\setFastLfo, 0, 0, 0, 0, 1.0, 0.5, 0.0], [0, 0, 0, 0, 1.0, 0.5, 0.0]],
        [[\setFastLfo, 5, 6, 4, 7, 50.0, 1.0, -2.0], [5, 6, 4, 7, 50.0, 1.0, -2.0]],
        [[\setFastLfo, 1, 2, 3, 4, 0.001, -0.5, -3.0], [1, 2, 3, 4, 0.003, 0.0, -2.0]],
        [[\setFastLfo, 1, 2, 3, 4, 80.0, 1.5, 2.5], [1, 2, 3, 4, 50.0, 1.0, 2.0]],
        [[\stopFastLfo, 0], [0]],
        [[\syncFastLfo, 5, 1.0], [5, 1.0]],
        [[\syncFastLfo, 2, 1.5], [2, 1.0]],
        [[\syncFastLfo, 2, -0.5], [2, 0.0]],
        [[\setScatter, 0.5, 0.1, 31, 127], [0.5, 0.1, 31, 127]],
        [[\setScatter, 1.5, 0.001, 0, 0], [1.0, 0.01, 0, 0]],
        [[\setScatter, -0.5, 2.0, 3, 5], [0.0, 1.0, 3, 5]],
        [[\setFastOffset, 6, 0, 4, 2.0], [6, 0, 4, 2.0]],
        [[\setFastOffset, 0, 0, 0, 2.5], [0, 0, 0, 2.0]],
        [[\setFastOffset, 3, 0, 1, -7.0], [3, 0, 1, -2.0]]
    ];
    var before = nodeCounts.value, counts = List.new, recorded = List.new;
    check.(signatures.every({ arg pair; h.formatOf(pair[0]) == pair[1] }),
        "modulation: the five commands exist with their signatures (got %)".format(signatures.collect({ arg pair; h.formatOf(pair[0]) })));
    calls.do({ arg call;
        command.(*call[0]);
        server.sync;
        counts.add(nodeCounts.value);
        recorded.add(state[\received][call[0][0]] == call[1]);
    });
    check.(before.notNil and: { counts.every({ arg each; each == before }) },
        "modulation: no command creates a node (synths and groups before %, after each %)".format(before, counts.asSet.asArray));
    check.(recorded.every(_ == true),
        "modulation: each command records its arguments, the continuous ones clipped (%)".format(
            calls.collect({ arg call; call[0][0] }).select({ arg name, index; recorded[index].not })));
};

// Step 1's out-of-range indices and every continuous argument's non-finite
// value (NaN passes clip): each posts one line, records nothing and creates
// no node
checkIgnored = {
    var nan = 0.0 / 0.0;
    var lfo = { arg lfo, voice, destination, shape; [\setFastLfo, lfo, voice, destination, shape, 1.0, 0.5, 0.0] };
    var bad = [
        lfo.(6, 0, 0, 0), lfo.(-1, 0, 0, 0), lfo.(0, 7, 0, 0), lfo.(0, -1, 0, 0), lfo.(0, 0, 5, 0), lfo.(0, 0, -1, 0),
        lfo.(0, 0, 0, 8), lfo.(0, 0, 0, -1), lfo.(0.5, 0, 0, 0),
        [\setFastLfo, 0, 0, 0, 0, nan, 0.5, 0.0], [\setFastLfo, 0, 0, 0, 0, 1.0, nan, 0.0], [\setFastLfo, 0, 0, 0, 0, 1.0, 0.5, nan],
        [\setFastLfo, 0, 0, 0, 0, inf, 0.5, 0.0], [\setFastLfo, 0, 0, 0, 0, 1.0, 0.5, inf.neg],
        [\stopFastLfo, 6], [\stopFastLfo, -1], [\syncFastLfo, 6, 0.5], [\syncFastLfo, -1, 0.5],
        [\syncFastLfo, 0, nan], [\syncFastLfo, 0, inf],
        [\setScatter, 0.1, 0.1, 32, 127], [\setScatter, 0.1, 0.1, -1, 127], [\setScatter, 0.1, 0.1, 3, 128], [\setScatter, 0.1, 0.1, 3, -1],
        [\setScatter, nan, 0.1, 3, 127], [\setScatter, 0.1, nan, 3, 127], [\setScatter, inf, 0.1, 3, 127],
        [\setFastOffset, 7, 0, 0, 0.0], [\setFastOffset, -1, 0, 0, 0.0], [\setFastOffset, 0, 1, 0, 0.0], [\setFastOffset, 0, -1, 0, 0.0],
        [\setFastOffset, 0, 0, 5, 0.0], [\setFastOffset, 0, 0, -1, 0.0],
        [\setFastOffset, 0, 0, 0, nan], [\setFastOffset, 0, 0, 0, inf], [\setFastOffset, 0, 0, 0, inf.neg]
    ];
    var kept = state[\received].deepCopy, before = nodeCounts.value, lines = List.new, unchanged = List.new;
    state[\postIgnored] = { arg line; ignoredLines.add(line) };
    bad.do({ arg call;
        var count = ignoredLines.size;
        command.(*call);
        lines.add(ignoredLines.size - count);
        unchanged.add(sameReceived.(state[\received], kept));
    });
    server.sync;
    state[\postIgnored] = nil;
    check.(unchanged.every(_ == true) and: { lines.every(_ == 1) } and: { nodeCounts.value == before }
        and: { ignoredLines.every({ arg line; line.beginsWith("strata: ") }) },
        "modulation: out-of-range indices and non-finite values are ignored, one line each (changed by %; lines %)".format(
            bad.select({ arg call, index; unchanged[index].not }), lines.asSet.asArray));
};

// Every channel reads 0 after the commands, and fastModGroup is the first
// node of xg, before voiceGroup, and holds nothing
checkBuses = {
    var values = h.readBus(state[\fastModBus]), silent = h.readBus(state[\silentFastModBus]);
    var children = childrenOf.(context.xg), group = state[\fastModGroup];
    check.((values.size == 35) and: { values.every(_ == 0) } and: { silent.size == 5 } and: { silent.every(_ == 0) },
        "modulation: every fast-modulation channel reads 0 (% of 35 and % of the silent bus's 5 at 0)".format(
            values.count(_ == 0), silent.count(_ == 0)));
    check.(group.notNil and: { children.size > 1 } and: { children[0] == group.nodeID } and: { children[1] == engine.voiceGroup.nodeID }
        and: { childrenOf.(group).isEmpty },
        "modulation: fastModGroup sits before voiceGroup, at the head of xg, empty (xg's first nodes %, fastModGroup %, voiceGroup %)".format(
            children.keep(2), group !? _.nodeID, engine.voiceGroup.nodeID));
};

// A voice on each source kind, then each switched (a replacement grain
// synth): every grain synth and every stage reads its voice's block, which
// setGrainParam and setVoiceParam never replace. The slot stays empty (its
// grain synth starts all the same; no load: #581, docs/notes/engine/modulation.md)
checkFastModIn = {
    var slot = 2, silent = state[\silentFastModBus].index;
    // [voice, first source, second source]
    var plan = [[0, 0, engine.inputSource], [1, slot + 1, 0], [2, engine.inputSource, slot + 1]];
    var read = { plan.collect({ arg each; getControl.(engine.synths[engine.grainKey(each[0])], \fastModIn) }) };
    var blocks = plan.collect({ arg each; engine.fastModBlock(each[0], 0) });
    var saved = plan.collect({ arg each; engine.grainControls[each[0]].copy });
    var first, second, stages, refused, kept;
    plan.do({ arg each;
        command.(\setGrainSource, each[0], each[1]);
        command.(\voiceOn, each[0], 110.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    });
    server.sync; 0.1.wait;
    first = read.value;
    plan.do({ arg each; command.(\setGrainSource, each[0], each[2]) });
    server.sync; 0.1.wait;
    second = read.value;
    stages = engine.numVoices.collect({ arg voice; getControl.(engine.synths[engine.voiceMixKey(voice)], \fastModIn) });
    kept = engine.grainControls[0][\fastModIn];
    command.(\setGrainParam, 0, \fastModIn, silent);
    command.(\setVoiceParam, 0, \fastModIn, silent);
    server.sync;
    refused = (engine.grainControls[0][\fastModIn] == kept) and: { engine.voiceControls[0][\fastModIn].isNil }
        and: { getControl.(engine.synths[engine.grainKey(0)], \fastModIn) == blocks[0] };
    check.((first == blocks) and: { second == blocks }
        and: { stages == engine.numVoices.collect({ arg voice; engine.fastModBlock(voice, 0) }) }
        and: { blocks.every({ arg block; block != silent }) },
        "modulation: every grain synth and stage starts with its voice's block as fastModIn (grain synths %, after a switch %, stages %; blocks %)".format(
            first, second, stages, blocks));
    check.(refused, "modulation: setGrainParam and setVoiceParam refuse fastModIn (#458)");
    // stopped, back on their synth sources (stopAllVoices), with their grain controls
    plan.do({ arg each; command.(\voiceOff, each[0]) });
    h.stopAllVoices;
    plan.do({ arg each, index; engine.grainControls[each[0]] = saved[index] });
    server.sync;
};

// The stage's gate and mute controls (design §8.12, §8.14): declared with
// their defaults, set through setGrainParam, kept, and neutral: a synth
// voice's tap is its synth path unchanged (filter mix 0) and an input
// voice's tap its mirror (the other path, on the check's tone in the input
// bus: no slot load, #581), whatever they are set to
checkGateControls = {
    var names = [\seqGate, \gateSeconds, \gateRelease, \voiceMute], defaults = [0, 0.1, 0.1, 0];
    var synthVoice = 1, otherVoice = 4, voices = [synthVoice, otherVoice], tone;
    var saved = voices.collect({ arg voice; engine.grainControls[voice].copy });
    var stageDesc = SynthDescLib.global.at(\strataVoiceMix);
    var declared = names.collect({ arg name, index;
        var control = stageDesc.controls.detect({ arg each; each.name == name });
        control.notNil and: { control.defaultValue.equalWithPrecision(defaults[index], 1e-6) }
    });
    var inGrainDefs = h.grainDefs.collect({ arg defName;
        SynthDescLib.global.at(defName).controlNames.collect(_.asSymbol).select({ arg name; names.includes(name) }) }).flatten;
    var peaks = 2.collect({ Bus.control(server, 2) }), probes, settings, measured = List.new, reached, kept;
    var taps = engine.areaState[\record][\voiceTaps];
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.inputSynth, \addBefore);
    voices.do({ arg voice; command.(\setGrainParam, voice, \filterMix, 0) });
    // (at the ring's head: a history an earlier area left could reach back before the tone)
    command.(\setGrainParam, otherVoice, \history, 0);
    command.(\setGrainSource, otherVoice, engine.inputSource);
    voices.do({ arg voice; command.(\voiceOn, voice, 110.0, 0.5, 0.0, 0.1, 20.0, 1.0) });
    server.sync;
    // after processGroup: the stages have written the taps and the mirror
    probes = [
        Synth(\strataCheckBusDiff, [\a, taps[synthVoice], \b, engine.voicePathBus(synthVoice, 0), \out, peaks[0]], engine.processGroup, \addAfter),
        Synth(\strataCheckBusDiff, [\a, taps[otherVoice], \b, engine.granBuses[otherVoice], \out, peaks[1]], engine.processGroup, \addAfter)
    ];
    1.0.wait;
    // [the settings, the stage's values for them]
    settings = [[], [\seqGate, 1, \gateSeconds, 0.0625, \gateRelease, 0.5], [\voiceMute, 1], [\seqGate, 1, \voiceMute, 1]];
    settings.do({ arg pairs;
        voices.do({ arg voice; pairs.pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) }) });
        server.sync; 0.1.wait;
        probes.do({ arg probe; probe.set(\t_reset, 1) });
        0.3.wait;
        measured.add(peaks.collect({ arg bus; h.readBus(bus) }));
    });
    reached = voices.every({ arg voice;
        var stage = engine.synths[engine.voiceMixKey(voice)];
        [[\seqGate, 1], [\gateSeconds, 0.0625], [\gateRelease, 0.5], [\voiceMute, 1]].every({ arg pair;
            getControl.(stage, pair[0]).equalWithPrecision(pair[1], 1e-6) and: { engine.grainControls[voice][pair[0]] == pair[1] } })
    });
    kept = voices.every({ arg voice;
        var grain = engine.synths[engine.grainKey(voice)];
        names.every({ arg name; engine.grainControlPairs(voice).includes(name).not }) and: { grain.notNil }
    });
    check.(declared.every(_ == true) and: { inGrainDefs.isEmpty },
        "modulation: the stage has seqGate, gateSeconds, gateRelease and voiceMute (defaults %), no grain def does (%)".format(
            names.collect({ arg name; stageDesc.controls.detect({ arg each; each.name == name }) !? _.defaultValue }), inGrainDefs));
    check.(reached and: { kept },
        "modulation: setGrainParam sets the four on the stage and keeps them with the voice, never for a grain synth");
    check.(measured.every({ arg pair; pair.every({ arg values; (values[0] < 1e-6) and: { values[1] > 0.001 } }) }),
        "modulation: the stage has seqGate, gateSeconds, gateRelease and voiceMute, and setting them changes nothing yet ([difference, level] of the synth voice's and the input voice's taps, per setting: %)".format(
            measured.collect({ arg pair; pair.collect({ arg values; values.collect({ arg value; value.round(1e-9) }) }) })));
    voices.do({ arg voice;
        names.do({ arg name, index; command.(\setGrainParam, voice, name, defaults[index]) });
        command.(\voiceOff, voice);
    });
    probes.do(_.free);
    tone.free;
    h.stopAllVoices;
    voices.do({ arg voice, index;
        command.(\setGrainParam, voice, \filterMix, saved[index][\filterMix] ? 0);
        engine.grainControls[voice] = saved[index];
    });
    server.sync;
    peaks.do(_.free);
};

// The grain defs and the stage default fastModIn to one silent fast bus,
// the one of the engine that built them, never control bus 0. The global
// SynthDescLib holds the defs of the engine built last, another area's in a
// full run, whose buses are not h.engine's: the descs are h.engine's when
// their other bus defaults (the stage's tapOut, the grain defs' recHeadBus)
// are its buses, and only then must the silent bus be h.engine's too. Read
// only: no defs built again (#581, docs/notes/engine/modulation.md)
checkDefaults = {
    var silent = state[\silentFastModBus].index, defNames = [\strataGrainRing, \strataGrainBuf, \strataVoiceMix];
    var defaultOf = { arg defName, name;
        SynthDescLib.global.at(defName).controls.detect({ arg control; control.name == name }) !? _.defaultValue };
    var defaults = defNames.collect({ arg defName; defaultOf.(defName, \fastModIn) });
    var engines = (defaultOf.(\strataVoiceMix, \tapOut) == engine.areaState[\record][\tapSink].index)
        and: { [\strataGrainRing, \strataGrainBuf].every({ arg defName;
            defaultOf.(defName, \recHeadBus) == engine.areaState[\record][\idleHead].index }) };
    check.(defaults.every(_.notNil) and: { defaults.asSet.size == 1 } and: { defaults[0] != 0 }
        and: { engines.not or: { defaults[0] == silent } },
        "modulation: fastModIn defaults to silentFastModBus in both grain defs and the stage (%; this engine's silent bus %, its descs %)".format(
            defaults, silent, if (engines) { "this engine's" } { "another engine's" }));
};

// The area's stop frees fastModGroup and its free both buses: run here on a
// group and two buses swapped in for the check (h.engine's own come back
// afterward), not on a second engine (#581)
checkFree = {
    var keys = [\fastModBus, \silentFastModBus, \fastModGroup], kept = keys.collect({ arg key; state[key] });
    var buses = [Bus.control(server, 35), Bus.control(server, 5)], group = Group.before(engine.voiceGroup), held, left;
    server.sync;
    held = childrenOf.(context.xg).includes(group.nodeID);
    protect {
        state[\fastModBus] = buses[0]; state[\silentFastModBus] = buses[1]; state[\fastModGroup] = group;
        area[\stop].value;
        area[\free].value;
        server.sync;
        left = childrenOf.(context.xg).includes(group.nodeID);
    } {
        keys.do({ arg key, index; state[key] = kept[index] });
    };
    check.(held and: { left == false } and: { buses.every({ arg bus; bus.index.isNil }) }
        and: { kept.every({ arg each; each.notNil }) } and: { (kept[0].index ? -1) >= 0 } and: { childrenOf.(context.xg)[0] == kept[2].nodeID },
        "modulation: free frees the buses, and stop the group (held %, group left %, buses left %; the engine's own kept)".format(held, left,
            buses.count({ arg bus; bus.index.notNil })));
};

// What the area leaves for the areas after it: every voice stopped, on its
// synth source, with the grain controls it found
checkVoicesLeft = {
    var sources = engine.grainSource.copy, running = (0 .. engine.numVoices - 1).select({ arg voice; engine.voiceRunning(voice) });
    var changed = (0 .. engine.numVoices - 1).reject({ arg voice; engine.grainControls[voice] == foundControls[voice] });
    check.(sources.every(_ == 0) and: { running.isEmpty } and: { changed.isEmpty },
        "modulation: the area leaves every voice on its synth source (sources %, running %, grain controls changed on %)".format(
            sources, running, changed));
};

if (area.isNil or: { state.isNil }) {
    check.(false, "modulation: the area runs at order 160 (no strataAreaModulation)");
} {
    checkState.value;
    checkDefaults.value;
    checkChannels.value;
    checkCommands.value;
    checkIgnored.value;
    checkBuses.value;
    checkFastModIn.value;
    checkGateControls.value;
    checkFree.value;
    checkVoicesLeft.value;
};
}
