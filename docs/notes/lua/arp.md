## Must not break

- **The list is the only thing the arpeggiator sends**, through `S.lib.variation`'s `send_intervals_now` (`interval1..8`, 0 past the list, then `intervalCount`): `M.list(voice, set)` orders what that function sends. Off, `list` gives the set as it is, so a voice that does not arpeggiate sends exactly 3.7's intervals; `arpOn` and `arpFold` are the record's (its grain key and its `sync`), and a default start sends both as 0 (the fixture allowances name them).
- **An arpeggiating voice's further notes are its list, never a slot** (`docs/notes/lua/notes.md`): on a running voice with the arpeggiator on and its own note held, `S.lib.notes.play` hands every further note, a step chord's `extra_only` ones included, to `M.hold`, which returns `NOTES.arp_slot` (0: truthy, never 1). A note with a region (a slice) keeps its slot: the list holds pitches alone. Turned on, the arpeggiator takes the voice's held extra notes (`S.lib.notes.take_extras`: cut, `noteOff` with cut 1) into the list; turned off, the list's notes go silent and sound again only when played again.
- **A held chord's list is sent once a step, and only when it changed** (2b's fix round 1): `hold`, a release, `release_owner`, `forget_owner`, `forget` and a new base (`own_note`) only mark the voice (as does every step while no own note's pitch is kept, #846); the LFO step hook (`START_ORDER.arp`) sends a marked running voice's list when it differs from the one the engine was last sent (`M.sent`, which `S.lib.variation`'s `send_intervals_now` calls at every send, a start's and a sync's included, so a restarted voice always gets its list). So the keys of one MIDI burst or one step's chord send the list once, 9 messages, at most one 48 Hz tick (about 21 ms) after the key that changed it, while each key's own note and accent go at once; a key struck again at its pitch, or a step's chord repeated unchanged, sends none. Seven voices given an eight-key chord in one step send at most 7 × 9 list messages at the next LFO step and none after, while their pitch is still; while a voice's pitch moves continuously (a `freq` scene fade, the morph or a macro on a voice holding a step chord) its list changes every step, so one list a voice goes out each 48 Hz tick. What a player hears of the wait: a changed chord takes effect within about a fiftieth of a second, and the grains a key itself fires at once (a triggered-mode voice's grain at its accent, a Karplus re-pluck's first grains) may still play the list as it was.
- **Each key the arpeggiator takes is a hit of the voice** (decision 1, the controller's ruling): `hold` sends `S.lib.engine_sync.retrigger(voice, velocity, "note")` unless the sequencer owns the note, a slot-1 hit, so each added key re-plucks a Karplus voice, fires a grain in triggered mode, opens a gated voice's gate and restarts a one-shot scan, which 3.7's `extra_note_hit` never did.
- **`interval prob` is not used while the arpeggiator is on**: the engine (`StrataVariation.sc`) steps every grain through the list while `arpOn` is 1 and ignores `intervalProb`; VOICE dims the row while it is on (#845: `LAYOUT.unused_levels`, `docs/notes/lua/pages/voice.md`), and the user page says so.
- **The note hooks hear each held note once**: `started` when it joins the list, `moved` when the same owner and key comes again, `ended` when it leaves (a release, `release_owner`, `forget_owner`, `forget`, the room's oldest giving way, the arpeggiator turned off, the voice's stop), each with the slot `NOTES.arp_slot`, through `S.lib.notes.run_note_hooks`. A note the arpeggiator takes when turned on keeps its start: `take_extras` forgets its slot's record with no `ended` and the list adds it with no `started`, so an external target (MIDI out, crow, nb) plays on, and its one `ended` comes when it leaves the list. `lib/io/targets.lua` keys played notes by owner and key and ignores the slot, so a MIDI chord reaches the external targets as a chord.
- **The own note never parks under the list** (its notes hold no slot, so `others_held` is false): lifting its key forgets its record while it sounds on, and the list keeps its pitch as the base until the next note on the free slot 1 is the own note and the new base (`M.own_note`, from `play_own`), from which the held steps are worked out again.
- **A hit only marks its voice** (the `voice_hit` hook `arp`, which never sends); the shuffle's resend is the LFO step hook's, installed once at `START_ORDER.arp`. Every resend is `ARP.max_steps + 1` messages, counted (`S.lib.engine_sync.count_sends`), at that step.
- The arpeggiator keeps nothing in a PSET or scene but its param: the held list, the base and the shuffle are state, never params.

## Machines

### arp list
- **State:** per voice, the mode (`v<i>_arp`, `M.on(voice)`, `M.mode(voice)`) and the held list (`entries[voice]`, oldest first, read with `M.held(voice)`), with the base (`bases[voice]`), the shuffle (`shuffles[voice]`, `shuffled_at[voice]`), the hit marks (`marked[voice]`) and the list the engine was last sent (`remembered[voice]`, `M.sent`) and whether it is due again (`pending[voice]`). The states: `off`, `on, empty` (no note in the list) and `on, holding`.
- **Invariant:** `arp`: only a running arpeggiating voice holds notes in its list, at most `ARP.max_steps - 1`, each owner and key once and none also in a slot of `S.lib.notes`.
- **Two facts:** `bases[voice] == nil` is both "no own note's pitch kept" and "check the held chord's list at every LFO step" (#846: the base is then the voice's pitch now, which a freq turn, a scene or a step moves).
- **Test:** `test/unit/arp_test.lua`: "C-E-G held by MIDI on a running arpeggiating voice: intervals 0, 4, 7, count 3; play returns 1, 0, 0; no noteOn on slots 2-8; pool_used 0", "turned on with two extra notes sounding: noteOff cut on both slots, their pitches in the list", "turned off: intervalCount 0 with no set; the held keys silent until played again", "a held chord takes at most eight steps, the own note's included", "the note hooks' starts and ends balance across the arpeggiator's paths". A table and no transition test.

A further note is one `S.lib.notes.play` hands the list: on a running voice whose own note is held (an `extra_only` one too), never one with a region. A stopped voice is `off` or `on, empty`: its stop clears the list (the invariant), and a play on it takes slot 1, so it gets no further note.

| State | Event | Next | Effect |
|---|---|---|---|
| `off` | `turned on, extra notes held` | `on, holding` | `take_extras`: each cut (`noteOff` with cut 1) and moved into the list with no `ended`; marked |
| `off` | `turned on, none held` | `on, empty` | nothing taken; `arpOn` 1, `arpFold`, the intervals |
| `off` | `a further note` | `off` | it is a slot's (`docs/notes/lua/notes.md`) |
| `on, empty` | `a further note` | `on, holding` | held (`started`), marked; a hit unless the sequencer's |
| `on, empty` | `turned off` | `off` | `arpOn` 0, `arpFold`, the intervals as the set gives them |
| `on, empty` | `the voice's stop` | `on, empty` | the base and the shuffle go |
| `on, holding` | `a further note` | `on, holding` | joins (the same owner and key re-pitched; past the room the oldest leaves); marked |
| `on, holding` | `release, others held` | `on, holding` | it leaves (`ended`); marked |
| `on, holding` | `release of the last held` | `on, empty` | it leaves; marked: the list goes back to the set |
| `on, holding` | `the own note played` | `on, holding` | the new base; marked when it moved |
| `on, holding` | `the LFO step, marked` | `on, holding` | the list sent once (`ARP.max_steps + 1` messages, counted) when it differs from `remembered` |
| `on, holding` | `turned off` | `off` | cleared, each note's `ended` heard, nothing cut (the list's notes go silent); the intervals resent |
| `on, holding` | `the voice's stop` | `on, empty` | cleared, nothing sent |

## lib/arp.lua (`S.lib.arp`)

3.8, package 2b (design §4.3, §11, §12). Included right after `lib/notes.lua`; nothing reads `S.lib.arp` at include time.

`M.ARP`: `name` (`"arp"`, the param's key and the record's name), `section` (`"grain"`, VOICE's), `modes` (`off`, `up`, `down`, `up-down`, `shuffle`), `mode_index` (`off` 1, `up` 2, `down` 3, `up_down` 4, `shuffle` 5), `shuffle_seconds` (4), `max_steps` (`S.constants.NOTE_SLOTS`, 8: the engine's `interval1..8`).

### The param

`v<i>_arp`, an option of `ARP.modes`, default off: one registered voice-param record, `arp`.
- Its grain key sends `arpOn` (1 for any mode but off; `carry = false`) through `send_param_to_engine`, while the voice runs.
- Its action (turned on: the held extra notes taken; off: the list cleared), then, on a running voice, `arpFold` (1 for up-down) and the intervals again (`S.lib.variation.send_intervals`). The record's `sync` sends `arpFold` at a start, before `voiceOn`, and at a running voice's sync.
- A scene key, discrete `{1, 5}` (switched at a transition's end), `scene_defaults` `{arp = 1}`. No fader, no randomize, no mutation.
- VOICE: a row in the grain section after 1c's (`voice_rows`); its `layout_states` draw each voice on each mode, the cursor on the row, the pan wander above it at 100 %.

### The list

`M.list(voice, set)`: off, `set` itself. On, the steps are the held chord's when any note is held (`{0}`, the own note, then each held pitch less the base, fractional semitones in a tuning that is not twelve equal), else `set` (the interval set; `S.lib.tuning.chord()` for the chord set), at most `ARP.max_steps`, ordered: ascending for up and up-down (the engine folds it, `arpFold`), descending for down, the voice's current shuffle for shuffle. The shuffle is a permutation of the steps' places, drawn again when its length changes, at a marked hit and at least every `ARP.shuffle_seconds`. A list of fewer than two steps is never reshuffled. A scale, root or tuning change resends a chord-set voice's list through `S.lib.variation`'s `send_chords` (`tuning_changed`); a held chord keeps its pitches as they were played (as extra notes do), so a tuning change leaves its steps.

### The held chord

- `M.hold(voice, played)`: `played` is `S.lib.notes.play`'s checked note. The same owner and key again is re-pitched in place; a new note past the room (`ARP.max_steps - 1` beside the own note) takes the oldest one's place. The voice is marked for the step's send (above), and a note that is not the sequencer's accents the voice (`S.lib.engine_sync.retrigger`, source `note`: a step's chord is its step's hit). Returns `NOTES.arp_slot`.
- `M.release(voice, owner, key) -> boolean` (marked for the step's send when one left), `M.release_owner(voice, owner)`, `M.forget_owner(voice, owner)` (the same: the list holds no slot to release); `S.lib.notes`' `release`, `forget` (when `find` fails), `release_owner`, `forget_owner`, `release_all` and the voice-stop hook reach them.
- `M.clear(voice)`: every held note goes, sending nothing (the voice's stop, the arpeggiator turned off), with the base and the shuffle.
- `M.held(voice)`: copies of the held notes, oldest first, `{owner, key, pitch, velocity}`.
- `M.on(voice)`, `M.mode(voice)` (the mode's name), `M.own_note(voice, pitch)` (the own note played: the new base; a held chord marked when it moved), `M.sent(voice, list)` (`send_intervals_now`'s record of what the engine holds).
- The base is slot 1's note's pitch whenever one is there, kept after its record goes, else the voice's pitch now (`S.lib.notes.own_pitch`). With no own note's pitch kept (a step chord's further notes on a voice holding no slot), the LFO step hook checks the held chord's list at every step and sends it when it differs (#846), so a `freq` turn, a scene or a step that moves the voice's pitch re-measures the chord from the new pitch within a tick, and the chord keeps its pitches; an unchanged pitch sends nothing.

### MAIN's count

MAIN's held-note count (`S.lib.notes.held`, from two: `1+ reso 3`) counts the voice's slots only, its own note and its extra notes, so it leaves the list's notes out: an arpeggiating voice holding a chord shows no count (the user page says so).

### Per-note expression

A note in the list holds no slot, so `S.lib.notes.find` does not find it and `lib/expression.lua` drops its per-note expression (MPE bend, pressure, slide): one grain stream has one expression, the own note's.

### Registrations

- The record `arp` (above).
- `S.register_voice_hit({name = "arp"})`: marks the voice.
- The start step `arp` (`START_ORDER.arp`, 112): the shuffle's hook joins the LFO clock's step hooks once (`S.lib.lfos.on_step`); it sends nothing. No cleanup step: it keeps no clock.
- The invariant `arp`: only a running arpeggiating voice holds notes in its list, at most `ARP.max_steps - 1`, each owner and key once and none also in a slot.

Tests: `test/unit/arp_test.lua` (the options and sends; the list in each mode; a custom set; intervals off; a scale and a tuning change; MIDI's chord, its release and latch, the own note lifted, turned on over extra notes and off, MIDI out through the hooks, a 19-tone tuning, MPE, the room, a freq turn with no own note kept (#846); the hooks' balance; the shuffle and its hook), the seam in `test/unit/notes_test.lua`, a step's chord in `test/unit/sequencer_test.lua`, a latched key struck again in `test/unit/midi_in_test.lua`.
