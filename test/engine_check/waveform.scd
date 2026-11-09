// test/engine_check/waveform.scd
// The waveform area (lib/engine/StrataWaveform.sc): its hooks, neutral until
// package 1b fills them. See docs/notes/engine/waveform.md.
{ arg h;
var engine = h.engine;
var ran = List.new;
engine.writeSlotPeaks(0, 100, { ran.add(\write) });
engine.readSlotPeaks(0, 64, { ran.add(\read) });
h.check(ran.asArray == [\write, \read], "waveform: writeSlotPeaks and readSlotPeaks run their action at once");
h.check(engine.peaksPath(2) == (engine.allocSettingsDirectory +/+ "buf3.peaks"),
    "waveform: peaksPath is buf<n>.peaks in the folder used at alloc");
}
