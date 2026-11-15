# Controllers

An OXI E16 or a box of sixteen faders on Strata's sixteen macros. Back to the [IO page](../pages/io.md).

Both controllers map onto all sixteen macros, whatever bank MOD shows: encoder or fader 1 is macro 1, and so on to 16. Choose each one's MIDI port on IO's `controllers` section (the settings are the rig settings described on the IO page). Everything starts off.

All of this is unverified on the devices until the 4.0 hardware check; it follows the makers' documents (below). In particular, the script uses `string.char`, which the E16 manual does not list among its Lua functions.

## An OXI E16

Strata reads the E16's encoders as relative turns and, with a small script loaded into the E16, draws the macros on its rings and labels.

**Set up the E16** (in OXI's app, or on the E16):
1. Set sixteen controls (the first page of a scene, say) to the type **CC Rel1** (or **CC Rel2**), one CC each, in a row: CC 102 to 117 and channel 16 are Strata's defaults. Output port: the USB port you connect to norns.
2. Connect the E16 to norns by USB (it needs the host port's power, 200 mA) and choose its port in `e16 port`. `e16 channel`, `e16 cc` (the first of the sixteen CCs) and `e16 encoding` (`rel1` or `rel2`) must say what the controls send.
3. Optionally, for rings and labels: load `extras/e16/strata.lua` (from Strata's folder on norns, `dust/code/strata/extras/e16/`) into the scene with OXI's app. The script is not loaded by norns.

**What a turn does.** Under `rel1` the E16 sends 1 for a step up and 127 for a step down; under `rel2` 63 for up and 65 for down. A turn is a turn of the macro's encoder on the norns: one detent (1 %) a step, so macro learn, the gesture recorders and MOD see it as a hand edit.

**What Strata sends back.** Up to fifteen times a second, for each macro whose value changed: its value as a CC (the same number and channel the control sends), and one SysEx frame with all sixteen values for the script's rings. When the E16 is connected, Strata sends each control's label (the macro's first target, cut to four characters, or `M1` to `M16`) and the title `STRATA`; a label is sent again when a macro's first target changes. If the E16 sends your own turn's CC back (its Thru), Strata takes the first CC that matches what it just sent for that echo and ignores it; a real step that looks the same as the echo (the first step up from 0 under `rel1` echoes as 1) can be lost once, never more.

A macro moved by an LFO or the modulation matrix moves only the sound, never the macro's value, the rings or the CCs. Without the script the CCs may still move the controls if the E16's firmware follows incoming CCs; the rings and labels need the script.

When the E16 is connected Strata sends every macro's CC and the rings within a tick, so the rings show the macros at once.

## A box of faders

A 16n Faderbank, a 16nx, an ATOV Faderpunk or any box of sixteen absolute faders. The defaults are the 16n's and the Faderpunk's: CC 32 to 47 on channel 1.

1. Connect the box by USB and choose its port in `faders port`; set `faders channel` and `faders cc` (the first of the sixteen CCs) if you changed them on the box.
2. With the box in its 14-bit mode (the 16n's editor, WebMIDI), turn `faders hires` on: the low 7 bits of each fader come on its CC plus 32 (CC 64 to 79 by default). With hires on, a fader that sends only 7 bits still works over its whole range.

**Pickup.** A fader moves its macro only once it is picked up, so a macro never jumps: pick it up by moving the fader to the macro's value (within about 1.5 %) or through it. After that the fader sets the macro. Anything else that changes the macro (a scene recall, the morph, a turn on the norns, another controller) ends the pickup, and the fader waits until it meets the value again. IO shows sixteen marks, one per fader: `|` picked up, `.` waiting. An LFO or a matrix routing on a macro does not end a pickup.

## MAP clash

PARAMS > MAP also acts on a CC if you mapped it. A controller whose CC is mapped there would move a macro twice, and Strata cannot stop MAP. The section's title shows `map clash` when the MAP holds an entry for a port, channel and CC a controller here uses. To clear it, open PARAMS > MAP, find the parameter mapped to that CC and clear its mapping.

## When something is wrong

- `[--]` on the section title: a port is set and no device is on it.
- `port taken`: a port is set that another part of Strata holds (a remote grid or arc, a MIDI grid through midigrid, the other controller). That controller does nothing until it is set to another port or the holder lets go, when it takes the port by itself.

The MIDI input never holds a port. A controller set to the MIDI input's port (the `midi device` port, 1 by default) takes it: Strata then plays no notes from that port, and SETUP's `midi` row shows the owner in place of the device's name (`midi 1: (e16)` or `midi 1: (faders)`). Set the controller to its own port to keep playing notes from the keyboard there.

## Sources

- OXI E16 User Manual 1.0.1a (relative types, the scripting API of chapter 6).
- The 16n firmware's README and its SysEx and wiki pages (CC 32 to 47, channel 1, 14-bit mode with the low byte on CC + 32).
- Unverified on the device until the 4.0 hardware check.
