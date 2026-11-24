// StrataOutRings.sc
// The out rings area (3.8, design §5): each voice's output ring, a stereo
// pair of outRingSeconds (the performance area's method, which
// fixedBufferBytes counts), and its persistent writer in the record area's
// tap group, recording the voice's tap: everything the voice sounds before
// its dry level (after its grains, filter, level, gate and mute). A voice on
// a voice source (voiceSourceFirst + j) reads voice j's ring as an input
// voice reads the input ring (ringBuffersFor). See
// docs/notes/engine/outrings.md.

+ Engine_Strata {
    // The out rings area (order 135): after the record area (130), whose
    // start makes the tap group, so its writers go to the group's tail; its
    // stop, which runs in descending order, frees them before the record
    // area's frees the group. The writers never end on their own: their
    // keys are effectKeys (plain messages)
    strataAreaOutRings {
        ^(
            order: 135,
            allocState: { this.areaCall(\allocOutRings) },
            addDefs: { this.areaCall(\addOutRingDefs); [] },
            start: { this.areaCall(\startOutRingWriters) },
            stop: { this.areaCall(\stopOutRingWriters) },
            free: { this.areaCall(\freeOutRings) },
            effectKeys: this.outRingWriterKeys
        )
    }

    // The writers' synth keys, one per voice
    outRingWriterKeys {
        ^numVoices.collect({ arg voice; ("outRingWrite" ++ voice).asSymbol })
    }

    // [left buffer, right buffer, phase bus] of a voice's output ring
    outRingFor { arg voice;
        var state = areaState[\outRings];
        ^[state[\left][voice], state[\right][voice], state[\phaseBuses][voice]]
    }

    // areaState[\outRings]: \left and \right (per voice a mono buffer of
    // outRingSeconds at the server rate), \phaseBuses (per voice its
    // writer's frame, zeroed: a writer starts from its bus). The writers
    // are kept in synths alone, under outRingWriterKeys (#943)
    allocOutRings {
        var server = context.server, state = areaState[\outRings];
        var frames = server.sampleRate * this.outRingSeconds;
        state[\left] = Array.fill(numVoices, { Buffer.alloc(server, frames, 1) });
        state[\right] = Array.fill(numVoices, { Buffer.alloc(server, frames, 1) });
        state[\phaseBuses] = Array.fill(numVoices, { Bus.control(server, 1) });
        state[\phaseBuses].do({ arg bus; bus.set(0) });
    }

    addOutRingDefs {
        // An output ring's writer: \strataRingWrite's graph (its phase is
        // ringWritePhase, so a writer never resets a Phasor with a trigger
        // on its first sample, #801), each channel through zeroBadValues
        // and then softclip: linear to half scale and never at full scale,
        // so a loop of voices reading each other holds there (design §5)
        SynthDef(\strataOutRingWrite, {
            arg in, bufL, bufR, phaseOut, resume = 0;
            var sig = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel).softclip });
            var phase = this.ringWritePhase(bufL, phaseOut, resume);
            BufWr.ar(sig[0], bufL, phase);
            BufWr.ar(sig[1], bufR, phase);
            Out.kr(phaseOut, A2K.kr(phase));
        }).add;
    }

    // One writer per voice, reading its tap, at the tail of the tap group
    // (after the master and strataTapPreMaster)
    startOutRingWriters {
        var record = areaState[\record];
        this.outRingWriterKeys.do({ arg key, voice;
            var ring = this.outRingFor(voice);
            synths[key] = Synth(\strataOutRingWrite, [\in, record[\voiceTaps][voice], \bufL, ring[0], \bufR, ring[1],
                \phaseOut, ring[2]], record[\tapGroup], \addToTail);
        });
    }

    // The writers (quietly, as the ring writers are freed)
    stopOutRingWriters {
        this.outRingWriterKeys.do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) { this.sendToSynth(synth.freeMsg); synth.free(false) };
        });
    }

    // The rings and their phase buses (every area's nodes are gone by now;
    // each key may be missing after an alloc that failed part way)
    freeOutRings {
        var state = areaState[\outRings];
        ((state[\left] ? []) ++ (state[\right] ? [])).do({ arg buffer; buffer !? { buffer.free } });
        (state[\phaseBuses] ? []).do({ arg bus; bus.free });
    }
}
