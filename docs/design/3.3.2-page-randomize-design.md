# Page Randomize (#557): Design

Status: written 2026-11-11 for the maintainer's approval, with the builder check's questions answered. It implements #557.

## Intent

Randomize gets one gesture on every page of parameters: **ALT+K2**. Pressing it again within a few seconds undoes it. The maintainer wants this so the gesture is always the same while playing and becomes muscle memory. Today only MAIN randomizes on ALT+K2. SEQ randomizes on ALT+K3. VOICE, FX and LFO have no randomize.

## Decisions (the maintainer's, 2026-11-10 and 2026-11-11)

1. **ALT+K2 randomizes on every page of parameters, with its undo on the same key.** Where ALT+K2 does something else today, that action moves (#557's direction).
2. **SEQ swaps its keys:** ALT+K2 randomizes the pattern, and ALT+K3 clears it (#557).
3. **VOICE, FX and LFO randomize the section under the cursor**, not the whole page (2026-11-11). MAIN keeps its whole-voice randomize, so VOICE is its fine-grained twin.
4. **Registered per-voice params are randomized on a press only** (2026-11-11). These are variation, voice filter and sends, input history, bookmarks and loop regions.
   - A press of ALT+K2 on one of their sections randomizes them.
   - MAIN's whole-voice randomize, the mutations and the 256 fader pages still never touch them.
   - AGENTS.md's rule "Registered per-voice params ... never reach randomize" becomes "never reach MAIN's randomize, mutations or the fader pages; a page randomize of their own section is the one exception".

5. **On SEQ, #557 wins over 3.4's Question 12** (2026-11-11). 3.4's design gave SEQ's ALT+K2 to opening the step edit view; instead ALT+K2 randomizes there as on every page.
   - In 3.4, opening the step edit view moves to **ALT+K2 held**, SEQ's hold action. Question 12 rejected a hold gesture only because a hold on plain K2 or K3 collides with 3.1's backup idea of K2 held as ALT. A hold under ALT does not.
   - ALT+K3 clears the pattern.
   - 3.4's design is amended to match: Question 12, §8.6 and the step view's own keys, where ALT+K2 resets a row and ALT+K3 randomizes. The step view follows the same rule: ALT+K2 randomizes, its hold resets.
6. **It ships now, before 3.4** (2026-11-11), on today's MAIN, VOICE, SEQ, FX and LFO pages.
   - 3.4's LFO package re-applies the LFO randomize to its rebuilt page (six LFOs, the new fields, the renamed params).
   - 3.4's MOD page, a page of parameters, follows decision 1: ALT+K2 randomizes the section under its cursor, and its "clear the rows" moves to its hold.
   - 3.4's plan settles which of the new LFO and MOD fields are randomized and which are kept. 3.4's design records this.

## Goals, non-goals, anti-goals

- **Goals:**
  - one gesture on MAIN, VOICE, SEQ, FX and LFO;
  - an undo that works the same everywhere;
  - results that stay usable, so a press while playing never blows the mix up.
- **Non-goals:**
  - BUFFER, SCENES and SETUP keep their keys (proposal A below);
  - no grid or arc randomize gesture is added (the 256's pattern randomize keys stay as they are);
  - what MAIN's randomize changes is unchanged (only its timing moves to the release, proposal C).
- **Anti-goals:**
  - a randomize that silences a voice or the master: level, a filter mix of 0, a bypass, or a source switch;
  - one that rewires structure: crossmod sources, LFO destinations, or a voice's source;
  - one that changes a locked voice;
  - an undo that behaves differently on different pages.

## Approaches

1. **One shared core, and each page declares its sections (chosen).**
   - `lib/mutation.lua`'s randomize and undo become a general helper: randomize a set of params within given ranges, with the one shared undo.
   - Each page record names the section under its cursor and that section's params and ranges.
   - The modules that own the registered sections give their ranges in the registration records they already have, so nothing central lists another module's params. This follows the project's "a feature edits only its own files" rule.
2. **One central table** in `lib/mutation.lua` listing every page's sections and ranges. It is simplest to read, but every later page or module would edit that one file, and the registered sections' ranges would live away from their modules.
3. **Each page writes its own randomize and undo.** Nothing shared changes, but it makes four copies of the undo and lock logic, and the undo would drift between pages. That works against the muscle-memory goal.

## The behavior

### The key: quick or held, acting on release

ALT+K2 acts on **release** on every page that randomizes. This is the pattern BUFFER's ALT keys already use (`hold_seconds` 0.5).
- **A quick press** (released within 0.5 s) randomizes, or undoes.
- **A press held past 0.5 s** does the page's hold action. That is **reset to default** on VOICE and LFO (the action ALT+K2 does today on press), and nothing on MAIN, SEQ and FX for now. In 3.4, SEQ's hold opens the step edit view (decision 5).
- While ALT+K2 is held, the hint row names what letting go will do. It changes at 0.5 s, as on BUFFER.

The reason is proposal B below: VOICE's and LFO's reset needs a home. Acting on release on every page keeps the feel the same everywhere.

### What each press randomizes

The **section under the cursor** on VOICE, FX and LFO; on MAIN the whole voice (as today); on SEQ the selected voice's pattern (as ALT+K3 does today). "Kept" means never changed by a randomize.

| Page | Section | Randomized | Kept |
|---|---|---|---|
| MAIN | the selected voice | as today (`randomize_voice`) | as today |
| VOICE | synth (synth source) | the synth's params, as MAIN's synth part | level (amp) |
| VOICE | synth (buffer source) | buffer position, rate and scan (MAIN's ranges); the loop region (the loops module's range: a usable start and length that fit together) | |
| VOICE | input | history (the history module's range) | |
| VOICE | grain | size, density, pitch, spread, envelope | grain mode |
| VOICE | crossmod | speed, and the three slots' amplitude and frequency amounts | the three sources |
| VOICE | mix | pan (where the voice has one) | source, level, freeze, freeze mode |
| VOICE | variation | reverse, pitch jitter, pan jitter, size jitter, interval probability (the variation module's ranges) | the interval set, the custom intervals, quantize (my call: they set the pitch content, and switching the set adds or removes rows under the cursor) |
| VOICE | filter & sends | type, cutoff, res, delay send, reverb send (the voice mix module's ranges) | the filter's mix |
| VOICE | bookmarks | the four positions (the positions module's range) | |
| FX | master | density, tape drift | |
| FX | filter | type, cutoff, res | the filter's mix |
| FX | delay | time, feedback, mix | bypass |
| FX | reverb | mix, size, damp | bypass |
| LFO | the selected LFO | shape, rate (free period or clocked division) | destination, mode, depth, offset, on/off |
| SEQ | the selected voice's pattern | as today (`randomize_pattern`) | |

**Ranges** keep results usable. A range is a part of the param's span, never its whole span when the whole span can blow up the sound. These are my calls; the plan sets the exact values with a test each:
- feedback stays below runaway;
- the delay and reverb mixes and sends stay moderate;
- every res stays below self-oscillation;
- cutoffs and frequencies spread evenly across octaves (as MAIN's exp params do);
- an LFO's free period stays between a few tenths of a second and a few tens of seconds;
- the drift stays subtle.

A binary param a randomize sets goes through `set_binary_param`, so a MIDI-mapped controller follows (#538's rule). Every param a randomize sets reaches the engine through its action, as any param does.

### Undo

- **One undo for the whole script:** the last randomize, wherever it happened. It is MAIN's `S.undo` generalized to name its page, its section and (on MAIN and VOICE) its voice. It holds the params' old values, or the old pattern for SEQ, whose undo restores it through `S.lib.sequencer.replace_pattern`.
- **A quick ALT+K2 undoes** when it lands within 5 s (`UNDO_SECONDS`) on the same page, same section and same voice as the undo. Anywhere else, a quick ALT+K2 randomizes there and replaces the undo.
- **What ends the undo, as MAIN's rule today:**
  - an edit of a param the undo holds (`note_param_edit`);
  - a scene recall;
  - a mutation of the undo's voice;
  - a new randomize.

  SEQ's undo also ends on any edit of that voice's pattern.
- **The hint shows `K2:undo`** while a quick press would undo, and `K2:rand` otherwise. On a locked voice, VOICE shows MAIN's `locked` hint.

### Locks

VOICE leaves a locked voice alone, as MAIN does: ALT+K2 does nothing there, and the hint says `locked`. FX and LFO have no voice, so there is nothing to lock. SEQ randomizes a locked voice's pattern as today, since lock covers params, not patterns; this stays as it is.

## Proposals the maintainer can overturn

- **A. BUFFER, SCENES and SETUP keep their keys.** BUFFER holds files, not parameters: its randomize is K2 held (a random file), and ALT+K2 is clear or fill. SCENES' and SETUP's ALT+K2 do nothing today and stay that way.
- **B. Reset to default moves to ALT+K2 held, on VOICE and LFO.** Both pages already use ALT+K3, for lock and for on/off, so there is no free key. The cost is that randomize acts on release, about a fraction of a second later than on press.
- **C. Every randomizing page acts on release,** for one feel everywhere.
- **D. One shared undo** for whichever page randomized last.

## Constraints (AGENTS.md)

- **ALT:** every ALT+K2 goes through `alt_action`. The release handling joins BUFFER's in `alt_key_release`, and a key pressed with ALT releases through `alt_key_release`. AGENTS.md's ALT rule names VOICE, LFO, MAIN, FX and SEQ beside BUFFER as pages whose ALT+K2 acts on release.
- **Randomize undo:** every param a randomize sets calls `note_param_edit` from its action. The drift's and the undo's own writes never end the undo. A recall, a new randomize, and a mutation of the undo's voice end it.
- **Param to engine:** goes through `send_param_to_engine`. LFOs never `params:set` their destination.
- **Pages:** a page's hints change only through its `hints(alt_held)`, and every change the screen shows calls `request_redraw()`.
- **Locals and ownership:** new per-module state goes in one table. Each page's file owns its sections' randomize sets, and each registered module owns its ranges in its registration record.

## Docs that follow

- `docs/user/controls.md`;
- each page's user page (main, voice, seq, fx, lfo);
- the grid and arc pages, where they mention these keys;
- AGENTS.md's ALT rule, its Randomize undo rule, and its "Registered per-voice params" rule (decision 4);
- the notes for mutation and each page;
- `docs/design/3.4-design.md`: Question 12, §8.6, the step view's keys, the LFO package and the MOD page, as decisions 5 and 6 say. The plan sequences this edit after the open-issues batch lands, since that batch also edits the file.

## Left to the builder

- The helper's name and signature, and the record fields' names.
- The exact range values, within the principles above, with a test each.
- The test layout per page.
- Which existing tests change because ALT+K2 now acts on release.
