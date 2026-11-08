// test/engine_check/effects.scd
// The mix and the effects chain: the master limiter before the saturator,
// the bus routing (three master filters, the delay and reverb returns, the
// master sum), the defaults the Lua params assume, setFilter on all three
// filters, setDelay, the filter type crossfades (master and voice), the NaN
// guards, plain sends to the effects chain's synths, the sends against
// check-only copies of 3.0's chain, the explicit bypass (it frees and
// re-creates a node, a mix of 0 never does), and the high tier's FDN reverb
// against FreeVerb2.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var readBus = { arg bus; h.readBus(bus) };
var measure = { arg probe, bus, seconds = 0.3; h.measure(probe, bus, seconds) };
var mixBus = { arg name; engine.mixBus(name) };
var masterUGens, readStep;
var checkFilterCrossfade, checkEffectsGuard, checkEffectSendsReported, checkRouting, checkChain30, checkDrySends;
var checkBypassFrees, checkBypassMemory, checkBypassToggling, checkMixThroughZero, checkSetWhileBypassed;
var checkReverbBypass, checkFdn, chainTail, delayNodes, floodFit, smallProbeKB, probeKB;
var sentBy, setsControl, broadcasts;
var floodCount = 640;

// The defs in xg, in node order, from the filter on (the chain at its tail)
chainTail = {
    var names = h.synthNames(context.xg);
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

// Check-only copies of 3.0's chain (lib/Engine_Strata.sc at 3.1.0): the
// filter, the delay and the reverb crossfading their own dry and wet
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
SynthDef(\strataCheck30Delay, { arg in, out, time=0.375, feedback=0.4, mix=0;
    var dry, delayed, wet;
    dry = In.ar(in, 2);
    delayed = DelayC.ar(dry + LocalIn.ar(2), 2, time.lag(0.1).clip(0.01, 2));
    LocalOut.ar(delayed * feedback.clip(0, 0.95));
    wet = mix.lag(0.05).clip(0, 1);
    Out.ar(out, dry + ((delayed - dry) * wet));
}).add;
SynthDef(\strataCheck30Reverb, { arg in, out, mix=0.3, size=0.8, damp=0.5;
    var sig = In.ar(in, 2);
    Out.ar(out, FreeVerb2.ar(sig[0], sig[1], mix, size, damp));
}).add;
// A stand-in grain synth: bursts of noise and a tone (raw, also written to
// the raw bus) through the engine's voiceOutput with the given sends; its
// buses are controls (voiceOutput's named controls, set from
// mixBusControls), so a check can move them to private buses
SynthDef(\strataCheckChainSource, { arg out, raw, junk, delaySend = 1, reverbSend = 1;
    var sig = ({ WhiteNoise.ar(0.15) } ! 2) * LFPulse.kr(3, 0, 0.3).lag(0.005) + SinOsc.ar([330, 331], 0, 0.08);
    Out.ar(raw, sig);
    engine.voiceOutput(sig, out, junk, 0, delaySend, reverbSend);
}).add;
// The master's input (masterSum, as \strataMaster sums it) on the given buses
SynthDef(\strataCheckMasterSum, { arg in, delayIn, reverbIn, fxMix, out;
    Out.ar(out, engine.masterSum(in, delayIn, reverbIn, fxMix));
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
// A 10 ms noise burst, once
SynthDef(\strataCheckBurst, { arg out;
    Out.ar(out, ({ WhiteNoise.ar(0.5) } ! 2) * EnvGen.ar(Env.perc(0.001, 0.01), doneAction: 2));
}).add;
// The energy envelope of a stereo bus (20 ms lag), recorded at control rate
SynthDef(\strataCheckEnvelopeRecord, { arg in, buffer;
    RecordBuf.kr(A2K.kr(Lag.ar(In.ar(in, 2).squared.sum, 0.02)), buffer, loop: 0, doneAction: 2);
}).add;
server.sync;

// The largest sample step a filter of def (fully wet, a 1 kHz sine at its
// cutoff, where lowpass and highpass are in antiphase) takes while its type
// changes, against the largest in any type's steady state. Each [defName,
// message] pair runs in its own group on its own buses, all at once (the
// same type changes at the same times), so the defs share one timeline.
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
        check.(switchStep <= (steadySteps.maxItem * 1.1),
            "% (largest step % while switching, % at most in steady state %)".format(
                run[\message], switchStep.round(0.0001), steadySteps.maxItem.round(0.0001), steadySteps.round(0.0001)));
    });
    runs.do({ arg run; run[\group].free; run[\buses].do(_.free) });
};
// the largest step since the probe on bus was last reset
readStep = { arg bus;
    var condition = Condition(false), value;
    bus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
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
        and: { getControl.(master, \reverbIn) == engine.reverbBus.index } and: { getControl.(master, \fxMix) == mixBus.(\fxMix).index },
        "effects: the master sums the filtered dry bus and the two returns, reading the mixes from fxMix");
    check.(chainTail.value == [\strataFilter, \strataFilter, \strataFilter, \strataDelay, \strataReverb, \strataMaster],
        "effects: xg ends filter x3 -> delay -> reverb -> master (got %)".format(chainTail.value));
    check.((mixBus.(\dry) === engine.mainBus) and: { mixBus.(\dryPost) === engine.filterBus }
        and: { mixBus.(\delayReturn) === engine.delayBus } and: { mixBus.(\reverbReturn) === engine.reverbBus }
        and: { mixBus.(\fxMix).numChannels == 2 } and: { mixBus.(\fxMix).rate == \control }
        and: { [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].every({ arg name;
            (mixBus.(name).numChannels == 2) and: { mixBus.(name).rate == \audio } }) },
        "effects: areaState[\\mix] holds the stereo send buses, their ...Post copies, the returns and fxMix (2 channels)");
    // every grain synth the engine starts takes this engine's buses
    check.((0..(engine.numVoices - 1)).every({ arg voice;
        var synth = engine.synths[engine.grainKey(voice)];
        synth.notNil and: { getControl.(synth, \delaySendOut) == mixBus.(\delaySend).index }
            and: { getControl.(synth, \reverbSendOut) == mixBus.(\reverbSend).index }
            and: { getControl.(synth, \fxMixIn) == mixBus.(\fxMix).index }
    }), "effects: every running grain synth writes this engine's send buses and reads its fxMix");
};

// A NaN or inf on any of the three mix buses (a voice blowing up) becomes
// silence before the effects: with the delay feeding back and the reverb
// on, 50 ms of inf and NaN on the bus leave the master output free of bad
// values once they have passed. A probe on the bus itself sees the burst.
checkEffectsGuard = {
    command.(\setDelay, 0.25, 0.5, 0.5);
    command.(\setReverb, 0.5, 0.8, 0.5);
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
    captured = [{ command.(\setFilter, 5000.0, 0.5, 0, 0.0) }, { command.(\setDelay, 0.375, 0.4, 0.0) },
        { command.(\setReverb, 0.3, 0.8, 0.5) }, { command.(\setMasterDrift, 0.01) }, { command.(\setVoiceParam, 0, \amp, 0.2) }
    ].collect({ arg send; server.makeBundle(false, send) });
    engine.synths[\filter] = filter;
    filterTargets = captured[0].select({ arg msg; msg[0] == 15 }).collect({ arg msg; msg[1] });
    check.(captured.keep(4).every({ arg messages; messages.notEmpty and: { quiet.(messages).not } })
        and: { filterTargets.asSet == Set[freed.nodeID, engine.synths[\filterDelay].nodeID, engine.synths[\filterReverb].nodeID] },
        "setSynth sends to the effects chain without /error -1, so a missing FX node is reported (filter x3, delay, reverb, master: %)".format(
            captured.keep(4)));
    check.(quiet.(captured[4]), "and to a voice's synth inside a quiet bundle (got %)".format(captured[4]));
};

// 3.2's chain (the stand-in grain synth through voiceOutput, every send at
// 1, then the engine's three filters, delay and reverb, and the master's
// input, masterSum, on the engine's buses) against check-only copies of
// 3.0's chain fed the stand-in's raw output (the input 3.0's master got):
// the two differ by less than -60 dB of the reference. (The master after
// the sum is the same def in both, but two of them never match: PitchShift
// draws its time dispersion from the server's shared random generator.)
// The engine's delay and reverb are bypassed and lifted first, so they
// start empty as the copies do. fx: [filter freq, res, type, mix; delay
// time, feedback, mix; reverb mix, size, damp]; sweep: a function of the
// time (s) giving the delay mix, sent every 50 ms (with the copy's in the
// same bundle), or nil.
checkChain30 = { arg label, fx, sweep;
    var rawBus = Bus.audio(server, 2), filtered30 = Bus.audio(server, 2), delayed30 = Bus.audio(server, 2);
    var reverbed30 = Bus.audio(server, 2), out32 = Bus.audio(server, 2), sum32;
    var junk = Bus.audio(server, 2), energyBus = Bus.control(server, 2);
    var group30 = Group.after(context.xg), compareGroup, copies, source, comparator, energies, ratio, elapsed = 0;
    command.(\setFilter, *fx.copyRange(0, 3));
    command.(\setDelay, *fx.copyRange(4, 6));
    command.(\setReverb, *fx.copyRange(7, 9));
    command.(\setBypass, 0, 1); command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
    server.sync;
    copies = [
        Synth(\strataCheck30Filter, [\in, rawBus, \out, filtered30, \freq, fx[0], \res, fx[1], \filterType, fx[2], \mix, fx[3]],
            group30, \addToTail),
        Synth(\strataCheck30Delay, [\in, filtered30, \out, delayed30, \time, fx[4], \feedback, fx[5], \mix, fx[6]],
            group30, \addToTail),
        Synth(\strataCheck30Reverb, [\in, delayed30, \out, reverbed30, \mix, fx[7], \size, fx[8], \damp, fx[9]],
            group30, \addToTail)
    ];
    compareGroup = Group.after(group30);
    sum32 = Synth(\strataCheckMasterSum, [\in, engine.filterBus, \delayIn, engine.delayBus, \reverbIn, engine.reverbBus,
        \fxMix, mixBus.(\fxMix), \out, out32], engine.synths[\master], \addBefore);
    0.6.wait; server.sync;   // the lifted mixes settle
    server.makeBundle(nil, {
        source = Synth(\strataCheckChainSource, [\out, engine.mainBus, \raw, rawBus, \junk, junk]
            ++ engine.mixBusControls.asKeyValuePairs, engine.processGroup, \addToTail);
        comparator = Synth(\strataCheckCompare, [\in, out32, \ref, reverbed30, \out, energyBus], compareGroup);
    });
    while { elapsed < 1.5 } {
        if (sweep.notNil) {
            server.makeBundle(nil, {
                command.(\setDelay, fx[4], fx[5], sweep.(elapsed));
                copies[1].set(\mix, sweep.(elapsed));
            });
        };
        0.05.wait; elapsed = elapsed + 0.05;
    };
    energies = readBus.(energyBus);
    ratio = if (energies.size == 2 and: { energies[1] > 0 }) { (energies[0] / energies[1]).sqrt } { 1 };
    check.((energies.size == 2) and: { energies[1] > 1 } and: { ratio < 0.001 },
        "effects: with every send at 1 the output matches 3.0's chain within -60 dB (%: % dB, reference energy %)".format(
            label, (ratio.max(1e-12).ampdb).round(0.1), energies[1] ? 0));
    source.free; comparator.free; sum32.free; group30.free; compareGroup.free; server.sync;
    [rawBus, filtered30, delayed30, reverbed30, out32, junk, energyBus].do(_.free);
};

// A voice whose sends are 0 plays dry at full level at any global mix: the
// stand-in's dry output equals its raw signal and its sends carry nothing,
// with the delay and reverb mixes high; with its sends at 1 the dry part is
// (1 - m_d)(1 - m_r) of it, the delay send all of it and the reverb send
// (1 - m_d)
checkDrySends = {
    var rawBus = Bus.audio(server, 2), dryBus = Bus.audio(server, 2), delayBus = Bus.audio(server, 2);
    var reverbBus = Bus.audio(server, 2), junk = Bus.audio(server, 2), peakBus = Bus.control(server, 4);
    var group = Group.after(engine.processGroup), source, probe, peaks, results;
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
    command.(\setDelay, 0.375, 0.4, 0.8);
    command.(\setReverb, 0.9, 0.8, 0.5);
    server.sync; 0.2.wait;
    // [delay send, reverb send, dry gain, delay send gain, reverb send gain]
    results = [[0, 0, 1, 0, 0], [1, 1, 0.2 * 0.1, 1, 0.2]].collect({ arg each;
        source = Synth(\strataCheckChainSource, [\out, dryBus, \raw, rawBus, \junk, junk, \delaySend, each[0], \reverbSend, each[1],
            \delaySendOut, delayBus.index, \reverbSendOut, reverbBus.index, \fxMixIn, mixBus.(\fxMix).index], group);
        probe = Synth(\strataCheckSendPeaks, [\raw, rawBus, \dry, dryBus, \delay, delayBus, \reverb, reverbBus, \out, peakBus,
            \dryGain, each[2], \delayGain, each[3], \reverbGain, each[4]], group, \addToTail);
        server.sync; 0.2.wait;
        peaks = measure.(probe, peakBus, 0.5);
        source.free; probe.free; server.sync;
        peaks
    });
    check.(results.every({ arg each; (each.size == 4) and: { each[3] > 0.1 } and: { each.keep(3).every({ arg peak; peak < 1e-5 }) } }),
        "effects: a voice with sends 0 plays dry at full level at any global mix (delay 0.8, reverb 0.9; errors against dry x1 and empty sends, and at sends 1 dry x0.02, delay send x1, reverb send x0.2: %)".format(
            results.collect({ arg each; each.round(0.000001) })));
    group.free; [rawBus, dryBus, delayBus, reverbBus, junk, peakBus].do(_.free);
};

// A command's messages, captured (makeBundle(false) sends nothing) and
// then sent as they are, so a check can read what the command sent inside
// a wait as short as the bypass fade (one bundle; the free comes later)
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
// whether messages hold a /c_setn of fxMix to the two mixes
broadcasts = { arg messages, delayMix, reverbMix;
    messages.any({ arg msg; (msg[0].asSymbol == '/c_setn') and: { msg[1] == mixBus.(\fxMix).index }
        and: { msg[3].equalWithPrecision(delayMix) } and: { msg[4].equalWithPrecision(reverbMix) } })
};

// The bypass: the delay's mix and the broadcast mix go to 0 at once (one
// bundle, no free in it), the node is freed after the fade and re-created
// in its place from the kept controls when lifted
checkBypassFrees = {
    var before, after, broadcast, lifted, messages;
    command.(\setDelay, 0.3, 0.45, 0.6);
    server.sync; 0.1.wait;
    before = engine.synths[\delay];
    messages = sentBy.(\setBypass, 0, 1);
    check.((engine.synths[\delay] === before) and: { setsControl.(messages, before, \mix, 0) }
        and: { broadcasts.(messages, 0, 0.3) } and: { messages.any({ arg msg; msg[0] == 11 }).not },
        "effects: setBypass first sets the delay's mix and its broadcast to 0 in one bundle, keeping the node for the fade (sent %)".format(
            messages));
    0.2.wait; server.sync;
    after = chainTail.value;
    check.(engine.synths[\delay].isNil and: { delayNodes.value == 0 }
        and: { after == [\strataFilter, \strataFilter, \strataFilter, \strataReverb, \strataMaster] },
        "effects: setBypass frees the delay after the mix fade (chain %)".format(after));
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = engine.synths[\delay];
    broadcast = readBus.(mixBus.(\fxMix));
    check.(lifted.notNil and: { lifted !== before } and: { delayNodes.value == 1 }
        and: { chainTail.value == [\strataFilter, \strataFilter, \strataFilter, \strataDelay, \strataReverb, \strataMaster] }
        and: { getControl.(lifted, \time).equalWithPrecision(0.3) } and: { getControl.(lifted, \feedback).equalWithPrecision(0.45) }
        and: { getControl.(lifted, \mix).equalWithPrecision(0.6) } and: { broadcast[0].equalWithPrecision(0.6) },
        "effects: setBypass frees the delay after the mix fade and re-creates it when lifted (after the reverb send's filter, with time, feedback and mix kept; broadcast %)".format(broadcast));
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

// Freeing the delay gives its DelayC lines (1 MB) back to the pool
checkBypassMemory = {
    var running, bypassed, freedKB;
    running = floodFit.value;
    command.(\setBypass, 0, 1);
    0.2.wait; server.sync;
    bypassed = floodFit.value;
    freedKB = (bypassed - running) * probeKB;
    check.(freedKB > 900,
        "effects: a bypassed delay returns its 1 MB to the pool (about % KB more free; a probe % KB)".format(
            freedKB.round(1), probeKB.round(0.1)));
    command.(\setBypass, 0, 0);
    server.sync; 0.1.wait;
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

// An LFO-rate series of setDelays taking the mix through 0 and back never
// frees the delay node, and a mix of 0 broadcasts 0 with the node running
checkMixThroughZero = {
    var node = engine.synths[\delay], zeroBroadcast;
    50.do({ arg index;
        var mix = (0.4 * sin(index * 0.5)).max(0);
        command.(\setDelay, 0.3, 0.45, mix);
        if (index == 7) { server.sync; zeroBroadcast = readBus.(mixBus.(\fxMix))[0] };
        0.02.wait;
    });
    server.sync; 0.2.wait;
    check.((engine.synths[\delay] === node) and: { delayNodes.value == 1 } and: { zeroBroadcast == 0 }
        and: { h.synthTree(context.xg).any({ arg each; each[\id] == node.nodeID }) },
        "effects: a mix swept through 0 never frees the node (broadcast at 0: %)".format(zeroBroadcast));
};

// setDelay during the fade and after the free: the values are kept, the
// mix sent and broadcast stays 0, and the lift brings them back
checkSetWhileBypassed = {
    var fading = engine.synths[\delay], broadcast, lifted, messages;
    command.(\setBypass, 0, 1);
    messages = sentBy.(\setDelay, 0.2, 0.3, 0.7);
    check.(setsControl.(messages, fading, \mix, 0) and: { setsControl.(messages, fading, \time, 0.2) }
        and: { broadcasts.(messages, 0, engine.liveMix(\reverb)) },
        "effects: setDelay during the bypass fade sets the time and keeps the mix and its broadcast at 0 (sent %)".format(messages));
    0.2.wait; server.sync;
    command.(\setDelay, 0.5, 0.6, 0.8);
    server.sync;
    broadcast = readBus.(mixBus.(\fxMix));
    check.(engine.synths[\delay].isNil and: { delayNodes.value == 0 } and: { broadcast[0] == 0 },
        "effects: setDelay while bypassed stores its values and keeps the mix at 0 (broadcast %)".format(broadcast));
    command.(\setBypass, 0, 0);
    server.sync;
    lifted = engine.synths[\delay];
    broadcast = readBus.(mixBus.(\fxMix));
    check.(lifted.notNil and: { getControl.(lifted, \time).equalWithPrecision(0.5) }
        and: { getControl.(lifted, \feedback).equalWithPrecision(0.6) } and: { getControl.(lifted, \mix).equalWithPrecision(0.8) }
        and: { broadcast[0].equalWithPrecision(0.8) },
        "effects: and the lift creates the delay with them (broadcast %)".format(broadcast));
};

// The reverb's bypass: its node is freed and re-created before the master;
// the delay is untouched; setReverb while bypassed is kept
checkReverbBypass = {
    var delay = engine.synths[\delay], before = engine.synths[\reverb], broadcast, lifted;
    command.(\setReverb, 0.4, 0.7, 0.3);
    command.(\setBypass, 1, 1);
    0.2.wait; server.sync;
    command.(\setReverb, 0.35, 0.6, 0.2);
    server.sync;
    broadcast = readBus.(mixBus.(\fxMix));
    check.(engine.synths[\reverb].isNil and: { h.synthNames(context.xg).includes(\strataReverb).not }
        and: { engine.synths[\delay] === delay } and: { broadcast[1] == 0 },
        "effects: setBypass frees the reverb after its fade and leaves the delay (broadcast %)".format(broadcast));
    command.(\setBypass, 1, 0);
    server.sync;
    lifted = engine.synths[\reverb];
    broadcast = readBus.(mixBus.(\fxMix));
    check.(lifted.notNil and: { lifted !== before } and: { lifted.defName.asSymbol == \strataReverb }
        and: { chainTail.value == [\strataFilter, \strataFilter, \strataFilter, \strataDelay, \strataReverb, \strataMaster] }
        and: { getControl.(lifted, \mix).equalWithPrecision(0.35) } and: { getControl.(lifted, \size).equalWithPrecision(0.6) }
        and: { getControl.(lifted, \damp).equalWithPrecision(0.2) } and: { broadcast[1].equalWithPrecision(0.35) },
        "effects: lifting the reverb's bypass re-creates it before the master with the kept controls (broadcast %)".format(broadcast));
};

// The FDN (the high tier's reverb) against FreeVerb2, both fully wet at
// size 0.8 and damp 0.5: the RT60 of a noise burst's energy envelope (T30:
// twice the time from -5 to -35 dB) within 30%. Also each one's pool size
// (the small probes that fit with and without one), and a high engine
// runs the FDN, also after a bypass is lifted.
checkFdn = {
    // each def in its own group on its own buses, rendered at once; a 3 s
    // window holds T30 (-35 dB about 1-1.4 s after -5 dB at RT60 2-2.7 s)
    var rt60s = { arg defNames;
        var seconds = 3, frames = (seconds * server.sampleRate / server.options.blockSize).asInteger;
        var runs = defNames.collect({ arg defName;
            var run = (inBus: Bus.audio(server, 2), outBus: Bus.audio(server, 2), nothing: Bus.audio(server, 2),
                buffer: Buffer.alloc(server, frames, 1), group: Group.after(context.xg), condition: Condition(false));
            Synth(defName, [\in, run[\inBus], \delayIn, run[\nothing], \out, run[\outBus], \mix, 1, \size, 0.8, \damp, 0.5],
                run[\group]);
            run
        });
        server.sync; 0.1.wait;
        server.makeBundle(nil, {
            runs.do({ arg run;
                Synth(\strataCheckBurst, [\out, run[\inBus]], run[\group], \addToHead);
                Synth(\strataCheckEnvelopeRecord, [\in, run[\outBus], \buffer, run[\buffer]], run[\group], \addToTail);
            })
        });
        (seconds + 0.3).wait;
        runs.collect({ arg run;
            var values, dbs, peakIndex, peakDb, at5, at35;
            run[\buffer].loadToFloatArray(action: { arg array; values = array; run[\condition].test = true; run[\condition].signal });
            awaitReply.(run[\condition], 10);
            run[\group].free; server.sync;
            [\buffer, \inBus, \outBus, \nothing].do({ arg key; run[key].free });
            dbs = values.collect({ arg value; 10 * log10(value.max(1e-20)) });
            peakIndex = dbs.maxIndex; peakDb = dbs[peakIndex];
            at5 = (peakIndex..(dbs.size - 1)).detect({ arg index; dbs[index] <= (peakDb - 5) });
            at35 = (peakIndex..(dbs.size - 1)).detect({ arg index; dbs[index] <= (peakDb - 35) });
            if (at5.notNil and: { at35.notNil }) {
                2 * (at35 - at5) * server.options.blockSize / server.sampleRate
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
        "effects: the FDN's RT60 is within 30\\% of FreeVerb2's at size 0.8 (FDN % s, FreeVerb2 % s; pool: FDN about % KB, FreeVerb2 about % KB)".format(
            fdn !? { arg value; value.round(0.01) }, freeverb !? { arg value; value.round(0.01) }, fdnKB.round(1), freeverbKB.round(1)));
    check.(fdnKB < 512, "effects: the FDN takes under 512 KB of the pool (about % KB)".format(fdnKB.round(1)));
    // a high engine's reverb
    write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 16\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    high = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    highReverb = high.synths[\reverb] !? { arg synth; synth.defName.asSymbol };
    h.commandTo(high, \setBypass, 1, 1);
    0.2.wait; server.sync;
    h.commandTo(high, \setBypass, 1, 0);
    server.sync;
    check.((high.tier == \high) and: { highReverb == \strataReverbFDN }
        and: { high.synths[\reverb] !? { arg synth; synth.defName.asSymbol } == \strataReverbFDN }
        and: { engine.synths[\reverb].defName.asSymbol == \strataReverb },
        "effects: the high tier runs the FDN reverb (also after a bypass is lifted) and standard FreeVerb2 (got %, %)".format(
            highReverb, high.synths[\reverb] !? { arg synth; synth.defName }));
    h.freeEngine(high);
    server.sync;
    check.([\delaySend, \reverbSend, \delaySendPost, \reverbSendPost, \fxMix].every({ arg name; high.mixBus(name).index.isNil }),
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
// "effects: the filter and send controls feed a UGen", in both grain defs
check.(h.grainDefs.every({ arg name;
    [\filterType, \filterFreq, \filterRes, \filterMix, \delaySend, \reverbSend].every({ arg control;
        h.controlFeedsAUGen(name, control) })
}), "effects: the filter and send controls feed a UGen");
check.(h.grainDefs.every({ arg name;
    SynthDescLib.global.at(name).def.children.select({ arg ugen; ugen.isKindOf(Out) }).size == 4
}), "effects: each grain def writes the dry bus, the two sends and the mirror");

// The 3.0 comparison and the dry voice first, with no voice running
probeKB = smallProbeKB.value;
checkChain30.("defaults", [5000.0, 0.5, 0, 0.0, 0.375, 0.4, 0.0, 0.3, 0.8, 0.5], nil);
checkChain30.("filter on, delay mix swept by an LFO", [1200.0, 0.4, 0, 0.6, 0.21, 0.5, 0.5, 0.45, 0.7, 0.3],
    { arg seconds; 0.5 + (0.4 * sin(2pi * 0.7 * seconds)) });
checkDrySends.value;

h.startAllVoices;
checkRouting.value;

// Effects defaults match the Lua param defaults (Lua never bangs its params)
command.(\setFilter, 5000.0, 0.5, 0, 0.0);
command.(\setDelay, 0.375, 0.4, 0.0);
command.(\setReverb, 0.3, 0.8, 0.5);
server.sync;
check.([\filter, \filterDelay, \filterReverb].every({ arg key;
    (getControl.(engine.synths[key], \freq) == 5000.0) and: { getControl.(engine.synths[key], \mix) == 0.0 } }),
    "filter freq default 5000, each filter starts bypassed");
check.(getControl.(engine.synths[\delay], \time) == 0.375, "delay time default 0.375");
check.(getControl.(engine.synths[\delay], \mix) == 0.0, "delay starts dry");
check.(readBus.(mixBus.(\fxMix)).round(0.0001) == [0.0, 0.3], "fxMix broadcasts the delay and reverb mixes (0 and 0.3)");

command.(\setFilter, 800.0, 0.2, 1, 1.0);
server.sync;
check.([\filter, \filterDelay, \filterReverb].every({ arg key;
    var synth = engine.synths[key];
    (getControl.(synth, \filterType) == 1) and: { getControl.(synth, \freq) == 800.0 }
        and: { getControl.(synth, \res).equalWithPrecision(0.2) } and: { getControl.(synth, \mix) == 1.0 }
}), "effects: setFilter sets all three master filters");
command.(\setDelay, 0.25, 0.5, 0.5);
server.sync;
check.(getControl.(engine.synths[\delay], \time) == 0.25, "setDelay sets time");
check.(getControl.(engine.synths[\delay], \feedback) == 0.5, "setDelay sets feedback");
check.(getControl.(engine.synths[\delay], \mix) == 0.5, "setDelay sets mix");
check.(readBus.(mixBus.(\fxMix))[0] == 0.5, "setDelay broadcasts the mix");

checkFilterCrossfade.([[\strataFilter, "filter type changes crossfade"],
    [\strataCheckVoiceFilter, "effects: the voice filter crossfades types in 20 ms"]]);
checkEffectsGuard.value;
checkEffectSendsReported.value;
h.stopAllVoices;

checkBypassFrees.value;
checkBypassMemory.value;
checkBypassToggling.value;
checkMixThroughZero.value;
checkSetWhileBypassed.value;
checkReverbBypass.value;
checkFdn.value;

// back to the Lua defaults for the areas that follow, nothing bypassed
command.(\setBypass, 0, 0); command.(\setBypass, 1, 0);
command.(\setFilter, 5000.0, 0.5, 0, 0.0);
command.(\setDelay, 0.375, 0.4, 0.0);
command.(\setReverb, 0.3, 0.8, 0.5);
command.(\setMasterDrift, 0.01);
server.sync;
}
