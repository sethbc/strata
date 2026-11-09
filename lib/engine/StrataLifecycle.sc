// StrataLifecycle.sc
// A voice's synths over their life: starting, placing, re-gating,
// replacing, fading, cutting and releasing them (replace, never stack).
// See docs/notes/engine/lifecycle.md and docs/notes/engine/memory.md.

+ Engine_Strata {
    startVoiceSynth { arg voice;
        var defName = voiceSynthDefs[voice];
        ^this.watchVoiceSynth(voice, this.voiceKey(voice),
            Synth(defName, [\out, granBuses[voice]] ++ this.controlPairs(defName, voiceControls[voice]),
                target: voiceGroup))
    }

    // Modulation output synth, at the tail of processGroup at the voice's
    // mod speed, with the voice's mix group moved just before it in the same
    // bundle: the mirror the stage writes reaches strataMod in the same
    // block (a re-gated mod synth is already after its group). A group
    // never ends, so these are plain messages.
    startModSynth { arg voice;
        var mod = Synth.basicNew(\strataMod, context.server);
        context.server.sendBundle(nil,
            mod.newMsg(processGroup, [\in, granBuses[voice], \out, modBuses[voice]] ++ this.modSpeedPairs(voice), \addToTail),
            ['/n_before', this.voiceMixGroup(voice).nodeID, mod.nodeID]);
        ^this.watchVoiceSynth(voice, this.modKey(voice), mod)
    }

    // The voice's mod speed as strataMod controls; empty until Lua has sent one
    modSpeedPairs { arg voice;
        ^if (modSpeeds[voice].notNil) { [\speed, modSpeeds[voice]] } { [] }
    }

    // The voice-level (buffer and input sources) and grain controls a grain
    // synth for the voice's current source takes. The synth source reads its
    // voice's 4 s ring at history 0, whatever history the voice keeps (that
    // is for the input ring), so a voice that leaves the input never reads
    // a wrapped ring.
    grainControlPairs { arg voice;
        var defName = this.grainDefFor(voice);
        var pairs = this.controlPairs(defName, grainControls[voice]);
        if (grainSource[voice] != 0) { pairs = this.controlPairs(defName, voiceControls[voice]) ++ pairs };
        if (grainSource[voice] == 0) { pairs = pairs ++ [\history, 0] };
        ^pairs
    }

    // The grain synth for the voice's current source, with its current
    // grain controls and its source kind's path (out: voicePathBus). Buffer
    // and input sources also take the voice-level controls the grain SynthDef
    // has (pan, bend, the frequency crossmod). The rate switch is always set
    // explicitly: the synth source's strataGrainRing reads the voice's ring
    // with pan and rateLevel 0 (its voice synth already applies them;
    // rateLevel 0 makes the bend and frequency crossmod term 1) and its mod
    // buses on the silent bus, never control bus 0 (the input amplitude
    // follower on norns); the input source's reads the input ring with
    // them on, as a buffer source's strataGrainBuf does. A strataGrainRing
    // is kept in ringReaders and a strataGrainBuf in grainSlots (with its
    // slot, so a slot change reaches it in its release too: bufferChanged)
    // until it frees.
    startGrainSynth { arg voice, target, addAction;
        var source = grainSource[voice];
        var defName = this.grainDefFor(voice);
        var args = [\out, this.voicePathBus(voice, source)], synth;

        case
        { source == 0 } {
            args = args ++ this.ringPairs(voice) ++ [\rateLevel, 0, \pan, 0,
                \modBus1, silentBus.index, \modBus2, silentBus.index, \modBus3, silentBus.index];
        }
        { source == this.inputSource } { args = args ++ this.ringPairs(voice) ++ [\rateLevel, 1] }
        { args = args ++ [\rateLevel, 1] ++ this.bufferSlotPairs(voice) };
        synth = this.watchVoiceSynth(voice, this.grainKey(voice),
            Synth(defName, args ++ this.grainControlPairs(voice), target, addAction));
        case
        { defName == \strataGrainBuf } { grainSlots[synth] = source - 1 }
        { defName == \strataGrainRing } { this.ringReaders[synth] = voice };
        ^synth
    }

    // The ring a synth- or input-sourced voice reads, as strataGrainRing
    // controls (ringBuffersFor); empty for a buffer source
    ringPairs { arg voice;
        var ring = this.ringBuffersFor(voice, grainSource[voice]);
        ^if (ring.isNil) { [] } { [\bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index] }
    }

    // A buffer-sourced voice's slot as strataGrainBuf controls (bufnums,
    // valid length, record head bus and, for a slot holding audio, rate
    // scale: see bufferChanged); empty for the synth and input sources
    bufferSlotPairs { arg voice;
        var slot = grainSource[voice] - 1;
        if (grainSource[voice].inclusivelyBetween(1, numBuffers).not) { ^[] };
        ^[\bufnumL, buffersL[slot].bufnum, \bufnumR, buffersR[slot].bufnum] ++ this.slotLengthPairs(slot)
    }

    // A slot's valid length and record head bus as strataGrainBuf controls,
    // with its rate scale only when it holds audio: a slot that empties
    // (clear, record) must not retune the grains still fading out (hasAudio's lag)
    slotLengthPairs { arg index;
        var frames = bufferFrames[index];
        var head = [\recHeadBus, this.slotHeadBus(index).index];
        ^(if (frames > 0) { [\bufFrames, frames, \bufRateScale, this.bufferRateScale(index)] } { [\bufFrames, 0] }) ++ head
    }

    // A new grain synth for the voice's source, placed so the node order
    // holds after any history of switches: the synth source's at the head
    // of processGroup (it writes the voice's synth path; the stage reads it
    // later in processGroup), any other at the head of the voice's mix
    // group, so its stage, at the group's tail, reads it in the same block.
    // Never created next to another synth: that one may already have freed
    // on the server without sclang knowing yet (an /s_new to a missing
    // target creates nothing, leaving a grain synth that never frees); a
    // group never ends.
    startPlacedGrainSynth { arg voice;
        if (grainSource[voice] == 0) { ^this.startGrainSynth(voice, processGroup, \addToHead) };
        ^this.startGrainSynth(voice, this.voiceMixGroup(voice), \addToHead)
    }

    // Start a voice: every synth it still has is re-gated instead of
    // stacking a new one. A running voice's synths only take the voiceOn
    // values. A released voice's synths that are still in their release
    // get gate 1 (the ASR restarts its attack from the current level) and
    // the values with set; the ones already freed are started. A releasing
    // synth that no longer fits the source (it changed while the voice was
    // stopped) is treated as replaceGrainSynth treats the synths it
    // replaces, before anything new starts: a grain synth built for another
    // source finishes its release and a voice synth (the source is no
    // longer the synth) is given a forced release (release(grainRelease)),
    // both as the voice's fadingSynths (fadeSupersededSynths), so the next
    // switch or mismatched start can cut them and the voice holds at most
    // its live synths, one fading and one cutting set (#46). New grain
    // synths are placed by startPlacedGrainSynth; the mix group is already
    // before a re-gated mod synth.
    gateVoice { arg voice;
        var releasing = releasingSynths[voice];
        var voiceKey = this.voiceKey(voice), grainKey = this.grainKey(voice), modKey = this.modKey(voice);
        var stillReleasing = { arg key; var synth = releasing[key]; synth.notNil and: { synth.isPlaying } };
        var superseded = List.new;

        if ((grainSource[voice] != 0) and: { stillReleasing.(voiceKey) }) {
            this.sendToSynth(releasing[voiceKey].releaseMsg(grainRelease));
            superseded.add(releasing.removeAt(voiceKey));
        };
        if (synths[grainKey].isNil and: { stillReleasing.(grainKey) } and: { releasedGrainSource[voice] != grainSource[voice] }) {
            superseded.add(releasing.removeAt(grainKey));
        };
        this.fadeSupersededSynths(voice, superseded);

        // Voice synth: synth source only
        if (grainSource[voice] == 0) {
            if (synths[voiceKey].isNil and: { stillReleasing.(voiceKey) }) { synths[voiceKey] = releasing.removeAt(voiceKey) };
            if (synths[voiceKey].isNil) {
                synths[voiceKey] = this.startVoiceSynth(voice);
            } {
                this.sendToSynth(synths[voiceKey].setMsg(\gate, 1, *this.controlPairs(voiceSynthDefs[voice], voiceControls[voice])));
            };
        };

        // Grain synth: re-gated only if it was built for the current source
        // (one built for another source is fading by now)
        if (synths[grainKey].isNil and: { stillReleasing.(grainKey) }) {
            synths[grainKey] = releasing.removeAt(grainKey);
        };
        if (synths[grainKey].isNil) {
            synths[grainKey] = this.startPlacedGrainSynth(voice);
        } {
            // with the slot as it is now: bufferChanged sends a releasing grain synth bufFrames 0 only
            this.sendToSynth(synths[grainKey].setMsg(\gate, 1, *(this.bufferSlotPairs(voice) ++ this.grainControlPairs(voice))));
        };

        if (synths[modKey].isNil and: { stillReleasing.(modKey) }) {
            synths[modKey] = releasing.removeAt(modKey);
        };
        if (synths[modKey].isNil) { synths[modKey] = this.startModSynth(voice) } {
            this.sendToSynth(synths[modKey].setMsg(\gate, 1, *this.modSpeedPairs(voice)));
        };
    }

    // Watch one of a voice's synths (key: its voiceKey, grainKey or modKey)
    // until it frees. A released synth is then forgotten. A synth the voice
    // is using frees only if its release ended just as voiceOn re-gated it
    // (the gate arrived too late); it is started again so the voice is
    // never left without it. free empties synths first, so nothing restarts
    // when the engine is freed.
    watchVoiceSynth { arg voice, key, synth;
        synth.register(true);  // playing from now on, so gateVoice can re-gate it at once
        synth.onFree({
            if (releasingSynths[voice][key] === synth) { releasingSynths[voice].removeAt(key) };
            fadingSynths[voice].remove(synth);
            cuttingSynths[voice].remove(synth);
            grainSlots.removeAt(synth);
            this.ringReaders.removeAt(synth);
            if (synths[key] === synth) {
                synths.removeAt(key);
                case
                { key == this.voiceKey(voice) } {
                    if (grainSource[voice] == 0) { synths[key] = this.startVoiceSynth(voice) };
                }
                { key == this.grainKey(voice) } { synths[key] = this.startPlacedGrainSynth(voice) }
                { synths[key] = this.startModSynth(voice) };
            };
        });
        ^synth
    }

    // Swap a running voice's grain synth for one matching its source: the
    // old one is released (grainRelease) as the new one starts, so one
    // voice never runs two grain paths beyond that release. The new one is
    // placed by startPlacedGrainSynth (the synth source's at the head of
    // processGroup, any other in the voice's mix group).
    // Whatever is fading (what an earlier switch replaced, or what voiceOn
    // handed over when it restarted the voice for another source) is cut
    // first (cutSynth: gone within switchCutTime), so once a switch has been
    // processed the voice has at most one fading grain synth and one fading
    // voice synth. A frozen voice is unfrozen first (the freeze area), and
    // the switch counts as a ring change (ringChanges), so a ring copy still
    // waiting for its fade no longer runs.
    replaceGrainSynth { arg voice;
        var oldGrain, voiceSynth;

        this.unfreezeVoice(voice);
        this.ringChanges[voice] = this.ringChanges[voice] + 1;
        oldGrain = synths.removeAt(this.grainKey(voice));
        this.cutFadingSynths(voice);
        synths[this.grainKey(voice)] = this.startPlacedGrainSynth(voice);
        if (oldGrain.notNil) {
            // A forced release (gate -1 - time), linear over grainRelease;
            // the next switch cuts it with its kill fade
            this.sendToSynth(oldGrain.releaseMsg(grainRelease));
            fadingSynths[voice].add(oldGrain);
        };

        if (grainSource[voice] == 0) {
            if (synths[this.voiceKey(voice)].isNil) {
                synths[this.voiceKey(voice)] = this.startVoiceSynth(voice);
            };
        } {
            // Its sound only reaches the output through the old grain synth,
            // so it releases with it instead of over its own (up to 12 s) release
            voiceSynth = synths.removeAt(this.voiceKey(voice));
            if (voiceSynth.notNil) {
                this.sendToSynth(voiceSynth.releaseMsg(grainRelease));
                fadingSynths[voice].add(voiceSynth);
            };
        };
    }

    // Cut (switchCutTime) the voice's fading synths: those an earlier
    // source switch gated off, and those voiceOn handed over (built for
    // another source while the voice was stopped). The running voice's
    // synths are never among them. Synths an earlier cut left in their kill
    // fade are freed first, so a burst of switches (several inside one
    // switchCutTime: a chord of scene buttons) never piles them up: a voice
    // holds at most one live, one fading and one cutting set of synths (see
    // docs/notes/engine/memory.md). Nothing of a running voice
    // should be left in releasingSynths (voiceOn re-gates a releasing synth
    // or hands it to fadingSynths); one that is is cut too, with a warning.
    cutFadingSynths { arg voice;
        var releasing = releasingSynths[voice];
        [this.voiceKey(voice), this.grainKey(voice)].do({ arg key;
            var synth = releasing.removeAt(key);
            if (synth.notNil) {
                this.warnInvariant("voice % switched with % still releasing".format(voice, key));
                fadingSynths[voice].add(synth);
            };
        });
        this.replaceFadingSynths(voice, []);
    }

    // Synths the voice stopped using while they still release (gateVoice:
    // built for another source; releaseVoice: superseded) become its
    // fadingSynths, as the synths a switch replaces do: the synths an
    // earlier cut left in their kill fade are freed and the fading ones are
    // cut first. Nothing when there are none, so a start that re-gates
    // everything cuts nothing.
    fadeSupersededSynths { arg voice, superseded;
        if (superseded.notEmpty) { this.replaceFadingSynths(voice, superseded) };
    }

    // Free the cutting synths, cut the fading ones, and make newFading the
    // fading set: a voice then holds one cutting and one fading set at most
    replaceFadingSynths { arg voice, newFading;
        this.freeCuttingSynths(voice);
        fadingSynths[voice].do({ arg synth; this.cutVoiceSynth(voice, synth) });
        fadingSynths[voice].clear;
        newFading.do({ arg synth; fadingSynths[voice].add(synth) });
    }

    // cutSynth, remembering the synth until it frees so the next switch can
    // free it at once if its fade has not ended
    cutVoiceSynth { arg voice, synth;
        if (synth.isPlaying) {
            this.cutSynth(synth);
            cuttingSynths[voice].add(synth);
        };
    }

    // Free the voice's synths still in their kill fade, at once. One may
    // have ended its fade on the server already (its /n_end not yet in
    // sclang): sendToSynth keeps that /n_free from being reported. onFree
    // forgets them; they are never in synths or releasingSynths.
    freeCuttingSynths { arg voice;
        cuttingSynths[voice].do({ arg synth;
            if (synth.isPlaying) { this.sendToSynth(synth.freeMsg) };
        });
        cuttingSynths[voice].clear;
    }

    // Gate off a voice's synth trio (each frees itself after its release,
    // even one created in this control block: see openedGate), so later
    // commands to that voice are no-ops. The released synths are kept in
    // releasingSynths until they free, for voiceOn to re-gate. gateVoice
    // leaves nothing releasing beside a voice's running synths (it re-gates
    // a releasing synth or hands it to fadingSynths), so no releasing synth
    // should be under the same key; one that is (with a warning) would
    // otherwise release untracked, out of reach of the next switch's cut, so
    // it joins the fading set the way gateVoice's do (fadeSupersededSynths).
    // Only voice and grain synths have the kill fade; a releasing mod synth
    // is always re-gated by voiceOn, never superseded.
    releaseVoice { arg voice;
        var superseded = [this.voiceKey(voice), this.grainKey(voice)].select({ arg key;
            var synth = releasingSynths[voice][key];
            synths[key].notNil and: { synth.notNil } and: { synth !== synths[key] }
        }).collect({ arg key; releasingSynths[voice].removeAt(key) });
        if (synths[this.grainKey(voice)].notNil) { releasedGrainSource[voice] = grainSource[voice] };
        if (superseded.notEmpty) { this.warnInvariant("voice % stopped with a superseded synth still releasing".format(voice)) };
        this.fadeSupersededSynths(voice, superseded.select(_.isPlaying));
        [this.voiceKey(voice), this.grainKey(voice), this.modKey(voice)].do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) {
                this.sendToSynth(synth.setMsg(\gate, 0));
                releasingSynths[voice][key] = synth;
            };
        });
    }
}
