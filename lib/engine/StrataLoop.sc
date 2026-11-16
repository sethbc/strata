// StrataLoop.sc
// The loop area: where a buffer grain starts in its slot
// (\strataGrainBuf, grainBody in StrataGrainDefs.sc). The voice's loop
// (loopStart, loopLength: grain params, fractions of the slot's valid
// region) is where its grains start; bufPos, the scan and the spread move
// through the loop and wrap inside it. See docs/notes/engine/loops.md.

+ Engine_Strata {
    // The loop area (order 100): no state, defs or commands. loopStart and
    // loopLength are plain grain params (setGrainParam keeps and sends them)
    strataAreaLoop {
        ^(order: 100)
    }

    // The largest bufPos slotGrainPos takes: under 1, which the wrap maps
    // to 0 (one millionth of the loop from its last start)
    lastLoopPosition { ^0.999999 }

    // A buffer grain's start, as a fraction (0-1) of the slot's valid
    // region (validFrames frames). bufPos is the voice's position, scanPhase
    // the scan's offset (0-1, wrapping), spreadDraw the grain's position
    // jitter, rate its signed rate, durFrames the frames it reads; loopStart
    // and loopLength the loop as fractions of the region.
    //   start = loopStart + ((bufPos + scan + spreadDraw) wrap 0..1) x loopLength
    // in frames, inside the starts that keep the grain in the region: a
    // forward grain starts in [0, validFrames - grainEndMargin - durFrames]
    // (it ends inside the region, so it never reads the zeroed rest of the
    // buffer), a reverse one (rate < 0) in [durFrames, validFrames -
    // grainEndMargin] (it ends at or after frame 0, so it never wraps into
    // the rest). The loop is cut to those starts: a grain starts inside the
    // loop and may play past its end, but never past the region; a loop
    // with no room left (at the region's end, shorter than a grain) starts
    // its grains at the nearest start that fits. loopStart 0 and loopLength
    // 1 give 3.1's starts (the position scaled to the forward starts).
    // durFrames is at most validFrames - grainEndMargin (slotGrainReader caps
    // the duration), so both ranges hold at least one start.
    // rate is the read rate in slot frames per output frame (signed), what
    // the direction test and the head guard need. The legal range depends
    // on the grain's own direction and frames, which the variation area
    // draws per grain at audio rate, so the loop's first and last start are
    // clipped to it at audio rate: the bounds of the trigger's own sample,
    // where GrainBuf latches the grain.
    // recHead (the slot's head bus, StrataRecord.sc): the record area's
    // guard (slotHeadGuard) sees the frame and its lowest and highest legal
    // starts, and has the last word on where the grain starts.
    // 3.7: state (slotScanState, StrataPositions.sc; nil for 3.6's starts)
    // is the scan's mode and its span: a note's region in the loop's place
    // while regionLength > 0 (slotSpan), cut to the legal starts as the loop
    // is, and the position in it by the mode (slotScanPosition).
    slotGrainPos { arg trig, bufPos, scanPhase, spreadDraw, rate, durFrames, validFrames, loopStart, loopLength, recHead, state;
        var reverse = rate < 0;
        var lowest = durFrames * reverse;
        var highest = (validFrames - grainEndMargin - (durFrames * (1 - reverse))).max(lowest);
        var span = if (state.isNil) { this.slotSpan(loopStart, loopLength) } { [state[\first], state[\last]] };
        // max and min, never clip: on a control-rate receiver clip is a
        // Clip.kr, which reads the audio-rate bounds once per block (the
        // grain before's)
        var loopFirst = (span[0] * validFrames).max(lowest).min(highest);
        var loopLast = (span[1] * validFrames).max(loopFirst).min(highest);
        // bufPos 1 is the loop's last start, not its first: the position
        // stays just under 1, which the wrap maps to 0 (the scan and the
        // spread still wrap past it)
        var frame = loopFirst + (this.slotScanPosition(bufPos, scanPhase, spreadDraw, state) * (loopLast - loopFirst));
        ^this.slotHeadGuard(frame, lowest, highest, rate, durFrames, recHead) / validFrames.max(1)
    }

    // The span a buffer grain starts in, [first, last] fractions of the
    // valid region: the loop (loopStart, loopLength) or, while regionLength
    // > 0 (3.7: a note's region, design §3.4), the region (regionStart,
    // regionLength), each clipped 0-1, the last at most 1. Without a region
    // (nil) the loop's, as 3.6 computed it
    slotSpan { arg loopStart, loopLength, regionStart, regionLength;
        var first = loopStart.clip(0, 1), length = loopLength.clip(0, 1), inRegion;
        if (regionLength.notNil) {
            inRegion = regionLength > 0;
            first = Select.kr(inRegion, [first, regionStart.clip(0, 1)]);
            length = Select.kr(inRegion, [length, regionLength.clip(0, 1)]);
        };
        ^[first, (first + length).min(1)]
    }
}
