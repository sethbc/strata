// test/engine_check/soak.scd
// The soak: on demand only (STRATA_ENGINE_CHECK_AREAS=soak; never in a full
// run or a CI shard). A long session's long-file work on a high engine of
// its own, round after round, so the allocation of the engine's long-file
// paths in sclang (the decode check of loadBuffer, the save interleave)
// adds up as hours of play would: sclang 3.13, norns' version, can fail in
// its garbage collector under heavy allocation (#131;
// docs/notes/engine/files.md). Each round loads a long file into the next
// slot, saves the slot, checks that the saved file equals the source in
// every frame and clears the slot.
//   STRATA_SOAK_ROUNDS: the rounds (40 by default)
//   STRATA_SOAK_CHECK: frames (the default) or length (only the saved
//   file's length: the engine's own allocation, without the check's reads)
//   STRATA_SOAK_SECONDS: the file and slot length, one of the high tier's
//   lengths (60 by default; 120 or 300, which allocates 8 x 2 x 300 s of
//   server buffers, about 920 MB at 48 kHz)
// The run must end inside its deadline (ENGINE_CHECK_TIMEOUT less 30 s,
// 540 s by default): give a long soak a longer ENGINE_CHECK_TIMEOUT.
{ arg h;
var server = h.server, scratchRoot = h.tempDir;
var check = { arg condition, message; h.check(condition, message) };
var waitFor = { arg condition, timeout = 3; h.waitFor(condition, timeout) };
var rounds = { var given = ("STRATA_SOAK_ROUNDS".getenv ? "").asInteger; if (given > 0) { given } { 40 } }.value;
var seconds = ("STRATA_SOAK_SECONDS".getenv ? "60").asInteger;
var root = scratchRoot +/+ "soak", rate = server.sampleRate.asInteger;
var write = { arg path, text; File.use(path, "w", { arg file; file.write(text) }) };
var ramp = { arg frame; ((frame % 1000) / 1000 - 0.5) * 0.8 }, period;
var sourcePath = root +/+ "ramp.wav", file, other, frames, failed = List.new, start, times = List.new;
var checkFrames = ("STRATA_SOAK_CHECK".getenv ? "frames") != "length";
// A saved file against the source in every sample (h.sameFrames: the int16
// samples come back exactly): [the largest difference, the frames compared]
var sameAsSource = { arg savedFile; h.sameFrames(savedFile, sourcePath) };
// bufferSaveResult reports so far as [slot index, failed]: value =
// (save * 2 + failed) * numBuffers + slot index
var saveReports = {
    h.pollValues(\bufferSaveResult).collect({ arg value;
        var slots = other.numBuffers, rest = value.asInteger div: slots;
        [value.asInteger % slots, (rest % 2) == 1]
    })
};

if ([60, 120, 300].includes(seconds).not) {
    check.(false, "soak: STRATA_SOAK_SECONDS is one of the high tier's long lengths (60, 120, 300), got %".format(seconds));
    seconds = 60;
};
frames = seconds * rate;
period = (0 .. 999).collect(ramp);
File.mkdir(root);
write.(root +/+ "performance.data", "performance high\nbuffer_seconds %\n".format(seconds));
write.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4");
write.(root +/+ "meminfo", "MemTotal:        8000000 kB\nMemFree:         6000000 kB\nMemAvailable:    7000000 kB\n");
// the long file: left a ramp, right its negative, a second at a time
file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
file.openWrite(sourcePath);
seconds.do({ arg second;
    var left = h.periodic(period, second * rate, rate);
    file.writeData(h.stereoOf(left, left.neg));
});
file.close;

other = h.startEngine((settingsDir: root, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
check.(other.tier == \high and: { other.bufferSeconds == seconds },
    "soak: the high engine has % s slots (tier %, % s)".format(seconds, other.tier, other.bufferSeconds));
start = Main.elapsedTime;
rounds.do({ arg round;
    var slot = round % other.numBuffers, savePath = root +/+ "saved/round%.wav".format(round % 2);
    var roundStart = Main.elapsedTime, loaded, reports, saved, deviation, savedFile;
    if (File.exists(savePath)) { File.delete(savePath) };
    h.commandTo(other, \loadBuffer, slot, sourcePath);
    loaded = waitFor.({ other.bufferFrames[slot] == frames }, 30);
    reports = saveReports.value.size;
    h.commandTo(other, \saveBuffer, slot, savePath);
    saved = waitFor.({ saveReports.value.size > reports }, 120)
        and: { saveReports.value.copyToEnd(reports) == [[slot, false]] };
    savedFile = if (saved) { SoundFile.openRead(savePath) };
    deviation = case
        { savedFile.isNil } { [1, 0] }
        { checkFrames.not } { [0, savedFile.numFrames] }
        { sameAsSource.(savedFile) };
    savedFile !? { savedFile.close };
    h.commandTo(other, \clearBuffer, slot); server.sync;
    times.add(Main.elapsedTime - roundStart);
    if (loaded.not or: { saved.not } or: { deviation[0] != 0 } or: { deviation[1] != frames }) {
        failed.add(round);
        ("soak: round % failed (loaded %, saved %, largest error %, % of % frames)".format(
            round + 1, loaded, saved, deviation[0], deviation[1], frames)).postln;
    };
    ("soak: round % of %: % s".format(round + 1, rounds, times.last.round(0.01))).postln;
});
check.(failed.isEmpty,
    "soak: % rounds of a % s load, save and every-frame check (failed: %; % s in all, % s at most a round)".format(
        rounds, seconds, failed.asArray, (Main.elapsedTime - start).round(0.1), times.maxItem.round(0.01)));
h.freeEngine(other);
File.delete(sourcePath);
2.do({ arg index; var path = root +/+ "saved/round%.wav".format(index); if (File.exists(path)) { File.delete(path) } });
}
