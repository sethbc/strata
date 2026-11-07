// StrataPerformance.sc
// The performance area: decides the tier at alloc, before any other area
// allocates a buffer or builds a SynthDef, and sets the tier values every
// other area builds with (tier, bufferSeconds, maxGrains, historySeconds).
// It reads the setting Lua saved (performance.data), the board model and
// the free memory, and writes what it runs to performance_active.data,
// which Lua reads at init. The engine runs high only if it could write that
// file, so the two never disagree. See docs/notes/engine/performance.md.

+ Engine_Strata {
    // The standard tier's buffer length (s): Lua's S.constants.STANDARD_BUFFER_SECONDS
    standardBufferSeconds { ^16 }

    // The high tier's buffer lengths (s), longest first: the setting's
    // length, stepped down until the slots and rings leave minFreeMemKB
    highBufferChoices { ^#[300, 120, 60, 16] }

    // Seconds of live input history: standard, high
    standardHistorySeconds { ^16 }
    highHistorySeconds { ^60 }

    // Grains per GrainIn/GrainBuf table on both tiers (Lua's largest
    // overlap, 0.5 s x 100 grains/s x 2 = 100, stays inside it)
    tierMaxGrains { ^128 }

    // MemAvailable (kB) the high tier's slots and rings must leave: 1 GB
    minFreeMemKB { ^1048576 }

    // The setting's defaults: a missing file, key or value
    defaultPerformanceSetting { ^(performance: \auto, bufferSeconds: 60) }

    // The settings folder: settingsDir, or Lua's _path.data .. "strata/" on
    // norns (the folder scenes.data is in). "~" is expanded
    settingsDirectory {
        var dir = (settingsDir ? (Platform.userHomeDir +/+ "dust/data/strata/")).asString;
        if (dir.beginsWith("~")) { dir = dir.standardizePath };
        ^dir
    }

    // The settings folder this engine used at alloc (settingsDir is set for
    // a build only in the engine check), else settingsDirectory
    allocSettingsDirectory {
        ^(areaState !? { arg state; state[\performance] } !? { arg state; state[\settingsDir] })
            ? this.settingsDirectory
    }

    performanceSettingPath { ^this.settingsDirectory +/+ "performance.data" }
    activePerformancePath { ^this.settingsDirectory +/+ "performance_active.data" }

    // The performance area (order 10): first, so the tier values are set
    // before any area allocates a buffer or builds a SynthDef with them. It
    // also starts the file-write state (instanceTag, writeGenerations),
    // which its own write uses
    strataAreaPerformance {
        ^(
            order: 10,
            allocState: { this.allocPerformance }
        )
    }

    allocPerformance {
        var state = areaState[\performance], decision;
        instanceTag = UniqueID.next;
        writeGenerations = Dictionary.new;
        // the folder deleteStaleParts cleans (stalePartDirs), as this start used it
        state[\settingsDir] = this.settingsDirectory;
        decision = this.performanceDecision(this.readPerformanceSetting, this.readBoardModel,
            this.readMemAvailableKB, context.server.sampleRate ? 48000);
        if (this.writeActivePerformance(decision).not) {
            decision = this.standardPerformance("standard: performance_active.data could not be written");
            postln("strata: cannot write " ++ this.activePerformancePath ++ "; running standard");
        };
        state[\decision] = decision;
        tier = decision[\tier];
        bufferSeconds = decision[\bufferSeconds];
        maxGrains = decision[\maxGrains];
        historySeconds = decision[\historySeconds];
        postln("strata: performance " ++ tier ++ ", " ++ bufferSeconds ++ " s buffers (" ++ decision[\reason] ++ ")");
    }

    standardPerformance { arg reason;
        ^(tier: \standard, bufferSeconds: this.standardBufferSeconds, maxGrains: this.tierMaxGrains,
            historySeconds: this.standardHistorySeconds, reason: reason)
    }

    // performance.data's "key value" lines: (performance: \auto|\standard|\high,
    // bufferSeconds: 16|60|120|300). Each key is read on its own: a missing
    // file, key or value outside its choices gives that key's default (auto,
    // 60 s), with one line in the post window naming what was ignored. Other
    // keys are ignored (a newer release's)
    readPerformanceSetting {
        var setting = this.defaultPerformanceSetting, path = this.performanceSettingPath, text, ignored = List.new;
        if (File.exists(path).not) { ^setting };
        text = try { File.readAllString(path) } { nil };
        if (text.isNil) {
            postln("strata: cannot read " ++ path ++ "; using auto, 60 s");
            ^setting
        };
        text.split($\n).do({ arg line;
            var words = line.collect({ arg char; if (char.isSpace) { Char.space } { char } }).split(Char.space)
                .reject(_.isEmpty);
            var key = words[0], value = words[1];
            case
            { key == "performance" } {
                if ((words.size == 2) and: { ["auto", "standard", "high"].includesEqual(value) }) {
                    setting[\performance] = value.asSymbol
                } { ignored.add(line) }
            }
            { key == "buffer_seconds" } {
                if ((words.size == 2) and: { value.every(_.isDecDigit) }
                    and: { this.highBufferChoices.includes(value.asInteger) }) {
                    setting[\bufferSeconds] = value.asInteger
                } { ignored.add(line) }
            };
        });
        if (ignored.notEmpty) {
            postln("strata: performance.data: ignored " ++ ignored.collect(_.asCompileString).join(", ")
                ++ "; using performance " ++ setting[\performance] ++ ", buffer_seconds " ++ setting[\bufferSeconds]);
        };
        ^setting
    }

    // The board's model (modelPath, or the device tree's on norns), without
    // the NULs it ends with and outer whitespace; "" when it cannot be read.
    // Read byte by byte: a sysfs or /proc file may report size 0
    readBoardModel {
        var path = (modelPath ? "/sys/firmware/devicetree/base/model").asString, file, chars = List.new, char;
        if (File.exists(path).not) { ^"" };
        file = try { File.open(path, "r") } { nil };
        if (file.isNil or: { file.isOpen.not }) { ^"" };
        while { (chars.size < 256) and: { (char = file.getChar).notNil } } {
            if (char.ascii != 0) { chars.add(if (char.isPrint) { char } { Char.space }) };
        };
        file.close;
        ^this.trimmedText(String.newFrom(chars))
    }

    // text without its leading and trailing whitespace
    trimmedText { arg text;
        var first = text.detectIndex({ arg char; char.isSpace.not }), last = text.size - 1;
        if (first.isNil) { ^"" };
        while { text[last].isSpace } { last = last - 1 };
        ^text.copyRange(first, last)
    }

    // MemAvailable in kB from meminfoPath (or /proc/meminfo), read line by
    // line (sclang reads /proc files as empty with readAllString); nil when
    // it cannot be read or has no such line
    readMemAvailableKB {
        var path = (meminfoPath ? "/proc/meminfo").asString, file, line, found, number;
        if (File.exists(path).not) { ^nil };
        file = try { File.open(path, "r") } { nil };
        if (file.isNil or: { file.isOpen.not }) { ^nil };
        while { found.isNil and: { (line = file.getLine).notNil } } {
            if (line.beginsWith("MemAvailable:")) {
                number = line.copyToEnd(13).reject(_.isSpace).replace("kB", "");
                found = if (number.notEmpty and: { number.every(_.isDecDigit) }) { number.asInteger } { false };
            };
        };
        file.close;
        ^if (found == false) { nil } { found }
    }

    // Bytes the high tier allocates for slots of `seconds`: 8 slots x 2 mono
    // buffers, every voice's 2-channel ring and the input ring
    // (highHistorySeconds + ringGuardSeconds + 1), 4-byte samples
    highMemoryBytes { arg seconds, sampleRate;
        ^(numBuffers * 2 * seconds * sampleRate * 4)
            + (numVoices * 2 * this.ringSeconds * sampleRate * 4)
            + (2 * (this.highHistorySeconds + this.ringGuardSeconds + 1) * sampleRate * 4)
    }

    // The tier and its values from the setting, the board model and
    // MemAvailable (kB, or nil): an Event (tier, bufferSeconds, maxGrains,
    // historySeconds, reason). standard gives standard; high gives high on
    // any board; auto gives high when the model names a Pi 4 or a Compute
    // Module 4 (CM4S too), else standard. High's length is the setting's,
    // stepped down (highBufferChoices) until the slots and rings leave
    // minFreeMemKB of MemAvailable; an unreadable meminfo gives 16 s
    performanceDecision { arg setting, model, memAvailableKB, sampleRate;
        var choice = setting[\performance], wanted = setting[\bufferSeconds] ? 60, high, reason, seconds;
        model = (model ? "").asString;
        high = switch(choice,
            \standard, { false },
            \high, { true },
            { model.contains("Raspberry Pi 4") or: { model.contains("Compute Module 4") } });
        reason = switch(choice,
            \standard, { "standard: setting" },
            \high, { "high: setting" },
            { "auto: " ++ (if (model.isEmpty) { "unknown board" } { model }) });
        if (high.not) { ^this.standardPerformance(reason) };
        seconds = this.highBufferChoices.select({ arg each; each <= wanted }).detect({ arg each;
            memAvailableKB.notNil and: {
                (memAvailableKB - (this.highMemoryBytes(each, sampleRate) / 1024)) >= this.minFreeMemKB
            }
        }) ? this.highBufferChoices.last;
        if (seconds < wanted) {
            reason = reason ++ "; buffer " ++ wanted ++ " s -> " ++ seconds ++ " s ("
                ++ (if (memAvailableKB.isNil) { "meminfo unreadable" } { "memory" }) ++ ")";
        };
        ^(tier: \high, bufferSeconds: seconds, maxGrains: this.tierMaxGrains,
            historySeconds: this.highHistorySeconds, reason: reason)
    }

    // performance_active.data's text: one "key value" line per value
    activePerformanceText { arg decision;
        ^"tier %\nbuffer_seconds %\nmax_grains %\nhistory_seconds %\nreason %\n".format(decision[\tier],
            decision[\bufferSeconds], decision[\maxGrains], decision[\historySeconds], decision[\reason])
    }

    // Write performance_active.data, synchronously, so it exists before
    // alloc returns. The old file is deleted first (a start that cannot
    // write leaves none, and Lua then runs standard). The text goes to
    // path.<instanceTag>-<generation>.part, renamed into place with mv -f;
    // the final path is never opened for writing. Returns false when the
    // file could not be written (no .part is left)
    writeActivePerformance { arg decision;
        var path = this.activePerformancePath, partPath, file, written = false;
        if (File.exists(path)) { try { File.delete(path) } };
        if (File.exists(path)) {
            postln("strata: cannot remove the old " ++ path);
            ^false
        };
        try { File.mkdir(path.dirname) };
        writeCount = writeCount + 1;
        partPath = path ++ "." ++ instanceTag ++ "-" ++ writeCount ++ ".part";
        file = try { File.open(partPath, "w") } { nil };
        if (file.notNil and: { file.isOpen }) {
            written = try { file.write(this.activePerformanceText(decision)); true } { false };
            file.close;
        };
        written = written and: { ("mv -f " ++ partPath.shellQuote ++ " " ++ path.shellQuote).systemCmd == 0 };
        if (File.exists(partPath)) { try { File.delete(partPath) } };
        ^written and: { File.exists(path) }
    }
}
