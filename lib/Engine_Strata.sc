// Engine_Strata.sc
// Ambient granular synthesis engine for norns
// Multiple synthesis voices with granular processing

Engine_Strata : CroneEngine {
    var <synths;
    var <granBuses;
    var <mainBus;
    var <reverbBus;
    
    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }
    
    alloc {
        // Audio buses for granular processing
        granBuses = Array.fill(4, { Bus.audio(context.server, 2) });
        mainBus = Bus.audio(context.server, 2);
        reverbBus = Bus.audio(context.server, 2);
        
        // SynthDefs
        SynthDef(\strataResonator, {
            arg out, gate=1, freq=100, rq=0.1, noise=0.5, 
            mod1=0.1, mod2=0.15, amp=0.3, pan=0;
            var sig, env, noiseSource;
            
            env = EnvGen.kr(Env.asr(4, 1, 8), gate, doneAction: 2);
            noiseSource = PinkNoise.ar(noise) + LFNoise1.ar(100, 0.3);
            
            sig = DynKlank.ar(
                `[
                    [freq, freq * 1.5, freq * 2.3, freq * 3.7],
                    [1, 0.7, 0.5, 0.3],
                    [2, 1.5, 1, 0.8]
                ],
                noiseSource
            );
            
            sig = sig * LFNoise1.kr([mod1, mod2]).range(0.5, 1);
            sig = RLPF.ar(sig, freq * LFNoise1.kr(0.1).range(1, 4), rq);
            sig = Pan2.ar(sig, pan);
            
            Out.ar(out, sig * env * amp);
        }).add;
        
        SynthDef(\strataFM, {
            arg out, gate=1, freq=80, ratio=1.5, index=2, 
            modFreq=0.05, amp=0.25, pan=0;
            var sig, mod, env, carrier;
            
            env = EnvGen.kr(Env.asr(5, 1, 10), gate, doneAction: 2);
            
            modFreq = LFNoise1.kr(0.1).range(modFreq * 0.5, modFreq * 2);
            ratio = ratio + LFNoise1.kr(0.08).range(-0.1, 0.1);
            index = index * LFNoise1.kr(0.12).range(0.5, 1.5);
            
            mod = SinOsc.ar(freq * ratio) * freq * index;
            carrier = SinOsc.ar(freq + mod);
            
            sig = carrier * LFNoise1.kr([modFreq, modFreq * 1.1]).range(0.3, 1);
            sig = Pan2.ar(sig, pan);
            
            Out.ar(out, sig * env * amp);
        }).add;
        
        SynthDef(\strataFolder, {
            arg out, gate=1, freq=60, fold=1, mod=0.2, amp=0.3, pan=0;
            var sig, env, foldAmt;
            
            env = EnvGen.kr(Env.asr(3, 1, 6), gate, doneAction: 2);
            
            foldAmt = fold * LFNoise1.kr(mod).range(0.5, 1.5);
            sig = SinOsc.ar(freq * [1, 1.002]);
            sig = (sig * foldAmt).fold2(1);
            sig = LPF.ar(sig, 2000 + (LFNoise1.kr(0.1) * 1000));
            sig = Balance2.ar(sig[0], sig[1], pan);
            
            Out.ar(out, sig * env * amp);
        }).add;
        
        SynthDef(\strataSub, {
            arg out, gate=1, freq=40, drift=0.02, amp=0.4;
            var sig, env, modFreq;
            
            env = EnvGen.kr(Env.asr(8, 1, 12), gate, doneAction: 2);
            
            modFreq = freq + LFNoise1.kr(drift).range(-2, 2);
            sig = SinOsc.ar(modFreq ! 2);
            sig = sig + (SinOsc.ar(modFreq * 0.5) * 0.3);
            
            Out.ar(out, sig * env * amp);
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
            var synthType = [\strataResonator, \strataFM, \strataFolder, \strataSub][voice];
            
            synths[("voice" ++ voice).asSymbol] = Synth(synthType, [
                \out, bus,
                \freq, msg[2],
                \amp, msg[3],
                \pan, msg[4]
            ] ++ this.getVoiceParams(voice, msg), target: context.xg);
            
            synths[("grain" ++ voice).asSymbol] = Synth(\strataGrain, [
                \in, bus,
                \out, mainBus,
                \grainSize, msg[5],
                \grainDensity, msg[6],
                \pitchShift, msg[7]
            ], target: context.xg, addAction: \addAfter);
        });
        
        this.addCommand(\voiceOff, "i", { arg msg;
            var voice = msg[1];
            synths[("voice" ++ voice).asSymbol].set(\gate, 0);
            synths[("grain" ++ voice).asSymbol].set(\gate, 0);
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
            { voice == 3 } { [\drift, 0.02] };
    }
    
    free {
        synths.do({ arg synth; synth.free });
        granBuses.do({ arg bus; bus.free });
        mainBus.free;
        reverbBus.free;
    }
}
