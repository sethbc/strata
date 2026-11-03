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
var allDefs = voiceDefs ++ [\strataMod, \strataGrain, \strataReverb, \strataMaster];

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
        var oldVoice, newVoice, before, after, silentIndex, startedNames;

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
        });

        // Command signatures
        check.(formatOf.(\voiceOn) == "iffffff", "voiceOn signature is iffffff (C1)");
        check.(formatOf.(\retrigger) == "i", "retrigger command exists with signature i (C3)");

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
        command.(\retrigger, 2);
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

        // Node ordering inside context.xg (M5)
        names = synthNames.(context.xg);
        voiceNames = names.select({ arg name; voiceDefs.includes(name) });
        grainIndices = names.collect({ arg name, index; if (name == \strataGrain or: { name == \strataMod }) { index } }).reject(_.isNil);
        firstGrain = grainIndices.minItem;
        check.(names.size == ((7 * 3) + 2), "xg holds 7 voice trios plus reverb and master (got %)".format(names.size));
        check.(names.indexOf(voiceNames.last) < firstGrain, "voices run before grain/mod synths");
        check.(grainIndices.maxItem < names.indexOf(\strataReverb), "grain/mod synths run before reverb");
        check.(names.last == \strataMaster, "master runs last inside xg (M5)");
        check.(synthNames.(context.og).includes(\strataMaster).not, "master is not placed after og (M5)");

        // retrigger never creates nodes (C3)
        before = synthNames.(context.xg).size;
        50.do({ arg count; command.(\retrigger, count % 7) });
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
        command.(\retrigger, 4);
        command.(\setModSpeed, 4, 2.0);
        check.(engine.synths[\voice4].isNil, "voiceOff forgets the stopped voice's synths");

        command.(\setMasterDrift, 0.0);
        command.(\setReverb, 1.0, 0.5, 0.5);
        server.sync;

        engine.free;
        server.sync;
        check.(synthNames.(context.xg).size == 0, "free removes every engine node");
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
