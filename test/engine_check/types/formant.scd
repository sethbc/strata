// test/engine_check/types/formant.scd
// The formant voice type's own checks (3.8, package 1j), run by the types
// area after its own: \strataFormant's place in voiceTypeDefs, its level at
// the defaults and at each own key's range ends at 110 and 2000 Hz (finite,
// above levelFloor and under levelCeiling on the voice bus), what it leaves
// below 8 Hz, and a held chord's three extra notes on its def. Its pool size
// is the memory area's (checkVoiceSynthSizes reads voiceTypeDefs), and
// noteMain's ±1 the voices area's (it reads noteMainRanges). See
// docs/notes/engine/types.md (Formant).
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var command = { arg name ... args; h.command(name, *args) };
var def = \strataFormant;
var typeIndex = engine.voiceTypeDefs.indexOf(def);
// what a voice of the type must play: finite, a peak above levelFloor (not
// silent) and under levelCeiling, and below 8 Hz (two 8 Hz lowpasses) a
// peak under subsonicCeiling of the whole (the FM and Ring voices' measure,
// docs/notes/engine/voices.md)
var levelFloor = 0.005, levelCeiling = 1, subsonicCeiling = 0.15;
// the own keys at the record's defaults, and each key's range (Lua's specs;
// formant's is the expression's, noteMainRanges)
var defaults = (formant: 1, vowel: 0.5, bw: 0.5);
var ranges;
var pitches = [110.0, 2000.0];
// the def's own attack, which every measure waits out
var attackSeconds = SynthDescLib.global.at(def) !? { arg desc; desc.controlDict[\attackTime].defaultValue } ? 0;
var settleSeconds = 0.6, levelSeconds = 2.0, subsonicSettle = 1.0, subsonicSeconds = 8.0;
var touched = [\formant, \vowel, \bw];
var bus, probes, play, stopVoices, cases, measureCases;

check.(typeIndex.notNil and: { typeIndex >= engine.numVoices },
    "formant: \\strataFormant is in voiceTypeDefs, after the types the voices start on (at %)".format(typeIndex));
// (without the def in the list nothing below can run)
if (typeIndex.notNil) {
ranges = (formant: engine.noteMainRanges[def].copyToEnd(1), vowel: [0, 1], bw: [0.1, 1]);
// A probe of a voice bus: its peak, its peak below 8 Hz and its bad values
SynthDef(\strataCheckFormantProbe, { arg in, out, t_reset = 0;
    var sig = In.ar(in, 2), reset = T2A.ar(t_reset);
    Out.kr(out, A2K.kr([
        Peak.ar(sig.abs.reduce(\max), reset),
        Peak.ar(LPF.ar(LPF.ar(sig[0], 8), 8).abs, reset),
        Peak.ar(CheckBadValues.ar(sig[0], 0, 0).max(CheckBadValues.ar(sig[1], 0, 0)), reset)
    ]));
}).add;
server.sync;

// Voice v on the type at the given own values and pitch: as Lua starts a
// voice, its synthesis values right after voiceOn (which resets them)
play = { arg voice, values, freq;
    command.(\setGrainSource, voice, 0);
    command.(\setVoiceType, voice, typeIndex);
    command.(\voiceOn, voice, freq, 0.3, 0.0, 0.1, 20.0, 1.0);
    defaults.keysValuesDo({ arg key, value; command.(\setVoiceParam, voice, key, (values[key] ? value).asFloat) });
};
stopVoices = {
    h.stopAllVoices;
    engine.numVoices.do({ arg voice;
        command.(\setVoiceType, voice, voice);
        touched.do({ arg key; engine.voiceControls[voice].removeAt(key) });
    });
    server.sync;
};

// Each case at once on its own voice (at most numVoices a run): [label,
// values, freq]; returns each one's [peak, below 8 Hz, bad]
measureCases = { arg list, settle, seconds;
    var values;
    bus = Bus.control(server, 3 * list.size);
    list.do({ arg case, voice; play.(voice, case[1], case[2]) });
    server.sync; (attackSeconds + settle).wait;
    probes = list.collect({ arg case, voice;
        Synth(\strataCheckFormantProbe, [\in, engine.granBuses[voice], \out, bus.index + (3 * voice)], engine.voiceGroup, \addAfter)
    });
    server.sync; 0.2.wait;
    server.makeBundle(nil, { probes.do(_.set(\t_reset, 1)) });
    seconds.wait;
    values = h.readBus(bus).clump(3);
    probes.do(_.free); server.sync; bus.free;
    stopVoices.value;
    values
};

// "formant: its level at the defaults and its keys' range ends, at 110 and
// 2000 Hz": finite, above levelFloor, under levelCeiling
cases = [["the defaults", ()]] ++ ranges.keys.asArray.sort.collect({ arg key;
    ranges[key].collect({ arg end; ["% %".format(key, end), ().put(key, end)] })
}).flatten(1);
pitches.do({ arg freq;
    cases.clump(engine.numVoices).do({ arg group;
        var results = measureCases.(group.collect({ arg case; case ++ [freq] }), settleSeconds, levelSeconds);
        group.do({ arg case, index;
            var peak = results[index] !? { arg each; each[0] }, bad = results[index] !? { arg each; each[2] };
            check.(peak.notNil and: { peak.isNaN.not } and: { bad == 0 } and: { peak > levelFloor } and: { peak < levelCeiling },
                "formant: % Hz at % is finite with a peak between % and % (peak %, bad values %)".format(
                    freq.asInteger, case[0], levelFloor, levelCeiling, peak !? { peak.round(0.0001) }, bad));
        });
    });
});

// "formant: 2000 Hz at formant 2 is finite and under 1": the high note with
// the formants scaled up a player will meet (both formants and the
// bandwidth at their highest)
{
    var results = measureCases.([["formant 2", (formant: ranges[\formant][1], vowel: 0, bw: ranges[\bw][1]), 2000.0]],
        settleSeconds, levelSeconds);
    var peak = results[0][0], bad = results[0][2];
    check.(peak.isNaN.not and: { bad == 0 } and: { peak > levelFloor } and: { peak < levelCeiling },
        "formant: 2000 Hz at formant 2 is finite and under 1 (peak %, bad values %)".format(peak.round(0.0001), bad));
}.value;

// "formant: below 8 Hz under subsonicCeiling of the peak": the defaults,
// and the widest bandwidth at the vowel's end and the formant scale's ends
// where a formant falls near or under the pitch. Formant's bursts last
// max(pitch, bandwidth) a cycle, so there a burst holds half a cycle or so
// of its sine and carries DC that moves with the vowel's wander: without
// the def's subsonicBlock 0.090 below 8 Hz of a 0.212 peak at 300 Hz
// (formant 0.5) and 0.082 of 0.179 at 2000 Hz (formant 2), both failing;
// with it under 0.0001 of every peak (3.14.1)
{
    var low = (formant: ranges[\formant][0], vowel: 0, bw: ranges[\bw][1]);
    var high = (formant: ranges[\formant][1], vowel: 0, bw: ranges[\bw][1]);
    var list = [["the defaults at 110 Hz", (), 110.0], ["formant 0.5, vowel 0, bw 1 at 110 Hz", low, 110.0],
        ["formant 0.5, vowel 0, bw 1 at 300 Hz", low, 300.0], ["formant 2, vowel 0, bw 1 at 2000 Hz", high, 2000.0]];
    var results = measureCases.(list, subsonicSettle, subsonicSeconds);
    list.do({ arg case, index;
        var peak = results[index][0], below = results[index][1];
        check.((peak > levelFloor) and: { below < (peak * subsonicCeiling) },
            "formant: % leaves below 8 Hz under % of its peak (% of %)".format(
                case[0], subsonicCeiling, below.round(0.00001), peak.round(0.0001)));
    });
}.value;

// "formant: a held chord's three extra notes start three synths of its def"
{
    var voice = 0, notes;
    play.(voice, (), 110.0);
    command.(\setNotePool, 3);
    server.sync;
    [1, 2, 3].do({ arg slot; command.(\noteOn, voice, slot, 60.0 + slot, 110.0 * (1 + (slot / 4)), 1.0, 0.8) });
    server.sync; 0.1.wait;
    notes = h.noteSynths(voice);
    check.((notes.size == 3) and: { notes.every({ arg synth; synth.defName.asSymbol == def }) }
        and: { h.noteNodesAgree(engine)[0] },
        "formant: a held chord's three extra notes start three synths of its def (%; the server's notes agree: %)".format(
            notes.collect({ arg synth; synth.defName }), h.noteNodesAgree(engine)));
    [1, 2, 3].do({ arg slot; command.(\noteOff, voice, slot, 1) });
    command.(\setNotePool, 0);
    server.sync;
    stopVoices.value;
}.value;
};
}
