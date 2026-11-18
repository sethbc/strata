// StrataScale.sc
// The scale area: the one tuning and scale every voice's grains quantize
// to, as a table of tuningTableFrames frames (scaleBuffer) that setScale,
// setTuning and setTuningTone fill, and the quantize step grainRate
// (StrataVariation.sc) applies to a grain's pitch. See
// docs/notes/engine/tuning.md.

+ Engine_Strata {
    // Every pitch class: quantize rounds to semitones (the scale off)
    chromaticMask { ^4095 }

    // The tuning's limits and the table's shape (3.8; lib/tuning.lua's
    // TUNING mirrors them, a docs test compares): 1-128 tones a period of
    // 100-4800 cents; a period this near octaveCents is an octave, where a
    // tuning of tuningTwelve tones takes the scale's mask; degree 0 sits on
    // key tuningRootKey + the root; the table's frames start at note
    // tuningTableLow, tuningTableResolution a semitone (-100 to 309.5:
    // every buffer voice's quantized pitch)
    tuningMaxTones { ^128 }
    tuningMinPeriod { ^100 }
    tuningMaxPeriod { ^4800 }
    octaveCents { ^1200 }
    tuningTwelve { ^12 }
    tuningOctaveTolerance { ^0.001 }
    tuningRootKey { ^60 }
    tuningTableFrames { ^4096 }
    tuningTableLow { ^-100 }
    tuningTableResolution { ^10 }

    // The scale area (order 80): allocState runs before every area's
    // addDefs, so grainRate reads the table's bufnum as a constant
    strataAreaScale {
        ^(
            order: 80,
            allocState: { this.areaCall(\allocScaleBuffer) },
            addCommands: { this.areaCall(\addScaleCommands) },
            free: { this.areaCall(\freeScaleBuffer) },
            // scaleNote is Lua's reference note; a buffer voice's grains
            // quantize around the rate it plays its slot at, so bufRate
            // moves the note the grain synth gets (scaleNoteFor)
            grainParamHandlers: (
                scaleNote: { arg voice, value;
                    areaState[\scale][\notes][voice] = value;
                    this.sendScaleNote(voice);
                    true
                },
                bufRate: { arg voice, value;
                    grainControls[voice][\bufRate] = value;
                    this.setSynth(this.grainKey(voice), \bufRate, value);
                    this.sendScaleNote(voice);
                    true
                }
            )
        )
    }

    // The scaleNote a voice's grain synth quantizes around: Lua's reference
    // note (setGrainParam scaleNote: a synth voice's freq, the root + 60 for
    // a buffer or input voice), plus, for a buffer slot, the semitones of its
    // bufRate, so a MIDI note (or any rate) transposes the voice without
    // moving the scale its grains land on
    scaleNoteFor { arg voice;
        var note = areaState[\scale][\notes][voice];
        if (grainSource[voice].inclusivelyBetween(1, numBuffers)) {
            note = note + (grainControls[voice][\bufRate] ? 1).max(0.001).ratiomidi;
        };
        ^note
    }

    // The scaleNote of a buffer voice's note playing its slot at rate (3.5):
    // Lua's reference note plus the semitones of that rate, as scaleNoteFor
    // gives the own note's from its bufRate
    noteScaleNote { arg voice, rate;
        ^areaState[\scale][\notes][voice] + rate.max(0.001).ratiomidi
    }

    // Keep and send a voice's scaleNote (scaleNoteFor), so a replacement
    // grain synth starts with it. Lua resends scaleNote after every source
    // switch, which recomputes it for the new source. A buffer voice's
    // extra notes each get their own (noteScaleNote of their rate); an input
    // voice's take the voice's
    sendScaleNote { arg voice;
        var note = this.scaleNoteFor(voice), notes = this.noteSynths(voice, \grain);
        grainControls[voice][\scaleNote] = note;
        this.setSynth(this.grainKey(voice), \scaleNote, note);
        if (notes.notEmpty) {
            this.sendToSynth(*this.extraNoteRecords.select({ arg record; notes.includes(record[\synth]) }).collect({ arg record;
                record[\synth].setMsg(\scaleNote, if (record[\kind] == \buffer) { this.noteScaleNote(voice, record[\rate]) } { note })
            }));
        };
    }

    // The tuning table (3.8, design §6.2): tuningTableFrames frames, frame
    // f the pitch (a fractional MIDI note) of the allowed tone nearest
    // tuningTableLow + f / tuningTableResolution, a tie going down. Its
    // bufnum never changes
    scaleBuffer { ^areaState[\scale][\buffer] }

    // The scale as setScale last set it: [root, mask]
    scaleRootAndMask { ^[areaState[\scale][\root], areaState[\scale][\mask]] }

    // The tuning as the last whole set left it: [tones (cents, the first
    // 0, ascending), period (cents)]
    tuningTonesAndPeriod { ^[areaState[\scale][\tones], areaState[\scale][\period]] }

    // Twelve equal steps, chromatic from C, until a change arrives (Lua's
    // defaults: scale off, root C, tuning 12 equal). The table goes with the
    // buffer's allocation, as its completion message
    allocScaleBuffer {
        var state = areaState[\scale];
        state[\notes] = Array.fill(numVoices, 60);  // Lua's reference notes (the grain defs' default)
        state[\root] = 0;
        state[\mask] = this.chromaticMask;
        state[\tones] = (0 .. (this.tuningTwelve - 1)) * (this.octaveCents div: this.tuningTwelve);
        state[\period] = this.octaveCents;
        state[\pending] = nil;
        state[\buffer] = Buffer.alloc(context.server, this.tuningTableFrames, 1,
            { arg buffer; this.tuningTableMsg(buffer.bufnum) });
    }

    freeScaleBuffer {
        areaState[\scale][\buffer].free;
    }

    validScaleRoot { arg root; ^root.isInteger and: { root >= 0 } and: { root <= 11 } }

    validScaleMask { arg mask; ^mask.isInteger and: { mask >= 1 } and: { mask <= this.chromaticMask } }

    // The tones the table lands on, in cents above degree 0: in a tuning of
    // twelve tones to an octave, those whose bit of mask is set (bit k:
    // degree k); in any other, every tone. A loop over the twelve tones,
    // never a function per tone
    tuningAllowed { arg tones, period, mask;
        var allowed, degree = 0;
        if ((tones.size != this.tuningTwelve) or: { (period - this.octaveCents).abs >= this.tuningOctaveTolerance }) {
            ^tones
        };
        allowed = List.new(this.tuningTwelve);
        while { degree < this.tuningTwelve } {
            if (mask.bitAnd(1 << degree) != 0) { allowed.add(tones[degree]) };
            degree = degree + 1;
        };
        ^allowed.asArray
    }

    // The table for a tuning (tones in cents, the first 0; period in cents),
    // root (0-11: degree 0 is key tuningRootKey + root) and mask, as a
    // Signal. Pure. Every per-frame step is a Signal primitive; the one
    // sclang loop is over the boundaries between neighboring allowed tones
    // (at most tuningMaxTones + 1), each a pass over every frame: a frame
    // above a boundary's midpoint takes the upper tone, one at it the lower
    tuningTable { arg tones, period, root, mask;
        var frames = this.tuningTableFrames, res = this.tuningTableResolution, low = this.tuningTableLow;
        var rootNote = this.tuningRootKey + root, allowed = this.tuningAllowed(tones, period, mask);
        var ext = [allowed.last - period] ++ allowed ++ [allowed.first + period];  // a tone either side of a period
        var keys = (0 .. (frames - 1));
        var cents = (Signal.newClear(frames).putEach(keys, keys) * (100 / res)) + ((low - rootNote) * 100);
        var periods = (((rootNote - low) * 100) / period).ceil + 1;  // whole periods that make every frame's cents positive
        var shifted = cents + (periods * period);
        var into = shifted.mod(period);                              // cents into the period
        var start = shifted - into - (periods * period);             // the period's start, cents from degree 0
        var tone = (into * 0) + ext[0], boundary = 0;
        while { boundary < (ext.size - 1) } {
            tone = tone + ((into - ((ext[boundary] + ext[boundary + 1]) / 2)).sign.max(0)
                * (ext[boundary + 1] - ext[boundary]));
            boundary = boundary + 1;
        };
        ^((start + tone) / 100) + rootNote
    }

    // The table as one /b_setn of every frame (an Array, never Buffer.setn,
    // whose setnMsgArgs adds every value in sclang): one message, so no
    // grain reads half a table
    tuningTableMsg { arg bufnum;
        var state = areaState[\scale], frames = this.tuningTableFrames;
        ^[\b_setn, bufnum, 0, frames] ++ this.tuningTable(state[\tones], state[\period], state[\root], state[\mask])
            .at((0 .. (frames - 1)))
    }

    sendTuningTable {
        context.server.listSendMsg(this.tuningTableMsg(this.scaleBuffer.bufnum));
    }

    // One console line for an ignored tuning command (the engine check
    // collects them through areaState[\scale][\postIgnored])
    postTuningIgnored { arg command, why;
        var line = "strata: % ignored: %".format(command, why), post = areaState[\scale][\postIgnored];
        if (post.notNil) { post.value(line) } { line.postln };
    }

    // The table for root (0-11, 0 = C) and mask (a 12-bit pitch-class set
    // from the root, 1-4095). Anything else is ignored: the scale stays
    setScale { arg root, mask;
        var state = areaState[\scale];
        if (this.validScaleRoot(root) and: { this.validScaleMask(mask) }) {
            state[\root] = root;
            state[\mask] = mask;
            this.sendTuningTable;
        };
    }

    // Begin a tuning of count tones (1 to tuningMaxTones) a period of period
    // cents (tuningMinPeriod to tuningMaxPeriod); its tones follow as
    // setTuningTone. Anything else is ignored with one line, and a set
    // already begun stays as it was
    setTuning { arg count, period;
        if ((count.isInteger and: { count >= 1 } and: { count <= this.tuningMaxTones }).not) {
            ^this.postTuningIgnored(\setTuning, "count % is not a whole number from 1 to %".format(count, this.tuningMaxTones))
        };
        if (period.isNaN or: { period.abs == inf } or: { period < this.tuningMinPeriod } or: { period > this.tuningMaxPeriod }) {
            ^this.postTuningIgnored(\setTuning, "period % is not from % to % cents".format(period, this.tuningMinPeriod,
                this.tuningMaxPeriod))
        };
        areaState[\scale][\pending] = (count: count, period: period, tones: Array.newClear(count), received: 0);
    }

    // Tone index (0 to count - 1) of the set setTuning began, in cents from
    // 0 to below the period; ignored with one line otherwise. The set's last
    // tone checks it (tone 0 is 0, each above the last): a whole set
    // replaces the tuning and the table, a broken one is dropped with one
    // line, the old tuning kept
    setTuningTone { arg index, cents;
        var state = areaState[\scale], pending = state[\pending], tones, degree = 1, ascending;
        if (pending.isNil) { ^this.postTuningIgnored(\setTuningTone, "no set begun (setTuning)") };
        if ((index.isInteger and: { index >= 0 } and: { index < pending[\count] }).not) {
            ^this.postTuningIgnored(\setTuningTone, "index % is not a whole number from 0 to %".format(index,
                pending[\count] - 1))
        };
        if (cents.isNaN or: { cents.abs == inf } or: { cents < 0 } or: { cents >= pending[\period] }) {
            ^this.postTuningIgnored(\setTuningTone, "cents % is not from 0 to below the period %".format(cents,
                pending[\period]))
        };
        tones = pending[\tones];
        if (tones[index].isNil) { pending[\received] = pending[\received] + 1 };
        tones[index] = cents;
        if (pending[\received] < pending[\count]) { ^this };
        state[\pending] = nil;
        ascending = tones[0] == 0;
        while { ascending and: { degree < tones.size } } {
            ascending = tones[degree] > tones[degree - 1];
            degree = degree + 1;
        };
        if (ascending.not) {
            ^this.postTuningIgnored(\setTuningTone, "the set's tones do not start at 0 and ascend: the tuning stays")
        };
        state[\tones] = tones;
        state[\period] = pending[\period];
        this.sendTuningTable;
    }

    addScaleCommands {
        this.addCommand(\setScale, "ii", { arg msg;
            this.setScale(msg[1], msg[2]);
        });
        this.addCommand(\setTuning, "if", { arg msg;
            this.setTuning(msg[1], msg[2]);
        });
        this.addCommand(\setTuningTone, "if", { arg msg;
            this.setTuningTone(msg[1], msg[2]);
        });
    }

    // A grain's offset (semitones from the voice's pitch) quantized: its
    // note n = scaleNote + 12 log2(pitchShift) + offset (scaleNote: the
    // voice's reference note, a fractional MIDI note) is read from the
    // tuning table at its nearest frame, q(n) = scaleBuffer[round((n -
    // tuningTableLow) * tuningTableResolution)] (Index clips past either
    // end), and the result is q(n) - scaleNote - 12 log2(pitchShift): the
    // grain lands on an allowed tone
    quantizedOffset { arg pitchShift, offset, scaleNote;
        var base = scaleNote + pitchShift.max(0.001).ratiomidi;
        var frame = ((base + offset) * this.tuningTableResolution) - (this.tuningTableLow * this.tuningTableResolution);
        ^Index.ar(this.scaleBuffer.bufnum, frame.round) - base
    }
}
