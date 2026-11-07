// Engine_Strata.sc
// Ambient granular synthesis engine for norns
// Multiple synthesis voices with granular processing
//
// This file holds the class, every variable, *new and the generic alloc
// and free. Everything else is in class extensions under lib/engine/
// (Strata*.sc), one file per part of the engine. The engine's areas
// register themselves: each defines a method strataArea<Name> returning an
// Event (strataAreas in lib/engine/StrataUtil.sc; the contract is in
// docs/notes/engine/structure.md), and alloc and free run them. Later
// work adds an area file, never a variable or a line here.

Engine_Strata : CroneEngine {
    // The performance area's files (nil = the norns defaults); the engine
    // check sets them before it builds an engine
    classvar <>settingsDir, <>modelPath, <>meminfoPath;

    var <numVoices = 7;  // Must match NUM_VOICES in strata.lua
    var <voiceSynthDefs;
    var <synths;
    var <granBuses;
    var <mainBus;   // grain outputs mix here
    var <filterBus; // filter output, delay input
    var <delayBus;  // delay output, reverb input
    var <reverbBus;
    var <modBuses;  // Control buses for cross-modulation
    var <silentBus; // Always-zero control bus used for "no modulation source"
    var <envBuffers; // Grain envelope shapes 1-4 (envShape 0 is GrainIn's built-in Hann)
    var <voiceGroup;   // Input synth and voice synths (head of context.xg)
    var <processGroup; // Grain synths, then mod synths (after voiceGroup)

    // Audio sources: grainSource[voice] is 0 = the voice's synth,
    // 1..numBuffers = buffer slot, numBuffers + 1 = live input
    var <numBuffers = 8;      // Must match NUM_BUFFERS in strata.lua
    var <>bufferSeconds = 16;  // Must match BUFFER_SECONDS in strata.lua (set by the performance area)
    var <numModSlots = 3;     // Crossmod slots per voice (modBus1..3): must match NUM_MOD_SLOTS in strata.lua
    var <buffersL, <buffersR; // One mono buffer per channel per slot (GrainBuf reads mono only)
    var <bufferFrames;        // Valid (loaded or recorded) frames per slot; 0 = empty
    var <bufferSampleRates;   // Sample rate of each slot's content (valid seconds = frames / rate)
    var <recordSynths;        // Running strataRecord synth per slot, or nil
    var <recordFrameBuses;    // Per slot: frames recorded so far, written by strataRecord
    var <slotChanges;         // Per slot: counts loads, records, clears and stops; a late reply applies only if unchanged
    var <stopReplies;         // Per slot: the slotChanges count of a stopRecord whose frame count is still awaited, or nil
    var <bufferLoads;         // Per slot: loadBuffer commands received (Lua's load_buffer counts the same), named in bufferLoadFailed
    var <inputBus;            // Stereo live input, written by inputSynth
    var <inputSynth;
    var <grainSource;
    var <voiceControls; // Per voice: voice synth controls (params, crossmod) for restarts
    var <grainControls; // Per voice: grain synth controls, carried into a replacement
    var <releasingSynths;     // Per voice: released synths still in their release (key -> Synth), re-gated by voiceOn
    var <releasedGrainSource; // Per voice: the source its releasing grain synth was built for
    var controlNameSets;      // Per voice and grain SynthDef: its control names (IdentitySet), for controlPairs
    var <fadingSynths;        // Per voice: grain and voice synths a source switch gated off, still releasing
    var <cuttingSynths;       // Per voice: grain and voice synths in their kill fade (cutSynth), freed by the next switch
    var <grainSlots;          // Every strataGrainBuf synth until it frees (live, releasing, fading or cutting) -> the slot index it reads
    var <modSpeeds;           // Per voice: the last setModSpeed (nil until one arrives), for a restarted strataMod
    var <bufferStatePoll;
    var bufferStateCursor = 0;
    var <bufferLoadFailedPoll;    // value = (load number * 2 + emptied) * numBuffers + slot index (bufferLoadFailedValue)
    var <loadCheckFrames = 16384; // Frames per chunk when loadSlot decodes a file to check it (fileDecodes)
    var <loadShortfallFrames = 4096; // Frames a file may decode short of its header's count and still load (fileDecodes)
    var <grainRelease = 2;        // Release time of both grain SynthDefs
    var <switchCutTime = 0.05;    // Length of the kill fade (cutSynth); built into the SynthDefs in alloc, so later changes do nothing
    // Real-time memory (see docs/notes/engine/memory.md). Both
    // are built into the grain SynthDefs in alloc, so later changes do nothing.
    var <pitchShiftWindow = 0.1;  // Grain PitchShift window (s): fixed, never the grain size (its delay line is allocated at that size)
    var <>maxGrains = 128;        // Grain table of every GrainIn/GrainBuf: Lua's largest overlap is 0.5 s x 200 grains/s = 100 (set by the performance area)
    // Built into the SynthDefs in alloc too (see Signal safety in docs/notes/engine/structure.md)
    var <filterCeiling = 0.45;    // Highest Resonator cutoff, as a fraction of the sample rate: below Nyquist, so RLPF stays stable
    var <grainEndMargin = 4;      // Frames a buffer grain stops short of the valid region's end (interpolation, rounding)
    var <resonatorGain = 0.02;    // DynKlank on noise rings ~50x hotter than the other voices: brings the Resonator's default level (peak ~0.5) in line
    var <voiceCeiling = 1;        // The Resonator's voice limiter level: its reachable extremes (low freq, noise 1, full crossmod) peak far higher
    var <voiceLimiterLookahead = 0.003; // The Resonator limiter's lookahead (s): Limiter delays the voice by twice this (its default 0.01 s: 20 ms)
    var <>scratchDir;             // Where completed recordings are written (buf<n>.wav)
    var writeCount = 0;
    var <writeGenerations;        // Per output path: the newest write's number; older writes abandon
    var <>writeChunkWait = 0.001; // Pause between interleave chunks (the engine check slows it)
    var <int16Peak = 0.999969482421875; // 32767 / 32768: the largest sample a 16-bit write keeps (symmetric clip)
    var <instanceTag;             // Unique per engine instance in the sclang session; part of every temporary and .part name
    var <stalePartAge = 60;       // deleteStaleParts deletes only .part files older than this (s)
    // Wait after fading a slot's grain synths (bufFrames 0; strataGrainBuf's
    // hasAudio lag is 0.05 s) before zeroing or overwriting it. The engine check lengthens it.
    var <>bufferFadeWait = 0.06;
    // nil: warnInvariant posts its line with String.warn. A function takes
    // the line instead (the engine check captures the lines it provokes, so
    // they do not fail the run)
    var <>postInvariantWarning;
    // nil: deleteStaleParts posts each file it cannot age with postln. A
    // function takes the line instead (the engine check captures it)
    var <>postStaleFileLine;
    // The persistent synths' keys (the effects chain's): they never end on
    // their own, so setSynth sends to them plainly (a failure there is a
    // real bug and is reported). Built from the areas' effectKeys in alloc.
    var <effectKeys;
    // Tier values the performance area sets (with bufferSeconds and maxGrains)
    var <>historySeconds = 16;    // Seconds of live input history
    var <>tier = \standard;       // \standard or \high
    // Area registration (see alloc)
    var <areaState;               // Area name -> IdentityDictionary: each area's own state
    var areas;                    // The areas' Events (strataAreas), in ascending order
    var grainDefTable;            // The areas' grainDefs: source predicate -> grain SynthDef name (grainDefFor)
    var grainParamHandlers;       // The areas' grainParamHandlers: grain param name -> function (setGrainParam)

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    // Runs each phase across every area in ascending order: allocState
    // (buses, buffers and state; the performance area first sets the tier
    // values), addDefs (SynthDefs; each area returns the names whose
    // controls controlPairs must know), then, after a sync, addCommands
    // (commands and polls) and start (persistent nodes). effectKeys,
    // grainDefTable, grainParamHandlers and controlNameSets are built from
    // what the areas register.
    alloc {
        var defNames = List.new;
        areas = this.strataAreas;
        areaState = IdentityDictionary.new;
        areas.do({ arg area; areaState[area[\name]] = IdentityDictionary.new });
        effectKeys = areas.inject([], { arg keys, area; keys ++ (area[\effectKeys] ? []) });
        grainDefTable = areas.inject([], { arg table, area; table ++ (area[\grainDefs] ? []) });
        grainParamHandlers = IdentityDictionary.new;
        areas.do({ arg area;
            (area[\grainParamHandlers] ? ()).keysValuesDo({ arg name, handler;
                if (grainParamHandlers[name].notNil) { Error("Strata: two areas handle grain param " ++ name).throw };
                grainParamHandlers[name] = handler;
            });
        });

        areas.do({ arg area; area[\allocState].value });
        areas.do({ arg area; defNames.addAll(area[\addDefs].value ? []) });

        // The control names of every SynthDef controlPairs filters for, looked up once
        controlNameSets = IdentityDictionary.new;
        defNames.do({ arg defName;
            controlNameSets[defName] = SynthDescLib.global.at(defName).controlNames.collect(_.asSymbol).as(IdentitySet);
        });

        context.server.sync;

        areas.do({ arg area; area[\addCommands].value });
        areas.do({ arg area; area[\start].value });
    }

    // Two passes, each in descending order: every area's stop (its nodes:
    // recordings canceled, synths and groups freed), then every area's free
    // (its buses and buffers), so no bus or buffer is freed while a node of
    // any area still uses it
    free {
        if (areas.isNil) { ^this };
        areas.reverseDo({ arg area; area[\stop].value });
        areas.reverseDo({ arg area; area[\free].value });
    }
}
