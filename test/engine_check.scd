// engine_check.scd
// Runtime check of lib/Engine_Strata.sc against the real norns CroneEngine
// and CroneAudioContext classes. Run through test/run_engine_check.sh, which
// sets up the class library. Boots a local scsynth (on UDP port $STRATA_SC_PORT, default 57110); the engine's output is
// routed to a private bus so nothing is audible.
//
// This file is the runner: it boots the server, builds the engine and runs
// the area files test/engine_check/<area>.scd in areaOrder (the areas named
// in $STRATA_ENGINE_CHECK_AREAS, comma- or space-separated, or every area
// file present but the onDemandAreas). Each area file returns a function of the helper Event h
// (below), which holds the shared helpers and the engine. Call a helper as
// a method: h.check(condition, "area: message"), h.command(\voiceOn, ...).
// Each area stops the voices it started (h.stopAllVoices); after it the
// runner checks that no voice, grain or mod synth is left, clears every slot
// so the next area starts from empty slots, and posts the area's time.
(
var server = Server.local;
var failures = 0;
// The fixed order the areas run in; an absent 3.2 file is skipped
var areaOrder = [\structure, \voices, \grains, \lifecycle, \memory, \buffers, \files, \effects, \performance,
    \rings, \freeze, \variation, \loops, \soak];
// Areas that run only when $STRATA_ENGINE_CHECK_AREAS names them, never in
// a full run or a CI shard: the soak (docs/notes/engine/files.md, #131)
var onDemandAreas = [\soak];
var testDir = thisProcess.nowExecutingPath.dirname;
var areaPath = { arg name; testDir +/+ "engine_check" +/+ (name.asString ++ ".scd") };
var areasText = "STRATA_ENGINE_CHECK_AREAS".getenv ? "";
var requested = areasText.split($,).collect({ arg part; part.split($ ) }).flatten
    .collect({ arg name; name.select({ arg char; char.isSpace.not }) }).reject(_.isEmpty).collect(_.asSymbol);
var missingAreas = requested.reject({ arg name; areaOrder.includes(name) and: { File.exists(areaPath.(name)) } });
var areas = if (missingAreas.notEmpty) {
    ("ENGINE CHECK FAILED: no area " ++ missingAreas[0]).postln;
    1.exit;
} {
    areaOrder.select({ arg name; File.exists(areaPath.(name))
        and: { if (requested.isEmpty) { onDemandAreas.includes(name).not } { requested.includes(name) } } })
};
// The run's own deadline (s): run_engine_check.sh passes 30 s less than its
// timeout ($ENGINE_CHECK_TIMEOUT, 570 by default), so a long soak can be given more
var deadline = { var given = ("STRATA_ENGINE_CHECK_DEADLINE".getenv ? "").asInteger; if (given > 0) { given } { 540 } }.value;
var context, engine, h;
var voiceDefs = [\strataResonator, \strataFM, \strataFolder, \strataSub,
    \strataPulse, \strataKarplus, \strataRing];
var allDefs = voiceDefs ++ [\strataMod, \strataGrainRing, \strataGrainBuf, \strataInput, \strataRecord, \strataRingWrite,
    \strataFilter, \strataDelay, \strataReverb, \strataMaster];
var grainDefs = [\strataGrainRing, \strataGrainBuf];
var engineVoiceDefs = voiceDefs ++ grainDefs ++ [\strataMod];
// Every /poll/value message the run receives, and each poll's values as
// they arrive, by poll index (a List each): the helpers read one poll's
// values instead of scanning every message, which grow all run long. Each
// List is made with room for pollListCapacity entries, so it never grows
// while the run receives messages: on sclang 3.13 a List that grows past
// 128 entries (its Array then becomes a big object) inside an OSC handler
// while a long save allocates corrupted the collector (a count assertion), every
// time, once about 128 polls had arrived (the 300 s soak's tenth round,
// #131). The end of the run checks that none outgrew it.
var pollListCapacity = 16384;
var pollMessages = List.new(pollListCapacity);
var pollValueLists = IdentityDictionary.new(16);
// scsynth's UDP port: STRATA_SC_PORT (default 57110), so checks in different
// worktrees can run side by side on one machine
var scPortText = "STRATA_SC_PORT".getenv;
var scPort = if(scPortText.isNil or: { scPortText.size == 0 }, 57110, {
    // asInteger turns "abc" into 0, so accept digits only
    if(scPortText.every({ arg char; char.isDecDigit }).not or: { scPortText.asInteger.inclusivelyBetween(1, 65535).not }) {
        ("ENGINE CHECK FAILED: STRATA_SC_PORT must be a port number from 1 to 65535, got \"" ++ scPortText ++ "\"").postln;
        1.exit;
    };
    scPortText.asInteger
});
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

// Each engine's commands, taken when it is built: engine -> name ->
// [the function matron's OSC would call, its path]. A second engine on the
// same server (startEngine) re-registers the same OSCdefs, which would
// otherwise run its commands for the first one.
var engineCommands = IdentityDictionary.new;
var takeCommands = { arg target;
    var table = IdentityDictionary.new;
    target.commands.do({ arg cmd; table[cmd.name] = [cmd.oscdef.func, ("/command/" ++ cmd.name).asSymbol] });
    engineCommands[target] = table;
};

// Invoke a registered engine command exactly as matron's OSC would.
var commandTo = { arg target, name ... args;
    var entry = engineCommands[target] !? { arg table; table[name] };
    if (entry.isNil) { Error("no command " ++ name).throw };
    entry[0].value([entry[1]] ++ args);
};
var command = { arg name ... args; commandTo.(engine, name, *args) };

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

// Wait (inside the check routine) until condition is true or timeout passes
var waitFor = { arg condition, timeout = 3;
    var elapsed = 0;
    while { condition.value.not and: { elapsed < timeout } } { 0.05.wait; elapsed = elapsed + 0.05 };
    condition.value
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

// A voice's synths as the engine tracks them: [voice synth, grain synth, mod synth]
var voiceTrio = { arg voice;
    [engine.voiceKey(voice), engine.grainKey(voice), engine.modKey(voice)].collect({ arg key; engine.synths[key] })
};

// Test sound built from C primitives, never a sclang function per sample:
// on sclang 3.13 (norns' version, CI's) millions of small calls pile up
// garbage-collector work until it fails (#131; docs/notes/engine/files.md).
// A Signal of `size` samples repeating `values`, an Array (putEach wraps
// its values; it reads keys and values as Arrays, so never pass it a
// FloatArray or Signal)
var repeating = { arg size, values;
    if (size < 1) { Signal.new } { Signal.newClear(size).putEach((0 .. size - 1), values) }
};
// A stereo FloatArray of two mono channels of one size (Signals or Arrays):
// at with an index Array returns an Array, which putEach takes
var stereoOf = { arg left, right;
    var size = left.size, frames = (0 .. size - 1), stereo = FloatArray.newClear(size * 2);
    if (size > 0) {
        stereo.putEach((0, 2 .. (size * 2) - 2), left.at(frames));
        stereo.putEach((1, 3 .. (size * 2) - 1), right.at(frames));
    };
    stereo
};
// A Signal of `size` samples counting 0, 1, 2, ... (Signal arithmetic
// scales it: rampSignal.(n) / n rises from 0 toward 1)
var rampSignal = { arg size;
    var steps = (0 .. size - 1);
    Signal.newClear(size).putEach(steps, steps)
};
// `frames` frames from startFrame of a mono signal that repeats `period`
// (an Array of one period's samples, built once with a function per sample)
var periodic = { arg period, startFrame, frames;
    repeating.(frames, period.rotate((startFrame % period.size).neg))
};
// A Signal of `size` samples of noise up to ±level: 4801 random values
// (a period longer than a FLAC block) repeated
var noise = { arg size, level; repeating.(size, Array.fill(4801, { level.rand2 })) };
// Write `frames` frames of `values` (an Array: one constant per channel)
// to an open SoundFile, at most 65536 frames at a time
var writeConstantFrames = { arg file, frames, values;
    var left = frames;
    while { left > 0 } {
        file.writeData(repeating.(left.min(65536) * values.size, values));
        left = left - 65536;
    };
};

// An open sound file compared in every sample with the file at `path`
// (a saved int16 file against the int16 source it was loaded from: the
// samples come back exactly). Both are read 65536 frames at a time, each
// chunk into a fresh Signal, and compared with Signal arithmetic (-, peak:
// C primitives, no Array of slots for the collector to scan). Returns [the
// largest difference (1 where the chunks differ in size), the frames compared].
var sameFrames = { arg file, path;
    var other = SoundFile.openRead(path), deviation = 0, frames = 0, ours, theirs;
    if (other.isNil) { [1, 0] } {
        while { ours = Signal.newClear(65536 * file.numChannels); file.readData(ours); ours.size > 0 } {
            theirs = Signal.newClear(65536 * other.numChannels);
            other.readData(theirs);
            deviation = deviation.max(if (theirs.size == ours.size) { (ours - theirs).peak } { 1 });
            frames = frames + (ours.size div: file.numChannels);
        };
        other.close;
        [deviation, frames]
    }
};

// Write `seconds` seconds at `rate` of a stereo signal to an open SoundFile,
// a second at a time: left repeating `period` (an Array, as periodic takes),
// right its negative. When a second holds whole periods (a 1000-frame period
// at 48 kHz) every second is the same, so one is built and written each
// time: a long file then allocates one second's arrays, not every second's
var writePeriodicSeconds = { arg file, period, seconds, rate;
    var build = { arg second; var left = periodic.(period, second * rate, rate); stereoOf.(left, left.neg) };
    var same = if ((rate % period.size) == 0) { build.(0) };
    seconds.do({ arg second; file.writeData(same ?? { build.(second) }) });
};

// Write a test sound file of constant per-channel values
var writeTestFile = { arg path, sampleRate, frames, values;
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16")
        .numChannels_(values.size).sampleRate_(sampleRate);
    file.openWrite(path);
    writeConstantFrames.(file, frames, values);
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

// A control bus's first value (inside the check routine)
var readBusValue = { arg bus;
    var condition = Condition(false), value;
    bus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
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

// true when n real-time memory probes of 256 KB (\strataCheckMemProbe), all
// started at once, allocate: the pool still has n * 256 KB free (in blocks
// of 256 KB). The probe bus is zeroed first, so a probe whose /s_new fails
// reads 0.
var probeFree = { arg count;
    var probeBus = Bus.control(server, count), probes, values;
    probeBus.setAll(0); server.sync;
    probes = count.collect({ arg index;
        Synth(\strataCheckMemProbe, [\out, probeBus.index + index], engine.processGroup, \addToTail)
    });
    server.sync; 0.1.wait;
    values = readBus.(probeBus);
    probes.do(_.free);
    server.sync;
    probeBus.free;
    (values.size == count) and: { values.every({ arg value; value > 0.5 }) }
};

// Build an engine in a context and wait for its alloc. settings: an Event
// of Engine_Strata classvars (settingsDir, modelPath, meminfoPath) set for
// this build only (the previous values come back once it is built). A
// settingsDir or modelPath left out is a fresh folder below the check's temp
// dir and a model file that does not exist, so the performance area never
// reads or writes ~/dust and decides auto on an unknown board: standard.
var settingsBuilds = 0;
var buildEngine = { arg target, settings;
    // saved: [key, previous value] pairs (a Dictionary would drop a nil value)
    var done = Condition(false), built, saved = List.new;
    settings = (settings ? ()).copy;
    settingsBuilds = settingsBuilds + 1;
    if (settings[\settingsDir].isNil) { settings[\settingsDir] = scratchRoot +/+ ("settings" ++ settingsBuilds ++ "/") };
    if (settings[\modelPath].isNil) { settings[\modelPath] = scratchRoot +/+ "no-board-model" };
    settings.keysValuesDo({ arg key, value;
        var setter = (key.asString ++ "_").asSymbol;
        if (Engine_Strata.respondsTo(setter).not) { Error("Engine_Strata has no classvar " ++ key).throw };
        saved.add([key, Engine_Strata.perform(key)]);
        Engine_Strata.perform(setter, value);
    });
    built = Engine_Strata.new(target, { done.test = true; done.signal });
    awaitReply.(done, 30);
    server.sync;
    saved.do({ arg pair; Engine_Strata.perform((pair[0].asString ++ "_").asSymbol, pair[1]) });
    takeCommands.(built);
    built
};

// A second engine instance on the same server, in a context of its own
// (silent, freed at the end of the run), writing below the check's temp
// dir. Its polls are the first engine's (CronePollRegistry keeps one poll
// per name), so its reports arrive as that engine's. Drive it with
// h.commandTo(engine, \name, ...) and free it with h.freeEngine(engine).
var extraContexts = List.new;
var startEngine = { arg settings;
    var target = CroneAudioContext.new(server), built;
    target.out_b = Bus.audio(server, 2);  // keep it silent
    server.sync;
    extraContexts.add(target);
    built = buildEngine.(target, settings);
    built.scratchDir = scratchRoot +/+ ("engine" ++ extraContexts.size) +/+ "scratch/";
    built
};

// Free an engine (once). Freeing another engine than h.engine gives the
// OSCdefs back to h.engine's commands.
var freedEngines = IdentitySet.new;
var freeEngine = { arg target;
    if (freedEngines.includes(target).not) { freedEngines.add(target); target.free };
    if (target !== engine and: { freedEngines.includes(engine).not }) {
        engineCommands[engine].keysValuesDo({ arg name, entry; OSCdef(name, entry[0], entry[1]) });
    };
};

// The voice, grain and mod synths running in an engine's context
var voiceNodesLeft = { arg target;
    synthNames.(target.context.xg).select({ arg name; engineVoiceDefs.includes(name) })
};

// Stop every voice of an engine (h.engine by default) and put it back on its
// synth source, then cut what still releases or fades (a mod synth, which
// has no kill fade, is freed) and wait until none of its voice, grain or
// mod synths is left. Each area ends with this.
var stopAllVoices = { arg target;
    target = target ? engine;
    target.numVoices.do({ arg voice;
        commandTo.(target, \voiceOff, voice);
        commandTo.(target, \setGrainSource, voice, 0);
    });
    server.sync;
    target.numVoices.do({ arg voice;
        (target.releasingSynths[voice].values.asArray ++ target.fadingSynths[voice].asArray
            ++ target.cuttingSynths[voice].asArray).do({ arg synth;
            if (synth.isPlaying) {
                if (synth.defName.asSymbol == \strataMod) { target.sendToSynth(synth.freeMsg) } { target.cutSynth(synth) };
            };
        });
    });
    waitFor.({ voiceNodesLeft.(target).isEmpty }, 3);
};

// Every voice started as the engine check always has: voice 7 (engine voice
// 6) on buffer slot 4 (source 4, index 3), the others on their synths, at
// 100 Hz + the voice index, amp 0.2, pan 0, grain size 0.1, density 10,
// pitch 1
var startAllVoices = {
    command.(\setGrainSource, 6, 4);
    server.sync;
    engine.numVoices.do({ arg voice;
        command.(\voiceOn, voice, 100.0 + voice, 0.2, 0.0, 0.1, 10.0, 1.0);
    });
    server.sync;
};

// After each area: nothing of a voice is left running, every slot is empty
var finishArea = { arg name, seconds;
    var left = voiceNodesLeft.(engine), keys = engine.synths.keys.reject({ arg key; engine.effectKeys.includes(key) });
    var message = "%: leaves no voice, grain or mod synth running".format(name);
    if (left.notEmpty or: { keys.notEmpty }) { message = message ++ " (left: %, tracked: %)".format(left, keys) };
    check.(left.isEmpty and: { keys.isEmpty }, message);
    if (left.notEmpty or: { keys.notEmpty }) { stopAllVoices.value };
    engine.numBuffers.do({ arg slot; command.(\clearBuffer, slot) });
    server.sync;
    ("area %: % s".format(name, seconds.round(0.1))).postln;
};

server.addr = NetAddr("127.0.0.1", scPort);
("scsynth port: %".format(scPort)).postln;
("engine check areas: %".format(areas.join(", "))).postln;
server.options.numInputBusChannels = 2;
// norns' real-time memory pool: Crone.sc boots Server.local without setting
// memSize, so scsynth gets the ServerOptions default of 8192 KB. Set it
// explicitly so the worst-case memory check measures norns' budget.
server.options.memSize = 8192;
// Whatever hangs (a server.sync to a server that went away), the check ends:
// a failed run after `deadline` s (540 by default, inside CI's 600 s timeout)
SystemClock.sched(deadline, {
    ("FAIL engine check did not finish within % s".format(deadline)).postln;
    ("ENGINE CHECK FAILED: timed out after % failures".format(failures)).postln;
    server.quit;
    SystemClock.sched(1, { 1.exit });
    nil
});
server.waitForBoot({
    var exitCode, defaultScratchDir, running, workDir = "STRATA_CHECK_TMPDIR".getenv;
    // the server's PID for run_engine_check.sh, which stops this scsynth if
    // it outlives sclang (a crash, #152)
    if (workDir.notNil and: { workDir.size > 0 } and: { server.pid.notNil }) {
        try { File.use(workDir +/+ "scsynth.pid", "w", { arg file; file.write(server.pid.asString ++ "\n") }) };
    };
    try {
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
        // ... the peak of each channel of a stereo bus since the last
        // t_reset; 1 once a NaN or inf (CheckBadValues codes 1 and 2; 3 is a
        // denormal) has reached a stereo bus since the last t_reset; and 50
        // ms of inf (left, a float overflow: log(0) does not give -inf in
        // scsynth) and NaN (right), after which it frees itself
        SynthDef(\strataCheckChannelPeaks, { arg in, out, t_reset = 0;
            Out.kr(out, A2K.kr(Peak.ar(In.ar(in, 2).abs, t_reset)));
        }).add;
        SynthDef(\strataCheckBadValues, { arg in, out, t_reset = 0;
            var codes = CheckBadValues.ar(In.ar(in, 2), 0, 0);
            Out.kr(out, A2K.kr(Peak.ar(((codes > 0.5) * (codes < 2.5)).sum, t_reset)));
        }).add;
        // ... the RMS of a stereo bus over about the last 1.5 s (a 10 s 60 dB lag of the mean square)
        SynthDef(\strataCheckRms, { arg in, out;
            Out.kr(out, A2K.kr(Lag.ar(In.ar(in, 2).squared.sum * 0.5, 10).sqrt));
        }).add;
        SynthDef(\strataCheckBadSource, { arg out, big = 1e30;
            var infinite = DC.ar(big) * big;
            Line.kr(0, 0, 0.05, doneAction: 2);
            Out.ar(out, [infinite, infinite - infinite]);
        }).add;
        server.sync;
        context = CroneAudioContext.new(server);
        context.out_b = Bus.audio(server, 2);  // keep the check silent
        server.sync;

        // Polls send to Crone.remoteAddr (matron on norns); capture them here
        Crone.remoteAddr = NetAddr.localAddr;
        OSCFunc({ arg msg;
            var values = pollValueLists[msg[1]];
            pollMessages.add(msg);
            if (values.isNil) { values = List.new(pollListCapacity); pollValueLists[msg[1]] = values };
            values.add(msg[2]);
        }, '/poll/value');

        engine = buildEngine.(context);
        "compiled and allocated Engine_Strata".postln;
        defaultScratchDir = engine.scratchDir;
        // never write into ~/dust from the check; a nested dir also tests mkdir on demand
        engine.scratchDir = scratchRoot +/+ "nested/scratch/";
        engine.bufferStatePoll.start;
        engine.bufferLoadFailedPoll.start;
        engine.bufferSaveResultPoll.start;

        // Test files every area may load: stereo, mono, too long, not audio
        File.mkdir(scratchRoot);
        writeTestFile.(scratchRoot +/+ "stereo.wav", 22050, 11025, [0.5, -0.25]);
        writeTestFile.(scratchRoot +/+ "mono.wav", 44100, 4410, [0.4]);
        writeTestFile.(scratchRoot +/+ "long.wav", 22050, 22050 * 17, [0.1]);
        File.use(scratchRoot +/+ "not-audio.wav", "w", { arg text; text.write("not a sound file") });

        h = (
            // values
            engine: engine, server: server, context: context, tempDir: scratchRoot, testDir: testDir,
            pollMessages: pollMessages, voiceDefs: voiceDefs, allDefs: allDefs, grainDefs: grainDefs,
            chainDefs: chainDefs, defaultScratchDir: defaultScratchDir,
            stereoPath: scratchRoot +/+ "stereo.wav", monoPath: scratchRoot +/+ "mono.wav",
            longPath: scratchRoot +/+ "long.wav", textPath: scratchRoot +/+ "not-audio.wav",
            // helpers: each takes the Event first (h.check(condition, message))
            check: { arg self, condition, message; check.(condition, message) },
            command: { arg self, name ... args; command.(name, *args) },
            commandTo: { arg self, target, name ... args; commandTo.(target, name, *args) },
            formatOf: { arg self, name; formatOf.(name) },
            awaitReply: { arg self, condition, timeout = 5; awaitReply.(condition, timeout) },
            waitFor: { arg self, condition, timeout = 3; waitFor.(condition, timeout) },
            synthNames: { arg self, group; synthNames.(group) },
            synthTree: { arg self, group; synthNodes.(group) },
            voiceSynths: { arg self, voice; voiceTrio.(voice) },
            controlFeedsAUGen: { arg self, defName, controlName; controlFeedsAUGen.(defName, controlName) },
            // a poll's values so far, oldest first (an Array of just those,
            // copied from its List's room for pollListCapacity)
            pollValues: { arg self, pollName;
                var poll = CronePollRegistry.getPollFromName(pollName);
                var values = poll !? { pollValueLists[poll.index] };
                if (values.isNil or: { values.isEmpty }) { [] } { values.array.copyRange(0, values.size - 1) }
            },
            // true once some value of the poll was within `tolerance` of
            // `target` (exclusive), tested with Signal arithmetic over all of
            // its values: no function per value, however long the run (#131)
            pollValueNear: { arg self, pollName, target, tolerance;
                var poll = CronePollRegistry.getPollFromName(pollName);
                var values = poll !? { pollValueLists[poll.index] }, size = values !? _.size ? 0, signal;
                if (size < 1) { false } {
                    signal = Signal.newClear(size).putEach((0 .. size - 1), values.array);
                    (((signal - target).abs.neg + tolerance).max(0).peak > 0)
                }
            },
            writeTestFile: { arg self, path, sampleRate, frames, values; writeTestFile.(path, sampleRate, frames, values) },
            // test sound from C primitives (#131): see repeating and the helpers after it
            repeating: { arg self, size, values; repeating.(size, values) },
            stereoOf: { arg self, left, right; stereoOf.(left, right) },
            rampSignal: { arg self, size; rampSignal.(size) },
            periodic: { arg self, period, startFrame, frames; periodic.(period, startFrame, frames) },
            noise: { arg self, size, level; noise.(size, level) },
            writePeriodicSeconds: { arg self, file, period, seconds, rate; writePeriodicSeconds.(file, period, seconds, rate) },
            sameFrames: { arg self, file, path; sameFrames.(file, path) },
            writeConstantFrames: { arg self, file, frames, values; writeConstantFrames.(file, frames, values) },
            bufferSample: { arg self, buffer, frame; bufferSample.(buffer, frame) },
            getControl: { arg self, synth, control; getControl.(synth, control) },
            readBusValue: { arg self, bus; readBusValue.(bus) },
            readBus: { arg self, bus; readBus.(bus) },
            measure: { arg self, probe, bus, seconds = 0.3; measure.(probe, bus, seconds) },
            probeFree: { arg self, count; probeFree.(count) },
            startEngine: { arg self, settings; startEngine.(settings) },
            freeEngine: { arg self, target; freeEngine.(target) },
            // Free h.engine and build its replacement in the same context
            // (settings: as startEngine's; nil builds the default engine),
            // for a check that needs one engine alone on the server (the
            // memory area's high run). The areas after it run on the new one.
            replaceEngine: { arg self, settings;
                engine.bufferStatePoll.stop;
                freeEngine.(engine);
                server.sync;
                engine = buildEngine.(context, settings);
                engine.scratchDir = scratchRoot +/+ "nested/scratch/";
                engine.bufferStatePoll.start;
                engine.bufferLoadFailedPoll.start;
                engine.bufferSaveResultPoll.start;
                self[\engine] = engine;
                engine
            },
            stopAllVoices: { arg self, target; stopAllVoices.(target) },
            startAllVoices: { arg self; startAllVoices.value }
        );

        areas.do({ arg name;
            var area = areaPath.(name).load, start = Main.elapsedTime;
            running = name;
            if (area.isKindOf(Function)) {
                area.value(h);
            } {
                check.(false, "%: test/engine_check/%.scd returns the area's function".format(name, name));
            };
            finishArea.(name, Main.elapsedTime - start);
        });
        running = nil;

        engine.bufferStatePoll.stop;
        freeEngine.(engine);
        server.sync;
        check.(synthNames.(context.xg).size == 0, "free removes every node of the engine the areas ran on");
        // a List past its capacity grows inside the OSC handler: raise pollListCapacity
        check.(([pollMessages] ++ pollValueLists.values.asArray).every({ arg list; list.size < pollListCapacity }),
            "the poll lists never grew past pollListCapacity (% messages of %)".format(pollMessages.size, pollListCapacity));
        extraContexts.do({ arg each;
            [each.ig, each.xg, each.og].do(_.free);
            (each.in_b ++ each.amp_in_b ++ each.amp_out_b ++ each.pitch_in_b ++ [each.out_b]).do(_.free);
        });
    } { arg error;
        error.reportError;
        failures = failures + 1;
        "FAIL exception during engine check".postln;
        running !? { ("FAIL (in area %)".format(running)).postln };
    };

    // Delete only the check's own scratch folder: strata-engine-check-<stamp>-<port>
    // directly inside an absolute temp dir (#134)
    if ((scratchRoot.dirname.withoutTrailingSlash == Platform.defaultTempDir.withoutTrailingSlash)
        and: { scratchRoot.beginsWith("/") }
        and: { PathName(scratchRoot).fileName.beginsWith("strata-engine-check-") }) {
        ("rm -rf -- " ++ scratchRoot.shellQuote).systemCmd;
    } { ("strata check: left " ++ scratchRoot ++ " in place (not the check's scratch folder)").postln };
    if (failures == 0) { "ENGINE CHECK PASSED".postln; exitCode = 0 } {
        ("ENGINE CHECK FAILED: % failures".format(failures)).postln; exitCode = 1 };
    server.quit;
    1.wait;
    exitCode.exit;
});
)
