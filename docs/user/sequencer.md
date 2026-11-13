# Sequencer

The pattern sequencer: each voice's own length, division and swing, what a step can hold (probability, ratchets, step locks, notes, a gate), Euclidean fill, chaining scenes' patterns and following the clock's transport. Back to the [README](../../README.md).

The patterns themselves are 16 steps per voice, each off or at a level of 1-15 (its accent's strength). They are edited on the [SEQ page](pages/seq.md) and the [grid](grid.md). K2 on SEQ, the grids' play keys and the arc's button start and stop them.

## Each voice's clock

Every voice steps through its pattern on its own clock (PARAMETERS > the voice's extras):
- **seq length** (1-16 steps, default 16): the voice plays steps 1 to its length, then starts again at step 1. A shorter length takes effect at once while the voice is still inside it; when it has already passed the new length, the voice finishes its round first. On the grid, the steps past a voice's length show dimly (level 1) if they are set
- **seq division** (1/32, 1/16t, 1/16, 1/8t, 1/8, 1/4, 1/2 or 1 bar per step; default 1/16): how long each of the voice's steps is. Voices at different divisions and lengths drift against each other and meet again, polyrhythms from one start
- **seq swing** (50-75 %, default 50): every second step the voice plays comes late, by (swing - 50) / 50 of a step: 50 is straight, 66 is close to a triplet feel, 75 puts the step three quarters of the way through its pair. Each voice swings its own division, and swing never drifts against the clock

Each row of the grid shows its own voice's playing step. All the voices start together, on step 1, when the patterns start. **Division reset** (PARAMETERS > sequencer) puts every voice back at step 1 at the next bar, so voices that have drifted apart line up again.

## What a step holds

A set step plays its voice at its level: a running voice gets an accent (Karplus re-plucks its string, a voice in triggered grain mode fires one grain), a stopped one is started. Beyond its level, a step can hold:
- **probability** (0-100 %, 100 when not set): the chance the step plays each time around, drawn once for the whole step
- **ratchets** (1-4 hits): the step plays that many times, evenly spaced through it. Hits are never closer than 20 ms apart: at fast tempos and short divisions a step plays fewer of them
- **step locks** (position, pitch, size): the voice plays that buffer position, grain pitch or grain size for this step only, and goes back to its own value at the next step that plays without the lock. The voice's own setting never changes. Turning the param by hand (an encoder, the arc or a grid fader) while a step lock holds it ends the lock at once. Every step lock also ends when the patterns stop, the voice's pattern is cleared or replaced (a scene recall, the chain), the voice's length is shortened past the step that set it, or, once the step is turned off with no other step of the voice set, when the voice comes around to its step 1 again. Step locks have nothing to do with a voice's lock (`[L]`)
- **a note** (a scale degree, -14 to 14): the step plays the voice that many tones of the global scale above (or below) its own pitch, for this step only: a synth voice's freq, a buffer voice's rate, an input voice's grain pitch (on top of the step's pitch lock when it has one). Degree 0 is the voice's own pitch. While the scale is off every semitone counts, so degree 3 is three semitones up. A buffer or input voice's pitch is the note a MIDI note plays at its rate (rate 1 is middle C)
- **a chord** (up to 8 notes): the step plays them all together. The first is the voice's own note, moved for the step as a single note moves it; the others are extra notes from the note pool, each at its degree from the same pitch (an input voice's on top of the step's pitch lock too). Every hit of a ratchet accents every note. A chord ends where a step lock ends: at the voice's next step that plays (the notes it shares with the chord change pitch where they sound, the rest end), when the patterns stop, the pattern is cleared or replaced, the voice's length is shortened past the step, or the voice comes around to its step 1 with no step left set. A chord takes only free room: notes past the voice's **note cap** (VOICE) or the **note pool** are not played, at any step, so a chord keeps its first notes and a note cap of 1 or a pool of 0 plays its first note alone, as 3.4 did. A step never takes a note or its place from MIDI: it never ends, replaces or re-pitches a note MIDI holds, on any voice, while a MIDI note may take a sequenced note's place. While a MIDI note holds the voice, the chord plays as extra notes beside it as far as there is free room (at a note cap of 1 or an empty pool the step then adds no note)
- **a bookmark** (1-4): a buffer voice jumps to that bookmark as the step plays, but only when the bookmark lies inside the voice's loop (a jump outside it would reset the loop)
- **a gate** (0.05-16 steps): this step's gate length, for a gated voice (below)

Scenes keep every step's attributes with the patterns, and recall them as they recall the patterns.

If a step fails to play one of Strata's own voices (a bug), the patterns stop, show stopped, and the error appears in maiden. Other things a step plays through (MIDI out and other integrations, in later versions) never stop the patterns: one that fails is named in maiden once and left out until the patterns start again.

## Gates

Normally a step only accents a voice that keeps sounding. With **seq gate** on (PARAMETERS > the voice's extras, default off), the voice is heard only while a step's gate is open: each hit opens it (in 5 ms) for **seq gate length** (0.05-16 steps, default 0.5) or the step's own gate, then it closes over **seq gate release** (0.005-4 s, default 0.1). A ratchet's hits share the step's gate length between them. The gate opens and closes a chord's notes together. A gate longer than the gap to the next hit is reopened by it, so long gates tie. With the patterns stopped, a gated voice is silent while MAIN still shows it running; a MIDI note opens the gate too. The delay and reverb tails ring on after it closes. Scenes switch the gate on and off at a transition's end and fade its length and release.

## Euclidean fill

A Euclidean fill spreads a number of hits as evenly as possible over the voice's length (3 hits over 8 steps: steps 1, 4 and 7), turned by a rotation (0 to the length - 1, wrapping around; the hits go from 0 to the length). It writes the voice's first length steps (hits at level 15, the rest off) and keeps the steps past the length and every step's attributes, so you can edit the steps by hand afterward.

## Chaining

**Chain** (PARAMETERS > sequencer) plays a run of scenes' patterns one after the other: while the patterns play, every **chain bars** bars (1-16, default 4) the next saved scene of **chain from** (default 1) to chain from + **chain scenes** - 1 (default 2) gives its patterns, its step attributes and each voice's length and division, going back to the first after the last and skipping empty slots. Nothing else of the scene is applied: the sound, the sources and which voices run stay as they are. Starting the patterns with the chain on loads the first scene of the range at once; switching the chain on while they play waits for the next bar. PSETs store the chain settings; scenes do not.

## Following the clock's transport

**Follow transport** (PARAMETERS > sequencer, or SETUP's `transport` row: `follow` or `off`; default on) lets an external clock start and stop the patterns: with norns' clock source set to MIDI or Link (with PARAMETERS > CLOCK > link start/stop sync on), a MIDI start or a Link start plays every voice from step 1 at once, on the clock's first beat, whether the patterns played or not (a running chain starts again from its first scene), and a stop stops them as K2 does. On the internal clock nothing follows: PARAMETERS > CLOCK > reset neither starts nor stops the patterns. Strata never starts or stops the clock itself: its play keys start the patterns only.

When the clock starts again without the patterns following it (PARAMETERS > CLOCK > reset on the internal clock, or a MIDI or Link start with follow transport off), or its count jumps for another reason (a new clock source chosen in PARAMETERS > CLOCK, for example), while they play, they keep their own count: the next 16th waits for the clock's next 16th, every voice moves by that same amount (at most a 16th later than it would have played, never earlier), and the voices, the chain's bars and the ratchets stay together, with no step played twice. The next start of the patterns counts from the clock again.

If the norns is busy for a moment (a long load, for example) and the patterns fall behind the clock, each voice plays the one step the clock has reached and skips the ones it missed, rather than rushing through them, so the patterns stay in time with the clock. A step that comes a little late (less than a 16th) still plays.
