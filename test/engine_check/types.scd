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
// three old ones cutting, and the releasing one releasing, not restarted.
// The three starts are in the switch's one bundle with the voice synth's
// start and the kills of the old voice synth and of the three old notes
// (restartVoiceNotes runs inside replaceVoiceType's bundle), as the
// unfreeze's chord check below asks of a waiting switch
{
    var voice = 1, slots = [1, 2, 3, 4], old, after, records, ok, freqs, units, oldVoice, newVoice, bundled;
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
    oldVoice = engine.synths[engine.voiceKey(voice)];
    units = h.wireUnits({ command.(\setVoiceType, voice, 2) });
    newVoice = engine.synths[engine.voiceKey(voice)];
    after = slots.collect({ arg slot; record.(slot)[\synth] });
    records = slots.collect({ arg slot; [record.(slot)[\state], record.(slot)[\cutting] === old[slot - 1]] });
    bundled = units.any({ arg unit;
        unit.any({ arg msg; isStartOf.(msg, newVoice) }) and: { unit.any({ arg msg; isKillOf.(msg, oldVoice) }) }
            and: { [1, 2, 3].every({ arg slot; unit.any({ arg msg; isStartOf.(msg, after[slot - 1]) })
                and: { unit.any({ arg msg; isKillOf.(msg, old[slot - 1]) }) } }) } });
    server.sync;
    freqs = [1, 2, 3].collect({ arg slot; after[slot - 1] !? { arg synth; h.getControl(synth, \freq) } });
    ok = [1, 2, 3].every({ arg slot; var synth = after[slot - 1];
        synth.notNil and: { synth !== old[slot - 1] } and: { synth.defName.asSymbol == typeDefs[2] }
            and: { records[slot - 1] == [\live, true] } and: { (freqs[slot - 1] ? 0 - (220.0 + (slot * 55))).abs < 0.001 } })
        and: { after[3] === old[3] } and: { record.(4)[\state] == \releasing } and: { record.(4)[\cutting].isNil }
        and: { oldVoice.notNil } and: { newVoice !== oldVoice } and: { bundled };
    check.(ok, "types: a switch under a chord restarts the three live voice synth notes on the new def at their freq, cuts the old ones and leaves the releasing one releasing, in the switch's one bundle ([state, old cutting]: %, freqs %, releasing kept %, one bundle %)".format(
        records, freqs, after[3] === old[3], bundled));
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
// paused, never replaced; freeze stays 1, kept and on the voice's ring
// grain synth on the server; the synth path's RMS over the second after
// the switch is within 1 dB of the second before; an FM voice synth runs
// and the Resonator is cutting (a hold switches at once); the stream notes
// keep their nodes. On a high engine the same with freezeMode 1 (spectral):
// the spectral writer is the same node, and the switch waits for the
// unfreeze (PV_MagFreeze holds the magnitudes and takes the phases from the
// voice bus, so a new voice synth would set the held spectrum's phases):
// the Resonator keeps running and the held sound stays within the band of
// a freeze with no switch (the edges beside the hold limit, below), each
// second measured where the grains play only held audio: from
// spectralSettleSeconds after the freeze (the frozen grains start
// grainMaxSeconds back, in the voice's live audio from before it) and from
// spectralReachSeconds after the switch. The unfreeze then makes the
// switch, in its own bundle. The grains
// read the held ring at one place and pan (posSpread and panSpread 0), so
// the held sound repeats and two seconds of it match: with the spreads at
// their 0.5 a hold's own level moved -1.27 to +0.5 dB between the seconds
// with no switch (3.13), and with them at 0 -0.28 to -0.10 dB, the switch
// alike
SynthDef(\strataCheckTypesWindowRms, { arg in, out, t_reset = 0;
    var square = In.ar(in, 2).squared.sum * 0.5;
    Out.kr(out, A2K.kr(Sweep.ar(t_reset, square * SampleRate.ir) / Sweep.ar(t_reset, SampleRate.ir).max(1)));
}).add;
server.sync;
{
    // The hold case's limit (dB, either way), and the spectral case's band
    // (dB, the held second after the waiting switch against the held second
    // before; docs/notes/engine/types.md, #798). The waiting switch leaves
    // the voice synth alone, so the level moves as with no switch: -1.00 to
    // +0.77 dB in X6's runs (sd 0.37 on 3.14.1, n 32; 0.28 on 3.13, n 30),
    // and across the waiting switch -0.60 to +0.73 on 3.14.1 (sd 0.31, n 30)
    // and -0.77 to +0.90 on 3.13 (sd 0.42, n 20). The edges are three
    // standard deviations (the larger, 0.42) past the worst figure each way,
    // rounded out to the tenth: -1.00 - 1.26 = -2.26, so -2.3; +0.90 + 1.26
    // = +2.16, so +2.2. A switch made at once read -7.67 to +0.10 dB on
    // 3.14.1 (mean -2.36) and -7.87 to +0.20 on 3.13 (mean -2.57): the wait
    // check, not the band, is what fails it. Silence (the level x 0.1 reads
    // -20 to -29 dB) and a held spectrum that runs away (x 10: +11 to +20
    // dB) fail the band. A hold lost to the live voice read +0.8 to +13.0
    // dB: the ring check is what catches it (the writer replaced, freeze 0)
    var holdLimitDb = 1, spectralLowDb = -2.3, spectralHighDb = 2.2;
    var spectralSettleSeconds = 0.7, spectralReachSeconds = 0.6;
    // An FM key sent under a waiting switch (FM's own index, not its default
    // 2 and not a control of the Resonator): kept for the FM synth the
    // unfreeze starts
    var waitingIndex = 3.7;
    // The voice synths a voice holds, tracked (live, releasing, fading and
    // cutting) and on the server (its voice bus as out, the extra notes'
    // synths left out: they write the voice bus too)
    var trackedVoiceSynths = { arg target, voice;
        var held = IdentitySet.new, key = target.voiceKey(voice);
        [target.synths, target.releasingSynths[voice]].do({ arg dict; dict[key] !? { arg synth; held.add(synth) } });
        held.addAll(target.fadingSynths[voice]); held.addAll(target.cuttingSynths[voice]);
        held.count({ arg synth; isVoiceDef.(synth.defName) })
    };
    var serverVoiceSynths = { arg target, voice;
        var notes = (1 .. (target.noteSlots - 1)).collect({ arg slot; var record = target.noteRecord(voice, slot);
            [record[\synth], record[\cutting]].select(_.notNil).collect(_.nodeID) }).flatten;
        h.synthTree(target.voiceGroup).count({ arg node; isVoiceDef.(node[\def]) and: { notes.includes(node[\id]).not }
            and: { node[\controls][\out].asInteger == target.granBuses[voice].index } }) };
    var frozenSwitch = { arg target, mode, label;
        var run = { arg name ... args; h.commandTo(target, name, *args) };
        var voice = 0, writerBefore, writerAfter, phaseMoving, old, new, streams, streamsAfter, before, after, db, grainFreeze;
        var waits = mode == 1, cuttingAtSwitch, oldCutAtSwitch, raised = 0, held = 0, onServer = 0, units, fm, cutting, bundled, gone, fmIndex, notesAfter;
        var count = { held = max(held, trackedVoiceSynths.(target, voice)) };
        var meterBus = Bus.control(server, 1), meter, window, phaseBus = target.areaState[\rings][\phaseBuses][voice];
        // the kept grain controls the scenario sends (nil: never sent), as
        // they were before it, put back after
        var sentKeys = [\freeze, \freezeMode, \posSpread, \panSpread], sentBefore = sentKeys.collect({ arg key; target.grainControls[voice][key] });
        var defDefault = { arg key; SynthDescLib.global.at(\strataGrainRing).controls.detect({ arg each; each.name == key }).defaultValue };
        window = { meter.set(\t_reset, 1); 1.0.wait; h.readBusValue(meterBus).max(0).sqrt };
        run.(\setGrainSource, voice, 0);
        run.(\setGrainParam, voice, \freezeMode, mode);
        run.(\setGrainParam, voice, \posSpread, 0.0);
        run.(\setGrainParam, voice, \panSpread, 0.0);
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
        if (mode == 1) { spectralSettleSeconds.wait };
        before = window.value;
        run.(\setVoiceType, voice, 1);
        new = target.synths[target.voiceKey(voice)];
        cuttingAtSwitch = target.cuttingSynths[voice].size;
        oldCutAtSwitch = target.cuttingSynths[voice].includes(old);
        count.value;
        // Lua's sync after a switch: the new type's keys, which the waiting
        // voice synth lacks
        if (waits) { try { run.(\setVoiceParam, voice, \index, waitingIndex) } { raised = raised + 1 }; count.value };
        if (mode == 1) { spectralReachSeconds.wait };
        after = window.value;
        writerAfter = target.ringWriterFor(voice);
        streamsAfter = [1, 2].collect({ arg slot; [target.noteRecord(voice, slot)[\kind], target.noteRecord(voice, slot)[\synth]] });
        // the server's own freeze: the voice's ring grain synth's control
        // (the ring writers have none: hold is the writer paused, spectral
        // the writer's def)
        grainFreeze = target.synths[target.grainKey(voice)] !? { arg synth; h.getControl(synth, \freeze) };
        phaseMoving = h.readBusValue(phaseBus);
        0.2.wait;
        phaseMoving = h.readBusValue(phaseBus) != phaseMoving;
        db = if ((before > 0) and: { after > 0 }) { (after / before).ampdb } { inf };
        check.((writerAfter === writerBefore) and: { writerAfter.notNil }
            and: { h.synthTree(target.voiceGroup).any({ arg node; (node[\id] == writerBefore.nodeID)
                and: { node[\def] == if (mode == 0) { \strataRingWrite } { \strataRingWriteSpectral } } }) }
            and: { (mode == 0).not or: { phaseMoving.not } }
            and: { target.grainControls[voice][\freeze] == 1 } and: { target.areaState[\freeze][\frozen][voice] }
            and: { grainFreeze == 1 },
            "types: a frozen synth voice keeps its ring across setVoiceType (% tier, %: the same writer %, %, freeze % kept, % on the grain synth)".format(
                target.tier, label, writerAfter === writerBefore, if (mode == 0) { "paused " ++ phaseMoving.not } { "spectral" },
                target.grainControls[voice][\freeze], grainFreeze));
        check.((if (mode == 0) { db.abs <= holdLimitDb } { (db >= spectralLowDb) and: { db <= spectralHighDb } })
            and: { before > 1e-4 } and: { new.notNil },
            "types: a frozen synth voice keeps its held sound across setVoiceType (% tier, %: synth path RMS % then %, % dB, %; new %)".format(
                target.tier, label, before.round(0.00001), after.round(0.00001), db.round(0.01),
                if (mode == 0) { "at most %".format(holdLimitDb) } { "% to %".format(spectralLowDb, spectralHighDb) }, new !? { new.defName }));
        if (waits.not) {
            check.((new !== old) and: { new.notNil } and: { new.defName.asSymbol == \strataFM }
                and: { oldCutAtSwitch },
                "types: a hold-frozen voice still switches at once (% tier: new %, the Resonator cutting %)".format(
                    target.tier, new !? { new.defName }, oldCutAtSwitch));
        } {
            check.((new === old) and: { old.notNil } and: { old.defName.asSymbol == \strataResonator }
                and: { target.voiceType(voice) == 1 } and: { target.voiceDefFor(voice) == \strataFM }
                and: { cuttingAtSwitch == 0 } and: { raised == 0 } and: { old.isPlaying },
                "types: a spectral-frozen voice's type switch waits for the unfreeze (% tier: type %, def %, the same Resonator %, % cutting, % raised)".format(
                    target.tier, target.voiceType(voice), target.voiceDefFor(voice), new === old, cuttingAtSwitch, raised));
        };
        check.((streamsAfter == streams) and: { streams.every({ arg each; (each[0] == \stream) and: { each[1].notNil } }) },
            "types: a frozen voice's stream notes keep their nodes across setVoiceType (% tier: %)".format(target.tier, streamsAfter));
        meter.free; meterBus.free;
        // The unfreeze applies a waiting switch, in its own bundle: an FM
        // voice synth with the index sent under the wait, the Resonator cut
        // (kill 1 in the same bundle) and gone within switchCutTime and a
        // margin, two voice synths at most throughout, and the stream notes
        // restarted as FM voice synths (notesUnfrozen)
        if (waits) {
            units = h.wireUnits({ run.(\setGrainParam, voice, \freeze, 0.0) });
            count.value;
            fm = target.synths[target.voiceKey(voice)];
            cutting = target.cuttingSynths[voice].includes(old);
            bundled = units.any({ arg unit; unit.any({ arg msg; isStartOf.(msg, fm) }) and: { unit.any({ arg msg; isKillOf.(msg, old) }) } });
            server.sync;
            onServer = max(onServer, serverVoiceSynths.(target, voice));
            fmIndex = fm !? { arg synth; h.getControl(synth, \index) };
            notesAfter = [1, 2].collect({ arg slot; var record = target.noteRecord(voice, slot);
                [record[\kind], record[\synth] !? { arg synth; synth.defName.asSymbol }] });
            (target.switchCutTime + 0.1).wait; server.sync;
            count.value; onServer = max(onServer, serverVoiceSynths.(target, voice));
            gone = h.synthTree(target.voiceGroup).every({ arg node; node[\id] != old.nodeID });
            check.(fm.notNil and: { fm !== old } and: { fm.defName.asSymbol == \strataFM } and: { cutting } and: { bundled } and: { gone }
                and: { (fmIndex ? 0 - waitingIndex).abs < 0.001 } and: { held <= 2 } and: { onServer <= 2 }
                and: { notesAfter.every({ arg each; each == [\voice, \strataFM] }) },
                "types: a spectral-frozen voice's waiting switch is applied at the unfreeze (% tier: new %, the Resonator cutting % in the unfreeze's bundle % and gone %, index % (sent %), voice synths at most % tracked and % on the server, notes %)".format(
                    target.tier, fm !? { fm.defName }, cutting, bundled, gone, fmIndex, waitingIndex, held, onServer, notesAfter));
        };
        // the unfreeze, then the controls the scenario sent put back: a
        // kept value as it was, one never sent as the def's default to the
        // synth and out of the kept controls again (the voice was not
        // frozen before, so its kept freeze, if any, is 0 and the unfreeze
        // stands)
        run.(\setGrainParam, voice, \freeze, 0.0);
        [sentKeys, sentBefore].flop.do({ arg pair;
            run.(\setGrainParam, voice, pair[0], pair[1] ?? { defDefault.(pair[0]) });
            if (pair[1].isNil) { target.grainControls[voice].removeAt(pair[0]) };
        });
        check.(sentKeys.collect({ arg key; target.grainControls[voice][key] }) == sentBefore,
            "types: the frozen switch's scenario puts back the voice's kept % (% tier, %: %, before %)".format(
                sentKeys, target.tier, label, sentKeys.collect({ arg key; target.grainControls[voice][key] }), sentBefore));
        h.stopAllVoices(target);
        run.(\setNotePool, 0);
        run.(\setVoiceType, voice, voice);
        server.sync;
    };
    // The waiting switch's other cases, on a high engine, voice 0 on the
    // Resonator at 220 Hz frozen spectral: a second switch replaces the
    // first, a switch back to the running type cancels the wait, and every
    // path that ends the freeze applies it (a source switch away and back,
    // voiceOff then voiceOn, freezeMode 0 while frozen). Each reads the
    // Resonator still running just before what ends the freeze
    var waitingSwitches = { arg target;
        var run = { arg name ... args; h.commandTo(target, name, *args) };
        var voice = 0, key = target.voiceKey(voice);
        var kills = { arg units; units.flatten(1).count({ arg msg; ((msg[0] == 15) or: { msg[0] == '/n_set' })
            and: { (2, 4 .. (msg.size - 2)).any({ arg index; (msg[index].asSymbol == \kill) and: { msg[index + 1] == 1 } }) } }) };
        var starts = { arg units, def; units.flatten(1).count({ arg msg; ((msg[0] == 9) or: { msg[0] == '/s_new' }) and: { msg[1].asSymbol == def } }) };
        var freezeSpectral = {
            run.(\setGrainSource, voice, 0);
            run.(\setGrainParam, voice, \freezeMode, 1.0);
            run.(\voiceOn, voice, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
            server.sync; 0.3.wait;
            run.(\setGrainParam, voice, \freeze, 1.0);
            server.sync;
            target.synths[key]
        };
        var settle = {
            run.(\setGrainParam, voice, \freeze, 0.0);
            run.(\setGrainParam, voice, \freezeMode, 0.0);
            h.stopAllVoices(target);
            run.(\setVoiceType, voice, voice);
            server.sync; (target.switchCutTime + 0.1).wait;
        };
        var old, waited, units, now, held, tracked = 0, onServer = 0;
        var bound = { tracked = max(tracked, trackedVoiceSynths.(target, voice)) };

        // "types: a second switch under the freeze replaces the first"
        old = freezeSpectral.value;
        run.(\setVoiceType, voice, 1);
        run.(\setVoiceType, voice, 2);
        waited = target.synths[key] === old;
        units = h.wireUnits({ run.(\setGrainParam, voice, \freeze, 0.0) });
        now = target.synths[key];
        server.sync;
        check.(waited and: { now.notNil } and: { now.defName.asSymbol == \strataFolder } and: { kills.(units) == 1 }
            and: { target.cuttingSynths[voice].includes(old) } and: { starts.(units, \strataFM) == 0 },
            "types: a second switch under the freeze replaces the first (waited %, then %, % cut, % FM starts)".format(
                waited, now !? { now.defName }, kills.(units), starts.(units, \strataFM)));
        settle.value;

        // "types: a switch back to the running type under the freeze cancels
        // the wait"
        old = freezeSpectral.value;
        run.(\setVoiceType, voice, 1);
        run.(\setVoiceType, voice, 0);
        waited = target.synths[key] === old;
        units = h.wireUnits({ run.(\setGrainParam, voice, \freeze, 0.0) });
        server.sync;
        check.(waited and: { target.synths[key] === old } and: { old.isPlaying } and: { kills.(units) == 0 }
            and: { target.cuttingSynths[voice].isEmpty } and: { target.voiceType(voice) == 0 },
            "types: a switch back to the running type under the freeze cancels the wait (the same Resonator %, % cut, type %)".format(
                target.synths[key] === old, kills.(units), target.voiceType(voice)));
        settle.value;

        // "types: a waiting switch is applied whatever ends the freeze": a
        // source switch away (to slot 1: the Resonator fades, no voice synth
        // starts) and back (the type's def starts, the freeze ended)
        old = freezeSpectral.value;
        run.(\setVoiceType, voice, 1);
        waited = target.synths[key] === old;
        run.(\setGrainSource, voice, 1);
        held = target.synths[key];
        run.(\setGrainSource, voice, 0);
        now = target.synths[key];
        server.sync;
        check.(waited and: { held.isNil } and: { now.notNil } and: { now.defName.asSymbol == \strataFM }
            and: { target.areaState[\freeze][\frozen][voice].not } and: { trackedVoiceSynths.(target, voice) <= 2 },
            "types: a waiting switch is applied whatever ends the freeze (a source switch away and back: waited %, away %, back %, frozen %, % voice synths)".format(
                waited, held !? { held.defName }, now !? { now.defName }, target.areaState[\freeze][\frozen][voice], trackedVoiceSynths.(target, voice)));
        settle.value;

        // voiceOff then voiceOn under the freeze: the start is the type's
        // def and the releasing Resonator is cut (gateVoice's rule); the
        // unfreeze then has nothing to apply. The voice holds two voice
        // synths at most (the new and the cut), counted after each command
        // (tracked) and synced after each (on the server, the extra notes'
        // synths left out: there are none here)
        old = freezeSpectral.value;
        tracked = 0; onServer = 0;
        run.(\setVoiceType, voice, 1);
        bound.value;
        waited = target.synths[key] === old;
        run.(\voiceOff, voice);
        bound.value;
        server.sync; onServer = max(onServer, serverVoiceSynths.(target, voice));
        run.(\voiceOn, voice, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
        bound.value;
        now = target.synths[key];
        held = target.cuttingSynths[voice].includes(old);
        server.sync; onServer = max(onServer, serverVoiceSynths.(target, voice));
        units = h.wireUnits({ run.(\setGrainParam, voice, \freeze, 0.0) });
        bound.value;
        server.sync; onServer = max(onServer, serverVoiceSynths.(target, voice));
        check.(waited and: { now.notNil } and: { now.defName.asSymbol == \strataFM } and: { held }
            and: { kills.(units) == 0 } and: { target.synths[key] === now } and: { tracked <= 2 } and: { onServer <= 2 },
            "types: a waiting switch is applied whatever ends the freeze (voiceOff then voiceOn: waited %, then %, the Resonator cut %, % cut at the unfreeze, voice synths at most % tracked and % on the server)".format(
                waited, now !? { now.defName }, held, kills.(units), tracked, onServer));
        settle.value;

        // freezeMode 0 while frozen: the voice freezes again in hold
        // (setFreezeMode: unfreeze, then freeze), and that unfreeze applies
        // the switch: hold switches at once
        old = freezeSpectral.value;
        run.(\setVoiceType, voice, 1);
        waited = target.synths[key] === old;
        run.(\setGrainParam, voice, \freezeMode, 0.0);
        now = target.synths[key];
        server.sync;
        check.(waited and: { now.notNil } and: { now.defName.asSymbol == \strataFM } and: { target.cuttingSynths[voice].includes(old) }
            and: { target.areaState[\freeze][\frozen][voice] } and: { target.areaState[\freeze][\mode][voice] == \hold }
            and: { target.ringWriterFor(voice) !? { arg writer; writer.defName.asSymbol == \strataRingWrite } ? false },
            "types: a waiting switch is applied whatever ends the freeze (freezeMode 0 while frozen: waited %, then %, frozen % in %, writer %)".format(
                waited, now !? { now.defName }, target.areaState[\freeze][\frozen][voice], target.areaState[\freeze][\mode][voice],
                target.ringWriterFor(voice) !? { arg writer; writer.defName }));
        settle.value;

        // "types: a held chord's voice synth notes wait with the switch and
        // move to the new def at the unfreeze" (0c's chord check, under the
        // freeze): three extra notes held before the spectral freeze are
        // voice synths of the Resonator (a freeze changes no note on its
        // own; Lua cuts them, the engine does not). Through the wait each
        // keeps its node and its def; the unfreeze restarts the three on FM
        // at their kept freq (restartVoiceNotes, in switchVoiceType), each
        // start in the unfreeze's one bundle with the voice synth's FM start
        // and the kills of the Resonator and of the three old notes, which
        // are cutting
        {
            var slots = [1, 2, 3], record = { arg slot; target.noteRecord(voice, slot) };
            var notesBefore, notesDuring, notesAfter, records, freqs, noteUnits, bundledChord, fmVoice, held;
            run.(\setGrainSource, voice, 0);
            run.(\setGrainParam, voice, \freezeMode, 1.0);
            run.(\voiceOn, voice, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
            run.(\setNotePool, target.notePoolMax);
            slots.do({ arg slot;
                run.(\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
                run.(\noteOn, voice, slot, 60.0 + slot, 220.0 + (slot * 55), 1.0, 1.0);
            });
            server.sync; 0.3.wait;
            run.(\setGrainParam, voice, \freeze, 1.0);
            server.sync;
            held = target.synths[key];
            notesBefore = slots.collect({ arg slot; record.(slot)[\synth] });
            run.(\setVoiceType, voice, 1);
            server.sync; 0.1.wait;
            notesDuring = slots.collect({ arg slot; record.(slot)[\synth] });
            noteUnits = h.wireUnits({ run.(\setGrainParam, voice, \freeze, 0.0) });
            fmVoice = target.synths[key];
            notesAfter = slots.collect({ arg slot; record.(slot)[\synth] });
            records = slots.collect({ arg slot; [record.(slot)[\state], record.(slot)[\cutting] === notesBefore[slot - 1]] });
            bundledChord = noteUnits.any({ arg unit;
                unit.any({ arg msg; isStartOf.(msg, fmVoice) }) and: { unit.any({ arg msg; isKillOf.(msg, held) }) }
                    and: { notesAfter.every({ arg synth; unit.any({ arg msg; isStartOf.(msg, synth) }) }) }
                    and: { notesBefore.every({ arg synth; unit.any({ arg msg; isKillOf.(msg, synth) }) }) } });
            server.sync;
            freqs = notesAfter.collect({ arg synth; synth !? { h.getControl(synth, \freq) } });
            check.((target.synths[key] === fmVoice) and: { held !== fmVoice }
                and: { notesBefore.every({ arg synth; synth.notNil and: { synth.defName.asSymbol == \strataResonator } }) }
                and: { [notesBefore, notesDuring].flop.every({ arg pair; pair[0] === pair[1] }) }
                and: { fmVoice.notNil } and: { fmVoice.defName.asSymbol == \strataFM }
                and: { slots.every({ arg slot; var synth = notesAfter[slot - 1];
                    synth.notNil and: { synth !== notesBefore[slot - 1] } and: { synth.defName.asSymbol == \strataFM }
                        and: { records[slot - 1] == [\live, true] } and: { ((freqs[slot - 1] ? 0) - (220.0 + (slot * 55))).abs < 0.001 } }) }
                and: { bundledChord },
                "types: a held chord's voice synth notes wait with the switch and move to the new def at the unfreeze (kept through the wait %, [state, old cutting] %, defs %, freqs %, one bundle with the voice synth's switch %)".format(
                    [notesBefore, notesDuring].flop.every({ arg pair; pair[0] === pair[1] }), records,
                    notesAfter.collect({ arg synth; synth !? { synth.defName } }), freqs, bundledChord));
            settle.value;
            run.(\setNotePool, 0);
        }.value;
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
    {
        frozenSwitch.(other, 1, "spectral");
        frozenSwitch.(other, 0, "hold");
        waitingSwitches.(other);
    }.protect({ h.freeEngine(other); server.sync });
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
