### Changed
- Development: the local SuperCollider 3.13 engine check (`test/run_engine_check_313.sh`) runs a full run as CI does, as the workflow's shards, each in a fresh sclang of its own, and a run passes only when every shard passed, so a long-lived sclang no longer crashes it (#581); `-1` keeps the old run in one sclang and `-l` lists the shards.
