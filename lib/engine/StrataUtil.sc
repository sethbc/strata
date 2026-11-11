// StrataUtil.sc
// Engine_Strata's shared helpers: the synth keys, the validators,
// grainDefFor and controlPairs, warnInvariant, sendToSynth, cutSynth and
// setSynth, the SynthDef building blocks (openedGate, killFade,
// panBalance, zeroBadValues, subsonicBlock), the area registry
// (strataAreas) and the contained area phases (runAreaPhases). See
// docs/notes/engine/structure.md.

+ Engine_Strata {
    voiceKey { arg voice; ^("voice" ++ voice).asSymbol }
    grainKey { arg voice; ^("grain" ++ voice).asSymbol }
    modKey { arg voice; ^("mod" ++ voice).asSymbol }

    validVoice { arg voice;
        ^voice.isInteger and: { (voice >= 0) and: { voice < numVoices } }
    }

    validModSlot { arg slot;
        ^slot.isInteger and: { (slot >= 1) and: { slot <= numModSlots } }
    }

    validBuffer { arg index;
        ^index.isInteger and: { (index >= 0) and: { index < numBuffers } }
    }

    inputSource { ^numBuffers + 1 }

    validSource { arg source;
        ^source.isInteger and: { (source >= 0) and: { source <= this.inputSource } }
    }

    voiceRunning { arg voice;
        ^synths[this.voiceKey(voice)].notNil or: { synths[this.grainKey(voice)].notNil }
    }

    // The grain SynthDef for the voice's current source: the first of the
    // areas' grainDefs (grainDefTable) whose predicate takes the source
    grainDefFor { arg voice;
        var source = grainSource[voice];
        ^grainDefTable.detect({ arg entry; entry.key.value(source) }).value
    }

    // Key/value pairs from a Dictionary for the controls a SynthDef has
    controlPairs { arg defName, controls;
        var names = controlNameSets[defName];
        var pairs = List.new;
        controls.keysValuesDo({ arg key, value;
            if (names.includes(key)) { pairs.add(key).add(value) };
        });
        ^pairs.asArray
    }

    // A lifecycle invariant that should always hold did not: one line in
    // maiden (and a failure in test/run_engine_check.sh), never an error
    warnInvariant { arg message;
        var line = "Strata invariant broken: " ++ message;
        if (postInvariantWarning.notNil) { postInvariantWarning.value(line) } { line.warn };
    }

    // Send messages to synths that can end on the server on their own, so
    // one may have freed a moment ago, its /n_end not yet in sclang
    // (isPlaying still true): a releasing synth voiceOn re-gates (gateVoice)
    // or a fading one a switch cuts (cutSynth), whose release just ended; a
    // live synth (setSynth, releaseVoice, replaceGrainSynth), which frees
    // when its release ended just as voiceOn re-gated it (watchVoiceSynth
    // starts it again); a record synth whose take just completed
    // (stopRecording). /error -1 turns off the server's error reports, so a
    // message to such a node fails silently, where it would post "FAILURE IN
    // SERVER ... Node not found" (which test/run_engine_check.sh fails on)
    // and send a /fail reply; /error -2 turns them on again. The server
    // counts the two until the end of the bundle, so the reports are off for
    // these messages only, also when makeBundle flattens this bundle into a
    // larger one (voiceOn's): a voice or grain synth's /s_new after it is
    // still reported when it fails (#498).
    sendToSynth { arg ... msgs;
        context.server.sendBundle(nil, *([['/error', -1]] ++ msgs ++ [['/error', -2]]));
    }

    // End a voice or grain synth within switchCutTime through its kill
    // fade, whatever release it is already in. Not a second forced release:
    // EnvGen starts a forced release only when its gate crosses -1 from
    // above, so one already in a release(grainRelease) ignores a shorter one.
    cutSynth { arg synth;
        if (synth.isPlaying) { this.sendToSynth(synth.setMsg(\kill, 1)) };
    }

    // The gate of a synth's ASR envelope: 1 in its first control block
    // (Impulse.kr(0) is a single impulse at the start), the gate control
    // from then on. EnvGen starts only when its gate rises above 0, so a
    // synth gated off in the block it was created in (voiceOn and voiceOff
    // in one bundle) would never start its envelope and never free; this
    // way it starts in that first block and releases from the next. Later
    // blocks see the gate unchanged, negative values included (a max with
    // 0 would turn a forced release into the full natural one), so
    // releases, forced releases and re-gates are unchanged.
    openedGate { arg gate;
        ^Select.kr(Impulse.kr(0) > 0, [gate, 1])
    }

    // Kill fade multiplied into every voice and grain synth's output: level 1
    // until the kill control rises above 0 (an EnvGen that has not been
    // triggered holds its first level), then a linear switchCutTime fade to
    // 0 that frees the synth, independent of its ASR. Kill is the fade's
    // trigger, not a gate, so it also works when it arrives in the synth's
    // first control block (a gate that starts at 0 never starts).
    killFade { arg kill;
        ^EnvGen.kr(Env([1, 0], [switchCutTime]), kill, doneAction: 2)
    }

    // The voice's pan on a buffer or input grain synth's stereo output, as a
    // balance: the far channel is turned down (pan -1 leaves the left only,
    // 1 the right only) and a centered voice is unchanged. Not a Balance2,
    // which takes 3 dB off both channels at the center.
    panBalance { arg sig, pan;
        ^sig * [1 - pan.clip(0, 1), 1 + pan.clip(-1, 0)]
    }

    // One channel (audio or control rate) with every NaN, inf or denormal
    // sample replaced by 0 (CheckBadValues); every other sample passes
    // unchanged, bit for bit (Select)
    zeroBadValues { arg sig;
        ^if (sig.rate == \audio) {
            Select.ar(CheckBadValues.ar(sig, 0, 0) > 0, [sig, DC.ar(0)])
        } {
            Select.kr(CheckBadValues.kr(sig, 0, 0) > 0, [sig, DC.kr(0)])
        }
    }

    // A voice's signal without what lies under the audible range: a 12 dB
    // per octave highpass at subsonicCutoff. For the two voices whose
    // synthesis makes a component at or near 0 Hz (FM, Ring: #309), before
    // their voice bus, so it reaches neither the grains (which would turn
    // it into a tone at the grain rate), the crossmod follower, the sends
    // nor the master's limiter and saturation.
    subsonicBlock { arg sig;
        ^HPF.ar(sig, this.subsonicCutoff)
    }
    subsonicCutoff { ^15 }

    // Set controls on a synth only if it is running. A voice's synth (voice,
    // grain or mod key) may have freed a moment ago (see watchVoiceSynth), so
    // it goes through sendToSynth; the effects chain's (effectKeys) never
    // ends on its own, so a plain set, whose failure the server reports
    setSynth { arg key ... controls;
        var synth = synths[key];
        if (synth.notNil) {
            if (effectKeys.includes(key)) { synth.set(*controls) } { this.sendToSynth(synth.setMsg(*controls)) };
        };
    }

    // The engine's areas: every method named strataArea<Name>, this class's
    // own and its extensions' (this.class.methods holds both), returns an
    // Event with the area's order and phases (see alloc). Each Event gets
    // its name: <Name> with its first letter lowercased (\rings for
    // strataAreaRings). Two areas with one order are an error. Returned in
    // ascending order.
    strataAreas {
        var found = List.new, orders = IdentityDictionary.new;
        this.class.methods.do({ arg method;
            var selector = method.name.asString, area, name;
            if ((selector.size > 10) and: { selector.beginsWith("strataArea") } and: { selector[10].isUpper }) {
                area = this.perform(method.name);
                name = (selector[10].toLower.asString ++ selector.copyToEnd(11)).asSymbol;
                if (orders[area[\order]].notNil) {
                    Error("Strata: the % and % areas share order %".format(orders[area[\order]], name, area[\order])).throw;
                };
                orders[area[\order]] = name;
                area[\name] = name;
                found.add(area);
            };
        });
        ^found.sort({ arg a, b; a[\order] < b[\order] }).asArray
    }

    // One phase (\stop or \free) of every area in the list, in descending
    // order, each under its own try (#499): an area that raises is named in
    // one invariant line (warnInvariant) and the others still run, so every
    // node is still freed before any bus or buffer and nothing an area made
    // is left behind by another's error. free runs it over every area;
    // alloc's rollback over the areas whose start or allocState began.
    runAreaPhases { arg list, phase;
        list.reverseDo({ arg area;
            try { area[phase].value } { arg error;
                this.warnInvariant("the % area's % raised: %".format(area[\name], phase, error.errorString));
            };
        });
    }
}
