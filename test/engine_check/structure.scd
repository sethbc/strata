// test/engine_check/structure.scd
// The engine's structure: every SynthDef is built, the command signatures,
// the state of a fresh engine (empty slots, synth sources, the live input),
// commands on a never-started voice, node ordering inside context.xg, and
// free (on a second engine, with fades still pending). Runs first, so the
// fresh-engine checks see the engine as alloc left it.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var formatOf = { arg name; h.formatOf(name) };
var synthNames = { arg group; h.synthNames(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var voiceDefs = h.voiceDefs, allDefs = h.allDefs, grainDefs = h.grainDefs, chainDefs = h.chainDefs;
var names, voiceNames, grainIndices, firstGrain, other;

// free with fades still pending (#22, #47): with a long fade wait, a
// clear, a load and a recording on slots that running voices read (voices 1-3,
// engine 0-2, read slots 1-3), then free at once. Nothing that waited runs
// afterward: no zeroing, read or record synth reaches the freed buffers and
// nodes (the server reports no failure) and no slot change completes. Frees
// the engine (a second instance, so the other areas keep theirs).
var freeDuringPendingFades = { arg engine, stereoPath;
    var command = { arg name ... args; h.commandTo(engine, name, *args) };
    var fails = List.new, watcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr), waiting;
    var sent, realAddr, nodeFrees, bufferFrees;
    engine.bufferFadeWait = 0.5;
    command.(\clearBuffer, 0);
    command.(\loadBuffer, 1, stereoPath, 0);
    command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0);
    waiting = (0..2).every({ arg slot; engine.slotPlaying(slot) }) and: { engine.recordSynths[2].notNil };
    // every message free sends, in order (free never yields, so only the
    // engine's messages pass through the recording address meanwhile)
    // (Server.addr_ reads addr and isLocal; Server.sendMsg, listSendMsg,
    // sendBundle and listSendBundle all go through sendMsg and sendBundle)
    sent = List.new; realAddr = server.addr;
    protect {
        server.addr = (
            addr: realAddr.addr, port: realAddr.port, isLocal: realAddr.isLocal,
            sendMsg: { arg self ... msg; sent.add(msg); realAddr.sendMsg(*msg) },
            sendBundle: { arg self, time ... msgs; sent.addAll(msgs); realAddr.sendBundle(time, *msgs) }
        );
        h.freeEngine(engine);
    } { server.addr = realAddr };
    nodeFrees = sent.selectIndices({ arg msg; ["11", "/n_free", "n_free"].includesEqual(msg[0].asString) });
    bufferFrees = sent.selectIndices({ arg msg; ["32", "/b_free", "b_free"].includesEqual(msg[0].asString) });
    check.(nodeFrees.notEmpty and: { bufferFrees.notEmpty } and: { nodeFrees.maxItem < bufferFrees.minItem },
        "free sends every node free before any buffer free (node frees at %, buffer frees from %)".format(
            nodeFrees, bufferFrees.minItem));
    1.0.wait; server.sync;
    watcher.free;
    check.(waiting and: { fails.isEmpty } and: { engine.bufferFrames[1] == 0 } and: { engine.recordSynths.every(_.isNil) },
        "free with a clear, a load and a recording waiting for their fade runs none of them (waiting %, server failures %)".format(
            waiting, fails));
};

// SynthDefs
allDefs.do({ arg name;
    check.(SynthDescLib.global.at(name).notNil, "SynthDef % built".format(name));
});

// Command signatures
check.(formatOf.(\voiceOn) == "iffffff", "voiceOn signature is iffffff (C1)");
check.(formatOf.(\retrigger) == "if", "retrigger signature is if (voice, velocity)");
check.(formatOf.(\setFilter) == "ffif", "setFilter signature is ffif");
check.(formatOf.(\setDelay) == "fff", "setDelay signature is fff");
check.(formatOf.(\setGrainSource) == "ii", "setGrainSource ii");
check.(formatOf.(\loadBuffer) == "isf" and: { formatOf.(\recordBuffer) == "ifffifif" }
    and: { formatOf.(\clearBuffer) == "i" } and: { formatOf.(\saveBuffer) == "isff" }
    and: { formatOf.(\stopRecord) == "i" }, "buffer command signatures");

// A fresh engine: empty slots, every voice on its synth, the live input
check.(engine.bufferFrames == Array.fill(8, 0), "every slot starts empty");
check.(engine.grainSource == Array.fill(engine.numVoices, 0), "every voice starts on its synth source");
check.(engine.inputBus.numChannels == 2 and: { engine.inputBus.rate == \audio }, "inputBus is a stereo audio bus");
check.(engine.inputSynth.defName == \strataInput
    and: { getControl.(engine.inputSynth, \out) == engine.inputBus.index }, "strataInput writes inputBus");
names = synthNames.(engine.voiceGroup);
check.(names.asArray == ([\strataInput] ++ (\strataRingWrite ! (engine.numVoices + 1))),
    "strataInput and the ring writers run in the voice group (got %)".format(names));

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

// Node ordering inside context.xg (M5)
h.startAllVoices;
names = synthNames.(context.xg);
voiceNames = names.select({ arg name; voiceDefs.includes(name) });
grainIndices = names.collect({ arg name, index; if (grainDefs.includes(name) or: { name == \strataMod }) { index } }).reject(_.isNil);
firstGrain = grainIndices.minItem;
check.(names.size == (((engine.numVoices - 1) * 3) + 2 + 1 + (engine.numVoices + 1) + engine.numVoices + 6),
    "xg holds % voice trios, 1 buffer voice (grain + mod), the input synth, the ring writers, the stages, filter x3, delay, reverb and master (got %)".format(
        engine.numVoices - 1, names.size));
check.(names.indexOf(\strataInput) < firstGrain, "the input synth runs before grain synths");
check.(names.indexOf(voiceNames.last) < firstGrain, "voices run before grain/mod synths");
check.(grainIndices.maxItem < names.indexOf(\strataFilter), "grain/mod synths run before the effects chain");
if (engine.respondsTo(\voiceMixKey).not) {
    check.(false, "structure: the node order is voiceGroup, processGroup (synth-source grain synths, then each voice's mix group before its mod synth), then the effects chain");
} {
    // the groups' order in the engine group's tree: voiceGroup, processGroup,
    // then the effects chain; inside processGroup the synth-source grain
    // synths (head), then each voice's mix group, its mod synth just after it
    var nodes = h.synthTree(context.xg), synthPaths, firstStage, lastSynthGrain;
    var positionOf = { arg def; nodes.detectIndex({ arg node; node.def == def }) };
    var stageAndMod = { arg voice;
        var stageAt = nodes.detectIndex({ arg node; (node.def == \strataVoiceMix) and: { node.controls[\mirrorOut] == engine.granBuses[voice].index } });
        var modAt = nodes.detectIndex({ arg node; (node.def == \strataMod) and: { node.controls[\in] == engine.granBuses[voice].index } });
        [stageAt, modAt]
    };
    synthPaths = engine.areaState[\mix][\synthPaths].collect(_.index);
    firstStage = nodes.detectIndex({ arg node; node.def == \strataVoiceMix });
    lastSynthGrain = nodes.selectIndices({ arg node; (node.def == \strataGrainRing) and: { synthPaths.includes(node.controls[\out].asInteger) } }).maxItem;
    check.((positionOf.(\strataInput) < firstStage) and: { nodes.detectIndex({ arg node; node.def == voiceDefs[0] }) < firstStage }
        and: { lastSynthGrain.notNil } and: { lastSynthGrain < firstStage }
        and: { (0..engine.numVoices - 1).every({ arg voice;
            var pair = stageAndMod.(voice); pair[0].notNil and: { pair[1].notNil } and: { pair[1] == (pair[0] + 1) } }) }
        and: { firstStage < positionOf.(\strataFilter) },
        "structure: the node order is voiceGroup, processGroup (synth-source grain synths, then each voice's mix group before its mod synth), then the effects chain");
};
check.(names.copyRange(names.size - 4, names.size - 1).asArray == chainDefs,
    "xg ends filter -> delay -> reverb -> master (got %)".format(names.copyRange(names.size - 4, names.size - 1)));
check.(names.last == \strataMaster, "master runs last inside xg (M5)");
check.(synthNames.(context.og).includes(\strataMaster).not, "master is not placed after og (M5)");
h.stopAllVoices;

// The 3.3 surface
check.(engine.strataAreas.select({ arg area; [\record, \waveform, \positions].includes(area[\name]) })
    .collect({ arg area; [area[\name], area[\order]] }) == [[\record, 130], [\waveform, 140], [\positions, 150]],
    "structure: the record, waveform and positions areas run at orders 130, 140 and 150");
check.(grainDefs.every({ arg name;
        var controls = SynthDescLib.global.at(name).controlNames.collect(_.asSymbol);
        [\recHeadBus, \scrubRate, \scanHold, \t_scanReset].every({ arg control; controls.includes(control) })
    }), "structure: both grain defs declare recHeadBus, scrubRate, scanHold and t_scanReset");
check.((engine.waveformPoints == 64) and: { engine.areaState[\waveform][\peakBuffers].size == 8 }
    and: { engine.areaState[\waveform][\peakBuffers].every({ arg buffer; (buffer.numFrames == 64) and: { buffer.numChannels == 1 } }) },
    "structure: waveformPoints is 64 and the waveform area holds eight 64-frame peak buffers");
engine.numVoices.do({ arg voice;
    command.(\setGrainSource, voice, voice + 1);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
});
server.sync;
check.(engine.numVoices.collect({ arg voice;
        var control = getControl.(engine.synths[engine.grainKey(voice)], \recHeadBus);
        (control == engine.slotHeadBus(voice).index) and: { control != engine.areaState[\record][\idleHead].index }
    }).every(_ == true), "structure: every buffer grain synth gets its slot's recHeadBus");
h.stopAllVoices;

// A triggered buffer grain, from the engine's def and from the copy of 3.2's
// in the check (h.def32), both with no spreads: identical on the server
{
    var rate = server.sampleRate.asInteger, path = h.tempDir +/+ "structure-grain.wav";
    var period = Array.fill(1000, { arg i; sin(2pi * 7 * i / 1000) * 0.5 });
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    var buses = 2.collect({ Bus.audio(server, 2) }), sink = Bus.audio(server, 2), peaks = Bus.control(server, 2);
    var group = Group.after(engine.processGroup), ids, values;
    var args = { arg out; [\out, out, \mirrorOut, sink, \bufnumL, engine.buffersL[0].bufnum, \bufnumR, engine.buffersR[0].bufnum,
        \bufRateScale, 1, \bufFrames, rate * 2, \bufPos, 0.25, \grainSize, 0.1, \grainMode, 1, \posSpread, 0, \panSpread, 0,
        \delaySendOut, sink.index, \reverbSendOut, sink.index, \fxMixIn, engine.mixBus(\fxMix).index] };
    file.openWrite(path);
    h.writePeriodicSeconds(file, period, 2, rate);
    file.close;
    command.(\loadBuffer, 0, path, 0);
    h.waitFor({ engine.bufferFrames[0] > 0 });
    ids = 2.collect({ server.nextNodeID });
    // both grain synths in one bundle, so both start in one block
    // (3.2's def has the sends: at 0 its dry output is the signal itself)
    server.sendBundle(nil,
        (['/s_new', \strataGrainBuf, ids[0], 1, group.nodeID] ++ args.(buses[0])).asOSCArgArray,
        (['/s_new', h.def32[\grainBuf], ids[1], 1, group.nodeID] ++ args.(buses[1]) ++ [\delaySend, 0, \reverbSend, 0]).asOSCArgArray);
    server.sync;
    Synth(\strataCheckBusDiff, [\a, buses[0], \b, buses[1], \out, peaks], group, \addToTail);
    0.3.wait;                  // past the grain synths' attack
    server.sendBundle(nil, ['/n_set', ids[0], \t_trig, 1], ['/n_set', ids[1], \t_trig, 1]);
    0.3.wait; server.sync;
    values = h.readBus(peaks);
    group.free; server.sync;
    command.(\clearBuffer, 0);
    buses.do(_.free); sink.free; peaks.free;
    check.((values[1] > 0.001) and: { values[0] < 1e-6 },
        "structure: a triggered buffer grain with spreads 0 matches 3.2's within 1e-6 (difference %, level %)".format(values[0], values[1]));
}.value;

// free, on a second engine whose voices 1-3 read slots 1-3
other = h.startEngine;
3.do({ arg voice;
    h.commandTo(other, \setGrainSource, voice, voice + 1);
    h.commandTo(other, \voiceOn, voice, 110.0, 0.2, 0.0, 0.5, 20.0, 1.0);
});
server.sync; 0.2.wait;
freeDuringPendingFades.(other, h.stereoPath);
server.sync;
check.(synthNames.(other.context.xg).size == 0, "free removes every engine node");
check.(other.envBuffers.every({ arg buffer; buffer.bufnum.isNil }), "free frees the envelope buffers");
check.((other.buffersL ++ other.buffersR).every({ arg buffer; buffer.bufnum.isNil }), "free frees the buffer slots");
check.(([other.inputBus, other.silentBus, other.mainBus, other.filterBus, other.delayBus, other.reverbBus]
    ++ other.granBuses ++ other.modBuses ++ other.recordFrameBuses).every({ arg bus; bus.index.isNil }),
    "free frees every engine bus");
check.((other.areaState[\record][\headBuses] ++ other.areaState[\record][\voiceTaps]
        ++ [other.areaState[\record][\tapSink], other.areaState[\record][\idleHead]]).every({ arg bus; bus.index.isNil })
    and: { other.areaState[\waveform][\peakBuffers].every({ arg buffer; buffer.bufnum.isNil }) },
    "structure: free frees the head buses, the voice taps and the peak buffers");
}
