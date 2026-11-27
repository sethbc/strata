// Run in two sclang processes by save-restart.py, with the normal engine
// runner's registered commands, silent server, load confirmation and polls.
{ arg h;
    var dir = "STRATA_RESTART_DIR".getenv, role = thisProcess.argv[1];
    var destination = dir +/+ "held-restart.wav";
    h.command(\loadBuffer, 0, dir +/+ (role ++ ".wav"), 0);
    h.awaitLoad(0);
    if (role == "old") { h.engine.stopPeaksMover };  // force the real OS fallback
    h.command(\saveBuffer, 0, destination, 0, 1);
    if (role == "old") {
        // The supervisor kills this sclang after the child enters mv.
        60.wait;
        h.check(false, "restart: old sclang was never killed at handoff");
    } {
        var published = h.waitFor({ h.pollValues(\bufferSaveResult).includesEqual(
            h.engine.bufferSaveResultValue(0, 1, false)) });
        h.check(published, "restart: successor reported the first save written");
        if (published) {
            File.use(dir +/+ "published", "w", { arg file; file.write("published") });
            h.check(h.waitFor({ File.exists(dir +/+ "verified") }, 15),
                "restart: supervisor compared every frame before engine teardown");
        };
    };
}
