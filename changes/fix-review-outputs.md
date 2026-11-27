### Fixed

- Silent preset reads restore both crow inputs’ modes and voltage ranges. A deferred voltage is discarded when its jack changes role or becomes the norns clock output.
- ER-301 and TELEXo notes get their complete set of ii messages at the queue boundary. Releasing the newest note during congestion restores the remaining note’s CV when room returns.
- Deselecting an nb player safely retires its delayed activation even when the player has its own deactivation hook.
