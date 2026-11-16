// test/engine_check/onsets.scd
// The onsets area (3.7): analyzeBuffer's transients pass over a slot, its
// bufferOnsets poll and its file, buf<n>.onsets in the settings folder.
// Clicks at known frames, silence and a steady tone, the 63 kept at least
// 30 ms apart, the strengths, the file in place before the report, a pass a
// load, a clear or a recording overtakes, the refusals, a 300 s pass on a
// high engine that lets commands in, no file left behind, and an index out
// of range. Test sound is built with C primitives (#131): single-sample
// clicks put into a silent Signal, a period repeated.
{ arg h;
var engine = h.engine, server = h.server, scratchRoot = h.tempDir;
var rate = server.sampleRate.asInteger;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var waitFor = { arg condition, timeout = 3; h.waitFor(condition, timeout) };
var area = engine.strataAreas.detect({ arg each; each[\name] == \onsets });
var state, poll, hop, gapFrames, gapHops, body;

// Per slot, the analyzeBuffer commands an engine has counted
var analysesOf = { arg target; target.areaState[\onsets][\analyses] };

// A slot's onsets file on an engine, standardized
var onsetsFile = { arg target, slot; target.onsetsPath(slot).standardizePath };

// An onsets file's lines as an Event of key -> the line's other words
// (\magic: its first line), or nil when there is none
var readOnsets = { arg path;
    var fields = (), lines;
    if (File.exists(path).not) { nil } {
        lines = File.readAllString(path).split($\n);
        fields[\magic] = lines[0];
        lines.do({ arg line;
            var words = line.split($ ).reject(_.isEmpty);
            if (words.size > 0) { fields[words[0].asSymbol] = words.drop(1) };
        });
        fields
    }
};
var onsetFrames = { arg fields; (fields !? { fields[\onsets] } ? []).collect(_.asInteger) };
var onsetStrengths = { arg fields; (fields !? { fields[\strengths] } ? []).collect(_.asFloat) };

// What an analysis left behind: its temporary float files and the .part
// files of the slot's onsets file
var tempFilesOf = { arg target, slot, count;
    (Platform.defaultTempDir +/+ "strata-buf%-%-onsets%-*.wav".format(slot + 1, target.instanceTag, count)).pathMatch
};
var partFilesOf = { arg target, slot; (onsetsFile.(target, slot) ++ ".*.part").pathMatch };

// Start an analysis of a slot on target: an Event that notes the report's
// arrival (an OSCFunc on /poll/value, as the waveform check watches the
// length's), whether it failed, and whether the onsets file was there then
var startAnalysis = { arg target, slot;
    var run = (slot: slot, count: analysesOf.(target)[slot] + 1, target: target), index = poll.index;
    run[\watcher] = OSCFunc({ arg msg;
        var value = msg[2].asInteger, slots = target.numBuffers;
        if ((msg[1] == index) and: { (value % slots) == slot } and: { ((value div: slots) div: 2) == run[\count] }
            and: { run[\arrived].isNil }) {
            run[\arrived] = Main.elapsedTime;
            run[\failed] = ((value div: slots) % 2) == 1;
            run[\fileThere] = File.exists(onsetsFile.(target, slot));
        };
    }, '/poll/value');
    run[\start] = Main.elapsedTime;
    h.commandTo(target, \analyzeBuffer, slot);
    run
};
// Wait for its report, at most timeout s (a FAIL line naming the slot and
// the analysis otherwise); the run gets its seconds from the command
var finishAnalysis = { arg run, timeout = 5;
    waitFor.({ run[\arrived].notNil }, timeout);
    run[\watcher].free;
    if (run[\arrived].isNil) {
        check.(false, "onsets: slot %'s analysis % reports within % s".format(run[\slot], run[\count], timeout));
    };
    run[\seconds] = run[\arrived] !? { arg arrived; arrived - run[\start] };
    run
};
var analyze = { arg target, slot, timeout = 5; finishAnalysis.(startAnalysis.(target, slot), timeout) };

// A stereo float WAV at the server rate, `frames` long, silent but for
// single-sample clicks at clickFrames (an Array) of levels (an Array), the
// same on both channels
var writeClickFile = { arg path, frames, clickFrames, levels;
    var mono = Signal.newClear(frames), file;
    mono.putEach(clickFrames, levels);
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(rate);
    file.openWrite(path);
    file.writeData(h.stereoOf(mono, mono));
    file.close;
};
// Load a file into a slot of target and wait for it
var loadInto = { arg target, slot, path, timeout = 5;
    h.commandTo(target, \loadBuffer, slot, path, 0);
    h.awaitLoad(slot, target, timeout);
};

// A high engine of its own (300 s slots), as the waveform area builds one
var highRoot = scratchRoot +/+ "onsets-high";
var startHighEngine = {
    var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(highRoot);
    write.(highRoot +/+ "performance.data", "performance high\nbuffer_seconds 300\n");
    write.(highRoot +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(highRoot +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    h.startEngine((settingsDir: highRoot, modelPath: highRoot +/+ "model", meminfoPath: highRoot +/+ "meminfo"))
};

// The area, its literals, its command and its state
var checkArea = {
    check.(area[\order] == 180, "onsets: the area runs at order 180 (got %)".format(area[\order]));
    check.((engine.onsetHopFrames == 256) and: { engine.onsetCandidates == 63 } and: { engine.onsetGapSeconds == 0.03 },
        "onsets: a hop is 256 frames, 63 candidates at most, 30 ms apart (got %, %, %)".format(
            engine.onsetHopFrames, engine.onsetCandidates, engine.onsetGapSeconds));
    check.(h.formatOf(\analyzeBuffer) == "i", "onsets: analyzeBuffer's signature is \"i\" (got %)".format(h.formatOf(\analyzeBuffer)));
    check.((analysesOf.(engine).size == engine.numBuffers) and: { analysesOf.(engine).every(_.isInteger) },
        "onsets: each slot counts its analyses (%)".format(analysesOf.(engine)));
    check.(engine.onsetsPath(2) == (engine.allocSettingsDirectory +/+ "buf3.onsets"),
        "onsets: a slot's file is buf<n>.onsets in the folder used at alloc (%)".format(engine.onsetsPath(2)));
    check.(engine.bufferOnsetsValue(3, 5, true) == ((((5 * 2) + 1) * engine.numBuffers) + 3).asFloat,
        "onsets: bufferOnsets packs (count * 2 + failed) * numBuffers + slot index");
};

// Eight clicks of rising level at 0.25 s steps: each found at the first
// frame of its hop, the strongest (the last, loudest: each follows
// silence, so its strength is its energy over the floor) 1, the others in
// proportion, the list in frame order, the file in place before the
// report, and no temporary file or .part left
var checkClicks = {
    var slot = 0, path = scratchRoot +/+ "onsets-clicks.wav", frames = (2.25 * rate).asInteger;
    var clicks = (1 .. 8).collect({ arg step; (step * 0.25 * rate).asInteger });
    var levels = (2 .. 9).collect({ arg step; step / 10 }), run, fields, found, strengths, expected, floor;
    writeClickFile.(path, frames, clicks, levels);
    loadInto.(engine, slot, path);
    if (File.exists(onsetsFile.(engine, slot))) { File.delete(onsetsFile.(engine, slot)) };
    run = analyze.(engine, slot);
    fields = readOnsets.(onsetsFile.(engine, slot));
    found = onsetFrames.(fields);
    strengths = onsetStrengths.(fields);
    check.((run[\failed] == false) and: { found.size == 8 }
        and: { found.every({ arg frame, i; (frame >= (clicks[i] - hop)) and: { frame <= clicks[i] } }) }
        and: { found.every({ arg frame; (frame % hop) == 0 }) },
        "onsets: clicks at known frames are each found within one hop before them (clicks %, found %)".format(clicks, found));
    check.(fields.notNil and: { fields[\magic] == "strata-onsets 1" } and: { fields[\slot] == ["1"] }
        and: { fields[\frames] == [frames.asString] } and: { fields[\rate] == [rate.asString] },
        "onsets: the file names its format, slot, frames and rate (%)".format(fields));
    // each strength: its energy over the floor's half, less 2, over the loudest's
    floor = engine.onsetFloor * 0.5;
    expected = levels.collect({ arg level; ((2 * level.squared) / floor) - 2 });
    expected = expected / expected.last;
    check.((strengths.size == found.size) and: { strengths.last == 1.0 } and: { strengths.every({ arg each; (each >= 0) and: { each <= 1 } }) }
        and: { (fields[\strengths] ? []).every({ arg text; (text.size == 5) and: { text[1] == $. } }) }
        and: { found == found.copy.sort } and: { strengths.every({ arg each, i; (each - expected[i]).abs < 0.0015 }) },
        "onsets: the strongest candidate's strength is 1 and the list is in frame order (strengths %, expected %)".format(
            fields !? { fields[\strengths] }, expected.round(0.001)));
    check.(run[\fileThere] == true, "onsets: the file is in place before the report (found: %)".format(run[\fileThere]));
    check.(tempFilesOf.(engine, slot, run[\count]).isEmpty and: { partFilesOf.(engine, slot).isEmpty },
        "onsets: the pass leaves no temporary file (temporary %, .part %)".format(
            tempFilesOf.(engine, slot, run[\count]), partFilesOf.(engine, slot)));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// Silence and a steady tone (from the slot's first frame) have no onset:
// both passes report, each file's two lists empty
var checkNone = {
    var slot = 1, silentPath = scratchRoot +/+ "onsets-silent.wav", tonePath = scratchRoot +/+ "onsets-tone.wav";
    var period = Array.fill(100, { arg i; (i / 100 * 2pi).sin * 0.5 }), tone, file, silent, steady;
    h.writeTestFile(silentPath, rate, rate, [0, 0]);
    tone = h.periodic(period, 0, rate);
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(rate);
    file.openWrite(tonePath); file.writeData(h.stereoOf(tone, tone)); file.close;
    loadInto.(engine, slot, silentPath);
    silent = analyze.(engine, slot);
    silent[\fields] = readOnsets.(onsetsFile.(engine, slot));
    loadInto.(engine, slot, tonePath);
    steady = analyze.(engine, slot);
    steady[\fields] = readOnsets.(onsetsFile.(engine, slot));
    check.([silent, steady].every({ arg run; (run[\failed] == false) and: { run[\fields].notNil }
        and: { run[\fields][\onsets] == [] } and: { run[\fields][\strengths] == [] } }),
        "onsets: silence gives none, and a steady tone gives none (silence %, tone %)".format(
            silent[\fields] !? { arg each; each[\onsets] }, steady[\fields] !? { arg each; each[\onsets] }));
    command.(\clearBuffer, slot); server.sync;
    File.delete(silentPath); File.delete(tonePath);
};

// 200 clicks 10 ms apart of rising level: the first follows silence (the
// strongest), the second only the first, and from the third on each
// follows the two before it, its energy rising faster than theirs, so the
// strengths rise from the third click on. Kept: the strongest first, each
// at least 30 ms from every one kept before it (gapHops whole hops, as the
// kept frames are hops' first frames). And 100 clicks 40 ms apart of rising
// level, each after silence: the 63 strongest are the last 63.
var checkKept = {
    var slot = 2, path = scratchRoot +/+ "onsets-dense.wav", frames = (2.2 * rate).asInteger;
    var spacing = (0.01 * rate).asInteger, first = (0.1 * rate).asInteger;
    var clicks = (0 .. 199).collect({ arg k; first + (k * spacing) });
    var growth = (18.squared).log / 199.squared;
    var levels = (0 .. 199).collect({ arg k; 0.05 * (growth * k.squared / 2).exp });
    var byStrength = [0, 1] ++ (199, 198 .. 2), keptHops = List.new(engine.onsetCandidates), expected, found, run, gaps;
    var sparsePath = scratchRoot +/+ "onsets-sparse.wav", sparseSpacing = (0.04 * rate).asInteger, sparseClicks, sparseRun, sparseFound;
    writeClickFile.(path, frames, clicks, levels);
    loadInto.(engine, slot, path);
    run = analyze.(engine, slot);
    found = onsetFrames.(readOnsets.(onsetsFile.(engine, slot)));
    byStrength.do({ arg k;
        var clickHop = clicks[k] div: hop;
        if ((keptHops.size < engine.onsetCandidates) and: { keptHops.every({ arg kept; (kept - clickHop).abs >= gapHops }) }) {
            keptHops.add(clickHop);
        };
    });
    expected = keptHops.asArray.sort * hop;
    gaps = found.differentiate.drop(1);
    check.((run[\failed] == false) and: { found.size <= engine.onsetCandidates } and: { gaps.every({ arg gap; gap >= gapFrames }) }
        and: { found == expected },
        "onsets: at most 63, at least 30 ms apart, the strongest kept (% kept, smallest gap %, expected % at %)".format(
            found.size, gaps.minItem, expected.size, expected.copyRange(0, 4)));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
    sparseClicks = (0 .. 99).collect({ arg k; first + (k * sparseSpacing) });
    writeClickFile.(sparsePath, (4.2 * rate).asInteger, sparseClicks, (0 .. 99).collect({ arg k; 0.05 * (18 ** (k / 99)) }));
    loadInto.(engine, slot, sparsePath);
    sparseRun = analyze.(engine, slot);
    sparseFound = onsetFrames.(readOnsets.(onsetsFile.(engine, slot)));
    check.((sparseRun[\failed] == false) and: { sparseFound == sparseClicks.drop(37).collect({ arg click; click div: hop * hop }) },
        "onsets: of 100 candidates the 63 strongest are kept (% kept, from % to %)".format(
            sparseFound.size, sparseFound.first, sparseFound.last));
    command.(\clearBuffer, slot); server.sync;
    File.delete(sparsePath);
};

// A load, a clear or a recording sent during a pass makes it report
// failed and leave no file (nor a temporary file or a .part), and stops it
// at once: the clear in the same tick as the command (before the server's
// writes are synced: it reads no chunk), the load and the recording once
// the pass has read two chunks (each chunk slowed to 20 ms here, so it is
// still reading: it reads at most the chunk under way after the change)
var checkInterrupted = {
    var slot = 3, path = scratchRoot +/+ "onsets-ten.wav", outcomes = List.new(3);
    var interrupt = { arg kind, midLoop, disrupt, settle;
        var run, chunks, atChange;
        loadInto.(engine, slot, path);
        if (File.exists(onsetsFile.(engine, slot))) { File.delete(onsetsFile.(engine, slot)) };
        chunks = state[\chunks];
        run = startAnalysis.(engine, slot);
        if (midLoop) { waitFor.({ state[\chunks] >= (chunks + 2) }, 5) };
        disrupt.value;
        atChange = state[\chunks];
        settle.value;
        finishAnalysis.(run, 10);
        // a late rename would come with the pass's own report: none comes after it
        0.2.wait;
        outcomes.add([kind, run[\failed], File.exists(onsetsFile.(engine, slot)),
            tempFilesOf.(engine, slot, run[\count]).size, partFilesOf.(engine, slot).size,
            (state[\chunks] - atChange) <= (if (midLoop) { 1 } { 0 })]);
    };
    h.writeTestFile(path, rate, 10 * rate, [0.25, -0.25]);
    state[\chunkWait] = 0.02;
    protect {
        interrupt.(\clear, false, { command.(\clearBuffer, slot) }, {});
        interrupt.(\load, true, { command.(\loadBuffer, slot, h.stereoPath, 0) }, { h.awaitLoad(slot) });
        interrupt.(\record, true, { command.(\recordBuffer, slot, 0.2, 1.0, 0, 0, 0, 0, 0) }, { h.awaitTake(slot) });
    } { state[\chunkWait] = nil };
    check.((outcomes.size == 3) and: { outcomes.every({ arg each; each.drop(1) == [true, false, 0, 0, true] }) },
        "onsets: a load, a clear or a recording sent during the pass makes it report failed and leave no file ([kind, failed, file, temporary, .part, stopped at once]: %)".format(
            outcomes.asArray));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// Refused at once, with a failed report: an empty slot, and a slot that
// records (one holding audio, in a playable recording). Nothing is written.
var checkRefused = {
    var slot = 4, count, empty, recording, atOnce = List.new(2), wasRecording, frames, path = scratchRoot +/+ "onsets-held.wav";
    command.(\clearBuffer, slot); server.sync;
    count = analysesOf.(engine)[slot] + 1;
    empty = startAnalysis.(engine, slot);
    atOnce.add(poll.value == engine.bufferOnsetsValue(slot, count, true));
    finishAnalysis.(empty);
    // at the server's rate, so the recording is a playable one over the audio
    h.writeTestFile(path, rate, rate, [0.25, 0.25]);
    loadInto.(engine, slot, path);
    command.(\recordBuffer, slot, 2.0, 1.0, 0.5, 0, 0, 0, 0);
    wasRecording = engine.slotRecording(slot);
    frames = engine.bufferFrames[slot];
    recording = startAnalysis.(engine, slot);
    atOnce.add(poll.value == engine.bufferOnsetsValue(slot, count + 1, true));
    finishAnalysis.(recording);
    command.(\stopRecord, slot);
    h.awaitTake(slot);
    check.((empty[\failed] == true) and: { recording[\failed] == true } and: { wasRecording } and: { atOnce.every(_.value) }
        and: { tempFilesOf.(engine, slot, count).isEmpty } and: { tempFilesOf.(engine, slot, count + 1).isEmpty },
        "onsets: an empty slot and a recording slot are refused with a failed report (failed %, %; recording %, % frames; at once %)".format(
            empty[\failed], recording[\failed], wasRecording, frames, atOnce.asArray));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// A 16 s pass on the standard tier, timed; then a 300 s pass on a high
// engine: a message sent every 10 ms while it runs is each handled within
// 5 ms (an OSC message waits for the language lock, which the pass holds
// for one chunk at most), and it keeps the 63 of a click every 1000 frames
var checkLong = {
    var period = [0.9] ++ Array.fill(999, 0), write, standardRun, longRun, highEngine, slot = 0;
    var shortPath = scratchRoot +/+ "onsets-16.wav", longPath = highRoot +/+ "onsets-300.wav";
    var capacity = 20000, sentAt = Array.newClear(capacity), latency = Signal.newClear(capacity), sent = 0, heard = 0, ping;
    write = { arg path, seconds;
        var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
        file.openWrite(path);
        h.writePeriodicSeconds(file, period, seconds, rate);
        file.close;
    };
    write.(shortPath, engine.standardBufferSeconds);
    loadInto.(engine, slot, shortPath);
    standardRun = analyze.(engine, slot, 10);
    check.((standardRun[\failed] == false) and: { onsetFrames.(readOnsets.(onsetsFile.(engine, slot))).size == engine.onsetCandidates },
        "onsets: a 16 s pass keeps 63 and reports in % s".format(standardRun[\seconds] !? { arg each; each.round(0.001) }));
    command.(\clearBuffer, slot); server.sync;
    File.delete(shortPath);

    highEngine = startHighEngine.value;
    protect {
        write.(longPath, 300);
        loadInto.(highEngine, slot, longPath, 60);
        ping = OSCFunc({ arg msg;
            var number = msg[1].asInteger;
            if ((number >= 0) and: { number < sent }) { latency[number] = Main.elapsedTime - sentAt[number]; heard = heard + 1 };
        }, '/strataCheckOnsetsPing');
        longRun = startAnalysis.(highEngine, slot);
        while { longRun[\arrived].isNil and: { sent < capacity } and: { (Main.elapsedTime - longRun[\start]) < 120 } } {
            sentAt[sent] = Main.elapsedTime;
            sent = sent + 1;
            NetAddr.localAddr.sendMsg('/strataCheckOnsetsPing', sent - 1);
            0.01.wait;
        };
        finishAnalysis.(longRun, 1);
        0.1.wait;
        ping.free;
        check.((longRun[\failed] == false) and: { heard == sent } and: { sent > 10 } and: { latency.copyRange(0, sent - 1).peak < 0.005 }
            and: { onsetFrames.(readOnsets.(onsetsFile.(highEngine, slot))).size == engine.onsetCandidates },
            "onsets: a 300 s slot's pass yields to commands (% s; % messages, % heard, the slowest handled in % ms)".format(
                longRun[\seconds] !? { arg each; each.round(0.01) }, sent, heard,
                (latency.copyRange(0, (sent - 1).max(0)).peak * 1000).round(0.01)));
        h.commandTo(highEngine, \clearBuffer, slot); server.sync;
    } {
        h.freeEngine(highEngine);
        if (File.exists(longPath)) { File.delete(longPath) };
    };
};

// An index out of range is ignored with one line, and counts nothing
var checkOutOfRange = {
    var modulation = engine.areaState[\modulation], previous = modulation[\postIgnored], lines = List.new(4);
    var before = analysesOf.(engine).copy;
    modulation[\postIgnored] = { arg line; lines.add(line) };
    protect {
        command.(\analyzeBuffer, -1);
        command.(\analyzeBuffer, engine.numBuffers);
    } { modulation[\postIgnored] = previous };
    check.((lines.size == 2) and: { lines.every({ arg line; line.contains("analyzeBuffer") }) } and: { analysesOf.(engine) == before },
        "onsets: a slot index out of range is ignored, one line (%)".format(lines.asArray));
};

body = {
    state = engine.areaState[\onsets];
    poll = engine.bufferOnsetsPoll;
    hop = engine.onsetHopFrames;
    gapFrames = engine.onsetGapSeconds * rate;
    gapHops = (gapFrames / hop).ceil.asInteger;
    poll.start;
    protect {
        checkArea.value;
        checkClicks.value;
        checkNone.value;
        checkKept.value;
        checkInterrupted.value;
        checkRefused.value;
        checkLong.value;
        checkOutOfRange.value;
    } { poll.stop };
};

if (area.isNil) {
    check.(false, "onsets: the engine has an onsets area (strataAreaOnsets)");
} {
    body.value;
};
}
