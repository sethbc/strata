// StrataFiles.sc
// The files area: checking a file decodes before a load, writing a slot
// to a WAV (saveBuffer, its bufferSaveResult poll, and the scratch takes)
// and deleting what an interrupted write left. See docs/notes/engine/files.md.

+ Engine_Strata {
    // The files area (order 50)
    strataAreaFiles {
        ^(
            order: 50,
            // per slot, the saveBuffer commands received (bufferSaves), the
            // renames under way (pathRenames); then the files a write
            // interrupted by a crash or power cut left
            allocState: {
                areaState[\files][\saves] = Array.fill(numBuffers, 0);
                areaState[\files][\renames] = Dictionary.new;
                this.deleteStaleParts
            },
            addCommands: { this.addFileCommands }
        )
    }

    addFileCommands {
        // msg: slot index, path of the stereo 16-bit WAV to write, start and
        // length (fractions of the valid region; 0 and 1 write all of it)
        this.addCommand(\saveBuffer, "isff", { arg msg;
            this.saveSlot(msg[1], msg[2].asString, msg[3], msg[4]);
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

    // Per output path: the write whose rename into place is under way (its
    // generation), from the rename's start until it has ended, so a newer
    // write to the path renames only after it. Holds only renames under way.
    pathRenames { ^areaState[\files][\renames] }

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
    saveSlot { arg index, path, start = 0, length = 1;
        var save;
        if (this.validBuffer(index).not) { ^this };
        save = this.bufferSaves[index] + 1;
        this.bufferSaves[index] = save;
        this.writeSlot(index, path, { arg written;
            this.bufferSaveResultPoll.update(this.bufferSaveResultValue(index, save, written.not));
        }, start, length);
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
    // fresh chunk array: see freshReadArray.
    // yielding: called inside a routine, which yields after every chunk
    // (yieldToCommands), so a long file (a 300 s FLAC takes seconds on a Pi)
    // never holds up the commands meanwhile. keepGoing (nil, or a function
    // answering whether the check is still wanted) is asked after each of
    // those yields: false stops the check there and returns false, so a
    // load that something superseded reads no further (#375).
    // peaks (a FloatArray of waveformPoints, or nil): filled with the
    // largest absolute sample of each bin across the channels, clipped to 1.
    // The reads are bin-aligned: at most loadCheckFrames, ending at the next
    // bin boundary, so no chunk spans two bins. A bin's peak is Signal's
    // peak, a C primitive: no array and no sclang function per sample
    // (maxItem and minItem call a function for every sample, #131).
    fileDecodes { arg file, frames, yielding = false, peaks, keepGoing;
        var channels = file.numChannels, done = 0, bin = 0, binEnd, wanted, chunk, decoded;
        peaks = peaks ?? { FloatArray.newClear(this.waveformPoints) };
        while { done < frames } {
            // a file shorter than the bins leaves some of them empty: skipped, never read
            binEnd = this.peakBinEnd(bin, frames);
            while { binEnd <= done } { bin = bin + 1; binEnd = this.peakBinEnd(bin, frames) };
            wanted = loadCheckFrames.min(binEnd - done);
            chunk = this.freshReadArray(wanted * channels);
            file.readData(chunk);  // shrinks chunk to the samples decoded
            decoded = chunk.size div: channels;
            if (decoded > 0) { peaks[bin] = peaks[bin].max(chunk.peak.min(1.0)) };
            done = done + decoded;
            if ((decoded < wanted) and: { done < frames }) { ^(frames - done) <= loadShortfallFrames };
            if (yielding and: { done < frames }) {
                this.yieldToCommands(0);
                if (keepGoing.notNil and: { keepGoing.value.not }) { ^false };
            };
        };
        ^true
    }

    // The first frame after a load's bin (integers, so every frame is in
    // exactly one bin). Bin waveformPoints - 1 ends at `frames`.
    peakBinEnd { arg bin, frames;
        ^((bin + 1) * frames) div: this.waveformPoints
    }

    // A new Signal (a FloatArray) of `size` for one SoundFile readData.
    // Every readData reads into a fresh array, never one an earlier read
    // filled: reusing one across reads makes sclang 3.13 (norns' version)
    // abort a while later in its garbage collector (a count assertion). On
    // 3.13 the engine check's buffers, files and effects areas crashed 11 of
    // 12 runs with the arrays reused and 1 of 8 with fresh ones (#131). A
    // structure test checks every readData in the engine reads into one. A
    // Signal, so the interleave can clip a chunk and the peak scan measure
    // one with C primitives.
    freshReadArray { arg size;
        ^Signal.newClear(size)
    }

    // The indices interleaveChunk needs for a chunk of `size` frames, each
    // an Array the series primitive fills: the left channel's samples in
    // the stereo chunk (0, 2, ...), the right's (1, 3, ...) and a mono
    // chunk's frames (0 .. size - 1)
    interleaveKeys { arg size;
        ^[(0, 2 .. (size * 2) - 2), (1, 3 .. (size * 2) - 1), (0 .. size - 1)]
    }

    // One interleaved chunk of a left and a right chunk (Signals, as
    // freshReadArray makes them; a right one shorter than the left is
    // padded with silence), each clipped to ±peak, using C primitives only:
    // no sclang function runs per sample, which on sclang 3.13 piles up
    // garbage-collector work (#131). The Signal clip, at with an index
    // Array (which returns an Array of Floats) and putEach (which reads
    // its keys and values as Arrays: never pass it a FloatArray or Signal,
    // whose samples it would misread). keys: the interleaveKeys of
    // left.size. Byte for byte what a per-frame loop wrote.
    interleaveChunk { arg left, right, keys, peak;
        var size = left.size, interleaved = FloatArray.newClear(size * 2);
        if (right.size < size) { right = right.extend(size, 0.0) };
        interleaved.putEach(keys[0], left.clip(peak.neg, peak).at(keys[2]));
        interleaved.putEach(keys[1], right.clip(peak.neg, peak).at(keys[2]));
        ^interleaved
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
    // reader never sees a half-written file. The rename goes to the mover
    // (renameIntoPlace, the waveform area's: no fork of sclang, #217), after
    // any older write's rename to the path has ended, so renames land in
    // write order. Each write to a path gets a new
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
    // start and length are fractions of the valid region (V frames): the
    // write takes frames [start * V, (start + length) * V). A region of less
    // than one frame writes nothing, posts why and calls done with false.
    writeSlot { arg index, path, done, start = 0, length = 1;
        var valid = bufferFrames[index];
        var sampleRate = bufferSampleRates[index];
        var firstFrame, frames, generation, tempPaths, partPath;
        if (valid < 1) {
            postln("strata: buffer " ++ (index + 1) ++ " is empty; nothing written to " ++ path);
            done.value(false);
            ^this
        };
        firstFrame = (start.clip(0, 1) * valid).round.asInteger;
        frames = ((start + length).clip(0, 1) * valid).round.asInteger - firstFrame;
        if ((frames < 1) or: { (length * valid) < 1 }) {
            postln("strata: the region of buffer " ++ (index + 1) ++ " is under one frame; nothing written to " ++ path);
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
        buffersL[index].write(tempPaths[0], "wav", "float", frames, firstFrame);
        buffersR[index].write(tempPaths[1], "wav", "float", frames, firstFrame);
        fork({
            var current = { writeGenerations[path] == generation };
            // done runs at most once, whatever happens below
            var reported = false, finish = { arg ok; if (reported.not) { reported = true; done.value(ok) } };
            var deleteIfThere = { arg file; try { if (File.exists(file)) { File.delete(file) } } };
            // every SoundFile the interleave opens, so an error can close them
            var openFiles = List.new;
            // handedOff: the .part belongs to its rename (renameIntoPlace),
            // which reports; never deleted or reported here after that.
            // newest: it passed the newest-write check, so it reports even
            // after its writeGenerations entry has gone
            var written, folder, handedOff = false, renameEnded = false, newest = false, waitStart;
            try {
                context.server.sync;
                written = current.value and: {
                    this.interleaveFiles(tempPaths, partPath, sampleRate, current, frames, openFiles)
                };
                tempPaths.do({ arg tempPath; File.delete(tempPath) });
                // an older write's rename to this path still under way (the
                // mover's, or a subprocess's): wait for it, so renames land in
                // write order whatever carries them (a newer one by subprocess
                // could land before an older one the mover still holds). At
                // most twice peaksMoverTimeout; it ends by then. Polled as
                // often as the mover's acknowledgment (peaksMoverPollStep).
                waitStart = Main.elapsedTime;
                // A write a newer one supersedes stops waiting at once.
                while { written and: { this.pathRenames[path].notNil } and: { current.value }
                    and: { (Main.elapsedTime - waitStart) < (this.peaksMoverTimeout * 2) } } {
                    this.yieldToCommands(this.peaksMoverPollStep)
                };
                // no yield between this check and the rename's start. The
                // newest write forgets its generation whether it succeeded or
                // failed, and reports how it ended (finish); an abandoned one
                // leaves the newer write's entry alone and reports nothing. A
                // folder at the path fails the write: mv -f would move the
                // file into it. The rename goes to the mover (no fork of
                // sclang, #217) and finish runs once it has ended.
                if (current.value) {
                    newest = true;
                    folder = written and: { PathName(path).isFolder };
                    if (folder) { postln("strata: cannot write " ++ path ++ " (a folder is in the way)") };
                    writeGenerations.removeAt(path);
                    if (written and: { folder.not }) {
                        this.renameIntoPlace(partPath, path, { arg moved;
                            renameEnded = true;
                            if (this.pathRenames[path] == generation) { this.pathRenames.removeAt(path) };
                            if (moved) {
                                postln("strata: wrote buffer " ++ (index + 1) ++ " to " ++ path);
                            } {
                                postln("strata: cannot move " ++ partPath ++ " to " ++ path);
                            };
                            finish.(moved);
                        });
                        // scheduled: from here the rename owns the .part and reports
                        handedOff = true;
                        if (renameEnded.not) { this.pathRenames[path] = generation };
                    } {
                        finish.(false);
                    };
                };
                if (handedOff.not and: { File.exists(partPath) }) { File.delete(partPath) };
            } { arg error;
                // an sclang error inside the write (a read, a delete, the
                // interleave) still ends it: its sound files closed, nothing
                // left behind, and the newest write still reports, failed.
                // Each close is its own try, so one that fails skips nothing.
                // Never posted with the word the engine check fails on: the
                // check injects this.
                postln("strata: cannot write % (%)".format(path, error.class.name));
                openFiles.do({ arg file; try { if (file.notNil and: { file.isOpen }) { file.close } } });
                tempPaths.do(deleteIfThere);
                // no rename scheduled: nothing else will report
                if (handedOff.not) {
                    deleteIfThere.(partPath);
                    if (current.value) { writeGenerations.removeAt(path); newest = true };
                    if (newest) { finish.(false) };
                };
            };
        }, SystemClock);
    }

    // A test hook (nil on norns): a function interleaveFiles calls with the
    // output path, a stage and its open sound files (openFiles): \start before
    // it opens any, \open once the temporary files and the output are open,
    // so the engine check can throw inside a write's routine at either point
    interleaveFaultHook { ^areaState[\files][\interleaveFaultHook] }
    interleaveFaultHook_ { arg hook; areaState[\files][\interleaveFaultHook] = hook }

    // Called inside a routine. Returns false (and writes nothing more) as
    // soon as keepGoing is false, i.e. a newer write to the same path began,
    // or when the output cannot be written. frames is the length written (of
    // the region): a temporary file holding fewer (the server's write ran out of
    // disk: a 300 s save needs about 115 MB of them) or an output that ends
    // short is a failed write, posted as one, so writeSlot never renames a
    // truncated file over the old one. openFiles (a List, from writeSlot)
    // gets every SoundFile it opens, so the caller can close them if an error
    // ends the routine; on any normal return they are closed here.
    interleaveFiles { arg sourcePaths, path, sampleRate, keepGoing, frames, openFiles;
        var chunkFrames = 8192, sources;
        var output, left, right, finished = true, written;
        var keys = this.interleaveKeys(chunkFrames);
        var opened = { arg file; if (file.notNil) { openFiles.add(file) }; file };

        openFiles = openFiles ?? { List.new };
        this.interleaveFaultHook.value(path, \start, openFiles);  // the engine check's fault, before any file opens
        sources = sourcePaths.collect({ arg sourcePath; opened.(SoundFile.openRead(sourcePath)) });
        if (sources.includes(nil).not and: { sources.any({ arg source; source.numFrames < frames }) }) {
            postln("strata: cannot write " ++ path ++ " (a temporary file holds % of % frames: is the disk full?)".format(
                sources.collect(_.numFrames).minItem, frames));
            sources.do({ arg source; source.close });
            ^false
        };
        // File.mkdir throws when the directory cannot be made; openWrite then fails below
        try { File.mkdir(path.dirname) };
        output = if (sources.includes(nil).not) { opened.(SoundFile.openWrite(path, "WAV", "int16", 2, sampleRate)) };
        if (output.isNil) {
            postln("strata: cannot write " ++ path);
            sources.do({ arg source; if (source.notNil) { source.close } });
            ^false
        };
        this.interleaveFaultHook.value(path, \open, openFiles);  // the engine check's fault, with every file open

        while { finished and: { left = this.freshReadArray(chunkFrames); sources[0].readData(left); left.size > 0 } } {
            right = this.freshReadArray(chunkFrames);
            sources[1].readData(right);
            // the last chunk is shorter: its own keys
            if (left.size != keys[0].size) { keys = this.interleaveKeys(left.size) };
            output.writeData(this.interleaveChunk(left, right, keys, int16Peak));
            // from the real time: a long save's chunks outlast a 1 ms wait
            this.yieldToCommands(writeChunkWait);
            finished = keepGoing.value;
        };
        output.close;
        sources.do({ arg source; source.close });
        if (finished.not) { ^false };
        // the output read back: a write that ran out of disk ends short
        written = opened.(SoundFile.openRead(path));
        written = written !? { arg file; var count = file.numFrames; file.close; count };
        if (written != frames) {
            postln("strata: cannot write " ++ path ++ " (% of % frames written: is the disk full?)".format(written, frames));
            ^false
        };
        ^true
    }
}
