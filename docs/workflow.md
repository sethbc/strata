# Running work packages through agents

How a session runs a release's work packages (or a batch of fixes) through agents: one controller dispatches workers and reviewers, each worker builds one package on a branch of its own, and the controller lands what passes, several reviewed packages to a pull request (Landing in batches, below). AGENTS.md's rules apply to every package; this file adds the process. A plan's own folder may add its specifics (the release, its waves, ports and fragment names), but never relaxes a rule here.

## Roles

- **Controller**: the session that plans the dispatches, writes the briefs, starts workers and reviewers, rules on their questions, builds and lands the batches' pull requests and keeps the ledger. It runs from the main checkout (the repository's own folder), never from a worktree.
- **Worker**: one agent building one package in its own worktree, from one brief. It neither dispatches agents nor merges.
- **Reviewer**: one agent reading one package's diff against its brief, read-only.

## Skills

The process runs on the superpowers skills. The session doing a step invokes its skill at that step, and a resumed session invokes it again. Where a skill differs from this file or AGENTS.md, this file and AGENTS.md win.

- **Design**: `superpowers:brainstorming`, for anything new. The design goes in `docs/design/<release>-design.md` (a smaller one as `docs/design/<release>-<topic>-design.md`), not the skill's default folder. An approved design is not brainstormed again.
- **Plan**: `superpowers:writing-plans`, saved under docs/superpowers/plans/ while its release is open and removed at the release (At a release, below).
- **Workspace**: `superpowers:using-git-worktrees`. A worker starts in the worktree made for it and makes no other. The controller stays in the main checkout.
- **Execution**: `superpowers:subagent-driven-development`, by the controller at the start of a plan and on every resume. Packages run in parallel, one worktree and branch each, where the skill runs one implementer at a time; the file ownership in each brief is what makes that safe. The skill's ledger is the ledger below.
- **Code**: `superpowers:test-driven-development`, by every worker whose package changes code or tests. A docs-only package skips it.
- **Review**: a plan's packages are reviewed with `superpowers:subagent-driven-development`'s own task-reviewer and re-review templates, with "Review" below as the reviewer's criteria; `superpowers:requesting-code-review`, by the controller, is for a review outside a plan's task loop (a design, a docs change, a release).
- **Finishing**: `superpowers:finishing-a-development-branch`, by the controller at the end of a plan. The choice is always its pull request option, never a local merge: `main` takes rebase merges only.

## The ledger

- The ledger (the record of dispatches, rulings and progress) is `.superpowers/sdd/<plan>/progress.md` in the main checkout, untracked (`.superpowers/` is in `.git/info/exclude`). The plan's folder also holds the briefs (`task-<N>-brief.md`), the common instructions and the review diffs.
- Never inside a worktree: a worktree is removed when its work is done, and the ledger with it.
- When resuming, read the ledger's tail first.
- Record each ruling with its reason and what it costs if wrong, as the files under docs/decisions/ record decisions (`docs/decisions/README.md`).

## Briefs

A brief is everything a worker knows about its package, so it is exact:
- the branch name, and the changelog fragment's name;
- the files the package owns, by path (its ownership: it edits only those, plus registration lines);
- the interfaces it provides and consumes, by exact name and shape (functions, fields, registry records, engine commands with their signatures);
- the tests to write, by name and file, with the values they check;
- the notes and user docs to update;
- the commit message;
- the scratch folder name and, for engine work, the scsynth port.

Where a brief is ambiguous or conflicts with the merged code, the worker reports NEEDS_CONTEXT rather than guess, and the controller rules in the ledger.

## Worker rules

- **One worktree per package.** Start with `git fetch -q origin && git checkout -q -b <branch> origin/main` (append `-2` if the name is taken). Check with `git worktree list` that the directory is not the main checkout; if it is, stop and report without changing anything. Commit before finishing (a worktree with no commits may be deleted). Never use bare `git stash`.
- **No rebase of your own; never merge main in.** The controller's batch puts the package's commits on `main` (Landing in batches, below), so a worker rebases only when the controller asks, and then with `git fetch -q origin && git rebase origin/main` (resolve conflicts commit by commit), then `git push --force-with-lease`. Never `git merge origin/main`, never `gh pr update-branch` without `--rebase`.
- **Own scratch folder, own worktree, nothing else.** Workers share the session's scratchpad, so each works only in `scratchpad/<worker>/` (the name its dispatch gives) and its own worktree. Never write to, rename or delete anything outside those: not another worker's folder, worktree, logs or Docker containers, even when the names look like its own. Generic names (`v0`, `run1`) go inside the worker's folder.
- **Guarded deletes only**: `rm -rf -- "${dir:?}"` on an absolute path inside the worker's own folder, spelled out; `git rm` for tracked files; a worktree only with `git worktree remove`, and only one the worker created.
- **Step 0**: check every name the brief consumes against the merged code. Where a merged name differs, use it and say so in the report; where a consumed interface is missing, report NEEDS_CONTEXT.
- **Ownership**: edit only the brief's files plus registration lines (an include, a `register_params` call, a `START_ORDER`/`CLEANUP_ORDER` entry, a AGENTS.md module-table row, command-table row or invariant bullet). If a test outside the package breaks because of its intended behavior change, change only the minimum lines and list them in the report.
- **Shared files**: never edit CHANGELOG.md; add the changelog fragment the brief names (`changes/<name>.md`, see `changes/README.md`). Edit `docs/status.md` only where the package needs to: a pull request that closes an open item removes that item's line.
- **TDD**: invoke `superpowers:test-driven-development`, then write the brief's failing tests first, see them fail, implement, see them pass.
- **Screen changes**: anything drawn follows AGENTS.md's layout rules; look at the page renders (`lua test/render_pages.lua` then `python3 test/render_pages.py`), since the layout tests miss text over a line and strings crowding nearby baselines.
- US English everywhere (a test enforces it); never name the maintainer in docs, commits or pull requests.
- **Checks before each commit**: `lua test/run.lua`, `luajit test/run.lua` and `lua test/sync_check.lua`. A package that touches engine code or a check area also runs the engine check: its own areas while working (`STRATA_ENGINE_CHECK_AREAS`, on its own `STRATA_SC_PORT`), then every area before pushing, on SuperCollider 3.14.1 (`test/run_engine_check.sh`) and on 3.13, norns' and CI's version (`test/run_engine_check_313.sh`, in Docker: `docs/notes/test-harness/engine-check-runner.md`). It reports #131's rate on 3.13: how many runs passed, failed and crashed, out of how many, and how many ran at once.
- Commit with the brief's message, ending with the session's attribution line, then `git push -u origin HEAD`. A worker opens no pull request: its pushed branch is what the controller's batch lands.

## Findings

Every problem found along the way (by a worker, a reviewer or the controller) gets its own GitHub issue and its own fix, in a package of its own or the package whose files it is in, even when small. None is folded into an unrelated package, deferred without an issue or accepted silently. A worker that finds one outside its package reports it; the controller files it and dispatches the fix.

## Reports

- A worker writes its full report to `TASK-<N>-REPORT.md` in its worktree root (gitignored, never committed): what changed per file, the TDD red and green evidence, Step 0's name differences, the test totals, the engine runs (with #131's rate), every file touched outside its list and why, and its concerns.
- Its reply to the controller is short (under 12 lines): status (DONE, DONE_WITH_CONCERNS, NEEDS_CONTEXT or BLOCKED), branch, commit, test totals, concerns and the report's path.
- The controller copies what it needs into the ledger (`task-<N>-report.md` there), since the worktree goes.

## Review

A reviewer checks one package against its brief, then its build quality. It is a gate for the task, not a merge review. The controller dispatches it through `superpowers:subagent-driven-development`'s task-reviewer and re-review templates, with this section as its criteria.
- Inputs: the brief, the plan's common instructions and constraints, the worker's report and the diff file the dispatch names. Files outside the diff are read with `git show origin/<branch>:<path>` from the main checkout, and only for a concrete named risk.
- Read-only: never modify a working tree, index, HEAD or branch, never dispatch agents, never rerun the full suites (the report carries the evidence). A focused check for a specific doubt is fine in a temporary worktree inside the reviewer's own scratch folder, removed after: `lua test/run.lua <filter>`, or one engine area with `STRATA_ENGINE_CHECK_AREAS=<area>` on a port of its own.
- Flag any edit outside the package's files that is not a registration line or a minimal fix of a test its intended change broke, and any interface whose name or shape differs from the brief, the plan or the merged code (other packages build against those names).
- Check also: the TDD evidence, the plan's constraints, the screen layout rules if anything is drawn, US English, the changelog fragment, the notes file and the user docs.
- Output: part 1, spec compliance (pass or fail, with what is missing, extra or misunderstood); part 2, quality (critical, important, minor, each with file:line and why); then the verdict (spec pass or fail; approved or changes requested), in under 450 words.

## Landing in batches

Reviewed packages land in batches, one pull request per batch, not one per package, so CI runs once for a batch instead of about three times a package (at its opening, after its rebase and on `main`):
- **A batch** is reviewed packages whose files are disjoint, or already ordered. The controller cherry-picks each package's own commits, in order, onto `origin/main` as one landing branch (`land/batch-<n>`), so every package keeps its commits and messages (a branch stacked on another package contributes only its last commits). It runs the three Lua checks there, pushes the branch and opens one pull request whose body has every package's section and every `Fixes #<n>` line.
- **Workers push their branches, but no pull request is opened per package,** and workers do not rebase: the batch does that. A package pull request already open is closed when its batch lands.
- **A red batch** (a conflict while cherry-picking, a failing check, a red CI run) blocks only until it is fixed: the package is fixed (its worker is resumed, and the batch rebuilt) or dropped from the batch and landed later. A failed CI job is rerun once (an engine shard can fail on a slow runner's timing) before the batch counts as red, but for sclang's collector errors, which are a regression of the `areaCall` rule to find, never rerun (`docs/status.md`).
- **After a batch where two packages edit the same user page** (or any shared doc), check that the later one did not overwrite the earlier's lines: a package built before the earlier one landed can carry a line's old text back onto `main` (the final review found a line of `docs/user/pages/lfo.md` reverted that way).
- The controller merges a batch's pull request once CI is green, by rebase (`gh pr merge --rebase`), so `main` stays linear.

## At a release

The release pull request, besides the code's own version lines (`strata.lua`'s header and README.md name the release; a test checks them against CHANGELOG.md; README.md's line gives the version and points at CHANGELOG.md, and never summarizes releases):
- merges the changelog fragments into CHANGELOG.md under the new version and deletes them (`changes/README.md`);
- adds the release's paragraph and its landing line to `docs/history.md`;
- updates `docs/status.md` (its first section, the open items the release closed, the limits it moved) and AGENTS.md's "The current release is" line;
- moves the release's row in `ROADMAP.md` from its section to the Shipped table, and removes the section;
- adds the release's decisions as `docs/decisions/<release>.md`, with its line in `docs/decisions/README.md` (rulings keep the numbers code comments cite);
- marks the lines of `docs/design/<release>-design.md` the build differs from ("amended <date>, as built"), since a shipped design is history and is not rewritten;
- removes the release's plan from docs/superpowers/plans/: git history keeps it, CHANGELOG.md says what it built and the decisions file keeps its rulings.

## Merging and cleanup

- A pull request outside a batch (a release, a docs change) is merged the same way, once CI is green, by rebase.
- Pull requests that touch the same file land one at a time: the later one waits until the earlier merges, then is rebuilt or rebased on `main` and reruns the checks.
- On a conflict in a registration line, keep both lines in the order the sequence needs (AGENTS.md, Working in parallel).
- Leftover worktrees and folders of a finished worker (reported, or stopped) are cleaned up by the controller that dispatched it or by the maintainer, never by another worker. First check that nothing is uncommitted or unpushed (`git -C <worktree> status --short`, `git log @{u}..`), then `git worktree remove <path>` and `git worktree prune`. A worktree whose branch is merged or abandoned goes; one with work not yet pushed is pushed or reported first.
