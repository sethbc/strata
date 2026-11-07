// StrataLoop.sc
// The loop area: where a buffer grain starts in its slot
// (\strataGrainBuf, grainBody in StrataGrainDefs.sc). For now a neutral
// hook: the whole valid region is the loop. See docs/notes/engine/grains.md.

+ Engine_Strata {
    // The loop area (order 100): no state, defs or commands yet
    strataAreaLoop {
        ^(order: 100)
    }

    // A buffer grain's start, as a fraction (0-1) of the slot's valid
    // region (validFrames frames). bufPos is the voice's position, scanPhase
    // the scan's offset (0-1, wrapping), spreadDraw the grain's position
    // jitter, rate its signed rate, durFrames the frames it reads; loopStart
    // and loopLength the loop as fractions of the region. Neutral (3.1's
    // rule): the position wrapped to 0-1, scaled to the frames a grain can
    // start in and still end inside the region (grainEndMargin short of its
    // end), so no grain reads the zeroed rest of the buffer.
    slotGrainPos { arg trig, bufPos, scanPhase, spreadDraw, rate, durFrames, validFrames, loopStart, loopLength;
        var startFrames = (validFrames - grainEndMargin - durFrames).max(0);
        ^(bufPos + scanPhase + spreadDraw).wrap(0, 1) * (startFrames / validFrames.max(1))
    }
}
