// StrataFiles.sc
// The files area: checking a file decodes before a load, writing a slot
// to a WAV (saveBuffer and the scratch takes) and deleting what an
// interrupted write left. See docs/notes/engine/files.md.

+ Engine_Strata {
    // The files area (order 50)
    strataAreaFiles {
        ^(
            order: 50,
            // the files a write interrupted by a crash or power cut left
            allocState: { this.deleteStaleParts }
        )
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
    // loads, while damage before the last block is caught. One chunk array
    // serves the whole file (the last read may run past `frames`).
    fileDecodes { arg file, frames;
        var remaining = frames, chunk = FloatArray.newClear(loadCheckFrames * file.numChannels), decoded;
        while { remaining > 0 } {
            file.readData(chunk);  // shrinks chunk to the samples decoded
            decoded = chunk.size div: file.numChannels;
            remaining = remaining - decoded;
            if ((decoded < loadCheckFrames) and: { remaining > 0 }) { ^remaining <= loadShortfallFrames };
        };
        ^true
    }

    scratchPath { arg index;
        ^scratchDir +/+ ("buf" ++ (index + 1) ++ ".wav")
    }

    // Delete the files a write interrupted by a crash or power cut left: the
    // .part files in scratchDir (scratch takes) and its parent (saveBuffer's
    // <date>-buf<n>.wav, in _path.audio/strata/ on norns), and writeSlot's
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

    // scratchDir and its parent, keeping only absolute directories below the
    // root: an empty or relative scratchDir ("", ".", "scratch/", whose
    // dirname is ".") would glob the working directory, and "" or "/" the
    // root. "~" is expanded; other paths are not standardized, since
    // standardizePath turns "." into the working directory.
    stalePartDirs {
        var dir = scratchDir.asString;
        if (dir.beginsWith("~")) { dir = dir.standardizePath };
        dir = dir.withoutTrailingSlash;
        ^[dir, dir.dirname].select({ arg each;
            each.beginsWith("/") and: { each.withoutTrailingSlash.size > 1 }
        })
    }

    // Write a slot's valid region to path as a stereo 16-bit WAV at the
    // content's sample rate, creating the directory. The server writes each
    // mono buffer to a temporary float file; sclang then interleaves them in
    // chunks (yielding between chunks) into a per-write
    // path.<instanceTag>-<n>.part file and renames it into place, so a
    // reader never sees a half-written file. Each write to a path gets a new
    // generation number: an older write still interleaving when a newer one
    // starts abandons (deleting its .part), so the newest write always wins
    // and two writes never mix. instanceTag keeps another engine instance's
    // files apart. Samples beyond ±1 (a take recorded at a level above 1)
    // are clipped symmetrically to ±int16Peak, never wrapped. Temporary
    // files are deleted in every case. Creates no synth nodes.
    writeSlot { arg index, path;
        var frames = bufferFrames[index];
        var sampleRate = bufferSampleRates[index];
        var generation, tempPaths, partPath;
        if (frames < 1) {
            postln("strata: buffer " ++ (index + 1) ++ " is empty; nothing written to " ++ path);
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
            var written;
            context.server.sync;
            written = current.value and: { this.interleaveFiles(tempPaths, partPath, sampleRate, current) };
            tempPaths.do({ arg tempPath; File.delete(tempPath) });
            // no yield between this check and the rename. The newest write
            // forgets its generation whether it succeeded or failed; an
            // abandoned one leaves the newer write's entry alone.
            if (current.value) {
                if (written) {
                    if (("mv -f " ++ partPath.shellQuote ++ " " ++ path.shellQuote).systemCmd == 0) {
                        postln("strata: wrote buffer " ++ (index + 1) ++ " to " ++ path);
                    } {
                        postln("strata: cannot move " ++ partPath ++ " to " ++ path);
                    };
                };
                writeGenerations.removeAt(path);
            };
            if (File.exists(partPath)) { File.delete(partPath) };
        }, SystemClock);
    }

    // Called inside a routine. Returns false (and writes nothing more) as
    // soon as keepGoing is false, i.e. a newer write to the same path began,
    // or when the output cannot be written.
    interleaveFiles { arg sourcePaths, path, sampleRate, keepGoing;
        var chunkFrames = 8192;
        var sources = sourcePaths.collect({ arg sourcePath; SoundFile.openRead(sourcePath) });
        var output, left, right, interleaved, finished = true;
        var peak = int16Peak, negativePeak = int16Peak.neg;

        // File.mkdir throws when the directory cannot be made; openWrite then fails below
        try { File.mkdir(path.dirname) };
        output = if (sources.includes(nil).not) { SoundFile.openWrite(path, "WAV", "int16", 2, sampleRate) };
        if (output.isNil) {
            postln("strata: cannot write " ++ path);
            sources.do({ arg source; if (source.notNil) { source.close } });
            ^false
        };

        left = FloatArray.newClear(chunkFrames);
        right = FloatArray.newClear(chunkFrames);
        while { finished and: { sources[0].readData(left); left.size > 0 } } {
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
            writeChunkWait.wait;
            finished = keepGoing.value;
        };
        output.close;
        sources.do({ arg source; source.close });
        ^finished
    }
}
