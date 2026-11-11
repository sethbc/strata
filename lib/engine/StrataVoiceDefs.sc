// StrataVoiceDefs.sc
// The seven voice SynthDefs and \strataMod, added by the voices area
// (StrataVoices.sc). See docs/notes/engine/voices.md.

+ Engine_Strata {
    addVoiceDefs {
        // Modulation output synth - outputs envelope follower signal for cross-mod.
        // A NaN or inf on the voice bus (a voice that blows up) never reaches
        // the mod bus: it would spread to every voice this one modulates and,
        // through their own mod synths, on, for good. The input is guarded
        // before the follower (whose state a NaN would poison, so it follows
        // again once the bad values stop) and the output once more; normal
        // values pass both guards unchanged (zeroBadValues).
        SynthDef(\strataMod, {
            arg in, out, gate=1, speed=10;
            var sig, env, modSig;

            env = EnvGen.kr(Env.asr(0.1, 1, 0.5), this.openedGate(gate), doneAction: 2);
            sig = this.zeroBadValues(In.ar(in, 2).sum);  // Sum stereo to mono

            // Envelope follower with smoothing
            modSig = Amplitude.kr(sig, 0.01, 0.1);
            // Add slow LFO component for more movement
            modSig = (modSig * 0.7) + (LFNoise1.kr(speed).range(0, 0.3));
            modSig = this.zeroBadValues(modSig.lag(0.05));  // Smooth the output

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
            // The cutoff is kept below Nyquist: above it RLPF's poles leave
            // the unit circle (high freq, frequency crossmod, bend and the
            // noise factor can get there) and the NaN would kill the output
            sig = RLPF.ar(sig, (modFreq * LFNoise1.kr(0.1).range(1, 4)).min(SampleRate.ir * filterCeiling), rq);
            // The resonator bank driven by noise peaks about 50x higher
            // than the other voices (at 20 Hz with noise 1, thousands):
            // resonatorGain brings its defaults into their range, and a
            // limiter at voiceCeiling (mono, before the pan) bounds the
            // reachable extremes, accents and crossmod included. At the
            // defaults it only catches the hottest moments (the cutoff's
            // slow noise factor near 4, full-velocity accents), where the
            // master limiter used to act on every sample. Its lookahead is
            // short (voiceLimiterLookahead): Limiter delays its output by
            // twice it, so its default would put the Resonator 20 ms behind
            // the other voices and their accents
            sig = Limiter.ar(sig * resonatorGain * modAmp, voiceCeiling, voiceLimiterLookahead);
            sig = Pan2.ar(sig, pan);

            Out.ar(out, sig * env);
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
            // at a ratio near 1 or 0.5 an FM sideband lands at 0 Hz and, as the
            // ratio wanders, moves a few Hz either way: taken out here, before
            // the voice bus (subsonicBlock, #309)
            carrier = this.subsonicBlock(SinOsc.ar(modFreqVal + mod));

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
            // at a ratio near 1 the difference tone is at 0 Hz (subsonicBlock, #309)
            ring = this.subsonicBlock(car * modulator);

            // Add some of the original carrier for warmth
            sig = ring + (car * brightness * 0.3);

            // Gentle filtering
            sig = LPF.ar(sig, 3000 + (LFNoise1.kr(0.1) * 1000));
            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp);
        }).add;
    }
}
