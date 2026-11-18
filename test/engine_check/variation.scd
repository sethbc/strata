// test/engine_check/variation.scd
// Per-grain variation and the scale: reverse grains, pitch jitter, the
// interval sets and their probability, quantize to the scale (setScale and
// scaleBuffer), size jitter's cap, pan jitter, and that every variation
// control feeds a UGen.
//
// Grain rates and lengths are read from a timecode, as in rings.scd: a
// check synth writes the seconds since it started (left) and 1 (right) into
// voice 1's bus, so a grain of voice 1 (through a rectangular envelope) reads
// back on its left over its right the time its audio was written. A log
// synth writes each grain's rate (how far its read moved since 10 ms into
// it, over the time since then) and length into two buffers when the grain
// ends, one frame per grain.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var probeGroup, quietBus, nowBus, readOut, rectEnv, timecode, logRates, logDurs, logEnds, grainLog, startTimecodeVoice;
var grains, rates, semitones, majorMask = 2741, majorOffsets, before, after, state, bufferOffsets;
var rampPath, rampFile, rampFrames, scaleNote, leftPath, peakBus, peakProbe, levels, ratioDb, logFrames = 256, sentinel = -1000;
var varyControls = [\reverseProb, \pitchJitter, \panJitter, \sizeJitter, \intervalCount, \intervalProb, \quantize,
    \scaleNote] ++ (1..8).collect({ arg index; ("interval" ++ index).asSymbol });

SynthDef(\strataCheckVariationTimecode, { arg out, now;
    var time = Sweep.ar(0, 1);
    Out.ar(out, [time, DC.ar(1)]);
    Out.ar(now, time);
}).add;
// One frame per grain, at its end: its rate into rates, its length (s)
// into durs, and when it ended (s since the log started) into ends. Frame
// BufFrames - 1 takes every other sample's write
SynthDef(\strataCheckGrainLog, { arg in, rates, durs, ends;
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
    BufWr.ar(Delay1.ar(Sweep.ar(0, 1)), ends, index, 0);
}).add;
// The grain SynthDefs hold scaleBuffer's bufnum as a constant, and every
// engine built on this server re-adds them with its own: an earlier area's
// second engine (h.startEngine, freed since) has left them reading its freed
// buffer. On norns one engine runs at a time. Rebuild them for this engine
engine.addGrainDefs;
server.sync;

probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);
nowBus = Bus.audio(server, 1);
readOut = Bus.audio(server, 2);
peakBus = Bus.control(server, 2);
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
logRates = Buffer.alloc(server, logFrames, 1);
logDurs = Buffer.alloc(server, logFrames, 1);
logEnds = Buffer.alloc(server, logFrames, 1);
server.sync;

// The grains a voice (engine voice 0 by default) plays while seconds pass: [rate, length, end] per grain,
// the first left out (it may have started before the log)
grainLog = { arg seconds, voice = 0;
    var log, values = [nil, nil, nil];
    [logRates, logDurs, logEnds].do({ arg buffer; buffer.fill(0, logFrames, sentinel) });
    server.sync;
    engine.synths[engine.grainKey(voice)].set(\out, readOut.index);
    log = Synth(\strataCheckGrainLog, [\in, readOut, \rates, logRates, \durs, logDurs, \ends, logEnds], probeGroup);
    seconds.wait;
    log.free;
    engine.synths[engine.grainKey(voice)].set(\out, engine.voicePathBus(voice, engine.grainSource[voice]).index);
    h.check(h.getControl(engine.synths[engine.grainKey(voice)], \out) == engine.voicePathBus(voice, engine.grainSource[voice]).index,
        "variation: a grain synth's out is restored to its own path (voice %)".format(voice));
    server.sync;
    [logRates, logDurs, logEnds].do({ arg buffer, index;
        var condition = Condition(false);
        buffer.loadToFloatArray(action: { arg array; values[index] = array; condition.test = true; condition.signal });
        h.awaitReply(condition);
    });
    [values[0].copyRange(0, logFrames - 2), values[1].copyRange(0, logFrames - 2), values[2].copyRange(0, logFrames - 2)].flop
        .select({ arg pair; pair[0] != sentinel }).drop(1)
};
// Voice voice on source with its synth (if any) played elsewhere, its
// grains through the rectangular envelope, no pan wander or position spread
startTimecodeVoice = { arg voice, source, size, density, pitch;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 100.0, 0.2, 0.0, size, density, pitch);
    server.sync;
    engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.set(\out, quietBus.index) };
    [\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, voice, control, 0.0) });
    engine.synths[engine.grainKey(voice)].set(\envBuf, rectEnv.bufnum);
    server.sync;
};

// ---- The controls and the scale ----
h.grainDefs.do({ arg name;
    var unused = varyControls.reject({ arg control; h.controlFeedsAUGen(name, control) });
    check.(unused.isEmpty, "variation: the variation controls feed a UGen in % (unused: %)".format(name, unused));
});

state = engine.areaState[\scale];
bufferOffsets = {
    var condition = Condition(false), values;
    engine.scaleBuffer.loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition);
    values.asArray.collect(_.asInteger)
};
check.((engine.scaleBuffer.numFrames == 12) and: { engine.scaleRootAndMask == [0, 4095] }
    and: { bufferOffsets.value == Array.fill(12, 0) },
    "variation: the scale buffer has 12 frames and starts chromatic (root 0, mask 4095, every offset 0)");
// C major: C# D# F# G# A# go down to C D F G A (a tie goes down)
majorOffsets = [0, -1, 0, -1, 0, 0, -1, 0, -1, 0, -1, 0];
command.(\setScale, 0, majorMask); server.sync;
check.(bufferOffsets.value == majorOffsets, "variation: setScale(0, C major) fills the offsets to the nearest tone (got %)"
    .format(bufferOffsets.value));
// D major (C# D E F# G A B): C is a tie between B and C#, so -1
command.(\setScale, 2, majorMask); server.sync;
check.(bufferOffsets.value == [-1, 0, 0, -1, 0, -1, 0, 0, -1, 0, -1, 0],
    "variation: the mask is from the root (D major; got %)".format(bufferOffsets.value));
before = [engine.scaleRootAndMask, bufferOffsets.value];
[[12, majorMask], [-1, majorMask], [0, 0], [0, 4096], [0, -5]].do({ arg pair; command.(\setScale, pair[0], pair[1]) });
server.sync;
after = [engine.scaleRootAndMask, bufferOffsets.value];
check.(after == before, "variation: setScale ignores a bad root or mask (kept %)".format(after[0]));
command.(\setScale, 0, 4095); server.sync;

// ---- Grain rates and lengths (voice 1 on the timecode) ----
timecode = Synth(\strataCheckVariationTimecode, [\out, engine.granBuses[0], \now, nowBus], engine.voiceGroup, \addToHead);
startTimecodeVoice.(0, 0, 0.1, 5.0, 1.0);
1.0.wait;  // the ring holds a second of timecode

// at the defaults every grain plays at the voice's pitch
grains = grainLog.(2.0);
check.((grains.size >= 5) and: { grains.every({ arg pair; (pair[0] - 1).abs < 0.002 }) },
    "variation: at the defaults every grain plays at rate 1 (% grains)".format(grains.size));

command.(\setGrainParam, 0, \reverseProb, 1.0);
0.3.wait;
grains = grainLog.(3.0);
check.((grains.size >= 8) and: { grains.every({ arg pair; (pair[0] + 1).abs < 0.002 }) },
    "variation: reverseProb 1 plays a ramp backward (rates %)".format(grains.collect({ arg pair; pair[0].round(0.001) })));
command.(\setGrainParam, 0, \reverseProb, 0.0);

command.(\setGrainParam, 0, \pitchJitter, 12.0);
0.3.wait;
grains = grainLog.(5.0);
rates = grains.collect(_.first);
semitones = rates.collect({ arg rate; rate.ratiomidi });
check.((grains.size >= 15) and: { rates.every({ arg rate; (rate >= 0.499) and: { rate <= 2.002 } }) }
    and: { (semitones.maxItem - semitones.minItem) > 12 }
    and: { semitones.count({ arg each; (each - each.round).abs > 0.05 }) > (semitones.size div: 2) },
    "variation: pitchJitter 12 keeps grains within an octave and spreads them (% grains, % to % semitones)".format(
        grains.size, semitones.minItem.round(0.01), semitones.maxItem.round(0.01)));

// quantize: C major from C4, with the same jitter
command.(\setScale, 0, majorMask);
command.(\setGrainParam, 0, \scaleNote, 60.0);
command.(\setGrainParam, 0, \quantize, 1.0);
0.3.wait;
grains = grainLog.(5.0);
semitones = grains.collect({ arg pair; pair[0].ratiomidi });
check.((grains.size >= 15) and: { semitones.every({ arg each;
        ((each - each.round).abs < 0.03) and: { majorOffsets[(60 + each.round.asInteger) % 12] == 0 }
            and: { each.round.abs <= 12 } }) }
    and: { semitones.collect(_.round).asSet.size >= 4 },
    "variation: quantize lands every grain on a scale tone (C major from C4; semitones %)".format(
        semitones.collect(_.round(0.01))));
command.(\setGrainParam, 0, \quantize, 0.0);
command.(\setGrainParam, 0, \pitchJitter, 0.0);
command.(\setScale, 0, 4095);

// the octaves set: one of -12, 0 and 12 per grain
[[1, -12.0], [2, 0.0], [3, 12.0]].do({ arg pair; command.(\setGrainParam, 0, ("interval" ++ pair[0]).asSymbol, pair[1]) });
command.(\setGrainParam, 0, \intervalCount, 3.0);
0.3.wait;
grains = grainLog.(5.0);
rates = grains.collect(_.first);
check.((grains.size >= 15) and: { rates.every({ arg rate; [0.5, 1, 2].any({ arg target; (rate / target - 1).abs < 0.002 }) }) }
    and: { [0.5, 1, 2].every({ arg target; rates.any({ arg rate; (rate / target - 1).abs < 0.002 }) }) },
    "variation: octaves picks only -12, 0 and 12 (rates %)".format(rates.collect(_.round(0.001))));
command.(\setGrainParam, 0, \intervalProb, 0.0);
0.3.wait;
grains = grainLog.(2.5);
check.((grains.size >= 8) and: { grains.every({ arg pair; (pair[0] - 1).abs < 0.002 }) },
    "variation: intervalProb 0 plays the base pitch only (rates %)".format(grains.collect({ arg pair; pair[0].round(0.001) })));
command.(\setGrainParam, 0, \intervalProb, 1.0);
command.(\setGrainParam, 0, \intervalCount, 0.0);

// size jitter: 0.5 s grains x 2^(-1..1), never past 0.5 s
command.(\setGrainParam, 0, \grainSize, 0.5);
command.(\setGrainParam, 0, \grainDensity, 1.9);
command.(\setGrainParam, 0, \sizeJitter, 1.0);
0.6.wait;
grains = grainLog.(7.0);
rates = grains.collect({ arg pair; pair[1] });
check.((grains.size >= 8) and: { rates.maxItem <= 0.505 } and: { rates.maxItem >= 0.495 } and: { rates.minItem < 0.49 },
    "variation: sizeJitter never makes a grain longer than 0.5 s (lengths %)".format(rates.collect(_.round(0.001))));
command.(\setGrainParam, 0, \sizeJitter, 0.0);

// ---- 3.8's arpeggiator step (design §4.3) ----
// intervals 0, 12 and 24 (rates 1, 2 and 4), five 0.1 s grains a second:
// with arpOn 1 each grain plays the next of the three in turn (the step is
// read at a control block's start, so a grain may play the step before its
// own: the order holds, a grain late), with arpFold 1 there and back; a
// grain grainProb drops never advances the step; with arpOn 0 the draw is
// today's
{
    var cycle = [1, 2, 4], folded = [1, 2, 4, 2];
    // a rate within tolerance (0.3 %) of target; the check across
    // retriggered and continuous grains passes 2 %: a ring grain at 4 in
    // triggered mode lasts a third of its size, too short to read to 0.3 %
    // (it reads 3.975), and the rates are an octave apart
    var near = { arg rate, target, tolerance = 0.003; (rate / target - 1).abs < tolerance };
    var place = { arg rate, list; list.detectIndex({ arg target; near.(rate, target) }) };
    // whether the rates follow list in turn from some place in it
    var inTurn = { arg rates, list, tolerance = 0.003;
        list.size.collect({ arg start; rates.every({ arg rate, index; near.(rate, list.wrapAt(start + index), tolerance) }) }).any(_.value)
    };
    var steps = { arg rates; rates.collect({ arg rate; place.(rate, cycle) ? -1 }) }, gaps;
    command.(\setGrainParam, 0, \grainSize, 0.1);
    command.(\setGrainParam, 0, \grainDensity, 5.0);
    [[1, 0.0], [2, 12.0], [3, 24.0]].do({ arg pair; command.(\setGrainParam, 0, ("interval" ++ pair[0]).asSymbol, pair[1]) });
    command.(\setGrainParam, 0, \intervalCount, 3.0);
    command.(\setGrainParam, 0, \arpOn, 1.0);
    0.5.wait;
    rates = grainLog.(3.0).collect(_.first);
    check.((rates.size >= 10) and: { inTurn.(rates, cycle) },
        "variation: arpOn 1, intervals 0, 12, 24, count 3: rates cycle 1, 2, 4 (a lag of one grain allowed; rates %)".format(
            rates.collect(_.round(0.001))));
    command.(\setGrainParam, 0, \arpFold, 1.0);
    0.5.wait;
    rates = grainLog.(3.0).collect(_.first);
    check.((rates.size >= 10) and: { inTurn.(rates, folded) },
        "variation: arpFold 1: 1, 2, 4, 2, 1 (rates %)".format(rates.collect(_.round(0.001))));
    command.(\setGrainParam, 0, \arpFold, 0.0);
    command.(\setGrainParam, 0, \grainProb, 0.5);
    0.5.wait;
    grains = grainLog.(10.0);
    rates = grains.collect(_.first);
    // each grain that sounds plays the step after the last one that
    // sounded; the check means something only when some two sounding
    // grains are a number of triggers apart that is no multiple of three
    // (dropped grains that advanced the step would then show), the gaps
    // read from when each grain ended, 0.2 s a trigger at density 5
    gaps = grains.collect(_.last).differentiate.drop(1).collect({ arg seconds; (seconds * 5).round.asInteger });
    check.((rates.size >= 12) and: { gaps.any({ arg gap; (gap % 3) != 0 }) }
        and: { steps.(rates).slide(2, 1).clump(2).every({ arg pair; (pair[0] >= 0) and: { pair[1] == ((pair[0] + 1) % 3) } }) },
        "variation: a dropped grain does not advance the step (grainProb 0.5; rates %; triggers between sounding grains %)".format(
            rates.collect(_.round(0.001)), gaps));
    command.(\setGrainParam, 0, \grainProb, 1.0);
    // the order wherever a grain starts in a control block (fix round 1):
    // at density 20 from a fresh voiceOn (a grain synth's Impulse fires on
    // its first sample, so at 2400 samples a grain its starts alternate
    // between a block's first sample and its middle), then at 13 a second
    // (3692.3 samples a grain: a start's place in the block drifts through
    // the block, its first sample included) over 130 grains, the cycle and
    // the fold each: every grain the same step, its own or the one before,
    // never a step skipped or played twice. 0.04 s grains, so none overlap
    [[cycle, 0, "1, 2, 4"], [folded, 1, "1, 2, 4, 2, 1"]].do({ arg each;
        var list = each[0], fold = each[1], label = each[2];
        command.(\setGrainParam, 0, \arpFold, fold);
        command.(\voiceOff, 0);
        // until the grain synth has ended (a voiceOn would re-gate it)
        h.waitFor({ engine.releasingSynths[0].values.every({ arg synth; synth.defName != \strataGrainRing })
            and: { engine.synths[engine.grainKey(0)].isNil } }, 5);
        startTimecodeVoice.(0, 0, 0.04, 20.0, 1.0);
        0.5.wait;
        rates = grainLog.(2.0).collect(_.first);
        check.((rates.size >= 24) and: { inTurn.(rates, list) },
            "variation: the arpeggio holds its order at density 20 from a fresh voiceOn (arpFold %: %, % grains; rates %)".format(
                fold, label, rates.size, rates.collect(_.round(0.001))));
        command.(\setGrainParam, 0, \grainDensity, 13.0);
        0.3.wait;
        rates = grainLog.(10.5).collect(_.first);
        check.((rates.size >= 130) and: { inTurn.(rates, list) },
            "variation: the arpeggio skips and repeats no step at 13 grains a second over 130 grains (arpFold %: %, % grains; first breaks at %)".format(
                fold, label, rates.size, list.size.collect({ arg start;
                    rates.detectIndex({ arg rate, index; near.(rate, list.wrapAt(start + index)).not }) }).reject(_.isNil).maxItem));
    });
    // ... and across grains on a block's first sample and grains inside
    // one: a retrigger's grain starts on its block's first sample (T2A),
    // a continuous grain mostly inside its block, so the cycle and the
    // fold run on through continuous grains (13 a second, each inside its
    // block: at 5 a second, 9600 samples, every grain fell on a block's
    // first sample too, so the modes could not differ), six retriggers
    // 0.15 s apart, continuous grains, six retriggers and continuous
    // grains again: one rule for every grain, no step skipped or repeated
    // where the mode changes
    [[cycle, 0, "1, 2, 4"], [folded, 1, "1, 2, 4, 2, 1"]].do({ arg each;
        var list = each[0], fold = each[1], label = each[2], log;
        command.(\setGrainParam, 0, \arpFold, fold);
        command.(\setGrainParam, 0, \grainDensity, 13.0);
        0.3.wait;
        log = Routine({
            2.do({
                0.9.wait;
                command.(\setGrainParam, 0, \grainMode, 1);
                6.do({ arg index; server.makeBundle(0.1 + (index * 0.15), { command.(\retrigger, 0, 1.0) }) });
                1.1.wait;
                command.(\setGrainParam, 0, \grainMode, 0);
            });
        }).play;
        rates = grainLog.(5.5).collect(_.first);
        log.stop;
        command.(\setGrainParam, 0, \grainMode, 0);
        check.((rates.size >= 20) and: { inTurn.(rates, list, 0.02) },
            "variation: the arpeggio holds its order across retriggered grains (on a block's first sample) and continuous ones (arpFold %: %, % grains; rates %)".format(
                fold, label, rates.size, rates.collect(_.round(0.001))));
    });
    command.(\setGrainParam, 0, \arpFold, 0.0);
    command.(\setGrainParam, 0, \grainSize, 0.1);
    command.(\setGrainParam, 0, \grainDensity, 5.0);
    command.(\setGrainParam, 0, \arpOn, 0.0);
    0.5.wait;
    rates = grainLog.(4.0).collect(_.first);
    check.((rates.size >= 12) and: { rates.every({ arg rate; place.(rate, cycle).notNil }) }
        and: { cycle.every({ arg target; rates.any({ arg rate; near.(rate, target) }) }) } and: { inTurn.(rates, cycle).not },
        "variation: arpOn 0 draws as today: each grain one of the three at random (rates %)".format(rates.collect(_.round(0.001))));
    command.(\setGrainParam, 0, \intervalCount, 0.0);
    command.(\setGrainParam, 0, \grainDensity, 20.0);
}.value;

command.(\voiceOff, 0);
timecode.free;

// ---- 3.8's probability and the overlap cloud (design §4.2, §4.4) ----
// Voice 3 on a slot of DC, every grain through an envelope that is 1 for
// four frames near its start and 0 elsewhere (one blip as each grain
// starts, at every size the checks use), on a private bus: a counter counts
// the blips in a window the server times, so it counts the grains started
// however they overlap
{
    var voice = 2, slot = 2, path = h.tempDir +/+ "variation-dc.wav", countBus = Bus.control(server, 1);
    var blip = Buffer.loadCollection(server, [0.0, 1.0, 1.0, 1.0, 1.0] ++ Array.fill(1019, 0.0)), counter, count, counts;
    SynthDef(\strataCheckGrainCount, { arg in, out, seconds = 1, t_reset = 0;
        var reset = T2A.ar(t_reset), open = Sweep.ar(reset, 1) < seconds;
        Out.kr(out, A2K.kr(PulseCount.ar((In.ar(in, 2).abs.sum > 1e-4) * open, reset)));
    }).add;
    h.writeTestFile(path, server.sampleRate, (2 * server.sampleRate).asInteger, [1.0, 1.0]);
    command.(\loadBuffer, slot, path, 0); h.awaitLoad(slot);
    command.(\setGrainSource, voice, slot + 1);
    command.(\voiceOn, voice, 100.0, 0.5, 0.0, 0.01, 20.0, 1.0);
    server.sync;
    [[\posSpread, 0.0], [\panSpread, 0.0], [\bufPos, 0.25], [\bufScan, 0.0]].do({ arg pair; command.(\setGrainParam, voice, *pair) });
    engine.synths[engine.grainKey(voice)].set(\out, readOut.index, \envBuf, blip.bufnum);
    counter = Synth(\strataCheckGrainCount, [\in, readOut, \out, countBus], probeGroup);
    server.sync; 0.3.wait;                     // past the grain synth's attack
    // the grains started in `seconds` from now (a window the server times)
    count = { arg seconds, during;
        counter.set(\seconds, seconds, \t_reset, 1);
        server.sync;
        during.value;
        (seconds + 0.2).wait;
        h.readBus(countBus).first
    };
    // probability (continuous mode): 400 triggers in 2 s at density 200
    command.(\setGrainParam, voice, \grainDensity, 200.0);
    0.1.wait;
    counts = [count.(2.0)];
    command.(\setGrainParam, voice, \grainProb, 0.5);
    0.1.wait;
    counts = counts ++ [count.(2.0)];
    check.(((counts[0] - 400).abs <= 2) and: { counts[1] >= 160 } and: { counts[1] <= 240 },
        "variation: grainProb 0.5 passes 40-60 percent of 400 triggers at density 200 (% of %)".format(counts[1], counts[0]));
    command.(\setGrainParam, voice, \grainProb, 0.0);
    0.1.wait;
    counts = [count.(1.0)];
    command.(\setGrainParam, voice, \grainMode, 1);
    0.1.wait;
    counts = counts ++ [count.(1.0, { 5.do({ arg index; server.makeBundle(0.1 + (index * 0.1), {
        command.(\retrigger, voice, 1.0) }) }) })];
    check.((counts[0] == 0) and: { counts[1] == 5 },
        "variation: grainProb 0 sounds no grain in continuous mode and one grain per retrigger in triggered mode (% grains in 1 s; % for 5 retriggers)".format(
            counts[0], counts[1]));
    command.(\setGrainParam, voice, \grainMode, 0);
    command.(\setGrainParam, voice, \grainProb, 1.0);
    // the overlap cloud: grainOverlap over the size, within 0.1 to 250 a second
    command.(\setGrainParam, voice, \grainDensity, 20.0);
    command.(\setGrainParam, voice, \grainSize, 0.1);
    command.(\setGrainParam, voice, \grainOverlap, 2.0);
    command.(\setGrainParam, voice, \overlapOn, 1);
    0.2.wait;
    counts = [count.(2.0)];
    command.(\setGrainParam, voice, \grainSize, 0.01);
    command.(\setGrainParam, voice, \grainOverlap, 16.0);
    0.2.wait;
    counts = counts ++ [count.(1.0)];
    command.(\setGrainParam, voice, \grainSize, 0.1);
    command.(\setGrainParam, voice, \grainOverlap, 2.0);
    // a size fast offset of +0.245 s (one half range): the size 0.345 s
    command.(\setFastOffset, voice, 0, 2, 0.245 / engine.fastModHalfRanges[2]);
    0.3.wait;
    counts = counts ++ [count.(2.0)];
    command.(\setFastOffset, voice, 0, 2, 0.0);
    check.(((counts[0] - 40).abs <= 2) and: { (counts[1] - 250).abs <= 3 }
        and: { ((counts[2] / 40) - (0.1 / 0.345)).abs < 0.06 },
        "variation: overlapOn 1, grainOverlap 2, size 0.1: 40 ± 2 triggers in 2 s (%); size 0.01, overlap 16: 250 a second (%); a size fast offset of +0.245 lowers the rate by its ratio (% in 2 s, ratio %, want %)".format(
            counts[0], counts[1], counts[2], (counts[2] / 40).round(0.001), (0.1 / 0.345).round(0.001)));
    // triggered mode with the overlap cloud: one grain per retrigger, none without
    0.3.wait;
    [[\grainMode, 1], [\grainOverlap, 16.0], [\grainSize, 0.01]].do({ arg pair; command.(\setGrainParam, voice, *pair) });
    0.2.wait;
    counts = [count.(1.0)];
    counts = counts ++ [count.(1.5, { 10.do({ arg index; server.makeBundle(0.1 + (index * 0.1), {
        command.(\retrigger, voice, 1.0) }) }) })];
    check.((counts[0] == 0) and: { counts[1] == 10 },
        "variation: triggered mode with the overlap cloud: grainMode 1, overlapOn 1, grainOverlap 16, size 0.01: no grain in 1 s without a t_trig (%); 10 retriggers 100 ms apart give exactly 10 grains (%)".format(
            counts[0], counts[1]));
    [[\grainMode, 0], [\overlapOn, 0], [\grainOverlap, 2.0], [\grainSize, 0.1], [\posSpread, 0.5], [\panSpread, 0.5],
        [\bufPos, 0.0]].do({ arg pair; command.(\setGrainParam, voice, *pair) });
    counter.free;
    command.(\voiceOff, voice);
    command.(\setGrainSource, voice, 0);
    command.(\clearBuffer, slot);
    server.sync;
    [countBus, blip].do(_.free);
    File.delete(path);
}.value;

// ---- Pan jitter (voice 2 on a buffer slot) ----
// stereo.wav holds 0.5 left and -0.25 right: at zero pan jitter the left
// buffer's grains play left only and the right's right only, as in 3.1, so
// the channels keep their 6 dB difference
command.(\loadBuffer, 0, h.stereoPath, 0); h.awaitLoad(0);
command.(\setGrainSource, 1, 1);
command.(\voiceOn, 1, 100.0, 0.5, 0.0, 0.1, 10.0, 1.0);
server.sync;
command.(\setGrainParam, 1, \panSpread, 0.0);
engine.synths[engine.grainKey(1)].set(\out, readOut.index);
peakProbe = Synth(\strataCheckChannelPeaks, [\in, readOut, \out, peakBus], probeGroup);
0.5.wait;
levels = h.measure(peakProbe, peakBus, 1.0);
ratioDb = (levels[0] / levels[1].max(1e-9)).ampdb;
check.((levels[1] > 0.01) and: { (ratioDb - 2.ampdb).abs < 0.5 },
    "variation: zero pan jitter matches 3.1's channel levels within 0.5 dB (left over right % dB, want %)".format(
        ratioDb.round(0.01), 2.ampdb.round(0.01)));
// a left-only file: with pan jitter 1 the left buffer's grains reach the
// right channel, but never past the center (their pans stay in -1..0)
leftPath = h.tempDir +/+ "variation-left.wav";
h.writeTestFile(leftPath, 22050, 11025, [0.5, 0.0]);
command.(\loadBuffer, 0, leftPath, 0); h.awaitLoad(0);
0.3.wait;   // the voice's grains of the new file, past its hasAudio fade-in
levels = h.measure(peakProbe, peakBus, 1.0);
check.((levels[0] > 0.01) and: { levels[1] < (levels[0] * 0.01) },
    "variation: zero pan jitter keeps a left-only buffer left (peaks %)".format(levels.round(0.0001)));
command.(\setGrainParam, 1, \panJitter, 1.0);
0.3.wait;
levels = h.measure(peakProbe, peakBus, 2.0);
check.((levels[1] > (levels[0] * 0.3)) and: { levels[1] <= (levels[0] * 1.001) },
    "variation: pan jitter spreads grain pans within -1..1 (peaks %)".format(levels.round(0.0001)));
command.(\setGrainParam, 1, \panJitter, 0.0);
command.(\setGrainParam, 1, \panSpread, 0.5);
peakProbe.free;
command.(\voiceOff, 1);
command.(\setGrainSource, 1, 0);

// ---- A buffer voice quantizes around the rate it plays (voice 2) ----
// A slot holding a ramp (left: the fraction of its 1 s, right: 1) is read
// like the timecode. bufRate 2^(4/12) (a MIDI E4) with Lua's scaleNote 60
// (root C): the grain synth quantizes around 64, so every grain, played at
// its rate, still lands on C major
rampPath = h.tempDir +/+ "variation-ramp.wav";
rampFrames = server.sampleRate.asInteger;
rampFile = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(server.sampleRate);
rampFile.openWrite(rampPath);
rampFile.writeData(h.stereoOf(h.rampSignal(rampFrames) / rampFrames, h.repeating(rampFrames, [1.0])));
rampFile.close;
command.(\loadBuffer, 0, rampPath, 0); h.awaitLoad(0);
startTimecodeVoice.(1, 1, 0.1, 5.0, 1.0);
[[\bufPos, 0.3], [\bufScan, 0.0], [\scaleNote, 60.0], [\bufRate, 2 ** (4 / 12)], [\pitchJitter, 12.0], [\quantize, 1.0]]
    .do({ arg pair; command.(\setGrainParam, 1, *pair) });
command.(\setScale, 0, majorMask);
server.sync;
scaleNote = h.getControl(engine.synths[engine.grainKey(1)], \scaleNote);
check.((scaleNote - 64).abs < 0.001,
    "variation: a buffer voice's bufRate moves the scaleNote its grain synth gets (60 + 4 semitones; got %)".format(scaleNote));
0.3.wait;
grains = grainLog.(5.0, 1);
semitones = grains.collect({ arg pair; pair[0].ratiomidi });
check.((grains.size >= 15) and: { semitones.every({ arg each;
        ((each - each.round).abs < 0.03) and: { majorOffsets[(60 + each.round.asInteger) % 12] == 0 } }) }
    and: { semitones.collect(_.round).asSet.size >= 4 },
    "variation: a buffer voice at bufRate 2^(4/12) (MIDI E4) keeps its grains in C major (semitones %)".format(
        semitones.collect(_.round(0.01))));
// quantize comes before bend and crossmod: a bend of half a semitone moves
// every quantized grain half a semitone off C major, where a bend inside
// the quantize would snap it back onto a tone
command.(\setVoiceParam, 1, \bend, 2 ** (0.5 / 12));
0.3.wait;
grains = grainLog.(5.0, 1);
semitones = grains.collect({ arg pair; pair[0].ratiomidi - 0.5 });
check.((grains.size >= 15) and: { semitones.every({ arg each;
        ((each - each.round).abs < 0.03) and: { majorOffsets[(60 + each.round.asInteger) % 12] == 0 } }) }
    and: { semitones.collect(_.round).asSet.size >= 4 },
    "variation: a bend of half a semitone moves a quantized buffer voice's grains half a semitone off the scale (semitones less 0.5: %)".format(
        semitones.collect(_.round(0.01))));
command.(\setVoiceParam, 1, \bend, 1.0);
[[\pitchJitter, 0.0], [\quantize, 0.0], [\bufRate, 1.0], [\bufPos, 0.0], [\posSpread, 0.5], [\panSpread, 0.5]]
    .do({ arg pair; command.(\setGrainParam, 1, *pair) });
command.(\setScale, 0, 4095);
command.(\voiceOff, 1);
command.(\setGrainSource, 1, 0);

h.stopAllVoices;
[\reverseProb, \pitchJitter, \panJitter, \sizeJitter, \intervalCount, \quantize].do({ arg control;
    engine.numVoices.do({ arg voice; command.(\setGrainParam, voice, control, 0.0) });
});
command.(\setGrainParam, 0, \grainSize, 0.1);
command.(\setGrainParam, 0, \grainDensity, 20.0);
command.(\setGrainParam, 0, \scaleNote, 60.0);
probeGroup.free;
[quietBus, nowBus, readOut, peakBus].do(_.free);
[rectEnv, logRates, logDurs, logEnds].do(_.free);
File.delete(leftPath);
File.delete(rampPath);
server.sync;
}
