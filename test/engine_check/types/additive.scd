// test/engine_check/types/additive.scd
// The additive voice type's own checks (3.8, package 1g), run by the types
// area: its place in voiceTypeDefs, its partial count, its level at its
// defaults and at each own key's range ends at 110 and 2000 Hz, nothing
// below 8 Hz, no partial above 0.45 x the sample rate at 2000 Hz with
// stretch 1, and three extra notes of a held chord on three synths of its
// def. Its pool size is the memory area's (checkVoiceSynthSizes, every
// voice def under one limit). See docs/notes/engine/types.md
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var typeDefs = engine.voiceTypeDefs, type = typeDefs.indexOf(\strataAdditive);
var voice = 0, levelFloor = 0.005, levelCeiling = 1, subsonicCeiling = 0.15, highCeilingDb = -60;
// The record's defaults and each own key's range (lib/types/additive.lua)
var defaults = [\tilt, 1.0, \stretch, 0.0, \oddEven, 0.5, \wander, 0.2];
var ranges = (tilt: [0, 3], stretch: [-1, 1], oddEven: [0, 1], wander: [0.01, 1]);
var bus = Bus.control(server, 3), probe;
var setDefaults = { defaults.pairsDo({ arg key, value; command.(\setVoiceParam, voice, key, value) }) };
// [the peak of either side, the peak below 8 Hz (two 8 Hz lowpasses), the
// peak above 0.45 x the sample rate (eight highpasses there: a partial at
// 20.1 kHz, the highest 2000 Hz plays at stretch 1, is about 73 dB down,
// one at 22.4 kHz passes), each since the last reset
SynthDef(\strataCheckAdditiveMeter, { arg in, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset), high = sig;
    8.do({ high = HPF.ar(high, SampleRate.ir * engine.additiveMuteRatio) });
    Out.kr(out, A2K.kr([Peak.ar(sig.abs.reduce(\max), reset), Peak.ar(LPF.ar(LPF.ar(sig, 8), 8).abs.reduce(\max), reset),
        Peak.ar(high.abs.reduce(\max), reset)]));
}).add;
server.sync;

// "additive: its def follows the built-in types in voiceTypeDefs"
check.(type.notNil and: { type > typeDefs.indexOf(\strataRing) } and: { engine.numVoiceTypes == typeDefs.size },
    "additive: \\strataAdditive follows the built-in types in voiceTypeDefs (type %, of %)".format(type, typeDefs.size));
// "additive: its def plays additivePartials partials": one SinOsc each
{
    var desc = SynthDescLib.global.at(\strataAdditive);
    var sines = desc !? { desc.def.children.count({ arg unit; unit.class == SinOsc }) };
    check.((engine.additivePartials > 0) and: { sines == engine.additivePartials },
        "additive: its def plays additivePartials partials (% SinOscs, % partials; % UGens)".format(
            sines, engine.additivePartials, desc !? { desc.def.children.size }));
}.value;

if (type.notNil) {
    command.(\setVoiceType, voice, type);
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 110.0, 0.3, 0.0, 0.1, 10.0, 1.0);
    setDefaults.value;
    server.sync;
    probe = Synth(\strataCheckAdditiveMeter, [\in, engine.granBuses[voice], \out, bus.index], engine.voiceGroup, \addAfter);
    // the attack (4 s) over
    4.5.wait;
    check.(engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.defName.asSymbol == \strataAdditive } ? false,
        "additive: a voice on the additive type plays \\strataAdditive (%)".format(
            engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.defName }));

    // "additive: finite and sounding, under 1, at its defaults and at each own
    // key's range ends, at 110 and 2000 Hz"
    {
        var cases = [[\defaults, nil, nil]], failures = List.new, lowest = inf, highest = 0;
        ranges.keysValuesDo({ arg key, range; range.do({ arg value; cases = cases.add([key, key, value]) }) });
        [110.0, 2000.0].do({ arg freq;
            cases.do({ arg each;
                var values;
                setDefaults.value;
                command.(\setVoiceParam, voice, \freq, freq);
                if (each[1].notNil) { command.(\setVoiceParam, voice, each[1], each[2].asFloat) };
                server.sync; 0.3.wait;
                values = h.measure(probe, bus, 0.6);
                if ((values.size == 3) and: { values[0].isNaN.not } and: { values[0] < inf }) {
                    lowest = lowest.min(values[0]); highest = highest.max(values[0]);
                };
                if ((values.size != 3) or: { values[0].isNaN } or: { values[0] == inf } or: { values[0] <= levelFloor }
                    or: { values[0] >= levelCeiling }) {
                    failures.add("% Hz % %: %".format(freq, each[0], each[2], values))
                };
            });
        });
        check.(failures.isEmpty,
            "additive: finite, above % and under % at its defaults and each own key's range ends, at 110 and 2000 Hz (peaks % to %; failed: %)".format(
                levelFloor, levelCeiling, lowest.round(0.0001), highest.round(0.0001), failures));
    }.value;

    // "additive: nothing below 8 Hz": at its defaults at 110 Hz, the bus
    // below 8 Hz peaks under subsonicCeiling of its whole peak over 6 s (the
    // lowpasses settled first)
    {
        var values;
        setDefaults.value;
        command.(\setVoiceParam, voice, \freq, 110.0);
        server.sync; 2.0.wait;
        values = h.measure(probe, bus, 6.0);
        check.((values.size == 3) and: { values[0] > levelFloor } and: { values[1] < (values[0] * subsonicCeiling) },
            "additive: nothing below 8 Hz on its bus (below 8 Hz % of a peak of %, at most %)".format(
                values[1] !? { arg value; value.round(0.00001) }, values[0] !? { arg value; value.round(0.0001) }, subsonicCeiling));
    }.value;

    // "additive: 2000 Hz at stretch 1 holds no partial above 0.45 x the
    // sample rate": the energy above it is under -60 dB of the peak
    {
        var values, db;
        setDefaults.value;
        command.(\setVoiceParam, voice, \freq, 2000.0);
        command.(\setVoiceParam, voice, \stretch, 1.0);
        command.(\setVoiceParam, voice, \tilt, 0.0);
        server.sync; 0.5.wait;
        values = h.measure(probe, bus, 1.0);
        db = if ((values.size == 3) and: { values[0] > 0 }) { (values[2].max(1e-12) / values[0]).ampdb } { inf };
        check.((values.size == 3) and: { values[0] > levelFloor } and: { db < highCeilingDb },
            "additive: 2000 Hz at stretch 1 holds no partial above % x the sample rate (above it % dB of the peak %, under % dB)".format(
                engine.additiveMuteRatio, db.round(0.1), values[0] !? { arg value; value.round(0.0001) }, highCeilingDb));
    }.value;

    // "additive: three extra notes of a held chord start three synths of its
    // def": the own note and three extra slots, each its own \strataAdditive
    {
        var notes, nodes;
        setDefaults.value;
        command.(\setNotePool, 3);
        [1, 2, 3].do({ arg slot, index;
            command.(\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
            command.(\noteOn, voice, slot, 64.0 + (index * 3), 330.0 * (index + 1), 1.0, 1.0);
        });
        server.sync; 0.2.wait;
        notes = h.noteSynths(voice).select({ arg synth; synth.defName.asSymbol == \strataAdditive });
        nodes = h.synthTree(engine.voiceGroup).count({ arg node; node[\def] == \strataAdditive });
        check.((notes.size == 3) and: { nodes == 4 },
            "additive: three extra notes of a held chord start three synths of its def (% extra notes on it, % on the server with the own note)".format(
                notes.size, nodes));
        [1, 2, 3].do({ arg slot; command.(\noteOff, voice, slot, 1) });
        server.sync;
        command.(\setNotePool, 0);
    }.value;

    probe.free;
    h.stopAllVoices;
    command.(\setVoiceType, voice, voice);
    server.sync;
};
bus.free;
}
