// test/engine_check/voices.scd
// The voices: the voice SynthDefs' controls, velocity only as the accent's
// levelScale (and the Karplus allowance, checked against bent copies), the
// silent bus, voiceOn, crossmod routing and slots, pitchbend, retrigger and
// its velocity, the Resonator's ceiling and level, the strataMod guard, the
// controls the engine refuses as param names, what a voice param sends a
// buffer voice's grain synth, commands to a stopped voice or a bad index,
// the FM and Ring voices' subsonic block, and the direction of the Pulse
// voice's res.
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var synthNames = { arg group; h.synthNames(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var controlFeedsAUGen = { arg defName, controlName; h.controlFeedsAUGen(defName, controlName) };
var readBus = { arg bus; h.readBus(bus) };
var measure = { arg probe, bus, seconds = 0.3; h.measure(probe, bus, seconds) };
var voiceDefs = h.voiceDefs, grainDefs = h.grainDefs;
var silentIndex, before, after;

// true when the velocity control feeds nothing but EnvGen levelScale inputs
// (a per-trigger accent depth), never a bare multiplier on a running signal.
// One narrow allowance, for \strataKarplus (or a check SynthDef given
// pluckAllowed true): velocity may scale a T2A of the t_trig control (a
// single-sample impulse per retrigger) on its way to the pluck excitation,
// and nowhere else. sclang fuses `T2A * velocity + Impulse` into a MulAdd,
// so the product is either a MulAdd (T2A and velocity, plus anything but
// velocity) or a '*' BinaryOpUGen whose users are '+' sums; every user of
// the MulAdd (or of those sums) must be a Decay's input (the noise burst)
// or a Pluck's trigger (#47; checkKarplusMutants checks the check).
var velocityOnlyScalesAccents = { arg defName, pluckAllowed;
    var desc = SynthDescLib.global.at(defName);
    var ugens = desc.def.children, allowPluck = pluckAllowed ? (defName == \strataKarplus);
    var controlIndex = { arg name; desc.controls.detect({ arg each; each.name == name }) !? { arg control; control.index } };
    var velocityIndex = controlIndex.(\velocity), trigIndex = controlIndex.(\t_trig);
    var isControl = { arg input, index;
        index.notNil and: { input.isKindOf(OutputProxy) } and: { input.source.isKindOf(Control) }
            and: { (input.source.specialIndex + input.outputIndex) == index }
    };
    var isVelocity = { arg input; isControl.(input, velocityIndex) };
    var isTrigImpulse = { arg input; input.isKindOf(T2A) and: { isControl.(input.inputs[0], trigIndex) } };
    // [ugen, input index] for every input of every UGen that is source
    var usersOf = { arg source;
        ugens.collect({ arg ugen; (ugen.inputs ? []).collect({ arg input, index; if (input === source) { [ugen, index] } }).reject(_.isNil) })
            .flatten(1)
    };
    var excitesOnly = { arg source;
        var users = usersOf.(source);
        users.notEmpty and: { users.every({ arg pair;
            (pair[0].isKindOf(Decay) and: { pair[1] == 0 }) or: { pair[0].isKindOf(Pluck) and: { pair[1] == 1 } }
        }) }
    };
    var scalesTrigImpulse = { arg factors;
        (factors.select(isVelocity).size == 1) and: { factors.select(isTrigImpulse).size == 1 }
    };
    var isPluckImpulseProduct = { arg ugen;
        var users;
        allowPluck and: {
            case
            { ugen.isKindOf(MulAdd) } {
                scalesTrigImpulse.(ugen.inputs.copyRange(0, 1)) and: { isVelocity.(ugen.inputs[2]).not }
                    and: { excitesOnly.(ugen) }
            }
            { ugen.isKindOf(BinaryOpUGen) and: { ugen.operator == '*' } } {
                users = usersOf.(ugen);
                scalesTrigImpulse.(ugen.inputs) and: { users.notEmpty } and: { users.every({ arg pair;
                    pair[0].isKindOf(BinaryOpUGen) and: { pair[0].operator == '+' } and: { excitesOnly.(pair[0]) }
                }) }
            }
            { false }
        }
    };
    var users;
    if (velocityIndex.isNil) { false } {
        users = ugens.select({ arg ugen; (ugen.inputs ? []).any(isVelocity) });
        users.notEmpty and: { users.every({ arg ugen;
            isPluckImpulseProduct.(ugen) or: {
                ugen.isKindOf(EnvGen) and: { ugen.inputs.every({ arg input, index; isVelocity.(input).not or: { index == 1 } }) }
            }
        }) }
    }
};

// The Karplus allowance above is narrow (#47): a check-only copy of the
// Karplus excitation passes with the allowance on, and copies bent three
// ways fail with it: the impulse a T2A of the gate instead of t_trig, the
// velocity-scaled impulse also scaling the output, and the excitation
// trigger smeared into a running level (a Lag) that scales the output
var checkKarplusMutants = {
    var addKarplusCopy = { arg name, mutation;
        SynthDef(name, { arg out, gate = 1, t_trig = 0, velocity = 1;
            var accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);
            var exciteTrig = Impulse.ar(0.3) + (T2A.ar(if (mutation == \gateImpulse) { gate } { t_trig }) * velocity);
            var sig = Pluck.ar(Decay.ar(exciteTrig, 0.01, PinkNoise.ar(1)), exciteTrig, 0.1, 0.005, 4, 0.5);
            if (mutation == \impulseToOutput) { sig = sig * (1 + (T2A.ar(t_trig) * velocity)) };
            if (mutation == \impulseLevel) { sig = sig * Lag.ar(exciteTrig, 0.5) };
            Out.ar(out, sig * (1 + accent));
        }).add;
    };
    [[\strataCheckKarplusCopy, nil, true, "a faithful copy of the Karplus excitation"],
        [\strataCheckKarplusGateImpulse, \gateImpulse, false, "a velocity-scaled T2A of the gate (not of t_trig)"],
        [\strataCheckKarplusImpulseOut, \impulseToOutput, false, "a velocity-scaled T2A of t_trig that also scales the output"],
        [\strataCheckKarplusImpulseLevel, \impulseLevel, false, "an excitation trigger smeared into a level that scales the output"]
    ].do({ arg mutant;
        addKarplusCopy.(mutant[0], mutant[1]);
        check.(velocityOnlyScalesAccents.(mutant[0], true) == mutant[2],
            "the strict velocity check % % under the Karplus allowance".format(
                if (mutant[2]) { "accepts" } { "rejects" }, mutant[3]));
    });
};

// The crossmod commands take slots 1..numModSlots, the modBus1..N of every
// voice SynthDef, and ignore any other slot (#47): nothing is kept for it in
// voiceControls (where it stayed for good) and the voice's slots are
// unchanged. The voice runs on its synth source.
var checkModSlots = { arg voice;
    var slots = engine.tryPerform(\numModSlots), synth = engine.synths[engine.voiceKey(voice)], stray;
    var modBusCounts = voiceDefs.collect({ arg name;
        SynthDescLib.global.at(name).controlNames.count({ arg control; control.asString.beginsWith("modBus") })
    });
    check.(slots.notNil and: { modBusCounts.every({ arg count; count == slots }) },
        "numModSlots (%) is the number of modBus controls of every voice SynthDef (%)".format(slots, modBusCounts));
    [0, 4, -1].do({ arg slot;
        command.(\setModSource, voice, slot, 0);
        command.(\setModAmpAmt, voice, slot, 0.5);
        command.(\setModFreqAmt, voice, slot, 0.5);
    });
    command.(\setModAmpAmt, voice, 3, 0.25);
    server.sync;
    stray = ["modBus", "modAmpAmt", "modFreqAmt"].collect({ arg prefix; [0, 4, -1].collect({ arg slot; (prefix ++ slot).asSymbol }) })
        .flatten.select({ arg name; engine.voiceControls[voice][name].notNil });
    check.(stray.isEmpty and: { getControl.(synth, \modAmpAmt3) == 0.25 } and: { engine.voiceControls[voice][\modAmpAmt3] == 0.25 },
        "crossmod commands ignore slots 0, 4 and -1 and slot 3 still works (stray controls kept: %)".format(stray));
    command.(\setModAmpAmt, voice, 3, 0.0);
};

// The Resonator's filter cutoff stays below Nyquist: sixteen Resonators far
// past it (10-25 kHz, x 3 by frequency crossmod, bent up 2 semitones, rq 1,
// each with its own noise factor of 1-4) on a private bus produce no NaN or
// inf. Unclamped, RLPF is unstable whenever cutoff x rq falls between SR/2
// and SR (or the same band above a multiple of SR), so some would blow up.
var checkResonatorCeiling = {
    var group = Group.tail(server), out = Bus.audio(server, 2), modBus = Bus.control(server, 1);
    var badBus = Bus.control(server, 1), probe, bad;
    modBus.set(1);
    16.do({ arg index;
        Synth(\strataResonator, [\out, out, \freq, 10000 + (index * 1000), \rq, 1, \amp, 0.3, \bend, 2 ** (2 / 12),
            \modBus1, modBus.index, \modBus2, engine.silentBus.index, \modBus3, engine.silentBus.index,
            \modFreqAmt1, 2], group);
    });
    probe = Synth(\strataCheckBadValues, [\in, out, \out, badBus], group, \addToTail);
    server.sync;
    bad = measure.(probe, badBus, 1.5);
    check.(bad == [0], "Resonators with a cutoff far past Nyquist stay finite (bad values seen: %)".format(bad));
    group.free; out.free; modBus.free; badBus.free;
    server.sync;
};

// The Resonator's level: DynKlank's resonators driven by noise ring far
// hotter than the other voices (at its defaults it peaked about 23 before
// the master limiter, at reachable extremes in the thousands, so it crushed
// every other voice). resonatorGain and a mono limiter at voiceCeiling (1,
// before the pan) fix it:
// - 32 Resonators at their defaults (amp 0.3, no accents) have a median
//   RMS of 0.07-0.22, and 32 with a gain 3x too high (amp 0.9: amp scales
//   the same product as resonatorGain) a median above 0.22, which the
//   limiter does not hide the way it hides peaks; the defaults peak at most
//   0.75 per channel. One Resonator's RMS over the meter's 1.5 s spreads
//   widely (0.06-0.34 at the defaults, 0.2-0.47 at 3x, in 256 of each),
//   because the cutoff's 1-4 noise factor and the amplitude wobbles move
//   at 0.1-0.15 Hz: a median of eight passed 0.2 about once in 100 runs
//   (#91). Bootstrapped from those 256, a median of 32 has mean 0.127 and
//   SD 0.009 at the defaults (range 0.09-0.18) and mean 0.327 and SD 0.012
//   at 3x (0.27-0.37), so 0.22 sits about 9 SD from both;
// - at the extremes Lua allows (freq 20-2000, rq 0.01 or 1, noise 1, amp 1,
//   amplitude and frequency crossmod at full, accents at velocity 1 every
//   0.25 s), centered, no channel passes 0.75 (the limiter's 1 x Pan2's
//   0.707 at the center);
// - one extreme panned hard right reaches the limiter's own level: its right
//   channel peaks at 0.9-1.05 and its left stays silent.
var checkResonatorLevel = {
    var group = Group.tail(server), modBus = Bus.control(server, 1), silent = engine.silentBus.index;
    var defaults = [\freq, 100, \rq, 0.1, \noise, 0.5, \amp, 0.3, \modBus1, silent, \modBus2, silent];
    var extremes = [20, 100, 400, 2000].collect({ arg freq; [0.01, 1].collect({ arg rq;
        [\freq, freq, \rq, rq, \noise, 1, \amp, 1, \modAmpAmt1, 2, \modFreqAmt2, 2]
    }) }).flatten(1);
    var panned = [\freq, 20, \rq, 0.01, \noise, 1, \amp, 1, \modAmpAmt1, 2, \modFreqAmt2, 2, \pan, 1];
    var tripled = defaults ++ [\amp, 0.9];     // /s_new sets controls in order: the later amp wins
    var defaultCount = 32, rmsCeiling = 0.22;
    var cases = (defaultCount.collect({ defaults }) ++ defaultCount.collect({ tripled }) ++ extremes ++ [panned]);
    var buses = cases.collect({ Bus.audio(server, 2) }), peakBus = Bus.control(server, 2 * cases.size);
    var rmsBus = Bus.control(server, 2 * defaultCount), synths, peaks, rms, tripledRms, defaultPeak, extremePeak, pannedPeaks;
    var extremeStart = 2 * defaultCount;
    var median = { arg values; values[defaultCount div: 2] };
    var show = { arg value; value !? { value.round(0.001) } };
    var spread = { arg values; "%-%".format(show.(values.first), show.(values.last)) };
    // Limiter delays its output by twice its lookahead (dur): its default
    // 0.01 s put the Resonator 20 ms behind the other voices (#47)
    var lookaheads = SynthDescLib.global.at(\strataResonator).def.children.select({ arg ugen; ugen.isKindOf(Limiter) })
        .collect({ arg ugen; ugen.inputs[2] });
    check.((lookaheads.size == 1) and: { lookaheads[0].isNumber } and: { lookaheads[0] >= 0.002 } and: { lookaheads[0] <= 0.005 }
        and: { lookaheads[0] == engine.tryPerform(\voiceLimiterLookahead) },
        "the Resonator's limiter looks ahead voiceLimiterLookahead, 2-5 ms, delaying the voice 4-10 ms (got %)".format(lookaheads));
    modBus.set(1);
    synths = cases.collect({ arg args, index;
        Synth(\strataResonator, [\out, buses[index], \modBus1, modBus.index, \modBus2, modBus.index, \modBus3, silent] ++ args, group)
    });
    cases.do({ arg args, index;
        Synth(\strataCheckChannelPeaks, [\in, buses[index], \out, peakBus.index + (2 * index)], group, \addToTail);
        if (index < extremeStart) { Synth(\strataCheckRms, [\in, buses[index], \out, rmsBus.index + index], group, \addToTail) };
    });
    server.sync; 4.5.wait;                     // past the 4 s attack
    group.set(\t_reset, 1);
    4.wait;                                    // the RMS meters have forgotten the attack
    rms = readBus.(rmsBus);
    tripledRms = rms.copyRange(defaultCount, extremeStart - 1).sort;
    rms = rms.copyRange(0, defaultCount - 1).sort;
    defaultPeak = readBus.(peakBus).copyRange(0, (2 * defaultCount) - 1).maxItem;
    group.set(\t_reset, 1);
    8.do({ synths.do({ arg synth; synth.set(\velocity, 1, \t_trig, 1) }); 0.25.wait });
    peaks = readBus.(peakBus).clump(2);
    extremePeak = peaks.copyRange(extremeStart, extremeStart + extremes.size - 1).flatten.maxItem;
    pannedPeaks = peaks.last;
    check.((rms.size == defaultCount) and: { median.(rms) >= 0.07 } and: { median.(rms) <= rmsCeiling },
        "% Resonators at their defaults have a median RMS of 0.07-% (got %, range %)".format(
            defaultCount, rmsCeiling, show.(median.(rms)), spread.(rms)));
    check.((tripledRms.size == defaultCount) and: { median.(tripledRms) > rmsCeiling },
        "% Resonators with a gain 3x too high (amp 0.9) have a median RMS above % (got %, range %)".format(
            defaultCount, rmsCeiling, show.(median.(tripledRms)), spread.(tripledRms)));
    check.(defaultPeak.notNil and: { defaultPeak > 0.05 } and: { defaultPeak <= 0.75 },
        "the Resonator at its defaults peaks at most 0.75 per channel (got %)".format(defaultPeak));
    check.(extremePeak.notNil and: { extremePeak <= 0.75 },
        "the Resonator at reachable extremes, centered, never peaks past 0.75 per channel (got %; per case %)".format(extremePeak,
            peaks.copyRange(extremeStart, extremeStart + extremes.size - 1).collect(_.maxItem).collect({ arg value; value.round(0.01) })));
    check.(pannedPeaks.notNil and: { pannedPeaks[1] >= 0.9 } and: { pannedPeaks[1] <= 1.05 } and: { pannedPeaks[0] < 0.001 },
        "a Resonator extreme panned hard right peaks at its limiter's level, 0.9-1.05 (got %)".format(pannedPeaks));
    group.free; modBus.free; peakBus.free; rmsBus.free; buses.do(_.free);
    server.sync;
};

// A NaN or inf on a voice bus (a voice blowing up) never reaches its mod bus
// (#47), so it cannot spread through crossmod into the voices it modulates
// and, through their mod synths, on, for good. On private buses: a tone and
// 50 ms of inf and NaN on a voice bus, read by a strataMod; a Resonator
// modulated by its mod bus at full amplitude and frequency depth. After the
// burst the mod bus is finite and follows the tone again, and the Resonator
// has produced no bad value.
var checkModGuard = {
    var group = Group.tail(server), voiceBus = Bus.audio(server, 2), out = Bus.audio(server, 2), modBus = Bus.control(server, 1);
    var voiceBadBus = Bus.control(server, 1), badBus = Bus.control(server, 1), abBus = Bus.control(server, 4), silent = engine.silentBus.index;
    var mod, probe, voiceBad, bad, modValue, ab;
    var guards = SynthDescLib.global.at(\strataMod).def.children.count({ arg ugen; ugen.isKindOf(CheckBadValues) });
    // A/B first: zeroBadValues, the guard strataMod applies to its input
    // (audio) and output (control), passes normal values bit for bit: the
    // largest difference between guarded and unguarded copies of a varied
    // signal (and of its follower) is exactly 0, while the signals are not
    SynthDef(\strataCheckGuardAB, { arg in, out;
        var audio = In.ar(in, 2).sum * LFNoise1.ar(50).exprange(0.001, 3);
        var control = (Amplitude.kr(audio, 0.01, 0.1) * 0.7) + LFNoise1.kr(10).range(0, 0.3);
        Out.kr(out, [A2K.kr(Peak.ar((engine.zeroBadValues(audio) - audio).abs)),
            Peak.kr((engine.zeroBadValues(control) - control).abs), A2K.kr(Peak.ar(audio.abs)), Peak.kr(control.abs)]);
    }).add;
    server.sync;
    Synth(\strataCheckTone, [\out, voiceBus], group);
    Synth(\strataCheckGuardAB, [\in, voiceBus, \out, abBus], group, \addToTail);
    server.sync; 0.5.wait;
    ab = readBus.(abBus);
    check.((guards == 2) and: { ab.size == 4 } and: { ab[0] == 0 } and: { ab[1] == 0 } and: { ab[2] > 0.1 } and: { ab[3] > 0.1 },
        "strataMod guards its input and output (% CheckBadValues) and the guard passes normal values bit for bit (largest difference audio %, control %; peaks %, %)".format(
            guards, ab[0], ab[1], ab[2], ab[3]));
    group.freeAll; server.sync;
    Synth(\strataCheckTone, [\out, voiceBus], group);
    mod = Synth(\strataMod, [\in, voiceBus, \out, modBus], group, \addToTail);
    Synth(\strataCheckBadValues, [\in, voiceBus, \out, voiceBadBus], mod, \addBefore);
    Synth(\strataResonator, [\out, out, \modBus1, modBus.index, \modBus2, silent, \modBus3, silent,
        \modAmpAmt1, 2, \modFreqAmt1, 2], group, \addToTail);
    probe = Synth(\strataCheckBadValues, [\in, out, \out, badBus], group, \addToTail);
    server.sync; 0.5.wait;
    Synth(\strataCheckBadSource, [\out, voiceBus], group, \addToHead);
    server.sync; 0.3.wait;
    voiceBad = readBus.(voiceBadBus);
    check.(voiceBad.notEmpty and: { voiceBad[0] > 0 }, "the check's burst puts NaN and inf on the voice bus (seen: %)".format(voiceBad));
    bad = measure.(probe, badBus, 0.5);
    modValue = readBus.(modBus)[0];
    check.(modValue.notNil and: { modValue.isNaN.not } and: { modValue > 0.3 } and: { modValue < 2 },
        "after the burst strataMod's output is finite and follows the voice again (got %)".format(modValue));
    check.(bad == [0], "a voice crossmodulated by a voice that blew up stays finite (bad values seen: %)".format(bad));
    group.free; voiceBus.free; out.free; modBus.free; voiceBadBus.free; badBus.free; abBus.free;
    server.sync;
};

// The FM and Ring voices leave nothing under the audible range on their
// voice bus at ratio 1, where a sideband (FM) or the difference tone (Ring)
// falls at 0 Hz and wanders a few Hz either way with the ratio (#309):
// below 8 Hz (two 8 Hz lowpasses) the bus peaks under subsonicCeiling
// (0.15) of its whole peak over 14 s (0.02-0.06 measured with the 15 Hz
// highpass; 0.47 and 0.44 without it). Both voices on their synth source.
var checkSubsonic = {
    var subsonicCeiling = 0.15;
    var bus = Bus.control(server, 4), probes, values;
    SynthDef(\strataCheckSubsonic, { arg in, out, t_reset = 0;
        var sig = In.ar(in, 2)[0], reset = T2A.ar(t_reset);
        Out.kr(out, A2K.kr([Peak.ar(LPF.ar(LPF.ar(sig, 8), 8).abs, reset), Peak.ar(sig.abs, reset)]));
    }).add;
    command.(\setGrainSource, 1, 0);
    command.(\setGrainSource, 6, 0);
    server.sync;
    command.(\voiceOn, 1, 80.0, 0.25, 0.0, 0.1, 20.0, 1.0);
    command.(\setVoiceParam, 1, \ratio, 1.0);
    command.(\setVoiceParam, 1, \index, 2.0);
    command.(\voiceOn, 6, 300.0, 0.25, 0.0, 0.1, 20.0, 1.0);
    command.(\setVoiceParam, 6, \ratio, 1.0);
    server.sync; 6.0.wait;
    probes = [Synth(\strataCheckSubsonic, [\in, engine.granBuses[1], \out, bus.index], engine.voiceGroup, \addAfter),
        Synth(\strataCheckSubsonic, [\in, engine.granBuses[6], \out, bus.index + 2], engine.voiceGroup, \addAfter)];
    // (the probes' lowpasses settle before the measurement starts)
    server.sync; 1.0.wait;
    server.makeBundle(nil, { probes.do(_.set(\t_reset, 1)) }); 14.0.wait;
    values = readBus.(bus);
    check.((values.size == 4) and: { values[1] > 0.1 } and: { values[0] < (values[1] * subsonicCeiling) },
        "voices: the FM voice at ratio 1 leaves nothing under the audible range on its bus (below 8 Hz % of a peak of %)".format(
            values[0].round(0.0001), values[1].round(0.0001)));
    check.((values.size == 4) and: { values[3] > 0.1 } and: { values[2] < (values[3] * subsonicCeiling) },
        "voices: nor does the Ring voice at ratio 1 (below 8 Hz % of a peak of %)".format(
            values[2].round(0.0001), values[3].round(0.0001)));
    probes.do(_.free); server.sync; bus.free;
    command.(\voiceOff, 1); command.(\voiceOff, 6);
    h.stopAllVoices;
};

// The Pulse voice's res rises with resonance, as every other res does
// (#314): at 250 Hz with its cutoff at 1000 the voice bus is at least
// pulseResMinimumDb (1 dB) louder at res 1 than at res 0.1, each the RMS of
// its left channel over 6 s, alternated 0.1, 1, 0.1, 1 so the cutoff's slow
// wander (0.5 to 2 times, at 0.2 Hz) averages out (+3.2 to +4.4 dB measured;
// -4.1 dB when res was the filter's rq). Every level is above 0.01.
var checkPulseRes = {
    var pulseResMinimumDb = 1;
    var bus = Bus.control(server, 1), probe, levels, ratioDb;
    SynthDef(\strataCheckPulseRms, { arg in, out, t_reset = 0;
        var sig = In.ar(in, 2)[0], reset = T2A.ar(t_reset);
        Out.kr(out, A2K.kr((Integrator.ar(sig.squared, 1 - reset) / Sweep.ar(reset, SampleRate.ir).max(1)).sqrt));
    }).add;
    command.(\setGrainSource, 4, 0);
    server.sync;
    command.(\voiceOn, 4, 250.0, 0.3, 0.0, 0.1, 20.0, 1.0);
    command.(\setVoiceParam, 4, \cutoff, 1000.0);
    command.(\setVoiceParam, 4, \width, 0.5);
    server.sync; 3.0.wait;
    probe = Synth(\strataCheckPulseRms, [\in, engine.granBuses[4], \out, bus.index], engine.voiceGroup, \addAfter);
    levels = [0.1, 1.0, 0.1, 1.0].collect({ arg res;
        command.(\setVoiceParam, 4, \res, res);
        server.sync; 0.3.wait;
        probe.set(\t_reset, 1); 6.0.wait;
        readBus.(bus)[0] ? 0
    });
    ratioDb = ((levels[1] + levels[3]) / (levels[0] + levels[2]).max(1e-9)).ampdb;
    check.((levels.minItem > 0.01) and: { ratioDb >= pulseResMinimumDb },
        "voices: the Pulse voice's res rises with resonance (RMS at res 0.1, 1, 0.1, 1: %; res 1 over res 0.1: % dB)".format(
            levels.round(0.0001), ratioDb.round(0.01)));
    probe.free; server.sync; bus.free;
    command.(\voiceOff, 4);
    h.stopAllVoices;
};

// setGrainParam and setVoiceParam keep none of the controls the engine
// sets itself (#458): kept, a value stayed in grainControls or
// voiceControls for good and reached every synth the engine started for
// the voice. kill 1 cut each grain synth 50 ms in (and the engine started
// another); the others are sent the value they already have (so a kept one
// changes no sound) and must not be kept. bufferVoice runs on a slot,
// synthVoice on its synth.
var checkEngineOwnedControls = { arg bufferVoice, synthVoice;
    var grainKey = engine.grainKey(bufferVoice), voiceKey = engine.voiceKey(synthVoice);
    var grain = engine.synths[grainKey], voiceSynth = engine.synths[voiceKey], slot = engine.grainSource[bufferVoice] - 1;
    var keptGrain = engine.grainControls[bufferVoice].copy, keptVoice = engine.voiceControls[synthVoice].copy;
    var envBuf = engine.grainControls[bufferVoice][\envBuf], otherEnvelope;
    var unchanged = { arg now, before, names; names.every({ arg name; now[name] == before[name] }) };
    var grainNames, voiceNames;
    command.(\setGrainParam, bufferVoice, \kill, 1);
    command.(\setVoiceParam, synthVoice, \kill, 1);
    server.sync; 0.3.wait;
    check.((engine.synths[grainKey] === grain) and: { grain.isPlaying } and: { engine.grainControls[bufferVoice][\kill].isNil }
        and: { engine.synths[voiceKey] === voiceSynth } and: { voiceSynth.isPlaying } and: { engine.voiceControls[synthVoice][\kill].isNil },
        "voices: setGrainParam and setVoiceParam refuse kill: the grain and voice synths play on (#458)");
    // (only where the engine took it: never again kill a synth it starts)
    engine.grainControls[bufferVoice].removeAt(\kill); engine.voiceControls[synthVoice].removeAt(\kill);
    otherEnvelope = engine.envBuffers.detect({ arg buffer; buffer.bufnum != envBuf }).bufnum;
    grainNames = [\gate, 1, \out, engine.voicePathBus(bufferVoice, slot + 1).index, \t_trig, 0,
        \bufnumL, engine.buffersL[slot].bufnum, \bufnumR, engine.buffersR[slot].bufnum, \bufFrames, engine.bufferFrames[slot],
        \bufRateScale, 1, \envBuf, otherEnvelope, \ringLevel, 1, \rateLevel, 1,
        \pan, engine.voiceControls[bufferVoice][\pan], \bend, engine.voiceControls[bufferVoice][\bend],
        \modBus1, engine.voiceControls[bufferVoice][\modBus1], \modFreqAmt1, engine.voiceControls[bufferVoice][\modFreqAmt1]];
    grainNames.pairsDo({ arg name, value; command.(\setGrainParam, bufferVoice, name, value) });
    voiceNames = [\gate, 1, \out, engine.granBuses[synthVoice].index, \t_trig, 0, \velocity, 1, \modAmpAmt1, 0.0001, \modFreqAmt1, 0.0001];
    voiceNames.pairsDo({ arg name, value; command.(\setVoiceParam, synthVoice, name, value) });
    server.sync;
    check.(unchanged.(engine.grainControls[bufferVoice], keptGrain, grainNames.clump(2).collect(_[0])),
        "voices: setGrainParam keeps none of gate, out, t_trig, the slot's controls, envBuf, ringLevel, rateLevel, pan, bend or the crossmod (#458; kept: %)".format(
            grainNames.clump(2).collect(_[0]).reject({ arg name; engine.grainControls[bufferVoice][name] == keptGrain[name] })));
    check.(unchanged.(engine.voiceControls[synthVoice], keptVoice, voiceNames.clump(2).collect(_[0])),
        "voices: setVoiceParam keeps none of gate, out, t_trig, velocity or the crossmod amounts (#458; kept: %)".format(
            voiceNames.clump(2).collect(_[0]).reject({ arg name; engine.voiceControls[synthVoice][name] == keptVoice[name] })));
    // (only where the engine took them)
    engine.grainControls[bufferVoice] = keptGrain; engine.voiceControls[synthVoice] = keptVoice;
    command.(\setGrainParam, bufferVoice, \envShape, engine.envBuffers.detectIndex({ arg buffer; buffer.bufnum == envBuf }) !? (_ + 1) ? 0);
    command.(\setModAmpAmt, synthVoice, 1, 0); command.(\setModFreqAmt, synthVoice, 1, 0);
    server.sync;
};

// A voice param a buffer voice's grain SynthDef lacks (the Ring voice's
// brightness) sends its grain synth nothing; one it has (pan) one /n_set
// with that control (#501). What the command sends is taken from a bundle
// it builds but does not send (makeBundle false), then sent as it was.
var checkVoiceParamSends = { arg voice;
    var grain = engine.synths[engine.grainKey(voice)];
    var nodeSets = { arg messages; messages.select({ arg msg; [15, '/n_set', "/n_set"].includesEqual(msg[0]) }) };
    var sent = server.makeBundle(false, { command.(\setVoiceParam, voice, \brightness, 0.7) }) ? [];
    var panSent;
    if (sent.notEmpty) { server.sendBundle(nil, *sent) };
    panSent = server.makeBundle(false, { command.(\setVoiceParam, voice, \pan, 0.0) }) ? [];
    if (panSent.notEmpty) { server.sendBundle(nil, *panSent) };
    server.sync;
    check.(nodeSets.(sent).isEmpty,
        "voices: setVoiceParam of a control the grain SynthDef lacks sends a buffer voice's grain synth nothing (#501; sent %)".format(sent));
    check.((nodeSets.(panSent).size == 1) and: { nodeSets.(panSent)[0].asArray == [15, grain.nodeID, \pan, 0.0] },
        "voices: setVoiceParam pan sends a buffer voice's grain synth one /n_set with pan (#501; sent %)".format(panSent));
};

// 3.5's note controls (design 3.5 §3.2, §3.5): noteGate (the own note's
// park), noteBend, noteAmp and noteMain in every voice SynthDef, and the
// ASR's times as the controls attackTime and releaseTime. Their defaults
// play 3.4's sound: the area's own output checks (the Resonator's level and
// ceiling, the subsonic block, the Pulse's res) and the other areas' pass
// unchanged with no tolerance widened, which is the audio proof (two voice
// synths never match sample for sample: every def draws random values)
var noteControlDefaults = (noteGate: 1, noteBend: 1, noteAmp: 1, noteMain: 0);
// each def's ASR times in 3.4 (design 3.5 §3.5)
var asrTimes34 = (strataResonator: [4, 8], strataFM: [5, 10], strataFolder: [3, 6], strataSub: [8, 12],
    strataPulse: [2, 4], strataKarplus: [0.01, 2], strataRing: [3, 5]);
var controlDefault = { arg defName, controlName;
    var control = SynthDescLib.global.at(defName).controls.detect({ arg each; each.name == controlName });
    control !? { control.defaultValue }
};
// a function true of a UGen input that is the named control of the def
var isControlOf = { arg defName, controlName;
    var control = SynthDescLib.global.at(defName).controls.detect({ arg each; each.name == controlName });
    { arg input; control.notNil and: { input.isKindOf(OutputProxy) } and: { input.source.isKindOf(Control) }
        and: { (input.source.specialIndex + input.outputIndex) == control.index } }
};
// true when input, or a UGen at most depth inputs above it, passes test
var reaches = { arg input, test, depth;
    test.(input) or: { (depth > 0) and: { input.isKindOf(UGen) } and: {
        (input.inputs ? []).any({ arg each; reaches.(each, test, depth - 1) }) } }
};
var noteSilent = { engine.silentBus.index };
// A private bus's peaks in windows after a reset (server time, so commands
// sent in timestamped bundles meet them exactly): for each [start, end) of
// windows (s after t_reset, four pairs), the peak of channel's |x|
var addNoteDefs = {
    SynthDef(\strataCheckNoteWindows, { arg in, out, t_reset = 0, channel = 0;
        var x = Select.ar(channel, In.ar(in, 2)).abs, reset = T2A.ar(t_reset), elapsed = Sweep.ar(reset, 1);
        var windows = \windows.kr(0 ! 8);
        Out.kr(out, 4.collect({ arg index;
            A2K.kr(Peak.ar(x * (elapsed >= windows[2 * index]) * (elapsed < windows[(2 * index) + 1]), reset)) }));
    }).add;
    // the peak of a bus's left channel and its upward zero crossings since t_reset
    SynthDef(\strataCheckNoteCount, { arg in, out, t_reset = 0;
        var x = In.ar(in, 2)[0], reset = T2A.ar(t_reset);
        Out.kr(out, A2K.kr([Peak.ar(x.abs, reset), PulseCount.ar(x > 0, reset)]));
    }).add;
    // what notePark computes, and its lowest and highest from the start
    if (engine.respondsTo(\notePark)) {
        SynthDef(\strataCheckNotePark, { arg out, noteGate = 1, attackTime = 0.05, releaseTime = 0.05;
            var park = engine.notePark(noteGate, attackTime, releaseTime);
            Out.kr(out, [park, RunningMin.kr(park), RunningMax.kr(park)]);
        }).add;
    };
    // a park's level latched at times after t_reset (server time): notePark,
    // and a check-only park that jumps (noteGate itself), which the ramp
    // check must reject
    [[\strataCheckNoteParkRamp, { arg noteGate, attackTime, releaseTime; engine.notePark(noteGate, attackTime, releaseTime) }],
        [\strataCheckNoteParkJump, { arg noteGate; noteGate }]].do({ arg pair;
        if (engine.respondsTo(\notePark)) {
            SynthDef(pair[0], { arg out, noteGate = 1, attackTime = 0.2, releaseTime = 0.2, t_reset = 0;
                var park = pair[1].value(noteGate, attackTime, releaseTime), elapsed = Sweep.kr(t_reset, 1);
                Out.kr(out, \times.kr([0.1, 0.4]).collect({ arg time; Latch.kr(park, elapsed >= time) }));
            }).add;
        };
    });
    // what noteMainValue computes for each def's entry of noteMainRanges
    if (engine.respondsTo(\noteMainValue) and: { engine.respondsTo(\noteMainRanges) }) {
        voiceDefs.do({ arg defName;
            SynthDef(("strataCheckNoteMain_" ++ defName).asSymbol, { arg out, value = 0, noteMain = 0;
                Out.kr(out, engine.noteMainValue(defName, value, noteMain));
            }).add;
        });
    };
    server.sync;
};
var startPrivate = { arg defName, bus, group, args;
    Synth(defName, [\out, bus, \modBus1, noteSilent.value, \modBus2, noteSilent.value, \modBus3, noteSilent.value] ++ args, group)
};

// "voices: every voice def plays 3.4's values with the note controls at
// their defaults": each def's note controls default to neutral values, and
// what they compute is exactly neutral on the server from the first block
// (the park 1, noteMainValue the control itself)
var checkNoteDefaults = {
    var bus = Bus.control(server, 3 + voiceDefs.size), group = Group.tail(server), values, mains;
    var defaults = voiceDefs.every({ arg defName;
        noteControlDefaults.keys.every({ arg name; controlDefault.(defName, name) == noteControlDefaults[name] })
    });
    var probes = engine.respondsTo(\notePark) and: { engine.respondsTo(\noteMainValue) };
    if (probes) {
        Synth(\strataCheckNotePark, [\out, bus.index, \attackTime, 4, \releaseTime, 8], group);
        voiceDefs.do({ arg defName, index;
            var entry = engine.noteMainRanges[defName];
            Synth(("strataCheckNoteMain_" ++ defName).asSymbol, [\out, bus.index + 3 + index,
                \value, controlDefault.(defName, entry[0]), \noteMain, 0], group);
        });
    };
    server.sync; 0.2.wait;
    values = h.readBus(bus);
    mains = if (probes) { voiceDefs.collect({ arg defName, index;
        (values[3 + index] - controlDefault.(defName, engine.noteMainRanges[defName][0])).abs }) } { [1] };
    check.(defaults and: { probes } and: { values.keep(3) == [1, 1, 1] } and: { mains.every({ arg error; error < 1e-6 }) },
        "voices: every voice def plays 3.4's values with the note controls at their defaults (defaults %, the park and its lowest and highest %, noteMainValue at noteMain 0 off its control by %)".format(
            defaults, values.keep(3), mains));
    group.free; bus.free;
    server.sync;
};

// The park (notePark: design 3.5 §3.2, ruling 4): 1 from the first block
// while noteGate is 1; at noteGate 0 down to 0 over the release, back to 1
// over the attack at noteGate 1, and ramping both ways, not jumping (at
// half its 0.2 s release and half its 0.2 s attack it is between 0.05 and
// 0.95: on the ASR's curve, -4, about 0.12 and 0.88; a check-only park that
// jumps reads 0 and 1 there and must fail); a synth started with noteGate 0
// is parked from its first block (a parked note's new synth); and no
// doneAction (the probe synth is still there)
var checkNotePark = {
    var name = "voices: the park is 1 from the first block at noteGate 1, ramps to 0 over its release and back over its attack, and starts parked at noteGate 0";
    var bus = Bus.control(server, 10), group = Group.tail(server), open, parked, down, up, startedParked, ramps, ramp, probes, ok;
    var ramped = { arg levels; levels.size == 2 and: { levels.every({ arg level; (level > 0.05) and: { level < 0.95 } }) } };
    if (engine.respondsTo(\notePark).not) { check.(false, name ++ " (no notePark)") } {
        open = Synth(\strataCheckNotePark, [\out, bus.index, \attackTime, 0.05, \releaseTime, 0.05], group);
        startedParked = Synth(\strataCheckNotePark, [\out, bus.index + 3, \noteGate, 0], group);
        ramps = [\strataCheckNoteParkRamp, \strataCheckNoteParkJump].collect({ arg defName, index;
            Synth(defName, [\out, bus.index + 6 + (2 * index)], group) });
        server.sync; 0.1.wait;
        parked = h.readBus(bus);
        open.set(\noteGate, 0); server.sync; 0.15.wait;
        down = h.readBus(bus)[0];
        open.set(\noteGate, 1); server.sync; 0.15.wait;
        up = h.readBus(bus)[0];
        // the ramps, in server time: parked with the reset, unparked 0.3 s
        // later; latched at 0.1 s (half the release) and 0.4 s (half the attack)
        server.makeBundle(0.2, { ramps.do(_.set(\noteGate, 0, \t_reset, 1)) });
        server.makeBundle(0.2 + 0.3, { ramps.do(_.set(\noteGate, 1)) });
        0.8.wait; server.sync;
        ramp = h.readBus(bus).drop(6).clump(2);
        // both park probes still there (no doneAction): the open one, parked
        // and unparked, and the one started parked
        probes = h.synthNames(group).occurrencesOf(\strataCheckNotePark);
        ok = (parked.keep(3) == [1, 1, 1]) and: { parked.drop(3).keep(3) == [0, 0, 0] } and: { down == 0 } and: { up == 1 }
            and: { ramped.(ramp[0]) } and: { ramped.(ramp[1]).not } and: { probes == 2 };
        check.(ok, name ++ " (open: value, lowest, highest %; started parked %; down %; up %; at half its release and half its attack %, a jumping park's %; park probes there %)".format(
            parked.keep(3), parked.drop(3).keep(3), down, up, ramp[0].collect({ arg level; level.round(0.0001) }), ramp[1], probes));
    };
    group.free; bus.free;
    server.sync;
};

// "voices: noteAmp 0.5 halves a voice synth's level and noteBend 2 doubles
// its frequency": Subs at 100 Hz with the least drift (0.001, a pitch
// wander of 0.1 %) and a 10 ms attack, on private buses: one at noteAmp
// 0.5 peaks at half the reference's (within 1e-3: one waveform, so one
// peak), one at noteBend 2 crosses zero upward as often as a reference at
// 200 Hz (within 2 in a second) and twice as often as the 100 Hz one
var checkNoteAmpBend = {
    var group = Group.tail(server), buses = 4.collect({ Bus.audio(server, 2) }), counts = Bus.control(server, 8), trackers, values;
    var base = [\freq, 100, \drift, 0.001, \amp, 0.4, \attackTime, 0.01];
    [base, base ++ [\noteAmp, 0.5], base ++ [\noteBend, 2], base ++ [\freq, 200]].do({ arg args, index;
        startPrivate.(\strataSub, buses[index], group, args) });
    trackers = buses.collect({ arg bus, index; Synth(\strataCheckNoteCount, [\in, bus, \out, counts.index + (2 * index)], group, \addToTail) });
    server.sync; 0.3.wait;
    server.makeBundle(nil, { trackers.do(_.set(\t_reset, 1)) });
    1.0.wait;
    values = h.readBus(counts).clump(2);
    check.((values[0][0] > 0.1) and: { ((values[1][0] / values[0][0]) - 0.5).abs < 1e-3 }
        and: { (values[2][1] - values[3][1]).abs <= 2 } and: { ((values[2][1] / values[0][1].max(1)) - 2).abs < 0.03 },
        "voices: noteAmp 0.5 halves a voice synth's level and noteBend 2 doubles its frequency (Sub: peaks %, upward zero crossings in 1 s %: reference, noteAmp 0.5, noteBend 2, 200 Hz)".format(
            values.collect({ arg each; each[0].round(0.0001) }), values.collect(_[1])));
    group.free; buses.do(_.free); counts.free;
    server.sync;
};

// "voices: noteGate 0 silences a voice synth within its release and leaves
// it running; noteGate 1 brings it back": a Pulse with releaseTime 0.05 and
// attackTime 0.1 (its ASR and its park take both), parked 0.3 s after a
// reset, silent (under 1e-4) from 0.15 s after, its node still there, and
// unparked at 0.7 s: above half its level by the end of its attack
var checkNoteGateVoice = {
    var group = Group.tail(server), bus = Bus.audio(server, 2), peaks = Bus.control(server, 4), pulse, tracker, values, there;
    pulse = startPrivate.(\strataPulse, bus, group, [\freq, 250, \amp, 0.3, \attackTime, 0.1, \releaseTime, 0.05]);
    tracker = Synth(\strataCheckNoteWindows, [\in, bus, \out, peaks.index], group, \addToTail);
    tracker.setn(\windows, [0, 0.3, 0.45, 0.65, 0.7, 0.8, 0.85, 1.0]);
    server.sync; 0.4.wait;
    server.makeBundle(0.2, { tracker.set(\t_reset, 1) });
    server.makeBundle(0.2 + 0.3, { pulse.set(\noteGate, 0) });
    server.makeBundle(0.2 + 0.7, { pulse.set(\noteGate, 1) });
    0.75.wait;                             // 0.55 s after the reset: parked
    there = h.synthNames(group).includes(\strataPulse);
    0.55.wait; server.sync;
    values = h.readBus(peaks);
    check.((values[0] > 0.01) and: { values[1] < 1e-4 } and: { there } and: { values[2] > (0.5 * values[0]) },
        "voices: noteGate 0 silences a voice synth within its release and leaves it running; noteGate 1 brings it back (Pulse, releaseTime 0.05: peak before %, 0.15-0.35 s after the park %, node there %, within the 0.1 s attack after %, after %)".format(
            values[0].round(0.0001), values[1], there, values[2].round(0.0001), values[3].round(0.0001)));
    group.free; bus.free; peaks.free;
    server.sync;
};

// "voices: attackTime 0.01 brings the Resonator to nine tenths of its level
// within 0.1 s": a Resonator at the extremes, hard right (its limiter holds
// the right channel at about its level, 0.9-1.05, whatever the noise: the
// level check below), with attackTime 0.01 and releaseTime 0.5. Its gate goes
// to 0 0.3 s after a reset (the release has it under half its level 0.15-0.2
// s later) and back to 1 at 0.5 s: within 0.1 s it is back at nine tenths of
// the level before (the 3.4 attack of 4 s would be about a quarter)
var checkNoteAttack = {
    var group = Group.tail(server), bus = Bus.audio(server, 2), peaks = Bus.control(server, 4), modBus = Bus.control(server, 1);
    var resonator, tracker, values;
    modBus.set(1);
    resonator = Synth(\strataResonator, [\out, bus, \freq, 20, \rq, 0.01, \noise, 1, \amp, 1, \pan, 1,
        \modBus1, modBus.index, \modBus2, noteSilent.value, \modBus3, noteSilent.value, \modAmpAmt1, 2,
        \attackTime, 0.01, \releaseTime, 0.5], group);
    tracker = Synth(\strataCheckNoteWindows, [\in, bus, \out, peaks.index, \channel, 1], group, \addToTail);
    tracker.setn(\windows, [0, 0.3, 0.45, 0.5, 0.5, 0.6, 0.6, 0.9]);
    server.sync; 1.5.wait;
    server.makeBundle(0.2, { tracker.set(\t_reset, 1) });
    server.makeBundle(0.2 + 0.3, { resonator.set(\gate, 0) });
    server.makeBundle(0.2 + 0.5, { resonator.set(\gate, 1) });
    1.2.wait; server.sync;
    values = h.readBus(peaks);
    check.((values[0] > 0.5) and: { values[1] < (0.5 * values[0]) } and: { values[2] >= (0.9 * values[0]) },
        "voices: attackTime 0.01 brings the Resonator to nine tenths of its level within 0.1 s (right channel peaks: before %, in the release %, 0.1 s after the gate %, after %)".format(
            *values.collect({ arg value; value.round(0.0001) })));
    group.free; bus.free; peaks.free; modBus.free;
    server.sync;
};

// "voices: the default attack and release are each def's times of 3.4":
// attackTime and releaseTime default to them, and the ASR (the EnvGen that
// frees the synth) takes its times from both, clipped to attackTimeRange
// and releaseTimeRange (0.005-30 and 0.01-30 s), as every def's
// voiceEnvelope does
var checkNoteTimes = {
    var attackRange = engine.tryPerform(\attackTimeRange) ? [nil, nil], releaseRange = engine.tryPerform(\releaseTimeRange) ? [nil, nil];
    var found = voiceDefs.collect({ arg defName;
        var ugens = SynthDescLib.global.at(defName).def.children;
        var isAttack = isControlOf.(defName, \attackTime), isRelease = isControlOf.(defName, \releaseTime);
        var clipOf = { arg test, low, high; { arg input; input.isKindOf(Clip) and: { test.(input.inputs[0]) }
            and: { input.inputs[1] == low } and: { input.inputs[2] == high } } };
        var asr = ugens.detect({ arg ugen; ugen.isKindOf(EnvGen) and: { ugen.inputs[4] == 2 }
            and: { ugen.inputs.any(clipOf.(isAttack, attackRange[0], attackRange[1])) }
            and: { ugen.inputs.any(clipOf.(isRelease, releaseRange[0], releaseRange[1])) } });
        var defaults = [controlDefault.(defName, \attackTime), controlDefault.(defName, \releaseTime)];
        [defName, defaults, asr.notNil]
    });
    check.((attackRange.asArray == [0.005, 30]) and: { releaseRange.asArray == [0.01, 30] }
        and: { found.every({ arg each; each[2] and: { [each[1], asrTimes34[each[0]]].flop.every({ arg pair;
            pair[0].notNil and: { pair[0].equalWithPrecision(pair[1], 1e-6) } }) } }) },
        "voices: the default attack and release are each def's times of 3.4 (ranges %, %; defaults, and the ASR takes them: %)".format(
            attackRange, releaseRange, found));
};

// "voices: noteMain 1 puts each def's expression control at its range's
// end" (ruling 5: every voice def draws random values, so two synths never
// match and no def is proven by its audio). noteMainValue, the one formula
// every def calls, is proven on the server for each entry of
// noteMainRanges: from the range's middle, noteMain 1 gives hi, -1 lo and
// 0.5 the middle plus a quarter of the range; from either end, noteMain past
// it stays at the end (the clip); at noteMain 0 the value itself. Each def's
// use of it is proven by its graph: a Clip to the entry's lo and hi whose
// input reads both the def's expression control and noteMain
var checkNoteMain = {
    var ranges = engine.tryPerform(\noteMainRanges), cases, bus, group, values, expected, errors, graphs;
    if (ranges.isNil or: { engine.respondsTo(\noteMainValue).not }) {
        check.(false, "voices: noteMain 1 puts each def's expression control at its range's end (no noteMainRanges or noteMainValue)");
    } {
        // [value, noteMain, expected] from the entry's lo and hi
        cases = { arg low, high; var mid = (low + high) / 2;
            [[mid, 1, high], [mid, -1, low], [mid, 0.5, mid + ((high - low) / 4)], [high, 1, high], [low, -1, low],
                [mid, 0, mid], [high, -0.5, high - ((high - low) / 4)]] };
        bus = Bus.control(server, voiceDefs.size * 7);
        group = Group.tail(server);
        expected = List.new;
        voiceDefs.do({ arg defName, defIndex;
            var entry = ranges[defName];
            cases.(entry[1], entry[2]).do({ arg each, caseIndex;
                Synth(("strataCheckNoteMain_" ++ defName).asSymbol, [\out, bus.index + (defIndex * 7) + caseIndex,
                    \value, each[0], \noteMain, each[1]], group);
                expected.add(each[2]);
            });
        });
        server.sync; 0.2.wait;
        values = h.readBus(bus);
        errors = [values, expected].flop.collect({ arg pair; (pair[0] - pair[1]).abs });
        graphs = voiceDefs.collect({ arg defName;
            var entry = ranges[defName], ugens = SynthDescLib.global.at(defName).def.children;
            var isMain = isControlOf.(defName, \noteMain), isExpression = isControlOf.(defName, entry[0]);
            ugens.any({ arg ugen; ugen.isKindOf(Clip) and: { ugen.inputs[1] == entry[1] } and: { ugen.inputs[2] == entry[2] }
                and: { reaches.(ugen.inputs[0], isMain, 3) } and: { reaches.(ugen.inputs[0], isExpression, 2) }
                and: { ugens.any({ arg user; (user.inputs ? []).any({ arg input; input === ugen }) }) } })
        });
        check.((values.size == expected.size) and: { errors.every({ arg error; error < 1e-6 }) } and: { graphs.every(_ == true) },
            "voices: noteMain 1 puts each def's expression control at its range's end (noteMainValue on the server, largest error % over % cases; each def's graph clips noteMain's offset of its control to the range: %)".format(
                errors.maxItem, expected.size, [voiceDefs, graphs].flop));
        group.free; bus.free;
        server.sync;
    };
};

// "voices: in a grain def, velocity feeds only the accent's levelScale"
// (3.5: a grain def's note accent, t_accent at velocity; before 3.5 the
// grain defs had no velocity): the strict check above, and the EnvGen it
// scales is gated by t_accent
var checkGrainVelocity = {
    var found = grainDefs.collect({ arg defName;
        var ugens = SynthDescLib.global.at(defName).def.children;
        var isVelocity = isControlOf.(defName, \velocity), isAccent = isControlOf.(defName, \t_accent);
        [defName, velocityOnlyScalesAccents.(defName, false),
            ugens.any({ arg ugen; ugen.isKindOf(EnvGen) and: { isVelocity.(ugen.inputs[1]) } and: { isAccent.(ugen.inputs[0]) } })]
    });
    check.(found.every({ arg each; each[1] and: { each[2] } }),
        "voices: in a grain def, velocity feeds only the accent's levelScale (an EnvGen gated by t_accent: %)".format(found));
};

// SynthDefs
voiceDefs.do({ arg name;
    var controls = SynthDescLib.global.at(name).controlNames.collect(_.asSymbol);
    check.(controls.includes(\t_trig), "% has a t_trig control (C3)".format(name));
    check.(controls.includes(\velocity), "% has a velocity control for the accent".format(name));
    check.(controlFeedsAUGen.(name, \bend), "% has a bend control (MIDI pitchbend) that reaches its frequency".format(name));
    // EnvGen inputs: gate, levelScale, ...; the accent's levelScale is
    // the velocity control (sampled per trigger), not the constant 1
    check.(SynthDescLib.global.at(name).def.children.any({ arg ugen;
        ugen.isKindOf(EnvGen) and: { ugen.inputs[1].isKindOf(OutputProxy) }
    }), "% scales its accent envelope by velocity through levelScale".format(name));
});
voiceDefs.do({ arg name;
    check.(velocityOnlyScalesAccents.(name),
        "% uses velocity only as its accent's levelScale (no bare velocity multiplier)".format(name));
});
check.(SynthDescLib.global.at(\strataVoiceMix).notNil and: { velocityOnlyScalesAccents.(\strataVoiceMix) },
    "voices: velocity in strataVoiceMix feeds only EnvGen levelScale");
// A copy of the stage bent so velocity also scales the level directly: the check must fail it
SynthDef(\strataCheckBentVoiceMix, { arg out, t_trig = 0, velocity = 1;
    var accent = EnvGen.kr(Env.perc(0.005, 0.4), t_trig, levelScale: velocity);
    Out.ar(out, In.ar(0, 2) * (1 + accent) * velocity);
}).add;
server.sync;
check.(velocityOnlyScalesAccents.(\strataCheckBentVoiceMix, false).not, "voices: a bent copy of strataVoiceMix fails the velocity check");
checkKarplusMutants.value;

// 3.5's note controls, on synths of the area's own (private buses)
addNoteDefs.value;
checkNoteDefaults.value;
checkNotePark.value;
checkNoteTimes.value;
checkNoteMain.value;
checkGrainVelocity.value;
checkNoteAmpBend.value;
checkNoteGateVoice.value;
checkNoteAttack.value;

// Silent bus (I4)
silentIndex = engine.silentBus.index;
check.(silentIndex != context.amp_in_b[0].index and: { silentIndex != 0 },
    "silent bus is not control bus 0 / the input amplitude bus (I4)");
// ... and reads 0 where a freed control bus held another value (#504): a
// freed bus keeps its last value on the server, and only the engine's own
// silentBus.set(0) clears it. Every control bus the allocator holds free
// (the gaps below its top, and 256 from there) is set to 1, then a new
// engine is built on them; afterward they are set back to 0.
{
    var allocator = server.controlBusAllocator, ranges = List.new, cursor = allocator.pos, other, value, dirty;
    allocator.blocks.collect({ arg block; [block.start, block.size] }).sort({ arg a, b; a[0] < b[0] }).do({ arg block;
        if (block[0] > cursor) { ranges.add([cursor, block[0] - cursor]) };
        cursor = cursor.max(block[0] + block[1]);
    });
    ranges.add([cursor, 256]);
    ranges.do({ arg range; server.sendMsg('/c_fill', range[0], range[1], 1) });
    server.sync;
    other = h.startEngine;
    value = h.readBusValue(other.silentBus);
    dirty = ranges.any({ arg range; other.silentBus.index.inclusivelyBetween(range[0], range[0] + range[1] - 1) });
    check.(dirty and: { value == 0 },
        "voices: a new engine's silent bus reads 0 on a bus index that held 1 (index %, on a freed bus: %, reads %)".format(
            other.silentBus.index, dirty, value));
    h.freeEngine(other);
    server.sync;
    ranges.do({ arg range; server.sendMsg('/c_fill', range[0], range[1], 0) });
    server.sync;
}.value;

// Start every voice
h.startAllVoices;
check.(getControl.(engine.synths[\voice3], \freq) == 103.0, "voiceOn sets freq (C1)");
check.(getControl.(engine.synths[\voice0], \modBus1) == silentIndex,
    "voiceOn routes unused mod slots to the silent bus (I4)");

command.(\setModSource, 1, 2, 0);
server.sync;
check.(getControl.(engine.synths[\voice1], \modBus2) == engine.modBuses[0].index,
    "setModSource routes a slot to the source voice's mod bus");

// Pitchbend: bend is a voice-level control (voice synth; strataGrainBuf for a buffer source)
command.(\setVoiceParam, 0, \bend, 1.05);
command.(\setVoiceParam, 6, \bend, 0.95);
server.sync;
check.(getControl.(engine.synths[\voice0], \bend).equalWithPrecision(1.05), "setVoiceParam bend reaches voice0");
check.(getControl.(engine.synths[\grain6], \bend).equalWithPrecision(0.95),
    "setVoiceParam bend reaches a buffer-sourced voice's strataGrainBuf");
command.(\setVoiceParam, 0, \bend, 1.0);
command.(\setVoiceParam, 6, \bend, 1.0);

// retrigger clamps its velocity to 0-1 (MIDI sends velocity / 127)
command.(\retrigger, 3, 2.5); server.sync;
check.(getControl.(engine.synths[\voice3], \velocity) == 1, "retrigger clamps velocity above 1");
command.(\retrigger, 3, -0.5); server.sync;
check.(getControl.(engine.synths[\voice3], \velocity) == 0, "retrigger clamps velocity below 0");
command.(\retrigger, 3, 1.0);
command.(\setModSource, 1, 2, -1);
server.sync;
check.(getControl.(engine.synths[\voice1], \modBus2) == silentIndex,
    "setModSource -1 routes to the silent bus (I4)");
checkModSlots.(1);
checkEngineOwnedControls.(6, 2);
checkVoiceParamSends.(6);

// retrigger carries velocity to the voice synth (accent depth)
before = synthNames.(context.xg).size;
command.(\retrigger, 0, 0.5);
server.sync;
check.(getControl.(engine.synths[\voice0], \velocity) == 0.5, "retrigger sets velocity on the voice synth");
check.(synthNames.(context.xg).size == before, "a velocity retrigger creates no nodes");

checkResonatorCeiling.value;
checkResonatorLevel.value;
checkModGuard.value;

// retrigger never creates nodes (C3)
before = synthNames.(context.xg).size;
50.do({ arg count; command.(\retrigger, count % engine.numVoices, 1.0) });
server.sync;
after = synthNames.(context.xg).size;
check.(before == after, "50 retriggers create no nodes (% before, % after)".format(before, after));

// voiceOff twice, then commands to the stopped voice
command.(\voiceOff, 4);
command.(\voiceOff, 4);
command.(\setVoiceParam, 4, \width, 0.3);
command.(\retrigger, 4, 0.5);
command.(\setModSpeed, 4, 2.0);
check.(engine.synths[\voice4].isNil, "voiceOff forgets the stopped voice's synths");
// an index outside the voices, or not an integer, is ignored (#262), by
// every one of the ten voice commands (#504; voiceOn 1.5 is voice 1, below).
// Before #262 voiceOff raised for -1, numVoices and 99; 1.5 is here as a pin, so a non-integer index stays ignored.
// Nothing raises, and no node, tracked synth or kept value changes (the
// grain params: a stored one, envShape, the freeze area's freeze and
// history, a stage's filterFreq).
{
    var raised = 0, synthsBefore, enginesBefore, releasingBefore, keptBefore, freqBefore, kept;
    var releasingTotal = { engine.releasingSynths.inject(0, { arg sum, dict; sum + dict.size }) };
    var sorted = { arg dict; dict.keys.asArray.sort.collect({ arg key; [key, dict[key]] }) };
    var keptState = { [engine.voiceControls.collect(sorted), engine.grainControls.collect(sorted),
        engine.grainSource.copy, engine.modSpeeds.copy] };
    command.(\voiceOn, 0, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    server.sync;
    synthsBefore = synthNames.(context.xg).size;
    enginesBefore = engine.synths.size;
    releasingBefore = releasingTotal.value;
    keptBefore = keptState.value;
    [-1, engine.numVoices, 99, 1.5].do({ arg index;
        if (index != 1.5) { try { command.(\voiceOn, index, 220.0, 0.2, 0.0, 0.1, 10.0, 1.0) } { raised = raised + 1 } };
        try { command.(\voiceOff, index) } { raised = raised + 1 };
        try { command.(\retrigger, index, 1.0) } { raised = raised + 1 };
        try { command.(\setVoiceParam, index, \amp, 0.3) } { raised = raised + 1 };
        [[\grainSize, 0.2], [\envShape, 1], [\freeze, 1], [\history, 2.0], [\filterFreq, 900.0]].do({ arg pair;
            try { command.(\setGrainParam, index, pair[0], pair[1]) } { raised = raised + 1 };
        });
        try { command.(\setGrainSource, index, 3) } { raised = raised + 1 };
        try { command.(\setModSource, index, 1, 0) } { raised = raised + 1 };
        try { command.(\setModAmpAmt, index, 1, 0.5) } { raised = raised + 1 };
        try { command.(\setModFreqAmt, index, 1, 0.5) } { raised = raised + 1 };
        try { command.(\setModSpeed, index, 3.0) } { raised = raised + 1 };
    });
    server.sync;
    kept = keptState.value;
    // <= because a synth released above (voice 4) may free itself between the reads
    check.((raised == 0) and: { synthNames.(context.xg).size <= synthsBefore }
        and: { engine.synths.size == enginesBefore }
        and: { releasingTotal.value <= releasingBefore },
        "the ten voice commands ignore a voice index outside the voices (% raised)".format(raised));
    check.(kept == keptBefore,
        "the ten voice commands keep no value for a voice index outside the voices (#504; changed: %)".format(
            [\voiceControls, \grainControls, \grainSource, \modSpeeds].select({ arg name, index; kept[index] != keptBefore[index] })));
    // voiceOn converts its index first: 1.5 is voice 1 (running, so it takes the new freq)
    freqBefore = getControl.(engine.synths[\voice1], \freq);
    command.(\voiceOn, 1.5, 333.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    server.sync;
    check.((freqBefore != 333.0) and: { getControl.(engine.synths[\voice1], \freq) == 333.0 },
        "voiceOn 1.5 is voiceOn 1 (#504; voice 1 at % Hz, then %)".format(freqBefore, getControl.(engine.synths[\voice1], \freq)));
}.value;
checkSubsonic.value;
checkPulseRes.value;
h.stopAllVoices;
}
