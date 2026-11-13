// StrataRings.sc
// The rings area: each voice's ring and the input ring the ring grain
// synths read, their persistent writers and phase buses, each voice's copy
// ring (an input freeze's copy: the freeze area's), and the ring readers.
// See docs/notes/engine/rings.md.

+ Engine_Strata {
    // Seconds each voice's ring holds
    ringSeconds { ^4 }

    // Seconds the input ring holds beyond historySeconds (and one more)
    ringGuardSeconds { ^4 }

    // How far behind the write head a ring grain starts at the least (s):
    // the block A2K reports the head at its start, plus interpolation
    ringReadMargin { ^0.005 }

    // A ring grain's position spread: a random offset of up to
    // posSpread x this, backward from where it would start (s)
    ringSpreadSeconds { ^0.5 }

    // Ring grain rates are clipped to +/- this, so the lookback stays bounded
    ringMaxRate { ^4 }

    // The rings area (order 70): writers at the tail of voiceGroup, after
    // the input synth and the voice synths (the record synths run in the
    // tap group, after the master), so a voice writer records only its
    // voice synth: the voice's stage writes its mirror to the voice bus
    // later, at the tail of its mix group in processGroup (after the
    // synth-source grain synths at the head and the voice's buffer and
    // input grain synths at its group's head, before its mod synth). The
    // writers never end on their own: their keys are effectKeys (plain
    // messages).
    strataAreaRings {
        ^(
            order: 70,
            allocState: { this.areaCall(\allocRings) },
            addDefs: { this.areaCall(\addRingDefs); [] },
            start: { this.areaCall(\startRingWriters) },
            stop: { this.areaCall(\stopRingWriters) },
            free: { this.areaCall(\freeRings) },
            effectKeys: this.ringWriterKeys
        )
    }

    // The writers' synth keys: one per voice, then the input's
    ringWriterKeys {
        ^numVoices.collect({ arg voice; ("ringWrite" ++ voice).asSymbol }) ++ [\ringWriteInput]
    }

    // Every ring grain synth until it frees -> the voice it plays for
    ringReaders { ^areaState[\rings][\readers] }

    // Per voice: counts the changes that make a pending ring copy stale
    // (a source switch here, freeze and unfreeze in the freeze area)
    ringChanges { ^areaState[\rings][\changes] }

    // [left buffer, right buffer, phase bus] a ring grain synth reads for a
    // voice's source: the voice's own ring for the synth source, the input
    // ring for the input source; nil for a buffer slot
    ringBuffersFor { arg voice, source;
        var rings = areaState[\rings];
        case
        { source == 0 } { ^[rings[\voiceL][voice], rings[\voiceR][voice], rings[\phaseBuses][voice]] }
        { source == this.inputSource } { ^[rings[\inputL], rings[\inputR], rings[\phaseBuses][numVoices]] };
        ^nil
    }

    // [left buffer, right buffer, phase bus] of a voice's copy ring: what an
    // input freeze holds (the freeze area writes it), read only by the
    // voice's input grain synths. The voice's own ring only ever holds its
    // voice bus, so a synth-source grain synth never reads input audio
    copyRingFor { arg voice;
        var rings = areaState[\rings];
        ^[rings[\copyL][voice], rings[\copyR][voice], rings[\copyPhaseBuses][voice]]
    }

    allocRings {
        var server = context.server, rings = areaState[\rings];
        var voiceFrames = server.sampleRate * this.ringSeconds;
        var inputFrames = server.sampleRate * (historySeconds + this.ringGuardSeconds + 1);
        rings[\voiceL] = Array.fill(numVoices, { Buffer.alloc(server, voiceFrames, 1) });
        rings[\voiceR] = Array.fill(numVoices, { Buffer.alloc(server, voiceFrames, 1) });
        // each voice's copy ring, as long as its own (an input freeze's 4 s)
        rings[\copyL] = Array.fill(numVoices, { Buffer.alloc(server, voiceFrames, 1) });
        rings[\copyR] = Array.fill(numVoices, { Buffer.alloc(server, voiceFrames, 1) });
        rings[\inputL] = Buffer.alloc(server, inputFrames, 1);
        rings[\inputR] = Buffer.alloc(server, inputFrames, 1);
        // the last is the input's; zeroed, since a writer starts from its bus
        rings[\phaseBuses] = Array.fill(numVoices + 1, { Bus.control(server, 1) });
        rings[\phaseBuses].do({ arg bus; bus.set(0) });
        // the copy rings' (a spectral input freeze's writer moves one)
        rings[\copyPhaseBuses] = Array.fill(numVoices, { Bus.control(server, 1) });
        rings[\copyPhaseBuses].do({ arg bus; bus.set(0) });
        rings[\readers] = IdentityDictionary.new;
        rings[\changes] = Array.fill(numVoices, 0);
        rings[\writers] = [];
    }

    addRingDefs {
        // A ring writer: a Phasor over the ring's frames drives two BufWrs
        // (always appending: the ring holds the last BufFrames of its input)
        // and reports its frame position on phaseOut. It starts from the
        // position on phaseOut, so a writer that replaces another (the freeze
        // area's) carries on where that one was. The input goes through
        // zeroBadValues first: a voice that blows up never writes NaN into a
        // ring that frozen or later grains replay.
        SynthDef(\strataRingWrite, {
            arg in, bufL, bufR, phaseOut;
            var sig = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel) });
            var phase = Phasor.ar(Impulse.ar(0), 1, 0, BufFrames.kr(bufL), In.kr(phaseOut));
            BufWr.ar(sig[0], bufL, phase);
            BufWr.ar(sig[1], bufR, phase);
            Out.kr(phaseOut, A2K.kr(phase));
        }).add;
    }

    // One writer per voice (reading its voice bus), then the input's
    // (reading inputBus), each at the tail of voiceGroup
    startRingWriters {
        var rings = areaState[\rings];
        rings[\writers] = this.ringWriterKeys.collect({ arg key, index;
            var isInput = index == numVoices;
            var buffers = this.ringBuffersFor(index, if (isInput) { this.inputSource } { 0 });
            var writer = Synth(\strataRingWrite, [
                \in, if (isInput) { inputBus } { granBuses[index] },
                \bufL, buffers[0], \bufR, buffers[1], \phaseOut, buffers[2]
            ], voiceGroup, \addToTail);
            synths[key] = writer;
            writer
        });
    }

    // The writers (quietly, as the voices' are freed)
    stopRingWriters {
        this.ringWriterKeys.do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) { this.sendToSynth(synth.freeMsg); synth.free(false) };
        });
        areaState[\rings][\writers] = [];
    }

    // The rings, the copy rings and their phase buses (every area's nodes
    // are gone by now)
    freeRings {
        var rings = areaState[\rings];
        // (each key may be missing after an alloc that failed part way)
        ([\voiceL, \voiceR, \copyL, \copyR].collect({ arg key; rings[key] ? [] }).flatten
            ++ [rings[\inputL], rings[\inputR]]).do({ arg buffer; buffer !? { buffer.free } });
        ((rings[\phaseBuses] ? []) ++ (rings[\copyPhaseBuses] ? [])).do({ arg bus; bus.free });
        rings[\readers] !? { arg readers; readers.clear };
    }
}
