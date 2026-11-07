// StrataEffects.sc
// The effects area: the filter, delay, reverb and master SynthDefs, their
// commands and the chain at the tail of the engine group. See
// docs/notes/engine/effects.md.

+ Engine_Strata {
    // The effects area (order 60)
    strataAreaEffects {
        ^(
            order: 60,
            allocState: { this.allocEffectBuses },
            addDefs: { this.addEffectDefs; [] },
            addCommands: { this.addEffectCommands },
            start: { this.startEffectsChain },
            free: { this.freeEffects },
            effectKeys: this.effectChainKeys
        )
    }

    // The chain's synths, in signal order
    effectChainKeys { ^[\filter, \delay, \reverb, \master] }

    allocEffectBuses {
        // Effects chain: mainBus -> filter -> filterBus -> delay -> delayBus
        // -> reverb -> reverbBus -> master
        mainBus = Bus.audio(context.server, 2);
        filterBus = Bus.audio(context.server, 2);
        delayBus = Bus.audio(context.server, 2);
        reverbBus = Bus.audio(context.server, 2);
    }

    addEffectDefs {
        // Multimode filter: 0 lowpass, 1 highpass, 2 bandpass. res 0..1 maps
        // to rq 1..0.05; mix crossfades dry (0, the default bypass) to filtered.
        // First in the effects chain, it also replaces any NaN or inf (and
        // denormal) sample with 0 (CheckBadValues), so a voice that blows up
        // can never poison the delay feedback or the reverb for good.
        // A type change crossfades over 20 ms: the three filters always run
        // and each is weighted by a lagged "this is the type" (the weights
        // sum to 1 once settled), so switching never steps the output.
        SynthDef(\strataFilter, {
            arg in, out, freq=5000, res=0.5, filterType=0, mix=0;
            var dry, filtered, cutoff, rq, wet, type;

            dry = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel) });
            cutoff = freq.lag(0.05).clip(20, 20000);
            rq = 1 - (res.clip(0, 1) * 0.95);
            type = filterType.round.clip(0, 2);
            filtered = [
                RLPF.ar(dry, cutoff, rq),
                RHPF.ar(dry, cutoff, rq),
                BPF.ar(dry, cutoff, rq)
            ].collect({ arg each, index; each * BinaryOpUGen('==', type, index).lag(0.02) }).sum;
            wet = mix.lag(0.05).clip(0, 1);

            Out.ar(out, dry + ((filtered - dry) * wet));
        }).add;

        // Stereo delay with feedback (LocalIn/LocalOut around DelayC, max 2 s).
        // The time lag avoids zipper noise when the time changes; mix
        // crossfades dry (0, the default) to delayed.
        SynthDef(\strataDelay, {
            arg in, out, time=0.375, feedback=0.4, mix=0;
            var dry, delayed, wet;

            dry = In.ar(in, 2);
            delayed = DelayC.ar(dry + LocalIn.ar(2), 2, time.lag(0.1).clip(0.01, 2));
            LocalOut.ar(delayed * feedback.clip(0, 0.95));
            wet = mix.lag(0.05).clip(0, 1);

            Out.ar(out, dry + ((delayed - dry) * wet));
        }).add;

        // Simple reverb
        SynthDef(\strataReverb, {
            arg in, out, mix=0.3, size=0.8, damp=0.5;
            var sig, wet;
            
            sig = In.ar(in, 2);
            // FreeVerb2 already crossfades dry and wet by mix
            wet = FreeVerb2.ar(sig[0], sig[1], mix, size, damp);

            Out.ar(out, wet);
        }).add;
        
        // Master output with soft saturation
        SynthDef(\strataMaster, {
            arg in, out, amp=0.7, drift=0.01;
            var sig, driftMod;
            
            sig = In.ar(in, 2);
            
            // Tape-style pitch drift at a fixed slow rate; drift sets the depth
            // (0 = no drift, default 0.01 = +/-0.2%, max 0.1 = +/-2%)
            driftMod = 1 + (LFNoise1.kr(0.2) * drift * 0.2);
            sig = PitchShift.ar(sig, 0.2, driftMod, 0, 0.01);
            
            // Limiter as a safety net for filter resonance and delay feedback
            // peaks, before the saturator (tanh * 0.5 already bounds its own
            // output, so a limiter after it could never act)
            sig = Limiter.ar(sig, 0.95);

            // Soft saturation
            sig = (sig * 2).tanh * 0.5;

            Out.ar(out, sig * amp);
        }).add;
    }

    addEffectCommands {
        this.addCommand(\setMasterDrift, "f", { arg msg;
            this.setSynth(\master, \drift, msg[1]);
        });

        this.addCommand(\setReverb, "fff", { arg msg;
            this.setSynth(\reverb, \mix, msg[1], \size, msg[2], \damp, msg[3]);
        });

        // msg: freq, res, filterType (0 lowpass, 1 highpass, 2 bandpass), mix
        this.addCommand(\setFilter, "ffif", { arg msg;
            this.setSynth(\filter, \freq, msg[1], \res, msg[2], \filterType, msg[3], \mix, msg[4]);
        });

        // msg: time (s), feedback, mix
        this.addCommand(\setDelay, "fff", { arg msg;
            this.setSynth(\delay, \time, msg[1], \feedback, msg[2], \mix, msg[3]);
        });
    }

    startEffectsChain {
        // Start the effects chain and master at the tail of the engine
        // group, in signal order
        synths[\filter] = Synth(\strataFilter, [
            \in, mainBus,
            \out, filterBus
        ], target: context.xg, addAction: \addToTail);

        synths[\delay] = Synth(\strataDelay, [
            \in, filterBus,
            \out, delayBus
        ], target: context.xg, addAction: \addToTail);

        synths[\reverb] = Synth(\strataReverb, [
            \in, delayBus,
            \out, reverbBus
        ], target: context.xg, addAction: \addToTail);

        synths[\master] = Synth(\strataMaster, [
            \in, reverbBus,
            \out, context.out_b
        ], target: context.xg, addAction: \addToTail);
    }

    // The chain's synths (quietly, as free frees every synth), then its buses
    freeEffects {
        this.effectChainKeys.do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) { this.sendToSynth(synth.freeMsg); synth.free(false) };
        });
        mainBus.free;
        filterBus.free;
        delayBus.free;
        reverbBus.free;
    }
}
