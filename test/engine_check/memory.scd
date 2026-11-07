// test/engine_check/memory.scd
// Real-time memory: the grain UGens' fixed sizes, what each grain synth
// takes of the pool, and the worst cases (spaced switches, a burst, fast
// recalls) on norns' 8192 KB pool: 3 MB left on standard, 4 MB on high.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var grainDefs = h.grainDefs;

// The pool's free bytes and its largest free block, from /rtMemoryStatus
var poolFree = {
    var condition = Condition(false), reply;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/rtMemoryStatus.reply', server.addr).oneShot;
    server.sync;
    server.sendMsg('/rtMemoryStatus');
    awaitReply.(condition);
    (reply ? [nil, 0, 0]).copyRange(1, 2)
};
var poolUsedKB = { ((server.options.memSize * 1024) - poolFree.value[0]) / 1024 };

// maxGrains (one grain table per GrainBuf, from the pool) covers the
// largest overlap Lua can ask for: grain size 0.5 s x density 100 x master
// density 2 (a GrainBuf runs at most maxGrains - 1 grains). Every grain
// UGen uses it, never a size from a control.
var checkGrainMemorySizes = {
    var maxGrains = engine.tryPerform(\maxGrains);
    check.(maxGrains.isNumber and: { (maxGrains - 1) >= (0.5 * 100 * 2) } and: { maxGrains < 512 },
        "maxGrains covers the largest grain overlap Lua sends (100) and is below GrainBuf's default 512 (got %)".format(maxGrains));
    grainDefs.do({ arg name;
        var ugens = SynthDescLib.global.at(name).def.children;
        var grainTables = ugens.select({ arg ugen; ugen.isKindOf(GrainIn) or: { ugen.isKindOf(GrainBuf) } })
            .collect({ arg ugen; ugen.inputs.last });
        check.(grainTables.notEmpty and: { grainTables.every({ arg each; each == maxGrains }) },
            "%'s grain UGens use maxGrains (got %)".format(name, grainTables));
    });
};

// What one grain synth of each def takes of the pool: ten of them started
// at once (playing grains, to a private bus), the pool's free bytes before
// and after. Posted, for docs/notes/engine/memory.md.
var checkGrainSynthSizes = {
    var privateBus = Bus.audio(server, 2), group = Group.after(engine.processGroup), count = 10;
    var ring = engine.ringBuffersFor(0, 0), sizes;
    var argsFor = (
        strataGrainRing: [\bufL, ring[0], \bufR, ring[1], \phaseBus, ring[2]],
        strataGrainBuf: [\bufnumL, engine.buffersL[0], \bufnumR, engine.buffersR[0]]
    );
    server.sync;
    sizes = grainDefs.collect({ arg name;
        var before = poolFree.value[0], synths, after;
        synths = count.collect({ Synth(name, [\out, privateBus, \mirrorOut, privateBus, \grainSize, 0.5, \grainDensity, 200]
            ++ argsFor[name], group) });
        server.sync; 0.1.wait;
        after = poolFree.value[0];
        synths.do(_.free); server.sync;
        (before - after) / count / 1024
    });
    grainDefs.do({ arg name, index;
        ("memory: % takes % KB of the pool per synth".format(name, sizes[index].round(0.1))).postln;
    });
    check.(sizes.every({ arg size; (size > 0) and: { size < 64 } }),
        "memory: each grain synth takes under 64 KB of the pool (% KB)".format(
            [grainDefs, sizes.round(0.1)].flop.collect({ arg pair; "% %".format(*pair) }).join(", ")));
    group.free; privateBus.free;
};

// What one probe takes of the pool (its delay line and graph), so the
// worst-case figures below are the engine's own
var probeKB = {
    var bus = Bus.control(server, 1), before, after, probe;
    server.sync;
    before = poolFree.value[0];
    probe = Synth(\strataCheckMemProbe, [\out, bus], engine.processGroup, \addToTail);
    after = poolFree.value[0];
    probe.free; server.sync; bus.free;
    (before - after) / 1024
}.value;

// The worst cases (inside the check routine), on an engine (h.engine or
// the high one): every voice at the largest grain size and density Lua
// sends, switched synth -> buffer -> input -> synth. Spaced: each switch
// processed before the next (0.2 s apart, well past switchCutTime, as E3
// detents arrive), then stopped and started; at the last switch each voice
// holds its live synths, the input grain synth releasing and the buffer
// grain synth in its kill fade. Burst: the three switches at once on every
// voice (a chord of grid scene buttons, or PMAP-mapped source params),
// where each switch frees the synths the previous one left in their kill
// fade, so the voice holds no more. Recalls: scenes A = on/synth, B =
// off/input, C = on/buffer recalled A -> B -> A -> C at once (#46), each
// voice's source sent before its stop or start (the order Lua used before
// #46, the worst one): B builds an input grain synth and releases it, A's
// voiceOn hands it to fadingSynths, and the voice still holds no more than
// its live synths, one fading and one cutting set. Each time, on norns'
// 8192 KB pool (memSize, set before boot), probeCount 256 KB probes (twelve
// on standard: 3 MB, 3.5's second note per voice plus 1 MB; sixteen on
// high: 4 MB; see docs/notes/engine/memory.md) are sent right after the
// last command, with no sync between, inside the 50 ms kill fade; the
// pool's status and the node tree are asked for after them, in the same
// order: the cutting synths must still be there (so the probes measure the
// real peak) and every probe must allocate. run_engine_check.sh also fails
// on any "alloc failed". Returns the engine's own use at each peak (KB).
var checkMemoryWorstCase = { arg target, probeCount, floorLabel;
    var command = { arg name ... args; h.commandTo(target, name, *args) };
    var startVoice = { arg voice; command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 200.0, 1.0) };
    var startAll = { target.numVoices.do(startVoice) };
    var switchAll = { arg sourceOf; target.numVoices.do({ arg voice; command.(\setGrainSource, voice, sourceOf.(voice)) }) };
    var sourceSteps = [{ arg voice; voice + 1 }, { target.numBuffers + 1 }, { 0 }];
    var probeBus = Bus.control(server, probeCount), figures = List.new;
    var probeHeadroom = { arg label;
        var cutting = target.numVoices.collect({ arg voice; target.cuttingSynths[voice].asArray.collect(_.nodeID) }).flatten;
        var probes, statusDone = Condition(false), status, tree, present, values, used;
        probes = probeCount.collect({ arg index;
            Synth(\strataCheckMemProbe, [\out, probeBus.index + index], target.processGroup, \addToTail)
        });
        OSCFunc({ arg msg; status = msg; statusDone.test = true; statusDone.signal }, '/rtMemoryStatus.reply', server.addr).oneShot;
        server.sendMsg('/rtMemoryStatus');
        tree = h.synthTree(target.context.xg);   // answered after the probes and the status
        awaitReply.(statusDone);
        present = tree.count({ arg node; cutting.includes(node.id) });
        server.sync; 0.1.wait;
        values = h.readBus(probeBus);
        used = (((server.options.memSize * 1024) - (status ? [nil, 0])[1]) / 1024) - (probeCount * probeKB);
        figures.add(used.round(1));
        check.((cutting.size > 0) and: { present == cutting.size },
            "memory: the cutting synths are still there when the probes start (%: % of %)".format(label, present, cutting.size));
        check.((values.size == probeCount) and: { values.every({ arg value; value > 0.5 }) },
            "memory: % free at the % worst case: % (the engine uses % KB with its cutting synths)".format(
                floorLabel, target.tier, label, used.round(1)));
        probes.do(_.free);
        probeBus.setAll(0);
        2.5.wait; server.sync;
    };
    probeBus.setAll(0); server.sync;
    startAll.value;
    server.sync; 0.2.wait;
    sourceSteps.do({ arg sourceOf, step;
        if (step > 0) { 0.2.wait; server.sync };
        switchAll.(sourceOf);
    });
    target.numVoices.do({ arg voice; command.(\voiceOff, voice) });
    startAll.value;
    probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted");
    sourceSteps.do({ arg sourceOf; switchAll.(sourceOf) });
    probeHeadroom.("seven voices at grain size 0.5, each switched three times at once");
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, target.numBuffers + 1); command.(\voiceOff, voice) });
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, 0); startVoice.(voice) });
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, voice + 1) });
    probeHeadroom.("seven voices at grain size 0.5, recalled A -> B -> A -> C at once (on/synth, off/input, on/synth, on/buffer)");
    h.stopAllVoices(target);
    probeBus.free;
    figures
};

// The high run (needs the performance setting): the default engine is
// replaced by a high one (one engine alone in the pool), the three worst
// cases run with sixteen probes, and the default engine comes back for the
// areas that follow. 2a adds spectral freeze on every voice to this run.
var checkHighWorstCase = {
    var root = h.tempDir +/+ "memory-high/", high;
    var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    high = h.replaceEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    check.(high.tier == \high, "memory: the high engine runs tier high (got %, % s slots, % s history)".format(
        high.tier, high.bufferSeconds, high.historySeconds));
    checkMemoryWorstCase.(high, 16, "4 MB");
    engine = h.replaceEngine(nil);
    check.(engine.tier == \standard, "memory: the default engine is back for the areas that follow");
};

checkGrainMemorySizes.value;
checkGrainSynthSizes.value;
check.(engine.tier == \standard, "memory: the default engine runs tier standard (idle, it uses % KB of the pool; a probe % KB)".format(
    poolUsedKB.value.round(1), probeKB.round(0.1)));
checkMemoryWorstCase.(engine, 12, "3 MB");
checkHighWorstCase.value;
h.stopAllVoices;
}
