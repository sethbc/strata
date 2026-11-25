# Facts for the 3.9 reverb freeze plan: the Lua side, its tests and the docs

A read-only survey of the repository on 2026-11-25, at the design's branch (d4034c42: `main`'s tree at 80b28332), against `docs/design/3.9-reverb-freeze-design.md`. Paths are relative to the repository's root; line numbers are that commit's, so find each site by its text.

## 1. lib/fx_hold.lua (137 lines) and docs/notes/lua/fx-hold.md (58 lines)

Include order (strata.lua): 83 `voice_mix`, 84 `performance`, 125 `delay_sync`, **127 `fx_hold`**, 130 `params_setup`, 134 `ui/header`, 155 `pages/fx`, 196 `grid/pages/fx`.

Places that assume the delay is the only effect that freezes:
- L1-18 header comment ("The invariant `fx hold`: the delay is never bypassed and frozen").
- L24 `M.FX_HOLD = {delay = {freeze_id = "delay_freeze", clear_id = "delay_clear"}}`. To change: add `reverb = {freeze_id = "reverb_freeze"}` (no clear_id). The pages build ids as `FX_HOLD[effect][row.hold .. "_id"]` (lib/pages/fx.lua L120-122), so the reverb record needs only `freeze_id`.
- L26-32 `M.offered(effect)`: `return M.FX_HOLD[effect] ~= nil`. To change: delay true; reverb `S.performance.tier == "high"`. Note that **S.performance is nil at fx_hold's include**: it is first set in params_setup's constructor (lib/params_setup.lua L27-28, include at strata.lua:130), and `read_active` replaces it in the first params record, "performance" (params_setup L355-359; performance.lua L105-115). Nothing calls offered at include time. lib/notes.lua:102 guards with `S.performance and S.performance.tier`. lib/freeze.lua:36 does not guard: `return S.performance.tier == "high"`.
- L35-37 `frozen`, L40-45 `any_frozen` (iterates `pairs(M.FX_HOLD)`), L50-52 `freezable`, L56-59 `toggle`, L63-66 `release`: these work unchanged once FX_HOLD.reverb exists and offered reads the tier. With offered false, `frozen("reverb")` is false even when the param is 1, and release does nothing.
- L69-71 `M.clear()`: `params:set(M.FX_HOLD.delay.clear_id, 1)`. Stays as it is (the reverb has no clear).
- L75-77 the local `bypassed_and_frozen()`: `return S.lib.voice_mix.bypassed("delay") and M.frozen("delay")`. To change: take an effect argument, or loop over FX_HOLD.
- L79-83 `S.register_invariant("fx hold", ...)` returns "the delay is bypassed and frozen (delay_bypass 1, delay_freeze 1)". To change: check both effects and name the effect in the message. The existing test only needs the substring "bypassed and frozen" (fx_hold_test L296). Open question: should the reverb check use `frozen` (which is gated by offered) or the raw param?
- L90-92 the PSET hook `{name = "fx_hold", read = function() if bypassed_and_frozen() then M.release("delay") end end}`. To change: do the same for each effect. Order: fx_hold's hook is registered at include (127), before the engine params' silent-read hook (params_setup L955+, #965), so the release goes out before setBypass. That hook skips params whose save is off (`engine_follows` → `M.load_default(param) == nil`, L968-973), so it never touches reverb_freeze.
- L94-134 `S.register_fx_params({name = "hold", count = 2, add = ...})`. To change: `count = 3`, and add the reverb param after delay_clear: binary, `behavior = "toggle"`, default 0, `name = "reverb freeze"`, `params:set_save(id, false)`, and `S.engine_senders[id] = function(value) engine.setReverbFreeze(value) end`. The delay's refused-while-bypassed action is at L105-117: `if x == 1 and S.lib.voice_mix.bypassed("delay") then set_binary_param(delay.freeze_id, 0) return end; send_param_to_engine(...); request_redraw(); grid_redraw()`. The reverb's condition is `x == 1 and (bypassed("reverb") or not M.offered("reverb"))`. `add_counted` (params_setup L679-680) checks the count, and the group size is `FX_GROUP_PARAMS (11) + Σ record.count` (L20, L544-546).
- A source test, engine_sync_test.lua L311-330, rejects any `.frozen` field name in Lua code. It rewrites `M.frozen(` in fx_hold.lua and `fx_hold.frozen(` elsewhere first, so do not name a field `frozen` (for example `FX_HOLD.reverb.frozen`).

docs/notes/lua/fx-hold.md, the lines to rewrite:
- L3 ("`delay_freeze` is in no PSET and no scene"), L4 (PSET load and the hook, delay only), L5 ("The delay is never bypassed and frozen"), L7 ("`release` checks `offered(effect)` first, so the action calls it for both effects (the reverb has none: below)"), L8 (refused while bypassed), L9-10 (senders, set_binary_param).
- **L12 "The reverb has no freeze"**: the whole bullet goes.
- L14-35 `## Machines` / `### delay freeze`, with State, Invariant `fx hold`, Test and a 13-row table.
- L39 (count = 2, the fx group's order), L41-50, L44 "`M.offered(effect)`: true for "delay", false for anything else (the reverb's freeze is cut)", L54, L58 (Tests: "the reverb not offered on either tier (the cut)").
- **docs_test rule** (test/unit/docs_test.lua L3666-3745, test "every registered invariant has a Machines entry" at L3748): every registered invariant is entered exactly once, and a second entry naming it fails with "`fx hold` is entered twice". A new `### reverb freeze` entry must therefore start its Invariant line with `none` (the parser returns at `^none`, L3692) and then point at the delay's entry. The alternatives are to cover both effects in one entry, or to register a new invariant name. The table header must be `| State | Event | Next | Effect |`.

## 2. lib/voice_mix.lua

- L41-45 `M.BYPASS = {delay = {param_id = "delay_bypass", ..., engine_effect = 0}, reverb = {param_id = "reverb_bypass", ..., engine_effect = 1}}`, and `M.BYPASS_ORDER = {"delay", "reverb"}`.
- L47-51 `function M.bypassed(effect) local bypass = M.BYPASS[effect]; return bypass ~= nil and params:get(bypass.param_id) == 1 end`.
- L232-259: the bypass fx record (`name = "bypass"`, `count = #M.BYPASS_ORDER`). Its action at **L250-253**: `action = function(x) if x == 1 then S.lib.fx_hold.release(effect) end send_param_to_engine(bypass.param_id, x) end`. No change needed. The sender is at L255.
- The comment at L248 and docs/notes/lua/voice-mix.md L8 say "`release` does nothing for an effect with no freeze (the reverb: its freeze is cut from 3.8)". Rewrite both.
- test/unit/voice_mix_test.lua L195-214 "a bypass ends its effect's freeze before it bypasses" runs on standard: reverb bypass sends `setBypass(1, 1)` and no freeze. It still passes. Only its comment at L195 ("the reverb has none (cut from 3.8)") is stale.

## 3. The tier

- `S.constants.STANDARD_PERFORMANCE` (lib/constants.lua L48-52) is `{tier = "standard", buffer_seconds = 16, max_grains = 128, ...}`.
- params_setup L27-28 copies it into `S.performance` when the module is constructed. `S.lib.performance.read_active()` (performance.lua L105-115) sets `S.performance = active` from `performance_active.data`, called by the first params record, "performance" (params_setup L355-359, which also calls `S.close_registries()`). So S.performance holds the right tier before any fx record's `add` runs, but **S.performance is nil at fx_hold's include**.
- Readers of the tier: lib/freeze.lua:36 `return S.performance.tier == "high"`, notes.lua:102, pages/setup.lua:261 and 275.
- How tests run "on high":
  - (a) `h.write_performance_active({tier = "high", buffer_seconds = 60, max_grains = 128, history_seconds = 60, reason = "high: setting"})` before `load_strata()` (test/helpers.lua L118-139, exported L1880; it applies to the next load only). freeze_test.lua L12 defines `local HIGH = {...}` for this. pages_fx_test L1111 uses it.
  - (b) Set the tier after the load: fx_hold_test L354 `S.performance.tier = tier`. This works because offered reads the tier at each use.
- grid_pages_fx_test's `each_arrangement` (L77-86) calls `load_strata()` with no options, so it runs standard. A high run needs (a) before each load inside the loop, or (b) inside the body.
- Layout states (ui_layout tests, render_pages) load without write_performance_active, so they run on standard.

## 4. test/unit/fx_hold_test.lua (454 lines)

Helpers at L16-62. At L36 `freeze_calls` returns `calls_named("setDelayFreeze")`; add a reverb version.

| Line | Test | Changed by the reverb freeze? |
|---|---|---|
| 64 | delay_freeze is a binary fx param, off, never written to a PSET and never a scene field | Yes, its place assertion: L81 asserts `params.params[index + 1].id == "delay_clear"` (still true). No assertion of what follows delay_clear. Unchanged; a reverb twin is needed |
| 103 | delay_freeze sends setDelayFreeze | no (any_frozen stays true/false: the reverb is 0) |
| 115 | delay_clear sends clearDelay with no argument | no |
| 130 | a bypass ends the delay's freeze first | no |
| 149 | a freeze set while bypassed is refused | no; reverb twin needed |
| 181 | toggle echoes to a MIDI-mapped controller | no |
| 200 | a PSET load leaves a freeze as it is | no |
| 222 | a PSET that bypasses the delay ends its freeze... | no |
| 249 | a silent read that leaves the delay bypassed and frozen releases the freeze | no; reverb twin needed |
| 272 | a silent read that leaves the delay running keeps its freeze... | no |
| 283 | the invariant fx hold fails for a delay bypassed and frozen | no (substring "bypassed and frozen"); reverb case to add |
| 305 | clear on a frozen delay releases the freeze, then clears | no |
| **334** | release('reverb') does nothing while the reverb is not offered | **Yes if run on high**. On standard (the default load) it still holds: offered false, release and toggle send nothing, reverb_bypass sends only `setBypass(1, 1)`. Its message "(cut from 3.8)" is stale |
| **351** | the reverb is offered no freeze on either tier (the freeze is cut from 3.8) | **Yes: rewrite** |
| 372 | freezable is offered and not bypassed... | **Yes**: L380-382 assert `not freezable("reverb")`. True on standard (default load), but the comment "(not offered)" stays true only on standard |
| 395 | a tempo change under a frozen synced delay keeps the freeze | no |
| 417 | a frozen delay through a tempo move, a sync switch, a bypass and a PSET load | no |

The pin at L347-368:
```lua
-- The plan's ruling 27: 3.8's package 3a measured the high tier's reverb
-- freeze and cut it ... 4a's and 4b's reverb freeze paths read offered("reverb")
test("the reverb is offered no freeze on either tier (the freeze is cut from 3.8)", function()
  for _, tier in ipairs({"standard", "high"}) do
    local context, S, fx_hold = loaded()
    S.performance.tier = tier
    assert_true(not fx_hold.offered("reverb"), "not offered on " .. tier)
    assert_true(not fx_hold.frozen("reverb") and not fx_hold.any_frozen(), "and never frozen on " .. tier)
    assert_equal(fx_hold.FX_HOLD.reverb, nil, "no reverb record")
    assert_equal(params.lookup["reverb_freeze"], nil, "no reverb_freeze param")
    context.clear_engine_calls()
    fx_hold.toggle("reverb"); fx_hold.release("reverb")
    assert_equal(#context.engine_calls, 0, "toggle and release of the reverb send nothing on " .. tier)
  end
  local spec = h.stubs.engine_spec_from_source(h.engine_sources())
  assert_true(not h.stubs.engine_signatures_from_source(h.engine_sources()).setReverbFreeze,
    "the engine has no setReverbFreeze")
  assert_true(spec.synthdef_controls.strataReverbFDN ~= nil and not spec.synthdef_controls.strataReverbFDN.frozen,
    "and the FDN no frozen control")
end)
```
Per the design (§7), package 1 (the engine) ends the last two assertions (L363-367). Package 2 rewrites the loop: offered false on standard and true on high, the record and the param present on both, and toggle on standard sends nothing.

## 5. The pages

### lib/pages/fx.lua
- Rows at L48-82: the delay's section row L58 `{label = "delay", ..., bypass = "delay", freeze = "delay"}`; L59-60 the time row `{label = "time", ..., param_id = "delay_time", ..., synced = "delay_division", frozen_mark = "delay"}`; L65 the delay's freeze row `{label = "freeze", section = "delay", effect = "delay", hold = "freeze", format = on_off, binary = true}`; L67 the reverb's section row `{label = "reverb", ..., bypass = "reverb", freeze = "reverb"}`; **L69 the size row `{label = "size", section = "reverb", param_id = "reverb_size", format = "%.2f", effect = "reverb"}`**, which gets `frozen_mark = "reverb"`; L72 the reverb's freeze row (hold = "freeze").
- Constants L85-93: `bypass_text "byp"`, `frozen_text "frz"`, `bypass_level 4`, `frozen_mark_text "held"`, `frozen_mark_gap 4`, `unavailable_text "--"`, `hints.freeze "K3:freeze"`, `hints.unfreeze "K3:unfreeze"`.
- `row_param_id` L118-127: a hold row returns nil when `not hold.offered(row.effect)`, otherwise `hold.FX_HOLD[row.effect][row.hold .. "_id"]`. `row_value` L135-144 shows `--` when nil.
- `draw_fx_row` L146-176: a section row's mark L152-161 (`byp` if bypassed, `frz` if `S.lib.fx_hold.frozen(row.freeze)`); **frozen_mark L168-173**: `if row.frozen_mark and S.lib.fx_hold.frozen(row.frozen_mark) then screen.level(FX.bypass_level); screen.move(FX.param_x + screen.text_extents(row.label) + FX.frozen_mark_gap, y); screen.text(FX.frozen_mark_text); screen.level(level) end`. Adding `frozen_mark = "reverb"` to L69 needs no code change.
- Hints `fx_hints` L201-218: with ALT held, freeze if `freezable(row.effect)`, unfreeze if `frozen`. E3 `fx_enc` L220-235 returns when row_param_id is nil, and binary rows go through `set_binary_param`. `fx_alt_key` L307-314 calls `S.lib.fx_hold.toggle(effect)`. ALT+K2 specs L270-283 have no freeze ids.
- Header comment L9-14 ("a frozen delay's time row 'held'"; "The reverb's freeze is reached only through ...offered("reverb") (cut from 3.8, #819: its row shows --)"). Rewrite it.
- layout_states L340-394 freeze only the delay. Layout states run on standard, so a "reverb frozen" state would have to set the tier itself. Also, the test "FX's 3.8 layout states lay out" (pages_fx_test L1137-1170) asserts at L1148-1149 that **no layout state's name contains "reverb frozen"**.

### test/unit/pages_fx_test.lua
The stand-in at L641-652:
```lua
local REVERB_FREEZE_ID = "reverb_freeze"
local function plant_reverb_freeze(S)
  params:add{ type = "binary", id = REVERB_FREEZE_ID, name = "reverb freeze", behavior = "toggle", default = 0,
    action = function() request_redraw() end }
  S.lib.fx_hold.FX_HOLD.reverb = { freeze_id = REVERB_FREEZE_ID }
end
```
**Once the real param exists, this `params:add` raises `"parameter ID collision: reverb_freeze"`** (stub `register`, test/norns_stubs.lua L1249-1262). Every caller must change, either to a high-tier load or to `S.performance.tier = "high"`.
- Callers: L841 (in "ALT+K3 freezes and releases the row's effect; nothing on a bypassed effect, on the shimmer rows, or on a reverb not offered", L811), L882 ("E3 turns a freeze row on and off", L870), L915 ("a frozen effect's section row shows frz at level 4", L888), L981 ("the reverb's freeze row shows -- where it is not offered, and E3 does nothing there", L969), L1041 ("with ALT on a delay or reverb row the hint is K2:rand K3:freeze E3:fine, or K3:unfreeze while frozen", L1020), L1116 ("FX lays out with a reverb frozen on high where its freeze is offered", L1110, which already writes the high tier at L1111).
- **"FX works with the reverb freeze cut" (L734-785)** removes the param from `params.params` and the lookup, sets `FX_HOLD.reverb = nil`, and calls `forbid_param(REVERB_FREEZE_ID)` (L672-686). With the freeze built it should become "on the standard tier", where the param exists, so forbid_param no longer fits as it is. Decide whether pages may read the param on standard: they never do, because row_param_id returns nil when offered is false, so forbid_param can stay without removing the param.
- "the time row is marked while the delay is frozen" (L929-967) is the model for a size-row `held` test.
- "FX lists ... in order" (L688) lists 26 rows; there is no new row.

### lib/grid/pages/fx.lua
- `FX_PAGE.keys.freeze = {delay = 3, reverb = 7}` (L36); levels (L43-44): `on = LEVELS.picked` (15), `off = LEVELS.unpicked` (4), `dark = 0` (constants L154-156).
- Press `effects_key` L104-121: `elseif freeze then if fx_hold.offered(freeze) then fx_hold.toggle(freeze) end`.
- `freeze_level` L139-143: dark when not offered, otherwise `on_off(frozen)`. It is drawn at L157.
- `signature` L173-182: `fx_hold.offered("reverb") and tostring(fx_hold.frozen("reverb")) or "-"` (L180). The real param's action calls `grid_redraw()`, so the term is redundant but harmless. The delay has no term for that reason (#855, grid notes L7).
- No code change is needed. The header comment L8-9 ("the freeze dark and dead while S.lib.fx_hold offers none") stays true.

### test/unit/grid_pages_fx_test.lua
The stand-in at L116-125:
```lua
local function plant_reverb_freeze(S)
  S.lib.fx_hold.FX_HOLD.reverb = {freeze_id = "reverb_freeze"}
  params:add{type = "binary", id = S.lib.fx_hold.FX_HOLD.reverb.freeze_id, name = "reverb freeze",
    behavior = "toggle", default = 0}
  assert_true(S.lib.fx_hold.offered("reverb"), "the planted record makes the reverb's freeze offered")
  grid_redraw()
  return S.lib.fx_hold.FX_HOLD.reverb.freeze_id
end
```
Tests on the reverb's paths:
- "line 7's keys and levels" (L316), its RF block L390-412: 4 then 15, a freeze set elsewhere shows within a drift tick, refused while bypassed.
- **"RF is dark and dead while offered is false" (L416-434)**: asserts "3.8 offers no reverb freeze", then sets `FX_HOLD.reverb = nil` and `params:add{... id = "reverb_freeze" ...}` at L427, which collides once the param exists.
- "with the reverb freeze cut the page draws, and RF is dark and dead" (L436-461): plants, stubs `offered` to return false for the reverb, and sets `params.lookup[freeze_id] = nil`.

All three use `each_arrangement`, which loads standard. On high: RF 4 and 15. On standard: dark (0) and dead.

### Header (lib/ui/header.lua)
- `draw_page_dots` L27-40: `local frozen = S.lib.fx_hold.any_frozen()` (L28). The FX dot becomes a 2x5 bar at `HEADER.frozen_level`. No change. Comment L23-26.
- test/unit/ui_header_test.lua L447-453 (`REVERB_FREEZE_ID`). "the header marks a frozen delay or reverb on every page" (L470-542) asserts at L509 `not offered("reverb")`, and at **L534-541**:
```lua
  params:add{ type = "binary", id = REVERB_FREEZE_ID, name = "reverb freeze", behavior = "toggle", default = 0 }
  S.lib.fx_hold.FX_HOLD.reverb = { freeze_id = REVERB_FREEZE_ID }
  params:set(REVERB_FREEZE_ID, 1)
  each_page(function(name) assert_bar(name .. ", the reverb frozen") end)
  S.lib.fx_hold.FX_HOLD.reverb = nil
  each_page(function(name) assert_dot(name .. ", a reverb not offered") end)
```
This collides too. Rewrite: on high, a set of reverb_freeze shows the bar; on standard (tier "standard", with the param silently at 1) it shows the dot.

## 6. Param counts and fixtures

- **test/unit/params_setup_test.lua L281-285**: `assert_equal(params.params[group_index].n, #FX_PARAM_IDS + 2 + 1 + 3 + 2 + 3, "group size")`. The `2` is fx_hold's hold record, so it becomes 3. The comment at L281-284 names "3.8's lib/fx_hold.lua's delay freeze and clear".
- **PARAM_FIXTURE_ALLOWED** (params_setup_test L1706-1845, against test/fixtures/3.7.0-params.lua). The 1b block L1760-1765: `{kind = "added", id = "delay_freeze", after = "delay_pingpong", ..., record = {t = T.binary, name = "delay freeze", default = 0}}`, delay_clear after delay_freeze, and `{kind = "group_size", id = "strata_fx", add = 2, ...}`. At L1767 the 2a entry `shimmer_interval` has `after = "delay_clear"`.
  - The placement rule (L1983+): "each record kept, then what is placed after it (in the list's order, each followed by what is placed after it)". A reverb_freeze entry with `after = "delay_clear"` appended at the end of the list would therefore land after shimmer_interval and its followers, the wrong place.
  - Either put the new block before 2a's (between L1765 and L1766) with `after = "delay_clear"`, or set shimmer_interval's `after` to `"reverb_freeze"`.
  - Add `{kind = "group_size", id = "strata_fx", add = 1, why = "<id>: ..."}` (several `add` entries sum).
  - Record: `{t = T.binary, name = "reverb freeze", default = 0}`. Every why begins "<id>: ".
- **test/fixtures/3.8.0-start-calls.lua / 3.7.0 / 3.8.0-scene-calls.lua**: none has setDelayFreeze. The start sends no fx freeze, and the silent-read hook skips params whose save is off. A binary default-0 param whose save is off, sent only through its action, adds no start or scene call. system_38_test has `RUN_CALLS_ALLOWED = {}` (L30), so nothing to change, provided nothing sends reverb_freeze at the start.
- The hold record's `count` (fx_hold L97) is checked by `add_counted` (params_setup L679-680) and by the group size sum (L544-546).
- How delay_freeze is treated:
  - PSET save off: `params:set_save` at L119. The test is fx_hold_test L72-87, and params_setup_test L2319 has `assert_equal(setup.load_default(lookup("delay_freeze")), nil, "a param saved nowhere: none")` (optionally add reverb_freeze).
  - Not a scene field: scenes' `SCENE_GLOBAL_PARAMS` is an explicit list (lib/scenes.lua L104-121).
  - Not an LFO destination or macro target: lfos.lua L101-102 is an explicit list, `S.lib.macros.target_ids()` (macros.lua L134) comes from the LFO-destination catalog, and fx_hold_test L98-100 checks it.
  - MIDI-mappable by default (norns pmap), with echo through set_binary_param.
- **test/unit/factory_test.lua L556-567** "the allow side covers 3.8's sound params and skips the holds" has `lines = {'"delay_freeze": 1', ...}` and asserts the line is refused ("the line for delay_freeze is refused"). The comment L557-558 says "3a's reverb freeze is cut". The factory refuses any param whose save is off generically (lib/factory.lua L308 `param.save == false`, refusal message L350-355). reverb_freeze needs no naming in factory.lua; adding `'"reverb_freeze": 1'` to the test is optional coverage. The fx group is not a rig group (factory.lua L44-50). L609-615 "a held delay freeze stays through a load" could gain a reverb twin (optional).
- params_setup_test L1341-1366 (#965/#883, a silent read that bypasses a frozen delay) is the model for the reverb's silent-read test.

## 7. Other modules
`delay_freeze` appears in lib/ only in lib/fx_hold.lua. None of these name a freeze, and none needs reverb_freeze: lib/macros.lua (targets from the LFO catalog), lib/matrix.lua, lib/lfos.lua (L101-102 explicit fx destinations), lib/mutation.lua (FX randomize specs are lib/pages/fx.lua L270-283, explicit ids), lib/scenes.lua (L104-121 explicit globals), lib/io/*.lua (no fx ids at all), lib/arc/fx.lua (explicit rings, reverb_mix etc.), lib/engine_sync.lua (setReverb's sender only). ui_layout_test.lua and test/render_pages.lua have no freeze or tier references; they run each page's layout_states on standard.

## 8. Docs to update (sentences that say the reverb has no freeze, or that name only the delay)
- docs/user/effects.md: L9 (Reverb bullet; the high tier's FDN). L30 `## Delay freeze and clear`, L32 "While the delay is frozen, FX's dot in the header stands tall on every page.", L34-36 (L36: "Neither is saved ... unless the PSET bypasses the delay ..."). L48-54 `## Bypass` (L50, L52: "changing ... the reverb size ... meanwhile takes effect when the bypass is lifted"). No sentence there says the reverb lacks a freeze; a new "Reverb freeze" section goes beside L30. Headings: L13, 21, 30, 38, 48.
- docs/user/pages/fx.md:
  - L10 (reverb rows, incl. `freeze`).
  - **L13**: "...While the delay is frozen its `time` row also shows `held` (dim) after the label... The reverb's `freeze` row shows `--`: Strata 3.8 has no reverb freeze, and the row does nothing."
  - L16 (E3 on `freeze`).
  - **L21**: "**ALT+K3 on a delay row** - ... On a reverb row ALT+K3 does nothing (Strata 3.8 has no reverb freeze); on the filter, master and shimmer rows nothing either".
  - L24 "**The frozen mark.** While the delay is frozen, FX's own dot ...".
  - L30 hint: "`K3:freeze` (or `K3:unfreeze` while frozen) on a row of a running delay".
- docs/user/grid/pages/fx.md: L18 (db/rb: "A bypass ends the effect's freeze"), L20 (DF), **L22 "**RF** (line 7, key 7) is the reverb's freeze. 3.8 has none, so the key is dark and does nothing"**, L9 (the key map), L27.
- docs/user/params.md `## FX (group)` L13-28: **no bullet for delay freeze or clear exists** (L23 bypasses, L24 delay to reverb, L25 shimmer, L26-28 sync/division/ping-pong). The design asks for params.md, so the plan adds a bullet (for both freezes, or the reverb's alone). The docs test on params.md (docs_test L4087, "params.md names every Strata group in menu order and every param of a voice's last three parts (#343)") checks groups and per-voice params only, not fx params, so no test forces it.
- docs/notes/lua/pages/fx.md:
  - L8 "(3.8 cut the reverb's freeze, #819: there is no `reverb_freeze` param, and a test checks nothing reaches for one). Never decide from a param's presence or `S.performance.tier`."
  - L12 (`held` within 128x64).
  - **L13 "The time row's `held`** (#911, 3.9): a row's `frozen_mark = "<effect>"` (the delay's `time` row alone)…"
  - L39 (rows), L40, L41 ("A frozen delay's `time` row shows ... `held`"), L44 (ALT+K3 "a delay or offered reverb").
  - L46 layout_states: "No state freezes the reverb: on this build its freeze is not offered, and the page plants no test param (4a's review)."
  - **L47**: "The tests reach a reverb freeze behind the same seam a later package would fill: they plant ... (`plant_reverb_freeze` ...; the header test the same)...".
- docs/notes/lua/grid/pages/fx.md: **L4** "...so with no freeze (3.8: package 3a's freeze was cut, #819) RF is dark (0) and dead ...; a later package that puts `FX_HOLD.reverb = {freeze_id = ...}` and its param in place lights it with no change here." L7 (the follow: "`delay_freeze` (always: so its term is not in the signature, #855)", "the reverb's freeze (`-` while not offered)", "\"line 7's keys and levels\" for the planted reverb freeze"). L25 table row `| 7 | 3, 7 | while offered(effect) ... | offered: 15 frozen / 4; else 0 |` (still right).
- docs/notes/lua/ui/header-and-flashes.md **L42**: "while `S.lib.fx_hold.any_frozen()` (the delay frozen, or a reverb whose freeze is offered; 3.8 offers none, #819)".
- docs/notes/lua/voice-mix.md L8 ("the reverb: its freeze is cut from 3.8"). docs/notes/lua/factory.md L3 and L44 name `delay_freeze` as saved nowhere (optionally add reverb_freeze).
- Code comments to refresh: lib/fx_hold.lua L1-18, L26-29; lib/pages/fx.lua L9-14, L41-47; lib/voice_mix.lua L248; lib/ui/header.lua L23-26 (still right); test comments in voice_mix_test L195, factory_test L557-558, ui_header_test L447-452, pages_fx_test L641-646, grid_pages_fx_test L116-117.
- AGENTS.md is 7,927 words (8,000 limit). The rule at L201 "**Delay freeze and clear**". Package 1 owns the command row, per the design.

## 9. Status, roadmap, #6
- docs/status.md: L8 ("Plans:" ... "then #819's design ... approved on 2026-11-25, its plan next"); **L14** ("Next: 3.9 ... then #819, the high tier's reverb freeze, cut from 3.8 ..."); L17 (#6: "Its body is the essential list, with a section for each release's additions (... 3.9's first part as §14, and the rework's, added at its plan's end)"); L23 (pool figures, `\strataReverbFDN` 228.4 KB, "a reverb freeze, #819, may take it to 242": package 1). A new "3.9's third part" bullet would follow L16.
- ROADMAP.md: L28 (Goals 9: "the high tier's reverb freeze comes next (its design ... approved 2026-11-25)"), L67 (table row "... the high tier's reverb freeze"), L75, and the `## 3.9: what 3.8 delays` section L104-111 with its first bullet **L108** "**The high tier's reverb freeze** (#819). 3.8's package built ... cut ...". Mark it built there.
- **#6's checklist is only the GitHub issue body** (`gh issue view 6`); no repository file holds it. Its sections run to "## 15. The 3.9 additions, second part (the grid's sequencer reworked; ...)". §14 already holds "The delay's freeze, clear and a silent read", and §4 mentions the "high-tier FDN reverb". So the line goes in as a new "## 16. The 3.9 additions, third part" (or under §15) through `gh issue edit 6 --body-file ...`. status.md L17's list of sections is then updated to name it. No plan in docs/superpowers/plans/ shows a specific command for this; the grid-sequencer rework's "Its device checks are added to #6 at the plan's end" (status L16) is the precedent.
- Also: docs/decisions/3.9.md exists (add this design's decisions and calls). changes/design-3.9-reverb-freeze.md already exists (the design branch's fragment); each pull request adds `changes/<branch>.md`.
- Engine-side facts touching Lua tests (package 1): test/norns_stubs.lua L746 `setDelayFreeze = function(args) return range("frozen", args[1], 0, 1) end` (add setReverbFreeze beside it); test/sync_check.lua L216-217 `sync_check.PENDING_COMMANDS = {}` (package 1 adds "setReverbFreeze", package 2 removes it).
