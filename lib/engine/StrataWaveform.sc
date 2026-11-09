// StrataWaveform.sc
// The waveform area: each slot's peak buffer and the hooks that keep it. The
// hooks are neutral here; 3.3's waveform package (1b) fills them. See
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

    // Write a slot's peaks file, then run action. Neutral: runs action at once
    writeSlotPeaks { arg index, frames, action;
        action.value;
    }

    // Read a slot's peaks file, then run action. Neutral: runs action at once
    readSlotPeaks { arg index, usedBins, action;
        action.value;
    }

    // Forget a slot's peaks. Neutral: nothing
    clearSlotPeaks { arg index;
    }
}
