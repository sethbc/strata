// test/engine_check/memory.scd
// Real-time memory: the grain UGens' fixed sizes, and the worst cases
// (spaced switches, a burst, fast recalls) on norns' 8192 KB pool.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var grainDefs = h.grainDefs;

// Real-time memory (#19). PitchShift allocates its delay line
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

checkGrainMemorySizes.value;
checkMemoryWorstCase.value;
h.stopAllVoices;
}
