// test/engine_check/buffers.scd
// Buffer slots: their layout, recording into a slot a voice reads, the
// bufferState and bufferLoadFailed polls, stopRecord, clearBuffer, loads
// (stereo, mono, too long, missing, unreadable, damaged) and their failure
// reports, a file's rate and pitch, and fade before zeroing (every
// interleaving inside the fade wait, releasing and fading grain synths),
// and the high tier's 60 s slots: loads checked in a routine and what
// wins over them, on a high engine of their own.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var waitFor = { arg condition, timeout = 3; h.waitFor(condition, timeout) };
var synthNames = { arg group; h.synthNames(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var bufferSample = { arg buffer, frame; h.bufferSample(buffer, frame) };
var readBusValue = { arg bus; h.readBusValue(bus) };
var scratchRoot = h.tempDir;
var stereoPath = h.stereoPath, monoPath = h.monoPath, longPath = h.longPath, textPath = h.textPath;
var before, scratchFile, file, frames, info, tone, probe, peakBus, readPeak, duringPeak, afterPeak;

// bufferState poll value: ((the slot's loads % bufferStateLoads) *
// (numBuffers + 1) + slot index) * bufferStateStride + valid seconds
// (#578; seconds below the stride, so the thousands name one slot and its
// load number); stateBase is a slot's thousands on an engine (h.engine
// unless given) now, which the reports since its last load carry. Checked
// over the poll's values with Signal arithmetic (h.pollValueNear), never a
// function per message: the run's messages grow all run long (#131)
var stateBase = { arg slot, target;
    target = target ? engine;
    (((target.bufferLoads[slot] % target.bufferStateLoads) * (target.numBuffers + 1)) + slot) * target.bufferStateStride
};
var bufferStateSeen = { arg slot, seconds, target; h.pollValueNear(\bufferState, stateBase.(slot, target) + seconds, 0.011) };
// bufferState poll values received so far
var bufferStateValues = { h.pollValues(\bufferState) };
// bufferLoadFailed poll values received so far
var loadFailures = { h.pollValues(\bufferLoadFailed) };

// Buffer and file checks in functions of their own, called from the check
// routine: its function is near sclang's per-function selector table limit
// (a function that exceeds it does not compile, and the check never ends).

// A missing, unreadable or empty file loaded into a slot that is recording
// cancels the recording (Lua's load_buffer assumes so): the take never
// completes, the slot stays empty and no scratch take is written
var checkBadLoadsDuringRecording = { arg textPath, stereoPath;
    var emptyPath = scratchRoot +/+ "no-frames.wav", file, info, goodLoad;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(1).sampleRate_(44100);
    file.openWrite(emptyPath); file.close;
    [[scratchRoot +/+ "missing.wav", "missing", 0.1], [textPath, "unreadable", 0.1], [emptyPath, "empty", 0.1],
        [emptyPath, "empty (recording not started yet)", 0]].do({ arg bad;
        File.delete(engine.scratchDir +/+ "buf7.wav");
        command.(\recordBuffer, 6, 0.3, 1.0, 0, 0, 0, 0, 0);
        bad[2].wait; server.sync;
        info = engine.recordSynths[6].notNil;
        command.(\loadBuffer, 6, bad[0], 0); 0.6.wait; server.sync;
        check.(info and: { engine.recordSynths[6].isNil } and: { engine.bufferFrames[6] == 0 }
            and: { synthNames.(context.xg).includes(\strataRecord).not }
            and: { File.exists(engine.scratchDir +/+ "buf7.wav").not },
            "a % file loaded during a recording cancels it: no take, nothing written (% frames)".format(
                bad[1], engine.bufferFrames[6]));
    });
    // ... also one stopped early whose frame count has not arrived yet: the
    // late reply keeps nothing
    File.delete(engine.scratchDir +/+ "buf7.wav");
    command.(\recordBuffer, 6, 1.0, 1.0, 0, 0, 0, 0, 0); 0.3.wait; server.sync;
    info = engine.recordSynths[6].notNil;
    command.(\stopRecord, 6);
    command.(\loadBuffer, 6, scratchRoot +/+ "missing.wav", 0);
    1.0.wait; server.sync;
    check.(info and: { engine.bufferFrames[6] == 0 } and: { engine.stopReplies[6].isNil }
        and: { File.exists(engine.scratchDir +/+ "buf7.wav").not },
        "a missing file loaded right after stopRecord cancels the stopped take: no take, nothing written (% frames)".format(
            engine.bufferFrames[6]));
    // ... but a good load sent between them is a change of its own, which
    // drops the awaited frame count: the missing file then finds no take to
    // cancel and leaves the good load alone (#47)
    File.delete(engine.scratchDir +/+ "buf7.wav");
    command.(\recordBuffer, 6, 1.0, 1.0, 0, 0, 0, 0, 0); 0.3.wait; server.sync;
    info = engine.recordSynths[6].notNil;
    command.(\stopRecord, 6);
    command.(\loadBuffer, 6, stereoPath, 0);
    goodLoad = engine.bufferLoads[6];
    command.(\loadBuffer, 6, scratchRoot +/+ "missing.wav", 0);
    // (the stopped take's late frame count has come and been dropped by
    // then; the good load is waited for itself, the missing file's never
    // taking effect)
    1.0.wait; h.awaitLoad(6, nil, 5, goodLoad);
    check.(info and: { engine.bufferFrames[6] == 11025 } and: { (bufferSample.(engine.buffersL[6], 100) - 0.5).abs < 0.001 }
        and: { File.exists(engine.scratchDir +/+ "buf7.wav").not },
        "a missing file loaded after stopRecord and a good load leaves the good load (% frames), no take written".format(
            engine.bufferFrames[6]));
    command.(\clearBuffer, 6); server.sync;
};

// A FLAC whose data is overwritten from a third of the way in: its header
// is sound (SoundFile.openRead gives its frames), but libsndfile stops
// decoding early, and the server's /b_readChannel then fills the rest with
// silence without any /fail (measured with scsynth 3.14: 12288 of 48000
// frames decode). Returns its path and whether its header reads. Decoding
// it makes libFLAC 1.4 print "Rewinding, seeking necessary" to stderr:
// expected, harmless, not silenceable from sclang, and not matched by
// run_engine_check.sh's error patterns.
var writeDamagedFlac = { arg path;
    var file = SoundFile.new.headerFormat_("FLAC").sampleFormat_("int16").numChannels_(1).sampleRate_(48000);
    var bytes, header, headerReads, start;
    file.openWrite(path); file.writeData(h.noise(48000, 0.5)); file.close;
    file = File(path, "rb"); bytes = Int8Array.newClear(file.length); file.read(bytes); file.close;
    start = bytes.size div: 3;
    bytes.overWrite(Int8Array.newClear(bytes.size - start).fill(0x55), start);
    file = File(path, "wb"); file.write(bytes); file.close;
    header = SoundFile.openRead(path);
    headerReads = header.notNil and: { header.numFrames == 48000 };
    if (header.notNil) { header.close };
    [path, headerReads]
};

// A missing, unreadable, empty or damaged file loaded into a slot holding
// audio leaves the audio, and the bufferLoadFailed poll reports exactly that
// load ((load number * 2 + 0) * 8 + slot index: not emptied) as a float,
// once; a good load reports nothing. Slot 4 holds the stereo file's 11025
// frames.
var checkLoadFailureReports = { arg textPath, stereoPath;
    var emptyPath = scratchRoot +/+ "no-frames-4.wav", file, before, damaged;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(1).sampleRate_(44100);
    file.openWrite(emptyPath); file.close;
    damaged = writeDamagedFlac.(scratchRoot +/+ "damaged.flac");
    check.(damaged[1], "the damaged FLAC still has a sound header (48000 frames)");
    [[textPath, "unreadable"], [scratchRoot +/+ "missing.wav", "missing"], [emptyPath, "empty"],
        [damaged[0], "damaged FLAC"]].do({ arg bad;
        before = loadFailures.value.size;
        command.(\loadBuffer, 4, bad[0], 0);
        check.(waitFor.({ loadFailures.value.size > before }),
            "the % file loaded over audio is reported by bufferLoadFailed".format(bad[1]));
        0.2.wait; server.sync;
        check.(loadFailures.value.drop(before) == [(engine.bufferLoads[4] * 2) * engine.numBuffers + 4]
            and: { loadFailures.value.last.isKindOf(Float) },
            "the report names slot 4 and its load number % once, as a float (got %)".format(
                engine.bufferLoads[4], loadFailures.value.drop(before)));
        check.(engine.bufferFrames[4] == 11025 and: { (bufferSample.(engine.buffersL[4], 100) - 0.5).abs < 0.001 },
            "the % file left the slot's audio".format(bad[1]));
    });
    before = loadFailures.value.size;
    command.(\loadBuffer, 4, stereoPath, 0); h.awaitLoad(4);
    check.(loadFailures.value.size == before and: { engine.bufferFrames[4] == 11025 },
        "a good load reports no failure");
};

// A file at another rate plays at its own pitch: a 1 kHz sine written at
// 44.1 kHz, played by voice 7 (engine voice 6, reading slot 4) through
// strataGrainBuf (every grain from one position, so overlapping grains stay
// in phase) and measured by Pitch on the voice's bus mirror. 919 Hz would
// mean the rate scale is applied twice (by the engine and by GrainBuf),
// 1088 Hz not at all. Then a take recorded into the same slot (the server
// keeps the buffer's 44.1 kHz rate) plays at the recorded tone's pitch.
var checkFilePitch = {
    var sinePath = scratchRoot +/+ "sine-44100.wav", file, pitchBus, probe, tone, readPitch, pitches;
    SynthDef(\strataCheckPitch, { arg in, out;
        Out.kr(out, Pitch.kr(In.ar(in, 2)[0], minFreq: 200, maxFreq: 4000)[0]);
    }).add;
    server.sync;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(44100);
    file.openWrite(sinePath);
    // 2 s on both sides: a period of 441 frames holds 10 cycles
    file.writeData({ var sine = h.periodic((0 .. 440).collect({ arg frame; sin(2pi * 1000 * frame / 44100) * 0.5 }), 0, 44100 * 2);
        h.stereoOf(sine, sine) }.value);
    file.close;
    command.(\loadBuffer, 3, sinePath, 0); h.awaitLoad(3);
    [[\bufPos, 0.25], [\bufScan, 0], [\posSpread, 0], [\bufRate, 1], [\pitchShift, 1],
        [\grainSize, 0.2], [\grainDensity, 20], [\grainMode, 0]].do({ arg pair;
        command.(\setGrainParam, 6, pair[0], pair[1]);
    });
    command.(\setVoiceParam, 6, \bend, 1);
    pitchBus = Bus.control(server, 1);
    probe = Synth(\strataCheckPitch, [\in, engine.granBuses[6], \out, pitchBus], engine.processGroup, \addToTail);
    // eleven readings over a second, sorted: the middle one is the median
    readPitch = {
        1.0.wait;
        11.collect({
            var condition = Condition(false), value;
            0.1.wait;
            pitchBus.get({ arg result; value = result; condition.test = true; condition.signal });
            awaitReply.(condition);
            value
        }).sort
    };
    pitches = readPitch.value;
    check.((pitches[5] - 1000).abs < 10,
        "a 44.1 kHz file plays at its own pitch (a 1 kHz sine measures % Hz; readings %)".format(
            pitches[5].round(0.1), pitches.round(0.1)));
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
    command.(\recordBuffer, 3, 1.0, 1.0, 0, 0, 0, 0, 0); h.awaitTake(3);
    tone.free;
    pitches = readPitch.value;
    check.(engine.bufferFrames[3] > 0 and: { (pitches[5] - 440).abs < 5 },
        "a take recorded over a 44.1 kHz file plays at its pitch (a 440 Hz tone measures % Hz; readings %)".format(
            pitches[5].round(0.1), pitches.round(0.1)));
    probe.free; pitchBus.free;
};

// Two back-to-back loads into a slot no voice plays both read at once: a
// /fail for the first one's file (simulated here, as the server sends it)
// fails only that load, never the second one's good read of another file.
// The failure says the slot was emptied only while nothing has changed it
// since (#1035): a failed read alone is emptied, the first of the two is
// not, the second load having taken effect after it
var checkReadFailureMatching = { arg stereoPath, monoPath;
    var firstPath = scratchRoot +/+ "first-of-two.wav", before, firstLoad, alone, aloneLoad;
    var issued, firstRead = {
        issued = h.wireUnits({ command.(\loadBuffer, 5, firstPath, 0) }).flatten(1)
            .detect({ arg msg; msg[0].asString == "/b_readChannel" })[2];
    };
    var failRead = { thisProcess.recvOSCmessage(0, server.addr, NetAddr.langPort, ['/fail', '/b_readChannel',
        "File '" ++ issued ++ "' could not be opened: System error : No such file or directory.\n",
        engine.buffersL[5].bufnum]) };
    File.delete(firstPath); File.copy(monoPath, firstPath);
    before = loadFailures.value.size;
    firstRead.value;
    aloneLoad = engine.bufferLoads[5];
    failRead.value;
    waitFor.({ loadFailures.value.size > before });
    alone = loadFailures.value.drop(before);
    before = loadFailures.value.size;
    firstRead.value;
    firstLoad = engine.bufferLoads[5];
    command.(\loadBuffer, 5, stereoPath, 0);
    failRead.value;
    h.awaitLoad(5);
    waitFor.({ loadFailures.value.size > before });
    check.(loadFailures.value.drop(before).collect({ arg value; ((value - 5) / (engine.numBuffers * 2)).floor }) == [firstLoad],
        "a /fail names its file: only the first of two loads fails (got %)".format(loadFailures.value.drop(before)));
    check.((alone == [((aloneLoad * 2) + 1) * engine.numBuffers + 5])
        and: { loadFailures.value.drop(before) == [(firstLoad * 2) * engine.numBuffers + 5] },
        "a failed server read reports the slot emptied only while nothing has changed it since (#1035): alone % (expected %), superseded % (expected %)".format(
            alone, [((aloneLoad * 2) + 1) * engine.numBuffers + 5],
            loadFailures.value.drop(before), [(firstLoad * 2) * engine.numBuffers + 5]));
    check.(engine.bufferFrames[5] == 11025, "the second load's good read is kept (% frames)".format(engine.bufferFrames[5]));
    File.delete(firstPath);
};

// Rewrite the pathname while an active voice fades, in both directions.
var checkReplacedFileLoad = {
    var slot = 2, path = scratchRoot +/+ "changing-load.wav";
    var stereo = [48000, 9000, [0.25, -0.25]], mono = [32000, 3000, [0.75]];
    [[stereo, mono], [mono, stereo]].do({ arg pair;
        var old = pair[0], new = pair[1], before = loadFailures.value.size, values, expected, peaks;
        var rate, frames, wantedPeak = old[2][0], seconds = (old[1] / old[0]).round(0.01);
        h.writeTestFile(path, old[0], old[1], old[2]);
        command.(\loadBuffer, slot, path, 0);
        h.writeTestFile(path, new[0], new[1], new[2]);
        h.awaitLoad(slot); server.sync;
        values = [100, 6000].collect({ arg frame;
            [bufferSample.(engine.buffersL[slot], frame), bufferSample.(engine.buffersR[slot], frame)]
        }).flat;
        expected = if (old === stereo) { [0.25, -0.25, 0.25, -0.25] } { [0.75, 0.75, 0, 0] };
        peaks = engine.areaState[\waveform][\peaks][slot];
        frames = engine.bufferFrames[slot]; rate = engine.bufferSampleRates[slot];
        check.((frames == old[1]) and: { rate == old[0] } and: { (peaks.minItem - wantedPeak).abs < 0.001 }
            and: { (peaks.maxItem - wantedPeak).abs < 0.001 } and: { values.every({ arg v, i; (v - expected[i]).abs < 0.001 }) }
            and: { loadFailures.value.size == before } and: { bufferStateSeen.(slot, seconds) },
            "buffers: replacing a checked % channel file during the fade installs the checked audio (frames %, rate %, peak %, samples %, failures %)".format(
                old[2].size, frames, rate, peaks.maxItem, values, loadFailures.value.drop(before)));
    });
};
// Staging fails before the slot is changed. The old audio and its
// overview remain usable and a later load can use the scratch directory.
var checkLoadStagingFailure = {
    var slot = 2, original = engine.scratchDir, failures = loadFailures.value.size, expected;
    var frames = engine.bufferFrames[slot], rate = engine.bufferSampleRates[slot], peak = engine.areaState[\waveform][\peaks][slot].copy;
    var left = bufferSample.(engine.buffersL[slot], 100), right = bufferSample.(engine.buffersR[slot], 100);
    protect {
        engine.scratchDir = stereoPath; // an existing file cannot hold a snapshot
        command.(\loadBuffer, slot, monoPath, 0);
        expected = engine.bufferLoads[slot] * 2 * engine.numBuffers + slot;
    } { engine.scratchDir = original };
    check.(waitFor.({ loadFailures.value.drop(failures) == [expected] }) and: { engine.bufferFrames[slot] == frames }
        and: { engine.bufferSampleRates[slot] == rate } and: { engine.areaState[\waveform][\peaks][slot] == peak }
        and: { bufferSample.(engine.buffersL[slot], 100) == left } and: { bufferSample.(engine.buffersR[slot], 100) == right },
        "buffers: an unavailable staging directory reports one unchanged failure and preserves the slot");
};
// Integer series at zero and one frame: never select a nonexistent
// channel or lose the lone frame at a waveform bin boundary.
var checkPackedLoadEdges = {
    var samples = engine.playedLoadChunk(Signal.newClear(0), 3, 0);
    check.(samples.notNil and: { samples.isEmpty }, "buffers: packing zero three-channel frames gives an empty stage chunk");
    samples = engine.playedLoadChunk(Signal[0.25, -0.5, 0.75], 3, 1);
    check.((samples.size == 2) and: { samples[0] == 0.25 } and: { samples[1] == -0.5 },
        "buffers: packing one three-channel frame keeps exactly its first stereo pair");
};
// Without a language yield, all eight read pairs still own their private
// input, even if the server has already completed some reads.
var checkLoadSnapshotBudget = {
    var other = h.startEngine, live = other.areaState[\buffers][\snapshots];
    var path = scratchRoot +/+ "snapshot-budget.wav", n = loadFailures.value.size, bytes = 0, healthy = true, zeroes = 0, left = other.buffersL[0];
    h.writeTestFile(path, 48000, 9000, [0.25, -0.5, 0.8]);
    other.numBuffers.do({ arg i; h.commandTo(other, \loadBuffer, i, path, 0) });
    live.do({ arg name;
        var info = SoundFile.openRead(name);
        bytes = bytes + File.fileSize(name);
        healthy = healthy and: { info.numFrames == 9000 } and: { info.numChannels == 2 };
        info.close;
    });
    check.(live.size == other.numBuffers and: { healthy } and: { bytes <= (other.numBuffers * ((9000 * 8) + 1024)) },
        "buffers: eight pending reads own eight stages limited to the selected stereo samples (bytes %)".format(bytes));
    other.buffersL[0] = (numFrames: left.numFrames, bufnum: left.bufnum,
        zero: { zeroes = zeroes + 1; left.zero },
        readChannel: { arg self ... args; left.performList(\readChannel, args) });

    other.numBuffers.do({ arg i; h.commandTo(other, \loadBuffer, i, monoPath, 0) });
    h.commandTo(other, \clearBuffer, 1);
    h.commandTo(other, \loadBuffer, 2, stereoPath, 0);
    h.commandTo(other, \loadBuffer, 3, textPath, 0);
    check.(live.size == other.numBuffers and: { h.waitFor({
        other.bufferFrames == [4410, 0, 11025, 4410, 4410, 4410, 4410, 4410] and: { live.isEmpty }
    }, 3) } and: { loadFailures.value.drop(n) == [(6 * other.numBuffers) + 3] }
        and: { (bufferSample.(left, 100) - 0.4).abs < 0.001 }
        and: { (bufferSample.(other.buffersR[0], 100) - 0.4).abs < 0.001 }
        and: { (bufferSample.(other.buffersR[2], 100) + 0.25).abs < 0.001 }
        and: { (other.scratchDir +/+ "strata-load-*.part").pathMatch.isEmpty },
        "buffers: two full-slot restores keep eight stages, clear cancels, a later replacement wins and a bad later load preserves the queued load (frames %, failures %)".format(other.bufferFrames, loadFailures.value.drop(n)));
    check.(zeroes == 1, "buffers: the deferred load zeroes its buffer once after fading (% zeroes)".format(zeroes));
    other.buffersL[0] = left;
    h.freeEngine(other);
};
// A and B are both valid at admission, then B vanishes before a stage
// is available. Lua must receive an emptied B, never a rollback to A.
var checkDeferredLoadFailure = {
    var other = h.startEngine, slot = 7, path = scratchRoot +/+ "deferred-gone.wav", n = loadFailures.value.size;
    var cancel, accepted, state, failures;
    h.commandTo(other, \loadBuffer, slot, stereoPath, 0); h.awaitLoad(slot, other);
    h.commandTo(other, \loadBuffer, slot, textPath, 0);
    waitFor.({ loadFailures.value.size == (n + 1) });
    check.(other.bufferFrames[slot] == 11025 and: { loadFailures.value.drop(n) == [4 * other.numBuffers + slot] },
        "buffers: a missing source before admission reports unchanged and keeps the stereo slot");
    h.commandTo(other, \recordBuffer, slot, 2, 1, 0.5, 0, 0, 0, 0, 0); 0.12.wait; h.server.sync;
    cancel = other.slotRecording(slot);
    File.copy(stereoPath, path); n = loadFailures.value.size;
    other.numBuffers.do({ arg i; h.commandTo(other, \loadBuffer, i % 7, stereoPath, 0) });
    h.commandTo(other, \loadBuffer, slot, monoPath, 0);
    accepted = other.slotRecording(slot).not;
    h.commandTo(other, \loadBuffer, slot, path, 0);
    File.delete(path);
    waitFor.({ loadFailures.value.size > n });
    h.server.sync;
    failures = loadFailures.value.drop(n); state = other.bufferStateReport(slot, other.bufferStateSeconds(slot));
    check.(cancel and: { accepted }, "buffers: a valid short load ends its active take immediately even with eight outstanding reads");
    check.(failures == [(9 * other.numBuffers) + slot] and: { other.bufferFrames[slot] == 0 }
        and: { other.bufferSampleRates[slot] == h.server.sampleRate } and: { other.areaState[\waveform][\peaks][slot].maxItem == 0 }
        and: { bufferSample.(other.buffersL[slot], 100) == 0 } and: { bufferSample.(other.buffersR[slot], 100) == 0 }
        and: { h.pollValueNear(\bufferState, state, 0.001) },
        "buffers: B disappearing after displacing A reports B emptied and zero playable frames, samples and peaks (state %, failures %)".format(state, failures));
    h.freeEngine(other);
};
// Losing directory write permission after the reads were sent must not
// lose the accounting for a snapshot that could not be removed.
var checkLoadSnapshotCleanup = { arg freeAtEnd;
    var other = h.startEngine, dir = other.scratchDir, denied, files;
    var probe = dir +/+ "unlink-probe", live = other.areaState[\buffers][\snapshots];
    File.mkdir(dir); File.use(probe, "w", { arg f; f.write("probe") });
    h.commandTo(other, \loadBuffer, 0, stereoPath, 0);
    protect {
        ("chmod 555 " ++ dir.shellQuote).systemCmd;
        denied = try { File.delete(probe).not } { true };
        h.awaitLoad(0, other);
        files = (dir +/+ "strata-load-*.part").pathMatch;
        if (denied) {
            check.(files.size == 1 and: { live.includes(files[0]) },
                "buffers: a snapshot the directory will not unlink stays accounted for after successful server reads");
        };
    } { ("chmod 755 " ++ dir.shellQuote).systemCmd };
    if (freeAtEnd) { h.freeEngine(other) } {
        h.commandTo(other, \loadBuffer, 0, monoPath, 0); h.awaitLoad(0, other)
    };
    check.(live.isEmpty and: { (dir +/+ "strata-load-*.part").pathMatch.isEmpty },
        "buffers: recovered directory permits snapshot cleanup at %".format(if (freeAtEnd) { "engine free" } { "next load" }));
    File.delete(probe); if (freeAtEnd.not) { h.freeEngine(other) };
};
// A file that passes loadSlot's checks but is gone when the server reads it
// (after the fade wait; a drive unplugged, say) is the one way to make the
// server's read itself fail: /fail for /b_readChannel. The slot was zeroed,
// so it stays empty and the load is reported as emptied ((load * 2 + 1) * 8
// + slot index). Called from checkBufferFades inside its lengthened fade
// wait (voice 1 reads slot 2).
var checkVanishedFileLoad = { arg stereoPath, monoPath;
    var path = scratchRoot +/+ "vanishing.wav", before, expected;
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    File.copy(stereoPath, path);
    before = loadFailures.value.size;
    command.(\loadBuffer, 2, path, 0);
    expected = ((engine.bufferLoads[2] * 2) + 1) * engine.numBuffers + 2;
    File.delete(path);   // the server reads it bufferFadeWait from now
    check.(loadFailures.value.size == before, "a file that passes the checks is not reported before the server reads it");
    check.(waitFor.({ loadFailures.value.size > before }), "a file gone when the server reads it is reported by bufferLoadFailed");
    0.1.wait; server.sync;
    check.(loadFailures.value.drop(before) == [expected],
        "as that load's failure with the slot emptied (expected %, got %)".format(expected, loadFailures.value.drop(before)));
    check.(engine.bufferFrames[2] == 0 and: { getControl.(engine.synths[\grain1], \bufFrames) == 0 }
        and: { bufferSample.(engine.buffersL[2], 100) == 0 }, "the slot stays empty (zeroed, 0 frames)");
    // a later load inside the wait wins: the vanished file is never read and nothing is reported
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    File.copy(stereoPath, path);
    before = loadFailures.value.size;
    command.(\loadBuffer, 2, path, 0); File.delete(path);
    command.(\loadBuffer, 2, monoPath, 0);
    // the load itself, then a window in which no report of the vanished
    // file may arrive (an absence keeps a fixed wait)
    h.awaitLoad(2); 0.5.wait; server.sync;
    check.(engine.bufferFrames[2] == 4410 and: { loadFailures.value.size == before },
        "a load inside the fade wait wins over a vanished file's load (% frames, % reports)".format(
            engine.bufferFrames[2], loadFailures.value.size - before));
};

// Grain synths that are no longer the voice's (releasing after voiceOff,
// fading after a source switch) but still read a slot fade out before it is
// zeroed or overwritten (#47): a clear, load or recording sends them
// bufFrames 0 at once and waits for them as for a running voice, so the
// tail never clicks, and they never take the new take's length (their tail
// would replay it); voiceOn re-gates a releasing one with the slot as it is
// then. Called from checkBufferFades inside its lengthened fade wait (voice 1
// reads slot 2).
var checkReleasingGrainFades = { arg stereoPath, monoPath;
    var grainKey = engine.grainKey(1), grain, steadyLevel, cutStep, stepBus, stepProbe, peakBus, peakProbe;
    var restart = { command.(\voiceOn, 1, 101.0, 1.0, 0.0, 0.2, 20.0, 1.0); server.sync };
    var holds = { arg value; (bufferSample.(engine.buffersL[2], 100) - value).abs < 0.001 };
    // a clear inside the release: faded at once, zeroed after the fade, no step
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    grain = engine.synths[grainKey];
    stepBus = Bus.control(server, 1); peakBus = Bus.control(server, 1);
    stepProbe = Synth(\strataCheckStep, [\in, engine.granBuses[1], \out, stepBus], engine.processGroup, \addToTail);
    peakProbe = Synth(\strataCheckPeak, [\in, engine.granBuses[1], \out, peakBus], engine.processGroup, \addToTail);
    server.sync; 0.3.wait;
    peakProbe.set(\t_reset, 1); 0.3.wait;
    steadyLevel = readBusValue.(peakBus);
    stepProbe.set(\t_reset, 1); 0.05.wait;
    command.(\voiceOff, 1);
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(grain.isPlaying and: { getControl.(grain, \bufFrames) == 0 } and: { holds.(0.5) },
        "a clear in a voiceOff release fades the releasing grain synth at once and leaves the buffers until the fade is over");
    0.6.wait; server.sync;
    cutStep = readBusValue.(stepBus);
    check.((bufferSample.(engine.buffersL[2], 100) == 0) and: { steadyLevel > 0.05 } and: { cutStep < (steadyLevel * 0.01) },
        "then zeroes the slot, and the release tail fades instead of cutting off (largest step %; level %)".format(
            cutStep.round(0.000001), steadyLevel.round(0.0001)));
    stepProbe.free; peakProbe.free; stepBus.free; peakBus.free;
    restart.value;
    check.(engine.synths[grainKey] === grain, "voiceOn in the release re-gates that grain synth");
    // a load inside the release: faded at once, read after the fade, never taken by the tail
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    command.(\voiceOff, 1);
    command.(\loadBuffer, 2, monoPath, 0); 0.1.wait; server.sync;
    check.((getControl.(grain, \bufFrames) == 0) and: { holds.(0.5) },
        "a load in a voiceOff release fades the releasing grain synth at once and reads the file only after the fade");
    // the load itself, then a window in which the releasing grain synth
    // must not take its length (an absence keeps a fixed wait; the 2 s
    // release outlasts both)
    h.awaitLoad(2); 0.5.wait; server.sync;
    check.((engine.bufferFrames[2] == 4410) and: { holds.(0.4) } and: { grain.isPlaying } and: { getControl.(grain, \bufFrames) == 0 },
        "the releasing grain synth never takes the loaded take (its tail would replay it)");
    restart.value;
    check.((engine.synths[grainKey] === grain) and: { getControl.(grain, \bufFrames) == 4410 },
        "voiceOn re-gates it with the loaded take");
    // a recording inside the release: faded first, recorded after the fade
    File.delete(engine.scratchDir +/+ "buf3.wav");
    command.(\voiceOff, 1);
    command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0); 0.1.wait; server.sync;
    check.((getControl.(grain, \bufFrames) == 0) and: { synthNames.(context.xg).includes(\strataRecord).not } and: { holds.(0.4) },
        "a recording in a voiceOff release fades the releasing grain synth first and starts only after the fade");
    h.awaitTake(2);
    check.((engine.bufferFrames[2] == (0.2 * server.sampleRate).round.asInteger) and: { grain.isPlaying }
        and: { getControl.(grain, \bufFrames) == 0 }, "then records the take, which the releasing grain synth never takes");
    restart.value;
    // a grain synth a source switch left fading
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    command.(\setGrainSource, 1, 0); server.sync;
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(engine.fadingSynths[1].includes(grain) and: { getControl.(grain, \bufFrames) == 0 } and: { holds.(0.5) },
        "a clear fades a grain synth a switch left fading at once and leaves the buffers until the fade is over");
    0.6.wait; server.sync;
    check.(bufferSample.(engine.buffersL[2], 100) == 0, "then zeroes the slot");
    command.(\setGrainSource, 1, 3); server.sync;
};

// A slot that empties keeps the rate of the grains still fading out (#47):
// a clear or a recording leaves the voice's bufRateScale (a 22050 Hz file)
// until the slot holds audio again, so no grain started in the hasAudio fade
// plays at another pitch; a take's rate arrives with its length. Called from
// checkBufferFades (voice 1 reads slot 2).
var checkFadeRates = { arg stereoPath;
    var fileScale = 22050 / server.sampleRate, rateScale = { getControl.(engine.synths[engine.grainKey(1)], \bufRateScale) };
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(rateScale.value.equalWithPrecision(fileScale),
        "a clear leaves the rate of the grains fading out (bufRateScale %, the file's %)".format(rateScale.value, fileScale));
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    File.delete(engine.scratchDir +/+ "buf3.wav");
    command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0); 0.1.wait; server.sync;
    check.(rateScale.value.equalWithPrecision(fileScale),
        "a recording leaves the rate of the grains fading out until its take is in (bufRateScale %)".format(rateScale.value));
    h.awaitTake(2);
    check.((engine.bufferFrames[2] > 0) and: { rateScale.value == 1 },
        "the take's rate arrives with its length (bufRateScale %)".format(rateScale.value));
};

// More interleavings inside the fade wait (#22, #47), on the slot voice 1
// reads: a stopRecord before the recording has started cancels it (it never
// starts, nothing is written); a missing file loaded while a recording waits
// cancels it and is reported; of two recordings the later one wins and only
// it runs. Called from checkBufferFades.
var checkFadeWaitInterleavings = { arg longPath;
    var takePath = engine.scratchDir +/+ "buf3.wav", before, running;
    var recorders = { synthNames.(context.xg).count({ arg name; name == \strataRecord }) };
    command.(\loadBuffer, 2, longPath, 0); h.awaitLoad(2);
    File.delete(takePath);
    command.(\recordBuffer, 2, 0.5, 1.0, 0, 0, 0, 0, 0); 0.1.wait;
    command.(\stopRecord, 2); 0.6.wait; server.sync;
    running = recorders.value;
    0.5.wait; server.sync;
    check.((running == 0) and: { engine.recordSynths[2].isNil } and: { engine.bufferFrames[2] == 0 } and: { File.exists(takePath).not },
        "a stopRecord inside the fade wait cancels the recording: it never starts, nothing is written");
    command.(\loadBuffer, 2, longPath, 0); h.awaitLoad(2);
    before = loadFailures.value.size;
    command.(\recordBuffer, 2, 0.5, 1.0, 0, 0, 0, 0, 0);
    command.(\loadBuffer, 2, scratchRoot +/+ "missing.wav", 0); 0.6.wait; server.sync;
    running = recorders.value;
    0.5.wait; server.sync;
    check.((running == 0) and: { engine.recordSynths[2].isNil } and: { engine.bufferFrames[2] == 0 } and: { File.exists(takePath).not }
        and: { loadFailures.value.drop(before) == [(engine.bufferLoads[2] * 2) * engine.numBuffers + 2] },
        "a missing file loaded while a recording waits for its fade cancels it and is reported (reports %)".format(
            loadFailures.value.drop(before)));
    command.(\loadBuffer, 2, longPath, 0); h.awaitLoad(2);
    command.(\recordBuffer, 2, 0.5, 1.0, 0, 0, 0, 0, 0);
    command.(\recordBuffer, 2, 0.4, 1.0, 0, 0, 0, 0, 0); 0.65.wait; server.sync;   // the later one runs from the fade's end (0.5 s) to 0.9 s
    running = recorders.value;
    h.awaitTake(2);
    waitFor.({ File.exists(takePath) }, 5);   // its scratch take, written after it ends
    check.((running == 1) and: { engine.recordSynths[2].isNil } and: { engine.bufferFrames[2] == (0.4 * server.sampleRate).round.asInteger }
        and: { File.exists(takePath) },
        "of two recordings inside the fade wait the later one wins and only it runs (% running, % frames)".format(
            running, engine.bufferFrames[2]));
};

// Clearing, loading or recording into a slot a voice plays fades it first:
// the grain synth gets bufFrames 0 at once (strataGrainBuf's hasAudio lag
// fades it) and the buffers are zeroed or overwritten only bufferFadeWait
// later, so the sound never cuts off. Voice 2 (engine voice 1) reads slot 3
// (index 2).
var checkBufferFades = { arg stereoPath, monoPath, longPath;
    var fadeLags, defaultFadeWait, steadyStep, cutStep, steadyLevel, stepBus, stepProbe, peakBus, peakProbe, units, reads;
    fadeLags = SynthDescLib.global.at(\strataGrainBuf).def.children.select({ arg ugen;
        ugen.isKindOf(Lag) and: { ugen.inputs[0].isKindOf(BinaryOpUGen) } and: { ugen.inputs[0].operator == '>' }
    }).collect({ arg ugen; ugen.inputs[1] });
    check.(engine.respondsTo(\bufferFadeWait) and: { fadeLags.size == 1 }
        and: { fadeLags[0].isNumber } and: { engine.bufferFadeWait > fadeLags[0] }
        and: { engine.bufferFadeWait < 0.2 },
        "bufferFadeWait (%) is slightly longer than strataGrainBuf's hasAudio lag (%)".format(
            engine.tryPerform(\bufferFadeWait), fadeLags));
    // The constant stereo file through overlapping Hann grains from one
    // position: a steady level with tiny sample-to-sample steps, so an
    // abrupt cut steps by about the level and a fade by far less
    [[\bufPos, 0.5], [\bufScan, 0], [\posSpread, 0], [\bufRate, 1], [\pitchShift, 1],
        [\grainSize, 0.2], [\grainDensity, 20], [\grainMode, 0], [\windowShape, 0.57]].do({ arg pair;
        command.(\setGrainParam, 1, pair[0], pair[1]);
    });
    command.(\setVoiceParam, 1, \amp, 1);
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    stepBus = Bus.control(server, 1); peakBus = Bus.control(server, 1);
    stepProbe = Synth(\strataCheckStep, [\in, engine.granBuses[1], \out, stepBus], engine.processGroup, \addToTail);
    peakProbe = Synth(\strataCheckPeak, [\in, engine.granBuses[1], \out, peakBus], engine.processGroup, \addToTail);
    1.0.wait;
    stepProbe.set(\t_reset, 1); peakProbe.set(\t_reset, 1); 0.5.wait;
    steadyStep = readBusValue.(stepBus); steadyLevel = readBusValue.(peakBus);
    stepProbe.set(\t_reset, 1); 0.05.wait;
    command.(\clearBuffer, 2); 0.3.wait;
    cutStep = readBusValue.(stepBus);
    check.(bufferSample.(engine.buffersL[2], 100) == 0, "the cleared slot is zeroed after the fade");
    // measured: a fade steps by about 0.1 % of the level, an abrupt cut by about 4 %
    check.(steadyLevel > 0.05 and: { cutStep < (steadyLevel * 0.01) },
        "clearing a slot a voice plays fades it out (largest step % while clearing; level %, largest step % playing)".format(
            cutStep.round(0.000001), steadyLevel.round(0.0001), steadyStep.round(0.000001)));
    stepProbe.free; peakProbe.free; stepBus.free; peakBus.free;
    // Inside the wait (lengthened so the check can look): faded at once, zeroed or overwritten after
    checkReplacedFileLoad.value;
    checkLoadStagingFailure.value;
    checkPackedLoadEdges.value;
    checkLoadSnapshotBudget.value;
    checkDeferredLoadFailure.value;
    checkLoadSnapshotCleanup.(false); checkLoadSnapshotCleanup.(true);
    defaultFadeWait = engine.bufferFadeWait;
    engine.bufferFadeWait = 0.5;
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    command.(\clearBuffer, 2); 0.1.wait; server.sync;
    check.(getControl.(engine.synths[\grain1], \bufFrames) == 0 and: { engine.bufferFrames[2] == 0 }
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.5).abs < 0.001 },
        "clearBuffer fades the voice at once and leaves the buffers until the fade is over");
    0.6.wait; server.sync;
    check.(bufferSample.(engine.buffersL[2], 100) == 0, "then clearBuffer zeroes the slot");
    command.(\loadBuffer, 2, stereoPath, 0); h.awaitLoad(2);
    command.(\loadBuffer, 2, monoPath, 0); 0.1.wait; server.sync;
    check.(getControl.(engine.synths[\grain1], \bufFrames) == 0 and: { engine.bufferFrames[2] == 0 }
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.5).abs < 0.001 },
        "loadBuffer fades the voice at once and reads the file only after the fade");
    h.awaitLoad(2);
    check.(engine.bufferFrames[2] == 4410 and: { getControl.(engine.synths[\grain1], \bufFrames) == 4410 }
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.4).abs < 0.001 }, "then loadBuffer reads the file");
    File.delete(engine.scratchDir +/+ "buf3.wav");
    command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0); 0.1.wait; server.sync;
    check.(synthNames.(context.xg).includes(\strataRecord).not
        and: { (bufferSample.(engine.buffersL[2], 100) - 0.4).abs < 0.001 },
        "recordBuffer leaves the buffers and starts no recording until the fade is over");
    h.awaitTake(2);
    waitFor.({ File.exists(engine.scratchDir +/+ "buf3.wav") }, 5);   // its scratch take, written after it ends
    check.(engine.recordSynths[2].isNil and: { engine.bufferFrames[2] == (0.2 * server.sampleRate).round.asInteger }
        and: { File.exists(engine.scratchDir +/+ "buf3.wav") }, "then recordBuffer records the take");
    // Every interleaving inside the wait: the later command wins
    [
        ["a clear after a load", { command.(\loadBuffer, 2, stereoPath, 0); command.(\clearBuffer, 2) }, 0, 0],
        ["a load after a clear", { command.(\clearBuffer, 2); command.(\loadBuffer, 2, stereoPath, 0) }, 11025, 0.5],
        ["a load after a load", { command.(\loadBuffer, 2, stereoPath, 0); command.(\loadBuffer, 2, monoPath, 0) }, 4410, 0.4],
        ["a clear after a recording", { command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0); command.(\clearBuffer, 2) }, 0, 0],
        ["a load after a recording", { command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0); command.(\loadBuffer, 2, monoPath, 0) }, 4410, 0.4],
        ["a recording after a load", { command.(\loadBuffer, 2, stereoPath, 0); command.(\recordBuffer, 2, 0.2, 1.0, 0, 0, 0, 0, 0) },
            (0.2 * server.sampleRate).round.asInteger, nil]
    ].do({ arg case;
        command.(\loadBuffer, 2, longPath, 0); h.awaitLoad(2);   // audio in the slot, so the voice fades
        File.delete(engine.scratchDir +/+ "buf3.wav");
        case[1].value;
        // (every earlier command's late step has come and been dropped by
        // then; a case ending on a load or a recording waits for it itself)
        1.5.wait; server.sync;
        if (case[3].notNil and: { case[2] > 0 }) { h.awaitLoad(2) };
        if (case[3].isNil) { h.awaitTake(2); waitFor.({ File.exists(engine.scratchDir +/+ "buf3.wav") }, 5) };
        check.(engine.bufferFrames[2] == case[2] and: { getControl.(engine.synths[\grain1], \bufFrames) == case[2] }
            and: { engine.recordSynths[2].isNil }
            and: { case[3].isNil or: { (bufferSample.(engine.buffersL[2], 100) - case[3]).abs < 0.001 } }
            and: { File.exists(engine.scratchDir +/+ "buf3.wav") == case[3].isNil },
            "% inside the fade wins (% frames)".format(case[0], engine.bufferFrames[2]));
    });
    // A slot no voice plays changes without the wait
    // (its reads are among the command's own messages: never a time, #706)
    units = h.wireUnits({ command.(\loadBuffer, 5, stereoPath, 0) }).flatten(1);
    reads = units.count({ arg msg; (msg[0].asString == "/b_readChannel")
        and: { [engine.buffersL[5].bufnum, engine.buffersR[5].bufnum].includes(msg[1]) } });
    h.awaitLoad(5);
    check.((reads == 2) and: { engine.bufferFrames[5] == 11025 },
        "a slot no voice plays loads without the fade wait (% reads sent with the command)".format(reads));
    command.(\clearBuffer, 5); server.sync;
    check.(engine.bufferFrames[5] == 0 and: { bufferSample.(engine.buffersL[5], 100) == 0 },
        "and clears without it");
    checkReleasingGrainFades.(stereoPath, monoPath);
    checkFadeRates.(stereoPath);
    checkFadeWaitInterleavings.(longPath);
    checkVanishedFileLoad.(stereoPath, monoPath);
    check.(engine.areaState[\buffers][\snapshots].isEmpty and: { (engine.scratchDir +/+ "strata-load-*.part").pathMatch.isEmpty },
        "buffers: successful, missing and superseded sources release their snapshot files and credits");
    engine.bufferFadeWait = defaultFadeWait;
};

// The high tier's long slots, on an engine of their own (h.startEngine with
// a high setting of 60 s, a Pi 4 model and plenty of memory). A file longer
// than 16 s at the server rate is checked in a routine that yields between
// chunks (fileDecodes), so its load takes effect only after the check.
// Commands go to it through h.commandTo; its poll reports arrive as the
// default engine's (one poll per name).
var startHighEngine = { arg name;
    var root = scratchRoot +/+ name;
    var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"))
};

// A stereo 16-bit file of `seconds` at the server rate, written a second at
// a time: left levelFor.(second), right its negative
var writeLongFile = { arg path, seconds, levelFor;
    var rate = server.sampleRate.asInteger;
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    // +1, -1, ... once; each second is it scaled (Signal arithmetic)
    var signs = h.repeating(rate * 2, [1.0, -1.0]);
    file.openWrite(path);
    seconds.do({ arg second;
        var level = levelFor.(second);
        file.writeData(signs * level);
    });
    file.close;
};

// A 20 s mono FLAC of noise (longer than 16 s, so it is checked
// asynchronously) overwritten from a third of the way in: its header is
// sound, but it stops decoding early (as writeDamagedFlac)
var writeDamagedLongFlac = { arg path;
    var rate = server.sampleRate.asInteger, bytes, start;
    var file = SoundFile.new.headerFormat_("FLAC").sampleFormat_("int16").numChannels_(1).sampleRate_(rate);
    file.openWrite(path);
    20.do({ file.writeData(h.noise(rate, 0.5)) });
    file.close;
    file = File(path, "rb"); bytes = Int8Array.newClear(file.length); file.read(bytes); file.close;
    start = bytes.size div: 3;
    bytes.overWrite(Int8Array.newClear(bytes.size - start).fill(0x55), start);
    file = File(path, "wb"); file.write(bytes); file.close;
};

// A 60 s slot loads a 60 s file, records a take longer than a standard slot
// holds (stopped early), saves and clears
var checkLongSlotCommands = { arg other, path60;
    var rate = server.sampleRate.asInteger, cmd = { arg name ... args; h.commandTo(other, name, *args) };
    var loaded, recorded, saved, cleared, savePath = scratchRoot +/+ "long-slots/saved/sixty.wav", file, duration;
    cmd.(\loadBuffer, 0, path60, 0);
    loaded = waitFor.({ other.bufferFrames[0] == (60 * rate) }, 10)
        and: { (bufferSample.(other.buffersL[0], (59.5 * rate).asInteger) - 0.6).abs < 0.001 }
        and: { (bufferSample.(other.buffersR[0], (10.5 * rate).asInteger) + 0.11).abs < 0.001 }
        and: { waitFor.({ bufferStateSeen.(0, 60, other) }) };
    cmd.(\recordBuffer, 1, 20, 1.0, 0, 0, 0, 0, 0); 0.3.wait; server.sync;
    duration = other.recordSynths[1] !? { arg synth; getControl.(synth, \frames) / rate };
    cmd.(\stopRecord, 1); h.awaitTake(1, other);
    recorded = duration.notNil and: { (duration - 20).abs < 0.001 } and: { other.bufferFrames[1] > 0 };
    cmd.(\saveBuffer, 0, savePath, 0, 1);
    saved = waitFor.({ File.exists(savePath) }, 60);
    file = if (saved) { SoundFile.openRead(savePath) };
    saved = file.notNil and: { file.numFrames == (60 * rate) } and: { file.numChannels == 2 } and: { file.sampleFormat == "int16" };
    file !? { file.close };
    cmd.(\clearBuffer, 0); server.sync;
    cleared = other.bufferFrames[0] == 0 and: { bufferSample.(other.buffersL[0], (59.5 * rate).asInteger) == 0 };
    check.(loaded and: { recorded } and: { saved } and: { cleared },
        "buffers: a 60 s slot loads, records, clears and saves (loaded %, recorded % (duration %), saved %, cleared %)".format(
            loaded, recorded, duration, saved, cleared));
    cmd.(\clearBuffer, 1); server.sync;
};

// A load, record or clear sent while a long file is checked wins: the
// checked load is dropped silently (a damaged file is then never reported).
// A later load wins whichever check ends first; a later load that fails
// leaves the checked one to apply (Lua then puts that load's name back).
var checkAsyncDecodeOrder = { arg other, path60, path20, damaged;
    var rate = server.sampleRate.asInteger, cmd = { arg name ... args; h.commandTo(other, name, *args) };
    var before, immediate, settle = { 1.5.wait; server.sync };
    before = loadFailures.value.size;
    cmd.(\loadBuffer, 2, damaged, 0);
    immediate = loadFailures.value.size == before;
    check.(immediate and: { waitFor.({ loadFailures.value.size > before }, 10) }
        and: { loadFailures.value.drop(before) == [(other.bufferLoads[2] * 2) * other.numBuffers + 2] },
        "buffers: a damaged long file is reported once its check ends (got %)".format(loadFailures.value.drop(before)));
    cmd.(\loadBuffer, 2, path20, 0);
    waitFor.({ other.bufferFrames[2] == (20 * rate) }, 10);
    before = loadFailures.value.size;
    cmd.(\loadBuffer, 2, damaged, 0);
    cmd.(\clearBuffer, 2);
    settle.value; 0.5.wait;
    check.(loadFailures.value.size == before and: { other.bufferFrames[2] == 0 }
        and: { bufferSample.(other.buffersL[2], rate) == 0 },
        "buffers: an async decode loses to a later clear and reports nothing (% reports, % frames)".format(
            loadFailures.value.size - before, other.bufferFrames[2]));
    cmd.(\loadBuffer, 3, path60, 0); cmd.(\clearBuffer, 3); settle.value;
    check.(other.bufferFrames[3] == 0 and: { bufferSample.(other.buffersL[3], 100) == 0 },
        "buffers: a long file's load loses to a clear sent during its check (% frames)".format(other.bufferFrames[3]));
    cmd.(\loadBuffer, 3, path60, 0); cmd.(\recordBuffer, 3, 0.3, 1.0, 0, 0, 0, 0, 0); settle.value; h.awaitTake(3, other);
    check.(other.bufferFrames[3] == (0.3 * rate).round.asInteger and: { other.recordSynths[3].isNil },
        "buffers: a recording sent during a long file's check wins (% frames)".format(other.bufferFrames[3]));
    // (settle lets a superseded check end; the winning load is waited for itself)
    cmd.(\loadBuffer, 3, path60, 0); cmd.(\loadBuffer, 3, stereoPath, 0); settle.value; h.awaitLoad(3, other, 10);
    check.(other.bufferFrames[3] == 11025 and: { (bufferSample.(other.buffersL[3], 100) - 0.5).abs < 0.001 },
        "buffers: a short load sent during a long file's check wins (% frames)".format(other.bufferFrames[3]));
    cmd.(\loadBuffer, 3, path60, 0); cmd.(\loadBuffer, 3, path20, 0); settle.value; h.awaitLoad(3, other, 10);
    check.(other.bufferFrames[3] == (20 * rate) and: { (bufferSample.(other.buffersL[3], 100) - 0.7).abs < 0.001 },
        "buffers: of two long loads the later wins when its check ends first (% frames)".format(other.bufferFrames[3]));
    cmd.(\loadBuffer, 3, path20, 0); cmd.(\loadBuffer, 3, path60, 0); settle.value; h.awaitLoad(3, other, 10);
    check.(other.bufferFrames[3] == (60 * rate) and: { (bufferSample.(other.buffersL[3], (30.5 * rate).asInteger) - 0.31).abs < 0.001 },
        "buffers: of two long loads the later wins when its check ends last (% frames)".format(other.bufferFrames[3]));
    [2, 3].do({ arg slot; cmd.(\clearBuffer, slot) }); server.sync;
};

// bufferLoads counts every loadBuffer at the command, so a load rejected
// while an earlier one is still checked is reported under its own number
// at once, and the earlier load still applies
var checkAsyncLoadNumbers = { arg other, path60;
    var rate = server.sampleRate.asInteger, cmd = { arg name ... args; h.commandTo(other, name, *args) };
    var before = loadFailures.value.size, loads = other.bufferLoads[5], counted, reported;
    cmd.(\loadBuffer, 5, path60, 0);
    counted = other.bufferLoads[5] == (loads + 1);
    cmd.(\loadBuffer, 5, scratchRoot +/+ "missing.wav", 0);
    reported = waitFor.({ loadFailures.value.size > before }) and: { other.bufferFrames[5] == 0 };
    check.(counted and: { reported } and: { other.bufferLoads[5] == (loads + 2) }
        and: { loadFailures.value.drop(before) == [((loads + 2) * 2) * other.numBuffers + 5] },
        "buffers: bufferLoads counts at the command during an async decode (reports %)".format(loadFailures.value.drop(before)));
    check.(waitFor.({ other.bufferFrames[5] == (60 * rate) }, 10),
        "buffers: a load rejected during a long file's check leaves that load to apply (% frames)".format(other.bufferFrames[5]));
    cmd.(\clearBuffer, 5); server.sync;
};

// A long check yields between its chunks: a message sent 5 ms after it
// begins (by a task scheduled then, which runs only if the check yields) is
// handled before it ends, which takes about 50 ms here (with no yield, or
// one that falls behind its clock, sclang would hold every command and
// task until the check is over)
var checkDecodeYields = { arg other, path60;
    var file = SoundFile.openRead(path60), done = false, result, heard, ping;
    ping = OSCFunc({ heard = done.not }, '/strataCheckDecodePing');
    fork({
        SystemClock.sched(0.005, { NetAddr.localAddr.sendMsg('/strataCheckDecodePing'); nil });
        result = other.fileDecodes(file, file.numFrames, true);
        done = true;
    }, SystemClock);
    waitFor.({ done }, 10);
    0.1.wait;
    file.close; ping.free;
    check.(result == true and: { heard == true },
        "buffers: a long file's check lets commands in between its chunks (decodes %, heard during it %)".format(result, heard));
};

// ... and loadBuffer runs that check yielding: a message sent 5 ms after a
// long file's loadBuffer is handled while the check still runs (the load
// has not taken effect: slotChanges unchanged)
var checkLoadYields = { arg other, path60;
    var change = other.slotChanges[7], heard, ping;
    ping = OSCFunc({ heard = other.slotChanges[7] == change }, '/strataCheckLoadPing');
    h.commandTo(other, \loadBuffer, 7, path60, 0);
    SystemClock.sched(0.005, { NetAddr.localAddr.sendMsg('/strataCheckLoadPing'); nil });
    waitFor.({ other.bufferFrames[7] == (60 * server.sampleRate) }, 10);
    0.1.wait;
    ping.free;
    check.(heard == true and: { other.slotChanges[7] != change },
        "buffers: a message sent during a long file's loadBuffer check is handled before the load takes effect (heard during it %)".format(heard));
    h.commandTo(other, \clearBuffer, 7); server.sync;
};

// The chunks an engine's fileDecodes has read since alloc (#375; 0 for an
// engine that does not count them)
var decodeChunks = { arg target; target.areaState[\files][\decodeChunks] ? 0 };

// #375: a long file's check stops at the first chunk after something
// supersedes it, and closes the file: fileDecodes asks keepGoing after
// every chunk; and a load and a clear in one tick read one chunk of the
// file's 192 (counted, so a loaded machine cannot make it pass or fail)
var checkDecodeStops = { arg other, path60;
    var rate = server.sampleRate.asInteger, file = SoundFile.openRead(path60), peaks = FloatArray.newClear(other.waveformPoints);
    var asked = 0, result, done = false, chunks;
    fork({
        result = other.fileDecodes(file, file.numFrames, true, peaks, { asked = asked + 1; false });
        done = true;
    }, SystemClock);
    waitFor.({ done }, 10);
    file.close;
    check.((result == false) and: { asked == 1 } and: { peaks.count({ arg each; each > 0 }) == 1 },
        "buffers: a long file's check stops at the first chunk once keepGoing is false (decodes %, asked %, bins read %)".format(
            result, asked, peaks.count({ arg each; each > 0 })));
    chunks = decodeChunks.(other);
    h.commandTo(other, \loadBuffer, 4, path60, 0);
    h.commandTo(other, \clearBuffer, 4);
    1.0.wait; server.sync;
    chunks = decodeChunks.(other) - chunks;
    check.(chunks.inclusivelyBetween(1, 2) and: { other.bufferFrames[4] == 0 },
        "buffers: a long file's check superseded by a clear stops at its next chunk (% chunks of 192 read, % frames)".format(chunks, other.bufferFrames[4]));
};

// #885: an sclang error inside a long load's check (injected through
// loadCheckFaultHook, which the check's routine calls after the file's
// chunks with the slot and the load's number) still ends the load: it is
// rejected at once under its own number, and the empty slot stays empty
var checkLoadCheckFault = { arg other, path60;
    var before = loadFailures.value.size, load, reports, reported;
    other.loadCheckFaultHook = { arg index; if (index == 2) { Error("injected load check fault").throw } };
    h.commandTo(other, \loadBuffer, 2, path60, 0);
    load = other.bufferLoads[2];
    reported = waitFor.({ loadFailures.value.size > before }, 5);
    other.loadCheckFaultHook = nil;
    reports = loadFailures.value.drop(before);
    check.(reported and: { reports == [other.bufferLoadFailedValue(2, load, false)] } and: { other.bufferFrames[2] == 0 },
        "buffers: an error in a long load's check reports bufferLoadFailed with the load's number (load %, reports %, % frames)".format(
            load, reports, other.bufferFrames[2]));
};

// #983: a bufferState report names the newest load of its slot that, with
// every load before it, has an outcome, never a load still in its check.
// The value the periodic poll sends for the slot (announcedBufferState: the
// high engine's own poll function is never registered, its polls being the
// default engine's) names the load before a long one at its command and
// during its check, and the check's 0 s and length name it. The length a
// long load's cancel of a recording reports at its command names the load
// before it too, and a check rejected after canceling one reports the
// slot's length under its own number before its failure, so Lua resolves
// the failure from the length the cancel left. The reports are read in
// the order they arrived (h.pollMessages, a window of a few messages)
var checkCheckedLoadNumbers = { arg other, path60, damaged;
    var slot = 1, cmd = { arg name ... args; h.commandTo(other, name, *args) };
    var stateIndex = CronePollRegistry.getPollFromName(\bufferState).index;
    var failedIndex = CronePollRegistry.getPollFromName(\bufferLoadFailed).index;
    var loads = other.bufferStateLoads, before, shown, atCommand, during, since, events, wanted, decode, slotEvents;
    // whether the default engine's idle slot names none of the loads a
    // check wants, so leaving its value out hides none of the high
    // engine's; a clash fails with a line of its own naming it
    var apart = { arg numbers, which;
        var idle = decode.(engine.announcedBufferState(slot))[0], clear = numbers.includes(idle).not;
        if (clear.not) {
            check.(false, ("buffers: the % #983 check's window: the default engine's idle slot % names load number %, "
                ++ "one the check wants (%), so leaving that slot's reports out would hide the high engine's: give one "
                ++ "of the two slots another load count").format(which, slot, idle, numbers));
        };
        clear
    };
    // [load number, seconds] of a bufferState value, as Lua decodes it
    decode = { arg value; var cell = (value / 1000).floor.asInteger; [cell div: 9, ((value - (cell * 1000)) * 100).round / 100] };
    // the slot's reports since `since`, in arrival order: [\state, load
    // number, seconds] or [\failed, load number]. The default engine's
    // periodic poll, which the high engine's reports share, also reports
    // its own slot of that index every 2.25 s: its value (that idle slot's,
    // fixed meanwhile) is left out
    slotEvents = { arg since;
        var found = List.new(16), idle = engine.announcedBufferState(slot);
        h.pollMessages.array.copyRange(since, h.pollMessages.size - 1).do({ arg msg;
            var value = msg[2], whole = value.round.asInteger;
            case
            { (msg[1] == stateIndex) and: { ((value / 1000).floor.asInteger % 9) == slot }
                and: { (value - idle).abs > 0.004 } } { found.add([\state] ++ decode.(value)) }
            { (msg[1] == failedIndex) and: { (whole % other.numBuffers) == slot } } {
                found.add([\failed, (whole div: other.numBuffers) div: 2]) };
        });
        found.asArray
    };
    cmd.(\clearBuffer, slot);
    cmd.(\loadBuffer, slot, stereoPath, 0); h.awaitLoad(slot, other);
    0.05.wait; server.sync;
    before = other.bufferLoads[slot];
    shown = other.bufferStateSeconds(slot);
    other.loadCheckFaultHook = { arg index; if (index == slot) { during = other.announcedBufferState(slot) } };
    since = h.pollMessages.size;
    cmd.(\loadBuffer, slot, path60, 0);
    atCommand = other.announcedBufferState(slot);
    h.awaitLoad(slot, other, 10);
    other.loadCheckFaultHook = nil;
    0.05.wait; server.sync;
    events = slotEvents.(since);
    wanted = [[\state, (before + 1) % loads, 0], [\state, (before + 1) % loads, 60]];
    // (apart first, so a clash is named even when it hid a report)
    check.(apart.([before % loads, (before + 1) % loads], "periodic report's")
        and: { decode.(atCommand ? 0) == [before % loads, shown] } and: { decode.(during ? 0) == [before % loads, shown] }
        and: { events == wanted },
        "buffers: a periodic report during a long load's check names the load before it, its 0 s and length name it (#983; at the command %, during the check %, reports %, wanted [%, %] then %)".format(
            atCommand !? decode, during !? decode, events, before % loads, shown, wanted));
    // a replace take, prepared at once (0 s), then a long file that cancels
    // it at its command and fails its check
    cmd.(\recordBuffer, slot, 5, 1.0, 0, 0, 0, 0, 0);
    0.1.wait; server.sync;
    before = other.bufferLoads[slot];
    since = h.pollMessages.size;
    cmd.(\loadBuffer, slot, damaged, 0);
    waitFor.({ slotEvents.(since).any({ arg event; event[0] == \failed }) }, 10);
    0.05.wait; server.sync;
    events = slotEvents.(since);
    wanted = [[\state, before % loads, 0], [\state, (before + 1) % loads, 0], [\failed, before + 1]];
    check.(apart.([before % loads, (before + 1) % loads], "cancel's") and: { events == wanted },
        "buffers: a long load's cancel of a recording reports under the load before it, and its rejected check under its own number before its failure (#983; reports %, wanted %)".format(
            events, wanted));
    // #1016: the same with a missing file loaded during the check (rejected
    // at once): the rejected check's length still names its own load, not
    // the later one, so Lua never takes it for a given-back check's end
    cmd.(\recordBuffer, slot, 5, 1.0, 0, 0, 0, 0, 0);
    0.1.wait; server.sync;
    before = other.bufferLoads[slot];
    since = h.pollMessages.size;
    cmd.(\loadBuffer, slot, damaged, 0);
    cmd.(\loadBuffer, slot, scratchRoot +/+ "missing.wav", 0);
    waitFor.({ slotEvents.(since).select({ arg event; event[0] == \failed }).size >= 2 }, 10);
    0.05.wait; server.sync;
    events = slotEvents.(since);
    wanted = [[\state, before % loads, 0], [\failed, before + 2], [\state, (before + 1) % loads, 0], [\failed, before + 1]];
    check.(apart.([before % loads, (before + 1) % loads, (before + 2) % loads], "later load's") and: { events == wanted },
        "buffers: a rejected check that canceled a recording reports its length under its own number when a later load was rejected first (#1016; reports %, wanted %)".format(
            events, wanted));
    cmd.(\clearBuffer, slot); server.sync;
};

// #946: a slot being loaded is at the server's rate, with 0 frames, until
// its length is reported: the file's rate goes to the peaks write and is
// set with the length in the write's action. The peaks mover, stopped,
// holds the write open (for up to peaksMoverTimeout) while it is read
var checkLoadRateWithLength = {
    var path = scratchRoot +/+ "rate-946.wav", mover = engine.areaState[\waveform][\mover], frames = 22050;
    var held, during, after;
    h.writeTestFile(path, 44100, frames, [0.25, 0.25]);
    ("kill -STOP " ++ mover[\pid]).systemCmd;
    command.(\loadBuffer, 5, path, 0);
    held = waitFor.({ mover[\pending] > 0 }, 0.8);
    during = [engine.bufferSampleRates[5], engine.bufferFrames[5]];
    ("kill -CONT " ++ mover[\pid]).systemCmd;
    h.awaitLoad(5);
    after = [engine.bufferSampleRates[5], engine.bufferFrames[5]];
    check.(held and: { during == [server.sampleRate, 0] } and: { after == [44100, frames] }
        and: { bufferStateSeen.(5, (frames / 44100).round(0.01)) },
        "buffers: a slot being loaded is at the server's rate until its length is reported (peaks write held %; rate and frames then %, after %)".format(
            held, during, after));
    command.(\clearBuffer, 5); server.sync;
    File.delete(path);
};

var checkLongSlots = {
    var other, path60 = scratchRoot +/+ "sixty.wav", path20 = scratchRoot +/+ "twenty.wav", freedChunks;
    var damaged = scratchRoot +/+ "twenty-damaged.flac";
    writeLongFile.(path60, 60, { arg second; (second + 1) * 0.01 });
    writeLongFile.(path20, 20, { 0.7 });
    writeDamagedLongFlac.(damaged);
    other = startHighEngine.("long-slots");
    check.(other.tier == \high and: { other.bufferSeconds == 60 }
        and: { (other.buffersL ++ other.buffersR).every({ arg buffer; buffer.numFrames == (60 * server.sampleRate) }) },
        "buffers: the high engine has 60 s slots (tier %, % s)".format(other.tier, other.bufferSeconds));
    checkLongSlotCommands.(other, path60);
    checkAsyncDecodeOrder.(other, path60, path20, damaged);
    checkAsyncLoadNumbers.(other, path60);
    checkDecodeYields.(other, path60);
    checkLoadYields.(other, path60);
    checkDecodeStops.(other, path60);
    checkLoadCheckFault.(other, path60);
    checkCheckedLoadNumbers.(other, path60, damaged);
    // freed during a check: nothing applies to the freed buffers, and the
    // check stops at its next chunk (the file closed)
    freedChunks = decodeChunks.(other);
    h.commandTo(other, \loadBuffer, 6, path60, 0);
    h.freeEngine(other);
    1.0.wait; h.teardownSync("free engine during a load");
    freedChunks = decodeChunks.(other) - freedChunks;
    check.(other.bufferFrames[6] == 0, "buffers: an engine freed during a long file's check applies nothing");
    check.(freedChunks.inclusivelyBetween(1, 2),
        "buffers: an engine freed during a long file's check stops at its next chunk (% chunks of 192 read)".format(freedChunks));
    [path60, path20, damaged].do({ arg path; File.delete(path) });
};

// Buffer slots
check.(engine.buffersL.size == 8 and: { engine.buffersR.size == 8 }, "eight stereo slots as L/R pairs");
check.(engine.buffersL.every({ arg buffer; buffer.numChannels == 1 })
    and: { engine.buffersR.every({ arg buffer; buffer.numChannels == 1 }) }, "buffers are mono");
check.((engine.buffersL ++ engine.buffersR).collect(_.bufnum).asSet.size == 16, "sixteen distinct buffer numbers");

h.startAllVoices;

// Recording into a slot a voice is reading
command.(\setGrainSource, 1, 3);            // voice 1 reads slot 3 (index 2)
2.5.wait; server.sync;
before = synthNames.(context.xg).size;
command.(\recordBuffer, 2, 0.3, 1.0, 0, 0, 0, 0, 0); 0.15.wait; server.sync;   // starts after the fade and the zeroing syncs
check.(synthNames.(context.xg).includes(\strataRecord), "recordBuffer runs a record synth");
h.awaitTake(2);
check.(engine.bufferFrames[2] == (0.3 * server.sampleRate).round.asInteger, "recordBuffer sets the valid length");
check.(getControl.(engine.synths[\grain1], \bufFrames) == engine.bufferFrames[2],
    "a voice reading the slot gets the new valid length");
check.(synthNames.(context.xg).size == before, "recording into a slot a voice is reading adds no lasting nodes");
check.(waitFor.({ bufferStateSeen.(2, 0.3) }), "the bufferState poll reports the recorded seconds");
check.(bufferStateValues.value.notEmpty and: { bufferStateValues.value.every({ arg value; value.isKindOf(Float) }) },
    "bufferState is sent as a float value poll (matron's /poll/value is typed if)");
check.(waitFor.({ (0..7).every({ arg slot; h.pollValueNear(\bufferState, stateBase.(slot) + 499.95, 500) }) }),
    "the periodic bufferState poll reports every slot");
scratchFile = engine.scratchDir +/+ "buf3.wav";
check.(waitFor.({ File.exists(scratchFile) }), "a completed recording writes the scratch take buf3.wav");
1.0.wait;
file = SoundFile.openRead(scratchFile);
check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == engine.bufferFrames[2] }
    and: { file.sampleFormat == "int16" } and: { file.headerFormat == "WAV" },
    "the scratch take is a stereo 16-bit WAV of the valid region");
file !? { file.close };

// Recording replaces and clearBuffer cancels
command.(\recordBuffer, 3, 1.0, 1.0, 0, 0, 0, 0, 0); 0.15.wait; server.sync;   // a voice reads slot 4: after the fade
check.(synthNames.(context.xg).includes(\strataRecord), "a 1 s recording is running");
command.(\clearBuffer, 3); 0.5.wait; server.sync;
check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.bufferFrames[3] == 0 },
    "clearBuffer stops a recording in progress");
// canceled before the record synth could start (still waiting for its zeroed buffers)
command.(\recordBuffer, 3, 0.2, 1.0, 0, 0, 0, 0, 0);
command.(\clearBuffer, 3);
0.5.wait; server.sync;
check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.bufferFrames[3] == 0 }
    and: { engine.recordSynths[3].isNil }, "a recording canceled before it starts never runs");
check.(File.exists(engine.scratchDir +/+ "buf4.wav").not, "a canceled recording writes no scratch take");

// stopRecord ends a recording early, keeping what was captured
File.delete(engine.scratchDir +/+ "buf4.wav");
before = synthNames.(context.xg).size;
command.(\stopRecord, 3); 0.1.wait; server.sync;
check.(synthNames.(context.xg).size == before and: { engine.bufferFrames[3] == 0 }
    and: { File.exists(engine.scratchDir +/+ "buf4.wav").not }, "stopRecord on an idle slot is a no-op");
command.(\recordBuffer, 3, 1.0, 1.0, 0, 0, 0, 0, 0); 0.15.wait; server.sync;   // a voice reads slot 4: after the fade
check.(synthNames.(context.xg).includes(\strataRecord), "a 1 s recording is running before stopRecord");
0.15.wait;
command.(\stopRecord, 3); h.awaitTake(3);
check.(synthNames.(context.xg).includes(\strataRecord).not and: { engine.recordSynths[3].isNil },
    "stopRecord stops the record synth");
check.(synthNames.(context.xg).size == before, "stopRecord leaves no lasting nodes");
frames = engine.bufferFrames[3];
check.((frames > (0.1 * server.sampleRate)) and: { frames < (0.4 * server.sampleRate) },
    "stopRecord sets the valid length to what was recorded (~0.2 s; got % s)".format(frames / server.sampleRate));
check.(getControl.(engine.synths[\grain6], \bufFrames) == frames, "stopRecord reaches a voice reading the slot");
check.(waitFor.({ bufferStateSeen.(3, (frames / server.sampleRate).round(0.01)) }), "stopRecord updates the poll");
scratchFile = engine.scratchDir +/+ "buf4.wav";
check.(waitFor.({ File.exists(scratchFile) }), "stopRecord writes the scratch take");
1.0.wait;
file = SoundFile.openRead(scratchFile);
check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == frames },
    "the early-stopped scratch take holds the recorded frames");
file !? { file.close };
command.(\stopRecord, 3); 0.2.wait; server.sync;
check.(engine.bufferFrames[3] == frames, "a second stopRecord is a no-op");
command.(\clearBuffer, 3); server.sync;
// stopRecord then clearBuffer before the frame count arrives: the
// clear wins (slotChanges), nothing is restored and nothing written
File.delete(scratchFile);
command.(\recordBuffer, 3, 1.0, 1.0, 0, 0, 0, 0, 0); 0.15.wait; server.sync;   // a voice reads slot 4: after the fade
0.15.wait;
check.(engine.recordSynths[3].notNil, "a recording runs before stopRecord + clearBuffer");
command.(\stopRecord, 3);
command.(\clearBuffer, 3);
1.0.wait; server.sync;
check.(engine.bufferFrames[3] == 0, "a clear right after stopRecord leaves the slot empty (got % frames)".format(engine.bufferFrames[3]));
check.(File.exists(scratchFile).not, "a clear right after stopRecord writes no scratch take");

// loadBuffer: stereo, mono, too long, missing, unreadable
before = synthNames.(context.xg).size;
info = [engine.buffersL[4].bufnum, engine.buffersR[4].bufnum];
command.(\loadBuffer, 4, longPath, 0); h.awaitLoad(4);
check.(engine.bufferFrames[4] == (22050 * 16), "loadBuffer reads at most 16 s");
command.(\loadBuffer, 4, stereoPath, 0);
check.(engine.bufferFrames[4] == 0, "loadBuffer empties the slot (the voices reading it fade) until the file has been read");
h.awaitLoad(4);
check.(engine.bufferFrames[4] == 11025, "loadBuffer sets the valid length from the file");
check.([engine.buffersL[4].bufnum, engine.buffersR[4].bufnum] == info, "loadBuffer keeps the slot's bufnums");
check.((bufferSample.(engine.buffersL[4], 100) - 0.5).abs < 0.001
    and: { (bufferSample.(engine.buffersR[4], 100) + 0.25).abs < 0.001 }, "a stereo file fills left and right");
check.(bufferSample.(engine.buffersL[4], 20000) == 0, "loadBuffer zeroes the slot first (no tail of the longer file)");
check.(waitFor.({ bufferStateSeen.(4, 0.5) }), "the poll reports a loaded file's seconds at the file's rate");
command.(\loadBuffer, 4, scratchRoot +/+ "missing.wav", 0); 0.2.wait; server.sync;
command.(\loadBuffer, 4, textPath, 0); 0.2.wait; server.sync;
check.(engine.bufferFrames[4] == 11025 and: { (bufferSample.(engine.buffersL[4], 100) - 0.5).abs < 0.001 },
    "a missing or unreadable file leaves the slot unchanged");
checkLoadFailureReports.(textPath, stereoPath);
checkReadFailureMatching.(stereoPath, monoPath);
checkBadLoadsDuringRecording.(textPath, stereoPath);
checkLoadRateWithLength.value;
command.(\loadBuffer, 5, monoPath, 0); h.awaitLoad(5);
check.((bufferSample.(engine.buffersL[5], 10) - 0.4).abs < 0.001
    and: { (bufferSample.(engine.buffersR[5], 10) - 0.4).abs < 0.001 }, "a mono file fills both channels");
// a clear right after a load wins: the load's completion changes nothing
command.(\loadBuffer, 5, stereoPath, 0);
command.(\clearBuffer, 5);
0.5.wait; server.sync;
check.(engine.bufferFrames[5] == 0, "a clear right after loadBuffer leaves the slot empty (got % frames)".format(engine.bufferFrames[5]));
check.(synthNames.(context.xg).size == before, "loading adds no nodes");

// A file's sample rate becomes the slot's rate scale; recording restores the server rate.
// Voice 7 (engine voice 6) reads slot 4 (index 3).
command.(\loadBuffer, 3, stereoPath, 0); h.awaitLoad(3);
check.(getControl.(engine.synths[\grain6], \bufRateScale).equalWithPrecision(22050 / server.sampleRate)
    and: { getControl.(engine.synths[\grain6], \bufFrames) == 11025 },
    "a voice reading a loaded slot plays it at the file's rate");
checkFilePitch.value;
command.(\recordBuffer, 3, 0.1, 1.0, 0, 0, 0, 0, 0); h.awaitTake(3);
check.(getControl.(engine.synths[\grain6], \bufRateScale) == 1, "recording resets the slot to the server's rate");

command.(\clearBuffer, 2); 0.2.wait; server.sync;   // after the fade (a voice reads the slot)
check.(engine.bufferFrames[2] == 0, "clearBuffer resets it");
check.(getControl.(engine.synths[\grain1], \bufFrames) == 0, "clearBuffer reaches a voice reading the slot");
check.(bufferSample.(engine.buffersL[2], 10) == 0, "clearBuffer zeroes the slot");
command.(\setGrainSource, 1, 0);
2.5.wait; server.sync;

// A voice reading a slot that is being recorded stays silent until
// the take completes, instead of looping the take's first grain.
// A test tone in the input bus is recorded; a peak meter on voice 1's
// bus hears the strataGrainBuf mirror.
command.(\setGrainSource, 1, 3);           // slot 3 (index 2), empty
2.5.wait; server.sync;                     // the voice synth's release is over
peakBus = Bus.control(server, 1);
tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
probe = Synth(\strataCheckPeak, [\in, engine.granBuses[1], \out, peakBus], engine.processGroup, \addToTail);
readPeak = {
    var condition = Condition(false), value;
    probe.set(\t_reset, 1);
    0.3.wait;
    peakBus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
};
command.(\recordBuffer, 2, 1.0, 1.0, 0, 0, 0, 0, 0); 0.3.wait; server.sync;
duringPeak = readPeak.value;               // 0.3-0.6 s into the 1 s take
check.(engine.recordSynths[2].notNil and: { getControl.(engine.synths[\grain1], \bufFrames) == 0 },
    "the slot is still recording (bufFrames 0)");
check.(duringPeak < 0.001, "a voice reading a slot being recorded is silent (peak %)".format(duringPeak));
h.awaitTake(2);
check.(engine.recordSynths[2].isNil and: { engine.bufferFrames[2] > 0 }, "the take has completed");
afterPeak = readPeak.value;
check.(afterPeak > 0.01, "after the take completes the voice plays it (peak %)".format(afterPeak));
tone.free; probe.free; peakBus.free;
checkBufferFades.(stereoPath, monoPath, longPath);
command.(\clearBuffer, 2);
command.(\setGrainSource, 1, 0);
2.5.wait; server.sync;
h.stopAllVoices;
checkLongSlots.value;

// loadBuffer with start 0 reads the whole file, as 3.2's: the slot equals a
// fresh server read of the file (frames and rate too)
{
    var engine = h.engine, server = h.server, rate = server.sampleRate.asInteger, path = h.tempDir +/+ "buffers-load.wav";
    var period = Array.fill(1000, { arg i; sin(2pi * 5 * i / 1000) * 0.5 });
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    var frames = rate, left, right, group, diffL = Bus.control(server, 2), diffR = Bus.control(server, 2), valuesL, valuesR;
    file.openWrite(path);
    h.writePeriodicSeconds(file, period, 1, rate);
    file.close;
    h.command(\loadBuffer, 2, path, 0);
    h.waitFor({ engine.bufferFrames[2] == frames });
    left = Buffer.readChannel(server, path, channels: [0]);
    right = Buffer.readChannel(server, path, channels: [1]);
    server.sync;
    group = Group.after(engine.processGroup);
    Synth(\strataCheckBufDiff, [\bufA, engine.buffersL[2].bufnum, \bufB, left.bufnum, \frames, frames, \out, diffL], group);
    Synth(\strataCheckBufDiff, [\bufA, engine.buffersR[2].bufnum, \bufB, right.bufnum, \frames, frames, \out, diffR], group);
    1.1.wait; server.sync;
    valuesL = h.readBus(diffL); valuesR = h.readBus(diffR);
    group.free; left.free; right.free; server.sync;
    h.command(\clearBuffer, 2); server.sync;
    [diffL, diffR].do(_.free);
    h.check((engine.bufferSampleRates[2] == rate) and: { valuesL[1] > 0.1 } and: { valuesR[1] > 0.1 }
        and: { valuesL[0] == 0 } and: { valuesR[0] == 0 },
        "buffers: loadBuffer with start 0 loads as 3.2's loadBuffer (difference %, %)".format(valuesL[0], valuesR[0]));
}.value;

// A load from a start point (3.3): the slot holds the file from that frame.
// Each file has two regions, so which frames were read shows in the slot.
{
    var rate = server.sampleRate.asInteger, writeRegions, wav, flac, longPath, other, peaks;
    writeRegions = { arg path, format, fileRate, firstFrames, secondFrames, first, second;
        var file = SoundFile.new.headerFormat_(format).sampleFormat_("int16").numChannels_(2).sampleRate_(fileRate);
        file.openWrite(path);
        h.writeConstantFrames(file, firstFrames, [first, first.neg]);
        h.writeConstantFrames(file, secondFrames, [second, second.neg]);
        file.close;
    };
    wav = scratchRoot +/+ "buffers-start.wav"; flac = scratchRoot +/+ "buffers-start.flac";
    [wav, flac].do({ arg path, i;
        var slot = 2, half = rate div: 2;
        writeRegions.(path, ["WAV", "FLAC"][i], rate, half, half, 0.1, 0.7);
        command.(\loadBuffer, slot, path, 0.5);
        h.waitFor({ engine.bufferFrames[slot] == half });
        0.1.wait; server.sync;
        check.((engine.bufferFrames[slot] == half)
            and: { (bufferSample.(engine.buffersL[slot], 0) - 0.7).abs < 0.001 }
            and: { (bufferSample.(engine.buffersR[slot], half - 1) + 0.7).abs < 0.001 },
            "buffers: loadBuffer from a start reads from that frame (WAV and FLAC) (% frames, first sample %)".format(
                engine.bufferFrames[slot], bufferSample.(engine.buffersL[slot], 0)));
        command.(\clearBuffer, slot); server.sync;
        File.delete(path);
    });
    // past the end: the slot's length of its last frames (a 17 s file at 22050 Hz, on a 16 s slot)
    {
        var slot = 2, fileRate = 22050, path = scratchRoot +/+ "buffers-past-end.wav", frames = fileRate * 16;
        writeRegions.(path, "WAV", fileRate, fileRate, frames, 0.1, 0.7);
        // 100000 s at 22050 Hz is more frames than an int32 holds
        [100, 100000].do({ arg start;
            command.(\loadBuffer, slot, path, start);
            h.waitFor({ engine.bufferFrames[slot] == frames });
            0.1.wait; server.sync;
            check.((engine.bufferFrames[slot] == frames) and: { (bufferSample.(engine.buffersL[slot], 0) - 0.7).abs < 0.001 },
                "buffers: a start past the file's end loads its last frames (start %: % frames, first sample %)".format(
                    start, engine.bufferFrames[slot], bufferSample.(engine.buffersL[slot], 0)));
            command.(\clearBuffer, slot); server.sync;
        });
        File.delete(path);
    }.value;
    // a long file's check seeks too: the peaks it reads begin at the start
    longPath = scratchRoot +/+ "buffers-start-long.wav";
    writeRegions.(longPath, "WAV", rate, rate * 2, rate * 20, 0.9, 0.2);
    other = startHighEngine.("start-long");
    h.commandTo(other, \loadBuffer, 2, longPath, 2);
    h.waitFor({ other.bufferFrames[2] == (rate * 20) }, 10);
    0.1.wait; server.sync;
    peaks = other.areaState[\waveform][\peaks][2];
    check.((other.bufferFrames[2] == (rate * 20)) and: { (peaks.maxItem - 0.2).abs < 0.001 },
        "buffers: a long file's check starts at the start (% frames, largest peak %)".format(other.bufferFrames[2], peaks.maxItem));
    h.freeEngine(other);
    File.delete(longPath);
}.value;

// #456: a slot that holds frames reports at least 0.01 s, however few (a
// 128-frame single cycle is 0.0027 s, which rounds to 0.00: Lua would take
// it as empty); an empty slot reports 0
{
    var slot = 5, path = scratchRoot +/+ "buffers-single-cycle.wav", value, emptyValue, emptyBase;
    h.writeTestFile(path, server.sampleRate.asInteger, 128, [0.5, -0.5]);
    command.(\clearBuffer, slot); server.sync;
    emptyValue = engine.bufferStateValue(slot);
    emptyBase = stateBase.(slot);
    command.(\loadBuffer, slot, path, 0);
    waitFor.({ engine.bufferFrames[slot] == 128 });
    0.1.wait; server.sync;
    value = engine.bufferStateValue(slot);
    check.((engine.bufferFrames[slot] == 128) and: { (value - (stateBase.(slot) + 0.01)).abs < 0.001 }
        and: { h.pollValueNear(\bufferState, stateBase.(slot) + 0.01, 0.002) } and: { emptyValue == emptyBase },
        "buffers: a slot holding 128 frames reports 0.01 s, an empty one 0 (% frames: %, empty: %)".format(
            engine.bufferFrames[slot], value, emptyValue));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
}.value;

// #578: every bufferState report names the slot's load it was sent after:
// ((loads % 7) * 9 + slot index) * 1000 + seconds, loads being the
// loadBuffer commands the engine has received for the slot (counted from
// 1, as Lua's load_buffer counts them), whatever change the report is of.
// Slot 7 (index 6) is first brought to a multiple of 7 loads with missing
// files (each rejected at once, with no bufferState report), so every
// value below is a literal: two quick loads (the first one's length is
// never reported), a failed load (the periodic report then names it), a
// clear and a recording (the slot's load number), and the seventh load's
// wrap to 0. The 32-bit float keeps the largest value to the hundredth.
{
    var slot = 6, missing = scratchRoot +/+ "missing.wav", start, values, near, cycle, periodic, top;
    var poll = engine.bufferStatePoll;
    // the slot's bufferState values received since `start`, consecutive
    // repeats once. A function per message, which the #131 note above rules
    // out for the whole run's messages, runs here only over the window
    // since `start`: a few seconds, a handful of messages
    var slotValues = { arg since;
        var found = List.new(16);
        h.pollMessages.array.copyRange(since, h.pollMessages.size - 1).do({ arg msg;
            var value = msg[2];
            if ((msg[1] == poll.index) and: { ((value / 1000).floor.asInteger % 9) == slot }
                and: { found.isEmpty or: { found.last != value } }) { found.add(value) };
        });
        found.asArray
    };
    // [load number, seconds] of a value, as Lua decodes it (the hundredths rounded)
    var decode = { arg value; var cell = (value / 1000).floor.asInteger; [cell div: 9, ((value - (cell * 1000)) * 100).round / 100] };
    // true when each decoded value names the load and the hundredth wanted
    var decodes = { arg got, wanted; (got.size == wanted.size) and: { got.every({ arg value, index;
        var pair = decode.(value); (pair[0] == wanted[index][0]) and: { (pair[1] - wanted[index][1]).abs < 1e-9 } }) } };
    // the index the next messages take, once every message sent so far has
    // arrived (a periodic repeat of the slot's previous value must not open
    // the next window)
    var from = { 0.05.wait; server.sync; h.pollMessages.size };
    near = { arg got, wanted; (got.size == wanted.size) and: { got.every({ arg value, index; (value - wanted[index]).abs < 0.004 }) } };
    // one whole periodic cycle, stepped now (requestValue runs the poll's function)
    cycle = { (engine.numBuffers + 1).collect({ poll.requestValue; poll.value }) };
    command.(\clearBuffer, slot); server.sync;
    ((7 - (engine.bufferLoads[slot] % 7)) % 7).do({ command.(\loadBuffer, slot, missing, 0) });
    // two quick loads: 0 s for each as it takes effect, then the second's 0.1 s
    start = from.value;
    command.(\loadBuffer, slot, stereoPath, 0);
    command.(\loadBuffer, slot, monoPath, 0);
    waitFor.({ near.(slotValues.(start), [15000.0, 24000.0, 24000.1]) });
    values = slotValues.(start);
    check.(near.(values, [15000.0, 24000.0, 24000.1]) and: { decodes.(values, [[1, 0], [2, 0], [2, 0.1]]) },
        "buffers: two quick loads report 0 s as load 1, then 0 s and 0.1 s as load 2, never load 1's 0.5 s (#578; got % = %)".format(
            values, values.collect(decode)));
    // a failed load: the slot's next periodic report names it (Lua counted it too)
    command.(\loadBuffer, slot, missing, 0);
    server.sync;
    periodic = cycle.value.detect({ arg value; ((value / 1000).floor.asInteger % 9) == slot });
    check.(periodic.notNil and: { (periodic - 33000.1).abs < 0.004 },
        "buffers: after a failed third load the periodic report names load 3 with the slot's 0.1 s (#578; got %)".format(periodic));
    // a clear, then a replace take: each report names the slot's load (3)
    start = from.value;
    command.(\clearBuffer, slot);
    command.(\recordBuffer, slot, 0.1, 1.0, 0, 0, 0, 0, 0, 0);
    waitFor.({ near.(slotValues.(start), [33000.0, 33000.1]) });
    values = slotValues.(start);
    check.(near.(values, [33000.0, 33000.1]),
        "buffers: a clear and a recording report the slot's load number, 3 (#578; got %)".format(values));
    // loads 4 to 6 fail, the seventh takes the number back to 0
    3.do({ command.(\loadBuffer, slot, missing, 0) });
    start = from.value;
    command.(\loadBuffer, slot, stereoPath, 0);
    waitFor.({ near.(slotValues.(start), [6000.0, 6000.5]) });
    values = slotValues.(start);
    check.(near.(values, [6000.0, 6000.5]) and: { engine.bufferLoads[slot] % 7 == 0 },
        "buffers: the seventh load's reports name load 0 (#578; got %)".format(values));
    // the largest value, slot index 7 at load number 6 and 300 s: 61300
    top = [61000.0, 61000.01, 61150.37, 61299.99, 61300.0];
    values = FloatArray.newFrom(top).asArray;
    check.(values.every({ arg value, index; (value - top[index]).abs < 0.002 })
        and: { decodes.(values, [[6, 0], [6, 0.01], [6, 150.37], [6, 299.99], [6, 300]]) },
        "buffers: the largest bufferState value, 61300, keeps its load number and 0.01 s in a 32-bit float (#578; got %)".format(
            values.collect(decode)));
    command.(\clearBuffer, slot); server.sync;
}.value;

// 3.7's slot gain (design §4.4): setSlotGain keeps a gain per slot (1 at
// alloc), sends it to every live reader of the slot at once and to a reader
// started later (slotLengthPairs); a load and a clear set it back to 1 with
// the same send; the command clips the gain to 0-16, records it and ignores a
// bad slot or a non-finite gain with one line
{
    var slot = 4, voice = 5, gains = engine.areaState[\buffers][\gains], grain = { engine.synths[engine.grainKey(voice)] };
    var modulation = engine.areaState[\modulation], previous = modulation[\postIgnored], lines = List.new;
    var atAlloc = gains.copy, live, started, loaded, cleared, received, ignored;
    command.(\loadBuffer, slot, stereoPath, 0); h.awaitLoad(slot);
    command.(\setGrainSource, voice, slot + 1);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 20.0, 1.0);
    server.sync;
    command.(\setSlotGain, slot, 2.5);
    server.sync;
    live = [gains[slot], getControl.(grain.value, \slotGain)];
    command.(\setGrainSource, voice, 0);
    command.(\setGrainSource, voice, slot + 1);
    server.sync;
    started = getControl.(grain.value, \slotGain);
    check.((atAlloc == (1 ! engine.numBuffers)) and: { live[0] == 2.5 } and: { live[1].equalWithPrecision(2.5, 1e-6) }
        and: { started.equalWithPrecision(2.5, 1e-6) },
        "buffers: setSlotGain reaches a live reader and the reader a later start makes (at alloc %; kept and live %; a later start %)".format(
            atAlloc, live, started));
    command.(\loadBuffer, slot, stereoPath, 0);
    loaded = [gains[slot]];
    server.sync;
    loaded = loaded ++ [getControl.(grain.value, \slotGain)];
    h.awaitLoad(slot);
    command.(\setSlotGain, slot, 3.0);
    command.(\clearBuffer, slot);
    server.sync;
    cleared = [gains[slot], getControl.(grain.value, \slotGain)];
    check.((loaded[0] == 1) and: { loaded[1] == 1 } and: { cleared[0] == 1 } and: { cleared[1] == 1 },
        "buffers: a load and a clear set the slot's gain to 1 (load: kept and live %; clear %)".format(loaded, cleared));
    command.(\setSlotGain, slot, 17.0);
    received = [engine.areaState[\buffers][\received][\setSlotGain].copy, gains[slot]];
    command.(\setSlotGain, slot, -1.0);
    received = received ++ [gains[slot]];
    modulation[\postIgnored] = { arg line; lines.add(line) };
    {
        [[\setSlotGain, 8, 1.0], [\setSlotGain, -1, 1.0], [\setSlotGain, slot, 0.0 / 0.0], [\setSlotGain, slot, inf]].do({ arg call;
            command.(*call) });
    }.protect({ modulation[\postIgnored] = previous });
    ignored = (lines.size == 4) and: { lines.every({ arg line; line.beginsWith("strata: setSlotGain ignored: ") }) }
        and: { engine.areaState[\buffers][\received][\setSlotGain] == [slot, 0.0] } and: { gains[slot] == 0 };
    check.((received[0] == [slot, 16.0]) and: { received[1] == 16 } and: { received[2] == 0 } and: { ignored },
        "buffers: setSlotGain clips its gain to 0-16, records it, and ignores a bad slot or gain with one line each (received %; lines %)".format(
            received, lines.asArray));
    command.(\setSlotGain, slot, 1.0);
    command.(\voiceOff, voice);
    h.stopAllVoices;
    command.(\setGrainSource, voice, 0);
    server.sync;
}.value;
}
