### Changed
- Development: every CI job has a timeout (15 minutes for the Lua job and each engine shard, 5 for the gathering job), so a hung runner no longer holds a pull request for hours; a test pins it.
