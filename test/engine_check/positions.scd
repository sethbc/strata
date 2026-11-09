// test/engine_check/positions.scd
// The positions area (lib/engine/StrataPositions.sc): the neutral
// slotScanPhase is 3.2's scan. See docs/notes/engine/positions.md.
{ arg h;
var engine = h.engine, server = h.server;
var out = Bus.control(server, 2);
var values, synth;
SynthDef(\strataCheckScanCompare, { arg peaks, scan = 0.5, freeze = 0, t_reset = 0;
    var a = engine.slotScanPhase(scan, freeze, 0, 0, 0);
    var b = Phasor.ar(0, engine.scanRate(scan, freeze) * SampleDur.ir, 0, 1);
    Out.kr(peaks, [A2K.kr(Peak.ar((a - b).abs, t_reset)), A2K.kr(a)]);
}).add;
server.sync;
synth = Synth(\strataCheckScanCompare, [\peaks, out, \scan, 0.5], engine.processGroup, \addToTail);
1.0.wait;
values = h.readBus(out);
h.check((values[0] < 1e-6) and: { values[1] > 0.3 },
    "positions: slotScanPhase is 3.2's scan (difference %, phase %)".format(values[0], values[1]));
synth.free; out.free; server.sync;
}
