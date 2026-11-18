// test/engine_check/shimmer.scd
// Shimmer (3.8 design §7.4; package 2a): the pitch shifter (shimmerShift)
// in \strataDelay's feedback and around each reverb (\strataReverb's
// FreeVerb2, \strataReverbFDN). At amount 0 each effect is its def as it
// was before shimmer, bit for bit (against check-only copies of 1b's delay
// and 1a's two reverbs); the delay's loop stays bounded at every interval
// at feedback 0.95, frozen too; each reverb's loop stays bounded at every
// interval, amount and size (a soft clip at shimmerCeiling and the duck on
// the output's level, shimmerLoop), at a ratio near 1 too, and holds a
// quiet halo; a NaN in a reverb's loop never reaches its output. Then
// the engine's nodes: setShimmer sets and
// keeps both amounts and the ratio (through a bypass and its lift), ignores
// a non-finite value with one line, each node reads its own two of the four
// rings, a bypass's free empties them, and a fresh engine (standard and
// high) starts at amount 0 and ratio 2. The signal checks run nodes of the
// engine's own defs on buses, rings and lines of their own (startCheckNode,
// the one place this area starts one), measured on the server in windows
// of server time, so a busy machine changes nothing.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var readBus = { arg bus; h.readBus(bus) };
var powerDb = { arg ratio; (ratio.max(1e-30).log10 * 10).round(0.01) };
var ampDb = { arg ratio; ratio.max(1e-15).ampdb.round(0.1) };
// the windows an analysis measures, and the values it gives each
var numWindows = 8, fields = 4, windowField;
var ratios = [0.5, 1.5, 2, 3, 4];
var delayDefs = [\strataDelay, \strataCheckShimmerDelay18];
var startCheckNode, runCases, runPlans, guarded, withIgnoredLines, ringPeak;
var planAsBefore, planDelayBounded, planReverbBounded, planNanInLoop, planPresent, planHeld, checkCommand,
    checkIgnoredValues, checkRings, checkFresh;
// the shimmer checks' bounds (planPresent): a shifted band of a sine at
// least presentDb over the same case at amount 0 (the smallest reading is
// 34.9 dB, the delay at ratio 1.5), of noise noisePresentDb over it (the
// band above 1200 Hz holds the reverb's own share of the low-passed noise,
// so it reads 20.6-22.2 dB); a loud case's shifted band within
// proportionalDb of ten times a quiet one's (20 dB, level for level); a
// steady loud case the duck leaves alone moving at most pumpDb more than
// the same case at amount 0
var presentDb = 30, noisePresentDb = 15, proportionalDb = 6, pumpDb = 1.5;
// the shifted band at least shiftDb over the band the other ratio would
// make (planPresent: the shift follows the ratio; two band-passes at rq
// 0.05 pass an unshifted 440 Hz about 10.2 dB more at 660 Hz than at 880 Hz,
// so a loop that ignored the ratio would come within 0.2 dB of 10)
var shiftDb = 20;
// planHeld: a runaway held by the duck on a steady send (size 1, amount 1,
// the worst ratio) moving at most heldPumpDb more over 100 ms than the same
// send at amount 0 (FreeVerb2's sine reads 1.71 dB more; with a 1 % range
// 3.43); a send near full scale's runaway peaking at most loudOverDb over
// the same send at amount 0
var heldPumpDb = 2.5, loudOverDb = 6;
// planHeld: the held runaway's energy at most heldOverDb over the same send
// at amount 0 (held: with the clip alone this loop grew to a peak of 10.8)
var heldOverDb = 3;
// on a sine, where the duck regulates, the held runaway's RMS at most
// heldSineTimes the send's (the bound's top: 1.25 x 1.5 x the follower's
// 1.35 x the RMS, 2.5 times, plus the halo; 2.4-3.05 measured)
var heldSineTimes = 4;
// the halo (planReverbBounded, ratio 1.5, amount 1, size 1), the duck
// regulating it alone 3-6 s after the send stops: its level over 100 ms
// moving at most haloPumpDb (2.05 dB on FreeVerb2, 1.52 on the FDN; a duck
// made to oscillate, a 3 s follower and a 1 % range, read 3.48 and 4.28)
var haloPumpDb = 3;
// the worst ratio each reverb's loop runs away at (with the clip alone:
// FreeVerb2's peak reached 10.8 at 4; the FDN's, of the five, 1.06 at 1.5)
var worstRatios = (strataReverb: 4, strataReverbFDN: 1.5);
// the halo (planReverbBounded): its RMS 5-9 s after the input stops under
// haloRmsDb, its peak under -6 dBFS (the brief's)
var haloRmsDb = -15;
var bandsFields = 8, bandsField;

// A stereo input from `from` to `to` (s from its start): independent pink
// noise at level (low-passed twice at lowpass Hz unless it is 0) plus a
// sine of freq at sine on both channels. The noise draws from a random
// generator of its own (rgen, RandID), seeded at the start (RandSeed), so
// every run plays the same noise and the seeders below never touch it
SynthDef(\strataCheckShimmerInput, { arg out, level = 0.25, from = 0, to = 1e9, sine = 0, freq = 440, lowpass = 0,
        rgen = 7, seed = 1;
    var id = RandID.ir(rgen), seeded = RandSeed.kr(1, seed), elapsed = Sweep.ar(0, 1);
    var noise = { PinkNoise.ar(level) } ! 2, cutoff = lowpass.max(20);
    var shaped = Select.ar(lowpass > 0, [noise, LPF.ar(LPF.ar(noise, cutoff), cutoff)]);
    Out.ar(out, (shaped + (SinOsc.ar(freq, 0, sine) ! 2)) * (elapsed >= from) * (elapsed < to));
}).add;
// A stereo bus from `from` to `to` (s from its start): the energy of a
// band (mode 0: two band-passes at freq, rq 0.05; 1: two high-passes at
// freq; both channels) and of the whole signal, and the largest and the
// smallest of its level averaged over about 100 ms (the power of both
// channels through a one-pole Lag of 0.69 s to -60 dB, a time constant of
// 100 ms; no buffer, so no pool beyond the graph's), four values on out.
// It frees itself at seconds
SynthDef(\strataCheckShimmerBands, { arg in, out, freq = 880, mode = 0, from = 1, to = 4, seconds = 5;
    var sig = In.ar(in, 2), elapsed = Sweep.ar(0, 1), inside = (elapsed >= from) * (elapsed < to);
    var band = Select.ar(mode, [BPF.ar(BPF.ar(sig, freq, 0.05), freq, 0.05), HPF.ar(HPF.ar(sig, freq), freq)]);
    var sliding = Lag.ar(sig.squared.sum, 0.69);
    Out.kr(out, A2K.kr([Integrator.ar(band.squared.sum * inside, 1), Integrator.ar(sig.squared.sum * inside, 1),
        RunningMax.ar(sliding * inside), RunningMin.ar(Select.ar(inside, [DC.ar(1e9), sliding]))]));
    Line.kr(0, 0, seconds, doneAction: 2);
}).add;
// inf on the left and NaN on the right for one control block from at, 0 otherwise
SynthDef(\strataCheckShimmerBad, { arg out, at = 1, big = 1e30;
    var elapsed = Sweep.ar(0, 1), inside = (elapsed >= at) * (elapsed < (at + ControlDur.ir));
    var infinite = DC.ar(big) * big;
    Out.ar(out, [Select.ar(inside, [DC.ar(0), infinite]), Select.ar(inside, [DC.ar(0), infinite - infinite])]);
}).add;
// Reseeds the default random generator (rgen 0, which every graph without
// a RandID draws from) at the start of every control block: a seeder just
// before each of two nodes makes their draws (the FDN's drift) the same
SynthDef(\strataCheckShimmerSeed, { arg out, seed = 1234;
    Out.kr(out, A2K.kr(RandSeed.ar(Impulse.ar(ControlRate.ir), seed)));
}).add;
// A node that writes silence (a case that reads only its input)
SynthDef(\strataCheckShimmerSilent, { arg out; Out.ar(out, DC.ar(0) ! 2) }).add;
// A delay time on a control bus: center + depth x a sine at rate Hz
SynthDef(\strataCheckShimmerTimeLfo, { arg out, center = 0.3, depth = 0.1, rate = 0.5;
    Out.kr(out, SinOsc.kr(rate, 0, depth, center));
}).add;
// A control bus's value over time from the synth's start: first, second
// from at (s)
SynthDef(\strataCheckShimmerStep, { arg out, first = 0, second = 1, at = 1e9;
    Out.kr(out, Select.kr(Sweep.kr(0, 1) >= at, [first, second]));
}).add;
// A stereo bus in eight windows of time from the synth's start ([start,
// end] s each): per window, the sum of its squared samples (both channels,
// bad values counted as 0), its largest absolute sample, whether a NaN or
// inf reached it (1) and its largest absolute difference from ref (summed
// over both channels); four values a window on out. It frees itself at
// seconds
SynthDef(\strataCheckShimmerWindows, { arg in, ref, out, seconds = 1, windows = #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    var sig = In.ar(in, 2), other = In.ar(ref, 2), elapsed = Sweep.ar(0, 1);
    var codes = CheckBadValues.ar(sig, 0, 0), bad = ((codes > 0.5) * (codes < 2.5)).sum.min(1);
    var clean = sig.collect({ arg channel, index; Select.ar(codes[index] > 0, [channel, DC.ar(0)]) });
    var largest = clean[0].abs.max(clean[1].abs), difference = (sig - other).abs.sum;
    Out.kr(out, 8.collect({ arg index;
        var inside = (elapsed >= windows[index * 2]) * (elapsed < windows[(index * 2) + 1]);
        A2K.kr([Integrator.ar(clean.squared.sum * inside, 1), RunningMax.ar(largest * inside), RunningMax.ar(bad * inside),
            RunningMax.ar(difference * inside)])
    }).flat);
    Line.kr(0, 0, seconds, doneAction: 2);
}).add;

// Check-only copies of the three defs as they were before shimmer (1b's
// delay with its freeze and clear, 1a's reverbs), against which shimmer 0
// is compared bit for bit
SynthDef(\strataCheckShimmerDelay18, {
    arg in, out, bufL, bufR, time=0.375, feedback=0.4, mix=0, pingPong=0, fadeIn=0, frozen=0, t_clear=0;
    var hold = Slew.kr(frozen.clip(0, 1), engine.delayFreezeRate, engine.delayFreezeRate);
    var isFrozen = frozen.clip(0, 1) > 0;
    var input = In.ar(in, 2) * engine.liftFade(fadeIn) * (1 - hold), returned = LocalIn.ar(2);
    var held = Gate.kr(time.clip(0.01, 5.4), 1 - isFrozen).lag(0.1);
    var delayTime = Select.kr(isFrozen, [held, (held * SampleRate.ir).round / SampleRate.ir]);
    var lagged = pingPong.clip(0, 1).lag(0.05);
    var snapped = (pingPong.clip(0, 1) >= engine.delayPingPongSnap).lag(0.05);
    var cross = lagged + ((snapped - lagged) * hold), keep = 1 - cross;
    var muted = 1 - Trig1.kr(t_clear, delayTime + engine.delayClearMargin);
    var delayed = BufDelayC.ar([bufL, bufR], [
        input[0] + (input[1] * cross) + (returned[0] * keep) + (returned[1] * cross),
        (input[1] * keep) + (returned[1] * keep) + (returned[0] * cross)
    ], delayTime);
    LocalOut.ar(delayed * feedback.clip(0, 0.95).max(hold) * engine.delayClearGain(muted, ControlRate.ir));
    Out.ar(out, delayed * engine.delayClearGain(muted, 1 / engine.delayClearFade) * mix.clip(0, 1).lag(engine.fxMixLag));
}).add;
SynthDef(\strataCheckShimmerVerb18, {
    arg in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0;
    var sig = (In.ar(in, 2) + (In.ar(delayIn, 2) * delayToReverb.clip(0, 1).lag(engine.fxMixLag)))
        * engine.liftFade(fadeIn);
    var wet = FreeVerb2.ar(sig[0], sig[1], 1, size, damp);
    Out.ar(out, wet * mix.clip(0, 1).lag(engine.fxMixLag));
}).add;
SynthDef(\strataCheckShimmerFdn18, {
    arg in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0;
    var room = size.clip(0, 1).lag(0.1), damping = damp.clip(0, 1).lag(0.1) * 0.4;
    var sig = (In.ar(in, 2) + (In.ar(delayIn, 2) * delayToReverb.clip(0, 1).lag(engine.fxMixLag)))
        * engine.liftFade(fadeIn);
    var feedbackBase = 0.7 + (0.28 * room), reference = 1378 * SampleDur.ir;
    var drift = [0, 0, LFNoise1.kr(0.31) * 0.0006, 0, 0, 0, LFNoise1.kr(0.43) * 0.0005, 0];
    var lengths = engine.fdnLineSeconds * (0.6 + (0.4 * room)) + drift;
    var diffused, feedback, lines, sum, wet;
    diffused = sig.collect({ arg channel, side;
        engine.fdnDiffuserSeconds[side].inject(channel, { arg each, time;
            AllpassN.ar(each, time, time, time * 19)
        })
    });
    feedback = LocalIn.ar(8);
    lines = 8.collect({ arg index;
        var line = DelayL.ar((diffused[index % 2] * 0.25) + feedback[index], engine.fdnLineSeconds[index] + 0.002,
            lengths[index] - ControlDur.ir);
        OnePole.ar(line, damping)
    });
    sum = lines.sum * (2 / 8);
    LocalOut.ar(lines.collect({ arg line, index;
        (line - sum) * (feedbackBase ** (lengths[index] / reference))
    }));
    wet = [lines[0] + lines[2] + lines[4] + lines[6], lines[1] + lines[3] + lines[5] + lines[7]];
    Out.ar(out, wet * mix.clip(0, 1).lag(engine.fxMixLag));
}).add;

// A window's field of a case's values (0 energy, 1 peak, 2 bad, 3 largest
// difference from ref)
windowField = { arg values, window, field; values !? { values[(window * fields) + field] } ? 0 };
// A case's bands field (0 band energy, 1 energy, 2 largest and 3 smallest
// level over 100 ms; 4 to 7 the same of its otherBands), after its windows
bandsField = { arg values, field; values !? { values[(numWindows * fields) + field] } ? 0 };

// The one place this area starts a node of a delay or reverb def: on its
// own buses (delayIn: a silent bus), its own two shimmer rings (shiftL,
// shiftR: a ring left out is buffer 0, which the node would write) and,
// for a delay, its own line (bufL, bufR); at level 1 unless controls say
// otherwise
startCheckNode = { arg def, inBus, outBus, silent, buffers, controls, target;
    var line = if (delayDefs.includes(def)) { [\bufL, buffers[\line][0], \bufR, buffers[\line][1]] } { [] };
    Synth(def, [\in, inBus, \delayIn, silent, \out, outBus, \shiftL, buffers[\rings][0], \shiftR, buffers[\rings][1],
        \mix, 1] ++ line ++ controls, target, \addToTail)
};

// Run cases at once, in one group created in one bundle, for seconds of
// server time: each case an Event of def, controls (the node's), input
// (\strataCheckShimmerInput's controls) or inputFrom (an earlier case's
// index, whose input it shares), bad (a \strataCheckShimmerBad's at on the
// input), seed (a seeder just before the node), steps (control -> [first,
// second, at]: a \strataCheckShimmerStep mapped to the node's control),
// lfo (true: the time on a \strataCheckShimmerTimeLfo), ref (an earlier
// case's index, whose output the difference is taken from), probeInput
// (true: the windows read the input, not the output), windows (up to
// eight [start, end] pairs), bands ([freq, mode, from, to]: a
// \strataCheckShimmerBands on the same bus) and otherBands (a second one). Each input's noise draws from
// a generator of its own (8 + its index), seeded with 1000 + its index.
// The values of each case, as windowField and bandsField read them
runCases = { arg cases, seconds;
    var group = Group.after(context.xg), silent = Bus.audio(server, 2), seedBus = Bus.control(server, 1);
    var condition = Condition(false), ended = 0, results;
    var made = cases.collect({ arg case;
        (inBus: if (case[\inputFrom].isNil) { Bus.audio(server, 2) }, outBus: Bus.audio(server, 2),
            resultBus: Bus.control(server, (numWindows * fields) + bandsFields),
            controlBuses: List.new,
            buffers: (rings: 2.collect({ Buffer.alloc(server, engine.shimmerRingFrames, 1) }),
                line: if (delayDefs.includes(case[\def])) { 2.collect({ Buffer.alloc(server, engine.delayLineFrames, 1) }) } { [] }))
    });
    // each input's noise on a generator of its own: past the server's count
    // RandID falls back to the shared default generator, and the seeding
    // with it
    check.((8 + cases.size) <= server.options.numRGens,
        "shimmer: a batch's % inputs each get a random generator of their own (8 + its index under the server's %)".format(
            cases.size, server.options.numRGens));
    made.do({ arg each; each[\resultBus].setAll(0) });
    server.sync;
    server.makeBundle(nil, {
        cases.do({ arg case, index;
            var each = made[index], node;
            if (case[\inputFrom].notNil) { each[\inBus] = made[case[\inputFrom]][\inBus] } {
                Synth(\strataCheckShimmerInput, [\out, each[\inBus], \rgen, 8 + index, \seed, 1000 + index] ++ (case[\input] ? []),
                    group, \addToTail);
                case[\bad] !? { arg at; Synth(\strataCheckShimmerBad, [\out, each[\inBus], \at, at], group, \addToTail) };
            };
        });
        cases.do({ arg case, index;
            var each = made[index], node, maps = List.new;
            (case[\steps] ? ()).keysValuesDo({ arg control, step;
                var bus = Bus.control(server, 1);
                each[\controlBuses].add(bus);
                maps.add([control, bus]);
                Synth(\strataCheckShimmerStep, [\out, bus, \first, step[0], \second, step[1], \at, step[2]], group, \addToTail);
            });
            if (case[\lfo] == true) {
                var bus = Bus.control(server, 1);
                each[\controlBuses].add(bus);
                maps.add([\time, bus]);
                Synth(\strataCheckShimmerTimeLfo, [\out, bus], group, \addToTail);
            };
            case[\seed] !? { arg seed; Synth(\strataCheckShimmerSeed, [\out, seedBus, \seed, seed], group, \addToTail) };
            node = startCheckNode.(case[\def], each[\inBus], each[\outBus], silent, each[\buffers], case[\controls] ? [], group);
            maps.do({ arg pair; node.map(pair[0], pair[1]) });
        });
        cases.do({ arg case, index;
            var windows = (case[\windows] ++ ([0, 0] ! numWindows)).copyRange(0, numWindows - 1).flat;
            var analysis = Synth(\strataCheckShimmerWindows, [\in, if (case[\probeInput] == true) { made[index][\inBus] } { made[index][\outBus] },
                \ref, case[\ref] !? { arg ref; made[ref][\outBus] } ? silent, \out, made[index][\resultBus],
                \seconds, seconds, \windows, windows], group, \addToTail);
            OSCFunc({ ended = ended + 1; if (ended == cases.size) { condition.test = true; condition.signal } },
                '/n_end', server.addr, argTemplate: [analysis.nodeID]).oneShot;
            [case[\bands], case[\otherBands]].do({ arg bands, which;
                bands !? { Synth(\strataCheckShimmerBands, [\in, if (case[\probeInput] == true) { made[index][\inBus] } { made[index][\outBus] },
                    \out, made[index][\resultBus].index + (numWindows * fields) + (which * 4), \freq, bands[0], \mode, bands[1],
                    \from, bands[2], \to, bands[3], \seconds, seconds], group, \addToTail) };
            });
        });
    });
    awaitReply.(condition, (seconds * 10) + 10);
    results = made.collect({ arg each; readBus.(each[\resultBus]) });
    group.free; server.sync;
    made.do({ arg each, index;
        if (cases[index][\inputFrom].isNil) { each[\inBus].free };
        [each[\outBus], each[\resultBus]].do(_.free);
        each[\controlBuses].do(_.free);
        (each[\buffers][\rings] ++ each[\buffers][\line]).do(_.free);
    });
    silent.free; seedBus.free; server.sync;
    results
};

// A check that raises (a command the engine does not have) fails, naming it
guarded = { arg name, body;
    try { body.value } { arg error; check.(false, "shimmer: % raised %".format(name, error.errorString)) };
};

// Runs body with the lines the engine posts for ignored commands added to
// lines (the modulation area's postIgnored hook), put back however it ends
withIgnoredLines = { arg lines, body;
    var modulation = engine.areaState[\modulation], previous = modulation[\postIgnored];
    modulation[\postIgnored] = { arg line; lines.add(line) };
    body.protect({ modulation[\postIgnored] = previous });
};

// A buffer's largest absolute sample
ringPeak = { arg buffer;
    var condition = Condition(false), peak;
    buffer.loadToFloatArray(action: { arg array; peak = array.abs.maxItem; condition.test = true; condition.signal });
    awaitReply.(condition, 10);
    peak
};

// Run plans at once, in one runCases batch of the longest plan's seconds:
// each plan an Event of cases (indices in ref and inputFrom its own),
// seconds and judge (a function of its cases' results, in its order)
runPlans = { arg plans;
    var cases = List.new, offsets = List.new, results;
    plans.do({ arg plan;
        var offset = cases.size;
        offsets.add(offset);
        plan[\cases].do({ arg case;
            var copy = case.copy;
            case[\ref] !? { arg ref; copy[\ref] = ref + offset };
            case[\inputFrom] !? { arg from; copy[\inputFrom] = from + offset };
            cases.add(copy);
        });
    });
    results = runCases.(cases.asArray, plans.collect({ arg plan; plan[\seconds] }).maxItem);
    plans.do({ arg plan, index;
        plan[\judge].(results.copyRange(offsets[index], offsets[index] + plan[\cases].size - 1));
    });
};

// Shimmer 0 is each effect without it, bit for bit (design §7.4): every
// def at amount 0 (its ratio at 3: the interval changes nothing at 0)
// against its check-only copy of the def before shimmer, on the same pink
// noise for 5 s: the delay at feedback 0.4 and ping-pong 0.5 at a fixed
// fractional time, on a 0.5 Hz time LFO and frozen at 1 s; FreeVerb2 and
// the FDN at size 0.8, damp 0.5 (the FDN's drift draws its random values
// from the default generator: a seeder before each of the two nodes makes
// them the same). Largest difference 0.0
planAsBefore = {
    var zero = [\shimmer, 0, \shimmerRatio, 3], delay = [\time, 0.30928, \feedback, 0.4, \pingPong, 0.5];
    var reverb = [\size, 0.8, \damp, 0.5], window = [[0, 5]];
    var labels = ["the delay at 0.30928 s", "the delay on a time LFO", "the delay frozen at 1 s", "FreeVerb2", "the FDN"];
    (seconds: 5.05, cases: [
        (def: \strataDelay, controls: delay ++ zero, input: [\level, 0.5], windows: window, ref: 1),
        (def: \strataCheckShimmerDelay18, controls: delay, inputFrom: 0, windows: window),
        (def: \strataDelay, controls: delay ++ zero, input: [\level, 0.5], lfo: true, windows: window, ref: 3),
        (def: \strataCheckShimmerDelay18, controls: delay, inputFrom: 2, lfo: true, windows: window),
        (def: \strataDelay, controls: delay ++ zero, input: [\level, 0.5, \to, 1.5], steps: (frozen: [0, 1, 1]),
            windows: window, ref: 5),
        (def: \strataCheckShimmerDelay18, controls: delay, inputFrom: 4, steps: (frozen: [0, 1, 1]), windows: window),
        (def: \strataReverb, controls: reverb ++ zero, input: [\level, 0.25], windows: window, ref: 7),
        (def: \strataCheckShimmerVerb18, controls: reverb, inputFrom: 6, windows: window),
        (def: \strataReverbFDN, controls: reverb ++ zero, input: [\level, 0.25], seed: 1234, windows: window, ref: 9),
        (def: \strataCheckShimmerFdn18, controls: reverb, inputFrom: 8, seed: 1234, windows: window)
    ], judge: { arg results;
        [0, 2, 4, 6, 8].do({ arg index, which;
            var values = results[index];
            check.((windowField.(values, 0, 1) > 0.05) and: { windowField.(values, 0, 3) == 0 } and: { windowField.(values, 0, 2) == 0 },
                "shimmer: at amount 0, % is its def before shimmer, bit for bit (largest difference % over 5 s; largest sample %)".format(
                    labels[which], windowField.(values, 0, 3), windowField.(values, 0, 1).round(0.001)));
        });
    })
};

// The delay's loop is bounded (design §7.4: the loop's gain is still the
// feedback's): a 0.2 s pink burst at feedback 0.95, time 0.375 s, each of
// the five ratios at shimmer 1, unfrozen and frozen at 0.25 s (the loop's
// gain exactly 1): the energy in the last window of 9 s is at most 1 dB
// over the first after the burst. Each window is three of the loop's
// periods (the time and the feedback's one block)
planDelayBounded = {
    var rate = server.sampleRate, block = server.options.blockSize, time = 0.375;
    var period = ((time * rate).round + block) / rate, width = 3 * period;
    var windows = [[0.5, 0.5 + width], [9 - width, 9]], cases = List.new;
    ratios.do({ arg ratio;
        [false, true].do({ arg frozen;
            cases.add((def: \strataDelay, controls: [\time, time, \feedback, 0.95, \shimmer, 1, \shimmerRatio, ratio],
                input: [\level, 0.5, \to, 0.2], steps: if (frozen) { (frozen: [0, 1, 0.25]) } { () }, windows: windows,
                label: "ratio %, %".format(ratio, if (frozen) { "frozen" } { "unfrozen" })));
        });
    });
    (seconds: 9.05, cases: cases.asArray, judge: { arg results;
        cases.do({ arg case, index;
            var values = results[index], first = windowField.(values, 0, 0), last = windowField.(values, 1, 0);
            check.((first > 1) and: { last <= (first * (10 ** 0.1)) } and: { windowField.(values, 0, 2) == 0 }
                and: { windowField.(values, 1, 2) == 0 },
                "shimmer: the delay's loop at feedback 0.95 and shimmer 1 is bounded (%): the last window of 9 s within 1 dB of the first after the burst (% dB; first window's energy %)".format(
                    case[\label], powerDb.(last / first.max(1e-30)), first.round(0.1)));
        });
    })
};

// Each reverb's loop is bounded (design §7.4: the ceiling and the duck,
// shimmerLoop): every ratio x amount {0.5, 1} x size {0.8, 1} at damp 0, 3
// s of pink noise then silence: over 9 s the output's peak stays under 1.0
// and no NaN or inf reaches it, and at ratio 1.5, amount 1, size 1 (the
// worst of the five near 1) the halo after the input stops stays under -6
// dBFS and its RMS under haloRmsDb. A check-only case at ratio 1.02 (a loop that grows +110 to +126 dB
// unbounded, the 3.8 facts) proves the bound holds. Every random source is
// seeded (the input's noise, the FDN's drift), so a run's figures are the
// last run's. One reverb def a plan
// (its 21 cases: the FDN takes about 225 KB of the pool a node, 4.7 MB in
// all, so the FDN's plan runs in a batch of its own)
planReverbBounded = { arg def;
    var cases = List.new;
    (ratios ++ [1.02]).do({ arg ratio;
        var amounts = if (ratio == 1.02) { [1] } { [0.5, 1] }, sizes = if (ratio == 1.02) { [1] } { [0.8, 1] };
        amounts.do({ arg amount;
            sizes.do({ arg size;
                cases.add((def: def, controls: [\size, size, \damp, 0, \shimmer, amount, \shimmerRatio, ratio],
                    input: [\level, 0.25, \to, 3], windows: [[0, 9], [5, 9]], seed: 1234,
                    halo: (ratio == 1.5) and: { amount == 1 } and: { size == 1 },
                    bands: if ((ratio == 1.5) and: { amount == 1 } and: { size == 1 }) { [1000, 0, 6, 8.9] },
                    label: "% at ratio %, amount %, size %".format(def, ratio, amount, size)));
            });
        });
    });
    (seconds: 9.05, cases: cases.asArray, judge: { arg results;
        cases.do({ arg case, index;
            var values = results[index], peak = windowField.(values, 0, 1), halo = windowField.(values, 1, 1);
            check.((peak > 0.01) and: { peak < 1.0 } and: { windowField.(values, 0, 2) == 0 },
                "shimmer: % is bounded: its peak over 9 s is under 1.0 and no bad value reaches it (peak %, bad %, after the input stops %)".format(
                    case[\label], peak.round(0.0001), windowField.(values, 0, 2), halo.round(0.0001)));
            if (case[\halo]) {
                var rms = (windowField.(values, 1, 0) / (4 * server.sampleRate * 2)).sqrt;
                var pump = powerDb.(bandsField.(values, 2) / bandsField.(values, 3).max(1e-30));
                check.((halo < 0.5) and: { rms.ampdb < haloRmsDb } and: { rms > 1e-4 },
                    "shimmer: % holds a quiet halo after the input stops: from 5 to 9 s its peak under -6 dBFS and its RMS under % dB (peak % dB, RMS % dB)".format(
                        case[\label], haloRmsDb, ampDb.(halo), ampDb.(rms)));
                check.(pump <= haloPumpDb,
                    "shimmer: % holds its halo without pumping, the duck regulating it alone: from 6 to 8.9 s its level over 100 ms moves % dB (at most %)".format(
                        case[\label], pump, haloPumpDb));
            };
        });
    })
};

// Shimmer is heard (the review's findings 1 and 2): each effect on a sine
// of 440 Hz at 0.1 (moderate), at amount 0.5 and ratio 2 or 1.5, against
// the same case at amount 0: the band at 880 or 660 Hz (the shift) at least
// presentDb more (the effects are linear, so without a shift that band
// holds only the sine's leak through the band-passes), and at least
// shiftDb over the band the other ratio would make (660 or 880 Hz: a loop
// that does not follow the ratio, whose soft clip's harmonics reach 880
// Hz, fails there). Then each reverb at
// size 0.8, damp 0.5, ratio 2, amount 0.5, loud (0.5: its output well
// above the -22 dB RMS the first law ducked at) against quiet (0.05): on
// the sine, the band at 880 Hz, and on pink noise low-passed at 400 Hz, the
// band above 1200 Hz (where the shift moves it); the loud band within
// proportionalDb of twenty dB above the quiet one (shimmer present when
// loud, in proportion) and presentDb above the loud case at amount 0. And
// no pumping where the duck does not act: on the loud sine and the loud
// noise (the bound far above them), the largest level averaged over 100 ms
// from 2 to 5 s over the smallest, at most pumpDb more than the same case's
// at amount 0 (the reverb's own spread on that input; the input's own is
// reported too). Where the duck holds a runaway: planHeld
planPresent = { arg defs;
    var cases = List.new, judges = List.new, window = [2, 5];
    var add = { arg case; cases.add(case); cases.size - 1 };
    var bandDb = { arg results, a, b; powerDb.(bandsField.(results[a], 0) / bandsField.(results[b], 0).max(1e-30)) };
    var pumpOf = { arg values; powerDb.(bandsField.(values, 2) / bandsField.(values, 3).max(1e-30)) };
    [[\strataDelay, [\time, 0.375, \feedback, 0.4]], [\strataReverb, [\size, 0.8, \damp, 0.5]],
        [\strataReverbFDN, [\size, 0.8, \damp, 0.5]]].select({ arg pair; defs.includes(pair[0]) }).do({ arg pair;
        var def = pair[0], controls = pair[1], seed = if (def == \strataReverbFDN) { 1234 };
        [2, 1.5].do({ arg ratio;
            var band = [440 * ratio, 0] ++ window, other = [440 * (3.5 - ratio), 0] ++ window;
            var shim = add.((def: def, controls: controls ++ [\shimmer, 0.5, \shimmerRatio, ratio], seed: seed,
                input: [\level, 0, \sine, 0.1], bands: band, otherBands: other, windows: [window]));
            var plain = add.((def: def, controls: controls ++ [\shimmer, 0, \shimmerRatio, ratio], seed: seed,
                inputFrom: shim, bands: band, windows: [window]));
            judges.add({ arg results;
                var shift = powerDb.(bandsField.(results[shim], 0) / bandsField.(results[shim], 4).max(1e-30));
                check.((bandDb.(results, shim, plain) >= presentDb) and: { shift >= shiftDb },
                    "shimmer: % shimmers a moderate sine of 440 Hz at ratio % and amount 0.5: the band at % Hz % dB over amount 0 (at least % dB) and % dB over the band at % Hz (at least %)".format(
                        def, ratio, 440 * ratio, bandDb.(results, shim, plain), presentDb, shift, 440 * (3.5 - ratio), shiftDb));
            });
        });
        if (def != \strataDelay) {
            [[\sine, [\level, 0, \sine, 0.5], [\level, 0, \sine, 0.05], [880, 0] ++ window],
                [\noise, [\level, 0.5, \lowpass, 400], [\level, 0.05, \lowpass, 400], [1200, 1] ++ window]].do({ arg kind;
                var shimmered = controls ++ [\shimmer, 0.5, \shimmerRatio, 2];
                var loud = add.((def: def, controls: shimmered, seed: seed, input: kind[1], bands: kind[3], windows: [window]));
                var quiet = add.((def: def, controls: shimmered, seed: seed, input: kind[2], bands: kind[3], windows: [window]));
                var plain = add.((def: def, controls: controls ++ [\shimmer, 0], seed: seed, inputFrom: loud, bands: kind[3],
                    windows: [window]));
                // (the input's own spread, read on the input: the node a
                // silent check-only one)
                var input = add.((def: \strataCheckShimmerSilent, inputFrom: loud, probeInput: true,
                    bands: kind[3], windows: [window]));
                judges.add({ arg results;
                    var proportion = bandDb.(results, loud, quiet), over = bandDb.(results, loud, plain);
                    var rms = (bandsField.(results[loud], 1) / ((window[1] - window[0]) * server.sampleRate * 2)).sqrt;
                    var pump = pumpOf.(results[loud]), own = pumpOf.(results[plain]), inputPump = pumpOf.(results[input]);
                    var floor = if (kind[0] == \sine) { presentDb } { noisePresentDb };
                    check.(((proportion - 20).abs <= proportionalDb) and: { over >= floor },
                        "shimmer: % shimmers a loud % (its output RMS % dB) in proportion: the shifted band % dB over a tenth of the input's (20 dB within %), % dB over amount 0 (at least %)".format(
                            def, kind[0], ampDb.(rms), proportion, proportionalDb, over, floor));
                    check.((pump - own) <= pumpDb,
                        "shimmer: % on a loud steady % the duck leaves alone does not pump: its level over 100 ms from 2 to 5 s moves % dB, at amount 0 % dB (at most % dB more; the input's own %)".format(
                            def, kind[0], pump, own, pumpDb, inputPump));
                });
            });
        };
    });
    (seconds: 5.05, cases: cases.asArray, judge: { arg results; judges.do({ arg judge; judge.(results) }) })
};

// A bad value in the send never poisons a reverb (the review's finding 3):
// each reverb at size 0.8, ratio 2, at amount 0 and at amount 1, on pink
// noise, with one control block of inf and NaN on its input at 1 s: the
// input carries them, the output none over 4 s, and from 1.5 s on it plays
// as the same case without them does (its energy within haloSameDb): the
// send is zeroed before the reverb and its level follower, so neither
// FreeVerb2's combs, the FDN's lines nor the follower latch a NaN
planNanInLoop = {
    var defs = [\strataReverb, \strataReverbFDN], amounts = [0, 1], cases = List.new, judges = List.new;
    var windows = [[0, 4], [1.5, 4], [0, 1]], sameDb = 1;
    defs.do({ arg def;
        var seed = if (def == \strataReverbFDN) { 1234 };
        amounts.do({ arg amount;
            var controls = [\size, 0.8, \damp, 0.5, \shimmer, amount, \shimmerRatio, 2];
            var bad = cases.size, clean = bad + 1, input = bad + 2;
            // (the same noise in both: their inputs' generators seeded alike)
            cases.add((def: def, controls: controls, input: [\level, 0.25, \seed, 77], bad: 1, seed: seed, windows: windows));
            cases.add((def: def, controls: controls, input: [\level, 0.25, \seed, 77], seed: seed, windows: windows));
            cases.add((def: \strataCheckShimmerSilent, inputFrom: bad, probeInput: true, windows: windows));
            judges.add({ arg results;
                var after = powerDb.(windowField.(results[bad], 1, 0) / windowField.(results[clean], 1, 0).max(1e-30));
                check.((windowField.(results[input], 0, 2) == 1) and: { windowField.(results[bad], 0, 2) == 0 }
                    and: { windowField.(results[bad], 2, 1) > 0.01 } and: { after.abs <= sameDb },
                    "shimmer: a block of NaN and inf on %'s input at amount % never poisons it: the input carries them (%), the output none (%), and from 1.5 s it plays as the same case without them (% dB, within %)".format(
                        def, amount, windowField.(results[input], 0, 2), windowField.(results[bad], 0, 2), after, sameDb));
            });
        });
    });
    (seconds: 4.05, cases: cases.asArray, judge: { arg results; judges.do({ arg judge; judge.(results) }) })
};

// The duck where it acts (the review's round 2, finding 1): each reverb at
// size 1, damp 0, amount 1 and its worst ratio (worstRatios) on a steady
// send, a runaway the duck holds at its bound: from 4 to 8.9 s its energy
// at most heldOverDb over the same send at amount 0 and its level over 100
// ms moving at most heldPumpDb more than that send's. On a sine of 440 Hz at
// 0.25 the duck regulates (an instrumented copy read its gain at 0.15-0.2 on
// average, the output at the knee's top); on pink noise at 0.25 (seeded)
// the reverb's own build-up at size 1 reaches the bound, and the duck holds
// the loop all but shut. With it, what the bound holds (the review's
// finding 4): the held output's RMS over the send's true RMS, for that noise
// and for a sine of 440 Hz at 0.25 (reported). And a send near full scale
// (pink noise at 0.9, the review's finding 5): no bad value over 9 s, and
// its peak at most loudOverDb over the same send at amount 0
planHeld = {
    var cases = List.new, judges = List.new, window = [4, 8.9];
    var add = { arg case; cases.add(case); cases.size - 1 };
    var pumpOf = { arg values; powerDb.(bandsField.(values, 2) / bandsField.(values, 3).max(1e-30)) };
    var energyDb = { arg results, a, b; powerDb.(bandsField.(results[a], 1) / bandsField.(results[b], 1).max(1e-30)) };
    [\strataReverb, \strataReverbFDN].do({ arg def;
        var ratio = worstRatios[def], seed = if (def == \strataReverbFDN) { 1234 };
        var held = [\size, 1, \damp, 0, \shimmer, 1, \shimmerRatio, ratio], plain = [\size, 1, \damp, 0, \shimmer, 0];
        var bands = [1000, 0] ++ window, all = [[0, 9]];
        var noise = add.((def: def, controls: held, seed: seed, input: [\level, 0.25], bands: bands, windows: all));
        var noisePlain = add.((def: def, controls: plain, seed: seed, inputFrom: noise, bands: bands, windows: all));
        var noiseIn = add.((def: \strataCheckShimmerSilent, inputFrom: noise, probeInput: true, bands: bands, windows: all));
        var sine = add.((def: def, controls: held, seed: seed, input: [\level, 0, \sine, 0.25], bands: bands, windows: all));
        var sinePlain = add.((def: def, controls: plain, seed: seed, inputFrom: sine, bands: bands, windows: all));
        var sineIn = add.((def: \strataCheckShimmerSilent, inputFrom: sine, probeInput: true, bands: bands, windows: all));
        var loud = add.((def: def, controls: held, seed: seed, input: [\level, 0.9], windows: all));
        var loudPlain = add.((def: def, controls: plain, seed: seed, inputFrom: loud, windows: all));
        judges.add({ arg results;
            var pump = pumpOf.(results[noise]), own = pumpOf.(results[noisePlain]);
            var over = energyDb.(results, noise, noisePlain);
            var sinePump = pumpOf.(results[sine]), sineOwn = pumpOf.(results[sinePlain]);
            var sineOver = energyDb.(results, sine, sinePlain);
            var loudOver = ampDb.(windowField.(results[loud], 0, 1) / windowField.(results[loudPlain], 0, 1).max(1e-15));
            var sineTimes = energyDb.(results, sine, sineIn).dbamp;
            check.((sineTimes <= heldSineTimes) and: { (sinePump - sineOwn) <= heldPumpDb },
                "shimmer: % holds a runaway on a steady sine without pumping (ratio %, amount 1, size 1, the duck regulating at its bound: its RMS from 4 to 8.9 s % times the send's, at most %; % dB over amount 0; its level over 100 ms moves % dB, at amount 0 % dB, at most % dB more)".format(
                    def, ratio, sineTimes.round(0.01), heldSineTimes, sineOver, sinePump, sineOwn, heldPumpDb));
            check.((over <= heldOverDb) and: { (pump - own) <= heldPumpDb },
                "shimmer: % holds a runaway on steady pink noise without pumping (ratio %, amount 1, size 1, the reverb's own build-up at the bound: its energy from 4 to 8.9 s % dB over amount 0, at most %; its level over 100 ms moves % dB, at amount 0 % dB, at most % dB more)".format(
                    def, ratio, over, heldOverDb, pump, own, heldPumpDb));
            check.(true, "shimmer: %'s held runaway is % times the send's RMS on pink noise and % times on a sine (its RMS over the send's, from 4 to 8.9 s)".format(
                def, energyDb.(results, noise, noiseIn).dbamp.round(0.01), energyDb.(results, sine, sineIn).dbamp.round(0.01)));
            check.((windowField.(results[loud], 0, 2) == 0) and: { loudOver <= loudOverDb },
                "shimmer: % on a send near full scale (pink noise at 0.9, ratio %, amount 1, size 1) stays finite and peaks % dB over amount 0 (at most %; its peak %, at amount 0 %)".format(
                    def, ratio, loudOver, loudOverDb, windowField.(results[loud], 0, 1).round(0.001),
                    windowField.(results[loudPlain], 0, 1).round(0.001)));
        });
    });
    (seconds: 9.05, cases: cases.asArray, judge: { arg results; judges.do({ arg judge; judge.(results) }) })
};

// setShimmer sets both nodes and keeps its values; a bypass of both and a
// lift creates nodes with them (design §7.4: kept through a bypass), and a
// setShimmer while bypassed is kept for the lift
checkCommand = {
    var kept = { arg key; engine.areaState[\effects][\controls][key] !? { arg controls; [controls[\shimmer], controls[\shimmerRatio]] } };
    var read = { arg key; engine.synths[key] !? { arg synth; [getControl.(synth, \shimmer), getControl.(synth, \shimmerRatio)] } };
    var near = { arg values, expected; values.notNil and: { [values, expected].flop.every({ arg pair;
        pair[0].notNil and: { pair[0].equalWithPrecision(pair[1], 1e-6) } }) } };
    var set, lifted, again;
    command.(\setShimmer, 0.6, 0.4, 3);
    server.sync;
    set = [read.(\delay), read.(\reverb), kept.(\delay), kept.(\reverb)];
    command.(\setBypass, 0, 1); command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
    server.sync;
    lifted = [read.(\delay), read.(\reverb)];
    check.(near.(set[0], [0.6, 3]) and: { near.(set[1], [0.4, 3]) } and: { near.(set[2], [0.6, 3]) } and: { near.(set[3], [0.4, 3]) }
        and: { near.(lifted[0], [0.6, 3]) } and: { near.(lifted[1], [0.4, 3]) },
        "shimmer: setShimmer(0.6, 0.4, 3) sets the delay's and the reverb's shimmer and ratio and keeps them (nodes %, %; kept %, %), and a lift keeps the shimmer (the lifted nodes %, %)".format(
            set[0], set[1], set[2], set[3], lifted[0], lifted[1]));
    command.(\setBypass, 0, 1); command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    command.(\setShimmer, 0.25, 0.75, 0.5);
    server.sync;
    again = [kept.(\delay), kept.(\reverb), engine.synths[\delay].isNil and: { engine.synths[\reverb].isNil }];
    command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
    server.sync;
    again = again ++ [read.(\delay), read.(\reverb)];
    check.(near.(again[0], [0.25, 0.5]) and: { near.(again[1], [0.75, 0.5]) } and: { again[2] == true }
        and: { near.(again[3], [0.25, 0.5]) } and: { near.(again[4], [0.75, 0.5]) },
        "shimmer: setShimmer while both are bypassed is kept, and the lift creates the nodes with it (kept %, %, no nodes %; lifted %, %)".format(
            *again));
    command.(\setShimmer, 0, 0, 2);
    server.sync;
};

// A non-finite value in any of setShimmer's three places is ignored with
// one line each, the nodes and the kept values left as they are
checkIgnoredValues = {
    var lines = List.new, nan = 0.0 / 0.0, before, after;
    var state = { [\delay, \reverb].collect({ arg key;
        [getControl.(engine.synths[key], \shimmer), getControl.(engine.synths[key], \shimmerRatio)]
            ++ engine.areaState[\effects][\controls][key].atAll([\shimmer, \shimmerRatio]) }) };
    command.(\setShimmer, 0.5, 0.5, 1.5);
    server.sync;
    before = state.value;
    withIgnoredLines.(lines, { [[nan, 0.2, 2], [0.2, inf, 2], [0.2, 0.2, -inf]].do({ arg values; command.(\setShimmer, *values) }) });
    server.sync;
    after = state.value;
    check.((lines.size == 3) and: { after == before },
        "shimmer: setShimmer with a NaN or infinite value in each place is ignored with one line each (lines %; before %, after %)".format(
            lines.asArray, before, after));
    command.(\setShimmer, 0, 0, 2);
    server.sync;
};

// Shimmer's four rings (shimmerRingFrames, one channel each, bufnums that
// never change): the delay's node reads the first two, the reverb's the
// last two, through a bypass and its lift; with shimmer on and pink noise
// on both sends each holds audio, and a bypass's free empties its
// effect's two (a lifted node never plays a ring's old audio)
checkRings = {
    var rings = engine.areaState[\effects][\shimmerRings], bufnums = rings !? { rings.collect(_.bufnum) };
    var nodeRings = { [\delay, \reverb].collect({ arg key; engine.synths[key] !? { arg synth;
        [getControl.(synth, \shiftL), getControl.(synth, \shiftR)] } }).flatten };
    var first = nodeRings.value, noise, filled, emptied, lifted;
    command.(\setShimmer, 1, 1, 2);
    noise = [\delaySend, \reverbSend].collect({ arg name;
        Synth(\strataCheckShimmerInput, [\out, engine.mixBus(name), \level, 0.25], engine.processGroup, \addToTail) });
    server.sync; 0.5.wait;
    filled = rings !? { rings.collect({ arg buffer; ringPeak.(buffer) }) };
    noise.do(_.free); server.sync;
    command.(\setBypass, 0, 1); command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    emptied = rings !? { rings.collect({ arg buffer; ringPeak.(buffer) }) };
    command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
    server.sync;
    lifted = nodeRings.value;
    command.(\setShimmer, 0, 0, 2);
    server.sync;
    check.(rings.notNil and: { rings.size == 4 } and: { rings.every({ arg buffer; (buffer.numFrames == engine.shimmerRingFrames)
            and: { buffer.numChannels == 1 } }) } and: { bufnums.asSet.size == 4 } and: { first == bufnums } and: { lifted == bufnums },
        "shimmer: four rings of % frames, one channel each, the delay's node on the first two and the reverb's on the last two, through a bypass and its lift (bufnums %, the nodes' %, lifted %)".format(
            engine.shimmerRingFrames, bufnums, first, lifted));
    check.(filled.notNil and: { filled.every({ arg peak; peak.notNil and: { peak > 0.001 } }) }
        and: { emptied.every({ arg peak; peak == 0 }) },
        "shimmer: a bypass's free empties its effect's rings (largest sample with noise on the sends %, after the free %)".format(
            filled, emptied));
};

// A fresh engine starts at shimmer 0 and ratio 2 on both nodes, kept so
// too, the standard tier and the high one (the FDN, on its two rings);
// the high engine's FDN keeps setShimmer's values through a bypass's lift
checkFresh = {
    var root = h.tempDir +/+ "shimmer-high/", write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    var readEngine = { arg target; [\delay, \reverb].collect({ arg key;
        [target.synths[key] !? { arg synth; [getControl.(synth, \shimmer), getControl.(synth, \shimmerRatio)] },
            target.areaState[\effects][\controls][key].atAll([\shimmer, \shimmerRatio])] }) };
    var fresh = h.startEngine(()), high, freshValues, highValues, highRings, highBufnums, lifted;
    server.sync;
    freshValues = readEngine.(fresh);
    h.freeEngine(fresh);
    server.sync;
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 16\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    high = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    server.sync;
    highValues = readEngine.(high);
    highBufnums = high.areaState[\effects][\shimmerRings] !? { arg rings; rings.collect(_.bufnum) };
    highRings = high.synths[\reverb] !? { arg synth; [synth.defName.asSymbol, getControl.(synth, \shiftL), getControl.(synth, \shiftR)] };
    h.commandTo(high, \setShimmer, 0.5, 0.7, 1.5);
    h.commandTo(high, \setBypass, 1, 1);
    0.2.wait; server.sync;
    h.commandTo(high, \setBypass, 1, 0);
    server.sync;
    lifted = high.synths[\reverb] !? { arg synth; [getControl.(synth, \shimmer), getControl.(synth, \shimmerRatio),
        getControl.(synth, \shiftL), getControl.(synth, \shiftR)] };
    h.freeEngine(high);
    server.sync;
    check.((freshValues == [[[0, 2], [0, 2]], [[0, 2], [0, 2]]]) and: { highValues == freshValues },
        "shimmer: a fresh engine starts at shimmer 0 and ratio 2 on the delay and the reverb, the nodes and the kept values (standard %, high %)".format(
            freshValues, highValues));
    check.(highBufnums.notNil and: { highRings == [\strataReverbFDN, highBufnums[2], highBufnums[3]] }
        and: { lifted.notNil and: { lifted[0].equalWithPrecision(0.7, 1e-6) } and: { lifted[1] == 1.5 }
            and: { lifted.copyRange(2, 3) == highBufnums.copyRange(2, 3) } },
        "shimmer: a high engine's FDN reads the reverb's two rings and keeps setShimmer through a lift (rings %, the node %, lifted %)".format(
            highBufnums, highRings, lifted));
};

// the signal checks in four batches, each under 5 MB of the pool: amount
// 0, a NaN in the send and the FDN heard (5 s); the delay's loop and
// FreeVerb2's, and the two heard (9 s); the FDN's loop (9 s); the held
// runaways and the send near full scale (9 s)
guarded.("shimmer 0 as before, a NaN in the send and the FDN heard",
    { runPlans.([planAsBefore.value, planNanInLoop.value, planPresent.([\strataReverbFDN])]) });
guarded.("the delay's and FreeVerb2's loops, and the two heard",
    { runPlans.([planDelayBounded.value, planReverbBounded.(\strataReverb), planPresent.([\strataDelay, \strataReverb])]) });
guarded.("the FDN's loop", { runPlans.([planReverbBounded.(\strataReverbFDN)]) });
guarded.("the duck where it holds a runaway", { runPlans.([planHeld.value]) });
guarded.("setShimmer", checkCommand);
guarded.("setShimmer's ignored values", checkIgnoredValues);
guarded.("the rings", checkRings);
guarded.("a fresh engine", checkFresh);

// the engine as the area found it: no shimmer, nothing bypassed
try { command.(\setShimmer, 0, 0, 2) } { };
command.(\setBypass, 0, 0);
command.(\setBypass, 1, 0);
server.sync;
}
