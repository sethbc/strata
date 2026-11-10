### Fixed

- The engine check's memory area no longer fails on a loaded machine or a CI runner because the cut synths ended their 50 ms fade before the probes met them: it holds them in their fade while the probes run (#209).
