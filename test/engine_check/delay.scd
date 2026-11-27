// test/engine_check/delay.scd
// The delay's freeze and clear (3.8 design §7.2, §7.3; package 1b), on
// \strataDelay (lib/engine/StrataDelay.sc): a frozen loop keeps its level
// and its treble at a fractional time (the time rounded to whole samples),
// a snapped ping-pong keeps its width, the input is closed, a time change
// waits for the release, a release decays at the kept feedback; a clear
// mutes the return and empties the line, frozen or not. Then the commands:
// setDelayFreeze sets and keeps frozen (through a bypass's fade, dropped at
// its free: a lift starts unfrozen at its kept time, #889),
// ignores another value with one line, clearDelay sets the trigger and
// nothing while bypassed, and a fresh engine starts unfrozen. The signal
// checks run on nodes of the engine's own \strataDelay on buses and lines of
// their own (startCheckDelay, the one place a check starts one), driven by
// step synths on control buses and measured on the server in windows of
// server time, so a busy machine changes nothing.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var readBus = { arg bus; h.readBus(bus) };
// a power ratio and an amplitude ratio in dB, for the messages
var powerDb = { arg ratio; (ratio.max(1e-30).log10 * 10).round(0.01) };
var ampDb = { arg ratio; ratio.max(1e-15).ampdb.round(0.1) };
// the windows an analysis measures, and the values it gives each
var numWindows = 8, fields = 7, windowField;
var startCheckDelay, allocLine, runCases, guarded, withIgnoredLines;
// BufDelayC at the rounded time, plus LocalIn's one feedback block
var heldPeriod = { arg time; ((time * server.sampleRate).round + server.options.blockSize) / server.sampleRate };
var checkHeldLoop, checkLoopBehavior, checkClearEdge, checkFreezeCommand, checkLiftAfterFreedFreeze, checkIgnoredValues;
var checkClearCommand, checkFreshEngine, checkClearHistory;
var times = [0.375, 0.30928];
// the audio channels the server's allocator holds (#807: the area gives
// back every bus it allocates), how many it held as the area began, and
// the fresh engine's context's (checkFreshEngine: its inputs and its
// silent output, which the harness frees only at the run's end)
var audioChannelsHeld = { server.audioBusAllocator.blocks.sum({ arg block; block.size }) };
var audioChannelsAtStart = audioChannelsHeld.value, contextChannels = 0;
// a clear's largest sample step against the steady signal's (checkClearEdge)
var clearStepBound = 1.0;

// A control bus's value over time from the synth's start: first, second
// from at (s), third from endAt, optionally back to second from againAt
SynthDef(\strataCheckDelayStep, { arg out, first = 0, second = 1, third = 0, at = 1e9, endAt = 1e9, againAt = 1e9;
    var elapsed = Sweep.kr(0, 1);
    Out.kr(out, Select.kr((elapsed >= at) + (elapsed >= endAt) + (elapsed >= againAt), [first, second, third, second]));
}).add;
// A stereo input: pink noise at noise (independent channels) until noiseTo,
// a sine of freq at sine on both channels from sineFrom to sineTo (s from its start)
SynthDef(\strataCheckDelayInput, { arg out, noise = 0, noiseTo = 1e9, sine = 0, freq = 1000, sineFrom = 1e9, sineTo = 1e9, sineAgain = 1e9, phase = 0;
    var elapsed = Sweep.ar(0, 1);
    var noises = ({ PinkNoise.ar(noise) } ! 2) * (elapsed < noiseTo);
    var sounding = ((elapsed >= sineFrom) * (elapsed < sineTo)).max(elapsed >= sineAgain);
    Out.ar(out, noises + ((SinOsc.ar(freq, phase, sine) ! 2) * sounding));
}).add;
// A stereo bus in eight windows of time from the synth's start ([start,
// end] s each): per window, the sum of its squared samples (both channels),
// the same of its 6-24 kHz band (two second-order highpasses at 6 kHz), of
// its side ((L - R) / 2) and its mid ((L + R) / 2), its largest absolute
// sample, the largest absolute difference from ref (summed over both
// channels) and its largest step from one sample to the next (either
// channel); seven values a window on out. It frees itself at seconds
SynthDef(\strataCheckDelayWindows, { arg in, ref, out, seconds = 1, windows = #[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    var sig = In.ar(in, 2), other = In.ar(ref, 2), elapsed = Sweep.ar(0, 1);
    var band = HPF.ar(HPF.ar(sig, 6000), 6000);
    var mid = (sig[0] + sig[1]) * 0.5, side = (sig[0] - sig[1]) * 0.5;
    var largest = sig[0].abs.max(sig[1].abs), difference = (sig - other).abs.sum;
    var steps = (sig - Delay1.ar(sig)).abs, step = steps[0].max(steps[1]);
    Out.kr(out, 8.collect({ arg index;
        var inside = (elapsed >= windows[index * 2]) * (elapsed < windows[(index * 2) + 1]);
        A2K.kr([Integrator.ar(sig.squared.sum * inside, 1), Integrator.ar(band.squared.sum * inside, 1),
            Integrator.ar(side.squared * inside, 1), Integrator.ar(mid.squared * inside, 1),
            RunningMax.ar(largest * inside), RunningMax.ar(difference * inside), RunningMax.ar(step * inside)])
    }).flat);
    Line.kr(0, 0, seconds, doneAction: 2);
}).add;

// A delay line of the engine's size for a check's own node: two fresh mono
// buffers (a node on the engine's own would write into its running line),
// then two shimmer rings (3.8: shiftL, shiftR; a ring left out is buffer 0)
allocLine = { 2.collect({ Buffer.alloc(server, engine.delayLineFrames, 1) })
    ++ 2.collect({ Buffer.alloc(server, engine.shimmerRingFrames, 1) }) };

// The one place this area starts a \strataDelay: on its own buses and line,
// at level 1 unless controls say otherwise
startCheckDelay = { arg inBus, outBus, line, controls, target, addAction = \addToTail;
    Synth(\strataDelay, [\in, inBus, \out, outBus, \bufL, line[0], \bufR, line[1], \shiftL, line[2], \shiftR, line[3],
        \mix, 1] ++ controls, target, addAction)
};

// A window's field of a case's values (fields: 0 energy, 1 band energy, 2
// side energy, 3 mid energy, 4 peak, 5 largest difference from ref, 6
// largest step from one sample to the next)
windowField = { arg values, window, field; values !? { values[(window * fields) + field] } ? 0 };

// Run cases at once, in one group created in one bundle, for seconds of
// server time: each case an Event of delay (the node's controls), input
// (\strataCheckDelayInput's controls) or inputFrom (an earlier case's
// index, whose input it shares), steps (control -> [first, second, third,
// at, endAt, optional againAt]: a \strataCheckDelayStep mapped to the node's control), ref
// (an earlier case's index, whose return the difference is taken from) and
// windows (up to eight [start, end] pairs). The values of each case, as
// windowField reads them
runCases = { arg cases, seconds;
    var group = Group.after(context.xg), silent = Bus.audio(server, 2), condition = Condition(false), ended = 0;
    // (an inputFrom case shares its input's bus and allocates none: #807)
    var made = cases.collect({ arg case; (inBus: if (case[\inputFrom].isNil) { Bus.audio(server, 2) },
        outBus: Bus.audio(server, 2), line: allocLine.value,
        resultBus: Bus.control(server, numWindows * fields), stepBuses: List.new) });
    var results;
    made.do({ arg each; each[\resultBus].setAll(0) });
    server.sync;
    server.makeBundle(nil, {
        cases.do({ arg case, index;
            var each = made[index], node;
            if (case[\inputFrom].notNil) { each[\inBus] = made[case[\inputFrom]][\inBus] } {
                Synth(\strataCheckDelayInput, [\out, each[\inBus]] ++ (case[\input] ? []), group, \addToTail) };
            (case[\steps] ? ()).keysValuesDo({ arg control, step;
                var bus = Bus.control(server, 1);
                each[\stepBuses].add(bus);
                each[control] = bus;
                Synth(\strataCheckDelayStep, [\out, bus, \first, step[0], \second, step[1], \third, step[2],
                    \at, step[3], \endAt, step[4], \againAt, step[5] ? 1e9], group, \addToTail);
            });
            node = startCheckDelay.(each[\inBus], each[\outBus], each[\line], case[\delay] ? [], group);
            (case[\steps] ? ()).keysDo({ arg control; node.map(control, each[control]) });
        });
        cases.do({ arg case, index;
            var windows = (case[\windows] ++ ([0, 0] ! numWindows)).copyRange(0, numWindows - 1).flat;
            var analysis = Synth(\strataCheckDelayWindows, [\in, made[index][\outBus],
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
        each[\stepBuses].do(_.free);
        each[\line].do(_.free);
    });
    silent.free; server.sync;
    results
};

// A check that raises (a command the engine does not have) fails, naming it
guarded = { arg name, body;
    try { body.value } { arg error; check.(false, "delay: % raised %".format(name, error.errorString)) };
};

// Runs body with the lines the engine posts for ignored commands added to
// lines (the modulation area's postIgnored hook), put back however it ends
withIgnoredLines = { arg lines, body;
    var modulation = engine.areaState[\modulation], previous = modulation[\postIgnored];
    modulation[\postIgnored] = { arg line; lines.add(line) };
    body.protect({ modulation[\postIgnored] = previous });
};

// A held loop keeps its level (design §7.3): steady pink noise, feedback
// 0.4, at 0.375 s and the fractional 0.30928 s, ping-pong 0, 1 and 0.5,
// frozen at 1 s. In windows of about 1 s from 2 to 9 s the energy stays
// within 0.5 dB of the first window's, and so does its 6-24 kHz band (a time
// not rounded to whole samples darkens the loop at each pass: 10.7-11 dB
// lost by 9 s at 0.30928 s, the facts measured); at ping-pong 0.5, snapped
// to 1, the side stays above -20 dB of the mid (unsnapped, the two lines
// become one). Each window is a whole number of the loop's periods (the
// rounded time and the feedback's one block), so a window holds the same
// audio as the next and the noise's own spread does not count
checkHeldLoop = {
    var pingPongs = [0, 1, 0.5], cases = List.new, results;
    times.do({ arg time;
        var period = heldPeriod.(time), width = (1 / period).round.max(1) * period;
        var windows = [[0.5, 1.0]] ++ 7.collect({ arg index; [2 + (index * width), 2 + ((index + 1) * width)] })
            .select({ arg window; window[1] <= 9 });
        pingPongs.do({ arg pingPong;
            // at 0.5 the noise stops at 1.5 s (closed by then, frozen): a
            // loop that was not held would lose its width as it decays
            var input = [\noise, 0.5] ++ (if (pingPong == 0.5) { [\noiseTo, 1.5] } { [] });
            cases.add((delay: [\time, time, \feedback, 0.4, \pingPong, pingPong], input: input,
                steps: (frozen: [0, 1, 1, 1, 1e9]), windows: windows, label: "% s, ping-pong %".format(time, pingPong)));
        });
    });
    results = runCases.(cases, 9.05);
    cases.do({ arg case, index;
        var values = results[index];
        var last = case[\windows].size - 1;
        var spread = { arg field; (2 .. last).collect({ arg window;
            powerDb.(windowField.(values, window, field) / windowField.(values, 1, field).max(1e-30)).abs }).maxItem };
        var widths = (1 .. last).collect({ arg window;
            powerDb.(windowField.(values, window, 2) / windowField.(values, window, 3).max(1e-30)) });
        check.((windowField.(values, 1, 0) > 100) and: { spread.(0) <= 0.5 } and: { spread.(1) <= 0.5 },
            "delay: a loop frozen at 1 s (%) keeps its level and its 6-24 kHz band within 0.5 dB from 2 to 9 s (energy in the first of % windows of % s %, largest moves % and % dB)".format(
                case[\label], last, (case[\windows][1][1] - case[\windows][1][0]).round(0.001), windowField.(values, 1, 0).round(0.1),
                spread.(0).round(0.001), spread.(1).round(0.001)));
        if (case[\delay][5] == 0.5) {
            check.(widths.every({ arg width; width > -20 }),
                "delay: frozen at ping-pong 0.5 (snapped to 1), % keeps its width: the side above -20 dB of the mid in each window from 2 to 9 s (side to mid, dB, %)".format(
                    case[\label], widths));
        };
    });
};

// The input is closed, a time change waits for the release, a release
// decays at the kept feedback, and a clear mutes and empties, in one run
// of nine nodes (time 0.375 s, feedback 0.4)
checkLoopBehavior = {
    var time = 0.375, delay = [\time, time, \feedback, 0.4], noise = [\noise, 0.5], steady, held, decay, results, values;
    var width = 2 * heldPeriod.(time), endHeld = 2.99;
    var cases = [
        // 0, 1: a 1 kHz sine from 1.5 s on, frozen at 1 s and not
        (delay: delay, input: [\sine, 0.5, \sineFrom, 1.5], steps: (frozen: [0, 1, 1, 1, 1e9]), windows: [[1.6, 4.0]]),
        (delay: delay, input: [\sine, 0.5, \sineFrom, 1.5], windows: [[1.6, 4.0]]),
        // 2, 3: frozen from 1 to 5 s on the same noise, case 2's time set to
        // 0.2 s at 2 s; case 2's difference from case 3. A window ends 10 ms
        // before a step (the release here, the clear and the release below):
        // a step synth's Sweep.kr runs a block ahead of an analysis's
        // Sweep.ar on SuperCollider 3.13 (3.14 changed when Sweep adds its
        // increment), so the release would fall inside a window ending at 5 s
        (delay: delay, input: noise, steps: (frozen: [0, 1, 0, 1, 5], time: [0.375, 0.2, 0.2, 2, 1e9]), ref: 3,
            windows: [[1.5, 4.99], [5.6, 7.0]]),
        (delay: delay, inputFrom: 2, steps: (frozen: [0, 1, 0, 1, 5]), windows: [[1.5, 4.99]]),
        // 4: noise until 2 s, frozen from 1 to 3 s. The two hold windows each hear
        // two whole periods. The last two windows measure the decay as before.
        (delay: delay, input: noise ++ [\noiseTo, 2], steps: (frozen: [0, 1, 0, 1, 3]),
            windows: [[endHeld - (2 * width), endHeld - width], [endHeld - width, endHeld], [2.0, endHeld], [5.0, 5.5]]),
        // 5: steady noise, cleared at 2 s
        (delay: delay, input: noise, steps: (t_clear: [0, 1, 1, 2, 1e9]),
            windows: [[1.0, 1.99], [2.01, 2.375], [2.395, 2.7]]),
        // 6: noise until 1.5 s, cleared at 2 s
        (delay: delay, input: noise ++ [\noiseTo, 1.5], steps: (t_clear: [0, 1, 1, 2, 1e9]),
            windows: [[1.0, 1.5], [2.385, 4.0]]),
        // 7: steady noise, frozen at 1 s, cleared at 2 s
        (delay: delay, input: noise, steps: (frozen: [0, 1, 1, 1, 1e9], t_clear: [0, 1, 1, 2, 1e9]),
            windows: [[1.5, 2.0], [2.385, 4.0]])
    ];
    results = runCases.(cases, 7.05);
    check.((windowField.(results[1], 0, 4) > 0.1) and: { windowField.(results[0], 0, 4) < (windowField.(results[1], 0, 4) * 0.001) },
        "delay: the input is closed while frozen: a 1 kHz sine started after the freeze stays under -60 dB of its level unfrozen in the return (% dB; unfrozen peak %)".format(
            ampDb.(windowField.(results[0], 0, 4) / windowField.(results[1], 0, 4).max(1e-15)), windowField.(results[1], 0, 4).round(0.001)));
    check.((windowField.(results[2], 0, 4) > 0.1) and: { windowField.(results[2], 0, 5) <= 1e-6 }
        and: { windowField.(results[2], 1, 5) > 0.01 },
        "delay: a time change waits for the release: setDelay's 0.2 s while frozen changes nothing until the release (largest difference from a node left at 0.375 s, frozen %, after the release %)".format(
            windowField.(results[2], 0, 5), windowField.(results[2], 1, 5).round(0.001)));
    values = results[4];
    held = 10 * (windowField.(values, 1, 0) / windowField.(values, 0, 0).max(1e-30)).max(1e-30).log10;
    decay = (windowField.(values, 3, 0) / 0.5) / (windowField.(values, 2, 0) / (endHeld - 2)).max(1e-30);
    check.((windowField.(values, 0, 0) > 100) and: { held.abs <= 0.05 } and: { decay < 1e-4 },
        "delay: a release decays at the kept feedback 0.4: held within 0.05 dB over two pairs of whole periods before release (% dB), under -40 dB 2 s after it (% dB of the frozen level)".format(
            held.round(0.00001), powerDb.(decay)));
    values = results[5];
    steady = windowField.(values, 0, 4);
    check.((steady > 0.1) and: { windowField.(values, 1, 4) < (steady * 0.001) } and: { windowField.(values, 2, 4) > (steady * 0.1) },
        "delay: a clear mutes the return from 10 ms after it to one delay time (% dB of the steady peak) and the input it takes comes back one delay time later (% dB)".format(
            ampDb.(windowField.(values, 1, 4) / steady.max(1e-15)), ampDb.(windowField.(values, 2, 4) / steady.max(1e-15))));
    values = results[6];
    steady = windowField.(values, 0, 4);
    check.((steady > 0.1) and: { windowField.(values, 1, 4) < (steady * 1e-6) },
        "delay: with the input stopped, a clear empties the line: under -120 dB after its window (% dB of the peak before)".format(
            ampDb.(windowField.(values, 1, 4) / steady.max(1e-15))));
    values = results[7];
    steady = windowField.(values, 0, 4);
    check.((steady > 0.1) and: { windowField.(values, 1, 4) < (steady * 1e-6) },
        "delay: frozen and cleared, the loop is empty: under -120 dB after the clear's window (% dB of the frozen peak)".format(
            ampDb.(windowField.(values, 1, 4) / steady.max(1e-15))));
};

// An input pulse and every control change use the server clock. Compare
// paired nodes driven by the same audio, and require an audible reference.
checkClearHistory = {
    var pulse = [\sine, 0.1, \freq, 330, \sineFrom, 0.75, \sineTo, 0.85, \sineAgain, 1.25];
    var short = [\time, 0.04, \feedback, 0], long = [\time, 0.4, \feedback, 0];
    var shimmering = [\time, 0.04, \feedback, 0.9, \shimmer, 1];
    var before = [\sine, 0.1, \sineFrom, 0.15, \sineTo, 0.45];
    var repeatWindows = [[1.1, 1.35], [1.68, 1.75]], ringWindows = [[0.3, 0.43], [0.53, 1.5]];
    var atEnd = [0, 1, 1, 0.48, 1e9];
    var results = runCases.([
        // Both clears precede the echo. Only the first precedes the input.
        (input: pulse, delay: long, steps: (t_clear: [0, 1, 0, 0.65, 0.7]), windows: repeatWindows),
        (inputFrom: 0, delay: long, steps: (t_clear: [0, 1, 0, 0.65, 0.7, 0.9]), windows: repeatWindows),
        // The pitch shifter's heads can read further back than this delay time.
        (input: before, delay: shimmering,
            steps: (t_clear: atEnd), windows: ringWindows),
        // Move the tap into the old tone after the original clear window.
        (inputFrom: 2, delay: short, steps: (t_clear: atEnd, time: [0.04, 0.6, 0.6, 0.75, 1e9]),
            windows: [[0.25, 0.43], [0.7, 1.25]]),
        // Sweep across discarded audio in a single control block, then back.
        (input: [\sine, 0.1, \sineFrom, 0.15, \sineTo, 0.479], delay: short,
            steps: (t_clear: atEnd, time: [0.04, 5.4, 0.01, 0.75, 0.9]), windows: [[0.25, 0.43], [0.55, 1.4]]),
        // Clearing before the input should give the same shimmer tail as an
        // uncleared node. The window contains only feedback from that input.
        (inputFrom: 0, delay: shimmering, windows: [[0.92, 1.2]]),
        (inputFrom: 0, delay: shimmering, steps: (t_clear: [0, 1, 1, 0.01, 1e9]), ref: 5, windows: [[0.92, 1.2]]),
        // A moving tap changes the sine's natural slope. Compare its largest
        // sample step with the very same sweep played without a clear.
        (input: [\sine, 0.1, \sineFrom, 0.1, \freq, 20, \phase, pi/2], delay: short,
            steps: (time: [0.04, 0.6, 0.6, 0.75, 1e9]), windows: [[0.74, 0.95]]),
        (inputFrom: 7, delay: short, steps: (t_clear: atEnd, time: [0.04, 0.6, 0.6, 0.75, 1e9]),
            windows: [[0.74, 0.95]])
    ], 1.8);
    var peak = { arg i, w = 0; windowField.(results[i], w, 4) };
    var sweepStep = windowField.(results[7], 0, 6), closedStep = windowField.(results[8], 0, 6);
    check.((peak.(0) > 0.09) and: { peak.(1) < 1e-6 } and: { peak.(1, 1) > 0.09 },
        "delay: a second Clear discards the first refill and passes new input (one press %, both %, new tone %)".format(
            peak.(0), peak.(1), peak.(1, 1)));
    check.((peak.(2) > 0.05) and: { peak.(2, 1) < 1e-6 },
        "delay: a short cleared line cannot retrieve old shimmer (before %, after %)".format(peak.(2), peak.(2, 1)));
    check.((peak.(3) > 0.09) and: { peak.(3, 1) < 1e-6 },
        "delay: lengthening the tap after Clear cannot retrieve the discarded tone (before %, after %)".format(peak.(3), peak.(3, 1)));
    check.((peak.(4) > 0.09) and: { peak.(4, 1) < 1e-6 },
        "delay: a full-range time sweep cannot cross back into discarded audio for part of a block (peak %)".format(peak.(4, 1)));
    check.((peak.(5) > 0.02) and: { peak.(6) > 0.02 } and: { windowField.(results[6], 0, 5) < 1e-6 },
        "delay: a Clear at startup preserves the shimmer tail of new input (peak %, difference %)".format(
            peak.(5), windowField.(results[6], 0, 5)));
    check.((peak.(8) > 0.09) and: { sweepStep > 0 } and: { closedStep <= (sweepStep + 1e-5) },
        "delay: a moving tap fades when it reaches cleared history (largest step %, uncleared sweep %)".format(
            closedStep, sweepStep));
};

// A clear ends without a step (#308's kind of click): a steady sine at 0.5,
// feedback 0.4, time 0.375 s, cleared at 2 s. Across the window's end
// (about 2.38 s, where the return opens again) and one delay time after it
// (where what the reopened feedback wrote comes back), the return's largest
// step from one sample to the next stays within clearStepBound (1) of its
// largest in steady state. The sine is low (about 29 Hz: a smooth signal
// whose own steps are small, so a gain that steps up in a control block
// shows) and a whole number of cycles a loop period (eleven), so the loop's
// repeats add in phase: the steady return is the largest the loop ever
// plays, and the refill after the clear, a part of that sum, is never
// louder. (At about 100 Hz the repeats partly cancel, and the input alone
// after a clear has larger steps than the steady return, a step or not.)
checkClearEdge = {
    var rate = server.sampleRate, block = server.options.blockSize, time = 0.375;
    var freq = 11 * rate / ((time * rate).round + block);
    var results = runCases.([(delay: [\time, time, \feedback, 0.4], input: [\sine, 0.5, \freq, freq, \sineFrom, 0],
        steps: (t_clear: [0, 1, 1, 2, 1e9]), windows: [[1.0, 1.99], [2.3, 2.85], [2.3, 2.5], [2.5, 2.85]])], 3.05);
    var values = results[0], steady = windowField.(values, 0, 6), edge = windowField.(values, 1, 6);
    check.((steady > 0.001) and: { edge <= (steady * clearStepBound) },
        "delay: a clear ends without a step: the return's largest sample step across its window's end and one delay time after is within % of its steady largest at % Hz (% against %: the window's end %, the feedback's return %)".format(
            clearStepBound, freq.round(0.01), edge.round(0.00001), steady.round(0.00001), windowField.(values, 2, 6).round(0.00001),
            windowField.(values, 3, 6).round(0.00001)));
};

// setDelayFreeze sets the node's frozen and keeps it; it is kept through a
// bypass's fade (a lift inside it keeps the node, frozen, with its loop)
// and dropped once the bypass frees the node (#889: the lifted node starts
// unfrozen), and a release while freed keeps 0
checkFreezeCommand = {
    var controls = { engine.areaState[\effects][\controls][\delay] };
    var node = engine.synths[\delay], set, released, lifted, again;
    command.(\setDelayFreeze, 1);
    server.sync;
    set = [getControl.(node, \frozen), controls.value[\frozen]];
    command.(\setDelayFreeze, 0);
    server.sync;
    released = [getControl.(node, \frozen), controls.value[\frozen]];
    check.((set == [1, 1]) and: { released == [0, 0] },
        "delay: setDelayFreeze sets the node's frozen and keeps it (1: node, kept %; 0: %)".format(set, released));
    command.(\setDelayFreeze, 1);
    // bypassed and lifted in one tick: inside the fade, the same node
    command.(\setBypass, 0, 1);
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = [engine.synths[\delay] === node, engine.synths[\delay] !? { arg synth; getControl.(synth, \frozen) }, controls.value[\frozen]];
    command.(\setBypass, 0, 1);
    // past the fade (bypassFadeTime, 51 ms): freed
    0.1.wait; server.sync;
    again = [controls.value[\frozen], engine.synths[\delay].isNil];
    command.(\setDelayFreeze, 0);
    server.sync;
    again = again ++ [controls.value[\frozen]];
    command.(\setBypass, 0, 0);
    server.sync;
    again = again ++ [engine.synths[\delay] !? { arg synth; getControl.(synth, \frozen) }];
    check.((lifted == [true, 1, 1]) and: { again == [0, true, 0, 0] },
        "delay: frozen is kept through a bypass's fade and a lift inside it (same node, the node's and kept %), and dropped once the bypass frees the node (kept, no node, kept after a release, lifted: %)".format(
            lifted, again));
};

// #889: a bypass that frees the delay drops its kept frozen (its line is
// emptied: no loop is left to hold), and a freeze sent while it is freed
// is not kept, so a lift starts the delay unfrozen at its kept time,
// whichever way the freeze came: the lifted node's frozen 0 (and the kept
// value), and a 1 kHz tone sent into it at the lift silent in its return
// until the delay time (0.1 s) and back after it (windows from the tone's
// start, measured on the server)
checkLiftAfterFreedFreeze = {
    var time = 0.1, results = List.new;
    command.(\setDelay, time, 0.4, 1.0, 0);
    [\beforeBypass, \whileFreed].do({ arg when;
        var resultBus = Bus.control(server, numWindows * fields), silent = Bus.audio(server, 2);
        var node, freedKept, kept, frozen, values, tone;
        resultBus.setAll(0);
        if (when == \beforeBypass) { command.(\setDelayFreeze, 1) };
        command.(\setBypass, 0, 1);
        // past the fade (bypassFadeTime, 51 ms): freed
        0.1.wait; server.sync;
        if (when == \whileFreed) { command.(\setDelayFreeze, 1) };
        freedKept = engine.areaState[\effects][\controls][\delay][\frozen];
        command.(\setBypass, 0, 0);
        server.sync;
        node = engine.synths[\delay];
        frozen = getControl.(node, \frozen);
        kept = engine.areaState[\effects][\controls][\delay][\frozen];
        server.makeBundle(nil, {
            tone = Synth(\strataCheckDelayInput, [\out, engine.mixBus(\delaySendPost), \sine, 0.5, \sineFrom, 0], node, \addBefore);
            Synth(\strataCheckDelayWindows, [\in, engine.delayBus, \ref, silent, \out, resultBus, \seconds, 0.3,
                \windows, [0.02, time - 0.03, time + 0.05, 0.28] ++ (0 ! 12)], node, \addAfter);
        });
        0.35.wait; server.sync;
        values = readBus.(resultBus);
        tone.free; server.sync;
        [resultBus, silent].do(_.free);
        results.add([when, freedKept, kept, frozen, windowField.(values, 0, 4).round(0.0001), windowField.(values, 1, 4).round(0.0001)]);
    });
    command.(\setDelayFreeze, 0);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    server.sync;
    check.(results.every({ arg each; (each[1] == 0) and: { each[2] == 0 } and: { each[3] == 0 }
            and: { each[4] < 0.001 } and: { each[5] > 0.1 } }),
        "delay: a bypass lifted with frozen kept starts the delay unfrozen at its kept time (when the freeze came, kept once freed, kept and the node's frozen after the lift, the return's peak before and after % s: %)".format(
            time, results));
};

// Another value than 0 or 1 is ignored with one line, the node and the
// kept value left as they are
checkIgnoredValues = {
    var lines = List.new, node = engine.synths[\delay], after;
    withIgnoredLines.(lines, { [2, -1].do({ arg value; command.(\setDelayFreeze, value) }) });
    server.sync;
    after = [getControl.(node, \frozen), engine.areaState[\effects][\controls][\delay][\frozen]];
    check.((lines.size == 2) and: { after == [0, 0] },
        "delay: setDelayFreeze of 2 or -1 is ignored with one line each (lines %, node and kept %)".format(lines.asArray, after));
};

// clearDelay sets the running node's t_clear and keeps nothing; while the
// delay is bypassed, in its fade and after its free, it sends nothing
checkClearCommand = {
    var capture = { var messages = server.makeBundle(false, { command.(\clearDelay) }); server.sendBundle(nil, *messages); messages };
    var node = engine.synths[\delay], running, fading, freed;
    running = capture.value;
    command.(\setBypass, 0, 1);
    fading = capture.value;
    0.2.wait; server.sync;
    freed = capture.value;
    command.(\setBypass, 0, 0);
    server.sync;
    check.(running.any({ arg msg; (msg[0] == 15) and: { msg[1] == node.nodeID } and: { msg.indexOf(\t_clear).notNil }
            and: { msg[msg.indexOf(\t_clear) + 1] == 1 } })
        and: { fading.isEmpty } and: { freed.isEmpty } and: { engine.areaState[\effects][\controls][\delay][\t_clear].isNil },
        "delay: clearDelay sets the running delay's t_clear, keeps nothing, and sends nothing while bypassed (running %, in the fade %, after the free %)".format(
            running, fading, freed));
};

// A fresh engine's delay is unfrozen, the node and the kept value
checkFreshEngine = {
    var fresh = h.startEngine(()), values;
    server.sync;
    contextChannels = (fresh.context.in_b ++ [fresh.context.out_b]).sum({ arg bus; bus.numChannels });
    values = [fresh.synths[\delay] !? { arg synth; getControl.(synth, \frozen) },
        fresh.areaState[\effects][\controls][\delay][\frozen]];
    h.freeEngine(fresh);
    h.teardownSync("free fresh engine");
    check.(values == [0, 0], "delay: a fresh engine's delay starts unfrozen, the node and the kept value (%)".format(values));
};

guarded.("the held loop", checkHeldLoop);
guarded.("the loop's behavior", checkLoopBehavior);
guarded.("the clear's edge", checkClearEdge);
guarded.("cleared line and pitch-shifter history", checkClearHistory);
guarded.("setDelayFreeze", checkFreezeCommand);
guarded.("a lift after a freed freeze", checkLiftAfterFreedFreeze);
guarded.("setDelayFreeze's ignored values", checkIgnoredValues);
guarded.("clearDelay", checkClearCommand);
guarded.("a fresh engine", checkFreshEngine);

// the engine as the area found it: unfrozen, at the defaults, nothing bypassed
try { command.(\setDelayFreeze, 0) } { };
command.(\setBypass, 0, 0);
command.(\setDelay, 0.375, 0.4, 0.0, 0);
server.sync;
check.(audioChannelsHeld.value == (audioChannelsAtStart + contextChannels),
    "delay: the area leaves no audio bus allocated but the fresh engine's context (#807; % channels held at its start, % at its end, % the context's)".format(
        audioChannelsAtStart, audioChannelsHeld.value, contextChannels));
}
