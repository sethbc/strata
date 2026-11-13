// test/engine_check/notes.scd
// The notes area (lib/engine/StrataNotes.sc, 3.5): its order, its literals
// and state, its four commands' checks (each checks its indices and that
// every continuous argument is finite: a bad one is ignored with one line;
// it clips its continuous arguments and records them), and the note
// lifecycle: extra notes as synths in their slots (a buffer or input voice's
// a grain synth of its own), what reaches them, their release and cut, and
// failed starts. See docs/notes/engine/notes.md.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var area = engine.strataAreas.detect({ arg each; each[\name] == \notes });
var state = engine.areaState[\notes];
var nan = 0.0 / 0.0;
var nodeCounts, sameReceived, withIgnoredLines, checkState, checkSignatures, checkNoNodes, checkRecorded, checkIgnored;
var checkHookRestored, checkPool;
var slotRecord, slotState, slotSynth, slotCutting, near, controlOf, sentSets, sentValue, startBufferVoice, startInputVoice;
var playNote, neutralExpression, ownGrain, notesOf, neutralSlots;
var checkBufferNotes, checkSlotChurn, checkInputNote, checkGrainFanOut, checkExpression, checkFailedNoteStart;
var startSynthVoice, checkSynthNote, checkSynthChord, checkVoiceFanOut, checkExpressionKinds;
var levelProbe, checkPark, checkVoiceCommands, checkPoolFull, checkPoolRandom, checkPoolShrink, checkCuttingBound;
var heldCount, cuttingCount;
var checkSourceSwitch, checkBufferLoad, checkInputFreeze;
var checkFrozenNotes, checkSpectralNotes;
var wireMessages, sentCount, startValue, checkParkThroughFreeze, checkSilentRestarts, checkOwnNoteOnAccent;

// A slot's record (nil while the area keeps none), and its state, its
// synth and its cutting synth
slotRecord = { arg voice, slot; state[\slots] !? { arg slots; slots[voice] !? { arg each; each[slot] } } };
slotState = { arg voice, slot; slotRecord.(voice, slot) !? { arg record; record[\state] } };
slotSynth = { arg voice, slot; slotRecord.(voice, slot) !? { arg record; record[\synth] } };
slotCutting = { arg voice, slot; slotRecord.(voice, slot) !? { arg record; record[\cutting] } };
// Two control values within a float32's reach of each other
near = { arg a, b, tolerance = 0.0001; a.isNumber and: { b.isNumber } and: { (a - b).abs < tolerance } };
// One control of a synth on the server (nil for no synth)
controlOf = { arg synth, name; synth !? { h.getControl(synth, name) } };
// The /n_set messages of a bundle (makeBundle(false)) to a synth, and the
// last value one of them gives a control (nil for none)
sentSets = { arg bundle, synth;
    bundle.select({ arg msg; synth.notNil and: { (msg[0] == 15) or: { msg[0] == '/n_set' } } and: { msg[1] == synth.nodeID } })
};
sentValue = { arg bundle, synth, name;
    var value;
    sentSets.(bundle, synth).do({ arg msg;
        (2, 4 .. (msg.size - 2)).do({ arg index; if (msg[index].asSymbol == name) { value = msg[index + 1] } });
    });
    value
};
// The messages of h.wireUnits' entries, in order (what reached the server)
wireMessages = { arg units; units.collect({ arg unit; unit }).flatten(1) };
// How many of the messages set name to value on synth
sentCount = { arg messages, synth, name, value;
    messages.count({ arg msg;
        synth.notNil and: { (msg[0] == 15) or: { msg[0] == '/n_set' } } and: { msg[1] == synth.nodeID }
            and: { (2, 4 .. (msg.size - 2)).any({ arg index; (msg[index].asSymbol == name) and: { msg[index + 1] == value } }) }
    })
};
// The value a synth's /s_new message gives a control (nil for none): its
// pairs follow the def, node, add action and target
startValue = { arg msg, name;
    var value;
    (5, 7 .. (msg.size - 2)).do({ arg index; if (msg[index].asSymbol == name) { value = msg[index + 1] } });
    value
};
// voice on buffer slot (index slot, loaded with the stereo test file if
// empty) at scaleNote 60 and bufRate 1, running
startBufferVoice = { arg voice, slot = 0;
    if (engine.bufferFrames[slot] == 0) {
        command.(\loadBuffer, slot, h.stereoPath, 0);
        h.waitFor({ engine.bufferFrames[slot] > 0 }, 3);
    };
    command.(\setGrainSource, voice, slot + 1);
    command.(\setGrainParam, voice, \scaleNote, 60.0);
    command.(\setGrainParam, voice, \bufRate, 1.0);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.05.wait;
};
startInputVoice = { arg voice;
    command.(\setGrainSource, voice, engine.inputSource);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.05.wait;
};
// voice running on its synth source
startSynthVoice = { arg voice;
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.05.wait;
};
// Live and releasing extra notes, and cutting note synths, across every voice
heldCount = { state[\slots].sum({ arg slots; slots.copyToEnd(1).count({ arg record; [\live, \releasing].includes(record[\state]) }) }) };
cuttingCount = { state[\slots].sum({ arg slots; slots.copyToEnd(1).count({ arg record; record[\cutting].notNil }) }) };
// A peak meter on a voice's bus (granBuses: its voice synths', or the stage's
// mirror of its other path), at the tail of processGroup: [the probe, the
// control bus it writes], for h.measure
levelProbe = { arg voice;
    var bus = Bus.control(server, 1);
    [Synth(\strataCheckPeak, [\in, engine.granBuses[voice], \out, bus], engine.processGroup, \addToTail), bus]
};
// A note as Lua starts one: its expression (neutral unless given), then its noteOn
neutralExpression = [1.0, 1.0, 0.0, 0.0, 0.0];
playNote = { arg voice, slot, rate = 1.0, velocity = 1.0, freq = 220.0, note = 60.0, expression;
    command.(\noteExpression, voice, slot, *(expression ? neutralExpression));
    command.(\noteOn, voice, slot, note, freq, rate, velocity);
};
ownGrain = { arg voice; engine.synths[engine.grainKey(voice)] };
// The voice's extra notes' synths, live or releasing
notesOf = { arg voice; (1 .. (engine.noteSlots - 1)).collect({ arg slot; slotSynth.(voice, slot) }).reject(_.isNil) };
// Every slot as alloc leaves it: an extra slot empty, slot 0 unparked at
// the neutral expression
neutralSlots = {
    state[\slots].notNil and: { state[\slots].every({ arg slots;
        (slots.size == engine.noteSlots) and: { slots.every({ arg record, slot;
            record.notNil and: { if (slot == 0) { record[\parked] == false } {
                (record[\state] == \empty) and: { record[\synth].isNil } and: { record[\cutting].isNil } } } }) }
    }) }
};

// [synths, groups] on the server, from one /status reply
nodeCounts = {
    var condition = Condition(false), reply;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/status.reply', server.addr).oneShot;
    server.sendMsg('/status');
    h.awaitReply(condition);
    reply !? { [reply[3], reply[4]] }
};

// Two records of what the commands received, key for key
sameReceived = { arg a, b;
    (a.size == b.size) and: { a.keys.every({ arg key; a[key] == b[key] }) }
};

// Runs body with the lines the engine posts for ignored commands added to
// lines, through the modulation area's postIgnored hook (the notes
// commands post through its postFastModIgnored). However body ends, an
// error included, the hook goes back to what it was (a protect, as the
// memory area's guardedHold), so the areas after this one see their lines
withIgnoredLines = { arg lines, body;
    var modulation = engine.areaState[\modulation], previous = modulation[\postIgnored];
    modulation[\postIgnored] = { arg line; lines.add(line) };
    body.protect({ modulation[\postIgnored] = previous });
};

// The area, its literals and its state as alloc leaves it
checkState = {
    var slots = state[\slots];
    check.(area.notNil and: { area[\order] == 170 }, "notes: the area runs at order 170 (got %)".format(area !? { area[\order] }));
    check.((engine.noteSlots == 8) and: { engine.notePoolMax == 16 } and: { engine.noteLag == 0.02 }
        and: { state[\pool] == 0 } and: { state[\received].isKindOf(IdentityDictionary) }
        and: { slots.size == engine.numVoices } and: { neutralSlots.value },
        "notes: the area holds no pool and an empty slot for every note of every voice, the own note unparked (noteSlots %, notePoolMax %, noteLag %, pool %, slots %)".format(
            engine.noteSlots, engine.notePoolMax, engine.noteLag, state[\pool], slots !? { slots.collect({ arg each; each.collect({ arg record;
                record !? { record[\state] ? record[\parked] } }) }) }));
};

checkSignatures = {
    var signatures = [[\noteOn, "iiffff"], [\noteOff, "iii"], [\noteExpression, "iifffff"], [\setNotePool, "i"]];
    check.(signatures.every({ arg pair; h.formatOf(pair[0]) == pair[1] }),
        "notes: the four commands exist with their signatures (got %)".format(signatures.collect({ arg pair; h.formatOf(pair[0]) })));
};

// Each command, with valid arguments, to a running voice with the pool
// empty: the server's node count is the same after each, and the extra
// note, which the empty pool has no room for, is refused with one line
checkNoNodes = {
    var calls = [
        [\noteOn, 0, 1, 60.0, 440.0, 1.0, 1.0],
        [\noteExpression, 0, 1, 2.0, 0.5, 0.25, -0.25, 0.5],
        [\noteOff, 0, 1, 0],
        [\noteOff, 0, 2, 1],
        [\noteOn, 0, 0, 62.0, 220.0, 0.5, 0.8],
        [\setNotePool, 8],
        [\setNotePool, 0]
    ];
    var before, counts = List.new, lines = List.new;
    command.(\voiceOn, 0, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.3.wait;
    before = nodeCounts.value;
    withIgnoredLines.(lines, {
        calls.do({ arg call;
            command.(*call);
            server.sync; 0.05.wait;
            counts.add(nodeCounts.value);
        });
    });
    check.(before.notNil and: { engine.voiceRunning(0) } and: { counts.every({ arg each; each == before }) },
        "notes: with the pool empty no command creates a node (synths and groups before %, after each %)".format(before, counts.asArray));
    check.((lines.size == 1) and: { lines.first.beginsWith("strata: noteOn ignored: ") },
        "notes: an extra note the empty pool has no room for is refused with one line (%)".format(lines.asArray));
    command.(\noteExpression, 0, 1, *neutralExpression);
    h.stopAllVoices;
};

// The valid calls: each is recorded with its continuous arguments clipped
// (an out-of-range continuous value is clipped, never ignored)
checkRecorded = {
    // [the call, what the command records]
    var calls = [
        [[\noteOn, 6, 7, 127.0, 20000.0, 4.0, 1.0], [6, 7, 127.0, 20000.0, 4.0, 1.0]],
        [[\noteOn, 0, 0, 0.0, 8.0, 0.25, 0.0], [0, 0, 0.0, 8.0, 0.25, 0.0]],
        [[\noteOn, 3, 4, 128.0, 7.0, 0.2, 1.5], [3, 4, 127.0, 8.0, 0.25, 1.0]],
        [[\noteOn, 3, 4, -1.0, 20001.0, 4.1, -0.5], [3, 4, 0.0, 20000.0, 4.0, 0.0]],
        [[\noteOff, 0, 0, 0], [0, 0, 0]],
        [[\noteOff, 6, 7, 1], [6, 7, 1]],
        [[\noteExpression, 6, 7, 16.0, 2.0, 1.0, -1.0, 1.0], [6, 7, 16.0, 2.0, 1.0, -1.0, 1.0]],
        [[\noteExpression, 0, 0, 0.0625, 0.0, 0.0, 0.0, 0.0], [0, 0, 0.0625, 0.0, 0.0, 0.0, 0.0]],
        [[\noteExpression, 2, 3, 0.05, 2.5, 1.5, -1.5, 2.0], [2, 3, 0.0625, 2.0, 1.0, -1.0, 1.0]],
        [[\noteExpression, 2, 3, 17.0, -0.5, -1.5, 1.5, -2.0], [2, 3, 16.0, 0.0, -1.0, 1.0, -1.0]],
        [[\setNotePool, 16], [16]],
        [[\setNotePool, 0], [0]]
    ];
    // (the notes go to stopped voices, which refuse an extra note with a
    // line: the lines are taken, and the slots' expressions put back)
    var recorded;
    withIgnoredLines.(List.new, {
        recorded = calls.collect({ arg call;
            command.(*call[0]);
            state[\received][call[0][0]] == call[1]
        });
    });
    check.(recorded.every(_ == true),
        "notes: each command records its arguments, the continuous ones clipped (wrong: %)".format(
            calls.select({ arg call, index; recorded[index].not }).collect({ arg call; [call[0], state[\received][call[0][0]]] })));
    [[6, 7], [0, 0], [2, 3]].do({ arg pair; command.(\noteExpression, pair[0], pair[1], *neutralExpression) });
    command.(\voiceOn, 0, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);  // unparks voice 0's own note (noteOff 0, 0 parked it)
    h.stopAllVoices;
};

// Step 1's out-of-range indices and non-finite values, and the other
// bounds: each posts one line, records nothing and creates no node
checkIgnored = {
    var on = { arg voice, slot; [\noteOn, voice, slot, 60.0, 440.0, 1.0, 1.0] };
    var expression = { arg voice, slot; [\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0] };
    var bad = [
        on.(7, 1), on.(-1, 1), on.(0, 8), on.(0, -1), on.(0.5, 1), on.(0, 1.5),
        [\noteOn, 0, 1, nan, 440.0, 1.0, 1.0], [\noteOn, 0, 1, 60.0, nan, 1.0, 1.0], [\noteOn, 0, 1, 60.0, 440.0, nan, 1.0],
        [\noteOn, 0, 1, 60.0, 440.0, 1.0, nan], [\noteOn, 0, 1, 60.0, inf, 1.0, 1.0], [\noteOn, 0, 1, inf.neg, 440.0, 1.0, 1.0],
        [\noteOff, 7, 0, 0], [\noteOff, -1, 0, 0], [\noteOff, 0, 8, 0], [\noteOff, 0, -1, 0], [\noteOff, 0, 1, 2], [\noteOff, 0, 1, -1],
        expression.(7, 1), expression.(-1, 1), expression.(0, 8), expression.(0, -1),
        [\noteExpression, 0, 1, nan, 1.0, 0.0, 0.0, 0.0], [\noteExpression, 0, 1, 1.0, nan, 0.0, 0.0, 0.0],
        [\noteExpression, 0, 1, 1.0, 1.0, nan, 0.0, 0.0], [\noteExpression, 0, 1, 1.0, 1.0, 0.0, nan, 0.0],
        [\noteExpression, 0, 1, 1.0, 1.0, 0.0, 0.0, nan], [\noteExpression, 0, 1, inf, 1.0, 0.0, 0.0, 0.0],
        [\setNotePool, 17], [\setNotePool, -1], [\setNotePool, 0.5]
    ];
    var ignoredLines = List.new;
    var kept = state[\received].deepCopy, keptPool = state[\pool], before = nodeCounts.value, lines = List.new, unchanged = List.new;
    withIgnoredLines.(ignoredLines, {
        bad.do({ arg call;
            var count = ignoredLines.size;
            command.(*call);
            lines.add(ignoredLines.copyToEnd(count));
            unchanged.add(sameReceived.(state[\received], kept) and: { state[\pool] == keptPool });
        });
        server.sync;
    });
    check.(unchanged.every(_ == true) and: { lines.every({ arg each; each.size == 1 }) } and: { nodeCounts.value == before }
        and: { bad.every({ arg call, index; lines[index].first !? { arg line;
            line.beginsWith("strata: % ignored: ".format(call[0])) } ? false }) },
        "notes: out-of-range indices and non-finite values are ignored, one line each (changed by %; lines per call %; first %)".format(
            bad.select({ arg call, index; unchanged[index].not }), lines.collect(_.size).asSet.asArray, ignoredLines.first));
};

// An error while the check holds the hook still gives it back, so the
// areas after this one see their ignored lines: a deliberate error inside
// withIgnoredLines (caught here), then the hook must be what it was
checkHookRestored = {
    var modulation = engine.areaState[\modulation], before = modulation[\postIgnored], caught = false;
    try {
        withIgnoredLines.(List.new, { Error("notes check: a deliberate error while the hook is held").throw })
    } { caught = true };
    check.(caught and: { modulation[\postIgnored] === before },
        "notes: an error while the check holds the ignored-lines hook still gives it back (caught %, hook given back %)".format(
            caught, modulation[\postIgnored] === before));
    modulation[\postIgnored] = before;
};

// setNotePool keeps the size it is sent, 0 to notePoolMax, and an ignored
// one leaves it
checkPool = {
    var pools = List.new;
    [5, 17, 16, -1, 0].do({ arg size;
        command.(\setNotePool, size);
        pools.add(state[\pool]);
    });
    check.(pools.asArray == [5, 5, 16, 16, 0],
        "notes: setNotePool keeps the size (after 5, 17, 16, -1 and 0: %)".format(pools.asArray));
};

// A buffer voice's extra note: one \strataGrainBuf of its own at the head of
// the voice's mix group, playing the note's rate as its bufRate with a
// scaleNote of its own; a noteOn on the live slot re-pitches and accents it
// (t_accent at its velocity) without a node; a noteOff releases it (it
// frees after the grain release, 2 s), one with cut 1 frees it in the kill
// fade. The voice (1) is on slot 1 (index 0)
checkBufferNotes = {
    var voice = 1, group, nodes, own, synth, before, bundle, released, cutGone, tail;
    var grainBufName = "\\strataGrainBuf";
    startBufferVoice.(voice);
    command.(\setNotePool, 8);
    own = ownGrain.(voice);
    group = engine.voiceMixGroup(voice);
    playNote.(voice, 1, 1.5, 0.8, 392.0, 67.0);
    server.sync;
    synth = slotSynth.(voice, 1);
    nodes = h.synthTree(group);
    check.((slotState.(voice, 1) == \live) and: { synth.notNil } and: { nodes.first.notNil }
        and: { nodes.first[\def] == \strataGrainBuf } and: { nodes.first[\id] == synth.nodeID }
        and: { near.(nodes.first[\controls][\bufRate], 1.5) } and: { near.(nodes.first[\controls][\scaleNote], 60 + 1.5.ratiomidi) }
        and: { near.(nodes.first[\controls][\velocity], 0.8) }
        and: { nodes.count({ arg node; node[\def] == \strataGrainBuf }) == 2 } and: { near.(controlOf.(own, \bufRate), 1.0) }
        and: { near.(controlOf.(own, \scaleNote), 60) },
        "notes: noteOn on an empty slot of a buffer voice starts one % at the head of its mix group, with its own bufRate and scaleNote (state %, first node %, grain bufs %)".format(
            grainBufName, slotState.(voice, 1), nodes.first !? { arg node; [node[\def], node[\controls][\bufRate], node[\controls][\scaleNote]] },
            nodes.count({ arg node; node[\def] == \strataGrainBuf })));

    before = h.synthNames(h.context.xg).size;
    bundle = server.makeBundle(false, { command.(\noteOn, voice, 1, 72.0, 523.0, 2.0, 0.5) });
    server.sendBundle(nil, *bundle);
    server.sync;
    check.((slotSynth.(voice, 1) === synth) and: { h.synthNames(h.context.xg).size == before }
        and: { sentValue.(bundle, synth, \t_accent) == 1 } and: { near.(sentValue.(bundle, synth, \velocity), 0.5) }
        and: { near.(controlOf.(synth, \bufRate), 2.0) } and: { near.(controlOf.(synth, \scaleNote), 72) }
        and: { bundle.every({ arg msg; msg[0] != 9 }) },
        "notes: noteOn on a live slot sets its pitch, fires its accent and creates no node (same synth %, nodes % then %, sent %)".format(
            slotSynth.(voice, 1) === synth, before, h.synthNames(h.context.xg).size, sentSets.(bundle, synth)));

    command.(\noteOff, voice, 1, 0);
    server.sync; 0.5.wait;
    released = (slotState.(voice, 1) == \releasing) and: { synth.isPlaying } and: { controlOf.(synth, \gate) == 0 };
    tail = h.waitFor({ slotState.(voice, 1) == \empty }, 3);
    playNote.(voice, 2, 1.0);
    server.sync; 0.1.wait;
    synth = slotSynth.(voice, 2);
    command.(\noteOff, voice, 2, 1);
    0.1.wait; server.sync;
    cutGone = synth.notNil and: { synth.isPlaying.not } and: { slotState.(voice, 2) == \empty } and: { slotCutting.(voice, 2).isNil }
        and: { h.synthNames(group).count({ arg name; name == \strataGrainBuf }) == 1 };
    check.(released and: { tail } and: { slotSynth.(voice, 1).isNil } and: { cutGone },
        "notes: noteOff releases a note, which frees after its release; noteOff with cut 1 frees it within 0.1 s (released %, freed %, cut %)".format(
            released, tail, cutGone));
};

// A hundred noteOn and noteOff pairs 5 ms apart on one slot of the buffer
// voice: each noteOn meets the slot releasing, cuts the tail and starts a
// new synth. After every command the engine tracks at most the slot's
// synth and one cutting synth, and the server (one /g_queryTree with
// controls) runs at most one live (gate 1, kill 0) and one cutting (kill 1)
// note synth for it, at most two in all
checkSlotChurn = {
    var voice = 1, slot = 3, own = ownGrain.(voice), group = engine.voiceMixGroup(voice);
    var tracked = 0, live = 0, cutting = 0, all = 0;
    100.do({
        [{ command.(\noteOn, voice, slot, 60.0, 220.0, 1.0, 1.0) }, { command.(\noteOff, voice, slot, 0) }].do({ arg send;
            var nodes;
            send.value;
            tracked = max(tracked, [slotSynth.(voice, slot), slotCutting.(voice, slot)].count(_.notNil));
            server.sync;
            nodes = h.synthTree(group).select({ arg node; (node[\def] == \strataGrainBuf) and: { own.isNil or: { node[\id] != own.nodeID } } });
            all = max(all, nodes.size);
            live = max(live, nodes.count({ arg node; (node[\controls][\gate] > 0) and: { node[\controls][\kill] == 0 } }));
            cutting = max(cutting, nodes.count({ arg node; node[\controls][\kill] > 0 }));
            0.005.wait;
        });
    });
    check.((tracked <= 2) and: { tracked >= 1 } and: { live <= 1 } and: { cutting <= 1 } and: { all <= 2 } and: { all >= 1 }
        and: { slotState.(voice, slot) == \releasing },
        "notes: noteOn on a releasing slot cuts the tail and starts a new synth; the slot never holds two live synths (at most % tracked, on the server % live, % cutting, % in all)".format(
            tracked, live, cutting, all));
    command.(\noteOff, voice, slot, 1);
    server.sync;
};

// An input voice's extra note: a \strataGrainRing of its own at the head of
// the voice's mix group, reading the input ring and playing the note's rate
// as its pitchShift, mapped to its voice in ringReaders
checkInputNote = {
    var voice = 2, synth, nodes, ring = engine.ringBuffersFor(voice, engine.inputSource);
    var grainRingName = "\\strataGrainRing";
    startInputVoice.(voice);
    playNote.(voice, 1, 1.5);
    server.sync;
    synth = slotSynth.(voice, 1);
    nodes = h.synthTree(engine.voiceMixGroup(voice));
    check.(synth.notNil and: { nodes.first.notNil } and: { nodes.first[\id] == synth.nodeID }
        and: { nodes.first[\def] == \strataGrainRing } and: { near.(nodes.first[\controls][\pitchShift], 1.5) }
        and: { near.(controlOf.(ownGrain.(voice), \pitchShift), 1.0) }
        and: { nodes.first[\controls][\bufL] == ring[0].bufnum }
        and: { nodes.first[\controls][\out] == engine.voicePathBus(voice, engine.inputSource).index }
        and: { engine.ringReaders[synth] == voice },
        "notes: an input voice's note is a % with its own pitchShift (first node %)".format(grainRingName,
            nodes.first !? { arg node; [node[\def], node[\controls][\pitchShift], node[\controls][\bufL]] }));
};

// A voice-wide grain param (grainSize; pitchShift on a buffer voice; the
// envelope, as its envBuf; the voice's pan, a voice-level grain control; an
// input voice's history; a buffer voice's t_scanReset, never stored)
// reaches the own grain synth and every live note of the voice; bufRate
// only the own note's (each note keeps its own, with its own scaleNote,
// which a new scaleNote moves by the note's rate); an input voice's
// pitchShift only its own note's; retrigger sends t_trig to every grain
// synth of the voice
checkGrainFanOut = {
    var buffer = 1, input = 2, ownBuffer = ownGrain.(buffer), ownInput = ownGrain.(input), notes, inputNote, bundle, synths, ok, scanReset;
    playNote.(buffer, 1, 1.5);
    playNote.(buffer, 2, 2.0);
    server.sync;
    notes = [slotSynth.(buffer, 1), slotSynth.(buffer, 2)];
    inputNote = slotSynth.(input, 1);
    command.(\setGrainParam, buffer, \grainSize, 0.3);
    command.(\setGrainParam, buffer, \pitchShift, 1.25);
    command.(\setGrainParam, buffer, \envShape, 2.0);
    command.(\setVoiceParam, buffer, \pan, 0.25);
    command.(\setGrainParam, buffer, \bufRate, 0.5);
    command.(\setGrainParam, buffer, \scaleNote, 62.0);
    command.(\setGrainParam, input, \pitchShift, 0.75);
    command.(\setGrainParam, input, \grainSize, 0.2);
    command.(\setGrainParam, input, \history, 0.5);
    server.sync;
    scanReset = server.makeBundle(false, { command.(\setGrainParam, buffer, \t_scanReset, 1.0) });
    server.sendBundle(nil, *scanReset);
    server.sync;
    synths = [ownBuffer] ++ notes;
    ok = notes.every(_.notNil) and: { inputNote.notNil }
        and: { synths.every({ arg synth; near.(controlOf.(synth, \grainSize), 0.3) and: { near.(controlOf.(synth, \pitchShift), 1.25) }
            and: { controlOf.(synth, \envBuf) == engine.envBuffers[1].bufnum } and: { near.(controlOf.(synth, \pan), 0.25) } }) }
        and: { near.(controlOf.(ownBuffer, \bufRate), 0.5) } and: { near.(controlOf.(ownBuffer, \scaleNote), 62 + 0.5.ratiomidi) }
        and: { near.(controlOf.(notes[0], \bufRate), 1.5) } and: { near.(controlOf.(notes[0], \scaleNote), 62 + 1.5.ratiomidi) }
        and: { near.(controlOf.(notes[1], \bufRate), 2.0) } and: { near.(controlOf.(notes[1], \scaleNote), 74) }
        and: { near.(controlOf.(ownInput, \pitchShift), 0.75) } and: { near.(controlOf.(inputNote, \pitchShift), 1.5) }
        and: { near.(controlOf.(ownInput, \grainSize), 0.2) } and: { near.(controlOf.(inputNote, \grainSize), 0.2) }
        and: { near.(controlOf.(ownInput, \history), 0.5) } and: { near.(controlOf.(inputNote, \history), 0.5) }
        and: { synths.every({ arg synth; sentValue.(scanReset, synth, \t_scanReset) == 1 }) };
    bundle = server.makeBundle(false, { command.(\retrigger, buffer, 0.7) });
    server.sendBundle(nil, *bundle);
    server.sync;
    check.(ok and: { synths.every({ arg synth; sentValue.(bundle, synth, \t_trig) == 1 }) },
        "notes: a voice-wide grain param reaches every note of the voice, and bufRate only its own note (buffer notes' bufRate %, scaleNote %, grainSize %; input note's pitchShift %; retrigger's t_trig %)".format(
            notes.collect({ arg synth; controlOf.(synth, \bufRate) }), notes.collect({ arg synth; controlOf.(synth, \scaleNote) }),
            synths.collect({ arg synth; controlOf.(synth, \grainSize) }), controlOf.(inputNote, \pitchShift),
            synths.collect({ arg synth; sentValue.(bundle, synth, \t_trig) })));
    [1, 2].do({ arg slot; command.(\noteOff, buffer, slot, 1) });
    command.(\noteOff, input, 1, 1);
    command.(\setGrainParam, buffer, \pitchShift, 1.0);
    command.(\setGrainParam, buffer, \bufRate, 1.0);
    command.(\setGrainParam, buffer, \scaleNote, 60.0);
    command.(\setVoiceParam, buffer, \pan, 0.0);
    command.(\setGrainParam, input, \history, 0.0);
    server.sync; 0.1.wait;
};

// An empty slot keeps the expression it is sent (no node), and its next
// noteOn starts with it; a live note's expression is set on its synth at
// once (a grain note takes bend, amp, position and size; main is a voice
// synth note's)
checkExpression = {
    var voice = 1, slot = 4, before = h.synthNames(h.context.xg).size, synth, kept, started, live;
    command.(\noteExpression, voice, slot, 2.0, 0.5, 0.25, -0.25, 0.5);
    server.sync;
    kept = (slotRecord.(voice, slot) !? { arg record; record[\expression] } ? ()) ;
    kept = (kept[\bend] == 2.0) and: { kept[\amp] == 0.5 } and: { kept[\position] == 0.25 } and: { kept[\size] == -0.25 }
        and: { kept[\main] == 0.5 } and: { h.synthNames(h.context.xg).size == before };
    command.(\noteOn, voice, slot, 60.0, 220.0, 1.0, 1.0);
    server.sync;
    synth = slotSynth.(voice, slot);
    started = synth.notNil and: { near.(controlOf.(synth, \noteBend), 2.0) } and: { near.(controlOf.(synth, \noteAmp), 0.5) }
        and: { near.(controlOf.(synth, \notePos), 0.25) } and: { near.(controlOf.(synth, \noteSize), -0.25) };
    check.(kept and: { started },
        "notes: noteExpression is kept for an empty slot and a later noteOn starts with it (kept %, started %)".format(kept, started));
    command.(\noteExpression, voice, slot, 0.5, 1.5, -0.5, 0.5, 0.0);
    server.sync;
    live = [\noteBend, \noteAmp, \notePos, \noteSize].collect({ arg name; controlOf.(synth, name) });
    check.(synth.notNil and: { [live, [0.5, 1.5, -0.5, 0.5]].flop.every({ arg pair; near.(pair[0], pair[1]) }) },
        "notes: noteExpression reaches a live note within one block (noteBend, noteAmp, notePos, noteSize: %)".format(live));
    command.(\noteOff, voice, slot, 1);
    command.(\noteExpression, voice, slot, *neutralExpression);
    server.sync; 0.1.wait;
};

// A note whose /s_new never reached the server (held back from the
// command's bundle, makeBundle(false), as for a start with no room in the
// pool: for sclang the same, with no FAILURE line) is live for the engine;
// past startConfirmWait the slot's next noteOn forgets it and starts the
// note, and a noteOff forgets it and does nothing. A noteOff on an empty
// slot, released or cut, sends the server nothing it fails on (no /fail)
checkFailedNoteStart = {
    var voice = 1, fails = List.new, watcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr);
    var withheld = { arg slot;
        var bundle, synth;
        command.(\noteExpression, voice, slot, *neutralExpression);
        bundle = server.makeBundle(false, { command.(\noteOn, voice, slot, 60.0, 220.0, 1.0, 1.0) });
        synth = slotSynth.(voice, slot);
        server.sendBundle(nil, *bundle.reject({ arg msg; synth.notNil and: { msg[0] == 9 } and: { msg[2] == synth.nodeID } }));
        server.sync;
        synth
    };
    var unstarted, restarted, onServer, forgotten;
    unstarted = withheld.(5);
    (engine.startConfirmWait + 0.1).wait;
    command.(\noteOn, voice, 5, 60.0, 220.0, 1.0, 1.0);
    server.sync; 0.05.wait;
    restarted = slotSynth.(voice, 5);
    onServer = restarted.notNil and: { h.synthTree(engine.voiceMixGroup(voice)).any({ arg node; node[\id] == restarted.nodeID }) };
    unstarted = withheld.(6);
    (engine.startConfirmWait + 0.1).wait;
    command.(\noteOff, voice, 6, 0);
    server.sync;
    forgotten = (slotState.(voice, 6) == \empty) and: { slotSynth.(voice, 6).isNil } and: { engine.unconfirmedStarts[unstarted].isNil };
    command.(\noteOff, voice, 7, 0);
    command.(\noteOff, voice, 7, 1);
    server.sync; 0.1.wait;
    check.(unstarted.notNil and: { restarted.notNil } and: { restarted !== unstarted } and: { onServer } and: { slotState.(voice, 5) == \live }
        and: { forgotten } and: { fails.isEmpty },
        "notes: noteOn on a slot whose start failed starts it, and noteOff on an empty slot is silent (started %, forgotten %, server failures %)".format(
            onServer, forgotten, fails));
    watcher.free;
    command.(\noteOff, voice, 5, 1);
    server.sync; 0.1.wait;
};

// A synth voice's extra note: one voice synth of the voice's def at the
// head of voiceGroup, writing the voice's bus (which its one ring writer
// records and its one grain synth grains), at the note's own freq, started
// with its accent (t_trig 1 at its velocity) and its park open. The voice
// (3, Sub) runs on its synth source
checkSynthNote = {
    var voice = 3, own, synth, nodes, bundle, start;
    startSynthVoice.(voice);
    command.(\setNotePool, 16);
    own = engine.synths[engine.voiceKey(voice)];
    command.(\noteExpression, voice, 1, *neutralExpression);
    bundle = server.makeBundle(false, { command.(\noteOn, voice, 1, 57.0, 220.0, 1.0, 0.6) });
    server.sendBundle(nil, *bundle);
    server.sync;
    synth = slotSynth.(voice, 1);
    start = bundle.detect({ arg msg; (msg[0] == 9) and: { synth.notNil } and: { msg[2] == synth.nodeID } });
    nodes = h.synthTree(engine.voiceGroup);
    check.(synth.notNil and: { slotState.(voice, 1) == \live } and: { nodes.first.notNil } and: { nodes.first[\id] == synth.nodeID }
        and: { nodes.first[\def] == engine.voiceSynthDefs[voice] }
        and: { nodes.first[\controls][\out] == engine.granBuses[voice].index }
        and: { near.(nodes.first[\controls][\freq], 220) } and: { near.(controlOf.(own, \freq), 110) }
        and: { near.(nodes.first[\controls][\velocity], 0.6) } and: { nodes.first[\controls][\noteGate] == 1 }
        and: { start.notNil and: { start.indexOf(\t_trig).notNil } and: { start[start.indexOf(\t_trig) + 1] == 1 } },
        "notes: a synth voice's note is one voice synth at the head of voiceGroup, on the voice's bus, with its own freq (first node %, started with t_trig %)".format(
            nodes.first !? { arg node; [node[\def], node[\controls][\out], node[\controls][\freq]] },
            start !? { start.indexOf(\t_trig) !? { arg index; start[index + 1] } }));
};

// A chord of eight on the synth voice (its own note and seven extra notes):
// eight voice synths of its def on its bus, and still one grain synth on its
// synth path, one ring writer of its bus and one mod synth reading it
checkSynthChord = {
    var voice = 3, nodes, voiceSynths, grains, writers, mods;
    (2 .. 7).do({ arg slot; playNote.(voice, slot, 1.0, 1.0, 110.0 * (1 + (slot / 4))) });
    server.sync;
    nodes = h.synthTree(h.context.xg);
    voiceSynths = nodes.count({ arg node; (node[\def] == engine.voiceSynthDefs[voice]) and: { node[\controls][\out] == engine.granBuses[voice].index } });
    grains = nodes.count({ arg node; h.grainDefs.includes(node[\def]) and: { node[\controls][\out] == engine.voicePathBus(voice, 0).index } });
    writers = nodes.count({ arg node; node[\def].asString.beginsWith("strataRingWrite") and: { node[\controls][\in] == engine.granBuses[voice].index } });
    mods = nodes.count({ arg node; (node[\def] == \strataMod) and: { node[\controls][\in] == engine.granBuses[voice].index } });
    check.((voiceSynths == 8) and: { grains == 1 } and: { writers == 1 } and: { mods == 1 } and: { notesOf.(voice).size == 7 },
        "notes: the voice's grain synth, ring writer and mod synth stay one each under a chord of eight (% voice synths, % grain synths, % ring writers, % mod synths)".format(
            voiceSynths, grains, writers, mods));
};

// setVoiceParam on the chord's voice: a synthesis param (drift), the voice's
// release time and amp reach every note's voice synth; freq only the own
// note's
checkVoiceFanOut = {
    var voice = 3, own = engine.synths[engine.voiceKey(voice)], notes = notesOf.(voice), all, freqs;
    command.(\setVoiceParam, voice, \drift, 0.05);
    command.(\setVoiceParam, voice, \releaseTime, 1.5);
    command.(\setVoiceParam, voice, \amp, 0.3);
    command.(\setVoiceParam, voice, \freq, 55.0);
    server.sync;
    all = [own] ++ notes;
    freqs = notes.collect({ arg synth; controlOf.(synth, \freq) });
    check.((notes.size == 7) and: { all.every({ arg synth; near.(controlOf.(synth, \drift), 0.05) and: { near.(controlOf.(synth, \releaseTime), 1.5) }
            and: { near.(controlOf.(synth, \amp), 0.3) } }) }
        and: { near.(controlOf.(own, \freq), 55) } and: { freqs.every({ arg freq; freq.notNil and: { freq > 100 } }) },
        "notes: setVoiceParam reaches every note's synth, and freq only the own note's (own freq %, the notes' %)".format(
            controlOf.(own, \freq), freqs));
    command.(\setVoiceParam, voice, \drift, 0.02);
    command.(\setVoiceParam, voice, \releaseTime, 12.0);
    command.(\setVoiceParam, voice, \amp, 0.2);
    command.(\setVoiceParam, voice, \freq, 110.0);
};

// A note's expression by its kind: a voice synth note takes bend, amp and
// main (noteMain), a grain note bend, amp, position and size (notePos,
// noteSize). The buffer voice (1) plays a note in slot 1
checkExpressionKinds = {
    var synthVoice = 3, bufferVoice = 1, voiceNote = slotSynth.(synthVoice, 1), grainNote, voiceValues, grainValues;
    startBufferVoice.(bufferVoice);
    playNote.(bufferVoice, 1, 1.0);
    server.sync;
    grainNote = slotSynth.(bufferVoice, 1);
    command.(\noteExpression, synthVoice, 1, 1.5, 0.8, 0.3, -0.3, 0.6);
    command.(\noteExpression, bufferVoice, 1, 0.75, 1.2, 0.4, -0.4, 0.9);
    server.sync;
    voiceValues = [\noteBend, \noteAmp, \noteMain].collect({ arg name; controlOf.(voiceNote, name) });
    grainValues = [\noteBend, \noteAmp, \notePos, \noteSize].collect({ arg name; controlOf.(grainNote, name) });
    check.(voiceNote.notNil and: { grainNote.notNil }
        and: { [voiceValues, [1.5, 0.8, 0.6]].flop.every({ arg pair; near.(pair[0], pair[1]) }) }
        and: { [grainValues, [0.75, 1.2, 0.4, -0.4]].flop.every({ arg pair; near.(pair[0], pair[1]) }) },
        "notes: main reaches a voice-synth note's noteMain and position and size a grain note's (voice synth note: %; grain note: %)".format(
            voiceValues, grainValues));
    (1 .. 7).do({ arg slot; command.(\noteOff, synthVoice, slot, 1); command.(\noteExpression, synthVoice, slot, *neutralExpression) });
    command.(\noteOff, bufferVoice, 1, 1);
    command.(\noteExpression, bufferVoice, 1, *neutralExpression);
    server.sync; 0.1.wait;
};

// The own note's park (slot 0), on a synth voice (4, Pulse: once its 2 s
// attack is over, its attack and release set short, since the park takes the
// voice's times), a buffer voice
// (1) and an input voice (2, fed a test tone): noteOff on slot 0 sets
// noteGate 0 on the synth that sounds the own note (the voice synth, or the
// grain synth), whose level falls to 0 over its release while every synth
// stays; noteOn on slot 0 sets it to 1 and the level comes back (no node
// either way)
checkPark = {
    var tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead), results;
    startSynthVoice.(4);
    startBufferVoice.(1);
    startInputVoice.(2);
    server.sync; 2.3.wait;
    command.(\setVoiceParam, 4, \attackTime, 0.05);
    command.(\setVoiceParam, 4, \releaseTime, 0.3);
    results = [[4, engine.voiceKey(4), 0.6], [1, engine.grainKey(1), 2.4], [2, engine.grainKey(2), 2.4]].collect({ arg each;
        var voice = each[0], synth = engine.synths[each[1]], probe = levelProbe.(voice), before, parked, back, nodes, gate, kept;
        server.sync;
        before = h.measure(probe[0], probe[1], 0.3)[0];
        nodes = h.synthNames(h.context.xg).size;
        command.(\noteOff, voice, 0, 0);
        server.sync;
        gate = controlOf.(synth, \noteGate);
        each[2].wait;
        parked = h.measure(probe[0], probe[1], 0.2)[0];
        kept = (engine.synths[each[1]] === synth) and: { synth.isPlaying } and: { h.synthNames(h.context.xg).size == nodes };
        command.(\noteOn, voice, 0, 60.0, 220.0, 1.0, 1.0);
        server.sync; 0.4.wait;
        back = h.measure(probe[0], probe[1], 0.3)[0];
        probe[0].free; probe[1].free;
        [voice, gate, before, parked, back, kept, controlOf.(synth, \noteGate)]
    });
    tone.free;
    check.(results.every({ arg each; (each[1] == 0) and: { each[2] > 0.01 } and: { each[3] < (each[2] * 0.01) }
            and: { each[4] > (each[2] * 0.5) } and: { each[5] } and: { each[6] == 1 } }),
        "notes: noteOff on slot 0 parks the own note: its synths stay, its level falls to 0; noteOn on slot 0 brings it back (per voice [voice, noteGate parked, level before, parked, back, synths kept, noteGate after]: %)".format(
            results.collect({ arg each; [each[0], each[1], each[2].round(0.001), each[3].round(0.0001), each[4].round(0.001), each[5], each[6]] })));
    command.(\setVoiceParam, 4, \attackTime, 2.0);
    command.(\setVoiceParam, 4, \releaseTime, 4.0);
    h.stopAllVoices;
};

// voiceOff releases every extra note with the voice (their gate 0, their
// slots releasing); voiceOn after it re-gates only the own synths (no new
// node) and leaves the extra tails to end; after the longest release (the
// grain synths' 2 s, Karplus's 2 s) every slot is empty. A buffer voice (1)
// and a synth voice (5) hold three extra notes each; voiceOn also unparks
// the own note and puts its expression back to neutral
checkVoiceCommands = {
    var voices = [1, 5], notes, own, nodes, released, regated, tails, parkReset;
    command.(\setNotePool, 8);
    startBufferVoice.(1);
    startSynthVoice.(5);
    voices.do({ arg voice; (1 .. 3).do({ arg slot; playNote.(voice, slot, 1.0 + (slot / 4), 1.0, 220.0 * (1 + (slot / 4))) }) });
    command.(\noteOff, 1, 0, 0);
    command.(\noteExpression, 1, 0, 2.0, 0.5, 0.5, 0.5, 0.5);
    server.sync;
    notes = voices.collect({ arg voice; notesOf.(voice) });
    own = voices.collect({ arg voice; h.voiceSynths(voice) });
    voices.do({ arg voice; command.(\voiceOff, voice) });
    server.sync;
    released = voices.every({ arg voice, index; (1 .. 3).every({ arg slot; slotState.(voice, slot) == \releasing })
        and: { notes[index].every({ arg synth; controlOf.(synth, \gate) == 0 }) } });
    nodes = h.synthNames(h.context.xg).size;
    voices.do({ arg voice; command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0) });
    server.sync;
    regated = (h.synthNames(h.context.xg).size == nodes)
        and: { voices.every({ arg voice, index; h.voiceSynths(voice).every({ arg synth, key; synth === own[index][key] }) }) }
        and: { voices.every({ arg voice, index; (1 .. 3).every({ arg slot; slotState.(voice, slot) == \releasing })
            and: { notes[index].every({ arg synth; controlOf.(synth, \gate) == 0 }) } }) };
    parkReset = (slotRecord.(1, 0)[\parked] == false) and: { slotRecord.(1, 0)[\expression][\bend] == 1 }
        and: { controlOf.(ownGrain.(1), \noteGate) == 1 } and: { near.(controlOf.(ownGrain.(1), \noteBend), 1) };
    check.(released and: { regated } and: { parkReset },
        "notes: voiceOff releases every note and voiceOn after it re-gates only the own synths (released %, re-gated only the own %, own note unparked and neutral %)".format(
            released, regated, parkReset));
    tails = h.waitFor({ voices.every({ arg voice; (1 .. 7).every({ arg slot; slotState.(voice, slot) == \empty }) }) }, 3);
    check.(tails and: { notes.flatten.every({ arg synth; synth.isPlaying.not }) },
        "notes: after voiceOff and the longest release every slot is empty (% slots left)".format(
            voices.collect({ arg voice; (1 .. 7).reject({ arg slot; slotState.(voice, slot) == \empty }) })));
    h.stopAllVoices;
};

// A full pool (4) on the buffer voice (1): two live notes and two releasing
// (the older first); a new note cuts the oldest releasing one (its slot
// empty, its synth cutting) and leaves the other releasing. With the pool
// full of live notes a new note is refused with one line, starting nothing
checkPoolFull = {
    var voice = 1, before, lines = List.new, cut;
    startBufferVoice.(voice);
    command.(\setNotePool, 4);
    (1 .. 4).do({ arg slot; playNote.(voice, slot, 1.0) });
    server.sync;
    command.(\noteOff, voice, 2, 0);
    command.(\noteOff, voice, 3, 0);
    cut = slotSynth.(voice, 2);
    playNote.(voice, 5, 1.5);
    server.sync;
    check.((slotState.(voice, 2) == \empty) and: { slotCutting.(voice, 2) === cut } and: { slotState.(voice, 3) == \releasing }
        and: { slotState.(voice, 5) == \live } and: { heldCount.value == 4 },
        "notes: with the pool full of live and releasing notes a new note cuts the oldest releasing one (slots 1-5: %, % held)".format(
            (1 .. 5).collect({ arg slot; slotState.(voice, slot) }), heldCount.value));
    playNote.(voice, 3, 1.0);   // slot 3 was releasing: its tail is cut, a new note starts
    server.sync; 0.1.wait; server.sync;   // past the kill fade
    before = h.synthNames(h.context.xg).size;
    withIgnoredLines.(lines, { playNote.(voice, 6, 1.0) });
    server.sync;
    check.((lines.size == 1) and: { lines.first.beginsWith("strata: noteOn ignored: ") } and: { slotState.(voice, 6) == \empty }
        and: { h.synthNames(h.context.xg).size == before } and: { heldCount.value == 4 },
        "notes: with the pool full of live notes a new note is refused with one line (%; % held)".format(lines.asArray, heldCount.value));
    h.stopAllVoices;
};

// A random run of 2000 commands over the seven voices (three synth voices,
// two buffer voices, two input voices, all running): noteOn, noteOff (a
// release or a cut) on random extra slots, now and then a voiceOff and
// voiceOn or a new pool size. After every command live and releasing extra
// notes are within the pool, and cutting note synths within it too
checkPoolRandom = {
    var random = Pseed(7, Pwhite(0.0, 1.0)).asStream, held = 0, cutting = 0, over = List.new, pool = 8;
    var sources = [0, 1, 2, engine.inputSource, 0, engine.inputSource, 0];
    [0, 1].do({ arg slot;
        if (engine.bufferFrames[slot] == 0) { command.(\loadBuffer, slot, h.stereoPath, 0); h.waitFor({ engine.bufferFrames[slot] > 0 }, 3) };
    });
    sources.do({ arg source, voice;
        command.(\setGrainSource, voice, source);
        command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    });
    command.(\setNotePool, pool);
    server.sync;
    withIgnoredLines.(List.new, {
        2000.do({ arg index;
            var draw = random.next, voice = (random.next * 7).floor.asInteger.min(6), slot = (random.next * 7).floor.asInteger.min(6) + 1;
            case
            { draw < 0.5 } { playNote.(voice, slot, 0.5 + random.next, 1.0, 110.0 + (random.next * 400)) }
            { draw < 0.75 } { command.(\noteOff, voice, slot, 0) }
            { draw < 0.9 } { command.(\noteOff, voice, slot, 1) }
            { draw < 0.95 } { command.(\voiceOff, voice); command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0) }
            { pool = (random.next * 17).floor.asInteger.min(16); command.(\setNotePool, pool) };
            held = max(held, heldCount.value);
            cutting = max(cutting, cuttingCount.value);
            if ((heldCount.value > pool) or: { cuttingCount.value > pool }) { over.add([index, heldCount.value, cuttingCount.value, pool]) };
            if ((index % 25) == 24) { server.sync; 0.01.wait };
        });
    });
    check.(over.isEmpty and: { held > 0 },
        "notes: live and releasing extra notes never exceed the pool (2000 commands over seven voices: at most % held and % cutting; over the pool at %)".format(
            held, cutting, over.keep(5)));
    h.stopAllVoices;
};

// setNotePool below what is held cuts the notes past it: the oldest
// releasing first, then the oldest live. Six notes on the buffer voice
// (slots 1-6, in that order), slot 6 then released: a pool of 4 cuts slot 6
// (releasing) and slot 1 (the oldest live)
checkPoolShrink = {
    var voice = 1;
    startBufferVoice.(voice);
    command.(\setNotePool, 8);
    (1 .. 6).do({ arg slot; playNote.(voice, slot, 1.0) });
    command.(\noteOff, voice, 6, 0);
    command.(\setNotePool, 4);
    server.sync;
    check.(([\empty, \live, \live, \live, \live, \empty] == (1 .. 6).collect({ arg slot; slotState.(voice, slot) }))
        and: { slotCutting.(voice, 1).notNil } and: { slotCutting.(voice, 6).notNil } and: { heldCount.value == 4 },
        "notes: setNotePool below what is held cuts the oldest notes past it (slots 1-6: %)".format(
            (1 .. 6).collect({ arg slot; slotState.(voice, slot) })));
    h.stopAllVoices;
};

// With a pool of 2, notes started and cut on every extra slot of the buffer
// voice in turn, the commands sent without a yield (no /n_end is handled
// meanwhile, so no kill fade ends on its own for sclang): after each command
// at most two cutting note synths, the oldest freed at once, and on the
// server at most two in their kill fade (kill 1) once it has them all
checkCuttingBound = {
    var voice = 1, worst = 0, worstServer = 0, own;
    startBufferVoice.(voice);
    command.(\setNotePool, 2);
    own = ownGrain.(voice);
    3.do({
        (1 .. 7).do({ arg slot;
            playNote.(voice, slot, 1.0);
            worst = max(worst, cuttingCount.value);
            command.(\noteOff, voice, slot, 1);
            worst = max(worst, cuttingCount.value);
        });
        server.sync;
        worstServer = max(worstServer, h.synthTree(engine.voiceMixGroup(voice)).count({ arg node;
            (node[\def] == \strataGrainBuf) and: { node[\id] != own.nodeID } and: { node[\controls][\kill] > 0 } }));
        0.1.wait;
    });
    check.((worst == 2) and: { worstServer <= 2 },
        "notes: cutting note synths never exceed the pool (a pool of 2: at most % cutting tracked, % on the server)".format(worst, worstServer));
    h.stopAllVoices;
};

// A source switch of a running voice under a chord (voice 6, Ring): three
// live extra notes (slots 1-3) and one releasing (slot 4). Synth -> buffer
// (slot 1) -> input -> synth: each switch cuts every extra note and
// restarts each live one on the new source from its kept values, in the
// switch's bundle (a kill 1 to each old note's synth and an /s_new of each
// new one, in the one bundle the command sends); the releasing one is cut
// and not restarted. The live count is the same before and after, each live
// slot holds its new synth (of the new source's kind) and the old one only
// as its cutting synth
checkSourceSwitch = {
    var voice = 6, results = List.new, kindOf = IdentityDictionary[0 -> \voice, 1 -> \buffer], defOf;
    kindOf[engine.inputSource] = \input;
    defOf = (voice: engine.voiceSynthDefs[voice], buffer: \strataGrainBuf, input: \strataGrainRing);
    startSynthVoice.(voice);
    command.(\setNotePool, 16);
    if (engine.bufferFrames[0] == 0) { command.(\loadBuffer, 0, h.stereoPath, 0); h.waitFor({ engine.bufferFrames[0] > 0 }, 3) };
    (1 .. 4).do({ arg slot; playNote.(voice, slot, 1.0 + (slot / 8), 1.0, 220.0 + (slot * 55)) });
    command.(\noteOff, voice, 4, 0);
    server.sync;
    [1, engine.inputSource, 0].do({ arg source;
        var old = (1 .. 4).collect({ arg slot; slotSynth.(voice, slot) }), live = (1 .. 4).select({ arg slot; slotState.(voice, slot) == \live });
        // (the cutting entries read before any yield: a kill fade ends 50 ms on)
        var bundle = server.makeBundle(false, { command.(\setGrainSource, voice, source) }), new, nodes, ok;
        var cutting = (1 .. 4).collect({ arg slot; slotCutting.(voice, slot) });
        server.sendBundle(nil, *bundle);
        server.sync;
        new = (1 .. 4).collect({ arg slot; slotSynth.(voice, slot) });
        nodes = h.synthTree(h.context.xg);
        ok = ((1 .. 4).select({ arg slot; slotState.(voice, slot) == \live }) == live) and: { slotState.(voice, 4) == \empty }
            and: { live.every({ arg slot; var synth = new[slot - 1];
                synth.notNil and: { synth !== old[slot - 1] } and: { cutting[slot - 1] === old[slot - 1] }
                    and: { slotRecord.(voice, slot)[\kind] == kindOf[source] }
                    and: { nodes.detect({ arg node; node[\id] == synth.nodeID }) !? { arg node; node[\def] == defOf[kindOf[source]] } ? false }
                    and: { bundle.any({ arg msg; (msg[0] == 9) and: { msg[2] == synth.nodeID } }) } }) }
            and: { old.reject(_.isNil).every({ arg synth; sentValue.(bundle, synth, \kill) == 1 }) };
        results.add([source, ok, live]);
    });
    check.(results.every({ arg each; each[1] }) and: { results.every({ arg each; each[2] == [1, 2, 3] }) }
        and: { (1 .. 3).every({ arg slot; near.(controlOf.(slotSynth.(voice, slot), \freq), 220.0 + (slot * 55)) }) },
        "notes: a source switch under a chord cuts every extra note and restarts the held ones on the new source in one bundle ([source, ok, live slots]: %)".format(
            results.asArray));
    h.stopAllVoices;
};

// A buffer load into the slot a buffer voice reads, under its notes (two
// live, one releasing): the load's first step (in the command's bundle)
// sends every grain synth reading the slot bufFrames 0 (the fade), the
// notes' included; once the
// file is in, the voice's live grain synths, its live notes' included, take
// the slot's new length and rate, and the releasing note keeps bufFrames 0
checkBufferLoad = {
    var voice = 1, notes, tail, own, faded, loaded, bundle;
    startBufferVoice.(voice);
    command.(\setNotePool, 8);
    (1 .. 3).do({ arg slot; playNote.(voice, slot, 1.0) });
    command.(\noteOff, voice, 3, 0);
    server.sync;
    own = ownGrain.(voice);
    notes = [slotSynth.(voice, 1), slotSynth.(voice, 2)];
    tail = slotSynth.(voice, 3);
    // (the load's first step, the fade, is in the command's own bundle:
    // read there, since the rest follows within bufferFadeWait)
    bundle = server.makeBundle(false, { command.(\loadBuffer, 0, h.monoPath, 0) });
    server.sendBundle(nil, *bundle);
    faded = ([own, tail] ++ notes).collect({ arg synth; sentValue.(bundle, synth, \bufFrames) });
    h.waitFor({ engine.bufferFrames[0] == 4410 }, 3);
    server.sync; 0.05.wait;
    loaded = ([own] ++ notes).collect({ arg synth; [controlOf.(synth, \bufFrames), controlOf.(synth, \bufRateScale)] });
    check.(faded.every(_ == 0) and: { loaded.every({ arg pair; (pair[0] == 4410) and: { near.(pair[1], engine.bufferRateScale(0)) } }) }
        and: { controlOf.(tail, \bufFrames) == 0 },
        "notes: a buffer load fades every note reading the slot (bufFrames at the load: %; once in, the own and live notes' [bufFrames, bufRateScale]: %; the releasing note's %)".format(
            faded, loaded, controlOf.(tail, \bufFrames)));
    h.stopAllVoices;
    command.(\clearBuffer, 0);
    server.sync;
};

// An input freeze (hold) under notes (voice 2, two live notes): once the copy
// is in, the own grain synth and every live note read the voice's copy ring
// at history 0 and count among its readers, and a note started while frozen
// reads it too; the freeze control reaches them all; the unfreeze sets them
// all back to the input ring, with freeze 0
checkInputFreeze = {
    var voice = 2, copy = engine.copyRingFor(voice), input = engine.ringBuffersFor(voice, engine.inputSource);
    var readers = engine.areaState[\freeze][\inputReaders], synths, frozen, back, reading;
    startInputVoice.(voice);
    command.(\setNotePool, 8);
    [1, 2].do({ arg slot; playNote.(voice, slot, 1.0 + (slot / 4)) });
    server.sync;
    command.(\setGrainParam, voice, \freeze, 1.0);
    h.waitFor({ engine.areaState[\freeze][\copied][voice] }, 3);
    server.sync;
    playNote.(voice, 3, 0.75);
    server.sync;
    synths = [ownGrain.(voice)] ++ (1 .. 3).collect({ arg slot; slotSynth.(voice, slot) });
    reading = { arg synth, ring; (controlOf.(synth, \bufL) == ring[0].bufnum) and: { controlOf.(synth, \phaseBus) == ring[2].index } };
    frozen = synths.collect({ arg synth; synth.notNil and: { reading.(synth, copy) } and: { controlOf.(synth, \history) == 0 }
        and: { controlOf.(synth, \freeze) == 1 } and: { readers[synth].notNil } });
    command.(\setGrainParam, voice, \freeze, 0.0);
    server.sync;
    back = synths.collect({ arg synth; synth.notNil and: { reading.(synth, input) } and: { controlOf.(synth, \freeze) == 0 } });
    check.(frozen.every(_ == true) and: { back.every(_ == true) },
        "notes: an input freeze points every note of the voice at the copy ring (own, notes 1-3 on the copy: %; back on the input ring after the unfreeze: %)".format(
            frozen, back));
    h.stopAllVoices;
};

// A frozen synth voice (3, Sub, frozen on hold) plays its notes as streams
// of its frozen ring: an extra note is a \strataGrainRing of the voice's own
// ring at the head of processGroup, writing its synth path (rateLevel and
// pan 0, the freeze on), at noteRate the note's rate. Slot 0's noteOn sets
// the own grain synth's noteRate and fires its accent; its noteOff parks the
// own grain synth, the synth that sounds a frozen voice's own note. The
// unfreeze, in its bundle: every ring-stream note cut, each live one
// restarted as a voice synth at its kept freq (a releasing one not), the own
// grain synth's noteRate back to 1 and its park open, and a parked own
// note's park on the voice synth again
checkFrozenNotes = {
    var voice = 3, ring = engine.ringBuffersFor(voice, 0), grainRingName = "\\strataGrainRing";
    var own, ownVoice, note, nodes, bundle, streams, restarted, parkedOn, ok;
    startSynthVoice.(voice);
    command.(\setNotePool, 8);
    server.sync; 0.2.wait;
    command.(\setGrainParam, voice, \freeze, 1.0);
    server.sync;
    own = ownGrain.(voice);
    ownVoice = engine.synths[engine.voiceKey(voice)];
    playNote.(voice, 1, 1.5, 1.0, 330.0);
    server.sync;
    note = slotSynth.(voice, 1);
    nodes = h.synthTree(engine.processGroup);
    check.(note.notNil and: { slotRecord.(voice, 1)[\kind] == \stream } and: { nodes.first.notNil } and: { nodes.first[\id] == note.nodeID }
        and: { nodes.first[\def] == \strataGrainRing } and: { near.(nodes.first[\controls][\noteRate], 1.5) }
        and: { nodes.first[\controls][\bufL] == ring[0].bufnum } and: { nodes.first[\controls][\phaseBus] == ring[2].index }
        and: { nodes.first[\controls][\out] == engine.voicePathBus(voice, 0).index } and: { nodes.first[\controls][\rateLevel] == 0 }
        and: { nodes.first[\controls][\pan] == 0 } and: { nodes.first[\controls][\freeze] == 1 } and: { engine.ringReaders[note] == voice }
        and: { near.(controlOf.(own, \noteRate), 1) },
        "notes: on a frozen synth voice a note is a % of the voice's ring at the head of processGroup, at noteRate (first node %)".format(
            grainRingName, nodes.first !? { arg node; [node[\def], node[\controls][\noteRate], node[\controls][\bufL], node[\controls][\out]] }));

    bundle = server.makeBundle(false, { command.(\noteOn, voice, 0, 62.0, 123.0, 1.25, 0.9) });
    server.sendBundle(nil, *bundle);
    server.sync;
    check.(near.(sentValue.(bundle, own, \noteRate), 1.25) and: { sentValue.(bundle, own, \t_accent) == 1 }
        and: { near.(sentValue.(bundle, own, \velocity), 0.9) } and: { near.(controlOf.(own, \noteRate), 1.25) },
        "notes: noteOn on slot 0 of a frozen synth voice sets the own grain synth's noteRate and fires its accent (sent %)".format(
            sentSets.(bundle, own)));

    command.(\noteOff, voice, 0, 0);
    server.sync;
    parkedOn = [controlOf.(own, \noteGate), controlOf.(ownVoice, \noteGate)];
    check.((parkedOn == [0, 0]) and: { slotRecord.(voice, 0)[\parked] },
        "notes: slot 0 of a frozen synth voice parks on its grain synth, and its voice synth with it (ruling 44; [grain synth, voice synth] noteGate: %)".format(parkedOn));

    playNote.(voice, 2, 0.75, 1.0, 165.0);
    playNote.(voice, 3, 1.0, 1.0, 220.0);
    command.(\noteOff, voice, 3, 0);
    server.sync;
    streams = (1 .. 3).collect({ arg slot; slotSynth.(voice, slot) });
    bundle = server.makeBundle(false, { command.(\setGrainParam, voice, \freeze, 0.0) });
    restarted = [1, 2].collect({ arg slot; slotSynth.(voice, slot) });
    server.sendBundle(nil, *bundle);
    server.sync;
    ok = streams.every({ arg synth; synth.notNil and: { sentValue.(bundle, synth, \kill) == 1 } })
        and: { restarted.every({ arg synth; synth.notNil and: { streams.includes(synth).not }
            and: { bundle.any({ arg msg; (msg[0] == 9) and: { msg[2] == synth.nodeID } and: { msg[1].asSymbol == engine.voiceSynthDefs[voice] } }) } }) }
        and: { [1, 2].every({ arg slot; slotRecord.(voice, slot)[\kind] == \voice }) } and: { slotState.(voice, 3) == \empty }
        and: { near.(controlOf.(restarted[0], \freq), 330) } and: { near.(controlOf.(restarted[1], \freq), 165) }
        and: { near.(sentValue.(bundle, own, \noteRate), 1) } and: { sentValue.(bundle, own, \noteGate) == 1 }
        and: { sentValue.(bundle, ownVoice, \noteGate) == 0 } and: { near.(controlOf.(own, \noteRate), 1) }
        and: { controlOf.(ownVoice, \noteGate) == 0 } and: { controlOf.(own, \freeze) == 0 };
    check.(ok,
        "notes: an unfreeze cuts the ring-stream notes, restarts the held ones as voice synths at their freq, and returns noteRate to 1, in the unfreeze's bundle (restarted kinds %, freqs %, own grain noteRate % noteGate %, own voice synth noteGate %)".format(
            [1, 2].collect({ arg slot; slotRecord.(voice, slot)[\kind] }), restarted.collect({ arg synth; controlOf.(synth, \freq) }),
            controlOf.(own, \noteRate), controlOf.(own, \noteGate), controlOf.(ownVoice, \noteGate)));
    h.stopAllVoices;
};

// Spectral freeze (the high tier, an engine of its own): a frozen synth
// voice's spectral writer holds its ring, and a note played on it is a
// ring-stream note like a hold's; with the own note parked (on its grain
// synth) the voice's synth path still carries the note's stream of the
// frozen sound. The voice (4, Pulse) plays 2.2 s first, so its ring holds
// sound
checkSpectralNotes = {
    var root = h.tempDir +/+ "notes-high/", write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    var other, to, voice = 4, note, writer, probe, bus, level, kind;
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 16\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    to = { arg name ... args; h.commandTo(other, name, *args) };
    to.(\setGrainSource, voice, 0);
    to.(\voiceOn, voice, 110.0, 0.4, 0.0, 0.1, 20.0, 1.0);
    to.(\setNotePool, 8);
    server.sync; 2.2.wait;
    to.(\setGrainParam, voice, \freezeMode, 1.0);
    to.(\setGrainParam, voice, \freeze, 1.0);
    server.sync; 0.3.wait;
    to.(\noteExpression, voice, 1, *neutralExpression);
    to.(\noteOn, voice, 1, 67.0, 165.0, 1.5, 1.0);
    to.(\noteOff, voice, 0, 0);
    server.sync;
    note = other.areaState[\notes][\slots][voice][1][\synth];
    kind = other.areaState[\notes][\slots][voice][1][\kind];
    writer = other.ringWriterFor(voice);
    2.4.wait;   // the own grain synth's park closes over the grain release
    bus = Bus.control(server, 1);
    probe = Synth(\strataCheckPeak, [\in, other.voicePathBus(voice, 0), \out, bus], other.processGroup, \addToTail);
    server.sync;
    level = h.measure(probe, bus, 0.5)[0];
    probe.free; bus.free;
    check.((other.tier == \high) and: { writer.notNil } and: { writer.defName.asSymbol == \strataRingWriteSpectral }
        and: { kind == \stream } and: { note.notNil } and: { note.defName.asSymbol == \strataGrainRing }
        and: { near.(controlOf.(note, \noteRate), 1.5) } and: { level > 0.001 },
        "notes: spectral freeze plays ring-stream notes too (tier %, ring writer %, note %, kind %, the synth path's level with the own note parked %)".format(
            other.tier, writer !? { writer.defName }, note !? { note.defName }, kind, level));
    h.stopAllVoices(other);
    h.freeEngine(other);
    server.sync;
};

// Ruling 44: the own note's park through a synth voice's freeze. The own
// voice synth's noteGate follows the park, frozen or not; while frozen a
// slot-0 command reaches the own grain synth too (the freeze itself parks
// nothing: the frozen ring holds the chord); the unfreeze sets the grain
// synth's noteGate back to 1 and leaves the voice synth where the park
// says, so an unfreeze under a parked own note makes no sound of it. The
// voice (4, Pulse, its 2 s attack waited out, then its attack and release
// set short) is parked before its freeze, then during one; its voice
// synth's level (a peak meter on its bus) over 0.3 s after each unfreeze
// stays under 1% of its level playing
checkParkThroughFreeze = {
    var voice = 4, probe, results, voiceSynth, grain;
    startSynthVoice.(voice);
    server.sync; 2.3.wait;
    command.(\setVoiceParam, voice, \attackTime, 0.05);
    command.(\setVoiceParam, voice, \releaseTime, 0.3);
    voiceSynth = engine.synths[engine.voiceKey(voice)];
    grain = ownGrain.(voice);
    probe = levelProbe.(voice);
    server.sync;
    results = [\before, \during].collect({ arg order;
        var playing = h.measure(probe[0], probe[1], 0.3)[0], frozen, after, gates;
        if (order == \before) {
            command.(\noteOff, voice, 0, 0); server.sync; 0.6.wait;
            command.(\setGrainParam, voice, \freeze, 1.0); server.sync; 0.3.wait;
        } {
            command.(\setGrainParam, voice, \freeze, 1.0); server.sync; 0.3.wait;
            command.(\noteOff, voice, 0, 0); server.sync; 0.6.wait;
        };
        frozen = [controlOf.(voiceSynth, \noteGate), controlOf.(grain, \noteGate)];
        command.(\setGrainParam, voice, \freeze, 0.0);
        after = h.measure(probe[0], probe[1], 0.3)[0];
        gates = [controlOf.(voiceSynth, \noteGate), controlOf.(grain, \noteGate)];
        command.(\noteOn, voice, 0, 60.0, 220.0, 1.0, 1.0);   // unparked again, for the next order
        server.sync; 0.5.wait;
        [order, playing, frozen, after, gates]
    });
    probe[0].free; probe[1].free;
    check.(results.every({ arg each; (each[1] > 0.01) and: { each[3] < (each[1] * 0.01) } and: { each[4] == [0, 1] } })
        and: { results[0][2] == [0, 1] } and: { results[1][2] == [0, 0] },
        "notes: an unfreeze under a parked own note makes no sound of it, parked before the freeze or during it (ruling 44; [order, level playing, [voice synth, grain synth] noteGate frozen, level after the unfreeze, noteGate after]: %)".format(
            results.collect({ arg each; [each[0], each[1].round(0.001), each[2], each[3].round(0.0001), each[4]] })));
    command.(\setVoiceParam, voice, \attackTime, 2.0);
    command.(\setVoiceParam, voice, \releaseTime, 4.0);
    h.stopAllVoices;
};

// Ruling 45: the held notes the engine restarts itself start silent: no
// t_accent, no t_trig, their velocity kept. A chord on a synth voice (6,
// Ring: three notes at velocity 0.7) through synth -> buffer -> input ->
// synth, then frozen with ring-stream notes and unfrozen: every /s_new of a
// restarted note that reached the server carries no accent or trigger and
// the note's velocity
checkSilentRestarts = {
    var voice = 6, starts = List.new, restartedOf, units;
    startSynthVoice.(voice);
    command.(\setNotePool, 16);
    if (engine.bufferFrames[0] == 0) { command.(\loadBuffer, 0, h.stereoPath, 0); h.waitFor({ engine.bufferFrames[0] > 0 }, 3) };
    (1 .. 3).do({ arg slot; playNote.(voice, slot, 1.0, 0.7, 220.0 + (slot * 55)) });
    server.sync;
    restartedOf = { arg messages;
        (1 .. 3).collect({ arg slot; slotSynth.(voice, slot) }).collect({ arg synth;
            messages.detect({ arg msg; synth.notNil and: { msg[0] == 9 } and: { msg[2] == synth.nodeID } }) })
    };
    [1, engine.inputSource, 0].do({ arg source;
        units = h.wireUnits({ command.(\setGrainSource, voice, source) });
        starts.addAll(restartedOf.(wireMessages.(units)));
        server.sync;
    });
    command.(\setGrainParam, voice, \freeze, 1.0);
    server.sync;
    (1 .. 3).do({ arg slot; command.(\noteOff, voice, slot, 1) });
    (1 .. 3).do({ arg slot; playNote.(voice, slot, 1.0, 0.7, 220.0 + (slot * 55)) });
    server.sync;
    units = h.wireUnits({ command.(\setGrainParam, voice, \freeze, 0.0) });
    starts.addAll(restartedOf.(wireMessages.(units)));
    server.sync;
    check.((starts.size == 12) and: { starts.every(_.notNil) }
        and: { starts.every({ arg msg; ((startValue.(msg, \t_accent) ? 0) == 0) and: { (startValue.(msg, \t_trig) ? 0) == 0 }
            and: { near.(startValue.(msg, \velocity), 0.7) } }) },
        "notes: notes the engine restarts (a source switch, an unfreeze) start with no accent or trigger, their velocity kept (ruling 45; [t_accent, t_trig, velocity] of each start: %)".format(
            starts.collect({ arg msg; msg !? { [startValue.(msg, \t_accent), startValue.(msg, \t_trig), startValue.(msg, \velocity)] } })));
    h.stopAllVoices;
};

// Ruling 47: a slot-0 noteOn on an unfrozen voice only unparks the own note
// (noteGate 1): Lua's retrigger after it accents the voice and plucks
// Karplus once. On a Karplus voice (5) a slot-0 noteOn and a retrigger send
// the own voice synth t_trig once; on a buffer voice (1) the slot-0 noteOn
// sends the own grain synth no t_accent (the stage's accent is the
// retrigger's)
checkOwnNoteOnAccent = {
    var karplus = 5, buffer = 1, voiceSynth, grain, karplusMessages, bufferMessages;
    startSynthVoice.(karplus);
    startBufferVoice.(buffer);
    voiceSynth = engine.synths[engine.voiceKey(karplus)];
    grain = ownGrain.(buffer);
    command.(\noteOff, karplus, 0, 0);
    command.(\noteOff, buffer, 0, 0);
    server.sync;
    karplusMessages = wireMessages.(h.wireUnits({
        command.(\noteOn, karplus, 0, 60.0, 220.0, 1.0, 0.8);
        command.(\retrigger, karplus, 0.8);
    }));
    bufferMessages = wireMessages.(h.wireUnits({ command.(\noteOn, buffer, 0, 60.0, 220.0, 1.0, 0.8) }));
    server.sync;
    check.((sentCount.(karplusMessages, voiceSynth, \t_trig, 1) == 1) and: { sentCount.(karplusMessages, voiceSynth, \noteGate, 1) == 1 }
        and: { sentCount.(bufferMessages, grain, \t_accent, 1) == 0 } and: { sentCount.(bufferMessages, grain, \noteGate, 1) == 1 },
        "notes: a slot-0 noteOn on an unfrozen voice only unparks it: with the retrigger after it Karplus gets one t_trig, and a buffer voice's grain synth no t_accent (ruling 47; Karplus t_trig sent %, buffer t_accent sent %)".format(
            sentCount.(karplusMessages, voiceSynth, \t_trig, 1), sentCount.(bufferMessages, grain, \t_accent, 1)));
    h.stopAllVoices;
};

if (area.isNil or: { state.isNil }) {
    check.(false, "notes: the area runs at order 170 (no strataAreaNotes)");
} {
    checkState.value;
    checkSignatures.value;
    checkNoNodes.value;
    checkRecorded.value;
    checkIgnored.value;
    checkHookRestored.value;
    checkPool.value;
    // the note lifecycle: buffer and input notes
    checkBufferNotes.value;
    checkSlotChurn.value;
    checkInputNote.value;
    checkGrainFanOut.value;
    checkExpression.value;
    checkFailedNoteStart.value;
    h.stopAllVoices;
    // synth-voice notes
    checkSynthNote.value;
    checkSynthChord.value;
    checkVoiceFanOut.value;
    checkExpressionKinds.value;
    h.stopAllVoices;
    // the park, the voice's commands and the pool
    checkPark.value;
    checkVoiceCommands.value;
    checkPoolFull.value;
    checkPoolRandom.value;
    checkPoolShrink.value;
    checkCuttingBound.value;
    h.stopAllVoices;
    // sources, buffers and the input freeze
    checkSourceSwitch.value;
    checkBufferLoad.value;
    checkInputFreeze.value;
    h.stopAllVoices;
    // frozen synth voices
    checkFrozenNotes.value;
    checkSpectralNotes.value;
    h.stopAllVoices;
    // the fix round's rulings: the park through a freeze, silent restarts,
    // the slot-0 noteOn's accent
    checkParkThroughFreeze.value;
    checkSilentRestarts.value;
    checkOwnNoteOnAccent.value;
    h.stopAllVoices;
    // the pool as the area found it: none
    command.(\setNotePool, 0);
};
h.stopAllVoices;
}
