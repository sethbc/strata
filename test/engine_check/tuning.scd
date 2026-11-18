// test/engine_check/tuning.scd
// The tuning table (3.8, design §6.2): scaleBuffer holds tuningTableFrames
// frames, frame f the pitch (a fractional MIDI note) of the allowed tone
// nearest tuningTableLow + f / tuningTableResolution, a tie going down.
// setTuning and setTuningTone replace the tuning, setScale its mask (in a
// tuning of twelve tones to an octave); a bad or incomplete set keeps the
// table. Each table is read back with loadToFloatArray and compared with
// the nearest tone found by brute force; then one grain-level case: a
// quantized voice in 19 equal steps lands every grain on a 19-EDO tone
// (the timecode probe of variation.scd, with defs of its own).
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var frames = engine.tuningTableFrames, low = engine.tuningTableLow, res = engine.tuningTableResolution;
var rootKey = engine.tuningRootKey, majorMask = 2741, bufnum = engine.scaleBuffer.bufnum, scale = engine.areaState[\scale];
var equal12 = (0..11) * 100, equal19 = (0..18).collect({ arg step; step * 1200 / 19 });
// ji normal (norns' intonation JI.normal), in cents
var jiNormal = [0, 111.7313, 203.9100, 315.6413, 386.3137, 498.0450, 590.2237, 701.9550, 813.6863, 884.3587, 996.0900, 1088.2687];
var readTable, centerOf, nearest, maskAllowed, sendTuning, mismatches, sameAs, lines, ignored, capture, before, table;
var probeGroup, quietBus, readOut, rectEnv, logRates, logDurs, logFrames = 256, sentinel = -1000, timecode, grainLog;
var grains, semitones, buildTimes;

// The table's frames (an Array of Floats)
readTable = {
    var condition = Condition(false), values;
    engine.scaleBuffer.loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition);
    values.asArray
};
centerOf = { arg frame; low + (frame / res) };
// The allowed tone nearest pitch, a tie going down: allowed are cents above
// degree 0 (key rootKey + root), repeated each period. Returns the tone and
// how much nearer it is than the next nearest (0 at a midpoint)
nearest = { arg pitch, allowed, period, root;
    var rootNote = rootKey + root, periods = ((pitch - rootNote) * 100 / period).floor;
    var candidates = [periods - 1, periods, periods + 1].collect({ arg count;
        allowed.collect({ arg tone; rootNote + (((count * period) + tone) / 100) }) }).flatten.sort;
    var distances = candidates.collect({ arg candidate; (candidate - pitch).abs });
    var best = distances.minIndex, margin;
    margin = distances.copy.put(best, inf).minItem - distances[best];
    [candidates[best], margin]
};
// The tones of a twelve-tone tuning whose bit of mask is set (bit k: degree k)
maskAllowed = { arg tones, mask; tones.select({ arg tone, degree; mask.bitAnd(1 << degree) != 0 }) };
// A tuning, its tones in order (or in the order given)
sendTuning = { arg tones, period, order;
    command.(\setTuning, tones.size, period.asFloat);
    (order ? (0 .. (tones.size - 1))).do({ arg index; command.(\setTuningTone, index, tones[index].asFloat) });
    server.sync;
};
// How many frames of table miss the nearest tone (exact: equal; else
// within 1e-4 semitone, frames within 1e-3 of a midpoint left out)
mismatches = { arg table, allowed, period, root, exact = true;
    var count = 0;
    table.do({ arg value, frame;
        var found = nearest.(centerOf.(frame), allowed, period, root);
        if (exact) {
            if (value != found[0]) { count = count + 1 };
        } {
            if ((found[1] >= 1e-3) and: { (value - found[0]).abs > 1e-4 }) { count = count + 1 };
        };
    });
    count
};
sameAs = { arg a, b; (a.size == b.size) and: { a.every({ arg value, index; value == b[index] }) } };
// Count the console lines the area posts while fn runs (postTuningIgnored)
lines = List.new(64);
capture = { arg fn;
    var previous = scale[\postIgnored];
    lines.clear;
    scale[\postIgnored] = { arg line; lines.add(line) };
    fn.protect({ scale[\postIgnored] = previous });
    lines.size
};

// ---- The default table ----
table = readTable.value;
check.((engine.scaleBuffer.numFrames == frames) and: { table.size == frames }
    and: { engine.scaleRootAndMask == [0, engine.chromaticMask] }
    and: { engine.tuningTonesAndPeriod == [equal12, engine.octaveCents] },
    "tuning: the table has tuningTableFrames frames and starts at twelve equal, chromatic from C (% frames, %, %)".format(
        table.size, engine.scaleRootAndMask, engine.tuningTonesAndPeriod));
check.((mismatches.(table, equal12, engine.octaveCents, 0) == 0) and: { table.every({ arg value; value == value.round }) },
    "tuning: every default frame is the nearest whole note to its center, a tie down, exactly (% missed)".format(
        mismatches.(table, equal12, engine.octaveCents, 0)));
// 3.7's quantize rounded n to the whole note, a half up: the default
// table agrees but at the exact half semitones, where a tie goes down
{
var halves = 0, missed = 0;
table.do({ arg value, frame;
    var center = centerOf.(frame), half = (frame % res) == (res div: 2);
    if (half) { halves = halves + 1 };
    if (value != (if (half) { center.round - 1 } { center.round })) { missed = missed + 1 };
});
check.((missed == 0) and: { halves == (frames / res).round.asInteger },
    "tuning: the default table lands where 3.7's quantize lands but at the % half semitones (% missed)".format(halves, missed));
}.value;

// ---- The scale's mask ----
command.(\setScale, 0, majorMask); server.sync;
table = readTable.value;
check.(mismatches.(table, maskAllowed.(equal12, majorMask), engine.octaveCents, 0) == 0,
    "tuning: setScale(0, C major) fills the table with the nearest tone of the scale, a tie down");
command.(\setScale, 2, majorMask); server.sync;
table = readTable.value;
check.(mismatches.(table, maskAllowed.(equal12, majorMask), engine.octaveCents, 2) == 0,
    "tuning: the mask is from the root (D major)");
before = [engine.scaleRootAndMask, table];
check.(capture.({
    [[12, majorMask], [-1, majorMask], [0, 0], [0, 4096], [0, -5]].do({ arg pair; command.(\setScale, pair[0], pair[1]) });
    server.sync;
}) == 0, "tuning: setScale ignores a bad root or mask silently, as 3.7 did");
check.((engine.scaleRootAndMask == before[0]) and: { sameAs.(readTable.value, before[1]) },
    "tuning: setScale ignores a bad root or mask, the table unchanged (kept %)".format(engine.scaleRootAndMask));
command.(\setScale, 0, engine.chromaticMask); server.sync;

// ---- Another tuning ----
sendTuning.(equal19, engine.octaveCents);
table = readTable.value;
check.((engine.tuningTonesAndPeriod[0].size == 19) and: { mismatches.(table, equal19, engine.octaveCents, 0, false) == 0 },
    "tuning: a 19-tone tuning lands every frame on the nearest 19-EDO pitch from C4 (% missed)".format(
        mismatches.(table, equal19, engine.octaveCents, 0, false)));
command.(\setScale, 0, majorMask); server.sync;
check.(sameAs.(readTable.value, table), "tuning: setScale(0, C major) under 19 tones changes no frame (every tone allowed)");
// twelve just tones with the mask
sendTuning.(jiNormal, engine.octaveCents);
table = readTable.value;
check.(mismatches.(table, maskAllowed.(jiNormal, majorMask), engine.octaveCents, 0, false) == 0,
    "tuning: the mask applies in twelve just tones to an octave (ji normal, C major; % missed)".format(
        mismatches.(table, maskAllowed.(jiNormal, majorMask), engine.octaveCents, 0, false)));
// twelve tones of a 1300-cent period: no octave, every tone allowed
sendTuning.((0..11).collect({ arg step; step * 1300 / 12 }), 1300);
table = readTable.value;
check.(mismatches.(table, (0..11).collect({ arg step; step * 1300 / 12 }), 1300, 0, false) == 0,
    "tuning: twelve tones of 1300 cents ignore the mask (every tone allowed)");
command.(\setScale, 0, engine.chromaticMask);
sendTuning.(equal12, engine.octaveCents);

// ---- Sets that keep the old tuning ----
before = [readTable.value, engine.tuningTonesAndPeriod];
ignored = { arg what, expected, fn;
    var posted = capture.({ fn.value; server.sync });
    check.((posted == expected) and: { sameAs.(readTable.value, before[0]) } and: { engine.tuningTonesAndPeriod == before[1] },
        "tuning: % keeps the old tuning (% console lines of %: %)".format(what, posted, expected, lines.asArray));
};
ignored.("eleven of twelve tones", 0, {
    command.(\setTuning, 12, 1200.0);
    11.do({ arg index; command.(\setTuningTone, index, jiNormal[index].asFloat) });
});
ignored.("a set that does not ascend", 1, {
    sendTuning.(jiNormal.copy.swap(1, 2), engine.octaveCents) });
ignored.("a set whose tone 0 is not 0", 1, {
    sendTuning.([5] ++ equal12.drop(1), engine.octaveCents) });
ignored.("a tone at the period", 1, {
    command.(\setTuning, 2, 1200.0); command.(\setTuningTone, 0, 0.0); command.(\setTuningTone, 1, 1200.0) });
ignored.("a non-finite tone", 1, { command.(\setTuning, 2, 1200.0); command.(\setTuningTone, 1, 0.0 / 0.0) });
ignored.("setTuning with a count of 0 or 129, or a period of 99, 4801 or nan", 5, {
    [[0, 1200.0], [129, 1200.0], [12, 99.0], [12, 4801.0], [12, 0.0 / 0.0]].do({ arg pair; command.(\setTuning, *pair) }) });
ignored.("a tone past the count", 1, { command.(\setTuning, 2, 1200.0); command.(\setTuningTone, 2, 50.0) });
// tones in any order complete a set
sendTuning.(jiNormal, engine.octaveCents, (11, 10 .. 0));
check.(engine.tuningTonesAndPeriod[0].every({ arg cents, index; (cents - jiNormal[index]).abs < 1e-3 }),
    "tuning: tones arriving in reverse order complete the set (%)".format(engine.tuningTonesAndPeriod));
before = [readTable.value, engine.tuningTonesAndPeriod];
ignored.("a tone with no set begun", 1, { command.(\setTuningTone, 0, 0.0) });
sendTuning.(equal12, engine.octaveCents);

// ---- How long a table takes to build (posted for the report) ----
buildTimes = [["12 equal", equal12, 1200], ["partch-like 43", (0..42).collect({ arg i; i * 1200 / 43 }), 1200],
    ["128 tones of 100 cents", (0..127).collect({ arg i; i * 100 / 128 }), 100]].collect({ arg entry;
    var start = Main.elapsedTime;
    10.do({ engine.tuningTable(entry[1], entry[2], 0, engine.chromaticMask) });
    [entry[0], ((Main.elapsedTime - start) * 100).round(0.001)]
});
check.(buildTimes.every({ arg entry; entry[1] < 50 }),
    "tuning: a table builds in under 50 ms (ms each, the mean of ten: %)".format(buildTimes));

// ---- Grain level: a quantized voice in 19 equal steps ----
SynthDef(\strataCheckTuningTimecode, { arg out;
    Out.ar(out, [Sweep.ar(0, 1), DC.ar(1)]);
}).add;
SynthDef(\strataCheckTuningGrainLog, { arg in, rates, durs;
    var sig = In.ar(in, 2);
    var on = sig[1] > 0.05;
    var read = sig[0] / sig[1].max(0.001);
    var elapsed = Sweep.ar(on, on);
    var mark = on * (elapsed > 0.01);
    var rate = (read - Latch.ar(read, mark)) / ((elapsed - Latch.ar(elapsed, mark)) + SampleDur.ir);
    var ended = (Delay1.ar(on) - on) > 0.5;
    var index = Select.ar(ended, [DC.ar(BufFrames.kr(rates) - 1), PulseCount.ar(ended) - 1]);
    BufWr.ar(Delay1.ar(rate), rates, index, 0);
    BufWr.ar(Delay1.ar(elapsed), durs, index, 0);
}).add;
// the grain defs bake in scaleBuffer's bufnum: rebuild them for this engine (variation.scd)
engine.addGrainDefs;
probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);
readOut = Bus.audio(server, 2);
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
logRates = Buffer.alloc(server, logFrames, 1);
logDurs = Buffer.alloc(server, logFrames, 1);
server.sync;
grainLog = { arg seconds;
    var log, values = [nil, nil];
    [logRates, logDurs].do({ arg buffer; buffer.fill(0, logFrames, sentinel) });
    server.sync;
    engine.synths[engine.grainKey(0)].set(\out, readOut.index);
    log = Synth(\strataCheckTuningGrainLog, [\in, readOut, \rates, logRates, \durs, logDurs], probeGroup);
    seconds.wait;
    log.free;
    engine.synths[engine.grainKey(0)].set(\out, engine.voicePathBus(0, engine.grainSource[0]).index);
    server.sync;
    [logRates, logDurs].do({ arg buffer, index;
        var condition = Condition(false);
        buffer.loadToFloatArray(action: { arg array; values[index] = array; condition.test = true; condition.signal });
        h.awaitReply(condition);
    });
    [values[0].copyRange(0, logFrames - 2), values[1].copyRange(0, logFrames - 2)].flop
        .select({ arg pair; pair[0] != sentinel }).drop(1)
};
timecode = Synth(\strataCheckTuningTimecode, [\out, engine.granBuses[0]], engine.voiceGroup, \addToHead);
command.(\setGrainSource, 0, 0);
command.(\voiceOn, 0, 100.0, 0.2, 0.0, 0.1, 5.0, 1.0);
server.sync;
engine.synths[engine.voiceKey(0)] !? { arg synth; synth.set(\out, quietBus.index) };
[\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, 0, control, 0.0) });
engine.synths[engine.grainKey(0)].set(\envBuf, rectEnv.bufnum);
server.sync;
1.0.wait;  // the ring holds a second of timecode
sendTuning.(equal19, engine.octaveCents);
command.(\setGrainParam, 0, \scaleNote, 60.0);
command.(\setGrainParam, 0, \pitchJitter, 6.0);
command.(\setGrainParam, 0, \quantize, 1.0);
0.3.wait;
grains = grainLog.(5.0);
semitones = grains.collect({ arg pair; pair[0].ratiomidi });
check.((grains.size >= 15) and: { semitones.every({ arg each; var steps = each * 19 / 12; (steps - steps.round).abs * 12 / 19 < 0.03 }) }
    and: { semitones.collect({ arg each; (each * 19 / 12).round }).asSet.size >= 4 },
    "tuning: a quantized voice in 19 equal steps at jitter 6 lands every grain within 0.03 semitones of a tone (%)".format(
        semitones.collect(_.round(0.01))));
command.(\setGrainParam, 0, \quantize, 0.0);
command.(\setGrainParam, 0, \pitchJitter, 0.0);
sendTuning.(equal12, engine.octaveCents);
check.(engine.scaleBuffer.bufnum == bufnum, "tuning: the table's bufnum never changes (% then %)".format(bufnum, engine.scaleBuffer.bufnum));

h.stopAllVoices;
[\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, 0, control, 0.5) });
timecode.free;
probeGroup.free;
[quietBus, readOut].do(_.free);
[rectEnv, logRates, logDurs].do(_.free);
server.sync;
}
