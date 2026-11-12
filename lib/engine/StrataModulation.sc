// StrataModulation.sc
// The modulation area: 3.4's fast modulation. Five destinations per voice
// (pitch, position, size, cutoff, amp) take an offset from a control bus,
// fastModBus, indexed by (voice, note slot, destination) through
// fastModChannel only; the engine LFOs, scatter and the matrix's offset
// node write it from fastModGroup, before voiceGroup. Lua owns every base
// value: the buses hold offsets only. As 3.4's Wave 0 leaves it, the area
// holds the buses, the group, the five commands (checked, recorded, no
// node) and the neutral hooks the grain SynthDefs and the mix stage call
// (fastModRead, fastMod, fastModPosition, voiceMixMod), so every bus at 0
// plays exactly as 3.3. See docs/notes/engine/modulation.md.

+ Engine_Strata {
    // Fast destinations per voice: 0 pitch, 1 position, 2 size, 3 cutoff,
    // 4 amp. Lua's S.constants.NUM_FAST_DESTINATIONS is the same number (a
    // docs test compares them)
    numFastDestinations { ^5 }

    // Note slots per voice on fastModBus (3.5 raises it to its tier's note
    // limit). Lua's S.constants.FAST_MOD_NOTE_SLOTS is the same number
    fastModNoteSlots { ^1 }

    // Engine LFOs (setFastLfo's lfo 0-5, Lua's LFOs 1-6) and their shapes
    // (sine, tri, square, up, down, s&h, smooth, drunk)
    numFastLfos { ^6 }
    numFastLfoShapes { ^8 }

    // The modulation area (order 160)
    strataAreaModulation {
        ^(
            order: 160,
            allocState: { this.allocFastModulation },
            addCommands: { this.addFastModCommands },
            start: { areaState[\modulation][\fastModGroup] = Group.before(voiceGroup) },
            stop: { areaState[\modulation][\fastModGroup] !? { arg group; group.free } },
            free: { this.freeFastModBuses },
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
    // follower), lfos (one place per engine LFO for its node), scatter (its
    // node), received (what each command last took, for the engine check)
    // and fastModGroup (made in start). Every voice's grain synths and stage
    // read its note slot 0 block: fastModIn in grainControls (every grain
    // synth, replacements and restarts included, starts with it) and in the
    // mix area's stageControls (made by then: order 120)
    allocFastModulation {
        var state = areaState[\modulation], server = context.server;
        state[\fastModBus] = Bus.control(server, numVoices * this.fastModNoteSlots * this.numFastDestinations);
        state[\fastModBus].setAll(0);
        state[\silentFastModBus] = Bus.control(server, this.numFastDestinations);
        state[\silentFastModBus].setAll(0);
        state[\lfos] = Array.newClear(this.numFastLfos);
        state[\scatter] = nil;
        state[\received] = IdentityDictionary.new;
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

    // The channel of voice v's note slot n, destination d: index + (v x
    // slots + n) x numFastDestinations + d. Every writer and reader of
    // fastModBus goes through fastModChannel, so 3.5's note slots change
    // fastModNoteSlots and nothing else; fastModChannelFor takes the slot
    // count (the engine check runs it with six)
    fastModChannelFor { arg voice, noteSlot, destination, slots;
        ^areaState[\modulation][\fastModBus].index + ((((voice * slots) + noteSlot) * this.numFastDestinations) + destination)
    }
    fastModChannel { arg voice, noteSlot, destination;
        ^this.fastModChannelFor(voice, noteSlot, destination, this.fastModNoteSlots)
    }

    // A block's first channel (destination 0): what a grain synth or stage
    // reads its numFastDestinations channels from
    fastModBlock { arg voice, noteSlot;
        ^this.fastModChannel(voice, noteSlot, 0)
    }

    // The hooks, neutral in Wave 0 (no UGen; package 1a fills them).
    // fastModRead: the block's offsets, one per destination (both grain
    // SynthDefs, before their controls Event and reader).
    fastModRead { arg fastModIn; ^0 ! this.numFastDestinations }

    // fastMod: the grain controls Event with pitch and size offset (called
    // first in grainSignal; the offsets are the Event's fastMod).
    fastMod { arg controls; ^controls }

    // fastModPosition: a buffer grain's bufPos with its position offset
    // (strataGrainBuf, before slotGrainReader).
    fastModPosition { arg bufPos, m; ^bufPos }

    // voiceMixMod: the stage's controls Event (\strataVoiceMix, before both
    // filter banks and voiceLevel). Declares the stage's fastModIn (its
    // voice's block, from stageControls; default the silent bus) and the gate
    // and mute controls (design 3.4 §8.12, §8.14), and sets the two values the
    // stage's level lines read: ampOffset 0 (the amp channel's offset, through
    // voiceLevel on both paths) and voiceGate 1 (the factor on the stage's
    // whole output, after the mirror's tap of the other path). At those
    // values the stage's graph is 3.3's.
    voiceMixMod { arg controls;
        controls[\fastModIn] = \fastModIn.kr(areaState[\modulation][\silentFastModBus].index);
        controls[\seqGate] = \seqGate.kr(0);
        controls[\gateSeconds] = \gateSeconds.kr(0.1);
        controls[\gateRelease] = \gateRelease.kr(0.1);
        controls[\voiceMute] = \voiceMute.kr(0);
        controls[\ampOffset] = 0;
        controls[\voiceGate] = 1;
        ^controls
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

    // What a command took, for the engine check
    receiveFastMod { arg command, values;
        areaState[\modulation][\received][command] = values;
    }

    // The five commands (design 3.4 §3.4, §10.2). Wave 0 checks their
    // indices (an out-of-range one, or a non-finite offset, is ignored with
    // one line), clips their continuous arguments, records what they took
    // and creates no node. The Lua engine stub reads these clips as its
    // limits (and its index limits from the four numbers above); a
    // setFastOffset offset is clipped after its finite check, so the stub
    // checks only that it is finite (Lua's matrix sends a sum the engine
    // clamps)
    addFastModCommands {
        var lastLfo = this.numFastLfos - 1, lastVoice = numVoices - 1, lastDestination = this.numFastDestinations - 1;
        var lastShape = this.numFastLfoShapes - 1, lastNoteSlot = this.fastModNoteSlots - 1;
        var destinationMask = (1 << this.numFastDestinations) - 1, voiceMask = (1 << numVoices) - 1;

        // Engine LFO lfo on voice's fast destination (note slot 0 in 3.4):
        // shape, rate (Hz), depth and offset (half ranges)
        this.addCommand(\setFastLfo, "iiiifff", { arg msg;
            var lfo = msg[1], voice = msg[2], destination = msg[3], shape = msg[4];
            var rate = msg[5].clip(0.003, 50), depth = msg[6].clip(0, 1), offset = msg[7].clip(-2, 2);
            if (this.fastModIndicesValid(\setFastLfo, [[\lfo, lfo, lastLfo], [\voice, voice, lastVoice],
                [\destination, destination, lastDestination], [\shape, shape, lastShape]])) {
                this.receiveFastMod(\setFastLfo, [lfo, voice, destination, shape, rate, depth, offset]);
            };
        });

        // Release an engine LFO's node
        this.addCommand(\stopFastLfo, "i", { arg msg;
            var lfo = msg[1];
            if (this.fastModIndicesValid(\stopFastLfo, [[\lfo, lfo, lastLfo]])) { this.receiveFastMod(\stopFastLfo, [lfo]) };
        });

        // Set an engine LFO's phase (0-1) now
        this.addCommand(\syncFastLfo, "if", { arg msg;
            var lfo = msg[1], phase = msg[2].clip(0, 1);
            if (this.fastModIndicesValid(\syncFastLfo, [[\lfo, lfo, lastLfo]])) { this.receiveFastMod(\syncFastLfo, [lfo, phase]) };
        });

        // Scatter: depth 0-1, rate (Hz), a destination mask (bit d =
        // destination d) and a voice mask (bit v = voice v)
        this.addCommand(\setScatter, "ffii", { arg msg;
            var depth = msg[1].clip(0, 1), rate = msg[2].clip(0.01, 1), destinations = msg[3], voices = msg[4];
            if (this.fastModIndicesValid(\setScatter, [[\destinations, destinations, destinationMask], [\voices, voices, voiceMask]])) {
                this.receiveFastMod(\setScatter, [depth, rate, destinations, voices]);
            };
        });

        // The Lua-computed offset (the matrix's, half ranges) on voice's note
        // slot and fast destination
        this.addCommand(\setFastOffset, "iiif", { arg msg;
            var voice = msg[1], noteSlot = msg[2], destination = msg[3], offset = msg[4];
            if (this.fastModIndicesValid(\setFastOffset, [[\voice, voice, lastVoice], [\noteSlot, noteSlot, lastNoteSlot],
                [\destination, destination, lastDestination]])) {
                if (offset.isNaN or: { offset.abs == inf }) {
                    this.postFastModIgnored(\setFastOffset, "offset % is not a finite number".format(offset));
                } {
                    this.receiveFastMod(\setFastOffset, [voice, noteSlot, destination, offset.clip(-2, 2)]);
                };
            };
        });
    }
}
