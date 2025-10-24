// Engine_Strata.sc
// Ambient granular synthesis engine for norns
// Multiple synthesis voices with granular processing

Engine_Strata : CroneEngine {
    var <synths;
    var <granBuses;
    var <mainBus;
    var <reverbBus;
    var <modBuses;  // Control buses for cross-modulation

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        // Audio buses for granular processing (7 voices)
        granBuses = Array.fill(7, { Bus.audio(context.server, 2) });
        mainBus = Bus.audio(context.server, 2);
        reverbBus = Bus.audio(context.server, 2);

        // Control buses for cross-modulation (one per voice)
        modBuses = Array.fill(7, { Bus.control(context.server, 1) });
        
        // SynthDefs

        // Modulation output synth - outputs envelope follower signal for cross-mod
        SynthDef(\strataMod, {
            arg in, out, gate=1, speed=10;
            var sig, env, modSig;

            env = EnvGen.kr(Env.asr(0.1, 1, 0.5), gate, doneAction: 2);
            sig = In.ar(in, 2).sum;  // Sum stereo to mono

            // Envelope follower with smoothing
            modSig = Amplitude.kr(sig, 0.01, 0.1);
            // Add slow LFO component for more movement
            modSig = (modSig * 0.7) + (LFNoise1.kr(speed).range(0, 0.3));
            modSig = modSig.lag(0.05);  // Smooth the output

            Out.kr(out, modSig * env);
        }).add;

        SynthDef(\strataResonator, {
            arg out, gate=1, freq=100, rq=0.1, noise=0.5,
            mod1=0.1, mod2=0.15, amp=0.3, pan=0,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, env, noiseSource, modSig, modFreq, modAmp;

            env = EnvGen.kr(Env.asr(4, 1, 8), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreq = freq * (1 + (modSig * modFreqAmt));
            modAmp = amp * (1 + (modSig * modAmpAmt));

            noiseSource = PinkNoise.ar(noise) + LFNoise1.ar(100, 0.3);

            sig = DynKlank.ar(
                `[
                    [modFreq, modFreq * 1.5, modFreq * 2.3, modFreq * 3.7],
                    [1, 0.7, 0.5, 0.3],
                    [2, 1.5, 1, 0.8]
                ],
                noiseSource
            );

            sig = sig * LFNoise1.kr([mod1, mod2]).range(0.5, 1);
            sig = RLPF.ar(sig, modFreq * LFNoise1.kr(0.1).range(1, 4), rq);
            sig = Pan2.ar(sig, pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
        
        SynthDef(\strataFM, {
            arg out, gate=1, freq=80, ratio=1.5, index=2,
            modFreq=0.05, amp=0.25, pan=0,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, mod, env, carrier, modSig, modFreqVal, modAmp;

            env = EnvGen.kr(Env.asr(5, 1, 10), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreqVal = freq * (1 + (modSig * modFreqAmt));
            modAmp = amp * (1 + (modSig * modAmpAmt));

            modFreq = LFNoise1.kr(0.1).range(modFreq * 0.5, modFreq * 2);
            ratio = ratio + LFNoise1.kr(0.08).range(-0.1, 0.1);
            index = index * LFNoise1.kr(0.12).range(0.5, 1.5);

            mod = SinOsc.ar(modFreqVal * ratio) * modFreqVal * index;
            carrier = SinOsc.ar(modFreqVal + mod);

            sig = carrier * LFNoise1.kr([modFreq, modFreq * 1.1]).range(0.3, 1);
            sig = Pan2.ar(sig, pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
        
        SynthDef(\strataFolder, {
            arg out, gate=1, freq=60, fold=1, mod=0.2, amp=0.3, pan=0,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, env, foldAmt, modSig, modFreq, modAmp;

            env = EnvGen.kr(Env.asr(3, 1, 6), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreq = freq * (1 + (modSig * modFreqAmt));
            modAmp = amp * (1 + (modSig * modAmpAmt));

            foldAmt = fold * LFNoise1.kr(mod).range(0.5, 1.5);
            sig = SinOsc.ar(modFreq * [1, 1.002]);
            sig = (sig * foldAmt).fold2(1);
            sig = LPF.ar(sig, 2000 + (LFNoise1.kr(0.1) * 1000));
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
        
        SynthDef(\strataSub, {
            arg out, gate=1, freq=40, drift=0.02, amp=0.4,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, env, modFreq, modSig, modAmp;

            env = EnvGen.kr(Env.asr(8, 1, 12), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreq = freq * (1 + (modSig * modFreqAmt));
            modFreq = modFreq + LFNoise1.kr(drift).range(-2, 2);
            modAmp = amp * (1 + (modSig * modAmpAmt));

            sig = SinOsc.ar(modFreq ! 2);
            sig = sig + (SinOsc.ar(modFreq * 0.5) * 0.3);

            Out.ar(out, sig * env * modAmp);
        }).add;

        SynthDef(\strataPulse, {
            arg out, gate=1, freq=120, width=0.5, cutoff=2000,
            res=0.3, amp=0.3, pan=0,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, env, modSig, modFreq, modAmp, modWidth;

            env = EnvGen.kr(Env.asr(2, 1, 4), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreq = freq * (1 + (modSig * modFreqAmt));
            modAmp = amp * (1 + (modSig * modAmpAmt));

            // Modulate pulse width with LFO and cross-mod
            modWidth = width + (LFNoise1.kr(0.15).range(-0.2, 0.2)) + (modSig * 0.3);
            modWidth = modWidth.clip(0.05, 0.95);

            sig = Pulse.ar(modFreq * [1, 1.003], modWidth);

            // Dynamic filter with slow modulation
            cutoff = cutoff * LFNoise1.kr(0.2).range(0.5, 2);
            sig = RLPF.ar(sig, cutoff.clip(100, 8000), res);

            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp * 0.7);
        }).add;

        SynthDef(\strataKarplus, {
            arg out, gate=1, freq=200, decay=4, damping=0.5,
            excite=0.3, amp=0.35, pan=0,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, env, modSig, modFreq, modAmp, noise, pluck;

            env = EnvGen.kr(Env.asr(0.01, 1, 2), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreq = freq * (1 + (modSig * modFreqAmt));
            modAmp = amp * (1 + (modSig * modAmpAmt));

            // Excitation signal - burst of noise
            noise = PinkNoise.ar(1);
            pluck = Decay.ar(Impulse.ar(excite), 0.01, noise);

            // Karplus-Strong with variable decay
            sig = Pluck.ar(
                in: pluck,
                trig: Impulse.ar(excite),
                maxdelaytime: 0.1,
                delaytime: modFreq.reciprocal,
                decaytime: decay,
                coef: damping.linlin(0, 1, 0.1, 0.9)
            );

            // Slight detuning for stereo width
            sig = [sig, Pluck.ar(
                in: pluck,
                trig: Impulse.ar(excite),
                maxdelaytime: 0.1,
                delaytime: (modFreq * 1.002).reciprocal,
                decaytime: decay,
                coef: damping.linlin(0, 1, 0.1, 0.9)
            )];

            sig = Balance2.ar(sig[0], sig[1], pan);
            sig = LPF.ar(sig, 4000);  // Gentle high-frequency roll-off

            Out.ar(out, sig * env * modAmp);
        }).add;

        SynthDef(\strataRing, {
            arg out, gate=1, freq=300, ratio=1.618, mod=0.2,
            brightness=0.5, amp=0.25, pan=0,
            modBus=0, modAmpAmt=0, modFreqAmt=0;
            var sig, env, modSig, modFreq, modAmp, car, modulator, ring;

            env = EnvGen.kr(Env.asr(3, 1, 5), gate, doneAction: 2);

            // Read modulation signal
            modSig = In.kr(modBus, 1);
            modFreq = freq * (1 + (modSig * modFreqAmt));
            modAmp = amp * (1 + (modSig * modAmpAmt));

            // Slowly evolving ratio for inharmonic movement
            ratio = ratio + (LFNoise1.kr(mod).range(-0.1, 0.1));

            // Two oscillators for ring modulation
            car = SinOsc.ar(modFreq * [1, 1.005]);
            modulator = SinOsc.ar(modFreq * ratio);

            // Ring modulation
            ring = car * modulator;

            // Add some of the original carrier for warmth
            sig = ring + (car * brightness * 0.3);

            // Gentle filtering
            sig = LPF.ar(sig, 3000 + (LFNoise1.kr(0.1) * 1000));
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp);
        }).add;

        // Granular processor
        SynthDef(\strataGrain, {
            arg in, out, gate=1,
            grainSize=0.1, grainDensity=20, pitchShift=1, 
            posSpread=0.5, panSpread=0.5, amp=1;
            var sig, env, input;
            
            env = EnvGen.kr(Env.asr(0.1, 1, 2), gate, doneAction: 2);
            input = In.ar(in, 2);
            
            sig = GrainIn.ar(
                numChannels: 2,
                trigger: Impulse.ar(grainDensity),
                dur: grainSize,
                in: input,
                pan: LFNoise1.kr(2).range(panSpread.neg, panSpread),
                envbufnum: -1
            ) * pitchShift.lag(0.5);
            
            sig = sig + (DelayC.ar(
                input,
                0.2,
                LFNoise1.kr(1).range(0, posSpread * 0.2)
            ) * 0.3);
            
            Out.ar(out, sig * env * amp);
        }).add;
        
        // Simple reverb
        SynthDef(\strataReverb, {
            arg in, out, mix=0.3, size=0.8, damp=0.5;
            var sig, wet;
            
            sig = In.ar(in, 2);
            wet = FreeVerb2.ar(sig[0], sig[1], mix, size, damp);
            
            Out.ar(out, sig + wet);
        }).add;
        
        // Master output with soft saturation
        SynthDef(\strataMaster, {
            arg in, out, amp=0.7, drift=0.01;
            var sig, driftMod;
            
            sig = In.ar(in, 2);
            
            // Tape-style pitch drift
            driftMod = LFNoise1.kr(drift).range(0.998, 1.002);
            sig = PitchShift.ar(sig, 0.2, driftMod, 0, 0.01);
            
            // Soft saturation
            sig = (sig * 2).tanh * 0.5;
            
            Out.ar(out, sig * amp);
        }).add;
        
        context.server.sync;
        
        // Initialize synth groups
        synths = Dictionary.new;
        
        // Commands for voice control
        this.addCommand(\voiceOn, "isfffff", { arg msg;
            var voice = msg[1];
            var bus = granBuses[voice];
            var modBus = modBuses[voice];
            var synthType = [\strataResonator, \strataFM, \strataFolder, \strataSub, \strataPulse, \strataKarplus, \strataRing][voice];

            synths[("voice" ++ voice).asSymbol] = Synth(synthType, [
                \out, bus,
                \freq, msg[2],
                \amp, msg[3],
                \pan, msg[4],
                \modBus, modBus  // Default: use own mod bus (will be set to 0 by default)
            ] ++ this.getVoiceParams(voice, msg), target: context.xg);

            synths[("grain" ++ voice).asSymbol] = Synth(\strataGrain, [
                \in, bus,
                \out, mainBus,
                \grainSize, msg[5],
                \grainDensity, msg[6],
                \pitchShift, msg[7]
            ], target: context.xg, addAction: \addAfter);

            // Create modulation output synth
            synths[("mod" ++ voice).asSymbol] = Synth(\strataMod, [
                \in, bus,
                \out, modBus
            ], target: context.xg, addAction: \addAfter);
        });

        this.addCommand(\voiceOff, "i", { arg msg;
            var voice = msg[1];
            synths[("voice" ++ voice).asSymbol].set(\gate, 0);
            synths[("grain" ++ voice).asSymbol].set(\gate, 0);
            synths[("mod" ++ voice).asSymbol].set(\gate, 0);
        });
        
        this.addCommand(\setVoiceParam, "isf", { arg msg;
            var voice = msg[1];
            var param = msg[2];
            var value = msg[3];
            synths[("voice" ++ voice).asSymbol].set(param, value);
        });
        
        this.addCommand(\setGrainParam, "isf", { arg msg;
            var voice = msg[1];
            var param = msg[2];
            var value = msg[3];
            synths[("grain" ++ voice).asSymbol].set(param, value);
        });
        
        this.addCommand(\setMasterDrift, "f", { arg msg;
            synths[\master].set(\drift, msg[1]);
        });
        
        this.addCommand(\setReverb, "fff", { arg msg;
            synths[\reverb].set(\mix, msg[1], \size, msg[2], \damp, msg[3]);
        });

        // Cross-modulation commands
        this.addCommand(\setModSource, "ii", { arg msg;
            var voice = msg[1];
            var sourceVoice = msg[2];
            var sourceBus;

            // If sourceVoice is -1, disable modulation (use a silent bus)
            if (sourceVoice >= 0) {
                sourceBus = modBuses[sourceVoice];
            } {
                sourceBus = 0;  // Will output silence/zero
            };

            synths[("voice" ++ voice).asSymbol].set(\modBus, sourceBus);
        });

        this.addCommand(\setModAmpAmt, "if", { arg msg;
            var voice = msg[1];
            var amount = msg[2];
            synths[("voice" ++ voice).asSymbol].set(\modAmpAmt, amount);
        });

        this.addCommand(\setModFreqAmt, "if", { arg msg;
            var voice = msg[1];
            var amount = msg[2];
            synths[("voice" ++ voice).asSymbol].set(\modFreqAmt, amount);
        });

        this.addCommand(\setModSpeed, "if", { arg msg;
            var voice = msg[1];
            var speed = msg[2];
            synths[("mod" ++ voice).asSymbol].set(\speed, speed);
        });

        // Start reverb and master
        synths[\reverb] = Synth(\strataReverb, [
            \in, mainBus,
            \out, reverbBus
        ], target: context.og);
        
        synths[\master] = Synth(\strataMaster, [
            \in, reverbBus,
            \out, context.out_b
        ], target: context.og, addAction: \addAfter);
    }
    
    getVoiceParams { arg voice, msg;
        // Helper to get voice-specific parameters
        ^case
            { voice == 0 } { [\rq, 0.1, \noise, 0.5, \mod1, 0.1, \mod2, 0.15] }
            { voice == 1 } { [\ratio, 1.5, \index, 2, \modFreq, 0.05] }
            { voice == 2 } { [\fold, 1, \mod, 0.2] }
            { voice == 3 } { [\drift, 0.02] }
            { voice == 4 } { [\width, 0.5, \cutoff, 2000, \res, 0.3] }
            { voice == 5 } { [\decay, 4, \damping, 0.5, \excite, 0.3] }
            { voice == 6 } { [\ratio, 1.618, \mod, 0.2, \brightness, 0.5] };
    }
    
    free {
        synths.do({ arg synth; synth.free });
        granBuses.do({ arg bus; bus.free });
        modBuses.do({ arg bus; bus.free });
        mainBus.free;
        reverbBus.free;
    }
}
