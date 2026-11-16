// StrataOnsets.sc
// The onsets area (3.7): a transients pass over a slot (analyzeBuffer),
// its file, buf<n>.onsets in the settings folder, and its bufferOnsets
// poll. Lua turns the candidates into slices. See
// docs/notes/engine/onsets.md.

+ Engine_Strata {
    // The onsets area (order 180). Per slot, the analyzeBuffer commands
    // received (analyses, counted from 1 as Lua counts them); the chunks the
    // passes have read since alloc (chunks, for the check); a wait after
    // each chunk the check may set (chunkWait, nil on norns); stopped once
    // the engine frees, so a pass still running reports nothing
    strataAreaOnsets {
        ^(
            order: 180,
            allocState: {
                areaState[\onsets][\analyses] = Array.fill(numBuffers, 0);
                areaState[\onsets][\chunks] = 0;
                areaState[\onsets][\stopped] = false;
            },
            addCommands: { this.areaCall(\addOnsetsCommands) },
            stop: { areaState[\onsets][\stopped] = true }
        )
    }

    // A hop: the frames each energy is measured over, a power of two (the
    // pairwise sums of hopEnergies halve a chunk eight times). A candidate
    // is placed at its hop's first frame.
    onsetHopFrames { ^256 }

    // The most candidates a pass keeps: with the marker at 0, at most 64 slices
    onsetCandidates { ^63 }

    // The least time between two kept candidates (s)
    onsetGapSeconds { ^0.03 }

    // Frames per read: 64 hops
    onsetChunkFrames { ^16384 }

    // The least energy a candidate's hop holds (both channels' squares
    // summed): a mean square of 1e-6 (-60 dB) over the hop
    onsetFloor { ^1e-6 * this.onsetHopFrames }

    // The largest strength before scaling: a NaN or an infinity in the
    // audio never reaches the scaling
    onsetStrengthCeiling { ^1e9 }

    onsetsPath { arg index;
        ^this.allocSettingsDirectory +/+ ("buf" ++ (index + 1) ++ ".onsets")
    }

    bufferOnsetsPoll { ^areaState[\onsets][\poll] }

    // One float, as bufferSaveResult: (count * 2 + failed) * numBuffers +
    // slot index, where count is the slot's analysis (from 1) and failed 1
    // when no file was written for it
    bufferOnsetsValue { arg index, count, failed; ^((((count * 2) + failed.binaryValue) * numBuffers) + index).asFloat }

    addOnsetsCommands {
        // msg: slot index 0-7. An index out of range is ignored with one
        // line (the modulation area's fastModIndicesValid, as the notes
        // commands do)
        this.addCommand(\analyzeBuffer, "i", { arg msg;
            if (this.fastModIndicesValid(\analyzeBuffer, [[\slot, msg[1], numBuffers - 1]])) {
                this.areaCall(\analyzeSlot, msg[1]);
            };
        });

        // How an analysis ended: one message per analyzeBuffer, after its
        // file is in place, or failed (refused, overtaken by a change to the
        // slot, or not written). Not periodic; a value request resends the
        // last report (Lua acts on a slot's newest analysis only).
        areaState[\onsets][\poll] = this.addPoll(\bufferOnsets, {
            this.bufferOnsetsPoll.value ? 0.0
        }, false);
    }

    reportOnsets { arg index, count, failed;
        if (areaState[\onsets][\stopped].not) {
            this.bufferOnsetsPoll.update(this.bufferOnsetsValue(index, count, failed));
        };
    }

    // analyzeBuffer: count the analysis, refuse at once a slot with no
    // audio or one that records, else have the server write both channels'
    // valid region to temporary float files and run the pass on them in a
    // routine (runOnsetPass), as a save's first stage does (writeSlot)
    analyzeSlot { arg index;
        var state = areaState[\onsets], count, frames, change, tempPaths;
        if (this.validBuffer(index).not) { ^this };
        count = state[\analyses][index] + 1;
        state[\analyses][index] = count;
        frames = bufferFrames[index];
        if ((frames < 1) or: { this.slotRecording(index) }) { ^this.reportOnsets(index, count, true) };
        change = slotChanges[index];
        // deleteStaleParts' pattern (strata-buf*-*.wav) matches these names
        tempPaths = ["L", "R"].collect({ arg side;
            Platform.defaultTempDir +/+ "strata-buf%-%-onsets%-%.wav".format(index + 1, instanceTag, count, side)
        });
        buffersL[index].write(tempPaths[0], "wav", "float", frames, 0);
        buffersR[index].write(tempPaths[1], "wav", "float", frames, 0);
        fork({ this.areaCall(\runOnsetPass, index, count, change, frames, tempPaths) }, SystemClock);
    }

    // Inside a routine. Every step runs only while nothing changed the slot
    // (slotChanges: a load, a clear or a recording sent meanwhile wins) and
    // the engine runs; else the temporary files are deleted and the
    // analysis reports failed. An sclang error ends it the same way. Once
    // the file's rename is under way (writeOnsetsFile), the rename reports.
    runOnsetPass { arg index, count, change, frames, tempPaths;
        var state = areaState[\onsets], rate = bufferSampleRates[index], strengths, picks, handedOff = false;
        var current = { (slotChanges[index] == change) and: { state[\stopped].not } };
        var deleteTemporary = { tempPaths.do({ arg path; try { if (File.exists(path)) { File.delete(path) } } }) };
        try {
            context.server.sync;
            if (current.value) { strengths = this.onsetStrengths(tempPaths, frames, current) };
            deleteTemporary.value;
            if (strengths.notNil and: { current.value }) {
                picks = this.pickOnsets(strengths, ((this.onsetGapSeconds * rate) / this.onsetHopFrames).ceil.asInteger);
                handedOff = this.areaCall(\writeOnsetsFile, index, count, frames, rate, picks, change);
            };
        } { arg error;
            postln("strata: cannot analyze buffer % (%)".format(index + 1, error.class.name));
        };
        deleteTemporary.value;
        if (handedOff.not) { this.reportOnsets(index, count, true) };
    }

    // Inside a routine: each hop's strength over the two temporary files of
    // `frames` frames (a Signal, one value per whole hop; the last part
    // hop is left out), or nil once keepGoing answers false or a file
    // cannot be read. Read in chunks of onsetChunkFrames, each into a fresh
    // array (freshReadArray), waiting through yieldToCommands after each;
    // every step is a C primitive, none runs per sample (#131).
    onsetStrengths { arg paths, frames, keepGoing;
        var hop = this.onsetHopFrames, hops = frames div: hop, done = 0, going = true;
        var files = [SoundFile.openRead(paths[0]), SoundFile.openRead(paths[1])];
        var strengths, carry, left, right, size, energies, chunk;
        if (files.includes(nil)) {
            files.do({ arg file; if (file.notNil) { file.close } });
            ^nil
        };
        strengths = Signal.newClear(hops.max(1));
        protect {
            while { going and: { done < hops } } {
                left = this.freshReadArray(this.onsetChunkFrames);
                files[0].readData(left);
                right = this.freshReadArray(this.onsetChunkFrames);
                files[1].readData(right);
                areaState[\onsets][\chunks] = areaState[\onsets][\chunks] + 1;
                size = ((left.size.min(right.size)) div: hop).min(hops - done);
                if (size < 1) { going = false } {
                    energies = this.hopEnergies(left, size) + this.hopEnergies(right, size);
                    // before the first hop its own energy stands in, so it is never a candidate
                    carry = carry ?? { Signal.newClear(4) + energies[0] };
                    chunk = this.onsetChunkStrengths(energies, carry);
                    strengths.overWrite(chunk[0], done);
                    carry = chunk[1];
                    done = done + size;
                    this.yieldToCommands(areaState[\onsets][\chunkWait] ? 0);
                    going = keepGoing.value;
                };
            };
        } {
            files[0].close;
            files[1].close;
        };
        if (going.not and: { done < hops }) { ^nil };
        strengths[0] = 0;
        ^strengths
    }

    // The energy of each of the first `hops` hops of a mono chunk: its
    // samples squared, summed in pairs eight times over (copySeries of the
    // even and the odd elements, added), so each sum is a hop's (C
    // primitives; Signal's integral is one sum, not a running one)
    hopEnergies { arg chunk, hops;
        var width = this.onsetHopFrames, sums;
        if (chunk.size != (hops * width)) { chunk = chunk.copySeries(0, 1, (hops * width) - 1) };
        sums = chunk.squared;
        while { width > 1 } {
            sums = sums.copySeries(0, 2, sums.size - 2) + sums.copySeries(1, 3, sums.size - 1);
            width = width div: 2;
        };
        ^sums
    }

    // A chunk's hop strengths, and the last four hops' energies for the
    // next chunk. A hop is a candidate when its energy is above onsetFloor
    // and more than twice the mean of the four hops before it (carry holds
    // the four before this chunk). The mean counts as at least half the
    // floor, so the divide after silence is finite and a hop above the
    // floor there is a candidate. Its strength is the rise in level: log2
    // of the ratio, less 1 (the 2x threshold), so a hit after silence
    // (a ratio of 1e5 or more) and one inside a texture (a ratio of a few)
    // stay on one scale once the strongest is 1. Signal arithmetic only.
    onsetChunkStrengths { arg energies, carry;
        var size = energies.size, around = Signal.newClear(size + 4), before, ratio;
        around.overWrite(carry, 0);
        around.overWrite(energies, 4);
        before = around.copySeries(0, 1, size - 1) + around.copySeries(1, 2, size)
            + around.copySeries(2, 3, size + 1) + around.copySeries(3, 4, size + 2);
        ratio = energies.thresh(this.onsetFloor) / (before * 0.25).max(this.onsetFloor * 0.5);
        ^[(ratio.log2 - 1).max(0).min(this.onsetStrengthCeiling), around.copySeries(size, size + 1, size + 3)]
    }

    // The strongest onsetCandidates at least gapHops hops apart: the
    // strongest hop (Signal's peak), then the strongest of those left once
    // every hop nearer than gapHops is cleared, and so on (one step per
    // candidate kept, C primitives over the hops). Into arrays made once
    // with room for onsetCandidates: [frames, strengths, count], in the
    // order kept (strongest first). strengths is changed.
    pickOnsets { arg strengths, gapHops;
        var most = this.onsetCandidates, frames = Array.newClear(most), values = Array.newClear(most), count = 0;
        var strongest = strengths.peak, index, first, last;
        while { (count < most) and: { strongest > 0 } } {
            index = strengths.indexOf(strongest);
            if (index.isNil) { strongest = 0 } {
                frames[count] = index * this.onsetHopFrames;
                values[count] = strongest;
                count = count + 1;
                first = (index - gapHops + 1).max(0);
                last = (index + gapHops - 1).min(strengths.size - 1);
                strengths.overWrite(Signal.newClear((last - first) + 1), first);
                strongest = strengths.peak;
            };
        };
        ^[frames, values, count]
    }

    // The onsets file's text: the kept frames in ascending order, each
    // strength (three decimals, peakText) over the strongest's
    onsetsText { arg index, frames, rate, picks;
        var count = picks[2], kept = picks[0].copyRange(0, count - 1), order = kept.order;
        var strongest = picks[1][0] ? 1, strengths = picks[1].copyRange(0, count - 1)[order];
        ^"strata-onsets 1\nslot %\nframes %\nrate %\n".format(index + 1, frames.asInteger, rate.round.asInteger)
            ++ (["onsets"] ++ kept[order]).join(" ") ++ "\n"
            ++ (["strengths"] ++ strengths.collect({ arg value; this.peakText(value / strongest) })).join(" ") ++ "\n"
    }

    // Write the slot's onsets file through a .part renamed into place
    // (renameIntoPlace, the waveform area's mover), whose end reports:
    // written once the file is in place, failed when the rename failed or
    // the slot changed meanwhile (a file renamed into place after a change
    // is deleted: it describes audio the slot no longer holds). Returns
    // whether the rename is under way; false, reporting nothing, when the
    // .part cannot be written, a folder is in the way or the slot changed.
    writeOnsetsFile { arg index, count, frames, rate, picks, change;
        var path = this.onsetsPath(index).standardizePath, partPath = path ++ "." ++ instanceTag ++ "-" ++ count ++ ".part";
        var text = this.onsetsText(index, frames, rate, picks), file, written;
        try { File.mkdir(path.dirname) };
        written = try {
            file = File.new(partPath, "w");
            if (file.isOpen) { file.write(text); file.close; true } { false }
        } { false };
        // mv -f would move the file into a folder at the path, and succeed
        if (written.not or: { PathName(path).isFolder } or: { slotChanges[index] != change }) {
            if (written.not) { postln("strata: cannot write " ++ path) };
            try { if (File.exists(partPath)) { File.delete(partPath) } };
            ^false
        };
        this.renameIntoPlace(partPath, path, { arg moved;
            var kept = moved and: { slotChanges[index] == change };
            if (moved.not) { postln("strata: cannot move " ++ partPath ++ " to " ++ path) };
            if (moved and: { kept.not }) { try { File.delete(path) } };
            this.reportOnsets(index, count, kept.not);
        });
        ^true
    }
}
