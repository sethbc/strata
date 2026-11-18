// test/engine_check/types/wave.scd
// The wave voice type's own checks (3.8, package 1f, design §3), loaded by
// the types area (test/engine_check/types.scd), a function of h: the bank
// (waveBankSize consecutive wavetables of waveTableFrames, filled on the
// server, freed by free), \strataWave's level at its defaults and at each
// own key's range ends, its energy below 8 Hz, morph's two ends, and a held
// chord's extra notes, each a \strataWave reading the bank. Its pool size
// is the memory area's (checkVoiceSynthSizes). See docs/notes/engine/types.md
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var silent = engine.silentBus.index;
var bankOf = { arg target; target.areaState[\typeWave] !? { arg state; state[\bank] } };
var bank = bankOf.(engine);
var typeIndex = engine.voiceTypeDefs.indexOf(\strataWave);
var known = bank.notNil and: { typeIndex.notNil } and: { SynthDescLib.global.at(\strataWave).notNil };
// The own keys' range ends (the record's specs, lib/types/wave.lua)
var keyEnds = [[\morph, 0, 1], [\morphRate, 0.01, 1], [\morphDepth, 0, 1], [\detune, 0, 0.02]];
var levelFloor = 0.005, levelCeiling = 1, subsonicCeiling = 0.15;
// The tables' RMS within tableSpreadDb of the loudest (the controller's
// ruling at 1f's review), and morph 1's share of energy above 4.5 times
// the pitch at least morphMinimumShare above morph 0's
var tableSpreadDb = 3, morphMinimumShare = 0.25;
// The level probe's outputs (strataCheckWaveLevel) a probe
var probeChannels = 7;
// The RMS of a probe's left channel and of its highpassed left channel
// over its window of `seconds`, from its outputs
var windowRms = { arg values, seconds; [((values[4] - values[3]).max(0) / seconds).sqrt,
    ((values[6] - values[5]).max(0) / seconds).sqrt] };
// Whether value is a constant of the def (its constants map value -> index)
var defHasConstant = { arg defName, value;
    SynthDescLib.global.at(defName) !? { arg desc; desc.def.constants.keys.any({ arg each; each == value }) } ? false };
// count frames of a buffer from index, read from the server
var framesOf = { arg buffer, index, count;
    var condition = Condition(false), values;
    buffer.getn(index, count, { arg result; values = result; condition.test = true; condition.signal });
    h.awaitReply(condition);
    values ? []
};
// each bufnum's frames as the server reports them (/b_query, one /b_info)
var serverFrames = { arg bufnums;
    var condition = Condition(false), frames = IdentityDictionary.new, responder;
    responder = OSCFunc({ arg msg;
        msg.drop(1).clump(4).do({ arg info; frames[info[0]] = info[1] });
        condition.test = true; condition.signal;
    }, '/b_info', server.addr);
    server.listSendMsg(["/b_query"] ++ bufnums);
    h.awaitReply(condition);
    responder.free;
    bufnums.collect({ arg bufnum; frames[bufnum] })
};
// A \strataWave on a private bus at the given controls (the attack short,
// every crossmod slot silent)
var startWave = { arg bus, group, args;
    Synth(\strataWave, [\out, bus, \attackTime, 0.01, \modBus1, silent, \modBus2, silent, \modBus3, silent] ++ args, group)
};

// The level probe (probeChannels outputs): from t_reset, the stereo bus's
// peak, its peak below 8 Hz (two 8 Hz lowpasses), whether a bad value came,
// the integral of its left channel's square latched at `from` and at `to`
// seconds, and the same of its left channel above `high` Hz (two highpasses)
SynthDef(\strataCheckWaveLevel, { arg in, out, t_reset = 0, from = 0, to = 2, high = 990;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset), elapsed = Sweep.kr(t_reset, 1);
    var energy = A2K.kr(Integrator.ar(sig[0].squared * SampleDur.ir, 1)), low = LPF.ar(LPF.ar(sig, 8), 8);
    var highEnergy = A2K.kr(Integrator.ar(HPF.ar(HPF.ar(sig[0], high), high).squared * SampleDur.ir, 1));
    Out.kr(out, [A2K.kr(Peak.ar(sig[0].abs.max(sig[1].abs), reset)), A2K.kr(Peak.ar(low[0].abs.max(low[1].abs), reset)),
        A2K.kr(Peak.ar(CheckBadValues.ar(sig.sum, 0, 0) > 0, reset)),
        Latch.kr(energy, elapsed >= from), Latch.kr(energy, elapsed >= to),
        Latch.kr(highEnergy, elapsed >= from), Latch.kr(highEnergy, elapsed >= to)]);
}).add;
server.sync;

// \strataWave holds its bank's first bufnum as a constant, and every engine
// built on this server re-adds it with its own bank: an earlier area's
// second engine (h.startEngine, freed since) has left it reading that
// engine's freed bank. On norns one engine runs at a time. Rebuild it for
// this engine
if (engine.respondsTo(\addWaveDef)) { engine.areaCall(\addWaveDef); server.sync };

// "wave: the bank is eight consecutive buffers holding wavetableBankFrames":
// waveBankSize buffers of waveTableFrames, consecutive bufnums (VOsc3 reads
// a table and the next), their frames summing to 0b's wavetableBankFrames,
// each filled on the server (the 16 frames from an eighth of a table are
// not all 0), as a type after the roster's (voiceTypeDefs). (That the def
// reads its engine's bank is proven on the second engine below, whose bank
// is not at bufnum 0: the def has a 0 of its own)
{
    var bufnums = bank !? { bank.collect(_.bufnum) } ? [], sizes = bank !? { bank.collect(_.numFrames) } ? [];
    var filled = (bank ? []).collect({ arg buffer;
        framesOf.(buffer, engine.waveTableFrames div: 8, 16).any({ arg value; value.abs > 0.001 }) });
    var reported = serverFrames.(bufnums);
    check.(known and: { bank.size == engine.waveBankSize } and: { engine.waveBankSize == 8 }
        and: { (bufnums.differentiate.drop(1)).every(_ == 1) }
        and: { sizes.sum == engine.wavetableBankFrames } and: { sizes.every(_ == engine.waveTableFrames) }
        and: { reported == sizes } and: { filled.every(_ == true) }
        and: { typeIndex >= engine.numVoices },
        "wave: the bank is eight consecutive buffers holding wavetableBankFrames (bufnums %, frames %, on the server %, filled %, type %)".format(
            bufnums, sizes, reported, filled, typeIndex));
}.value;

// "wave: an engine's def reads its own bank": a second engine, whose bank
// starts past h.engine's (so not at 0, a constant the def has anyway),
// re-adds \strataWave with its own first bufnum as a constant, and not
// h.engine's (when that is not 0).
// "wave: free leaves no buffer of the bank": that bank, its bufnums taken
// first, is freed with the engine: every Buffer freed and the server
// reports no frames at any of its bufnums
{
    var target = h.startEngine, other = bankOf.(target), bufnums, before, after, freed, own, mine;
    bufnums = other !? { other.collect(_.bufnum) } ? [];
    own = bufnums.notEmpty and: { defHasConstant.(\strataWave, bufnums[0]) };
    mine = bank !? { bank[0].bufnum };
    check.(known and: { bufnums.notEmpty } and: { bufnums[0] != 0 } and: { bufnums[0] != mine } and: { own }
        and: { (mine == 0) or: { defHasConstant.(\strataWave, mine).not } },
        "wave: an engine's def reads its own bank (the second engine's first bufnum % a constant of the def %; h.engine's %)".format(
            bufnums[0], own, mine));
    before = serverFrames.(bufnums);
    h.freeEngine(target);
    server.sync;
    after = serverFrames.(bufnums);
    freed = (other ? []).every({ arg buffer; buffer.bufnum.isNil });
    check.(other.notNil and: { bufnums.size == engine.waveBankSize } and: { before.every(_ == engine.waveTableFrames) }
        and: { freed } and: { after.every(_ == 0) },
        "wave: free leaves no buffer of the bank (bufnums %, frames before %, after %, Buffers freed %)".format(
            bufnums, before, after, freed));
}.value;
// (the second engine re-added the def with its own bank)
if (engine.respondsTo(\addWaveDef)) { engine.areaCall(\addWaveDef); server.sync };

// "wave: at its defaults and at each own key's range ends, at 110 and
// 2000 Hz, the voice is finite, peaks above levelFloor and under 1": one
// \strataWave a case on a private bus, the others at their defaults, peaks
// over 1.5 s from 0.5 s after the start
{
    var cases = [[]] ++ keyEnds.collect({ arg entry; [[entry[0], entry[1]], [entry[0], entry[2]]] }).flatten(1);
    var results = List.new;
    [110, 2000].do({ arg freq;
        var group = Group.tail(server), buses = cases.collect({ Bus.audio(server, 2) });
        var levels = Bus.control(server, cases.size * probeChannels), probes;
        if (known) { cases.do({ arg args, index; startWave.(buses[index], group, [\freq, freq] ++ args) }) };
        probes = cases.collect({ arg args, index;
            Synth(\strataCheckWaveLevel, [\in, buses[index], \out, levels.index + (index * probeChannels)], group, \addToTail) });
        server.sync; 0.5.wait;
        probes.do(_.set(\t_reset, 1));
        1.5.wait;
        h.readBus(levels).clump(probeChannels).do({ arg values, index; results.add([freq, cases[index], values[0], values[2]]) });
        group.free; server.sync; buses.do(_.free); levels.free;
    });
    check.(known and: { results.size == (2 * cases.size) } and: { results.every({ arg each;
        (each[3] == 0) and: { each[2] > levelFloor } and: { each[2] < levelCeiling } }) },
        "wave: at its defaults and at each own key's range ends, at 110 and 2000 Hz, the voice is finite, peaks above % and under % ([Hz, controls, peak, bad]: %)".format(
            levelFloor, levelCeiling, results.collect({ arg each; [each[0], each[1], each[2].round(0.0001), each[3]] })));
}.value;

// "wave: below 8 Hz the voice peaks under subsonicCeiling of its peak":
// at its defaults at 110 Hz, over 4 s from 2 s after the start (a wavetable
// of sines has no energy at 0 Hz, and the detune's beating none either)
{
    var group = Group.tail(server), bus = Bus.audio(server, 2), levels = Bus.control(server, probeChannels), probe, values;
    if (known) { startWave.(bus, group, [\freq, 110]) };
    probe = Synth(\strataCheckWaveLevel, [\in, bus, \out, levels.index], group, \addToTail);
    server.sync; 2.0.wait;
    probe.set(\t_reset, 1);
    4.0.wait;
    values = h.readBus(levels);
    check.(known and: { values[0] > levelFloor } and: { values[1] < (values[0] * subsonicCeiling) },
        "wave: below 8 Hz the voice peaks under % of its peak (at 110 Hz: below 8 Hz % of a peak of %)".format(
            subsonicCeiling, values[1].round(0.0001), values[0].round(0.0001)));
    group.free; server.sync; bus.free; levels.free;
}.value;

// "wave: the eight tables play within 3 dB of each other": at 220 Hz, at
// the defaults but morphDepth 0 (no wander), one \strataWave at each table's
// place (morph k / (waveBankSize - 1)), the RMS of each left channel over
// the same 2 s window within tableSpreadDb of the loudest, each above
// levelFloor. The level at the defaults' morph 0.3 is shown beside them
// (not checked)
{
    var size = if (known) { engine.waveBankSize } { 2 };
    var morphs = ((0 .. (size - 1)) / (size - 1)) ++ [0.3];
    var group = Group.tail(server), buses = morphs.collect({ Bus.audio(server, 2) });
    var levels = Bus.control(server, morphs.size * probeChannels), probes, rms, tables, spreadDb;
    if (known) { morphs.do({ arg morph, index; startWave.(buses[index], group, [\freq, 220, \morph, morph, \morphDepth, 0]) }) };
    probes = buses.collect({ arg bus, index;
        Synth(\strataCheckWaveLevel, [\in, bus, \out, levels.index + (index * probeChannels), \from, 0.5, \to, 2.5], group, \addToTail) });
    server.sync; 0.2.wait;
    server.makeBundle(0.1, { probes.do(_.set(\t_reset, 1)) });
    3.0.wait;
    rms = h.readBus(levels).clump(probeChannels).collect({ arg values; windowRms.(values, 2)[0] });
    tables = rms.drop(-1);
    spreadDb = (tables.maxItem.max(1e-9) / tables.minItem.max(1e-9)).ampdb;
    check.(known and: { tables.size == engine.waveBankSize } and: { tables.every({ arg each; each > levelFloor }) }
        and: { spreadDb <= tableSpreadDb },
        "wave: the eight tables play within 3 dB of each other (RMS at 220 Hz, morph % : %; % dB from the quietest to the loudest, at most %; at morph 0.3: %)".format(
            morphs.drop(-1).round(0.001), tables.round(0.0001), spreadDb.round(0.01), tableSpreadDb, rms.last.round(0.0001)));
    group.free; server.sync; buses.do(_.free); levels.free;
}.value;

// "wave: morph 0 and 1 both play, and they differ": at 220 Hz with
// morphDepth 0 (no wander), over the same 2 s window, morph 0 (the sine)
// against morph 1 (the brightest table): both above levelFloor, and the
// share of the left channel's energy above the fourth harmonic (two 990 Hz
// highpasses) at least morphMinimumShare greater at morph 1. Its spectrum
// is what differs, not its level (the tables play at matched level: the
// controller's ruling at 1f's review, which replaced a level difference here)
{
    var group = Group.tail(server), buses = 2.collect({ Bus.audio(server, 2) }), levels = Bus.control(server, 2 * probeChannels);
    var probes, rms, shares;
    if (known) { [0, 1].do({ arg morph, index; startWave.(buses[index], group, [\freq, 220, \morph, morph, \morphDepth, 0]) }) };
    probes = buses.collect({ arg bus, index;
        Synth(\strataCheckWaveLevel, [\in, bus, \out, levels.index + (index * probeChannels), \from, 0.5, \to, 2.5, \high, 990],
            group, \addToTail) });
    server.sync; 0.2.wait;
    server.makeBundle(0.1, { probes.do(_.set(\t_reset, 1)) });
    3.0.wait;
    rms = h.readBus(levels).clump(probeChannels).collect({ arg values; windowRms.(values, 2) });
    shares = rms.collect({ arg each; (each[1] / each[0].max(1e-9)).squared });
    check.(known and: { rms.every({ arg each; each[0] > levelFloor }) } and: { (shares[1] - shares[0]) >= morphMinimumShare },
        "wave: morph 0 and 1 both play, and they differ (at 220 Hz: RMS morph 0 %, morph 1 %; share of the energy above the fourth harmonic, morph 0 %, morph 1 %, at least % more)".format(
            rms[0][0].round(0.0001), rms[1][0].round(0.0001), shares[0].round(0.001), shares[1].round(0.001), morphMinimumShare));
    group.free; server.sync; buses.do(_.free); levels.free;
}.value;

// "wave: the extra notes read the bank": voice 0 on the wave type holds a
// three-note chord: three \strataWave note synths (each moved to a private
// bus of its own for the measure), each finite and above levelFloor, and
// morph sent voice-wide reaches all three
{
    var voice = 0, slots = [1, 2, 3], notes, buses, levels, probes, group, values, morphs, defs;
    if (known) { command.(\setVoiceType, voice, typeIndex) };
    command.(\setGrainSource, voice, 0);
    command.(\voiceOn, voice, 110.0, 0.2, 0.0, 0.1, 10.0, 1.0);
    command.(\setVoiceParam, voice, \attackTime, 0.01);
    command.(\setNotePool, engine.notePoolMax);
    slots.do({ arg slot;
        command.(\noteExpression, voice, slot, 1.0, 1.0, 0.0, 0.0, 0.0);
        command.(\noteOn, voice, slot, 60.0 + slot, 220.0 + (slot * 55), 1.0, 1.0);
    });
    server.sync; 0.1.wait;
    notes = slots.collect({ arg slot; engine.noteRecord(voice, slot)[\synth] });
    defs = notes.collect({ arg synth; synth !? { synth.defName.asSymbol } });
    group = Group.after(engine.voiceGroup);
    buses = slots.collect({ Bus.audio(server, 2) });
    levels = Bus.control(server, slots.size * probeChannels);
    notes.do({ arg synth, index; synth !? { synth.set(\out, buses[index]) } });
    probes = slots.collect({ arg slot, index;
        Synth(\strataCheckWaveLevel, [\in, buses[index], \out, levels.index + (index * probeChannels)], group) });
    server.sync; 0.3.wait;
    probes.do(_.set(\t_reset, 1));
    1.0.wait;
    values = h.readBus(levels).clump(probeChannels);
    command.(\setVoiceParam, voice, \morph, 0.9);
    server.sync;
    morphs = notes.collect({ arg synth; synth !? { h.getControl(synth, \morph) } });
    check.(known and: { defs.every(_ == \strataWave) }
        and: { engine.synths[engine.voiceKey(voice)] !? { arg synth; synth.defName.asSymbol == \strataWave } ? false }
        and: { values.every({ arg each; (each[2] == 0) and: { each[0] > levelFloor } and: { each[0] < levelCeiling } }) }
        and: { morphs.every({ arg morph; morph.notNil and: { (morph - 0.9).abs < 1e-6 } }) },
        "wave: the extra notes read the bank (note defs %, [peak, bad] %, morph after a voice-wide 0.9 %)".format(
            defs, values.collect({ arg each; [each[0].round(0.0001), each[2]] }), morphs));
    group.free;
    h.stopAllVoices;
    buses.do(_.free); levels.free;
    command.(\setNotePool, 0);
    command.(\setVoiceType, voice, voice);
}.value;
h.stopAllVoices;
}
