### Fixed
- The engine check's Resonator level test no longer fails at random (#91): it takes the median RMS of 32 default Resonators instead of 8 (bound 0.07-0.22) and checks that 32 with a gain 3x too high stay above 0.22.
