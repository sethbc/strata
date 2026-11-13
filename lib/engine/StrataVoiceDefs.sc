// StrataVoiceDefs.sc
// The seven voice SynthDefs and \strataMod, added by the voices area
// (StrataVoices.sc). See docs/notes/engine/voices.md.

+ Engine_Strata {
    // The block every voice SynthDef shares (#372), from its controls: the
    // accent (voiceAccent), the three crossmod slots read from their buses,
    // the amplitude crossmod (crossmodAmp), the frequency (freq x bend, the
    // MIDI pitchbend ratio, 1 = none, x the note's bend, noteBend, x the
    // frequency crossmod, crossmodFreq) and the level (voiceLevel, the
    // formula the stage applies on the other path, of amp x the note's
    // gain, noteAmp). 3.5's noteBend and noteAmp are lagged noteLag (they
    // move at Lua's 48 Hz) and neutral at 1. Returns (modSig: the amplitude
    // crossmod, modFreq: the frequency, modAmp: the level).
    voiceModulation { arg freq, bend, amp, modBuses, modAmpAmts, modFreqAmts, t_trig, velocity, noteBend, noteAmp;
        var accent = this.voiceAccent(t_trig, velocity);
        var mods = modBuses.collect({ arg bus; In.kr(bus, 1) });
        var modSig = this.crossmodAmp(mods, modAmpAmts);
        var modFreq = freq * bend * noteBend.lag(this.noteLag) * (1 + this.crossmodFreq(mods, modFreqAmts));
        ^(modSig: modSig, modFreq: modFreq, modAmp: this.voiceLevel(amp * noteAmp.lag(this.noteLag), modSig, accent))
    }

    // The own note's park (design 3.5 §3.2): a second envelope with the
    // def's attack and release (each voice def's attackTime and releaseTime,
    // the grain defs' 0.1 s and grainRelease) and no doneAction, multiplied
    // into the output: noteGate 0 takes it down to 0 over the release,
    // noteGate 1 back up over the attack, on the ASR's curve. It starts open
    // (ruling 4): its first level is noteGate's as the synth starts, so at
    // noteGate 1 it is 1 from the first block (exactly, so every def plays
    // 3.4's values), and a synth started at noteGate 0 is parked from its
    // first block. An EnvGen not yet triggered holds noteGate's level, so a
    // noteGate 0 sent in the synth's first block parks it too
    notePark { arg noteGate, attackTime, releaseTime;
        ^EnvGen.kr(Env([noteGate, 1, 0], [attackTime, releaseTime], -4, releaseNode: 1), noteGate)
    }

    // Each voice def's expression control, the one 3.5's per-note main
    // expression (noteMain) moves, and its range: Lua's param spec of that
    // control (VOICE_PARAM_SPECS, lib/params_setup.lua; a docs test compares
    // them). The Resonator's is rq, since its MAIN param is its pitch
    noteMainRanges {
        ^(strataResonator: [\rq, 0.01, 1], strataFM: [\index, 0, 10], strataFolder: [\fold, 0.1, 5], strataSub: [\drift, 0.001, 0.1],
            strataPulse: [\width, 0.05, 0.95], strataKarplus: [\decay, 0.5, 10], strataRing: [\ratio, 0.5, 8])
    }

    // A voice def's expression control as it plays: value (the control) +
    // noteMain (lagged noteLag) x half its range, clipped to the range
    // (noteMainRanges). At noteMain 0 it is value itself (Lua keeps value in
    // the range); every voice def calls it on its own control
    noteMainValue { arg defName, value, noteMain;
        var range = this.noteMainRanges[defName], low = range[1], high = range[2];
        ^(value + (noteMain.lag(this.noteLag) * ((high - low) / 2))).clip(low, high)
    }

    // The accent envelope fired by the retrigger command (pattern steps,
    // MIDI notes); its depth is the velocity sent with the trigger.
    // levelScale is sampled when the envelope starts, so a new velocity
    // never rescales a running accent tail. Every voice SynthDef and the
    // stage use it
    voiceAccent { arg t_trig, velocity;
        ^EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity)
    }

    // The crossmod slots' signals times their amounts, summed slot by slot
    crossmodSum { arg mods, amounts;
        var sum = mods[0] * amounts[0];
        (mods.size - 1).do({ arg index; sum = sum + (mods[index + 1] * amounts[index + 1]) });
        ^sum
    }

    // The amplitude crossmod, clamped to -2..2 against excessive modulation
    // (the voices' and the stage's)
    crossmodAmp { arg mods, amounts;
        ^this.crossmodSum(mods, amounts).clip(-2, 2)
    }

    // The frequency crossmod, clamped to -0.9..2 so the modulated frequency
    // (or a grain's rate) stays positive: at least 0.1 x its own (the
    // voices' and the grain synths')
    crossmodFreq { arg mods, amounts;
        ^this.crossmodSum(mods, amounts).clip(-0.9, 2)
    }

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
        // and multiplies killFade (the engine's cut) into it; see those
        // methods. 3.5's note controls (design 3.5 §3.2, §3.5), each neutral
        // at its default: noteGate (the park, notePark, on the ASR's times),
        // noteBend and noteAmp (voiceModulation), noteMain (the def's
        // expression control, noteMainValue), and attackTime and
        // releaseTime, the ASR's times (each def's 3.4 times by default,
        // clipped to 0.005-30 and 0.01-30 s)
        SynthDef(\strataResonator, {
            arg out, gate=1, freq=100, rq=0.1, noise=0.5,
            mod1=0.1, mod2=0.15, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=4, releaseTime=8;
            var sig, env, noiseSource, modSig, modFreq, modAmp, modulation, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

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
            sig = RLPF.ar(sig, (modFreq * LFNoise1.kr(0.1).range(1, 4)).min(SampleRate.ir * filterCeiling),
                this.noteMainValue(\strataResonator, rq, noteMain));
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
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=5, releaseTime=10;
            var sig, mod, env, carrier, modSig, modFreqVal, modAmp, modulation, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreqVal = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            modFreq = LFNoise1.kr(0.1).range(modFreq * 0.5, modFreq * 2);
            ratio = ratio + LFNoise1.kr(0.08).range(-0.1, 0.1);
            index = this.noteMainValue(\strataFM, index, noteMain) * LFNoise1.kr(0.12).range(0.5, 1.5);

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
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var sig, env, foldAmt, modSig, modFreq, modAmp, modulation, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            foldAmt = this.noteMainValue(\strataFolder, fold, noteMain) * LFNoise1.kr(mod).range(0.5, 1.5);
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
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=8, releaseTime=12;
            var sig, env, modFreq, modSig, modAmp, modulation, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];
            // Slow pitch drift whose depth is the drift amount (0 = none)
            modFreq = modFreq * (1 + (LFNoise1.kr(0.1) * this.noteMainValue(\strataSub, drift, noteMain)));

            sig = SinOsc.ar(modFreq ! 2);
            sig = sig + (SinOsc.ar(modFreq * 0.5) * 0.3);

            Out.ar(out, sig * env * modAmp);
        }).add;

        SynthDef(\strataPulse, {
            arg out, gate=1, freq=120, width=0.5, cutoff=2000,
            res=0.8, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=2, releaseTime=4;
            var sig, env, modSig, modFreq, modAmp, modWidth, modulation, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            // Modulate pulse width with LFO and cross-mod
            modWidth = this.noteMainValue(\strataPulse, width, noteMain) + (LFNoise1.kr(0.15).range(-0.2, 0.2)) + (modSig * 0.3);
            modWidth = modWidth.clip(0.05, 0.95);

            sig = Pulse.ar(modFreq * [1, 1.003], modWidth);

            // Dynamic filter with slow modulation
            cutoff = cutoff * LFNoise1.kr(0.2).range(0.5, 2);
            // res rises with resonance, as the voice filter's and the master
            // filter's do (#314): 0.1 (flat) to 1 (sharpest) plays the
            // filter's rq from 1 down to 0.1, rq = 1.1 - res (Lua's
            // PULSE_RES.mirror, which mirrors older scenes and PSETs: the
            // default 0.8 is rq 0.3, 3.2's default). The clip keeps a stray value
            // from reaching the filter as an rq of 0 or less
            sig = RLPF.ar(sig, cutoff.clip(100, 8000), 1.1 - res.clip(0.1, 1));

            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp * 0.7);
        }).add;

        SynthDef(\strataKarplus, {
            arg out, gate=1, freq=200, decay=4, damping=0.5,
            excite=0.3, amp=0.35, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=0.01, releaseTime=2;
            var sig, env, modSig, modFreq, modAmp, noise, pluck, exciteTrig, modulation, decayTime, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            // Excitation trigger: the free-running exciter plus retrigger
            // commands, so a pattern step actually re-plucks the string as
            // hard as its velocity. T2A is a single-sample impulse, so the
            // velocity only scales that trigger's excitation, never a
            // running signal.
            exciteTrig = Impulse.ar(excite) + (T2A.ar(t_trig) * velocity);

            // Excitation signal - burst of noise
            noise = PinkNoise.ar(1);
            pluck = Decay.ar(exciteTrig, 0.01, noise);

            // Karplus-Strong with variable decay (the expression control's)
            decayTime = this.noteMainValue(\strataKarplus, decay, noteMain);
            sig = Pluck.ar(
                in: pluck,
                trig: exciteTrig,
                maxdelaytime: 0.1,
                delaytime: modFreq.reciprocal,
                decaytime: decayTime,
                coef: damping.linlin(0, 1, 0.1, 0.9)
            );

            // Slight detuning for stereo width
            sig = [sig, Pluck.ar(
                in: pluck,
                trig: exciteTrig,
                maxdelaytime: 0.1,
                delaytime: (modFreq * 1.002).reciprocal,
                decaytime: decayTime,
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
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=5;
            var sig, env, modSig, modFreq, modAmp, car, modulator, ring, modulation, attack, release;

            attack = attackTime.clip(0.005, 30); release = releaseTime.clip(0.01, 30);
            env = EnvGen.kr(Env.asr(attack, 1, release), this.openedGate(gate), doneAction: 2) * this.killFade(kill)
                * this.notePark(noteGate, attack, release);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modSig = modulation[\modSig];
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            // Slowly evolving ratio for inharmonic movement
            ratio = this.noteMainValue(\strataRing, ratio, noteMain) + (LFNoise1.kr(mod).range(-0.1, 0.1));

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
