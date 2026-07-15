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
| [`archon-bmad-story-automator`](#archon-bmad-story-automator) | The BMAD implementation loop — create → dev → review → commit per story, with per-epic retrospectives and (in [stacked-branching](#stacked-branching--pr-automation) mode) a repeatable, per-epic [integration rebuild, functional test & antagonistic review cycle](#per-epic-integration-rebuild-functional-test--antagonistic-review) that, on failure, attempts a bounded [auto-correct-course self-healing loop](#auto-correct-course-the-self-healing-loop) before escalating to a human. |

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
| `rebase_cascade` | — | *Stacked-branching mode only* — refreshes the whole stack against upstream before rebuilding/testing/reviewing it — see [below](#per-epic-integration-rebuild-functional-test--antagonistic-review) |
| `integration_build` | — | *Stacked-branching mode only* — rebuilds a disposable cumulative integration branch from the freshly-rebased stack |
| `functional_test` | — | *Stacked-branching mode only* — generates-if-missing and runs cumulative epic-level and project-level acceptance tests |
| `integrate_review` | — | *Stacked-branching mode only* — antagonistic requirements-driven review of the disposable branch, corroborated by the passing functional tests — see [Per-epic integration rebuild, functional test & antagonistic review](#per-epic-integration-rebuild-functional-test--antagonistic-review) |
| `auto_correct_course` | — | *Stacked-branching mode only* — root-causes a `functional_test`/`integrate_review` failure, fixes it (on the owning story branch only) if safe, and loops back to `rebase_cascade`; escalates otherwise — see [Auto-correct-course: the self-healing loop](#auto-correct-course-the-self-healing-loop) |

When everything in your selection is `done`, each completed epic has had its retrospective, and the
highest completed epic's validation cycle (above) has run, the run finishes and emits a report.

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

#### Per-epic integration rebuild, functional test & antagonistic review

The per-story `review` phase is deliberately narrow — each pass only ever sees **one story's own
diff**. That's the right scope for "did this story do what it claims," but it structurally cannot catch
a gap that only exists at the **seam between stories or epics**: e.g. an early story adds a processor
module, and a later story that's supposed to wire it into the live pipeline never actually does, or a
config flag one epic introduces is set but nothing in a later epic ever reads it. Each story's review
looks clean in isolation; the feature is still broken end-to-end. This is exactly the class of defect a
real antagonistic pass over the *whole merged stack* — corroborated by actually **running** cumulative
acceptance tests, not just reading code — is built to catch.

Rather than a single check at the very end of a run, this is a **repeatable four-step cycle** that runs
after **every epic** completes (and as a catch-all — see below — for runs where no epic's retrospective
freshly fires), each time cumulatively covering everything from epic 1 through whichever epic just
finished:

1. **`rebase_cascade`** — refresh the stack against `upstream`/`origin` first (fast-forward the default
   branch, then cascade-rebase every `feat/*/story-*` branch onto it in stack order, filtered to epics
   `<= currentValidationEpic`), so the next steps validate the *freshest* code, not a stale snapshot.
   A conflict here halts with `status = "needs-attention"` — a stack that no longer rebases cleanly
   needs a human decision, not an autonomous resolution.
2. **`integration_build`** — merge that freshly-rebased, filtered stack, in order, onto a fresh,
   local-only, never-pushed `integration/epic-{N}-validation-<suffix>` branch. Nothing is pushed
   anywhere; the branch is disposable and rebuilt from scratch every cycle. A merge conflict here halts
   the same way as above.
3. **`functional_test`** — inventories existing functional/acceptance-level suites on that branch and
   generates whichever are missing, in **two distinct categories**:
   - **Epic-level tests**, one per epic in scope, proving that epic's own acceptance criteria hold
     end-to-end (not just asserted per-story in isolation).
   - **Project-level / cross-epic tests** — a smaller, standing suite derived from the PRD's overall
     goals and any requirement or user journey that only makes sense once two or more epics compose
     together (e.g. "a span created by an early epic's instrumentation is queryable through a later
     epic's export path"). No amount of per-epic testing alone can catch this class of gap.

   Both categories follow the spirit of `bmad-qa-generate-e2e-tests` (existing framework/patterns,
   happy path + explicit edge cases, no over-engineering) but skip that skill's "ask the user what to
   test" step, deriving scope autonomously from the epics'/PRD's acceptance criteria instead — this
   phase runs fully autonomously. Tests are committed only on the disposable integration branch, never
   on any story branch. The full suite (existing + newly generated, both categories) is then run for
   real. **Any failure, in either category**, is direct executable proof of a break and halts with
   `status = "needs-attention"` — it is never treated as a soft signal or auto-fixed.
4. **`integrate_review`** — only reached once every test above passes. One antagonistic review of the
   merged branch, prefers a clean sub-agent/Task-tool context (falls back to reviewing inline if
   unavailable), reading the full PRD, epics/acceptance-criteria, architecture doc, and spec, plus every
   story file in scope — then inspecting the *actual merged code*, not story claims, using the passing
   functional tests as corroborating (not exculpatory) evidence. Findings are classified
   `CRITICAL`/`HIGH`/`MEDIUM`/`LOW` with file/line evidence, written to
   `{planningArtifacts}/integration-review-epic-{N}-<date>.md`.

**Branches on the outcome — auto-fixes narrow, mechanical defects, escalates the rest:**
- **0 CRITICAL / 0 HIGH, all tests pass** → every epic from the lowest not-yet-validated epic through
  the current one is appended to `epicsValidated`, and the run resumes normal selection (next epic's
  stories, or `status = "complete"` if nothing else is pending).
- **1+ CRITICAL or HIGH finding, or any functional test failure** → rather than halting immediately,
  the run enters [`auto_correct_course`](#auto-correct-course-the-self-healing-loop): if the failure
  root-causes to an unambiguous implementation-fidelity defect (a stale caller/test never updated
  after a different, already-landed story's intentional API change), it's fixed automatically — on
  the correct owning story branch, never the disposable one — and the whole four-step cycle re-runs
  from `rebase_cascade` to prove the fix is real. This repeats up to `maxIntegrationFixRetries` times
  (default 3). The run only halts with `status = "needs-attention"` (distinct from `failed` — every
  individual story genuinely passed its own review; the gap is cross-story/cross-epic) if a finding
  is judged NOT safe to auto-fix (ambiguous design intent, conflicting requirements, a gap implying a
  missing story/epic) or the retry budget is exhausted with the problem still present. Either way,
  the final report points at the findings file / test failure and recommends running BMad's
  `bmad-correct-course` workflow by hand, since a human decision is now unavoidable.

#### Auto-correct-course: the self-healing loop

A functional-test failure or a CRITICAL/HIGH integration-review finding is *proof* something is
broken, but not everything broken this way needs a human in the loop. The most common case observed
in practice: Story A lands and — correctly, deliberately — changes a function's signature or a
module's behavior; Story B (already merged, maybe epics earlier) still calls the old signature in its
own test or a downstream caller, because Story B was written before Story A's change ever landed.
Every story's own per-story review passes (each diff looks internally consistent), yet the composed
stack is broken. This is exactly the class of defect that's mechanical to fix once root-caused: there
is one unambiguously correct answer (match the newer, already-landed, intentional contract), no
design judgment call required.

`auto_correct_course` is deliberately narrow about what it will fix on its own:

- **Root-cause first.** For a test failure, `git log -p` / `git blame` on both the failing test and
  the production code it exercises to find which commit changed the contract and which side never
  caught up. For a review finding, the finding's own file/line evidence plus `git blame` to find the
  owning story.
- **Classify before touching anything.** Only an unambiguous implementation-fidelity defect against
  an already-approved contract is "safe to auto-fix" — the same "Minor: Direct Adjustment" tier
  `bmad-correct-course` itself would assign. Anything involving ambiguous intent, conflicting
  acceptance criteria, or a gap that implies a missing story/epic is left alone entirely — no partial
  autonomous fix is applied if even one finding in the batch doesn't qualify — and the run escalates
  to `needs-attention` immediately instead of guessing.
- **The fix always lands on the owning story branch — never on the disposable integration
  branch.** This is a hard rule, not a preference: the integration/validation branch is rebuilt from
  scratch every cycle, so anything fixed only there is silently thrown away and the defect would
  resurface on every future run. The phase determines which individual `feat/*/story-*` branch's
  tracked file actually contains the defective content (via `git log`/`git blame`, same mechanism a
  human would use), checks that branch out (working around a worktree lock if another session has it
  checked out), resyncs against `origin` first, applies the minimal fix, runs just that file's own
  tests, commits with a message referencing the finding, and pushes with `--force-with-lease` — the
  exact same branch that will eventually be opened as its own PR. If multiple branches need fixes,
  each is fixed in stack order and cascade-rebased forward before the next one is touched, so nothing
  is edited twice and no fix is ever "lost" underneath a later one.
- **Then it proves the fix, it doesn't just assert it.** After committing/pushing, the phase loops
  back to `rebase_cascade` — the *entire* four-step cycle re-runs from a completely fresh disposable
  integration branch and a fresh functional-test pass, so a green result here is real end-to-end
  proof, not just "the diff looks right."
- **Bounded and auditable.** `maxIntegrationFixRetries` (default 3) caps how many cycles this can run
  before forcing escalation regardless of classification. Every cycle's fixes (branch, commit SHA,
  summary) are appended to `integrationFixLog` in `state.json`, and the final report surfaces the full
  log — which branches were touched, what was fixed, and how many retries were used — so a human
  reviewing a `complete` run can still see exactly what the automation changed on its own.

This is intentionally a *narrower* trust boundary than the per-story `review` phase's own inline
auto-fix (which only ever touches one story's own diff, already scoped to a single branch). Crossing
epic/story boundaries to fix something on a DIFFERENT branch than the one currently being worked is a
bigger blast radius, which is exactly why the classification step exists as a hard gate before any
edit is made.

**When this cycle triggers:**
- **Eagerly**, right when an epic's own retrospective (`retro` phase) lands, covering that epic and
  everything beneath it.
- **As a catch-all**, from `select`'s end-of-run gate: if no pending story/retro work remains but the
  highest fully-`done` epic in `sprint-status.yaml` is still absent from `epicsValidated` — e.g. a
  defect-fix pass that re-touches stories across several already-completed epics never causes any of
  their retrospectives to re-fire (retrospectives are guarded against re-running), so without this
  catch-all the cycle would silently never run at all in that scenario.

**This is the mechanized version of a manual process**: keep the stack fresh, rebuild a disposable local
integration branch by replaying it in order, prove the cumulative acceptance criteria actually run, then
point one adversarial reviewer at the composed result — repeated after every epic instead of deferred to
the very end of a multi-epic run, so drift and cross-story/cross-epic gaps never have a chance to pile
up unnoticed.

**Single-branch (non-stacked) projects**: this cycle is a deliberate no-op. Without the
[stacked-branching convention](#stacked-branching--pr-automation) every story already lands on the same
one worktree branch, so there's no separate `feat/*/story-*` branches to rebuild or merge — `select`'s
catch-all never fires, and the run completes exactly as it always has. You only get real cross-story
integration validation by adopting stacked branching.

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
