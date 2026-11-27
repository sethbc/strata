// test/engine_check/types/saw.scd
// The saw type's own checks (3.8, package 1i), loaded by the types area
// (test/engine_check/types.scd), a function of h: \strataSaw is in
// voiceTypeDefs after the seven built-in types, with its noteMainRanges
// entry; at its defaults and at each own key's range ends, at 110 and
// 2000 Hz, it plays finite values, peaks above sawPeakFloor and under 1,
// and leaves under subsonicCeiling of its peak below 8 Hz (with no floor
// at the closed filter's one corner, closedCase); and a held
// chord's three extra notes on a saw voice start three \strataSaw synths.
// Its pool size is the memory area's (checkVoiceSynthSizes, every def of
// voiceTypeDefs against 52 KB). See docs/notes/engine/types.md (Saw)
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var typeDefs = engine.tryPerform(\voiceTypeDefs) ? [];
var sawType = typeDefs.indexOf(\strataSaw);
var sawPeakFloor = 0.005, subsonicCeiling = 0.15;

// "types: \strataSaw is a type after the built-in seven, with its
// expression range"
check.(sawType.notNil and: { sawType >= engine.numVoices }
    and: { (engine.tryPerform(\noteMainRanges) ? ())[\strataSaw] == [\width, 0.05, 0.95] }
    and: { engine.controlPairs(\strataSaw, Dictionary[\detune -> 0.01]).notEmpty },
    "types: \\strataSaw is a type after the built-in voices' (index %), its expression width 0.05-0.95 (%)".format(
        sawType, (engine.tryPerform(\noteMainRanges) ? ())[\strataSaw]));

// "types: saw at its defaults and its keys' range ends, at 110 and 2000
// Hz, is finite, peaks above sawPeakFloor and under 1 per channel, and
// leaves under subsonicCeiling of its peak below 8 Hz": each case a
// \strataSaw of its own on a private bus (attack 0.01 s, the crossmod
// slots on silentBus), a probe after it: per channel the peak of two 8 Hz
// lowpasses, the peak, and any NaN or inf. Measured over sawSeconds after
// the lowpasses settle. Pulse at its own defaults, at 110 Hz, is the level
// reference the message reports.
// The one exception, closedCase (the cutoff at its low end at 2000 Hz):
// the lowpass closed four octaves under the note leaves it near silence,
// so it has no floor; it keeps the rest of the measure (finite, under 1,
// under subsonicCeiling of its peak below 8 Hz) and is quieter than the
// same cutoff at 110 Hz (openCase: the filter cuts the higher note more)
{
    var sawSeconds = 4, settleSeconds = 1.5;
    var silent = engine.silentBus.index;
    var ends = [[\width, 0.05], [\width, 0.95], [\detune, 0], [\detune, 0.02], [\cutoff, 100], [\cutoff, 8000],
        [\res, 0.1], [\res, 1]];
    var cases = [110, 2000].collect({ arg freq; [[freq, nil, nil]] ++ ends.collect({ arg pair; [freq] ++ pair }) }).flatten(1);
    var closedCase = [2000, \cutoff, 100], openCase = [110, \cutoff, 100], peaks, openPeak;
    var group, buses, probeBus, probes, values, results, failures, reference, referenceBus, referenceProbe, referenceOut, referenceValues;
    SynthDef(\strataCheckSawProbe, { arg in, out, t_reset = 0;
        var sig = In.ar(in, 2), reset = T2A.ar(t_reset), codes = CheckBadValues.ar(sig, 0, 0);
        Out.kr(out, A2K.kr(Peak.ar(LPF.ar(LPF.ar(sig, 8), 8).abs, reset)
            ++ Peak.ar(sig.abs, reset) ++ [Peak.ar(((codes > 0.5) * (codes < 2.5)).sum, reset)]));
    }).add;
    server.sync;
    group = Group.tail(server);
    buses = cases.collect({ Bus.audio(server, 2) });
    referenceBus = Bus.audio(server, 2);
    probeBus = Bus.control(server, 5 * cases.size);
    referenceOut = Bus.control(server, 5);
    cases.do({ arg each, index;
        var args = [\out, buses[index], \freq, each[0], \attackTime, 0.01,
            \modBus1, silent, \modBus2, silent, \modBus3, silent];
        if (each[1].notNil) { args = args ++ [each[1], each[2]] };
        Synth(\strataSaw, args, group, \addToHead);
    });
    reference = Synth(\strataPulse, [\out, referenceBus, \freq, 110, \attackTime, 0.01,
        \modBus1, silent, \modBus2, silent, \modBus3, silent], group, \addToHead);
    probes = cases.collect({ arg each, index;
        Synth(\strataCheckSawProbe, [\in, buses[index], \out, probeBus.index + (5 * index)], group, \addToTail) });
    referenceProbe = Synth(\strataCheckSawProbe, [\in, referenceBus, \out, referenceOut.index], group, \addToTail);
    server.sync; settleSeconds.wait;
    server.makeBundle(nil, { (probes ++ [referenceProbe]).do(_.set(\t_reset, 1)) });
    sawSeconds.wait;
    values = h.readBus(probeBus).clump(5);
    referenceValues = h.readBus(referenceOut);
    peaks = cases.collect({ arg each, index; (values[index] ? []).copyRange(2, 3).maxItem ? 0 });
    openPeak = peaks[cases.indexOfEqual(openCase)];
    results = cases.collect({ arg each, index;
        var v = values[index] ? [], peak = peaks[index], low = v.copyRange(0, 1).maxItem ? 0;
        var sound = (v.size == 5) and: { v.every({ arg value; value.isNaN.not and: { value < inf } }) }
            and: { v[4] == 0 } and: { peak < 1 };
        var ok = if (each == closedCase) {
            sound and: { openPeak.notNil } and: { peak < openPeak } and: { low < (peak * subsonicCeiling) }
        } {
            sound and: { peak > sawPeakFloor } and: { low < (peak * subsonicCeiling) }
        };
        [each, peak, low, ok]
    });
    failures = results.reject({ arg each; each[3] });
    check.((results.size == cases.size) and: { failures.isEmpty },
        "types: saw at its defaults and its keys' range ends, at 110 and 2000 Hz, is finite, peaks above % and under 1 and leaves under % of its peak below 8 Hz; at % no floor, and under % (% against %, below 8 Hz %) (failing [[freq, key, value], peak, below 8 Hz]: %; peaks from % to %; at its defaults at 110 Hz % against Pulse's %, % dB)".format(
            sawPeakFloor, subsonicCeiling, closedCase, openCase,
            peaks[cases.indexOfEqual(closedCase)] !? { arg peak; peak.round(0.0001) }, openPeak !? { arg peak; peak.round(0.0001) },
            results.detect({ arg each; each[0] == closedCase }) !? { arg each; each[2].round(0.000001) },
            failures.collect({ arg each; [each[0], each[1].round(0.0001), each[2].round(0.0001)] }),
            results.collect({ arg each; each[1] }).minItem.round(0.0001), results.collect({ arg each; each[1] }).maxItem.round(0.0001),
            results[0][1].round(0.0001), (referenceValues.copyRange(2, 3).maxItem ? 0).round(0.0001),
            (results[0][1] / (referenceValues.copyRange(2, 3).maxItem ? 0).max(1e-9)).ampdb.round(0.1)));
    group.free; server.sync;
    buses.do(_.free); referenceBus.free; probeBus.free; referenceOut.free;
}.value;

// Measure the three fundamentals on each side with 1 Hz-wide bandpass filters.
{
    var group, source, audio, levels, bins, silent = engine.silentBus.index;
    SynthDef(\strataCheckSawDetuneBands, { arg in, out;
        var bands = In.ar(in, 2).collect({ arg channel;
            [480, 490, 500, 510, 520].collect({ arg freq;
                Amplitude.kr(BPF.ar(channel, freq, 0.002), 0.05, 0.05)
            })
        });
        Out.kr(out, bands.flat)
    }).add;
    server.sync;
    group = Group.tail(server);
    audio = Bus.audio(server, 2);
    levels = Bus.control(server, 10);
    source = Synth(\strataSaw, [\out, audio, \freq, 500, \detune, 0, \cutoff, 8000, \res, 0.1,
        \modBus1, silent, \modBus2, silent, \modBus3, silent, \attackTime, 0.01], group, \addToHead);
    Synth(\strataCheckSawDetuneBands, [\in, audio, \out, levels], group, \addToTail);
    server.sync; 2.wait;
    bins = h.readBus(levels).clump(5);
    check.((bins.size == 2) and: { bins.every({ arg side;
        (side[2] > 0.005) and: { [0, 1, 3, 4].every({ arg i; side[i] < (side[2] / 4) }) }
    }) }, "saw: detune 0 puts only the fundamental in the five bins (%)".format(bins));
    source.set(\detune, 0.02);
    server.sync; 2.wait;
    bins = h.readBus(levels).clump(5);
    check.((bins.size == 2) and: { [[2, 3, 4], [0, 1, 2]].every({ arg wanted, channel;
        var side = bins[channel], floor = side[wanted].minItem;
        (floor > 0.005) and: { side[[0, 1, 2, 3, 4].reject({ arg i; wanted.includes(i) })].maxItem < (floor / 4) }
    }) }, "saw: 2 percent detune plays 500/510/520 Hz left and 480/490/500 Hz right (%)".format(bins));
    group.free; server.sync; levels.free; audio.free
}.value;

// "types: a held chord's three extra notes on a saw voice start three
// \strataSaw synths": voice 0 put on saw and started, three notes held
{
    var voice = 0, slots = [1, 2, 3], own, notes;
    command.(\setVoiceType, voice, sawType ? 0);
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    command.(\setNotePool, slots.size);
    slots.do({ arg slot;
        command.(\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
        command.(\noteOn, voice, slot, 45.0 + (slot * 4), 110.0 * (slot + 1), 1.0, 1.0);
    });
    server.sync; 0.05.wait;
    own = engine.synths[engine.voiceKey(voice)];
    notes = h.noteSynths(voice);
    check.(sawType.notNil and: { own.notNil } and: { own.defName.asSymbol == \strataSaw }
        and: { notes.size == slots.size } and: { notes.every({ arg synth; synth.defName.asSymbol == \strataSaw }) }
        and: { notes.collect(_.nodeID).asSet.size == slots.size },
        "types: a held chord's three extra notes on a saw voice start three \\strataSaw synths (own %, notes %)".format(
            own !? { own.defName }, notes.collect({ arg synth; synth.defName })));
    slots.do({ arg slot; command.(\noteOff, voice, slot, 1) });
    h.stopAllVoices;
    command.(\setNotePool, 0);
    command.(\setVoiceType, voice, voice);
    server.sync;
}.value;
}
