// test/engine_check/lifecycle.scd
// Synth lifecycle: the kill fade, replace-never-stack source switches
// (bursts, spaced switches, node order after any switch history), voiceOn
// re-gating within and after the release, a same-block note, re-gating
// buffer- and input-sourced voices, superseded synths at start, fast stop /
// start cycles, the invariant warnings, quiet sends to synths that have just
// freed, starts the server never made, the reports a re-gating voiceOn keeps
// on, and restarts of synths that end unexpectedly.
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
        trackedVoices = max(trackedVoices, held.count({ arg synth; synth.defName.asSymbol == engine.voiceDefFor(voice) }));
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
        serverVoices = max(serverVoices, nodes.count({ arg node; node.def == engine.voiceDefFor(voice) }));
    });
    check.((serverGrains <= 3) and: { serverVoices <= 3 },
        "and the server runs at most three of each after every step (worst % grain, % voice)".format(serverGrains, serverVoices));
    command.(\setGrainSource, voice, 0);
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "the fast cycles leave no extra nodes");
};

// The synth sets of one voice of target, as the table of
// docs/notes/engine/lifecycle.md (The synth sets) has them after any event:
// the problems found, none when the sets hold. The live, releasing, fading
// and cutting sets are disjoint and hold none of the voice's note synths;
// no mod synth fades or cuts; nothing releases under a key that is live; at
// most one voice synth and one grain synth fade (one fading set); and the
// live set is the source's: none on a stopped voice, and on a running one
// its grain and mod synths, its voice synth on the synth source only, and a
// grain synth built for its source (a slot's \strataGrainBuf, a ring's
// \strataGrainRing). Whether the voice runs and its source are the caller's
// (running, source: what its own commands made them), never read from the
// engine checked
var checkOwnSynths = { arg target, voice, running, source;
    var keys = [target.voiceKey(voice), target.grainKey(voice), target.modKey(voice)];
    var live = keys.collect({ arg key; target.synths[key] }), releasing = target.releasingSynths[voice];
    var fading = target.fadingSynths[voice].asArray, cutting = target.cuttingSynths[voice].asArray;
    var held = live.reject(_.isNil) ++ releasing.values.asArray ++ fading ++ cutting;
    var notes = target.areaState[\notes][\slots][voice].copyToEnd(1).collect({ arg record; [record[\synth], record[\cutting]] }).flatten.reject(_.isNil);
    var problems = List.new;
    var defOf = { arg synth; synth.defName.asSymbol };
    var fadingVoices = fading.count({ arg synth; voiceDefs.includes(defOf.(synth)) });
    var fadingGrains = fading.count({ arg synth; grainDefs.includes(defOf.(synth)) });
    if (held.as(IdentitySet).size != held.size) { problems.add("a synth in two sets") };
    if (notes.any({ arg synth; held.includes(synth) })) { problems.add("a note synth among the own synths") };
    if ((fading ++ cutting).any({ arg synth; defOf.(synth) == \strataMod })) { problems.add("a mod synth fading or cutting") };
    keys.do({ arg key, index; if (live[index].notNil and: { releasing[key].notNil }) { problems.add("% releasing under its live key".format(key)) } });
    if ((fadingVoices > 1) or: { fadingGrains > 1 }) { problems.add("% voice and % grain synths fading".format(fadingVoices, fadingGrains)) };
    if (running.not) {
        if (live.any(_.notNil)) { problems.add("a stopped voice with a live synth") };
    } {
        if (live[1].isNil or: { live[2].isNil } or: { live[0].isNil != (source != 0) }) {
            problems.add("the live set of a running voice is not the source's (source %, live %)".format(source, live.collect({ arg synth; synth !? _.nodeID }))) };
        if (live[1].notNil and: { (defOf.(live[1]) == \strataGrainBuf) != source.inclusivelyBetween(1, target.numBuffers) }) {
            problems.add("a live % on source %".format(defOf.(live[1]), source)) };
    };
    problems
};

// A seeded walk of target's voices: `steps` commands drawn from voiceOn,
// voiceOff, setGrainSource (the synth, two slots, the input, two voice
// sources), setVoiceType, setGrainParam's freeze and freezeMode, and noteOn
// (the own note and three extra slots), sent without a yield, so no /n_end
// or /n_go is handled meanwhile and the sets move by the commands' rows
// alone; checkOwnSynths after every command. But for one thing: a start the
// server has not confirmed within startConfirmWait counts as failed at the
// voice's next voiceOn or cut (forgetFailedStarts), and with no yield no
// /n_go comes in, so a walk that ran longer than that would forget the
// starts it made itself. So it syncs with the server (a yield: the /n_go
// and /n_end so far are handled) once half of startConfirmWait has passed
// since the walk began or last synced. The walk keeps its own record of
// what its commands made of each voice (the model: running or stopped, its
// source, its live extra notes), never the engine's, and judges the engine
// by it: a voiceOn runs the voice, a voiceOff stops a running one, a
// setGrainSource records the source, an extra note on a running voice is
// live while the pool (pool) has room, and a voiceOff releases the voice's.
// The commands Lua never sends are ignored with one line each, and only
// these: an extra note to a stopped voice ("voice <v> is stopped") and one
// with the pool full of live notes ("the pool of <pool> is full of live
// notes"); any other line, or a missing one, is a problem. Returns the
// first failure ([step, the last eight commands, the problems]), the rows
// reached, the lines ignored, the syncs and the model at the end
var walkOwnSynths = { arg target, seed, steps, voices, pool;
    var random = Pseed(seed, Pwhite(0.0, 1.0)).asStream, failure, recent = List.new(9), ignored = 0;
    var lastSync = Main.elapsedTime, syncs = 0, walkStep, lines = List.new;
    // the model, from a fresh engine: every voice stopped on the synth source, no extra note
    var running = Array.fill(target.numVoices, false), sourceOf = Array.fill(target.numVoices, 0), liveNotes = Set.new;
    var reached = IdentityDictionary.new, reach = { arg name; reached[name] = (reached[name] ? 0) + 1 };
    var pick = { arg items; items[(random.next * items.size).floor.asInteger.min(items.size - 1)] };
    var sources = [0, 0, 0, 1, 2, target.inputSource, target.voiceSourceFirst, target.voiceSourceFirst + 6];
    var types = (0 .. (target.numVoiceTypes - 1)), modulation = target.areaState[\modulation], previous = modulation[\postIgnored];
    // one command and its checks
    walkStep = { arg step;
        var voice = pick.(voices), draw = random.next, message, problems, expected = [], wasRunning = running[voice];
        var grainKey = target.grainKey(voice), voiceKey = target.voiceKey(voice);
        var liveGrain = target.synths[grainKey], liveVoice = target.synths[voiceKey];
        var releasing = target.releasingSynths[voice].values.asArray, frozen = target.areaState[\freeze][\frozen][voice];
        var type = target.voiceType(voice), spectral = target.areaState[\freeze][\mode][voice] == \spectral;
        message = case
        { draw < 0.18 } { [\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0] }
        { draw < 0.3 } { [\voiceOff, voice] }
        { draw < 0.48 } { [\setGrainSource, voice, pick.(sources)] }
        { draw < 0.62 } { [\setVoiceType, voice, pick.(types)] }
        { draw < 0.74 } { [\setGrainParam, voice, \freeze, pick.([0.0, 1.0])] }
        { draw < 0.84 } { [\setGrainParam, voice, \freezeMode, pick.([0.0, 1.0, 1.0])] }
        { [\noteOn, voice, pick.((0 .. 3)), 60.0, 220.0, 1.0, 1.0] };
        // the lines the model expects, then the model moved by the command
        switch (message[0])
        { \voiceOn } { running[voice] = true }
        { \voiceOff } {
            if (wasRunning) { liveNotes = liveNotes.reject({ arg note; note[0] == voice }) };
            running[voice] = false;
        }
        { \setGrainSource } { sourceOf[voice] = message[2] }
        { \noteOn } {
            if (message[2] > 0) {
                case
                { wasRunning.not } { expected = ["strata: noteOn ignored: voice % is stopped".format(voice)] }
                { liveNotes.includes([voice, message[2]]) } { }
                { liveNotes.size >= pool } { expected = ["strata: noteOn ignored: the pool of % is full of live notes".format(pool)] }
                { liveNotes.add([voice, message[2]]) };
            };
        };
        lines.clear;
        h.commandTo(target, *message);
        recent.add(message);
        if (recent.size > 8) { recent.removeAt(0) };
        problems = checkOwnSynths.(target, voice, running[voice], sourceOf[voice]);
        if (lines.asArray != expected) { problems.add("the lines ignored % where % were expected".format(lines.asArray, expected)) };
        if (problems.notEmpty and: { failure.isNil }) { failure = [step, recent.asArray, problems.asArray] };
        // the rows the walk must reach
        switch (message[0])
        { \voiceOn } {
            if (liveGrain.isNil and: { releasing.includes(target.synths[grainKey]) }) { reach.(\regated) };
            if (releasing.any({ arg synth; target.fadingSynths[voice].includes(synth) })) { reach.(\superseded) };
            if (releasing.any({ arg synth; target.cuttingSynths[voice].includes(synth) })) { reach.(\cutAtStart) };
        }
        // (a release once it took effect: the grain synth gone from the live set into the releasing one)
        { \voiceOff } {
            if (wasRunning and: { liveGrain.notNil } and: { target.synths[grainKey].isNil }
                and: { target.releasingSynths[voice].values.includes(liveGrain) }) { reach.(\released) };
        }
        { \setGrainSource } { if (liveGrain.notNil and: { target.synths[grainKey] !== liveGrain }) { reach.(\switched) } }
        { \setVoiceType } {
            if (message[2] != type) {
                if (liveVoice.notNil) { reach.(if (target.synths[voiceKey] !== liveVoice) { \typeSwitched } { \typeWaiting }) };
                // (#979's row: a stopped voice under a spectral freeze)
                if (liveGrain.isNil and: { spectral }) { reach.(\typeStoppedSpectral) };
            };
        }
        { \setGrainParam } {
            if (frozen.not and: { target.areaState[\freeze][\frozen][voice] }) { reach.(\frozen) };
            if (liveVoice.notNil and: { target.synths[voiceKey].notNil } and: { target.synths[voiceKey] !== liveVoice }) { reach.(\waitingApplied) };
        }
        { \noteOn } { if ((message[2] > 0) and: { target.areaState[\notes][\slots][voice][message[2]][\state] == \live }) { reach.(\noteLive) } };
    };
    modulation[\postIgnored] = { arg line; ignored = ignored + 1; lines.add(line) };
    {
        steps.do({ arg step;
            if ((Main.elapsedTime - lastSync) > (target.startConfirmWait / 2)) { server.sync; lastSync = Main.elapsedTime; syncs = syncs + 1 };
            walkStep.(step);
        });
    }.protect({ modulation[\postIgnored] = previous });
    (failure: failure, reached: reached, ignored: ignored, syncs: syncs, running: running, sources: sourceOf)
};

// The walk on a high engine of its own (a Pi 4's settings, as the
// reproducer of #1000 made them), voices 0-2 on their own types, slots 1 and
// 2 loaded and a pool of 6 extra notes for their nine extra slots: 2000
// commands of one seed, which must reach the rows it names, the spectral
// rows among them (a type switch waiting for a spectral freeze's unfreeze,
// applied at it, and #979's switch of a stopped voice under one), which only
// a high engine has. Its freeze and freezeMode commands come in bursts
// between syncs, as a mapped controller or a scene sends them: before #1000's
// fix such a burst paused a ring writer twice before its first block, which
// skipped its constructors, and the run after crashed scsynth
// (https://github.com/sethbc/strata/issues/1000)
var checkSynthSetWalk = { arg seed;
    var steps = 2000, voices = [0, 1, 2], pool = 6;
    var rows = [\regated, \superseded, \cutAtStart, \released, \switched, \typeSwitched, \frozen, \noteLive,
        \typeWaiting, \waitingApplied, \typeStoppedSpectral];
    var root = h.tempDir +/+ "walk-high", write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    var target, result, start, seconds, missing, endProblems;
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 16\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    target = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    [0, 1].do({ arg slot; h.commandTo(target, \loadBuffer, slot, h.stereoPath, 0) });
    h.waitFor({ [0, 1].every({ arg slot; target.bufferFrames[slot] > 0 }) }, 3);
    h.commandTo(target, \setNotePool, pool);
    server.sync;
    start = Main.elapsedTime;
    result = walkOwnSynths.(target, seed, steps, voices, pool);
    seconds = Main.elapsedTime - start;
    missing = rows.reject({ arg name; (result[\reached][name] ? 0) > 0 });
    endProblems = voices.collect({ arg voice; checkOwnSynths.(target, voice, result[\running][voice], result[\sources][voice]) }).flatten;
    check.(result[\failure].isNil and: { missing.isEmpty } and: { endProblems.isEmpty },
        "lifecycle: a seeded walk of % commands (seed %, % tier, % s, % syncs, % ignored) keeps every voice's synth sets as the table has them after each (first failure at step %, the last commands %: %; rows reached %, never reached %; at the end %)".format(
            steps, seed, target.tier, seconds.round(0.01), result[\syncs], result[\ignored], result[\failure] !? { arg failure; failure[0] },
            result[\failure] !? { arg failure; failure[1] }, result[\failure] !? { arg failure; failure[2] },
            rows.collect({ arg name; [name, result[\reached][name] ? 0] }), missing, endProblems));
    h.stopAllVoices(target);
    h.freeEngine(target);
    h.teardownSync("free walk engine");
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
        ["replaceGrainSynth (a switch) releasing the live synths", {}, {
            freeBehind.(voiceTrio.(voice)); command.(\setGrainSource, voice, 9) }],
        ["cutSynth (the next switch) cutting the fading synths", { command.(\setGrainSource, voice, 0) }, {
            freeBehind.(engine.fadingSynths[voice].asArray); command.(\setGrainSource, voice, 9) }],
        ["gateVoice (voiceOn for another source) releasing the voice synth and re-gating the mod synth", {
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

// A start the server never made (#497): a synth whose /s_new fails (no
// room in the real-time pool, a def missing) sends no /n_go and no /n_end,
// so the engine, which takes a new synth as playing, would keep it and
// re-gate it at every voiceOn, the voice silent for good. The failure is
// made here by holding back the grain synth's /s_new from a voiceOn's
// bundle (for sclang the same as a failed one, with no FAILURE line).
// Past startConfirmWait (0.5 s) the next voiceOn starts a grain synth: after
// a stop, and on a running voice. The voice (Karplus: 2 s release) runs on
// its synth source and ends with one trio.
var checkFailedStarts = { arg voice, before;
    var grainKey = engine.grainKey(voice), unstarted, nodes;
    var grainNodes = { synthNodes.(engine.processGroup).select({ arg node;
        grainDefs.includes(node.def) and: { node.controls[\out].asInteger == engine.voicePathBus(voice, 0).index } }) };
    // a fresh start whose grain synth never reaches the server
    var startWithoutGrain = {
        var bundle;
        command.(\voiceOff, voice); 2.5.wait; server.sync;
        bundle = server.makeBundle(false, { command.(\voiceOn, voice, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0) });
        unstarted = engine.synths[grainKey];
        server.sendBundle(nil, *bundle.reject({ arg msg; (msg[0] == 9) and: { msg[2] == unstarted.nodeID } }));
        server.sync;
        grainNodes.value.isEmpty and: { engine.synths[grainKey] === unstarted } and: { unstarted.isPlaying }
    };
    var started = {
        nodes = grainNodes.value;
        (nodes.size == 1) and: { engine.synths[grainKey].notNil } and: { engine.synths[grainKey] !== unstarted }
            and: { engine.synths[grainKey].nodeID == nodes[0][\id] } and: { engine.releasingSynths[voice][grainKey].isNil }
            and: { engine.ringReaders[unstarted].isNil }
    };
    check.(startWithoutGrain.value, "lifecycle: a grain synth whose /s_new never ran is tracked as playing, with no node (the failure the check makes)");
    command.(\voiceOff, voice); 1.0.wait;
    command.(\voiceOn, voice, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
    check.(started.value, "lifecycle: after a stop, a voice whose grain synth never started gets one at its next start (#497; % grain nodes)".format(nodes.size));
    check.(startWithoutGrain.value, "lifecycle: ... and again, on a voice left running");
    1.0.wait;
    command.(\voiceOn, voice, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
    check.(started.value, "lifecycle: a running voice whose grain synth never started gets one at its next voiceOn (#497; % grain nodes)".format(nodes.size));
    check.(synthNames.(context.xg).size == before, "lifecycle: the voice is back to one trio");
};

// ... and one that only source switches meet (#497): a running voice's grain
// synth that never started, past startConfirmWait, switched away three
// times before any voiceOn (the first switch releases it into the fading
// set, the second cuts it, the third frees what is cutting) is forgotten,
// not left as a ring reader or unconfirmed start for good. The voice ends
// on its synth source with one trio.
var checkFailedStartSwitches = { arg voice, before;
    var grainKey = engine.grainKey(voice), unstarted, bundle, kept;
    command.(\voiceOff, voice); 2.5.wait; server.sync;
    bundle = server.makeBundle(false, { command.(\voiceOn, voice, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0) });
    unstarted = engine.synths[grainKey];
    server.sendBundle(nil, *bundle.reject({ arg msg; (msg[0] == 9) and: { msg[2] == unstarted.nodeID } }));
    server.sync; 1.0.wait;
    [9, 0, 9].do({ arg source; command.(\setGrainSource, voice, source); server.sync });
    kept = [engine.ringReaders[unstarted].notNil, engine.unconfirmedStarts[unstarted].notNil,
        engine.fadingSynths[voice].includes(unstarted), engine.cuttingSynths[voice].includes(unstarted)];
    check.(kept.every(_.not),
        "lifecycle: a grain synth that never started, switched away three times before a voiceOn, is forgotten (#497; kept as a ring reader, unconfirmed, fading, cutting: %)".format(kept));
    command.(\setGrainSource, voice, 0); 2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "lifecycle: the voice is back to one trio after the switches");
};

// ... and one the engine judges itself (#1019): past startConfirmWait, with
// no command to the voice, a synth whose /s_new failed is in none of the
// engine's records, whatever its kind. Each failure is made by holding the
// synth's /s_new back from what the engine sends (as the #497 checks do,
// with any later message to that node in the same packets, so the server
// sees none of it and posts nothing). Three running voices, each switched
// from the input to the synth source with its new grain synth held back:
// the first then left running, the second stopped at once (its failed
// synth releasing), the third switched to the input and back at once
// (fading, then cutting). The first also loses its voice synth and its mod
// synth behind sclang's back (an /n_free), and the restart of each is held
// back; the third, on a pool of one, starts an extra note whose synth is
// held back. Then twice startConfirmWait and a quarter of a second more,
// no command, and the records read (the voice's live keys, its releasing,
// fading and cutting sets, its note slots, ringReaders, grainSlots, the
// freeze area's inputReaders, unconfirmedStarts), each judged against the
// synths the check itself held back; past twice startConfirmWait, the
// bookkeeping sweep's unconfirmed starts too. Each voice and the pool are
// then put back as they were
var checkFailedStartJudged = { arg voices, before;
    var failed = List.new(8), kept, swept, realAddr = server.addr, start = Main.elapsedTime, pool = engine.areaState[\notes][\pool];
    var running = voices.collect({ arg voice; engine.voiceRunning(voice) }), sources = voices.collect({ arg voice; engine.grainSource[voice] });
    var heldBy = { arg voice, synth;
        var records = List.new;
        if ([engine.voiceKey(voice), engine.grainKey(voice), engine.modKey(voice)].any({ arg key; engine.synths[key] === synth })) { records.add(\live) };
        if (engine.releasingSynths[voice].values.includes(synth)) { records.add(\releasing) };
        if (engine.fadingSynths[voice].includes(synth)) { records.add(\fading) };
        if (engine.cuttingSynths[voice].includes(synth)) { records.add(\cutting) };
        if (engine.areaState[\notes][\slots][voice].any({ arg record; record.notNil
            and: { (record[\synth] === synth) or: { record[\cutting] === synth } } })) { records.add(\noteSlot) };
        if (engine.ringReaders[synth].notNil) { records.add(\ringReader) };
        if (engine.grainSlots[synth].notNil) { records.add(\grainSlot) };
        if (engine.areaState[\freeze][\inputReaders][synth].notNil) { records.add(\inputReader) };
        if (engine.unconfirmedStarts[synth].notNil) { records.add(\unconfirmed) };
        records.asArray
    };
    // what the function sends, but every /s_new of one of defs (and any
    // later message to that node)
    var failing = { arg defs, function;
        var heldBack = List.new(4);
        var keep = { arg msgs;
            msgs.reject({ arg msg;
                var name = msg[0].asString;
                if (["9", "/s_new", "s_new"].includesEqual(name)) {
                    if (defs.includes(msg[1].asSymbol)) { heldBack.add(msg[2]); true } { heldBack.includes(msg[4]) }
                } { (name.beginsWith("/n_") or: { msg[0].isNumber and: { msg[0].inclusivelyBetween(10, 19) } }) and: { heldBack.includes(msg[1]) } }
            })
        };
        protect {
            server.addr = (
                addr: realAddr.addr, port: realAddr.port, isLocal: realAddr.isLocal, hostname: realAddr.hostname,
                socket: realAddr.socket, hasBundle: false,
                sendMsg: { arg self ... msg; var kept = keep.([msg]); if (kept.notEmpty) { realAddr.sendMsg(*kept[0]) } },
                sendBundle: { arg self, time ... msgs; var kept = keep.(msgs); if (kept.notEmpty) { realAddr.sendBundle(time, *kept) } },
                sendClumpedBundles: { arg self, time ... msgs; var kept = keep.(msgs); if (kept.notEmpty) { realAddr.sendClumpedBundles(time, *kept) } }
            );
            function.value;
        } { server.addr = realAddr };
    };
    // a synth of the voice freed behind sclang's back, its restart held back
    var restartFailing = { arg voice, key, def, label;
        var synth = engine.synths[key];
        failing.([def], {
            server.sendMsg('/n_free', synth.nodeID);
            h.waitFor({ engine.synths[key] !== synth }, 1);
        });
        failed.add([voice, engine.synths[key], label]);
    };
    voices.do({ arg voice;
        if (engine.voiceRunning(voice).not) { command.(\voiceOn, voice, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0) };
        command.(\setGrainSource, voice, 9);
    });
    server.sync;
    voices.do({ arg voice, index;
        failing.([\strataGrainRing], { command.(\setGrainSource, voice, 0) });
        failed.add([voice, engine.synths[engine.grainKey(voice)], [\grainLive, \grainReleasing, \grainCutting][index]]);
    });
    server.sync;
    restartFailing.(voices[0], engine.voiceKey(voices[0]), engine.voiceDefFor(voices[0]), \voiceSynth);
    restartFailing.(voices[0], engine.modKey(voices[0]), \strataMod, \modSynth);
    command.(\voiceOff, voices[1]);
    [9, 0].do({ arg source; command.(\setGrainSource, voices[2], source); server.sync });
    command.(\setNotePool, 1);
    failing.([engine.voiceDefFor(voices[2]), \strataGrainRing, \strataGrainBuf], {
        command.(\noteOn, voices[2], 1, 64.0, 329.63, 1.0, 0.8) });
    failed.add([voices[2], engine.noteRecord(voices[2], 1)[\synth], \note]);
    server.sync;
    kept = failed.collect({ arg each; [each[2], each[1].notNil and: { heldBy.(each[0], each[1]).notEmpty }] });
    // (past twice startConfirmWait, so the sweep's condition of #1019 is
    // read too; its line shown without the runner's prefix)
    ((2 * engine.startConfirmWait) + 0.25).wait;
    server.sync;
    kept = [kept, failed.collect({ arg each; [each[2], each[1] !? { arg synth; heldBy.(each[0], synth) }] })];
    swept = h.sweepLines(engine, "lifecycle's #1019 check").select({ arg line; line.contains("a start unconfirmed") })
        .collect({ arg line; line.replace("Strata invariant broken: ", "") });
    check.((failed.size == 6) and: { kept[0].every({ arg each; each[1] }) } and: { kept[1].every({ arg each; each[1] == [] }) } and: { swept.isEmpty },
        "lifecycle: a synth whose /s_new failed is in no record past startConfirmWait, with no command sent: a grain synth left running, stopped and switched away twice, a voice and a mod synth restarted, an extra note (#1019; held before the wait %, the records after it %; the sweep's unconfirmed starts %)".format(
            kept[0], kept[1], swept));
    command.(\noteOff, voices[2], 1, 1);
    command.(\setNotePool, pool);
    voices.do({ arg voice, index;
        command.(\voiceOn, voice, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0);
        command.(\setGrainSource, voice, sources[index]);
        if (running[index].not) { command.(\voiceOff, voice) };
    });
    check.(h.waitFor({ synthNames.(context.xg).size == before }, 4),
        "lifecycle: the three voices are back as they were after the failed starts (#1019; % nodes, % before; % s in all)".format(synthNames.(context.xg).size, before, (Main.elapsedTime - start).round(0.01)));
};

// A voiceOn that re-gates a releasing synth (sendToSynth: a bundle quiet
// for its own messages) still has the server report the starts that follow
// in the same bundle (#498): /error -1 turns reports off until the end of
// the bundle it is in, and makeBundle flattens every sendToSynth into
// voiceOn's, so sendToSynth closes with /error -2. Every /s_new of the
// voiceOn comes where the bundle's -1s and -2s balance. The voice (a voice
// release longer than the grain's 2 s) runs on its synth source: 2.5 s into
// its release only its voice synth is left, which voiceOn re-gates before
// it starts the grain and mod synths.
var checkRegateReportsStarts = { arg voice;
    var bundle, level = 0, starts = 0, quiet = List.new;
    command.(\voiceOff, voice); 2.5.wait; server.sync;
    bundle = server.makeBundle(false, { command.(\voiceOn, voice, 220.0, 0.25, 0.1, 0.2, 12.0, 1.5) });
    server.sendBundle(nil, *bundle);
    server.sync;
    bundle.do({ arg msg;
        if ((msg[0] == '/error') and: { msg[1] == -1 }) { level = level + 1 };
        if ((msg[0] == '/error') and: { msg[1] == -2 }) { level = level - 1 };
        if (msg[0] == 9) { starts = starts + 1; if (level > 0) { quiet.add(msg[1]) } };
    });
    check.((starts == 2) and: { quiet.isEmpty } and: { level == 0 },
        "lifecycle: a voiceOn that re-gates a releasing voice synth leaves the server's reports on for its grain and mod synths' starts (#498; % starts, quiet: %)".format(
            starts, quiet));
};

// The engine's cut (cutSynth) triggers a freeing fade on the kill
// control, independent of whatever release the gate envelope is in
(voiceDefs ++ grainDefs).do({ arg name;
    check.(controlTriggersFreeingEnvGen.(name, \kill), "% has a kill fade (kill triggers a freeing EnvGen)".format(name));
});

// Every voice started, voice 0 with the grain params the checks below
// carry over (pitch 2, position spread 0.7, a window shape of 0.25)
h.startAllVoices;
silentIndex = engine.silentBus.index;
command.(\setGrainParam, 0, \pitchShift, 2.0);
command.(\setGrainParam, 0, \posSpread, 0.7);
command.(\setGrainParam, 0, \windowShape, 0.25);
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
check.(getControl.(grainBuf, \windowShape) == 0.25, "grain controls carry over (windowShape)");
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
// (3.8: the voice sources end at voiceSourceFirst + numVoices - 1)
command.(\setGrainSource, 0, engine.voiceSourceFirst + engine.numVoices);
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
// (inside makeBundle, sendToSynth's messages are flattened into the
// outer bundle: its /error -1 and -2 keep reports off around them only, #498)
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
command.(\loadBuffer, 3, stereoPath, 0); h.awaitLoad(3);    // 11025 frames at 22050 Hz
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
command.(\setGrainParam, 3, \windowShape, 0.75);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 9);  // the input; only recorded: the voice is stopped
command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
after = voiceTrio.(3);
// voiceOn merges its values into the voice's grain controls, so a new
// grain synth starts in the voice's grain mode (no stray continuous grains; M2)
check.((getControl.(after[1], \grainMode) == 1) and: { getControl.(after[1], \windowShape) == 0.75 }
    and: { getControl.(after[1], \grainSize).equalWithPrecision(0.1) },
    "a grain synth built by voiceOn keeps the voice's grain mode and window, with voiceOn's size");
command.(\setGrainParam, 3, \grainMode, 0);
command.(\setGrainParam, 3, \windowShape, 0.57);
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
checkSynthSetWalk.(9);
checkInvariantWarnings.(3, before);
checkQuietNodeSends.(3, before);
checkFailedStarts.(5, before);
checkFailedStartSwitches.(5, before);
checkFailedStartJudged.([4, 5, 6], before);
checkRegateReportsStarts.(2);

// A re-gated synth whose release ends just as the gate arrives frees
// anyway; the engine starts that synth again
oldTrio = voiceTrio.(2);
server.sendMsg(\n_free, oldTrio[1].nodeID);  // ends without sclang having freed it
0.2.wait; server.sync;
after = voiceTrio.(2);
check.(after[1].notNil and: { after[1] !== oldTrio[1] } and: { after[1].isPlaying }
    and: { synthNames.(context.xg).size == before }, "a running voice's synth that ends unexpectedly is started again");
// ... its voice synth too (synth source only), from the voice's current
// values (voiceControls: freq from voiceOn, fold set since) (#505)
command.(\setVoiceParam, 2, \fold, 0.7); server.sync;
oldTrio = voiceTrio.(2);
server.sendMsg(\n_free, oldTrio[0].nodeID);  // ends without sclang having freed it
0.2.wait; server.sync;
after = voiceTrio.(2);
check.(after[0].notNil and: { after[0] !== oldTrio[0] } and: { after[0].isPlaying }
    and: { getControl.(after[0], \fold).equalWithPrecision(0.7) } and: { getControl.(after[0], \freq) == 220.0 }
    and: { synthNames.(context.xg).size == before },
    "lifecycle: a running voice's voice synth that ends unexpectedly is started again with the voice's values (#505)");
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

// A live synth that frees itself is started again (above), but not in a
// loop (#940; #458 was one at 20 Hz): past restartLimit restarts of a
// voice's synths within restartWindow the next is refused, with one
// invariant line for the run, and the voice is left without that synth
// until its next voiceOn, which starts them as gateVoice starts any synth
// a voice is missing and starts the count again. The rule is driven from
// the voice's own restart times (areaState[\voices][\restarts]), set here,
// so nothing rests on how many round trips fit in a second: first,
// restartLimit restarts older than the window, which no longer count (the
// restart is allowed and they are dropped: without the pruning it would be
// refused); then a run of restartLimit - 1 restarts just now, and the
// voice's voice, grain and mod synths freed on the server together (one
// restart, two refusals, one line). The voice (1) runs on its synth source.
{
    var voice = 1, lines = List.new, limit, window, times, keys, live, old, pruned, restarted, left, healed, onServer, cleared;
    keys = [engine.voiceKey(voice), engine.grainKey(voice), engine.modKey(voice)];
    live = { keys.collect({ arg key; engine.synths[key] }).reject(_.isNil) };
    limit = if (engine.respondsTo(\restartLimit)) { engine.restartLimit } { 32 };
    window = if (engine.respondsTo(\restartWindow)) { engine.restartWindow } { 1 };
    times = engine.areaState[\voices][\restarts] !? { arg all; all[voice] };
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0); server.sync;
    engine.postInvariantWarning = { arg line; lines.add(line) };
    // restarts older than the window: the voice synth is started again
    old = engine.synths[keys[0]];
    times !? { times.clear; limit.do({ times.add(Main.elapsedTime - window - 0.5) }) };
    server.sendMsg(\n_free, old.nodeID);  // ends without sclang having freed it
    server.sync; 0.02.wait; server.sync;  // (the /n_end comes before the sync's reply)
    restarted = engine.synths[keys[0]];
    pruned = [restarted.notNil and: { restarted !== old }, lines.size, times !? _.size];
    // restartLimit - 1 restarts just now: one more is started, the others refused
    times !? { times.clear; (limit - 1).do({ times.add(Main.elapsedTime) }) };
    server.sendBundle(nil, *live.value.collect({ arg synth; [\n_free, synth.nodeID] }));
    server.sync; 0.02.wait; server.sync;
    left = live.value;
    engine.postInvariantWarning = nil;
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0); server.sync;
    cleared = times.notNil and: { times.isEmpty };
    healed = engine.synths[keys[0]];
    onServer = healed.notNil and: { synthNodes.(engine.voiceGroup).any({ arg node; node[\id] == healed.nodeID }) }
        and: { keys.every({ arg key; engine.synths[key].notNil }) };
    check.((limit == 32) and: { window == 1 } and: { pruned == [true, 0, 1] },
        "lifecycle: restarts older than restartWindow no longer count: a voice with restartLimit of them restarts its synth (#940; restarted, invariant lines, restart times kept: %)".format(
            pruned));
    check.((left.size == 1) and: { lines.size == 1 } and: { lines[0].contains("restart") } and: { onServer } and: { cleared },
        "lifecycle: a voice whose live synth frees itself more than restartLimit times in a second stops restarting, with one invariant line (#940; of three freed, % started again, % lines, started at the next voiceOn %, its count started again %)".format(
            left.size, lines.size, onServer, cleared));
    h.stopAllVoices;
}.value;

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
    // (3.7: the scan is a speed, ruling 29: 1 crosses the 2 s slot in 2 s, as 3.6's 0.5 loops a second did)
    [\posSpread, 0, \panSpread, 0, \panJitter, 0, \bufPos, 0, \loopStart, 0, \loopLength, 1, \scrubRate, 0, \scanHold, 0, \bufScan, 1].pairsDo({ arg name, value;
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
            [\setGrainParam, voice, \windowShape, 0.57], [\setGrainParam, voice, \grainMode, mode],
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

// The switch and recall stress with chords held (3.5): five voices (0-4)
// each hold a chord of four (the own note and three extra notes, slots 1-3:
// 15 extra notes, within the pool of 16, where seven voices' 21 would not
// fit) through the same bursts, spaced switches and fast stop / source /
// start / switch cycles as above, voice 4 switched and voice 3 cycled (it
// plays its chord again at each start, as a held chord's keys would). Each
// switch cuts the switched voice's notes and restarts the live ones on the
// new source, so the own synths keep their bounds above, counted without the
// note synths, every slot holds at most one live and one cutting synth, the
// live notes stay three a voice, within the pool, and after each stress the
// note synths the server runs are exactly those the slots hold
// (h.noteNodesAgree, one /g_queryTree)
{
    var voice = 4, cycleVoice = 3, chordVoices = [0, 1, 2, 3, 4], slots = engine.areaState[\notes] !? { arg state; state[\slots] };
    var bursts = [1, 2, 0, 9, 0, 3, 4, 0, 5, 6], cycles = [[9, 3], [0, 9], [4, 0], [9, 0], [4, 3], [0, 9]];
    var chord = { arg target;
        (1 .. 3).do({ arg slot;
            command.(\noteExpression, target, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
            command.(\noteOn, target, slot, 60.0 + slot, 110.0 * (1 + (slot / 4)), 1.0, 1.0);
        });
    };
    // the node IDs of every note synth the notes area tracks (live,
    // releasing or cutting)
    var noteIDs = {
        (slots ? []).collect({ arg records; records.copyToEnd(1).collect({ arg record; [record[\synth], record[\cutting]] }) })
            .flatten(2).reject(_.isNil).collect(_.nodeID).as(IdentitySet)
    };
    var slotsBounded = {
        (slots ? []).every({ arg records; records.copyToEnd(1).every({ arg record; record[\state] != \live or: { record[\synth].notNil } }) })
            and: { (slots ? []).sum({ arg records; records.copyToEnd(1).count({ arg record; [\live, \releasing].includes(record[\state]) }) })
                <= engine.areaState[\notes][\pool] }
            and: { (slots ? []).sum({ arg records; records.copyToEnd(1).count({ arg record; record[\cutting].notNil }) })
                <= engine.areaState[\notes][\pool] }
    };
    var liveNotes = { arg target; slots !? { slots[target].copyToEnd(1).count({ arg record; record[\state] == \live }) } ? 0 };
    var chordsHeld = { chordVoices.every({ arg each; liveNotes.(each) == 3 }) };
    // the voice's own grain synths and voice synths on the server, without its notes'
    var ownCounts = { arg target;
        var nodes = synthNodes.(context.xg), ids = noteIDs.value, own = nodes.reject({ arg node; ids.includes(node[\id]) });
        [voiceGrainNodes.(own, target).size,
            own.count({ arg node; (node.def == engine.voiceDefFor(target)) and: { node.controls[\out].asInteger == engine.granBuses[target].index } })]
    };
    var grainBefore, voiceBefore, grainCount, voiceCount, bounded = true, live = List.new, maxGrain = 0, maxVoice = 0;
    var trackedGrains = 0, trackedVoices = 0, agree = List.new;
    command.(\setNotePool, 16);
    chordVoices.do({ arg each;
        command.(\setGrainSource, each, 0);
        command.(\voiceOn, each, 110.0 + each, 0.2, 0.0, 0.1, 10.0, 1.0);
        chord.(each);
    });
    server.sync; 0.3.wait; server.sync;
    # grainBefore, voiceBefore = ownCounts.(voice);
    // a burst of ten switches at once
    bursts.do({ arg source; command.(\setGrainSource, voice, source); bounded = bounded and: { slotsBounded.value } });
    live.add(chordsHeld.value);
    0.3.wait; server.sync;
    # grainCount, voiceCount = ownCounts.(voice);
    agree.add(h.noteNodesAgree);
    check.((grainCount == (grainBefore + 1)) and: { voiceCount == (voiceBefore - 1) } and: { bounded } and: { live.last }
        and: { agree.last[0] },
        "lifecycle: with a chord of four held on five voices, 10 source switches leave the own live grain synth and one releasing, and cut the own voice synth (% grain and % voice synths of its own, % and % before; slots bounded %, chords held %, the server's note synths the slots' %)".format(
            grainCount, voiceCount, grainBefore, voiceBefore, bounded, live.last, agree.last[0]));
    command.(\setGrainSource, voice, 0); 2.5.wait; server.sync;
    // the same switches 0.2 s apart
    # grainBefore, voiceBefore = ownCounts.(voice);
    bounded = true; live.clear;
    bursts.do({ arg source;
        command.(\setGrainSource, voice, source);
        bounded = bounded and: { slotsBounded.value };
        live.add(chordsHeld.value);
        0.2.wait; server.sync;
        # grainCount, voiceCount = ownCounts.(voice);
        maxGrain = max(maxGrain, grainCount);
        maxVoice = max(maxVoice, voiceCount);
    });
    agree.add(h.noteNodesAgree);
    check.((maxGrain <= (grainBefore + 1)) and: { maxVoice <= (voiceBefore + 1) } and: { bounded } and: { live.every(_ == true) }
        and: { agree.last[0] },
        "lifecycle: with a chord of four held on five voices, switches 0.2 s apart keep at most the own live grain synth and one releasing, and one releasing voice synth (at most % grain and % voice synths of its own, % and % before; slots bounded %, chords held %, the server's note synths the slots' %)".format(
            maxGrain, maxVoice, grainBefore, voiceBefore, bounded, live.every(_ == true), agree.last[0]));
    command.(\setGrainSource, voice, 0); 2.5.wait; server.sync;
    // the fast stop / source / start / switch cycles on voice 3, its chord
    // played again at each start, the other four voices' chords held; the
    // own synths counted as checkStopStartCycles counts them (the engine's
    // tracking, after every command, without a yield)
    bounded = true;
    cycles.do({ arg sources;
        [{ command.(\voiceOff, cycleVoice) }, { command.(\setGrainSource, cycleVoice, sources[0]) },
            { command.(\voiceOn, cycleVoice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); chord.(cycleVoice) },
            { command.(\setGrainSource, cycleVoice, sources[1]) }].do({ arg step;
            var held = IdentitySet.new;
            step.value;
            [engine.synths, engine.releasingSynths[cycleVoice]].do({ arg dict;
                [engine.voiceKey(cycleVoice), engine.grainKey(cycleVoice)].do({ arg key; dict[key] !? { arg synth; held.add(synth) } });
            });
            held.addAll(engine.fadingSynths[cycleVoice]); held.addAll(engine.cuttingSynths[cycleVoice]);
            trackedGrains = max(trackedGrains, held.count({ arg synth; grainDefs.includes(synth.defName.asSymbol) }));
            trackedVoices = max(trackedVoices, held.count({ arg synth; synth.defName.asSymbol == engine.voiceDefFor(cycleVoice) }));
            bounded = bounded and: { slotsBounded.value };
        });
    });
    server.sync; 0.1.wait; server.sync;
    agree.add(h.noteNodesAgree);
    check.((trackedGrains <= 3) and: { trackedVoices <= 3 } and: { trackedVoices >= 2 } and: { bounded } and: { chordsHeld.value }
        and: { agree.last[0] },
        "lifecycle: with a chord of four held on five voices, six fast stop / source / start / switch cycles hold at most three own grain synths and three own voice synths after every command (worst % and %; slots bounded %, chords held %, the server's note synths the slots' % (server %, slots %))".format(
            trackedGrains, trackedVoices, bounded, chordsHeld.value, agree.last[0], agree.last[1].size, agree.last[2].size));
    command.(\setGrainSource, cycleVoice, 0);
    h.stopAllVoices;
    command.(\setNotePool, 0);
    server.sync;
}.value;
}
