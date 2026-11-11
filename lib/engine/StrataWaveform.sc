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
        // per slot: what the peaks file this engine last wrote holds
        // (peaksContent: frames, rate, the values as written), nil before one
        state[\written] = Array.newClear(numBuffers);
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
    // mv -f by the mover (renameIntoPlace: no fork of sclang, #210);
    // action runs once the rename has ended, only if nothing
    // changed the slot meanwhile (slotChanges; or, given current, a
    // function, while it answers true: a playable recording's arming, whose
    // take a stop may change meanwhile). A failed write posts why and
    // still runs action: a waveform is a view, never a reason to hold up
    // audio. rate is the slot's own, so frames / rate is what bufferState
    // reports at any file rate. What the file holds is kept (written), so a
    // refresh can tell when it would write the same (peaksUnchanged).
    writeSlotPeaks { arg index, frames, action, current;
        var state = areaState[\waveform], change = slotChanges[index], path = this.peaksPath(index).standardizePath;
        var generation, partPath, content = this.peaksContent(index, frames);
        var finish = { arg written;
            if (written.not) { postln("strata: cannot write " ++ path) };
            state[\written][index] = if (written) { content };
            if (current.notNil) { if (current.value) { action.value } } {
                if (slotChanges[index] == change) { action.value }
            };
        };
        state[\generation] = state[\generation] + 1;
        generation = state[\generation];
        partPath = path ++ "." ++ instanceTag ++ "-" ++ generation ++ ".part";
        if (this.writePeaksFile(index, content, generation, partPath).not) { ^finish.(false) };
        // mv -f would move the file into a folder at the path, and succeed
        if (PathName(path).isFolder) { File.delete(partPath); ^finish.(false) };
        this.renameIntoPlace(partPath, path, finish);
    }

    // The mover (#210, #217): one shell for the engine's life that renames
    // the .part files sclang writes into place, so a write never forks
    // sclang (a fork costs about 2.5 ms per 130 MB of sclang): every peaks
    // file (every peakRefreshSeconds while a slot records), and the files
    // area's saves and scratch takes (writeSlot). It starts with this
    // area's allocState (order 140, after the files area's): every write
    // that renames comes after alloc, and renameIntoPlace renames by
    // subprocess while there is none. sclang writes each rename to a FIFO
    // as three lines, the .part, the path and an acknowledgment file; the
    // shell runs mv -f for each, in order, then creates the acknowledgment,
    // or, for a failed mv whose .part is still there, creates the failure
    // file (moverFailPath) instead and then deletes the .part. sclang
    // opens its end read-write ("r+": it holds a reader too, so a mover
    // that died never SIGPIPEs sclang) and close-on-exec ("e": no
    // later child holds it open, so the mover ends on EOF when free closes
    // it). The FIFO's name goes as soon as the mover has opened it. Without a
    // mover (mkfifo failed, the mover died, a path holds a newline) a write
    // renames through a subprocess of its own, as before.
    peaksMoverPath {
        ^this.allocSettingsDirectory.standardizePath +/+ ("strata-peaks-mover." ++ instanceTag ++ ".part")
    }

    // How long a write waits on the mover before it renames by a
    // subprocess instead (s). The mover stays in use unless it is gone.
    peaksMoverTimeout { ^1 }

    // How often a write polls for the mover's acknowledgment (s), and
    // alloc for the FIFO's name to go; writeSlot waits as often for an
    // older rename to the same path (StrataFiles.sc)
    peaksMoverPollStep { ^0.002 }

    // How often a write that has renamed by subprocess (after
    // peaksMoverTimeout) polls for the mover's late acknowledgment (s)
    peaksMoverSlowPollStep { ^0.05 }

    // Renames the mover may hold unacknowledged: four (twelve lines), far
    // below a pipe's buffer, so a write to the FIFO never blocks sclang,
    // even with a mover that is stuck
    peaksMoverBacklog { ^4 }

    // A rename's acknowledgment file, and the file the mover creates
    // instead when its mv failed (the shell derives it from the
    // acknowledgment's name): named like a .part, so one a crash left goes
    // with deleteStaleParts
    peaksAckPath { arg partPath; ^partPath.drop(-5) ++ ".ack.part" }
    moverFailPath { arg partPath; ^partPath.drop(-5) ++ ".fail.part" }

    // The mover's process has ended (its exit action, or no /proc entry
    // for its pid where there is a /proc); a stopped or slow one has not
    peaksMoverGone { arg mover;
        ^mover[\exited] or: { File.exists("/proc/self") and: { File.exists("/proc/" ++ mover[\pid]).not } }
    }

    startPeaksMover {
        var fifo = this.peaksMoverPath, file;
        var mover = (alive: false, exited: false, freed: false, pending: 0, pid: nil, file: nil);
        // a failed mv fails the write only if the .part is still there (one
        // a timed-out write renamed by subprocess is gone): the failure file
        // first, then the .part goes, so a fallback that finds the .part
        // gone also finds the failure (or the poll has noted it). A failure
        // file that cannot be made leaves the .part, and the fallback's own
        // mv reports. The caller's finish posts a failure.
        var script = "rm -f -- \"$0\"; while IFS= read -r part && IFS= read -r path && IFS= read -r ack; do "
            ++ "if mv -f -- \"$part\" \"$path\" 2>/dev/null || [ ! -e \"$part\" ]; then : > \"$ack\"; "
            ++ "else : > \"${ack%.ack.part}.fail.part\" && rm -f -- \"$part\"; fi; done";
        areaState[\waveform][\mover] = mover;
        try { File.mkdir(fifo.dirname) };
        // a name left by an engine of an earlier sclang session (instanceTag
        // restarts with sclang)
        try { if (File.exists(fifo)) { File.delete(fifo) } };
        if (("mkfifo -m 600 " ++ fifo.shellQuote).systemCmd != 0) {
            postln("strata: no mover (cannot make " ++ fifo ++ "); peaks files, saves and scratch takes rename by subprocess");
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
            // the folder finds it once alloc is done. A name still there
            // then means a mover that never started reading: given up, as
            // one that cannot be opened is
            // Elapsed time, never the waits counted: norns allocs in a fork
            // that runs every allocState with no sync between, so it can be
            // behind schedule and run its late waits back to back
            if (thisThread.isKindOf(Routine)) {
                var started = Main.elapsedTime;
                while { File.exists(fifo) and: { (Main.elapsedTime - started) < this.peaksMoverTimeout } } { this.peaksMoverPollStep.wait };
                if (File.exists(fifo)) { this.abandonPeaksMover(mover, fifo, "it never opened " ++ fifo) };
            };
        } {
            this.abandonPeaksMover(mover, fifo, "cannot open " ++ fifo);
        };
    }

    // No mover for this engine: post why, remove the FIFO, end the shell;
    // every rename goes by subprocess
    abandonPeaksMover { arg mover, fifo, reason;
        postln("strata: no mover (" ++ reason ++ "); peaks files, saves and scratch takes rename by subprocess");
        mover[\alive] = false;
        mover[\file] !? { arg file; try { file.close } };
        mover[\file] = nil;
        try { File.delete(fifo) };
        ("kill " ++ mover[\pid]).unixCmd(nil, false);
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

    // Rename partPath to path, then finish.(written), once: through the
    // mover when it is alive, holds fewer than peaksMoverBacklog renames
    // and no path holds a newline (the lines would split), else by a
    // subprocess. Through the mover, written is true once its
    // acknowledgment is there, false once its failure file is. A write the
    // mover has not done within peaksMoverTimeout renames by subprocess
    // instead (finish runs then, never again); the rename stays counted
    // until the mover acknowledges it (its late mv finds no .part and says
    // nothing), so a stuck mover fills the backlog and is skipped, and one
    // that catches up is used again. Only a mover that is gone stops its use.
    renameIntoPlace { arg partPath, path, finish;
        var mover = areaState[\waveform][\mover], ackPath = this.peaksAckPath(partPath), started, finished = false;
        // moverFailed: the poll consumed the mover's failure file, so a
        // fallback that finds the .part gone knows the write was lost
        var failPath = this.moverFailPath(partPath), moverFailed = false;
        var partGone = { moverFailed.not and: { File.exists(failPath).not } };
        var usable = mover.notNil and: { mover[\alive] } and: { mover[\pending] < this.peaksMoverBacklog }
            and: { [partPath, path, ackPath].every({ arg each; each.includes($\n).not }) };
        var bySubprocess = { if (finished.not) { finished = true; this.renameBySubprocess(partPath, path, finish, partGone) } };
        if (usable and: {
            try { mover[\file].write(partPath ++ "\n" ++ path ++ "\n" ++ ackPath ++ "\n"); mover[\file].flush; true } { false }
        }) {
            mover[\pending] = mover[\pending] + 1;
            started = Main.elapsedTime;
            SystemClock.sched(this.peaksMoverPollStep, {
                case
                { mover[\freed] } { nil }  // the engine was freed: its actions are dropped
                { File.exists(ackPath) or: { File.exists(failPath) } } {
                    var written = File.exists(failPath).not;
                    moverFailed = written.not;
                    try { File.delete(if (written) { ackPath } { failPath }) };
                    mover[\pending] = mover[\pending] - 1;
                    if (finished.not) { finished = true; finish.(written) };
                    nil
                }
                { mover[\exited] } { mover[\pending] = mover[\pending] - 1; bySubprocess.value; nil }
                { finished } { this.peaksMoverSlowPollStep }  // renamed by subprocess: waiting for the acknowledgment
                { (Main.elapsedTime - started) >= this.peaksMoverTimeout } {
                    if (this.peaksMoverGone(mover)) { mover[\alive] = false };
                    bySubprocess.value;
                    this.peaksMoverSlowPollStep
                }
                { this.peaksMoverPollStep }
            });
        } {
            bySubprocess.value;
        };
    }

    // mv -f through unixCmd (asynchronous, but the fork holds sclang a few
    // ms). A failed mv whose .part is gone means the mover took it first (a
    // write that timed out on it): written is then partGone's answer
    // (renameIntoPlace's: the mover left no failure file), true without one
    renameBySubprocess { arg partPath, path, finish, partGone;
        ("mv -f " ++ partPath.shellQuote ++ " " ++ path.shellQuote).unixCmd({ arg exitCode;
            var written = exitCode == 0;
            if (written.not) {
                if (try { File.exists(partPath) } { true }) {
                    try { File.delete(partPath) }
                } {
                    written = partGone.value ? true;
                };
            };
            finish.(written);
        }, false);
    }

    // What a slot's peaks file of `frames` would hold, but its generation:
    // the frames and rate lines, then the values as the file writes them
    // (three decimals), from sclang's copy of the overview. Two files with
    // the same content draw the same waveform
    peaksContent { arg index, frames;
        var peaks = areaState[\waveform][\peaks][index].asArray.collect({ arg value; this.peakText(value) });
        ^["frames %\nrate %\n".format(frames.asInteger, bufferSampleRates[index].round.asInteger), "peaks " ++ peaks.join(" ")]
    }

    // true when the slot's peaks file is there and holds what one of
    // `frames` written now would (peaksContent): a loop recording's
    // refresh then writes nothing (#523)
    peaksUnchanged { arg index, frames;
        var written = areaState[\waveform][\written][index];
        ^written.notNil and: { written == this.peaksContent(index, frames) } and: { File.exists(this.peaksPath(index).standardizePath) }
    }

    // The peaks file's text (content: peaksContent), written to path; false
    // when it cannot be
    writePeaksFile { arg index, content, generation, path;
        var text = "strata-peaks 1\nslot %\n".format(index + 1) ++ content[0] ++ "generation %\n".format(generation)
            ++ content[1] ++ "\n";
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

    // The slot's overview of oldFrames put on a longer length of newFrames
    // (a playable recording that extends the slot, #313): read from the
    // peak buffer (a record synth canceled since the last read may have
    // written it), each new bin the largest of the old bins it covers,
    // zeros past the old audio, stored in sclang and the peak buffer; then
    // action, with the overview as it was (a FloatArray, which
    // storeSlotPeaks puts back). A reply that arrives after something
    // changed the slot stores nothing.
    shrinkSlotPeaks { arg index, oldFrames, newFrames, action;
        var points = this.waveformPoints, change = slotChanges[index];
        this.slotPeakBuffer(index).getn(0, points, { arg values;
            var before = FloatArray.newFrom(values);
            if (slotChanges[index] == change) { this.storeSlotPeaks(index, this.shrunkPeaks(values, oldFrames, newFrames)) };
            action.value(before);
        });
    }

    // values (waveformPoints bins over oldFrames) as bins over newFrames
    // (longer). Integers throughout, as spreadPeaks: new bin b covers the
    // old bins from floor(b * newFrames / oldFrames) up to, not including,
    // ceil((b + 1) * newFrames / oldFrames), and is 0 when the first of
    // them is past the last (the largest product, 65 x 14.4 million frames,
    // is under 2^31)
    shrunkPeaks { arg values, oldFrames, newFrames;
        var points = this.waveformPoints, shrunk = FloatArray.newClear(points);
        points.do({ arg bin;
            var from = (bin * newFrames) div: oldFrames;
            var to = ((((bin + 1) * newFrames) + oldFrames - 1) div: oldFrames).min(points);
            var largest = 0;
            if (from < points) { (to - from).do({ arg offset; largest = largest.max(values[from + offset]) }) };
            shrunk[bin] = largest;
        });
        ^shrunk
    }

    // Forget a slot's peaks: zeros, in sclang and the peak buffer. No file:
    // Lua draws nothing for an empty slot.
    clearSlotPeaks { arg index;
        areaState[\waveform][\peaks][index] = FloatArray.newClear(this.waveformPoints);
        this.slotPeakBuffer(index).zero;
    }
}
