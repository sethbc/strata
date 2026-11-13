// StrataNotes.sc
// The notes area (3.5): each voice's eight note slots (slot 0 the voice's
// own note, 1-7 extra notes from a pool all voices share) and the four note
// commands. Lua allocates the slots and owns every value; the engine holds
// the bounds. Until the note lifecycle lands the commands are checked
// stubs: each validates its arguments, clips the continuous ones, records
// them and does nothing else. See docs/notes/engine/notes.md.

+ Engine_Strata {
    // Note slots per voice: 0 the voice's own note, 1-7 its extra notes. Lua's
    // S.constants.NOTE_SLOTS is the same number (a docs test compares them)
    noteSlots { ^8 }

    // The most extra notes the pool holds, across every voice (setNotePool's
    // size 0..notePoolMax). Lua's S.constants.NOTE_POOL.max is the same number
    notePoolMax { ^16 }

    // The lag (s) of every per-note control, smoothing Lua's 48 Hz steps
    noteLag { ^0.02 }

    // The notes area (order 170)
    strataAreaNotes {
        ^(
            order: 170,
            allocState: { this.allocNoteState },
            addCommands: { this.addNoteCommands }
        )
    }

    // areaState[\notes]: pool (how many extra notes the pool holds: 0 until
    // Lua sends setNotePool), slots (per voice an Array of noteSlots places,
    // nil while empty) and received (what each command last took, for the
    // engine check)
    allocNoteState {
        var state = areaState[\notes];
        state[\pool] = 0;
        state[\slots] = numVoices.collect({ Array.newClear(this.noteSlots) });
        state[\received] = IdentityDictionary.new;
    }

    // What a command took, for the engine check
    receiveNote { arg command, values;
        areaState[\notes][\received][command] = values;
    }

    // The four commands (design 3.5 §3.1). Each checks its indices, then
    // every continuous argument's finiteness, as 3.4's five fast-modulation
    // commands do and through the same checks (fastModIndicesValid and
    // fastModValuesFinite, StrataModulation.sc: a bad one of either is
    // ignored with one line, and the command does nothing), clips the
    // continuous arguments only then and records what it took. The Lua
    // engine stub reads the clips (name = msg[i].clip(...)) as its limits,
    // and its index limits from noteSlots and notePoolMax. They create no
    // node; setNotePool keeps the size.
    addNoteCommands {
        var lastVoice = numVoices - 1, lastSlot = this.noteSlots - 1;

        // Start voice's slot: note 0-127 (the scale reference), freq 8-20000
        // Hz, rate 0.25-4, velocity 0-1
        this.addCommand(\noteOn, "iiffff", { arg msg;
            var voice = msg[1], slot = msg[2], note, freq, rate, velocity;
            if (this.fastModIndicesValid(\noteOn, [[\voice, voice, lastVoice], [\slot, slot, lastSlot]])
                and: { this.fastModValuesFinite(\noteOn, [[\note, msg[3]], [\freq, msg[4]], [\rate, msg[5]], [\velocity, msg[6]]]) }) {
                note = msg[3].clip(0, 127); freq = msg[4].clip(8, 20000); rate = msg[5].clip(0.25, 4); velocity = msg[6].clip(0, 1);
                this.receiveNote(\noteOn, [voice, slot, note, freq, rate, velocity]);
            };
        });

        // End voice's slot: cut 0 releases it, 1 cuts it
        this.addCommand(\noteOff, "iii", { arg msg;
            var voice = msg[1], slot = msg[2], cut = msg[3];
            if (this.fastModIndicesValid(\noteOff, [[\voice, voice, lastVoice], [\slot, slot, lastSlot], [\cut, cut, 1]])) {
                this.receiveNote(\noteOff, [voice, slot, cut]);
            };
        });

        // Voice's slot's expression: bend a ratio 0.0625-16, amp a gain 0-2,
        // position, size and main offsets of -1..1 half ranges
        this.addCommand(\noteExpression, "iifffff", { arg msg;
            var voice = msg[1], slot = msg[2], bend, amp, position, size, main;
            if (this.fastModIndicesValid(\noteExpression, [[\voice, voice, lastVoice], [\slot, slot, lastSlot]])
                and: { this.fastModValuesFinite(\noteExpression, [[\bend, msg[3]], [\amp, msg[4]], [\position, msg[5]],
                    [\size, msg[6]], [\main, msg[7]]]) }) {
                bend = msg[3].clip(0.0625, 16); amp = msg[4].clip(0, 2);
                position = msg[5].clip(-1, 1); size = msg[6].clip(-1, 1); main = msg[7].clip(-1, 1);
                this.receiveNote(\noteExpression, [voice, slot, bend, amp, position, size, main]);
            };
        });

        // The pool: how many extra notes all voices share, 0..notePoolMax
        this.addCommand(\setNotePool, "i", { arg msg;
            var size = msg[1];
            if (this.fastModIndicesValid(\setNotePool, [[\size, size, this.notePoolMax]])) {
                areaState[\notes][\pool] = size;
                this.receiveNote(\setNotePool, [size]);
            };
        });
    }
}
