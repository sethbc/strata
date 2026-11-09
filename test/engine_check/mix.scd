// test/engine_check/mix.scd
// The per-voice mix stage (\strataVoiceMix, lib/engine/StrataMix.sc): that
// every voice plays exactly as 3.2's grain synths did (design 3.3 §0c.4), on
// the server, against references that hold 3.2's voice filter, level, sends
// and mirror in the grain synth; the stage's placement, persistence, values
// and bad-value reset. See docs/notes/engine/mix.md.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var hasStage = engine.respondsTo(\voiceMixKey) and: { engine.respondsTo(\grainSignal) };
var voice = 4;  // Pulse: a short attack (2 s) among the sustaining voices
// The worst fade difference Step 1b measured at 5 kHz res 0.5 on 3.13 (three
// runs: -39.4, -36.6 and -38.6 dB, the slot fade on a noise slot), plus 6 dB
var fadeBoundDb = -30.6;
var silent = -30.dbamp;   // a reference peak under this means nothing was compared
var neutralGrain = [\posSpread, 0, \panSpread, 0, \pitchShift, 1.0, \bufPos, 0.3, \bufRate, 1, \bufScan, 0, \envShape, 0, \history, 0,
    \grainMode, 0, \reverseProb, 0, \pitchJitter, 0, \panJitter, 0, \sizeJitter, 0, \intervalCount, 0, \quantize, 0,
    \loopStart, 0, \loopLength, 1, \freeze, 0];
var stageOf = { arg target; engine.synths[engine.voiceMixKey(target)] };
var defaults = (amp: 0.5, filterType: 0, filterFreq: 5000, filterRes: 0.5, filterMix: 0, delaySend: 1, reverbSend: 1,
    modBus: nil, modAmt: 0);
var rate = server.sampleRate.asInteger;
var slotPaths = [h.tempDir +/+ "mix-slot-0.wav", h.tempDir +/+ "mix-slot-1.wav"];
var tone;

var loadSlot = { arg slot;
    command.(\loadBuffer, slot, slotPaths[slot], 0);
    h.waitFor({ engine.bufferFrames[slot] > 0 });
    server.sync;
};

// 3.2's grain synth, built from the engine's own reader and grainSignal
// (the grains, rate, pan and fade 0c leaves in the grain synth) and 3.2's
// tail (voiceFilter, the fade times 3.2's voice-level gain, voiceOutput)
var addSplitReferences = {
    var body = { arg c, reader;
        var grain = engine.grainSignal(c, reader), sig;
        var accent = EnvGen.kr(Env.perc(0.005, 0.4), c[\t_trig], levelScale: c[\velocity]);
        var modSigs = c[\modBuses].collect({ arg bus; In.kr(bus, 1) });
        var modSig = (modSigs * c[\modAmpAmts]).sum.clip(-2, 2) * c[\modLevel];
        sig = h.voiceFilter32(grain[\sig], c[\filterType], c[\filterFreq], c[\filterRes], c[\filterMix]);
        sig = sig * grain[\fade] * (c[\amp] * (1 + modSig) * (1 + (accent * c[\accentAmt]))).clip(0, 2);
        h.voiceOutput32(sig, c[\out], c[\mirrorOut], c[\mirrorLevel], c[\delaySend], c[\reverbSend]);
    };
    var controls = {
        (
            out: \out.kr(0), gate: \gate.kr(1), grainSize: \grainSize.kr(0.1), grainDensity: \grainDensity.kr(20),
            pitchShift: \pitchShift.kr(1), posSpread: \posSpread.kr(0.5), panSpread: \panSpread.kr(0.5), envBuf: \envBuf.kr(-1),
            grainMode: \grainMode.kr(0), t_trig: \t_trig.tr(0), velocity: \velocity.kr(1), amp: \amp.kr(1), bend: \bend.kr(1),
            kill: \kill.kr(0), pan: \pan.kr(0), accentAmt: \accentAmt.kr(0), mirrorOut: \mirrorOut.kr(0), mirrorLevel: \mirrorLevel.kr(0),
            modLevel: \modLevel.kr(0), rateLevel: \rateLevel.kr(1), modBuses: [\modBus1.kr(0), \modBus2.kr(0), \modBus3.kr(0)],
            modAmpAmts: [\modAmpAmt1.kr(0), \modAmpAmt2.kr(0), \modAmpAmt3.kr(0)],
            modFreqAmts: [\modFreqAmt1.kr(0), \modFreqAmt2.kr(0), \modFreqAmt3.kr(0)], ringLevel: \ringLevel.kr(1),
            reverseProb: \reverseProb.kr(0), pitchJitter: \pitchJitter.kr(0), panJitter: \panJitter.kr(0), sizeJitter: \sizeJitter.kr(0),
            intervals: (1..8).collect({ arg index; ("interval" ++ index).asSymbol.kr(0) }),
            intervalCount: \intervalCount.kr(0), intervalProb: \intervalProb.kr(1), quantize: \quantize.kr(0), scaleNote: \scaleNote.kr(60),
            filterType: \filterType.kr(0), filterFreq: \filterFreq.kr(5000), filterRes: \filterRes.kr(0.5), filterMix: \filterMix.kr(0),
            delaySend: \delaySend.kr(1), reverbSend: \reverbSend.kr(1)
        )
    };
    SynthDef(\strataCheckGrainRing32Split, {
        var c = controls.value;
        body.(c, engine.ringGrainReader(\bufL.kr(0), \bufR.kr(0), \phaseBus.kr(0), c[\posSpread], \history.kr(0), \bufScan.kr(0), \freeze.kr(0)));
    }).add;
    SynthDef(\strataCheckGrainBuf32Split, {
        var c = controls.value;
        body.(c, engine.slotGrainReader(\bufnumL.kr(0), \bufnumR.kr(0), \bufFrames.kr(1), \bufRateScale.kr(1), \bufPos.kr(0), \bufRate.kr(1),
            \bufScan.kr(0), c[\posSpread], \freeze.kr(0), \loopStart.kr(0), \loopLength.kr(1), \scrubRate.kr(0), \scanHold.kr(0),
            \t_scanReset.tr(0), \recHeadBus.kr(engine.areaState[\record][\idleHead].index)));
    }).add;
    // The largest difference over dry, delay send, reverb send and mirror
    // (eight channels, in that order) and the reference's own peak
    SynthDef(\strataCheckMixCompare, { arg refIn, stageIn, out, t_reset = 0;
        var ref = In.ar(refIn, 8), stage = In.ar(stageIn, 8);
        Out.kr(out, [A2K.kr(Peak.ar((ref - stage).abs.reduce(\max), t_reset)), A2K.kr(Peak.ar(ref.abs.reduce(\max), t_reset))]);
    }).add;
    // A 3 Hz sine on a mod bus, as a crossmod source
    SynthDef(\strataCheckModSine, { arg out; Out.kr(out, SinOsc.kr(3)) }).add;
    // A bus copied to another, and a denormal written to a bus
    SynthDef(\strataCheckBusCopy, { arg in, out; Out.ar(out, In.ar(in, 2)) }).add;
    SynthDef(\strataCheckDenormal, { arg out; Out.ar(out, DC.ar(1e-40) ! 2) }).add;
};

// What 3.2's startGrainSynth gave a grain synth of this source, for the
// reference: source 0 the synth source (no mirror, accent, level or pan),
// 1..numBuffers a slot, numBuffers + 1 the input. settings: as defaults
var refPairs = { arg state, target, source, settings;
    var modBus = settings[\modBus] ?? { engine.silentBus.index };
    var pairs = [
        \out, state[\refBus].index, \mirrorOut, state[\refBus].index + 6,
        \delaySendOut, state[\refBus].index + 2, \reverbSendOut, state[\refBus].index + 4, \fxMixIn, engine.mixBus(\fxMix).index,
        \grainSize, 0.1, \grainDensity, 20, \pitchShift, 1, \posSpread, 0, \panSpread, 0, \envBuf, -1, \grainMode, 0,
        \filterType, settings[\filterType], \filterFreq, settings[\filterFreq], \filterRes, settings[\filterRes],
        \filterMix, settings[\filterMix], \delaySend, settings[\delaySend], \reverbSend, settings[\reverbSend], \pan, 0, \bend, 1, \history, 0
    ];
    if (source == 0) {
        var ring = engine.ringBuffersFor(target, 0);
        pairs ++ [\bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index, \amp, 1,
            \mirrorLevel, 0, \accentAmt, 0, \modLevel, 0, \rateLevel, 0,
            \modBus1, engine.silentBus.index, \modBus2, engine.silentBus.index, \modBus3, engine.silentBus.index]
    } {
        var level = [\amp, settings[\amp], \mirrorLevel, 1, \accentAmt, 1, \modLevel, 1, \rateLevel, 1,
            \modBus1, modBus, \modBus2, engine.silentBus.index, \modBus3, engine.silentBus.index, \modAmpAmt1, settings[\modAmt]];
        if (source == engine.inputSource) {
            var ring = engine.ringBuffersFor(target, source);
            pairs ++ level ++ [\bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index]
        } {
            var slot = source - 1;
            pairs ++ level ++ [\bufnumL, engine.buffersL[slot].bufnum, \bufnumR, engine.buffersR[slot].bufnum,
                \bufFrames, engine.bufferFrames[slot], \bufRateScale, engine.bufferRateScale(slot), \bufPos, 0.3]
        }
    }
};
// A reference's def: the split ones, or (verbatim) the runner's copies of 3.2's
var refDef = { arg source, verbatim;
    var isRing = (source == 0) or: { source == engine.inputSource };
    if (verbatim) { if (isRing) { h.def32[\grainRing] } { h.def32[\grainBuf] } }
    { if (isRing) { \strataCheckGrainRing32Split } { \strataCheckGrainBuf32Split } }
};

// Everything one comparison needs: private buses (reference, stage, tap),
// the peak bus, a group after processGroup with the reference synths at its
// head and the comparator at its tail, and the references' live, fading and
// cutting synths, tracked as the engine tracks the voice's. The stage writes
// the private buses meanwhile.
var withComparison = { arg target, body, verbatim = false;
    var stage = stageOf.(target), group = Group.after(engine.processGroup);
    var refBus = Bus.audio(server, 8), stageBus = Bus.audio(server, 8), tapBus = Bus.audio(server, 2), peaks = Bus.control(server, 2);
    var state = (voice: target, group: group, refBus: refBus, stageBus: stageBus, tapBus: tapBus, peaks: peaks, verbatim: verbatim,
        live: nil, fading: List.new, cutting: List.new);
    var result;
    stage.set(\out, stageBus.index, \delaySendOut, stageBus.index + 2, \reverbSendOut, stageBus.index + 4,
        \mirrorOut, stageBus.index + 6, \tapOut, tapBus.index);
    state[\compare] = Synth(\strataCheckMixCompare, [\refIn, refBus, \stageIn, stageBus, \out, peaks], group, \addToTail);
    server.sync;
    result = body.value(state);
    stageOf.(target).set(*engine.areaState[\mix][\stageControls][target].asKeyValuePairs);
    group.free; server.sync;
    [refBus, stageBus, tapBus, peaks].do(_.free);
    result
};

// The voice's values on the engine (the stage's lags settle before anything is compared)
var prepareVoice = { arg target, source, settings;
    neutralGrain.pairsDo({ arg name, value; command.(\setGrainParam, target, name, value) });
    [\filterType, \filterFreq, \filterRes, \filterMix, \delaySend, \reverbSend].do({ arg name;
        command.(\setGrainParam, target, name, settings[name]) });
    command.(\setGrainSource, target, source);
    server.sync; 0.3.wait;
};

// Reset the comparator, run trigger in the same bundle, wait, read [diff, ref peak]
var measureSpan = { arg state, seconds, trigger;
    server.makeBundle(nil, { state[\compare].set(\t_reset, 1); trigger.value });
    seconds.wait; server.sync;
    h.readBus(state[\peaks])
};
// Start the voice and a reference copy in one block (inside a bundle)
var startReference = { arg state, source, settings;
    state[\live] = Synth(refDef.(source, state[\verbatim]), refPairs.(state, state[\voice], source, settings), state[\group], \addToHead);
};
var voiceOnPair = { arg state, source, settings;
    command.(\voiceOn, state[\voice], 220.0, settings[\amp], 0.0, 0.1, 20.0, 1.0);
    startReference.(state, source, settings);
};
// A source switch on the engine and, in the same bundle, on the references:
// what replaceGrainSynth does (cut what fades, free what was cutting)
var switchPair = { arg state, source, settings;
    var old = state[\live];
    command.(\setGrainSource, state[\voice], source);
    state[\cutting].do({ arg synth; engine.sendToSynth(synth.freeMsg) });
    state[\cutting].clear;
    state[\fading].do({ arg synth; engine.sendToSynth(synth.setMsg(\kill, 1)); state[\cutting].add(synth) });
    state[\fading].clear;
    startReference.(state, source, settings);
    if (old.notNil) { engine.sendToSynth(old.releaseMsg(engine.grainRelease)); state[\fading].add(old) };
};
var voiceOffPair = { arg state;
    command.(\voiceOff, state[\voice]);
    if (state[\live].notNil) { engine.sendToSynth(state[\live].setMsg(\gate, 0)) };
};
var stopVoice = { arg state;
    h.stopAllVoices;
    ([state[\live]] ++ state[\fading].asArray ++ state[\cutting].asArray).do({ arg synth;
        if (synth.notNil) { engine.sendToSynth(synth.freeMsg) } });
    state[\live] = nil; state[\fading].clear; state[\cutting].clear;
    server.sync;
};
var inDb = { arg peaks; (peaks[0] / max(peaks[1], 1e-12)).ampdb.round(0.1) };
var assertEqualRef = { arg peaks, message;
    check.((peaks.size == 2) and: { peaks[1] > silent } and: { peaks[0] < 1e-6 },
        "% (difference %, reference peak %, % dB)".format(message, peaks[0], peaks[1], inDb.(peaks)));
};

// Steady state: from 0.2 s after voiceOn for 1 s. during (optional) runs in
// the 1 s window (a function of state, it waits), after waiting 0
var compareSteady = { arg message, source, settings, during;
    withComparison.(voice, { arg state;
        var peaks;
        prepareVoice.(voice, source, settings);
        server.makeBundle(nil, { voiceOnPair.(state, source, settings) });
        0.2.wait;
        peaks = if (during.notNil) {
            server.makeBundle(nil, { state[\compare].set(\t_reset, 1) });
            during.value(state);
            server.sync;
            h.readBus(state[\peaks])
        } { measureSpan.(state, 1.0, nil) };
        stopVoice.(state);
        assertEqualRef.(peaks, message);
    });
};

// The structural checks run with no audio comparison, so a missing stage
// shows up as a named failure of each of them
var checkStagePlacement = {
    var stages = { arg target; h.synthTree(engine.voiceMixGroup(target)) };
    var xg = h.synthTree(context.xg);
    check.((engine.numVoices.collect({ arg target;
            var nodes = stages.(target);
            (nodes.last.def == \strataVoiceMix) and: { nodes.last.controls[\otherIn] == engine.areaState[\mix][\otherPaths][target].index }
                and: { nodes.last.controls[\synthIn] == engine.areaState[\mix][\synthPaths][target].index }
        }).every(_ == true)) and: { xg.count({ arg node; node.def == \strataVoiceMix }) == engine.numVoices },
        "mix: every voice has one strataVoiceMix at its mix group's tail from start to stop");
};

// mix: every voice's stage is the same node from before these to after
var checkStagePersistence = {
    var ids = engine.numVoices.collect({ arg target; stageOf.(target).nodeID });
    var same = { engine.numVoices.collect({ arg target; stageOf.(target).nodeID }) == ids };
    // switches, starts and stops
    engine.numVoices.do({ arg target;
        command.(\setGrainSource, target, (target % engine.numBuffers) + 1);
        command.(\voiceOn, target, 220.0, 0.2, 0.0, 0.2, 40.0, 1.0);
    });
    server.sync; 0.2.wait;
    engine.numVoices.do({ arg target; command.(\setGrainSource, target, engine.inputSource); command.(\setGrainSource, target, 0) });
    server.sync; 0.1.wait;
    engine.numVoices.do({ arg target; command.(\voiceOff, target) });
    server.sync; 0.1.wait;
    // the A -> B -> A -> C recalls: on/synth, off/input, on/synth, on/buffer, at once
    engine.numVoices.do({ arg target; command.(\setGrainSource, target, engine.inputSource); command.(\voiceOff, target) });
    engine.numVoices.do({ arg target; command.(\setGrainSource, target, 0); command.(\voiceOn, target, 110.0, 0.2, 0.0, 0.5, 200.0, 1.0) });
    engine.numVoices.do({ arg target; command.(\setGrainSource, target, target + 1) });
    server.sync; 0.1.wait;
    h.stopAllVoices;
    check.(same.value, "mix: switches, starts, stops and the A -> B -> A -> C recalls leave every stage's node ID unchanged");
};

// A mix group sits just before its voice's mod synth: in the flattened node
// order, the voice's stage immediately precedes its mod synth
var groupsBeforeMods = {
    var nodes = h.synthTree(engine.processGroup);
    (0..engine.numVoices - 1).every({ arg target;
        var modAt = nodes.detectIndex({ arg node; (node.def == \strataMod) and: { node.controls[\in] == engine.granBuses[target].index } });
        var stageAt = nodes.detectIndex({ arg node; (node.def == \strataVoiceMix) and: { node.controls[\mirrorOut] == engine.granBuses[target].index } });
        modAt.isNil or: { stageAt.notNil and: { (modAt - 1) == stageAt } }
    })
};
var checkGroupOrder = {
    h.startAllVoices;
    check.(groupsBeforeMods.value, "mix: each mix group sits just before its voice's mod synth");
    engine.synths[engine.modKey(2)] !? { arg mod; server.sendMsg(\n_free, mod.nodeID) };
    0.2.wait; server.sync;
    check.(groupsBeforeMods.value, "mix: each mix group sits just before its voice's mod synth, after a mod restart too");
    command.(\setGrainSource, 0, 1); command.(\setGrainSource, 1, engine.inputSource);
    server.sync;
    {
        var nodes = h.synthTree(engine.processGroup), firstStage = nodes.detectIndex({ arg node; node.def == \strataVoiceMix });
        var synthPaths = engine.areaState[\mix][\synthPaths].collect(_.index);
        var synthRings = nodes.selectIndices({ arg node;
            (node.def == \strataGrainRing) and: { synthPaths.includes(node.controls[\out].asInteger) } });
        var bufferAt = h.synthTree(engine.voiceMixGroup(0)), inputAt = h.synthTree(engine.voiceMixGroup(1));
        check.((bufferAt.first.def == \strataGrainBuf) and: { inputAt.first.def == \strataGrainRing }
            and: { firstStage.notNil } and: { synthRings.notEmpty } and: { synthRings.every({ arg at; at < firstStage }) },
            "mix: buffer and input grain synths start in their mix group, synth-source ones at the head of processGroup");
    }.value;
    h.stopAllVoices;
};
var checkGrainDefsLostControls = {
    var removed = [\amp, \velocity, \accentAmt, \modLevel, \modAmpAmt1, \modAmpAmt2, \modAmpAmt3, \mirrorOut, \mirrorLevel,
        \filterType, \filterFreq, \filterRes, \filterMix, \delaySend, \reverbSend, \delaySendOut, \reverbSendOut, \fxMixIn];
    var left = h.grainDefs.collect({ arg name;
        SynthDescLib.global.at(name).controlNames.collect(_.asSymbol).select({ arg control; removed.includes(control) })
    }).flatten;
    check.(left.isEmpty, "mix: no grain SynthDef has a filter, send, mirror, accent or amp control (left: %)".format(left));
};

var checkStageValues = {
    var stage = stageOf.(voice), silentIndex = engine.silentBus.index, before;
    var send = { arg name, value; command.(\setGrainParam, voice, name, value) };
    command.(\voiceOn, voice, 220.0, 0.25, 0.0, 0.1, 20.0, 1.0); server.sync;
    [\filterType, \filterFreq, \filterRes, \filterMix, \delaySend, \reverbSend].do({ arg name, index;
        var value = [2, 800, 0.7, 0.75, 0.2, 0.4][index];
        send.(name, value);
    });
    server.sync;
    check.([\filterType, \filterFreq, \filterRes, \filterMix, \delaySend, \reverbSend].every({ arg name, index;
        var value = [2, 800, 0.7, 0.75, 0.2, 0.4][index];
        getControl.(stage, name).equalWithPrecision(value) and: { engine.grainControls[voice][name] == value }
    }), "mix: the six filter and send names reach the stage and are kept in grainControls");
    [\filterType, \filterFreq, \filterRes, \filterMix].do({ arg name, index;
        send.(name, [0, 5000, 0.5, 0][index]) });
    [\delaySend, \reverbSend].do({ arg name; send.(name, 1) });
    command.(\setVoiceParam, voice, \amp, 0.3);
    command.(\setModSource, voice, 2, 3);
    command.(\setModAmpAmt, voice, 2, 0.25);
    server.sync;
    check.(getControl.(stage, \amp).equalWithPrecision(0.3) and: { getControl.(stage, \modBus2) == engine.modBuses[3].index }
        and: { getControl.(stage, \modAmpAmt2).equalWithPrecision(0.25) },
        "mix: amp, setModSource and setModAmpAmt reach the stage");
    command.(\voiceOn, voice, 220.0, 0.6, 0.0, 0.1, 20.0, 1.0); server.sync;
    check.(getControl.(stage, \amp).equalWithPrecision(0.6) and: { getControl.(stage, \modBus2) == silentIndex }
        and: { getControl.(stage, \modAmpAmt2) == 0 },
        "mix: amp, setModSource and setModAmpAmt reach the stage, and voiceOn sends it the reset values");
    // retrigger: only while the voice runs, and it creates no node
    before = h.synthNames(context.xg).size;
    command.(\retrigger, voice, 0.75); server.sync;
    check.((getControl.(stage, \velocity) == 0.75) and: { h.synthNames(context.xg).size == before },
        "mix: retrigger reaches the running voice's stage and creates no node");
    command.(\voiceOff, voice); server.sync;
    command.(\retrigger, voice, 0.5); server.sync;
    check.((getControl.(stage, \velocity) == 0.75) and: { h.synthNames(context.xg).size == before },
        "mix: retrigger reaches the stage only while the voice runs and creates no node");
    h.stopAllVoices;
    // a filter change during a crossfade is on the stage; the fading grain synth has no filter control
    command.(\setGrainSource, voice, 1);
    command.(\voiceOn, voice, 220.0, 0.25, 0.0, 0.1, 20.0, 1.0); server.sync; 0.2.wait;
    {
        var fading = engine.synths[engine.grainKey(voice)];
        command.(\setGrainSource, voice, 2); server.sync;
        send.(\filterFreq, 1200); server.sync;
        check.((getControl.(stage, \filterFreq) == 1200) and: { engine.fadingSynths[voice].includes(fading) }
            and: { SynthDescLib.global.at(fading.defName.asSymbol).controlNames.collect(_.asSymbol).includes(\filterFreq).not },
            "mix: a filter change during a switch's crossfade is on the stage, with no filter control on the fading grain synth");
    }.value;
    send.(\filterFreq, 5000);
    h.stopAllVoices;
    // silentBus until a crossmod source is set
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 220.0, 0.25, 0.0, 0.1, 20.0, 1.0); server.sync;
    check.([\modBus1, \modBus2, \modBus3].every({ arg name; (getControl.(stage, name) == silentIndex) and: { getControl.(stage, name) != 0 } }),
        "mix: the stage reads silentBus until a crossmod source is set, never control bus 0");
    h.stopAllVoices;
};

// A NaN on the stage's node makes its filter bad: the stage is replaced in
// place (the same group and key, a new node), plays again, and nothing bad
// reaches the buses; a denormal never replaces it
var checkBadStage = {
    var state = engine.areaState[\mix], source = 1, bad = 0;
    var mixGroup = engine.voiceMixGroup(voice), group = Group.after(engine.processGroup), badBus = Bus.control(server, 4);
    var peakBus = Bus.control(server, 1), probes, peakProbe, oldId, nodes, denormal, level;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 220.0, 0.5, 0.0, 0.1, 20.0, 1.0); server.sync; 0.3.wait;
    probes = [engine.mainBus, engine.mixBus(\delaySend), engine.mixBus(\reverbSend), engine.granBuses[voice]].collect({ arg bus, index;
        Synth(\strataCheckBadValues, [\in, bus, \out, badBus.index + index], group) });
    peakProbe = Synth(\strataCheckPeak, [\in, engine.mainBus, \out, peakBus], group);
    server.sync; 0.1.wait;
    oldId = stageOf.(voice).nodeID;
    stageOf.(voice).set(\filterMix, 0/0);    // a NaN: the replacement starts from the kept 0
    0.3.wait; server.sync;
    level = h.measure(peakProbe, peakBus, 0.4)[0];
    bad = h.readBus(badBus);
    nodes = h.synthTree(mixGroup);
    check.((stageOf.(voice).nodeID != oldId) and: { nodes.last.id == stageOf.(voice).nodeID } and: { nodes.last.def == \strataVoiceMix }
        and: { bad.every({ arg each; each == 0 }) } and: { level > 0.02 },
        "mix: a stage whose filter goes bad is replaced in place, plays again and lets nothing bad out (node % -> %, bad seen %, level after %)".format(
            oldId, stageOf.(voice).nodeID, bad, level));
    // a denormal alone never replaces it (input and, by the graph, the raw filter outputs)
    oldId = stageOf.(voice).nodeID;
    denormal = Synth(\strataCheckDenormal, [\out, engine.voicePathBus(voice, 0)], engine.processGroup, \addToHead);
    server.sync; 0.2.wait;
    denormal.free; server.sync;
    {
        var ugens = SynthDescLib.global.at(\strataVoiceMix).def.children, reply = ugens.detect({ arg ugen; ugen.isKindOf(SendReply) });
        check.((stageOf.(voice).nodeID == oldId) and: { reply.notNil }
            and: { ugens.count({ arg ugen; ugen.isKindOf(BinaryOpUGen) and: { ugen.operator == '<' } and: { ugen.inputs[1] == 2.5 } }) >= 4 },
            "mix: a denormal alone never replaces the stage (the reset's trigger takes codes 1 and 2 only)");
    }.value;
    h.stopAllVoices;
    probes.do(_.free); group.free; server.sync; badBus.free; peakBus.free;
};

// The figures and the bound
var checkFades = {
    [[5000, 0.5, "5 kHz res 0.5", true], [200, 0.9, "200 Hz res 0.9", false]].do({ arg filterSet;
        var settings = defaults.copy.putAll((filterFreq: filterSet[0], filterRes: filterSet[1], filterMix: 1, amp: 1));
        var figures = List.new;
        withComparison.(voice, { arg state;
            var add = { arg name, peaks;
                figures.add(inDb.(peaks));
                check.(inDb.(peaks).isNaN.not and: { peaks[1] > 0 },
                    "mix: fade figure at %: % % dB of the reference's peak (difference %)".format(filterSet[2], name, inDb.(peaks), peaks[0]));
            };
            loadSlot.(0); loadSlot.(1);
            prepareVoice.(voice, 1, settings);
            add.("attack", measureSpan.(state, 0.25, { voiceOnPair.(state, 1, settings) }));
            0.1.wait;
            add.("release", measureSpan.(state, 2.2, { voiceOffPair.(state) }));
            state[\live] = nil;
            server.makeBundle(nil, { voiceOnPair.(state, 1, settings) });
            0.3.wait;
            add.("a switch's crossfade", measureSpan.(state, 2.2, { switchPair.(state, 2, settings) }));
            0.05.wait;
            server.makeBundle(nil, { switchPair.(state, 1, settings) });   // slot 1 starts; slot 2 fades
            0.2.wait;
            add.("a cut", measureSpan.(state, 0.1, { switchPair.(state, 2, settings) }));   // cuts the slot 1 grain's predecessor
            0.2.wait;
            // live on slot 2 (index 1): the slot fade
            add.("a slot fade", measureSpan.(state, 0.15, {
                command.(\clearBuffer, 1);
                engine.sendToSynth(state[\live].setMsg(\bufFrames, 0));
            }));
            stopVoice.(state);
        });
        if (filterSet[3]) {
            check.((figures.size == 5) and: { figures.maxItem < fadeBoundDb },
                "mix: with the filter at 5 kHz res 0.5, a fade differs from 3.2's by less than the measured bound of % dB (worst % dB)".format(
                    fadeBoundDb, figures.maxItem));
        };
    });
};

// Crossfades with accents and an amp move: printed; the reference's fading
// tails keep their values, as 3.2's did (design §0c.4, exception 2)
var checkAccentedCrossfade = {
    [[2, "buffer -> buffer"], [engine.inputSource, "buffer -> input"], [0, "buffer -> synth"]].do({ arg entry;
        var target = entry[0], peaks;
        var settings = defaults.copy.putAll((amp: 0.5));
        withComparison.(voice, { arg state;
            prepareVoice.(voice, 1, settings);
            server.makeBundle(nil, { voiceOnPair.(state, 1, settings) });
            0.3.wait;
            server.makeBundle(nil, { state[\compare].set(\t_reset, 1); switchPair.(state, target, settings) });
            20.do({ arg index;
                server.makeBundle(nil, {
                    command.(\retrigger, voice, 0.7);
                    if (state[\live].notNil) { state[\live].set(\velocity, 0.7, \t_trig, 1) };
                    if (index == 10) {
                        command.(\setVoiceParam, voice, \amp, 0.3);
                        if (target != 0) { state[\live].set(\amp, 0.3) };
                    };
                });
                0.1.wait;
            });
            server.sync;
            peaks = h.readBus(state[\peaks]);
            stopVoice.(state);
            check.((peaks.size == 2) and: { peaks[1] > silent } and: { inDb.(peaks).isNaN.not } and: { inDb.(peaks) < 100 },
                "mix: bypassed, a crossfade with accents and an amp move prints its difference from 3.2's (%: % dB of the reference's peak, reference peak %)".format(
                    entry[1], inDb.(peaks), peaks[1]));
        });
    });
};

// the mirror: a synth voice's bus carries its voice synth alone; a buffer voice's equals the reference's
var checkMirror = {
    var copyBus = Bus.audio(server, 2), group = Group.after(engine.processGroup), peaks = Bus.control(server, 2);
    var copy, probe, values;
    // synth voice: its own synth on a private bus, copied to the voice bus before the ring writer
    prepareVoice.(voice, 0, defaults);
    command.(\voiceOn, voice, 220.0, 1.0, 0.0, 0.1, 20.0, 1.0); server.sync;
    engine.synths[engine.voiceKey(voice)].set(\out, copyBus.index);
    copy = Synth(\strataCheckBusCopy, [\in, copyBus, \out, engine.granBuses[voice]], engine.ringWriterFor(voice), \addBefore);
    probe = Synth(\strataCheckBusDiff, [\a, copyBus, \b, engine.granBuses[voice], \out, peaks], group, \addToTail);
    server.sync; 1.5.wait;   // past enough of the Pulse's attack, the grains running
    probe.set(\t_reset, 1); 0.5.wait; server.sync;
    values = h.readBus(peaks);
    check.((values[0] < 1e-6) and: { values[1] > 0.01 },
        "mix: the mirror carries the buffer and input path only, filtered and after the level (a synth voice's voice bus: difference %, level %)".format(values[0], values[1]));
    copy.free; probe.free;
    h.stopAllVoices;
    // a buffer voice's mirror equals the reference's within 1e-6
    withComparison.(voice, { arg state;
        var settings = defaults.copy.putAll((filterFreq: 1000, filterRes: 0.9, filterMix: 1));
        var bufferPeaks;
        var mirrorProbe, mirrorPeaks = Bus.control(server, 2), mirrorValues;
        prepareVoice.(voice, 1, settings);
        mirrorProbe = Synth(\strataCheckBusDiff, [\a, state[\refBus].index + 6, \b, state[\stageBus].index + 6, \out, mirrorPeaks], state[\group], \addToTail);
        server.makeBundle(nil, { voiceOnPair.(state, 1, settings) });
        0.3.wait;
        mirrorProbe.set(\t_reset, 1); 1.0.wait; server.sync;
        mirrorValues = h.readBus(mirrorPeaks);
        stopVoice.(state);
        mirrorProbe.free; mirrorPeaks.free;
        check.((mirrorValues[1] > silent) and: { mirrorValues[0] < 1e-6 },
            "mix: the mirror carries the buffer and input path only, filtered and after the level (a buffer voice: difference %, reference level %)".format(mirrorValues[0], mirrorValues[1]));
        bufferPeaks;
    });
    copyBus.free; group.free; peaks.free;
};

// the tap: sends 0, the stage's dry output and the tap are the same signal
var checkTap = {
    var settings = defaults.copy.putAll((delaySend: 0, reverbSend: 0, filterFreq: 1000, filterRes: 0.9, filterMix: 1));
    withComparison.(voice, { arg state;
        var tapPeaks = Bus.control(server, 2), tapProbe, values;
        prepareVoice.(voice, 1, settings);
        tapProbe = Synth(\strataCheckBusDiff, [\a, state[\stageBus].index, \b, state[\tapBus], \out, tapPeaks], state[\group], \addToTail);
        server.makeBundle(nil, { voiceOnPair.(state, 1, settings) });
        0.3.wait;
        tapProbe.set(\t_reset, 1); 1.0.wait; server.sync;
        values = h.readBus(tapPeaks);
        stopVoice.(state);
        tapProbe.free; tapPeaks.free;
        check.((values[1] > silent) and: { values[0] < 1e-6 },
            "mix: a voice's tap carries its whole output before the sends (difference %, level %)".format(values[0], values[1]));
    });
};

if (hasStage.not) {
    check.(false, "mix: every voice has one strataVoiceMix at its mix group's tail from start to stop");
    check.(false, "mix: no grain SynthDef has a filter, send, mirror, accent or amp control");
} {
    addSplitReferences.value;
    server.sync;
    // Two 2 s stereo slots of noise at the server rate (the same seed each run)
    thisThread.randSeed = 330;
    slotPaths.do({ arg path, index;
        var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
        file.openWrite(path);
        file.writeData(h.stereoOf(h.noise(rate * 2, 0.5), h.noise(rate * 2, 0.5)));
        file.close;
    });
    loadSlot.(0); loadSlot.(1);
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.inputSynth, \addBefore);
    server.sync;

    checkStagePlacement.value;
    checkGrainDefsLostControls.value;
    checkStageValues.value;
    checkStagePersistence.value;
    checkGroupOrder.value;

    // Steady states: lowpass 1 kHz res 0.9, sends 0.6 and 0.3, delay and reverb mixes 0.5 and 0.4
    command.(\setDelay, 0.25, 0.4, 0.5);
    command.(\setReverb, 0.4, 0.8, 0.5);
    server.sync; 0.2.wait;
    {
        var settings = defaults.copy.putAll((filterFreq: 1000, filterRes: 0.9, filterMix: 1, delaySend: 0.6, reverbSend: 0.3, amp: 0.8));
        var sineSynth = Synth(\strataCheckModSine, [\out, engine.modBuses[0]], engine.voiceGroup, \addToHead);
        compareSteady.("mix: a synth voice equals 3.2's grain synth within 1e-6 in steady state", 0, settings);
        compareSteady.("mix: an input voice equals 3.2's within 1e-6 in steady state", engine.inputSource, settings);
        compareSteady.("mix: a buffer voice equals 3.2's within 1e-6 in steady state, with crossmod, accents and an amp move", 1, settings, { arg state;
            server.makeBundle(nil, {
                command.(\setModSource, voice, 1, 0);
                command.(\setModAmpAmt, voice, 1, 1.0);
                state[\live].set(\modBus1, engine.modBuses[0].index, \modAmpAmt1, 1.0);
            });
            10.do({ arg index;
                server.makeBundle(nil, {
                    command.(\retrigger, voice, 0.7);
                    state[\live].set(\velocity, 0.7, \t_trig, 1);
                    if (index == 4) { command.(\setVoiceParam, voice, \amp, 0.6); state[\live].set(\amp, 0.6) };
                    if (index == 7) { command.(\setVoiceParam, voice, \amp, 0.4); state[\live].set(\amp, 0.4) };
                });
                0.1.wait;
            });
        });
        sineSynth.free;
        // each filter type, and mix 0.5 (a buffer voice)
        [[0, 1, "lowpass"], [1, 1, "highpass"], [2, 1, "bandpass"], [0, 0.5, "lowpass at mix 0.5"]].do({ arg filterCase;
            var filterSettings = defaults.copy.putAll((filterType: filterCase[0], filterFreq: 1000, filterRes: 0.5, filterMix: filterCase[1]));
            compareSteady.("mix: each filter type and mix 0.5 equal 3.2's within 1e-6 (%)".format(filterCase[2]), 1, filterSettings);
        });
    }.value;

    // Bypassed: the filter mix back to 0 (and the delay and reverb at their
    // defaults, their mixes broadcast), the lags settled
    command.(\setDelay, 0.375, 0.4, 0.0);
    command.(\setReverb, 0.3, 0.8, 0.5);
    server.sync; 1.0.wait;
    {
        var settings = defaults.copy.putAll((amp: 0.8));
        withComparison.(voice, { arg state;
            var peaks;
            prepareVoice.(voice, 0, settings);
            1.0.wait;  // the filter mix lag
            peaks = measureSpan.(state, 0.5, { voiceOnPair.(state, 0, settings) });
            server.makeBundle(nil, { switchPair.(state, 1, settings) });
            0.6.wait;
            server.makeBundle(nil, { switchPair.(state, engine.inputSource, settings) });
            0.6.wait;
            server.makeBundle(nil, { voiceOffPair.(state) });
            2.2.wait; server.sync;
            {
                var whole = h.readBus(state[\peaks]);
                stopVoice.(state);
                check.((whole[1] > silent) and: { whole[0] < 1e-6 },
                    "mix: bypassed, a voice equals 3.2's within 1e-6 through voiceOn, a synth -> buffer -> input switch with its crossfades and cut, and voiceOff's release (difference %, reference peak %, the attack alone %)".format(whole[0], whole[1], peaks));
            }.value;
        });
    }.value;

    // Bypassed, against a verbatim copy of 3.2's grain defs
    {
        var settings = defaults.copy.putAll((amp: 0.7));
        [[1, "a buffer voice"], [engine.inputSource, "an input voice"]].do({ arg entry;
            var peaks, crossPeaks, whole;
            withComparison.(voice, { arg state;
                prepareVoice.(voice, entry[0], settings);
                0.5.wait;
                peaks = measureSpan.(state, 1.2, { voiceOnPair.(state, entry[0], settings) });
                server.makeBundle(nil, { state[\compare].set(\t_reset, 1); switchPair.(state, 2, settings) });
                1.2.wait; server.sync;
                crossPeaks = h.readBus(state[\peaks]);
                stopVoice.(state);
                check.((peaks[1] > silent) and: { peaks[0] < 1e-6 } and: { crossPeaks[1] > silent } and: { crossPeaks[0] < 1e-6 },
                    "mix: bypassed, a buffer voice and an input voice equal a verbatim copy of 3.2's grain defs within 1e-6 (%: steady state difference %, a crossfade %)".format(
                        entry[1], peaks[0], crossPeaks[0]));
            }, true);
        });
    }.value;

    checkAccentedCrossfade.value;
    checkFades.value;
    checkMirror.value;
    checkTap.value;
    checkBadStage.value;

    tone.free;
    command.(\setDelay, 0.375, 0.4, 0.0);
    command.(\setReverb, 0.3, 0.8, 0.5);
    [\filterType, 0, \filterFreq, 5000, \filterRes, 0.5, \filterMix, 0, \delaySend, 1, \reverbSend, 1].pairsDo({ arg name, value;
        command.(\setGrainParam, voice, name, value) });
    slotPaths.do(File.delete(_));
    2.do({ arg slot; command.(\clearBuffer, slot) });
};
h.stopAllVoices;
}
