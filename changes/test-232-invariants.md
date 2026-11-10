### Added
- Tests: modules register their state invariants (`S.register_invariant`), and the test harness checks every one after each unit test, failing the test that leaves one broken (#232). Seeded with the scene transition, the pattern clock, the grid's held keys, the norns keys' ALT presses, the buffer slots and the flash slots. Nothing changes on the device.
