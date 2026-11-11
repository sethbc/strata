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
    slotGrainPos { arg trig, bufPos, scanPhase, spreadDraw, rate, durFrames, validFrames, loopStart, loopLength, recHead;
        var reverse = rate < 0;
        var lowest = durFrames * reverse;
        var highest = (validFrames - grainEndMargin - (durFrames * (1 - reverse))).max(lowest);
        var first = loopStart.clip(0, 1);
        // max and min, never clip: on a control-rate receiver clip is a
        // Clip.kr, which reads the audio-rate bounds once per block (the
        // grain before's)
        var loopFirst = (first * validFrames).max(lowest).min(highest);
        var loopLast = ((first + loopLength.clip(0, 1)).min(1) * validFrames).max(loopFirst).min(highest);
        var frame = loopFirst + ((bufPos + scanPhase + spreadDraw).wrap(0, 1) * (loopLast - loopFirst));
        ^this.slotHeadGuard(frame, lowest, highest, rate, durFrames, recHead) / validFrames.max(1)
    }
}
