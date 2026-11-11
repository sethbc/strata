// StrataEffects.sc
// The effects area: the master filter (three instances, one per mix bus),
// the delay and the reverb as returns, the master sum and output, their
// commands (setFilter, setDelay, setReverb, setMasterDrift, setBypass) and
// the chain at the tail of the engine group. The bypass frees the delay or
// the reverb and re-creates it when lifted. See docs/notes/engine/effects.md.

+ Engine_Strata {
    // The effects area (order 60)
    strataAreaEffects {
        ^(
            order: 60,
            allocState: { this.allocEffectBuses },
            addDefs: { this.addEffectDefs; [] },
            addCommands: { this.addEffectCommands },
            start: { this.startEffectsChain },
            stop: { this.stopEffects },
            free: { this.freeEffects },
            effectKeys: this.effectChainKeys
        )
    }

    // The chain's synths, in signal order. None ends on its own: the engine
    // frees and re-creates the delay and the reverb (setBypass), so messages
    // to them stay plain (setSynth)
    effectChainKeys { ^[\filter, \filterDelay, \filterReverb, \delay, \reverb, \master] }

    // The effects setBypass frees, by its effect number (0 delay, 1 reverb)
    bypassKeys { ^[\delay, \reverb] }

    // How long a bypass waits after broadcasting the mix as 0 before it
    // frees the node: the readers' lag (fxMixLag) plus one block
    bypassFadeTime {
        ^this.fxMixLag + (context.server.options.blockSize / context.server.sampleRate)
    }

    allocEffectBuses {
        var state = areaState[\effects];
        // mainBus: the dry part of every grain synth's output (out); filterBus:
        // it after the master filter; delayBus: the delay's return (m_d D);
        // reverbBus: the reverb's (m_r R). The send buses are the mix area's.
        mainBus = Bus.audio(context.server, 2);
        filterBus = Bus.audio(context.server, 2);
        delayBus = Bus.audio(context.server, 2);
        reverbBus = Bus.audio(context.server, 2);
        // The delay's and reverb's last controls (setDelay, setReverb), kept
        // through a bypass for the node that lifting it creates; whether each
        // is bypassed; and the token of a bypass waiting to free its node
        state[\controls] = IdentityDictionary.new;
        state[\bypassed] = IdentityDictionary[\delay -> false, \reverb -> false];
        state[\pendingFrees] = IdentityDictionary.new;
    }

    // The master filter's design, shared with the voice filter
    // (voiceFilter): 0 lowpass, 1 highpass, 2 bandpass at rq 1 - res x 0.95
    // (res 0-1), wet crossfading sig (0) to filtered (1). A type change
    // crossfades over 20 ms: each type is weighted by a lagged "this is the
    // type" (the weights sum to 1 once settled), so switching never steps
    // the output. Never compare a UGen with == (object identity):
    // BinaryOpUGen('==', ...). type is a whole number (any other weights
    // every type 0: the output is sig x (1 - wet)).
    // Two filters run, RLPF and BPF. The highpass is sig - lowpass -
    // bandpass: RLPF, BPF and RHPF share their poles and their numerators
    // add up to the denominator, so the three outputs add up to the input
    // (to -140 dB in single precision) and the difference is RHPF's
    // response. RHPF itself is not used: its state grows as 1 / cutoff
    // squared, and a cutoff that jumps up reads that state through the new
    // coefficients as a burst far above the signal (#305); the lowpass's
    // state is bounded by the signal. So with the type weights w0 (low),
    // w1 (high) and w2 (band):
    //   filtered = low x (w0 - w1) + band x (w2 - w1) + sig x w1
    // grouped so that a settled lowpass or bandpass is RLPF or BPF plus
    // exact zeros, bit for bit. The cutoff goes through riseLimitedCutoff.
    multimodeFilter { arg sig, cutoff, res, type, wet;
        var rq = 1 - (res * 0.95);
        var freq = this.riseLimitedCutoff(cutoff);
        var weights = 3.collect({ arg index; BinaryOpUGen('==', type, index).lag(0.02) });
        var low = RLPF.ar(sig, freq, rq), band = BPF.ar(sig, freq, rq);
        var filtered = (low * (weights[0] - weights[1])) + (band * (weights[2] - weights[1])) + (sig * weights[1]);
        ^sig + ((filtered - sig) * wet)
    }

    // How fast a filter's cutoff may rise, in octaves per second: the whole
    // range (20 Hz to 20 kHz) takes 0.1 s
    cutoffRiseRate { ^100 }

    // A cutoff (control rate, Hz, already lagged and clipped by its
    // SynthDef) held under a ceiling that rises at most cutoffRiseRate
    // octaves a second and falls at once (Slew starts at its input, so a
    // new node starts at its cutoff). A cutoff that falls, holds, or rises
    // more slowly passes unchanged, bit for bit: the ceiling sits 0.01 %
    // above the slewed value, so the rounding of log2 and 2 ** never makes
    // it the smaller of the two. A faster rise glides at that rate. The
    // bandpass's state (and the lowpass's, less) is also larger at a low
    // cutoff, and the rate bounds what a jump up reads from it (#305). (The
    // parentheses around 2 ** matter: sclang reads binary operators left to
    // right.)
    riseLimitedCutoff { arg cutoff;
        ^cutoff.min((2 ** Slew.kr(cutoff.log2, this.cutoffRiseRate, 1e6)) * 1.0001)
    }

    // The master's input: the filtered dry bus (in), the delay's return
    // (delayIn, m_d D) through the reverb's dry share (1 - m_r, from fxMix,
    // lagged as every mix reader) and the reverb's return (reverbIn, m_r R):
    // dry + m_d (1 - m_r) D + m_r R, which at sends of 1 is 3.0's chain
    masterSum { arg in, delayIn, reverbIn, fxMix;
        // (the engine broadcasts mixes already clipped to 0-1: liveMix)
        var reverbMix = In.kr(fxMix + 1, 1).lag(this.fxMixLag);
        ^In.ar(in, 2) + (In.ar(delayIn, 2) * (1 - reverbMix)) + In.ar(reverbIn, 2)
    }

    // The gain on the input of a delay or reverb node: 1 from its first
    // sample (fadeIn 0: the nodes the engine starts with, and every other),
    // or a linear rise from 0 to 1 over fxMixLag (fadeIn 1: a node a bypass
    // lift creates). The sends carry audio all the time, so a new, empty
    // line that took its input whole would record a step and play it one
    // delay time later as a click (#308). Read once, as the node starts.
    // An audio-rate Line: on SuperCollider 3.13 a control-rate Line's first
    // block is already one step up, which leaves a step of 2.7 % of the
    // signal at the node's first sample.
    liftFade { arg fadeIn;
        ^Line.ar(1 - fadeIn, 1, this.fxMixLag)
    }

    // The FDN's eight line lengths (s): primes of samples at 48 kHz, about
    // 31-107 ms, at size 1 (lines scale by 0.6 + 0.4 x size)
    fdnLineSeconds { ^[1487, 1759, 2063, 2543, 2927, 3499, 4271, 5119] / 48000 }

    // The FDN's input diffusers (s), per channel: four allpasses of 5-30 ms
    fdnDiffuserSeconds { ^[[0.0053, 0.0079, 0.0131, 0.0239], [0.0061, 0.0089, 0.0149, 0.0271]] }

    addEffectDefs {
        // Master multimode filter (multimodeFilter), one on each mix bus
        // (dry, delay send, reverb send): the filter is linear, so filtering
        // the three parts equals filtering their sum, as 3.0 did before the
        // delay. Its input first goes through the NaN guard: any NaN or inf
        // (and denormal) sample is replaced with 0 (CheckBadValues), so a
        // voice that blows up can never poison the delay feedback or the
        // reverb for good. mix 0 (the default) passes the input unchanged.
        SynthDef(\strataFilter, {
            arg in, out, freq=5000, res=0.5, filterType=0, mix=0;
            var dry = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel) });
            Out.ar(out, this.multimodeFilter(dry, freq.lag(0.05).clip(20, 20000), res.clip(0, 1),
                filterType.round.clip(0, 2), mix.lag(0.05).clip(0, 1)));
        }).add;

        // Stereo delay with feedback (LocalIn/LocalOut around DelayC, max 2 s),
        // on the filtered delay send (through liftFade: fadeIn 1 on a node a
        // bypass lift creates; the feedback path is not faded). It returns
        // the delayed signal only, at its mix (lagged as fxMixBus's readers:
        // m_d D). The time lag avoids zipper noise when the time changes.
        SynthDef(\strataDelay, {
            arg in, out, time=0.375, feedback=0.4, mix=0, fadeIn=0;
            var delayed = DelayC.ar((In.ar(in, 2) * this.liftFade(fadeIn)) + LocalIn.ar(2), 2, time.lag(0.1).clip(0.01, 2));
            LocalOut.ar(delayed * feedback.clip(0, 0.95));
            Out.ar(out, delayed * mix.clip(0, 1).lag(this.fxMixLag));
        }).add;

        // The standard tier's reverb: FreeVerb2 fully wet on the filtered
        // reverb send plus the delay's return (through liftFade, as the
        // delay's), returned at its mix (m_r R)
        SynthDef(\strataReverb, {
            arg in, delayIn, out, mix=0.3, size=0.8, damp=0.5, fadeIn=0;
            var sig = (In.ar(in, 2) + In.ar(delayIn, 2)) * this.liftFade(fadeIn);
            var wet = FreeVerb2.ar(sig[0], sig[1], 1, size, damp);
            Out.ar(out, wet * mix.clip(0, 1).lag(this.fxMixLag));
        }).add;

        // The high tier's reverb, a feedback delay network of core UGens, with
        // the same input (through liftFade), controls and return as
        // \strataReverb: four allpass diffusers per channel, eight DelayL
        // lines (fdnLineSeconds, scaled by size; the LocalIn/LocalOut block
        // is taken off each) mixed by a Householder matrix (lossless), each
        // damped by a OnePole (damp, as FreeVerb's per pass) and fed back at
        // a gain that gives FreeVerb's decay per second at size (0.7 + 0.28 x
        // size per 1378 samples, FreeVerb's mean comb). Two lines' lengths
        // drift slowly (LFNoise1) against metallic ringing. Left and right
        // are tapped from alternate lines. Every delay is sized by a constant.
        SynthDef(\strataReverbFDN, {
            arg in, delayIn, out, mix=0.3, size=0.8, damp=0.5, fadeIn=0;
            var room = size.clip(0, 1).lag(0.1), damping = damp.clip(0, 1).lag(0.1) * 0.4;
            var sig = (In.ar(in, 2) + In.ar(delayIn, 2)) * this.liftFade(fadeIn);
            var feedbackBase = 0.7 + (0.28 * room), reference = 1378 * SampleDur.ir;
            var drift = [0, 0, LFNoise1.kr(0.31) * 0.0006, 0, 0, 0, LFNoise1.kr(0.43) * 0.0005, 0];
            var lengths = this.fdnLineSeconds * (0.6 + (0.4 * room)) + drift;
            var diffused, feedback, lines, sum, wet;
            diffused = sig.collect({ arg channel, side;
                this.fdnDiffuserSeconds[side].inject(channel, { arg each, time;
                    AllpassN.ar(each, time, time, time * 19)
                })
            });
            feedback = LocalIn.ar(8);
            lines = 8.collect({ arg index;
                // each line's own maximum (its size-1 length plus the drift's
                // room), so a short line never takes the longest one's memory
                var line = DelayL.ar((diffused[index % 2] * 0.25) + feedback[index], this.fdnLineSeconds[index] + 0.002,
                    lengths[index] - ControlDur.ir);
                OnePole.ar(line, damping)
            });
            sum = lines.sum * (2 / 8);
            LocalOut.ar(lines.collect({ arg line, index;
                (line - sum) * (feedbackBase ** (lengths[index] / reference))
            }));
            wet = [lines[0] + lines[2] + lines[4] + lines[6], lines[1] + lines[3] + lines[5] + lines[7]];
            Out.ar(out, wet * mix.clip(0, 1).lag(this.fxMixLag));
        }).add;

        // Master output: the mix (masterSum), then drift, the limiter and
        // the soft saturation.
        SynthDef(\strataMaster, {
            arg in, delayIn, reverbIn, fxMix, out, amp=0.7, drift=0.01;
            var sig = this.masterSum(in, delayIn, reverbIn, fxMix);
            var driftMod;

            // Tape-style pitch drift at a fixed slow rate; drift sets the depth
            // (0 = no drift, default 0.01 = +/-0.2%, max 0.1 = +/-2%). The
            // shifter overlaps four grains of its window: no time dispersion
            // (a random delay per grain made every steady tone flutter by
            // 25-30 dB, at drift 0 too, and took 5.7 dB off everything
            // above 1 kHz: #306), and a 10 ms window, so the grains' delays
            // differ by too little to comb the audible range at the default
            // drift (the first notch is at 2 / ((ratio - 1) x window) Hz).
            // At drift 0 the shifter is a two-sample delay, exactly.
            driftMod = 1 + (LFNoise1.kr(0.2) * drift * 0.2);
            sig = PitchShift.ar(sig, 0.01, driftMod, 0, 0);

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

        // msg: mix, size, damp. Kept for a bypassed reverb's next node; while
        // bypassed the mix sent and broadcast stays 0
        this.addCommand(\setReverb, "fff", { arg msg;
            this.keepEffectControls(\reverb, (mix: msg[1], size: msg[2], damp: msg[3]));
            context.server.makeBundle(nil, {
                this.setSynth(\reverb, \mix, msg[1] * this.effectLive(\reverb), \size, msg[2], \damp, msg[3]);
                this.broadcastFxMix;
            });
        });

        // msg: freq, res, filterType (0 lowpass, 1 highpass, 2 bandpass), mix;
        // the same on all three master filters, in one bundle (the Lua stub
        // reads the FX controls from the literal \filter line)
        this.addCommand(\setFilter, "ffif", { arg msg;
            context.server.makeBundle(nil, {
                this.setSynth(\filter, \freq, msg[1], \res, msg[2], \filterType, msg[3], \mix, msg[4]);
                [\filterDelay, \filterReverb].do({ arg key;
                    this.setSynth(key, \freq, msg[1], \res, msg[2], \filterType, msg[3], \mix, msg[4])
                });
            });
        });

        // msg: time (s), feedback, mix. Kept for a bypassed delay's next
        // node; while bypassed the mix sent and broadcast stays 0
        this.addCommand(\setDelay, "fff", { arg msg;
            this.keepEffectControls(\delay, (time: msg[1], feedback: msg[2], mix: msg[3]));
            context.server.makeBundle(nil, {
                this.setSynth(\delay, \time, msg[1], \feedback, msg[2], \mix, msg[3] * this.effectLive(\delay));
                this.broadcastFxMix;
            });
        });

        // msg: effect (0 delay, 1 reverb; others ignored), bypassed (0 or 1)
        this.addCommand(\setBypass, "ii", { arg msg;
            var key = if (msg[1].isInteger) { this.bypassKeys[msg[1]] };
            if (key.notNil and: { [0, 1].includes(msg[2]) }) { this.setEffectBypass(key, msg[2] == 1) };
        });
    }

    // Keep an effect's controls (an Event of control -> value)
    keepEffectControls { arg key, controls;
        areaState[\effects][\controls][key].putAll(controls);
    }

    // 1 while the effect runs, 0 while it is bypassed
    effectLive { arg key;
        ^if (areaState[\effects][\bypassed][key]) { 0 } { 1 }
    }

    // The mix an effect's readers use: its kept mix, 0 while bypassed
    liveMix { arg key;
        ^areaState[\effects][\controls][key][\mix].clip(0, 1) * this.effectLive(key)
    }

    // Broadcast the delay and reverb mixes on fxMix (voiceOutput's and the
    // master's readers). Inside the bundle that sets the nodes' own mixes,
    // so every reader moves in the same block
    broadcastFxMix {
        this.mixBus(\fxMix).setn([this.liveMix(\delay), this.liveMix(\reverb)]);
    }

    // Bypass an effect (\delay, \reverb) or lift its bypass. A bypass sets
    // its mix and the broadcast mix to 0 (so the dry gains return to full
    // and nothing jumps), then frees the node after bypassFadeTime: its CPU
    // and its real-time memory (the delay's 1 MB) come back. Lifting it
    // inside that wait cancels the free and restores the mix; lifting it
    // later creates the node again in its place, from the kept controls at
    // mix 0 and with fadeIn 1 (its input rises over fxMixLag, so the new
    // line records no step: liftFade, #308), then sets the kept mix (both in
    // one bundle), which fades in through the lag. A free in flight reaches
    // the server before that creation. Only this frees or creates an effect:
    // a mix of 0 only silences.
    setEffectBypass { arg key, bypassed;
        var state = areaState[\effects], token;
        if (state[\bypassed][key] == bypassed) { ^this };
        state[\bypassed][key] = bypassed;
        if (bypassed) {
            token = Object.new;
            state[\pendingFrees][key] = token;
            context.server.makeBundle(nil, {
                this.setSynth(key, \mix, 0);
                this.broadcastFxMix;
            });
            SystemClock.sched(this.bypassFadeTime, {
                if (state[\pendingFrees][key] === token) {
                    state[\pendingFrees].removeAt(key);
                    synths.removeAt(key) !? { arg synth; synth.free };
                };
                nil
            });
        } {
            // the free still waiting (nil once it has been sent)
            token = state[\pendingFrees].removeAt(key);
            context.server.makeBundle(nil, {
                if (token.isNil) {
                    if (key == \delay) { this.startDelay(synths[\filterReverb], \addAfter, 0, 1) } {
                        this.startReverb(synths[\master], \addBefore, 0, 1) };
                };
                this.setSynth(key, \mix, this.liveMix(key));
                this.broadcastFxMix;
            });
        };
    }

    // The delay node, on the filtered delay send, writing delayBus, from
    // the kept controls (mix: that mix instead, when given; fadeIn 1: its
    // input fades in, liftFade)
    startDelay { arg target, addAction, mix, fadeIn = 0;
        var controls = areaState[\effects][\controls][\delay];
        synths[\delay] = Synth(\strataDelay, [\in, this.mixBus(\delaySendPost), \out, delayBus,
            \time, controls[\time], \feedback, controls[\feedback], \mix, mix ? controls[\mix],
            \fadeIn, fadeIn], target, addAction);
    }

    // The reverb node for the tier (high: the FDN), on the filtered reverb
    // send and the delay's return, writing reverbBus, from the kept controls
    // (mix: that mix instead, when given; fadeIn 1: its input fades in,
    // liftFade)
    startReverb { arg target, addAction, mix, fadeIn = 0;
        var controls = areaState[\effects][\controls][\reverb];
        var args = [\in, this.mixBus(\reverbSendPost), \delayIn, delayBus, \out, reverbBus,
            \mix, mix ? controls[\mix], \size, controls[\size], \damp, controls[\damp], \fadeIn, fadeIn];
        if (tier == \high) {
            synths[\reverb] = Synth(\strataReverbFDN, args, target, addAction);
        } {
            synths[\reverb] = Synth(\strataReverb, args, target, addAction);
        };
    }

    // A SynthDef's default for each of the named controls, as an Event
    effectDefaults { arg defName, names;
        var controls = SynthDescLib.global.at(defName).controls, defaults = ();
        names.do({ arg name; defaults[name] = controls.detect({ arg each; each.name == name }).defaultValue });
        ^defaults
    }

    startEffectsChain {
        var state = areaState[\effects];
        // the kept controls start at the SynthDefs' defaults (the Lua params'
        // defaults: the script never bangs its params)
        state[\controls][\delay] = this.effectDefaults(\strataDelay, [\time, \feedback, \mix]);
        state[\controls][\reverb] = this.effectDefaults(\strataReverb, [\mix, \size, \damp]);
        this.broadcastFxMix;

        // The chain at the tail of the engine group, in signal order: the
        // three master filters (dry, delay send, reverb send), the delay, the
        // reverb, the master
        synths[\filter] = Synth(\strataFilter, [\in, mainBus, \out, filterBus], context.xg, \addToTail);
        synths[\filterDelay] = Synth(\strataFilter, [\in, this.mixBus(\delaySend), \out, this.mixBus(\delaySendPost)],
            context.xg, \addToTail);
        synths[\filterReverb] = Synth(\strataFilter, [\in, this.mixBus(\reverbSend), \out, this.mixBus(\reverbSendPost)],
            context.xg, \addToTail);
        this.startDelay(context.xg, \addToTail);
        this.startReverb(context.xg, \addToTail);
        synths[\master] = Synth(\strataMaster, [\in, filterBus, \delayIn, delayBus, \reverbIn, reverbBus,
            \fxMix, this.mixBus(\fxMix), \out, context.out_b], context.xg, \addToTail);
    }

    // The chain's synths (quietly, as the voices' are freed); a bypass
    // waiting to free a node frees nothing after this
    stopEffects {
        areaState[\effects][\pendingFrees].clear;
        this.effectChainKeys.do({ arg key;
            var synth = synths.removeAt(key);
            if (synth.notNil) { this.sendToSynth(synth.freeMsg); synth.free(false) };
        });
    }

    // The chain's buses (every area's nodes are gone by now)
    freeEffects {
        mainBus.free;
        filterBus.free;
        delayBus.free;
        reverbBus.free;
    }
}
