// test/engine_check/notes.scd
// The notes area (lib/engine/StrataNotes.sc, 3.5): its order, its literals
// and state, and its four commands as checked stubs. Each command checks its
// indices and that every continuous argument is finite (a bad one is ignored
// with one line), clips its continuous arguments, records them and creates
// no node; setNotePool keeps the size. See docs/notes/engine/notes.md.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var area = engine.strataAreas.detect({ arg each; each[\name] == \notes });
var state = engine.areaState[\notes];
var nan = 0.0 / 0.0;
var nodeCounts, sameReceived, withIgnoredLines, checkState, checkSignatures, checkNoNodes, checkRecorded, checkIgnored;
var checkHookRestored, checkPool;

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
        and: { slots.size == engine.numVoices }
        and: { slots.every({ arg each; (each.size == engine.noteSlots) and: { each.every(_.isNil) } }) },
        "notes: the area holds no pool and an empty slot for every note of every voice (noteSlots %, notePoolMax %, noteLag %, pool %, slots %)".format(
            engine.noteSlots, engine.notePoolMax, engine.noteLag, state[\pool], slots !? { slots.collect(_.size) }));
};

checkSignatures = {
    var signatures = [[\noteOn, "iiffff"], [\noteOff, "iii"], [\noteExpression, "iifffff"], [\setNotePool, "i"]];
    check.(signatures.every({ arg pair; h.formatOf(pair[0]) == pair[1] }),
        "notes: the four commands exist with their signatures (got %)".format(signatures.collect({ arg pair; h.formatOf(pair[0]) })));
};

// Each command, with valid arguments, to a running voice: the server's
// node count is the same after each
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
    var before, counts = List.new;
    command.(\voiceOn, 0, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.3.wait;
    before = nodeCounts.value;
    calls.do({ arg call;
        command.(*call);
        server.sync; 0.05.wait;
        counts.add(nodeCounts.value);
    });
    check.(before.notNil and: { engine.voiceRunning(0) } and: { counts.every({ arg each; each == before }) },
        "notes: no command creates a node (synths and groups before %, after each %)".format(before, counts.asArray));
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
    var recorded = calls.collect({ arg call;
        command.(*call[0]);
        state[\received][call[0][0]] == call[1]
    });
    check.(recorded.every(_ == true),
        "notes: each command records its arguments, the continuous ones clipped (wrong: %)".format(
            calls.select({ arg call, index; recorded[index].not }).collect({ arg call; [call[0], state[\received][call[0][0]]] })));
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
    // the pool as the area found it: none
    command.(\setNotePool, 0);
};
h.stopAllVoices;
}
