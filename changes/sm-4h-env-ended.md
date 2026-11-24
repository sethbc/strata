### Fixed
- An envelope (loop off) that has ended stays at 0 until its next hit when one of its times is lengthened after it ended: before, an envelope routed to a setting Strata follows (one that is not a voice's fast setting) could come back partway through its run, which the engine's envelope never does (#969).
