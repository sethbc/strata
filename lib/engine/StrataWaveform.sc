// StrataWaveform.sc
// The waveform area: each slot's overview of waveformPoints peaks, kept in
// sclang and in the slot's peak buffer, and its peaks file, buf<n>.peaks in
// the settings folder, which Lua reads to draw the slot. See
// docs/notes/engine/waveform.md.

+ Engine_Strata {
    // The waveform area (order 140)
    strataAreaWaveform {
        ^(
            order: 140,
            allocState: { this.allocWaveformState },
            free: {
                this.stopPeaksMover;
                areaState[\waveform][\peakBuffers].do({ arg buffer; buffer.free })
            }
        )
    }

    // Points of a slot's peak curve (Lua's WAVEFORM_POINTS)
    waveformPoints { ^64 }

    allocWaveformState {
        var state = areaState[\waveform];
        state[\peakBuffers] = Array.fill(numBuffers, { Buffer.alloc(context.server, this.waveformPoints, 1) });
        state[\peaks] = Array.fill(numBuffers, { FloatArray.newClear(this.waveformPoints) });
        state[\generation] = 0;
        this.startPeaksMover;
    }

    slotPeakBuffer { arg index;
        ^areaState[\waveform][\peakBuffers][index]
    }

    // A slot's peaks file: buf<n>.peaks in the settings folder this engine
    // used at alloc (allocSettingsDirectory, as stalePartDirs uses it: the
    // engine check restores settingsDir after each build, so
    // settingsDirectory would write into ~/dust)
    peaksPath { arg index;
        ^this.allocSettingsDirectory +/+ ("buf" ++ (index + 1) ++ ".peaks")
    }

    // A load's peaks become the slot's: sclang's copy (no other array: the
    // FloatArray the load's scan made) and the peak buffer (one /b_setn)
    storeSlotPeaks { arg index, peaks;
        areaState[\waveform][\peaks][index] = peaks;
        this.slotPeakBuffer(index).setn(0, peaks.asArray);
    }

    // A peak as the file writes it: three decimals, always
    peakText { arg value;
        var milli = (value.clip(0, 1) * 1000).round.asInteger;
        ^(milli div: 1000).asString ++ "." ++ (milli % 1000).asString.padLeft(3, "0")
    }

    // Write a slot's peaks file, then run action. The file goes to
    // <path>.<instanceTag>-<generation>.part and is renamed into place with
    // mv -f by the peaks mover (renamePeaksFile: no fork of sclang, #210);
    // action runs once the rename has ended, only if nothing
    // changed the slot meanwhile (slotChanges). A failed write posts why and
    // still runs action: a waveform is a view, never a reason to hold up
    // audio. rate is the slot's own, so frames / rate is what bufferState
    // reports at any file rate.
    writeSlotPeaks { arg index, frames, action;
        var state = areaState[\waveform], change = slotChanges[index], path = this.peaksPath(index).standardizePath;
        var generation, partPath;
        var finish = { arg written;
            if (written.not) { postln("strata: cannot write " ++ path) };
            if (slotChanges[index] == change) { action.value };
        };
        state[\generation] = state[\generation] + 1;
        generation = state[\generation];
        partPath = path ++ "." ++ instanceTag ++ "-" ++ generation ++ ".part";
        if (this.writePeaksFile(index, frames, generation, partPath).not) { ^finish.(false) };
        // mv -f would move the file into a folder at the path, and succeed
        if (PathName(path).isFolder) { File.delete(partPath); ^finish.(false) };
        this.renamePeaksFile(partPath, path, finish);
    }

    // The peaks mover (#210): one shell for the engine's life that renames
    // the peaks files sclang writes, so a refresh never forks sclang (a fork
    // costs about 2.5 ms per 130 MB of sclang, every peakRefreshSeconds
    // while a slot records). sclang writes each rename to a FIFO as two
    // lines, the .part and the path; the shell runs mv -f for each pair in
    // order. sclang opens its end read-write ("r+": it holds a reader too, so
    // a mover that died never SIGPIPEs sclang) and close-on-exec ("e": no
    // later child holds it open, so the mover ends on EOF when free closes
    // it). The FIFO's name goes as soon as the mover has opened it. Without a
    // mover (mkfifo failed, the mover died, a path holds a newline) a write
    // renames through a subprocess of its own, as before.
    peaksMoverPath {
        ^this.allocSettingsDirectory.standardizePath +/+ ("strata-peaks-mover." ++ instanceTag ++ ".part")
    }

    // How long a rename may wait on the mover before the write renames by a
    // subprocess and the mover is no longer used (s)
    peaksMoverTimeout { ^1 }

    // Lines the FIFO may hold unread: four renames, far below a pipe's
    // buffer, so a write to it never blocks sclang
    peaksMoverBacklog { ^8 }

    startPeaksMover {
        var fifo = this.peaksMoverPath, file;
        var mover = (alive: false, exited: false, freed: false, pending: 0, pid: nil, file: nil);
        var script = "rm -f -- \"$0\"; while IFS= read -r part && IFS= read -r path; do "
            ++ "mv -f -- \"$part\" \"$path\" 2>/dev/null || { rm -f -- \"$part\"; echo \"strata: cannot write $path\"; }; done";
        areaState[\waveform][\mover] = mover;
        try { File.mkdir(fifo.dirname) };
        // a name left by an engine of an earlier sclang session (instanceTag
        // restarts with sclang)
        try { if (File.exists(fifo)) { File.delete(fifo) } };
        if (("mkfifo -m 600 " ++ fifo.shellQuote).systemCmd != 0) {
            postln("strata: no peaks mover (cannot make " ++ fifo ++ "); peaks files rename by subprocess");
            ^this
        };
        // the shell's open blocks until sclang's end is open, then it removes the name
        mover[\pid] = ("exec sh -c " ++ script.shellQuote ++ " " ++ fifo.shellQuote ++ " < " ++ fifo.shellQuote).unixCmd({
            mover[\alive] = false;
            mover[\exited] = true;
        }, true);
        file = try { File(fifo, "r+e") };
        if (file.notNil and: { file.isOpen }) {
            mover[\file] = file;
            mover[\alive] = true;
            // alloc runs in a routine: wait (a few ms, at most 1 s) until the
            // mover has opened the FIFO and removed its name, so no listing of
            // the folder finds it once alloc is done
            if (thisThread.isKindOf(Routine)) {
                var waited = 0;
                while { File.exists(fifo) and: { waited < this.peaksMoverTimeout } } { 0.002.wait; waited = waited + 0.002 };
            };
        } {
            postln("strata: no peaks mover (cannot open " ++ fifo ++ "); peaks files rename by subprocess");
            try { File.delete(fifo) };
            ("kill " ++ mover[\pid]).unixCmd(nil, false);
        };
    }

    // Close sclang's end: the mover renames what it has read, then reads EOF and ends
    stopPeaksMover {
        var mover = areaState[\waveform][\mover];
        if (mover.isNil) { ^this };
        mover[\alive] = false;
        mover[\freed] = true;
        mover[\file] !? { arg file; try { file.close } };
        mover[\file] = nil;
    }

    // Rename partPath to path, then finish.(written): through the mover when
    // it is alive, has room and neither path holds a newline (the lines
    // would split), else by a subprocess. Through the mover, written is
    // true once the .part is gone (the mover posts a failure itself).
    renamePeaksFile { arg partPath, path, finish;
        var mover = areaState[\waveform][\mover], started;
        var usable = mover.notNil and: { mover[\alive] } and: { mover[\pending] < this.peaksMoverBacklog }
            and: { partPath.includes($\n).not } and: { path.includes($\n).not };
        if (usable and: {
            try { mover[\file].write(partPath ++ "\n" ++ path ++ "\n"); mover[\file].flush; true } { false }
        }) {
            mover[\pending] = mover[\pending] + 2;
            started = Main.elapsedTime;
            SystemClock.sched(0.002, {
                case
                { mover[\freed] } { nil }  // the engine was freed: its actions are dropped
                { File.exists(partPath).not } { mover[\pending] = mover[\pending] - 2; finish.(true); nil }
                { (Main.elapsedTime - started) >= this.peaksMoverTimeout } {
                    mover[\pending] = mover[\pending] - 2;
                    mover[\alive] = false;
                    this.renameBySubprocess(partPath, path, finish);
                    nil
                }
                { 0.002 }
            });
        } {
            this.renameBySubprocess(partPath, path, finish);
        };
    }

    // mv -f through unixCmd (asynchronous, but the fork holds sclang a few ms)
    renameBySubprocess { arg partPath, path, finish;
        ("mv -f " ++ partPath.shellQuote ++ " " ++ path.shellQuote).unixCmd({ arg exitCode;
            if (exitCode != 0) { try { if (File.exists(partPath)) { File.delete(partPath) } } };
            finish.(exitCode == 0);
        }, false);
    }

    // The peaks file's text, written to path; false when it cannot be
    writePeaksFile { arg index, frames, generation, path;
        var peaks = areaState[\waveform][\peaks][index].asArray.collect({ arg value; this.peakText(value) });
        var text = "strata-peaks 1\nslot %\nframes %\nrate %\ngeneration %\npeaks %\n".format(
            index + 1, frames.asInteger, bufferSampleRates[index].round.asInteger, generation, peaks.join(" "));
        var file;
        try { File.mkdir(path.dirname) };
        ^try {
            file = File.new(path, "w");
            if (file.isOpen) { file.write(text); file.close; true } { false }
        } { false }
    }

    // Read a slot's peak buffer (one /b_getn of 64 floats) into sclang: its
    // first usedBins bins spread over waveformPoints, each new bin the
    // largest of the bins it covers, then run action. A spread (usedBins
    // under waveformPoints) also goes back into the peak buffer, so sclang
    // and the buffer keep one overview. A reply that arrives after something
    // changed the slot stores nothing (it belongs to audio the slot no
    // longer holds), and action runs either way.
    readSlotPeaks { arg index, usedBins, action;
        var points = this.waveformPoints, change = slotChanges[index], used = usedBins.clip(1, points);
        this.slotPeakBuffer(index).getn(0, points, { arg values;
            if (slotChanges[index] == change) {
                if (used < points) {
                    this.storeSlotPeaks(index, this.spreadPeaks(values, used));
                } {
                    areaState[\waveform][\peaks][index] = this.spreadPeaks(values, used);
                };
            };
            action.value;
        });
    }

    // The first usedBins of values spread over waveformPoints bins. Integers
    // throughout, so a bin edge never lands a rounding away from its place.
    spreadPeaks { arg values, usedBins;
        var points = this.waveformPoints, spread = FloatArray.newClear(points);
        points.do({ arg bin;
            var from = (bin * usedBins) div: points;
            var to = (((bin + 1) * usedBins) + points - 1) div: points;  // the first old bin past the new one
            var largest = 0;
            (to - from).do({ arg offset; largest = largest.max(values[from + offset]) });
            spread[bin] = largest;
        });
        ^spread
    }

    // Forget a slot's peaks: zeros, in sclang and the peak buffer. No file:
    // Lua draws nothing for an empty slot.
    clearSlotPeaks { arg index;
        areaState[\waveform][\peaks][index] = FloatArray.newClear(this.waveformPoints);
        this.slotPeakBuffer(index).zero;
    }
}
