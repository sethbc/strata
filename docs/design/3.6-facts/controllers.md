# Controller facts for the 3.6 design

Gathered 2026-11-13. Each bullet ends in its source. Manuals were downloaded and read as text (PDF text extraction worked for all of them). "FW" = firmware.

Source shorthand:
- E16-MAN = OXI E16 User Manual 1.0.1a (the PDF the maker links from https://oxiinstruments.com/e16/ ), fetched from https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- E16-QS = E16 quick start, https://kmraudio.com/cdn/shop/files/OXI_E16_-_User_Manual.pdf
- ONE-38 = OXI ONE (first generation) User Guide v3.8 (2023), copy at https://www.allfordj.ru/upload/iblock/c0c/wzlkj8g80f29webhefwwn50h621b7ovf/rukovodstvo_polzovatelya_oxi_instruments_one_black_edition.pdf (maker's guide re-hosted by a retailer; the maker's own links are Google Drive files listed at https://oxiinstruments.com/oxi-one/manual )
- MKII-DOC = OXI ONE MKII online manual, FW 2.2.10, https://docs.oxiinstruments.com/oxi-one-mkii-manual/
- NT-MAN = disting NT user manual 1.17, https://expert-sleepers.co.uk/downloads/manuals/disting_NT_user_manual_1.17.pdf (NT firmware list shows 1.19.0 dated 16/10/2026 as latest, https://expert-sleepers.co.uk/distingNTfirmwareupdates.html )

---

## 1. OXI Instruments E16

- 16 push/turn endless encoders, each with an LED ring; OLED screen; shift button. E16-MAN https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Organization (E16-MAN 1.0.1a): up to 16 scenes, 8 shown on home screen (knobs 1-8, next 8 via knobs 9-16); each scene has 12 pages of 16 controls (192 controls per scene) and 16 presets per scene. Each control has 2 destinations plus a push value. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
  - The older quick start says 7 scenes (S.1-S.7 plus SYS) and 12 pages. https://kmraudio.com/cdn/shop/files/OXI_E16_-_User_Manual.pdf (see Surprises)
- Per-destination "Type" options: Off, CC Rel1, CC Rel2, CC Abs, CC14 (High Resolution), PC, PB, AT, Note, NRPN, Script. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Encoding is set per control, per destination (Dest1 and Dest2 each have their own Type, Output port, Channel, CC number, min, max), on the device or in the OXI App. Not a per-layout setting. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- CC Rel 1: sends 1 to increment and 127 to decrement. CC Rel 2: sends 63 to increment and 65 to decrement. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- CC Abs: 0-127, with per-control Minimum and Maximum within 0-127, an "Anchor" push-reset value, and an encoder Mode (Div8/Div4/Div2, Acc0-Acc3, LSp2/4/6, or Scene default). https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- CC14: 14-bit CC (MSB/LSB pair), display scales 1000 or 9999 offered "useful for CC14"; the manual groups NRPN and CC14 as working "in a similar way". Exact MSB/LSB CC pairing (CC n and n+32) is not spelled out in the text read. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- NRPN is a destination Type (same options table: output, channel). https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Output port per destination: Same as Page, TRS1, TRS2, USB1, USB2, USB3, BLE, ALL-BLE, ALL-USB, Off. So 3 USB output ports. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- The maker's product page says the E16 shows as 3 virtual MIDI ports over USB. https://oxiinstruments.com/e16/
- Push: a separate push value per control. For CC the Mode is Press Only, Press & Release, or Toggle, with P.Val (value on push) and R.Val (value on release). The push can also send a Note (on/off), a PC number, start scripts, or navigate pages. So pushes send CC, Note or PC according to configuration, not a fixed message. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Incoming MIDI (E16-MAN section 2.15): MIDI In can be passed through to selected outputs (Thru per TRS/USB/BLE); an external MIDI clock is used by tempo-synchronized recording modes; Program Change (optionally with Bank Select) received on a configured "PC Receive Channel" changes scene or page. PC mode "scene" or "page". With Bank Select + PC: bank selects the scene, PC selects the page. PC 1-16 select scenes 1-16 directly. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
  - So a host can switch scene/page by Program Change on one dedicated channel (setting required on the E16).
- MIDI Learn (section 2.16): the E16 learns channel and CC from an incoming message and assigns it to the destination. This is a mapping aid; the manual text does not say that incoming CC then moves the knob value or ring. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Change log in the manual: 0.5.6b "MIDI Learn", "Send MIDI parameter data manually or when changing scenes or presets" (Auto Transmit, Send All). No "feedback" entry. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Lua scripting (E16-MAN chapter 6), a script is loaded per scene via the OXI App. Globals: `controller`, `page`, `midi`, `leds`, `slots`, `var`. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
  - Receive callback documented: `controller.onSysex(bytes)` only (raw bytes incl. F0/F7). No documented receive callback for incoming CC or notes.
  - `leds.update(index, value 0-16383, color 0-15)` takes over an encoder's ring; `leds.reset(index)` returns it. `slots.update(index, text)` overrides the 4-character label under an encoder. `page.setTitle`. `midi.sendCC(output, channel 0-15, cc, value)`, `midi.sendSysex(output, bytes)` (max 128 bytes per call).
  - Therefore host-driven ring/label feedback is possible only through a user-installed Lua script that listens for SysEx (the script defines its own SysEx format; the manual's example uses manufacturer byte 0x7D). Script memory is "limited".
- Clock: E16 has an internal clock (40-300 BPM) and uses external MIDI clock when present, for the looper only. It is not documented as a clock source for other devices. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- i2c: no i2c mentioned anywhere in the E16 manual text (grep of the whole manual: none). Hardware: USB-C (power + MIDI), TRS MIDI 1 in / 2 out (type A), Bluetooth LE 5.0. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- USB class: manual says it can be connected directly by USB-C to a PC/Mac DAW and "provides MIDI In and Out"; it also is the power input (5 V, 200 mA). Class compliance is not stated in words. https://drive.google.com/file/d/1yZn1i96nRkosn2o6eDlj5wzuErPQEe9N/view
- Forum (not maker): a poster says feedback "is supported but the target needs to broadcast its CC values over MIDI". https://www.elektronauts.com/t/oxi-instruments-e16-midi-controller/238039?page=17
- Forum (user quoting release notes, unconfirmed by maker page): FW 0.5.6 (04/02/2026) listed "Add: Midi learn", "Add: Midi feedback"; FW 0.5.7 (11/02/2026) added a push-action LED ring indicator and a 7-bit to 14-bit smart default. https://www.elektronauts.com/t/oxi-instruments-e16-midi-controller/238039?page=15 (also reported via search of page 17)
- FW 1.0 (July 2026) headline: a MIDI parameter looper. https://synthanatomy.com/2026/07/oxi-instruments-e16-a-multi-scene-performance-midi-controller.html
- Norns blockers: none found. Needs enough USB power (200 mA) from the host port. Port names as a host sees them: not verified.

## 2. OXI ONE (and OXI ONE MKII)

Note: ONE-38 is the 2023 guide for the first generation; MKII-DOC is FW 2.2.10. Where a question is answered only in ONE-38 it is marked (ONE-38) and may differ on the MKII.

- Eight sequencers (Mono, Poly, Chord, Multitrack, Stochastic, Matriceal; MKII FW 2.x adds Domino, Saga, MIDI Player). Each sequencer has a global MIDI channel and output (ALL, TRS, USB, BLE). ONE-38 https://www.allfordj.ru/upload/iblock/c0c/wzlkj8g80f29webhefwwn50h621b7ovf/rukovodstvo_polzovatelya_oxi_instruments_one_black_edition.pdf ; MKII-DOC https://docs.oxiinstruments.com/oxi-one-mkii-manual/sequencer-modes/
- Multitrack: 8 mono tracks per sequencer; each track has its own MIDI channel and output; by default the track channel equals the sequencer channel; several tracks can share a channel. MKII-DOC https://docs.oxiinstruments.com/oxi-one-mkii-manual/multitrack-mode/ ; ONE-38 (same file as above)
- Ports and channels: each port has 16 channels; ports A and B built in (OXI Split adds ports, "96 channels"); MKII-DOC https://docs.oxiinstruments.com/oxi-one-mkii-manual/connectivity/. ONE-38 says "32 channels available for the USB output in two separate virtual ports" (same ONE-38 file).
- Poly mode: up to 7 notes per step, 128 steps (ONE-38). Each Multitrack track is monophonic (MKII-DOC multitrack page). Chord notes can be spread across channels by "Channel Multiplex" (MKII-DOC lists the chapter at https://docs.oxiinstruments.com/oxi-one-mkii-manual/ ; chapter content not read).
- Modulation lanes (MKII-DOC): 8 lanes per sequencer, up to 128 steps, up to 2 MIDI + 2 internal destinations per lane; Multitrack has 1 lane per track. https://docs.oxiinstruments.com/oxi-one-mkii-manual/modulation/
  - MIDI destination types: CC (0-127), Pitch Bend (bipolar), Aftertouch, Program Change, Off. CC range 0-127 (7-bit). NRPN is not a destination type; the page says "CC is supported but NRPN is not". https://docs.oxiinstruments.com/oxi-one-mkii-manual/modulation/
  - ONE-38 lists LFO external destinations as CC, Program Change, Aftertouch and Pitch Bend (ONE-38 file).
- Clock and transport: MIDI clock is read and output at 24 ppqn. Sync sources INT, USB, MIDI, CLK, BLE. "MIDI Transport Msgs Send" (ONE-38 config) sends Clock, Start, Stop and Continue through TRS, USB and Bluetooth. MKII-DOC https://docs.oxiinstruments.com/oxi-one-mkii-manual/connectivity/ ; ONE-38 (file above)
  - Auto Sync ON: when stopped, the unit starts on an incoming MIDI Start; OFF: ignores incoming Start. A MIDI Stop, or loss of the external source, makes it fall back to internal sync. MKII-DOC connectivity page.
  - "Start Stop Msgs Ignore" config exists (ONE-38).
  - Transport CC (ONE-38): Stop CC 105, Play CC 106, Rec CC 107, on port A, channel set in Config > MIDI "CC Transport Msgs Channel" (Off or 1-16); used when OXI One is not the clock master. ONE-38 file.
- Program change: each arranger slot sends a PC (setting "=" uses the pattern's PC value, Off, or 1-128), sent 2 clock ticks before the pattern transition; each pattern also has PC and bank-select values (settings pages 1 and 2); bank select is sent as MIDI bank change (CC0 MSB / CC32 LSB mentioned, mapping of the 1-128 value not explained). https://docs.oxiinstruments.com/oxi-one-mkii-manual/arranger/
  - Per-sequencer "PROGRAM CHANGE" sends a PC on the selected channel/output on pattern change (per track in Multitrack). ONE-38 file.
- Incoming program change: selects arranger columns (PC 1 = first column); receive channel set in Config > MIDI > "PC receive global channel". https://docs.oxiinstruments.com/oxi-one-mkii-manual/arranger/
- Incoming notes: with "MIDI In channel filtering" ON, each sequencer (or Multitrack track) listens to notes only on its own channel for recording, MIDI-to-CV, scale filtering, chord triggering and arpeggiation; OFF: only the selected sequencer listens, on all channels. If all tracks of a Multitrack share one channel, messages go to track 1 only (ONE-38). Option "Ch & Note (MULTI)" also exists. ONE-38 file (section near "MIDI In channel filtering").
- Thru: per-port (TRS, USB, BLE) thru toggles in Config > MIDI. MKII-DOC connectivity page.
- USB role: Config > System > USB Mode = Device ("a USB MIDI Device"), Host + Power, or Host No Power. In Device mode a host (computer, norns) drives it; in host modes it hosts other class-compliant devices. https://docs.oxiinstruments.com/oxi-one-mkii-manual/connectivity/ ; ONE-38 lists tested USB hosted devices including Launch Control XL, Launchpad Pro Mk3, KeyStep, nanoKONTROL2 (ONE-38 file).
- Bluetooth MIDI and a 3-message MIDI monitor exist. MKII-DOC connectivity page.
- MPE: no mention in MKII-DOC pages read, in ONE-38 (grep of the whole text), or in firmware coverage found. Treat as not supported until shown otherwise; see Not verified. https://docs.oxiinstruments.com/oxi-one-mkii-manual/connectivity/
- Norns blockers: for norns to send to it, the unit must be in USB Device mode (default state not verified). Class compliance and port names are not stated in the manuals. Power: in Device mode it takes power from the USB host.

## 3. 16n Faderbank and 16nx

- 16 faders (60 mm). Original 16n: Teensy-based, firmware 2.1.0, hardware 1.34. https://github.com/16n-faderbank/16n
- Default: CC 32-47, MIDI channel 1, on both USB and TRS. https://github.com/16n-faderbank/16n/wiki/User-Guide ; https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md
- Configuration: web editor (WebMIDI, Chrome) at https://16n-faderbank.github.io/editor over USB, using SysEx; per-fader channel and CC, separately for USB and TRS. https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md ; https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/SYSEX_SPEC.md
- 14-bit: the firmware supports a high-resolution mode per output (USB and TRS configured separately); condition in source: `usbCCs[q] < 96` and the per-fader flag set; the LSB is sent as CC + 32 (16nx source shows MSB on CC n and LSB on CC n+32). Default is 7-bit. So "7-bit only" is wrong. https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/16n_faderbank_firmware.ino ; https://github.com/16n-faderbank/16next_firmware/blob/main/main.cpp ; EEPROM map in https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md (addresses 80-85 "booleans for high-res mode")
- Faders are absolute; no relative mode in the firmware or README. https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md
- Incoming MIDI: only configuration SysEx (header F0 7D 00 00 in the 16nx source, 16n sysex spec) is acted on; optional "Soft MIDI thru" (EEPROM address 8, default 0) forwards USB input to TRS. No LEDs or motors per fader. Options exist for a power LED and "LED blink on MIDI data" (a single activity LED). https://github.com/16n-faderbank/16next_firmware/blob/main/main.cpp ; https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md
  - The 16n receives clock/other messages through handlers `midiClock` etc. in `midiClock.ino` (purpose: LED blink); no output effect found.
- i2c: follower by default (set up for monome Teletype); "I2C Master / Leader" is selectable in the editor (applied at next boot) to drive Ansible, TXo, ER-301. https://github.com/16n-faderbank/16n/wiki/User-Guide ; https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md (address 3 "I2C Master/Follower")
- 16nx (second generation, RP2040, USB-C): "compatible with the 16n editor", software "backwards compatible", same USB/TRS/i2c roles. https://16n-faderbank.github.io/16nx
  - USB device name: the 16nx firmware descriptor has manufacturer "Oxion", product "16nx". https://github.com/16n-faderbank/16next_firmware/blob/main/usb_descriptors.c
  - USB MIDI is class-compliant (TinyUSB MIDI device, sources above).
- Original 16n USB name: firmware README requires Teensyduino "USB type: MIDI"; that is the Teensy MIDI device; the exact product string shown to a host is not stated in repo text read. https://github.com/16n-faderbank/16n/blob/main/firmware/16n_faderbank_firmware/README.md
- Norns blockers: none found. A norns script reading it only receives CC.

## 4. ATOV Faderpunk

- 16 channels, each with a fader, a button, an RGB LED and a configurable CV jack. RP2350B, firmware in Rust (Embassy), open source. https://github.com/ATOVproject/faderpunk
- Inputs/outputs from retailer/reviews: USB-C (power + MIDI), 3.5 mm TRS MIDI in and two MIDI outs, an i2c socket. https://www.soundonsound.com/reviews/atov-faderpunk ; https://synthanatomy.com/2025/09/atov-faderpunk-a-hackable-midi-cv-and-modulation-hub.html
- Apps: each of the 16 channels runs apps (up to 16 at once; an app can use more than one channel); apps are loaded and configured from a browser configurator. https://github.com/ATOVproject/faderpunk ; https://github.com/ATOVproject/faderpunk/blob/main/faderpunk/src/apps/control.rs
- "Control" app (source): per-fader MIDI channel, MIDI CC, MIDI out selection, optional NRPN switch (`nrpn: bool`), per-fader button with modes Mute / CC toggle / CC momentary / Program Change / invert toggle / invert momentary, button channel and CC/PC number. Source defaults: fader CC = 32 + channel index, button CC = 48 + channel index. Each fader outputs absolute values. https://github.com/ATOVproject/faderpunk/blob/main/faderpunk/src/apps/control.rs
  - Whether the non-NRPN path sends 7-bit CC or 14-bit CC pairs: not verified.
- Other MIDI apps in the source tree: `cv2midi`, `cv2midinote`, `midi2cv`, `notefader`, `seq8`, `lfo`, `euclid`, etc. https://github.com/ATOVproject/faderpunk/tree/main/faderpunk/src/apps
- Incoming MIDI: the README says input events including MIDI are broadcast to all apps; `midi2cv` consumes MIDI. Whether any app moves a fader LED or value from incoming CC (feedback): not verified. https://github.com/ATOVproject/faderpunk
  - The LEDs are driven by the app (the Control app sets LED brightness from its own output value, per its source). https://github.com/ATOVproject/faderpunk/blob/main/faderpunk/src/apps/control.rs
- USB: composite-free class-compliant USB-MIDI 1.0. Configuration moved to MIDI SysEx on a second virtual cable, so it is "a pure class-compliant USB-MIDI device" (issue closed 2026-07). Two cables: "Faderpunk" and "Faderpunk Config". USB vendor "ATOV", product "Faderpunk", VID 0xF569, PID 0x0001. https://github.com/ATOVproject/faderpunk/blob/main/docs/usb-host-compatibility.md ; https://github.com/ATOVproject/faderpunk/blob/main/faderpunk/src/tasks/transport.rs ; https://github.com/ATOVproject/faderpunk/blob/main/faderpunk/src/usb_midi.rs
  - A hardware USB host (CME H4MIDI) failed to bind the older composite (MIDI+WebUSB) firmware; the later firmware is MIDI-only and was confirmed with that host. https://github.com/ATOVproject/faderpunk/blob/main/docs/usb-host-compatibility.md
- i2c: leader by default (400 kHz); probes the bus once, 10 s after start, then talks to recognized followers only: 0x20 Ansible, 0x31 ER-301-compatible controller messages (usable by a disting NT whose follower address is set to 0x31), 0x60-0x67 TXo. Changing the mode needs a reboot. Only the Control and Panner apps publish i2c output. It can also be follower: "normal follower mode at address 0x56 is currently unimplemented". https://github.com/ATOVproject/faderpunk/blob/main/docs/i2c.md ; README says it is also compatible with the 16n faderbank protocol https://github.com/ATOVproject/faderpunk
- Firmware: stable 1.9 and 1.10 mentioned (new apps, Buchla 1.2 V/oct), August 2026. https://www.gearnews.com/atov-faderpunk-synth/ ; https://synthanatomy.com/2026/08/atov-faderpunk-a-hackable-midi-cv-and-modulation-hub.html
- Norns blockers: none found for current firmware. Old composite firmware could fail on some hardware hosts; norns' kernel host is not that stack (norns acceptance not verified on hardware).

## 5. Launchpads and others through midigrid

Repository: https://github.com/jaggednz/midigrid (README is only a pointer to the llllllll.co threads https://llllllll.co/t/midigrid-use-launchpads-and-other-midi-grid-controllers-with-norns/42336 and https://llllllll.co/t/norns-alternative-grids/26909 ). Facts below are from the library source on the default branch `master`.

- Maintenance: last commit on `master` 2026-10-19 (merge of a PR "Fix/gen3 leds and garbage"); an earlier commit 2026-10-18 "Launchpad gen3: lights while placing, no memory build-up, live rotation". Repo updated 2026-11-03. https://github.com/jaggednz/midigrid/commits/master
- Two ways to use it:
  1. The include line in the script: `include "midigrid/lib/mg_128"` (that file is `local grid = include "midigrid/lib/midigrid"; grid:init('128'); return grid`; `mg_256.lua` is the same with '256' and says "completely UNTESTED"; there is no `mg_64.lua`, a '64' layout is `grid:init('64')` or the default when `connect` is called without `init`). https://github.com/jaggednz/midigrid/blob/master/lib/mg_128.lua ; https://github.com/jaggednz/midigrid/blob/master/lib/mg_256.lua ; https://github.com/jaggednz/midigrid/blob/master/lib/midigrid.lua
  2. As a norns mod (`lib/mod.lua`): SYSTEM > MODS > MIDIGRID. The mod replaces the global `grid.connect` so an unmodified script that calls `grid.connect()` gets midigrid when active; size 64 / 128 / 256 (default 128), per-device rotation, palette, "place devices". No script change needed in that case. https://github.com/jaggednz/midigrid/blob/master/lib/mod.lua
  - The `util.file_exists(_path.code.."midigrid") and include "midigrid/lib/mg_128" or grid` line quoted in the question is not in this repository's README or in `mg_128.lua`; whether it appears in the forum thread was not checked (the line itself is valid with `mg_128`'s return value).
- Sizes: 64 = one 8x8 quad. 128 = two 8x8 quads side by side (width 16, height 8), 256 = four quads (16x16). `midigrid.cols`/`rows` equal the vgrid width and height. https://github.com/jaggednz/midigrid/blob/master/lib/vgrid.lua ; https://github.com/jaggednz/midigrid/blob/master/lib/midigrid.lua
  - A 128 layout with one device: the single device shows one quad at a time and the top-row (aux row) buttons 1..N select the quad (`create_quad_handers`; aux handlers for `row` buttons 1-4 call `change_quad`); with two devices each device is assigned one quad (name order, or remembered places). `update_quad_btn_aux` lights those buttons (15 for the current quad, 2 for others). `quad_switching_enabled` defaults to true. These aux buttons are consumed by the library; they do not reach the script's `key`. https://github.com/jaggednz/midigrid/blob/master/lib/devices/generic_device.lua ; vgrid.lua above
  - For a 128 on one 8x8 device, the script's cells in the off-screen quad are buffered but not visible until the quad is switched.
- Devices matched by MIDI port name (`supported_devices.lua`): APC mini, APC mini mk2, Livid Block; Launchpad gen 1 ("launchpad", "launchpad s", "launchpad mini" and "launchpad mini N"); "launchpad mk2" (RGB); Launchpad Mini MK3 (interface 2), Launchpad Pro MK3 (interface 1), Launchpad X (interface 2, "launchpad open 2"); Push 2; Push 3; LinnStrument; Synthstrom Deluge; Midiplus SmartPad. Also device files for `launchpad_gen3`. Launchkey and Tenori-on: `tenori-on.lua` exists in `lib/devices` but is not in the name table; no Launchkey file. https://github.com/jaggednz/midigrid/blob/master/lib/supported_devices.lua ; tree https://github.com/jaggednz/midigrid/tree/master/lib/devices
- Brightness: `grid:led(x, y, z)` accepts z 0-15 and indexes a 16-entry `brightness_map` per device (default map 0..15 straight through). So varibright calls work on all devices, but what you see depends on the map: Launchpad gen 1 uses 16 entries that map to about 8 distinct red/green/orange colors; APC mini map is `{0,1,1,1,1,1,1,1,3,3,3,3,5,5,5,5}` (3 distinct non-off states); RGB devices (launchpad mk2/Mini mk3/X/Pro/Push) use a 16-entry color table (`rgb_lut`) with selectable palettes. https://github.com/jaggednz/midigrid/blob/master/lib/devices/generic_device.lua ; launchpad.lua ; apc_mini.lua ; launchpad_rgb.lua ; launchpad_gen3.lua (same folder)
- `midigrid.intensity()` and `rotation()` are stubs (`--TODO unimplemented`). https://github.com/jaggednz/midigrid/blob/master/lib/midigrid.lua
- Connect behavior: `connect()` returns the midigrid object (a table with `key`, `led`, `all`, `refresh`, `cols`, `rows`, `device`, `vports`, `name = 'Midi Grid'`); `midigrid.device` is set to `{id = 999, cols, rows, name = "midigrid", serial = 1234567}` when a supported device is found. If no supported MIDI grid is found it returns `core_grid.connect()` (the real monome grid object). https://github.com/jaggednz/midigrid/blob/master/lib/midigrid.lua
- `grid.add` / `grid.remove`: midigrid does not call them. It wraps `midi.add` and `midi.remove` only (to clean up on unplug). Plugging in a Launchpad after the script loaded does not call the script's `grid.add`; devices are found only at `connect()` time. https://github.com/jaggednz/midigrid/blob/master/lib/midigrid.lua ; the mod comment lists `Grid.add`/`Grid.remove` as left to the real grid https://github.com/jaggednz/midigrid/blob/master/lib/mod.lua
- Script changes beyond the include line: a script that sets `g.key = function(x,y,z)` works (the library calls `midigrid.key`). Layout-sensitive scripts must read `g.cols` and `g.rows` after connect. A script that hard-codes the monome grid detection by `grid.cols`/`grid.rows` before connecting sees the real grid's values.
- Midigrid takes over the Launchpad as a MIDI device; it also patches `midi.devices[id].event`, so the same device cannot be used as a separate MIDI controller by the script at the same time.

## 6. Expert Sleepers disting NT

- USB: type C socket; "a High Speed USB 2.0 device. It is not a USB host." The NT is "a MIDI Class, Audio 2.0 Class, and Video Class compliant device"; no drivers needed on macOS, iOS and Linux. So norns (host) can send to it. NT-MAN https://expert-sleepers.co.uk/downloads/manuals/disting_NT_user_manual_1.17.pdf
- MIDI also over a 4-pin breakout header and the Select Bus (used as a plain MIDI connection; the Select Bus preset protocol is not implemented). NT-MAN (same URL)
- Polyphony: "polysynths" share common features; they respond to MIDI notes (min/max note, velocity/pressure curves) and support MPE: per-note pitch bend, aftertouch and the Y dimension (CC 74). MPE channels set by "MIDI channel" (the common/master channel) and "MPE channels" (note channel count; common channel 1 gives note channels 2 upward; common channel 16 gives 15 downward). Each algorithm has its own MPE parameter (1-16). NT-MAN (same URL); firmware note "polysynths in MPE mode can now play the same note several times at once" https://expert-sleepers.co.uk/distingNTfirmwareupdates.html
- CC mapping: MIDI mappings set algorithm parameters directly (not added). Types: CC, Note-momentary, Note-toggle, 14-bit CC low-first, 14-bit CC high-first, Pitch bend, Channel pressure. Per mapping: parameter, channel, CC/note 0-127, enabled, symmetric, Relative CC (yes/no), min, max, view change. "Learn" mode on the right encoder. Soft takeover (Sudden, Gradual, Always on) does not apply to relative mappings. NT-MAN (same URL)
- Relative CC encoding: the manual says only "an up/down relative movement" and does not specify the value encoding. NT-MAN (same URL, the "Relative CC?" row)
- MIDI out: the setting "Send CCs if changed by MIDI map" sends CCs when a mapped parameter changes (to avoid loops with a controller that echoes). NT-MAN (same URL)
- Program change: when enabled, a PC loads a preset: first a preset whose filename contains "#<program number>", otherwise the alphabetically sorted file list indexed by program number. Settings: PC channel, "uses Bank" (Bank Select CC 0), "shows message". NT-MAN (same URL)
- SysEx device ID setting; MIDI forwarding between USB, breakout and Select Bus. NT-MAN (same URL)
- i2c: header J8 (SDA, SCL, ground). "In general the disting NT acts as a follower on the I2C bus, not as a leader." Address set in Settings. Messages `<address> <command> ...`: 0x11 set i2c controller X (14-bit value MSB LSB); 0x46/0x47 set parameter; 0x48-0x4A get; note messages 0x54-0x57 and 0x68-0x6B (note on/off, pitch, with channel); 0x4F/0x50 send MIDI from breakout/Select Bus; 0x81-0x83 send raw MIDI bytes to the NT "as if the I2C connection were just another MIDI cable". Values 16384 = 10 V. NT-MAN section "I2C reference" (same URL)
  - "Much of this I2C protocol is based on that developed for the disting EX." Compatibility is therefore partial by design: the NT adds a "current algorithm" concept (parameter 255) the EX did not need. NT-MAN section "I2C reference" (same URL)
  - Firmware 1.14.0 added i2c messages for an arbitrary MIDI stream including SysEx; 1.18.0 added i2c MIDI out. https://expert-sleepers.co.uk/distingNTfirmwareupdates.html
  - Faderpunk can drive an NT's i2c controllers via the ER-301-compatible 0x11 message (follower address 0x31). https://github.com/ATOVproject/faderpunk/blob/main/docs/i2c.md
- Norns blockers: none found (USB device, class compliant). The NT's USB MIDI port name as listed on Linux: not verified.

---

## Not verified

1. E16: whether incoming CC (same CC and channel) moves an encoder's value or LED ring ("MIDI feedback"). Only a forum quote of release notes says FW 0.5.6 added "Midi feedback"; E16-MAN 1.0.1a documents MIDI Learn and no feedback.
2. E16: exact 14-bit CC pairing (MSB CC n, LSB CC n+32) and exact NRPN message format.
3. E16: USB device name and the three virtual port names as seen by a Linux host.
4. E16: whether it sends MIDI clock (it follows an external clock for its looper only).
5. E16: any i2c (none documented).
6. E16: whether the scene count is 7 or 16 on current firmware (quick start vs manual conflict; manual 1.0.1a says 16).
7. E16: whether the OXI App edits per-control labels beyond 4 characters, and whether labels or ring values can be written by a host without a custom Lua script (nothing found).
8. OXI ONE / MKII: MPE support (nothing found), Song Position Pointer send/receive, and MIDI Continue receive; ONE-38 lists Continue only as sent with transport messages.
9. OXI ONE / MKII: USB class compliance wording and the port names as seen on Linux; default USB Mode after power-up.
10. OXI ONE MKII: whether MKII differs from ONE-38 in MIDI-in channel filtering and Poly-mode output (MKII-DOC "Poly Mode" and "Channel Multiplex" pages not read).
11. 16n (original): the exact USB product string a host sees (16nx is "16nx" by manufacturer "Oxion").
12. 16n/16nx: which CCs 16nx uses by default (README says "different CC per fader"; the original 16n default is 32-47 ch 1).
13. Faderpunk: whether MIDI CC output is 14-bit when NRPN is off; per-app default MIDI channel; any incoming-MIDI-to-LED/fader feedback in any app; i2c follower role behavior (unimplemented).
14. Faderpunk: official manual (not found; the faderpunk.cv/apps page and ATOV site were not reachable by the tools used).
15. midigrid: the exact "util.file_exists ... include 'midigrid/lib/mg_128' or grid" idiom in the forum thread; any known breakage against the current norns release (repo activity shows fixes through 2026-10-19 but no statement).
16. midigrid: Launchkey support (no device file), exact count of visually distinct brightness steps on real Launchpad hardware beyond the maps in the source.
17. disting NT: the value encoding of Relative CC; the USB MIDI port names; whether the NT sends MIDI notes or CC out over USB for any algorithm other than the "Send CCs" feature.

## Surprises

- The 16n firmware does support 14-bit CC (per-output option, LSB on CC+32); it is off by default.
- OXI E16 manual 1.0.1a documents MIDI Learn and no host feedback; "feedback" appears only in a forum quote. Ring and label updates from a host need a Lua script on the E16 (SysEx in only; `controller.onSysex`).
- The E16 pushes are configurable (CC with press/release/toggle values, Note, PC, scripts, page navigation), not a fixed message; scenes can be changed by incoming Program Change (with optional Bank Select).
- OXI E16 relative encodings: Rel1 (1 / 127) and Rel2 (63 / 65) per destination. No two's-complement or 64-centered (offset binary) option is listed.
- midigrid's "128" is two 8x8 quads (width 16 by height 8), not paging by default; with one device the library's own top-row buttons switch quads and are not given to the script. midigrid never calls `grid.add` or `grid.remove`.
- The disting NT is a USB device only (not a host) and its MPE support is on polysynth algorithms; its i2c is follower-only and the messages are the disting EX's plus extra.
- Faderpunk is i2c leader by default, with i2c output only from two apps; its USB descriptor is MIDI-only and it exposes two cables ("Faderpunk", "Faderpunk Config").
- OXI ONE MKII docs list NRPN as unsupported for modulation lanes, and lane CC output is 7-bit.
- The OXI ONE guide v3.8 is for the first generation; MKII and ONE FW differ, and the MKII FW 2.2.10 manual lacks the "Transport CC" and "MIDI Transport Msgs Send" text that ONE-38 has.
