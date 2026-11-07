// StrataPerformance.sc
// The performance area: the tier values (tier, bufferSeconds, maxGrains,
// historySeconds) every other area builds with. For now a stub that sets
// the standard tier's values, today's. See docs/notes/engine/performance.md.

+ Engine_Strata {
    // The standard tier's buffer length (s): Lua's S.constants.STANDARD_BUFFER_SECONDS
    standardBufferSeconds { ^16 }

    // The performance area (order 10): first, so the tier values are set
    // before any area allocates a buffer or builds a SynthDef with them
    strataAreaPerformance {
        ^(
            order: 10,
            allocState: {
                tier = \standard;
                bufferSeconds = this.standardBufferSeconds;
                maxGrains = 128;
                historySeconds = 16;
            }
        )
    }
}
