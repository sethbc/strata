# SCENES

The eight scenes and the scene sequencer on the screen. Back to [Screen Controls](../controls.md).

The page shows the eight slots in two columns (1-4 on the left, 5-8 on the right). Each slot has its number and a small box that is filled when the slot holds a scene. The current scene is bright (while a crossfade goes to it, it blinks until the crossfade lands) and a `>` marks the scene the sequencer is on while it runs. Below the slots are four fields in a 2x2 block: the transition time (`fade`), the sequencer on or off (`seq`), the sequence length (`len`) and the scene duration (`dur`).

| Control | Action |
|---------|--------|
| E2 | Move through the slots 1-8, then the four fields |
| E3 | On a slot: change the transition time. On a field: change that field (on `seq`, right turns it on and left turns it off). ALT+E3 adjusts finely |
| K2 | Recall the slot with the transition time (a fade) |
| K3 | Recall the slot at once |
| ALT+K3 | Save the current sound into the slot |

Saving into an empty slot happens at once. Saving into a slot that already holds a scene asks first: the hint row shows `K3 again: overwrite S<n>` (with ALT held or not), and a second ALT+K3 within 2 seconds saves; after 2 seconds the question goes from the hint row by itself. Moving the cursor cancels the question, so it never applies to another slot. A message from another page (a failed buffer load, say) never hides the question; while a message meant for every page covers the hint row, the next ALT+K3 asks again instead of saving. The question shows on this page only.

Recalling an empty slot does nothing. With an arc, pressing the ring button recalls the slot at once. See [Scenes and Automation](../scenes.md) for the scene system and saving and loading scenes on disk.
