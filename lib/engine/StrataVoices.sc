// StrataVoices.sc
// The voices area: the voices' buses, groups and state, the voice commands
// (voiceOn, retrigger, voiceOff, setVoiceParam, setGrainParam,
// setGrainSource and the crossmod commands), setVoiceControl and
// envBufnumFor. See docs/notes/engine/voices.md.

+ Engine_Strata {
    // The voices area (order 20)
    strataAreaVoices {
        ^(
            order: 20,
            allocState: { this.areaCall(\allocVoiceState) },
            addDefs: { this.areaCall(\addVoiceDefs); voiceSynthDefs },
            addCommands: { this.areaCall(\addVoiceCommands) },
            start: { this.areaCall(\startVoiceGroups) },
            stop: { this.areaCall(\stopVoices) },
            free: { this.areaCall(\freeVoices) }
        )
    }

    allocVoiceState {
        // Voice SynthDef for each voice index (0-indexed, as sent by Lua)
        voiceSynthDefs = [\strataResonator, \strataFM, \strataFolder, \strataSub,
            \strataPulse, \strataKarplus, \strataRing];

        // Audio buses for granular processing (one stereo bus per voice)
        granBuses = Array.fill(numVoices, { Bus.audio(context.server, 2) });

        // Control buses for cross-modulation (one per voice)
        modBuses = Array.fill(numVoices, { Bus.control(context.server, 1) });

        // "No modulation source" must read a bus that is always zero. Control
        // bus 0 is not safe: CroneAudioContext allocates the input amplitude
        // follower (amp_in_b) there before any engine loads.
        silentBus = Bus.control(context.server, 1);
        silentBus.set(0);

        grainSource = Array.fill(numVoices, 0);
        voiceControls = Array.fill(numVoices, { Dictionary.new });
        grainControls = Array.fill(numVoices, { Dictionary.new });
        releasingSynths = Array.fill(numVoices, { Dictionary.new });
        releasedGrainSource = Array.fill(numVoices, 0);
        fadingSynths = Array.fill(numVoices, { IdentitySet.new });
        cuttingSynths = Array.fill(numVoices, { IdentitySet.new });
        grainSlots = IdentityDictionary.new;
        modSpeeds = Array.newClear(numVoices);
        // Every voice, grain and mod synth whose start the server has not
        // confirmed yet (/n_go) -> when it was started (watchVoiceSynth, #497)
        areaState[\voices][\unconfirmed] = IdentityDictionary.new;
        // The names setVoiceParam and setGrainParam refuse (#458)
        areaState[\voices][\refusedVoiceParams] = (this.engineOwnedControls ++ this.modSlotControls).as(IdentitySet);
        areaState[\voices][\refusedGrainParams] = (this.engineOwnedControls ++ this.modSlotControls
            ++ this.voiceLevelGrainControls).as(IdentitySet);

        // Every node a voice or area keeps running, by key (voiceKey,
        // grainKey, modKey and effectKeys)
        synths = Dictionary.new;
    }

    startVoiceGroups {
        // Node order inside the engine group (context.xg):
        // voiceGroup (the input synth, voice synths, then the ring writers
        // at its tail) -> processGroup (the synth source's grain synths at
        // the head; each voice's mix group, the voice's buffer and input
        // grain synths at its head and its strataVoiceMix at its tail, just
        // before that voice's mod synth, so the mirror reaches strataMod in
        // the same block; mod synths added at the tail: see
        // startPlacedGrainSynth and startModSynth) -> filter x3 (dry, delay
        // send, reverb send) -> delay -> reverb -> master -> the record
        // area's tap group (strataTapPreMaster, then the record synths), last.
        // Keeping everything inside xg leaves norns' output group (og) and
        // its output metering after the engine.
        voiceGroup = Group.head(context.xg);
        processGroup = Group.after(voiceGroup);
    }

    addVoiceCommands {
        // Commands for voice control
        this.addCommand(\voiceOn, "iffffff", { arg msg;
            var voice = msg[1].asInteger;

            if (this.validVoice(voice)) {
                // All 3 mod slots start on the silent bus (no modulation) and
                // bend at 1. The Lua script sends the voice-level values (the
                // synthesis params, crossmod routing and amounts, mod speed,
                // bend) right after voiceOn, since these are reset here; the
                // source and every grain value come just before it (#325).
                // The Lua voices table is the only source of their values.
                voiceControls[voice] = Dictionary[
                    \freq -> msg[2], \amp -> msg[3], \pan -> msg[4], \bend -> 1,
                    \modBus1 -> silentBus.index, \modBus2 -> silentBus.index, \modBus3 -> silentBus.index,
                    \modAmpAmt1 -> 0, \modAmpAmt2 -> 0, \modAmpAmt3 -> 0,
                    \modFreqAmt1 -> 0, \modFreqAmt2 -> 0, \modFreqAmt3 -> 0
                ];
                // Merged into the grain controls the voice already has (Lua
                // sends every grain value just before voiceOn, and a stopped
                // voice keeps them), so a grain synth voiceOn builds or
                // re-gates plays this start's grain values from its first grain
                grainControls[voice].putAll(Dictionary[
                    \grainSize -> msg[5], \grainDensity -> msg[6], \pitchShift -> msg[7]
                ]);
                // the own note unparked at the neutral expression (the notes
                // area's), which the synths gateVoice re-gates or starts take
                this.resetOwnNote(voice);

                // Re-gates the synths the voice still has (running or
                // releasing) and starts the missing ones; never stacks. The
                // stage takes the reset values in the same bundle, so the
                // level and the first grain land in one block.
                context.server.makeBundle(nil, {
                    this.setSynth(this.voiceMixKey(voice), *this.controlPairs(\strataVoiceMix, voiceControls[voice]));
                    // (through areaCall: the synths' onFree watchers keep this
                    // frame, and a function's frame is freed as it returns, #211)
                    this.areaCall(\gateVoice, voice);
                });
            };
        });

        // Re-articulate a running voice without creating new nodes: fires
        // the accent envelope at the given velocity (0-1) on the own voice
        // synth (the synth source, re-plucking Karplus) and, while the voice
        // runs, on the stage (its voice-level gain on the buffer or input
        // path), and one grain on every grain synth of the voice, its extra
        // notes' included (setGrainSynths), in triggered mode. A grain
        // synth's own accent (3.5's t_accent) is its note's, which only the
        // notes area fires: retrigger sends it t_trig alone. velocity is set
        // in the same message as t_trig.
        this.addCommand(\retrigger, "if", { arg msg;
            var voice = msg[1], velocity = msg[2].clip(0, 1);
            if (this.validVoice(voice)) {
                this.setSynth(this.voiceKey(voice), \velocity, velocity, \t_trig, 1);
                this.setGrainSynths(voice, \t_trig, 1);
                if (this.voiceRunning(voice)) { this.setSynth(this.voiceMixKey(voice), \velocity, velocity, \t_trig, 1) };
            };
        });

        this.addCommand(\voiceOff, "i", { arg msg;
            var voice = msg[1];
            if (this.validVoice(voice)) { this.releaseVoice(voice) };
        });

        // A control the engine sets itself is refused (#458)
        this.addCommand(\setVoiceParam, "isf", { arg msg;
            var param = msg[2].asSymbol;
            if (areaState[\voices][\refusedVoiceParams].includes(param).not) { this.setVoiceControl(msg[1], param, msg[3]) };
        });

        // A param an area handles (grainParamHandlers: the grains area's
        // envShape) goes to its handler, which returns true when it has
        // dealt with it; other params pass straight through, to the own grain
        // synth and the voice's extra notes (setGrainSynths, which keeps a
        // note's own pitch its own). Every value is kept so a replacement
        // grain synth (source switch) starts with it.
        // A control the engine sets itself, or a voice-level one, is refused
        // (#458).
        this.addCommand(\setGrainParam, "isf", { arg msg;
            var voice = msg[1], param = msg[2].asSymbol, value = msg[3], handler;
            if (this.validVoice(voice) and: { areaState[\voices][\refusedGrainParams].includes(param).not }) {
                handler = grainParamHandlers[param];
                if (handler.isNil or: { handler.value(voice, value) != true }) {
                    grainControls[voice][param] = value;
                    this.setGrainSynths(voice, param, value);
                };
            };
        });

        // source: 0 = the voice's synth, 1-8 = buffer slot, 9 = live input.
        // A stopped voice only records it (voiceOn builds the right synths);
        // a running voice gets its grain synth replaced, never stacked.
        this.addCommand(\setGrainSource, "ii", { arg msg;
            var voice = msg[1], source = msg[2];
            if (this.validVoice(voice) and: { this.validSource(source) }
                and: { source != grainSource[voice] }) {
                grainSource[voice] = source;
                if (this.voiceRunning(voice)) { this.replaceGrainSynth(voice) };
            };
        });

        // Multi-source cross-modulation commands. A slot outside
        // 1..numModSlots is ignored (it would name a control no SynthDef has,
        // kept in voiceControls for good)
        this.addCommand(\setModSource, "iii", { arg msg;
            var voice = msg[1];
            var slot = msg[2];  // 1, 2, or 3
            var sourceVoice = msg[3];
            var sourceBus;

            // -1 (or any out-of-range source) means no modulation: read the
            // always-zero silent bus
            if (this.validVoice(sourceVoice)) {
                sourceBus = modBuses[sourceVoice].index;
            } {
                sourceBus = silentBus.index;
            };

            if (this.validModSlot(slot)) { this.setVoiceControl(voice, ("modBus" ++ slot).asSymbol, sourceBus) };
        });

        this.addCommand(\setModAmpAmt, "iif", { arg msg;
            // msg: voice, slot (1-3), amount
            if (this.validModSlot(msg[2])) { this.setVoiceControl(msg[1], ("modAmpAmt" ++ msg[2]).asSymbol, msg[3]) };
        });

        this.addCommand(\setModFreqAmt, "iif", { arg msg;
            // msg: voice, slot (1-3), amount
            if (this.validModSlot(msg[2])) { this.setVoiceControl(msg[1], ("modFreqAmt" ++ msg[2]).asSymbol, msg[3]) };
        });

        // Kept per voice, so a mod synth the engine starts again (onFree,
        // gateVoice) runs at the voice's speed, not the SynthDef default
        this.addCommand(\setModSpeed, "if", { arg msg;
            var voice = msg[1];
            if (this.validVoice(voice)) {
                modSpeeds[voice] = msg[2];
                this.setSynth(this.modKey(voice), \speed, msg[2]);
            };
        });
    }

    // The voices' synths (the effects area has stopped its own), then their
    // groups
    stopVoices {
        synths.do({ arg synth; this.sendToSynth(synth.freeMsg); synth.free(false) });
        synths.clear;  // their onFree must not start them again
        // also frees voices still in their release phase
        voiceGroup.free;
        processGroup.free;
    }

    // The voices' buses (every area's nodes are gone by now)
    freeVoices {
        granBuses.do({ arg bus; bus.free });
        modBuses.do({ arg bus; bus.free });
        silentBus.free;
    }

    // GrainIn envbufnum for an envShape index: 0 = built-in Hann (-1),
    // 1-4 = envBuffers; nil for anything else
    envBufnumFor { arg index;
        if (index == 0) { ^-1 };
        if ((index >= 1) and: { index <= envBuffers.size }) { ^envBuffers[index - 1].bufnum };
        ^nil
    }

    // A voice-level control (synthesis param, crossmod routing or amount):
    // kept for restarts, sent to the voice synth and the voice's extra voice
    // synth notes (setVoiceSynths: freq only to the own note's), to the grain
    // synth and the extra grain notes (setGrainSynths) when
    // that has the control (pan, bend and the frequency crossmod) while the
    // voice is not on its synth source, and, whatever the source, to the
    // stage when that has the control (amp and the amplitude crossmod) while
    // the voice runs (a stopped voice's reach the stage at its next voiceOn).
    // A synth whose SynthDef lacks the control is sent nothing (#501).
    setVoiceControl { arg voice, control, value;
        var pairs;
        if (this.validVoice(voice)) {
            voiceControls[voice][control] = value;
            this.setVoiceSynths(voice, control, value);
            if (grainSource[voice] != 0) {
                pairs = this.controlPairs(this.grainDefFor(voice), Dictionary[control -> value]);
                if (pairs.notEmpty) { this.setGrainSynths(voice, *pairs) };
            };
            pairs = this.controlPairs(\strataVoiceMix, Dictionary[control -> value]);
            if (pairs.notEmpty and: { this.voiceRunning(voice) }) { this.setSynth(this.voiceMixKey(voice), *pairs) };
        };
    }

    // The controls the engine sets itself, never a setVoiceParam or
    // setGrainParam name (#458): kept under such a name, a value stayed in
    // voiceControls or grainControls for good and reached every synth the
    // engine started for the voice (kill 1 cut each one 50 ms in). The
    // lifecycle's (out, gate, kill), retrigger's (t_trig, velocity), the slot
    // a buffer grain synth reads (bufnumL/R, bufFrames, bufRateScale,
    // recHeadBus), the ring a ring grain synth reads (bufL/R, phaseBus,
    // ringLevel), the source's rate switch (rateLevel), the envelope's
    // buffer (envBuf, from envShape) and the fast-modulation block a grain
    // synth or stage reads (fastModIn, the modulation area's), and 3.5's
    // per-note controls, which the notes area sets on one note's synth
    // (noteGate, noteBend, noteAmp, noteMain, notePos, noteSize, noteRate
    // and the note's accent, t_accent), and the stage's t_gate (an extra
    // note's gate trigger, ruling 54); with them the crossmod commands'
    // (modSlotControls). The envelope times (attackTime, releaseTime) are
    // ordinary voice params. The Lua engine stub reads these lists and
    // rejects the same names.
    engineOwnedControls {
        ^#[\out, \gate, \kill, \t_trig, \velocity, \bufnumL, \bufnumR, \bufFrames, \bufRateScale, \recHeadBus,
            \bufL, \bufR, \phaseBus, \ringLevel, \rateLevel, \envBuf, \fastModIn,
            \noteGate, \noteBend, \noteAmp, \noteMain, \notePos, \noteSize, \noteRate, \t_accent, \t_gate]
    }

    // The crossmod commands' controls, one of each per slot: modBus1,
    // modAmpAmt1, modFreqAmt1, ... up to numModSlots
    modSlotControlNames { ^#[\modBus, \modAmpAmt, \modFreqAmt] }
    modSlotControls {
        ^(1..numModSlots).collect({ arg slot;
            this.modSlotControlNames.collect({ arg name; (name ++ slot).asSymbol })
        }).flatten
    }

    // The voice-level controls a buffer or input voice's grain synth takes
    // from setVoiceParam (setVoiceControl): setGrainParam refuses them too,
    // since a kept one would win over the voice's own (grainControlPairs)
    voiceLevelGrainControls { ^#[\pan, \bend] }

    // Every voice, grain and mod synth not yet confirmed by its /n_go ->
    // when it was started (watchVoiceSynth, startFailed)
    unconfirmedStarts { ^areaState[\voices][\unconfirmed] }
}
