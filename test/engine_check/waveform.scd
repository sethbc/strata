// test/engine_check/waveform.scd
// The waveform area: the peaks a load computes (fileDecodes), the peak
// buffers, the peaks files (format, where they land, written through a .part
// and in place before the length is reported), and a 300 s load and save
// back to back on a high engine (#131: on sclang 3.13 this is where array
// churn aborts sclang). No audio-length array is read back into sclang here.
{ arg h;
var engine = h.engine, server = h.server, scratchRoot = h.tempDir;
var rate = server.sampleRate.asInteger, points = engine.waveformPoints;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var waitFor = { arg condition, timeout = 3; h.waitFor(condition, timeout) };
var storedPeaks = { arg target, slot; target.areaState[\waveform][\peaks][slot] };

// A peaks file's lines as an Event of key -> the line's other words, or nil
var readPeaksFile = { arg path;
    var fields = ();
    if (File.exists(path).not) { nil } {
        File.readAllString(path).split($\n).do({ arg line;
            var words = line.split($ );
            if (words[0].size > 0) { fields[words[0].asSymbol] = words.drop(1) };
        });
        fields
    }
};

// A stereo 16-bit file: optionally `prefix` frames of loudValues, then one
// constant chunk of binFrames per bin (valuesFor.(bin): one value per channel)
var writePerBinFile = { arg path, sampleRate, binFrames, valuesFor, prefix = 0, loudValues = #[0.95, -0.95], format = "WAV";
    var file = SoundFile.new.headerFormat_(format).sampleFormat_("int16").numChannels_(2).sampleRate_(sampleRate);
    file.openWrite(path);
    if (prefix > 0) { h.writeConstantFrames(file, prefix, loudValues) };
    points.do({ arg bin; h.writeConstantFrames(file, binFrames, valuesFor.(bin)) });
    file.close;
};

// Each bin's level, largest in the left channel on even bins and in the
// right, negative, on odd ones (so the peak is an absolute value)
var binLevel = { arg bin; ((bin + 1) / points * 0.8) + 0.05 };
var binValues = { arg bin;
    var level = binLevel.(bin);
    if (bin.even) { [level, level.neg * 0.5] } { [level * 0.5, level.neg] }
};

// The largest difference between a slot's stored peaks and binLevel
var peaksError = { arg target, slot;
    var peaks = storedPeaks.(target, slot), largest = 0;
    points.do({ arg bin; largest = largest.max((peaks[bin] - binLevel.(bin)).abs) });
    largest
};

// A peak buffer's 64 values (one /b_getn), as sclang reads them
var peakBufferValues = { arg target, slot;
    var done = Condition(false), values;
    target.slotPeakBuffer(slot).getn(0, points, { arg array; values = array; done.test = true; done.signal });
    h.awaitReply(done);
    values
};

var highRoot = scratchRoot +/+ "waveform-high", highEngine;
var startHighEngine = {
    var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
    File.mkdir(highRoot);
    write.(highRoot +/+ "performance.data", "performance high\nbuffer_seconds 300\n");
    write.(highRoot +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
    write.(highRoot +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
    h.startEngine((settingsDir: highRoot, modelPath: highRoot +/+ "model", meminfoPath: highRoot +/+ "meminfo"))
};

// bufferSaveResult reports so far as [slot index, failed]
var saveReports = { arg target;
    h.pollValues(\bufferSaveResult).collect({ arg value;
        var slots = target.numBuffers, rest = value.asInteger div: slots;
        [value.asInteger % slots, (rest % 2) == 1]
    })
};

check.(engine.peaksPath(2) == (engine.allocSettingsDirectory +/+ "buf3.peaks"),
    "waveform: peaksPath is buf<n>.peaks in the folder used at alloc");

// A load's peaks: 64 bins of known maxima after a loud prefix, from a start
// past the prefix (short: the check at once; long: the check in a routine)
{
    var path = scratchRoot +/+ "waveform-short.wav", prefix = (0.25 * rate).floor.asInteger, binFrames = 100, slot = 1;
    var values, largest = 0;
    writePerBinFile.(path, rate, binFrames, binValues, prefix);
    command.(\loadBuffer, slot, path, 0.25);
    waitFor.({ engine.bufferFrames[slot] == (binFrames * points) });
    0.1.wait; server.sync;
    values = peakBufferValues.(engine, slot);
    points.do({ arg bin; largest = largest.max((values[bin] - binLevel.(bin)).abs) });
    check.((peaksError.(engine, slot) < 0.001) and: { largest < 0.001 },
        "waveform: a load's peaks match a file of known per-bin maxima (short: stored error %, peak buffer error %)".format(
            peaksError.(engine, slot), largest));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
}.value;

// A replace take's peaks: a check synth fills the peak buffer (bin i holds i / 64)
{
    var slot = 3, def = \strataCheckPeakFill, peaks, synth, values;
    var fill = {
        synth = Synth(def, [\buf, engine.slotPeakBuffer(slot).bufnum], engine.context.xg);
        0.05.wait; synth.free; server.sync;
    };
    SynthDef(def, { arg buf;
        var phase = Phasor.ar(0, 1, 0, BufFrames.kr(buf));
        BufWr.ar(phase / 64, buf, phase, 1);
    }).add;
    server.sync;
    fill.value;
    engine.readSlotPeaks(slot, points, { peaks = storedPeaks.(engine, slot) });
    waitFor.({ peaks.notNil });
    check.((0 .. points - 1).every({ arg bin; (peaks[bin] - (bin / points)).abs < 0.0001 }),
        "waveform: a replace take's peaks and an early stop's spread over 64 (take: read back %)".format(peaks.keep(4)));
    peaks = nil;
    engine.readSlotPeaks(slot, 32, { peaks = storedPeaks.(engine, slot) });
    waitFor.({ peaks.notNil });
    // of the first 32 bins spread over 64: new bin b covers old bin b div 2, the largest
    check.((0 .. points - 1).every({ arg bin; (peaks[bin] - ((bin div: 2) / points)).abs < 0.0001 }),
        "waveform: a replace take's peaks and an early stop's spread over 64 (early stop: read back %)".format(peaks.keep(4)));
    server.sync;
    values = peakBufferValues.(engine, slot);
    check.((0 .. points - 1).every({ arg bin; (values[bin] - ((bin div: 2) / points)).abs < 0.0001 }),
        "waveform: an early stop's spread reaches the peak buffer too (buffer holds %)".format(values.keep(4)));
    fill.value;
    peaks = nil;
    engine.readSlotPeaks(slot, 3, { peaks = storedPeaks.(engine, slot) });
    waitFor.({ peaks.notNil });
    check.(((peaks[0] - 0).abs < 0.0001) and: { (peaks[32] - (1 / points)).abs < 0.0001 } and: { (peaks[63] - (2 / points)).abs < 0.0001 },
        "waveform: an early stop's bins all count: each new bin is the largest it covers (read %, %, %)".format(peaks[0], peaks[32], peaks[63]));
    h.command(\clearBuffer, slot); server.sync;
}.value;

// The file's format, slot, frames, rate and a rising generation
{
    var path = scratchRoot +/+ "waveform-format.wav", slot = 2, peaksPath = engine.peaksPath(slot), first, second, values;
    writePerBinFile.(path, rate, 200, binValues);
    if (File.exists(peaksPath)) { File.delete(peaksPath) };
    command.(\loadBuffer, slot, path, 0);
    waitFor.({ engine.bufferFrames[slot] == (200 * points) });
    0.1.wait; server.sync;
    first = readPeaksFile.(peaksPath);
    values = first !? { first[\peaks] } ?? { [] };
    check.(first.notNil
        and: { first[('strata-peaks').asSymbol] == ["1"] } and: { first[\slot] == ["3"] }
        and: { first[\frames] == ((200 * points).asString.bubble) } and: { first[\rate] == (rate.asString.bubble) },
        "waveform: the peaks file has the format, slot, frames, rate and a rising generation (header: %)".format(first));
    check.((values.size == points) and: { values.every({ arg each; (each.size == 5) and: { each[1] == $. } }) },
        "waveform: the peaks file has the format, slot, frames, rate and a rising generation (64 values, three decimals: %)".format(values.keep(3)));
    command.(\loadBuffer, slot, path, 0);
    0.1.wait; waitFor.({ engine.bufferFrames[slot] == (200 * points) });
    0.1.wait; server.sync;
    second = readPeaksFile.(peaksPath);
    check.(first.notNil and: { second.notNil }
        and: { second[\generation][0].asInteger > first[\generation][0].asInteger },
        "waveform: the peaks file has the format, slot, frames, rate and a rising generation (generations % then %)".format(
            first !? { first[\generation] }, second !? { second[\generation] }));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
}.value;

// The action runs once the rename ends, only if nothing changed the slot
// since the write began: the clear lands before the rename can end, since
// both calls run in this one thread
{
    var slot = 6, ran = false, unchanged = false;
    engine.writeSlotPeaks(slot, 100, { unchanged = true });
    waitFor.({ unchanged });
    check.(unchanged, "waveform: writeSlotPeaks runs its action once the rename ends");
    engine.writeSlotPeaks(slot, 100, { ran = true });
    engine.clearSlot(slot);
    0.3.wait; server.sync;
    check.(ran.not, "waveform: a slot changed during the write drops writeSlotPeaks' action");
}.value;

// The peaks file is in place when the length report leaves: the poll's
// message arrives within a fraction of a millisecond, a rename's subprocess
// takes longer, so a report sent first would find no file
{
    var path = scratchRoot +/+ "waveform-order.wav", slot = 5, peaksPath = engine.peaksPath(slot), found;
    var pollIndex = CronePollRegistry.getPollFromName(\bufferState).index, watcher;
    writePerBinFile.(path, rate, 100, binValues);
    command.(\clearBuffer, slot); server.sync;
    if (File.exists(peaksPath)) { File.delete(peaksPath) };
    watcher = OSCFunc({ arg msg;
        if ((msg[1] == pollIndex) and: { msg[2] > ((slot * 1000) + 0.01) } and: { msg[2] < ((slot + 1) * 1000) } and: { found.isNil }) {
            found = File.exists(peaksPath);
        };
    }, '/poll/value');
    command.(\loadBuffer, slot, path, 0);
    waitFor.({ found.notNil });
    watcher.free;
    check.(found == true, "waveform: the peaks file is in place before the bufferState report (found: %)".format(found));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
}.value;

// Where it lands
{
    var path = h.monoPath, slot = 6, peaksPath = engine.peaksPath(slot), loadStart = Date.getDate.rawSeconds - 1;
    var home = "~/dust/data/strata/buf7.peaks".standardizePath;
    if (File.exists(peaksPath)) { File.delete(peaksPath) };
    command.(\loadBuffer, slot, path, 0);
    waitFor.({ engine.bufferFrames[slot] == 4410 });
    0.1.wait; server.sync;
    check.(File.exists(peaksPath) and: { peaksPath.beginsWith(scratchRoot) }
        and: { File.exists(home).not or: { File.mtime(home) < loadStart } },
        "waveform: the peaks file lands in the check's settings folder, never in ~/dust (%)".format(peaksPath));
    command.(\clearBuffer, slot); server.sync;
}.value;

// Through a .part: a hard link to the old file keeps the old text, which only
// a rename into place can leave (opening the file for writing changes both)
{
    var slot = 4, peaksPath = engine.peaksPath(slot), linkPath = peaksPath ++ ".link", dir = engine.allocSettingsDirectory;
    var old = "old peaks\n", kept, parts;
    if (File.exists(linkPath)) { File.delete(linkPath) };
    File.use(peaksPath, "w", { arg file; file.write(old) });
    ("ln " ++ peaksPath.shellQuote ++ " " ++ linkPath.shellQuote).systemCmd;
    command.(\loadBuffer, slot, h.monoPath, 0);
    waitFor.({ engine.bufferFrames[slot] == 4410 });
    0.1.wait; server.sync;
    kept = File.readAllString(linkPath);
    parts = (dir +/+ "*.peaks.*.part").pathMatch;
    check.((kept == old) and: { File.readAllString(peaksPath) != old } and: { parts.isEmpty },
        "waveform: the peaks file is written through a .part and never left as one (link kept the old text: %, parts left: %)".format(kept == old, parts));
    File.delete(linkPath);
    command.(\clearBuffer, slot); server.sync;
}.value;

// A clear writes no file and zeroes the peaks; a failed load changes nothing
{
    var slot = 7, peaksPath = engine.peaksPath(slot), path = scratchRoot +/+ "waveform-clear.wav", before, after, values;
    writePerBinFile.(path, rate, 100, binValues);
    command.(\loadBuffer, slot, path, 0);
    waitFor.({ engine.bufferFrames[slot] == (100 * points) });
    0.1.wait; server.sync;
    before = storedPeaks.(engine, slot).copy;
    command.(\loadBuffer, slot, scratchRoot +/+ "missing.wav", 0);
    0.2.wait; server.sync;
    command.(\loadBuffer, slot, h.textPath, 0);
    0.2.wait; server.sync;
    after = storedPeaks.(engine, slot);
    values = peakBufferValues.(engine, slot);
    check.((0 .. points - 1).every({ arg bin; (before[bin] == after[bin]) and: { (values[bin] - before[bin]).abs < 0.0001 } })
        and: { before.maxItem > 0.5 },
        "waveform: a failed load leaves the peaks unchanged (largest % then %)".format(before.maxItem, after.maxItem));
    File.delete(peaksPath);
    command.(\clearBuffer, slot);
    0.2.wait; server.sync;
    after = storedPeaks.(engine, slot);
    values = peakBufferValues.(engine, slot);
    check.(File.exists(peaksPath).not and: { after.every(_ == 0) } and: { values.every(_ == 0) },
        "waveform: a clear writes no peaks file and zeroes the peaks (file %, largest %, buffer largest %)".format(
            File.exists(peaksPath), after.maxItem, values.maxItem));
    File.delete(path);
}.value;

// A stale .part is deleted at alloc
{
    var dir = scratchRoot +/+ "waveform-stale/", part = dir +/+ "buf1.peaks.old-7.part", fresh = dir +/+ "buf2.peaks.new-8.part", other;
    File.mkdir(dir);
    [part, fresh].do({ arg each; File.use(each, "w", { arg file; file.write("peaks") }) });
    ("touch -t 202001010000 " ++ part.shellQuote).systemCmd;
    other = h.startEngine((settingsDir: dir, modelPath: scratchRoot +/+ "no-board-model"));
    check.(File.exists(part).not and: { File.exists(fresh) },
        "waveform: a stale peaks .part older than stalePartAge is deleted at alloc (old left: %, fresh left: %)".format(File.exists(part), File.exists(fresh)));
    h.freeEngine(other);
    File.delete(fresh);
}.value;

// A failed write (a folder in the way): the length is still reported, and no .part stays
{
    var slot = 2, peaksPath = engine.peaksPath(slot), dir = engine.allocSettingsDirectory, seconds = 0.1;
    if (File.exists(peaksPath)) { File.delete(peaksPath) };
    File.mkdir(peaksPath);
    command.(\loadBuffer, slot, h.monoPath, 0);
    waitFor.({ engine.bufferFrames[slot] == 4410 });
    0.1.wait; server.sync;
    check.((engine.bufferFrames[slot] == 4410) and: { h.pollValueNear(\bufferState, (slot * 1000) + seconds, 0.011) }
        and: { PathName(peaksPath).isFolder } and: { (dir +/+ "*.peaks.*.part").pathMatch.isEmpty },
        "waveform: a failed peaks write still reports the length (% frames)".format(engine.bufferFrames[slot]));
    ("rmdir " ++ peaksPath.shellQuote).systemCmd;
    command.(\clearBuffer, slot); server.sync;
}.value;

// The peaks mover (#210): one long-lived shell renames every peaks file, so a
// write never forks sclang. Engines of their own, so h.engine keeps its
// mover. Its FIFO's name is gone once both ends are open; a write through it
// lands; a stopped mover makes that one write rename by subprocess (one
// action), stays in use and is used again once it catches up; a killed one
// is noticed by its exit action and cannot SIGPIPE sclang (which holds a
// reader); a second engine's mover never holds the first's FIFO open
// (close-on-exec), so freeing the first ends its mover; and a mover that
// never removes the FIFO's name is given up at alloc.
{
    var dir = scratchRoot +/+ "waveform-mover/", mover, other, second, slot = 3, ran, peaksPath, fifo, exited, calls;
    var noBoard = scratchRoot +/+ "no-board-model";
    var alive = { arg pid; ("kill -0 " ++ pid ++ " 2>/dev/null").systemCmd == 0 };
    var write = { arg target;
        var done = false, start = Main.elapsedTime, took;
        calls = 0;
        target.writeSlotPeaks(slot, 100, { calls = calls + 1; done = true });
        waitFor.({ done }, 3);
        took = Main.elapsedTime - start;
        [done and: { File.exists(peaksPath) } and: { (dir +/+ "*.peaks.*.part").pathMatch.isEmpty }, took]
    };
    var fakeShellDir = scratchRoot +/+ "waveform-slow-sh", path, fifoLeft;
    File.mkdir(dir);
    other = h.startEngine((settingsDir: dir, modelPath: noBoard));
    mover = other.areaState[\waveform][\mover];
    peaksPath = other.peaksPath(slot);
    fifo = other.peaksMoverPath;
    check.(mover.notNil and: { mover[\alive] } and: { mover[\pid].notNil } and: { alive.(mover[\pid]) } and: { File.exists(fifo).not },
        "waveform: the peaks mover runs and its FIFO's name is gone (alive %, FIFO left %)".format(mover !? { mover[\alive] }, File.exists(fifo)));
    ran = write.(other);
    check.(ran[0] and: { mover[\alive] } and: { mover[\pending] == 0 },
        "waveform: a peaks write through the mover lands and runs its action (% ms)".format((ran[1] * 1000).round(0.1)));
    // stopped: that one write renames by subprocess after peaksMoverTimeout;
    // the mover, still running, stays in use, and once it catches up (its
    // late rename finds the .part gone and says nothing) it is used again
    ("kill -STOP " ++ mover[\pid]).systemCmd;
    ran = write.(other);
    check.(ran[0] and: { mover[\alive] } and: { ran[1] >= other.peaksMoverTimeout } and: { mover[\pending] == 1 },
        "waveform: a stopped mover's write renames by subprocess and the mover stays in use (% s, alive %, pending %)".format(
            ran[1].round(0.01), mover[\alive], mover[\pending]));
    ("kill -CONT " ++ mover[\pid]).systemCmd;
    waitFor.({ mover[\pending] == 0 }, 3);
    0.2.wait;
    check.((calls == 1) and: { mover[\pending] == 0 },
        "waveform: a write whose rename timed out runs its action once, also after the mover catches up (actions %, pending %)".format(calls, mover[\pending]));
    ran = write.(other);
    check.(ran[0] and: { ran[1] < 0.5 } and: { mover[\alive] },
        "waveform: a mover that caught up renames the next write itself (% ms)".format((ran[1] * 1000).round(0.1)));
    h.freeEngine(other);
    // killed before any timeout: its exit action stops its use, a write
    // straight into its FIFO cannot SIGPIPE sclang, and a peaks write
    // renames by subprocess at once
    other = h.startEngine((settingsDir: dir, modelPath: noBoard));
    mover = other.areaState[\waveform][\mover];
    ("kill -KILL " ++ mover[\pid]).systemCmd;
    exited = waitFor.({ mover[\exited] == true }, 3);
    check.(exited and: { mover[\alive].not },
        "waveform: a killed mover's exit action stops its use (exited %, alive %)".format(mover[\exited], mover[\alive]));
    mover[\file].write("orphan\nline\n"); mover[\file].flush;
    ran = write.(other);
    check.(ran[0] and: { ran[1] < other.peaksMoverTimeout },
        "waveform: after the mover is killed, a peaks write renames by a subprocess and sclang lives (% s)".format(ran[1].round(0.01)));
    h.freeEngine(other);
    // close-on-exec: a second engine started while the first's FIFO is
    // open, so its mover (a child of sclang) would inherit that end without
    // it; freeing the first must still end the first's mover
    other = h.startEngine((settingsDir: dir, modelPath: noBoard));
    mover = other.areaState[\waveform][\mover];
    second = h.startEngine((settingsDir: dir, modelPath: noBoard));
    h.freeEngine(other);
    exited = waitFor.({ mover[\exited] == true }, 3);
    check.(exited and: { alive.(mover[\pid]).not } and: { second.areaState[\waveform][\mover][\alive] },
        "waveform: freeing an engine ends its peaks mover while another engine's mover runs (exited %)".format(mover[\exited]));
    mover = second.areaState[\waveform][\mover];
    h.freeEngine(second);
    exited = waitFor.({ mover[\exited] == true }, 3);
    check.(exited, "waveform: freeing the engine ends its peaks mover (exited %)".format(mover[\exited]));
    // a mover that has not removed the FIFO's name when alloc's wait ends
    // (an sh on PATH that sleeps first) is given up: the name goes, the
    // shell is ended and writes rename by subprocess at once
    File.mkdir(fakeShellDir);
    File.use(fakeShellDir +/+ "sh", "w", { arg file; file.write("#!/bin/sh\nsleep 3\nexec /bin/sh \"$@\"\n") });
    ("chmod 755 " ++ (fakeShellDir +/+ "sh").shellQuote).systemCmd;
    path = "PATH".getenv;
    "PATH".setenv(fakeShellDir ++ ":" ++ path);
    other = protect { h.startEngine((settingsDir: dir, modelPath: noBoard)) } { "PATH".setenv(path) };
    "PATH".setenv(path);
    mover = other.areaState[\waveform][\mover];
    fifo = other.peaksMoverPath;
    fifoLeft = File.exists(fifo);
    exited = waitFor.({ mover[\exited] == true }, 3);
    ran = write.(other);
    check.(mover[\alive].not and: { fifoLeft.not } and: { exited } and: { ran[0] } and: { ran[1] < 0.5 },
        "waveform: a mover that never removes its FIFO's name is given up at alloc (alive %, FIFO left %, exited %, write % s)".format(
            mover[\alive], fifoLeft, mover[\exited], ran[1].round(0.01)));
    h.freeEngine(other);
    // alloc's wait is real time, not scheduled time: norns allocs in a
    // fork (Crone.setEngine, a TempoClock routine) that runs every area's
    // allocState with no sync between, so it can be behind schedule and run
    // its late waits back to back (this check's own routine is on AppClock,
    // which counts from real time, so the step runs in a fork too). A fork
    // 1.5 s behind (sclang held by a blocking sleep) starts a mover whose sh
    // removes the FIFO's name after 0.5 s: the wait must last until then,
    // and keep the mover
    File.use(fakeShellDir +/+ "sh", "w", { arg file; file.write("#!/bin/sh\nsleep 0.5\nexec /bin/sh \"$@\"\n") });
    other = h.startEngine((settingsDir: dir, modelPath: noBoard));
    other.stopPeaksMover;
    waitFor.({ other.areaState[\waveform][\mover][\exited] == true }, 3);
    {
        var started = Condition(false);
        fork {
            0.01.wait;
            "sleep 1.5".systemCmd;
            "PATH".setenv(fakeShellDir ++ ":" ++ path);
            protect { other.startPeaksMover } { "PATH".setenv(path) };
            started.test = true;
            started.signal;
        };
        h.awaitReply(started);
    }.value;
    "PATH".setenv(path);
    mover = other.areaState[\waveform][\mover];
    fifoLeft = File.exists(other.peaksMoverPath);
    ran = write.(other);
    check.(mover[\alive] and: { fifoLeft.not } and: { ran[0] } and: { ran[1] < 0.5 } and: { mover[\pending] == 0 },
        "waveform: alloc's wait for the mover counts real time, so a routine behind schedule keeps a mover that opens late (alive %, FIFO left %, write % s)".format(
            mover[\alive], fifoLeft, ran[1].round(0.01)));
    h.freeEngine(other);
    File.delete(fakeShellDir +/+ "sh");
    (dir +/+ "*.peaks").pathMatch.do({ arg each; File.delete(each) });
}.value;

// A file at another rate
{
    var slot = 3, fields;
    if (File.exists(engine.peaksPath(slot))) { File.delete(engine.peaksPath(slot)) };
    command.(\loadBuffer, slot, h.stereoPath, 0);
    waitFor.({ engine.bufferFrames[slot] == 11025 });
    0.1.wait; server.sync;
    fields = readPeaksFile.(engine.peaksPath(slot));
    check.(fields.notNil and: { fields[\rate] == ["22050"] } and: { fields[\frames] == ["11025"] }
        and: { h.pollValueNear(\bufferState, (slot * 1000) + 0.5, 0.011) },
        "waveform: a file at another rate writes its own rate, so frames / rate equals the reported seconds (%)".format(fields));
    command.(\clearBuffer, slot); server.sync;
}.value;

// A file shorter than 64 frames
{
    var path = scratchRoot +/+ "waveform-tiny.wav", slot = 4, peaks;
    h.writeTestFile(path, rate, 10, [0.5, -0.5]);
    command.(\loadBuffer, slot, path, 0);
    waitFor.({ engine.bufferFrames[slot] == 10 });
    0.1.wait; server.sync;
    peaks = storedPeaks.(engine, slot);
    check.((engine.bufferFrames[slot] == 10)
        and: { peaks.every({ arg each; (each == 0) or: { (each - 0.5).abs < 0.001 } }) }
        and: { peaks.count({ arg each; each > 0 }) == 10 },
        "waveform: a file shorter than 64 frames loads and its peaks fill only the bins its frames reach (% frames, % bins)".format(
            engine.bufferFrames[slot], peaks.count({ arg each; each > 0 })));
    command.(\clearBuffer, slot); server.sync;
    File.delete(path);
}.value;

// A high engine of its own: a long file's peaks, then the soak
highEngine = startHighEngine.value;
{
    var path = scratchRoot +/+ "waveform-long.wav", binFrames = 15000, prefix = (1.5 * rate).floor.asInteger, slot = 1, frames = binFrames * points;
    writePerBinFile.(path, rate, binFrames, binValues, prefix);
    h.commandTo(highEngine, \loadBuffer, slot, path, 1.5);
    waitFor.({ highEngine.bufferFrames[slot] == frames }, 20);
    0.2.wait; server.sync;
    check.((highEngine.bufferFrames[slot] == frames) and: { peaksError.(highEngine, slot) < 0.001 },
        "waveform: a load's peaks match a file of known per-bin maxima (long, from a start: % frames, error %)".format(
            highEngine.bufferFrames[slot], peaksError.(highEngine, slot)));
    h.commandTo(highEngine, \clearBuffer, slot); server.sync;
    File.delete(path);
}.value;

// The 300 s soak: seconds per round posted; at most 240 s in all
{
    var seconds = 300, rounds = 3, frames = seconds * rate, path = highRoot +/+ "soak.wav", file;
    var failed = List.new(rounds), times = List.new(rounds), loads = List.new(rounds), start = Main.elapsedTime;
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    file.openWrite(path);
    h.writeConstantFrames(file, frames, [0.5, -0.25]);
    file.close;
    rounds.do({ arg round;
        var slot = round % highEngine.numBuffers, savePath = highRoot +/+ "saved/round%.wav".format(round);
        var roundStart = Main.elapsedTime, loaded, saved, savedFile, count, reports, loadSeconds;
        h.commandTo(highEngine, \loadBuffer, slot, path, 0);
        loaded = waitFor.({ highEngine.bufferFrames[slot] == frames }, 60);
        loadSeconds = Main.elapsedTime - roundStart;
        loads.add(loadSeconds.round(0.01));
        reports = saveReports.(highEngine).size;
        h.commandTo(highEngine, \saveBuffer, slot, savePath, 0, 1);
        saved = waitFor.({ saveReports.(highEngine).size > reports }, 60)
            and: { saveReports.(highEngine).copyToEnd(reports) == [[slot, false]] };
        savedFile = if (saved) { SoundFile.openRead(savePath) };
        count = savedFile !? { arg each; var value = each.numFrames; each.close; value } ? 0;
        h.commandTo(highEngine, \clearBuffer, slot); server.sync;
        if (File.exists(savePath)) { File.delete(savePath) };
        times.add(Main.elapsedTime - roundStart);
        if (loaded.not or: { saved.not } or: { count != frames }) { failed.add(round) };
        ("waveform: 300 s pair % of %: load % s, load and save % s".format(round + 1, rounds, loadSeconds.round(0.01), times.last.round(0.01))).postln;
    });
    File.delete(path);
    check.(failed.isEmpty and: { (Main.elapsedTime - start) < 240 },
        "waveform: a 300 s load and a 300 s save back to back, three times, without an sclang abort (failed %, % s in all, loads % s)".format(
            failed.asArray, (Main.elapsedTime - start).round(0.1), loads.asArray));
}.value;
h.freeEngine(highEngine);
}
