// StrataPositions.sc
// The positions area: a buffer grain synth's scan phase, with its transient
// performance state (t_scanReset, scrubRate, scanHold), which no scene, PSET
// or voices table holds; 3.7's scan modes (wrap, bounce, one shot), the scan
// as a speed, a note's region in the loop's place, the scan's sync
// (syncScan) and the restart of a one-shot voice's scan on its hits
// (voiceHit). See docs/notes/engine/positions.md.

+ Engine_Strata {
    // The positions area (order 150). t_scanReset is handled here so nothing
    // stores it: a replacement grain synth never starts with a stale trigger.
    // It reaches the voice's extra notes too (setGrainSynths).
    // scrubRate and scanHold are plain grain controls, stored and sent, so a
    // switch mid-glide keeps gliding. 3.7: regionLength (the own note's
    // region, with regionStart, a plain grain param sent before it) is kept
    // and set on the own grain synth with a scan restart, in one message; a
    // per-note control, so a voice-wide send never reaches an extra note
    // (perNoteGrainControls). A retrigger restarts a one-shot voice's own
    // scan (positionsHit), unless regionLength's restart reached the same
    // synth less than a control block before (regionResetJustSent, #742).
    strataAreaPositions {
        ^(
            order: 150,
            allocState: { this.areaCall(\allocPositionState) },
            addCommands: { this.areaCall(\addPositionCommands) },
            grainParamHandlers: (
                t_scanReset: { arg voice, value;
                    this.setGrainSynths(voice, \t_scanReset, value);
                    true
                },
                regionLength: { arg voice, value;
                    grainControls[voice][\regionLength] = value;
                    this.setSynth(this.grainKey(voice), \regionLength, value, \t_scanReset, 1);
                    areaState[\positions][\regionResets][voice] = [synths[this.grainKey(voice)], thisThread.seconds];
                    true
                }
            ),
            voiceHit: { arg voice, kind; this.areaCall(\positionsHit, voice, kind) }
        )
    }

    // areaState[\positions][\received]: what syncScan last took, for the
    // engine check; [\regionResets]: per voice, the own grain synth
    // regionLength last restarted and when ([synth, seconds], #742)
    allocPositionState {
        areaState[\positions][\received] = IdentityDictionary.new;
        areaState[\positions][\regionResets] = Array.newClear(numVoices);
    }

    // syncScan (design 3.7 §2.4): the voice's own scan phase, 0-2 in passes
    // (wrap takes its fraction, bounce the whole), on its own grain synth when
    // that reads a slot; nothing else. 3.5's command rules: a voice outside
    // 0..numVoices - 1 or a non-finite phase is ignored with one line
    // (fastModIndicesValid, fastModValuesFinite), the phase clipped, what it
    // took recorded
    addPositionCommands {
        this.addCommand(\syncScan, "if", { arg msg;
            var voice = msg[1], phase;
            if (this.fastModIndicesValid(\syncScan, [[\voice, voice, numVoices - 1]])
                and: { this.fastModValuesFinite(\syncScan, [[\phase, msg[2]]]) }) {
                phase = msg[2].clip(0, 2);
                areaState[\positions][\received][\syncScan] = [voice, phase];
                this.syncScan(voice, phase);
            };
        });
    }

    syncScan { arg voice, phase;
        var synth = synths[this.grainKey(voice)];
        if (synth.notNil and: { synth.defName.asSymbol == \strataGrainBuf }) {
            this.setSynth(this.grainKey(voice), \scanSyncPhase, phase, \t_scanSync, 1);
        };
    }

    // A hit (voiceHit): a retrigger restarts a one-shot voice's own scan,
    // its own grain synth's alone (an extra note's restarts at its own
    // noteOn: extraNoteOn), unless regionLength has just restarted it: a
    // slice's region and hit then restart the scan once, not twice (#742)
    positionsHit { arg voice, kind;
        if ((kind == \retrigger) and: { this.oneShotVoice(voice) } and: { this.regionResetJustSent(voice).not }) {
            this.setSynth(this.grainKey(voice), \t_scanReset, 1);
        };
    }

    // True when regionLength's restart reached the voice's live own grain
    // synth less than a control block ago (#742). Two sets of t_scanReset
    // in the same or adjacent blocks already make one restart; two need a
    // block of 0 between them. sclang cannot see the server's blocks, so the
    // window is one block's time against thisThread.seconds (in a command
    // handler, when sclang took the message)
    regionResetJustSent { arg voice;
        var last = areaState[\positions][\regionResets][voice], server = context.server;
        ^last.notNil and: { last[0].notNil } and: { last[0] === synths[this.grainKey(voice)] }
            and: { (thisThread.seconds - last[1]) < (server.options.blockSize / server.sampleRate) }
    }

    // Whether the voice's scan is a one shot: its kept scanMode rounded and
    // clipped to 0-2, as the def reads it (slotScanState), is 2
    oneShotVoice { arg voice;
        ^(grainControls[voice][\scanMode] ? 0).round.clip(0, 2) == 2
    }

    // The scan's speed (3.7, ruling 29): the phase's rate for a scan of 1,
    // in spans a second, where spanFrames is the span (the region's or the
    // loop's length) in the slot's frames, at least one: bufRateScale x the
    // server's rate is the slot's frames a second, so a scan of 1 crosses
    // any span in its own length
    slotScanSpeed { arg bufRateScale, spanFrames;
        ^bufRateScale * SampleRate.ir / spanFrames.max(1)
    }

    // A buffer grain synth's 3.7 scan state, from an Event of its controls
    // (scanMode, regionStart, regionLength, followRate, slotGain, t_scanSync,
    // scanSyncPhase) and its loop: mode (scanMode rounded, 0 wrap, 1 bounce,
    // 2 one shot), oneShot (1 in one shot), first and last (the span's first
    // and last fraction of the valid region: the region while regionLength >
    // 0, else the loop; slotSpan, StrataLoop.sc), and the other controls as
    // they are
    slotScanState { arg controls, loopStart, loopLength;
        var scanMode = controls[\scanMode], mode = scanMode.round.clip(0, 2);
        var span = this.slotSpan(loopStart, loopLength, controls[\regionStart], controls[\regionLength]);
        ^(mode: mode, oneShot: mode > 1.5, first: span[0], last: span[1], followRate: controls[\followRate],
            slotGain: controls[\slotGain], t_scanSync: controls[\t_scanSync], scanSyncPhase: controls[\scanSyncPhase])
    }

    // A buffer grain's scan offset, in fractions of its span: the voice's
    // own scan (scanRate, stopped while frozen or by scanHold) at the speed
    // (slotScanSpeed) plus scrubRate (spans a second), which neither stops.
    // t_scanReset restarts it at 0. Without a scan state (state nil: a
    // check-only reader), 3.2's wrapping Phasor. With one (slotScanState):
    // in wrap a Phasor from 0 to 1, in bounce to 2 (two passes, which
    // slotScanPosition folds), reset by t_scanReset to 0 or by the sync
    // (t_scanSync) to scanSyncPhase, wrapped into its range; in one shot an
    // integrator (Sweep, double precision) that starts at 0 at a restart and
    // runs either way without wrapping (a Phasor with a far end wraps at once
    // on a negative rate), which the sync never moves
    slotScanPhase { arg bufScan, freeze, scrubRate, scanHold, t_scanReset, speed = 1, state;
        var rate = (this.scanRate(bufScan, freeze) * speed * (1 - scanHold)) + scrubRate, end;
        if (state.isNil) { ^Phasor.ar(t_scanReset, rate * SampleDur.ir, 0, 1) };
        end = Select.kr(state[\mode], [1, 2, 1]);
        ^Select.ar(state[\oneShot], [
            Phasor.ar(t_scanReset + state[\t_scanSync], rate * SampleDur.ir, 0, end,
                state[\scanSyncPhase].wrap(0, end) * state[\t_scanSync]),
            Sweep.ar(t_scanReset, rate)
        ])
    }

    // Where in its span (0-1) a buffer grain starts, from the position
    // (bufPos), the scan's phase and the grain's spread draw. Wrap (and no
    // scan state): the three summed and wrapped, 3.2's, with bufPos 1 the
    // span's last start (lastLoopPosition). Bounce: bufPos + the phase folded
    // over the span; one shot: held at its edges; in both the spread is added
    // last and the sum clipped to the span, never wrapped. state[\sum] is
    // bufPos + the phase when the reader has it (the one shot's level reads it)
    slotScanPosition { arg bufPos, scanPhase, spreadDraw, state;
        var wrapped = (bufPos.min(this.lastLoopPosition) + scanPhase + spreadDraw).wrap(0, 1), sum, held;
        if (state.isNil) { ^wrapped };
        sum = state[\sum] ?? { bufPos + scanPhase };
        held = (Select.ar(state[\oneShot], [sum.fold(0, 1), sum.clip(0, 1)]) + spreadDraw).clip(0, 1);
        ^Select.ar(state[\mode], [wrapped, held, held])
    }

    // A one-shot grain synth's level (state[\sum] is bufPos + the phase): 0
    // once the sum is past 1 (its end, forward) or below 0 (before its start,
    // backward), lagged 5 ms, until a restart brings it back; 1 in the other
    // modes. At exactly 1 (the span's last start) it sounds (design §2.1,
    // §3.5; the decisions' 3.7 file), so a backward one shot from 1 opens at
    // full level
    oneShotLevel { arg state;
        var sum = state[\sum];
        ^(1 - (((sum > 1) + (sum < 0)) * state[\oneShot])).lag(0.005)
    }
}
