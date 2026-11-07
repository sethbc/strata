// test/engine_check/memory.scd
// Real-time memory: the grain UGens' fixed sizes, what each grain synth
// takes of the pool, and the worst cases (spaced switches, a burst, fast
// recalls) on norns' 8192 KB pool, with 3 MB left on the standard tier.
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
// time, on norns' 8192 KB pool (memSize, set before boot), twelve 256 KB
// probes (3 MB, the standard floor: 3.5's second note per voice plus 1 MB;
// see docs/notes/engine/memory.md) started at that moment must still
// allocate. run_engine_check.sh also fails on any "alloc failed".
var checkMemoryWorstCase = {
    var startVoice = { arg voice; command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 200.0, 1.0) };
    var startAll = { engine.numVoices.do(startVoice) };
    var switchAll = { arg sourceOf; engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, sourceOf.(voice)) }) };
    var sourceSteps = [{ arg voice; voice + 1 }, { engine.numBuffers + 1 }, { 0 }];
    // at once after the last command, while the cut synths still fade
    var probeHeadroom = { arg label;
        var used;
        server.sync;
        used = poolUsedKB.value;
        check.(h.probeFree(12), "memory: 3 MB free at the standard worst case: % (pool used % KB)".format(label, used.round(1)));
        2.5.wait; server.sync;
    };
    check.(engine.tier == \standard, "memory: the default engine runs tier standard (idle, it uses % KB of the pool)".format(
        poolUsedKB.value.round(1)));
    startAll.value;
    server.sync; 0.2.wait;
    sourceSteps.do({ arg sourceOf, step;
        if (step > 0) { 0.2.wait; server.sync };
        switchAll.(sourceOf);
    });
    engine.numVoices.do({ arg voice; command.(\voiceOff, voice) });
    startAll.value;
    probeHeadroom.("seven voices at grain size 0.5, switched 0.2 s apart and restarted");
    sourceSteps.do({ arg sourceOf; switchAll.(sourceOf) });
    probeHeadroom.("seven voices at grain size 0.5, each switched three times at once");
    engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, engine.numBuffers + 1); command.(\voiceOff, voice) });
    engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, 0); startVoice.(voice) });
    engine.numVoices.do({ arg voice; command.(\setGrainSource, voice, voice + 1) });
    probeHeadroom.("seven voices at grain size 0.5, recalled A -> B -> A -> C at once (on/synth, off/input, on/synth, on/buffer)");
};

checkGrainMemorySizes.value;
checkGrainSynthSizes.value;
checkMemoryWorstCase.value;
h.stopAllVoices;
}
