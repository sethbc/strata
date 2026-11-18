// StrataTypeSaw.sc
// The saw voice type (3.8, design §3): \strataSaw, three detuned variable
// saws a side through a resonant lowpass. Its def's name is in the voices
// area's voiceTypeDefs and its expression range in noteMainRanges. See
// docs/notes/engine/types.md.

+ Engine_Strata {
    // The saw type's area (order 24): its def only. The voices area's
    // addDefs returns the name (voiceTypeDefs), so this one returns none
    strataAreaTypeSaw {
        ^(
            order: 24,
            addDefs: { this.areaCall(\addSawDef); [] }
        )
    }

    addSawDef {
        // Three VarSaws a side, each detuned from the pitch by 0, 1 and 2
        // times detune (upward on the left, downward on the right), so
        // detune 0 is one saw and the sides beat apart as it rises. width,
        // the expression control (noteMainValue), is each saw's width: 0.5
        // a triangle, toward either end a saw. A VarSaw's mean is 0 at any
        // width, so nothing reaches 0 Hz. Then Pulse's resonant lowpass: the
        // cutoff wanders between half and twice the setting, within
        // 100-8000 Hz, and res plays the filter's rq as 1.1 - res (Lua's
        // PULSE_RES.mirror, which a test compares), so one res sounds the
        // same on both types
        SynthDef(\strataSaw, {
            arg out, gate=1, freq=100, width=0.5, detune=0.003, cutoff=2000,
            res=0.8, amp=0.3, pan=0,
            modBus1=0, modBus2=0, modBus3=0,
            modAmpAmt1=0, modAmpAmt2=0, modAmpAmt3=0,
            modFreqAmt1=0, modFreqAmt2=0, modFreqAmt3=0,
            t_trig=0, velocity=1, bend=1, kill=0,
            noteGate=1, noteBend=1, noteAmp=1, noteMain=0, attackTime=3, releaseTime=6;
            var sig, env, modFreq, modAmp, modulation, modWidth;

            env = this.voiceEnvelope(gate, kill, noteGate, attackTime, releaseTime);
            // the accent, crossmod, bend and level every voice shares (voiceModulation)
            modulation = this.voiceModulation(freq, bend, amp, [modBus1, modBus2, modBus3],
                [modAmpAmt1, modAmpAmt2, modAmpAmt3], [modFreqAmt1, modFreqAmt2, modFreqAmt3], t_trig, velocity, noteBend, noteAmp);
            modFreq = modulation[\modFreq];
            modAmp = modulation[\modAmp];

            modWidth = this.noteMainValue(\strataSaw, width, noteMain);
            sig = [1, -1].collect({ arg side;
                [0, 1, 2].collect({ arg k; VarSaw.ar(modFreq * (1 + (detune * side * k)), 0, modWidth) }).sum / 3
            });

            cutoff = cutoff * LFNoise1.kr(0.1).range(0.5, 2);
            sig = RLPF.ar(sig, cutoff.clip(100, 8000), 1.1 - res.clip(0.1, 1));

            sig = Balance2.ar(sig[0], sig[1], pan);

            Out.ar(out, sig * env * modAmp * 0.5);
        }).add;
    }
}
