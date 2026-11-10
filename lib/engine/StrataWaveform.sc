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
            free: { areaState[\waveform][\peakBuffers].do({ arg buffer; buffer.free }) }
        )
    }

    // Points of a slot's peak curve (Lua's WAVEFORM_POINTS)
    waveformPoints { ^64 }

    allocWaveformState {
        var state = areaState[\waveform];
        state[\peakBuffers] = Array.fill(numBuffers, { Buffer.alloc(context.server, this.waveformPoints, 1) });
        state[\peaks] = Array.fill(numBuffers, { FloatArray.newClear(this.waveformPoints) });
        state[\generation] = 0;
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
    // mv -f through unixCmd (asynchronous, so sclang never waits on a
    // subprocess); action runs once the rename has ended, only if nothing
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
    // largest of the bins it covers, then run action. A reply that arrives
    // after something changed the slot stores nothing (it belongs to audio
    // the slot no longer holds), and action runs either way.
    readSlotPeaks { arg index, usedBins, action;
        var points = this.waveformPoints, change = slotChanges[index];
        this.slotPeakBuffer(index).getn(0, points, { arg values;
            if (slotChanges[index] == change) {
                areaState[\waveform][\peaks][index] = this.spreadPeaks(values, usedBins.clip(1, points));
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
