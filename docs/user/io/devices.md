# Supported devices

Two devices that need no code of their own, the OXI ONE and the Disting NT, with a setup for each, and then one table of every device Strata 3.6 reaches. Back to [IO](../pages/io.md).

Everything here is built from the makers' documents and the sources of norns and the other projects. None of it has been tried on a device: it is unverified until the 4.0 hardware check, and where a document does not say something, this page says so.

## An OXI ONE as the sequencer

An OXI ONE (or an ONE MKII) can play Strata's seven voices, one MIDI channel for each, set the tempo, and recall scenes with program changes. Strata needs nothing set up on its side but the MIDI port and a few settings.

**Connect it.** The OXI ONE has to be in USB device mode (Config > System > USB Mode: `Device`), so norns, the host, drives the connection. Its default mode after power-up is not stated in the manuals. Plug it into one of norns' USB ports and look for it in SYSTEM > DEVICES > MIDI.

**Notes.** Strata's default is one channel for each voice: channel 1 plays voice 1 (Resonator), up to channel 7 for voice 7 (Ring), and channels 8 to 16 are ignored (SETUP's `channels` row, `per voice`; see [MIDI Input](../midi.md)).
1. In PARAMETERS > midi, set `midi device` to the OXI's port.
2. On the OXI, use a Multitrack sequencer: eight monophonic tracks, each with its own channel and output. Give seven of them channels 1 to 7 and the output the USB port. The Poly sequencer plays up to seven notes in a step on one channel, which Strata plays as a chord on that voice (a voice has up to eight notes).
3. A track's notes reach Strata as played notes, with velocity, so each voice's [notes settings](../midi.md) (note off, latch, pressure) apply to them. The OXI's documents do not mention MPE, so treat it as a plain MIDI source.

**The clock.** Two ways, and Strata follows either; it never starts or stops norns' clock itself.
- *The OXI leads.* In PARAMETERS > CLOCK, set the source to `midi` and pick the OXI's port. On the OXI, turn on `MIDI Transport Msgs Send` (a setting of the first generation's guide, in its configuration) so it sends clock, start and stop. With `follow transport` on (PARAMETERS > sequencer; SETUP's `transport` row; it is on by default), the OXI's Start plays every voice's pattern from step 1 and its Stop stops them ([Sequencer](../sequencer.md)).
- *norns leads.* In PARAMETERS > CLOCK, turn on `midi clock out` for the OXI's port, and on the OXI set the sync source to USB. The OXI's Auto Sync setting decides whether it starts on norns' MIDI Start.

The OXI's documents say it reads and sends MIDI clock at 24 pulses per quarter note. Whether it sends or reads Song Position Pointer or MIDI Continue is not stated.

**Scenes from the arranger.** Strata recalls scene 1 to 16 when it hears program change 0 to 15 (see [MIDI out](midi-out.md), Program change).
1. On the IO page, in the `midi` section, turn `pc in` on, and set `pc channel` to the channel the OXI sends program changes on (or `any`). Strata listens on the `midi device` port, so the OXI has to be on that port.
2. On the OXI, give each arranger slot a program change (the slot's PC setting; each pattern also has a PC value, and the slot's `=` setting uses it). The OXI sends it two clock ticks before the pattern changes, so a scene recall that waits for the bar (PARAMETERS > sequencer, `quantize actions`) lands on the bar.
3. The OXI's manual says its PC values run 1 to 128, and does not say whether 1 goes out as program 0. Try one slot first: if the scene you get is one off, change the slot's values by one.

An empty scene does nothing. Leave `pc out` off on the OXI's port unless you want Strata's recalls to move the OXI too: the OXI takes an incoming program change as a choice of arranger column. A scene recall that came from the OXI is never sent back to its port.

## A Disting NT as a MIDI target

The Expert Sleepers disting NT is a class-compliant USB MIDI device (it is not a USB host), so norns, the host, reaches it with no driver. It is a target of MIDI out: a voice's steps and played notes go to its polysynth algorithms, as plain MIDI or as MPE. Its USB port name as Linux lists it is not stated; look for it in SYSTEM > DEVICES > MIDI.

**Plain.** In PARAMETERS > out midi (or the `midi` row of IO's `voice` section), set the voice's `out port` to the NT's port, `out channel` to the channel the algorithm's `MIDI channel` setting names, and leave `out mode` at `plain`. Each voice can feed a different algorithm on a different channel.

**MPE.** The NT's polysynth algorithms support MPE: per-note pitch bend, aftertouch and the Y dimension (CC 74). Strata's MPE voice takes the lower zone, channel 1 as the master and the members from channel 2.
1. On the NT, set the algorithm's `MIDI channel` to 1 (the common channel; with 1, the note channels run from 2 upward) and its `MPE channels` to the number of members you will use.
2. In Strata, set the voice's `out mode` to `mpe`, `out members` to the same number (1 to 15; 15 by default), and `out bend range` to the bend range the algorithm uses. Strata sends the MPE configuration message and the member channels' bend range when the mode turns on and when the NT is plugged in (see [MIDI out](midi-out.md), MPE). The NT's documents do not say whether the algorithm acts on those messages, so set its channels by hand as well.
3. A note you play on Strata carries its own bend, pressure and slide (CC 74) to its member channel. A step's note has none: its channel gets a centered bend.

**Control changes.** A CC slot (`cc 1` to `cc 8` in the `midi` section) sends a modulation source as a CC. The NT maps CCs to algorithm parameters in its MIDI mappings (type `CC`, with a channel and a CC number, 0 to 127); set the mapping's channel and number to the slot's, and give it a range. A slot sends 7 bits, so a mapping of the 14-bit types gets nothing usable.

**Presets.** With program change enabled on the NT, a program change loads a preset: one whose file name contains `#<program number>`, or else the file at that place in the sorted list. Turn `pc out` on, with `pc out port` the NT's port, and each scene recall sends program (scene - 1), 0 to 15.

**Not supported.** Strata's ii bus covers only the modules on its own pages, so it does not talk to the NT's i2c.

## Every supported device

"How" says which part of Strata reaches the device. Every row is unverified on the device until the 4.0 hardware check (issue #6).

| Device | How Strata reaches it | Page | Built from | Status |
|---|---|---|---|---|
| Any MIDI synth or sampler, plain or MPE | MIDI out: a voice's steps and played notes, eight CC slots, program change | [MIDI out](midi-out.md) | MIDI 1.0 specification; MIDI Polyphonic Expression 1.0 (the MMA's RP-053); norns' `lua/core/midi.lua` | Unverified until 4.0 |
| Expert Sleepers disting NT | MIDI out, over USB | this page | disting NT user manual 1.17 (firmware list at 1.19.0) | Unverified until 4.0 |
| OXI ONE, ONE MKII | MIDI input per voice, MIDI clock and transport, program change in | this page | OXI ONE user guide v3.8 (2023, first generation); ONE MKII online manual, firmware 2.2.10 | Unverified until 4.0 |
| OXI E16 | Controllers: its sixteen encoders on the macros, rings and labels back | [Controllers](controllers.md) | OXI E16 user manual 1.0.1a | Unverified until 4.0 |
| 16n, 16nx, ATOV Faderpunk, other boxes of sixteen faders | Controllers: sixteen faders on the macros, with pickup | [Controllers](controllers.md) | 16n firmware 2.1.0's README and SysEx specification (CC 32 to 47, channel 1, 14-bit mode); the 16nx firmware; Faderpunk's source at github.com/ATOVproject/faderpunk | Unverified until 4.0 |
| monome crow | The crow section: inputs, outputs, clock out; the bridge for every ii device | [crow](crow.md) | crow firmware v4.0.5 and its reference; norns' `lua/core/crow.lua` | Unverified until 4.0 |
| Teletype | The ii bus: `CROW.C1` to `CROW.C3` | [The ii bus and Teletype](ii.md) | Teletype v5.0.0; monome's ii page | Unverified until 4.0 |
| Mannequins Just Friends | ii, through crow | [Just Friends](jf.md) | Just-Type (Just Friends' ii commands); crow v4.0.5's `lua/ii/jf.lua` | Unverified until 4.0 |
| W/ synth and W/ tape | ii, through crow | [W/](w.md) | the W/ wiki (github.com/whimsicalraps/wslash); crow v4.0.5's `lua/ii/wsyn.lua` and `wtape.lua` | Unverified until 4.0 |
| ER-301 | ii, through crow | [ER-301 and TELEXo](er301-txo.md) | crow v4.0.5's ii descriptor for the ER-301; Teletype's notes on the ER-301 | Unverified until 4.0 |
| TELEXo | ii, through crow | [ER-301 and TELEXo](er301-txo.md) | crow v4.0.5's ii descriptor for the TELEXo; the TELEX README | Unverified until 4.0 |
| nb voice mods (nb_crow, nb_jf, nb_ex, nb_drumcrow and others) | nb players, one a voice | [nb voices](nb.md) | nb at commit `400e0b38` (2024-06-15) and the voice mods named in `docs/design/3.6-facts/checks.md` | Unverified until 4.0 |
| monome grid zero, grid one, 2022 grid and the 2025 arc, in iii mode | Remote grids and arcs, over MIDI | [Remote grids and arcs](remote.md) | iii v1.1.2 and its device repositories | Unverified until 4.0 |
| Launchpads, APC mini, Push and others | A MIDI grid through the midigrid mod | [Remote grids and arcs](remote.md) | midigrid, branch `master` at commit `beb75e82` (2026-10-19) | Unverified until 4.0 |
| OSC apps, TouchOSC | OSC in and feedback, two TouchOSC layouts | [OSC and TouchOSC](osc.md) | norns' `lua/core/osc.lua`; TouchOSC's manual (site v1.9.3.541); tosclib 0.3.5 for the layouts' file format | Unverified until 4.0; the layouts have never been opened in TouchOSC |
| norns' softcut | The tape loop | [The tape loop](tape.md) | norns' `lua/core/softcut.lua` and softcut-lib at commit `ce870c55` | Unverified until 4.0 |
