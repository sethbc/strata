// StrataRings.sc
// The rings area: each voice's ring and the input ring the grains read.
// For now a stub that registers the area and its constants.

+ Engine_Strata {
    // Seconds each voice's ring holds
    ringSeconds { ^4 }

    // Seconds the input ring holds beyond historySeconds (and one more)
    ringGuardSeconds { ^4 }

    // The rings area (order 70)
    strataAreaRings {
        ^(order: 70)
    }
}
