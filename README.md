# Archon BMAD

**A collection of [BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD) workflows for the
[Archon](https://archon.diy) workflow engine.**

This repository is a home for native Archon workflows that automate parts of the BMAD method. Each
workflow is a self-contained `*.yaml` file in [`workflows/`](./workflows) that runs locally, in chat,
or on the web UI — no tmux, no Python helper, no separate orchestrator process. Install them all at
once and run whichever one you need.

The collection grows over time. The first workflow,
[`archon-bmad-story-automator`](#archon-bmad-story-automator), automates the BMAD *implementation*
loop; future workflows will cover other parts of the method (planning, review, release, and so on).

---

## Install

`./install.sh` copies **every** workflow in [`workflows/`](./workflows) into your Archon workflows
directory — so a single install gives you the whole collection, and re-running it picks up any
workflows added later.

**Global (every project on your machine):**

```bash
./install.sh
# copies workflows/*.yaml -> ~/.archon/workflows/
```

**A specific repo:**

```bash
./install.sh /path/to/your-bmad-project/.archon/workflows
```

**Manual:**

```bash
mkdir -p ~/.archon/workflows
cp workflows/*.yaml ~/.archon/workflows/
```

Respects `ARCHON_HOME`. Verify the collection is discoverable (every workflow here is named
`archon-bmad-*`):

```bash
archon workflow list | grep archon-bmad
```

---

## Workflows

| Workflow                                                | Automates                                                                 |
| ------------------------------------------------------- | ------------------------------------------------------------------------- |
| [`archon-bmad-story-automator`](#archon-bmad-story-automator) | The BMAD implementation loop — create → dev → review → commit per story, with per-epic retrospectives and (in [stacked-branching](#stacked-branching--pr-automation) mode) a final cross-story [integration rebuild & antagonistic review](#post-fix-integration-rebuild--antagonistic-review). |

_More workflows will be added here over time._

---

### archon-bmad-story-automator

A port of the [`bmad-story-automator`](https://github.com/bmad-code-org/bmad-automator) onto the
Archon workflow engine. After you've finished BMAD planning (PRD, architecture, sprint plan) and
`sprint-status.yaml` exists, this workflow drives the whole implementation cycle — story by story,
with an adversarial review gate and per-epic retrospectives — using **your existing BMAD skills**.

#### What it does

For each selected story it plays one role per loop iteration, verifying against the real
`sprint-status.yaml` after every step (never trusting a session that merely "looks done"):

| Phase    | BMAD skill invoked              | What happens                                                        |
| -------- | ------------------------------- | ------------------------------------------------------------------ |
| `branch` | —                                | *Only if the repo uses [stacked branching](#stacked-branching--pr-automation)* — checkout/create this story's own branch, stacked on the previous story's |
| `create` | `bmad-create-story`             | Write the next story file (YOLO, autonomous)                       |
| `dev`    | `bmad-dev-story`                | Implement all `[ ]` tasks, run tests, tick checkboxes              |
| `auto`   | `bmad-qa-generate-e2e-tests`    | Optional — test-gen; **auto-skipped** if the skill isn't installed |
| `review` | _inlined adversarial reviewer_  | Attack impl vs story claims + git reality; auto-fix; **gate = 0 CRITICAL & 0 HIGH**; loops ≤ 8 |
| `commit` | —                               | `git commit` after review verifies; if stacked branching is on, also pushes and opens/updates this story's PR |
| `retro`  | `bmad-retrospective`            | Fires per epic when every story in it is `done`; YOLO; non-blocking |
| `integrate_review` | — | Runs **once**, after everything above — *only does real work in [stacked-branching](#stacked-branching--pr-automation) mode* — see [Post-fix integration rebuild & antagonistic review](#post-fix-integration-rebuild--antagonistic-review) |

When everything in your selection is `done`, each completed epic has had its retrospective, and the
integration review (below) has run, the run finishes and emits a report.

#### Review gating & automatic fixes

The `review` phase is an **inlined adversarial reviewer**, not a rubber stamp. Each iteration it
validates the story file's *claims* against the *actual* implementation and git reality — cross-checking
the File List against `git status`/`git diff`, hunting for acceptance criteria that are missing or only
partially implemented, verifying that every task marked `[x]` was genuinely done, and doing a code-quality
pass (security, error handling, performance, real-vs-placeholder test assertions). Because it runs with
`fresh_context: true`, every pass is a clean-slate re-attack rather than a reviewer talking itself into
"looks good."

Findings are bucketed into four severities, and the workflow treats them differently along **two
independent axes** — what gets *fixed*, and what *blocks the commit*:

| Severity   | Example                                                                       | Auto-fixed?            | Gates the commit? |
| ---------- | ---------------------------------------------------------------------------- | ---------------------- | ----------------- |
| `CRITICAL` | A task marked `[x]` that wasn't actually done; a File-List file with no git change (false claim) | Yes                    | **Yes**           |
| `HIGH`     | An acceptance criterion missing or only partial; a security hole             | Yes                    | **Yes**           |
| `MEDIUM`   | A changed file absent from the story's File List; weak error handling        | Yes, where practical   | No                |
| `LOW`      | Style nits, minor cleanups                                                   | Tracked only           | No                |

**Automatic fixes.** When the reviewer finds a `CRITICAL`, `HIGH`, or `MEDIUM` issue it edits the code
directly, adds or adjusts tests, and re-runs the suite to confirm green — all *within the same iteration*,
so fixing more issues doesn't cost extra loops. `LOW` findings are recorded in the review notes but left
for a human. None of these fixes are committed during `review`; they sit uncommitted in the working tree
so the whole story still lands as **one atomic commit** in the `commit` phase.

**The gate.** A story is only allowed to flip to `done` when **0 CRITICAL and 0 HIGH** findings remain
after the fix pass. If any CRITICAL or HIGH survives, the story is set back to `in-progress`, the retry
counter increments, and the loop re-enters `review` for another adversarial pass — up to
**`maxReviewRetries` (default 8)** times. Exhausting the retries marks the story `failed` with an
escalation reason rather than shipping it. Gating on `HIGH` (not just `CRITICAL`) also closes a subtle
gap: a fix applied to a HIGH finding gets re-verified by a fresh adversarial pass before commit, instead
of being committed unchecked.

**Why MEDIUM/LOW don't gate.** An adversarial reviewer with fresh context can almost always surface
*some* subjective MEDIUM ("add more coverage", "consider refactoring"). Letting those block the loop
risks never converging and failing perfectly good stories on taste. So MEDIUM is fixed opportunistically
but never blocks, and LOW is left to human judgment. In practice CRITICAL and HIGH clear within a couple
of cycles, so the 8-retry ceiling is comfortable headroom rather than an expected limit — tune it (and
the other knobs) under [Configuration knobs](#configuration-knobs).

#### Requirements

- **Archon** installed (`archon` CLI or the web UI). See https://archon.diy.
- A **BMAD-METHOD project** with planning complete — i.e. `_bmad/bmm/config.yaml` and
  `<output_folder>/implementation-artifacts/sprint-status.yaml` both exist. For the default worktree
  isolation, **track (commit) your `_bmad-output/`** so the worktree checks it out — see [Isolation](#isolation).
- The BMAD implementation skills installed in the project under one of `.claude/skills`,
  `.agents/skills`, or `.codex/skills`:
  - `bmad-create-story` *(required)*
  - `bmad-dev-story` *(required)*
  - `bmad-retrospective` *(required)*
  - `bmad-qa-generate-e2e-tests` *(optional — the `auto` phase is skipped if absent)*

The workflow defaults to the `claude` provider so the BMAD skills are auto-discovered. It works with
any project BMAD targets (the workflow itself is project-agnostic).

#### Usage

Run from the **root of your BMAD project**. By default Archon runs it in an isolated git worktree and
the per-story commits land on that worktree's branch (see [Isolation](#isolation)); pass `--no-worktree`
to run directly in your live checkout instead:

```bash
# Implement a whole epic
archon workflow run archon-bmad-story-automator "epic 2"

# Implement specific stories
archon workflow run archon-bmad-story-automator "stories 2-1 through 2-4"

# Implement everything still pending in sprint-status
archon workflow run archon-bmad-story-automator "all pending stories"

# Kick it off detached and watch it
archon workflow run archon-bmad-story-automator "epic 2" --detach
archon workflow runs
```

You can also launch it from Archon chat ("run archon-bmad-story-automator for epic 2") or the web UI.
The free-text argument is interpreted by the loop's `select` phase against `sprint-status.yaml`, so
natural phrasing ("epic 2", "the auth stories", "everything left") works.

#### Isolation

By default, Archon runs each workflow in an isolated git **worktree** — a separate checkout under
`~/.archon/workspaces/<group>/<repo>/worktrees/archon/`, on a branch Archon names automatically
(`archon/task-archon-bmad-story-automator-<timestamp>`). Your live checkout is never touched, and
multiple runs can proceed in parallel. The worktree **persists after the run** — Archon does *not*
auto-merge or auto-delete it; you integrate and tear it down explicitly (see below).

**Hydrating BMAD's gitignored inputs.** A worktree contains only *tracked* files, and BMAD gitignores
everything the skills need to run: `_bmad/` (config and the scripts the skills execute) and the skill
roots `.claude/`/`.agents/`/`.codex/` (the BMAD skills themselves). So the workflow's `init` node
**copies those into the worktree** from your live checkout before anything else runs (`cp -Rn`, so it
never overwrites a tracked file, and they stay gitignored so nothing of BMAD's tooling leaks into a
commit). The BMAD **output** folder (`_bmad-output/` with `sprint-status.yaml` and the story files) is
*not* copied — the workflow assumes you **track it in git** (so it's shared across people and personas),
so the worktree checks it out natively. Commit your planning output before running.

**Two requirements for worktree mode:**

- **A discoverable default branch.** Archon bases the worktree on `origin/HEAD`, falling back to
  `origin/main`. If your repo has neither (a local-only repo, or a `master` default with no remote),
  worktree creation fails — set `worktree.baseBranch` in `.archon/config.yaml`, or pass `--from <ref>`
  per run.
- **Build dependencies.** A fresh worktree has no gitignored deps (`node_modules/`, virtualenvs, etc.),
  which the workflow installs for you — mirroring how Archon's own bundled dev-loop workflows handle it.
  In two layers: `init` does a fast best-effort frozen install for the common JS case (`bun`/`npm ci`/
  `yarn`/`pnpm`), and the `dev` phase then discovers and installs across every ecosystem (JS, plus
  `pip`/`poetry`, `cargo`, `go mod`) before running tests. You normally don't need to do anything. The
  exceptions are environments the auto-detect can't satisfy unattended — a **private registry needing
  auth**, or a **missing language toolchain**; for those, provision them once (e.g. via `archon continue
  <branch> "install deps"`) or run `--no-worktree`.

**Integrating a run.** Per-story commits land on the worktree's branch; the final report prints the exact
commands. In short — review, integrate, then tear down:

```bash
git -C <live-checkout> log --oneline <base>..<worktree-branch>   # review what landed
git -C <live-checkout> merge --no-ff <worktree-branch>           # merge locally (refs are shared), or:
git -C <worktree> push -u origin <worktree-branch>               # push & open a PR instead
archon complete <worktree-branch>     # remove worktree + delete branch (refuses unless merged/pushed; --force to override)
```

Re-enter the **same** worktree (inputs already hydrated) to do more:
`archon continue <worktree-branch> --workflow archon-bmad-story-automator "<more stories>"`.
`archon isolation list` shows active worktrees; `archon isolation cleanup --merged` bulk-removes merged ones.

**Running in the live checkout instead.** Pass `--no-worktree` to skip worktrees and run directly in your
live checkout (the copy step then no-ops — the gitignored inputs are already there). `--branch <name>` /
`--from <ref>` control the worktree's branch and base point.

#### Stacked branching & PR automation

Some BMAD projects adopt a repo-wide convention of **one branch + one PR per story, chained as a
stack**, instead of landing every story on one long branch — the standard "large PR is unreviewable"
fix, using something like the [`gh-stack`](https://github.github.com/gh-stack/) extension or manual
`gh pr create --base <previous-story-branch>`. This workflow **auto-detects** that convention and
adapts, with zero configuration:

- **Detection.** `init` looks for `.agents/rules/story-branching-stacked-prs.mdc` (or a
  `.cursor/rules/`/`.claude/rules/` projection of it). If found, the run switches into stacked-branching
  mode (`stackedBranching: true` in `bmad-env.json`) and copies the rule's full text into
  `$ARTIFACTS_DIR/branching-rule.md` so every phase's prompt — including the inlined `review` phase,
  which bypasses BMAD skills' own `persistent_facts` — sees it. Projects without that rule file see
  **no change in behavior**: everything still lands on the single run-wide worktree branch as before.
- **Per-story branch (new `branch` phase).** Runs right before `create`/`dev` for each newly-selected
  story. Branch name: `feat/<epic-slug>/story-<epic>.<story>`. The epic slug is resolved once per epic
  (reused from an existing `feat/*/story-<epic>.*` branch if the epic's stack is already underway, else
  derived from the most-recently-modified `<output_folder>/specs/spec-*` folder name, else from
  `project_name` in `_bmad/bmm/config.yaml`). Every story branches off the **previous story's own
  branch** — that's the "stack" — and this chaining crosses epic boundaries: an epic's **first** story
  branches off the **previous epic's last story branch**, not off the repo's default branch. The repo's
  real default branch (`origin/HEAD` / `origin/main`) is only ever the parent for the very first story
  of the very first epic ever worked in the repo. Any stray uncommitted changes are safety-stashed
  before switching.
- **Push + PR (extended `commit` phase).** After the atomic commit, the story's branch is pushed to
  `origin` and its PR is opened with `--base` set to the branch it stacked on — via `gh stack submit` if
  the [`gh-stack`](https://github.github.com/gh-stack/) `gh` extension is installed, else a plain
  `gh pr create --base <parent-branch>`. Both push and PR creation are **best-effort**: a missing/
  unauthenticated `gh`, no network, or a repo without native stacked-PR support never fails the story —
  it's logged and left for the final report and a human to finish. Re-running is idempotent (an existing
  PR for that branch is detected and left alone rather than duplicated).
- **Report.** When `stackedBranching` was on, the final `report` node lists each completed story's own
  branch, what it's based on, and its PR URL/number (via `gh pr list`) instead of the single-branch
  merge instructions.

This requires no changes to the rule file's location or content beyond what your project already uses
for [the convention itself](https://github.com/github/gh-stack) — the workflow only *reads* it.

#### Post-fix integration rebuild & antagonistic review

The per-story `review` phase is deliberately narrow — each pass only ever sees **one story's own
diff**. That's the right scope for "did this story do what it claims," but it structurally cannot catch
a gap that only exists at the **seam between stories**: e.g. an early story adds a processor module,
and a later story that's supposed to wire it into the live pipeline never actually does, or a config
flag one story introduces is set but nothing downstream ever reads it. Each story's review looks clean
in isolation; the feature is still broken end-to-end. This is exactly the class of defect a real
antagonistic pass over the *whole merged stack* — read against the PRD, epics, and architecture, not
just each story's own acceptance criteria — is built to catch.

`integrate_review` is a final phase that runs this check automatically, **once per run**, after every
targeted story is `done` and any newly-completed epic's retrospective has fired — the last gate before
`status` is allowed to reach `complete`:

1. **Rebuild the whole stack, fresh.** It doesn't limit itself to the stories this particular run
   touched — it enumerates every `feat/*/story-*` branch that exists in the repo today (the full
   feature as it currently stands, e.g. all 5 epics / 15 stories, even on a run that only fixed 7 of
   them) and sequentially `git merge --no-ff`s them, in stack order, onto a **fresh, local-only,
   never-pushed** `integration/review-<timestamp>` branch. Nothing is pushed anywhere and nothing is
   deleted afterward — the branch is left in place for you to inspect or reuse.
2. **One antagonistic review of the merged result.** Prefers a clean sub-agent/Task-tool context (falls
   back to reviewing inline if unavailable) that reads the full PRD, epics/acceptance-criteria,
   architecture doc, and spec, plus every story file in the stack — then inspects the *actual merged
   code*, not story claims, checking criteria that only make sense when multiple stories compose
   together. Findings are classified `CRITICAL`/`HIGH`/`MEDIUM`/`LOW` with file/line evidence, written
   to `{planningArtifacts}/integration-review-<date>.md`.
3. **Branches on the outcome, doesn't auto-fix:**
   - **0 CRITICAL / 0 HIGH** → `integrationReviewDone = true`, the run proceeds to `status =
     "complete"` as normal.
   - **1+ CRITICAL or HIGH** → the run halts with `status = "needs-attention"` (distinct from `failed`
     — every individual story genuinely passed its own review; the gap is cross-story) and the final
     report points at the findings file and recommends running BMad's `bmad-correct-course` workflow,
     since a cross-story integration gap is exactly the kind of "significant change" that process
     exists to triage (it may need new fix-stories, not a blind patch).
   - A **merge conflict** while rebuilding the stack halts the same way — that means the stack itself
     is no longer cleanly stacked (e.g. a fix landed on one branch without rebasing the branches after
     it), which needs a human decision, not an autonomous resolution.

**This is the mechanized version of a manual process**: rebuild a disposable local integration branch
by replaying the stack in order, then point one adversarial reviewer at the *composed* result instead
of any single story's diff.

**Single-branch (non-stacked) projects**: this phase is a deliberate no-op. Without the
[stacked-branching convention](#stacked-branching--pr-automation) every story already lands on the same
one worktree branch, so there's no separate `feat/*/story-*` branches to rebuild or merge — the phase
detects none exist, marks itself done immediately, and the run completes exactly as it always has. You
only get real cross-story integration review by adopting stacked branching.

#### Configuration knobs

Edit `workflows/archon-bmad-story-automator.yaml` to taste:

- `model:` — uses real Claude aliases so it works without extra setup: default `sonnet`, the heavy
  `build-loop` node `opus` (dev + adversarial review — under-powering this is the main reason naive
  automation produces slop), and the `report` node `haiku`. `opus` over a long multi-story run is the
  expensive part; drop `build-loop` to `sonnet` to trade quality for cost. If you'd rather use Archon
  tier presets (`small`/`medium`/`large`), configure them first with `archon ai tier set <tier>
  claude <model>` — unconfigured tier names fail to resolve.
- `build-loop.loop.max_iterations` (default `150`) — raise for very large multi-epic runs.
- `build-loop.idle_timeout` (default `1800000` ms = 30 min) — raise if `dev-story` sessions run long.
- `build-loop.loop.until` / retry counts (`maxReviewRetries`, `maxCreateRetries`) — tune the gates.

#### How it differs from the upstream automator

This is a faithful port of the *pipeline*, deliberately simplified for the Archon runtime:

- **One Archon `loop:` node** driven by a `state.json` state machine + `sprint-status.yaml`, instead
  of a Python orchestrator spawning tmux child sessions. `fresh_context: true` gives each role a clean
  session, mirroring the automator's isolated sessions.
- **The adversarial reviewer is inlined** into the workflow (derived from the automator's bundled
  `bmad-story-automator-review` skill), so you don't need to install that review skill separately.
- **No programmatic complexity scoring / per-story agent selection.** Archon handles provider/model
  selection via config tiers; set the loop `model` (or tiers) once.
- **Commit-only, like the upstream** — it does not open PRs. Add a final node if you want one.

Everything else — the `create → dev → auto → review(≤8) → commit` per-story sequence, the
adversarial review gate (see [Review gating & automatic fixes](#review-gating--automatic-fixes)),
sprint-status as source of truth, and per-epic retrospectives fired inside the loop — matches the
automator.

---

## Adding a workflow

1. Drop a new `*.yaml` Archon workflow into [`workflows/`](./workflows) with a descriptive `name:`.
   Keep it prefixed `archon-bmad-` so it's easy to find with `archon workflow list | grep archon-bmad`.
2. Add a row to the [Workflows](#workflows) table and a `###` section documenting it.
3. `./install.sh` picks it up automatically — no installer changes needed.

## Credits & license

`archon-bmad-story-automator` is ported from
[`bmad-code-org/bmad-automator`](https://github.com/bmad-code-org/bmad-automator) and built for the
[BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD). Both are MIT-licensed; see
[`NOTICE`](./NOTICE) for attribution. This repository is MIT-licensed — see [`LICENSE`](./LICENSE).
