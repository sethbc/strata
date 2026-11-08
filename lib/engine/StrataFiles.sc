// StrataFiles.sc
// The files area: checking a file decodes before a load, writing a slot
// to a WAV (saveBuffer, its bufferSaveResult poll, and the scratch takes)
// and deleting what an interrupted write left. See docs/notes/engine/files.md.

+ Engine_Strata {
    // The files area (order 50)
    strataAreaFiles {
        ^(
            order: 50,
            // per slot, the saveBuffer commands received (bufferSaves); then
            // the files a write interrupted by a crash or power cut left
            allocState: {
                areaState[\files][\saves] = Array.fill(numBuffers, 0);
                this.deleteStaleParts
            },
            addCommands: { this.addFileCommands }
        )
    }

    addFileCommands {
        // msg: slot index, path of the stereo 16-bit WAV to write
        this.addCommand(\saveBuffer, "is", { arg msg;
            this.saveSlot(msg[1], msg[2].asString);
        });

        // How a save ended: one message per saveBuffer whose write ends,
        // written or failed (bufferSaveResultValue: the slot, that slot's save
        // number and failed), so Lua confirms a save only once its file is in
        // place and a late report never speaks for a newer save. A write
        // abandoned for a newer write to the same path reports nothing (the
        // newer one reports). Not periodic; a value request resends the last
        // report (Lua ignores a repeat).
        areaState[\files][\saveResultPoll] = this.addPoll(\bufferSaveResult, {
            this.bufferSaveResultPoll.value ? 0.0
        }, false);
    }

    bufferSaveResultPoll { ^areaState[\files][\saveResultPoll] }

    // Per slot: the saveBuffer commands received, counted from 1 (Lua's
    // save_buffer counts the same), named in bufferSaveResult
    bufferSaves { ^areaState[\files][\saves] }

    // One float, as bufferLoadFailed (matron's /poll/value is typed "if"):
    // (save * 2 + failed) * numBuffers + slot index, where save is the slot's
    // save number (counted from 1) and failed is 1 when the engine wrote
    // nothing, 0 when the file is in place. Exact for the first 2^20 saves of
    // a slot (a float32 holds integers exactly up to 2^24).
    bufferSaveResultValue { arg index, save, failed;
        ^((((save * 2) + failed.binaryValue) * numBuffers) + index).asFloat
    }

    // saveBuffer: count the save and write the slot, reporting how the write
    // ended on bufferSaveResult (an abandoned write reports nothing)
    saveSlot { arg index, path;
        var save;
        if (this.validBuffer(index).not) { ^this };
        save = this.bufferSaves[index] + 1;
        this.bufferSaves[index] = save;
        this.writeSlot(index, path, { arg written;
            this.bufferSaveResultPoll.update(this.bufferSaveResultValue(index, save, written.not));
        });
    }

    // true when libsndfile decodes the first `frames` frames of the open
    // file, or all but loadShortfallFrames of them. A damaged compressed file
    // (a corrupt or truncated FLAC) has a sound header but stops decoding
    // early, and the server's read then fills the rest with silence without
    // reporting anything, so loadSlot decodes the frames itself first (16 s
    // of 48 kHz stereo: about 2 ms for a WAV, 9 ms for a FLAC on a desktop;
    // the file is then in the page cache for the server's read). The
    // shortfall allowed is one default FLAC block (4096 frames, 85 ms at
    // 48 kHz), more than an MP3's encoder delay and padding (under 2 x 1152
    // frames), so a header count that overshoots by a codec's padding still
    // loads, while damage before the last block is caught. Each read gets a
    // fresh chunk array (the last read may run past `frames`): see
    // freshReadArray.
    // yielding: called inside a routine, which yields after every chunk
    // (yieldToCommands), so a long file (a 300 s FLAC takes seconds on a Pi)
    // never holds up the commands meanwhile.
    fileDecodes { arg file, frames, yielding = false;
        var remaining = frames, chunk, decoded;
        while { remaining > 0 } {
            chunk = this.freshReadArray(loadCheckFrames * file.numChannels);
            file.readData(chunk);  // shrinks chunk to the samples decoded
            decoded = chunk.size div: file.numChannels;
            remaining = remaining - decoded;
            if ((decoded < loadCheckFrames) and: { remaining > 0 }) { ^remaining <= loadShortfallFrames };
            if (yielding and: { remaining > 0 }) { this.yieldToCommands(0) };
        };
        ^true
    }

    // A new FloatArray of `size` for one SoundFile readData. Every readData
    // reads into a fresh array, never one an earlier read filled: reusing
    // one across reads makes sclang 3.13 (norns' version) abort a while
    // later in its garbage collector (a count assertion). On 3.13 the
    // engine check's buffers, files and effects areas crashed 11 of 12 runs
    // with the arrays reused and 1 of 8 with fresh ones (#131). A structure
    // test checks every readData in the engine reads into one.
    freshReadArray { arg size;
        ^FloatArray.newClear(size)
    }

    // Inside a routine: wait `wait` seconds, and at least until commandGap
    // seconds of real time from now. A routine whose chunks take longer than
    // its waits falls behind its logical time, so a plain wait reschedules
    // it in the past: SystemClock runs it again at once without ever
    // releasing the language lock, and every OSC message (matron's commands,
    // server replies) waits until the routine ends. Waking in the real
    // future lets them in after every chunk. A routine on time waits just
    // `wait`, as a plain wait would.
    yieldToCommands { arg wait;
        wait.max((Main.elapsedTime - thisThread.seconds) + this.commandGap).wait
    }

    // The least real time a yielding chunk loop waits (s): long enough for a
    // waiting OSC message to take the language lock, short enough to add
    // little to a long loop (0.18 s over a 300 s save's 1758 chunks)
    commandGap { ^0.0002 }

    scratchPath { arg index;
        ^scratchDir +/+ ("buf" ++ (index + 1) ++ ".wav")
    }

    // Delete the files a write interrupted by a crash or power cut left: the
    // .part files in scratchDir (scratch takes), its parent (saveBuffer's
    // <date>-buf<n>.wav, in _path.audio/strata/ on norns) and the settings
    // folder (performance_active.data, performance.data), and writeSlot's
    // temporary float files (strata-buf<n>-<tag>-<n>-<side>.wav) in
    // Platform.defaultTempDir; only files older than stalePartAge. alloc
    // calls this: after a script reload in the same sclang session the
    // previous engine instance may still be writing, and a running write
    // touches its .part with every chunk, so a fresh one is never deleted
    // (its float files are written just before the interleave opens them,
    // and deleting an open file does not stop it being read). A file whose
    // age cannot be read is left, with a line in maiden (one gone since
    // pathMatch is skipped silently). Returns those files' paths.
    deleteStaleParts {
        var oldest = Date.getDate.rawSeconds - stalePartAge, unreadable = List.new;
        var patterns = this.stalePartDirs.collect({ arg dir; dir +/+ "*.part" })
            ++ [Platform.defaultTempDir +/+ "strata-buf*-*.wav"];
        patterns.do({ arg pattern;
            pattern.pathMatch.do({ arg path;
                var modified = try { File.mtime(path) } {
                    // gone since pathMatch, or not (File.exists fails too
                    // when the directory cannot be searched)
                    if (try { File.exists(path) } { true }) { unreadable.add(path) };
                    nil
                };
                if (modified.notNil and: { modified < oldest }) { File.delete(path) };
            });
        });
        unreadable.do({ arg path;
            var line = "strata: cannot read when " ++ path ++ " was last written; left in place";
            if (postStaleFileLine.notNil) { postStaleFileLine.value(line) } { line.postln };
        });
        ^unreadable.asArray
    }

    // scratchDir and its parent, then the settings folder the performance
    // area used at alloc (settingsDir, or ~/dust/data/strata/), keeping only
    // absolute directories below the root: an empty or relative scratchDir
    // ("", ".", "scratch/", whose dirname is ".") or settingsDir would glob
    // the working directory, and "" or "/" the root. "~" is expanded; other
    // paths are not standardized, since standardizePath turns "." into the
    // working directory. A folder is listed once.
    stalePartDirs {
        var dir = scratchDir.asString, dirs, settings;
        settings = this.allocSettingsDirectory.asString;
        if (dir.beginsWith("~")) { dir = dir.standardizePath };
        if (settings.beginsWith("~")) { settings = settings.standardizePath };
        dir = dir.withoutTrailingSlash;
        settings = settings.withoutTrailingSlash;
        dirs = [dir, dir.dirname];
        if (dirs.includesEqual(settings).not) { dirs = dirs.add(settings) };
        ^dirs.select({ arg each;
            each.beginsWith("/") and: { each.withoutTrailingSlash.size > 1 }
        })
    }

    // Write a slot's valid region to path as a stereo 16-bit WAV at the
    // content's sample rate, creating the directory. The server writes each
    // mono buffer to a temporary float file; sclang then interleaves them in
    // chunks (yielding between chunks from the real time, so a 300 s save
    // never holds up the commands) into a per-write
    // path.<instanceTag>-<n>.part file and renames it into place, so a
    // reader never sees a half-written file. Each write to a path gets a new
    // generation number: an older write still interleaving when a newer one
    // starts abandons (deleting its .part), so the newest write always wins
    // and two writes never mix. instanceTag keeps another engine instance's
    // files apart. Samples beyond ±1 (a take recorded at a level above 1)
    // are clipped symmetrically to ±int16Peak, never wrapped. Temporary
    // files are deleted in every case. Creates no synth nodes. done (nil, or
    // a function of written, a Boolean) is called once when the write ends:
    // true once the file is in place, false when nothing was written (an
    // empty slot, at once; a folder that cannot be made, a short write or a
    // failed rename); never for a write a newer one abandoned.
    writeSlot { arg index, path, done;
        var frames = bufferFrames[index];
        var sampleRate = bufferSampleRates[index];
        var generation, tempPaths, partPath;
        if (frames < 1) {
            postln("strata: buffer " ++ (index + 1) ++ " is empty; nothing written to " ++ path);
            done.value(false);
            ^this
        };
        path = path.standardizePath;
        writeCount = writeCount + 1;
        generation = writeCount;
        writeGenerations[path] = generation;
        tempPaths = ["L", "R"].collect({ arg side;
            Platform.defaultTempDir +/+ "strata-buf%-%-%-%.wav".format(index + 1, instanceTag, generation, side)
        });
        partPath = path ++ "." ++ instanceTag ++ "-" ++ generation ++ ".part";
        buffersL[index].write(tempPaths[0], "wav", "float", frames);
        buffersR[index].write(tempPaths[1], "wav", "float", frames);
        fork({
            var current = { writeGenerations[path] == generation };
            // done runs at most once, whatever happens below
            var reported = false, finish = { arg ok; if (reported.not) { reported = true; done.value(ok) } };
            var deleteIfThere = { arg file; try { if (File.exists(file)) { File.delete(file) } } };
            var written, moved, folder;
            try {
                context.server.sync;
                written = current.value and: { this.interleaveFiles(tempPaths, partPath, sampleRate, current, frames) };
                tempPaths.do({ arg tempPath; File.delete(tempPath) });
                // no yield between this check and the rename. The newest write
                // forgets its generation whether it succeeded or failed, and
                // reports how it ended (finish); an abandoned one leaves the
                // newer write's entry alone and reports nothing. A folder at
                // the path fails the write: mv -f would move the file into it.
                if (current.value) {
                    folder = written and: { PathName(path).isFolder };
                    if (folder) { postln("strata: cannot write " ++ path ++ " (a folder is in the way)") };
                    moved = written and: { folder.not }
                        and: { ("mv -f " ++ partPath.shellQuote ++ " " ++ path.shellQuote).systemCmd == 0 };
                    if (moved) {
                        postln("strata: wrote buffer " ++ (index + 1) ++ " to " ++ path);
                    } {
                        if (written and: { folder.not }) { postln("strata: cannot move " ++ partPath ++ " to " ++ path) };
                    };
                    writeGenerations.removeAt(path);
                    finish.(moved);
                };
                if (File.exists(partPath)) { File.delete(partPath) };
            } { arg error;
                // an sclang error inside the write (a read, a delete, the
                // interleave) still ends it: nothing left behind, and the
                // newest write still reports, failed. Never posted with the
                // word the engine check fails on: the check injects this.
                postln("strata: cannot write % (%)".format(path, error.class.name));
                tempPaths.do(deleteIfThere);
                deleteIfThere.(partPath);
                if (current.value) {
                    writeGenerations.removeAt(path);
                    finish.(false);
                };
            };
        }, SystemClock);
    }

    // A test hook (nil on norns): a function interleaveFiles calls first with
    // the output path, so the engine check can throw inside a write's routine
    interleaveFaultHook { ^areaState[\files][\interleaveFaultHook] }
    interleaveFaultHook_ { arg hook; areaState[\files][\interleaveFaultHook] = hook }

    // Called inside a routine. Returns false (and writes nothing more) as
    // soon as keepGoing is false, i.e. a newer write to the same path began,
    // or when the output cannot be written. frames is the slot's valid
    // length: a temporary file holding fewer (the server's write ran out of
    // disk: a 300 s save needs about 115 MB of them) or an output that ends
    // short is a failed write, posted as one, so writeSlot never renames a
    // truncated file over the old one.
    interleaveFiles { arg sourcePaths, path, sampleRate, keepGoing, frames;
        var chunkFrames = 8192, sources;
        var output, left, right, interleaved, finished = true, written;
        var peak = int16Peak, negativePeak = int16Peak.neg;

        this.interleaveFaultHook.value(path);  // the engine check's fault, before any file opens
        sources = sourcePaths.collect({ arg sourcePath; SoundFile.openRead(sourcePath) });
        if (sources.includes(nil).not and: { sources.any({ arg source; source.numFrames < frames }) }) {
            postln("strata: cannot write " ++ path ++ " (a temporary file holds % of % frames: is the disk full?)".format(
                sources.collect(_.numFrames).minItem, frames));
            sources.do({ arg source; source.close });
            ^false
        };
        // File.mkdir throws when the directory cannot be made; openWrite then fails below
        try { File.mkdir(path.dirname) };
        output = if (sources.includes(nil).not) { SoundFile.openWrite(path, "WAV", "int16", 2, sampleRate) };
        if (output.isNil) {
            postln("strata: cannot write " ++ path);
            sources.do({ arg source; if (source.notNil) { source.close } });
            ^false
        };

        while { finished and: { left = this.freshReadArray(chunkFrames); sources[0].readData(left); left.size > 0 } } {
            right = this.freshReadArray(chunkFrames);
            sources[1].readData(right);
            // A per-frame loop: faster here than an array-level lace, which
            // only descends into Arrays, so each chunk would be converted
            // FloatArray -> Array -> FloatArray (about twice as slow in sclang 3.13)
            interleaved = FloatArray.newClear(left.size * 2);
            left.size.do({ arg frame;
                interleaved[frame * 2] = left[frame].clip(negativePeak, peak);
                interleaved[(frame * 2) + 1] = (right[frame] ? 0).clip(negativePeak, peak);
            });
            output.writeData(interleaved);
            // from the real time: a long save's chunks outlast a 1 ms wait
            this.yieldToCommands(writeChunkWait);
            finished = keepGoing.value;
        };
        output.close;
        sources.do({ arg source; source.close });
        if (finished.not) { ^false };
        // the output read back: a write that ran out of disk ends short
        written = SoundFile.openRead(path);
        written = written !? { arg file; var count = file.numFrames; file.close; count };
        if (written != frames) {
            postln("strata: cannot write " ++ path ++ " (% of % frames written: is the disk full?)".format(written, frames));
            ^false
        };
        ^true
    }
}
