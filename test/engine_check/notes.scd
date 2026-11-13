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
    // the pool as the area found it: none
    command.(\setNotePool, 0);
};
h.stopAllVoices;
}
