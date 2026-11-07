// test/engine_check/loops.scd
// Loop regions: where a buffer grain starts (slotGrainPos, StrataLoop.sc)
// for a loop (loopStart, loopLength), and that no grain, forward or
// reverse, reads past the slot's valid region.
//
// Two kinds of check. The starts themselves come from a check-only def that
// runs slotGrainPos on its own (no buffer) and reports, over the triggers
// since a reset, the lowest and highest start, the lowest and highest frame
// a grain reads, and how far the start is from 3.1's rule. The reads come
// from a voice on a slot whose frames outside the region under test hold 1
// and inside it 0, so any grain reading outside is heard; reverse grains
// (no Lua param gives them before the variation area) through a check-only
// def built with slotGrainReader at rate -1.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var readBus = { arg bus; h.readBus(bus) };
var getControl = { arg synth, control; h.getControl(synth, control) };
var measure = { arg probe, bus, seconds = 0.3; h.measure(probe, bus, seconds) };
var writeTestFile = { arg path, sampleRate, frames, values; h.writeTestFile(path, sampleRate, frames, values) };
var sampleRate = server.sampleRate, margin = engine.grainEndMargin;
var posBus, posSynth, starts, inRange, near;
var voice = 0, slot = 2, grainKey = engine.grainKey(0), path = h.tempDir +/+ "loops.wav";
var privateBus, peakBus, probeGroup, peakProbe, loadSlot, playSlot, quietFor, peak;
var reverseSynth, reverseWith, wrapSynth;

// The starts slotGrainPos gives, in frames, over the triggers since
// t_reset: [lowest start, highest start, lowest frame read, highest frame
// read, largest difference from 3.1's start (a fraction of the region),
// triggers]. A forward grain reads from its start up durFrames frames, a
// reverse one (rate < 0) down durFrames frames. The scan's phase restarts
// at 0 with each reset.
SynthDef(\strataCheckLoopStarts, { arg out, t_reset = 0, validFrames = 48000, durFrames = 4800, rate = 1,
    bufPos = 0, bufScan = 0, posSpread = 0, loopStart = 0, loopLength = 1, density = 500;
    var trig = Impulse.ar(density), reset = T2A.ar(t_reset), on = trig > 0;
    var scanPhase = Phasor.ar(reset, bufScan * SampleDur.ir, 0, 1);
    var spreadDraw = TRand.ar(posSpread * -0.5, posSpread * 0.5, trig);
    var pos = engine.slotGrainPos(trig, bufPos, scanPhase, spreadDraw, K2A.ar(rate), K2A.ar(durFrames), validFrames,
        loopStart, loopLength);
    var start = pos * validFrames, reverse = rate < 0;
    var lowest = start - (durFrames * reverse), highest = start + (durFrames * (1 - reverse));
    var old = (bufPos + scanPhase + spreadDraw).wrap(0, 1)
        * ((validFrames - margin - durFrames).max(0) / validFrames.max(1));
    Out.kr(out, A2K.kr([
        RunningMin.ar(Select.ar(on, [DC.ar(1e9), start]), reset),
        RunningMax.ar(Select.ar(on, [DC.ar(-1e9), start]), reset),
        RunningMin.ar(Select.ar(on, [DC.ar(1e9), lowest]), reset),
        RunningMax.ar(Select.ar(on, [DC.ar(-1e9), highest]), reset),
        RunningMax.ar((pos - old).abs * on, reset),
        PulseCount.ar(trig, reset)
    ]));
}).add;

// Reverse grains from a slot: slotGrainReader (and so slotGrainPos) at rate
// -1, the real buffer reader's start, duration and rate. Stereo, to a
// private bus.
SynthDef(\strataCheckLoopReverse, { arg out, bufnumL, bufnumR, bufFrames = 1, bufPos = 0, bufScan = 0,
    posSpread = 0, loopStart = 0, loopLength = 1, grainSize = 0.2, density = 40;
    var trig = Impulse.ar(density);
    var read = engine.slotGrainReader(bufnumL, bufnumR, bufFrames, 1, bufPos, 1, bufScan, posSpread, 0,
        loopStart, loopLength).value(trig, DC.ar(-1), grainSize, 0);
    Out.ar(out, GrainBuf.ar(2, trig, read[\dur], read[\bufL], read[\rate], read[\pos], 2, 0, -1, engine.maxGrains)
        * read[\level]);
}).add;

// ... and the same grains started by 3.1's rule (the start scaled to the
// forward starts), which a reverse grain near frame 0 reads past: the
// control that shows the check hears a wrap into the rest of the slot
SynthDef(\strataCheckLoopReverseWrap, { arg out, bufnumL, bufFrames = 1, bufPos = 0, grainSize = 0.2, density = 40;
    var trig = Impulse.ar(density);
    var durFrames = grainSize * SampleRate.ir;
    var pos = bufPos.wrap(0, 1) * ((bufFrames - margin - durFrames).max(0) / bufFrames.max(1));
    Out.ar(out, GrainBuf.ar(2, trig, grainSize, bufnumL, -1, pos * (bufFrames / BufFrames.kr(bufnumL)), 2, 0, -1,
        engine.maxGrains));
}).add;
server.sync;

posBus = Bus.control(server, 6);
posSynth = Synth(\strataCheckLoopStarts, [\out, posBus], engine.processGroup, \addAfter);
// The readings for these settings (the others as they were)
starts = { arg settings, seconds = 0.5;
    posSynth.set(*settings); server.sync;
    posSynth.set(\t_reset, 1);
    seconds.wait;
    readBus.(posBus)
};
// Every start in [low, high] frames, with a frame for float rounding
inRange = { arg readings, low, high; (readings[0] >= (low - 1)) and: { readings[1] <= (high + 1) } };
near = { arg value, target, frames = 2; (value - target).abs <= frames };

// grains start inside the region
[1, -1].do({ arg rate;
    var readings = starts.([\validFrames, sampleRate, \durFrames, 0.1 * sampleRate, \rate, rate,
        \bufPos, 0, \bufScan, 0.37, \posSpread, 0.5, \loopStart, 0.25, \loopLength, 0.25], 1);
    check.((readings[5] > 100) and: { inRange.(readings, 0.25 * sampleRate, 0.5 * sampleRate) }
        and: { readings[0] < (0.27 * sampleRate) } and: { readings[1] > (0.48 * sampleRate) },
        "loops: grains start inside the region (start 0.25, length 0.25, rate %; starts % to % of % frames)"
            .format(rate, readings[0], readings[1], sampleRate));
});

// bufPos, scan and spread wrap inside the loop
[1, -1].do({ arg rate;
    var still, moving;
    still = starts.([\validFrames, sampleRate, \durFrames, 0.1 * sampleRate, \rate, rate,
        \bufPos, 0.9, \bufScan, 0, \posSpread, 0, \loopStart, 0.25, \loopLength, 0.25]);
    moving = starts.([\bufPos, 0.9, \bufScan, -1.7, \posSpread, 1], 1);
    check.(near.(still[0], 0.475 * sampleRate) and: { near.(still[1], 0.475 * sampleRate) }
        and: { inRange.(moving, 0.25 * sampleRate, 0.5 * sampleRate) }
        and: { moving[0] < (0.26 * sampleRate) } and: { moving[1] > (0.49 * sampleRate) },
        "loops: bufPos, scan and spread wrap inside the loop (rate %; bufPos 0.9 starts at % to %, scanned % to %)"
            .format(rate, still[0], still[1], moving[0], moving[1]));
});

// a grain may play past the loop end but never past the valid region:
// a loop in the middle gets full-length grains, past its end (or, reverse,
// its start); one at the region's end starts them where they still fit
[[0.4, 0.1, 0.2], [0.9, 0.1, 0.2], [0.75, 0.25, 0.5]].do({ arg loop;
    [1, -1].do({ arg rate;
        var durFrames = loop[2] * sampleRate;
        var readings = starts.([\validFrames, sampleRate, \durFrames, durFrames, \rate, rate,
            \bufPos, 0.5, \bufScan, 1.3, \posSpread, 1, \loopStart, loop[0], \loopLength, loop[1]], 1);
        var inRegion = (readings[2] >= -0.01) and: { readings[3] <= (sampleRate - margin + 0.01) };
        var pastLoop = if (rate > 0) { readings[3] > ((loop[0] + loop[1]) * sampleRate) } { readings[2] < (loop[0] * sampleRate) };
        var fits = (loop[0] + loop[1]) * sampleRate <= (sampleRate - margin - durFrames);
        check.(inRegion and: { fits.not or: { pastLoop and: { inRange.(readings, loop[0] * sampleRate,
                (loop[0] + loop[1]) * sampleRate) } } },
            "loops: a grain may play past the loop end but never past the valid region (loop %/%, grain % s, rate %; reads % to % of %)"
                .format(loop[0], loop[1], loop[2], rate, readings[2], readings[3], sampleRate));
    });
});

// a loop shorter than a grain never reads past the valid region: a loop of
// 0.001 at either end of a 0.25 s region with 0.2 s grains, and a 0.05 s
// region (shorter than the grain: slotGrainReader caps the grain at the
// region less the margin)
[[0.25, 0.2], [0.05, 0.05 - (margin / sampleRate)]].do({ arg region;
    var validFrames = (region[0] * sampleRate).round, durFrames = (region[1] * sampleRate).round;
    [[0.999, 0.001], [0, 0.001], [0.5, 0.001]].do({ arg loop;
        [1, -1].do({ arg rate;
            var readings = starts.([\validFrames, validFrames, \durFrames, durFrames, \rate, rate,
                \bufPos, 0.3, \bufScan, 2.1, \posSpread, 1, \loopStart, loop[0], \loopLength, loop[1]]);
            check.((readings[5] > 50) and: { readings[2] >= -0.01 } and: { readings[3] <= (validFrames - margin + 0.01) },
                "loops: a loop shorter than a grain never reads past the valid region (% s region, loop %/%, rate %; reads % to % of %)"
                    .format(region[0], loop[0], loop[1], rate, readings[2], readings[3], validFrames));
        });
    });
});

// loopStart 0 and loopLength 1 give 3.1's positions
[0, 0.1, 0.5, 1 - (margin / sampleRate)].do({ arg grainSeconds;
    var readings = starts.([\validFrames, sampleRate, \durFrames, (grainSeconds * sampleRate).round, \rate, 1,
        \bufPos, 0.2, \bufScan, 0.8, \posSpread, 1, \loopStart, 0, \loopLength, 1], 0.5);
    check.((readings[5] > 100) and: { readings[4] < 1e-5 },
        "loops: loopStart 0 and loopLength 1 give 3.1's positions (grain % s; largest difference %)"
            .format(grainSeconds.round(0.001), readings[4]));
});
check.([\loopStart, \loopLength].every({ arg name; h.controlFeedsAUGen(\strataGrainBuf, name) }),
    "loops: loopStart and loopLength reach a UGen in strataGrainBuf");
check.([[\loopStart, 0], [\loopLength, 1]].every({ arg pair;
        SynthDescLib.global.at(\strataGrainBuf).controls.detect({ arg each; each.name == pair[0] }).defaultValue == pair[1] }),
    "loops: strataGrainBuf's loop defaults are the whole region");
posSynth.free; server.sync; posBus.free;

// Reads from a slot. The slot holds 0 in [low, high) of its valid region
// and 1 everywhere else, past the region too (loadBuffer zeroes the rest;
// the 1s are set by hand), so a grain is heard exactly when it reads
// outside [low, high)
privateBus = Bus.audio(server, 2);
peakBus = Bus.control(server, 1);
probeGroup = Group.after(engine.processGroup);
peakProbe = Synth(\strataCheckPeak, [\in, privateBus, \out, peakBus], probeGroup);
loadSlot = { arg seconds, low = 0, high = 1;
    var validFrames;
    writeTestFile.(path, sampleRate, (seconds * sampleRate).round.asInteger, [0, 0]);
    command.(\loadBuffer, slot, path); 0.3.wait; server.sync;
    validFrames = engine.bufferFrames[slot];
    [engine.buffersL[slot], engine.buffersR[slot]].do({ arg buffer;
        var first = (low * validFrames).round.asInteger, last = (high * validFrames).round.asInteger;
        if (first > 0) { buffer.fill(0, first, 1) };
        buffer.fill(last, buffer.numFrames - last, 1);
    });
    server.sync;
    validFrames
};
// voice 0 on the slot, its grains to the private bus
command.(\setGrainSource, voice, slot + 1);
command.(\voiceOn, voice, 200.0, 0.5, 0.0, 0.2, 40.0, 1.0);
server.sync;
engine.synths[grainKey].set(\out, privateBus.index);
playSlot = { arg settings;
    settings.pairsDo({ arg name, value; command.(\setGrainParam, voice, name, value) });
    server.sync;
    0.3.wait;  // the grains started before have ended
    measure.(peakProbe, peakBus, 0.6)[0]
};
quietFor = { arg level; level.notNil and: { level < 0.001 } };

check.(getControl.(engine.synths[grainKey], \loopStart) == 0 and: { getControl.(engine.synths[grainKey], \loopLength) == 1 },
    "loops: a buffer voice's grain synth starts with the whole region");
// grains start inside the region, with the real def: 1 before the loop
loadSlot.(1, 0.25);
peak = playSlot.([\posSpread, 1, \bufScan, 0.5, \bufPos, 0, \loopStart, 0, \loopLength, 1]);
check.(peak > 0.05, "loops: the whole region is heard before the loop is set (peak %)".format(peak));
peak = playSlot.([\loopStart, 0.25, \loopLength, 0.25]);
check.(quietFor.(peak), "loops: grains start inside the region (strataGrainBuf, loop 0.25/0.25; peak %)".format(peak));
check.(getControl.(engine.synths[grainKey], \loopStart).equalWithPrecision(0.25),
    "loops: setGrainParam sets the loop on a buffer voice's grain synth");
// the loop survives a source switch (a new grain synth starts with it)
command.(\setGrainSource, voice, slot + 2); server.sync;
check.(getControl.(engine.synths[grainKey], \loopStart).equalWithPrecision(0.25)
    and: { getControl.(engine.synths[grainKey], \loopLength).equalWithPrecision(0.25) },
    "loops: a voice's loop reaches the grain synth a source switch starts");
command.(\setGrainSource, voice, slot + 1); server.sync;
engine.synths[grainKey].set(\out, privateBus.index);

// a loop at the region's end, or shorter than a grain, with the real def:
// silence in the region, 1 past it, at rate 1 and 2
[[0.5, 0.9, 0.1, 1], [0.25, 0.999, 0.001, 1], [0.25, 0.999, 0.001, 2], [0.05, 0.999, 0.001, 1], [0.05, 0, 0.001, 1]].do({ arg grainCase;
    loadSlot.(grainCase[0]);
    peak = playSlot.([\loopStart, grainCase[1], \loopLength, grainCase[2], \bufRate, grainCase[3], \bufPos, 0.7,
        \bufScan, 0.9, \posSpread, 1]);
    check.(quietFor.(peak),
        "loops: a loop shorter than a grain never reads past the valid region (strataGrainBuf, % s region, loop %/%, 0.2 s grains at rate %; peak %)"
            .format(grainCase[0], grainCase[1], grainCase[2], grainCase[3], peak));
});
[[\loopStart, 0], [\loopLength, 1], [\bufRate, 1], [\bufPos, 0], [\bufScan, 0], [\posSpread, 0.5]].do({ arg pair;
    command.(\setGrainParam, voice, *pair)
});
engine.synths[grainKey].set(\out, engine.mainBus.index);
command.(\voiceOff, voice);
command.(\setGrainSource, voice, 0);
server.sync;

// reverse grains in a slot never read the zeroed tail: 1 past the region,
// at the loops where a reverse grain is closest to frame 0
reverseWith = { arg defName, settings;
    var synth = Synth(defName, [\out, privateBus, \bufnumL, engine.buffersL[slot], \bufnumR, engine.buffersR[slot],
        \bufFrames, engine.bufferFrames[slot]] ++ settings, engine.processGroup);
    var level;
    server.sync;
    0.3.wait;
    level = measure.(peakProbe, peakBus, 0.6)[0];
    synth.free; server.sync;
    level
};
loadSlot.(0.25);
peak = reverseWith.(\strataCheckLoopReverseWrap, [\bufPos, 0]);
check.(peak > 0.05, "loops: the check hears a reverse grain that crosses frame 0 (3.1's start; peak %)".format(peak));
[[0, 0.001], [0, 1], [0.5, 0.25], [0.999, 0.001]].do({ arg loop;
    peak = reverseWith.(\strataCheckLoopReverse, [\loopStart, loop[0], \loopLength, loop[1], \bufPos, 0,
        \bufScan, 1.1, \posSpread, 1]);
    check.(quietFor.(peak), "loops: reverse grains in a slot never read the zeroed tail (loop %/%, 0.2 s grains; peak %)"
        .format(loop[0], loop[1], peak));
});
// ... and they do play: the same grains over a region of 1s are heard
[engine.buffersL[slot], engine.buffersR[slot]].do({ arg buffer; buffer.fill(0, buffer.numFrames, 1) });
server.sync;
peak = reverseWith.(\strataCheckLoopReverse, [\loopStart, 0, \loopLength, 0.001]);
check.(peak > 0.05, "loops: the reverse check's grains play (peak %)".format(peak));

peakProbe.free; probeGroup.free;
command.(\clearBuffer, slot);
server.sync;
privateBus.free; peakBus.free;
File.delete(path);
h.stopAllVoices;
}
