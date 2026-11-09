// test/engine_check/record.scd
// The record area (lib/engine/StrataRecord.sc): its buses, and recordBuffer's
// eight arguments with 3.2's behavior. See docs/notes/engine/record.md.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var state = engine.areaState[\record];
var seconds = 0.2, tone, frames;

check.((state[\headBuses].size == 8)
    and: { state[\headBuses].every({ arg bus; (bus.numChannels == 2) and: { bus.rate == \control } and: { h.readBus(bus) == [-1.0, 0.0] } }) }
    and: { h.readBus(state[\idleHead]) == [-1.0, 0.0] }
    and: { state[\voiceTaps].size == 7 }
    and: { state[\voiceTaps].every({ arg bus; (bus.numChannels == 2) and: { bus.rate == \audio } }) }
    and: { state[\tapSink].numChannels == 2 },
    "record: eight head buses read -1 and 0 and seven stereo voice taps exist");

engine.recordStatePoll.start;
check.(h.formatOf(\recordBuffer) == "ifffifif", "record: recordBuffer takes eight arguments (format ifffifif)");
tone = Synth(\strataCheckTone, [\out, engine.inputBus], engine.inputSynth, \addBefore);
server.sync;
h.command(\loadBuffer, 0, h.stereoPath, 0);
h.waitFor({ engine.bufferFrames[0] > 0 });
h.command(\recordBuffer, 0, seconds, 1.0, 0, 0, 0, 0, 0);
frames = (seconds * server.sampleRate).round.asInteger;
check.((engine.bufferFrames[0] == 0) and: { engine.recordSynths[0].notNil },
    "record: recordBuffer takes eight arguments and records the input as a replace take (the slot reads empty)");
h.waitFor({ engine.bufferFrames[0] == frames }, (seconds + 1));
check.((engine.bufferFrames[0] == frames) and: { engine.recordSynths[0].isNil }
    and: { h.bufferSample(engine.buffersL[0], 500).abs > 0.001 },
    "record: recordBuffer takes eight arguments and records the input as a replace take (frames %, a sample %)".format(
        engine.bufferFrames[0], h.bufferSample(engine.buffersL[0], 500)));
tone.free; server.sync;
check.(CronePollRegistry.getPollFromName(\recordState).notNil and: { h.pollValues(\recordState).isEmpty },
    "record: the recordState poll exists and sends nothing");
engine.recordStatePoll.stop;
h.command(\clearBuffer, 0); server.sync;
}
