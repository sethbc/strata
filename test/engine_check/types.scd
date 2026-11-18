// test/engine_check/types.scd
// The types area (3.8, design §0.3): a voice's synth is its type, one of
// the engine's voiceTypeDefs. Every voice starts on its own type, every
// type's def is known to controlPairs, and gateVoice cuts a releasing voice
// synth of another type instead of taking it back. Then the files
// test/engine_check/types/<key>.scd, sorted, each a function of h (a type
// package's own checks of its def).
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var typeDefs = engine.tryPerform(\voiceTypeDefs) ? [];
var typeOf = { arg voice; engine.tryPerform(\voiceType, voice) };
var defOf = { arg voice; engine.tryPerform(\voiceDefFor, voice) };
var isVoiceDef = { arg name; typeDefs.includes(name.asSymbol) };
var isStartOf = { arg msg, synth;
    synth.notNil and: { (msg[0] == 9) or: { msg[0] == '/s_new' } } and: { msg[2] == synth.nodeID } };
var isKillOf = { arg msg, synth;
    synth.notNil and: { (msg[0] == 15) or: { msg[0] == '/n_set' } } and: { msg[1] == synth.nodeID }
        and: { (2, 4 .. (msg.size - 2)).any({ arg index; (msg[index].asSymbol == \kill) and: { msg[index + 1] == 1 } }) } };
var nodeIDs = { h.synthTree(context.xg).collect({ arg node; node[\id] }) };
var startVoice = { arg voice, freq = 220.0;
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, freq, 0.2, 0.0, 0.1, 10.0, 1.0);
    server.sync; 0.05.wait;
};
var typeFiles;

// "types: every voice starts on its own type"
check.((typeDefs.size >= engine.numVoices) and: { (0 .. (engine.numVoices - 1)).every({ arg voice;
    (typeOf.(voice) == voice) and: { defOf.(voice) == typeDefs[voice] } }) },
    "types: every voice starts on its own type (types %, defs %)".format(
        engine.numVoices.collect({ arg voice; typeOf.(voice) }), engine.numVoices.collect({ arg voice; defOf.(voice) })));

// "types: controlPairs knows every type's def"
check.((typeDefs.size >= engine.numVoices) and: { typeDefs.every({ arg name;
    engine.controlPairs(name, Dictionary[\freq -> 1]).notEmpty }) },
    "types: controlPairs knows every type's def (%)".format(typeDefs));

// "types: a releasing voice synth of another type is cut, never taken
// back": voice 0 (Resonator, an 8 s release) stopped, put on type 1 (a
// direct write of its type), started again: the releasing Resonator is cut
// (in cuttingSynths, kill 1 in the start's messages) and gone within
// switchCutTime and a margin, and an FM synth runs. The control case
// (voice 2 stopped and started on its own type) re-gates its releasing synth
{
    var old, units, new, cutting, killed, gone, control, controlOld;
    startVoice.(0);
    startVoice.(2);
    0.3.wait;
    old = engine.synths[engine.voiceKey(0)];
    controlOld = engine.synths[engine.voiceKey(2)];
    command.(\voiceOff, 0);
    command.(\voiceOff, 2);
    server.sync; 0.1.wait;
    engine.areaState[\voices][\types] !? { arg types; types[0] = 1 };
    units = h.wireUnits({ command.(\voiceOn, 0, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0) });
    cutting = engine.cuttingSynths[0].includes(old);
    new = engine.synths[engine.voiceKey(0)];
    killed = units.flatten(1).any({ arg msg; isKillOf.(msg, old) });
    command.(\voiceOn, 2, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    control = engine.synths[engine.voiceKey(2)];
    (engine.switchCutTime + 0.1).wait; server.sync;
    gone = nodeIDs.value.includes(old.nodeID).not;
    check.(cutting and: { killed } and: { gone } and: { new !== old } and: { new.notNil }
        and: { new.defName.asSymbol == \strataFM } and: { nodeIDs.value.includes(new.nodeID) },
        "types: a releasing voice synth of another type is cut, never taken back (cutting %, kill 1 sent %, gone %, the new synth %)".format(
            cutting, killed, gone, new !? { new.defName }));
    check.((control === controlOld) and: { control.notNil },
        "types: a releasing voice synth of the voice's own type is re-gated (the same synth %)".format(control === controlOld));
    h.stopAllVoices;
    engine.areaState[\voices][\types] !? { arg types; types[0] = 0 };
}.value;

// "types: setVoiceType is "ii""
check.(h.formatOf(\setVoiceType) == "ii", "types: setVoiceType is \"ii\" (%)".format(h.formatOf(\setVoiceType)));

// Ignored arguments: a voice outside the voices or not an integer, or a type
// outside the list or not an integer, raise nothing and change no node,
// tracked synth, voiceControls or type
{
    var raised = 0, before, after, state;
    state = { [h.synthTree(context.xg).collect({ arg node; [node[\id], node[\def]] }), engine.synths.keys.asArray.sort,
        engine.synths.values.collect(_.nodeID).asArray.sort, engine.voiceControls.collect({ arg dict; dict.asSortedArray }),
        engine.cuttingSynths.collect({ arg set; set.size }), engine.numVoices.collect({ arg voice; typeOf.(voice) })] };
    startVoice.(0);
    before = state.value;
    [-1, engine.numVoices, 99, 1.5].do({ arg voice; try { command.(\setVoiceType, voice, 1) } { raised = raised + 1 } });
    [-1, typeDefs.size, 99, 1.5].do({ arg type; try { command.(\setVoiceType, 0, type) } { raised = raised + 1 } });
    server.sync;
    after = state.value;
    check.((raised == 0) and: { after == before },
        "types: setVoiceType ignores the voices -1, %, 99 and 1.5 and the types -1, %, 99 and 1.5, changing nothing (% raised; changed: %)".format(
            engine.numVoices, typeDefs.size, raised, [\nodes, \keys, \synths, \voiceControls, \cutting, \types].select({ arg name, index; after[index] != before[index] })));
    // the same type again: no node, the cutting set as it was
    before = state.value;
    command.(\setVoiceType, 0, 0);
    server.sync;
    after = state.value;
    check.(after == before, "types: setVoiceType of the voice's own type is a no-op (changed: %)".format(
        [\nodes, \keys, \synths, \voiceControls, \cutting, \types].select({ arg name, index; after[index] != before[index] })));
    h.stopAllVoices;
}.value;

// A stopped voice records its type: no node; its next voiceOn starts the
// type's def
{
    var nodesBefore, nodesAfter, new;
    nodesBefore = nodeIDs.value.size;
    command.(\setVoiceType, 1, 3);
    server.sync;
    nodesAfter = nodeIDs.value.size;
    command.(\voiceOn, 1, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    server.sync;
    new = engine.synths[engine.voiceKey(1)];
    check.((nodesAfter == nodesBefore) and: { typeOf.(1) == 3 } and: { new.notNil } and: { new.defName.asSymbol == typeDefs[3] }
        and: { h.synthTree(context.xg).any({ arg node; (node[\id] == new.nodeID) and: { node[\def] == typeDefs[3] } }) },
        "types: a stopped voice records its type, and its next start plays it (nodes % then %, type %, started %)".format(
            nodesBefore, nodesAfter, typeOf.(1), new !? { new.defName }));
    h.stopAllVoices;
    command.(\setVoiceType, 1, 1);
}.value;

// A buffer voice and an input voice record their type: no voice synth; a
// switch to the synth source then starts the type's def
[[2, 1, 4], [3, engine.inputSource, 5]].do({ arg each;
    var voice = each[0], source = each[1], type = each[2], without, back;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    server.sync;
    command.(\setVoiceType, voice, type);
    server.sync;
    without = engine.synths[engine.voiceKey(voice)].isNil and: { h.synthTree(context.xg).every({ arg node;
        isVoiceDef.(node[\def]).not or: { node[\controls][\out].asInteger != engine.granBuses[voice].index } }) };
    command.(\setGrainSource, voice, 0);
    server.sync;
    back = engine.synths[engine.voiceKey(voice)];
    check.(without and: { typeOf.(voice) == type } and: { back.notNil } and: { back.defName.asSymbol == typeDefs[type] },
        "types: a voice on source % records its type with no voice synth, and its switch to the synth plays it (no voice synth %, type %, then %)".format(
            source, without, typeOf.(voice), back !? { back.defName }));
    h.stopAllVoices;
    command.(\setVoiceType, voice, voice);
});

// A running synth voice: the switch cuts its voice synth and starts the new
// type's at the head of voiceGroup, in one bundle; the old one is cutting
// (kill 1) and gone within switchCutTime and a margin. Six switches sent
// without a yield never hold more than two voice synths, tracked (live,
// releasing, fading and cutting) or on the server (synced after each), and
// the count reaches two
{
    var voice = 4, old, new, units, bundled, head, cutting, gone, tracked = 0, onServer = 0;
    var types = [1, 2, 3, 0, 5, 4];
    var trackedCount = {
        var held = IdentitySet.new, key = engine.voiceKey(voice);
        [engine.synths, engine.releasingSynths[voice]].do({ arg dict; dict[key] !? { arg synth; held.add(synth) } });
        held.addAll(engine.fadingSynths[voice]); held.addAll(engine.cuttingSynths[voice]);
        held.count({ arg synth; isVoiceDef.(synth.defName) })
    };
    var serverCount = { h.synthTree(context.xg).count({ arg node;
        isVoiceDef.(node[\def]) and: { node[\controls][\out].asInteger == engine.granBuses[voice].index } }) };
    startVoice.(voice);
    0.2.wait;
    old = engine.synths[engine.voiceKey(voice)];
    units = h.wireUnits({ command.(\setVoiceType, voice, 2) });
    new = engine.synths[engine.voiceKey(voice)];
    cutting = engine.cuttingSynths[voice].includes(old);
    bundled = units.any({ arg unit; unit.any({ arg msg; isStartOf.(msg, new) }) and: { unit.any({ arg msg; isKillOf.(msg, old) }) } });
    server.sync;
    head = h.synthTree(engine.voiceGroup).first !? { arg node; node[\id] == new.nodeID } ? false;
    (engine.switchCutTime + 0.1).wait; server.sync;
    gone = nodeIDs.value.includes(old.nodeID).not;
    check.((new !== old) and: { new.notNil } and: { new.defName.asSymbol == typeDefs[2] } and: { cutting } and: { bundled }
        and: { head } and: { gone } and: { engine.synths.keys.count({ arg key; key == engine.voiceKey(voice) }) == 1 },
        "types: setVoiceType on a running synth voice cuts its voice synth and starts the type's at the head of voiceGroup in one bundle (new %, old cutting %, one bundle %, at the head %, old gone %)".format(
            new !? { new.defName }, cutting, bundled, head, gone));
    types.do({ arg type; command.(\setVoiceType, voice, type); tracked = max(tracked, trackedCount.value) });
    (engine.switchCutTime + 0.1).wait; server.sync;
    types.do({ arg type; command.(\setVoiceType, voice, (type + 1) % typeDefs.size); server.sync; onServer = max(onServer, serverCount.value) });
    check.((tracked == 2) and: { onServer <= 2 } and: { onServer >= 1 },
        "types: six switches of a running voice hold at most two voice synths (tracked: at most %, on the server: at most %)".format(tracked, onServer));
    h.stopAllVoices;
    command.(\setVoiceType, voice, voice);
}.value;

// The extra notes: three voice synth notes live and one releasing; a
// switch leaves three live notes of the new def at their kept freq, the
// three old ones cutting, and the releasing one releasing, not restarted
{
    var voice = 1, slots = [1, 2, 3, 4], old, after, records, ok, freqs;
    var record = { arg slot; engine.noteRecord(voice, slot) };
    startVoice.(voice);
    command.(\setNotePool, engine.notePoolMax);
    slots.do({ arg slot;
        command.(\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
        command.(\noteOn, voice, slot, 60.0 + slot, 220.0 + (slot * 55), 1.0, 1.0);
    });
    command.(\noteOff, voice, 4, 0);
    server.sync; 0.05.wait;
    old = slots.collect({ arg slot; record.(slot)[\synth] });
    command.(\setVoiceType, voice, 2);
    after = slots.collect({ arg slot; record.(slot)[\synth] });
    records = slots.collect({ arg slot; [record.(slot)[\state], record.(slot)[\cutting] === old[slot - 1]] });
    server.sync;
    freqs = [1, 2, 3].collect({ arg slot; after[slot - 1] !? { arg synth; h.getControl(synth, \freq) } });
    ok = [1, 2, 3].every({ arg slot; var synth = after[slot - 1];
        synth.notNil and: { synth !== old[slot - 1] } and: { synth.defName.asSymbol == typeDefs[2] }
            and: { records[slot - 1] == [\live, true] } and: { (freqs[slot - 1] ? 0 - (220.0 + (slot * 55))).abs < 0.001 } })
        and: { after[3] === old[3] } and: { record.(4)[\state] == \releasing } and: { record.(4)[\cutting].isNil };
    check.(ok, "types: a switch under a chord restarts the three live voice synth notes on the new def at their freq, cuts the old ones and leaves the releasing one releasing ([state, old cutting]: %, freqs %, releasing kept %)".format(
        records, freqs, after[3] === old[3]));
    h.stopAllVoices;
    command.(\setNotePool, 0);
    command.(\setVoiceType, voice, voice);
}.value;

// The own note's park reaches the new def: noteOff on slot 0 parks it, and
// the switch's new voice synth starts at noteGate 0
{
    var voice = 5, new;
    startVoice.(voice);
    command.(\noteOff, voice, 0, 0);
    server.sync;
    command.(\setVoiceType, voice, 0);
    server.sync;
    new = engine.synths[engine.voiceKey(voice)];
    check.(new.notNil and: { new.defName.asSymbol == typeDefs[0] } and: { h.getControl(new, \noteGate) == 0 },
        "types: a parked own note stays parked on the new type's voice synth (noteGate %)".format(new !? { h.getControl(new, \noteGate) }));
    h.stopAllVoices;
    command.(\setVoiceType, voice, voice);
}.value;

// voiceSynthFreed restarts the voice's current type: the live voice synth
// freed from outside comes back as the type's def
{
    var voice = 6, old, back;
    startVoice.(voice);
    command.(\setVoiceType, voice, 3);
    server.sync; 0.1.wait;
    old = engine.synths[engine.voiceKey(voice)];
    server.sendMsg('/n_free', old.nodeID);
    h.waitFor({ engine.synths[engine.voiceKey(voice)] !== old }, 2);
    server.sync;
    back = engine.synths[engine.voiceKey(voice)];
    check.(back.notNil and: { back !== old } and: { back.defName.asSymbol == typeDefs[3] },
        "types: a voice synth that frees on its own is started again as the voice's current type (%)".format(back !? { back.defName }));
    h.stopAllVoices;
    command.(\setVoiceType, voice, voice);
}.value;

// "types: a frozen synth voice keeps its ring and its held sound across
// setVoiceType" (design §0.3; Review Focus 2's engine half): voice 0 on
// the Resonator at 220 Hz for 2 s, frozen (hold), two ring-stream notes;
// after 1 s it switches to type 1. The ring writer is the same node, still
// paused, never replaced; freeze stays 1; the synth path's RMS over the
// second after the switch is within 1 dB of the second before; an FM voice
// synth runs and the Resonator is cutting; the stream notes keep their
// nodes. On a high engine the same with freezeMode 1 (spectral): the
// spectral writer is the same node
SynthDef(\strataCheckTypesWindowRms, { arg in, out, t_reset = 0;
    var square = In.ar(in, 2).squared.sum * 0.5;
    Out.kr(out, A2K.kr(Sweep.ar(t_reset, square * SampleRate.ir) / Sweep.ar(t_reset, SampleRate.ir).max(1)));
}).add;
server.sync;
{
    var frozenSwitch = { arg target, mode, label;
        var run = { arg name ... args; h.commandTo(target, name, *args) };
        var voice = 0, writerBefore, writerAfter, phaseMoving, old, new, streams, streamsAfter, before, after, db;
        var meterBus = Bus.control(server, 1), meter, window, phaseBus = target.areaState[\rings][\phaseBuses][voice];
        window = { meter.set(\t_reset, 1); 1.0.wait; h.readBusValue(meterBus).max(0).sqrt };
        run.(\setGrainSource, voice, 0);
        run.(\setGrainParam, voice, \freezeMode, mode);
        run.(\voiceOn, voice, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
        2.0.wait;
        run.(\setGrainParam, voice, \freeze, 1.0);
        run.(\setNotePool, 4);
        [1, 2].do({ arg slot;
            run.(\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
            run.(\noteOn, voice, slot, 60.0, 220.0, 1.0 + (slot / 4), 1.0);
        });
        server.sync;
        meter = Synth(\strataCheckTypesWindowRms, [\in, target.voicePathBus(voice, 0), \out, meterBus], target.processGroup, \addToTail);
        server.sync;
        writerBefore = target.ringWriterFor(voice);
        streams = [1, 2].collect({ arg slot; [target.noteRecord(voice, slot)[\kind], target.noteRecord(voice, slot)[\synth]] });
        old = target.synths[target.voiceKey(voice)];
        before = window.value;
        run.(\setVoiceType, voice, 1);
        new = target.synths[target.voiceKey(voice)];
        after = window.value;
        writerAfter = target.ringWriterFor(voice);
        streamsAfter = [1, 2].collect({ arg slot; [target.noteRecord(voice, slot)[\kind], target.noteRecord(voice, slot)[\synth]] });
        phaseMoving = h.readBusValue(phaseBus);
        0.2.wait;
        phaseMoving = h.readBusValue(phaseBus) != phaseMoving;
        db = if ((before > 0) and: { after > 0 }) { (after / before).ampdb } { inf };
        check.((writerAfter === writerBefore) and: { writerAfter.notNil }
            and: { h.synthTree(target.voiceGroup).any({ arg node; (node[\id] == writerBefore.nodeID)
                and: { node[\def] == if (mode == 0) { \strataRingWrite } { \strataRingWriteSpectral } } }) }
            and: { (mode == 0).not or: { phaseMoving.not } }
            and: { target.grainControls[voice][\freeze] == 1 } and: { target.areaState[\freeze][\frozen][voice] },
            "types: a frozen synth voice keeps its ring across setVoiceType (% tier, %: the same writer %, %, freeze %)".format(
                target.tier, label, writerAfter === writerBefore, if (mode == 0) { "paused " ++ phaseMoving.not } { "spectral" },
                target.grainControls[voice][\freeze]));
        check.((db.abs <= 1) and: { before > 1e-4 } and: { new.notNil } and: { new.defName.asSymbol == \strataFM }
            and: { target.cuttingSynths[voice].includes(old) or: { old.isPlaying.not } },
            "types: a frozen synth voice keeps its held sound across setVoiceType (% tier, %: synth path RMS % then %, % dB; new %)".format(
                target.tier, label, before.round(0.00001), after.round(0.00001), db.round(0.01), new !? { new.defName }));
        check.((streamsAfter == streams) and: { streams.every({ arg each; (each[0] == \stream) and: { each[1].notNil } }) },
            "types: a frozen voice's stream notes keep their nodes across setVoiceType (% tier: %)".format(target.tier, streamsAfter));
        meter.free; meterBus.free;
        run.(\setGrainParam, voice, \freeze, 0.0);
        run.(\setGrainParam, voice, \freezeMode, 0.0);
        h.stopAllVoices(target);
        run.(\setNotePool, 0);
        run.(\setVoiceType, voice, voice);
        server.sync;
    };
    var root = h.tempDir +/+ "types-high/", write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    var other;
    frozenSwitch.(engine, 0, "hold");
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    check.(other.tier == \high, "types: the spectral case's engine runs the high tier (%)".format(other.tier));
    { frozenSwitch.(other, 1, "spectral") }.protect({ h.freeEngine(other); server.sync });
}.value;

// A type package's own checks: test/engine_check/types/<key>.scd, sorted,
// each a function of h
typeFiles = (h.testDir +/+ "engine_check" +/+ "types" +/+ "*.scd").pathMatch.sort;
typeFiles.do({ arg path;
    var area = path.load;
    if (area.isKindOf(Function)) { area.value(h) } {
        check.(false, "types: % returns a function of h".format(path.basename));
    };
    h.stopAllVoices;
});
h.stopAllVoices;
}
