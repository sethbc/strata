// test/engine_check/memory.scd
// Real-time memory: the grain UGens' fixed sizes, what each grain synth
// takes of the pool, and the worst cases (spaced switches, a burst, fast
// recalls, every voice on three buffer slots, the worst cases with one
// recording, eight recordings) on norns' 8192 KB pool: 3 MB left on standard,
// 3.5 MB on high (3 MB on both tiers with eight recordings running).
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
//   Two 64 KB DelayN probes (\strataCheckReserveProbe) are allocated just
//   before each flood and freed just after it (in its bundle), so the server never runs with a full pool: replies
//   (/c_getn, /n_info) and anything an engine synth allocates meanwhile find
//   room (the high run's spectral writers take their last ~16 KB each
//   lazily, about 21 ms in, after the flood: the freed reserve holds it).
//   They count as free. (256 KB each until 2d: with 2b and 2d the high
//   worst case left about 145-165 KB beside sixteen probes (4240-4260 -
//   4096 KB), and about 30-50 KB after the spectral writers' lazy
//   allocations: too little for two 256 KB reserves. 3.3's floor of
//   fourteen probes leaves 512 KB more.)
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
    server.sendBundle(nil, *reserve.collect({ arg id; ['/s_new', \strataCheckReserveProbe, id, 1, engine.processGroup.nodeID,
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
var reserveKB = 2 * 65;   // the two 64 KB DelayN probes around each flood

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
    var ring = engine.ringBuffersFor(0, 0), sizes, sizes32, stageKB;
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
    // (3.2's 69 and 75 KB; 88 KB is 3.3's and 3.4's limit: design Question 1)
    check.(sizes.every({ arg size; (size > 0) and: { size < 88 } }),
        "memory: each grain synth takes under 88 KB of the pool (% KB, by allocation probes)".format(
            [grainDefs, sizes.round(0.1)].flop.collect({ arg pair; "% %".format(*pair) }).join(", ")));
    // ... against check-only copies of 3.2's defs, measured the same way
    sizes32 = [h.def32[\grainRing], h.def32[\grainBuf]].collect({ arg name, index;
        var before = floodFit.value, synths, after;
        var defName = grainDefs[index];
        synths = count.collect({ Synth(name, [\out, privateBus, \mirrorOut, privateBus, \grainSize, 0.5, \grainDensity, 200]
            ++ argsFor[defName] ++ engine.mixBusControls.asKeyValuePairs, group) });
        server.sync; 0.1.wait;
        after = floodFit.value;
        synths.do(_.free); server.sync;
        (before - after) * probeKB / count
    });
    // (the buffer def pays for the head guard: about 8 KB of its 16 KB saving)
    check.((sizes.size == 2) and: { (sizes[0] - sizes32[0]) <= -12 } and: { (sizes[1] - sizes32[1]) <= -6 },
        "memory: each grain synth is under 3.2's (at least 12 KB for the ring, 6 KB for the buffer def with its head guard) (% KB now, % KB 3.2's copies)".format(sizes.round(0.1), sizes32.round(0.1)));
    // the stage's size (design 3.3 §0c.6; it fails above 40 KB, the budget 3.4 keeps)
    stageKB = if (SynthDescLib.global.at(\strataVoiceMix).isNil) { 0 } {
        var before = floodFit.value, synths, after;
        synths = count.collect({ Synth(\strataVoiceMix, [\synthIn, privateBus, \otherIn, privateBus, \out, privateBus,
            \mirrorOut, privateBus, \tapOut, privateBus, \delaySendOut, privateBus.index, \reverbSendOut, privateBus.index,
            \fxMixIn, engine.mixBus(\fxMix).index, \modBus1, engine.silentBus, \modBus2, engine.silentBus, \modBus3, engine.silentBus], group) });
        server.sync; 0.1.wait;
        after = floodFit.value;
        synths.do(_.free); server.sync;
        (before - after) * probeKB / count
    };
    check.((stageKB > 0) and: { stageKB < 40 }, "memory: a voice's mix stage takes under 40 KB of the pool (% KB; estimate 35-37)".format(stageKB.round(0.1)));
    group.free; privateBus.free;
};

// What one \strataRecord takes of the pool (a loop recording, with its
// pre-roll), and the head guard's size: the small probes that fit with and
// without twenty of each. The guard is measured as its own graph against a
// check-only graph with the same inputs that returns the frame as it came
// (slotHeadGuard is what \strataGrainBuf adds: StrataLoop.sc).
var sizeOf = { arg start;
    var count = 20, before = floodFit.value, synths, after;
    synths = count.collect({ arg index; start.value(index) });
    server.sync; 0.1.wait;
    after = floodFit.value;
    synths.do(_.free); server.sync;
    (before - after) * probeKB / count
};
var checkRecordSizes = {
    var privateBus = Bus.audio(server, 2), controlBus = Bus.control(server, 40), group = Group.after(engine.processGroup), recordKB, guardKB, plainKB;
    var slotFrames = engine.buffersL[0].numFrames;
    // every input of the guard a signal, as in \strataGrainBuf (constants
    // would fold its arithmetic away), in both graphs
    SynthDef(\strataCheckGuardSize, { arg frame = 1000, lowest = 0, highest = 1e7, rate = 1, durFrames = 2000, recHead;
        Out.kr(controlBus.index, A2K.kr(engine.slotHeadGuard(K2A.ar(frame), K2A.ar(lowest), K2A.ar(highest), K2A.ar(rate),
            K2A.ar(durFrames), recHead)));
    }).add;
    SynthDef(\strataCheckGuardPlain, { arg frame = 1000, lowest = 0, highest = 1e7, rate = 1, durFrames = 2000, recHead;
        Out.kr(controlBus.index, A2K.kr(K2A.ar(frame) + (K2A.ar(lowest) + K2A.ar(highest) + K2A.ar(rate) + K2A.ar(durFrames) * 0)));
    }).add;
    server.sync;
    recordKB = sizeOf.({ arg index;
        Synth(\strataRecord, [\in, privateBus, \bufnumL, engine.buffersL[0].bufnum, \bufnumR, engine.buffersR[0].bufnum,
            \level, 0, \feedback, 1, \loop, 1, \frames, slotFrames, \peakFrames, slotFrames, \peakBuf, engine.slotPeakBuffer(0).bufnum,
            \framesOut, controlBus.index + 20 + index, \headOut, controlBus.index + index, \replyID, 99], group)
    });
    guardKB = sizeOf.({ arg index; Synth(\strataCheckGuardSize, [\recHead, engine.areaState[\record][\idleHead].index], group) });
    plainKB = sizeOf.({ arg index; Synth(\strataCheckGuardPlain, [\recHead, engine.areaState[\record][\idleHead].index], group) });
    check.((recordKB > 0) and: { recordKB <= 24 },
        "memory: a record synth takes about 15 KB (% KB of the pool, by allocation probes)".format(recordKB.round(0.1)));
    check.(((guardKB - plainKB) > 0) and: { (guardKB - plainKB) <= 8 },
        "memory: the head guard takes at most 8 KB per buffer grain synth (% KB: % KB against % KB without it)".format(
            (guardKB - plainKB).round(0.1), guardKB.round(0.1), plainKB.round(0.1)));
    group.free; privateBus.free; controlBus.free;
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
// on standard: 3 MB, 3.5's second note per voice plus 1 MB; fourteen on
// high: 3.5 MB; see docs/notes/engine/memory.md) are sent right after the
// last command, with no sync between, inside the 50 ms kill fade, then the
// flood of small probes (what is left beyond them) and the node tree, in
// that order: the cutting synths must still be there (so the probes meet
// the real peak) and every 256 KB probe must allocate. run_engine_check.sh
// also fails on any "alloc failed". engage (optional) runs right after each
// scenario's last command, before the probes (the high run's spectral
// freeze). The all-buffer worst case: every voice switched between three
// slots 0.2 s apart, so it holds a live, a fading and a cutting
// \strataGrainBuf (21 in all, the largest grain def). Eight recordings: the
// spaced mixed case with every slot recording an input take, twelve probes
// on both tiers (recordingFits gathers each tier's answer for one check).
// Returns the free KB at each peak.
var rateFilePath = h.tempDir +/+ "memory-rate.wav";
var recordingFits = List.new;
var checkMemoryWorstCase = { arg target, probeCount, floorLabel, engage;
    var command = { arg name ... args; h.commandTo(target, name, *args) };
    var startVoice = { arg voice; command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 200.0, 1.0) };
    var startAll = { target.numVoices.do(startVoice) };
    var switchAll = { arg sourceOf; target.numVoices.do({ arg voice; command.(\setGrainSource, voice, sourceOf.(voice)) }) };
    var sourceSteps = [{ arg voice; voice + 1 }, { target.numBuffers + 1 }, { 0 }];
    var slotOf = { arg voice, step; ((voice + step) % target.numBuffers) + 1 };
    var probeBus = Bus.control(server, probeCount), figures = List.new;
    var recordingProbes = 12, recordingsStarted;
    // the eight recordings, one per source kind: input, pre-master,
    // post-master, voices 1-5 (recordBuffer's source: 0, 1, 2, 3-7)
    var recordingSources = [0, 1, 2, 3, 4, 5, 6, 7];
    // a slot a voice reads, at the server rate, so its recording is playable
    // (the head guard runs in that voice's grain synths); a loop recording
    // of the pre-master bus
    var recordSlot = 0;
    var startRecording = { command.(\recordBuffer, recordSlot, 8.0, 1.0, 0, 1, 0, 1, 0) };
    var recordingRunning = { h.waitFor({ target.recordSynths[recordSlot].notNil and: { target.recordSynths[recordSlot].isPlaying } }, 3) };
    var stopRecording = { command.(\stopRecord, recordSlot); h.waitFor({ target.recordSynths[recordSlot].isNil }, 3) };
    // Just after the recording's peaks refresh (every peakRefreshSeconds:
    // the peaks file's rename is a subprocess, whose start can hold sclang
    // up for longer than a 50 ms cut), so the last switch and the probes
    // fall between two refreshes
    var afterPeakRefresh = {
        var counters = target.areaState[\record][\peakWrites], count = counters[\refreshes];
        h.waitFor({ counters[\refreshes] > count }, 1);
        0.1.wait; server.sync;
    };
    // scenario: names the case in the check line ("worst case", "all-buffer
    // worst case"); count: the probes (probeCount unless given); report: a
    // function of (all allocated, free KB) instead of the floor's own check
    var probeHeadroom = { arg label, scenario = "worst case", count, report;
        var cutting = target.numVoices.collect({ arg voice; target.cuttingSynths[voice].asArray.collect(_.nodeID) }).flatten;
        var probes, flood, infos = IdentitySet.new, watcher, present, values, freeKB, fits;
        count = count ? probeCount;
        scenario = scenario ? "worst case";
        probes = count.collect({ arg index;
            Synth(\strataCheckMemProbe, [\out, probeBus.index + index], target.processGroup, \addToTail)
        });
        flood = floodStart.value;
        // which cutting synths still exist, asked right after: /n_query
        // answers /n_info for each one there and (errors off) nothing for one gone
        watcher = OSCFunc({ arg msg; infos.add(msg[1]) }, '/n_info', server.addr);
        server.sendBundle(nil, ['/error', -1], *cutting.collect({ arg id; ['/n_query', id] }));
        freeKB = (count * 256) + (floodResult.(flood) * probeKB) + reserveKB;
        watcher.free;
        present = cutting.count({ arg id; infos.includes(id) });
        if (scenario.contains("all-buffer")) {
            // by now the 50 ms cuts have ended: 14 left, plus the 7 that were cutting
            var running = h.synthNames(target.processGroup).count({ arg name; name == \strataGrainBuf });
            check.((present == target.numVoices) and: { running >= (target.numVoices * 2) },
                "memory: the all-buffer case holds 21 strataGrainBuf (% cutting, % still running after the cuts)".format(present, running));
        };
        values = h.readBus(probeBus).keep(count);
        fits = (values.size == count) and: { values.every({ arg value; value > 0.5 }) };
        figures.add(freeKB.round(1));
        check.((cutting.size > 0) and: { present == cutting.size },
            "memory: the cutting synths are still there when the probes start (%: % of %)".format(label, present, cutting.size));
        if (report.notNil) { report.value(fits, freeKB) } {
            check.(fits, "memory: % free at the % %: % (about % KB free, the engine using about % KB more than idle)".format(
                floorLabel, target.tier, scenario, label, freeKB.round(10), (idleFreeKB - freeKB).round(10)));
        };
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
    // all-buffer: 21 \strataGrainBuf, reading slots that hold audio
    target.numBuffers.do({ arg slot; command.(\loadBuffer, slot, h.stereoPath, 0) });
    h.waitFor({ target.bufferFrames.every({ arg frames; frames > 0 }) }, 3);
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, slotOf.(voice, 0)) });
    startAll.value;
    server.sync; 0.2.wait;
    2.do({ arg step;
        if (step > 0) { 0.2.wait; server.sync };
        target.numVoices.do({ arg voice; command.(\setGrainSource, voice, slotOf.(voice, step + 1)) });
    });
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, each switched between three slots 0.2 s apart", "all-buffer worst case");
    h.stopAllVoices(target);
    // the same two worst cases with one recording running
    command.(\clearBuffer, recordSlot); server.sync;
    command.(\loadBuffer, recordSlot, rateFilePath, 0);
    h.waitFor({ target.bufferFrames[recordSlot] == (server.sampleRate.round.asInteger) }, 3);
    startRecording.value;
    recordingRunning.value;
    startAll.value;
    server.sync; 0.2.wait;
    sourceSteps.do({ arg sourceOf, step;
        if (step > 0) { 0.2.wait; server.sync };
        // the last switch makes the cutting set the probes must meet
        if (step == (sourceSteps.size - 1)) { afterPeakRefresh.value };
        switchAll.(sourceOf);
    });
    target.numVoices.do({ arg voice; command.(\voiceOff, voice) });
    startAll.value;
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted, one recording", "worst case with a recording");
    stopRecording.value;
    h.stopAllVoices(target);
    command.(\clearBuffer, recordSlot); server.sync;
    command.(\loadBuffer, recordSlot, rateFilePath, 0);
    h.waitFor({ target.bufferFrames[recordSlot] == (server.sampleRate.round.asInteger) }, 3);
    startRecording.value;
    recordingRunning.value;
    target.numVoices.do({ arg voice; command.(\setGrainSource, voice, slotOf.(voice, 0)) });
    startAll.value;
    server.sync; 0.2.wait;
    2.do({ arg step;
        if (step > 0) { 0.2.wait; server.sync; afterPeakRefresh.value };
        target.numVoices.do({ arg voice; command.(\setGrainSource, voice, slotOf.(voice, step + 1)) });
    });
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, each switched between three slots 0.2 s apart, one recording", "all-buffer worst case with a recording");
    stopRecording.value;
    h.stopAllVoices(target);
    command.(\clearBuffer, recordSlot); server.sync;
    // eight recordings at the mixed worst case (spaced, as the first
    // scenario), one per source kind
    target.numBuffers.do({ arg slot; command.(\recordBuffer, slot, 8.0, 1.0, 0, recordingSources[slot], 0, 0, 0) });
    recordingsStarted = h.waitFor({ target.recordSynths.every({ arg synth; synth.notNil and: { synth.isPlaying } }) }, 3);
    startAll.value;
    server.sync; 0.2.wait;
    sourceSteps.do({ arg sourceOf, step;
        if (step > 0) { 0.2.wait; server.sync };
        switchAll.(sourceOf);
    });
    target.numVoices.do({ arg voice; command.(\voiceOff, voice) });
    startAll.value;
    engage.value(command);
    probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted, eight slots recording", nil, recordingProbes,
        { arg fits, freeKB;
            recordingFits.add([target.tier, fits and: { recordingsStarted }
                and: { target.recordSynths.every({ arg synth; synth.notNil and: { synth.isPlaying } }) }, freeKB.round(10)]);
        });
    target.numBuffers.do({ arg slot; command.(\clearBuffer, slot) });
    h.stopAllVoices(target);
    probeBus.free;
    figures
};

// The high run (needs the performance setting): the default engine is
// replaced by a high one (one engine alone in the pool), the worst cases
// run with fourteen probes (3.5 MB) and spectral freeze engaged on every voice
// (a spectral writer per voice reading a ring: the first two scenarios end
// on the synth source; the recalls and the all-buffer case end on the
// slots, where spectral holds),
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
    checkMemoryWorstCase.(high, 14, "3.5 MB", { arg command;
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
// The flood's reserve: a 64 KB DelayN (16384 floats)
SynthDef(\strataCheckReserveProbe, { arg out; Out.kr(out, A2K.kr(DelayN.ar(DC.ar(1), 0.25, 0.01))) }).add;
server.sync;

h.writeTestFile(rateFilePath, server.sampleRate.round.asInteger, server.sampleRate.round.asInteger, [0.3, 0.3]);
probeKB = smallProbeKB.value;
idleFreeKB = (floodFit.value * probeKB) + reserveKB;
checkGrainMemorySizes.value;
checkGrainSynthSizes.value;
checkRecordSizes.value;
check.(engine.tier == \standard and: { probeKB > 4 } and: { probeKB < 64 },
    "memory: the default engine runs tier standard (idle, about % KB of the pool free; a small probe % KB)".format(
        idleFreeKB.round(10), probeKB.round(0.1)));
checkMemoryWorstCase.(engine, 12, "3 MB");
checkHighWorstCase.value;
check.((recordingFits.size == 2) and: { recordingFits.every({ arg each; each[1] }) },
    "memory: 3 MB free on both tiers with eight recordings running (%)".format(
        recordingFits.collect({ arg each; "% about % KB free".format(each[0], each[2]) }).join(", ")));
h.stopAllVoices;
reserveBus.free;
}
