// test/engine_check/onsets.scd
// The onsets area (3.7): analyzeBuffer's transients pass over a slot, its
// bufferOnsets poll and its file, buf<n>.onsets in the settings folder.
// Clicks at known frames, silence and a steady tone, the 63 kept at least
// 30 ms apart, the strengths, the file in place before the report, a pass a
// load, a clear, a recording or a newer analysis overtakes, an older pass's
// late rename that leaves a newer pass's file, the refusals, a 300 s pass on a
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
// silence, so its rise is its energy over half the floor) 1, the others
// by their rise in level (log2 of that ratio, less 1), the list in frame
// order, the file in place before the report, and no temporary file or
// .part left
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
    // each strength: log2 of its energy over the floor's half, less 1, over the loudest's
    floor = engine.onsetFloor * 0.5;
    expected = levels.collect({ arg level; ((2 * level.squared) / floor).log2 - 1 });
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

// One hit after silence, then four hits inside a steady texture (a tone
// whose every hop holds the same energy), each a known rise over the mean
// of the four hops before it: 3, 9, 5 and 17 times, in that order in time.
// A strength is the rise in level, log2 of that ratio less 1 (the 2x
// threshold), over the strongest's: the hit after silence (its ratio over
// half the floor, about 13000) is 1, and the four in the texture keep
// three-decimal strengths that are distinct, non-zero and in the order of
// their rises. Each click falls where the tone is 0, so its hop holds the
// tone's energy and the click's alone.
var checkTexture = {
    var slot = 5, path = scratchRoot +/+ "onsets-texture.wav", start = 19 * hop, spacing = 4800;
    var toneLevel = 0.02, period = Array.fill(64, { arg i; (i / 64 * 2pi).sin * toneLevel });
    // a hop of the tone, both channels
    var toneEnergy = 2 * hop * toneLevel.squared / 2;
    var rises = [3, 9, 5, 17], frames = start + (spacing * (rises.size + 1));
    var clicks = [start] ++ rises.collect({ arg rise, k; start + ((k + 1) * spacing) });
    var levels = [0.9] ++ rises.collect({ arg rise; ((rise - 1) * toneEnergy / 2).sqrt });
    var ratios = [(toneEnergy + (2 * 0.9.squared)) / (engine.onsetFloor * 0.5)] ++ rises;
    var mono = Signal.newClear(frames), file, run, fields, found, texts, strengths, expected, inTexture;
    mono.overWrite(h.periodic(period, 0, frames - start), start);
    mono.putEach(clicks, levels);
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(rate);
    file.openWrite(path); file.writeData(h.stereoOf(mono, mono)); file.close;
    loadInto.(engine, slot, path);
    run = analyze.(engine, slot);
    fields = readOnsets.(onsetsFile.(engine, slot));
    found = onsetFrames.(fields);
    texts = fields !? { fields[\strengths] } ? [];
    strengths = onsetStrengths.(fields);
    expected = ratios.collect({ arg ratio; ratio.log2 - 1 });
    expected = expected / expected[0];
    inTexture = texts.drop(1);
    check.((run[\failed] == false) and: { found == clicks.collect({ arg click; click div: hop * hop }) }
        and: { strengths.size == 5 } and: { strengths[0] == 1.0 }
        and: { inTexture.every({ arg text; text.asFloat > 0 }) } and: { inTexture.asSet.size == inTexture.size }
        and: { (strengths.drop(1).order) == (rises.order) }
        and: { strengths.every({ arg each, i; (each - expected[i]).abs < 0.0015 }) },
        "onsets: a strength is the rise in level: a hit after silence and hits in a texture stay distinct, non-zero and in order (found %, strengths %, expected %)".format(
            found, texts, expected.round(0.001)));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// Each hop's energy against a plain reference: noise, different on the
// two channels, through hopEnergies (the two channels added, as the pass
// adds them) and through each hop's own copyRange(...).squared.integral
// (Signal's integral is one sum), over a whole chunk and over a chunk
// longer than the hops asked for (cut to them)
var checkEnergies = {
    var size = engine.onsetChunkFrames, left = h.noise(size, 0.8), right = h.noise(size, 0.3);
    var compare = { arg hops;
        var energies = engine.hopEnergies(left, hops) + engine.hopEnergies(right, hops);
        var reference = (0 .. hops - 1).collect({ arg i;
            var first = i * hop, last = first + hop - 1;
            left.copyRange(first, last).squared.integral + right.copyRange(first, last).squared.integral
        });
        (energies.size == hops) and: { reference.every({ arg each, i; ((energies[i] - each).abs / each) < 1e-5 }) }
    };
    check.(compare.(size div: hop) and: { compare.(40) } and: { left[0] != right[0] },
        "onsets: each hop's energy is the sum of its frames' squares on both channels (noise, against copyRange and integral)");
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

// Wait (inside the check routine) until condition is true or timeout
// passes, looking every 5 ms (waitFor looks every 50 ms)
// A copy of h.waitFor with its own step: the helper is test/engine_check.scd's, outside this area's file
var waitFine = { arg condition, timeout = 5;
    var started = Main.elapsedTime;
    while { condition.value.not and: { (Main.elapsedTime - started) < timeout } } { 0.005.wait };
    condition.value
};
// Every temporary float file of a slot's analyses on target
var allTempFilesOf = { arg target, slot;
    (Platform.defaultTempDir +/+ "strata-buf%-%-onsets*-*.wav".format(slot + 1, target.instanceTag)).pathMatch
};

// A second analyzeBuffer of a slot ends the pass under way at its next
// chunk (#872): the older reports failed, the newer runs to its end and
// writes the file, and only one pair of temporary files is there at a time.
// Each chunk is slowed to 20 ms; the older pass has read two chunks when the
// second command comes, and the pair is counted once four more chunks have
// been read (the older pass, still going, would have read two of them).
var checkSuperseded = {
    var slot = 6, path = scratchRoot +/+ "onsets-superseded.wav", older, newer, before, atSecond, newerChunks, olderChunks;
    var pairs, newerArrivedThen, frames;
    h.writeTestFile(path, rate, 4 * rate, [0.25, -0.25]);
    loadInto.(engine, slot, path);
    if (File.exists(onsetsFile.(engine, slot))) { File.delete(onsetsFile.(engine, slot)) };
    frames = engine.bufferFrames[slot];
    // the chunks a whole pass over the slot reads
    newerChunks = ((frames div: hop) / 64).ceil.asInteger;
    state[\chunkWait] = 0.02;
    protect {
        before = state[\chunks];
        older = startAnalysis.(engine, slot);
        waitFine.({ state[\chunks] >= (before + 2) });
        atSecond = state[\chunks];
        newer = startAnalysis.(engine, slot);
        waitFine.({ state[\chunks] >= (atSecond + 4) });
        pairs = allTempFilesOf.(engine, slot);
        newerArrivedThen = newer[\arrived].notNil;
        finishAnalysis.(older);
        finishAnalysis.(newer);
    } { state[\chunkWait] = nil };
    olderChunks = state[\chunks] - before - newerChunks;
    check.((older[\failed] == true) and: { newer[\failed] == false } and: { File.exists(onsetsFile.(engine, slot)) }
        and: { olderChunks <= ((atSecond - before) + 1) },
        "onsets: a second analyzeBuffer ends the first at its next chunk: two reports, the first failed (failed %, %; the first read % chunks, % when the second came; file %)".format(
            older[\failed], newer[\failed], olderChunks, atSecond - before, File.exists(onsetsFile.(engine, slot))));
    check.(newerArrivedThen.not and: { pairs.size == 2 } and: { pairs.every({ arg each; each.contains("-onsets" ++ newer[\count] ++ "-") }) }
        and: { allTempFilesOf.(engine, slot).isEmpty } and: { partFilesOf.(engine, slot).isEmpty },
        "onsets: one pair of temporary files at a time while a newer pass runs (%; left %, .part %)".format(
            pairs.collect({ arg each; each.basename }), allTempFilesOf.(engine, slot), partFilesOf.(engine, slot)));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// A pass that finds its slot changed after its rename was handed on deletes
// the renamed file only while it is the slot's newest analysis (#888), and
// a newer pass's rename waits for it (#963): with the mover stopped, an
// older pass hands its rename on, the slot changes, and a newer pass
// writes its .part and waits while the older's rename is under way
// (pathRenames); once the mover goes on, the older's rename ends (failed:
// the slot changed), then the newer's lands. The older pass reports failed
// and leaves the newer pass's file in place. The change is the slot's count
// alone (slotChanged, as a load of the same audio counts it): a load's own
// peaks rename would wait in the stopped mover.
var checkOlderRename = {
    var slot = 6, path = scratchRoot +/+ "onsets-older-rename.wav", frames = (0.5 * rate).asInteger;
    var mover = engine.areaState[\waveform][\mover], older, newer, pid, handedOlder = false, newerWaits = false, fields, stopped = false;
    writeClickFile.(path, frames, [(0.25 * rate).asInteger], [0.5]);
    loadInto.(engine, slot, path);
    if (File.exists(onsetsFile.(engine, slot))) { File.delete(onsetsFile.(engine, slot)) };
    if (mover.notNil and: { mover[\alive] }) {
        waitFor.({ mover[\pending] == 0 });
        pid = mover[\pid];
        ("kill -STOP " ++ pid).systemCmd;
        stopped = true;
        protect {
            older = startAnalysis.(engine, slot);
            handedOlder = waitFine.({ mover[\pending] == 1 }, 0.5);
            engine.slotChanged(slot);
            newer = startAnalysis.(engine, slot);
            // both .part files there, the older's alone in the mover
            newerWaits = waitFine.({ partFilesOf.(engine, slot).size == 2 }, 0.5) and: { mover[\pending] == 1 };
        } { ("kill -CONT " ++ pid).systemCmd };
        finishAnalysis.(older);
        finishAnalysis.(newer);
        waitFor.({ mover[\pending] == 0 });
    };
    fields = readOnsets.(onsetsFile.(engine, slot));
    check.(stopped and: { handedOlder } and: { newerWaits } and: { older[\failed] == true } and: { newer[\failed] == false }
        and: { fields.notNil } and: { fields[\frames] == [frames.asString] } and: { partFilesOf.(engine, slot).isEmpty },
        "onsets: a pass that finds its slot changed after its rename was handed on leaves a newer pass's file, whose rename waits for it (mover held %, handed on %, the newer waiting %; failed %, %; file %)".format(
            stopped, handedOlder, newerWaits, older !? { older[\failed] }, newer !? { newer[\failed] }, fields.notNil));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// #963: an older pass's rename by subprocess can no longer land over a
// newer pass's file. With the mover stopped, an older pass hands its
// rename to the mover, renames of the check's own fill the rest of its
// backlog (peaksMoverBacklog), the slot's audio gains a second click on
// the server and its count changes, and a newer pass then finds the
// backlog full, so its rename would go by subprocess at once, while the
// older's goes by subprocess only past peaksMoverTimeout. The newer waits
// for the older's rename to end (pathRenames): the file in place once both
// have ended is the newer pass's, two onsets, never the older's one
var checkRenameOrder = {
    var slot = 7, path = scratchRoot +/+ "onsets-order.wav", frames = (0.5 * rate).asInteger;
    var clicks = [(0.1 * rate).asInteger, (0.4 * rate).asInteger];
    var mover = engine.areaState[\waveform][\mover], older, newer, pid, fills = [], fields, stopped = false, handedOlder = false, full = false;
    writeClickFile.(path, frames, [clicks[0]], [0.5]);
    loadInto.(engine, slot, path);
    if (File.exists(onsetsFile.(engine, slot))) { File.delete(onsetsFile.(engine, slot)) };
    if (mover.notNil and: { mover[\alive] }) {
        waitFor.({ mover[\pending] == 0 });
        pid = mover[\pid];
        ("kill -STOP " ++ pid).systemCmd;
        stopped = true;
        protect {
            older = startAnalysis.(engine, slot);
            handedOlder = waitFine.({ mover[\pending] == 1 }, 0.5);
            fills = (1 .. (engine.peaksMoverBacklog - 1)).collect({ arg n;
                var target = scratchRoot +/+ ("onsets-fill-" ++ n), part = target ++ ".part";
                File.use(part, "w", { arg file; file.write("fill") });
                engine.renameIntoPlace(part, target, {});
                target
            });
            full = mover[\pending] == engine.peaksMoverBacklog;
            [engine.buffersL[slot], engine.buffersR[slot]].do({ arg buffer; buffer.set(clicks[1], 0.9) });
            server.sync;
            engine.slotChanged(slot);
            newer = startAnalysis.(engine, slot);
            finishAnalysis.(older);
            finishAnalysis.(newer);
        } { ("kill -CONT " ++ pid).systemCmd };
        waitFor.({ mover[\pending] == 0 });
    };
    fields = readOnsets.(onsetsFile.(engine, slot));
    check.(stopped and: { handedOlder } and: { full } and: { older[\failed] == true } and: { newer[\failed] == false }
        and: { onsetFrames.(fields) == clicks.collect({ arg click; click div: hop * hop }) } and: { partFilesOf.(engine, slot).isEmpty },
        "onsets: the newer pass's file stays in place over an older pass's rename by subprocess (#963; mover held %, handed on %, backlog full %; failed %, %; onsets %)".format(
            stopped, handedOlder, full, older !? { older[\failed] }, newer !? { newer[\failed] }, onsetFrames.(fields)));
    fills.do({ arg each; if (File.exists(each)) { File.delete(each) } });
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

// ... and a slot whose take is ending (#966): a playable recording over the
// audio, its record synth freed and its peaks file held by the stopped
// mover (the slot holds audio and no record synth, so only takeEnding tells
// it), is refused as a recording slot is, at once
var checkRefusedEnding = {
    var slot = 4, path = scratchRoot +/+ "onsets-ending.wav", mover = engine.areaState[\waveform][\mover];
    var count, run, ending = false, atOnce = false, stopped = false;
    h.writeTestFile(path, rate, rate, [0.25, 0.25]);
    loadInto.(engine, slot, path);
    if (mover.notNil and: { mover[\alive] }) {
        waitFor.({ mover[\pending] == 0 });
        ("kill -STOP " ++ mover[\pid]).systemCmd;
        stopped = true;
        protect {
            command.(\recordBuffer, slot, 0.05, 1.0, 0.5, 0, 0, 0, 0);
            ending = waitFine.({ engine.takeEnding(slot) }, 2);
            count = analysesOf.(engine)[slot] + 1;
            run = startAnalysis.(engine, slot);
            atOnce = poll.value == engine.bufferOnsetsValue(slot, count, true);
        } { ("kill -CONT " ++ mover[\pid]).systemCmd };
        finishAnalysis.(run);
        h.awaitTake(slot);
    };
    check.(stopped and: { ending } and: { run[\failed] == true } and: { atOnce } and: { tempFilesOf.(engine, slot, count).isEmpty },
        "onsets: a slot whose take is ending is refused with a failed report (#966; mover held %, ending %, failed %, at once %)".format(
            stopped, ending, run !? { run[\failed] }, atOnce));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
};

// A 16 s pass on the standard tier, timed; then a 300 s pass on a high
// engine: a message sent every 10 ms while it runs is each handled within
// one of the pass's chunks of its send (an OSC message waits for the
// language lock, which the pass holds for one chunk at most), counted with
// the area's chunks, not timed, so a loaded machine cannot fail it (#964);
// and it keeps the 63 of a click every 1000 frames. The messages go from
// the check's routine, which runs during the pass only when the pass
// yields: some must be sent between the pass's first chunk and its last
// (a pass that never yields would let none be sent then, each sent before
// or after it handled at once)
var checkLong = {
    var period = [0.9] ++ Array.fill(999, 0), write, standardRun, longRun, highEngine, slot = 0;
    var shortPath = scratchRoot +/+ "onsets-16.wav", longPath = highRoot +/+ "onsets-300.wav";
    var capacity = 20000, sentAt = Array.newClear(capacity), latency = Signal.newClear(capacity), sent = 0, heard = 0, ping;
    var sentChunk = Array.newClear(capacity), heardChunks = Array.newClear(capacity), chunksOf, firstChunk, lastChunk, during, late;
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
        chunksOf = { highEngine.areaState[\onsets][\chunks] };
        ping = OSCFunc({ arg msg;
            var number = msg[1].asInteger;
            if ((number >= 0) and: { number < sent } and: { heardChunks[number].isNil }) {
                latency[number] = Main.elapsedTime - sentAt[number];
                heardChunks[number] = chunksOf.value - sentChunk[number];
                heard = heard + 1;
            };
        }, '/strataCheckOnsetsPing');
        firstChunk = chunksOf.value;
        longRun = startAnalysis.(highEngine, slot);
        while { longRun[\arrived].isNil and: { sent < capacity } and: { (Main.elapsedTime - longRun[\start]) < 120 } } {
            sentAt[sent] = Main.elapsedTime;
            sentChunk[sent] = chunksOf.value;
            sent = sent + 1;
            NetAddr.localAddr.sendMsg('/strataCheckOnsetsPing', sent - 1);
            0.01.wait;
        };
        finishAnalysis.(longRun, 1);
        lastChunk = chunksOf.value;
        0.1.wait;
        ping.free;
        // sent after the pass's first chunk and before its last
        during = sentChunk.copyRange(0, (sent - 1).max(0)).count({ arg each; each.notNil and: { each > firstChunk } and: { each < lastChunk } });
        late = heardChunks.copyRange(0, (sent - 1).max(0)).count({ arg each; each.isNil or: { each > 1 } });
        check.((longRun[\failed] == false) and: { heard == sent } and: { sent > 10 } and: { late == 0 } and: { during > 0 }
            and: { onsetFrames.(readOnsets.(onsetsFile.(highEngine, slot))).size == engine.onsetCandidates },
            "onsets: a 300 s slot's pass yields to commands, each message handled within a chunk of its send (#964; % s, % chunks; % messages, % sent during the chunks, % heard, % after more than one chunk, the most chunks %; the slowest handled in % ms)".format(
                longRun[\seconds] !? { arg each; each.round(0.01) }, lastChunk - firstChunk, sent, during, heard, late,
                heardChunks.copyRange(0, (sent - 1).max(0)).select(_.notNil).maxItem,
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
        checkTexture.value;
        checkEnergies.value;
        checkInterrupted.value;
        checkSuperseded.value;
        checkOlderRename.value;
        checkRenameOrder.value;
        checkRefused.value;
        checkRefusedEnding.value;
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
