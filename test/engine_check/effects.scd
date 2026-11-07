// test/engine_check/effects.scd
// The effects chain: the master limiter before the saturator, the bus
// routing, the defaults the Lua params assume, setFilter and setDelay, the
// filter type crossfade, the NaN guard before the effects, and plain sends
// to the effects chain's synths.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var readBus = { arg bus; h.readBus(bus) };
var measure = { arg probe, bus, seconds = 0.3; h.measure(probe, bus, seconds) };
var masterUGens, filterGroup, filterIn, filterOut, stepBus, filterSynth, stepProbe, readStep, steadySteps, switchStep;

// A NaN or inf reaching mainBus (a voice blowing up) becomes silence before
// the effects: with the delay feeding back and the reverb on, 50 ms of inf
// and NaN on mainBus leave the master output free of bad values once they
// have passed. Unguarded, they circulate in the delay feedback and the
// reverb combs for good.
var checkEffectsGuard = {
    var badBus = Bus.control(server, 1), mainBadBus = Bus.control(server, 1), probe, mainProbe, bad, mainBad;
    command.(\setDelay, 0.25, 0.5, 0.5);
    command.(\setReverb, 0.5, 0.8, 0.5);
    probe = Synth(\strataCheckBadValues, [\in, context.out_b, \out, badBus], context.xg, \addAfter);
    // positive control: on mainBus itself (after the grain synths, before the filter) the burst is seen
    mainProbe = Synth(\strataCheckBadValues, [\in, engine.mainBus, \out, mainBadBus], engine.processGroup, \addAfter);
    server.sync;
    Synth(\strataCheckBadSource, [\out, engine.mainBus], engine.processGroup, \addToTail);
    server.sync; 0.3.wait;
    mainBad = readBus.(mainBadBus);
    check.(mainBad.notEmpty and: { mainBad[0] > 0 }, "the check's burst puts NaN and inf on mainBus (seen: %)".format(mainBad));
    bad = measure.(probe, badBus, 0.5);
    check.(bad == [0], "NaN and inf on mainBus never reach the master output after they pass (bad values seen: %)".format(bad));
    probe.free; mainProbe.free; badBus.free; mainBadBus.free;
};

// setSynth sends to the effects chain plainly (#47 review): filter, delay,
// reverb and master never end on their own, so a "Node not found" there is a
// real bug the server must report, while a voice's synth may have just freed
// and gets sendToSynth's quiet bundle. With \filter pointed at a freed node
// (restored afterward), each FX command's messages are captured with
// makeBundle(false), which sends nothing (a real failure would print a
// FAILURE line and fail this run on purpose): no /error -1 among them, and
// the filter's /n_set names the freed node. A voice param's set has one.
var checkEffectSendsReported = {
    var quiet = { arg messages; messages.any({ arg msg; (msg[0] == '/error') and: { msg[1] == -1 } }) };
    var filter = engine.synths[\filter], freed = Group.tail(server);
    var captured;
    server.sync; freed.free; server.sync;
    engine.synths[\filter] = freed;
    captured = [{ command.(\setFilter, 5000.0, 0.5, 0, 0.0) }, { command.(\setDelay, 0.375, 0.4, 0.0) },
        { command.(\setReverb, 0.3, 0.8, 0.5) }, { command.(\setMasterDrift, 0.01) }, { command.(\setVoiceParam, 0, \amp, 0.2) }
    ].collect({ arg send; server.makeBundle(false, send) });
    engine.synths[\filter] = filter;
    check.(captured.keep(4).every({ arg messages; messages.notEmpty and: { quiet.(messages).not } })
        and: { captured[0].every({ arg msg; (msg[0] == 15) and: { msg[1] == freed.nodeID } }) },
        "setSynth sends to the effects chain without /error -1, so a missing FX node is reported (filter, delay, reverb, master: %)".format(
            captured.keep(4)));
    check.(quiet.(captured[4]), "and to a voice's synth inside a quiet bundle (got %)".format(captured[4]));
};

check.(SynthDescLib.global.at(\strataMaster).def.children.any({ arg ugen; ugen.isKindOf(Limiter) }),
    "master has a Limiter safety stage");
// The limiter must feed the tanh saturator: after it, tanh * 0.5 already
// bounds the signal and the limiter could never act
masterUGens = SynthDescLib.global.at(\strataMaster).def.children;
check.(masterUGens.detectIndex({ arg ugen; ugen.isKindOf(Limiter) })
    < masterUGens.detectIndex({ arg ugen; ugen.isKindOf(UnaryOpUGen) and: { ugen.operator == \tanh } }),
    "master limits before the tanh saturation");

h.startAllVoices;

// Effects chain bus routing: mainBus -> filter -> delay -> reverb -> master
check.(getControl.(engine.synths[\filter], \in) == engine.mainBus.index, "filter reads mainBus");
check.(getControl.(engine.synths[\filter], \out) == engine.filterBus.index, "filter writes filterBus");
check.(getControl.(engine.synths[\delay], \in) == engine.filterBus.index, "delay reads filterBus");
check.(getControl.(engine.synths[\delay], \out) == engine.delayBus.index, "delay writes delayBus");
check.(getControl.(engine.synths[\reverb], \in) == engine.delayBus.index, "reverb reads delayBus");
check.(getControl.(engine.synths[\reverb], \out) == engine.reverbBus.index, "reverb writes reverbBus");
check.(getControl.(engine.synths[\master], \in) == engine.reverbBus.index, "master reads reverbBus");

// Effects defaults match the Lua param defaults (Lua never bangs its params)
check.(getControl.(engine.synths[\filter], \freq) == 5000.0, "filter freq default 5000");
check.(getControl.(engine.synths[\filter], \mix) == 0.0, "filter starts bypassed");
check.(getControl.(engine.synths[\delay], \time) == 0.375, "delay time default 0.375");
check.(getControl.(engine.synths[\delay], \mix) == 0.0, "delay starts dry");

command.(\setFilter, 800.0, 0.2, 1, 1.0);
server.sync;
check.(getControl.(engine.synths[\filter], \filterType) == 1, "setFilter sets filterType");
check.(getControl.(engine.synths[\filter], \freq) == 800.0, "setFilter sets freq");
check.(getControl.(engine.synths[\filter], \res).equalWithPrecision(0.2), "setFilter sets res");
check.(getControl.(engine.synths[\filter], \mix) == 1.0, "setFilter sets mix");
command.(\setDelay, 0.25, 0.5, 0.5);
server.sync;
check.(getControl.(engine.synths[\delay], \time) == 0.25, "setDelay sets time");
check.(getControl.(engine.synths[\delay], \feedback) == 0.5, "setDelay sets feedback");
check.(getControl.(engine.synths[\delay], \mix) == 0.5, "setDelay sets mix");

// A filter type change crossfades: a strataFilter of its own (fully
// wet, on a 1 kHz sine at its cutoff, where lowpass and highpass are
// in antiphase) never steps further between two samples while the
// type changes than in any type's steady state
filterIn = Bus.audio(server, 2); filterOut = Bus.audio(server, 2); stepBus = Bus.control(server, 1);
filterGroup = Group.tail(server);
Synth(\strataCheckSine, [\out, filterIn, \freq, 1000], filterGroup, \addToTail);
filterSynth = Synth(\strataFilter, [\in, filterIn, \out, filterOut, \freq, 1000, \res, 0.5, \filterType, 0, \mix, 1],
    filterGroup, \addToTail);
stepProbe = Synth(\strataCheckStep, [\in, filterOut, \out, stepBus], filterGroup, \addToTail);
// the largest step since the probe was last reset
readStep = {
    var condition = Condition(false), value;
    stepBus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
};
steadySteps = [0, 1, 2].collect({ arg type;
    filterSynth.set(\filterType, type); 0.4.wait;
    stepProbe.set(\t_reset, 1); 0.3.wait;
    readStep.value
});
filterSynth.set(\filterType, 0); 0.4.wait;
stepProbe.set(\t_reset, 1); 0.05.wait;
// six changes, each at a different point in the sine's cycle
[1, 2, 0, 2, 1, 0].do({ arg type; filterSynth.set(\filterType, type); 0.13.wait });
switchStep = readStep.value;
check.(switchStep <= (steadySteps.maxItem * 1.1),
    "filter type changes crossfade (largest step % while switching, % at most in steady state %)".format(
        switchStep.round(0.0001), steadySteps.maxItem.round(0.0001), steadySteps.round(0.0001)));
filterGroup.free; filterIn.free; filterOut.free; stepBus.free;
checkEffectsGuard.value;
checkEffectSendsReported.value;

command.(\setMasterDrift, 0.0);
command.(\setReverb, 1.0, 0.5, 0.5);
server.sync;
h.stopAllVoices;
}
