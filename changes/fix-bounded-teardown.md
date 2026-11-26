### Fixed

- The engine check now reports which server reply went missing while stopping voices, freeing a test engine or cleaning up a shard. It retries a missing sync reply once and reports a failure after five seconds if the reply is still missing.
