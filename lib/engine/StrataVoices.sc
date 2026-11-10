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
            allocState: { this.allocVoiceState },
            addDefs: { this.addVoiceDefs; voiceSynthDefs },
            addCommands: { this.addVoiceCommands },
            start: { this.startVoiceGroups },
            stop: { this.stopVoices },
            free: { this.freeVoices }
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

        // Every node a voice or area keeps running, by key (voiceKey,
        // grainKey, modKey and effectKeys)
        synths = Dictionary.new;
    }

    startVoiceGroups {
        // Node order inside the engine group (context.xg):
        // voiceGroup (input, voices, recorders) -> processGroup (the synth
        // source's grain synths at the head; each voice's mix group, the
        // voice's buffer and input grain synths at its head and its
        // strataVoiceMix at its tail, just before that voice's mod synth,
        // so the mirror reaches strataMod in the same block; mod synths
        // added at the tail: see startPlacedGrainSynth and startModSynth)
        // -> filter -> delay -> reverb -> master.
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
                // bend at 1. Voice-specific params, posSpread, crossmod
                // routing and mod speed are pushed by the Lua script
                // (sync_voice_to_engine) right after voiceOn; the Lua voices
                // table is the only source of their values.
                voiceControls[voice] = Dictionary[
                    \freq -> msg[2], \amp -> msg[3], \pan -> msg[4], \bend -> 1,
                    \modBus1 -> silentBus.index, \modBus2 -> silentBus.index, \modBus3 -> silentBus.index,
                    \modAmpAmt1 -> 0, \modAmpAmt2 -> 0, \modAmpAmt3 -> 0,
                    \modFreqAmt1 -> 0, \modFreqAmt2 -> 0, \modFreqAmt3 -> 0
                ];
                // Merged into the grain controls the voice already has, so a
                // grain synth voiceOn builds starts in the voice's grain mode,
                // envelope and buffer position (Lua re-sends them right after)
                grainControls[voice].putAll(Dictionary[
                    \grainSize -> msg[5], \grainDensity -> msg[6], \pitchShift -> msg[7]
                ]);

                // Re-gates the synths the voice still has (running or
                // releasing) and starts the missing ones; never stacks. The
                // stage takes the reset values in the same bundle, so the
                // level and the first grain land in one block.
                context.server.makeBundle(nil, {
                    this.setSynth(this.voiceMixKey(voice), *this.controlPairs(\strataVoiceMix, voiceControls[voice]));
                    this.gateVoice(voice);
                });
            };
        });

        // Re-articulate a running voice without creating new nodes: fires
        // the accent envelope at the given velocity (0-1) on the voice synth
        // (the synth source, re-plucking Karplus) and, while the voice runs,
        // on the stage (its voice-level gain on the buffer or input path),
        // and one grain when the grain synth is in triggered mode (the grain
        // synth takes t_trig alone: it has no accent). velocity is set in the
        // same message as t_trig.
        this.addCommand(\retrigger, "if", { arg msg;
            var voice = msg[1], velocity = msg[2].clip(0, 1);
            if (this.validVoice(voice)) {
                this.setSynth(this.voiceKey(voice), \velocity, velocity, \t_trig, 1);
                this.setSynth(this.grainKey(voice), \t_trig, 1);
                if (this.voiceRunning(voice)) { this.setSynth(this.voiceMixKey(voice), \velocity, velocity, \t_trig, 1) };
            };
        });

        this.addCommand(\voiceOff, "i", { arg msg;
            var voice = msg[1];
            if (this.validVoice(voice)) { this.releaseVoice(voice) };
        });

        this.addCommand(\setVoiceParam, "isf", { arg msg;
            this.setVoiceControl(msg[1], msg[2].asSymbol, msg[3]);
        });

        // A param an area handles (grainParamHandlers: the grains area's
        // envShape) goes to its handler, which returns true when it has
        // dealt with it; other params pass straight through. Every value is
        // kept so a replacement grain synth (source switch) starts with it.
        this.addCommand(\setGrainParam, "isf", { arg msg;
            var voice = msg[1], param = msg[2].asSymbol, value = msg[3], handler;
            if (this.validVoice(voice)) {
                handler = grainParamHandlers[param];
                if (handler.isNil or: { handler.value(voice, value) != true }) {
                    grainControls[voice][param] = value;
                    this.setSynth(this.grainKey(voice), param, value);
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
    // kept for restarts, sent to the voice synth, to the grain synth when
    // that has the control (pan, bend and the frequency crossmod) while the
    // voice is not on its synth source, and, whatever the source, to the
    // stage when that has the control (amp and the amplitude crossmod) while
    // the voice runs (a stopped voice's reach the stage at its next voiceOn)
    setVoiceControl { arg voice, control, value;
        var pairs;
        if (this.validVoice(voice)) {
            voiceControls[voice][control] = value;
            this.setSynth(this.voiceKey(voice), control, value);
            if (grainSource[voice] != 0) {
                this.setSynth(this.grainKey(voice), *this.controlPairs(this.grainDefFor(voice), Dictionary[control -> value]));
            };
            pairs = this.controlPairs(\strataVoiceMix, Dictionary[control -> value]);
            if (pairs.notEmpty and: { this.voiceRunning(voice) }) { this.setSynth(this.voiceMixKey(voice), *pairs) };
        };
    }
}
