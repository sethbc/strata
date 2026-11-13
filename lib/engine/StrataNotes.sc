// StrataNotes.sc
// The notes area (3.5): each voice's eight note slots (slot 0 the voice's
// own note, 1-7 extra notes from a pool all voices share) and the four note
// commands. Lua allocates the slots and owns every value; the engine holds
// the bounds: a slot never holds two live synths, and live and releasing
// extra notes never exceed the pool. An extra note is a synth of its own in
// its slot: a synth voice's a voice synth at the head of voiceGroup, on the
// voice's bus (its one grain synth grains the chord), or, while the voice is
// frozen, a stream of its frozen ring; a buffer or input voice's a grain
// synth at the head of the voice's mix group. Each has its own pitch. Voice-wide sends reach a voice's notes through setVoiceSynths
// and setGrainSynths. See docs/notes/engine/notes.md.

+ Engine_Strata {
    // Note slots per voice: 0 the voice's own note, 1-7 its extra notes. Lua's
    // S.constants.NOTE_SLOTS is the same number (a docs test compares them)
    noteSlots { ^8 }

    // The most extra notes the pool holds, across every voice (setNotePool's
    // size 0..notePoolMax). Lua's S.constants.NOTE_POOL.max is the same number
    notePoolMax { ^16 }

    // The lag (s) of every per-note control, smoothing Lua's 48 Hz steps
    noteLag { ^0.02 }

    // The note that plays at rate 1 on a buffer or input voice: Lua's
    // NOTES.rate_root_note (a docs test compares them)
    noteRateRootNote { ^60 }

    // The rate Lua's note_values gives a buffer or input voice's note
    // (ruling 53): 2 ^ ((note - noteRateRootNote) / 12), clipped as noteOn
    // clips a rate. A ring-stream note's kept rate is against the freeze
    // reference instead, which only Lua holds, so a note that leaves the
    // stream takes this from its kept note (ruling 46's note put to use)
    absoluteNoteRate { arg note;
        ^(2 ** ((note - this.noteRateRootNote) / 12)).clip(0.25, 4)
    }

    // A ring-stream note leaving the stream (restartNotes, notesUnfrozen):
    // its kept rate becomes its note's (absoluteNoteRate), so a later
    // restart on a buffer or the input plays its pitch there (#682)
    leaveStream { arg record;
        if (record[\kind] == \stream) { record[\rate] = this.absoluteNoteRate(record[\note]) };
    }

    // The notes area (order 170): the last in alloc's order, the first in
    // free's, so its stop frees the note synths before the voices' groups go
    strataAreaNotes {
        ^(
            order: 170,
            allocState: { this.areaCall(\allocNoteState) },
            addCommands: { this.areaCall(\addNoteCommands) },
            stop: { this.areaCall(\stopNotes) }
        )
    }

    // areaState[\notes]: pool (how many extra notes the pool holds: 0 until
    // Lua sends setNotePool), slots (per voice an Array of noteSlots records:
    // slot 0's its kept expression and parked flag, each extra slot's
    // emptyNoteRecord), order (a counter: each started note and each cut
    // takes the next number, so the oldest is the lowest) and received (what
    // each command last took, for the engine check)
    allocNoteState {
        var state = areaState[\notes];
        state[\pool] = 0;
        state[\order] = 0;
        state[\slots] = numVoices.collect({ this.noteSlots.collect({ arg slot; this.emptyNoteRecord(slot) }) });
        state[\received] = IdentityDictionary.new;
    }

    // A note's expression at rest: no bend, unit gain, no offsets
    neutralNoteExpression { ^(bend: 1, amp: 1, position: 0, size: 0, main: 0) }

    // A slot as alloc leaves it. Slot 0 (the own note, whose synths are the
    // voice's): its kept expression, whether it is parked, and its rate (a
    // frozen synth voice's own grain synth's noteRate). An extra slot:
    // its state (\empty, \live, \releasing), its synth (live or releasing),
    // its cutting synth (in its kill fade), its kind (\voice, \buffer,
    // \input, \stream: what its synth is), its last noteOn's note, freq, rate and velocity, its
    // kept expression, and the order it started at and its cutting synth's
    emptyNoteRecord { arg slot;
        if (slot == 0) { ^(expression: this.neutralNoteExpression, parked: false, rate: 1) };
        ^(state: \empty, synth: nil, cutting: nil, kind: nil, note: 60, freq: 440, rate: 1, velocity: 1,
            expression: this.neutralNoteExpression, order: 0, cutOrder: 0)
    }

    noteRecord { arg voice, slot; ^areaState[\notes][\slots][voice][slot] }

    // The next order number (oldest lowest)
    nextNoteOrder {
        var state = areaState[\notes];
        state[\order] = state[\order] + 1;
        ^state[\order]
    }

    // Every extra slot's record, of every voice
    extraNoteRecords {
        ^areaState[\notes][\slots].collect({ arg slots; slots.copyToEnd(1) }).flatten
    }

    // The live extra note synths of a voice (of one kind: \grain for every
    // grain synth note; nil for all)
    noteSynths { arg voice, kind;
        if (this.validVoice(voice).not) { ^[] };
        ^areaState[\notes][\slots][voice].copyToEnd(1).select({ arg record;
            (record[\state] == \live) and: { record[\synth].notNil }
                and: { kind.isNil or: { (kind == \grain) and: { this.grainNoteKinds.includes(record[\kind]) } } or: { record[\kind] == kind } }
        }).collect({ arg record; record[\synth] })
    }

    // The kinds of note whose synth is a grain synth (\stream: a frozen synth
    // voice's ring)
    grainNoteKinds { ^#[\buffer, \input, \stream] }

    // Whether the voice is a frozen synth voice: on its synth source, its
    // ring held (the freeze area's)
    frozenSynthVoice { arg voice;
        ^(grainSource[voice] == 0) and: { areaState[\freeze][\frozen][voice] }
    }

    // Live and releasing extra notes, across every voice: what the pool bounds
    heldNoteCount {
        ^this.extraNoteRecords.count({ arg record; (record[\state] == \live) or: { record[\state] == \releasing } })
    }

    // Extra note synths in their kill fade, across every voice
    cuttingNoteRecords {
        ^this.extraNoteRecords.select({ arg record; record[\cutting].notNil })
    }

    // What the voice's next extra note is: a voice synth (a synth voice), a
    // stream of its frozen ring (a frozen synth voice), or a grain synth of
    // its buffer slot or of the input
    noteKindFor { arg voice;
        var source = grainSource[voice];
        if (source == this.inputSource) { ^\input };
        if (source.inclusivelyBetween(1, numBuffers)) { ^\buffer };
        if (this.frozenSynthVoice(voice)) { ^\stream };
        ^\voice
    }

    // A note's pitch as its synth's controls: a synth voice's note plays its
    // freq, a buffer note its rate as its bufRate with a scaleNote of its
    // own, an input note its rate as its pitchShift, a frozen synth voice's
    // its rate as its stream's noteRate (the voice's pitchShift stays)
    notePitchPairs { arg voice, record;
        ^switch (record[\kind])
        { \voice } { [\freq, record[\freq]] }
        { \buffer } { [\bufRate, record[\rate], \scaleNote, this.noteScaleNote(voice, record[\rate])] }
        { \input } { [\pitchShift, record[\rate]] }
        { \stream } { [\noteRate, record[\rate]] }
        { [] }
    }

    // A note's accent at its velocity: a voice synth's t_trig (which
    // re-plucks a Karplus note), a grain synth's t_accent
    noteAccentPairs { arg record;
        ^[\velocity, record[\velocity], if (record[\kind] == \voice) { \t_trig } { \t_accent }, 1]
    }

    // A note's expression as its synth's controls: bend and amp, then a voice
    // synth's main (noteMain), a grain synth's position and size
    noteExpressionPairs { arg kind, expression;
        var pairs = [\noteBend, expression[\bend], \noteAmp, expression[\amp]];
        if (kind == \voice) { ^pairs ++ [\noteMain, expression[\main]] };
        ^pairs ++ [\notePos, expression[\position], \noteSize, expression[\size]]
    }

    // The controls only one voice synth note takes, never a voice-wide
    // send's (design 3.5 §3.2): its freq, its velocity and accent, its note
    // controls
    perNoteVoiceControls { ^#[\freq, \velocity, \t_trig, \noteGate, \noteBend, \noteAmp, \noteMain] }

    // A voice-wide voice synth send: the own voice synth (setSynth) and every
    // live voice synth note of the voice (sendToSynth), the latter without
    // the per-note names
    setVoiceSynths { arg voice ... pairs;
        var notePairs, notes;
        this.setSynth(this.voiceKey(voice), *pairs);
        notes = this.noteSynths(voice, \voice);
        if (notes.notEmpty) {
            notePairs = this.pairsWithout(pairs, this.perNoteVoiceControls);
            if (notePairs.notEmpty) { this.sendToSynth(*notes.collect({ arg synth; synth.setMsg(*notePairs) })) };
        };
    }

    // The controls only one note's synth takes, never a voice-wide send's
    // (design 3.5 §3.2): the note controls, its velocity and accent, and the
    // control that is its pitch: a buffer note's bufRate and scaleNote, an
    // input note's pitchShift
    perNoteGrainControls { arg voice;
        var names = [\noteGate, \noteBend, \noteAmp, \notePos, \noteSize, \noteRate, \velocity, \t_accent];
        if (grainSource[voice] == this.inputSource) { ^names ++ [\pitchShift] };
        if (grainSource[voice].inclusivelyBetween(1, numBuffers)) { ^names ++ [\bufRate, \scaleNote] };
        ^names
    }

    // A voice-wide grain send: the own grain synth (setSynth) and every live
    // extra grain note of the voice (sendToSynth), the latter without the
    // per-note names
    setGrainSynths { arg voice ... pairs;
        var notePairs, notes;
        this.setSynth(this.grainKey(voice), *pairs);
        notes = this.noteSynths(voice, \grain);
        if (notes.notEmpty) {
            notePairs = this.pairsWithout(pairs, this.perNoteGrainControls(voice));
            if (notePairs.notEmpty) { this.sendToSynth(*notes.collect({ arg synth; synth.setMsg(*notePairs) })) };
        };
    }

    // Start the slot's note (its record holds the noteOn's values): its
    // synth, watched as a note's (watchNoteSynth), with the voice's controls,
    // then the note's pitch, accent, park open and expression, last so they
    // win. A synth voice's note is a voice synth of the voice's def at the
    // head of voiceGroup writing the voice's bus, from voiceControls (as
    // startVoiceSynth); a buffer or input voice's a grain synth for the
    // voice's source at the head of its mix group (startGrainSynth, from
    // grainControlPairs); a frozen synth voice's a \strataGrainRing reading
    // the voice's ring (grainReadPairs, as its own grain synth does, the
    // freeze on) at the head of processGroup, writing the synth path with
    // rateLevel and pan 0 (startGrainSynth's synth source), at noteRate the
    // note's rate. Placement is never relative to another note's synth. A
    // note the engine restarts itself (silent: a source switch, an unfreeze)
    // starts with no accent or trigger, its velocity kept (ruling 45)
    startNoteSynth { arg voice, slot, silent = false;
        var record = this.noteRecord(voice, slot), kind = this.noteKindFor(voice), defName, notePairs;
        record[\kind] = kind;
        notePairs = this.notePitchPairs(voice, record)
            ++ (if (silent) { [\velocity, record[\velocity]] } { this.noteAccentPairs(record) }) ++ [\noteGate, 1]
            ++ this.noteExpressionPairs(kind, record[\expression]);
        if (kind == \voice) {
            defName = voiceSynthDefs[voice];
            ^this.watchNoteSynth(voice, slot, Synth(defName,
                [\out, granBuses[voice]] ++ this.controlPairs(defName, voiceControls[voice]) ++ notePairs, voiceGroup, \addToHead))
        };
        ^this.startGrainSynth(voice, if (kind == \stream) { processGroup } { this.voiceMixGroup(voice) }, \addToHead, notePairs,
            { arg synth; this.watchNoteSynth(voice, slot, synth) })
    }

    // Watch a note's synth until it frees: its start counts once the server
    // confirms it (watchStart, as a voice's synths), and when it frees its
    // slot empties (or its cutting entry clears) and it leaves the readers;
    // nothing restarts it (never watchVoiceSynth's restart rule)
    watchNoteSynth { arg voice, slot, synth;
        this.watchStart(synth);
        synth.onFree({
            var record = this.noteRecord(voice, slot);
            this.forgetGrainReader(synth);
            if (record[\synth] === synth) { record[\synth] = nil; record[\state] = \empty };
            if (record[\cutting] === synth) { record[\cutting] = nil };
        });
        ^synth
    }

    // A slot's synths whose start the server never confirmed past
    // startConfirmWait are forgotten as an /n_end would have them forgotten
    // (endFailedStart runs their onFree, which empties the slot), so the
    // slot's command meets it as it is: a failed start frees its slot
    forgetFailedNoteStarts { arg record;
        [record[\synth], record[\cutting]].do({ arg synth;
            if (synth.notNil and: { this.startFailed(synth) }) { this.endFailedStart(synth) };
        });
    }

    // Free a slot's cutting synth at once (endNoteSynth)
    freeNoteCutting { arg record;
        var synth = record[\cutting];
        if (synth.notNil) {
            record[\cutting] = nil;
            this.endNoteSynth(synth);
        };
    }

    // Free a note synth now and forget it everywhere it was registered, as
    // its /n_end would (endFailedStart: quietly freed, out of the
    // NodeWatcher, its onFree run, out of unconfirmedStarts): one that never
    // started sends no /n_end, so nothing else would forget it (review item
    // 7). One that did start is freed all the same; its late /n_end finds no
    // watched node
    endNoteSynth { arg synth;
        this.endFailedStart(synth);
    }

    // Cut a slot's note (live or releasing) in the kill fade: it becomes the
    // slot's cutting synth and the slot empties. An earlier cutting synth of
    // the slot is freed at once, and so is the oldest cutting note synth
    // anywhere when cutting synths would pass the pool, so they never
    // exceed one per slot nor the pool in all
    cutNote { arg voice, slot;
        var record = this.noteRecord(voice, slot), synth = record[\synth];
        record[\synth] = nil;
        record[\state] = \empty;
        if (synth.isNil or: { synth.isPlaying.not }) { ^this };
        this.freeNoteCutting(record);
        this.cutSynth(synth);
        record[\cutting] = synth;
        record[\cutOrder] = this.nextNoteOrder;
        this.trimCuttingNotes(areaState[\notes][\pool]);
    }

    // Free the oldest cutting note synths until at most `most` are left
    trimCuttingNotes { arg most;
        var cutting = this.cuttingNoteRecords.sort({ arg a, b; a[\cutOrder] < b[\cutOrder] });
        (cutting.size - most.max(0)).do({ arg index; this.freeNoteCutting(cutting[index]) });
    }

    // Release a live note: its synth's gate 0, the slot releasing until the
    // synth frees after its release
    releaseNote { arg voice, slot;
        var record = this.noteRecord(voice, slot);
        if (record[\state] != \live) { ^this };
        this.sendToSynth(record[\synth].setMsg(\gate, 0));
        record[\state] = \releasing;
    }

    // Room in the pool for one more extra note: when live and releasing
    // notes already number it (failed starts forgotten first), the oldest
    // releasing one anywhere is cut.
    // false when none is releasing (a full pool of live notes: Lua never
    // sends that)
    makeNoteRoom {
        var releasing;
        // a start the server never confirmed past startConfirmWait holds no
        // room: forgotten first, whatever slot it is in (review item 7)
        this.extraNoteRecords.do({ arg record; this.forgetFailedNoteStarts(record) });
        if (this.heldNoteCount < areaState[\notes][\pool]) { ^true };
        releasing = this.extraNoteRecords.select({ arg record; record[\state] == \releasing });
        if (releasing.isEmpty) { ^false };
        releasing = releasing.minItem({ arg record; record[\order] });
        this.cutNote(*this.noteVoiceAndSlot(releasing));
        ^this.heldNoteCount < areaState[\notes][\pool]
    }

    // [voice, slot] of an extra slot's record
    noteVoiceAndSlot { arg record;
        areaState[\notes][\slots].do({ arg slots, voice;
            slots.do({ arg each, slot; if (each === record) { ^[voice, slot] } });
        });
        ^nil
    }

    // Start the slot's note if the pool has room, else refuse it with one
    // line. A restarted note keeps the order it started at (order) and
    // starts silent (ruling 45)
    startNote { arg voice, slot, order, silent = false;
        var record = this.noteRecord(voice, slot);
        if (this.makeNoteRoom.not) {
            this.postFastModIgnored(\noteOn, "the pool of % is full of live notes".format(areaState[\notes][\pool]));
            ^this
        };
        record[\order] = order ?? { this.nextNoteOrder };
        record[\synth] = this.startNoteSynth(voice, slot, silent);
        record[\state] = \live;
    }

    // noteOn on an extra slot (design 3.5 §3.4): on a live slot the pitch is
    // set on its synth and its accent fired (no node); a releasing slot's
    // tail is cut and a new synth starts; an empty slot starts one. A
    // stopped voice takes no extra note (Lua never sends one): ignored with
    // one line. A note that sounds then opens the voice's step gate
    // (openStepGate, ruling 54), as retrigger does for the own note; the
    // engine's own restarts (startNote from restartNotes, notesUnfrozen)
    // open nothing
    extraNoteOn { arg voice, slot, note, freq, rate, velocity;
        var record = this.noteRecord(voice, slot);
        this.forgetFailedNoteStarts(record);
        if (this.voiceRunning(voice).not) {
            ^this.postFastModIgnored(\noteOn, "voice % is stopped".format(voice))
        };
        record[\note] = note;
        record[\freq] = freq;
        record[\rate] = rate;
        record[\velocity] = velocity;
        switch (record[\state])
        { \live } {
            this.sendToSynth(record[\synth].setMsg(*(this.notePitchPairs(voice, record) ++ this.noteAccentPairs(record))));
        }
        { \releasing } {
            this.cutNote(voice, slot);
            this.startNote(voice, slot);
        }
        { this.startNote(voice, slot) };
        if (record[\state] == \live) { this.openStepGate(voice) };
    }

    // Ruling 54 (#683): the voice's step gate opens for an extra note's
    // start as for retrigger's, with no accent: the stage's t_gate starts
    // its gate envelope (voiceMixMod) and nothing else, so no accent on the
    // stage, no pluck and no grain trigger. With the gate off (seqGate 0)
    // it changes nothing heard
    openStepGate { arg voice;
        this.setSynth(this.voiceMixKey(voice), \t_gate, 1);
    }

    // noteOff on an extra slot: cut 0 releases a live note, cut 1 cuts a live
    // or releasing one; an empty slot does nothing
    extraNoteOff { arg voice, slot, cut;
        var record = this.noteRecord(voice, slot);
        this.forgetFailedNoteStarts(record);
        if (record[\synth].isNil) { ^this };
        if (cut == 1) { this.cutNote(voice, slot) } { this.releaseNote(voice, slot) };
    }

    // noteExpression on an extra slot: kept for the slot (a later noteOn
    // starts with it) and set on its synth, live or releasing
    extraNoteExpression { arg voice, slot, expression;
        var record = this.noteRecord(voice, slot);
        record[\expression] = expression;
        if (record[\synth].notNil) {
            this.sendToSynth(record[\synth].setMsg(*this.noteExpressionPairs(record[\kind], expression)));
        };
    }

    // The pool, 0..notePoolMax; notes past a smaller one are cut (the
    // oldest releasing first, then the oldest live), and cutting note synths
    // past it are freed
    setNotePool { arg size;
        var held;
        areaState[\notes][\pool] = size;
        while { this.heldNoteCount > size } {
            held = this.extraNoteRecords.select({ arg record; record[\state] == \releasing });
            if (held.isEmpty) { held = this.extraNoteRecords.select({ arg record; record[\state] == \live }) };
            this.cutNote(*this.noteVoiceAndSlot(held.minItem({ arg record; record[\order] })));
        };
        this.trimCuttingNotes(size);
    }

    // Whether the voice's own note sounds through its grain synth (a buffer
    // or input voice, and a frozen synth voice, whose grain synth plays the
    // frozen ring) rather than its voice synth (a synth voice)
    ownNoteOnGrain { arg voice;
        ^(grainSource[voice] != 0) or: { this.frozenSynthVoice(voice) }
    }

    // The key of the synth that sounds the voice's own note: the one slot 0's
    // expression reaches (the park also reaches a synth voice's own voice
    // synth, frozen or not: ownNoteOff, ownNoteOn)
    ownNoteKey { arg voice;
        ^if (this.ownNoteOnGrain(voice)) { this.grainKey(voice) } { this.voiceKey(voice) }
    }

    // What one of the voice's own synths (a synth of defName) starts or is
    // re-gated with of the note controls: the one that sounds the own note
    // takes slot 0's kept expression, every other own synth (a synth voice's
    // grain synth, which grains the whole chord) the neutral values, its
    // defaults. The park (ruling 44): a voice synth always takes it (frozen
    // or not), a grain synth when it sounds the own note. Only the controls
    // defName has
    ownNotePairs { arg voice, defName;
        var own = this.noteRecord(voice, 0), expression = own[\expression], controls;
        var isVoiceDef = voiceSynthDefs.includes(defName), sounds = isVoiceDef == this.ownNoteOnGrain(voice).not;
        if (sounds.not) { expression = this.neutralNoteExpression };
        controls = Dictionary[\noteGate -> (if ((sounds or: { isVoiceDef }) and: { own[\parked] }) { 0 } { 1 }),
            \noteBend -> expression[\bend], \noteAmp -> expression[\amp], \noteMain -> expression[\main],
            \notePos -> expression[\position], \noteSize -> expression[\size],
            \noteRate -> (if (sounds and: { this.frozenSynthVoice(voice) }) { own[\rate] } { 1 })];
        ^this.controlPairs(defName, controls)
    }

    // voiceOn starts every voice unparked, its own note's expression neutral
    // (as it resets bend); gateVoice gives the own synths ownNotePairs
    resetOwnNote { arg voice;
        var own = this.noteRecord(voice, 0);
        own[\parked] = false;
        own[\expression] = this.neutralNoteExpression;
        own[\rate] = 1;
    }

    // A synth voice's unfreeze (the freeze area's unfreezeWithControl, in
    // its bundle, the voice already unfrozen): the own grain synth back to
    // the neutral note controls (noteRate 1, its park open), the own note's
    // expression on the voice synth again (ownNotePairs, which also resends
    // the park the voice synth already holds: ruling 44, ownNoteOff and
    // ownNoteOn reach it while frozen), every ring-stream note cut and each
    // live one restarted as a voice synth at its kept freq, keeping its
    // order, silent (ruling 45), its kept rate now its note's (leaveStream,
    // ruling 53); a releasing one is not restarted
    notesUnfrozen { arg voice;
        this.noteRecord(voice, 0)[\rate] = 1;
        this.setSynth(this.grainKey(voice), *this.ownNotePairs(voice, \strataGrainRing));
        this.setSynth(this.voiceKey(voice), *this.ownNotePairs(voice, voiceSynthDefs[voice]));
        (1 .. (this.noteSlots - 1)).do({ arg slot;
            var record = this.noteRecord(voice, slot), wasLive = record[\state] == \live, order = record[\order];
            if ((record[\kind] == \stream) and: { record[\synth].notNil }) {
                this.cutNote(voice, slot);
                this.leaveStream(record);
                if (wasLive) { this.startNote(voice, slot, order, true) };
            };
        });
    }

    // noteOn on slot 0: the own note unparked (noteGate 1) on the synths its
    // park is on (ownNoteGateKeys), and nothing else on an unfrozen voice
    // (ruling 47: Lua follows it with retrigger, which accents the voice,
    // plucks Karplus and opens the stage's step gate, once). On a frozen
    // synth voice the own grain synth also takes the note's rate as its
    // noteRate, parked or not (the own note's only pitch there), and its
    // accent at velocity (t_accent: the only accent that stream has)
    ownNoteOn { arg voice, rate, velocity;
        var own = this.noteRecord(voice, 0);
        own[\parked] = false;
        this.ownNoteGateKeys(voice).do({ arg key;
            if ((key == this.grainKey(voice)) and: { this.frozenSynthVoice(voice) }) {
                own[\rate] = rate;
                this.setSynth(key, \noteGate, 1, \noteRate, rate, \velocity, velocity, \t_accent, 1);
            } { this.setSynth(key, \noteGate, 1) };
        });
    }

    // noteOff on slot 0: the own note parked (noteGate 0 on the synths its
    // park is on: its level falls over the release, every synth stays)
    ownNoteOff { arg voice;
        this.noteRecord(voice, 0)[\parked] = true;
        this.ownNoteGateKeys(voice).do({ arg key; this.setSynth(key, \noteGate, 0) });
    }

    // The keys of the own synths slot 0's park reaches (ruling 44): a synth
    // voice's own voice synth, frozen or not (inaudible while frozen, so its
    // park costs nothing there and the unfreeze finds it where the park
    // says), and the own grain synth wherever it sounds the own note (a
    // buffer or input voice; a frozen synth voice, from the slot-0 commands
    // while frozen: the freeze itself parks nothing, its ring holding the
    // chord)
    ownNoteGateKeys { arg voice;
        var keys = List.new;
        if (grainSource[voice] == 0) { keys.add(this.voiceKey(voice)) };
        if (this.ownNoteOnGrain(voice)) { keys.add(this.grainKey(voice)) };
        ^keys.asArray
    }

    // noteExpression on slot 0: kept, and set on the synth that sounds the
    // own note
    ownNoteExpression { arg voice, expression;
        var key = this.ownNoteKey(voice);
        this.noteRecord(voice, 0)[\expression] = expression;
        this.setSynth(key, *this.noteExpressionPairs(if (this.ownNoteOnGrain(voice)) { \buffer } { \voice }, expression));
    }

    // A running voice's source switch (replaceGrainSynth, in its bundle):
    // every extra note of the voice is cut, and each that was live restarts
    // on the new source from its kept values (startNoteSynth by the voice's
    // state now), keeping its order, silent (ruling 45); a releasing one is
    // not restarted. A ring-stream note restarts at its note's rate
    // (leaveStream, ruling 53). So a slot holds a live and a cutting synth
    // at most
    restartNotes { arg voice;
        (1 .. (this.noteSlots - 1)).do({ arg slot;
            var record = this.noteRecord(voice, slot), wasLive = record[\state] == \live, order = record[\order];
            if (record[\synth].notNil) {
                this.cutNote(voice, slot);
                this.leaveStream(record);
                if (wasLive) { this.startNote(voice, slot, order, true) };
            };
        });
    }

    // voiceOff releases every live extra note of the voice with it: their
    // tails stay in their slots and the pool until they free
    releaseNotes { arg voice;
        (1 .. (this.noteSlots - 1)).do({ arg slot; this.releaseNote(voice, slot) });
    }

    // The area's stop: every note synth freed (quietly) and every slot as
    // alloc left it, before the voices' groups go
    stopNotes {
        var slots = areaState[\notes][\slots];
        slots.do({ arg records; records.copyToEnd(1).do({ arg record;
            [record[\synth], record[\cutting]].do({ arg synth; if (synth.notNil) { this.endNoteSynth(synth) } });
        }) });
        areaState[\notes][\slots] = numVoices.collect({ this.noteSlots.collect({ arg slot; this.emptyNoteRecord(slot) }) });
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
    // continuous arguments only then, records what it took and acts. The Lua
    // engine stub reads the clips (name = msg[i].clip(...)) as its limits,
    // and its index limits from noteSlots and notePoolMax.
    addNoteCommands {
        var lastVoice = numVoices - 1, lastSlot = this.noteSlots - 1;

        // Start voice's slot: note 0-127 (the scale reference), freq 8-20000
        // Hz, rate 0.25-4, velocity 0-1. The engine keeps note in the slot's
        // record (ruling 46): a ring-stream note leaving the stream takes its
        // rate from it (leaveStream, ruling 53); a buffer note's scaleNote
        // comes from the voice's reference note and its rate (noteScaleNote);
        // a later release's tunings will need a note's number apart from its rate
        this.addCommand(\noteOn, "iiffff", { arg msg;
            var voice = msg[1], slot = msg[2], note, freq, rate, velocity;
            if (this.fastModIndicesValid(\noteOn, [[\voice, voice, lastVoice], [\slot, slot, lastSlot]])
                and: { this.fastModValuesFinite(\noteOn, [[\note, msg[3]], [\freq, msg[4]], [\rate, msg[5]], [\velocity, msg[6]]]) }) {
                note = msg[3].clip(0, 127); freq = msg[4].clip(8, 20000); rate = msg[5].clip(0.25, 4); velocity = msg[6].clip(0, 1);
                this.receiveNote(\noteOn, [voice, slot, note, freq, rate, velocity]);
                if (slot > 0) { this.extraNoteOn(voice, slot, note, freq, rate, velocity) } { this.ownNoteOn(voice, rate, velocity) };
            };
        });

        // End voice's slot: cut 0 releases it, 1 cuts it
        this.addCommand(\noteOff, "iii", { arg msg;
            var voice = msg[1], slot = msg[2], cut = msg[3];
            if (this.fastModIndicesValid(\noteOff, [[\voice, voice, lastVoice], [\slot, slot, lastSlot], [\cut, cut, 1]])) {
                this.receiveNote(\noteOff, [voice, slot, cut]);
                if (slot > 0) { this.extraNoteOff(voice, slot, cut) } { this.ownNoteOff(voice) };
            };
        });

        // Voice's slot's expression: bend a ratio 0.0625-16, amp a gain 0-2,
        // position, size and main offsets of -1..1 half ranges
        this.addCommand(\noteExpression, "iifffff", { arg msg;
            var voice = msg[1], slot = msg[2], bend, amp, position, size, main, expression;
            if (this.fastModIndicesValid(\noteExpression, [[\voice, voice, lastVoice], [\slot, slot, lastSlot]])
                and: { this.fastModValuesFinite(\noteExpression, [[\bend, msg[3]], [\amp, msg[4]], [\position, msg[5]],
                    [\size, msg[6]], [\main, msg[7]]]) }) {
                bend = msg[3].clip(0.0625, 16); amp = msg[4].clip(0, 2);
                position = msg[5].clip(-1, 1); size = msg[6].clip(-1, 1); main = msg[7].clip(-1, 1);
                this.receiveNote(\noteExpression, [voice, slot, bend, amp, position, size, main]);
                expression = (bend: bend, amp: amp, position: position, size: size, main: main);
                if (slot > 0) { this.extraNoteExpression(voice, slot, expression) } { this.ownNoteExpression(voice, expression) };
            };
        });

        // The pool: how many extra notes all voices share, 0..notePoolMax
        this.addCommand(\setNotePool, "i", { arg msg;
            var size = msg[1];
            if (this.fastModIndicesValid(\setNotePool, [[\size, size, this.notePoolMax]])) {
                this.receiveNote(\setNotePool, [size]);
                this.setNotePool(size);
            };
        });
    }
}
