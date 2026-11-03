// engine_check.scd
// Runtime check of lib/Engine_Strata.sc against the real norns CroneEngine
// and CroneAudioContext classes. Run through test/run_engine_check.sh, which
// sets up the class library. Boots a local scsynth; the engine's output is
// routed to a private bus so nothing is audible.
(
var server = Server.local;
var failures = 0;
var context, engine, done, tree, names, voiceNames, grainIndices, firstGrain;
var voiceDefs = [\strataResonator, \strataFM, \strataFolder, \strataSub,
    \strataPulse, \strataKarplus, \strataRing];
var allDefs = voiceDefs ++ [\strataMod, \strataGrain, \strataFilter, \strataDelay, \strataReverb, \strataMaster];
var chainDefs = [\strataFilter, \strataDelay, \strataReverb, \strataMaster];

var check = { arg condition, message;
    if (condition == true) {
        ("ok   " ++ message).postln;
    } {
        failures = failures + 1;
        ("FAIL " ++ message).postln;
    };
};

// Invoke a registered engine command exactly as matron's OSC would.
var command = { arg name ... args;
    var entry = engine.commands.detect({ arg cmd; cmd.name == name });
    if (entry.isNil) { Error("no command " ++ name).throw };
    entry.oscdef.func.value([("/command/" ++ name).asSymbol] ++ args);
};

var formatOf = { arg name;
    var entry = engine.commands.detect({ arg cmd; cmd.name == name });
    if (entry.isNil) { nil } { entry.format.asString };
};

// Depth-first list of synth def names under a node, from /g_queryTree.
var synthNames = { arg group;
    var condition = Condition(false), reply, list = List.new, index = 2, parse;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal },
        '/g_queryTree.reply', server.addr).oneShot;
    server.sendMsg('/g_queryTree', group.nodeID, 0);
    condition.wait;
    parse = {
        var numChildren = reply[index + 1];
        index = index + 2;
        if (numChildren == -1) {
            list.add(reply[index].asSymbol);
            index = index + 1;
        } {
            numChildren.do({ parse.value });
        };
    };
    parse.value;
    list
};

var getControl = { arg synth, control;
    var condition = Condition(false), value;
    synth.get(control, { arg result; value = result; condition.test = true; condition.signal });
    condition.wait;
    value
};

server.options.numInputBusChannels = 2;
server.waitForBoot({
    var exitCode;
    try {
        var oldVoice, newVoice, before, after, silentIndex, startedNames, masterUGens, envSamples;

        CroneDefs.sendDefs(server);
        server.sync;
        context = CroneAudioContext.new(server);
        context.out_b = Bus.audio(server, 2);  // keep the check silent
        server.sync;

        done = Condition(false);
        engine = Engine_Strata.new(context, { done.test = true; done.signal });
        done.wait;
        server.sync;
        "compiled and allocated Engine_Strata".postln;

        // SynthDefs
        allDefs.do({ arg name;
            check.(SynthDescLib.global.at(name).notNil, "SynthDef % built".format(name));
        });
        voiceDefs.do({ arg name;
            var controls = SynthDescLib.global.at(name).controlNames.collect(_.asSymbol);
            check.(controls.includes(\t_trig), "% has a t_trig control (C3)".format(name));
            check.(controls.includes(\velocity), "% has a velocity control for the accent".format(name));
        });
        [\grainMode, \t_trig, \velocity].do({ arg control;
            check.(SynthDescLib.global.at(\strataGrain).controlNames.collect(_.asSymbol).includes(control),
                "strataGrain has a % control".format(control));
        });
        check.(SynthDescLib.global.at(\strataGrain).def.children.any({ arg ugen; ugen.isKindOf(Select) })
            and: { SynthDescLib.global.at(\strataGrain).def.children.any({ arg ugen; ugen.isKindOf(T2A) }) },
            "strataGrain selects between Impulse and T2A(t_trig) grain triggers");

        // Command signatures
        check.(formatOf.(\voiceOn) == "iffffff", "voiceOn signature is iffffff (C1)");
        check.(formatOf.(\retrigger) == "if", "retrigger signature is if (voice, velocity)");
        check.(formatOf.(\setFilter) == "ffif", "setFilter signature is ffif");
        check.(formatOf.(\setDelay) == "fff", "setDelay signature is fff");
        check.(SynthDescLib.global.at(\strataMaster).def.children.any({ arg ugen; ugen.isKindOf(Limiter) }),
            "master has a Limiter safety stage");
        // The limiter must feed the tanh saturator: after it, tanh * 0.5 already
        // bounds the signal and the limiter could never act
        masterUGens = SynthDescLib.global.at(\strataMaster).def.children;
        check.(masterUGens.detectIndex({ arg ugen; ugen.isKindOf(Limiter) })
            < masterUGens.detectIndex({ arg ugen; ugen.isKindOf(UnaryOpUGen) and: { ugen.operator == \tanh } }),
            "master limits before the tanh saturation");

        // Silent bus (I4)
        silentIndex = engine.silentBus.index;
        check.(silentIndex != context.amp_in_b[0].index and: { silentIndex != 0 },
            "silent bus is not control bus 0 / the input amplitude bus (I4)");

        // Commands on never-started voices must not throw (M6)
        command.(\voiceOff, 2);
        command.(\setVoiceParam, 2, \fold, 2.0);
        command.(\setGrainParam, 2, \grainSize, 0.2);
        command.(\setModSource, 2, 1, 0);
        command.(\setModAmpAmt, 2, 1, 0.5);
        command.(\setModFreqAmt, 2, 1, 0.5);
        command.(\setModSpeed, 2, 5.0);
        command.(\retrigger, 2, 1.0);
        check.(true, "commands on a never-started voice do not throw (M6)");

        // Start every voice
        7.do({ arg voice;
            command.(\voiceOn, voice, 100.0 + voice, 0.2, 0.0, 0.1, 10.0, 1.0);
        });
        server.sync;

        check.(getControl.(engine.synths[\voice3], \freq) == 103.0, "voiceOn sets freq (C1)");
        check.(getControl.(engine.synths[\voice0], \modBus1) == silentIndex,
            "voiceOn routes unused mod slots to the silent bus (I4)");

        command.(\setModSource, 1, 2, 0);
        server.sync;
        check.(getControl.(engine.synths[\voice1], \modBus2) == engine.modBuses[0].index,
            "setModSource routes a slot to the source voice's mod bus");
        command.(\setModSource, 1, 2, -1);
        server.sync;
        check.(getControl.(engine.synths[\voice1], \modBus2) == silentIndex,
            "setModSource -1 routes to the silent bus (I4)");

        command.(\setGrainParam, 0, \pitchShift, 2.0);
        command.(\setGrainParam, 0, \posSpread, 0.7);
        server.sync;
        check.(getControl.(engine.synths[\grain0], \pitchShift) == 2.0, "setGrainParam pitchShift reaches the grain synth");

        // Grain mode: 0 = continuous (Impulse), 1 = triggered (one grain per t_trig)
        check.(getControl.(engine.synths[\grain0], \grainMode) == 0, "grain synths start continuous");
        command.(\setGrainParam, 0, \grainMode, 1);
        server.sync;
        check.(getControl.(engine.synths[\grain0], \grainMode) == 1, "setGrainParam grainMode reaches the grain synth");
        command.(\setGrainParam, 0, \grainMode, 0);

        // retrigger carries velocity to the voice synth (accent depth) and the grain synth
        before = synthNames.(context.xg).size;
        command.(\retrigger, 0, 0.5);
        server.sync;
        check.(getControl.(engine.synths[\voice0], \velocity) == 0.5, "retrigger sets velocity on the voice synth");
        check.(getControl.(engine.synths[\grain0], \velocity) == 0.5, "retrigger sets velocity on the grain synth");
        check.(synthNames.(context.xg).size == before, "a velocity retrigger creates no nodes");

        // Grain envelope shapes: envShape 0 = built-in Hann (-1), 1-4 = envBuffers
        check.(engine.envBuffers.size == 4, "four grain envelope buffers");
        check.(engine.envBuffers.every({ arg buffer; buffer.numFrames == 1024 }),
            "envelope buffers hold 1024 frames");
        envSamples = { var condition = Condition(false), values;
            engine.envBuffers[3].loadToFloatArray(action: { arg array;
                values = array; condition.test = true; condition.signal });
            condition.wait;
            values
        }.value;
        check.((envSamples[0].abs < 0.01) and: { (envSamples[512] - 1).abs < 0.01 },
            "trapezoid envelope buffer is loaded on the server (0 at the start, 1 in the middle)");
        check.(getControl.(engine.synths[\grain0], \envBuf) == -1, "grain synths start with the Hann envelope");
        command.(\setGrainParam, 0, \envShape, 2);
        server.sync;
        check.(getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[1].bufnum,
            "envShape 2 selects the second envelope buffer");
        command.(\setGrainParam, 0, \envShape, 4);
        server.sync;
        check.(getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[3].bufnum,
            "envShape 4 selects the last envelope buffer");
        command.(\setGrainParam, 0, \envShape, 0);
        server.sync;
        check.(getControl.(engine.synths[\grain0], \envBuf) == -1, "envShape 0 returns to the Hann envelope");
        command.(\setGrainParam, 0, \envShape, 1);
        command.(\setGrainParam, 0, \envShape, 9);
        command.(\setGrainParam, 0, \envShape, -1);
        server.sync;
        check.(getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[0].bufnum,
            "an out-of-range envShape is ignored");

        // Node ordering inside context.xg (M5)
        names = synthNames.(context.xg);
        voiceNames = names.select({ arg name; voiceDefs.includes(name) });
        grainIndices = names.collect({ arg name, index; if (name == \strataGrain or: { name == \strataMod }) { index } }).reject(_.isNil);
        firstGrain = grainIndices.minItem;
        check.(names.size == ((7 * 3) + 4), "xg holds 7 voice trios plus filter, delay, reverb and master (got %)".format(names.size));
        check.(names.indexOf(voiceNames.last) < firstGrain, "voices run before grain/mod synths");
        check.(grainIndices.maxItem < names.indexOf(\strataFilter), "grain/mod synths run before the effects chain");
        check.(names.copyRange(names.size - 4, names.size - 1).asArray == chainDefs,
            "xg ends filter -> delay -> reverb -> master (got %)".format(names.copyRange(names.size - 4, names.size - 1)));
        check.(names.last == \strataMaster, "master runs last inside xg (M5)");

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
        check.(synthNames.(context.og).includes(\strataMaster).not, "master is not placed after og (M5)");

        // retrigger never creates nodes (C3)
        before = synthNames.(context.xg).size;
        50.do({ arg count; command.(\retrigger, count % 7, 1.0) });
        server.sync;
        after = synthNames.(context.xg).size;
        check.(before == after, "50 retriggers create no nodes (% before, % after)".format(before, after));

        // voiceOn on a running voice replaces the trio (M6)
        oldVoice = engine.synths[\voice0];
        command.(\voiceOn, 0, 150.0, 0.2, 0.0, 0.1, 10.0, 1.0);
        server.sync;
        newVoice = engine.synths[\voice0];
        check.(oldVoice !== newVoice, "voiceOn on a running voice creates a new voice synth");
        check.(getControl.(oldVoice, \gate) == 0.0, "voiceOn on a running voice gates the old one off (M6)");

        // voiceOff twice, then commands to the stopped voice
        command.(\voiceOff, 4);
        command.(\voiceOff, 4);
        command.(\setVoiceParam, 4, \width, 0.3);
        command.(\retrigger, 4, 0.5);
        command.(\setModSpeed, 4, 2.0);
        check.(engine.synths[\voice4].isNil, "voiceOff forgets the stopped voice's synths");

        command.(\setMasterDrift, 0.0);
        command.(\setReverb, 1.0, 0.5, 0.5);
        server.sync;

        engine.free;
        server.sync;
        check.(synthNames.(context.xg).size == 0, "free removes every engine node");
        check.(engine.envBuffers.every({ arg buffer; buffer.bufnum.isNil }), "free frees the envelope buffers");
    } { arg error;
        error.reportError;
        failures = failures + 1;
        "FAIL exception during engine check".postln;
    };

    if (failures == 0) { "ENGINE CHECK PASSED".postln; exitCode = 0 } {
        ("ENGINE CHECK FAILED: % failures".format(failures)).postln; exitCode = 1 };
    server.quit;
    1.wait;
    exitCode.exit;
});
)
