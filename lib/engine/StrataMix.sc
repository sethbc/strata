// StrataMix.sc
// The mix area: one persistent mix stage per voice (\strataVoiceMix), which
// holds what all of a voice's grain synths share: the voice filter
// (voiceFilter), the voice-level gain (voiceLevel), its dry level and its
// delay and reverb sends (voiceOutput: 3.8's plain sends), the mirror and
// the voice tap. Holds the voices' path buses and mix groups, the send
// buses and their filtered copies. See docs/notes/engine/mix.md.

+ Engine_Strata {
    // The mix area (order 120)
    strataAreaMix {
        ^(
            order: 120,
            allocState: { this.areaCall(\allocMixBuses) },
            addDefs: { this.areaCall(\addVoiceMixDef); [\strataVoiceMix] },
            start: { this.areaCall(\startVoiceMixes) },
            stop: { this.areaCall(\stopVoiceMixes) },
            free: { this.areaCall(\freeMixBuses) },
            effectKeys: numVoices.collect({ arg voice; this.voiceMixKey(voice) }),
            // The stage's own grain params: kept with the voice's other grain
            // controls (so a replaced stage restarts with them), then sent
            // to the stage, never to a grain synth
            grainParamHandlers: (
                filterType: { arg voice, value; this.setStageParam(voice, \filterType, value) },
                filterFreq: { arg voice, value; this.setStageParam(voice, \filterFreq, value) },
                filterRes: { arg voice, value; this.setStageParam(voice, \filterRes, value) },
                filterMix: { arg voice, value; this.setStageParam(voice, \filterMix, value) },
                dry: { arg voice, value; this.setStageParam(voice, \dry, value) },
                delaySend: { arg voice, value; this.setStageParam(voice, \delaySend, value) },
                reverbSend: { arg voice, value; this.setStageParam(voice, \reverbSend, value) }
            )
        )
    }

    // A stage's persistent key (one of effectKeys)
    voiceMixKey { arg voice; ^("voiceMix" ++ voice).asSymbol }

    // A voice's mix group (areaState[\mix][\mixGroups]): buffer and input
    // grain synths at its head, the stage at its tail, just before the
    // voice's mod synth in processGroup
    voiceMixGroup { arg voice; ^areaState[\mix][\mixGroups][voice] }

    // The bus a grain synth of this source writes: the synth path for the
    // voice's own synth (source 0), the other path for a slot or the input
    voicePathBus { arg voice, source;
        ^if (source == 0) { areaState[\mix][\synthPaths][voice] } { areaState[\mix][\otherPaths][voice] }
    }

    // The voice-level gain: amp, the amplitude crossmod and the accent. The
    // one place this level is computed: the stage applies it on the other
    // path, every voice SynthDef to its own output (voiceModulation,
    // StrataVoiceDefs.sc); 3.4's offsets change only its callers
    voiceLevel { arg amp, modSig, accent;
        ^(amp * (1 + modSig) * (1 + accent)).clip(0, 2)
    }

    // Keep the value with the voice's grain controls and set it on the stage
    setStageParam { arg voice, param, value;
        grainControls[voice][param] = value;
        this.setSynth(this.voiceMixKey(voice), param, value);
        ^true
    }

    // The lag (s) of every send, dry level and return level (and of a lifted
    // node's input fade, liftFade): 3.0's delay lagged its mix by as much
    fxMixLag { ^0.05 }

    // The buses (areaState[\mix]): the delay and reverb sends (stereo audio,
    // written by every stage) and their copies after the master filter
    // (...Post). The effects area's buses are
    // named here too: dry (mainBus, every stage's out), dryPost
    // (filterBus), delayReturn (delayBus) and reverbReturn (reverbBus). Each
    // voice has its two paths (stereo audio): the synth path (synthPaths,
    // written by its synth-source grain synths) and the other path
    // (otherPaths, its buffer and input grain synths), and its mix group
    // (mixGroups, created in start). stageControls holds, per voice, the
    // Dictionary a stage starts with: its buses and silent mod slots (never
    // SynthDef defaults, which are the buses of the last engine built);
    // tapOut is added in start, once the record area has allocated the taps.
    allocMixBuses {
        var state = areaState[\mix], server = context.server;
        [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].do({ arg name; state[name] = Bus.audio(server, 2) });
        state[\dry] = mainBus;
        state[\dryPost] = filterBus;
        state[\delayReturn] = delayBus;
        state[\reverbReturn] = reverbBus;
        state[\synthPaths] = Array.fill(numVoices, { Bus.audio(server, 2) });
        state[\otherPaths] = Array.fill(numVoices, { Bus.audio(server, 2) });
        state[\mixGroups] = Array.newClear(numVoices);
        state[\replacing] = Array.fill(numVoices, false);
        state[\stageControls] = Array.fill(numVoices, { arg voice;
            var controls = Dictionary[
                \voice -> voice, \synthIn -> state[\synthPaths][voice].index, \otherIn -> state[\otherPaths][voice].index,
                \out -> mainBus.index, \mirrorOut -> granBuses[voice].index,
                \modBus1 -> silentBus.index, \modBus2 -> silentBus.index, \modBus3 -> silentBus.index
            ];
            controls.putAll(this.mixBusControls);
            controls
        });
    }

    // A mix bus by name (areaState[\mix])
    mixBus { arg name;
        ^areaState[\mix][name]
    }

    // A stage's bus controls (voiceOutput's named controls) for this
    // engine's buses
    mixBusControls {
        ^Dictionary[
            \delaySendOut -> this.mixBus(\delaySend).index,
            \reverbSendOut -> this.mixBus(\reverbSend).index
        ]
    }

    // The mix area's own buses (every node is gone by now)
    freeMixBuses {
        var state = areaState[\mix];
        [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].do({ arg name; this.mixBus(name).free });
        (state[\synthPaths] ++ state[\otherPaths]).do({ arg bus; bus.free });
    }

    // The voice's stage. Persistent (started in the mix area's start, freed
    // in its stop, an effectKey): what its grain synths play is filtered
    // once, on two paths (the synth path needs no level, a voice synth
    // already applied amp, crossmod and accent; the other path takes the
    // voice-level gain after its filter, so a moving gain is not smeared
    // through the filter's memory). The two inputs and the two filtered
    // pairs go through zeroBadValues (a NaN from one grain synth, or a
    // filter gone bad, never reaches the buses); a stage whose filter goes
    // bad (its raw outputs read NaN or inf: codes 1 and 2 of
    // CheckBadValues, never code 3, a denormal) is replaced in place
    // (replaceBadVoiceMix). The mirror is the other path only, filtered and
    // after the level; the tap the whole output, before the dry level and the
    // sends (so a voice at dry 0 still records and feeds its readers).
    // voiceMixMod (the modulation area's, StrataModulation.sc) declares the
    // stage's fastModIn, gate and mute controls and gives the level lines
    // their amp offset and gate.
    addVoiceMixDef {
        SynthDef(\strataVoiceMix, {
            arg synthIn, otherIn, out, mirrorOut, amp=1, modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0, t_trig=0, velocity=1,
            filterType=0, filterFreq=5000, filterRes=0.5, filterMix=0, dry=1, delaySend=1, reverbSend=1;
            var voice = \voice.kr(0);
            var c = this.voiceMixMod((
                synthIn: synthIn, otherIn: otherIn, out: out, mirrorOut: mirrorOut,
                tapOut: \tapOut.kr(areaState[\record][\tapSink].index),
                amp: amp, modBuses: [modBus1, modBus2, modBus3], modAmpAmts: [modAmpAmt1, modAmpAmt2, modAmpAmt3],
                t_trig: t_trig, velocity: velocity, filterType: filterType, filterFreq: filterFreq, filterRes: filterRes,
                filterMix: filterMix, dry: dry, delaySend: delaySend, reverbSend: reverbSend
            ));
            var guard = { arg signal; signal.collect({ arg channel; this.zeroBadValues(channel) }) };
            var synthPath = guard.(In.ar(c[\synthIn], 2)), otherPath = guard.(In.ar(c[\otherIn], 2));
            // one set of lagged controls on four channels: two filter banks
            var raw = this.voiceFilter(synthPath ++ otherPath, c[\filterType], c[\filterFreq], c[\filterRes], c[\filterMix]);
            var codes = raw.collect({ arg channel; CheckBadValues.ar(channel, 0, 0) });
            var bad = codes.collect({ arg code; (code > 0.5) * (code < 2.5) }).sum > 0;
            var filtered = guard.(raw);
            var modSig = this.crossmodAmp(c[\modBuses].collect({ arg bus; In.kr(bus, 1) }), c[\modAmpAmts]);
            var accent = this.voiceAccent(c[\t_trig], c[\velocity]);
            // (3.4's amp offset on both paths, and its gate and mute on the
            // whole output but the mirror: voiceMixMod's ampOffset 0 and
            // voiceGate 1 fold both lines to 3.3's)
            var other = filtered.drop(2) * this.voiceLevel(c[\amp], modSig + c[\ampOffset], accent);
            var sig = ((filtered.keep(2) * this.voiceLevel(1, c[\ampOffset], 0)) + other) * c[\voiceGate];
            SendReply.ar(bad, '/strataVoiceMixBad', voice);
            this.voiceOutput(sig, c[\out], c[\dry], c[\delaySend], c[\reverbSend]);
            Out.ar(c[\mirrorOut], other);
            Out.ar(c[\tapOut], sig);
        }).add;
    }

    // The seven mix groups, at the tail of processGroup in voice order (the
    // first mod synth moves its group next to it), a stage at each group's
    // tail, the voice's tap on its stageControls, and the responder that
    // replaces a stage whose filter went bad
    startVoiceMixes {
        var state = areaState[\mix];
        numVoices.do({ arg voice;
            state[\stageControls][voice][\tapOut] = areaState[\record][\voiceTaps][voice].index;
            state[\mixGroups][voice] = Group.tail(processGroup);
            synths[this.voiceMixKey(voice)] = Synth(\strataVoiceMix, this.voiceMixArgs(voice),
                state[\mixGroups][voice], \addToTail);
        });
        state[\badResponder] = OSCFunc({ arg msg; this.areaCall(\replaceBadVoiceMix, msg[1], msg[3].asInteger) },
            '/strataVoiceMixBad', context.server.addr);
    }

    // A stage's start controls: its buses and silent mod slots, then the
    // voice's kept values (amp, crossmod routing and amounts, filter, sends)
    voiceMixArgs { arg voice;
        ^areaState[\mix][\stageControls][voice].asKeyValuePairs
            ++ this.controlPairs(\strataVoiceMix, voiceControls[voice])
            ++ this.controlPairs(\strataVoiceMix, grainControls[voice])
    }

    // Replace a stage whose filter went bad, in place (one server step, the
    // same group and key), from its start controls and the voice's kept
    // values. nodeID is the stage that sent the reply: a reply from a node
    // already replaced, or from another engine on this server, does
    // nothing, and at most one replacement per voice is in flight.
    replaceBadVoiceMix { arg nodeID, voice;
        var state = areaState[\mix], key, old, replacement;
        if (this.validVoice(voice)) {
            key = this.voiceMixKey(voice);
            old = synths[key];
            if (old.notNil and: { old.nodeID == nodeID } and: { state[\replacing][voice].not }) {
                state[\replacing][voice] = true;
                replacement = Synth.replace(old, \strataVoiceMix, this.voiceMixArgs(voice));
                synths[key] = replacement;
                OSCFunc({ state[\replacing][voice] = false }, '/n_go', context.server.addr, argTemplate: [replacement.nodeID]).oneShot;
                ("strata: voice " ++ (voice + 1) ++ " mix stage reset (bad values)").postln;
            };
        };
    }

    // The stages, then their groups (quietly, as every node is freed here)
    stopVoiceMixes {
        var state = areaState[\mix];
        state[\badResponder] !? { arg responder; responder.free };
        numVoices.do({ arg voice;
            var synth = synths.removeAt(this.voiceMixKey(voice));
            if (synth.notNil) { this.sendToSynth(synth.freeMsg); synth.free(false) };
        });
        state[\mixGroups].do({ arg group; group !? { group.free } });
    }

    // A signal's stereo output through the voice's own filter: the
    // master filter's design (multimodeFilter: the three types weighted by
    // a lagged type match, so a type change crossfades over 20 ms; the
    // cutoff rises at most cutoffRiseRate), with the cutoff and mix lagged
    // 0.05 s as the master's. filterMix 0 (the default) passes sig unchanged.
    // filterType is only rounded (Lua sends 0-2; any other value leaves the
    // filter out), one UGen less in every stage than the master's clip.
    voiceFilter { arg sig, filterType, filterFreq, filterRes, filterMix;
        ^this.multimodeFilter(sig, filterFreq.lag(0.05).clip(20, 20000), filterRes.clip(0, 1), filterType.round,
            filterMix.lag(0.05).clip(0, 1))
    }

    // Write a stage's stereo output: plain sends (3.8). The dry bus takes
    // the signal times the voice's dry level, each send bus the signal times
    // its send (each 0-1, lagged fxMixLag); the sends are taken before the
    // dry level, so a voice at dry 0 is fully wet. The returns are levels of
    // their own (the delay's and the reverb's mix), and the master sums the
    // three (masterSum, StrataEffects.sc). (The stage writes the mirror and
    // the tap itself, before the dry level.)
    voiceOutput { arg sig, out, dry, delaySend, reverbSend;
        Out.ar(out, sig * dry.clip(0, 1).lag(this.fxMixLag));
        Out.ar(\delaySendOut.kr(this.mixBus(\delaySend).index), sig * delaySend.clip(0, 1).lag(this.fxMixLag));
        Out.ar(\reverbSendOut.kr(this.mixBus(\reverbSend).index), sig * reverbSend.clip(0, 1).lag(this.fxMixLag));
    }
}
