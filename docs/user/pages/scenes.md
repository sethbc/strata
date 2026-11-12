# SCENES

The sixteen scenes, their names and the scene sequencer on the screen. Back to [Screen Controls](../controls.md).

The sixteen scene slots are in two banks of eight: scenes 1-8 and scenes 9-16. The page shows one bank at a time, in two columns (1-4 and 5-8, or 9-12 and 13-16): the bank of the slot under the cursor, and while the cursor is on a field, the bank it showed last. Each slot has its number, a small box that is filled when the slot holds a scene, and its name, if you gave it one (a long name is cut to fit). The current scene is bright (while a crossfade goes to it, it blinks until the crossfade lands) and a `>` before the name marks the scene the sequencer is on while it runs. Below the slots are four fields in a 2x2 block: the transition time (`fade`), the sequencer on or off (`seq`), the sequence length (`len`, up to 16) and the scene duration (`dur`).

| Control | Action |
|---------|--------|
| E2 | Move through the slots 1-16, then the four fields |
| ALT+E2 | On a slot, jump to the same place in the other bank (slot 3 to slot 11, and back); where there is no slot eight away (right from slot 13, left from slot 3) it does nothing. On a field it moves one step, as E2 |
| E3 | On a slot: change the transition time. On a field: change that field (on `seq`, right turns it on and left turns it off). ALT+E3 adjusts finely |
| K2 | Recall the slot with the transition time (a fade) |
| K3 | Recall the slot at once |
| ALT+K2 | Name the slot (when you let K2 go) |
| ALT+K3 | Save the current sound into the slot |

The hint row on an empty slot reads `empty  ALT+K3:save` (K2 and K3 recall nothing there; they flash `S<n> empty` in the header, as a grid's recall key does). With K1 held the hint offers `K2:name K3:save` on a slot and neither on a field. Saving into an empty slot happens at once. Saving into a slot that already holds a scene asks first: the hint row asks, naming the keys that answer (`K3 again: overwrite S<n>` while ALT is held, `ALT+K3: overwrite S<n>` once ALT is up), and a second ALT+K3 within 2 seconds saves (a plain K3 still recalls the slot, so it overwrites nothing); after 2 seconds the question goes from the hint row by itself. Moving the cursor cancels the question, so it never applies to another slot. A message from another page (a failed buffer load, say) never hides the question; while a message meant for every page covers the hint row, the next ALT+K3 asks again instead of saving. The question shows on this page only.

## Naming a slot

Hold K1, press K2 and let it go: norns' text entry opens, headed `scene <n> name` and starting from the slot's name. E2 picks a letter and K3 adds it; E3 moves down to `DEL` and `OK` (E2 picks between them, K3 deletes or finishes). `OK` names the slot; K2 cancels and keeps the old name. A name is up to 12 characters of plain letters, digits, spaces and punctuation (anything longer is cut, and other characters are left out). An empty slot can be named too, and a slot keeps its name when you save a scene into it. The name is written to disk at once, with the scenes. The header's messages about a slot carry its name: `saved S3 dusk`, `S3 dusk empty`, `S3 dusk not on disk` (the header's `S3` indicator keeps the number alone). If you open the norns menu while the text entry is open and name something there (a PSET, say), the slot's name entry is dropped when the menu closes: the slot keeps its old name and the page works as before.

Recalling an empty slot does nothing. With an arc, pressing the ring button recalls the slot at once. See [Scenes and Automation](../scenes.md) for the scene system and saving and loading scenes on disk.
