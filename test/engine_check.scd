// engine_check.scd
// Runtime check of lib/Engine_Strata.sc against the real norns CroneEngine
// and CroneAudioContext classes. Run through test/run_engine_check.sh, which
// sets up the class library. Boots a local scsynth (on UDP port $STRATA_SC_PORT, default 57110); the engine's output is
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
// scsynth's UDP port: STRATA_SC_PORT (default 57110), so checks in different
// worktrees can run side by side on one machine
var scPort = if("STRATA_SC_PORT".getenv.isNil or: { "STRATA_SC_PORT".getenv.size == 0 }, 57110, { "STRATA_SC_PORT".getenv.asInteger });
var scratchRoot = Platform.defaultTempDir +/+ ("strata-engine-check-" ++ Date.getDate.stamp ++ "-" ++ scPort);
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

// Wait (inside the check routine) for a reply that signals condition, at
// most timeout seconds: a reply that never comes (a node or control the
// engine does not have, a server that went away) fails the check instead
// of hanging it. Returns true if the reply arrived.
var awaitReply = { arg condition, timeout = 5;
    var timedOut = false;
    SystemClock.sched(timeout, {
        if (condition.test.not) { timedOut = true; condition.test = true; condition.signal };
        nil
    });
    condition.wait;
    if (timedOut) { failures = failures + 1; ("FAIL no server reply within % s".format(timeout)).postln };
    timedOut.not
};

// Depth-first list of synth def names under a node, from /g_queryTree.
var synthNames = { arg group;
    var condition = Condition(false), reply, list = List.new, index = 2, parse;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal },
        '/g_queryTree.reply', server.addr).oneShot;
    server.sendMsg('/g_queryTree', group.nodeID, 0);
    if (awaitReply.(condition).not) { reply = [nil, 0, 0, 0] };  // parses as an empty tree
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

// Depth-first list of the synths under a node with their controls, from
// /g_queryTree with controls: one Event (id, def, controls) per synth. One
// reply, so it never asks a synth that is freeing in the meantime.
var synthNodes = { arg group;
    var condition = Condition(false), reply, list = List.new, index = 2, parse;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal },
        '/g_queryTree.reply', server.addr).oneShot;
    server.sendMsg('/g_queryTree', group.nodeID, 1);
    if (awaitReply.(condition).not) { reply = [nil, 0, 0, 0] };  // parses as an empty tree
    parse = {
        var nodeID = reply[index], numChildren = reply[index + 1], def, controls;
        index = index + 2;
        if (numChildren == -1) {
            def = reply[index].asSymbol;
            controls = IdentityDictionary.new;
            reply[index + 1].do({ arg pair;
                controls[reply[index + 2 + (pair * 2)].asSymbol] = reply[index + 3 + (pair * 2)];
            });
            index = index + 2 + (reply[index + 1] * 2);
            list.add((id: nodeID, def: def, controls: controls));
        } {
            numChildren.do({ parse.value });
        };
    };
    parse.value;
    list
};

// A voice's grain synths (live or releasing) in node order: [position in
// nodes, reads the voice bus?] for each synth whose mirrorOut is the voice bus
var voiceGrainNodes = { arg nodes, voice;
    var voiceBus = engine.granBuses[voice].index;
    nodes.collect({ arg node, position;
        if (grainDefs.includes(node.def) and: { node.controls[\mirrorOut] == voiceBus }) {
            [position, (node.def == \strataGrain) and: { node.controls[\in] == voiceBus }]
        }
    }).reject(_.isNil)
};
var voiceModPosition = { arg nodes, voice;
    nodes.detectIndex({ arg node; (node.def == \strataMod) and: { node.controls[\in] == engine.granBuses[voice].index } })
};
// Every running voice's grain synths run before its own mod synth
var grainsBeforeOwnMods = {
    var nodes = synthNodes.(engine.processGroup);
    (0..(engine.numVoices - 1)).every({ arg voice;
        var grains = voiceGrainNodes.(nodes, voice), modPosition = voiceModPosition.(nodes, voice);
        grains.isEmpty or: { modPosition.notNil and: { grains.every({ arg each; each[0] < modPosition }) } }
    })
};

var controlDefault = { arg defName, controlName;
    var control = SynthDescLib.global.at(defName).controls.detect({ arg each; each.name == controlName });
    control !? { control.defaultValue }
};

// Wait (inside the check routine) until condition is true or timeout passes
var waitFor = { arg condition, timeout = 3;
    var elapsed = 0;
    while { condition.value.not and: { elapsed < timeout } } { 0.05.wait; elapsed = elapsed + 0.05 };
    condition.value
};

// true when the velocity control feeds nothing but EnvGen levelScale inputs
// (a per-trigger accent depth), never a bare multiplier on a running signal.
// One narrow allowance, for \strataKarplus (or a check SynthDef given
// pluckAllowed true): velocity may scale a T2A of the t_trig control (a
// single-sample impulse per retrigger) on its way to the pluck excitation,
// and nowhere else. sclang fuses `T2A * velocity + Impulse` into a MulAdd,
// so the product is either a MulAdd (T2A and velocity, plus anything but
// velocity) or a '*' BinaryOpUGen whose users are '+' sums; every user of
// the MulAdd (or of those sums) must be a Decay's input (the noise burst)
// or a Pluck's trigger (#47; checkKarplusMutants checks the check).
var velocityOnlyScalesAccents = { arg defName, pluckAllowed;
    var desc = SynthDescLib.global.at(defName);
    var ugens = desc.def.children, allowPluck = pluckAllowed ? (defName == \strataKarplus);
    var controlIndex = { arg name; desc.controls.detect({ arg each; each.name == name }) !? { arg control; control.index } };
    var velocityIndex = controlIndex.(\velocity), trigIndex = controlIndex.(\t_trig);
    var isControl = { arg input, index;
        index.notNil and: { input.isKindOf(OutputProxy) } and: { input.source.isKindOf(Control) }
            and: { (input.source.specialIndex + input.outputIndex) == index }
    };
    var isVelocity = { arg input; isControl.(input, velocityIndex) };
    var isTrigImpulse = { arg input; input.isKindOf(T2A) and: { isControl.(input.inputs[0], trigIndex) } };
    // [ugen, input index] for every input of every UGen that is source
    var usersOf = { arg source;
        ugens.collect({ arg ugen; (ugen.inputs ? []).collect({ arg input, index; if (input === source) { [ugen, index] } }).reject(_.isNil) })
            .flatten(1)
    };
    var excitesOnly = { arg source;
        var users = usersOf.(source);
        users.notEmpty and: { users.every({ arg pair;
            (pair[0].isKindOf(Decay) and: { pair[1] == 0 }) or: { pair[0].isKindOf(Pluck) and: { pair[1] == 1 } }
        }) }
    };
    var scalesTrigImpulse = { arg factors;
        (factors.select(isVelocity).size == 1) and: { factors.select(isTrigImpulse).size == 1 }
    };
    var isPluckImpulseProduct = { arg ugen;
        var users;
        allowPluck and: {
            case
            { ugen.isKindOf(MulAdd) } {
                scalesTrigImpulse.(ugen.inputs.copyRange(0, 1)) and: { isVelocity.(ugen.inputs[2]).not }
                    and: { excitesOnly.(ugen) }
            }
            { ugen.isKindOf(BinaryOpUGen) and: { ugen.operator == '*' } } {
                users = usersOf.(ugen);
                scalesTrigImpulse.(ugen.inputs) and: { users.notEmpty } and: { users.every({ arg pair;
                    pair[0].isKindOf(BinaryOpUGen) and: { pair[0].operator == '+' } and: { excitesOnly.(pair[0]) }
                }) }
            }
            { false }
        }
    };
    var users;
    if (velocityIndex.isNil) { false } {
        users = ugens.select({ arg ugen; (ugen.inputs ? []).any(isVelocity) });
        users.notEmpty and: { users.every({ arg ugen;
            isPluckImpulseProduct.(ugen) or: {
                ugen.isKindOf(EnvGen) and: { ugen.inputs.every({ arg input, index; isVelocity.(input).not or: { index == 1 } }) }
            }
        }) }
    }
};

// The Karplus allowance above is narrow (#47): a check-only copy of the
// Karplus excitation passes with the allowance on, and copies bent three
// ways fail with it: the impulse a T2A of the gate instead of t_trig, the
// velocity-scaled impulse also scaling the output, and the excitation
// trigger smeared into a running level (a Lag) that scales the output
var checkKarplusMutants = {
    var addKarplusCopy = { arg name, mutation;
        SynthDef(name, { arg out, gate = 1, t_trig = 0, velocity = 1;
            var accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);
            var exciteTrig = Impulse.ar(0.3) + (T2A.ar(if (mutation == \gateImpulse) { gate } { t_trig }) * velocity);
            var sig = Pluck.ar(Decay.ar(exciteTrig, 0.01, PinkNoise.ar(1)), exciteTrig, 0.1, 0.005, 4, 0.5);
            if (mutation == \impulseToOutput) { sig = sig * (1 + (T2A.ar(t_trig) * velocity)) };
            if (mutation == \impulseLevel) { sig = sig * Lag.ar(exciteTrig, 0.5) };
            Out.ar(out, sig * (1 + accent));
        }).add;
    };
    [[\strataCheckKarplusCopy, nil, true, "a faithful copy of the Karplus excitation"],
        [\strataCheckKarplusGateImpulse, \gateImpulse, false, "a velocity-scaled T2A of the gate (not of t_trig)"],
        [\strataCheckKarplusImpulseOut, \impulseToOutput, false, "a velocity-scaled T2A of t_trig that also scales the output"],
        [\strataCheckKarplusImpulseLevel, \impulseLevel, false, "an excitation trigger smeared into a level that scales the output"]
    ].do({ arg mutant;
        addKarplusCopy.(mutant[0], mutant[1]);
        check.(velocityOnlyScalesAccents.(mutant[0], true) == mutant[2],
            "the strict velocity check % % under the Karplus allowance".format(
                if (mutant[2]) { "accepts" } { "rejects" }, mutant[3]));
    });
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

// The engine's temporary float files (strata-buf*) in the shared system
// temp dir. Checks compare sets taken before and after their own writes, so
// files a killed earlier run left behind never count.
var tempFloatFiles = {
    PathName(Platform.defaultTempDir).files.select({ arg each; each.fileName.beginsWith("strata-buf") })
        .collect(_.fullPath).asSet
};
// bufferState poll value: slot index * 100 + valid seconds
var decodeBufferState = { arg value; var slot = (value / 100).floor; [slot.asInteger, value - (slot * 100)] };
var bufferStateSeen = { arg slot, seconds;
    pollMessages.any({ arg msg; var decoded = decodeBufferState.(msg[2]);
        (msg[1] == engine.bufferStatePoll.index) and: { decoded[0] == slot }
            and: { (decoded[1] - seconds).abs < 0.011 } })
};
// bufferState poll messages received so far
var bufferStateMessages = { pollMessages.select({ arg msg; msg[1] == engine.bufferStatePoll.index }) };
// bufferLoadFailed poll values received so far
var loadFailures = {
    pollMessages.select({ arg msg; msg[1] == engine.bufferLoadFailedPoll.index }).collect({ arg msg; msg[2] })
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
    awaitReply.(condition);
    value
};

var getControl = { arg synth, control;
    var condition = Condition(false), value;
    synth.get(control, { arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
};

// Buffer and file checks in functions of their own, called from the check
// routine: its function is near sclang's per-function selector table limit
// (a function that exceeds it does not compile, and the check never ends).

// A missing, unreadable or empty file loaded into a slot that is recording
// cancels the recording (Lua's load_buffer assumes so): the take never
// completes, the slot stays empty and no scratch take is written
var checkBadLoadsDuringRecording = { arg textPath, stereoPath;
    var emptyPath = scratchRoot +/+ "no-frames.wav", file, info;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(1).sampleRate_(44100);
    file.openWrite(emptyPath); file.close;
    [[scratchRoot +/+ "missing.wav", "missing", 0.1], [textPath, "unreadable", 0.1], [emptyPath, "empty", 0.1],
        [emptyPath, "empty (recording not started yet)", 0]].do({ arg bad;
        File.delete(engine.scratchDir +/+ "buf7.wav");
        command.(\recordBuffer, 6, 0.3, 1.0);
        bad[2].wait; server.sync;
        info = engine.recordSynths[6].notNil;
        command.(\loadBuffer, 6, bad[0]); 0.6.wait; server.sync;
        check.(info and: { engine.recordSynths[6].isNil } and: { engine.bufferFrames[6] == 0 }
            and: { synthNames.(context.xg).includes(\strataRecord).not }
            and: { File.exists(engine.scratchDir +/+ "buf7.wav").not },
            "a % file loaded during a recording cancels it: no take, nothing written (% frames)".format(
                bad[1], engine.bufferFrames[6]));
    });
    // ... also one stopped early whose frame count has not arrived yet: the
    // late reply keeps nothing
    File.delete(engine.scratchDir +/+ "buf7.wav");
    command.(\recordBuffer, 6, 1.0, 1.0); 0.3.wait; server.sync;
    info = engine.recordSynths[6].notNil;
    command.(\stopRecord, 6);
    command.(\loadBuffer, 6, scratchRoot +/+ "missing.wav");
    1.0.wait; server.sync;
    check.(info and: { engine.bufferFrames[6] == 0 } and: { engine.stopReplies[6].isNil }
        and: { File.exists(engine.scratchDir +/+ "buf7.wav").not },
        "a missing file loaded right after stopRecord cancels the stopped take: no take, nothing written (% frames)".format(
            engine.bufferFrames[6]));
    // ... but a good load sent between them is a change of its own, which
    // drops the awaited frame count: the missing file then finds no take to
    // cancel and leaves the good load alone (#47)
    File.delete(engine.scratchDir +/+ "buf7.wav");
    command.(\recordBuffer, 6, 1.0, 1.0); 0.3.wait; server.sync;
    info = engine.recordSynths[6].notNil;
    command.(\stopRecord, 6);
    command.(\loadBuffer, 6, stereoPath);
    command.(\loadBuffer, 6, scratchRoot +/+ "missing.wav");
    1.0.wait; server.sync;
    check.(info and: { engine.bufferFrames[6] == 11025 } and: { (bufferSample.(engine.buffersL[6], 100) - 0.5).abs < 0.001 }
        and: { File.exists(engine.scratchDir +/+ "buf7.wav").not },
        "a missing file loaded after stopRecord and a good load leaves the good load (% frames), no take written".format(
            engine.bufferFrames[6]));
    command.(\clearBuffer, 6); server.sync;
};

// A FLAC whose data is overwritten from a third of the way in: its header
// is sound (SoundFile.openRead gives its frames), but libsndfile stops
// decoding early, and the server's /b_readChannel then fills the rest with
// silence without any /fail (measured with scsynth 3.14: 12288 of 48000
// frames decode). Returns its path and whether its header reads. Decoding
// it makes libFLAC 1.4 print "Rewinding, seeking necessary" to stderr:
// expected, harmless, not silenceable from sclang, and not matched by
// run_engine_check.sh's error patterns.
var writeDamagedFlac = { arg path;
    var file = SoundFile.new.headerFormat_("FLAC").sampleFormat_("int16").numChannels_(1).sampleRate_(48000);
    var bytes, header, headerReads;
    file.openWrite(path); file.writeData(FloatArray.fill(48000, { 1.0.rand2 * 0.5 })); file.close;
    file = File(path, "rb"); bytes = Int8Array.newClear(file.length); file.read(bytes); file.close;
    ((bytes.size div: 3)..(bytes.size - 1)).do({ arg i; bytes[i] = 0x55 });
    file = File(path, "wb"); file.write(bytes); file.close;
    header = SoundFile.openRead(path);
    headerReads = header.notNil and: { header.numFrames == 48000 };
    if (header.notNil) { header.close };
    [path, headerReads]
};

// A missing, unreadable, empty or damaged file loaded into a slot holding
// audio leaves the audio, and the bufferLoadFailed poll reports exactly that
// load ((load number * 2 + 0) * 8 + slot index: not emptied) as a float,
// once; a good load reports nothing. Slot 4 holds the stereo file's 11025
// frames.
var checkLoadFailureReports = { arg textPath, stereoPath;
    var emptyPath = scratchRoot +/+ "no-frames-4.wav", file, before, damaged;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(1).sampleRate_(44100);
    file.openWrite(emptyPath); file.close;
    damaged = writeDamagedFlac.(scratchRoot +/+ "damaged.flac");
    check.(damaged[1], "the damaged FLAC still has a sound header (48000 frames)");
    [[textPath, "unreadable"], [scratchRoot +/+ "missing.wav", "missing"], [emptyPath, "empty"],
        [damaged[0], "damaged FLAC"]].do({ arg bad;
        before = loadFailures.value.size;
        command.(\loadBuffer, 4, bad[0]);
        check.(waitFor.({ loadFailures.value.size > before }),
            "the % file loaded over audio is reported by bufferLoadFailed".format(bad[1]));
        0.2.wait; server.sync;
        check.(loadFailures.value.drop(before) == [(engine.bufferLoads[4] * 2) * engine.numBuffers + 4]
            and: { loadFailures.value.last.isKindOf(Float) },
            "the report names slot 4 and its load number % once, as a float (got %)".format(
                engine.bufferLoads[4], loadFailures.value.drop(before)));
        check.(engine.bufferFrames[4] == 11025 and: { (bufferSample.(engine.buffersL[4], 100) - 0.5).abs < 0.001 },
            "the % file left the slot's audio".format(bad[1]));
    });
    before = loadFailures.value.size;
    command.(\loadBuffer, 4, stereoPath); 0.5.wait; server.sync;
    check.(loadFailures.value.size == before and: { engine.bufferFrames[4] == 11025 },
        "a good load reports no failure");
};

// A take recorded above level 1 holds samples beyond ±1 (the buffers are
// float; a float file loads them too): saving clips them symmetrically to
// the int16 range and never wraps
var checkLoudSave = {
    var loudPath = scratchRoot +/+ "loud.wav", savePath, file, data;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(server.sampleRate);
    file.openWrite(loudPath);
    file.writeData(FloatArray.fill(2 * 1000, { arg i; [1.5, -1.7][i % 2] }));
    file.close;
    command.(\loadBuffer, 6, loudPath); 0.5.wait; server.sync;
    check.(((bufferSample.(engine.buffersL[6], 10) - 1.5).abs < 0.001)
        and: { (bufferSample.(engine.buffersR[6], 10) + 1.7).abs < 0.001 }, "a slot holds samples beyond ±1 unclipped");
    savePath = scratchRoot +/+ "saved/loud.wav";
    command.(\saveBuffer, 6, savePath);
    check.(waitFor.({ File.exists(savePath) }), "a slot beyond ±1 is saved");
    0.5.wait;
    file = SoundFile.openRead(savePath);
    if (file.notNil) {
        data = FloatArray.newClear(2 * 1000);
        file.readData(data);
        file.close;
        check.(data.size == 2000 and: { data[0] > 0.999 } and: { (0..999).every({ arg frame;
                (data[frame * 2] == data[0]) and: { data[(frame * 2) + 1] == data[0].neg } }) },
            "saving clips beyond ±1 symmetrically to the int16 range, never wraps (read back % / %)".format(
                data[0], data[1]));
    } {
        check.(false, "the saved loud file can be read");
    };
    command.(\clearBuffer, 6); server.sync;
};

// writeSlot's temporary float files a crash left in the system temp dir
// (strata-buf<n>-<tag>-<n>-<side>.wav) are deleted like stale .part files:
// only those older than stalePartAge, and no other file (#47). A .part file
// whose age cannot be read (its directory cannot be searched, so File.mtime
// fails while the file is still there) is left, posted and returned.
var checkStaleTempFiles = {
    var tag = "check" ++ Date.getDate.stamp, unreadable, result, readable, savedDir = engine.scratchDir, lines = List.new;
    var names = ["strata-buf3-%-1-L.wav", "strata-buf3-%-2-R.wav", "strata-buf%.wav"].collect({ arg name;
        Platform.defaultTempDir +/+ name.format(tag) });
    names.do({ arg path; File.use(path, "w", { arg text; text.write("float") }) });
    ("touch -t 202001010000 " ++ names[0].shellQuote ++ " " ++ names[2].shellQuote).systemCmd;  // a crash long ago
    engine.tryPerform(\deleteStaleParts);
    check.(File.exists(names[0]).not and: { File.exists(names[1]) } and: { File.exists(names[2]) },
        "deleteStaleParts deletes old temporary float files and keeps fresh ones and other files (left: %)".format(
            names.select({ arg path; File.exists(path) }).collect({ arg path; path.basename })));
    names.do({ arg path; File.delete(path) });
    unreadable = scratchRoot +/+ "unsearchable/";
    File.mkdir(unreadable);
    File.use(unreadable +/+ "buf4.wav.9.part", "w", { arg text; text.write("stale") });
    ("chmod 644 " ++ unreadable.shellQuote).systemCmd;
    readable = try { File.mtime(unreadable +/+ "buf4.wav.9.part"); true } { false };
    engine.scratchDir = unreadable;
    engine.postStaleFileLine = { arg line; lines.add(line) };
    result = engine.tryPerform(\deleteStaleParts);
    engine.postStaleFileLine = nil;
    engine.scratchDir = savedDir;
    ("chmod 755 " ++ unreadable.shellQuote).systemCmd;
    if (readable) {
        check.(true, "(skipped: a directory without search permission is still searchable here, as root)");
    } {
        check.(result.isKindOf(Array) and: { result.includesEqual(unreadable +/+ "buf4.wav.9.part") }
            and: { File.exists(unreadable +/+ "buf4.wav.9.part") },
            "deleteStaleParts leaves, posts and returns a .part file whose age it cannot read (got %)".format(result));
        check.(lines.asArray == [("strata: cannot read when " ++ unreadable ++ "buf4.wav.9.part was last written; left in place")],
            "and posts one line naming it (got %)".format(lines));
    };
    File.delete(unreadable +/+ "buf4.wav.9.part");
};

// .part files a crash left in scratchDir (scratch takes) and its parent
// (saveBuffer's dated files) are deleted at alloc. alloc runs before the
// check can point scratchDir away from ~/dust, so the deletion is checked
// through deleteStaleParts (the check routine checks alloc calls it). Only
// .part files older than stalePartAge go: a fresh one may be a write still
// running in another engine instance (a script reload in the same sclang
// session runs alloc while the old engine writes).
var checkStaleParts = {
    var info, data, savePath, file;
    info = [engine.scratchDir, engine.scratchDir.withoutTrailingSlash.dirname];
    info.do({ arg dir;
        File.mkdir(dir);
        File.use(dir +/+ "buf2.wav.17.part", "w", { arg text; text.write("stale") });
        ("touch -t 202001010000 " ++ (dir +/+ "buf2.wav.17.part").shellQuote).systemCmd;  // a crash long ago
        File.use(dir +/+ "buf3.wav.5.part", "w", { arg text; text.write("running") });
        File.use(dir +/+ "keep.txt", "w", { arg text; text.write("keep") });
    });
    engine.tryPerform(\deleteStaleParts);
    check.(info.every({ arg dir; File.exists(dir +/+ "buf2.wav.17.part").not and: { File.exists(dir +/+ "keep.txt") } }),
        "deleteStaleParts deletes old .part files in scratchDir and its parent, and nothing else");
    check.(info.every({ arg dir; File.exists(dir +/+ "buf3.wav.5.part") }),
        "deleteStaleParts keeps a fresh .part file (a write that may still be running)");
    check.(engine.respondsTo(\stalePartAge) and: { engine.stalePartAge >= 60 },
        "stalePartAge is at least a minute (%)".format(engine.tryPerform(\stalePartAge)));
    info.do({ arg dir; ["keep.txt", "buf2.wav.17.part", "buf3.wav.5.part"].do({ arg name; File.delete(dir +/+ name) }) });
    checkStaleTempFiles.value;
    // A write still interleaving survives deleteStaleParts, and its .part
    // name carries this engine instance's tag, so two instances' writes
    // to one path never share a .part file
    engine.writeChunkWait = 0.02;          // the 16 s interleave now takes about 2 s
    savePath = engine.scratchDir +/+ "running.wav";
    command.(\saveBuffer, 7, savePath);
    0.5.wait;
    data = PathName(engine.scratchDir).files.collect(_.fileName).select({ arg name; name.endsWith(".part") });
    check.(engine.respondsTo(\instanceTag) and: { data.size == 1 }
        and: { data[0].beginsWith("running.wav." ++ engine.instanceTag ++ "-") },
        "a .part name carries the engine instance's tag (got %)".format(data));
    engine.tryPerform(\deleteStaleParts);
    check.(waitFor.({ File.exists(savePath) }, 10), "a write in progress survives deleteStaleParts");
    engine.writeChunkWait = 0.001;
    file = SoundFile.openRead(savePath);
    check.(file.notNil and: { file.numFrames == engine.bufferFrames[7] }, "and holds every frame");
    file !? { file.close };
    File.delete(savePath);
};

// A file at another rate plays at its own pitch: a 1 kHz sine written at
// 44.1 kHz, played by voice 7 (engine voice 6, reading slot 4) through
// strataGrainBuf (every grain from one position, so overlapping grains stay
// in phase) and measured by Pitch on the voice's bus mirror. 919 Hz would
// mean the rate scale is applied twice (by the engine and by GrainBuf),
// 1088 Hz not at all. Then a take recorded into the same slot (the server
// keeps the buffer's 44.1 kHz rate) plays at the recorded tone's pitch.
var checkFilePitch = {
    var sinePath = scratchRoot +/+ "sine-44100.wav", file, pitchBus, probe, tone, readPitch, pitches;
    SynthDef(\strataCheckPitch, { arg in, out;
        Out.kr(out, Pitch.kr(In.ar(in, 2)[0], minFreq: 200, maxFreq: 4000)[0]);
    }).add;
    server.sync;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(44100);
    file.openWrite(sinePath);
    file.writeData(FloatArray.fill(44100 * 2 * 2, { arg i; sin(2pi * 1000 * (i div: 2) / 44100) * 0.5 }));
    file.close;
    command.(\loadBuffer, 3, sinePath); 0.5.wait; server.sync;
    [[\bufPos, 0.25], [\bufScan, 0], [\posSpread, 0], [\bufRate, 1], [\pitchShift, 1],
        [\grainSize, 0.2], [\grainDensity, 20], [\grainMode, 0]].do({ arg pair;
        command.(\setGrainParam, 6, pair[0], pair[1]);
    });
    command.(\setVoiceParam, 6, \bend, 1);
    pitchBus = Bus.control(server, 1);
    probe = Synth(\strataCheckPitch, [\in, engine.granBuses[6], \out, pitchBus], engine.processGroup, \addToTail);
    // eleven readings over a second, sorted: the middle one is the median
    readPitch = {
        1.0.wait;
        11.collect({
            var condition = Condition(false), value;
            0.1.wait;
            pitchBus.get({ arg result; value = result; condition.test = true; condition.signal });
            awaitReply.(condition);
            value
        }).sort
    };
    pitches = readPitch.value;
    check.((pitches[5] - 1000).abs < 10,
        "a 44.1 kHz file plays at its own pitch (a 1 kHz sine measures % Hz; readings %)".format(
            pitches[5].round(0.1), pitches.round(0.1)));
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
    command.(\recordBuffer, 3, 1.0, 1.0); 1.5.wait; server.sync;
    tone.free;
    pitches = readPitch.value;
    check.(engine.bufferFrames[3] > 0 and: { (pitches[5] - 440).abs < 5 },
        "a take recorded over a 44.1 kHz file plays at its pitch (a 440 Hz tone measures % Hz; readings %)".format(
            pitches[5].round(0.1), pitches.round(0.1)));
    probe.free; pitchBus.free;
};

// fileDecodes accepts a header count up to loadShortfallFrames more than
// the frames that decode (asking a good file for more frames than it has
// stands in for such a header), and rejects anything beyond
var checkDecodeShortfall = { arg stereoPath, longPath;
    var decodes = { arg path, frames;
        var file = SoundFile.openRead(path), result = engine.fileDecodes(file, frames);
        file.close;
        result
    };
    check.(decodes.(stereoPath, 11025) and: { decodes.(longPath, 22050 * 16) },
        "fileDecodes accepts files that decode in full (one chunk and many)");
    check.(decodes.(stereoPath, 11025 + engine.loadShortfallFrames)
        and: { decodes.(stereoPath, 11025 + engine.loadShortfallFrames + 1).not },
        "fileDecodes tolerates a shortfall of loadShortfallFrames (%) and no more".format(engine.loadShortfallFrames));
};

// Two back-to-back loads into a slot no voice plays both read at once: a
// /fail for the first one's file (simulated here, as the server sends it)
// fails only that load, never the second one's good read of another file
var checkReadFailureMatching = { arg stereoPath, monoPath;
    var firstPath = scratchRoot +/+ "first-of-two.wav", before, firstLoad;
    File.delete(firstPath); File.copy(monoPath, firstPath);
    before = loadFailures.value.size;
    command.(\loadBuffer, 5, firstPath);
    firstLoad = engine.bufferLoads[5];
    command.(\loadBuffer, 5, stereoPath);
    thisProcess.recvOSCmessage(0, server.addr, NetAddr.langPort, ['/fail', '/b_readChannel',
        "File '" ++ firstPath.standardizePath ++ "' could not be opened: System error : No such file or directory.\n",
        engine.buffersL[5].bufnum]);
    0.5.wait; server.sync;
    check.(loadFailures.value.drop(before) == [((firstLoad * 2) + 1) * engine.numBuffers + 5],
        "a /fail names its file: only the first of two loads fails (got %)".format(loadFailures.value.drop(before)));
    check.(engine.bufferFrames[5] == 11025, "the second load's good read is kept (% frames)".format(engine.bufferFrames[5]));
    File.delete(firstPath);
};

// A file that passes loadSlot's checks but is gone when the server reads it
// (after the fade wait; a drive unplugged, say) is the one way to make the
// server's read itself fail: /fail for /b_readChannel. The slot was zeroed,
// so it stays empty and the load is reported as emptied ((load * 2 + 1) * 8
// + slot index). Called from checkBufferFades inside its lengthened fade
// wait (voice 1 reads slot 2).
var checkVanishedFileLoad = { arg stereoPath, monoPath;
    var path = scratchRoot +/+ "vanishing.wav", before, expected;
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    File.copy(stereoPath, path);
    before = loadFailures.value.size;
    command.(\loadBuffer, 2, path);
    expected = ((engine.bufferLoads[2] * 2) + 1) * engine.numBuffers + 2;
    File.delete(path);   // the server reads it bufferFadeWait from now
    check.(loadFailures.value.size == before, "a file that passes the checks is not reported before the server reads it");
    check.(waitFor.({ loadFailures.value.size > before }), "a file gone when the server reads it is reported by bufferLoadFailed");
    0.1.wait; server.sync;
    check.(loadFailures.value.drop(before) == [expected],
        "as that load's failure with the slot emptied (expected %, got %)".format(expected, loadFailures.value.drop(before)));
    check.(engine.bufferFrames[2] == 0 and: { getControl.(engine.synths[\grain1], \bufFrames) == 0 }
        and: { bufferSample.(engine.buffersL[2], 100) == 0 }, "the slot stays empty (zeroed, 0 frames)");
    // a later load inside the wait wins: the vanished file is never read and nothing is reported
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    File.copy(stereoPath, path);
    before = loadFailures.value.size;
    command.(\loadBuffer, 2, path); File.delete(path);
    command.(\loadBuffer, 2, monoPath);
    1.2.wait; server.sync;
    check.(engine.bufferFrames[2] == 4410 and: { loadFailures.value.size == before },
        "a load inside the fade wait wins over a vanished file's load (% frames, % reports)".format(
            engine.bufferFrames[2], loadFailures.value.size - before));
};

// A control bus's first value (inside the check routine)
var readBusValue = { arg bus;
    var condition = Condition(false), value;
    bus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
};

// Grain synths that are no longer the voice's (releasing after voiceOff,
// fading after a source switch) but still read a slot fade out before it is
// zeroed or overwritten (#47): a clear, load or recording sends them
// bufFrames 0 at once and waits for them as for a running voice, so the
// tail never clicks, and they never take the new take's length (their tail
// would replay it); voiceOn re-gates a releasing one with the slot as it is
// then. Called from checkBufferFades inside its lengthened fade wait (voice 1
// reads slot 2).
var checkReleasingGrainFades = { arg stereoPath, monoPath;
    var grainKey = engine.grainKey(1), grain, steadyLevel, cutStep, stepBus, stepProbe, peakBus, peakProbe;
    var restart = { command.(\voiceOn, 1, 101.0, 1.0, 0.0, 0.2, 20.0, 1.0); server.sync };
    var holds = { arg value; (bufferSample.(engine.buffersL[2], 100) - value).abs < 0.001 };
    // a clear inside the release: faded at once, zeroed after the fade, no step
    command.(\loadBuffer, 2, stereoPath); 1.0.wait; server.sync;
    grain = engine.synths[grainKey];
    stepBus = Bus.control(server, 1); peakBus = Bus.control(server, 1);
    stepProbe = Synth(\strataCheckStep, [\in, engine.granBuses[1], \out, stepBus], engine.processGroup, \addToTail);
    peakProbe = Synth(\strataCheckPeak, [\in, engine.granBuses[1], \out, peakBus], engine.processGroup, \addToTail);
    server.sync; 0.3.wait;
    peakProbe.set(\t_reset, 1); 0.3.wait;
    steadyLevel = readBusValue.(peakBus);
    stepProbe.set(\t_reset, 1); 0.05.wait;
    command.(\voiceOff, 1);
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(grain.isPlaying and: { getControl.(grain, \bufFrames) == 0 } and: { holds.(0.5) },
        "a clear in a voiceOff release fades the releasing grain synth at once and leaves the buffers until the fade is over");
    0.6.wait; server.sync;
    cutStep = readBusValue.(stepBus);
    check.((bufferSample.(engine.buffersL[2], 100) == 0) and: { steadyLevel > 0.05 } and: { cutStep < (steadyLevel * 0.01) },
        "then zeroes the slot, and the release tail fades instead of cutting off (largest step %; level %)".format(
            cutStep.round(0.000001), steadyLevel.round(0.0001)));
    stepProbe.free; peakProbe.free; stepBus.free; peakBus.free;
    restart.value;
    check.(engine.synths[grainKey] === grain, "voiceOn in the release re-gates that grain synth");
    // a load inside the release: faded at once, read after the fade, never taken by the tail
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    command.(\voiceOff, 1);
    command.(\loadBuffer, 2, monoPath); 0.1.wait; server.sync;
    check.((getControl.(grain, \bufFrames) == 0) and: { holds.(0.5) },
        "a load in a voiceOff release fades the releasing grain synth at once and reads the file only after the fade");
    0.7.wait; server.sync;
    check.((engine.bufferFrames[2] == 4410) and: { holds.(0.4) } and: { grain.isPlaying } and: { getControl.(grain, \bufFrames) == 0 },
        "the releasing grain synth never takes the loaded take (its tail would replay it)");
    restart.value;
    check.((engine.synths[grainKey] === grain) and: { getControl.(grain, \bufFrames) == 4410 },
        "voiceOn re-gates it with the loaded take");
    // a recording inside the release: faded first, recorded after the fade
    File.delete(engine.scratchDir +/+ "buf3.wav");
    command.(\voiceOff, 1);
    command.(\recordBuffer, 2, 0.2, 1.0); 0.1.wait; server.sync;
    check.((getControl.(grain, \bufFrames) == 0) and: { synthNames.(engine.voiceGroup).includes(\strataRecord).not } and: { holds.(0.4) },
        "a recording in a voiceOff release fades the releasing grain synth first and starts only after the fade");
    1.0.wait; server.sync;
    check.((engine.bufferFrames[2] == (0.2 * server.sampleRate).round.asInteger) and: { grain.isPlaying }
        and: { getControl.(grain, \bufFrames) == 0 }, "then records the take, which the releasing grain synth never takes");
    restart.value;
    // a grain synth a source switch left fading
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    command.(\setGrainSource, 1, 0); server.sync;
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(engine.fadingSynths[1].includes(grain) and: { getControl.(grain, \bufFrames) == 0 } and: { holds.(0.5) },
        "a clear fades a grain synth a switch left fading at once and leaves the buffers until the fade is over");
    0.6.wait; server.sync;
    check.(bufferSample.(engine.buffersL[2], 100) == 0, "then zeroes the slot");
    command.(\setGrainSource, 1, 3); server.sync;
};

// A slot that empties keeps the rate of the grains still fading out (#47):
// a clear or a recording leaves the voice's bufRateScale (a 22050 Hz file)
// until the slot holds audio again, so no grain started in the hasAudio fade
// plays at another pitch; a take's rate arrives with its length. Called from
// checkBufferFades (voice 1 reads slot 2).
var checkFadeRates = { arg stereoPath;
    var fileScale = 22050 / server.sampleRate, rateScale = { getControl.(engine.synths[engine.grainKey(1)], \bufRateScale) };
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(rateScale.value.equalWithPrecision(fileScale),
        "a clear leaves the rate of the grains fading out (bufRateScale %, the file's %)".format(rateScale.value, fileScale));
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    File.delete(engine.scratchDir +/+ "buf3.wav");
    command.(\recordBuffer, 2, 0.2, 1.0); 0.1.wait; server.sync;
    check.(rateScale.value.equalWithPrecision(fileScale),
        "a recording leaves the rate of the grains fading out until its take is in (bufRateScale %)".format(rateScale.value));
    1.0.wait; server.sync;
    check.((engine.bufferFrames[2] > 0) and: { rateScale.value == 1 },
        "the take's rate arrives with its length (bufRateScale %)".format(rateScale.value));
};

// More interleavings inside the fade wait (#22, #47), on the slot voice 1
// reads: a stopRecord before the recording has started cancels it (it never
// starts, nothing is written); a missing file loaded while a recording waits
// cancels it and is reported; of two recordings the later one wins and only
// it runs. Called from checkBufferFades.
var checkFadeWaitInterleavings = { arg longPath;
    var takePath = engine.scratchDir +/+ "buf3.wav", before, running;
    var recorders = { synthNames.(engine.voiceGroup).count({ arg name; name == \strataRecord }) };
    command.(\loadBuffer, 2, longPath); 0.8.wait; server.sync;
    File.delete(takePath);
    command.(\recordBuffer, 2, 0.5, 1.0); 0.1.wait;
    command.(\stopRecord, 2); 0.6.wait; server.sync;
    running = recorders.value;
    0.5.wait; server.sync;
    check.((running == 0) and: { engine.recordSynths[2].isNil } and: { engine.bufferFrames[2] == 0 } and: { File.exists(takePath).not },
        "a stopRecord inside the fade wait cancels the recording: it never starts, nothing is written");
    command.(\loadBuffer, 2, longPath); 0.8.wait; server.sync;
    before = loadFailures.value.size;
    command.(\recordBuffer, 2, 0.5, 1.0);
    command.(\loadBuffer, 2, scratchRoot +/+ "missing.wav"); 0.6.wait; server.sync;
    running = recorders.value;
    0.5.wait; server.sync;
    check.((running == 0) and: { engine.recordSynths[2].isNil } and: { engine.bufferFrames[2] == 0 } and: { File.exists(takePath).not }
        and: { loadFailures.value.drop(before) == [(engine.bufferLoads[2] * 2) * engine.numBuffers + 2] },
        "a missing file loaded while a recording waits for its fade cancels it and is reported (reports %)".format(
            loadFailures.value.drop(before)));
    command.(\loadBuffer, 2, longPath); 0.8.wait; server.sync;
    command.(\recordBuffer, 2, 0.5, 1.0);
    command.(\recordBuffer, 2, 0.4, 1.0); 0.65.wait; server.sync;   // the later one runs from the fade's end (0.5 s) to 0.9 s
    running = recorders.value;
    0.8.wait; server.sync;
    check.((running == 1) and: { engine.recordSynths[2].isNil } and: { engine.bufferFrames[2] == (0.4 * server.sampleRate).round.asInteger }
        and: { File.exists(takePath) },
        "of two recordings inside the fade wait the later one wins and only it runs (% running, % frames)".format(
            running, engine.bufferFrames[2]));
};

// Clearing, loading or recording into a slot a voice plays fades it first:
// the grain synth gets bufFrames 0 at once (strataGrainBuf's hasAudio lag
// fades it) and the buffers are zeroed or overwritten only bufferFadeWait
// later, so the sound never cuts off. Voice 2 (engine voice 1) reads slot 3
// (index 2).
var checkBufferFades = { arg stereoPath, monoPath, longPath;
    var fadeLags, defaultFadeWait, steadyStep, cutStep, steadyLevel, stepBus, stepProbe, peakBus, peakProbe;
    fadeLags = SynthDescLib.global.at(\strataGrainBuf).def.children.select({ arg ugen;
        ugen.isKindOf(Lag) and: { ugen.inputs[0].isKindOf(BinaryOpUGen) } and: { ugen.inputs[0].operator == '>' }
    }).collect({ arg ugen; ugen.inputs[1] });
    check.(engine.respondsTo(\bufferFadeWait) and: { fadeLags.size == 1 }
        and: { fadeLags[0].isNumber } and: { engine.bufferFadeWait > fadeLags[0] }
        and: { engine.bufferFadeWait < 0.2 },
        "bufferFadeWait (%) is slightly longer than strataGrainBuf's hasAudio lag (%)".format(
            engine.tryPerform(\bufferFadeWait), fadeLags));
    // The constant stereo file through overlapping Hann grains from one
    // position: a steady level with tiny sample-to-sample steps, so an
    // abrupt cut steps by about the level and a fade by far less
    [[\bufPos, 0.5], [\bufScan, 0], [\posSpread, 0], [\bufRate, 1], [\pitchShift, 1],
        [\grainSize, 0.2], [\grainDensity, 20], [\grainMode, 0], [\envShape, 0]].do({ arg pair;
        command.(\setGrainParam, 1, pair[0], pair[1]);
    });
    command.(\setVoiceParam, 1, \amp, 1);
    command.(\loadBuffer, 2, stereoPath); 0.5.wait; server.sync;
    stepBus = Bus.control(server, 1); peakBus = Bus.control(server, 1);
    stepProbe = Synth(\strataCheckStep, [\in, engine.granBuses[1], \out, stepBus], engine.processGroup, \addToTail);
    peakProbe = Synth(\strataCheckPeak, [\in, engine.granBuses[1], \out, peakBus], engine.processGroup, \addToTail);
    1.0.wait;
    stepProbe.set(\t_reset, 1); peakProbe.set(\t_reset, 1); 0.5.wait;
    steadyStep = readBusValue.(stepBus); steadyLevel = readBusValue.(peakBus);
    stepProbe.set(\t_reset, 1); 0.05.wait;
    command.(\clearBuffer, 2); 0.3.wait;
    cutStep = readBusValue.(stepBus);
    check.(bufferSample.(engine.buffersL[2], 100) == 0, "the cleared slot is zeroed after the fade");
    // measured: a fade steps by about 0.1 % of the level, an abrupt cut by about 4 %
    check.(steadyLevel > 0.05 and: { cutStep < (steadyLevel * 0.01) },
        "clearing a slot a voice plays fades it out (largest step % while clearing; level %, largest step % playing)".format(
            cutStep.round(0.000001), steadyLevel.round(0.0001), steadyStep.round(0.000001)));
    stepProbe.free; peakProbe.free; stepBus.free; peakBus.free;
    // Inside the wait (lengthened so the check can look): faded at once, zeroed or overwritten after
    defaultFadeWait = engine.bufferFadeWait;
    engine.bufferFadeWait = 0.5;
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(getControl.(engine.synths[\grain1], \bufFrames) == 0 and: { engine.bufferFrames[2] == 0 }
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.5).abs < 0.001 },
        "clearBuffer fades the voice at once and leaves the buffers until the fade is over");
    0.6.wait; server.sync;
    check.(bufferSample.(engine.buffersL[2], 100) == 0, "then clearBuffer zeroes the slot");
    command.(\loadBuffer, 2, stereoPath); 0.8.wait; server.sync;
    command.(\loadBuffer, 2, monoPath); 0.1.wait; server.sync;
    check.(getControl.(engine.synths[\grain1], \bufFrames) == 0 and: { engine.bufferFrames[2] == 0 }
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.5).abs < 0.001 },
        "loadBuffer fades the voice at once and reads the file only after the fade");
    0.7.wait; server.sync;
    check.(engine.bufferFrames[2] == 4410 and: { getControl.(engine.synths[\grain1], \bufFrames) == 4410 }
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.4).abs < 0.001 }, "then loadBuffer reads the file");
    File.delete(engine.scratchDir +/+ "buf3.wav");
    command.(\recordBuffer, 2, 0.2, 1.0); 0.1.wait; server.sync;
    check.(synthNames.(engine.voiceGroup).includes(\strataRecord).not
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.4).abs < 0.001 },
        "recordBuffer leaves the buffers and starts no recording until the fade is over");
    1.0.wait; server.sync;
    check.(engine.recordSynths[2].isNil and: { engine.bufferFrames[2] == (0.2 * server.sampleRate).round.asInteger }
        and: { File.exists(engine.scratchDir +/+ "buf3.wav") }, "then recordBuffer records the take");
    // Every interleaving inside the wait: the later command wins
    [
        ["a clear after a load", { command.(\loadBuffer, 2, stereoPath); command.(\clearBuffer, 2) }, 0, 0],
        ["a load after a clear", { command.(\clearBuffer, 2); command.(\loadBuffer, 2, stereoPath) }, 11025, 0.5],
        ["a load after a load", { command.(\loadBuffer, 2, stereoPath); command.(\loadBuffer, 2, monoPath) }, 4410, 0.4],
        ["a clear after a recording", { command.(\recordBuffer, 2, 0.2, 1.0); command.(\clearBuffer, 2) }, 0, 0],
        ["a load after a recording", { command.(\recordBuffer, 2, 0.2, 1.0); command.(\loadBuffer, 2, monoPath) }, 4410, 0.4],
        ["a recording after a load", { command.(\loadBuffer, 2, stereoPath); command.(\recordBuffer, 2, 0.2, 1.0) },
            (0.2 * server.sampleRate).round.asInteger, nil]
    ].do({ arg case;
        command.(\loadBuffer, 2, longPath); 0.8.wait; server.sync;   // audio in the slot, so the voice fades
        File.delete(engine.scratchDir +/+ "buf3.wav");
        case[1].value;
        1.5.wait; server.sync;
        check.(engine.bufferFrames[2] == case[2] and: { getControl.(engine.synths[\grain1], \bufFrames) == case[2] }
            and: { engine.recordSynths[2].isNil }
            and: { case[3].isNil or: { (bufferSample.(engine.buffersL[2], 100) - case[3]).abs < 0.001 } }
            and: { File.exists(engine.scratchDir +/+ "buf3.wav") == case[3].isNil },
            "% inside the fade wins (% frames)".format(case[0], engine.bufferFrames[2]));
    });
    // A slot no voice plays changes without the wait
    command.(\loadBuffer, 5, stereoPath); 0.2.wait; server.sync;
    check.(engine.bufferFrames[5] == 11025, "a slot no voice plays loads without the fade wait");
    command.(\clearBuffer, 5); server.sync;
    check.(engine.bufferFrames[5] == 0 and: { bufferSample.(engine.buffersL[5], 100) == 0 },
        "and clears without it");
    checkReleasingGrainFades.(stereoPath, monoPath);
    checkFadeRates.(stereoPath);
    checkFadeWaitInterleavings.(longPath);
    checkVanishedFileLoad.(stereoPath, monoPath);
    engine.bufferFadeWait = defaultFadeWait;
};

// free with fades still pending (#22, #47): with a long fade wait, a
// clear, a load and a recording on slots that running voices read (voices 1-3,
// engine 0-2, read slots 1-3 as checkMemoryWorstCase leaves them), then free
// at once. Nothing that waited runs afterward: no zeroing, read or record
// synth reaches the freed buffers and nodes (the server reports no failure)
// and no slot change completes. Frees the engine.
var freeDuringPendingFades = { arg stereoPath;
    var fails = List.new, watcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr), waiting;
    engine.bufferFadeWait = 0.5;
    command.(\clearBuffer, 0);
    command.(\loadBuffer, 1, stereoPath);
    command.(\recordBuffer, 2, 0.2, 1.0);
    waiting = (0..2).every({ arg slot; engine.slotPlaying(slot) }) and: { engine.recordSynths[2].notNil };
    engine.free;
    1.0.wait; server.sync;
    watcher.free;
    check.(waiting and: { fails.isEmpty } and: { engine.bufferFrames[1] == 0 } and: { engine.recordSynths.every(_.isNil) },
        "free with a clear, a load and a recording waiting for their fade runs none of them (waiting %, server failures %)".format(
            waiting, fails));
};

// Real-time memory (#19), as top-level functions (the check routine is at
// sclang's per-function selector limit). PitchShift allocates its delay line
// from scsynth's real-time pool when a synth starts, sized by the window it
// starts with, so the grain window is a fixed constant, never the grain size
// (0.5 s took 1 MB per grain synth). maxGrains (one grain table per
// GrainIn/GrainBuf, also from the pool) covers the largest overlap Lua can
// ask for: grain size 0.5 s x density 100 x master density 2 (a
// GrainIn/GrainBuf runs at most maxGrains - 1 grains).
var checkGrainMemorySizes = {
    var window = engine.tryPerform(\pitchShiftWindow), maxGrains = engine.tryPerform(\maxGrains);
    check.(window.isNumber and: { window >= 0.1 } and: { window <= 0.2 },
        "the grain PitchShift window is a constant of 0.1-0.2 s (got %)".format(window));
    check.(maxGrains.isNumber and: { (maxGrains - 1) >= (0.5 * 100 * 2) } and: { maxGrains < 512 },
        "maxGrains covers the largest grain overlap Lua sends (100) and is below GrainIn's default 512 (got %)".format(maxGrains));
    grainDefs.do({ arg name;
        var ugens = SynthDescLib.global.at(name).def.children;
        var windows = ugens.select({ arg ugen; ugen.isKindOf(PitchShift) }).collect({ arg ugen; ugen.inputs[1] });
        var grainTables = ugens.select({ arg ugen; ugen.isKindOf(GrainIn) or: { ugen.isKindOf(GrainBuf) } })
            .collect({ arg ugen; ugen.inputs.last });
        check.(windows.notEmpty and: { windows.every({ arg each; each.isNumber and: { each == window } }) },
            "%'s PitchShift windows are the fixed pitchShiftWindow, not the grain size (got %)".format(name, windows));
        check.(grainTables.notEmpty and: { grainTables.every({ arg each; each == maxGrains }) },
            "%'s grain UGens use maxGrains (got %)".format(name, grainTables));
    });
};

// The worst cases (inside the check routine): every voice at the largest
// grain size and density Lua sends, switched synth -> buffer -> input ->
// synth. Spaced: each switch processed before the next (0.2 s apart, well
// past switchCutTime, as E3 detents arrive), then stopped and started; at
// the last switch each voice holds its live synths, the input grain synth
// releasing and the buffer grain synth in its kill fade. Burst: the three
// switches at once on every voice (a chord of grid scene buttons, or
// PMAP-mapped source params), where each switch frees the synths the
// previous one left in their kill fade, so the voice holds no more. Recalls:
// scenes A = on/synth, B = off/input, C = on/buffer recalled A -> B -> A -> C
// at once (#46), each voice's source sent before its stop or start (the order
// Lua used before #46, the worst one): B builds an input grain synth and
// releases it, A's voiceOn hands it to fadingSynths, and the voice still
// holds no more than its live synths, one fading and one cutting set. Each
// time, on norns' 8192 KB pool (memSize, set before boot), four 256 KB probes
// (1 MB) started at that moment must still allocate. The probe bus is zeroed
// first, so a probe whose /s_new fails reads 0. run_engine_check.sh also
// fails on any "alloc failed" the server prints.
var checkMemoryWorstCase = {
    var probeCount = 4, probeBus = Bus.control(server, probeCount);
    var startVoice = { arg voice; command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 200.0, 1.0) };
    var startAll = { engine.numVoices.do(startVoice) };
    var switchAll = { arg sourceOf; engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, sourceOf.(voice)) }) };
    var sourceSteps = [{ arg voice; voice + 1 }, { engine.numBuffers + 1 }, { 0 }];
    // started at once after the last command, while the cut synths still fade
    var probeHeadroom = { arg label;
        var probes = probeCount.collect({ arg index;
            Synth(\strataCheckMemProbe, [\out, probeBus.index + index], engine.processGroup, \addToTail)
        }), values;
        server.sync; 0.1.wait;
        values = {
            var condition = Condition(false), result;
            probeBus.getn(probeCount, { arg each; result = each; condition.test = true; condition.signal });
            awaitReply.(condition);
            result ? []
        }.value;
        check.((values.size == probeCount) and: { values.every({ arg value; value > 0.5 }) },
            "% leave at least % KB of norns' real-time pool free (probes %)".format(label, probeCount * 256, values));
        probes.do(_.free);
        2.5.wait; server.sync;
    };
    startAll.value;
    probeBus.setAll(0); server.sync; 0.2.wait;
    sourceSteps.do({ arg sourceOf, step;
        if (step > 0) { 0.2.wait; server.sync };
        switchAll.(sourceOf);
    });
    engine.numVoices.do({ arg voice; command.(\voiceOff, voice) });
    startAll.value;
    probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted,");
    probeBus.setAll(0); server.sync;
    sourceSteps.do({ arg sourceOf; switchAll.(sourceOf) });
    probeHeadroom.("seven voices at grain size 0.5, each switched three times at once,");
    probeBus.setAll(0); server.sync;
    engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, engine.numBuffers + 1); command.(\voiceOff, voice) });
    engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, 0); startVoice.(voice) });
    engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, voice + 1) });
    probeHeadroom.("seven voices at grain size 0.5, recalled A -> B -> A -> C at once (on/synth, off/input, on/synth, on/buffer),");
    probeBus.free;
};

// ---- Engine audio (#21), also as top-level functions ----

// Check-only SynthDefs: the peak of each channel of a stereo bus since the
// last t_reset; 1 once a NaN or inf (CheckBadValues codes 1 and 2; 3 is a
// denormal) has reached a stereo bus since the last t_reset; and 50 ms of
// inf (left, a float overflow: log(0) does not give -inf in scsynth) and NaN
// (right), after which it frees itself
var addAudioCheckDefs = {
    SynthDef(\strataCheckChannelPeaks, { arg in, out, t_reset = 0;
        Out.kr(out, A2K.kr(Peak.ar(In.ar(in, 2).abs, t_reset)));
    }).add;
    SynthDef(\strataCheckBadValues, { arg in, out, t_reset = 0;
        var codes = CheckBadValues.ar(In.ar(in, 2), 0, 0);
        Out.kr(out, A2K.kr(Peak.ar(((codes > 0.5) * (codes < 2.5)).sum, t_reset)));
    }).add;
    // the RMS of a stereo bus over about the last 1.5 s (a 10 s 60 dB lag of the mean square)
    SynthDef(\strataCheckRms, { arg in, out;
        Out.kr(out, A2K.kr(Lag.ar(In.ar(in, 2).squared.sum * 0.5, 10).sqrt));
    }).add;
    SynthDef(\strataCheckBadSource, { arg out, big = 1e30;
        var infinite = DC.ar(big) * big;
        Line.kr(0, 0, 0.05, doneAction: 2);
        Out.ar(out, [infinite, infinite - infinite]);
    }).add;
};

// A control bus's values (inside the check routine)
var readBus = { arg bus;
    var condition = Condition(false), values;
    bus.getn(bus.numChannels, { arg result; values = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    values ? []
};
// Reset a peak probe, wait, and read what it measured meanwhile
var measure = { arg probe, bus, seconds = 0.3;
    probe.set(\t_reset, 1);
    seconds.wait;
    readBus.(bus)
};

// The Resonator's filter cutoff stays below Nyquist: sixteen Resonators far
// past it (10-25 kHz, x 3 by frequency crossmod, bent up 2 semitones, rq 1,
// each with its own noise factor of 1-4) on a private bus produce no NaN or
// inf. Unclamped, RLPF is unstable whenever cutoff x rq falls between SR/2
// and SR (or the same band above a multiple of SR), so some would blow up.
var checkResonatorCeiling = {
    var group = Group.tail(server), out = Bus.audio(server, 2), modBus = Bus.control(server, 1);
    var badBus = Bus.control(server, 1), probe, bad;
    modBus.set(1);
    16.do({ arg index;
        Synth(\strataResonator, [\out, out, \freq, 10000 + (index * 1000), \rq, 1, \amp, 0.3, \bend, 2 ** (2 / 12),
            \modBus1, modBus.index, \modBus2, engine.silentBus.index, \modBus3, engine.silentBus.index,
            \modFreqAmt1, 2], group);
    });
    probe = Synth(\strataCheckBadValues, [\in, out, \out, badBus], group, \addToTail);
    server.sync;
    bad = measure.(probe, badBus, 1.5);
    check.(bad == [0], "Resonators with a cutoff far past Nyquist stay finite (bad values seen: %)".format(bad));
    group.free; out.free; modBus.free; badBus.free;
    server.sync;
};

// The Resonator's level: DynKlank's resonators driven by noise ring far
// hotter than the other voices (at its defaults it peaked about 23 before
// the master limiter, at reachable extremes in the thousands, so it crushed
// every other voice). resonatorGain and a mono limiter at voiceCeiling (1,
// before the pan) fix it:
// - eight Resonators at their defaults (amp 0.3, no accents) have a median
//   RMS of 0.045-0.2 (measured about 0.1; a gain left 3x too high gives
//   about 0.29, which the limiter does not hide the way it hides peaks)
//   and peak at most 0.75 per channel;
// - at the extremes Lua allows (freq 20-2000, rq 0.01 or 1, noise 1, amp 1,
//   amplitude and frequency crossmod at full, accents at velocity 1 every
//   0.25 s), centered, no channel passes 0.75 (the limiter's 1 x Pan2's
//   0.707 at the center);
// - one extreme panned hard right reaches the limiter's own level: its right
//   channel peaks at 0.9-1.05 and its left stays silent.
var checkResonatorLevel = {
    var group = Group.tail(server), modBus = Bus.control(server, 1), silent = engine.silentBus.index;
    var defaults = [\freq, 100, \rq, 0.1, \noise, 0.5, \amp, 0.3, \modBus1, silent, \modBus2, silent];
    var extremes = [20, 100, 400, 2000].collect({ arg freq; [0.01, 1].collect({ arg rq;
        [\freq, freq, \rq, rq, \noise, 1, \amp, 1, \modAmpAmt1, 2, \modFreqAmt2, 2]
    }) }).flatten(1);
    var panned = [\freq, 20, \rq, 0.01, \noise, 1, \amp, 1, \modAmpAmt1, 2, \modFreqAmt2, 2, \pan, 1];
    var defaultCount = 8, cases = (defaultCount.collect({ defaults }) ++ extremes ++ [panned]);
    var buses = cases.collect({ Bus.audio(server, 2) }), peakBus = Bus.control(server, 2 * cases.size);
    var rmsBus = Bus.control(server, defaultCount), synths, peaks, rms, defaultPeak, extremePeak, pannedPeaks;
    // Limiter delays its output by twice its lookahead (dur): its default
    // 0.01 s put the Resonator 20 ms behind the other voices (#47)
    var lookaheads = SynthDescLib.global.at(\strataResonator).def.children.select({ arg ugen; ugen.isKindOf(Limiter) })
        .collect({ arg ugen; ugen.inputs[2] });
    check.((lookaheads.size == 1) and: { lookaheads[0].isNumber } and: { lookaheads[0] >= 0.002 } and: { lookaheads[0] <= 0.005 }
        and: { lookaheads[0] == engine.tryPerform(\voiceLimiterLookahead) },
        "the Resonator's limiter looks ahead voiceLimiterLookahead, 2-5 ms, delaying the voice 4-10 ms (got %)".format(lookaheads));
    modBus.set(1);
    synths = cases.collect({ arg args, index;
        Synth(\strataResonator, [\out, buses[index], \modBus1, modBus.index, \modBus2, modBus.index, \modBus3, silent] ++ args, group)
    });
    cases.do({ arg args, index;
        Synth(\strataCheckChannelPeaks, [\in, buses[index], \out, peakBus.index + (2 * index)], group, \addToTail);
        if (index < defaultCount) { Synth(\strataCheckRms, [\in, buses[index], \out, rmsBus.index + index], group, \addToTail) };
    });
    server.sync; 4.5.wait;                     // past the 4 s attack
    group.set(\t_reset, 1);
    4.wait;                                    // the RMS meters have forgotten the attack
    rms = readBus.(rmsBus).sort;
    defaultPeak = readBus.(peakBus).copyRange(0, (2 * defaultCount) - 1).maxItem;
    group.set(\t_reset, 1);
    8.do({ synths.do({ arg synth; synth.set(\velocity, 1, \t_trig, 1) }); 0.25.wait });
    peaks = readBus.(peakBus).clump(2);
    extremePeak = peaks.copyRange(defaultCount, defaultCount + extremes.size - 1).flatten.maxItem;
    pannedPeaks = peaks.last;
    check.((rms.size == defaultCount) and: { rms[defaultCount div: 2] >= 0.045 } and: { rms[defaultCount div: 2] <= 0.2 },
        "the Resonator at its defaults has a median RMS of 0.045-0.2 (got %, all %)".format(
            rms[defaultCount div: 2], rms.collect({ arg value; value.round(0.001) })));
    check.(defaultPeak.notNil and: { defaultPeak > 0.05 } and: { defaultPeak <= 0.75 },
        "the Resonator at its defaults peaks at most 0.75 per channel (got %)".format(defaultPeak));
    check.(extremePeak.notNil and: { extremePeak <= 0.75 },
        "the Resonator at reachable extremes, centered, never peaks past 0.75 per channel (got %; per case %)".format(extremePeak,
            peaks.copyRange(defaultCount, defaultCount + extremes.size - 1).collect(_.maxItem).collect({ arg value; value.round(0.01) })));
    check.(pannedPeaks.notNil and: { pannedPeaks[1] >= 0.9 } and: { pannedPeaks[1] <= 1.05 } and: { pannedPeaks[0] < 0.001 },
        "a Resonator extreme panned hard right peaks at its limiter's level, 0.9-1.05 (got %)".format(pannedPeaks));
    group.free; modBus.free; peakBus.free; rmsBus.free; buses.do(_.free);
    server.sync;
};

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

// A NaN or inf on a voice bus (a voice blowing up) never reaches its mod bus
// (#47), so it cannot spread through crossmod into the voices it modulates
// and, through their mod synths, on, for good. On private buses: a tone and
// 50 ms of inf and NaN on a voice bus, read by a strataMod; a Resonator
// modulated by its mod bus at full amplitude and frequency depth. After the
// burst the mod bus is finite and follows the tone again, and the Resonator
// has produced no bad value.
var checkModGuard = {
    var group = Group.tail(server), voiceBus = Bus.audio(server, 2), out = Bus.audio(server, 2), modBus = Bus.control(server, 1);
    var voiceBadBus = Bus.control(server, 1), badBus = Bus.control(server, 1), abBus = Bus.control(server, 4), silent = engine.silentBus.index;
    var mod, probe, voiceBad, bad, modValue, ab;
    var guards = SynthDescLib.global.at(\strataMod).def.children.count({ arg ugen; ugen.isKindOf(CheckBadValues) });
    // A/B first: zeroBadValues, the guard strataMod applies to its input
    // (audio) and output (control), passes normal values bit for bit: the
    // largest difference between guarded and unguarded copies of a varied
    // signal (and of its follower) is exactly 0, while the signals are not
    SynthDef(\strataCheckGuardAB, { arg in, out;
        var audio = In.ar(in, 2).sum * LFNoise1.ar(50).exprange(0.001, 3);
        var control = (Amplitude.kr(audio, 0.01, 0.1) * 0.7) + LFNoise1.kr(10).range(0, 0.3);
        Out.kr(out, [A2K.kr(Peak.ar((engine.zeroBadValues(audio) - audio).abs)),
            Peak.kr((engine.zeroBadValues(control) - control).abs), A2K.kr(Peak.ar(audio.abs)), Peak.kr(control.abs)]);
    }).add;
    server.sync;
    Synth(\strataCheckTone, [\out, voiceBus], group);
    Synth(\strataCheckGuardAB, [\in, voiceBus, \out, abBus], group, \addToTail);
    server.sync; 0.5.wait;
    ab = readBus.(abBus);
    check.((guards == 2) and: { ab.size == 4 } and: { ab[0] == 0 } and: { ab[1] == 0 } and: { ab[2] > 0.1 } and: { ab[3] > 0.1 },
        "strataMod guards its input and output (% CheckBadValues) and the guard passes normal values bit for bit (largest difference audio %, control %; peaks %, %)".format(
            guards, ab[0], ab[1], ab[2], ab[3]));
    group.freeAll; server.sync;
    Synth(\strataCheckTone, [\out, voiceBus], group);
    mod = Synth(\strataMod, [\in, voiceBus, \out, modBus], group, \addToTail);
    Synth(\strataCheckBadValues, [\in, voiceBus, \out, voiceBadBus], mod, \addBefore);
    Synth(\strataResonator, [\out, out, \modBus1, modBus.index, \modBus2, silent, \modBus3, silent,
        \modAmpAmt1, 2, \modFreqAmt1, 2], group, \addToTail);
    probe = Synth(\strataCheckBadValues, [\in, out, \out, badBus], group, \addToTail);
    server.sync; 0.5.wait;
    Synth(\strataCheckBadSource, [\out, voiceBus], group, \addToHead);
    server.sync; 0.3.wait;
    voiceBad = readBus.(voiceBadBus);
    check.(voiceBad.notEmpty and: { voiceBad[0] > 0 }, "the check's burst puts NaN and inf on the voice bus (seen: %)".format(voiceBad));
    bad = measure.(probe, badBus, 0.5);
    modValue = readBus.(modBus)[0];
    check.(modValue.notNil and: { modValue.isNaN.not } and: { modValue > 0.3 } and: { modValue < 2 },
        "after the burst strataMod's output is finite and follows the voice again (got %)".format(modValue));
    check.(bad == [0], "a voice crossmodulated by a voice that blew up stays finite (bad values seen: %)".format(bad));
    group.free; voiceBus.free; out.free; modBus.free; voiceBadBus.free; badBus.free; abBus.free;
    server.sync;
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

// A mod synth the engine restarts (its release ended just as voiceOn
// re-gated it) keeps the voice's mod speed
var checkModSpeedRestart = { arg voice;
    var key = engine.modKey(voice), oldMod;
    command.(\setModSpeed, voice, 3.5); server.sync;
    oldMod = engine.synths[key];
    server.sendMsg(\n_free, oldMod.nodeID);  // ends without sclang having freed it
    0.2.wait; server.sync;
    check.(engine.synths[key].notNil and: { engine.synths[key] !== oldMod }
        and: { getControl.(engine.synths[key], \speed) == 3.5 },
        "a restarted mod synth keeps the voice's mod speed (got %)".format(engine.synths[key] !? { getControl.(engine.synths[key], \speed) }));
};

// The crossmod commands take slots 1..numModSlots, the modBus1..N of every
// voice SynthDef, and ignore any other slot (#47): nothing is kept for it in
// voiceControls (where it stayed for good) and the voice's slots are
// unchanged. The voice runs on its synth source.
var checkModSlots = { arg voice;
    var slots = engine.tryPerform(\numModSlots), synth = engine.synths[engine.voiceKey(voice)], stray;
    var modBusCounts = voiceDefs.collect({ arg name;
        SynthDescLib.global.at(name).controlNames.count({ arg control; control.asString.beginsWith("modBus") })
    });
    check.(slots.notNil and: { modBusCounts.every({ arg count; count == slots }) },
        "numModSlots (%) is the number of modBus controls of every voice SynthDef (%)".format(slots, modBusCounts));
    [0, 4, -1].do({ arg slot;
        command.(\setModSource, voice, slot, 0);
        command.(\setModAmpAmt, voice, slot, 0.5);
        command.(\setModFreqAmt, voice, slot, 0.5);
    });
    command.(\setModAmpAmt, voice, 3, 0.25);
    server.sync;
    stray = ["modBus", "modAmpAmt", "modFreqAmt"].collect({ arg prefix; [0, 4, -1].collect({ arg slot; (prefix ++ slot).asSymbol }) })
        .flatten.select({ arg name; engine.voiceControls[voice][name].notNil });
    check.(stray.isEmpty and: { getControl.(synth, \modAmpAmt3) == 0.25 } and: { engine.voiceControls[voice][\modAmpAmt3] == 0.25 },
        "crossmod commands ignore slots 0, 4 and -1 and slot 3 still works (stray controls kept: %)".format(stray));
    command.(\setModAmpAmt, voice, 3, 0.0);
};

// voiceOn after a source change in the release: the previous source's
// releasing grain synth and the voice synth (now forced to release) are
// tracked as the voice's fadingSynths, not left releasing beside the new
// one, and the next start for another source cuts them (#46). The voice
// runs on its synth source.
var checkSupersededAtStart = { arg voice, before;
    var oldTrio = voiceTrio.(voice), fading = engine.fadingSynths[voice];
    command.(\voiceOff, voice);
    command.(\setGrainSource, voice, 9);
    command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); server.sync;
    check.(oldTrio[1].isPlaying and: { engine.synths[engine.grainKey(voice)] !== oldTrio[1] }
        and: { fading.includes(oldTrio[1]) } and: { fading.includes(oldTrio[0]) }
        and: { engine.releasingSynths[voice][engine.grainKey(voice)].isNil }
        and: { engine.releasingSynths[voice][engine.voiceKey(voice)].isNil },
        "voiceOn hands the previous source's releasing grain and voice synths to fadingSynths");
    command.(\voiceOff, voice); server.sync;
    check.(oldTrio[1].isPlaying and: { fading.includes(oldTrio[1]) }, "voiceOff keeps them fading (tracked)");
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); 0.15.wait; server.sync;
    check.(oldTrio[1].isPlaying.not and: { oldTrio[0].isPlaying.not } and: { engine.cuttingSynths[voice].isEmpty },
        "the next start for another source cuts them (got grain %, voice %)".format(oldTrio[1].isPlaying, oldTrio[0].isPlaying));
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "the voice is back on its synth with one trio");
};

// Fast stop / source change / start / running switch cycles on one voice:
// voiceOn hands the releasing synths built for another source to
// fadingSynths as a switch does (cutting the fading ones, freeing the
// cutting ones), so the voice holds at most its live grain synth, one fading
// and one cutting (#46), and as many voice synths. The cycles visit the
// synth source too: [9, 0] from the synth source hands the released voice
// synth to fadingSynths at voiceOn and cuts it as the switch back starts a
// new one, so two voice synths are held at once there (the count measures
// something). Two passes:
// - the engine's own tracking (live, releasing, fading and cutting synths)
//   after every command, all 24 commands without a yield: no /n_end is
//   handled meanwhile, so nothing leaves the sets on its own and the counts
//   do not depend on server timing (an upper bound on what the server runs)
// - the server's node tree after every step (sync, one /g_queryTree), as an
//   upper bound only: a slower server can only have freed more
var checkStopStartCycles = { arg voice;
    var before = synthNames.(context.xg).size, cycles = [[9, 3], [0, 9], [4, 0], [9, 0], [4, 3], [0, 9]];
    var trackedGrains = 0, trackedVoices = 0, serverGrains = 0, serverVoices = 0;
    var runCycles = { arg afterStep;
        // [stopped source, running source]: each differs from the one before
        cycles.do({ arg sources;
            command.(\voiceOff, voice); afterStep.value;
            command.(\setGrainSource, voice, sources[0]); afterStep.value;
            command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0); afterStep.value;
            command.(\setGrainSource, voice, sources[1]); afterStep.value;
        });
    };
    runCycles.({
        var held = IdentitySet.new;
        [engine.synths, engine.releasingSynths[voice]].do({ arg dict;
            [engine.voiceKey(voice), engine.grainKey(voice)].do({ arg key; dict[key] !? { arg synth; held.add(synth) } });
        });
        held.addAll(engine.fadingSynths[voice]); held.addAll(engine.cuttingSynths[voice]);
        trackedGrains = max(trackedGrains, held.count({ arg synth; grainDefs.includes(synth.defName.asSymbol) }));
        trackedVoices = max(trackedVoices, held.count({ arg synth; synth.defName.asSymbol == engine.voiceSynthDefs[voice] }));
    });
    check.(trackedGrains <= 3, "six fast stop / source / start / switch cycles hold at most three grain synths after every command (worst %)".format(trackedGrains));
    check.((trackedVoices <= 3) and: { trackedVoices >= 2 }, "and at most three voice synths, two at once after [9, 0] (worst %)".format(trackedVoices));
    command.(\setGrainSource, voice, 0);
    2.5.wait; server.sync;
    runCycles.({
        var nodes;
        server.sync;
        nodes = synthNodes.(context.xg);
        serverGrains = max(serverGrains, voiceGrainNodes.(nodes, voice).size);
        serverVoices = max(serverVoices, nodes.count({ arg node; node.def == engine.voiceSynthDefs[voice] }));
    });
    check.((serverGrains <= 3) and: { serverVoices <= 3 },
        "and the server runs at most three of each after every step (worst % grain, % voice)".format(serverGrains, serverVoices));
    command.(\setGrainSource, voice, 0);
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "the fast cycles leave no extra nodes");
};

// The invariant warnings (#46): a synth found releasing where the
// bookkeeping never leaves one (injected here: a stand-in synth in
// releasingSynths of a running voice) is still handled, and the engine
// posts a "Strata invariant broken" line that run_engine_check.sh fails
// on. The lines are captured through postInvariantWarning, so this run
// does not fail (nor do these checks print them); the stand-ins are freed
// and forgotten afterward. The voice runs on its synth source.
var engineCheckScript = thisProcess.nowExecutingPath !? { arg path; path.dirname +/+ "run_engine_check.sh" };
var checkInvariantWarnings = { arg voice, before;
    var lines = List.new, grainKey = engine.grainKey(voice), standIns, failPattern, standInBus = Bus.control(server, 1);
    var standIn = { Synth(\strataCheckMemProbe, [\out, standInBus.index], engine.processGroup, \addToTail).register(true) };
    var scriptText = engineCheckScript !? { arg path; File.exists(path).if({ File.readAllString(path) }) };
    engine.postInvariantWarning = { arg line; lines.add(line) };
    standIns = [standIn.value, standIn.value]; server.sync;
    // a switch of a running voice that finds a synth in releasingSynths
    engine.releasingSynths[voice][grainKey] = standIns[0];
    command.(\setGrainSource, voice, 9);
    check.((lines.size == 1) and: { lines[0].contains("Strata invariant broken") }
        and: { engine.releasingSynths[voice][grainKey].isNil } and: { engine.cuttingSynths[voice].includes(standIns[0]) },
        "a switch that finds a synth releasing cuts it and warns (% lines)".format(lines.size));
    // a stop that finds a superseded synth under a running synth's key
    engine.releasingSynths[voice][grainKey] = standIns[1];
    command.(\voiceOff, voice);
    check.((lines.size == 2) and: { lines[1].contains("Strata invariant broken") }
        and: { engine.fadingSynths[voice].includes(standIns[1]) },
        "a stop that finds a superseded synth hands it to fadingSynths and warns (% lines)".format(lines.size));
    engine.postInvariantWarning = nil;
    // run_engine_check.sh fails on these lines as String.warn posts them
    failPattern = scriptText !? { arg text;
        text.split($\n).detect({ arg line; line.contains("! grep -qE") }) !? { arg line; line.split($").at(1) }
    };
    check.(failPattern.notNil and: { lines.every({ arg line; ("WARNING: " ++ line).findRegexp(failPattern).notEmpty }) },
        "run_engine_check.sh's failure pattern matches the posted warnings (pattern found: %)".format(failPattern.notNil));
    // ... and the line the server prints for a grain UGen past its maxGrains,
    // which drops grains (#47). The check's own line must not quote it: the
    // script would fail on that too
    check.(failPattern.notNil and: { "Too many grains!".findRegexp(failPattern).notEmpty },
        "run_engine_check.sh's failure pattern matches the server's line for a grain UGen past maxGrains");
    command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0);
    command.(\setGrainSource, voice, 0);
    server.sync;
    // the first was freed by the stop's freeCuttingSynths already
    standIns.do({ arg synth;
        if (synth.isPlaying) { server.sendBundle(nil, ['/error', -1], ['/n_free', synth.nodeID]) };
        engine.fadingSynths[voice].remove(synth); engine.cuttingSynths[voice].remove(synth);
    });
    2.5.wait; server.sync;
    standInBus.free;
    check.(synthNames.(context.xg).size == before, "the voice is back on its synth with one trio, the stand-ins gone");
};

// Messages to synths that can end on the server on their own go out
// quietly (sendToSynth, #47). Each race frees synths on the server behind
// sclang's back, so their /n_end is not handled yet and the engine still
// sees them playing, then at once sends the command that messages them. The
// server must report none of it: no /fail reply, so no "FAILURE IN SERVER"
// line, on which run_engine_check.sh fails (the flake this prevents). Each
// race is [what messages the freed synths, setup (may wait), the race]. The
// voice runs on its synth source and ends there, with what it still uses
// restarted by the engine; slot 8 (index 7) is free for the check.
var checkQuietNodeSends = { arg voice, before;
    var fails = List.new, watcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr);
    var keys = [engine.voiceKey(voice), engine.grainKey(voice), engine.modKey(voice)];
    var start = { command.(\voiceOn, voice, 40.0, 0.25, 0.0, 0.1, 10.0, 1.0) };
    var freeBehind = { arg nodes; nodes.do({ arg node; if (node.notNil) { server.sendMsg(\n_free, node.nodeID) } }) };
    var releasing = { arg names; names.collect({ arg key; engine.releasingSynths[voice][key] }) };
    [
        ["setSynth (a grain param) to the live grain synth", {}, {
            freeBehind.([engine.synths[keys[1]]]); command.(\setGrainParam, voice, \grainSize, 0.1) }],
        ["releaseVoice (voiceOff) gating off the live synths", {}, {
            freeBehind.(voiceTrio.(voice)); command.(\voiceOff, voice) }],
        ["gateVoice (voiceOn) re-gating the releasing synths", { start.value; server.sync; command.(\voiceOff, voice) }, {
            freeBehind.(releasing.(keys)); start.value }],
        ["replaceGrainSynth (a switch) releasing the live synths and moving the new grain synth before the freed mod synth", {}, {
            freeBehind.(voiceTrio.(voice)); command.(\setGrainSource, voice, 9) }],
        ["cutSynth (the next switch) cutting the fading synths", { command.(\setGrainSource, voice, 0) }, {
            freeBehind.(engine.fadingSynths[voice].asArray); command.(\setGrainSource, voice, 9) }],
        ["gateVoice (voiceOn for another source) releasing the voice synth and moving the mod synth", {
            command.(\setGrainSource, voice, 0); server.sync; command.(\voiceOff, voice); command.(\setGrainSource, voice, 9) }, {
            freeBehind.(releasing.([keys[0], keys[2]])); start.value }],
        ["stopRecording (stopRecord) freeing a record synth whose take has just ended", {
            command.(\recordBuffer, 7, 0.5, 1.0); 0.2.wait }, {
            freeBehind.([engine.recordSynths[7]]); command.(\stopRecord, 7) }],
        ["bufferChanged (a clear) fading a releasing buffer grain synth", {
            command.(\setGrainSource, voice, 8); server.sync; command.(\voiceOff, voice) }, {
            freeBehind.(releasing.([keys[1]])); command.(\clearBuffer, 7) }]
    ].do({ arg race;
        race[1].value;
        server.sync; 0.1.wait; server.sync;
        fails.clear;
        race[2].value;
        server.sync; 0.3.wait; server.sync;    // the engine has restarted what the voice still uses
        check.(fails.isEmpty, "% sends quietly to synths that have just freed (server failures: %)".format(race[0], fails));
    });
    watcher.free;
    command.(\setGrainSource, voice, 0); start.value;
    2.5.wait; server.sync;
    check.(synthNames.(context.xg).size == before, "after the races the voice is back on its synth with one trio");
};

// Buffer- and input-sourced voices, on a running voice on its synth source
// and an empty slot: the voice's pan places their grains (pan -1 left only,
// 1 right only), triggered grain mode fires one grain per retrigger and
// nothing without one (as for a synth voice), and a buffer grain never reads
// past the end of the slot's valid region. The grain synth writes to a
// private bus for the measurements.
var checkSourceGrains = { arg voice, slot;
    var grainKey = engine.grainKey(voice), privateBus = Bus.audio(server, 2), peakBus = Bus.control(server, 2);
    var group = Group.after(engine.processGroup), path = scratchRoot +/+ "source-grains.wav";
    var tone, probe, peaks, file, frames = server.sampleRate.asInteger;
    var toPrivate = { engine.synths[grainKey].set(\out, privateBus.index); server.sync };
    var toMain = { engine.synths[grainKey].set(\out, engine.mainBus.index) };

    grainDefs.do({ arg name;
        check.(controlFeedsAUGen.(name, \pan), "% has a pan control that reaches a UGen".format(name));
    });
    // the synth source's grain synth never pans again (the voice synth does)
    command.(\setVoiceParam, voice, \pan, -1.0); server.sync;
    check.((getControl.(engine.synths[engine.voiceKey(voice)], \pan) == -1) and: { getControl.(engine.synths[grainKey], \pan) == 0 },
        "a synth-sourced voice's pan reaches its voice synth, never its grain synth");

    // a 1 s stereo 440 Hz sine at 0.5, at the server rate
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(server.sampleRate);
    file.openWrite(path);
    file.writeData(FloatArray.fill(frames * 2, { arg i; sin(2pi * 440 * (i div: 2) / server.sampleRate) * 0.5 }));
    file.close;
    command.(\loadBuffer, slot, path); 0.3.wait; server.sync;
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
    probe = Synth(\strataCheckChannelPeaks, [\in, privateBus, \out, peakBus], group);

    [[slot + 1, "a buffer"], [engine.numBuffers + 1, "an input"]].do({ arg pair;
        var label = pair[1];
        command.(\setVoiceParam, voice, \pan, -1.0);
        command.(\setGrainSource, voice, pair[0]); server.sync;
        toPrivate.value;
        check.(getControl.(engine.synths[grainKey], \pan) == -1, "%-sourced voice's grain synth starts at the voice's pan".format(label));
        [[-1.0, [true, false]], [1.0, [false, true]], [0.0, [true, true]]].do({ arg panCase;
            command.(\setVoiceParam, voice, \pan, panCase[0]); server.sync;
            peaks = measure.(probe, peakBus, 0.3);
            check.((peaks.size == 2) and: { [0, 1].every({ arg channel;
                    if (panCase[1][channel]) { peaks[channel] > 0.01 } { peaks[channel] < 0.001 } }) },
                "%-sourced voice at pan % sounds % (peaks %)".format(label, panCase[0],
                    ["left only", "right only", "on both sides"][[[true, false], [false, true], [true, true]].indexOfEqual(panCase[1])], peaks));
        });
        // triggered grain mode
        command.(\setGrainParam, voice, \grainMode, 1);
        0.5.wait; server.sync;                 // grains in flight and the PitchShift window have ended
        peaks = measure.(probe, peakBus, 0.3);
        check.(peaks.sum < 0.001, "%-sourced voice in triggered mode is silent without a trigger (peaks %)".format(label, peaks));
        probe.set(\t_reset, 1); server.sync;
        command.(\retrigger, voice, 1.0);
        0.3.wait;
        peaks = readBus.(peakBus);
        check.(peaks.sum > 0.01, "a retrigger fires a grain on %-sourced voice in triggered mode (peaks %)".format(label, peaks));
        command.(\setGrainParam, voice, \grainMode, 0);
        toMain.value;
    });

    // Grain end: a slot of silence whose frames past the valid region hold 1
    // (set by hand after the load, which zeroes them). Grains scanning up to
    // the region's end, at a rate and size that read far past it unless
    // limited, must read silence only: at the server rate, at 22050 Hz and
    // rate 2, at 96 kHz (GrainBuf reads two frames per sample there: a limit
    // that left out the buffer's rate scale would read past the end), and
    // with a region shorter than a grain. [file rate, seconds, grain size, rate]
    command.(\setGrainSource, voice, slot + 1); server.sync;
    toPrivate.value;
    [[server.sampleRate, 0.25, 0.2, 1], [22050, 0.25, 0.2, 2], [96000, 0.25, 0.2, 1], [server.sampleRate, 0.05, 0.2, 1]].do({ arg grainCase;
        var validFrames;
        writeTestFile.(path, grainCase[0], (grainCase[0] * grainCase[1]).round.asInteger, [0, 0]);
        command.(\loadBuffer, slot, path); 0.3.wait; server.sync;
        validFrames = engine.bufferFrames[slot];
        [engine.buffersL[slot], engine.buffersR[slot]].do({ arg buffer; buffer.fill(validFrames, buffer.numFrames - validFrames, 1) });
        command.(\setGrainParam, voice, \grainSize, grainCase[2]);
        command.(\setGrainParam, voice, \bufRate, grainCase[3]);
        command.(\setGrainParam, voice, \bufPos, 0.9);
        command.(\setGrainParam, voice, \bufScan, 0.5);
        server.sync; 0.3.wait;                 // grains started before the fill have ended
        peaks = measure.(probe, peakBus, 0.6);
        check.((peaks.size == 2) and: { peaks.maxItem < 0.001 },
            "grains never read past the valid region (% s at % Hz, grain % s, rate %; peaks %)".format(
                grainCase[1], grainCase[0], grainCase[2], grainCase[3], peaks));
    });
    toMain.value;
    [[\grainSize, 0.1], [\bufRate, 1], [\bufPos, 0], [\bufScan, 0]].do({ arg pair; command.(\setGrainParam, voice, *pair) });
    command.(\setVoiceParam, voice, \pan, 0.0);
    command.(\clearBuffer, slot);
    command.(\setGrainSource, voice, 0);
    tone.free; group.free;
    2.5.wait; server.sync;
    privateBus.free; peakBus.free;
    File.delete(path);
};

server.addr = NetAddr("127.0.0.1", scPort);
("scsynth port: %".format(scPort)).postln;
server.options.numInputBusChannels = 2;
// norns' real-time memory pool: Crone.sc boots Server.local without setting
// memSize, so scsynth gets the ServerOptions default of 8192 KB. Set it
// explicitly so the worst-case memory check below measures norns' budget.
server.options.memSize = 8192;
// Whatever hangs (a server.sync to a server that went away), the check ends:
// a failed run after 540 s, inside CI's 600 s timeout
SystemClock.sched(540, {
    "FAIL engine check did not finish within 540 s".postln;
    ("ENGINE CHECK FAILED: timed out after % failures".format(failures)).postln;
    server.quit;
    SystemClock.sched(1, { 1.exit });
    nil
});
server.waitForBoot({
    var exitCode;
    try {
        var oldTrio, before, after, silentIndex, startedNames, masterUGens, envSamples;
        var oldGrain, oldVoiceSynth, grainBuf, scratchFile, savePath, file, frames, data;
        var stereoPath, monoPath, longPath, textPath, info;
        var grainInUGens, tone, probe, peakBus, readPeak, duringPeak, afterPeak;
        var grainCount, voiceCount, grainBefore, voiceBefore;
        var countVoiceAndGrain, maxGrainCount, maxVoiceCount;
        var triggeredBus, continuousPeak, untriggeredPeak, triggeredPeak;
        var filterGroup, filterIn, filterOut, stepBus, filterSynth, stepProbe, readStep, steadySteps, switchStep;
        var orderNodes, orderGrains, busReadingAt, mirroringAt, longWritePath, writeStart, writeSeconds, rampValue;
        var tempFilesBefore = tempFloatFiles.value;

        CroneDefs.sendDefs(server);
        // Check-only helpers: a test tone (written into the input bus) and a
        // peak meter on a stereo bus (reset with t_reset, read from a control bus)
        SynthDef(\strataCheckTone, { arg out; Out.ar(out, SinOsc.ar(440, 0, 0.5) ! 2) }).add;
        SynthDef(\strataCheckPeak, { arg in, out, t_reset = 0;
            Out.kr(out, A2K.kr(Peak.ar(In.ar(in, 2).abs.sum, t_reset)));
        }).add;
        // ... a sine of any frequency, and the largest sample-to-sample step
        // of a bus's left channel since the last t_reset
        SynthDef(\strataCheckSine, { arg out, freq = 1000; Out.ar(out, SinOsc.ar(freq, 0, 0.5) ! 2) }).add;
        SynthDef(\strataCheckStep, { arg in, out, t_reset = 0;
            var sig = In.ar(in, 2)[0];
            Out.kr(out, A2K.kr(Peak.ar((sig - Delay1.ar(sig)).abs, t_reset)));
        }).add;
        // ... and a real-time memory probe: a delay line of 65536 floats
        // (256 KB) taken from the real-time pool; it passes 1 through, or
        // reads 0 if the allocation failed
        SynthDef(\strataCheckMemProbe, { arg out; Out.kr(out, A2K.kr(DelayN.ar(DC.ar(1), 1.0, 0.01))) }).add;
        addAudioCheckDefs.value;
        server.sync;
        context = CroneAudioContext.new(server);
        context.out_b = Bus.audio(server, 2);  // keep the check silent
        server.sync;

        // Polls send to Crone.remoteAddr (matron on norns); capture them here
        Crone.remoteAddr = NetAddr.localAddr;
        OSCFunc({ arg msg; pollMessages.add(msg) }, '/poll/value');

        done = Condition(false);
        engine = Engine_Strata.new(context, { done.test = true; done.signal });
        awaitReply.(done, 30);
        server.sync;
        "compiled and allocated Engine_Strata".postln;
        check.(engine.scratchDir == (Platform.userHomeDir +/+ "dust/audio/strata/scratch/"),
            "scratch takes default to ~/dust/audio/strata/scratch/");
        // never write into ~/dust from the check; a nested dir also tests mkdir on demand
        engine.scratchDir = scratchRoot +/+ "nested/scratch/";
        engine.bufferStatePoll.start;
        engine.bufferLoadFailedPoll.start;

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
        // control, independent of whatever release the gate envelope is in
        (voiceDefs ++ grainDefs).do({ arg name;
            check.(controlTriggersFreeingEnvGen.(name, \kill), "% has a kill fade (kill triggers a freeing EnvGen)".format(name));
        });
        (voiceDefs ++ grainDefs).do({ arg name;
            check.(velocityOnlyScalesAccents.(name),
                "% uses velocity only as its accent's levelScale (no bare velocity multiplier)".format(name));
        });
        checkKarplusMutants.value;
        grainDefs.do({ arg name;
            [\grainMode, \t_trig, \velocity, \bend, \envBuf].do({ arg control;
                check.(SynthDescLib.global.at(name).controlNames.collect(_.asSymbol).includes(control),
                    "% has a % control".format(name, control));
            });
        });
        [\accentAmt, \mirrorOut, \mirrorLevel].do({ arg control;
            check.(SynthDescLib.global.at(\strataGrain).controlNames.collect(_.asSymbol).includes(control),
                "strataGrain has a % control (input-source accent and mirror)".format(control));
        });
        // mirrorOut defaults to bus 0, so a mirror is off unless the engine
        // turns it on: mirrorLevel defaults to 0 in both grain SynthDefs
        grainDefs.do({ arg name;
            check.(controlDefault.(name, \mirrorLevel) == 0, "% has mirrorLevel, default 0 (got %)".format(name, controlDefault.(name, \mirrorLevel)));
        });
        // Amplitude crossmod for input-sourced voices, off (modLevel 0) by default
        [\modBus1, \modBus2, \modBus3, \modAmpAmt1, \modAmpAmt2, \modAmpAmt3, \modLevel].do({ arg control;
            check.(controlFeedsAUGen.(\strataGrain, control), "strataGrain has a % control that reaches a UGen".format(control));
        });
        check.(controlDefault.(\strataGrain, \modLevel) == 0, "strataGrain's modLevel defaults to 0 (crossmod off)");
        check.(SynthDescLib.global.at(\strataGrain).controlNames.collect(_.asSymbol).includes(\modFreqAmt1).not,
            "strataGrain has no frequency crossmod (meaningless for live input)");
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
        // sources and nothing is doubled
        grainInUGens = SynthDescLib.global.at(\strataGrain).def.children;
        check.(grainInUGens.count({ arg ugen; ugen.isKindOf(GrainIn) }) == 2
            and: { grainInUGens.select({ arg ugen; ugen.isKindOf(GrainIn) }).every({ arg ugen; ugen.channels.size == 1 }) },
            "strataGrain runs two mono GrainIns (L/R; got %)".format(grainInUGens.count({ arg ugen; ugen.isKindOf(GrainIn) })));
        check.(grainInUGens.count({ arg ugen; ugen.isKindOf(PitchShift) }) == 2,
            "strataGrain pitch-shifts the stereo pair once (two mono PitchShifts; got %)".format(
                grainInUGens.count({ arg ugen; ugen.isKindOf(PitchShift) })));
        check.(grainInUGens.any({ arg ugen; ugen.isKindOf(Balance2) }), "strataGrain pans with Balance2");
        checkGrainMemorySizes.value;
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
        check.(engine.grainSource == Array.fill(engine.numVoices, 0), "every voice starts on its synth source");
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
        engine.numVoices.do({ arg voice;
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
        checkModSlots.(1);

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
            awaitReply.(condition);
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
        check.(names.size == (((engine.numVoices - 1) * 3) + 2 + 1 + 4),
            "xg holds % voice trios, 1 buffer voice (grain + mod), the input synth, filter, delay, reverb and master (got %)".format(
                engine.numVoices - 1, names.size));
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
        checkResonatorCeiling.value;
        checkResonatorLevel.value;
        checkEffectsGuard.value;
        checkModGuard.value;
        checkEffectSendsReported.value;
        check.(synthNames.(context.og).includes(\strataMaster).not, "master is not placed after og (M5)");

        // retrigger never creates nodes (C3)
        before = synthNames.(context.xg).size;
        50.do({ arg count; command.(\retrigger, count % engine.numVoices, 1.0) });
        server.sync;
        after = synthNames.(context.xg).size;
        check.(before == after, "50 retriggers create no nodes (% before, % after)".format(before, after));

        // ---- Audio sources: replace, never stack ----
        check.(grainsBeforeOwnMods.value, "every voice's grain synths run before its mod synth (mirror reaches strataMod)");
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
        check.(getControl.(grainBuf, \mirrorLevel) == 1, "the engine turns strataGrainBuf's mirror on (mirrorLevel 1)");
        check.(grainsBeforeOwnMods.value, "a replacement grain synth still runs before its voice's mod synth");
        after = synthNames.(context.xg).size;
        command.(\setGrainSource, 0, 3); server.sync;
        check.(engine.synths[\grain0] === grainBuf and: { synthNames.(context.xg).size == after },
            "setGrainSource with the current source changes nothing");
        command.(\retrigger, 0, 0.5); server.sync;
        check.(getControl.(grainBuf, \velocity) == 0.5, "retrigger carries velocity to strataGrainBuf (for its accent)");
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
            "input source mirrors into the voice bus (so its mod synth keeps feeding crossmod)");
        check.(getControl.(engine.synths[\grain0], \accentAmt) == 1, "input source carries the accent (accentAmt 1: no voice synth accents it)");
        check.(getControl.(engine.synths[\grain0], \amp).equalWithPrecision(0.3), "the voice's amp sets the input grain level");
        check.(getControl.(engine.synths[\grain0], \pitchShift) == 2.0, "grain controls carry over to the input source");
        command.(\retrigger, 0, 0.75); server.sync;
        check.(getControl.(engine.synths[\grain0], \velocity) == 0.75, "retrigger carries velocity to the input grain synth");
        // amplitude crossmod reaches an input-sourced voice through its grain synth
        check.(getControl.(engine.synths[\grain0], \modLevel) == 1, "input source: crossmod on (modLevel 1)");
        check.(getControl.(engine.synths[\grain0], \modBus1) == engine.modBuses[2].index
            and: { getControl.(engine.synths[\grain0], \modAmpAmt1) == 0.5 },
            "input source: the grain synth reads its routed mod bus with the slot's amp amount");
        command.(\setModAmpAmt, 0, 2, 0.75); server.sync;
        check.(getControl.(engine.synths[\grain0], \modAmpAmt2) == 0.75, "setModAmpAmt reaches an input-sourced voice's grain synth");
        command.(\setModAmpAmt, 0, 2, 0.0);
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
        check.(getControl.(engine.synths[\grain0], \modLevel) == 0,
            "synth source: the grain synth's crossmod is off (the voice synth applies it)");
        check.([\modBus1, \modBus2, \modBus3].every({ arg control; getControl.(engine.synths[\grain0], control) == silentIndex }),
            "synth source: the grain synth's mod buses are the silent bus, never control bus 0");
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
        command.(\recordBuffer, 2, 0.3, 1.0); 0.15.wait; server.sync;   // starts after the fade and the zeroing syncs
        check.(synthNames.(engine.voiceGroup).includes(\strataRecord), "recordBuffer runs a record synth");
        0.5.wait; server.sync;
        check.(engine.bufferFrames[2] == (0.3 * server.sampleRate).round.asInteger, "recordBuffer sets the valid length");
        check.(getControl.(engine.synths[\grain1], \bufFrames) == engine.bufferFrames[2],
            "a voice reading the slot gets the new valid length");
        check.(synthNames.(context.xg).size == before, "recording into a slot a voice is reading adds no lasting nodes");
        check.(waitFor.({ bufferStateSeen.(2, 0.3) }), "the bufferState poll reports the recorded seconds");
        check.(bufferStateMessages.value.notEmpty and: { bufferStateMessages.value.every({ arg msg; msg[2].isKindOf(Float) }) },
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
        command.(\recordBuffer, 3, 1.0, 1.0); 0.15.wait; server.sync;   // a voice reads slot 4: after the fade
        check.(synthNames.(context.xg).includes(\strataRecord), "a 1 s recording is running");
        command.(\clearBuffer, 3); 0.5.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.bufferFrames[3] == 0 },
            "clearBuffer stops a recording in progress");
        // canceled before the record synth could start (still waiting for its zeroed buffers)
        command.(\recordBuffer, 3, 0.2, 1.0);
        command.(\clearBuffer, 3);
        0.5.wait; server.sync;
        check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.bufferFrames[3] == 0 }
            and: { engine.recordSynths[3].isNil }, "a recording canceled before it starts never runs");
        check.(File.exists(engine.scratchDir +/+ "buf4.wav").not, "a canceled recording writes no scratch take");

        // stopRecord ends a recording early, keeping what was captured
        File.delete(engine.scratchDir +/+ "buf4.wav");
        before = synthNames.(context.xg).size;
        command.(\stopRecord, 3); 0.1.wait; server.sync;
        check.(synthNames.(context.xg).size == before and: { engine.bufferFrames[3] == 0 }
            and: { File.exists(engine.scratchDir +/+ "buf4.wav").not }, "stopRecord on an idle slot is a no-op");
        command.(\recordBuffer, 3, 1.0, 1.0); 0.15.wait; server.sync;   // a voice reads slot 4: after the fade
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
        // stopRecord then clearBuffer before the frame count arrives: the
        // clear wins (slotChanges), nothing is restored and nothing written
        File.delete(scratchFile);
        command.(\recordBuffer, 3, 1.0, 1.0); 0.15.wait; server.sync;   // a voice reads slot 4: after the fade
        0.15.wait;
        check.(engine.recordSynths[3].notNil, "a recording runs before stopRecord + clearBuffer");
        command.(\stopRecord, 3);
        command.(\clearBuffer, 3);
        1.0.wait; server.sync;
        check.(engine.bufferFrames[3] == 0, "a clear right after stopRecord leaves the slot empty (got % frames)".format(engine.bufferFrames[3]));
        check.(File.exists(scratchFile).not, "a clear right after stopRecord writes no scratch take");

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
        command.(\loadBuffer, 4, stereoPath);
        check.(engine.bufferFrames[4] == 0, "loadBuffer empties the slot (the voices reading it fade) until the file has been read");
        0.3.wait; server.sync;
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
        checkLoadFailureReports.(textPath, stereoPath);
        checkDecodeShortfall.(stereoPath, longPath);
        checkReadFailureMatching.(stereoPath, monoPath);
        checkBadLoadsDuringRecording.(textPath, stereoPath);
        command.(\loadBuffer, 5, monoPath); 0.3.wait; server.sync;
        check.((bufferSample.(engine.buffersL[5], 10) - 0.4).abs < 0.001
            and: { (bufferSample.(engine.buffersR[5], 10) - 0.4).abs < 0.001 }, "a mono file fills both channels");
        // a clear right after a load wins: the load's completion changes nothing
        command.(\loadBuffer, 5, stereoPath);
        command.(\clearBuffer, 5);
        0.5.wait; server.sync;
        check.(engine.bufferFrames[5] == 0, "a clear right after loadBuffer leaves the slot empty (got % frames)".format(engine.bufferFrames[5]));
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
        checkLoudSave.value;
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
        info = tempFloatFiles.value - tempFilesBefore;
        check.(info.isEmpty, "no temporary float files are left behind (new: %)".format(info.asArray));

        // A 16 s take at the server rate: the interleave finishes, every
        // sample is in place (left ramp, right its negative) and the time is reported
        rampValue = { arg frame; ((frame % 1000) / 1000 - 0.5) * 0.8 };
        longWritePath = scratchRoot +/+ "long-server-rate.wav";
        frames = (server.sampleRate * 16).asInteger;
        file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(server.sampleRate);
        file.openWrite(longWritePath);
        file.writeData(FloatArray.fill(frames * 2, { arg i; var value = rampValue.(i div: 2); if (i.odd) { value.neg } { value } }));
        file.close;
        info = pollMessages.size;   // slot 8 reported 716 before (16 s at 22.05 kHz): only later reports count
        command.(\loadBuffer, 7, longWritePath); 1.0.wait; server.sync;
        check.(engine.bufferFrames[7] == frames, "a 16 s file at the server rate fills slot 8");
        check.(waitFor.({ pollMessages.copyToEnd(info).any({ arg msg; msg[2] == 716 }) }),
            "slot 8 holding 16 s reports 716 through bufferState (the encoding's maximum)");
        savePath = scratchRoot +/+ "long/saved.wav";
        writeStart = Main.elapsedTime;
        command.(\saveBuffer, 7, savePath);
        info = waitFor.({ File.exists(savePath) }, 30);
        writeSeconds = Main.elapsedTime - writeStart;
        check.(info, "a 16 s write completes (% frames at % Hz in % s)".format(frames, server.sampleRate, writeSeconds.round(0.01)));
        file = SoundFile.openRead(savePath);
        check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == frames }, "the 16 s file holds every frame");
        if (file.notNil) {
            data = FloatArray.newClear(frames * 2);
            file.readData(data);
            file.close;
            check.(((0, 997 .. frames - 1) ++ [8191, 8192, 8193, 16383, 16384, frames - 1]).every({ arg frame;
                    ((data[frame * 2] - rampValue.(frame)).abs < 0.001) and: { (data[(frame * 2) + 1] + rampValue.(frame)).abs < 0.001 } }),
                "the 16 s file interleaves every frame in place (chunk boundaries included)");
        };
        File.delete(longWritePath);

        // A write that fails (its directory cannot be made: the parent is a
        // file) forgets its generation and leaves no temporary files
        savePath = textPath +/+ "sub/cannot.wav";
        tempFilesBefore = tempFloatFiles.value;
        command.(\saveBuffer, 4, savePath); 1.0.wait;
        check.(engine.respondsTo(\writeGenerations) and: { engine.writeGenerations[savePath.standardizePath].isNil },
            "a failed newest write removes its writeGenerations entry");
        info = tempFloatFiles.value - tempFilesBefore;
        check.(info.isEmpty, "a failed write leaves no temporary float files (new: %)".format(info.asArray));
        checkStaleParts.value;
        file = Engine_Strata.findMethod(\alloc);
        data = File.readAllString(file.filenameSymbol.asString);
        data = data.copyRange(file.charPos, data.find("\n    }", offset: file.charPos) ? (data.size - 1));
        check.(data.contains("this.deleteStaleParts"), "alloc calls deleteStaleParts");
        // A scratchDir with no directory part has no parent to clean: the
        // working directory's .part files are left alone
        info = [engine.scratchDir, File.getcwd +/+ ("strata-engine-check-" ++ Date.getDate.stamp ++ ".part")];
        File.use(info[1], "w", { arg text; text.write("not stale") });
        engine.scratchDir = "strata-engine-check-relative/";
        engine.tryPerform(\deleteStaleParts);
        check.(File.exists(info[1]), "deleteStaleParts with a relative scratchDir leaves the working directory (%) alone".format(File.getcwd));
        File.delete(info[1]);
        engine.scratchDir = info[0];
        // Only absolute directories below the root are cleaned: an empty,
        // relative or root scratchDir never globs the working directory or /
        savePath = engine.scratchDir;
        info = [["", []], ["/", []], [".", []], ["./", []], ["x/", []], ["//", []],
            ["/a/", ["/a"]], ["/a/b/", ["/a/b", "/a"]]].reject({ arg pair;
            engine.scratchDir = pair[0];
            engine.tryPerform(\stalePartDirs) == pair[1]
        });
        check.(info.isEmpty, "deleteStaleParts cleans only absolute directories below / (wrong for %)".format(info));
        engine.scratchDir = savePath;

        command.(\saveBuffer, 6, scratchRoot +/+ "empty.wav"); 0.5.wait;
        check.(File.exists(scratchRoot +/+ "empty.wav").not, "saving an empty slot writes nothing");
        check.(synthNames.(context.xg).size == before, "saving adds no nodes");

        // A file's sample rate becomes the slot's rate scale; recording restores the server rate.
        // Voice 7 (engine voice 6) reads slot 4 (index 3).
        command.(\loadBuffer, 3, stereoPath); 0.3.wait; server.sync;
        check.(getControl.(engine.synths[\grain6], \bufRateScale).equalWithPrecision(22050 / server.sampleRate)
            and: { getControl.(engine.synths[\grain6], \bufFrames) == 11025 },
            "a voice reading a loaded slot plays it at the file's rate");
        checkFilePitch.value;
        command.(\recordBuffer, 3, 0.1, 1.0); 0.4.wait; server.sync;
        check.(getControl.(engine.synths[\grain6], \bufRateScale) == 1, "recording resets the slot to the server's rate");

        command.(\clearBuffer, 2); 0.2.wait; server.sync;   // after the fade (a voice reads the slot)
        check.(engine.bufferFrames[2] == 0, "clearBuffer resets it");
        check.(getControl.(engine.synths[\grain1], \bufFrames) == 0, "clearBuffer reaches a voice reading the slot");
        check.(bufferSample.(engine.buffersL[2], 10) == 0, "clearBuffer zeroes the slot");
        command.(\setGrainSource, 1, 0);
        2.5.wait; server.sync;

        // A voice reading a slot that is being recorded stays silent until
        // the take completes, instead of looping the take's first grain.
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
            awaitReply.(condition);
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
        checkBufferFades.(stereoPath, monoPath, longPath);
        command.(\clearBuffer, 2);
        command.(\setGrainSource, 1, 0);
        2.5.wait; server.sync;

        // Triggered grain mode on a running synth voice (voice 0, its
        // resonator long past its attack): no grain and no position-spread
        // sound without a trigger, one grain after a retrigger. Its grain
        // synth writes to a private bus for the measurement.
        triggeredBus = Bus.audio(server, 2);
        peakBus = Bus.control(server, 1);
        engine.synths[\grain0].set(\out, triggeredBus.index);
        probe = Synth(\strataCheckPeak, [\in, triggeredBus, \out, peakBus], engine.processGroup, \addToTail);
        server.sync;
        0.1.wait;                                  // let the grains reach the private bus
        continuousPeak = readPeak.value;
        check.(continuousPeak > 0.01, "a running synth voice's continuous grains sound (peak %)".format(continuousPeak));
        command.(\setGrainParam, 0, \grainMode, 1);
        0.5.wait; server.sync;                     // grains in flight and the PitchShift window have ended
        untriggeredPeak = readPeak.value;
        check.(untriggeredPeak < 0.001,
            "a triggered-mode synth voice is silent without a trigger (peak %)".format(untriggeredPeak));
        probe.set(\t_reset, 1); server.sync;
        command.(\retrigger, 0, 1.0);
        0.3.wait;
        triggeredPeak = {
            var condition = Condition(false), value;
            peakBus.get({ arg result; value = result; condition.test = true; condition.signal });
            awaitReply.(condition);
            value
        }.value;
        check.(triggeredPeak > 0.01, "a retrigger fires a grain in triggered mode (peak %)".format(triggeredPeak));
        command.(\setGrainParam, 0, \grainMode, 0);
        engine.synths[\grain0].set(\out, engine.mainBus.index);
        server.sync;
        probe.free; peakBus.free; triggeredBus.free;
        server.sync;
        checkSourceGrains.(1, 2);

        // A burst of source switches (E3 scrolling) keeps at most one
        // releasing grain synth per voice: each switch cuts the one an
        // earlier switch left releasing, and the voice synths it released
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
        // which a second, shorter forced release (gate -1 - time) cannot
        countVoiceAndGrain = {
            var list = synthNames.(context.xg);
            [list.count({ arg name; grainDefs.includes(name) }), list.count({ arg name; voiceDefs.includes(name) })]
        };
        # grainBefore, voiceBefore = countVoiceAndGrain.value;
        maxGrainCount = 0; maxVoiceCount = 0;
        [1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source;
            command.(\setGrainSource, 4, source);
            0.2.wait; server.sync;    // well past switchCutTime (and CI block jitter), so this switch has been processed
            # grainCount, voiceCount = countVoiceAndGrain.value;
            maxGrainCount = max(maxGrainCount, grainCount);
            maxVoiceCount = max(maxVoiceCount, voiceCount);
        });
        check.(maxGrainCount <= (grainBefore + 1),
            "switches 0.2 s apart keep at most the live grain synth and one releasing (at most % grain synths, % before)".format(maxGrainCount, grainBefore));
        check.(maxVoiceCount <= (voiceBefore + 1),
            "switches 0.2 s apart keep at most one releasing voice synth (at most % voice synths, % before)".format(maxVoiceCount, voiceBefore));
        command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "spaced switches leave no extra nodes");
        [1, 2, 0, 9, 0, 3, 4, 0, 5, 6].do({ arg source; command.(\setGrainSource, 4, source); 0.02.wait });
        0.2.wait; server.sync;
        # grainCount, voiceCount = countVoiceAndGrain.value;
        check.((grainCount <= (grainBefore + 1)) and: { voiceCount <= voiceBefore },
            "switches 0.02 s apart end with the live grain synth and one releasing (% grain synths, % voice synths; % and % before)".format(
                grainCount, voiceCount, grainBefore, voiceBefore));
        2.5.wait; server.sync;
        check.(engine.fadingSynths[4].isEmpty and: { engine.releasingSynths[4].isEmpty },
            "after the release nothing a spaced burst released stays tracked");
        command.(\setGrainSource, 4, 0); 2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "the spaced burst leaves no extra nodes");

        // Grain node order holds for any switch history: synth -> buffer ->
        // input -> synth within 1 s, read at once (the buffer grain synth is
        // still in its cut): every grain synth that reads the voice bus runs
        // before every one that mirrors into it, and all before the voice's mod synth
        command.(\setGrainSource, 4, 3); 0.3.wait;
        command.(\setGrainSource, 4, 9); 0.3.wait;
        command.(\setGrainSource, 4, 0); server.sync;   // no wait: the buffer grain synth is in its 50 ms cut
        orderNodes = synthNodes.(engine.processGroup);
        orderGrains = voiceGrainNodes.(orderNodes, 4);
        busReadingAt = orderGrains.select({ arg each; each[1] }).collect(_.first);
        mirroringAt = orderGrains.reject({ arg each; each[1] }).collect(_.first);
        check.(busReadingAt.notEmpty and: { mirroringAt.notEmpty } and: { busReadingAt.maxItem < mirroringAt.minItem },
            "after 0 -> 3 -> 9 -> 0 every bus-reading grain synth runs before every mirroring one (bus-reading at %, mirroring at %)".format(busReadingAt, mirroringAt));
        check.(voiceModPosition.(orderNodes, 4).notNil and: { orderGrains.every({ arg each; each[0] < voiceModPosition.(orderNodes, 4) }) },
            "... and every grain synth of the voice before its mod synth (grains at %, mod at %)".format(
                orderGrains.collect(_.first), voiceModPosition.(orderNodes, 4)));
        check.(grainsBeforeOwnMods.value, "every voice's grain synths still run before its mod synth");
        2.5.wait; server.sync;
        check.(synthNames.(context.xg).size == before, "the 0 -> 3 -> 9 -> 0 switches leave no extra nodes");

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
        // never started
        // (inside makeBundle, sendToSynth's bundle is flattened into the
        // outer one: its /error -1 then silences the rest of that bundle)
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
        check.(grainsBeforeOwnMods.value, "the new mirroring grain synth runs before the re-gated mod synth");
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

        checkSupersededAtStart.(3, before);
        checkStopStartCycles.(3);
        checkInvariantWarnings.(3, before);
        checkQuietNodeSends.(3, before);

        // A re-gated synth whose release ends just as the gate arrives frees
        // anyway; the engine starts that synth again
        oldTrio = voiceTrio.(2);
        server.sendMsg(\n_free, oldTrio[1].nodeID);  // ends without sclang having freed it
        0.2.wait; server.sync;
        after = voiceTrio.(2);
        check.(after[1].notNil and: { after[1] !== oldTrio[1] } and: { after[1].isPlaying }
            and: { synthNames.(context.xg).size == before }, "a running voice's synth that ends unexpectedly is started again");
        checkModSpeedRestart.(2);

        // voiceOff twice, then commands to the stopped voice
        command.(\voiceOff, 4);
        command.(\voiceOff, 4);
        command.(\setVoiceParam, 4, \width, 0.3);
        command.(\retrigger, 4, 0.5);
        command.(\setModSpeed, 4, 2.0);
        check.(engine.synths[\voice4].isNil, "voiceOff forgets the stopped voice's synths");

        checkMemoryWorstCase.value;

        command.(\setMasterDrift, 0.0);
        command.(\setReverb, 1.0, 0.5, 0.5);
        server.sync;

        freeDuringPendingFades.(stereoPath);
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
