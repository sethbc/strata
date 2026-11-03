// Engine_Strata.sc
// Ambient granular synthesis engine for norns
// Multiple synthesis voices with granular processing

Engine_Strata : CroneEngine {
    var <numVoices = 7;  // Must match NUM_VOICES in strata.lua
    var <voiceSynthDefs;
    var <synths;
    var <granBuses;
    var <mainBus;
    var <reverbBus;
    var <modBuses;  // Control buses for cross-modulation
    var <silentBus; // Always-zero control bus used for "no modulation source"
    var <voiceGroup;   // Voice synths (head of context.xg)
    var <processGroup; // Grain and mod synths (after voiceGroup)

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        // Voice SynthDef for each voice index (0-indexed, as sent by Lua)
        voiceSynthDefs = [\strataResonator, \strataFM, \strataFolder, \strataSub,
            \strataPulse, \strataKarplus, \strataRing];

        // Audio buses for granular processing (one stereo bus per voice)
        granBuses = Array.fill(numVoices, { Bus.audio(context.server, 2) });
        mainBus = Bus.audio(context.server, 2);
        reverbBus = Bus.audio(context.server, 2);

        // Control buses for cross-modulation (one per voice)
        modBuses = Array.fill(numVoices, { Bus.control(context.server, 1) });

        // "No modulation source" must read a bus that is always zero. Control
        // bus 0 is not safe: CroneAudioContext allocates the input amplitude
        // follower (amp_in_b) there before any engine loads.
        silentBus = Bus.control(context.server, 1);
        silentBus.set(0);
        
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
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, env, noiseSource, modSig, modFreq, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(4, 1, 8), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            noiseSource = PinkNoise.ar(noise) + LFNoise1.ar(100, 0.3);

            sig = DynKlank.ar(
                `[
                    [modFreq, modFreq * 1.5, modFreq * 2.3, modFreq * 3.7],
                    [1, 0.7, 0.5, 0.3],
                    [2, 1.5, 1, 0.8]
                ],
                noiseSource
            );

            // Two slow amplitude wobbles averaged to one mono gain, so Pan2
            // below receives a mono signal (a 2-element array here doubled
            // the output into two summed stereo pairs)
            sig = sig * ((LFNoise1.kr(mod1).range(0.5, 1) + LFNoise1.kr(mod2).range(0.5, 1)) * 0.5);
            sig = RLPF.ar(sig, modFreq * LFNoise1.kr(0.1).range(1, 4), rq);
            sig = Pan2.ar(sig, pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
        
        SynthDef(\strataFM, {
            arg out, gate=1, freq=80, ratio=1.5, index=2,
            modFreq=0.05, amp=0.25, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, mod, env, carrier, modSig, modFreqVal, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(5, 1, 10), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreqVal = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

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
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, env, foldAmt, modSig, modFreq, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(3, 1, 6), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            foldAmt = fold * LFNoise1.kr(mod).range(0.5, 1.5);
            sig = SinOsc.ar(modFreq * [1, 1.002]);
            sig = (sig * foldAmt).fold2(1);
            sig = LPF.ar(sig, 2000 + (LFNoise1.kr(0.1) * 1000));
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
        
        SynthDef(\strataSub, {
            arg out, gate=1, freq=40, drift=0.02, amp=0.4,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, env, modFreq, modSig, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(8, 1, 12), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            // Slow pitch drift whose depth is the drift amount (0 = none)
            modFreq = modFreq * (1 + (LFNoise1.kr(0.1) * drift));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            sig = SinOsc.ar(modFreq ! 2);
            sig = sig + (SinOsc.ar(modFreq * 0.5) * 0.3);

            Out.ar(out, sig * env * modAmp);
        }).add;

        SynthDef(\strataPulse, {
            arg out, gate=1, freq=120, width=0.5, cutoff=2000,
            res=0.3, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, env, modSig, modFreq, modAmp, modWidth;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(2, 1, 4), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

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
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, env, modSig, modFreq, modAmp, noise, pluck, exciteTrig;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(0.01, 1, 2), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            // Excitation trigger: the free-running exciter plus retrigger
            // commands, so a pattern step actually re-plucks the string
            exciteTrig = Impulse.ar(excite) + T2A.ar(t_trig);

            // Excitation signal - burst of noise
            noise = PinkNoise.ar(1);
            pluck = Decay.ar(exciteTrig, 0.01, noise);

            // Karplus-Strong with variable decay
            sig = Pluck.ar(
                in: pluck,
                trig: exciteTrig,
                maxdelaytime: 0.1,
                delaytime: modFreq.reciprocal,
                decaytime: decay,
                coef: damping.linlin(0, 1, 0.1, 0.9)
            );

            // Slight detuning for stereo width
            sig = [sig, Pluck.ar(
                in: pluck,
                trig: exciteTrig,
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
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0;
            var sig, env, modSig, modFreq, modAmp, car, modulator, ring;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(3, 1, 5), gate, doneAction: 2);
            // Accent envelope fired by the retrigger command (pattern steps)
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

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
            );

            // Position spread: a little of the input, smeared by a wandering delay
            sig = sig + (DelayC.ar(
                input,
                0.2,
                LFNoise1.kr(1).range(0, posSpread * 0.2)
            ) * 0.3);

            // Transpose the whole grain-synth output (GrainIn has no rate
            // input). Shifting after the spread path is summed keeps every
            // part transposed and time-aligned. PitchShift's window size is
            // fixed when the synth starts.
            sig = PitchShift.ar(
                sig,
                windowSize: grainSize.clip(0.01, 0.5),
                pitchRatio: pitchShift.lag(0.5),
                pitchDispersion: 0,
                timeDispersion: 0
            );
            
            Out.ar(out, sig * env * amp);
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
            
            // Soft saturation
            sig = (sig * 2).tanh * 0.5;
            
            Out.ar(out, sig * amp);
        }).add;
        
        context.server.sync;

        synths = Dictionary.new;

        // Node order inside the engine group (context.xg):
        // voiceGroup -> processGroup (grain + mod) -> reverb -> master.
        // Keeping everything inside xg leaves norns' output group (og) and
        // its output metering after the engine.
        voiceGroup = Group.head(context.xg);
        processGroup = Group.after(voiceGroup);

        // Commands for voice control
        this.addCommand(\voiceOn, "iffffff", { arg msg;
            var voice = msg[1].asInteger;
            var bus, modBus;

            if (this.validVoice(voice)) {
                // Starting a running voice replaces it: release the old trio
                this.releaseVoice(voice);

                bus = granBuses[voice];
                modBus = modBuses[voice];

                synths[this.voiceKey(voice)] = Synth(voiceSynthDefs[voice], [
                    \out, bus,
                    \freq, msg[2],
                    \amp, msg[3],
                    \pan, msg[4],
                    // Initialize all 3 mod bus slots to the silent bus (no modulation)
                    \modBus1, silentBus.index,
                    \modBus2, silentBus.index,
                    \modBus3, silentBus.index,
                    \modAmpAmt1, 0,
                    \modAmpAmt2, 0,
                    \modAmpAmt3, 0,
                    \modFreqAmt1, 0,
                    \modFreqAmt2, 0,
                    \modFreqAmt3, 0
                ], target: voiceGroup);
                // Voice-specific params, posSpread, crossmod routing and mod speed
                // are pushed by the Lua script (sync_voice_to_engine) right after
                // voiceOn; the Lua voices table is the only source of their values.

                synths[this.grainKey(voice)] = Synth(\strataGrain, [
                    \in, bus,
                    \out, mainBus,
                    \grainSize, msg[5],
                    \grainDensity, msg[6],
                    \pitchShift, msg[7]
                ], target: processGroup);

                // Create modulation output synth
                synths[this.modKey(voice)] = Synth(\strataMod, [
                    \in, bus,
                    \out, modBus
                ], target: processGroup);
            };
        });

        // Re-articulate a running voice without creating new nodes:
        // fires the voice synth's accent envelope (and re-plucks Karplus)
        this.addCommand(\retrigger, "i", { arg msg;
            this.setSynth(this.voiceKey(msg[1]), \t_trig, 1);
        });

        this.addCommand(\voiceOff, "i", { arg msg;
            this.releaseVoice(msg[1]);
        });

        this.addCommand(\setVoiceParam, "isf", { arg msg;
            this.setSynth(this.voiceKey(msg[1]), msg[2], msg[3]);
        });

        this.addCommand(\setGrainParam, "isf", { arg msg;
            this.setSynth(this.grainKey(msg[1]), msg[2], msg[3]);
        });

        this.addCommand(\setMasterDrift, "f", { arg msg;
            this.setSynth(\master, \drift, msg[1]);
        });

        this.addCommand(\setReverb, "fff", { arg msg;
            this.setSynth(\reverb, \mix, msg[1], \size, msg[2], \damp, msg[3]);
        });

        // Multi-source cross-modulation commands
        this.addCommand(\setModSource, "iii", { arg msg;
            var voice = msg[1];
            var slot = msg[2];  // 1, 2, or 3
            var sourceVoice = msg[3];
            var sourceBus;

            // -1 (or any out-of-range source) means no modulation: read the
            // always-zero silent bus
            if (this.validVoice(sourceVoice)) {
                sourceBus = modBuses[sourceVoice].index;
            } {
                sourceBus = silentBus.index;
            };

            this.setSynth(this.voiceKey(voice), ("modBus" ++ slot).asSymbol, sourceBus);
        });

        this.addCommand(\setModAmpAmt, "iif", { arg msg;
            // msg: voice, slot (1-3), amount
            this.setSynth(this.voiceKey(msg[1]), ("modAmpAmt" ++ msg[2]).asSymbol, msg[3]);
        });

        this.addCommand(\setModFreqAmt, "iif", { arg msg;
            // msg: voice, slot (1-3), amount
            this.setSynth(this.voiceKey(msg[1]), ("modFreqAmt" ++ msg[2]).asSymbol, msg[3]);
        });

        this.addCommand(\setModSpeed, "if", { arg msg;
            this.setSynth(this.modKey(msg[1]), \speed, msg[2]);
        });

        // Start reverb and master at the tail of the engine group
        synths[\reverb] = Synth(\strataReverb, [
            \in, mainBus,
            \out, reverbBus
        ], target: context.xg, addAction: \addToTail);

        synths[\master] = Synth(\strataMaster, [
            \in, reverbBus,
            \out, context.out_b
        ], target: context.xg, addAction: \addToTail);
    }

    voiceKey { arg voice; ^("voice" ++ voice).asSymbol }
    grainKey { arg voice; ^("grain" ++ voice).asSymbol }
    modKey { arg voice; ^("mod" ++ voice).asSymbol }

    validVoice { arg voice;
        ^voice.isInteger and: { (voice >= 0) and: { voice < numVoices } }
    }

    // Gate off a voice's synth trio (each frees itself after its release)
    // and forget it, so later commands to that voice are no-ops
    releaseVoice { arg voice;
        [this.voiceKey(voice), this.grainKey(voice), this.modKey(voice)].do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) { synth.set(\gate, 0) };
        });
    }

    // Set controls on a synth only if it is running
    setSynth { arg key ... controls;
        var synth = synths[key];
        if (synth.notNil) { synth.set(*controls) };
    }

    free {
        synths.do({ arg synth; synth.free });
        // also frees voices still in their release phase
        voiceGroup.free;
        processGroup.free;
        granBuses.do({ arg bus; bus.free });
        modBuses.do({ arg bus; bus.free });
        silentBus.free;
        mainBus.free;
        reverbBus.free;
    }
}
