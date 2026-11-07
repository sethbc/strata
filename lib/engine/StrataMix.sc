// StrataMix.sc
// The mix area: a grain synth's own filter (voiceFilter) and where its
// output goes (voiceOutput): the dry bus (out, mainBus), the delay send and
// the reverb send, with gains that reproduce 3.0's crossfade mixes at
// sends of 1, plus the mirror. Holds the send buses, their filtered copies
// and fxMixBus (the global delay and reverb mixes the effects area
// broadcasts). See docs/notes/engine/effects.md.

+ Engine_Strata {
    // The mix area (order 120)
    strataAreaMix {
        ^(
            order: 120,
            allocState: { this.allocMixBuses },
            free: { this.freeMixBuses }
        )
    }

    // The mixes' lag in every reader (s): 3.0's delay lagged its mix by as much
    fxMixLag { ^0.05 }

    // The buses (areaState[\mix]): the delay and reverb sends (stereo audio,
    // written by every grain synth), their copies after the master filter
    // (...Post), and fxMix (control, 2 channels: the delay mix and the reverb
    // mix as the engine broadcasts them). The effects area's buses are
    // named here too: dry (mainBus, every grain synth's out), dryPost
    // (filterBus), delayReturn (delayBus) and reverbReturn (reverbBus). The
    // grain synths take this engine's send and mix buses through
    // grainControls (mixBusControls), never only through their SynthDef
    // defaults: those are the buses of the last engine built, which in the
    // engine check is not always this one.
    allocMixBuses {
        var state = areaState[\mix], server = context.server;
        [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost].do({ arg name; state[name] = Bus.audio(server, 2) });
        state[\fxMix] = Bus.control(server, 2);
        state[\dry] = mainBus;
        state[\dryPost] = filterBus;
        state[\delayReturn] = delayBus;
        state[\reverbReturn] = reverbBus;
        numVoices.do({ arg voice; grainControls[voice].putAll(this.mixBusControls) });
    }

    // A mix bus by name (areaState[\mix])
    mixBus { arg name;
        ^areaState[\mix][name]
    }

    // The grain synths' bus controls (voiceOutput's named controls) for
    // this engine's buses
    mixBusControls {
        ^Dictionary[
            \delaySendOut -> this.mixBus(\delaySend).index,
            \reverbSendOut -> this.mixBus(\reverbSend).index,
            \fxMixIn -> this.mixBus(\fxMix).index
        ]
    }

    // The mix area's own buses (every node is gone by now)
    freeMixBuses {
        [\delaySend, \reverbSend, \delaySendPost, \reverbSendPost, \fxMix].do({ arg name; this.mixBus(name).free });
    }

    // A grain synth's stereo output through the voice's own filter: the
    // master filter's design (multimodeFilter: RLPF, RHPF and BPF weighted by
    // a lagged type match, so a type change crossfades over 20 ms), with the
    // cutoff and mix lagged 0.05 s as the master's. filterMix 0 (the
    // default) passes sig unchanged.
    voiceFilter { arg sig, filterType, filterFreq, filterRes, filterMix;
        ^this.multimodeFilter(sig, filterFreq.lag(0.05).clip(20, 20000), filterRes.clip(0, 1), filterType,
            filterMix.lag(0.05).clip(0, 1))
    }

    // Write a grain synth's stereo output. With the voice's sends s_d and
    // s_r (delaySend, reverbSend, 0-1, lagged) and the global mixes m_d and
    // m_r (fxMixIn, lagged fxMixLag):
    //   out (dry):     (1 - s_d m_d)(1 - s_r m_r)
    //   delay send:    s_d
    //   reverb send:   s_r (1 - s_d m_d)
    // The effects add m_d D (the delay's return) and m_r R (the reverb's)
    // back (StrataEffects.sc), so at sends of 1 this is term for term 3.0's
    // serial chain, and at sends of 0 the voice plays dry at full level.
    // The mirror (mirrorOut, times mirrorLevel: the voice bus, for its mod
    // synth) is the whole output, whatever the sends.
    voiceOutput { arg sig, out, mirrorOut, mirrorLevel, delaySend, reverbSend;
        var mixes = In.kr(\fxMixIn.kr(this.mixBus(\fxMix).index), 2).clip(0, 1).lag(this.fxMixLag);
        var toDelay = delaySend.clip(0, 1).lag(this.fxMixLag), toReverb = reverbSend.clip(0, 1).lag(this.fxMixLag);
        var pastDelay = 1 - (toDelay * mixes[0]);
        Out.ar(out, sig * (pastDelay * (1 - (toReverb * mixes[1]))));
        Out.ar(\delaySendOut.kr(this.mixBus(\delaySend).index), sig * toDelay);
        Out.ar(\reverbSendOut.kr(this.mixBus(\reverbSend).index), sig * (toReverb * pastDelay));
        Out.ar(mirrorOut, sig * mirrorLevel);
    }
}
