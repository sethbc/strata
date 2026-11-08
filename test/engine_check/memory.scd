// test/engine_check/memory.scd
// Real-time memory: the grain UGens' fixed sizes, what each grain synth
// takes of the pool, and the worst cases (spaced switches, a burst, fast
// recalls) on norns' 8192 KB pool: 3 MB left on standard, 4 MB on high.
//
// Everything is measured with allocation probes, as on SuperCollider 3.13
// (norns' and CI's version, which has no /rtMemoryStatus):
// - the floors: 256 KB DelayN probes (\strataCheckMemProbe) that must all
//   allocate (a failing one would print "alloc failed", which fails the run);
// - the figures: a flood of small graph probes (\strataCheckPoolProbe, about
//   16 KB of controls each) sent in one bundle with /error -1. A probe whose
//   graph does not fit is simply not created (its /s_new fails quietly, with
//   no UGen to print anything), so the number that did, times a probe's
//   size, is the pool's free memory to within one probe. A probe's size is
//   calibrated against four DelayN probes (1 MB) on the running server.
//   Two 256 KB DelayN probes are allocated just before each flood and freed
//   just after it, so the server never runs with a full pool: replies
//   (/c_getn, /n_info) and anything an engine synth allocates meanwhile find
//   room. They count as free.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var grainDefs = h.grainDefs;
var floodCount = 640;   // more small probes than the whole pool holds
var reserveBus = Bus.control(server, 1);

// Send the flood of small probes now (in processGroup, at the tail), with
// error reports off for that bundle. Returns their bus and node IDs; read
// the count with floodResult once the server has answered.
// (A DelayN, and a GrainBuf or Pluck of a synth just started, takes its
// memory when it first runs, in the next block, where a graph takes its
// own at /s_new: so the flood waits a sync and 10 ms, past that block, for
// everything sent before it, the reserve included)
var floodStart = {
    var bus = Bus.control(server, floodCount), ids = floodCount.collect({ server.nextNodeID });
    var reserve = 2.collect({ server.nextNodeID });
    bus.setAll(0);
    server.sendBundle(nil, *reserve.collect({ arg id; ['/s_new', \strataCheckMemProbe, id, 1, engine.processGroup.nodeID,
        \out, reserveBus.index] }));
    server.sync; 0.01.wait;
    server.sendBundle(nil, *([['/error', -1]] ++ ids.collect({ arg id, index;
        ['/s_new', \strataCheckPoolProbe, id, 1, engine.processGroup.nodeID, \out, bus.index + index]
    }) ++ reserve.collect({ arg id; ['/n_free', id] })));
    [bus, ids]
};
// How many of a flood's probes were created; frees them (quietly: the
// ones that were not created do not exist)
var floodResult = { arg flood;
    var values, count;
    server.sync; 0.05.wait;
    values = h.readBus(flood[0]);
    count = values.count({ arg value; value > 0.5 });
    server.sendBundle(nil, ['/error', -1], *flood[1].collect({ arg id; ['/n_free', id] }));
    server.sync;
    flood[0].free;
    count
};
// The number of small probes the pool holds now
var floodFit = { var flood; server.sync; flood = floodStart.value; floodResult.(flood) };
var reserveKB = 2 * 257;   // the two DelayN probes around each flood

// A small probe's size (KB): how many fewer fit beside four 256 KB DelayN
// probes, which take 1024 KB of delay lines (and about 1 KB each of graph)
var smallProbeKB = {
    var bus = Bus.control(server, 4), without, with, probes;
    without = floodFit.value;
    probes = 4.collect({ arg index; Synth(\strataCheckMemProbe, [\out, bus.index + index], engine.processGroup, \addToTail) });
    with = floodFit.value;
    probes.do(_.free); server.sync; bus.free;
    1028 / (without - with).max(1)
};
var probeKB, idleFreeKB;

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

// What one grain synth of each def takes of the pool: the small probes
// that fit with and without twenty of them (playing grains, to a private
// bus), so the figure is within a probe / 20 (under 1 KB)
var checkGrainSynthSizes = {
    var privateBus = Bus.audio(server, 2), group = Group.after(engine.processGroup), count = 20;
    var ring = engine.ringBuffersFor(0, 0), sizes;
    var argsFor = (
        strataGrainRing: [\bufL, ring[0], \bufR, ring[1], \phaseBus, ring[2]],
        strataGrainBuf: [\bufnumL, engine.buffersL[0], \bufnumR, engine.buffersR[0]]
    );
    sizes = grainDefs.collect({ arg name;
        var before = floodFit.value, synths, after;
        synths = count.collect({ Synth(name, [\out, privateBus, \mirrorOut, privateBus, \grainSize, 0.5, \grainDensity, 200]
            ++ argsFor[name], group) });
        server.sync; 0.1.wait;
        after = floodFit.value;
        synths.do(_.free); server.sync;
        (before - after) * probeKB / count
    });
    check.(sizes.every({ arg size; (size > 0) and: { size < 64 } }),
        "memory: each grain synth takes under 64 KB of the pool (% KB, by allocation probes)".format(
            [grainDefs, sizes.round(0.1)].flop.collect({ arg pair; "% %".format(*pair) }).join(", ")));
    group.free; privateBus.free;
};

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
// last command, with no sync between, inside the 50 ms kill fade, then the
// flood of small probes (what is left beyond them) and the node tree, in
// that order: the cutting synths must still be there (so the probes meet
// the real peak) and every 256 KB probe must allocate. run_engine_check.sh
// also fails on any "alloc failed". engage (optional) runs right after each
// scenario's last command, before the probes (the high run's spectral
// freeze). Returns the free KB at each peak.
var checkMemoryWorstCase = { arg target, probeCount, floorLabel, engage;
    var command = { arg name ... args; h.commandTo(target, name, *args) };
    var startVoice = { arg voice; command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 200.0, 1.0) };
    var startAll = { target.numVoices.do(startVoice) };
    var switchAll = { arg sourceOf; target.numVoices.do({ arg voice; command.(\setGrainSource, voice, sourceOf.(voice)) }) };
    var sourceSteps = [{ arg voice; voice + 1 }, { target.numBuffers + 1 }, { 0 }];
    var probeBus = Bus.control(server, probeCount), figures = List.new;
    var probeHeadroom = { arg label;
        var cutting = target.numVoices.collect({ arg voice; target.cuttingSynths[voice].asArray.collect(_.nodeID) }).flatten;
        var probes, flood, infos = IdentitySet.new, watcher, present, values, freeKB;
        probes = probeCount.collect({ arg index;
            Synth(\strataCheckMemProbe, [\out, probeBus.index + index], target.processGroup, \addToTail)
        });
        flood = floodStart.value;
        // which cutting synths still exist, asked right after: /n_query
        // answers /n_info for each one there and (errors off) nothing for one gone
        watcher = OSCFunc({ arg msg; infos.add(msg[1]) }, '/n_info', server.addr);
        server.sendBundle(nil, ['/error', -1], *cutting.collect({ arg id; ['/n_query', id] }));
        freeKB = (probeCount * 256) + (floodResult.(flood) * probeKB) + reserveKB;
        watcher.free;
        present = cutting.count({ arg id; infos.includes(id) });
        values = h.readBus(probeBus);
        figures.add(freeKB.round(1));
        check.((cutting.size > 0) and: { present == cutting.size },
            "memory: the cutting synths are still there when the probes start (%: % of %)".format(label, present, cutting.size));
        check.((values.size == probeCount) and: { values.every({ arg value; value > 0.5 }) },
            "memory: % free at the % worst case: % (about % KB free, the engine using about % KB more than idle)".format(
                floorLabel, target.tier, label, freeKB.round(10), (idleFreeKB - freeKB).round(10)));
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
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted");
    sourceSteps.do({ arg sourceOf; switchAll.(sourceOf) });
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, each switched three times at once");
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, target.numBuffers + 1); command.(\voiceOff, voice) });
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, 0); startVoice.(voice) });
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, voice + 1) });
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, recalled A -> B -> A -> C at once (on/synth, off/input, on/synth, on/buffer)");
    h.stopAllVoices(target);
    probeBus.free;
    figures
};

// The high run (needs the performance setting): the default engine is
// replaced by a high one (one engine alone in the pool), the three worst
// cases run with sixteen probes and spectral freeze engaged on every voice
// (a spectral writer per voice reading a ring: the first two scenarios end
// on the synth source; the third ends on the slots, where spectral holds),
// and the default engine comes back for the areas that follow.
// PV_MagFreeze takes its few KB once its first frame is analyzed (about
// 21 ms in): after the probes have allocated, while they are still held,
// so an allocation that did not fit would fail the run ("alloc failed").
var spectralFreezeAll = { arg command;
    engine.numVoices.do({ arg voice;
        command.(\setGrainParam, voice, \freezeMode, 1.0);
        command.(\setGrainParam, voice, \freeze, 1.0);
    });
};
var checkHighWorstCase = {
    var root = h.tempDir +/+ "memory-high/", high, spectral;
    var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    high = h.replaceEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    engine = high;   // the floods go into its processGroup
    check.(high.tier == \high, "memory: the high engine runs tier high (got %, % s slots, % s history)".format(
        high.tier, high.bufferSeconds, high.historySeconds));
    spectral = List.new;
    checkMemoryWorstCase.(high, 16, "4 MB", { arg command;
        spectralFreezeAll.(command);
        spectral.add(high.numVoices.collect({ arg voice; high.ringWriterFor(voice) })
            .count({ arg writer; writer.defName.asSymbol == \strataRingWriteSpectral }));
    });
    check.((spectral[0] == high.numVoices) and: { spectral[1] == high.numVoices },
        "memory: the high run engages spectral freeze on every voice (spectral writers per scenario: %)".format(spectral));
    engine = h.replaceEngine(nil);
    check.(engine.tier == \standard, "memory: the default engine is back for the areas that follow");
};

// The small probe: about 16 KB of graph (240 controls); it writes 1 to its
// bus once created
SynthDef(\strataCheckPoolProbe, { arg out;
    var padding = NamedControl.kr(\padding, 0 ! 240);
    Out.kr(out, DC.kr(1) + (padding[0] * 0));
}).add;
server.sync;

probeKB = smallProbeKB.value;
idleFreeKB = (floodFit.value * probeKB) + reserveKB;
checkGrainMemorySizes.value;
checkGrainSynthSizes.value;
check.(engine.tier == \standard and: { probeKB > 4 } and: { probeKB < 64 },
    "memory: the default engine runs tier standard (idle, about % KB of the pool free; a small probe % KB)".format(
        idleFreeKB.round(10), probeKB.round(0.1)));
checkMemoryWorstCase.(engine, 12, "3 MB");
checkHighWorstCase.value;
h.stopAllVoices;
reserveBus.free;
}
