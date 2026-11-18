// StrataDelay.sc
// The master delay: its line (two mono buffers the effects area allocates
// and frees), its SynthDef, the node's start and the setDelay command. No
// area of its own: the effects area owns the node and its place in the
// chain, and calls these. See docs/notes/engine/effects.md.

+ Engine_Strata {
    // Frames of each of the delay line's two buffers: 2^18 (5.46 s at
    // 48 kHz). BufDelayC reads a power of two (it clips the delay to the
    // largest one under the buffer's size, less a frame), so 5.4 s fits.
    // A literal, so nothing depends on whether 2 ** 18 is an Integer
    delayLineFrames { ^262144 }

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
    // buffers need not: a lifted delay starts empty)
    emptyDelayLine {
        this.delayLine.do({ arg buffer; context.server.listSendMsg(buffer.zeroMsg) });
    }

    addDelayDef {
        // Stereo delay with feedback (LocalIn/LocalOut around BufDelayC, on
        // the two buffers of delayLine: bufL and bufR, which every
        // Synth(\strataDelay) passes, since a bufnum left at 0 is buffer 0),
        // up to 5.4 s, on the filtered delay send (through liftFade: fadeIn 1
        // on a node a bypass lift creates; the feedback path is not faded).
        // It returns the delayed signal only, at its mix (lagged as
        // fxMixBus's readers: m_d D). The time lag avoids zipper noise when
        // the time changes. pingPong (0-1, lagged 50 ms) crossfades the
        // lines' inputs linearly: at 0 each line takes its own channel and
        // its own feedback (3.6's graph, exactly); at 1 the left line takes
        // both channels and the right line's feedback, the right line only
        // the left's, so the repeats alternate sides. It plays what 3.7's
        // DelayC lines played, sample for sample (the same cubic
        // interpolation on a power-of-two line). The time's clip stays a
        // literal: the Lua stub reads setDelay's limit from it.
        SynthDef(\strataDelay, {
            arg in, out, bufL, bufR, time=0.375, feedback=0.4, mix=0, pingPong=0, fadeIn=0;
            var input = In.ar(in, 2) * this.liftFade(fadeIn), returned = LocalIn.ar(2);
            var cross = pingPong.clip(0, 1).lag(0.05), keep = 1 - cross;
            var delayed = BufDelayC.ar([bufL, bufR], [
                input[0] + (input[1] * cross) + (returned[0] * keep) + (returned[1] * cross),
                (input[1] * keep) + (returned[1] * keep) + (returned[0] * cross)
            ], time.lag(0.1).clip(0.01, 5.4));
            LocalOut.ar(delayed * feedback.clip(0, 0.95));
            Out.ar(out, delayed * mix.clip(0, 1).lag(this.fxMixLag));
        }).add;
    }

    addDelayCommands {
        // msg: time (s), feedback, mix, pingPong. Kept for a bypassed
        // delay's next node; while bypassed the mix sent and broadcast stays 0.
        // A non-finite argument is ignored with one line, as 3.4's commands
        // ignore one (fastModValuesFinite): a NaN in the node's lag or
        // feedback loop would stay there until a bypass re-created it
        this.addCommand(\setDelay, "ffff", { arg msg;
            if (this.fastModValuesFinite(\setDelay, [[\time, msg[1]], [\feedback, msg[2]], [\mix, msg[3]],
                [\pingPong, msg[4]]])) {
                this.keepEffectControls(\delay, (time: msg[1], feedback: msg[2], mix: msg[3], pingPong: msg[4]));
                context.server.makeBundle(nil, {
                    this.setSynth(\delay, \time, msg[1], \feedback, msg[2], \mix, msg[3] * this.effectLive(\delay),
                        \pingPong, msg[4]);
                    this.broadcastFxMix;
                });
            };
        });
    }

    // The delay node, on the filtered delay send and the line, writing
    // delayBus, from the kept controls (mix: that mix instead, when given;
    // fadeIn 1: its input fades in, liftFade)
    startDelay { arg target, addAction, mix, fadeIn = 0;
        var controls = areaState[\effects][\controls][\delay];
        synths[\delay] = Synth(\strataDelay, [\in, this.mixBus(\delaySendPost), \out, delayBus,
            \bufL, this.delayLine[0], \bufR, this.delayLine[1],
            \time, controls[\time], \feedback, controls[\feedback], \mix, mix ? controls[\mix],
            \pingPong, controls[\pingPong], \fadeIn, fadeIn], target, addAction);
    }
}
