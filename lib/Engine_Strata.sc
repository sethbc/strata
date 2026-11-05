// Engine_Strata.sc
// Ambient granular synthesis engine for norns
// Multiple synthesis voices with granular processing

Engine_Strata : CroneEngine {
    var <numVoices = 7;  // Must match NUM_VOICES in strata.lua
    var <voiceSynthDefs;
    var <synths;
    var <granBuses;
    var <mainBus;   // grain outputs mix here
    var <filterBus; // filter output, delay input
    var <delayBus;  // delay output, reverb input
    var <reverbBus;
    var <modBuses;  // Control buses for cross-modulation
    var <silentBus; // Always-zero control bus used for "no modulation source"
    var <envBuffers; // Grain envelope shapes 1-4 (envShape 0 is GrainIn's built-in Hann)
    var <voiceGroup;   // Input synth and voice synths (head of context.xg)
    var <processGroup; // Grain synths, then mod synths (after voiceGroup)

    // Audio sources: grainSource[voice] is 0 = the voice's synth,
    // 1..numBuffers = buffer slot, numBuffers + 1 = live input
    var <numBuffers = 8;      // Must match NUM_BUFFERS in strata.lua
    var <bufferSeconds = 16;  // Must match BUFFER_SECONDS in strata.lua
    var <buffersL, <buffersR; // One mono buffer per channel per slot (GrainBuf reads mono only)
    var <bufferFrames;        // Valid (loaded or recorded) frames per slot; 0 = empty
    var <bufferSampleRates;   // Sample rate of each slot's content (valid seconds = frames / rate)
    var <recordSynths;        // Running strataRecord synth per slot, or nil
    var <recordFrameBuses;    // Per slot: frames recorded so far, written by strataRecord
    var <slotChanges;         // Per slot: counts loads, records, clears and stops; a late reply applies only if unchanged
    var <stopReplies;         // Per slot: the slotChanges count of a stopRecord whose frame count is still awaited, or nil
    var <inputBus;            // Stereo live input, written by inputSynth
    var <inputSynth;
    var <grainSource;
    var <voiceControls; // Per voice: voice synth controls (params, crossmod) for restarts
    var <grainControls; // Per voice: grain synth controls, carried into a replacement
    var <releasingSynths;     // Per voice: released synths still in their release (key -> Synth), re-gated by voiceOn
    var <releasedGrainSource; // Per voice: the source its releasing grain synth was built for
    var controlNameSets;      // Per voice and grain SynthDef: its control names (IdentitySet), for controlPairs
    var <fadingSynths;        // Per voice: grain and voice synths a source switch gated off, still releasing
    var <cuttingSynths;       // Per voice: grain and voice synths in their kill fade (cutSynth), freed by the next switch
    var <bufferStatePoll;
    var bufferStateCursor = 0;
    var <bufferStateStride = 100; // bufferState value = slot index * stride + valid seconds
    var <grainRelease = 2;        // Release time of both grain SynthDefs
    var <switchCutTime = 0.05;    // Length of the kill fade (cutSynth); built into the SynthDefs in alloc, so later changes do nothing
    // Real-time memory (see "Real-time memory" in docs/notes/engine.md). Both
    // are built into the grain SynthDefs in alloc, so later changes do nothing.
    var <pitchShiftWindow = 0.1;  // Grain PitchShift window (s): fixed, never the grain size (its delay line is allocated at that size)
    var <maxGrains = 128;         // Grain table of every GrainIn/GrainBuf: Lua's largest overlap is 0.5 s x 200 grains/s = 100
    var <>scratchDir;             // Where completed recordings are written (buf<n>.wav)
    var writeCount = 0;
    var <writeGenerations;        // Per output path: the newest write's number; older writes abandon
    var <>writeChunkWait = 0.001; // Pause between interleave chunks (the engine check slows it)
    var <int16Peak = 0.999969482421875; // 32767 / 32768: the largest sample a 16-bit write keeps (symmetric clip)
    var <instanceTag;             // Unique per engine instance in the sclang session; part of every temporary and .part name
    var <stalePartAge = 60;       // deleteStaleParts deletes only .part files older than this (s)
    // Wait after fading a slot's grain synths (bufFrames 0; strataGrainBuf's
    // hasAudio lag is 0.05 s) before zeroing or overwriting it. The engine check lengthens it.
    var <>bufferFadeWait = 0.06;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        // Voice SynthDef for each voice index (0-indexed, as sent by Lua)
        voiceSynthDefs = [\strataResonator, \strataFM, \strataFolder, \strataSub,
            \strataPulse, \strataKarplus, \strataRing];

        // Audio buses for granular processing (one stereo bus per voice)
        granBuses = Array.fill(numVoices, { Bus.audio(context.server, 2) });
        // Effects chain: mainBus -> filter -> filterBus -> delay -> delayBus
        // -> reverb -> reverbBus -> master
        mainBus = Bus.audio(context.server, 2);
        filterBus = Bus.audio(context.server, 2);
        delayBus = Bus.audio(context.server, 2);
        reverbBus = Bus.audio(context.server, 2);

        // Control buses for cross-modulation (one per voice)
        modBuses = Array.fill(numVoices, { Bus.control(context.server, 1) });

        // "No modulation source" must read a bus that is always zero. Control
        // bus 0 is not safe: CroneAudioContext allocates the input amplitude
        // follower (amp_in_b) there before any engine loads.
        silentBus = Bus.control(context.server, 1);
        silentBus.set(0);

        // Grain envelope shapes selected by setGrainParam(voice, \envShape, n):
        // 0 = GrainIn's built-in Hann (envbufnum -1), 1-4 = these buffers
        envBuffers = [
            Env.sine,
            Env.perc(0.1, 0.9),
            Env.linen(0.1, 0.8, 0.1),
            Env([0, 1, 1, 0], [0.25, 0.5, 0.25])  // trapezoid
        ].collect({ arg env; Buffer.loadCollection(context.server, env.asSignal(1024)) });

        // Buffer slots: a left/right pair of mono buffers each, 16 s at the
        // server rate (8 slots x 2 x 16 s x 48 kHz x 4 bytes = about 49 MB)
        buffersL = Array.fill(numBuffers, { Buffer.alloc(context.server, context.server.sampleRate * bufferSeconds, 1) });
        buffersR = Array.fill(numBuffers, { Buffer.alloc(context.server, context.server.sampleRate * bufferSeconds, 1) });
        bufferFrames = Array.fill(numBuffers, 0);
        bufferSampleRates = Array.fill(numBuffers, { context.server.sampleRate });
        recordSynths = Array.newClear(numBuffers);
        recordFrameBuses = Array.fill(numBuffers, { Bus.control(context.server, 1) });
        slotChanges = Array.fill(numBuffers, 0);
        stopReplies = Array.newClear(numBuffers);
        inputBus = Bus.audio(context.server, 2);
        // Equals Lua's _path.audio .. "strata/scratch/" on norns
        scratchDir = Platform.userHomeDir +/+ "dust/audio/strata/scratch/";
        instanceTag = UniqueID.next;
        this.deleteStaleParts;

        writeGenerations = Dictionary.new;
        grainSource = Array.fill(numVoices, 0);
        voiceControls = Array.fill(numVoices, { Dictionary.new });
        grainControls = Array.fill(numVoices, { Dictionary.new });
        releasingSynths = Array.fill(numVoices, { Dictionary.new });
        releasedGrainSource = Array.fill(numVoices, 0);
        fadingSynths = Array.fill(numVoices, { IdentitySet.new });
        cuttingSynths = Array.fill(numVoices, { IdentitySet.new });

        // SynthDefs

        // Live input copied to inputBus for input-sourced grain synths and recording
        SynthDef(\strataInput, {
            arg out;
            Out.ar(out, SoundIn.ar([0, 1]));
        }).add;

        // Records the stereo input into a slot's buffer pair from frame 0
        // (replacing, never overdubbing) and frees itself after duration.
        // framesOut holds the frames recorded so far, read by stopRecord.
        SynthDef(\strataRecord, {
            arg in, bufnumL, bufnumR, level=1, duration=1, framesOut;
            var sig = In.ar(in, 2) * level;
            RecordBuf.ar(sig[0], bufnumL, loop: 0, doneAction: 2);
            RecordBuf.ar(sig[1], bufnumR, loop: 0);
            Out.kr(framesOut, Sweep.kr(0, SampleRate.ir));
            Line.kr(0, 0, duration, doneAction: 2);
        }).add;

        // Modulation output synth - outputs envelope follower signal for cross-mod
        SynthDef(\strataMod, {
            arg in, out, gate=1, speed=10;
            var sig, env, modSig;

            env = EnvGen.kr(Env.asr(0.1, 1, 0.5), this.openedGate(gate), doneAction: 2);
            sig = In.ar(in, 2).sum;  // Sum stereo to mono

            // Envelope follower with smoothing
            modSig = Amplitude.kr(sig, 0.01, 0.1);
            // Add slow LFO component for more movement
            modSig = (modSig * 0.7) + (LFNoise1.kr(speed).range(0, 0.3));
            modSig = modSig.lag(0.05);  // Smooth the output

            Out.kr(out, modSig * env);
        }).add;

        // Every voice and grain SynthDef gates its ASR through openedGate
        // and multiplies killFade (the engine's cut) into it; see those methods
        SynthDef(\strataResonator, {
            arg out, gate=1, freq=100, rq=0.1, noise=0.5,
            mod1=0.1, mod2=0.15, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, env, noiseSource, modSig, modFreq, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(4, 1, 8), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
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
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, mod, env, carrier, modSig, modFreqVal, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(5, 1, 10), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreqVal = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
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
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, env, foldAmt, modSig, modFreq, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(3, 1, 6), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
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
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, env, modFreq, modSig, modAmp;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(8, 1, 12), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
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
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, env, modSig, modFreq, modAmp, modWidth;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(2, 1, 4), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
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
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, env, modSig, modFreq, modAmp, noise, pluck, exciteTrig;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(0.01, 1, 2), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            // Excitation trigger: the free-running exciter plus retrigger
            // commands, so a pattern step actually re-plucks the string as
            // hard as its velocity. T2A is a single-sample impulse, so the
            // velocity only scales that trigger's excitation, never a
            // running signal.
            exciteTrig = Impulse.ar(excite) + (T2A.ar(t_trig) * velocity);

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
            t_trig=0, velocity=1, bend=1, kill=0;
            var sig, env, modSig, modFreq, modAmp, car, modulator, ring;
            var mod1Sig, mod2Sig, mod3Sig, accent;

            env = EnvGen.kr(Env.asr(3, 1, 5), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent envelope fired by the retrigger command (pattern steps,
            // MIDI notes); its depth is the velocity sent with the trigger.
            // levelScale is sampled when the envelope starts, so a new
            // velocity never rescales a running accent tail.
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            // Read and mix modulation signals from 3 sources
            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);

            // Mix modulation signals with clamping to prevent excessive modulation.
            // The frequency modulator is clamped to -0.9..2 so the modulated
            // frequency stays positive (at least 0.1 * freq). bend is the MIDI
            // pitchbend ratio (1 = none, +/-2 semitones).
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            modFreq = freq * bend * (1 + ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2));
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

        // Granular processor for a stereo bus: the voice's own bus (synth
        // source) or inputBus (input source). For the input source the engine
        // sets accentAmt 1 (there is no voice synth to carry the accent),
        // mirrorLevel 1 (copies the output to the voice bus for strataMod)
        // and modLevel 1 (amplitude crossmod; frequency crossmod has no
        // meaning for live input and is ignored); for the synth source all
        // three are 0 (their defaults), since the voice synth already accents
        // and crossmods and this synth reads the voice bus. bend is unused here.
        SynthDef(\strataGrain, {
            arg in, out, gate=1,
            grainSize=0.1, grainDensity=20, pitchShift=1,
            posSpread=0.5, panSpread=0.5, amp=1, envBuf = -1,
            grainMode=0, t_trig=0, velocity=1, accentAmt=0,
            mirrorOut=0, mirrorLevel=0, bend=1, kill=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0, modLevel=0;
            var sig, env, input, mode, grainTrigger, spreadLevel, accent, left, right, modSig;

            env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent for input-sourced voices; levelScale is sampled per
            // trigger, so velocity never rescales a running tail
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);
            // Amplitude crossmod for input-sourced voices, clamped like the voices'
            modSig = ((In.kr(modBus1, 1) * modAmpAmt1) + (In.kr(modBus2, 1) * modAmpAmt2)
                + (In.kr(modBus3, 1) * modAmpAmt3)).clip(-2, 2) * modLevel;
            input = In.ar(in, 2);

            // grainMode 0 = continuous (grainDensity grains per second),
            // 1 = triggered: one grain per t_trig (retrigger: pattern steps,
            // MIDI notes). Synth-sourced velocity reaches triggered grains
            // through the voice synth's accent; GrainIn has no per-grain
            // amplitude. Triggered mode mutes the position-spread path so
            // only the grains sound (faded over 50 ms, so a mode change
            // does not click; grainDensity and posSpread then do nothing).
            mode = grainMode.round.clip(0, 1);
            grainTrigger = Select.ar(mode, [Impulse.ar(grainDensity), T2A.ar(t_trig)]);
            spreadLevel = Select.kr(mode, [1, 0]).lag(0.05);

            // One mono GrainIn per input channel on a shared trigger, panned
            // as a pair like strataGrainBuf. (A stereo GrainIn on a stereo
            // input expands into two, each panning its own channel, which
            // Out then folds back to one channel apiece: pan spread did
            // nothing and the output path was doubled.) The voice's own pan
            // is already in the voice synth's output.
            left = GrainIn.ar(1, grainTrigger, grainSize, input[0], 0, envBuf, maxGrains);
            right = GrainIn.ar(1, grainTrigger, grainSize, input[1], 0, envBuf, maxGrains);
            sig = Balance2.ar(left, right, LFNoise1.kr(2).range(panSpread.neg, panSpread));

            // Position spread: a little of the input, smeared by a wandering delay
            sig = sig + (DelayC.ar(
                input,
                0.2,
                LFNoise1.kr(1).range(0, posSpread * 0.2)
            ) * 0.3 * spreadLevel);

            // Transpose the whole grain-synth output (GrainIn has no rate
            // input). Shifting after the spread path is summed keeps every
            // part transposed and time-aligned. The window is the fixed
            // pitchShiftWindow, not the grain size: PitchShift allocates its
            // delay line from the real-time pool for the window it starts with.
            sig = PitchShift.ar(
                sig,
                windowSize: pitchShiftWindow,
                pitchRatio: pitchShift.lag(0.5),
                pitchDispersion: 0,
                timeDispersion: 0
            );

            sig = sig * env * (amp * (1 + modSig) * (1 + (accent * accentAmt))).clip(0, 2);
            Out.ar(out, sig);
            Out.ar(mirrorOut, sig * mirrorLevel);
        }).add;

        // Granular processor for a buffer slot: two mono GrainBufs (left and
        // right buffers) share one trigger, position, rate and duration, so
        // every grain is sample-aligned across the pair. bufPos (0-1) and the
        // scan are fractions of the valid region (bufFrames), so a short
        // sample uses the whole position range; bufScan moves the position
        // in valid-region lengths per second and wraps. Crossmod applies to
        // amplitude and rate as voice synths apply it to amp and freq.
        // bufRateScale is the content's sample rate over the server's (what
        // BufRateScale.kr would report), tracked by the engine: b_alloc keeps
        // a loaded file's rate, and norns' scsynth has no b_setSampleRate. The
        // output also goes to mirrorOut (the voice's bus) so the voice's
        // strataMod keeps following what is heard; the engine sets mirrorLevel
        // 1 (the default 0 keeps a synth without a mirrorOut off bus 0).
        SynthDef(\strataGrainBuf, {
            arg out, gate=1, bufnumL=0, bufnumR=0, bufFrames=1, bufRateScale=1, bufPos=0, bufRate=1, bufScan=0,
            grainSize=0.1, grainDensity=20, pitchShift=1, posSpread=0.5, panSpread=0.5,
            envBuf = -1, grainMode=0, t_trig=0, amp=1, bend=1,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            velocity=1, mirrorOut=0, mirrorLevel=0, kill=0;
            var sig, env, accent, mod1Sig, mod2Sig, mod3Sig, modSig, rateMod, modAmp;
            var mode, grainTrigger, validFraction, scanPos, grainPos, rate, left, right, hasAudio;

            env = EnvGen.kr(Env.asr(0.1, 1, grainRelease), this.openedGate(gate), doneAction: 2) * this.killFade(kill);
            // Accent fired by retrigger; levelScale is sampled per trigger
            accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);

            mod1Sig = In.kr(modBus1, 1);
            mod2Sig = In.kr(modBus2, 1);
            mod3Sig = In.kr(modBus3, 1);
            modSig = ((mod1Sig * modAmpAmt1) + (mod2Sig * modAmpAmt2) + (mod3Sig * modAmpAmt3)).clip(-2, 2);
            // Clamped like voice frequency modulation so the rate stays positive
            rateMod = ((mod1Sig * modFreqAmt1) + (mod2Sig * modFreqAmt2) + (mod3Sig * modFreqAmt3)).clip(-0.9, 2);
            modAmp = (amp * (1 + modSig) * (1 + accent)).clip(0, 2);

            mode = grainMode.round.clip(0, 1);
            grainTrigger = Select.ar(mode, [Impulse.ar(grainDensity), T2A.ar(t_trig)]);

            validFraction = (bufFrames / BufFrames.kr(bufnumL)).clip(0, 1);
            scanPos = (bufPos + Phasor.ar(0, bufScan * SampleDur.ir, 0, 1)) % 1;
            grainPos = (scanPos + TRand.ar(posSpread * -0.5, posSpread * 0.5, grainTrigger)).wrap(0, 1) * validFraction;
            // GrainBuf already scales by the buffer's own rate (BufRateScale), which
            // the server keeps from the last file read even after a recording:
            // divided out, so the engine's bufRateScale applies exactly once
            rate = bufRate * bend * (bufRateScale / BufRateScale.kr(bufnumL)) * (1 + rateMod);

            left = GrainBuf.ar(1, grainTrigger, grainSize, bufnumL, rate, grainPos, 2, 0, envBuf, maxGrains);
            right = GrainBuf.ar(1, grainTrigger, grainSize, bufnumR, rate, grainPos, 2, 0, envBuf, maxGrains);
            sig = Balance2.ar(left, right, LFNoise1.kr(2).range(panSpread.neg, panSpread));

            // Same transposition stage as strataGrain (fixed window), once for the pair
            sig = PitchShift.ar(
                sig,
                windowSize: pitchShiftWindow,
                pitchRatio: pitchShift.lag(0.5),
                pitchDispersion: 0,
                timeDispersion: 0
            );

            // Silent while the slot is empty or being recorded (bufFrames 0):
            // every grain would read position 0 and loop the take's first grain
            hasAudio = (bufFrames > 0).lag(0.05);

            sig = sig * env * modAmp * hasAudio;
            Out.ar(out, sig);
            Out.ar(mirrorOut, sig * mirrorLevel);
        }).add;

        // Multimode filter: 0 lowpass, 1 highpass, 2 bandpass. res 0..1 maps
        // to rq 1..0.05; mix crossfades dry (0, the default bypass) to filtered.
        // A type change crossfades over 20 ms: the three filters always run
        // and each is weighted by a lagged "this is the type" (the weights
        // sum to 1 once settled), so switching never steps the output.
        SynthDef(\strataFilter, {
            arg in, out, freq=5000, res=0.5, filterType=0, mix=0;
            var dry, filtered, cutoff, rq, wet, type;

            dry = In.ar(in, 2);
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
        
        // The control names of every SynthDef controlPairs filters for, looked up once
        controlNameSets = IdentityDictionary.new;
        (voiceSynthDefs ++ [\strataGrain, \strataGrainBuf]).do({ arg defName;
            controlNameSets[defName] = SynthDescLib.global.at(defName).controlNames.collect(_.asSymbol).as(IdentitySet);
        });

        context.server.sync;

        synths = Dictionary.new;

        // Node order inside the engine group (context.xg):
        // voiceGroup (input, voices, recorders) -> processGroup (grain
        // synths that read a voice bus at the head; grain synths that mirror
        // into a voice bus just before that voice's live mod synth, so the
        // mirror reaches strataMod in the same block; mod synths added at
        // the tail; see startPlacedGrainSynth) -> filter -> delay -> reverb
        // -> master.
        // Keeping everything inside xg leaves norns' output group (og) and
        // its output metering after the engine.
        voiceGroup = Group.head(context.xg);
        processGroup = Group.after(voiceGroup);
        inputSynth = Synth(\strataInput, [\out, inputBus], voiceGroup, \addToHead);

        // Commands for voice control
        this.addCommand(\voiceOn, "iffffff", { arg msg;
            var voice = msg[1].asInteger;

            if (this.validVoice(voice)) {
                // All 3 mod slots start on the silent bus (no modulation) and
                // bend at 1. Voice-specific params, posSpread, crossmod
                // routing and mod speed are pushed by the Lua script
                // (sync_voice_to_engine) right after voiceOn; the Lua voices
                // table is the only source of their values.
                voiceControls[voice] = Dictionary[
                    \freq -> msg[2], \amp -> msg[3], \pan -> msg[4], \bend -> 1,
                    \modBus1 -> silentBus.index, \modBus2 -> silentBus.index, \modBus3 -> silentBus.index,
                    \modAmpAmt1 -> 0, \modAmpAmt2 -> 0, \modAmpAmt3 -> 0,
                    \modFreqAmt1 -> 0, \modFreqAmt2 -> 0, \modFreqAmt3 -> 0
                ];
                // Merged into the grain controls the voice already has, so a
                // grain synth voiceOn builds starts in the voice's grain mode,
                // envelope and buffer position (Lua re-sends them right after)
                grainControls[voice].putAll(Dictionary[
                    \grainSize -> msg[5], \grainDensity -> msg[6], \pitchShift -> msg[7]
                ]);

                // Re-gates the synths the voice still has (running or
                // releasing) and starts the missing ones; never stacks
                this.gateVoice(voice);
            };
        });

        // Re-articulate a running voice without creating new nodes: fires
        // the accent envelope at the given velocity (0-1) on whichever synth
        // carries it (the voice synth for the synth source, re-plucking
        // Karplus; the grain synth for buffer and input sources), and one
        // grain when the grain synth is in triggered mode. velocity is set
        // in the same message as t_trig.
        this.addCommand(\retrigger, "if", { arg msg;
            var velocity = msg[2].clip(0, 1);
            this.setSynth(this.voiceKey(msg[1]), \velocity, velocity, \t_trig, 1);
            this.setSynth(this.grainKey(msg[1]), \velocity, velocity, \t_trig, 1);
        });

        this.addCommand(\voiceOff, "i", { arg msg;
            this.releaseVoice(msg[1]);
        });

        this.addCommand(\setVoiceParam, "isf", { arg msg;
            this.setVoiceControl(msg[1], msg[2].asSymbol, msg[3]);
        });

        // envShape is an index (0 = Hann, 1-4 = envBuffers) that the engine
        // turns into the grain synth's envBuf; other params pass straight
        // through. Every value is kept so a replacement grain synth (source
        // switch) starts with it.
        this.addCommand(\setGrainParam, "isf", { arg msg;
            var voice = msg[1], param = msg[2].asSymbol, value = msg[3], bufnum;
            if (this.validVoice(voice)) {
                if (param == \envShape) {
                    bufnum = this.envBufnumFor(value.round.asInteger);
                    if (bufnum.notNil) {
                        grainControls[voice][\envBuf] = bufnum;
                        this.setSynth(this.grainKey(voice), \envBuf, bufnum);
                    };
                } {
                    grainControls[voice][param] = value;
                    this.setSynth(this.grainKey(voice), param, value);
                };
            };
        });

        // source: 0 = the voice's synth, 1-8 = buffer slot, 9 = live input.
        // A stopped voice only records it (voiceOn builds the right synths);
        // a running voice gets its grain synth replaced, never stacked.
        this.addCommand(\setGrainSource, "ii", { arg msg;
            var voice = msg[1], source = msg[2];
            if (this.validVoice(voice) and: { this.validSource(source) }
                and: { source != grainSource[voice] }) {
                grainSource[voice] = source;
                if (this.voiceRunning(voice)) { this.replaceGrainSynth(voice) };
            };
        });

        // msg: slot index (0-7), sound file path
        this.addCommand(\loadBuffer, "is", { arg msg;
            this.loadSlot(msg[1], msg[2].asString);
        });

        // msg: slot index, seconds, input level
        this.addCommand(\recordBuffer, "iff", { arg msg;
            this.recordSlot(msg[1], msg[2], msg[3]);
        });

        this.addCommand(\clearBuffer, "i", { arg msg;
            this.clearSlot(msg[1]);
        });

        // End a recording early, keeping what was captured
        this.addCommand(\stopRecord, "i", { arg msg;
            this.stopRecordSlot(msg[1]);
        });

        // msg: slot index, path of the stereo 16-bit WAV to write
        this.addCommand(\saveBuffer, "is", { arg msg;
            if (this.validBuffer(msg[1])) { this.writeSlot(msg[1], msg[2].asString) };
        });

        // Valid seconds per slot. matron only accepts single-float value
        // polls (/poll/value is typed "if"), so each message carries one
        // slot: slot index * bufferStateStride + seconds. The periodic poll
        // cycles through the slots; every change is also sent at once.
        bufferStatePoll = this.addPoll(\bufferState, {
            var value = this.bufferStateValue(bufferStateCursor);
            bufferStateCursor = (bufferStateCursor + 1) % numBuffers;
            value
        });

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

            this.setVoiceControl(voice, ("modBus" ++ slot).asSymbol, sourceBus);
        });

        this.addCommand(\setModAmpAmt, "iif", { arg msg;
            // msg: voice, slot (1-3), amount
            this.setVoiceControl(msg[1], ("modAmpAmt" ++ msg[2]).asSymbol, msg[3]);
        });

        this.addCommand(\setModFreqAmt, "iif", { arg msg;
            // msg: voice, slot (1-3), amount
            this.setVoiceControl(msg[1], ("modFreqAmt" ++ msg[2]).asSymbol, msg[3]);
        });

        this.addCommand(\setModSpeed, "if", { arg msg;
            this.setSynth(this.modKey(msg[1]), \speed, msg[2]);
        });

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

    voiceKey { arg voice; ^("voice" ++ voice).asSymbol }
    grainKey { arg voice; ^("grain" ++ voice).asSymbol }
    modKey { arg voice; ^("mod" ++ voice).asSymbol }

    // GrainIn envbufnum for an envShape index: 0 = built-in Hann (-1),
    // 1-4 = envBuffers; nil for anything else
    envBufnumFor { arg index;
        if (index == 0) { ^-1 };
        if ((index >= 1) and: { index <= envBuffers.size }) { ^envBuffers[index - 1].bufnum };
        ^nil
    }

    validVoice { arg voice;
        ^voice.isInteger and: { (voice >= 0) and: { voice < numVoices } }
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

    grainDefFor { arg voice;
        ^if (grainSource[voice].inclusivelyBetween(1, numBuffers)) { \strataGrainBuf } { \strataGrain }
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

    // A voice-level control (synthesis param, crossmod routing or amount):
    // kept for restarts, sent to the voice synth, and to the grain synth
    // when that has the control (strataGrainBuf takes crossmod, amp and
    // bend; the input strataGrain takes amp and the amplitude crossmod)
    // while the voice is not on its synth source
    setVoiceControl { arg voice, control, value;
        if (this.validVoice(voice)) {
            voiceControls[voice][control] = value;
            this.setSynth(this.voiceKey(voice), control, value);
            if (grainSource[voice] != 0) {
                this.setSynth(this.grainKey(voice), *this.controlPairs(this.grainDefFor(voice), Dictionary[control -> value]));
            };
        };
    }

    startVoiceSynth { arg voice;
        var defName = voiceSynthDefs[voice];
        ^this.watchVoiceSynth(voice, this.voiceKey(voice),
            Synth(defName, [\out, granBuses[voice]] ++ this.controlPairs(defName, voiceControls[voice]),
                target: voiceGroup))
    }

    // Modulation output synth, after every grain synth
    startModSynth { arg voice;
        ^this.watchVoiceSynth(voice, this.modKey(voice), Synth(\strataMod, [
            \in, granBuses[voice],
            \out, modBuses[voice]
        ], target: processGroup, addAction: \addToTail))
    }

    // The voice-level (buffer and input sources) and grain controls a grain
    // synth for the voice's current source takes
    grainControlPairs { arg voice;
        var defName = this.grainDefFor(voice);
        var pairs = this.controlPairs(defName, grainControls[voice]);
        if (grainSource[voice] != 0) { pairs = this.controlPairs(defName, voiceControls[voice]) ++ pairs };
        ^pairs
    }

    // The grain synth for the voice's current source, with its current
    // grain controls. Buffer and input sources also take the voice-level
    // controls the grain SynthDef has (level, crossmod, bend). The mirror,
    // accent and (strataGrain) crossmod switches are always set explicitly.
    startGrainSynth { arg voice, target, addAction;
        var source = grainSource[voice];
        var defName = this.grainDefFor(voice);
        var args = [\out, mainBus, \mirrorOut, granBuses[voice]];

        case
        { source == 0 } {
            // crossmod off, and read from the silent bus, never control bus 0 (the
            // input amplitude follower on norns)
            args = args ++ [\in, granBuses[voice], \mirrorLevel, 0, \accentAmt, 0, \modLevel, 0,
                \modBus1, silentBus.index, \modBus2, silentBus.index, \modBus3, silentBus.index];
        }
        { source == this.inputSource } {
            args = args ++ [\in, inputBus, \mirrorLevel, 1, \accentAmt, 1, \modLevel, 1];
        }
        { args = args ++ [\mirrorLevel, 1] ++ this.bufferSlotPairs(voice) };
        ^this.watchVoiceSynth(voice, this.grainKey(voice),
            Synth(defName, args ++ this.grainControlPairs(voice), target, addAction))
    }

    // A buffer-sourced voice's slot as strataGrainBuf controls (bufnums,
    // valid length, rate scale); empty for the synth and input sources
    bufferSlotPairs { arg voice;
        var slot = grainSource[voice] - 1;
        if (grainSource[voice].inclusivelyBetween(1, numBuffers).not) { ^[] };
        ^[\bufnumL, buffersL[slot].bufnum, \bufnumR, buffersR[slot].bufnum,
            \bufFrames, bufferFrames[slot], \bufRateScale, this.bufferRateScale(slot)]
    }

    // A new grain synth for the voice's source, placed so the node order
    // holds after any history of switches: one that reads the voice bus
    // (synth source) at the head of processGroup, so it runs before every
    // grain synth that mirrors into a voice bus and never re-grains a
    // mirror; one that mirrors (buffer and input sources) at the tail of
    // processGroup, then moved before the voice's running strataMod (the
    // mod synth started or re-gated next is put after it when there is
    // none). Never created next to another synth: that one may already
    // have freed on the server without sclang knowing yet (an /s_new to a
    // missing target creates nothing, leaving a grain synth that never
    // frees). A move to a freed mod synth just fails; its onFree restart
    // goes to the tail, after the grain synth.
    startPlacedGrainSynth { arg voice;
        var modSynth = synths[this.modKey(voice)], grainSynth;
        if (grainSource[voice] == 0) { ^this.startGrainSynth(voice, processGroup, \addToHead) };
        grainSynth = this.startGrainSynth(voice, processGroup, \addToTail);
        if (modSynth.notNil) { grainSynth.moveBefore(modSynth) };
        ^grainSynth
    }

    // Start a voice: every synth it still has is re-gated instead of
    // stacking a new one. A running voice's synths only take the voiceOn
    // values. A released voice's synths that are still in their release
    // get gate 1 (the ASR restarts its attack from the current level) and
    // the values with set; the ones already freed are started. A releasing
    // synth that no longer fits the source (it changed while the voice was
    // stopped) is left to finish: a grain synth for another source releases
    // beside the new one, and a voice synth (the source is no longer the
    // synth) is given a forced release (release(grainRelease)), as
    // replaceGrainSynth does. New grain synths are placed by
    // startPlacedGrainSynth; a mod synth re-gated after a new mirroring
    // grain synth went to the tail of processGroup is moved after it.
    gateVoice { arg voice;
        var releasing = releasingSynths[voice];
        var voiceKey = this.voiceKey(voice), grainKey = this.grainKey(voice), modKey = this.modKey(voice);
        var stillReleasing = { arg key; var synth = releasing[key]; synth.notNil and: { synth.isPlaying } };

        // Voice synth: synth source only
        if (grainSource[voice] == 0) {
            if (synths[voiceKey].isNil and: { stillReleasing.(voiceKey) }) { synths[voiceKey] = releasing.removeAt(voiceKey) };
            if (synths[voiceKey].isNil) {
                synths[voiceKey] = this.startVoiceSynth(voice);
            } {
                synths[voiceKey].set(\gate, 1, *this.controlPairs(voiceSynthDefs[voice], voiceControls[voice]));
            };
        } {
            if (stillReleasing.(voiceKey)) { releasing[voiceKey].release(grainRelease) };
        };

        // Grain synth: re-gated only if it was built for the current source
        if (synths[grainKey].isNil and: { stillReleasing.(grainKey) } and: { releasedGrainSource[voice] == grainSource[voice] }) {
            synths[grainKey] = releasing.removeAt(grainKey);
        };
        if (synths[grainKey].isNil) {
            synths[grainKey] = this.startPlacedGrainSynth(voice);
        } {
            // with the slot as it is now: bufferChanged only reaches running grain synths
            synths[grainKey].set(\gate, 1, *(this.bufferSlotPairs(voice) ++ this.grainControlPairs(voice)));
        };

        if (synths[modKey].isNil and: { stillReleasing.(modKey) }) {
            synths[modKey] = releasing.removeAt(modKey);
            // after the voice's grain synth when that mirrors into the voice
            // bus (a move: if this mod synth has just freed, nothing happens
            // and its replacement starts at the tail)
            if (grainSource[voice] != 0) { synths[modKey].moveAfter(synths[grainKey]) };
        };
        if (synths[modKey].isNil) { synths[modKey] = this.startModSynth(voice) } { synths[modKey].set(\gate, 1) };
    }

    // Watch one of a voice's synths (key: its voiceKey, grainKey or modKey)
    // until it frees. A released synth is then forgotten. A synth the voice
    // is using frees only if its release ended just as voiceOn re-gated it
    // (the gate arrived too late); it is started again so the voice is
    // never left without it. free empties synths first, so nothing restarts
    // when the engine is freed.
    watchVoiceSynth { arg voice, key, synth;
        synth.register(true);  // playing from now on, so gateVoice can re-gate it at once
        synth.onFree({
            if (releasingSynths[voice][key] === synth) { releasingSynths[voice].removeAt(key) };
            fadingSynths[voice].remove(synth);
            cuttingSynths[voice].remove(synth);
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

    // Swap a running voice's grain synth for one matching its source: the
    // old one is released (grainRelease) as the new one starts, so one
    // voice never runs two grain paths beyond that release. The new one is
    // placed by startPlacedGrainSynth (bus-reading at the head, mirroring
    // before the voice's mod synth), so no grain synth re-grains a mirror.
    // Whatever an earlier switch (or a voiceOff the voice was restarted
    // from) left releasing is cut first (cutSynth: gone within
    // switchCutTime), so once a switch has been processed the voice has at
    // most one releasing grain synth and one releasing voice synth.
    replaceGrainSynth { arg voice;
        var oldGrain = synths.removeAt(this.grainKey(voice));
        var voiceSynth;

        this.cutFadingSynths(voice);
        synths[this.grainKey(voice)] = this.startPlacedGrainSynth(voice);
        if (oldGrain.notNil) {
            // A forced release (gate -1 - time), linear over grainRelease;
            // the next switch cuts it with its kill fade
            oldGrain.release(grainRelease);
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
                voiceSynth.release(grainRelease);
                fadingSynths[voice].add(voiceSynth);
            };
        };
    }

    // Cut (switchCutTime) the voice's grain and voice synths that are still
    // releasing and no longer used: those a source switch gated off, and
    // those voiceOff released that voiceOn did not re-gate (built for
    // another source). The running voice's synths are never among them.
    // Synths an earlier cut left in their kill fade are freed first, so a
    // burst of switches (several inside one switchCutTime: a chord of scene
    // buttons) never piles them up: a voice holds at most one live, one
    // releasing and one cutting set of synths (see Real-time memory in
    // docs/notes/engine.md).
    cutFadingSynths { arg voice;
        var releasing = releasingSynths[voice];
        this.freeCuttingSynths(voice);
        [this.voiceKey(voice), this.grainKey(voice)].do({ arg key;
            var synth = releasing.removeAt(key);
            if (synth.notNil) { fadingSynths[voice].add(synth) };
        });
        fadingSynths[voice].do({ arg synth; this.cutVoiceSynth(voice, synth) });
        fadingSynths[voice].clear;
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
    // sclang): /error -1 keeps that /n_free from being reported. onFree
    // forgets them; they are never in synths or releasingSynths.
    freeCuttingSynths { arg voice;
        cuttingSynths[voice].do({ arg synth;
            if (synth.isPlaying) { context.server.sendBundle(nil, ['/error', -1], ['/n_free', synth.nodeID]) };
        });
        cuttingSynths[voice].clear;
    }

    // End a voice or grain synth within switchCutTime through its kill
    // fade, whatever release it is already in. Not a second forced release:
    // EnvGen starts a forced release only when its gate crosses -1 from
    // above, so one already in a release(grainRelease) ignores a shorter one.
    cutSynth { arg synth;
        if (synth.isPlaying) { synth.set(\kill, 1) };
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

    bufferStateValue { arg index;
        ^(index * bufferStateStride) + (bufferFrames[index] / bufferSampleRates[index]).round(0.01)
    }

    bufferRateScale { arg index;
        ^bufferSampleRates[index] / context.server.sampleRate
    }

    // A slot's valid length or rate changed: tell the grain synths reading it and Lua
    bufferChanged { arg index;
        numVoices.do({ arg voice;
            if (grainSource[voice] == (index + 1)) {
                this.setSynth(this.grainKey(voice), \bufFrames, bufferFrames[index],
                    \bufRateScale, this.bufferRateScale(index));
            };
        });
        bufferStatePoll.update(this.bufferStateValue(index));
    }

    // Cancel a recording in progress, or one still waiting for its zeroed
    // buffers (it then never starts); its onFree sees it was cancelled
    stopRecording { arg index;
        var synth = recordSynths[index];
        recordSynths[index] = nil;
        if (synth.notNil and: { synth.isPlaying }) { synth.free };
    }

    // Read up to bufferSeconds of a sound file into a slot (channel 0 to the
    // left buffer, channel 1, or 0 again for a mono file, to the right).
    // At most bufferSeconds at the server rate fit (the buffers' size), so a
    // file at twice the server rate keeps half as many seconds. A missing,
    // unreadable or empty file leaves the slot unchanged (rejectLoad). The
    // file's sample rate becomes the slot's bufRateScale, so it plays at
    // pitch. The voices reading the slot fade out first (afterSlotFade):
    // the slot reads 0 frames until the reads have completed (a sync after
    // them), then its length and rate reach the grain synths and the poll,
    // only if nothing else changed the slot meanwhile (slotChanges).
    loadSlot { arg index, path;
        var file, frames, rightChannel, sampleRate, change;
        if (this.validBuffer(index).not) { ^this };
        file = SoundFile.openRead(path.standardizePath);
        if (file.isNil) { ^this.rejectLoad(index, "cannot read sound file " ++ path) };
        sampleRate = file.sampleRate;
        frames = [file.numFrames, (sampleRate * bufferSeconds).floor.asInteger, buffersL[index].numFrames].minItem;
        rightChannel = if (file.numChannels > 1) { 1 } { 0 };
        file.close;
        if (frames < 1) { ^this.rejectLoad(index, "sound file " ++ path ++ " is empty") };

        this.stopRecording(index);
        change = this.slotChanged(index);
        bufferFrames[index] = 0;
        this.bufferChanged(index);
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
            buffersL[index].readChannel(path.standardizePath, 0, frames, 0, false, [0]);
            buffersR[index].readChannel(path.standardizePath, 0, frames, 0, false, [rightChannel]);
            fork({
                context.server.sync;  // answered once both reads are done
                if (slotChanges[index] == change) {
                    bufferFrames[index] = frames;
                    bufferSampleRates[index] = sampleRate;
                    this.bufferChanged(index);
                };
            }, SystemClock);
        });
    }

    // A load whose file cannot be used leaves the slot as it is, except that
    // it cancels a recording in progress or waiting to start, or one stopped
    // early whose frame count has not arrived yet (stopReplies; the slot
    // change drops that reply), as Lua's load_buffer expects: that take
    // never completes, so it is never adopted under the bad file's name.
    // The slot reads empty (0 frames), as for a recording a clear cancelled.
    rejectLoad { arg index, reason;
        var recording = recordSynths[index].notNil or: { stopReplies[index].notNil };
        postln("strata: " ++ reason ++ "; buffer " ++ (index + 1)
            ++ (if (recording) { " recording cancelled" } { " unchanged" }));
        if (recording) {
            this.stopRecording(index);
            this.slotChanged(index);
            stopReplies[index] = nil;
            this.bufferChanged(index);
        };
    }

    // true when a running voice's grain synth reads the slot
    slotPlaying { arg index;
        ^(0..(numVoices - 1)).any({ arg voice;
            (grainSource[voice] == (index + 1)) and: { synths[this.grainKey(voice)].notNil }
        })
    }

    // Run action (zeroing or overwriting a slot) once the voices reading it
    // have faded out: the caller has set its bufFrames to 0 (bufferChanged),
    // which strataGrainBuf's hasAudio lag fades, so the sound never cuts
    // off. bufferFadeWait later when a running voice reads the slot, at once
    // otherwise. A delayed action runs only if nothing changed the slot
    // meanwhile (slotChanges), so a later load, record or clear always wins.
    afterSlotFade { arg index, change, action;
        if (this.slotPlaying(index).not) { ^action.value };
        SystemClock.sched(bufferFadeWait, {
            if (slotChanges[index] == change) { action.value };
            nil
        });
    }

    // Count a change to a slot (load, record, clear, stop) and return the
    // new count: a reply that arrives later applies only if it is unchanged
    slotChanged { arg index;
        slotChanges[index] = slotChanges[index] + 1;
        ^slotChanges[index]
    }

    // Record the stereo input into a slot, replacing it: the slot reads as
    // empty at once (the voices reading it fade out, afterSlotFade), then
    // the pair is zeroed and the record synth starts after a sync, so
    // zeroing never lands on the new take, and only if nothing cancelled it
    // meanwhile (a completion message could not be cancelled before the
    // node exists). The slot reads as empty until the recording completes,
    // then the take is written to scratchDir so it survives a restart.
    recordSlot { arg index, seconds, level;
        var frames, synth, change;
        if (this.validBuffer(index).not) { ^this };
        frames = (seconds * context.server.sampleRate).round.asInteger.clip(0, buffersL[index].numFrames);
        if (frames < 1) { ^this };

        this.stopRecording(index);
        change = this.slotChanged(index);
        bufferFrames[index] = 0;
        bufferSampleRates[index] = context.server.sampleRate;
        this.bufferChanged(index);

        synth = Synth.basicNew(\strataRecord, context.server);
        recordSynths[index] = synth;
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
            fork({
                context.server.sync;
                if (recordSynths[index] === synth) {
                    // Marked playing from the moment it is sent (not when /n_go
                    // arrives), so stopRecording frees it from here on
                    synth.register(true);
                    synth.onFree({
                        if (recordSynths[index] === synth) {
                            recordSynths[index] = nil;
                            bufferFrames[index] = frames;
                            this.bufferChanged(index);
                            this.writeSlot(index, this.scratchPath(index));
                        };
                    });
                    recordFrameBuses[index].set(0);
                    context.server.listSendMsg(synth.newMsg(inputSynth, [
                        \in, inputBus,
                        \bufnumL, buffersL[index].bufnum,
                        \bufnumR, buffersR[index].bufnum,
                        \level, level,
                        \duration, frames / context.server.sampleRate,
                        \framesOut, recordFrameBuses[index].index
                    ], \addAfter));
                };
            }, SystemClock);
        });
    }

    // Stop a recording now and keep it: the slot's valid length becomes the
    // frames the record synth reported (its frames bus keeps the last value
    // after the free, and /c_get is answered after the /n_free), then the
    // scratch take is written as for a completed recording. A recording
    // still waiting for its zeroed buffers captured nothing and is simply
    // cancelled; an idle slot is left alone. The reply applies only if no
    // load, record or clear changed the slot before it arrived (slotChanges).
    stopRecordSlot { arg index;
        var synth, started, change;
        if (this.validBuffer(index).not) { ^this };
        synth = recordSynths[index];
        if (synth.isNil) { ^this };
        started = synth.isPlaying;  // read first: Node.free clears it
        this.stopRecording(index);
        change = this.slotChanged(index);
        if (started.not) { ^this };
        stopReplies[index] = change;
        recordFrameBuses[index].get({ arg recorded;
            if (stopReplies[index] == change) { stopReplies[index] = nil };
            if (slotChanges[index] == change) {
                bufferFrames[index] = recorded.round.asInteger.clip(0, buffersL[index].numFrames);
                this.bufferChanged(index);
                this.writeSlot(index, this.scratchPath(index));
            };
        });
    }

    // Empty a slot: it reads 0 frames at once (the voices reading it fade
    // out) and is zeroed after the fade (afterSlotFade)
    clearSlot { arg index;
        var change;
        if (this.validBuffer(index).not) { ^this };
        this.stopRecording(index);
        change = this.slotChanged(index);
        bufferFrames[index] = 0;
        bufferSampleRates[index] = context.server.sampleRate;
        this.bufferChanged(index);
        this.afterSlotFade(index, change, {
            buffersL[index].zero;
            buffersR[index].zero;
        });
    }

    scratchPath { arg index;
        ^scratchDir +/+ ("buf" ++ (index + 1) ++ ".wav")
    }

    // Delete the .part files a write interrupted by a crash or power cut left
    // in scratchDir (scratch takes) and its parent (saveBuffer's
    // <date>-buf<n>.wav, in _path.audio/strata/ on norns); only *.part files,
    // and only those older than stalePartAge. alloc calls this: after a
    // script reload in the same sclang session the previous engine instance
    // may still be writing, and a running write touches its .part with every
    // chunk, so a fresh one is never deleted.
    deleteStaleParts {
        var oldest = Date.getDate.rawSeconds - stalePartAge;
        this.stalePartDirs.do({ arg dir;
            (dir +/+ "*.part").pathMatch.do({ arg partPath;
                // try: the file may be gone since pathMatch (File.mtime then throws)
                var modified = try { File.mtime(partPath) };
                if (modified.notNil and: { modified < oldest }) { File.delete(partPath) };
            });
        });
    }

    // scratchDir and its parent, keeping only absolute directories below the
    // root: an empty or relative scratchDir ("", ".", "scratch/", whose
    // dirname is ".") would glob the working directory, and "" or "/" the
    // root. "~" is expanded; other paths are not standardized, since
    // standardizePath turns "." into the working directory.
    stalePartDirs {
        var dir = scratchDir.asString;
        if (dir.beginsWith("~")) { dir = dir.standardizePath };
        dir = dir.withoutTrailingSlash;
        ^[dir, dir.dirname].select({ arg each;
            each.beginsWith("/") and: { each.withoutTrailingSlash.size > 1 }
        })
    }

    // Write a slot's valid region to path as a stereo 16-bit WAV at the
    // content's sample rate, creating the directory. The server writes each
    // mono buffer to a temporary float file; sclang then interleaves them in
    // chunks (yielding between chunks) into a per-write
    // path.<instanceTag>-<n>.part file and renames it into place, so a
    // reader never sees a half-written file. Each write to a path gets a new
    // generation number: an older write still interleaving when a newer one
    // starts abandons (deleting its .part), so the newest write always wins
    // and two writes never mix. instanceTag keeps another engine instance's
    // files apart. Samples beyond ±1 (a take recorded at a level above 1)
    // are clipped symmetrically to ±int16Peak, never wrapped. Temporary
    // files are deleted in every case. Creates no synth nodes.
    writeSlot { arg index, path;
        var frames = bufferFrames[index];
        var sampleRate = bufferSampleRates[index];
        var generation, tempPaths, partPath;
        if (frames < 1) {
            postln("strata: buffer " ++ (index + 1) ++ " is empty; nothing written to " ++ path);
            ^this
        };
        path = path.standardizePath;
        writeCount = writeCount + 1;
        generation = writeCount;
        writeGenerations[path] = generation;
        tempPaths = ["L", "R"].collect({ arg side;
            Platform.defaultTempDir +/+ "strata-buf%-%-%-%.wav".format(index + 1, instanceTag, generation, side)
        });
        partPath = path ++ "." ++ instanceTag ++ "-" ++ generation ++ ".part";
        buffersL[index].write(tempPaths[0], "wav", "float", frames);
        buffersR[index].write(tempPaths[1], "wav", "float", frames);
        fork({
            var current = { writeGenerations[path] == generation };
            var written;
            context.server.sync;
            written = current.value and: { this.interleaveFiles(tempPaths, partPath, sampleRate, current) };
            tempPaths.do({ arg tempPath; File.delete(tempPath) });
            // no yield between this check and the rename. The newest write
            // forgets its generation whether it succeeded or failed; an
            // abandoned one leaves the newer write's entry alone.
            if (current.value) {
                if (written) {
                    if (("mv -f " ++ partPath.shellQuote ++ " " ++ path.shellQuote).systemCmd == 0) {
                        postln("strata: wrote buffer " ++ (index + 1) ++ " to " ++ path);
                    } {
                        postln("strata: cannot move " ++ partPath ++ " to " ++ path);
                    };
                };
                writeGenerations.removeAt(path);
            };
            if (File.exists(partPath)) { File.delete(partPath) };
        }, SystemClock);
    }

    // Called inside a routine. Returns false (and writes nothing more) as
    // soon as keepGoing is false, i.e. a newer write to the same path began,
    // or when the output cannot be written.
    interleaveFiles { arg sourcePaths, path, sampleRate, keepGoing;
        var chunkFrames = 8192;
        var sources = sourcePaths.collect({ arg sourcePath; SoundFile.openRead(sourcePath) });
        var output, left, right, interleaved, finished = true;
        var peak = int16Peak, negativePeak = int16Peak.neg;

        // File.mkdir throws when the directory cannot be made; openWrite then fails below
        try { File.mkdir(path.dirname) };
        output = if (sources.includes(nil).not) { SoundFile.openWrite(path, "WAV", "int16", 2, sampleRate) };
        if (output.isNil) {
            postln("strata: cannot write " ++ path);
            sources.do({ arg source; if (source.notNil) { source.close } });
            ^false
        };

        left = FloatArray.newClear(chunkFrames);
        right = FloatArray.newClear(chunkFrames);
        while { finished and: { sources[0].readData(left); left.size > 0 } } {
            sources[1].readData(right);
            // A per-frame loop: faster here than an array-level lace, which
            // only descends into Arrays, so each chunk would be converted
            // FloatArray -> Array -> FloatArray (about twice as slow in sclang 3.13)
            interleaved = FloatArray.newClear(left.size * 2);
            left.size.do({ arg frame;
                interleaved[frame * 2] = left[frame].clip(negativePeak, peak);
                interleaved[(frame * 2) + 1] = (right[frame] ? 0).clip(negativePeak, peak);
            });
            output.writeData(interleaved);
            writeChunkWait.wait;
            finished = keepGoing.value;
        };
        output.close;
        sources.do({ arg source; source.close });
        ^finished
    }

    // Gate off a voice's synth trio (each frees itself after its release,
    // even one created in this control block: see openedGate), so later
    // commands to that voice are no-ops. The released synths are kept in
    // releasingSynths until they free, for voiceOn to re-gate. One already
    // releasing under the same key (a grain synth for the previous source
    // that voiceOn left releasing beside the new one) is cut: it would
    // otherwise release untracked, out of reach of the next switch's cut.
    // Only voice and grain synths have the kill fade; a releasing mod synth
    // is always re-gated by voiceOn, never superseded.
    releaseVoice { arg voice;
        if (synths[this.grainKey(voice)].notNil) { releasedGrainSource[voice] = grainSource[voice] };
        [this.voiceKey(voice), this.grainKey(voice), this.modKey(voice)].do({ arg key;
            var synth = synths.removeAt(key), superseded = releasingSynths[voice][key];
            if (synth.notNil) {
                if (superseded.notNil and: { superseded !== synth } and: { key != this.modKey(voice) }) {
                    this.cutVoiceSynth(voice, superseded)
                };
                synth.set(\gate, 0);
                releasingSynths[voice][key] = synth;
            };
        });
    }

    // Set controls on a synth only if it is running
    setSynth { arg key ... controls;
        var synth = synths[key];
        if (synth.notNil) { synth.set(*controls) };
    }

    free {
        // cancelled first, so no recording completes (and writes) on free;
        // a slot change also drops a load or zeroing still waiting for its fade
        numBuffers.do({ arg index; this.stopRecording(index); this.slotChanged(index) });
        synths.do({ arg synth; synth.free });
        synths.clear;  // their onFree must not start them again
        inputSynth.free;
        // also frees voices still in their release phase
        voiceGroup.free;
        processGroup.free;
        granBuses.do({ arg bus; bus.free });
        modBuses.do({ arg bus; bus.free });
        silentBus.free;
        envBuffers.do({ arg buffer; buffer.free });
        buffersL.do({ arg buffer; buffer.free });
        buffersR.do({ arg buffer; buffer.free });
        inputBus.free;
        recordFrameBuses.do({ arg bus; bus.free });
        mainBus.free;
        filterBus.free;
        delayBus.free;
        reverbBus.free;
    }
}
