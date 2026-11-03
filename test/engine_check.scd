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
var allDefs = voiceDefs ++ [\strataMod, \strataGrain, \strataGrainBuf, \strataInput, \strataRecord,
    \strataFilter, \strataDelay, \strataReverb, \strataMaster];
var grainDefs = [\strataGrain, \strataGrainBuf];
var pollMessages = List.new;
var scratchRoot = Platform.defaultTempDir +/+ ("strata-engine-check-" ++ Date.getDate.stamp);
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

// Wait (inside the check routine) until condition is true or timeout passes
var waitFor = { arg condition, timeout = 3;
    var elapsed = 0;
    while { condition.value.not and: { elapsed < timeout } } { 0.05.wait; elapsed = elapsed + 0.05 };
    condition.value
};

// true when the velocity control feeds nothing but EnvGen levelScale inputs
// (a per-trigger accent depth), never a bare multiplier on a running signal
var velocityOnlyScalesAccents = { arg defName;
    var desc = SynthDescLib.global.at(defName);
    var control = desc.controls.detect({ arg each; each.name == \velocity });
    var isVelocity = { arg input;
        input.isKindOf(OutputProxy) and: { input.source.isKindOf(Control) }
            and: { (input.source.specialIndex + input.outputIndex) == control.index }
    };
    var users;
    if (control.isNil) { false } {
        users = desc.def.children.select({ arg ugen; (ugen.inputs ? []).any(isVelocity) });
        users.notEmpty and: { users.every({ arg ugen;
            ugen.isKindOf(EnvGen) and: { ugen.inputs.every({ arg input, index; isVelocity.(input).not or: { index == 1 } }) }
        }) }
    }
};

// bufferState poll value: slot index * 100 + valid seconds
var decodeBufferState = { arg value; var slot = (value / 100).floor; [slot.asInteger, value - (slot * 100)] };
var bufferStateSeen = { arg slot, seconds;
    pollMessages.any({ arg msg; var decoded = decodeBufferState.(msg[2]);
        (decoded[0] == slot) and: { (decoded[1] - seconds).abs < 0.011 } })
};

// Write a test sound file of constant per-channel values
var writeTestFile = { arg path, sampleRate, frames, values;
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16")
        .numChannels_(values.size).sampleRate_(sampleRate);
    file.openWrite(path);
    file.writeData(FloatArray.fill(frames * values.size, { arg i; values[i % values.size] }));
    file.close;
};

var bufferSample = { arg buffer, frame;
    var condition = Condition(false), value;
    buffer.loadToFloatArray(frame, 1, { arg array; value = array[0]; condition.test = true; condition.signal });
    condition.wait;
    value
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
        var oldGrain, oldVoiceSynth, grainBuf, processNames, scratchFile, savePath, file, frames, data;
        var stereoPath, monoPath, longPath, textPath, info;

        CroneDefs.sendDefs(server);
        server.sync;
        context = CroneAudioContext.new(server);
        context.out_b = Bus.audio(server, 2);  // keep the check silent
        server.sync;

        // Polls send to Crone.remoteAddr (matron on norns); capture them here
        Crone.remoteAddr = NetAddr.localAddr;
        OSCFunc({ arg msg; pollMessages.add(msg) }, '/poll/value');

        done = Condition(false);
        engine = Engine_Strata.new(context, { done.test = true; done.signal });
        done.wait;
        server.sync;
        "compiled and allocated Engine_Strata".postln;
        check.(engine.scratchDir == (Platform.userHomeDir +/+ "dust/audio/strata/scratch/"),
            "scratch takes default to ~/dust/audio/strata/scratch/");
        // never write into ~/dust from the check; a nested dir also tests mkdir on demand
        engine.scratchDir = scratchRoot +/+ "nested/scratch/";
        engine.bufferStatePoll.start;

        // SynthDefs
        allDefs.do({ arg name;
            check.(SynthDescLib.global.at(name).notNil, "SynthDef % built".format(name));
        });
        voiceDefs.do({ arg name;
            var controls = SynthDescLib.global.at(name).controlNames.collect(_.asSymbol);
            check.(controls.includes(\t_trig), "% has a t_trig control (C3)".format(name));
            check.(controls.includes(\velocity), "% has a velocity control for the accent".format(name));
            // EnvGen inputs: gate, levelScale, ...; the accent's levelScale is
            // the velocity control (sampled per trigger), not the constant 1
            check.(SynthDescLib.global.at(name).def.children.any({ arg ugen;
                ugen.isKindOf(EnvGen) and: { ugen.inputs[1].isKindOf(OutputProxy) }
            }), "% scales its accent envelope by velocity through levelScale".format(name));
        });
        grainDefs.do({ arg name;
            check.(velocityOnlyScalesAccents.(name),
                "% uses velocity only as its accent's levelScale (no bare velocity multiplier)".format(name));
            [\grainMode, \t_trig, \velocity, \bend, \envBuf].do({ arg control;
                check.(SynthDescLib.global.at(name).controlNames.collect(_.asSymbol).includes(control),
                    "% has a % control".format(name, control));
            });
        });
        [\accentAmt, \mirrorOut, \mirrorLevel].do({ arg control;
            check.(SynthDescLib.global.at(\strataGrain).controlNames.collect(_.asSymbol).includes(control),
                "strataGrain has a % control (input-source accent and mirror)".format(control));
        });
        [\out, \gate, \bufnumL, \bufnumR, \bufFrames, \bufPos, \bufRate, \bufScan, \grainSize, \grainDensity,
            \pitchShift, \posSpread, \panSpread, \amp, \modBus1, \modBus2, \modBus3, \modAmpAmt1, \modAmpAmt2,
            \modAmpAmt3, \modFreqAmt1, \modFreqAmt2, \modFreqAmt3, \mirrorOut].do({ arg control;
            check.(SynthDescLib.global.at(\strataGrainBuf).controlNames.collect(_.asSymbol).includes(control),
                "strataGrainBuf has a % control".format(control));
        });
        grainBuf = SynthDescLib.global.at(\strataGrainBuf).def.children;
        check.(grainBuf.count({ arg ugen; ugen.isKindOf(GrainBuf) }) == 2, "strataGrainBuf runs two mono GrainBufs (L/R)");
        check.(grainBuf.select({ arg ugen; ugen.isKindOf(GrainBuf) }).every({ arg ugen; ugen.numChannels == 1 }),
            "strataGrainBuf's GrainBufs are mono");
        // one PitchShift per channel of the panned pair (not one per GrainBuf path)
        check.(grainBuf.count({ arg ugen; ugen.isKindOf(PitchShift) }) == 2,
            "strataGrainBuf pitch-shifts the stereo pair once (two mono PitchShifts)");
        check.(grainBuf.any({ arg ugen; ugen.isKindOf(Balance2) }), "strataGrainBuf pans with Balance2");
        check.(SynthDescLib.global.at(\strataGrainBuf).controlNames.collect(_.asSymbol).includes(\bufRateScale),
            "strataGrainBuf has a bufRateScale control (content rate / server rate)");
        check.(grainBuf.any({ arg ugen; ugen.isKindOf(Select) }) and: { grainBuf.any({ arg ugen; ugen.isKindOf(T2A) }) },
            "strataGrainBuf selects between Impulse and T2A(t_trig) grain triggers");
        check.(SynthDescLib.global.at(\strataGrain).def.children.any({ arg ugen; ugen.isKindOf(Select) })
            and: { SynthDescLib.global.at(\strataGrain).def.children.any({ arg ugen; ugen.isKindOf(T2A) }) },
            "strataGrain selects between Impulse and T2A(t_trig) grain triggers");

        // Command signatures
        check.(formatOf.(\voiceOn) == "iffffff", "voiceOn signature is iffffff (C1)");
        check.(formatOf.(\retrigger) == "if", "retrigger signature is if (voice, velocity)");
        check.(formatOf.(\setFilter) == "ffif", "setFilter signature is ffif");
        check.(formatOf.(\setDelay) == "fff", "setDelay signature is fff");
        check.(formatOf.(\setGrainSource) == "ii", "setGrainSource ii");
        check.(formatOf.(\loadBuffer) == "is" and: { formatOf.(\recordBuffer) == "iff" }
            and: { formatOf.(\clearBuffer) == "i" } and: { formatOf.(\saveBuffer) == "is" }
            and: { formatOf.(\stopRecord) == "i" }, "buffer command signatures");

        // Buffer slots and the live input
        check.(engine.numBuffers == 8 and: { engine.bufferSeconds == 16 }, "numBuffers 8, bufferSeconds 16");
        check.(engine.buffersL.size == 8 and: { engine.buffersR.size == 8 }, "eight stereo slots as L/R pairs");
        check.(engine.buffersL.every({ arg buffer; buffer.numChannels == 1 })
            and: { engine.buffersR.every({ arg buffer; buffer.numChannels == 1 }) }, "buffers are mono");
        check.((engine.buffersL ++ engine.buffersR).every({ arg buffer; buffer.numFrames == (server.sampleRate * 16) }),
            "each buffer holds 16 s at the server rate");
        check.((engine.buffersL ++ engine.buffersR).collect(_.bufnum).asSet.size == 16, "sixteen distinct buffer numbers");
        check.(engine.bufferFrames == Array.fill(8, 0), "every slot starts empty");
        check.(engine.grainSource == Array.fill(7, 0), "every voice starts on its synth source");
        check.(engine.inputBus.numChannels == 2 and: { engine.inputBus.rate == \audio }, "inputBus is a stereo audio bus");
        check.(engine.inputSynth.defName == \strataInput
            and: { getControl.(engine.inputSynth, \out) == engine.inputBus.index }, "strataInput writes inputBus");
        check.(synthNames.(engine.voiceGroup) == List[\strataInput], "strataInput runs in the voice group");
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
        command.(\setGrainParam, 2, \bufPos, 0.5);
        command.(\setGrainSource, 2, 0);
        check.(true, "commands on a never-started voice do not throw (M6)");

        // setGrainSource on a stopped voice only records the source
        before = synthNames.(context.xg).size;
        command.(\setGrainSource, 6, 4);
        server.sync;
        check.(synthNames.(context.xg).size == before and: { engine.grainSource[6] == 4 },
            "setGrainSource on a stopped voice records the source and creates no nodes");

        // Start every voice
        7.do({ arg voice;
            command.(\voiceOn, voice, 100.0 + voice, 0.2, 0.0, 0.1, 10.0, 1.0);
        });
        server.sync;

        check.(getControl.(engine.synths[\voice3], \freq) == 103.0, "voiceOn sets freq (C1)");
        check.(engine.synths[\voice6].isNil and: { engine.synths[\grain6].defName == \strataGrainBuf },
            "voiceOn for a buffer-sourced voice builds strataGrainBuf and no voice synth");
        check.(getControl.(engine.synths[\grain6], \bufnumL) == engine.buffersL[3].bufnum
            and: { getControl.(engine.synths[\grain6], \bufnumR) == engine.buffersR[3].bufnum },
            "source 4 reads slot 4 (index 3)");
        check.(getControl.(engine.synths[\grain6], \grainSize).equalWithPrecision(0.1), "voiceOn grain args reach strataGrainBuf");
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

        // retrigger carries velocity to the voice synth (accent depth)
        before = synthNames.(context.xg).size;
        command.(\retrigger, 0, 0.5);
        server.sync;
        check.(getControl.(engine.synths[\voice0], \velocity) == 0.5, "retrigger sets velocity on the voice synth");
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
        grainIndices = names.collect({ arg name, index; if (grainDefs.includes(name) or: { name == \strataMod }) { index } }).reject(_.isNil);
        firstGrain = grainIndices.minItem;
        check.(names.size == ((6 * 3) + 2 + 1 + 4),
            "xg holds 6 voice trios, 1 buffer voice (grain + mod), the input synth, filter, delay, reverb and master (got %)".format(names.size));
        check.(names.indexOf(\strataInput) < firstGrain, "the input synth runs before grain synths");
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

        // ---- Audio sources: replace, never stack ----
        processNames = { synthNames.(engine.processGroup) };
        check.((processNames.value.collect({ arg name, index; if (grainDefs.includes(name)) { index } }).reject(_.isNil).maxItem)
            < processNames.value.indexOf(\strataMod), "grain synths run before every mod synth (mirror reaches strataMod)");
        // voice 0 running from the earlier voiceOn; switch it to buffer 3
        before = synthNames.(context.xg).size;
        oldGrain = engine.synths[\grain0];
        oldVoiceSynth = engine.synths[\voice0];
        command.(\setGrainParam, 0, \bufPos, 0.25);
        command.(\setGrainSource, 0, 3); server.sync;
        check.(synthNames.(context.xg).includes(\strataGrainBuf), "buffer source uses strataGrainBuf");
        check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 2, "one GrainBuf synth per buffer voice (voices 1 and 7)");
        check.(engine.synths[\voice0].isNil, "voice synth released in buffer mode");
        check.(getControl.(oldVoiceSynth, \gate) < 0, "the voice synth gets a short forced release");
        check.(getControl.(oldGrain, \gate) == 0, "the old grain synth is gated off");
        grainBuf = engine.synths[\grain0];
        check.(grainBuf.defName == \strataGrainBuf, "voice 1 now runs strataGrainBuf");
        check.(getControl.(grainBuf, \bufnumL) == engine.buffersL[2].bufnum, "source 3 reads slot 3 (index 2)");
        check.(getControl.(grainBuf, \bufPos) == 0.25, "grain controls set before the switch carry over (bufPos)");
        check.(getControl.(grainBuf, \pitchShift) == 2.0, "grain controls carry over (pitchShift)");
        check.(getControl.(grainBuf, \envBuf) == engine.envBuffers[0].bufnum, "grain controls carry over (envBuf)");
        check.(getControl.(grainBuf, \out) == engine.mainBus.index, "strataGrainBuf writes mainBus");
        check.(getControl.(grainBuf, \mirrorOut) == engine.granBuses[0].index, "strataGrainBuf mirrors into the voice bus");
        check.(getControl.(grainBuf, \bufFrames) == 0, "an empty slot plays with bufFrames 0");
        check.((processNames.value.collect({ arg name, index; if (grainDefs.includes(name)) { index } }).reject(_.isNil).maxItem)
            < processNames.value.indexOf(\strataMod), "a replacement grain synth still runs before every mod synth");
        after = synthNames.(context.xg).size;
        command.(\setGrainSource, 0, 3); server.sync;
        check.(engine.synths[\grain0] === grainBuf and: { synthNames.(context.xg).size == after },
            "setGrainSource with the current source changes nothing");
        command.(\retrigger, 0, 0.5); server.sync;
        check.(getControl.(grainBuf, \velocity) == 0.5, "retrigger carries velocity to strataGrainBuf (R7)");
        command.(\setModSource, 0, 1, 2);
        command.(\setModAmpAmt, 0, 1, 0.5);
        command.(\setModFreqAmt, 0, 2, 0.25);
        command.(\setVoiceParam, 0, \amp, 0.3);
        command.(\setVoiceParam, 0, \rq, 0.2);
        command.(\setGrainParam, 0, \bufRate, 0.5);
        server.sync;
        check.(getControl.(grainBuf, \modBus1) == engine.modBuses[2].index, "setModSource reaches strataGrainBuf");
        check.(getControl.(grainBuf, \modAmpAmt1) == 0.5 and: { getControl.(grainBuf, \modFreqAmt2) == 0.25 },
            "mod amounts reach strataGrainBuf");
        check.(getControl.(grainBuf, \amp).equalWithPrecision(0.3), "the voice's amp sets strataGrainBuf's level");
        check.(getControl.(grainBuf, \bufRate) == 0.5, "setGrainParam bufRate reaches strataGrainBuf");
        command.(\setGrainSource, 0, 9); server.sync;
        check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 2, "input source uses strataGrain (old GrainBuf only releasing)");
        check.(getControl.(grainBuf, \gate) == 0, "switching away gates the GrainBuf synth off");
        check.(engine.synths[\grain0].defName == \strataGrain
            and: { getControl.(engine.synths[\grain0], \in) == engine.inputBus.index }, "input source: strataGrain reads inputBus");
        check.(getControl.(engine.synths[\grain0], \mirrorLevel) == 1
            and: { getControl.(engine.synths[\grain0], \mirrorOut) == engine.granBuses[0].index },
            "input source mirrors into the voice bus (R8)");
        check.(getControl.(engine.synths[\grain0], \accentAmt) == 1, "input source carries the accent (R7)");
        check.(getControl.(engine.synths[\grain0], \amp).equalWithPrecision(0.3), "the voice's amp sets the input grain level");
        check.(getControl.(engine.synths[\grain0], \pitchShift) == 2.0, "grain controls carry over to the input source");
        command.(\retrigger, 0, 0.75); server.sync;
        check.(getControl.(engine.synths[\grain0], \velocity) == 0.75, "retrigger carries velocity to the input grain synth");
        command.(\setGrainSource, 0, 0); server.sync;
        check.(engine.synths[\voice0].notNil, "returning to synth restarts the voice synth");
        check.(engine.synths[\voice0].defName == \strataResonator, "the restarted voice synth is the voice's own SynthDef");
        check.(getControl.(engine.synths[\voice0], \rq).equalWithPrecision(0.2)
            and: { getControl.(engine.synths[\voice0], \amp).equalWithPrecision(0.3) }
            and: { getControl.(engine.synths[\voice0], \freq) == 100.0 },
            "the restarted voice synth gets the voice's current params");
        check.(getControl.(engine.synths[\voice0], \modBus1) == engine.modBuses[2].index
            and: { getControl.(engine.synths[\voice0], \modAmpAmt1) == 0.5 },
            "the restarted voice synth keeps its crossmod routing");
        check.(getControl.(engine.synths[\grain0], \in) == engine.granBuses[0].index
            and: { getControl.(engine.synths[\grain0], \mirrorLevel) == 0 }
            and: { getControl.(engine.synths[\grain0], \accentAmt) == 0 }
            and: { getControl.(engine.synths[\grain0], \amp) == 1 },
            "synth source: grain reads the voice bus, no mirror, no grain accent, unity level");
        command.(\setGrainSource, 0, 10);
        command.(\setGrainSource, 0, -1);
        server.sync;
        check.(engine.grainSource[0] == 0, "out-of-range sources are ignored");
        2.5.wait; server.sync;
        check.(synthNames.(context.xg).count({ arg n; n == \strataGrainBuf }) == 1, "the released GrainBuf synth is gone");
        check.(synthNames.(context.xg).size == before, "source switching leaves no extra nodes");

        // Recording into a slot a voice is reading
        command.(\setGrainSource, 1, 3);            // voice 1 reads slot 3 (index 2)
        2.5.wait; server.sync;
        before = synthNames.(context.xg).size;
        command.(\recordBuffer, 2, 0.1, 1.0); 0.05.wait; server.sync;   // starts after the zeroing syncs
        check.(synthNames.(engine.voiceGroup).includes(\strataRecord), "recordBuffer runs a record synth");
        0.3.wait; server.sync;
        check.(engine.bufferFrames[2] == (0.1 * server.sampleRate).round.asInteger, "recordBuffer sets the valid length");
        check.(getControl.(engine.synths[\grain1], \bufFrames) == engine.bufferFrames[2],
            "a voice reading the slot gets the new valid length");
        check.(synthNames.(context.xg).size == before, "recording into a slot a voice is reading adds no lasting nodes");
        check.(waitFor.({ bufferStateSeen.(2, 0.1) }), "the bufferState poll reports the recorded seconds");
        check.(pollMessages.notEmpty and: { pollMessages.every({ arg msg;
            (msg[1] == engine.bufferStatePoll.index) and: { msg[2].isKindOf(Float) } }) },
            "bufferState is sent as a float value poll (matron's /poll/value is typed if)");
        check.(waitFor.({ (0..7).every({ arg slot; pollMessages.any({ arg msg; decodeBufferState.(msg[2])[0] == slot }) }) }),
            "the periodic bufferState poll reports every slot");
        scratchFile = engine.scratchDir +/+ "buf3.wav";
        check.(waitFor.({ File.exists(scratchFile) }), "a completed recording writes the scratch take buf3.wav");
        1.0.wait;
        file = SoundFile.openRead(scratchFile);
        check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == engine.bufferFrames[2] }
            and: { file.sampleFormat == "int16" } and: { file.headerFormat == "WAV" },
            "the scratch take is a stereo 16-bit WAV of the valid region");
        file !? { file.close };

        // Recording replaces and clearBuffer cancels
        command.(\recordBuffer, 3, 1.0, 1.0); 0.05.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord), "a 1 s recording is running");
        command.(\clearBuffer, 3); 0.5.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.bufferFrames[3] == 0 },
            "clearBuffer stops a recording in progress");
        // cancelled before the record synth could start (still waiting for its zeroed buffers)
        command.(\recordBuffer, 3, 0.2, 1.0);
        command.(\clearBuffer, 3);
        0.5.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.bufferFrames[3] == 0 }
            and: { engine.recordSynths[3].isNil }, "a recording cancelled before it starts never runs");
        check.(File.exists(engine.scratchDir +/+ "buf4.wav").not, "a cancelled recording writes no scratch take");

        // stopRecord ends a recording early, keeping what was captured
        File.delete(engine.scratchDir +/+ "buf4.wav");
        before = synthNames.(context.xg).size;
        command.(\stopRecord, 3); 0.1.wait; server.sync;
        check.(synthNames.(context.xg).size == before and: { engine.bufferFrames[3] == 0 }
            and: { File.exists(engine.scratchDir +/+ "buf4.wav").not }, "stopRecord on an idle slot is a no-op");
        command.(\recordBuffer, 3, 1.0, 1.0); 0.05.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord), "a 1 s recording is running before stopRecord");
        0.15.wait;
        command.(\stopRecord, 3); 0.3.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.recordSynths[3].isNil },
            "stopRecord stops the record synth");
        check.(synthNames.(context.xg).size == before, "stopRecord leaves no lasting nodes");
        frames = engine.bufferFrames[3];
        check.((frames > (0.1 * server.sampleRate)) and: { frames < (0.4 * server.sampleRate) },
            "stopRecord sets the valid length to what was recorded (~0.2 s; got % s)".format(frames / server.sampleRate));
        check.(getControl.(engine.synths[\grain6], \bufFrames) == frames, "stopRecord reaches a voice reading the slot");
        check.(waitFor.({ bufferStateSeen.(3, (frames / server.sampleRate).round(0.01)) }), "stopRecord updates the poll");
        scratchFile = engine.scratchDir +/+ "buf4.wav";
        check.(waitFor.({ File.exists(scratchFile) }), "stopRecord writes the scratch take");
        1.0.wait;
        file = SoundFile.openRead(scratchFile);
        check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == frames },
            "the early-stopped scratch take holds the recorded frames");
        file !? { file.close };
        command.(\stopRecord, 3); 0.2.wait; server.sync;
        check.(engine.bufferFrames[3] == frames, "a second stopRecord is a no-op");
        command.(\clearBuffer, 3); server.sync;

        // loadBuffer: stereo, mono, too long, missing, unreadable
        stereoPath = scratchRoot +/+ "stereo.wav";
        monoPath = scratchRoot +/+ "mono.wav";
        longPath = scratchRoot +/+ "long.wav";
        textPath = scratchRoot +/+ "not-audio.wav";
        File.mkdir(scratchRoot);
        writeTestFile.(stereoPath, 22050, 11025, [0.5, -0.25]);
        writeTestFile.(monoPath, 44100, 4410, [0.4]);
        writeTestFile.(longPath, 22050, 22050 * 17, [0.1]);
        File.use(textPath, "w", { arg text; text.write("not a sound file") });
        before = synthNames.(context.xg).size;
        info = [engine.buffersL[4].bufnum, engine.buffersR[4].bufnum];
        command.(\loadBuffer, 4, longPath); 0.5.wait; server.sync;
        check.(engine.bufferFrames[4] == (22050 * 16), "loadBuffer reads at most 16 s");
        command.(\loadBuffer, 4, stereoPath); 0.3.wait; server.sync;
        check.(engine.bufferFrames[4] == 11025, "loadBuffer sets the valid length from the file");
        check.([engine.buffersL[4].bufnum, engine.buffersR[4].bufnum] == info, "loadBuffer keeps the slot's bufnums");
        check.((bufferSample.(engine.buffersL[4], 100) - 0.5).abs < 0.001
            and: { (bufferSample.(engine.buffersR[4], 100) + 0.25).abs < 0.001 }, "a stereo file fills left and right");
        check.(bufferSample.(engine.buffersL[4], 20000) == 0, "loadBuffer zeroes the slot first (no tail of the longer file)");
        check.(waitFor.({ bufferStateSeen.(4, 0.5) }), "the poll reports a loaded file's seconds at the file's rate");
        command.(\loadBuffer, 4, scratchRoot +/+ "missing.wav"); 0.2.wait; server.sync;
        command.(\loadBuffer, 4, textPath); 0.2.wait; server.sync;
        check.(engine.bufferFrames[4] == 11025 and: { (bufferSample.(engine.buffersL[4], 100) - 0.5).abs < 0.001 },
            "a missing or unreadable file leaves the slot unchanged");
        command.(\loadBuffer, 5, monoPath); 0.3.wait; server.sync;
        check.((bufferSample.(engine.buffersL[5], 10) - 0.4).abs < 0.001
            and: { (bufferSample.(engine.buffersR[5], 10) - 0.4).abs < 0.001 }, "a mono file fills both channels");
        check.(synthNames.(context.xg).size == before, "loading adds no nodes");

        // saveBuffer writes the valid region as a stereo 16-bit WAV
        savePath = scratchRoot +/+ "saved/take-buf5.wav";
        command.(\saveBuffer, 4, savePath);
        check.(waitFor.({ File.exists(savePath) }), "saveBuffer writes the file (creating its directory)");
        1.0.wait;
        file = SoundFile.openRead(savePath);
        check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == 11025 }
            and: { file.sampleRate == 22050 } and: { file.sampleFormat == "int16" },
            "the saved file is stereo 16-bit at the content's rate, valid frames only");
        if (file.notNil) {
            data = FloatArray.newClear(2 * 200);
            file.readData(data);
            file.close;
            check.(((data[200] - 0.5).abs < 0.001) and: { (data[201] + 0.25).abs < 0.001 },
                "the saved file interleaves left and right");
        };
        command.(\saveBuffer, 6, scratchRoot +/+ "empty.wav"); 0.5.wait;
        check.(File.exists(scratchRoot +/+ "empty.wav").not, "saving an empty slot writes nothing");
        check.(synthNames.(context.xg).size == before, "saving adds no nodes");

        // A file's sample rate becomes the slot's rate scale; recording restores the server rate.
        // Voice 7 (engine voice 6) reads slot 4 (index 3).
        command.(\loadBuffer, 3, stereoPath); 0.3.wait; server.sync;
        check.(getControl.(engine.synths[\grain6], \bufRateScale).equalWithPrecision(22050 / server.sampleRate)
            and: { getControl.(engine.synths[\grain6], \bufFrames) == 11025 },
            "a voice reading a loaded slot plays it at the file's rate");
        command.(\recordBuffer, 3, 0.1, 1.0); 0.4.wait; server.sync;
        check.(getControl.(engine.synths[\grain6], \bufRateScale) == 1, "recording resets the slot to the server's rate");

        command.(\clearBuffer, 2); server.sync;
        check.(engine.bufferFrames[2] == 0, "clearBuffer resets it");
        check.(getControl.(engine.synths[\grain1], \bufFrames) == 0, "clearBuffer reaches a voice reading the slot");
        check.(bufferSample.(engine.buffersL[2], 10) == 0, "clearBuffer zeroes the slot");
        command.(\setGrainSource, 1, 0);
        2.5.wait; server.sync;

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
        check.((engine.buffersL ++ engine.buffersR).every({ arg buffer; buffer.bufnum.isNil }), "free frees the buffer slots");
        check.(engine.inputBus.index.isNil, "free frees the input bus");
        engine.bufferStatePoll.stop;
    } { arg error;
        error.reportError;
        failures = failures + 1;
        "FAIL exception during engine check".postln;
    };

    ("rm -rf " ++ scratchRoot.shellQuote).systemCmd;
    if (failures == 0) { "ENGINE CHECK PASSED".postln; exitCode = 0 } {
        ("ENGINE CHECK FAILED: % failures".format(failures)).postln; exitCode = 1 };
    server.quit;
    1.wait;
    exitCode.exit;
});
)
