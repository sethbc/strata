// test/engine_check/performance.scd
// The performance area (lib/engine/StrataPerformance.sc): the setting it
// reads (performance.data), the board model and MemAvailable it decides
// with, the tier it picks, the active file it writes
// (performance_active.data) through a .part, and the tier values the other
// areas build with. Fake settings, model and meminfo files live in
// h.tempDir; engines built on them go through h.startEngine.
{ arg h;
var engine = h.engine, server = h.server;
var check = { arg condition, message; h.check(condition, message) };
var root = h.tempDir +/+ "performance";
var writeText = { arg path, text;
    File.mkdir(path.dirname);
    File.use(path, "w", { arg file; file.write(text) });
};
var readText = { arg path; if (File.exists(path)) { File.readAllString(path) } { nil } };
// Engine_Strata classvars set for one call (as buildEngine sets them for a
// build): settings is an Array of [key, value] pairs, so a nil value (the
// norns default) can be set too
var withClassvars = { arg settings, function;
    var saved = settings.collect({ arg pair; [pair[0], Engine_Strata.perform(pair[0])] }), result;
    settings.do({ arg pair; Engine_Strata.perform((pair[0].asString ++ "_").asSymbol, pair[1]) });
    result = function.value;
    saved.do({ arg pair; Engine_Strata.perform((pair[0].asString ++ "_").asSymbol, pair[1]) });
    result
};
// The setting read from a performance.data holding text (nil: no file)
var settingFrom = { arg name, text;
    var dir = root +/+ name;
    File.mkdir(dir);
    if (text.notNil) { writeText.(dir +/+ "performance.data", text) };
    withClassvars.([[\settingsDir, dir]], { engine.readPerformanceSetting })
};
var setting = { arg performance, seconds = 60; (performance: performance, bufferSeconds: seconds) };
var decide = { arg choice, model, memKB = 2100000, seconds = 60;
    engine.performanceDecision(setting.(choice, seconds), model, memKB, 48000)
};
// "key value" lines of a file, as a Dictionary of Strings
var keyValues = { arg text;
    var fields = Dictionary.new;
    (text ? "").split($\n).do({ arg line;
        var space = line.indexOf(Char.space);
        if (space.notNil) { fields[line.copyRange(0, space - 1)] = line.copyToEnd(space + 1) };
    });
    fields
};
var models = (
    pi4: "Raspberry Pi 4 Model B Rev 1.4", cm4: "Raspberry Pi Compute Module 4 Rev 1.0",
    cm4s: "Raspberry Pi Compute Module 4S Rev 1.0", cm3: "Raspberry Pi Compute Module 3 Plus Rev 1.0",
    pi3: "Raspberry Pi 3 Model B Plus Rev 1.3", unknown: "Generic x86 desktop", empty: ""
);
var decision, other, dir, text, fields, parts, stale, fresh, result, readOnlyRun;

File.mkdir(root);

// The main engine: standard, as every check engine without a setting is
// (an unknown board on auto)
check.(engine.tier == \standard and: { engine.bufferSeconds == 16 } and: { engine.maxGrains == 128 }
    and: { engine.historySeconds == 16 }, "performance: the check's engine runs standard (16 s, 128 grains, 16 s history)");
check.(engine.numBuffers == 8 and: { engine.standardBufferSeconds == 16 }, "performance: numBuffers 8, standardBufferSeconds 16");
check.((engine.buffersL ++ engine.buffersR).every({ arg buffer; buffer.numFrames == (server.sampleRate * 16) }),
    "performance: each standard buffer holds 16 s at the server rate");
check.(engine.highBufferChoices == #[300, 120, 60, 16] and: { engine.highHistorySeconds == 60 }
    and: { engine.minFreeMemKB == 1048576 }, "performance: the high tier's constants");

// The tier from the setting and the board
check.(models.values.every({ arg model; decide.(\standard, model)[\tier] == \standard }),
    "performance: standard gives standard on any board");
decision = decide.(\high, models[\cm3]);
check.(decision[\tier] == \high and: { decision[\bufferSeconds] == 60 } and: { decision[\historySeconds] == 60 },
    "performance: high gives high on a CM3 model (got %)".format(decision));
check.([models[\pi4], models[\cm4], models[\cm4s]].every({ arg model; decide.(\auto, model)[\tier] == \high }),
    "performance: auto gives high for Raspberry Pi 4 Model B Rev 1.4 and Raspberry Pi Compute Module 4 / 4S");
check.([models[\cm3], models[\pi3], models[\unknown], models[\empty], nil].every({ arg model;
    decide.(\auto, model)[\tier] == \standard }),
    "performance: auto gives standard for a CM3, a Pi 3, an unknown and an empty model");
check.([\standard, \auto].every({ arg choice; decide.(choice, models[\cm3])[\bufferSeconds] == 16 })
    and: { decide.(\standard, models[\pi4], 2100000, 300)[\bufferSeconds] == 16 },
    "performance: standard always has 16 s slots");

// The step-down from a 300 s setting at 48 kHz
result = [[2100000, 300], [1800000, 120], [1350000, 60], [1150000, 16], [nil, 16]].reject({ arg pair;
    decide.(\high, models[\pi4], pair[0], 300)[\bufferSeconds] == pair[1]
});
check.(result.isEmpty, "performance: the 300 -> 120 -> 60 -> 16 step-down (wrong for MemAvailable %)".format(
    result.collect(_.first)));
check.(decide.(\high, models[\pi4], 2100000, 120)[\bufferSeconds] == 120
    and: { decide.(\high, models[\pi4], 2100000, 16)[\bufferSeconds] == 16 },
    "performance: the setting's length is the most it gets");
check.(decide.(\high, models[\pi4], 1800000, 300)[\reason].contains("300 s -> 120 s (memory)"),
    "performance: a step-down is in the reason");
// The memory each length needs: slots, every voice's ring and the input ring
check.(engine.highMemoryBytes(60, 48000) == ((8 * 2 * 60 * 48000 * 4) + (7 * 2 * 4 * 48000 * 4)
    + (2 * (60 + 4 + 1) * 48000 * 4)), "performance: the high tier's memory per length");

// The files it reads
check.(settingFrom.("missing", nil) == setting.(\auto, 60), "performance: a missing settings file means auto and 60 s");
result = [
    ["garbled", "performance turbo\nbuffer_seconds 999\n"],
    ["truncated", "performance hi"],
    ["newer", "performance ultra\nbuffer_seconds 600\nfreeze_tables 4\n"],
    ["binary", String.newFrom([0, 255, 10, 7, 112].collect(_.asAscii))],
    ["empty", ""],
    ["extra words", "performance high please\nbuffer_seconds 60 s\n"]
].reject({ arg pair; settingFrom.(pair[0], pair[1]) == setting.(\auto, 60) });
check.(result.isEmpty, "performance: a garbled settings file means auto and 60 s (wrong for %)".format(
    result.collect(_.first)));
check.(settingFrom.("valid", "performance high\r\nbuffer_seconds 120\r\n") == setting.(\high, 120)
    and: { settingFrom.("one bad", "performance standard\nbuffer_seconds 61\n") == setting.(\standard, 60) },
    "performance: each key is read on its own (CRLF too)");
writeText.(root +/+ "model", "Raspberry Pi 4 Model B Rev 1.4" ++ 0.asAscii);
writeText.(root +/+ "model-padded", " Raspberry Pi Compute Module 4 Rev 1.0\n" ++ 0.asAscii ++ 0.asAscii);
check.(withClassvars.([[\modelPath, root +/+ "model"]], { engine.readBoardModel }) == models[\pi4]
    and: { withClassvars.([[\modelPath, root +/+ "model-padded"]], { engine.readBoardModel }) == models[\cm4] }
    and: { withClassvars.([[\modelPath, root +/+ "no-model"]], { engine.readBoardModel }) == "" },
    "performance: the board model, without NULs and outer whitespace, or empty");
writeText.(root +/+ "meminfo", "MemTotal:        3884000 kB\nMemFree:          900000 kB\nMemAvailable:    2100000 kB\n");
writeText.(root +/+ "meminfo-none", "MemTotal:        3884000 kB\n");
check.(withClassvars.([[\meminfoPath, root +/+ "meminfo"]], { engine.readMemAvailableKB }) == 2100000
    and: { withClassvars.([[\meminfoPath, root +/+ "meminfo-none"]], { engine.readMemAvailableKB }).isNil }
    and: { withClassvars.([[\meminfoPath, root +/+ "no-meminfo"]], { engine.readMemAvailableKB }).isNil },
    "performance: MemAvailable in kB, or nil");
if (File.exists("/proc/meminfo")) {
    result = withClassvars.([[\meminfoPath, nil]], { engine.readMemAvailableKB });
    check.(result.isInteger and: { result > 0 }, "performance: /proc/meminfo is read line by line (got %)".format(result));
};

// A high engine: the active file, its values and the slots it allocates
dir = root +/+ "high/";
writeText.(dir +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
other = h.startEngine((settingsDir: dir, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
fields = keyValues.(readText.(dir +/+ "performance_active.data"));
check.(fields["tier"] == "high" and: { fields["buffer_seconds"] == "60" } and: { fields["max_grains"] == "128" }
    and: { fields["history_seconds"] == "60" } and: { fields["reason"] == "high: setting" } and: { fields.size == 5 },
    "performance: the active file holds tier, buffer_seconds, max_grains 128, history_seconds and reason (got %)".format(fields));
check.(other.tier == \high and: { other.bufferSeconds == 60 } and: { other.historySeconds == 60 }
    and: { other.maxGrains == 128 } and: { (other.historySeconds + other.ringGuardSeconds + 1) == 65 }
    and: { (other.buffersL ++ other.buffersR).every({ arg buffer; buffer.numFrames == (server.sampleRate * 60) }) },
    "performance: a high engine allocates 60 s slots and a 65 s input history budget");
parts = (dir +/+ "*.part").pathMatch;
check.(parts.isEmpty and: { File.exists(dir +/+ "performance_active.data") },
    "performance: the active file is written through a .part and never left as one (left: %)".format(parts));
h.freeEngine(other);
// written only through path.<instanceTag>-<generation>.part, renamed with mv -f
text = Engine_Strata.findMethod(\writeActivePerformance);
text = File.readAllString(text.filenameSymbol.asString).copyRange(text.charPos,
    File.readAllString(text.filenameSymbol.asString).find("\n    }", offset: text.charPos));
check.(text.contains("\".part\"") and: { text.contains("instanceTag") } and: { text.contains("mv -f") }
    and: { text.contains("File.open(path").not } and: { text.contains("File.use(path").not },
    "performance: writeActivePerformance writes a .part and renames it, never the final path");

// auto on a Pi 4 with a garbled setting: high, 60 s
dir = root +/+ "auto/";
writeText.(dir +/+ "performance.data", "performance turbo\nbuffer_seconds 999\n");
writeText.(dir +/+ "performance_active.data", "tier high\nbuffer_seconds 300\n");  // a previous start's
other = h.startEngine((settingsDir: dir, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
fields = keyValues.(readText.(dir +/+ "performance_active.data"));
check.(other.tier == \high and: { other.bufferSeconds == 60 } and: { fields["tier"] == "high" }
    and: { fields["buffer_seconds"] == "60" } and: { fields["reason"] == ("auto: " ++ models[\pi4]) },
    "performance: a garbled settings file means auto and 60 s, and the active file says so (got %)".format(fields));
h.freeEngine(other);

// An unwritable settings folder (below a regular file): standard, and no file
writeText.(root +/+ "regular-file", "not a folder");
dir = root +/+ "regular-file/settings/";
other = h.startEngine((settingsDir: dir, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
check.(other.tier == \standard and: { other.bufferSeconds == 16 } and: { other.historySeconds == 16 }
    and: { File.exists(dir +/+ "performance_active.data").not },
    "performance: an unwritable settings dir runs standard");
h.freeEngine(other);
// An active file that cannot be replaced (a folder with a file in it): standard, no .part left
dir = root +/+ "blocked/";
writeText.(dir +/+ "performance.data", "performance high\nbuffer_seconds 60\n");
writeText.(dir +/+ "performance_active.data/inside", "keeps the folder");
other = h.startEngine((settingsDir: dir, modelPath: root +/+ "model", meminfoPath: root +/+ "meminfo"));
parts = (dir +/+ "*.part").pathMatch;
check.(other.tier == \standard and: { parts.isEmpty },
    "performance: an active file that cannot be replaced runs standard and leaves no .part (left: %)".format(parts));
h.freeEngine(other);

// An old active file the engine cannot remove (#153): Lua will read it, so
// the engine runs what it says, read by Lua's rules (parse_active_text;
// test/unit/performance_test.lua checks Lua on the same texts)
check.(engine.parseActivePerformance("tier high\r\nbuffer_seconds 120\r\nmax_grains 128\r\nhistory_seconds 60\r\nreason x y\r\n")
    == (tier: \high, bufferSeconds: 120, maxGrains: 128, historySeconds: 60, reason: "x y"),
    "performance: parseActivePerformance reads a valid file (CRLF too)");
check.(engine.parseActivePerformance("  tier standard \nbuffer_seconds 16\nmax_grains 128\nhistory_seconds 16\n")
    == (tier: \standard, bufferSeconds: 16, maxGrains: 128, historySeconds: 16, reason: ""),
    "performance: and a valid standard file without a reason");
check.(engine.parseActivePerformance("tier high\nbuffer_seconds 300\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n")
    [\bufferSeconds] == 60, "performance: the last line of a key wins, as in Lua");
result = [
    nil, "", "tier high\n", "tier turbo\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 61\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60 s\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60.5\nmax_grains 128\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60\nmax_grains 64\nhistory_seconds 60\n",
    "tier high\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 16\n",
    "tier standard\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 16\n",
    "tier high please\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\n"
].reject({ arg text; engine.parseActivePerformance(text).isNil });
check.(result.isEmpty, "performance: parseActivePerformance refuses what Lua refuses (accepted %)".format(result));
// An old file in a settings folder the engine cannot write to: [tier,
// bufferSeconds, reason, the file's text after, .part files left], or nil
// when the folder is writable anyway (as root)
writeText.(root +/+ "meminfo-1350000", "MemAvailable:    1350000 kB\n");
readOnlyRun = { arg name, stale, settingText, meminfo = "meminfo";
    var folder = root +/+ "readonly-" ++ name ++ "/", engineThere, writable, outcome;
    writeText.(folder +/+ "performance.data", settingText);
    writeText.(folder +/+ "performance_active.data", stale);
    ("chmod 555 " ++ folder.shellQuote).systemCmd;
    writable = try { File.use(folder +/+ "probe", "w", { arg file; file.write("x") }); File.exists(folder +/+ "probe") } { false };
    if (writable.not) {
        engineThere = h.startEngine((settingsDir: folder, modelPath: root +/+ "model", meminfoPath: root +/+ meminfo));
        outcome = [engineThere.tier, engineThere.bufferSeconds, engineThere.areaState[\performance][\decision][\reason],
            readText.(folder +/+ "performance_active.data"), (folder +/+ "*.part").pathMatch,
            engineThere.bufferLengthValue];
        h.freeEngine(engineThere);
    };
    ("chmod 755 " ++ folder.shellQuote).systemCmd;
    outcome
};
text = "tier high\nbuffer_seconds 60\nmax_grains 128\nhistory_seconds 60\nreason high: setting\n";
fields = readOnlyRun.("high", text, "performance standard\n");
if (fields.isNil) {
    check.(true, "performance: (skipped: a read-only settings folder is still writable here, as root)");
} {
    check.(fields[0] == \high and: { fields[1] == 60 } and: { fields[3] == text } and: { fields[4].isEmpty },
        "performance: an old high active file that cannot be removed runs high, 60 s, as Lua will read it (got %)".format(fields));
    check.(fields[2].contains("could not be replaced"), "performance: and the reason says why (got %)".format(fields[2]));
    fields = readOnlyRun.("high-memory", "tier high\nbuffer_seconds 300\nmax_grains 128\nhistory_seconds 60\nreason x\n",
        "performance high\nbuffer_seconds 300\n", "meminfo-1350000");
    check.(fields[0] == \high and: { fields[1] == 60 } and: { fields[2].contains("300 s -> 60 s (memory)") },
        "performance: an old high 300 s file runs high with the memory step-down (got %)".format(fields));
    check.(fields[5] == 8060, "performance: and reports its 60 s slots to Lua as bufferState 8 * 1000 + 60 (got %)".format(fields[5]));
    fields = readOnlyRun.("standard", "tier standard\nbuffer_seconds 16\nmax_grains 128\nhistory_seconds 16\nreason x\n",
        "performance high\nbuffer_seconds 60\n");
    check.(fields[0] == \standard and: { fields[1] == 16 },
        "performance: an old standard file that cannot be removed runs standard, whatever the setting (got %)".format(fields));
    fields = readOnlyRun.("garbled", "tier high\nbuffer_seconds 61\n", "performance high\nbuffer_seconds 60\n");
    check.(fields[0] == \standard and: { fields[1] == 16 },
        "performance: an old file Lua cannot read runs standard, as Lua will (got %)".format(fields));
};

// A crash's .part in the settings folder: deleted at alloc once stale, a fresh one kept
dir = root +/+ "stale/";
stale = dir +/+ "performance_active.data.1234-5.part";
fresh = dir +/+ "performance.data.part";
writeText.(stale, "tier hi");
("touch -t 202001010000 " ++ stale.shellQuote).systemCmd;
writeText.(fresh, "performance high\n");
other = h.startEngine((settingsDir: dir));
check.(File.exists(stale).not and: { File.exists(fresh) } and: { File.exists(dir +/+ "performance_active.data") },
    "performance: a stale performance_active.data .part older than stalePartAge is deleted at alloc");
check.(other.stalePartDirs.includesEqual(dir.withoutTrailingSlash),
    "performance: stalePartDirs holds the settings folder (got %)".format(other.stalePartDirs));
h.freeEngine(other);

// The bufferState poll carries slot * 1000 + seconds
check.(engine.bufferStateStride == 1000, "performance: bufferStateStride is 1000");
h.command(\loadBuffer, 2, h.stereoPath);
check.(h.waitFor({ engine.bufferFrames[2] > 0 }, 3) and: { engine.bufferStateValue(2) == 2000.5 }
    and: { h.waitFor({ h.pollValueNear(\bufferState, 2000.5, 0.001) }, 3) },
    "performance: bufferState carries slot * 1000 + seconds (got %)".format(engine.bufferStateValue(2)));
// matron's poll float is 32 bits: 0.01 s steps survive up to 7 * 1000 + 300 s
check.((FloatArray[7300.0][0] == 7300) and: { (FloatArray[7299.99][0] - 7299.99).abs < 0.001 }
    and: { FloatArray[2016.5][0] == 2016.5 },
    "performance: the largest value, 7 * 1000 + 300 s, keeps 0.01 s in a 32-bit float");
// ... and, after the slots, the slot length: numBuffers * 1000 + bufferSeconds
check.(engine.bufferLengthValue == 8016 and: { engine.bufferLengthValue.isKindOf(Float) } and: { h.waitFor({ h.pollValues(\bufferState).any({ arg value; (value - 8016).abs < 0.001 }) }, 3) },
    "performance: the periodic bufferState also sends the slot length, 8 * 1000 + 16 (got %)".format(
        h.pollValues(\bufferState).select({ arg value; value >= 8000 }).asSet));
h.command(\clearBuffer, 2);
server.sync;
}
