### Fixed
- The engine check's freeze area no longer fails on a slow machine when a copy lands before its voiceOff: it redoes the case's setup up to three times (#569). The local engine check's default timeout is 1800 s, so a full run has about 14 minutes to spare (#570).
