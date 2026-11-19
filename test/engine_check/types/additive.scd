// test/engine_check/types/additive.scd
// The additive voice type's own checks (3.8, package 1g), run by the types
// area: its place in voiceTypeDefs, its partial count, its level at its
// defaults and at each own key's range ends at 110 and 2000 Hz, its two
// sides within balanceLimitDb (1.5 dB) of each other at pan 0, nothing
// below 8 Hz, no partial above 0.45 x the sample rate at 2000 Hz with
// stretch 1, no alias at 12 kHz bent there from 2000 Hz (where only the
// fundamental may play), and three extra notes of a held chord on three
// synths of its def. Each side is measured by itself. Its pool size is the
// memory area's
// (checkVoiceSynthSizes, every voice def under one limit). See
// docs/notes/engine/types.md
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var typeDefs = engine.voiceTypeDefs, type = typeDefs.indexOf(\strataAdditive);
var voice = 0, levelFloor = 0.005, levelCeiling = 1, subsonicCeiling = 0.15, highCeilingDb = -60, balanceLimitDb = 1.5;
// The record's defaults and each own key's range (lib/types/additive.lua)
var defaults = [\tilt, 1.0, \stretch, 0.0, \oddEven, 0.5, \wander, 0.2];
var ranges = (tilt: [0, 3], stretch: [-1, 1], oddEven: [0, 1], wander: [0.01, 1]);
var bus = Bus.control(server, 8), probe;
var setDefaults = { defaults.pairsDo({ arg key, value; command.(\setVoiceParam, voice, key, value) }) };
// A side's four values of a meter reading (0 left, 1 right), or nil
var side = { arg values, index; if (values.size == 8) { values.copyRange(index * 4, (index * 4) + 3) } { nil } };
// Both sides finite, above levelFloor and under levelCeiling
var sounding = { arg values;
    [0, 1].every({ arg index;
        var each = side.(values, index);
        each.notNil and: { each[0].isNaN.not } and: { each[0] < inf } and: { each[0] > levelFloor } and: { each[0] < levelCeiling }
    })
};
var round = { arg value, step; value !? { value.round(step) } };

// Each side by itself, since the last reset: [its peak, its peak below 8 Hz
// (two 8 Hz lowpasses), its peak above 0.45 x the sample rate (eight
// highpasses there: a partial at 20.1 kHz, the highest 2000 Hz plays at
// stretch 1, is about 73 dB down, one at 22.4 kHz passes), its mean
// square], the left side's four, then the right's
SynthDef(\strataCheckAdditiveMeter, { arg in, out, t_reset = 0;
    var reset = T2A.ar(t_reset), samples = Sweep.ar(t_reset, SampleRate.ir).max(1);
    Out.kr(out, A2K.kr(In.ar(in, 2).collect({ arg sig;
        var high = sig;
        8.do({ high = HPF.ar(high, SampleRate.ir * engine.additiveMuteRatio) });
        [Peak.ar(sig.abs, reset), Peak.ar(LPF.ar(LPF.ar(sig, 8), 8).abs, reset), Peak.ar(high.abs, reset),
            Sweep.ar(t_reset, sig.squared * SampleRate.ir) / samples]
    }).flatten));
}).add;
// Each side by itself, since the last reset: [its peak, its peak with the
// fundamental at `notch` Hz taken out (four band-rejects there, rq 0.05:
// 600 Hz wide at 12 kHz)], the left side's two, then the right's
SynthDef(\strataCheckAdditiveNotch, { arg in, out, t_reset = 0, notch = 12000;
    var reset = T2A.ar(t_reset);
    Out.kr(out, A2K.kr(In.ar(in, 2).collect({ arg sig;
        var rest = sig;
        4.do({ rest = BRF.ar(rest, notch, 0.05) });
        [Peak.ar(sig.abs, reset), Peak.ar(rest.abs, reset)]
    }).flatten));
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
    // key's range ends, at 110 and 2000 Hz": each side by itself
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
                [0, 1].do({ arg index;
                    var peaks = side.(values, index);
                    if (peaks.notNil and: { peaks[0].isNaN.not } and: { peaks[0] < inf }) {
                        lowest = lowest.min(peaks[0]); highest = highest.max(peaks[0]);
                    };
                });
                if (sounding.(values).not) { failures.add("% Hz % %: %".format(freq, each[0], each[2], values)) };
            });
        });
        check.(failures.isEmpty,
            "additive: finite, above % and under % on each side at its defaults and each own key's range ends, at 110 and 2000 Hz (peaks % to %; failed: %)".format(
                levelFloor, levelCeiling, lowest.round(0.0001), highest.round(0.0001), failures));
    }.value;

    // "additive: the two sides are within 1.5 dB at pan 0": each side's RMS
    // over 1.5 s, at 110 and 2000 Hz at its defaults, tilt 0 and 3 and
    // oddEven 0 and 1, and at 12 kHz, where every partial but the
    // fundamental is muted (the second would be at 24 kHz)
    {
        var cases = [[\defaults, nil, nil], [\tilt, \tilt, 0.0], [\tilt, \tilt, 3.0], [\oddEven, \oddEven, 0.0],
            [\oddEven, \oddEven, 1.0]];
        var failures = List.new, widest = 0, run;
        run = { arg freq, each;
            var values, left, right, db = inf;
            setDefaults.value;
            command.(\setVoiceParam, voice, \freq, freq);
            if (each[1].notNil) { command.(\setVoiceParam, voice, each[1], each[2]) };
            server.sync; 0.3.wait;
            values = h.measure(probe, bus, 1.5);
            left = side.(values, 0); right = side.(values, 1);
            if (left.notNil and: { right.notNil } and: { left[3] > 0 } and: { right[3] > 0 }) {
                db = (left[3] / right[3]).log10 * 10;
                if (db.abs > widest.abs) { widest = db };
            };
            if (sounding.(values).not or: { db.abs > balanceLimitDb }) {
                failures.add("% Hz % %: % dB".format(freq, each[0], each[2], round.(db, 0.01)))
            };
        };
        [110.0, 2000.0].do({ arg freq; cases.do({ arg each; run.(freq, each) }) });
        run.(12000.0, [\fundamental, nil, nil]);
        check.(failures.isEmpty,
            "additive: the two sides are within % dB at pan 0 (left against right, the widest % dB; failed: %)".format(
                balanceLimitDb, round.(widest, 0.01), failures));
    }.value;

    // "additive: nothing below 8 Hz": at its defaults at 110 Hz, each side
    // below 8 Hz peaks under subsonicCeiling of its whole peak over 6 s (the
    // lowpasses settled first)
    {
        var values, low;
        setDefaults.value;
        command.(\setVoiceParam, voice, \freq, 110.0);
        server.sync; 2.0.wait;
        values = h.measure(probe, bus, 6.0);
        low = [0, 1].collect({ arg index; side.(values, index) !? { arg each; [each[1], each[0]] } });
        check.(sounding.(values) and: { low.every({ arg each; each[0] < (each[1] * subsonicCeiling) }) },
            "additive: nothing below 8 Hz on either side of its bus (below 8 Hz against the peak, left then right: %; at most %)".format(
                low.collect({ arg each; each !? { [round.(each[0], 0.00001), round.(each[1], 0.0001)] } }), subsonicCeiling));
    }.value;

    // "additive: 2000 Hz at stretch 1 holds no partial above 0.45 x the
    // sample rate": on each side the energy above it is under -60 dB of the
    // side's peak
    {
        var values, db;
        setDefaults.value;
        command.(\setVoiceParam, voice, \freq, 2000.0);
        command.(\setVoiceParam, voice, \stretch, 1.0);
        command.(\setVoiceParam, voice, \tilt, 0.0);
        server.sync; 0.5.wait;
        values = h.measure(probe, bus, 1.0);
        db = [0, 1].collect({ arg index;
            var each = side.(values, index);
            if (each.notNil and: { each[0] > 0 }) { (each[2].max(1e-12) / each[0]).ampdb } { inf }
        });
        check.(sounding.(values) and: { db.every({ arg each; each < highCeilingDb }) },
            "additive: 2000 Hz at stretch 1 holds no partial above % x the sample rate (above it, of each side's peak, % dB; under % dB)".format(
                engine.additiveMuteRatio, db.collect({ arg each; round.(each, 0.1) }), highCeilingDb));
    }.value;

    // "additive: bent to 12 kHz at stretch 1 only the fundamental plays":
    // the stretch check above reads only the band above 0.45 x the sample
    // rate, where a partial left unmuted at 2000 Hz would sound, so an
    // alias folded below it (a partial past Nyquist plays at the sample
    // rate less its frequency, or lower still) is not seen there. At 2000
    // Hz bent 6 times (the voice's pitchbend; the mute reads the frequency
    // after it), stretch 1 and tilt 0, the second partial would be at
    // 24.8 kHz, so every partial but the fundamental is muted: one that
    // played would fold to 23.2 kHz (the second), 10.0 kHz (the third),
    // 3.4 kHz (the fourth) and on through the band. On each side, with the
    // fundamental taken out, what is left peaks under -60 dB of the side's
    // peak
    {
        var notchBus = Bus.control(server, 4), notchProbe, values, db, bent = 6.0;
        setDefaults.value;
        command.(\setVoiceParam, voice, \freq, 2000.0);
        command.(\setVoiceParam, voice, \stretch, 1.0);
        command.(\setVoiceParam, voice, \tilt, 0.0);
        command.(\setVoiceParam, voice, \bend, bent);
        server.sync;
        notchProbe = Synth(\strataCheckAdditiveNotch, [\in, engine.granBuses[voice], \out, notchBus.index, \notch, 2000.0 * bent],
            engine.voiceGroup, \addAfter);
        server.sync; 0.5.wait;
        values = h.measure(notchProbe, notchBus, 1.0);
        db = [0, 1].collect({ arg index;
            var each = if (values.size == 4) { values.copyRange(index * 2, (index * 2) + 1) };
            if (each.notNil and: { each[0] > levelFloor }) { (each[1].max(1e-12) / each[0]).ampdb } { inf }
        });
        check.(db.every({ arg each; each < highCeilingDb }),
            "additive: bent to 12 kHz at stretch 1 only the fundamental plays (with it taken out, of each side's peak, % dB; under % dB)".format(
                db.collect({ arg each; round.(each, 0.1) }), highCeilingDb));
        notchProbe.free;
        command.(\setVoiceParam, voice, \bend, 1.0);
        server.sync;
        notchBus.free;
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
