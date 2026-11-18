// StrataEffects.sc
// The effects area: the master filter (three instances, one on each bus
// it filters before the effects), the delay and the reverb as returns at
// their levels, the master sum and output, their
// commands (setFilter, setReverb, setMasterDrift, setBypass, setShimmer; the
// delay's line, def and setDelay are in StrataDelay.sc), 3.8's shimmer
// (shimmerShift, its four rings, the reverbs' loops) and the chain at the
// tail of the engine group. The bypass frees the delay or the reverb and
// re-creates it when lifted. See docs/notes/engine/effects.md and
// docs/notes/engine/shimmer.md.

+ Engine_Strata {
    // The effects area (order 60)
    strataAreaEffects {
        ^(
            order: 60,
            allocState: { this.areaCall(\allocEffectBuses) },
            addDefs: { this.areaCall(\addEffectDefs); [] },
            addCommands: { this.areaCall(\addEffectCommands) },
            start: { this.areaCall(\startEffectsChain) },
            stop: { this.areaCall(\stopEffects) },
            free: { this.areaCall(\freeEffects) },
            effectKeys: this.effectChainKeys
        )
    }

    // The chain's synths, in signal order. None ends on its own: the engine
    // frees and re-creates the delay and the reverb (setBypass), so messages
    // to them stay plain (setSynth)
    effectChainKeys { ^[\filter, \filterDelay, \filterReverb, \delay, \reverb, \master] }

    // The effects setBypass frees, by its effect number (0 delay, 1 reverb)
    bypassKeys { ^[\delay, \reverb] }

    // How long a bypass waits after setting the node's level to 0 before it
    // frees it: the level's lag (fxMixLag) plus one block
    bypassFadeTime {
        ^this.fxMixLag + (context.server.options.blockSize / context.server.sampleRate)
    }

    allocEffectBuses {
        var state = areaState[\effects];
        // mainBus: every stage's dry output (out); filterBus: it after the
        // master filter; delayBus: the delay's return (at its level);
        // reverbBus: the reverb's. The send buses are the mix area's.
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
        this.allocDelayLine;
        // shimmer's four mono rings (3.8 design §7.4): the delay's left and
        // right, the reverb's left and right. Ordinary RAM (256 KB,
        // fixedBufferBytes counts them), allocated once: bufnums never change
        state[\shimmerRings] = 4.collect({ Buffer.alloc(context.server, this.shimmerRingFrames, 1) });
    }

    // 3.8's shimmer (design §7.4): one shifter, built twice, in the delay's
    // feedback and around each reverb. Its window (s): the two read heads'
    // delays sweep it, so it sets their rate, never memory
    shimmerWindowSeconds { ^0.1 }

    // The read heads trail the write head by at least this many control
    // blocks, so a read never meets a frame the write has not made yet,
    // whichever of BufWr and BufRd the graph runs first in a block (cubic
    // interpolation reads a frame ahead)
    shimmerLeadBlocks { ^2 }

    // The reverbs' loop: its ceiling (a soft clip, -12 dB) and its filters
    // (the shift carries energy out through them)
    shimmerCeiling { ^0.25 }
    shimmerLowpassHz { ^6000 }
    shimmerHighpassHz { ^100 }

    // An effect's two shimmer rings (\delay or \reverb): [left, right]
    shimmerRingsFor { arg key;
        var rings = areaState[\effects][\shimmerRings];
        ^if (key == \delay) { rings.copyRange(0, 1) } { rings.copyRange(2, 3) }
    }

    // Zero an effect's two rings: sent in the bundle that frees its node,
    // so the node a lift creates never reads a ring's old audio (a BufRd,
    // unlike BufDelayC, reads whatever the ring holds)
    emptyShimmerRings { arg key;
        this.shimmerRingsFor(key).do({ arg buffer; context.server.listSendMsg(buffer.zeroMsg) });
    }

    // The pitch shifter (stereo in, stereo out): each channel is written
    // into its ring (bufs: [left, right] mono buffers of shimmerRingFrames)
    // at a Phasor and read by two cubic BufRd heads whose delays sweep
    // shimmerWindowSeconds at the rate that shifts by ratio ((1 - ratio) /
    // window, an LFSaw, the two heads half a cycle apart), each behind the
    // write head by at least shimmerLeadBlocks. Their Hann gains, 0.5 +
    // 0.5 x cos(pi x the first head's saw) and 1 less it, sum to exactly 1
    // and are 0 where a head jumps: a convex mix, never above the ring's
    // peak. BufRd's loop wraps the read frames
    shimmerShift { arg sig, bufs, ratio;
        var frames = this.shimmerRingFrames, window = this.shimmerWindowSeconds;
        var phase = Phasor.ar(0, 1, 0, frames), saws = LFSaw.ar((1 - ratio) / window, [0, 1]);
        var span = window * SampleRate.ir * 0.5, lead = this.shimmerLeadBlocks * BlockSize.ir;
        var reads = phase - ((saws * span) + (span + lead));
        var first = ((saws[0] * pi).cos * 0.5) + 0.5, gains = [first, 1 - first];
        ^sig.collect({ arg channel, index;
            BufWr.ar(channel, bufs[index], phase);
            (BufRd.ar(1, bufs[index], reads, 1, 4) * gains).sum
        })
    }

    // The duck (shimmerLoop). The reverb's output may carry shimmer up to
    // shimmerOverInput times the send's level, plus the halo,
    // shimmerHaloRms: the loop's gain falls linearly from 1 there to 0 at
    // (1 + shimmerDuckRange) times it. The output's level is its RMS (both
    // channels' mean square lagged shimmerHaloLag s, a 60 dB time, as
    // Lag's); the send's is its mean square rising over shimmerSendAttack and
    // falling over shimmerSendRelease (LagUD), so it rides the send's peaks
    // and reads above its RMS (1.35 times on a sine, about 1.6 times on pink
    // noise), and a tail keeps its shimmer while the send falls away, down to
    // the halo
    shimmerOverInput { ^1.5 }
    shimmerHaloRms { ^0.07 }
    shimmerHaloLag { ^0.5 }
    shimmerSendAttack { ^0.05 }
    shimmerSendRelease { ^2 }
    shimmerDuckRange { ^0.25 }

    // A stereo signal's level (both channels), its mean square lagged up
    // and down (60 dB times), at control rate
    shimmerLevel { arg sig, up, down;
        ^A2K.kr(LagUD.ar((sig[0].squared + sig[1].squared) * 0.5, up, down)).sqrt
    }

    // The loop around a reverb (wet: its stereo output, and sent: what the
    // reverb is sent, before the loop, each with its bad values already
    // zeroed, so neither level follower can latch a NaN): shifted,
    // low-passed at shimmerLowpassHz, high-passed at shimmerHighpassHz,
    // clipped softly at shimmerCeiling ((x / ceiling).tanh x ceiling), times
    // amount and times the duck, then any bad value zeroed: what goes back
    // into the reverb's input (an exact 0 at amount 0). The clip bounds what
    // the loop feeds in, but not what comes out: the reverb's own gain is far
    // above 1 at a large size (FreeVerb2 at size 1, damp 0: a loop at the
    // clip drove its output to a peak of 10.8), and a loop leaking a
    // hundredth of the clip sustains it. So the duck holds the output to
    // (1 + shimmerDuckRange) x (shimmerOverInput x the send's level + the
    // halo): about 2.5 times the send's RMS on a sine and 3.0 times on pink
    // noise, plus the halo; a loud send keeps its shimmer in proportion (its
    // output is under that bound unless the loop runs away), a loop that
    // would grow holds there, and once the send stops, at the halo (about -22
    // dB RMS), whatever the reverb's gain, until the amount or the size comes
    // down. Keyed on a level against the send's (2a's first law keyed on the
    // output alone, and ducked every loud return)
    shimmerLoop { arg wet, sent, bufs, amount, ratio;
        var ceiling = this.shimmerCeiling;
        var level = this.shimmerLevel(wet, this.shimmerHaloLag, this.shimmerHaloLag);
        var bound = (this.shimmerLevel(sent, this.shimmerSendAttack, this.shimmerSendRelease) * this.shimmerOverInput)
            + this.shimmerHaloRms;
        var duck = (1 - ((level - bound) / (bound * this.shimmerDuckRange))).clip(0, 1);
        var filtered = HPF.ar(LPF.ar(this.shimmerShift(wet, bufs, ratio), this.shimmerLowpassHz), this.shimmerHighpassHz);
        ^filtered.collect({ arg channel;
            this.zeroBadValues((channel / ceiling).tanh * ceiling * (amount * duck))
        })
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

    // The gain on the master's sum (3.8 design §7.1): 3.7's dry share at
    // its default reverb mix (1 - 0.3), so with the reverb's level at 0.43
    // (0.3 / 0.7) a default start sounds as 3.7.0's and the pre-master tap,
    // the limiter and the saturator see what they saw. (masterAmp's
    // amp=0.7 is another 0.7, at the output.)
    masterSumGain { ^0.7 }

    // The master's input: the filtered dry bus (in), the delay's return
    // (delayIn) and the reverb's (reverbIn), each at its own level, summed
    // and times masterSumGain. The pre-master record tap reads it too.
    masterSum { arg in, delayIn, reverbIn;
        ^(In.ar(in, 2) + In.ar(delayIn, 2) + In.ar(reverbIn, 2)) * this.masterSumGain
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
        // Master multimode filter (multimodeFilter), one on each bus it
        // filters before the effects (dry, delay send, reverb send; never the
        // returns): each filters what goes to one place. Its input first
        // goes through the NaN guard: any NaN or inf (and denormal) sample
        // is replaced with 0 (CheckBadValues), so a
        // voice that blows up can never poison the delay feedback or the
        // reverb for good. mix 0 (the default) passes the input unchanged.
        SynthDef(\strataFilter, {
            arg in, out, freq=5000, res=0.5, filterType=0, mix=0;
            var dry = In.ar(in, 2).collect({ arg channel; this.zeroBadValues(channel) });
            Out.ar(out, this.multimodeFilter(dry, freq.lag(0.05).clip(20, 20000), res.clip(0, 1),
                filterType.round.clip(0, 2), mix.lag(0.05).clip(0, 1)));
        }).add;

        // The delay (StrataDelay.sc), called here, not inside a function
        this.addDelayDef;

        // The standard tier's reverb: FreeVerb2 fully wet on the filtered
        // reverb send plus delayToReverb (0-1, lagged; at 1, the default, the
        // echoes are reverberated as in 3.7, at 0 a voice with no reverb send
        // has dry echoes) of the delay's return (through liftFade, as the
        // delay's), returned at its level (mix). The clips stay literals in
        // the defs: the Lua stub reads setReverb's and setShimmer's limits
        // from them. 3.8's shimmer (design §7.4): its one LocalIn takes the
        // loop (shimmerLoop, on the reverb's two rings shiftL and shiftR,
        // times shimmer 0-1, lagged fxMixLag; shimmerRatio 0.5-4) back into
        // FreeVerb2's input; an exact 0 at shimmer 0, so the def is the one
        // before, bit for bit. The send and the output pass zeroBadValues
        SynthDef(\strataReverb, {
            arg in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0,
                shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2;
            var sent = ((In.ar(in, 2) + (In.ar(delayIn, 2) * delayToReverb.clip(0, 1).lag(this.fxMixLag)))
                * this.liftFade(fadeIn)).collect({ arg channel; this.zeroBadValues(channel) });
            var sig = sent + LocalIn.ar(2);
            var wet = FreeVerb2.ar(sig[0], sig[1], 1, size, damp).collect({ arg channel; this.zeroBadValues(channel) });
            LocalOut.ar(this.shimmerLoop(wet, sent, [shiftL, shiftR], shimmer.clip(0, 1).lag(this.fxMixLag),
                shimmerRatio.clip(0.5, 4)));
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
        // 3.8's shimmer loop (as \strataReverb's) takes channels 8 and 9 of
        // its one LocalIn, widened to ten, and enters before the diffusers;
        // the send and the output pass zeroBadValues
        SynthDef(\strataReverbFDN, {
            arg in, delayIn, out, mix=0.43, size=0.8, damp=0.5, delayToReverb=1, fadeIn=0,
                shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2;
            var room = size.clip(0, 1).lag(0.1), damping = damp.clip(0, 1).lag(0.1) * 0.4;
            var sig = ((In.ar(in, 2) + (In.ar(delayIn, 2) * delayToReverb.clip(0, 1).lag(this.fxMixLag)))
                * this.liftFade(fadeIn)).collect({ arg channel; this.zeroBadValues(channel) });
            var feedbackBase = 0.7 + (0.28 * room), reference = 1378 * SampleDur.ir;
            var drift = [0, 0, LFNoise1.kr(0.31) * 0.0006, 0, 0, 0, LFNoise1.kr(0.43) * 0.0005, 0];
            var lengths = this.fdnLineSeconds * (0.6 + (0.4 * room)) + drift;
            var diffused, feedback, lines, sum, wet;
            feedback = LocalIn.ar(10);
            diffused = (sig + feedback.copyRange(8, 9)).collect({ arg channel, side;
                this.fdnDiffuserSeconds[side].inject(channel, { arg each, time;
                    AllpassN.ar(each, time, time, time * 19)
                })
            });
            lines = 8.collect({ arg index;
                // each line's own maximum (its size-1 length plus the drift's
                // room), so a short line never takes the longest one's memory
                var line = DelayL.ar((diffused[index % 2] * 0.25) + feedback[index], this.fdnLineSeconds[index] + 0.002,
                    lengths[index] - ControlDur.ir);
                OnePole.ar(line, damping)
            });
            sum = lines.sum * (2 / 8);
            wet = [lines[0] + lines[2] + lines[4] + lines[6], lines[1] + lines[3] + lines[5] + lines[7]]
                .collect({ arg channel; this.zeroBadValues(channel) });
            LocalOut.ar(lines.collect({ arg line, index;
                (line - sum) * (feedbackBase ** (lengths[index] / reference))
            }) ++ this.shimmerLoop(wet, sig, [shiftL, shiftR], shimmer.clip(0, 1).lag(this.fxMixLag), shimmerRatio.clip(0.5, 4)));
            Out.ar(out, wet * mix.clip(0, 1).lag(this.fxMixLag));
        }).add;

        // Master output: the sum (masterSum), then drift, the limiter and
        // the soft saturation.
        SynthDef(\strataMaster, {
            arg in, delayIn, reverbIn, out, amp=0.7, drift=0.01;
            var sig = this.masterSum(in, delayIn, reverbIn);
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

        // msg: mix (the return's level), size, damp, delayToReverb. All four
        // kept for a bypassed reverb's next node; while bypassed the level
        // sent stays 0
        this.addCommand(\setReverb, "ffff", { arg msg;
            this.keepEffectControls(\reverb, (mix: msg[1], size: msg[2], damp: msg[3], delayToReverb: msg[4]));
            this.setSynth(\reverb, \mix, msg[1] * this.effectLive(\reverb), \size, msg[2], \damp, msg[3],
                \delayToReverb, msg[4]);
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

        this.addDelayCommands;

        // msg: delayAmount, reverbAmount (0-1), ratio (0.5-4): the delay's
        // feedback blend and the reverb's loop, at one interval (design
        // §7.4). Kept for a bypassed effect's next node (all three, both
        // effects). A non-finite argument is ignored with one line, as
        // setDelay's (fastModValuesFinite); the defs clip the values
        this.addCommand(\setShimmer, "fff", { arg msg;
            if (this.fastModValuesFinite(\setShimmer, [[\delayAmount, msg[1]], [\reverbAmount, msg[2]], [\ratio, msg[3]]])) {
                this.keepEffectControls(\delay, (shimmer: msg[1], shimmerRatio: msg[3]));
                this.keepEffectControls(\reverb, (shimmer: msg[2], shimmerRatio: msg[3]));
                this.setSynth(\delay, \shimmer, msg[1], \shimmerRatio, msg[3]);
                this.setSynth(\reverb, \shimmer, msg[2], \shimmerRatio, msg[3]);
            };
        });

        // msg: effect (0 delay, 1 reverb; others ignored), bypassed (0 or 1)
        this.addCommand(\setBypass, "ii", { arg msg;
            var key = if (msg[1].isInteger) { this.bypassKeys[msg[1]] };
            if (key.notNil and: { [0, 1].includes(msg[2]) }) { this.areaCall(\setEffectBypass, key, msg[2] == 1) };
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

    // Bypass an effect (\delay, \reverb) or lift its bypass. A bypass sets
    // its level to 0 (the node's mix, so its return fades out over its lag
    // and nothing jumps), then frees the node after bypassFadeTime: its CPU
    // and its few KB of the pool come back (the delay's line and the
    // shimmer rings are buffers, kept: the free's bundle empties them,
    // emptyDelayLine, emptyShimmerRings). Lifting it
    // inside that wait cancels the free and restores the level; lifting it
    // later creates the node again in its place, from the kept controls at
    // level 0 and with fadeIn 1 (its input rises over fxMixLag, so the new
    // line records no step: liftFade, #308), then sets the kept level (both
    // in one bundle; the node clips it), which fades in through the lag. A
    // free in flight reaches the server before that creation. Only this
    // frees or creates an effect: a level of 0 only silences.
    setEffectBypass { arg key, bypassed;
        var state = areaState[\effects], token;
        if (state[\bypassed][key] == bypassed) { ^this };
        state[\bypassed][key] = bypassed;
        if (bypassed) {
            token = Object.new;
            state[\pendingFrees][key] = token;
            this.setSynth(key, \mix, 0);
            // from the handler's own time: sclang runs an OSC handler with
            // its thread's time at when it runs, so however late it runs the
            // wait counts from the message above (docs/notes/engine/effects.md)
            SystemClock.sched(this.bypassFadeTime, {
                if (state[\pendingFrees][key] === token) {
                    state[\pendingFrees].removeAt(key);
                    synths.removeAt(key) !? { arg synth;
                        context.server.makeBundle(nil, {
                            synth.free;
                            if (key == \delay) { this.emptyDelayLine };
                            this.emptyShimmerRings(key);
                        });
                    };
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
                this.setSynth(key, \mix, state[\controls][key][\mix]);
            });
        };
    }

    // The reverb node for the tier (high: the FDN), on the filtered reverb
    // send, the delay's return and the reverb's two shimmer rings
    // (shimmerRingsFor), writing reverbBus, from the kept controls (mix:
    // that level instead, when given; fadeIn 1: its input fades in,
    // liftFade)
    startReverb { arg target, addAction, mix, fadeIn = 0;
        var controls = areaState[\effects][\controls][\reverb], rings = this.shimmerRingsFor(\reverb);
        var args = [\in, this.mixBus(\reverbSendPost), \delayIn, delayBus, \out, reverbBus,
            \shiftL, rings[0], \shiftR, rings[1],
            \mix, mix ? controls[\mix], \size, controls[\size], \damp, controls[\damp],
            \delayToReverb, controls[\delayToReverb], \shimmer, controls[\shimmer],
            \shimmerRatio, controls[\shimmerRatio], \fadeIn, fadeIn];
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
        state[\controls][\delay] = this.effectDefaults(\strataDelay, [\time, \feedback, \mix, \pingPong, \frozen,
            \shimmer, \shimmerRatio]);
        state[\controls][\reverb] = this.effectDefaults(\strataReverb, [\mix, \size, \damp, \delayToReverb,
            \shimmer, \shimmerRatio]);

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
            \out, context.out_b], context.xg, \addToTail);
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

    // The chain's buses, the delay's line and shimmer's rings (every area's
    // nodes are gone by now; the rings stay listed, freed)
    freeEffects {
        this.freeDelayLine;
        (areaState[\effects][\shimmerRings] ? []).do({ arg buffer; buffer.free });
        mainBus.free;
        filterBus.free;
        delayBus.free;
        reverbBus.free;
    }
}
