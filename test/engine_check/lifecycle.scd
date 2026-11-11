// test/engine_check/lifecycle.scd
// Synth lifecycle: the kill fade, replace-never-stack source switches
// (bursts, spaced switches, node order after any switch history), voiceOn
// re-gating within and after the release, a same-block note, re-gating
// buffer- and input-sourced voices, superseded synths at start, fast stop /
// start cycles, the invariant warnings, quiet sends to synths that have just
// freed, and restarts of synths that end unexpectedly.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var synthNames = { arg group; h.synthNames(group) };
var synthNodes = { arg group; h.synthTree(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var voiceTrio = { arg voice; h.voiceSynths(voice) };
var voiceDefs = h.voiceDefs, grainDefs = h.grainDefs, stereoPath = h.stereoPath;
var oldTrio, before, after, silentIndex, names, oldGrain, oldVoiceSynth, grainBuf;
var grainCount, voiceCount, grainBefore, voiceBefore, countVoiceAndGrain, maxGrainCount, maxVoiceCount;
var orderNodes, orderGrains, busReadingAt, mirroringAt;

// A voice's grain synths (live or releasing) in node order: [position in
// nodes, reads the voice's own ring?] for each grain synth on one of its two
// paths (engine.voicePathBus)
var voiceGrainNodes = { arg nodes, voice;
    var paths = [engine.voicePathBus(voice, 0).index, engine.voicePathBus(voice, 1).index];
    nodes.collect({ arg node, position;
        if (grainDefs.includes(node.def) and: { paths.includes(node.controls[\out].asInteger) }) {
            [position, (node.def == \strataGrainRing) and: { node.controls[\bufL] == engine.ringBuffersFor(voice, 0)[0].bufnum }]
        }
    }).reject(_.isNil)
};
var stageOf = { arg voice; engine.synths[engine.voiceMixKey(voice)] };
var voiceModPosition = { arg nodes, voice;
    nodes.detectIndex({ arg node; (node.def == \strataMod) and: { node.controls[\in] == engine.granBuses[voice].index } })
};
// Every running voice's grain synths run before its own mod synth
var grainsBeforeOwnMods = {
    var nodes = synthNodes.(engine.processGroup);
    (0..(engine.numVoices - 1)).every({ arg voice;
        var grains = voiceGrainNodes.(nodes, voice), modPosition = voiceModPosition.(nodes, voice);
        grains.isEmpty or: { modPosition.notNil and: { grains.every({ arg each; each[0] < modPosition }) } }
    })
};

// true when the named control is the gate (first input) of an EnvGen
// whose doneAction (input 4, after levelScale, levelBias, timeScale) frees the synth
var controlTriggersFreeingEnvGen = { arg defName, controlName;
    var desc = SynthDescLib.global.at(defName);
    var control = desc.controls.detect({ arg each; each.name == controlName });
    control.notNil and: { desc.def.children.any({ arg ugen;
        var gate = ugen.inputs.notNil.if({ ugen.inputs[0] });
        ugen.isKindOf(EnvGen) and: { gate.isKindOf(OutputProxy) } and: { gate.source.isKindOf(Control) }
            and: { (gate.source.specialIndex + gate.outputIndex) == control.index } and: { ugen.inputs[4] == 2 }
    }) }
};

// A mod synth the engine restarts (its release ended just as voiceOn
// re-gated it) keeps the voice's mod speed
var checkModSpeedRestart = { arg voice;
    var key = engine.modKey(voice), oldMod;
    command.(\setModSpeed, voice, 3.5); server.sync;
    oldMod = engine.synths[key];
    server.sendMsg(\n_free, oldMod.nodeID);  // ends without sclang having freed it
    0.2.wait; server.sync;
    check.(engine.synths[key].notNil and: { engine.synths[key] !== oldMod }
        and: { getControl.(engine.synths[key], \speed) == 3.5 },
        "a restarted mod synth keeps the voice's mod speed (got %)".format(engine.synths[key] !? { getControl.(engine.synths[key], \speed) }));
};

// voiceOn after a source change in the release: the previous source's
// releasing grain synth and the voice synth (now forced to release) are
// tracked as the voice's fadingSynths, not left releasing beside the new
// one, and the next start for another source cuts them (#46). The voice
// runs on its synth source.
var checkSupersededAtStart = { arg voice, before;
    var oldTrio = voiceTrio.(voice), fading = engine.fadingSynths[voice];
    command.(\voiceOff, voice);
    command.(\setGrainSource, voice, 9);
    command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
    check.(oldTrio[1].isPlaying and: { engine.synths[engine.grainKey(voice)] !== oldTrio[1] }
        and: { fading.includes(oldTrio[1]) } and: { fading.includes(oldTrio[0]) }
        and: { engine.releasingSynths[voice][engine.grainKey(voice)].isNil }
        and: { engine.releasingSynths[voice][engine.voiceKey(voice)].isNil },
        "voiceOn hands the previous source's releasing grain and voice synths to fadingSynths");
    command.(\voiceOff, voice); server.sync;
    check.(oldTrio[1].isPlaying and: { fading.includes(oldTrio[1]) }, "voiceOff keeps them fading (tracked)");
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); 0.15.wait; server.sync;
    check.(oldTrio[1].isPlaying.not and: { oldTrio[0].isPlaying.not } and: { engine.cuttingSynths[voice].isEmpty },
        "the next start for another source cuts them (got grain %, voice %)".format(oldTrio[1].isPlaying, oldTrio[0].isPlaying));
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "the voice is back on its synth with one trio");
};

// Fast stop / source change / start / running switch cycles on one voice:
// voiceOn hands the releasing synths built for another source to
// fadingSynths as a switch does (cutting the fading ones, freeing the
// cutting ones), so the voice holds at most its live grain synth, one fading
// and one cutting (#46), and as many voice synths. The cycles visit the
// synth source too: [9, 0] from the synth source hands the released voice
// synth to fadingSynths at voiceOn and cuts it as the switch back starts a
// new one, so two voice synths are held at once there (the count measures
// something). Two passes:
// - the engine's own tracking (live, releasing, fading and cutting synths)
//   after every command, all 24 commands without a yield: no /n_end is
//   handled meanwhile, so nothing leaves the sets on its own and the counts
//   do not depend on server timing (an upper bound on what the server runs)
// - the server's node tree after every step (sync, one /g_queryTree), as an
//   upper bound only: a slower server can only have freed more
var checkStopStartCycles = { arg voice;
    var before = synthNames.(context.xg).size, cycles = [[9, 3], [0, 9], [4, 0], [9, 0], [4, 3], [0, 9]];
    var trackedGrains = 0, trackedVoices = 0, serverGrains = 0, serverVoices = 0;
    var runCycles = { arg afterStep;
        // [stopped source, running source]: each differs from the one before
        cycles.do({ arg sources;
            command.(\voiceOff, voice); afterStep.value;
            command.(\setGrainSource, voice, sources[0]); afterStep.value;
            command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); afterStep.value;
            command.(\setGrainSource, voice, sources[1]); afterStep.value;
        });
    };
    runCycles.({
        var held = IdentitySet.new;
        [engine.synths, engine.releasingSynths[voice]].do({ arg dict;
            [engine.voiceKey(voice), engine.grainKey(voice)].do({ arg key; dict[key] !? { arg synth; held.add(synth) } });
        });
        held.addAll(engine.fadingSynths[voice]); held.addAll(engine.cuttingSynths[voice]);
        trackedGrains = max(trackedGrains, held.count({ arg synth; grainDefs.includes(synth.defName.asSymbol) }));
        trackedVoices = max(trackedVoices, held.count({ arg synth; synth.defName.asSymbol == engine.voiceSynthDefs[voice] }));
    });
    check.(trackedGrains <= 3, "six fast stop / source / start / switch cycles hold at most three grain synths after every command (worst %)".format(trackedGrains));
    check.((trackedVoices <= 3) and: { trackedVoices >= 2 }, "and at most three voice synths, two at once after [9, 0] (worst %)".format(trackedVoices));
    command.(\setGrainSource, voice, 0);
    2.5.wait; server.sync;
    runCycles.({
        var nodes;
        server.sync;
        nodes = synthNodes.(context.xg);
        serverGrains = max(serverGrains, voiceGrainNodes.(nodes, voice).size);
        serverVoices = max(serverVoices, nodes.count({ arg node; node.def == engine.voiceSynthDefs[voice] }));
    });
    check.((serverGrains <= 3) and: { serverVoices <= 3 },
        "and the server runs at most three of each after every step (worst % grain, % voice)".format(serverGrains, serverVoices));
    command.(\setGrainSource, voice, 0);
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "the fast cycles leave no extra nodes");
};

// The invariant warnings (#46): a synth found releasing where the
// bookkeeping never leaves one (injected here: a stand-in synth in
// releasingSynths of a running voice) is still handled, and the engine
// posts a "Strata invariant broken" line that run_engine_check.sh fails
// on. The lines are captured through postInvariantWarning, so this run
// does not fail (nor do these checks print them); the stand-ins are freed
// and forgotten afterward. The voice runs on its synth source.
var engineCheckScript = h.testDir +/+ "run_engine_check.sh";
var checkInvariantWarnings = { arg voice, before;
    var lines = List.new, grainKey = engine.grainKey(voice), standIns, failPattern, standInBus = Bus.control(server, 1);
    var standIn = { Synth(\strataCheckMemProbe, [\out, standInBus.index], engine.processGroup, \addToTail).register(true) };
    var scriptText = engineCheckScript !? { arg path; File.exists(path).if({ File.readAllString(path) }) };
    engine.postInvariantWarning = { arg line; lines.add(line) };
    standIns = [standIn.value, standIn.value]; server.sync;
    // a switch of a running voice that finds a synth in releasingSynths
    engine.releasingSynths[voice][grainKey] = standIns[0];
    command.(\setGrainSource, voice, 9);
    check.((lines.size == 1) and: { lines[0].contains("Strata invariant broken") }
        and: { engine.releasingSynths[voice][grainKey].isNil } and: { engine.cuttingSynths[voice].includes(standIns[0]) },
        "a switch that finds a synth releasing cuts it and warns (% lines)".format(lines.size));
    // a stop that finds a superseded synth under a running synth's key
    engine.releasingSynths[voice][grainKey] = standIns[1];
    command.(\voiceOff, voice);
    check.((lines.size == 2) and: { lines[1].contains("Strata invariant broken") }
        and: { engine.fadingSynths[voice].includes(standIns[1]) },
        "a stop that finds a superseded synth hands it to fadingSynths and warns (% lines)".format(lines.size));
    engine.postInvariantWarning = nil;
    // run_engine_check.sh fails on these lines as String.warn posts them
    failPattern = scriptText !? { arg text;
        text.split($\n).detect({ arg line; line.contains("! grep -qE") }) !? { arg line; line.split($").at(1) }
    };
    check.(failPattern.notNil and: { lines.every({ arg line; ("WARNING: " ++ line).findRegexp(failPattern).notEmpty }) },
        "run_engine_check.sh's failure pattern matches the posted warnings (pattern found: %)".format(failPattern.notNil));
    // ... and the line the server prints for a grain UGen past its maxGrains,
    // which drops grains (#47). The check's own line must not quote it: the
    // script would fail on that too
    check.(failPattern.notNil and: { "Too many grains!".findRegexp(failPattern).notEmpty },
        "run_engine_check.sh's failure pattern matches the server's line for a grain UGen past maxGrains");
    command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0);
    command.(\setGrainSource, voice, 0);
    server.sync;
    // the first was freed by the stop's freeCuttingSynths already
    standIns.do({ arg synth;
        if (synth.isPlaying) { server.sendBundle(nil, ['/error', -1], ['/n_free', synth.nodeID]) };
        engine.fadingSynths[voice].remove(synth); engine.cuttingSynths[voice].remove(synth);
    });
    2.5.wait; server.sync;
    standInBus.free;
    check.(synthNames.(context.xg).size == before, "the voice is back on its synth with one trio, the stand-ins gone");
};

// Messages to synths that can end on the server on their own go out
// quietly (sendToSynth, #47). Each race frees synths on the server behind
// sclang's back, so their /n_end is not handled yet and the engine still
// sees them playing, then at once sends the command that messages them. The
// server must report none of it: no /fail reply, so no "FAILURE IN SERVER"
// line, on which run_engine_check.sh fails (the flake this prevents). Each
// race is [what messages the freed synths, setup (may wait), the race]. The
// voice runs on its synth source and ends there, with what it still uses
// restarted by the engine; slot 8 (index 7) is free for the check.
var checkQuietNodeSends = { arg voice, before;
    var fails = List.new, watcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr);
    var keys = [engine.voiceKey(voice), engine.grainKey(voice), engine.modKey(voice)];
    var start = { command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0) };
    var freeBehind = { arg nodes; nodes.do({ arg node; if (node.notNil) { server.sendMsg(\n_free, node.nodeID) } }) };
    var releasing = { arg names; names.collect({ arg key; engine.releasingSynths[voice][key] }) };
    [
        ["setSynth (a grain param) to the live grain synth", {}, {
            freeBehind.([engine.synths[keys[1]]]); command.(\setGrainParam, voice, \grainSize, 0.1) }],
        ["releaseVoice (voiceOff) gating off the live synths", {}, {
            freeBehind.(voiceTrio.(voice)); command.(\voiceOff, voice) }],
        ["gateVoice (voiceOn) re-gating the releasing synths", { start.value; server.sync; command.(\voiceOff, voice) }, {
            freeBehind.(releasing.(keys)); start.value }],
        ["replaceGrainSynth (a switch) releasing the live synths and moving the new grain synth before the freed mod synth", {}, {
            freeBehind.(voiceTrio.(voice)); command.(\setGrainSource, voice, 9) }],
        ["cutSynth (the next switch) cutting the fading synths", { command.(\setGrainSource, voice, 0) }, {
            freeBehind.(engine.fadingSynths[voice].asArray); command.(\setGrainSource, voice, 9) }],
        ["gateVoice (voiceOn for another source) releasing the voice synth and moving the mod synth", {
            command.(\setGrainSource, voice, 0); server.sync; command.(\voiceOff, voice); command.(\setGrainSource, voice, 9) }, {
            freeBehind.(releasing.([keys[0], keys[2]])); start.value }],
        ["stopRecording (stopRecord) freeing a record synth whose take has just ended", {
            command.(\recordBuffer, 7, 0.5, 1.0, 0, 0, 0, 0, 0); 0.2.wait }, {
            freeBehind.([engine.recordSynths[7]]); command.(\stopRecord, 7) }],
        ["bufferChanged (a clear) fading a releasing buffer grain synth", {
            command.(\setGrainSource, voice, 8); server.sync; command.(\voiceOff, voice) }, {
            freeBehind.(releasing.([keys[1]])); command.(\clearBuffer, 7) }]
    ].do({ arg race;
        race[1].value;
        server.sync; 0.1.wait; server.sync;
        fails.clear;
        race[2].value;
        server.sync; 0.3.wait; server.sync;    // the engine has restarted what the voice still uses
        check.(fails.isEmpty, "% sends quietly to synths that have just freed (server failures: %)".format(race[0], fails));
    });
    watcher.free;
    command.(\setGrainSource, voice, 0); start.value;
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "after the races the voice is back on its synth with one trio");
};

// The engine's cut (cutSynth) triggers a freeing fade on the kill
// control, independent of whatever release the gate envelope is in
(voiceDefs ++ grainDefs).do({ arg name;
    check.(controlTriggersFreeingEnvGen.(name, \kill), "% has a kill fade (kill triggers a freeing EnvGen)".format(name));
});

// Every voice started, voice 0 with the grain params the checks below
// carry over (pitch 2, position spread 0.7, the first envelope buffer)
h.startAllVoices;
silentIndex = engine.silentBus.index;
command.(\setGrainParam, 0, \pitchShift, 2.0);
command.(\setGrainParam, 0, \posSpread, 0.7);
command.(\setGrainParam, 0, \envShape, 1);
server.sync;

// ---- Audio sources: replace, never stack ----
check.(grainsBeforeOwnMods.value, "every voice's grain synths run before its mod synth (mirror reaches strataMod)");
// voice 0 running from the earlier voiceOn; switch it to buffer 3
before = synthNames.(context.xg).size;
oldGrain = engine.synths[\grain0];
oldVoiceSynth = engine.synths[\voice0];
command.(\setGrainParam, 0, \bufPos, 0.25);
command.(\setGrainSource, 0, 3); server.sync;
check.(synthNames.(context.xg).includes(\strataGrainBuf), "buffer source uses strataGrainBuf");
check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 2, "one GrainBuf synth per buffer voice (voices 1 and 7)");
check.(engine.synths[\voice0].isNil, "voice synth released in buffer mode");
check.(getControl.(oldVoiceSynth, \gate) < 0, "the voice synth gets a short forced release");
check.(getControl.(oldGrain, \gate) < 0, "the old grain synth gets a forced release (grainRelease)");
grainBuf = engine.synths[\grain0];
check.(grainBuf.defName == \strataGrainBuf, "voice 1 now runs strataGrainBuf");
check.(getControl.(grainBuf, \bufnumL) == engine.buffersL[2].bufnum, "source 3 reads slot 3 (index 2)");
check.(getControl.(grainBuf, \bufPos) == 0.25, "grain controls set before the switch carry over (bufPos)");
check.(getControl.(grainBuf, \pitchShift) == 2.0, "grain controls carry over (pitchShift)");
check.(getControl.(grainBuf, \envBuf) == engine.envBuffers[0].bufnum, "grain controls carry over (envBuf)");
check.(getControl.(grainBuf, \out) == engine.voicePathBus(0, 3).index, "strataGrainBuf writes the voice's other path");
check.(getControl.(stageOf.(0), \mirrorOut) == engine.granBuses[0].index, "the stage mirrors the other path into the voice bus");
check.(getControl.(grainBuf, \bufFrames) == 0, "an empty slot plays with bufFrames 0");
check.(grainsBeforeOwnMods.value, "a replacement grain synth still runs before its voice's mod synth");
after = synthNames.(context.xg).size;
command.(\setGrainSource, 0, 3); server.sync;
check.(engine.synths[\grain0] === grainBuf and: { synthNames.(context.xg).size == after },
    "setGrainSource with the current source changes nothing");
command.(\retrigger, 0, 0.5); server.sync;
check.(getControl.(stageOf.(0), \velocity) == 0.5, "retrigger carries velocity to the voice's stage (for its accent)");
command.(\setModSource, 0, 1, 2);
command.(\setModAmpAmt, 0, 1, 0.5);
command.(\setModFreqAmt, 0, 2, 0.25);
command.(\setVoiceParam, 0, \amp, 0.3);
command.(\setVoiceParam, 0, \rq, 0.2);
command.(\setGrainParam, 0, \bufRate, 0.5);
server.sync;
check.(getControl.(grainBuf, \modBus1) == engine.modBuses[2].index, "setModSource reaches strataGrainBuf");
check.(getControl.(stageOf.(0), \modAmpAmt1) == 0.5 and: { getControl.(grainBuf, \modFreqAmt2) == 0.25 },
    "the amp amount reaches the stage and the freq amount strataGrainBuf");
check.(getControl.(stageOf.(0), \amp).equalWithPrecision(0.3), "the voice's amp sets its stage's level");
check.(getControl.(grainBuf, \bufRate) == 0.5, "setGrainParam bufRate reaches strataGrainBuf");
command.(\setGrainSource, 0, 9); server.sync;
check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 2, "input source uses strataGrainRing (old GrainBuf only releasing)");
check.(getControl.(grainBuf, \gate) < 0, "switching away releases the GrainBuf synth (forced release)");
check.(engine.synths[\grain0].defName == \strataGrainRing
    and: { getControl.(engine.synths[\grain0], \bufL) == engine.ringBuffersFor(0, engine.inputSource)[0].bufnum }
    and: { getControl.(engine.synths[\grain0], \phaseBus) == engine.ringBuffersFor(0, engine.inputSource)[2].index },
    "input source: strataGrainRing reads the input ring");
check.(getControl.(stageOf.(0), \mirrorOut) == engine.granBuses[0].index,
    "input source: the stage mirrors into the voice bus (so its mod synth keeps feeding crossmod)");
check.(getControl.(engine.synths[\grain0], \out) == engine.voicePathBus(0, 9).index,
    "input source: the grain synth writes the voice's other path (its stage applies the level and accent)");
check.(getControl.(stageOf.(0), \amp).equalWithPrecision(0.3), "the voice's amp sets its stage's level");
check.(getControl.(engine.synths[\grain0], \pitchShift) == 2.0, "grain controls carry over to the input source");
command.(\retrigger, 0, 0.75); server.sync;
check.(getControl.(stageOf.(0), \velocity) == 0.75, "retrigger carries velocity to the stage of an input voice");
// amplitude crossmod reaches an input-sourced voice through its grain synth
check.(getControl.(engine.synths[\grain0], \modBus1) == engine.modBuses[2].index
    and: { getControl.(stageOf.(0), \modBus1) == engine.modBuses[2].index }
    and: { getControl.(stageOf.(0), \modAmpAmt1) == 0.5 },
    "input source: the grain synth reads its routed mod bus (rate); the stage reads it for the level, with the slot's amp amount");
command.(\setModAmpAmt, 0, 2, 0.75); server.sync;
check.(getControl.(stageOf.(0), \modAmpAmt2) == 0.75, "setModAmpAmt reaches an input-sourced voice's stage");
command.(\setModAmpAmt, 0, 2, 0.0);
command.(\setGrainSource, 0, 0); server.sync;
check.(engine.synths[\voice0].notNil, "returning to synth restarts the voice synth");
check.(engine.synths[\voice0].defName == \strataResonator, "the restarted voice synth is the voice's own SynthDef");
check.(getControl.(engine.synths[\voice0], \rq).equalWithPrecision(0.2)
    and: { getControl.(engine.synths[\voice0], \amp).equalWithPrecision(0.3) }
    and: { getControl.(engine.synths[\voice0], \freq) == 100.0 },
    "the restarted voice synth gets the voice's current params");
check.(getControl.(engine.synths[\voice0], \modBus1) == engine.modBuses[2].index
    and: { getControl.(engine.synths[\voice0], \modAmpAmt1) == 0.5 },
    "the restarted voice synth keeps its crossmod routing");
check.(getControl.(engine.synths[\grain0], \bufL) == engine.ringBuffersFor(0, 0)[0].bufnum
    and: { getControl.(engine.synths[\grain0], \out) == engine.voicePathBus(0, 0).index },
    "synth source: grain reads the voice ring and writes the voice's synth path (no mirror, no level)");
check.([\modBus1, \modBus2, \modBus3].every({ arg control; getControl.(engine.synths[\grain0], control) == silentIndex }),
    "synth source: the grain synth's mod buses are the silent bus, never control bus 0");
command.(\setGrainSource, 0, 10);
command.(\setGrainSource, 0, -1);
server.sync;
check.(engine.grainSource[0] == 0, "out-of-range sources are ignored");
2.5.wait; server.sync;
check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 1, "the released GrainBuf synth is gone");
check.(synthNames.(context.xg).size == before, "source switching leaves no extra nodes");

// A burst of source switches (E3 scrolling) keeps at most one
// releasing grain synth per voice: each switch cuts the one an
// earlier switch left releasing, and the voice synths it released
before = synthNames.(context.xg).size;
names = synthNames.(context.xg);
grainBefore = names.count({ arg name; grainDefs.includes(name) });
voiceBefore = names.count({ arg name; voiceDefs.includes(name) });
[1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source; command.(\setGrainSource, 4, source) });
0.3.wait; server.sync;
names = synthNames.(context.xg);
grainCount = names.count({ arg name; grainDefs.includes(name) });
voiceCount = names.count({ arg name; voiceDefs.includes(name) });
check.(grainCount == (grainBefore + 1),
    "10 source switches leave the live grain synth and one releasing (% grain synths, % before)".format(grainCount, grainBefore));
check.(voiceCount == (voiceBefore - 1),
    "the voice synths the burst started and released are cut too (% voice synths, % before)".format(voiceCount, voiceBefore));
2.5.wait; server.sync;
names = synthNames.(context.xg);
check.(names.count({ arg name; grainDefs.includes(name) }) == grainBefore
    and: { engine.fadingSynths[4].isEmpty } and: { engine.releasingSynths[4].isEmpty },
    "after the release no grain synth is left over and nothing stays tracked (% grain synths, fading %, releasing %)".format(names.count({ arg name; grainDefs.includes(name) }), engine.fadingSynths[4], engine.releasingSynths[4]));
command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
check.(synthNames.(context.xg).size == before, "the burst leaves no extra nodes");

// The same switches spread over many control blocks (real E3 detents):
// a cut must also end a synth that is already in its forced release,
// which a second, shorter forced release (gate -1 - time) cannot
countVoiceAndGrain = {
    var list = synthNames.(context.xg);
    [list.count({ arg name; grainDefs.includes(name) }), list.count({ arg name; voiceDefs.includes(name) })]
};
# grainBefore, voiceBefore = countVoiceAndGrain.value;
maxGrainCount = 0; maxVoiceCount = 0;
[1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source;
    command.(\setGrainSource, 4, source);
    0.2.wait; server.sync;    // well past switchCutTime (and CI block jitter), so this switch has been processed
    # grainCount, voiceCount = countVoiceAndGrain.value;
    maxGrainCount = max(maxGrainCount, grainCount);
    maxVoiceCount = max(maxVoiceCount, voiceCount);
});
check.(maxGrainCount <= (grainBefore + 1),
    "switches 0.2 s apart keep at most the live grain synth and one releasing (at most % grain synths, % before)".format(maxGrainCount, grainBefore));
check.(maxVoiceCount <= (voiceBefore + 1),
    "switches 0.2 s apart keep at most one releasing voice synth (at most % voice synths, % before)".format(maxVoiceCount, voiceBefore));
command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
check.(synthNames.(context.xg).size == before, "spaced switches leave no extra nodes");
[1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source; command.(\setGrainSource, 4, source); 0.02.wait });
0.2.wait; server.sync;
# grainCount, voiceCount = countVoiceAndGrain.value;
check.((grainCount <= (grainBefore + 1)) and: { voiceCount <= voiceBefore },
    "switches 0.02 s apart end with the live grain synth and one releasing (% grain synths, % voice synths; % and % before)".format(
        grainCount, voiceCount, grainBefore, voiceBefore));
2.5.wait; server.sync;
check.(engine.fadingSynths[4].isEmpty and: { engine.releasingSynths[4].isEmpty },
    "after the release nothing a spaced burst released stays tracked");
command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
check.(synthNames.(context.xg).size == before, "the spaced burst leaves no extra nodes");

// Grain node order holds for any switch history: synth -> buffer ->
// input -> synth within 1 s, read at once (the buffer grain synth is
// still in its cut): every grain synth that reads the voice bus runs
// before every one that mirrors into it, and all before the voice's mod synth
command.(\setGrainSource, 4, 3); 0.3.wait;
command.(\setGrainSource, 4, 9); 0.3.wait;
command.(\setGrainSource, 4, 0); server.sync;   // no wait: the buffer grain synth is in its 50 ms cut
orderNodes = synthNodes.(engine.processGroup);
orderGrains = voiceGrainNodes.(orderNodes, 4);
busReadingAt = orderGrains.select({ arg each; each[1] }).collect(_.first);
mirroringAt = orderGrains.reject({ arg each; each[1] }).collect(_.first);
check.(busReadingAt.notEmpty and: { mirroringAt.notEmpty } and: { busReadingAt.maxItem < mirroringAt.minItem },
    "after 0 -> 3 -> 9 -> 0 every bus-reading grain synth runs before every mirroring one (bus-reading at %, mirroring at %)".format(busReadingAt, mirroringAt));
check.(voiceModPosition.(orderNodes, 4).notNil and: { orderGrains.every({ arg each; each[0] < voiceModPosition.(orderNodes, 4) }) },
    "... and every grain synth of the voice before its mod synth (grains at %, mod at %)".format(
        orderGrains.collect(_.first), voiceModPosition.(orderNodes, 4)));
check.(grainsBeforeOwnMods.value, "every voice's grain synths still run before its mod synth");
2.5.wait; server.sync;
check.(synthNames.(context.xg).size == before, "the 0 -> 3 -> 9 -> 0 switches leave no extra nodes");

// voiceOn never stacks synths (M6; spec section 5 re-gate). A running
// voice keeps its synths and takes the voiceOn values.
before = synthNames.(context.xg).size;
oldTrio = voiceTrio.(0);
command.(\voiceOn, 0, 150.0, 0.2, 0.0, 0.1, 10.0, 1.0);
server.sync;
check.(synthNames.(context.xg).size == before, "voiceOn on a running voice creates no nodes (M6)");
check.(voiceTrio.(0).every({ arg synth, index; synth === oldTrio[index] }), "voiceOn on a running voice keeps its synths");
check.((getControl.(oldTrio[0], \freq) == 150.0) and: { getControl.(oldTrio[0], \gate) == 1 },
    "voiceOn on a running voice applies its freq with set");

// voiceOff then voiceOn within the release re-gates the same synths
oldTrio = voiceTrio.(2);  // Folder: 6 s voice release
command.(\setVoiceParam, 2, \bend, 1.1);
command.(\voiceOff, 2); server.sync;
check.(oldTrio.every({ arg synth; getControl.(synth, \gate) == 0 }), "voiceOff gates the trio off");
command.(\voiceOn, 2, 220.0, 0.25, 0.1, 0.2, 12.0, 1.5); server.sync;
check.(synthNames.(context.xg).size == before, "voiceOn during the release creates no nodes");
check.(voiceTrio.(2).every({ arg synth, index; synth === oldTrio[index] }), "voiceOn during the release re-gates the same synths");
check.(oldTrio.every({ arg synth; getControl.(synth, \gate) == 1 }), "re-gated synths are back at gate 1");
check.((getControl.(oldTrio[0], \freq) == 220.0) and: { getControl.(oldTrio[0], \pan).equalWithPrecision(0.1) }
    and: { getControl.(oldTrio[1], \grainSize).equalWithPrecision(0.2) } and: { getControl.(oldTrio[1], \grainDensity) == 12.0 }
    and: { getControl.(oldTrio[1], \pitchShift) == 1.5 }, "re-gating applies the voiceOn values with set");
check.(getControl.(oldTrio[0], \bend) == 1, "voiceOn resets bend to 1");

// Partway through the release the grain (2 s) and mod (0.5 s) synths
// have freed and the voice synth still releases: it is re-gated, the
// other two are started
command.(\voiceOff, 2); 2.5.wait; server.sync;
check.(synthNames.(context.xg).size == (before - 2), "2.5 s after voiceOff only the voice synth still releases");
command.(\voiceOn, 2, 220.0, 0.25, 0.1, 0.2, 12.0, 1.5); server.sync;
after = voiceTrio.(2);
check.(synthNames.(context.xg).size == before, "voiceOn late in the release brings back one trio");
check.((after[0] === oldTrio[0]) and: { after[1] !== oldTrio[1] } and: { after[2] !== oldTrio[2] }
    and: { after.every({ arg synth; synth.isPlaying }) }, "the releasing voice synth is re-gated, grain and mod synths are new");
check.(getControl.(after[0], \gate) == 1, "the re-gated voice synth is at gate 1");

// After the whole release voiceOn creates fresh synths (Karplus: 2 s release)
oldTrio = voiceTrio.(5);
command.(\voiceOff, 5); 2.5.wait; server.sync;
check.(synthNames.(context.xg).size == (before - 3), "a released voice's synths free themselves");
check.(engine.releasingSynths[5].isEmpty, "freed synths are forgotten");
command.(\voiceOn, 5, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
after = voiceTrio.(5);
check.((synthNames.(context.xg).size == before) and: { after.every({ arg synth, index; synth.notNil and: { synth !== oldTrio[index] } }) },
    "voiceOn after the release creates a fresh trio");

// voiceOn and voiceOff in one control block (a MIDI note-on and
// note-off in one bundle): the trio created in that block still
// releases and frees, instead of waiting forever on an envelope that
// never started
// (inside makeBundle, sendToSynth's bundle is flattened into the
// outer one: its /error -1 then silences the rest of that bundle)
command.(\voiceOff, 5); 2.5.wait; server.sync;
server.makeBundle(0.1, {
    command.(\voiceOn, 5, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0);
    command.(\voiceOff, 5);
});
oldTrio = engine.releasingSynths[5].values.asArray;
0.3.wait; server.sync;
check.((oldTrio.size == 3) and: { synthNames.(context.xg).size == before },
    "voiceOn and voiceOff in one bundle create a trio that is releasing");
2.5.wait; server.sync;
check.((synthNames.(context.xg).size == (before - 3)) and: { engine.releasingSynths[5].isEmpty }
    and: { oldTrio.every({ arg synth; synth.isPlaying.not }) },
    "a trio started and released in one control block frees after its release (% nodes, % before)".format(
        synthNames.(context.xg).size, before));
command.(\voiceOn, 5, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
check.(synthNames.(context.xg).size == before, "the voice starts again after a same-block note");

// A buffer-sourced voice (a grain and a mod synth, no voice synth) re-gates too
oldTrio = voiceTrio.(6);
command.(\voiceOff, 6); server.sync;
command.(\voiceOn, 6, 100.0, 0.25, 0.0, 0.3, 10.0, 1.0); server.sync;
after = voiceTrio.(6);
check.((synthNames.(context.xg).size == before) and: { after[0].isNil } and: { after[1] === oldTrio[1] }
    and: { after[2] === oldTrio[2] } and: { getControl.(after[1], \gate) == 1 }
    and: { getControl.(after[1], \grainSize).equalWithPrecision(0.3) }, "a buffer-sourced voice re-gates its grain and mod synths");
// The slot changes while the voice releases: the re-gated grain synth
// takes its new length and rate (M1). Slot 4 holds a 0.1 s take at the server rate.
command.(\voiceOff, 6); server.sync;
command.(\loadBuffer, 3, stereoPath, 0); 0.3.wait; server.sync;    // 11025 frames at 22050 Hz
command.(\voiceOn, 6, 100.0, 0.25, 0.0, 0.3, 10.0, 1.0); server.sync;
after = voiceTrio.(6);
check.((after[1] === oldTrio[1]) and: { getControl.(after[1], \bufFrames) == 11025 }
    and: { getControl.(after[1], \bufRateScale).equalWithPrecision(22050 / server.sampleRate) },
    "a re-gated buffer grain synth takes a slot change made during its release (bufFrames %)".format(
        getControl.(after[1], \bufFrames)));

// A source switch while the voice is releasing: voiceOn builds the new
// source's grain synth and re-gates the mod synth; the old voice and
// grain synths finish within the grain release (no orphans)
oldTrio = voiceTrio.(3);  // Sub: 12 s voice release
command.(\setGrainParam, 3, \grainMode, 1);
command.(\setGrainParam, 3, \envShape, 2);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 9);  // the input; only recorded: the voice is stopped
command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
after = voiceTrio.(3);
// voiceOn merges its values into the voice's grain controls, so a new
// grain synth starts in the voice's grain mode (no stray continuous grains; M2)
check.((getControl.(after[1], \grainMode) == 1) and: { getControl.(after[1], \envBuf) == engine.envBuffers[1].bufnum }
    and: { getControl.(after[1], \grainSize).equalWithPrecision(0.1) },
    "a grain synth built by voiceOn keeps the voice's grain mode and envelope, with voiceOn's size");
command.(\setGrainParam, 3, \grainMode, 0);
command.(\setGrainParam, 3, \envShape, 0);
check.(after[0].isNil and: { after[1].defName == \strataGrainRing } and: { after[1] !== oldTrio[1] }
    and: { getControl.(after[1], \bufL) == engine.ringBuffersFor(3, engine.inputSource)[0].bufnum }
    and: { after[2] === oldTrio[2] }, "voiceOn after a source switch in the release builds the new grain synth, re-gates the mod synth");
check.(grainsBeforeOwnMods.value, "the new mirroring grain synth runs before the re-gated mod synth");
2.5.wait; server.sync;
check.(oldTrio[0].isPlaying.not and: { oldTrio[1].isPlaying.not } and: { synthNames.(context.xg).size == (before - 1) },
    "the old voice and grain synths free themselves within the grain release (no orphans)");
// an input-sourced voice re-gates its grain and mod synths
oldTrio = voiceTrio.(3);
command.(\voiceOff, 3); server.sync;
command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
after = voiceTrio.(3);
check.((synthNames.(context.xg).size == (before - 1)) and: { after[0].isNil } and: { after[1] === oldTrio[1] }
    and: { after[2] === oldTrio[2] } and: { getControl.(after[1], \gate) == 1 }, "an input-sourced voice re-gates its grain and mod synths");
command.(\setGrainSource, 3, 0); 2.5.wait; server.sync;
check.(synthNames.(context.xg).size == before, "switching back to the synth restores the trio");

checkSupersededAtStart.(3, before);
checkStopStartCycles.(3);
checkInvariantWarnings.(3, before);
checkQuietNodeSends.(3, before);

// A re-gated synth whose release ends just as the gate arrives frees
// anyway; the engine starts that synth again
oldTrio = voiceTrio.(2);
server.sendMsg(\n_free, oldTrio[1].nodeID);  // ends without sclang having freed it
0.2.wait; server.sync;
after = voiceTrio.(2);
check.(after[1].notNil and: { after[1] !== oldTrio[1] } and: { after[1].isPlaying }
    and: { synthNames.(context.xg).size == before }, "a running voice's synth that ends unexpectedly is started again");
checkModSpeedRestart.(2);

// ringReaders holds every strataGrainRing (live, releasing, fading or
// cutting) with its voice until it frees, then forgets it
command.(\setGrainSource, 4, 9); server.sync;     // voice 4's synth-source grain synth now fades
check.((0..(engine.numVoices - 1)).every({ arg voice;
        var synth = engine.synths[engine.grainKey(voice)];
        synth.isNil or: { synth.defName.asSymbol != \strataGrainRing } or: { engine.ringReaders[synth] == voice } })
    and: { engine.fadingSynths[4].select({ arg synth; synth.defName.asSymbol == \strataGrainRing })
        .every({ arg synth; engine.ringReaders[synth] == 4 }) }
    and: { engine.ringReaders.keys.every({ arg synth; synth.defName.asSymbol == \strataGrainRing }) },
    "lifecycle: ringReaders maps every ring grain synth to its voice (% readers)".format(engine.ringReaders.size));
h.stopAllVoices;
check.(h.waitFor({ engine.ringReaders.isEmpty }, 3), "lifecycle: ringReaders empties as ring grain synths free");

// Every grain start restarts the scan (design 3.3 §5.1). A slot whose left
// channel is a staircase of its position and whose right channel is 1, so
// the left / right ratio of a voice's grains is where they read (with no
// pan spread or pan jitter, which would move the ratio).
{
    var voice = 1, slot = 7, grainKey = engine.grainKey(voice), posBus = Bus.control(server, 1);
    var path = h.tempDir +/+ "lifecycle-scan.wav", saved = engine.grainControls[voice].copy;
    var position, probe, frames, stepFrames, steps = 64, grain, moved, restarted, first;
    SynthDef(\strataCheckRegateScan, { arg in, peaks;
        var signal = In.ar(in, 2);
        Out.kr(peaks, A2K.kr(RunningSum.ar(signal[0].abs, 960) / RunningSum.ar(signal[1].abs, 960).max(0.001)));
    }).add;
    server.sync;
    h.writeTestFile(path, server.sampleRate, (2 * server.sampleRate).round.asInteger, [0, 0]);
    command.(\loadBuffer, slot, path, 0);
    h.waitFor({ engine.bufferFrames[slot] > 0 }, 3);
    0.1.wait; server.sync;
    frames = engine.bufferFrames[slot];
    stepFrames = frames div: steps;
    steps.do({ arg step; engine.buffersL[slot].fill(step * stepFrames, stepFrames, step / steps) });
    engine.buffersR[slot].fill(0, frames, 1);
    server.sync;
    position = { h.readBus(posBus)[0] };
    probe = Synth.before(engine.synths[engine.voiceMixKey(voice)], \strataCheckRegateScan,
        [\in, engine.voicePathBus(voice, 1).index, \peaks, posBus.index]);
    server.sync;
    [\posSpread, 0, \panSpread, 0, \panJitter, 0, \bufPos, 0, \loopStart, 0, \loopLength, 1, \scrubRate, 0, \scanHold, 0, \bufScan, 0.5].pairsDo({ arg name, value;
        command.(\setGrainParam, voice, name, value)
    });
    command.(\setGrainSource, voice, slot + 1);
    server.sync;
    command.(\voiceOn, voice, 200.0, 0.5, 0.0, 0.04, 200.0, 1.0);
    server.sync;
    0.15.wait;
    first = position.value;
    check.(first < 0.2, "lifecycle: a new grain synth's scan starts at 0 (the grains at %)".format(first));

    1.2.wait;
    moved = position.value;
    grain = engine.synths[grainKey];
    command.(\voiceOff, voice); server.sync;
    0.05.wait;
    command.(\voiceOn, voice, 200.0, 0.5, 0.0, 0.04, 200.0, 1.0); server.sync;
    0.1.wait;
    restarted = position.value;
    check.((moved > 0.4) and: { engine.synths[grainKey] === grain } and: { restarted < 0.2 },
        "lifecycle: a re-gated buffer voice restarts its scan (the grains at %, then %, % the same grain synth)"
            .format(moved, restarted, if (engine.synths[grainKey] === grain) { "with" } { "NOT with" }));

    // a running voice's voiceOn is no start: its scan goes on
    1.2.wait;
    moved = position.value;
    command.(\voiceOn, voice, 200.0, 0.5, 0.0, 0.04, 200.0, 1.0); server.sync;
    0.1.wait;
    restarted = position.value;
    check.((moved > 0.4) and: { restarted > (moved - 0.1) },
        "lifecycle: a voiceOn on a running buffer voice keeps its scan (the grains at %, then %)".format(moved, restarted));

    probe.free;
    command.(\voiceOff, voice);
    h.stopAllVoices;
    command.(\setGrainSource, voice, 0);
    command.(\clearBuffer, slot);
    engine.grainControls[voice] = saved;
    server.sync;
    posBus.free;
    File.delete(path);
}.value;

// A start's first grain plays the start's own grain values (#325). Lua
// sends a start as the source and every grain value, then voiceOn, then the
// voice-level values (S.lib.engine_sync.start_voice); the engine keeps a
// stopped voice's grain values and builds (or re-gates) its grain synth with
// them inside voiceOn's bundle. A slot whose first half is +0.5 and second
// half -0.5, and a buffer voice whose kept position is 0.75 (its last run's,
// in the negative half), started at 0.25: its path never goes below -0.05.
// Sent the old way (voiceOn first, the rest 30 ms later, a sync arriving
// late) the first grains read 0.75 (about -0.31). The same with triggered
// mode chosen while stopped and no retrigger: the path stays silent. And a
// releasing voice: grain values sent during its release never reach the
// releasing synth, and voiceOn re-gates that node with them
{
    var voice = 2, slot = 5, minMaxBus = Bus.control(server, 2), probe, frames, half;
    var path = h.tempDir +/+ "lifecycle-start-order.wav", saved = engine.grainControls[voice].copy;
    var period = server.options.blockSize / server.sampleRate;
    var window, grainValues, voiceValues, startInLuaOrder, trial, results, node, running, releasing, regated;
    SynthDef(\strataCheckStartOrder, { arg in, out, t_reset = 0;
        var signal = In.ar(in, 2)[0], reset = T2A.ar(t_reset);
        Out.kr(out, [A2K.kr(RunningMin.ar(signal, reset)), A2K.kr(RunningMax.ar(signal, reset))]);
    }).add;
    server.sync;
    h.writeTestFile(path, server.sampleRate, (2 * server.sampleRate).round.asInteger, [0, 0]);
    command.(\loadBuffer, slot, path, 0);
    h.waitFor({ engine.bufferFrames[slot] > 0 }, 3);
    0.1.wait; server.sync;
    frames = engine.bufferFrames[slot];
    half = frames div: 2;
    [engine.buffersL[slot], engine.buffersR[slot]].do({ arg buffer;
        buffer.fill(0, half, 0.5);
        buffer.fill(half, frames - half, -0.5);
    });
    server.sync;
    [\panSpread, 0, \panJitter, 0, \loopStart, 0, \loopLength, 1, \scrubRate, 0, \scanHold, 0].pairsDo({ arg name, value;
        command.(\setGrainParam, voice, name, value)
    });
    command.(\setGrainSource, voice, slot + 1);
    server.sync;
    // the voice's other path, ahead of its stage
    command.(\voiceOn, voice, 60.0, 0.3, 0.0, 0.1, 20.0, 1.0);
    server.sync;
    probe = Synth.before(engine.synths[engine.voiceMixKey(voice)], \strataCheckStartOrder,
        [\in, engine.voicePathBus(voice, 1).index, \out, minMaxBus.index]);
    server.sync;
    command.(\voiceOff, voice);
    2.6.wait;

    // [min, max] of the voice's path over the next seconds
    window = { arg seconds;
        probe.set(\t_reset, 1); server.sync;
        seconds.wait;
        h.readBus(minMaxBus).round(0.01)
    };
    grainValues = { arg bufPos, mode;
        [[\setGrainSource, voice, slot + 1],
            [\setGrainParam, voice, \grainSize, 0.1], [\setGrainParam, voice, \grainDensity, 20.0],
            [\setGrainParam, voice, \pitchShift, 1.0], [\setGrainParam, voice, \posSpread, 0.0],
            [\setGrainParam, voice, \envShape, 0.0], [\setGrainParam, voice, \grainMode, mode],
            [\setGrainParam, voice, \bufPos, bufPos], [\setGrainParam, voice, \bufRate, 1.0],
            [\setGrainParam, voice, \bufScan, 0.0]]
    };
    voiceValues = [[\setVoiceParam, voice, \freq, 60.0], [\setVoiceParam, voice, \fold, 1.0],
        [\setVoiceParam, voice, \mod, 0.2], [\setVoiceParam, voice, \amp, 0.3], [\setVoiceParam, voice, \pan, 0.0],
        [\setModSpeed, voice, 10.0], [\setVoiceParam, voice, \bend, 1.0]];
    // A start as Lua sends it: the source and the grain values, voiceOn,
    // then the voice-level values, here 30 ms late (a sync arriving late)
    startInLuaOrder = { arg bufPos, mode;
        (grainValues.(bufPos, mode) ++ [[\voiceOn, voice, 60.0, 0.3, 0.0, 0.1, 20.0, 1.0]] ++ voiceValues)
            .do({ arg message;
                command.(*message);
                if (message[0] == \voiceOn) { 0.03.wait };
            });
    };
    // One start of the stopped voice, whose kept position and mode are its
    // last run's (0.75, continuous): [min, max] over its first 0.4 s
    trial = { arg bufPos, mode;
        var result;
        command.(\setGrainParam, voice, \bufPos, 0.75);
        command.(\setGrainParam, voice, \grainMode, 0);
        server.sync;
        probe.set(\t_reset, 1); server.sync;
        (0.03 + period.rand).wait;     // anywhere in a control block
        startInLuaOrder.(bufPos, mode);
        0.4.wait;
        result = h.readBus(minMaxBus).round(0.01);
        command.(\voiceOff, voice);
        2.6.wait;                      // the grain synth's release ends: the next start builds a new one
        result
    };

    results = 3.collect({ trial.(0.25, 0) });
    check.(results.every({ arg result; (result[0] >= -0.05) and: { result[1] > 0.2 } }),
        "lifecycle: a start sent as Lua sends it plays no grain from the last run's position ([min, max] per start: %)"
            .format(results));
    results = 2.collect({ trial.(0.25, 1) });
    // and a retrigger then plays one, so the silence is the mode's
    startInLuaOrder.(0.25, 1);
    0.2.wait;
    probe.set(\t_reset, 1); server.sync;
    command.(\retrigger, voice, 1.0);
    0.2.wait;
    regated = h.readBus(minMaxBus).round(0.01);
    command.(\voiceOff, voice);
    2.6.wait;
    check.(results.every({ arg result; (result[0] >= -0.05) and: { result[1] <= 0.05 } }) and: { regated[1] > 0.2 },
        "lifecycle: a start in triggered mode chosen while stopped plays no grain before a retrigger ([min, max] per start: %; after a retrigger %)"
            .format(results, regated));

    // the releasing voice: running at 0.75, stopped, the new grain values
    // 0.3 s into its release, then voiceOn 0.3 s later
    command.(\setGrainParam, voice, \bufPos, 0.75);
    command.(\setGrainParam, voice, \grainMode, 0);
    command.(\voiceOn, voice, 60.0, 0.3, 0.0, 0.1, 20.0, 1.0);
    0.5.wait;
    running = window.(0.3);
    node = engine.synths[engine.grainKey(voice)].nodeID;
    command.(\voiceOff, voice);
    0.3.wait;
    grainValues.(0.25, 0).do({ arg message; command.(*message) });
    server.sync;
    releasing = window.(0.3);
    command.(\voiceOn, voice, 60.0, 0.3, 0.0, 0.1, 20.0, 1.0);
    voiceValues.do({ arg message; command.(*message) });
    server.sync;
    check.(engine.synths[engine.grainKey(voice)].notNil and: { engine.synths[engine.grainKey(voice)].nodeID == node },
        "lifecycle: voiceOn re-gates the releasing grain synth (no new node)");
    0.25.wait;                         // the grains in flight (0.1 s) end
    regated = window.(0.3);
    check.((running[1] < -0.2) and: { releasing[1] < 0.05 } and: { regated[0] > 0 },
        "lifecycle: grain values sent during a release wait for the re-gate, which takes them (running %, releasing %, re-gated %)"
            .format(running, releasing, regated));

    probe.free;
    command.(\voiceOff, voice);
    h.stopAllVoices;
    command.(\setGrainSource, voice, 0);
    command.(\clearBuffer, slot);
    engine.grainControls[voice] = saved;
    server.sync;
    minMaxBus.free;
    File.delete(path);
}.value;
}
