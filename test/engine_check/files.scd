// test/engine_check/files.scd
// Files: the scratch directory, decoding a file before it loads
// (fileDecodes), saveBuffer (stereo 16-bit WAV, clipping, back-to-back
// writes to one path, a full 16 s take, a write that fails), stale .part
// and temporary float files, which directories deleteStaleParts cleans, and
// a 60 s save on a high engine of its own (commands still get in meanwhile).
// Every save that ends is reported once on the bufferSaveResult poll (#127).
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var waitFor = { arg condition, timeout = 3; h.waitFor(condition, timeout) };
var synthNames = { arg group; h.synthNames(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var bufferSample = { arg buffer, frame; h.bufferSample(buffer, frame) };
var pollMessages = h.pollMessages, scratchRoot = h.tempDir;
var stereoPath = h.stereoPath, longPath = h.longPath, textPath = h.textPath;
var before, savePath, file, frames, data, info, longWritePath, writeStart, writeSeconds, rampValue, rampPeriod, reports;

// bufferSaveResult reports received so far, each decoded as [slot index,
// the slot's save number, failed]: value = (save * 2 + failed) * numBuffers + slot index
var saveResults = {
    h.pollValues(\bufferSaveResult).collect({ arg value;
        var slots = engine.numBuffers, rest = value.asInteger div: slots;
        [value.asInteger % slots, rest div: 2, (rest % 2) == 1]
    })
};
// the reports after the first `count`
var saveReportsAfter = { arg count; saveResults.value.copyToEnd(count) };
// the saveBuffer commands slot `index` has received (nil before #127)
var savesSent = { arg index; engine.tryPerform(\bufferSaves) !? { arg saves; saves[index] } };

// The engine's temporary float files (strata-buf*) in the shared system
// temp dir. Checks compare sets taken before and after their own writes, so
// files a killed earlier run left behind never count.
var tempFloatFiles = {
    PathName(Platform.defaultTempDir).files.select({ arg each; each.fileName.beginsWith("strata-buf") })
        .collect(_.fullPath).asSet
};

// A take recorded above level 1 holds samples beyond ±1 (the buffers are
// float; a float file loads them too): saving clips them symmetrically to
// the int16 range and never wraps
var checkLoudSave = {
    var loudPath = scratchRoot +/+ "loud.wav", savePath, file, data;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("float").numChannels_(2).sampleRate_(server.sampleRate);
    file.openWrite(loudPath);
    file.writeData(h.repeating(2 * 1000, [1.5, -1.7]));
    file.close;
    command.(\loadBuffer, 6, loudPath, 0); 0.5.wait; server.sync;
    check.(((bufferSample.(engine.buffersL[6], 10) - 1.5).abs < 0.001)
        and: { (bufferSample.(engine.buffersR[6], 10) + 1.7).abs < 0.001 }, "a slot holds samples beyond ±1 unclipped");
    savePath = scratchRoot +/+ "saved/loud.wav";
    command.(\saveBuffer, 6, savePath, 0, 1);
    check.(waitFor.({ File.exists(savePath) }), "a slot beyond ±1 is saved");
    0.5.wait;
    file = SoundFile.openRead(savePath);
    if (file.notNil) {
        data = FloatArray.newClear(2 * 1000);
        file.readData(data);
        file.close;
        check.(data.size == 2000 and: { data[0] > 0.999 } and: { (0..999).every({ arg frame;
                (data[frame * 2] == data[0]) and: { data[(frame * 2) + 1] == data[0].neg } }) },
            "saving clips beyond ±1 symmetrically to the int16 range, never wraps (read back % / %)".format(
                data[0], data[1]));
    } {
        check.(false, "the saved loud file can be read");
    };
    command.(\clearBuffer, 6); server.sync;
};

// writeSlot's temporary float files a crash left in the system temp dir
// (strata-buf<n>-<tag>-<n>-<side>.wav) are deleted like stale .part files:
// only those older than stalePartAge, and no other file (#47). A .part file
// whose age cannot be read (its directory cannot be searched, so File.mtime
// fails while the file is still there) is left, posted and returned.
var checkStaleTempFiles = {
    var tag = "check" ++ Date.getDate.stamp, unreadable, result, readable, savedDir = engine.scratchDir, lines = List.new;
    var names = ["strata-buf3-%-1-L.wav", "strata-buf3-%-2-R.wav", "strata-buf%.wav"].collect({ arg name;
        Platform.defaultTempDir +/+ name.format(tag) });
    names.do({ arg path; File.use(path, "w", { arg text; text.write("float") }) });
    ("touch -t 202001010000 " ++ names[0].shellQuote ++ " " ++ names[2].shellQuote).systemCmd;  // a crash long ago
    engine.tryPerform(\deleteStaleParts);
    check.(File.exists(names[0]).not and: { File.exists(names[1]) } and: { File.exists(names[2]) },
        "deleteStaleParts deletes old temporary float files and keeps fresh ones and other files (left: %)".format(
            names.select({ arg path; File.exists(path) }).collect({ arg path; path.basename })));
    names.do({ arg path; File.delete(path) });
    unreadable = scratchRoot +/+ "unsearchable/";
    File.mkdir(unreadable);
    File.use(unreadable +/+ "buf4.wav.9.part", "w", { arg text; text.write("stale") });
    ("chmod 644 " ++ unreadable.shellQuote).systemCmd;
    readable = try { File.mtime(unreadable +/+ "buf4.wav.9.part"); true } { false };
    engine.scratchDir = unreadable;
    engine.postStaleFileLine = { arg line; lines.add(line) };
    result = engine.tryPerform(\deleteStaleParts);
    engine.postStaleFileLine = nil;
    engine.scratchDir = savedDir;
    ("chmod 755 " ++ unreadable.shellQuote).systemCmd;
    if (readable) {
        check.(true, "(skipped: a directory without search permission is still searchable here, as root)");
    } {
        check.(result.isKindOf(Array) and: { result.includesEqual(unreadable +/+ "buf4.wav.9.part") }
            and: { File.exists(unreadable +/+ "buf4.wav.9.part") },
            "deleteStaleParts leaves, posts and returns a .part file whose age it cannot read (got %)".format(result));
        check.(lines.asArray == [("strata: cannot read when " ++ unreadable ++ "buf4.wav.9.part was last written; left in place")],
            "and posts one line naming it (got %)".format(lines));
    };
    File.delete(unreadable +/+ "buf4.wav.9.part");
};

// .part files a crash left in scratchDir (scratch takes) and its parent
// (saveBuffer's dated files) are deleted at alloc. alloc runs before the
// check can point scratchDir away from ~/dust, so the deletion is checked
// through deleteStaleParts (the check routine checks alloc calls it). Only
// .part files older than stalePartAge go: a fresh one may be a write still
// running in another engine instance (a script reload in the same sclang
// session runs alloc while the old engine writes).
var checkStaleParts = {
    var info, data, savePath, file, count;
    info = [engine.scratchDir, engine.scratchDir.withoutTrailingSlash.dirname];
    info.do({ arg dir;
        File.mkdir(dir);
        File.use(dir +/+ "buf2.wav.17.part", "w", { arg text; text.write("stale") });
        ("touch -t 202001010000 " ++ (dir +/+ "buf2.wav.17.part").shellQuote).systemCmd;  // a crash long ago
        File.use(dir +/+ "buf3.wav.5.part", "w", { arg text; text.write("running") });
        File.use(dir +/+ "keep.txt", "w", { arg text; text.write("keep") });
    });
    engine.tryPerform(\deleteStaleParts);
    check.(info.every({ arg dir; File.exists(dir +/+ "buf2.wav.17.part").not and: { File.exists(dir +/+ "keep.txt") } }),
        "deleteStaleParts deletes old .part files in scratchDir and its parent, and nothing else");
    check.(info.every({ arg dir; File.exists(dir +/+ "buf3.wav.5.part") }),
        "deleteStaleParts keeps a fresh .part file (a write that may still be running)");
    check.(engine.respondsTo(\stalePartAge) and: { engine.stalePartAge >= 60 },
        "stalePartAge is at least a minute (%)".format(engine.tryPerform(\stalePartAge)));
    info.do({ arg dir; ["keep.txt", "buf2.wav.17.part", "buf3.wav.5.part"].do({ arg name; File.delete(dir +/+ name) }) });
    checkStaleTempFiles.value;
    // A write still interleaving survives deleteStaleParts, and its .part
    // name carries this engine instance's tag, so two instances' writes
    // to one path never share a .part file
    engine.writeChunkWait = 0.02;          // the 16 s interleave now takes about 2 s
    savePath = engine.scratchDir +/+ "running.wav";
    count = saveResults.value.size;
    command.(\saveBuffer, 7, savePath, 0, 1);
    0.5.wait;
    data = PathName(engine.scratchDir).files.collect(_.fileName).select({ arg name; name.endsWith(".part") });
    check.(engine.respondsTo(\instanceTag) and: { data.size == 1 }
        and: { data[0].beginsWith("running.wav." ++ engine.instanceTag ++ "-") },
        "a .part name carries the engine instance's tag (got %)".format(data));
    engine.tryPerform(\deleteStaleParts);
    check.(waitFor.({ File.exists(savePath) }, 10), "a write in progress survives deleteStaleParts");
    // its report arrives a moment after the rename: wait, so no later window counts it
    waitFor.({ saveReportsAfter.(count).notEmpty });
    engine.writeChunkWait = 0.001;
    file = SoundFile.openRead(savePath);
    check.(file.notNil and: { file.numFrames == engine.bufferFrames[7] }, "and holds every frame");
    file !? { file.close };
    File.delete(savePath);
};

// fileDecodes accepts a header count up to loadShortfallFrames more than
// the frames that decode (asking a good file for more frames than it has
// stands in for such a header), and rejects anything beyond
var checkDecodeShortfall = { arg stereoPath, longPath;
    var decodes = { arg path, frames;
        var file = SoundFile.openRead(path), result = engine.fileDecodes(file, frames);
        file.close;
        result
    };
    check.(decodes.(stereoPath, 11025) and: { decodes.(longPath, 22050 * 16) },
        "fileDecodes accepts files that decode in full (one chunk and many)");
    check.(decodes.(stereoPath, 11025 + engine.loadShortfallFrames)
        and: { decodes.(stereoPath, 11025 + engine.loadShortfallFrames + 1).not },
        "fileDecodes tolerates a shortfall of loadShortfallFrames (%) and no more".format(engine.loadShortfallFrames));
};
// A 60 s slot on a high engine of its own (h.startEngine with a high
// setting of 60 s, a Pi 4 model and plenty of memory) saves 60 s of stereo
// 16-bit, every frame in place, and posts the time it took. Its chunk wait
// is set shorter than a chunk takes, so the interleave falls behind its
// clock: a message sent while it runs must still be handled before it ends.
var checkLongSave = {
    var root = scratchRoot +/+ "long-save", rate = server.sampleRate.asInteger, frames = 60 * rate;
    var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    var ramp = { arg frame; ((frame % 1000) / 1000 - 0.5) * 0.8 };
    var other, sourcePath = root +/+ "ramp.wav", savePath = root +/+ "saved/ramp.wav", file, data, start, seconds;
    var heard, ping, parts, partSeen, period = (0 .. 999).collect(ramp);
    File.mkdir(root);
    write.(root +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
    write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    // left the ramp, right its negative, a second at a time
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    file.openWrite(sourcePath);
    h.writePeriodicSeconds(file, period, 60, rate);
    file.close;
    other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
    h.commandTo(other, \loadBuffer, 0, sourcePath, 0);
    check.(other.bufferSeconds == 60 and: { waitFor.({ other.bufferFrames[0] == frames }, 10) },
        "files: a 60 s file fills a high engine's 60 s slot (% frames)".format(other.bufferFrames[0]));
    // the ping goes out once the interleave has opened its .part file, and
    // its handler notes whether the save was still running (the .part there,
    // the file not yet in place)
    parts = { (savePath ++ ".*.part").pathMatch };
    ping = OSCFunc({ heard = parts.value.notEmpty and: { File.exists(savePath).not } }, '/strataCheckSavePing');
    other.writeChunkWait = 0.0001;
    reports = saveResults.value.size;
    start = Main.elapsedTime;
    h.commandTo(other, \saveBuffer, 0, savePath, 0, 1);
    while { parts.value.isEmpty and: { File.exists(savePath).not } and: { (Main.elapsedTime - start) < 30 } } { 0.001.wait };
    partSeen = parts.value.notEmpty;
    NetAddr.localAddr.sendMsg('/strataCheckSavePing');
    waitFor.({ File.exists(savePath) }, 120);
    seconds = Main.elapsedTime - start;
    0.2.wait;
    ping.free;
    check.(saveReportsAfter.(reports) == [[0, 1, false]],
        "files: a 60 s save is reported written once it is in place (got %)".format(saveReportsAfter.(reports)));
    check.(partSeen and: { heard == true },
        "files: a message sent while a long save interleaves is handled before it ends (.part seen %, heard during it %)".format(
            partSeen, heard));
    file = SoundFile.openRead(savePath);
    // every frame equals the source's, read in chunks (never one 23 MB array)
    data = if (file.notNil) { h.sameFrames(file, sourcePath) } { [1, 0] };
    file !? { file.close };
    check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == frames } and: { file.sampleFormat == "int16" }
        and: { file.sampleRate == rate } and: { data[0] == 0 } and: { data[1] == frames },
        "files: a 60 s save writes 60 s of stereo 16-bit, every frame in place (% frames in % s; largest error %)".format(
            file !? _.numFrames, seconds.round(0.01), data[0]));
    h.freeEngine(other);
    File.delete(sourcePath); File.delete(savePath);
};
// A short temporary file (the server's write ran out of disk) fails the
// save: simulated by asking for more frames than the slot's buffers hold,
// which the server's /b_write clips to the buffer's end. The file already
// at the path is kept, no .part is left, and the newest write's entry goes.
var checkShortWrite = { arg stereoPath;
    var dir = scratchRoot +/+ "short-write", savePath = dir +/+ "kept.wav", file, kept, count;
    File.mkdir(dir);
    File.copy(stereoPath, savePath);
    command.(\loadBuffer, 6, stereoPath, 0); 0.5.wait; server.sync;
    engine.bufferFrames[6] = engine.buffersL[6].numFrames + 100;
    count = saveResults.value.size;
    command.(\saveBuffer, 6, savePath, 0, 1);
    3.0.wait;
    check.(saveReportsAfter.(count) == [[6, savesSent.(6), true]],
        "files: a save whose temporary file is short is reported failed (got %)".format(saveReportsAfter.(count)));
    engine.bufferFrames[6] = 11025;
    file = SoundFile.openRead(savePath);
    kept = file.notNil and: { file.numFrames == 11025 } and: { file.sampleRate == 22050 };
    file !? { file.close };
    check.(kept and: { PathName(dir).files.collect(_.fileName) == ["kept.wav"] }
        and: { engine.writeGenerations[savePath.standardizePath].isNil },
        "files: a save whose temporary file is short keeps the old file and leaves no .part (left: %)".format(
            PathName(dir).files.collect(_.fileName)));
    command.(\clearBuffer, 6); server.sync;
    File.delete(savePath);
};
// An sclang error inside a write's routine (injected through
// interleaveFaultHook, which interleaveFiles calls with the output path, a
// stage and the sound files it has open: \start before it opens any, \open
// once the temporary files and the output are open) still ends the save: one
// failed report, its writeGenerations entry gone, no temporary float or .part
// file left, and every sound file it had opened closed. Slot 5 (index 4)
// holds the stereo file.
var checkWriteFault = { arg stage;
    var dir = scratchRoot +/+ "fault-" ++ stage, savePath = dir +/+ "broken.wav", count, temps = tempFloatFiles.value;
    var left, seen;
    File.mkdir(dir);
    count = saveResults.value.size;
    engine.tryPerform(\interleaveFaultHook_, { arg path, at, openFiles;
        if (at == stage) { seen = openFiles.copy; Error("injected write fault").throw };
    });
    command.(\saveBuffer, 4, savePath, 0, 1);
    1.0.wait;
    engine.tryPerform(\interleaveFaultHook_, nil);
    left = (tempFloatFiles.value - temps).asArray ++ PathName(dir).files.collect(_.fileName);
    check.(saveReportsAfter.(count) == [[4, savesSent.(4), true]],
        "files: a save whose routine throws (%) is reported failed, once (got %)".format(stage, saveReportsAfter.(count)));
    check.(engine.writeGenerations[savePath.standardizePath].isNil and: { left.isEmpty },
        "files: and leaves no writeGenerations entry, temporary or .part file (%; left: %)".format(stage, left));
    check.(seen.notNil and: { seen.size == (if (stage == \open) { 3 } { 0 }) } and: { seen.every({ arg file; file.isOpen.not }) },
        "files: and closes every sound file it had opened (%: % opened, open now: %)".format(
            stage, seen !? _.size, seen !? { seen.count(_.isOpen) }));
};
// A save onto a folder (mv -f would move the file into it) fails: one
// failed report, the folder and its contents unchanged, no .part beside it
var checkSaveOntoFolder = {
    var dir = scratchRoot +/+ "onto-folder", savePath = dir +/+ "taken.wav", count, inside, beside;
    File.mkdir(savePath);
    File.use(savePath +/+ "inside.txt", "w", { arg text; text.write("keep") });
    count = saveResults.value.size;
    command.(\saveBuffer, 4, savePath, 0, 1);
    1.0.wait;
    inside = PathName(savePath).files.collect(_.fileName);
    beside = PathName(dir).files.collect(_.fileName);
    check.(saveReportsAfter.(count) == [[4, savesSent.(4), true]],
        "files: a save onto a folder is reported failed (got %)".format(saveReportsAfter.(count)));
    check.(PathName(savePath).isFolder and: { inside == ["inside.txt"] } and: { beside.isEmpty }
        and: { engine.writeGenerations[savePath.standardizePath].isNil },
        "files: and leaves the folder as it was, with no .part beside it (inside %, beside %)".format(inside, beside));
    File.delete(savePath +/+ "inside.txt"); File.delete(savePath);
};
var tempFilesBefore = tempFloatFiles.value;

check.(engine.tryPerform(\bufferSaveResultValue, 3, 2, true) == (((2 * 2) + 1) * engine.numBuffers + 3).asFloat
    and: { engine.tryPerform(\bufferSaveResultValue, 0, 1, false) == (2 * engine.numBuffers).asFloat },
    "bufferSaveResultValue is (save * 2 + failed) * numBuffers + slot index, a float");

check.(h.defaultScratchDir == (Platform.userHomeDir +/+ "dust/audio/strata/scratch/"),
    "scratch takes default to ~/dust/audio/strata/scratch/");
checkDecodeShortfall.(stereoPath, longPath);

// Slot 5 (index 4) holds the stereo file the saves below write
before = synthNames.(context.xg).size;
command.(\loadBuffer, 4, stereoPath, 0); 0.5.wait; server.sync;

// saveBuffer writes the valid region as a stereo 16-bit WAV
savePath = scratchRoot +/+ "saved/take-buf5.wav";
info = savesSent.(4); reports = saveResults.value.size;
command.(\saveBuffer, 4, savePath, 0, 1);
check.(waitFor.({ File.exists(savePath) }), "saveBuffer writes the file (creating its directory)");
1.0.wait;
check.(info.notNil and: { savesSent.(4) == (info + 1) }, "saveBuffer counts the slot's saves (% then %)".format(info, savesSent.(4)));
check.(saveReportsAfter.(reports) == [[4, savesSent.(4), false]],
    "a save that writes its file is reported once, written, with its slot and save number (got %)".format(
        saveReportsAfter.(reports)));
file = SoundFile.openRead(savePath);
check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == 11025 }
    and: { file.sampleRate == 22050 } and: { file.sampleFormat == "int16" },
    "the saved file is stereo 16-bit at the content's rate, valid frames only");
if (file.notNil) {
    data = FloatArray.newClear(2 * 200);
    file.readData(data);
    file.close;
    check.(((data[200] - 0.5).abs < 0.001) and: { (data[201] + 0.25).abs < 0.001 },
        "the saved file interleaves left and right");
};
checkLoudSave.value;
// Two writes to one path back to back: the newer one wins, the file is never mixed
command.(\loadBuffer, 7, longPath, 0); 0.5.wait; server.sync;     // 16 s at 22050 Hz: a long interleave
savePath = scratchRoot +/+ "race/same.wav";
engine.writeChunkWait = 0.02;          // the long interleave now takes about 0.9 s
reports = saveResults.value.size;
command.(\saveBuffer, 7, savePath, 0, 1);
0.3.wait;                              // the first interleave is under way
command.(\saveBuffer, 4, savePath, 0, 1);                              // 11025 frames, 0.5 / -0.25
check.(waitFor.({ File.exists(savePath) }, 5), "back-to-back writes to one path produce the file");
2.0.wait;
check.(saveReportsAfter.(reports) == [[4, savesSent.(4), false]],
    "of two writes to one path only the newer is reported, written; the abandoned one reports nothing (got %)".format(
        saveReportsAfter.(reports)));
file = SoundFile.openRead(savePath);
check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == 11025 } and: { file.sampleRate == 22050 },
    "an older write to the same path abandons: the file is the second write (got % frames)".format(file !? _.numFrames));
if (file.notNil) {
    data = FloatArray.newClear(2 * 11025);
    file.readData(data);
    file.close;
    check.(data.size == (2 * 11025) and: { (0..11024).every({ arg frame;
            ((data[frame * 2] - 0.5).abs < 0.001) and: { (data[(frame * 2) + 1] + 0.25).abs < 0.001 } }) },
        "the surviving file holds exactly the second write's samples");
};
// the other order: a short write then a long one; the long (newer) one wins
reports = saveResults.value.size;
command.(\saveBuffer, 4, savePath, 0, 1);
command.(\saveBuffer, 7, savePath, 0, 1);
3.0.wait;
check.(saveReportsAfter.(reports) == [[7, savesSent.(7), false]],
    "the newer long write is the one reported (got %)".format(saveReportsAfter.(reports)));
engine.writeChunkWait = 0.001;
file = SoundFile.openRead(savePath);
check.(file.notNil and: { file.numFrames == (22050 * 16) }, "a newer long write replaces an older short one");
file !? { file.close };
check.(PathName(savePath.dirname).files.collect(_.fileName) == [PathName(savePath).fileName],
    "no .part files are left beside the written file (got %)".format(PathName(savePath.dirname).files.collect(_.fileName)));
info = tempFloatFiles.value - tempFilesBefore;
check.(info.isEmpty, "no temporary float files are left behind (new: %)".format(info.asArray));

// A 16 s take at the server rate: the interleave finishes, every
// sample is in place (left ramp, right its negative) and the time is reported
rampValue = { arg frame; ((frame % 1000) / 1000 - 0.5) * 0.8 };
rampPeriod = (0 .. 999).collect(rampValue);
longWritePath = scratchRoot +/+ "long-server-rate.wav";
frames = (server.sampleRate * 16).asInteger;
file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(server.sampleRate);
file.openWrite(longWritePath);
h.writePeriodicSeconds(file, rampPeriod, 16, server.sampleRate.asInteger);
file.close;
info = pollMessages.size;   // slot 8 reported 7016 before (16 s at 22.05 kHz): only later reports count
command.(\loadBuffer, 7, longWritePath, 0); 1.0.wait; server.sync;
check.(engine.bufferFrames[7] == frames, "a 16 s file at the server rate fills slot 8");
check.(waitFor.({ pollMessages.copyToEnd(info).any({ arg msg; msg[2] == 7016 }) }),
    "slot 8 holding 16 s reports 7016 through bufferState");
savePath = scratchRoot +/+ "long/saved.wav";
reports = saveResults.value.size;
writeStart = Main.elapsedTime;
command.(\saveBuffer, 7, savePath, 0, 1);
info = waitFor.({ File.exists(savePath) }, 30);
writeSeconds = Main.elapsedTime - writeStart;
check.(info, "a 16 s write completes (% frames at % Hz in % s)".format(frames, server.sampleRate, writeSeconds.round(0.01)));
// its report is sent just after the rename and arrives as an OSC message a
// moment later: wait for it, so it never lands in a later check's window
check.(waitFor.({ saveReportsAfter.(reports).notEmpty }) and: { saveReportsAfter.(reports) == [[7, savesSent.(7), false]] },
    "the 16 s write is reported written (got %)".format(saveReportsAfter.(reports)));
file = SoundFile.openRead(savePath);
check.(file.notNil and: { file.numChannels == 2 } and: { file.numFrames == frames }, "the 16 s file holds every frame");
if (file.notNil) {
    data = h.sameFrames(file, longWritePath);
    file.close;
    check.((data[0] == 0) and: { data[1] == frames },
        "the 16 s file interleaves every frame in place, equal to the loaded file (chunk boundaries included; largest error %, % frames)".format(
            data[0], data[1]));
};
File.delete(longWritePath);

// A write that fails (its directory cannot be made: the parent is a
// file) forgets its generation and leaves no temporary files
savePath = textPath +/+ "sub/cannot.wav";
tempFilesBefore = tempFloatFiles.value;
reports = saveResults.value.size;
command.(\saveBuffer, 4, savePath, 0, 1); 1.0.wait;
check.(saveReportsAfter.(reports) == [[4, savesSent.(4), true]],
    "a save whose folder cannot be made is reported failed (got %)".format(saveReportsAfter.(reports)));
check.(engine.respondsTo(\writeGenerations) and: { engine.writeGenerations[savePath.standardizePath].isNil },
    "a failed newest write removes its writeGenerations entry");
info = tempFloatFiles.value - tempFilesBefore;
check.(info.isEmpty, "a failed write leaves no temporary float files (new: %)".format(info.asArray));
checkStaleParts.value;
// alloc runs every area's allocState: the files area's calls it
file = Engine_Strata.findMethod(\strataAreaFiles);
data = File.readAllString(file.filenameSymbol.asString);
data = data.copyRange(file.charPos, data.find("\n    }", offset: file.charPos) ? (data.size - 1));
check.(data.contains("this.deleteStaleParts"), "alloc calls deleteStaleParts");
// A scratchDir with no directory part has no parent to clean: the
// working directory's .part files are left alone
info = [engine.scratchDir, File.getcwd +/+ ("strata-engine-check-" ++ Date.getDate.stamp ++ ".part")];
File.use(info[1], "w", { arg text; text.write("not stale") });
engine.scratchDir = "strata-engine-check-relative/";
engine.tryPerform(\deleteStaleParts);
check.(File.exists(info[1]), "deleteStaleParts with a relative scratchDir leaves the working directory (%) alone".format(File.getcwd));
File.delete(info[1]);
engine.scratchDir = info[0];
// Only absolute directories below the root are cleaned: an empty,
// relative or root scratchDir never globs the working directory or /
savePath = engine.scratchDir;
info = [["", []], ["/", []], [".", []], ["./", []], ["x/", []], ["//", []],
    ["/a/", ["/a"]], ["/a/b/", ["/a/b", "/a"]]].reject({ arg pair;
    engine.scratchDir = pair[0];
    // the settings folder (the performance area's, absolute) always follows
    engine.tryPerform(\stalePartDirs) == (pair[1] ++ [engine.allocSettingsDirectory.withoutTrailingSlash])
});
check.(info.isEmpty, "deleteStaleParts cleans only absolute directories below / (wrong for %)".format(info));
engine.scratchDir = savePath;

reports = saveResults.value.size;
command.(\saveBuffer, 6, scratchRoot +/+ "empty.wav", 0, 1); 0.5.wait;
check.(File.exists(scratchRoot +/+ "empty.wav").not, "saving an empty slot writes nothing");
check.(saveReportsAfter.(reports) == [[6, savesSent.(6), true]],
    "and is reported failed (got %)".format(saveReportsAfter.(reports)));
// a slot out of range is ignored: nothing counted, nothing reported
info = (0 .. engine.numBuffers - 1).collect({ arg index; savesSent.(index) });
reports = saveResults.value.size;
command.(\saveBuffer, engine.numBuffers, scratchRoot +/+ "out-of-range.wav", 0, 1); 0.3.wait;
check.(saveReportsAfter.(reports).isEmpty and: { (0 .. engine.numBuffers - 1).collect({ arg index; savesSent.(index) }) == info },
    "a save of a slot out of range counts and reports nothing");
check.(synthNames.(context.xg).size == before, "saving adds no nodes");
checkShortWrite.(stereoPath);
checkWriteFault.(\start);
checkWriteFault.(\open);
checkSaveOntoFolder.value;
checkLongSave.value;

// saveBuffer with 0 and 1 writes what 3.2's saveBuffer wrote: the whole valid
// region, as a 16-bit stereo WAV equal to the int16 file it was loaded from
{
    var rate = server.sampleRate.asInteger, sourcePath = scratchRoot +/+ "files-region-source.wav";
    var path = scratchRoot +/+ "files-region-saved.wav", file, written, data;
    var period = Array.fill(1000, { arg i; sin(2pi * 3 * i / 1000) * 0.5 });
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    file.openWrite(sourcePath);
    h.writePeriodicSeconds(file, period, 2, rate);
    file.close;
    command.(\loadBuffer, 5, sourcePath, 0);
    h.waitFor({ engine.bufferFrames[5] == (rate * 2) });
    command.(\saveBuffer, 5, path, 0, 1);
    h.waitFor({ File.exists(path) }, 4);
    0.2.wait; server.sync;
    written = SoundFile.openRead(path);
    data = if (written.notNil) { var result = h.sameFrames(written, sourcePath); written.close; result } { [1, 0] };
    command.(\clearBuffer, 5); server.sync;
    check.((data[0] == 0) and: { data[1] == (rate * 2) },
        "files: saveBuffer with 0 and 1 writes what 3.2's saveBuffer wrote (difference %, % frames)".format(data[0], data[1]));
}.value;

// 3.3's region saves: a slot of four quarters of known levels
{
    var rate = server.sampleRate.asInteger, slot = 5, quarter = rate div: 4, frames = quarter * 4;
    var path = scratchRoot +/+ "files-quarters.wav", file;
    var regionPath = scratchRoot +/+ "files-quarter-region.wav", wholePath = scratchRoot +/+ "files-whole-region.wav", smallPath = scratchRoot +/+ "files-tiny-region.wav";
    var frameAt = { arg soundFile, frame;
        var data = FloatArray.newClear(2);
        soundFile.seek(frame, 0);
        soundFile.readData(data);
        data[0]
    };
    var save = { arg savePath, start, length;
        var reports = saveResults.value.size;
        command.(\saveBuffer, slot, savePath, start, length);
        waitFor.({ saveResults.value.size > reports }, 4);
        saveResults.value.last
    };
    var result, saved, count, first, last;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    file.openWrite(path);
    [0.1, 0.2, 0.3, 0.4].do({ arg level; h.writeConstantFrames(file, quarter, [level, level.neg]) });
    file.close;
    command.(\loadBuffer, slot, path, 0);
    h.waitFor({ engine.bufferFrames[slot] == frames });
    0.1.wait; server.sync;
    // [0.25, 0.75) of the valid region: the second and third quarters
    result = save.(regionPath, 0.25, 0.5);
    saved = SoundFile.openRead(regionPath);
    #count, first, last = if (saved.notNil) {
        var values = [saved.numFrames, frameAt.(saved, 0), frameAt.(saved, (quarter * 2) - 1)];
        saved.close;
        values
    } { [0, 0, 0] };
    check.((result[2] == false) and: { count == (quarter * 2) }
        and: { (first - 0.2).abs < 0.001 } and: { (last - 0.3).abs < 0.001 },
        "files: saveBuffer of a region writes those frames (% frames, first %, last %)".format(count, first, last));
    // 0, 1: the whole valid region
    result = save.(wholePath, 0, 1);
    saved = SoundFile.openRead(wholePath);
    count = saved !? { arg each; var value = each.numFrames; each.close; value } ? 0;
    check.((result[2] == false) and: { count == frames },
        "files: saveBuffer of 0, 1 writes the whole valid region (% of % frames)".format(count, frames));
    // less than one frame: nothing written, reported failed
    [[0.25, 0], [0.5, 0.25 / frames]].do({ arg region;
        result = save.(smallPath, region[0], region[1]);
        check.((result[2] == true) and: { File.exists(smallPath).not },
            "files: a region under one frame writes nothing and reports failed (start %, length %: failed %, file %)".format(
                region[0], region[1], result[2], File.exists(smallPath)));
    });
    command.(\clearBuffer, slot); server.sync;
    [path, regionPath, wholePath].do({ arg each; if (File.exists(each)) { File.delete(each) } });
}.value;

// #217: a save's .part used to be renamed with a blocking systemCmd, which
// on norns' glibc 2.28 forks sclang (about 2.5 ms per 130 MB of it) and
// waits for mv, so every save or scratch take held sclang that long. The
// rename now goes to the mover (renameIntoPlace, docs/notes/engine/waveform.md).
// A 1 ms SystemClock task looks for the saved file on every tick: the gap
// in which the file appears spans the rename, so the OS preempting sclang
// elsewhere in a save cannot fail it. Counted, not the largest: fewer than
// lateLimit late gaps of ten saves.
{
    var slot = 3, saves = 10, gapLimit = 0.003, lateLimit = 3, dir = scratchRoot +/+ "rename-hold";
    var gaps = List.new(saves), late, sorted;
    command.(\loadBuffer, slot, stereoPath, 0); 0.5.wait; server.sync;
    File.mkdir(dir);
    saves.do({ arg n;
        var path = dir +/+ "save%.wav".format(n), last = Main.elapsedTime, gap, ticker, count = saveResults.value.size;
        ticker = Routine({ loop {
            var now = Main.elapsedTime;
            if (gap.isNil and: { File.exists(path) }) { gap = now - last };
            last = now;
            0.001.wait
        } }).play(SystemClock);
        command.(\saveBuffer, slot, path, 0, 1);
        waitFor.({ saveReportsAfter.(count).notEmpty and: { gap.notNil } }, 3);
        ticker.stop;
        gaps.add(gap ? inf);
        if (File.exists(path)) { File.delete(path) };
    });
    late = gaps.count({ arg value; value >= gapLimit });
    sorted = gaps.copy.sort;
    check.((gaps.size == saves) and: { late < lateLimit },
        "files: a save's rename holds sclang under 3 ms, never a fork (% of % rename gaps of a 1 ms task over 3 ms; median % ms, longest % ms)".format(
            late, saves, (sorted[saves div: 2] * 1000).round(0.01), (sorted.last * 1000).round(0.01)));
    command.(\clearBuffer, slot); server.sync;
}.value;

// The mover serves saves too: on an engine of its own (h.engine keeps its
// mover), a save while the mover is stopped renames by subprocess after
// peaksMoverTimeout and reports once, also after the mover catches up; a
// save after the mover is killed renames by subprocess at once and reports
// once. writeSlot's done is called directly, counting its calls.
{
    var dir = scratchRoot +/+ "files-mover/", other, mover, path = dir +/+ "saved.wav", noBoard = scratchRoot +/+ "no-board-model";
    var save = { arg index, target, timeout = 3;
        var result = (calls: 0, written: nil, start: Main.elapsedTime);
        target.writeSlot(index, path, { arg written; result[\calls] = result[\calls] + 1; result[\written] = written; result[\took] = Main.elapsedTime - result[\start] });
        waitFor.({ result[\calls] > 0 }, timeout);
        result
    };
    var framesAt = { var file = SoundFile.openRead(path); file !? { var count = file.numFrames; file.close; count } };
    var ran;
    File.mkdir(dir);
    other = h.startEngine((settingsDir: dir, modelPath: noBoard));
    mover = other.areaState[\waveform][\mover];
    h.commandTo(other, \loadBuffer, 0, stereoPath, 0);
    waitFor.({ other.bufferFrames[0] == 11025 });
    0.2.wait; server.sync;
    ran = save.(0, other);
    check.((ran[\written] == true) and: { framesAt.value == 11025 } and: { mover[\pending] == 0 },
        "files: a save through the mover lands and reports once (% calls, % ms)".format(ran[\calls], ran[\took] !? { (ran[\took] * 1000).round(0.1) }));
    File.delete(path);
    ("kill -STOP " ++ mover[\pid]).systemCmd;
    ran = save.(0, other);
    check.((ran[\written] == true) and: { (ran[\took] ? 0) >= other.peaksMoverTimeout } and: { framesAt.value == 11025 } and: { mover[\pending] == 1 },
        "files: a save while the mover is stopped renames by subprocess after its timeout (% s, pending %)".format(ran[\took] !? { ran[\took].round(0.01) }, mover[\pending]));
    ("kill -CONT " ++ mover[\pid]).systemCmd;
    waitFor.({ mover[\pending] == 0 });
    0.2.wait;
    check.((ran[\calls] == 1) and: { mover[\pending] == 0 } and: { framesAt.value == 11025 } and: { (dir +/+ "*.part").pathMatch.isEmpty },
        "files: and reports once, also after the mover catches up (% calls, pending %, left %)".format(ran[\calls], mover[\pending], (dir +/+ "*.part").pathMatch));
    File.delete(path);
    ("kill -KILL " ++ mover[\pid]).systemCmd;
    waitFor.({ mover[\exited] == true });
    ran = save.(0, other);
    0.2.wait;
    check.((ran[\calls] == 1) and: { ran[\written] == true } and: { (ran[\took] ? inf) < other.peaksMoverTimeout } and: { framesAt.value == 11025 },
        "files: a save after the mover is killed renames by subprocess at once and reports once (% calls, % s)".format(ran[\calls], ran[\took] !? { ran[\took].round(0.01) }));
    h.freeEngine(other);
    if (File.exists(path)) { File.delete(path) };
}.value;

// Renames to one path land in write order whatever carries them: an older
// save's rename waiting in a stopped mover, then the mover's backlog
// filled by peaks writes, so a newer save to the same path cannot use the
// mover. The newer one waits for the older one's rename before its own
// (never a subprocess rename the stopped mover would later overwrite), so
// the newer file stays, and each save reports once, written.
{
    var dir = scratchRoot +/+ "files-mover-order/", other, mover, path = dir +/+ "same.wav", noBoard = scratchRoot +/+ "no-board-model";
    var older = (calls: 0), newer = (calls: 0), frames;
    var done = { arg result; { arg written; result[\calls] = result[\calls] + 1; result[\written] = written } };
    File.mkdir(dir);
    other = h.startEngine((settingsDir: dir, modelPath: noBoard));
    mover = other.areaState[\waveform][\mover];
    h.commandTo(other, \loadBuffer, 0, stereoPath, 0);
    h.commandTo(other, \loadBuffer, 1, h.monoPath, 0);
    waitFor.({ (other.bufferFrames[0] == 11025) and: { other.bufferFrames[1] == 4410 } });
    0.2.wait; server.sync;
    ("kill -STOP " ++ mover[\pid]).systemCmd;
    other.writeSlot(0, path, done.(older));
    waitFor.({ mover[\pending] == 1 });
    (other.peaksMoverBacklog - 1).do({ other.writeSlotPeaks(2, 100, nil) });
    other.writeSlot(1, path, done.(newer));
    0.5.wait;
    ("kill -CONT " ++ mover[\pid]).systemCmd;
    waitFor.({ (older[\calls] > 0) and: { newer[\calls] > 0 } and: { mover[\pending] == 0 } }, 4);
    0.3.wait;
    frames = SoundFile.openRead(path) !? { arg file; var count = file.numFrames; file.close; count };
    check.((frames == 4410) and: { older[\calls] == 1 } and: { newer[\calls] == 1 } and: { older[\written] == true } and: { newer[\written] == true }
        and: { (dir +/+ "*.part").pathMatch.isEmpty },
        "files: renames to one path land in write order, the newer save's file stays (% frames; reports % and %, left %)".format(
            frames, older[\calls], newer[\calls], (dir +/+ "*.part").pathMatch));
    h.freeEngine(other);
    if (File.exists(path)) { File.delete(path) };
}.value;
}
