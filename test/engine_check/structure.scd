// test/engine_check/structure.scd
// The engine's structure: every SynthDef is built, the command signatures,
// the state of a fresh engine (empty slots, synth sources, the live input),
// commands on a never-started voice, node ordering inside context.xg, and
// free (on a second engine, with fades still pending). Runs first, so the
// fresh-engine checks see the engine as alloc left it.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var formatOf = { arg name; h.formatOf(name) };
var synthNames = { arg group; h.synthNames(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var voiceDefs = h.voiceDefs, allDefs = h.allDefs, grainDefs = h.grainDefs, chainDefs = h.chainDefs;
var names, voiceNames, grainIndices, firstGrain, other, otherLine;

// free with fades still pending (#22, #47): with a long fade wait, a
// clear, a load and a recording on slots that running voices read (voices 1-3,
// engine 0-2, read slots 1-3), then free at once. Nothing that waited runs
// afterward: no zeroing, read or record synth reaches the freed buffers and
// nodes (the server reports no failure) and no slot change completes. Frees
// the engine (a second instance, so the other areas keep theirs).
var freeDuringPendingFades = { arg engine, stereoPath;
    var command = { arg name ... args; h.commandTo(engine, name, *args) };
    var fails = List.new, watcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr), waiting;
    var sent, realAddr, nodeFrees, bufferFrees;
    engine.bufferFadeWait = 0.5;
    command.(\clearBuffer, 0);
    command.(\loadBuffer, 1, stereoPath, 0);
    command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0);
    waiting = (0..2).every({ arg slot; engine.slotPlaying(slot) }) and: { engine.recordSynths[2].notNil };
    // every message free sends, in order (free never yields, so only the
    // engine's messages pass through the recording address meanwhile)
    // (Server.addr_ reads addr and isLocal; Server.sendMsg, listSendMsg,
    // sendBundle and listSendBundle all go through sendMsg and sendBundle)
    sent = List.new; realAddr = server.addr;
    protect {
        server.addr = (
            addr: realAddr.addr, port: realAddr.port, isLocal: realAddr.isLocal,
            sendMsg: { arg self ... msg; sent.add(msg); realAddr.sendMsg(*msg) },
            sendBundle: { arg self, time ... msgs; sent.addAll(msgs); realAddr.sendBundle(time, *msgs) }
        );
        h.freeEngine(engine);
    } { server.addr = realAddr };
    nodeFrees = sent.selectIndices({ arg msg; ["11", "/n_free", "n_free"].includesEqual(msg[0].asString) });
    bufferFrees = sent.selectIndices({ arg msg; ["32", "/b_free", "b_free"].includesEqual(msg[0].asString) });
    check.(nodeFrees.notEmpty and: { bufferFrees.notEmpty } and: { nodeFrees.maxItem < bufferFrees.minItem },
        "free sends every node free before any buffer free (node frees at %, buffer frees from %)".format(
            nodeFrees, bufferFrees.minItem));
    1.0.wait; server.sync;
    watcher.free;
    check.(waiting and: { fails.isEmpty } and: { engine.bufferFrames[1] == 0 } and: { engine.recordSynths.every(_.isNil) },
        "free with a clear, a load and a recording waiting for their fade runs none of them (waiting %, server failures %)".format(
            waiting, fails));
};

// A group's own children, in order: one [node ID, def name] per child (the
// def name nil for a group), from one /g_queryTree
var childrenOf = { arg group;
    var condition = Condition(false), reply, children = List.new, index = 2, parse;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal },
        '/g_queryTree.reply', server.addr).oneShot;
    server.sendMsg('/g_queryTree', group.nodeID, 0);
    if (h.awaitReply(condition).not) { reply = [nil, 0, group.nodeID, 0] };
    // depth 0 is the group itself; a child is listed once its own children are read
    parse = { arg depth;
        var nodeID = reply[index], numChildren = reply[index + 1], def;
        index = index + 2;
        if (numChildren == -1) { def = reply[index].asSymbol; index = index + 1 } { numChildren.do({ parse.(depth + 1) }) };
        if (depth == 1) { children.add([nodeID, def]) };
    };
    parse.(0);
    children.asArray
};

// What an engine still holds after free: [nodes in its context's engine
// group, buses not freed, buffers not freed] (nil state, never made, counts
// as freed)
// line: the delay's line, held before free (freeDelayLine forgets it, so
// a freed engine's state no longer names it; #807); the engine's own while
// it still holds one
var engineLeft = { arg target, line;
    var rings = target.areaState[\rings], record = target.areaState[\record], mix = target.areaState[\mix];
    var outRings = target.areaState[\outRings] ? ();
    var buses = [target.inputBus, target.silentBus, target.mainBus, target.filterBus, target.delayBus, target.reverbBus]
        ++ target.granBuses ++ target.modBuses ++ target.recordFrameBuses ++ (rings[\phaseBuses] ? [])
        ++ (outRings[\phaseBuses] ? [])
        ++ (record[\headBuses] ? []) ++ (record[\voiceTaps] ? []) ++ [record[\tapSink], record[\idleHead]]
        ++ [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].collect({ arg name; mix[name] })
        ++ (mix[\synthPaths] ? []) ++ (mix[\otherPaths] ? []);
    var buffers = (target.areaState[\grains][\windowBank] ? []) ++ target.buffersL ++ target.buffersR
        ++ (rings[\voiceL] ? []) ++ (rings[\voiceR] ? []) ++ [rings[\inputL], rings[\inputR], target.areaState[\scale][\buffer]]
        ++ (target.areaState[\waveform][\peakBuffers] ? []) ++ (outRings[\left] ? []) ++ (outRings[\right] ? [])
        ++ (target.areaState[\effects][\shimmerRings] ? []) ++ (target.areaState[\effects][\delayLine] ? line ? []);
    [childrenOf.(target.context.xg).size, buses.count({ arg bus; bus.notNil and: { bus.index.notNil } }),
        buffers.count({ arg buffer; buffer.notNil and: { buffer.bufnum.notNil } })]
};

// free runs every area's stop and free though one raises (#499): a
// check-only area between the rings (70) and the scale (80), whose stop and
// free raise, is put into a second engine's areas. free reports each (one
// invariant line, captured here), runs on, and leaves no node, bus or
// buffer. Before the fix the first raise ended free: every stop below it
// and every free were skipped.
var checkFreeContained = {
    var target = h.startEngine, lines = List.new, raised, areas, left, delayLine, pastStop;
    target.postInvariantWarning = { arg line; lines.add(line) };
    delayLine = target.delayLine;
    areas = target.instVarAt(\areas);
    // (pastStop: as the engine runs, then as an area's stop meets it, #942)
    pastStop = [target.tryPerform(\pastStop)];
    target.instVarPut(\areas, areas.select({ arg area; area[\order] < 75 })
        ++ [(name: \checkRaises, order: 75,
            stop: { pastStop = pastStop.add(target.tryPerform(\pastStop)); Error("check: this area's stop raises").throw },
            free: { Error("check: this area's free raises").throw })]
        ++ areas.select({ arg area; area[\order] > 75 }));
    try { h.freeEngine(target) } { arg error; raised = error };
    h.freeEngine(target);  // (the commands back to h.engine, should free have raised)
    h.teardownSync("free engine after an area hook");
    left = engineLeft.(target, delayLine);
    check.(raised.isNil and: { delayLine.size == 2 } and: { left == [0, 0, 0] },
        "structure: free frees every node, bus and buffer though an area's stop and free raise (#499; raised: %, left nodes, buses, buffers: %)".format(
            raised !? _.errorString, left));
    // (the message never quotes the lines: run_engine_check.sh would fail on them)
    check.((lines.size == 2) and: { lines.every({ arg line; line.find("checkRaises").notNil }) }
        and: { lines.any({ arg line; line.find("'s stop raised").notNil }) } and: { lines.any({ arg line; line.find("'s free raised").notNil }) },
        "structure: free reports each area phase that raised, by name (% lines)".format(lines.size));
    check.((pastStop[0] == false) and: { pastStop[1] == true },
        "structure: pastStop is false while the engine runs and true once free has begun the stop phase (#942; running, then in an area's stop: %)".format(pastStop));
};

// No frame the engine's SynthDef functions keep points at a freed frame
// (#211): each function's home method frame was called through areaCall,
// so its callers, walked from there, are live method frames up to an
// Engine_Strata:areaCall frame (whose own caller areaCall cleared). Only
// the engine's own defs are walked (their home method is an Engine_Strata
// method); a caller that is not a method frame (a function's, freed when
// it returned: what the rule prevents) ends the walk as a failure before it
// is read any further.
var checkDefCallers = {
    var areaCall = Engine_Strata.findMethod(\areaCall), walked = 0, bad = List.new;
    // (a frame sclang has freed reads as empty: its method is nil)
    var frameMethod = { arg frame; if (frame.isKindOf(Frame)) { try { frame.instVarAt(0) } } };
    SynthDescLib.global.synthDescs.keysValuesDo({ arg name, desc;
        var func = desc.def !? { desc.def.func }, frame, method, found = false, steps = 0;
        if (func.isKindOf(Function)) {
            frame = func.instVarAt(1);  // the function's context
            frame = if (frame.isKindOf(Frame)) { frame.instVarAt(3) };  // its home method frame
            method = frameMethod.(frame);
            if (method.isKindOf(Method) and: { method.ownerClass == Engine_Strata }) {
                walked = walked + 1;
                while { found.not and: { method.isKindOf(Method) } and: { steps < 16 } } {
                    if (method === areaCall) { found = true } {
                        frame = frame.instVarAt(1);  // the caller
                        method = frameMethod.(frame);
                        steps = steps + 1;
                    };
                };
                if (found.not) { bad.add(name) };
            };
        };
    });
    check.((walked >= 20) and: { bad.isEmpty },
        "structure: each engine SynthDef function's home frame was called through areaCall, so it keeps no freed caller (#211; walked %, not through areaCall: %)".format(
            walked, bad.asArray.sort));
};

// alloc that raises frees what it built, then raises again (#499). The
// engine's context reads as norns' does, but its output bus raises when the
// effects area's start asks for it (the master's out): every area's
// allocState has run by then (the slots and rings allocated) and the
// voices', buffers' and effects' nodes partly started. Engine_Strata.new
// runs alloc in a fork of its own, where nothing could catch the error, so
// the engine is made with newCopyArgs, given the state CroneEngine's init
// gives, and the check calls alloc itself. The performance area's files go
// below the check's temp dir, as buildEngine's. Returns (engine, raised,
// lines: the invariant lines it posted, group: its engine group, freed by
// the caller after h.freeEngine, which gives the OSC defs back to h.engine;
// delayLine: the delay's line as alloc raised).
var failingAlloc = {
    var group = Group.tail(server), built = Engine_Strata.newCopyArgs, lines = List.new, raised, delayLine;
    var settings = [Engine_Strata.settingsDir, Engine_Strata.modelPath];
    // (the delay's line is held as the output bus raises: the rollback's
    // freeDelayLine forgets it, #807)
    built.instVarPut(\context, (server: server, xg: group, out_b: {
        delayLine = built.areaState[\effects][\delayLine];
        Error("check: no output bus").throw }));
    built.instVarPut(\commands, List.new);
    built.instVarPut(\commandNames, Dictionary.new);
    built.instVarPut(\pollNames, Set.new);
    built.postInvariantWarning = { arg line; lines.add(line) };
    Engine_Strata.settingsDir = h.tempDir +/+ "settings-rollback/";
    Engine_Strata.modelPath = h.tempDir +/+ "no-board-model";
    try { built.alloc } { arg error; raised = error };
    Engine_Strata.settingsDir = settings[0];
    Engine_Strata.modelPath = settings[1];
    server.sync;
    (engine: built, raised: raised, lines: lines, group: group, delayLine: delayLine)
};

// free after an alloc that raised part way through the rings area's
// allocState (70), with free's two passes over every area (#942): the
// areas below the rings made their state, the rings a part of theirs (the
// voice rings' left buffers), the areas above none, and no area started.
// The voices' stop and the mix area's free meet that (no groups, no mix
// state) and raise nothing (an area phase that raises is one invariant
// line, naming its area). No area can be made to raise inside alloc here,
// so alloc's first steps are run as alloc runs them (the areas, their
// state, each allocState in order), with a part of the rings' own.
var checkFreeAfterPartialAlloc = {
    var group = Group.tail(server), built = Engine_Strata.newCopyArgs, lines = List.new, raised, areas, named;
    var settings = [Engine_Strata.settingsDir, Engine_Strata.modelPath];
    built.instVarPut(\context, (server: server, xg: group, out_b: { Error("check: no output bus").throw }));
    built.instVarPut(\commands, List.new);
    built.instVarPut(\commandNames, Dictionary.new);
    built.instVarPut(\pollNames, Set.new);
    built.postInvariantWarning = { arg line; lines.add(line) };
    Engine_Strata.settingsDir = h.tempDir +/+ "settings-partial/";
    Engine_Strata.modelPath = h.tempDir +/+ "no-board-model";
    try {
        areas = built.strataAreas;
        built.instVarPut(\areas, areas);
        built.instVarPut(\areaState, IdentityDictionary.new);
        areas.do({ arg area; built.areaState[area[\name]] = IdentityDictionary.new });
        built.instVarPut(\grainParamHandlers, IdentityDictionary.new);
        areas.select({ arg area; area[\order] < 70 }).do({ arg area; area[\allocState].value });
        built.areaState[\rings][\voiceL] = Array.fill(built.numVoices, { Buffer.alloc(server, 64, 1) });
        built.free;
    } { arg error; raised = error };
    Engine_Strata.settingsDir = settings[0];
    Engine_Strata.modelPath = settings[1];
    server.sync;
    named = lines.select({ arg line; ["voices", "mix"].any({ arg name; line.find("the " ++ name ++ " area's").notNil }) });
    check.(raised.isNil and: { named.isEmpty },
        "structure: free after an allocState that failed in the rings area raises nothing in voices and mix (#942; raised %, % of % invariant lines name the voices or the mix)".format(
            raised !? _.errorString, named.size, lines.size));
    group.free;
};

// The polls the engine's areas register: every `this.addPoll(\name` in its
// sources (lib/Engine_Strata.sc and lib/engine/Strata*.sc) outside a //
// comment, as the Lua stub reads them, so a new poll needs no change here
var declaredPolls = {
    var classFile = Engine_Strata.filenameSymbol.asString, marker = "this.addPoll(\\", names = Set.new;
    ([classFile] ++ (PathName(classFile).pathOnly +/+ "engine/Strata*.sc").pathMatch).do({ arg path;
        var text = File.readAllString(path);
        (text.findAll(marker) ? []).do({ arg at;
            var lineStart = (text.copyRange(0, at).findBackwards("\n") ? -1) + 1;
            var start = at + marker.size, end = start;
            while { (end < text.size) and: { text[end].isAlphaNum or: { text[end] == $_ } } } { end = end + 1 };
            if (text.copyRange(lineStart, at).find("//").isNil) { names.add(text.copyRange(start, end - 1).asSymbol) };
        });
    });
    names
};

// The rollback also undoes what norns' deinit would (Crone calls it only on
// an engine whose alloc returned): the commands' OSC defs are freed, and
// the polls another engine holds under the same names (h.engine's, here:
// CronePollRegistry keeps the first poll of a name) stay that engine's.
var checkAllocRolledBack = {
    var names = engine.pollNames.asArray, held = names.collect({ arg name; CronePollRegistry.getPollFromName(name) });
    var failed = failingAlloc.value, built = failed[\engine], lines = failed[\lines], raised = failed[\raised];
    var left = engineLeft.(built, failed[\delayLine]), defsLeft = built.commands.select({ arg command; OSCdef.all[command.name].notNil });
    check.((raised !? { raised.errorString.find("check: no output bus").notNil }) == true,
        "structure: alloc raises the error that stopped it again (#499; got %)".format(raised !? _.errorString));
    check.((failed[\delayLine].size == 2) and: { left == [0, 0, 0] },
        "structure: alloc that raises leaves no node, bus or buffer of what it built, the delay's line among them (#499, #807; line held: %, left nodes, buses, buffers: %)".format(
            failed[\delayLine].size, left));
    // every area that had begun stops and frees what it partly made without
    // raising (an area phase that raised would be reported in a line; the
    // message names the phases without quoting the lines)
    check.(lines.isEmpty, "structure: alloc's rollback raises in no area's stop or free (% reported: %)".format(lines.size,
        lines.collect({ arg line; line.copyRange(line.find("the ") ? 0, (line.find(" raised") ? line.size) - 1) })));
    check.(built.commands.notEmpty and: { defsLeft.isEmpty },
        "structure: alloc that raises frees its commands' OSC defs (#499; % commands, % left)".format(built.commands.size, defsLeft.size));
    check.((names.asSet == declaredPolls.value) and: { names.notEmpty }
        and: { names.every({ arg name, index; CronePollRegistry.getPollFromName(name) === held[index] }) },
        "structure: alloc that raises leaves the polls another engine holds under its names (% of the engine's %)".format(names, declaredPolls.value.asArray));
    h.freeEngine(built);  // (the commands back to h.engine)
    h.teardownSync("free engine after partial alloc");
    failed[\group].free;
};

// A rolled-back engine leaves no poll of its own (#499). Polls a failed
// alloc registered stayed in norns' CronePollRegistry, which keeps the
// first poll of a name, so the next engine got the dead one's: its periodic
// bufferState reported the dead engine's slots. On norns a failed load is
// the only engine; here h.engine's polls are taken out of the registry
// first, so the failing engine registers its own, then a new engine is
// built, loads slot 1 (0.5 s) and must report it through the registry's
// bufferState (its function, called here: one slot per call, then the
// slots' length). Afterward h.engine's polls go back, the very objects h.engine
// holds, at their indices (h.pollValues reads by index), running as before
// (h.putBackPolls): copies registered in their place were never started, and
// an engine a later area built (the files area's 60 s save) reported through
// them, so its reports never arrived (#652).
var checkRollbackPolls = {
    var names = engine.pollNames.asArray.sort({ arg a, b;
        CronePollRegistry.getPollFromName(a).index < CronePollRegistry.getPollFromName(b).index });
    var held = names.collect({ arg name; CronePollRegistry.getPollFromName(name) });
    var running = held.collect({ arg poll; poll.instVarAt(\isRunning) == true });
    var failed, fresh, left, reports, slotOne, restored;
    names.do({ arg name; CronePollRegistry.remove(name) });
    failed = failingAlloc.value;
    left = names.select({ arg name; CronePollRegistry.getPollFromName(name).notNil });
    fresh = h.startEngine;
    h.commandTo(fresh, \loadBuffer, 0, h.stereoPath, 0);
    h.waitFor({ fresh.bufferFrames[0] > 0 }, 3);
    reports = (fresh.numBuffers + 1).collect({ CronePollRegistry.getPollFromName(\bufferState).instVarAt(\function).value });
    // slot index 0's report: its thousands are (load number * (numBuffers + 1) + 0) (#578)
    slotOne = reports.detect({ arg value; ((value / fresh.bufferStateStride).floor.asInteger % (fresh.numBuffers + 1)) == 0 });
    h.freeEngine(failed[\engine]);
    h.freeEngine(fresh);
    h.teardownSync("free rollback engines");
    failed[\group].free;
    // h.engine's polls back: the very objects, at their indices, running as before
    h.putBackPolls(held.collect({ arg poll, index; [poll, running[index]] }));
    restored = held.every({ arg poll, index;
        (CronePollRegistry.getPollFromName(poll.name) === poll) and: { CronePollRegistry.getPollFromIndex(poll.index) === poll }
            and: { (poll.instVarAt(\isRunning) == true) == running[index] } });
    check.(left.isEmpty, "structure: alloc that raises leaves no poll of its own in norns' poll registry (#499; left: %)".format(left));
    // its own slot 1 after its one load: (1 * 9 + 0) * 1000 + 0.5 s (the dead engine's would read 0)
    check.((slotOne !? { (slotOne - 9000.5).abs < 0.01 }) == true,
        "structure: the engine built after a failed one reports its own slots through bufferState (#499; slot 1 reads %)".format(slotOne));
    check.(restored and: { names.notEmpty } and: { names.asSet == declaredPolls.value },
        "structure: h.engine's polls are back in the registry, the same objects at their indices, running as before (#652; % of the engine's %)".format(
            names, declaredPolls.value.asArray));
};

// 3.7's voiceHit (design §0.2): an area's optional hook hears a voice's
// start (voiceOn on a stopped voice, a releasing one included), a retrigger
// (of a valid voice, running or not) and an extra note that sounds
// (extraNoteOn, where it opens the step gate: a start or a re-strike), each
// once per area, in ascending order, with the voice and the kind, a start
// once the voice runs (after voiceOn's bundle). A running
// voice's voiceOn, a refused extra note (the pool full, the voice stopped)
// and an invalid voice tell nothing. Two check-only areas between the rings
// (70) and the scale (80), at orders no other check uses, are put into
// h.engine's areas for the time and record their calls (h.engine's own
// areas have no hook: the checks above and every other area play as before)
var checkVoiceHit = {
    var voice = 3, calls = List.new, areas = engine.instVarAt(\areas), failed = List.new;
    // each call records whether the voice runs as the hook hears it: true at
    // \start proves the hit comes after voiceOn's bundle (gateVoice)
    var hook = { arg order; { arg hitVoice, kind; calls.add([order, hitVoice, kind, engine.voiceRunning(hitVoice)]) } };
    var both = { arg kind, running = true; [[76, voice, kind, running], [77, voice, kind, running]] };
    var expect = { arg what, expected; var got = calls.asArray; calls.clear; if (got != expected) { failed.add([what, got]) } };
    engine.instVarPut(\areas, areas.select({ arg area; area[\order] < 76 })
        ++ [(name: \checkHitFirst, order: 76, voiceHit: hook.(76)), (name: \checkHitSecond, order: 77, voiceHit: hook.(77))]
        ++ areas.select({ arg area; area[\order] > 77 }));
    protect {
        command.(\setNotePool, 1);
        command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
        expect.(\startStopped, both.(\start));
        command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
        expect.(\startRunning, []);
        command.(\retrigger, voice, 0.8);
        expect.(\retrigger, both.(\retrigger));
        command.(\noteOn, voice, 1, 64.0, 329.63, 1.26, 0.8);
        expect.(\noteStart, both.(\note));
        command.(\noteOn, voice, 1, 65.0, 349.23, 1.33, 0.8);
        expect.(\noteRestrike, both.(\note));
        command.(\noteOn, voice, 2, 67.0, 392.0, 1.5, 0.8);
        expect.(\notePoolFull, []);
        command.(\voiceOff, voice);
        expect.(\voiceOff, []);
        command.(\noteOn, voice, 2, 67.0, 392.0, 1.5, 0.8);
        expect.(\noteVoiceStopped, []);
        command.(\retrigger, voice, 0.8);
        expect.(\retriggerStopped, both.(\retrigger, false));
        command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
        expect.(\startReleasing, both.(\start));
        command.(\voiceOn, 99, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
        command.(\retrigger, 99, 0.8);
        expect.(\invalidVoice, []);
    } {
        engine.instVarPut(\areas, areas);
        command.(\setNotePool, 0);
    };
    h.stopAllVoices;
    check.(failed.isEmpty,
        "structure: voiceHit runs every area's hook in order with the voice and the kind (wrong: %)".format(failed.asArray));
};

// SynthDefs
allDefs.do({ arg name;
    check.(SynthDescLib.global.at(name).notNil, "SynthDef % built".format(name));
});

// Command signatures
check.(formatOf.(\voiceOn) == "iffffff", "voiceOn signature is iffffff (C1)");
check.(formatOf.(\retrigger) == "if", "retrigger signature is if (voice, velocity)");
check.(formatOf.(\setFilter) == "ffif", "setFilter signature is ffif");
check.(formatOf.(\setDelay) == "ffff", "setDelay signature is ffff");
check.(formatOf.(\setGrainSource) == "ii", "setGrainSource ii");
check.(formatOf.(\loadBuffer) == "isf" and: { formatOf.(\recordBuffer) == "ifffififf" }
    and: { formatOf.(\clearBuffer) == "i" } and: { formatOf.(\saveBuffer) == "isff" }
    and: { formatOf.(\stopRecord) == "i" }, "buffer command signatures");

// A fresh engine: empty slots, every voice on its synth, the live input
check.(engine.bufferFrames == Array.fill(8, 0), "every slot starts empty");
check.(engine.grainSource == Array.fill(engine.numVoices, 0), "every voice starts on its synth source");
check.(engine.inputBus.numChannels == 2 and: { engine.inputBus.rate == \audio }, "inputBus is a stereo audio bus");
check.(engine.inputSynth.defName == \strataInput
    and: { getControl.(engine.inputSynth, \out) == engine.inputBus.index }, "strataInput writes inputBus");
names = synthNames.(engine.voiceGroup);
check.(names.asArray == ([\strataInput] ++ (\strataRingWrite ! (engine.numVoices + 1))),
    "strataInput and the ring writers run in the voice group (got %)".format(names));

// Commands on never-started voices must not throw (M6)
command.(\voiceOff, 2);
command.(\setVoiceParam, 2, \fold, 2.0);
command.(\setGrainParam, 2, \grainSize, 0.2);
command.(\setModSource, 2, 1, 0);
command.(\setModAmpAmt, 2, 1, 0.5);
command.(\setModFreqAmt, 2, 1, 0.5);
command.(\setModSpeed, 2, 5.0);
command.(\retrigger, 2, 1.0);
command.(\setGrainParam, 2, \bufPos, 0.5);
command.(\setGrainSource, 2, 0);
check.(true, "commands on a never-started voice do not throw (M6)");

// Node ordering inside context.xg (M5)
h.startAllVoices;
// (the record area's tap group, after the master, is checked below with xg's own nodes)
names = synthNames.(context.xg).reject({ arg name; [\strataTapPreMaster, \strataRecord, \strataOutRingWrite].includes(name) });
voiceNames = names.select({ arg name; voiceDefs.includes(name) });
grainIndices = names.collect({ arg name, index; if (grainDefs.includes(name) or: { name == \strataMod }) { index } }).reject(_.isNil);
firstGrain = grainIndices.minItem;
check.(names.size == (1 + ((engine.numVoices - 1) * 3) + 2 + 1 + (engine.numVoices + 1) + engine.numVoices + 6),
    "xg holds the offset node, % voice trios, 1 buffer voice (grain + mod), the input synth, the ring writers, the stages, filter x3, delay, reverb and master (got %)".format(
        engine.numVoices - 1, names.size));
check.(names.indexOf(\strataInput) < firstGrain, "the input synth runs before grain synths");
check.(names.indexOf(voiceNames.last) < firstGrain, "voices run before grain/mod synths");
check.(grainIndices.maxItem < names.indexOf(\strataFilter), "grain/mod synths run before the effects chain");
if (engine.respondsTo(\voiceMixKey).not) {
    check.(false, "structure: the node order is voiceGroup, processGroup (synth-source grain synths, then each voice's mix group before its mod synth), then the effects chain");
} {
    // the groups' order in the engine group's tree: voiceGroup, processGroup,
    // then the effects chain; inside processGroup the synth-source grain
    // synths (head), then each voice's mix group, its mod synth just after it
    var nodes = h.synthTree(context.xg), synthPaths, firstStage, lastSynthGrain;
    var positionOf = { arg def; nodes.detectIndex({ arg node; node.def == def }) };
    var stageAndMod = { arg voice;
        var stageAt = nodes.detectIndex({ arg node; (node.def == \strataVoiceMix) and: { node.controls[\mirrorOut] == engine.granBuses[voice].index } });
        var modAt = nodes.detectIndex({ arg node; (node.def == \strataMod) and: { node.controls[\in] == engine.granBuses[voice].index } });
        [stageAt, modAt]
    };
    synthPaths = engine.areaState[\mix][\synthPaths].collect(_.index);
    firstStage = nodes.detectIndex({ arg node; node.def == \strataVoiceMix });
    lastSynthGrain = nodes.selectIndices({ arg node; (node.def == \strataGrainRing) and: { synthPaths.includes(node.controls[\out].asInteger) } }).maxItem;
    check.((positionOf.(\strataInput) < firstStage) and: { nodes.detectIndex({ arg node; node.def == voiceDefs[0] }) < firstStage }
        and: { lastSynthGrain.notNil } and: { lastSynthGrain < firstStage }
        and: { (0..engine.numVoices - 1).every({ arg voice;
            var pair = stageAndMod.(voice); pair[0].notNil and: { pair[1].notNil } and: { pair[1] == (pair[0] + 1) } }) }
        and: { firstStage < positionOf.(\strataFilter) },
        "structure: the node order is voiceGroup, processGroup (synth-source grain synths, then each voice's mix group before its mod synth), then the effects chain");
};
check.(names.copyRange(names.size - 4, names.size - 1).asArray == chainDefs,
    "xg ends filter -> delay -> reverb -> master (got %)".format(names.copyRange(names.size - 4, names.size - 1)));
// xg's own nodes, in order (#525: the flat list above leaves out the tap
// group): the modulation area's fastModGroup (3.4), the voice and process
// groups, the effects chain, the master, then the record area's tap group,
// last, with strataTapPreMaster at its head
{
    var tapGroup = engine.areaState[\record][\tapGroup], children = childrenOf.(context.xg);
    var expected = [engine.areaState[\modulation][\fastModGroup].nodeID, engine.voiceGroup.nodeID, engine.processGroup.nodeID]
        ++ engine.effectChainKeys.collect({ arg key; engine.synths[key].nodeID }) ++ [tapGroup.nodeID];
    var tapHead = childrenOf.(tapGroup).first;
    check.((children.collect(_[0]) == expected) and: { children.last[1].isNil }
        and: { tapHead.notNil } and: { tapHead[1] == \strataTapPreMaster },
        "structure: xg runs fastModGroup, voiceGroup, processGroup, filter x3, delay, reverb, master, then the tap group, last, strataTapPreMaster at its head (#525; got %)".format(
            children.collect({ arg child; child[1] ? \group })));
}.value;
// 3.4's fastModGroup heads the engine's group, with the offset node first
// in it, so the offsets are written before anything reads them in a block
{
    var children = childrenOf.(context.xg), group = engine.areaState[\modulation][\fastModGroup];
    var inside = group !? { childrenOf.(group) } ? [];
    check.(group.notNil and: { children.notEmpty } and: { children[0][0] == group.nodeID } and: { children[0][1].isNil }
        and: { inside.notEmpty } and: { inside[0][1] == \strataFastOffsets },
        "structure: fastModGroup is the first node of the engine's group (xg's first node %, fastModGroup %, its first node %)".format(
            children.first, group !? _.nodeID, inside.first));
}.value;
check.(synthNames.(context.og).includes(\strataMaster).not, "master is not placed after og (M5)");
h.stopAllVoices;

// The 3.3 surface
check.(engine.strataAreas.select({ arg area; [\record, \waveform, \positions].includes(area[\name]) })
    .collect({ arg area; [area[\name], area[\order]] }) == [[\record, 130], [\waveform, 140], [\positions, 150]],
    "structure: the record, waveform and positions areas run at orders 130, 140 and 150");
check.(grainDefs.every({ arg name;
        var controls = SynthDescLib.global.at(name).controlNames.collect(_.asSymbol);
        [\recHeadBus, \scrubRate, \scanHold, \t_scanReset].every({ arg control; controls.includes(control) })
    }), "structure: both grain defs declare recHeadBus, scrubRate, scanHold and t_scanReset");
check.((engine.waveformPoints == 64) and: { engine.areaState[\waveform][\peakBuffers].size == 8 }
    and: { engine.areaState[\waveform][\peakBuffers].every({ arg buffer; (buffer.numFrames == 64) and: { buffer.numChannels == 1 } }) },
    "structure: waveformPoints is 64 and the waveform area holds eight 64-frame peak buffers");
engine.numVoices.do({ arg voice;
    command.(\setGrainSource, voice, voice + 1);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
});
server.sync;
check.(engine.numVoices.collect({ arg voice;
        var control = getControl.(engine.synths[engine.grainKey(voice)], \recHeadBus);
        (control == engine.slotHeadBus(voice).index) and: { control != engine.areaState[\record][\idleHead].index }
    }).every(_ == true), "structure: every buffer grain synth gets its slot's recHeadBus");
h.stopAllVoices;

// A triggered buffer grain, from the engine's def and from the copy of 3.2's
// in the check (h.def32), both with no spreads: identical on the server
{
    var rate = server.sampleRate.asInteger, path = h.tempDir +/+ "structure-grain.wav";
    var period = Array.fill(1000, { arg i; sin(2pi * 7 * i / 1000) * 0.5 });
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    var buses = 2.collect({ Bus.audio(server, 2) }), sink = Bus.audio(server, 2), peaks = Bus.control(server, 2);
    var group = Group.after(engine.processGroup), ids, values;
    var args = { arg out; [\out, out, \mirrorOut, sink, \bufnumL, engine.buffersL[0].bufnum, \bufnumR, engine.buffersR[0].bufnum,
        \bufRateScale, 1, \bufFrames, rate * 2, \bufPos, 0.25, \grainSize, 0.1, \grainMode, 1, \posSpread, 0, \panSpread, 0,
        \delaySendOut, sink.index, \reverbSendOut, sink.index] };
    file.openWrite(path);
    h.writePeriodicSeconds(file, period, 2, rate);
    file.close;
    command.(\loadBuffer, 0, path, 0);
    h.waitFor({ engine.bufferFrames[0] > 0 });
    ids = 2.collect({ server.nextNodeID });
    // both grain synths in one bundle, so both start in one block
    // (3.2's def has the sends: at 0 its dry output is the signal itself)
    server.sendBundle(nil,
        (['/s_new', \strataGrainBuf, ids[0], 1, group.nodeID] ++ args.(buses[0])).asOSCArgArray,
        (['/s_new', h.def32[\grainBuf], ids[1], 1, group.nodeID] ++ args.(buses[1]) ++ [\delaySend, 0, \reverbSend, 0]).asOSCArgArray);
    server.sync;
    Synth(\strataCheckBusDiff, [\a, buses[0], \b, buses[1], \out, peaks], group, \addToTail);
    0.3.wait;                  // past the grain synths' attack
    server.sendBundle(nil, ['/n_set', ids[0], \t_trig, 1], ['/n_set', ids[1], \t_trig, 1]);
    0.3.wait; server.sync;
    values = h.readBus(peaks);
    group.free; server.sync;
    command.(\clearBuffer, 0);
    buses.do(_.free); sink.free; peaks.free;
    check.((values[1] > 0.001) and: { values[0] < 1e-6 },
        "structure: a triggered buffer grain with spreads 0 matches 3.2's within 1e-6 (difference %, level %)".format(values[0], values[1]));
}.value;

// free, on a second engine whose voices 1-3 read slots 1-3
other = h.startEngine;
3.do({ arg voice;
    h.commandTo(other, \setGrainSource, voice, voice + 1);
    h.commandTo(other, \voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 20.0, 1.0);
});
server.sync; 0.2.wait;
otherLine = other.delayLine;  // (free forgets it: freeDelayLine, #807)
freeDuringPendingFades.(other, h.stereoPath);
h.teardownSync("free engine during pending fades");
check.(synthNames.(other.context.xg).size == 0, "free removes every engine node");
check.((other.areaState[\grains][\windowBank] ? []).notEmpty
    and: { other.areaState[\grains][\windowBank].every({ arg buffer; buffer.bufnum.isNil }) }, "free frees the window bank");
check.((other.buffersL ++ other.buffersR).every({ arg buffer; buffer.bufnum.isNil }), "free frees the buffer slots");
check.(([other.inputBus, other.silentBus, other.mainBus, other.filterBus, other.delayBus, other.reverbBus]
    ++ other.granBuses ++ other.modBuses ++ other.recordFrameBuses).every({ arg bus; bus.index.isNil }),
    "free frees every engine bus");
check.((other.areaState[\record][\headBuses] ++ other.areaState[\record][\voiceTaps]
        ++ [other.areaState[\record][\tapSink], other.areaState[\record][\idleHead]]).every({ arg bus; bus.index.isNil })
    and: { other.areaState[\waveform][\peakBuffers].every({ arg buffer; buffer.bufnum.isNil }) },
    "structure: free frees the head buses, the voice taps and the peak buffers");
// (3.8) the output rings, their phase buses and their writers
check.((other.areaState[\outRings][\left] ++ other.areaState[\outRings][\right]).every({ arg buffer; buffer.bufnum.isNil })
    and: { other.areaState[\outRings][\phaseBuses].every({ arg bus; bus.index.isNil }) }
    and: { other.outRingWriterKeys.every({ arg key; other.synths[key].isNil }) },
    "structure: free frees the output rings, their phase buses and their writers");
check.((otherLine.size == 2) and: { otherLine.every({ arg buffer; buffer.bufnum.isNil }) },
    "structure: free frees the delay's line (#807; % buffers held)".format(otherLine.size));
// (engineLeft counts a running engine's nodes, buses and buffers, and none of a freed one's)
check.(engineLeft.(engine).every(_ > 0) and: { engineLeft.(other, otherLine) == [0, 0, 0] },
    "structure: engineLeft counts what an engine holds (running %, freed %)".format(engineLeft.(engine),
        engineLeft.(other, otherLine)));
// (#807) and a delay's line held before free while its two buffers are
// still allocated, as a free that left the line would leave them. The
// engine's own free left so (freeDelayLine forgetting the line without
// freeing its buffers: #837's mutation, reverted) fails four checks here:
// "free frees the delay's line", "engineLeft counts what an engine holds"
// (freed [0, 0, 2]), and checkFreeContained's and checkAllocRolledBack's
// (each left [0, 0, 2])
{
    var kept = 2.collect({ Buffer.alloc(server, 64, 1) }), counted;
    server.sync;
    counted = engineLeft.(other, kept);
    kept.do(_.free); server.sync;
    check.(counted == [0, 0, 2], "structure: engineLeft counts a delay's line free left allocated (#807; counted %)".format(counted));
}.value;

// Drop the first sync reply, then every reply to each kind of barrier. An
// 8 s safety release lets even an unbounded implementation return.
[['/synced', true], ['/synced', false], ['/g_queryTree.reply', false]].do({ arg test;
    var path = test[0], allowRetry = test[1], dispatcher = OSCFunc.defaultDispatcher;
    var first, seen = 0, timer, raised, elapsed, start, released = false;
    var keeper = OSCFunc({}, '/strataCheckTeardown', server.addr);
    var filter = { arg msg, time, addr, port;
        if ((addr == server.addr) and: { msg[0] == path }
            and: { first.isNil or: { msg == first } }) {
            seen = seen + 1;
            if (first.isNil) {
                first = msg;
                timer = Routine({ released = true; dispatcher.value(msg, time, addr, port) });
                SystemClock.schedAbs(Main.elapsedTime + 8, timer);
            } {
                if (allowRetry) { dispatcher.value(msg, time, addr, port) };
            };
        } { dispatcher.value(msg, time, addr, port) }
    };
    thisProcess.replaceOSCRecvFunc(dispatcher, filter);
    protect {
        start = Main.elapsedTime;
        try { h.stopAllVoices } { arg error; raised = error.errorString };
        elapsed = Main.elapsedTime - start;
    } {
        thisProcess.replaceOSCRecvFunc(filter, dispatcher);
        timer !? { timer.stop };
        keeper.free;
    };
    if (allowRetry) {
        check.((seen == 2) and: { released.not } and: { raised.isNil },
            "structure: a stop whose first /synced was dropped completes on the same sync ID's second reply (% replies, %)"
                .format(seen, raised));
    } {
        check.((seen == if (path == '/synced') { 2 } { 1 }) and: { released.not } and: { raised.notNil }
            and: { raised.contains("structure teardown: stop voices") } and: { raised.contains(path.asString) },
            "structure: teardown identifies withheld % replies before the safety release (% replies in % s, %)"
                .format(path, seen, elapsed.round(0.01), raised));
    };
});
h.stopAllVoices;

checkVoiceHit.value;
checkFreeContained.value;
checkAllocRolledBack.value;
checkFreeAfterPartialAlloc.value;
checkRollbackPolls.value;
checkDefCallers.value;
}
