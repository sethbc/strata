// StrataDelay.sc
// The master delay: its line (two mono buffers the effects area allocates
// and frees), its SynthDef with 3.8's freeze and clear, the node's start
// and its commands (setDelay, setDelayFreeze, clearDelay); its feedback
// carries 3.8's shimmer (shimmerShift, StrataEffects.sc). No area of its
// own: the effects area owns the node and its place in the chain, and
// calls these. See docs/notes/engine/effects.md and
// docs/notes/engine/delay.md (the freeze and the clear).

+ Engine_Strata {
    // Frames of each of the delay line's two buffers: 2^18 (5.46 s at
    // 48 kHz). BufDelayC reads a power of two (it clips the delay to the
    // largest one under the buffer's size, less a frame), so 5.4 s fits.
    // A literal, so nothing depends on whether 2 ** 18 is an Integer
    delayLineFrames { ^262144 }

    // The freeze's ramp (s, 3.8 design §7.3): the loop's gain rises to
    // exactly 1 and the input closes over it, and a release undoes both
    delayFreezeSeconds { ^0.02 }

    // The ramp as Slew's rate (a change of 1 a ramp; Slew reaches its
    // target exactly, where a one-pole lag only approaches it)
    delayFreezeRate { ^1 / this.delayFreezeSeconds }

    // While frozen the ping-pong cross-feed is snapped to 0 or 1: 1 from
    // this up (a cross of 0.5 would make the two lines one)
    delayPingPongSnap { ^0.5 }

    // A clear mutes the feedback and the return for the delay time and this
    // (s, design §7.2): what the line held has gone by then
    delayClearMargin { ^0.005 }

    // The return's fade out at a clear (s), inside the margin: the return
    // falls silent at once, without a step
    delayClearFade { ^0.003 }

    // The feedback's and the return's fade back in as a clear's window ends
    // (s): the line takes what it returns again, and a gain stepped back up
    // in one control block wrote a step into the line, heard one delay time
    // later (as #308's click), and stepped the return itself. Over 20 ms of
    // a raised cosine the fade's largest slope on a full-scale tone down to
    // about 20 Hz stays under the tone's own, so neither has a sample step
    // larger than the steady signal's (the delay area's check)
    delayClearOpenSeconds { ^0.02 }

    // A clear's gain from muted (1, or 0 inside the window): back to 1 over
    // delayClearOpenSeconds and down to 0 at close (per second; a fall of
    // ControlRate.ir is one control block), each as a raised cosine of a
    // linear Slew, so it starts and ends without a corner. Exactly 1 while
    // muted is 1 (Slew starts at its input, and cos(pi) is -1 in single
    // precision): an uncleared delay plays its graph before, bit for bit
    delayClearGain { arg muted, close;
        var ramp = Slew.kr(muted, 1 / this.delayClearOpenSeconds, close);
        ^(1 - cos(ramp * pi)) * 0.5
    }

    // The delay's line: [left, right], allocated once (bufnums never change)
    delayLine { ^areaState[\effects][\delayLine] }

    // From the effects area's allocState (synced before start). Ordinary
    // RAM (2 MB), not the real-time pool: a bypass frees the node's CPU and
    // its few KB only (fixedBufferBytes counts the line)
    allocDelayLine {
        areaState[\effects][\delayLine] = 2.collect({ Buffer.alloc(context.server, this.delayLineFrames, 1) });
    }

    // From the effects area's free, after every stop
    freeDelayLine {
        (areaState[\effects][\delayLine] ? []).do({ arg buffer; buffer.free });
        areaState[\effects][\delayLine] = nil;
    }

    // Zero both buffers: sent in the bundle that frees the delay node, so
    // the node a lift creates finds the line empty (BufDelayC also reads 0
    // for what a new node has not yet written, but a later reader of the
    // buffers need not: a lifted delay starts empty). An empty line has no
    // loop to hold, so the kept frozen goes to 0 with it (#889): a node
    // born frozen would close its input on the empty line and hold a time
    // of 0 (Gate.kr starts closed at 0), and the lift starts it unfrozen
    emptyDelayLine {
        this.delayLine.do({ arg buffer; context.server.listSendMsg(buffer.zeroMsg) });
        this.keepEffectControls(\delay, (frozen: 0));
    }

    addDelayDef {
        // Stereo delay with feedback (LocalIn/LocalOut around BufDelayC, on
        // the two buffers of delayLine: bufL and bufR, which every
        // Synth(\strataDelay) passes, since a bufnum left at 0 is buffer 0),
        // up to 5.4 s, on the filtered delay send (through liftFade: fadeIn 1
        // on a node a bypass lift creates; the feedback path is not faded).
        // It returns the delayed signal only, at its level (mix, lagged
        // fxMixLag, as every send and return), which the master sums. The
        // time lag avoids zipper noise when the time changes. pingPong (0-1,
        // lagged 50 ms) crossfades the lines' inputs linearly: at 0 each line takes its own channel and
        // its own feedback (3.6's graph, exactly); at 1 the left line takes
        // both channels and the right line's feedback, the right line only
        // the left's, so the repeats alternate sides. It plays what 3.7's
        // DelayC lines played, sample for sample (the same cubic
        // interpolation on a power-of-two line). The clips stay literals:
        // the Lua stub reads setDelay's and setDelayFreeze's limits from
        // them.
        // 3.8's freeze (frozen, 0 or 1; design §7.3): hold, a linear ramp
        // over delayFreezeSeconds that reaches 1 exactly, takes the loop's
        // gain to the feedback's max with it (exactly 1) and closes the
        // input (times 1 - hold); the time is held at its value at the
        // freeze (Gate before the lag, so a time sent meanwhile waits for the
        // release and a release glides to it) and, while frozen, rounded to
        // whole samples (a fractional time's interpolation darkens the loop
        // at every pass); the cross-feed moves with hold to pingPong snapped
        // to 0 or 1 (delayPingPongSnap), so the loop keeps its width.
        // Unfrozen (hold 0) every product is the graph before, bit for bit.
        // 3.8's clear (t_clear, a trigger; design §7.2): a Trig1 window of
        // the delay time and delayClearMargin mutes the feedback (at once)
        // and the return (faded over delayClearFade), so what the line held
        // is gone when it ends and the line holds only what came in since;
        // both come back over delayClearOpenSeconds (delayClearGain).
        // 3.8's shimmer (shimmer 0-1, lagged fxMixLag; shimmerRatio 0.5-4;
        // design §7.4): the feedback is a blend of the delayed signal and its
        // shifted copy (shimmerShift, on the delay's two shimmer rings shiftL
        // and shiftR, which every Synth(\strataDelay) passes as it passes its
        // line), so each repeat steps by the ratio and the loop's gain is
        // still the feedback's (the shifter's two heads are a convex mix);
        // the return stays the delayed signal. At shimmer 0 the blend adds an
        // exact 0 (the rings hold finite values): the graph before, bit for
        // bit
        SynthDef(\strataDelay, {
            arg in, out, bufL, bufR, time=0.375, feedback=0.4, mix=0, pingPong=0, fadeIn=0, frozen=0, t_clear=0,
                shiftL=0, shiftR=0, shimmer=0, shimmerRatio=2;
            var hold = Slew.kr(frozen.clip(0, 1), this.delayFreezeRate, this.delayFreezeRate);
            var isFrozen = frozen.clip(0, 1) > 0;
            var input = In.ar(in, 2) * this.liftFade(fadeIn) * (1 - hold), returned = LocalIn.ar(2);
            var held = Gate.kr(time.clip(0.01, 5.4), 1 - isFrozen).lag(0.1);
            var delayTime = Select.kr(isFrozen, [held, (held * SampleRate.ir).round / SampleRate.ir]);
            var lagged = pingPong.clip(0, 1).lag(0.05);
            var snapped = (pingPong.clip(0, 1) >= this.delayPingPongSnap).lag(0.05);
            var cross = lagged + ((snapped - lagged) * hold), keep = 1 - cross;
            var muted = 1 - Trig1.kr(t_clear, delayTime + this.delayClearMargin);
            var delayed = BufDelayC.ar([bufL, bufR], [
                input[0] + (input[1] * cross) + (returned[0] * keep) + (returned[1] * cross),
                (input[1] * keep) + (returned[1] * keep) + (returned[0] * cross)
            ], delayTime);
            var shifted = this.shimmerShift(delayed, [shiftL, shiftR], shimmerRatio.clip(0.5, 4));
            var fed = delayed + ((shifted - delayed) * shimmer.clip(0, 1).lag(this.fxMixLag));
            LocalOut.ar(fed * feedback.clip(0, 0.95).max(hold) * this.delayClearGain(muted, ControlRate.ir));
            Out.ar(out, delayed * this.delayClearGain(muted, 1 / this.delayClearFade) * mix.clip(0, 1).lag(this.fxMixLag));
        }).add;
    }

    addDelayCommands {
        // msg: time (s), feedback, mix (the return's level), pingPong. Kept
        // for a bypassed delay's next node; while bypassed the level sent
        // stays 0.
        // A non-finite argument is ignored with one line, as 3.4's commands
        // ignore one (fastModValuesFinite): a NaN in the node's lag or
        // feedback loop would stay there until a bypass re-created it
        this.addCommand(\setDelay, "ffff", { arg msg;
            if (this.fastModValuesFinite(\setDelay, [[\time, msg[1]], [\feedback, msg[2]], [\mix, msg[3]],
                [\pingPong, msg[4]]])) {
                this.keepEffectControls(\delay, (time: msg[1], feedback: msg[2], mix: msg[3], pingPong: msg[4]));
                this.setSynth(\delay, \time, msg[1], \feedback, msg[2], \mix, msg[3] * this.effectLive(\delay),
                    \pingPong, msg[4]);
            };
        });

        // msg: frozen, 0 (release) or 1 (freeze): kept and set on the node.
        // With no node (a bypass has freed it, emptying its line) 0 is
        // kept, so a lift never starts a frozen node on an empty line
        // (#889; Lua also releases a freeze before it bypasses and refuses
        // one while bypassed: docs/notes/engine/delay.md, Freeze by bypass).
        // Another value is ignored with one line
        this.addCommand(\setDelayFreeze, "i", { arg msg;
            if (this.fastModIndicesValid(\setDelayFreeze, [[\frozen, msg[1], 1]])) {
                this.keepEffectControls(\delay, (frozen: if (synths[\delay].notNil) { msg[1] } { 0 }));
                this.setSynth(\delay, \frozen, msg[1]);
            };
        });

        // No argument: the running delay's clear window opens (t_clear).
        // Never kept, and nothing while the delay is bypassed (in its fade
        // too: a lifted delay starts empty anyway)
        this.addCommand(\clearDelay, "", { arg msg;
            if (this.effectLive(\delay) == 1) { this.setSynth(\delay, \t_clear, 1); };
        });
    }

    // The delay node, on the filtered delay send, the line and the delay's
    // two shimmer rings (shimmerRingsFor), writing delayBus, from the kept
    // controls, frozen and shimmer's two among them (mix: that mix instead,
    // when given; fadeIn 1: its input fades in, liftFade)
    startDelay { arg target, addAction, mix, fadeIn = 0;
        var controls = areaState[\effects][\controls][\delay], rings = this.shimmerRingsFor(\delay);
        synths[\delay] = Synth(\strataDelay, [\in, this.mixBus(\delaySendPost), \out, delayBus,
            \bufL, this.delayLine[0], \bufR, this.delayLine[1], \shiftL, rings[0], \shiftR, rings[1],
            \time, controls[\time], \feedback, controls[\feedback], \mix, mix ? controls[\mix],
            \pingPong, controls[\pingPong], \frozen, controls[\frozen], \shimmer, controls[\shimmer],
            \shimmerRatio, controls[\shimmerRatio], \fadeIn, fadeIn], target, addAction);
    }
}
