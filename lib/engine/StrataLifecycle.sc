// StrataLifecycle.sc
// A voice's synths over their life: starting, placing, re-gating,
// replacing, fading, cutting and releasing them (replace, never stack).
// See docs/notes/engine/lifecycle.md and docs/notes/engine/memory.md.

+ Engine_Strata {
    // The voice's own voice synth, from voiceControls, with the own note's
    // park and expression (ownNotePairs, the notes area's)
    startVoiceSynth { arg voice;
        var defName = voiceSynthDefs[voice];
        ^this.watchVoiceSynth(voice, this.voiceKey(voice),
            Synth(defName, [\out, granBuses[voice]] ++ this.controlPairs(defName, voiceControls[voice])
                ++ this.ownNotePairs(voice, defName), target: voiceGroup))
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
    // synth for the voice's current source takes, then the ring it reads and
    // the history it reads it at (grainReadPairs, the freeze area's answer;
    // empty for a buffer source), last so they win over the kept history:
    // the synth source's ring at history 0, the input ring at the voice's
    // history, or a frozen input voice's copy at history 0.
    grainControlPairs { arg voice;
        var defName = this.grainDefFor(voice);
        var pairs = this.controlPairs(defName, grainControls[voice]);
        if (grainSource[voice] != 0) { pairs = this.controlPairs(defName, voiceControls[voice]) ++ pairs };
        ^pairs ++ this.grainReadPairs(voice)
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
    // them on, as a buffer source's strataGrainBuf does. The ring a
    // strataGrainRing reads comes with its grain controls (grainControlPairs).
    // A strataGrainRing is kept in ringReaders (and, reading a frozen input
    // voice's copy, in the freeze area's inputReaders) and a strataGrainBuf
    // in grainSlots (with its slot, so a slot change reaches it in its
    // release too: bufferChanged) until it frees. An extra note's grain
    // synth (3.5, the notes area's startNoteSynth) is this with the note's
    // controls (notePairs, last so they win) and its own watcher (watch, a
    // function of the new synth returning it): nil for the voice's own grain
    // synth, watched by watchVoiceSynth, which takes the own note's park and
    // expression when it sounds the own note (ownNotePairs).
    startGrainSynth { arg voice, target, addAction, notePairs, watch;
        var source = grainSource[voice];
        var defName = this.grainDefFor(voice);
        var args = [\out, this.voicePathBus(voice, source)], synth;

        case
        { source == 0 } {
            args = args ++ [\rateLevel, 0, \pan, 0,
                \modBus1, silentBus.index, \modBus2, silentBus.index, \modBus3, silentBus.index];
        }
        { source == this.inputSource } { args = args ++ [\rateLevel, 1] }
        { args = args ++ [\rateLevel, 1] ++ this.bufferSlotPairs(voice) };
        synth = Synth(defName, args ++ this.grainControlPairs(voice) ++ (notePairs ?? { this.ownNotePairs(voice, defName) }), target, addAction);
        synth = if (watch.notNil) { watch.value(synth) } { this.watchVoiceSynth(voice, this.grainKey(voice), synth) };
        case
        { defName == \strataGrainBuf } { grainSlots[synth] = source - 1 }
        { defName == \strataGrainRing } {
            this.ringReaders[synth] = voice;
            this.noteInputReader(voice, synth);
        };
        ^synth
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
    // values (with the own note's park and expression, which voiceOn has
    // reset: ownNotePairs). A released voice's synths that are still in their release
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
    // before a re-gated mod synth. A synth whose start the server never
    // confirmed is forgotten first (forgetFailedStarts), so it is started
    // again, never re-gated.
    gateVoice { arg voice;
        var releasing = releasingSynths[voice];
        var voiceKey = this.voiceKey(voice), grainKey = this.grainKey(voice), modKey = this.modKey(voice);
        var stillReleasing = { arg key; var synth = releasing[key]; synth.notNil and: { synth.isPlaying } };
        var superseded = List.new, scanRestart = [];

        this.forgetFailedStarts(voice);

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
                this.sendToSynth(synths[voiceKey].setMsg(\gate, 1, *(this.controlPairs(voiceSynthDefs[voice], voiceControls[voice])
                    ++ this.ownNotePairs(voice, voiceSynthDefs[voice]))));
            };
        };

        // Grain synth: re-gated only if it was built for the current source
        // (one built for another source is fading by now). A re-gated
        // releasing slot reader restarts its scan, as a new one starts it
        // at 0 (every grain start restarts the scan).
        if (synths[grainKey].isNil and: { stillReleasing.(grainKey) }) {
            synths[grainKey] = releasing.removeAt(grainKey);
            if (synths[grainKey].defName.asSymbol == \strataGrainBuf) { scanRestart = [\t_scanReset, 1] };
        };
        if (synths[grainKey].isNil) {
            synths[grainKey] = this.startPlacedGrainSynth(voice);
        } {
            // with the slot as it is now: bufferChanged sends a releasing grain
            // synth bufFrames 0 only; with the ring grainControlPairs gives
            this.sendToSynth(synths[grainKey].setMsg(\gate, 1, *(scanRestart ++ this.bufferSlotPairs(voice) ++ this.grainControlPairs(voice)
                ++ this.ownNotePairs(voice, synths[grainKey].defName.asSymbol))));
            this.noteInputReader(voice, synths[grainKey]);
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
    // when the engine is freed. Until the server's /n_go confirms that it
    // runs, the synth is kept in unconfirmedStarts with its start time: one
    // whose /s_new failed never sends /n_go or /n_end (startFailed, #497).
    watchVoiceSynth { arg voice, key, synth;
        this.watchStart(synth);
        synth.onFree({
            if (releasingSynths[voice][key] === synth) { releasingSynths[voice].removeAt(key) };
            fadingSynths[voice].remove(synth);
            cuttingSynths[voice].remove(synth);
            this.forgetGrainReader(synth);
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

    // A new synth playing from now on (register(true), so gateVoice can
    // re-gate it at once; isPlaying only once NodeWatcher watches it: only
    // then can a /n_go come), and kept in unconfirmedStarts with its start
    // time until its /n_go (or /n_end): every voice, grain and mod synth's
    // and every note synth's (#497)
    watchStart { arg synth;
        var unconfirmed = this.unconfirmedStarts, confirm;
        synth.register(true);
        if (synth.isPlaying) {
            unconfirmed[synth] = Main.elapsedTime;
            confirm = { arg node, what;
                if ((what == \n_go) or: { what == \n_end }) { unconfirmed.removeAt(node); node.removeDependant(confirm) };
            };
            synth.addDependant(confirm);
        };
    }

    // A grain synth that frees reads nothing: it leaves grainSlots,
    // ringReaders and the freeze area's inputReaders
    forgetGrainReader { arg synth;
        grainSlots.removeAt(synth);
        this.ringReaders.removeAt(synth);
        this.forgetInputReader(synth);
    }

    // Seconds a new synth has for the server's /n_go (a reply within a
    // control block or two) before it counts as never started
    startConfirmWait { ^0.5 }

    // A synth the voice started whose /n_go has not come within
    // startConfirmWait: its /s_new failed on the server (no room in the
    // real-time pool, a missing def), so it never ran and never will
    startFailed { arg synth;
        var since = this.unconfirmedStarts[synth];
        ^since.notNil and: { (Main.elapsedTime - since) > this.startConfirmWait }
    }

    // The voice's synths that never started (startFailed), wherever the
    // engine keeps them (live, releasing, fading or cutting), are forgotten
    // as their /n_end would have them forgotten (#497): no /n_end ever comes
    // for them, so the engine would re-gate them at every voiceOn and the
    // voice would stay without them. A live one leaves synths first, so its
    // onFree does not start it again: the start that follows (gateVoice)
    // builds what the voice is missing.
    forgetFailedStarts { arg voice;
        var keys = [this.voiceKey(voice), this.grainKey(voice), this.modKey(voice)];
        var failed = (keys.collect({ arg key; synths[key] }) ++ releasingSynths[voice].values.asArray
            ++ fadingSynths[voice].asArray ++ cuttingSynths[voice].asArray).select({ arg synth;
            synth.notNil and: { this.startFailed(synth) }
        }).as(IdentitySet);
        keys.do({ arg key; if (synths[key].notNil and: { failed.includes(synths[key]) }) { synths.removeAt(key) } });
        failed.do({ arg synth; this.endFailedStart(synth) });
    }

    // What NodeWatcher does at a synth's /n_end, for one that never started:
    // it is no longer watched and its onFree runs. In case it did start after
    // all (a /n_go held up past startConfirmWait), it is freed, quietly.
    endFailedStart { arg synth;
        this.sendToSynth(synth.freeMsg);
        NodeWatcher.unregister(synth);
        synth.isPlaying = false;
        synth.isRunning = false;
        synth.changed(\n_end);
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
    // waiting for its fade no longer runs. Every extra note of the voice is
    // cut and each live one restarted on the new source (restartNotes, the
    // notes area's). All of it goes in one bundle, so it lands in one block.
    replaceGrainSynth { arg voice;
        context.server.makeBundle(nil, { this.switchGrainSynth(voice) });
    }

    // replaceGrainSynth's work, inside its bundle
    switchGrainSynth { arg voice;
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
        this.restartNotes(voice);
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
    // forgets them; they are never in synths or releasingSynths. A synth
    // that never started is forgotten first (forgetFailedStarts): once out
    // of the cutting set nothing would find it again, and it would stay a
    // ring reader and an unconfirmed start for good (#497).
    freeCuttingSynths { arg voice;
        this.forgetFailedStarts(voice);
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
    // is always re-gated by voiceOn, never superseded. Every live extra note
    // of the voice is released with it (releaseNotes, the notes area's).
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
        this.releaseNotes(voice);
    }
}
