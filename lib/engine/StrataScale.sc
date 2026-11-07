// StrataScale.sc
// The scale area: the one scale every voice's grains quantize to, as a
// 12-frame buffer (scaleBuffer) that setScale fills, and the quantize step
// grainRate (StrataVariation.sc) applies to a grain's pitch. See
// docs/notes/engine/variation.md.

+ Engine_Strata {
    // Every pitch class: quantize rounds to semitones (the scale off)
    chromaticMask { ^4095 }

    // The scale area (order 80): allocState runs before every area's
    // addDefs, so grainRate reads the buffer's bufnum as a constant
    strataAreaScale {
        ^(
            order: 80,
            allocState: { this.allocScaleBuffer },
            addCommands: { this.addScaleCommands },
            free: { this.freeScaleBuffer },
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

    // Keep and send a voice's scaleNote (scaleNoteFor), so a replacement
    // grain synth starts with it. Lua resends scaleNote after every source
    // switch, which recomputes it for the new source
    sendScaleNote { arg voice;
        var note = this.scaleNoteFor(voice);
        grainControls[voice][\scaleNote] = note;
        this.setSynth(this.grainKey(voice), \scaleNote, note);
    }

    // 12 frames, one per pitch class (0 = C): the semitones from that pitch
    // class to the nearest tone of the scale (0 for a tone). Its bufnum
    // never changes
    scaleBuffer { ^areaState[\scale][\buffer] }

    // The scale as setScale last set it: [root, mask]
    scaleRootAndMask { ^[areaState[\scale][\root], areaState[\scale][\mask]] }

    // Chromatic until setScale arrives (Lua's default: scale off, root C)
    allocScaleBuffer {
        var state = areaState[\scale];
        state[\notes] = Array.fill(numVoices, 60);  // Lua's reference notes (the grain defs' default)
        state[\root] = 0;
        state[\mask] = this.chromaticMask;
        state[\offsets] = this.scaleOffsets(0, this.chromaticMask);
        state[\buffer] = Buffer.alloc(context.server, 12, 1,
            { arg buffer; buffer.setnMsg(0, state[\offsets]) });
    }

    freeScaleBuffer {
        areaState[\scale][\buffer].free;
    }

    // Per pitch class 0-11, the offset (-6..6 semitones) to the nearest
    // pitch class of the scale, where bit k of mask is the pitch class k
    // semitones above root. A tie goes down
    scaleOffsets { arg root, mask;
        var inScale = { arg pitchClass; mask.bitAnd(1 << ((pitchClass - root) % 12)) != 0 };
        var candidates = [0] ++ (1..6).collect({ arg distance; [distance.neg, distance] }).flatten;
        ^12.collect({ arg pitchClass;
            candidates.detect({ arg offset; inScale.((pitchClass + offset) % 12) })
        })
    }

    validScaleRoot { arg root; ^root.isInteger and: { root >= 0 } and: { root <= 11 } }

    validScaleMask { arg mask; ^mask.isInteger and: { mask >= 1 } and: { mask <= this.chromaticMask } }

    // Fill scaleBuffer for root (0-11, 0 = C) and mask (a 12-bit pitch-class
    // set from the root, 1-4095). Anything else is ignored: the scale stays
    setScale { arg root, mask;
        var state = areaState[\scale];
        if (this.validScaleRoot(root) and: { this.validScaleMask(mask) }) {
            state[\root] = root;
            state[\mask] = mask;
            state[\offsets] = this.scaleOffsets(root, mask);
            state[\buffer].setn(0, state[\offsets]);
        };
    }

    addScaleCommands {
        this.addCommand(\setScale, "ii", { arg msg;
            this.setScale(msg[1], msg[2]);
        });
    }

    // A grain's offset (semitones from the voice's pitch) quantized: its
    // note n = scaleNote + 12 log2(pitchShift) + offset (scaleNote: the
    // voice's reference note, a fractional MIDI note) becomes
    // q(n) = round(n) + scaleBuffer[round(n) mod 12], and the result is
    // q(n) - scaleNote - 12 log2(pitchShift): the grain lands on a scale tone
    quantizedOffset { arg pitchShift, offset, scaleNote;
        var base = scaleNote + pitchShift.max(0.001).ratiomidi;
        var rounded = (base + offset).round;
        ^rounded + Index.ar(this.scaleBuffer.bufnum, rounded % 12) - base
    }
}
