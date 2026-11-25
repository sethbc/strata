// test/engine_check/reverb.scd
// The high tier's reverb freeze (3.9 design, #819) on \strataReverbFDN:
// its eight lines are sixteen buffers (lib/engine/StrataReverb.sc), and
// unfrozen it is 3.8.0's def, bit for bit (against a check-only copy of
// it). The signal checks run nodes of the engine's own def on buses, lines
// and rings of their own (startCheckNode, the one place this area starts
// one), measured on the server in windows of server time, so a busy
// machine changes nothing.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var readBus = { arg bus; h.readBus(bus) };
// the windows an analysis measures, and the values it gives each
var numWindows = 8, fields = 5, windowField;
var newLines, startCheckNode, runCases, guarded, powerDb, stepsArgs;
var checkGraph, checkAsBefore, checkHold, checkBehavior, checkHeldDrift, checkCommands, checkToggledNode, startHigh, withIgnoredLines;
// the def the behavior checks freeze (checkBehavior)
var freezeDef = \strataReverbFDN;
// the bar (design, Decided 6): the level's step at the freeze against an
// unfrozen twin, and the level and the band above 6 kHz after 60 s frozen,
// each within barDb
var barDb = 1;
// the band's own step at the freeze (against the window before it) the
// design asks the builder to look at: above this, the rising gain is tried
var bandStepLookDb = 1.5;
// the audio channels the server's allocator holds (#807: the area gives
// back every bus it allocates), how many it held as the area began, and
// the high engine's context's (checkCommands: its inputs and its silent
// output, which the harness frees only at the run's end)
var audioChannelsHeld = { server.audioBusAllocator.blocks.sum({ arg block; block.size }) };
var audioChannelsAtStart = audioChannelsHeld.value, contextChannels = 0;

// A stereo input from `from` to `to` (s from its start): independent noise
// at level, pink high-passed twice at 100 Hz (white 0) or white (white 1).
// It draws from a random generator of its own (rgen, RandID), seeded at the
// start (RandSeed), so every run plays the same noise and the seeders below
// never touch it
SynthDef(\strataCheckReverbInput, { arg out, level = 0.25, white = 0, from = 0, to = 1e9, rgen = 8, seed = 1;
    var id = RandID.ir(rgen), seeded = RandSeed.kr(1, seed), elapsed = Sweep.ar(0, 1);
    var pink = ({ PinkNoise.ar(level) } ! 2).collect({ arg channel; HPF.ar(HPF.ar(channel, 100), 100) });
    var noise = Select.ar(white, [pink, { WhiteNoise.ar(level) } ! 2]);
    Out.ar(out, noise * (elapsed >= from) * (elapsed < to));
}).add;
// Reseeds the default random generator (rgen 0, which the FDN's drift
// draws from) at the start of every control block: a seeder just before
// each of two nodes makes their drifts the same (as shimmer.scd's)
SynthDef(\strataCheckReverbSeed, { arg out, seed = 1234;
    Out.kr(out, A2K.kr(RandSeed.ar(Impulse.ar(ControlRate.ir), seed)));
}).add;
// A control bus's value over time from the synth's start: values[0], then
// values[i] from times[i - 1] (s; rising, 1e9 for none)
SynthDef(\strataCheckReverbSteps, { arg out, values = #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        times = #[1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9, 1e9];
    var elapsed = Sweep.kr(0, 1);
    Out.kr(out, Select.kr(times.collect({ arg time; elapsed >= time }).sum, values));
}).add;
// fdnHeldDrift (StrataReverb.sc) on a known signal: a 0.5 Hz sine of
// depth (a drift's size, moving slower than fdnDriftReturnRate) held while
// open is 0, from closeAt to openAt (s), written with the sine at every
// control block into buf ([sine, held] frames) from the synth's start
SynthDef(\strataCheckReverbDrift, { arg buf, depth = 0.0005, closeAt = 1, openAt = 2.5;
    var elapsed = Sweep.kr(0, 1), sine = SinOsc.kr(0.5, 0, depth);
    var open = 1 - ((elapsed >= closeAt) * (elapsed < openAt));
    RecordBuf.kr([sine, engine.fdnHeldDrift(sine, open)], buf, loop: 0, doneAction: 2);
}).add;
// A control bus moving linearly from `from` to `to` over seconds
SynthDef(\strataCheckReverbSweep, { arg out, from = 0.3, to = 0.9, seconds = 6;
    Out.kr(out, Line.kr(from, to, seconds));
}).add;
// A stereo bus in eight windows of time from the synth's start ([start,
// end] s each): per window, the sum of its squared samples (both channels,
// bad values counted as 0), the same of its band above 6 kHz (two
// second-order highpasses at 6 kHz), its largest absolute sample, the
// largest absolute difference from ref (summed over both channels) and
// whether a NaN or inf reached it (1); five values a window on out. It
// frees itself at seconds
SynthDef(\strataCheckReverbWindows, { arg in, ref, out, seconds = 1, windows = #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    var sig = In.ar(in, 2), other = In.ar(ref, 2), elapsed = Sweep.ar(0, 1);
    var codes = CheckBadValues.ar(sig, 0, 0), bad = ((codes > 0.5) * (codes < 2.5)).sum.min(1);
    var clean = sig.collect({ arg channel, index; Select.ar(codes[index] > 0, [channel, DC.ar(0)]) });
    var band = HPF.ar(HPF.ar(clean, 6000), 6000);
    var largest = clean[0].abs.max(clean[1].abs), difference = (sig - other).abs.sum;
    Out.kr(out, 8.collect({ arg index;
        var inside = (elapsed >= windows[index * 2]) * (elapsed < windows[(index * 2) + 1]);
        A2K.kr([Integrator.ar(clean.squared.sum * inside, 1), Integrator.ar(band.squared.sum * inside, 1),
            RunningMax.ar(largest * inside), RunningMax.ar(difference * inside), RunningMax.ar(bad * inside)])
    }).flat);
    Line.kr(0, 0, seconds, doneAction: 2);
}).add;

// A check-only copy of \strataReverbFDN as it is in 3.8.0 (before #819),
// its shimmer loop through the engine's own methods: unfrozen, the def is
// this, bit for bit
SynthDef(\strataCheckReverbFDNBefore, {
    arg in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0,
        shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2;
    var room = size.clip(0, 1).lag(0.1), damping = damp.clip(0, 1).lag(0.1) * 0.4;
    var sig = ((In.ar(in, 2) + (In.ar(delayIn, 2) * delayToReverb.clip(0, 1).lag(engine.fxMixLag)))
        * engine.liftFade(fadeIn)).collect({ arg channel; engine.zeroBadValues(channel) });
    var feedbackBase = 0.7 + (0.28 * room), reference = 1378 * SampleDur.ir;
    var drift = [0, 0, LFNoise1.kr(0.31) * 0.0006, 0, 0, 0, LFNoise1.kr(0.43) * 0.0005, 0];
    var lengths = engine.fdnLineSeconds * (0.6 + (0.4 * room)) + drift;
    var diffused, feedback, lines, sum, wet;
    feedback = LocalIn.ar(10);
    diffused = (sig + feedback.copyRange(8, 9)).collect({ arg channel, side;
        engine.fdnDiffuserSeconds[side].inject(channel, { arg each, time;
            AllpassN.ar(each, time, time, time * 19)
        })
    });
    lines = 8.collect({ arg index;
        var line = DelayL.ar((diffused[index % 2] * 0.25) + feedback[index], engine.fdnLineSeconds[index] + 0.002,
            lengths[index] - ControlDur.ir);
        OnePole.ar(line, damping)
    });
    sum = lines.sum * (2 / 8);
    wet = [lines[0] + lines[2] + lines[4] + lines[6], lines[1] + lines[3] + lines[5] + lines[7]]
        .collect({ arg channel; engine.zeroBadValues(channel) });
    LocalOut.ar(lines.collect({ arg line, index;
        (line - sum) * (feedbackBase ** (lengths[index] / reference))
    }) ++ engine.shimmerLoop(wet, sig, [shiftL, shiftR], shimmer.clip(0, 1).lag(engine.fxMixLag), shimmerRatio.clip(0.5, 4)));
    Out.ar(out, wet * mix.clip(0, 1).lag(engine.fxMixLag));
}).add;

// A power ratio in dB
powerDb = { arg ratio; ratio.max(1e-30).log10 * 10 };
// \strataCheckReverbSteps' controls for [values, times]
stepsArgs = { arg spec;
    var values = spec[0], times = spec[1];
    [\values, (values ++ (values.last ! 24)).copyRange(0, 23), \times, (times ++ (1e9 ! 24)).copyRange(0, 23)]
};

// A window's field of a case's values (0 energy, 1 band energy, 2 peak, 3
// largest difference from ref, 4 bad)
windowField = { arg values, window, field; values !? { values[(window * fields) + field] } ? 0 };

// A node's own buffers: sixteen line buffers (the engine's sizes, on
// consecutive bufnums: newReverbLines; a node on the engine's own would
// write into its running lines) and two shimmer rings (a ring left out is
// buffer 0, which the node would write)
newLines = { (lines: engine.newReverbLines, rings: 2.collect({ Buffer.alloc(server, engine.shimmerRingFrames, 1) })) };

// The one place this area starts a reverb node (the engine's FDN or the
// check-only copy): on its own buses (delayIn: a silent bus), its own
// lines (lineBuf: the first of them; the copy has no such control, and the
// server ignores a control a def lacks) and rings, at level 1 unless
// controls say otherwise
startCheckNode = { arg def, inBus, outBus, silent, buffers, controls, target;
    Synth(def, [\in, inBus, \delayIn, silent, \out, outBus, \lineBuf, buffers[\lines][0].bufnum,
        \shiftL, buffers[\rings][0], \shiftR, buffers[\rings][1], \mix, 1] ++ controls, target, \addToTail)
};

// Run cases at once, in one group created in one bundle, for seconds of
// server time: each case an Event of def (\strataReverbFDN unless given),
// controls (the node's), input (\strataCheckReverbInput's controls) or
// inputFrom (an earlier case's index, whose input it shares), seed (a
// seeder just before the node), sweeps (control -> [from, to, seconds]: a
// \strataCheckReverbSweep mapped to the node's control), steps (control ->
// [values, times]: a \strataCheckReverbSteps mapped to it), ref (an earlier
// case's index, whose output the difference is taken from) and windows (up
// to eight [start, end] pairs). Each input's noise draws from a generator
// of its own (8 + its index), seeded with 1000 + its index unless its
// input says otherwise. The values of each case, as windowField reads them
runCases = { arg cases, seconds;
    var group = Group.after(context.xg), silent = Bus.audio(server, 2), seedBus = Bus.control(server, 1);
    var condition = Condition(false), ended = 0, results;
    var made = cases.collect({ arg case;
        (inBus: if (case[\inputFrom].isNil) { Bus.audio(server, 2) }, outBus: Bus.audio(server, 2),
            resultBus: Bus.control(server, numWindows * fields), controlBuses: List.new, buffers: newLines.value)
    });
    check.((8 + cases.size) <= server.options.numRGens,
        "reverb: a batch's % inputs each get a random generator of their own (8 + its index under the server's %)".format(
            cases.size, server.options.numRGens));
    made.do({ arg each; each[\resultBus].setAll(0) });
    server.sync;
    server.makeBundle(nil, {
        cases.do({ arg case, index;
            var each = made[index];
            if (case[\inputFrom].notNil) { each[\inBus] = made[case[\inputFrom]][\inBus] } {
                Synth(\strataCheckReverbInput, [\out, each[\inBus], \rgen, 8 + index, \seed, 1000 + index] ++ (case[\input] ? []),
                    group, \addToTail);
            };
        });
        cases.do({ arg case, index;
            var each = made[index], node, maps = List.new;
            (case[\sweeps] ? ()).keysValuesDo({ arg control, sweep;
                var bus = Bus.control(server, 1);
                each[\controlBuses].add(bus);
                maps.add([control, bus]);
                Synth(\strataCheckReverbSweep, [\out, bus, \from, sweep[0], \to, sweep[1], \seconds, sweep[2]], group, \addToTail);
            });
            (case[\steps] ? ()).keysValuesDo({ arg control, spec;
                var bus = Bus.control(server, 1);
                each[\controlBuses].add(bus);
                maps.add([control, bus]);
                Synth(\strataCheckReverbSteps, [\out, bus] ++ stepsArgs.(spec), group, \addToTail);
            });
            case[\seed] !? { arg seed; Synth(\strataCheckReverbSeed, [\out, seedBus, \seed, seed], group, \addToTail) };
            node = startCheckNode.(case[\def] ? \strataReverbFDN, each[\inBus], each[\outBus], silent, each[\buffers],
                case[\controls] ? [], group);
            maps.do({ arg pair; node.map(pair[0], pair[1]) });
        });
        cases.do({ arg case, index;
            var windows = (case[\windows] ++ ([0, 0] ! numWindows)).copyRange(0, numWindows - 1).flat;
            var analysis = Synth(\strataCheckReverbWindows, [\in, made[index][\outBus],
                \ref, case[\ref] !? { arg ref; made[ref][\outBus] } ? silent, \out, made[index][\resultBus],
                \seconds, seconds, \windows, windows], group, \addToTail);
            OSCFunc({ ended = ended + 1; if (ended == cases.size) { condition.test = true; condition.signal } },
                '/n_end', server.addr, argTemplate: [analysis.nodeID]).oneShot;
        });
    });
    awaitReply.(condition, (seconds * 10) + 10);
    results = made.collect({ arg each; readBus.(each[\resultBus]) });
    group.free; server.sync;
    made.do({ arg each, index;
        if (cases[index][\inputFrom].isNil) { each[\inBus].free };
        [each[\outBus], each[\resultBus]].do(_.free);
        each[\controlBuses].do(_.free);
        (each[\buffers][\lines] ++ each[\buffers][\rings]).do(_.free);
    });
    silent.free; seedBus.free; server.sync;
    results
};

// A check that raises (a method the engine does not have) fails, naming it
guarded = { arg name, body;
    try { body.value } { arg error; check.(false, "reverb: % raised %".format(name, error.errorString)) };
};

// The lines are buffers: the FDN's graph reads each line twice, through
// BufDelayL (interpolated) and BufDelayN (whole samples), and has no
// DelayL of its own memory left
checkGraph = {
    var ugens = SynthDescLib.global.at(\strataReverbFDN).def.children;
    var counts = [BufDelayL, BufDelayN, DelayL].collect({ arg kind; ugens.count({ arg ugen; ugen.class === kind }) });
    check.(counts == [8, 8, 0],
        "reverb: the FDN reads eight BufDelayL and eight BufDelayN and no DelayL (BufDelayL, BufDelayN, DelayL: %)".format(counts));
};

// Unfrozen, the def is 3.8.0's (design, Constraints): four pairs on shared
// inputs, each pair's drift reseeded before each node, for 6 s: size 0.8
// still and size swept 0.3 to 0.9 by a control bus both nodes map, each at
// shimmer 0 and 0.5. Largest difference exactly 0
checkAsBefore = {
    var seconds = 6, window = [[0, seconds]], cases = List.new, labels = List.new, results, largest;
    [false, true].do({ arg swept;
        [0, 0.5].do({ arg shimmer;
            var controls = [\size, 0.8, \damp, 0.5, \shimmer, shimmer, \shimmerRatio, 2];
            var sweeps = if (swept) { (size: [0.3, 0.9, seconds]) } { () };
            var first = cases.size;
            cases.add((controls: controls, input: [\level, 0.25], seed: 1234, sweeps: sweeps, windows: window, ref: first + 1));
            cases.add((def: \strataCheckReverbFDNBefore, controls: controls, inputFrom: first, seed: 1234, sweeps: sweeps,
                windows: window));
            labels.add("size %, shimmer %".format(if (swept) { "swept 0.3 to 0.9" } { 0.8 }, shimmer));
        });
    });
    results = runCases.(cases.asArray, seconds + 0.05);
    largest = labels.collect({ arg label, pair; windowField.(results[pair * 2], 0, 3) });
    check.(labels.every({ arg label, pair; windowField.(results[pair * 2], 0, 2) > 0.01 })
        and: { largest.every({ arg value; value == 0 }) }
        and: { results.every({ arg values; windowField.(values, 0, 4) == 0 }) },
        "reverb: unfrozen, the def is 3.8.0's (largest difference %; %; peaks %)".format(largest.maxItem, labels.asArray,
            labels.collect({ arg label, pair; windowField.(results[pair * 2], 0, 2).round(0.001) })));
};

// Runs body with the lines an engine posts for ignored commands added to
// lines (its modulation area's postIgnored hook), put back however it ends
withIgnoredLines = { arg target, lines, body;
    var modulation = target.areaState[\modulation], previous = modulation[\postIgnored];
    modulation[\postIgnored] = { arg line; lines.add(line) };
    body.protect({ modulation[\postIgnored] = previous });
};

// A high engine of its own (the performance file says high), as the
// effects and shimmer areas build one
startHigh = {
    var root = h.tempDir +/+ "reverb-high/", write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 16\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"))
};

// The bar (design, Decided 6 and section 5), measured on the real def:
// twelve pairs, a node frozen at 12 s (the network has reached its level,
// size 1 included) and an unfrozen twin on the same input and drift, each
// pair's input stopping at 13 s (so an unfrozen node decays: the twin's
// last window is silent), read to 60 s after the freeze in windows of 0.9
// s: the level's step in the window from 0.1 to 1.0 s after the freeze
// against the twin's in the same window, and the level and the band above
// 6 kHz in the window from 59.1 to 60.0 s against that first one. The
// settings as size, damp, noise, shimmer (pink noise high-passed twice at
// 100 Hz; shimmer's ratio 2). Every case's three figures are a check of
// their own, with the band's own step at the freeze against the window
// before it (the design asks the builder to look at it: above
// bandStepLookDb the rising gain is tried)
checkHold = {
    var freezeAt = 12, inputTo = 13, seconds = 72.05;
    var before = [freezeAt - 0.9, freezeAt], after = [freezeAt + 0.1, freezeAt + 1.0], held = [freezeAt + 59.1, freezeAt + 60.0];
    var settings = [[0.5, 0, \pink, 0], [0.5, 0.5, \pink, 0], [0.8, 0, \pink, 0], [0.8, 0.5, \pink, 0], [1, 0.5, \pink, 0],
        [0.2, 1, \pink, 0], [0.5, 1, \white, 0], [0.8, 0.5, \white, 0], [1, 1, \white, 0], [0.2, 0, \white, 0],
        [0.8, 0.5, \pink, 1], [1, 0.5, \pink, 1]];
    var cases = List.new, results, figures, steps, levels, bands, silent;
    settings.do({ arg setting, index;
        var controls = [\size, setting[0], \damp, setting[1], \shimmer, setting[3], \shimmerRatio, 2];
        var input = [\level, 0.25, \white, if (setting[2] == \white) { 1 } { 0 }, \to, inputTo];
        var first = cases.size, windows = [before, after, held];
        cases.add((controls: controls, input: input, seed: 2000 + index, steps: (frozen: [[0, 1], [freezeAt]]), windows: windows));
        cases.add((controls: controls, inputFrom: first, seed: 2000 + index, windows: windows));
    });
    results = runCases.(cases.asArray, seconds);
    figures = settings.collect({ arg setting, index;
        var frozen = results[index * 2], twin = results[(index * 2) + 1];
        [powerDb.(windowField.(frozen, 1, 0) / windowField.(twin, 1, 0).max(1e-30)),
            powerDb.(windowField.(frozen, 2, 0) / windowField.(frozen, 1, 0).max(1e-30)),
            powerDb.(windowField.(frozen, 2, 1) / windowField.(frozen, 1, 1).max(1e-30)),
            powerDb.(windowField.(frozen, 1, 1) / windowField.(frozen, 0, 1).max(1e-30)),
            powerDb.(windowField.(twin, 2, 0) / windowField.(twin, 1, 0).max(1e-30))]
    });
    // every case's figures, each a check of the bar's three, with the band's
    // own step against the window before the freeze (the design's look)
    settings.do({ arg setting, index;
        var each = figures[index];
        check.(each.copyRange(0, 2).every({ arg value; value.abs < barDb }),
            "reverb: the bar at size %, damp %, % noise, shimmer %: step %, level after 60 s %, band above 6 kHz after 60 s % dB (the band's own step at the freeze % dB, looked at above %; the twin after 60 s % dB)".format(
                setting[0], setting[1], setting[2], setting[3], each[0].round(0.01), each[1].round(0.01), each[2].round(0.01),
                each[3].round(0.01), bandStepLookDb, each[4].round(0.01)));
    });
    steps = figures.collect(_[0]); levels = figures.collect(_[1]); bands = figures.collect(_[2]); silent = figures.collect(_[4]);
    check.(results.every({ arg values; (0 .. 2).every({ arg window; windowField.(values, window, 4) == 0 }) })
        and: { settings.every({ arg setting, index; windowField.(results[index * 2], 1, 0) > 1 }) },
        "reverb: the hold batch has signal and no bad value (energies after the freeze %)".format(
            settings.collect({ arg setting, index; windowField.(results[index * 2], 1, 0).round(0.1) })));
    check.(steps.every({ arg value; value.abs < barDb }),
        "reverb: the level steps by under 1 dB at the freeze, against its twin (%)".format(steps.collect(_.round(0.01))));
    check.(levels.every({ arg value; value.abs < barDb }) and: { silent.every({ arg value; value < -60 }) },
        "reverb: frozen for 60 s, the level holds within 1 dB (%; the unfrozen twins, their input stopped, % dB)".format(
            levels.collect(_.round(0.01)), silent.collect(_.round(1))));
    check.(bands.every({ arg value; value.abs < barDb }),
        "reverb: frozen for 60 s, the band above 6 kHz holds within 1 dB (%)".format(bands.collect(_.round(0.01))));
};

// The rest of the freeze's behavior (design, section 5), in one batch of
// nine nodes on steady pink noise (size 0.8, damp 0.5 unless said): the
// input closed (frozen at 0.5 s, noise from 1 s, against an unfrozen
// twin), a release with the input stopped (frozen at 1.5 s, the noise
// stopping at 2 s, released at 4 s), a release with it running (frozen at
// 2 s, released at 5 s, against a twin, from which it differs while
// frozen), a size change while frozen (0.5 to 1 at 3 s, frozen at 2 s),
// damp while frozen (frozen at 2 s, the noise stopping at 2.5 s, damp 0 to
// 1 at 3 s and back at 5 s) and the freeze toggled ten times in 2 s
// (frozen every 0.2 s from 2 s to 3.8 s, released 0.1 s after each but
// the last, against a twin; the noise stopping at 5 s, the last freeze
// holds while the twin decays)
checkBehavior = {
    var controls = [\size, 0.8, \damp, 0.5], noise = [\level, 0.25], seconds = 9.05, results, values, twin;
    var cases = [
        // 0, 1: the input closed
        (def: freezeDef, controls: controls, input: noise ++ [\from, 1], seed: 3000, steps: (frozen: [[0, 1], [0.5]]),
            windows: [[2, 4]]),
        (def: freezeDef, controls: controls, inputFrom: 0, seed: 3000, windows: [[2, 4]]),
        // 2: a release with the input stopped
        (def: freezeDef, controls: controls, input: noise ++ [\to, 2], seed: 3001, steps: (frozen: [[0, 1, 0], [1.5, 4]]),
            windows: [[2.5, 3.4], [7.0, 7.9]]),
        // 3, 4: a release with the input running
        (def: freezeDef, controls: controls, input: noise, seed: 3002, steps: (frozen: [[0, 1, 0], [2, 5]]),
            windows: [[8.0, 8.9], [3.0, 3.9]], ref: 4),
        (def: freezeDef, controls: controls, inputFrom: 3, seed: 3002, windows: [[8.0, 8.9]]),
        // 5: a size change while frozen
        (def: freezeDef, controls: [\damp, 0.5], input: noise, seed: 3003,
            steps: (frozen: [[0, 1], [2]], size: [[0.5, 1], [3]]), windows: [[2.1, 3.0], [4.0, 4.9]]),
        // 6: damp while frozen
        (def: freezeDef, controls: [\size, 0.8], input: noise ++ [\to, 2.5], seed: 3004,
            steps: (frozen: [[0, 1], [2]], damp: [[0, 1, 0], [3, 5]]), windows: [[2.1, 3.0], [3.5, 4.4], [5.5, 6.4]]),
        // 7, 8: toggled ten times in 2 s
        (def: freezeDef, controls: controls, input: noise ++ [\to, 5], seed: 3005,
            steps: (frozen: [[0] ++ ([1, 0] ! 9).flat ++ [1], (0 .. 18).collect({ arg index; 2 + (index * 0.1) })]),
            windows: [[2, 4.9], [4.0, 4.9], [8.0, 8.9]]),
        (def: freezeDef, controls: controls, inputFrom: 7, seed: 3005, windows: [[4.0, 4.9], [8.0, 8.9]])
    ];
    results = runCases.(cases, seconds);
    check.((windowField.(results[1], 0, 0) > 1) and: { windowField.(results[0], 0, 0) < (windowField.(results[1], 0, 0) * 1e-6) },
        "reverb: the input is closed while frozen: noise sent after the freeze stays 60 dB under an unfrozen twin (% dB)".format(
            powerDb.(windowField.(results[0], 0, 0) / windowField.(results[1], 0, 0).max(1e-30)).round(0.1)));
    values = results[2];
    check.((windowField.(values, 0, 0) > 1) and: { windowField.(values, 1, 0) < (windowField.(values, 0, 0) * 1e-4) },
        "reverb: a release with the input stopped decays: 3 s after it the level is % dB of the frozen level (at most -40, size 0.8)".format(
            powerDb.(windowField.(values, 1, 0) / windowField.(values, 0, 0).max(1e-30)).round(0.1)));
    values = powerDb.(windowField.(results[3], 0, 0) / windowField.(results[4], 0, 0).max(1e-30));
    check.((windowField.(results[4], 0, 0) > 1) and: { values.abs < 1 }
        and: { windowField.(results[3], 1, 3) > (windowField.(results[3], 1, 2) * 0.1) },
        "reverb: a release with the input running returns to the twin's level: within 1 dB 3 s after it (% dB; while frozen it differed from the twin by up to %, its peak %)".format(
            values.round(0.01), windowField.(results[3], 1, 3).round(0.001), windowField.(results[3], 1, 2).round(0.001)));
    values = powerDb.(windowField.(results[5], 1, 0) / windowField.(results[5], 0, 0).max(1e-30));
    check.((windowField.(results[5], 0, 0) > 1) and: { values.abs < 0.5 },
        "reverb: a size change waits for the release: size 0.5 to 1 while frozen moves the level by under 0.5 dB (% dB)".format(values.round(0.01)));
    values = results[6];
    values = [powerDb.(windowField.(values, 1, 1) / windowField.(values, 0, 1).max(1e-30)),
        powerDb.(windowField.(values, 2, 1) / windowField.(values, 0, 1).max(1e-30))];
    check.((windowField.(results[6], 0, 1) > 0) and: { values[0] <= -1 } and: { values[1].abs < 0.5 },
        "reverb: damp shades the output: damp 0 to 1 while frozen moves the band above 6 kHz by % dB (at most -1), and back at 0 by % dB (within 0.5)".format(
            values[0].round(0.01), values[1].round(0.01)));
    twin = [powerDb.(windowField.(results[7], 1, 0) / windowField.(results[8], 0, 0).max(1e-30)),
        powerDb.(windowField.(results[7], 2, 0) / windowField.(results[7], 1, 0).max(1e-30)),
        powerDb.(windowField.(results[8], 1, 0) / windowField.(results[8], 0, 0).max(1e-30))];
    check.(results.every({ arg each; (0 .. (numWindows - 1)).every({ arg window; windowField.(each, window, 4) == 0 }) })
        and: { windowField.(results[8], 0, 0) > 1 } and: { twin[0].abs < 1 } and: { twin[1].abs < 1 } and: { twin[2] < -40 },
        "reverb: toggled ten times in 2 s: no bad value, and after the last freeze the level is within 1 dB of the twin's (% dB; held % dB once the input stops, the twin % dB)".format(
            twin[0].round(0.01), twin[1].round(0.01), twin[2].round(0.1)));
};

// The held drift glides back (fdnHeldDrift, on a 0.5 Hz sine in place of
// the noise): the sine itself while open, before the close; constant while
// closed (1 to 2.5 s); after the reopening its distance to the sine falls
// by at most fdnDriftReturnRate a second (and a little rounding) until it
// meets the sine, exactly, and it never steps by more than the sine's and
// the return's rates together a block
checkHeldDrift = {
    var seconds = 5, rate = server.sampleRate / server.options.blockSize, frames = (seconds * rate).asInteger;
    var buf = Buffer.alloc(server, frames, 2), condition = Condition(false), data, sine, held;
    var closeAt = 1, openAt = 2.5, depth = 0.0005, perBlock = engine.fdnDriftReturnRate / rate;
    var closeFrame, openFrame, before, closed, gaps, falls, met, steps, bound;
    server.sync;
    Synth(\strataCheckReverbDrift, [\buf, buf, \depth, depth, \closeAt, closeAt, \openAt, openAt], context.xg, \addAfter);
    // RecordBuf frees its node at the buffer's end (doneAction 2)
    (seconds + 0.5).wait; server.sync;
    buf.loadToFloatArray(action: { arg array; data = array; condition.test = true; condition.signal });
    awaitReply.(condition, 10);
    buf.free;
    sine = data.clump(2).collect(_[0]); held = data.clump(2).collect(_[1]);
    closeFrame = (closeAt * rate).floor.asInteger - 2; openFrame = (openAt * rate).ceil.asInteger + 2;
    before = (0 .. closeFrame).every({ arg frame; held[frame] == sine[frame] });
    closed = ((closeFrame + 4) .. (openFrame - 4)).collect({ arg frame; held[frame] });
    gaps = (openFrame .. (frames - 1)).collect({ arg frame; (held[frame] - sine[frame]).abs });
    falls = gaps.differentiate.drop(1);
    met = gaps.detectIndex({ arg gap; gap == 0 });
    steps = held.differentiate.drop(1).abs.maxItem;
    bound = (perBlock + (2pi * 0.5 * depth / rate)) * 1.01;
    check.(before and: { (closed.maxItem - closed.minItem) == 0 }
        and: { met.notNil } and: { falls.copyRange(0, (met ? 1) - 1).every({ arg fall; fall <= 0 and: { fall.abs <= (perBlock * 1.001) } }) }
        and: { gaps.copyRange(met ? 0, gaps.size - 1).every({ arg gap; gap == 0 }) } and: { steps <= bound },
        "reverb: the held drift glides back: the sine while open %, constant while closed (moves %), after the reopening its distance to the sine falls by at most fdnDriftReturnRate a second until it meets it (% s after), exactly after, and no step (largest a block %, at most %)".format(
            before, closed.maxItem - closed.minItem, met !? { arg frame; (frame / rate).round(0.001) }, steps, bound));
};

// The engine's own reverb node toggled ten times in 2 s by setReverbFreeze
// (frozen, then released 0.1 s later, nine times, then frozen a tenth),
// on a high engine (target, its fresh node node) with pink noise sent into
// its filtered reverb send: after every command the engine's context holds
// exactly one \strataReverbFDN, the engine's node keeps its node ID, and no
// NaN or inf reaches the reverb's return. Released after
checkToggledNode = { arg target, node;
    var silent = Bus.audio(server, 2), resultBus = Bus.control(server, numWindows * fields), seconds = 20;
    var input, analysis, ids = List.new, counts = List.new, values, kept;
    resultBus.setAll(0);
    server.sync;
    server.makeBundle(nil, {
        input = Synth(\strataCheckReverbInput, [\out, target.mixBus(\reverbSendPost), \rgen, 40, \seed, 5000], node, \addBefore);
        analysis = Synth(\strataCheckReverbWindows, [\in, target.reverbBus, \ref, silent, \out, resultBus, \seconds, seconds,
            \windows, [0, seconds] ++ (0 ! 14)], node, \addAfter);
    });
    1.wait;
    19.do({ arg index;
        h.commandTo(target, \setReverbFreeze, if (index.even) { 1 } { 0 });
        server.sync;
        ids.add(target.synths[\reverb] !? { arg synth; synth.nodeID });
        counts.add(h.synthNames(target.context.xg).count({ arg name; name == \strataReverbFDN }));
        0.1.wait;
    });
    0.5.wait; server.sync;
    values = readBus.(resultBus);
    kept = target.areaState[\effects][\controls][\reverb][\frozen];
    h.commandTo(target, \setReverbFreeze, 0);
    input.free; analysis.free; server.sync;
    [silent, resultBus].do(_.free);
    check.((ids.size == 19) and: { ids.every({ arg id; id == node.nodeID }) } and: { counts.every({ arg count; count == 1 }) }
        and: { kept == 1 } and: { windowField.(values, 0, 2) > 0.01 } and: { windowField.(values, 0, 4) == 0 },
        "reverb: setReverbFreeze toggled ten times in 2 s keeps one reverb node, the engine's own, with no bad value (node IDs %, the node %; \\strataReverbFDN nodes after each command %; kept %; peak %, bad %)".format(
            ids.asSet.asArray, node.nodeID, counts.asSet.asArray, kept, windowField.(values, 0, 2).round(0.001),
            windowField.(values, 0, 4)));
};

// The command and the bypass (design, sections 1 and 3), on the main
// (standard) engine and a high one of its own: setReverbFreeze sets and
// keeps the high node's frozen and ignores another value with one line;
// the standard tier keeps 0 and sets nothing; frozen is kept through a
// bypass's fade and a lift inside it, and a freed reverb is never frozen
// (the free keeps 0, a freeze with no node keeps 0, the lifted node is
// unfrozen); the free zeroes the sixteen lines, whose bufnums a bypass and
// a lift keep; a fresh high engine's reverb is unfrozen
checkCommands = {
    var high, node, kept, set, released, lines, ignored, standard, standardMessages, lifted, again, freed, bufnums;
    var lineFrames, peaks, fresh, firstLineBuf;
    // the standard tier
    standardMessages = h.wireUnits({ command.(\setReverbFreeze, 1) }).flatten;
    server.sync;
    standard = [engine.areaState[\effects][\controls][\reverb][\frozen], getControl.(engine.synths[\reverb], \frozen),
        engine.areaState[\effects][\reverbLines], engine.reverbLineBuf];
    command.(\setReverbFreeze, 0);
    check.((standard == [0, 0, nil, 0]) and: { standardMessages.isEmpty },
        "reverb: on the standard tier setReverbFreeze keeps 0 and sets nothing (kept, the node's, lines, lineBuf %; messages %)".format(
            standard, standardMessages));
    // a high engine
    high = startHigh.value;
    server.sync;
    contextChannels = (high.context.in_b ++ [high.context.out_b]).sum({ arg bus; bus.numChannels });
    kept = { high.areaState[\effects][\controls][\reverb][\frozen] };
    node = high.synths[\reverb];
    lines = high.areaState[\effects][\reverbLines];
    bufnums = lines !? { lines.collect(_.bufnum) };
    lineFrames = lines !? { lines.collect(_.numFrames) };
    fresh = [node !? { getControl.(node, \frozen) }, kept.value];
    firstLineBuf = node !? { getControl.(node, \lineBuf) };
    check.(fresh == [0, 0], "reverb: a fresh high engine's reverb has frozen 0 (the node's and kept %)".format(fresh));
    checkToggledNode.(high, node);
    h.commandTo(high, \setReverbFreeze, 1);
    server.sync;
    set = [getControl.(node, \frozen), kept.value];
    h.commandTo(high, \setReverbFreeze, 0);
    server.sync;
    released = [getControl.(node, \frozen), kept.value];
    ignored = List.new;
    withIgnoredLines.(high, ignored, { [2, -1, 0.5].do({ arg value; h.commandTo(high, \setReverbFreeze, value) }) });
    server.sync;
    check.((set == [1, 1]) and: { released == [0, 0] } and: { ignored.size == 3 }
        and: { [getControl.(node, \frozen), kept.value] == [0, 0] },
        "reverb: setReverbFreeze sets the high node's frozen and keeps it; 2, -1 and a float are ignored with one line (1: %, 0: %, lines %)".format(
            set, released, ignored.asArray));
    // kept through a bypass's fade and a lift inside it: the same node
    h.commandTo(high, \setReverbFreeze, 1);
    h.commandTo(high, \setBypass, 1, 1);
    h.commandTo(high, \setBypass, 1, 0);
    server.sync;
    lifted = [high.synths[\reverb] === node, high.synths[\reverb] !? { arg synth; getControl.(synth, \frozen) }, kept.value];
    check.(lifted == [true, 1, 1],
        "reverb: frozen is kept through a bypass's fade and a lift inside it (same node, the node's and kept %)".format(lifted));
    // freed: the bypass's free keeps 0 and zeroes the lines (filled with 1
    // in its fade, so a free that zeroes nothing leaves them at 1), a
    // freeze with no node keeps 0, the lifted node is unfrozen
    h.commandTo(high, \setBypass, 1, 1);
    (lines ? []).do({ arg buffer; server.listSendMsg(buffer.fillMsg(0, buffer.numFrames, 1)) });
    // past the fade (bypassFadeTime, 51 ms): freed
    0.2.wait; server.sync;
    again = [kept.value, high.synths[\reverb].isNil];
    h.commandTo(high, \setReverbFreeze, 1);
    server.sync;
    again = again ++ [kept.value];
    peaks = (lines ? []).collect({ arg buffer;
        var condition = Condition(false), peak;
        buffer.loadToFloatArray(action: { arg array; peak = array.abs.maxItem; condition.test = true; condition.signal });
        awaitReply.(condition, 10);
        peak
    });
    h.commandTo(high, \setBypass, 1, 0);
    server.sync;
    again = again ++ [high.synths[\reverb] !? { arg synth; getControl.(synth, \frozen) }, kept.value];
    freed = [high.areaState[\effects][\reverbLines] !? { arg each; each.collect(_.bufnum) },
        high.synths[\reverb] !? { arg synth; getControl.(synth, \lineBuf) }];
    check.(again == [0, true, 0, 0, 0],
        "reverb: a freed reverb is never frozen (kept once freed, no node, kept after a freeze with no node, the lifted node's and kept: %)".format(
            again));
    check.((peaks.size == 16) and: { peaks.every({ arg peak; peak == 0 }) },
        "reverb: a bypass's free zeroes the sixteen lines (their largest samples after the free %)".format(peaks));
    check.(bufnums.notNil and: { lineFrames == engine.fdnLineFrames.collect({ arg frames; [frames, frames] }).flatten }
        and: { bufnums == (bufnums[0] .. (bufnums[0] + 15)) } and: { freed == [bufnums, bufnums[0]] }
        and: { firstLineBuf == bufnums[0] },
        "reverb: the lines are sixteen buffers of fdnLineFrames whose bufnums a bypass and a lift keep (frames %, bufnums %, the first node's lineBuf %, after the lift %)".format(
            lineFrames, bufnums, firstLineBuf, freed));
    h.freeEngine(high);
    server.sync;
};

guarded.("the graph", checkGraph);
guarded.("unfrozen as before", checkAsBefore);
guarded.("the hold", checkHold);
guarded.("the freeze's behavior", checkBehavior);
guarded.("the held drift", checkHeldDrift);
guarded.("the command and the bypass", checkCommands);

// the engine as the area found it: unfrozen
try { command.(\setReverbFreeze, 0) } { };
server.sync;

check.(audioChannelsHeld.value == (audioChannelsAtStart + contextChannels),
    "reverb: the area leaves no audio bus allocated but the high engine's context (#807; % channels held at its start, % at its end, % the context's)".format(
        audioChannelsAtStart, audioChannelsHeld.value, contextChannels));
}
