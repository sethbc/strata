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
    command.(\loadBuffer, 1, stereoPath);
    command.(\recordBuffer, 2, 0.2, 1.0);
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
check.(formatOf.(\loadBuffer) == "is" and: { formatOf.(\recordBuffer) == "iff" }
    and: { formatOf.(\clearBuffer) == "i" } and: { formatOf.(\saveBuffer) == "is" }
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
check.(names.size == (((engine.numVoices - 1) * 3) + 2 + 1 + (engine.numVoices + 1) + 4),
    "xg holds % voice trios, 1 buffer voice (grain + mod), the input synth, the ring writers, filter, delay, reverb and master (got %)".format(
        engine.numVoices - 1, names.size));
check.(names.indexOf(\strataInput) < firstGrain, "the input synth runs before grain synths");
check.(names.indexOf(voiceNames.last) < firstGrain, "voices run before grain/mod synths");
check.(grainIndices.maxItem < names.indexOf(\strataFilter), "grain/mod synths run before the effects chain");
check.(names.copyRange(names.size - 4, names.size - 1).asArray == chainDefs,
    "xg ends filter -> delay -> reverb -> master (got %)".format(names.copyRange(names.size - 4, names.size - 1)));
check.(names.last == \strataMaster, "master runs last inside xg (M5)");
check.(synthNames.(context.og).includes(\strataMaster).not, "master is not placed after og (M5)");
h.stopAllVoices;

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
}
