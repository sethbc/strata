// test/engine_check/types/noise.scd
// The noise voice type's own checks (3.8, package 1h; loaded by the types
// area, test/engine_check/types.scd): \strataNoise (pink noise and dust
// through a lowpass and a resonant bank, lib/engine/StrataTypeNoise.sc)
// sits in voiceTypeDefs at Lua's place for it, plays at its defaults and at
// each own key's range ends, is level-matched to the Pulse voice, leaves
// nothing under 8 Hz, stays under 1 at its hottest with accents and past
// the bank's Nyquist cap, and plays an extra note of a held chord as a
// synth of its own def. Its place is read, never written as a number
// (ruling 64). The def's pool size is the memory area's
// (checkVoiceSynthSizes measures every def of voiceTypeDefs).
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var readBus = { arg bus; h.readBus(bus) };
var defName = \strataNoise, desc = SynthDescLib.global.at(defName);
var typeDefs = engine.tryPerform(\voiceTypeDefs) ? [];
var silent = engine.silentBus.index;
var show = { arg value; value !? { value.round(0.0001) } };
// The ends of each of the type's own keys (Lua's specs, lib/types/noise.lua)
var ownRanges = [[\color, 0, 1], [\grit, 0, 1], [\dust, 0.5, 50], [\q, 0.005, 1], [\bank, 0, 1]];
// The two pitches every level case plays at
var pitches = [110, 2000];
// A short attack, so the measures start at the full level
var quick = [\attackTime, 0.05];
// The RMS of a stereo bus's left channel since the last t_reset
var addRmsDef = {
    SynthDef(\strataCheckNoiseRms, { arg in, out, t_reset = 0;
        var sig = In.ar(in, 2)[0], reset = T2A.ar(t_reset);
        Out.kr(out, A2K.kr((Integrator.ar(sig.squared, 1 - reset) / Sweep.ar(reset, SampleRate.ir).max(1)).sqrt));
    }).add;
    // ... and the peak below 8 Hz (two 8 Hz lowpasses) and the whole peak
    // of the left channel since the last t_reset (voices.scd's subsonic probe)
    SynthDef(\strataCheckNoiseSubsonic, { arg in, out, t_reset = 0;
        var sig = In.ar(in, 2)[0], reset = T2A.ar(t_reset);
        Out.kr(out, A2K.kr([Peak.ar(LPF.ar(LPF.ar(sig, 8), 8).abs, reset), Peak.ar(sig.abs, reset)]));
    }).add;
};
// Play each case (args for \strataNoise) on a private bus of its own; after
// settle s, reset the meters and wait seconds (while during runs, with the
// synths, if given); answer [the largest channel peak, bad values seen] of each
var playCases = { arg cases, settle, seconds, during;
    var group = Group.tail(server), buses = cases.collect({ Bus.audio(server, 2) });
    var peakBus = Bus.control(server, 2 * cases.size), badBus = Bus.control(server, cases.size), synths, peaks, bad;
    synths = cases.collect({ arg args, index;
        Synth(defName, [\out, buses[index], \modBus1, silent, \modBus2, silent, \modBus3, silent] ++ args, group)
    });
    cases.do({ arg args, index;
        Synth(\strataCheckChannelPeaks, [\in, buses[index], \out, peakBus.index + (2 * index)], group, \addToTail);
        Synth(\strataCheckBadValues, [\in, buses[index], \out, badBus.index + index], group, \addToTail);
    });
    server.sync; settle.wait;
    group.set(\t_reset, 1);
    if (during.notNil) { during.(synths, seconds) } { seconds.wait };
    peaks = readBus.(peakBus).clump(2).collect(_.maxItem);
    bad = readBus.(badBus);
    group.free; server.sync;
    peakBus.free; badBus.free; buses.do(_.free);
    [peaks, bad]
};

if (desc.isNil) {
    check.(false, "noise: \\strataNoise is a SynthDef the engine added");
} {
    addRmsDef.value;
    server.sync;

    // "noise: \strataNoise sits in voiceTypeDefs at Lua's place": the
    // record's index is its place among strata.lua's lib/types/ includes
    // (lib/types.lua's registry gives it in include order), the engine's
    // type that less one
    {
        var lines = File.readAllString(h.testDir +/+ ".." +/+ "strata.lua").split($\n);
        var keys = lines.collect({ arg line; line.findRegexp("include\\(\"lib/types/([a-z_]+)\"\\)") })
            .reject(_.isEmpty).collect({ arg found; found[1][1] });
        var index = keys.indexOfEqual("noise") !? (_ + 1);
        check.(index.notNil and: { typeDefs.indexOf(defName) == (index - 1) } and: { index > engine.numVoices },
            "noise: \\strataNoise sits in voiceTypeDefs at Lua's place, after the built-in types (Lua's index %, engine's %, of %)".format(
                index, typeDefs.indexOf(defName), keys));
    }.value;

    // "noise: at its defaults and each own key's range ends, at 110 and 2000
    // Hz, it is finite and peaks above 0.005 and under 1"
    {
        var cases = List.new, labels = List.new, result, problems;
        pitches.do({ arg freq;
            cases.add(quick ++ [\freq, freq]); labels.add("defaults at %".format(freq));
            ownRanges.do({ arg range;
                [range[1], range[2]].do({ arg end;
                    cases.add(quick ++ [\freq, freq, range[0], end]); labels.add("% % at %".format(range[0], end, freq));
                });
            });
        });
        result = playCases.(cases.asArray, 0.5, 4);
        problems = [labels, result[0], result[1]].flop.reject({ arg each;
            (each[2] == 0) and: { each[1] > 0.005 } and: { each[1] < 1 } });
        check.((result[0].size == cases.size) and: { problems.isEmpty },
            "noise: at its defaults and each own key's range ends, at 110 and 2000 Hz, it is finite and peaks above 0.005 and under 1 (peaks % to %; failing [case, peak, bad]: %)".format(
                show.(result[0].minItem), show.(result[0].maxItem),
                problems.collect({ arg each; [each[0], show.(each[1]), each[2]] })));
    }.value;

    // "noise: at its defaults it plays as loud as the Pulse voice": at 220
    // Hz, sixteen of each at their defaults (attackTime 0.05), the mean of
    // their left channels' RMS over 6 s within 3 dB
    {
        var count = 16, group = Group.tail(server), buses = (2 * count).collect({ Bus.audio(server, 2) });
        var rmsBus = Bus.control(server, 2 * count), rms, noise, pulse, db;
        (2 * count).do({ arg index;
            Synth(if (index < count) { defName } { \strataPulse },
                [\out, buses[index], \freq, 220, \modBus1, silent, \modBus2, silent, \modBus3, silent] ++ quick, group);
            Synth(\strataCheckNoiseRms, [\in, buses[index], \out, rmsBus.index + index], group, \addToTail);
        });
        server.sync; 0.5.wait;
        group.set(\t_reset, 1);
        6.wait;
        rms = readBus.(rmsBus);
        noise = rms.copyRange(0, count - 1).mean;
        pulse = rms.copyRange(count, (2 * count) - 1).mean;
        db = if ((noise > 0) and: { pulse > 0 }) { (noise / pulse).ampdb } { inf };
        check.(db.abs <= 3,
            "noise: at its defaults it plays as loud as the Pulse voice (RMS at 220 Hz % against %, % dB; at most 3)".format(
                show.(noise), show.(pulse), db.round(0.01)));
        group.free; server.sync; rmsBus.free; buses.do(_.free);
    }.value;

    // "noise: nothing under 8 Hz": pink noise has energy near 0 Hz, so the
    // source goes through subsonicBlock: at the defaults and with the bank
    // at 0 (the plain noise alone), at 110 Hz, the peak below 8 Hz stays
    // under 0.15 of the whole peak over 10 s (the FM and Ring rule)
    {
        var cases = [quick ++ [\freq, 110], quick ++ [\freq, 110, \bank, 0]];
        var group = Group.tail(server), buses = cases.collect({ Bus.audio(server, 2) }), bus = Bus.control(server, 2 * cases.size);
        var values;
        cases.do({ arg args, index;
            Synth(defName, [\out, buses[index], \modBus1, silent, \modBus2, silent, \modBus3, silent] ++ args, group);
            Synth(\strataCheckNoiseSubsonic, [\in, buses[index], \out, bus.index + (2 * index)], group, \addToTail);
        });
        // (the probes' lowpasses settle before the measurement starts)
        server.sync; 1.0.wait;
        group.set(\t_reset, 1);
        10.wait;
        values = readBus.(bus).clump(2);
        check.((values.size == cases.size) and: { values.every({ arg pair; (pair[1] > 0.005) and: { pair[0] < (pair[1] * 0.15) } }) },
            "noise: nothing under 8 Hz (below 8 Hz against the whole peak, at the defaults and the bank at 0: %)".format(
                values.collect({ arg pair; pair.collect(show) })));
        group.free; server.sync; bus.free; buses.do(_.free);
    }.value;

    // "noise: q 0.005, grit 1, accents every 0.25 s for 4 s stay under 1":
    // the narrowest bank at full grit, struck by every step, at its hottest
    // (amp 1, dust 50, the bank and color at 1, amplitude and frequency
    // crossmod at full) at 20, 110 and 2000 Hz, centered and panned hard
    // either way, accents at velocity 1 every 0.25 s
    {
        var modBus = Bus.control(server, 1), cases, result;
        var hottest = [\q, 0.005, \grit, 1, \amp, 1, \dust, 50, \bank, 1, \color, 1, \modAmpAmt1, 2, \modFreqAmt2, 2];
        modBus.set(1);
        cases = [20, 110, 2000].collect({ arg freq; [0, -1, 1].collect({ arg pan;
            quick ++ hottest ++ [\freq, freq, \pan, pan, \modBus1, modBus.index, \modBus2, modBus.index]
        }) }).flatten(1);
        result = playCases.(cases, 0.5, 4, { arg synths, seconds;
            (seconds / 0.25).round.asInteger.do({ synths.do({ arg synth; synth.set(\velocity, 1, \t_trig, 1) }); 0.25.wait });
        });
        check.((result[0].size == cases.size) and: { result[0].every({ arg peak; (peak > 0.005) and: { peak < 1 } }) }
            and: { result[1].every(_ == 0) },
            "noise: q 0.005, grit 1, accents every 0.25 s for 4 s stay under 1 (peaks %, bad values %)".format(
                result[0].collect(show), result[1]));
        modBus.free;
    }.value;

    // "noise: bent past the bank's Nyquist cap it stays finite and under
    // 1": each resonance is capped at filterCeiling x the sample rate
    // (21600 Hz at 48 kHz), which freq's range (20-2000 Hz) and the
    // crossmod alone never reach (2000 x 1.5 ** 3 x 3 = 20250 Hz at the
    // hottest above), but a note's bend (noteExpression's, up to 16) or
    // the voice's pitchbend does: at 2000 Hz, noteBend 4 puts the top
    // resonance on the cap (27000 Hz asked), 16 every one (32000 Hz and
    // up), and bend 2 with noteBend 16 and the frequency crossmod at full
    // asks for 192000 Hz and up. A Resonz above Nyquist with a wide
    // band (rq 1) is unstable (its pole radius passes 1 once the frequency
    // passes about 0.64 of the sample rate), so at q 1 and 0.005, amp 1,
    // the bank at 1, the peak stays finite, above 0.005 and under 1
    {
        var modBus = Bus.control(server, 1), cases, result;
        var hot = [\amp, 1, \bank, 1, \color, 1, \freq, 2000];
        modBus.set(1);
        cases = [0.005, 1].collect({ arg q; [
            quick ++ hot ++ [\q, q, \noteBend, 4],
            quick ++ hot ++ [\q, q, \noteBend, 16],
            quick ++ hot ++ [\q, q, \bend, 2, \noteBend, 16, \modFreqAmt1, 2, \modBus1, modBus.index]
        ] }).flatten(1);
        result = playCases.(cases, 0.5, 2);
        check.((result[0].size == cases.size) and: { result[0].every({ arg peak; peak.isNaN.not and: { peak > 0.005 } and: { peak < 1 } }) }
            and: { result[1].every(_ == 0) },
            "noise: bent past the bank's Nyquist cap it stays finite and under 1 (q 0.005 then 1, each at noteBend 4, 16 and 16 with bend 2 and the frequency crossmod at full: peaks %, bad values %)".format(
                result[0].collect(show), result[1]));
        modBus.free;
    }.value;

    // "noise: three extra notes of a held chord start three synths of its
    // def": a voice on noise, its own note held, three extra notes
    {
        var voice = 0, type = typeDefs.indexOf(defName), notes;
        if (type.notNil) {
            command.(\setVoiceType, voice, type);
            command.(\setGrainSource, voice, 0);
            command.(\voiceOn, voice, 110.0, 0.3, 0.0, 0.1, 10.0, 1.0);
            command.(\setNotePool, engine.notePoolMax);
            [1, 2, 3].do({ arg slot; command.(\noteOn, voice, slot, 48.0 + (slot * 4), 110.0 * (1 + (slot * 0.25)), 1.0, 1.0) });
            server.sync; 0.1.wait;
        };
        notes = h.noteSynths(voice);
        check.((engine.voiceDefFor(voice) == defName) and: { notes.size == 3 }
            and: { notes.every({ arg synth; synth.defName.asSymbol == defName }) },
            "noise: three extra notes of a held chord start three synths of its def (the voice on %, notes %)".format(
                engine.voiceDefFor(voice), notes.collect({ arg synth; synth.defName })));
        h.stopAllVoices;
        command.(\setNotePool, 0);
        command.(\setVoiceType, voice, voice);
        server.sync;
    }.value;
};
}
