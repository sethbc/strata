// StrataReverb.sc
// The high tier's reverb lines and its freeze (3.9, #819): the FDN's eight
// lines as sixteen mono buffers the effects area allocates and frees (two a
// line: the interpolated read's and the whole-sample read's), and their
// zeroing at a bypass. The def, \strataReverbFDN, is in StrataEffects.sc
// with the standard tier's. No area of its own: the effects area owns the
// node and its place in the chain, and calls these. See
// docs/notes/engine/reverb.md.

+ Engine_Strata {
    // Frames of each line's two buffers, in line order: the power of two
    // above each line's longest delay (its size-1 length, the drift's room
    // and a block), the memory each line's DelayL took of the pool before.
    // BufDelayL and BufDelayN read a power of two. Literals, so nothing
    // depends on how a power is computed
    fdnLineFrames { ^[2048, 2048, 4096, 4096, 4096, 4096, 8192, 8192] }

    // The freeze's ramp (s): the delay's (3.9 design, call 5). The loop's
    // gains rise to exactly 1 and the input closes over it, and a release
    // undoes both
    reverbFreezeSeconds { ^0.02 }

    // The ramp as Slew's rate (a change of 1 a ramp; Slew reaches its
    // target exactly, where a one-pole lag only approaches it)
    reverbFreezeRate { ^1 / this.reverbFreezeSeconds }

    // How fast a held drift glides back to the drift after a release (s of
    // line length a second; 3.8's package 3a): faster than either drift
    // moves (at most about 0.0004 s a second), so it meets it
    fdnDriftReturnRate { ^0.002 }

    // A line's drift (control rate) held while frozen (open 0) at its value
    // at the close; after the release (open 1 again) the gap to the drift
    // closes at no more than fdnDriftReturnRate, so the line's length glides
    // back rather than jumping. Exactly drift whenever it has never closed:
    // the gap is then an exact 0 (Gate passes drift, x - x is 0, Slew starts
    // at its input)
    fdnHeldDrift { arg drift, open;
        var held = Gate.kr(drift, open);
        var gap = Slew.kr(held - drift, this.fdnDriftReturnRate, this.fdnDriftReturnRate);
        ^Select.kr(open, [held, drift + gap])
    }

    // Sixteen fresh mono buffers of fdnLineFrames, on consecutive bufnums:
    // line i's interpolated read's at the first + (2 x i), its whole-sample
    // read's at the first + (2 x i) + 1, so the def takes one bufnum
    // (lineBuf). The engine check's own nodes take a set of their own
    newReverbLines {
        var server = context.server, first = server.nextBufferNumber(this.fdnLineFrames.size * 2);
        ^this.fdnLineFrames.collect({ arg frames, index;
            2.collect({ arg which; Buffer.alloc(server, frames, 1, bufnum: first + (2 * index) + which) })
        }).flatten
    }

    // From the effects area's allocState (synced before start), after the
    // performance area (order 10) has set the tier: on the high tier the
    // lines (ordinary RAM, 288 KB: highMemoryBytes counts them), allocated
    // once, so bufnums never change; nothing on the standard tier
    allocReverbLines {
        if (tier == \high) { areaState[\effects][\reverbLines] = this.newReverbLines };
    }

    // The first line's bufnum for startReverb, or 0 with no lines (the
    // standard tier's \strataReverb has no lineBuf: the server ignores a
    // control a def lacks)
    reverbLineBuf {
        ^areaState[\effects][\reverbLines] !? { arg lines; lines.first.bufnum } ? 0
    }

    // From the effects area's free, after every stop
    freeReverbLines {
        (areaState[\effects][\reverbLines] ? []).do({ arg buffer; buffer.free });
        areaState[\effects][\reverbLines] = nil;
    }

    // Zero the sixteen lines: sent in the bundle that frees the reverb
    // node, so the node a lift creates finds them empty. An empty network
    // has no tail to hold, so the kept frozen goes to 0 with them, as the
    // delay's (#889): a lifted reverb starts empty and unfrozen, never born
    // frozen (its Gate would hold a size of 0)
    emptyReverbLines {
        (areaState[\effects][\reverbLines] ? []).do({ arg buffer; context.server.listSendMsg(buffer.zeroMsg) });
        this.keepEffectControls(\reverb, (frozen: 0));
    }

    addReverbCommands {
        // msg: frozen, 0 (release) or 1 (freeze); another value is ignored
        // with one line. On the high tier, keep frozen and set it on the
        // node; with no node (a bypass has freed it, emptying its lines) 0
        // is kept, so a lift never starts a frozen node (Lua also releases a
        // freeze before it bypasses and refuses one while bypassed:
        // docs/notes/engine/reverb.md, Freeze by bypass). On the standard
        // tier (FreeVerb2) there is no freeze: 0 is kept and nothing is sent
        this.addCommand(\setReverbFreeze, "i", { arg msg;
            if (this.fastModIndicesValid(\setReverbFreeze, [[\frozen, msg[1], 1]])) {
                if (tier == \high) {
                    this.keepEffectControls(\reverb, (frozen: if (synths[\reverb].notNil) { msg[1] } { 0 }));
                    this.setSynth(\reverb, \frozen, msg[1]);
                } {
                    this.keepEffectControls(\reverb, (frozen: 0));
                };
            };
        });
    }
}
