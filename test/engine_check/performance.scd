// test/engine_check/performance.scd
// The values a performance tier sets. Today there is one: 16 s slots.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
check.(engine.numBuffers == 8 and: { engine.bufferSeconds == 16 }, "numBuffers 8, bufferSeconds 16");
check.((engine.buffersL ++ engine.buffersR).every({ arg buffer; buffer.numFrames == (server.sampleRate * 16) }),
    "each buffer holds 16 s at the server rate");
}
