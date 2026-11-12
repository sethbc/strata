// test/engine_check/modulation.scd
// The modulation area (lib/engine/StrataModulation.sc): its order, the
// fast-modulation buses and their addressing (fastModChannel,
// fastModBlock), the five commands (their checks, the nodes they make and
// the channels they write), the offset node at the head of fastModGroup,
// the engine LFOs' shapes and lifecycle, scatter, each destination's offset
// in the grain synths and the stage, the stage's gate and mute, and that
// with every bus at 0 the grain synths and the stage play exactly as 3.3's
// (check-only copies of 3.3's defs, as the mix area compares against 3.2's).
// See docs/notes/engine/modulation.md.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var area = engine.strataAreas.detect({ arg each; each[\name] == \modulation });
var state = engine.areaState[\modulation];
// the lines the engine posts for the commands it ignores
var ignoredLines = List.new;
// every voice's grain controls as the area found them (it puts them back)
var foundControls = engine.grainControls.collect(_.copy);
var shapeNames = [\Sine, \Tri, \Square, \Up, \Down, \Sah, \Smooth, \Drunk];
var lfoDefs = shapeNames.collect({ arg name; ("strataFastLfo" ++ name).asSymbol });
var areaDefs = lfoDefs ++ [\strataScatter, \strataFastOffsets];
var blockSeconds = server.options.blockSize / server.sampleRate;
var nodeCounts, childrenOf, sameReceived, channelBus, readChannel, readAll, groupNodes, lfoNodes, offsetNode;
var placeSynth, resetModulation, withOffsetsPaused, addCheckDefs, measureFor, loadNoiseSlot, noisePath;
var checkState, checkChannels, checkCommands, checkIgnored, checkBuses, checkFastModIn, checkGateControls;
var checkDefaults, checkVoicesLeft, checkOffsetNode, checkOffsetWrites, checkLfoSeries, checkLfoSums, checkShapes;
var checkSync, checkScatter, checkReleases, checkPitch, checkGrainTaps, checkGrainChannels, checkStageTaps;
var checkStageCutoff, checkStageAmp, checkEqual33, checkGates, checkGateEngine, checkMute, checkDefsSafe;
var checkVelocity, checkStartStop, checkGateKept, checkRegateEnded, stageArgs, ringArgs, bufArgs;
var checkScatterGlides, checkGateLag;

// [synths, groups] on the server, from one /status reply
nodeCounts = {
    var condition = Condition(false), reply;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/status.reply', server.addr).oneShot;
    server.sendMsg('/status');
    h.awaitReply(condition);
    reply !? { [reply[3], reply[4]] }
};

// A group's own children's node IDs, in order, from one /g_queryTree
childrenOf = { arg group;
    var condition = Condition(false), reply, children = List.new, index = 2, parse;
    OSCFunc({ arg msg; reply = msg; condition.test = true; condition.signal }, '/g_queryTree.reply', server.addr).oneShot;
    server.sendMsg('/g_queryTree', group.nodeID, 0);
    if (h.awaitReply(condition).not) { reply = [nil, 0, group.nodeID, 0] };
    parse = { arg depth;
        var nodeID = reply[index], numChildren = reply[index + 1];
        index = index + 2;
        if (numChildren == -1) { index = index + 1 } { numChildren.do({ parse.(depth + 1) }) };
        if (depth == 1) { children.add(nodeID) };
    };
    parse.(0);
    children.asArray
};

// Two records of what the commands received, key for key
sameReceived = { arg a, b;
    (a.size == b.size) and: { a.keys.every({ arg key; a[key] == b[key] }) }
};

// A fast-modulation channel as a one-channel Bus (no allocation), and its value
channelBus = { arg voice, destination; Bus.new(\control, engine.fastModChannel(voice, 0, destination), 1, server) };
readChannel = { arg voice, destination; h.readBusValue(channelBus.(voice, destination)) };
readAll = { h.readBus(state[\fastModBus]) };
// fastModGroup's synths in order (id, def, controls); its LFO nodes; its offset node
groupNodes = { state[\fastModGroup] !? { arg group; h.synthTree(group) } ? [] };
lfoNodes = { groupNodes.value.select({ arg node; lfoDefs.includes(node[\def]) }) };
offsetNode = { engine.synths[\fastOffsets] };
// The node an LFO's place holds (nil without one)
placeSynth = { arg lfo; state[\lfos] !? { arg places; places[lfo] !? { arg place; place[\synth] } } };

// Every LFO stopped, scatter released, every offset 0, and the lags and
// releases over (an area's checks start from this)
resetModulation = {
    6.do({ arg lfo; command.(\stopFastLfo, lfo) });
    command.(\setScatter, 0.0, 0.1, 0, 0);
    engine.numVoices.do({ arg voice; 5.do({ arg destination; command.(\setFastOffset, voice, 0, destination, 0.0) }) });
    server.sync; 0.7.wait; server.sync;
};

// body run with the offset node paused (it writes every channel first in
// every block, so a channel no other node writes holds its last value only
// while it is paused); it runs again however body ends
withOffsetsPaused = { arg body;
    var node = offsetNode.value;
    if (node.notNil) { server.sendMsg('/n_run', node.nodeID, 0) };
    server.sync;
    body.protect({ if (node.notNil) { server.sendMsg('/n_run', node.nodeID, 1) } });
};

// The check's own SynthDefs: taps on what the hooks compute, 3.3's grain
// defs and stage (the text of 3.3.2's, this. written engine., the helpers
// they call still the engine's own), a DC source, trackers and probes
addCheckDefs = {
    var silent = state[\silentFastModBus].index;
    var grainSignal33 = { arg controls, reader;
        var c = controls, env, modSigs, rateMod, bendRate, grainMode, mode, trig;
        var vary, rate, dur, read, panOffset, left, right, sig;
        env = EnvGen.kr(Env.asr(0.1, 1, engine.grainRelease), engine.openedGate(c[\gate]), doneAction: 2) * engine.killFade(c[\kill]);
        modSigs = c[\modBuses].collect({ arg bus; In.kr(bus, 1) });
        rateMod = engine.crossmodFreq(modSigs, c[\modFreqAmts]);
        bendRate = 1 + (c[\rateLevel] * ((c[\bend] * (1 + rateMod)) - 1));
        grainMode = c[\grainMode];
        mode = grainMode.round.clip(0, 1);
        trig = Trig1.ar(Select.ar(mode, [Impulse.ar(c[\grainDensity]), T2A.ar(c[\t_trig])]), engine.grainTriggerSeconds);
        vary = (
            reverseProb: c[\reverseProb], pitchJitter: c[\pitchJitter], intervals: c[\intervals],
            intervalCount: c[\intervalCount], intervalProb: c[\intervalProb], quantize: c[\quantize], scaleNote: c[\scaleNote]
        );
        rate = engine.grainRate(trig, c[\pitchShift], bendRate, vary);
        dur = engine.grainDur(trig, c[\grainSize], c[\sizeJitter]).min(engine.grainMaxSeconds);
        read = reader.value(trig, rate, dur, mode);
        panOffset = engine.grainPan(trig, c[\panJitter]);
        left = GrainBuf.ar(2, trig, read[\dur], read[\bufL], read[\rate], read[\pos], 2,
            (panOffset - 1).clip(-1, 1), c[\envBuf], engine.maxGrains);
        right = GrainBuf.ar(2, trig, read[\dur], read[\bufR], read[\rate], read[\pos], 2,
            (panOffset + 1).clip(-1, 1), c[\envBuf], engine.maxGrains);
        sig = left + right;
        sig = Balance2.ar(sig[0], sig[1], LFNoise1.kr(2).range(c[\panSpread].neg, c[\panSpread]));
        sig = engine.panBalance(sig, c[\pan]);
        Out.ar(c[\out], sig * (env * read[\level] * c[\ringLevel].lag(0.05)));
    };
    var controls33 = { arg out, gate, grainSize, grainDensity, pitchShift, posSpread, panSpread, envBuf, grainMode, t_trig, bend,
        kill, pan, rateLevel, modBus1, modBus2, modBus3, modFreqAmt1, modFreqAmt2, modFreqAmt3, ringLevel, reverseProb,
        pitchJitter, panJitter, sizeJitter, interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8,
        intervalCount, intervalProb, quantize, scaleNote;
        (
            out: out, gate: gate, grainSize: grainSize, grainDensity: grainDensity, pitchShift: pitchShift,
            posSpread: posSpread, panSpread: panSpread, envBuf: envBuf, grainMode: grainMode,
            t_trig: t_trig, bend: bend, kill: kill, pan: pan, rateLevel: rateLevel,
            modBuses: [modBus1, modBus2, modBus3], modFreqAmts: [modFreqAmt1, modFreqAmt2, modFreqAmt3],
            ringLevel: ringLevel, reverseProb: reverseProb, pitchJitter: pitchJitter, panJitter: panJitter,
            sizeJitter: sizeJitter,
            intervals: [interval1, interval2, interval3, interval4, interval5, interval6, interval7, interval8],
            intervalCount: intervalCount, intervalProb: intervalProb, quantize: quantize, scaleNote: scaleNote
        )
    };
    // what the grain hooks compute: [pitchShift, bufPos, grainSize]
    SynthDef(\strataCheckFastTaps, { arg out, pitchShift = 1, bufPos = 0.3, grainSize = 0.1;
        var m = engine.fastModRead(\fastModIn.kr(silent));
        var c = engine.fastMod((pitchShift: pitchShift, grainSize: grainSize, fastMod: m));
        Out.kr(out, [c[\pitchShift], engine.fastModPosition(bufPos, m), c[\grainSize]].collect({ arg value;
            if (value.isNumber) { DC.kr(value) } { value } }));
    }).add;
    // what voiceMixMod computes: [filterFreq, ampOffset, voiceGate]
    SynthDef(\strataCheckStageTaps, { arg out, filterFreq = 1000, t_trig = 0, velocity = 1;
        var c = engine.voiceMixMod((filterFreq: filterFreq, t_trig: t_trig, velocity: velocity, amp: 1));
        Out.kr(out, [c[\filterFreq], c[\ampOffset], c[\voiceGate]].collect({ arg value;
            if (value.isNumber) { DC.kr(value) } { value } }));
    }).add;
    SynthDef(\strataCheckGrainRing33, {
        arg out, gate=1, bufL=0, bufR=0, phaseBus=0, bufScan=0,
        grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
        envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
        modBus1=0, modBus2=0, modBus3=0,
        modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
        history=0, ringLevel=1, freeze=0, freezeMode=0,
        reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
        interval1=0, interval2=0, interval3=0, interval4=0,
        interval5=0, interval6=0, interval7=0, interval8=0,
        intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
        loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0;
        var controls = controls33.(out, gate, grainSize, grainDensity, pitchShift, posSpread, panSpread, envBuf, grainMode, t_trig,
            bend, kill, pan, rateLevel, modBus1, modBus2, modBus3, modFreqAmt1, modFreqAmt2, modFreqAmt3, ringLevel, reverseProb,
            pitchJitter, panJitter, sizeJitter, interval1, interval2, interval3, interval4, interval5, interval6, interval7,
            interval8, intervalCount, intervalProb, quantize, scaleNote);
        grainSignal33.(controls, engine.ringGrainReader(bufL, bufR, phaseBus, posSpread, history, bufScan, freeze));
    }).add;
    SynthDef(\strataCheckGrainBuf33, {
        arg out, gate=1, bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0,
        grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
        envBuf = -1, grainMode=0, t_trig=0, bend=1, kill=0, pan=0, rateLevel=1,
        modBus1=0, modBus2=0, modBus3=0,
        modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
        history=0, ringLevel=1, freeze=0, freezeMode=0,
        reverseProb=0, pitchJitter=0, panJitter=0, sizeJitter=0,
        interval1=0, interval2=0, interval3=0, interval4=0,
        interval5=0, interval6=0, interval7=0, interval8=0,
        intervalCount=0, intervalProb=1, quantize=0, scaleNote=60,
        loopStart=0, loopLength=1, scrubRate=0, scanHold=0, t_scanReset=0;
        var recHeadBus = \recHeadBus.kr(engine.areaState[\record][\idleHead].index);
        var controls = controls33.(out, gate, grainSize, grainDensity, pitchShift, posSpread, panSpread, envBuf, grainMode, t_trig,
            bend, kill, pan, rateLevel, modBus1, modBus2, modBus3, modFreqAmt1, modFreqAmt2, modFreqAmt3, ringLevel, reverseProb,
            pitchJitter, panJitter, sizeJitter, interval1, interval2, interval3, interval4, interval5, interval6, interval7,
            interval8, intervalCount, intervalProb, quantize, scaleNote);
        grainSignal33.(controls, engine.slotGrainReader(bufnumL, bufnumR, bufFrames, bufRateScale, bufPos, bufRate,
            bufScan, posSpread, freeze, loopStart, loopLength, scrubRate, scanHold, t_scanReset, recHeadBus));
    }).add;
    SynthDef(\strataCheckVoiceMix33, {
        arg synthIn, otherIn, out, mirrorOut, amp=1, modBus1=0, modBus2=0, modBus3=0,
        modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0, t_trig=0, velocity=1,
        filterType=0, filterFreq=5000, filterRes=0.5, filterMix=0, delaySend=1, reverbSend=1;
        var c = (
            synthIn: synthIn, otherIn: otherIn, out: out, mirrorOut: mirrorOut,
            tapOut: \tapOut.kr(engine.areaState[\record][\tapSink].index),
            amp: amp, modBuses: [modBus1, modBus2, modBus3], modAmpAmts: [modAmpAmt1, modAmpAmt2, modAmpAmt3],
            t_trig: t_trig, velocity: velocity, filterType: filterType, filterFreq: filterFreq, filterRes: filterRes,
            filterMix: filterMix, delaySend: delaySend, reverbSend: reverbSend
        );
        var guard = { arg signal; signal.collect({ arg channel; engine.zeroBadValues(channel) }) };
        var synthPath = guard.(In.ar(c[\synthIn], 2)), otherPath = guard.(In.ar(c[\otherIn], 2));
        var raw = engine.voiceFilter(synthPath ++ otherPath, c[\filterType], c[\filterFreq], c[\filterRes], c[\filterMix]);
        var filtered = guard.(raw);
        var modSig = engine.crossmodAmp(c[\modBuses].collect({ arg bus; In.kr(bus, 1) }), c[\modAmpAmts]);
        var accent = engine.voiceAccent(c[\t_trig], c[\velocity]);
        var other = filtered.drop(2) * engine.voiceLevel(c[\amp], modSig, accent);
        var sig = filtered.keep(2) + other;
        engine.voiceOutput(sig, c[\out], c[\delaySend], c[\reverbSend]);
        Out.ar(c[\mirrorOut], other);
        Out.ar(c[\tapOut], sig);
    }).add;
    SynthDef(\strataCheckDC, { arg out, level = 0.5; Out.ar(out, DC.ar(level) ! 2) }).add;
    // a control channel's value, and while `seconds` after t_reset run: how
    // many blocks it changed in (each change's first block), its largest
    // step from one block to the next, its lowest and highest
    SynthDef(\strataCheckKrTrack, { arg in, out, t_reset = 0, seconds = 2;
        var x = In.kr(in, 1), step = (x - Delay1.kr(x)).abs, active = Sweep.kr(t_reset, 1) < seconds;
        Out.kr(out, [x, PulseCount.kr((step > 1e-6) * active, t_reset), Peak.kr(step * active, t_reset),
            RunningMin.kr(Select.kr(active, [1e9, x]), t_reset), RunningMax.kr(Select.kr(active, [-1e9, x]), t_reset)]);
    }).add;
    // the ratio of two audio buses' left channels, block by block: now, its
    // lowest in the first minTime after t_reset, at `times` after it
    // (latched), and last the ratio of the block before t_reset's (latched at
    // the reset: a trigger sent in the reset's bundle acts in the reset's
    // block, so this is the level just before the trigger). Seven channels
    SynthDef(\strataCheckRatioTrack, { arg a, b, out, t_reset = 0, minTime = 0.07;
        var x = A2K.kr(In.ar(a, 1)), y = A2K.kr(In.ar(b, 1));
        var ratio = x / y.abs.max(1e-9), elapsed = Sweep.kr(t_reset, 1), times = \times.kr(0 ! 4);
        Out.kr(out, [ratio, Latch.kr(RunningMin.kr(ratio, t_reset), elapsed >= minTime)]
            ++ times.collect({ arg time; Latch.kr(ratio, elapsed >= time) }) ++ [Latch.kr(Delay1.kr(ratio), t_reset)]);
    }).add;
    // the pitch of a stereo bus (its sum) and whether it has one
    SynthDef(\strataCheckPitch, { arg in, out;
        Out.kr(out, Pitch.kr(In.ar(in, 2).sum, minFreq: 60, maxFreq: 4000, median: 7, ampThreshold: 0.001));
    }).add;
    // a 3 Hz sine on one control bus and the same sine plus shift on another
    SynthDef(\strataCheckModPair, { arg outA, outB, shift = 0;
        var sine = SinOsc.kr(3);
        Out.kr(outA, sine);
        Out.kr(outB, sine + shift);
    }).add;
    // ten channels (a stage's dry, delay send, reverb send, mirror and tap):
    // the largest |a - scale x b| and the largest |b|, since t_reset
    SynthDef(\strataCheckStageDiff, { arg a, b, out, scale = 1, t_reset = 0;
        var x = In.ar(a, 10), y = In.ar(b, 10);
        Out.kr(out, [A2K.kr(Peak.ar((x - (y * scale)).abs.reduce(\max), t_reset)), A2K.kr(Peak.ar(y.abs.reduce(\max), t_reset))]);
    }).add;
    // the whole fast-modulation bus, block by block, since t_reset: the
    // largest step of any channel from one block to the next, and the
    // largest value of any channel
    SynthDef(\strataCheckBusStep, { arg in, out, t_reset = 0;
        var x = In.kr(in, state[\fastModBus].numChannels), step = (x - Delay1.kr(x)).abs;
        Out.kr(out, [Peak.kr(step.reduce(\max), t_reset), Peak.kr(x.abs.reduce(\max), t_reset)]);
    }).add;
    // the ratio of two audio buses' left channels, block by block (each
    // block's first sample), and its largest step from one block to the
    // next since t_reset
    SynthDef(\strataCheckRatioStep, { arg a, b, out, t_reset = 0;
        var ratio = A2K.kr(In.ar(a, 1)) / A2K.kr(In.ar(b, 1)).abs.max(1e-9);
        Out.kr(out, [ratio, Peak.kr((ratio - Delay1.kr(ratio)).abs, t_reset)]);
    }).add;
    server.sync;
};

// Reset a [difference, level] probe, wait, read it
measureFor = { arg probe, bus, seconds = 0.4; h.measure(probe, bus, seconds) };

// A slot of noise at the server rate (a grain's place shows in what it reads)
noisePath = h.tempDir +/+ "modulation-noise.wav";
loadNoiseSlot = { arg slot;
    var rate = server.sampleRate.round.asInteger;
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    if (File.exists(noisePath).not) {
        file.openWrite(noisePath);
        file.writeData(h.stereoOf(h.noise(rate, 0.5), h.noise(rate, 0.4)));
        file.close;
    };
    command.(\loadBuffer, slot, noisePath, 0);
    h.waitFor({ engine.bufferFrames[slot] == rate }, 3);
    server.sync;
};

// A check stage's controls: its ten outputs on outBus (dry, delay send,
// reverb send, mirror, tap), its inputs, silent mod slots, then extra
stageArgs = { arg outBus, synthIn, otherIn, extra;
    [\synthIn, synthIn, \otherIn, otherIn, \out, outBus.index, \delaySendOut, outBus.index + 2, \reverbSendOut, outBus.index + 4,
        \mirrorOut, outBus.index + 6, \tapOut, outBus.index + 8, \fxMixIn, engine.mixBus(\fxMix).index,
        \modBus1, engine.silentBus.index, \modBus2, engine.silentBus.index, \modBus3, engine.silentBus.index,
        \fastModIn, state[\silentFastModBus].index] ++ (extra ? [])
};
// A check grain synth's controls on a voice's ring (as its synth source's)
// or a slot, every draw off, then extra
ringArgs = { arg outBus, voice, extra;
    var ring = engine.ringBuffersFor(voice, 0);
    [\out, outBus.index, \bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index, \grainSize, 0.1, \grainDensity, 20,
        \pitchShift, 1, \posSpread, 0, \panSpread, 0, \rateLevel, 0, \pan, 0, \fastModIn, state[\silentFastModBus].index] ++ (extra ? [])
};
bufArgs = { arg outBus, slot, extra;
    [\out, outBus.index, \bufnumL, engine.buffersL[slot].bufnum, \bufnumR, engine.buffersR[slot].bufnum,
        \bufFrames, engine.bufferFrames[slot], \bufRateScale, engine.bufferRateScale(slot), \bufPos, 0.3,
        \grainSize, 0.1, \grainDensity, 20, \pitchShift, 1, \posSpread, 0, \panSpread, 0, \pan, 0,
        \fastModIn, state[\silentFastModBus].index] ++ (extra ? [])
};

// The area, its order and its state as alloc leaves it
checkState = {
    check.(area.notNil and: { area[\order] == 160 }, "modulation: the area runs at order 160 (got %)".format(area !? { area[\order] }));
    check.((engine.numFastDestinations == 5) and: { engine.fastModNoteSlots == 1 } and: { engine.numFastLfos == 6 }
        and: { state[\fastModBus].numChannels == 35 } and: { state[\fastModBus].rate == \control }
        and: { state[\silentFastModBus].numChannels == 5 } and: { state[\silentFastModBus].rate == \control }
        and: { state[\silentFastModBus].index != state[\fastModBus].index }
        and: { state[\lfos] == [nil, nil, nil, nil, nil, nil] } and: { state[\scatter].isNil },
        "modulation: the area holds a 35-channel fastModBus, a 5-channel silentFastModBus, six empty LFO places and no scatter (%, %, %)".format(
            state[\fastModBus] !? _.numChannels, state[\silentFastModBus] !? _.numChannels, state[\lfos]));
};

// fastModChannel(v, n, d) = index + (v x slots + n) x 5 + d, through
// fastModChannelFor with this engine's one slot and with six
checkChannels = {
    var index = state[\fastModBus].index;
    var voices = (0 .. engine.numVoices - 1), destinations = (0 .. 4);
    var got = voices.collect({ arg v; destinations.collect({ arg d; engine.fastModChannel(v, 0, d) }) }).flatten;
    var expected = voices.collect({ arg v; destinations.collect({ arg d; index + (5 * v) + d }) }).flatten;
    var blocks = voices.collect({ arg v; engine.fastModBlock(v, 0) });
    var six = voices.collect({ arg v; (0 .. 5).collect({ arg n; destinations.collect({ arg d;
        engine.fastModChannelFor(v, n, d, 6) - index }) }) }).flatten(2);
    var sixExpected = voices.collect({ arg v; (0 .. 5).collect({ arg n; destinations.collect({ arg d;
        (((v * 6) + n) * 5) + d }) }) }).flatten(2);
    check.((got == expected) and: { blocks == voices.collect({ arg v; index + (5 * v) }) }
        and: { (six == sixExpected) and: { six.asSet.size == 210 } and: { six.minItem == 0 } and: { six.maxItem == 209 } },
        "modulation: fastModChannel is index + (v × slots + n) × 5 + d for every voice, slot and destination (one slot: %; six: % distinct, % to %)".format(
            got - index, six.asSet.size, six.minItem, six.maxItem));
};

// The offset node: one \strataFastOffsets at the head of fastModGroup,
// writing the whole bus, persistent (its key is an effectKey), the same
// node from the area's first check to its last (startStop checks the
// area's start and stop on an engine of its own)
checkOffsetNode = { arg label, firstID;
    var nodes = groupNodes.value, node = offsetNode.value;
    var offsets = nodes.select({ arg each; each[\def] == \strataFastOffsets });
    check.(node.notNil and: { nodes.notEmpty } and: { nodes[0][\def] == \strataFastOffsets } and: { offsets.size == 1 }
        and: { nodes[0][\id] == node.nodeID } and: { nodes[0][\controls][\out] == state[\fastModBus].index }
        and: { engine.effectKeys.includes(\fastOffsets) } and: { firstID.isNil or: { firstID == node.nodeID } },
        "modulation: one offset node at the head of fastModGroup from start to stop (%: fastModGroup holds %, the node %, writing %, first %)".format(
            label, nodes.collect(_[\def]), node !? _.nodeID, nodes.first !? { arg each; each[\controls][\out] }, firstID));
    node !? _.nodeID
};

// setFastOffset through the offset node: the value on its channel after the
// lag (50 ms), clamped to ±2, every other channel untouched; and an offset
// and an engine LFO on one channel add
checkOffsetWrites = {
    var others, values, sum, clamped;
    command.(\setFastOffset, 2, 0, 0, 0.5);
    server.sync; 0.2.wait;
    values = readAll.value;
    others = values.reject({ arg value, index; index == (engine.fastModChannel(2, 0, 0) - state[\fastModBus].index) });
    check.((values.size == 35) and: { (readChannel.(2, 0) - 0.5).abs < 0.001 } and: { others.every(_ == 0) },
        "modulation: setFastOffset(2, 0, 0, 0.5) reads 0.5 on its channel after the lag (got %, % other channels at 0)".format(
            readChannel.(2, 0), others.count(_ == 0)));
    command.(\setFastOffset, 3, 0, 4, 7.0);
    server.sync; 0.2.wait;
    clamped = readChannel.(3, 4);
    command.(\setFastOffset, 3, 0, 4, 0.0);
    // a sine LFO of depth 0.25 at phase 0.25 (its peak) on the same channel
    command.(\setFastLfo, 0, 2, 0, 0, 0.003, 0.25, 0.0);
    command.(\syncFastLfo, 0, 0.25);
    server.sync; 0.2.wait;
    sum = readChannel.(2, 0);
    check.(((sum - 0.75).abs < 0.01) and: { (clamped - 2).abs < 0.001 },
        "modulation: an offset and an engine LFO on one channel add (0.5 + 0.25: got %; an offset of 7 reads %)".format(sum, clamped));
    resetModulation.value;
};

// The commands' signatures, and the valid calls: each is recorded with its
// continuous arguments clipped; only setFastLfo and setScatter make nodes,
// and only in fastModGroup
checkCommands = {
    var signatures = [[\setFastLfo, "iiiifff"], [\stopFastLfo, "i"], [\syncFastLfo, "if"], [\setScatter, "ffii"], [\setFastOffset, "iiif"]];
    // [the call, what the command records]
    var calls = [
        [[\setFastLfo, 0, 0, 0, 0, 1.0, 0.5, 0.0], [0, 0, 0, 0, 1.0, 0.5, 0.0]],
        [[\setFastLfo, 5, 6, 4, 7, 50.0, 1.0, -2.0], [5, 6, 4, 7, 50.0, 1.0, -2.0]],
        [[\setFastLfo, 1, 2, 3, 4, 0.001, -0.5, -3.0], [1, 2, 3, 4, 0.003, 0.0, -2.0]],
        [[\setFastLfo, 1, 2, 3, 4, 80.0, 1.5, 2.5], [1, 2, 3, 4, 50.0, 1.0, 2.0]],
        [[\stopFastLfo, 0], [0]],
        [[\syncFastLfo, 5, 1.0], [5, 1.0]],
        [[\syncFastLfo, 2, 1.5], [2, 1.0]],
        [[\syncFastLfo, 2, -0.5], [2, 0.0]],
        [[\setScatter, 0.5, 0.1, 31, 127], [0.5, 0.1, 31, 127]],
        [[\setScatter, 1.5, 0.001, 0, 0], [1.0, 0.01, 0, 0]],
        [[\setScatter, -0.5, 2.0, 3, 5], [0.0, 1.0, 3, 5]],
        [[\setFastOffset, 6, 0, 4, 2.0], [6, 0, 4, 2.0]],
        [[\setFastOffset, 0, 0, 0, 2.5], [0, 0, 0, 2.0]],
        [[\setFastOffset, 3, 0, 1, -7.0], [3, 0, 1, -2.0]]
    ];
    var outside = { var counts = nodeCounts.value; counts !? { [counts[0] - groupNodes.value.size, counts[1]] } };
    var before = outside.value, counts = List.new, recorded = List.new;
    check.(signatures.every({ arg pair; h.formatOf(pair[0]) == pair[1] }),
        "modulation: the five commands exist with their signatures (got %)".format(signatures.collect({ arg pair; h.formatOf(pair[0]) })));
    calls.do({ arg call;
        command.(*call[0]);
        server.sync;
        counts.add(outside.value);
        recorded.add(state[\received][call[0][0]] == call[1]);
    });
    check.(before.notNil and: { counts.every({ arg each; each == before }) },
        "modulation: no command makes a node outside fastModGroup (synths and groups outside it before %, after each %)".format(
            before, counts.asSet.asArray));
    check.(recorded.every(_ == true),
        "modulation: each command records its arguments, the continuous ones clipped (%)".format(
            calls.collect({ arg call; call[0][0] }).select({ arg name, index; recorded[index].not })));
    resetModulation.value;
};

// Step 1's out-of-range indices and every continuous argument's non-finite
// value (NaN passes clip): each posts one line, records nothing and creates
// no node
checkIgnored = {
    var nan = 0.0 / 0.0;
    var lfo = { arg lfo, voice, destination, shape; [\setFastLfo, lfo, voice, destination, shape, 1.0, 0.5, 0.0] };
    var bad = [
        lfo.(6, 0, 0, 0), lfo.(-1, 0, 0, 0), lfo.(0, 7, 0, 0), lfo.(0, -1, 0, 0), lfo.(0, 0, 5, 0), lfo.(0, 0, -1, 0),
        lfo.(0, 0, 0, 8), lfo.(0, 0, 0, -1), lfo.(0.5, 0, 0, 0),
        [\setFastLfo, 0, 0, 0, 0, nan, 0.5, 0.0], [\setFastLfo, 0, 0, 0, 0, 1.0, nan, 0.0], [\setFastLfo, 0, 0, 0, 0, 1.0, 0.5, nan],
        [\setFastLfo, 0, 0, 0, 0, inf, 0.5, 0.0], [\setFastLfo, 0, 0, 0, 0, 1.0, 0.5, inf.neg],
        [\stopFastLfo, 6], [\stopFastLfo, -1], [\syncFastLfo, 6, 0.5], [\syncFastLfo, -1, 0.5],
        [\syncFastLfo, 0, nan], [\syncFastLfo, 0, inf],
        [\setScatter, 0.1, 0.1, 32, 127], [\setScatter, 0.1, 0.1, -1, 127], [\setScatter, 0.1, 0.1, 3, 128], [\setScatter, 0.1, 0.1, 3, -1],
        [\setScatter, nan, 0.1, 3, 127], [\setScatter, 0.1, nan, 3, 127], [\setScatter, inf, 0.1, 3, 127],
        [\setFastOffset, 7, 0, 0, 0.0], [\setFastOffset, -1, 0, 0, 0.0], [\setFastOffset, 0, 1, 0, 0.0], [\setFastOffset, 0, -1, 0, 0.0],
        [\setFastOffset, 0, 0, 5, 0.0], [\setFastOffset, 0, 0, -1, 0.0],
        [\setFastOffset, 0, 0, 0, nan], [\setFastOffset, 0, 0, 0, inf], [\setFastOffset, 0, 0, 0, inf.neg]
    ];
    var kept = state[\received].deepCopy, before = nodeCounts.value, lines = List.new, unchanged = List.new;
    state[\postIgnored] = { arg line; ignoredLines.add(line) };
    bad.do({ arg call;
        var count = ignoredLines.size;
        command.(*call);
        lines.add(ignoredLines.size - count);
        unchanged.add(sameReceived.(state[\received], kept));
    });
    server.sync;
    state[\postIgnored] = nil;
    check.(unchanged.every(_ == true) and: { lines.every(_ == 1) } and: { nodeCounts.value == before }
        and: { ignoredLines.every({ arg line; line.beginsWith("strata: ") }) } and: { readAll.value.every(_ == 0) },
        "modulation: out-of-range indices and non-finite values are ignored, one line each, and change no channel (changed by %; lines %)".format(
            bad.select({ arg call, index; unchanged[index].not }), lines.asSet.asArray));
};

// Every channel reads 0 once the commands' nodes are gone, and fastModGroup
// is the first node of xg, before voiceGroup, holding the offset node alone
checkBuses = {
    var values = readAll.value, silent = h.readBus(state[\silentFastModBus]);
    var children = childrenOf.(context.xg), group = state[\fastModGroup], inside = groupNodes.value;
    check.((values.size == 35) and: { values.every(_ == 0) } and: { silent.size == 5 } and: { silent.every(_ == 0) },
        "modulation: every fast-modulation channel reads 0 (% of 35 and % of the silent bus's 5 at 0)".format(
            values.count(_ == 0), silent.count(_ == 0)));
    check.(group.notNil and: { children.size > 1 } and: { children[0] == group.nodeID } and: { children[1] == engine.voiceGroup.nodeID }
        and: { inside.collect(_[\def]) == [\strataFastOffsets] },
        "modulation: fastModGroup sits before voiceGroup, at the head of xg, with the offset node alone once LFOs and scatter end (xg's first nodes %, fastModGroup %, voiceGroup %, holding %)".format(
            children.keep(2), group !? _.nodeID, engine.voiceGroup.nodeID, inside.collect(_[\def])));
};

// Starts, shape changes, moves, sets and stops of the six LFOs at 20 Hz for
// 2 s (seeded): 40 steps, each sent 50 ms after the last began (a deadline
// from the series' start, so a slow step never slows the rest), with starts
// and shape changes also sent in the same tick as a stop, so they reach an
// LFO in its release. One tree read a step, asked for in the same tick as
// the step's commands, with no sync between (a sync takes about 27 ms here,
// past the release): the server answers it after the commands, in order, and
// the places' nodes are taken as the commands leave them. Each read asserts
// the bound: every LFO node on the server is its LFO's place's node, so at
// most one per LFO, a releasing one included (a start re-gates it; a shape
// change frees it as the new node starts, or replaces a running one in one
// server step); each running LFO has exactly one, of its shape and writing
// its channel; and each LFO stopped in the step before, 50 ms earlier, past
// its 20 ms release, has none and no place. None once all are stopped
checkLfoSeries = {
    var steps = 40, period = 0.05, wrong = List.new, maxNodes = 0, maxReleasing = 0, actions = Bag.new, settings = Array.newClear(6);
    var stoppedBefore = [], times = List.new(steps), queries = List.new(steps), t0, final, places, span;
    thisThread.randSeed = 3401;
    t0 = Main.elapsedTime;
    steps.do({ arg step;
        var stopped = List.new, own, releasing, nodes, ids, running, queryStart;
        ((t0 + (period * step)) - Main.elapsedTime).max(0).wait;
        times.add(Main.elapsedTime - t0);
        6.do({ arg lfo;
            var action = [\start, \shape, \move, \set, \stop, \restart, \reshape, \none].wchoose(
                [0.2, 0.12, 0.12, 0.12, 0.18, 0.1, 0.1, 0.06].normalizeSum);
            var current = settings[lfo];
            if (current.isNil and: { [\shape, \move, \set, \restart, \reshape].includes(action) }) { action = \start };
            actions.add(action);
            switch (action)
            { \start } { current = [7.rand, 5.rand, 8.rand, exprand(0.1, 50.0), 1.0.rand, 0.5.rand2] }
            { \shape } { current = current.copy.put(2, (current[2] + 1 + 6.rand) % 8) }
            { \move } { current = current.copy.put(0, 7.rand).put(1, 5.rand) }
            { \set } { current = current.copy.put(3, exprand(0.1, 50.0)).put(4, 1.0.rand) }
            { \stop } { current = nil; command.(\stopFastLfo, lfo); stopped.add(lfo) }
            // (into its release: the same settings, or a new shape)
            { \restart } { command.(\stopFastLfo, lfo) }
            { \reshape } { command.(\stopFastLfo, lfo); current = current.copy.put(2, (current[2] + 1 + 6.rand) % 8) };
            if (current.notNil and: { action != \none }) { command.(\setFastLfo, lfo, *current) };
            settings[lfo] = current;
        });
        own = (0 .. 5).collect({ arg lfo; placeSynth.(lfo) !? _.nodeID });
        releasing = (0 .. 5).select({ arg lfo; state[\lfos][lfo] !? { arg place; place[\running].not } ? false })
            .collect({ arg lfo; own[lfo] });
        queryStart = Main.elapsedTime;
        nodes = lfoNodes.value;
        queries.add(Main.elapsedTime - queryStart);
        ids = nodes.collect(_[\id]);
        running = settings.collect({ arg each, lfo; if (each.notNil) { [lfo, each] } }).reject(_.isNil);
        maxNodes = maxNodes.max(ids.size);
        maxReleasing = maxReleasing.max(ids.count({ arg id; releasing.includes(id) }));
        if ((ids.asSet.size != ids.size) or: { ids.any({ arg id; own.includes(id).not }) }
            or: { running.any({ arg pair;
                var node = nodes.detect({ arg each; each[\id] == own[pair[0]] });
                node.isNil or: { node[\def] != lfoDefs[pair[1][2]] }
                    or: { node[\controls][\out] != engine.fastModChannel(pair[1][0], 0, pair[1][1]) } }) }
            or: { stoppedBefore.any({ arg lfo; settings[lfo].isNil and: { own[lfo].notNil } }) }) {
            wrong.add([step, ids.size, running.size]);
        };
        stoppedBefore = stopped;
    });
    span = times.last - times.first;
    6.do({ arg lfo; command.(\stopFastLfo, lfo) });
    0.1.wait; server.sync;
    final = lfoNodes.value;
    places = state[\lfos] ? [0];
    check.(wrong.isEmpty and: { maxNodes <= 6 } and: { maxReleasing > 0 } and: { final.isEmpty } and: { places.every(_.isNil) }
        and: { readAll.value.every(_ == 0) },
        "modulation: one node per LFO through starts, shape changes, moves and stops at 20 Hz for 2 s, and none once stopped (% steps sent over % s, the slowest tree read % s; at each step's commands every LFO node is its place's, a releasing one included, each running LFO has one, of its shape on its channel, and each stopped a step before has none: steps wrong %, at most % LFO nodes and % releasing at once, % left, actions %)".format(
            steps, span.round(0.001), queries.maxItem.round(0.001), wrong.keep(4), maxNodes, maxReleasing, final.size, actions.contents));
    resetModulation.value;
};

// Two LFOs on one channel add; with the offset node paused (so only the
// LFOs write the channel), a stopped LFO's channel returns to 0 while
// another on it keeps writing, and a moved LFO zeroes its old channel
checkLfoSums = {
    var both, one, none, moved;
    command.(\setFastLfo, 1, 4, 1, 0, 0.003, 0.2, 0.0);
    command.(\setFastLfo, 2, 4, 1, 0, 0.003, 0.3, 0.0);
    [1, 2].do({ arg lfo; command.(\syncFastLfo, lfo, 0.25) });
    server.sync; 0.2.wait;
    both = readChannel.(4, 1);
    check.((both - 0.5).abs < 0.01, "modulation: two LFOs on one channel add (0.2 + 0.3: got %)".format(both));
    withOffsetsPaused.({
        command.(\stopFastLfo, 1);
        server.sync; 0.1.wait;
        one = readChannel.(4, 1);
        command.(\stopFastLfo, 2);
        server.sync; 0.1.wait;
        none = readChannel.(4, 1);
        check.(((one - 0.3).abs < 0.01) and: { none == 0 },
            "modulation: a stopped LFO's channel returns to 0 while another on it keeps writing (one left: %; none: %)".format(one, none));
        command.(\setFastLfo, 3, 3, 1, 0, 0.003, 0.4, 0.0);
        command.(\syncFastLfo, 3, 0.25);
        server.sync; 0.2.wait;
        command.(\setFastLfo, 3, 3, 2, 0, 0.003, 0.4, 0.0);
        server.sync; 0.1.wait;
        moved = [readChannel.(3, 1), readChannel.(3, 2)];
        command.(\stopFastLfo, 3);
        server.sync; 0.1.wait;
    });
    check.((moved[0] == 0) and: { (moved[1] - 0.4).abs < 0.01 },
        "modulation: an LFO moved to another destination zeroes its old channel (old %, new %)".format(*moved));
    resetModulation.value;
};

// Each shape at fixed phases (rate 0.003 Hz: a 333 s cycle, so the phase
// holds while it is read), depth 0.4 and offset 0.1: (2u - 1) x depth +
// offset; then, on the server, s&h's one value per cycle and smooth's and
// drunk's steps, never more than their per-block slope
checkShapes = {
    // [shape, phase, expected]
    var points = [
        [0, 0.25, 0.5], [0, 0.75, -0.3], [0, 0.0, 0.1],
        [1, 0.25, 0.1], [1, 0.5, 0.5], [1, 0.0, -0.3],
        [2, 0.25, 0.5], [2, 0.75, -0.3],
        [3, 0.25, -0.1], [3, 0.75, 0.3],
        [4, 0.25, 0.3], [4, 0.75, -0.1]
    ];
    var got = points.collect({ arg point;
        command.(\setFastLfo, 0, 1, 2, point[0], 0.003, 0.4, 0.1);
        command.(\syncFastLfo, 0, point[1]);
        server.sync; 0.12.wait;
        readChannel.(1, 2)
    });
    var bad = points.select({ arg point, index; (got[index] - point[2]).abs >= 0.005 });
    var trackBus = Bus.control(server, 5), track, results = IdentityDictionary.new, rate = 2.0, inc = rate * blockSeconds;
    check.(bad.isEmpty and: { got.size == points.size },
        "modulation: the shapes: sine at phase 0.25 reads depth + offset, square at 0.75 -depth + offset, and tri, up and down at their phases (wrong: %)".format(
            bad.collect({ arg point; [shapeNames[point[0]], point[1], point[2], got[points.indexOf(point)].round(0.0001)] })));
    command.(\stopFastLfo, 0);
    server.sync; 0.1.wait;
    track = Synth(\strataCheckKrTrack, [\in, channelBus.(1, 2).index, \out, trackBus.index, \seconds, 2.0], engine.processGroup, \addToTail);
    // s&h, smooth and drunk at 2 Hz, depth 1: synced to phase 0.5, then
    // tracked for 2 s from 50 ms later (wraps at 0.25, 0.75, 1.25, 1.75 s)
    [5, 6, 7].do({ arg shape;
        command.(\setFastLfo, 0, 1, 2, shape, rate, 1.0, 0.0);
        server.sync; 0.6.wait;
        server.makeBundle(0.1, { command.(\syncFastLfo, 0, 0.5) });
        server.makeBundle(0.15, { track.set(\t_reset, 1) });
        2.4.wait; server.sync;
        results[shape] = h.readBus(trackBus);
        command.(\stopFastLfo, 0);
        server.sync; 0.1.wait;
    });
    track.free;
    trackBus.free;
    // [value, changes, largest step, lowest, highest]
    check.((results[5][1] == 4) and: { results[5][2] > 0.01 },
        "modulation: the shapes: s&h holds one value through a cycle and draws at the wrap (4 wraps in 2 s: % changes, largest %)".format(
            results[5][1], results[5][2].round(0.0001)));
    check.((results[6][2] > 0) and: { results[6][2] <= (2 * inc * 1.001) } and: { results[7][2] > 0 } and: { results[7][2] <= (2 * 0.2 * inc * 1.001) }
        and: { results[6][3] >= -1.0001 } and: { results[6][4] <= 1.0001 } and: { results[7][3] >= -1.0001 } and: { results[7][4] <= 1.0001 },
        "modulation: the shapes: smooth and drunk never jump by more than their per-block slope (smooth % of %, drunk % of %; ranges % and %)".format(
            results[6][2].round(0.00001), (2 * inc).round(0.00001), results[7][2].round(0.00001), (0.4 * inc).round(0.00001),
            results[6].copyRange(3, 4).round(0.001), results[7].copyRange(3, 4).round(0.001)));
    resetModulation.value;
};

// syncFastLfo sets the phase of a running LFO, and is a no-op without one
checkSync = {
    var values, before;
    command.(\setFastLfo, 4, 0, 3, 0, 0.003, 0.4, 0.0);
    values = [0.25, 0.75, 0.0].collect({ arg phase;
        command.(\syncFastLfo, 4, phase);
        server.sync; 0.1.wait;
        readChannel.(0, 3)
    });
    command.(\stopFastLfo, 4);
    server.sync; 0.1.wait;
    before = nodeCounts.value;
    command.(\syncFastLfo, 4, 0.5);
    server.sync;
    check.(((values[0] - 0.4).abs < 0.005) and: { (values[1] + 0.4).abs < 0.005 } and: { values[2].abs < 0.005 }
        and: { nodeCounts.value == before } and: { placeSynth.(4).isNil },
        "modulation: syncFastLfo sets the phase (sine at 0.25, 0.75, 0: %), and without a node makes none".format(values.round(0.0001)));
    resetModulation.value;
};

// Scatter: its masks reach only their channels; its end zeroes its
// channels (with the offset node paused, so only scatter writes them)
checkScatter = {
    var reached, nodes, after, inMask;
    // destinations 0 and 2 on voices 1 and 2
    command.(\setScatter, 0.8, 1.0, 5, 6);
    server.sync; 1.0.wait;
    reached = readAll.value;
    nodes = groupNodes.value.count({ arg node; node[\def] == \strataScatter });
    inMask = { arg index; [1, 2].includes(index div: 5) and: { [0, 2].includes(index % 5) } };
    check.((nodes == 1) and: { reached.every({ arg value, index; if (inMask.(index)) { value != 0 } { value == 0 } }) }
        and: { reached.every({ arg value; value.abs <= (0.8 * 1.5) }) },
        "modulation: setScatter writes only the masks' channels, at most about depth (% scatter nodes; nonzero channels %)".format(
            nodes, reached.selectIndices({ arg value; value != 0 })));
    command.(\setScatter, 1.0, 1.0, 31, 127);
    server.sync; 0.6.wait;
    withOffsetsPaused.({
        reached = readAll.value;
        command.(\setScatter, 0.0, 1.0, 31, 127);
        server.sync; 0.8.wait;
        after = readAll.value;
        nodes = groupNodes.value.count({ arg node; node[\def] == \strataScatter });
    });
    check.(reached.every(_ != 0) and: { nodes == 0 } and: { after.every(_ == 0) } and: { state[\scatter].isNil },
        "modulation: scatter's end zeroes its channels (% of 35 written before its end; % scatter nodes left, % of 35 channels at 0 after it)".format(
            reached.count(_ != 0), nodes, after.count(_ == 0)));
    resetModulation.value;
};

// Scatter's gains glide (#610): a lock (a voice's bit off), an unlock and a
// destination toggled off and on move a channel by at most about 2 % of
// scatter's value a block (its gains lagged 0.5 s: 60 dB in 0.5 s, 1.8 % of
// the way a block at 750 blocks a second, beside the noise's own slope of
// under 1 % a block at 1 Hz), where an unlagged gain moved it all the way in
// one block (a lock took voice 1's amp offset from -0.383 to 0 at the next
// read). Scatter at depth 1 and rate 1 on every voice and destination; each
// change moves 28 or 30 channels, whose largest value before it (or after
// it, for the moves up) shows what a snap would have stepped. A locked
// voice's channels reach 0 within 1.5 s, and scatter's end, released in the
// middle of a lock's glide, still zeroes every channel (offset node paused)
checkScatterGlides = {
    var trackBus = Bus.control(server, 2), track, results = List.new, change, lockedAt, settled, after, nodes;
    var lockedChannels = { arg values; values.select({ arg value, index; (index div: 5) > 0 }) };
    var keptChannels = { arg values; values.select({ arg value, index; (index div: 5) == 0 }) };
    // [label, the mask's new destinations and voices, which channels move,
    // whether they move down (their value before) or up (their value after)]
    change = { arg label, destinations, voices, moved, down;
        var before = readAll.value, step;
        track.set(\t_reset, 1);
        server.sync; 0.02.wait;
        command.(\setScatter, 1.0, 1.0, destinations, voices);
        server.sync; if (down) { 0.3.wait } { 1.0.wait };
        step = h.readBus(trackBus);
        results.add([label, step[0], if (down) { moved.(before).abs.maxItem } { moved.(readAll.value).abs.maxItem }]);
    };
    command.(\setScatter, 1.0, 1.0, 31, 127);
    server.sync; 1.5.wait;
    track = Synth(\strataCheckBusStep, [\in, state[\fastModBus].index, \out, trackBus.index], engine.processGroup, \addToTail);
    server.sync; 0.05.wait;
    // a lock of every voice but the first: their 30 channels go to 0
    change.("lock", 31, 1, lockedChannels, true);
    1.2.wait;
    settled = readAll.value;
    lockedAt = [lockedChannels.(settled).abs.maxItem, keptChannels.(settled).abs.maxItem];
    // their unlock: back from 0
    change.("unlock", 31, 127, lockedChannels, false);
    // every destination but pitch (position, size, cutoff, amp) off, then
    // on: 28 channels
    change.("destinations off", 1, 127, { arg values; values.select({ arg value, index; (index % 5) > 0 }) }, true);
    change.("destinations on", 31, 127, { arg values; values.select({ arg value, index; (index % 5) > 0 }) }, false);
    track.free;
    trackBus.free;
    check.(results.every({ arg each; (each[1] < 0.05) and: { each[2] > 0.2 } })
        and: { lockedAt[0] < 1e-3 } and: { lockedAt[1] > 1e-3 },
        "modulation: scatter's gains glide: a lock, an unlock and a destination toggle move a channel at most 0.05 a block (largest step, and the largest value a snap would have stepped: %; 1.2 s after the lock its channels read at most %, the kept voice's up to %)".format(
            results.collect({ arg each; "% % of %".format(each[0], each[1].round(0.0001), each[2].round(0.001)) }).join(", "),
            lockedAt[0].round(1e-6), lockedAt[1].round(0.001)));
    // released in the middle of a lock's glide: its end zeroes every channel
    withOffsetsPaused.({
        command.(\setScatter, 1.0, 1.0, 31, 1);
        server.sync; 0.1.wait;
        command.(\setScatter, 0.0, 1.0, 31, 1);
        server.sync; 0.8.wait;
        after = readAll.value;
        nodes = groupNodes.value.count({ arg node; node[\def] == \strataScatter });
    });
    check.((nodes == 0) and: { after.every(_ == 0) } and: { state[\scatter].isNil },
        "modulation: scatter's end zeroes every channel when it is released in the middle of a glide (% scatter nodes left, % of 35 channels at 0)".format(
            nodes, after.count(_ == 0)));
    resetModulation.value;
};

// An LFO stopped, its 20 ms release over on the server before sclang has
// handled the /n_end (the routine holds the interpreter for 60 ms in a loop
// that allocates nothing, so no reply is handled meanwhile), then re-gated
// and given a new shape in one tick, as a PSET load or a scene recall can
// set an LFO's on and shape params one after the other about 20 ms after a
// stop. The re-gate reaches no node; the shape change must free the old node
// (quietly) and start a new one, never send a Synth.replace to a node that is
// gone (the server refuses it, posts a failure, sends /fail and makes no
// node). Afterward the LFO has exactly one node, of the new shape, it
// modulates its channel, and a stop ends it
checkRegateEnded = {
    var fails = 0, responder = OSCFunc({ fails = fails + 1 }, '/fail', server.addr), old, until, nodes, value, ended, ok;
    command.(\setFastLfo, 2, 3, 0, 0, 0.003, 0.4, 0.0);
    server.sync; 0.1.wait;
    old = placeSynth.(2);
    command.(\stopFastLfo, 2);
    until = Main.elapsedTime + 0.06;
    while { Main.elapsedTime < until } { };
    command.(\setFastLfo, 2, 3, 0, 0, 0.003, 0.4, 0.0);
    command.(\setFastLfo, 2, 3, 0, 2, 0.003, 0.4, 0.0);
    command.(\syncFastLfo, 2, 0.25);
    server.sync; 0.2.wait; server.sync;
    nodes = lfoNodes.value;
    value = readChannel.(3, 0);
    command.(\stopFastLfo, 2);
    server.sync; 0.1.wait; server.sync;
    ended = lfoNodes.value.isEmpty and: { placeSynth.(2).isNil };
    server.sync;
    responder.free;
    ok = (fails == 0) and: { nodes.size == 1 } and: { nodes[0][\def] == \strataFastLfoSquare }
        and: { old.notNil and: { nodes[0][\id] != old.nodeID } } and: { (value - 0.4).abs < 0.005 } and: { ended };
    check.(ok, "modulation: an LFO re-gated and given a new shape after its release ended on the server gets one new node, which modulates, and a stop ends it (% /fail replies; LFO nodes %; channel % of 0.4; none after the stop: %)".format(
        fails, nodes.collect(_[\def]), value.round(0.0001), ended));
    resetModulation.value;
};

// Messages to LFO and scatter nodes during their releases (20 ms and
// 0.5 s) go through sendToSynth: no /fail reply (the runner also fails on
// the server's word for it, in capitals, anywhere in its output, so this
// check's line spells it in lowercase). A re-gate in the release keeps the node. An LFO whose
// release ends on the server just as setFastLfo re-gates it (its end made
// here with an /n_free in the same tick as the release and the re-gate, so
// the re-gate reaches no node) starts again, and one whose shape changes
// then gets one new node: never left without one, never two
checkReleases = {
    var fails = 0, responder = OSCFunc({ fails = fails + 1 }, '/fail', server.addr), regated, restarted, changed, old, scatterOld, ok;
    6.do({ arg lfo; command.(\setFastLfo, lfo, lfo, lfo % 5, lfo, 5.0, 0.3, 0.0) });
    command.(\setScatter, 0.5, 0.5, 31, 127);
    server.sync; 0.1.wait;
    scatterOld = state[\scatter] !? { arg place; place[\synth] };
    6.do({ arg lfo; command.(\stopFastLfo, lfo) });
    command.(\setScatter, 0.0, 0.5, 31, 127);
    [0.0, 0.01, 0.018, 0.022, 0.03].do({ arg wait;
        wait.wait;
        6.do({ arg lfo; command.(\syncFastLfo, lfo, 0.5); command.(\stopFastLfo, lfo) });
        command.(\setScatter, 0.0, 0.3, 31, 127);
    });
    // a re-gate inside the release: LFOs 0-2 run on
    6.do({ arg lfo; command.(\stopFastLfo, lfo) });
    [0, 1, 2].do({ arg lfo; command.(\setFastLfo, lfo, lfo, lfo % 5, lfo, 0.003, 0.3, 0.0) });
    0.25.wait;
    command.(\setScatter, 0.4, 0.2, 31, 127);   // inside scatter's 0.5 s release: re-gated
    server.sync; 0.3.wait;
    regated = [0, 1, 2].every({ arg lfo; placeSynth.(lfo).notNil and: { placeSynth.(lfo).isPlaying } })
        and: { [3, 4, 5].every({ arg lfo; placeSynth.(lfo).isNil }) } and: { lfoNodes.value.size == 3 }
        and: { (state[\scatter] !? { arg place; place[\synth] }) === scatterOld }
        and: { groupNodes.value.count({ arg node; node[\def] == \strataScatter }) == 1 };
    // LFO 0 released, its node gone on the server at once, re-gated in the
    // same tick (its shape kept, 0); LFO 1 the same with a new shape (5)
    old = [0, 1].collect({ arg lfo; placeSynth.(lfo) });
    [0, 1].do({ arg lfo; command.(\stopFastLfo, lfo) });
    old.do({ arg synth; synth !? { server.sendMsg('/n_free', synth.nodeID) } });
    command.(\setFastLfo, 0, 0, 0, 0, 0.003, 0.3, 0.0);
    command.(\setFastLfo, 1, 1, 1, 5, 0.003, 0.3, 0.0);
    server.sync; 0.2.wait; server.sync;
    restarted = placeSynth.(0);
    changed = placeSynth.(1);
    ok = [restarted, changed].every({ arg synth, index; synth.notNil and: { synth !== old[index] } and: { synth.isPlaying }
        and: { lfoNodes.value.collect(_[\id]).includes(synth.nodeID) } })
        and: { lfoNodes.value.size == 3 } and: { lfoNodes.value.detect({ arg node; node[\id] == changed.nodeID }) !? { arg node;
            node[\def] == \strataFastLfoSah } ? false };
    server.sync;
    responder.free;
    check.((fails == 0) and: { regated } and: { ok },
        "modulation: no failure while LFO and scatter nodes release (% /fail replies; re-gated in the release: %; a node that ended as it was re-gated starts again: %)".format(
            fails, regated, ok));
    resetModulation.value;
};

// The pitch channel on a synth voice (Folder, 330 Hz): an offset of +0.5
// half ranges, through the offset node and through an engine LFO, raises
// its grain rate by 0.9375 (Pitch on its synth path, against offset 0).
// The source is kept steady: the Folder's fold at 0.5 keeps its sine under
// the fold (its fold amount wanders 0.5-1.5 times it), so the voice is a
// sine through its lowpass, and each reading is the median of 15 reads
// over about 1 s. (At 220 Hz with its default fold, single readings of
// the base varied by 1.2 %, which once took the ratio past 0.02.)
checkPitch = {
    var voice = 2, pitchBus = Bus.control(server, 2), probe, base, offset, lfo, saved = engine.grainControls[voice].copy;
    var savedVoice = engine.voiceControls[voice].copy, expected = 330 * 1.001;
    var pitchOf = {
        var reads = 15.collect({ var values = h.readBus(pitchBus); 0.07.wait; if (values[1] > 0.5) { values[0] } });
        reads = reads.reject(_.isNil);
        if (reads.isEmpty) { 0 } { reads.sort[reads.size div: 2] }
    };
    command.(\setVoiceParam, voice, \fold, 0.5);
    command.(\voiceOn, voice, 330.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    command.(\setVoiceParam, voice, \fold, 0.5);
    server.sync; 1.5.wait;
    probe = Synth(\strataCheckPitch, [\in, engine.voicePathBus(voice, 0), \out, pitchBus], engine.processGroup, \addAfter);
    server.sync; 0.5.wait;
    base = pitchOf.value;
    command.(\setFastOffset, voice, 0, 0, 0.5);
    server.sync; 0.5.wait;
    offset = pitchOf.value;
    command.(\setFastOffset, voice, 0, 0, 0.0);
    command.(\setFastLfo, 0, voice, 0, 0, 0.003, 0.5, 0.0);
    command.(\syncFastLfo, 0, 0.25);
    server.sync; 0.5.wait;
    lfo = pitchOf.value;
    probe.free;
    pitchBus.free;
    command.(\voiceOff, voice);
    h.stopAllVoices;
    engine.grainControls[voice] = saved;
    engine.voiceControls[voice] = savedVoice;
    // (the base within 1 % of the voice's pitch, the two ratios within 2 %
    // of 1.9375: 0.03; an offset not applied reads about 1.0)
    check.(((base / expected) - 1).abs < 0.01 and: { ((offset / base.max(1)) - 1.9375).abs < 0.03 }
        and: { ((lfo / base.max(1)) - 1.9375).abs < 0.03 },
        "modulation: a pitch offset of +0.5 half ranges raises a synth voice's grain rate by 0.9375 (% Hz at 0, % with the offset node: × %, % with an LFO: × %)".format(
            base.round(0.1), offset.round(0.1), (offset / base.max(1)).round(0.0001), lfo.round(0.1), (lfo / base.max(1)).round(0.0001)));
    resetModulation.value;
};

// What the grain hooks compute, on a check-only def that calls them as both
// grain defs do (taps on pitchShift, bufPos and grainSize), for offsets on
// one block: + 1.875, 0.5 and 0.245 × m, clipped to 0.25-4, 0-1 and
// 0.01-0.5; then the real defs: a buffer grain synth at bufPos 0.3 and grain
// size 0.1 with position and size offsets plays as one at the moved values
checkGrainTaps = {
    var voice = 5, tapBus = Bus.control(server, 3), tap, slot = 4, outA = Bus.audio(server, 2), outB = Bus.audio(server, 2);
    var peaks = Bus.control(server, 2), group, pair, diff, measured, ring, saved = engine.grainControls[1].copy;
    // [m for pitch, position and size, expected taps]
    var cases = [
        [0.5, [1.9375, 0.55, 0.2225]], [-0.2, [0.625, 0.2, 0.051]], [2.0, [4.0, 1.0, 0.5]], [-2.0, [0.25, 0.0, 0.01]]
    ];
    var setOffsets = { arg values; values.do({ arg value, destination; command.(\setFastOffset, voice, 0, destination, value) }) };
    tap = Synth(\strataCheckFastTaps, [\out, tapBus.index, \fastModIn, engine.fastModBlock(voice, 0)], engine.processGroup, \addToTail);
    measured = cases.collect({ arg each;
        setOffsets.([each[0], each[0], each[0], 0, 0]);
        server.sync; 0.3.wait;
        h.readBus(tapBus)
    });
    tap.free;
    check.(cases.every({ arg each, index; (measured[index] - each[1]).abs.every({ arg error; error < 1e-5 }) }),
        "modulation: bufPos and grainSize move by 0.5 × m and 0.245 × m and clip, and pitchShift by 1.875 × m (m %: taps %)".format(
            cases.collect(_[0]), measured.collect({ arg each; each.round(0.0001) })));
    // the real \strataGrainBuf and \strataGrainRing, in pairs started in one bundle
    loadNoiseSlot.(slot);
    command.(\voiceOn, 1, 180.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.5.wait;
    setOffsets.([0.5, 0.5, 0.4, 0, 0]);
    server.sync; 0.3.wait;
    group = Group.after(engine.processGroup);
    diff = Synth(\strataCheckBusDiff, [\a, outA, \b, outB, \out, peaks], group, \addToTail);
    pair = { arg defName, argsA, argsB;
        var synths, result;
        server.makeBundle(nil, { synths = [Synth(defName, argsA, group, \addToHead), Synth(defName, argsB, group, \addToHead)] });
        server.sync; 0.3.wait;
        result = measureFor.(diff, peaks, 0.5);
        synths.do(_.free);
        server.sync;
        result
    };
    measured = [
        pair.(\strataGrainBuf, bufArgs.(outA, slot, [\fastModIn, engine.fastModBlock(voice, 0)]),
            bufArgs.(outB, slot, [\bufPos, 0.55, \pitchShift, 1.9375, \grainSize, 0.1 + (0.245 * 0.4)])),
        pair.(\strataGrainRing, ringArgs.(outA, 1, [\fastModIn, engine.fastModBlock(voice, 0)]),
            ringArgs.(outB, 1, [\pitchShift, 1.9375, \grainSize, 0.1 + (0.245 * 0.4)]))
    ];
    // (within 1 % of the level: the moved size is a float64 sum sent as a
    // float32 control where the def adds float32s, and at 0.198 s, 9504.0
    // samples, a last bit can move a grain's end by a sample, about 0.2 %;
    // an offset not applied differs by about the level, as RED showed)
    check.(measured.every({ arg peak; (peak[1] > 0.01) and: { peak[0] < (peak[1] * 1e-2) } }),
        "modulation: the grain defs apply position, size and pitch offsets as moved controls would ([difference, level]: buffer %, ring %)".format(
            *measured.collect({ arg peak; peak.round(1e-7) })));
    // the cutoff and amp channels moved, the rest at 0: each def plays as
    // with no offset at all (they read the amp channel and use neither)
    setOffsets.([0, 0, 0, 1.0, 1.0]);
    server.sync; 0.3.wait;
    measured = [
        pair.(\strataGrainBuf, bufArgs.(outA, slot, [\fastModIn, engine.fastModBlock(voice, 0)]), bufArgs.(outB, slot)),
        pair.(\strataGrainRing, ringArgs.(outA, 1, [\fastModIn, engine.fastModBlock(voice, 0)]), ringArgs.(outB, 1))
    ];
    ring = checkGrainChannels.value;
    check.(measured.every({ arg peak; (peak[1] > 0.01) and: { peak[0] < 1e-6 } }) and: { ring },
        "modulation: the grain synths ignore the cutoff channel and only read the amp channel ([difference, level] with both at 1: buffer %, ring %; graphs: %)".format(
            measured[0].round(1e-7), measured[1].round(1e-7), ring));
    group.free;
    [tapBus, outA, outB, peaks].do(_.free);
    command.(\voiceOff, 1);
    h.stopAllVoices;
    engine.grainControls[1] = saved;
    command.(\clearBuffer, slot);
    resetModulation.value;
};

// In both grain defs' graphs, the In of fastModIn has five channels: pitch
// (0) and size (2) feed UGens, position (1) only in \strataGrainBuf, the
// cutoff (3) and amp (4) feed none
checkGrainChannels = {
    h.grainDefs.every({ arg defName;
        var desc = SynthDescLib.global.at(defName), ugens = desc.def.children;
        var control = desc.controls.detect({ arg each; each.name == \fastModIn });
        var isFastModIn = { arg input; input.isKindOf(OutputProxy) and: { input.source.isKindOf(Control) }
            and: { (input.source.specialIndex + input.outputIndex) == control.index } };
        var reader = ugens.detect({ arg ugen; ugen.isKindOf(In) and: { isFastModIn.(ugen.inputs[0]) } });
        var used = { arg channel; ugens.any({ arg ugen; (ugen.inputs ? []).any({ arg input; input === channel }) }) };
        control.notNil and: { reader.notNil } and: { reader.channels.size == 5 } and: {
            var flags = reader.channels.collect(used);
            (flags == [true, defName == \strataGrainBuf, true, false, false])
        }
    })
};

// What voiceMixMod computes, on a check-only copy of the stage's Event
// through the hook (taps on filterFreq and ampOffset): filterFreq x 31.62 ^
// m3, clipped to 20-20000, and the amp channel's offset as is
checkStageTaps = {
    var voice = 5, tapBus = Bus.control(server, 3), tap, measured;
    // [cutoff m3, amp m4, expected filterFreq from 1000 Hz]
    var cases = [[0.5, 0.5, 1000 * (31.62 ** 0.5)], [-0.5, -1.0, 1000 / (31.62 ** 0.5)], [-1.0, 1.0, 1000 / 31.62],
        [1.0, 2.0, 20000], [-2.0, -2.0, 20], [2.0, 0.0, 20000]];
    tap = Synth(\strataCheckStageTaps, [\out, tapBus.index, \fastModIn, engine.fastModBlock(voice, 0), \filterFreq, 1000],
        engine.processGroup, \addToTail);
    measured = cases.collect({ arg each;
        command.(\setFastOffset, voice, 0, 3, each[0]);
        command.(\setFastOffset, voice, 0, 4, each[1]);
        server.sync; 0.3.wait;
        h.readBus(tapBus)
    });
    tap.free; tapBus.free;
    check.(cases.every({ arg each, index;
        ((measured[index][0] / each[2]) - 1).abs < 1e-4 and: { (measured[index][1] - each[1]).abs < 1e-5 } }),
        "modulation: the stage's cutoff moves by 31.62 ^ m and clips at 20 and 20000 (from 1000 Hz, m %: %; amp offsets %)".format(
            cases.collect(_[0]), measured.collect({ arg each; each[0].round(0.01) }), measured.collect({ arg each; each[1].round(0.0001) })));
    resetModulation.value;
};

// The real stage with a cutoff offset filters as one at the moved cutoff
checkStageCutoff = {
    var voice = 5, group = Group.after(engine.processGroup), inBus = Bus.audio(server, 2), silentIn = Bus.audio(server, 2);
    var outs = 2.collect({ Bus.audio(server, 10) }), peaks = Bus.control(server, 2), source, stages, diff, measured;
    var filter = [\filterType, 0, \filterRes, 0.5, \filterMix, 1, \amp, 1];
    command.(\setFastOffset, voice, 0, 3, 0.5);
    server.sync; 0.3.wait;
    source = Synth(\strataCheckSine, [\out, inBus, \freq, 3000], group, \addToHead);
    server.makeBundle(nil, { stages = [
        Synth(\strataVoiceMix, stageArgs.(outs[0], inBus.index, silentIn.index, filter ++ [\filterFreq, 1000, \fastModIn, engine.fastModBlock(voice, 0)]), group, \addToTail),
        Synth(\strataVoiceMix, stageArgs.(outs[1], inBus.index, silentIn.index, filter ++ [\filterFreq, 1000 * (31.62 ** 0.5)]), group, \addToTail)
    ] });
    diff = Synth(\strataCheckStageDiff, [\a, outs[0], \b, outs[1], \out, peaks], group, \addToTail);
    server.sync; 0.4.wait;
    measured = measureFor.(diff, peaks, 0.4);
    check.((measured[1] > 0.01) and: { measured[0] < (measured[1] * 1e-3) },
        "modulation: the stage filters at the moved cutoff (1000 Hz at m 0.5 against 5623 Hz: [difference, level] %)".format(measured.round(1e-7)));
    group.free;
    ([inBus, silentIn, peaks] ++ outs).do(_.free);
    resetModulation.value;
};

// The amp channel on the stage, by the design's law (§3.3): the other
// path's level is (amp x (1 + modSig + m4) x (1 + accent)).clip(0, 2), the
// synth path's (1 + m4).clip(0, 2). With no crossmod and no accent, -1
// silences both paths and +1 doubles them. With crossmod (a sine at amount
// 0.5) and an accent running, the other path's level is the law's: the
// stage equals 3.3's with the crossmod bus shifted by the offset over the
// amount (so modSig there is modSig + m4, inside the same clip), the clip
// at 0 (-1: the crossmod's positive half) and at 2 (+1 at amp 0.9) both
// met; the synth path ignores both and is silent or doubled. (At -1 the
// other path is not silent while crossmod runs: the law adds the offset to
// the crossmod, as the design's table says.)
checkStageAmp = {
    var voice = 5, group = Group.after(engine.processGroup), synthIn = Bus.audio(server, 2), otherIn = Bus.audio(server, 2);
    var silentIn = Bus.audio(server, 2), modBuses = Bus.control(server, 2), outs = 2.collect({ Bus.audio(server, 10) });
    var peaks = Bus.control(server, 2), sources, diff, results = List.new, run;
    var block = [\fastModIn, engine.fastModBlock(voice, 0)], crossA = [\modBus1, modBuses.index, \modAmpAmt1, 0.5];
    var crossB = [\modBus1, modBuses.index + 1, \modAmpAmt1, 0.5], level = [\amp, 0.3];
    sources = [Synth(\strataCheckSine, [\out, synthIn, \freq, 300], group, \addToHead),
        Synth(\strataCheckSine, [\out, otherIn, \freq, 500], group, \addToHead)];
    diff = Synth(\strataCheckStageDiff, [\a, outs[0], \b, outs[1], \out, peaks], group, \addToTail);
    // [the stage's def and controls, the reference's, scale, label]
    run = { arg offset, defB, argsA, argsB, scale, label, shift, accent = true;
        var stages, pairs, result;
        command.(\setFastOffset, voice, 0, 4, offset);
        server.sync; 0.3.wait;
        pairs = Synth(\strataCheckModPair, [\outA, modBuses.index, \outB, modBuses.index + 1, \shift, shift ? 0], group, \addToHead);
        server.makeBundle(nil, { stages = [Synth(\strataVoiceMix, argsA, diff, \addBefore), Synth(defB, argsB, diff, \addBefore)] });
        // (the scale well before the reset: a control into an audio-rate
        // multiply ramps across the block it changes in)
        diff.set(\scale, scale);
        server.sync; 0.2.wait;
        server.makeBundle(nil, {
            if (accent) { stages.do({ arg stage; stage.set(\velocity, 0.8, \t_trig, 1) }) };
            diff.set(\t_reset, 1)
        });
        0.5.wait; server.sync;
        result = h.readBus(peaks);
        stages.do(_.free); pairs.free;
        server.sync;
        results.add([label, result]);
        result
    };
    // no crossmod or accent: both paths, -1 against silence (the reference at 0 x), +1 against twice the reference
    run.(-1.0, \strataVoiceMix, stageArgs.(outs[0], synthIn.index, otherIn.index, level ++ block), stageArgs.(outs[1], synthIn.index, otherIn.index, level), 0, "-1, both paths", nil, false);
    run.(1.0, \strataVoiceMix, stageArgs.(outs[0], synthIn.index, otherIn.index, level ++ block), stageArgs.(outs[1], synthIn.index, otherIn.index, level), 2, "+1, both paths", nil, false);
    // the synth path alone, with crossmod and an accent running
    run.(-1.0, \strataVoiceMix, stageArgs.(outs[0], synthIn.index, silentIn.index, level ++ block ++ crossA), stageArgs.(outs[1], synthIn.index, silentIn.index, level ++ crossA), 0, "-1, synth path, crossmod");
    run.(1.0, \strataVoiceMix, stageArgs.(outs[0], synthIn.index, silentIn.index, level ++ block ++ crossA), stageArgs.(outs[1], synthIn.index, silentIn.index, level ++ crossA), 2, "+1, synth path, crossmod");
    // the other path alone, with crossmod and an accent: as 3.3's with the crossmod bus shifted by offset / 0.5
    run.(-1.0, \strataCheckVoiceMix33, stageArgs.(outs[0], silentIn.index, otherIn.index, level ++ block ++ crossA), stageArgs.(outs[1], silentIn.index, otherIn.index, level ++ crossB), 1, "-1, other path, crossmod", -2.0);
    run.(1.0, \strataCheckVoiceMix33, stageArgs.(outs[0], silentIn.index, otherIn.index, level ++ block ++ crossA), stageArgs.(outs[1], silentIn.index, otherIn.index, level ++ crossB), 1, "+1, other path, crossmod", 2.0);
    run.(1.0, \strataCheckVoiceMix33, stageArgs.(outs[0], silentIn.index, otherIn.index, [\amp, 0.9] ++ block ++ crossA), stageArgs.(outs[1], silentIn.index, otherIn.index, [\amp, 0.9] ++ crossB), 1, "+1, other path, crossmod, amp 0.9 (the clip at 2)", 2.0);
    check.(results.every({ arg each; (each[1][1] > 0.01) and: { each[1][0] < 1e-5 } }),
        "modulation: an amp offset of −1 silences both paths and +1 doubles them, and with crossmod and an accent running on the other path its level is the law's, (amp × (1 + modSig + m4) × (1 + accent)).clip(0, 2) ([difference, level] %)".format(
            results.collect({ arg each; "%: %".format(each[0], each[1].round(1e-7)) }).join("; ")));
    group.free;
    ([synthIn, otherIn, silentIn, modBuses, peaks] ++ outs).do(_.free);
    resetModulation.value;
};

// With every bus at 0, each grain def and the stage play exactly as 3.3's
// (check-only copies), the grain synths reading their voice's block and the
// stage with its filter, crossmod, accent and sends running
checkEqual33 = {
    var voice = 1, slot = 4, group, outA = Bus.audio(server, 2), outB = Bus.audio(server, 2), peaks = Bus.control(server, 2);
    var diff, pair, measured, block = [\fastModIn, engine.fastModBlock(voice, 0)], stageResult;
    var synthIn = Bus.audio(server, 2), otherIn = Bus.audio(server, 2), modBuses = Bus.control(server, 2);
    var outs = 2.collect({ Bus.audio(server, 10) }), stagePeaks = Bus.control(server, 2), stageDiff, stages, sources;
    var saved = engine.grainControls[voice].copy;
    loadNoiseSlot.(slot);
    command.(\voiceOn, voice, 180.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.5.wait;
    group = Group.after(engine.processGroup);
    diff = Synth(\strataCheckBusDiff, [\a, outA, \b, outB, \out, peaks], group, \addToTail);
    pair = { arg defA, defB, argsA, argsB;
        var synths, result;
        server.makeBundle(nil, { synths = [Synth(defA, argsA, group, \addToHead), Synth(defB, argsB, group, \addToHead)] });
        server.sync; 0.3.wait;
        result = measureFor.(diff, peaks, 0.5);
        synths.do(_.free);
        server.sync;
        result
    };
    measured = [
        pair.(\strataGrainRing, \strataCheckGrainRing33, ringArgs.(outA, voice, block), ringArgs.(outB, voice)),
        pair.(\strataGrainBuf, \strataCheckGrainBuf33, bufArgs.(outA, slot, block), bufArgs.(outB, slot))
    ];
    sources = [Synth(\strataCheckSine, [\out, synthIn, \freq, 300], group, \addToHead),
        Synth(\strataCheckSine, [\out, otherIn, \freq, 700], group, \addToHead),
        Synth(\strataCheckModPair, [\outA, modBuses.index, \outB, modBuses.index + 1], group, \addToHead)];
    stageDiff = Synth(\strataCheckStageDiff, [\a, outs[0], \b, outs[1], \out, stagePeaks], group, \addToTail);
    server.makeBundle(nil, { stages = [
        Synth(\strataVoiceMix, stageArgs.(outs[0], synthIn.index, otherIn.index, [\amp, 0.6, \modBus1, modBuses.index, \modAmpAmt1, 0.5,
            \filterType, 2, \filterFreq, 1500, \filterRes, 0.3, \filterMix, 0.6, \delaySend, 0.7, \reverbSend, 0.4] ++ block), stageDiff, \addBefore),
        Synth(\strataCheckVoiceMix33, stageArgs.(outs[1], synthIn.index, otherIn.index, [\amp, 0.6, \modBus1, modBuses.index, \modAmpAmt1, 0.5,
            \filterType, 2, \filterFreq, 1500, \filterRes, 0.3, \filterMix, 0.6, \delaySend, 0.7, \reverbSend, 0.4]), stageDiff, \addBefore)
    ] });
    server.sync; 0.3.wait;
    server.makeBundle(nil, { stages.do({ arg stage; stage.set(\velocity, 0.8, \t_trig, 1) }); stageDiff.set(\t_reset, 1) });
    0.3.wait;
    server.makeBundle(nil, { stages.do({ arg stage; stage.set(\velocity, 0.4, \t_trig, 1) }) });
    0.3.wait; server.sync;
    stageResult = h.readBus(stagePeaks);
    check.(measured.every({ arg peak; (peak[1] > 0.01) and: { peak[0] < 1e-6 } }) and: { (stageResult[1] > 0.01) and: { stageResult[0] < 1e-6 } },
        "modulation: with every bus at 0 each grain synth and stage equals 3.3's within 1e-6 ([difference, level]: ring %, buffer %, stage %)".format(
            measured[0].round(1e-8), measured[1].round(1e-8), stageResult.round(1e-8)));
    group.free;
    [outA, outB, peaks, synthIn, otherIn, modBuses, stagePeaks].do(_.free);
    outs.do(_.free);
    command.(\voiceOff, voice);
    h.stopAllVoices;
    engine.grainControls[voice] = saved;
    command.(\clearBuffer, slot);
};

// The gate (design §8.12), on two check stages of the real def fed by one
// DC source (so the tap is the level times the gate factor): G gated
// (seqGate 1), U not; the trackers read G's tap over U's, block by block,
// at times after triggers sent in timestamped bundles
checkGates = {
    var group = Group.after(engine.processGroup), synthIn = Bus.audio(server, 2), otherIn = Bus.audio(server, 2), silentIn = Bus.audio(server, 2);
    var outs = 2.collect({ Bus.audio(server, 10) }), trackBus = Bus.control(server, 7), track2Bus = Bus.control(server, 7);
    var peaks = Bus.control(server, 2), sources, stages, track, track2, diff, before, open, longer, rerun, mirror, velocity, tapPeak;
    var gateArgs = [\seqGate, 1, \gateSeconds, 0.1, \gateRelease, 0.05];
    var triggerAt = { arg latency, velocity = 1, also;
        server.makeBundle(latency, { stages.do({ arg stage; stage.set(\velocity, velocity, \t_trig, 1) }); also.value });
    };
    var restart = { arg inputs, argsG;
        stages.do(_.free);
        server.makeBundle(nil, { stages = [
            Synth(\strataVoiceMix, stageArgs.(outs[0], inputs[0], inputs[1], argsG), track, \addBefore),
            Synth(\strataVoiceMix, stageArgs.(outs[1], inputs[0], inputs[1]), track, \addBefore)
        ] });
        server.sync; 0.3.wait;
    };
    sources = [Synth(\strataCheckDC, [\out, synthIn, \level, 0.5], group, \addToHead),
        Synth(\strataCheckDC, [\out, otherIn, \level, 0.25], group, \addToHead)];
    // [now, lowest, at 0.05, 0.13, 0.25 and 0.3 s]
    track = Synth(\strataCheckRatioTrack, [\a, outs[0].index + 8, \b, outs[1].index + 8, \out, trackBus, \times, [0.05, 0.13, 0.25, 0.3]], group, \addToTail);
    track2 = Synth(\strataCheckRatioTrack, [\a, outs[0].index + 8, \b, outs[1].index + 8, \out, track2Bus, \minTime, 0.07, \times, [0.03, 0.05, 0.06, 0.07]], group, \addToTail);
    diff = Synth(\strataCheckBusDiff, [\a, outs[0].index + 6, \b, outs[1].index + 6, \out, peaks], group, \addToTail);
    stages = [];
    // silent until a trigger; at its ungated level 50 ms after one; silent
    // again after gateSeconds (0.1) and the release (0.05): 5 ms up, held to
    // 0.105 s, half way down at 0.13 s, closed at 0.155 s
    restart.([synthIn.index, silentIn.index], gateArgs);
    before = h.readBus(trackBus)[0];
    triggerAt.(0.1, 1, { track.set(\t_reset, 1) });
    0.5.wait; server.sync;
    open = h.readBus(trackBus);
    // and a longer gateSeconds (0.3 s) holds it open past 0.25 s
    stages[0].set(\gateSeconds, 0.3);
    server.sync;
    triggerAt.(0.1, 1, { track.set(\t_reset, 1) });
    0.5.wait; server.sync;
    longer = h.readBus(trackBus);
    check.((before.abs < 0.001) and: { (open[2] - 1).abs < 0.01 } and: { (open[3] - 0.5).abs < 0.06 } and: { open[4].abs < 0.01 }
        and: { (longer[4] - 1).abs < 0.01 },
        "modulation: a gated voice is silent until a retrigger, at its ungated level 50 ms after one, and silent again after gateSeconds and the release (before %; at 0.05 s %, 0.13 s %, 0.25 s %; with gateSeconds 0.3, at 0.25 s %)".format(
            before.round(0.0001), open[2].round(0.0001), open[3].round(0.0001), open[4].round(0.0001), longer[4].round(0.0001)));
    // a trigger in the release (at 0.13 s, half way down) reopens the gate from its level
    stages[0].set(\gateSeconds, 0.1);
    server.sync; 0.3.wait;
    triggerAt.(0.1, 1, { track.set(\t_reset, 1) });
    triggerAt.(0.23, 1, { track2.set(\t_reset, 1) });
    0.6.wait; server.sync;
    open = h.readBus(trackBus);
    rerun = h.readBus(track2Bus);
    // The level just before the trigger (the tracker's last channel: the
    // block before the trigger's) is about half way down the release (0.4-0.65:
    // the trigger's bundle falls anywhere in a block, and the attack's and
    // hold's whole blocks move the release by a block or two). The lowest
    // after it is the release two blocks on, no lower: the tracker reads each
    // block's first sample, which is the gate of the block before (an
    // audio-rate multiply interpolates a control across its block), and the
    // envelope's level in the trigger's own block is still the release's next
    // step (its attack starts from there, the block after). So the bound is
    // two steps (a block over gateRelease, 0.027 each; measured: exactly two)
    // and a rounding's slack; a gate that dipped further at the re-gate, or
    // restarted from 0, reads lower
    check.((rerun[6] >= 0.4) and: { rerun[6] <= 0.65 } and: { rerun[1] >= (rerun[6] - (2 * blockSeconds / 0.05) - 1e-3) }
        and: { (rerun[2] - 1).abs < 0.01 },
        "modulation: a retrigger during the release reopens the gate from its level (just before it %, lowest after it %, at most two release steps of % under it; 30 ms after it %)".format(
            rerun[6].round(0.0001), rerun[1].round(0.0001), (blockSeconds / 0.05).round(0.0001), rerun[2].round(0.0001)));
    // the mirror is not gated and the tap is (both paths, no trigger)
    restart.([synthIn.index, otherIn.index], gateArgs);
    mirror = measureFor.(diff, peaks, 0.3);
    tapPeak = h.readBus(trackBus)[0];
    check.((mirror[1] > 0.01) and: { mirror[0] < 1e-6 } and: { tapPeak.abs < 0.001 },
        "modulation: the mirror is not gated and the tap is (mirror against the ungated stage's [difference, level] %; tap over the ungated tap %)".format(
            mirror.round(1e-7), tapPeak.round(0.0001)));
    // velocity does not scale the gate: a trigger at velocity 0.25 opens the
    // closed gate fully, and it closes again (the accent, which velocity
    // scales, is on both stages' other paths alike)
    triggerAt.(0.1, 0.25, { track.set(\t_reset, 1) });
    0.4.wait; server.sync;
    velocity = h.readBus(trackBus);
    check.((tapPeak.abs < 0.001) and: { (velocity[2] - 1).abs < 0.01 } and: { velocity[4].abs < 0.01 },
        "modulation: velocity does not scale the gate (velocity 0.25: tap over the ungated tap % before, % at 0.05 s, % at 0.25 s)".format(
            tapPeak.round(0.0001), velocity[2].round(0.0001), velocity[4].round(0.0001)));
    group.free;
    ([synthIn, otherIn, silentIn, trackBus, track2Bus, peaks] ++ outs).do(_.free);
};

// seqGate glides (#614): switched on a running voice, or at a recall's end,
// the gate closes (no trigger: its envelope is at 0) and opens again over
// the mute's 20 ms lag, never within one block. Two check stages of the
// real def fed by one DC source, G's seqGate switched, U ungated: the ratio
// of their taps, block by block, never steps by more than 0.6 (the lag's
// first block moves it 37 % of the way, 1 - e^(-6.9 / 15); a switch in one
// block steps it about 0.98), and it is closed (under 0.001) or open
// (within 0.001 of 1) 0.15 s after each switch
checkGateLag = {
    var group = Group.after(engine.processGroup), synthIn = Bus.audio(server, 2), silentIn = Bus.audio(server, 2);
    var outs = 2.collect({ Bus.audio(server, 10) }), trackBus = Bus.control(server, 2), source, stages, track, results;
    source = Synth(\strataCheckDC, [\out, synthIn, \level, 0.5], group, \addToHead);
    track = Synth(\strataCheckRatioStep, [\a, outs[0].index + 8, \b, outs[1].index + 8, \out, trackBus], group, \addToTail);
    server.makeBundle(nil, { stages = [
        Synth(\strataVoiceMix, stageArgs.(outs[0], synthIn.index, silentIn.index, [\seqGate, 0, \gateSeconds, 0.1, \gateRelease, 0.05]), track, \addBefore),
        Synth(\strataVoiceMix, stageArgs.(outs[1], synthIn.index, silentIn.index), track, \addBefore)
    ] });
    server.sync; 0.3.wait;
    results = [1, 0].collect({ arg gate;
        var read;
        track.set(\t_reset, 1);
        server.sync; 0.02.wait;
        stages[0].set(\seqGate, gate);
        server.sync; 0.15.wait;
        read = h.readBus(trackBus);
        [gate, read[0], read[1]]
    });
    check.((results[0][1].abs < 0.001) and: { (results[1][1] - 1).abs < 0.001 } and: { results.every({ arg each; each[2] < 0.6 }) },
        "modulation: seqGate switched on a running voice glides over 20 ms (seqGate, the tap over the ungated tap 0.15 s after, its largest step a block: %)".format(
            results.collect({ arg each; "% % %".format(each[0], each[1].round(0.0001), each[2].round(0.0001)) }).join(", ")));
    group.free;
    ([synthIn, silentIn, trackBus] ++ outs).do(_.free);
};

// Mute (design §8.14) on two check stages of the real def, both paths fed:
// voiceMute 1 silences the tap within 0.1 s whether ungated, gated open or
// gated closed (a trigger then opens nothing), voiceMute 0 brings it back,
// and the mirror never differs from the unmuted stage's
checkMute = {
    var group = Group.after(engine.processGroup), synthIn = Bus.audio(server, 2), otherIn = Bus.audio(server, 2);
    var outs = 2.collect({ Bus.audio(server, 10) }), trackBus = Bus.control(server, 7), peaks = Bus.control(server, 2);
    var sources, stages, track, diff, results = List.new, back, mirror;
    var runCase = { arg label, argsM, triggerFirst, triggerAfter;
        var muted, opened;
        stages.do(_.free);
        server.makeBundle(nil, { stages = [
            Synth(\strataVoiceMix, stageArgs.(outs[0], synthIn.index, otherIn.index, argsM), track, \addBefore),
            Synth(\strataVoiceMix, stageArgs.(outs[1], synthIn.index, otherIn.index), track, \addBefore)
        ] });
        server.sync; 0.3.wait;
        // the mirrors are compared from the first case's stages to the end
        if (results.isEmpty) { diff.set(\t_reset, 1) };
        if (triggerFirst) { stages.do({ arg stage; stage.set(\t_trig, 1) }); server.sync; 0.05.wait };
        server.makeBundle(0.1, { stages[0].set(\voiceMute, 1); track.set(\t_reset, 1) });
        0.3.wait; server.sync;
        // [now, lowest, at 0.02, 0.05, 0.1, 0.2 s]: at 0.1 s
        muted = h.readBus(trackBus)[4];
        opened = if (triggerAfter) {
            stages.do({ arg stage; stage.set(\t_trig, 1) });
            server.sync; 0.05.wait;
            h.readBus(trackBus)[0]
        };
        results.add([label, muted, opened]);
    };
    sources = [Synth(\strataCheckDC, [\out, synthIn, \level, 0.5], group, \addToHead),
        Synth(\strataCheckDC, [\out, otherIn, \level, 0.25], group, \addToHead)];
    track = Synth(\strataCheckRatioTrack, [\a, outs[0].index + 8, \b, outs[1].index + 8, \out, trackBus, \times, [0.02, 0.05, 0.1, 0.2]], group, \addToTail);
    diff = Synth(\strataCheckBusDiff, [\a, outs[0].index + 6, \b, outs[1].index + 6, \out, peaks], group, \addToTail);
    stages = [];
    runCase.("ungated", [], false, false);
    // voiceMute 0 brings it back within 0.1 s
    server.makeBundle(0.1, { stages[0].set(\voiceMute, 0); track.set(\t_reset, 1) });
    0.3.wait; server.sync;
    back = h.readBus(trackBus)[4];
    runCase.("gated open", [\seqGate, 1, \gateSeconds, 2, \gateRelease, 0.05], true, false);
    runCase.("gated closed", [\seqGate, 1, \gateSeconds, 2, \gateRelease, 0.05], false, true);
    mirror = h.readBus(peaks);
    check.(results.every({ arg each; (each[1].abs < 0.001) and: { each[2].isNil or: { each[2].abs < 0.001 } } })
        and: { (back - 1).abs < 0.01 } and: { (mirror[1] > 0.01) and: { mirror[0] < 1e-6 } },
        "modulation: voiceMute 1 silences a voice within 0.1 s whatever its gate, voiceMute 0 brings it back, and the mirror is never muted (tap over the unmuted tap at 0.1 s: %; back %; mirror [difference, level] %)".format(
            results.collect({ arg each; "% % %".format(each[0], each[1].round(0.0001), each[2] !? { arg value; value.round(0.0001) }) }).join(", "),
            back.round(0.0001), mirror.round(1e-7)));
    group.free;
    ([synthIn, otherIn, trackBus, peaks] ++ outs).do(_.free);
};

// The gate and mute through the engine: an input voice on the check's tone,
// gated with setGrainParam, is silent on its tap until retrigger opens it,
// silent again after the gate, and voiceMute silences it
checkGateEngine = {
    var voice = 4, saved = engine.grainControls[voice].copy, tone, probe, peakBus = Bus.control(server, 1), closed, opened, after, muted, back;
    var tap = engine.areaState[\record][\voiceTaps][voice];
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.inputSynth, \addBefore);
    command.(\setGrainParam, voice, \history, 0);
    command.(\setGrainSource, voice, engine.inputSource);
    command.(\voiceOn, voice, 110.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    [\seqGate, 1, \gateSeconds, 0.1, \gateRelease, 0.05].pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) });
    server.sync;
    probe = Synth(\strataCheckPeak, [\in, tap, \out, peakBus], engine.processGroup, \addAfter);
    1.0.wait;
    closed = measureFor.(probe, peakBus, 0.2)[0];
    server.makeBundle(nil, { command.(\retrigger, voice, 1.0); probe.set(\t_reset, 1) });
    0.08.wait; server.sync;
    opened = h.readBus(peakBus)[0];
    0.3.wait;
    after = measureFor.(probe, peakBus, 0.2)[0];
    command.(\setGrainParam, voice, \seqGate, 0);
    server.sync; 0.2.wait;
    command.(\setGrainParam, voice, \voiceMute, 1);
    server.sync; 0.1.wait;
    muted = measureFor.(probe, peakBus, 0.2)[0];
    command.(\setGrainParam, voice, \voiceMute, 0);
    server.sync; 0.1.wait;
    back = measureFor.(probe, peakBus, 0.2)[0];
    check.((closed < 1e-4) and: { opened > 0.01 } and: { after < 1e-4 } and: { muted < 1e-4 } and: { back > 0.01 },
        "modulation: through the engine, a gated voice's tap opens on retrigger and closes after the gate, and voiceMute silences it (closed %, opened %, after %, muted %, back %)".format(
            closed.round(1e-6), opened.round(1e-4), after.round(1e-6), muted.round(1e-6), back.round(1e-4)));
    [\seqGate, 0, \gateSeconds, 0.1, \gateRelease, 0.1, \voiceMute, 0].pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) });
    command.(\voiceOff, voice);
    probe.free; tone.free; peakBus.free;
    h.stopAllVoices;
    engine.grainControls[voice] = saved;
    server.sync;
};

// Lua sends gateSeconds (and gateRelease and the mute) to a voice only when
// it changes, caching the last value for the session, so the engine keeps
// them: a stage replaced in place (a NaN on its filter) and its voice
// stopped and started, and switched to another source and back, each keep
// gateSeconds, gateRelease and voiceMute as last set, with nothing resent;
// the mute keeps the replaced stage silent, and the next seqGate uses the
// kept gateSeconds (0.3 s: open 0.22-0.28 s after a retrigger, where the
// default 0.1 s and its release close by 0.21 s; closed again by 0.4 s)
checkGateKept = {
    var voice = 4, saved = engine.grainControls[voice].copy, tap = engine.areaState[\record][\voiceTaps][voice];
    var peakBus = Bus.control(server, 1), tone, probe, oldId, replaced, muted, opened, closed, reads = List.new;
    var stageOf = { engine.synths[engine.voiceMixKey(voice)] };
    var readStage = { arg label; reads.add([label] ++ [\gateSeconds, \gateRelease, \voiceMute].collect({ arg name; getControl.(stageOf.value, name) })) };
    var expected = [0.3, 0.05, 1];
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.inputSynth, \addBefore);
    command.(\setGrainParam, voice, \history, 0);
    command.(\setGrainSource, voice, engine.inputSource);
    command.(\voiceOn, voice, 110.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    [\gateSeconds, 0.3, \gateRelease, 0.05, \voiceMute, 1].pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) });
    server.sync; 0.3.wait;
    readStage.("set");
    probe = Synth(\strataCheckPeak, [\in, tap, \out, peakBus], engine.processGroup, \addAfter);
    oldId = stageOf.value.nodeID;
    stageOf.value.set(\filterMix, 0/0);    // a NaN: the stage is replaced in place from its kept controls
    0.3.wait; server.sync;
    replaced = stageOf.value.nodeID != oldId;
    readStage.("replaced");
    muted = measureFor.(probe, peakBus, 0.2)[0];
    command.(\voiceOff, voice);
    server.sync; 0.2.wait;
    command.(\voiceOn, voice, 110.0, 0.5, 0.0, 0.1, 20.0, 1.0);
    server.sync; 0.2.wait;
    readStage.("restarted");
    command.(\setGrainSource, voice, 0);
    server.sync; 0.2.wait;
    command.(\setGrainSource, voice, engine.inputSource);
    server.sync; 0.3.wait;
    readStage.("switched and back");
    // the mute lifted, the gate on: gateSeconds and gateRelease are the kept ones
    command.(\setGrainParam, voice, \voiceMute, 0);
    command.(\setGrainParam, voice, \seqGate, 1);
    server.sync; 0.3.wait;
    server.makeBundle(0.1, { command.(\retrigger, voice, 1.0) });
    server.makeBundle(0.32, { probe.set(\t_reset, 1) });
    0.38.wait; server.sync;
    opened = h.readBus(peakBus)[0];
    server.makeBundle(0.12, { probe.set(\t_reset, 1) });
    0.25.wait; server.sync;
    closed = h.readBus(peakBus)[0];
    check.(replaced and: { reads.every({ arg each; (each.drop(1) - expected).abs.every({ arg error; error < 1e-6 }) }) }
        and: { muted < 1e-4 } and: { opened > 0.01 } and: { closed < 1e-4 },
        "modulation: a stage replaced in place and its voice restarted or switched keep gateSeconds, gateRelease and the mute as last set, with no resend, and the next seqGate uses them (replaced %; [gateSeconds, gateRelease, voiceMute] %; muted tap %; gated tap 0.22-0.28 s after a retrigger %, later %)".format(
            replaced, reads.collect({ arg each; "%: %".format(each[0], each.drop(1).round(0.0001)) }).join(", "),
            muted.round(1e-6), opened.round(1e-4), closed.round(1e-6)));
    [\seqGate, 0, \gateSeconds, 0.1, \gateRelease, 0.1, \voiceMute, 0].pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) });
    command.(\voiceOff, voice);
    probe.free; tone.free; peakBus.free;
    h.stopAllVoices;
    engine.grainControls[voice] = saved;
    server.sync;
};

// The stage's gate and mute controls (design §8.12, §8.14): declared with
// their defaults, set through setGrainParam, kept, never a grain synth's
checkGateControls = {
    var names = [\seqGate, \gateSeconds, \gateRelease, \voiceMute], defaults = [0, 0.1, 0.1, 0];
    var voices = [1, 4], saved = voices.collect({ arg voice; engine.grainControls[voice].copy });
    var stageDesc = SynthDescLib.global.at(\strataVoiceMix), reached, kept;
    var declared = names.collect({ arg name, index;
        var control = stageDesc.controls.detect({ arg each; each.name == name });
        control.notNil and: { control.defaultValue.equalWithPrecision(defaults[index], 1e-6) }
    });
    var inGrainDefs = h.grainDefs.collect({ arg defName;
        SynthDescLib.global.at(defName).controlNames.collect(_.asSymbol).select({ arg name; names.includes(name) }) }).flatten;
    voices.do({ arg voice; command.(\voiceOn, voice, 110.0, 0.5, 0.0, 0.1, 20.0, 1.0) });
    voices.do({ arg voice; [\seqGate, 1, \gateSeconds, 0.0625, \gateRelease, 0.5, \voiceMute, 1].pairsDo({ arg name, value;
        command.(\setGrainParam, voice, name, value) }) });
    server.sync;
    reached = voices.every({ arg voice;
        var stage = engine.synths[engine.voiceMixKey(voice)];
        [[\seqGate, 1], [\gateSeconds, 0.0625], [\gateRelease, 0.5], [\voiceMute, 1]].every({ arg pair;
            getControl.(stage, pair[0]).equalWithPrecision(pair[1], 1e-6) and: { engine.grainControls[voice][pair[0]] == pair[1] } })
    });
    kept = voices.every({ arg voice;
        names.every({ arg name; engine.grainControlPairs(voice).includes(name).not }) and: { engine.synths[engine.grainKey(voice)].notNil }
    });
    check.(declared.every(_ == true) and: { inGrainDefs.isEmpty },
        "modulation: the stage has seqGate, gateSeconds, gateRelease and voiceMute (defaults %), no grain def does (%)".format(
            names.collect({ arg name; stageDesc.controls.detect({ arg each; each.name == name }) !? _.defaultValue }), inGrainDefs));
    check.(reached and: { kept },
        "modulation: setGrainParam sets the four on the stage and keeps them with the voice, never for a grain synth");
    voices.do({ arg voice;
        names.do({ arg name, index; command.(\setGrainParam, voice, name, defaults[index]) });
        command.(\voiceOff, voice);
    });
    h.stopAllVoices;
    voices.do({ arg voice, index; engine.grainControls[voice] = saved[index] });
    server.sync;
};

// A voice on each source kind, then each switched (a replacement grain
// synth): every grain synth and every stage reads its voice's block, which
// setGrainParam and setVoiceParam never replace
checkFastModIn = {
    var slot = 2, silent = state[\silentFastModBus].index;
    // [voice, first source, second source]
    var plan = [[0, 0, engine.inputSource], [1, slot + 1, 0], [2, engine.inputSource, slot + 1]];
    var read = { plan.collect({ arg each; getControl.(engine.synths[engine.grainKey(each[0])], \fastModIn) }) };
    var blocks = plan.collect({ arg each; engine.fastModBlock(each[0], 0) });
    var saved = plan.collect({ arg each; engine.grainControls[each[0]].copy });
    var first, second, stages, refused, kept;
    plan.do({ arg each;
        command.(\setGrainSource, each[0], each[1]);
        command.(\voiceOn, each[0], 110.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    });
    server.sync; 0.1.wait;
    first = read.value;
    plan.do({ arg each; command.(\setGrainSource, each[0], each[2]) });
    server.sync; 0.1.wait;
    second = read.value;
    stages = engine.numVoices.collect({ arg voice; getControl.(engine.synths[engine.voiceMixKey(voice)], \fastModIn) });
    kept = engine.grainControls[0][\fastModIn];
    command.(\setGrainParam, 0, \fastModIn, silent);
    command.(\setVoiceParam, 0, \fastModIn, silent);
    server.sync;
    refused = (engine.grainControls[0][\fastModIn] == kept) and: { engine.voiceControls[0][\fastModIn].isNil }
        and: { getControl.(engine.synths[engine.grainKey(0)], \fastModIn) == blocks[0] };
    check.((first == blocks) and: { second == blocks }
        and: { stages == engine.numVoices.collect({ arg voice; engine.fastModBlock(voice, 0) }) }
        and: { blocks.every({ arg block; block != silent }) },
        "modulation: every grain synth and stage starts with its voice's block as fastModIn (grain synths %, after a switch %, stages %; blocks %)".format(
            first, second, stages, blocks));
    check.(refused, "modulation: setGrainParam and setVoiceParam refuse fastModIn (#458)");
    plan.do({ arg each; command.(\voiceOff, each[0]) });
    h.stopAllVoices;
    plan.do({ arg each, index; engine.grainControls[each[0]] = saved[index] });
    server.sync;
};

// The grain defs and the stage default fastModIn to one silent fast bus,
// the one of the engine that built them, never control bus 0. The global
// SynthDescLib holds the defs of the engine built last, another area's in a
// full run, whose buses are not h.engine's: the descs are h.engine's when
// their other bus defaults (the stage's tapOut, the grain defs' recHeadBus)
// are its buses, and only then must the silent bus be h.engine's too
checkDefaults = {
    var silent = state[\silentFastModBus].index, defNames = [\strataGrainRing, \strataGrainBuf, \strataVoiceMix];
    var defaultOf = { arg defName, name;
        SynthDescLib.global.at(defName).controls.detect({ arg control; control.name == name }) !? _.defaultValue };
    var defaults = defNames.collect({ arg defName; defaultOf.(defName, \fastModIn) });
    var engines = (defaultOf.(\strataVoiceMix, \tapOut) == engine.areaState[\record][\tapSink].index)
        and: { [\strataGrainRing, \strataGrainBuf].every({ arg defName;
            defaultOf.(defName, \recHeadBus) == engine.areaState[\record][\idleHead].index }) };
    check.(defaults.every(_.notNil) and: { defaults.asSet.size == 1 } and: { defaults[0] != 0 }
        and: { engines.not or: { defaults[0] == silent } },
        "modulation: fastModIn defaults to silentFastModBus in both grain defs and the stage (%; this engine's silent bus %, its descs %)".format(
            defaults, silent, if (engines) { "this engine's" } { "another engine's" }));
};

// No def of the area has a LocalBuf, a delay line or a table: no UGen of a
// class that takes real-time memory (Delay1 and HPZ1 keep one sample in the
// unit, no memory of their own)
checkDefsSafe = {
    var forbidden = ["LocalBuf", "MaxLocalBufs", "DelayN", "DelayL", "DelayC", "BufDelay", "Comb", "BufComb", "Allpass",
        "BufAllpass", "PitchShift", "Grain", "TGrains", "Pluck", "FFT", "PV_", "Warp", "PlayBuf", "BufRd", "RecordBuf"];
    var found = areaDefs.collect({ arg defName;
        var desc = SynthDescLib.global.at(defName);
        if (desc.isNil) { [defName, \missing] } {
            desc.def.children.collect({ arg ugen; ugen.class.name.asString })
                .select({ arg name; forbidden.any({ arg prefix; name.beginsWith(prefix) }) })
        }
    });
    check.(found.every(_.isEmpty) and: { lfoDefs.size == engine.numFastLfoShapes },
        "modulation: no def of the area has a LocalBuf, a delay line or a table sized from a control (%)".format(
            [areaDefs, found].flop.reject({ arg pair; pair[1].isEmpty })));
};

// The velocity invariant: no def of the area has a velocity control, and in
// the stage (whose gate the area builds) velocity feeds only EnvGen
// levelScale inputs, never the gate's envelope
checkVelocity = {
    var withVelocity = areaDefs.select({ arg defName;
        SynthDescLib.global.at(defName).isNil or: {
            SynthDescLib.global.at(defName).controls.any({ arg control; control.name == \velocity }) } });
    var desc = SynthDescLib.global.at(\strataVoiceMix), ugens = desc.def.children;
    var velocity = desc.controls.detect({ arg each; each.name == \velocity });
    var isVelocity = { arg input; velocity.notNil and: { input.isKindOf(OutputProxy) } and: { input.source.isKindOf(Control) }
        and: { (input.source.specialIndex + input.outputIndex) == velocity.index } };
    var users = ugens.select({ arg ugen; (ugen.inputs ? []).any(isVelocity) });
    var onlyLevelScale = users.notEmpty and: { users.every({ arg ugen;
        ugen.isKindOf(EnvGen) and: { ugen.inputs.every({ arg input, index; isVelocity.(input).not or: { index == 1 } }) } }) };
    var envelopes = ugens.count({ arg ugen; ugen.isKindOf(EnvGen) });
    check.(withVelocity.isEmpty and: { onlyLevelScale } and: { envelopes >= 2 },
        "modulation: the velocity check passes on the area's defs (defs with a velocity control %; the stage's velocity users %, its envelopes %)".format(
            withVelocity, users.collect(_.class), envelopes));
};

// The area's start and stop on an engine of its own: its fastModGroup heads
// its xg with the offset node first, writing its bus; LFOs and scatter join
// it; its free leaves no node, group or bus
checkStartStop = {
    var other = h.startEngine, otherState = other.areaState[\modulation], group, buses, busIndex, nodes, first, left, running;
    group = otherState[\fastModGroup];
    buses = [otherState[\fastModBus], otherState[\silentFastModBus]];
    busIndex = buses[0] !? _.index;
    first = childrenOf.(other.context.xg).first;
    nodes = group !? { h.synthTree(group) } ? [];
    h.commandTo(other, \setFastLfo, 0, 0, 0, 6, 5.0, 0.5, 0.0);
    h.commandTo(other, \setScatter, 0.5, 0.3, 31, 127);
    server.sync; 0.1.wait;
    running = group !? { h.synthNames(group) } ? [];
    h.freeEngine(other);
    server.sync; 0.1.wait;
    left = h.synthNames(other.context.xg);
    check.((group.notNil and: { first == group.nodeID }) and: { nodes.size == 1 } and: { nodes[0][\def] == \strataFastOffsets }
        and: { busIndex.notNil } and: { nodes[0][\controls][\out] == busIndex }
        and: { running.asSet == Set[\strataFastOffsets, \strataFastLfoSmooth, \strataScatter] }
        and: { left.isEmpty } and: { buses.every({ arg bus; bus.isNil or: { bus.index.isNil } }) }
        and: { otherState[\lfos].every(_.isNil) } and: { otherState[\scatter].isNil },
        "modulation: one offset node at the head of fastModGroup from start to stop (an engine of its own: at start %, running %, after free % nodes, buses freed %)".format(
            nodes.collect(_[\def]), running, left.size, buses.collect({ arg bus; bus !? { bus.index.isNil } })));
};

// What the area leaves for the areas after it: every voice stopped, on its
// synth source, with the grain controls it found, and nothing modulating
checkVoicesLeft = {
    var sources = engine.grainSource.copy, running = (0 .. engine.numVoices - 1).select({ arg voice; engine.voiceRunning(voice) });
    var changed = (0 .. engine.numVoices - 1).reject({ arg voice; engine.grainControls[voice] == foundControls[voice] });
    check.(sources.every(_ == 0) and: { running.isEmpty } and: { changed.isEmpty } and: { readAll.value.every(_ == 0) }
        and: { lfoNodes.value.isEmpty },
        "modulation: the area leaves every voice on its synth source and every channel at 0 (sources %, running %, grain controls changed on %)".format(
            sources, running, changed));
};

if (area.isNil or: { state.isNil }) {
    check.(false, "modulation: the area runs at order 160 (no strataAreaModulation)");
} {
    var firstID;
    addCheckDefs.value;
    checkState.value;
    checkDefaults.value;
    checkChannels.value;
    firstID = checkOffsetNode.("at the area's start", nil);
    checkCommands.value;
    checkIgnored.value;
    checkBuses.value;
    checkOffsetWrites.value;
    checkLfoSeries.value;
    checkLfoSums.value;
    checkShapes.value;
    checkSync.value;
    checkScatter.value;
    checkScatterGlides.value;
    checkReleases.value;
    checkRegateEnded.value;
    checkPitch.value;
    checkGrainTaps.value;
    checkStageTaps.value;
    checkStageCutoff.value;
    checkStageAmp.value;
    checkEqual33.value;
    checkGates.value;
    checkGateLag.value;
    checkMute.value;
    checkGateEngine.value;
    checkGateKept.value;
    checkFastModIn.value;
    checkGateControls.value;
    checkDefsSafe.value;
    checkVelocity.value;
    checkOffsetNode.("at the area's end", firstID);
    checkVoicesLeft.value;
    // last: it builds an engine, whose defs then are the global descs
    checkStartStop.value;
};
}
