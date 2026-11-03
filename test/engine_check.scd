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

// true when some UGen of the SynthDef reads the named control (it is not
// declared and left unused)
var controlFeedsAUGen = { arg defName, controlName;
    var desc = SynthDescLib.global.at(defName);
    var control = desc.controls.detect({ arg each; each.name == controlName });
    control.notNil and: { desc.def.children.any({ arg ugen;
        (ugen.inputs ? []).any({ arg input;
            input.isKindOf(OutputProxy) and: { input.source.isKindOf(Control) }
                and: { (input.source.specialIndex + input.outputIndex) == control.index }
        })
    }) }
};

// true when the named control is the gate (first input) of an EnvGen
// whose doneAction (input 4, after levelScale, levelBias, timeScale) frees the synth
var controlTriggersFreeingEnvGen = { arg defName, controlName;
    var desc = SynthDescLib.global.at(defName);
    var control = desc.controls.detect({ arg each; each.name == controlName });
    control.notNil and: { desc.def.children.any({ arg ugen;
        var gate = ugen.inputs.notNil.if({ ugen.inputs[0] });
        ugen.isKindOf(EnvGen) and: { gate.isKindOf(OutputProxy) } and: { gate.source.isKindOf(Control) }
            and: { (gate.source.specialIndex + gate.outputIndex) == control.index } and: { ugen.inputs[4] == 2 }
    }) }
};

// A voice's synths as the engine tracks them: [voice synth, grain synth, mod synth]
var voiceTrio = { arg voice;
    [engine.voiceKey(voice), engine.grainKey(voice), engine.modKey(voice)].collect({ arg key; engine.synths[key] })
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
        var oldTrio, before, after, silentIndex, startedNames, masterUGens, envSamples;
        var oldGrain, oldVoiceSynth, grainBuf, processNames, scratchFile, savePath, file, frames, data;
        var stereoPath, monoPath, longPath, textPath, info;
        var grainInUGens, tone, probe, peakBus, readPeak, duringPeak, afterPeak;
        var grainCount, voiceCount, grainBefore, voiceBefore;
        var countVoiceAndGrain, maxGrainCount, maxVoiceCount, staleGrain;

        CroneDefs.sendDefs(server);
        // Check-only helpers: a test tone (written into the input bus) and a
        // peak meter on a stereo bus (reset with t_reset, read from a control bus)
        SynthDef(\strataCheckTone, { arg out; Out.ar(out, SinOsc.ar(440, 0, 0.5) ! 2) }).add;
        SynthDef(\strataCheckPeak, { arg in, out, t_reset = 0;
            Out.kr(out, A2K.kr(Peak.ar(In.ar(in, 2).abs.sum, t_reset)));
        }).add;
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
            check.(controlFeedsAUGen.(name, \bend), "% has a bend control (MIDI pitchbend) that reaches its frequency".format(name));
            // EnvGen inputs: gate, levelScale, ...; the accent's levelScale is
            // the velocity control (sampled per trigger), not the constant 1
            check.(SynthDescLib.global.at(name).def.children.any({ arg ugen;
                ugen.isKindOf(EnvGen) and: { ugen.inputs[1].isKindOf(OutputProxy) }
            }), "% scales its accent envelope by velocity through levelScale".format(name));
        });
        // The engine's cut (cutSynth) triggers a freeing fade on the kill
        // control, independent of whatever release the gate envelope is in (F4)
        (voiceDefs ++ grainDefs).do({ arg name;
            check.(controlTriggersFreeingEnvGen.(name, \kill), "% has a kill fade (kill triggers a freeing EnvGen)".format(name));
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
        check.(controlFeedsAUGen.(\strataGrainBuf, \bend), "strataGrainBuf's bend control reaches its rate");
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
        // strataGrain mirrors strataGrainBuf: one mono GrainIn per input
        // channel panned as a pair, so pan spread works for synth and input
        // sources and nothing is doubled (F1)
        grainInUGens = SynthDescLib.global.at(\strataGrain).def.children;
        check.(grainInUGens.count({ arg ugen; ugen.isKindOf(GrainIn) }) == 2
            and: { grainInUGens.select({ arg ugen; ugen.isKindOf(GrainIn) }).every({ arg ugen; ugen.channels.size == 1 }) },
            "strataGrain runs two mono GrainIns (L/R; got %)".format(grainInUGens.count({ arg ugen; ugen.isKindOf(GrainIn) })));
        check.(grainInUGens.count({ arg ugen; ugen.isKindOf(PitchShift) }) == 2,
            "strataGrain pitch-shifts the stereo pair once (two mono PitchShifts; got %)".format(
                grainInUGens.count({ arg ugen; ugen.isKindOf(PitchShift) })));
        check.(grainInUGens.any({ arg ugen; ugen.isKindOf(Balance2) }), "strataGrain pans with Balance2");
        check.(grainInUGens.select({ arg ugen; ugen.isKindOf(Out) }).collect({ arg ugen; ugen.inputs.size - 1 }) == [2, 2],
            "strataGrain has one stereo Out to mainBus and one to the mirror (got %)".format(
                grainInUGens.select({ arg ugen; ugen.isKindOf(Out) }).collect({ arg ugen; ugen.inputs.size - 1 })));
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

        // Pitchbend: bend is a voice-level control (voice synth; strataGrainBuf for a buffer source)
        command.(\setVoiceParam, 0, \bend, 1.05);
        command.(\setVoiceParam, 6, \bend, 0.95);
        server.sync;
        check.(getControl.(engine.synths[\voice0], \bend).equalWithPrecision(1.05), "setVoiceParam bend reaches voice0");
        check.(getControl.(engine.synths[\grain6], \bend).equalWithPrecision(0.95),
            "setVoiceParam bend reaches a buffer-sourced voice's strataGrainBuf");
        command.(\setVoiceParam, 0, \bend, 1.0);
        command.(\setVoiceParam, 6, \bend, 1.0);

        // retrigger clamps its velocity to 0-1 (MIDI sends velocity / 127)
        command.(\retrigger, 3, 2.5); server.sync;
        check.(getControl.(engine.synths[\voice3], \velocity) == 1, "retrigger clamps velocity above 1");
        command.(\retrigger, 3, -0.5); server.sync;
        check.(getControl.(engine.synths[\voice3], \velocity) == 0, "retrigger clamps velocity below 0");
        command.(\retrigger, 3, 1.0);
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
        check.(getControl.(oldGrain, \gate) < 0, "the old grain synth gets a forced release (grainRelease)");
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
        check.(getControl.(grainBuf, \gate) < 0, "switching away releases the GrainBuf synth (forced release)");
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
        // Two writes to one path back to back: the newer one wins, the file is never mixed
        command.(\loadBuffer, 7, longPath); 0.5.wait; server.sync;     // 16 s at 22050 Hz: a long interleave
        savePath = scratchRoot +/+ "race/same.wav";
        engine.writeChunkWait = 0.02;          // the long interleave now takes about 0.9 s
        command.(\saveBuffer, 7, savePath);
        0.3.wait;                              // the first interleave is under way
        command.(\saveBuffer, 4, savePath);                              // 11025 frames, 0.5 / -0.25
        check.(waitFor.({ File.exists(savePath) }, 5), "back-to-back writes to one path produce the file");
        2.0.wait;
        file = SoundFile.openRead(savePath);
        check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == 11025 } and: { file.sampleRate == 22050 },
            "an older write to the same path abandons: the file is the second write (got % frames)".format(file !? _.numFrames));
        if (file.notNil) {
            data = FloatArray.newClear(2 * 11025);
            file.readData(data);
            file.close;
            check.(data.size == (2 * 11025) and: { (0..11024).every({ arg frame;
                    ((data[frame * 2] - 0.5).abs < 0.001) and: { (data[(frame * 2) + 1] + 0.25).abs < 0.001 } }) },
                "the surviving file holds exactly the second write's samples");
        };
        // the other order: a short write then a long one; the long (newer) one wins
        command.(\saveBuffer, 4, savePath);
        command.(\saveBuffer, 7, savePath);
        3.0.wait;
        engine.writeChunkWait = 0.001;
        file = SoundFile.openRead(savePath);
        check.(file.notNil and: { file.numFrames == (22050 * 16) }, "a newer long write replaces an older short one");
        file !? { file.close };
        check.(PathName(savePath.dirname).files.collect(_.fileName) == [PathName(savePath).fileName],
            "no .part files are left beside the written file (got %)".format(PathName(savePath.dirname).files.collect(_.fileName)));
        check.(PathName(Platform.defaultTempDir).files.select({ arg each; each.fileName.beginsWith("strata-buf") }).isEmpty,
            "no temporary float files are left behind");

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

        // A voice reading a slot that is being recorded stays silent until
        // the take completes, instead of looping the take's first grain (F3).
        // A test tone in the input bus is recorded; a peak meter on voice 1's
        // bus hears the strataGrainBuf mirror.
        command.(\setGrainSource, 1, 3);           // slot 3 (index 2), empty
        2.5.wait; server.sync;                     // the voice synth's release is over
        peakBus = Bus.control(server, 1);
        tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
        probe = Synth(\strataCheckPeak, [\in, engine.granBuses[1], \out, peakBus], engine.processGroup, \addToTail);
        readPeak = {
            var condition = Condition(false), value;
            probe.set(\t_reset, 1);
            0.3.wait;
            peakBus.get({ arg result; value = result; condition.test = true; condition.signal });
            condition.wait;
            value
        };
        command.(\recordBuffer, 2, 1.0, 1.0); 0.3.wait; server.sync;
        duringPeak = readPeak.value;               // 0.3-0.6 s into the 1 s take
        check.(engine.recordSynths[2].notNil and: { getControl.(engine.synths[\grain1], \bufFrames) == 0 },
            "the slot is still recording (bufFrames 0)");
        check.(duringPeak < 0.001, "a voice reading a slot being recorded is silent (peak %)".format(duringPeak));
        0.8.wait; server.sync;
        check.(engine.recordSynths[2].isNil and: { engine.bufferFrames[2] > 0 }, "the take has completed");
        afterPeak = readPeak.value;
        check.(afterPeak > 0.01, "after the take completes the voice plays it (peak %)".format(afterPeak));
        tone.free; probe.free; peakBus.free;
        command.(\clearBuffer, 2);
        command.(\setGrainSource, 1, 0);
        2.5.wait; server.sync;

        // A burst of source switches (E3 scrolling) keeps at most one
        // releasing grain synth per voice: each switch cuts the one an
        // earlier switch left releasing, and the voice synths it released (F4)
        before = synthNames.(context.xg).size;
        names = synthNames.(context.xg);
        grainBefore = names.count({ arg name; grainDefs.includes(name) });
        voiceBefore = names.count({ arg name; voiceDefs.includes(name) });
        [1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source; command.(\setGrainSource, 4, source) });
        0.3.wait; server.sync;
        names = synthNames.(context.xg);
        grainCount = names.count({ arg name; grainDefs.includes(name) });
        voiceCount = names.count({ arg name; voiceDefs.includes(name) });
        check.(grainCount == (grainBefore + 1),
            "10 source switches leave the live grain synth and one releasing (% grain synths, % before)".format(grainCount, grainBefore));
        check.(voiceCount == (voiceBefore - 1),
            "the voice synths the burst started and released are cut too (% voice synths, % before)".format(voiceCount, voiceBefore));
        2.5.wait; server.sync;
        names = synthNames.(context.xg);
        check.(names.count({ arg name; grainDefs.includes(name) }) == grainBefore
            and: { engine.fadingSynths[4].isEmpty } and: { engine.releasingSynths[4].isEmpty },
            "after the release no grain synth is left over and nothing stays tracked (% grain synths, fading %, releasing %)".format(names.count({ arg name; grainDefs.includes(name) }), engine.fadingSynths[4], engine.releasingSynths[4]));
        command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "the burst leaves no extra nodes");

        // The same switches spread over many control blocks (real E3 detents):
        // a cut must also end a synth that is already in its forced release,
        // which a second, shorter forced release (gate -1 - time) cannot (F4)
        countVoiceAndGrain = {
            var list = synthNames.(context.xg);
            [list.count({ arg name; grainDefs.includes(name) }), list.count({ arg name; voiceDefs.includes(name) })]
        };
        # grainBefore, voiceBefore = countVoiceAndGrain.value;
        maxGrainCount = 0; maxVoiceCount = 0;
        [1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source;
            command.(\setGrainSource, 4, source);
            0.1.wait; server.sync;    // longer than switchCutTime, so this switch has been processed
            # grainCount, voiceCount = countVoiceAndGrain.value;
            maxGrainCount = max(maxGrainCount, grainCount);
            maxVoiceCount = max(maxVoiceCount, voiceCount);
        });
        check.(maxGrainCount <= (grainBefore + 1),
            "switches 0.1 s apart keep at most the live grain synth and one releasing (at most % grain synths, % before)".format(maxGrainCount, grainBefore));
        check.(maxVoiceCount <= (voiceBefore + 1),
            "switches 0.1 s apart keep at most one releasing voice synth (at most % voice synths, % before)".format(maxVoiceCount, voiceBefore));
        command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "spaced switches leave no extra nodes");
        [1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source; command.(\setGrainSource, 4, source); 0.02.wait });
        0.1.wait; server.sync;
        # grainCount, voiceCount = countVoiceAndGrain.value;
        check.((grainCount <= (grainBefore + 1)) and: { voiceCount <= voiceBefore },
            "switches 0.02 s apart end with the live grain synth and one releasing (% grain synths, % voice synths; % and % before)".format(
                grainCount, voiceCount, grainBefore, voiceBefore));
        2.5.wait; server.sync;
        check.(engine.fadingSynths[4].isEmpty and: { engine.releasingSynths[4].isEmpty },
            "after the release nothing a spaced burst released stays tracked");
        command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "the spaced burst leaves no extra nodes");

        // voiceOn never stacks synths (M6; spec section 5 re-gate). A running
        // voice keeps its synths and takes the voiceOn values.
        before = synthNames.(context.xg).size;
        oldTrio = voiceTrio.(0);
        command.(\voiceOn, 0, 150.0, 0.2, 0.0, 0.1, 10.0, 1.0);
        server.sync;
        check.(synthNames.(context.xg).size == before, "voiceOn on a running voice creates no nodes (M6)");
        check.(voiceTrio.(0).every({ arg synth, index; synth === oldTrio[index] }), "voiceOn on a running voice keeps its synths");
        check.((getControl.(oldTrio[0], \freq) == 150.0) and: { getControl.(oldTrio[0], \gate) == 1 },
            "voiceOn on a running voice applies its freq with set");

        // voiceOff then voiceOn within the release re-gates the same synths
        oldTrio = voiceTrio.(2);  // Folder: 6 s voice release
        command.(\setVoiceParam, 2, \bend, 1.1);
        command.(\voiceOff, 2); server.sync;
        check.(oldTrio.every({ arg synth; getControl.(synth, \gate) == 0 }), "voiceOff gates the trio off");
        command.(\voiceOn, 2, 220.0, 0.25, 0.1, 0.2, 12.0, 1.5); server.sync;
        check.(synthNames.(context.xg).size == before, "voiceOn during the release creates no nodes");
        check.(voiceTrio.(2).every({ arg synth, index; synth === oldTrio[index] }), "voiceOn during the release re-gates the same synths");
        check.(oldTrio.every({ arg synth; getControl.(synth, \gate) == 1 }), "re-gated synths are back at gate 1");
        check.((getControl.(oldTrio[0], \freq) == 220.0) and: { getControl.(oldTrio[0], \pan).equalWithPrecision(0.1) }
            and: { getControl.(oldTrio[1], \grainSize).equalWithPrecision(0.2) } and: { getControl.(oldTrio[1], \grainDensity) == 12.0 }
            and: { getControl.(oldTrio[1], \pitchShift) == 1.5 }, "re-gating applies the voiceOn values with set");
        check.(getControl.(oldTrio[0], \bend) == 1, "voiceOn resets bend to 1");

        // Partway through the release the grain (2 s) and mod (0.5 s) synths
        // have freed and the voice synth still releases: it is re-gated, the
        // other two are started
        command.(\voiceOff, 2); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == (before - 2), "2.5 s after voiceOff only the voice synth still releases");
        command.(\voiceOn, 2, 220.0, 0.25, 0.1, 0.2, 12.0, 1.5); server.sync;
        after = voiceTrio.(2);
        check.(synthNames.(context.xg).size == before, "voiceOn late in the release brings back one trio");
        check.((after[0] === oldTrio[0]) and: { after[1] !== oldTrio[1] } and: { after[2] !== oldTrio[2] }
            and: { after.every({ arg synth; synth.isPlaying }) }, "the releasing voice synth is re-gated, grain and mod synths are new");
        check.(getControl.(after[0], \gate) == 1, "the re-gated voice synth is at gate 1");

        // After the whole release voiceOn creates fresh synths (Karplus: 2 s release)
        oldTrio = voiceTrio.(5);
        command.(\voiceOff, 5); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == (before - 3), "a released voice's synths free themselves");
        check.(engine.releasingSynths[5].isEmpty, "freed synths are forgotten");
        command.(\voiceOn, 5, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
        after = voiceTrio.(5);
        check.((synthNames.(context.xg).size == before) and: { after.every({ arg synth, index; synth.notNil and: { synth !== oldTrio[index] } }) },
            "voiceOn after the release creates a fresh trio");

        // voiceOn and voiceOff in one control block (a MIDI note-on and
        // note-off in one bundle): the trio created in that block still
        // releases and frees, instead of waiting forever on an envelope that
        // never started (F4)
        command.(\voiceOff, 5); 2.5.wait; server.sync;
        server.makeBundle(0.1, {
            command.(\voiceOn, 5, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0);
            command.(\voiceOff, 5);
        });
        oldTrio = engine.releasingSynths[5].values.asArray;
        0.3.wait; server.sync;
        check.((oldTrio.size == 3) and: { synthNames.(context.xg).size == before },
            "voiceOn and voiceOff in one bundle create a trio that is releasing");
        2.5.wait; server.sync;
        check.((synthNames.(context.xg).size == (before - 3)) and: { engine.releasingSynths[5].isEmpty }
            and: { oldTrio.every({ arg synth; synth.isPlaying.not }) },
            "a trio started and released in one control block frees after its release (% nodes, % before)".format(
                synthNames.(context.xg).size, before));
        command.(\voiceOn, 5, 200.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
        check.(synthNames.(context.xg).size == before, "the voice starts again after a same-block note");

        // A buffer-sourced voice (a grain and a mod synth, no voice synth) re-gates too
        oldTrio = voiceTrio.(6);
        command.(\voiceOff, 6); server.sync;
        command.(\voiceOn, 6, 100.0, 0.25, 0.0, 0.3, 10.0, 1.0); server.sync;
        after = voiceTrio.(6);
        check.((synthNames.(context.xg).size == before) and: { after[0].isNil } and: { after[1] === oldTrio[1] }
            and: { after[2] === oldTrio[2] } and: { getControl.(after[1], \gate) == 1 }
            and: { getControl.(after[1], \grainSize).equalWithPrecision(0.3) }, "a buffer-sourced voice re-gates its grain and mod synths");
        // The slot changes while the voice releases: the re-gated grain synth
        // takes its new length and rate (M1). Slot 4 holds a 0.1 s take at the server rate.
        command.(\voiceOff, 6); server.sync;
        command.(\loadBuffer, 3, stereoPath); 0.3.wait; server.sync;    // 11025 frames at 22050 Hz
        command.(\voiceOn, 6, 100.0, 0.25, 0.0, 0.3, 10.0, 1.0); server.sync;
        after = voiceTrio.(6);
        check.((after[1] === oldTrio[1]) and: { getControl.(after[1], \bufFrames) == 11025 }
            and: { getControl.(after[1], \bufRateScale).equalWithPrecision(22050 / server.sampleRate) },
            "a re-gated buffer grain synth takes a slot change made during its release (bufFrames %)".format(
                getControl.(after[1], \bufFrames)));

        // A source switch while the voice is releasing: voiceOn builds the new
        // source's grain synth and re-gates the mod synth; the old voice and
        // grain synths finish within the grain release (no orphans)
        oldTrio = voiceTrio.(3);  // Sub: 12 s voice release
        command.(\setGrainParam, 3, \grainMode, 1);
        command.(\setGrainParam, 3, \envShape, 2);
        command.(\voiceOff, 3);
        command.(\setGrainSource, 3, 9);  // the input; only recorded: the voice is stopped
        command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
        after = voiceTrio.(3);
        // voiceOn merges its values into the voice's grain controls, so a new
        // grain synth starts in the voice's grain mode (no stray continuous grains; M2)
        check.((getControl.(after[1], \grainMode) == 1) and: { getControl.(after[1], \envBuf) == engine.envBuffers[1].bufnum }
            and: { getControl.(after[1], \grainSize).equalWithPrecision(0.1) },
            "a grain synth built by voiceOn keeps the voice's grain mode and envelope, with voiceOn's size");
        command.(\setGrainParam, 3, \grainMode, 0);
        command.(\setGrainParam, 3, \envShape, 0);
        check.(after[0].isNil and: { after[1].defName == \strataGrain } and: { after[1] !== oldTrio[1] }
            and: { getControl.(after[1], \in) == engine.inputBus.index }
            and: { after[2] === oldTrio[2] }, "voiceOn after a source switch in the release builds the new grain synth, re-gates the mod synth");
        2.5.wait; server.sync;
        check.(oldTrio[0].isPlaying.not and: { oldTrio[1].isPlaying.not } and: { synthNames.(context.xg).size == (before - 1) },
            "the old voice and grain synths free themselves within the grain release (no orphans)");
        // an input-sourced voice re-gates its grain and mod synths
        oldTrio = voiceTrio.(3);
        command.(\voiceOff, 3); server.sync;
        command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
        after = voiceTrio.(3);
        check.((synthNames.(context.xg).size == (before - 1)) and: { after[0].isNil } and: { after[1] === oldTrio[1] }
            and: { after[2] === oldTrio[2] } and: { getControl.(after[1], \gate) == 1 }, "an input-sourced voice re-gates its grain and mod synths");
        command.(\setGrainSource, 3, 0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "switching back to the synth restores the trio");

        // voiceOff after a voiceOn that left the previous source's grain
        // synth releasing beside the new one: that superseded grain synth is
        // cut, not left releasing untracked where no later switch could cut it (F4)
        oldTrio = voiceTrio.(3);
        command.(\voiceOff, 3);
        command.(\setGrainSource, 3, 9);
        command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
        staleGrain = oldTrio[1];
        check.(staleGrain.isPlaying and: { engine.synths[\grain3] !== staleGrain }, "the previous grain synth still releases beside the new one");
        command.(\voiceOff, 3); 0.15.wait; server.sync;
        check.(staleGrain.isPlaying.not, "voiceOff cuts a releasing grain synth that voiceOn superseded");
        command.(\setGrainSource, 3, 0);
        command.(\voiceOn, 3, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "the voice is back on its synth with one trio");

        // A re-gated synth whose release ends just as the gate arrives frees
        // anyway; the engine starts that synth again
        oldTrio = voiceTrio.(2);
        server.sendMsg(\n_free, oldTrio[1].nodeID);  // ends without sclang having freed it
        0.2.wait; server.sync;
        after = voiceTrio.(2);
        check.(after[1].notNil and: { after[1] !== oldTrio[1] } and: { after[1].isPlaying }
            and: { synthNames.(context.xg).size == before }, "a running voice's synth that ends unexpectedly is started again");

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
