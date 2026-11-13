// test/engine_check/grains.scd
// The grain stage: both grain SynthDefs' controls and UGens, a stopped
// voice's source choice, voiceOn for a buffer source, the grain params
// (pitch, mode, envelope shapes), triggered grains on a synth voice, and
// buffer- and input-sourced grains (pan, triggered mode, the grain end).
{ arg h;
var engine = h.engine, server = h.server, context = h.context;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var awaitReply = { arg condition, timeout = 5; h.awaitReply(condition, timeout) };
var synthNames = { arg group; h.synthNames(group) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var controlFeedsAUGen = { arg defName, controlName; h.controlFeedsAUGen(defName, controlName) };
var readBus = { arg bus; h.readBus(bus) };
var measure = { arg probe, bus, seconds = 0.3; h.measure(probe, bus, seconds) };
var writeTestFile = { arg path, sampleRate, frames, values; h.writeTestFile(path, sampleRate, frames, values) };
var grainDefs = h.grainDefs, scratchRoot = h.tempDir;
var before, envSamples, voicesStarted;
var probe, peakBus, readPeak, triggeredBus, continuousPeak, untriggeredPeak, triggeredPeak;

var controlDefault = { arg defName, controlName;
    var control = SynthDescLib.global.at(defName).controls.detect({ arg each; each.name == controlName });
    control !? { control.defaultValue }
};

// Buffer- and input-sourced voices, on a running voice on its synth source
// and an empty slot: the voice's pan places their grains (pan -1 left only,
// 1 right only), triggered grain mode fires one grain per retrigger and
// nothing without one (as for a synth voice), and a buffer grain never reads
// past the end of the slot's valid region. The grain synth writes to a
// private bus for the measurements.
var checkSourceGrains = { arg voice, slot;
    var grainKey = engine.grainKey(voice), privateBus = Bus.audio(server, 2), peakBus = Bus.control(server, 2);
    var group = Group.after(engine.processGroup), path = scratchRoot +/+ "source-grains.wav";
    var tone, probe, peaks, file, frames = server.sampleRate.asInteger;
    var toPrivate = { engine.synths[grainKey].set(\out, privateBus.index); server.sync };
    var toMain = { engine.synths[grainKey].set(\out, engine.voicePathBus(voice, engine.grainSource[voice]).index) };

    grainDefs.do({ arg name;
        check.(controlFeedsAUGen.(name, \pan), "% has a pan control that reaches a UGen".format(name));
    });
    // the synth source's grain synth never pans again (the voice synth does)
    command.(\setVoiceParam, voice, \pan, -1.0); server.sync;
    check.((getControl.(engine.synths[engine.voiceKey(voice)], \pan) == -1) and: { getControl.(engine.synths[grainKey], \pan) == 0 },
        "a synth-sourced voice's pan reaches its voice synth, never its grain synth");

    // a 1 s stereo 440 Hz sine at 0.5, at the server rate
    file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(server.sampleRate);
    file.openWrite(path);
    // one period: the frames holding a whole number of cycles
    file.writeData({ var sine = h.periodic((0 .. (frames div: frames.gcd(440)) - 1).collect({ arg frame;
        sin(2pi * 440 * frame / server.sampleRate) * 0.5 }), 0, frames);
        h.stereoOf(sine, sine) }.value);
    file.close;
    command.(\loadBuffer, slot, path, 0); 0.3.wait; server.sync;
    tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.voiceGroup, \addToHead);
    probe = Synth(\strataCheckChannelPeaks, [\in, privateBus, \out, peakBus], group);

    [[slot + 1, "a buffer"], [engine.numBuffers + 1, "an input"]].do({ arg pair;
        var label = pair[1];
        command.(\setVoiceParam, voice, \pan, -1.0);
        command.(\setGrainSource, voice, pair[0]); server.sync;
        toPrivate.value;
        check.(getControl.(engine.synths[grainKey], \pan) == -1, "%-sourced voice's grain synth starts at the voice's pan".format(label));
        [[-1.0, [true, false]], [1.0, [false, true]], [0.0, [true, true]]].do({ arg panCase;
            command.(\setVoiceParam, voice, \pan, panCase[0]); server.sync;
            peaks = measure.(probe, peakBus, 0.3);
            check.((peaks.size == 2) and: { [0, 1].every({ arg channel;
                    if (panCase[1][channel]) { peaks[channel] > 0.01 } { peaks[channel] < 0.001 } }) },
                "%-sourced voice at pan % sounds % (peaks %)".format(label, panCase[0],
                    ["left only", "right only", "on both sides"][[[true, false], [false, true], [true, true]].indexOfEqual(panCase[1])], peaks));
        });
        // triggered grain mode
        command.(\setGrainParam, voice, \grainMode, 1);
        0.5.wait; server.sync;                 // the grains in flight have ended
        peaks = measure.(probe, peakBus, 0.3);
        check.(peaks.sum < 0.001, "%-sourced voice in triggered mode is silent without a trigger (peaks %)".format(label, peaks));
        probe.set(\t_reset, 1); server.sync;
        command.(\retrigger, voice, 1.0);
        0.3.wait;
        peaks = readBus.(peakBus);
        check.(peaks.sum > 0.01, "a retrigger fires a grain on %-sourced voice in triggered mode (peaks %)".format(label, peaks));
        command.(\setGrainParam, voice, \grainMode, 0);
        toMain.value;
    });

    // Grain end: a slot of silence whose frames past the valid region hold 1
    // (set by hand after the load, which zeroes them). Grains scanning up to
    // the region's end, at a rate and size that read far past it unless
    // limited, must read silence only: at the server rate, at 22050 Hz and
    // rate 2, at 96 kHz (GrainBuf reads two frames per sample there: a limit
    // that left out the buffer's rate scale would read past the end), and
    // with a region shorter than a grain. [file rate, seconds, grain size, rate]
    command.(\setGrainSource, voice, slot + 1); server.sync;
    toPrivate.value;
    [[server.sampleRate, 0.25, 0.2, 1], [22050, 0.25, 0.2, 2], [96000, 0.25, 0.2, 1], [server.sampleRate, 0.05, 0.2, 1]].do({ arg grainCase;
        var validFrames;
        writeTestFile.(path, grainCase[0], (grainCase[0] * grainCase[1]).round.asInteger, [0, 0]);
        command.(\loadBuffer, slot, path, 0); 0.3.wait; server.sync;
        validFrames = engine.bufferFrames[slot];
        [engine.buffersL[slot], engine.buffersR[slot]].do({ arg buffer; buffer.fill(validFrames, buffer.numFrames - validFrames, 1) });
        command.(\setGrainParam, voice, \grainSize, grainCase[2]);
        command.(\setGrainParam, voice, \bufRate, grainCase[3]);
        command.(\setGrainParam, voice, \bufPos, 0.9);
        command.(\setGrainParam, voice, \bufScan, 0.5);
        server.sync; 0.3.wait;                 // grains started before the fill have ended
        peaks = measure.(probe, peakBus, 0.6);
        check.((peaks.size == 2) and: { peaks.maxItem < 0.001 },
            "grains never read past the valid region (% s at % Hz, grain % s, rate %; peaks %)".format(
                grainCase[1], grainCase[0], grainCase[2], grainCase[3], peaks));
    });
    toMain.value;
    [[\grainSize, 0.1], [\bufRate, 1], [\bufPos, 0], [\bufScan, 0]].do({ arg pair; command.(\setGrainParam, voice, *pair) });
    command.(\setVoiceParam, voice, \pan, 0.0);
    command.(\clearBuffer, slot);
    command.(\setGrainSource, voice, 0);
    tone.free; group.free;
    2.5.wait; server.sync;
    privateBus.free; peakBus.free;
    File.delete(path);
};

// 3.5's note controls in both grain SynthDefs (design 3.5 §3.2): noteGate
// (the park, 0.1 s up, grainRelease down), noteBend (on the grain rate,
// outside rateLevel), noteAmp and the note's accent (t_accent at velocity)
// on the fade, notePos and noteSize added to the fast offsets, and in
// \strataGrainRing noteRate on pitchShift before quantize. The checks below
// play pairs of real grain synths started in one bundle (every draw off, so
// two synths of one def with the same controls play the same samples): one
// with a note control, one with the base control it should equal
var noteNeutral = (noteGate: 1, noteBend: 1, noteAmp: 1, notePos: 0, noteSize: 0, velocity: 1, t_accent: 0);
var noteSlot = 5, noteVoice = 0, notePath = scratchRoot +/+ "grains-note-noise.wav";
var silentFastIn = { engine.areaState[\modulation][\silentFastModBus].index };
// a ring grain synth's controls on a voice's ring (as its synth source's:
// rateLevel 0), or a buffer grain synth's on a slot, every draw off, then extra
var noteRingArgs = { arg outBus, extra;
    var ring = engine.ringBuffersFor(noteVoice, 0);
    [\out, outBus.index, \bufL, ring[0].bufnum, \bufR, ring[1].bufnum, \phaseBus, ring[2].index, \grainSize, 0.1, \grainDensity, 20,
        \pitchShift, 1, \posSpread, 0, \panSpread, 0, \rateLevel, 0, \pan, 0, \fastModIn, silentFastIn.value] ++ (extra ? [])
};
var noteBufArgs = { arg outBus, extra;
    [\out, outBus.index, \bufnumL, engine.buffersL[noteSlot].bufnum, \bufnumR, engine.buffersR[noteSlot].bufnum,
        \bufFrames, engine.bufferFrames[noteSlot], \bufRateScale, engine.bufferRateScale(noteSlot), \bufPos, 0.3,
        \grainSize, 0.1, \grainDensity, 20, \pitchShift, 1, \posSpread, 0, \panSpread, 0, \pan, 0,
        \fastModIn, silentFastIn.value] ++ (extra ? [])
};
// a slot of noise at the server rate (a grain's place and rate show in what it reads)
var loadNoteSlot = {
    var rate = server.sampleRate.round.asInteger;
    var file = SoundFile.new.headerFormat_("WAV").sampleFormat_("int16").numChannels_(2).sampleRate_(rate);
    file.openWrite(notePath);
    file.writeData(h.stereoOf(h.noise(rate, 0.5), h.noise(rate, 0.4)));
    file.close;
    command.(\loadBuffer, noteSlot, notePath, 0);
    h.waitFor({ engine.bufferFrames[noteSlot] == rate }, 3);
    server.sync;
};
// The largest |a - scale x b x (1 + accent)| and the largest |b| since
// t_reset (accent: the engine's own voiceAccent, fired by t_accent at
// velocity, as a grain synth's note accent is)
var addNoteDiff = {
    SynthDef(\strataCheckNoteDiff, { arg a, b, out, scale = 1, t_reset = 0, t_accent = 0, velocity = 0;
        var x = In.ar(a, 2), y = In.ar(b, 2) * scale * (1 + engine.voiceAccent(t_accent, velocity)), reset = T2A.ar(t_reset);
        Out.kr(out, [A2K.kr(Peak.ar((x - y).abs.sum, reset)), A2K.kr(Peak.ar(y.abs.sum, reset))]);
    }).add;
    // a bus's peaks in windows after a reset: for each [start, end) of
    // windows (s after t_reset, four pairs), the peak of |x| (both channels)
    SynthDef(\strataCheckNoteGrainWindows, { arg in, out, t_reset = 0;
        var x = In.ar(in, 2).abs.sum, reset = T2A.ar(t_reset), elapsed = Sweep.ar(reset, 1), windows = \windows.kr(0 ! 8);
        Out.kr(out, 4.collect({ arg index;
            A2K.kr(Peak.ar(x * (elapsed >= windows[2 * index]) * (elapsed < windows[(2 * index) + 1]), reset)) }));
    }).add;
    server.sync;
};
// [difference, level] of a pair started in one bundle: defName with argsA
// on outA, with argsB on outB, measured 0.3 s after the start for 0.5 s
var notePair = { arg defName, argsA, argsB, scale = 1, defNameB;
    var group = Group.after(engine.processGroup), outA = Bus.audio(server, 2), outB = Bus.audio(server, 2);
    var peaks = Bus.control(server, 2), diff, result;
    diff = Synth(\strataCheckNoteDiff, [\a, outA, \b, outB, \out, peaks, \scale, scale], group, \addToTail);
    server.makeBundle(nil, { [[defName, argsA.(outA)], [defNameB ? defName, argsB.(outB)]].do({ arg each;
        Synth(each[0], each[1], group, \addToHead) }) });
    server.sync; 0.3.wait;
    result = measure.(diff, peaks, 0.5);
    group.free; server.sync;
    [outA, outB, peaks].do(_.free);
    result
};
// a pair's result as "[difference, level]"
var showPair = { arg pair; pair.round(1e-7) };
var pairMatches = { arg pair, tolerance = 1e-6; (pair[1] > 0.01) and: { pair[0] < (pair[1] * tolerance) } };

// "grains: both grain defs play 3.4's values with the note controls at
// their defaults": the controls default to neutral (the park open, no
// bend, gain 1, no offset, no accent, noteRate 1). The audio proof is the
// equality checks other areas run on the real defs, unchanged: the
// modulation area's against check-only copies of 3.3's defs within 1e-6
// and the mix area's against 3.2's
var checkNoteDefaults = {
    var found = grainDefs.collect({ arg name;
        var names = noteNeutral.keys.asArray ++ (if (name == \strataGrainRing) { [\noteRate] } { [] });
        [name, names.reject({ arg control; controlDefault.(name, control) == (noteNeutral[control] ? 1) })]
    });
    check.(found.every({ arg each; each[1].isEmpty }),
        "grains: both grain defs play 3.4's values with the note controls at their defaults (controls missing or not neutral: %)".format(found));
};

// "grains: noteAmp, notePos, noteSize and noteBend act on one grain synth"
// (each pair against the base control it moves; a moved size is a float32
// sum, so within 1 % as the modulation area's size offset)
var checkNoteActs = {
    var results = [
        // noteAmp 0.5: half the level, on both defs
        [\amp, notePair.(\strataGrainBuf, { arg out; noteBufArgs.(out, [\noteAmp, 0.5]) }, { arg out; noteBufArgs.(out) }, 0.5), 1e-6],
        [\ampRing, notePair.(\strataGrainRing, { arg out; noteRingArgs.(out, [\noteAmp, 0.5]) }, { arg out; noteRingArgs.(out) }, 0.5), 1e-6],
        // notePos 0.5 at bufPos 0.25: grains at 0.5 of the region
        [\pos, notePair.(\strataGrainBuf, { arg out; noteBufArgs.(out, [\bufPos, 0.25, \notePos, 0.5]) },
            { arg out; noteBufArgs.(out, [\bufPos, 0.5]) }), 1e-6],
        // noteSize 1 at grainSize 0.1: grains of 0.345 s
        [\size, notePair.(\strataGrainBuf, { arg out; noteBufArgs.(out, [\noteSize, 1]) },
            { arg out; noteBufArgs.(out, [\grainSize, 0.345]) }), 1e-2],
        // noteBend 2: twice the read rate (bufRate 2), quantize on in both
        [\bend, notePair.(\strataGrainBuf, { arg out; noteBufArgs.(out, [\noteBend, 2, \pitchShift, 1.03, \quantize, 1]) },
            { arg out; noteBufArgs.(out, [\bufRate, 2, \pitchShift, 1.03, \quantize, 1]) }), 1e-6]
    ];
    // ... and each control does something: its pair against the unmoved synth differs
    var moved = notePair.(\strataGrainBuf, { arg out; noteBufArgs.(out, [\bufPos, 0.25, \notePos, 0.5]) },
        { arg out; noteBufArgs.(out, [\bufPos, 0.25]) });
    check.(results.every({ arg each; pairMatches.(each[1], each[2]) }) and: { pairMatches.(moved).not },
        "grains: noteAmp, notePos, noteSize and noteBend act on one grain synth ([difference, level] against the moved control: %; notePos against none %)".format(
            results.collect({ arg each; "% %".format(each[0], showPair.(each[1])) }).join(", "), showPair.(moved)));
};

// "grains: noteRate 2 doubles a ring grain's rate and is quantized with
// pitchShift": noteRate 2 plays as pitchShift 2; with quantize on, noteRate
// 1.5 plays as pitchShift 1.5 quantized (7 semitones), so noteRate
// multiplies pitchShift before quantize (after it, the rate would be 1.5
// itself, which the unquantized reference shows differs)
var checkNoteRate = {
    var doubled = notePair.(\strataGrainRing, { arg out; noteRingArgs.(out, [\noteRate, 2]) }, { arg out; noteRingArgs.(out, [\pitchShift, 2]) });
    var quantized = notePair.(\strataGrainRing, { arg out; noteRingArgs.(out, [\noteRate, 1.5, \quantize, 1]) },
        { arg out; noteRingArgs.(out, [\pitchShift, 1.5, \quantize, 1]) });
    var unquantized = notePair.(\strataGrainRing, { arg out; noteRingArgs.(out, [\noteRate, 1.5, \quantize, 1]) },
        { arg out; noteRingArgs.(out, [\pitchShift, 1.5]) });
    check.(pairMatches.(doubled) and: { pairMatches.(quantized) } and: { pairMatches.(unquantized).not },
        "grains: noteRate 2 doubles a ring grain's rate and is quantized with pitchShift ([difference, level]: noteRate 2 against pitchShift 2 %, noteRate 1.5 quantized against pitchShift 1.5 quantized %, against 1.5 unquantized %)".format(
            showPair.(doubled), showPair.(quantized), showPair.(unquantized)));
};

// "grains: noteBend acts on a synth-source grain synth, where bend does
// not": at rateLevel 0, noteBend 2 plays as pitchShift 2, and bend 2 as no bend
var checkNoteBendSynthSource = {
    var noteBend = notePair.(\strataGrainRing, { arg out; noteRingArgs.(out, [\noteBend, 2]) }, { arg out; noteRingArgs.(out, [\pitchShift, 2]) });
    var bend = notePair.(\strataGrainRing, { arg out; noteRingArgs.(out, [\bend, 2]) }, { arg out; noteRingArgs.(out) });
    check.(pairMatches.(noteBend) and: { pairMatches.(bend) },
        "grains: noteBend acts on a synth-source grain synth, where bend does not ([difference, level]: noteBend 2 against pitchShift 2 %, bend 2 against none %)".format(
            showPair.(noteBend), showPair.(bend)));
};

// "grains: t_accent at velocity 1 doubles a grain synth's level for the
// accent's length": a buffer grain synth accented (t_accent at velocity 1)
// plays as its unaccented twin times 1 + the accent (the voices' and the
// stage's envelope, voiceAccent: up in 5 ms, which a control-rate envelope
// ends at 0.8 after its whole blocks, down over 0.4 s), so twice the level
// at its height (1.7-2 times from 4 to 12 ms), and as the twin from 0.5 s
var checkNoteAccent = {
    var group = Group.after(engine.processGroup), outA = Bus.audio(server, 2), outB = Bus.audio(server, 2);
    var peaks = Bus.control(server, 2), windows = Bus.control(server, 8), synths, diff, trackers, model, levels;
    diff = Synth(\strataCheckNoteDiff, [\a, outA, \b, outB, \out, peaks], group, \addToTail);
    trackers = [outA, outB].collect({ arg bus, index;
        Synth(\strataCheckNoteGrainWindows, [\in, bus, \out, windows.index + (4 * index)], group, \addToTail) });
    trackers.do(_.setn(\windows, [0.004, 0.012, 0.5, 0.8, 0, 0, 0, 0]));
    server.makeBundle(nil, { synths = [outA, outB].collect({ arg bus; Synth(\strataGrainBuf, noteBufArgs.(bus), group, \addToHead) }) });
    server.sync; 0.3.wait;
    server.makeBundle(0.2, {
        synths[0].set(\velocity, 1, \t_accent, 1);
        diff.set(\velocity, 1, \t_accent, 1, \t_reset, 1);
        trackers.do(_.set(\t_reset, 1));
    });
    0.2.wait; 0.45.wait;
    model = h.readBus(peaks);
    0.4.wait; server.sync;
    levels = h.readBus(windows).clump(4);
    check.(pairMatches.(model, 1e-5) and: { (levels[0][0] / levels[1][0].max(1e-9)).inclusivelyBetween(1.7, 2.0) }
        and: { (levels[0][1] - levels[1][1]).abs < (levels[1][1] * 1e-6) } and: { levels[1][1] > 0.01 },
        "grains: t_accent at velocity 1 doubles a grain synth's level for the accent's length (against its twin times 1 + the accent over 0.45 s: [difference, level] %; level over the twin's at 4-12 ms %; peaks 0.5-0.8 s after %, %)".format(
            showPair.(model), (levels[0][0] / levels[1][0].max(1e-9)).round(0.001), levels[0][1].round(0.0001), levels[1][1].round(0.0001)));
    group.free; server.sync;
    [outA, outB, peaks, windows].do(_.free);
};

// "grains: noteGate parks a grain synth and its scan keeps running": two
// buffer grain synths scanning the slot (bufScan 0.5), one parked 0.3 s
// after a reset: silent (under 1e-4) once its release (grainRelease) is
// over, its node still there; unparked at 2.6 s, it plays as its twin, never
// parked, from 0.3 s after (the park's 0.1 s attack): its scan ran on
// while it was parked (stopped, it would read 1.15 region lengths behind)
var checkNotePark = {
    var group = Group.after(engine.processGroup), outA = Bus.audio(server, 2), outB = Bus.audio(server, 2);
    var peaks = Bus.control(server, 2), windows = Bus.control(server, 4), synths, diff, tracker, there, silent, after;
    var release = engine.grainRelease, unpark = 0.3 + release + 0.3;
    diff = Synth(\strataCheckNoteDiff, [\a, outA, \b, outB, \out, peaks], group, \addToTail);
    tracker = Synth(\strataCheckNoteGrainWindows, [\in, outA, \out, windows.index], group, \addToTail);
    tracker.setn(\windows, [0.3 + release + 0.05, unpark, 0, 0, 0, 0, 0, 0]);
    server.makeBundle(nil, { synths = [outA, outB].collect({ arg bus; Synth(\strataGrainBuf, noteBufArgs.(bus, [\bufScan, 0.5]), group, \addToHead) }) });
    server.sync; 0.3.wait;
    server.makeBundle(0.2, { tracker.set(\t_reset, 1) });
    server.makeBundle(0.2 + 0.3, { synths[0].set(\noteGate, 0) });
    server.makeBundle(0.2 + unpark, { synths[0].set(\noteGate, 1) });
    server.makeBundle(0.2 + unpark + 0.3, { diff.set(\t_reset, 1) });
    (0.2 + 0.3 + release + 0.1).wait;
    there = h.synthTree(group).count({ arg node; node[\def] == \strataGrainBuf }) == 2;
    (unpark - (0.3 + release + 0.1) + 0.3 + 0.5).wait;
    after = h.readBus(peaks);
    silent = h.readBus(windows)[0];
    check.((silent < 1e-4) and: { there } and: { pairMatches.(after) },
        "grains: noteGate parks a grain synth and its scan keeps running (parked: peak % after its % s release, both nodes there %; unparked, against its twin: [difference, level] %)".format(
            silent, release, there, showPair.(after)));
    group.free; server.sync;
    [outA, outB, peaks, windows].do(_.free);
};

// SynthDefs
grainDefs.do({ arg name;
    [\grainMode, \t_trig, \bend, \envBuf].do({ arg control;
        check.(SynthDescLib.global.at(name).controlNames.collect(_.asSymbol).includes(control),
            "% has a % control".format(name, control));
    });
});
// Both grain SynthDefs take the frequency crossmod and pan switches (the
// voice-level gain, the mirror and the accent are the voice's stage: the mix area)
grainDefs.do({ arg name;
    [\modBus1, \modBus2, \modBus3, \modFreqAmt1, \modFreqAmt2, \modFreqAmt3, \bend, \rateLevel].do({ arg control;
        check.(controlFeedsAUGen.(name, control), "% has a % control that reaches a UGen".format(name, control));
    });
    check.(controlDefault.(name, \rateLevel) == 1, "%'s rateLevel defaults to 1".format(name));
});
[\out, \gate, \bufnumL, \bufnumR, \bufFrames, \bufPos, \bufRate, \bufScan, \grainSize, \grainDensity,
    \pitchShift, \posSpread, \panSpread, \modBus1, \modBus2, \modBus3, \modFreqAmt1, \modFreqAmt2, \modFreqAmt3].do({ arg control;
    check.(SynthDescLib.global.at(\strataGrainBuf).controlNames.collect(_.asSymbol).includes(control),
        "strataGrainBuf has a % control".format(control));
});
check.(SynthDescLib.global.at(\strataGrainBuf).controlNames.collect(_.asSymbol).includes(\bufRateScale),
    "strataGrainBuf has a bufRateScale control (content rate / server rate)");
[\bufL, \bufR, \phaseBus, \history].do({ arg control;
    check.(controlFeedsAUGen.(\strataGrainRing, control), "strataGrainRing has a % control that reaches a UGen".format(control));
});
// "grains: both grain defs declare every 3.2 control", with defaults that
// keep 3.1's sound (the ring def adds bufL, bufR and phaseBus, above)
check.(grainDefs.every({ arg name;
    var defaults = [[\bufScan, 0], [\history, 0], [\ringLevel, 1], [\rateLevel, 1], [\freeze, 0], [\freezeMode, 0], [\reverseProb, 0],
        [\pitchJitter, 0], [\panJitter, 0], [\sizeJitter, 0]]
    ++ (1..8).collect({ arg index; [("interval" ++ index).asSymbol, 0] })
    ++ [[\intervalCount, 0], [\intervalProb, 1], [\quantize, 0], [\scaleNote, 60], [\loopStart, 0], [\loopLength, 1]];
    defaults.every({ arg pair; controlDefault.(name, pair[0]) == pair[1] })
}), "grains: both grain defs declare every 3.2 control");
// "grains: the hook methods exist": the areas that fill them later
// (variation, loop, freeze, mix) keep these names
check.([\grainRate, \grainPan, \grainDur, \slotGrainPos, \scanRate, \ringScanOffset, \freezeVoice, \unfreezeVoice, \voiceOutput, \voiceFilter]
    .every({ arg method; engine.respondsTo(method) }), "grains: the hook methods exist");
// Both: two stereo GrainBufs (one per channel buffer, panned -1 and +1, so
// the pair stays sample-aligned), Balance2 for the pan wander, the trigger
// selected by grainMode, and one stereo Out, the path of its source
grainDefs.do({ arg name;
    var ugens = SynthDescLib.global.at(name).def.children;
    var grainBufs = ugens.select({ arg ugen; ugen.isKindOf(GrainBuf) });
    check.((grainBufs.size == 2) and: { grainBufs.every({ arg ugen; ugen.channels.size == 2 }) },
        "% runs two stereo GrainBufs, one per channel buffer (got %)".format(name, grainBufs.size));
    check.(ugens.any({ arg ugen; ugen.isKindOf(Balance2) }), "% pans with Balance2".format(name));
    check.(ugens.any({ arg ugen; ugen.isKindOf(Select) }) and: { ugens.any({ arg ugen; ugen.isKindOf(T2A) }) },
        "% selects between Impulse and T2A(t_trig) grain triggers".format(name));
    check.(ugens.select({ arg ugen; ugen.isKindOf(Out) }).collect({ arg ugen; ugen.inputs.size - 1 }) == [2],
        "% has one stereo Out, its source's path (got %)".format(name,
            ugens.select({ arg ugen; ugen.isKindOf(Out) }).collect({ arg ugen; ugen.inputs.size - 1 })));
});
// "grains: sources 0 and 9 build strataGrainRing, 1-8 strataGrainBuf" (a stopped voice)
check.((0..engine.inputSource).every({ arg source;
    var expected = if (source.inclusivelyBetween(1, engine.numBuffers)) { \strataGrainBuf } { \strataGrainRing };
    command.(\setGrainSource, 5, source);
    engine.grainDefFor(5) == expected
}), "grains: sources 0 and 9 build strataGrainRing, 1-8 strataGrainBuf");
command.(\setGrainSource, 5, 0);


// setGrainSource on a stopped voice only records the source
before = synthNames.(context.xg).size;
command.(\setGrainSource, 6, 4);
server.sync;
check.(synthNames.(context.xg).size == before and: { engine.grainSource[6] == 4 },
    "setGrainSource on a stopped voice records the source and creates no nodes");

// Start every voice
h.startAllVoices;
voicesStarted = Main.elapsedTime;
check.(engine.synths[\voice6].isNil and: { engine.synths[\grain6].defName == \strataGrainBuf },
    "voiceOn for a buffer-sourced voice builds strataGrainBuf and no voice synth");
check.(getControl.(engine.synths[\grain6], \bufnumL) == engine.buffersL[3].bufnum
    and: { getControl.(engine.synths[\grain6], \bufnumR) == engine.buffersR[3].bufnum },
    "source 4 reads slot 4 (index 3)");
check.(getControl.(engine.synths[\grain6], \grainSize).equalWithPrecision(0.1), "voiceOn grain args reach strataGrainBuf");
check.((engine.synths[\grain0].defName == \strataGrainRing)
    and: { [[\pan, 0], [\rateLevel, 0]].every({ arg pair;
        getControl.(engine.synths[\grain0], pair[0]) == pair[1] }) }
    and: { getControl.(engine.synths[\grain0], \bufL) == engine.ringBuffersFor(0, 0)[0].bufnum }
    and: { getControl.(engine.synths[\grain0], \phaseBus) == engine.ringBuffersFor(0, 0)[2].index },
    "grains: the synth-source grain synth keeps pan 0 and rateLevel 0 (and reads its voice's ring)");

command.(\setGrainParam, 0, \pitchShift, 2.0);
command.(\setGrainParam, 0, \posSpread, 0.7);
server.sync;
check.(getControl.(engine.synths[\grain0], \pitchShift) == 2.0, "setGrainParam pitchShift reaches the grain synth");

// Grain mode: 0 = continuous (Impulse), 1 = triggered (one grain per t_trig)
check.(getControl.(engine.synths[\grain0], \grainMode) == 0, "grain synths start continuous");
command.(\setGrainParam, 0, \grainMode, 1);
server.sync;
check.(getControl.(engine.synths[\grain0], \grainMode) == 1, "setGrainParam grainMode reaches the grain synth");
command.(\setGrainParam, 0, \grainMode, 0);

// Grain envelope shapes: envShape 0 = built-in Hann (-1), 1-4 = envBuffers
check.(engine.envBuffers.size == 4, "four grain envelope buffers");
check.(engine.envBuffers.every({ arg buffer; buffer.numFrames == 1024 }),
    "envelope buffers hold 1024 frames");
envSamples = { var condition = Condition(false), values;
    engine.envBuffers[3].loadToFloatArray(action: { arg array;
        values = array; condition.test = true; condition.signal });
    awaitReply.(condition);
    values
}.value;
check.((envSamples[0].abs < 0.01) and: { (envSamples[512] - 1).abs < 0.01 },
    "trapezoid envelope buffer is loaded on the server (0 at the start, 1 in the middle)");
check.(getControl.(engine.synths[\grain0], \envBuf) == -1, "grain synths start with the Hann envelope");
command.(\setGrainParam, 0, \envShape, 2);
server.sync;
check.(getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[1].bufnum,
    "envShape 2 selects the second envelope buffer");
command.(\setGrainParam, 0, \envShape, 4);
server.sync;
check.(getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[3].bufnum,
    "envShape 4 selects the last envelope buffer");
command.(\setGrainParam, 0, \envShape, 0);
server.sync;
check.(getControl.(engine.synths[\grain0], \envBuf) == -1, "envShape 0 returns to the Hann envelope");
command.(\setGrainParam, 0, \envShape, 1);
command.(\setGrainParam, 0, \envShape, 9);
command.(\setGrainParam, 0, \envShape, -1);
server.sync;
check.(getControl.(engine.synths[\grain0], \envBuf) == engine.envBuffers[0].bufnum,
    "an out-of-range envShape is ignored");

// Triggered grain mode on a running synth voice (voice 0, its
// resonator long past its attack): no grain and no position-spread
// sound without a trigger, one grain after a retrigger. Its grain
// synth writes to a private bus for the measurement.
max(4.5 - (Main.elapsedTime - voicesStarted), 0).wait;   // past the Resonator's 4 s attack
triggeredBus = Bus.audio(server, 2);
peakBus = Bus.control(server, 1);
engine.synths[\grain0].set(\out, triggeredBus.index);
probe = Synth(\strataCheckPeak, [\in, triggeredBus, \out, peakBus], engine.processGroup, \addToTail);
readPeak = {
    var condition = Condition(false), value;
    probe.set(\t_reset, 1);
    0.3.wait;
    peakBus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
};
server.sync;
0.1.wait;                                  // let the grains reach the private bus
continuousPeak = readPeak.value;
check.(continuousPeak > 0.01, "a running synth voice's continuous grains sound (peak %)".format(continuousPeak));
command.(\setGrainParam, 0, \grainMode, 1);
0.5.wait; server.sync;                     // the grains in flight have ended
untriggeredPeak = readPeak.value;
check.(untriggeredPeak < 0.001,
    "a triggered-mode synth voice is silent without a trigger (peak %)".format(untriggeredPeak));
probe.set(\t_reset, 1); server.sync;
command.(\retrigger, 0, 1.0);
0.3.wait;
triggeredPeak = {
    var condition = Condition(false), value;
    peakBus.get({ arg result; value = result; condition.test = true; condition.signal });
    awaitReply.(condition);
    value
}.value;
check.(triggeredPeak > 0.01, "a retrigger fires a grain in triggered mode (peak %)".format(triggeredPeak));
command.(\setGrainParam, 0, \grainMode, 0);
engine.synths[\grain0].set(\out, engine.voicePathBus(0, 0).index);
server.sync;
probe.free; peakBus.free; triggeredBus.free;
server.sync;
checkSourceGrains.(1, 2);

// A flood of retriggers (200 in 0.5 s, as a MIDI flood could send) on a
// triggered-mode buffer voice of 0.5 s grains: a grain starts at most every
// grainTriggerSeconds (4 ms), so no more than 125 sound at once, under
// GrainBuf's maxGrains - 1 (past it GrainBuf drops grains and prints "Too
// many grains", which fails the run). The slot holds 1 and the grains have
// a rectangular envelope, so the right channel's level over one grain's
// counts the grains sounding
{
    var voice = 3, slot = 5, path = scratchRoot +/+ "flood.wav", privateBus = Bus.audio(server, 2), bus = Bus.control(server, 2);
    var rectEnv = Buffer.loadCollection(server, Array.fill(1024, 1.0)), group = Group.after(engine.processGroup);
    var probe, one, many;
    writeTestFile.(path, server.sampleRate, (2 * server.sampleRate).asInteger, [1.0, 1.0]);
    command.(\loadBuffer, slot, path, 0); 0.3.wait; server.sync;
    command.(\setGrainSource, voice, slot + 1); server.sync;
    [[\grainMode, 1], [\grainSize, 0.5], [\posSpread, 0], [\panSpread, 0], [\panJitter, 0], [\sizeJitter, 0], [\bufRate, 1]]
        .do({ arg pair; command.(\setGrainParam, voice, *pair) });
    server.sync;
    engine.synths[engine.grainKey(voice)].set(\out, privateBus.index, \envBuf, rectEnv.bufnum);
    probe = Synth(\strataCheckChannelPeaks, [\in, privateBus, \out, bus], group);
    server.sync; 0.6.wait;                 // past the grain synth's attack, no grain in flight
    probe.set(\t_reset, 1); server.sync;
    command.(\retrigger, voice, 1.0);
    0.3.wait;
    one = readBus.(bus)[1];
    0.4.wait;                              // that grain has ended
    probe.set(\t_reset, 1); server.sync;
    // timestamped, so the server takes one every 2.5 ms (each in a block of
    // its own) whatever sclang's timing
    200.do({ arg index; server.makeBundle(0.2 + (index * 0.0025), { command.(\retrigger, voice, 1.0) }) });
    (0.2 + 0.5 + 0.3).wait;
    many = readBus.(bus)[1] / one.max(1e-9);
    check.((one > 0.5) and: { many > 50 } and: { many <= 125.5 },
        "a flood of 200 retriggers in 0.5 s never sounds more than 125 grains at once (at most %; one grain %)".format(
            many.round(0.1), one.round(0.0001)));
    [[\grainMode, 0], [\grainSize, 0.1], [\posSpread, 0.5], [\panSpread, 0.5], [\envShape, 0]]
        .do({ arg pair; command.(\setGrainParam, voice, *pair) });
    engine.synths[engine.grainKey(voice)].set(\out, engine.voicePathBus(voice, engine.grainSource[voice]).index);
    command.(\setGrainSource, voice, 0);
    server.sync;
    probe.free; group.free; server.sync;
    [privateBus, bus, rectEnv].do(_.free);
    command.(\clearBuffer, slot);
    File.delete(path);
}.value;

// 3.5's note controls: pairs of grain synths of the area's own, reading
// noteVoice's ring (its Resonator running since startAllVoices) or a slot
// of noise
checkNoteDefaults.value;
addNoteDiff.value;
loadNoteSlot.value;
checkNoteActs.value;
checkNoteRate.value;
checkNoteBendSynthSource.value;
checkNoteAccent.value;
checkNotePark.value;
command.(\clearBuffer, noteSlot);
File.delete(notePath);
h.stopAllVoices;
}
