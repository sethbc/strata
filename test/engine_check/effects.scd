// test/engine_check/effects.scd
// The mix and the effects chain: the master limiter before the saturator,
// the bus routing (three master filters, the delay and reverb returns, the
// master sum), the defaults a fresh engine starts with (the Lua params'),
// setFilter on all three filters, setDelay, the filter types (each passes
// and stops what its name says), their crossfades (master and voice), a
// cutoff step up that throws no spike and the filter as 3.0's wherever the
// cutoff does not rise fast, the NaN guards, plain messages to the effects
// chain's synths, the plain sends (3.8: a stage's dry level and sends, the
// returns as levels, the delay into the reverb, masterSum at 0.7 of the
// three buses, a default start as 3.7's law), the master's drift shifter
// leaving a steady tone steady, the explicit bypass
// (it frees and re-creates a node, a level of 0 never does; a lifted delay's
// first echo and a lifted reverb's tail start without a step; the free lands
// after the fade when the command's handler runs late), and the high tier's
// FDN reverb against FreeVerb2.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var readBus = { arg bus; h.readBus(bus) };
var measure = { arg probe, bus, seconds = 0.3; h.measure(probe, bus, seconds) };
var mixBus = { arg name; engine.mixBus(name) };
var db = { arg ratio; ratio.max(1e-9).ampdb.round(0.1) };
var masterUGens, readStep;
var checkFilterCrossfade, checkEffectsGuard, checkEffectSendsReported, checkRouting, checkPlainChain, checkPlainSends;
var checkDefaultBalance, checkEchoesWithoutReverb;
var checkBypassFrees, checkBypassToggling, checkMixThroughZero, checkSetWhileBypassed;
var allocLine, freeLine, lineMax, checkDelayLine, checkLiftStartsEmpty, checkLineAsDelayC;
var checkReverbBypass, checkFdn, chainTail, delayNodes, floodFit, smallProbeKB, probeKB;
var checkFreshDefaults, checkFilterTypes, checkCutoffStep, checkFilterAsBefore, checkMasterSteady, checkLiftStartsSmoothly;
var checkBypassFreeTiming, echoPeaks, checkPingPong, checkPingPongKept, checkLongDelay;
var sentBy, setsControl, setsNoBus;
var floodCount = 640;

// The defs in xg, in node order, from the filter on (the chain at its
// tail; the record area's tap group, which follows the master, left out)
chainTail = {
    var names = h.synthNames(context.xg).reject({ arg name; [\strataTapPreMaster, \strataRecord].includes(name) });
    names.copyRange(names.indexOf(\strataFilter) ? names.size, names.size - 1).asArray
};
// How many delay nodes the engine group holds
delayNodes = { h.synthNames(context.xg).count({ arg name; name == \strataDelay }) };

// The pool's free memory, as memory.scd measures it: a flood of small
// graph probes (about 16 KB of controls each) in one bundle with /error -1;
// the number created is the free memory to within one probe. A probe's size
// is calibrated against four 256 KB DelayN probes (smallProbeKB). Two 256
// KB DelayN probes are allocated before each flood and freed right after it
// (in its bundle), so the replies that read it find room.
SynthDef(\strataCheckEffectsPoolProbe, { arg out;
    var padding = NamedControl.kr(\padding, 0 ! 240);
    Out.kr(out, DC.kr(1) + (padding[0] * 0));
}).add;
floodFit = {
    var bus = Bus.control(server, floodCount), ids = floodCount.collect({ server.nextNodeID }), values, count;
    var reserveBus = Bus.control(server, 1), reserve = 2.collect({ server.nextNodeID });
    bus.setAll(0);
    server.sendBundle(nil, *reserve.collect({ arg id; ['/s_new', \strataCheckMemProbe, id, 1, engine.processGroup.nodeID,
        \out, reserveBus.index] }));
    server.sync; 0.01.wait;
    server.sendBundle(nil, *([['/error', -1]] ++ ids.collect({ arg id, index;
        ['/s_new', \strataCheckEffectsPoolProbe, id, 1, engine.processGroup.nodeID, \out, bus.index + index]
    }) ++ reserve.collect({ arg id; ['/n_free', id] })));
    server.sync; 0.05.wait;
    values = readBus.(bus);
    count = values.count({ arg value; value > 0.5 });
    server.sendBundle(nil, ['/error', -1], *ids.collect({ arg id; ['/n_free', id] }));
    server.sync;
    bus.free; reserveBus.free;
    count
};
smallProbeKB = {
    var bus = Bus.control(server, 4), without, with, probes;
    without = floodFit.value;
    probes = 4.collect({ arg index; Synth(\strataCheckMemProbe, [\out, bus.index + index], engine.processGroup, \addToTail) });
    server.sync; 0.05.wait;
    with = floodFit.value;
    probes.do(_.free); server.sync; bus.free;
    1028 / (without - with).max(1)
};

// A check-only copy of 3.0's master filter (lib/Engine_Strata.sc at 3.1.0),
// RHPF and all, against which checkFilterAsBefore holds today's (#305)
SynthDef(\strataCheck30Filter, { arg in, out, freq=5000, res=0.5, filterType=0, mix=0;
    var dry, filtered, cutoff, rq, wet, type;
    dry = In.ar(in, 2).collect({ arg channel; engine.zeroBadValues(channel) });
    cutoff = freq.lag(0.05).clip(20, 20000);
    rq = 1 - (res.clip(0, 1) * 0.95);
    type = filterType.round.clip(0, 2);
    filtered = [
        RLPF.ar(dry, cutoff, rq),
        RHPF.ar(dry, cutoff, rq),
        BPF.ar(dry, cutoff, rq)
    ].collect({ arg each, index; each * BinaryOpUGen('==', type, index).lag(0.02) }).sum;
    wet = mix.lag(0.05).clip(0, 1);
    Out.ar(out, dry + ((filtered - dry) * wet));
}).add;
// A check-only reverb: \strataReverb's FreeVerb2, fully wet, fed the
// filtered reverb send plus k times the delay's return, at its level (the
// engine's reverb with no lift fade and no lags)
SynthDef(\strataCheckPlainReverb, { arg send, delay, out, k = 1, mix = 0.43, size = 0.8, damp = 0.5;
    var sig = In.ar(send, 2) + (In.ar(delay, 2) * k);
    Out.ar(out, FreeVerb2.ar(sig[0], sig[1], 1, size, damp) * mix);
}).add;
// 3.7's law at the defaults (a check-only copy): the dry signal x times 0.7
// plus 0.3 of FreeVerb2 fully wet on it (the filter at mix 0 and the delay
// at mix 0 pass nothing else)
SynthDef(\strataCheckLaw37, { arg in, out, size = 0.8, damp = 0.5;
    var x = In.ar(in, 2);
    Out.ar(out, (x * 0.7) + (FreeVerb2.ar(x[0], x[1], 1, size, damp) * 0.3));
}).add;
// Three stereo buses summed times 0.7 (design §7.1's masterSum, written out)
SynthDef(\strataCheckPlainSum, { arg a, b, c, out;
    Out.ar(out, (In.ar(a, 2) + In.ar(b, 2) + In.ar(c, 2)) * 0.7);
}).add;
// A stand-in grain synth: bursts of noise and a tone (raw, also written to
// the raw bus) through the engine's voiceOutput with the given dry level and
// sends; its buses are controls (voiceOutput's named controls, set from
// mixBusControls), so a check can move them to private buses
SynthDef(\strataCheckChainSource, { arg out, raw, dry = 1, delaySend = 1, reverbSend = 1;
    var sig = ({ WhiteNoise.ar(0.15) } ! 2) * LFPulse.kr(3, 0, 0.3).lag(0.005) + SinOsc.ar([330, 331], 0, 0.08);
    Out.ar(raw, sig);
    engine.voiceOutput(sig, out, dry, delaySend, reverbSend);
}).add;
// The master's input (masterSum, as \strataMaster sums it) on the given buses
SynthDef(\strataCheckMasterSum, { arg in, delayIn, reverbIn, out;
    Out.ar(out, engine.masterSum(in, delayIn, reverbIn));
}).add;
// Two stereo buses compared: the energy of their difference and of the
// reference (in), summed since the synth started
SynthDef(\strataCheckCompare, { arg in, ref, out;
    var a = In.ar(in, 2), b = In.ar(ref, 2);
    Out.kr(out, A2K.kr([Integrator.ar((a - b).squared.sum, 1), Integrator.ar(b.squared.sum, 1)]));
}).add;
// The voice filter alone (voiceFilter, as every grain synth runs it)
SynthDef(\strataCheckVoiceFilter, { arg in, out, filterType = 0, freq = 1000, res = 0.5, mix = 1;
    Out.ar(out, engine.voiceFilter(In.ar(in, 2), filterType, freq, res, mix));
}).add;
// A unit impulse on both channels, once (Impulse at 0 Hz fires on its
// first sample): the same every run, where a noise burst's spectrum, and so
// the decay the reverbs measure, varies with the random generator's state
SynthDef(\strataCheckImpulse, { arg out;
    Out.ar(out, Impulse.ar(0) ! 2);
    Line.kr(0, 0, 0.01, doneAction: 2);
}).add;
// The decay of two stereo buses (inA, inB), measured on the server for a
// fixed number of control blocks, after which it frees itself (its /n_end
// ends the wait). For each bus, from its energy envelope (20 ms lag): the
// blocks spent above -5 dB and above -35 dB of the running peak, 1 once it
// fell below -35 dB, and the peak; out holds the eight values when it ends.
SynthDef(\strataCheckDecayTimes, { arg inA, inB, out, blocks = 1;
    Out.kr(out, [inA, inB].collect({ arg in;
        var energy = A2K.kr(Lag.ar(In.ar(in, 2).squared.sum, 0.02)), peak = RunningMax.kr(energy);
        [Integrator.kr(energy > (peak * 10.pow(-0.5)), 1), Integrator.kr(energy > (peak * 10.pow(-3.5)), 1),
            RunningMax.kr((energy < (peak * 10.pow(-3.5))) * (peak > 0)), peak]
    }).flat);
    Line.kr(0, 0, blocks * ControlDur.ir, doneAction: 2);
}).add;
// A one-sample impulse on the left channel only (the right silent)
SynthDef(\strataCheckLeftImpulse, { arg out;
    Out.ar(out, [Impulse.ar(0), DC.ar(0)]);
    Line.kr(0, 0, 0.01, doneAction: 2);
}).add;
// Each side's largest absolute sample of a stereo bus in three windows of
// time from the node's start ([start, end] s each), on out as six values
// (window 1 left, right, window 2 left, ...); it frees itself at seconds
SynthDef(\strataCheckEchoPeaks, { arg in, out, windows = #[0, 0, 0, 0, 0, 0], seconds = 1;
    var sig = In.ar(in, 2), elapsed = Sweep.ar(0, 1);
    Out.kr(out, 3.collect({ arg index;
        var inside = (elapsed >= windows[index * 2]) * (elapsed < windows[(index * 2) + 1]);
        sig.collect({ arg channel; A2K.kr(RunningMax.ar(channel.abs * inside)) })
    }).flat);
    Line.kr(0, 0, seconds, doneAction: 2);
}).add;
// A 25 Hz sine at 0.4 on out, and on freqOut a cutoff of 20 Hz for its
// first 2 s, then 20 kHz (timed on the server, from the synth's start)
SynthDef(\strataCheckCutoffStepSource, { arg out, freqOut;
    Out.ar(out, SinOsc.ar(25, 0, 0.4) ! 2);
    Out.kr(freqOut, Select.kr(Sweep.kr(0, 1) > 2, [DC.kr(20), DC.kr(20000)]));
}).add;
// The peak of a bus's left channel from 1 to 1.9 s after the synth's start
// (before the step) and from 2 s on (after it)
SynthDef(\strataCheckStepPeaks, { arg in, out;
    var time = Sweep.kr(0, 1), level = In.ar(in, 2)[0].abs;
    Out.kr(out, A2K.kr([RunningMax.ar(level * (time > 1) * (time <= 1.9)), RunningMax.ar(level * (time > 2))]));
}).add;
SynthDef(\strataCheckPinkNoise, { arg out; Out.ar(out, PinkNoise.ar(0.5 ! 2)) }).add;
// A check-only copy of 3.7's \strataDelay, on its own DelayC lines of 2.7 s
// (lib/engine/StrataEffects.sc at 3.7.0), against which the engine's buffer
// line is compared (3.8 design §0.2)
SynthDef(\strataCheckDelayC37, {
    arg in, out, time=0.375, feedback=0.4, mix=0, pingPong=0, fadeIn=0;
    var input = In.ar(in, 2) * engine.liftFade(fadeIn), returned = LocalIn.ar(2);
    var cross = pingPong.clip(0, 1).lag(0.05), keep = 1 - cross;
    var delayed = DelayC.ar([
        input[0] + (input[1] * cross) + (returned[0] * keep) + (returned[1] * cross),
        (input[1] * keep) + (returned[1] * keep) + (returned[0] * cross)
    ], 2.7, time.lag(0.1).clip(0.01, 2.7));
    LocalOut.ar(delayed * feedback.clip(0, 0.95));
    Out.ar(out, delayed * mix.clip(0, 1).lag(engine.fxMixLag));
}).add;
// The largest absolute difference between two stereo buses and the largest
// sample of the second (both channels summed), on out, from the node's
// start; it frees itself at seconds
SynthDef(\strataCheckDiffPeak, { arg inA, inB, out, seconds = 1;
    var b = In.ar(inB, 2);
    Out.kr(out, A2K.kr([RunningMax.ar((In.ar(inA, 2) - b).abs.sum), RunningMax.ar(b.abs.sum)]));
    Line.kr(0, 0, seconds, doneAction: 2);
}).add;
// A delay time on a control bus: center + depth x a sine at rate Hz
SynthDef(\strataCheckTimeLfo, { arg out, center = 0.3, depth = 0.1, rate = 0.5;
    Out.kr(out, SinOsc.kr(rate, 0, depth, center));
}).add;
// The master's output (in) against the master without its shifter: the
// limiter, the saturation and amp 0.7 on the filtered dry bus (clean) times
// masterSumGain (the master's sum with both returns silent) two samples
// late, as the shifter at ratio 1 delays it. Since t_reset: the
// running minimum and maximum of each one's level (a 0.5 ms / 20 ms
// follower) and the largest difference between them.
SynthDef(\strataCheckMasterLevel, { arg in, clean, out, t_reset = 0;
    var follow = { arg sig; Amplitude.ar(sig, 0.0005, 0.02) };
    var output = In.ar(in, 2)[0];
    var plain = ((Limiter.ar(Delay2.ar(In.ar(clean, 2)[0] * engine.masterSumGain), 0.95) * 2).tanh * 0.5) * 0.7;
    var master = follow.(output), reference = follow.(plain), reset = T2A.ar(t_reset);
    Out.kr(out, A2K.kr([RunningMin.ar(master, reset), RunningMax.ar(master, reset),
        RunningMin.ar(reference, reset), RunningMax.ar(reference, reset), Peak.ar((output - plain).abs, reset)]));
}).add;
server.sync;

// The largest sample step a filter of def (fully wet, a 1 kHz sine at its
// cutoff, where lowpass and highpass are in antiphase) takes while its type
// changes, against the largest in any type's steady state, and every type's
// steady step above 0.01 (a type that played silence would pass the
// comparison as 0 <= 0, #365). Each [defName, message] pair runs in its own
// group on its own buses, all at once (the same type changes at the same
// times), so the defs share one timeline.
checkFilterCrossfade = { arg pairs;
    var runs = pairs.collect({ arg pair;
        var group = Group.tail(server), filterIn = Bus.audio(server, 2), filterOut = Bus.audio(server, 2);
        var stepBus = Bus.control(server, 1), filterSynth, stepProbe;
        Synth(\strataCheckSine, [\out, filterIn, \freq, 1000], group, \addToTail);
        filterSynth = Synth(pair[0], [\in, filterIn, \out, filterOut, \freq, 1000, \res, 0.5, \filterType, 0, \mix, 1],
            group, \addToTail);
        stepProbe = Synth(\strataCheckStep, [\in, filterOut, \out, stepBus], group, \addToTail);
        (message: pair[1], group: group, buses: [filterIn, filterOut, stepBus], stepBus: stepBus,
            filter: filterSynth, probe: stepProbe, steady: List.new)
    });
    var setType = { arg type; server.makeBundle(nil, { runs.do({ arg run; run[\filter].set(\filterType, type) }) }) };
    var resetProbes = { server.makeBundle(nil, { runs.do({ arg run; run[\probe].set(\t_reset, 1) }) }) };
    [0, 1, 2].do({ arg type;
        setType.(type); 0.4.wait;
        resetProbes.value; 0.3.wait;
        runs.do({ arg run; run[\steady].add(readStep.(run[\stepBus])) })
    });
    setType.(0); 0.4.wait;
    resetProbes.value; 0.05.wait;
    // six changes, each at a different point in the sine's cycle
    [1, 2, 0, 2, 1, 0].do({ arg type; setType.(type); 0.13.wait });
    runs.do({ arg run;
        var switchStep = readStep.(run[\stepBus]), steadySteps = run[\steady].asArray;
        check.((steadySteps.size == 3) and: { steadySteps.minItem > 0.01 } and: { switchStep <= (steadySteps.maxItem * 1.1) },
            "% (largest step % while switching, % at most in steady state %, each type's above 0.01)".format(
                run[\message], switchStep.round(0.0001), steadySteps.maxItem.round(0.0001), steadySteps.round(0.0001)));
    });
    runs.do({ arg run; run[\group].free; run[\buses].do(_.free) });
};

// Each filter type passes and stops what its name says (#365): 100 Hz,
// 1 kHz and 10 kHz sines at 0.5, a tone below, at and above the cutoff
// (1 kHz, res 0.5, fully wet), through \strataFilter and the voice filter.
// The lowpass passes the low tone and stops the high one, the highpass the
// reverse, the bandpass passes only the middle one ("passes": a peak above
// 0.7 of the tone's; "stops": under 0.2). The other filter checks compare a
// filter with itself or with copies of the same design; this one fails if
// two types are swapped or one is silent. All 18 chains run at once.
checkFilterTypes = {
    var tones = [100, 1000, 10000], defs = [\strataFilter, \strataCheckVoiceFilter], types = [0, 1, 2];
    // per type, on [low, middle, high]: true passes, false stops, nil either
    var expected = [[true, nil, false], [false, nil, true], [false, true, false]];
    var group = Group.tail(server), toneBuses = tones.collect({ Bus.audio(server, 2) });
    var cases = defs.collect({ arg def; types.collect({ arg type; tones.collect({ arg freq, tone; [def, type, tone] }) }) }).flatten(2);
    var outBuses = cases.collect({ Bus.audio(server, 2) }), peakBus = Bus.control(server, cases.size * 2), probes, gains;
    server.makeBundle(nil, {
        tones.do({ arg freq, tone; Synth(\strataCheckSine, [\out, toneBuses[tone], \freq, freq], group, \addToTail) });
        probes = cases.collect({ arg each, index;
            Synth(each[0], [\in, toneBuses[each[2]], \out, outBuses[index], \freq, 1000, \res, 0.5, \filterType, each[1], \mix, 1],
                group, \addToTail);
            Synth(\strataCheckChannelPeaks, [\in, outBuses[index], \out, peakBus.index + (index * 2)], group, \addToTail)
        });
    });
    server.sync; 0.5.wait;
    server.makeBundle(nil, { probes.do({ arg probe; probe.set(\t_reset, 1) }) });
    0.3.wait;
    gains = readBus.(peakBus).clump(2).collect({ arg pair; (pair[0] / 0.5).round(0.001) });
    defs.do({ arg def, which;
        var byType = if (gains.size == cases.size) { gains.copyRange(which * 9, (which * 9) + 8).clump(3) } { [] };
        check.((byType.size == 3) and: { types.every({ arg type; tones.every({ arg freq, tone;
                var want = expected[type][tone], gain = byType[type][tone];
                want.isNil or: { if (want) { gain > 0.7 } { gain < 0.2 } }
            }) }) },
            "effects: each filter type passes and stops what its name says (%: gains on 100 Hz, 1 kHz and 10 kHz at a 1 kHz cutoff: lowpass %, highpass %, bandpass %)".format(
                def, byType[0], byType[1], byType[2]));
    });
    group.free; server.sync;
    (toneBuses ++ outBuses ++ [peakBus]).do(_.free);
};

// A cutoff stepped up from 20 Hz to 20 kHz in one control change throws no
// spike (#305). A 25 Hz sine at 0.4 (a tone just above the parked cutoff:
// the worst case found) runs through \strataFilter and the voice filter,
// fully wet, both cutoffs mapped to a control bus that a check synth holds
// at 20 Hz for 2 s and then at 20 kHz. Everything starts in one bundle and
// times itself on the server (Sweep), so the figures are the same every
// run. The peak after the step stays under 3 for the highpass and the
// bandpass at res 1 (the resonance's own reach there is 20 x 0.4 = 8) and
// under 1.5 for the lowpass at res 1 and the highpass at res 0.5; the peak
// before it is above 0.01 on both filters, so silence never passes.
checkCutoffStep = {
    // [type, res, ceiling]
    var cases = [[1, 1.0, 3], [2, 1.0, 3], [0, 1.0, 1.5], [1, 0.5, 1.5]], defs = [\strataFilter, \strataCheckVoiceFilter];
    var peakBus = Bus.control(server, cases.size * 4), freqBus = Bus.control(server, 1), group = Group.tail(server);
    var inBus = Bus.audio(server, 2), outBuses = cases.collect({ defs.collect({ Bus.audio(server, 2) }) }), peaks;
    freqBus.set(20); server.sync;
    server.makeBundle(nil, {
        Synth(\strataCheckCutoffStepSource, [\out, inBus, \freqOut, freqBus], group, \addToTail);
        cases.do({ arg each, index;
            defs.do({ arg def, which;
                var filter = Synth(def, [\in, inBus, \out, outBuses[index][which], \freq, 20, \res, each[1],
                    \filterType, each[0], \mix, 1], group, \addToTail);
                filter.map(\freq, freqBus);
                Synth(\strataCheckStepPeaks, [\in, outBuses[index][which], \out, peakBus.index + (index * 4) + (which * 2)],
                    group, \addToTail);
            });
        });
    });
    server.sync; 4.5.wait;
    peaks = readBus.(peakBus);
    group.free; server.sync;
    cases.do({ arg each, index;
        var four = peaks.copyRange(index * 4, (index * 4) + 3);
        check.((four.size == 4) and: { four[0] > 0.01 } and: { four[2] > 0.01 } and: { four[1] < each[2] } and: { four[3] < each[2] },
            "effects: a cutoff stepped 20 Hz -> 20 kHz throws no spike (type %, res %, a 25 Hz sine at 0.4: \\strataFilter peaks % after the step, % before; the voice filter % after, % before; ceiling %)".format(
                each[0], each[1], four[1] !? { arg value; value.round(0.001) }, four[0] !? { arg value; value.round(0.001) },
                four[3] !? { arg value; value.round(0.001) }, four[2] !? { arg value; value.round(0.001) }, each[2]));
    });
    ([peakBus, freqBus, inBus] ++ outBuses.flat).do(_.free);
};

// A cutoff that falls, holds or rises slowly plays as 3.0's filter did
// (#305): \strataFilter against the area's verbatim copy of 3.0's filter
// (\strataCheck30Filter) on one pink noise bus. The lowpass and the
// bandpass are exact (difference 0) in steady state, through a 20 kHz -> 20
// Hz step and through a 1000 -> 1414 Hz step; the highpass is within 1e-6
// in steady state at 20 Hz, 1 kHz and 20 kHz, each read after 3 s (a
// highpass moved down rings at its new cutoff, 0.11 s per e-fold at 20 Hz
// and res 0.9).
checkFilterAsBefore = {
    var inBus = Bus.audio(server, 2), engineBus = Bus.audio(server, 2), copyBus = Bus.audio(server, 2);
    var diffBus = Bus.control(server, 2), group = Group.tail(server), filter, copy, probe, set, differ, results;
    server.makeBundle(nil, {
        Synth(\strataCheckPinkNoise, [\out, inBus], group, \addToTail);
        filter = Synth(\strataFilter, [\in, inBus, \out, engineBus, \freq, 1000, \res, 0.5, \filterType, 0, \mix, 1], group, \addToTail);
        copy = Synth(\strataCheck30Filter, [\in, inBus, \out, copyBus, \freq, 1000, \res, 0.5, \filterType, 0, \mix, 1], group, \addToTail);
        probe = Synth(\strataCheckBusDiff, [\a, engineBus, \b, copyBus, \out, diffBus], group, \addToTail);
    });
    // both filters' controls in one bundle; the largest difference (and the
    // engine filter's level) over the given seconds from now
    set = { arg ... controls; server.makeBundle(nil, { filter.set(*controls); copy.set(*controls) }) };
    differ = { arg seconds = 0.6; probe.set(\t_reset, 1); seconds.wait; readBus.(diffBus) };
    server.sync; 0.3.wait;
    results = [0, 2].collect({ arg type;
        var steady, fall, rise;
        set.(\filterType, type, \freq, 20000, \res, 0.9); 0.5.wait;
        steady = differ.value;
        server.makeBundle(nil, { probe.set(\t_reset, 1); filter.set(\freq, 20); copy.set(\freq, 20) }); 0.8.wait;
        fall = readBus.(diffBus);
        set.(\freq, 1000); 0.8.wait;
        server.makeBundle(nil, { probe.set(\t_reset, 1); filter.set(\freq, 1414); copy.set(\freq, 1414) }); 0.6.wait;
        rise = readBus.(diffBus);
        [steady, fall, rise]
    });
    check.(results.flatten(1).every({ arg pair; (pair.size == 2) and: { pair[0] == 0 } and: { pair[1] > 0.01 } }),
        "effects: a cutoff that falls, holds or rises slowly plays the lowpass and the bandpass exactly as 3.0's (differences [steady, 20 kHz -> 20 Hz, 1000 -> 1414 Hz], lowpass then bandpass: %; levels %)".format(
            results.collect({ arg each; each.collect(_[0]) }),
            results.collect({ arg each; each.collect({ arg pair; pair[1] !? { arg value; value.round(0.001) } }) })));
    results = [20, 1000, 20000].collect({ arg freq;
        set.(\filterType, 1, \freq, freq, \res, 0.9); 3.0.wait;
        differ.value
    });
    check.(results.every({ arg pair; (pair.size == 2) and: { pair[0] < 1e-6 } and: { pair[1] > 0.01 } }),
        "effects: the highpass in steady state is 3.0's within 1e-6 (at 20 Hz, 1 kHz and 20 kHz: differences %, levels %)".format(
            results.collect(_[0]), results.collect({ arg pair; pair[1] !? { arg value; value.round(0.001) } })));
    group.free; server.sync;
    [inBus, engineBus, copyBus, diffBus].do(_.free);
};
// the largest step since the probe on bus was last reset
readStep = { arg bus;
    var condition = Condition(false), value;
    bus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
};

// A fresh engine starts at the Lua params' defaults, read before any
// command reaches it (#364): the script never bangs its params, so this is
// what plays until a param moves. (The Lua test "the FX SynthDefs' defaults
// equal the Lua param defaults" pins the SynthDefs' defaults to the
// params'; this pins what the nodes start with.) Each master filter at
// 5000 Hz, res 0.5, lowpass, mix 0; the delay at 0.375 s, feedback 0.4, mix
// 0, pingPong 0; the reverb at level 0.43, size 0.8, damp 0.5 and delay to
// reverb 1 (3.8); the drift at 0.01; no fxMix bus (3.8's plain sends);
// neither effect bypassed (the bypass params' 0);
// the scale chromatic from C (what the scale and root params' defaults
// send: setScale(0, 4095)).
checkFreshDefaults = {
    var fresh = h.startEngine(()), values;
    var read = { arg key, controls; controls.collect({ arg control; fresh.synths[key] !? { arg synth; getControl.(synth, control) } }) };
    var near = { arg got, wanted; (got.size == wanted.size) and: { [got, wanted].flop.every({ arg pair;
        pair[0].notNil and: { pair[0].equalWithPrecision(pair[1], 1e-6) } }) } };
    server.sync;
    values = (
        filters: [\filter, \filterDelay, \filterReverb].collect({ arg key; read.(key, [\freq, \res, \filterType, \mix]) }),
        delay: read.(\delay, [\time, \feedback, \mix, \pingPong]),
        reverb: read.(\reverb, [\mix, \size, \damp, \delayToReverb]),
        kept: fresh.areaState[\effects][\controls][\reverb].atAll([\mix, \size, \damp, \delayToReverb]),
        drift: read.(\master, [\drift]), fxMix: fresh.mixBus(\fxMix),
        bypassed: [\delay, \reverb].collect({ arg key; fresh.areaState[\effects][\bypassed][key] }),
        scale: fresh.scaleRootAndMask
    );
    h.freeEngine(fresh);
    server.sync;
    check.(values[\filters].every({ arg each; near.(each, [5000, 0.5, 0, 0]) }),
        "effects: a fresh engine's three master filters start at 5000 Hz, res 0.5, lowpass and mix 0, the Lua defaults (got %)".format(
            values[\filters]));
    check.(near.(values[\delay], [0.375, 0.4, 0, 0])
        and: { SynthDescLib.global.at(\strataDelay).controls.any({ arg control; control.name == \pingPong }) }
        and: { near.(values[\reverb], [0.43, 0.8, 0.5, 1]) } and: { near.(values[\kept], [0.43, 0.8, 0.5, 1]) }
        and: { near.(values[\drift], [0.01]) } and: { values[\fxMix].isNil },
        "effects: a fresh engine's delay starts at 0.375 s, feedback 0.4, level and pingPong 0, its reverb at level 0.43, size 0.8, damp 0.5 and delay to reverb 1 (kept so too), its drift at 0.01, with no fxMix bus, the Lua defaults (delay %, reverb %, kept %, drift %, fxMix %)".format(
            values[\delay], values[\reverb], values[\kept], values[\drift], values[\fxMix]));
    check.((values[\bypassed] == [false, false]) and: { values[\scale] == [0, 4095] },
        "effects: a fresh engine has neither effect bypassed and plays the chromatic scale from C, the Lua defaults (bypassed %, scale %)".format(
            values[\bypassed], values[\scale]));
};

checkRouting = {
    var filters = [\filter, \filterDelay, \filterReverb].collect({ arg key; engine.synths[key] });
    var master = engine.synths[\master];
    check.([[engine.mainBus, engine.filterBus], [\delaySend, \delaySendPost], [\reverbSend, \reverbSendPost]].every({ arg pair, index;
        var buses = pair.collect({ arg bus; if (bus.isKindOf(Symbol)) { mixBus.(bus) } { bus } });
        (getControl.(filters[index], \in) == buses[0].index) and: { getControl.(filters[index], \out) == buses[1].index }
    }), "effects: the three master filters read the dry, delay send and reverb send buses and write their ...Post copies");
    check.((getControl.(engine.synths[\delay], \in) == mixBus.(\delaySendPost).index)
        and: { getControl.(engine.synths[\delay], \out) == engine.delayBus.index },
        "effects: the delay reads the filtered delay send and writes its return (delayBus)");
    check.((getControl.(engine.synths[\reverb], \in) == mixBus.(\reverbSendPost).index)
        and: { getControl.(engine.synths[\reverb], \delayIn) == engine.delayBus.index }
        and: { getControl.(engine.synths[\reverb], \out) == engine.reverbBus.index },
        "effects: the reverb reads the filtered reverb send and the delay's return, and writes its return (reverbBus)");
    check.((getControl.(master, \in) == engine.filterBus.index) and: { getControl.(master, \delayIn) == engine.delayBus.index }
        and: { getControl.(master, \reverbIn) == engine.reverbBus.index }
        and: { SynthDescLib.global.at(\strataMaster).controlNames.collect(_.asSymbol).includes(\fxMix).not },
        "effects: the master sums the filtered dry bus and the two returns, and reads no mix bus");
    check.(chainTail.value == [\strataFilter, \strataFilter, \strataFilter, \strataDelay, \strataReverb, \strataMaster],
        "effects: xg ends filter x3 -> delay -> reverb -> master (got %)".format(chainTail.value));
    check.((mixBus.(\dry) === engine.mainBus) and: { mixBus.(\dryPost) === engine.filterBus }
        and: { mixBus.(\delayReturn) === engine.delayBus } and: { mixBus.(\reverbReturn) === engine.reverbBus }
        and: { mixBus.(\fxMix).isNil }
        and: { [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].every({ arg name;
            (mixBus.(name).numChannels == 2) and: { mixBus.(name).rate == \audio } }) },
        "effects: areaState[\\mix] holds the stereo send buses, their ...Post copies and the returns, and no fxMix");
    // every stage takes this engine's buses
    check.((0..(engine.numVoices - 1)).every({ arg voice;
        var synth = engine.synths[engine.voiceMixKey(voice)];
        synth.notNil and: { getControl.(synth, \delaySendOut) == mixBus.(\delaySend).index }
            and: { getControl.(synth, \reverbSendOut) == mixBus.(\reverbSend).index }
    }) and: { SynthDescLib.global.at(\strataVoiceMix).controlNames.collect(_.asSymbol).includes(\fxMixIn).not },
        "effects: every voice's mix stage writes this engine's send buses and reads no mix bus");
};

// A NaN or inf on any of the three mix buses (a voice blowing up) becomes
// silence before the effects: with the delay feeding back and the reverb
// on, 50 ms of inf and NaN on the bus leave the master output free of bad
// values once they have passed. A probe on the bus itself sees the burst.
checkEffectsGuard = {
    command.(\setDelay, 0.25, 0.5, 0.5, 0);
    command.(\setReverb, 0.5, 0.8, 0.5, 1);
    [[\dry, engine.mainBus], [\delaySend, mixBus.(\delaySend)], [\reverbSend, mixBus.(\reverbSend)]].do({ arg pair;
        var badBus = Bus.control(server, 1), busBadBus = Bus.control(server, 1), probe, busProbe, bad, busBad;
        probe = Synth(\strataCheckBadValues, [\in, context.out_b, \out, badBus], context.xg, \addAfter);
        busProbe = Synth(\strataCheckBadValues, [\in, pair[1], \out, busBadBus], engine.processGroup, \addAfter);
        server.sync;
        Synth(\strataCheckBadSource, [\out, pair[1]], engine.processGroup, \addToTail);
        server.sync; 0.3.wait;
        busBad = readBus.(busBadBus);
        bad = measure.(probe, badBus, 0.5);
        check.(busBad.notEmpty and: { busBad[0] > 0 } and: { bad == [0] },
            "effects: NaN on any filter bus is zeroed (% bus: the burst seen there %, bad values at the output %)".format(
                pair[0], busBad, bad));
        probe.free; busProbe.free; badBus.free; busBadBus.free;
    });
};

// setSynth sends to the effects chain plainly (#47 review): the chain's
// synths never end on their own (the bypass frees and creates them in the
// engine), so a "Node not found" there is a real bug the server must
// report, while a voice's synth may have just freed and gets sendToSynth's
// quiet bundle. With \filter pointed at a freed node (restored afterward),
// each FX command's messages are captured with makeBundle(false), which
// sends nothing (a real failure would print a FAILURE line and fail this
// run on purpose): no /error -1 among them, and setFilter's /n_set reaches
// the freed node and both other master filters. A voice param's set has one.
checkEffectSendsReported = {
    var quiet = { arg messages; messages.any({ arg msg; (msg[0] == '/error') and: { msg[1] == -1 } }) };
    var filter = engine.synths[\filter], freed = Group.tail(server);
    var captured, filterTargets;
    server.sync; freed.free; server.sync;
    engine.synths[\filter] = freed;
    captured = [{ command.(\setFilter, 5000.0, 0.5, 0, 0.0) }, { command.(\setDelay, 0.375, 0.4, 0.0, 0) },
        { command.(\setReverb, 0.43, 0.8, 0.5, 1) }, { command.(\setMasterDrift, 0.01) }, { command.(\setVoiceParam, 0, \amp, 0.2) }
    ].collect({ arg send; server.makeBundle(false, send) });
    engine.synths[\filter] = filter;
    filterTargets = captured[0].select({ arg msg; msg[0] == 15 }).collect({ arg msg; msg[1] });
    check.(captured.keep(4).every({ arg messages; messages.notEmpty and: { quiet.(messages).not } })
        and: { filterTargets.asSet == Set[freed.nodeID, engine.synths[\filterDelay].nodeID, engine.synths[\filterReverb].nodeID] },
        "setSynth sends to the effects chain without /error -1, so a missing FX node is reported (filter x3, delay, reverb, master: %)".format(
            captured.keep(4)));
    check.(quiet.(captured[4]), "and to a voice's synth inside a quiet bundle (got %)".format(captured[4]));
};

// The plain chain (3.8 design §7.1): the stand-in grain synth through
// voiceOutput at dry 1 and both sends 1, then the engine's three filters
// (the filter on), its delay (level 0.5) and its reverb (level 0.4), at
// delay to reverb k. The reverb's return matches a check-only
// \strataReverb fed the filtered reverb send plus k times the delay's
// return, at its level, within -60 dB of it; and masterSum, on the engine's
// buses, is 0.7 times the three summed within 1e-6. The engine's delay and
// reverb are bypassed and lifted first, so they start empty as the copy
// does, and the source starts once the lifted levels have settled.
checkPlainChain = { arg k;
    var rawBus = Bus.audio(server, 2), copyBus = Bus.audio(server, 2), sumBus = Bus.audio(server, 2);
    var plainBus = Bus.audio(server, 2), energyBus = Bus.control(server, 2), sumPeakBus = Bus.control(server, 2);
    var group = Group.after(context.xg), copy, sums, source, energies, ratio, sumPeaks, condition = Condition(false);
    command.(\setFilter, 1200.0, 0.4, 0, 0.6);
    command.(\setDelay, 0.21, 0.5, 0.5, 0);
    command.(\setReverb, 0.4, 0.7, 0.3, k);
    command.(\setBypass, 0, 1); command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
    server.sync;
    copy = Synth(\strataCheckPlainReverb, [\send, mixBus.(\reverbSendPost), \delay, engine.delayBus, \out, copyBus,
        \k, k, \mix, 0.4, \size, 0.7, \damp, 0.3], engine.synths[\reverb], \addAfter);
    sums = [
        Synth(\strataCheckMasterSum, [\in, engine.filterBus, \delayIn, engine.delayBus, \reverbIn, engine.reverbBus,
            \out, sumBus], engine.synths[\master], \addBefore),
        Synth(\strataCheckPlainSum, [\a, engine.filterBus, \b, engine.delayBus, \c, engine.reverbBus, \out, plainBus],
            engine.synths[\master], \addBefore)
    ];
    0.6.wait; server.sync;   // the lifted levels settle
    server.makeBundle(nil, {
        var peaks;
        source = Synth(\strataCheckChainSource, [\out, engine.mainBus, \raw, rawBus]
            ++ engine.mixBusControls.asKeyValuePairs, engine.processGroup, \addToTail);
        Synth(\strataCheckCompare, [\in, engine.reverbBus, \ref, copyBus, \out, energyBus], group);
        peaks = Synth(\strataCheckDiffPeak, [\inA, sumBus, \inB, plainBus, \out, sumPeakBus, \seconds, 1.5], group);
        OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr, argTemplate: [peaks.nodeID]).oneShot;
    });
    awaitReply.(condition, 15);
    energies = readBus.(energyBus);
    sumPeaks = readBus.(sumPeakBus);
    ratio = if (energies.size == 2 and: { energies[1] > 0 }) { (energies[0] / energies[1]).sqrt } { 1 };
    check.((energies.size == 2) and: { energies[1] > 1 } and: { ratio < 0.001 },
        "effects: the reverb's return is FreeVerb2 on the reverb send plus % of the delay's return, at its level, within -60 dB (% dB, reference energy %)".format(
            k, (ratio.max(1e-12).ampdb).round(0.1), energies[1] ? 0));
    check.((sumPeaks.size == 2) and: { sumPeaks[1] > 0.01 } and: { sumPeaks[0] < 1e-6 },
        "effects: masterSum is 0.7 of the dry bus and the two returns within 1e-6 (delay to reverb %: difference %, largest sample %)".format(
            k, sumPeaks[0], sumPeaks[1]));
    source.free; copy.free; sums.do(_.free); group.free; server.sync;
    [rawBus, copyBus, sumBus, plainBus, energyBus, sumPeakBus].do(_.free);
};

// A default start sounds as 3.7.0's (design §7.1): at the defaults (dry 1,
// sends 1, the filter at mix 0, the delay at level 0, the reverb at 0.43,
// delay to reverb 1) the master's input is within -40 dB of 3.7's law,
// 0.7 F(x) + 0.3 R(F(x)) (F the filter, here x itself; R FreeVerb2 fully
// wet), on a check-only copy fed the stand-in's raw signal
checkDefaultBalance = {
    var rawBus = Bus.audio(server, 2), lawBus = Bus.audio(server, 2), sumBus = Bus.audio(server, 2);
    var energyBus = Bus.control(server, 2), group = Group.after(context.xg), source, energies, ratio, sum;
    command.(\setFilter, 5000.0, 0.5, 0, 0.0);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    command.(\setBypass, 0, 1); command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
    server.sync;
    Synth(\strataCheckLaw37, [\in, rawBus, \out, lawBus], group, \addToTail);
    sum = Synth(\strataCheckMasterSum, [\in, engine.filterBus, \delayIn, engine.delayBus, \reverbIn, engine.reverbBus,
        \out, sumBus], engine.synths[\master], \addBefore);
    0.6.wait; server.sync;
    server.makeBundle(nil, {
        source = Synth(\strataCheckChainSource, [\out, engine.mainBus, \raw, rawBus]
            ++ engine.mixBusControls.asKeyValuePairs, engine.processGroup, \addToTail);
        Synth(\strataCheckCompare, [\in, sumBus, \ref, lawBus, \out, energyBus], group, \addToTail);
    });
    1.5.wait; server.sync;
    energies = readBus.(energyBus);
    ratio = if (energies.size == 2 and: { energies[1] > 0 }) { (energies[0] / energies[1]).sqrt } { 1 };
    check.((energies.size == 2) and: { energies[1] > 1 } and: { ratio < 0.01 },
        "effects: at the defaults the master's input is 3.7's law (0.7 dry + 0.3 reverb) within -40 dB (% dB, reference energy %)".format(
            (ratio.max(1e-12).ampdb).round(0.1), energies[1] ? 0));
    source.free; sum.free; group.free; server.sync;
    [rawBus, lawBus, sumBus, energyBus].do(_.free);
};

// Plain sends (design §7.1): the stand-in's dry bus reads its signal x
// times dry and each send bus x times that send, the sends taken before the
// dry level, whatever the delay's and the reverb's levels (0.8 and 0.9):
// [dry, delay send, reverb send] at [1, 0, 0], [1, 1, 1], [0, 1, 0.5] and
// [0.5, 0.3, 1], each bus within 1e-5
checkPlainSends = {
    var rawBus = Bus.audio(server, 2), dryBus = Bus.audio(server, 2), delayBus = Bus.audio(server, 2);
    var reverbBus = Bus.audio(server, 2), peakBus = Bus.control(server, 4);
    var group = Group.after(engine.processGroup), source, probe, peaks, results;
    var cases = [[1, 0, 0], [1, 1, 1], [0, 1, 0.5], [0.5, 0.3, 1]];
    // the largest error of each bus against the raw signal times its gain
    SynthDef(\strataCheckSendPeaks, { arg raw, dry, delay, reverb, out, dryGain = 1, delayGain = 0, reverbGain = 0, t_reset = 0;
        var x = In.ar(raw, 2);
        Out.kr(out, A2K.kr([
            Peak.ar((In.ar(dry, 2) - (x * dryGain)).abs.sum, t_reset),
            Peak.ar((In.ar(delay, 2) - (x * delayGain)).abs.sum, t_reset),
            Peak.ar((In.ar(reverb, 2) - (x * reverbGain)).abs.sum, t_reset),
            Peak.ar(x.abs.sum, t_reset)
        ]));
    }).add;
    command.(\setDelay, 0.375, 0.4, 0.8, 0);
    command.(\setReverb, 0.9, 0.8, 0.5, 1);
    server.sync; 0.2.wait;
    results = cases.collect({ arg each;
        source = Synth(\strataCheckChainSource, [\out, dryBus, \raw, rawBus, \dry, each[0], \delaySend, each[1],
            \reverbSend, each[2], \delaySendOut, delayBus.index, \reverbSendOut, reverbBus.index], group);
        probe = Synth(\strataCheckSendPeaks, [\raw, rawBus, \dry, dryBus, \delay, delayBus, \reverb, reverbBus, \out, peakBus,
            \dryGain, each[0], \delayGain, each[1], \reverbGain, each[2]], group, \addToTail);
        server.sync; 0.2.wait;
        peaks = measure.(probe, peakBus, 0.5);
        source.free; probe.free; server.sync;
        peaks
    });
    check.(results.every({ arg each; (each.size == 4) and: { each[3] > 0.1 } and: { each.keep(3).every({ arg peak; peak < 1e-5 }) } }),
        "effects: plain sends: the dry bus is x times dry and each send x times its send, the levels aside (delay 0.8, reverb 0.9; [dry, delay, reverb] % : errors %)".format(
            cases, results.collect({ arg each; each.round(0.000001) })));
    group.free; [rawBus, dryBus, delayBus, reverbBus, peakBus].do(_.free);
};

// What a player meets (3.8 plan, 1a): the reverb at level 0 while the delay
// plays. The echoes still sound, since the delay's return reaches the master
// on its own: an impulse on the delay send alone (time 0.1 s, feedback 0,
// level 0.5, the filter at mix 0, the reverb at level 0) comes back on the
// delay's return at 0.5 and on the master's input (masterSum on the
// engine's buses) at 0.7 x 0.5, and nowhere before
checkEchoesWithoutReverb = {
    var sumBus = Bus.audio(server, 2), returnPeaks = Bus.control(server, 6), sumPeaks = Bus.control(server, 6);
    var condition = Condition(false), sum, onReturn, onSum, windows = [0, 0.09, 0.09, 0.11, 0.11, 0.3];
    command.(\setFilter, 5000.0, 0.5, 0, 0.0);
    command.(\setMasterDrift, 0.0);
    command.(\setReverb, 0.0, 0.8, 0.5, 1);
    command.(\setDelay, 0.1, 0.0, 0.5, 0);
    returnPeaks.setAll(0); sumPeaks.setAll(0);
    sum = Synth(\strataCheckMasterSum, [\in, engine.filterBus, \delayIn, engine.delayBus, \reverbIn, engine.reverbBus,
        \out, sumBus], engine.synths[\master], \addBefore);
    server.sync; 0.5.wait;
    server.makeBundle(nil, {
        var analysis;
        Synth(\strataCheckLeftImpulse, [\out, mixBus.(\delaySend)], engine.processGroup, \addToTail);
        Synth(\strataCheckEchoPeaks, [\in, engine.delayBus, \out, returnPeaks, \windows, windows, \seconds, 0.35],
            engine.synths[\master], \addAfter);
        analysis = Synth(\strataCheckEchoPeaks, [\in, sumBus, \out, sumPeaks, \windows, windows, \seconds, 0.35],
            engine.synths[\master], \addAfter);
        OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr, argTemplate: [analysis.nodeID]).oneShot;
    });
    awaitReply.(condition, 10);
    server.sync;
    onReturn = readBus.(returnPeaks);
    onSum = readBus.(sumPeaks);
    check.((onReturn.size == 6) and: { onSum.size == 6 } and: { onReturn[2].equalWithPrecision(0.5, 0.001) }
        and: { onSum[2].equalWithPrecision(0.35, 0.001) }
        and: { [0, 1, 3, 4, 5].every({ arg index; (onReturn[index] < 0.001) and: { onSum[index] < 0.001 } }) },
        "effects: a reverb at level 0 leaves the echoes: the master's input holds the delay's return at 0.7 x its level (left peaks before, at and after the echo: return %, master's input %)".format(
            onReturn.collect({ arg value; value.round(0.0001) }), onSum.collect({ arg value; value.round(0.0001) })));
    sum.free; server.sync;
    [sumBus, returnPeaks, sumPeaks].do(_.free);
    command.(\setMasterDrift, 0.01);
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    server.sync;
};

// The master leaves a steady tone steady (#306). Its drift shifter has no
// time dispersion and a window of at most 0.02 s (read from the graph: the
// comb a long window makes depends on where the drift's random walk sits,
// so a level reading could miss it). A 1 kHz sine at 0.5 on the dry bus,
// the filter, delay and reverb mixes at 0: at drift 0 the output is the
// master without its shifter (its limiter, saturation and amp on the input
// two samples late) within 1e-5, and at drift 0, 0.01 and 0.1 the output's
// level moves at most 1 dB more than that reference's.
checkMasterSteady = {
    var shifter = SynthDescLib.global.at(\strataMaster).def.children.detect({ arg ugen; ugen.isKindOf(PitchShift) });
    var bus = Bus.control(server, 5), tone, probe, values, swings;
    check.(shifter.notNil and: { shifter.inputs[4] == 0 } and: { shifter.inputs[1].isNumber } and: { shifter.inputs[1] <= 0.02 },
        "effects: the master's shifter has no time dispersion and a window of at most 0.02 s (window %, time dispersion %)".format(
            shifter !? { shifter.inputs[1] }, shifter !? { shifter.inputs[4] }));
    command.(\setFilter, 5000.0, 0.5, 0, 0.0);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    command.(\setReverb, 0.0, 0.8, 0.5, 1);
    server.sync;
    tone = Synth(\strataCheckSine, [\out, engine.mainBus, \freq, 1000], engine.processGroup, \addToTail);
    probe = Synth(\strataCheckMasterLevel, [\in, context.out_b, \clean, engine.filterBus, \out, bus], context.xg, \addAfter);
    swings = [0.0, 0.01, 0.1].collect({ arg drift;
        command.(\setMasterDrift, drift);
        server.sync; 0.5.wait;
        probe.set(\t_reset, 1); 3.0.wait;
        values = readBus.(bus);
        if (drift == 0) {
            check.((values.size == 5) and: { values[3] > 0.2 } and: { values[4] < 1e-5 },
                "effects: at drift 0 the master is its limiter and saturation alone (largest difference %, level %)".format(
                    values[4], values[3] !? { arg value; value.round(0.0001) }));
        };
        if (values.size == 5) { [db.(values[1] / values[0].max(1e-9)), db.(values[3] / values[2].max(1e-9))] } { [inf, 0] }
    });
    check.(swings.every({ arg pair; pair[0] < (pair[1] + 1) }),
        "effects: a steady 1 kHz sine leaves the master steady at drift 0, 0.01 and 0.1 (its level moves % dB; without the shifter % dB)".format(
            swings.collect(_[0]), swings.collect(_[1])));
    tone.free; probe.free; server.sync; bus.free;
    command.(\setMasterDrift, 0.01);
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    server.sync;
};

// A command's messages, captured (makeBundle(false) sends nothing) and
// then sent as they are, so a check can read what the command sent inside
// a wait as short as the bypass fade (the free comes later)
sentBy = { arg name ... args;
    var messages = server.makeBundle(false, { command.(name, *args) });
    server.sendBundle(nil, *messages);
    messages
};
// whether messages hold an /n_set of node's control to value
setsControl = { arg messages, node, control, value;
    messages.any({ arg msg; (msg[0] == 15) and: { msg[1] == node.nodeID } and: {
        msg.indexOf(control).notNil and: { msg[msg.indexOf(control) + 1].equalWithPrecision(value) } } })
};
// whether messages set no bus (3.8: no mix is broadcast, the levels are
// the nodes' own)
setsNoBus = { arg messages;
    messages.every({ arg msg; [\c_set, \c_setn, \c_fill].includes(msg[0].asString.replace("/", "").asSymbol).not })
};

// The bypass: the delay's level goes to 0 (one message, no free with it,
// no bus set), the node is freed after the fade and re-created in its
// place from the kept controls when lifted
checkBypassFrees = {
    var before, after, lifted, messages;
    command.(\setDelay, 0.3, 0.45, 0.6, 0);
    server.sync; 0.1.wait;
    before = engine.synths[\delay];
    messages = sentBy.(\setBypass, 0, 1);
    check.((engine.synths[\delay] === before) and: { setsControl.(messages, before, \mix, 0) }
        and: { setsNoBus.(messages) } and: { messages.any({ arg msg; msg[0] == 11 }).not },
        "effects: setBypass first sets the delay's level to 0, keeping the node for the fade and setting no bus (sent %)".format(
            messages));
    0.2.wait; server.sync;
    after = chainTail.value;
    check.(engine.synths[\delay].isNil and: { delayNodes.value == 0 }
        and: { after == [\strataFilter, \strataFilter, \strataFilter, \strataReverb, \strataMaster] },
        "effects: setBypass frees the delay after the mix fade (chain %)".format(after));
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = engine.synths[\delay];
    check.(lifted.notNil and: { lifted !== before } and: { delayNodes.value == 1 }
        and: { chainTail.value == [\strataFilter, \strataFilter, \strataFilter, \strataDelay, \strataReverb, \strataMaster] }
        and: { getControl.(lifted, \time).equalWithPrecision(0.3) } and: { getControl.(lifted, \feedback).equalWithPrecision(0.45) }
        and: { getControl.(lifted, \mix).equalWithPrecision(0.6) },
        "effects: setBypass frees the delay after the level's fade and re-creates it when lifted (after the reverb send's filter, with time, feedback and level kept: level %)".format(
            lifted !? { getControl.(lifted, \mix) }));
    // a lift inside the wait cancels the free: the same node, its mix back
    command.(\setBypass, 0, 1);
    command.(\setBypass, 0, 0);
    0.2.wait; server.sync;
    check.((engine.synths[\delay] === lifted) and: { delayNodes.value == 1 } and: { getControl.(lifted, \mix).equalWithPrecision(0.6) },
        "effects: a bypass lifted inside its fade cancels the free (the same node, its mix restored)");
    // others ignored
    command.(\setBypass, 2, 1); command.(\setBypass, -1, 1); command.(\setBypass, 0, 2);
    server.sync; 0.1.wait;
    check.((engine.synths[\delay] === lifted) and: { engine.synths[\reverb].notNil } and: { delayNodes.value == 1 },
        "effects: setBypass ignores any other effect or value");
};

// Lifting a bypass while audio plays starts the first echo or the tail
// without a step (#308): with a 100 Hz sine on the effect's send (the
// delay: time 0.05 s, feedback 0.4, mix 0.5; the reverb: mix 0.5, size 0.8,
// damp 0.5, the delay's mix 0; the filter, drift and the other effect out
// of the way), the largest sample step on the effect's return and at the
// output after a lift (eight lifts, each at a different point of the sine's
// cycle, each after the bypass freed the node) stays within twice the
// steady state's. The return's probe runs after the master, so the lifted
// node (the delay after the third filter, the reverb before the master)
// is always ahead of it. effect: 0 the delay, 1 the reverb.
checkLiftStartsSmoothly = { arg effect;
    var name = [\delay, \reverb][effect], words = ["delay's first echo", "reverb's tail"][effect];
    var stepBus = Bus.control(server, 1), outStepBus = Bus.control(server, 1), tone, stepProbe, outStepProbe;
    var resetBoth, readBoth, steady, lifted;
    command.(\setFilter, 5000.0, 0.5, 0, 0.0);
    command.(\setMasterDrift, 0.0);
    if (effect == 0) { command.(\setReverb, 0.0, 0.8, 0.5, 1); command.(\setDelay, 0.05, 0.4, 0.5, 0) } {
        command.(\setDelay, 0.375, 0.4, 0.0, 0); command.(\setReverb, 0.5, 0.8, 0.5, 1) };
    server.sync;
    tone = Synth(\strataCheckSine, [\out, mixBus.([\delaySend, \reverbSend][effect]), \freq, 100], engine.processGroup, \addToTail);
    stepProbe = Synth(\strataCheckStep, [\in, [engine.delayBus, engine.reverbBus][effect], \out, stepBus],
        engine.synths[\master], \addAfter);
    outStepProbe = Synth(\strataCheckStep, [\in, context.out_b, \out, outStepBus], context.xg, \addAfter);
    resetBoth = { stepProbe.set(\t_reset, 1); outStepProbe.set(\t_reset, 1) };
    readBoth = { [readBus.(stepBus)[0], readBus.(outStepBus)[0]] };
    server.sync; 1.0.wait;
    server.makeBundle(nil, { resetBoth.value }); 0.5.wait;
    steady = readBoth.value;
    lifted = 8.collect({ arg index;
        command.(\setBypass, effect, 1);
        (0.2 + (index * 0.0013)).wait; server.sync;
        server.makeBundle(nil, { resetBoth.value; command.(\setBypass, effect, 0) });
        0.4.wait;
        readBoth.value
    });
    check.(steady.every(_.notNil) and: { steady[0] > 0.0005 } and: { engine.synths[name].notNil } and: { lifted.every({ arg pair;
            pair.every(_.notNil) and: { pair[0] <= (steady[0] * 2) } and: { pair[1] <= (steady[1] * 2) } }) },
        "effects: a lifted % starts without a step (largest step on the return %, at the output %, after eight lifts; % and % in steady state)".format(
            words,
            lifted.collect(_[0]).select(_.notNil).maxItem !? { arg value; value.round(0.00001) },
            lifted.collect(_[1]).select(_.notNil).maxItem !? { arg value; value.round(0.00001) },
            steady[0] !? { arg value; value.round(0.00001) }, steady[1] !? { arg value; value.round(0.00001) }));
    tone.free; stepProbe.free; outStepProbe.free; server.sync;
    stepBus.free; outStepBus.free;
    command.(\setMasterDrift, 0.01);
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    server.sync;
};

// The bypass's free lands after the mix's lag has run out also when the
// command's handler runs late (#308's risk: the free is scheduled
// bypassFadeTime ahead on SystemClock, from the handler's own time). The
// engine's commands arrive as OSC messages (matron's, through CroneEngine's
// OSCdefs), and sclang runs an OSC handler with its thread's time set to
// when the handler runs, not when the message arrived (3.13 and 3.14.1
// alike), so the wait counts from the bundle that sets the mix to 0. Here
// /command/setBypass goes to sclang over OSC while the interpreter is kept
// busy for 100 ms, so the handler runs 100 ms late; with a 100 Hz sine on
// the delay send (time 0.05 s, feedback 0.4, mix 0.5), the largest sample
// step on the delay's return from the bypass to after the free stays within
// twice the steady state's (a free inside the fade cuts the return off:
// a step of up to the return's level), and the node is freed. Four times,
// the delay lifted and filled again in between.
checkBypassFreeTiming = {
    var stepBus = Bus.control(server, 1), tone, stepProbe, steady, results, address = NetAddr.localAddr;
    command.(\setFilter, 5000.0, 0.5, 0, 0.0);
    command.(\setMasterDrift, 0.0);
    command.(\setReverb, 0.0, 0.8, 0.5, 1);
    command.(\setDelay, 0.05, 0.4, 0.5, 0);
    server.sync;
    tone = Synth(\strataCheckSine, [\out, mixBus.(\delaySend), \freq, 100], engine.processGroup, \addToTail);
    stepProbe = Synth(\strataCheckStep, [\in, engine.delayBus, \out, stepBus], engine.synths[\master], \addAfter);
    server.sync; 1.0.wait;
    stepProbe.set(\t_reset, 1); 0.5.wait;
    steady = readBus.(stepBus)[0];
    results = 4.collect({
        var sentAt, late, step, freed;
        stepProbe.set(\t_reset, 1); server.sync;
        sentAt = Main.elapsedTime;
        address.sendMsg('/command/setBypass', 0, 1);
        while { Main.elapsedTime < (sentAt + 0.1) } { };   // the interpreter busy: the handler runs 100 ms late
        late = engine.areaState[\effects][\bypassed][\delay].not;   // it has not run yet
        0.4.wait; server.sync;
        step = readBus.(stepBus)[0];
        freed = engine.areaState[\effects][\bypassed][\delay] and: { engine.synths[\delay].isNil } and: { delayNodes.value == 0 };
        command.(\setBypass, 0, 0);
        server.sync; 1.0.wait;
        [step, late and: { freed }]
    });
    check.(steady.notNil and: { steady > 0.001 } and: { results.every({ arg each;
            each[0].notNil and: { each[0] <= (steady * 2) } and: { each[1] } }) },
        "effects: a bypass whose handler runs 100 ms late frees the delay after its fade (largest step on the return from the bypass to after the free %, % in steady state; ran late and freed %)".format(
            results.collect({ arg each; each[0] !? { arg value; value.round(0.00001) } }), steady !? { arg value; value.round(0.00001) },
            results.collect(_[1])));
    tone.free; stepProbe.free; server.sync; stepBus.free;
    command.(\setMasterDrift, 0.01);
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    server.sync;
};

// A delay line of the engine's size for a check's own \strataDelay: two
// fresh mono buffers (a node on the engine's own would write into its
// running line; a bufnum left out is buffer 0). Free them with freeLine
allocLine = { var line = 2.collect({ Buffer.alloc(server, engine.delayLineFrames, 1) }); server.sync; line };
freeLine = { arg line; line.do(_.free); server.sync };

// A node of the engine's own \strataDelay on buses and a line of its own
// (the engine's delay untouched), fed a one-sample impulse on the left in
// the same bundle as \strataCheckEchoPeaks, which reads the node's return
// in three windows (in server time, so a busy machine changes nothing; its
// /n_end ends the wait): the six peaks (window 1 left, right, ...).
// controls: the delay's (mix 1 unless given)
echoPeaks = { arg controls, windows;
    var group = Group.after(context.xg), inBus = Bus.audio(server, 2), outBus = Bus.audio(server, 2);
    var resultBus = Bus.control(server, 6), condition = Condition(false), seconds = windows.last + 0.05, values;
    var line = allocLine.value;
    resultBus.setAll(0);
    server.sync;
    server.makeBundle(nil, {
        var analysis;
        Synth(\strataCheckLeftImpulse, [\out, inBus], group, \addToTail);
        Synth(\strataDelay, [\in, inBus, \out, outBus, \bufL, line[0], \bufR, line[1], \mix, 1] ++ controls, group,
            \addToTail);
        analysis = Synth(\strataCheckEchoPeaks, [\in, outBus, \out, resultBus, \windows, windows, \seconds, seconds],
            group, \addToTail);
        OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr, argTemplate: [analysis.nodeID]).oneShot;
    });
    awaitReply.(condition, seconds * 10);
    values = readBus.(resultBus);
    group.free; server.sync;
    [inBus, outBus, resultBus].do(_.free);
    freeLine.(line);
    values
};

// At pingPong 1 the input is summed into the left line and each line feeds
// the other, so an impulse on the left comes back left after the time,
// then right, then left; at 0 (today's graph) it stays on the left. Time
// 0.1 s, feedback 0.9: the peaks around 0.1, 0.2 and 0.3 s (the feedback
// loop adds a block a pass), each on its side with the other under -60 dB
checkPingPong = {
    var windows = [0.09, 0.11, 0.19, 0.21, 0.29, 0.31];
    var alternate = echoPeaks.([\time, 0.1, \feedback, 0.9, \pingPong, 1], windows);
    var plain = echoPeaks.([\time, 0.1, \feedback, 0.9, \pingPong, 0], windows);
    var sides = { arg peaks, wanted; (peaks.size == 6) and: { wanted.every({ arg side, index;
        var on = peaks[(index * 2) + side], off = peaks[(index * 2) + (1 - side)];
        (on > 0.5) and: { off < (on * 0.001) } }) } };
    check.(sides.(alternate, [0, 1, 0]),
        "effects: at pingPong 1 an impulse on the left repeats left, then right, then left (peaks L, R at 0.1, 0.2, 0.3 s: %)".format(
            alternate.collect({ arg value; value.round(0.0001) })));
    check.(sides.(plain, [0, 0, 0]),
        "effects: at pingPong 0 an impulse on the left repeats on the left alone, as before (peaks L, R at 0.1, 0.2, 0.3 s: %)".format(
            plain.collect({ arg value; value.round(0.0001) })));
};

// pingPong is kept with the other three: a bypass lifted re-creates the
// node with it, and one sent while bypassed comes back at the lift
checkPingPongKept = {
    var lifted, again;
    command.(\setDelay, 0.3, 0.45, 0.6, 0.7);
    server.sync;
    command.(\setBypass, 0, 1);
    0.2.wait; server.sync;
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = engine.synths[\delay] !? { arg synth; getControl.(synth, \pingPong) };
    command.(\setBypass, 0, 1);
    0.2.wait; server.sync;
    command.(\setDelay, 0.3, 0.45, 0.6, 0.35);
    server.sync;
    command.(\setBypass, 0, 0);
    server.sync;
    again = engine.synths[\delay] !? { arg synth; getControl.(synth, \pingPong) };
    check.(lifted.notNil and: { lifted.equalWithPrecision(0.7) } and: { again.notNil } and: { again.equalWithPrecision(0.35) },
        "effects: pingPong is kept through a bypass and its lift (lifted %, set while bypassed then lifted %)".format(lifted, again));
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    server.sync;
};

// The delay line holds 5.4 s (3.8 design §0.2): an impulse comes back at
// 5.4 s and nowhere else (3.7's 2.7 s clip would return it at 2.7 s, in the
// first window): the peaks before, at and after 5.4 s
checkLongDelay = {
    var peaks = echoPeaks.([\time, 5.4, \feedback, 0], [0, 5.38, 5.39, 5.41, 5.42, 5.6]);
    check.((peaks.size == 6) and: { peaks[2] > 0.5 } and: { [0, 1, 3, 4, 5].every({ arg index; peaks[index] < 0.0005 }) },
        "effects: a time of 5.4 s is reached (peaks L, R before, at and after 5.4 s: %)".format(
            peaks.collect({ arg value; value.round(0.0001) })));
};

// The largest absolute sample a buffer holds (read through a file)
lineMax = { arg buffer;
    var condition = Condition(false), peak;
    buffer.loadToFloatArray(action: { arg array; peak = array.abs.maxItem; condition.test = true; condition.signal });
    awaitReply.(condition, 10);
    peak
};

// The delay's line is two mono buffers of delayLineFrames (2^18) the effects
// area allocates once and reads with BufDelayC: the node runs on them, and
// a bypass and its lift keep them (bufnums never change). The free's bundle
// empties them (emptyDelayLine): with pink noise on the delay send the line
// holds audio, and after the free it holds none
checkDelayLine = {
    var line = engine.delayLine, ugens = SynthDescLib.global.at(\strataDelay).def.children;
    var bufnums = line !? { line.collect(_.bufnum) }, nodeBufnums, first, lifted, noise, filled, emptied;
    nodeBufnums = { engine.synths[\delay] !? { arg synth; [getControl.(synth, \bufL), getControl.(synth, \bufR)] } };
    first = nodeBufnums.value;
    noise = Synth(\strataCheckPinkNoise, [\out, mixBus.(\delaySend)], engine.processGroup, \addToTail);
    server.sync; 0.5.wait;
    filled = line !? { line.collect({ arg buffer; lineMax.(buffer) }) };
    noise.free; server.sync;
    command.(\setBypass, 0, 1);
    0.2.wait; server.sync;
    emptied = line !? { line.collect({ arg buffer; lineMax.(buffer) }) };
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = nodeBufnums.value;
    check.(line.notNil and: { line.size == 2 } and: { line.every({ arg buffer; (buffer.numFrames == 262144)
            and: { buffer.numChannels == 1 } }) } and: { first == bufnums } and: { lifted == bufnums }
        and: { engine.delayLine.collect(_.bufnum) == bufnums }
        and: { ugens.count({ arg ugen; ugen.class == BufDelayC }) == 2 } and: { ugens.any({ arg ugen; ugen.class == DelayC }).not },
        "effects: the delay's line is two buffers of 262144 frames, one channel each, whose bufnums a bypass and its lift keep (frames %, channels %, bufnums %; the node's % and, lifted, %; BufDelayC lines %)".format(
            line !? { line.collect(_.numFrames) }, line !? { line.collect(_.numChannels) }, bufnums, first, lifted,
            ugens.count({ arg ugen; ugen.class == BufDelayC })));
    check.(filled.notNil and: { filled.every({ arg peak; peak.notNil and: { peak > 0.01 } }) }
        and: { emptied.every({ arg peak; peak == 0 }) },
        "effects: a bypass's free empties the delay's line (largest sample with noise on the send %, after the free %)".format(
            filled, emptied));
};

// A player bypasses the delay mid-echo and lifts it after the free: the
// lift plays nothing of the old line. An impulse on the delay send at
// feedback 0.9 and mix 1 (its echoes heard at 0.5 and 1 s), a bypass past
// its free, a lift; then the return stays under -60 dB for 5.5 s, a line's
// length and more
checkLiftStartsEmpty = {
    var heardBus = Bus.control(server, 6), afterBus = Bus.control(server, 6), condition = Condition(false), heard, after;
    command.(\setFilter, 5000.0, 0.5, 0, 0.0);
    command.(\setMasterDrift, 0.0);
    command.(\setReverb, 0.0, 0.8, 0.5, 1);
    command.(\setDelay, 0.5, 0.9, 1.0, 0);
    heardBus.setAll(0); afterBus.setAll(0);
    server.sync; 0.3.wait;
    server.makeBundle(nil, {
        Synth(\strataCheckLeftImpulse, [\out, mixBus.(\delaySend)], engine.processGroup, \addToTail);
        Synth(\strataCheckEchoPeaks, [\in, engine.delayBus, \out, heardBus, \windows, [0.45, 0.6, 0.95, 1.1, 1.1, 1.2],
            \seconds, 1.25], engine.synths[\master], \addAfter);
    });
    1.3.wait; server.sync;
    heard = readBus.(heardBus);
    command.(\setBypass, 0, 1);
    0.2.wait; server.sync;
    server.makeBundle(nil, {
        var analysis;
        command.(\setBypass, 0, 0);
        analysis = Synth(\strataCheckEchoPeaks, [\in, engine.delayBus, \out, afterBus, \windows, [0, 1.8, 1.8, 3.6, 3.6, 5.5],
            \seconds, 5.55], engine.synths[\master], \addAfter);
        OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr, argTemplate: [analysis.nodeID]).oneShot;
    });
    awaitReply.(condition, 60);
    after = readBus.(afterBus);
    check.((heard.size == 6) and: { heard[0] > 0.3 } and: { heard[2] > 0.3 } and: { after.size == 6 }
        and: { after.every({ arg peak; peak < 0.001 }) },
        "effects: a lifted delay starts empty (the echoes before the bypass %, the return's peaks in 5.5 s after the lift %)".format(
            heard.collect({ arg value; value.round(0.0001) }), after.collect({ arg value; value.round(0.000001) })));
    heardBus.free; afterBus.free;
    command.(\setMasterDrift, 0.01);
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    command.(\setDelay, 0.375, 0.4, 0.0, 0);
    server.sync;
};

// The buffer line plays what 3.7's DelayC played: the engine's \strataDelay
// on a line of its own beside a check-only copy of 3.7's def, both on the
// same pink noise for 5.5 s, feedback 0.4, ping-pong 0.5, at a fractional
// fixed time (0.30928 s) and on a 0.5 Hz LFO (0.2-0.4 s): largest
// difference 0 (both interpolate a power-of-two line with the same cubic)
checkLineAsDelayC = {
    var compare = { arg lfo;
        var group = Group.after(context.xg), noiseBus = Bus.audio(server, 2), outA = Bus.audio(server, 2);
        var outB = Bus.audio(server, 2), timeBus = Bus.control(server, 1), resultBus = Bus.control(server, 2);
        var line = allocLine.value, condition = Condition(false), seconds = 5.5, values;
        var controls = [\time, 0.30928, \feedback, 0.4, \pingPong, 0.5, \mix, 1];
        resultBus.setAll(0);
        server.sync;
        server.makeBundle(nil, {
            var copy, node, analysis;
            if (lfo) { Synth(\strataCheckTimeLfo, [\out, timeBus], group, \addToTail) };
            Synth(\strataCheckPinkNoise, [\out, noiseBus], group, \addToTail);
            copy = Synth(\strataCheckDelayC37, [\in, noiseBus, \out, outA] ++ controls, group, \addToTail);
            node = Synth(\strataDelay, [\in, noiseBus, \out, outB, \bufL, line[0], \bufR, line[1]] ++ controls, group,
                \addToTail);
            if (lfo) { copy.map(\time, timeBus); node.map(\time, timeBus) };
            analysis = Synth(\strataCheckDiffPeak, [\inA, outA, \inB, outB, \out, resultBus, \seconds, seconds], group,
                \addToTail);
            OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr, argTemplate: [analysis.nodeID]).oneShot;
        });
        awaitReply.(condition, seconds * 10);
        values = readBus.(resultBus);
        group.free; server.sync;
        [noiseBus, outA, outB, timeBus, resultBus].do(_.free);
        freeLine.(line);
        values
    };
    var fixed = compare.(false), moving = compare.(true);
    check.([fixed, moving].every({ arg values; (values.size == 2) and: { values[0] == 0 } and: { values[1] > 0.1 } }),
        "effects: the buffer line plays what DelayC played (largest difference at 0.30928 s %, on a 0.5 Hz LFO %; largest return % and %)".format(
            fixed[0], moving[0], fixed[1] !? { arg value; value.round(0.001) }, moving[1] !? { arg value; value.round(0.001) }));
};

// Toggled at 20 Hz for 2 s, the delay never has two nodes, and once it
// settles bypassed none
checkBypassToggling = {
    var most = 0, bypassed = 0, created;
    41.do({ arg index;
        bypassed = 1 - bypassed;
        command.(\setBypass, 0, bypassed);
        most = most.max(delayNodes.value);
        0.04.wait;
    });
    0.3.wait; server.sync;
    check.((most <= 1) and: { bypassed == 1 } and: { delayNodes.value == 0 } and: { engine.synths[\delay].isNil },
        "effects: 20 Hz bypass toggling for 2 s keeps at most one delay node and none once bypassed (most %, at the end %)".format(
            most, delayNodes.value));
    command.(\setBypass, 0, 0);
    server.sync;
    check.((delayNodes.value == 1) and: { engine.synths[\delay].notNil }, "effects: and lifting it brings one back");
    // at about 15 Hz each bypass outlasts the fade (bypassFadeTime, about
    // 51 ms), so its free is sent and the next lift creates a new node
    most = 0; bypassed = 0;
    created = IdentitySet[engine.synths[\delay]];
    31.do({
        bypassed = 1 - bypassed;
        command.(\setBypass, 0, bypassed);
        if (bypassed == 0) { created.add(engine.synths[\delay]) };
        0.067.wait;
        most = most.max(delayNodes.value);
    });
    0.3.wait; server.sync;
    check.((most <= 1) and: { created.size >= 8 } and: { delayNodes.value == 0 } and: { engine.synths[\delay].isNil },
        "effects: 15 Hz bypass toggling frees and re-creates the delay, never two nodes and none once bypassed (most %, % nodes made, at the end %)".format(
            most, created.size, delayNodes.value));
    command.(\setBypass, 0, 0);
    server.sync;
    check.((delayNodes.value == 1) and: { engine.synths[\delay].notNil }, "effects: and lifting it brings one back again");
};

// An LFO-rate series of setDelays taking the level through 0 and back never
// frees the delay node: at 0 the node runs at level 0
checkMixThroughZero = {
    var node = engine.synths[\delay], zeroLevel;
    50.do({ arg index;
        var mix = (0.4 * sin(index * 0.5)).max(0);
        command.(\setDelay, 0.3, 0.45, mix, 0);
        if (index == 7) { server.sync; zeroLevel = getControl.(node, \mix) };
        0.02.wait;
    });
    server.sync; 0.2.wait;
    check.((engine.synths[\delay] === node) and: { delayNodes.value == 1 } and: { zeroLevel == 0 }
        and: { h.synthTree(context.xg).any({ arg each; each[\id] == node.nodeID }) },
        "effects: a level swept through 0 never frees the node (the node's level at 0: %)".format(zeroLevel));
};

// setDelay during the fade and after the free: the values are kept, the
// level sent stays 0 (no bus is set), and the lift brings them back
checkSetWhileBypassed = {
    var fading = engine.synths[\delay], kept, lifted, messages;
    command.(\setBypass, 0, 1);
    messages = sentBy.(\setDelay, 0.2, 0.3, 0.7, 0);
    check.(setsControl.(messages, fading, \mix, 0) and: { setsControl.(messages, fading, \time, 0.2) }
        and: { setsNoBus.(messages) },
        "effects: setDelay during the bypass fade sets the time and keeps the level at 0, setting no bus (sent %)".format(messages));
    0.2.wait; server.sync;
    command.(\setDelay, 0.5, 0.6, 0.8, 0);
    server.sync;
    kept = engine.areaState[\effects][\controls][\delay].atAll([\time, \feedback, \mix]);
    check.(engine.synths[\delay].isNil and: { delayNodes.value == 0 } and: { kept == [0.5, 0.6, 0.8] },
        "effects: setDelay while bypassed stores its values, with no node to set (kept %)".format(kept));
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = engine.synths[\delay];
    check.(lifted.notNil and: { getControl.(lifted, \time).equalWithPrecision(0.5) }
        and: { getControl.(lifted, \feedback).equalWithPrecision(0.6) } and: { getControl.(lifted, \mix).equalWithPrecision(0.8) },
        "effects: and the lift creates the delay with them (level %)".format(lifted !? { getControl.(lifted, \mix) }));
};

// The reverb's bypass: its node is freed and re-created before the master;
// the delay is untouched; setReverb while bypassed is kept, all four of its
// values (3.8: delay to reverb among them)
checkReverbBypass = {
    var delay = engine.synths[\delay], before = engine.synths[\reverb], kept, lifted, messages;
    command.(\setReverb, 0.4, 0.7, 0.3, 1);
    messages = sentBy.(\setBypass, 1, 1);
    check.(setsControl.(messages, before, \mix, 0) and: { setsNoBus.(messages) },
        "effects: setBypass sets the reverb's level to 0 for its fade, setting no bus (sent %)".format(messages));
    0.2.wait; server.sync;
    command.(\setReverb, 0.35, 0.6, 0.2, 0.25);
    server.sync;
    kept = engine.areaState[\effects][\controls][\reverb].atAll([\mix, \size, \damp, \delayToReverb]);
    check.(engine.synths[\reverb].isNil and: { h.synthNames(context.xg).includes(\strataReverb).not }
        and: { engine.synths[\delay] === delay } and: { kept == [0.35, 0.6, 0.2, 0.25] },
        "effects: setBypass frees the reverb after its fade and leaves the delay; setReverb while bypassed is kept (kept %)".format(kept));
    command.(\setBypass, 1, 0);
    server.sync;
    lifted = engine.synths[\reverb];
    check.(lifted.notNil and: { lifted !== before } and: { lifted.defName.asSymbol == \strataReverb }
        and: { chainTail.value == [\strataFilter, \strataFilter, \strataFilter, \strataDelay, \strataReverb, \strataMaster] }
        and: { getControl.(lifted, \mix).equalWithPrecision(0.35) } and: { getControl.(lifted, \size).equalWithPrecision(0.6) }
        and: { getControl.(lifted, \damp).equalWithPrecision(0.2) } and: { getControl.(lifted, \delayToReverb).equalWithPrecision(0.25) },
        "effects: lifting the reverb's bypass re-creates it before the master with the kept controls, delay to reverb among them (level %, delay to reverb %)".format(
            lifted !? { getControl.(lifted, \mix) }, lifted !? { getControl.(lifted, \delayToReverb) }));
    command.(\setReverb, 0.43, 0.8, 0.5, 1);
    server.sync;
};

// The FDN (the high tier's reverb) against FreeVerb2, both fully wet at
// size 0.8 and damp 0.5: the RT60 of the impulse response's energy envelope
// (T30: twice the time from -5 to -35 dB, as the blocks the envelope spends
// above each level) within 30%. Also each one's pool size
// (the small probes that fit with and without one), and a high engine
// runs the FDN, also after a bypass is lifted.
checkFdn = {
    // Both defs (inA, inB) in one group, created in one bundle: one impulse
    // on one bus that both read, each def writing its own bus, and one
    // \strataCheckDecayTimes after them. Everything is counted in server
    // blocks and the wait ends on the analysis synth's /n_end, so a busy
    // machine (a late server, a late sclang) changes nothing. A 3 s window
    // holds T30 (-35 dB about 1.1-1.3 s after -5 dB at RT60 1.9-2.2 s).
    var rt60s = { arg defNames;
        var seconds = 3, blocks = (seconds * server.sampleRate / server.options.blockSize).asInteger;
        var group = Group.after(context.xg), inBus = Bus.audio(server, 2), nothing = Bus.audio(server, 2);
        var outBuses = defNames.collect({ Bus.audio(server, 2) }), resultBus = Bus.control(server, 4 * defNames.size);
        var condition = Condition(false), values;
        resultBus.setAll(0);
        server.sync;
        server.makeBundle(nil, {
            var analysis;
            Synth(\strataCheckImpulse, [\out, inBus], group, \addToTail);
            defNames.do({ arg defName, index;
                Synth(defName, [\in, inBus, \delayIn, nothing, \out, outBuses[index], \mix, 1, \size, 0.8, \damp, 0.5],
                    group, \addToTail)
            });
            analysis = Synth(\strataCheckDecayTimes, [\inA, outBuses[0], \inB, outBuses[1], \out, resultBus,
                \blocks, blocks], group, \addToTail);
            OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr, argTemplate: [analysis.nodeID])
                .oneShot;
        });
        awaitReply.(condition, seconds * 10);
        values = readBus.(resultBus);
        group.free; server.sync;
        ([inBus, nothing, resultBus] ++ outBuses).do(_.free);
        defNames.collect({ arg defName, index;
            var above5, above35, reached, peak;
            #above5, above35, reached, peak = values.copyRange(index * 4, (index * 4) + 3);
            if ((values.size == (4 * defNames.size)) and: { reached == 1 } and: { peak > 0 }) {
                2 * (above35 - above5) * server.options.blockSize / server.sampleRate
            }
        })
    };
    var poolKB = { arg defName;
        var inBus = Bus.audio(server, 2), outBus = Bus.audio(server, 2), without, with, synth;
        without = floodFit.value;
        synth = Synth(defName, [\in, inBus, \delayIn, inBus, \out, outBus], engine.processGroup, \addToTail);
        server.sync; 0.05.wait;
        with = floodFit.value;
        synth.free; server.sync; inBus.free; outBus.free;
        (without - with) * probeKB
    };
    var rt60 = rt60s.([\strataReverb, \strataReverbFDN]), freeverb = rt60[0], fdn = rt60[1];
    var freeverbKB = poolKB.(\strataReverb), fdnKB = poolKB.(\strataReverbFDN);
    var root = h.tempDir +/+ "effects-high/", write, high, highReverb;
    check.(freeverb.notNil and: { fdn.notNil } and: { (fdn / freeverb).inclusivelyBetween(0.7, 1.3) },
        "effects: the FDN's RT60 is within 30\\% of FreeVerb2's at size 0.8 (FDN % s, FreeVerb2 % s, ratio %; pool: FDN about % KB, FreeVerb2 about % KB)".format(
            fdn !? { arg value; value.round(0.01) }, freeverb !? { arg value; value.round(0.01) },
            (fdn.notNil and: { freeverb.notNil }).if({ (fdn / freeverb).round(0.001) }), fdnKB.round(1), freeverbKB.round(1)));
    check.(fdnKB < 512, "effects: the FDN takes under 512 KB of the pool (about % KB)".format(fdnKB.round(1)));
    // a high engine's reverb
    write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 16\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    high = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    highReverb = high.synths[\reverb] !? { arg synth; synth.defName.asSymbol };
    // the high engine's fresh reverb node, as checkFreshDefaults reads the standard one's
    {
        var fresh = [\mix, \size, \damp, \delayToReverb].collect({ arg name;
            high.synths[\reverb] !? { arg synth; getControl.(synth, name) } });
        check.(fresh.every(_.notNil) and: { [fresh, [0.43, 0.8, 0.5, 1]].flop.every({ arg pair;
                pair[0].equalWithPrecision(pair[1], 1e-6) }) },
            "effects: a fresh high engine's FDN starts at level 0.43, size 0.8, damp 0.5 and delay to reverb 1 (got %)".format(fresh));
    }.value;
    h.commandTo(high, \setBypass, 1, 1);
    0.2.wait; server.sync;
    h.commandTo(high, \setBypass, 1, 0);
    server.sync;
    check.((high.tier == \high) and: { highReverb == \strataReverbFDN }
        and: { high.synths[\reverb] !? { arg synth; synth.defName.asSymbol } == \strataReverbFDN }
        and: { engine.synths[\reverb].defName.asSymbol == \strataReverb },
        "effects: the high tier runs the FDN reverb (also after a bypass is lifted) and standard FreeVerb2 (got %, %)".format(
            highReverb, high.synths[\reverb] !? { arg synth; synth.defName }));
    // The FDN takes delayToReverb of the delay's return (3.8): a unit
    // impulse on the high engine's delay return alone (written just before
    // its reverb node), the reverb at level 1, size 0.8, damp 0.5: at
    // delayToReverb 0 the FDN's return stays silent, at 1 its tail sounds.
    // The peaks of the return in three windows over 1.5 s, read on the
    // server (\strataCheckEchoPeaks, its /n_end ends the wait)
    {
        var tail = { arg k;
            var resultBus = Bus.control(server, 6), condition = Condition(false), values;
            resultBus.setAll(0);
            h.commandTo(high, \setReverb, 1.0, 0.8, 0.5, k);
            server.sync; 0.3.wait;
            server.makeBundle(nil, {
                var analysis;
                Synth(\strataCheckImpulse, [\out, high.delayBus], high.synths[\reverb], \addBefore);
                analysis = Synth(\strataCheckEchoPeaks, [\in, high.reverbBus, \out, resultBus,
                    \windows, [0, 0.5, 0.5, 1, 1, 1.5], \seconds, 1.55], high.synths[\reverb], \addAfter);
                OSCFunc({ condition.test = true; condition.signal }, '/n_end', server.addr,
                    argTemplate: [analysis.nodeID]).oneShot;
            });
            awaitReply.(condition, 20);
            values = readBus.(resultBus);
            resultBus.free;
            values
        };
        var none = tail.(0), some = tail.(1);
        check.((none.size == 6) and: { none.every({ arg peak; peak < 1e-6 }) } and: { some.size == 6 }
            and: { some.maxItem > 0.001 },
            "effects: the FDN takes delay to reverb of the delay's return: an impulse on the return alone leaves it silent at 0 and sounds at 1 (peaks at 0 %, at 1 %)".format(
                none.collect({ arg value; value.round(0.000001) }), some.collect({ arg value; value.round(0.0001) })));
        h.commandTo(high, \setReverb, 0.43, 0.8, 0.5, 1);
        server.sync;
    }.value;
    h.freeEngine(high);
    server.sync;
    check.([\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].every({ arg name; high.mixBus(name).index.isNil }),
        "effects: free frees the mix area's buses");
};

check.(SynthDescLib.global.at(\strataMaster).def.children.any({ arg ugen; ugen.isKindOf(Limiter) }),
    "master has a Limiter safety stage");
// The limiter must feed the tanh saturator: after it, tanh * 0.5 already
// bounds the signal and the limiter could never act
masterUGens = SynthDescLib.global.at(\strataMaster).def.children;
check.(masterUGens.detectIndex({ arg ugen; ugen.isKindOf(Limiter) })
    < masterUGens.detectIndex({ arg ugen; ugen.isKindOf(UnaryOpUGen) and: { ugen.operator == \tanh } }),
    "master limits before the tanh saturation");
// "effects: the filter and send controls feed a UGen", in the stage; each
// grain def has one stereo Out (its path), the stage five (dry, the two
// sends, the mirror and the tap)
check.([\filterType, \filterFreq, \filterRes, \filterMix, \dry, \delaySend, \reverbSend].every({ arg control;
    h.controlFeedsAUGen(\strataVoiceMix, control) }), "effects: the filter, dry and send controls feed a UGen");
check.(engine.masterSumGain == 0.7, "effects: masterSum's gain is 0.7, 3.7's dry share (design section 7.1)");
check.(h.grainDefs.every({ arg name;
    SynthDescLib.global.at(name).def.children.select({ arg ugen; ugen.isKindOf(Out) }).size == 1 })
    and: { SynthDescLib.global.at(\strataVoiceMix).def.children.select({ arg ugen; ugen.isKindOf(Out) }).size == 5 },
    "effects: each grain def writes one path; the stage writes the dry bus, the two sends, the mirror and the tap");

// The defaults a fresh engine starts with, then the plain chain at three
// amounts of the delay into the reverb, the default balance, the plain
// sends and the echoes without the reverb, with no voice running
checkFreshDefaults.value;
probeKB = smallProbeKB.value;
[0, 0.5, 1].do({ arg k; checkPlainChain.(k) });
checkDefaultBalance.value;
checkPlainSends.value;
checkEchoesWithoutReverb.value;
checkPingPong.value;

h.startAllVoices;
checkRouting.value;

// Back to the defaults after the plain chain and the sends (the defaults
// themselves are checkFreshDefaults'): setReverb sets all four of the
// reverb's controls
command.(\setFilter, 5000.0, 0.5, 0, 0.0);
command.(\setDelay, 0.375, 0.4, 0.0, 0);
command.(\setReverb, 0.4, 0.7, 0.3, 0.6);
server.sync;
{
    var got = [\mix, \size, \damp, \delayToReverb].collect({ arg name; getControl.(engine.synths[\reverb], name) });
    check.((got.size == 4) and: { [got, [0.4, 0.7, 0.3, 0.6]].flop.every({ arg pair;
            pair[0].notNil and: { pair[0].equalWithPrecision(pair[1], 1e-6) } }) },
        "effects: setReverb sets the reverb's level, size, damping and delay to reverb (got %)".format(got));
}.value;
command.(\setReverb, 0.43, 0.8, 0.5, 1);
server.sync;

command.(\setFilter, 800.0, 0.2, 1, 1.0);
server.sync;
check.([\filter, \filterDelay, \filterReverb].every({ arg key;
    var synth = engine.synths[key];
    (getControl.(synth, \filterType) == 1) and: { getControl.(synth, \freq) == 800.0 }
        and: { getControl.(synth, \res).equalWithPrecision(0.2) } and: { getControl.(synth, \mix) == 1.0 }
}), "effects: setFilter sets all three master filters");
command.(\setDelay, 0.25, 0.5, 0.5, 0.25);
server.sync;
check.(getControl.(engine.synths[\delay], \time) == 0.25, "setDelay sets time");
check.(getControl.(engine.synths[\delay], \feedback) == 0.5, "setDelay sets feedback");
check.(getControl.(engine.synths[\delay], \mix) == 0.5, "setDelay sets mix");
check.(getControl.(engine.synths[\delay], \pingPong) == 0.25, "setDelay sets pingPong");
// A non-finite argument leaves the delay as it was, with one line each (the
// final review's engine Minor 3): a NaN in its lag or feedback loop would
// stay in the node until a bypass re-created it
{
    var lines = List.new, modulation = engine.areaState[\modulation], previous = modulation[\postIgnored];
    var controls = [\time, \feedback, \mix, \pingPong], kept = engine.areaState[\effects][\controls][\delay].copy, before, after;
    var nan = 0.0 / 0.0;
    before = controls.collect({ arg name; getControl.(engine.synths[\delay], name) });
    modulation[\postIgnored] = { arg line; lines.add(line) };
    {
        [[nan, 0.5, 0.5, 0.25], [0.25, inf, 0.5, 0.25], [0.25, 0.5, nan, 0.25], [0.25, 0.5, 0.5, -inf]].do({ arg values;
            command.(\setDelay, *values) });
    }.protect({ modulation[\postIgnored] = previous });
    server.sync;
    after = controls.collect({ arg name; getControl.(engine.synths[\delay], name) });
    check.((lines.size == 4) and: { lines.every({ arg line; line.beginsWith("strata: setDelay ignored: ") }) }
        and: { after == before } and: { engine.areaState[\effects][\controls][\delay] == kept },
        "effects: setDelay with a non-finite argument is ignored, one line each (lines %; controls % then %)".format(
            lines.asArray, before, after));
}.value;
command.(\setDelay, 0.25, 0.5, 0.5, 0);

checkFilterTypes.value;
checkFilterCrossfade.([[\strataFilter, "filter type changes crossfade"],
    [\strataCheckVoiceFilter, "effects: the voice filter crossfades types in 20 ms"]]);
checkCutoffStep.value;
checkFilterAsBefore.value;
checkEffectsGuard.value;
checkEffectSendsReported.value;
h.stopAllVoices;

checkMasterSteady.value;
checkBypassFrees.value;
checkLiftStartsSmoothly.(0);
checkBypassFreeTiming.value;
checkDelayLine.value;
checkLongDelay.value;
checkLiftStartsEmpty.value;
checkLineAsDelayC.value;
checkBypassToggling.value;
checkMixThroughZero.value;
checkSetWhileBypassed.value;
checkPingPongKept.value;
checkReverbBypass.value;
checkLiftStartsSmoothly.(1);
checkFdn.value;

// back to the Lua defaults for the areas that follow, nothing bypassed
command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
command.(\setFilter, 5000.0, 0.5, 0, 0.0);
command.(\setDelay, 0.375, 0.4, 0.0, 0);
command.(\setReverb, 0.43, 0.8, 0.5, 1);
command.(\setMasterDrift, 0.01);
server.sync;
}
