// StrataEnvelopes.sc
// The envelopes area (3.7, design §7.1, §7.3): envelope nodes that a
// voice's hits fire and that write the fast-modulation buses. A route
// (0..numEnvRoutes - 1, Lua's matrix slot) has at most one node,
// \strataEnvelope, at the tail of the modulation area's fastModGroup, on one
// channel of fastModBus (fastModChannel); its source is the voice whose
// hits fire it. The voiceHit hook sends each route of the hit voice its
// hold and a trigger, in one message: no message from Lua per hit, and
// never a node per hit. setFastEnv starts, moves and sets a route's node;
// stopFastEnv releases it. The rules are the engine LFOs': offsets only,
// one node per route at every moment (a releasing one included), a channel
// zeroed when its last writer ends, every message through sendToSynth. See
// docs/notes/engine/envelopes.md.

+ Engine_Strata {
    // The routes (setFastEnv's route 0-15): one per matrix slot. Lua's
    // S.constants.MATRIX_SLOTS is the same number (a docs test compares them)
    numEnvRoutes { ^16 }

    // The envelopes area (order 190, after modulation's 160: fastModGroup
    // exists from its start)
    strataAreaEnvelopes {
        ^(
            order: 190,
            allocState: { this.areaCall(\allocEnvelopes) },
            addDefs: { this.areaCall(\addEnvelopeDefs); [] },
            addCommands: { this.areaCall(\addEnvelopeCommands) },
            start: { this.areaCall(\startEnvelopes) },
            stop: { this.areaCall(\stopEnvelopes) },
            voiceHit: { arg voice, kind; this.areaCall(\envelopesHit, voice, kind) }
        )
    }

    // areaState[\envelopes]: routes (one place per route: nil, or an Event
    // of its node and settings), nodeChannels (each envelope node -> the
    // channel it writes, until it ends), received (what each command last
    // took, for the engine check) and stopped (true until start: the area
    // not started yet). While it is true, and once the engine is past stop
    // (pastStop, from free's stop phase, #942), commands and hits do
    // nothing, and no node's end restarts or zeroes anything
    allocEnvelopes {
        var state = areaState[\envelopes];
        state[\routes] = Array.newClear(this.numEnvRoutes);
        state[\nodeChannels] = IdentityDictionary.new;
        state[\received] = IdentityDictionary.new;
        state[\stopped] = true;
    }

    startEnvelopes { areaState[\envelopes][\stopped] = false }

    // The places are forgotten first, and the engine is past stop by now
    // (pastStop), so no node's end starts another or zeroes a channel; the
    // nodes are freed (the modulation area's stop,
    // after this one, frees fastModGroup too)
    stopEnvelopes {
        var state = areaState[\envelopes], nodes = state[\nodeChannels].keys;
        state[\routes] = Array.newClear(this.numEnvRoutes);
        state[\nodeChannels] = IdentityDictionary.new;
        nodes.do({ arg synth; this.sendToSynth(synth.freeMsg) });
    }

    // \strataEnvelope (design §7.1): 0 to 1 over attack, 1 to sustain over
    // decay, sustain for hold, sustain to 0 over release, each slope bent by
    // curve, from a trigger (t_hit, or loop's restart); a trigger starts the
    // attack from the level the envelope is at (EnvGen restarts a segment
    // from its current level). Sustain 0 is an attack and a decay: its hold
    // and release take no time. With loop 1 it starts again each time it
    // ends (the end, read through LocalIn, is a trigger a block later),
    // and at once when it has never run. The shape times depth (lagged 20
    // ms) on one channel, under a 20 ms ASR on gate that frees the node at
    // its release's end. Control rate, no delay line or table (LocalIn.kr
    // keeps one value in the graph)
    addEnvelopeDefs {
        var fade = this.fastLfoFadeSeconds;
        SynthDef(\strataEnvelope, { arg out, depth = 0, attack = 0.005, decay = 0.2, sustain = 0, release = 0.2, curve = -4,
            loop = 0, hold = 0, t_hit = 0, gate = 1;
            var ended = LocalIn.kr(1, 1), held = sustain > 0, trigger, shape, gateEnv;
            trigger = t_hit + ((loop > 0) * ended);
            shape = EnvGen.kr(Env([0, 1, sustain, sustain, 0], [attack, decay, hold * held, release * held], curve), trigger);
            // ended: the envelope has run to its end, or has never run
            LocalOut.kr(Done.kr(shape).max(PulseCount.kr(trigger) < 1));
            gateEnv = EnvGen.kr(Env.asr(fade, 1, fade), this.openedGate(gate), doneAction: 2);
            Out.kr(out, shape * depth.lag(fade) * gateEnv);
        }).add;
    }

    // A route's node from its place (its controls), at the tail of
    // fastModGroup, watched until it ends
    startFastEnv { arg route, place;
        var synth = Synth(\strataEnvelope, place[\controls], areaState[\modulation][\fastModGroup], \addToTail);
        ^this.areaCall(\watchFastEnv, route, synth, place[\channel])
    }

    watchFastEnv { arg route, synth, channel;
        areaState[\envelopes][\nodeChannels][synth] = channel;
        synth.onFree({ this.fastEnvEnded(route, synth) });
        ^synth
    }

    // Whether no envelope node writes channel now
    envChannelUnwritten { arg channel; ^areaState[\envelopes][\nodeChannels].includes(channel).not }

    // A route's node ended. Still its place's and running: its release ended
    // just as setFastEnv re-gated it, so it starts again (a route is never
    // left without its node). Its place's, not running (stopFastEnv
    // released it): the route has none now.
    // Either way, or for a node no longer its route's, its channel goes to 0
    // unless another envelope node writes it now
    fastEnvEnded { arg route, synth;
        var state = areaState[\envelopes], channel = state[\nodeChannels].removeAt(synth), place;
        if (state[\stopped] or: { this.pastStop }) { ^this };
        place = state[\routes][route];
        if (place.notNil and: { place[\synth] === synth }) {
            if (place[\running]) { place[\synth] = this.startFastEnv(route, place); ^this };
            state[\routes][route] = nil;
        };
        if (channel.notNil and: { this.envChannelUnwritten(channel) }) { this.zeroFastModChannels(channel, 1) };
    }

    // Edits keep the active segment of a route from the same source.
    // A new source gets a fresh generator, including when the old node
    // is releasing. Only the source's own hits (or its loop) start it.
    setFastEnv { arg route, source, voice, destination, depth, attack, decay, sustain, release, curve, loop;
        var state = areaState[\envelopes], place = state[\routes][route], channel = this.fastModChannel(voice, 0, destination);
        var controls = [\out, channel, \depth, depth, \attack, attack, \decay, decay, \sustain, sustain, \release, release,
            \curve, curve, \loop, loop];
        var oldChannel, sourceChanged;
        if (state[\stopped] or: { this.pastStop }) { ^this };
        if (place.isNil) {
            place = (source: source, channel: channel, controls: controls, running: true);
            state[\routes][route] = place;
            place[\synth] = this.startFastEnv(route, place);
            ^this
        };
        oldChannel = place[\channel];
        sourceChanged = place[\source] != source;
        place[\source] = source;
        place[\channel] = channel;
        place[\controls] = controls;
        place[\running] = true;
        if (sourceChanged) {
            context.server.makeBundle(nil, {
                var old = place[\synth];
                this.sendToSynth(old.freeMsg);
                state[\nodeChannels].removeAt(old);
                place[\synth] = this.areaCall(\startFastEnv, route, place);
                if ((oldChannel != channel) and: { this.envChannelUnwritten(oldChannel) }) {
                    this.zeroFastModChannels(oldChannel, 1);
                };
            });
            ^this
        };
        state[\nodeChannels][place[\synth]] = channel;
        this.sendToSynth(*([place[\synth].setMsg(\gate, 1, *controls)]
            ++ (if ((oldChannel != channel) and: { this.envChannelUnwritten(oldChannel) }) { [['/c_fill', oldChannel, 1, 0]] } { [] })));
    }

    // stopFastEnv: release the route's node (20 ms); its channel is zeroed
    // when it ends (fastEnvEnded). No-op without a running node
    stopFastEnv { arg route;
        var place = areaState[\envelopes][\routes][route];
        if (place.notNil and: { place[\running] }) {
            place[\running] = false;
            this.sendToSynth(place[\synth].setMsg(\gate, 0));
        };
    }

    // A hit on voice (every kind: \start, \retrigger, \note): each running
    // route whose source is voice gets the hit's hold (ruling 26: seqGate x
    // gateSeconds as the stage keeps them, 0 and 0.1 until Lua sends them)
    // and a trigger, in one message. An inlined while, no closure: hits can
    // come hundreds a second
    envelopesHit { arg voice, kind;
        var state = areaState[\envelopes], places = state[\routes], route = 0, place, controls, hold;
        if (state[\stopped] or: { this.pastStop }) { ^this };
        controls = grainControls[voice];
        hold = (controls[\seqGate] ? 0) * (controls[\gateSeconds] ? 0.1);
        while { route < places.size } {
            place = places[route];
            if (place.notNil and: { place[\running] } and: { place[\source] == voice }) {
                this.sendToSynth(place[\synth].setMsg(\hold, hold, \t_hit, 1));
            };
            route = route + 1;
        };
    }

    // What a command took, for the engine check
    receiveEnvelope { arg command, values;
        areaState[\envelopes][\received][command] = values;
    }

    // The two commands (design §7.3). Each checks its indices, then every
    // continuous argument's finiteness, as the modulation area's do (a bad
    // one of either is ignored with one line, and the command does
    // nothing), clips the continuous arguments only then, records what it
    // took and acts. The Lua engine stub reads the clips (name =
    // msg[i].clip(...)) as its limits, and its index limits from
    // numEnvRoutes and the modulation area's numbers
    addEnvelopeCommands {
        var lastRoute = this.numEnvRoutes - 1, lastVoice = numVoices - 1, lastDestination = this.numFastDestinations - 1;

        // Route route, fired by source's hits, on voice's fast destination
        // (note slot 0): depth (half ranges), attack, decay and release (s),
        // sustain (0-1), curve and loop (0 or 1)
        this.addCommand(\setFastEnv, "iiiiffffffi", { arg msg;
            var route = msg[1], source = msg[2], voice = msg[3], destination = msg[4], loop = msg[11];
            var depth, attack, decay, sustain, release, curve;
            if (this.fastModIndicesValid(\setFastEnv, [[\route, route, lastRoute], [\source, source, lastVoice],
                [\voice, voice, lastVoice], [\destination, destination, lastDestination], [\loop, loop, 1]])
                and: { this.fastModValuesFinite(\setFastEnv, [[\depth, msg[5]], [\attack, msg[6]], [\decay, msg[7]],
                    [\sustain, msg[8]], [\release, msg[9]], [\curve, msg[10]]]) }) {
                depth = msg[5].clip(-2, 2); attack = msg[6].clip(0.001, 10); decay = msg[7].clip(0.001, 10);
                sustain = msg[8].clip(0, 1); release = msg[9].clip(0.001, 10); curve = msg[10].clip(-8, 8);
                this.receiveEnvelope(\setFastEnv, [route, source, voice, destination, depth, attack, decay, sustain, release, curve, loop]);
                this.setFastEnv(route, source, voice, destination, depth, attack, decay, sustain, release, curve, loop);
            };
        });

        // Release a route's node
        this.addCommand(\stopFastEnv, "i", { arg msg;
            var route = msg[1];
            if (this.fastModIndicesValid(\stopFastEnv, [[\route, route, lastRoute]])) {
                this.receiveEnvelope(\stopFastEnv, [route]);
                this.stopFastEnv(route);
            };
        });
    }
}
