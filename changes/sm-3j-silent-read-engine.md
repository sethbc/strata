### Fixed
- After a script or mod reads a PSET silently (`params:read(n, true)`; norns' own PARAMS menu reads with actions and never met this), the sound follows the PSET at once: the master filter, delay, reverb, shimmer, tape drift, effect bypasses, scale and tuning reach the engine as a read with actions sends them (each command once), instead of waiting until each param next moves (#965).
