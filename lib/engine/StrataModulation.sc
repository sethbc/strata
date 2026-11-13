// StrataModulation.sc
// The modulation area: 3.4's fast modulation. Five destinations per voice
// (pitch, position, size, cutoff, amp) take an offset from a control bus,
// fastModBus, indexed by (voice, note slot, destination) through
// fastModChannel only. The writers run in fastModGroup, before voiceGroup:
// the offset node (\strataFastOffsets, the values Lua's matrix computes) at
// its head, then the engine LFOs (one node per LFO, one SynthDef per shape)
// and scatter. The grain SynthDefs (pitch, position, size) and the per-voice
// mix stage (cutoff, amp) add the offsets to what Lua sent, which they never
// store: Lua owns every base value, the buses hold offsets only. The stage's
// step gate and mute are this area's too (voiceMixMod). See
// docs/notes/engine/modulation.md.

+ Engine_Strata {
    // Fast destinations per voice: 0 pitch, 1 position, 2 size, 3 cutoff,
    // 4 amp. Lua's S.constants.NUM_FAST_DESTINATIONS is the same number (a
    // docs test compares them)
    numFastDestinations { ^5 }

    // Note slots per voice on fastModBus: one, the voice's (3.5 keeps it at
    // one, design 3.5 Question 1: a note's own values are its synth's
    // per-note controls, and every note of a voice reads the voice's block).
    // Lua's S.constants.FAST_MOD_NOTE_SLOTS is the same number
    fastModNoteSlots { ^1 }

    // Engine LFOs (setFastLfo's lfo 0-5, Lua's LFOs 1-6) and their shapes
    // (sine, tri, square, up, down, s&h, smooth, drunk)
    numFastLfos { ^6 }
    numFastLfoShapes { ^8 }

    // An offset m is in half ranges: pitch, position and size move by m x
    // these (half of the Lua specs' ranges of grain_pitch 0.25-4, buf_pos
    // 0-1 and grain_size 0.01-0.5; a docs test compares them), the cutoff
    // by fastModCutoffFactor ^ m (31.62 squared is filter_freq's 20-20000:
    // m = 1 is half its ten octaves)
    fastModHalfRanges { ^[1.875, 0.5, 0.245] }
    fastModCutoffFactor { ^31.62 }

    // The engine LFO SynthDefs, one per shape, in shape order
    fastLfoShapeNames { ^[\Sine, \Tri, \Square, \Up, \Down, \Sah, \Smooth, \Drunk] }
    fastLfoDefName { arg shape; ^("strataFastLfo" ++ this.fastLfoShapeNames[shape]).asSymbol }

    // The envelopes' attack and release (s): an engine LFO's (and its depth
    // lag), scatter's; and the lag of scatter's gains (s), so a lock, an
    // unlock, a mask or a depth change glides (#610)
    fastLfoFadeSeconds { ^0.02 }
    scatterFadeSeconds { ^0.5 }
    scatterGainLagSeconds { ^0.5 }

    // The offset node's key in synths (one of effectKeys: it never ends on
    // its own, so messages to it go plainly)
    fastOffsetsKey { ^\fastOffsets }

    // The step gate's attack (s, design 3.4 §8.12), as the stage's
    // control-rate envelope runs it: whole control blocks, at least 5 ms (4
    // blocks, 5.33 ms, at 48 kHz). EnvGen.kr ends a segment on its whole
    // blocks without reaching its level (5 ms, 3.75 blocks, stopped at 0.8),
    // and the next segment starts there: the hold would climb from 0.8 to 1
    // over gateSeconds. A hundredth of a block over the whole number keeps
    // the float product from rounding down a block; the attack reaches
    // 4 / 4.01 of the level and the hold the rest.
    gateAttackSeconds {
        var server = context.server, blockSeconds = server.options.blockSize / (server.sampleRate ? 48000);
        ^((0.005 / blockSeconds).ceil + 0.01) * blockSeconds
    }

    // The modulation area (order 160)
    strataAreaModulation {
        ^(
            order: 160,
            allocState: { this.areaCall(\allocFastModulation) },
            addDefs: { this.areaCall(\addFastModDefs); [] },
            addCommands: { this.areaCall(\addFastModCommands) },
            start: { this.areaCall(\startFastModulation) },
            stop: { this.areaCall(\stopFastModulation) },
            free: { this.areaCall(\freeFastModBuses) },
            effectKeys: [this.fastOffsetsKey],
            // The stage's gate and mute (design 3.4 §8.12, §8.14), as the mix
            // area's filter and send params: kept with the voice's grain
            // controls (a replaced stage restarts with them) and sent to the
            // stage, never to a grain synth
            grainParamHandlers: (
                seqGate: { arg voice, value; this.setStageParam(voice, \seqGate, value) },
                gateSeconds: { arg voice, value; this.setStageParam(voice, \gateSeconds, value) },
                gateRelease: { arg voice, value; this.setStageParam(voice, \gateRelease, value) },
                voiceMute: { arg voice, value; this.setStageParam(voice, \voiceMute, value) }
            )
        )
    }

    // areaState[\modulation]: fastModBus (control, numVoices x
    // fastModNoteSlots x numFastDestinations channels: 35), silentFastModBus
    // (numFastDestinations channels, always 0: the default fastModIn of the
    // grain SynthDefs and the stage, never control bus 0, norns' input
    // follower), lfos (one place per engine LFO: an Event of its node and
    // settings, or nil), scatter (its place), nodeChannels (each LFO node ->
    // the channel it writes), received (what each command last took, for the
    // engine check), stopped and fastModGroup (made in start). Every voice's
    // grain synths and stage read its note slot 0 block: fastModIn in
    // grainControls (every grain synth, replacements and restarts included,
    // starts with it) and in the mix area's stageControls (made by then:
    // order 120)
    allocFastModulation {
        var state = areaState[\modulation], server = context.server;
        state[\fastModBus] = Bus.control(server, numVoices * this.fastModNoteSlots * this.numFastDestinations);
        state[\fastModBus].setAll(0);
        state[\silentFastModBus] = Bus.control(server, this.numFastDestinations);
        state[\silentFastModBus].setAll(0);
        state[\lfos] = Array.newClear(this.numFastLfos);
        state[\scatter] = nil;
        state[\nodeChannels] = IdentityDictionary.new;
        state[\received] = IdentityDictionary.new;
        state[\stopped] = true;
        numVoices.do({ arg voice;
            var block = this.fastModBlock(voice, 0);
            grainControls[voice][\fastModIn] = block;
            areaState[\mix][\stageControls][voice][\fastModIn] = block;
        });
    }

    // The area's buses (every node is gone by now)
    freeFastModBuses {
        var state = areaState[\modulation];
        [\fastModBus, \silentFastModBus].do({ arg name; state[name] !? { arg bus; bus.free } });
    }

    // fastModGroup, at the head of xg (before voiceGroup, so the offsets are
    // written before any grain synth or stage reads them in a block), with
    // the offset node at its head, from start to stop
    startFastModulation {
        var state = areaState[\modulation];
        state[\stopped] = false;
        state[\fastModGroup] = Group.before(voiceGroup);
        synths[this.fastOffsetsKey] = Synth(\strataFastOffsets, [\out, this.fastModBlock(0, 0)], state[\fastModGroup], \addToHead);
    }

    // Every node goes with the group. The places are forgotten first, so no
    // node's end starts another or zeroes a channel
    stopFastModulation {
        var state = areaState[\modulation];
        state[\stopped] = true;
        state[\lfos] = Array.newClear(this.numFastLfos);
        state[\scatter] = nil;
        synths.removeAt(this.fastOffsetsKey);
        state[\fastModGroup] !? { arg group; group.free };
    }

    // The channel of voice v's note slot n, destination d: index + (v x
    // slots + n) x numFastDestinations + d. Every writer and reader of
    // fastModBus goes through fastModChannel, so more note slots would change
    // fastModNoteSlots and nothing else; fastModChannelFor takes the slot
    // count (the engine check runs it with six)
    fastModChannelFor { arg voice, noteSlot, destination, slots;
        ^areaState[\modulation][\fastModBus].index + ((((voice * slots) + noteSlot) * this.numFastDestinations) + destination)
    }
    fastModChannel { arg voice, noteSlot, destination;
        ^this.fastModChannelFor(voice, noteSlot, destination, this.fastModNoteSlots)
    }

    // A block's first channel (destination 0): what a grain synth or stage
    // reads its numFastDestinations channels from. fastModBlock(0, 0) is the
    // bus's first channel, which the whole-bus writers (the offset node,
    // scatter) write from
    fastModBlock { arg voice, noteSlot;
        ^this.fastModChannel(voice, noteSlot, 0)
    }

    // Zero count channels from first (/c_fill): a writer that ended leaves
    // its last value on a control bus
    zeroFastModChannels { arg first, count;
        context.server.sendMsg('/c_fill', first, count, 0);
    }

    // The hooks. fastModRead: the block's offsets, one per destination, in
    // one In.kr (both grain SynthDefs, before their controls Event and
    // reader; the stage, in voiceMixMod).
    fastModRead { arg fastModIn; ^In.kr(fastModIn, this.numFastDestinations) }

    // fastMod: the grain controls Event with pitch and size offset (called
    // first in grainSignal, before grainRate, grainDur and the readers; the
    // offsets are the Event's fastMod), clipped to the Lua specs' ranges.
    // 3.5's note: pitchShift x the Event's noteRate (a frozen synth voice's
    // note's rate, before quantize; 1 in \strataGrainBuf) and the note's
    // size offset, the Event's noteSize (half ranges, lagged noteLag), added
    // to the block's. The cutoff and amp channels are read and unused: the
    // stage applies them (a note's own gain is grainSignal's, from noteAmp).
    fastMod { arg controls;
        var c = controls.copy, m = controls[\fastMod], half = this.fastModHalfRanges;
        c[\pitchShift] = ((c[\pitchShift] * c[\noteRate]) + (half[0] * m[0])).clip(0.25, 4);
        c[\grainSize] = (c[\grainSize] + (half[2] * (m[2] + c[\noteSize].lag(this.noteLag)))).clip(0.01, 0.5);
        ^c
    }

    // fastModPosition: a buffer grain's bufPos with its position offset and
    // 3.5's note's (notePos, half ranges, lagged noteLag) (strataGrainBuf,
    // before slotGrainReader, so slotScanPhase and slotHeadGuard see it),
    // clipped to 0-1
    fastModPosition { arg bufPos, m, notePos;
        ^(bufPos + (this.fastModHalfRanges[1] * (m[1] + notePos.lag(this.noteLag)))).clip(0, 1)
    }

    // voiceMixMod: the stage's controls Event (\strataVoiceMix, before both
    // filter banks and voiceLevel). Declares the stage's fastModIn (its
    // voice's block, from stageControls; default the silent bus) and the gate
    // and mute controls (design 3.4 §8.12, §8.14), reads the block, and sets
    // what the stage reads: filterFreq x fastModCutoffFactor ^ m3 (clipped to
    // 20-20000, before both banks and their 0.05 s lag), ampOffset m4
    // (through voiceLevel on both paths) and voiceGate, the factor on the
    // stage's whole output after the mirror's tap of the other path:
    //   (1 - gate lagged 20 ms x (1 - env)) x (1 - mute lagged 20 ms)
    // (seqGate switched on a running voice, or at a recall's end, glides as
    // the mute does, #614; a gate held at 1 is exactly 1, so the envelope's
    // attack and release are unchanged)
    // env is gateAttackSeconds up (5 ms in whole control blocks),
    // gateSeconds held, gateRelease down, started by the
    // stage's t_trig (retrigger's, the accent's) and restarted from its level
    // by a new one; velocity never reaches it. With every channel at 0,
    // seqGate 0 and voiceMute 0 the stage plays 3.3's graph's values.
    voiceMixMod { arg controls;
        var fastModIn = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index), m = this.fastModRead(fastModIn);
        var seqGate = \seqGate.kr(0), gateSeconds = \gateSeconds.kr(0.1), gateRelease = \gateRelease.kr(0.1);
        var voiceMute = \voiceMute.kr(0), gate, mute, env;
        // (written on the controls' own names: the Lua stub reads the
        // enumerations from "seqGate.round.clip(0, 1)" and
        // "voiceMute.round.clip(0, 1)")
        gate = seqGate.round.clip(0, 1);
        mute = voiceMute.round.clip(0, 1);
        env = EnvGen.kr(Env([0, 1, 1, 0], [this.gateAttackSeconds, gateSeconds.clip(0.005, 120), gateRelease.clip(0.005, 4)]),
            controls[\t_trig]);
        controls[\fastModIn] = fastModIn;
        controls[\seqGate] = seqGate;
        controls[\gateSeconds] = gateSeconds;
        controls[\gateRelease] = gateRelease;
        controls[\voiceMute] = voiceMute;
        controls[\filterFreq] = (controls[\filterFreq] * (this.fastModCutoffFactor ** m[3])).clip(20, 20000);
        controls[\ampOffset] = m[4];
        controls[\voiceGate] = (1 - (gate.lag(0.02) * (1 - env))) * (1 - mute.lag(0.02));
        ^controls
    }

    // The area's SynthDefs, all control rate: the eight engine LFOs (one
    // function, one def per shape), scatter and the offset node
    addFastModDefs {
        var state = areaState[\modulation], numChannels = state[\fastModBus].numChannels, fade = this.fastLfoFadeSeconds, offsets;
        // An engine LFO: a phase over 0-1 at rate Hz (one step per control
        // block), reset by t_sync to syncPhase; the shape's u (0-1) of it;
        // ((2u - 1) x depth + offset) on one channel, depth lagged and the
        // whole through a 20 ms ASR that frees the node at its release's end
        this.fastLfoShapeNames.do({ arg name, shape;
            SynthDef(this.fastLfoDefName(shape), { arg out, rate = 0.25, depth = 0, offset = 0, t_sync = 0, syncPhase = 0, gate = 1;
                var phase = Phasor.kr(t_sync, rate * ControlDur.ir, 0, 1, syncPhase);
                var u = this.fastLfoShape(shape, phase);
                var env = EnvGen.kr(Env.asr(fade, 1, fade), this.openedGate(gate), doneAction: 2);
                Out.kr(out, ((((2 * u) - 1) * depth.lag(fade)) + offset) * env);
            }).add;
        });
        // Scatter: slow smooth noise on every channel, each at rate x its own
        // spread (drawn here, at build: voices and destinations never move
        // together) times its gain (depth x the channel's voice and
        // destination bits, lagged 0.5 s: a gain set to 0 or back glides,
        // never steps), through a 0.5 s ASR; one Out over the whole bus
        SynthDef(\strataScatter, { arg out, rate = 0.1, gate = 1;
            var gains = Lag.kr(\gains.kr(0 ! numChannels), this.scatterGainLagSeconds), spread = { rrand(0.8, 1.2) } ! numChannels;
            var env = EnvGen.kr(Env.asr(this.scatterFadeSeconds, 1, this.scatterFadeSeconds), this.openedGate(gate), doneAction: 2);
            Out.kr(out, LFDNoise3.kr(rate * spread) * gains * env);
        }).add;
        // The offset node: Lua's offsets (the matrix's sums, half ranges),
        // lagged, on the whole bus
        offsets = SynthDef(\strataFastOffsets, { arg out, lag = 0.05;
            Out.kr(out, Lag.kr(\offsets.kr(0 ! numChannels), lag));
        }).add;
        // (setFastOffset sets one of its values by control index)
        state[\offsetsIndex] = offsets.allControlNames.detect({ arg control; control.name == \offsets }).index;
    }

    // An engine LFO's u (0-1) at phase (§2.2): sine, tri, square, up, down;
    // s&h a new uniform value at each cycle start, held; smooth linear from
    // the last s&h value to the next over the cycle; drunk a random walk of
    // uniform steps of ±0.2, reflected at 0 and 1, linear between, like smooth
    fastLfoShape { arg shape, phase;
        var draws;
        ^switch (shape)
        { 0 } { ((phase * 2pi).sin * 0.5) + 0.5 }
        { 1 } { 1 - ((phase * 2) - 1).abs }
        { 2 } { phase < 0.5 }
        { 3 } { phase }
        { 4 } { 1 - phase }
        { 5 } { this.fastLfoDraws(phase, Dwhite(0, 1, inf))[\next] }
        { 6 } { draws = this.fastLfoDraws(phase, Dwhite(0, 1, inf)); draws[\prev] + ((draws[\next] - draws[\prev]) * phase) }
        { 7 } { draws = this.fastLfoDraws(phase, Dbrown(0, 1, 0.2, inf)); draws[\prev] + ((draws[\next] - draws[\prev]) * phase) }
    }

    // A demand sequence's value drawn at the LFO's start and at each cycle
    // start (the phase falls: a wrap, or a sync back), and the value before
    // it (the start's own at the start: a first cycle from a value to itself)
    fastLfoDraws { arg phase, values;
        var start = Impulse.kr(0) > 0, wrap = (HPZ1.kr(phase) < 0) + start;
        var next = Demand.kr(wrap, 0, values);
        ^(next: next, prev: Latch.kr(Select.kr(start, [Delay1.kr(next), next]), wrap))
    }

    // An engine LFO's node from its place (shape, channel, controls), at the
    // tail of fastModGroup, watched until it ends. A fresh node: not released.
    // It starts at phase 0, or at phase when one is given (a restart,
    // fastLfoEnded: synced in the bundle that makes it, so its first block
    // reads that phase); either way the place's anchor is that phase, now
    startFastLfo { arg lfo, place, phase;
        var defName = this.fastLfoDefName(place[\shape]), group = areaState[\modulation][\fastModGroup], synth;
        if (phase.isNil) {
            synth = Synth(defName, place[\controls], group, \addToTail);
        } {
            context.server.makeBundle(nil, {
                synth = Synth(defName, place[\controls], group, \addToTail);
                this.sendToSynth(synth.setMsg(\syncPhase, phase, \t_sync, 1));
            });
        };
        place[\released] = false;
        this.anchorFastLfo(place, phase ? 0);
        ^this.watchFastLfo(lfo, synth, place[\channel])
    }

    // An LFO's phase anchor (#611): place[\anchor] = [phase, time, rate],
    // the phase its node started at or was synced to at time (sclang's
    // Main.elapsedTime), moving at rate Hz. Set at a node's start, a sync
    // and every set (at the phase reached, so a new rate counts from then),
    // so the phase now is known even when the sync went to a node that had
    // ended (its release over as setFastLfo re-gated it): a node
    // fastLfoEnded starts again begins there, not at 0
    fastLfoRate { arg place; ^place[\controls][place[\controls].indexOf(\rate) + 1] }
    anchorFastLfo { arg place, phase; place[\anchor] = [phase, Main.elapsedTime, this.fastLfoRate(place)] }
    fastLfoPhaseNow { arg place;
        var anchor = place[\anchor];
        ^if (anchor.isNil) { 0 } { (anchor[0] + (anchor[2] * (Main.elapsedTime - anchor[1]))) % 1 }
    }

    watchFastLfo { arg lfo, synth, channel;
        areaState[\modulation][\nodeChannels][synth] = channel;
        synth.onFree({ this.fastLfoEnded(lfo, synth) });
        ^synth
    }

    // An LFO's node ended. Still its place's and running: its release ended
    // just as setFastLfo re-gated it, so it starts again (an LFO is never
    // left without its node), at the place's phase now (the last sync or
    // start, advanced: fastLfoPhaseNow). Its place's, released: the LFO has
    // none now and its channel goes to 0. Another's (replaced, or freed for
    // a new node): its channel goes to 0 unless the LFO's node writes it
    // now. Other writers on that channel write it again in the next block.
    fastLfoEnded { arg lfo, synth;
        var state = areaState[\modulation], channel = state[\nodeChannels].removeAt(synth), place;
        if (state[\stopped]) { ^this };
        place = state[\lfos][lfo];
        if (place.notNil and: { place[\synth] === synth }) {
            if (place[\running]) { place[\synth] = this.areaCall(\startFastLfo, lfo, place, this.fastLfoPhaseNow(place)) } {
                state[\lfos][lfo] = nil;
                channel !? { this.zeroFastModChannels(channel, 1) };
            };
        } {
            if (channel.notNil and: { place.isNil or: { place[\channel] != channel } }) { this.zeroFastModChannels(channel, 1) };
        };
    }

    // setFastLfo: the LFO's node made if it has none; else set (a releasing
    // one re-gated), replaced in the same server step on a new shape
    // (Synth.replace, while the node was never released), moved on a new
    // voice or destination, its old channel zeroed in the same bundle. Never
    // more than one node per LFO. A node released since it started (stopFastLfo;
    // place[\released], cleared only by a fresh node) may have ended on the
    // server already, its /n_end not yet in sclang, even after a re-gate,
    // which then reached nothing: a Synth.replace of it would be refused and
    // make no node, and the place would keep a synth that never started. So
    // its shape change frees it (quietly) and starts a new node, in one bundle.
    // A new node starts at phase 0 (Lua syncs it); a set keeps the phase,
    // re-anchored at the new rate
    setFastLfo { arg lfo, voice, destination, shape, rate, depth, offset;
        var state = areaState[\modulation], place = state[\lfos][lfo], channel = this.fastModChannel(voice, 0, destination);
        var controls = [\out, channel, \rate, rate, \depth, depth, \offset, offset], oldChannel, old, fresh, phase;
        if (state[\stopped]) { ^this };
        if (place.isNil) {
            place = (shape: shape, channel: channel, controls: controls, running: true);
            state[\lfos][lfo] = place;
            place[\synth] = this.areaCall(\startFastLfo, lfo, place);
            ^this
        };
        oldChannel = place[\channel];
        phase = this.fastLfoPhaseNow(place);
        place[\channel] = channel;
        place[\controls] = controls;
        this.anchorFastLfo(place, phase);
        if (shape != place[\shape]) {
            place[\shape] = shape;
            old = place[\synth];
            place[\synth] = if (place[\released].not) {
                this.anchorFastLfo(place, 0);
                this.watchFastLfo(lfo, Synth.replace(old, this.fastLfoDefName(shape), controls), channel)
            } {
                // (startFastLfo through areaCall: the node's onFree keeps
                // the frame watching it, whose caller must not be this
                // function's frame, freed as it returns, #211)
                context.server.makeBundle(nil, {
                    this.sendToSynth(old.freeMsg);
                    fresh = this.areaCall(\startFastLfo, lfo, place);
                });
                fresh
            };
            place[\running] = true;
            if (oldChannel != channel) { this.zeroFastModChannels(oldChannel, 1) };
        } {
            place[\running] = true;
            state[\nodeChannels][place[\synth]] = channel;
            this.sendToSynth(*([place[\synth].setMsg(\gate, 1, *controls)]
                ++ (if (oldChannel != channel) { [['/c_fill', oldChannel, 1, 0]] } { [] })));
        };
    }

    // stopFastLfo: release the LFO's node (20 ms); its channel is zeroed
    // when it ends (fastLfoEnded). No-op without a running node
    stopFastLfo { arg lfo;
        var place = areaState[\modulation][\lfos][lfo];
        if (place.notNil and: { place[\running] }) {
            place[\running] = false;
            place[\released] = true;
            this.sendToSynth(place[\synth].setMsg(\gate, 0));
        };
    }

    // syncFastLfo: the LFO's phase now (a releasing node too), and its
    // anchor (kept for a restart, even when the node has just ended). No-op
    // without a node
    syncFastLfo { arg lfo, phase;
        areaState[\modulation][\lfos][lfo] !? { arg place;
            this.anchorFastLfo(place, phase);
            this.sendToSynth(place[\synth].setMsg(\syncPhase, phase, \t_sync, 1));
        };
    }

    // Scatter's gains, a channel's index from fastModBlock(0, 0): depth on
    // every channel whose voice and destination bits are set, else 0
    scatterGains { arg depth, destinations, voices;
        var first = this.fastModBlock(0, 0), gains = 0 ! areaState[\modulation][\fastModBus].numChannels;
        numVoices.do({ arg voice;
            if (voices.bitTest(voice)) {
                this.numFastDestinations.do({ arg destination;
                    if (destinations.bitTest(destination)) { gains[this.fastModChannel(voice, 0, destination) - first] = depth };
                });
            };
        });
        ^gains
    }

    // setScatter: depth above 0 makes the node (or sets it, a releasing one
    // re-gated); depth 0 releases it (0.5 s), keeping its gains to fade from
    setScatter { arg depth, rate, destinations, voices;
        var state = areaState[\modulation], place = state[\scatter], gains;
        if (state[\stopped]) { ^this };
        if (depth > 0) {
            gains = this.scatterGains(depth, destinations, voices);
            if (place.isNil) {
                place = (rate: rate, gains: gains, running: true);
                state[\scatter] = place;
                place[\synth] = this.startScatter(place);
            } {
                place[\rate] = rate;
                place[\gains] = gains;
                place[\running] = true;
                this.sendToSynth(place[\synth].setMsg(\gate, 1, \rate, rate), place[\synth].setnMsg(\gains, gains));
            };
        } {
            if (place.notNil) {
                place[\rate] = rate;
                this.sendToSynth(*([place[\synth].setMsg(\rate, rate)] ++ (if (place[\running]) { [place[\synth].setMsg(\gate, 0)] } { [] })));
                place[\running] = false;
            };
        };
    }

    // Scatter's node from its place, its gains set in the same bundle, at the
    // tail of fastModGroup, watched until it ends
    startScatter { arg place;
        var synth;
        context.server.makeBundle(nil, {
            synth = Synth(\strataScatter, [\out, this.fastModBlock(0, 0), \rate, place[\rate]], areaState[\modulation][\fastModGroup], \addToTail);
            synth.setn(\gains, place[\gains]);
        });
        synth.onFree({ this.scatterEnded(synth) });
        ^synth
    }

    // Scatter's node ended: started again if its release ended just as
    // setScatter re-gated it; else scatter has none and every channel goes
    // to 0 (the LFOs and the offset node write theirs again in the next block)
    scatterEnded { arg synth;
        var state = areaState[\modulation], place = state[\scatter];
        if (state[\stopped]) { ^this };
        if (place.notNil and: { place[\synth] === synth } and: { place[\running] }) {
            place[\synth] = this.startScatter(place);
        } {
            if (place.notNil and: { place[\synth] === synth }) { state[\scatter] = nil };
            if (state[\scatter].isNil) { this.zeroFastModChannels(this.fastModBlock(0, 0), state[\fastModBus].numChannels) };
        };
    }

    // setFastOffset: one value of the offset node's offsets (a plain set: it
    // never ends on its own)
    setFastOffset { arg voice, noteSlot, destination, offset;
        var state = areaState[\modulation];
        if (state[\stopped]) { ^this };
        this.setSynth(this.fastOffsetsKey,
            state[\offsetsIndex] + (this.fastModChannel(voice, noteSlot, destination) - this.fastModBlock(0, 0)), offset);
    }

    // An ignored command's line: posted, or given to the function in
    // areaState[\modulation][\postIgnored] (the engine check counts them)
    postFastModIgnored { arg command, why;
        var line = "strata: % ignored: %".format(command, why), post = areaState[\modulation][\postIgnored];
        if (post.notNil) { post.value(line) } { line.postln };
    }

    // Whether every [name, value, highest] is a whole number from 0 to its
    // highest; else one line naming the first that is not, and false
    fastModIndicesValid { arg command, indices;
        var bad = indices.detect({ arg index;
            (index[1].isInteger and: { index[1] >= 0 } and: { index[1] <= index[2] }).not });
        if (bad.isNil) { ^true };
        this.postFastModIgnored(command, "% % is not a whole number from 0 to %".format(bad[0], bad[1], bad[2]));
        ^false
    }

    // Whether every [name, value] is a finite number (a NaN passes clip, an
    // infinity clips to a bound); else one line naming the first that is
    // not, and false
    fastModValuesFinite { arg command, values;
        var bad = values.detect({ arg value; value[1].isNaN or: { value[1].abs == inf } });
        if (bad.isNil) { ^true };
        this.postFastModIgnored(command, "% % is not a finite number".format(bad[0], bad[1]));
        ^false
    }

    // What a command took, for the engine check
    receiveFastMod { arg command, values;
        areaState[\modulation][\received][command] = values;
    }

    // The five commands (design 3.4 §3.4, §10.2). Each checks its indices,
    // then every continuous argument's finiteness (a bad one of either is
    // ignored with one line, and the command does nothing), clips the
    // continuous arguments only then, records what it took and acts. The Lua
    // engine stub reads the clips (name = msg[i].clip(...)) as its limits
    // (and its index limits from the four numbers above); a setFastOffset
    // offset is clipped on its own name, so the stub checks only that it is
    // finite (Lua's matrix sends a sum the engine clamps)
    addFastModCommands {
        var lastLfo = this.numFastLfos - 1, lastVoice = numVoices - 1, lastDestination = this.numFastDestinations - 1;
        var lastShape = this.numFastLfoShapes - 1, lastNoteSlot = this.fastModNoteSlots - 1;
        var destinationMask = (1 << this.numFastDestinations) - 1, voiceMask = (1 << numVoices) - 1;

        // Engine LFO lfo on voice's fast destination (note slot 0 in 3.4):
        // shape, rate (Hz), depth and offset (half ranges)
        this.addCommand(\setFastLfo, "iiiifff", { arg msg;
            var lfo = msg[1], voice = msg[2], destination = msg[3], shape = msg[4], rate, depth, offset;
            if (this.fastModIndicesValid(\setFastLfo, [[\lfo, lfo, lastLfo], [\voice, voice, lastVoice],
                [\destination, destination, lastDestination], [\shape, shape, lastShape]])
                and: { this.fastModValuesFinite(\setFastLfo, [[\rate, msg[5]], [\depth, msg[6]], [\offset, msg[7]]]) }) {
                rate = msg[5].clip(0.003, 50); depth = msg[6].clip(0, 1); offset = msg[7].clip(-2, 2);
                this.receiveFastMod(\setFastLfo, [lfo, voice, destination, shape, rate, depth, offset]);
                this.setFastLfo(lfo, voice, destination, shape, rate, depth, offset);
            };
        });

        // Release an engine LFO's node
        this.addCommand(\stopFastLfo, "i", { arg msg;
            var lfo = msg[1];
            if (this.fastModIndicesValid(\stopFastLfo, [[\lfo, lfo, lastLfo]])) {
                this.receiveFastMod(\stopFastLfo, [lfo]);
                this.stopFastLfo(lfo);
            };
        });

        // Set an engine LFO's phase (0-1) now
        this.addCommand(\syncFastLfo, "if", { arg msg;
            var lfo = msg[1], phase;
            if (this.fastModIndicesValid(\syncFastLfo, [[\lfo, lfo, lastLfo]])
                and: { this.fastModValuesFinite(\syncFastLfo, [[\phase, msg[2]]]) }) {
                phase = msg[2].clip(0, 1);
                this.receiveFastMod(\syncFastLfo, [lfo, phase]);
                this.syncFastLfo(lfo, phase);
            };
        });

        // Scatter: depth 0-1, rate (Hz), a destination mask (bit d =
        // destination d) and a voice mask (bit v = voice v)
        this.addCommand(\setScatter, "ffii", { arg msg;
            var destinations = msg[3], voices = msg[4], depth, rate;
            if (this.fastModIndicesValid(\setScatter, [[\destinations, destinations, destinationMask], [\voices, voices, voiceMask]])
                and: { this.fastModValuesFinite(\setScatter, [[\depth, msg[1]], [\rate, msg[2]]]) }) {
                depth = msg[1].clip(0, 1); rate = msg[2].clip(0.01, 1);
                this.receiveFastMod(\setScatter, [depth, rate, destinations, voices]);
                this.setScatter(depth, rate, destinations, voices);
            };
        });

        // The Lua-computed offset (the matrix's, half ranges) on voice's note
        // slot and fast destination
        this.addCommand(\setFastOffset, "iiif", { arg msg;
            var voice = msg[1], noteSlot = msg[2], destination = msg[3], offset = msg[4];
            if (this.fastModIndicesValid(\setFastOffset, [[\voice, voice, lastVoice], [\noteSlot, noteSlot, lastNoteSlot],
                [\destination, destination, lastDestination]])
                and: { this.fastModValuesFinite(\setFastOffset, [[\offset, offset]]) }) {
                offset = offset.clip(-2, 2);
                this.receiveFastMod(\setFastOffset, [voice, noteSlot, destination, offset]);
                this.setFastOffset(voice, noteSlot, destination, offset);
            };
        });
    }
}
