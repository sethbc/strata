// test/engine_check/freeze.scd
// Freeze: each source holds (a synth voice's ring, an input voice's copy,
// a buffer's scan) and unfreeze resumes; the input copy, in the voice's
// copy ring, its fade and its ring changes; the input grain synth as a
// reader of the copy; a source switch unfreezes; the voice's own ring
// never holds an input copy, so a synth-source grain synth never plays one
// (#494, #495); an unfreeze's re-point and freeze 0 in one bundle; spectral
// writers on a high engine (one writer per ring) and spectral on standard
// holding; free with a copy pending and the high tier's FFT buffers
// (#503).
//
// Most reads use a timecode, as the rings area does: a check synth writes
// the seconds since it started (left) and 1 (right) into voice 1's bus and
// the input bus (each switchable), and the same seconds to a private bus. A
// grain synth with a rectangular envelope then reads left/right as the time
// its audio was written.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var rings = engine.areaState[\rings], state = engine.areaState[\freeze];
var sampleRate = server.sampleRate, margin = engine.ringReadMargin;
// how much later than the clock was read a command may take effect: the
// server runs commands once per hardware period (1024 frames under the
// check's dummy JACK, 21 ms), and the read and the command each take a trip
var periodSlack = 0.06;
var probeGroup, quietBus, nowBus, clockBus, readOut, rectEnv, timecode, started;
var timeReads, startTimecodeVoice, now, phaseMoves, grainOf, fadingRingReader, voiceRing, inputRing, copyRing;
var readings, frozenAt, live, fading, ok, savedFadeWait = engine.bufferFadeWait;
var rampPath, rampFile, other, otherCommand, writerNodes, root, write, high, toggles;
var old, readsCopy, restartGrain, startInput;
var tone, meters, peaksOver, sentDuring, inOneBundle, ringPeak, writerBefore, kept, fails, failWatcher, standard;

// A grain synth's reads while seconds pass: [largest lookback, smallest
// lookback, largest read, smallest read, seconds with a grain]. Reads only
// while the right channel (1 in the ring) is above 0.05.
SynthDef(\strataCheckFreezeRead, { arg in, now, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset);
    var on = sig[1] > 0.05;
    var read = sig[0] / sig[1].max(0.001);
    var lookback = In.ar(now, 1) - read;
    Out.kr(out, A2K.kr([
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), lookback]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), lookback]), reset),
        RunningMax.ar(Select.ar(on, [DC.ar(-1000), read]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1000), read]), reset),
        Sweep.ar(reset, on)
    ]));
}).add;
// Where each grain starts reading: its read 1 ms in (a latch on the
// grain's first sample may still hold the read before it), held between
// grains
SynthDef(\strataCheckFreezeGrainStart, { arg in, out;
    var sig = In.ar(in, 2), on = sig[1] > 0.05;
    var read = sig[0] / sig[1].max(0.001);
    var onset = (on - Delay1.ar(on)) > 0;
    Out.kr(out, A2K.kr(Latch.ar(read, DelayN.ar(onset, 0.001, 0.001))));
}).add;
// The timecode: into out (voice 1's bus, while voiceOn > 0) and out2 (the
// input bus, while inputOn > 0); the time to now (audio) and nowKr
SynthDef(\strataCheckFreezeTimecode, { arg out, out2, now, nowKr, voiceOn = 1, inputOn = 1;
    var time = Sweep.ar(0, 1), sig = [time, DC.ar(1)];
    Out.ar(out, sig * voiceOn);
    Out.ar(out2, sig * inputOn);
    Out.ar(now, time);
    Out.kr(nowKr, A2K.kr(time));
}).add;
server.sync;

probeGroup = Group.after(engine.processGroup);
quietBus = Bus.audio(server, 2);    // where redirected voice synths play
nowBus = Bus.audio(server, 1);
clockBus = Bus.control(server, 1);
readOut = Bus.audio(server, 2);     // where a measured grain synth plays
rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0));
server.sync;

voiceRing = { arg voice; engine.ringBuffersFor(voice, 0) };
copyRing = { arg voice; engine.copyRingFor(voice) };
inputRing = engine.ringBuffersFor(0, engine.inputSource);
grainOf = { arg voice; engine.synths[engine.grainKey(voice)] };
now = { h.readBusValue(clockBus) };
// whether a phase bus moves over 0.2 s
phaseMoves = { arg bus; var first = h.readBusValue(bus); 0.2.wait; h.readBusValue(bus) != first };

// A voice's grain synth to readOut, then its reads while action runs and
// seconds pass
timeReads = { arg voice, seconds, action;
    var bus = Bus.control(server, 5), probe, values, synth = grainOf.(voice);
    synth.set(\out, readOut.index);
    probe = Synth(\strataCheckFreezeRead, [\in, readOut, \now, nowBus, \out, bus], probeGroup);
    server.sync; 0.05.wait;
    probe.set(\t_reset, 1); server.sync;
    action.value;
    seconds.wait;
    values = h.readBus(bus);
    probe.free; bus.free;
    synth.set(\out, engine.voicePathBus(voice, engine.grainSource[voice]).index);
    check.(getControl.(synth, \out) == engine.voicePathBus(voice, engine.grainSource[voice]).index,
        "freeze: a grain synth's out is restored to its own path (voice %)".format(voice));
    values
};
// Start a voice for the timecode reads: its voice synth (if any) played
// elsewhere, its grains through the rectangular envelope, no pan wander
// or position spread
startTimecodeVoice = { arg voice, source, size, density, pitch;
    command.(\setGrainSource, voice, source);
    command.(\voiceOn, voice, 100.0, 0.2, 0.0, size, density, pitch);
    server.sync;
    engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.set(\out, quietBus.index) };
    [\posSpread, \panSpread].do({ arg control; command.(\setGrainParam, voice, control, 0.0) });
    grainOf.(voice).set(\envBuf, rectEnv.bufnum);
    server.sync;
};
// The voice's fading strataGrainRing (a switch's), or nil
fadingRingReader = { arg voice;
    engine.fadingSynths[voice].detect({ arg synth; synth.isPlaying and: { synth.defName.asSymbol == \strataGrainRing } })
};
// Whether an input voice's grain synth reads its frozen copy: the copy
// ring at history 0, frozen, counted among the copy's readers
readsCopy = { arg voice, synth;
    var entry = state[\inputReaders][synth];
    (getControl.(synth, \bufL) == copyRing.(voice)[0].bufnum) and: { getControl.(synth, \phaseBus) == copyRing.(voice)[2].index }
        and: { getControl.(synth, \history) == 0 } and: { getControl.(synth, \freeze) == 1 }
        and: { entry.notNil } and: { entry[\until].isNil }
};
// Free a voice's live grain synth on the server behind sclang's back (a
// release that ended just as a gate came, as lifecycle.scd provokes it):
// whether the engine started another
restartGrain = { arg voice;
    var freed = grainOf.(voice), restarted;
    server.sendMsg(\n_free, freed.nodeID);
    restarted = h.waitFor({ grainOf.(voice).notNil and: { grainOf.(voice) !== freed } }, 0.3);
    server.sync;
    restarted
};
// voiceOn for a voice whose source is already set
startInput = { arg voice; command.(\voiceOn, voice, 100.0, 0.2, 0.0, 0.1, 10.0, 1.0) };
// Two peak meters on an engine: one on a voice's synth path just before
// its stage (what its synth-source grain synths write, which carries no
// voice level), one on the main bus after processGroup (every stage's dry
// output). peaksOver resets both, waits, and reads [synth path, main bus]
meters = { arg target, voice;
    var buses = 2.collect({ Bus.control(server, 1) });
    (synthPath: Synth(\strataCheckPeak, [\in, target.voicePathBus(voice, 0), \out, buses[0]],
        target.synths[target.voiceMixKey(voice)], \addBefore),
     main: Synth(\strataCheckPeak, [\in, target.mainBus, \out, buses[1]], target.processGroup, \addAfter),
     buses: buses)
};
peaksOver = { arg meter, seconds;
    meter[\synthPath].set(\t_reset, 1); meter[\main].set(\t_reset, 1);
    seconds.wait;
    [h.readBusValue(meter[\buses][0]), h.readBusValue(meter[\buses][1])]
};
// The largest sample of a mono buffer (a whole ring)
ringPeak = { arg buffer;
    var condition = Condition(false), values;
    buffer.loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition, 10);
    (values ? [1]).abs.maxItem
};
// What the engine sends while function runs (function must not yield):
// one entry per packet, the messages of a bundle kept together.
// (Server.addr_ reads addr and isLocal; Server.sendMsg, listSendMsg,
// sendBundle and listSendBundle all go through sendMsg and sendBundle, as
// in structure.scd. Server.makeBundle asks hasBundle, copies hostname and
// socket into a BundleNetAddr and sends what it gathered through
// sendClumpedBundles.)
sentDuring = { arg function;
    var sent = List.new, realAddr = server.addr;
    protect {
        server.addr = (
            addr: realAddr.addr, port: realAddr.port, isLocal: realAddr.isLocal, hostname: realAddr.hostname,
            socket: realAddr.socket, hasBundle: false,
            sendMsg: { arg self ... msg; sent.add([msg]); realAddr.sendMsg(*msg) },
            sendBundle: { arg self, time ... msgs; sent.add(msgs); realAddr.sendBundle(time, *msgs) },
            sendClumpedBundles: { arg self, time ... msgs; sent.add(msgs); realAddr.sendClumpedBundles(time, *msgs) }
        );
        function.value;
    } { server.addr = realAddr };
    sent
};
// Whether one packet sets both a node's ring (bufL) and its freeze control
// to value: an unfreeze's two changes land in one block (#535's reader
// holds the freeze flag for the block, so a split would start a block of
// grains on the input ring at the frozen read point)
inOneBundle = { arg packets, nodeID, value;
    var sets = { arg msg; ["15", "/n_set", "n_set"].includesEqual(msg[0].asString) and: { msg[1] == nodeID } };
    // where a control's name is in an n_set: [15, node, name, value, ...]
    var nameAt = { arg msg, name;
        msg.detectIndex({ arg item, index; (index >= 2) and: { index.even } and: { item.asString == name.asString } }) };
    packets.any({ arg packet;
        packet.any({ arg msg; sets.(msg) and: { nameAt.(msg, \bufL).notNil } })
            and: { packet.any({ arg msg; var at; sets.(msg) and: { (at = nameAt.(msg, \freeze)).notNil } and: { msg[at + 1] == value } }) }
    })
};

timecode = Synth(\strataCheckFreezeTimecode, [\out, engine.granBuses[0], \out2, engine.inputBus,
    \now, nowBus, \nowKr, clockBus], engine.voiceGroup, \addToHead);
started = Main.elapsedTime;

// ---- The area ----
check.([\frozen, \mode].every({ arg key; state[key].size == engine.numVoices })
    and: { state[\frozen].every(_.not) },
    "freeze: areaState[\\freeze] keeps \\frozen and \\mode per voice, nothing frozen");
check.(h.grainDefs.every({ arg name; h.controlFeedsAUGen(name, \freeze) }),
    "freeze: the freeze controls feed a UGen (freeze in both grain SynthDefs: the scan, the frozen ring's read point)");
check.([engine.scanRate(0.5, 0), engine.scanRate(0.5, 1)] == [0.5, 0],
    "freeze: scanRate is bufScan x (1 - freeze)");

// ---- The voice's own ring never holds an input copy (#494, #495) ----
// A 440 Hz tone at 0.5 on the input (the timecode's input off meanwhile)
// and voice 4 (engine 3) with no pan wander or position spread; meters on
// its synth path (what its synth-source grain synths write: no voice
// level) and on the main bus
timecode.set(\inputOn, 0);
tone = Synth(\strataCheckSine, [\out, engine.inputBus, \freq, 440], engine.voiceGroup, \addToHead);
standard = meters.(engine, 3);
// #494: the voice on its synth for a ring length and more, its voice synth
// playing elsewhere (so its ring holds silence), then switched to the
// input and frozen at once (a scene recall's order). The synth-source
// grain synth the switch leaves releasing reads the voice's own ring,
// which the copy never reaches: the synth path stays silent and the main
// bus never rises above the frozen voice's own level
startTimecodeVoice.(3, 0, 0.1, 10.0, 1.0);
(engine.ringSeconds + 0.4).wait;
command.(\setGrainSource, 3, engine.inputSource);
command.(\setGrainParam, 3, \freeze, 1.0);
readings = peaksOver.(standard, 2.4);
// the switch's releasing grain synth has ended by now (grainRelease 2 s):
// the frozen voice alone
kept = peaksOver.(standard, 0.6);
check.(state[\copied][3] and: { readings[0] < 1e-4 } and: { kept[1] > 0.02 } and: { readings[1] <= (kept[1] * 1.1) },
    "freeze: a fading synth-source grain synth never plays an input copy (synth path peak % over 2.4 s; main bus peak %, the frozen voice alone %)".format(
        readings[0].round(0.0001), readings[1].round(0.0001), kept[1].round(0.0001)));
command.(\setGrainParam, 3, \freeze, 0.0);
command.(\voiceOff, 3);
// #495: a frozen input voice at amp 0 switched to its synth. The new
// synth-source grain synth reads the voice's own ring, which holds only
// what the voice bus carried (silence: the voice was on the input, then
// its voice synth at amp 0), never the copy. At pitch 1 and at pitch 2 (a
// longer lookback), then for a voice stopped while frozen, moved to its
// synth and started again with no freeze resent (its writer never paused).
// Position spread at its default (0.5), so a grain starts up to 0.25 s
// back
command.(\setGrainParam, 3, \posSpread, 0.5);
[1.0, 2.0].do({ arg pitch;
    command.(\voiceOn, 3, 100.0, 0.0, 0.0, 0.1, 10.0, pitch);
    command.(\setGrainParam, 3, \freeze, 1.0);
    ok = h.waitFor({ state[\copied][3] }, 0.5);
    0.3.wait;
    command.(\setGrainSource, 3, 0);
    readings = peaksOver.(standard, 1.0);
    check.(ok and: { readings[0] < 1e-4 },
        "freeze: a frozen input voice switched to its synth keeps its synth path silent (pitch %: copied %, synth path peak % over the first second)".format(
            pitch, ok, readings[0].round(0.0001)));
    command.(\voiceOff, 3);
    command.(\setGrainSource, 3, engine.inputSource);
});
command.(\voiceOn, 3, 100.0, 0.0, 0.0, 0.1, 10.0, 1.0);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 0.5);
0.3.wait;
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
command.(\voiceOn, 3, 100.0, 0.0, 0.0, 0.1, 10.0, 1.0);
readings = peaksOver.(standard, 1.0);
check.(ok and: { state[\frozen][3] } and: { readings[0] < 1e-4 },
    "freeze: a voice stopped while frozen on the input and started on its synth keeps its synth path silent (copied %, still frozen on the input %, synth path peak % over the first second)".format(
        ok, state[\frozen][3], readings[0].round(0.0001)));
command.(\setGrainParam, 3, \freeze, 0.0);
command.(\voiceOff, 3);
server.sync;
tone.free;
[\synthPath, \main].do({ arg key; standard[key].free });
standard[\buses].do(_.free);
timecode.set(\inputOn, 1);

// ---- A synth voice: its ring held ----
// voice 1 on the timecode, its ring full of it (4 s and more)
startTimecodeVoice.(0, 0, 0.1, 10.0, 1.0);
(engine.ringSeconds + 0.3 - (Main.elapsedTime - started)).max(0).wait;
frozenAt = now.value;
command.(\setGrainParam, 0, \freeze, 1.0);
server.sync;
ok = phaseMoves.(rings[\phaseBuses][0]).not;
timecode.set(\voiceOn, 0);          // the voice's bus falls silent
0.3.wait;
readings = timeReads.(0, 1.0);
check.(ok and: { state[\frozen][0] } and: { state[\mode][0] == \hold } and: { readings[4] > 0.8 }
    and: { readings[2] <= (frozenAt + periodSlack) } and: { readings[3] >= (frozenAt - 1.0) }
    and: { (readings[2] - readings[3]) < 0.15 },
    "freeze: a frozen synth voice keeps sounding after its voice synth falls silent (writer paused %, % s of grains, reads % to % s, frozen at % s)".format(
        ok, readings[4].round(0.01), readings[3].round(0.001), readings[2].round(0.001), frozenAt.round(0.001)));
// the scan moves the read point back through the frozen ring, wrapping:
// at bufScan 1 (one ring length, 4 s, a second) each grain (0.1 s apart, 0.05 s long)
// starts about 0.4 s further back, and the start jumps up to the newest
// audio (the seam) once per 4 s of travel. Each grain's start, polled at
// 20 Hz for about 3 s
readings = { arg seconds;
    var bus = Bus.control(server, 1), synth = grainOf.(0), probe, starts = List.new, began, travel;
    synth.set(\out, readOut.index);
    probe = Synth(\strataCheckFreezeGrainStart, [\in, readOut, \out, bus], probeGroup);
    command.(\setGrainParam, 0, \grainSize, 0.05);  // a gap between grains, so each start shows
    server.sync; 0.2.wait;
    command.(\setGrainParam, 0, \bufScan, 1.0);
    server.sync;
    began = Main.elapsedTime;
    while { (Main.elapsedTime - began) < seconds } { starts.add(h.readBusValue(bus)); 0.05.wait };
    travel = (Main.elapsedTime - began) * engine.ringSeconds;
    command.(\setGrainParam, 0, \bufScan, 0.0);
    command.(\setGrainParam, 0, \grainSize, 0.1);
    probe.free; bus.free;
    synth.set(\out, engine.voicePathBus(0, engine.grainSource[0]).index);
    check.(getControl.(synth, \out) == engine.voicePathBus(0, engine.grainSource[0]).index,
        "freeze: the grain synth's out is restored to its own path (voice 0)");
    [starts.asArray.differentiate.drop(1), travel]
}.value(3.0);
ok = readings[0].select({ arg step; step.abs > 0.01 });
check.((ok.select({ arg step; step > 2 }).size).inclusivelyBetween((readings[1] / engine.ringSeconds).floor,
        (readings[1] / engine.ringSeconds).ceil)
    and: { ok.reject({ arg step; step > 2 }).every({ arg step; step < 0 }) }
    and: { ok.size > 20 },
    "freeze: bufScan moves the read point back through a frozen ring and passes the seam once per 4 s of travel (% s of travel, % seam jumps, % steps back, % forward)".format(
        readings[1].round(0.1), ok.count({ arg step; step > 2 }), ok.count({ arg step; step < 0 }),
        ok.count({ arg step; (step > 0) and: { step <= 2 } })));
// unfreeze: the writer resumes and the grains read just behind the head again
timecode.set(\voiceOn, 1);
command.(\setGrainParam, 0, \freeze, 0.0);
server.sync; 0.3.wait;
ok = phaseMoves.(rings[\phaseBuses][0]);
readings = timeReads.(0, 0.5);
check.(ok and: { state[\frozen][0].not } and: { readings[4] > 0.3 } and: { readings[1] >= (margin - 0.0005) }
    and: { readings[0] < 0.02 },
    "freeze: unfreeze resumes the live ring (writer moving %, lookback % to % s)".format(
        ok, readings[1].round(0.0001), readings[0].round(0.0001)));

// ---- Spectral asked for on the standard tier holds ----
command.(\setGrainParam, 0, \freezeMode, 1.0);
command.(\setGrainParam, 0, \freeze, 1.0);
server.sync;
writerNodes = h.synthTree(engine.voiceGroup).select({ arg node;
    [\strataRingWrite, \strataRingWriteSpectral].includes(node.def) });
ok = phaseMoves.(rings[\phaseBuses][0]).not;
check.((engine.tier == \standard) and: { state[\mode][0] == \hold } and: { ok }
    and: { writerNodes.every({ arg node; node.def == \strataRingWrite }) }
    and: { writerNodes.size == (engine.numVoices + 1) },
    "freeze: spectral on standard acts as hold (mode %, writer paused %, writers %)".format(
        state[\mode][0], ok, writerNodes.collect(_.def)));
command.(\setGrainParam, 0, \freeze, 0.0);
command.(\setGrainParam, 0, \freezeMode, 0.0);

// ---- A source switch unfreezes ----
command.(\setGrainParam, 0, \freeze, 1.0);
command.(\setGrainSource, 0, 2);
server.sync;
check.(state[\frozen][0].not and: { engine.grainControls[0][\freeze] == 0 } and: { phaseMoves.(rings[\phaseBuses][0]) }
    and: { getControl.(grainOf.(0), \freeze) == 0 },
    "freeze: a source switch unfreezes (the writer runs, the new grain synth starts at freeze 0)");
command.(\voiceOff, 0);
command.(\setGrainSource, 0, 0);

// ---- An input voice: the 4 s at its read point, copied into its copy ring ----
// voice 4 on the input ring at history 2; no reader of its copy ring, so
// the copy runs at once. Its own ring holds what its bus carried: silence
// (it was silent all through the checks above; an input voice's stage
// writes its mirror later in the block than the writer reads)
startTimecodeVoice.(3, engine.inputSource, 0.1, 10.0, 1.0);
command.(\setGrainParam, 3, \history, 2.0);
0.5.wait;
live = grainOf.(3);
writerBefore = engine.ringWriterFor(3);
frozenAt = now.value;
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 0.3);
server.sync;
check.(ok and: { getControl.(live, \bufL) == copyRing.(3)[0].bufnum } and: { getControl.(live, \history) == 0 }
    and: { getControl.(live, \phaseBus) == copyRing.(3)[2].index },
    "freeze: with no reader of its copy ring an input voice's copy runs at once and its grain synth reads it at history 0");
// the copy never touches the voice's own ring or its writer: the writer
// is the node it was, a strataRingWrite of the voice bus, running, and
// the ring still holds silence (no sample of the timecode, whose right
// channel is 1)
writerNodes = h.synthTree(engine.voiceGroup).select({ arg node; node.id == writerBefore.nodeID });
readings = [engine.ringWriterFor(3) === writerBefore, writerNodes.size == 1
    and: { writerNodes[0].def == \strataRingWrite } and: { writerNodes[0].controls[\in] == engine.granBuses[3].index },
    phaseMoves.(rings[\phaseBuses][3]), ringPeak.(rings[\voiceR][3]), ringPeak.(copyRing.(3)[1])];
check.(readings[0] and: { readings[1] } and: { readings[2] } and: { readings[3] < 1e-6 } and: { readings[4] > 0.9 }
    and: { getControl.(live, \bufL) == copyRing.(3)[0].bufnum },
    "freeze: an input freeze leaves the voice's ring and its writer alone (the same writer %, of the voice bus %, running %; voice ring peak %, copy ring peak %)".format(
        *readings.collect({ arg value; if (value.isNumber) { value.round(0.0001) } { value } })));
timecode.set(\inputOn, 0);          // the input falls silent
0.3.wait;
readings = timeReads.(3, 1.0);
check.((readings[4] > 0.8) and: { readings[2] <= (frozenAt - 2.0 + 0.05) } and: { readings[3] >= (frozenAt - 2.0 - 0.75) }
    and: { (readings[2] - readings[3]) < 0.15 },
    "freeze: input hold keeps the audio at the read point (history 2 s holds the tone from 2 s back: reads % to % s, frozen at % s)".format(
        readings[3].round(0.001), readings[2].round(0.001), frozenAt.round(0.001)));
// history is 0 inside the copy: a change is kept for the unfreeze
command.(\setGrainParam, 3, \history, 3.0); server.sync;
check.((getControl.(live, \history) == 0) and: { engine.grainControls[3][\history] == 3 },
    "freeze: history stays 0 inside the frozen copy (and is kept)");
command.(\setGrainParam, 3, \history, 2.0);
// the live grain synth reads the copy ring while frozen, and for 0.5 s
// after it is set back to the input ring. The unfreeze sets it back and
// sends its freeze 0 in one bundle, so both land in one block
timecode.set(\inputOn, 1);
ok = engine.copyRingReaders(3).includes(live);
kept = sentDuring.({ command.(\setGrainParam, 3, \freeze, 0.0) });
server.sync;
check.(inOneBundle.(kept, live.nodeID, 0),
    "freeze: an unfreeze sends the grain synth's re-point to the input ring and its freeze 0 in one bundle (packets sent: %)".format(kept));
0.2.wait;
readings = [engine.copyRingReaders(3).includes(live), getControl.(live, \bufL) == inputRing[0].bufnum,
    getControl.(live, \history)];
0.5.wait;
check.(ok and: { readings[0] } and: { readings[1] } and: { readings[2] == 2 }
    and: { engine.copyRingReaders(3).includes(live).not } and: { engine.ringReaders[live] == 3 },
    "freeze: the live input grain synth is a reader of the copy ring while frozen and for 0.5 s after unfreeze (frozen %, 0.2 s after %, back on the input ring %, history %)".format(
        ok, readings[0], readings[1], readings[2]));

// ---- A frozen input voice's grain synth reads the copy, however it starts ----
// (no freeze resend after voiceOn: what a grain synth reads is the engine's
// own answer, not Lua's)
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 0.3);
server.sync;
// re-gated inside its release: the same node
command.(\voiceOff, 3);
startInput.(3); server.sync;
check.(ok and: { grainOf.(3) === live } and: { getControl.(live, \history) == 0 }
    and: { getControl.(live, \bufL) == copyRing.(3)[0].bufnum },
    "freeze: a re-gated grain synth of a frozen input voice keeps reading the copy at history 0 (history %)".format(
        getControl.(live, \history)));
// a new grain synth once the old one has freed
command.(\voiceOff, 3);
ok = h.waitFor({ live.isPlaying.not }, engine.grainRelease + 1);
startInput.(3); server.sync;
live = grainOf.(3);
check.(ok and: { readsCopy.(3, live) },
    "freeze: a frozen input voice's new grain synth reads the copy (bufL is the copy ring's %)".format(
        getControl.(live, \bufL) == copyRing.(3)[0].bufnum));
// restarted by a late gate (its release ended as the gate came)
old = live;
ok = restartGrain.(3);
live = grainOf.(3);
check.(ok and: { live !== old } and: { readsCopy.(3, live) },
    "freeze: a grain synth restarted by a late gate on a frozen input voice reads the copy (bufL is the copy ring's %)".format(
        getControl.(live, \bufL) == copyRing.(3)[0].bufnum));
// an unfreeze reaches the restarted reader
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
check.((getControl.(live, \bufL) == inputRing[0].bufnum) and: { getControl.(live, \history) == 2 },
    "freeze: an unfreeze reaches a restarted reader (back on the input ring at history %)".format(getControl.(live, \history)));
0.6.wait;   // past freezeLeaveSeconds: the next freeze finds no reader

// ---- The fade before a copy ----
// Only an input grain synth reads a copy ring (a releasing synth-source
// grain synth reads its voice's own ring), so a copy waits only for a
// reader of the copy: a refreeze within freezeLeaveSeconds of an unfreeze,
// whose live grain synth's grains may still read the old copy. With
// bufferFadeWait 1 s, so the readings inside the wait have about 0.9 s to
// spare (#506)
engine.bufferFadeWait = 1.0;
// a refreeze inside that window: the live synth fades, the copy waits
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 0.3);
0.2.wait;
command.(\setGrainParam, 3, \freeze, 0.0);
0.1.wait;
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.05.wait;
readings = [getControl.(live, \ringLevel), getControl.(live, \bufL) == inputRing[0].bufnum];
0.15.wait;
readings = readings ++ [getControl.(live, \bufL) == inputRing[0].bufnum];
ok = h.waitFor({ state[\copied][3] }, 2);
server.sync;
check.(ok and: { readings[0] == 0 } and: { readings[1] } and: { readings[2] } and: { getControl.(live, \bufL) == copyRing.(3)[0].bufnum }
    and: { getControl.(live, \ringLevel) == 1 },
    "freeze: a refreeze inside that window fades before copying (ringLevel %, input ring at 0.05 s % and 0.2 s %, then the copy at ringLevel 1)".format(
        readings[0], readings[1], readings[2]));
command.(\setGrainParam, 3, \freeze, 0.0);

// a switch from the synth to the input leaves the synth-source grain synth
// releasing, a reader of the voice's own ring and none of the copy ring:
// a freeze then lands at once (no wait, though bufferFadeWait is 1 s) and
// never fades it. (First past freezeLeaveSeconds: the input grain synth
// just set back, releasing after the voiceOff, no longer counts as a
// reader of the copy)
0.6.wait;
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
startTimecodeVoice.(3, 0, 0.1, 10.0, 1.0);
0.3.wait;
command.(\setGrainSource, 3, engine.inputSource); server.sync;
fading = fadingRingReader.(3);
live = grainOf.(3);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 0.3);
server.sync;
readings = [ok, fading.notNil and: { getControl.(fading, \ringLevel) == 1 }, getControl.(live, \bufL) == copyRing.(3)[0].bufnum,
    state[\faded][3].isEmpty];
check.(readings.every({ arg value; value == true }),
    "freeze: a switch from the synth to the input leaves no reader of the copy ring: the copy lands at once and the releasing synth-source grain synth keeps ringLevel 1 (copied within 0.3 s, ringLevel 1, on the copy, nothing faded: %)".format(
        readings));
command.(\setGrainParam, 3, \freeze, 0.0);

// an unfreeze inside the copy's wait wins: no copy, the reader back at
// ringLevel 1. The wait is a refreeze's (above); the copy ring's right
// channel is zeroed first (the timecode's right channel is 1)
0.6.wait;   // past freezeLeaveSeconds: the first freeze finds no reader
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 0.3);
command.(\setGrainParam, 3, \freeze, 0.0);
copyRing.(3)[1].zero; server.sync;
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.1.wait;
readings = [state[\faded][3].notEmpty, state[\copied][3].not];
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
1.2.wait;
readings = readings ++ [0, 0.25, 0.5, 0.75, 0.999].collect({ arg fraction;
    h.bufferSample(copyRing.(3)[1], (fraction * (copyRing.(3)[1].numFrames - 1)).asInteger) });
check.((getControl.(live, \bufL) == inputRing[0].bufnum) and: { state[\copied][3].not } and: { readings[0] } and: { readings[1] }
    and: { readings.drop(2).every({ arg value; value != 1 }) } and: { getControl.(live, \ringLevel) == 1 },
    "freeze: an unfreeze inside the copy's wait wins (waiting % %; no copy: the copy ring reads %; the reader back at ringLevel 1)".format(
        readings[0], readings[1], readings.drop(2).round(0.001)));
// a grain synth restarted inside the copy's wait reads the input ring at
// the voice's history, then the copy once it is in
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 2);
command.(\setGrainParam, 3, \freeze, 0.0);
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.05.wait;
ok = restartGrain.(3);
live = grainOf.(3);
readings = [state[\faded][3].notEmpty, state[\copied][3].not, getControl.(live, \bufL) == inputRing[0].bufnum, getControl.(live, \history)];
h.waitFor({ state[\copied][3] }, 2);
server.sync;
check.(ok and: { readings[0] } and: { readings[1] } and: { readings[2] } and: { readings[3] == 2 }
    and: { getControl.(live, \bufL) == copyRing.(3)[0].bufnum } and: { getControl.(live, \history) == 0 },
    "freeze: a restart inside a copy's wait reads the input ring, then the copy (waiting %, not copied %, input ring %, history %)".format(
        readings[0], readings[1], readings[2], readings[3]));
command.(\setGrainParam, 3, \freeze, 0.0);
// a voiceOff inside the copy's wait: the copy lands while the voice is
// stopped (no live grain synth to point at it), and a voiceOn inside the
// release re-gates the same grain synth onto the copy, with no freeze
// resend; the unfreeze sets it back
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 2);
command.(\setGrainParam, 3, \freeze, 0.0);
old = grainOf.(3);
command.(\setGrainParam, 3, \freeze, 1.0); server.sync;
0.05.wait;
command.(\voiceOff, 3); server.sync;
readings = [state[\faded][3].notEmpty, state[\copied][3].not];
ok = h.waitFor({ state[\copied][3] }, 2);
startInput.(3); server.sync;
live = grainOf.(3);
readings = readings ++ [ok, live === old, getControl.(live, \bufL) == copyRing.(3)[0].bufnum,
    getControl.(live, \history) == 0,
    state[\inputReaders][live].notNil and: { state[\inputReaders][live][\until].isNil }];
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
readings = readings ++ [getControl.(live, \bufL) == inputRing[0].bufnum, getControl.(live, \history) == 2];
check.(readings.every({ arg value; value == true }),
    "freeze: a grain synth re-gated onto a copy that landed while its voice was stopped is set back by the unfreeze (waiting, not copied, copied, same node, on the copy, history 0, a reader, back on the input ring, history 2: %)".format(
        readings));
engine.bufferFadeWait = savedFadeWait;
command.(\setGrainParam, 3, \history, 0.0);
// a frozen input voice switched to its synth: unfrozen, its writer reads the voice bus again
command.(\setGrainParam, 3, \freeze, 1.0);
h.waitFor({ state[\copied][3] }, 0.3);
command.(\setGrainSource, 3, 0); server.sync;
writerNodes = h.synthTree(engine.voiceGroup).select({ arg node; node.id == engine.synths[engine.ringWriterKeys[3]].nodeID });
check.(state[\frozen][3].not and: { writerNodes.size == 1 } and: { writerNodes[0].controls[\in] == engine.granBuses[3].index }
    and: { phaseMoves.(rings[\phaseBuses][3]) },
    "freeze: a source switch unfreezes an input voice (its writer reads its voice bus and runs)");
command.(\voiceOff, 3);
// a source changed while a frozen input voice was stopped: the grain synth
// voiceOn starts reads the new source and is no reader of the copy
command.(\setGrainSource, 3, engine.inputSource);
startInput.(3);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 2);
old = grainOf.(3);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 1);
ok = ok and: { h.waitFor({ old.isPlaying.not }, engine.grainRelease + 1) };
startInput.(3); server.sync;
live = grainOf.(3);
check.(ok and: { live.defName.asSymbol == \strataGrainBuf } and: { state[\inputReaders][live].isNil },
    "freeze: a source changed while a frozen input voice was stopped starts on the new source (%)".format(live.defName));
command.(\setGrainParam, 3, \freeze, 0.0);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
// the source changed to the synth while a frozen input voice was stopped: the
// new synth-source grain synth is never counted a reader of the input copy
// (it would read the live input after the unfreeze), once the old grain synth
// has freed and once inside its release
command.(\setGrainSource, 3, engine.inputSource);
startInput.(3);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 2);
old = grainOf.(3);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
ok = ok and: { h.waitFor({ old.isPlaying.not }, engine.grainRelease + 1) };
startInput.(3); server.sync;
live = grainOf.(3);
readings = [ok, live.defName.asSymbol == \strataGrainRing, state[\inputReaders][live].isNil,
    getControl.(live, \bufL) == voiceRing.(3)[0].bufnum, getControl.(live, \history) == 0,
    state[\frozen][3], phaseMoves.(rings[\phaseBuses][3])];
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
readings = readings ++ [getControl.(live, \bufL) == voiceRing.(3)[0].bufnum, state[\frozen][3].not,
    phaseMoves.(rings[\phaseBuses][3])];
check.(readings.every({ arg value; value == true }),
    "freeze: a synth source started after the old grain synth freed is no reader of the input copy (freed, ring def, no reader, own ring, history 0, still frozen on the input, its writer running: an input freeze never pauses it; after freeze 0: own ring, unfrozen, writer runs: %)".format(readings));
command.(\voiceOff, 3);
command.(\setGrainSource, 3, engine.inputSource);
startInput.(3);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 2);
old = grainOf.(3);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
startInput.(3); server.sync;
live = grainOf.(3);
readings = [ok, live !== old, live.defName.asSymbol == \strataGrainRing, state[\inputReaders][live].isNil,
    getControl.(live, \bufL) == voiceRing.(3)[0].bufnum];
command.(\setGrainParam, 3, \freeze, 0.0); server.sync;
readings = readings ++ [getControl.(live, \bufL) == voiceRing.(3)[0].bufnum,
    old.isPlaying.not or: { getControl.(old, \bufL) == inputRing[0].bufnum }];
check.(readings.every({ arg value; value == true }),
    "freeze: a synth source started inside the old grain synth's release is no reader of the input copy (copied, new node, ring def, no reader, own ring; after freeze 0: own ring, the old one set back: %)".format(readings));
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);
// inputReaders forgets a reader that frees: a frozen input voice stopped
// and started three times (Lua resending freeze after each voiceOn) counts
// only its live grain synth
command.(\setGrainSource, 3, engine.inputSource);
startInput.(3);
command.(\setGrainParam, 3, \freeze, 1.0);
ok = h.waitFor({ state[\copied][3] }, 2);
3.do({
    old = grainOf.(3);
    command.(\voiceOff, 3);
    ok = ok and: { h.waitFor({ old.isPlaying.not }, engine.grainRelease + 1) };
    startInput.(3);
    command.(\setGrainParam, 3, \freeze, 1.0);
});
server.sync;
check.(ok and: { state[\inputReaders].size == 1 } and: { state[\inputReaders].keys.asArray[0] === grainOf.(3) },
    "freeze: inputReaders forgets a reader that frees (% entries, % of them freed)".format(
        state[\inputReaders].size, state[\inputReaders].keys.count({ arg synth; synth.isPlaying.not })));
command.(\setGrainParam, 3, \freeze, 0.0);
command.(\voiceOff, 3);
command.(\setGrainSource, 3, 0);

// ---- A buffer voice: the scan stops, spread still moves ----
// slot 6 holds a 1 s ramp (left 0 -> 1, right 1), so a grain's read is its
// position in the slot
rampPath = h.tempDir +/+ "freeze-ramp.wav";
rampFile = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(sampleRate.asInteger);
rampFile.openWrite(rampPath);
rampFile.writeData(h.stereoOf(h.rampSignal(sampleRate.asInteger) / sampleRate, h.repeating(sampleRate.asInteger, [1.0])));
rampFile.close;
command.(\loadBuffer, 5, rampPath, 0);
h.waitFor({ engine.bufferFrames[5] > 0 }, 3);
startTimecodeVoice.(1, 6, 0.05, 20.0, 1.0);
command.(\setGrainParam, 1, \bufScan, 0.5);
0.3.wait;
readings = [timeReads.(1, 0.5)];
command.(\setGrainParam, 1, \freeze, 1.0);
0.2.wait;
readings = readings ++ [timeReads.(1, 0.5)];
command.(\setGrainParam, 1, \posSpread, 0.5);
0.2.wait;
readings = readings ++ [timeReads.(1, 0.5)];
readings = readings.collect({ arg reads; reads[2] - reads[3] });
check.((readings[0] > 0.2) and: { readings[1] < 0.08 } and: { readings[2] > 0.2 },
    "freeze: buffer hold stops the scan while spread still moves (read spans scanning, frozen, frozen with spread: %)".format(
        readings.round(0.001)));
command.(\setGrainParam, 1, \freeze, 0.0);
command.(\setGrainParam, 1, \bufScan, 0.0);
command.(\voiceOff, 1);
command.(\setGrainSource, 1, 0);

timecode.free;
h.stopAllVoices;
engine.numVoices.do({ arg voice; command.(\setGrainParam, voice, \freeze, 0.0); command.(\setGrainParam, voice, \freezeMode, 0.0) });
server.sync;

// ---- Spectral writers (a high engine) ----
root = h.tempDir +/+ "freeze-high/";
write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
File.mkdir(root);
write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
otherCommand = { arg name ... args; h.commandTo(other, name, *args) };
high = other.tier == \high;
// the spectral writer's def is added by a high engine only (so not in the
// runner's allDefs, which the structure area checks on the standard engine)
check.(high and: { SynthDescLib.global.at(\strataRingWriteSpectral).notNil }
    and: { SynthDescLib.global.at(\strataRingWriteSpectral).controlNames.collect(_.asSymbol) == [\in, \bufL, \bufR, \phaseOut, \fftL, \fftR] }
    and: { other.areaState[\freeze][\spectralBuffers].size == other.numVoices }
    and: { other.areaState[\freeze][\spectralBuffers].flat.every({ arg buffer; buffer.numFrames == other.spectralFrames }) },
    "freeze: a high engine adds strataRingWriteSpectral, with strataRingWrite's controls and a voice's FFT pair (fftL, fftR)");
check.(engine.areaState[\freeze][\spectralBuffers] == [],
    "freeze: a standard engine allocates no spectral FFT buffers");
writerNodes = {
    h.synthTree(other.voiceGroup).select({ arg node; [\strataRingWrite, \strataRingWriteSpectral].includes(node.def) })
};
otherCommand.(\voiceOn, 0, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
otherCommand.(\setGrainParam, 0, \freezeMode, 1.0);
server.sync;
toggles = 20.collect({ arg index;
    var frozen = index.even, nodes, spectral, key = other.ringWriterKeys[0];
    otherCommand.(\setGrainParam, 0, \freeze, if (frozen) { 1.0 } { 0.0 });
    server.sync; 0.05.wait;
    nodes = writerNodes.value;
    spectral = nodes.select({ arg node; node.def == \strataRingWriteSpectral });
    (nodes.size == (other.numVoices + 1)) and: { spectral.size == if (frozen) { 1 } { 0 } }
        and: { nodes.any({ arg node; node.id == other.synths[key].nodeID }) }
        and: { (other.areaState[\rings][\writers][0] === other.synths[key]) }
        and: { frozen.not or: { spectral[0].controls[\in] == other.granBuses[0].index } }
        and: { phaseMoves.(other.areaState[\rings][\phaseBuses][0]) }
});
check.(high and: { toggles.every(_.value) } and: { other.areaState[\freeze][\frozen][0].not },
    "freeze: spectral writer replacement leaves one writer per voice (high %, 20 toggles: %)".format(high, toggles));
// spectral on silence (a stopped voice: its bus is silent) writes only the
// dither, far below hearing: no buzz at the hop rate
otherCommand.(\setGrainParam, 4, \freezeMode, 1.0);
otherCommand.(\setGrainParam, 4, \freeze, 1.0);
server.sync; 0.6.wait;
readings = {
    var condition = Condition(false), values;
    other.ringBuffersFor(4, 0)[0].loadToFloatArray(action: { arg array; values = array; condition.test = true; condition.signal });
    h.awaitReply(condition, 10);
    (values ? [1]).abs.maxItem
}.value;
check.((writerNodes.value.count({ arg node; node.def == \strataRingWriteSpectral }) == 1) and: { readings < 0.001 },
    "freeze: a spectral writer frozen on silence writes nothing audible (ring peak %)".format(readings));
otherCommand.(\setGrainParam, 4, \freeze, 0.0);
server.sync;
// #495 with a spectral input freeze: a frozen input voice at amp 0
// switched to its synth keeps its synth path silent (the spectral writer
// of the input writes the copy ring only)
tone = Synth(\strataCheckSine, [\out, other.inputBus, \freq, 440], other.voiceGroup, \addToHead);
standard = meters.(other, 5);
otherCommand.(\setGrainSource, 5, other.inputSource);
otherCommand.(\voiceOn, 5, 100.0, 0.0, 0.0, 0.1, 10.0, 1.0);
otherCommand.(\setGrainParam, 5, \freezeMode, 1.0);
server.sync; 0.2.wait;
otherCommand.(\setGrainParam, 5, \freeze, 1.0);
ok = h.waitFor({ other.areaState[\freeze][\copied][5] }, 0.5);
0.5.wait;   // the spectral writer writes the held input meanwhile
otherCommand.(\setGrainSource, 5, 0);
readings = peaksOver.(standard, 1.0);
check.(ok and: { readings[0] < 1e-4 },
    "freeze: a frozen input voice switched to its synth keeps its synth path silent (spectral, high tier: copied %, synth path peak % over the first second)".format(
        ok, readings[0].round(0.0001)));
otherCommand.(\voiceOff, 5);
server.sync;
tone.free;
[\synthPath, \main].do({ arg key; standard[key].free });
standard[\buses].do(_.free);
// spectral on an input voice: the copy, then a spectral writer of the
// input into the voice's copy ring, a node of its own (copyWriterKeys);
// the voice's own writer still writes its voice bus
otherCommand.(\setGrainSource, 2, other.inputSource);
otherCommand.(\voiceOn, 2, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
otherCommand.(\setGrainParam, 2, \freezeMode, 1.0);
server.sync; 0.2.wait;
writerBefore = other.ringWriterFor(2);
otherCommand.(\setGrainParam, 2, \freeze, 1.0);
h.waitFor({ other.areaState[\freeze][\copied][2] }, 0.5);
server.sync;
readings = writerNodes.value;
kept = readings.detect({ arg node; node.id == (other.synths[other.copyWriterKeys[2]] !? { arg synth; synth.nodeID }) });
readings = readings.detect({ arg node; node.id == other.ringWriterFor(2).nodeID });
check.(kept.notNil and: { kept.def == \strataRingWriteSpectral } and: { kept.controls[\in] == other.inputBus.index }
    and: { kept.controls[\bufL] == other.copyRingFor(2)[0].bufnum } and: { kept.controls[\phaseOut] == other.copyRingFor(2)[2].index }
    and: { getControl.(other.synths[other.grainKey(2)], \bufL) == other.copyRingFor(2)[0].bufnum }
    and: { phaseMoves.(other.copyRingFor(2)[2]) }
    and: { other.ringWriterFor(2) === writerBefore } and: { readings.notNil } and: { readings.def == \strataRingWrite }
    and: { readings.controls[\in] == other.granBuses[2].index },
    "freeze: spectral on an input voice writes the held input into its copy ring, which its grain synth reads; the voice's own writer still writes its voice bus (copy writer %, own writer %)".format(
        kept !? { arg node; node.def }, readings !? { arg node; node.def }));
// a mode change while frozen: spectral -> hold pauses the writer instead
// (voice 2's copy writer is the one spectral writer left)
otherCommand.(\setGrainParam, 0, \freeze, 1.0);
otherCommand.(\setGrainParam, 0, \freezeMode, 0.0);
server.sync; 0.05.wait;
check.((other.areaState[\freeze][\mode][0] == \hold) and: { writerNodes.value.count({ arg node; node.def == \strataRingWriteSpectral }) == 1 }
    and: { phaseMoves.(other.areaState[\rings][\phaseBuses][0]).not },
    "freeze: a mode change while frozen freezes again in the new mode");
check.(other.grainControls[0][\freeze] == 1,
    "freeze: a freezeMode change keeps a frozen voice's freeze control (kept %)".format(other.grainControls[0][\freeze]));
other.numVoices.do({ arg voice; otherCommand.(\setGrainParam, voice, \freeze, 0.0) });
server.sync;
check.(other.synths[other.copyWriterKeys[2]].isNil and: { writerNodes.value.count({ arg node; node.def == \strataRingWriteSpectral }) == 0 }
    and: { writerNodes.value.size == (other.numVoices + 1) },
    "freeze: an unfreeze frees the spectral copy writer (no copyWrite node, one writer per ring)");
// free with a spectral copy writer running (#503): the area's stop frees
// it and its free the FFT buffers (voice 2, still on the input, freezeMode 1)
otherCommand.(\setGrainParam, 2, \freeze, 1.0);
ok = h.waitFor({ other.synths[other.copyWriterKeys[2]].notNil }, 0.5);
kept = other.areaState[\freeze][\spectralBuffers].flat;
h.stopAllVoices(other);
h.freeEngine(other);
server.sync; 0.2.wait;
check.(ok and: { kept.size == (2 * other.numVoices) } and: { kept.every({ arg buffer; buffer.bufnum.isNil }) }
    and: { h.synthNames(other.context.xg).includes(\strataRingWriteSpectral).not }
    and: { other.copyWriterKeys.every({ arg key; other.synths[key].isNil }) },
    "freeze: free with a spectral copy writer running frees it, and the high tier's FFT buffers (copy writer running %, % FFT buffers freed %)".format(
        ok, kept.size, kept.count({ arg buffer; buffer.bufnum.isNil })));

// ---- free with an input copy waiting for its fade (#503) ----
// A second standard engine with bufferFadeWait 1 s: an input voice frozen,
// unfrozen and frozen again at once (its live grain synth still reads the
// old copy, so the second copy waits), then the engine freed inside the
// wait: the copy never runs against the freed rings and buses (no server
// failure, no error, \copied false)
other = h.startEngine;
otherCommand = { arg name ... args; h.commandTo(other, name, *args) };
other.bufferFadeWait = 1.0;
otherCommand.(\setGrainSource, 2, other.inputSource);
otherCommand.(\voiceOn, 2, 100.0, 0.2, 0.0, 0.1, 10.0, 1.0);
server.sync; 0.2.wait;
otherCommand.(\setGrainParam, 2, \freeze, 1.0);
ok = h.waitFor({ other.areaState[\freeze][\copied][2] }, 0.5);
otherCommand.(\setGrainParam, 2, \freeze, 0.0);
otherCommand.(\setGrainParam, 2, \freeze, 1.0);
readings = [ok, other.areaState[\freeze][\faded][2].notEmpty, other.areaState[\freeze][\copied][2].not];
fails = List.new;
failWatcher = OSCFunc({ arg msg; fails.add(msg.copyRange(1, 2)) }, '/fail', server.addr);
h.freeEngine(other);
1.5.wait; server.sync;
failWatcher.free;
check.(readings.every({ arg value; value == true }) and: { other.areaState[\freeze][\copied][2].not } and: { fails.isEmpty },
    "freeze: free with an input copy waiting for its fade runs none of it (copied, waiting, not copied: %; copied after the free %; server failures %)".format(
        readings, other.areaState[\freeze][\copied][2], fails));
server.sync;

probeGroup.free;
[quietBus, nowBus, clockBus, readOut].do(_.free);
rectEnv.free;
server.sync;
}
