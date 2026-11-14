# crow, ii and Teletype: verified facts for 3.6

Local sources (read-only checkouts):
- norns `~/src/norns` at `227aa044` (2026-10-04).
- crow firmware `~/src/crow` at `b340579` (`v4.0.5-4`, 2026-04-18). The latest crow release is still v4.0.5 (2023-07-25, `gh release list -R monome/crow`).
- Teletype `~/src/teletype` at `e390bac` (`v5.0.0-6`). Its `libavr32` submodule is not checked out, so I read it through the GitHub API at the pinned commit `b37dc3f`.
- monome docs `~/src/docs` at `3e61d07` (source of monome.org/docs).

Paths below are relative to those roots: `norns:`, `crow:`, `tt:`, `docs:`.

## 1. crow from a norns script

### The norns `crow` table
- A norns script does not call a fixed crow API. `crow` is a proxy: indexing builds a key chain, calling it sends `<chain>(<quoted args>)` as Lua text, and assigning sends `<chain>=<quoted value>`. crow then runs that text. Source: norns:lua/core/crow.lua:198-235.
- Querying values directly is not supported. The source says: "does *not* support directly querying values or function responses from crow". Values come back only through callbacks. Source: norns:lua/core/crow.lua:195-197.
- Assigning a function (for example `crow.input[1].stream = fn`) does three things. It registers `fn` on norns under a one-letter key, it sends crow a stub `function(...)_c.tell('<key>',quote(...))end`, and crow's later `^^<key>(...)` line calls `fn`. Source: norns:lua/core/crow.lua:205-216.
- There are at most 52 event keys (A-Z, a-z), and the 7 static events take the first 7 (norns:lua/core/crow.lua:123-131). That leaves 45 function assignments per script session. Keys are never reused until `norns.crow.init()` runs at script clear (norns:lua/core/script.lua:101). Each reassignment uses a new key, including the re-assignments needed after a crow reconnect. Past 52 the code prints "ERROR: can't register event" and stores the function under the key `""`. Source: norns:lua/core/crow.lua:110-119.
- Raw code: `crow("output[1].volts = 3")` and `crow.send(...)` (a legacy alias) send a literal string. Source: norns:lua/core/crow.lua:186, 231-233. Multi-line strings work; the core clock helper sends one. Source: norns:lua/core/crow.lua:161-169.
- Fixed helpers:
  - `crow.version()`, `crow.identity()`, `crow.reset()` (runs `crow.reset()` on crow), `crow.kill()` (`^^k`) and `crow.clear()` (`^^c`). Source: norns:lua/core/crow.lua:181-185.
  - `norns.crow.connected()` returns `norns.crow.dev ~= nil`. Source: norns:lua/core/crow.lua:64-66.
- When crow is absent, every send is a silent no-op: `norns.crow.send` does nothing when `norns.crow.dev` is nil. Source: norns:lua/core/crow.lua:58-62. Function assignments still use up norns event keys.
- Add, remove and receive callbacks: assign `norns.crow.add(id, name, dev)`, `norns.crow.remove(id)` and `norns.crow.receive(line)`.
  - `receive` gets every line from crow that does not contain `^^`, such as print output.
  - The default `add` runs `crow.reset()` on every (re)connect. A script that replaces `add` also replaces that reset.
  - `norns.crow.init()` restores all three defaults at script clear.
  - Source: norns:lua/core/crow.lua:9-24, 140-157.
- The comment lines `crow.add -> norns.crow.add` are not aliases. `crow.<anything> = fn` goes through `crow.__newindex`, which sends `<name>=<quote(fn)>` to crow. Scripts must assign `norns.crow.add` and the others directly. Source: norns:lua/core/crow.lua:187-191, 226.
- Only one crow is supported. norns keeps a single `norns.crow.dev`, so a second crow replaces the first. Sources: norns:lua/core/crow.lua:10; docs:crow/norns.md:22-23 ("Presently, only a single crow is supported", https://monome.org/docs/crow/norns/).
- Every script load runs `crow.reset()`, through `norns.crow.init()` at script clear. On crow, `crow.reset()` does the following:
  - sets inputs to `none` and zeroes the outputs and their slews;
  - cancels output clocks;
  - restores the `ii.self` follower handlers and frees all metros.
  - Sources: norns:lua/core/crow.lua:140-142; crow:lib/l_crowlib.c:225-273 (`ii.reset_events(ii.self)`, `ii_follow_reset()`, `metro.free_all()`).

### Inputs
- crow has 2 CV inputs. The modes are `'none'`, `'stream'`, `'change'`, `'window'`, `'scale'`, `'volume'`, `'peak'`, `'freq'` (input 1 only) and `'clock'`. Source: docs:crow/reference.md:24-107 (https://monome.org/docs/crow/reference/).
- Signatures, from norns as `crow.input[n].mode(...)`:
  - `mode('stream', time)`
  - `mode('change', threshold, hysteresis, direction)`, with direction `'rising'`, `'falling'` or `'both'`
  - `mode('window', windows, hysteresis)`
  - `mode('scale', notes, temperament, scaling)`
  - `mode('volume', time)`
  - `mode('peak', threshold, hysteresis)`
  - `mode('freq', time)`
  - `mode('clock', division)`
  - Defaults: `time=0.1`, `threshold=1.0`, `hysteresis=0.1`, `direction='both'`, `div=1/4`.
  - Source: docs:crow/reference.md:51-121.
- Callbacks are `crow.input[n].stream = fn(volts)` and `crow.input[n].change = fn(state)` (state is 1 rising, 0 falling). `crow.input[n].query()` calls the stream callback once. Source: docs:crow/norns.md:59-123, 274-286.
- The stream interval is quantized to 32-sample blocks at 48 kHz: `blocks = (48000*interval)/32`, minimum 1 block (about 0.67 ms). Source: crow:lib/detect.c:91-92; crow:ll/adda.h:5 (`ADDA_BLOCK_SIZE 32`). The FAQ gives the inputs a "1.5 kHz sample rate" (48000/32). Source: docs:crow/faq.md (comparison table; https://monome.org/docs/crow/faq/).
- An input `change` event with no handler assigned reaches norns as `^^change(...)`, which norns ignores (`change = function() end`). Source: norns:lua/core/crow.lua:130.
- Throughput across USB: I found no measured figure. Two facts bound it:
  - matron opens the port at `B115200` (USB CDC) and reads at most 255 bytes per loop, with a 1 ms `usleep`. Source: norns:matron/src/device/device_crow.h:14; device_crow.cc:95-106.
  - Every `^^` line is `load()`ed as Lua on norns. Source: norns:lua/core/crow.lua:27-47.

### Outputs
- crow has 4 CV outputs, from -5 to +10 V. Source: docs:crow/norns.md:44-48.
- `crow.output[n].volts = v`, `.slew = seconds` and `.shape = 'linear'|'sine'|'logarithmic'|'exponential'|'now'|'wait'|'over'|'under'|'rebound'`. Source: docs:crow/reference.md:151-192.
- `crow.output[n].scale({notes}, temperament, scaling)` quantizes after slew and actions, and `.scale('none')` turns it off. Source: docs:crow/reference.md:194-214.
- `action` from norns is a string, which crow `load`s. Source: crow:lua/output.lua:48-51. Examples:
  - `crow.output[1].action = "lfo(1,5)"`
  - `"{ to(0,0), to(5,0.1), to(1,2) }"`
  - `"loop{...}"`, `"times(n,{...})"`
  - Start it with `crow.output[1]()`. Source: docs:crow/norns.md:154-205.
- The asllib actions:
  - `lfo(time, level, shape)` (defaults 1, 5, `'sine'`)
  - `pulse(time, level, polarity)` (0.01, 5, 1)
  - `ramp(time, skew, level)`
  - `ar(attack, release, level, shape)` (0.05, 0.5, 7, `'log'`)
  - `adsr(attack, decay, sustain, release, shape)` (0.05, 0.3, 2, 2, `'linear'`)
  - `oscillate(freq, level, shape)`
  - `adsr` holds at sustain on `output[n](true)` and releases on `output[n](false)`.
  - Source: docs:crow/reference.md:233-303.
- `crow.output[n].done = fn` runs when an action completes. `crow.output[n].receive = fn(v)` together with `crow.output[n].query()` reads an output's current value. Source: docs:crow/reference.md:305-312; docs:crow/norns.md:207-223.
- Output clock on crow: `output[n]:clock(division)` (default division 1, the same units as `clock.sync`), `output[n]:clock('none')` and `output[n].clock_div = x`. The default action is `pulse()`. Source: docs:crow/reference.md:216-231; crow:lua/output.lua:29-43.
- From norns, the clock method needs a raw string, for example `crow("output[1]:clock(1/4)")`. This is inferred from the code, not tested. Both `crow.output[1]:clock(1/4)` and `crow.output[1].clock(1/4)` look broken through the proxy:
  - The colon form quotes the proxy table as the first argument.
  - The dot form passes the division as `self`.
  - Sources: norns:lua/core/crow.lua:198-223; crow:lua/output.lua:29-36.
- crow's own clock is separate from norns' clock. It runs from its internal tempo (`clock.tempo = bpm`) or from an input in `'clock'` mode, with `clock.start()`, `clock.stop()` and `clock.transport.start`/`stop`. Sources: docs:crow/reference.md:593-631; crow:lua/clock.lua:91-116. No source describes syncing it to norns' clock over USB.

### How norns' clock relates to crow
- Clock source "crow" (PARAMETERS > CLOCK > source) does the following:
  - It sends crow `input[1].change = function() tell('change',1,1) end` and `input[1].mode('change',2,0.1,'rising')`. Source: norns:lua/core/clock.lua:215-223; norns:lua/core/crow.lua:161-169.
  - matron advances the beat whenever a received line contains `^^change(1,1)`. Source: norns:matron/src/device/device_crow.cc:84-86.
  - The tempo is a 4-pulse moving average. `crow in div` (1-32, default 4) sets pulses per beat. A gap of more than 4 beats counts as a stop. Source: norns:matron/src/clocks/clock_crow.cc:11-77; norns:lua/core/clock.lua:314-321.
  - A script must leave crow input 1 alone while the clock source is crow.
- "crow out" (off / output 1-4, default off, with `crow out div` 1-32 default 4) runs a norns coroutine forever. Each pulse is `clock.sync(1/div)`, then `crow.output[k].volts = 10`, a sleep of half a division, then `volts = 0`: two USB sends per pulse. A script driving the same output would conflict with it. Sources: norns:lua/core/clock.lua:301-338; norns:lua/core/state.lua:55-57.
- A script that clocks an output itself has two options:
  - set `crow.output[n].action = "pulse(0.01,5)"` and call `crow.output[n]()` from a norns `clock.sync` loop, which costs one USB send per pulse;
  - run crow's own `output[n]:clock(div)`, which runs on crow's tempo, not norns'.
  - Sources: as above.
- After script clear with the clock source set to crow, `script.lua` sets `crow.input[1].change = function() end` through the proxy. Source: norns:lua/core/script.lua:123-127. That registers a lettered event, so crow would then send `^^H(..)`, not `^^change(1,1)`, and matron's clock match would fail. This is a code reading only (see Not verified).

## 2. ii through crow from norns

### Calling and reading back
- Commands are `crow.ii.<device>.<command>(args...)`, which crow receives as `ii["<device>"]["<command>"](args)`. Examples: `crow.ii.jf.mode(1)` and `crow.ii.jf.play_note(3)`. Source: docs:crow/norns.md:127-143.
- Getters are `crow.ii.<device>.get('<name>' [, args])`, with the reply on `crow.ii.<device>.event = function(e, value) end`.
  - `e` is `{name, device, arg}` (getter name, device index starting at 1, first argument). Sources: docs:crow/reference.md:798-837; crow:lua/ii.lua:54-62.
  - `get` returns nothing; the reply arrives later as an event.
  - Through norns, the event comes back as the forwarded `(e, value)` pair (proxy mechanism above).
- A second device of the same type is addressed as `ii.<device>[n].cmd(...)`, from norns `crow.ii.jf[2].play_note(...)`. Sources: crow:lua/ii.lua:12-16; docs:crow/reference.md:839-855.
- `ii.raw(addr, bytes [, rx_len])` and `ii.event_raw = fn(addr, cmd, data)` reach devices crow has no descriptor for. Source: docs:crow/reference.md:857-877.
- Value types:
  - `s16V` sends volts × 1638.3, so 10 V = 16383 and the range is about ±20 V.
  - `s16ms` sends seconds × 1000.
  - `s8` is clamped to -128..127, `u8` to 0..255.
  - Source: crow:lib/ii.c:23, 433-475.
- Bus speed: `ii.fastmode(true)` switches from the default "stable" timing (97-148 kHz) to 165-350 kHz, about 4×. Sources: crow:ll/i2c.h:14-19; docs:crow/reference.md:896-903.
- crow's leader queue holds 16 messages. A full queue prints "queue full" and drops the new message. Source: crow:lib/ii.c:22, 138-140.
- Before leading, crow checks that the bus is not BUSY. A failed send is retried once on the next pass and then abandoned. Sources: crow:lib/ii.c:174-217; crow:ll/i2c.c:253-310.
- Pull-ups: `crow.ii.pullup(true|false)`. They are on by default and "should probably stay on". Sources: docs:crow/reference.md:905-909; crow:lib/ii.c:99-102 (hardware 3k3 on crow v1.1 plus the microcontroller's internal pull-ups).

### Devices crow's firmware knows
The descriptors are the files in crow:lua/ii/.
- `ansible` (0x20-0x23), `crow` (0x01-0x04), `disting` (EX, 0x41-0x44), `er301` (0x31-0x33), `faders` (16n, 0x34-0x37), `jf` (0x70, 0x75), `kria` (0x28), `levels` (0x2C), `meadowphysics` (0x2A), `txi` (0x68-0x6F), `txo` (0x60-0x67), `wdel` (0x78-0x79), `wsyn` (0x76-0x77) and `wtape` (0x71-0x72).
- No descriptor exists for Teletype, the Disting NT, Faderpunk or i2c2midi. A request to add i2c2midi is open as crow issue #490.

### Just Friends (`jf`; crow:lua/ii/jf.lua)
- Commands:
  - `trigger(channel, state)`
  - `run_mode(mode)`
  - `run(volts)`
  - `transpose(pitch_volts)`
  - `vtrigger(channel, level_volts)`
  - `mode(mode)` (non-zero enters Synthesis or Geode)
  - `tick(clock_or_bpm)`, argument type s8
  - `play_voice(channel, pitch_or_divs, level_or_repeats)`
  - `play_note(pitch_or_divs, level_or_repeats)`
  - `god_mode(state)`
  - `retune(channel, num, denom)`
  - `quantize(divisions)`
  - `pitch(channel, pitch)`
  - `address(index)`
- Getters: `speed`, `tsc`, `ramp`, `curve`, `fm`, `time`, `intone`. Source: crow:lua/ii/jf.lua:6-138.
- Synthesis mode has 6 voices. Pitch is 1 V/oct with 0 V = C3. Level is in volts ("`5.0` gives 5V peak to peak"). `play_note` takes a free voice first, otherwise steals the oldest. Source: Just-Type, https://github.com/whimsicalraps/Just-Friends/blob/main/Just-Type.md.
- `mode(1)` picks Synthesis or Geode from the SPEED switch: sound gives Synthesis, shape gives Geode. The mode lasts until power-off or `mode(0)`. Source: Just-Type (as above); tt:docs/ops/justfriends.toml (JF.MODE).
- Geode:
  - `tick(1..48)` is ticks per measure (4 = one per beat) and must be sent continuously to follow an external clock.
  - `tick(49..255)` sets a free-running bpm; 0 resets to the start of the measure.
  - `divs` splits the measure.
  - `repeats` of -1 is infinite, 0 a single trigger, 1 two events.
  - It has 6 channels; `play_note` assigns the oldest unused channel.
  - Sources: Just-Type (as above); tt:docs/ops/justfriends.toml (JF.TICK, JF.VOX, JF.NOTE).

### W/ (`wsyn`, `wtape`, `wdel`)
- A W/ runs one engine at a time (Tape, Del or Syn) and switches engines from the panel. Each engine has its own ii address. A second unit running the same engine takes the alternate address (hold Play+Down at power-on). Source: https://github.com/whimsicalraps/wslash/wiki.
- W/Syn has 4 voices of 2-op FM. Source: the same wiki.
- `wsyn` (crow:lua/ii/wsyn.lua):
  - `velocity(voice, v)`
  - `pitch(voice, v8)`
  - `play_voice(voice, pitch, velocity)`
  - `play_note(pitch, level)`
  - `ar_mode(is_ar)`
  - `curve(v)`, `ramp(v)`
  - `fm_index(v)`, `fm_env(v)`, `fm_ratio(num, den)`
  - `lpg_time(v)`, `lpg_symmetry(v)`
  - `patch(jack, param)`
  - `voices(count)` (0 = unison)
  - getter `fm_ratio`
- `wtape` (crow:lua/ii/wtape.lua):
  - `record(active)`
  - `play(playback)` (-1 flips direction)
  - `reverse()`
  - `speed(speed_or_num, deno)`
  - `freq(v)`
  - `erase_strength(level)`, `monitor_level(gain)`, `rec_level(gain)`
  - `echo_mode(is_echo)`
  - `loop_start()` and `loop_end()` (both mark the current time)
  - `loop_active(state)`, `loop_scale(scale)`, `loop_next(direction)`
  - `timestamp(seconds)` (absolute seek, s32T)
  - `seek(seconds)` (relative)
  - `WARNING_clear_tape()`
  - getters `speed`, `loop_start`, `loop_end`
  - There is no command to set loop points at an arbitrary time. A script seeks with `timestamp` and then calls `loop_start()`/`loop_end()`.
- `wdel` (crow:lua/ii/wdel.lua):
  - `feedback(level)`, `mix(fade)`, `filter(cutoff)`
  - `freeze(is_active)`
  - `time(seconds)`
  - `length(count, divisions)`, `position(count, divisions)`, `cut(count, divisions)`
  - `rate(multiplier)`, `freq(volts)`
  - `clock()` (one sync pulse)
  - `clock_ratio(mul, div)`
  - `pluck(volume)`
  - `mod_rate(rate)`, `mod_amount(amount)`

### ER-301 (`er301`; crow:lua/ii/er301.lua)
- Commands: `tr(port, state)`, `tr_tog(port)`, `tr_pulse(port)`, `tr_time(port, ms)`, `tr_pol(port, rising)`, `cv(port, volts)` (follows slew), `cv_slew(port, ms)`, `cv_set(port, volts)` (ignores slew) and `cv_off(port, volts)`.
- There is no command named `cv_offset` (the ER-301 one is `cv_off`).
- Ports start at 1. Ports of 101 and above go to the next address: 1-100 to 0x31, 101-200 to 0x32, 201-300 to 0x33. Source: crow:lua/ii/er301.lua:67-75.
- The Teletype equivalents are `SC.TR`, `SC.TR.POL`, `SC.TR.TIME`, `SC.TR.TOG`, `SC.TR.PULSE`, `SC.CV`, `SC.CV.OFF`, `SC.CV.SET` and `SC.CV.SLEW`. There are up to 3 units with 100 TR and 100 CV each. Sources: tt:docs/ops/er301.toml; tt:docs/ops/er301.md.
- The ER-301 needs "a slight mod" and a special cable with two pins swapped. Source: tt:docs/whats_new.md:163.

### TELEXo (`txo`; crow:lua/ii/txo.lua)
- Each unit has 4 TR and 4 CV outputs. CV is ±10 V at 16 bits. There can be up to 8 units (0x60-0x67), set by jumpers. Source: https://github.com/bpcmusic/telex (README).
- crow addresses ports 1-32. Ports of 5 and above go to the next unit. Source: crow:lua/ii/txo.lua:537-545.
- The descriptor exposes all of TR, CV, oscillator and envelope:
  - TR: `tr`, `tr_tog`, `tr_pulse`, `tr_time` (plus `_s` and `_m` variants), `tr_pol`, `tr_pulse_div`, `tr_pulse_mute`, and the metronome commands `tr_m*`.
  - CV: `cv`, `cv_set`, `cv_slew` (plus `_s` and `_m` variants), `cv_off`, `cv_qt`, `cv_qt_set`, `cv_n`, `cv_n_set`, `cv_scale`, `cv_log`.
  - Oscillator: `osc`, `osc_set`, `osc_qt`, `osc_n`, `osc_fq`, `osc_lfo`, `osc_wave`, `osc_sync`, `osc_phase`, `osc_width`, `osc_rect`, `osc_slew`, `osc_scale`, `osc_cyc*`, `osc_ctr`.
  - Envelope: `env_act`, `env_att`, `env_dec` (plus `_s` and `_m` variants), `env_trig`, `env_eoc`, `env_eor`, `env_loop`, `env(port, state)` (a gate).
  - Global: `kill`, `tr_init`, `cv_init`, `cv_calib`, `cv_reset`, `init`.
  - Source: crow:lua/ii/txo.lua:11-536.

### Disting EX (`disting`; crow:lua/ii/disting.lua) and the Disting NT
- The crow descriptor is for the Disting EX at 0x41-0x44. Commands:
  - `load_preset`, `save_preset`, `reset_preset`
  - `algorithm`
  - `controller(controller, value)` (0x11)
  - `parameter(p, v)` (0x46), `scale_parameter(p, v)` (0x47)
  - `wav_record`, `wav_playback`
  - `al_pitch`, `al_clock`
  - `lp_clear`
  - `midi(status, b0, b1)` (0x4F), `select_bus` (0x50)
  - `voice_pitch`, `voice_on`, `voice_off` (0x51-0x53)
  - `note_pitch(note_id, volts)` (0x54), `note_velocity(note_id, volts)` (0x55, the note-on), `note_off(note_id)` (0x56), `all_notes_off` (0x57)
  - the dual-algorithm commands (0x5D-0x65)
  - Getters: `preset`, `algorithm`, `parameter`, `parameter_min`, `parameter_max`, `lp_state`, and the `dual_*` getters.
  - Source: crow:lua/ii/disting.lua:1-235.
- The NT is "in general" a follower. Its address is set in Settings (no default is given), its pull-ups have a hardware switch (SW8), and 16384 ↔ 10 V; velocity is 0-16384.
- Messages the NT 1.19 manual documents:
  - controllers and parameters: 0x11, 0x46, 0x47, getters 0x48-0x4A (parameter number 255 selects the "current algorithm");
  - notes: 0x54, 0x55, 0x56, 0x57, and the channel forms 0x68, 0x69, 0x6A, 0x6B;
  - MIDI: 0x4F, 0x50, and 0x81-0x83 for arbitrary MIDI into the NT;
  - CVC: 0x01.
  - Source: disting NT user manual 1.19, "I2C reference", pp. 437-440 (https://www.expert-sleepers.co.uk/downloads/manuals/disting_NT_user_manual_1.19.pdf); pull-up switch in the same manual's hardware section (also manual 1.3 p. 12).
- The NT protocol "is based on that developed for the disting EX" (manual 1.19 p. 437). crow's `note_pitch`, `note_velocity`, `note_off`, `all_notes_off`, `controller`, `parameter` and `scale_parameter` use the same bytes and a compatible scale (1638.3 vs 1638.4 per volt).
- The NT manual does not list the EX's `voice_*` (0x51-0x53), preset or algorithm-load commands. crow has no command for NT channels (0x68-0x6B) or MIDI-in (0x81-0x83), so those need `ii.raw`.
- Firmware notes: 1.11.0 "Added Lua support for I2C commands and getters"; 1.6.0 added direct parameter control. Source: https://www.expert-sleepers.co.uk/distingNTfirmwareupdates.html.

### 16n faderbank (`faders`; crow:lua/ii/faders.lua)
- The descriptor has getters only. Their names are the numbers 1-16 (cmd 0-15) at 0x34-0x37 (4 banks), and each returns an `s16V` value. Usage: `ii.faders.get(1)` and `ii.faders.event = function(e, data) end`. Source: crow:lua/ii/faders.lua:1-83.
- The 16n's 14-bit 0-16383 arrives as 0 to about 10.0 "volts" (16383/1638.3). Sources: crow:lib/ii.c:396-400; 16nx firmware main.cpp:287-294.
- The 16n must be in follower mode (details in §5).
- Each fader is one get: one leader-queue slot (of 16) and one USB event back. No source gives a polling rate.

## 3. Teletype to norns

### The `CROW.*` ops and what crow does with them
- Ops: `CROW.SEL x`, `CROW1:`-`CROW4:`, `CROWN:`, `CROW.V x y`, `CROW.SLEW x y`, `CROW.C1`-`CROW.C4`, `CROW.RST`, `CROW.PULSE x y z t`, `CROW.AR x y z t`, `CROW.LFO x y z t`, `CROW.IN x`, `CROW.OUT x`, `CROW.Q0`-`CROW.Q3`. Sources: tt:src/ops/crow.c:201-222; docs:crow/teletype.md (https://monome.org/docs/crow/teletype/).
- crow handles `volts`, `slew`, `reset`, `pulse`, `ar` and `lfo` in C through default `ii.self.*` handlers that drive its outputs. Source: crow:lib/l_crowlib.c:409-533.
- `CROW.IN` and `CROW.OUT` are answered in C. Source: crow:lib/ii.c:276-283.
- `CROW.C1`-`C4` call `ii.self.call1(a)` through `ii.self.call4(a,b,c,d)`. The arguments are raw signed 16-bit integers, not scaled to volts. Calls are queued and run from crow's event loop. Sources: crow:lua/ii/crow.lua:19-43; crow:lua/ii.lua:72-121; crow:lib/ii.c:300-320.
- `CROW.Q0`-`Q3` call `ii.self.query0()` through `ii.self.query3(a,b,c)`, which must return a number. They run synchronously in the I2C interrupt path ("DANGER!! run the Lua callback directly!"), and the C side calls `luaL_checknumber` on the result. Sources: crow:lib/ii.c:283-288; crow:lib/lualink.c:1112-1126.
- Default handlers print `call<n>`, or print and return 0, until a script replaces them. `crow.reset()`, and therefore every norns script load or crow reconnect, restores the defaults. Sources: crow:lua/ii.lua:91-112; crow:lib/l_crowlib.c:253-262.

### Can a norns script receive what Teletype sends?
- `crow.ii.self.call1 = function(x) ... end` from norns should forward each `CROW.C1` to norns. The assignment sends crow `ii["self"]["call1"]=function(...)_c.tell('<key>',quote(...))end` (`_c` is crow's global library table; crow:lua/bootstrap.lua:54). This is inferred from code and not tested on hardware. Sources: norns:lua/core/crow.lua:205-216; crow:lua/ii.lua:114-117.
  - The same works for `call2`-`call4`.
  - It has to be assigned again after every crow reset or reconnect.
  - Each call becomes a USB message.
- Queries cannot be forwarded to norns. A forwarder returns nil, and `luaL_checknumber` then fails inside the interrupt path. crow issue #492 says crow "can also be made to crash immediately by redefining the `ii.self.query0` function" this way. Source: https://github.com/monome/crow/issues/492.
  - Possible workaround (not verified): norns sends a crow-side function that returns a crow variable, such as `crow("ii.self.query0 = function() return qv end")`, and updates `qv` with `crow.qv = n`.
- Open bug, crow issue #492 (opened 2023-12-27): "When simultaneously receiving serial messages from norns and i2c query commands from Teletype, crow will eventually crash." The reporter saw it on crow 3.0.0 and 4.0.5. With `CROW.Q0` in Teletype's M script and norns sending every 0.17-0.5 s, crow crashed within 20-30 s, and "norns is hung until crow is disconnected or power cycled". The issue is still open. Source: https://github.com/monome/crow/issues/492.
- Uploading code: `crow("...")`/`crow.send` runs any Lua on crow. `norns.crow.loadscript(file, is_persistent, cont)` uploads a file from the script's `crow/` folder (falling back to `code/`). It sends `^^s`, then each line with a 10 ms sleep, then `^^e` to run it or `^^w` to save it to flash. It must run inside a clock, and it is run through `clock.run`. Source: norns:lua/core/crow.lua:68-106.
- Custom tells: a crow-side `tell('myevent', a, b)` arrives on norns as `norns.crow.events.myevent(a, b)`.
  - The script assigns `norns.crow.events.myevent = fn`. Unassigned names print "unused event". Source: norns:lua/core/crow.lua:27-36, 121-135.
  - `tell` takes the event name plus at most 4 arguments, each turned into text with `luaL_checkstring`. Strings and tables have to go through `quote()`. Source: crow:lib/lualink.c:158-196.
  - `norns.crow.events` is rebuilt at script clear. Source: norns:lua/core/crow.lua:121-145.
- Teletype is leader only. `module/main.c` initializes only the leader (`init_i2c_leader()`, tt:module/main.c:1215), and Teletype has no follower address. Neither crow nor norns can send it ii messages. Teletype can only read crow through `CROW.IN`, `CROW.OUT` and `CROW.Q*`.

## 4. Bus leadership and pull-ups
- monome's ii page: "Can I use Crow and Teletype simultaneously on the same ii bus? Yes and no ... If multiple devices transmit at once, there is a possibility of one module locking up, or other odd behavior. As a result this type of setup is not currently supported, though some users have found varying degrees of success using multiple leaders." Source: docs:modular/ii.md:87-95 (https://monome.org/docs/modular/ii).
- crow has no leader or follower setting. It "is always listening ... until it's told to execute a leader-command, at which point it attempts to lead the bus. Once that command / query is complete, it returns to follower mode." Source: docs:crow/faq.md:155-159.
- crow arbitration: crow checks the BUSY flag before it leads (crow:ll/i2c.c:294-297). On arbitration loss the code only prints "TODO Arbitration Lost" (crow:ll/i2c.c:334-340). A stuck leader operation is aborted after a countdown (`I2C_READY_TIMEOUT 20000`, crow:ll/i2c.c:227-248).
- Teletype arbitration: the TWI driver at the pinned libavr32 commit waits on its own software busy flag (`TWI_BUSY_COUNTER 10000`, libavr32 asf/avr32/drivers/twi/twi.c:74-92, 412-415). I found no handling of arbitration loss in it.
- A community wiki states: "Teletype does not support multiple leaders sending messages simultaneously on the same i2c bus" and "multiple leaders sending messages can lead to i2c not working until you power cycle". Source: https://github.com/scanner-darkly/teletype/wiki/II-protocol.
- Follower addresses:
  - crow uses 0x01-0x04, set with `ii.address = n` or `ii.set_address(n)`. Sources: crow:lib/ii.c:68-74, 103-122; libavr32 src/ii.h:5-9; docs:crow/reference.md:879-894.
  - Teletype has none (above).
  - Two crows on the same address answering one query is undefined behavior (crow issue #464, closed).
- Pull-ups:
  - "in many cases you should probably only have one device pulling the lines up". Source: docs:modular/ii.md:63.
  - Teletype and crow both power the bus. Source: docs:modular/ii.md:30-33.
  - crow's are on by default and switchable (`ii.pullup`).
  - The Disting NT says "At least one device on the I2C bus needs to have pull-up resistors enabled. It may work fine with more than one set of pull-ups enabled, or it may not" (manual 1.19, hardware section).
  - Faderpunk's docs say to "Enable one suitable set of pull-ups on the bus" (https://github.com/ATOVproject/faderpunk/blob/main/docs/i2c.md).
  - Original 16n: `I2C_PULLUP_EXT`, so it expects external pull-ups. Source: 16n firmware `16n_faderbank_firmware.ino:201-278` (https://github.com/16n-faderbank/16n).
  - 16nx: `gpio_pull_up` on SDA and SCL in both modes, which are the RP2040's internal pull-ups. Source: https://github.com/16n-faderbank/16next_firmware main.cpp:103-108.
- Recommended setup with crow, Teletype and followers on one bus: monome documents it as "not currently supported" (above). I found no monome recommendation that makes it supported.
- A 16n in leader mode is a second leader on the bus (see §5). In follower mode it answers reads at 0x34 from crow or Teletype.
- Known crow bus instabilities:
  - Max for Live driving Just Friends or W/ through crow "the entire i2c bus will unpredictably crash" (crow issue #497, open). A comment there suggests raising the 16-slot queue.
  - Rapid `ii.ansible.*` loops dropped commands or locked up Ansible (crow issue #221, closed).
  - Just Friends was unstable when it got notes before `jf.mode(1)` at startup (crow issue #220, closed).

## 5. Faderpunk and the 16n/16nx over i2c

### ATOV Faderpunk (https://github.com/ATOVproject/faderpunk, docs/i2c.md, commit 55f422b, 2026-11-09)
- Faderpunk is "a leader by default", at 400 kHz. In leader mode it scans the bus once, 10 s after boot. It sends controller messages only to recognized addresses:
  - 0x20 Ansible
  - 0x31, using "ER-301-compatible" `0x11 <controller> <MSB> <LSB>`, which a Disting NT set to 0x31 accepts
  - 0x60-0x67 TXo
- Only the Control and Panner apps send ii. Values are scaled from 0-4095 to 0-16383.
- "Normal follower mode at address `0x56` is currently unimplemented." Calibration uses a separate follower protocol at 0x57.
- Changing the mode needs a reboot.
- It does not emulate a 16n, and crow has no descriptor for it. crow cannot read it, and no documented message from Faderpunk reaches crow's 0x01-0x04.

### 16n (original, Teensy) and 16nx (RP2040)
- Docs: the 16n sends I2C "either as a master device, which could connect directly to (e.g.) an ER-301 or monome Ansible, or as a bus device for a monome Teletype". The 16nx "still speaks monome-style I2C protocols". Sources: https://github.com/16n-faderbank/16n-faderbank.github.io (16n.md:30, 16nx.md:30, 61).
- The default is follower. The mode is EEPROM byte 3, set in the web editor, and it takes effect after a power cycle. Source: 16n firmware README.md:27-29, 60 (https://github.com/16n-faderbank/16n).
- Follower address 0x34 ("unless you ABSOLUTELY know what you are doing"). Sources: 16n config.h:39-40; 16nx main.h:51-53.
- A leader writes one byte (fader index 0-15) and then reads 2 bytes (MSB, LSB) of a 14-bit value, 0-16383. The 16nx's 12-bit ADC is shifted left by 2 bits, and a rotated layout inverts it. Source: 16nx main.cpp:287-294, 363-393.
- Teletype reads with `FADER x` / `FB x`, where x 1-16 is bank 1 and 17-32 is bank 2, up to 4 banks. Source: tt:docs/ops/fader.toml.
- In leader mode:
  - it does not answer as a follower (`i2c_slave_init` runs only in the follower branch);
  - it scans the bus at boot;
  - it sends each changed fader to every TXo, ER-301 and Ansible it found (TXo/ER-301 cmd 0x11, Ansible cmd 0x06), at 400 kHz.
  - Source: 16nx main.cpp:112-119, 354-356; i2c_utils.cpp:10-83 (https://github.com/16n-faderbank/16next_firmware, commit 9fff5cc).
  - So crow can read a 16n only in follower mode. A 16n in leader mode on a bus where crow also leads is a multi-leader bus.
- crow can read it from norns with `crow.ii.faders.get(n)` and `crow.ii.faders.event`, on up to 4 banks (§2). No source gives a rate.

## Not verified
1. The fastest practical `stream` interval, and how many crow USB messages per second matron or crow can take before dropping or choking. No measured figure found; only the code bounds in §1.
2. Whether the colon-call `crow.output[n]:clock(div)` really fails from norns. This is a code reading; not run.
3. Whether norns' crow clock-in stops following after a script clear. `script.lua:123-127` re-registers input 1 through the proxy, which would send a lettered event, not `^^change(1,1)`. This is a code reading; not tested.
4. That `crow.ii.self.call1..4 = fn` from norns forwards Teletype's `CROW.C*` to norns end to end. Inferred from code; not tested on hardware.
5. Whether the forwarded call path (as opposed to queries) is also hit by the crash in crow issue #492.
6. The exact failure when a query handler returns nil: an unprotected `luaL_checknumber` error, a crash or a hang. Issue #492 reports an immediate crash.
7. What `e.name` holds for the `faders` getters whose names are numbers (number or string).
8. How fast crow can poll 16 faders (16-slot queue, one USB event per fader).
9. Whether a Disting NT answers at 0x41-0x44 by default, so that crow's `disting` descriptor reaches it without `ii.raw`. The manual gives no default address.
10. Whether a W/ ignores ii commands for an engine it is not running.
11. Whether crow's `jf.tick` (argument type s8) can send JF's 128-255 bpm range (see Surprises).
12. The ii command number for `wsyn.transpose` (W/ firmware 2.0.1).
13. Whether Teletype's TWI hardware handles arbitration loss in a way that avoids lockup. I found no code for it, and I did not read the UC3 hardware behavior.
14. Whether the AtoV 16n rework has pull-ups fitted. Only a search summary said so; the manual page returned 403.
15. Any monome or lines recommendation that makes crow, Teletype and a 16n leader on one bus a supported setup. None found; monome says not supported.
16. ER-301 behavior with crow specifically (the hardware mod and pin-swapped cable are documented for Teletype only).

## Surprises
- `CROW.Q*` from Teletype while norns talks to crow over USB is a known, open crash (crow issue #492, crow 3.0.0 and 4.0.5). Redefining a query handler (which forwarding to norns would do) crashes crow at once.
- A norns script cannot answer Teletype queries live. Query handlers run synchronously in crow's I2C interrupt path and must return a number. Only `CROW.C1`-`C4` calls (queued) can be forwarded to norns.
- Teletype is leader only, so nothing can send ii to it, and monome calls crow plus Teletype as leaders on one bus "not currently supported".
- crow handles arbitration loss only as a "TODO" print.
- crow's leader queue is only 16 messages, and overflow drops messages silently ("queue full" goes to crow's console).
- The norns `crow` proxy is limited to 45 function-callback assignments per script session, and each reassignment (including the re-assignments after a crow reconnect) uses up a slot.
- Every norns script load runs `crow.reset()`, which clears crow outputs and actions, metros, output clocks and `ii.self` handlers.
- The docs list `crow.ii.crow.output(channel, level)`, but the descriptor command is `volts` (docs:crow/norns.md:294 vs crow:lua/ii/crow.lua:7). The ER-301's offset command is `cv_off`, not `cv_offset`.
- crow has no descriptor for Teletype, the Disting NT, Faderpunk or i2c2midi.
- `wsyn.transpose` (W/ 2.0.1, "This will require a new `crow` firmware") is not in crow's `wsyn` descriptor, even at the latest source. Source: https://github.com/whimsicalraps/wslash/releases.
- crow's `jf.tick` argument is `s8` (clamped to 127), while JF documents 49-255 as bpm. Bpm above 127 cannot be sent through `jf.tick`; a continuous tick stream (1-48 per measure) is the documented way to follow a clock anyway.
- Faderpunk has no working follower mode and does not emulate a 16n. It leads by default, so it is another leader on any bus with crow.
- A 16n in leader mode stops answering reads.
- The Disting NT does not document the EX's `voice_*` commands. Its channel note messages (0x68-0x6B) and MIDI-in (0x81-0x83) have no crow descriptor entries.
- norns' system "crow out" clock sends two USB messages per pulse from a norns coroutine. A script driving the same output conflicts with it.
- With the clock source set to crow, crow input 1 belongs to the system.
